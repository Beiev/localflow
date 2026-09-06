import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import LocalFlowCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [RecordingSession] = []
    @Published var selection: UUID? { didSet { if oldValue != selection { answer = ""; answerSources = [] } } }
    @Published var active: RecordingSession?
    @Published var status = "Готов к работе"
    @Published var error: String?
    @Published var stableText = ""
    @Published var draftText = ""
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var liveTails: [String: String] = [:]
    @Published var liveRevision = 0
    @Published var elapsed: Double = 0
    @Published var paused = false
    @Published var processing = false
    @Published var finalText = ""
    @Published var applications: [SCRunningApplication] = []
    @Published var applicationPID: pid_t = 0
    @Published var expectedRemoteSpeakers = 0
    @Published var dictionary: [DictionaryEntry] = []
    @Published var voices: [VoiceProfile] = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var installed: Set<String> = []
    @Published var answer = ""
    @Published var answerSources: [RecordingSession] = []
    @Published var asking = false
    @Published var modelStatus = "Модели не загружены в память"
    @Published var metrics = ""
    @Published var isStarting = false
    let store: Store
    let speech = SpeechEngine()
    let editor = TextEngine()
    let speakerEngine = SpeakerEngine()
    let capture = AudioCapture()
    let shortcut = GlobalShortcut()
    let insertion = TextInsertion()
    let overlay = OverlayController()
    private var processingTask: Task<Void, Never>?
    private var currentJobID: UUID?
    private var resumeAfterDictation: [UUID] = []
    private var preempting = false
    private var downloads: [String: Task<Void, Never>] = [:]
    private var liveTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var startDate = Date()
    private var buffers: [String: AudioFrame] = [:]
    private var hypotheses: [String: LiveHypothesis] = [:]
    private var committed: [TranscriptSegment] = []
    private var nextWindowStart: [String: Double] = [:]
    private var dictationDuringMeeting: (start: Double, target: UUID)?
    private var player: AVAudioPlayer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var maintenanceTimer: Timer?
    var compact: Bool { UserDefaults.standard.bool(forKey: "compactASR") }
    var selectedSession: RecordingSession? { sessions.first { $0.id == selection } }
    var isRecording: Bool { active != nil && !processing }
    init() {
        do { try AppPaths.create(); store = try Store() } catch { fatalError("LocalFlow archive: \(error.localizedDescription)") }
        refresh()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in Task { @MainActor in
            guard let self else { return }
            await self.editor.unload()
            if !self.isRecording && !self.processing { await self.speech.unload() }
            await self.updateMetrics()
        } }
        pressure.resume(); pressureSource = pressure
        capture.onFrame = { [weak self] frame in Task { @MainActor in self?.receive(frame) } }
        capture.onError = { [weak self] error in Task { @MainActor in self?.error = error; self?.stop() } }
        shortcut.onToggle = { [weak self] in self?.toggleDictation() }
        shortcut.onCancel = { [weak self] in self?.cancel() }
        shortcut.enabled = UserDefaults.standard.bool(forKey: "shortcutEnabled")
        _ = shortcut.install()
        // No inference on startup. Only recover persisted work state.
        for var session in sessions where ["recording", "processing"].contains(session.state) {
            session.state = "interrupted"; session.error = "Обработка прервана. Аудио сохранено; нажмите «Повторить обработку»."; try? store.save(session)
        }
        do { try store.pruneAudio() } catch { self.error = error.localizedDescription }
        refresh()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording, !self.processing else { return }
                do { try self.store.pruneAudio() } catch { self.error = error.localizedDescription }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop(); await self?.unloadModels() } }
    }
    func refresh() {
        do { sessions = try store.sessions(); dictionary = try store.dictionary(); voices = try store.voices() } catch { self.error = error.localizedDescription }
        installed = Set(ModelCatalog.packages.filter(\.installed).map(\.id))
    }
    func showMain() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main-") == true || $0.title == "LocalFlow" }?.makeKeyAndOrderFront(nil) }
    func enableShortcut() { shortcut.requestPermission(); shortcut.enabled = true; UserDefaults.standard.set(true, forKey: "shortcutEnabled"); if !shortcut.install() { error = "Разрешите LocalFlow в Универсальном доступе, затем нажмите кнопку ещё раз. Отключите ⌘B в Handy, чтобы приложения не записывали одновременно." } }
    func toggleDictation() {
        guard !isStarting, !preempting else { return }
        if processing, let job = currentJobID, active?.kind != .dictation {
            insertion.capture(); preempting = true
            let task = processingTask
            task?.cancel()
            Task {
                await task?.value
                if var saved = (try? store.sessions())?.first(where: { $0.id == job }) {
                    saved.state = "queued"; saved.error = "Обработка продолжится после диктовки."; try? store.save(saved)
                    resumeAfterDictation.append(job)
                }
                active = nil; processing = false; preempting = false; start(.dictation)
            }
            return
        }
        if let active, active.kind == .meeting, !processing {
            if let range = dictationDuringMeeting { dictationDuringMeeting = nil; processMeetingDictation(since: range.start) }
            else { insertion.capture(); dictationDuringMeeting = (elapsed, active.id); overlay.show(model: self); status = "Диктовка во время созвона" }
        } else if isRecording { stop() }
        else if !processing { insertion.capture(); start(.dictation) }
    }
    func start(_ kind: SessionKind) {
        guard active == nil, !isStarting, !processing else { return }
        guard installed.contains(compact ? "asr4" : "asr8") else { error = "Откройте «Модели» и загрузите распознаватель. Для связного текста загрузите также редактор."; showMain(); return }
        let app = kind == .meeting ? applications.first { $0.processID == applicationPID } : nil
        if kind == .meeting && app == nil { error = "Выберите приложение созвона"; return }
        isStarting = true
        Task {
            var session = RecordingSession(kind: kind)
            if kind == .meeting && expectedRemoteSpeakers > 0 { session.expectedRemoteSpeakers = expectedRemoteSpeakers }
            do {
                try store.save(session)
                active = session; selection = session.id; buffers = [:]; hypotheses = [:]; committed = []; nextWindowStart = [:]
                stableText = ""; draftText = ""; liveSegments = []; liveTails = [:]; finalText = ""; elapsed = 0; paused = false; startDate = Date()
                status = "Запускаю микрофон…"
                try await capture.start(id: session.id, application: app)
                shortcut.recording = true; status = "Слушаю…"; overlay.show(model: self)
                startLoops(); refresh()
            } catch { active = nil; self.error = error.localizedDescription; var failed = session; failed.state = "interrupted"; failed.error = error.localizedDescription; try? store.save(failed); refresh() }
            isStarting = false
        }
    }
    private func startLoops() {
        liveTask = Task {
            while !Task.isCancelled && active != nil && !processing {
                if !paused { await updateLive() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        clockTask = Task {
            while !Task.isCancelled && active != nil && !processing {
                elapsed = Date().timeIntervalSince(startDate)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }
    private func receive(_ frame: AudioFrame) {
        guard active != nil, !processing else { return }
        if var old = buffers[frame.source], frame.start - old.start - Double(old.samples.count)/16000 < 0.5 {
            old.samples.append(contentsOf: frame.samples)
            let excess = old.samples.count - 12 * 16000
            if excess > 0 { old.samples.removeFirst(excess); old.start += Double(excess)/16000 }
            buffers[frame.source] = old
        } else { buffers[frame.source] = frame }
    }
    private func updateLive() async {
        guard let id = active?.id else { return }
        for source in buffers.keys.sorted() {
            guard let frame = buffers[source], frame.samples.count >= 3200 else { continue }
            let offset = max(0, Int(((nextWindowStart[source].map { max(0, $0 - 1) } ?? frame.start) - frame.start) * 16000))
            guard offset < frame.samples.count else { continue }
            let samples = Array(frame.samples.dropFirst(offset)); let start = frame.start + Double(offset)/16000
            do {
                if !(await speech.isLoaded) { status = "Запись идёт · загружаю распознаватель…" }
                let recognition = try await speech.recognize(samples, compact: compact)
                let boundary = nextWindowStart[source] ?? start
                let words = TranscriptAssembly.windowWords(recognition.words, offset: start, from: boundary, to: .infinity, source: source)
                let text = words.map(\.text).joined(separator: " ")
                guard !Task.isCancelled, active?.id == id, !processing else { return }
                var h = hypotheses[source] ?? LiveHypothesis(); h.update(text); hypotheses[source] = h
                let previous = committed.filter { $0.source == source }.suffix(3).map(\.text).joined(separator: " ")
                if dictationDuringMeeting == nil || source == "microphone" {
                    stableText = [previous, h.stable].filter { !$0.isEmpty }.joined(separator: " "); draftText = h.draft
                }
                if samples.count >= 8 * 16000 {
                    // Retain a second of right context and replay a second of left context.
                    // Timestamp ownership prevents the overlap from duplicating words.
                    let end = start + Double(samples.count)/16000 - 1
                    let finalized = words.filter { ($0.start + $0.end)/2 < end }
                    committed.append(contentsOf: TranscriptAssembly.group(finalized))
                    nextWindowStart[source] = end
                    var tail = LiveHypothesis()
                    tail.update(words.filter { ($0.start + $0.end)/2 >= end }.map(\.text).joined(separator: " "))
                    hypotheses[source] = tail
                    active?.segments = committed; if let active { try store.save(active) }
                }
                liveSegments = committed
                liveTails = hypotheses.mapValues { [$0.stable, $0.draft].filter { !$0.isEmpty }.joined(separator: " ") }
                liveRevision += 1
                status = paused ? "Пауза" : "Слушаю…"
            } catch { guard !Task.isCancelled else { return }; status = "Аудио сохраняется; расшифровку можно повторить"; self.error = error.localizedDescription; return }
        }
    }
    func pause() { paused.toggle(); capture.setPaused(paused); status = paused ? "Пауза" : "Слушаю…" }
    func stop() {
        guard let session = active, !processing, !isStarting else { return }
        currentJobID = session.id
        processing = true; status = "Завершаю расшифровку…"; shortcut.recording = false
        liveTask?.cancel(); clockTask?.cancel(); dictationDuringMeeting = nil
        processingTask = Task {
            await capture.stop(); await liveTask?.value
            var saved = session; saved.duration = elapsed; saved.state = "processing"
            do { try store.save(saved); try await process(saved, insert: session.kind == .dictation) }
            catch {
                saved = (try? store.sessions())?.first(where: { $0.id == saved.id }) ?? saved
                saved.state = "interrupted"; saved.error = Task.isCancelled ? "Обработка приостановлена" : error.localizedDescription
                try? store.save(saved); if !Task.isCancelled { self.error = error.localizedDescription }; status = "Аудио сохранено. Можно повторить обработку."
            }
            active = nil; processing = false; currentJobID = nil; refresh(); await scheduleUnload(); resumeQueued()
        }
    }
    func quit() {
        preempting = true; resumeAfterDictation = []
        liveTask?.cancel(); clockTask?.cancel(); processingTask?.cancel(); shortcut.recording = false
        Task {
            await capture.stop(); await liveTask?.value; await processingTask?.value
            if var session = active {
                session.state = "interrupted"; session.error = "Приложение закрыто. Аудио сохранено для восстановления."
                try? store.save(session)
            }
            NSApp.terminate(nil)
        }
    }
    func cancel() {
        if dictationDuringMeeting != nil { dictationDuringMeeting = nil; status = "Созвон продолжается"; return }
        guard active != nil || processing else { overlay.hide(); return }
        liveTask?.cancel(); clockTask?.cancel(); processingTask?.cancel(); shortcut.recording = false
        Task {
            await capture.stop(); await processingTask?.value
            if var session = active { session.state = "interrupted"; session.error = "Отменено пользователем. Аудио сохранено."; try? store.save(session) }
            active = nil; processing = false; overlay.hide(); refresh(); await scheduleUnload()
        }
    }
    private func resumeQueued() {
        guard !preempting, active == nil, !processing, let id = resumeAfterDictation.first else { return }
        resumeAfterDictation.removeFirst()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let mode = session.pendingMode { transform(session, mode: mode) } else { retry(session) }
    }
    func process(_ session: RecordingSession, insert: Bool = false) async throws {
        var result = session; result.state = "processing"; result.error = nil
        let parts = try AudioFiles.parts(session.id)
        if result.transcribedThrough == nil { result.segments = []; result.transcribedThrough = [:] }
        let sources = Set(parts.map(\.source)).sorted()
        for source in sources {
            let id = session.id
            let url = try await Task.detached { try AudioFiles.joinedTrack(id, source: source) }.value
            let duration = parts.filter { $0.source == source }.map { $0.start + $0.duration }.max() ?? 0
            var center = result.transcribedThrough?[source] ?? 0
            while center < duration {
                try Task.checkCancellation()
                let windowStart = max(0, center - 1)
                let windowEnd = min(duration, center + 11)
                let samples = try AudioFiles.read(url, from: windowStart, duration: windowEnd - windowStart)
                if samples.isEmpty { break }
                status = await speech.isLoaded ? "Распознаю запись…" : "Загружаю распознаватель…"
                let recognition = try await speech.recognize(samples, compact: compact)
                let boundaryEnd = min(duration, center + 10)
                if !recognition.words.isEmpty {
                    for var word in recognition.words {
                        word.start += windowStart; word.end += windowStart
                        let midpoint = (word.start + word.end)/2
                        if midpoint >= center && (midpoint < boundaryEnd || boundaryEnd == duration) {
                            word.source = source; word.speaker = source == "microphone" ? "Я" : nil
                            result.segments.append(word)
                        }
                    }
                } else if !recognition.text.isEmpty {
                    throw LocalFlowError.message("Модель не вернула временные отметки. Аудио сохранено для повторной обработки.")
                }
                center += 10
                result.transcribedThrough?[source] = center
                result.duration = max(result.duration, duration)
                try store.save(result)
                status = "Расшифровка \(Int(min(center, duration)))/\(Int(duration)) с"
            }
            // The system track is reused by diarization; both analysis files are temporary.
            if source != "system" { try? FileManager.default.removeItem(at: url) }
        }
        if result.kind == .meeting && installed.contains("speakers") {
            status = "Разделяю голоса…"
            let id = result.id
            let url = try await Task.detached { try AudioFiles.joinedTrack(id, source: "system") }.value
            defer { try? FileManager.default.removeItem(at: url) }
            do { result = try await speakerEngine.annotate(result, audio: url, profiles: voices) }
            catch { result.error = "Голоса не разделены: \(error.localizedDescription)" }
        }
        result.segments = TranscriptAssembly.group(result.segments)
        let raw = result.kind == .meeting ? result.referencedText : result.rawText
        finalText = raw
        if !raw.isEmpty && installed.contains("editor") {
            status = "Редактирую…"
            do {
                let mode: ProcessingMode = result.kind == .meeting ? .summary : .clean
                let edit = try await editor.edit(raw, mode: mode, dictionary: dictionary)
                result.versions.append(TextVersion(mode: mode, text: edit.text)); finalText = edit.text
                if edit.guarded { result.error = "Некоторые фрагменты оставлены исходными: редактор изменил защищённые детали." }
            } catch { result.error = "Расшифровка сохранена. Редактор: \(error.localizedDescription)" }
        }
        try Task.checkCancellation()
        result.state = "ready"; result.transcribedThrough = nil; result.pendingMode = nil; try store.save(result); refresh(); selection = result.id
        stableText = finalText; draftText = ""; status = "Готово"
        if insert {
            if await insertion.paste(finalText) { overlay.hide() }
            else { status = "Текст готов — выберите поле и вставьте"; overlay.show(model: self) }
        } else { overlay.hide() }
    }
    func retry(_ session: RecordingSession) {
        guard !processing, active == nil else { return }; processing = true; currentJobID = session.id
        processingTask = Task {
            do { try await process(session) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload()
        }
    }
    private func processMeetingDictation(since start: Double) {
        guard let id = active?.id else { return }
        let end = elapsed
        Task {
            do {
                await capture.checkpoint()
                let parts = try AudioFiles.parts(id).filter { $0.source == "microphone" && $0.start < end && $0.start + $0.duration > start }
                var fragments: [String] = []
                for part in parts {
                    var offset = max(0, start - part.start)
                    let stop = min(part.duration, end - part.start)
                    while offset < stop {
                        let samples = try AudioFiles.read(AppPaths.audio(id).appendingPathComponent(part.file), from: offset, duration: min(12, stop - offset))
                        if samples.isEmpty { break }
                        fragments.append(try await speech.transcribe(samples, compact: compact))
                        offset += Double(samples.count)/16000
                    }
                }
                let raw = fragments.joined(separator: " ")
                let value = installed.contains("editor") ? try await editor.edit(raw, mode: .clean, dictionary: dictionary).text : raw
                finalText = value
                if !(await insertion.paste(value)) { status = "Диктовка готова — скопируйте текст" }
                else { status = "Созвон продолжается" }
            } catch { self.error = error.localizedDescription }
        }
    }
    func transform(_ session: RecordingSession, mode: ProcessingMode) {
        guard !processing, active == nil else { return }; processing = true; currentJobID = session.id
        var pending = session; pending.pendingMode = mode; pending.state = "processing"; try? store.save(pending)
        processingTask = Task {
            do {
                let edit = try await editor.edit(session.referencedText, mode: mode, dictionary: dictionary)
                try Task.checkCancellation()
                var updated = session; updated.pendingMode = nil; updated.state = "ready"; updated.versions.append(.init(mode: mode, text: edit.text)); try store.save(updated)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload()
        }
    }
    func importAudio() {
        guard !processing, active == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        processing = true
        processingTask = Task {
            var session = RecordingSession(kind: .note); session.title = url.deletingPathExtension().lastPathComponent; currentJobID = session.id
            do { try store.save(session); let id = session.id; try await Task.detached { try AudioFiles.importFile(url, id: id) }.value; try await process(session) }
            catch { session.state = "interrupted"; session.error = error.localizedDescription; try? store.save(session); self.error = error.localizedDescription }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload()
        }
    }
    func loadApplications() { Task { do { applications = try await AudioCapture.applications(); if applicationPID == 0 { applicationPID = applications.first?.processID ?? 0 } } catch { self.error = "Разрешите запись экрана и системного аудио в настройках macOS. \(error.localizedDescription)" } } }
    func install(_ package: ModelPackage) {
        guard downloads[package.id] == nil else { return }; downloadProgress[package.id] = 0
        downloads[package.id] = Task {
            do { try await ModelInstaller().install(package) { fraction, _ in Task { @MainActor in self.downloadProgress[package.id] = fraction } } }
            catch { self.error = error.localizedDescription }
            downloads[package.id] = nil; downloadProgress[package.id] = nil; refresh()
        }
    }
    func cancelDownload(_ id: String) { downloads[id]?.cancel() }
    func ask(_ question: String, session: RecordingSession?) {
        guard !asking, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; asking = true; answer = ""
        Task {
            do {
                let candidates = try session.map { [$0] } ?? store.search(question).map(\.session)
                answerSources = Array(candidates.filter { !$0.segments.isEmpty }.prefix(5))
                let words = question.lowercased().split(separator: " ").filter { $0.count > 2 }
                let evidence = answerSources.enumerated().map { index, item in
                    let ranked = item.segments.sorted { a,b in
                        words.filter { a.text.lowercased().contains($0) }.count > words.filter { b.text.lowercased().contains($0) }.count
                    }.prefix(8).sorted { $0.start < $1.start }
                    return "[\(index+1)] \(item.title)\n" + ranked.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
                }.joined(separator: "\n\n")
                answer = try await editor.answer(question, evidence: String(evidence.prefix(18000)))
            } catch { self.error = error.localizedDescription }
            asking = false; await scheduleUnload()
        }
    }
    func save(_ session: RecordingSession) { do { try store.save(session); refresh() } catch { self.error = error.localizedDescription } }
    func delete(_ session: RecordingSession) { do { try store.delete(session.id); refresh() } catch { self.error = error.localizedDescription } }
    func addWord(_ heard: String, _ preferred: String) { guard !heard.isEmpty, !preferred.isEmpty else { return }; do { try store.save(DictionaryEntry(heard: heard, preferred: preferred)); refresh() } catch { self.error = error.localizedDescription } }
    func saveVoice(_ name: String, embedding: [Float]) { guard !name.isEmpty, !embedding.isEmpty else { return }; do { try store.save(VoiceProfile(name: name, embedding: embedding)); refresh() } catch { self.error = error.localizedDescription } }
    func deleteItem(_ id: UUID, voice: Bool) { do { try store.deleteItem(id, voice: voice); refresh() } catch { self.error = error.localizedDescription } }
    func play(_ session: RecordingSession, at seconds: Double, source: String) {
        do {
            guard let part = try AudioFiles.parts(session.id).first(where: { $0.source == source && $0.start <= seconds && $0.start + $0.duration > seconds }) else { throw LocalFlowError.message("Аудио этого фрагмента уже удалено или недоступно") }
            player = try AVAudioPlayer(contentsOf: AppPaths.audio(session.id).appendingPathComponent(part.file)); player?.currentTime = max(0, seconds - part.start); player?.play()
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop() }
    func export(_ session: RecordingSession, text selectedText: String? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.title + ".md"; panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "# \(session.title)\n\n" + (selectedText ?? session.versions.last?.text ?? session.referencedText)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func copyResult() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(finalText, forType: .string) }
    func pasteResult() { Task { if await insertion.paste(finalText, useCurrentTarget: true) { overlay.hide() } else { status = "Выберите текстовое поле другого приложения" } } }
    func scheduleUnload() async {
        await speech.scheduleUnload(after: Double(UserDefaults.standard.integer(forKey: "asrIdleSeconds").nonzero(default: 120)))
        await editor.scheduleUnload(after: Double(UserDefaults.standard.integer(forKey: "editorIdleSeconds").nonzero(default: 60)))
        await updateMetrics()
    }
    func unloadModels() async { guard !isRecording else { return }; await speech.unload(); await editor.unload(); await updateMetrics() }
    func updateMetrics() async {
        let asr = await speech.isLoaded; let llm = await editor.isLoaded
        modelStatus = "Распознавание: \(asr ? "в памяти" : "выгружено") · Редактор: \(llm ? "в памяти" : "выгружен")"
        let cold = await speech.coldStartSeconds; let inference = await speech.inferenceSeconds; let editCold = await editor.coldStartSeconds
        metrics = String(format: "Память процесса: %.0f МБ · Загрузка ASR: %.2f с · Последнее распознавание: %.2f с · Загрузка редактора: %.2f с", ProcessMetrics.footprintMB, cold, inference, editCold)
    }
}
