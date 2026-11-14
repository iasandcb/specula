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

public struct DisplaySnapshot: Codable, Sendable {
    public let current: RemoteDisplayMode
    public let modes: [RemoteDisplayMode]
    public init(current: RemoteDisplayMode, modes: [RemoteDisplayMode]) { self.current = current; self.modes = modes }
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
