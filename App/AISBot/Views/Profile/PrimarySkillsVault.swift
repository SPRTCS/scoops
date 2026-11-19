import SwiftUI
import LocalAuthentication

// MARK: - Haupt-Scoop

/// Kleine Krone für den Haupt-Scoop (Seitenleiste, Profil).
struct PrimaryBadge: View {
    var size: CGFloat = 16
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(Color(hex: "#5A3B00"))
            .frame(width: size, height: size)
            .background(Color(hex: "#FFC83D"), in: Circle())
            .overlay(Circle().strokeBorder(theme.sidebarBackground, lineWidth: 1.5))
            .accessibilityLabel("Haupt-Scoop")
    }
}

/// Zeilen „Haupt-Scoop“ (Schalter) und „Initiative“ für eine Profil-Sektion.
struct PrimaryToggleRows: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            PrimaryBadge(size: 22)
            Text("Haupt-Scoop").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
            Spacer()
            Toggle("Haupt-Scoop", isOn: Binding(get: { bot.primary }, set: { on in Task { await store.setPrimary(bot.id, on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
        .groupedRow()
        if bot.primary {
            Button { store.showInitiative = true } label: {
                GroupedLabelRow(icon: "clock.badge.checkmark", iconColor: theme.accent, title: "Initiative",
                                subtitle: initiativeSummary) { DisclosureChevron() }
            }
            .buttonStyle(.plain)
        }
    }

    private var initiativeSummary: String {
        guard let s = store.initiative else { return "Prüfzeiten und Ruhezeit" }
        guard s.enabled else { return "Aus" }
        return s.times.isEmpty ? "Keine Prüfzeiten" : s.times.joined(separator: " · ")
    }
}

// MARK: - Aufsicht (v1.21)

/// Schalter „Darf andere Scoops prüfen“: Chats, Einstellungen und Kosten der anderen Scoops lesen und Verbesserungen
/// vorschlagen (jede einzeln per Freigabe). Beim Haupt-Scoop fest an.
struct ReviewToggleRow: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var isOn: Bool { bot.primary || bot.canReview }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "binoculars.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Darf andere Scoops prüfen").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                if bot.primary {
                    Text("Beim Haupt-Scoop immer an").font(.system(size: 12.5)).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            Toggle("Darf andere Scoops prüfen", isOn: Binding(get: { isOn }, set: { on in
                guard !bot.primary, on != bot.canReview else { return }
                Task { await store.setCanReview(bot.id, on) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.accent)
            .disabled(bot.primary)
        }
        .groupedRow(vertical: 6)
    }

    /// Erklärtext unter dem Abschnitt
    static func footer(_ bot: Bot) -> String {
        var text = "\(bot.name) liest die Chats, Einstellungen und Kosten der anderen Scoops und schlägt dir Verbesserungen vor "
            + "(Fähigkeiten, Gedächtnis, Anweisungen, Routine-Modell). Übernommen wird erst, wenn du die Karte freigibst. "
            + "Gespräche mit Gästen geteilter Scoops bleiben ausgeblendet."
        if (bot.primary || bot.canReview) && bot.isSharedByMe {
            text += " Solange \(bot.name) geteilt ist, ist die Aufsicht pausiert."
        }
        return text
    }
}

// MARK: - Initiative

/// Initiative in klaren Sektionen: Haupt-Scoop, Automatisch melden, Prüfzeiten, Ruhezeit, Jetzt prüfen.
struct InitiativeSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var toast: String?
    @State private var running = false
    @State private var saveTask: Task<Void, Never>?
    @State private var pendingTimes: [String]?

    private var settings: InitiativeSettings? { store.initiative }
    private var times: [String] { pendingTimes ?? settings?.times ?? [] }

    var body: some View {
        GroupedStack {
            primarySection
            if let settings {
                GroupedSection("Automatisch melden",
                               footer: "Prüft zu festen Zeiten To-dos, Mails, Freigaben und Termine und schreibt nur, wenn es etwas Wichtiges gibt.") {
                    HStack {
                        Text("Meldet sich von selbst").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Toggle("Meldet sich von selbst", isOn: Binding(
                            get: { settings.enabled },
                            set: { v in Task { await store.updateInitiative(InitiativePatch(enabled: v)) } }))
                            .labelsHidden().toggleStyle(.switch).tint(theme.accent)
                    }
                    .groupedRow()
                }
                GroupedSection("Prüfzeiten", footer: times.count >= 8 ? "Höchstens 8 Prüfzeiten." : nil) {
                    ForEach(Array(times.enumerated()), id: \.offset) { idx, time in
                        HStack(spacing: 12) {
                            Button { removeTime(idx) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(theme.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Zeit \(time) entfernen")
                            Text("Prüfung \(idx + 1)").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                            Spacer()
                            DatePicker("Zeit \(idx + 1)", selection: timeBinding(idx), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "de_DE"))
                        }
                        .groupedRow(vertical: 6)
                    }
                    if times.count < 8 {
                        Button { addTime() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(theme.success)
                                Text("Zeit hinzufügen").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                                Spacer()
                            }
                            .groupedRow()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(!settings.enabled)
                .opacity(settings.enabled ? 1 : 0.55)
                GroupedSection("Ruhezeit", footer: "In dieser Zeit meldet sich dein Haupt-Scoop nicht von selbst.") {
                    HStack {
                        Text("Von").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        DatePicker("Ruhezeit von", selection: quietBinding(start: true), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .groupedRow(vertical: 6)
                    HStack {
                        Text("Bis").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        DatePicker("Ruhezeit bis", selection: quietBinding(start: false), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .groupedRow(vertical: 6)
                }
                .environment(\.locale, Locale(identifier: "de_DE"))
                GroupedSection(footer: "Löst sofort einen Check aus, zum Ausprobieren.") {
                    Button { Task { await runNow() } } label: {
                        HStack(spacing: 10) {
                            Spacer()
                            if running { ProgressView().controlSize(.small) }
                            Label("Jetzt prüfen lassen", systemImage: "sparkle.magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(store.primaryBot == nil ? theme.textTertiary : theme.accent)
                            Spacer()
                        }
                        .groupedRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(running || store.primaryBot == nil)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.sendButtonIcon)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(theme.sendButton, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .offset(y: 46)
            }
        }
        .animation(.snappy, value: toast)
        .task { await store.loadInitiative() }
    }

    @ViewBuilder
    private var primarySection: some View {
        if let primary = store.primaryBot {
            GroupedSection("Haupt-Scoop", footer: "Nur der Haupt-Scoop meldet sich zu den Prüfzeiten von selbst.") {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        MascotView(mascot: primary.mascot, size: 36, seed: primary.id, animated: false)
                        PrimaryBadge(size: 15).offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(primary.name).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textPrimary)
                        if let label = primary.label, !label.isEmpty {
                            Text(label).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer()
                    choosePrimaryMenu(label: "Ändern")
                }
                .groupedRow(vertical: 8)
            }
        } else {
            GroupedSection("Haupt-Scoop",
                           footer: "Wähle einen Scoop als ersten Ansprechpartner. Nur er meldet sich zu den Prüfzeiten von selbst.") {
                HStack {
                    Text("Noch kein Haupt-Scoop").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    Spacer()
                    choosePrimaryMenu(label: "Wählen")
                }
                .groupedRow()
            }
        }
    }

    private func choosePrimaryMenu(label: String) -> some View {
        Menu {
            ForEach(store.bots) { bot in
                Button(bot.title) { Task { await store.setPrimary(bot.id, true) } }
            }
        } label: {
            Text(label).font(.system(size: 15)).foregroundStyle(theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Zeiten

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    private func date(_ s: String?) -> Date { s.flatMap { Self.formatter.date(from: $0) } ?? Self.formatter.date(from: "08:00")! }
    private func string(_ d: Date) -> String { Self.formatter.string(from: d) }

    private func timeBinding(_ idx: Int) -> Binding<Date> {
        Binding(get: { date(times.indices.contains(idx) ? times[idx] : nil) },
                set: { d in
                    var t = times
                    guard t.indices.contains(idx) else { return }
                    t[idx] = string(d)
                    scheduleSave(t)
                })
    }

    private func quietBinding(start: Bool) -> Binding<Date> {
        Binding(get: { date(start ? settings?.quietStart : settings?.quietEnd) },
                set: { d in
                    let v = string(d)
                    Task { await store.updateInitiative(start ? InitiativePatch(quietStart: v) : InitiativePatch(quietEnd: v)) }
                })
    }

    private func addTime() {
        var t = times
        let last = t.last.map(date) ?? date("08:00")
        t.append(string(last.addingTimeInterval(3 * 3600)))
        scheduleSave(t, immediately: true)
    }

    private func removeTime(_ idx: Int) {
        var t = times
        guard t.indices.contains(idx) else { return }
        t.remove(at: idx)
        scheduleSave(t, immediately: true)
    }

    /// Zeiten gebündelt speichern (DatePicker meldet beim Drehen viele Zwischenwerte).
    private func scheduleSave(_ t: [String], immediately: Bool = false) {
        pendingTimes = t
        saveTask?.cancel()
        saveTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled else { return }
            let sorted = Array(Set(t)).sorted()
            await store.updateInitiative(InitiativePatch(times: sorted))
            pendingTimes = nil
        }
    }

    private func runNow() async {
        running = true
        let ok = await store.runInitiative()
        running = false
        if ok {
            toast = "\(store.primaryBot?.name ?? "Dein Scoop") schaut nach …"
            try? await Task.sleep(for: .seconds(3))
            toast = nil
        }
    }
}

/// Initiative als eigenes Blatt (aus dem Profil des Haupt-Scoops).
struct InitiativeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Initiative", icon: "clock.badge.checkmark") { dismiss() }
            ScrollView {
                InitiativeSettingsView()
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 60)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 480, height: 680)
        #endif
    }
}

// MARK: - Fähigkeiten

/// Fähigkeiten eines Scoops (eigene + geteilte) im Profil.
struct SkillList: View {
    let botID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var items: [Skill] {
        (store.skills[botID] ?? []).sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                GroupedSection("Fähigkeiten",
                               footer: "Wenn ein Scoop eine Aufgabe gut gelöst hat, kann er sich merken, wie es geht. Sag z. B. „Merk dir, wie das geht.“") {
                    GroupedLabelRow(icon: "wand.and.stars", title: "Noch keine Fähigkeiten", titleColor: theme.textSecondary)
                }
            } else {
                GroupedSection("Fähigkeiten", footer: "Antippen zeigt die Schritte. Dort kannst du sie ändern oder löschen.", dividerInset: 50) {
                    ForEach(items) { skill in
                        Button { store.presentedSkillID = skill.id } label: {
                            GroupedLabelRow(icon: skill.isShared ? "person.3" : "wand.and.stars",
                                            iconColor: skill.isShared ? theme.accent : theme.textSecondary,
                                            title: skill.name,
                                            subtitle: (skill.isShared ? "für alle Scoops · " : "") + SkillList.usage(skill)) {
                                DisclosureChevron()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: botID) { await store.loadSkills(botID: botID) }
    }

    static func usage(_ skill: Skill) -> String {
        let count = skill.uses == 1 ? "1× genutzt" : "\(skill.uses)× genutzt"
        guard let last = skill.lastUsed else { return skill.uses == 0 ? "noch nicht genutzt" : count }
        return "\(count) · zuletzt \(Formatting.dayTime(last))"
    }
}

/// Detail einer Fähigkeit: Beschreibung und Schritte, bearbeiten, löschen.
struct SkillDetailView: View {
    let skillID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var name = ""
    @State private var description = ""
    @State private var steps = ""
    @State private var confirmDelete = false
    @State private var saving = false

    private var skill: Skill? { store.skill(skillID) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Fähigkeit", icon: "wand.and.stars", trailing: {
                if skill != nil {
                    Button(editing ? "Abbrechen" : "Bearbeiten") {
                        if !editing { load() }
                        editing.toggle()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }, onClose: { dismiss() })
            if let skill {
                ScrollView {
                    GroupedStack {
                        if editing { editor } else { reader(skill) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                Divider().overlay(theme.surfaceBorder)
                HStack {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Löschen", systemImage: "trash").foregroundStyle(theme.danger)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if editing {
                        Button("Speichern") { save() }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ContentUnavailableView("Fähigkeit nicht gefunden", systemImage: "wand.and.stars")
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 500, height: 640)
        #endif
        .confirmationDialog("„\(skill?.name ?? "")“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task {
                    await store.deleteSkill(skillID)
                    dismiss()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Scoops wissen danach nicht mehr, wie diese Aufgabe geht.")
        }
    }

    @ViewBuilder
    private func reader(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.name).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.textPrimary)
            HStack(spacing: 6) {
                if let owner = store.bot(skill.botId) {
                    MascotView(mascot: owner.mascot, size: 18, seed: owner.id, animated: false)
                    Text(owner.name)
                } else {
                    Image(systemName: "person.3")
                    Text("für alle Scoops")
                }
                Text("·")
                Text(SkillList.usage(skill))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, GroupedMetrics.rowInset)
        if let d = skill.description, !d.isEmpty {
            GroupedSection("Beschreibung") {
                Text(d).font(.system(size: 15)).foregroundStyle(theme.textPrimary).groupedRow(vertical: 12)
            }
        }
        if let steps = skill.steps, !steps.isEmpty {
            GroupedSection("Schritte", footer: "So geht der Scoop vor, wenn er diese Fähigkeit nutzt.") {
                MarkdownView(text: steps)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .groupedRow(vertical: 12)
            }
        }
    }

    private var editor: some View {
        GroupedStack {
            GroupedSection("Name") {
                TextField("Name", text: $name).textFieldStyle(.plain).font(.system(size: 15)).groupedRow()
            }
            GroupedSection("Beschreibung") {
                TextField("Wofür ist diese Fähigkeit?", text: $description, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(2...5).groupedRow()
            }
            GroupedSection("Schritte", footer: "Eine Zeile pro Schritt, z. B. „1. …“") {
                TextEditor(text: $steps)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }
        }
    }

    private func load() {
        name = skill?.name ?? ""
        description = skill?.description ?? ""
        steps = skill?.steps ?? ""
    }

    private func save() {
        saving = true
        Task {
            await store.updateSkill(skillID, SkillPatch(name: name.trimmingCharacters(in: .whitespaces),
                                                        description: description, steps: steps))
            saving = false
            editing = false
        }
    }
}

// MARK: - Tresor

/// Tresor: Logins für die Scoops. Wird bei jedem Öffnen mit Face ID / Touch ID / Gerätecode geschützt.
struct VaultView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var authError: String?
    @State private var editing: VaultEntry?
    @State private var adding = false
    @State private var toDelete: VaultEntry?

    /// Nur Demo-Screenshots: `-vaultdemo` überspringt die Entsperrung im Demo-Modus.
    private var demoUnlocked: Bool { store.isMock && ProcessInfo.processInfo.arguments.contains("-vaultdemo") }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Tresor", icon: "lock.shield", trailing: {
                if unlocked {
                    Button { adding = true } label: { Label("Neu", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }, onClose: { dismiss() })
            if unlocked { list } else { locked }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 540, height: 620)
        #endif
        .task {
            if demoUnlocked { unlocked = true; await store.loadVault(); return }
            await authenticate()
        }
        .sheet(isPresented: $adding) {
            VaultEditor(entry: nil, initialPreview: ProcessInfo.processInfo.arguments.contains("-vaultaddemo"))
                .environment(\.theme, theme).environment(store)
        }
        .sheet(item: $editing) { entry in
            VaultEditor(entry: entry).environment(\.theme, theme).environment(store)
        }
        .confirmationDialog("„\(toDelete?.title ?? "")“ löschen?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let e = toDelete { Task { await store.deleteVaultEntry(e.id) } }
                toDelete = nil
            }
            Button("Abbrechen", role: .cancel) { toDelete = nil }
        } message: {
            Text("Benutzername und Passwort werden aus dem Schlüsselbund deines Macs entfernt.")
        }
        .onAppear {
            if demoUnlocked, ProcessInfo.processInfo.arguments.contains("-vaultaddemo") { adding = true }
        }
    }

    private var locked: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(theme.textTertiary)
            Text("Tresor gesperrt").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
            if let authError {
                Text(authError).font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            }
            Button { Task { await authenticate() } } label: {
                Label("Entsperren", systemImage: "faceid")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            GroupedStack {
                if store.vault.isEmpty {
                    GroupedSection("Logins", footer: footerText) {
                        GroupedLabelRow(icon: "key", title: "Noch keine Logins", titleColor: theme.textSecondary)
                    }
                } else {
                    GroupedSection("Logins", footer: footerText, dividerInset: 54) {
                        ForEach(store.vault) { entry in row(entry) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private var footerText: String {
        "Passwörter liegen nur im Schlüsselbund deines Macs. Deine Scoops sehen nur Titel, Webseite und Benutzername."
    }

    private func row(_ entry: VaultEntry) -> some View {
        Button { editing = entry } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.hasPassword ? "lock.fill" : "lock.open")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(entry.hasPassword ? theme.success : theme.textTertiary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                    Text([entry.domain, entry.username].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(entry.lastUsed.map { Formatting.shortDate($0) } ?? "neu")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                DisclosureChevron()
            }
            .groupedRow(vertical: 9)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editing = entry } label: { Label("Bearbeiten", systemImage: "pencil") }
            Button(role: .destructive) { toDelete = entry } label: { Label("Löschen", systemImage: "trash") }
        }
        .accessibilityLabel("\(entry.title), \(entry.domain ?? ""), \(entry.lastUsed.map { "zuletzt genutzt \(Formatting.dayTime($0))" } ?? "noch nicht genutzt")")
    }

    private func authenticate() async {
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = "Auf diesem Gerät ist kein Code oder Face ID / Touch ID eingerichtet."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Tresor öffnen")
            if ok {
                unlocked = true
                authError = nil
                await store.loadVault()
            }
        } catch {
            authError = "Nicht entsperrt. Tippe auf „Entsperren“, um es erneut zu versuchen."
        }
    }
}

/// Login anlegen oder bearbeiten.
struct VaultEditor: View {
    let entry: VaultEntry?
    var initialPreview = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""
    @State private var showPassword = false
    @State private var saving = false
    @State private var confirmDelete = false

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !url.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(entry == nil ? "Neuer Login" : "Login bearbeiten", icon: "key") { dismiss() }
            ScrollView {
                GroupedStack {
                    GroupedSection("Login") {
                        formRow("Titel") {
                            TextField("z. B. Kundenportal", text: $title).textFieldStyle(.plain)
                        }
                        formRow("Webseite") {
                            TextField("https://…", text: $url)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                #endif
                        }
                        formRow("Benutzer") {
                            TextField("Name oder E-Mail", text: $username)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .textContentType(.username)
                                #endif
                        }
                    }
                    GroupedSection("Passwort", footer: passwordFooter) {
                        formRow("Passwort") {
                            HStack(spacing: 8) {
                                Group {
                                    if showPassword {
                                        TextField(entry == nil ? "Passwort" : "Unverändert", text: $password)
                                    } else {
                                        SecureField(entry == nil ? "Passwort" : "Unverändert", text: $password)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .textContentType(.password)
                                #endif
                                Button { showPassword.toggle() } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(showPassword ? "Passwort verbergen" : "Passwort anzeigen")
                            }
                        }
                    }
                    GroupedSection("Notiz") {
                        TextField("optional", text: $note, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .lineLimit(2...4)
                            .groupedRow()
                    }
                    if entry != nil {
                        GroupedSection {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                GroupedLabelRow(icon: "trash", iconColor: theme.danger, title: "Login löschen", titleColor: theme.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            Divider().overlay(theme.surfaceBorder)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary))
                Button(entry == nil ? "Speichern" : "Sichern") { save() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
        .onAppear {
            if let e = entry {
                title = e.title; url = e.url ?? ""; username = e.username ?? ""; note = e.note ?? ""
            } else if initialPreview {
                title = "Kundenportal"; url = "https://portal.example.com/login"; username = "arman@example.com"
                password = "geheim123"
            }
        }
        .confirmationDialog("„\(entry?.title ?? "")“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let e = entry { Task { await store.deleteVaultEntry(e.id); dismiss() } }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    /// Formularzeile: Beschriftung links (feste Breite), Eingabe rechts.
    private func formRow<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundStyle(theme.textPrimary).frame(width: 92, alignment: .leading)
            content().font(.system(size: 15)).foregroundStyle(theme.textPrimary)
        }
        .groupedRow()
    }

    private var passwordFooter: String {
        var t = "Das Passwort wird nur im Schlüsselbund deines Macs gespeichert. Deine Scoops sehen nur Titel, Webseite und Benutzername."
        if let entry {
            t = (entry.hasPassword ? "Leer lassen, um das gespeicherte Passwort zu behalten. " : "Noch kein Passwort gespeichert. ") + t
        }
        return t
    }

    private func save() {
        saving = true
        var u = url.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty, !u.contains("://") { u = "https://" + u }
        let draft = VaultDraft(title: title.trimmingCharacters(in: .whitespaces), url: u,
                               username: username.isEmpty ? nil : username,
                               password: password.isEmpty ? nil : password,   // nur senden, wenn eingegeben
                               note: note.isEmpty ? nil : note)
        Task {
            let ok = await store.saveVaultEntry(id: entry?.id, draft: draft)
            saving = false
            if ok { dismiss() }
        }
    }
}
