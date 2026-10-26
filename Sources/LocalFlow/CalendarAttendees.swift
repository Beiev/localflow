import EventKit
import Foundation
import LocalFlowCore

/// Who the calendar says was supposed to be on a call.
///
/// Asked for only when the owner asks for it: the permission prompt belongs to a button press, not
/// to launching the application. Nothing is read without that, and nothing is written ever.
enum CalendarAttendees {
    /// A recording rarely starts exactly on the hour, and people join late.
    static let slack: TimeInterval = 15 * 60

    static func names(around date: Date, duration: TimeInterval, owner: String?) async -> [String] {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return [] }
        let from = date.addingTimeInterval(-slack)
        let to = date.addingTimeInterval(max(duration, 0) + slack)
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        // The meeting this recording belongs to is the one it overlaps most.
        let best = events.max { left, right in overlap(left, from: date, duration: duration) < overlap(right, from: date, duration: duration) }
        guard let best, overlap(best, from: date, duration: duration) > 0 else { return [] }
        var people: [CalendarNaming.Attendee] = []
        if let organiser = best.organizer { people.append(attendee(organiser)) }
        people += (best.attendees ?? []).map(attendee)
        return CalendarNaming.candidates(from: people, excluding: owner)
    }

    private static func attendee(_ participant: EKParticipant) -> CalendarNaming.Attendee {
        CalendarNaming.Attendee(name: participant.name, address: participant.url.absoluteString)
    }
    private static func overlap(_ event: EKEvent, from: Date, duration: TimeInterval) -> TimeInterval {
        guard let start = event.startDate, let end = event.endDate else { return 0 }
        let recordingEnd = from.addingTimeInterval(max(duration, 60))
        return max(0, min(end, recordingEnd).timeIntervalSince(max(start, from)))
    }
}
