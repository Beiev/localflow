import XCTest
@testable import LocalFlowCore

final class RussianDatesTests: XCTestCase {
    private let october = Date(timeIntervalSince1970: 1_761_436_800)

    func testADateReadsInRussian() {
        XCTAssertEqual(RussianDates.day(october, now: october), "26 октября")
        let nextYear = october.addingTimeInterval(400 * 86400)
        XCTAssertTrue(RussianDates.day(october, now: nextYear).hasSuffix("2025"), "чужой год называется")
    }
    func testTheNearestDaysAreCalledByName() {
        XCTAssertEqual(RussianDates.dayLabel(october, now: october), "Сегодня")
        XCTAssertEqual(RussianDates.dayLabel(october, now: october.addingTimeInterval(86400)), "Вчера")
        XCTAssertEqual(RussianDates.dayLabel(october, now: october.addingTimeInterval(5 * 86400)), "26 октября")
    }
    /// A two-hour call read "127:14" before this.
    func testAnHourIsShownAsAnHour() {
        XCTAssertEqual(RussianDates.length(94), "1:34")
        XCTAssertEqual(RussianDates.length(7634), "2:07:14")
        XCTAssertEqual(RussianDates.length(0), "0:00")
    }
}

final class AutomaticTitleTests: XCTestCase {
    func testAMeetingIsNamedAfterWhatItWasAbout() {
        XCTAssertEqual(RecordingSession.title(fromTopics: ["Удержание и заявки", "Хостинг и домен"]),
                       "Удержание и заявки, хостинг и домен")
    }
    func testATimeSpanIsNotAName() {
        XCTAssertNil(RecordingSession.title(fromTopics: ["[04:02]–[09:36]"]))
        XCTAssertEqual(RecordingSession.title(fromTopics: ["[04:02]–[09:36]", "Хостинг"]), "Хостинг")
    }
    func testALongListIsCutAtAWholeTopic() {
        let name = RecordingSession.title(fromTopics: ["Удержание и новые заявки", "Производство роликов и маржа", "Хостинг"])
        XCTAssertEqual(name, "Удержание и новые заявки, производство роликов и маржа")
    }
    func testANewRecordingKnowsItsTitleIsAutomatic() {
        XCTAssertTrue(RecordingSession(kind: .meeting).titleIsAutomatic)
    }
}

final class IdleSettingTests: XCTestCase {
    func testAnUnwrittenSettingTakesTheDefault() {
        XCTAssertEqual(0.nonzero(default: 60), 60)
    }
    /// "Не выгружать" is stored as a negative, and reading it as unset turned the choice back into
    /// a minute.
    func testAChoiceToKeepTheWeightsSurvives() {
        XCTAssertEqual((-1).nonzero(default: 60), -1)
        XCTAssertEqual(180.nonzero(default: 60), 180)
    }
}
