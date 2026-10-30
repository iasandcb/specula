import SwiftUI

@main
struct MacRemoteApp: App {
    var body: some Scene { WindowGroup { RemoteView() } }
}

@MainActor
final class Session: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "맥에 연결할 준비가 되었습니다"
    @Published var active = false
    @Published var ready = false
    @Published var optionHeld = false
    let display = DisplayController()
    private var client: RFBClient?
    private var task: Task<Void, Never>?
    private var input: Task<Void, Never>?
    private var generation = UUID()

    func toggleOption() {
        guard ready else { return }
        optionHeld.toggle(); key(0xffe7, down: optionHeld)
    }
    func connect(host: String, port: String, username: String, password: String) {
        guard !active else { return }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let port = UInt16(port), port > 0 else {
            status = "맥 주소와 포트(1~65535)를 확인해 주세요."; return
        }
        display.configure(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = UUID(); generation = id
        let client = RFBClient(); self.client = client
        active = true; status = "맥에 연결 중…"
        task = Task { [self] in
            do {
                try await client.run(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, username: username, password: password, onProgress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.status = progress
                    }
                }, onFrame: { frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        let provider = CGDataProvider(data: frame.rgba as CFData)!
                        if let cg = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                            self.image = UIImage(cgImage: cg)
                            self.status = "맥에 연결됨"
                        }
                    }
                }, onReady: { name in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.ready = true; self.status = name; self.display.beginSession()
                    }
                })
            } catch {
                guard generation == id else { return }
                status = error.localizedDescription
            }
            guard generation == id else { return }
            active = false; ready = false; optionHeld = false; image = nil; display.endSession()
        }
    }
    func disconnect() {
        display.endSession()
        generation = UUID(); task?.cancel(); input?.cancel()
        if let client { Task { await client.close() } }
        client = nil; active = false; ready = false; optionHeld = false; image = nil; status = "연결을 종료했습니다"
    }
    private func enqueue(_ operation: @escaping (RFBClient) async throws -> Void) {
        guard ready, let client else { return }
        let previous = input
        input = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do { try await operation(client) }
            catch { self?.status = error.localizedDescription }
        }
    }
    func key(_ symbol: UInt32, down: Bool) { enqueue { try await $0.key(symbol, down: down) } }
    func stroke(_ symbol: UInt32) { enqueue { client in
        try await client.key(symbol, down: true); try await client.key(symbol, down: false)
    } }
    func pointer(_ point: CGPoint, buttons: UInt8) { enqueue { try await $0.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons) } }
}

struct RemoteView: View {
    @StateObject private var session = Session()
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = "5900"
    @AppStorage("username") private var username = ""
    @State private var password = ""
    @State private var keyboard = true
    @State private var fillScreen = false
    @State private var displaySettings = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var phase
    private var fullScreen: Bool { session.active && (verticalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .pad) }
    var body: some View {
        NavigationStack {
            if fullScreen {
                ScreenSurface(image: session.image, enabled: session.ready, fill: fillScreen, optionHeld: session.optionHeld, key: session.key, pointer: session.pointer)
                    .background(.black)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Menu {
                            Button(session.optionHeld ? "⌥ Option 끄기" : "⌥ Option 켜기") { session.toggleOption() }
                            Button("맥 해상도") { displaySettings = true }
                            Button(fillScreen ? "전체 화면 보기" : "화면 채우기") { fillScreen.toggle() }
                            Button("입력기 전환") {
                                session.key(0xffe3, down: true); session.stroke(32); session.key(0xffe3, down: false)
                            }
                            Button("연결 종료", role: .destructive) { session.disconnect() }
                        } label: {
                            Image(systemName: "ellipsis").font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }.padding(8)
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .statusBarHidden()
                    .persistentSystemOverlays(.hidden)
            } else {

            VStack(spacing: 12) {
                if !session.active {
                    Form {
                        Section("접속할 맥") {
                            TextField("IP 주소 또는 Mac.local", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("포트", text: $port).keyboardType(.numberPad)
                            TextField("맥 사용자 이름 (선택)", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil)
                            SecureField(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VNC 암호" : "맥 로그인 암호", text: $password)
                                // Prevent iOS from treating remote-host credentials as an app login.
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section {
                            Button("맥에 연결") { session.connect(host: host, port: port, username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password); password = "" }
                                .disabled(host.isEmpty || password.isEmpty)
                        } footer: {
                            Text("맥의 화면 공유를 켜고, 맥 사용자 이름과 로그인 암호를 입력하세요. 사용자 이름을 비워두면 VNC 암호로 접속합니다. 암호는 저장하지 않습니다. 같은 네트워크나 VPN에서 사용하세요.")
                        }
                    }
                } else {
                    ScreenSurface(image: session.image, enabled: session.ready, optionHeld: session.optionHeld, key: session.key, pointer: session.pointer)
                        .background(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    if session.ready {
                        HStack {
                            Button("⌃ Space · 입력기") {
                                session.key(0xffe3, down: true); session.stroke(32); session.key(0xffe3, down: false)
                            }
                            Spacer()
                            Button("해상도") { displaySettings = true }
                            Button(keyboard ? "키보드 숨기기" : "키보드 표시") { keyboard.toggle() }
                        }.font(.caption).padding(.horizontal)
                        if keyboard { TestKeyboard(session: session) }
                    }
                }
                Text(session.status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if session.active && !session.ready { ProgressView() }
            }
            .padding(.bottom, 8)
            .navigationTitle("Mac Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.active { Button("연결 종료") { session.disconnect() } }
            }
            }
        }
        .sheet(isPresented: $displaySettings) { DisplaySettingsView(controller: session.display) }
        .onChange(of: phase) { _, newValue in if newValue == .background { session.disconnect() } }
    }
}

struct TestKeyboard: View {
    @ObservedObject var session: Session
    @State private var shift = false
    @State private var command = false
    var body: some View {
        VStack(spacing: 6) {
            Text("맥 입력기 검증용 영문 키보드").font(.caption2).foregroundStyle(.secondary)
            ForEach(["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"], id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { character in
                        Button(shift ? String(character).uppercased() : String(character)) {
                            let hid = character.asciiValue! >= 97 ? Int(character.asciiValue! - 97) + 4 : (character == "0" ? 39 : Int(character.asciiValue! - 49) + 30)
                            if let symbol = PhysicalKey.symbol(hid: hid, shift: shift) { session.stroke(symbol) }
                        }.frame(maxWidth: .infinity).buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                Button("⇧") { shift.toggle(); session.key(0xffe1, down: shift) }.tint(shift ? .orange : .blue)
                Button("⌘") { command.toggle(); session.key(0xffeb, down: command) }.tint(command ? .orange : .blue)
                Button("⌥") { session.toggleOption() }.tint(session.optionHeld ? .orange : .blue).accessibilityLabel("Option")
                Button("Space") { session.stroke(32) }
                Button("⌫") { session.stroke(0xff08) }
                Button("↵") { session.stroke(0xff0d) }
            }.buttonStyle(.bordered)
        }.padding(.horizontal, 6)
        .onDisappear {
            if shift { session.key(0xffe1, down: false) }
            if command { session.key(0xffeb, down: false) }
        }
    }
}
