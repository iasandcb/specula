import Foundation

public struct RemoteDisplayMode: Codable, Identifiable, Sendable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public init(id: UInt32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.id = id; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
    public var title: String { "\(width) × \(height)" + (pixelWidth > width ? " · Retina" : "") }
}
/// Modes offered to the phone. Every desktop-GUI mode is eligible, including 640×480, until the pixel cap.
public enum DisplayModes {
    public static let maxPixels = 6016 * 3384

    public static func offered(_ modes: [RemoteDisplayMode]) -> [RemoteDisplayMode] {
        var seen = Set<String>()
        return modes.filter(fits).sorted { a, b in
            if a.width != b.width { return a.width < b.width }
            if a.height != b.height { return a.height < b.height }
            if a.pixelWidth != b.pixelWidth { return a.pixelWidth < b.pixelWidth }
            if a.pixelHeight != b.pixelHeight { return a.pixelHeight < b.pixelHeight }
            return a.id < b.id
        }.filter { seen.insert("\($0.width)x\($0.height)x\($0.pixelWidth)x\($0.pixelHeight)").inserted }
    }

    public static func fits(_ mode: RemoteDisplayMode) -> Bool {
        mode.width > 0 && mode.height > 0 && mode.pixelWidth > 0 && mode.pixelHeight > 0
            && mode.pixelWidth <= maxPixels && mode.pixelHeight <= maxPixels
            && mode.pixelWidth * mode.pixelHeight <= maxPixels
    }
}

/// Rotation of the main display. `supported` is false when the panel rejects the probe.
public struct DisplayRotation: Codable, Equatable, Sendable {
    public let degrees: Int
    public let supported: Bool
    public init(degrees: Int, supported: Bool) {
        self.degrees = degrees
        self.supported = supported
    }
}

public struct SetDisplayRotation: Codable, Equatable, Sendable {
    public let degrees: Int
    public init(degrees: Int) { self.degrees = degrees }
}

/// Quadrants the framebuffer probe accepts, and the fb-rotate option word for each.
public enum DisplayRotationAngle {
    /// `kIOFBSetTransform` (0x400) with the quadrant in bits 7–8: 0, 90, 180, 270 → 0x400, 0x480, 0x500, 0x580.
    public static func probeOptions(degrees: Int) -> UInt32? {
        guard let angle = normalized(degrees) else { return nil }
        return 0x0000_0400 | (UInt32(angle / 90) << 7)
    }

    public static func normalized(_ degrees: Int) -> Int? {
        let wrapped = ((degrees % 360) + 360) % 360
        guard wrapped.isMultiple(of: 90) else { return nil }
        return wrapped
    }

    /// The phone toggle: upright goes to 90°, any other quadrant returns to 0°.
    public static func portraitToggle(from degrees: Int) -> Int {
        normalized(degrees) == 0 ? 90 : 0
    }
}

/// The framebuffer shape is the rotation the user can see. 90° and 270° are portrait.
public enum DisplayOrientationCheck {
    public static func isPortrait(_ degrees: Int) -> Bool {
        let angle = DisplayRotationAngle.normalized(degrees)
        return angle == 90 || angle == 270
    }

    /// A square frame matches either request. Any other shape must agree with the requested quadrant.
    public static func matches(width: Int, height: Int, degrees: Int) -> Bool {
        guard width > 0, height > 0, DisplayRotationAngle.normalized(degrees) != nil else { return false }
        if width == height { return true }
        return (height > width) == isPortrait(degrees)
    }

    public static func failureTitle(degrees: Int) -> String {
        guard DisplayRotationAngle.normalized(degrees) != nil else { return "화면 회전" }
        return isPortrait(degrees) ? "세로 모드" : "가로 모드"
    }
}

/// Phone-side limits for the display helper. The list must fail fast; rotation is allowed to poll.
public enum DisplayHTTP {
    public static let listTimeout: TimeInterval = 3
    public static let rotationTimeout: TimeInterval = 6
    public static let connectionLost = "해상도 보조 앱과의 연결이 끊겼습니다. 변경한 해상도는 약 1분 이내에 복원됩니다."
    public static let unreachable = "맥의 해상도 보조 앱에 연결할 수 없습니다."

    /// 401 means the bearer is missing or stale. That is the pairing-code screen, not a dropped helper.
    /// A 401 from the pairing request itself is a wrong code and keeps its message.
    public static func interpret(status: Int?, body: Data, isPairing: Bool) -> Result<Data, DisplayCallError> {
        if status == 200 { return .success(body) }
        let message = (try? JSONDecoder().decode(DisplayFailure.self, from: body))?.message ?? unreachable
        if status == 401, !isPairing { return .failure(.pairingRequired) }
        return .failure(.message(message))
    }
}

public enum DisplayCallError: Error, Equatable, Sendable, LocalizedError {
    case pairingRequired
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .pairingRequired: return "맥의 연결 코드로 다시 연결해 주세요."
        case .message(let message): return message
        }
    }
}

/// Which mechanism may rotate the main display.
/// Apple Silicon framebuffers are `IOMobileFramebuffer` and ignore the IOKit probe, so that path is Intel only.
public enum DisplayRotationRoute: Equatable, Sendable {
    case monitorPanel
    case iokit
    case unsupported

    /// `monitorPanelRejected` means the panel was found and reported that it cannot rotate.
    /// That answer stands on Intel too: do not fall through to the IOKit probe.
    public static func select(monitorPanelReady: Bool, monitorPanelRejected: Bool, appleSilicon: Bool, iokitFramebuffer: Bool) -> Self {
        if monitorPanelReady { return .monitorPanel }
        if monitorPanelRejected || appleSilicon || !iokitFramebuffer { return .unsupported }
        return .iokit
    }
}

public struct DisplaySnapshot: Codable, Sendable {
    public let current: RemoteDisplayMode
    public let modes: [RemoteDisplayMode]
    public init(current: RemoteDisplayMode, modes: [RemoteDisplayMode]) { self.current = current; self.modes = modes }
}
/// How the six-digit pairing code is drawn in the large window.
public enum PairingCodePresentation {
    /// "123456" → "123 456". Anything that is not six digits is left unchanged.
    public static func groupedDigits(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let split = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<split]) \(digits[split...])"
    }

    /// About 200 points, or a quarter of the screen, whichever is larger, without covering the whole display.
    public static func digitPointSize(screenHeight: Double) -> Double {
        guard screenHeight.isFinite, screenHeight > 0 else { return 200 }
        return min(max(200, screenHeight / 4), screenHeight * 0.45)
    }

    /// Countdown under the digits. Nil once the code is no longer valid.
    public static func remainingLabel(until deadline: Date, now: Date) -> String? {
        let seconds = Int(deadline.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        return String(format: "남은 시간 %d:%02d", seconds / 60, seconds % 60)
    }
}

public struct PairDisplayRequest: Codable { public let code: String; public init(code: String) { self.code = code } }
public struct PairDisplayResponse: Codable { public let token: String; public init(token: String) { self.token = token } }
public struct ChangeDisplayRequest: Codable { public let modeID: UInt32; public init(modeID: UInt32) { self.modeID = modeID } }
public struct DisplayFailure: Codable { public let message: String; public init(_ message: String) { self.message = message } }

/// A missed heartbeat restores the original mode even when the phone disappears.
public struct DisplayLease {
    public private(set) var originalModeID: UInt32?
    public private(set) var expiresAt: Date?
    public init() {}
    public mutating func changed(from modeID: UInt32, now: Date) {
        if originalModeID == nil { originalModeID = modeID }
        renew(now: now)
    }
    public mutating func renew(now: Date) { if originalModeID != nil { expiresAt = now.addingTimeInterval(60) } }
    public func expired(now: Date) -> Bool { expiresAt.map { now >= $0 } ?? false }
    public mutating func clear() { originalModeID = nil; expiresAt = nil }
}

/// Titles for the ⋯ menu, which replaces the connected-session bar in both orientations.
public enum SessionMenuItem: Equatable {
    case option(held: Bool)
    case keyboard(shown: Bool)
    case input
    case resolution
    case orientation(macIsPortrait: Bool)
    case fill(enabled: Bool)
    case disconnect

    public var title: String {
        switch self {
        case .option(let held): return held ? "⌥ Option 끄기" : "⌥ Option 켜기"
        case .keyboard(let shown): return shown ? "키보드 숨기기" : "키보드 표시"
        case .input: return "입력기 전환"
        case .resolution: return "맥 해상도"
        case .orientation(let macIsPortrait): return macIsPortrait ? "가로 모드" : "세로 모드"
        case .fill(let enabled): return enabled ? "전체 화면 보기" : "화면 채우기"
        case .disconnect: return "연결 종료"
        }
    }

    /// Option, keyboard, and input source, then display controls, then disconnect.
    public var section: Int {
        switch self {
        case .option, .keyboard, .input: return 0
        case .resolution, .orientation, .fill: return 1
        case .disconnect: return 2
        }
    }

    public var isDestructive: Bool {
        if case .disconnect = self { return true }
        return false
    }

    public static func items(optionHeld: Bool, keyboardShown: Bool, macIsPortrait: Bool, fillScreen: Bool) -> [SessionMenuItem] {
        [
            .option(held: optionHeld),
            .keyboard(shown: keyboardShown),
            .input,
            .resolution,
            .orientation(macIsPortrait: macIsPortrait),
            .fill(enabled: fillScreen),
            .disconnect
        ]
    }
}

/// Labels for the connected-session bar. The keyboard control is always present and the words stay short
/// so a narrow phone does not clip the trailing button.
public enum SessionControls {
    public static let input = "입력기"
    public static let resolution = "해상도"
    public static let keyboard = "키보드"
    /// Apple's minimum control size. The two-character orientation title needs this floor.
    public static let minimumHit = 44
    /// Body text, up from the previous 12pt caption, still narrow enough for a 320pt phone.
    public static let labelPointSize = 17
    public static let buttonSpacing = 8
    public static let labelPadding = 8
    public static let horizontalInset = 8
    /// The ⋯ button. Larger than the 44pt minimum so the glyph and hit target stay easy to see.
    public static let menuButtonSide = 64
    public static let menuGlyphPointSize = 28

    public static func orientation(macIsPortrait: Bool) -> String {
        macIsPortrait ? "가로" : "세로"
    }

    /// Width of one toolbar control, including padding, and never under the 44pt hit target.
    public static func controlWidth(_ title: String) -> Int {
        let text = title.reduce(0) { sum, character in
            sum + (character.isASCII ? (labelPointSize * 7) / 12 : labelPointSize)
        }
        return max(minimumHit, text + labelPadding * 2)
    }

    /// Four controls, the flexible middle gap, and the outer insets. One row, no alternate layout.
    public static func minimumRowWidth(macIsPortrait: Bool) -> Int {
        let titles = [keyboard, input, resolution, orientation(macIsPortrait: macIsPortrait)]
        let controls = titles.reduce(0) { $0 + controlWidth($1) }
        return controls + buttonSpacing * (titles.count + 1) + horizontalInset * 2
    }

    public static func titles(macIsPortrait: Bool) -> [String] {
        [input, resolution, orientation(macIsPortrait: macIsPortrait), keyboard]
    }

    /// Caption-size estimate. A Hangul syllable is one em; ASCII is narrower.
    public static func captionWidth(_ title: String) -> Int {
        title.reduce(0) { sum, character in
            sum + (character.isASCII ? 7 : 12)
        }
    }

    public static func rowWidth(titles: [String], gap: Int = 8, horizontalPadding: Int = 24) -> Int {
        let text = titles.reduce(0) { $0 + captionWidth($1) }
        let gaps = titles.isEmpty ? 0 : gap * (titles.count - 1)
        return text + gaps + horizontalPadding
    }

    public static func fits(macIsPortrait: Bool, width: Int) -> Bool {
        minimumRowWidth(macIsPortrait: macIsPortrait) <= width
    }

    /// The previous bar. The keyboard title grew to "키보드 숨기기" while the panel was open, which is the state at connect.
    public static func legacyTitles(macIsPortrait: Bool, keyboardShown: Bool) -> [String] {
        [
            "⌃ Space · 입력기",
            "해상도",
            macIsPortrait ? "가로 모드" : "세로 모드",
            keyboardShown ? "키보드 숨기기" : "키보드 표시"
        ]
    }
}

public enum DisplayPeer {
    public static func isAllowed(_ address: String) -> Bool {
        let plain = address.lowercased().split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        if plain == "::1" || plain.hasPrefix("fd7a:115c:a1e0:") { return true }
        let ipv4 = plain.hasPrefix("::ffff:") ? String(plain.dropFirst(7)) : plain
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
}
