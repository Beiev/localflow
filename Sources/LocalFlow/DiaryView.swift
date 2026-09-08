import SwiftUI
import LocalFlowCore

/// A note opens as a quiet page; microphone capture is always a separate action.
struct DiaryView: View {
    @ObservedObject var model: AppModel
    let session: RecordingSession
    @State private var showDetails = false
    @State private var showDelete = false
    @State private var editing = false
    @State private var text = ""
    private var current: RecordingSession { model.sessions.first { $0.id == session.id } ?? session }
    private var busy: Bool { model.isRecording || model.processing || model.isStarting }
    private var content: String { current.versions.last?.text ?? current.rawText }
    private var wordCount: Int { content.split(whereSeparator: \.isWhitespace).count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(current.createdAt.formatted(date: .complete, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    if wordCount > 0 { Text("· \(wordCount) слов").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                TextField("Название заметки", text: Binding(get: { current.title }, set: { var note = current; note.title = $0; model.save(note) }))
                    .font(.title.bold()).textFieldStyle(.plain).disabled(busy)
                TextField("О чём хотите рассказать? Короткое описание — необязательно", text: Binding(get: { current.noteDescription ?? "" }, set: { var note = current; note.noteDescription = $0; model.save(note) }), axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).foregroundStyle(.secondary).disabled(busy)
                if !busy {
                    HStack {
                        Button { model.startNote(current) } label: {
                            Label(current.duration > 0 ? "Дополнить голосом" : "Начать диктовку", systemImage: "mic.fill")
                        }.buttonStyle(.borderedProminent).tint(FlowTheme.accent).disabled(editing)
                        Text("Режим: " + model.defaultEditingMode.title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("Исходник и версии") { showDetails = true }
                            if !content.isEmpty {
                                Button("Скопировать текст") { model.copyText(content) }
                                Button("Редактировать текст") { text = content; editing = true }
                                Button("Экспорт") { model.export(current, text: content) }
                                Menu("Обработать заново") {
                                    ForEach(ProcessingMode.allCases, id: \.self) { mode in
                                        Button(mode.title) { model.transform(current, mode: mode) }
                                    }
                                }
                            }
                            Button(current.pinned ? "Обычный срок хранения аудио" : "Сохранить аудио бессрочно") { var note = current; note.pinned.toggle(); model.save(note) }
                            Button("Удалить заметку", role: .destructive) { showDelete = true }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if let error = current.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    if current.state == "interrupted" { Button("Продолжить обработку") { model.retry(current) }.disabled(busy) }
                }
                if editing {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $text).font(.body).frame(minHeight: 320).padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Отмена") { editing = false }
                            Button("Сохранить текст") {
                                var note = current; note.versions.append(.init(mode: .clean, text: text)); model.save(note); editing = false
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                } else if !content.isEmpty {
                    Text(content).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else if !busy {
                    Text("Заметка уже сохранена. Начните диктовку, когда будете готовы.")
                        .foregroundStyle(.secondary).padding(.top, 32)
                }
                Spacer(minLength: 80)
            }.padding(32).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showDetails) {
            VStack(spacing: 0) {
                HStack { Text("Исходник и версии").font(.headline); Spacer(); Button("Закрыть") { showDetails = false } }.padding()
                SessionView(model: model, session: current)
            }.frame(width: 720, height: 680)
        }
        .confirmationDialog("Удалить заметку и её аудио?", isPresented: $showDelete) {
            Button("Удалить", role: .destructive) { model.delete(current) }
        }
    }
}
