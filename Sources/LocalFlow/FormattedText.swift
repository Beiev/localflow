import SwiftUI
import LocalFlowCore

/// Renders the editor model's Markdown as layout instead of asterisks, and turns every `[мм:сс]`
/// into a control that plays that moment. Before this the summary was shown with `Text(String)`,
/// which displays the markup literally and leaves the citations dead.
struct FormattedText: View {
    let markdown: String
    /// Called with a position in seconds when a citation is clicked.
    var onTime: ((Double) -> Void)?

    private static let timeScheme = "localflow-time"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(RichText.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.timeScheme, let seconds = Double(url.absoluteString.dropFirst(Self.timeScheme.count + 1))
            else { return .systemAction }
            onTime?(seconds)
            return .handled
        })
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: RichBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // A summary is read by scanning for its sections, so a heading is given room above it
            // and full contrast. A level-three heading is a topic in a new document and a section
            // in an archived one — in both it is a thing to scan for, not a dimmed label.
            Text(inline(text))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 18 : 10)
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker ?? "•")
                    .font(marker == nil ? .body : .callout.monospacedDigit())
                    .foregroundStyle(marker == nil ? FlowTheme.accent : Color.secondary)
                    .frame(minWidth: marker == nil ? 8 : 18, alignment: .leading)
                Text(inline(text)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(FlowTheme.accent.opacity(0.35)).frame(width: 3)
                Text(inline(text)).font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            }
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(inline(cell)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider().gridCellColumns(max(1, header.count))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell)).font(.callout).lineSpacing(3)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Inline emphasis and citations in one pass: the citations are rewritten as Markdown links
    /// first, so the system parser produces real links rather than literal brackets.
    private func inline(_ text: String) -> AttributedString {
        let source = onTime == nil ? text : citationLinks(text)
        guard var value = try? AttributedString(markdown: source, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)) else { return AttributedString(text) }
        for run in value.runs where run.link?.scheme == Self.timeScheme {
            value[run.range].foregroundColor = FlowTheme.accent
            value[run.range].font = .callout.monospacedDigit()
            value[run.range].underlineStyle = nil
        }
        return value
    }

    private func citationLinks(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for reference in RichText.timeReferences(in: text) {
            result += text[cursor..<reference.range.lowerBound]
            let label = reference.label.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            result += "[\(label)](\(Self.timeScheme):\(Int(reference.seconds)))"
            cursor = reference.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
