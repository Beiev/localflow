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

/// Breathing dot that marks an active recording.
struct PulsingDot: View {
    var color: Color = .red
    @State private var pulsing = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(pulsing ? 1.35 : 0.7).opacity(pulsing ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulsing = true }
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
