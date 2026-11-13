import Foundation

extension PointerButtons {
    /// UIKit `UIEvent.ButtonMask` raw bits. Button numbers are 1-based (`1 << (number - 1)`):
    /// bit 0 is primary (left), bit 1 is secondary (right), bit 2 is `button(3)` (middle).
    /// RFB numbers the middle button as 2 and the right button as 3, so those two bits are swapped.
    public static func mask(uiButtonMask rawValue: Int) -> UInt8 {
        var mask: UInt8 = none
        if rawValue & (1 << 0) != 0 { mask |= left }
        if rawValue & (1 << 1) != 0 { mask |= right }
        if rawValue & (1 << 2) != 0 { mask |= middle }
        return mask
    }
}

/// View-point to remote framebuffer mapping shared by touch and pointer input.
public enum PointerMapping {
    public struct Frame: Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public func contains(x: Double, y: Double) -> Bool {
            x >= self.x && y >= self.y && x < self.x + width && y < self.y + height
        }
    }

    public struct Point: Equatable {
        public var x: Int
        public var y: Int
    }

    /// Letterboxed (or filled) image rectangle in view points. Nil when either side has no area.
    public static func displayedFrame(viewWidth: Double, viewHeight: Double, imageWidth: Double, imageHeight: Double, fill: Bool) -> Frame? {
        guard viewWidth > 0, viewHeight > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        guard viewWidth.isFinite, viewHeight.isFinite, imageWidth.isFinite, imageHeight.isFinite else { return nil }
        let scale = fill ? max(viewWidth / imageWidth, viewHeight / imageHeight) : min(viewWidth / imageWidth, viewHeight / imageHeight)
        guard scale.isFinite, scale > 0 else { return nil }
        let width = imageWidth * scale
        let height = imageHeight * scale
        return Frame(x: (viewWidth - width) / 2, y: (viewHeight - height) / 2, width: width, height: height)
    }

    /// Framebuffer pixel for a view point.
    /// `clamp` keeps a drag that leaves the image on the nearest pixel.
    /// Without it, letterbox and other outside points are nil so a hover does not jump the cursor.
    public static func framebufferPoint(viewX: Double, viewY: Double, viewWidth: Double, viewHeight: Double, imageWidth: Double, imageHeight: Double, fill: Bool, clamp: Bool) -> Point? {
        guard viewX.isFinite, viewY.isFinite else { return nil }
        guard let frame = displayedFrame(viewWidth: viewWidth, viewHeight: viewHeight, imageWidth: imageWidth, imageHeight: imageHeight, fill: fill) else { return nil }
        if !clamp && !frame.contains(x: viewX, y: viewY) { return nil }
        let rawX = (viewX - frame.x) / frame.width * imageWidth
        let rawY = (viewY - frame.y) / frame.height * imageHeight
        guard rawX.isFinite, rawY.isFinite else { return nil }
        let x = min(max(rawX, 0), imageWidth - 1)
        let y = min(max(rawY, 0), imageHeight - 1)
        return Point(x: Int(x), y: Int(y))
    }
}

/// Mouse-wheel and trackpad scroll translated into momentary RFB wheel buttons.
public enum PointerScroll {
    /// One wheel click per this many points of pan translation.
    /// A mouse detent on iPadOS is about 10 points, so one notch is one click.
    /// Trackpad movement uses the same step, close to the 16-point touch scroll.
    public static let pointsPerClick: Double = 10
    /// Caps a single update so a runaway translation cannot flood the pointer queue.
    public static let maxClicksPerAxis: Int = 80

    public struct Ticks: Equatable {
        /// Press then release for each click. `held` stays down across the release.
        public var masks: [UInt8]
        public var consumedX: Double
        public var consumedY: Double
    }

    /// Positive Y (finger or wheel moving down the view) is wheel-up, matching two-finger touch scroll.
    /// Positive X is wheel-left for the same natural-scrolling direction.
    /// `flushRemainder` turns a leftover fraction into one click and consumes the whole delta,
    /// so a short mouse detent still registers when the gesture ends.
    public static func ticks(deltaX: Double, deltaY: Double, held: UInt8 = 0, pointsPerClick: Double = PointerScroll.pointsPerClick, flushRemainder: Bool = false) -> Ticks {
        let y = axis(deltaY, pointsPerClick: pointsPerClick, flushRemainder: flushRemainder)
        let x = axis(deltaX, pointsPerClick: pointsPerClick, flushRemainder: flushRemainder)
        var masks: [UInt8] = []
        append(y.count > 0 ? PointerButtons.wheelUp : PointerButtons.wheelDown, count: abs(y.count), held: held, masks: &masks)
        append(x.count > 0 ? PointerButtons.wheelLeft : PointerButtons.wheelRight, count: abs(x.count), held: held, masks: &masks)
        return Ticks(masks: masks, consumedX: x.consumed, consumedY: y.consumed)
    }

    private static func append(_ button: UInt8, count: Int, held: UInt8, masks: inout [UInt8]) {
        guard count > 0 else { return }
        for _ in 0..<count {
            masks.append(held | button)
            masks.append(held)
        }
    }

    private static func axis(_ delta: Double, pointsPerClick: Double, flushRemainder: Bool) -> (count: Int, consumed: Double) {
        guard pointsPerClick > 0, delta.isFinite, delta != 0 else { return (0, 0) }
        let steps = delta / pointsPerClick
        if !steps.isFinite || abs(steps) >= Double(maxClicksPerAxis) {
            let count = delta > 0 ? maxClicksPerAxis : -maxClicksPerAxis
            return (count, Double(count) * pointsPerClick)
        }
        var count = Int(steps)
        let consumedSteps = Double(count) * pointsPerClick
        let leftover = delta - consumedSteps
        if flushRemainder && leftover != 0 {
            count += delta > 0 ? 1 : -1
            return (count, delta)
        }
        return (count, consumedSteps)
    }
}
