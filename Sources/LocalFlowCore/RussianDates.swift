import Foundation

/// Dates, and the rest of the grammar an interface in Russian needs.
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

    /// "1 запись", "2 записи", "5 записей". Russian needs three forms of a counted noun, and an
    /// interface written with one of them is wrong about two thirds of the time: the archive was
    /// labelled "2 записей" and a meeting of five people "5 участника".
    public static func counted(_ number: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(number) " + form(number, one, few, many)
    }
    public static func form(_ number: Int, _ one: String, _ few: String, _ many: String) -> String {
        // Eleven to fourteen take the many-form despite ending in one to four.
        let hundred = abs(number) % 100
        if (11...14).contains(hundred) { return many }
        switch hundred % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
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
