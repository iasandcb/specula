import Foundation
import Network

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
    private let queue = DispatchQueue(label: "MacRemote.RFB")
    public init() {}

    public func close() { connection?.cancel(); connection = nil }

    public func run(host: String, port: UInt16, username: String = "", password: String,
                    onProgress: @escaping @Sendable (String) -> Void = { _ in },
                    onFrame: @escaping @Sendable (Frame) -> Void,
                    onReady: @escaping @Sendable (String) -> Void) async throws {
        guard connection == nil else { throw RFBError.invalid("이미 연결 중입니다.") }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RFBError.invalid("포트를 확인해 주세요.") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
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
        // Prefer lossless ZRLE; servers may still choose Raw. Keep resize notifications.
        try await send(Data([2,0,0,3] + Wire.u32(16) + Wire.u32(0) + Wire.u32(0xffffff21)))
        handshakeDeadline.cancel()
        onProgress("첫 화면을 받는 중…")
        onReady(name)
        try await request(incremental: false)
        var zrle: ZRLEDecoder?
        while !Task.isCancelled {
            let type = try await number(1)
            switch type {
            case 0:
                _ = try await read(1)
                let count = try await number(2)
                var resized = false
                for _ in 0..<count {
                    let x = try await number(2), y = try await number(2)
                    let w = try await number(2), h = try await number(2)
                    let encoding = try await number(4)
                    if encoding == 0xffffff21 {
                        width = w; height = h; try allocate(); resized = true
                    } else if encoding == 0 || encoding == 16 {
                        guard w > 0, h > 0, x + w <= width, y + h <= height else { throw RFBError.invalid("화면 데이터의 범위가 잘못되었습니다.") }
                        var rect: Data
                        if encoding == 16 {
                            let length = try await number(4)
                            guard length > 0, length <= ZRLEDecoder.maximumCompressedLength else {
                                throw RFBError.invalid("ZRLE 압축 데이터가 허용 크기를 초과했습니다.")
                            }
                            let compressed = try await read(length)
                            let decoder: ZRLEDecoder
                            if let existing = zrle { decoder = existing }
                            else { decoder = try ZRLEDecoder(); zrle = decoder }
                            rect = try decoder.decode(compressed, width: w, height: h)
                        } else {
                            rect = try await read(w * h * 4)
                            for alpha in stride(from: 3, to: rect.count, by: 4) { rect[alpha] = 255 }
                        }
                        for row in 0..<h {
                            let start = ((y + row) * width + x) * 4
                            pixels.replaceSubrange(start..<(start + w * 4), with: rect[(row * w * 4)..<((row + 1) * w * 4)])
                        }
                    } else { throw RFBError.invalid("지원하지 않는 화면 압축 방식입니다: \(encoding)") }
                }
                onFrame(Frame(width: width, height: height, rgba: pixels))
                try await request(incremental: !resized)
            case 2: break // Bell
            case 3:
                _ = try await read(3)
                _ = try await reason() // Clipboard is deliberately not applied locally.
            default: throw RFBError.invalid("지원하지 않는 서버 메시지입니다: \(type)")
            }
        }
    }

    private func allocate() throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
            throw RFBError.invalid("지원 가능한 화면 크기를 초과했습니다.")
        }
        pixels = Data(repeating: 0, count: width * height * 4)
    }
    private func request(incremental: Bool) async throws {
        try await send(Data([3, incremental ? 1 : 0, 0,0,0,0] + Wire.u16(width) + Wire.u16(height)))
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
                    else { continuation.resume(throwing: RFBError.invalid(complete ? "맥이 연결을 종료했습니다." : "데이터를 받지 못했습니다.")) }
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
