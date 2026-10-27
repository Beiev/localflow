import XCTest
@testable import LocalFlowCore

final class SpeakerIdentityTests: XCTestCase {
    private func spans(_ values: [(String, Double, Double)]) -> [SpeakerSpan] {
        values.map { SpeakerSpan(start: $0.1, end: $0.2, speaker: $0.0) }
    }

    /// The shape of the owner's 45-minute two-person call: one voice holding 97 % of the remote
    /// speech and two fragments of itself holding 1 % and 0 %.
    func testFragmentsOfOneVoiceFoldIntoIt() {
        let call = spans([("S1", 0, 600), ("S2", 601, 611), ("S1", 612, 1400), ("S3", 1401, 1403)])
        XCTAssertEqual(TextSafety.minorIdentities(call), ["S2", "S3"])
        XCTAssertEqual(Set(TextSafety.foldMinorIdentities(call).map(\.speaker)), ["S1"])
    }
    /// Fragments go to the voice beside them in time, not to the loudest one overall.
    func testFragmentTakesTheNeighbouringVoice() {
        let call = spans([("A", 0, 300), ("minor", 301, 310), ("B", 311, 700), ("B", 800, 1200)])
        let folded = TextSafety.foldMinorIdentities(call)
        XCTAssertEqual(folded.first { $0.start == 301 }?.speaker, "A")
    }
    /// A quiet but real participant in a long call: 3 % of a 92-minute nine-person meeting, two
    /// minutes of speech. Dropping them would be worse than the problem being fixed.
    func testQuietParticipantWithRealSpeechSurvives() {
        var call = spans([("quiet", 0, 122)])
        for index in 0..<8 { call += spans([("loud\(index)", Double(200 + index * 500), Double(650 + index * 500))]) }
        XCTAssertFalse(TextSafety.minorIdentities(call).contains("quiet"))
        XCTAssertEqual(Set(TextSafety.foldMinorIdentities(call).map(\.speaker)).count, 9)
    }
    /// Both floors must be met: a large share of a short conversation is still the conversation.
    func testShortCallWithTwoBalancedVoicesIsNotFolded()  {
        let call = spans([("S1", 0, 20), ("S2", 21, 41)])
        XCTAssertTrue(TextSafety.minorIdentities(call).isEmpty)
        XCTAssertEqual(TextSafety.foldMinorIdentities(call).count, 2)
    }
    /// Nothing to fold into: everything would disappear, so nothing moves.
    func testAllIdentitiesMinorLeavesThemAlone() {
        let call = spans([("S1", 0, 2), ("S2", 3, 5), ("S3", 6, 8)])
        XCTAssertTrue(TextSafety.minorIdentities(call).isEmpty)
        XCTAssertEqual(TextSafety.foldMinorIdentities(call).count, 3)
    }
    func testSingleIdentityIsNeverMinor() {
        XCTAssertTrue(TextSafety.minorIdentities(spans([("S1", 0, 3)])).isEmpty)
    }
    func testSpeechTimeSumsEveryTurnOfAnIdentity() {
        let time = TextSafety.speechTime(spans([("S1", 0, 10), ("S2", 10, 15), ("S1", 20, 30)]))
        XCTAssertEqual(time["S1"], 20)
        XCTAssertEqual(time["S2"], 5)
    }

    // MARK: - Line-preserving chunking and the transcript guard

    func testLineChunksNeverSplitALine() {
        let transcript = (0..<40).map { "[0\($0 % 10):00] Я: " + String(repeating: "слово ", count: 30) }.joined(separator: "\n")
        let chunks = TextSafety.lineChunks(transcript, maxCharacters: 1000)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            for line in chunk.components(separatedBy: .newlines) where !line.isEmpty {
                XCTAssertTrue(line.hasPrefix("["), "a line was cut in half: \(line.prefix(30))")
            }
        }
        XCTAssertEqual(chunks.joined(separator: "\n"), transcript)
    }
    func testTurnPrefixesReadTimestampAndSpeaker() {
        XCTAssertEqual(TextSafety.turnPrefixes("[04:41] Лена: Он не отказался.\n[87:36] Я: Да."),
                       ["04:41|лена", "87:36|я"])
        XCTAssertTrue(TextSafety.turnPrefixes("Просто текст без отметок").isEmpty)
    }
    func testKeepsTurnsAcceptsACleanupAndRejectsLostOrMergedTurns() {
        let original = "[00:10] Я: ээ ну то есть да\n[00:20] Лена: Ага ага"
        XCTAssertTrue(TextSafety.keepsTurns(original: original, edited: "[00:10] Я: То есть да.\n[00:20] Лена: Ага."))
        XCTAssertFalse(TextSafety.keepsTurns(original: original, edited: "[00:10] Я: То есть да. Ага."))
        XCTAssertFalse(TextSafety.keepsTurns(original: original, edited: "[00:20] Лена: Ага.\n[00:10] Я: То есть да."))
        XCTAssertFalse(TextSafety.keepsTurns(original: original, edited: "Я: То есть да.\nЛена: Ага."))
        XCTAssertFalse(TextSafety.keepsTurns(original: original, edited: ""))
    }
    func testKeepsTurnsRejectsARenamedSpeaker() {
        XCTAssertFalse(TextSafety.keepsTurns(original: "[00:10] Я: Да", edited: "[00:10] Лена: Да"))
    }
}
