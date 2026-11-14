import XCTest
@testable import RemoteCore

final class SessionResumeTests: XCTestCase {
    func testBackgroundKeepsTheLinkAndForegroundOfALiveSessionDoesNotReconnect() {
        var session = liveSession()
        XCTAssertEqual(session.scene(.inactive), [])
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertTrue(session.backgroundTaskOpen)
        XCTAssertEqual(session.link, .live)
        XCTAssertEqual(session.scene(.inactive), [.endBackgroundTask])
        XCTAssertEqual(session.scene(.active), [])
        XCTAssertEqual(session.link, .live)
        XCTAssertTrue(session.presentsRemote)
    }

    func testExpirationEndsTheTaskWithoutForgettingTheSession() {
        var session = liveSession()
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertEqual(session.backgroundExpired(), [.endBackgroundTask])
        XCTAssertEqual(session.backgroundExpired(), [])
        XCTAssertFalse(session.userEnded)
        XCTAssertTrue(session.hasCredentials)
        XCTAssertEqual(session.linkClosed(.transport), [])
        XCTAssertTrue(session.presentsRemote)
        XCTAssertTrue(session.everLive)
        XCTAssertEqual(session.scene(.active), [.reconnect(afterMilliseconds: 400)])
        XCTAssertEqual(session.link, .reconnecting)
    }

    func testTransportDropsRetryThreeTimesThenReturnToTheConnectScreen() {
        var session = liveSession()
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 400)])
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 1_200)])
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 2_500)])
        XCTAssertEqual(session.linkClosed(.transport), [])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.link, .down)
        XCTAssertEqual(session.scene(.background), [])
        XCTAssertEqual(session.scene(.active), [])
    }

    func testADecodedFrameResetsTheReconnectBudget() {
        var session = liveSession()
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 400)])
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 1_200)])
        session.noteFrame()
        XCTAssertEqual(session.automaticReconnects, 0)
        XCTAssertEqual(session.linkClosed(.transport), [.reconnect(afterMilliseconds: 400)])
    }

    func testProtocolErrorStopsInsteadOfReconnecting() {
        var session = liveSession()
        XCTAssertEqual(session.linkClosed(.protocolError), [])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertFalse(session.acceptsSessionEvents)
        XCTAssertEqual(session.scene(.active), [])
    }

    func testInitialConnectFailureDoesNotEnterReconnecting() {
        var session = SessionResume()
        session.beginManualConnect()
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.linkClosed(.protocolError), [])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.link, .down)

        var transport = SessionResume()
        transport.beginManualConnect()
        XCTAssertEqual(transport.linkClosed(.transport), [])
        XCTAssertFalse(transport.presentsRemote)
        XCTAssertNotEqual(transport.link, .reconnecting)
    }

    func testBackgroundDropWaitsUntilForeground() {
        var session = liveSession()
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertEqual(session.linkClosed(.transport), [])
        XCTAssertEqual(session.link, .down)
        XCTAssertTrue(session.everLive)
        XCTAssertEqual(session.scene(.active), [.endBackgroundTask, .reconnect(afterMilliseconds: 400)])
    }

    func testUserDisconnectEndsTheTaskAndReturnsToTheForm() {
        var session = liveSession()
        _ = session.scene(.background)
        XCTAssertEqual(session.userDisconnected(), [.endBackgroundTask])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.linkClosed(.transport), [])
        XCTAssertEqual(session.scene(.active), [])
    }

    func testFirstAttemptFailureDoesNotReconnectOrStayOnTheRemoteScreen() {
        var session = SessionResume()
        session.beginManualConnect()
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertEqual(session.linkClosed(.transport), [])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.scene(.active), [.endBackgroundTask])
    }

    func testNoteFrameAfterGiveUpDoesNotReviveTheSession() {
        var session = liveSession()
        XCTAssertEqual(session.linkClosed(.protocolError), [])
        session.noteFrame()
        XCTAssertFalse(session.everLive)
        XCTAssertFalse(session.acceptsSessionEvents)
    }

    private func liveSession() -> SessionResume {
        var session = SessionResume()
        session.beginManualConnect()
        session.noteFrame()
        return session
    }
}
