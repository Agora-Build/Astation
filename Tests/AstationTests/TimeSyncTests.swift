import XCTest

@testable import Menubar

final class TimeSyncTests: XCTestCase {

    func testNewTimeSyncHasZeroOffset() {
        let ts = TimeSync()
        XCTAssertEqual(ts.offset, 0)
    }

    func testNowReturnsReasonableTimestamp() async {
        let ts = TimeSync()
        let now = await ts.now()
        // Should be within 60 seconds of local clock
        let local = UInt32(Date().timeIntervalSince1970)
        let diff = abs(Int64(now) - Int64(local))
        XCTAssertLessThan(diff, 60, "TimeSync.now() should be within 60s of local clock")
    }

    func testNowReturnsNonZero() async {
        let ts = TimeSync()
        let now = await ts.now()
        XCTAssertGreaterThan(now, 0, "Timestamp should be non-zero")
    }

    func testTimestampIsInReasonableRange() async {
        let ts = TimeSync()
        let now = await ts.now()
        // Should be after 2024-01-01 (1704067200) and before 2030-01-01 (1893456000)
        XCTAssertGreaterThan(now, 1_704_067_200, "Timestamp should be after 2024-01-01")
        XCTAssertLessThan(now, 1_893_456_000, "Timestamp should be before 2030-01-01")
    }

    func testMultipleCallsReturnConsistentTimestamps() async {
        let ts = TimeSync()
        let t1 = await ts.now()
        let t2 = await ts.now()
        // Second call should be >= first (monotonic) and within 2 seconds
        XCTAssertGreaterThanOrEqual(t2, t1, "Timestamps should be non-decreasing")
        XCTAssertLessThanOrEqual(t2 - t1, 2, "Consecutive calls should be within 2s")
    }

    func testOffsetAfterNowCall() async {
        let ts = TimeSync()
        _ = await ts.now()
        // After sync, offset should be small (within 60s assuming reasonable clock)
        let off = ts.offset
        XCTAssertLessThan(abs(off), 60, "Offset should be small if clocks are reasonably in sync")
    }
}
