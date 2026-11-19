import Foundation

// MARK: - Demo-Daten und Mock-Server für das Aufgaben-Board (`-mock`)

extension PreviewData {
    static var tasks: [BotTask] {
        let now = PreviewData.now
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        func task(_ id: String, _ bot: String, _ title: String, state: String, review: String? = nil, model: String,
                  cost: Double = 0, minutes: Double = 0, steps: Int = 0, created: Date, started: Date? = nil,
                  finished: Date? = nil, scheduled: Date? = nil, note: String? = nil, waitingFor: String? = nil,
                  waitingKind: String? = nil, prompt: String, result: String? = nil, error: String? = nil) -> BotTask {
            BotTask(id: id, botId: bot, chatId: bot, title: title, prompt: prompt, origin: "scoop", engine: "claude",
                    model: model, modelChoice: nil, state: state, review: review, column: nil, costUsd: cost,
                    budgetUsd: 3, maxMinutes: 60, activeMinutes: minutes, steps: steps, result: result, error: error,
                    note: note, waitingFor: waitingFor, waitingKind: waitingKind, files: [], fileItems: nil, lines: nil,
                    createdAt: created, startedAt: started, finishedAt: finished, scheduledAt: scheduled,
                    reviewedAt: review == "done" || review == "archived" ? finished : nil,
                    archivedAt: review == "archived" ? finished : nil, updatedAt: now, statusMessageId: nil)
        }
        let tomorrow8 = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                              of: now.addingTimeInterval(86_400)) ?? now
        var list = [
            task("t_ordner", "b_nora", "Steuerordner 2026 vorbereiten", state: "open", model: "claude-sonnet-5-5",
                 created: ago(90), prompt: "Lege die Ordnerstruktur für die Steuer 2026 an und sortiere die vorhandenen Belege ein."),
            task("t_ideen", "b_lio", "Ideen für YouTube-Serie sammeln", state: "open", model: "claude-sonnet-5-5",
                 created: ago(20), prompt: "Sammle zehn Ideen für eine YouTube-Serie über KI-Assistenten im Alltag."),
            task("t_wochen", "b_theo", "Wochenrückblick Wettbewerb", state: "scheduled", model: "claude-sonnet-5-5",
                 created: ago(30), scheduled: tomorrow8,
                 prompt: "Fasse die Neuigkeiten der fünf wichtigsten Wettbewerber dieser Woche zusammen."),
            task("t_post", "b_lio", "Launch-Post auf X vom AIS-Konto", state: "running", model: "claude-sonnet-5-5",
                 cost: 0.18, minutes: 3.2, steps: 14, created: ago(5), started: ago(4),
                 note: "Ins AIS-Konto gewechselt, Entwurf steht",
                 prompt: "Wechsle im Browser auf X zum Konto @ais_consulting und poste den Launch-Text mit Bild."),
            task("t_belege", "b_nora", "Belege Oktober abgleichen", state: "waiting", model: "claude-opus-5-5",
                 cost: 0.42, minutes: 9.5, steps: 31, created: ago(50), started: ago(48),
                 waitingFor: "Zwei Amex-Buchungen ohne Beleg: Soll ich bei den Händlern nachfragen?", waitingKind: "frage",
                 prompt: "Gleiche die Belege im Ordner Oktober mit Amex und N26 ab und liste fehlende auf."),
            task("t_bericht", "b_theo", "Marktbericht Pflegeroboter", state: "done", review: "review",
                 model: "claude-sonnet-5-5", cost: 0.64, minutes: 12.4, steps: 46, created: ago(180), started: ago(178),
                 finished: ago(160),
                 prompt: "Recherchiere den Markt für Pflegeroboter in DACH und schreib einen Bericht (PDF).",
                 result: "**Kurzfassung:** Der Markt wächst um ~18 % pro Jahr, getrieben von Personalmangel.\n\n- 12 Anbieter verglichen\n- Bericht als PDF in der Bibliothek"),
            task("t_crm", "b_mila", "Kontakte ins CRM übertragen", state: "failed", review: "review", model: "gpt-6.2-sol",
                 cost: 0.21, minutes: 4.1, steps: 18, created: ago(300), started: ago(298), finished: ago(290),
                 prompt: "Übertrage die neuen Kontakte aus der Tabelle in das CRM.",
                 error: "Anmeldung beim CRM abgelaufen."),
            task("t_reise", "b_pip", "Reiseplan Lissabon", state: "done", review: "done", model: "claude-haiku-5-5",
                 cost: 0.05, minutes: 2.0, steps: 9, created: ago(1500), started: ago(1499), finished: ago(1490),
                 prompt: "Plane drei Tage Lissabon mit Hotels, Restaurants und Wegen.", result: "Reiseplan liegt als PDF vor."),
            task("t_alt", "b_mila", "Newsletter-Entwurf", state: "done", review: "archived", model: "claude-haiku-5-5",
                 cost: 0.03, minutes: 1.1, steps: 5, created: ago(6000), started: ago(5999), finished: ago(5990),
                 prompt: "Entwirf den Newsletter für November."),
            task("t_mailcheck", "b_mila", "Mail-Check 10:00", state: "done", review: "done", model: "claude-haiku-5-5",
                 cost: 0.02, minutes: 0.8, steps: 4, created: ago(40), started: ago(40), finished: ago(39),
                 prompt: "Neue Mails prüfen und Wichtiges melden.", result: "Zwei neue Mails, nichts Dringendes."),
        ]
        if let i = list.firstIndex(where: { $0.id == "t_mailcheck" }) {
            list[i].routineId = "rt_demo"
            list[i].routineTitle = "Mail-Check"
        }
        // Rechner-Zugriff (v1.29): Standard, dazu eine Aufgabe mit Projektordner
        for i in list.indices {
            let bot = PreviewData.bots.first { $0.id == list[i].botId }
            let choice: TaskAccessChoice? = list[i].id == "t_ordner"
                ? TaskAccessChoice(scope: "projects", folders: ["~/Documents/Steuern"]) : nil
            list[i].access = MockService.mockAccess(bot: bot, choice: choice)
        }
        return list
    }
}

/// Aufgaben im Demo-Modus (eigener Speicher, damit `MockService` unverändert bleibt).
final class MockTaskStore {
    static let shared = MockTaskStore()
    var tasks: [BotTask] = PreviewData.tasks
    private var counter = 0

    func nextID() -> String {
        counter += 1
        return "t_mock\(counter)"
    }
}

extension MockService: TaskBoardService {
    private var store: MockTaskStore { .shared }

    private func publish(_ t: BotTask) -> BotTask {
        if let i = store.tasks.firstIndex(where: { $0.id == t.id }) { store.tasks[i] = t } else { store.tasks.insert(t, at: 0) }
        onEvent?(.taskUpdated(t))
        return t
    }

    private func find(_ id: String) throws -> BotTask {
        guard let t = store.tasks.first(where: { $0.id == id }) else { throw APIError(status: 404, message: "Aufgabe nicht gefunden") }
        return t
    }

    func boardTasks(botID: String?, limit: Int) async throws -> [BotTask] {
        Array(store.tasks.filter { botID == nil || $0.botId == botID }.prefix(limit))
    }

    func task(id: String) async throws -> BotTask {
        var t = try find(id)
        if t.lines == nil, (t.steps ?? 0) > 0 {
            t.lines = ["Liest den Auftrag", "Sucht im Web: \(t.title)", "Arbeitet am Bildschirm", "Schreibt Ergebnis.md"]
        }
        return t
    }

    func createTask(_ draft: TaskDraft) async throws -> BotTask {
        let scheduled = draft.scheduledAt.flatMap { $0 > Date().addingTimeInterval(30) ? $0 : nil }
        let actor = draft.actorId ?? draft.chatId
        let t = BotTask(id: store.nextID(), botId: actor, chatId: draft.chatId,
                        title: draft.title ?? String(draft.prompt.prefix(60)), prompt: draft.prompt, origin: "board",
                        engine: "claude", model: draft.model ?? "claude-sonnet-5-5", modelChoice: draft.model,
                        state: draft.backlog == true ? "open" : (scheduled == nil ? "running" : "scheduled"),
                        costUsd: 0, budgetUsd: 3, maxMinutes: 60, activeMinutes: 0, steps: 0, createdAt: Date(),
                        startedAt: scheduled == nil && draft.backlog != true ? Date() : nil,
                        scheduledAt: scheduled, updatedAt: Date(),
                        access: Self.mockAccess(bot: PreviewData.bots.first { $0.id == actor }, choice: draft.access))
        return publish(t)
    }

    /// Rechner-Zugriff wie der Server: Modus des Scoops, Bereich der Aufgabe bzw. des Scoops
    static func mockAccess(bot: Bot?, choice: TaskAccessChoice?) -> TaskAccess {
        let b = bot?.computerAccess ?? ScoopAccess()
        let scope = choice?.accessScope ?? b.accessScope
        let folders = choice?.accessScope == nil ? b.folders : (choice?.folders ?? [])
        return TaskAccess(mode: b.mode, scope: scope.rawValue, folders: folders, modeLabel: b.accessMode.title,
                          scopeLabel: scope.title, label: "\(b.accessMode.title) · \(scope.text(folders: folders))",
                          custom: choice?.accessScope != nil)
    }

    func updateTask(id: String, patch: TaskPatch) async throws -> BotTask {
        var t = try find(id)
        guard t.isNotStarted else { throw APIError(status: 409, message: "Nur offene oder geplante Aufgaben lassen sich ändern.") }
        t.column = nil
        if let v = patch.title { t.title = v }
        if let v = patch.prompt { t.prompt = v }
        if let v = patch.model { t.modelChoice = v == TaskPatch.sameAsScoop ? nil : v }
        if let v = patch.access {
            t.access = Self.mockAccess(bot: PreviewData.bots.first { $0.id == t.botId }, choice: v.accessScope == nil ? nil : v)
        }
        if patch.backlog == true {
            t.state = "open"; t.scheduledAt = nil
        } else if let v = patch.scheduledAt {
            t.scheduledAt = v; t.state = "scheduled"
        }
        return publish(t)
    }

    func deleteTask(id: String) async throws {
        store.tasks.removeAll { $0.id == id }
        onEvent?(.taskDeleted(id: id))
    }

    func taskAction(id: String, action: TaskAction, message: String?) async throws -> BotTask {
        var t = try find(id)
        t.column = nil
        switch action {
        case .start: t.state = "running"; t.startedAt = Date(); t.scheduledAt = nil
        case .stop: t.state = "stopped"; t.review = "review"; t.finishedAt = Date()
        case .resume, .rework: t.state = "running"; t.review = nil; t.waitingFor = nil
        case .accept: t.review = "done"; t.reviewedAt = Date()
        case .archive: t.review = "archived"; t.archivedAt = Date()
        case .restore: t.review = t.reviewedAt == nil ? "review" : "done"; t.archivedAt = nil
        }
        return publish(t)
    }
}
