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
    /// Conservative, explainable checks; passing them is not proof of semantic equivalence.
    public static func editIssues(original: String, edited: String) -> [EditIssue] {
        guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.empty]
        }
        var issues: [EditIssue] = []
        if numbers(original) != numbers(edited) { issues.append(.numbers) }
        let correction = #"(?<!\p{L})(?:точнее|вернее|поправка|rather|actually)\s*[:,—-]?\s*"# + numberPattern
        if matches(correction, original).flatMap({ numbers($0) }) != matches(correction, edited).flatMap({ numbers($0) }) { issues.append(.correction) }
        let before = negations(original), after = negations(edited)
        if before.count != after.count { issues.append(.negation) }
        else {
            // A count alone accepts "don't email; call" -> "email; don't call".
            // Require both sides of a swap to survive. A changed grammatical construction
            // ("не имеют брака" -> "нет брака") is not evidence of a moved negation.
            let functionWords: Set<String> = ["", "из", "в", "на", "к", "у", "о", "по", "с", "от", "для", "in", "at", "on", "to", "of", "from", "for", "with", "a", "an", "the"]
            let targets = Set(before + after).subtracting(functionWords).filter { target in
                let token = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: target) + #"(?![\p{L}\p{N}])"#
                let a = matches(token, original).count, b = matches(token, edited).count
                return a > 0 && a == b
            }
            let changes = targets.map { target in after.filter { $0 == target }.count - before.filter { $0 == target }.count }
            if changes.contains(where: { $0 < 0 }) && changes.contains(where: { $0 > 0 }) { issues.append(.negationScope) }
        }
        if original.count > 100 && edited.count < original.count / 2 { issues.append(.truncated) }
        if edited.count > max(200, original.count * 2) { issues.append(.expanded) }
        return issues
    }
    public static func validateEdit(original: String, edited: String) -> Bool {
        editIssues(original: original, edited: edited).isEmpty
    }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
    }
    private static let numberPattern = #"[+−-]?\d+(?:[.,]\d+|[ \u00a0\u202f]\d{3}(?!\d))*"#
    /// The numeric tokens a text carries, normalized. Exposed so a summary can be checked for
    /// numbers it invented: a figure that is not in the transcript was not said.
    /// The number words a conversation actually says, in the cases it says them in.
    ///
    /// This is not a numeral reader and does not try to be one: it answers one question — did
    /// anybody in these turns say a figure out loud rather than write it. A speech recogniser
    /// renders most figures as digits, but not all of them, and a summary that writes "30 %" over
    /// a turn saying "тридцать процентов" is right, not invented.
    public static let spokenFigure: String = {
        let forms = [
            "ноль", "один", "одна", "одно", "одного", "одну", "одним", "одной",
            "два", "две", "двух", "двумя", "три", "трёх", "трех", "тремя",
            "четыре", "четырёх", "четырех", "пять", "пяти", "шесть", "шести",
            "семь", "семи", "восемь", "восьми", "девять", "девяти", "десять", "десяти",
            "двадцать", "двадцати", "тридцать", "тридцати", "сорок", "сорока",
            "пятьдесят", "пятидесяти", "шестьдесят", "шестидесяти",
            "семьдесят", "семидесяти", "восемьдесят", "восьмидесяти", "девяносто", "девяноста",
            "сто", "ста", "двести", "двухсот", "триста", "трёхсот", "трехсот",
            "четыреста", "пятьсот", "полтора", "полторы", "половина", "половины",
            #"\p{L}*надцат\p{L}*"#, #"тысяч\p{L}*"#, #"миллион\p{L}*"#, #"миллиард\p{L}*"#,
        ]
        return #"(?i)(?<!\p{L})(?:"# + forms.joined(separator: "|") + #")(?!\p{L})"#
    }()

    public static func numberTokens(_ text: String) -> [String] { numbers(text) }
    private static func numbers(_ text: String) -> [String] {
        matches(numberPattern, text).map { value in
            let compact = value.replacingOccurrences(of: #"[ \u00a0\u202f]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "−", with: "-")
            let unsigned = compact.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            let sign = compact.hasPrefix("-") ? "-" : ""
            for (group, decimal) in [(",", "."), (".", ",")] {
                let g = NSRegularExpression.escapedPattern(for: group)
                let d = NSRegularExpression.escapedPattern(for: decimal)
                // Multiple groups or a grouping separator plus an explicit decimal separator.
                if unsigned.range(of: "^[1-9]\\d{0,2}(?:" + g + "\\d{3}){2,}$", options: .regularExpression) != nil ||
                    unsigned.range(of: "^[1-9]\\d{0,2}(?:" + g + "\\d{3})+" + d + "\\d+$", options: .regularExpression) != nil {
                    return sign + unsigned.replacingOccurrences(of: group, with: "").replacingOccurrences(of: decimal, with: ".")
                }
            }
            // A single separator followed by three digits is ambiguous without a language
            // profile: 1,500 might be 1500 or 1.5. Preserve it instead of guessing the locale.
            if unsigned.range(of: #"^[1-9]\d*[.,]\d{3}$"#, options: .regularExpression) != nil { return sign + unsigned }
            if matches(#"[.,]"#, unsigned).count <= 1 { return sign + unsigned.replacingOccurrences(of: ",", with: ".") }
            return sign + unsigned
        }
    }
    private static func negations(_ text: String) -> [String] {
        var normalized = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
        normalized = normalized.replacingOccurrences(of: #"\bcannot\b"#, with: "can not", options: .regularExpression)
            .replacingOccurrences(of: #"\bwon't\b"#, with: "will not", options: .regularExpression)
            .replacingOccurrences(of: #"\bshan't\b"#, with: "shall not", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{L})n't\b"#, with: " not", options: .regularExpression)
        let marker = #"(?<!\p{L})(?:не|нет|нельзя|никогда|ни|без|not|never|no|neither|nor|without|nobody|nothing|nowhere)(?!\p{L})"#
        let regex = try! NSRegularExpression(pattern: marker)
        return regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).map { match in
            let tail = (normalized as NSString).substring(from: NSMaxRange(match.range))
            // Stop at punctuation; negation cannot acquire a target from the next clause.
            return matches(#"^\s+[\p{L}\p{N}]+"#, tail).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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
    /// Chunks that never split a line. A speaker-labelled transcript loses its meaning the
    /// moment a turn is cut in half, so the word-level chunker cannot be used on one.
    public static func lineChunks(_ text: String, maxCharacters: Int = 6000) -> [String] {
        var chunks: [String] = []; var current: [String] = []; var length = 0
        for line in text.components(separatedBy: .newlines) {
            if length + line.count + 1 > maxCharacters && !current.isEmpty {
                chunks.append(current.joined(separator: "\n")); current = []; length = 0
            }
            current.append(line); length += line.count + 1
        }
        if current.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }
    /// The `[мм:сс] Имя:` opening of every turn, which a line-by-line cleanup has to hand back
    /// untouched: these are what the interface links to the audio.
    public static func turnPrefixes(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
            let stamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard stamp.range(of: #"^\d{1,3}:[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            let speaker = rest.prefix(while: { $0 != ":" }).trimmingCharacters(in: .whitespaces)
            return stamp + "|" + speaker.lowercased()
        }
    }
    /// A cleaned transcript must have the same turns, in the same order. Dropping, merging or
    /// reordering them is the failure this catches; the stretch then stays as recognized.
    public static func keepsTurns(original: String, edited: String) -> Bool {
        let source = turnPrefixes(original)
        return !source.isEmpty && source == turnPrefixes(edited)
    }
    /// Shortest line worth de-duplicating. Below this a repeat is punctuation or a heading,
    /// not a generation loop.
    public static let repeatableLineFloor = 12
    /// Drops lines the model repeated verbatim, keeping the first. A real 35-minute meeting came
    /// back with the same line 202 times out of 389: a generation loop, delivered whole.
    public static func collapseRepetitions(_ text: String) -> (text: String, removed: Int) {
        var seen = Set<String>()
        var kept: [String] = []
        var removed = 0
        for line in text.components(separatedBy: .newlines) {
            let key = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*-•—#>")).lowercased()
            guard key.count >= repeatableLineFloor else { kept.append(line); continue }
            if seen.insert(key).inserted { kept.append(line) } else { removed += 1 }
        }
        return (kept.joined(separator: "\n"), removed)
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
    /// A diarizer identity holding less than this share of the conversation, and less than
    /// `minorIdentitySeconds` of speech, is a fragment of a neighbouring voice rather than a
    /// participant of its own. Measured over eleven real meetings in the owner's archive: on the
    /// 45-minute two-person call the remote voice came back as three identities holding 97 %, 1 %
    /// and 0 % of the remote speech, and the 1 % and 0 % pieces were that same voice — their
    /// embeddings sat at cos 0,17 and 0,01 from the dominant one, so no similarity threshold
    /// would have merged them. Both floors have to be met: 3 % of a 92-minute nine-person call
    /// was a genuinely quiet participant with two minutes of speech, and dropping them would be
    /// worse than the problem being fixed.
    public static let minorIdentityShare = 0.05
    public static let minorIdentitySeconds = 60.0

    public static func speechTime(_ spans: [SpeakerSpan]) -> [String: Double] {
        spans.reduce(into: [:]) { total, span in
            total[span.speaker, default: 0] += max(0, span.end - span.start)
        }
    }
    /// Identities too small to be a participant. Never all of them: something has to remain.
    public static func minorIdentities(_ spans: [SpeakerSpan]) -> Set<String> {
        let time = speechTime(spans)
        let total = time.values.reduce(0, +)
        guard total > 0, time.count > 1 else { return [] }
        let minor = time.filter { $0.value / total < minorIdentityShare && $0.value < minorIdentitySeconds }
        return minor.count == time.count ? [] : Set(minor.keys)
    }
    /// Gives a fragment's speech to the surviving voice nearest in time. The alternative — leaving
    /// it as "Участник 2" — is what made a summary attribute one person's tasks to three people.
    /// A limit worth knowing: audio from a video played during the call is also a small identity,
    /// and this folds it into the nearest speaker instead of keeping it apart. Nothing is lost
    /// from the transcript either way; only the name above the words changes.
    public static func foldMinorIdentities(_ spans: [SpeakerSpan]) -> [SpeakerSpan] {
        let minor = minorIdentities(spans)
        guard !minor.isEmpty else { return spans }
        let major = spans.filter { !minor.contains($0.speaker) }
        guard let fallback = major.first else { return spans }
        return spans.map { span in
            guard minor.contains(span.speaker) else { return span }
            var folded = span
            folded.speaker = (major.min { distance($0, span) < distance($1, span) } ?? fallback).speaker
            return folded
        }
    }
    private static func distance(_ a: SpeakerSpan, _ b: SpeakerSpan) -> Double {
        max(0, max(a.start - b.end, b.start - a.end))
    }

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
