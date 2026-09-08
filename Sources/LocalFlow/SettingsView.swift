import SwiftUI
import AppKit
import LocalFlowCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("asrIdleSeconds") private var asrIdle = 120
    @AppStorage("editorIdleSeconds") private var editorIdle = 60
    @AppStorage("shortcutEnabled") private var shortcutEnabled = false
    @AppStorage("editingMode") private var editingMode = "clean"
    @AppStorage("editingStyle") private var editingStyle = ""
    @AppStorage("editorModel") private var editorModel = "editor"
    @AppStorage("settingsPage") private var page = "general"
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
                HStack { Text("Диктовка"); Spacer(); Text("⌘B").foregroundStyle(.secondary) }
                HStack { Text("Созвон"); Spacer(); Text("⌘⇧M").foregroundStyle(.secondary) }
                Text("Повторное нажатие завершает запись. Esc — отмена.").foregroundStyle(.secondary)
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
