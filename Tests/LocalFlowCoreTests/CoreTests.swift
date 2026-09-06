import XCTest
import LocalFlowCore

final class CoreTests: XCTestCase {
    func testOverlappingWindowsOwnBoundaryWordExactlyOnce() {
        let first = [TranscriptSegment(start: 6.7, end: 7.3, text: "граница")]
        let second = [TranscriptSegment(start: 0.7, end: 1.3, text: "граница")]
        let left = TranscriptAssembly.windowWords(first, offset: 0, from: 0, to: 7, source: "microphone")
        let right = TranscriptAssembly.windowWords(second, offset: 6, from: 7, to: 14, source: "microphone")
        XCTAssertTrue(left.isEmpty); XCTAssertEqual(right.map(\.text), ["граница"])
        XCTAssertEqual(right.first?.start ?? 0, 6.7, accuracy: 0.001)
    }

    func testAudioRecoveryUsesWrittenFramesAndPreservesPauseGap() throws {
        let id = UUID(); let root = AppPaths.audio(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AudioFiles.write(Array(repeating: 0.25, count: 16000), url: root.appendingPathComponent("a.caf"))
        try AudioFiles.write(Array(repeating: 0.5, count: 16000), url: root.appendingPathComponent("b.caf"))
        let journal = [AudioPart(file: "a.caf", source: "microphone", start: 0, duration: 0.5), AudioPart(file: "b.caf", source: "microphone", start: 2, duration: 0.5)]
        try JSONEncoder().encode(journal).write(to: root.appendingPathComponent("parts.json"))
        XCTAssertEqual(try AudioFiles.parts(id).map(\.duration), [1, 1])
        let joined = try AudioFiles.joinedTrack(id, source: "microphone")
        let samples = try AudioFiles.read(joined, duration: 3)
        XCTAssertEqual(samples.count, 48000)
        XCTAssertEqual(samples[8000], 0.25, accuracy: 0.001)
        XCTAssertEqual(samples[24000], 0, accuracy: 0.001)
        XCTAssertEqual(samples[40000], 0.5, accuracy: 0.001)
    }
    func testEditAllowsThousandsFormatting() { XCTAssertTrue(TextSafety.validateEdit(original: "Бюджет 250000 рублей.", edited: "Бюджет — 250 000 рублей.")) }
    func testEditRejectsWrongDecimal() { XCTAssertFalse(TextSafety.validateEdit(original: "Цена 0,03 доллара", edited: "Цена 0,3 доллара")) }
    func testEditRejectsChangedNumbers() { XCTAssertFalse(TextSafety.validateEdit(original: "Бюджет 250000 рублей, срок 15 дней.", edited: "Бюджет 25000 рублей, срок 15 дней.")) }
    func testEditRejectsMissingNegation() { XCTAssertFalse(TextSafety.validateEdit(original: "Мы не запускаем рекламу.", edited: "Мы запускаем рекламу.")) }
    func testEditAllowsGrammarAndFillers() { XCTAssertTrue(TextSafety.validateEdit(original: "Эээ, мы, ну, не запускаем рекламу, бюджет 5000.", edited: "Мы не запускаем рекламу. Бюджет 5000.")) }
    func testDictionaryUsesBoundariesAndLiteralReplacement() {
        let entries = [DictionaryEntry(heard: "кот", preferred: "$1\\test")]
        XCTAssertEqual(TextSafety.applyDictionary("кот котик КОТ", entries: entries), "$1\\test котик $1\\test")
    }
    func testLongChunkingDoesNotDropWords() {
        let words = (0..<5000).map { "слово\($0)" }
        let chunks = TextSafety.chunks(words.joined(separator: " "), maxCharacters: 300)
        XCTAssertEqual(chunks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }, words)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 301 })
    }
    func testEmptyChunking() { XCTAssertEqual(TextSafety.chunks(" \n"), []) }
    func testHypothesisRevisesTail() {
        var h = LiveHypothesis(); h.update("Нужно купить пять больших окон"); h.update("Нужно купить шесть больших окон")
        XCTAssertEqual(h.stable, "Нужно купить"); XCTAssertEqual(h.draft, "шесть больших окон")
    }
    func testHypothesisDoesNotDuplicateOnRepeatedUpdate() {
        var h = LiveHypothesis(); for _ in 0..<20 { h.update("Сделать большой новый проект") }
        XCTAssertEqual([h.stable,h.draft].joined(separator: " "), "Сделать большой новый проект")
    }
    func testUnknownVoiceIsNotAssigned() {
        XCTAssertNil(TextSafety.matchVoice([1,0], profiles: [VoiceProfile(name: "A", embedding: [0,1])]))
    }
    func testAmbiguousVoiceIsNotAssigned() {
        XCTAssertNil(TextSafety.matchVoice([1,0], profiles: [VoiceProfile(name: "A", embedding: [1,0]), VoiceProfile(name: "B", embedding: [0.99,0.01])]))
    }
    func testKnownVoiceMatched() { XCTAssertEqual(TextSafety.matchVoice([1,0], profiles: [VoiceProfile(name: "A", embedding: [1,0])]), "A") }
    func testZeroEmbedding() { XCTAssertEqual(TextSafety.cosine([0,0],[0,0]), 0) }
    func testGroupingKeepsSpeakerChanges() {
        let words = [TranscriptSegment(start: 0, end: 0.5, text: "Привет", speaker: "A"), TranscriptSegment(start: 0.5, end: 1, text: "всем.", speaker: "A"), TranscriptSegment(start: 1, end: 2, text: "Здравствуйте", speaker: "B")]
        let result = TranscriptAssembly.group(words); XCTAssertEqual(result.count,2); XCTAssertEqual(result[0].text,"Привет всем."); XCTAssertEqual(result[1].speaker,"B")
    }
    func testArchiveTransactionsAndSearchDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(url: root.appendingPathComponent("test.sqlite"))
        var session = RecordingSession(kind: .note); session.title = "Проверка проекта"; session.segments = [.init(start: 0, end: 5, text: "Согласовали бюджет LocalFlow 250000")]
        try store.save(session)
        XCTAssertEqual(try store.search("бюджет").count, 1)
        session.segments = [.init(start: 0, end: 5, text: "Обсудили дизайн")]; try store.save(session)
        XCTAssertEqual(try store.search("бюджет").count, 0)
        XCTAssertEqual(try store.search("дизайн").count, 1)
        try store.delete(session.id); XCTAssertEqual(try store.search("дизайн").count, 0)
        XCTAssertTrue(try store.sessions().isEmpty)
    }
    func testSearchPunctuationIsData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(url: root.appendingPathComponent("test.sqlite"))
        XCTAssertNoThrow(try store.search("\" OR * : ) NOT бюджет"))
    }
    func testStoreRoundtripPreservesVersionsAndManualNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(url: root.appendingPathComponent("test.sqlite"))
        var s = RecordingSession(kind: .meeting); s.speakers = ["speaker_1":"Макс"]; s.versions = [.init(mode: .summary, text:"Решили тестировать")]; s.pinned = true
        try store.save(s); let restored = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(restored.speakers,s.speakers); XCTAssertEqual(restored.versions.first?.text,s.versions.first?.text); XCTAssertTrue(restored.pinned)
    }
    func testModelManifestIsPinnedAndChecksummed() {
        XCTAssertEqual(ModelCatalog.packages.count,4)
        for package in ModelCatalog.packages {
            XCTAssertEqual(package.revision.count,40); XCTAssertFalse(package.files.isEmpty)
            for asset in package.files { XCTAssertGreaterThan(asset.size,0); XCTAssertEqual(asset.hash.count,asset.sha256 ? 64 : 40); XCTAssertFalse(asset.path.contains("..")) }
        }
    }
}
