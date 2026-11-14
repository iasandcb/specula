import SwiftUI
import Security

@MainActor
final class DisplayController: ObservableObject {
    @Published var snapshot: DisplaySnapshot?
    @Published var error = ""
    @Published var busy = false
    @Published var paired = false
    private var preferredModeID: UInt32?
    private var host = ""
    private var token: String?
    private var heartbeat: Task<Void, Never>?
    private var active = false
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    func configure(host: String) {
        self.host = host; token = readToken(host: host); paired = token != nil
        snapshot = nil; error = ""
    }
    func beginSession() { active = true; startHeartbeat() }
    func endSession() {
        active = false; heartbeat?.cancel(); heartbeat = nil
        preferredModeID = nil
        guard token != nil else { return }
        let host = self.host, token = self.token
        Task { try? await request(path: "/restore", body: Data("{}".utf8), host: host, token: token) }
    }
    private func startHeartbeat() {
        heartbeat?.cancel()
        guard active, token != nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    _ = try await self.request(path: "/heartbeat", body: Data("{}".utf8))
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch is CancellationError { return }
                catch {
                    self.error = "해상도 보조 앱과의 연결이 끊겼습니다. 변경한 해상도는 약 1분 이내에 복원됩니다."
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
        }
    }
    func pair(code: String) async {
        await perform {
            let result = try await self.request(path: "/pair", body: JSONEncoder().encode(PairDisplayRequest(code: code)))
            let response = try JSONDecoder().decode(PairDisplayResponse.self, from: result)
            try self.saveToken(response.token)
            self.token = response.token; self.paired = true; self.startHeartbeat()
            try await self.load()
        }
    }
    func refresh() async { await perform { try await self.load() } }
    private func load() async throws {
        snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: await request(path: "/modes"))
    }
    func change(_ id: UInt32) async {
        guard active else { error = "먼저 맥에 접속해 주세요."; return }
        await perform {
            let data = try await self.request(path: "/mode", body: JSONEncoder().encode(ChangeDisplayRequest(modeID: id)))
            self.snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: data)
            self.preferredModeID = id
        }
    }
    func reapplyPreferredMode() async {
        guard let mode = DisplayReconnect.mode(reconnecting: true, selected: preferredModeID) else { return }
        await change(mode)
    }
    func restore() async {
        await perform {
            let data = try await self.request(path: "/restore", body: Data("{}".utf8))
            self.snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: data)
            self.preferredModeID = nil
        }
    }
    func resetPairing() { token = nil; paired = false; heartbeat?.cancel(); snapshot = nil }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = ""
        defer { busy = false }
        do { try await action() }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    private func request(path: String, body: Data? = nil, host overrideHost: String? = nil, token overrideToken: String? = nil) async throws -> Data {
        let host = overrideHost ?? self.host
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = 5901; components.path = path
        guard let url = components.url else { throw RFBError.invalid("맥 주소를 확인해 주세요.") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = overrideToken ?? self.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(DisplayFailure.self, from: data)
            throw RFBError.invalid(failure?.message ?? "맥의 해상도 보조 앱에 연결할 수 없습니다.")
        }
        return data
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
                    }
                } else {
                    if let snapshot = controller.snapshot {
                        Section {
                            Text("현재: \(snapshot.current.title)")
                            Text("접속 종료 시 원래대로 복원합니다. 연결이 끊기면 약 1분 이내에 복원합니다.").font(.footnote).foregroundStyle(.secondary)
                            Button("원래 해상도로 복원") { Task { await controller.restore() } }
                        }
                        Section {
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
                    }
                    Button("목록 새로 고침") { Task { await controller.refresh() } }.disabled(controller.busy)
                    Button("연결 코드 다시 입력") { controller.resetPairing() }
                }
                if controller.busy { ProgressView() }
                if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
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
