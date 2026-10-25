import XCTest
@testable import LocalFlowCore

final class RichTextTests: XCTestCase {
    /// The shape eleven summaries in the owner's archive are already written in: a bold line for
    /// the section and an asterisk with three spaces for the bullet.
    func testBoldSectionLinesAndAsteriskBulletsBecomeStructure() {
        let blocks = RichText.blocks("""
        **О чём**
        Разбор плана на неделю.

        **Состояние и цифры**
        *   **Готовность:** на уровне 30% [04:41]
        *   Осталось: 12 пунктов [08:23]
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 3, text: "О чём"),
            .paragraph("Разбор плана на неделю."),
            .heading(level: 3, text: "Состояние и цифры"),
            .bullet(indent: 0, marker: nil, text: "**Готовность:** на уровне 30% [04:41]"),
            .bullet(indent: 0, marker: nil, text: "Осталось: 12 пунктов [08:23]"),
        ])
    }
    func testHeadingsBulletsQuotesDividersAndOrderedLists() {
        let blocks = RichText.blocks("""
        # Созвон
        ## Решения
        - Первое
          - Вложенное
        1. Нумерованное
        > Оговорка про выборку
        ---
        Обычный абзац,
        продолженный на второй строке.
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Созвон"),
            .heading(level: 2, text: "Решения"),
            .bullet(indent: 0, marker: nil, text: "Первое"),
            .bullet(indent: 1, marker: nil, text: "Вложенное"),
            .bullet(indent: 0, marker: "1.", text: "Нумерованное"),
            .quote("Оговорка про выборку"),
            .divider,
            .paragraph("Обычный абзац, продолженный на второй строке."),
        ])
    }
    func testTableKeepsHeaderAndPadsRaggedRows() {
        let blocks = RichText.blocks("""
        | Кто | Что | Срок |
        |---|:--:|---|
        | Паша | Схема | среда |
        | Лена | Текст |
        """)
        XCTAssertEqual(blocks, [.table(header: ["Кто", "Что", "Срок"],
                                       rows: [["Паша", "Схема", "среда"], ["Лена", "Текст", ""]])])
    }
    /// A pipe-separated line without the separator row is prose, not a table.
    func testPipesWithoutSeparatorRowStayProse() {
        XCTAssertEqual(RichText.blocks("| Кто | Что |"), [.paragraph("| Кто | Что |")])
    }
    func testBoldInsideASentenceIsNotAHeading() {
        XCTAssertEqual(RichText.blocks("Запас **650 МБ** на диске."),
                       [.paragraph("Запас **650 МБ** на диске.")])
    }
    func testPlainStripsMarkupAndFlattensTables() {
        let plain = RichText.plain("""
        **Решения**
        *   Поднять **первый** порог [31:06]

        | Кто | Что |
        |---|---|
        | Паша | Схема |
        """)
        XCTAssertEqual(plain, "Решения\n\n• Поднять первый порог [31:06]\nКто\tЧто\nПаша\tСхема")
    }
    func testInlineKeepsWordsAndDropsEmphasis() {
        XCTAssertEqual(RichText.inline("**Готовность:** ~на уровне~ `30%` и *запас*"), "Готовность: ~на уровне~ 30% и запас")
        XCTAssertEqual(RichText.inline("умножить 3 * 4 * 5"), "умножить 3 * 4 * 5")
    }
    func testTimeReferencesParseMinutesBeyondAnHourAndFullClock() {
        let text = "Решили [04:41], уточнили [87:36] и закрыли [1:02:03]."
        XCTAssertEqual(RichText.timeReferences(in: text).map(\.seconds), [281, 5256, 3723])
        XCTAssertEqual(RichText.timeReferences(in: text).map(\.label), ["[04:41]", "[87:36]", "[1:02:03]"])
    }
    func testMalformedReferencesAreNotTimes() {
        XCTAssertTrue(RichText.timeReferences(in: "задача без отметки [134] и [12:99]").isEmpty)
    }
    func testResolvableReferencesCountOnlyMomentsTheRecordingHas() {
        let text = "первое [00:30], второе [45:00]"
        XCTAssertEqual(RichText.resolvableReferences(in: text, duration: 600).resolvable, 1)
        XCTAssertEqual(RichText.resolvableReferences(in: text, duration: 600).total, 2)
        XCTAssertEqual(RichText.resolvableReferences(in: text, duration: 0).resolvable, 0)
    }
}
