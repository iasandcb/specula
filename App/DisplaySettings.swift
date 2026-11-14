import SwiftUI
import Security

@MainActor
final class DisplayController: ObservableObject {
    @Published var snapshot: DisplaySnapshot?
    @Published var error = ""
    @Published var busy = false
    @Published var paired = false
    @Published var portrait = false
    private var preferredModeID: UInt32?
    private var rotateAfterPairing = false
    var attemptedRotation = -1
    private var host = ""
    private var token: String?
    private var heartbeat: Task<Void, Never>?
    private var active = false

    func configure(host: String) {
        self.host = host; token = readToken(host: host); paired = token != nil
        snapshot = nil; error = ""
    }
    func beginSession() {
        active = true
        startHeartbeat()
        Task { await refreshRotation() }
    }
    func endSession() {
        active = false; heartbeat?.cancel(); heartbeat = nil
        preferredModeID = nil
        portrait = false
        guard token != nil else { return }
        let host = self.host, token = self.token
        Task { try? await Self.request(path: "/restore", body: Data("{}".utf8), host: host, token: token, timeout: DisplayHTTP.listTimeout) }
    }
    private func startHeartbeat() {
        heartbeat?.cancel()
        guard active, token != nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    _ = try await Self.request(path: "/heartbeat", body: Data("{}".utf8), host: self.host, token: self.token, timeout: DisplayHTTP.listTimeout)
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch is CancellationError { return }
                catch DisplayCallError.pairingRequired {
                    self.requirePairing()
                    return
                }
                catch {
                    self.error = DisplayHTTP.connectionLost
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
        }
    }
    func pair(code: String) async {
        await perform {
            let result = try await Self.request(path: "/pair", body: JSONEncoder().encode(PairDisplayRequest(code: code)), host: self.host, token: nil, timeout: DisplayHTTP.listTimeout, isPairing: true)
            let response = try JSONDecoder().decode(PairDisplayResponse.self, from: result)
            try self.saveToken(response.token)
            self.token = response.token; self.paired = true; self.startHeartbeat()
            try await self.load()
        }
        guard paired, rotateAfterPairing else { return }
        rotateAfterPairing = false
        await rotateMainDisplay()
    }
    func refresh() async { await perform { try await self.load() } }
    private func load() async throws {
        snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: await Self.request(path: "/modes", host: host, token: token, timeout: DisplayHTTP.listTimeout))
    }
    func change(_ id: UInt32) async {
        guard active else { error = "먼저 맥에 접속해 주세요."; return }
        await perform {
            let data = try await Self.request(path: "/mode", body: JSONEncoder().encode(ChangeDisplayRequest(modeID: id)), host: host, token: token, timeout: DisplayHTTP.listTimeout)
            self.snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: data)
            self.preferredModeID = id
        }
    }
    func reapplyPreferredMode() async {
        guard let mode = DisplayReconnect.mode(reconnecting: true, selected: preferredModeID) else { return }
        await change(mode)
    }
    func cancelPendingRotation() { rotateAfterPairing = false }
    func togglePortrait() async {
        guard paired else {
            rotateAfterPairing = true
            error = "세로 모드를 쓰려면 먼저 맥의 연결 코드를 입력하세요."
            return
        }
        await rotateMainDisplay()
    }
    private func rotateMainDisplay() async {
        await perform {
            let current = try JSONDecoder().decode(DisplayRotation.self, from: await Self.request(path: "/rotation", host: host, token: token, timeout: DisplayHTTP.rotationTimeout))
            let next = DisplayRotationAngle.portraitToggle(from: current.degrees)
            self.attemptedRotation = next
            let body = try JSONEncoder().encode(SetDisplayRotation(degrees: next))
            let updated = try JSONDecoder().decode(DisplayRotation.self, from: await Self.request(path: "/rotation", body: body, host: host, token: token, timeout: DisplayHTTP.rotationTimeout))
            guard updated.supported else { throw RFBError.invalid("이 디스플레이의 화면을 회전하지 못했습니다.") }
            self.portrait = DisplayOrientationCheck.isPortrait(updated.degrees)
        }
    }
    func noteRotationApplied() {
        error = ""
        portrait = DisplayOrientationCheck.isPortrait(attemptedRotation)
    }
    private func refreshRotation() async {
        guard paired else { return }
        do {
            let data = try await Self.request(path: "/rotation", host: host, token: token, timeout: DisplayHTTP.listTimeout)
            let value = try JSONDecoder().decode(DisplayRotation.self, from: data)
            portrait = DisplayOrientationCheck.isPortrait(value.degrees)
        } catch DisplayCallError.pairingRequired {
            requirePairing()
        } catch { return }
    }
    func restore() async {
        await perform {
            let data = try await Self.request(path: "/restore", body: Data("{}".utf8), host: host, token: token, timeout: DisplayHTTP.rotationTimeout)
            self.snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: data)
            self.preferredModeID = nil
        }
    }
    func resetPairing() { requirePairing() }
    private func requirePairing() {
        let remembered = host
        token = nil
        paired = false
        rotateAfterPairing = false
        heartbeat?.cancel()
        heartbeat = nil
        snapshot = nil
        busy = false
        error = ""
        if !remembered.isEmpty { deleteToken(remembered) }
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = ""
        defer { busy = false }
        do { try await action() }
        catch DisplayCallError.pairingRequired { requirePairing() }
        catch { self.error = error.localizedDescription }
    }
    /// URLSession work stays off the main actor. The delegate queue is not the main queue.
    private nonisolated static func request(path: String, body: Data? = nil, host: String, token: String?, timeout: TimeInterval, isPairing: Bool = false) async throws -> Data {
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = 5901; components.path = path
        guard let url = components.url else { throw RFBError.invalid("맥 주소를 확인해 주세요.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await DisplayHTTPSession.data(for: request)
        switch DisplayHTTP.interpret(status: (response as? HTTPURLResponse)?.statusCode, body: data, isPairing: isPairing) {
        case .success(let body): return body
        case .failure(let error): throw error
        }
    }
    private func keyQuery(host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ias.specula.display", kSecAttrAccount as String: host]
    }
    private func readToken(host: String) -> String? {
        var query = keyQuery(host: host); query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func saveToken(_ value: String) throws {
        let query = keyQuery(host: host)
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw RFBError.invalid("연결 정보를 안전하게 저장하지 못했습니다.") }
    }
    private func deleteToken(_ host: String) {
        SecItemDelete(keyQuery(host: host) as CFDictionary)
    }
}

private enum DisplayHTTPSession {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = DisplayHTTP.listTimeout
        configuration.timeoutIntervalForResource = DisplayHTTP.rotationTimeout + 1
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.name = "specula.display.http"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }()

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

struct DisplaySettingsView: View {
    @ObservedObject var controller: DisplayController
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if !controller.paired {
                    Section("맥 보조 앱 연결") {
                        Text("맥에서 ‘Specula Display’를 실행한 뒤 표시된 6자리 코드를 입력하세요.")
                        TextField("6자리 연결 코드", text: $code)
                            .keyboardType(.numbersAndPunctuation)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($codeFocused)
                            .submitLabel(.go)
                            .onSubmit(submitCode)
                            .onChange(of: code) { _, value in
                                let digits = String(value.filter(\.isNumber).prefix(6))
                                if digits != value { code = digits }
                            }
                            .task {
                                // The remote canvas resigns when this sheet is presented. Retry until that handoff finishes.
                                for delay in [UInt64(0), 50, 250, 700] {
                                    if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                                    if Task.isCancelled { return }
                                    codeFocused = true
                                }
                            }
                        Button("연결", action: submitCode)
                            .disabled(code.count != 6 || controller.busy)
                        if controller.busy, controller.error.isEmpty { ProgressView() }
                        if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
                    }
                } else if let snapshot = controller.snapshot {
                    Section {
                        Text("현재: \(snapshot.current.title)")
                        Text("접속 종료 시 원래대로 복원합니다. 연결이 끊기면 약 1분 이내에 복원합니다.").font(.footnote).foregroundStyle(.secondary)
                        Button("원래 해상도로 복원") { Task { await controller.restore() } }
                    }
                    Section {
                        // The helper already chose the modes, including widths under 800. Apply the mode id as sent.
                        ForEach(snapshot.modes) { mode in
                            Button { Task { await controller.change(mode.id) } } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(mode.title)
                                        Text("전송 \(mode.pixelWidth) × \(mode.pixelHeight) 픽셀").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if mode.id == snapshot.current.id { Image(systemName: "checkmark") }
                                }
                            }.disabled(controller.busy)
                        }
                    } header: { Text("맥 화면 해상도") } footer: {
                        Text("작은 해상도는 글자와 버튼을 크게 표시합니다. 1280 × 720 또는 1600 × 900부터 시험해 보세요. 맥 화면에도 적용됩니다.")
                    }
                    if controller.busy, controller.error.isEmpty { ProgressView("불러오는 중…") }
                    Button("목록 새로 고침") { Task { await controller.refresh() } }.disabled(controller.busy)
                    Button("연결 코드 다시 입력") { controller.resetPairing() }
                    if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
                } else {
                    Section {
                        if controller.error.isEmpty {
                            ProgressView()
                            Text("해상도 목록을 불러오는 중…").foregroundStyle(.secondary)
                        } else {
                            Text(controller.error).foregroundStyle(.red)
                            Button("다시 시도") { Task { await controller.refresh() } }.disabled(controller.busy)
                            Button("연결 코드 다시 입력") { controller.resetPairing() }
                        }
                    }
                }
            }
            .navigationTitle("맥 해상도")
            .toolbar { Button("완료") { dismiss() } }
            .task { if controller.paired { await controller.refresh() } }
        }
    }
    private func submitCode() {
        guard code.count == 6, !controller.busy else { return }
        let entered = code
        code = ""
        Task { await controller.pair(code: entered) }
    }
}
