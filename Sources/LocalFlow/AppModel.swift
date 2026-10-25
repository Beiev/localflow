import AppKit
import SwiftUI
import AVFoundation
import LocalFlowCore
import OSLog

@MainActor
final class AppModel: ObservableObject {
    private static let startupLog = Logger(subsystem: "com.beiev.localflow", category: "recording-start")
    @Published var sessions: [RecordingSession] = []
    @Published var selection: UUID? { didSet { if oldValue != selection { cancelQuestion(); answer = ""; answerSources = []; answerExcerpts = [] } } }
    @Published var active: RecordingSession?
    @Published var status = "Готов к работе"
    @Published var error: String?
    @Published var stableText = ""
    @Published var draftText = ""
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var liveTails: [String: String] = [:]
    let recordingMeter = RecordingMeter()
    private var audioLevel: Double = 0
    private var lastMeterUpdate: Double = 0
    @Published var elapsed: Double = 0
    @Published var paused = false
    @Published var processing = false
    @Published var finalText = ""
    @Published var dictionary: [DictionaryEntry] = []
    @Published var voices: [VoiceProfile] = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var installed: Set<String> = []
    @Published var answer = ""
    @Published var answerSources: [RecordingSession] = []
    @Published var answerExcerpts: [EvidenceExcerpt] = []
    @Published var asking = false
    @Published var modelStatus = "Модели не загружены в память"
    @Published var metrics = ""
    @Published var isStarting = false
    @Published var shortcutStatus = "Шорткат выключен"
    @Published var shortcutLastEvent = "Сочетание ещё не нажимали в этом запуске"
    @Published var dictationLabel = ShortcutSpec.dictationDefault.label
    @Published var meetingLabel = ShortcutSpec.meetingDefault.label
    @Published var section = "archive"
    let store: Store
    let speech = SpeechEngine()
    let editor = TextEngine()
    let speakerEngine = SpeakerEngine()
    let capture = AudioCapture()
    let shortcut = GlobalShortcut()
    let insertion = TextInsertion()
    let overlay = OverlayController()
    private var meetingDictationTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var questionRequestID = UUID()
    private var currentJobID: UUID?
    private var resumeAfterDictation: [UUID] = []
    private var preempting = false
    private var downloads: [String: Task<Void, Never>] = [:]
    private var startTask: Task<Void, Never>?
    private var stopAfterStart = false
    private var isCancelling = false
    private var captureError: String?
    private var microphoneReady = false
    private var liveTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var startDate = Date()
    private var buffers: [String: AudioFrame] = [:]
    private var hypotheses: [String: LiveHypothesis] = [:]
    private var committed: [TranscriptSegment] = []
    private var nextWindowStart: [String: Double] = [:]
    private var dictationDuringMeeting: Double?
    let playback = AudioPlayback()
    @Published var isPlaying = false
    private var pressureSource: DispatchSourceMemoryPressure?
    private var maintenanceTimer: Timer?
    var defaultEditingMode: ProcessingMode { UserDefaults.standard.string(forKey: "editingMode") == "compose" ? .compose : .clean }
    var editingStyle: String { UserDefaults.standard.string(forKey: "editingStyle") ?? "" }
    func createNote() {
        guard active == nil, !processing, !isStarting else { return }
        let note = RecordingSession.draftNote()
        do { try store.save(note); refresh(); selection = note.id; showMain() }
        catch { self.error = error.localizedDescription }
    }
    func startNote(_ note: RecordingSession) { start(.note, existing: note) }
    var selectedSession: RecordingSession? { sessions.first { $0.id == selection } }
    var isRecording: Bool { active != nil && !processing }
    init() throws {
        try AppPaths.create()
        store = try Store()
        refresh()
        playback.onChange = { [weak self] playing in self?.isPlaying = playing }
        playback.onError = { [weak self] message in self?.error = message }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in Task { @MainActor in
            guard let self else { return }
            await self.editor.unload()
            if !self.isRecording && !self.processing { await self.speech.unload() }
            await self.updateMetrics()
        } }
        pressure.resume(); pressureSource = pressure
        capture.onFrame = { [weak self] frame in Task { @MainActor in self?.receive(frame) } }
        capture.onError = { [weak self] id, message in Task { @MainActor in
            guard let self, self.active?.id == id, !self.isCancelling else { return }
            self.captureError = message
            self.error = message
            if !self.isStarting { self.stop() }
        } }
        capture.onStatus = { [weak self] id, message in Task { @MainActor in
            guard let self, self.active?.id == id, !self.processing, !self.isCancelling else { return }
            self.microphoneReady = message == "Слушаю…"
            self.status = self.paused ? "Пауза" : message
        } }
        shortcut.onToggle = { [weak self] in
            self?.shortcutLastEvent = "Последнее нажатие \(self?.dictationLabel ?? "⌘B"): " + Date().formatted(date: .omitted, time: .standard)
            self?.toggleDictation()
        }
        shortcut.onMeeting = { [weak self] in self?.toggleMeeting() }
        shortcut.onCancel = { [weak self] in self?.cancel() }
        shortcut.dictation = ShortcutSpec.load(key: "dictationShortcut", default: .dictationDefault)
        shortcut.meeting = ShortcutSpec.load(key: "meetingShortcut", default: .meetingDefault)
        dictationLabel = shortcut.dictation.label; meetingLabel = shortcut.meeting.label
        shortcut.enabled = UserDefaults.standard.bool(forKey: "shortcutEnabled")
        if shortcut.enabled { _ = shortcut.install() }
        shortcutStatus = shortcut.enabled ? shortcut.permissionStatus : "Шорткат выключен"
        // No inference on startup. Only recover persisted work state.
        for var session in sessions where ["recording", "processing", "queued"].contains(session.state) {
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
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh(); self?.refreshShortcut() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop(); await self?.unloadModels() } }
        Task { @MainActor [weak self] in
            guard let self, !isStarting, active == nil else { return }
            overlay.prepare(model: self)
        }
    }
    func refresh() {
        do { sessions = try store.sessions(); dictionary = try store.dictionary(); voices = try store.voices() } catch { self.error = error.localizedDescription }
        installed = Set(ModelCatalog.packages.filter(\.installed).map(\.id))
    }
    func showMain() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main-") == true || $0.title == "LocalFlow" }?.makeKeyAndOrderFront(nil) }
    func refreshShortcut() {
        shortcut.enabled = UserDefaults.standard.bool(forKey: "shortcutEnabled")
        shortcut.dictation = ShortcutSpec.load(key: "dictationShortcut", default: .dictationDefault)
        shortcut.meeting = ShortcutSpec.load(key: "meetingShortcut", default: .meetingDefault)
        dictationLabel = shortcut.dictation.label; meetingLabel = shortcut.meeting.label
        if shortcut.enabled { _ = shortcut.install() }
        shortcutStatus = shortcut.enabled ? shortcut.permissionStatus : "Шорткат выключен"
    }
    func setShortcutSuspended(_ value: Bool) { shortcut.suspended = value }
    func enableShortcut() {
        UserDefaults.standard.set(true, forKey: "shortcutEnabled")
        refreshShortcut()
    }
    func toggleDictation() {
        guard !isCancelling, !preempting, meetingDictationTask == nil else { return }
        if isStarting {
            stopAfterStart.toggle()
            if stopAfterStart { overlay.hide() } else { overlay.show(model: self) }
            return
        }
        if processing, active?.kind == .dictation { overlay.hide(); return }
        if processing, let job = currentJobID, active?.kind != .dictation {
            insertion.capture(); preempting = true
            let task = processingTask
            task?.cancel()
            Task {
                await task?.value
                if var saved = (try? store.session(job)) {
                    saved.state = "queued"; saved.error = "Обработка продолжится после диктовки."; try? store.save(saved)
                    resumeAfterDictation.append(job)
                }
                active = nil; processing = false; preempting = false; start(.dictation)
            }
            return
        }
        if let active, active.kind == .meeting, !processing {
            if let range = dictationDuringMeeting { dictationDuringMeeting = nil; overlay.hide(); processMeetingDictation(since: range) }
            else { insertion.capture(); dictationDuringMeeting = elapsed; overlay.show(model: self); status = "Диктовка во время созвона" }
        } else if isRecording { stop() }
        else if !processing { insertion.capture(); start(.dictation) }
    }
    func toggleMeeting() {
        if active?.kind == .meeting && isRecording { stop() }
        else if active == nil && !processing && !isStarting { start(.meeting) }
    }
    func start(_ kind: SessionKind, existing: RecordingSession? = nil) {
        guard active == nil, !isStarting, !isCancelling, !processing else { return }
        guard installed.contains("asr8") else { error = "Откройте «Модели» и загрузите распознаватель. Для связного текста загрузите также редактор."; showMain(); return }

        if let existing, existing.duration > 0, !FileManager.default.fileExists(atPath: AppPaths.audio(existing.id).appendingPathComponent("parts.json").path) {
            error = "Аудио этой заметки уже удалено. Создайте новую заметку; сохранённый текст останется в архиве."; return
        }
        cancelQuestion(); playback.stop()
        isStarting = true; stopAfterStart = false; captureError = nil; microphoneReady = false; error = nil
        shortcut.recording = true
        startTask = Task {
            var session = existing ?? RecordingSession(kind: kind)
            session.state = "recording"; session.error = nil; session.transcribedThrough = nil
            session.editingMode = defaultEditingMode; session.editingStyle = editingStyle
            if kind == .meeting {
                session.expectedRemoteSpeakers = nil
                if !ownerName.isEmpty { session.speakers[RecordingSession.ownerIdentity] = ownerName }
            }
            var persisted = false
            do {
                try Task.checkCancellation()
                active = session; buffers = [:]; hypotheses = [:]; committed = session.segments; nextWindowStart = [:]
                stableText = ""; draftText = ""; liveSegments = []; liveTails = [:]; finalText = ""; elapsed = session.duration; paused = false
                recordingMeter.levels = []; audioLevel = 0
                if kind == .dictation {
                    status = "Готовлю запись…"
                    if !stopAfterStart {
                        Self.startupLog.info("Opening recording panel before microphone startup")
                        overlay.show(model: self)
                    }
                    let stillVisible = try await overlay.waitForOpening()
                    // A second press during the entrance is just a dismissal:
                    // no microphone, empty archive item or recognizer startup.
                    if stopAfterStart || !stillVisible {
                        Self.startupLog.info("Entrance dismissed; microphone startup skipped")
                        active = nil; isStarting = false; shortcut.recording = false
                        status = "Готов к работе"
                        return
                    }
                }
                try Task.checkCancellation()
                try store.save(session); persisted = true; selection = session.id
                startDate = Date().addingTimeInterval(-session.duration)
                status = "Запускаю микрофон…"
                if kind == .dictation { Self.startupLog.info("Entrance complete; requesting microphone capture") }
                try await capture.start(id: session.id, captureSystemAudio: kind == .meeting, append: existing != nil && FileManager.default.fileExists(atPath: AppPaths.audio(session.id).appendingPathComponent("parts.json").path))
                try Task.checkCancellation()
                isStarting = false
                status = "Слушаю…"
                if stopAfterStart { stop() } else { startLoops() }
            } catch {
                isStarting = false; shortcut.recording = false
                var failed = session; failed.state = "interrupted"
                failed.error = Task.isCancelled ? "Отменено пользователем." : error.localizedDescription
                if persisted { try? store.save(failed) }
                active = nil
                if persisted { refresh() }
                if !Task.isCancelled {
                    self.error = error.localizedDescription; status = error.localizedDescription
                    if kind == .dictation { overlay.hide() }
                }
            }
        }
    }
    private func startLoops() {
        liveTask = Task {
            // Capture is already running. Keep archive decoding and cold model
            // loading away from the entrance, without dropping the first words.
            do { try await overlay.waitForOpening() } catch { return }
            guard !Task.isCancelled, active != nil, !processing else { return }
            refresh()
            while !Task.isCancelled && active != nil && !processing {
                do { try await overlay.waitForOpening() } catch { break }
                if !paused && microphoneReady { await updateLive() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        clockTask = Task {
            while !Task.isCancelled && active != nil && !processing {
                if !overlay.isOpening { elapsed = Date().timeIntervalSince(startDate) }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }
    private func receive(_ frame: AudioFrame) {
        guard active?.id == frame.sessionID, !processing, !isCancelling else { return }
        if frame.source == "microphone" { meter(frame.samples) }
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
                let recognition = try await speech.recognize(samples)
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
                    // Regroup the whole list, not just the new words: a turn that continues past a
                    // window boundary has to stay one turn. Grouping is idempotent, so replaying
                    // the committed turns through it cannot split or duplicate anything.
                    committed = TranscriptAssembly.group(committed + finalized)
                    nextWindowStart[source] = end
                    var tail = LiveHypothesis()
                    tail.update(words.filter { ($0.start + $0.end)/2 >= end }.map(\.text).joined(separator: " "))
                    hypotheses[source] = tail
                    active?.segments = committed; if let active { try store.save(active) }
                }
                liveSegments = committed
                liveTails = hypotheses.mapValues { [$0.stable, $0.draft].filter { !$0.isEmpty }.joined(separator: " ") }
                status = paused ? "Пауза" : "Слушаю…"
            } catch { guard !Task.isCancelled else { return }; status = "Аудио сохраняется; расшифровку можно повторить"; self.error = error.localizedDescription; return }
        }
    }
    /// Voice-level meter for the overlay waveform. Fast attack, slow release,
    /// square-root compression so quiet speech still moves the bars.
    private func meter(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let sum = Double(samples.reduce(Float(0)) { $0 + $1 * $1 })
        let rms = sqrt(sum / Double(samples.count))
        let target = min(1, sqrt(max(0, rms) / 0.15))
        audioLevel = max(target, audioLevel * 0.75)
        let now = ProcessInfo.processInfo.systemUptime
        guard !overlay.isOpening, now - lastMeterUpdate >= 1.0 / 30 else { return }
        lastMeterUpdate = now
        recordingMeter.append(audioLevel)
    }
    func pause() {
        paused.toggle(); capture.setPaused(paused); status = paused ? "Пауза" : "Слушаю…"
        if paused { Task { await scheduleUnload() } }
    }
    func stop() {
        if isStarting { stopAfterStart = true; overlay.hide(); return }
        guard let session = active, !processing, !isCancelling else { return }
        overlay.hide()
        elapsed = Date().timeIntervalSince(startDate)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        meetingDictationTask?.cancel()
        currentJobID = session.id
        processing = true; status = "Завершаю расшифровку…"; shortcut.recording = session.kind == .dictation
        liveTask?.cancel(); clockTask?.cancel(); dictationDuringMeeting = nil
        processingTask = Task {
            await capture.stop(); await liveTask?.value
            var saved = session; saved.duration = elapsed; saved.state = "processing"
            do {
                if let captureError, (try? AudioFiles.parts(session.id).isEmpty) != false {
                    throw LocalFlowError.message(captureError)
                }
                try store.save(saved)
                try await process(saved, insert: session.kind == .dictation, stoppedAt: stoppedAt)
                if let captureError, var result = try store.session(session.id) {
                    result.error = captureError; try store.save(result)
                    status = captureError
                    if session.kind == .dictation { overlay.hide() }
                }
            }
            catch {
                saved = (try? store.session(saved.id)) ?? saved
                saved.state = "interrupted"; saved.error = Task.isCancelled ? "Обработка приостановлена" : error.localizedDescription
                try? store.save(saved); if !Task.isCancelled { self.error = error.localizedDescription }; status = "Аудио сохранено · откройте архив для восстановления"
                // Completion never presents recording UI. Errors remain in the archive,
                // main window and menu bar, even if the user has already dismissed the panel.
                if !Task.isCancelled, session.kind == .dictation { overlay.hide() }
            }
            if session.kind != .dictation { overlay.hide() }
            active = nil; processing = false; shortcut.recording = false; currentJobID = nil; refresh(); await scheduleUnload(); resumeQueued()
        }
    }
    func quit() {
        meetingDictationTask?.cancel()
        preempting = true; resumeAfterDictation = []; isCancelling = true; startTask?.cancel()
        liveTask?.cancel(); clockTask?.cancel(); processingTask?.cancel(); shortcut.recording = false
        Task {
            await startTask?.value; await capture.stop(); await liveTask?.value; await processingTask?.value
            if var session = active {
                session.state = "interrupted"; session.error = "Приложение закрыто. Аудио сохранено для восстановления."
                try? store.save(session)
            }
            NSApp.terminate(nil)
        }
    }
    func cancel() {
        meetingDictationTask?.cancel()
        overlay.hide()
        recordingMeter.levels = []; audioLevel = 0
        if dictationDuringMeeting != nil { dictationDuringMeeting = nil; status = "Созвон продолжается"; return }
        guard !isCancelling else { return }
        guard active != nil || processing || isStarting else { shortcut.recording = false; return }
        isCancelling = true
        startTask?.cancel(); liveTask?.cancel(); clockTask?.cancel(); processingTask?.cancel(); shortcut.recording = false
        let starting = startTask, live = liveTask, job = processingTask
        Task {
            await starting?.value; await capture.stop(); await live?.value; await job?.value
            if var session = active {
                session.duration = elapsed; session.state = "interrupted"
                session.error = "Отменено пользователем. Полученное аудио сохранено."; try? store.save(session)
            }
            active = nil; processing = false; isStarting = false; currentJobID = nil
            status = "Готов к работе"; overlay.hide(); refresh(); await scheduleUnload()
            isCancelling = false; resumeQueued()
        }
    }
    private func resumeQueued() {
        guard !preempting, !isCancelling, active == nil, !processing, let id = resumeAfterDictation.first else { return }
        resumeAfterDictation.removeFirst()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let mode = session.pendingMode { transform(session, mode: mode) } else { retry(session) }
    }
    func process(_ session: RecordingSession, insert: Bool = false, stoppedAt: Double? = nil) async throws {
        let transcriptionStart = ProcessInfo.processInfo.systemUptime
        var timing: DictationMetrics?
        if insert, stoppedAt != nil {
            let speechLoaded = await speech.isLoaded
            let editorLoaded = await editor.isLoaded
            timing = DictationMetrics(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                editorID: installed.contains(ModelCatalog.editorPackageID()) ? ModelCatalog.editorPackageID() : nil,
                speechWasLoaded: speechLoaded, editorWasLoaded: editorLoaded)
        }
        status = await speech.isLoaded ? "Распознаю запись…" : "Загружаю распознаватель…"
        var result = try await SessionTranscriber(recognizer: speech, store: store).transcribe(session) { [weak self] current, total in
            Task { @MainActor in self?.status = "Расшифровка \(Int(current))/\(Int(total)) с" }
        }
        timing?.transcriptionSeconds = ProcessInfo.processInfo.systemUptime - transcriptionStart
        if result.kind == .meeting && installed.contains("speakers") && result.segments.contains(where: { $0.source == "system" }) {
            status = "Разделяю голоса…"
            let id = result.id
            let url = try await Task.detached { try AudioFiles.joinedTrack(id, source: "system") }.value
            defer { try? FileManager.default.removeItem(at: url) }
            do { result = try await speakerEngine.annotate(result, audio: url, profiles: voices) }
            catch { result.error = "Голоса не разделены: \(error.localizedDescription)" }
        }
        result.segments = TranscriptAssembly.group(result.segments)
        let raw = result.kind == .meeting ? result.referencedText : result.rawText
        finalText = TextSafety.minimalCleanup(raw, dictionary: dictionary)
        var needsReview = false
        var usedFallback = !raw.isEmpty
        let editingStart = ProcessInfo.processInfo.systemUptime
        if !raw.isEmpty && installed.contains(ModelCatalog.editorPackageID()) {
            let mode: ProcessingMode = result.kind == .meeting ? .summary : (result.editingMode ?? defaultEditingMode)
            status = mode.progressTitle
            do {
                let edit = try await editor.edit(raw, mode: mode, dictionary: dictionary, style: result.editingStyle ?? editingStyle)
                result.versions.append(TextVersion(mode: mode, text: edit.text, reviewIssues: edit.issues))
                finalText = edit.delivery(original: raw, dictionary: dictionary)
                usedFallback = edit.guarded
                timing?.reviewIssues = edit.issues
                if edit.guarded { needsReview = true; result.error = edit.reviewMessage + " Для вставки использована минимальная очистка; предложение редактора сохранено отдельной версией." }
            } catch { result.error = "Расшифровка сохранена. Редактор: \(error.localizedDescription)" }
        }
        try Task.checkCancellation()
        timing?.editingSeconds = ProcessInfo.processInfo.systemUptime - editingStart
        timing?.usedFallback = usedFallback
        if usedFallback { result.versions.append(TextVersion(mode: .clean, text: finalText, label: "Минимальная очистка")) }
        result.state = "ready"; result.transcribedThrough = nil; result.pendingMode = nil; try store.save(result); refresh(); selection = result.id
        if let stoppedAt { timing?.stopToReadySeconds = ProcessInfo.processInfo.systemUptime - stoppedAt }
        stableText = finalText; draftText = ""; status = "Готово"
        if insert {
            if !finalText.isEmpty {
                let pasted = await insertion.paste(finalText)
                timing?.pasteSucceeded = pasted
                if pasted, let stoppedAt { timing?.stopToPasteSeconds = ProcessInfo.processInfo.systemUptime - stoppedAt }
                if pasted {
                    status = needsReview ? "Текст вставлен · минимальная очистка" : "Текст вставлен"
                    overlay.hide()
                } else {
                    status = "Текст готов · поле для вставки недоступно"
                    overlay.hide()
                }
            } else { status = "Речь не обнаружена"; overlay.hide() }
        } else if raw.isEmpty { status = "Речь не обнаружена" }
        if let timing {
            do { try store.saveDictationMetrics(timing, for: result.id); refresh() }
            catch { self.error = "Текст сохранён, но замер задержки не записан: " + error.localizedDescription }
        }

    }
    private func persistInterruption(_ id: UUID, error: Error) {
        guard var saved = (try? store.session(id)) else { return }
        saved.state = "interrupted"
        saved.error = error is CancellationError ? "Обработка приостановлена. Можно продолжить." : error.localizedDescription
        try? store.save(saved)
    }
    func retry(_ session: RecordingSession) {
        if let mode = session.pendingMode { transform(session, mode: mode); return }
        guard !processing, active == nil else { return }; processing = true; currentJobID = session.id
        processingTask = Task {
            do { try await process(session) }
            catch { persistInterruption(session.id, error: error); if !Task.isCancelled { self.error = error.localizedDescription } }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload(); resumeQueued()
        }
    }
    private func processMeetingDictation(since start: Double) {
        guard let id = active?.id else { return }
        let end = elapsed
        meetingDictationTask = Task {
            defer { meetingDictationTask = nil }
            do {
                await capture.checkpoint()
                let parts = try AudioFiles.parts(id).filter { $0.source == "microphone" && $0.start < end && $0.start + $0.duration > start }
                var fragments: [String] = []
                for part in parts {
                    var offset = max(0, start - part.start)
                    let stop = min(part.duration, end - part.start)
                    while offset < stop {
                        try Task.checkCancellation()
                        let samples = try AudioFiles.read(AppPaths.audio(id).appendingPathComponent(part.file), from: offset, duration: min(12, stop - offset))
                        if samples.isEmpty { break }
                        fragments.append(try await speech.transcribe(samples))
                        offset += Double(samples.count)/16000
                    }
                }
                let raw = fragments.joined(separator: " ")
                var value = TextSafety.minimalCleanup(raw, dictionary: dictionary)
                var needsReview = false
                if !raw.isEmpty, installed.contains(ModelCatalog.editorPackageID()) {
                    do {
                        let edit = try await editor.edit(raw, mode: defaultEditingMode, dictionary: dictionary, style: editingStyle)
                        try Task.checkCancellation()
                        value = edit.delivery(original: raw, dictionary: dictionary)
                        needsReview = edit.guarded
                        if edit.guarded {
                            self.error = edit.reviewMessage + " Для вставки использована минимальная очистка."
                            if var meeting = active, meeting.id == id {
                                meeting.versions.append(.init(mode: defaultEditingMode, text: edit.text, label: "Диктовка во время созвона · предложение", reviewIssues: edit.issues))
                                active = meeting
                                try store.save(meeting)
                            }
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        self.error = "Использована минимальная очистка. Редактор: " + error.localizedDescription
                    }
                }
                try Task.checkCancellation()
                guard active?.id == id else { return }
                finalText = value
                if value.isEmpty { status = "Речь не обнаружена · созвон продолжается" }
                else if !(await insertion.paste(value)) { status = "Диктовка готова — скопируйте текст"; overlay.hide() }
                else { status = needsReview ? "Текст вставлен · минимальная очистка · созвон продолжается" : "Созвон продолжается" }
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func transform(_ session: RecordingSession, mode: ProcessingMode) {
        guard !processing, active == nil else { return }; processing = true; currentJobID = session.id
        var pending = session; pending.pendingMode = mode; pending.state = "processing"; try? store.save(pending); status = mode.progressTitle
        processingTask = Task {
            do {
                let edit = try await editor.edit((mode == .clean || mode == .compose) ? session.rawText : session.referencedText, mode: mode, dictionary: dictionary, style: editingStyle)
                try Task.checkCancellation()
                var updated = session; updated.pendingMode = nil; updated.state = "ready"; updated.versions.append(.init(mode: mode, text: edit.text, reviewIssues: edit.issues)); updated.error = edit.guarded ? edit.reviewMessage + " Редактура сохранена отдельно от исходника." : nil; try store.save(updated)
            } catch { persistInterruption(session.id, error: error); if !Task.isCancelled { self.error = error.localizedDescription } }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload(); resumeQueued()
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
            catch { persistInterruption(session.id, error: error); if !Task.isCancelled { self.error = error.localizedDescription } }
            processing = false; currentJobID = nil; refresh(); await scheduleUnload(); resumeQueued()
        }
    }
    func install(_ package: ModelPackage) {
        guard downloads[package.id] == nil else { return }; downloadProgress[package.id] = 0
        downloads[package.id] = Task {
            do { try await ModelInstaller().install(package) { fraction, _ in Task { @MainActor in self.downloadProgress[package.id] = fraction } } }
            catch { self.error = error.localizedDescription }
            downloads[package.id] = nil; downloadProgress[package.id] = nil; refresh()
        }
    }
    func cancelDownload(_ id: String) { downloads[id]?.cancel() }
    private func cancelQuestion() {
        questionTask?.cancel(); questionRequestID = UUID(); asking = false
    }
    func ask(_ question: String, session: RecordingSession?) {
        guard !asking, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let requestID = UUID(); questionRequestID = requestID
        asking = true; answer = ""; answerExcerpts = []
        questionTask = Task {
            do {
                let candidates = try session.map { [$0] } ?? store.search(question).map(\.session)
                let sources = Array(candidates.filter { !$0.segments.isEmpty }.prefix(5))
                let words = question.lowercased().split(separator: " ").filter { $0.count > 2 }
                var excerpts: [EvidenceExcerpt] = []
                let evidence = sources.enumerated().map { index, item in
                    let ranked = item.segments.sorted { a,b in
                        words.filter { a.text.lowercased().contains($0) }.count > words.filter { b.text.lowercased().contains($0) }.count
                    }.prefix(8).sorted { $0.start < $1.start }
                    excerpts += ranked.map { EvidenceExcerpt(recordingID: item.id, sourceIndex: index + 1, segment: $0) }
                    return "[\(index+1)] \(item.title)\n" + ranked.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
                }.joined(separator: "\n\n")
                let response = try await editor.answer(question, evidence: String(evidence.prefix(18000)))
                guard !Task.isCancelled, questionRequestID == requestID else { return }
                answer = response; answerSources = sources; answerExcerpts = excerpts
            } catch {
                guard !Task.isCancelled, questionRequestID == requestID else { return }
                self.error = error.localizedDescription
            }
            if questionRequestID == requestID { asking = false }
            await scheduleUnload()
        }
    }
    func save(_ session: RecordingSession) { do { try store.save(session); refresh() } catch { self.error = error.localizedDescription } }
    func delete(_ session: RecordingSession) { do { try store.delete(session.id); refresh() } catch { self.error = error.localizedDescription } }
    func addWord(_ heard: String, _ preferred: String) { guard !heard.isEmpty, !preferred.isEmpty else { return }; do { try store.save(DictionaryEntry(heard: heard, preferred: preferred)); refresh() } catch { self.error = error.localizedDescription } }
    /// The owner's own name, remembered across meetings once confirmed: it is the same person
    /// every time, and asking again on each recording is the reason nobody ever answered.
    var ownerName: String { UserDefaults.standard.string(forKey: "ownerName") ?? "" }
    func nameSpeaker(_ name: String, as id: String, in session: RecordingSession) {
        var value = session
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.speakers[id] = trimmed.isEmpty ? nil : trimmed
        save(value)
        if id == RecordingSession.ownerIdentity, !trimmed.isEmpty { UserDefaults.standard.set(trimmed, forKey: "ownerName") }
    }
    /// Folds voices too small to be participants, on a recording already in the archive. Separating
    /// them again would need the audio, which is pruned after thirty days; this needs only turns.
    func foldIdentities(_ session: RecordingSession) {
        let folded = session.foldingMinorIdentities()
        guard folded.embeddings.count != session.embeddings.count else { status = "Мелких голосов не нашлось"; return }
        save(folded)
        status = "Голоса сведены: \(session.embeddings.count) → \(folded.embeddings.count)"
    }
    func saveVoice(_ name: String, embedding: [Float]) { guard !name.isEmpty, !embedding.isEmpty else { return }; do { try store.save(VoiceProfile(name: name, embedding: embedding)); refresh() } catch { self.error = error.localizedDescription } }
    func deleteItem(_ id: UUID, voice: Bool) { do { try store.deleteItem(id, voice: voice); refresh() } catch { self.error = error.localizedDescription } }
    func play(_ session: RecordingSession, at seconds: Double, source: String) {
        do { try playback.play(session, at: seconds, source: source) }
        catch { self.error = error.localizedDescription }
    }
    /// Plays a moment cited by a condensed document, where the citation says when but not which
    /// track: the nearest recognized turn decides.
    func playMoment(_ session: RecordingSession, at seconds: Double) {
        let source = session.segments
            .min { abs($0.start - seconds) < abs($1.start - seconds) }?.source ?? "system"
        play(session, at: seconds, source: source)
    }
    /// Whether the single processing slot is busy with this record, so only its own screen shows
    /// progress for it.
    func isWorkingOn(_ id: UUID) -> Bool { currentJobID == id || active?.id == id }
    func stopPlayback() { playback.stop() }
    func export(_ session: RecordingSession, text selectedText: String? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.title + ".md"; panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "# \(session.title)\n\n" + (selectedText ?? session.versions.last?.text ?? session.referencedText)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func copyText(_ text: String) { guard !text.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copyResult() { copyText(finalText) }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let measured = sessions.compactMap(\.dictationMetrics).filter { $0.appVersion == version && $0.editorID == (installed.contains(ModelCatalog.editorPackageID()) ? ModelCatalog.editorPackageID() : nil) }
        let report = DictationReport(measured)
        func latency(_ distribution: LatencyDistribution, title: String) -> String {
            guard let median = distribution.p50, let p95 = distribution.p95 else { return title + ": пока нет замеров" }
            return String(format: "%@: %d · медиана %.2f с · p95 %.2f с", title, distribution.count, median, p95)
        }
        metrics += "\nОт остановки до подтверждения вставки (текущая версия и редактор):\n"
            + latency(report.stopToPasteWarm, title: "Модели готовы") + "\n"
            + latency(report.stopToPasteCold, title: "С загрузкой моделей")
            + "\nНеудачных вставок: \(report.insertionFailures) · Минимальная очистка: \(report.fallbacks)"
    }
}
