import XCTest
@testable import LocalFlowCore

private actor Stub {
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []
    private let reply: @Sendable (Int, String, String) throws -> String
    init(reply: @escaping @Sendable (Int, String, String) throws -> String) { self.reply = reply }
    func respond(_ prompt: String, _ instructions: String) throws -> String {
        prompts.append(prompt); self.instructions.append(instructions)
        return try reply(prompts.count - 1, prompt, instructions)
    }
    var calls: Int { prompts.count }
}

final class SummaryMaterialTests: XCTestCase {
    private let transcript = """
    [00:10] Паша: Готовность тридцать процентов, осталось двенадцать пунктов.
    [01:20] Лена: Договорились поднять первый порог.
    [1:02:03] Паша: Схему сделаю к среде.
    не реплика, а мусор
    """

    func testTurnsGetIdentifiersAndSecondsIncludingBeyondAnHour() {
        let material = SummaryMaterial.parse(transcript)
        XCTAssertEqual(material.turns.map(\.id), ["u1", "u2", "u3"])
        XCTAssertEqual(material.turns.map(\.seconds), [10, 80, 3723])
        XCTAssertEqual(material.turns.map(\.speaker), ["Паша", "Лена", "Паша"])
        XCTAssertEqual(material.speakers, ["Паша", "Лена"])
    }
    func testTimestampsComeFromTheEarliestCitedTurn() {
        let material = SummaryMaterial.parse(transcript)
        XCTAssertEqual(material.timestamp(for: ["u2", "u1"]), "[00:10]")
        XCTAssertEqual(material.timestamp(for: ["u3"]), "[62:03]")
        XCTAssertNil(material.timestamp(for: ["u99"]), "ссылка, которой нет, не даёт отметки")
    }
    /// The model is never shown a clock reading, so it cannot write one and cannot write `[134]`.
    func testThePromptCarriesIdentifiersAndNamesButNoTimestamps() {
        let material = SummaryMaterial.parse(transcript)
        let prompt = StructuredSummary.prompt(for: 0..<3, in: material)
        XCTAssertTrue(prompt.contains("u1 Паша:"))
        XCTAssertTrue(prompt.contains("u2 Лена:"))
        XCTAssertFalse(prompt.contains("00:10"))
        XCTAssertFalse(prompt.contains("["))
    }
    func testWindowsCoverEveryTurnAndOverlapByOne() {
        var lines: [String] = []
        for index in 0..<60 {
            lines.append(String(format: "[%02d:00] Паша: ", index) + String(repeating: "слово ", count: 30))
        }
        let material = SummaryMaterial.parse(lines.joined(separator: "\n"))
        let windows = StructuredSummary.windows(material)
        XCTAssertGreaterThan(windows.count, 2)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, material.turns.count)
        var covered: Set<Int> = []
        for window in windows { covered.formUnion(window) }
        XCTAssertEqual(covered.count, material.turns.count, "каждая реплика попала хотя бы в одно окно")
        for (first, second) in zip(windows, windows.dropFirst()) {
            XCTAssertLessThan(second.lowerBound, first.upperBound, "окна перекрываются")
        }
    }
}

final class StructuredSummaryRecordTests: XCTestCase {
    private let material = SummaryMaterial.parse("""
    [00:10] Паша: Готовность тридцать процентов.
    [01:20] Лена: Договорились поднять порог.
    """)

    private func parse(_ reply: String) -> [SummaryRecord] {
        StructuredSummary.parse(reply, window: 0..<2, material: material)
    }

    func testWellFormedLinesBecomeRecords() {
        let records = parse("""
        ФАКТ | Готовность дошла до тридцати процентов | u1
        РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2
        ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | к среде | u1
        ВОПРОС | Через что хостить примеры, пока непонятно | u2
        """)
        XCTAssertEqual(records.map(\.kind), [.fact, .decision, .task, .question])
        XCTAssertEqual(records[2].owner, "Паша")
        XCTAssertEqual(records[2].due, "к среде")
        XCTAssertEqual(records[3].evidence, ["u2"])
    }
    /// A malformed line is dropped on its own; the rest of the window survives. This is why the
    /// stage uses lines rather than one JSON document, which fails whole.
    func testGarbageLinesAreDroppedWithoutLosingTheRest() {
        let records = parse("""
        Вот что я нашёл в разговоре:
        ФАКТ | Готовность дошла до тридцати процентов | u1
        ЧТО-ТО | непонятное | u1
        РЕШЕНИЕ без черты u2
        РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2
        """)
        XCTAssertEqual(records.count, 2)
    }
    /// Evidence is the one field invention is detectable in: an identifier outside the window the
    /// model was shown did not come from the conversation.
    func testRecordsCitingATurnOutsideTheWindowAreDropped() {
        XCTAssertTrue(parse("ФАКТ | Готовность дошла до тридцати процентов | u77").isEmpty)
        XCTAssertTrue(parse("ФАКТ | Готовность дошла до тридцати процентов | без ссылки").isEmpty)
    }
    func testTooShortAssertionsAreDropped() {
        XCTAssertTrue(parse("ФАКТ | норм | u1").isEmpty)
        XCTAssertTrue(parse("ФАКТ | 5 | u1").isEmpty)
    }
    /// An intention is not a measurement, so a fact phrased as one is a task.
    func testAnIntentionLabelledAsAFactBecomesATask() {
        XCTAssertEqual(parse("ФАКТ | Нужно попробовать поднять первый порог | u1").first?.kind, .task)
        XCTAssertEqual(parse("ФАКТ | Готовность дошла до тридцати процентов | u1").first?.kind, .fact)
    }
    /// A decision keeps the model's label even when it is spoken as an obligation. Demoting these
    /// left a 45-minute call with one decision, and the wrong one: in Russian business speech the
    /// decision of a call is routinely said as "надо переносить запуск на следующую неделю".
    func testADecisionSpokenAsAnObligationStaysADecision() {
        XCTAssertEqual(parse("РЕШЕНИЕ | Надо переносить запуск на следующую неделю | u2").first?.kind, .decision)
        XCTAssertEqual(parse("РЕШЕНИЕ | Договорились поднять первый порог в цене | u2").first?.kind, .decision)
    }
    /// A line with figures and nothing to do in it is a measurement, however it was labelled.
    func testATaskWithNothingToDoInItBecomesAFact() {
        XCTAssertEqual(parse("ЗАДАЧА |  | Если первый вариант стоит 20 единиц, то второй стоит 3 | - | u1").first?.kind, .fact)
        XCTAssertEqual(parse("ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | - | u1").first?.kind, .task)
        XCTAssertTrue(StructuredSummary.hasAction("надо накидать темы и повесить на домен"))
        XCTAssertTrue(StructuredSummary.hasAction("Покопаться в сегменте"))
        XCTAssertFalse(StructuredSummary.hasAction("запас на диске 650 мегабайт"))
    }
    /// The same point as a decision and again as a task is one point, and the decision wins —
    /// unless the task carries an owner or a deadline the decision does not.
    func testATaskRepeatingADecisionIsDroppedUnlessItAddsSomething() {
        let bare = [
            SummaryRecord(kind: .decision, text: "Поднять первый порог в цене до двух с половиной", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "Первый порог поднять в цене до двух с половиной", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.foldTasksIntoDecisions(bare).map(\.kind), [.decision])
        var owned = bare
        owned[1].owner = "Паша"
        XCTAssertEqual(StructuredSummary.foldTasksIntoDecisions(owned).count, 2)
        let different = [
            SummaryRecord(kind: .decision, text: "Поднять первый порог в цене до двух с половиной", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "Найти хостинг, терпимый к содержимому примеров", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.foldTasksIntoDecisions(different).count, 2)
    }
    func testOnlyAKnownPersonIsAcceptedAsAnOwner() {
        XCTAssertEqual(parse("ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | - | u1").first?.owner, "Паша")
        XCTAssertNil(parse("ЗАДАЧА | Участник 1 | Собрать структуру сайта и выложить черновик | - | u1").first?.owner)
        XCTAssertNil(parse("ЗАДАЧА | Собеседник | Собрать структуру сайта и выложить черновик | - | u1").first?.owner)
        XCTAssertNil(parse("ЗАДАЧА | Геннадий | Собрать структуру сайта и выложить черновик | - | u1").first?.owner)
        XCTAssertNil(parse("ЗАДАЧА |  | Собрать структуру сайта и выложить черновик | - | u1").first?.owner)
    }
    func testAnEmptyDeadlineStaysEmpty() {
        XCTAssertNil(parse("ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | - | u1").first?.due)
        XCTAssertNil(parse("ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик |  | u1").first?.due)
        XCTAssertEqual(parse("ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | в пятницу | u1").first?.due, "в пятницу")
    }
    /// The same wording extracted as two different kinds is not a duplicate, and ordering the
    /// capped sections by text position must not trip over the repeat.
    func testTheSameWordingUnderTwoKindsSurvivesCapping() {
        let records = [
            SummaryRecord(kind: .decision, text: "Поднять первый порог до двух с половиной", evidence: ["u2"]),
            SummaryRecord(kind: .task, text: "Поднять первый порог до двух с половиной", evidence: ["u2"]),
        ]
        let kept = StructuredSummary.capped(records)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(kept.map(\.kind)), [.decision, .task])
    }
    /// Each section keeps at most its own limit, and what survives is put back in the order it
    /// was said rather than in the order it was ranked.
    func testSectionsAreCappedAndRestoredToTheOrderOfTheConversation() {
        let many = (1...30).map { index in
            SummaryRecord(kind: .decision, text: "Решение номер \(index) со своей формулировкой", evidence: ["u\(index)"])
        }
        let kept = StructuredSummary.capped(many)
        XCTAssertEqual(kept.count, StructuredSummary.sectionLimits[.decision])
        XCTAssertEqual(kept, kept.sorted { first, second in
            let order = many.firstIndex(of: first) ?? 0
            return order < (many.firstIndex(of: second) ?? 0)
        })
    }
    func testParaphrasesOfOneKindAreKeptOnceAndCarryTheOwnerForward() {
        let records = [
            SummaryRecord(kind: .task, text: "Собрать структуру сайта и выложить черновик", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "Выложить черновик и собрать структуру сайта", owner: "Паша", due: "среда", evidence: ["u2"]),
            SummaryRecord(kind: .question, text: "Собрать структуру сайта и выложить черновик", evidence: ["u2"]),
        ]
        let kept = StructuredSummary.deduplicate(records, material: material)
        XCTAssertEqual(kept.count, 2, "задача одна, вопрос — другой вид записи")
        XCTAssertEqual(kept.first?.owner, "Паша", "владелец из второго упоминания достаётся первому")
        XCTAssertEqual(kept.first?.due, "среда")
        XCTAssertEqual(kept.first?.evidence, ["u1"], "цитата указывает, где это сказали впервые")
    }
}

final class StructuredSummaryDocumentTests: XCTestCase {
    private let transcript = """
    [00:10] Паша: Готовность тридцать процентов, осталось двенадцать пунктов.
    [01:20] Лена: Давай поднимем первый порог, я согласна.
    [02:30] Паша: Схему сделаю к среде.
    [03:40] Лена: Через что хостить примеры, пока непонятно.
    """
    private var material: SummaryMaterial { SummaryMaterial.parse(transcript) }

    private func run(_ stub: Stub) async throws -> EditResult {
        try await StructuredSummary.run(text: transcript) { prompt, instructions in
            try await stub.respond(prompt, instructions)
        }
    }

    func testTheDocumentIsBuiltFromRecordsAndCitesRealMoments() async throws {
        let stub = Stub { _, _, _ in
            """
            ФАКТ | Готовность дошла до тридцати процентов, осталось двенадцать пунктов | u1
            РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2
            ЗАДАЧА | Паша | Собрать структуру сайта и выложить черновик | к среде | u3
            ВОПРОС | Через что хостить примеры | u4
            """
        }
        let result = try await run(stub)
        XCTAssertFalse(result.guarded)
        let score = SummaryQuality.score(result.text, source: transcript, duration: 240, speakers: material.speakers)
        XCTAssertEqual(score.sections, ["opening", "facts", "decisions", "tasks", "questions"])
        XCTAssertEqual(score.sectionPurity, 1)
        XCTAssertEqual(score.duplicatePairs, 0)
        XCTAssertEqual(score.citations, score.resolvableCitations)
        XCTAssertEqual(score.tasksWithGenericOwner, 0)
        XCTAssertTrue(score.openingIsSpecific)
        XCTAssertTrue(result.text.contains("[00:10]"))
        XCTAssertTrue(result.text.contains("| Паша |"))
        XCTAssertTrue(result.text.contains("к среде"))
    }
    /// Sections the conversation did not fill are left out rather than padded, which is what made
    /// "Открытые вопросы" repeat the tasks.
    func testSectionsWithNothingInThemAreOmitted() async throws {
        let stub = Stub { _, _, _ in "РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2" }
        let result = try await run(stub)
        XCTAssertTrue(result.text.contains("## Решения"))
        XCTAssertFalse(result.text.contains("## Задачи"))
        XCTAssertFalse(result.text.contains("## Открытые вопросы"))
        XCTAssertFalse(result.text.contains("## Состояние и цифры"))
    }
    func testATaskWithNoNamedOwnerSaysSoInsteadOfInventingOne() async throws {
        let stub = Stub { _, _, _ in "ЗАДАЧА | Участник 2 | Найти хостинг, терпимый к содержимому | - | u4" }
        let result = try await run(stub)
        XCTAssertTrue(result.text.contains("| не назван |"))
        // The word "Участники:" opens the deterministic paragraph, so look for the label itself.
        XCTAssertNil(result.text.range(of: SummaryQuality.genericOwner, options: .regularExpression))
    }
    /// The opening is assembled, never asked for. A 2B model asked to write a paragraph about an
    /// hour of conversation produced "Срок, связанный с 4 позиции, показал…" on real
    /// material — specific by every counter and unreadable — so the model is no longer asked.
    func testTheOpeningIsAssembledAndCostsNoModelCall() async throws {
        let stub = Stub { _, _, _ in "РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2" }
        let result = try await run(stub)
        let calls = await stub.calls
        XCTAssertEqual(calls, 1, "одно извлечение и ни одной попытки вступления")
        XCTAssertTrue(result.text.contains("Решили: Подняли первый порог"))
        XCTAssertTrue(result.text.contains("Решения: 1"))
        XCTAssertTrue(result.text.contains("Участники: Паша, Лена"))
        XCTAssertFalse(result.text.contains("Разговор на"), "склонение после числительного в коде не собрать")
        let score = SummaryQuality.score(result.text, source: transcript, duration: 240, speakers: material.speakers)
        XCTAssertTrue(score.openingIsSpecific)
    }
    func testAModelThatFindsNothingYieldsNoDocumentRatherThanAnEmptyShell() async throws {
        let result = try await run(Stub { _, _, _ in "В этой части ничего по делу нет." })
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.guarded)
        XCTAssertEqual(result.issues, [.empty])
    }
    func testCancellationReachesTheCaller() async throws {
        do {
            _ = try await run(Stub { _, _, _ in throw CancellationError() })
            XCTFail("expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    /// Every extraction's reply is kept, so what the model actually said can still be inspected.
    func testProposalsAreRecorded() async throws {
        let stub = Stub { _, _, _ in "РЕШЕНИЕ | Подняли первый порог до двух с половиной | u2" }
        let result = try await run(stub)
        XCTAssertEqual(result.proposals.count, 1)
    }
}

final class SummaryMaterialNamesTests: XCTestCase {
    /// A diarizer label is not a name. One summary opened with "собеседники: Макс, Пётр,
    /// Собеседник", which names a person who does not exist.
    func testNamedExcludesDiarizerLabelsAndTheOwnersOwnKey() {
        let material = SummaryMaterial.parse("""
        [00:10] Макс: первое слово в этом разговоре
        [00:20] Пётр: второе слово в этом разговоре
        [00:30] Собеседник: третье слово в этом разговоре
        [00:40] Участник 2: четвёртое слово в этом разговоре
        [00:50] Я: пятое слово в этом разговоре
        """)
        XCTAssertEqual(material.speakers, ["Макс", "Пётр", "Собеседник", "Участник 2", "Я"])
        XCTAssertEqual(material.named, ["Макс", "Пётр"])
    }
    /// The deterministic opening has to pass the same specificity check the model's attempt does.
    func testTheDeterministicOpeningIsSpecificAndNamesOnlyRealPeople() {
        let material = SummaryMaterial.parse("[00:10] Макс: слово\n[00:20] Собеседник: слово")
        let records = [
            SummaryRecord(kind: .decision, text: "Переносим запуск на следующую неделю", evidence: ["u1"]),
            SummaryRecord(kind: .fact, text: "Запас на диске дошёл до 650 мегабайт", evidence: ["u2"]),
        ]
        let opening = StructuredSummary.deterministicOpening(records, people: material.named, material: material)
        XCTAssertTrue(opening.contains("Участники: Макс"))
        XCTAssertFalse(opening.contains("Собеседник"))
        XCTAssertTrue(opening.contains("Решили: Переносим запуск"))
        XCTAssertTrue(opening.contains("Из цифр: Запас на диске"))
        XCTAssertTrue(SummaryQuality.isSpecific(opening, speakers: material.speakers))
    }
}

final class StructuredSummaryQuotaTests: XCTestCase {
    /// A window full of figures must not cost the conversation its decisions. With one pooled
    /// ceiling of five this is exactly what happened on a real 45-minute call: twelve figures,
    /// seven tasks and a single decision survived, and it was the wrong one.
    func testNumericFactsCannotCrowdOutDecisionsAndQuestions() {
        var records: [SummaryRecord] = []
        for index in 1...8 {
            records.append(SummaryRecord(kind: .fact, text: "Выручка в \(index) месяце дошла до \(index)00 долларов", evidence: ["u1"]))
        }
        records.append(SummaryRecord(kind: .decision, text: "Переносим запуск на следующую неделю", evidence: ["u2"]))
        records.append(SummaryRecord(kind: .question, text: "Через что хостить примеры, пока непонятно", evidence: ["u3"]))
        let kept = StructuredSummary.quota(records)
        XCTAssertEqual(kept.filter { $0.kind == .fact }.count, StructuredSummary.windowRecordLimit)
        XCTAssertEqual(kept.filter { $0.kind == .decision }.count, 1)
        XCTAssertEqual(kept.filter { $0.kind == .question }.count, 1)
    }
    /// Within a kind the stronger entry still wins, and the survivors keep the order of the call.
    func testWithinAKindTheStrongerEntryWinsAndOrderIsKept() {
        let records = [
            SummaryRecord(kind: .fact, text: "Что-то произошло на прошлой неделе", evidence: ["u1"]),
            SummaryRecord(kind: .fact, text: "Запас на диске дошёл до 650 мегабайт", evidence: ["u2"]),
            SummaryRecord(kind: .fact, text: "Заказов на средний тир за месяц ноль штук", evidence: ["u3"]),
        ]
        let kept = StructuredSummary.quota(records, each: 2)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.map(\.text), [records[1].text, records[2].text], "обе с цифрами, в порядке разговора")
    }
    /// The exact line from a real call that came back labelled as a task and is a measurement.
    func testTheRealMislabelledMeasurementFromTheCallIsRoutedToFacts() {
        let material = SummaryMaterial.parse("[36:11] Макс: про цены")
        let records = StructuredSummary.parse(
            "ЗАДАЧА |  | Если первый вариант стоит 20 единиц, то второй стоит 3 единицы 4 ед |  | u1",
            window: 0..<1, material: material)
        XCTAssertEqual(records.first?.kind, .fact)
    }
}

final class StructuredSummaryOrderingTests: XCTestCase {
    private let material = SummaryMaterial.parse("""
    [00:10] Паша: первое
    [01:00] Лена: второе
    [02:00] Паша: третье
    [03:00] Лена: четвёртое
    """)

    /// The real repeat from a 45-minute call that Jaccard alone let through, because Russian
    /// prefixes make "ставить" and "поставить" different stems.
    func testARepeatSeparatedOnlyByAPrefixIsCaughtByContainment() {
        let records = [
            SummaryRecord(kind: .task, text: "выглядит так, что нам надо писать инструкцию для подрядчика и выложить черновик", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "нам нужно написать инструкцию для подрядчика и выложить черновик", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.deduplicate(records, material: material).count, 1)
    }
    /// Containment must not merge a short line into any longer line that happens to contain it.
    func testContainmentDoesNotMergeShortUnrelatedLines() {
        let records = [
            SummaryRecord(kind: .task, text: "Найти домен для сайта", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "Найти хостинг, терпимый к содержимому примеров, и выложить черновик", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.deduplicate(records, material: material).count, 2)
    }
    /// Figures first, and inside each group the order of the conversation. The first comparator
    /// asked only "does one have figures and the other not", which Swift's sort may scramble.
    func testFactsAreOrderedByFiguresThenByWhenTheyWereSaid() {
        let records = [
            SummaryRecord(kind: .fact, text: "Без цифр, сказано позже всех в разговоре", evidence: ["u4"]),
            SummaryRecord(kind: .fact, text: "Запас на диске дошёл до 650 мегабайт", evidence: ["u3"]),
            SummaryRecord(kind: .fact, text: "Без цифр, но сказано раньше остальных", evidence: ["u2"]),
            SummaryRecord(kind: .fact, text: "Заказов на средний тир 0 за месяц", evidence: ["u1"]),
        ]
        let document = StructuredSummary.assemble(records, opening: "вступление", material: material)
        let facts = document.components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
        XCTAssertEqual(facts, [
            "- Заказов на средний тир 0 за месяц [00:10]",
            "- Запас на диске дошёл до 650 мегабайт [02:00]",
            "- Без цифр, но сказано раньше остальных [01:00]",
            "- Без цифр, сказано позже всех в разговоре [03:00]",
        ])
    }
    /// Another real line that came back labelled as a task and has nothing to do in it.
    func testAStatementAboutHowSomethingIsBuiltIsAFact() {
        let records = StructuredSummary.parse("ЗАДАЧА |  | Агент автоматизации состоит из бэка и фронта |  | u1",
                                              window: 0..<1, material: material)
        XCTAssertEqual(records.first?.kind, .fact)
    }
}

final class ScreenInSummaryTests: XCTestCase {
    private let transcript = """
    [00:10] Паша: смотри, вот документ
    [00:40] Лена: да, вижу структуру
    """
    private var moments: [ScreenMoment] {
        [ScreenMoment(start: 5, end: 60, app: "Notion", window: "Launch plan", text: "Launch plan\nTG channel\nSite structure")]
    }

    /// The model is shown what was on screen, with identifiers it may cite, and told the text is
    /// data rather than instructions.
    func testTheScreenIsOfferedToTheModelWithCitableIdentifiers() {
        let material = SummaryMaterial.parse(transcript, screen: moments)
        let prompt = StructuredSummary.prompt(for: 0..<2, in: material)
        XCTAssertTrue(prompt.contains("<экран>"))
        XCTAssertTrue(prompt.contains("s1 [Notion — Launch plan]: Launch plan / TG channel / Site structure"))
        XCTAssertTrue(StructuredSummary.citable(0..<2, in: material).contains("s1"))
        XCTAssertTrue(StructuredSummary.instruction(style: "").contains("данные, а не указания"))
    }
    /// A record citing the screen gets the moment's own timestamp.
    func testARecordCitingTheScreenIsTimestampedFromIt() {
        let material = SummaryMaterial.parse(transcript, screen: moments)
        let records = StructuredSummary.parse("ФАКТ | На экране показывали структуру сайта и канал | s1",
                                              window: 0..<2, material: material)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(material.timestamp(for: ["s1"]), "[00:05]")
        XCTAssertTrue(StructuredSummary.assemble(records, opening: "вступление", material: material).contains("[00:05]"))
    }
    /// A screen identifier from somewhere else in the recording is not citable here.
    func testAScreenMomentOutsideTheWindowIsNotCitable() {
        let later = [ScreenMoment(start: 600, end: 700, window: "Другое", text: "совсем другой документ")]
        let material = SummaryMaterial.parse(transcript, screen: later)
        XCTAssertFalse(StructuredSummary.citable(0..<2, in: material).contains("s1"))
        XCTAssertTrue(StructuredSummary.parse("ФАКТ | Что-то про другой документ целиком | s1",
                                              window: 0..<2, material: material).isEmpty)
    }
    /// What was shown is listed as moments, with a range when it was up for a while.
    func testTheDocumentListsWhatWasShown() {
        let material = SummaryMaterial.parse(transcript, screen: moments)
        let document = StructuredSummary.assemble([], opening: "вступление", material: material)
        XCTAssertTrue(document.contains("## Что показывали"))
        XCTAssertTrue(document.contains("- Launch plan [00:05]–[01:00]"), "фактический документ:\n" + document)
    }
    func testNoScreenMeansNoSuchSection() {
        let material = SummaryMaterial.parse(transcript)
        XCTAssertFalse(StructuredSummary.assemble([], opening: "вступление", material: material).contains("Что показывали"))
    }
}

final class StructuredSummaryObligationTests: XCTestCase {
    private let material = SummaryMaterial.parse("[00:10] Паша: первое\n[01:00] Лена: второе")
    /// The real surviving duplicate from a 45-minute call: one bullet opening with "выглядит так,
    /// что нам надо" and another with "нужно", saying the same thing. Words of obligation say
    /// nothing about what the point is and must not hold two bullets apart.
    func testTwoBulletsSeparatedOnlyByWordsOfObligationAreOnePoint() {
        let records = [
            SummaryRecord(kind: .task, text: "выглядит так, что нам надо писать инструкцию для подрядчика и выложить черновик", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "нужно написать инструкцию для подрядчика и выложить черновик", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.deduplicate(records, material: material).count, 1)
    }
    /// And two genuinely different obligations stay two.
    func testTwoDifferentObligationsStayTwo() {
        let records = [
            SummaryRecord(kind: .task, text: "нужно написать инструкцию для подрядчика", evidence: ["u1"]),
            SummaryRecord(kind: .task, text: "надо найти хостинг, терпимый к содержимому", evidence: ["u2"]),
        ]
        XCTAssertEqual(StructuredSummary.deduplicate(records, material: material).count, 2)
    }
}
