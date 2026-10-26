import XCTest
@testable import LocalFlowCore

final class ScreenContextTests: XCTestCase {
    private func signature(_ value: UInt8, size: Int = 256) -> [UInt8] { Array(repeating: value, count: size) }

    // MARK: - What counts as a change

    func testAnUnchangedScreenIsNotWorthReadingAgain() {
        XCTAssertFalse(ScreenContext.changed(signature(100), from: signature(100)))
    }
    /// A cursor crossing the screen or a camera tile breathing moves very few of the pixels.
    func testSmallMovementDoesNotCountAsANewScreen() {
        var next = signature(100)
        for index in 0..<6 { next[index] = 255 }
        XCTAssertFalse(ScreenContext.changed(next, from: signature(100)))
    }
    func testANewSlideCountsAsANewScreen() {
        XCTAssertTrue(ScreenContext.changed(signature(200), from: signature(100)))
    }
    func testTheFirstFrameAndAResizeAlwaysCountAsChanged() {
        XCTAssertTrue(ScreenContext.changed(signature(100), from: []))
        XCTAssertTrue(ScreenContext.changed(signature(100, size: 64), from: signature(100, size: 256)))
    }

    // MARK: - What text is worth keeping

    func testReadingDropsNoiseAndRepeats() {
        let text = ScreenContext.reading(["  Launch plan  ", "Launch plan", "—", "14:02", "3", "TG channel", "", "a"])
        XCTAssertEqual(text, "Launch plan\nTG channel")
    }
    func testReadingKeepsTheOrderItWasReadIn() {
        XCTAssertEqual(ScreenContext.reading(["Первое", "Второе", "Третье"]), "Первое\nВторое\nТретье")
    }
    func testReadingIsCappedSoAWallOfTextCannotCrowdOutTheTranscript() {
        let dense = (0..<200).map { "строка номер \($0) с каким-то содержимым" }
        let text = ScreenContext.reading(dense)
        XCTAssertLessThanOrEqual(text.count, ScreenContext.longestText + 1)
        XCTAssertTrue(text.hasSuffix("…"))
    }
    func testANumberOnItsOwnIsNotWhatWasBeingShown() {
        XCTAssertEqual(ScreenContext.reading(["12:04", "99", "0,5"]), "")
    }

    // MARK: - Moments, not instants

    func testThePeriodOneScreenWasShownBecomesOneMoment() {
        let samples = (0..<5).map { index in
            ScreenSample(time: Double(index) * 5, app: "Notion", window: "Launch plan",
                         lines: ["Launch plan", "TG channel", "Site structure"])
        }
        let moments = ScreenContext.moments(samples)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].start, 0)
        XCTAssertEqual(moments[0].end, 20)
        XCTAssertEqual(moments[0].window, "Launch plan")
        XCTAssertEqual(moments[0].timestamp, "00:00")
    }
    func testADifferentWindowStartsANewMoment() {
        let samples = [
            ScreenSample(time: 0, app: "Notion", window: "Launch plan", lines: ["Launch plan", "TG channel"]),
            ScreenSample(time: 5, app: "Notion", window: "Launch plan", lines: ["Launch plan", "TG channel"]),
            ScreenSample(time: 10, app: "Safari", window: "Pricing", lines: ["Pricing", "Base tier", "Mid tier"]),
        ]
        let moments = ScreenContext.moments(samples)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[0].end, 10, "первый экран был на виду, пока его не сменил второй")
        XCTAssertEqual(moments[1].start, 10)
    }
    /// Only a frame that differs from the last one read is journalled, so a slide nobody touched
    /// produces one sample. Ending its moment where it began hid it from every stretch of
    /// conversation that happened while it was up — which is the whole point of reading it.
    func testASlideLeftAloneLastsUntilSomethingReplacesIt() {
        let samples = [
            ScreenSample(time: 0, app: "Keynote", window: "Deck", lines: ["Пороги и тарифы", "Базовый уровень"]),
            ScreenSample(time: 300, app: "Safari", window: "Pricing", lines: ["Pricing", "Base tier", "Mid tier"]),
        ]
        let moments = ScreenContext.moments(samples)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[0].start, 0)
        XCTAssertEqual(moments[0].end, 300)
        XCTAssertEqual(moments[0].duration, 300)
    }
    func testDifferentTextInTheSameWindowStartsANewMoment() {
        let samples = [
            ScreenSample(time: 0, app: "Notion", window: "Doc", lines: ["Первый раздел", "про запуск канала"]),
            ScreenSample(time: 5, app: "Notion", window: "Doc", lines: ["Совершенно другое", "про метаданные и профили"]),
        ]
        XCTAssertEqual(ScreenContext.moments(samples).count, 2)
    }
    /// A dashboard loads in pieces; the fullest reading is the one worth keeping.
    func testTheFullestReadingOfAScreenWins() {
        let samples = [
            ScreenSample(time: 0, app: "Safari", window: "Dashboard", lines: ["Revenue"]),
            ScreenSample(time: 5, app: "Safari", window: "Dashboard", lines: ["Revenue", "Orders", "Retention 30%"]),
        ]
        let moments = ScreenContext.moments(samples)
        XCTAssertEqual(moments.count, 1)
        XCTAssertTrue(moments[0].text.contains("Retention 30%"))
    }
    func testAMomentStillOnScreenAtTheEndLastsUntilTheEnd() {
        let samples = [ScreenSample(time: 100, app: "Notion", window: "Doc", lines: ["Launch plan", "и ещё немного текста"])]
        let moments = ScreenContext.moments(samples, until: 160)
        XCTAssertEqual(moments[0].end, 160)
    }
    func testAMomentDoesNotGrowPastItsLimitSoItsTimestampKeepsMeaning() {
        let samples = (0..<200).map { index in
            ScreenSample(time: Double(index) * 5, app: "Notion", window: "Doc", lines: ["Launch plan", "и ещё немного текста"])
        }
        let moments = ScreenContext.moments(samples)
        XCTAssertGreaterThan(moments.count, 1)
        XCTAssertTrue(moments.allSatisfy { $0.duration <= ScreenContext.longestMoment })
    }
    func testFramesWithNothingReadableAreNotMoments() {
        XCTAssertTrue(ScreenContext.moments([ScreenSample(time: 0, lines: ["12:04", "x"])]).isEmpty)
    }
    func testOverlappingMomentsAreFoundForAStretchOfSpeech() {
        let all = [
            ScreenMoment(start: 0, end: 30, window: "Launch plan", text: "Launch plan"),
            ScreenMoment(start: 40, end: 90, window: "Pricing", text: "Pricing"),
        ]
        XCTAssertEqual(ScreenContext.moments(all, overlapping: 25, to: 45).count, 2)
        XCTAssertEqual(ScreenContext.moments(all, overlapping: 95, to: 120).count, 0)
        XCTAssertEqual(ScreenContext.moments(all, overlapping: 50, to: 60).first?.window, "Pricing")
    }
    func testAMomentIsNamedByItsWindowThenItsAppThenItsText() {
        XCTAssertEqual(ScreenMoment(start: 0, end: 1, app: "Notion", window: "Launch plan", text: "x").title, "Launch plan")
        XCTAssertEqual(ScreenMoment(start: 0, end: 1, app: "Notion", window: "", text: "x").title, "Notion")
        XCTAssertEqual(ScreenMoment(start: 0, end: 1, text: "первые слова с экрана").title, "первые слова с экрана")
    }
}
