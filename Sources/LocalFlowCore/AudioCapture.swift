import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import FluidAudio

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
}
/// All mutable audio/file state lives on one serial queue, never the UI thread.
public final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalFlow.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var converters: [String: AVAudioConverter] = [:]
    private var writers: [String: AVAudioFile] = [:]
    private var partIndices: [String: Int] = [:]
    private var parts: [AudioPart] = []
    private var directory: URL?
    private var epoch: Double = 0
    private var paused = false
    private var running = false
    private var lastJournalWrite: Double = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    public var onFrame: (@Sendable (AudioFrame) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    public override init() { super.init() }
    public static func applications() async throws -> [SCRunningApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier && !$0.applicationName.isEmpty }.sorted { $0.applicationName < $1.applicationName }
    }
    public func start(id: UUID, application: SCRunningApplication? = nil) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw LocalFlowError.message("Разрешите доступ к микрофону в Системных настройках → Конфиденциальность → Микрофон") }
        let directory = AppPaths.audio(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await withCheckedContinuation { c in queue.async { self.directory = directory; self.epoch = ProcessInfo.processInfo.systemUptime; self.parts = []; self.writers = [:]; self.partIndices = [:]; self.converters = [:]; self.running = true; self.paused = false; c.resume() } }
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw LocalFlowError.message("Микрофон недоступен") }
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                // The tap buffer is reused by AVAudioEngine; copy before leaving the callback.
                guard let copy = Self.copy(buffer) else { return }
                let time = ProcessInfo.processInfo.systemUptime
                self?.queue.async { self?.accept(copy, source: "microphone", time: time) }
            }
            self.engine = engine
            engine.prepare(); try engine.start()
            if let application {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw LocalFlowError.message("Нет экрана для захвата звука") }
                let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000; config.channelCount = 2
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                self.stream = stream
                try await stream.startCapture()
            }
        } catch { await stop(); throw error }
    }
    public func setPaused(_ value: Bool) { queue.async { self.paused = value } }
    public func checkpoint() async {
        await withCheckedContinuation { c in queue.async { self.writers.values.forEach { $0.close() }; self.writers = [:]; self.persist(); c.resume() } }
    }
    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        if let stream { try? await stream.stopCapture() }; stream = nil
        await withCheckedContinuation { c in queue.async { self.running = false; self.writers.values.forEach { $0.close() }; self.writers = [:]; self.converters = [:]; self.persist(); c.resume() } }
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) { onError?("Запись системного звука остановлена: \(error.localizedDescription)") }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr else { return }
        accept(buffer, source: "system", time: ProcessInfo.processInfo.systemUptime)
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        for (from, to) in zip(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
            if let a = from.mData, let b = to.mData { memcpy(b, a, Int(from.mDataByteSize)) }
        }; return copy
    }
    private func accept(_ buffer: AVAudioPCMBuffer, source: String, time: Double) {
        guard running, !paused, let directory else { return }
        do {
            if converters[source]?.inputFormat != buffer.format { converters[source] = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter = converters[source], let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 32)) else { return }
            var used = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, status in if used { status.pointee = .noDataNow; return nil }; used = true; status.pointee = .haveData; return buffer }
            if let error { throw error }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
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
            onFrame?(AudioFrame(source: source, samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))), start: start))
        } catch { running = false; writers.values.forEach { $0.close() }; writers = [:]; persist(); onError?("Запись остановлена: \(error.localizedDescription)") }
    }
    private func persist() {
        guard let directory else { return }
        do { try JSONEncoder().encode(parts).write(to: directory.appendingPathComponent("parts.json"), options: .atomic) }
        catch { onError?("Не удалось сохранить журнал аудио: \(error.localizedDescription)") }
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
            try source.read(into: buffer)
            let samples = try converter.resampleBuffer(buffer)
            let filename = "import-\(parts.count).caf"
            try write(samples, url: directory.appendingPathComponent(filename))
            let duration = Double(samples.count) / 16000
            parts.append(.init(file: filename, source: "microphone", start: start, duration: duration)); start += duration
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
