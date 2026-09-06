import SwiftUI
import LocalFlowCore

@main
struct LocalFlowApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("LocalFlow", id: "main") { MainView(model: model) }.defaultSize(width: 1120, height: 760)
            .commands { CommandGroup(replacing: .appTermination) { Button("Завершить LocalFlow") { model.quit() }.keyboardShortcut("q") } }
        MenuBarExtra("LocalFlow", systemImage: "waveform") {
            Button(model.isRecording ? "Завершить запись" : "Диктовать · ⌘B") { model.toggleDictation() }
            Button("Новая заметка") { model.start(.note) }.disabled(model.isRecording || model.processing)
            Button("Открыть LocalFlow") { model.showMain() }
            Divider()
            Button("Освободить память") { Task { await model.unloadModels() } }.disabled(model.isRecording || model.processing)
            Button("Завершить LocalFlow") { model.quit() }
        }
    }
}
