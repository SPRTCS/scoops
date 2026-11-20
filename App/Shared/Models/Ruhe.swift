import Foundation

// MARK: - Stummschalten und Ruhezeiten (App 1.3, docs/ruhe.md)

/// Stummschaltung eines Chats für die angemeldete Person (`mute` im Scoop- bzw. Gruppen-JSON).
/// Das Feld fehlt bei älteren Servern; daran erkennt die App, ob der Server stummschalten kann.
nonisolated struct ChatMute: Codable, Hashable, Sendable {
    var muted: Bool
    /// Ende der Stummschaltung; `nil` bei `muted == true` heißt dauerhaft
    var until: Date?

    static let off = ChatMute(muted: false, until: nil)
    static let forever = ChatMute(muted: true, until: nil)

    init(muted: Bool, until: Date? = nil) {
        self.muted = muted
        self.until = until
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        until = try? c.decodeIfPresent(Date.self, forKey: .until)
    }

    /// Gerade stumm? Eine befristete Stummschaltung endet von selbst, auch bevor der Server sie abräumt.
    func isActive(at now: Date = Date()) -> Bool {
        guard muted else { return false }
        if let until { return until > now }
        return true
    }
}

/// Dauer beim Stummschalten (Kontextmenü, Profil).
nonisolated enum MutePreset: String, CaseIterable, Identifiable, Sendable {
    case oneHour, eightHours, untilMorning, forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: String(localized: "1 Stunde")
        case .eightHours: String(localized: "8 Stunden")
        case .untilMorning: String(localized: "Bis morgen früh")
        case .forever: String(localized: "Dauerhaft")
        }
    }

    /// Uhrzeit von „morgen früh“
    static let morningHour = 7

    /// Ende der Stummschaltung (`nil` = dauerhaft). „Bis morgen früh“ ist das nächste 7:00 Uhr in der Zeitzone
    /// des Geräts; liegt das weniger als eine Stunde entfernt (früh am Morgen gewählt), gilt der Tag darauf.
    func until(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .eightHours: return now.addingTimeInterval(8 * 3600)
        case .forever: return nil
        case .untilMorning:
            let morning = DateComponents(hour: Self.morningHour, minute: 0, second: 0)
            guard let next = calendar.nextDate(after: now, matching: morning, matchingPolicy: .nextTime) else {
                return now.addingTimeInterval(12 * 3600)
            }
            if next.timeIntervalSince(now) >= 3600 { return next }
            return calendar.nextDate(after: next, matching: morning, matchingPolicy: .nextTime) ?? next
        }
    }
}

/// Ruhezeit der angemeldeten Person (`GET`/`PATCH /api/settings/quiet-hours`). In der Ruhezeit kommen Mitteilungen
/// still an. Gerechnet wird in `timezone` (Zeitzone des Geräts, auf dem sie eingestellt wurde).
nonisolated struct QuietHours: Codable, Hashable, Sendable {
    var enabled: Bool
    /// „HH:MM“
    var start: String
    var end: String
    /// Wochentage, an denen die Ruhezeit beginnt: 1 = Montag … 7 = Sonntag
    var days: [Int]
    /// „Freigaben trotzdem melden“
    var approvals: Bool
    /// IANA-Kennung, z. B. „Europe/Berlin“
    var timezone: String

    static let standard = QuietHours(enabled: false, start: "22:00", end: "07:00", days: [1, 2, 3, 4, 5, 6, 7],
                                     approvals: true, timezone: TimeZone.current.identifier)

    init(enabled: Bool, start: String, end: String, days: [Int], approvals: Bool, timezone: String) {
        self.enabled = enabled; self.start = start; self.end = end; self.days = days
        self.approvals = approvals; self.timezone = timezone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? "22:00"
        end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? "07:00"
        days = (try? c.decodeIfPresent([Int].self, forKey: .days)) ?? [1, 2, 3, 4, 5, 6, 7]
        approvals = (try? c.decodeIfPresent(Bool.self, forKey: .approvals)) ?? true
        timezone = (try? c.decodeIfPresent(String.self, forKey: .timezone)) ?? TimeZone.current.identifier
    }

    /// Minuten seit Mitternacht aus „HH:MM“ (ungültig → nil)
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return nil }
        return h * 60 + m
    }

    static func hhmm(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// Liegt `date` in der Ruhezeit? Wie auf dem Server (`ruhe.quiet_at`): Wanduhr in `timezone`, eine Ruhezeit über
    /// Mitternacht gehört zu dem Wochentag, an dem sie beginnt; Von = Bis heißt ganzer Tag.
    func contains(_ date: Date = Date()) -> Bool {
        guard enabled, let s = Self.minutes(start), let e = Self.minutes(end) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let m = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // Calendar: 1 = Sonntag … 7 = Samstag → 1 = Montag … 7 = Sonntag
        let today = ((parts.weekday ?? 1) + 5) % 7 + 1
        let yesterday = (today + 5) % 7 + 1
        if s == e { return days.contains(today) }
        if s < e { return m >= s && m < e && days.contains(today) }
        return (m >= s && days.contains(today)) || (m < e && days.contains(yesterday))
    }

    /// Kurzfassung für die Einstellungen: „22:00–07:00 · täglich“
    var summary: String {
        guard enabled else { return String(localized: "Aus", comment: "Ruhezeiten ausgeschaltet") }
        return "\(Self.displayTime(start))–\(Self.displayTime(end)) · \(Self.daysText(days))"
    }

    /// Uhrzeit „HH:MM“ zum Anzeigen: Deutsch unverändert („22:00“), sonst im Format der App-Sprache („10:00 PM“)
    static func displayTime(_ hhmm: String) -> String {
        guard !AppLanguage.isGerman, let m = minutes(hhmm) else { return hhmm }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: m / 60, minute: m % 60))
        else { return hhmm }
        var style = Date.FormatStyle.dateTime.hour().minute().locale(.app)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Kurze Wochentage, Montag zuerst: Deutsch „Mo“ … „So“, sonst aus dem Kalender der App-Sprache („Mon“ …)
    static var dayNames: [String] {
        if AppLanguage.isGerman { return ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .app
        let symbols = calendar.shortStandaloneWeekdaySymbols  // Sonntag zuerst
        guard symbols.count == 7 else { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] }
        return Array(symbols[1...]) + [symbols[0]]
    }

    static func daysText(_ days: [Int]) -> String {
        let set = Set(days.filter { (1...7).contains($0) })
        if set.count == 7 { return String(localized: "täglich", comment: "Ruhezeit an allen Wochentagen") }
        if set.isEmpty { return String(localized: "an keinem Tag", comment: "Ruhezeit an keinem Wochentag") }
        let names = dayNames
        if set == [1, 2, 3, 4, 5] { return "\(names[0])–\(names[4])" }
        return set.sorted().map { names[$0 - 1] }.joined(separator: ", ")
    }
}
