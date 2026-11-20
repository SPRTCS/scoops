import SwiftUI

/// Aufgaben-Board (Kanban) über alle Scoops: Geplant → In Arbeit → Zu prüfen → Abgeschlossen, Archiv als eigener Reiter.
/// iPhone: Spalten per Segment; iPad/Mac: Spalten nebeneinander, horizontal scrollbar, Drag & Drop wo es passt.
struct TaskBoardView: View {
    /// Schließen (Blatt auf dem iPhone, zurück zum Chat auf Mac/iPad)
    var onClose: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private enum Tab: String, CaseIterable, Identifiable {
        case board, archive
        var id: String { rawValue }
        var title: String {
            self == .board ? String(localized: "Board", comment: "Reiter: Aufgaben-Board")
                : String(localized: "Archiv", comment: "Reiter im Board")
        }
    }

    @State private var tab: Tab = .board
    @State private var compactColumn: TaskColumn = .active
    @State private var detail: IdentifiedString?
    @State private var form: TaskFormRequest?
    @State private var dropTarget: TaskColumn?
    @State private var columnChosen = false
    /// „Ablehnen“ auf einer Karte unter „Zu prüfen“: optionaler Kommentar, dann zurück in Arbeit
    @State private var rejecting: BotTask?
    @State private var rejectNote = ""
    /// Rückfrage vor „Alle abhaken“ (Zu prüfen) bzw. „Alle archivieren“ (Abgeschlossen)
    @State private var bulkColumn: TaskColumn?
    @FocusState private var searchFocused: Bool

    private var board: TaskBoardStore { store.taskBoard }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let note = board.unavailable {
                unavailable(note)
            } else if !board.loaded && board.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if board.isSearching && searchHits == 0 {
                searchEmpty
            } else if tab == .archive {
                archive
            } else if isCompact {
                compactBoard
            } else {
                wideBoard
            }
        }
        .background(theme.background.ignoresSafeArea())
        // ⌘F („Aufgaben durchsuchen“ im Menü): Suchfeld des Boards fokussieren
        .onChange(of: board.searchFocusRequest) { searchFocused = true }
        .task {
            // Live über Ereignisse; als Rückfall alle 20 s nachladen, solange das Board sichtbar ist
            await board.load()
            if !columnChosen { compactColumn = initialColumn }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                await board.load()
            }
        }
        .sheet(item: $detail) { item in
            TaskDetailView(taskID: item.id, onOpenChat: openChat, onEdit: { form = TaskFormRequest(editing: $0) })
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .sheet(item: $form) { request in
            TaskFormView(request: request)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .alert("Zurück in Arbeit", isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } }),
               presenting: rejecting) { task in
            TextField("Kommentar (optional)", text: $rejectNote)
            Button("Zurück in Arbeit") { reject(task) }
            Button("Abbrechen", role: .cancel) {}
        } message: { task in
            if let name = store.bot(task.botId)?.name {
                Text("\(name) arbeitet „\(task.title)“ nach. Schreib dazu, was fehlt oder anders sein soll.")
            } else {
                Text("Der Scoop arbeitet „\(task.title)“ nach. Schreib dazu, was fehlt oder anders sein soll.")
            }
        }
    }

    // MARK: Sammelaktionen

    /// Ziele von „Alle abhaken“ (nur fertige, keine Probleme) bzw. „Alle archivieren“; Scoop-Filter gilt.
    private func bulkTargets(_ column: TaskColumn) -> [BotTask] {
        switch column {
        case .review: board.tasks(in: .review).filter { !$0.isProblem }
        case .done: board.tasks(in: .done)
        default: []
        }
    }

    private func bulkQuestion(_ column: TaskColumn) -> String {
        let n = bulkTargets(column).count
        return column == .review ? String(localized: "\(n) Aufgaben als abgeschlossen markieren?")
            : String(localized: "\(n) Aufgaben archivieren?")
    }

    private func runBulk(_ column: TaskColumn) {
        let ids = bulkTargets(column).map(\.id)
        bulkColumn = nil
        Task { await board.performAll(ids, column == .review ? .accept : .archive) }
    }

    /// Knopf oben in „Zu prüfen“ / „Abgeschlossen“ (nur, wenn es etwas zu tun gibt)
    @ViewBuilder private func bulkButton(_ column: TaskColumn) -> some View {
        if column == .review || column == .done, !bulkTargets(column).isEmpty {
            let review = column == .review
            Button { bulkColumn = column } label: {
                Label(review ? "Alle abhaken" : "Alle archivieren", systemImage: review ? "checkmark.circle" : "archivebox")
                    .appFont(12, weight: .semibold)
                    .adaptiveLineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(review ? theme.success : theme.textSecondary)
                    .background((review ? theme.success : theme.textSecondary).opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(review ? "Alle fertigen Aufgaben als abgeschlossen markieren" : "Alle abgeschlossenen Aufgaben archivieren")
            // Am Knopf selbst: auf iPad/Duo zeigt die Abfrage als Popover auf diesen Knopf statt an den Rand des Boards.
            .confirmationDialog(bulkQuestion(column),
                                isPresented: Binding(get: { bulkColumn == column }, set: { if !$0 { bulkColumn = nil } }),
                                titleVisibility: .visible) {
                Button(review ? "Alle abhaken" : "Alle archivieren") { runBulk(column) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(review ? "Fehlgeschlagene oder angehaltene Aufgaben bleiben unter „Zu prüfen“."
                     : "Archivierte Aufgaben findest du im Reiter „Archiv“ und kannst sie dort wiederherstellen.")
            }
        }
    }

    /// Ablehnen: Nacharbeit mit Kommentar (ohne Kommentar ein allgemeiner Hinweis), Karte springt nach „In Arbeit“.
    private func reject(_ task: BotTask) {
        let note = rejectNote.trimmingCharacters(in: .whitespacesAndNewlines)
        rejectNote = ""
        rejecting = nil
        let message = note.isEmpty
            ? String(localized: "Das Ergebnis passt so noch nicht. Prüf es kritisch gegen den Auftrag, verbessere es und schreib einen neuen Abschlussbericht.")
            : note
        Task { await board.perform(task.id, .rework, message: message) }
    }

    /// iPhone: mit der Spalte beginnen, in der etwas zu tun ist
    private var initialColumn: TaskColumn {
        if board.count(.review) > 0 { return .review }
        if board.count(.active) > 0 { return .active }
        if board.count(.planned) > 0 { return .planned }
        return .active
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").appFont(17, weight: .semibold).foregroundStyle(theme.textSecondary)
                Text("Aufgaben").appFont(20, weight: .bold).foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if board.loading && board.loaded { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                newButton
                CircleIconButton(systemName: "xmark", help: "Aufgaben schließen", size: 30, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Picker("Ansicht", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t == .archive && board.count(.archived) > 0 ? "\(t.title) \(board.count(.archived))" : t.title)
                            .tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 150, maxWidth: 220)
                .layoutPriority(1)
                filterMenu
                Spacer(minLength: 0)
                // Breit: Suche rechts in derselben Zeile; schmal (iPhone) in einer eigenen Zeile darunter
                if !isCompact { searchField.frame(minWidth: 150, maxWidth: 260).layoutPriority(2) }
            }
            if isCompact { searchField }
        }
        // Dichte Bedienelemente: wachsen bis zur größten normalen Stufe mit, darüber nicht weiter
        .dynamicTypeSize(...AppFont.controlCap)
        .padding(.horizontal, isCompact ? 16 : 22)
        .padding(.top, isCompact ? 14 : 18)
        .padding(.bottom, 12)
    }

    // MARK: Suche

    /// Suche nach Titel, Beschreibung und Scoop; gilt zusammen mit dem Scoop-Filter in Board und Archiv.
    private var searchField: some View {
        @Bindable var board = board
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").appFont(13).foregroundStyle(theme.textTertiary)
            TextField("Aufgaben durchsuchen", text: $board.searchText)
                .textFieldStyle(.plain)
                .appFont(13.5)
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                // Esc leert zuerst die Suche; ist sie leer, schließt Esc wie gewohnt das Board
                .onKeyPress(.escape) {
                    guard !board.searchText.isEmpty else { return .ignored }
                    board.searchText = ""
                    return .handled
                }
            if !board.searchText.isEmpty {
                Button { board.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").appFont(13).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(searchFocused ? theme.accent.opacity(0.6) : theme.surfaceBorder))
        .help("Aufgaben durchsuchen (⌘F)")
    }

    /// Treffer der Suche in der aktuellen Ansicht (Board: alle Spalten, Archiv: das Archiv)
    private var searchHits: Int {
        tab == .archive ? board.count(.archived) : TaskColumn.board.reduce(0) { $0 + board.count($1) }
    }

    private var searchEmptyText: String {
        let query = board.searchQuery
        return String(localized: "Keine Aufgabe passt zu „\(query)“.")
    }

    /// Leerer Text einer Spalte: bei der Suche der Hinweis auf den Suchbegriff
    private func emptyText(_ column: TaskColumn) -> String {
        board.isSearching ? searchEmptyText : column.emptyText
    }

    /// Kein Treffer in der ganzen Ansicht: ein Hinweis statt lauter leerer Spalten
    private var searchEmpty: some View {
        let elsewhere = tab == .archive ? TaskColumn.board.reduce(0) { $0 + board.count($1) } : board.count(.archived)
        return VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").appFont(34).foregroundStyle(theme.textTertiary)
            Text(searchEmptyText)
                .appFont(16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Group {
                if elsewhere > 0 {
                    Text(tab == .archive ? String(localized: "Im Board gibt es \(elsewhere) Treffer.")
                                         : String(localized: "Im Archiv gibt es \(elsewhere) Treffer."))
                } else if board.filterBotID != nil, let bot = store.bot(board.filterBotID) {
                    Text("Gesucht wird nur bei \(bot.name). Wähl „Alle Scoops“, um überall zu suchen.")
                } else {
                    Text("Gesucht wird in Titel, Beschreibung und Scoop.")
                }
            }
            .font(.callout)
            .foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center)
            AdaptiveButtonRow(spacing: 10) {
                Button("Suche leeren") { board.searchText = "" }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if elsewhere > 0 {
                    Button(tab == .archive ? "Zum Board" : "Zum Archiv") { tab = tab == .archive ? .board : .archive }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newButton: some View {
        // Schmal (iPhone, Duo zugeklappt): kurz „Neu“ oben in der Titelzeile, nie umbrechen
        Button { form = TaskFormRequest() } label: {
            Label(isCompact ? "Neu" : "Neue Aufgabe", systemImage: "plus")
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("Neue Aufgabe")
        .buttonStyle(PillButtonStyle(kind: .primary))
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .help("Neue Aufgabe (⇧⌘N)")
    }

    private var filterMenu: some View {
        Menu {
            Button { board.filterBotID = nil } label: {
                if board.filterBotID == nil { Label("Alle Scoops", systemImage: "checkmark") } else { Text("Alle Scoops") }
            }
            Divider()
            ForEach(store.bots) { bot in
                Button { board.filterBotID = bot.id } label: {
                    if board.filterBotID == bot.id { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let id = board.filterBotID, let bot = store.bot(id) {
                    MascotView(mascot: bot.mascot, size: 18, seed: bot.id, animated: false)
                    Text(bot.name)
                } else {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("Alle Scoops")
                }
                Image(systemName: "chevron.down").appFont(9, weight: .bold)
            }
            .appFont(13.5, weight: .medium)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.surfaceBorder))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Nach Scoop filtern")
    }

    private func unavailable(_ note: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist").appFont(36).foregroundStyle(theme.textTertiary)
            Text(note).font(.callout).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: iPad/Mac: Spalten nebeneinander

    private var wideBoard: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(TaskColumn.board) { column in
                    columnView(column)
                        // Große Schrift: breitere Spalten (höchstens 440 pt), sonst brechen Titel Wort für Wort um
                        .frame(width: min(440, AppFont.scaled(300, relativeTo: .footnote, in: dynamicTypeSize)))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }

    private func columnView(_ column: TaskColumn) -> some View {
        let items = board.tasks(in: column)
        let targeted = dropTarget == column
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: column.symbol).appFont(13, weight: .semibold)
                    Text(column.title).appFont(14, weight: .semibold).adaptiveLineLimit(1)
                    Text("\(items.count)")
                        .appFont(12, weight: .semibold).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(theme.hover, in: Capsule())
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if column == .planned || column == .open {
                    let label = column == .open ? String(localized: "Aufgabe sammeln") : String(localized: "Aufgabe planen")
                    Button { form = TaskFormRequest(scheduled: column == .planned, backlog: column == .open) } label: {
                        Image(systemName: "plus").appFont(13, weight: .semibold)
                            .scaledFrame(26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(label)
                    .accessibilityLabel(label)
                }
            }
            .foregroundStyle(theme.textSecondary)
            .frame(minHeight: 26)
            .padding(.horizontal, 4)
            // Sammelknopf (Zu prüfen / Abgeschlossen) in eigener Zeile: drückt die Überschrift nicht zusammen
            if !bulkTargets(column).isEmpty {
                bulkButton(column).padding(.horizontal, 2)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if items.isEmpty {
                        // Bei der Suche kurz: Der Suchbegriff steht im Feld, und meist haben andere Spalten Treffer
                        Text(board.isSearching ? String(localized: "Kein Treffer") : column.emptyText)
                            .appFont(12.5)
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    ForEach(items) { task in
                        card(task)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(targeted ? theme.accent : theme.surfaceBorder.opacity(0.6), lineWidth: targeted ? 2 : 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            if column == .planned, let t = board.task(id), t.isOpen {
                // Offen → Geplant: Termin wählen
                form = TaskFormRequest(editing: t, scheduled: true)
                return true
            }
            return board.drop(taskID: id, on: column)
        } isTargeted: { inside in
            if inside { dropTarget = column } else if dropTarget == column { dropTarget = nil }
        }
        .animation(.snappy(duration: 0.2), value: targeted)
    }

    // MARK: iPhone: eine Spalte, Wechsel per Segment

    private var compactBoard: some View {
        VStack(spacing: 10) {
            Picker("Spalte", selection: Binding(get: { compactColumn }, set: { compactColumn = $0; columnChosen = true })) {
                ForEach(TaskColumn.board) { c in
                    let n = board.count(c)
                    Text(n > 0 ? "\(c.shortTitle) \(n)" : c.shortTitle).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            if !bulkTargets(compactColumn).isEmpty {
                HStack {
                    Spacer()
                    bulkButton(compactColumn)
                }
                .padding(.horizontal, 16)
            }
            list(board.tasks(in: compactColumn), empty: emptyText(compactColumn))
        }
    }

    private var archive: some View {
        list(board.tasks(in: .archived), empty: emptyText(.archived), grid: !isCompact)
    }

    private func list(_ items: [BotTask], empty: String, grid: Bool = false) -> some View {
        ScrollView {
            if items.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity)
            } else if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 12)], spacing: 12) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: Karte

    private func card(_ task: BotTask) -> some View {
        let column = task.boardColumn
        let review = column == .review
        return TaskCardView(
            task: task,
            onAccept: review && !task.isProblem ? { Task { await board.perform(task.id, .accept) } } : nil,
            onReject: review && !task.isProblem ? { rejectNote = ""; rejecting = task } : nil,
            onResume: review && task.isProblem ? { Task { await board.perform(task.id, .resume) } } : nil,
            onStart: column == .open ? { Task { await board.perform(task.id, .start) } } : nil,
            onPlan: column == .open ? { form = TaskFormRequest(editing: task, scheduled: true) } : nil,
            busy: board.isBusy(task.id))
            .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .onTapGesture { detail = IdentifiedString(id: task.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detail = IdentifiedString(id: task.id) }
            .contextMenu {
                TaskActionButtons(task: task, onOpenChat: openChat,
                                  onEdit: { form = TaskFormRequest(editing: $0) },
                                  onDetail: { detail = IdentifiedString(id: $0.id) })
            }
            .draggable(task.id) {
                TaskCardView(task: task).frame(width: 280).environment(\.theme, theme).environment(store)
            }
    }

    private func openChat(_ task: BotTask) {
        detail = nil
        onClose()
        store.selectedChatID = task.chatId
        if let mid = task.statusMessageId {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                await store.jumpToMessage(mid, chatID: task.chatId)
            }
        }
    }
}

extension TaskColumn {
    /// Kurz fürs Segment auf dem iPhone
    var shortTitle: String {
        switch self {
        case .open: String(localized: "Offen", comment: "Aufgabe/Spalte im Board: noch nicht gestartet")
        // Eigener Schlüssel: Im schmalen Segment passt „Scheduled“ nicht, englisch dort „Planned“
        case .planned: String(localized: "board.short.planned", defaultValue: "Geplant",
                              comment: "Kurzer Spaltentitel im Board (iPhone-Segment): geplante Aufgaben, englisch „Planned“")
        case .active: String(localized: "Läuft", comment: "Kurzer Spaltentitel im Board: laufende Aufgaben")
        case .review: String(localized: "Prüfen", comment: "Kurzer Spaltentitel im Board: zu prüfende Aufgaben")
        case .done: String(localized: "Fertig", comment: "Kurzer Spaltentitel im Board: abgenommene Aufgaben")
        case .archived: String(localized: "Archiv", comment: "Reiter im Board")
        }
    }
}

// MARK: - Karte

/// Karte einer Aufgabe: Titel, Scoop, Zustand, Modell, Dauer, Kosten, Schritte, Zeit.
struct TaskCardView: View {
    let task: BotTask
    /// Schnellknöpfe auf der Karte (Board); ohne Knöpfe z. B. in der Drag-Vorschau
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    var onResume: (() -> Void)?
    var onStart: (() -> Void)?
    var onPlan: (() -> Void)?
    var busy = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var bot: Bot? { store.bot(task.botId) }

    private var hasActions: Bool {
        onAccept != nil || onReject != nil || onResume != nil || onStart != nil || onPlan != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            info
            if hasActions { actions }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(theme, radius: 14)
        .overlay(alignment: .leading) {
            if task.isProblem || task.isWaiting {
                RoundedRectangle(cornerRadius: 2).fill(stateColor).frame(width: 3).padding(.vertical, 12)
            }
        }
    }

    /// Abhaken/Ablehnen (Zu prüfen), Fortsetzen (Problem), Starten/Planen (Offen)
    private var actions: some View {
        AdaptiveButtonRow(spacing: 8) {
            if let onAccept { TaskCardButton(title: "Abhaken", icon: "checkmark", tint: theme.success, prominent: true, action: onAccept) }
            if let onReject { TaskCardButton(title: "Ablehnen", icon: "arrow.uturn.backward", tint: theme.warning, action: onReject) }
            if let onResume { TaskCardButton(title: "Fortsetzen", icon: "arrow.clockwise", tint: theme.accent, prominent: true, action: onResume) }
            if let onStart { TaskCardButton(title: "Starten", icon: "play.fill", tint: theme.accent, prominent: true, action: onStart) }
            if let onPlan { TaskCardButton(title: "Planen", icon: "calendar", tint: theme.textSecondary, action: onPlan) }
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                if let bot {
                    MascotView(mascot: bot.mascot, size: 26, mood: task.isRunning ? .working : .idle, seed: bot.id,
                               animated: task.isRunning)
                } else {
                    Circle().fill(theme.hover).frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .appFont(14.5, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .appFont(12)
                        .foregroundStyle(theme.textSecondary)
                        .adaptiveLineLimit(1)
                    if task.isRoutine { TaskRoutineBadge(title: task.routineTitle) }
                    if TaskAccessBadge.shows(task.access), let access = task.access { TaskAccessBadge(access: access) }
                }
                Spacer(minLength: 0)
            }
            stateRow
            if task.isActive, let note = task.note, !note.isEmpty {
                Text(note)
                    .appFont(12)
                    .foregroundStyle(theme.textSecondary)
                    .adaptiveLineLimit(2)
            }
            TaskFacts(task: task, size: 11.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(bot?.name ?? ""), \(task.stateLabel)")
    }

    private var subtitle: String {
        var parts: [String] = [bot?.name ?? "Scoop"]
        if ChatGroup.isGroupID(task.chatId) {
            let group = store.chatName(task.chatId)
            parts.append(String(localized: "in \(group)", comment: "Ort einer Freigabe: in einer Gruppe"))
        }
        return parts.joined(separator: " · ")
    }

    private var stateColor: Color { TaskStyle.color(for: task, theme: theme) }

    /// Termin einer geplanten Aufgabe („Startet gleich · Heute 10:05“)
    private var scheduleText: String {
        guard let at = task.scheduledAt else { return String(localized: "Ohne Termin") }
        let when = Formatting.dayTime(at)
        return task.isOverdue ? String(localized: "Startet gleich · \(when)") : when
    }

    @ViewBuilder private var stateRow: some View {
        if task.isOpen {
            Label("Noch nicht freigegeben", systemImage: "tray")
                .appFont(12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        } else if task.isScheduled {
            Label(scheduleText, systemImage: "calendar.badge.clock")
                .appFont(12, weight: .medium)
                .foregroundStyle(theme.accent)
        } else if task.isActive || task.isProblem {
            HStack(spacing: 5) {
                Image(systemName: task.stateSymbol)
                    .symbolEffect(.rotate, isActive: task.state == "running")
                Text(task.stateLabel)
            }
            .appFont(12, weight: .semibold)
            .foregroundStyle(stateColor)
        }
    }
}

/// Kennzahlen: Modell, Dauer, Kosten, Schritte, Zeit (umbrechend, für Dynamic Type).
struct TaskFacts: View {
    let task: BotTask
    var size: CGFloat = 12
    @Environment(\.theme) private var theme

    var body: some View {
        TaskFlowLayout(spacing: 10, lineSpacing: 4) {
            if let m = task.model {
                fact("cpu", BotModel.displayName(for: m))
            }
            if let s = task.activeSeconds, s > 0 { fact("timer", Formatting.duration(s)) }
            if let c = task.costUsd, c > 0 || !task.isNotStarted { fact("dollarsign.circle", Formatting.usd(c)) }
            if let n = task.steps, n > 0 { fact("list.bullet", String(localized: "\(n) Schritte", comment: "Anzahl Schritte einer Aufgabe")) }
            if !task.isScheduled, let d = task.displayDate { fact("clock", Formatting.dayTime(d)) }
        }
        .appFont(size)
        .foregroundStyle(theme.textTertiary)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).imageScale(.small)
            Text(text).monospacedDigit()
        }
        .adaptiveLineLimit(1)
    }
}

enum TaskStyle {
    static func color(for task: BotTask, theme: Theme) -> Color {
        switch task.state {
        case "failed": theme.danger
        case "stopped", "limit": theme.warning
        case "waiting": theme.warning
        case "running", "queued": theme.accent
        default: task.review == "done" ? theme.success : theme.textSecondary
        }
    }
}

/// Einfacher Fließ-Layout: Elemente nebeneinander, Umbruch bei Platzmangel.
struct TaskFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            width = max(width, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(width, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Aktionen (Kontextmenü)

/// Knöpfe je nach Spalte. Wird im Kontextmenü der Karte genutzt.
struct TaskActionButtons: View {
    let task: BotTask
    var onOpenChat: (BotTask) -> Void
    var onEdit: (BotTask) -> Void
    var onDetail: (BotTask) -> Void
    @Environment(AppStore.self) private var store

    private var board: TaskBoardStore { store.taskBoard }

    var body: some View {
        Button { onDetail(task) } label: { Label("Details", systemImage: "info.circle") }
        switch task.boardColumn {
        case .open:
            Button { act(.start) } label: { Label("Jetzt starten", systemImage: "play.fill") }
            Button { onEdit(task) } label: { Label("Planen oder ändern", systemImage: "calendar") }
            Button(role: .destructive) { Task { await board.delete(task.id) } } label: { Label("Löschen", systemImage: "trash") }
        case .planned:
            Button { act(.start) } label: { Label("Sofort starten", systemImage: "play.fill") }
            Button { onEdit(task) } label: { Label("Termin oder Auftrag ändern", systemImage: "calendar") }
            Button { Task { await board.update(task.id, patch: TaskPatch(backlog: true)) } } label: {
                Label("Zurück zu Offen", systemImage: "tray")
            }
            Button(role: .destructive) { Task { await board.delete(task.id) } } label: { Label("Löschen", systemImage: "trash") }
        case .active:
            Button { act(.stop) } label: { Label("Anhalten", systemImage: "stop.circle") }
        case .review:
            if task.isProblem {
                Button { act(.resume) } label: { Label("Fortsetzen", systemImage: "arrow.clockwise") }
            } else {
                Button { act(.accept) } label: { Label("Erledigt", systemImage: "checkmark.seal") }
            }
            Button { onDetail(task) } label: { Label("Nacharbeiten …", systemImage: "arrow.uturn.backward") }
            Button { act(.archive) } label: { Label("Archivieren", systemImage: "archivebox") }
        case .done:
            Button { act(.archive) } label: { Label("Archivieren", systemImage: "archivebox") }
        case .archived:
            Button { act(.restore) } label: { Label("Wiederherstellen", systemImage: "arrow.uturn.backward.circle") }
        }
        Divider()
        Button { onOpenChat(task) } label: { Label("Zum Chat", systemImage: "bubble.left.and.bubble.right") }
    }

    private func act(_ action: TaskAction) {
        Task { await board.perform(task.id, action) }
    }
}

/// Kennzeichen „Routine“ (Farbe und Symbol wie der Routine-Modus im Eingabefeld).
struct TaskRoutineBadge: View {
    var title: String?

    var body: some View {
        let mode = ComposerMode.routine
        Label(title.map { name in String(localized: "Routine · \(name)") } ?? String(localized: "Routine"), systemImage: mode.icon)
            .appFont(11.5, weight: .semibold)
            .adaptiveLineLimit(1)
            .foregroundStyle(mode.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(mode.color.opacity(0.13), in: Capsule())
            .padding(.top, 3)
            .accessibilityLabel(title.map { name in String(localized: "Aus der Routine \(name)") } ?? String(localized: "Aus einer Routine"))
    }
}

/// Kleiner Knopf auf einer Board-Karte (gleich breit nebeneinander).
struct TaskCardButton: View {
    let title: LocalizedStringKey
    let icon: String
    let tint: Color
    var prominent = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .appFont(12.5, weight: .semibold)
                .labelStyle(.titleAndIcon)
                .adaptiveLineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(tint)
                .background(tint.opacity(prominent ? 0.16 : 0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(prominent ? 0.3 : 0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Einstieg (Mac-Seitenleiste)

/// Runder Knopf „Aufgaben“ in der Kopfzeile der Seitenleiste (Mac), mit Punkt, wenn etwas auf Arman wartet.
struct TaskBoardCircleButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let attention = store.taskBoard.attentionCount
        Button { store.showTaskBoard.toggle() } label: {
            CircleIconLabel(systemName: "checklist")
                .overlay(alignment: .topTrailing) {
                    if attention > 0 {
                        Text("\(min(attention, 99))")
                            .appFont(9.5, weight: .bold).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(ComposerMode.task.color, in: Capsule())
                            .offset(x: 3, y: -3)
                    }
                }
                .overlay {
                    if store.showTaskBoard {
                        Circle().strokeBorder(ComposerMode.task.color, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .option])
        .help("Aufgaben (⌥⌘A)")
        .accessibilityLabel(attention > 0 ? "Aufgaben, \(attention) brauchen dich" : "Aufgaben")
        // Zahl am Knopf: einmal laden, auch wenn das Board noch nie offen war
        .task { if !store.taskBoard.loaded, store.phase == .online { await store.taskBoard.load() } }
    }
}
