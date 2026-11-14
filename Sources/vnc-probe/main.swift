#if os(macOS)
import Darwin
import Foundation
import RemoteCore

/// macOS-only probe. The password is read with readpassphrase and is never taken from argv or written to stdout, stderr, or the dump.
@main
enum VNCProbe {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            print(ProbeOptions.usage)
            return
        }
        do {
            let options = try ProbeOptions.parse(CommandLine.arguments)
            let dump = try options.dump.map { try ByteDump(path: $0) }
            defer { dump?.close() }
            let password = try PasswordPrompt.read()
            let stats = ProbeStats()
            var failure: Error?
            do {
                try await run(options: options, password: password, dump: dump, stats: stats)
            } catch {
                failure = error
            }
            flush(stats)
            summarize(stats)
            if failure == nil, stats.decodeErrors > 0 { failure = ProbeError.message("화면 디코드에 실패했습니다.") }
            if failure == nil, let dumpError = dump?.error { failure = ProbeError.message("덤프를 쓰지 못했습니다: \(dumpError)") }
            if let failure { throw failure }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "연결에 실패했습니다."
            FileHandle.standardError.write(Data("vnc-probe: \(text)\n".utf8))
            exit(1)
        }
    }

    private static func run(options: ProbeOptions, password: String, dump: ByteDump?, stats: ProbeStats) async throws {
        let auth = options.user.isEmpty ? "vnc" : "ard"
        note("connect \(options.host):\(options.port) auth=\(auth)")
        let advertised = options.encodings ?? RFBEncodings.advertised()
        let numbers = advertised.map { String(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) }.joined(separator: ",")
        note("SetEncodings \(numbers)")
        let client = RFBClient()
        try await client.run(host: options.host, port: options.port, username: options.user, password: password, onProgress: { message in
            note(message)
        }, onFrame: { _ in }, onReady: { name in
            stats.started = Date()
            emit("server \(name)")
        }, encodings: options.encodings, updateLimit: options.updates, onServerBytes: { data in
            stats.received += data.count
            dump?.append(data)
        }, onRectangle: { rect in
            stats.buffered.append(rect)
            if rect.error != nil { stats.decodeErrors += 1 }
        }, onUpdate: { update in
            emit(String(format: "update %d rects=%d bytes=%d time=%.6fs", update.index, stats.buffered.count, update.bytes, update.seconds))
            for rect in stats.buffered { emit(line(rect)) }
            stats.buffered.removeAll()
            stats.updates += 1
        })
    }

    private static func flush(_ stats: ProbeStats) {
        guard !stats.buffered.isEmpty else { return }
        emit("update \(stats.buffered[0].update) incomplete rects=\(stats.buffered.count)")
        for rect in stats.buffered { emit(line(rect)) }
        stats.buffered.removeAll()
    }

    private static func summarize(_ stats: ProbeStats) {
        let elapsed = max(0, Date().timeIntervalSince(stats.started))
        let seconds = max(elapsed, 0.000001)
        var text = String(format: "summary updates=%d seconds=%.3f updates/s=%.2f bytes=%d bytes/s=%.1f",
                          stats.updates, elapsed, Double(stats.updates) / seconds, stats.received, Double(stats.received) / seconds)
        if stats.decodeErrors > 0 { text += " decode_errors=\(stats.decodeErrors)" }
        emit(text)
    }

    private static func line(_ rect: RectangleDiagnostic) -> String {
        let encoding = Int32(bitPattern: UInt32(truncatingIfNeeded: rect.encoding))
        var text = String(format: "  encoding=%d x=%d y=%d w=%d h=%d bytes=%d decode=%.6fs",
                          encoding, rect.x, rect.y, rect.width, rect.height, rect.bytes, rect.decodeSeconds)
        if let error = rect.error {
            text += " error=\(error)"
            if let offset = rect.offset { text += " offset=\(offset)" }
            text += " stream=\(rect.streamOffset)"
        }
        return text
    }

    private static func emit(_ text: String) {
        print(text)
        fflush(stdout)
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
        fflush(stderr)
    }
}

private struct ProbeOptions {
    var host = ""
    var port: UInt16 = 5900
    var user = ""
    var encodings: [Int]?
    var updates: Int?
    var dump: String?
    static let usage = "usage: vnc-probe --host <address> [--port 5900] [--user <name>] [--encodings zrle,cursor,copyrect,raw,...] [--updates N] [--dump file]"

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let (flag, inline) = split(argument)
            func value() throws -> String {
                if let inline { return inline }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw ProbeError.message("\(flag) 값이 없습니다.\n\(usage)") }
                return arguments[index]
            }
            if flag.lowercased().contains("pass") {
                throw ProbeError.message("암호는 인자로 받지 않습니다. 프롬프트에 입력하세요.")
            }
            switch flag {
            case "--host": options.host = try value()
            case "--port":
                let text = try value()
                guard let port = UInt16(text), port > 0 else { throw ProbeError.message("포트를 확인해 주세요.") }
                options.port = port
            case "--user": options.user = try value()
            case "--encodings":
                let text = try value()
                guard let parsed = RFBEncodings.parse(list: text) else { throw ProbeError.message("알 수 없는 인코딩입니다: \(text)") }
                options.encodings = parsed
            case "--updates":
                let text = try value()
                guard let count = Int(text), count > 0 else { throw ProbeError.message("갱신 횟수는 1 이상의 정수여야 합니다.") }
                options.updates = count
            case "--dump":
                let path = try value()
                guard !path.isEmpty else { throw ProbeError.message("덤프 파일 경로가 비어 있습니다.") }
                options.dump = path
            default:
                throw ProbeError.message("알 수 없는 인자입니다: \(argument)\n\(usage)")
            }
            index += 1
        }
        guard !options.host.isEmpty else { throw ProbeError.message("호스트가 필요합니다.\n\(usage)") }
        return options
    }

    private static func split(_ argument: String) -> (String, String?) {
        guard let eq = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<eq]), String(argument[argument.index(after: eq)...]))
    }
}

private enum ProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private final class ProbeStats: @unchecked Sendable {
    var received = 0
    var updates = 0
    var decodeErrors = 0
    var buffered: [RectangleDiagnostic] = []
    var started = Date()
}

private final class ByteDump: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var error: String?
    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw ProbeError.message("덤프 파일을 만들지 못했습니다.")
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    func append(_ data: Data) {
        guard error == nil, !data.isEmpty else { return }
        do { try handle.write(contentsOf: data) }
        catch { self.error = error.localizedDescription }
    }
    func close() { try? handle.close() }
}

private enum PasswordPrompt {
    static func read() throws -> String {
        let capacity = 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer {
            _ = memset_s(buffer, capacity, 0, capacity)
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }
        guard readpassphrase("Password: ", buffer, capacity, 0) != nil else {
            throw ProbeError.message("암호를 터미널에서 읽지 못했습니다.")
        }
        let password = String(cString: buffer)
        guard !password.isEmpty else { throw ProbeError.message("암호가 비어 있습니다.") }
        return password
    }
}
#else
import Foundation

@main
enum VNCProbe {
    static func main() {
        FileHandle.standardError.write(Data("vnc-probe는 macOS에서만 실행됩니다.\n".utf8))
        exit(1)
    }
}
#endif
