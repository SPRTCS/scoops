import SwiftUI

/// Einstellungen: Konto, Verbindung, Erscheinungsbild, Kosten, Über.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false
    @State private var showVault = false
    @State private var showServers = false

    @State private var showInitiative = ProcessInfo.processInfo.arguments.contains("-settingsinitiative")
    /// Seite „Nutzung und Verbrauch“ (Server 1.31); `-usage` öffnet sie direkt (Screenshots)
    @State private var showUsage = ProcessInfo.processInfo.arguments.contains("-usage")
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            SheetHeader("Einstellungen") { dismiss() }
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    GroupedStack {
                        AccountSettingsSection()
                        connectionsSection
                        appearance
                        appIconSection
                        initiativeSection
                        ComputersSection().id("nodes")
                        WorkspaceSettingsSection()
                        AboSettingsSection()
                        vaultSection
                        connection
                        costs
                        onboardingSection
                        about
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .task {
                    // Nur Screenshots: `-settingsnodes` scrollt zum Abschnitt „Rechner“
                    guard ProcessInfo.processInfo.arguments.contains("-settingsnodes") else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo("nodes", anchor: .top)
                }
            }
        }
        .background(theme.groupedBackground)
        .onAppear {
            url = store.settings.usesAccount ? ConnectionSettings.suggestedURL : store.settings.serverURL
            token = store.settings.usesAccount ? ConnectionSettings.storedToken : store.settings.token
        }
        .task {
            await store.loadUsage()
            await store.loadInitiative()
            await store.loadConnections()
        }
        .sheet(isPresented: $showInitiative) {
            InitiativeSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .sheet(isPresented: $showVault) {
            VaultView().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        #if os(iOS)
        .onAppear { if UsageRouter.shared.consume() { showUsage = true } }
        .onChange(of: UsageRouter.shared.requests) { _, _ in if UsageRouter.shared.consume() { showUsage = true } }
        .fullScreenCover(isPresented: $showUsage) {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-widgetgallery") { LimitsWidgetGallery() } else { UsageView() }
            }
            .storeShotStatusBar()
            .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        #else
        .onAppear { if showUsage { showUsage = false; openWindow(id: UsageView.windowID) } }
        #endif
        #if os(macOS)
        .frame(width: 580, height: 680)
        #endif
    }

    // MARK: Erscheinungsbild

    private var appearance: some View {
        @Bindable var store = store
        return GroupedSection("Erscheinungsbild",
                              footer: "„System“ folgt dem Hell- oder Dunkelmodus deines Geräts: Nacht bei Dunkel, Hell bei Hell.") {
            // Umbrechend: drei Karten nebeneinander passen auf schmalen Bildschirmen (iPhone Duo zugeklappt) nicht –
            // vorher wurde die ganze Seite breiter als der Bildschirm und links abgeschnitten.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button { withAnimation(.smooth) { store.appearance = mode } } label: {
                        ThemePreviewCard(mode: mode, selected: store.appearance == mode)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Erscheinungsbild \(mode.displayName)")
                    .accessibilityAddTraits(store.appearance == mode ? .isSelected : [])
                }
            }
            .groupedRow(vertical: 14)
        }
    }

    private var appIconSection: some View {
        #if os(iOS)
        let footer = "Das Symbol auf dem Home-Bildschirm. iOS bestätigt den Wechsel kurz mit einer Meldung."
        #else
        let footer = "Auf dem Mac ändert sich das Symbol im Dock, solange AIS Scoops läuft."
        #endif
        return GroupedSection("App-Symbol", footer: footer) {
            AppIconPicker()
        }
    }

    // MARK: Initiative und Tresor (v1.4)

    private var initiativeSection: some View {
        GroupedSection("Haupt-Scoop", footer: "Der Haupt-Scoop prüft zu festen Zeiten To-dos, Mails und Termine und meldet sich nur, wenn es etwas Wichtiges gibt.") {
            Button { showInitiative = true } label: {
                HStack(spacing: 12) {
                    if let primary = store.primaryBot {
                        ZStack(alignment: .bottomTrailing) {
                            MascotView(mascot: primary.mascot, size: 30, seed: primary.id, animated: false)
                            PrimaryBadge(size: 13).offset(x: 3, y: 3)
                        }
                        .frame(width: 30)
                    } else {
                        Image(systemName: "crown").font(.system(size: 15)).foregroundStyle(theme.textSecondary).frame(width: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Initiative").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        Text(initiativeSummary).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    DisclosureChevron()
                }
                .groupedRow(vertical: 8)
            }
            .buttonStyle(.plain)
        }
    }

    private var initiativeSummary: String {
        guard let primary = store.primaryBot else { return "Noch kein Haupt-Scoop gewählt" }
        guard let s = store.initiative else { return primary.name }
        guard s.enabled else { return "\(primary.name) · aus" }
        return "\(primary.name) · \(s.times.joined(separator: ", "))"
    }

    @State private var showConnections = false

    private var connectionsSection: some View {
        GroupedSection("Apps verbinden", footer: "Gmail, Notion, Kalender und mehr – auch mehrere Konten pro App. Deine Scoops nutzen sie für ihre Aufgaben.") {
            Button { showConnections = true } label: {
                GroupedLabelRow(icon: "link", iconColor: theme.accent, title: "Apps verbinden", subtitle: connectionsSummary) {
                    DisclosureChevron()
                }
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showConnections) {
            ConnectionsView().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }

    private var connectionsSummary: String {
        guard let c = store.connections else { return "Konten bei Gmail, Notion & Co." }
        let n = c.apps.reduce(0) { $0 + $1.accounts.count }
        let apps = c.apps.filter { !$0.accounts.isEmpty }.count
        return n == 0 ? "Noch keine Konten" : "\(n) \(n == 1 ? "Konto" : "Konten") in \(apps) \(apps == 1 ? "App" : "Apps")"
    }

    private var vaultSection: some View {
        GroupedSection("Tresor", footer: "Logins, mit denen sich deine Scoops auf Webseiten anmelden. Passwörter liegen nur im Schlüsselbund deines Macs; deine Scoops sehen nur Titel, Webseite und Benutzername.") {
            Button { showVault = true } label: {
                GroupedLabelRow(icon: "lock.shield", iconColor: theme.success, title: "Tresor öffnen",
                                subtitle: "Mit Face ID, Touch ID oder Code") { DisclosureChevron() }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Verbindung

    @ViewBuilder
    private var connection: some View {
        if store.settings.usesAccount {
            accountConnection
        } else {
            tokenConnection
        }
    }

    /// Verbindung über das Konto: Server aus „Deine Server“, kein Token nötig.
    private var accountConnection: some View {
        GroupedSection("Verbindung", footer: "Verbunden über dein Konto. Die App meldet sich mit deiner Sitzung beim Server an, ein Token ist nicht nötig.") {
            statusRow
            HStack(spacing: 12) {
                Text("Server").font(.system(size: 15)).foregroundStyle(theme.textPrimary).frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.settings.cloudServerName ?? "Server").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                    if let host = store.settings.baseURL?.host(), !store.settings.isMock {
                        Text(host).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .groupedRow()
            HStack {
                Button("Trennen", role: .destructive) { store.disconnect() }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.danger)
                Spacer()
                Button("Server wechseln") { showServers = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .font(.system(size: 15))
            .groupedRow(vertical: 8)
        }
        .sheet(isPresented: $showServers) {
            ServerSwitcherSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
            Spacer()
            if let v = store.serverVersion {
                Text("Server \(v)").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            }
        }
        .groupedRow()
    }

    private var tokenConnection: some View {
        GroupedSection("Verbindung", footer: "Ein Kopplungslink aisbot://pair?url=…&token=… vom Server trägt beides automatisch ein. Der Token liegt im Schlüsselbund.") {
            statusRow
            formRow("Server") {
                TextField("https://…ts.net", text: $url)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            formRow("Token") {
                SecureField("Token vom Server", text: $token).textFieldStyle(.plain)
            }
            HStack {
                Button("Trennen", role: .destructive) { store.disconnect() }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.danger)
                Spacer()
                if let checkResult {
                    Text(checkResult).font(.system(size: 12.5)).foregroundStyle(checkOK ? theme.success : theme.danger)
                        .lineLimit(2)
                }
                if checking { ProgressView().controlSize(.small) }
                Button("Verbinden") { connect() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(checking || url.isEmpty)
            }
            .font(.system(size: 15))
            .groupedRow(vertical: 8)
        }
    }

    private func formRow<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundStyle(theme.textPrimary).frame(width: 70, alignment: .leading)
            content().font(.system(size: 15)).foregroundStyle(theme.textPrimary)
        }
        .groupedRow()
    }

    private var statusColor: Color {
        switch store.phase {
        case .online: store.socketState == .connected ? theme.success : theme.warning
        case .connecting: theme.warning
        case .offline: theme.danger
        case .unconfigured: theme.textTertiary
        }
    }

    private var statusText: String {
        if store.isMock { return store.settings.usesAccount ? "Demo-Modus (Beispielkonto)" : "Demo-Modus (ohne Server)" }
        switch store.phase {
        case .online:
            switch store.socketState {
            case .connected: return "Verbunden, live"
            case .reconnecting: return "Verbunden, Live-Kanal verbindet neu …"
            default: return "Verbunden"
            }
        case .connecting: return "Verbinde …"
        case .offline(let m): return "Offline: \(m)"
        case .unconfigured: return "Nicht eingerichtet"
        }
    }

    private func connect() {
        let candidate = ConnectionSettings(serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                           token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        checking = true
        checkResult = nil
        Task {
            do {
                let h = try await store.validate(candidate)
                checkOK = true
                checkResult = "Verbunden\(h.version.map { " (Server \($0))" } ?? "")."
                await store.connect(with: candidate, persist: true)
            } catch {
                checkOK = false
                checkResult = "Keine Verbindung: \(error.localizedDescription)"
            }
            checking = false
        }
    }

    // MARK: Kosten

    @ViewBuilder
    private var costs: some View {
        if let u = store.usage {
            GroupedSection("Kosten", footer: u.byModel.isEmpty ? nil : "Aufteilung pro Modell für diesen Monat.") {
                costRow("Heute", u.todayUsd, bold: true)
                costRow("Dieser Monat", u.monthUsd, bold: true)
                ForEach(u.byModel.sorted { $0.value > $1.value }, id: \.key) { key, value in
                    costRow(BotModel.displayName(for: key), value, bold: false)
                }
                usageButton
            }
            if let abo = u.abo, abo.monthRuns > 0 {
                // Server 1.30: Läufe über KI-Abos (Claude Code/Codex mit Abo) ohne Betrag
                GroupedSection("Über Abos", footer: "Diese Läufe gingen über dein Claude- bzw. ChatGPT-Abo und kosten nichts extra; sie zählen auf die Limits des Abos.") {
                    runsRow("Heute", abo.todayRuns, bold: true)
                    runsRow("Dieser Monat", abo.monthRuns, bold: true)
                    ForEach(abo.byModel.sorted { $0.value.runs > $1.value.runs }, id: \.key) { key, value in
                        runsRow(BotModel.displayName(for: key), value.runs, bold: false)
                    }
                }
            }
            if !u.byBot.isEmpty {
                // Server 1.14: Kosten pro Scoop (geteilte Scoops mit Personen-Symbol; Details im Profil des Scoops)
                GroupedSection("Pro Scoop", footer: "Dieser Monat, teuerste zuerst. Geteilte Scoops zeigen im Profil die Kosten pro Person.",
                               dividerInset: 56) {
                    ForEach(u.byBot.sorted { $0.value.monthUsd > $1.value.monthUsd }, id: \.key) { id, cost in
                        botCostRow(id, cost)
                    }
                }
            }
        } else {
            GroupedSection("Kosten") {
                GroupedLabelRow(title: store.phase == .online ? "Lade …" : "Nur mit Verbindung zum Server verfügbar.",
                                titleColor: theme.textSecondary)
            }
        }
    }

    /// Server 1.31: eigene Seite mit Kosten, Tokens und Abo-Limits aller Apps (docs/nutzung.md)
    private var usageButton: some View {
        let supported = store.supportsUsageDetails
        return Button {
            #if os(macOS)
            openWindow(id: UsageView.windowID)
            #else
            showUsage = true
            #endif
        } label: {
            GroupedLabelRow(icon: "chart.bar.xaxis", iconColor: supported ? theme.accent : theme.textTertiary,
                            title: "Nutzung und Verbrauch",
                            subtitle: supported ? "Kosten, Tokens und Abo-Limits aller Apps"
                                                : "Server aktualisieren (ab Version 1.31)",
                            titleColor: supported ? nil : theme.textSecondary) {
                if supported { DisclosureChevron() }
            }
        }
        .buttonStyle(.plain)
        .disabled(!supported)
        .accessibilityHint(supported ? "Öffnet die Übersicht über Kosten, Tokens und Limits" : "Braucht Server 1.31")
    }

    private func runsRow(_ title: String, _ runs: Int, bold: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(bold ? theme.textPrimary : theme.textSecondary)
            Spacer()
            Text(runs == 1 ? "1 Lauf" : "\(runs) Läufe")
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(bold ? theme.textPrimary : theme.textSecondary)
        }
        .groupedRow()
    }

    private func botCostRow(_ id: String, _ cost: Usage.BotCost) -> some View {
        let bot = store.ownBot(id)
        return HStack(spacing: 12) {
            if let bot {
                MascotView(mascot: bot.mascot, size: 28, seed: bot.id, animated: false)
            } else {
                Image(systemName: "questionmark.circle").foregroundStyle(theme.textTertiary).frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(bot?.name ?? "Gelöschter Scoop").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                    if bot?.isSharedByMe == true {
                        Image(systemName: "person.2.fill").font(.system(size: 10.5)).foregroundStyle(theme.textTertiary)
                            .accessibilityLabel("geteilt")
                    }
                }
                Text("Heute \(Formatting.usd(cost.todayUsd))").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Text(Formatting.usd(cost.monthUsd)).font(.system(size: 15)).monospacedDigit().foregroundStyle(theme.textPrimary)
        }
        .groupedRow(vertical: 8)
        .accessibilityElement(children: .combine)
    }

    private func costRow(_ title: String, _ value: Double, bold: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(bold ? theme.textPrimary : theme.textSecondary)
            Spacer()
            Text(Formatting.usd(value))
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(bold ? theme.textPrimary : theme.textSecondary)
        }
        .groupedRow()
    }

    // MARK: Einführung

    private var onboardingSection: some View {
        @Bindable var onboarding = store.onboarding
        return GroupedSection("Einführung", footer: "Zeigt dir noch einmal Schritt für Schritt, wie du einen Server verbindest und einen Scoop gestaltest. Deine Scoops und Chats bleiben, wie sie sind.") {
            Button {
                onboarding.startReplay()
                store.showSettings = false
                dismiss()
            } label: {
                GroupedLabelRow(icon: "sparkles", iconColor: theme.accent, title: "Einführung erneut ansehen") {
                    DisclosureChevron()
                }
            }
            .buttonStyle(.plain)
            GroupedLabelRow(icon: "lightbulb", iconColor: theme.warning, title: "Tipps am Ende zeigen",
                            subtitle: "Teilen, Widgets und Apple Watch") {
                Toggle("Tipps am Ende zeigen", isOn: $onboarding.showsTips)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
            }
        }
    }

    // MARK: Über

    private var about: some View {
        GroupedSection("Über") {
            HStack(spacing: 14) {
                AppIconArtwork(variant: AppIconSwitcher.current, canvas: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AIS Scoops").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))")
                        .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                    Text("Deine Scoops: kleine Kollegen mit Charakter, Gedächtnis und eigenem Rechner.")
                        .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                }
            }
            .groupedRow(vertical: 12)
        }
    }
}

/// Kleine Vorschau eines Erscheinungsbilds (System: diagonal links Nacht, rechts Hell).
struct ThemePreviewCard: View {
    let mode: AppearanceMode
    let selected: Bool
    @Environment(\.theme) private var current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch mode {
                case .system:
                    miniature(.hell)
                        .overlay {
                            miniature(.nacht).mask {
                                GeometryReader { g in
                                    Path { p in
                                        p.move(to: .zero)
                                        p.addLine(to: CGPoint(x: g.size.width * 0.62, y: 0))
                                        p.addLine(to: CGPoint(x: g.size.width * 0.38, y: g.size.height))
                                        p.addLine(to: CGPoint(x: 0, y: g.size.height))
                                        p.closeSubpath()
                                    }
                                }
                            }
                        }
                case .nacht: miniature(.nacht)
                case .hell: miniature(.hell)
                }
            }
            .frame(height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(current.surfaceBorder))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(mode.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(current.textPrimary)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(current.accent).font(.system(size: 12)) }
                }
                Text(mode.subtitle).font(.system(size: 11.5)).foregroundStyle(current.textSecondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(current.groupedBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? current.accent : current.surfaceBorder, lineWidth: selected ? 2 : 1))
    }

    /// Mini-Fenster eines Entwurfs: Seitenleiste mit Maskottchen-Punkten, Verlauf mit Blasen.
    private func miniature(_ kind: ThemeKind) -> some View {
        let t = kind.theme
        return HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<3) { i in
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: Mascot.palette[[8, 7, 4][i]].hex)).frame(width: 9, height: 9)
                            Capsule().fill(t.textTertiary.opacity(0.6)).frame(width: 26, height: 4)
                        }
                    }
                }
                .padding(7)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(t.sidebarBackground)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 5).fill(t.surface).frame(width: 64, height: 18)
                        .shadow(color: t.cardShadow, radius: 3, y: 1)
                    HStack { Spacer(); Capsule().fill(t.userBubble).frame(width: 36, height: 10) }
                    RoundedRectangle(cornerRadius: 5).fill(t.surface).frame(width: 50, height: 12)
                        .shadow(color: t.cardShadow, radius: 3, y: 1)
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(t.background)
            }
    }
}
