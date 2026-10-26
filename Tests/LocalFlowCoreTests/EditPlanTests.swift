import XCTest
@testable import LocalFlowCore

/// Records what the plan asked the model and replies deterministically.
private actor StubResponder {
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

final class EditPlanTests: XCTestCase {
    /// Three chunks worth of a meeting transcript, with timestamps the plan must not invent past.
    private func transcript(turns: Int) -> String {
        (0..<turns).map { index in
            let minute = index / 4, second = (index % 4) * 15
            return String(format: "[%02d:%02d] Я: ", minute, second) + String(repeating: "слово ", count: 30) + "."
        }.joined(separator: "\n")
    }
    /// Enough turns to exceed one condensing pass, so the merge path is exercised.
    private let mergingTurns = 400
    private func condensingChunks(_ source: String) -> Int {
        TextSafety.chunks(source, maxCharacters: EditPlan.condensingChunkCharacters).count
    }
    /// These describe the single free-text pass, which is kept reachable for comparison. The
    /// structured path that replaced it as the default has its own suite.
    private func run(_ text: String, mode: ProcessingMode, stub: StubResponder) async throws -> EditResult {
        try await EditPlan.run(text: text, mode: mode, dictionary: [], strategy: .legacy) { prompt, instructions in
            try await stub.respond(prompt, instructions)
        }
    }

    func testMaterialThatFitsIsReadInOnePass() async throws {
        // Splitting material that fits measurably hurt the result, so a call this size is read
        // whole and the structure comes straight out of that single pass.
        let stub = StubResponder { _, _, _ in "**О чём** Коротко. [00:00]" }
        let source = "[00:00] Я: короткая запись."
        let result = try await run(source, mode: .summary, stub: stub)
        let calls = await stub.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.text, "**О чём** Коротко. [00:00]")
        let instruction = await stub.instructions[0]
        XCTAssertTrue(instruction.contains("«О чём»"), "one pass owns the structure itself")
        XCTAssertFalse(instruction.contains("Это часть"), "a single chunk is not a part of anything")
    }

    func testLongSummaryMergesNotesIntoOneDocument() async throws {
        let stub = StubResponder { index, prompt, _ in prompt.contains("<материал>") ? "Заметки части \(index). [00:00]" : "Сведённый конспект. [00:00]" }
        let source = transcript(turns: mergingTurns)
        XCTAssertGreaterThan(condensingChunks(source), 1)
        let result = try await run(source, mode: .summary, stub: stub)
        let chunks = condensingChunks(source)
        let calls = await stub.calls
        XCTAssertEqual(calls, chunks + 1, "one pass per chunk plus one merge")
        XCTAssertEqual(result.text, "Сведённый конспект. [00:00]")
        let prompts = await stub.prompts
        XCTAssertTrue(prompts.last!.contains("<заметки>"), "the merge pass reads notes, not the material")
        XCTAssertFalse(prompts.last!.contains("<материал>"))
        for note in 0..<chunks { XCTAssertTrue(prompts.last!.contains("Заметки части \(note)")) }
        let first = await stub.instructions[0]
        XCTAssertTrue(first.contains("Это часть 1 из \(chunks)"))
    }

    func testEditingModesKeepConcatenatingChunks() async throws {
        let stub = StubResponder { index, _, _ in "часть \(index)" }
        let source = transcript(turns: mergingTurns)
        let chunks = TextSafety.chunks(source).count
        let result = try await run(source, mode: .clean, stub: stub)
        let calls = await stub.calls
        XCTAssertEqual(calls, chunks, "editing has nothing to merge")
        XCTAssertEqual(result.text, (0..<chunks).map { "часть \($0)" }.joined(separator: "\n\n"))
        let instruction = await stub.instructions[0]
        XCTAssertFalse(instruction.contains("Уложись в"))
    }

    func testMergeThatInventsATimestampIsDiscarded() async throws {
        let stub = StubResponder { index, prompt, _ in prompt.contains("<материал>") ? "Заметки \(index). [00:00]" : "Выдумка про [99:59]." }
        let source = transcript(turns: mergingTurns)
        let chunks = condensingChunks(source)
        let result = try await run(source, mode: .summary, stub: stub)
        XCTAssertEqual(result.text, (0..<chunks).map { "Заметки \($0). [00:00]" }.joined(separator: "\n\n"))
        XCTAssertTrue(result.proposals.contains("Выдумка про [99:59]."), "the rejected proposal stays available")
    }

    func testFailingMergeStillReturnsTheNotes() async throws {
        struct Refused: Error {}
        let stub = StubResponder { index, prompt, _ in
            if prompt.contains("<заметки>") { throw Refused() }
            return "Заметки \(index)."
        }
        let source = transcript(turns: mergingTurns)
        let chunks = condensingChunks(source)
        let result = try await run(source, mode: .summary, stub: stub)
        XCTAssertEqual(result.text, (0..<chunks).map { "Заметки \($0)." }.joined(separator: "\n\n"))
    }

    func testCancelledMergeReachesTheCaller() async throws {
        let stub = StubResponder { index, prompt, _ in
            if prompt.contains("<заметки>") { throw CancellationError() }
            return "Заметки \(index)."
        }
        let source = transcript(turns: mergingTurns)
        do { _ = try await run(source, mode: .summary, stub: stub); XCTFail("cancellation must not be swallowed") }
        catch is CancellationError { }
    }

    func testTasksAndSpecificationAlsoMerge() async throws {
        for mode in [ProcessingMode.tasks, .specification] {
            let stub = StubResponder { index, prompt, _ in prompt.contains("<материал>") ? "Заметки \(index)." : "Сведено." }
            let result = try await run(transcript(turns: mergingTurns), mode: mode, stub: stub)
            XCTAssertEqual(result.text, "Сведено.", "\(mode) condenses and must merge")
        }
    }

    func testOversizedNotesAreFoldedBeforeTheFinalMerge() async throws {
        // Notes far larger than one context: on the first real run two of five came back four
        // times over the asked length, so the plan must fold before merging.
        // Distinct per chunk: identical notes would be collapsed as duplicates, which is correct
        // behaviour but would leave nothing to fold.
        let stub = StubResponder { index, prompt, _ in
            prompt.contains("<материал>") ? String(repeating: "нота\(index) ", count: 6000) : "Свёрнуто \(index)."
        }
        let source = transcript(turns: mergingTurns)
        let chunks = condensingChunks(source)
        let result = try await run(source, mode: .summary, stub: stub)
        let calls = await stub.calls
        XCTAssertGreaterThan(calls, chunks + 1, "oversized notes have to be folded first")
        XCTAssertEqual(result.text, result.proposals.last, "the final merge is what the caller gets")
        XCTAssertTrue(result.text.hasPrefix("Свёрнуто "))
    }
    func testEveryCondensingInstructionCarriesTheCitationRule() async throws {
        let stub = StubResponder { _, _, _ in "Пункт. [00:10]" }
        _ = try await run(transcript(turns: mergingTurns), mode: .summary, stub: stub)
        let instructions = await stub.instructions
        for instruction in instructions { XCTAssertTrue(instruction.contains("[мм:сс]"), "both passes must ask for timestamps") }
    }
    func testChunkNotesAreRawMaterialAndTheMergeOwnsTheStructure() async throws {
        let stub = StubResponder { _, _, _ in "Факт. [00:10]" }
        _ = try await run(transcript(turns: mergingTurns), mode: .summary, stub: stub)
        let instructions = await stub.instructions
        XCTAssertTrue(instructions[0].contains("Без заголовков"), "a chunk is material for the merge, not a summary of its own")
        XCTAssertTrue(instructions.last!.contains("«О чём»"), "the merge owns the structure")
    }
    func testLoopedModelOutputNeverReachesTheResult() async throws {
        let loop = Array(repeating: "Согласовано, что нужно делать (делать).", count: 50).joined(separator: "\n")
        let stub = StubResponder { _, prompt, _ in prompt.contains("<материал>") ? loop : "Сведено. [00:00]" }
        let result = try await run(transcript(turns: mergingTurns), mode: .summary, stub: stub)
        XCTAssertEqual(result.text, "Сведено. [00:00]")
        for proposal in result.proposals {
            XCTAssertLessThan(proposal.components(separatedBy: "Согласовано").count, 3, "a loop must be collapsed before it is used")
        }
    }
    func testCitedTimesMustExistInTheSource() {
        XCTAssertTrue(TextSafety.citedTimesExist(in: "Факт [01:20] и вывод.", source: "[01:20] Я: факт."))
        XCTAssertTrue(TextSafety.citedTimesExist(in: "Без отметок вообще.", source: "[01:20] Я: факт."))
        XCTAssertFalse(TextSafety.citedTimesExist(in: "Факт [07:41].", source: "[01:20] Я: факт."))
    }
}

/// The cleaned-transcript path: the same conversation, readable, with every turn still there.
final class TranscriptCleanupTests: XCTestCase {
    private func transcript(turns: Int) -> String {
        var lines: [String] = []
        for index in 0..<turns {
            let stamp: String = String(format: "[%02d:%02d] Я: ", index / 4, (index % 4) * 15)
            let words: String = String(repeating: "слово ", count: 20)
            lines.append(stamp + "ээ ну " + words + "и 15 файлов, не 12")
        }
        return lines.joined(separator: "\n")
    }
    private func run(_ text: String, stub: StubResponder) async throws -> EditResult {
        try await EditPlan.run(text: text, mode: .transcript, dictionary: []) { prompt, instructions in
            try await stub.respond(prompt, instructions)
        }
    }
    private func body(of prompt: String) -> String {
        prompt.replacingOccurrences(of: "<расшифровка>\n", with: "").replacingOccurrences(of: "\n</расшифровка>", with: "")
    }

    /// A faithful cleanup is delivered whole, in order, and is never asked to condense.
    func testCleanupIsDeliveredAndEveryTurnSurvives() async throws {
        let source = transcript(turns: 40)
        let stub = StubResponder { _, prompt, _ in
            let lines = prompt.components(separatedBy: .newlines).filter { $0.hasPrefix("[") }
            return lines.map { $0.replacingOccurrences(of: "ээ ну ", with: "") }.joined(separator: "\n")
        }
        let result = try await run(source, stub: stub)
        XCTAssertFalse(result.guarded)
        XCTAssertEqual(TextSafety.turnPrefixes(result.text), TextSafety.turnPrefixes(source))
        XCTAssertFalse(result.text.contains("ээ ну"))
        let calls = await stub.calls
        XCTAssertGreaterThan(calls, 1, "40 turns are more than one window")
        for instruction in await stub.instructions {
            XCTAssertTrue(instruction.contains("столько же строк"))
            XCTAssertFalse(instruction.contains("Уложись в"), "a transcript is not condensed")
        }
    }
    /// A window the model summarized instead of cleaning is replaced by what was recognized, and
    /// only that window: the rest of the transcript keeps its polish.
    func testASummarizedWindowFallsBackWithoutLosingTheOthers() async throws {
        let source = transcript(turns: 40)
        let stub = StubResponder { index, prompt, _ in
            if index == 1 { return "[00:00] Я: Обсудили файлы." }
            let lines = prompt.components(separatedBy: .newlines).filter { $0.hasPrefix("[") }
            return lines.map { $0.replacingOccurrences(of: "ээ ну ", with: "") }.joined(separator: "\n")
        }
        let result = try await run(source, stub: stub)
        XCTAssertTrue(result.guarded)
        XCTAssertEqual(result.issues, [.structure])
        XCTAssertEqual(TextSafety.turnPrefixes(result.text), TextSafety.turnPrefixes(source), "no turn may go missing")
        XCTAssertTrue(result.text.contains("ээ ну"), "the rejected window is back as recognized")
        XCTAssertFalse(result.text.contains("Обсудили файлы"))
    }
    /// A window that silently changed a number is rejected by the same guards as a dictation.
    func testAChangedNumberRejectsThatWindow() async throws {
        let source = transcript(turns: 8)
        let stub = StubResponder { _, prompt, _ in
            let lines = prompt.components(separatedBy: .newlines).filter { $0.hasPrefix("[") }
            return lines.map { $0.replacingOccurrences(of: "не 12", with: "не 21") }.joined(separator: "\n")
        }
        let result = try await run(source, stub: stub)
        XCTAssertTrue(result.guarded)
        XCTAssertTrue(result.issues.contains(.numbers))
        XCTAssertEqual(result.text, source, "nothing was trustworthy, so nothing was changed")
    }
    /// The model is shown whole turns: a window that cut one in half would make the guard fire on
    /// material that was never broken.
    func testEveryWindowContainsWholeTurns() async throws {
        let source = transcript(turns: 60)
        let stub = StubResponder { _, prompt, _ in
            prompt.components(separatedBy: .newlines).filter { $0.hasPrefix("[") }.joined(separator: "\n")
        }
        _ = try await run(source, stub: stub)
        for prompt in await stub.prompts {
            for line in body(of: prompt).components(separatedBy: .newlines) where !line.isEmpty {
                XCTAssertTrue(line.hasPrefix("["), "turn cut in half: \(line.prefix(40))")
                XCTAssertTrue(line.hasSuffix("не 12"), "turn cut in half: …\(line.suffix(40))")
            }
        }
    }
    /// An empty reply is not a cleanup.
    func testAnEmptyReplyKeepsTheRecognition() async throws {
        let source = transcript(turns: 4)
        let result = try await run(source, stub: StubResponder { _, _, _ in "" })
        XCTAssertTrue(result.guarded)
        XCTAssertEqual(result.text, source)
    }
    func testCancellationReachesTheCaller() async throws {
        let stub = StubResponder { _, _, _ in throw CancellationError() }
        do { _ = try await run(transcript(turns: 4), stub: stub); XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
