import Foundation

/// A name the recording itself offers for one of its voices, with the moment that says so.
public struct SpeakerNameProposal: Identifiable, Equatable, Sendable {
    /// The identity this name is proposed for; `RecordingSession.ownerIdentity` for the owner.
    public var id: String
    public var name: String
    /// How many times the name was used this way. One mention is a guess; several is a pattern.
    public var mentions: Int
    /// Where to listen, so the proposal can be checked in two seconds instead of trusted.
    public var evidence: TranscriptSegment
    public var reason: Reason
    public enum Reason: String, Equatable, Sendable {
        case addressed, introduced
        public var title: String {
            switch self {
            case .addressed: "так к нему обращаются в записи"
            case .introduced: "так он представился"
            }
        }
    }
    public init(id: String, name: String, mentions: Int, evidence: TranscriptSegment, reason: Reason) {
        self.id = id; self.name = name; self.mentions = mentions; self.evidence = evidence; self.reason = reason
    }
}

/// Turns diarizer labels into the names people actually used. Nothing is applied on its own: the
/// archive has sixteen meetings in which no speaker was ever named through the rename field, so
/// the point is a proposal cheap enough to confirm, not another place to type.
///
/// The whole method rests on one asymmetry: a name spoken as a vocative belongs to somebody else
/// in the room. Two sides addressing each other therefore name each other, while a third party
/// discussed by one side only — a client, a colleague — is named by nobody and stays out.
public enum SpeakerNaming {
    /// A vocative needs this many uses before it is offered, unless it is the only candidate.
    public static let mentionFloor = 2
    /// Shortest believable Russian first name in a vocative.
    private static let nameFloor = 3

    /// `Имя` directly after a comma: "Хорошо, Лена", "Глобально, Паша, давай…". A name *before* a
    /// comma is usually the subject of the sentence — "Пришла Вера, принесла договор" — so a name
    /// in that position is left alone.
    private static let vocativePattern = #"(?<=,)\s*(\p{Lu}\p{Ll}{2,})(?=[\s,.!?…]|$)"#
    /// The one opening that names the speaker rather than the listener. "Это <Имя>" was tried and
    /// dropped: on real calls it names whoever is being discussed as often as the speaker.
    private static let introductionPattern = #"меня зовут\s+(\p{Lu}\p{Ll}{2,})"#

    public static func proposals(for session: RecordingSession) -> [SpeakerNameProposal] {
        let turns = session.segments.sorted { $0.start < $1.start }
        // Turns the diarizer could not attribute carry no identity. They are still speech, but
        // they cannot say who addressed whom, and counting them as a third voice is what stopped
        // this from proposing anything on a two-person call.
        let identities = Set(turns.compactMap { identity(of: $0, in: session) })
        guard identities.count == 2 else { return introductions(turns, in: session, identities: identities) }

        var proposals: [SpeakerNameProposal] = []
        for subject in identities.sorted() {
            // Names used by everyone except this voice: those are the ones aimed at it.
            var counts: [String: (count: Int, first: TranscriptSegment)] = [:]
            for turn in turns where identity(of: turn, in: session).map({ $0 != subject }) == true {
                for name in matches(vocativePattern, in: turn.text) where name.count >= nameFloor {
                    if var existing = counts[name] { existing.count += 1; counts[name] = existing }
                    else { counts[name] = (1, turn) }
                }
            }
            guard let best = counts.max(by: { rank($0.value.count, $0.key) < rank($1.value.count, $1.key) }) else { continue }
            // A single mention is accepted only when nothing competes with it; a client's name
            // dropped once in passing must not win over the name of the person on the call.
            guard best.value.count >= mentionFloor || counts.count == 1 else { continue }
            let runnerUp = counts.filter { $0.key != best.key }.map(\.value.count).max() ?? 0
            guard best.value.count > runnerUp else { continue }
            proposals.append(SpeakerNameProposal(id: subject, name: best.key, mentions: best.value.count,
                                                 evidence: best.value.first, reason: .addressed))
        }
        return proposals + introductions(turns, in: session, identities: identities).filter { introduced in
            !proposals.contains { $0.id == introduced.id }
        }
    }

    /// Self-introductions work at any number of participants, and are the only evidence that names
    /// a voice from its own words.
    private static func introductions(_ turns: [TranscriptSegment], in session: RecordingSession, identities: Set<String>) -> [SpeakerNameProposal] {
        var found: [String: SpeakerNameProposal] = [:]
        for turn in turns {
            guard let speaker = identity(of: turn, in: session), identities.contains(speaker), found[speaker] == nil else { continue }
            guard let name = matches(introductionPattern, in: turn.text).first(where: { $0.count >= nameFloor }) else { continue }
            found[speaker] = SpeakerNameProposal(id: speaker, name: name, mentions: 1, evidence: turn, reason: .introduced)
        }
        return found.values.sorted { $0.id < $1.id }
    }

    /// Longer names break ties, so a full name wins over a one-syllable fragment at equal counts.
    private static func rank(_ count: Int, _ name: String) -> (Int, Int) { (count, name.count) }

    private static func identity(of segment: TranscriptSegment, in session: RecordingSession) -> String? {
        if segment.source == "microphone" { return RecordingSession.ownerIdentity }
        return segment.speaker.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        // Case matters: `\p{Lu}` under .caseInsensitive matches lowercase too, which made every
        // word after a comma a candidate name.
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
