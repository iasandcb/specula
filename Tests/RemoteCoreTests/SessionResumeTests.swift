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
        XCTAssertEqual(session.linkClosed(), [])
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.scene(.active), [.reconnect])
        XCTAssertEqual(session.link, .reconnecting)
    }

    func testForegroundDropReconnectsOnceAndAFailedRetryWaits() {
        var session = liveSession()
        XCTAssertEqual(session.linkClosed(), [.reconnect])
        XCTAssertEqual(session.linkClosed(), [])
        XCTAssertEqual(session.link, .down)
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.scene(.background), [])
        XCTAssertEqual(session.scene(.active), [.reconnect])
    }

    func testBackgroundDropWaitsUntilForeground() {
        var session = liveSession()
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertEqual(session.linkClosed(), [])
        XCTAssertEqual(session.link, .down)
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.scene(.active), [.endBackgroundTask, .reconnect])
    }

    func testUserDisconnectEndsTheTaskAndReturnsToTheForm() {
        var session = liveSession()
        _ = session.scene(.background)
        XCTAssertEqual(session.userDisconnected(), [.endBackgroundTask])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.linkClosed(), [])
        XCTAssertEqual(session.scene(.active), [])
    }

    func testFirstAttemptFailureDoesNotReconnectOrStayOnTheRemoteScreen() {
        var session = SessionResume()
        session.beginManualConnect()
        XCTAssertTrue(session.presentsRemote)
        XCTAssertEqual(session.scene(.background), [.beginBackgroundTask])
        XCTAssertEqual(session.linkClosed(), [])
        XCTAssertFalse(session.presentsRemote)
        XCTAssertEqual(session.scene(.active), [.endBackgroundTask])
    }

    private func liveSession() -> SessionResume {
        var session = SessionResume()
        session.beginManualConnect()
        session.noteLive()
        return session
    }
}
