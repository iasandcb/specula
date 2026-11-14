#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import IOKit
import Security
import DisplaySupport

@MainActor
final class DisplayHelper: NSObject, NSApplicationDelegate {
    private var listener: HTTPListener?
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var codeItem: NSMenuItem!
    private var code = ""
    private var codeDeadline = Date.distantPast
    private var failedPairs = 0
    private var pairWindow = Date()
    private var token = UUID().uuidString + UUID().uuidString
    private var lease = DisplayLease()
    private var original: CGDisplayMode?
    private var originalDisplay: CGDirectDisplayID?
    private var originalRotation: Int?
    private var commandedRotation: Int?
    private var timer: Timer?
    private var address = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Specula 화면 설정")
        let menu = NSMenu()
        menu.addItem(withTitle: "Specula 화면 설정", action: nil, keyEquivalent: "")
        codeItem = menu.addItem(withTitle: "", action: #selector(showPairing), keyEquivalent: "")
        codeItem.target = self
        let renew = menu.addItem(withTitle: "새 연결 코드 표시", action: #selector(newCode), keyEquivalent: ""); renew.target = self
        let restore = menu.addItem(withTitle: "원래 해상도로 복원", action: #selector(restoreAction), keyEquivalent: ""); restore.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        item.menu = menu
        do {
            address = try tailscaleAddress()
            let listener = try HTTPListener(port: 5901) { [weak self] connection in
                let request = HTTPRequestReader(connection: connection) { request in
                    Task { @MainActor in self?.handle(request, connection: connection) }
                }
                request.start()
            }
            self.listener = listener; listener.start()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.lease.expired(now: Date()) else { return }
                    try? self.restore()
                }
            }
            newCode()
        } catch { showMessage(error.localizedDescription) }
    }
    func verifyDisplayChange() throws {
        let before = try snapshot()
        guard let target = modes().first(where: { $0.width == 1280 && $0.height == 720 && $0.pixelWidth == 1280 }) else {
            throw HelperError.message("1280 × 720 모드를 사용할 수 없어 실화면 검사를 생략했습니다.")
        }
        defer { try? restore() }
        let changed = try change(UInt32(bitPattern: target.ioDisplayModeID))
        guard changed.current.width == 1280, changed.current.height == 720 else { throw HelperError.message("해상도 변경 확인에 실패했습니다.") }
        try restore()
        let after = try snapshot()
        guard before.current.id == after.current.id else { throw HelperError.message("해상도 복원 확인에 실패했습니다.") }
        print("Verified 1280 × 720 change and original-mode restoration.")
    }
    private func tailscaleAddress() throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
        process.arguments = ["ip", "-4"]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard process.terminationStatus == 0, parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]), parts.allSatisfy({ (0...255).contains($0) }) else {
            throw HelperError.message("테일스케일을 켠 뒤 보조 앱을 다시 실행해 주세요.")
        }
        return value
    }
    @objc private func newCode() {
        code = String(format: "%06d", Int.random(in: 0...999999))
        codeDeadline = Date().addingTimeInterval(300); failedPairs = 0
        codeItem.title = "연결 코드: \(code) (5분)"; showPairing()
    }
    @objc private func showPairing() {
        let text = "아이폰의 Specula → 해상도 설정에서\n아래 연결 코드를 입력하세요.\n\n\(code)\n\n맥 주소: \(address)\n코드는 5분 동안 유효합니다.\n접속 종료 또는 연결 유실 시 원래 해상도로 복원합니다."
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 17); label.alignment = .center
        label.frame = NSRect(x: 24, y: 24, width: 372, height: 230)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Specula · 해상도 연결"; window.contentView?.addSubview(label)
        window.isReleasedWhenClosed = false; window.center(); self.window?.close(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showMessage(_ text: String) { NSLog("Specula Display: %@", text); let alert = NSAlert(); alert.messageText = text; alert.runModal() }
    private func modes() -> [CGDisplayMode] {
        // Low-resolution duplicates (640×480, 720×450, non-HiDPI 1280×800, …) stay in the list.
        (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() && DisplayModes.fits(info($0)) }
    }
    private func info(_ mode: CGDisplayMode) -> RemoteDisplayMode {
        RemoteDisplayMode(id: UInt32(bitPattern: mode.ioDisplayModeID), width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight)
    }
    private func snapshot() throws -> DisplaySnapshot {
        guard let current = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { throw HelperError.message("현재 화면 정보를 읽지 못했습니다.") }
        return DisplaySnapshot(current: info(current), modes: DisplayModes.offered(modes().map(info)))
    }
    private func change(_ id: UInt32) throws -> DisplaySnapshot {
        let display = CGMainDisplayID()
        guard let target = modes().first(where: { UInt32(bitPattern: $0.ioDisplayModeID) == id }), let current = CGDisplayCopyDisplayMode(display) else { throw HelperError.message("이 맥에서 사용할 수 없는 해상도입니다.") }
        if original == nil { original = current; originalDisplay = display }
        guard CGDisplaySetDisplayMode(display, target, nil) == .success else {
            if lease.originalModeID == nil { original = nil; originalDisplay = nil }
            throw HelperError.message("맥이 해상도 변경을 허용하지 않았습니다.")
        }
        lease.changed(from: UInt32(bitPattern: current.ioDisplayModeID), now: Date())
        return try snapshot()
    }
    private func restore() throws {
        if let originalRotation {
            _ = MainDisplayProbe.apply(degrees: originalRotation)
            commandedRotation = originalRotation
            self.originalRotation = nil
        }
        guard let original, let display = originalDisplay else { lease.clear(); return }
        guard CGDisplaySetDisplayMode(display, original, nil) == .success else { throw HelperError.message("원래 해상도를 복원하지 못했습니다. 맥 디스플레이 설정에서 확인해 주세요.") }
        self.original = nil; originalDisplay = nil; lease.clear()
    }
    private func rotationState() -> DisplayRotation {
        let display = CGMainDisplayID()
        let degrees = MainDisplayProbe.sensedDegrees(display) ?? commandedRotation ?? 0
        return DisplayRotation(degrees: degrees, supported: MainDisplayProbe.framebuffer(for: display) != nil)
    }
    private func setRotation(_ degrees: Int) throws -> DisplayRotation {
        guard let angle = DisplayRotationAngle.normalized(degrees) else { throw HelperError.message("회전 각도는 0, 90, 180, 270만 사용할 수 있습니다.") }
        let display = CGMainDisplayID()
        let before = MainDisplayProbe.sensedDegrees(display) ?? commandedRotation ?? 0
        let applied = MainDisplayProbe.apply(degrees: angle, display: display)
        guard applied.supported else { return applied }
        if originalRotation == nil, applied.degrees != before { originalRotation = before }
        commandedRotation = applied.degrees
        return applied
    }
    @objc private func restoreAction() { do { try restore() } catch { showMessage(error.localizedDescription) } }
    @objc private func quit() { do { try restore(); NSApp.terminate(nil) } catch { showMessage(error.localizedDescription) } }
    func applicationWillTerminate(_ notification: Notification) { try? restore() }
    private func handle(_ request: HTTPRequest, connection: HTTPConnection) {
        do {
            if request.path == "/pair", request.method == "POST" {
                if Date().timeIntervalSince(pairWindow) > 60 { failedPairs = 0; pairWindow = Date() }
                guard failedPairs < 5 else { reply(connection, status: 429, value: DisplayFailure("잠시 후 다시 시도해 주세요.")); return }
                let input = try JSONDecoder().decode(PairDisplayRequest.self, from: request.body)
                guard Date() < codeDeadline, input.code == code else {
                    failedPairs += 1; reply(connection, status: 401, value: DisplayFailure("연결 코드가 틀렸거나 만료되었습니다.")); return
                }
                codeDeadline = .distantPast; codeItem.title = "아이폰 연결됨"
                reply(connection, value: PairDisplayResponse(token: token)); return
            }
            guard request.authorization == "Bearer \(token)" else { reply(connection, status: 401, value: DisplayFailure("맥의 연결 코드로 다시 연결해 주세요.")); return }
            switch (request.method, request.path) {
            case ("GET", "/modes"): reply(connection, value: try snapshot())
            case ("POST", "/mode"):
                let input = try JSONDecoder().decode(ChangeDisplayRequest.self, from: request.body)
                reply(connection, value: try change(input.modeID))
            case ("POST", "/heartbeat"):
                lease.renew(now: Date()); reply(connection, value: ["ok": true])
            case ("POST", "/restore"):
                try restore(); reply(connection, value: try snapshot())
            case ("GET", "/rotation"): reply(connection, value: rotationState())
            case ("POST", "/rotation"):
                let input = try JSONDecoder().decode(SetDisplayRotation.self, from: request.body)
                reply(connection, value: try setRotation(input.degrees))
            default: reply(connection, status: 404, value: DisplayFailure("알 수 없는 요청입니다."))
            }
        } catch { reply(connection, status: 400, value: DisplayFailure(error.localizedDescription)) }
    }
    private func reply<T: Encodable>(_ connection: HTTPConnection, status: Int = 200, value: T) {
        let body = (try? JSONEncoder().encode(value)) ?? Data()
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
/// fb-rotate mechanism: `IOServiceRequestProbe` with `kIOFBSetTransform` (0x400) and the quadrant in bits 7–8.
/// External panels on a MacBook Pro accept this; the built-in panel often rejects it, which is reported as unsupported.
private enum MainDisplayProbe {
    static func sensedDegrees(_ display: CGDirectDisplayID) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayRotation") else { return nil }
        let function = unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID) -> Double).self)
        return DisplayRotationAngle.normalized(Int(function(display).rounded()))
    }

    static func apply(degrees: Int, display: CGDirectDisplayID = CGMainDisplayID()) -> DisplayRotation {
        let current = sensedDegrees(display) ?? 0
        guard let options = DisplayRotationAngle.probeOptions(degrees: degrees), let service = framebuffer(for: display) else {
            return DisplayRotation(degrees: current, supported: false)
        }
        defer { IOObjectRelease(service) }
        guard IOServiceRequestProbe(service, options) == KERN_SUCCESS else {
            return DisplayRotation(degrees: current, supported: false)
        }
        return DisplayRotation(degrees: sensedDegrees(display) ?? degrees, supported: true)
    }

    static func framebuffer(for display: CGDirectDisplayID) -> io_service_t? {
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { return nil }
            if owns(service, vendor: vendor, model: model, serial: serial) { return service }
            IOObjectRelease(service)
        }
    }

    private static func owns(_ framebuffer: io_service_t, vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        if sameDisplay(framebuffer, vendor: vendor, model: model, serial: serial) { return true }
        var children: io_iterator_t = 0
        let opened = "IOService".withCString { IORegistryEntryGetChildIterator(framebuffer, $0, &children) }
        guard opened == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(children) }
        while true {
            let child = IOIteratorNext(children)
            if child == 0 { return false }
            defer { IOObjectRelease(child) }
            if sameDisplay(child, vendor: vendor, model: model, serial: serial) { return true }
        }
    }

    private static func sameDisplay(_ entry: io_registry_entry_t, vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        guard let entryVendor = number(entry, "DisplayVendorID"), let entryModel = number(entry, "DisplayProductID") else { return false }
        return entryVendor == vendor && entryModel == model && (number(entry, "DisplaySerialNumber") ?? 0) == serial
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        guard let property = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (property as? NSNumber)?.uint32Value
    }
}

private enum HelperError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
private final class HTTPListener: @unchecked Sendable {
    private let descriptor: Int32
    private let handler: (HTTPConnection) -> Void
    init(port: UInt16, handler: @escaping (HTTPConnection) -> Void) throws {
        self.handler = handler
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HelperError.message("수신 소켓을 만들지 못했습니다.") }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor); throw HelperError.message("해상도 설정 포트 5901을 열지 못했습니다.")
        }
    }
    func start() {
        DispatchQueue.global().async {
            while true {
                var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(self.descriptor, $0, &length) }
                }
                guard client >= 0 else { return }
                var ip = address.sin_addr
                var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                _ = inet_ntop(AF_INET, &ip, &bytes, socklen_t(bytes.count))
                guard DisplayPeer.isAllowed(String(cString: bytes)) else { Darwin.close(client); continue }
                self.handler(HTTPConnection(descriptor: client))
            }
        }
    }
}
private final class HTTPConnection: @unchecked Sendable {
    enum Completion { case contentProcessed((Error?) -> Void) }
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; if !closed { closed = true; Darwin.close(descriptor) } }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, Any?, Bool, Error?) -> Void) {
        DispatchQueue.global().async {
            self.lock.lock()
            guard !self.closed else { self.lock.unlock(); completion(nil, nil, true, nil); return }
            var bytes = [UInt8](repeating: 0, count: maximumLength)
            let count = Darwin.recv(self.descriptor, &bytes, maximumLength, 0)
            self.lock.unlock()
            if count > 0 { completion(Data(bytes.prefix(count)), nil, false, nil) }
            else { completion(nil, nil, true, count < 0 ? HelperError.message("요청 수신 시간이 초과되었습니다.") : nil) }
        }
    }
    func send(content: Data, completion: Completion) {
        DispatchQueue.global().async {
            self.lock.lock()
            var success = !self.closed
            if success {
                content.withUnsafeBytes { buffer in
                    var sent = 0
                    while sent < buffer.count {
                        let count = Darwin.send(self.descriptor, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                        if count <= 0 { success = false; break }
                        sent += count
                    }
                }
            }
            self.lock.unlock()
            if case .contentProcessed(let callback) = completion { callback(success ? nil : HelperError.message("응답을 보내지 못했습니다.")) }
        }
    }
}
private struct HTTPRequest { let method: String; let path: String; let authorization: String; let body: Data }
private final class HTTPRequestReader: @unchecked Sendable {
    let connection: HTTPConnection
    let completion: (HTTPRequest) -> Void
    var buffer = Data()
    init(connection: HTTPConnection, completion: @escaping (HTTPRequest) -> Void) { self.connection = connection; self.completion = completion }
    func start() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { self.connection.cancel() }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, error in
            guard error == nil, let data, !data.isEmpty else { self.connection.cancel(); return }
            self.buffer.append(data)
            guard self.buffer.count <= 8192 else { self.connection.cancel(); return }
            if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: self.buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines.first?.split(separator: " ") ?? []
                guard first.count == 3 else { self.connection.cancel(); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { self.connection.cancel(); return }
                    let name = parts[0].lowercased()
                    guard headers[name] == nil else { self.connection.cancel(); return }
                    headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil else { self.connection.cancel(); return }
                let length = headers["content-length"].flatMap(Int.init) ?? 0
                guard (0...4096).contains(length) else { self.connection.cancel(); return }
                let body = self.buffer[boundary.upperBound...]
                if body.count >= length {
                    self.completion(HTTPRequest(method: String(first[0]), path: String(first[1]), authorization: headers["authorization"] ?? "", body: Data(body.prefix(length))))
                    return
                }
            }
            if done { self.connection.cancel() } else { self.receive() }
        }
    }
}
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--verify-display") {
        do { try DisplayHelper().verifyDisplayChange(); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    let app = NSApplication.shared
    let delegate = DisplayHelper()
    app.delegate = delegate
    app.run()
}
#endif
