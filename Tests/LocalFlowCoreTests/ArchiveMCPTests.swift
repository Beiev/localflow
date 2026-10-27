import XCTest
@testable import LocalFlowCore

private struct FakeArchive: ArchiveReading {
    var recordings: [RecordingSession]
    func recent(limit: Int) throws -> [RecordingSession] { Array(recordings.prefix(limit)) }
    func matching(_ query: String, limit: Int) throws -> [RecordingSession] {
        let words = ArchiveSearch.words(query)
        return recordings.filter { session in
            let hay = (session.title + " " + session.referencedText + " " + (session.summary?.text ?? "")).lowercased()
            return words.contains { hay.contains($0) }
        }.prefix(limit).map { $0 }
    }
    func recording(_ id: UUID) throws -> RecordingSession? { recordings.first { $0.id == id } }
}

private func meeting(_ title: String, turns: [(Double, String, String)], summary: String? = nil) -> RecordingSession {
    var session = RecordingSession(kind: .meeting)
    session.title = title
    session.segments = turns.map { TranscriptSegment(start: $0.0, end: $0.0 + 5, text: $0.2, source: "system", speaker: $0.1) }
    session.speakers = ["s1": "Макс", "s2": "Лена"]
    session.embeddings = ["s1": [0], "s2": [0]]
    if let summary { session.versions = [TextVersion(mode: .summary, text: summary)] }
    return session
}

final class ArchiveSearchTests: XCTestCase {
    private let call = meeting("Пороги", turns: [
        (10, "s1", "Удержание держится на тридцати процентах."),
        (70, "s2", "Про погоду и про кота."),
        (130, "s1", "Удержание и пороги надо поднимать вместе."),
        (190, "s2", "Домен переносим на новый тариф."),
    ])

    func testMomentsAreRankedByWordsAndReadInConversationOrder() {
        let found = ArchiveSearch.moments(matching: "удержание пороги", in: call)
        XCTAssertEqual(found.map(\.timestamp), ["00:10", "02:10"])
        XCTAssertEqual(found.map(\.speaker), ["Макс", "Макс"])
    }
    /// A moment carrying none of the words is not evidence, and padding the result with it is how
    /// a citation ends up pointing at nothing.
    func testAMomentWithNoneOfTheWordsIsLeftOut() {
        XCTAssertTrue(ArchiveSearch.moments(matching: "лицензия", in: call).isEmpty)
        XCTAssertEqual(ArchiveSearch.moments(matching: "домен", in: call).map(\.timestamp), ["03:10"])
    }
    /// A question is almost never asked in the case the answer was spoken in.
    func testAWordMatchesItsOtherForms() {
        let inflected = meeting("Падежи", turns: [
            (10, "s1", "Решения по клиентам приняли в пятницу."),
            (70, "s2", "Про погоду."),
        ])
        XCTAssertEqual(ArchiveSearch.moments(matching: "решение клиенту", in: inflected).map(\.timestamp), ["00:10"])
    }
    func testWordsTooShortToCarryMeaningAreIgnored() {
        XCTAssertEqual(ArchiveSearch.words("и в на про домен"), ["про", "домен"])
        XCTAssertTrue(ArchiveSearch.moments(matching: "и в на", in: call).isEmpty)
    }
    func testTheLimitIsPerRecording() {
        let second = meeting("Второй", turns: [(10, "s1", "Удержание обсудили ещё раз.")])
        let found = ArchiveSearch.moments(matching: "удержание", in: [call, second], perRecording: 1)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.recording)).count, 2)
    }
}

final class ArchiveMCPTests: XCTestCase {
    private let call = meeting("Пороги", turns: [
        (10, "s1", "Удержание держится на тридцати процентах."),
        (70, "s2", "Домен переносим на новый тариф."),
    ], summary: "## О чём\n\nКоротко про пороги.")
    private var server: ArchiveMCP { ArchiveMCP(archive: FakeArchive(recordings: [call]), version: "test") }

    private func result(_ line: String) -> [String: Any] {
        guard let answer = server.respond(to: line), let data = answer.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
    private func text(_ tool: String, _ arguments: [String: Any]) -> String {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let payload = result(line)["result"] as? [String: Any] ?? [:]
        let content = payload["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }

    func testItAnswersTheHandshakeAndListsItsTools() {
        let handshake = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-01-01"}}"#)
        let payload = handshake["result"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["protocolVersion"] as? String, "2026-01-01", "версия клиента возвращается ему же")
        XCTAssertEqual((payload["serverInfo"] as? [String: Any])?["name"] as? String, ArchiveMCP.name)
        let tools = (result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String },
                       ["search_recordings", "list_recordings", "read_recording", "find_moments"])
    }
    /// A notification has no id and must not be answered: a reply to one is a protocol error on
    /// the client's side.
    func testANotificationIsNotAnswered() {
        XCTAssertNil(server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }
    func testBrokenJsonGetsAParseError() {
        let code = ((result("{не json") ["error"]) as? [String: Any])?["code"] as? Int
        XCTAssertEqual(code, -32700)
    }
    func testMomentsComeBackWithTheirTimeSpeakerAndRecording() {
        let found = text("find_moments", ["query": "удержание"])
        XCTAssertTrue(found.contains(call.id.uuidString), "момент без записи не на что сослаться")
        XCTAssertTrue(found.contains("[00:10] Макс:"), found)
        XCTAssertFalse(found.contains("[01:10]"), "реплика без этих слов не прикладывается")
    }
    func testReadingPartsOfARecording() {
        XCTAssertTrue(text("read_recording", ["id": call.id.uuidString]).contains("Коротко про пороги"))
        XCTAssertTrue(text("read_recording", ["id": call.id.uuidString, "part": "source"]).contains("[00:10] Макс:"))
        XCTAssertTrue(text("read_recording", ["id": call.id.uuidString, "part": "screen"]).contains("не читался"))
    }
    func testAnUnknownRecordingIsAToolErrorRatherThanACrash() {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": "read_recording", "arguments": ["id": UUID().uuidString]]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let payload = result(line)["result"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["isError"] as? Bool, true)
    }
    func testAnUnknownMethodIsRefusedPolitely() {
        let code = ((result(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)["error"]) as? [String: Any])?["code"] as? Int
        XCTAssertEqual(code, -32601)
    }
    /// Everything this server exposes is read-only, and that is the point: it is driven by an
    /// assistant, and an assistant reading a web page should not be able to delete a recording.
    func testThereIsNoToolThatChangesAnything() {
        let tools = ArchiveMCP.tools.compactMap { $0["name"] as? String }
        for forbidden in ["delete", "save", "remove", "update", "write", "transform"] {
            XCTAssertFalse(tools.contains { $0.contains(forbidden) }, "инструмент \(forbidden) не должен существовать")
        }
    }
    /// A page of 25 out of 264 looks like the whole archive to something that cannot scroll.
    func testAFullPageSaysThereIsMore() {
        let many = (0..<4).map { index in meeting("Созвон \(index)", turns: [(10, "s1", "Что-то сказали.")]) }
        let server = ArchiveMCP(archive: FakeArchive(recordings: many), version: "test")
        let full = (try? server.call("list_recordings", ["limit": 2])) ?? ""
        XCTAssertTrue(full.contains("в архиве их больше"), full)
        let partial = (try? server.call("list_recordings", ["limit": 25])) ?? ""
        XCTAssertFalse(partial.contains("в архиве их больше"), partial)
    }
    func testALongDocumentIsCutWithASayingSo() {
        let long = String(repeating: "слово ", count: ArchiveMCP.longestText)
        XCTAssertTrue(ArchiveMCP.cut(long).contains("обрезано"))
        XCTAssertLessThan(ArchiveMCP.cut(long).count, ArchiveMCP.longestText + 100)
    }
}

final class ArchiveStoreSearchTests: XCTestCase {
    /// The archive is searched in whatever case the question happens to be in.
    func testSearchFindsAnInflectedForm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(url: root.appendingPathComponent("test.sqlite"))
        var session = RecordingSession(kind: .meeting)
        session.title = "Клиенты"
        session.segments = [TranscriptSegment(start: 0, end: 5, text: "Решения по клиентам приняли в пятницу.")]
        try store.save(session)
        XCTAssertEqual(try store.search("решение").count, 1, "«решение» должно находить «решения»")
        XCTAssertEqual(try store.search("клиенту").count, 1)
        XCTAssertTrue(try store.search("лицензия").isEmpty)
    }
}

final class ArchiveExportTests: XCTestCase {
    private func session(_ title: String) -> RecordingSession {
        var value = RecordingSession(kind: .meeting)
        value.title = title
        value.createdAt = Date(timeIntervalSince1970: 1_761_436_800)
        return value
    }
    func testTheNameIsDatedAndSafeForAFileSystem() {
        XCTAssertTrue(ArchiveExport.filename(for: session("Созвон/подрядчик: планы")).hasSuffix("Созвон подрядчик планы.md"))
        XCTAssertTrue(ArchiveExport.filename(for: session("Созвон")).hasPrefix("2025-10-26 "), "дата впереди, чтобы папка сортировалась сама")
    }
    func testANameThatIsNotANameFallsBackToTheKind() {
        XCTAssertTrue(ArchiveExport.filename(for: session("   ...   ")).hasSuffix("Созвон.md"))
        XCTAssertTrue(ArchiveExport.filename(for: session("")).hasSuffix("Созвон.md"))
    }
    func testALongTitleIsCutRatherThanRefused() {
        let name = ArchiveExport.filename(for: session(String(repeating: "слово ", count: 40)))
        XCTAssertLessThanOrEqual(name.count, ArchiveExport.longestName + 20)
        XCTAssertTrue(name.hasSuffix(".md"))
    }
    /// Re-exporting the same recording has to replace its own file, not leave a second copy.
    func testTheNameIsTheSameEveryTime() {
        let value = session("Созвон с подрядчиком")
        XCTAssertEqual(ArchiveExport.filename(for: value), ArchiveExport.filename(for: value))
    }
}
