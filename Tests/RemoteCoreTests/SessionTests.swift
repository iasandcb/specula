import XCTest
import Network
import BigInt
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#else
import CCryptoShim
#endif
@testable import RemoteCore

final class SessionTests: XCTestCase {
    func testFragmentedHandshakeAuthenticationAndFramebuffer() async throws { try await session(account: false) }
    func testMacAccountLoginReachesFramebuffer() async throws { try await session(account: true) }
    func testZRLEAndCursorRectanglesUpdateTheFrameWithoutRawPixels() async throws { try await session(account: false, compressed: true) }

    private func session(account: Bool, compressed: Bool = false) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let serverFinished = expectation(description: "server verified client handshake")
        let receivedFrame = expectation(description: "client decoded frame")
        let ready = expectation(description: "client initialized")
        let receivedCursor = expectation(description: "client decoded cursor")
        if !compressed { receivedCursor.fulfill() }
        let queue = DispatchQueue(label: "test.rfb")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                do {
                    // Split the version across TCP sends, exercising exact-length reads.
                    try await self.send(connection, Data("RFB 003.".utf8))
                    try await self.send(connection, Data("008\n".utf8))
                    let version = try await self.read(connection, 12)
                    XCTAssertEqual(String(decoding: version, as: UTF8.self), "RFB 003.008\n")
                    try await self.send(connection, Data(account ? [UInt8(2),2,30] : [UInt8(1),2]))
                    let selection = try await self.read(connection, 1)
                    XCTAssertEqual(selection, Data([UInt8(account ? 30 : 2)]))
                    if account {
                        try await self.send(connection, Data([0,2,0,128]) + ARDTests.prime + ARDTests.peer)
                        let response = try await self.read(connection, 256)
                        try self.verifyAccountResponse(response)
                    } else {
                        try await self.send(connection, Data(repeating: 0, count: 16))
                        let response = try await self.read(connection, 16)
                        XCTAssertEqual(response.map { String(format: "%02x", $0) }.joined(), "8ca64de9c1b123a78ca64de9c1b123a7")
                    }
                    try await self.send(connection, Data([0,0,0,0]))
                    let shared = try await self.read(connection, 1)
                    XCTAssertEqual(shared, Data([1]))
                    let format: [UInt8] = [32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0]
                    try await self.send(connection, Data([0,2,0,1] + format + [0,0,0,4] + Array("Test".utf8)))
                    let pixelFormat = try await self.read(connection, 20)
                    XCTAssertEqual(pixelFormat, Data([0,0,0,0] + format))
                    let expectedEncodings = RFBEncodings.setEncodingsMessage()
                    let encodings = try await self.read(connection, expectedEncodings.count)
                    XCTAssertEqual(encodings, expectedEncodings)
                    let updateRequest = try await self.read(connection, 10)
                    XCTAssertEqual(updateRequest, Data([3,0,0,0,0,0,0,2,0,1]))
                    if compressed {
                        // Cursor (hotspot 0,0) then a 2×1 ZRLE tile: red, green. Not drawn as raw pixels.
                        let zrle = Data([0x78,0x9c,0x62,0xf8,0xcf,0xc0,0xc0,0xf0,0x9f,0x01,0x00,0x00,0x00,0xff,0xff])
                        var message = Data([0,0,0,2, 0,0,0,0, 0,1,0,1, 255,255,255,17, 9,8,7,0, 0x80])
                        message.append(contentsOf: [0,0,0,0, 0,2,0,1, 0,0,0,16])
                        message.append(contentsOf: [0,0,0,UInt8(zrle.count)])
                        message.append(zrle)
                        try await self.send(connection, message)
                    } else {
                        // A 2×1 raw rectangle: red, green. Padding must become opaque alpha.
                        try await self.send(connection, Data([0,0,0,1, 0,0,0,0,0,2,0,1,0,0,0,0, 255,0,0,0,0,255,0,0]))
                    }
                    let incrementalRequest = try await self.read(connection, 10)
                    XCTAssertEqual(incrementalRequest, Data([3,1,0,0,0,0,0,2,0,1]))
                } catch { XCTFail("Mock server failed: \(error)") }
                serverFinished.fulfill()
                connection.cancel()
            }
        }
        let listenerReady = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listenerReady.fulfill()
            case .failed(let error): XCTFail("Listener failed: \(error)"); listenerReady.fulfill()
            default: break
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [listenerReady], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = RFBClient()
        let task = Task {
            try? await client.run(host: "127.0.0.1", port: port, username: account ? "alex" : "", password: account ? "암호123" : "\0", onFrame: { frame in
                XCTAssertEqual(frame.width, 2); XCTAssertEqual(frame.height, 1)
                XCTAssertEqual(frame.rgba, Data([255,0,0,255,0,255,0,255]))
                receivedFrame.fulfill()
            }, onReady: { name in
                XCTAssertEqual(name, "Test"); ready.fulfill()
            }, onCursor: { cursor in
                XCTAssertEqual(cursor.width, 1)
                XCTAssertEqual(Array(cursor.rgba), [9, 8, 7, 255])
                receivedCursor.fulfill()
            })
        }
        await fulfillment(of: [ready, receivedFrame, receivedCursor, serverFinished], timeout: 15)
        await client.close(); task.cancel(); await task.value
    }
    private func verifyAccountResponse(_ response: Data) throws {
        let clientPublic = BigUInt(Data(response.suffix(128)))
        let secret = clientPublic.power(BigUInt(123456789), modulus: BigUInt(ARDTests.prime))
        let shared = try ARD.padded(secret, length: 128)
        let key = Array(Insecure.MD5.hash(data: shared))
        let ciphertext = Data(response.prefix(128))
        var plaintext = [UInt8](repeating: 0, count: 128)
        var written = 0
        let status = key.withUnsafeBytes { k in ciphertext.withUnsafeBytes { input in
            plaintext.withUnsafeMutableBytes { out in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k.baseAddress, 16, nil, input.baseAddress, 128, out.baseAddress, 128, &written)
            }
        } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess)); XCTAssertEqual(written, 128)
        let usernameBytes = plaintext.prefix(64).prefix(while: { $0 != 0 })
        let passwordBytes = plaintext.suffix(64).prefix(while: { $0 != 0 })
        XCTAssertEqual(String(decoding: usernameBytes, as: UTF8.self), "alex")
        XCTAssertEqual(String(decoding: passwordBytes, as: UTF8.self), "암호123")
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    private func read(_ connection: NWConnection, _ count: Int) async throws -> Data {
        var output = Data()
        while output.count < count {
            let maximum = count - output.count
            let data: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: RFBError.invalid("Unexpected EOF")) }
                }
            }
            output.append(data)
        }
        return output
    }

    func testProbeRecordsRectanglesAndOnlyPostInitBytes() async throws {
        let bell = Data([2])
        let raw = Data([0,0,0,1, 0,0,0,0, 0,2,0,1, 0,0,0,0, 255,0,0,0, 0,255,0,0])
        let copy = Data([0,0,0,1, 0,0,0,0, 0,2,0,1, 0,0,0,1, 0,0,0,0])
        let capture = ProbeCapture()
        let failure = try await runProbe(width: 2, height: 1, encodings: [RFBEncodings.raw, RFBEncodings.copyRect], updateLimit: 2, payload: bell + raw + copy, updates: 2, capture: capture)
        XCTAssertNil(failure)
        XCTAssertEqual(capture.bytes, bell + raw + copy)
        XCTAssertEqual(capture.rectangles.map(\.encoding), [RFBEncodings.raw, RFBEncodings.copyRect])
        XCTAssertEqual(capture.rectangles.map(\.bytes), [8, 4])
        XCTAssertEqual(capture.rectangles.map(\.streamOffset), [1 + 4, 1 + raw.count + 4])
        XCTAssertEqual(capture.rectangles.map(\.x), [0, 0])
        XCTAssertEqual(capture.rectangles.map(\.y), [0, 0])
        XCTAssertEqual(capture.rectangles.map(\.width), [2, 2])
        XCTAssertEqual(capture.rectangles.map(\.height), [1, 1])
        XCTAssertTrue(capture.rectangles.allSatisfy { $0.error == nil && $0.offset == nil && $0.decodeSeconds >= 0 && $0.decodeSeconds < 5 })
        XCTAssertEqual(capture.updates.map(\.index), [1, 2])
        XCTAssertEqual(capture.updates.map(\.bytes), [raw.count, copy.count])
        XCTAssertEqual(capture.frames.first?.rgba, Data([255,0,0,255, 0,255,0,255]))
        XCTAssertEqual(capture.frames.last?.rgba, capture.frames.first?.rgba)
    }

    func testProbeReportsZRLEOffsetAndKeepsTheFailingBytes() async throws {
        let zrle = Data([0x78, 0x9c, 0xab, 0x07, 0x00, 0x00, 0x80, 0x00, 0x80])
        var message = Data([0,0,0,1, 0,0,0,0, 0,1,0,1, 0,0,0,16, 0,0,0,UInt8(zrle.count)])
        message.append(zrle)
        let capture = ProbeCapture()
        let failure = try await runProbe(width: 1, height: 1, encodings: [RFBEncodings.zrle, RFBEncodings.raw], updateLimit: 5, payload: message, updates: 1, capture: capture)
        XCTAssertTrue(failure?.contains("재사용할 ZRLE 팔레트가 없습니다.") == true)
        XCTAssertEqual(capture.bytes, message)
        XCTAssertEqual(capture.updates.count, 0)
        XCTAssertEqual(capture.rectangles.count, 1)
        let rect = try XCTUnwrap(capture.rectangles.first)
        XCTAssertEqual(rect.encoding, RFBEncodings.zrle)
        XCTAssertEqual(rect.x, 0); XCTAssertEqual(rect.y, 0); XCTAssertEqual(rect.width, 1); XCTAssertEqual(rect.height, 1)
        XCTAssertEqual(rect.bytes, 4 + zrle.count)
        XCTAssertEqual(rect.offset, 1)
        XCTAssertEqual(rect.streamOffset, 4)
        XCTAssertEqual(rect.error, "재사용할 ZRLE 팔레트가 없습니다.")
        XCTAssertTrue(capture.frames.isEmpty)
    }

    private func runProbe(width: Int, height: Int, encodings: [Int], updateLimit: Int, payload: Data, updates: Int, capture: ProbeCapture) async throws -> String? {
        let listener = try NWListener(using: .tcp, on: .any)
        let serverDone = expectation(description: "probe server finished")
        let queue = DispatchQueue(label: "test.probe")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                defer { serverDone.fulfill() }
                do {
                    try await self.send(connection, Data("RFB 003.008\n".utf8))
                    let version = try await self.read(connection, 12)
                    XCTAssertEqual(version, Data("RFB 003.008\n".utf8))
                    try await self.send(connection, Data([1, 2]))
                    let selection = try await self.read(connection, 1)
                    XCTAssertEqual(selection, Data([2]))
                    try await self.send(connection, Data(repeating: 0, count: 16))
                    _ = try await self.read(connection, 16)
                    try await self.send(connection, Data([0,0,0,0]))
                    let shared = try await self.read(connection, 1)
                    XCTAssertEqual(shared, Data([1]))
                    let format: [UInt8] = [32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0]
                    let header = Data([UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)])
                    try await self.send(connection, header + Data(format) + Data([0,0,0,4] + Array("Test".utf8)))
                    let pixelFormat = try await self.read(connection, 20)
                    XCTAssertEqual(pixelFormat, Data([0,0,0,0] + format))
                    let expected = RFBEncodings.setEncodingsMessage(encodings: encodings)
                    let encodingsMessage = try await self.read(connection, expected.count)
                    XCTAssertEqual(encodingsMessage, expected)
                    let full = Data([3, 0, 0,0,0,0, UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)])
                    let firstRequest = try await self.read(connection, 10)
                    XCTAssertEqual(firstRequest, full)
                    try await self.send(connection, payload)
                    let incremental = Data([3, 1, 0,0,0,0, UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)])
                    for _ in 0..<updates {
                        let request = try await self.read(connection, 10)
                        XCTAssertEqual(request, incremental)
                    }
                } catch { XCTFail("Probe server failed: \(error)") }
            }
        }
        let listenerReady = expectation(description: "probe listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
            if case .failed(let error) = state { XCTFail("Listener failed: \(error)"); listenerReady.fulfill() }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [listenerReady], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = RFBClient()
        let clientTask = Task { () -> String? in
            do {
                try await client.run(host: "127.0.0.1", port: port, password: "probe", onFrame: { capture.frames.append($0) }, onReady: { name in
                    XCTAssertEqual(name, "Test")
                }, encodings: encodings, updateLimit: updateLimit, onServerBytes: { capture.bytes.append($0) }, onRectangle: { capture.rectangles.append($0) }, onUpdate: { capture.updates.append($0) })
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        await fulfillment(of: [serverDone], timeout: 15)
        await client.close()
        clientTask.cancel()
        return await clientTask.value
    }
}

private final class ProbeCapture: @unchecked Sendable {
    var bytes = Data()
    var rectangles: [RectangleDiagnostic] = []
    var updates: [UpdateDiagnostic] = []
    var frames: [Frame] = []
}
