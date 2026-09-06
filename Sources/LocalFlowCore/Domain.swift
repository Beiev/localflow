import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case dictation, note, meeting
    public var title: String { switch self { case .dictation: "Диктовка"; case .note: "Заметка"; case .meeting: "Созвон" } }
}
public enum ProcessingMode: String, Codable, CaseIterable, Sendable {
    case clean, summary, specification, tasks
    public var title: String { switch self { case .clean: "Связный текст"; case .summary: "Краткое резюме"; case .specification: "ТЗ"; case .tasks: "Список задач" } }
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
    public init(mode: ProcessingMode, text: String) { self.mode = mode; self.text = text }
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
    public var expectedRemoteSpeakers: Int?
    public var speakers: [String: String] = [:]
    public var embeddings: [String: [Float]] = [:]
    public init(kind: SessionKind) { self.kind = kind; self.title = kind.title + " " + Date().formatted(date: .abbreviated, time: .shortened) }
    public var rawText: String { segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") }
    public var referencedText: String {
        segments.sorted { $0.start < $1.start }.map { "[\($0.timestamp)] \(speakers[$0.speaker ?? ""] ?? $0.speaker ?? ($0.source == "microphone" ? "Я" : "Собеседник")): \($0.text)" }.joined(separator: "\n")
    }
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
