import AppKit
import PDFKit
import SwiftUI
import LocalFlowCore

// Renders the main window offscreen with seeded demo data; used for README screenshots.
// Run: LOCALFLOW_DATA_DIR=/tmp/lf-shots LocalFlowShots [output.png] [width] [height] [--dark] [--settings]

@main
struct LocalFlowShots {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let flags = Set(arguments.filter { $0.hasPrefix("--") })
        let values = arguments.filter { !$0.hasPrefix("--") }
        let output = values.first ?? "localflow-shot.png"
        let width = values.count > 1 ? Double(values[1]) ?? 1120 : 1120
        let height = values.count > 2 ? Double(values[2]) ?? 760 : 760
        try AppPaths.create()
        let store = try Store()
        try seedDemoArchive(store)
        let model = try AppModel()
        model.section = flags.contains("--settings") ? "settings" : "archive"
        if model.section == "archive", !model.sessions.isEmpty { model.selection = model.sessions.first { $0.kind == .meeting }?.id ?? model.sessions.first?.id }

        // NavigationSplitView and List are window-backed on macOS; host them in a real
        // offscreen window so NSTableView lays out and paints its rows.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MainView(model: model))
        host.appearance = NSAppearance(named: flags.contains("--dark") ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.displayIfNeeded()
        try await Task.sleep(for: .seconds(1))
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        let pdf = host.dataWithPDF(inside: host.bounds)
        guard let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { throw LocalFlowError.message("Не удалось создать страницу") }
        let image = page.thumbnail(of: NSSize(width: width * 2, height: height * 2), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw LocalFlowError.message("Не удалось сохранить PNG") }
        try png.write(to: URL(fileURLWithPath: output))
        print("saved \(output) \(Int(width))x\(Int(height))")
        exit(0)
    }

    private static func seedDemoArchive(_ store: Store) throws {
        guard try store.sessions().isEmpty else { return }
        var meeting = RecordingSession(kind: .meeting)
        meeting.title = "Созвон по релизу LocalFlow"
        meeting.duration = 37
        meeting.state = "ready"
        meeting.segments = [
            .init(start: 0, end: 7.4, text: "Итак, стартуем. Сегодня обсуждаем релиз и план на неделю.", source: "microphone", speaker: "Я"),
            .init(start: 7.6, end: 21.9, text: "Привет! По распознаванию всё готово, но нужно проверить длинные записи.", source: "system", speaker: "Speaker 1"),
            .init(start: 22.1, end: 36.8, text: "Отлично. Тогда я беру на себя тестирование на двухчасовом созвоне, а ты закрываешь задачи по редактуре.", source: "microphone", speaker: "Я"),
        ]
        meeting.versions = [.init(mode: .summary, text: "Обсудили готовность релиза.\n\nРешения:\n— Распознавание готово, нужна проверка длинных записей [00:07].\n— Тестирование двухчасового созвона берёт Макс [00:22].\n\nОткрытые вопросы:\n— Кто закрывает задачи по редактуре [00:22].")]
        var dictation = RecordingSession(kind: .dictation)
        dictation.title = "Мысль про статью"
        dictation.duration = 25
        dictation.state = "ready"
        dictation.segments = [
            .init(start: 0, end: 9.2, text: "Эээ, значит, идея такая:", source: "microphone", speaker: "Я"),
            .init(start: 9.4, end: 24.6, text: "написать короткий пост про локальные модели и приватность, три тезиса, без воды.", source: "microphone", speaker: "Я"),
        ]
        dictation.versions = [.init(mode: .compose, text: "Идея: написать короткий пост про локальные модели и приватность — три тезиса, без воды.")]
        var note = RecordingSession(kind: .note)
        note.title = "Дневник · вторник"
        note.state = "ready"
        note.versions = [.init(mode: .compose, text: "Сегодня дописал страницу настроек и наконец выбрал модель редактора. Вечером погулял вдоль реки — голова стала яснее.\n\nЗавтра: финальный прогон тестов и публикация репозитория.")]
        for session in [meeting, dictation, note] { try store.save(session) }
    }
}
