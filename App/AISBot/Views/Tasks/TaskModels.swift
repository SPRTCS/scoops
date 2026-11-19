import Foundation

// MARK: - Aufgaben-Board (Server 1.22, docs/aufgaben.md „Board“)

/// Aktionen auf einer Aufgabe (`POST /api/tasks/{id}/<aktion>`).
nonisolated enum TaskAction: String, Sendable {
    /// Offene oder geplante Aufgabe sofort starten
    case start
    /// Laufende Aufgabe anhalten
    case stop
    /// Fortsetzen (nach Fehler, Stopp, Limit, Rückfrage) mit optionalem Hinweis
    case resume = "continue"
    /// Abnahme: „Erledigt“
    case accept
    /// „Nacharbeiten“ mit Hinweis (setzt die Aufgabe fort)
    case rework
    case archive
    /// Aus dem Archiv zurück
    case restore
}

/// Neue Aufgabe (`POST /api/tasks`): ohne `scheduledAt` startet sie sofort, sonst landet sie unter „Geplant“.
nonisolated struct TaskDraft: Encodable, Sendable {
    var chatId: String
    /// Arbeitender Scoop (in Gruppen Pflicht, im Einzelchat = Chat)
    var actorId: String?
    var prompt: String
    var title: String?
    /// `nil` = „Wie Scoop“
    var model: String?
    var scheduledAt: Date?
    /// Nur sammeln (Spalte „Offen“, Server 1.23): startet erst auf Wunsch
    var backlog: Bool?
    /// v1.29: Bereich am Mac nur für diese Aufgabe (`nil` = wie Scoop)
    var access: TaskAccessChoice? = nil
}

/// Änderung einer offenen oder geplanten Aufgabe (`PATCH /api/tasks/{id}`). Nur gesetzte Felder werden übertragen.
nonisolated struct TaskPatch: Encodable, Sendable {
    var title: String?
    var prompt: String?
    /// `TaskPatch.sameAsScoop` setzt auf „Wie Scoop“ zurück
    var model: String?
    /// Termin setzen; bei einer offenen Aufgabe heißt das „Offen“ → „Geplant“
    var scheduledAt: Date?
    /// `true`: zurück nach „Offen“ (Termin entfällt)
    var backlog: Bool?
    /// v1.29: Bereich ändern; `TaskAccessChoice.sameAsScoop` = wie Scoop
    var access: TaskAccessChoice? = nil

    static let sameAsScoop = "wie_scoop"
}

/// Board-Endpunkte. `APIClient` und `MockService` erfüllen das Protokoll; Gäste geteilter Scoops haben keinen Zugriff
/// (der Server antwortet dort 403).
protocol TaskBoardService: AnyObject {
    /// Alle Aufgaben über alle Scoops (neueste zuerst), optional nur ein Scoop
    func boardTasks(botID: String?, limit: Int) async throws -> [BotTask]
    /// Eine Aufgabe mit Schritt-Verlauf und Dateien
    func task(id: String) async throws -> BotTask
    func createTask(_ draft: TaskDraft) async throws -> BotTask
    func updateTask(id: String, patch: TaskPatch) async throws -> BotTask
    /// Nur geplante Aufgaben
    func deleteTask(id: String) async throws
    func taskAction(id: String, action: TaskAction, message: String?) async throws -> BotTask
}

/// Formular „Aufgabe“ (Plus-Menü im Chat, Board, Bearbeiten einer geplanten Aufgabe).
struct TaskFormRequest: Identifiable, Hashable {
    var id = UUID()
    /// Fester Chat (aus dem Composer); `nil` = Scoop im Formular wählen
    var chatID: String?
    /// Geplante Aufgabe bearbeiten
    var editing: BotTask?
    /// Mit Termin starten (Board-Spalte „Geplant“)
    var scheduled = false
    /// Nur sammeln (Board-Spalte „Offen“)
    var backlog = false
}
