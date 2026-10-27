import Foundation
import CSQLite

/// One serialized connection. Every session write and its search document commit together.
public final class Store: @unchecked Sendable {
    public static let schemaVersion = 2
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL = AppPaths.root.appendingPathComponent("archive.sqlite"), readOnly: Bool = false) throws {
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw LocalFlowError.message("Не удалось открыть архив")
        }
        sqlite3_busy_timeout(db, 5000)
        do {
            // Inspect before any persistent PRAGMA: an older binary must never downgrade a DB.
            let version = try userVersion()
            guard version <= Self.schemaVersion else { throw LocalFlowError.message("Архив создан более новой версией LocalFlow (схема \(version)). Обновите приложение; архив не изменён.") }
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
                try migrate(from: version, url: url)
            }
        }
        catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func userVersion() throws -> Int {
        let s = try statement("PRAGMA user_version"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int(s, 0))
    }
    private func migrate(from version: Int, url: URL) throws {
        guard version < Self.schemaVersion else { return }
        // VACUUM INTO includes committed WAL pages. A file copy of archive.sqlite alone does not.
        let tables = try statement("SELECT count(*) FROM sqlite_master WHERE type='table'")
        defer { sqlite3_finalize(tables) }
        guard sqlite3_step(tables) == SQLITE_ROW else { throw error() }
        let hasData = sqlite3_column_int(tables, 0) > 0
        guard sqlite3_step(tables) == SQLITE_DONE else { throw error() }
        if hasData {
            let backup = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let destination = backup.appendingPathComponent("archive-v\(version)-\(UUID().uuidString).sqlite")
            let s = try statement("VACUUM INTO ?"); defer { sqlite3_finalize(s) }
            bind(destination.path, 1, s); try finish(s)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try userVersion() == version else { throw LocalFlowError.message("Версия архива изменилась в другом процессе. Откройте LocalFlow ещё раз.") }
            // Fresh archives take the very same steps as upgrades.
            if version < 1 {
                try execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, created REAL, data BLOB); CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, title, body, tokenize='unicode61'); CREATE TABLE IF NOT EXISTS dictionary(id TEXT PRIMARY KEY, data BLOB); CREATE TABLE IF NOT EXISTS voices(id TEXT PRIMARY KEY, data BLOB); PRAGMA user_version=1;")
            }
            if version < 2 { try execute("CREATE INDEX sessions_created ON sessions(created DESC, id DESC); PRAGMA user_version=2;") }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> Error { LocalFlowError.message("Архив: " + String(cString: sqlite3_errmsg(db))) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }; return s
    }
    private func bind(_ value: String, _ index: Int32, _ s: OpaquePointer) { sqlite3_bind_text(s, index, value, -1, transient) }
    private func finish(_ s: OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw error() } }
    public func save(_ session: RecordingSession) throws {
        lock.lock(); defer { lock.unlock() }
        let json = String(decoding: try encoder.encode(session), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("INSERT OR REPLACE INTO sessions(id,created,data) VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
            bind(session.id.uuidString, 1, s); sqlite3_bind_double(s, 2, session.createdAt.timeIntervalSince1970); bind(json, 3, s); try finish(s)
            let d = try statement("DELETE FROM search WHERE id=?"); defer { sqlite3_finalize(d) }; bind(session.id.uuidString, 1, d); try finish(d)
            let f = try statement("INSERT INTO search(id,title,body) VALUES(?,?,?)"); defer { sqlite3_finalize(f) }
            bind(session.id.uuidString, 1, f); bind(session.title, 2, f); bind((session.noteDescription ?? "") + "\n" + session.rawText + "\n" + session.versions.map(\.text).joined(separator: "\n"), 3, f); try finish(f)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func sessions(limit: Int? = nil, offset: Int = 0) throws -> [RecordingSession] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT data FROM sessions ORDER BY created DESC, id DESC LIMIT ? OFFSET ?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(limit.map { max(0, $0) } ?? -1)); sqlite3_bind_int64(s, 2, Int64(max(0, offset)))
        var result: [RecordingSession] = []
        while true {
            let step = sqlite3_step(s)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error() }
            if let p = sqlite3_column_text(s, 0) { result.append(try decoder.decode(RecordingSession.self, from: Data(String(cString: p).utf8))) } }
        return result
    }
    public func session(_ id: UUID) throws -> RecordingSession? {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT data FROM sessions WHERE id=?"); defer { sqlite3_finalize(s) }
        bind(id.uuidString, 1, s)
        let step = sqlite3_step(s)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let p = sqlite3_column_text(s, 0) else { throw error() }
        return try decoder.decode(RecordingSession.self, from: Data(String(cString: p).utf8))
    }
    /// Metadata-only update after insertion. Read the current row inside the write transaction
    /// so a title or pin changed while paste was pending is not replaced by an old snapshot.
    public func saveDictationMetrics(_ metrics: DictationMetrics, for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if var latest = try session(id) {
                latest.dictationMetrics = metrics
                let s = try statement("UPDATE sessions SET data=? WHERE id=?"); defer { sqlite3_finalize(s) }
                bind(String(decoding: try encoder.encode(latest), as: UTF8.self), 1, s)
                bind(id.uuidString, 2, s); try finish(s)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func search(_ query: String, limit: Int = 8) throws -> [SearchHit] {
        // Cut to a stem before the prefix match: full-text search with a trailing `*` finds
        // "решения" from "решени", but nothing finds it from "решение" — and a question is almost
        // never asked in the case the answer was spoken in.
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
            .map(ArchiveSearch.stem)
        guard !tokens.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT sessions.data FROM search JOIN sessions ON sessions.id=search.id WHERE search MATCH ? ORDER BY bm25(search) LIMIT ?"); defer { sqlite3_finalize(s) }
        // Each term is quoted. User punctuation can never become an FTS operator.
        bind(tokens.prefix(20).map { "\"\($0)\"*" }.joined(separator: " OR "), 1, s); sqlite3_bind_int(s, 2, Int32(limit))
        var hits: [SearchHit] = []
        while true {
            let step = sqlite3_step(s)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error() }
            if let p = sqlite3_column_text(s, 0) { hits.append(SearchHit(session: try decoder.decode(RecordingSession.self, from: Data(String(cString: p).utf8)))) } }
        return hits
    }
    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let audio = AppPaths.audio(id)
        // Keep the archive entry available for retry if deleting its audio fails.
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["sessions", "search"] { let s = try statement("DELETE FROM \(table) WHERE id=?"); defer { sqlite3_finalize(s) }; bind(id.uuidString, 1, s); try finish(s) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func items<T: Decodable>(_ table: String, _: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT data FROM \(table)"); defer { sqlite3_finalize(s) }
        var items: [T] = []
        while true {
            let step = sqlite3_step(s)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error() }
            if let p = sqlite3_column_text(s, 0) { items.append(try decoder.decode(T.self, from: Data(String(cString: p).utf8))) } }; return items
    }
    private func put<T: Encodable>(_ item: T, id: UUID, table: String) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("INSERT OR REPLACE INTO \(table) VALUES(?,?)"); defer { sqlite3_finalize(s) }
        bind(id.uuidString, 1, s); bind(String(decoding: try encoder.encode(item), as: UTF8.self), 2, s); try finish(s)
    }
    public func dictionary() throws -> [DictionaryEntry] { try items("dictionary", DictionaryEntry.self) }
    public func voices() throws -> [VoiceProfile] { try items("voices", VoiceProfile.self) }
    public func save(_ entry: DictionaryEntry) throws { try put(entry, id: entry.id, table: "dictionary") }
    public func save(_ voice: VoiceProfile) throws { try put(voice, id: voice.id, table: "voices") }
    public func deleteItem(_ id: UUID, voice: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("DELETE FROM \(voice ? "voices" : "dictionary") WHERE id=?"); defer { sqlite3_finalize(s) }; bind(id.uuidString, 1, s); try finish(s)
    }
    public func pruneAudio(now: Date = Date()) throws {
        for session in try sessions() where !session.pinned && session.createdAt < now.addingTimeInterval(-30 * 86400) && !["recording", "processing", "queued"].contains(session.state) {
            let url = AppPaths.audio(session.id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
