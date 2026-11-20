#if os(iOS)
import AlarmKit
import Foundation
import SwiftUI

/// Wecker und Timer für die Scoops (`apple.alarms.*`, API v1.18) über AlarmKit (iOS 26+).
///
/// AlarmKit liefert zu einem Wecker nur Zeitplan und Zustand, keinen Titel. Titel, Uhrzeit und Wiederholung merkt
/// sich die App deshalb selbst (UserDefaults, Schlüssel `scoopAlarms`) und gleicht sie mit `AlarmManager.alarms` ab.
/// Löschen ist frei: Es sind nur die eigenen Wecker dieser App, nicht die der Uhr-App.
@MainActor
final class AlarmBridge {
    static let shared = AlarmBridge()
    private let manager = AlarmManager.shared
    private let storeKey = "scoopAlarms"

    /// granted | denied | not_determined
    var permission: String {
        switch manager.authorizationState {
        case .authorized: "granted"
        case .denied: "denied"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    func requestAccess() async -> String {
        _ = await Self.authorize()
        return permission
    }

    // AlarmManager ist nicht Sendable: die asynchronen Aufrufe laufen außerhalb des MainActors über `.shared`.
    @concurrent nonisolated private static func authorize() async -> AlarmManager.AuthorizationState {
        (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
    }

    @concurrent nonisolated private static func schedule(id: UUID, schedule: Alarm.Schedule?, duration: TimeInterval?,
                                                        attributes: AlarmAttributes<ScoopAlarmMetadata>) async throws -> Alarm {
        if let duration {
            return try await AlarmManager.shared.schedule(id: id, configuration: .timer(duration: duration, attributes: attributes))
        }
        return try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: schedule, attributes: attributes))
    }

    // MARK: Befehle

    func run(_ command: String, _ p: JSONValue) async throws -> JSONValue {
        guard permission == "granted" else {
            throw AppleBridgeError("AIS Scoops darf auf diesem iPhone keine Wecker stellen. In AIS Scoops unter Apps verbinden → Apple → Wecker erlauben.")
        }
        switch command {
        case "apple.alarms.list": return try list()
        case "apple.alarms.add": return try await add(p)
        case "apple.alarms.timer": return try await timer(p)
        case "apple.alarms.delete": return try delete(p["id"]?.string ?? "")
        default: throw AppleBridgeError("Unbekannter Befehl \(command)")
        }
    }

    private func add(_ p: JSONValue) async throws -> JSONValue {
        // Titel ohne Vorgabe des Scoops ist auf dem Gerät sichtbar: in der Sprache der App
        let title = p["title"]?.string ?? String(localized: "Wecker", comment: "Titel eines Weckers ohne eigenen Namen")
        var record: [String: JSONValue] = ["title": .string(title), "kind": "alarm"]
        let schedule: Alarm.Schedule
        if let time = p["time"]?.string {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                throw AppleBridgeError("Uhrzeit ungültig: \(time)")
            }
            let days = (p["weekdays"]?.array ?? []).compactMap { $0.string.flatMap(Self.weekday) }
            schedule = .relative(.init(time: .init(hour: parts[0], minute: parts[1]),
                                       repeats: days.isEmpty ? .never : .weekly(days)))
            record["time"] = .string(String(format: "%02d:%02d", parts[0], parts[1]))
            if !days.isEmpty { record["weekdays"] = p["weekdays"] ?? .array([]) }
        } else if let raw = p["date"]?.string, let date = Self.localDate(raw) {
            guard date > Date() else { throw AppleBridgeError("Der Zeitpunkt liegt in der Vergangenheit.") }
            schedule = .fixed(date)
            record["date"] = .string(Self.iso(date))
        } else {
            throw AppleBridgeError("Uhrzeit oder Zeitpunkt fehlt.")
        }
        let attributes = AlarmAttributes<ScoopAlarmMetadata>(
            presentation: AlarmPresentation(alert: .init(title: LocalizedStringResource(stringLiteral: title),
                                                         stopButton: Self.stopButton)),
            metadata: ScoopAlarmMetadata(title: title, kind: "alarm"), tintColor: Self.tint)
        let id = UUID()
        let alarm = try await Self.schedule(id: id, schedule: schedule, duration: nil, attributes: attributes)
        save(id, record)
        return CmdResult.ok(["alarm": json(alarm)])
    }

    private func timer(_ p: JSONValue) async throws -> JSONValue {
        let seconds = Double(max(5, min(24 * 3600, p["seconds"]?.int ?? 0)))
        let title = p["title"]?.string ?? "Timer"
        let attributes = AlarmAttributes<ScoopAlarmMetadata>(
            presentation: AlarmPresentation(
                alert: .init(title: LocalizedStringResource(stringLiteral: title), stopButton: Self.stopButton),
                countdown: .init(title: LocalizedStringResource(stringLiteral: title),
                                 pauseButton: AlarmButton(text: "Pause", textColor: Self.tint, systemImageName: "pause.fill")),
                paused: .init(title: "Pausiert",
                              resumeButton: AlarmButton(text: LocalizedStringResource("alarm.resume", defaultValue: "Weiter", comment: "Knopf am pausierten Timer: fortsetzen"),
                                                        textColor: Self.tint, systemImageName: "play.fill"))),
            metadata: ScoopAlarmMetadata(title: title, kind: "timer"), tintColor: Self.tint)
        let id = UUID()
        let alarm = try await Self.schedule(id: id, schedule: nil, duration: seconds, attributes: attributes)
        save(id, ["title": .string(title), "kind": "timer", "seconds": .number(seconds),
                  "ends_at": .string(Self.iso(Date().addingTimeInterval(seconds)))])
        return CmdResult.ok(["alarm": json(alarm)])
    }

    private func list() throws -> JSONValue {
        let alarms = try manager.alarms
        // Gespeicherte Angaben zu Weckern, die es nicht mehr gibt (gelöscht, Timer abgelaufen), aufräumen
        var records = load()
        let live = Set(alarms.map(\.id.uuidString))
        records = records.filter { live.contains($0.key) }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: storeKey)
        return CmdResult.ok(["alarms": .array(alarms.map(json))])
    }

    private func delete(_ raw: String) throws -> JSONValue {
        guard let id = UUID(uuidString: raw), try manager.alarms.contains(where: { $0.id == id }) else {
            throw AppleBridgeError("Wecker nicht gefunden (ID aus 'anzeigen' nehmen).")
        }
        let record = load()[id.uuidString]
        try manager.cancel(id: id)
        var records = load()
        records[id.uuidString] = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: storeKey)
        return CmdResult.ok(["deleted": .object(["id": .string(raw), "title": record?["title"] ?? .null])])
    }

    // MARK: Darstellung und Speicher

    private func json(_ alarm: Alarm) -> JSONValue {
        var o = load()[alarm.id.uuidString] ?? [:]
        o["id"] = .string(alarm.id.uuidString)
        let state: String = switch alarm.state {
        case .scheduled: "scheduled"
        case .countdown: "countdown"
        case .paused: "paused"
        case .alerting: "alerting"
        @unknown default: "unknown"
        }
        o["state"] = .string(state)
        if o["kind"] == nil { o["kind"] = alarm.countdownDuration != nil ? "timer" : "alarm" }
        return .object(o)
    }

    private func load() -> [String: [String: JSONValue]] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data)) ?? [:]
    }

    private func save(_ id: UUID, _ record: [String: JSONValue]) {
        var all = load()
        var r = record
        r["created_at"] = .string(Self.iso(Date()))
        all[id.uuidString] = r
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: storeKey)
    }

    private static let tint = Color(red: 0.49, green: 0.36, blue: 1.0)
    private static let stopButton = AlarmButton(text: LocalizedStringResource("alarm.stop", defaultValue: "Aus", comment: "Knopf am klingelnden Wecker: ausschalten"),
                                                textColor: .white, systemImageName: "stop.fill")

    nonisolated static func weekday(_ name: String) -> Locale.Weekday? {
        switch name.lowercased() {
        case "monday": .monday
        case "tuesday": .tuesday
        case "wednesday": .wednesday
        case "thursday": .thursday
        case "friday": .friday
        case "saturday": .saturday
        case "sunday": .sunday
        default: nil
        }
    }

    /// „2026-11-20T06:45“ ohne Zone = Ortszeit des iPhones; mit Zone wie angegeben.
    nonisolated static func localDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let hasZone = s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if hasZone { return ISO8601Parser.parse(s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    nonisolated static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
#endif
