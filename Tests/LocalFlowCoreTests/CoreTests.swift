import XCTest
import LocalFlowCore

final class CoreTests: XCTestCase {
    func testCorrectionCannotBecomeDifferentNumericRelationship() {
        let source = "Отправить нужно 15 файлов, точнее 12, остальные пока не готовы."
        XCTAssertFalse(TextSafety.validateEdit(original: source, edited: "Нужно подготовить 15 файлов, однако 12 из них уже готовы, остальные — пока нет."))
        XCTAssertTrue(TextSafety.validateEdit(original: source, edited: "Нужно отправить 15 файлов, вернее 12. Остальные пока не готовы."))
    }
    func testRejectedEditStillProducesDeliverableTextWithoutChangingFacts() {
        let original = "Эээ, бюджет 250000 рублей, данные не отправляем. " + String(repeating: "Это длинная диктовка. ", count: 80)
        let proposal = "Бюджет 250 рублей. Данные отправляем."
        let review = TextSafety.reviewEdit(original: original, edited: proposal, mode: .compose)
        XCTAssertTrue(review.requiresReview)
        XCTAssertEqual(review.text, proposal)
        let delivered = TextSafety.deliveryText(original: original, edited: review.text, requiresReview: review.requiresReview, dictionary: [])
        XCTAssertTrue(delivered.contains("250000"))
        XCTAssertTrue(delivered.contains("не отправляем"))
        XCTAssertTrue(delivered.hasSuffix("Это длинная диктовка."))
        XCTAssertFalse(delivered.contains("Эээ"))
        XCTAssertEqual(TextSafety.deliveryText(original: original, edited: nil, requiresReview: false, dictionary: []), delivered)
    }
    func testMeetingShortcutIsDistinctFromDictation() {
        XCTAssertTrue(ShortcutChord.isMeeting(keyCode: 46, flags: (1 << 20) | (1 << 17) | 0x8))
        XCTAssertFalse(ShortcutChord.isMeeting(keyCode: 46, flags: (1 << 20) | 0x8))
        XCTAssertFalse(ShortcutChord.isLeftCommandB(keyCode: 11, flags: (1 << 20) | (1 << 17) | 0x8))
    }
    func testDraftNoteStartsWithoutRecordingAndKeepsDescription() throws {
        let note = RecordingSession.draftNote()
        XCTAssertEqual(note.state, "draft")
        XCTAssertTrue(note.segments.isEmpty)
        XCTAssertEqual(note.duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.audio(note.id).path))
        var described = note; described.noteDescription = "Идеи дневника"; described.editingMode = .compose
        let restored = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(described))
        XCTAssertEqual(restored.noteDescription, described.noteDescription)
        XCTAssertEqual(restored.editingMode, .compose)
        let legacy = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(note))
        XCTAssertNil(legacy.editingMode)
        XCTAssertNil(legacy.noteDescription)
    }
    func testSuspiciousEditRemainsAReviewableProposal() {
        let original = "Бюджет 5000 рублей. Мы не запускаем рекламу."
        let proposed = "Бюджет 500 рублей. Мы запускаем рекламу."
        for mode: ProcessingMode in [.clean, .compose] {
            let result = TextSafety.reviewEdit(original: original, edited: proposed, mode: mode)
            XCTAssertEqual(result.text, proposed)
            XCTAssertTrue(result.requiresReview)
        }
        let safe = TextSafety.reviewEdit(original: "Эээ, бюджет 5000.", edited: "Бюджет 5000.", mode: .clean)
        XCTAssertFalse(safe.requiresReview)
        let empty = TextSafety.reviewEdit(original: original, edited: " ", mode: .clean)
        XCTAssertEqual(empty.text, original); XCTAssertTrue(empty.requiresReview)
    }
    func testCorruptArchiveReturnsErrorWithoutReplacingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let original = Data("not a SQLite database".utf8); try original.write(to: url)
        XCTAssertThrowsError(try Store(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testRetentionKeepsPinnedAndQueuedAudioAndAllText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(url: root.appendingPathComponent("archive.sqlite"))
        var expired = RecordingSession(kind: .note); expired.createdAt = Date().addingTimeInterval(-31 * 86400); expired.state = "ready"
        var pinned = RecordingSession(kind: .note); pinned.createdAt = expired.createdAt; pinned.state = "ready"; pinned.pinned = true
        var queued = RecordingSession(kind: .note); queued.createdAt = expired.createdAt; queued.state = "queued"
        let sessions = [expired, pinned, queued]
        defer { for session in sessions { try? FileManager.default.removeItem(at: AppPaths.audio(session.id)) }; try? FileManager.default.removeItem(at: root) }
        for session in sessions { try store.save(session); try FileManager.default.createDirectory(at: AppPaths.audio(session.id), withIntermediateDirectories: true) }
        try store.pruneAudio()
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.audio(expired.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.audio(pinned.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.audio(queued.id).path))
        XCTAssertEqual(try store.sessions().count, 3)
    }
    func testAnswersRequireExistingSourcesAndTimestamps() {
        let evidence = "[1] Заметка\n[00:12] Бюджет 5000\n[2] Созвон\n[01:03] Решили проверить"
        XCTAssertTrue(TextSafety.hasValidCitations("Бюджет 5000 [1] [00:12]", evidence: evidence))
        XCTAssertFalse(TextSafety.hasValidCitations("Бюджет 5000 [3]", evidence: evidence))
        XCTAssertFalse(TextSafety.hasValidCitations("Бюджет 5000 [1] [02:00]", evidence: evidence))
        XCTAssertFalse(TextSafety.hasValidCitations("Бюджет 5000", evidence: evidence))
    }
    func testShortcutUsesLeftCommandFromEvent() {
        XCTAssertTrue(ShortcutChord.isLeftCommandB(keyCode: 11, flags: (1 << 20) | 0x8))
        XCTAssertFalse(ShortcutChord.isLeftCommandB(keyCode: 11, flags: (1 << 20) | 0x10))
        XCTAssertFalse(ShortcutChord.isLeftCommandB(keyCode: 11, flags: 0x8))
        XCTAssertFalse(ShortcutChord.isLeftCommandB(keyCode: 8, flags: (1 << 20) | 0x8))
        for modifier: UInt64 in [1 << 17, 1 << 18, 1 << 19] {
            XCTAssertFalse(ShortcutChord.isLeftCommandB(keyCode: 11, flags: (1 << 20) | 0x8 | modifier))
        }
    }

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
