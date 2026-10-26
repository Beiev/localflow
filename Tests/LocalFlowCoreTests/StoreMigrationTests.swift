import XCTest
import CSQLite
import LocalFlowCore

final class StoreMigrationTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("archive.sqlite") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func sql(_ text: String, at file: URL? = nil) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((file ?? url).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(db))) }
    }
    private func scalar(_ text: String, at file: URL? = nil) throws -> Int {
        var db: OpaquePointer?; var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2((file ?? url).path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, text, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
    private func legacy() throws -> RecordingSession {
        // Build a v1 fixture independently of Store's current schema implementation.
        try sql("PRAGMA user_version=1; CREATE TABLE sessions(id TEXT PRIMARY KEY, created REAL, data BLOB); CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED,title,body,tokenize='unicode61'); CREATE TABLE dictionary(id TEXT PRIMARY KEY,data BLOB); CREATE TABLE voices(id TEXT PRIMARY KEY,data BLOB);")
        var note = RecordingSession(kind: .note); note.title = "Migration fixture"; note.state = "ready"
        let json = String(decoding: try JSONEncoder().encode(note), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try sql("INSERT INTO sessions VALUES('\(note.id.uuidString)',0,'\(json)'); INSERT INTO search VALUES('\(note.id.uuidString)','Migration fixture','fixture');")
        return note
    }
    func testNewArchiveAndLegacyUpgradeUseSameVersionAndIndex() throws {
        let legacyNote = try legacy()
        let upgraded = try Store(url: url)
        XCTAssertEqual(try scalar("PRAGMA user_version"), Store.schemaVersion)
        XCTAssertEqual(try upgraded.session(legacyNote.id)?.title, legacyNote.title)
        XCTAssertEqual(try upgraded.search("fixture").first?.id, legacyNote.id)
        let freshURL = directory.appendingPathComponent("fresh.sqlite")
        let fresh = try Store(url: freshURL); try fresh.save(legacyNote)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: freshURL), Store.schemaVersion)
        for file in [url, freshURL] {
            XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='sessions_created'", at: file), 1)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: backup), 1)
        XCTAssertEqual(try Store(url: backup, readOnly: true).session(legacyNote.id)?.title, legacyNote.title)
        _ = try Store(url: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Backups").path).count, 1)
    }
    func testFutureArchiveIsUntouchedIncludingItsVersion() throws {
        try sql("PRAGMA user_version=999; CREATE TABLE future(value TEXT); INSERT INTO future VALUES('keep');")
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try Store(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 999)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
    }
    func testReadOnlyAuditDoesNotMigrateOrWrite() throws {
        let note = try legacy()
        let before = try Data(contentsOf: url)
        let store = try Store(url: url, readOnly: true)
        XCTAssertEqual(try store.session(note.id)?.title, note.title)
        XCTAssertThrowsError(try store.save(note))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
    }
    func testFailedMigrationRollsBackAndKeepsBackup() throws {
        let note = try legacy()
        // A conflicting index forces migration 2 to fail after opening its transaction.
        try sql("CREATE INDEX sessions_created ON sessions(id)")
        XCTAssertThrowsError(try Store(url: url))
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
        XCTAssertEqual(try Store(url: url, readOnly: true).session(note.id)?.title, note.title)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Backups").path).count, 1)
    }
    func testMigrationBackupIncludesCommittedWALData() throws {
        let note = try legacy()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; UPDATE sessions SET created=42;", nil, nil, nil), SQLITE_OK)
        let store = try Store(url: url)
        XCTAssertNotNil(try store.session(note.id))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try scalar("SELECT created FROM sessions", at: backup), 42)
    }
    func testPagesAreStableWithEqualDatesAndPointLookupDoesNotDecodeOtherRows() throws {
        let store = try Store(url: url)
        var ids: [UUID] = []
        for _ in 0..<7 {
            var note = RecordingSession(kind: .note); note.createdAt = Date(timeIntervalSince1970: 5)
            try store.save(note); ids.append(note.id)
        }
        let expected = ids.sorted { $0.uuidString > $1.uuidString }
        let pages = try [0, 3, 6].flatMap { try store.sessions(limit: 3, offset: $0).map(\.id) }
        XCTAssertEqual(pages, expected)
        XCTAssertTrue(try store.sessions(limit: 0).isEmpty)
        try sql("INSERT INTO sessions VALUES('broken',0,'invalid json')")
        XCTAssertEqual(try store.session(expected[0])?.id, expected[0])
        XCTAssertNil(try store.session(UUID()))
    }
    func testLateMetricsPreserveEditsAndDoNotRecreateDeletedSession() throws {
        let store = try Store(url: url)
        var session = RecordingSession(kind: .dictation)
        try store.save(session)
        session.title = "Renamed fixture"; session.pinned = true; try store.save(session)
        let timing = DictationMetrics(appVersion: "test", editorID: nil, speechWasLoaded: true, editorWasLoaded: false)
        try store.saveDictationMetrics(timing, for: session.id)
        let latest = try XCTUnwrap(store.session(session.id))
        XCTAssertEqual(latest.title, session.title); XCTAssertTrue(latest.pinned)
        XCTAssertEqual(latest.dictationMetrics?.appVersion, "test")
        XCTAssertEqual(try store.search("Renamed").first?.id, session.id)
        try store.delete(session.id)
        try store.saveDictationMetrics(timing, for: session.id)
        XCTAssertNil(try store.session(session.id)); XCTAssertTrue(try store.search("Renamed").isEmpty)
    }
}

/// A stored session is a JSON blob, and a synthesized `Decodable` requires every non-optional key
/// even when the property has a default. Adding one as a non-optional with a default made every
/// session in the archive fail to decode — the whole archive, not just the meetings that would
/// have carried the new field.
final class SessionShapeCompatibilityTests: XCTestCase {
    func testASessionSavedBeforeScreenCaptureExistedStillDecodes() throws {
        let old = """
        {"id":"1D6C9C61-2F2A-4E0E-9A3B-0C0C9D1E7A01","createdAt":780000000,"title":"Созвон",
         "kind":"meeting","duration":120,"segments":[],"versions":[],"pinned":false,
         "state":"ready","speakers":{},"embeddings":{}}
        """
        let session = try JSONDecoder().decode(RecordingSession.self, from: Data(old.utf8))
        XCTAssertEqual(session.kind, .meeting)
        XCTAssertTrue(session.screen.isEmpty)
    }
    /// And a round trip keeps what was captured.
    func testScreenMomentsSurviveARoundTrip() throws {
        var session = RecordingSession(kind: .meeting)
        session.screen = [ScreenMoment(start: 5, end: 60, app: "Notion", window: "План", text: "Пункт первый")]
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: try JSONEncoder().encode(session))
        XCTAssertEqual(decoded.screen.count, 1)
        XCTAssertEqual(decoded.screen.first?.window, "План")
        XCTAssertEqual(decoded.screen.first?.text, "Пункт первый")
    }
    /// Every other optional added over the life of the archive is still optional, so the minimal
    /// shape above has to keep decoding. This is the regression the next added field will hit.
    func testTheMinimalStoredShapeDecodesWithoutAnyLaterField() throws {
        let minimal = """
        {"id":"1D6C9C61-2F2A-4E0E-9A3B-0C0C9D1E7A02","createdAt":780000000,"title":"Диктовка",
         "kind":"dictation","duration":5,"segments":[],"versions":[],"pinned":false,
         "state":"ready","speakers":{},"embeddings":{}}
        """
        let session = try JSONDecoder().decode(RecordingSession.self, from: Data(minimal.utf8))
        XCTAssertEqual(session.title, "Диктовка")
        XCTAssertNil(session.dictationMetrics)
        XCTAssertNil(session.expectedRemoteSpeakers)
    }
}

/// The meeting as a message to the people who were in it, assembled from the document that
/// already exists.
final class FollowUpLetterTests: XCTestCase {
    private func meeting(_ summary: String) -> RecordingSession {
        var session = RecordingSession(kind: .meeting)
        session.title = "Планы на неделю"
        session.speakers = ["s1": "Макс", "s2": "Лена", "microphone": RecordingSession.ownerIdentity]
        session.versions = [TextVersion(mode: .summary, text: summary)]
        return session
    }

    func testTheLetterCarriesTopicsTasksAndQuestionsWithoutCitations() {
        let letter = meeting("""
        ## О чём

        Участники: Макс, Лена. Решения: 1. Задачи: 1. Открытые вопросы: 1.

        ## По темам

        ### Пороги и тарифы

        Поднимаем первый порог до двух тысяч [01:10]. Удержание тридцать процентов [00:10].

        ## Задачи

        | Кто | Что | Срок |
        |---|---|---|
        | Лена | Перенести домен [12:30] | пятница |
        | не назван | Собрать структуру сайта [11:07] | — |

        ## Открытые вопросы

        - Чем закрывать просевшее удержание [29:21]
        """).followUpLetter
        XCTAssertTrue(letter.hasPrefix("Итоги созвона «Планы на неделю» · "), letter)
        XCTAssertTrue(letter.contains("Участники: Лена, Макс"))
        XCTAssertTrue(letter.contains("• Пороги и тарифы — Поднимаем первый порог до двух тысяч."), letter)
        XCTAssertTrue(letter.contains("• Лена — Перенести домен (срок: пятница)"), letter)
        XCTAssertTrue(letter.contains("• не назван — Собрать структуру сайта"), letter)
        XCTAssertFalse(letter.contains("(срок: —)"), "пустой срок не печатается")
        XCTAssertTrue(letter.contains("Осталось без ответа:"))
        XCTAssertNil(letter.range(of: RichText.timePattern, options: .regularExpression),
                     "отметки времени бесполезны тому, у кого нет записи")
    }
    /// A document from before the topic stage has flat sections, and the letter is built from
    /// whichever shape the summary has.
    func testALetterIsStillBuiltFromAFlatSummary() {
        let letter = meeting("""
        **О чём**

        Короткий разговор о порогах.

        **Решения**

        - Поднимаем первый порог до двух тысяч [01:10]

        **Задачи**

        - Участник 1: Перенести домен [12:30]
        """).followUpLetter
        XCTAssertTrue(letter.contains("Решили:"))
        XCTAssertTrue(letter.contains("• Поднимаем первый порог до двух тысяч"))
        XCTAssertFalse(letter.contains("[01:10]"))
    }
    func testAMeetingWithNoSummaryHasNoLetter() {
        var session = RecordingSession(kind: .meeting)
        session.title = "Без конспекта"
        XCTAssertTrue(session.followUpLetter.isEmpty)
    }
    /// Tasks are a list rather than a table when not one of them has an owner or a deadline, and
    /// reading only the table lost the whole section from the letter.
    func testTheLetterReadsATaskListAsWellAsATaskTable() {
        let letter = meeting("""
        ## Задачи

        - Найти хостинг под примеры [03:20]
        - Собрать структуру сайта [05:00]
        """).followUpLetter
        XCTAssertTrue(letter.contains("Найти хостинг под примеры"), letter)
        XCTAssertTrue(letter.contains("Собрать структуру сайта"), letter)
    }
}
