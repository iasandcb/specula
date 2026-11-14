import Foundation

/// What to do with a VNC session when the link drops or the app moves between foreground and background.
/// A handshake that never produces a frame, or a protocol error, returns to the connect screen.
/// A working session that loses the socket reconnects at most three times, with a longer pause each time.
public struct SessionResume: Equatable {
    public enum Scene: Equatable, Sendable { case active, inactive, background }
    public enum Link: Equatable, Sendable { case idle, connecting, live, reconnecting, down }
    public enum LinkFailure: Equatable, Sendable { case transport, protocolError }
    public enum Action: Equatable, Sendable {
        case beginBackgroundTask
        case endBackgroundTask
        case reconnect(afterMilliseconds: Int)
    }

    public static let maxAutomaticReconnects = 3

    public private(set) var scene: Scene
    public private(set) var link: Link
    public private(set) var userEnded: Bool
    public private(set) var hasCredentials: Bool
    public private(set) var everLive: Bool
    public private(set) var backgroundTaskOpen: Bool
    public private(set) var automaticReconnects: Int

    public init() {
        scene = .active
        link = .idle
        userEnded = false
        hasCredentials = false
        everLive = false
        backgroundTaskOpen = false
        automaticReconnects = 0
    }

    /// Stay on the remote screen during a connection, a retry, or a drop we still intend to restore.
    public var presentsRemote: Bool {
        if userEnded { return false }
        switch link {
        case .idle: return false
        case .connecting, .live, .reconnecting: return true
        case .down: return everLive && hasCredentials
        }
    }

    /// Frame and cursor callbacks must ignore events after the attempt has already ended.
    public var acceptsSessionEvents: Bool {
        switch link {
        case .connecting, .live, .reconnecting: return true
        case .idle, .down: return false
        }
    }

    public static func backoffMilliseconds(attempt: Int) -> Int {
        switch attempt {
        case 1: return 400
        case 2: return 1_200
        default: return 2_500
        }
    }

    public mutating func beginManualConnect() {
        hasCredentials = true
        userEnded = false
        everLive = false
        automaticReconnects = 0
        link = .connecting
    }

    /// A decoded framebuffer means this attempt really worked, so the reconnect budget starts over.
    public mutating func noteFrame() {
        guard acceptsSessionEvents else { return }
        link = .live
        everLive = true
        automaticReconnects = 0
    }

    public mutating func linkClosed(_ failure: LinkFailure) -> [Action] {
        if userEnded || link == .idle || link == .down { return [] }
        link = .down
        if failure == .protocolError || !everLive || !hasCredentials {
            abandon()
            return []
        }
        guard scene == .active else { return [] }
        return reconnectIfAllowed()
    }

    public mutating func scene(_ next: Scene) -> [Action] {
        let previous = scene
        scene = next
        var actions: [Action] = []
        if next == .background, previous != .background, shouldHoldInBackground, !backgroundTaskOpen {
            backgroundTaskOpen = true
            actions.append(.beginBackgroundTask)
        }
        if next != .background, backgroundTaskOpen {
            backgroundTaskOpen = false
            actions.append(.endBackgroundTask)
        }
        if next == .active, previous != .active, link == .down, everLive, hasCredentials, !userEnded {
            actions.append(contentsOf: reconnectIfAllowed())
        }
        return actions
    }

    public mutating func backgroundExpired() -> [Action] {
        guard backgroundTaskOpen else { return [] }
        backgroundTaskOpen = false
        return [.endBackgroundTask]
    }

    public mutating func userDisconnected() -> [Action] {
        userEnded = true
        hasCredentials = false
        link = .idle
        everLive = false
        automaticReconnects = 0
        var actions: [Action] = []
        if backgroundTaskOpen {
            backgroundTaskOpen = false
            actions.append(.endBackgroundTask)
        }
        return actions
    }

    private var shouldHoldInBackground: Bool {
        !userEnded && hasCredentials && (link == .connecting || link == .live || link == .reconnecting)
    }

    private mutating func reconnectIfAllowed() -> [Action] {
        guard automaticReconnects < Self.maxAutomaticReconnects else {
            abandon()
            return []
        }
        automaticReconnects += 1
        link = .reconnecting
        return [.reconnect(afterMilliseconds: Self.backoffMilliseconds(attempt: automaticReconnects))]
    }

    private mutating func abandon() {
        everLive = false
        link = .down
        automaticReconnects = 0
    }
}

public enum ConnectFocus: Equatable, Sendable {
    case host, port, username, password

    /// Password when every other field has text. Otherwise the first empty field, in form order.
    public static func field(host: String, port: String, username: String, password: String) -> ConnectFocus {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .host }
        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .port }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .username }
        return .password
    }
}

public enum DisplayReconnect {
    /// The mode the user picked is applied again only after an automatic reconnect.
    public static func mode(reconnecting: Bool, selected: UInt32?) -> UInt32? {
        reconnecting ? selected : nil
    }
}
