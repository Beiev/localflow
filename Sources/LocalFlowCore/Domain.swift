import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case dictation, note, meeting
    public var title: String { switch self { case .dictation: "Диктовка"; case .note: "Заметка"; case .meeting: "Созвон" } }
}
public enum ProcessingMode: String, Codable, CaseIterable, Sendable {
    case clean, compose, transcript, summary, specification, tasks
    public var title: String { switch self { case .clean: "Аккуратно"; case .compose: "Связный текст"; case .transcript: "Чистая расшифровка"; case .summary: "Краткое резюме"; case .specification: "ТЗ"; case .tasks: "Список задач" } }
    /// True when the mode exists to make the material shorter. Such a mode cannot be applied
    /// chunk by chunk and concatenated: the parts have to be merged by a second pass.
    public var condenses: Bool { switch self { case .summary, .specification, .tasks: true; case .clean, .compose, .transcript: false } }
    /// True when the mode rewrites a speaker-labelled transcript line by line and must hand back
    /// the same lines in the same order.
    public var preservesTurns: Bool { self == .transcript }
    /// Modes worth offering for a kind of recording. Cleaning a transcript turn by turn means
    /// nothing for a one-speaker dictation, whose recognition already is its transcript.
    public static func available(for kind: SessionKind) -> [ProcessingMode] {
        allCases.filter { kind == .meeting || !$0.preservesTurns }
    }
    /// Shown while the model works. Summarizing a meeting is not editing a dictation, and saying
    /// "Редактирую…" for it is what made a summary read as an unwanted edit.
    public var progressTitle: String {
        switch self {
        case .clean, .compose: "Редактирую…"
        case .transcript: "Чищу расшифровку…"
        case .summary: "Собираю конспект…"
        case .specification: "Собираю ТЗ…"
        case .tasks: "Извлекаю задачи…"
        }
    }
}
public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var source: String
    public var speaker: String?
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, source: String = "microphone", speaker: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.source = source; self.speaker = speaker
    }
    public var timestamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
}
public struct TextVersion: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var mode: ProcessingMode
    public var text: String
    public var label: String?
    public var reviewIssues: [EditIssue]?
    public init(mode: ProcessingMode, text: String, label: String? = nil, reviewIssues: [EditIssue]? = nil) { self.mode = mode; self.text = text; self.label = label; self.reviewIssues = reviewIssues }
}
public struct RecordingSession: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var title: String
    public var kind: SessionKind
    public var duration: Double = 0
    public var segments: [TranscriptSegment] = []
    public var versions: [TextVersion] = []
    public var pinned = false
    public var state = "recording"
    public var error: String?
    public var transcribedThrough: [String: Double]?
    public var pendingMode: ProcessingMode?
    public var noteDescription: String?
    public var editingMode: ProcessingMode?
    public var editingStyle: String?
    public var expectedRemoteSpeakers: Int?
    public var dictationMetrics: DictationMetrics?
    public var speakers: [String: String] = [:]
    public var embeddings: [String: [Float]] = [:]
    /// What the shared screen showed, when screen capture was on for this recording. Text and
    /// window titles only; never video.
    ///
    /// Stored optional on purpose. A synthesized `Decodable` requires every non-optional key even
    /// when the property has a default, so adding one as `[ScreenMoment] = []` made every session
    /// already in the archive fail to decode — the whole archive, not just meetings. Optional
    /// decodes as absent, which is what an old recording is.
    private var screenMoments: [ScreenMoment]?
    public var screen: [ScreenMoment] {
        get { screenMoments ?? [] }
        set { screenMoments = newValue.isEmpty ? nil : newValue }
    }
    /// Whether the title is still the one the recording was given when it started.
    ///
    /// Stored optional for the same reason `screenMoments` is: a non-optional key makes every
    /// recording already in the archive fail to decode. Absent means an old recording, and an old
    /// recording's title is left alone — it may well have been typed by hand.
    private var automaticTitle: Bool?
    public var titleIsAutomatic: Bool {
        get { automaticTitle ?? false }
        set { automaticTitle = newValue }
    }
    public init(kind: SessionKind) {
        self.kind = kind
        self.title = kind.title + " " + RussianDates.dayAndTime(Date())
        self.automaticTitle = true
    }
    public static func draftNote() -> RecordingSession {
        var note = RecordingSession(kind: .note)
        note.state = "draft"; note.title = "Заметка " + RussianDates.day(Date())
        return note
    }
    /// A name for a condensed meeting, taken from what it turned out to be about.
    ///
    /// A list of "Созвон 25 октября, 14:37" is a list of files. The topics the document already
    /// names are what a person would have called it, so they are what it is called — until the
    /// owner types something, after which this never touches it again.
    public static func title(fromTopics topics: [String], longest: Int = 60) -> String? {
        let usable = topics.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && $0.range(of: RichText.timePattern, options: .regularExpression) == nil }
        guard !usable.isEmpty else { return nil }
        var name = ""
        for topic in usable {
            let next = name.isEmpty ? topic : name + ", " + topic.prefix(1).lowercased() + topic.dropFirst()
            if next.count > longest { break }
            name = next
        }
        return name.isEmpty ? String(usable[0].prefix(longest)) : name
    }
    public var rawText: String { segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") }
    /// The microphone track's speaker key. Naming it puts the owner's own name in the transcript
    /// and the summary, where "Я" reads as nobody once the document leaves the app.
    public static let ownerIdentity = "Я"
    public var ownerName: String? { speakers[Self.ownerIdentity].flatMap { $0.isEmpty ? nil : $0 } }
    public func speakerName(_ id: String?, source: String) -> String {
        if let id, let name = speakers[id], !name.isEmpty { return name }
        if source == "microphone" { return ownerName ?? Self.ownerIdentity }
        if let id, let index = embeddings.keys.sorted().firstIndex(of: id) { return "Участник \(index + 1)" }
        return "Собеседник"
    }
    public var referencedText: String {
        segments.sorted { $0.start < $1.start }.map { "[\($0.timestamp)] \(speakerName($0.speaker, source: $0.source)): \($0.text)" }.joined(separator: "\n")
    }
    /// Re-applies minor-identity folding to the turns already in the archive. Separating voices
    /// again needs the audio, which is pruned after thirty days; this needs only the turns, so a
    /// meeting recorded months ago can still stop claiming three people were on a two-person call.
    public func foldingMinorIdentities() -> RecordingSession {
        let remote = segments.filter { $0.source == "system" && $0.speaker != nil }
        guard !remote.isEmpty else { return self }
        let spans = remote.map { SpeakerSpan(start: $0.start, end: $0.end, speaker: $0.speaker ?? "") }
        let folded = TextSafety.foldMinorIdentities(spans)
        guard Set(folded.map(\.speaker)) != Set(spans.map(\.speaker)) else { return self }
        var replacement: [String: String] = [:]
        for (before, after) in zip(spans, folded) where before.speaker != after.speaker {
            replacement[before.speaker] = after.speaker
        }
        var value = self
        for index in value.segments.indices {
            guard let speaker = value.segments[index].speaker, let target = replacement[speaker] else { continue }
            value.segments[index].speaker = target
        }
        let surviving = Set(folded.map(\.speaker))
        value.embeddings = value.embeddings.filter { surviving.contains($0.key) }
        value.speakers = value.speakers.filter { surviving.contains($0.key) || $0.key == Self.ownerIdentity }
        return value
    }
    /// Whether folding would change anything, so the action can be offered only where it helps.
    public var hasMinorIdentities: Bool {
        let remote = segments.filter { $0.source == "system" && $0.speaker != nil }
        return !TextSafety.minorIdentities(remote.map { SpeakerSpan(start: $0.start, end: $0.end, speaker: $0.speaker ?? "") }).isEmpty
    }
    /// The condensed document a reader means by "конспект": the newest version produced by a mode
    /// whose job is to shorten.
    public var summary: TextVersion? { versions.last { $0.mode.condenses } }
    /// The newest line-by-line cleaned transcript, if one was made.
    public var cleanTranscript: TextVersion? { versions.last { $0.mode.preservesTurns } }
    /// Speakers the recording can tell apart: the separated remote voices plus the owner, when the
    /// microphone track carries speech of its own.
    public var participantCount: Int {
        embeddings.count + (segments.contains { $0.source == "microphone" } ? 1 : 0)
    }
    /// What the shared screen showed, as Markdown, for the screen tab and for copying.
    public var screenDocument: String {
        screen.map { moment in
            let where_ = [moment.app, moment.window].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            return "### \(moment.timestamp) \(where_.isEmpty ? moment.title : where_)\n\n\(moment.text)"
        }.joined(separator: "\n\n")
    }
    /// The line under a record's name in the archive.
    ///
    /// The first words of the recognition were being used, which on a meeting is whatever somebody
    /// happened to say first — "Прекрасно, прекрасно. Кот налил на кресло." A condensed recording
    /// knows what it was about, so it says that instead.
    public var preview: String {
        if let summary {
            for block in RichText.blocks(summary.text) {
                guard case .paragraph(let text) = block else { continue }
                let value = RichText.inline(text)
                    .replacingOccurrences(of: RichText.timePattern, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 20 { return value }
            }
        }
        let spoken = rawText.trimmingCharacters(in: .whitespaces)
        return spoken.isEmpty ? kind.title : spoken
    }

    /// The topic headings of the condensed document, in order.
    public var summaryTopicNames: [String] {
        guard let summary else { return [] }
        var names: [String] = []
        var inTopics = false
        for block in RichText.blocks(summary.text) {
            guard case .heading(let level, let text) = block else { continue }
            if level <= 2 {
                inTopics = text.lowercased().contains("по темам") || text.lowercased().contains("разбор по")
                continue
            }
            if inTopics { names.append(RichText.inline(text)) }
        }
        return names
    }

    /// The meeting as a message to the people who were in it: what each topic came to, who is
    /// doing what, and what nobody answered.
    ///
    /// Assembled from the document that already exists, so there is no model call and nothing in
    /// it that is not in the summary. Citations are dropped — a reader somewhere else cannot play
    /// your recording — and so is anything read off a screen.
    public var followUpLetter: String {
        guard let summary else { return "" }
        var topics: [(name: String, body: String)] = []
        var decisions: [String] = []
        var tasks: [[String]] = []
        var questions: [String] = []
        var section: String?
        var topicName: String?
        func clean(_ text: String) -> String {
            RichText.inline(text)
                .replacingOccurrences(of: RichText.timePattern, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: " .", with: ".")
                .trimmingCharacters(in: .whitespaces)
        }
        for block in RichText.blocks(summary.text) {
            switch block {
            case .heading(let level, let text):
                // Inside the topic section a subheading names a topic, whatever words it uses.
                if section == "topics", level > 2 { topicName = clean(text); continue }
                let value = text.lowercased()
                if value.contains("по темам") { section = "topics"; topicName = nil }
                else if value.contains("задач") { section = "tasks" }
                else if value.contains("вопрос") { section = "questions" }
                else if value.contains("решени") || value.contains("договорил") { section = "decisions" }
                else { section = nil }
            case .paragraph(let text):
                guard section == "topics", let name = topicName else { continue }
                topics.append((name, clean(text)))
                topicName = nil
            case .bullet(_, _, let text):
                if section == "questions" { questions.append(clean(text)) }
                else if section == "decisions" { decisions.append(clean(text)) }
                // Tasks are a list rather than a table when not one of them has an owner or a
                // deadline, which on a call between two people whose names were never spoken is
                // every one of them. Reading only the table lost the whole section.
                else if section == "tasks" { tasks.append(["", clean(text)]) }
            case .table(_, let rows):
                if section == "tasks" { tasks += rows }
            case .quote, .divider:
                continue
            }
        }
        var parts = ["Итоги созвона «\(title)» · " + RussianDates.dayAndTime(createdAt)]
        let people = speakers.values.filter { !$0.isEmpty && $0 != Self.ownerIdentity }.sorted()
        if !people.isEmpty { parts.append("Участники: " + people.joined(separator: ", ")) }
        if !topics.isEmpty {
            parts.append("Обсудили:\n" + topics.map { "• \($0.name) — \($0.body)" }.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            parts.append("Решили:\n" + decisions.map { "• " + $0 }.joined(separator: "\n"))
        }
        if !tasks.isEmpty {
            parts.append("Задачи:\n" + tasks.compactMap { row -> String? in
                guard row.count >= 2 else { return nil }
                let owner = clean(row[0]), what = clean(row[1])
                guard !what.isEmpty else { return nil }
                let due = row.count >= 3 ? clean(row[2]) : ""
                let when = due.isEmpty || due == "—" || due == "-" ? "" : " (срок: \(due))"
                return "• \(owner.isEmpty ? "не назван" : owner) — \(what)\(when)"
            }.joined(separator: "\n"))
        }
        if !questions.isEmpty {
            parts.append("Осталось без ответа:\n" + questions.map { "• " + $0 }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Just when each screen was up and what window it was, without a word of what it said.
    public var screenTitles: String {
        screen.map { "- \($0.title) \($0.timestamp)" }.joined(separator: "\n")
    }

    /// Summary, transcript and what was shown in one Markdown document, for pasting a whole
    /// meeting somewhere else.
    public var shareableDocument: String {
        var parts = ["# \(title)", durationLine]
        if let summary { parts.append(contentsOf: ["## Конспект", summary.text]) }
        parts.append(contentsOf: ["## Расшифровка", cleanTranscript?.text ?? referencedText])
        // Deliberately not the screen text. What was read off the display goes out only when it
        // is asked for by itself: a document pasted into a chat should not carry everything that
        // happened to be on the owner's screen during the call.
        if !screen.isEmpty { parts.append(contentsOf: ["## Что показывали", screenTitles]) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var durationLine: String {
        let stamp = RussianDates.dayAndTime(createdAt)
        guard duration > 0 else { return stamp }
        return stamp + " · " + String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}
/// A stretch of audio the diarizer attributed to one identity.
public struct SpeakerSpan: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public init(start: Double, end: Double, speaker: String) { self.start = start; self.end = end; self.speaker = speaker }
}
public struct DictionaryEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var heard: String
    public var preferred: String
    public init(heard: String, preferred: String) { self.heard = heard; self.preferred = preferred }
}
public struct VoiceProfile: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var embedding: [Float]
    public init(name: String, embedding: [Float]) { self.name = name; self.embedding = embedding }
}
public struct EvidenceExcerpt: Identifiable, Sendable {
    public var id: UUID { segment.id }
    public var recordingID: UUID
    public var sourceIndex: Int
    public var segment: TranscriptSegment
    public init(recordingID: UUID, sourceIndex: Int, segment: TranscriptSegment) {
        self.recordingID = recordingID; self.sourceIndex = sourceIndex; self.segment = segment
    }
}
public struct SearchHit: Identifiable, Sendable {
    public var id: UUID { session.id }
    public var session: RecordingSession
}
public enum LocalFlowError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum AppPaths {
    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LOCALFLOW_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow", isDirectory: true)
    }
    public static var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public static func audio(_ id: UUID) -> URL { root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true) }
    public static func create() throws { for url in [root, models, root.appendingPathComponent("Recordings")] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } }
}
