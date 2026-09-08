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

    public static func group(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var grouped: [TranscriptSegment] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if var last = grouped.last, last.source == word.source, last.speaker == word.speaker,
               word.start - last.end < 1, last.text.count + word.text.count < 220,
               ![".", "!", "?"].contains(last.text.last.map(String.init) ?? "") {
                last.text += " " + word.text; last.end = max(last.end, word.end); grouped[grouped.count-1] = last
            } else { grouped.append(word) }
        }
        return grouped
    }
}

// Global shortcut matching lives in ShortcutSpec (Shortcut.swift).
// Device-specific command bits are supplied with the key event (IOLLEvent.h);
// never poll global keyboard state: that has separate Input Monitoring semantics.
