import XCTest
@testable import RemoteCore

final class PointerInputTests: XCTestCase {
    func testUIKitButtonMaskSwapsRightAndMiddle() {
        XCTAssertEqual(PointerButtons.mask(uiButtonMask: 1 << 0), PointerButtons.left)
        XCTAssertEqual(PointerButtons.mask(uiButtonMask: 1 << 1), PointerButtons.right)
        XCTAssertEqual(PointerButtons.mask(uiButtonMask: 1 << 2), PointerButtons.middle)
        XCTAssertEqual(PointerButtons.right, 4)
        XCTAssertEqual(PointerButtons.middle, 2)
        let chord = PointerButtons.mask(uiButtonMask: 1 | 2 | 4)
        XCTAssertEqual(chord, PointerButtons.left | PointerButtons.right | PointerButtons.middle)
        XCTAssertEqual(PointerButtons.mask(uiButtonMask: 0), PointerButtons.none)
        XCTAssertEqual(PointerButtons.mask(uiButtonMask: 1 << 3), PointerButtons.none)
    }

    func testHorizontalWheelUsesButtonsSixAndSeven() {
        XCTAssertEqual(PointerButtons.wheelLeft, 32)
        XCTAssertEqual(PointerButtons.wheelRight, 64)
        XCTAssertEqual(PointerButtons.wheelUp, 8)
        XCTAssertEqual(PointerButtons.wheelDown, 16)
    }

    func testScrollTicksMatchFingerDirectionAndKeepRemainder() {
        let down = PointerScroll.ticks(deltaX: 0, deltaY: 25)
        XCTAssertEqual(down.masks, [PointerButtons.wheelUp, PointerButtons.none, PointerButtons.wheelUp, PointerButtons.none])
        XCTAssertEqual(down.consumedY, 20)
        XCTAssertEqual(down.consumedX, 0)

        let up = PointerScroll.ticks(deltaX: 0, deltaY: -10)
        XCTAssertEqual(up.masks, [PointerButtons.wheelDown, PointerButtons.none])
        XCTAssertEqual(up.consumedY, -10)

        let sideways = PointerScroll.ticks(deltaX: 30, deltaY: 0)
        XCTAssertEqual(sideways.masks, [PointerButtons.wheelLeft, PointerButtons.none, PointerButtons.wheelLeft, PointerButtons.none, PointerButtons.wheelLeft, PointerButtons.none])
        XCTAssertEqual(sideways.consumedX, 30)

        let tiny = PointerScroll.ticks(deltaX: 9, deltaY: -9)
        XCTAssertEqual(tiny.masks, [])
        XCTAssertEqual(tiny.consumedX, 0)
        XCTAssertEqual(tiny.consumedY, 0)

        let both = PointerScroll.ticks(deltaX: -10, deltaY: 10, held: PointerButtons.left)
        XCTAssertEqual(both.masks, [
            PointerButtons.left | PointerButtons.wheelUp, PointerButtons.left,
            PointerButtons.left | PointerButtons.wheelRight, PointerButtons.left
        ])
    }

    func testScrollFlushTurnsAShortDetentIntoOneClick() {
        let pending = PointerScroll.ticks(deltaX: 0, deltaY: 9)
        XCTAssertEqual(pending.masks, [])
        let finished = PointerScroll.ticks(deltaX: -4, deltaY: 9, flushRemainder: true)
        XCTAssertEqual(finished.masks, [PointerButtons.wheelUp, PointerButtons.none, PointerButtons.wheelRight, PointerButtons.none])
        XCTAssertEqual(finished.consumedX, -4)
        XCTAssertEqual(finished.consumedY, 9)
    }

    func testScrollCapsARunawayDelta() {
        let burst = PointerScroll.ticks(deltaX: 0, deltaY: Double(PointerScroll.maxClicksPerAxis + 40) * PointerScroll.pointsPerClick)
        XCTAssertEqual(burst.masks.count, PointerScroll.maxClicksPerAxis * 2)
        XCTAssertEqual(burst.consumedY, Double(PointerScroll.maxClicksPerAxis) * PointerScroll.pointsPerClick)
        XCTAssertTrue(burst.masks.allSatisfy { $0 == PointerButtons.wheelUp || $0 == PointerButtons.none })
    }

    func testFramebufferMappingLetterboxesFillsAndClamps() {
        let fit = (viewWidth: 200.0, viewHeight: 200.0, imageWidth: 100.0, imageHeight: 50.0, fill: false)
        let origin = PointerMapping.framebufferPoint(viewX: 0, viewY: 50, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: false)
        XCTAssertEqual(origin, PointerMapping.Point(x: 0, y: 0))
        XCTAssertNil(PointerMapping.framebufferPoint(viewX: 0, viewY: 0, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: false))
        let clamped = PointerMapping.framebufferPoint(viewX: 0, viewY: 0, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: true)
        XCTAssertEqual(clamped, PointerMapping.Point(x: 0, y: 0))
        let center = PointerMapping.framebufferPoint(viewX: 100, viewY: 100, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: false)
        XCTAssertEqual(center, PointerMapping.Point(x: 50, y: 25))
        let edge = PointerMapping.framebufferPoint(viewX: 200, viewY: 150, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: true)
        XCTAssertEqual(edge, PointerMapping.Point(x: 99, y: 49))
        let fractional = PointerMapping.framebufferPoint(viewX: 21.8, viewY: 70.9, viewWidth: fit.viewWidth, viewHeight: fit.viewHeight, imageWidth: fit.imageWidth, imageHeight: fit.imageHeight, fill: fit.fill, clamp: false)
        XCTAssertEqual(fractional, PointerMapping.Point(x: 10, y: 10))

        let filled = PointerMapping.framebufferPoint(viewX: 0, viewY: 0, viewWidth: 200, viewHeight: 200, imageWidth: 100, imageHeight: 50, fill: true, clamp: false)
        XCTAssertEqual(filled, PointerMapping.Point(x: 25, y: 0))
        XCTAssertNil(PointerMapping.framebufferPoint(viewX: 1, viewY: 1, viewWidth: 0, viewHeight: 10, imageWidth: 10, imageHeight: 10, fill: false, clamp: true))
        XCTAssertNil(PointerMapping.displayedFrame(viewWidth: 10, viewHeight: 10, imageWidth: 0, imageHeight: 10, fill: false))
    }
}
