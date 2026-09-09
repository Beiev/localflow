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
    private func run(_ text: String, mode: ProcessingMode, stub: StubResponder) async throws -> (text: String, guarded: Bool, proposals: [String]) {
        try await EditPlan.run(text: text, mode: mode, dictionary: []) { prompt, instructions in
            try await stub.respond(prompt, instructions)
        }
    }

    func testShortSummaryIsOneCallWithoutAMergePass() async throws {
        let stub = StubResponder { _, _, _ in "Главное: одно. [00:00]" }
        let source = "[00:00] Я: короткая запись."
        let result = try await run(source, mode: .summary, stub: stub)
        let calls = await stub.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.text, "Главное: одно. [00:00]")
        let instruction = await stub.instructions[0]
        XCTAssertTrue(instruction.contains("Уложись в"), "a condensing mode must carry a length budget")
        XCTAssertFalse(instruction.contains("Это часть"), "a single chunk is not a part of anything")
    }

    func testLongSummaryMergesNotesIntoOneDocument() async throws {
        let stub = StubResponder { index, _, _ in index < 3 ? "Заметки части \(index). [00:00]" : "Сведённый конспект. [00:00]" }
        let source = transcript(turns: 80)
        XCTAssertGreaterThan(TextSafety.chunks(source).count, 1)
        let result = try await run(source, mode: .summary, stub: stub)
        let chunks = TextSafety.chunks(source).count
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
        let source = transcript(turns: 80)
        let chunks = TextSafety.chunks(source).count
        let result = try await run(source, mode: .clean, stub: stub)
        let calls = await stub.calls
        XCTAssertEqual(calls, chunks, "editing has nothing to merge")
        XCTAssertEqual(result.text, (0..<chunks).map { "часть \($0)" }.joined(separator: "\n\n"))
        let instruction = await stub.instructions[0]
        XCTAssertFalse(instruction.contains("Уложись в"))
    }

    func testMergeThatInventsATimestampIsDiscarded() async throws {
        let stub = StubResponder { index, _, _ in index < 3 ? "Заметки \(index). [00:00]" : "Выдумка про [99:59]." }
        let source = transcript(turns: 80)
        let chunks = TextSafety.chunks(source).count
        let result = try await run(source, mode: .summary, stub: stub)
        XCTAssertEqual(result.text, (0..<chunks).map { "Заметки \($0). [00:00]" }.joined(separator: "\n\n"))
        XCTAssertTrue(result.proposals.contains("Выдумка про [99:59]."), "the rejected proposal stays available")
    }

    func testFailingMergeStillReturnsTheNotes() async throws {
        struct Refused: Error {}
        let stub = StubResponder { index, _, _ in
            if index >= 3 { throw Refused() }
            return "Заметки \(index)."
        }
        let source = transcript(turns: 80)
        let chunks = TextSafety.chunks(source).count
        let result = try await run(source, mode: .summary, stub: stub)
        XCTAssertEqual(result.text, (0..<chunks).map { "Заметки \($0)." }.joined(separator: "\n\n"))
    }

    func testCancelledMergeReachesTheCaller() async throws {
        let stub = StubResponder { index, _, _ in
            if index >= 3 { throw CancellationError() }
            return "Заметки \(index)."
        }
        let source = transcript(turns: 80)
        do { _ = try await run(source, mode: .summary, stub: stub); XCTFail("cancellation must not be swallowed") }
        catch is CancellationError { }
    }

    func testTasksAndSpecificationAlsoMerge() async throws {
        for mode in [ProcessingMode.tasks, .specification] {
            let stub = StubResponder { index, _, _ in index < 3 ? "Заметки \(index)." : "Сведено." }
            let result = try await run(transcript(turns: 80), mode: mode, stub: stub)
            XCTAssertEqual(result.text, "Сведено.", "\(mode) condenses and must merge")
        }
    }

    func testOversizedNotesAreFoldedBeforeTheFinalMerge() async throws {
        // Notes far larger than one context: on the first real run two of five came back four
        // times over the asked length, so the plan must fold before merging.
        let oversized = String(repeating: "нота ", count: 1500)
        let stub = StubResponder { index, prompt, _ in
            prompt.contains("<материал>") ? oversized : "Свёрнуто \(index)."
        }
        let source = transcript(turns: 80)
        let chunks = TextSafety.chunks(source).count
        let result = try await run(source, mode: .summary, stub: stub)
        let calls = await stub.calls
        XCTAssertGreaterThan(calls, chunks + 1, "oversized notes have to be folded first")
        XCTAssertEqual(result.text, result.proposals.last, "the final merge is what the caller gets")
        XCTAssertTrue(result.text.hasPrefix("Свёрнуто "))
    }
    func testEveryCondensingInstructionCarriesTheCitationRule() async throws {
        let stub = StubResponder { _, _, _ in "Пункт. [00:10]" }
        _ = try await run(transcript(turns: 80), mode: .summary, stub: stub)
        let instructions = await stub.instructions
        for instruction in instructions { XCTAssertTrue(instruction.contains("[мм:сс]"), "both passes must ask for timestamps") }
    }
    func testCitedTimesMustExistInTheSource() {
        XCTAssertTrue(TextSafety.citedTimesExist(in: "Факт [01:20] и вывод.", source: "[01:20] Я: факт."))
        XCTAssertTrue(TextSafety.citedTimesExist(in: "Без отметок вообще.", source: "[01:20] Я: факт."))
        XCTAssertFalse(TextSafety.citedTimesExist(in: "Факт [07:41].", source: "[01:20] Я: факт."))
    }
}
