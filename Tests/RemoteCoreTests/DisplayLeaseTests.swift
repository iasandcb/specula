import XCTest
import DisplaySupport

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
}
