import SwiftUI
import LocalFlowCore

/// Names for the voices in a meeting. Sixteen meetings were recorded and not one speaker was ever
/// named through the old rename field, buried in a collapsed section under the transcript — so
/// this asks at the moment the meeting is opened to be read, offers the name the recording itself
/// used, and takes one click.
struct ParticipantsView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession
    /// Compact above the transcript, full inside the collapsed section below it.
    var compact = false

    @State private var drafts: [String: String] = [:]
    @State private var dismissed: Set<String> = []
    /// Scanning every turn for vocatives is a regex pass over the whole conversation. Held in
    /// state rather than recomputed from `body`, which on a 536-turn meeting ran it twice per
    /// redraw — the same mistake the archive search was making.
    @State private var found: [SpeakerNameProposal] = []
    /// Names from the calendar invitation, fetched only when asked for: reading the calendar
    /// raises a permission prompt, and a prompt belongs to a button press.
    @State private var fromCalendar: [String] = []
    @State private var askingCalendar = false
    @State private var calendarNote: String?

    private var busy: Bool { model.processing || model.isRecording }
    private var voices: [String] { session.embeddings.keys.sorted() }
    private var identities: [String] {
        (session.segments.contains { $0.source == "microphone" } ? [RecordingSession.ownerIdentity] : []) + voices
    }
    private var unnamed: [String] { identities.filter { (session.speakers[$0] ?? "").isEmpty } }
    private var proposals: [SpeakerNameProposal] {
        found.filter { !dismissed.contains($0.id) && (session.speakers[$0.id] ?? "").isEmpty }
    }
    /// Changes that can alter who the recording thinks is speaking.
    private var namingKey: String { "\(session.id)-\(session.segments.count)-\(session.embeddings.count)" }

    var body: some View {
        content.task(id: namingKey) {
            let session = session
            found = await Task.detached { SpeakerNaming.proposals(for: session) }.value
        }
    }

    @ViewBuilder private var content: some View {
        if compact {
            if !proposals.isEmpty { VStack(alignment: .leading, spacing: 8) { ForEach(proposals) { proposal(for: $0) } } }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !proposals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) { ForEach(proposals) { proposal(for: $0) } }
                }
                ForEach(identities, id: \.self) { row(for: $0) }
                if session.kind == .meeting, !unnamed.isEmpty { calendarRow }
                if session.hasMinorIdentities {
                    Divider()
                    HStack(spacing: 10) {
                        Button { model.foldIdentities(session) } label: { Label("Свести мелкие голоса", systemImage: "arrow.triangle.merge") }
                            .disabled(busy)
                        Text("Голоса с несколькими секундами речи почти всегда обрывки соседнего — их речь уйдёт к нему.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A name spoken as a vocative only exists once people address each other, which on a first
    /// call with somebody they often never do. The invitation knows who was supposed to be there —
    /// it does not know who spoke, so these are candidates to put against a voice by hand.
    @ViewBuilder private var calendarRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    askingCalendar = true
                    Task {
                        let names = await CalendarAttendees.names(around: session.createdAt,
                                                                  duration: session.duration,
                                                                  owner: model.ownerName)
                        fromCalendar = names
                        calendarNote = names.isEmpty ? "Во встрече этого времени участников не нашлось." : nil
                        askingCalendar = false
                    }
                } label: { Label("Взять имена из календаря", systemImage: "calendar") }
                    .disabled(busy || askingCalendar)
                if askingCalendar { ProgressView().controlSize(.small) }
                if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
            }
            if !fromCalendar.isEmpty {
                Text("Кто был на встрече по календарю. Нажмите имя, потом голос, которому оно принадлежит.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(fromCalendar, id: \.self) { name in
                        Menu(name) {
                            ForEach(unnamed, id: \.self) { id in
                                Button(label(for: id)) { apply(name, to: id) }
                            }
                        }.fixedSize()
                    }
                }
            }
        }
    }

    private func proposal(for value: SpeakerNameProposal) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(FlowTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: value.id) + " — это " + value.name + "?").fontWeight(.medium)
                Text(value.reason.title + (value.mentions > 1 ? ", \(value.mentions) раза" : "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.play(session, at: value.evidence.start, source: value.evidence.source) } label: {
                Label(value.evidence.timestamp, systemImage: "play.fill").font(.caption.monospaced())
            }.buttonStyle(.borderless).help("Послушать это место")
            Button("Да, \(value.name)") { apply(value.name, to: value.id) }.buttonStyle(.borderedProminent)
            Button("Нет") { dismissed.insert(value.id) }
        }
        .padding(12)
        .background(FlowTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(for id: String) -> some View {
        HStack(spacing: 8) {
            Text(label(for: id)).font(.callout).frame(width: 108, alignment: .leading)
                .foregroundStyle(unnamed.contains(id) ? .secondary : .primary)
            TextField(id == RecordingSession.ownerIdentity ? "Ваше имя" : "Имя участника",
                      text: Binding(get: { drafts[id] ?? session.speakers[id] ?? "" }, set: { drafts[id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                .onSubmit { apply(drafts[id] ?? "", to: id) }
            Button("Сохранить") { apply(drafts[id] ?? "", to: id) }
                .disabled((drafts[id] ?? session.speakers[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            if id != RecordingSession.ownerIdentity {
                Button("Запомнить голос") { model.saveVoice(drafts[id] ?? session.speakers[id] ?? "", embedding: session.embeddings[id] ?? []) }
                    .disabled((drafts[id] ?? session.speakers[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Узнавать этот голос в следующих созвонах")
            }
            Spacer(minLength: 0)
        }
    }

    private func label(for id: String) -> String {
        id == RecordingSession.ownerIdentity ? "Вы" : session.speakerName(id, source: "system")
    }
    private func apply(_ name: String, to id: String) {
        drafts[id] = name
        model.nameSpeaker(name, as: id, in: session)
    }
}
