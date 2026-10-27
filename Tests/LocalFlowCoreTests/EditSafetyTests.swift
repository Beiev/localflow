import XCTest
import LocalFlowCore

final class EditSafetyTests: XCTestCase {
    func testEnglishNegationsCannotDisappear() {
        for (original, edited) in [
            ("No refunds.", "Refunds."), ("Don't send the invoice.", "Send the invoice."),
            ("We can’t ship today.", "We can ship today."), ("We won’t renew.", "We will renew."),
            ("I cannot approve.", "I can approve."), ("There isn't a backup.", "There is a backup."),
            ("Без подписки.", "С подпиской."), ("Without consent.", "With consent.")
        ] {
            XCTAssertTrue(TextSafety.editIssues(original: original, edited: edited).contains(.negation), original)
        }
    }
    func testContractionsMayExpandWithoutChangingMeaning() {
        for (original, edited) in [
            ("Don't send it.", "Do not send it."), ("We can’t ship.", "We cannot ship."),
            ("We won't renew.", "We will not renew."), ("It isn’t ready.", "It is not ready.")
        ] { XCTAssertTrue(TextSafety.validateEdit(original: original, edited: edited), original) }
    }
    func testNegationCannotMoveToAnotherRetainedAction() {
        for (original, edited) in [
            ("Don't email the client; call them.", "Email the client; don't call them."),
            ("Не отправляй письмо, сохрани черновик.", "Отправляй письмо, не сохрани черновик."),
            ("No refunds, unlimited support.", "Refunds, no support.")
        ] { XCTAssertTrue(TextSafety.editIssues(original: original, edited: edited).contains(.negationScope), original) }
    }
    func testUnambiguousNumberFormattingAndSigns() {
        for (original, edited) in [
            ("Budget 1,500,000.", "Budget 1500000."),
            ("Цена 1.500,25 евро.", "Цена 1 500,25 евро."),
            ("Price 1,500.25 dollars.", "Price 1500.25 dollars."),
            ("Цена 0,003.", "Цена 0.003."), ("−12", "-12"),
            ("Бюджет 250000.", "Бюджет 250\u{202f}000.")
        ] { XCTAssertTrue(TextSafety.validateEdit(original: original, edited: edited), original) }
    }
    func testEquivalentNegativeConstructionsDoNotLookLikeActionSwaps() {
        for (original, edited) in [
            ("Оборудование не имеет никакого брака.", "У оборудования нет никакого брака."),
            ("Сбой возник не из пустоты.", "Сбой не возник из пустоты.")
        ] { XCTAssertTrue(TextSafety.validateEdit(original: original, edited: edited), original) }
    }
    func testAmbiguousNumbersAreNeverGuessed() {
        for (original, edited) in [("1,500", "1.500"), ("1,500", "1500"), ("1,500", "1.5"), ("1.500,25", "1.5"), ("-12", "12"), ("15, 12", "12, 15"), ("12 12", "12")] {
            XCTAssertTrue(TextSafety.editIssues(original: original, edited: edited).contains(.numbers), original)
        }
        XCTAssertTrue(TextSafety.validateEdit(original: "Price 1,500", edited: "Price: 1,500."))
    }
    func testDiagnosticsAndDeliveryAreConsistent() async throws {
        let result = try await EditPlan.run(text: "Don't send 500 files.", mode: .clean, dictionary: []) { _, _ in "Send 50 files." }
        XCTAssertTrue(result.guarded)
        XCTAssertEqual(Set(result.issues), [.numbers, .negation])
        XCTAssertEqual(result.delivery(original: "Don't send 500 files.", dictionary: []), "Don't send 500 files.")
        XCTAssertEqual(result.proposals, ["Send 50 files."])
    }
    func testDictionaryAppliedBeforeValidation() async throws {
        let result = try await EditPlan.run(text: "Закажи модель 15.", mode: .clean, dictionary: [.init(heard: "модель 15", preferred: "Model 16")]) { _, _ in "Закажи Model 16." }
        XCTAssertFalse(result.guarded)
        XCTAssertTrue(result.issues.isEmpty)
    }
    func testDiagnosticsSurviveArchiveEncodingAndLegacyVersionsDecode() throws {
        var session = RecordingSession(kind: .dictation)
        session.versions = [.init(mode: .clean, text: "Synthetic example", reviewIssues: [.negation])]
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(RecordingSession.self, from: data).versions.first?.reviewIssues, [.negation])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var versions = try XCTUnwrap(object["versions"] as? [[String: Any]])
        versions[0].removeValue(forKey: "reviewIssues"); object["versions"] = versions
        let legacy = try JSONDecoder().decode(RecordingSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.dictationMetrics)
        XCTAssertNil(legacy.versions.first?.reviewIssues)
    }
}
