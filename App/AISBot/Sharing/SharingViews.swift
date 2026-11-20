import SwiftUI

// Oberflächen für geteilte Scoops (docs/sharing.md): Teilen verwalten (Admin), Einladung annehmen (Gast),
// Kosten pro Scoop und pro Person.

// MARK: - Bausteine

/// Rundes Bild einer Person: Initiale auf einer Farbe, die sich aus dem Namen ergibt.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 32

    private static let colors = ["#3D84F5", "#22BFAE", "#FF7A30", "#8B5CF6", "#FF5FA8", "#34C46C", "#F2484E", "#A87452"]

    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hex: Self.colors[sum % Self.colors.count])
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.fixed(size * (initials.count > 1 ? 0.36 : 0.44), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Kleine Kapsel wie „Schreiben“, „Zusehen“
struct ShareTag: View {
    let text: String
    var symbol: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).appFont(9.5, weight: .semibold) }
            Text(text).appFont(11, weight: .semibold).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(theme.selection, in: Capsule())
    }
}

// MARK: - Teilen (Admin, im Profil)

/// Abschnitt „Personen“ auf der Profilseite „Teilen“ eines eigenen Scoops: Personen, offene Einladungen und
/// „Person einladen“. Werkzeuge, Tageslimit und Kosten pro Person stehen darunter (`ProfileSharingPage`).
struct ShareSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showInvite = ProcessInfo.processInfo.arguments.contains("-invitedemo")
    @State private var toRemove: ShareMember?

    private var list: BotShareList? { store.shareLists[bot.id] }
    private var members: [ShareMember] { list?.members ?? bot.shared?.members ?? [] }
    private var invites: [ShareInvite] { (list?.invites ?? []).filter { ($0.expiresAt ?? .distantFuture) > Date() } }

    var body: some View {
        Group {
            if let reason = store.sharingUnavailableReason {
                GroupedSection("Personen", footer: reason) {
                    GroupedLabelRow(icon: "person.badge.plus", title: "Person einladen", titleColor: theme.textTertiary)
                }
            } else {
                GroupedSection(header, footer: footer, dividerInset: GroupedMetrics.rowInset + Self.avatar + 12) {
                    ForEach(members) { member in memberRow(member) }
                    ForEach(invites) { invite in inviteRow(invite) }
                    inviteButton
                }
            }
        }
        .task(id: bot.id) {
            guard store.sharingUnavailableReason == nil else { return }
            await store.loadShareList(botID: bot.id)
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet(bot: bot)
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        .confirmationDialog("\(toRemove?.name ?? "") entfernen?",
                            isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                if let m = toRemove { Task { await store.removeShare(m, botID: bot.id) } }
                toRemove = nil
            }
            Button("Abbrechen", role: .cancel) { toRemove = nil }
        } message: {
            let name = toRemove?.name ?? String(localized: "Die Person")
            Text("\(name) sieht \(bot.name) danach nicht mehr. Der gemeinsame Verlauf bleibt bei dir.")
        }
    }

    private var footer: String {
        members.isEmpty
            ? String(localized: "Lade Personen ein, mit \(bot.name) zu chatten. \(bot.name) läuft weiter auf deinem Server und arbeitet mit deinen Konten und API-Schlüsseln – Freigaben landen immer bei dir.")
            : String(localized: "Gäste arbeiten mit deinen Konten und auf deine Kosten. Freigaben (Mails, Anrufe, kritische Aktionen) landen immer bei dir, Tresor und Passwörter bleiben privat.")
    }

    /// Person: Bild, Name und eine ruhige Zeile mit Rolle und Rechner-Stufe. Die ganze Zeile öffnet das Menü.
    private func memberRow(_ member: ShareMember) -> some View {
        Menu {
            Section("Rolle") {
                Picker("Rolle", selection: Binding(get: { member.role }, set: { role in
                    Task { await store.updateShare(member, botID: bot.id, role: role) }
                })) {
                    ForEach(ShareRole.allCases) { r in Label(r.title, systemImage: r.symbol).tag(r) }
                }
                .pickerStyle(.inline)
            }
            Section("Rechner") {
                Picker("Rechner", selection: Binding(get: { member.computer }, set: { c in
                    Task { await store.updateShare(member, botID: bot.id, computer: c) }
                })) {
                    ForEach(ComputerAccess.allCases) { c in Label(c.title, systemImage: c.symbol).tag(c) }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button(role: .destructive) { toRemove = member } label: { Label("Entfernen …", systemImage: "person.badge.minus") }
        } label: {
            HStack(spacing: 12) {
                PersonAvatar(name: member.name, size: Self.avatar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .appFont(15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(1)
                    Text("\(member.role.title) · \(member.computer.shortTitle)")
                        .appFont(12.5)
                        .foregroundStyle(theme.textSecondary)
                        .adaptiveLineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .groupedRow(vertical: 9)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(member.name), \(member.role.title), Rechner \(member.computer.title)")
        .accessibilityHint("Rolle, Rechner-Zugriff ändern oder entfernen")
    }

    /// Bildgröße der Zeilen; Symbole von Einladung und „Person einladen“ stehen im selben Kreis.
    private static let avatar: CGFloat = 36

    private func circleIcon(_ name: String, tint: Color, background: Color) -> some View {
        Image(systemName: name)
            .appFont(15, weight: .semibold)
            .foregroundStyle(tint)
            .frame(width: Self.avatar, height: Self.avatar)
            .background(background, in: Circle())
    }

    /// Offene Einladung: wie eine Person, das Menü bietet „Widerrufen“.
    private func inviteRow(_ invite: ShareInvite) -> some View {
        Menu {
            Button(role: .destructive) { Task { await store.revokeInvite(invite, botID: bot.id) } } label: {
                Label("Einladung widerrufen", systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 12) {
                circleIcon("envelope.badge", tint: theme.textSecondary, background: theme.selection)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Einladung offen")
                        .appFont(15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(1)
                    Text([invite.role.title, invite.computer.shortTitle, expiryText(invite.expiresAt)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .appFont(12.5)
                        .foregroundStyle(theme.textSecondary)
                        .adaptiveLineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .groupedRow(vertical: 9)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Offene Einladung, \(invite.role.title), \(invite.computer.shortTitle)")
        .accessibilityHint("Einladung widerrufen")
    }

    private var inviteButton: some View {
        Button { showInvite = true } label: {
            HStack(spacing: 12) {
                circleIcon("plus", tint: theme.accent, background: theme.accent.opacity(0.14))
                Text("Person einladen")
                    .appFont(15, weight: .medium)
                    .foregroundStyle(theme.accent)
                Spacer()
            }
            .groupedRow(vertical: 9)
        }
        .buttonStyle(.plain)
    }

    /// Kopfzeile mit Anzahl („Personen · 2“)
    private var header: String {
        members.isEmpty ? String(localized: "Personen") : String(localized: "Personen · \(members.count)")
    }

    /// Kurzinfo für die Zeile „Teilen“ im Profil: „2 Personen“ bzw. „Nicht geteilt“
    static func summary(store: AppStore, bot: Bot) -> String {
        let count = store.shareLists[bot.id]?.members.count ?? bot.shared?.count ?? 0
        return count == 0 ? String(localized: "Nicht geteilt") : String(localized: "\(count) Personen")
    }

    private func expiryText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let days = Int((date.timeIntervalSinceNow / 86400).rounded(.up))
        return days <= 1 ? String(localized: "läuft heute ab") : String(localized: "noch \(days) Tage")
    }
}

/// Blatt „Person einladen“: Rolle und Rechner-Zugriff wählen, Link erzeugen, teilen oder kopieren.
struct InviteSheet: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var role: ShareRole = .write
    @State private var computer: ComputerAccess = .noAccess
    @State private var creating = false
    @State private var created: InviteCreated?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("\(bot.name) teilen", icon: "person.badge.plus") { dismiss() }
            ScrollView {
                GroupedStack {
                    HStack(spacing: 14) {
                        MascotView(mascot: bot.mascot, size: 54, seed: bot.id, animated: false)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bot.name).appFont(17, weight: .semibold).foregroundStyle(theme.textPrimary)
                            Text("Die eingeladene Person chattet mit \(bot.name) in ihrer eigenen AIS-Scoops-App.")
                                .appFont(13).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 4)
                    if let created { linkSection(created) } else { choices }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        #if os(macOS)
        .frame(width: 460, height: 620)
        #endif
        .task {
            // Nur Screenshots: Link gleich erzeugen (`-invitedemo link`)
            let args = ProcessInfo.processInfo.arguments
            if store.isMock, let i = args.firstIndex(of: "-invitedemo"), args.indices.contains(i + 1), args[i + 1] == "link" {
                await create()
            }
        }
    }

    @ViewBuilder
    private var choices: some View {
        GroupedSection("Rolle", dividerInset: 50) {
            ForEach(ShareRole.allCases) { r in
                choiceRow(symbol: r.symbol, title: r.title, detail: r.detail, selected: role == r) { role = r }
            }
        }
        GroupedSection("Rechner", footer: "Unabhängig von der Rolle. Gilt für den Rechner, an dem \(bot.name) arbeitet.",
                       dividerInset: 50) {
            ForEach(ComputerAccess.allCases) { c in
                choiceRow(symbol: c.symbol, title: c.title, detail: c.detail, selected: computer == c) { computer = c }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Gäste arbeiten mit deinen Konten, deinen API-Schlüsseln und auf deine Kosten (Tageslimit pro Gast). Welche Werkzeuge sie nutzen dürfen, legst du unter „Werkzeuge für Geteilte“ fest. Freigaben landen immer bei dir.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .appFont(12.5)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).appFont(13).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await create() } } label: {
                AdaptiveButtonRow(spacing: 8) {
                    if creating { ProgressView().controlSize(.small) }
                    Text("Einladungslink erzeugen")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(creating)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 4)
    }

    private func choiceRow(symbol: String, title: String, detail: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GroupedLabelRow(icon: symbol, iconColor: selected ? theme.accent : nil, title: title, subtitle: detail) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .appFont(19)
                    .foregroundStyle(selected ? theme.accent : theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func linkSection(_ invite: InviteCreated) -> some View {
        let url = invite.shareURL
        GroupedSection("Einladungslink", footer: "Gültig 7 Tage und nur einmal verwendbar. Wer den Link öffnet, sieht \(bot.name), dich als Admin, die Rolle „\(role.title)“ und den Rechner-Zugriff „\(computer.title)“.") {
            Text(url.absoluteString)
                .appFont(13, design: .monospaced)
                .foregroundStyle(theme.textPrimary)
                .adaptiveLineLimit(3)
                .textSelection(.enabled)
                .groupedRow()
            ShareLink(item: url, subject: Text("Einladung zu \(bot.name)"),
                      message: Text("Ich teile meinen Scoop \(bot.name) mit dir. Öffne den Link in AIS Scoops:")) {
                GroupedLabelRow(icon: "square.and.arrow.up", iconColor: theme.accent, title: "Teilen …", titleColor: theme.accent)
            }
            .buttonStyle(.plain)
            Button {
                Clipboard.copy(url.absoluteString)
                copied = true
            } label: {
                GroupedLabelRow(icon: copied ? "checkmark" : "doc.on.doc", iconColor: theme.accent,
                                title: copied ? "Kopiert" : "Link kopieren", titleColor: theme.accent)
            }
            .buttonStyle(.plain)
        }
        Button("Fertig") { dismiss() }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .frame(maxWidth: .infinity)
    }

    private func create() async {
        creating = true
        error = nil
        defer { creating = false }
        do {
            created = try await store.createInvite(botID: bot.id, role: role, computer: computer)
        } catch {
            self.error = store.message(error)
        }
    }
}

/// „Werkzeuge für Geteilte“ (Server-Einstellung pro Scoop), eigene Profilseite unter „Teilen“.
struct GuestToolsSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var settings: SharingSettings? { store.sharingSettings[bot.id] }
    private var tools: GuestTools { settings?.guestTools ?? bot.guestTools ?? .standard }

    var body: some View {
        GroupedSection("Werkzeuge",
                       footer: "Gilt nur für Läufe, die Gäste auslösen. Deine eigenen Läufe nutzen weiter alles. Antworten gehen immer; Tresor und Passwörter sind für Gäste nie erreichbar.",
                       dividerInset: 50) {
            ForEach(Self.visibleGroups(settings: settings, tools: tools), id: \.self) { group in groupRows(group) }
        }
        .task(id: bot.id) { await store.loadSharingSettings(botID: bot.id) }
    }

    /// Kurzinfo für die Zeile „Werkzeuge für Geteilte“: „2 von 4 an“
    static func summary(store: AppStore, bot: Bot) -> String? {
        let settings = store.sharingSettings[bot.id]
        let tools = settings?.guestTools ?? bot.guestTools ?? .standard
        let groups = visibleGroups(settings: settings, tools: tools)
        guard !groups.isEmpty else { return nil }
        let on = groups.filter { tools.isOn($0) }.count
        return on == 0 ? String(localized: "Alle aus") : String(localized: "\(on) von \(groups.count) an")
    }

    /// Gruppen, die der Server anbietet (unbekannte Optionen: alle bekannten zeigen)
    private static func visibleGroups(settings: SharingSettings?, tools: GuestTools) -> [String] {
        let available = settings?.options.available ?? [:]
        return tools.allGroups.filter { group in
            if group == "apps" || group == "mcp" {
                return !(settings?.options.items(group).isEmpty ?? true) || !(tools.items[group]?.isEmpty ?? true)
            }
            return available[group] ?? (GuestTools.Group(rawValue: group) != nil || tools.flags[group] != nil)
        }
    }

    @ViewBuilder
    private func groupRows(_ group: String) -> some View {
        let known = GuestTools.Group(rawValue: group)
        let items = itemOptions(group)
        if items.isEmpty {
            toggleRow(icon: known?.symbol ?? "wrench.and.screwdriver", title: known?.title ?? group, subtitle: known?.detail,
                      isOn: tools.isOn(group), group: group, item: nil)
        } else {
            // Gruppe mit Einzel-Schaltern (Apps, MCPs): Überschriftzeile + je App eine Zeile
            GroupedLabelRow(icon: known?.symbol ?? "square.grid.2x2", title: known?.title ?? group, subtitle: known?.detail)
            ForEach(items) { item in
                toggleRow(icon: nil, title: item.name, subtitle: nil, isOn: tools.isOn(group, item: item.id), inset: true,
                          group: group, item: item.id)
            }
        }
    }

    private func itemOptions(_ group: String) -> [SharingSettings.Option] {
        var options = settings?.options.items(group) ?? []
        for id in (tools.items[group] ?? [:]).keys.sorted() where !options.contains(where: { $0.id == id }) {
            options.append(.init(id: id, name: id))
        }
        return options
    }

    /// Schalter ändern: ganze Gruppe (`item == nil`) bzw. eine App/ein MCP der Gruppe
    private func setTool(group: String, item: String?, on: Bool) {
        var t = tools
        if let item {
            var list = t.items[group] ?? [:]
            for option in itemOptions(group) where list[option.id] == nil { list[option.id] = false }
            list[item] = on
            t.items[group] = list
            t.flags[group] = nil
        } else {
            t.flags[group] = on
        }
        save(t)
    }

    private func toggleRow(icon: String?, title: String, subtitle: String?, isOn: Bool, inset: Bool = false,
                           group: String, item: String?) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary).scaledFrame(width: 22)
            } else if inset {
                Color.clear.scaledFrame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(15).foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle).appFont(12.5).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { isOn }, set: { setTool(group: group, item: item, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
        .groupedRow(vertical: subtitle == nil ? 6 : 10)
    }

    private func save(_ t: GuestTools) {
        Task { await store.setGuestTools(t, botID: bot.id) }
    }
}

/// Tageslimit pro Gast (Server-Einstellung pro Scoop), auf der Profilseite „Teilen“.
struct GuestBudgetSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var budget: Double = 2
    @State private var budgetSave: Task<Void, Never>?

    private var settings: SharingSettings? { store.sharingSettings[bot.id] }

    var body: some View {
        GroupedSection("Tageslimit pro Gast",
                       footer: "Danach antwortet \(bot.name) dem Gast bis morgen nur noch „Tageslimit erreicht“. 0\u{00A0}$ = Gäste können nur mitlesen.") {
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle").appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary).scaledFrame(width: 22)
                Text("\(Formatting.usd(budget)) pro Tag").appFont(15).monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Stepper("Tageslimit", value: $budget, in: 0...100, step: budget < 5 ? 0.5 : 1)
                    .labelsHidden()
            }
            .groupedRow()
        }
        .task(id: bot.id) {
            budget = settings?.guestBudget ?? bot.guestBudget ?? 2
            await store.loadSharingSettings(botID: bot.id)
            budget = settings?.guestBudget ?? bot.guestBudget ?? 2
        }
        .onChange(of: budget) { _, value in
            guard value != (settings?.guestBudget ?? bot.guestBudget ?? 2) else { return }
            budgetSave?.cancel()
            budgetSave = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                await store.setGuestBudget(value, botID: bot.id)
            }
        }
    }
}

// MARK: - Kosten pro Scoop und pro Person

/// Kosten eines Scoops (heute, Monat). Bei geteilten Scoops sieht der Admin die Kosten jeder Person mit ihrem
/// Tageslimit, ein Gast nur seine eigenen Kosten und wie viel vom Tageslimit noch übrig ist.
struct CostSection: View {
    let bot: Bot
    /// Nur „Kosten pro Person“ (Profilseite „Teilen“); ohne Personen erscheint dann nichts.
    var perPersonOnly = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var usage: BotUsage? { store.botUsage[bot.id] }
    private var isGuest: Bool { store.isGuestChat(bot.id) }

    var body: some View {
        Group {
            if perPersonOnly {
                if let usage, !isGuest { personsSection(usage) }
            } else if store.botUsageUnavailable.contains(bot.id) {
                GroupedSection("Kosten", footer: "Kosten pro Scoop kennt erst AIS Scoops Server 1.14. Gesamtkosten: Einstellungen → Kosten.") {
                    GroupedLabelRow(icon: "dollarsign.circle", title: "Noch nicht verfügbar", titleColor: theme.textSecondary)
                }
            } else if let usage {
                if isGuest { guestSection(usage) } else { ownerSection(usage) }
            } else {
                GroupedSection("Kosten") {
                    GroupedLabelRow(icon: "dollarsign.circle", title: "Lade …", titleColor: theme.textSecondary)
                }
            }
        }
        // Beim Öffnen laden und nach jedem Lauf (busy → false) neu
        .task(id: bot.id) { await store.loadBotUsage(botID: bot.id) }
        .onChange(of: bot.busy) { _, busy in
            if !busy { Task { await store.loadBotUsage(botID: bot.id) } }
        }
    }

    @ViewBuilder
    private func ownerSection(_ u: BotUsage) -> some View {
        let persons = u.sortedPersons
        let shared = persons.count > 1 || bot.isSharedByMe
        GroupedSection(String(localized: "Kosten"), footer: shared
                       ? String(localized: "Pro Person zählt, wer den Lauf ausgelöst hat – Sprechmodus eingeschlossen.")
                       : String(localized: "Alle Läufe dieses Scoops, Sprechmodus eingeschlossen.")) {
            totalsRow(today: u.todayUsd, month: u.monthUsd, total: u.totalUsd)
        }
        personsSection(u)
    }

    @ViewBuilder
    private func personsSection(_ u: BotUsage) -> some View {
        let persons = u.sortedPersons
        if persons.count > 1 || bot.isSharedByMe, !persons.isEmpty {
            GroupedSection(String(localized: "Kosten pro Person · Monat"), footer: perPersonOnly ? nil : budgetFooter(u), dividerInset: 60) {
                ForEach(persons) { p in personRow(p, budget: u.guestBudget) }
            }
        }
    }

    /// Kurzinfo für Profilzeilen: „heute 0,12 $“ (Gast: eigene Kosten). Nil, solange nichts geladen ist.
    static func summary(store: AppStore, bot: Bot) -> String? {
        guard let u = store.botUsage[bot.id] else { return nil }
        let today = store.isGuestChat(bot.id) ? (u.byPerson.first { !$0.isOwner }?.todayUsd ?? u.todayUsd) : u.todayUsd
        return String(localized: "heute \(Formatting.usd(today))")
    }

    @ViewBuilder
    private func guestSection(_ u: BotUsage) -> some View {
        let me = u.byPerson.first { !$0.isOwner } ?? u.byPerson.first
        let owner = store.ownerName(of: bot.id) ?? String(localized: "Der Admin")
        GroupedSection("Deine Kosten", footer: "\(owner) bezahlt die Läufe, die du auslöst. Ist dein Tageslimit erreicht, antwortet \(bot.name) dir erst morgen wieder.") {
            totalsRow(today: me?.todayUsd ?? u.todayUsd, month: me?.monthUsd ?? u.monthUsd, total: nil)
            if let budget = u.guestBudget, budget > 0 {
                let left = me?.budgetLeftUsd ?? max(0, budget - (me?.todayUsd ?? u.todayUsd))
                budgetRow(used: budget - left, budget: budget, title: String(localized: "Tageslimit"))
            }
        }
    }

    private func budgetFooter(_ u: BotUsage) -> String? {
        guard let b = u.guestBudget else { return nil }
        return String(localized: "Tageslimit pro Gast: \(Formatting.usd(b)). Ändern unter Profil → „Teilen“.")
    }

    private func totalsRow(today: Double, month: Double, total: Double?) -> some View {
        HStack(spacing: 0) {
            stat("Heute", today)
            Divider().frame(height: 30)
            stat("Monat", month)
            if let total {
                Divider().frame(height: 30)
                stat("Gesamt", total)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: LocalizedStringKey, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(Formatting.usd(value)).appFont(16, weight: .semibold).monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).appFont(12).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func personRow(_ p: BotUsage.Person, budget: Double?) -> some View {
        let role = p.isOwner ? String(localized: "Admin (du)") : (p.role?.title ?? String(localized: "Gast"))
        let today = Formatting.usd(p.todayUsd)
        let detail: String
        if !p.isOwner, let budget, budget > 0 {
            detail = String(localized: "\(role) · heute \(today) von \(Formatting.usd(budget))")
        } else {
            detail = String(localized: "\(role) · heute \(today)")
        }
        return HStack(alignment: .top, spacing: 12) {
            PersonAvatar(name: p.name, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.name).appFont(15, weight: .medium).foregroundStyle(theme.textPrimary).adaptiveLineLimit(1)
                    Spacer(minLength: 8)
                    Text(Formatting.usd(p.monthUsd)).appFont(15, weight: .semibold).monospacedDigit()
                        .foregroundStyle(theme.textPrimary).fixedSize()
                }
                Text(detail).appFont(12.5).foregroundStyle(theme.textSecondary).lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !p.isOwner, let budget, budget > 0 {
                    let left = p.budgetLeftUsd ?? max(0, budget - p.todayUsd)
                    ProgressView(value: min(1, max(0, (budget - left) / budget)))
                        .tint(left <= 0 ? theme.danger : (left < budget * 0.2 ? theme.warning : theme.accent))
                        .padding(.top, 2)
                }
            }
        }
        .groupedRow(vertical: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.name), \(role), diesen Monat \(Formatting.usd(p.monthUsd)), heute \(Formatting.usd(p.todayUsd))")
    }

    private func budgetRow(used: Double, budget: Double, title: String) -> some View {
        let left = max(0, budget - used)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).appFont(15).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(left <= 0 ? "Erreicht" : "noch \(Formatting.usd(left)) von \(Formatting.usd(budget))")
                    .appFont(13.5).monospacedDigit()
                    .foregroundStyle(left <= 0 ? theme.danger : theme.textSecondary)
            }
            ProgressView(value: min(1, max(0, used / budget)))
                .tint(left <= 0 ? theme.danger : (left < budget * 0.2 ? theme.warning : theme.accent))
        }
        .groupedRow(vertical: 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Einladung annehmen (Gast)

/// Blatt nach dem Öffnen eines Einladungslinks: Vorschau (Scoop, Admin, Rolle, Rechner) und „Annehmen“.
/// Ohne Anmeldung zuerst „Mit Apple anmelden“.
struct InviteAcceptSheet: View {
    let code: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var info: InviteInfo?
    @State private var loadError: String?
    @State private var accepting = false
    @State private var acceptError: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Einladung", icon: "person.2") { dismiss() }
            ScrollView {
                VStack(spacing: 18) {
                    if let info { preview(info) } else if let loadError { problem(loadError) } else {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
            }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        #if os(macOS)
        .frame(width: 440, height: 600)
        #endif
        .task(id: code) {
            do {
                info = try await store.account.inviteInfo(code: code)
            } catch {
                loadError = store.message(error)
            }
        }
    }

    @ViewBuilder
    private func preview(_ info: InviteInfo) -> some View {
        VStack(spacing: 8) {
            MascotView(mascot: info.botMascot ?? .default, size: 96, seed: "invite-\(info.botName)", showsGround: true)
                .padding(.top, 10)
            Text(info.botName).appFont(22, weight: .semibold).foregroundStyle(theme.textPrimary)
            if let label = info.botLabel, !label.isEmpty {
                Text(label).appFont(14).foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: 6) {
                PersonAvatar(name: info.ownerName, size: 20)
                Text("\(info.ownerName) lädt dich ein").appFont(14).foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        if let problem = info.problem {
            self.problem(problem)
        } else {
            GroupedSection("Deine Rechte", dividerInset: 50) {
                GroupedLabelRow(icon: info.role.symbol, title: info.role.title, subtitle: info.role.detail)
                GroupedLabelRow(icon: info.computer.symbol, title: "Rechner: \(info.computer.title)", subtitle: info.computer.detail)
            }
            Label {
                Text("\(info.botName) läuft bei \(info.ownerName), mit deren Konten. Alle im Chat sehen deine Nachrichten. \(info.ownerName) kann deine Rechte jederzeit ändern, du kannst jederzeit austreten.")
            } icon: { Image(systemName: "info.circle") }
                .appFont(12.5)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let acceptError {
                Text(acceptError).appFont(13).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.account.isSignedIn {
                Button { accept() } label: {
                    AdaptiveButtonRow(spacing: 8) {
                        if accepting { ProgressView().controlSize(.small) }
                        Text("Annehmen")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(accepting)
                .keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 10) {
                    Text("Melde dich an, um die Einladung anzunehmen.")
                        .appFont(13.5).foregroundStyle(theme.textSecondary)
                    AppleSignInButton(height: 48)
                }
            }
            if let expires = info.expiresAt {
                Text("Gültig bis \(Formatting.shortDate(expires))").appFont(12).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func problem(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus").appFont(34).foregroundStyle(theme.warning)
            Text(text).appFont(15).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            Button("Schließen") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }

    private func accept() {
        accepting = true
        acceptError = nil
        Task {
            if let error = await store.acceptInvite(code: code) {
                acceptError = error
            } else {
                let name = info?.botName ?? "Scoop"
                store.showToast(String(localized: "\(name) steht jetzt unter „Mit mir geteilt“"))
                dismiss()
            }
            accepting = false
        }
    }
}

// MARK: - Gemeinsamer Chat

/// Nachricht einer anderen Person im geteilten Chat: links, mit kleinem Bild und Namen.
struct ForeignUserBubble: View {
    let message: Message
    @Environment(\.theme) private var theme
    @Environment(AppStore.self) private var store

    var body: some View {
        let name = store.authorName(of: message)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PersonAvatar(name: name, size: 20)
                Text(name).appFont(12.5, weight: .semibold).foregroundStyle(theme.textSecondary)
                if message.meta.authorRole == "admin" || (message.meta.authorUserId == nil && store.isGuestChat(message.chatId)) {
                    ShareTag(text: "Admin")
                }
                if let to = message.meta.toPeople, !to.isEmpty {
                    Label("an \(to.joined(separator: ", "))", systemImage: "arrow.turn.down.right")
                        .appFont(12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.leading, 4)
            .accessibilityHidden(true)
            if message.text.isEmpty, let ref = message.meta.replyTo {
                ReplyQuote(ref: ref, chatID: message.chatId).frame(maxWidth: 280)
            }
            if let ids = message.meta.fileIds, !ids.isEmpty {
                MessageAttachments(fileIDs: ids)
            }
            if !message.text.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    Text(Mentions.attributed(message.text, bots: store.bots, theme: theme))
                        .appFont(15)
                        .lineSpacing(3)
                        .foregroundStyle(theme.textPrimary)
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                        .withReplyQuote(message.meta.replyTo, chatID: message.chatId)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.userBubble.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.surfaceBorder))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ReplyQuote.accessibilityPrefix(message.meta.replyTo) + "\(name): \(message.text)")
                        .accessibilityAction(named: "Kopieren") { Clipboard.copy(message.text) }
                        .messageReactions(message, trailing: false, copyText: message.text)
                    if message.meta.voice == true {
                        Image(systemName: "waveform")
                            .appFont(11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.bottom, 10)
                            .accessibilityLabel("Gesprochen")
                    }
                    Spacer(minLength: 60)
                }
                if message.meta.edited != nil { EditedLabel() }
                MessageLinkPreview(text: message.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Freigabe-Karten im geteilten Chat: Gäste sehen den Stand ohne Knöpfe, entschieden wird beim Admin.
struct GuestApprovalGate<Content: View>: View {
    let message: Message
    @ViewBuilder var content: Content
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        if store.isGuestChat(message.chatId) || message.meta.guestView == true {
            guestCard
        } else {
            VStack(alignment: .leading, spacing: 4) {
                content
                if let name = message.meta.requestedBy?.name {
                    Label("Angefragt von \(name)", systemImage: "person.fill.questionmark")
                        .appFont(11.5, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 6)
                }
            }
        }
    }

    private var guestCard: some View {
        let owner = store.ownerName(of: message.chatId) ?? String(localized: "den Admin", comment: "Steht für den Namen des Admins: „Freigegeben durch den Admin“")
        let state = message.meta.state ?? "pending"
        let title: String = {
            if let t = message.meta.title, message.meta.guestView == true, !t.isEmpty { return t }
            switch state {
            case "pending": return String(localized: "Wartet auf Freigabe durch \(owner)")
            case "approved": return String(localized: "Freigegeben durch \(owner)")
            default: return String(localized: "Abgelehnt durch \(owner)")
            }
        }()
        let icon = state == "pending" ? "hourglass" : (state == "approved" ? "checkmark.circle.fill" : "xmark.circle.fill")
        let color = state == "pending" ? theme.warning : (state == "approved" ? theme.success : theme.textTertiary)
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .appFont(13)
                .foregroundStyle(color)
                .scaledFrame(26)
                .background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(14, weight: .semibold).foregroundStyle(theme.textPrimary)
                if state == "pending" {
                    Text("\(owner) entscheidet über Mails, Anrufe und andere wichtige Schritte.")
                        .appFont(12.5).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Statt Eingabefeld bei der Rolle „Lesen“
struct ReadOnlyComposerHint: View {
    let chatID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let owner = store.ownerName(of: chatID) ?? String(localized: "Der Admin")
        Label {
            Text("Du kannst hier nur mitlesen. \(owner) hat dir die Rolle „Lesen“ gegeben.")
        } icon: {
            Image(systemName: "eye")
        }
        .appFont(13.5)
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.surfaceBorder))
        .accessibilityElement(children: .combine)
    }
}
