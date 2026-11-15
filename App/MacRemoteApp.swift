import Combine
import SwiftUI

@main
struct MacRemoteApp: App {
    var body: some Scene { WindowGroup { RemoteView() } }
}

@MainActor
final class Session: ObservableObject {
    @Published var status = "맥에 연결할 준비가 되었습니다"
    /// Shown on the connect screen until the next attempt. The alert uses the same text.
    @Published var connectionError = ""
    @Published var showConnectionAlert = false
    @Published var active = false
    @Published var ready = false
    @Published var optionHeld = false
    /// Latest frame for rotation checks. Not published: publishing it rebuilt the ⋯ menu every frame.
    private(set) var image: UIImage?
    let frames = FramePump()
    let display = DisplayController()
    private var displayChanges: AnyCancellable?
    init() {
        displayChanges = display.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    private var client: RFBClient?
    private var task: Task<Void, Never>?
    private var input: Task<Void, Never>?
    private var generation = UUID()
    private var login: Login?
    private var reconnectWait: Task<Void, Never>?
    private var resume = SessionResume()
    private var backgroundBox: BackgroundBox?
    private var pendingRaster: (Frame, UUID)?
    private var pendingImage: UIImage?
    private var rasterBusy = false
    private let presenter = FramePresenter()

    private struct Login {
        var host: String
        var port: UInt16
        var username: String
        var password: String
    }

    func toggleOption() {
        guard ready else { return }
        optionHeld.toggle(); key(0xffe7, down: optionHeld)
    }
    func connect(host: String, port: String, username: String, password: String) {
        guard !active else { return }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let port = UInt16(port), port > 0 else {
            status = "맥 주소와 포트(1~65535)를 확인해 주세요."; return
        }
        connectionError = ""
        showConnectionAlert = false
        display.configure(host: trimmed)
        login = Login(host: trimmed, port: port, username: username, password: password)
        resume.beginManualConnect()
        startLink(reconnect: false)
    }
    func disconnect() {
        let actions = resume.userDisconnected()
        reconnectWait?.cancel(); reconnectWait = nil
        generation = UUID(); task?.cancel(); input?.cancel()
        let previous = client
        client = nil
        if let previous { Task { await previous.close() } }
        active = false; ready = false; optionHeld = false
        clearPicture()
        pendingRaster = nil; pendingImage = nil; login = nil
        status = "연결을 종료했습니다"
        display.endSession()
        presenter.stop()
        perform(actions)
    }
    func sceneChanged(_ phase: ScenePhase) {
        let mapped: SessionResume.Scene
        switch phase {
        case .background: mapped = .background
        case .inactive: mapped = .inactive
        default: mapped = .active
        }
        perform(resume.scene(mapped))
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

    private func startLink(reconnect: Bool) {
        guard let login, !resume.userEnded else { return }
        if !reconnect { reconnectWait?.cancel() }
        reconnectWait = nil
        let id = UUID()
        generation = id
        task?.cancel(); input?.cancel()
        if let client { Task { await client.close() } }
        let client = RFBClient()
        self.client = client
        active = true; ready = false; optionHeld = false
        status = reconnect ? "다시 연결하는 중…" : "맥에 연결 중…"
        if reconnect { frames.setCursor(nil, hidden: false) }
        let host = login.host, port = login.port, username = login.username, password = login.password
        task = Task { [self] in
            var failure: String?
            var protocolError = false
            do {
                try await client.run(host: host, port: port, username: username, password: password, onProgress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, !reconnect, self.connectionError.isEmpty, self.resume.acceptsSessionEvents else { return }
                        self.status = progress
                    }
                }, onFrame: { frame in
                    Task { @MainActor [weak self] in self?.enqueueFrame(frame, generation: id) }
                }, onReady: { name in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.resume.acceptsSessionEvents else { return }
                        self.ready = true
                        self.status = name
                        self.display.beginSession()
                        if reconnect { await self.display.reapplyPreferredMode() }
                    }
                }, onCursor: { cursor in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.resume.acceptsSessionEvents else { return }
                        if cursor.isHidden { self.frames.setCursor(nil, hidden: true) }
                        else { self.frames.setCursor(cursor, hidden: false) }
                    }
                })
            } catch is CancellationError {
            } catch let error as RFBError {
                failure = error.localizedDescription
                protocolError = error.isProtocolFailure
            } catch { failure = error.localizedDescription }
            guard generation == id else { return }
            finishLink(failure: failure, protocolError: protocolError)
        }
    }
    private func finishLink(failure: String?, protocolError: Bool) {
        ready = false; optionHeld = false
        let actions = resume.linkClosed(protocolError ? .protocolError : .transport)
        if !resume.presentsRemote {
            active = false
            clearPicture()
            pendingRaster = nil; pendingImage = nil
            display.endSession()
            if !resume.userEnded {
                let message = (failure?.isEmpty == false) ? failure! : "연결이 끊겼습니다."
                connectionError = message
                showConnectionAlert = true
                status = message
            }
        } else if actions.contains(where: { if case .reconnect = $0 { return true }; return false }) {
            status = "다시 연결하는 중…"
        } else if let failure {
            status = failure
        }
        perform(actions)
    }
    private func perform(_ actions: [SessionResume.Action]) {
        for action in actions {
            switch action {
            case .beginBackgroundTask: beginBackgroundHold()
            case .endBackgroundTask: endBackgroundHold()
            case .reconnect(let delay): scheduleReconnect(afterMilliseconds: delay)
            }
        }
    }
    private func scheduleReconnect(afterMilliseconds delay: Int) {
        reconnectWait?.cancel()
        status = "다시 연결하는 중…"
        reconnectWait = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            guard !Task.isCancelled, let self else { return }
            guard self.resume.link == .reconnecting, !self.resume.userEnded else { return }
            self.startLink(reconnect: true)
        }
    }
    private func beginBackgroundHold() {
        if let backgroundBox, backgroundBox.id != .invalid { return }
        let box = BackgroundBox()
        backgroundBox = box
        box.id = UIApplication.shared.beginBackgroundTask(withName: "Specula.vnc") { [weak self, box] in
            let ended = box.id
            box.id = .invalid
            if ended != .invalid { UIApplication.shared.endBackgroundTask(ended) }
            MainActor.assumeIsolated {
                if self?.backgroundBox === box { self?.backgroundBox = nil }
                _ = self?.resume.backgroundExpired()
            }
        }
        if box.id == .invalid {
            backgroundBox = nil
            _ = resume.backgroundExpired()
        }
    }
    private func endBackgroundHold() {
        guard let box = backgroundBox, box.id != .invalid else { backgroundBox = nil; return }
        let id = box.id
        box.id = .invalid
        backgroundBox = nil
        UIApplication.shared.endBackgroundTask(id)
    }
    private func enqueueFrame(_ frame: Frame, generation id: UUID) {
        guard generation == id, resume.acceptsSessionEvents else { return }
        resume.noteFrame()
        if presenter.onFrame == nil { presenter.onFrame = { [weak self] in self?.publishFrame() } }
        pendingRaster = (frame, id)
        startRaster()
    }
    private func startRaster() {
        guard !rasterBusy, let next = pendingRaster else { return }
        pendingRaster = nil
        rasterBusy = true
        let frame = next.0
        let id = next.1
        Task.detached(priority: .userInitiated) {
            let image = Session.rasterize(frame)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rasterBusy = false
                if self.generation == id, let image {
                    self.pendingImage = image
                    self.presenter.schedule()
                }
                self.startRaster()
            }
        }
    }
    private func publishFrame() {
        guard let image = pendingImage else { return }
        pendingImage = nil
        showPicture(image)
        // @Published fires even when the text is unchanged. Assigning it every frame
        // invalidated the ⋯ menu and dismissed the popup before a tap could land.
        if ready, connectionError.isEmpty, status != "맥에 연결됨" { status = "맥에 연결됨" }
    }
    private func showPicture(_ image: UIImage?) {
        self.image = image
        frames.setImage(image)
    }
    private func clearPicture() {
        image = nil
        frames.clear()
    }
    nonisolated private static func rasterize(_ frame: Frame) -> UIImage? {
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let cg = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private final class BackgroundBox { var id: UIBackgroundTaskIdentifier = .invalid }

/// Pushes frames and cursors straight to the canvas so SwiftUI does not rebuild the ⋯ menu.
final class FramePump {
    private(set) var image: UIImage?
    private(set) var cursor: RemoteCursor?
    private(set) var cursorHidden = false
    private var onImage: ((UIImage?) -> Void)?
    private var onCursor: ((RemoteCursor?, Bool) -> Void)?

    func setImage(_ image: UIImage?) {
        self.image = image
        onImage?(image)
    }

    func setCursor(_ cursor: RemoteCursor?, hidden: Bool) {
        guard cursor != self.cursor || hidden != cursorHidden else { return }
        self.cursor = cursor
        self.cursorHidden = hidden
        onCursor?(cursor, hidden)
    }

    func clear() {
        setImage(nil)
        setCursor(nil, hidden: false)
    }

    func bind(_ view: RemoteCanvas) {
        onImage = { [weak view] image in view?.image = image }
        onCursor = { [weak view] cursor, hidden in view?.applyServerCursor(cursor, hidden: hidden) }
        guard view.boundPump !== self else { return }
        view.boundPump = self
        view.image = image
        view.applyServerCursor(cursor, hidden: cursorHidden)
    }
}

private final class FramePresenter: NSObject {
    var onFrame: (() -> Void)?
    private var link: CADisplayLink?
    func schedule() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func step() {
        link?.invalidate(); link = nil
        onFrame?()
    }
}

struct RemoteView: View {
    @StateObject private var session = Session()
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = "5900"
    @AppStorage("username") private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: ConnectFocus?
    @State private var keyboard = true
    @State private var fillScreen = false
    @State private var displaySettings = false
    @State private var rotationAlert = false
    @State private var rotationAlertTitle = "화면 회전"
    @State private var rotationAlertText = ""
    @StateObject private var menuGate = MenuGate()
    @Environment(\.scenePhase) private var phase
    private var menuItems: [SessionMenuItem] {
        SessionMenuItem.items(optionHeld: session.optionHeld, keyboardShown: keyboard, macIsPortrait: session.display.portrait, fillScreen: fillScreen)
    }
    var body: some View {
        NavigationStack {
            if session.active {
                VStack(spacing: 0) {
                    ZStack {
                        ScreenSurface(frames: session.frames, enabled: session.ready, fill: fillScreen, optionHeld: session.optionHeld, suspendKeyCapture: displaySettings, menuGate: menuGate, key: session.key, pointer: session.pointer)
                        if !session.ready {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text(session.status).font(.footnote).multilineTextAlignment(.center)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 24)
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        SessionMenuButton(items: menuItems, gate: menuGate, perform: performMenu)
                            .frame(width: CGFloat(SessionControls.menuButtonSide), height: CGFloat(SessionControls.menuButtonSide))
                            .padding(12)
                    }
                    if session.ready, keyboard { TestKeyboard(session: session).padding(.bottom, 4) }
                }
                .background(.black)
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
            } else {
                VStack(spacing: 12) {
                    Form {
                        Section("접속할 맥") {
                            TextField("IP 주소 또는 Mac.local", text: $host)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .host)
                                .submitLabel(.next)
                                .onSubmit { submitConnection(from: .host) }
                            TextField("포트", text: $port)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .port)
                                .submitLabel(.next)
                                .onSubmit { submitConnection(from: .port) }
                            TextField("맥 사용자 이름 (선택)", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil)
                                .focused($focusedField, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { submitConnection(from: .username) }
                            SecureField(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VNC 암호" : "맥 로그인 암호", text: $password)
                                // Prevent iOS from treating remote-host credentials as an app login.
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { submitConnection(from: .password) }
                        }
                        Section {
                            Button("맥에 연결") { submitConnection(from: .password) }
                                .disabled(host.isEmpty || password.isEmpty)
                        } footer: {
                            Text("맥의 화면 공유를 켜고, 맥 사용자 이름과 로그인 암호를 입력하세요. 사용자 이름을 비워두면 VNC 암호로 접속합니다. 암호는 저장하지 않습니다. 같은 네트워크나 VPN에서 사용하세요.")
                            if !session.connectionError.isEmpty {
                                Text(session.connectionError).foregroundStyle(.red)
                            }
                        }
                    }
                    .task(id: session.active) {
                        guard !session.active else { return }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled, !session.active else { return }
                        focusedField = ConnectFocus.field(host: host, port: port, username: username, password: password)
                    }
                    Text(session.status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                .padding(.bottom, 8)
                .navigationTitle("Specula")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $displaySettings, onDismiss: {
            if !session.display.paired { session.display.cancelPendingRotation() }
        }) { DisplaySettingsView(controller: session.display) }
        .onChange(of: phase) { _, newValue in session.sceneChanged(newValue) }
        .alert("연결하지 못했습니다", isPresented: $session.showConnectionAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(session.connectionError)
        }
        .alert(rotationAlertTitle, isPresented: $rotationAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(rotationAlertText)
        }
    }
    private func performMenu(_ item: SessionMenuItem) {
        switch item {
        case .option: session.toggleOption()
        case .keyboard: keyboard.toggle()
        case .input: switchInput()
        case .resolution:
            session.display.cancelPendingRotation()
            displaySettings = true
        case .orientation: togglePortrait()
        case .fill: fillScreen.toggle()
        case .disconnect: session.disconnect()
        }
    }
    private func switchInput() {
        session.key(0xffe3, down: true); session.stroke(32); session.key(0xffe3, down: false)
    }
    private func togglePortrait() {
        Task {
            let needsPairing = !session.display.paired
            await session.display.togglePortrait()
            if needsPairing {
                displaySettings = true
                return
            }
            guard !session.display.error.isEmpty else { return }
            if await framebufferShowsAttemptedRotation() {
                session.display.noteRotationApplied()
                return
            }
            rotationAlertTitle = DisplayOrientationCheck.failureTitle(degrees: session.display.attemptedRotation)
            rotationAlertText = session.display.error
            rotationAlert = true
        }
    }
    /// The helper can answer before MonitorPanel finishes. The stream's new size is the rotation the user sees.
    private func framebufferShowsAttemptedRotation() async -> Bool {
        let degrees = session.display.attemptedRotation
        for _ in 0..<12 {
            if let size = session.image?.size,
               DisplayOrientationCheck.matches(width: Int(size.width.rounded()), height: Int(size.height.rounded()), degrees: degrees) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
    private func submitConnection(from field: ConnectFocus) {
        if !host.isEmpty, !password.isEmpty {
            session.connect(host: host, port: port, username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            password = ""
            return
        }
        switch field {
        case .host: focusedField = .port
        case .port: focusedField = .username
        case .username: focusedField = .password
        case .password: break
        }
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

/// UIKit menu. SwiftUI's Menu is recreated whenever its parent invalidates, which blinked the popup.
private struct SessionMenuButton: UIViewRepresentable {
    var items: [SessionMenuItem]
    var gate: MenuGate
    var perform: (SessionMenuItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EllipsisButton {
        let button = EllipsisButton()
        button.bridge = context.coordinator
        context.coordinator.bind(items: items, gate: gate, perform: perform, button: button)
        return button
    }

    func updateUIView(_ button: EllipsisButton, context: Context) {
        button.bridge = context.coordinator
        context.coordinator.bind(items: items, gate: gate, perform: perform, button: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EllipsisButton, context: Context) -> CGSize? {
        let side = CGFloat(SessionControls.menuButtonSide)
        return CGSize(width: side, height: side)
    }

    final class Coordinator {
        private var items: [SessionMenuItem] = []
        private var perform: (SessionMenuItem) -> Void = { _ in }
        private var gate: MenuGate?
        func bind(items: [SessionMenuItem], gate: MenuGate, perform: @escaping (SessionMenuItem) -> Void, button: EllipsisButton) {
            self.perform = perform
            self.gate = gate
            guard items != self.items else { return }
            self.items = items
            button.menu = Self.menu(items: items) { [weak self] item in
                self?.gate?.menuEnded()
                self?.perform(item)
            }
        }
        func menuBegan() { gate?.menuBegan() }
        private static func menu(items: [SessionMenuItem], select: @escaping (SessionMenuItem) -> Void) -> UIMenu {
            let sections = Dictionary(grouping: items, by: \.section).keys.sorted().map { section in
                UIMenu(options: .displayInline, children: items.filter { $0.section == section }.map { item in
                    let attributes: UIMenuElement.Attributes = item.isDestructive ? .destructive : []
                    return UIAction(title: item.title, attributes: attributes) { _ in select(item) }
                })
            }
            return UIMenu(title: "", children: sections)
        }
    }
}

private final class EllipsisButton: UIButton {
    weak var bridge: SessionMenuButton.Coordinator?
    private let side = CGFloat(SessionControls.menuButtonSide)

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        let symbol = UIImage.SymbolConfiguration(pointSize: CGFloat(SessionControls.menuGlyphPointSize), weight: .bold)
        let image = UIImage(systemName: "ellipsis", withConfiguration: symbol)
        config.image = image
        config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        config.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        config.background.strokeWidth = 1
        config.background.strokeColor = UIColor.label.withAlphaComponent(0.45)
        configuration = config
        showsMenuAsPrimaryAction = true
        isExclusiveTouch = true
        addTarget(self, action: #selector(didTouchDown), for: .touchDown)
        accessibilityLabel = "제어 메뉴"
        accessibilityHint = "Option, 키보드, 입력기, 해상도, 화면, 연결 종료"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        applyReadableMenuText()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        bridge?.menuBegan()
        return super.beginTracking(touch, with: event)
    }

    @objc private func didTouchDown() { bridge?.menuBegan() }

    private func applyReadableMenuText() {
        let order: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge
        ]
        let current = traitCollection.preferredContentSizeCategory
        guard let currentIndex = order.firstIndex(of: current),
              let floorIndex = order.firstIndex(of: .extraExtraLarge),
              currentIndex < floorIndex else { return }
        traitOverrides.preferredContentSizeCategory = .extraExtraLarge
    }
}
