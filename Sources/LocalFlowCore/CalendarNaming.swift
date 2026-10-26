import Foundation

/// Turning the people on a calendar invitation into names a transcript can use.
///
/// Speaker names are proposed from the conversation itself — somebody says "Лена, посмотри" and
/// the other side gets a name. That only works once people address each other, which on a first
/// call with somebody they often never do. The invitation knows who was supposed to be there.
///
/// It does not know who spoke, and this never pretends otherwise: what comes back is a list of
/// candidates for the owner to put against a voice, exactly like the proposals from the
/// conversation. Nothing is applied by itself.
public enum CalendarNaming {
    /// Longer than a name; a line this long is a room booking or a note to self.
    public static let longestName = 40
    public static let mostCandidates = 12

    /// One attendee as they appear on an invitation: a display name, or an address when the
    /// organiser never filled one in.
    public static func candidate(from attendee: String) -> String? {
        var value = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("mailto:") { value = String(value.dropFirst(7)) }
        // "Лена Иванова <lena@example.com>" and "lena@example.com" both reduce to a first name.
        if let bracket = value.firstIndex(of: "<") { value = String(value[..<bracket]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        if value.contains("@"), let local = value.split(separator: "@").first {
            // An address is a name only when it reads like one: "lena" yes, "info" or "a1b2" no.
            value = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" })
                .first.map(String.init) ?? String(local)
            guard value.count >= 3, value.rangeOfCharacter(from: .decimalDigits) == nil,
                  !nonPeople.contains(value.lowercased())
            else { return nil }
            value = value.prefix(1).uppercased() + value.dropFirst()
        }
        guard let first = value.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init),
              first.count >= 2, first.count <= longestName,
              first.rangeOfCharacter(from: .letters) != nil,
              first.rangeOfCharacter(from: .decimalDigits) == nil,
              !nonPeople.contains(first.lowercased())
        else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// One person on an invitation. Kept as a pair rather than flattened to a string, because the
    /// same person is usually both: a Cyrillic display name and a Latin address. Flattening them
    /// proposed "Лена" and "Lena" as two different people.
    public struct Attendee: Equatable, Sendable {
        public var name: String?
        public var address: String?
        public init(name: String? = nil, address: String? = nil) {
            self.name = name
            self.address = address
        }
    }

    /// Everyone on the invitation except the owner, in the order the invitation lists them, once
    /// each. The display name wins; the address is read only when there is no display name.
    public static func candidates(from attendees: [Attendee], excluding owner: String? = nil) -> [String] {
        let mine = owner?.trimmingCharacters(in: .whitespaces).lowercased()
        var seen: Set<String> = []
        return attendees.compactMap { attendee in
            attendee.name.flatMap(candidate(from:)) ?? attendee.address.flatMap(candidate(from:))
        }
        .filter { $0.lowercased() != mine && $0 != RecordingSession.ownerIdentity }
        .filter { seen.insert($0.lowercased()).inserted }
        .prefix(mostCandidates)
        .map { $0 }
    }

    /// Mailboxes that are not people.
    static let nonPeople: Set<String> = [
        "info", "hello", "team", "support", "sales", "noreply", "no-reply", "admin", "office",
        "mail", "contact", "hr", "jobs", "billing", "invite", "calendar", "meet", "zoom",
    ]
}
