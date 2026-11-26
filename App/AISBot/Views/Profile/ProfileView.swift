import SwiftUI

/// Profil eines Scoops (Mac/iPad/iPhone Duo aufgeklappt: rechte Inspector-Spalte, iPhone: Blatt).
///
/// Die Übersicht bleibt kurz: Kopf (Maskottchen, Name, Rolle, Modell), „Anstehend“ und „Computer“, darunter
/// Navigationszeilen zu den Unterseiten (`ProfilePage`): Bibliothek, Modell, Persönlichkeit, Teilen, Verwalten.
/// Eigener Seitenstapel (`ProfileStack`) im Inspector bzw. Blatt; beim Wechsel des Scoops springt er zurück zur Übersicht.
struct ProfileView: View {
    let botID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    /// Außerhalb des Stapels gelesen: schließt das Blatt (in einer Unterseite hieße `dismiss` „zurück“)
    @Environment(\.dismiss) private var dismiss
    @State private var router = ProfileRouter()
    @State private var showScreen = false
    /// Erst nach dem Einfahren alles aufbauen (siehe `ProfileSettle`)
    @State private var settled = false

    private var bot: Bot? { store.bot(botID) }
    /// Geteilter Scoop eines anderen (ich bin Gast)
    private var guest: BotAccess? { store.access(for: botID) }
    private var canEdit: Bool { guest.map { $0.role.canEdit } ?? true }

    /// Höchstens so viele Routinen unter „Anstehend“; alle stehen unter „Verwalten“ → „Routinen“
    private static let upcomingLimit = 3

    var body: some View {
        ProfileStack(botID: botID) { overview }
        .environment(router)
        #if os(iOS)
        .tint(theme.textPrimary)
        #endif
        .onAppear {
            router.onClose = { [store, dismiss] in
                store.showInspector = false
                #if os(iOS)
                dismiss()
                #endif
            }
        }
        // Anderer Scoop: zurück zur Übersicht
        .onChange(of: botID) { router.popToRoot() }
        // Auffrischen erst nach dem Einfahren (der Chat hat das Profil beim Öffnen schon geladen)
        .task(id: botID) {
            await ProfileSettle.wait(extra: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await store.loadProfile(botID: botID)
            // Kurzinfo „heute … $“ bei „Verwalten“
            await store.loadBotUsage(botID: botID)
        }
        .sheet(isPresented: $showScreen) {
            ScreenViewer(botName: bot?.name ?? "Scoop")
                .environment(\.theme, theme)
                .environment(store)
        }
    }

    private var overview: some View {
        ScrollViewReader { proxy in
            ProfileScaffold(page: nil) {
                if let bot {
                    VStack(spacing: 0) {
                        header(bot).padding(.bottom, 22)
                        if settled {
                            if guest != nil { guestOverview(bot) } else { ownerOverview(bot) }
                        } else {
                            ProfileSettle.placeholder
                        }
                    }
                }
            }
            .task {
                await ProfileSettle.wait()
                settled = true
                // Nur Screenshots: Startseite (`-profilepage …`, `-modeldemo` usw.) erst nach dem Einfahren öffnen
                let start = ProfilePage.initialPath
                if !start.isEmpty, router.path.isEmpty { router.path = start }
                // Nur Screenshots: `-computerdemo` scrollt zum Abschnitt „Computer“ (Rechner-Auswahl)
                if ProcessInfo.processInfo.arguments.contains("-computerdemo") {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("computer", anchor: .top)
                }
            }
        }
    }

    private func header(_ bot: Bot) -> some View {
        VStack(spacing: 6) {
            // Während des Ein- und Ausfahrens statisch (Bild aus dem Cache), sonst mit Fell-Animation
            MascotView(mascot: bot.mascot, size: 104, mood: store.isBusy(bot.id) ? .working : .idle,
                       seed: bot.id, animated: settled && store.showInspector, showsGround: true)
                .overlay(alignment: .bottomTrailing) {
                    if bot.primary { PrimaryBadge(size: 26).offset(x: -6, y: -10) }
                }
                .padding(.top, 4)
            Text(bot.name)
                .appFont(21, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            if let label = bot.label, !label.isEmpty {
                Text(label).appFont(13.5).foregroundStyle(theme.textSecondary)
            }
            if let guest {
                // Geteilter Scoop: läuft auf dem Server des Admins
                let owner = guest.ownerName ?? "Admin"
                HStack(spacing: 6) {
                    PersonAvatar(name: owner, size: 18)
                    Text("Läuft bei \(owner)").appFont(12.5, weight: .medium)
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(theme.selection, in: Capsule())
                .padding(.top, 4)
            }
            // Anbieter-Kennzeichen + Modell (Gäste sehen das Modell nicht)
            let model = bot.model ?? BotModel.haiku.rawValue
            if guest == nil || bot.model != nil { AdaptiveButtonRow(spacing: 5, alignment: .center) {
                if let mark = BotModel.providerMark(for: model) {
                    Text(mark)
                        .appFont(10.5, weight: .bold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.selection, in: Capsule())
                }
                Text(BotModel.displayName(for: model)).appFont(12)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.top, 2) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Übersicht (eigener Scoop)

    @ViewBuilder
    private func ownerOverview(_ bot: Bot) -> some View {
        GroupedStack {
            upcomingSection(bot)
            computerSection(bot)
            // v1.29: Rechte-Modus und Standard-Bereich (nur Admin; ältere Server liefern das Feld nicht)
            if bot.computerAccess != nil { ComputerAccessSection(bot: bot) }
            // Dauerhafte Freigaben: eine Zeile, Unterseiten nach Werkzeug (StandingApprovalsPages.swift)
            StandingApprovalsNavSection(bot: bot)
            // Nach Häufigkeit: Bibliothek (Dateien wiederfinden), Modell (Wechsel für einzelne Aufgaben),
            // Persönlichkeit und Teilen (meist einmal eingerichtet)
            GroupedSection(dividerInset: 50) {
                ProfileNavRow(page: .library, value: ProfileSummary.library(store: store, chatID: bot.id))
                ProfileNavRow(page: .model, value: BotModel.displayName(for: bot.model ?? BotModel.haiku.rawValue))
                ProfileNavRow(page: .personality, value: ProfileSummary.voice(bot))
                if store.canShare(bot.id) {
                    ProfileNavRow(page: .sharing, value: ShareSection.summary(store: store, bot: bot))
                }
            }
            MuteProfileSection(chatID: bot.id)
            GroupedSection(dividerInset: 50) {
                ProfileNavRow(page: .manage, value: CostSection.summary(store: store, bot: bot))
            }
        }
    }

    // MARK: Übersicht (Gast, geteilter Scoop)

    @ViewBuilder
    private func guestOverview(_ bot: Bot) -> some View {
        let access = guest ?? BotAccess(role: .read, computer: .noAccess)
        let share = store.share(for: bot.id)
        GroupedStack {
            GroupedSection(String(localized: "Geteilt mit dir"), footer: guestFooter(bot, owner: access.ownerName),
                           dividerInset: 50) {
                HStack(spacing: 12) {
                    PersonAvatar(name: access.ownerName ?? "Admin", size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(access.ownerName ?? "Admin").appFont(15).foregroundStyle(theme.textPrimary)
                        HStack(spacing: 5) {
                            let online = share.map { store.isGuestOnline($0) } ?? false
                            Circle().fill(online ? theme.success : theme.textTertiary).frame(width: 7, height: 7)
                            Text([share?.serverName, online ? "online" : "offline"].compactMap { $0 }.joined(separator: " · "))
                                .appFont(12.5).foregroundStyle(theme.textSecondary).adaptiveLineLimit(1)
                        }
                    }
                    Spacer()
                    ShareTag(text: "Admin")
                }
                .groupedRow(vertical: 8)
                GroupedLabelRow(icon: access.role.symbol, title: String(localized: "Deine Rolle: \(access.role.title)"),
                                subtitle: access.role.detail)
                GroupedLabelRow(icon: access.computer.symbol, title: String(localized: "Rechner: \(access.computer.title)"),
                                subtitle: access.computer.detail)
            }
            if access.role.canEdit { upcomingSection(bot) }
            if access.computer.canView { computerSection(bot) }
            GroupedSection(dividerInset: 50) {
                ProfileNavRow(page: .library, value: ProfileSummary.library(store: store, chatID: bot.id))
                if access.role.canEdit { ProfileNavRow(page: .personality, value: ProfileSummary.voice(bot)) }
            }
            MuteProfileSection(chatID: bot.id)
            GroupedSection(dividerInset: 50) {
                ProfileNavRow(page: .manage, value: CostSection.summary(store: store, bot: bot))
            }
        }
    }

    /// Fußtext „Geteilt mit dir“: ganzer Satz mit bzw. ohne Namen des Admins
    private func guestFooter(_ bot: Bot, owner: String?) -> String {
        guard let owner else {
            return String(localized: "\(bot.name) läuft auf dem Server von dem Admin und arbeitet mit den Konten von dem Admin. Freigaben entscheidet der Admin.")
        }
        return String(localized: "\(bot.name) läuft auf dem Server von \(owner) und arbeitet mit den Konten von \(owner). Freigaben entscheidet \(owner).")
    }

    // MARK: Anstehend, Computer

    /// Die nächsten Routinen (aktive zuerst); bei mehr als `upcomingLimit` führt eine Zeile zu allen.
    @ViewBuilder
    private func upcomingSection(_ bot: Bot) -> some View {
        let list = sortedRoutines(store: store, botID: bot.id)
        if list.isEmpty {
            GroupedSection("Anstehend",
                           footer: "Sag \(bot.name) im Chat, was regelmäßig passieren soll, etwa „Jeden Morgen um 7:30 ein Briefing“.") {
                GroupedLabelRow(icon: "clock", title: "Keine Routinen", titleColor: theme.textSecondary)
            }
        } else {
            GroupedSection("Anstehend", dividerInset: 50) {
                ForEach(list.prefix(Self.upcomingLimit)) { routine in RoutineRow(routine: routine) }
                if list.count > Self.upcomingLimit {
                    ProfileNavRow(page: .routines, value: "\(list.count)", title: String(localized: "Alle Routinen"))
                }
            }
        }
    }

    private func computerSection(_ bot: Bot) -> some View {
        let footer: String? = guest.map { $0.computer.canControl
            ? String(localized: "Du kannst zusehen und Maus und Tastatur übernehmen.")
            : String(localized: "Du kannst zusehen, aber nicht steuern.") } ?? computerFooter(bot)
        return GroupedSection(String(localized: "Computer", comment: "Abschnitt im Profil: Rechner des Scoops"), footer: footer) {
            if guest == nil, store.nodes.count > 1 { ComputerNodePicker(bot: bot) }
            computerRow(bot)
        }
        .id("computer")
        // Rechnerliste frisch vom Server: entfernte Rechner verschwinden auch hier sofort
        .task(id: bot.id) { if guest == nil { await store.loadNodes() } }
    }

    private func computerFooter(_ bot: Bot) -> String? {
        guard store.nodes.count > 1 else { return nil }
        if let n = store.node(bot.computerNode), !n.isAvailable {
            let status = n.statusText.lowercased()
            return String(localized: "„\(n.name)“ ist gerade \(status). \(bot.name) sagt Bescheid, wenn er den Rechner braucht.",
                          comment: "status z. B. „offline“ oder „pausiert“")
        }
        return String(localized: "An diesem Rechner arbeitet \(bot.name) mit Bildschirm und Terminal.")
    }

    private func computerRow(_ bot: Bot) -> some View {
        // Normalerweise zeigt die App schon den Rechner dieses Scoops; sonst den Stand aus der Rechnerliste
        let c = store.computerNodeID == bot.computerNode ? store.computer
            : (store.node(bot.computerNode)?.computerState ?? store.computer)
        var stateText = c.displayText
        if c.state == "busy", let other = c.botId, other != bot.id, let name = store.bot(other)?.name {
            stateText = String(localized: "Arbeitet für \(name)")
        }
        return Button {
            if store.computerNodeID != bot.computerNode { store.computerNodeID = bot.computerNode }
            showScreen = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.nodeName(bot.computerNode)).appFont(15).foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(stateColor(c.state)).frame(width: 7, height: 7)
                        Text(stateText).appFont(12.5).foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer()
                // Beim Ausfahren keine Bild-Abfragen mehr
                ScreenThumbnail(cornerRadius: 7, live: c.state != "asleep" && store.showInspector)
                    .frame(width: 78)
                    .opacity(c.state == "asleep" ? 0.4 : 1)
                DisclosureChevron()
            }
            .groupedRow(vertical: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(store.nodeName(bot.computerNode)), \(stateText). Bildschirm öffnen")
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "busy": theme.accent
        case "user": theme.warning
        case "awake": theme.success
        default: theme.textTertiary
        }
    }

}

// MARK: - Aufbau nach dem Einfahren

/// Das Profil fährt als Seitenleiste (Mac/iPad) bzw. als Blatt (iPhone) ein. Baut es sich in demselben Bild
/// komplett auf (Listen, Modellwahl, Stimme, Bot-Rechner-Vorschau, animiertes Maskottchen), kostet das einen
/// Block von rund 50 ms mitten in der Animation (gemessen, Build 12). Deshalb zuerst nur Kopf und Tabs,
/// der Rest kurz nach dem Ende der Animation.
enum ProfileSettle {
    /// etwas länger als die Spalten- bzw. Blatt-Animation
    static let delay: Duration = .milliseconds(380)

    static func wait(extra: Duration = .zero) async {
        try? await Task.sleep(for: delay + extra)
    }

    /// Ruhiger Platzhalter in Höhe der ersten Sektionen, damit nichts springt.
    static var placeholder: some View {
        Color.clear.frame(height: 480)
    }
}

// MARK: - Dauerhafte Freigaben (v1.20)

struct StandingApprovalRow: View {
    let item: StandingApproval
    /// Kürzere Beschriftung auf der Seite eines Werkzeugs (ohne Servernamen davor)
    var title: String?
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        GroupedLabelRow(icon: item.symbol, title: title ?? item.label,
                        subtitle: item.createdAt.map { date in
                            let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(.app))
                            return String(localized: "Seit \(day)", comment: "Dauerhafte Freigabe besteht seit einem Datum")
                        }) {
            Button { remove() } label: {
                Image(systemName: "minus.circle.fill")
                    .appFont(17)
                    .foregroundStyle(theme.danger)
            }
            .buttonStyle(.plain)
            .help("Entfernen: \(item.label)")
            .accessibilityLabel("Entfernen: \(item.label)")
        }
        .contextMenu {
            Button(role: .destructive) { remove() } label: { Label("Entfernen", systemImage: "trash") }
        }
    }

    private func remove() {
        Task { await store.deleteStandingApproval(item) }
    }
}

// MARK: - Routinen

struct RoutineRow: View {
    let routine: Routine
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var confirmDelete = false

    /// Modell des Scoops (Standard für Routinen ohne eigenes Modell)
    private var scoopModel: String { store.bot(routine.botId)?.model ?? BotModel.haiku.rawValue }
    /// Eigenes Modell nur zeigen, wenn es vom Scoop abweicht
    private var scoopModelName: String { BotModel.displayName(for: scoopModel) }
    private var ownModel: String? { routine.model.flatMap { $0 == scoopModel ? nil : $0 } }
    /// Modellwahl nur für eigene Scoops und echte Routinen (Erinnerungen laufen ohne Modell)
    private var canPickModel: Bool { routine.kind != "erinnerung" && store.access(for: routine.botId) == nil }
    private var subtitle: String {
        let when = routine.scheduleText ?? routine.schedule ?? ""
        guard let ownModel else { return when }
        return [when, BotModel.displayName(for: ownModel)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        // Große Schrift: Schalter unter dem Titel, damit der Titel die ganze Breite hat
        AdaptiveRow(spacing: 12, minSpacer: 4, trailingIndent: 34) {
            HStack(spacing: 12) {
                Image(systemName: routine.kind == "erinnerung" ? "bell" : "clock")
                    .appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title)
                        .appFont(15)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(1)
                    Text(subtitle)
                        .appFont(12)
                        .foregroundStyle(theme.textSecondary)
                        .adaptiveLineLimit(1)
                }
            }
        } trailing: {
            Toggle("", isOn: Binding(get: { routine.enabled },
                                     set: { v in Task { await store.setRoutine(routine, enabled: v) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
                .controlSize(.small)
                .accessibilityLabel(routine.title)
        }
        .groupedRow(vertical: 8)
        .contextMenu {
            Button { Task { await store.runRoutine(routine) } } label: { Label("Jetzt ausführen", systemImage: "play") }
            if canPickModel { modelMenu }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
        }
        .confirmationDialog("„\(routine.title)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await store.deleteRoutine(routine) } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    /// v1.20: Modell pro Routine („Wie Scoop“ = Modell des Scoops)
    private var modelMenu: some View {
        Menu {
            modelButton(nil, String(localized: "Wie Scoop (\(scoopModelName))"))
            ForEach(ModelProvider.allCases) { provider in
                Section(provider.title) {
                    ForEach(BotModel.choices(of: provider)) { m in modelButton(m.id, m.label) }
                }
            }
        } label: {
            Label("Modell", systemImage: "cpu")
        }
    }

    private func modelButton(_ id: String?, _ title: String) -> some View {
        let selected = routine.model == id
        return Button {
            guard !selected else { return }
            Task { await store.setRoutineModel(routine, model: id) }
        } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: - Modell

/// Modellwahl (Seite „Modell“) in zwei Sektionen (Claude / OpenAI), Häkchen rechts. Unbekannte Kennungen erscheinen als eigene Zeile.
struct ModelPickerSections: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var current: String { bot.model ?? BotModel.haiku.rawValue }

    var body: some View {
        GroupedStack {
            ForEach(ModelProvider.allCases) { provider in
                GroupedSection(provider.title, footer: footer(provider)) {
                    ForEach(BotModel.choices(of: provider)) { model in row(model.id, model.label, subtitle(model)) }
                }
            }
            if !ModelCatalogStore.shared.catalog.isSelectable(current) {
                GroupedSection("Weiteres Modell", footer: "Dieses Modell steht nicht in der Auswahl deines Servers; der Server nutzt es trotzdem.") {
                    row(current, BotModel.displayName(for: current), current == BotModel.displayName(for: current) ? nil : current)
                }
            }
        }
    }

    /// Hinweis unter dem Namen; Modelle ohne Schlüssel bzw. Abo auf dem Server sind gekennzeichnet
    private func subtitle(_ model: CatalogModel) -> String? {
        guard model.available == false else { return model.hint }
        return [model.hint, String(localized: "auf deinem Server nicht eingerichtet")].compactMap { $0 }.joined(separator: " · ")
    }

    /// Die Verstärkung (wer an wen abgibt) erklärt `ModelEscalationSection` darunter.
    private func footer(_ provider: ModelProvider) -> String? {
        provider == .anthropic
            ? nil
            : String(localized: "OpenAI-Scoops können alles wie die anderen; den Bot-Rechner bedient für sie eine Claude-Teilaufgabe.")
    }

    private func row(_ id: String, _ title: String, _ hint: String?) -> some View {
        let selected = current == id
        return Button {
            guard !selected else { return }
            Task { await store.updateBot(bot.id, BotPatch(model: id)) }
        } label: {
            GroupedLabelRow(title: title, subtitle: hint) {
                if selected {
                    Image(systemName: "checkmark").appFont(14, weight: .semibold).foregroundStyle(theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Charakter

struct CharacterEditor: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var text = ""
    @State private var saving = false

    private var changed: Bool { text != (bot.character ?? "") }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            GroupedSection("Charakter", footer: changed ? nil : "Tonfall und Eigenheiten. Beispiel: „locker, präzise, duzt“.") {
                TextField("Wie soll \(bot.name) sein?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(3...10)
                    .groupedRow(vertical: 12)
            }
            if changed {
                HStack {
                    Button("Verwerfen") { text = bot.character ?? "" }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Button("Speichern") {
                        saving = true
                        Task {
                            await store.updateBot(bot.id, BotPatch(character: text))
                            saving = false
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(saving)
                }
                .transition(.opacity)
            }
        }
        .onAppear { text = bot.character ?? "" }
        .onChange(of: bot.id) { text = bot.character ?? "" }
        .animation(.snappy(duration: 0.2), value: changed)
    }
}

// MARK: - Gedächtnis

struct MemoryList: View {
    let botID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var toDelete: Memory?
    @State private var expandedIDs: Set<String> = []

    private var groups: [(String, String, [Memory])] {
        let all = store.memories[botID] ?? []
        let shared = all.filter { $0.botId == nil }
        let diary = all.filter { $0.botId != nil && $0.kind == "tagebuch" }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        let profile = all.filter { $0.botId != nil && $0.kind != "tagebuch" }
        return [(String(localized: "Profil"), "person.text.rectangle", profile),
                (String(localized: "Geteilte Fakten"), "person.2", shared),
                (String(localized: "Tagebuch"), "book.closed", diary)].filter { !$0.2.isEmpty }
    }

    var body: some View {
        GroupedStack {
            if groups.isEmpty {
                GroupedSection("Gedächtnis", footer: "Dein Scoop merkt sich Regeln und Vorlieben von selbst. Frag im Chat: „Was weißt du über mich?“") {
                    GroupedLabelRow(icon: "brain", title: "Noch nichts gemerkt", titleColor: theme.textSecondary)
                }
            }
            ForEach(Array(groups.enumerated()), id: \.element.0) { idx, group in
                GroupedSection(group.0,
                               footer: idx == groups.count - 1
                                   ? String(localized: "Halte einen Eintrag gedrückt, um ihn zu löschen. Geteilte Fakten gelten für alle Scoops.") : nil) {
                    ForEach(group.2) { memory in memoryRow(memory) }
                }
            }
        }
        .confirmationDialog("Eintrag vergessen?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Vergessen", role: .destructive) {
                if let m = toDelete { Task { await store.deleteMemory(m, botID: botID) } }
                toDelete = nil
            }
            Button("Abbrechen", role: .cancel) { toDelete = nil }
        } message: {
            Text(toDelete?.text ?? "")
        }
    }

    private func memoryRow(_ memory: Memory) -> some View {
        let expanded = expandedIDs.contains(memory.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(memory.text)
                .appFont(14.5)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if memory.kind == "tagebuch", let d = memory.createdAt {
                Text(Formatting.shortDate(d)).appFont(11.5).foregroundStyle(theme.textTertiary)
            }
        }
        .groupedRow(vertical: 11)
        // Lange Einträge sind auf 4 Zeilen gekürzt; Tippen klappt sie auf.
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) {
                if expanded { expandedIDs.remove(memory.id) } else { expandedIDs.insert(memory.id) }
            }
        }
        .contextMenu {
            Button { Clipboard.copy(memory.text) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
            Button(role: .destructive) { toDelete = memory } label: { Label("Vergessen", systemImage: "trash") }
        }
    }
}
