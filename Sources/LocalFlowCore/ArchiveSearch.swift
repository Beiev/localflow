import Foundation

/// Finding things in the archive: which recordings a question is about, and which moments inside
/// them say so.
///
/// This is deliberately retrieval and nothing else. The application hands what it finds to the
/// local editor to answer in prose; the MCP server hands the same thing to whatever assistant is
/// asking. Neither of them should be reimplementing the ranking, and the ranking is the part worth
/// testing — an answer with a wrong citation is worse than no answer.
public enum ArchiveSearch {
    /// Words short enough to match anything carry no signal of their own.
    public static let shortestWord = 3
    /// How many moments one recording contributes before another recording gets a turn.
    public static let momentsPerRecording = 8

    public struct Moment: Equatable, Sendable {
        public var recording: UUID
        public var title: String
        public var speaker: String
        public var segment: TranscriptSegment
        public var timestamp: String { segment.timestamp }
        public var text: String { segment.text }
    }

    /// Russian inflects, and a question is almost never asked in the case the answer was spoken
    /// in: "решение" against "решения", "клиенту" against "клиентов". Matching whole words found
    /// nothing in half the cases that matter, so a word is cut to its first few characters and
    /// matched as a prefix — the same crude stem the summary metrics use.
    public static let stemLength = 6
    public static func stem(_ word: String) -> String { String(word.prefix(stemLength)) }

    public static func words(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= shortestWord }
            .map(stem)
    }

    /// Moments inside one recording, best first by how many of the query's words they carry, then
    /// put back into the order of the conversation so a reader can follow them.
    public static func moments(matching query: String, in recording: RecordingSession,
                               limit: Int = momentsPerRecording) -> [Moment] {
        let words = words(query)
        guard !words.isEmpty, !recording.segments.isEmpty else { return [] }
        let scored = recording.segments.map { segment -> (hits: Int, segment: TranscriptSegment) in
            let text = segment.text.lowercased()
            return (words.filter { text.contains($0) }.count, segment)
        }
        // A moment carrying none of the words is not evidence of anything, so it is left out
        // rather than used as padding to reach the limit.
        return scored.filter { $0.hits > 0 }
            .sorted { ($0.hits, -$0.segment.start) > ($1.hits, -$1.segment.start) }
            .prefix(limit)
            .sorted { $0.segment.start < $1.segment.start }
            .map { Moment(recording: recording.id, title: recording.title,
                          speaker: recording.speakerName($0.segment.speaker, source: $0.segment.source),
                          segment: $0.segment) }
    }

    /// Moments across several recordings, each recording keeping its own best few.
    public static func moments(matching query: String, in recordings: [RecordingSession],
                               perRecording: Int = momentsPerRecording) -> [Moment] {
        recordings.flatMap { moments(matching: query, in: $0, limit: perRecording) }
    }
}

/// A copy of a recording as a file somebody else's tool can read.
///
/// Every meeting product exports; this one writes into a folder the owner picks, so the notes land
/// wherever they already keep notes — Obsidian, a synced folder, a git repository — without a
/// service in between.
public enum ArchiveExport {
    /// Long enough for a real title, short enough to survive every file system in use.
    public static let longestName = 80

    /// `2026-10-26 Созвон с подрядчиком.md`, with everything a file system objects to removed.
    /// Dated first so the folder sorts by itself, and deterministic so re-exporting the same
    /// recording replaces its own file instead of leaving a second copy.
    public static func filename(for session: RecordingSession, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: session.createdAt)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        var title = session.title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A name that is only punctuation, or starts with a dot, is not a name.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if title.isEmpty { title = session.kind.title }
        if title.count > longestName { title = String(title.prefix(longestName)).trimmingCharacters(in: .whitespaces) }
        return "\(date) \(title).md"
    }
}
