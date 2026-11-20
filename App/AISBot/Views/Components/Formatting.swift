import Foundation

/// Datums- und Geldformate in der Sprache der App (`Locale.app`). Deutsch bleibt Zeichen für Zeichen wie vor 1.3
/// („Heute 10:05“, „Mo., 9. Nov. 10:05“); Englisch nimmt die üblichen Formate („Today 10:05 AM“, „Nov 9 10:05 AM“).
enum Formatting {
    static var locale: Locale { .app }

    /// „Heute 10:05“, „Gestern 18:20“, „Mo., 9. Nov. 10:05“
    static func dayTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = time(date)
        if cal.isDateInToday(date) { return String(localized: "Heute \(time)", comment: "Zeitpunkt heute, z. B. „Heute 10:05“") }
        if cal.isDateInYesterday(date) {
            return String(localized: "Gestern \(time)", comment: "Zeitpunkt gestern, z. B. „Gestern 18:20“")
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.wide).locale(locale)) + " \(time)"
        }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            : date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        return "\(day) \(time)"
    }

    /// Uhrzeit: „09:05“ (Deutsch), „9:05 AM“ (Englisch, je nach Region auch 24 Stunden)
    static func time(_ date: Date) -> String {
        if AppLanguage.isGerman {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        }
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(2)))
    }

    /// „12 s“, „1 min 4 s“ (Englisch „12s“, „1m 4s“)
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return String(localized: "\(s) s", comment: "Dauer in Sekunden (kurz)") }
        let m = s / 60, r = s % 60
        if m < 60 {
            return r == 0 ? String(localized: "\(m) min", comment: "Dauer in Minuten (kurz)")
                : String(localized: "\(m) min \(r) s", comment: "Dauer in Minuten und Sekunden (kurz)")
        }
        return String(localized: "\(m / 60) h \(m % 60) min", comment: "Dauer in Stunden und Minuten (kurz)")
    }
}
