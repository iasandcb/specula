import XCTest
import Network
import BigInt
import CryptoKit
import CommonCrypto
@testable import RemoteCore

final class SessionTests: XCTestCase {
    func testFragmentedHandshakeAuthenticationAndFramebuffer() async throws { try await session(account: false) }
    func testMacAccountLoginReachesFramebuffer() async throws { try await session(account: true) }

    private func session(account: Bool) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let serverFinished = expectation(description: "server verified client handshake")
        let receivedFrame = expectation(description: "client decoded frame")
        let ready = expectation(description: "client initialized")
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
                    let encodings = try await self.read(connection, 12)
                    XCTAssertEqual(encodings, Data([2,0,0,2,0,0,0,0,255,255,255,33]))
                    let updateRequest = try await self.read(connection, 10)
                    XCTAssertEqual(updateRequest, Data([3,0,0,0,0,0,0,2,0,1]))
                    // A 2×1 raw rectangle: red, green. Padding must become opaque alpha.
                    try await self.send(connection, Data([0,0,0,1, 0,0,0,0,0,2,0,1,0,0,0,0, 255,0,0,0,0,255,0,0]))
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
            })
        }
        await fulfillment(of: [ready, receivedFrame, serverFinished], timeout: 15)
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
}
