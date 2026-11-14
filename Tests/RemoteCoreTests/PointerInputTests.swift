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

    func testPointerMotionCollapsesAndButtonsStayImmediate() {
        var coalescer = PointerCoalescer()
        let first = coalescer.submit(.init(x: 0, y: 0, buttons: 0), nowMs: 0)
        XCTAssertEqual(first.send, [.init(x: 0, y: 0, buttons: 0)])
        let moved = coalescer.submit(.init(x: 4, y: 1, buttons: 0), nowMs: 5)
        XCTAssertEqual(moved.send, [])
        XCTAssertEqual(moved.flushAfterMs, 11)
        let replaced = coalescer.submit(.init(x: 9, y: 2, buttons: 0), nowMs: 8)
        XCTAssertEqual(replaced.send, [])
        let early = coalescer.flush(nowMs: 10)
        XCTAssertEqual(early.send, [])
        let flushed = coalescer.flush(nowMs: 16)
        XCTAssertEqual(flushed.send, [.init(x: 9, y: 2, buttons: 0)])

        let down = coalescer.submit(.init(x: 9, y: 2, buttons: PointerButtons.left), nowMs: 17)
        XCTAssertEqual(down.send, [.init(x: 9, y: 2, buttons: PointerButtons.left)])
        let up = coalescer.submit(.init(x: 9, y: 2, buttons: 0), nowMs: 17)
        XCTAssertEqual(up.send, [.init(x: 9, y: 2, buttons: 0)])

        var wheel = PointerCoalescer()
        var sent: [PointerCoalescer.Sample] = []
        for mask in [PointerButtons.wheelUp, PointerButtons.none, PointerButtons.wheelDown, PointerButtons.none] {
            sent.append(contentsOf: wheel.submit(.init(x: 3, y: 4, buttons: mask), nowMs: 0).send)
        }
        XCTAssertEqual(sent.map(\.buttons), [PointerButtons.wheelUp, PointerButtons.none, PointerButtons.wheelDown, PointerButtons.none])
    }

    func testCursorGlyphNeverStacksAndTinyCursorsGrowWithoutMovingTheHotspot() {
        XCTAssertEqual(PointerGlyph.choose(pointerInUse: false, hasServerCursor: true, serverHidCursor: false), .hidden)
        XCTAssertEqual(PointerGlyph.choose(pointerInUse: true, hasServerCursor: false, serverHidCursor: false), .localArrow)
        XCTAssertEqual(PointerGlyph.choose(pointerInUse: true, hasServerCursor: true, serverHidCursor: false), .server)
        XCTAssertEqual(PointerGlyph.choose(pointerInUse: true, hasServerCursor: false, serverHidCursor: true), .hidden)
        XCTAssertEqual(PointerGlyph.choose(pointerInUse: true, hasServerCursor: true, serverHidCursor: true), .hidden)

        let grown = CursorLayout.frame(pointerX: 100, pointerY: 80, hotspotX: 1, hotspotY: 2, cursorWidth: 16, cursorHeight: 16, pointScale: 0.5)
        XCTAssertEqual(grown?.height, 22)
        XCTAssertEqual(grown?.width, 22)
        XCTAssertEqual(grown?.x, 100 - 22 / 16)
        XCTAssertEqual(grown?.y, 80 - 2 * 22 / 16)
        let natural = CursorLayout.frame(pointerX: 10, pointerY: 10, hotspotX: 0, hotspotY: 0, cursorWidth: 32, cursorHeight: 32, pointScale: 2)
        XCTAssertEqual(natural, CursorLayout(x: 10, y: 10, width: 64, height: 64))
        XCTAssertNil(CursorLayout.frame(pointerX: 0, pointerY: 0, hotspotX: 0, hotspotY: 0, cursorWidth: 0, cursorHeight: 8, pointScale: 1))
    }
}
