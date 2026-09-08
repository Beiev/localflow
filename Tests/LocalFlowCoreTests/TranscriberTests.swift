import XCTest
import LocalFlowCore

private actor FixtureRecognizer: SpeechRecognizing {
    private var calls = 0
    private let interruptOnCall: Int?
    var words = [TranscriptSegment(start: 0.2, end: 0.5, text: "первое"), TranscriptSegment(start: 9.8, end: 10.2, text: "граница"), TranscriptSegment(start: 29.7, end: 29.9, text: "последнее")]
    init(interruptOnCall: Int? = nil, words: [TranscriptSegment]? = nil) { self.interruptOnCall = interruptOnCall; if let words { self.words = words } }
    func recognize(_ samples: [Float]) async throws -> SpeechRecognition {
        calls += 1
        if calls == interruptOnCall { throw CancellationError() }
        let offset = Double(samples.first ?? 0)
        let end = offset + Double(samples.count) / 16000
        let result = words.filter { $0.start >= offset && $0.end <= end }.map { value in
            var word = value; word.start -= offset; word.end -= offset; return word
        }
        return SpeechRecognition(text: result.map(\.text).joined(separator: " "), words: result)
    }
    func callCount() -> Int { calls }
}

final class TranscriberTests: XCTestCase {
    private func fixture() throws -> (RecordingSession, Store) {
        let session = RecordingSession(kind: .note)
        let root = AppPaths.audio(session.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let samples = (0..<480000).map { Float($0)/16000 }
        try AudioFiles.write(samples, url: root.appendingPathComponent("fixture.caf"))
        let parts = [AudioPart(file: "fixture.caf", source: "microphone", start: 0, duration: 30)]
        try JSONEncoder().encode(parts).write(to: root.appendingPathComponent("parts.json"))
        let store = try Store(url: root.appendingPathComponent("test.sqlite")); try store.save(session)
        return (session, store)
    }
    func testSevenMinuteDictationAcrossPartsRetainsEveryBoundaryAndTail() async throws {
        let session = RecordingSession(kind: .dictation)
        let root = AppPaths.audio(session.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var parts: [AudioPart] = []
        for part in 0..<14 {
            let start = Double(part * 30)
            let file = "part-\(part).caf"
            try AudioFiles.write((0..<480000).map { Float(start + Double($0) / 16000) }, url: root.appendingPathComponent(file))
            parts.append(AudioPart(file: file, source: "microphone", start: start, duration: 30))
        }
        try JSONEncoder().encode(parts).write(to: root.appendingPathComponent("parts.json"))
        let store = try Store(url: root.appendingPathComponent("test.sqlite"))
        let words = (1...41).map { TranscriptSegment(start: Double($0 * 10) - 0.2, end: Double($0 * 10) + 0.2, text: "граница-\($0)") } + [TranscriptSegment(start: 419.7, end: 419.9, text: "последнее")]
        let result = try await SessionTranscriber(recognizer: FixtureRecognizer(words: words), store: store).transcribe(session)
        XCTAssertEqual(result.segments.map(\.text), words.map(\.text))
        XCTAssertEqual(result.duration, 420)
        XCTAssertEqual(try store.sessions().first?.segments.last?.text, "последнее")
    }
    func testFinalPassKeepsBoundaryAndLastWordWithoutDuplicates() async throws {
        let (session, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: AppPaths.audio(session.id)) }
        let result = try await SessionTranscriber(recognizer: FixtureRecognizer(), store: store).transcribe(session)
        XCTAssertEqual(result.segments.map(\.text), ["первое", "граница", "последнее"])
        XCTAssertEqual(result.duration, 30)
        XCTAssertEqual(result.transcribedThrough?["microphone"], 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.audio(session.id).appendingPathComponent("microphone-analysis.caf").path))
    }
    func testInterruptedPassResumesFromPersistedCheckpoint() async throws {
        let (session, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: AppPaths.audio(session.id)) }
        do {
            _ = try await SessionTranscriber(recognizer: FixtureRecognizer(interruptOnCall: 2), store: store).transcribe(session)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let saved = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(saved.transcribedThrough?["microphone"], 10)
        XCTAssertEqual(saved.segments.map(\.text), ["первое"])
        let recognizer = FixtureRecognizer()
        let result = try await SessionTranscriber(recognizer: recognizer, store: store).transcribe(saved)
        let calls = await recognizer.callCount()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.segments.map(\.text), ["первое", "граница", "последнее"])
    }
}
