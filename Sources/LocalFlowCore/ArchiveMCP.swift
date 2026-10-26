import Foundation

/// What the MCP server is allowed to do with the archive: read it.
///
/// Narrow on purpose. The server is driven by whatever assistant the owner has pointed at it, and
/// an assistant acting on a page it just read should not be able to delete a recording.
public protocol ArchiveReading: Sendable {
    func recent(limit: Int) throws -> [RecordingSession]
    func matching(_ query: String, limit: Int) throws -> [RecordingSession]
    func recording(_ id: UUID) throws -> RecordingSession?
}

/// The archive behind a read-only store.
public struct StoreArchive: ArchiveReading {
    private let store: Store
    public init(store: Store) { self.store = store }
    public func recent(limit: Int) throws -> [RecordingSession] { try store.sessions(limit: limit) }
    public func matching(_ query: String, limit: Int) throws -> [RecordingSession] {
        try store.search(query, limit: limit).map(\.session)
    }
    public func recording(_ id: UUID) throws -> RecordingSession? { try store.session(id) }
}

/// The owner's own recordings, answerable by the owner's own assistant, without any of it leaving
/// the machine.
///
/// Every meeting product keeps your transcripts inside its own chat. This hands the same material
/// to whatever model you are already talking to, over stdio, with the moment each claim came from
/// attached — so the assistant can cite `[12:30]` and you can open that second in the recording.
///
/// Request handling is kept here, away from the executable, because the part worth testing is what
/// comes back for a given request, not how bytes reach a pipe.
public struct ArchiveMCP: Sendable {
    public static let name = "localflow-archive"
    public static let protocolVersion = "2025-06-18"
    /// Enough of a document to work with, short of pushing everything else out of a context.
    public static let longestText = 24000
    public static let mostRecordings = 25

    private let archive: any ArchiveReading
    private let version: String
    public init(archive: any ArchiveReading, version: String) {
        self.archive = archive
        self.version = version
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "search_recordings",
            "description": "Найти записи в личном архиве LocalFlow по словам из разговора. Полнотекстовый поиск по расшифровкам и конспектам. Возвращает список записей с идентификаторами — содержимое читается отдельно.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Слова, которые искать в записях"],
                    "limit": ["type": "integer", "description": "Сколько записей вернуть: по умолчанию 8, больше 25 не вернётся"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "list_recordings",
            "description": "Перечислить последние записи архива: созвоны, заметки и диктовки, новые сверху.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Сколько записей вернуть: по умолчанию 20, больше 25 не вернётся"],
                    "kind": ["type": "string", "description": "meeting, note или dictation; без него — все"],
                ],
            ],
        ],
        [
            "name": "read_recording",
            "description": "Прочитать одну запись: конспект, чистую расшифровку, исходное распознавание, что показывали на экране или письмо после созвона.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Идентификатор записи из поиска или списка"],
                    "part": ["type": "string", "description": "summary, transcript, source, screen, letter или all; по умолчанию summary"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "find_moments",
            "description": "Найти в архиве конкретные моменты разговора по словам. Каждый момент приходит с отметкой [мм:сс], именем говорящего и записью, из которой он взят, — так на него можно сослаться.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Слова, которые искать в репликах"],
                    "recording_id": ["type": "string", "description": "Искать только в этой записи"],
                    "limit": ["type": "integer", "description": "Сколько моментов из одной записи: по умолчанию 8, больше 25 не вернётся"],
                ],
                "required": ["query"],
            ],
        ],
    ]

    // MARK: - One request in, one response out

    /// `nil` means the message needs no reply: a JSON-RPC notification.
    public func respond(to line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return reply(id: NSNull(), error: -32700, message: "Разбор JSON не удался") }
        let id = message["id"] ?? NSNull()
        guard let method = message["method"] as? String else {
            // A response to something we never sent; nothing to answer.
            return nil
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return reply(id: id, result: [
                "protocolVersion": asked ?? Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.name, "version": version],
                "instructions": "Личный архив созвонов, заметок и диктовок на этой машине. Только чтение. Ссылайся на моменты отметками [мм:сс] вместе с названием записи.",
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(id: id, result: ["content": [["type": "text", "text": try call(name, arguments)]]])
            } catch {
                // Reported as a tool failure rather than a protocol error, so the assistant can
                // read what went wrong and try something else.
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": true])
            }
        default:
            return reply(id: id, error: -32601, message: "Неизвестный метод: \(method)")
        }
    }

    func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        switch name {
        case "search_recordings":
            let query = try text(arguments["query"], called: "query")
            let found = try archive.matching(query, limit: limit(arguments["limit"], default: 8))
            guard !found.isEmpty else { return "По запросу «\(query)» в архиве ничего не нашлось." }
            return found.map(Self.line(for:)).joined(separator: "\n")
        case "list_recordings":
            let kind = (arguments["kind"] as? String).flatMap { value in
                SessionKind.allCases.first { $0.rawValue == value }
            }
            let wanted = limit(arguments["limit"], default: 20)
            // Filtering happens after reading, so a kind that is rare still fills the page.
            let found = try archive.recent(limit: kind == nil ? wanted : max(wanted * 4, 80))
                .filter { kind == nil || $0.kind == kind }
                .prefix(wanted)
            guard !found.isEmpty else { return "Архив пуст." }
            // Said out loud, because a page of 25 out of 264 looks like the whole archive to
            // something that cannot see the scroll bar.
            let more = found.count >= wanted ? "\n\n[показаны последние \(found.count); в архиве их больше — сужайте поиском]" : ""
            return found.map(Self.line(for:)).joined(separator: "\n") + more
        case "read_recording":
            let recording = try found(arguments)
            let part = (arguments["part"] as? String ?? "summary").lowercased()
            return Self.cut(Self.part(part, of: recording))
        case "find_moments":
            let query = try text(arguments["query"], called: "query")
            let each = limit(arguments["limit"], default: ArchiveSearch.momentsPerRecording)
            let recordings: [RecordingSession]
            if arguments["recording_id"] != nil {
                recordings = [try found(arguments, key: "recording_id")]
            } else {
                recordings = try archive.matching(query, limit: 5)
            }
            let moments = ArchiveSearch.moments(matching: query, in: recordings, perRecording: each)
            guard !moments.isEmpty else { return "Моментов со словами «\(query)» не нашлось." }
            var lines: [String] = []
            var current: UUID?
            for moment in moments {
                if moment.recording != current {
                    current = moment.recording
                    lines.append("\n\(moment.title) · \(moment.recording.uuidString)")
                }
                lines.append("[\(moment.timestamp)] \(moment.speaker): \(moment.text)")
            }
            return Self.cut(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            throw LocalFlowError.message("Неизвестный инструмент: \(name)")
        }
    }

    // MARK: - Shapes

    static func line(for session: RecordingSession) -> String {
        var parts = [session.id.uuidString, session.kind.rawValue,
                     RussianDates.dayAndTime(session.createdAt)]
        if session.duration > 0 { parts.append(RussianDates.length(session.duration)) }
        if session.kind == .meeting, session.participantCount > 1 { parts.append("\(session.participantCount) уч.") }
        parts.append(session.summary == nil ? "без конспекта" : "есть конспект")
        return "\(session.title) — " + parts.joined(separator: " · ")
    }

    static func part(_ part: String, of session: RecordingSession) -> String {
        switch part {
        case "transcript": return session.cleanTranscript?.text ?? session.referencedText
        case "source": return session.referencedText
        case "screen": return session.screenDocument.isEmpty ? "Экран в этой записи не читался." : session.screenDocument
        case "letter": return session.followUpLetter.isEmpty ? "Письмо собирается из конспекта, а конспекта у этой записи нет." : session.followUpLetter
        case "all": return session.shareableDocument
        default:
            guard let summary = session.summary else {
                return "У этой записи нет конспекта. Расшифровка доступна как part=\"transcript\"."
            }
            return summary.text
        }
    }

    /// Cut rather than truncated silently: an assistant that cannot see the end of a document
    /// should be told that is what happened.
    static func cut(_ text: String) -> String {
        guard text.count > longestText else { return text }
        return String(text.prefix(longestText)) + "\n\n[…обрезано: документ длиннее \(longestText) знаков]"
    }

    private func found(_ arguments: [String: Any], key: String = "id") throws -> RecordingSession {
        let value = try text(arguments[key], called: key)
        guard let id = UUID(uuidString: value) else { throw LocalFlowError.message("\(key) должен быть идентификатором записи") }
        guard let session = try archive.recording(id) else { throw LocalFlowError.message("Записи \(value) в архиве нет") }
        return session
    }
    private func text(_ value: Any?, called name: String) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LocalFlowError.message("Нужен параметр \(name)")
        }
        return value
    }
    private func limit(_ value: Any?, default fallback: Int) -> Int {
        let asked = (value as? Int) ?? (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? fallback
        return min(max(asked, 1), Self.mostRecordings)
    }

    // MARK: - JSON-RPC

    private func reply(id: Any, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func reply(id: Any, error code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private func encode(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
