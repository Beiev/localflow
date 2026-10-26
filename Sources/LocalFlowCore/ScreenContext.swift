import Foundation

/// A stretch of time during which the screen showed the same thing. Moments, not instants: a slide
/// can be on screen for four minutes, and a note that says "at 12:03 this document was shown" is
/// far less useful than one that says it was shown from 12:03 to 12:07.
public struct ScreenMoment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    /// The application in front, when the capture could tell.
    public var app: String?
    /// The window title, which is often the document's own name.
    public var window: String?
    /// Text read off the screen, de-duplicated and trimmed.
    public var text: String
    /// File name of the one still kept for this moment, inside the session's audio directory.
    public var frame: String?
    public init(start: Double, end: Double, app: String? = nil, window: String? = nil, text: String, frame: String? = nil) {
        self.start = start; self.end = end; self.app = app; self.window = window; self.text = text; self.frame = frame
    }
    public var timestamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
    public var duration: Double { max(0, end - start) }
    /// What the moment is called in a list: the window, else the application, else the first words.
    public var title: String {
        if let window, !window.isEmpty { return window }
        if let app, !app.isEmpty { return app }
        return String(text.prefix(60))
    }
}

/// One frame as the capture saw it, before moments are assembled. Persisted without its
/// signature: the thumbnail exists only to decide whether the frame was worth reading.
public struct ScreenSample: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case time, app, window, lines }
    public var time: Double
    public var app: String?
    public var window: String?
    public var lines: [String]
    /// A coarse greyscale thumbnail of the frame, row-major. Used only to tell whether the screen
    /// changed enough to be worth reading, and therefore never persisted.
    public var signature: [UInt8] = []
    public init(time: Double, app: String? = nil, window: String? = nil, lines: [String], signature: [UInt8] = []) {
        self.time = time; self.app = app; self.window = window; self.lines = lines; self.signature = signature
    }
}

/// Turning a stream of frames into something worth attaching to a meeting. Everything here is
/// deterministic and free of ScreenCaptureKit and Vision, so the policy can be tested without a
/// screen: what counts as a change, what text is worth keeping, and where one moment ends.
public enum ScreenContext {
    /// Mean absolute difference, per channel step, above which two frames are different pictures.
    /// A cursor moving or a camera tile breathing sits far below this; a new slide sits far above.
    public static let changeThreshold = 6.0
    /// Two readings this similar are the same screen, so the moment continues.
    public static let sameScreenSimilarity = 0.6
    /// A moment never grows past this, so its single timestamp keeps meaning.
    public static let longestMoment: Double = 600
    /// A reading shorter than this is noise: a clock, a badge count, a stray letter.
    public static let shortestReading = 12
    /// Lines of text kept per moment. A dense dashboard can yield hundreds.
    public static let mostLines = 40
    /// Longest text kept per moment, so a wall of text cannot crowd out the transcript later.
    public static let longestText = 1200

    /// Whether a frame differs enough from the last one that was read to be worth reading.
    /// Comparing against the last *read* frame rather than the previous frame matters: a slow
    /// fade would otherwise never cross the threshold on any single step.
    public static func changed(_ next: [UInt8], from previous: [UInt8], threshold: Double = changeThreshold) -> Bool {
        guard !previous.isEmpty else { return true }
        guard next.count == previous.count, !next.isEmpty else { return true }
        var total = 0
        for (a, b) in zip(next, previous) { total += abs(Int(a) - Int(b)) }
        return Double(total) / Double(next.count) > threshold
    }

    /// Readable text from one frame's recognized lines: trimmed, de-duplicated, ordered as read,
    /// and capped. Lines that are pure punctuation or a bare number are dropped — a clock in the
    /// menu bar is not what was being shown.
    public static func reading(_ lines: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            guard value.count >= 3, value.rangeOfCharacter(from: .letters) != nil else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            kept.append(value)
            if kept.count >= mostLines { break }
        }
        let text = kept.joined(separator: "\n")
        guard text.count > longestText else { return text }
        return String(text.prefix(longestText)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Assembles samples into moments. A moment continues while the same window shows text that
    /// reads the same; it ends when the window changes, the text changes, or it has run too long.
    public static func moments(_ samples: [ScreenSample], until endOfRecording: Double? = nil) -> [ScreenMoment] {
        var moments: [ScreenMoment] = []
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            let text = reading(sample.lines)
            guard text.count >= shortestReading else { continue }
            if var open = moments.last, continues(open, with: sample, text: text) {
                open.end = sample.time
                // The longest reading of a screen is the most complete one: a dashboard loads in
                // pieces, and the first frame of it is the emptiest.
                if text.count > open.text.count { open.text = text }
                moments[moments.count - 1] = open
            } else {
                // The screen that was up stayed up until this one replaced it. Only a frame that
                // differs from the last one read is journalled, so a slide left alone produces
                // exactly one sample — and a moment that ended the instant it began was invisible
                // to every stretch of conversation that happened while it was on screen.
                if var previous = moments.last, previous.end < sample.time {
                    previous.end = min(sample.time, previous.start + longestMoment)
                    moments[moments.count - 1] = previous
                }
                moments.append(ScreenMoment(start: sample.time, end: sample.time,
                                            app: sample.app, window: sample.window, text: text))
            }
        }
        // A moment that was still on screen when the recording stopped lasted until then.
        if let endOfRecording, var last = moments.last, last.end < endOfRecording {
            last.end = min(endOfRecording, last.start + longestMoment)
            moments[moments.count - 1] = last
        }
        return moments
    }
    private static func continues(_ moment: ScreenMoment, with sample: ScreenSample, text: String) -> Bool {
        guard sample.time - moment.start < longestMoment else { return false }
        guard moment.window == sample.window, moment.app == sample.app else { return false }
        return similarity(tokens(moment.text), tokens(text)) >= sameScreenSimilarity
    }
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map { String($0.prefix(8)) }.filter { $0.count > 2 })
    }
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let union = a.union(b).count
        return union > 0 ? Double(a.intersection(b).count) / Double(union) : 0
    }

    /// What the screen showed while something was being said, for a condensing stage that may
    /// cite it. Only moments overlapping the turn, and only their titles and text.
    public static func moments(_ moments: [ScreenMoment], overlapping start: Double, to end: Double) -> [ScreenMoment] {
        moments.filter { $0.start <= end && $0.end >= start }
    }
}


/// The screen journal: one line per frame that was read, written as it happens so a crash leaves
/// what was already seen. It lives beside the session's audio and is removed with it.
public enum ScreenFiles {
    public static func journal(_ id: UUID) -> URL { AppPaths.audio(id).appendingPathComponent("screen.jsonl") }

    public static func append(_ sample: ScreenSample, id: UUID) throws {
        let url = journal(id)
        var line = try JSONEncoder().encode(sample)
        line.append(0x0a)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: url, options: .atomic)
        }
    }

    /// Reads the journal, skipping any line a crash left half-written.
    public static func samples(_ id: UUID) -> [ScreenSample] {
        // Decoded leniently: one byte of a multi-byte character lost to a power cut made the
        // strict decoder return nothing at all, throwing away a whole meeting's screen journal
        // rather than the one line it damaged.
        guard let data = try? Data(contentsOf: journal(id)) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        return text.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let row = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ScreenSample.self, from: row)
        }
    }

    public static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: journal(id)) }
}
