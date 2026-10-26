import XCTest
@testable import LocalFlowCore

final class MeetingWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func later(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testNothingIsOfferedUntilTheMicrophoneHasBeenHeldLongEnough() {
        var watch = MeetingWatch()
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: false, now: start))
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(10)),
                       "десять секунд — это голосовое, а не созвон")
        XCTAssertTrue(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(MeetingWatch.settle)))
    }
    /// Either signal alone is noise: a browser is always running, and the microphone is held by
    /// plenty of things that are not conversations.
    func testBothSignalsAreRequired() {
        var watch = MeetingWatch()
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: false, busy: false, now: start))
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: false, busy: false, now: later(600)))
        XCTAssertFalse(watch.update(inputBusy: false, conferencing: true, busy: false, now: later(601)))
    }
    func testNothingIsOfferedWhileThisApplicationIsBusy() {
        var watch = MeetingWatch()
        _ = watch.update(inputBusy: true, conferencing: true, busy: true, now: start)
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: true, now: later(300)),
                       "своя же запись держит микрофон")
    }
    func testAnAnsweredOfferDoesNotComeBackForTheSameCall() {
        var watch = MeetingWatch()
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: start)
        XCTAssertTrue(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(30)))
        watch.answer()
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(40)))
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(3000)))
    }
    /// The next call is a different call. Waving one away must not mean never again.
    func testTheNextCallIsOfferedAgain() {
        var watch = MeetingWatch()
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: start)
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: later(30))
        watch.answer()
        XCTAssertFalse(watch.update(inputBusy: false, conferencing: true, busy: false, now: later(60)), "созвон кончился")
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: later(600))
        XCTAssertTrue(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(630)))
    }
    func testTheRunRestartsWhenTheMicrophoneIsReleased() {
        var watch = MeetingWatch()
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: start)
        _ = watch.update(inputBusy: false, conferencing: true, busy: false, now: later(5))
        XCTAssertNil(watch.since)
        _ = watch.update(inputBusy: true, conferencing: true, busy: false, now: later(6))
        XCTAssertFalse(watch.update(inputBusy: true, conferencing: true, busy: false, now: later(20)),
                       "отсчёт начинается заново")
    }
    func testKnownConferencingApplicationsAreRecognisedByBundleIdentifier() {
        XCTAssertTrue(MeetingWatch.isConferencing(["com.apple.finder", "us.zoom.xos"]))
        XCTAssertTrue(MeetingWatch.isConferencing(["com.google.Chrome"]))
        XCTAssertFalse(MeetingWatch.isConferencing(["com.apple.finder", "com.apple.Notes"]))
        XCTAssertFalse(MeetingWatch.isConferencing([]))
    }
}

final class CalendarNamingTests: XCTestCase {
    func testADisplayNameBecomesAFirstName() {
        XCTAssertEqual(CalendarNaming.candidate(from: "Лена Иванова"), "Лена")
        XCTAssertEqual(CalendarNaming.candidate(from: "  \"Пётр Сергеев\" <p@example.com>  "), "Пётр")
        XCTAssertEqual(CalendarNaming.candidate(from: "Иванова, Лена"), "Иванова")
    }
    /// An invitation often carries an address and nothing else.
    func testAnAddressBecomesANameOnlyWhenItReadsLikeOne() {
        XCTAssertEqual(CalendarNaming.candidate(from: "lena.ivanova@example.com"), "Lena")
        XCTAssertEqual(CalendarNaming.candidate(from: "mailto:petr@example.com"), "Petr")
        XCTAssertNil(CalendarNaming.candidate(from: "info@example.com"), "почтовый ящик — не человек")
        XCTAssertNil(CalendarNaming.candidate(from: "a1b2@example.com"))
        XCTAssertNil(CalendarNaming.candidate(from: "hr@example.com"))
    }
    /// The same person is usually on an invitation twice over: a Cyrillic display name and a
    /// Latin address. Read apart, they proposed "Лена" and "Lena" as two people.
    func testTheDisplayNameWinsOverTheAddress() {
        let found = CalendarNaming.candidates(from: [
            .init(name: "Макс Б", address: "mailto:max@example.com"),
            .init(name: "Лена Иванова", address: "mailto:lena@example.com"),
        ], excluding: "Макс")
        XCTAssertEqual(found, ["Лена"], "себя предлагать не надо, и один человек — один раз")
    }
    func testAnAddressIsReadWhenThereIsNoDisplayName() {
        let found = CalendarNaming.candidates(from: [
            .init(name: nil, address: "mailto:petr.sergeev@example.com"),
            .init(name: "", address: "mailto:info@example.com"),
        ])
        XCTAssertEqual(found, ["Petr"])
    }
    func testNothingUsableGivesNothing() {
        XCTAssertTrue(CalendarNaming.candidates(from: [.init(name: "", address: "2"),
                                                       .init(address: "info@example.com")]).isEmpty)
    }
}
