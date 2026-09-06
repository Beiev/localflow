import Foundation
import CSQLite

/// One serialized connection. Every session write and its search document commit together.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL = AppPaths.root.appendingPathComponent("archive.sqlite")) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw LocalFlowError.message("Не удалось открыть архив") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, created REAL, data BLOB); CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, title, body, tokenize='unicode61'); CREATE TABLE IF NOT EXISTS dictionary(id TEXT PRIMARY KEY, data BLOB); CREATE TABLE IF NOT EXISTS voices(id TEXT PRIMARY KEY, data BLOB); PRAGMA user_version=1;")
    }
    deinit { sqlite3_close(db) }
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
            let s = try statement("INSERT OR REPLACE INTO sessions VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
            bind(session.id.uuidString, 1, s); sqlite3_bind_double(s, 2, session.createdAt.timeIntervalSince1970); bind(json, 3, s); try finish(s)
            let d = try statement("DELETE FROM search WHERE id=?"); defer { sqlite3_finalize(d) }; bind(session.id.uuidString, 1, d); try finish(d)
            let f = try statement("INSERT INTO search(id,title,body) VALUES(?,?,?)"); defer { sqlite3_finalize(f) }
            bind(session.id.uuidString, 1, f); bind(session.title, 2, f); bind(session.rawText + "\n" + session.versions.map(\.text).joined(separator: "\n"), 3, f); try finish(f)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func sessions() throws -> [RecordingSession] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT data FROM sessions ORDER BY created DESC"); defer { sqlite3_finalize(s) }
        var result: [RecordingSession] = []
        while sqlite3_step(s) == SQLITE_ROW { if let p = sqlite3_column_text(s, 0) { result.append(try decoder.decode(RecordingSession.self, from: Data(String(cString: p).utf8))) } }
        return result
    }
    public func search(_ query: String, limit: Int = 8) throws -> [SearchHit] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        guard !tokens.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT sessions.data FROM search JOIN sessions ON sessions.id=search.id WHERE search MATCH ? ORDER BY bm25(search) LIMIT ?"); defer { sqlite3_finalize(s) }
        // Each term is quoted. User punctuation can never become an FTS operator.
        bind(tokens.prefix(20).map { "\"\($0)\"*" }.joined(separator: " OR "), 1, s); sqlite3_bind_int(s, 2, Int32(limit))
        var hits: [SearchHit] = []
        while sqlite3_step(s) == SQLITE_ROW { if let p = sqlite3_column_text(s, 0) { hits.append(SearchHit(session: try decoder.decode(RecordingSession.self, from: Data(String(cString: p).utf8)))) } }
        return hits
    }
    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["sessions", "search"] { let s = try statement("DELETE FROM \(table) WHERE id=?"); defer { sqlite3_finalize(s) }; bind(id.uuidString, 1, s); try finish(s) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let audio = AppPaths.audio(id)
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
    }
    private func items<T: Decodable>(_ table: String, _: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT data FROM \(table)"); defer { sqlite3_finalize(s) }
        var items: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { if let p = sqlite3_column_text(s, 0) { items.append(try decoder.decode(T.self, from: Data(String(cString: p).utf8))) } }; return items
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
        for session in try sessions() where !session.pinned && session.createdAt < now.addingTimeInterval(-30 * 86400) && !["recording", "processing"].contains(session.state) {
            let url = AppPaths.audio(session.id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
