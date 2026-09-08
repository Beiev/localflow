import SwiftUI
import LocalFlowCore

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var model: AppModel?
    @Published var error: String?
    init() { retry() }
    func retry() {
        do { model = try AppModel(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func quit() { if let model { model.quit() } else { NSApp.terminate(nil) } }
}

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(LocalFlowDelegate.self) private var delegate
    @StateObject private var bootstrap = AppBootstrap()
    var body: some Scene {
        WindowGroup("LocalFlow", id: "main") {
            if let model = bootstrap.model { MainView(model: model) }
            else {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Не удалось открыть архив", systemImage: "externaldrive.badge.exclamationmark").font(.title2.bold())
                    Text(bootstrap.error ?? "Неизвестная ошибка").textSelection(.enabled)
                    Text("Записи не изменены. Проверьте доступ к папке данных и свободное место, затем повторите открытие.").foregroundStyle(.secondary)
                    HStack {
                        Button("Открыть папку данных") { NSWorkspace.shared.open(AppPaths.root) }
                        Button("Повторить") { bootstrap.retry() }.buttonStyle(.borderedProminent)
                    }
                }.padding(32).frame(width: 620)
            }
        }.defaultSize(width: 1120, height: 760)
            .commands { CommandGroup(replacing: .appTermination) { Button("Завершить LocalFlow") { bootstrap.quit() }.keyboardShortcut("q") } }
        MenuBarExtra {
            if let model = bootstrap.model { StatusMenu(model: model) }
            else { Button("Повторить открытие архива") { bootstrap.retry() } }
        } label: {
            if let model = bootstrap.model { StatusIcon(model: model) }
            else { Image(systemName: "waveform") }
        }
    }
}

final class LocalFlowDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "LocalFlow", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
}

private struct StatusIcon: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.processing ? "ellipsis.circle" : (model.isRecording ? "record.circle" : "waveform"))
            .accessibilityLabel("LocalFlow: " + model.status)
    }
}
private struct StatusMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.status)
        Button(model.isRecording ? "Завершить диктовку · ⌘B" : "Диктовать · ⌘B") { model.toggleDictation() }.disabled(model.processing || model.isStarting)
        Button(model.active?.kind == .meeting && model.isRecording ? "Завершить созвон · ⌘⇧M" : "Записать созвон · ⌘⇧M") { model.toggleMeeting() }.disabled(model.processing || (model.isRecording && model.active?.kind != .meeting))
        Button("Новая заметка") { model.createNote() }.disabled(model.isRecording || model.processing)
        if model.isRecording || model.processing { Button("Отменить · Esc") { model.cancel() } }
        Divider()
        Button("Скопировать последний текст") { model.copyResult() }.disabled(model.finalText.isEmpty)
        Button("Открыть LocalFlow") { model.showMain() }
        Button("Завершить LocalFlow") { model.quit() }
    }
}
