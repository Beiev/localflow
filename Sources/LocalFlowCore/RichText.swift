import Foundation

/// Block structure of the lightweight Markdown the editor model produces. The archive is full of
/// summaries written with `**Заголовок**` and `*   пункт`, and until something parsed them the
/// interface showed the asterisks themselves. Inline emphasis is left inside the text: the view
/// layer hands it to `AttributedString`, which already knows Markdown runs.
public enum RichBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` carries an ordered list's own numbering so it survives a round trip.
    case bullet(indent: Int, marker: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case divider
}

public enum RichText {
    /// A standalone fully-bold line is a heading in everything but syntax, and that is exactly
    /// what the model writes for its sections.
    private static let boldOnlyLine = #"^\*\*([^*][^\n]*?)\*\*[:：]?$"#
    private static let headingMarker = #"^(#{1,6})\s+(.*)$"#
    private static let bulletMarker = #"^([-*+•·—])\s+(.*)$"#
    private static let orderedMarker = #"^(\d{1,3})[.)]\s+(.*)$"#
    private static let dividerLine = #"^(?:-{3,}|\*{3,}|_{3,})$"#

    public static func blocks(_ markdown: String) -> [RichBlock] {
        var blocks: [RichBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph = []
            if !text.isEmpty { blocks.append(.paragraph(text)) }
        }
        func flushQuote() {
            let text = quote.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            quote = []
            if !text.isEmpty { blocks.append(.quote(text)) }
        }
        func flush() { flushParagraph(); flushQuote() }

        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); index += 1; continue }
            if line.range(of: dividerLine, options: .regularExpression) != nil { flush(); blocks.append(.divider); index += 1; continue }
            if let parts = capture(headingMarker, in: line), parts.count == 2 {
                flush()
                let text = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                if !text.isEmpty { blocks.append(.heading(level: min(6, parts[0].count), text: text)) }
                index += 1; continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1; continue
            }
            if let table = table(lines, from: index) {
                flush(); blocks.append(table.block); index = table.next; continue
            }
            if let parts = capture(bulletMarker, in: line), parts.count == 2, !parts[1].isEmpty {
                flush(); blocks.append(.bullet(indent: indent(of: raw), marker: nil, text: parts[1]))
                index += 1; continue
            }
            if let parts = capture(orderedMarker, in: line), parts.count == 2, !parts[1].isEmpty {
                flush(); blocks.append(.bullet(indent: indent(of: raw), marker: parts[0] + ".", text: parts[1]))
                index += 1; continue
            }
            // Checked per line, not per paragraph: the model writes the section title and its
            // first sentence on consecutive lines with no blank line between them.
            if let bold = capture(boldOnlyLine, in: line)?.first {
                flush(); blocks.append(.heading(level: 3, text: bold))
                index += 1; continue
            }
            flushQuote()
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// Four spaces or one tab per level, as every Markdown writer assumes.
    private static func indent(of line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return min(3, spaces / 2)
    }

    private static func table(_ lines: [String], from start: Int) -> (block: RichBlock, next: Int)? {
        func cells(_ line: String) -> [String]? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            var body = trimmed.dropFirst()
            if body.hasSuffix("|") { body = body.dropLast() }
            return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let header = cells(lines[start]), header.count > 1,
              start + 1 < lines.count, let separator = cells(lines[start + 1]), separator.count == header.count,
              separator.allSatisfy({ $0.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil })
        else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, let row = cells(lines[index]) {
            // A short or long row is still data; pad it rather than dropping the line.
            var padded = Array(row.prefix(header.count))
            while padded.count < header.count { padded.append("") }
            rows.append(padded)
            index += 1
        }
        return (.table(header: header, rows: rows), index)
    }

    /// Markdown with the markup removed, for pasting where asterisks are noise.
    public static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for block in blocks(markdown) {
            switch block {
            case .heading(_, let text): lines.append(""); lines.append(inline(text)); lines.append("")
            case .paragraph(let text): lines.append(inline(text))
            case .bullet(let indent, let marker, let text):
                lines.append(String(repeating: "  ", count: indent) + (marker ?? "•") + " " + inline(text))
            case .quote(let text): lines.append(inline(text))
            case .table(let header, let rows):
                lines.append(header.map(inline).joined(separator: "\t"))
                for row in rows { lines.append(row.map(inline).joined(separator: "\t")) }
            case .divider: lines.append("")
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips inline emphasis without touching the words.
    public static func inline(_ text: String) -> String {
        var value = text
        for pattern in [#"\*\*\*(.+?)\*\*\*"#, #"\*\*(.+?)\*\*"#, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, #"__(.+?)__"#, #"`(.+?)`"#] {
            value = value.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return value.replacingOccurrences(of: #"\[(.+?)\]\((.+?)\)"#, with: "$1", options: .regularExpression)
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

/// A `[мм:сс]` reference inside a condensed document: the only way back from a claim to the audio
/// that supports it.
public struct TimeReference: Equatable, Sendable {
    public var label: String
    public var seconds: Double
    /// Offsets into the string the reference was found in, so a renderer can link exactly it.
    public var range: Range<String.Index>
    public init(label: String, seconds: Double, range: Range<String.Index>) {
        self.label = label; self.seconds = seconds; self.range = range
    }
}

public extension RichText {
    /// `[12:34]` and `[1:02:03]`. Minutes are not capped at 59: an 88-minute call writes `[87:36]`.
    static let timePattern = #"\[(\d{1,3}):([0-5]\d)(?::([0-5]\d))?\]"#

    static func timeReferences(in text: String) -> [TimeReference] {
        guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            func group(_ index: Int) -> Double? {
                guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: text) else { return nil }
                return Double(text[range])
            }
            guard let first = group(1), let second = group(2) else { return nil }
            let seconds = group(3).map { first * 3600 + second * 60 + $0 } ?? (first * 60 + second)
            return TimeReference(label: String(text[whole]), seconds: seconds, range: whole)
        }
    }

    /// How many of a document's references point at a moment the recording actually has. A summary
    /// whose citations do not resolve is not checkable, however well it reads.
    static func resolvableReferences(in text: String, duration: Double) -> (total: Int, resolvable: Int) {
        let references = timeReferences(in: text)
        guard duration > 0 else { return (references.count, 0) }
        return (references.count, references.filter { $0.seconds <= duration + 1 }.count)
    }
}
