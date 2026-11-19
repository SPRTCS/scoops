import SwiftUI

/// Formular „Neue Aufgabe“ (Board) bzw. „Aufgabe ändern“ (offen oder geplant): Scoop, Auftrag, Titel, Start, Modell.
/// Start: sofort, mit Termin (Spalte „Geplant“) oder nur sammeln (Spalte „Offen“, startet erst auf Wunsch).
struct TaskFormView: View {
    let request: TaskFormRequest

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var chatID: String = ""
    @State private var actorID: String = ""
    @State private var prompt = ""
    @State private var title = ""
    @State private var startMode: TaskStartMode = .now
    @State private var date = TaskSchedule.defaultDate()
    @State private var model: String?
    /// v1.29: Bereich am Mac (`nil` = wie Scoop)
    @State private var access: TaskAccessChoice?
    @State private var saving = false
    @State private var prepared = false
    @FocusState private var promptFocused: Bool

    private var board: TaskBoardStore { store.taskBoard }
    private var editing: BotTask? { request.editing }
    private var isGroup: Bool { ChatGroup.isGroupID(chatID) }
    /// Scoops, die im gewählten Chat arbeiten können
    private var candidates: [Bot] { isGroup ? store.members(of: chatID) : store.bots }
    private var actor: Bot? { store.bot(actorID) }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !actorID.isEmpty && !saving
            && (startMode != .scheduled || date > Date().addingTimeInterval(-60))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(editing == nil ? "Neue Aufgabe" : "Aufgabe ändern", icon: "checklist") { dismiss() }
            ScrollView {
                GroupedStack {
                    if editing == nil && request.chatID == nil { scoopSection }
                    GroupedSection("Auftrag", footer: "Ziel, Umfang und gewünschtes Ergebnis – die Aufgabe arbeitet selbstständig.") {
                        TextField("Was soll erledigt werden?", text: $prompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(4...14)
                            .focused($promptFocused)
                            .font(.system(size: 15))
                            .groupedRow(vertical: 12)
                        TextField("Titel (optional)", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .groupedRow()
                    }
                    GroupedSection("Start", footer: startMode.footer) {
                        Picker("Start", selection: $startMode.animation(.snappy(duration: 0.2))) {
                            ForEach(editing == nil ? TaskStartMode.allCases : [.open, .scheduled]) { m in
                                Label(m.title, systemImage: m.icon).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .groupedRow()
                        if startMode == .scheduled {
                            DatePicker("Start", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                .font(.system(size: 15))
                                .groupedRow()
                        }
                    }
                    GroupedSection("Modell") {
                        GroupedLabelRow(icon: "cpu", title: "Modell") {
                            TaskModelMenu(model: $model, scoopModel: actor?.model)
                        }
                    }
                    if actor?.computerAccess != nil {
                        GroupedSection("Bereich am Mac", footer: scopeFooter) {
                            GroupedLabelRow(icon: (access?.accessScope ?? actor?.computerAccess?.accessScope ?? .workspace).icon,
                                            title: "Bereich") {
                                TaskScopeMenu(choice: $access, bot: actor)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        .onAppear(perform: prepare)
        #if os(macOS)
        .frame(width: 520, height: 640)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var scoopSection: some View {
        GroupedSection("Scoop") {
            Menu {
                ForEach(store.bots) { bot in
                    Button {
                        chatID = bot.id
                        actorID = bot.id
                    } label: {
                        if bot.id == actorID { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if let actor {
                        MascotView(mascot: actor.mascot, size: 26, seed: actor.id, animated: false)
                        Text(actor.name).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                    } else {
                        Text("Scoop wählen").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .groupedRow()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Scoop: \(actor?.name ?? "keiner gewählt")")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if editing == nil && request.chatID != nil && isGroup && candidates.count > 1 {
                Picker("Scoop", selection: $actorID) {
                    ForEach(candidates) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button("Abbrechen") { dismiss() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button(saveTitle) { Task { await save() } }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.groupedBackground)
    }

    private var scopeFooter: String {
        let mode = actor?.computerAccess?.accessMode ?? .auto
        return "Wo die Aufgabe auf dem Mac lesen und schreiben darf. Modus des Scoops: \(mode.title)."
    }

    private var saveTitle: String {
        if editing != nil { return "Sichern" }
        return startMode.saveTitle
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let t = editing {
            chatID = t.chatId
            actorID = t.botId
            prompt = t.prompt ?? ""
            title = t.title
            startMode = request.scheduled || t.isScheduled ? .scheduled : .open
            date = t.scheduledAt ?? TaskSchedule.defaultDate()
            model = t.modelChoice
            if let a = t.access, a.custom == true { access = TaskAccessChoice(scope: a.scope, folders: a.folders) }
            return
        }
        startMode = request.backlog ? .open : (request.scheduled ? .scheduled : .now)
        if let id = request.chatID {
            chatID = id
            actorID = ChatGroup.isGroupID(id) ? (store.members(of: id).first?.id ?? "") : id
        } else {
            let preferred = board.filterBotID ?? store.selectedChatID.flatMap { store.bot($0)?.id } ?? store.bots.first?.id
            chatID = preferred ?? ""
            actorID = preferred ?? ""
        }
        promptFocused = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = editing {
            let patch = TaskPatch(title: t.isEmpty ? nil : t, prompt: p, model: model ?? TaskPatch.sameAsScoop,
                                  scheduledAt: startMode == .scheduled ? date : nil,
                                  backlog: startMode == .open && !task.isOpen ? true : nil,
                                  access: actor?.computerAccess == nil ? nil : (access ?? .sameAsScoop))
            if await board.update(task.id, patch: patch) { dismiss() }
            return
        }
        let draft = TaskDraft(chatId: chatID, actorId: actorID, prompt: p, title: t.isEmpty ? nil : t, model: model,
                              scheduledAt: startMode == .scheduled ? date : nil, backlog: startMode == .open ? true : nil,
                              access: access)
        if let created = await board.create(draft) {
            store.showToast(created.isOpen ? "Unter „Offen“ gesammelt"
                            : created.isScheduled ? "Aufgabe geplant: \(Formatting.dayTime(created.scheduledAt ?? date))"
                            : "Aufgabe gestartet")
            dismiss()
        }
    }
}

/// Start einer Aufgabe im Formular
enum TaskStartMode: String, CaseIterable, Identifiable {
    case now, scheduled, open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Sofort"
        case .scheduled: "Termin"
        case .open: "Offen"
        }
    }

    var icon: String {
        switch self {
        case .now: "bolt.fill"
        case .scheduled: "calendar.badge.clock"
        case .open: "tray"
        }
    }

    var saveTitle: String {
        switch self {
        case .now: "Starten"
        case .scheduled: "Planen"
        case .open: "Sammeln"
        }
    }

    var footer: String {
        switch self {
        case .now: "Die Aufgabe startet sofort."
        case .scheduled: "Die Aufgabe startet zu diesem Zeitpunkt von selbst (auch nach einem Neustart des Servers)."
        case .open: "Die Aufgabe wartet unter „Offen“, bis du sie startest oder planst. Der Scoop fängt nicht von selbst an."
        }
    }
}

// MARK: - Modell- und Terminwahl (Formular und Eingabefeld)

/// Modell der Aufgabe: „Wie Scoop“ oder ein bestimmtes Modell (Liste wie bei Routinen).
struct TaskModelMenu: View {
    @Binding var model: String?
    var scoopModel: String?
    /// Kompakte Pille (Eingabefeld) statt Zeilenwert (Formular)
    var pill = false
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            choice(nil, "Wie Scoop" + (scoopModel.map { " (\(BotModel.displayName(for: $0)))" } ?? ""))
            ForEach(ModelProvider.allCases) { provider in
                Section(provider.title) {
                    ForEach(BotModel.choices(of: provider)) { m in choice(m.id, m.label) }
                }
            }
        } label: {
            if pill {
                TaskPillLabel(icon: "cpu", text: model.map { BotModel.displayName(for: $0) } ?? "Wie Scoop",
                              active: model != nil)
            } else {
                HStack(spacing: 4) {
                    Text(model.map { BotModel.displayName(for: $0) } ?? "Wie Scoop")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 14.5))
                .foregroundStyle(theme.textSecondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Modell: \(model.map { BotModel.displayName(for: $0) } ?? "wie Scoop")")
    }

    private func choice(_ id: String?, _ title: String) -> some View {
        Button { model = id } label: {
            if model == id { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Termin der Aufgabe im Eingabefeld: Menü mit Schnellwahl (Jetzt, In 1 h, Heute Abend, Morgen früh, Offen sammeln)
/// und „Datum und Uhrzeit …“ in einem eigenen Blatt. Vorher ein Popover mit Kalender, das über der Tastatur keinen
/// Platz hatte (iPhone Duo hoch und quer: abgeschnitten).
struct TaskSchedulePill: View {
    @Binding var date: Date?
    @Binding var backlog: Bool
    @State private var showPicker = false
    @State private var draft = TaskSchedule.defaultDate()
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            choice("Jetzt", icon: "bolt.fill", nil)
            choice("In 1 Stunde", icon: "clock", Date().addingTimeInterval(3600))
            if let evening = TaskSchedule.today(hour: 19) {
                choice("Heute Abend · 19:00", icon: "moon", evening)
            }
            if let morning = TaskSchedule.tomorrow(hour: 8) {
                choice("Morgen früh · 8:00", icon: "sunrise", morning)
            }
            Divider()
            Button {
                draft = date ?? TaskSchedule.defaultDate()
                showPicker = true
            } label: { Label("Datum und Uhrzeit …", systemImage: "calendar") }
            Divider()
            Button {
                backlog = true
                date = nil
            } label: {
                if backlog { Label("Offen sammeln", systemImage: "checkmark") } else { Label("Offen sammeln", systemImage: "tray") }
            }
        } label: {
            if backlog {
                TaskPillLabel(icon: "tray", text: "Offen", active: true)
            } else {
                TaskPillLabel(icon: date == nil ? "bolt.fill" : "calendar.badge.clock",
                              text: date.map { Formatting.dayTime($0) } ?? "Jetzt", active: date != nil)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(backlog ? "Nur sammeln – startet erst, wenn du sie im Board startest"
              : date == nil ? "Startet sofort – tippen für einen Termin" : "Geplanter Start")
        .accessibilityLabel(backlog ? "Start: offen, nur sammeln"
                            : date.map { "Start: \(Formatting.dayTime($0))" } ?? "Start: sofort")
        .sheet(isPresented: $showPicker) {
            TaskDateSheet(draft: $draft) {
                backlog = false
                date = draft
                showPicker = false
            } onCancel: { showPicker = false }
            .environment(\.theme, theme)
            .preferredColorScheme(theme.preferredScheme)
        }
    }

    private func choice(_ title: String, icon: String, _ value: Date?) -> some View {
        Button {
            backlog = false
            date = value
        } label: {
            let selected = !backlog && (value == nil ? date == nil : false)
            Label(title, systemImage: selected ? "checkmark" : icon)
        }
    }
}

/// Blatt „Wann starten?“: Kalender und Uhrzeit, scrollbar, damit nichts abgeschnitten wird (auch quer).
struct TaskDateSheet: View {
    @Binding var draft: Date
    var onDone: () -> Void
    var onCancel: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Abbrechen", action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Text("Wann starten?").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Übernehmen", action: onDone)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(draft < Date())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("Datum", selection: $draft, in: Date()..., displayedComponents: [.date])
                        #if os(iOS)
                        .datePickerStyle(.graphical)
                        #endif
                        .labelsHidden()
                    DatePicker("Uhrzeit", selection: $draft, displayedComponents: [.hourAndMinute])
                        .font(.system(size: 15))
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 380, height: 480)
        #endif
    }
}

/// Kleine Pille neben dem Modus-Chip (Farbe des Aufgaben-Modus, wenn gesetzt).
struct TaskPillLabel: View {
    let icon: String
    let text: String
    var active = false
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = ComposerMode.task.color
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .bold))
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
        }
        .foregroundStyle(active ? tint : theme.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? tint.opacity(0.12) : theme.hover, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? tint.opacity(0.25) : theme.surfaceBorder))
        .contentShape(Capsule())
    }
}

enum TaskSchedule {
    /// Vorschlag für einen Termin: nächste volle Stunde
    static func defaultDate(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: now) ?? now
        return cal.date(bySetting: .minute, value: 0, of: next).map { $0 < now ? next : $0 } ?? next
    }

    static func today(hour: Int) -> Date? {
        let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
        return d.flatMap { $0 > Date() ? $0 : nil }
    }

    static func tomorrow(hour: Int) -> Date? {
        let cal = Calendar.current
        guard let t = cal.date(byAdding: .day, value: 1, to: Date()) else { return nil }
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: t)
    }
}
