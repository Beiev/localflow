import XCTest
@testable import LocalFlowCore

final class CaptureHealthTests: XCTestCase {
    func testMissingFirstBufferTriggersBoundedRecovery() {
        var health = CaptureHealth(now: 100)
        XCTAssertFalse(health.receivedAudio)
        XCTAssertFalse(health.isStalled(at: 102))
        XCTAssertTrue(health.isStalled(at: 102.5))
        XCTAssertTrue(health.beginRecovery(at: 102.5))
        XCTAssertFalse(health.isStalled(at: 104))
        XCTAssertTrue(health.beginRecovery(at: 105))
        XCTAssertFalse(health.beginRecovery(at: 107.5))
    }
    func testSilenceAndPauseStillDeliverBuffersAndDoNotTriggerRecovery() {
        var health = CaptureHealth(now: 0)
        for second in 1...120 {
            health.didReceiveAudio(at: Double(second))
            XCTAssertFalse(health.isStalled(at: Double(second) + 0.5))
        }
        XCTAssertTrue(health.receivedAudio)
        XCTAssertEqual(health.recoveries, 0)
        XCTAssertTrue(health.isStalled(at: 123))
    }
    func testRecoveryRequiresFreshAudioBeforeReportingReady() {
        var health = CaptureHealth(now: 0)
        health.didReceiveAudio(at: 1)
        XCTAssertTrue(health.receivedAudio)
        XCTAssertTrue(health.beginRecovery(at: 4))
        XCTAssertFalse(health.receivedAudio)
        health.didReceiveAudio(at: 5)
        XCTAssertTrue(health.receivedAudio)
        XCTAssertFalse(health.isStalled(at: 6))
    }
}
