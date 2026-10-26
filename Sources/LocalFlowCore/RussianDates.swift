import Foundation

/// Dates in the language the rest of the application speaks.
///
/// `Date.formatted` follows the system locale, so on an English Mac a Russian interface was
/// labelling its records "Oct 25, 2026 at 14:37" — next to "Созвон", "Расшифровка" and
/// "Открытые вопросы". The language of an application is a decision it has already made.
public enum RussianDates {
    public static let locale = Locale(identifier: "ru_RU")
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = locale
        return value
    }

    /// "25 октября 2026" — and without the year while it is this one, because a year everybody
    /// knows is noise in a list.
    public static func day(_ date: Date, now: Date = Date()) -> String {
        let format = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return formatted(date, format)
    }
    /// "25 октября, 14:37"
    public static func dayAndTime(_ date: Date, now: Date = Date()) -> String {
        day(date, now: now) + ", " + formatted(date, "HH:mm")
    }
    public static func time(_ date: Date) -> String { formatted(date, "HH:mm") }

    /// What a list of days calls each of them: the two nearest by name, the rest by date.
    public static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Вчера" }
        return day(date, now: now)
    }

    /// Minutes and seconds, or hours when there are any: a two-hour call read "127:14".
    public static func length(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let hours = whole / 3600
        guard hours > 0 else { return String(format: "%d:%02d", whole / 60, whole % 60) }
        return String(format: "%d:%02d:%02d", hours, (whole % 3600) / 60, whole % 60)
    }

    private static func formatted(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
