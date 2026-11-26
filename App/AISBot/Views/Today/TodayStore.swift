import Foundation
import Observation
import SwiftUI

/// Zustand der Seite „Heute“: Freigaben-Postfach und Überblick über alle Scoops (nur der eigene Server).
///
/// Geladen wird mit einer Anfrage (`GET /api/today`). Danach hält sich die Seite über die vorhandenen Ereignisse
/// aktuell: Freigabe-Karten (`message.created/updated`), Statuszeilen laufender Chat-Läufe, `task.updated`,
/// `bot.updated`/`group.updated` (arbeitet, wartet), gelöschte Chats. Alles, was sich daraus nicht sicher ableiten
/// lässt (Aufgabe und Frist einer neuen Karte, geänderte Routinen), holt ein kurz verzögerter Abgleich nach.
@Observable
final class TodayStore {
    /// Server kennt die Seite (Health-Feld `today`); ältere Server und reine Gast-Verbindungen: `false`
    var available = false
    private(set) var loaded = false
    private(set) var loading = false
    /// Meldung, wenn das erste Laden scheitert
    private(set) var loadError: String?

    /// Offene Freigaben, neueste zuerst. Gerade entschiedene bleiben kurz stehen (`settling`), damit man das
    /// Ergebnis auf der Karte sieht, bevor sie verschwindet.
    private(set) var approvals: [TodayApproval] = []
    private(set) var settling: Set<String> = []
    private(set) var tasks: [String: BotTask] = [:]
    /// Laufende Chat-Läufe je Chat
    private(set) var runs: [String: TodayRun] = [:]
    private(set) var planned: [TodayPlanned] = []
    private(set) var routinesDone: [TodayRoutineDone] = []
    /// Beginn von „Seit gestern erledigt“ laut Server
    private(set) var since: Date?
    /// Letzter Besuch der Seite vor dem aktuellen (für die Punkte „neu“)
    private(set) var previousVisit: Date?
    /// Uhr für Fristen und „heute“ (läuft weiter, solange die Seite sichtbar ist)
    private(set) var clock = Date()

    /// Setzt der AppStore (eigene Server-Verbindung, Speicherschlüssel je Server)
    @ObservationIgnored var service: () -> TodayService? = { nil }
    @ObservationIgnored var storageKey: () -> String? = { nil }
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var settleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Demo (`-mock -heuteleer`): Seite ohne Inhalt zeigen
    static let demoEmpty = ProcessInfo.processInfo.arguments.contains("-heuteleer")

    /// Wie lange eine entschiedene Karte noch stehen bleibt
    private static let settleDelay: Duration = .milliseconds(1600)

    // MARK: Abschnitte

    /// Offene Freigaben (ohne abgelaufene), dazu gerade entschiedene Karten
    var approvalItems: [TodayApproval] {
        approvals.filter { settling.contains($0.id) || !$0.isExpired(at: clock) }
    }

    /// Aufgaben mit Rückfrage an den Nutzer (keine Karte; beantwortet wird in der Aufgabe bzw. im Chat)
    var questions: [BotTask] {
        tasks.values.filter { $0.isWaiting && $0.waitingKind == "frage" }
            .sorted { ($0.updatedAt ?? $0.startedAt ?? .distantPast) > ($1.updatedAt ?? $1.startedAt ?? .distantPast) }
    }

    /// Zähler am Eintrag „Heute“: offene Freigaben und Rückfragen
    var waitingCount: Int {
        approvals.filter { !settling.contains($0.id) && $0.message.isPendingApproval && !$0.isExpired(at: clock) }.count
            + questions.count
    }

    /// „2 Freigaben und 1 Rückfrage warten auf dich“ (`nil`, wenn nichts wartet)
    var waitingText: String? {
        let open = waitingCount - questions.count, asked = questions.count
        if open > 0, asked > 0 {
            let approvalsText = String(localized: "\(open) Freigaben", comment: "Anzahl offener Freigaben, z. B. „2 Freigaben“")
            let questionsText = String(localized: "\(asked) Rückfragen", comment: "Anzahl offener Rückfragen, z. B. „1 Rückfrage“")
            return String(localized: "\(approvalsText) und \(questionsText) warten auf dich")
        }
        if open > 0 { return String(localized: "\(open) Freigaben warten auf dich") }
        if asked > 0 { return String(localized: "\(asked) Rückfragen warten auf dich") }
        return nil
    }

    /// „Zum Prüfen“: fertige Aufgaben und Aufgaben mit Problem (Probleme zuerst, dann neueste)
    var review: [BotTask] {
        tasks.values.filter { $0.boardColumn == .review }.sorted {
            if $0.isProblem != $1.isProblem { return $0.isProblem }
            return ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast)
        }
    }

    /// „Läuft gerade“: Aufgaben, die arbeiten oder auf einen Platz warten
    var runningTasks: [BotTask] {
        tasks.values.filter(\.isRunning)
            .sorted { ($0.startedAt ?? $0.createdAt ?? .distantPast) > ($1.startedAt ?? $1.createdAt ?? .distantPast) }
    }

    var runningChats: [TodayRun] {
        runs.values.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// „Heute geplant“: geplante Aufgaben mit Termin bis Mitternacht
    var plannedTasks: [BotTask] {
        let end = Self.endOfDay(clock)
        return tasks.values.filter { $0.isScheduled && ($0.scheduledAt.map { $0 <= end } ?? false) }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
    }

    var plannedRoutines: [TodayPlanned] {
        let end = Self.endOfDay(clock)
        return planned.filter { $0.at <= end }.sorted { $0.at < $1.at }
    }

    /// Zähler „heute geplant“ (Widget in der Seitenleiste, Kopf der Seite)
    var plannedCount: Int { plannedTasks.count + plannedRoutines.count }

    /// Arbeitende Scoops und Aufgaben (Zähler „arbeiten“)
    var runningCount: Int { runningChats.count + runningTasks.count }

    /// „Seit gestern erledigt“: abgenommene Aufgaben seit `since`
    var doneTasks: [BotTask] {
        let start = since ?? clock.addingTimeInterval(-24 * 3600)
        return tasks.values.filter { $0.boardColumn == .done && ($0.finishedAt.map { $0 >= start } ?? false) }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    /// Reicht „Seit gestern erledigt“ weiter zurück als 24 Stunden (letzter Besuch länger her)?
    var reachesBackToLastVisit: Bool {
        guard let since else { return false }
        return clock.timeIntervalSince(since) > 25 * 3600
    }

    /// Erst seit dem letzten Besuch dazugekommen (Punkt „neu“)
    func isNew(_ date: Date?) -> Bool {
        guard let date, let previousVisit else { return false }
        return date > previousVisit
    }

    private static func endOfDay(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) ?? date.addingTimeInterval(86_400)
    }

    // MARK: Laden

    /// Verbindung gewechselt oder getrennt: alles vergessen
    func reset() {
        generation += 1
        reloadTask?.cancel()
        expiryTask?.cancel()
        settleTasks.values.forEach { $0.cancel() }
        settleTasks = [:]
        approvals = []; settling = []; tasks = [:]; runs = [:]; planned = []; routinesDone = []
        since = nil
        previousVisit = nil
        loaded = false
        loading = false
        loadError = nil
        available = false
    }

    func load() async {
        guard available, let service = service() else { return }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let o = try await service.todayOverview(since: lastVisit)
            guard gen == generation else { return }
            apply(o)
            loaded = true
            loadError = nil
        } catch let error as APIError where [403, 404, 405].contains(error.status) {
            // Server kennt die Seite (doch) nicht bzw. Gast-Verbindung: Eintrag ausblenden
            guard gen == generation else { return }
            available = false
        } catch {
            guard gen == generation else { return }
            if !loaded { loadError = (error as? APIError)?.message ?? error.localizedDescription }
        }
    }

    private func apply(_ o: TodayOverview) {
        clock = Date()
        // Karten, die gerade entschieden wurden, behalten ihren Stand, bis sie von selbst verschwinden
        let keep = approvals.filter { settling.contains($0.id) }
        let fresh = (o.approvals ?? []).filter { a in !settling.contains(a.id) && a.message.isPendingApproval }
        approvals = (keep + fresh).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        tasks = Dictionary((o.tasks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        runs = Dictionary((o.running ?? []).map { ($0.chatId, $0) }, uniquingKeysWith: { _, new in new })
        planned = o.planned ?? []
        routinesDone = o.routinesDone ?? []
        since = o.since
        scheduleExpiry()
    }

    /// Zum Ablauf der nächsten Frist die Uhr nachstellen, damit der Zähler auch stimmt, wenn die Seite gerade nicht
    /// sichtbar ist (die Karte gilt dann als liegengeblieben und zählt nicht mehr).
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let now = Date()
        guard let next = approvals.compactMap(\.expiresAt).filter({ $0 > now }).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 1))
            guard let self, !Task.isCancelled else { return }
            self.tick()
            self.scheduleExpiry()
        }
    }

    /// Abgleich mit dem Server, kurz gebündelt (mehrere Ereignisse hintereinander lösen nur eine Anfrage aus).
    func scheduleReload(after delay: Duration = .milliseconds(700)) {
        guard available else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.load()
        }
    }

    /// Uhr nachstellen (Fristen, Tageswechsel); die sichtbare Seite ruft das regelmäßig auf.
    func tick() { clock = Date() }

    // MARK: Besuch

    private var lastVisitKey: String? { storageKey().map { "todayLastVisit.\($0)" } }

    private var lastVisit: Date? {
        guard let key = lastVisitKey else { return nil }
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Seite erscheint: Stand des vorigen Besuchs merken (für „neu“).
    func pageAppeared() {
        previousVisit = lastVisit
        tick()
    }

    /// Seite verlassen bzw. App geht in den Hintergrund: Der Besuch gilt als erfolgt.
    func pageLeft() {
        guard let key = lastVisitKey else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
    }

    // MARK: Ereignisse

    /// Nachricht neu oder geändert (auch die Antwort auf eine eigene Entscheidung). Nur eigener Server.
    func messageChanged(_ m: Message) {
        guard available else { return }
        switch m.role {
        case .approval:
            guard m.meta.guestView != true, let approvalID = m.meta.approvalId else { return }
            approvalChanged(m, id: approvalID)
        case .status:
            if let info = m.meta.task {
                // Statuskarte einer Aufgabe: Zustand und Zwischenstand sofort
                guard var t = tasks[info.id] else { return }
                if let s = info.state, s != t.state {
                    t.state = s
                    t.column = nil
                }
                if let lines = m.meta.lines { t.steps = lines.count }
                if let n = info.note { t.note = n }
                if tasks[info.id] != t { tasks[info.id] = t }
            } else if m.isRunning {
                let run = TodayRun(chatId: m.chatId, botId: m.meta.authorId ?? (ChatGroup.isGroupID(m.chatId) ? nil : m.chatId),
                                   runId: m.meta.runId, messageId: m.id, line: m.meta.lines?.last,
                                   steps: m.meta.lines?.count, startedAt: m.meta.startedAt ?? m.createdAt,
                                   usesComputer: m.meta.usesComputer)
                if runs[m.chatId] != run { runs[m.chatId] = run }
            } else if runs[m.chatId]?.messageId == m.id {
                runs[m.chatId] = nil
            }
        default:
            break
        }
    }

    private func approvalChanged(_ m: Message, id: String) {
        if let i = approvals.firstIndex(where: { $0.id == id }) {
            guard approvals[i].message != m else { return }
            approvals[i].message = m
            if !m.isPendingApproval {
                settle(id)
            } else if settling.contains(id) {
                // Entscheidung ist gescheitert (Karte steht wieder auf offen): bleibt im Postfach
                settleTasks[id]?.cancel()
                settleTasks[id] = nil
                settling.remove(id)
            }
        } else if m.isPendingApproval, let entry = TodayApproval(message: m) {
            approvals.insert(entry, at: 0)
            scheduleExpiry()
            // Aufgabe und Frist der neuen Karte kennt nur der Server
            scheduleReload(after: .seconds(2))
        }
    }

    /// Entschiedene Karte: zählt sofort nicht mehr, verschwindet nach kurzer Zeit.
    private func settle(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) { _ = settling.insert(id) }
        settleTasks[id]?.cancel()
        settleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.3)) {
                self.approvals.removeAll { $0.id == id }
                self.settling.remove(id)
            }
            self.settleTasks[id] = nil
        }
    }

    /// `task.updated`
    func taskChanged(_ t: BotTask) {
        guard available else { return }
        let before = tasks[t.id]
        if [.archived, .open].contains(t.boardColumn) {
            tasks[t.id] = nil
        } else {
            var merged = t
            if merged.steps == nil { merged.steps = before?.steps }
            tasks[t.id] = merged
        }
        // Hält die Aufgabe nicht mehr an, gilt für ihre Karten wieder die Frist (und umgekehrt)
        if before?.isWaiting != t.isWaiting, approvals.contains(where: { $0.taskId == t.id }) || t.waitingKind == "freigabe" {
            scheduleReload()
        }
    }

    /// `task.deleted`
    func taskDeleted(_ id: String) {
        tasks[id] = nil
    }

    /// `bot.updated` / `group.updated`: arbeitet der Chat noch, wartet dort noch etwas auf den Nutzer?
    func chatChanged(id: String, busy: Bool, waiting: Bool) {
        guard available else { return }
        if !busy, runs[id] != nil { runs[id] = nil }
        // Laut Server wartet dort nichts mehr, hier steht aber noch eine offene Karte (Verlauf geleert, verpasstes
        // Ereignis): mit dem Server abgleichen statt zu raten.
        let known = approvals.contains { $0.chatId == id && !settling.contains($0.id) && $0.message.isPendingApproval }
        if !waiting, known {
            scheduleReload()
        }
        // Umgekehrt: Der Server meldet „wartet“ (rotes „?“ am Scoop), hier fehlt aber die Karte (verpasstes
        // `message.created`, Karte vor dem ersten Laden entstanden). Sonst zeigte „Heute“ „Alles ruhig“ neben dem „?“.
        if waiting, !known {
            scheduleReload()
        }
    }

    /// Scoop oder Gruppe gelöscht: alles dazu verschwindet sofort.
    func chatDeleted(_ id: String) {
        guard available else { return }
        approvals.removeAll { $0.chatId == id || $0.botId == id }
        for (key, t) in tasks where t.chatId == id || t.botId == id { tasks[key] = nil }
        runs[id] = nil
        planned.removeAll { $0.botId == id }
        routinesDone.removeAll { $0.botId == id }
    }

    /// `message.deleted` (Antworten auf die alte Fassung einer bearbeiteten Nachricht): Karte bzw. Statuskarte, die es
    /// nicht mehr gibt, verschwindet sofort. Sicherheitshalber gleicht die Seite danach mit dem Server ab.
    func messageDeleted(_ id: String) {
        guard available else { return }
        let hadApproval = approvals.contains { $0.message.id == id }
        approvals.removeAll { $0.message.id == id }
        for (chat, run) in runs where run.messageId == id { runs[chat] = nil }
        if hadApproval { scheduleReload() }
    }

    /// `routine.updated`: Zeitplan oder Lauf geändert
    func routineChanged() {
        scheduleReload(after: .seconds(1))
    }
}
