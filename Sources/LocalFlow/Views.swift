import SwiftUI
import AppKit
import LocalFlowCore

// MARK: - Floating dictation overlay

struct OverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if model.isRecording { PulsingDot(color: .red) }
                else if model.processing { ProgressView().controlSize(.mini) }
                else { Circle().fill(.green).frame(width: 8, height: 8) }
                Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Button { model.showMain() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)) }.help("Развернуть")
                Button { if model.isRecording && model.active?.kind != .meeting { model.stop() } else { model.overlay.hide() } } label: { Image(systemName: "xmark").font(.system(size: 11)) }.help("Завершить диктовку и скрыть окно")
            }
            .foregroundStyle(.secondary)
            LiveTranscriptView(stable: model.stableText.isEmpty && model.draftText.isEmpty ? (model.processing ? "Готовлю текст…" : "Говорите — слова появятся здесь") : model.stableText, draft: model.draftText)
                .frame(height: 82)
            HStack {
                Text("⌘B").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary, in: Capsule())
                Spacer()
                if model.isRecording {
                    if model.active?.kind != .dictation { Button(model.paused ? "Продолжить" : "Пауза") { model.pause() } }
                    Button("Отмена") { model.cancel() }
                    Button("Готово") { model.stop() }.buttonStyle(.borderedProminent).tint(FlowTheme.accent)
                } else if model.processing {
                    Button("Отмена") { model.cancel() }
                } else {
                    Button("Скопировать") { model.copyResult() }
                    Button("Вставить") { model.pasteResult() }.buttonStyle(.borderedProminent).tint(FlowTheme.accent)
                }
            }.font(.caption)
        }
        .buttonStyle(.plain).padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FlowTheme.overlayRadius))
        .overlay(RoundedRectangle(cornerRadius: FlowTheme.overlayRadius).strokeBorder(.white.opacity(0.15)))
        .padding(3)
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
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
                        Text("⌘B").font(.caption).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.18), in: Capsule())
                    }.font(.body.weight(.semibold)).padding(.vertical, 10).padding(.horizontal, 14)
                }
                .buttonStyle(.borderedProminent).tint(FlowTheme.accent)
                .disabled(model.isRecording || model.processing || model.isStarting)
                VStack(spacing: 2) {
                    sideAction("Новая заметка", "square.and.pencil") { model.createNote(); model.section = "archive" }
                    sideAction("Записать созвон · ⌘⇧M", "person.2.wave.2") { model.toggleMeeting() }
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
                if model.processing { Image(systemName: "sparkles").foregroundStyle(FlowTheme.accent) } else { PulsingDot(color: .red) }
                Text(model.status).fontWeight(.medium)
                Spacer()
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                Button("Показать окно") { model.overlay.show(model: model) }
                if model.isRecording {
                    Button(model.paused ? "Продолжить" : "Пауза") { model.pause() }
                    Button("Завершить") { model.stop() }.buttonStyle(.borderedProminent)
                }
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
                HStack { SectionHeader(title: "Архив", subtitle: model.sessions.isEmpty ? nil : "\(model.sessions.count) записей"); Spacer() }.padding(.horizontal, 16).padding(.top, 20)
                TextField("Найти в записях", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16)
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
    private var filteredSessions: [RecordingSession] { search.isEmpty ? model.sessions : ((try? model.store.search(search, limit: 100)) ?? []).map(\.session) }
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

struct SessionView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession
    @State private var selectedVersion = -1
    @State private var editText = ""
    @State private var editing = false
    @State private var newTitle = ""
    @State private var deletePrompt = false
    @State private var speakerNames: [String: String] = [:]
    @State private var heard = ""
    @State private var preferred = ""
    var current: RecordingSession { model.sessions.first { $0.id == session.id } ?? session }
    var shownText: String { if selectedVersion >= 0 && selectedVersion < current.versions.count { return current.versions[selectedVersion].text }; return current.referencedText }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    KindBadge(kind: current.kind, size: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Название", text: $newTitle).font(.title2.bold()).textFieldStyle(.plain).onSubmit { var value = current; value.title = newTitle; model.save(value) }
                        HStack(spacing: 8) {
                            Text(current.kind.title); Text("·"); Text(current.createdAt.formatted())
                            if current.duration > 0 { Text("·"); Text(Duration.seconds(current.duration).formatted(.time(pattern: .minuteSecond))) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { var value = current; value.pinned.toggle(); model.save(value) } label: { Image(systemName: current.pinned ? "pin.fill" : "pin") }.help("Сохранить аудио без срока удаления")
                    Button(role: .destructive) { deletePrompt = true } label: { Image(systemName: "trash") }.disabled(model.processing || model.isRecording)
                }
                if let error = current.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Menu { ForEach(ProcessingMode.allCases, id: \.self) { mode in Button(mode.title) { model.transform(current, mode: mode) } } } label: { Label("Обработать", systemImage: "wand.and.stars") }.disabled(model.processing || model.isRecording)
                    Button { model.retry(current) } label: { Label("Повторить", systemImage: "arrow.clockwise") }.disabled(model.processing || model.isRecording)
                    Button { model.export(current, text: shownText) } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Picker("Версия", selection: $selectedVersion) { Text("Исходная расшифровка").tag(-1); ForEach(Array(current.versions.enumerated()), id: \.element.id) { index, item in Text("\(item.label ?? item.mode.title) · \(item.date.formatted(date: .omitted, time: .shortened))").tag(index) } }
                        .pickerStyle(.menu).labelsHidden()
                        .disabled(current.versions.isEmpty)
                }
                if editing {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $editText).font(.body).frame(minHeight: 300).padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        HStack { Button("Отмена") { editing = false }; Button("Сохранить версию") { var value = current; value.versions.append(.init(mode: .clean, text: editText)); model.save(value); selectedVersion = value.versions.count - 1; editing = false }.buttonStyle(.borderedProminent) }
                    }
                } else if selectedVersion == -1 {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(current.segments.sorted { $0.start < $1.start }) { segment in
                            HStack(alignment: .top, spacing: 12) {
                                Button(segment.timestamp) { model.play(current, at: segment.start, source: segment.source) }.font(.caption.monospaced()).foregroundStyle(FlowTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(current.speakerName(segment.speaker, source: segment.source)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: Capsule())
                                    Text(segment.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if current.segments.isEmpty { Text("Расшифровка появится после обработки.").foregroundStyle(.secondary) }
                } else {
                    Text(shownText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).lineSpacing(5)
                }
                HStack {
                    Button { model.copyText(shownText) } label: { Label("Скопировать", systemImage: "doc.on.doc") }.disabled(shownText.isEmpty)
                    Button { editText = shownText; editing = true } label: { Label("Редактировать", systemImage: "pencil") }.disabled(shownText.isEmpty)
                    if model.isPlaying { Button("Остановить воспроизведение") { model.stopPlayback() } }
                    Spacer()
                }
                DisclosureGroup { dictionaryRow } label: { Label("Запомнить исправление", systemImage: "text.badge.checkmark").font(.callout.weight(.medium)) }
                if current.kind == .meeting {
                    DisclosureGroup {
                        Picker("Собеседников", selection: Binding(get: { current.expectedRemoteSpeakers ?? 0 }, set: { count in var value = current; value.expectedRemoteSpeakers = count == 0 ? nil : count; model.save(value) })) {
                            Text("Автоматически").tag(0)
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Button("Пересчитать участников") { model.retry(current) }.disabled(model.processing || model.isRecording)
                    } label: { Label("Уточнить разделение голосов", systemImage: "person.2").font(.callout.weight(.medium)) }
                }
                if !current.embeddings.isEmpty {
                    DisclosureGroup {
                        ForEach(current.embeddings.keys.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(current.speakerName(id, source: "system")).font(.caption.bold())
                                HStack {
                                    TextField("Имя участника", text: Binding(get: { speakerNames[id] ?? current.speakers[id] ?? "" }, set: { speakerNames[id] = $0 })).textFieldStyle(.roundedBorder)
                                    Button("Сохранить имя") {
                                        var value = current
                                        let name = (speakerNames[id] ?? current.speakers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        value.speakers[id] = name.isEmpty ? nil : name; model.save(value)
                                    }
                                    Button("Запомнить голос") { model.saveVoice(speakerNames[id] ?? current.speakers[id] ?? "", embedding: current.embeddings[id] ?? []) }
                                        .disabled((speakerNames[id] ?? current.speakers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }.padding(.top, 12)
                        }
                    } label: { Label("Участники и знакомые голоса", systemImage: "waveform.badge.person").font(.callout.weight(.medium)) }
                }
                Divider()
                ArchiveQuestionView(model: model, session: current)
            }.padding(28)
        }.frame(minWidth: 420, maxWidth: .infinity)
        .onAppear { newTitle = current.title; selectedVersion = current.versions.count - 1 }
        .onChange(of: current.versions.count) { _, count in selectedVersion = count - 1 }
        .confirmationDialog("Удалить запись, текст и аудио?", isPresented: $deletePrompt) { Button("Удалить запись", role: .destructive) { model.delete(current) } }
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
