import SwiftUI
import AppKit
import LocalFlowCore

/// Meter ticks invalidate only the waveform, not the archive, transcript, menu
/// and the rest of AppModel's observers 30 times per second.
@MainActor
final class RecordingMeter: ObservableObject {
    @Published var levels: [Double] = []
    func append(_ level: Double) {
        var next = Array(levels.suffix(119))
        next.append(level)
        levels = next
    }
}

private struct RecordingWaveform: View {
    @ObservedObject var meter: RecordingMeter
    var color: Color
    var body: some View { VoiceWaveform(levels: meter.levels, color: color) }
}

// MARK: - Notch dictation overlay

struct OverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.isRecording && !model.isStarting ? Color.red : Color.white.opacity(0.55)).frame(width: 6, height: 6)
                Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary)
            }
            RecordingWaveform(meter: model.recordingMeter, color: Color(red: 0.65, green: 0.78, blue: 1))
                .frame(height: 18).opacity(model.isRecording ? 1 : 0.35)
            LiveTranscriptView(stable: model.stableText.isEmpty && model.draftText.isEmpty
                ? (model.isStarting ? "Говорите после «Слушаю…»" : (model.isRecording ? "Говорите — слова появятся здесь" : ""))
                : model.stableText, draft: model.draftText, fontSize: 14)
                .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 5) {
                Text(model.dictationLabel + " завершить")
                Text("·")
                Text("esc отменить")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var results: [RecordingSession] = []
    @State private var searching = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).frame(width: 36, height: 36).background(FlowTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) { Text("LocalFlow").font(.headline); Text("Ваш голос. Ваш Mac.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 12)
                Button { model.toggleDictation() } label: {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Диктовать")
                        Spacer()
                        Text(model.dictationLabel).font(.caption).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.18), in: Capsule())
                    }.font(.body.weight(.semibold)).padding(.vertical, 10).padding(.horizontal, 14)
                }
                .buttonStyle(.borderedProminent).tint(FlowTheme.accent)
                .disabled(model.isRecording || model.processing || model.isStarting)
                VStack(spacing: 2) {
                    sideAction("Новая заметка", "square.and.pencil") { model.createNote(); model.section = "archive" }
                    sideAction("Записать созвон · \(model.meetingLabel)", "person.2.wave.2") { model.toggleMeeting() }
                    sideAction("Импорт аудио", "square.and.arrow.down") { model.importAudio() }
                }.buttonStyle(.plain).disabled(model.isRecording || model.processing || model.isStarting)
                Divider()
                VStack(spacing: 2) {
                    nav("archive", "Архив", "tray.full")
                    nav("memory", "Память", "brain")
                    nav("settings", "Настройки", "slider.horizontal.3")
                }
                Spacer()
                Label("Всё остаётся на устройстве", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.isRecording || model.processing || model.isStarting { recordingBar }
                Group {
                    if model.section == "settings" { SettingsView(model: model) }
                    else if model.section == "memory" { MemoryView(model: model) }
                    else { archive }
                }
                if !model.isRecording && !model.processing && !model.finalText.isEmpty { deliveryBar }
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(FlowTheme.accent)
        .alert("LocalFlow", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func nav(_ id: String, _ name: String, _ icon: String) -> some View {
        Button { model.section = id } label: {
            Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                .background(model.section == id ? FlowTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private func sideAction(_ name: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
        }.foregroundStyle(.primary)
    }
    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.processing { Image(systemName: "sparkles").foregroundStyle(FlowTheme.accent) }
                Text(model.status).fontWeight(.medium)
                Spacer()
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                if model.isRecording {
                    Button(model.paused ? "Продолжить" : "Пауза") { model.pause() }
                    Button("Завершить") { model.stop() }.buttonStyle(.borderedProminent)
                }
            }
            if model.isRecording {
                RecordingWaveform(meter: model.recordingMeter, color: .red).frame(height: 20)
            }
            LiveTranscriptView(stable: model.liveSegments.suffix(50).map { $0.text }.joined(separator: "\n"), draft: model.liveTails.keys.sorted().compactMap { model.liveTails[$0] }.joined(separator: "\n"), fontSize: 14)
                .frame(height: 140)
        }.padding(20).background(FlowTheme.accent.opacity(0.06))
    }
    private var deliveryBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(FlowTheme.accent)
            Text(model.status).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer()
            Button("Скопировать текст") { model.copyResult() }
            Button("Вставить снова") { model.pasteResult() }
        }.padding(14).background(Color.primary.opacity(0.04))
    }
    private var archive: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Архив", subtitle: search.isEmpty
                        ? (model.sessions.isEmpty ? nil : "\(model.sessions.count) записей")
                        : "\(results.count) найдено")
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 20)
                searchField.padding(.horizontal, 16)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filteredSessions) { session in
                            Button { model.selection = session.id } label: {
                                SessionRow(session: session, selected: model.selection == session.id)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                        }
                    }.padding(.vertical, 8)
                }
            }.frame(minWidth: 250, idealWidth: 300, maxWidth: 370)
            if let session = model.selectedSession {
                if session.kind == .note { DiaryView(model: model, session: session).id(session.id) }
                else { SessionView(model: model, session: session).id(session.id) }
            }
            else { archiveEmpty }
        }
    }
    private var archiveEmpty: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(FlowTheme.accent.opacity(0.85))
            Text("Мысли становятся текстом").font(.title.bold())
            Text("Надиктуйте заметку, запишите разговор\nили задайте вопрос своему архиву.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button { model.section = "settings" } label: { Label("Настроить модели", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent)
            }
            ArchiveQuestionView(model: model, session: nil).padding(.top, 20).frame(maxWidth: 560)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// Full-text search ran inside a computed property, so every redraw of the window — a meter
    /// tick included — re-queried SQLite while the query was still being typed.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Найти в записях", text: $search).textFieldStyle(.plain)
            if searching { ProgressView().controlSize(.small) }
            else if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .task(id: search) {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { results = []; searching = false; return }
            searching = true
            // Typing is not a query. Only a pause is.
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            let found = (try? model.store.search(query, limit: 100))?.map(\.session) ?? []
            guard !Task.isCancelled else { return }
            results = found; searching = false
        }
    }
    private var filteredSessions: [RecordingSession] { search.isEmpty ? model.sessions : results }
}

private struct SessionRow: View {
    let session: RecordingSession
    var selected = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KindBadge(kind: session.kind)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                    if session.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if session.duration > 0 { Text("·"); Text(Duration.seconds(session.duration).formatted(.time(pattern: .minuteSecond))) }
                }.font(.caption).foregroundStyle(.secondary)
                Text(session.rawText.isEmpty ? session.kind.shortTitle : String(session.rawText.prefix(110))).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                if session.state == "interrupted" { Label("Можно восстановить", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .contentShape(Rectangle())
        .background(selected ? FlowTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Session detail (dictations, meetings)

/// One record, shown as what the reader came for: the condensed document, the transcript itself,
/// or the raw recognition. Before this the transcript was reachable only through an unlabelled
/// version menu that reset to the summary every time the record was opened, so after a meeting
/// was condensed there was nowhere to read what had actually been said.
struct SessionView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession

    enum Pane: Hashable { case primary, transcript, screen, source, version(Int) }

    @State private var pane: Pane?
    @State private var editText = ""
    @State private var editing = false
    @State private var newTitle = ""
    @State private var deletePrompt = false
    @State private var heard = ""
    @State private var preferred = ""
    @State private var copiedLabel: String?

    var current: RecordingSession { model.sessions.first { $0.id == session.id } ?? session }
    private var busy: Bool { model.processing || model.isRecording }
    private var isMeeting: Bool { current.kind == .meeting }

    /// Tabs follow the material: a meeting has a summary, a transcript and the recognition; a
    /// dictation's recognition already is its transcript, so it has no third tab.
    private var panes: [Pane] {
        var value: [Pane] = []
        if isMeeting {
            if current.summary != nil { value.append(.primary) }
            value.append(.transcript)
            if !current.screen.isEmpty { value.append(.screen) }
        } else if current.versions.last != nil {
            value.append(.primary)
        }
        value.append(.source)
        return value
    }
    private var selected: Pane { pane ?? panes.first ?? .source }

    private func title(for pane: Pane) -> String {
        switch pane {
        case .primary: return isMeeting ? "Конспект" : "Текст"
        case .transcript: return "Расшифровка"
        case .screen: return "Экран"
        case .source: return "Исходник"
        case .version(let index):
            // Reprocessing replaces the version list while a version tab is open; an unchecked
            // subscript here would take the window down with it.
            guard index < current.versions.count else { return "Версия" }
            return current.versions[index].label ?? current.versions[index].mode.title
        }
    }
    private var primaryVersion: TextVersion? { isMeeting ? current.summary : current.versions.last }
    /// Versions that are not one of the tabs: a rejected proposal, a spec, a task list, a
    /// dictation made during the call.
    private var extraVersions: [(index: Int, version: TextVersion)] {
        current.versions.enumerated().compactMap { index, version in
            if version.id == primaryVersion?.id { return nil }
            if version.id == current.cleanTranscript?.id { return nil }
            return (index, version)
        }.reversed()
    }
    /// What the copy button copies and the editor edits.
    private var shownText: String {
        switch selected {
        case .primary: primaryVersion?.text ?? current.referencedText
        case .transcript: current.cleanTranscript?.text ?? current.referencedText
        case .screen: current.screenDocument
        case .source: current.referencedText
        case .version(let index): index < current.versions.count ? current.versions[index].text : ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = current.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                if busy && model.isWorkingOn(current.id) {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.status).font(.callout).foregroundStyle(.secondary) }
                }
                if isMeeting { ParticipantsView(model: model, session: current, compact: true) }
                toolbar
                content
                footer
                Divider()
                ArchiveQuestionView(model: model, session: current)
            }.padding(28)
        }.frame(minWidth: 460, maxWidth: .infinity)
        .onAppear { newTitle = current.title }
        .onChange(of: current.versions.count) { _, _ in if pane == nil || !panes.contains(selected) { pane = panes.first } }
        .confirmationDialog("Удалить запись, текст и аудио?", isPresented: $deletePrompt) {
            Button("Удалить запись", role: .destructive) { model.delete(current) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KindBadge(kind: current.kind, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                TextField("Название", text: $newTitle).font(.title2.bold()).textFieldStyle(.plain)
                    .onSubmit { var value = current; value.title = newTitle; model.save(value) }
                HStack(spacing: 7) {
                    Text(current.kind.title)
                    Text("·"); Text(current.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if current.duration > 0 { Text("·"); Text(Duration.seconds(current.duration).formatted(.time(pattern: .minuteSecond))) }
                    if isMeeting, current.participantCount > 1 { Text("·"); Text("\(current.participantCount) участника") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { var value = current; value.pinned.toggle(); model.save(value) } label: {
                Image(systemName: current.pinned ? "pin.fill" : "pin")
            }.buttonStyle(.borderless).help("Сохранить аудио без срока удаления")
            Menu {
                Button("Экспорт в Markdown…") { model.export(current, text: shownText) }
                Button("Редактировать текст") { editText = shownText; editing = true }.disabled(shownText.isEmpty)
                Divider()
                Menu("Обработать заново") {
                    ForEach(ProcessingMode.available(for: current.kind), id: \.self) { mode in
                        Button(mode.title) { model.transform(current, mode: mode) }
                    }
                }.disabled(busy)
                Button("Повторить обработку") { model.retry(current) }.disabled(busy)
                Divider()
                Button("Удалить запись", role: .destructive) { deletePrompt = true }.disabled(busy)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if panes.count > 1 {
                Picker("", selection: Binding(get: { selected }, set: { pane = $0 })) {
                    ForEach(panes, id: \.self) { Text(title(for: $0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if !extraVersions.isEmpty {
                Menu {
                    ForEach(extraVersions, id: \.index) { item in
                        Button("\(item.version.label ?? item.version.mode.title) · \(item.version.date.formatted(date: .omitted, time: .shortened))") {
                            pane = .version(item.index)
                        }
                    }
                } label: {
                    Label(isVersionPane ? title(for: selected) : "Ещё версии", systemImage: "clock.arrow.circlepath")
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            if model.isPlaying { Button { model.stopPlayback() } label: { Label("Остановить", systemImage: "stop.fill") } }
            copyControl
        }
    }
    private var isVersionPane: Bool { if case .version = selected { return true }; return false }

    private var copyControl: some View {
        HStack(spacing: 2) {
            Button { copy(shownText, as: "Скопировано") } label: {
                Label(copiedLabel ?? "Скопировать", systemImage: copiedLabel == nil ? "doc.on.doc" : "checkmark")
            }.disabled(shownText.isEmpty)
            Menu {
                Button("Скопировать без разметки") { copy(RichText.plain(shownText), as: "Скопировано") }
                if let summary = current.summary {
                    Button("Скопировать конспект") { copy(summary.text, as: "Конспект скопирован") }
                }
                Button("Скопировать расшифровку") { copy(current.cleanTranscript?.text ?? current.referencedText, as: "Расшифровка скопирована") }
                Divider()
                Button("Скопировать конспект и расшифровку") { copy(current.shareableDocument, as: "Скопировано целиком") }
            } label: { Image(systemName: "chevron.down").font(.caption2) }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }
    private func copy(_ text: String, as label: String) {
        guard !text.isEmpty else { return }
        model.copyText(text)
        copiedLabel = label
        Task { try? await Task.sleep(for: .seconds(1.6)); copiedLabel = nil }
    }

    @ViewBuilder private var content: some View {
        if editing {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $editText).font(.body).frame(minHeight: 320).padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Отмена") { editing = false }
                    Button("Сохранить версию") {
                        var value = current
                        value.versions.append(.init(mode: .clean, text: editText, label: "Правка вручную"))
                        model.save(value); pane = .version(value.versions.count - 1); editing = false
                    }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            switch selected {
            case .source: sourceTurns
            case .screen: screenMoments
            case .transcript where current.cleanTranscript == nil: transcriptInvitation
            default:
                if shownText.isEmpty { Text("Здесь пока ничего нет.").foregroundStyle(.secondary) }
                else { FormattedText(markdown: shownText) { seconds in model.playMoment(current, at: seconds) } }
            }
        }
    }

    /// The recognition as it stands, one block per turn, each openable in the audio.
    private var sourceTurns: some View {
        VStack(alignment: .leading, spacing: 12) {
            if current.segments.isEmpty {
                Text("Расшифровка появится после обработки.").foregroundStyle(.secondary)
            }
            ForEach(current.segments.sorted { $0.start < $1.start }) { segment in
                HStack(alignment: .top, spacing: 12) {
                    Button(segment.timestamp) { model.play(current, at: segment.start, source: segment.source) }
                        .buttonStyle(.plain).font(.caption.monospaced()).foregroundStyle(FlowTheme.accent)
                        .frame(width: 42, alignment: .leading).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.speakerName(segment.speaker, source: segment.source))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(segment.text).textSelection(.enabled).lineSpacing(3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// What the shared screen showed, as moments rather than frames: no picture was kept, only
    /// the text that was read off it and the window it belonged to.
    private var screenMoments: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Читалось с показанного экрана: текст и заголовки окон. Кадры и видео не сохраняются.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(current.screen) { moment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(moment.timestamp) { model.playMoment(current, at: moment.start) }
                            .buttonStyle(.plain).font(.caption.monospaced()).foregroundStyle(FlowTheme.accent)
                        Text(moment.title).font(.callout.weight(.medium)).lineLimit(1)
                        if moment.duration >= 30 {
                            Text(Duration.seconds(moment.duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if let app = moment.app, !app.isEmpty, app != moment.title {
                            Text(app).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                    Text(moment.text).font(.callout).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var transcriptInvitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Чистая расшифровка").font(.headline)
            Text("Весь разговор построчно, как он был: заполнители и заикания убраны, пунктуация расставлена, "
                 + "реплики, имена, числа и порядок — без изменений. Собирается локально и занимает несколько минут.")
                .foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.transform(current, mode: .transcript) } label: { Label("Сделать расшифровку", systemImage: "text.alignleft") }
                    .buttonStyle(.borderedProminent).disabled(busy || current.segments.isEmpty)
                Button("Пока показать исходник") { pane = .source }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup { dictionaryRow } label: {
                Label("Запомнить исправление", systemImage: "text.badge.checkmark").font(.callout.weight(.medium))
            }
            if isMeeting {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Собеседников", selection: Binding(get: { current.expectedRemoteSpeakers ?? 0 }, set: { count in
                            var value = current; value.expectedRemoteSpeakers = count == 0 ? nil : count; model.save(value)
                        })) {
                            Text("Автоматически").tag(0)
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Button("Пересчитать участников") { model.retry(current) }.disabled(busy)
                    }.padding(.top, 8)
                } label: { Label("Уточнить разделение голосов", systemImage: "person.2").font(.callout.weight(.medium)) }
            }
            if isMeeting, !current.segments.isEmpty {
                DisclosureGroup {
                    ParticipantsView(model: model, session: current).padding(.top, 12)
                } label: { Label("Участники и знакомые голоса", systemImage: "waveform.badge.person").font(.callout.weight(.medium)) }
            }
        }
    }

    private var dictionaryRow: some View {
        HStack {
            TextField("Как распознано", text: $heard).labelsHidden().textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Как правильно", text: $preferred).labelsHidden().textFieldStyle(.roundedBorder)
            Button("Запомнить") { model.addWord(heard, preferred); heard = ""; preferred = "" }
        }.padding(.top, 8)
    }
}

// MARK: - Ask the archive

struct ArchiveQuestionView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession?
    @State private var question = ""
    @State private var allArchive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(FlowTheme.accent)
                Text("Спросить у архива").font(.headline)
            }
            if session != nil { Toggle("Искать во всех записях", isOn: $allArchive).toggleStyle(.checkbox) }
            HStack(spacing: 8) {
                TextField("Какие решения мы приняли?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(FlowTheme.accent)
                    .disabled(model.asking || model.processing || model.isRecording || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.asking { ProgressView("Ищу ответ в записях…").controlSize(.small) }
            if !model.answer.isEmpty {
                Text(model.answer).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                ForEach(Array(model.answerSources.enumerated()), id: \.element.id) { index, source in
                    Button("[\(index+1)] \(source.title)") { model.selection = source.id }.font(.caption)
                }
                if !model.answerExcerpts.isEmpty {
                    DisclosureGroup("Исходные фрагменты") {
                        ForEach(model.answerExcerpts) { excerpt in
                            HStack(alignment: .top) {
                                Button("[\(excerpt.sourceIndex)] \(excerpt.segment.timestamp)") {
                                    if let recording = model.sessions.first(where: { $0.id == excerpt.recordingID }) {
                                        model.play(recording, at: excerpt.segment.start, source: excerpt.segment.source)
                                    }
                                }.font(.caption.monospaced())
                                Text(excerpt.segment.text).font(.caption).textSelection(.enabled)
                            }.padding(.top, 6)
                        }
                    }
                }
            }
        }
    }
    private func ask() { guard !model.processing, !model.isRecording else { return }; model.ask(question, session: allArchive ? nil : session) }
}

// MARK: - Dictionary and voices

struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var preferred = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Память", subtitle: "Словарь и знакомые голоса помогают понимать именно вашу речь.").padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "character.book.closed").foregroundStyle(FlowTheme.accent)
                        Text("Личный словарь").font(.headline)
                    }
                    Text("Добавляйте имена, термины и английские слова. Исправления применяются перед редактированием текста.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Как распознано", text: $heard).labelsHidden().textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Как правильно", text: $preferred).labelsHidden().textFieldStyle(.roundedBorder)
                        Button("Добавить") { model.addWord(heard, preferred); heard = ""; preferred = "" }.disabled(heard.isEmpty || preferred.isEmpty)
                    }
                    ForEach(model.dictionary) { item in
                        HStack {
                            Text(item.heard); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(item.preferred).fontWeight(.medium)
                            Spacer()
                            Button(role: .destructive) { model.deleteItem(item.id, voice: false) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        }.padding(.vertical, 2)
                    }
                }.flowCard()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.wave.2").foregroundStyle(FlowTheme.accent)
                        Text("Знакомые голоса").font(.headline)
                    }
                    Text("Сохраните голос из обработанного созвона. При неуверенном совпадении имя не назначается.").font(.callout).foregroundStyle(.secondary)
                    if model.voices.isEmpty { Text("Пока пусто: сохраните голос из созвона после обработки.").font(.callout).foregroundStyle(.tertiary) }
                    ForEach(model.voices) { voice in
                        HStack { Label(voice.name, systemImage: "person.wave.2.fill"); Spacer(); Button("Удалить голос", role: .destructive) { model.deleteItem(voice.id, voice: true) } }.padding(.vertical, 2)
                    }
                }.flowCard()
            }.padding(28).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Память")
    }
}
