import AppKit
import Contacts
import EventKit

/// Apple-Dienste, die die Scoops über diesen Mac nutzen können (Server 1.17, docs/scoops-connect.md).
nonisolated enum AppleService: String, CaseIterable, Identifiable, Sendable {
    case reminders, calendar, contacts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: String(localized: "Erinnerungen", comment: "Apple-Dienst (Name der App in macOS)")
        case .calendar: String(localized: "Kalender", comment: "Apple-Dienst (Name der App in macOS)")
        case .contacts: String(localized: "Kontakte", comment: "Apple-Dienst (Name der App in macOS)")
        }
    }

    /// Name in Antworten an den Server (Protokoll, bleibt deutsch wie alle Befehlsmeldungen der App)
    var protocolTitle: String {
        switch self {
        case .reminders: "Erinnerungen"
        case .calendar: "Kalender"
        case .contacts: "Kontakte"
        }
    }

    var detail: String {
        switch self {
        case .reminders: String(localized: "Scoops lesen, legen an, ändern und haken ab. Löschen nur mit deiner Freigabe in AIS Scoops.")
        case .calendar: String(localized: "Scoops lesen Termine und tragen neue ein. Löschen nur mit deiner Freigabe in AIS Scoops.")
        case .contacts: String(localized: "Scoops schlagen Telefonnummern, Mailadressen und Geburtstage nach (nur lesen).")
        }
    }

    var symbol: String {
        switch self {
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .contacts: "person.crop.circle"
        }
    }

    var settingsURL: String {
        switch self {
        case .reminders: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .calendar: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .contacts: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
    }
}

/// Zugriff auf Erinnerungen, Kalender (EventKit) und Kontakte (Contacts) für die Befehle `apple.*`.
///
/// Freigabe-Zustände (für `hello`/`state`): `granted`, `denied`, `not_determined`, `restricted`, `write_only` und
/// `disabled` (macOS-Freigabe da, aber in dieser App für die Scoops ausgeschaltet). Fragt nie selbst nach einer
/// Freigabe, wenn ein Befehl kommt – das passiert nur über „Freigeben“ in den Einstellungen.
nonisolated final class AppleBridge: @unchecked Sendable {
    static let shared = AppleBridge()

    private let lock = NSLock()
    private var _store = EKEventStore()
    private var store: EKEventStore { lock.withLock { _store } }
    private let contacts = CNContactStore()

    // MARK: Freigaben

    static func disabledKey(_ s: AppleService) -> String { "appleDisabled.\(s.rawValue)" }

    static func isDisabled(_ s: AppleService) -> Bool { UserDefaults.standard.bool(forKey: disabledKey(s)) }

    /// macOS-Freigabe allein (ohne den Schalter dieser App).
    static func systemPermission(_ s: AppleService) -> String {
        switch s {
        case .reminders: return map(EKEventStore.authorizationStatus(for: .reminder))
        case .calendar: return map(EKEventStore.authorizationStatus(for: .event))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return "granted"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not_determined"
            @unknown default: return "granted"  // z. B. „eingeschränkt“: Zugriff auf die ausgewählten Kontakte
            }
        }
    }

    private static func map(_ st: EKAuthorizationStatus) -> String {
        switch st {
        case .fullAccess: return "granted"
        case .writeOnly: return "write_only"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "denied"
        }
    }

    /// Zustand, wie ihn der Server sieht (Schalter dieser App eingerechnet).
    static func permission(_ s: AppleService) -> String {
        let p = systemPermission(s)
        return p == "granted" && isDisabled(s) ? "disabled" : p
    }

    static var grants: [AppleService: String] {
        Dictionary(uniqueKeysWithValues: AppleService.allCases.map { ($0, permission($0)) })
    }

    static var grantsJSON: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: AppleService.allCases.map { ($0.rawValue, .string(permission($0))) }))
    }

    /// Zeigt den System-Dialog (nur beim ersten Mal; danach nur noch in den Systemeinstellungen änderbar).
    @MainActor
    func request(_ s: AppleService) async -> Bool {
        NSApp.activate()
        let granted: Bool
        do {
            switch s {
            case .reminders: granted = try await store.requestFullAccessToReminders()
            case .calendar: granted = try await store.requestFullAccessToEvents()
            case .contacts: granted = try await contacts.requestAccess(for: .contacts)
            }
        } catch {
            granted = false
        }
        if granted, s != .contacts {
            // Ein vor der Freigabe angelegter Speicher sieht die Kalender sonst erst nach einem Neustart.
            lock.withLock { _store = EKEventStore() }
        }
        return granted
    }

    // MARK: Befehle

    /// Führt einen `apple.*`-Befehl abseits des Haupt-Threads aus und liefert das Ergebnis im Cua-Format.
    @concurrent
    func execute(_ command: String, params p: JSONValue) async -> JSONValue {
        let service: AppleService
        if command.hasPrefix("apple.reminders.") { service = .reminders }
        else if command.hasPrefix("apple.calendar.") { service = .calendar }
        else if command.hasPrefix("apple.contacts.") { service = .contacts }
        else if command == "apple.status" { return CmdResult.ok(["apple": Self.grantsJSON]) }
        else { return CmdResult.fail("Unbekannter Befehl \(command)") }

        switch Self.permission(service) {
        case "granted": break
        case "disabled": return CmdResult.fail("\(service.protocolTitle) sind auf diesem Mac in AIS Scoops Server für die Scoops ausgeschaltet.")
        case "not_determined": return CmdResult.fail("\(service.protocolTitle): Freigabe auf diesem Mac noch nicht erteilt (AIS Scoops Server → Apple-Dienste).")
        default: return CmdResult.fail("\(service.protocolTitle): Keine Freigabe auf diesem Mac (Systemeinstellungen → Datenschutz).")
        }

        do {
            switch command {
            case "apple.reminders.lists": return reminderLists()
            case "apple.reminders.list": return await listReminders(p)
            case "apple.reminders.get": return CmdResult.ok(["reminder": json(try reminder(p))])
            case "apple.reminders.add": return try addReminder(p)
            case "apple.reminders.update": return try updateReminder(p)
            case "apple.reminders.complete":
                let r = try reminder(p)
                r.isCompleted = p["completed"]?.bool ?? true
                try store.save(r, commit: true)
                return CmdResult.ok(["reminder": json(r)])
            case "apple.reminders.delete":
                let r = try reminder(p)
                let info = json(r)
                try store.remove(r, commit: true)
                return CmdResult.ok(["deleted": info])
            case "apple.calendar.calendars": return eventCalendars()
            case "apple.calendar.events": return try listEvents(p)
            case "apple.calendar.get": return CmdResult.ok(["event": json(try event(p))])
            case "apple.calendar.add": return try addEvent(p)
            case "apple.calendar.update": return try updateEvent(p)
            case "apple.calendar.delete":
                let e = try event(p)
                let info = json(e)
                try store.remove(e, span: span(p), commit: true)
                return CmdResult.ok(["deleted": info])
            case "apple.contacts.search": return try searchContacts(p)
            default: return CmdResult.fail("Unbekannter Befehl \(command)")
            }
        } catch let e as BridgeError {
            return CmdResult.fail(e.message)
        } catch {
            return CmdResult.fail(error.localizedDescription)
        }
    }

    struct BridgeError: Error { let message: String }

    // MARK: Erinnerungen

    private func reminderLists() -> JSONValue {
        let def = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        return CmdResult.ok(["lists": .array(lists.map { c in
            .object(["id": .string(c.calendarIdentifier), "title": .string(c.title), "color": .string(Self.hex(c.color)),
                     "account": .string(c.source?.title ?? ""), "writable": .bool(c.allowsContentModifications),
                     "default": .bool(c.calendarIdentifier == def)])
        })])
    }

    private func calendar(named raw: String?, for type: EKEntityType) throws -> EKCalendar? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let all = store.calendars(for: type)
        if let c = all.first(where: { $0.calendarIdentifier == name })
            ?? all.first(where: { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
            ?? all.first(where: { $0.title.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            return c
        }
        let names = all.map(\.title).joined(separator: ", ")
        throw BridgeError(message: "\(type == .reminder ? "Liste" : "Kalender") „\(name)“ nicht gefunden. Vorhanden: \(names)")
    }

    private func listReminders(_ p: JSONValue) async -> JSONValue {
        let cals: [EKCalendar]?
        do { cals = try calendar(named: p["list"]?.string, for: .reminder).map { [$0] } } catch {
            return CmdResult.fail((error as? BridgeError)?.message ?? error.localizedDescription)
        }
        let status = p["status"]?.string ?? "open"
        let dueBefore = p["due_before"]?.string.flatMap { Self.parseDate($0) }.map { $0.dateOnly ? Self.endOfDay($0.date) : $0.date }
        let predicate: NSPredicate
        switch status {
        case "completed": predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: cals)
        case "all": predicate = store.predicateForReminders(in: cals)
        default: predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: cals)
        }
        let query = (p["query"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let limit = max(1, min(p["limit"]?.int ?? 50, 200))
        let items: [JSONValue] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { found in
                var rs = found ?? []
                if !query.isEmpty {
                    rs = rs.filter { r in
                        [r.title ?? "", r.notes ?? ""].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                    }
                }
                if let dueBefore, status != "open" {
                    rs = rs.filter { r in r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { $0 <= dueBefore } ?? false }
                }
                rs.sort { a, b in
                    let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    if status == "completed" { return (a.completionDate ?? .distantPast) > (b.completionDate ?? .distantPast) }
                    return da != db ? da < db : (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
                }
                let total = rs.count
                var out = rs.prefix(limit).map { self.json($0) }
                if total > limit { out.append(.object(["more": .int(total - limit)])) }
                cont.resume(returning: out)
            }
        }
        return CmdResult.ok(["reminders": .array(items)])
    }

    private func reminder(_ p: JSONValue) throws -> EKReminder {
        guard let id = p["id"]?.string, !id.isEmpty else { throw BridgeError(message: "id fehlt") }
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BridgeError(message: "Erinnerung \(id) nicht gefunden (vielleicht schon gelöscht).")
        }
        return r
    }

    private func addReminder(_ p: JSONValue) throws -> JSONValue {
        guard let title = p["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw BridgeError(message: "title fehlt")
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = try calendar(named: p["list"]?.string, for: .reminder) ?? store.defaultCalendarForNewReminders()
        guard r.calendar != nil else { throw BridgeError(message: "Keine Erinnerungsliste vorhanden.") }
        if let n = p["notes"]?.string, !n.isEmpty { r.notes = n }
        if let prio = p["priority"] { r.priority = Self.priority(prio) }
        if let due = p["due"]?.string, !due.isEmpty { try setDue(r, due) }
        try store.save(r, commit: true)
        return CmdResult.ok(["reminder": json(r)])
    }

    private func updateReminder(_ p: JSONValue) throws -> JSONValue {
        let r = try reminder(p)
        if let t = p["title"]?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty { r.title = t }
        if let n = p["notes"]?.string { r.notes = n.isEmpty ? nil : n }
        if let prio = p["priority"] { r.priority = Self.priority(prio) }
        if let l = p["list"]?.string, !l.isEmpty, let c = try calendar(named: l, for: .reminder) { r.calendar = c }
        if let due = p["due"]?.string {
            if due.isEmpty {
                r.dueDateComponents = nil
                r.alarms?.forEach { r.removeAlarm($0) }
            } else {
                try setDue(r, due)
            }
        }
        if let done = p["completed"]?.bool { r.isCompleted = done }
        try store.save(r, commit: true)
        return CmdResult.ok(["reminder": json(r)])
    }

    private func setDue(_ r: EKReminder, _ raw: String) throws {
        guard let d = Self.parseDate(raw) else { throw BridgeError(message: "Ungültiges Datum „\(raw)“ (ISO 8601, z. B. 2026-11-20T09:00)") }
        var cal = Calendar.current
        cal.timeZone = .current
        r.alarms?.forEach { r.removeAlarm($0) }
        if d.dateOnly {
            var dc = cal.dateComponents([.year, .month, .day], from: d.date)
            dc.calendar = cal
            r.dueDateComponents = dc
        } else {
            var dc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d.date)
            dc.calendar = cal
            dc.timeZone = .current
            r.dueDateComponents = dc
            r.addAlarm(EKAlarm(absoluteDate: d.date))  // wie in der Erinnerungen-App: Hinweis zur Uhrzeit
        }
    }

    private static func priority(_ v: JSONValue) -> Int {
        if let n = v.int, v.string == nil { return max(0, min(n, 9)) }
        switch v.string?.lowercased() ?? "" {
        case "high", "hoch": return 1
        case "medium", "mittel": return 5
        case "low", "niedrig": return 9
        default: return 0
        }
    }

    private static func priorityName(_ p: Int) -> String {
        switch p {
        case 1...4: "high"
        case 5: "medium"
        case 6...9: "low"
        default: "none"
        }
    }

    func json(_ r: EKReminder) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""),
            "list": .string(r.calendar?.title ?? ""), "list_id": .string(r.calendar?.calendarIdentifier ?? ""),
            "completed": .bool(r.isCompleted), "priority": .string(Self.priorityName(r.priority)),
        ]
        if let n = r.notes, !n.isEmpty { o["notes"] = .string(String(n.prefix(1000))) }
        if let dc = r.dueDateComponents, let date = Calendar.current.date(from: dc) {
            let allDay = dc.hour == nil
            o["due"] = .string(allDay ? Self.dayString(date) : Self.iso(date))
            o["due_all_day"] = .bool(allDay)
        }
        if let c = r.completionDate { o["completed_at"] = .string(Self.iso(c)) }
        if let u = r.url { o["url"] = .string(u.absoluteString) }
        return .object(o)
    }

    // MARK: Kalender

    private func eventCalendars() -> JSONValue {
        let def = store.defaultCalendarForNewEvents?.calendarIdentifier
        let cals = store.calendars(for: .event).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        return CmdResult.ok(["calendars": .array(cals.map { c in
            .object(["id": .string(c.calendarIdentifier), "title": .string(c.title), "color": .string(Self.hex(c.color)),
                     "account": .string(c.source?.title ?? ""), "writable": .bool(c.allowsContentModifications),
                     "default": .bool(c.calendarIdentifier == def)])
        })])
    }

    private func listEvents(_ p: JSONValue) throws -> JSONValue {
        let start: Date
        if let raw = p["from"]?.string, !raw.isEmpty {
            guard let d = Self.parseDate(raw) else { throw BridgeError(message: "Ungültiges Datum „\(raw)“") }
            start = d.dateOnly ? Calendar.current.startOfDay(for: d.date) : d.date
        } else {
            start = Calendar.current.startOfDay(for: Date())
        }
        var end: Date
        if let raw = p["to"]?.string, !raw.isEmpty {
            guard let d = Self.parseDate(raw) else { throw BridgeError(message: "Ungültiges Datum „\(raw)“") }
            end = d.dateOnly ? Self.endOfDay(d.date) : d.date
        } else {
            end = Self.endOfDay(start)
        }
        if end <= start { end = Self.endOfDay(start) }
        end = min(end, start.addingTimeInterval(366 * 86400))
        let cals = try calendar(named: p["calendar"]?.string, for: .event).map { [$0] }
        let query = (p["query"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let limit = max(1, min(p["limit"]?.int ?? 100, 300))
        var events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals))
        if !query.isEmpty {
            events = events.filter { e in
                [e.title ?? "", e.location ?? "", e.notes ?? ""].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        events.sort { $0.startDate < $1.startDate }
        var out = events.prefix(limit).map { json($0) }
        if events.count > limit { out.append(.object(["more": .int(events.count - limit)])) }
        return CmdResult.ok(["from": .string(Self.iso(start)), "to": .string(Self.iso(end)), "events": .array(out)])
    }

    /// IDs: `eventIdentifier`, bei Serien zusätzlich `@<Unix-Zeit des Vorkommens>`, damit genau dieses Vorkommen gemeint ist.
    private func event(_ p: JSONValue) throws -> EKEvent {
        guard let raw = p["id"]?.string, !raw.isEmpty else { throw BridgeError(message: "id fehlt") }
        var base = raw
        var when: Date?
        if let at = raw.lastIndex(of: "@"), let ts = Double(raw[raw.index(after: at)...]) {
            base = String(raw[..<at])
            when = Date(timeIntervalSince1970: ts)
        }
        guard let e = store.event(withIdentifier: base) else {
            throw BridgeError(message: "Termin \(raw) nicht gefunden (vielleicht schon gelöscht).")
        }
        if let when, e.hasRecurrenceRules || abs(e.occurrenceDate?.timeIntervalSince(when) ?? 0) > 60 {
            let pred = store.predicateForEvents(withStart: when.addingTimeInterval(-86400), end: when.addingTimeInterval(86400),
                                                calendars: [e.calendar])
            if let occ = store.events(matching: pred).first(where: {
                $0.eventIdentifier == base && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(when)) < 60
            }) {
                return occ
            }
        }
        return e
    }

    private func span(_ p: JSONValue) -> EKSpan { p["span"]?.string == "future" ? .futureEvents : .thisEvent }

    private func addEvent(_ p: JSONValue) throws -> JSONValue {
        guard let title = p["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw BridgeError(message: "title fehlt")
        }
        guard let rawStart = p["start"]?.string, let s = Self.parseDate(rawStart) else {
            throw BridgeError(message: "start fehlt oder ist ungültig (ISO 8601, z. B. 2026-11-20T09:00)")
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.calendar = try calendar(named: p["calendar"]?.string, for: .event) ?? store.defaultCalendarForNewEvents
        guard let cal = e.calendar else { throw BridgeError(message: "Kein Kalender vorhanden.") }
        guard cal.allowsContentModifications else { throw BridgeError(message: "Kalender „\(cal.title)“ ist schreibgeschützt.") }
        let allDay = p["all_day"]?.bool ?? s.dateOnly
        e.isAllDay = allDay
        e.startDate = allDay ? Calendar.current.startOfDay(for: s.date) : s.date
        if let rawEnd = p["end"]?.string, !rawEnd.isEmpty {
            guard let en = Self.parseDate(rawEnd) else { throw BridgeError(message: "Ungültiges Ende „\(rawEnd)“") }
            e.endDate = allDay ? Self.endOfDay(en.date) : en.date
        } else {
            e.endDate = allDay ? Self.endOfDay(e.startDate) : e.startDate.addingTimeInterval(3600)
        }
        if e.endDate < e.startDate { throw BridgeError(message: "Das Ende liegt vor dem Beginn.") }
        if let l = p["location"]?.string, !l.isEmpty { e.location = l }
        if let n = p["notes"]?.string, !n.isEmpty { e.notes = n }
        if let m = p["alarm_minutes"]?.int, m >= 0 { e.addAlarm(EKAlarm(relativeOffset: TimeInterval(-m * 60))) }
        try store.save(e, span: .thisEvent, commit: true)
        return CmdResult.ok(["event": json(e)])
    }

    private func updateEvent(_ p: JSONValue) throws -> JSONValue {
        let e = try event(p)
        guard e.calendar.allowsContentModifications else { throw BridgeError(message: "Kalender „\(e.calendar.title)“ ist schreibgeschützt.") }
        if let t = p["title"]?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty { e.title = t }
        if let l = p["location"]?.string { e.location = l.isEmpty ? nil : l }
        if let n = p["notes"]?.string { e.notes = n.isEmpty ? nil : n }
        if let c = p["calendar"]?.string, !c.isEmpty, let cal = try calendar(named: c, for: .event) { e.calendar = cal }
        if let a = p["all_day"]?.bool { e.isAllDay = a }
        let duration = e.endDate.timeIntervalSince(e.startDate)
        if let raw = p["start"]?.string, !raw.isEmpty {
            guard let s = Self.parseDate(raw) else { throw BridgeError(message: "Ungültiger Beginn „\(raw)“") }
            e.startDate = e.isAllDay ? Calendar.current.startOfDay(for: s.date) : s.date
            if p["end"] == nil { e.endDate = e.startDate.addingTimeInterval(max(duration, 0)) }
        }
        if let raw = p["end"]?.string, !raw.isEmpty {
            guard let en = Self.parseDate(raw) else { throw BridgeError(message: "Ungültiges Ende „\(raw)“") }
            e.endDate = e.isAllDay ? Self.endOfDay(en.date) : en.date
        }
        if e.endDate < e.startDate { throw BridgeError(message: "Das Ende liegt vor dem Beginn.") }
        if let m = p["alarm_minutes"]?.int {
            e.alarms?.forEach { e.removeAlarm($0) }
            if m >= 0 { e.addAlarm(EKAlarm(relativeOffset: TimeInterval(-m * 60))) }
        }
        try store.save(e, span: span(p), commit: true)
        return CmdResult.ok(["event": json(e)])
    }

    func json(_ e: EKEvent) -> JSONValue {
        let base = e.eventIdentifier ?? e.calendarItemIdentifier
        let id = e.hasRecurrenceRules ? "\(base)@\(Int((e.occurrenceDate ?? e.startDate).timeIntervalSince1970))" : base
        var o: [String: JSONValue] = [
            "id": .string(id), "title": .string(e.title ?? ""), "all_day": .bool(e.isAllDay),
            "start": .string(e.isAllDay ? Self.dayString(e.startDate) : Self.iso(e.startDate)),
            "end": .string(e.isAllDay ? Self.dayString(e.endDate) : Self.iso(e.endDate)),
            "calendar": .string(e.calendar?.title ?? ""), "calendar_id": .string(e.calendar?.calendarIdentifier ?? ""),
            "recurring": .bool(e.hasRecurrenceRules),
        ]
        if let l = e.location, !l.isEmpty { o["location"] = .string(l) }
        if let n = e.notes, !n.isEmpty { o["notes"] = .string(String(n.prefix(500))) }
        if let u = e.url { o["url"] = .string(u.absoluteString) }
        if let a = e.attendees, !a.isEmpty { o["attendees"] = .int(a.count) }
        return .object(o)
    }

    // MARK: Kontakte

    private func searchContacts(_ p: JSONValue) throws -> JSONValue {
        let query = (p["query"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let days = p["birthdays_days"]?.int
        let limit = max(1, min(p["limit"]?.int ?? 20, 100))
        guard !query.isEmpty || days != nil else { throw BridgeError(message: "query fehlt") }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor,
        ]
        let digits = query.filter(\.isNumber)
        let phoneQuery = digits.count >= 4 && Double(digits.count) >= Double(query.filter { !$0.isWhitespace }.count) * 0.6
        let words = query.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(separator: " ").map(String.init)
        var hits: [(CNContact, Int?)] = []
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .userDefault
        try contacts.enumerateContacts(with: req) { c, _ in
            var nextBirthday: Int?
            if let days {
                guard let n = Self.daysUntilBirthday(c.birthday), n <= days else { return }
                nextBirthday = n
            }
            if !query.isEmpty {
                let match: Bool
                if phoneQuery {
                    let tail = String(digits.suffix(8))
                    match = c.phoneNumbers.contains { $0.value.stringValue.filter(\.isNumber).hasSuffix(tail) }
                } else if query.contains("@") {
                    match = c.emailAddresses.contains { ($0.value as String).localizedCaseInsensitiveContains(query) }
                } else {
                    let hay = [CNContactFormatter.string(from: c, style: .fullName) ?? "", c.nickname, c.organizationName, c.jobTitle,
                               c.emailAddresses.map { $0.value as String }.joined(separator: " ")]
                        .joined(separator: " ").lowercased().folding(options: .diacriticInsensitive, locale: nil)
                    match = words.allSatisfy { hay.contains($0) }
                }
                guard match else { return }
            }
            hits.append((c, nextBirthday))
        }
        if days != nil { hits.sort { ($0.1 ?? 999) < ($1.1 ?? 999) } }
        var out = hits.prefix(limit).map { json($0.0, nextBirthday: $0.1) }
        if hits.count > limit { out.append(.object(["more": .int(hits.count - limit)])) }
        return CmdResult.ok(["contacts": .array(out)])
    }

    private static func daysUntilBirthday(_ b: DateComponents?) -> Int? {
        guard let b, let month = b.month, let day = b.day else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let year = cal.component(.year, from: today)
        for y in [year, year + 1] {
            var dc = DateComponents(year: y, month: month, day: day)
            if month == 2, day == 29, cal.date(from: dc).map({ cal.component(.day, from: $0) }) != 29 { dc.day = 28 }
            if let d = cal.date(from: dc), d >= today { return cal.dateComponents([.day], from: today, to: d).day }
        }
        return nil
    }

    func json(_ c: CNContact, nextBirthday: Int?) -> JSONValue {
        func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        var o: [String: JSONValue] = [
            "id": .string(c.identifier),
            "name": .string(CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName),
        ]
        if !c.nickname.isEmpty { o["nickname"] = .string(c.nickname) }
        if !c.organizationName.isEmpty { o["organization"] = .string(c.organizationName) }
        if !c.jobTitle.isEmpty { o["job_title"] = .string(c.jobTitle) }
        if !c.phoneNumbers.isEmpty {
            o["phones"] = .array(c.phoneNumbers.map { .object(["label": .string(label($0.label)), "value": .string($0.value.stringValue)]) })
        }
        if !c.emailAddresses.isEmpty {
            o["emails"] = .array(c.emailAddresses.map { .object(["label": .string(label($0.label)), "value": .string($0.value as String)]) })
        }
        if let b = c.birthday, let m = b.month, let d = b.day {
            o["birthday"] = .string(b.year.map { String(format: "%04d-%02d-%02d", $0, m, d) } ?? String(format: "--%02d-%02d", m, d))
        }
        if let n = nextBirthday { o["birthday_in_days"] = .int(n) }
        if !c.postalAddresses.isEmpty {
            o["addresses"] = .array(c.postalAddresses.map {
                let a = $0.value
                let line = [a.street, [a.postalCode, a.city].filter { !$0.isEmpty }.joined(separator: " "), a.country]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                return .object(["label": .string(label($0.label)), "value": .string(line)])
            })
        }
        return .object(o)
    }

    // MARK: Datum

    struct ParsedDate { let date: Date; let dateOnly: Bool }

    /// ISO 8601: „2026-11-20“, „2026-11-20T09:00“, „2026-11-20T09:00:00“, jeweils optional mit Zeitzone („Z“, „+01:00“).
    /// Ohne Zeitzone gilt die Zeitzone dieses Macs.
    static func parseDate(_ raw: String) -> ParsedDate? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        if s.count == 10, let d = f.date(from: s) { return ParsedDate(date: d, dateOnly: true) }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return ParsedDate(date: d, dateOnly: false) }
        }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return ParsedDate(date: d, dateOnly: false) }
        }
        return nil
    }

    static func endOfDay(_ d: Date) -> Date {
        let start = Calendar.current.startOfDay(for: d)
        return Calendar.current.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? d
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func hex(_ c: NSColor?) -> String {
        guard let s = c?.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }
}
