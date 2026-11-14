import Foundation
import Network
#if canImport(os)
import os
#endif

private func logRFB(_ message: String) {
    #if canImport(os)
    Logger(subsystem: "com.ias.specula", category: "RFB").error("\(message, privacy: .public)")
    #else
    print("RFB: \(message)")
    #endif
}

public struct Frame: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
}

/// All protocol state is confined to this actor; only one receive loop may run.
public actor RFBClient {
    private var connection: NWConnection?
    private var width = 0
    private var height = 0
    private var pixels = Data()
    private var inflate = InflateStream()
    private var zrle = ZRLEDecoder()
    private let queue = DispatchQueue(label: "MacRemote.RFB")
    public init() {}

    /// Nagle would hold small pointer packets and framebuffer requests for a delayed ACK.
    static func transportParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    public func close() { connection?.cancel(); connection = nil }

    public func run(host: String, port: UInt16, username: String = "", password: String,
                    onProgress: @escaping @Sendable (String) -> Void = { _ in },
                    onFrame: @escaping @Sendable (Frame) -> Void,
                    onReady: @escaping @Sendable (String) -> Void,
                    onCursor: @escaping @Sendable (RemoteCursor) -> Void = { _ in }) async throws {
        guard connection == nil else { throw RFBError.invalid("이미 연결 중입니다.") }
        inflate = InflateStream()
        zrle = ZRLEDecoder()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RFBError.invalid("포트를 확인해 주세요.") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: Self.transportParameters())
        connection = conn
        defer { conn.cancel(); connection = nil }
        conn.start(queue: queue)
        let handshakeDeadline = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000); conn.cancel() }
            catch { }
        }
        defer { handshakeDeadline.cancel() }
        onProgress("맥에 접속 중…")
        let version = try await read(12)
        onProgress("맥 응답 확인 · 로그인 방식 협의 중…")
        guard let banner = String(data: version, encoding: .ascii), banner.hasPrefix("RFB "), banner.hasSuffix("\n"),
              let major = Int(banner.dropFirst(4).prefix(3)), major == 3,
              let minor = Int(banner.dropFirst(8).prefix(3)), minor >= 3 else {
            throw RFBError.invalid("지원하지 않는 화면 공유 프로토콜입니다.")
        }
        let negotiated = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        try await send(Data("RFB 003.00\(negotiated)\n".utf8))
        let accountLogin = !username.isEmpty
        let security = accountLogin ? 30 : 2
        if negotiated == 3 {
            guard try await number(4) == security else {
                throw RFBError.invalid(accountLogin ? "이 맥은 계정 로그인을 제공하지 않습니다. 사용자 이름을 비우고 VNC 암호로 접속해 주세요." : "맥에서 VNC 암호 접속을 켜거나 사용자 이름을 입력해 계정으로 접속해 주세요.")
            }
        } else {
            let count = try await number(1)
            guard count > 0 else { throw RFBError.invalid(try await reason()) }
            let types = try await read(count)
            guard types.contains(UInt8(security)) else {
                throw RFBError.invalid(accountLogin ? "이 맥은 지원하는 계정 인증(ARD)을 제공하지 않습니다. VNC 암호 접속을 사용해 주세요." : "사용자 이름과 맥 로그인 암호를 입력하거나, 맥에서 VNC 암호 접속을 켜 주세요.")
            }
            try await send(Data([UInt8(security)]))
        }
        if accountLogin {
            let generator = try await number(2)
            let length = try await number(2)
            guard (128...512).contains(length) else { throw RFBError.invalid("지원하지 않는 맥 인증 키 크기입니다.") }
            let modulus = try await read(length), peer = try await read(length)
            onProgress("맥 계정 인증 키 계산 중…")
            let computation = Task.detached {
                try ARD.response(generator: generator, modulus: modulus, peer: peer, username: username, password: password)
            }
            let response = try await withTaskCancellationHandler(operation: { try await computation.value }, onCancel: { computation.cancel() })
            try Task.checkCancellation()
            onProgress("맥에 로그인 확인 중…")
            try await send(response)
        } else {
            onProgress("VNC 암호 확인 중…")
            let challenge = try await read(16)
            try await send(Wire.challengeResponse(challenge, password: password))
        }
        guard try await number(4) == 0 else {
            throw RFBError.invalid(accountLogin ? "맥 계정 인증에 실패했습니다. 사용자 이름·암호와 화면 공유 접근 권한을 확인해 주세요." : "인증에 실패했습니다. 맥에 설정한 VNC 암호를 확인해 주세요.")
        }
        onProgress("로그인 완료 · 화면 정보 수신 중…")
        try await send(Data([1]))
        width = try await number(2); height = try await number(2)
        _ = try await read(16)
        let name = try await reason()
        try allocate()
        // 32 bpp, 24-bit depth, little endian, true colour; R/G/B shifts 0/8/16.
        try await send(Data([0,0,0,0, 32,24,0,1, 0,255,0,255,0,255, 0,8,16, 0,0,0]))
        try await send(RFBEncodings.setEncodingsMessage())
        handshakeDeadline.cancel()
        onProgress("첫 화면을 받는 중…")
        onReady(name)
        try await request(incremental: false)
        while !Task.isCancelled {
            let type = try await number(1)
            switch type {
            case 0:
                _ = try await read(1)
                let count = try await number(2)
                let pending = try await readRectangles(count)
                let resized = pending.contains { if case .desktop = $0 { return true }; return false }
                let requestedWidth = pending.reversed().compactMap { item -> Int? in
                    if case .desktop(let w, _) = item { return w }; return nil
                }.first ?? width
                let requestedHeight = pending.reversed().compactMap { item -> Int? in
                    if case .desktop(_, let h) = item { return h }; return nil
                }.first ?? height
                // The next request goes out before inflate or the UI, so the server can capture the following frame immediately.
                try await request(incremental: !resized, width: requestedWidth, height: requestedHeight)
                let applied = try apply(pending)
                if let cursor = applied.cursor { onCursor(cursor) }
                if applied.pixelsChanged { onFrame(Frame(width: width, height: height, rgba: pixels)) }
            case 2: break // Bell
            case 3:
                _ = try await read(3)
                _ = try await reason() // Clipboard is deliberately not applied locally.
            default: throw RFBError.invalid("지원하지 않는 서버 메시지입니다: \(type)")
            }
        }
    }

    private enum PendingRect {
        case desktop(Int, Int)
        case raw(x: Int, y: Int, w: Int, h: Int, data: Data)
        case copy(x: Int, y: Int, w: Int, h: Int, fromX: Int, fromY: Int)
        case zrle(x: Int, y: Int, w: Int, h: Int, data: Data)
        case cursor(RemoteCursor)
    }

    private func readRectangles(_ count: Int) async throws -> [PendingRect] {
        var pending: [PendingRect] = []
        var index = 0
        while index < count {
            index += 1
            let x = try await number(2), y = try await number(2)
            let w = try await number(2), h = try await number(2)
            let encoding = try await number(4)
            if encoding == RFBEncodings.lastRect { break }
            do {
                switch encoding {
                case RFBEncodings.desktopSize:
                    guard w > 0, h > 0 else { throw RFBError.invalid("화면 크기가 잘못되었습니다.") }
                    pending.append(.desktop(w, h))
                case RFBEncodings.cursor:
                    if w == 0 || h == 0 {
                        pending.append(.cursor(RemoteCursor(width: 0, height: 0, hotspotX: x, hotspotY: y, rgba: Data())))
                    } else {
                        guard let length = CursorPseudo.payloadLength(width: w, height: h) else { throw RFBError.invalid("커서 크기가 지원 범위를 넘습니다.") }
                        let payload = try await read(length)
                        let pixelBytes = w * h * 4
                        let cursor = try CursorPseudo.decode(width: w, height: h, hotspotX: x, hotspotY: y, pixels: payload.prefix(pixelBytes), mask: payload.suffix(length - pixelBytes))
                        pending.append(.cursor(cursor))
                    }
                case RFBEncodings.raw:
                    guard let bytes = FrameLimits.rawBytes(width: w, height: h) else { throw RFBError.invalid("화면 데이터의 범위가 잘못되었습니다.") }
                    pending.append(.raw(x: x, y: y, w: w, h: h, data: try await read(bytes)))
                case RFBEncodings.copyRect:
                    let fromX = try await number(2), fromY = try await number(2)
                    pending.append(.copy(x: x, y: y, w: w, h: h, fromX: fromX, fromY: fromY))
                case RFBEncodings.zrle:
                    let length = try await number(4)
                    guard let limit = ZRLEBudget.compressedBytes(width: w, height: h), (1...limit).contains(length) else {
                        throw RFBError.invalid("화면 압축 크기가 잘못되었습니다.")
                    }
                    pending.append(.zrle(x: x, y: y, w: w, h: h, data: try await read(length)))
                default:
                    throw RFBError.invalid("지원하지 않는 화면 압축 방식입니다: \(encoding)")
                }
            } catch let error as RFBError where !error.isProtocolFailure {
                throw error
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                let message = RectangleFailure.message(encoding: encoding, x: x, y: y, width: w, height: h, underlying: detail)
                logRFB(message)
                throw RFBError.invalid(message)
            }
        }
        return pending
    }

    private func apply(_ pending: [PendingRect]) throws -> (pixelsChanged: Bool, cursor: RemoteCursor?) {
        var pixelsChanged = false
        var cursor: RemoteCursor?
        for item in pending {
            switch item {
            case .desktop(let w, let h):
                width = w
                height = h
                try allocate()
                pixelsChanged = true
            case .raw(let x, let y, let w, let h, var data):
                do {
                    guard x + w <= width, y + h <= height else { throw RFBError.invalid("화면 데이터의 범위가 잘못되었습니다.") }
                    for alpha in stride(from: 3, to: data.count, by: 4) { data[alpha] = 255 }
                    try blit(data, x: x, y: y, w: w, h: h)
                } catch { throw contextual(RFBEncodings.raw, x, y, w, h, error) }
                pixelsChanged = true
            case .copy(let x, let y, let w, let h, let fromX, let fromY):
                do { try FramebufferCopy.copy(pixels: &pixels, width: width, height: height, x: x, y: y, w: w, h: h, fromX: fromX, fromY: fromY) }
                catch { throw contextual(RFBEncodings.copyRect, x, y, w, h, error) }
                pixelsChanged = true
            case .zrle(let x, let y, let w, let h, let data):
                do {
                    guard x + w <= width, y + h <= height else { throw RFBError.invalid("화면 데이터의 범위가 잘못되었습니다.") }
                    let rgba = try inflate.decodeZRLE(data, width: w, height: h, decoder: &zrle)
                    try blit(rgba, x: x, y: y, w: w, h: h)
                } catch { throw contextual(RFBEncodings.zrle, x, y, w, h, error) }
                pixelsChanged = true
            case .cursor(let value):
                cursor = value
            }
        }
        return (pixelsChanged, cursor)
    }

    private func contextual(_ encoding: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ error: Error) -> Error {
        if let error = error as? RFBError, !error.isProtocolFailure { return error }
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let message = RectangleFailure.message(encoding: encoding, x: x, y: y, width: w, height: h, underlying: detail)
        logRFB(message)
        return RFBError.invalid(message)
    }

    private func blit(_ rgba: Data, x: Int, y: Int, w: Int, h: Int) throws {
        guard rgba.count == w * h * 4 else { throw RFBError.invalid("화면 데이터의 범위가 잘못되었습니다.") }
        for row in 0..<h {
            let start = ((y + row) * width + x) * 4
            let source = row * w * 4
            pixels.replaceSubrange(start..<(start + w * 4), with: rgba[source..<(source + w * 4)])
        }
    }

    private func allocate() throws {
        guard FrameLimits.contains(width: width, height: height) else {
            throw RFBError.invalid("지원 가능한 화면 크기를 초과했습니다.")
        }
        pixels = Data(repeating: 0, count: width * height * 4)
    }
    private func request(incremental: Bool, width requestedWidth: Int? = nil, height requestedHeight: Int? = nil) async throws {
        try await send(Data([3, incremental ? 1 : 0, 0,0,0,0] + Wire.u16(requestedWidth ?? width) + Wire.u16(requestedHeight ?? height)))
    }
    public func key(_ symbol: UInt32, down: Bool) async throws { try await send(Wire.key(symbol, down: down)) }
    public func pointer(x: Int, y: Int, buttons: UInt8) async throws {
        guard width > 0, height > 0 else { return }
        try await send(Wire.pointer(x: max(0, min(width - 1, x)), y: max(0, min(height - 1, y)), buttons: buttons))
    }
    private func number(_ count: Int) async throws -> Int { Wire.integer(try await read(count)) }
    private func reason() async throws -> String {
        let size = try await number(4)
        guard size <= 1_048_576 else { throw RFBError.invalid("서버 메시지가 너무 큽니다.") }
        return String(decoding: try await read(size), as: UTF8.self)
    }
    private func read(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard let connection else { throw RFBError.invalid("연결이 종료되었습니다.") }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: RFBError.closed) }
                }
            }
            result.append(part)
        }
        return result
    }
    private func send(_ data: Data) async throws {
        guard let connection else { throw RFBError.invalid("연결이 종료되었습니다.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
