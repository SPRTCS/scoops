import Foundation

/// Deutsche Datums- und Geldformate.
enum Formatting {
    static let locale = Locale(identifier: "de_DE")

    /// „Heute 10:05“, „Gestern 18:20“, „Mo., 9. Nov. 10:05“
    static func dayTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        if cal.isDateInToday(date) { return "Heute \(time)" }
        if cal.isDateInYesterday(date) { return "Gestern \(time)" }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.wide).locale(locale)) + " \(time)"
        }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            : date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        return "\(day) \(time)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(2)))
    }

    /// „12 s“, „1 min 4 s“
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r == 0 ? "\(m) min" : "\(m) min \(r) s" }
        return "\(m / 60) h \(m % 60) min"
    }
}
