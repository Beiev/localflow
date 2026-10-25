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
    public init(kind: SessionKind) { self.kind = kind; self.title = kind.title + " " + Date().formatted(date: .abbreviated, time: .shortened) }
    public static func draftNote() -> RecordingSession {
        var note = RecordingSession(kind: .note)
        note.state = "draft"; note.title = "Заметка " + Date().formatted(date: .abbreviated, time: .omitted)
        return note
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
    /// Summary and transcript in one Markdown document, for pasting a whole meeting somewhere else.
    public var shareableDocument: String {
        var parts = ["# \(title)", durationLine]
        if let summary { parts.append(contentsOf: ["## Конспект", summary.text]) }
        parts.append(contentsOf: ["## Расшифровка", cleanTranscript?.text ?? referencedText])
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var durationLine: String {
        let stamp = createdAt.formatted(date: .long, time: .shortened)
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
