import SwiftUI
import QuickLook

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Size-Class, nach der das Layout gebaut wird. Folgt `sizeClass` nur, solange die Szene aktiv ist.
    ///
    /// Im Hintergrund rendert iOS Schnappschüsse in anderer Größe (iPhone Duo aufgeklappt: kurz `compact`, dann
    /// wieder `regular`). Ohne Einfrieren wechselte das Layout dabei auf den Stapel und zurück: Der Chat wurde neu
    /// aufgebaut, und das offene Profil (`.inspector`) wurde in kompakter Breite als Sheet präsentiert. Dieses Sheet
    /// blieb nach der Rückkehr als leeres, verschwommenes Blatt über der rechten Spalte hängen.
    @State private var layoutSizeClass: UserInterfaceSizeClass?
    /// Gilt für Layout und Unteransichten (Split-View, Inspector), siehe `layoutSizeClass`.
    private var effectiveSizeClass: UserInterfaceSizeClass? { layoutSizeClass ?? sizeClass }
    /// Tatsächliche Size-Class weicht vom eingefrorenen Layout ab (nur im Hintergrund möglich)
    private var sizeClassFrozen: Bool { sizeClass != effectiveSizeClass }
    /// Höhe der Chat-Pille, an der die Profilspalte ihren Schließen-Knopf ausrichtet (iPad, Duo aufgeklappt)
    @State private var headerAnchor = ChatHeaderAnchor()
    #endif
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// Ampelknöpfe im Fenster (für den Glas-Knopf „Seitenleiste einblenden“ daneben), `nil` im Vollbild
    @State private var titlebarButtons: CGRect?
    #endif
    #if os(macOS)
    /// Höchstbreite des Profils (Inspector) auf dem Mac
    private let inspectorMaxWidth: CGFloat = 380
    #endif

    var body: some View {
        @Bindable var store = store
        let theme = store.currentTheme
        Group {
            // Einführung (neue Nutzer) bzw. Anmelden/Server wählen ohne Verbindung. Nur geteilte Scoops (kein eigener
            // Server): trotzdem die App zeigen, „Mit mir geteilt“ in der Seitenleiste (`onboardingPresentation`).
            if let mode = store.onboardingPresentation {
                OnboardingFlowView(mode: mode)
            } else {
                #if os(iOS)
                Group {
                    if effectiveSizeClass == .compact { compactStack } else { split }
                }
                // Split-View und Inspector lesen die Size-Class aus der Umgebung: auch dort die eingefrorene
                // verwenden, sonst klappen sie bei Hintergrund-Schnappschüssen trotzdem um (Inspector → Sheet).
                .environment(\.horizontalSizeClass, effectiveSizeClass)
                #else
                split
                #endif
            }
        }
        // Befehlspalette (⌘K) und kurze Hinweise als Ebene über allem (keine Präsentation)
        .overlay {
            if store.showCommandPalette, store.phase != .unconfigured {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .appFont(13.5, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.surfaceBorder))
                    .shadow(color: .black.opacity(theme.kind == .nacht ? 0.4 : 0.12), radius: 16, y: 6)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        // Geteilte Inhalte, die noch nicht gesendet werden konnten (Teilen-Menü, docs/system.md)
        .overlay(alignment: .bottom) { ShareOutboxBanner() }
        .animation(.snappy(duration: 0.18), value: store.showCommandPalette)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.preferredScheme)
        .modifier(DeviceSchemeTracker())
        #if os(iOS)
        // Navigations- und Toolbar-Knöpfe in Textfarbe (weiß in Nacht, #111 in Hell) statt Systemblau.
        // Links, Schalter und Hervorhebungen setzen ihren Akzent selbst.
        .tint(theme.textPrimary)
        #else
        .tint(theme.accent)
        #endif
        .sheet(isPresented: $store.showCreateBot) {
            CreateBotView(editing: store.editingBot)
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
                .storeShotStatusBar()
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $store.showCreateGroup) {
            CreateGroupView()
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        // Scoop-Vorlagen: Vorschau vor dem Import, Export-Vorschau, Datei ins Fenster ziehen (docs/vorlagen.md)
        .modifier(TemplateHost())
        // Ruhezeiten aus der Befehlspalette (docs/ruhe.md)
        .sheet(isPresented: Binding(get: { store.ruhe.showSheet }, set: { store.ruhe.showSheet = $0 })) {
            QuietHoursSheet()
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        #if os(iOS)
        .fullScreenCover(item: voiceBinding) { item in
            VoiceModeView(chatID: item.id, demoPhase: voiceDemoPhase)
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
                .storeShotStatusBar()
        }
        #else
        .sheet(item: voiceBinding) { item in
            VoiceModeView(chatID: item.id, demoPhase: voiceDemoPhase)
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        #endif
        // Markdown (Berichte der Scoops) im eigenen Viewer, alles andere in Quick Look
        .quickLookPreview(Binding(get: { store.previewURL.flatMap { MarkdownDocumentView.handles($0) ? nil : $0 } },
                                  set: { store.previewURL = $0 }))
        .sheet(item: Binding(get: { store.previewURL.flatMap { MarkdownDocumentView.handles($0) ? PreviewDocument(url: $0) : nil } },
                             set: { if $0 == nil { store.previewURL = nil } })) { doc in
            MarkdownDocumentView(url: doc.url)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        // Einladungslink geöffnet (aisscoops://invite/<code>, https://…/i/<code>)
        .sheet(item: Binding(get: { store.presentedInviteCode.map(IdentifiedString.init) },
                             set: { store.presentedInviteCode = $0?.id })) { item in
            InviteAcceptSheet(code: item.id)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        // Kopplungslink (aisscoops://link?code=…), während schon ein Server verbunden ist
        .sheet(item: Binding(get: { store.onboarding.linkSheetCode.map(IdentifiedString.init) },
                             set: { store.onboarding.linkSheetCode = $0?.id })) { item in
            AddServerSheet(initialCode: item.id)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        // Nur geteilte Scoops: eigenen Server einrichten
        .sheet(isPresented: $store.showOwnServerSetup) {
            OnboardingFlowView(mode: .connectOnly)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                #if os(macOS)
                .frame(minWidth: 620, minHeight: 640)
                #endif
        }
        .onChange(of: store.phase) { _, phase in
            if phase != .unconfigured { store.showOwnServerSetup = false }
            if phase == .online { store.onboardingDidConnect() }
        }
        .sheet(item: Binding(get: { store.presentedSkillID.map(IdentifiedString.init) },
                             set: { store.presentedSkillID = $0?.id })) { item in
            SkillDetailView(skillID: item.id)
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .sheet(isPresented: $store.showInitiative) {
            InitiativeSheet()
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                .storeShotStatusBar()
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { store.showTaskBoard && isCompactLayout && store.phase != .unconfigured },
                                    set: { if !$0 { store.showTaskBoard = false } })) {
            TaskBoardView { store.showTaskBoard = false }
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                .storeShotStatusBar()
                .presentationDetents([.large])
        }
        #endif
        // Anderer Chat gewählt (Seitenleiste, Mitteilung): Board schließen
        .onChange(of: store.selectedChatID) { _, id in
            if id != nil, !isCompactLayout { store.showTaskBoard = false }
        }
        .sheet(isPresented: $store.showConnections) {
            ConnectionsView()
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                .storeShotStatusBar()
        }
        .sheet(isPresented: $store.showVault) {
            VaultView()
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .sheet(isPresented: $store.showScreenViewer) {
            ScreenViewer(botName: store.bot(store.computer.botId ?? store.selectedChatID)?.name ?? "")
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        #if os(iOS)
        .sheet(isPresented: $store.showServerSwitcher) {
            ServerSwitcherSheet()
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        #endif
        #if os(iOS)
        .sheet(item: compactInspectorSheet) { item in
            InspectorContent(chatID: item.id)
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.inspectorBackground)
        }
        #endif
        .alert("Hoppla", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        #if os(macOS)
        .onChange(of: UsageRouter.shared.requests) { _, _ in
            if UsageRouter.shared.consume() { openWindow(id: UsageView.windowID) }
        }
        .onChange(of: store.showSettings) { _, show in
            if show { openSettings(); store.showSettings = false }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            store.isAppActive = phase == .active
            #if os(iOS)
            // Zurück im Vordergrund: tatsächliche Size-Class übernehmen (z. B. im Hintergrund zugeklappt)
            if phase == .active, layoutSizeClass != sizeClass { layoutSizeClass = sizeClass }
            #endif
        }
        #if os(iOS)
        .onChange(of: sizeClass, initial: true) { _, newClass in
            // Nur im Vordergrund folgen (Auf-/Zuklappen, Stage Manager, Split View). Im Hintergrund sind das nur
            // Schnappschüsse des Systems, die das Layout nicht umbauen dürfen.
            if scenePhase == .active || layoutSizeClass == nil { layoutSizeClass = newClass }
        }
        #endif

    }

    /// iPhone (kompakte Breite): Board als Blatt statt in der Mitte
    private var isCompactLayout: Bool {
        #if os(iOS)
        effectiveSizeClass == .compact
        #else
        false
        #endif
    }

    private var voiceBinding: Binding<IdentifiedString?> {
        Binding(get: { store.voiceChatID.map(IdentifiedString.init) }, set: { store.voiceChatID = $0?.id })
    }

    /// Startargument `-voicedemo` (Gerätestimme) bzw. `-livedemo` (Live): Sprechmodus ohne Mikrofon (für Screenshots).
    private var voiceDemoPhase: VoiceModeView.Phase? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-livedemo") { return .live }
        return args.contains("-voicedemo") ? .speaking : nil
    }

    private var split: some View {
        #if os(iOS)
        // Profil als eigene Spalte neben dem Split-View statt `.inspector`, siehe `profileColumn`
        HStack(spacing: 0) {
            splitView
            profileColumn
        }
        .animation(.snappy(duration: 0.3), value: profileColumnChatID != nil)
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        @Bindable var store = store
        let theme = store.currentTheme
        return NavigationSplitView(columnVisibility: $store.sidebarColumns) {
            SidebarView()
                #if os(macOS)
                .frame(minWidth: MacWindowLayout.sidebarMinWidth, idealWidth: theme.sidebarWidth)
                #endif
                .navigationSplitViewColumnWidth(min: 250, ideal: theme.sidebarWidth, max: 340)
                #if os(macOS)
                .toolbar(removing: .sidebarToggle)
                #endif
        } detail: {
            Group {
                if store.showTaskBoard && !isCompactLayout {
                    // Aufgaben-Board statt des Chats in der Mitte (Mac, iPad)
                    TaskBoardView { store.showTaskBoard = false }
                        .transition(.opacity)
                } else if let id = store.selectedChatID, store.chatExists(id) {
                    chat(id)
                } else {
                    placeholder
                }
            }
            .animation(.snappy(duration: 0.2), value: store.showTaskBoard)
            #if os(macOS)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .background { theme.background.ignoresSafeArea() }
        #if os(macOS)
        // AppKit klappt die Seitenleiste bei zu schmalem Fenster selbst ein (Bildschirmwechsel): abgleichen und
        // wieder einblenden, siehe `SidebarSync`.
        .background { SidebarSync(store: store) { titlebarButtons = $0 } }
        .overlay(alignment: .topLeading) { sidebarRevealButton }
        .animation(.snappy(duration: 0.2), value: store.sidebarHidden)
        #endif
    }

    #if os(macOS)
    /// Seitenleiste zu: runder Glas-Knopf neben den Ampelknöpfen, damit es immer einen sichtbaren Weg zurück gibt
    /// (der System-Knopf ist entfernt, siehe `.toolbar(removing: .sidebarToggle)`).
    @ViewBuilder private var sidebarRevealButton: some View {
        if store.sidebarHidden {
            let size = SidebarRevealButton.size
            SidebarRevealButton()
                .padding(.leading, titlebarButtons.map { $0.maxX + 14 } ?? 14)
                .padding(.top, titlebarButtons.map { max(2, ($0.midY - size / 2).rounded()) } ?? 8)
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }
    #endif

    /// Chat. Mac: Profil als Inspector (rechte Spalte). iPad/iPhone Duo aufgeklappt: eigene Spalte neben dem
    /// Split-View (`profileColumn`). Kompakte Breite (iPhone, Duo zugeklappt): Blatt (`compactInspectorSheet`).
    private func chat(_ id: String) -> some View {
        #if os(iOS)
        ChatView(chatID: id)
            .id(id)
            .environment(headerAnchor)
        #else
        let theme = store.currentTheme
        return ChatView(chatID: id)
            .id(id)
            .inspector(isPresented: Bindable(store).showInspector) {
                InspectorContent(chatID: id)
                    .inspectorColumnWidth(min: 280, ideal: theme.inspectorWidth, max: inspectorMaxWidth)
                    .environment(\.theme, theme)
            }
        #endif
    }

    #if os(iOS)
    /// Chat, dessen Profil die rechte Spalte zeigt (`nil`: Spalte zu). Wie früher der Inspector nur neben einem
    /// Chat, nicht neben Aufgaben-Board oder Platzhalter.
    private var profileColumnChatID: String? {
        guard store.showInspector, !store.showTaskBoard, let id = store.selectedChatID, store.chatExists(id) else {
            return nil
        }
        return id
    }

    /// Profil auf iPad und iPhone Duo (aufgeklappt) als eigene Spalte rechts neben dem Split-View.
    ///
    /// Früher war das `.inspector` am Chat. Dessen Spalte liegt in UIKit aber unter der Navigationsleiste
    /// des Chats: Die reservierte über der Spalte ihre Höhe (Duo aufgeklappt 82 pt, iPad 86 pt) als sicheren Bereich,
    /// das Profil begann erst darunter (leerer Streifen über dem Schließen-Knopf). Eigene Knöpfe in dieser Höhe
    /// waren nicht antippbar, die Leiste fing die Tipps ab, und Leisten-Einträge aus dem Profil landeten im Chat
    /// (Zurück neben der Pille, Titel in der Mitte, auf dem Duo in der senkrechten Leiste). Neben dem Split-View
    /// liegt keine Leiste über der Spalte, die Profil-Kopfleiste steht auf der Höhe der Chat-Pille
    /// (`ChatHeaderAnchor`).
    ///
    /// Size-Class-Wechsel: Die Spalte gehört zur breiten Darstellung (`split`) und folgt damit der eingefrorenen
    /// Size-Class (`effectiveSizeClass`). Im Hintergrund (Schnappschüsse) bleibt sie stehen, beim Zuklappen
    /// übernimmt das Blatt (`compactInspectorSheet`), beim Aufklappen wieder die Spalte – kein eigenes Sheet, das
    /// leer hängen bleiben könnte.
    @ViewBuilder private var profileColumn: some View {
        if let id = profileColumnChatID {
            InspectorContent(chatID: id, headerAnchor: headerAnchor)
                // Anderer Chat: Profil neu aufbauen wie früher mit dem Chat (`.id` dort)
                .id(id)
                .frame(width: max(280, store.currentTheme.inspectorWidth))
                .transition(.move(edge: .trailing))
        }
    }
    #endif

    #if os(iOS)
    /// Profil in kompakter Breite (iPhone, Duo zugeklappt) als eigenes Sheet an der Wurzel statt über `.inspector`.
    ///
    /// Der Inspector fällt kompakt selbst auf ein Sheet zurück, präsentiert es aber aus dem Chat im Stapel heraus.
    /// Beim Wechsel auf die breite Darstellung (Aufklappen, Hintergrund-Schnappschuss) verschwindet diese Ansicht,
    /// das Sheet wurde dabei nicht geschlossen und blieb als leeres, verschwommenes Blatt über dem Chat stehen.
    /// An der Wurzel bleibt der Präsentierende erhalten: Wird die Darstellung breit, schließt SwiftUI das Sheet
    /// regulär, und das Profil steht als rechte Spalte da (der Zustand im Store bleibt `true`).
    private var compactInspectorSheet: Binding<IdentifiedString?> {
        Binding(get: {
            guard store.showInspector, effectiveSizeClass == .compact, store.phase != .unconfigured,
                  let id = store.selectedChatID, store.chatExists(id) else { return nil }
            return IdentifiedString(id: id)
        }, set: { item in
            // Nur echtes Schließen (Wischen, X) übernehmen, nicht das Schließen durch einen Layoutwechsel
            if item == nil, effectiveSizeClass == .compact, !sizeClassFrozen { store.showInspector = false }
        })
    }

    /// iPhone: Stapel-Navigation (Seitenleiste → Chat), Profil als Sheet.
    private var compactStack: some View {
        @Bindable var store = store
        return NavigationStack {
            SidebarView(standalone: true)
                .navigationDestination(item: compactChat(overToday: false)) { id in
                    if store.chatExists(id) { chat(id) }
                }
                // Seite „Heute“ liegt über der Chatliste; ein von dort geöffneter Chat liegt darüber, „Zurück“
                // führt wieder zu „Heute“.
                .navigationDestination(isPresented: $store.showToday) {
                    TodayView(inStack: true)
                        .navigationDestination(item: compactChat(overToday: true)) { id in
                            if store.chatExists(id) { chat(id) }
                        }
                }
        }
    }

    /// Gewählter Chat für den Stapel: Solange „Heute“ offen ist, öffnet er sich über dieser Seite, sonst über der
    /// Chatliste (immer nur eines der beiden Ziele ist aktiv).
    private func compactChat(overToday: Bool) -> Binding<String?> {
        Binding(get: { store.showToday == overToday ? store.selectedChatID : nil },
                set: { id in
                    if id != nil || store.showToday == overToday { store.selectedChatID = id }
                })
    }
    #endif

    private var placeholder: some View {
        let theme = store.currentTheme
        return ZStack {
            theme.background.ignoresSafeArea()
            if store.phase == .connecting {
                ProgressView()
            } else if case .offline(let message) = store.phase, store.bots.isEmpty, store.groups.isEmpty {
                ConnectionProblemView(message: message)
            } else if store.today.available {
                // Startansicht, solange kein Chat gewählt ist: Seite „Heute“ (ältere Server: Hinweis wie bisher)
                TodayView()
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: -8) {
                        ForEach(Array(store.bots.prefix(3).enumerated()), id: \.offset) { _, b in
                            MascotView(mascot: b.mascot, size: 64, seed: b.id)
                        }
                    }
                    Text(store.bots.isEmpty ? "Leg deinen ersten Scoop an" : "Wähle einen Scoop")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Links findest du deine Scoops. Mit ⌘N legst du einen neuen an.")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        #if os(iOS)
        // Ohne geöffneten Chat: iPad bei eingeklappter Seitenleiste oben rechts (sonst unten in der Seitenleiste),
        // Duo aufgeklappt in der senkrechten Leiste (siehe `PlaceholderSystemBar`).
        .modifier(PlaceholderSystemBar())
        #endif
    }
}

/// Inhalt der rechten Spalte bzw. des Profil-Blatts.
///
/// Nur aufbauen, wenn sichtbar (sonst kostet jeder Chatwechsel ein unsichtbares Profil). Beim Schließen bleibt
/// der Inhalt stehen, bis die Spalte hinausgeglitten ist, und wird erst danach abgebaut: Der Abbau der vielen
/// Steuerelemente kostete sonst rund 50 ms im ersten Bild der Animation, und die Spalte glitt leer hinaus.
/// Während des Hinausgleitens behält der Inhalt seine Breite (`StableWidthLayout`), statt in jedem Bild auf die
/// schmaler werdende Spalte neu gelayoutet zu werden.
struct InspectorContent: View {
    let chatID: String
    /// Nur in der rechten Spalte (iOS): Kopfzeile des Chats, an der sich der Schließen-Knopf ausrichtet. Im Blatt
    /// und auf dem Mac `nil`.
    var headerAnchor: ChatHeaderAnchor? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var keepAlive = false
    @State private var teardown: Task<Void, Never>?
    @State private var closingWidth: CGFloat?
    @State private var tracker = WidthTracker()
    /// Oberkante der Spalte auf dem Bildschirm (ohne sicheren Bereich), globale Koordinaten
    @State private var columnTop: CGFloat?

    @State private var remeasure: Task<Void, Never>?

    /// Pille nach dem Ende einer Animation frisch vermessen lassen (siehe `ChatHeaderAnchor`)
    private func remeasureHeader() {
        guard let headerAnchor else { return }
        remeasure?.cancel()
        remeasure = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            headerAnchor.measure()
        }
    }

    /// Abstand der Profil-Kopfleiste zur Oberkante der Spalte, damit der Schließen-Knopf auf der Höhe der Chat-Pille
    /// sitzt (iPad, iPhone Duo aufgeklappt, siehe `ChatHeaderAnchor`). Sonst `nil`: Blatt und Mac
    /// (Fenster-Symbolleiste) behalten den sicheren Bereich und ihren üblichen Abstand.
    private var barTop: CGFloat? {
        guard let midY = headerAnchor?.midY, let columnTop else { return nil }
        return max(0, midY - columnTop - ProfileScaffold<EmptyView>.barHeight / 2)
    }

    var body: some View {
        StableWidthLayout(frozenWidth: closingWidth, alignment: .leading) {
            Group {
                if store.showInspector || keepAlive {
                    if ChatGroup.isGroupID(chatID) { GroupProfileView(groupID: chatID) } else { ProfileView(botID: chatID) }
                }
            }
        }
        // Nur seitlich (Hinausgleiten): Die Kopfleiste darf bei `barTop` über den sicheren Bereich hinaus nach oben
        .clipShape(HorizontalClip())
        .environment(\.profileBarTop, barTop)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY - $0.safeAreaInsets.top } action: {
            columnTop = $0
        }
        // Pille neu vermessen, sobald die Spalte erscheint oder sich ihre Lage ändert (Auf-/Zuklappen, Drehen), und
        // zwar nach dem Ende der Animation: Erst dann steht die Navigationsleiste des Chats (siehe `ChatHeaderAnchor`)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global).integral } action: { _ in remeasureHeader() }
        .onAppear { remeasureHeader() }
        // Hintergrund durchgehend bis ganz oben: Die Profile setzen ihn nur innerhalb des sicheren Bereichs, darüber
        // (Toolbar-Höhe, Mac rund 52 pt) schien die Standardfläche der Spalte als hellerer Streifen durch.
        .background { theme.groupedBackground.ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tracker.widthChanged($0) }
        .onAppear { keepAlive = store.showInspector }
        .onChange(of: store.showInspector) { _, show in
            teardown?.cancel()
            if show {
                closingWidth = nil
                keepAlive = true
            } else {
                if tracker.width > 0 { closingWidth = tracker.width }
                teardown = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, !store.showInspector else { return }
                    keepAlive = false
                    closingWidth = nil
                }
            }
        }
    }
}

/// Mitte des Fensters, wenn keine Verbindung zustande kam: Grund und die zwei Auswege.
struct ConnectionProblemView: View {
    let message: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .appFont(40, weight: .medium)
                .foregroundStyle(theme.warning)
            Text("Keine Verbindung")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            AdaptiveButtonRow(spacing: 10) {
                Button("Neu versuchen") { Task { await store.retry() } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button(store.settings.usesAccount ? "Anderen Server wählen" : "Einstellungen") {
                    if store.settings.usesAccount { store.showServerSwitcher = true } else { store.showSettings = true }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .padding(.top, 4)
        }
        .padding(24)
    }
}


/// Merkt sich Hell/Dunkel des Geräts für das Erscheinungsbild „System“. Bei „System“ setzt die App kein festes
/// Schema (`Theme.preferredScheme` ist `nil`), dann liefert die Umgebung den echten Gerätewert.
private struct DeviceSchemeTracker: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var deviceScheme

    func body(content: Content) -> some View {
        content.onChange(of: deviceScheme, initial: true) { _, scheme in store.systemDark = scheme == .dark }
    }
}
