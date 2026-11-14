import XCTest
import Network
@testable import RemoteCore

/// Replays a real macOS Screen Sharing capture through RFBClient.
/// The bytes are the first 24 framebuffer updates after ServerInit from a 1600×1200 session
/// (MacBook Pro, 127.0.0.1:5900, Apple auth, ZRLE + CopyRect + Raw + Cursor + DesktopSize + LastRect).
/// Every rectangle in the capture is ZRLE. The server sent no cursor pseudo-encoding.
final class ScreenSharingReplayTests: XCTestCase {
    func testCapturedZRLESurvivesWifiSizedReads() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "screen-sharing-zrle", withExtension: "bin", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        XCTAssertEqual(fixture.count, 1_791_118)
        #if os(Linux)
        NWConnection.testingSegments(limit: 1500, seed: 0x5A17_C0DE)
        defer { NWConnection.testingSegments(limit: 0, seed: 0) }
        #endif
        let capture = ReplayCapture()
        let listener = try NWListener(using: .tcp, on: .any)
        let serverDone = expectation(description: "replay server sent the capture")
        let queue = DispatchQueue(label: "test.replay")
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
                    try await self.send(connection, Data([0, 0, 0, 0]))
                    let shared = try await self.read(connection, 1)
                    XCTAssertEqual(shared, Data([1]))
                    let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0]
                    let serverInit = Data([0x06, 0x40, 0x04, 0xb0]) + Data(format) + Data([0, 0, 0, 4] + Array("Test".utf8))
                    try await self.send(connection, serverInit)
                    let pixelFormat = try await self.read(connection, 20)
                    XCTAssertEqual(pixelFormat, Data([0, 0, 0, 0] + format))
                    let encodings = RFBEncodings.setEncodingsMessage()
                    let offered = try await self.read(connection, encodings.count)
                    XCTAssertEqual(offered, encodings)
                    XCTAssertEqual(RFBEncodings.advertised().first, RFBEncodings.zrle)
                    XCTAssertFalse(RFBEncodings.advertised().contains(RFBEncodings.cursor))
                    let request = try await self.read(connection, 10)
                    XCTAssertEqual(request, Data([3, 0, 0, 0, 0, 0, 0x06, 0x40, 0x04, 0xb0]))
                    var offset = 0
                    var rng = ReplayRNG(seed: 0xA11CE)
                    while offset < fixture.count {
                        let size = rng.next(upper: min(1500, fixture.count - offset))
                        try await self.send(connection, fixture.subdata(in: offset..<(offset + size)))
                        offset += size
                    }
                    // The client pipelines the next request before it decodes. Leave the socket open
                    // until those requests arrive, or closing here drops the unread tail.
                    let incremental = Data([3, 1, 0, 0, 0, 0, 0x06, 0x40, 0x04, 0xb0])
                    for _ in 0..<24 {
                        let next = try await self.read(connection, 10)
                        XCTAssertEqual(next, incremental)
                    }
                    connection.cancel()
                } catch {
                    XCTFail("Replay server failed: \(error)")
                }
            }
        }
        let listenerReady = expectation(description: "replay listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
            if case .failed(let error) = state { XCTFail("Listener failed: \(error)"); listenerReady.fulfill() }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [listenerReady], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = RFBClient()
        let clientTask = Task { () -> String in
            do {
                try await client.run(host: "127.0.0.1", port: port, password: "probe", onFrame: { frame in
                    capture.note(frame)
                }, onReady: { _ in })
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        let clientDone = expectation(description: "replay client finished")
        Task {
            _ = await clientTask.value
            clientDone.fulfill()
        }
        await fulfillment(of: [serverDone, clientDone], timeout: 180)
        await client.close()
        let failure = await clientTask.value
        XCTAssertFalse(failure.contains("화면"))
        XCTAssertFalse(failure.contains("ZRLE"))
        XCTAssertFalse(failure.contains("인코딩"))
        XCTAssertEqual(capture.updates, 24)
        XCTAssertEqual(capture.width, 1600)
        XCTAssertEqual(capture.height, 1200)
        XCTAssertEqual(capture.hash, 3_000_278_177_406_984_333)
        #if os(Linux)
        XCTAssertGreaterThan(NWConnection.testingReceiveCount, 1_000)
        XCTAssertLessThanOrEqual(NWConnection.testingLargestReceive, 1500)
        #endif
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

private final class ReplayCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var lastHash: UInt64 = 0
    private var lastWidth = 0
    private var lastHeight = 0
    var updates: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var hash: UInt64 { lock.lock(); defer { lock.unlock() }; return lastHash }
    var width: Int { lock.lock(); defer { lock.unlock() }; return lastWidth }
    var height: Int { lock.lock(); defer { lock.unlock() }; return lastHeight }
    func note(_ frame: Frame) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in frame.rgba {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        lock.lock()
        frames += 1
        lastHash = hash
        lastWidth = frame.width
        lastHeight = frame.height
        lock.unlock()
    }
}

private struct ReplayRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(upper: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1
        return Int(state % UInt64(upper)) + 1
    }
}
