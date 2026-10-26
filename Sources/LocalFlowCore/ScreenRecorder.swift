import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OSLog

/// Reads the shared screen while a meeting is recorded. A second output on the same
/// ScreenCaptureKit stream the system audio already uses, with its own queue: recognition takes
/// hundreds of milliseconds and must never sit in front of an audio buffer.
///
/// What it keeps is text and window titles, not video. One frame every few seconds is reduced to a
/// 16×16 thumbnail; only a frame that differs from the last one *read* is recognized, and only
/// recognized text is written — to a journal beside the audio, line by line, so a crash leaves
/// what was already seen.
public final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.beiev.localflow", category: "screen")
    /// Its own queue, handed to `addStreamOutput` so frames never queue behind audio.
    public let queue = DispatchQueue(label: "LocalFlow.screen", qos: .utility)
    /// How often ScreenCaptureKit is asked for a frame. Slides and documents do not change faster
    /// than this, and every frame costs a thumbnail.
    public static let frameInterval = CMTime(value: 3, timescale: 1)
    /// Widest frame asked for. Recognition does not need a retina image, and a smaller one is
    /// faster to reduce and to read.
    public static let widestFrame = 1600

    private var session: UUID?
    private var epoch: Double = 0
    private var languages: [String] = []
    private var lastRead: [UInt8] = []
    private var reading = false
    private var paused = false
    private(set) public var framesSeen = 0
    private(set) public var framesRead = 0

    public func start(id: UUID, epoch: Double) {
        queue.sync {
            self.session = id
            self.epoch = epoch
            self.lastRead = []
            self.paused = false
            self.framesSeen = 0
            self.framesRead = 0
            // Asked once per recording: the list does not change while a call runs, and the query
            // itself builds a request.
            self.languages = ScreenReader.languages()
            if self.languages.isEmpty {
                Self.logger.warning("Text recognition has no language this Mac supports; screen text will not be read")
            }
        }
    }
    public func pause(_ value: Bool) { queue.sync { self.paused = value } }
    public func stop() { queue.sync { self.session = nil } }

    /// What was read, assembled into moments. Called after the recording stops.
    public static func moments(_ id: UUID, until end: Double) -> [ScreenMoment] {
        ScreenContext.moments(ScreenFiles.samples(id), until: end)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let id = session, !paused, !reading else { return }
        // A frame the system marked incomplete has nothing new on it.
        guard Self.isComplete(sampleBuffer), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framesSeen += 1
        let signature = ScreenReader.signature(from: buffer)
        guard ScreenContext.changed(signature, from: lastRead) else { return }
        reading = true
        defer { reading = false }
        lastRead = signature
        framesRead += 1
        let lines = languages.isEmpty ? [] : ScreenReader.read(buffer, languages: languages)
        guard !lines.isEmpty else { return }
        let window = ScreenReader.frontmostWindow()
        let sample = ScreenSample(time: max(0, ProcessInfo.processInfo.systemUptime - epoch),
                                  app: window.app, window: window.window, lines: lines)
        do { try ScreenFiles.append(sample, id: id) }
        catch { Self.logger.error("Screen journal write failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// ScreenCaptureKit marks frames that carry no new content; reading those wastes the budget.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else { return true }
        return status == .complete
    }
}
