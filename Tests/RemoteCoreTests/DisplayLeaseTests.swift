import XCTest
import DisplaySupport
import RemoteCore

final class DisplayLeaseTests: XCTestCase {
    func testOnlyTailnetAndLoopbackPeersAreAllowed() {
        for address in ["100.120.15.22", "127.0.0.1", "::1", "::ffff:100.76.124.88", "fd7a:115c:a1e0::123"] { XCTAssertTrue(DisplayPeer.isAllowed(address)) }
        for address in ["192.168.0.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "100.64.0.999", "::ffff:192.168.0.1"] { XCTAssertFalse(DisplayPeer.isAllowed(address)) }
    }
    func testMultipleChangesPreserveOriginalMode() {
        var lease = DisplayLease()
        let now = Date(timeIntervalSince1970: 1000)
        lease.changed(from: 42, now: now)
        lease.changed(from: 77, now: now.addingTimeInterval(10))
        XCTAssertEqual(lease.originalModeID, 42)
        XCTAssertFalse(lease.expired(now: now.addingTimeInterval(69)))
        XCTAssertTrue(lease.expired(now: now.addingTimeInterval(70)))
    }
    func testHeartbeatRenewsRestoreDeadline() {
        var lease = DisplayLease()
        let now = Date(timeIntervalSince1970: 1000)
        lease.changed(from: 42, now: now)
        lease.renew(now: now.addingTimeInterval(30))
        XCTAssertFalse(lease.expired(now: now.addingTimeInterval(60)))
        XCTAssertTrue(lease.expired(now: now.addingTimeInterval(90)))
    }
    func testRestoredSessionCannotBeReactivatedByLateHeartbeat() {
        var lease = DisplayLease()
        let now = Date()
        lease.changed(from: 42, now: now); lease.clear(); lease.renew(now: now)
        XCTAssertNil(lease.originalModeID); XCTAssertNil(lease.expiresAt)
        XCTAssertFalse(lease.expired(now: now.addingTimeInterval(120)))
    }
    func testResolutionListKeepsLowModesAndBothPixelDensities() {
        let modes = [
            RemoteDisplayMode(id: 7, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080),
            RemoteDisplayMode(id: 5, width: 1280, height: 800, pixelWidth: 1280, pixelHeight: 800),
            RemoteDisplayMode(id: 1, width: 640, height: 480, pixelWidth: 640, pixelHeight: 480),
            RemoteDisplayMode(id: 4, width: 1280, height: 800, pixelWidth: 2560, pixelHeight: 1600),
            RemoteDisplayMode(id: 3, width: 1280, height: 800, pixelWidth: 1280, pixelHeight: 800),
            RemoteDisplayMode(id: 2, width: 720, height: 450, pixelWidth: 720, pixelHeight: 450),
            RemoteDisplayMode(id: 6, width: 8000, height: 5000, pixelWidth: 8000, pixelHeight: 5000),
            RemoteDisplayMode(id: 8, width: 0, height: 480, pixelWidth: 640, pixelHeight: 480)
        ]
        XCTAssertEqual(DisplayModes.offered(modes).map(\.id), [1, 2, 3, 4, 7])
        XCTAssertEqual(DisplayModes.offered(modes).map(\.title), ["640 × 480", "720 × 450", "1280 × 800", "1280 × 800 · Retina", "1920 × 1080"])
        XCTAssertTrue(DisplayModes.fits(RemoteDisplayMode(id: 9, width: 6016, height: 3384, pixelWidth: 6016, pixelHeight: 3384)))
        XCTAssertFalse(DisplayModes.fits(RemoteDisplayMode(id: 10, width: 8192, height: 8192, pixelWidth: 8192, pixelHeight: 8192)))
    }
    func testRotationProbeOptionsMatchFramebufferQuadrants() throws {
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: 0), 0x400)
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: 90), 0x480)
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: 180), 0x500)
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: 270), 0x580)
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: 360), 0x400)
        XCTAssertEqual(DisplayRotationAngle.probeOptions(degrees: -90), 0x580)
        XCTAssertNil(DisplayRotationAngle.probeOptions(degrees: 45))
        XCTAssertEqual(DisplayRotationAngle.portraitToggle(from: 0), 90)
        XCTAssertEqual(DisplayRotationAngle.portraitToggle(from: 90), 0)
        XCTAssertEqual(DisplayRotationAngle.portraitToggle(from: 180), 0)
        let encoded = try JSONEncoder().encode(DisplayRotation(degrees: 90, supported: false))
        let decoded = try JSONDecoder().decode(DisplayRotation.self, from: encoded)
        XCTAssertEqual(decoded, DisplayRotation(degrees: 90, supported: false))
        let request = try JSONDecoder().decode(SetDisplayRotation.self, from: Data(#"{"degrees":270}"#.utf8))
        XCTAssertEqual(request.degrees, 270)
    }
    func testAppleSiliconRotationDoesNotUseTheIOKitProbe() {
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: true, monitorPanelRejected: false, appleSilicon: true, iokitFramebuffer: false), .monitorPanel)
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: false, monitorPanelRejected: false, appleSilicon: true, iokitFramebuffer: true), .unsupported)
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: false, monitorPanelRejected: true, appleSilicon: false, iokitFramebuffer: true), .unsupported)
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: false, monitorPanelRejected: false, appleSilicon: false, iokitFramebuffer: true), .iokit)
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: true, monitorPanelRejected: false, appleSilicon: false, iokitFramebuffer: true), .monitorPanel)
        XCTAssertEqual(DisplayRotationRoute.select(monitorPanelReady: false, monitorPanelRejected: false, appleSilicon: false, iokitFramebuffer: false), .unsupported)
    }
    func testLandscapeFramebufferIsNotAFailedPortraitRotation() {
        XCTAssertTrue(DisplayOrientationCheck.matches(width: 1920, height: 1080, degrees: 0))
        XCTAssertTrue(DisplayOrientationCheck.matches(width: 1920, height: 1080, degrees: 180))
        XCTAssertFalse(DisplayOrientationCheck.matches(width: 1920, height: 1080, degrees: 90))
        XCTAssertTrue(DisplayOrientationCheck.matches(width: 1080, height: 1920, degrees: 90))
        XCTAssertTrue(DisplayOrientationCheck.matches(width: 1080, height: 1920, degrees: 270))
        XCTAssertFalse(DisplayOrientationCheck.matches(width: 1080, height: 1920, degrees: 0))
        XCTAssertFalse(DisplayOrientationCheck.matches(width: 0, height: 1080, degrees: 0))
        XCTAssertTrue(DisplayOrientationCheck.isPortrait(90))
        XCTAssertFalse(DisplayOrientationCheck.isPortrait(0))
        XCTAssertEqual(DisplayOrientationCheck.failureTitle(degrees: 0), "가로 모드")
        XCTAssertEqual(DisplayOrientationCheck.failureTitle(degrees: 180), "가로 모드")
        XCTAssertEqual(DisplayOrientationCheck.failureTitle(degrees: 90), "세로 모드")
        XCTAssertEqual(DisplayOrientationCheck.failureTitle(degrees: 45), "화면 회전")
    }
    func testResolutionListUsesAShortTimeout() {
        XCTAssertLessThanOrEqual(DisplayHTTP.listTimeout, 3)
        XCTAssertGreaterThan(DisplayHTTP.rotationTimeout, 5)
        XCTAssertLessThanOrEqual(DisplayHTTP.rotationTimeout, 6)
    }
    func testConnectedToolbarKeepsTheKeyboardButtonOnANarrowPhone() {
        for portrait in [false, true] {
            let titles = SessionControls.titles(macIsPortrait: portrait)
            XCTAssertEqual(titles.last, SessionControls.keyboard)
            XCTAssertTrue(SessionControls.fits(macIsPortrait: portrait, width: 320))
            let open = SessionControls.legacyTitles(macIsPortrait: portrait, keyboardShown: true)
            let closed = SessionControls.legacyTitles(macIsPortrait: portrait, keyboardShown: false)
            XCTAssertGreaterThan(SessionControls.rowWidth(titles: open, horizontalPadding: 32), 320)
            XCTAssertGreaterThan(SessionControls.captionWidth(open.last ?? ""), SessionControls.captionWidth(closed.last ?? ""))
        }
        XCTAssertEqual(SessionControls.titles(macIsPortrait: true), ["입력기", "해상도", "가로", "키보드"])
        XCTAssertEqual(SessionControls.titles(macIsPortrait: false), ["입력기", "해상도", "세로", "키보드"])
    }
    func testPortraitFramebufferStaysTallInTheView() {
        let frame = PointerMapping.displayedFrame(viewWidth: 800, viewHeight: 400, imageWidth: 1080, imageHeight: 1920, fill: false)
        XCTAssertEqual(frame?.height ?? 0, 400, accuracy: 0.01)
        XCTAssertLessThan(frame?.width ?? 0, frame?.height ?? 0)
        XCTAssertTrue(FrameLimits.contains(width: 1080, height: 1920))
    }
    func testPairingCodeIsGroupedAndSizedForALargeWindow() {
        XCTAssertEqual(PairingCodePresentation.groupedDigits("123456"), "123 456")
        XCTAssertEqual(PairingCodePresentation.groupedDigits("12345"), "12345")
        XCTAssertEqual(PairingCodePresentation.digitPointSize(screenHeight: 800), 200)
        XCTAssertEqual(PairingCodePresentation.digitPointSize(screenHeight: 1600), 400)
        XCTAssertEqual(PairingCodePresentation.digitPointSize(screenHeight: 100), 45)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PairingCodePresentation.remainingLabel(until: now.addingTimeInterval(125), now: now), "남은 시간 2:05")
        XCTAssertEqual(PairingCodePresentation.remainingLabel(until: now.addingTimeInterval(60), now: now), "남은 시간 1:00")
        XCTAssertNil(PairingCodePresentation.remainingLabel(until: now, now: now))
        XCTAssertNil(PairingCodePresentation.remainingLabel(until: now.addingTimeInterval(-1), now: now))
    }
    func testResolutionReturnsOnlyOnAutomaticReconnect() {
        XCTAssertEqual(DisplayReconnect.mode(reconnecting: true, selected: 42), 42)
        XCTAssertNil(DisplayReconnect.mode(reconnecting: false, selected: 42))
        XCTAssertNil(DisplayReconnect.mode(reconnecting: true, selected: nil))
    }
}
