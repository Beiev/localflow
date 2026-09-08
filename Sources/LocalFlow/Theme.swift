import SwiftUI
import LocalFlowCore

/// Shared visual language: one accent, one radius scale, one kind palette.
enum FlowTheme {
    static let accent = Color.indigo
    static let radius: CGFloat = 12
    static let overlayRadius: CGFloat = 16

    static func kindColor(_ kind: SessionKind) -> Color {
        switch kind {
        case .dictation: return .indigo
        case .note: return .teal
        case .meeting: return .orange
        }
    }
}

extension SessionKind {
    var systemImage: String {
        switch self {
        case .dictation: return "mic.fill"
        case .note: return "book.closed.fill"
        case .meeting: return "person.2.wave.2.fill"
        }
    }
    var shortTitle: String {
        switch self {
        case .dictation: return "Диктовка"
        case .note: return "Заметка"
        case .meeting: return "Созвон"
        }
    }
}

struct FlowCardStyle: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FlowTheme.radius))
    }
}

extension View {
    func flowCard(padding: CGFloat = 18) -> some View { modifier(FlowCardStyle(padding: padding)) }
}

/// Small colored square with an SF Symbol, used to mark session kind.
struct KindBadge: View {
    let kind: SessionKind
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(FlowTheme.kindColor(kind), in: RoundedRectangle(cornerRadius: size * 0.32))
    }
}

/// Live voice-level bars driven by the audio meter. Recent history sits at the
/// trailing edge; louder speech raises and brightens the bars.
struct VoiceWaveform: View {
    let levels: [Double]
    var color: Color = .red
    var body: some View {
        GeometryReader { proxy in
            let capacity = max(8, Int(proxy.size.width / 5))
            let visible = levels.suffix(capacity)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color.opacity(0.3 + 0.7 * CGFloat(min(1, max(0.05, level)))))
                        .frame(width: 3, height: 3 + 16 * CGFloat(min(1, max(0.04, level))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

extension Int {
    /// Russian plural form for "слово" (1 слово, 2 слова, 5 слов).
    var ruWordForm: String {
        let mod10 = abs(self) % 10, mod100 = abs(self) % 100
        if mod10 == 1 && mod100 != 11 { return "слово" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "слова" }
        return "слов"
    }
}
