import Foundation

public enum TextSafety {
    public static func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String {
        entries.filter { !$0.heard.isEmpty && !$0.preferred.isEmpty }.sorted { $0.heard.count > $1.heard.count }.reduce(text) { result, entry in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: entry.heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return result }
            return regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: entry.preferred))
        }
    }
    /// Deterministic fallback: no paraphrasing, number conversion, or negation removal.
    public static func minimalCleanup(_ text: String, dictionary: [DictionaryEntry]) -> String {
        let source = applyDictionary(text, entries: dictionary)
        return source.replacingOccurrences(of: "(?i)(?<![\\p{L}\\p{N}])(?:э{2,}|м{3,})(?![\\p{L}\\p{N}])[, ]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func deliveryText(original: String, edited: String?, requiresReview: Bool, dictionary: [DictionaryEntry]) -> String {
        if let edited, !requiresReview, !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return edited }
        return minimalCleanup(original, dictionary: dictionary)
    }
    public static func validateEdit(original: String, edited: String) -> Bool {
        guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return original.isEmpty }
        func matches(_ pattern: String, _ text: String) -> [String] {
            let r = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return r.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased() } }
        }
        // Conservative guard; this is not a proof of semantic equivalence.
        func numbers(_ text: String) -> [String] {
            matches("[+-]?\\d+(?:[ \u{00a0}\u{202f}]\\d{3})*(?:[.,]\\d+)?", text).map {
                $0.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: ",", with: ".")
            }
        }
        guard numbers(original) == numbers(edited) else { return false }
        // Keeping the same digits is insufficient when a speaker corrects a value:
        // "15 files, more precisely 12" must not become "15 files, 12 are ready".
        let correctedNumber = "(?<!\\p{L})(?:точнее|вернее|поправка|rather|actually)\\s*[:,—-]?\\s*[+-]?\\d+(?:[ \u{00a0}\u{202f}]\\d{3})*(?:[.,]\\d+)?"
        let originalCorrections = matches(correctedNumber, original).flatMap { numbers($0) }
        let editedCorrections = matches(correctedNumber, edited).flatMap { numbers($0) }
        guard originalCorrections == editedCorrections else { return false }

        let negatives = "(?<!\\p{L})(?:не|нет|нельзя|никогда|not|never)(?!\\p{L})"
        guard matches(negatives, original).count == matches(negatives, edited).count else { return false }
        if original.count > 100 && edited.count < original.count / 2 { return false }
        return edited.count <= max(200, original.count * 2)
    }
    /// Keep the edited proposal visible; suspicious changes require review instead of a silent rollback.
    public static func reviewEdit(original: String, edited: String, mode: ProcessingMode) -> (text: String, requiresReview: Bool) {
        guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (original, !original.isEmpty) }
        let checked = mode == .clean || mode == .compose
        return (edited, checked && !validateEdit(original: original, edited: edited))
    }
    public static func chunks(_ text: String, maxCharacters: Int = 6000) -> [String] {
        var chunks: [String] = []; var current = ""
        for line in text.components(separatedBy: .newlines) {
            for word in line.split(separator: " ") {
                if current.count + word.count + 1 > maxCharacters && !current.isEmpty { chunks.append(current); current = "" }
                current += (current.isEmpty ? "" : " ") + word
            }
            current += "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }
    private static func allMatches(_ pattern: String, _ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in Range(match.range, in: text).map { String(text[$0]) } })
    }
    /// Every [мм:сс] in the text must exist in the source. Carrying no timestamp at all is fine;
    /// carrying one that was never spoken is not.
    public static func citedTimesExist(in text: String, source: String) -> Bool {
        allMatches("\\[\\d{2,}:\\d{2}\\]", text).isSubset(of: allMatches("\\[\\d{2,}:\\d{2}\\]", source))
    }
    public static func hasValidCitations(_ answer: String, evidence: String) -> Bool {
        func matches(_ pattern: String, in text: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in Range(match.range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } })
        }
        let cited = matches("\\[\\d+\\]", in: answer)
        let available = matches("^\\[\\d+\\]", in: evidence)
        let times = matches("\\[\\d{2,}:\\d{2}\\]", in: answer)
        let sourceTimes = matches("\\[\\d{2,}:\\d{2}\\]", in: evidence)
        return !cited.isEmpty && cited.isSubset(of: available) && times.isSubset(of: sourceTimes)
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norm = sqrt(a.reduce(0) { $0 + $1*$1 } * b.reduce(0) { $0 + $1*$1 })
        return norm > 0 ? dot/norm : 0
    }
    /// Two diarizer identities at least this close are the same voice. On the one real recording
    /// available (9 September 2026) the split halves of one voice sat at cos 0,84 while genuinely
    /// different voices sat at 0,04 and 0,18 — a wide margin, but one recording, not a corpus.
    public static let identityMergeThreshold: Float = 0.8
    /// An utterance the diarizer left uncovered adopts the nearest identity within this window.
    public static let speakerReachSeconds = 2.0

    /// Collapses identities that are the same voice onto one representative, so a single speaker
    /// split into several diarizer identities stops looking like several people. Returns a map
    /// from every identity to its representative, which is the smallest id in its group.
    public static func mergeIdentities(_ database: [String: [Float]], threshold: Float = identityMergeThreshold) -> [String: String] {
        let ids = database.keys.sorted()
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func root(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        for (index, first) in ids.enumerated() {
            for second in ids.dropFirst(index + 1) {
                guard let left = database[first], let right = database[second], cosine(left, right) >= threshold else { continue }
                let (a, b) = (root(first), root(second))
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, root($0)) })
    }

    /// The identity owning a stretch of speech: the one it overlaps most, or — where the diarizer
    /// left a gap — the nearest one within `reach`. Requiring an overlap left 30 % of the system
    /// track with no speaker at all on the 9 September recording.
    public static func speaker(from start: Double, to end: Double, in spans: [SpeakerSpan], reach: Double = speakerReachSeconds) -> String? {
        var bestOverlap = 0.0, overlapping: String?
        var bestDistance = Double.infinity, nearest: String?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            let overlap = min(end, span.end) - max(start, span.start)
            if overlap > bestOverlap { bestOverlap = overlap; overlapping = span.speaker }
            let distance = max(0, max(span.start - end, start - span.end))
            if distance < bestDistance { bestDistance = distance; nearest = span.speaker }
        }
        if let overlapping { return overlapping }
        return bestDistance <= reach ? nearest : nil
    }
    public static func matchVoice(_ embedding: [Float], profiles: [VoiceProfile]) -> String? {
        let ranks = profiles.map { ($0.name, cosine(embedding, $0.embedding)) }.sorted { $0.1 > $1.1 }
        guard let best = ranks.first, best.1 >= 0.8, ranks.count == 1 || best.1 - ranks[1].1 >= 0.1 else { return nil }
        return best.0
    }
}
public struct LiveHypothesis: Sendable {
    public private(set) var stable = ""
    public private(set) var draft = ""
    private var previous: [String] = []
    public init() {}
    public mutating func update(_ text: String) {
        let words = text.split(separator: " ").map(String.init)
        var count = 0
        for (a,b) in zip(previous, words) { if a != b { break }; count += 1 }
        // Never call the last two words stable until the window is finalized.
        count = min(count, max(0, words.count - 2))
        stable = words.prefix(count).joined(separator: " ")
        draft = words.dropFirst(count).joined(separator: " ")
        previous = words
    }
}
public actor AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func acquire() async { if !locked { locked = true; return }; await withCheckedContinuation { waiters.append($0) } }
    public func release() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
}

public enum TranscriptAssembly {
    /// Each word belongs to one half-open interval; context can be replayed freely.
    public static func windowWords(_ words: [TranscriptSegment], offset: Double, from: Double, to: Double, source: String) -> [TranscriptSegment] {
        words.compactMap { value in
            var word = value; word.start += offset; word.end += offset; word.source = source
            let midpoint = (word.start + word.end)/2
            return midpoint >= from && midpoint < to ? word : nil
        }
    }

    /// A turn ends when the same speaker pauses for longer than this.
    public static let turnGapSeconds: Double = 2
    /// A turn stops growing past these bounds so its single timestamp stays meaningful.
    public static let turnCharacterLimit = 900
    public static let turnDurationSeconds: Double = 60

    private struct Stream: Hashable { let source: String; let speaker: String? }

    /// Consecutive words of one speaker become one turn. The recognizer emits punctuation, so a
    /// sentence boundary is not a turn boundary: splitting on it gave one archive entry per
    /// sentence (485 of them, median six words, on a real 29-minute call). Streams are tracked
    /// separately, so words interleaved from the other track cannot break a turn apart.
    public static func group(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var turns: [TranscriptSegment] = []
        var open: [Stream: Int] = [:]
        for word in words.sorted(by: { $0.start < $1.start }) {
            let stream = Stream(source: word.source, speaker: word.speaker)
            if let index = open[stream], extends(turns[index], with: word) {
                turns[index].text += " " + word.text
                turns[index].end = max(turns[index].end, word.end)
            } else {
                turns.append(word); open[stream] = turns.count - 1
            }
        }
        // Words arrive sorted by start, so turns are appended in ascending start order too.
        return turns
    }
    private static func extends(_ turn: TranscriptSegment, with word: TranscriptSegment) -> Bool {
        word.start - turn.end < turnGapSeconds
            && turn.text.count + word.text.count + 1 <= turnCharacterLimit
            && word.end - turn.start <= turnDurationSeconds
    }
}

// Global shortcut matching lives in ShortcutSpec (Shortcut.swift).
// Device-specific command bits are supplied with the key event (IOLLEvent.h);
// never poll global keyboard state: that has separate Input Monitoring semantics.
