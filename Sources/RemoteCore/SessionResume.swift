import Foundation

/// What to do with a live VNC session when the app is backgrounded or the link drops.
/// A short background keeps the socket. Coming back to a dead link reconnects once;
/// a failed reconnect waits for the next foreground transition instead of looping.
public struct SessionResume: Equatable {
    public enum Scene: Equatable, Sendable { case active, inactive, background }
    public enum Link: Equatable, Sendable { case idle, connecting, live, reconnecting, down }
    public enum Action: Equatable, Sendable { case beginBackgroundTask, endBackgroundTask, reconnect }

    public private(set) var scene: Scene
    public private(set) var link: Link
    public private(set) var userEnded: Bool
    public private(set) var hasCredentials: Bool
    public private(set) var everLive: Bool
    public private(set) var backgroundTaskOpen: Bool
    /// The open attempt is an automatic reconnect, so its failure must not schedule another immediately.
    public private(set) var resumeAttempt: Bool

    public init() {
        scene = .active
        link = .idle
        userEnded = false
        hasCredentials = false
        everLive = false
        backgroundTaskOpen = false
        resumeAttempt = false
    }

    /// Stay on the remote screen, including a dead link we still intend to restore.
    public var presentsRemote: Bool {
        if userEnded { return false }
        switch link {
        case .idle: return false
        case .connecting, .live, .reconnecting: return true
        case .down: return everLive && hasCredentials
        }
    }

    public mutating func beginManualConnect() {
        hasCredentials = true
        userEnded = false
        resumeAttempt = false
        link = .connecting
    }

    public mutating func noteLive() {
        link = .live
        everLive = true
        resumeAttempt = false
    }

    public mutating func linkClosed() -> [Action] {
        if userEnded || link == .idle || link == .down { return [] }
        let failedResume = resumeAttempt
        resumeAttempt = false
        link = .down
        guard everLive, hasCredentials, scene == .active, !failedResume else { return [] }
        return markReconnect()
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
        // Only the transition into the foreground retries. A drop while already active retries once from linkClosed.
        if next == .active, previous != .active, link == .down, everLive, hasCredentials, !userEnded, !resumeAttempt {
            actions.append(contentsOf: markReconnect())
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
        resumeAttempt = false
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

    private mutating func markReconnect() -> [Action] {
        resumeAttempt = true
        link = .reconnecting
        return [.reconnect]
    }
}

public enum DisplayReconnect {
    /// The mode the user picked is applied again only after an automatic reconnect.
    public static func mode(reconnecting: Bool, selected: UInt32?) -> UInt32? {
        reconnecting ? selected : nil
    }
}
