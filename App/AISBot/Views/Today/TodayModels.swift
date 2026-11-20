import Foundation

// MARK: - Seite „Heute“ (docs/API.md „Seite Heute“, Server: today.py)

/// Offene Freigabe im Postfach (`GET /api/today` bzw. `GET /api/approvals`): wer fragt, wo, und die Karten-Nachricht,
/// damit dieselben Karten wie im Chat sie zeigen können.
nonisolated struct TodayApproval: Codable, Hashable, Identifiable, Sendable {
    /// ID der Freigabe (`meta.approval_id` der Nachricht)
    var id: String
    /// Chat (Einzelchat = Scoop-ID, Gruppe `g_…`)
    var chatId: String
    /// Scoop, der fragt
    var botId: String?
    var kind: String?
    var title: String?
    var createdAt: Date?
    /// Danach gilt die Karte als liegengeblieben (48 h). `nil`: ohne Frist (eine Aufgabe hält wegen der Karte an).
    var expiresAt: Date?
    /// Aus einer Hintergrund-Aufgabe
    var taskId: String?
    var taskTitle: String?
    /// Geteilter Scoop: Gast, aus dessen Lauf die Freigabe stammt
    var requestedBy: String?
    var message: Message

    /// Frist, falls der Server keine nennt (frisch per Ereignis eingetroffene Karte)
    static let defaultLifetime: TimeInterval = 48 * 3600

    /// Karte, die gerade per Ereignis eingetroffen ist; Aufgabe und Frist kommen mit dem nächsten Abgleich.
    init?(message m: Message) {
        guard m.role == .approval, let approvalID = m.meta.approvalId else { return nil }
        id = approvalID
        chatId = m.chatId
        botId = m.meta.authorId ?? (ChatGroup.isGroupID(m.chatId) ? nil : m.chatId)
        kind = m.meta.kind
        title = m.meta.title
        createdAt = m.createdAt
        expiresAt = m.createdAt.addingTimeInterval(Self.defaultLifetime)
        taskId = m.meta.taskId
        requestedBy = m.meta.requestedBy?.name
        message = m
    }

    func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

/// Chat-Lauf, der gerade arbeitet (ohne Hintergrund-Aufgaben), mit letzter Statuszeile.
nonisolated struct TodayRun: Codable, Hashable, Identifiable, Sendable {
    var chatId: String
    /// Arbeitender Scoop (in Gruppen der Akteur)
    var botId: String?
    var runId: String?
    var messageId: String?
    var line: String?
    var steps: Int?
    var startedAt: Date?
    var usesComputer: Bool?

    var id: String { chatId }
}

/// Routine oder Erinnerung, die heute noch läuft.
nonisolated struct TodayPlanned: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// routine | erinnerung
    var kind: String
    var botId: String
    var title: String
    var at: Date
    var scheduleText: String?
    /// Weitere Läufe heute nach dem nächsten (z. B. stündliche Routine)
    var moreToday: Int?

    var isReminder: Bool { kind == "erinnerung" }
}

/// Routine oder Erinnerung, die seit dem letzten Besuch gelaufen ist.
nonisolated struct TodayRoutineDone: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: String
    var botId: String
    var title: String
    var at: Date

    var isReminder: Bool { kind == "erinnerung" }
}

/// Antwort von `GET /api/today`.
nonisolated struct TodayOverview: Codable, Sendable {
    /// Beginn von „Seit gestern erledigt“ (24 Stunden bzw. letzter Besuch, höchstens 7 Tage)
    var since: Date?
    var approvals: [TodayApproval]?
    /// In Arbeit, zu prüfen, heute geplant und seit `since` abgeschlossen; die App ordnet sie den Abschnitten zu
    var tasks: [BotTask]?
    var running: [TodayRun]?
    var planned: [TodayPlanned]?
    var routinesDone: [TodayRoutineDone]?
}

/// Endpunkt der Seite. `APIClient` und `MockService` erfüllen das Protokoll; Gäste geteilter Scoops haben keinen
/// Zugriff (der Server antwortet dort 403).
protocol TodayService: AnyObject {
    /// `since`: letzter Besuch der Seite (für „Seit gestern erledigt“)
    func todayOverview(since: Date?) async throws -> TodayOverview
}
