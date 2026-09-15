import XCTest
import LocalFlowCore

final class MetricsTests: XCTestCase {
    func testNearestRankPercentilesIgnoreInvalidDurations() {
        let report = LatencyDistribution((1...20).map(Double.init) + [.nan, .infinity, -1])
        XCTAssertEqual(report.count, 20); XCTAssertEqual(report.p50, 10); XCTAssertEqual(report.p95, 19)
        XCTAssertNil(LatencyDistribution([]).p95)
        XCTAssertEqual(LatencyDistribution([0.4]).p95, 0.4)
    }
    func testWarmColdAndFailedInsertionsStaySeparate() {
        var warm = DictationMetrics(appVersion: "test", editorID: "fixture", speechWasLoaded: true, editorWasLoaded: true)
        warm.stopToReadySeconds = 0.3; warm.pasteSucceeded = true; warm.stopToPasteSeconds = 0.5
        var cold = warm; cold.editorWasLoaded = false; cold.stopToPasteSeconds = 2
        var failed = warm; failed.pasteSucceeded = false; failed.stopToPasteSeconds = nil; failed.usedFallback = true
        let report = DictationReport([warm, cold, failed])
        XCTAssertEqual(report.measured, 3); XCTAssertEqual(report.insertionFailures, 1); XCTAssertEqual(report.fallbacks, 1)
        XCTAssertEqual(report.stopToPasteWarm.count, 1); XCTAssertEqual(report.stopToPasteWarm.p95, 0.5)
        XCTAssertEqual(report.stopToPasteCold.count, 1); XCTAssertEqual(report.stopToPasteCold.p95, 2)
        XCTAssertEqual(DictationReport([]).stopToPasteWarm.count, 0)
        XCTAssertNil(DictationReport([]).stopToPasteWarm.p95)
    }
}
