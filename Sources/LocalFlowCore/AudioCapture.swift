import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import FluidAudio
import OSLog

public struct AudioPart: Codable, Sendable {
    public var file: String
    public var source: String
    public var start: Double
    public var duration: Double
    public init(file: String, source: String, start: Double, duration: Double) {
        self.file = file; self.source = source; self.start = start; self.duration = duration
    }
}
public struct AudioFrame: Sendable {
    public var source: String
    public var samples: [Float]
    public var start: Double
    public var sessionID: UUID
}
/// Capture configuration, callbacks, converters and files share one serial queue.
/// The lifecycle gate also serializes start/stop across permission and ScreenCaptureKit awaits.
public final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.beiev.localflow", category: "capture")
    private let queue = DispatchQueue(label: "LocalFlow.audio", qos: .userInitiated)
    private let lifecycle = AsyncGate()
    private var microphone: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var stream: SCStream?
    private var converters: [String: AVAudioConverter] = [:]
    private var writers: [String: AVAudioFile] = [:]
    private var partIndices: [String: Int] = [:]
    private var parts: [AudioPart] = []
    private var directory: URL?
    private var epoch: Double = 0
    private var paused = false
    private var running = false
    private var stopping = false
    private var sessionID = UUID()
    private var runtimeObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var health = CaptureHealth()
    private var failure: String?
    private var lastJournalWrite: Double = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    public var onFrame: (@Sendable (AudioFrame) -> Void)?
    public var onError: (@Sendable (UUID, String) -> Void)?
    public var onStatus: (@Sendable (UUID, String) -> Void)?
    public override init() { super.init() }

    public func start(id: UUID, captureSystemAudio: Bool = false, append: Bool = false) async throws {
        await lifecycle.acquire()
        do {
            try Task.checkCancellation()
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw LocalFlowError.message("Разрешите доступ к микрофону в Системных настройках → Конфиденциальность → Микрофон") }
            try Task.checkCancellation()
            let previous = append ? try AudioFiles.parts(id) : []
            let offset = previous.map { $0.start + $0.duration }.max() ?? 0
            let directory = AppPaths.audio(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await onQueue {
                guard !self.running else { throw LocalFlowError.message("Запись уже запущена") }
                self.directory = directory; self.epoch = ProcessInfo.processInfo.systemUptime - offset
                self.parts = previous; self.writers = [:]; self.partIndices = [:]; self.converters = [:]
                self.running = true; self.stopping = false; self.sessionID = id; self.paused = false
                self.failure = nil; self.lastJournalWrite = 0
                self.health = CaptureHealth(now: ProcessInfo.processInfo.systemUptime)
                self.persist()
                if let failure = self.failure { throw LocalFlowError.message(failure) }
                try self.startMicrophone(useFallback: false)
                self.startWatchdog()
            }
            if captureSystemAudio {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard let display = content.displays.first else { throw LocalFlowError.message("Нет экрана для захвата звука") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000; config.channelCount = 2
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await onQueue { self.stream = stream }
                try await stream.startCapture()
            }
            // startRunning() alone does not prove that the microphone delivers samples.
            // The watchdog retries a stalled input; cancellation interrupts this wait.
            while true {
                try Task.checkCancellation()
                let ready = try await onQueue {
                    if let failure = self.failure { throw LocalFlowError.message(failure) }
                    return self.health.receivedAudio
                }
                if ready { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await lifecycle.release()
        } catch {
            await stopCapture()
            await lifecycle.release()
            throw error
        }
    }
    private func onQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    private func startMicrophone(useFallback: Bool) throws {
        stopMicrophone()
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.filter { $0.isConnected && !$0.isSuspended }
        let preferred = devices.first { $0.localizedName.localizedCaseInsensitiveContains("MV7") }
        let builtIn = devices.first { $0.localizedName.localizedCaseInsensitiveContains("MacBook") }
        guard let device = (useFallback ? builtIn : preferred) ?? AVCaptureDevice.default(for: .audio) ?? devices.first else {
            throw LocalFlowError.message("Микрофон недоступен. Проверьте подключение и доступ в настройках macOS.")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw LocalFlowError.message("Не удалось подключить микрофон \(device.localizedName)") }
        session.beginConfiguration()
        session.addInput(input); session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        microphone = session; microphoneOutput = output
        runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self, weak session] _ in
            self?.queue.async { [weak self, weak session] in
                guard let self, let session, self.microphone === session, self.running, !self.stopping else { return }
                self.recoverMicrophone()
            }
        }
        Self.logger.info("Starting microphone: \(device.localizedName, privacy: .public), fallback: \(useFallback)")
        onStatus?(sessionID, "Подключаю \(device.localizedName)…")
        session.startRunning()
        guard session.isRunning else { throw LocalFlowError.message("Не удалось запустить микрофон \(device.localizedName)") }
    }
    private func stopMicrophone() {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver); self.runtimeObserver = nil }
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        microphoneOutput = nil
        microphone?.stopRunning(); microphone = nil
        converters["microphone"] = nil
    }
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.stopping else { return }
            if self.health.isStalled(at: ProcessInfo.processInfo.systemUptime) { self.recoverMicrophone() }
        }
        watchdog = timer; timer.resume()
    }
    private func recoverMicrophone() {
        guard health.beginRecovery(at: ProcessInfo.processInfo.systemUptime) else {
            fail("Микрофон перестал передавать звук. Переподключение не помогло. Проверьте микрофон и начните запись снова; полученное аудио сохранено.")
            return
        }
        Self.logger.warning("Microphone recovery attempt \(self.health.recoveries)")
        onStatus?(sessionID, "Переподключаю микрофон…")
        do { try startMicrophone(useFallback: health.recoveries > 1) }
        catch {
            // Keep the watchdog alive for the remaining bounded recovery attempt.
            if health.recoveries >= CaptureHealth.maximumRecoveries { fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }
        Self.logger.error("Capture failed: \(message, privacy: .public)")
        failure = message; running = false
        watchdog?.cancel(); watchdog = nil
        stopMicrophone()
        writers.values.forEach { $0.close() }; writers = [:]; persist()
        onError?(sessionID, message)
    }
    public func setPaused(_ value: Bool) { queue.async { self.paused = value } }
    public func checkpoint() async {
        try? await onQueue { self.writers.values.forEach { $0.close() }; self.writers = [:]; self.persist() }
    }
    public func stop() async {
        await lifecycle.acquire()
        await stopCapture()
        await lifecycle.release()
    }
    private func stopCapture() async {
        let stream = try? await onQueue {
            self.stopping = true; self.running = false
            self.watchdog?.cancel(); self.watchdog = nil
            self.stopMicrophone()
            let stream = self.stream; self.stream = nil
            return stream
        }
        if let stream { try? await stream.stopCapture() }
        try? await onQueue {
            self.writers.values.forEach { $0.close() }; self.writers = [:]; self.converters = [:]; self.persist()
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === microphoneOutput, running, !stopping else { return }
        accept(sampleBuffer, source: "microphone")
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.stream === stream, self.running, !self.stopping else { return }
            self.fail("Запись системного звука остановлена: \(error.localizedDescription)")
        }
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, type == .audio else { return }
        accept(sampleBuffer, source: "system")
    }
    private func accept(_ sampleBuffer: CMSampleBuffer, source: String) {
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let time = presentation.isFinite && abs(presentation - now) < 5 ? presentation + Double(buffer.frameLength) / buffer.format.sampleRate : now
        accept(buffer, source: source, time: time)
    }
    private func accept(_ buffer: AVAudioPCMBuffer, source: String, time: Double) {
        guard running, !stopping, let directory else { return }
        do {
            if converters[source]?.inputFormat != buffer.format { converters[source] = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter = converters[source], let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 32)) else { throw LocalFlowError.message("Не удалось преобразовать звук микрофона") }
            var used = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, status in if used { status.pointee = .noDataNow; return nil }; used = true; status.pointee = .haveData; return buffer }
            if let error { throw error }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            if source == "microphone" {
                let recovered = !health.receivedAudio
                health.didReceiveAudio(at: ProcessInfo.processInfo.systemUptime)
                if recovered {
                    Self.logger.info("Microphone PCM delivery confirmed")
                    onStatus?(sessionID, "Слушаю…")
                }
            }
            guard !paused else { return }
            let duration = Double(output.frameLength) / 16000
            let start = max(0, time - epoch - duration)
            let oldIndex = partIndices[source]
            if writers[source] == nil || (oldIndex.map { parts[$0].duration >= 30 || start - parts[$0].start - parts[$0].duration > 0.5 } ?? false) {
                writers[source]?.close(); writers[source] = nil
                let name = "\(source)-\(UUID().uuidString).caf"
                writers[source] = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
                parts.append(AudioPart(file: name, source: source, start: start, duration: 0)); partIndices[source] = parts.count - 1
                persist() // Register each new file before its first samples can outlive the process.
            }
            try writers[source]?.write(from: output)
            parts[partIndices[source]!].duration += duration
            if time - lastJournalWrite >= 0.5 { persist(); lastJournalWrite = time }
            onFrame?(AudioFrame(source: source, samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))), start: start, sessionID: sessionID))
        } catch { fail("Запись остановлена: \(error.localizedDescription)") }
    }
    private func persist() {
        guard let directory else { return }
        do { try JSONEncoder().encode(parts).write(to: directory.appendingPathComponent("parts.json"), options: .atomic) }
        catch { if failure == nil { fail("Не удалось сохранить журнал аудио: \(error.localizedDescription)") } }
    }
}

public enum AudioFiles {
    public static func parts(_ id: UUID) throws -> [AudioPart] {
        var parts = try JSONDecoder().decode([AudioPart].self, from: Data(contentsOf: AppPaths.audio(id).appendingPathComponent("parts.json")))
        // A crash may leave the last journal entry behind the audio already written.
        for index in parts.indices {
            if let file = try? AVAudioFile(forReading: AppPaths.audio(id).appendingPathComponent(parts[index].file)) {
                parts[index].duration = Double(file.length) / file.processingFormat.sampleRate
            }
        }
        return parts
    }
    public static func importFile(_ url: URL, id: UUID) throws {
        let source = try AVAudioFile(forReading: url)
        let converter = AudioConverter()
        let directory = AppPaths.audio(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var parts: [AudioPart] = []; var start: Double = 0
        while source.framePosition < source.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.processingFormat.sampleRate * 15)) else { break }
            do { try source.read(into: buffer) }
            catch {
                // Packetized MP3/AAC length may include an undecodable padding tail.
                if source.framePosition > 0 && source.length - source.framePosition < 4096 { break }
                throw error
            }
            guard buffer.frameLength > 0 else { break }
            let samples = try converter.resampleBuffer(buffer)
            let filename = "import-\(parts.count).caf"
            try write(samples, url: directory.appendingPathComponent(filename))
            let duration = Double(samples.count) / 16000
            parts.append(.init(file: filename, source: "microphone", start: start, duration: duration)); start += duration
            try JSONEncoder().encode(parts).write(to: directory.appendingPathComponent("parts.json"), options: .atomic)
        }
        try JSONEncoder().encode(parts).write(to: directory.appendingPathComponent("parts.json"), options: .atomic)
    }
    public static func write(_ samples: [Float], url: URL) throws {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { file.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity; samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }; try file.write(from: buffer)
    }
    public static func read(_ url: URL, from seconds: Double = 0, duration: Double = 15) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        file.framePosition = min(file.length, AVAudioFramePosition(seconds * file.processingFormat.sampleRate))
        let frames = Int64(min(Double(file.length - file.framePosition), duration * file.processingFormat.sampleRate))
        guard frames > 0 else { return [] }
        let end = file.framePosition + frames
        var samples: [Float] = []
        let converter = AudioConverter()
        while file.framePosition < end {
            let capacity = AVAudioFrameCount(min(end - file.framePosition, Int64(file.processingFormat.sampleRate * 15)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        }
        return samples
    }
    public static func joinedTrack(_ id: UUID, source: String) throws -> URL {
        let directory = AppPaths.audio(id); let url = directory.appendingPathComponent("\(source)-analysis.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { output.close() }
        var writtenFrames: Int64 = 0
        for part in try parts(id).filter({ $0.source == source }).sorted(by: { $0.start < $1.start }) {
            let startFrame = Int64(part.start * 16000)
            while writtenFrames < startFrame {
                let count = Int(min(16000, startFrame - writtenFrames))
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = buffer.frameCapacity; memset(buffer.floatChannelData![0], 0, count * MemoryLayout<Float>.size); try output.write(from: buffer); writtenFrames += Int64(buffer.frameLength)
            }
            let input = try AVAudioFile(forReading: directory.appendingPathComponent(part.file))
            input.framePosition = min(input.length, max(0, writtenFrames - startFrame))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            while input.framePosition < input.length {
                try input.read(into: buffer); guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer); writtenFrames += Int64(buffer.frameLength)
            }
        }; return url
    }
}
