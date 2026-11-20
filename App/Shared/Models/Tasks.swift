import Foundation

// MARK: - Aufgaben-Board (Server 1.22, docs/aufgaben.md „Board“)

/// Eine Hintergrund-Aufgabe, wie sie `GET /api/tasks` liefert (alle Scoops, nur der Admin).
nonisolated struct BotTask: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// Scoop, der arbeitet (in Gruppen der Akteur)
    var botId: String
    /// Chat (Einzelchat = Scoop-ID, Gruppe `g_…`)
    var chatId: String
    var title: String
    var prompt: String?
    /// scoop | user | board | approval
    var origin: String?
    var engine: String?
    /// Wirksames Modell (bei „Wie Scoop“ das aktuelle Modell des Scoops)
    var model: String?
    /// Gewähltes Modell, `nil` = „Wie Scoop“
    var modelChoice: String?
    /// Laufzustand: scheduled | queued | running | waiting | done | failed | stopped | limit
    var state: String
    /// Abnahme: review | done | archived (getrennt vom Laufzustand)
    var review: String?
    /// Spalte im Board: planned | active | review | done | archived
    var column: String?
    var costUsd: Double?
    var budgetUsd: Double?
    var maxMinutes: Int?
    var activeMinutes: Double?
    /// Schritte in der Statuskarte
    var steps: Int?
    /// Abschlussbericht des Arbeitslaufs
    var result: String?
    var error: String?
    /// letzter Zwischenstand
    var note: String?
    /// Rückfrage/Freigabe, auf die die Aufgabe wartet
    var waitingFor: String?
    /// frage | freigabe
    var waitingKind: String?
    /// Ergebnisdateien (IDs in der Bibliothek des Chats)
    var files: [String]?
    /// Nur im Detail (`GET /api/tasks/{id}`): Dateien mit Namen
    var fileItems: [LibraryFile]?
    /// Nur im Detail: Schritt-Verlauf wie in der Statuskarte
    var lines: [String]?
    var createdAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var scheduledAt: Date?
    var reviewedAt: Date?
    var archivedAt: Date?
    var updatedAt: Date?
    var statusMessageId: String?
    /// Aus einer Routine gestartet (Server 1.26): Kennzeichen im Board, fertig direkt „Abgeschlossen“
    var routineId: String?
    var routineTitle: String?
    /// v1.29: Rechner-Zugriff der Aufgabe (Modus des Scoops, Bereich der Aufgabe bzw. des Scoops)
    var access: TaskAccess? = nil

    var isRoutine: Bool { routineId != nil }

    var boardColumn: TaskColumn {
        if let column, let c = TaskColumn(rawValue: column) { return c }
        if state == "open" { return .open }
        if state == "scheduled" { return .planned }
        if review == "archived" { return .archived }
        if ["queued", "running", "waiting"].contains(state) { return .active }
        return review == "done" ? .done : .review
    }

    var isRunning: Bool { ["queued", "running"].contains(state) }
    var isWaiting: Bool { state == "waiting" }
    var isActive: Bool { isRunning || isWaiting }
    /// Abgebrochen, fehlgeschlagen, angehalten oder am Limit: deutlich markieren, „Fortsetzen“ anbieten
    var isProblem: Bool { ["failed", "stopped", "limit"].contains(state) }
    var isScheduled: Bool { state == "scheduled" }
    /// Spalte „Offen“ (Backlog, Server 1.23): gesammelt, startet erst auf Wunsch
    var isOpen: Bool { state == "open" }
    /// Noch nicht gestartet (offen oder geplant): bearbeiten, planen, löschen, sofort starten
    var isNotStarted: Bool { isOpen || isScheduled }

    /// Kurzer Zustand für Karte und Detail
    var stateLabel: String {
        switch state {
        case "open": return String(localized: "Offen", comment: "Aufgabe/Spalte im Board: noch nicht gestartet")
        case "scheduled": return String(localized: "Geplant", comment: "Aufgabe/Spalte im Board: mit Termin geplant")
        case "queued": return String(localized: "Wartet auf einen Platz")
        case "running": return String(localized: "Läuft", comment: "Zustand einer Aufgabe")
        case "waiting":
            if waitingKind == "scoop" {
                // `waitingFor` kommt vom Server (in der Sprache der App), z. B. „Antwort von Lio“
                return waitingFor.map { String(localized: "Wartet auf \($0)") } ?? String(localized: "Wartet auf anderen Scoop")
            }
            return waitingKind == "frage" ? String(localized: "Rückfrage an dich") : String(localized: "Wartet auf Freigabe")
        case "failed": return String(localized: "Fehlgeschlagen", comment: "Zustand einer Aufgabe")
        case "stopped": return String(localized: "Angehalten", comment: "Zustand einer Aufgabe")
        case "limit": return String(localized: "Am Limit angehalten")
        default:
            switch review {
            case "done": return String(localized: "Abgeschlossen", comment: "Aufgabe/Spalte im Board: abgenommen")
            case "archived": return String(localized: "Archiviert", comment: "Zustand einer Aufgabe")
            default: return String(localized: "Fertig – zu prüfen")
            }
        }
    }

    var stateSymbol: String {
        switch state {
        case "open": return "tray"
        case "scheduled": return "calendar.badge.clock"
        case "queued": return "hourglass"
        case "running": return "circle.dotted"
        case "waiting": return waitingKind == "frage" ? "questionmark.bubble"
            : waitingKind == "scoop" ? "bubble.left.and.bubble.right" : "hand.raised"
        case "failed": return "exclamationmark.triangle.fill"
        case "stopped": return "stop.circle"
        case "limit": return "gauge.with.dots.needle.100percent"
        default: return review == "archived" ? "archivebox" : "checkmark.circle.fill"
        }
    }

    /// Arbeitszeit in Sekunden (gezählt vom Server, ohne Wartezeit auf Freigaben)
    var activeSeconds: TimeInterval? { activeMinutes.map { $0 * 60 } }

    /// Zeit für die Karte: Termin (geplant), sonst Ende, Start oder Anlage
    var displayDate: Date? {
        if isScheduled { return scheduledAt }
        return finishedAt ?? startedAt ?? createdAt
    }

    var isOverdue: Bool { isScheduled && (scheduledAt.map { $0 < Date() } ?? false) }
}

/// Spalten des Boards (Archiv ist ein eigener Reiter).
nonisolated enum TaskColumn: String, CaseIterable, Identifiable, Sendable {
    case open, planned, active, review, done, archived

    var id: String { rawValue }
    static let board: [TaskColumn] = [.open, .planned, .active, .review, .done]

    var title: String {
        switch self {
        case .open: String(localized: "Offen", comment: "Aufgabe/Spalte im Board: noch nicht gestartet")
        case .planned: String(localized: "Geplant", comment: "Aufgabe/Spalte im Board: mit Termin geplant")
        case .active: String(localized: "In Arbeit", comment: "Spalte im Board: laufende Aufgaben")
        case .review: String(localized: "Zu prüfen", comment: "Spalte im Board: fertig, noch nicht abgenommen")
        case .done: String(localized: "Abgeschlossen", comment: "Aufgabe/Spalte im Board: abgenommen")
        case .archived: String(localized: "Archiv", comment: "Reiter im Board")
        }
    }

    var symbol: String {
        switch self {
        case .open: "tray"
        case .planned: "calendar"
        case .active: "bolt.horizontal.circle"
        case .review: "eye"
        case .done: "checkmark.seal"
        case .archived: "archivebox"
        }
    }

    var emptyText: String {
        switch self {
        case .open: String(localized: "Hier sammelst du Aufgaben, die noch nicht losgehen sollen. Sie starten erst, wenn du sie startest oder planst.")
        case .planned: String(localized: "Keine geplanten Aufgaben. Mit „+ Neue Aufgabe“ und einem Termin planst du eine.")
        case .active: String(localized: "Gerade arbeitet kein Scoop an einer Aufgabe.")
        case .review: String(localized: "Nichts zu prüfen.")
        case .done: String(localized: "Noch nichts abgenommen.")
        case .archived: String(localized: "Das Archiv ist leer.")
        }
    }
}

/// Rechner-Zugriff einer Aufgabe, wie der Server ihn anzeigt (Board und Detail).
nonisolated struct TaskAccess: Codable, Hashable, Sendable {
    var mode: String
    var scope: String
    var folders: [String]?
    var modeLabel: String?
    var scopeLabel: String?
    /// „Automatisch · Projektordner (~/Code/App)“
    var label: String?
    /// Eigener Bereich nur für diese Aufgabe (sonst wie Scoop)
    var custom: Bool?

    var accessMode: AccessMode { AccessMode(rawValue: mode) ?? .auto }
    var accessScope: AccessScope { AccessScope(rawValue: scope) ?? .workspace }
    var scopeText: String { accessScope.text(folders: folders ?? []) }
}
