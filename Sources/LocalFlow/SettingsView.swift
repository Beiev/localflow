import SwiftUI
import AppKit
import LocalFlowCore

/// Captures the next key combination typed into the settings window.
/// The global tap is suspended while recording so the old shortcut does not fire.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var activeKey: String?
    @Published var message: String?
    private var monitor: Any?
    private var model: AppModel?
    func begin(key: String, model: AppModel, validate: @escaping (ShortcutSpec) -> String?, commit: @escaping (ShortcutSpec) -> Void) {
        end()
        self.model = model
        activeKey = key; message = nil
        model.setShortcutSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 { self.end(); return event }
                let spec = ShortcutSpec(keyCode: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
                if let error = validate(spec) { self.message = error; return event }
                commit(spec); self.end()
                return event
            }
        }
    }
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; activeKey = nil
        model?.setShortcutSuspended(false)
    }
}

private struct ShortcutRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: ShortcutRecorder
    let title: String
    let storageKey: String
    let defaultSpec: ShortcutSpec
    private var spec: ShortcutSpec { ShortcutSpec.load(key: storageKey, default: defaultSpec) }
    private var recording: Bool { recorder.activeKey == storageKey }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                Spacer()
                if recording {
                    Text("Нажмите сочетание…").foregroundStyle(FlowTheme.accent)
                    Button("Отменить") { recorder.end() }
                } else {
                    Text(spec.label)
                        .font(.system(size: 13, weight: .medium)).monospaced()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    Button("Изменить") { begin() }
                    if spec != defaultSpec { Button("Сбросить") { ShortcutSpec.reset(key: storageKey); model.refreshShortcut() } }
                }
            }
            if recording { Text("Esc — выйти без изменений.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func begin() {
        let otherKey = storageKey == "dictationShortcut" ? "meetingShortcut" : "dictationShortcut"
        let other = ShortcutSpec.load(key: otherKey, default: storageKey == "dictationShortcut" ? .meetingDefault : .dictationDefault)
        recorder.begin(key: storageKey, model: model, validate: { spec in
            if !spec.isValidChoice { return "Добавьте модификатор (⌘ ⌥ ⌃ ⇧) или выберите клавишу F1–F20." }
            if spec.isSystemCritical { return "Это сочетание нужно приложениям (копировать, вставить, закрыть окно). Выберите другое." }
            if spec == other { return "Уже занято другим действием." }
            return nil
        }, commit: { spec in
            spec.save(key: storageKey)
            model.refreshShortcut()
        })
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("asrIdleSeconds") private var asrIdle = 120
    @AppStorage("editorIdleSeconds") private var editorIdle = 60
    @AppStorage("shortcutEnabled") private var shortcutEnabled = false
    @AppStorage("editingMode") private var editingMode = "clean"
    @AppStorage("editingStyle") private var editingStyle = ""
    @AppStorage("editorModel") private var editorModel = "editor"
    @AppStorage("settingsPage") private var page = "general"
    @StateObject private var recorder = ShortcutRecorder()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(title: "Настройки", subtitle: "Поведение записи, модели и диагностика — всё локально.")
                Picker("Раздел настроек", selection: $page) {
                    Text("Основные").tag("general")
                    Text("Модели").tag("models")
                    Text("Диагностика").tag("diagnostics")
                }.pickerStyle(.segmented).labelsHidden()
                if page == "general" { general }
                else if page == "models" { models }
                else { diagnostics }
            }.font(.system(size: 13)).frame(maxWidth: 720, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity)
        }.navigationTitle("Настройки")
            .onAppear { model.refresh(); model.refreshShortcut() }
            .onDisappear { recorder.end() }
            .onChange(of: page) { _, _ in recorder.end() }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var general: some View {
        VStack(spacing: 20) {
            card("Запись") {
                Toggle("Глобальные сочетания клавиш", isOn: $shortcutEnabled)
                    .toggleStyle(.switch).onChange(of: shortcutEnabled) { _, _ in model.refreshShortcut() }
                ShortcutRow(model: model, recorder: recorder, title: "Диктовка", storageKey: "dictationShortcut", defaultSpec: .dictationDefault)
                ShortcutRow(model: model, recorder: recorder, title: "Созвон", storageKey: "meetingShortcut", defaultSpec: .meetingDefault)
                if let message = recorder.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                HStack { Text("Отмена записи"); Spacer(); Text("Esc").foregroundStyle(.secondary) }
                Text("Повторное нажатие завершает запись; Esc отменяет. Сочетания с ⌘ срабатывают только с левого ⌘, чтобы правый ⌘ продолжал работать в приложениях.").foregroundStyle(.secondary)
                Divider()
                Text("Созвоны: системный звук и отдельная дорожка микрофона. Shure MV7+ выбирается автоматически, когда подключён.").foregroundStyle(.secondary)
            }
            card("Редактура") {
                Picker("Режим", selection: $editingMode) {
                    Text("Аккуратно").tag("clean"); Text("Связный текст").tag("compose")
                }.pickerStyle(.segmented).labelsHidden()
                Text(editingMode == "clean" ? "Убрать речевой мусор, исправить термины и пунктуацию." : "Собрать мысли в абзацы, сохранив факты и ваш тон.").foregroundStyle(.secondary)
                Text("Ваш стиль").fontWeight(.medium)
                TextField("Например: от первого лица, без заголовков", text: $editingStyle, axis: .vertical)
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading)
                    .lineLimit(3...5).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                Text("Применяется к новым диктовкам и заметкам.").foregroundStyle(.secondary)
            }
            card("Память и хранение") {
                HStack {
                    Text("Выгрузить распознаватель"); Spacer()
                    Picker("Выгрузить распознаватель", selection: $asrIdle) { Text("Через 30 секунд").tag(30); Text("Через 2 минуты").tag(120); Text("Через 5 минут").tag(300) }.labelsHidden().frame(width: 180)
                }
                HStack {
                    Text("Выгрузить редактор"); Spacer()
                    Picker("Выгрузить редактор", selection: $editorIdle) { Text("Сразу").tag(1); Text("Через 1 минуту").tag(60); Text("Через 3 минуты").tag(180) }.labelsHidden().frame(width: 180)
                }
                Text("После выгрузки первый запуск занимает больше времени.").foregroundStyle(.secondary)
                Divider()
                Text("Аудио — 30 дней, закреплённое — без срока. Тексты сохраняются до удаления.").foregroundStyle(.secondary)
            }
        }
    }
    private var models: some View {
        VStack(spacing: 20) {
            card("На этом Mac") {
                Text("После загрузки модели работают без интернета.").foregroundStyle(.secondary)
                ForEach(ModelCatalog.packages) { package in
                    Divider()
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(package.title).fontWeight(.medium)
                            Text(ByteCountFormatter.string(fromByteCount: package.bytes, countStyle: .file)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.installed.contains(package.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Установлена") }
                        else if model.downloadProgress[package.id] != nil { Button("Остановить") { model.cancelDownload(package.id) } }
                        else { Button("Загрузить") { model.install(package) } }
                    }.padding(.vertical, 4)
                    if let progress = model.downloadProgress[package.id] { ProgressView(value: min(1, progress)) }
                }
            }
            card("Модель редактирования") {
                Picker("Модель редактирования", selection: $editorModel) {
                    Text("Gemma 4 E2B · быстрая").tag("editor")
                    Text("Qwen 4B · точная").tag("editor-qwen")
                }.pickerStyle(.segmented).labelsHidden().disabled(model.isRecording || model.processing)
                Text("Gemma 4 E2B вдвое быстрее и прошла отбор на точность; Qwen 4B — запасной вариант.").foregroundStyle(.secondary)
            }
        }
    }
    private var diagnostics: some View {
        VStack(spacing: 20) {
            card("Разрешения и клавиши") {
                Text(model.shortcutStatus).textSelection(.enabled)
                Text(model.shortcutLastEvent).foregroundStyle(.secondary)
                Button("Проверить сочетания") { model.enableShortcut() }
                HStack(spacing: 16) {
                    Link("Универсальный доступ", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    Link("Микрофон", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    Link("Звук созвонов", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            card("Ресурсы") {
                Text(model.modelStatus).foregroundStyle(.secondary)
                Text(model.metrics).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Обновить") { Task { await model.updateMetrics() } }
                    Button("Освободить память") { Task { await model.unloadModels() } }.disabled(model.isRecording || model.processing || model.asking)
                }
                Button("Открыть папку данных") { NSWorkspace.shared.open(AppPaths.root) }
            }
        }.task { await model.updateMetrics() }
    }
}
