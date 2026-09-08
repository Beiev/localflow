import SwiftUI
import AppKit
import LocalFlowCore

struct OverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(model.isRecording ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Button { if model.isRecording && model.active?.kind != .meeting { model.stop() } else { model.overlay.hide() } } label: { Image(systemName: "xmark") }.help("Завершить диктовку и скрыть окно")
                Button { model.showMain() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Развернуть")
            }
            LiveTranscriptView(stable: model.stableText.isEmpty && model.draftText.isEmpty ? (model.processing ? "Готовлю текст…" : "Говорите — слова появятся здесь") : model.stableText, draft: model.draftText)
                .frame(height: 78)
            HStack {
                Text("⌘B").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if model.isRecording {
                    if model.active?.kind != .dictation { Button(model.paused ? "Продолжить" : "Пауза") { model.pause() } }
                    Button("Отмена") { model.cancel() }
                    Button("Готово") { model.stop() }.buttonStyle(.borderedProminent).tint(.indigo)
                } else if model.processing { ProgressView().controlSize(.small); Button("Отмена") { model.cancel() } }
                else { Button("Скопировать") { model.copyResult() }; Button("Вставить") { model.pasteResult() } }
            }.font(.caption)
        }
        .buttonStyle(.plain).padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .padding(3)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var section = "archive"
    @State private var search = ""
    @State private var question = ""
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.indigo)
                    VStack(alignment: .leading) { Text("LocalFlow").font(.title3.bold()); Text("Ваш голос. Ваш Mac.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 14)
                VStack(spacing: 6) {
                    nav("archive", "Архив", "tray.full")
                    nav("memory", "Память", "brain")
                    nav("models", "Модели и настройки", "slider.horizontal.3")
                }
                Divider()
                Text("НОВАЯ ЗАПИСЬ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Button { model.toggleDictation() } label: { Label("Диктовать · ⌘B", systemImage: "mic") }
                    Button { model.createNote(); section = "archive" } label: { Label("Новая заметка", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    Button { model.toggleMeeting() } label: { Label("Записать созвон", systemImage: "person.2.wave.2").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    Button { model.importAudio() } label: { Label("Импорт аудио", systemImage: "square.and.arrow.down") }
                }.buttonStyle(.plain).disabled(model.isRecording || model.processing || model.isStarting)
                Spacer()
                Label("Всё остаётся на устройстве", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.isRecording || model.processing || model.isStarting { recordingBar }
                if section == "models" { SettingsView(model: model) }
                else if section == "memory" { MemoryView(model: model) }
                else { archive }
                if !model.isRecording && !model.processing && !model.finalText.isEmpty {
                    HStack {
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Скопировать текст") { model.copyResult() }
                    }.padding(12)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(.indigo)
        .alert("LocalFlow", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func nav(_ id: String, _ name: String, _ icon: String) -> some View {
        Button { section = id } label: { Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle()).background(section == id ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.processing ? "sparkles" : "waveform").foregroundStyle(.indigo)
                Text(model.status).fontWeight(.medium)
                Spacer(); Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                Button("Показать окно") { model.overlay.show(model: model) }
                if model.isRecording { Button(model.paused ? "Продолжить" : "Пауза") { model.pause() }; Button("Завершить") { model.stop() }.buttonStyle(.borderedProminent) }
                else { ProgressView().controlSize(.small) }
            }
            LiveTranscriptView(stable: model.liveSegments.suffix(50).map { $0.text }.joined(separator: "\n"), draft: model.liveTails.keys.sorted().compactMap { model.liveTails[$0] }.joined(separator: "\n"), fontSize: 14)
                .frame(height: 140)
        }.padding(20).background(Color.indigo.opacity(0.06))
    }
    private var archive: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Архив").font(.title2.bold()); Spacer(); Text("\(model.sessions.count)").foregroundStyle(.secondary) }.padding(.horizontal, 16).padding(.top, 22)
                TextField("Найти в записях", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16)
                List(selection: $model.selection) {
                    ForEach(filteredSessions) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(session.title).fontWeight(.medium).lineLimit(2); if session.pinned { Image(systemName: "pin.fill").font(.caption) } }
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(session.rawText.isEmpty ? session.kind.title : String(session.rawText.prefix(110))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if session.state == "interrupted" { Label("Можно восстановить", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 7).tag(session.id)
                    }
                }.listStyle(.inset)
            }.frame(minWidth: 250, idealWidth: 300, maxWidth: 370)
            if let session = model.selectedSession {
                if session.kind == .note { DiaryView(model: model, session: session).id(session.id) }
                else { SessionView(model: model, session: session).id(session.id) }
            }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(.indigo.opacity(0.8))
                    Text("Мысли становятся текстом").font(.title.bold())
                    Text("Надиктуйте заметку, запишите разговор\nили задайте вопрос своему архиву.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Настроить модели") { section = "models" }.buttonStyle(.borderedProminent)
                    ArchiveQuestionView(model: model, session: nil).padding(.top, 24).frame(maxWidth: 560)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private var filteredSessions: [RecordingSession] { search.isEmpty ? model.sessions : ((try? model.store.search(search, limit: 100)) ?? []).map(\.session) }
}
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
                TextField("Название", text: $newTitle).font(.title2.bold()).textFieldStyle(.plain).onSubmit { var value = current; value.title = newTitle; model.save(value) }
                HStack { Label(current.kind.title, systemImage: "waveform"); Text(current.createdAt.formatted()); Spacer(); Button { var value = current; value.pinned.toggle(); model.save(value) } label: { Image(systemName: current.pinned ? "pin.fill" : "pin") }.help("Сохранить аудио без срока удаления") }.font(.caption).foregroundStyle(.secondary)
                if let error = current.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Menu("Обработать") { ForEach(ProcessingMode.allCases, id: \.self) { mode in Button(mode.title) { model.transform(current, mode: mode) } } }.disabled(model.processing || model.isRecording)
                    Button("Повторить") { model.retry(current) }.disabled(model.processing || model.isRecording)
                    Button("Экспорт") { model.export(current, text: shownText) }
                    Spacer(); Button(role: .destructive) { deletePrompt = true } label: { Image(systemName: "trash") }.disabled(model.processing || model.isRecording)
                }
                Picker("Версия", selection: $selectedVersion) { Text("Исходная расшифровка").tag(-1); ForEach(Array(current.versions.enumerated()), id: \.element.id) { index, item in Text("\(item.label ?? item.mode.title) · \(item.date.formatted(date: .omitted, time: .shortened))").tag(index) } }
                if editing {
                    TextEditor(text: $editText).font(.body).frame(minHeight: 300)
                    HStack { Button("Отмена") { editing = false }; Button("Сохранить версию") { var value = current; value.versions.append(.init(mode: .clean, text: editText)); model.save(value); selectedVersion = value.versions.count - 1; editing = false }.buttonStyle(.borderedProminent) }
                } else if selectedVersion == -1 {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(current.segments.sorted { $0.start < $1.start }) { segment in
                            HStack(alignment: .top, spacing: 12) {
                                Button(segment.timestamp) { model.play(current, at: segment.start, source: segment.source) }.font(.caption.monospaced()).foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 4) { Text(current.speakerName(segment.speaker, source: segment.source)).font(.caption.bold()).foregroundStyle(.secondary); Text(segment.text).textSelection(.enabled) }
                            }
                        }
                    }
                    if current.segments.isEmpty { Text("Расшифровка появится после обработки.").foregroundStyle(.secondary) }
                } else { Text(shownText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).lineSpacing(5) }
                HStack { Button("Редактировать текст") { editText = shownText; editing = true }; Button("Остановить воспроизведение") { model.stopPlayback() }.disabled(!model.isPlaying) }
                DisclosureGroup("Запомнить исправление") { HStack { TextField("Как распознано", text: $heard); TextField("Как правильно", text: $preferred); Button("Запомнить") { model.addWord(heard, preferred); heard = ""; preferred = "" } }.textFieldStyle(.roundedBorder).padding(.top, 8) }
                if current.kind == .meeting {
                    DisclosureGroup("Уточнить разделение голосов") {
                        Picker("Собеседников", selection: Binding(get: { current.expectedRemoteSpeakers ?? 0 }, set: { count in var value = current; value.expectedRemoteSpeakers = count == 0 ? nil : count; model.save(value) })) {
                            Text("Автоматически").tag(0)
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Button("Пересчитать участников") { model.retry(current) }.disabled(model.processing || model.isRecording)
                    }
                }
                if !current.embeddings.isEmpty {
                    DisclosureGroup("Участники и знакомые голоса") {
                        ForEach(current.embeddings.keys.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(current.speakerName(id, source: "system")).font(.caption.bold())
                                TextField("Имя участника", text: Binding(get: { speakerNames[id] ?? current.speakers[id] ?? "" }, set: { speakerNames[id] = $0 }))
                                HStack {
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
                    }
                }
                Divider(); ArchiveQuestionView(model: model, session: current)
            }.padding(28)
        }.frame(minWidth: 420, maxWidth: .infinity)
        .onAppear { newTitle = current.title; selectedVersion = current.versions.count - 1 }
        .onChange(of: current.versions.count) { _, count in selectedVersion = count - 1 }
        .confirmationDialog("Удалить запись, текст и аудио?", isPresented: $deletePrompt) { Button("Удалить запись", role: .destructive) { model.delete(current) } }
    }
}
struct ArchiveQuestionView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession?
    @State private var question = ""
    @State private var allArchive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Спросить у архива").font(.headline)
            if session != nil { Toggle("Искать во всех записях", isOn: $allArchive).toggleStyle(.checkbox) }
            HStack { TextField("Какие решения мы приняли?", text: $question).textFieldStyle(.roundedBorder).onSubmit(ask); Button(action: ask) { Image(systemName: "arrow.up") }.disabled(model.asking || model.processing || model.isRecording) }
            if model.asking { ProgressView("Ищу ответ в записях…").controlSize(.small) }
            if !model.answer.isEmpty {
                Text(model.answer).textSelection(.enabled)
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
struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var preferred = ""
    var body: some View {
        Form {
            Section("Личный словарь") {
                Text("Добавляйте имена, термины и английские слова. Исправления применяются перед редактированием текста.").foregroundStyle(.secondary)
                HStack { TextField("Как распознано", text: $heard); TextField("Как правильно", text: $preferred); Button("Добавить") { model.addWord(heard, preferred); heard = ""; preferred = "" } }
                ForEach(model.dictionary) { item in HStack { Text(item.heard); Image(systemName: "arrow.right"); Text(item.preferred).fontWeight(.medium); Spacer(); Button(role: .destructive) { model.deleteItem(item.id, voice: false) } label: { Image(systemName: "trash") } } }
            }
            Section("Знакомые голоса") {
                Text("Сохраните голос из обработанного созвона. При неуверенном совпадении имя не назначается.").foregroundStyle(.secondary)
                ForEach(model.voices) { voice in HStack { Label(voice.name, systemImage: "person.wave.2"); Spacer(); Button("Удалить голос", role: .destructive) { model.deleteItem(voice.id, voice: true) } } }
            }
        }.formStyle(.grouped).navigationTitle("Память")
    }
}
