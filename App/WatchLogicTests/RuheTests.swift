import Foundation
import Testing

/// Stummschalten und Ruhezeiten (Shared/Models/Ruhe.swift, docs/ruhe.md). Die Ruhezeit rechnet wie der Server
/// (`ruhe.quiet_at`); die Fälle hier entsprechen Server/tests/test_ruhe.py.
@Suite("Ruhezeiten und Stummschalten")
struct RuheTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, zone: String = "Europe/Berlin") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let weekdays = QuietHours(enabled: true, start: "22:00", end: "07:00", days: [1, 2, 3, 4, 5], approvals: true,
                                      timezone: "Europe/Berlin")

    @Test("Über Mitternacht: gehört zu dem Tag, an dem die Ruhezeit beginnt")
    func overnight() {
        #expect(weekdays.contains(date(2026, 11, 16, 22, 0)))    // Montag 22:00
        #expect(weekdays.contains(date(2026, 11, 17, 6, 59)))    // Dienstag früh, gehört zum Montag
        #expect(!weekdays.contains(date(2026, 11, 17, 7, 0)))
        #expect(!weekdays.contains(date(2026, 11, 16, 21, 59)))
        #expect(weekdays.contains(date(2026, 11, 21, 3, 0)))     // Samstag früh: Ruhezeit vom Freitag
        #expect(!weekdays.contains(date(2026, 11, 21, 23, 0)))   // Samstag nicht gewählt
        #expect(!weekdays.contains(date(2026, 11, 23, 3, 0)))    // Montag früh: Sonntag nicht gewählt
    }

    @Test("Am Tag, ganztägig und ausgeschaltet")
    func daytime() {
        var day = weekdays
        day.start = "13:00"; day.end = "15:00"
        #expect(day.contains(date(2026, 11, 16, 14, 0)))
        #expect(!day.contains(date(2026, 11, 16, 15, 0)))
        #expect(!day.contains(date(2026, 11, 21, 14, 0)))
        var whole = weekdays
        whole.start = "08:00"; whole.end = "08:00"; whole.days = [1]
        #expect(whole.contains(date(2026, 11, 16, 12, 0)))
        #expect(!whole.contains(date(2026, 11, 17, 12, 0)))
        var off = weekdays
        off.enabled = false
        #expect(!off.contains(date(2026, 11, 16, 23, 0)))
    }

    @Test("Zeitzone der Person und Sommerzeit")
    func zones() {
        var ny = weekdays
        ny.timezone = "America/New_York"; ny.days = [1, 2, 3, 4, 5, 6, 7]
        #expect(ny.contains(date(2026, 11, 17, 5, 0)))     // 05:00 Berlin = 23:00 New York
        #expect(!ny.contains(date(2026, 11, 17, 23, 0)))   // 23:00 Berlin = 17:00 New York
        var all = weekdays
        all.days = [1, 2, 3, 4, 5, 6, 7]
        // 29.03.2026: Umstellung auf Sommerzeit. 04:59 UTC = 06:59 MESZ, 05:00 UTC = 07:00 MESZ
        #expect(all.contains(date(2026, 3, 29, 4, 59, zone: "UTC")))
        #expect(!all.contains(date(2026, 3, 29, 5, 0, zone: "UTC")))
    }

    @Test("Antwort des Servers und Kurzfassung")
    func decoding() throws {
        let json = #"{"enabled": true, "start": "21:30", "end": "06:00", "days": [6, 7], "approvals": false, "timezone": "Europe/Berlin", "active": false}"#
        let q = try JSONCoding.makeDecoder().decode(QuietHours.self, from: Data(json.utf8))
        #expect(q.enabled && q.start == "21:30" && q.days == [6, 7] && !q.approvals)
        #expect(q.summary == "21:30–06:00 · Sa, So")
        #expect(QuietHours.daysText([1, 2, 3, 4, 5]) == "Mo–Fr" && QuietHours.daysText([1, 2, 3, 4, 5, 6, 7]) == "täglich")
        #expect(QuietHours.minutes("07:05") == 425 && QuietHours.minutes("24:00") == nil && QuietHours.hhmm(425) == "07:05")
        // Ältere bzw. unvollständige Antworten bekommen die Standardwerte
        let empty = try JSONCoding.makeDecoder().decode(QuietHours.self, from: Data("{}".utf8))
        #expect(!empty.enabled && empty.start == "22:00" && empty.end == "07:00" && empty.approvals)
    }

    @Test("Stummschaltung: dauerhaft, befristet, abgelaufen")
    func mute() throws {
        let now = date(2026, 11, 19, 12, 0)
        #expect(ChatMute.forever.isActive(at: now) && !ChatMute.off.isActive(at: now))
        #expect(ChatMute(muted: true, until: now.addingTimeInterval(60)).isActive(at: now))
        #expect(!ChatMute(muted: true, until: now.addingTimeInterval(-1)).isActive(at: now))
        let json = #"{"muted": true, "until": "2026-11-20T06:00:00+00:00"}"#
        let m = try JSONCoding.makeDecoder().decode(ChatMute.self, from: Data(json.utf8))
        #expect(m.muted && m.until == date(2026, 11, 20, 7, 0))
        // Scoop-JSON älterer Server ohne `mute`: Feld fehlt → die App blendet „Stummschalten“ aus
        let bot = try JSONCoding.makeDecoder().decode(Bot.self, from: Data(##"{"id": "b_1", "name": "Mila", "mascot": {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}}"##.utf8))
        #expect(bot.mute == nil && !bot.isMuted)
    }

    @Test("Dauer: 1 Stunde, 8 Stunden, bis morgen früh, dauerhaft")
    func presets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let evening = date(2026, 11, 19, 22, 15)
        #expect(MutePreset.oneHour.until(from: evening, calendar: calendar) == evening.addingTimeInterval(3600))
        #expect(MutePreset.eightHours.until(from: evening, calendar: calendar) == evening.addingTimeInterval(8 * 3600))
        #expect(MutePreset.forever.until(from: evening, calendar: calendar) == nil)
        #expect(MutePreset.untilMorning.until(from: evening, calendar: calendar) == date(2026, 11, 20, 7, 0))
        // Nachts gewählt: derselbe Morgen; kurz vor 7 Uhr: erst der nächste
        #expect(MutePreset.untilMorning.until(from: date(2026, 11, 20, 2, 0), calendar: calendar) == date(2026, 11, 20, 7, 0))
        #expect(MutePreset.untilMorning.until(from: date(2026, 11, 20, 6, 30), calendar: calendar) == date(2026, 11, 21, 7, 0))
    }
}
