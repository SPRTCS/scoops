import Foundation
import Observation

/// Zustand des Aufgaben-Boards: Liste aller Aufgaben (alle Scoops), Filter, Aktionen.
///
/// Live: Der Server meldet Änderungen als `task.updated`/`task.deleted`; Statuskarten (`message.updated` mit
/// `meta.task`) aktualisieren Zustand, Kosten und Schritte sofort. Solange das Board sichtbar ist, lädt es zusätzlich
/// alle 20 s nach (falls ein Ereignis verloren geht).
@Observable
final class TaskBoardStore {
    private(set) var tasks: [BotTask] = []
    private(set) var loaded = false
    private(set) var loading = false
    /// Server kennt das Board noch nicht (vor 1.22) oder Gast-Verbindung
    private(set) var unavailable: String?
    /// Filter: nur dieser Scoop (`nil` = alle)
    var filterBotID: String?
    /// Suche im Board: Titel, Beschreibung und Scoop (zusammen mit dem Scoop-Filter, in allen Ansichten)
    var searchText = ""
    /// Suchfeld des Boards fokussieren (⌘F, solange das Board offen ist)
    var searchFocusRequest = 0
    /// Details, die gerade offen sind (mit Verlauf und Dateien)
    private(set) var details: [String: BotTask] = [:]
    /// Aktion läuft (Knöpfe sperren)
    private(set) var busyIDs: Set<String> = []
    /// Archiv: archivierte Aufgaben nach so vielen Tagen automatisch löschen (0 = nie, `nil` = noch nicht geladen)
    private(set) var archiveDays: Int?
    /// „Archiv leeren“ läuft
    private(set) var clearingArchive = false

    /// Setzt der AppStore (eigene Server-Verbindung, Fehleranzeige)
    @ObservationIgnored var service: () -> TaskBoardService? = { nil }
    @ObservationIgnored var onError: (Error) -> Void = { _ in }
    /// Namen zum Durchsuchen (Scoop mit Rolle, bei Gruppen der Chat); setzt der AppStore
    @ObservationIgnored var searchNames: (BotTask) -> [String] = { _ in [] }
    /// Server kann das Archiv aufräumen (1.40, `task_archive_cleanup` in /api/health); setzt der AppStore
    @ObservationIgnored var supportsArchiveCleanup: () -> Bool = { false }
    @ObservationIgnored private var detailReload: [String: Task<Void, Never>] = [:]

    /// Verbindung gewechselt: alles vergessen
    func reset() {
        tasks = []
        details = [:]
        loaded = false
        unavailable = nil
        filterBotID = nil
        searchText = ""
        archiveDays = nil
    }

    // MARK: Abfragen

    /// Suchbegriff ohne Leerraum außen (leer = keine Suche)
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !searchQuery.isEmpty }

    /// Jedes Wort der Suche muss in Titel, Beschreibung, Routine oder Scoop vorkommen (Groß-/Kleinschreibung und
    /// Umlaute egal, wie in der Befehlspalette).
    private func matcher() -> (BotTask) -> Bool {
        let tokens = Fuzzy.fold(searchQuery).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return { _ in true } }
        let names = searchNames
        return { task in
            let hay = Fuzzy.fold(([task.title, task.prompt ?? "", task.routineTitle ?? ""] + names(task)).joined(separator: "\n"))
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    func tasks(in column: TaskColumn) -> [BotTask] {
        let matches = matcher()
        let list = tasks.filter { $0.boardColumn == column && (filterBotID == nil || $0.botId == filterBotID) && matches($0) }
        switch column {
        case .open:
            // neueste oben
            return list.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .planned:
            // nächster Termin zuerst
            return list.sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
        case .active:
            // Rückfragen/Freigaben zuerst, dann nach Start
            return list.sorted {
                if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
                return ($0.startedAt ?? $0.createdAt ?? .distantPast) > ($1.startedAt ?? $1.createdAt ?? .distantPast)
            }
        case .review:
            // Probleme zuerst, dann neueste
            return list.sorted {
                if $0.isProblem != $1.isProblem { return $0.isProblem }
                return ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast)
            }
        case .done:
            return list.sorted { ($0.reviewedAt ?? $0.finishedAt ?? .distantPast) > ($1.reviewedAt ?? $1.finishedAt ?? .distantPast) }
        case .archived:
            return list.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        }
    }

    func count(_ column: TaskColumn) -> Int { tasks(in: column).count }

    func task(_ id: String) -> BotTask? { details[id] ?? tasks.first { $0.id == id } }

    /// Scoops, die Aufgaben haben (für den Filter)
    var botIDs: [String] { Array(Set(tasks.map(\.botId))).sorted() }

    /// Badge für die Leiste: Rückfragen/Freigaben + zu Prüfendes
    var attentionCount: Int {
        tasks.filter { ($0.isWaiting && $0.waitingKind != "scoop") || $0.boardColumn == .review }.count
    }

    func isBusy(_ id: String) -> Bool { busyIDs.contains(id) }

    // MARK: Laden

    func load() async {
        guard let service = service() else {
            unavailable = String(localized: "Das Aufgaben-Board gibt es nur auf deinem eigenen Server.")
            return
        }
        loading = true
        defer { loading = false }
        do {
            tasks = try await service.boardTasks(botID: nil, limit: 300)
            loaded = true
            unavailable = nil
        } catch let error as APIError where error.status == 404 || error.status == 405 {
            unavailable = String(localized: "Dein Server kennt das Aufgaben-Board noch nicht. Bitte auf Version 1.22 aktualisieren.")
        } catch let error as APIError where error.status == 403 {
            unavailable = String(localized: "Aufgaben sieht nur der Admin des Servers.")
        } catch {
            if !loaded { onError(error) }
        }
    }

    func loadDetail(_ id: String) async {
        guard let service = service() else { return }
        do {
            let t = try await service.task(id: id)
            details[id] = t
            upsert(t, keepDetail: false)
        } catch { onError(error) }
    }

    func closeDetail(_ id: String) {
        details[id] = nil
        detailReload[id]?.cancel()
        detailReload[id] = nil
    }

    // MARK: Ereignisse

    /// `task.updated`
    func apply(_ task: BotTask) {
        upsert(task, keepDetail: true)
        if details[task.id] != nil { scheduleDetailReload(task.id) }
    }

    /// `task.deleted`
    func remove(id: String) {
        tasks.removeAll { $0.id == id }
        details[id] = nil
    }

    /// Statuskarte einer Aufgabe geändert (`message.updated` mit `meta.task`): Schritte, Kosten, Zwischenstand sofort.
    func applyStatus(_ message: Message) {
        guard let info = message.meta.task, let idx = tasks.firstIndex(where: { $0.id == info.id }) else { return }
        var t = tasks[idx]
        if let s = info.state, s != t.state {
            t.state = s
            if s == "running" || s == "queued" { t.column = TaskColumn.active.rawValue }
        }
        if let lines = message.meta.lines { t.steps = lines.count }
        if let c = message.meta.costUsd { t.costUsd = c }
        if let n = info.note { t.note = n }
        tasks[idx] = t
        if var d = details[info.id] {
            d.state = t.state
            d.steps = t.steps
            d.costUsd = t.costUsd
            d.note = t.note
            if let lines = message.meta.lines { d.lines = lines }
            details[info.id] = d
        }
    }

    private func upsert(_ task: BotTask, keepDetail: Bool) {
        var t = task
        if let idx = tasks.firstIndex(where: { $0.id == t.id }) {
            // Listen-Einträge tragen keinen Verlauf; vorhandene Detail-Felder nicht verlieren
            if t.lines == nil { t.lines = tasks[idx].lines }
            tasks[idx] = t
        } else {
            tasks.insert(t, at: 0)
        }
        if keepDetail, var d = details[t.id] {
            let lines = d.lines, items = d.fileItems
            d = t
            d.lines = t.lines ?? lines
            d.fileItems = t.fileItems ?? items
            details[t.id] = d
        }
    }

    /// Detail nach einer Änderung nachladen (Dateien, Bericht), höchstens einmal pro Sekunde.
    private func scheduleDetailReload(_ id: String) {
        guard detailReload[id] == nil else { return }
        detailReload[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.detailReload[id] = nil
            if self.details[id] != nil { await self.loadDetail(id) }
        }
    }

    // MARK: Aktionen

    @discardableResult
    func create(_ draft: TaskDraft) async -> BotTask? {
        guard let service = service() else { return nil }
        do {
            let t = try await service.createTask(draft)
            upsert(t, keepDetail: true)
            return t
        } catch {
            onError(error)
            return nil
        }
    }

    @discardableResult
    func update(_ id: String, patch: TaskPatch) async -> Bool {
        await perform(id) { try await $0.updateTask(id: id, patch: patch) }
    }

    @discardableResult
    func perform(_ id: String, _ action: TaskAction, message: String? = nil) async -> Bool {
        await perform(id) { try await $0.taskAction(id: id, action: action, message: message) }
    }

    /// Sammelaktion (z. B. „Alle abhaken“, „Alle archivieren“): nacheinander, Fehler einzeln gemeldet.
    func performAll(_ ids: [String], _ action: TaskAction) async {
        for id in ids { _ = await perform(id, action) }
    }

    func delete(_ id: String) async {
        guard let service = service() else { return }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            try await service.deleteTask(id: id)
            remove(id: id)
        } catch { onError(error) }
    }

    private func perform(_ id: String, _ call: (TaskBoardService) async throws -> BotTask) async -> Bool {
        guard let service = service() else { return false }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            let t = try await call(service)
            upsert(t, keepDetail: true)
            if details[id] != nil { scheduleDetailReload(id) }
            return true
        } catch {
            onError(error)
            return false
        }
    }

    // MARK: Archiv aufräumen (Server 1.40)

    func loadArchiveDays() async {
        guard supportsArchiveCleanup(), let service = service() else { return }
        if let days = try? await service.taskArchiveDays() { archiveDays = days }
    }

    func setArchiveDays(_ days: Int) async {
        guard let service = service() else { return }
        let previous = archiveDays
        archiveDays = days
        do {
            archiveDays = try await service.setTaskArchiveDays(days)
        } catch {
            archiveDays = previous
            onError(error)
        }
    }

    /// „Archiv leeren“: alle archivierten Aufgaben, bei gesetztem Scoop-Filter nur die dieses Scoops.
    func clearArchive() async {
        guard let service = service() else { return }
        clearingArchive = true
        defer { clearingArchive = false }
        let bot = filterBotID
        do {
            _ = try await service.clearTaskArchive(botID: bot)
            tasks.removeAll { $0.boardColumn == .archived && (bot == nil || $0.botId == bot) }
        } catch { onError(error) }
    }

    // MARK: Drag & Drop

    /// Erlaubte Züge zwischen Spalten (sonst Knöpfe/Kontextmenü).
    func dropAction(_ task: BotTask, to column: TaskColumn) -> TaskAction? {
        switch (task.boardColumn, column) {
        case (.planned, .active), (.open, .active): return .start
        case (.review, .done): return task.isProblem ? nil : .accept
        case (.review, .archived), (.done, .archived): return .archive
        case (.archived, .done), (.archived, .review): return .restore
        default: return nil
        }
    }

    /// Ablegen in einer Spalte: `true`, wenn der Zug erlaubt war.
    func drop(taskID: String, on column: TaskColumn) -> Bool {
        guard let t = task(taskID) else { return false }
        if t.isScheduled && column == .open {
            Task { await update(taskID, patch: TaskPatch(backlog: true)) }
            return true
        }
        guard let action = dropAction(t, to: column) else { return false }
        Task { await perform(taskID, action) }
        return true
    }
}
