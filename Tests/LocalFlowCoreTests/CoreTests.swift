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
    func testShortcutSpecMatchesExactModifiersAndLeftCommand() {
        XCTAssertTrue(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: ShortcutSpec.command | 0x8))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: ShortcutSpec.command | 0x10))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: ShortcutSpec.command | ShortcutSpec.shift | 0x8))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: ShortcutSpec.command | ShortcutSpec.control | 0x8))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: ShortcutSpec.command | ShortcutSpec.option | 0x8))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 8, rawFlags: ShortcutSpec.command | 0x8))
        XCTAssertFalse(ShortcutSpec.dictationDefault.matches(keyCode: 11, rawFlags: 0x8))
        XCTAssertTrue(ShortcutSpec.meetingDefault.matches(keyCode: 46, rawFlags: ShortcutSpec.command | ShortcutSpec.shift | 0x8))
        XCTAssertFalse(ShortcutSpec.meetingDefault.matches(keyCode: 46, rawFlags: ShortcutSpec.command | 0x8))
        // Shortcuts without ⌘ fire with either physical side of their modifiers.
        let option = ShortcutSpec(keyCode: 3, flags: ShortcutSpec.option)
        XCTAssertTrue(option.matches(keyCode: 3, rawFlags: ShortcutSpec.option))
        XCTAssertTrue(option.matches(keyCode: 3, rawFlags: ShortcutSpec.option | 0x20))
        XCTAssertNotEqual(ShortcutSpec.dictationDefault, ShortcutSpec.meetingDefault)
    }
    func testShortcutSpecLabelsValidationAndStorage() {
        XCTAssertEqual(ShortcutSpec.dictationDefault.label, "⌘B")
        XCTAssertEqual(ShortcutSpec.meetingDefault.label, "⇧⌘M")
        XCTAssertEqual(ShortcutSpec(keyCode: 3, flags: ShortcutSpec.option | ShortcutSpec.shift).label, "⌥⇧F")
        XCTAssertEqual(ShortcutSpec(keyCode: 96, flags: 0).label, "F5")
        XCTAssertEqual(ShortcutSpec(keyCode: 3, flags: ShortcutSpec.control | ShortcutSpec.option | ShortcutSpec.shift | ShortcutSpec.command).label, "⌃⌥⇧⌘F")
        XCTAssertTrue(ShortcutSpec(keyCode: 96, flags: 0).isValidChoice)
        XCTAssertFalse(ShortcutSpec(keyCode: 11, flags: 0).isValidChoice)
        XCTAssertTrue(ShortcutSpec(keyCode: 8, flags: ShortcutSpec.command).isSystemCritical)
        XCTAssertFalse(ShortcutSpec(keyCode: 8, flags: ShortcutSpec.command | ShortcutSpec.shift).isSystemCritical)
        XCTAssertFalse(ShortcutSpec(keyCode: 11, flags: ShortcutSpec.command).isSystemCritical)
        let key = "shortcutSpecTestStorage"
        ShortcutSpec(keyCode: 122, flags: ShortcutSpec.option).save(key: key)
        XCTAssertEqual(ShortcutSpec.load(key: key, default: .dictationDefault), ShortcutSpec(keyCode: 122, flags: ShortcutSpec.option))
        ShortcutSpec.reset(key: key)
        XCTAssertEqual(ShortcutSpec.load(key: key, default: .dictationDefault), .dictationDefault)
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
    func testIdentitiesOfOneVoiceAreMerged() {
        // Shaped after the 9 September recording: two halves of one voice, one distinct voice.
        let database: [String: [Float]] = ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0.9, 0.1, 0]]
        let map = TextSafety.mergeIdentities(database)
        XCTAssertEqual(map["S3"], "S1")
        XCTAssertEqual(map["S1"], "S1")
        XCTAssertEqual(map["S2"], "S2")
    }
    func testDistinctVoicesAreNotMerged() {
        XCTAssertEqual(TextSafety.mergeIdentities(["S1": [1, 0], "S2": [0, 1]]), ["S1": "S1", "S2": "S2"])
    }
    func testMergingIsTransitive() {
        let database: [String: [Float]] = ["A": [1, 0], "B": [0.95, 0.05], "C": [0.9, 0.1]]
        XCTAssertEqual(Set(TextSafety.mergeIdentities(database).values), ["A"])
    }
    func testUncoveredUtteranceTakesTheNearestVoice() {
        let spans = [SpeakerSpan(start: 0, end: 10, speaker: "S1"), SpeakerSpan(start: 14, end: 20, speaker: "S2")]
        XCTAssertEqual(TextSafety.speaker(from: 2, to: 5, in: spans), "S1")
        XCTAssertEqual(TextSafety.speaker(from: 11, to: 12, in: spans), "S1")
        XCTAssertEqual(TextSafety.speaker(from: 13, to: 13.5, in: spans), "S2")
        XCTAssertNil(TextSafety.speaker(from: 40, to: 41, in: spans))
    }
    func testOverlapDecidesBeforeProximity() {
        let spans = [SpeakerSpan(start: 0, end: 10, speaker: "S1"), SpeakerSpan(start: 9, end: 20, speaker: "S2")]
        XCTAssertEqual(TextSafety.speaker(from: 9, to: 13, in: spans), "S2")
    }
    func testGroupingKeepsSpeakerChanges() {
        let words = [TranscriptSegment(start: 0, end: 0.5, text: "Привет", speaker: "A"), TranscriptSegment(start: 0.5, end: 1, text: "всем.", speaker: "A"), TranscriptSegment(start: 1, end: 2, text: "Здравствуйте", speaker: "B")]
        let result = TranscriptAssembly.group(words); XCTAssertEqual(result.count,2); XCTAssertEqual(result[0].text,"Привет всем."); XCTAssertEqual(result[1].speaker,"B")
    }
    func testSentencesOfOneSpeakerBecomeOneTurn() {
        let words = [TranscriptSegment(start: 0, end: 1, text: "Первое предложение.", speaker: "A"),
                     TranscriptSegment(start: 1.1, end: 2, text: "Второе предложение.", speaker: "A"),
                     TranscriptSegment(start: 2.05, end: 3, text: "Третье.", speaker: "A")]
        let result = TranscriptAssembly.group(words)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Первое предложение. Второе предложение. Третье.")
        XCTAssertEqual(result[0].end, 3)
    }
    func testTurnEndsAfterASilence() {
        let gap = TranscriptAssembly.turnGapSeconds
        let words = [TranscriptSegment(start: 0, end: 1, text: "До паузы.", speaker: "A"),
                     TranscriptSegment(start: 1 + gap, end: 2 + gap, text: "После паузы.", speaker: "A")]
        XCTAssertEqual(TranscriptAssembly.group(words).count, 2)
    }
    func testInterleavedTracksDoNotBreakTurnsApart() {
        let words = [TranscriptSegment(start: 0, end: 1, text: "Я говорю.", source: "microphone", speaker: "self"),
                     TranscriptSegment(start: 1.1, end: 1.4, text: "Ага.", source: "system", speaker: "S1"),
                     TranscriptSegment(start: 1.5, end: 2.5, text: "И продолжаю.", source: "microphone", speaker: "self")]
        let result = TranscriptAssembly.group(words)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.text, "Я говорю. И продолжаю.")
        XCTAssertEqual(result.first?.source, "microphone")
        XCTAssertEqual(result.last?.source, "system")
    }
    func testLongMonologueStaysWithinTurnBounds() {
        let sentence = String(repeating: "слово ", count: 20) + "."
        var words: [TranscriptSegment] = []
        var start = 0.0
        while start < 300 { words.append(TranscriptSegment(start: start, end: start + 1.5, text: sentence, speaker: "A")); start += 1.6 }
        let result = TranscriptAssembly.group(words)
        XCTAssertGreaterThan(result.count, 1)
        for turn in result {
            XCTAssertLessThanOrEqual(turn.text.count, TranscriptAssembly.turnCharacterLimit)
            XCTAssertLessThanOrEqual(turn.end - turn.start, TranscriptAssembly.turnDurationSeconds)
        }
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
    func testGroupingIsIdempotentAndMatchesIncrementalBatches() {
        var words: [TranscriptSegment] = []
        for index in 0..<40 {
            let start = Double(index) * 1.3
            let system: Bool = index % 5 == 0
            let text: String = "слово\(index)" + (index % 3 == 0 ? "." : "")
            words.append(TranscriptSegment(start: start, end: start + 1.0, text: text,
                                           source: system ? "system" : "microphone",
                                           speaker: system ? "S1" : "self"))
        }
        let once: [TranscriptSegment] = TranscriptAssembly.group(words)
        let twice: [TranscriptSegment] = TranscriptAssembly.group(once)
        XCTAssertEqual(once.map { $0.text }, twice.map { $0.text })
        // The live path regroups committed turns plus each new batch; that must land on the same
        // turns as the single offline pass, otherwise the archive and the live window disagree.
        var incremental: [TranscriptSegment] = []
        var index = 0
        while index < words.count {
            let batch = Array(words[index..<min(index + 7, words.count)])
            incremental = TranscriptAssembly.group(incremental + batch)
            index += 7
        }
        XCTAssertEqual(incremental.map { $0.text }, once.map { $0.text })
    }
    func testTurnAssemblyKeepsEveryWord() {
        var words: [TranscriptSegment] = []
        for index in 0..<40 {
            let start = Double(index) * 1.1
            let system: Bool = index % 4 == 0
            let text: String = "слово\(index)" + (index % 3 == 0 ? "." : "")
            words.append(TranscriptSegment(start: start, end: start + 0.9, text: text,
                                           source: system ? "system" : "microphone",
                                           speaker: system ? "S1" : "self"))
        }
        let turns: [TranscriptSegment] = TranscriptAssembly.group(words)
        let before: [String] = words.map { $0.text }.joined(separator: " ").split(separator: " ").map(String.init)
        let after: [String] = turns.map { $0.text }.joined(separator: " ").split(separator: " ").map(String.init)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(Set(before), Set(after))
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
