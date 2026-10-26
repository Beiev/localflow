import XCTest
@testable import LocalFlowCore

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
