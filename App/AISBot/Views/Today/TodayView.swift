import SwiftUI

/// Seite „Heute“: der Startpunkt über alle Scoops. Zeigt nur, was es gibt: offene Freigaben (mit denselben Karten wie
/// im Chat), Aufgaben zum Prüfen, was gerade läuft, was heute noch ansteht und was seit dem letzten Besuch erledigt
/// wurde. Ohne Inhalt ein freundlicher leerer Zustand.
///
/// iPad/Mac: in der Mitte, solange kein Chat gewählt ist. iPhone: im Stapel über der Chatliste (`inStack`).
struct TodayView: View {
    /// iPhone: Titel steht in der Navigationsleiste
    var inStack = false

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var detail: IdentifiedString?
    @State private var form: TaskFormRequest?
    /// „Ablehnen“ auf einer Karte unter „Zum Prüfen“: optionaler Kommentar, dann zurück in Arbeit
    @State private var rejecting: BotTask?
    @State private var rejectNote = ""

    private var today: TodayStore { store.today }

    private var isCompact: Bool {
        #if os(iOS)
        inStack || sizeClass == .compact
        #else
        false
        #endif
    }

    // MARK: Inhalte

    private var unread: [AppStore.ChatEntry] { store.unreadChats }

    private var planned: [TodayPlannedItem] {
        (today.plannedRoutines.map(TodayPlannedItem.routine) + today.plannedTasks.map(TodayPlannedItem.task))
            .sorted { $0.date < $1.date }
    }

    private var done: [TodayDoneItem] {
        (today.doneTasks.map(TodayDoneItem.task) + today.routinesDone.map(TodayDoneItem.routine))
            .sorted { $0.date > $1.date }
    }

    private var waitingCount: Int { today.waitingCount }
    private var runningCount: Int { today.runningChats.count + today.runningTasks.count }

    private var hasWaiting: Bool { !today.approvalItems.isEmpty || !today.questions.isEmpty }

    private var isEmpty: Bool {
        !hasWaiting && today.review.isEmpty && runningCount == 0 && planned.isEmpty && done.isEmpty && unread.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !today.loaded {
                    loadingState
                } else if isEmpty {
                    emptyState
                } else {
                    if hasWaiting { waitingSection }
                    if !today.review.isEmpty { reviewSection }
                    if runningCount > 0 { runningSection }
                    if !planned.isEmpty { plannedSection }
                    if !done.isEmpty || !unread.isEmpty { doneSection }
                }
            }
            .padding(.horizontal, isCompact ? 16 : 28)
            .padding(.top, isCompact ? 6 : 18)
            .padding(.bottom, 48)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.3), value: today.approvalItems.map(\.id))
        }
        .scrollIndicators(.automatic)
        .background(theme.background.ignoresSafeArea())
        .refreshable { await today.load() }
        .task {
            // Live über Ereignisse; als Rückfall jede Minute abgleichen, solange die Seite sichtbar ist (Fristen,
            // Tageswechsel, verpasste Ereignisse)
            today.pageAppeared()
            // Auch beim erneuten Öffnen abgleichen (eine Anfrage): sonst stünde ein verpasstes Ereignis bis zu einer
            // Minute nicht auf der Seite. Der Stand von eben bleibt solange sichtbar.
            await today.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await today.load()
            }
        }
        .onDisappear { today.pageLeft() }
        // Server kennt die Seite nicht mehr (z. B. Verbindung gewechselt): auf dem iPhone zurück zur Chatliste
        .onChange(of: today.available) { _, available in if !available { store.showToday = false } }
        .onChange(of: scenePhase) { _, phase in
            // Der Besuch endet auch, wenn die App in den Hintergrund geht
            if phase == .active { today.pageAppeared() } else { today.pageLeft() }
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
        #if os(iOS)
        .navigationTitle(inStack ? "Heute" : "")
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !inStack {
                    Text("Heute")
                        .appFont(28, weight: .bold)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(today.clock.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Formatting.locale)))
                    .appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                if today.loaded, !isEmpty {
                    Text(summary)
                        .appFont(15)
                        .foregroundStyle(waitingCount > 0 ? theme.textPrimary : theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if today.loading && today.loaded { ProgressView().controlSize(.small).padding(.top, 8) }
            #if os(macOS)
            CircleIconButton(systemName: "arrow.clockwise", help: "Aktualisieren (⌘R)", size: 30) {
                Task { await today.load() }
            }
            .keyboardShortcut("r", modifiers: .command)
            #endif
        }
    }

    /// Ein Satz, der sagt, worum es heute geht
    private var summary: String {
        var parts: [String] = []
        if let waiting = today.waitingText { parts.append(waiting) }
        let review = today.review.count
        if review > 0 { parts.append(String(localized: "\(review) Aufgaben zum Prüfen")) }
        let running = runningCount
        if running > 0 { parts.append(String(localized: "\(running) Scoops arbeiten")) }
        if parts.isEmpty { return String(localized: "Gerade wartet nichts auf dich.") }
        return parts.joined(separator: " · ")
    }

    // MARK: Laden und leerer Zustand

    @ViewBuilder private var loadingState: some View {
        if let error = today.loadError {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").appFont(32, weight: .medium).foregroundStyle(theme.warning)
                Text(error).font(.callout).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                Button("Neu versuchen") { Task { await today.load() } }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        }
    }

    private var emptyState: some View {
        let bot = store.primaryBot ?? store.bots.first
        return VStack(spacing: 14) {
            MascotView(mascot: bot?.mascot ?? .brand, size: 112, seed: bot?.id ?? "app-icon", showsGround: true)
                .accessibilityHidden(true)
            Text(store.bots.isEmpty ? "Leg deinen ersten Scoop an" : "Alles ruhig")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text(store.bots.isEmpty
                 ? "Er bekommt einen Namen, einen Charakter und ein eigenes Gedächtnis. Was er für dich erledigt, siehst du dann hier."
                 : "Gerade wartet nichts auf dich. Braucht ein Scoop eine Freigabe oder ist eine Aufgabe fertig, steht es hier.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            AdaptiveButtonRow(spacing: 10) {
                if store.bots.isEmpty {
                    Button("Neuer Scoop") { store.editingBot = nil; store.showCreateBot = true }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                } else {
                    Button("Neue Aufgabe") { form = TaskFormRequest() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Aufgaben öffnen") { store.showTaskBoard = true }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isCompact ? 56 : 90)
        .padding(.bottom, 20)
    }

    // MARK: 1. Wartet auf dich

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TodaySectionHeader(title: String(localized: "Wartet auf dich"), icon: "hand.raised.fill", tint: theme.warning, count: waitingCount)
            ForEach(today.approvalItems) { approval in
                TodayApprovalItem(approval: approval, settled: today.settling.contains(approval.id))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            ForEach(today.questions) { task in
                TodayQuestionCard(task: task) { detail = IdentifiedString(id: task.id) }
            }
        }
    }

    // MARK: 2. Zum Prüfen

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodaySectionHeader(title: String(localized: "Zum Prüfen"), icon: "eye.fill", tint: ComposerMode.task.color, count: today.review.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(today.review) { task in reviewCard(task) }
            }
        }
    }

    /// Board-Karte mit den Schnellknöpfen des Boards: Abhaken/Ablehnen bzw. Fortsetzen bei einem Problem
    private func reviewCard(_ task: BotTask) -> some View {
        let id = task.id
        let accept: (() -> Void)? = task.isProblem ? nil : { Task { await store.taskBoard.perform(id, .accept) } }
        let decline: (() -> Void)? = task.isProblem ? nil : { rejectNote = ""; rejecting = task }
        let resume: (() -> Void)? = task.isProblem ? { Task { await store.taskBoard.perform(id, .resume) } } : nil
        return TaskCardView(task: task, onAccept: accept, onReject: decline, onResume: resume,
                            busy: store.taskBoard.isBusy(id))
            .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .onTapGesture { detail = IdentifiedString(id: id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detail = IdentifiedString(id: id) }
            .contextMenu {
                TaskActionButtons(task: task, onOpenChat: openChat,
                                  onEdit: { form = TaskFormRequest(editing: $0) },
                                  onDetail: { detail = IdentifiedString(id: $0.id) })
            }
    }

    // MARK: 3. Läuft gerade

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodaySectionHeader(title: String(localized: "Läuft gerade"), icon: "bolt.fill", tint: theme.accent, count: runningCount)
            TodayListCard {
                ForEach(today.runningChats) { run in
                    TodayRunRow(run: run)
                }
                ForEach(today.runningTasks) { task in
                    TodayRunningTaskRow(task: task) { detail = IdentifiedString(id: task.id) }
                }
            }
        }
    }

    // MARK: 4. Heute geplant

    private var plannedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodaySectionHeader(title: String(localized: "Heute geplant"), icon: "calendar", tint: ComposerMode.routine.color, count: planned.count)
            TodayListCard {
                ForEach(planned) { item in
                    TodayPlannedRow(item: item) {
                        switch item {
                        case .routine(let r): store.openChatFromToday(r.botId)
                        case .task(let t): detail = IdentifiedString(id: t.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: 5. Seit gestern erledigt

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodaySectionHeader(title: doneTitle, icon: "checkmark.circle.fill", tint: theme.success,
                               count: done.count + unread.count)
            if !unread.isEmpty {
                TodayListCard {
                    ForEach(unread) { entry in TodayUnreadRow(entry: entry) }
                }
            }
            if !done.isEmpty {
                TodayListCard {
                    ForEach(done) { item in
                        TodayDoneRow(item: item, isNew: today.isNew(item.date)) {
                            switch item {
                            case .task(let t): detail = IdentifiedString(id: t.id)
                            case .routine(let r): store.openChatFromToday(r.botId)
                            }
                        }
                    }
                }
            }
        }
    }

    private var doneTitle: String {
        if done.isEmpty { return String(localized: "Ungelesen") }
        return today.reachesBackToLastVisit ? String(localized: "Seit deinem letzten Besuch erledigt") : String(localized: "Seit gestern erledigt")
    }

    // MARK: Aktionen

    private func openChat(_ task: BotTask) {
        detail = nil
        store.openChatFromToday(task.chatId, messageID: task.statusMessageId)
    }

    /// Ablehnen: Nacharbeit mit Kommentar (ohne Kommentar ein allgemeiner Hinweis), wie im Board.
    private func reject(_ task: BotTask) {
        let note = rejectNote.trimmingCharacters(in: .whitespacesAndNewlines)
        rejectNote = ""
        rejecting = nil
        let message = note.isEmpty
            ? String(localized: "Das Ergebnis passt so noch nicht. Prüf es kritisch gegen den Auftrag, verbessere es und schreib einen neuen Abschlussbericht.")
            : note
        Task { await store.taskBoard.perform(task.id, .rework, message: message) }
    }
}

/// „Heute geplant“: Routine, Erinnerung oder geplante Aufgabe
enum TodayPlannedItem: Identifiable {
    case routine(TodayPlanned)
    case task(BotTask)

    var id: String {
        switch self { case .routine(let r): "r:\(r.id)"; case .task(let t): "t:\(t.id)" }
    }
    var date: Date {
        switch self { case .routine(let r): r.at; case .task(let t): t.scheduledAt ?? .distantFuture }
    }
}

/// „Seit gestern erledigt“: abgenommene Aufgabe oder gelaufene Routine
enum TodayDoneItem: Identifiable {
    case task(BotTask)
    case routine(TodayRoutineDone)

    var id: String {
        switch self { case .task(let t): "t:\(t.id)"; case .routine(let r): "r:\(r.id)" }
    }
    var date: Date {
        switch self { case .task(let t): t.finishedAt ?? .distantPast; case .routine(let r): r.at }
    }
}
