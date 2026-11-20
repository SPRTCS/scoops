import SwiftUI

/// Detail einer Aufgabe: Auftrag, Schritt-Verlauf, Bericht, Dateien, Kosten und die passenden Knöpfe
/// (Anhalten, Fortsetzen, Erledigt, Nacharbeiten, Archivieren, Zum Chat).
struct TaskDetailView: View {
    let taskID: String
    var onOpenChat: (BotTask) -> Void
    var onEdit: (BotTask) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var hint = ""
    @State private var answer = ""
    @State private var confirmDelete = false
    @State private var showAllLines = false
    @FocusState private var hintFocused: Bool

    private var board: TaskBoardStore { store.taskBoard }
    private var task: BotTask? { board.task(taskID) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(task?.title ?? String(localized: "Aufgabe"), icon: "checklist") { dismiss() }
            if let task {
                ScrollView {
                    GroupedStack {
                        summary(task)
                        if task.isWaiting { waitingSection(task) }
                        actions(task)
                        if [.review, .done].contains(task.boardColumn) { reworkSection(task) }
                        if let p = task.prompt, !p.isEmpty {
                            GroupedSection("Auftrag") {
                                Text(p)
                                    .appFont(14)
                                    .foregroundStyle(theme.textPrimary)
                                    .textSelection(.enabled)
                                    .groupedRow()
                            }
                        }
                        stepsSection(task)
                        if let r = task.result, !r.isEmpty {
                            GroupedSection("Bericht") {
                                MarkdownView(text: r)
                                    .textSelection(.enabled)
                                    .groupedRow(vertical: 12)
                            }
                        }
                        if let e = task.error, !e.isEmpty {
                            GroupedSection("Fehler") {
                                Text(e).appFont(13).foregroundStyle(theme.danger).textSelection(.enabled)
                                    .groupedRow()
                            }
                        }
                        filesSection(task)
                        timesSection(task)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        .task { await board.loadDetail(taskID) }
        .onDisappear { board.closeDetail(taskID) }
        .confirmationDialog(task?.isOpen == true ? "Offene Aufgabe löschen?" : "Geplante Aufgabe löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task { await board.delete(taskID); dismiss() }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 720)
        #else
        .presentationDetents([.large])
        #endif
    }

    // MARK: Kopf

    private func summary(_ task: BotTask) -> some View {
        let bot = store.bot(task.botId)
        return GroupedSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let bot {
                        MascotView(mascot: bot.mascot, size: 36, mood: task.isRunning ? .working : .idle, seed: bot.id,
                                   animated: task.isRunning)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot?.name ?? "Scoop")
                            .appFont(15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        HStack(spacing: 5) {
                            Image(systemName: task.stateSymbol)
                                .symbolEffect(.rotate, isActive: task.state == "running")
                            Text(task.stateLabel)
                        }
                        .appFont(13, weight: .medium)
                        .foregroundStyle(TaskStyle.color(for: task, theme: theme))
                    }
                    Spacer(minLength: 0)
                }
                if task.isRoutine {
                    TaskRoutineBadge(title: task.routineTitle)
                    Text("Läufe einer Routine kommen fertig direkt unter „Abgeschlossen“. Verbessern lässt sich die Routine selbst.")
                        .appFont(12)
                        .foregroundStyle(theme.textTertiary)
                }
                if task.isScheduled, let at = task.scheduledAt {
                    Label("Startet \(Formatting.dayTime(at))", systemImage: "calendar.badge.clock")
                        .appFont(13.5, weight: .medium)
                        .foregroundStyle(theme.accent)
                }
                if task.isActive, let note = task.note, !note.isEmpty {
                    Text(note).appFont(13).foregroundStyle(theme.textSecondary)
                }
                TaskFacts(task: task, size: 12.5)
                if let access = task.access { TaskAccessDetail(access: access) }
                if let b = task.budgetUsd, !task.isNotStarted {
                    Text(limitText(b, maxMinutes: task.maxMinutes))
                        .appFont(11.5)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .groupedRow(vertical: 12)
        }
    }

    /// „Limit 2,00 $ · 30 min Arbeitszeit“
    private func limitText(_ budget: Double, maxMinutes: Int?) -> String {
        let limit = Formatting.usd(budget)
        guard let minutes = maxMinutes else { return String(localized: "Limit \(limit)", comment: "Kostenlimit einer Aufgabe") }
        return String(localized: "Limit \(limit) · \(minutes) min Arbeitszeit", comment: "Kostenlimit und Zeitlimit einer Aufgabe")
    }

    // MARK: Wartet auf Arman

    private func waitingSection(_ task: BotTask) -> some View {
        GroupedSection(task.waitingKind == "frage" ? String(localized: "Rückfrage") : String(localized: "Freigabe"),
                       footer: task.waitingKind == "frage" ? String(localized: "Deine Antwort geht direkt an die Aufgabe, sie arbeitet dann weiter.")
                       : String(localized: "Die Freigabe-Karte steht im Chat.")) {
            VStack(alignment: .leading, spacing: 10) {
                if let w = task.waitingFor, !w.isEmpty {
                    Text(w).appFont(14).foregroundStyle(theme.textPrimary).textSelection(.enabled)
                }
                if task.waitingKind == "frage" {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Antwort", text: $answer, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button("Senden") {
                            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { if await board.perform(task.id, .resume, message: text) { answer = "" } }
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || board.isBusy(task.id))
                    }
                } else {
                    Button { onOpenChat(task) } label: { Label("Zur Freigabe im Chat", systemImage: "hand.raised") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
            }
            .groupedRow(vertical: 12)
        }
    }

    // MARK: Knöpfe

    private func actions(_ task: BotTask) -> some View {
        let busy = board.isBusy(task.id)
        return TaskFlowLayout(spacing: 8, lineSpacing: 8) {
            switch task.boardColumn {
            case .open:
                pill("Jetzt starten", "play.fill", .primary) { await board.perform(task.id, .start) }
                Button { onEdit(task) } label: { Label("Planen oder ändern", systemImage: "calendar") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
            case .planned:
                pill("Sofort starten", "play.fill", .primary) { await board.perform(task.id, .start) }
                Button { onEdit(task) } label: { Label("Ändern", systemImage: "calendar") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                pill("Zurück zu Offen", "tray", .secondary) { await board.update(task.id, patch: TaskPatch(backlog: true)) }
                Button { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
            case .active:
                pill("Anhalten", "stop.circle", .secondary) { await board.perform(task.id, .stop) }
            case .review:
                if task.isProblem {
                    pill("Fortsetzen", "arrow.clockwise", .primary) { await board.perform(task.id, .resume) }
                } else {
                    pill("Erledigt", "checkmark.seal", .primary) { await board.perform(task.id, .accept) }
                }
                pill("Archivieren", "archivebox", .secondary) { await board.perform(task.id, .archive) }
            case .done:
                pill("Archivieren", "archivebox", .secondary) { await board.perform(task.id, .archive) }
            case .archived:
                pill("Wiederherstellen", "arrow.uturn.backward.circle", .primary) { await board.perform(task.id, .restore) }
            }
            Button { onOpenChat(task) } label: { Label("Zum Chat", systemImage: "bubble.left.and.bubble.right") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .disabled(busy)
    }

    private func pill(_ title: LocalizedStringKey, _ icon: String, _ kind: PillButtonStyle.Kind,
                      _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: icon) }
            .buttonStyle(PillButtonStyle(kind: kind))
    }

    private func reworkSection(_ task: BotTask) -> some View {
        GroupedSection("Nacharbeiten", footer: "Der Scoop setzt die Aufgabe mit deinem Hinweis im selben Arbeitsordner fort.") {
            // Große Schrift: Knopf unter dem Eingabefeld
            AdaptiveStack(horizontalAlignment: .trailing, verticalAlignment: .bottom, spacing: 8) {
                TextField("Was fehlt oder soll anders sein?", text: $hint, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($hintFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Nacharbeiten") {
                    let text = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await board.perform(task.id, .rework, message: text) { hint = "" } }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || board.isBusy(task.id))
            }
            .groupedRow(vertical: 12)
        }
    }

    // MARK: Verlauf, Dateien, Zeiten

    @ViewBuilder private func stepsSection(_ task: BotTask) -> some View {
        let lines = task.lines ?? []
        if !lines.isEmpty {
            let shown = showAllLines || lines.count <= 12 ? lines : Array(lines.suffix(12))
            GroupedSection(String(localized: "Verlauf · \(lines.count) Schritte", comment: "Überschrift: Schritte einer Aufgabe")) {
                VStack(alignment: .leading, spacing: 6) {
                    if shown.count < lines.count {
                        Button("Alle \(lines.count) Schritte zeigen") { showAllLines = true }
                            .buttonStyle(.borderless)
                            .appFont(12.5, weight: .medium)
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { idx, line in
                        let current = task.isRunning && idx == shown.count - 1
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: current ? "circle.dotted" : "checkmark")
                                .appFont(10, weight: .bold)
                                .foregroundStyle(current ? theme.accent : theme.textTertiary)
                                .scaledFrame(width: 14)
                                .symbolEffect(.rotate, isActive: current)
                            Text(line)
                                .appFont(13)
                                .foregroundStyle(current ? theme.textPrimary : theme.textSecondary)
                        }
                    }
                }
                .groupedRow(vertical: 12)
            }
        }
    }

    @ViewBuilder private func filesSection(_ task: BotTask) -> some View {
        let items = task.fileItems ?? []
        if !items.isEmpty {
            GroupedSection("Dateien", dividerInset: 50) {
                ForEach(items) { file in
                    Button {
                        Task { if let url = await store.download(file) { store.previewURL = url } }
                    } label: {
                        GroupedLabelRow(icon: file.symbolName, title: file.name, subtitle: file.sizeText) {
                            Image(systemName: "eye").foregroundStyle(theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(file.name) öffnen")
                }
            }
        }
    }

    private func timesSection(_ task: BotTask) -> some View {
        GroupedSection {
            if let d = task.createdAt { row("Angelegt", d) }
            if let d = task.startedAt { row("Gestartet", d) }
            if let d = task.finishedAt { row("Beendet", d) }
            if let d = task.reviewedAt { row("Abgenommen", d) }
            if let d = task.archivedAt { row("Archiviert", d) }
        }
    }

    private func row(_ title: LocalizedStringResource, _ date: Date) -> some View {
        GroupedLabelRow(title: title) {
            Text(Formatting.dayTime(date)).appFont(14).foregroundStyle(theme.textSecondary)
        }
    }
}
