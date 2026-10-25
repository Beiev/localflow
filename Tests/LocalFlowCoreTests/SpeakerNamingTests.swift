import XCTest
@testable import LocalFlowCore

final class SpeakerNamingTests: XCTestCase {
    private func meeting(_ turns: [(String, String?, String)]) -> RecordingSession {
        var session = RecordingSession(kind: .meeting)
        session.segments = turns.enumerated().map { index, turn in
            TranscriptSegment(start: Double(index) * 10, end: Double(index) * 10 + 8,
                              text: turn.2, source: turn.0, speaker: turn.1)
        }
        return session
    }

    /// The real shape of the owner's calls: each side addresses the other by name, so each side
    /// names the other.
    func testTwoSidesAddressingEachOtherNameEachOther() {
        let session = meeting([
            ("system", "S1", "Что я хотел, Паша, короче. Смотри."),
            ("microphone", "Я", "Глобально, Лена, давай по порядку."),
            ("system", "S1", "Короче, Паша, давай так."),
            ("microphone", "Я", "Хорошо, Лена. Давай я продвинусь."),
        ])
        let proposals = SpeakerNaming.proposals(for: session)
        XCTAssertEqual(proposals.first { $0.id == "S1" }?.name, "Лена")
        XCTAssertEqual(proposals.first { $0.id == "Я" }?.name, "Паша")
        XCTAssertEqual(proposals.first { $0.id == "S1" }?.mentions, 2)
        XCTAssertEqual(proposals.allSatisfy { $0.reason == .addressed }, true)
    }
    /// A client discussed by one side only must not become the other side's name.
    func testAThirdPartyMentionedOnceDoesNotWin() {
        let session = meeting([
            ("microphone", "Я", "Вот, например, Егор, который должен был подключиться."),
            ("microphone", "Я", "Это как его там, Тимур, да, по-моему, зовут."),
            ("microphone", "Я", "Глобально, Лена, нам нужен план."),
            ("microphone", "Я", "Хорошо, Лена, давай так."),
            ("system", "S1", "Понял, понял."),
        ])
        XCTAssertEqual(SpeakerNaming.proposals(for: session).first { $0.id == "S1" }?.name, "Лена")
    }
    /// One mention against a competitor is not evidence; one mention alone is offered.
    func testSingleMentionIsOfferedOnlyWithoutCompetition() {
        let lonely = meeting([("microphone", "Я", "Привет, Саша."), ("system", "S1", "Да, слушаю.")])
        XCTAssertEqual(SpeakerNaming.proposals(for: lonely).first { $0.id == "S1" }?.name, "Саша")
        let contested = meeting([
            ("microphone", "Я", "Привет, Саша."),
            ("microphone", "Я", "Передай, Тимур, документы."),
            ("system", "S1", "Да, слушаю."),
        ])
        XCTAssertNil(SpeakerNaming.proposals(for: contested).first { $0.id == "S1" })
    }
    /// A name before a comma is the subject of the sentence, not the person being addressed.
    func testNameBeforeACommaIsNotAVocative() {
        let session = meeting([
            ("microphone", "Я", "Пришла Вера, принесла три договора."),
            ("system", "S1", "Понял."),
        ])
        XCTAssertTrue(SpeakerNaming.proposals(for: session).isEmpty)
    }
    /// Turns the diarizer could not attribute are speech without an identity; they must not count
    /// as another participant, which is what stopped a two-person call from being named at all.
    func testUnattributedTurnsDoNotBlockATwoPersonCall() {
        let session = meeting([
            ("system", nil, "Mm-hmm."),
            ("system", "S1", "Короче, Паша, давай так."),
            ("microphone", "Я", "Хорошо, Лена. Договорились."),
            ("system", "S1", "Понял, Паша."),
        ])
        XCTAssertEqual(SpeakerNaming.proposals(for: session).count, 2)
    }
    /// With three voices a vocative no longer says who it was aimed at.
    func testThreeVoicesProposeNothingFromAddressing() {
        let session = meeting([
            ("system", "S1", "Короче, Паша, давай так."),
            ("system", "S2", "Да, Паша, согласен."),
            ("microphone", "Я", "Хорошо, Лена."),
        ])
        XCTAssertTrue(SpeakerNaming.proposals(for: session).isEmpty)
    }
    /// A self-introduction names its own speaker, and works at any number of voices.
    func testSelfIntroductionNamesTheSpeaker() {
        let session = meeting([
            ("system", "S1", "Здравствуйте, меня зовут Сергей, я из соседнего отдела."),
            ("system", "S2", "А я Антон."),
            ("microphone", "Я", "Приятно познакомиться."),
        ])
        let proposals = SpeakerNaming.proposals(for: session)
        XCTAssertEqual(proposals.first { $0.id == "S1" }?.name, "Сергей")
        XCTAssertEqual(proposals.first { $0.id == "S1" }?.reason, .introduced)
        XCTAssertNil(proposals.first { $0.id == "S2" }, "«А я Антон» без «меня зовут» — слишком частая конструкция")
    }
    /// The owner's own name belongs in the transcript: "Я" reads as nobody once a document leaves.
    func testNamingTheOwnerIdentityRenamesTheMicrophoneTrack() {
        var session = meeting([("microphone", "Я", "Да.")])
        XCTAssertEqual(session.speakerName("Я", source: "microphone"), "Я")
        session.speakers[RecordingSession.ownerIdentity] = "Паша"
        XCTAssertEqual(session.speakerName("Я", source: "microphone"), "Паша")
        XCTAssertEqual(session.ownerName, "Паша")
    }
}
