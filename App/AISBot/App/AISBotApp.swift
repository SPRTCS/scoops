import SwiftUI
import UserNotifications

@main
struct AISBotApp: App {
    @State private var store = AppStore()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // Store vor dem ersten Fenster anlegen: Startet iOS die App nur im Hintergrund (stille Push für Home, Wecker,
        // Standort oder ein Ort wurde betreten), gibt es kein Fenster, der Gerätekanal braucht aber die Verbindungsdaten.
        let store = AppStore()
        _store = State(initialValue: store)
        AppleDeviceAgent.shared.store = store
        AppleDeviceAgent.shared.launch()
        NotificationManager.shared.setUp()
        // Für Freigabe-Knöpfe an Mitteilungen, auch wenn iOS die App nur im Hintergrund startet
        NotificationManager.shared.store = store
        #if os(iOS)
        // Apple Watch: Zugangsdaten übergeben und Anfragen der Uhr beantworten (auch beim Hintergrundstart)
        WatchBridge.shared.start(store: store)
        #endif
        #if os(macOS)
        if let i = CommandLine.arguments.firstIndex(of: "-render-assets"), i + 1 < CommandLine.arguments.count {
            AssetRenderer.renderAll(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("AIS Scoops") {
            RootView()
                .environment(store)
                .task { await launch() }
                .onOpenURL { handle($0) }
                // Links (Kopplung, Widgets) im vorhandenen Fenster öffnen statt ein neues anzulegen.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #if os(macOS)
                .frame(minWidth: MacWindowLayout.minWidth, minHeight: 520)
                #endif
                .storeShotStatusBar()
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands { AppCommands(store: store) }
        .handlesExternalEvents(matching: ["*"])

        #if os(macOS)
        Window("Nutzung und Verbrauch", id: UsageView.windowID) {
            UsageView()
                .environment(store)
                .environment(\.theme, store.currentTheme)
                .preferredColorScheme(store.currentTheme.preferredScheme)
        }
        .defaultSize(width: 1120, height: 820)

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.theme, store.currentTheme)
                .preferredColorScheme(store.currentTheme.preferredScheme)
        }
        #endif
    }

    private func launch() async {
        NotificationManager.shared.onOpenBot = { id in
            store.selectedChatID = id
            store.showInspector = false
        }
        NotificationManager.shared.store = store
        if let pending = NotificationManager.shared.pendingBotID {
            NotificationManager.shared.pendingBotID = nil
            NotificationManager.shared.onOpenBot?(pending)
        }
        PushManager.shared.store = store
        VoiceCatalog.preload()
        await AppIconSwitcher.migrateLegacyIcon()
        #if os(macOS)
        AppIconSwitcher.applyDockIcon()
        #endif
        #if os(iOS)
        LiveActivityManager.shared.store = store
        #endif
        // Erlaubnis + APNs-Registrierung passieren nach erfolgreicher Verbindung (AppStore.connect).
        await store.start()
        applyLaunchArguments()
    }

    /// Steuerung für Screenshots/Tests: `-select <chatID>`, `-inspector`, `-memory`, `-library`, `-create`,
    /// `-creategroup`, `-voicedemo`, `-settings`, `-theme hell`.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-select"), i + 1 < args.count { store.selectedChatID = args[i + 1] }
        if args.contains("-inspector") { store.showInspector = true }
        if args.contains("-create") { store.editingBot = nil; store.showCreateBot = true }
        if args.contains("-editlook"), let bot = store.bot(store.selectedChatID) { store.editingBot = bot; store.showCreateBot = true }
        if args.contains("-settings") { store.showSettings = true }
        if args.contains("-creategroup") { store.showCreateGroup = true }
        if args.contains("-voicedemo") || args.contains("-livedemo"), let id = store.selectedChatID { store.voiceChatID = id }
        #if os(macOS) && DEBUG
        if let i = args.firstIndex(of: "-sidebarshrinktest") {
            SidebarShrinkTest.run(store: store, collapse: args.indices.contains(i + 1) && args[i + 1] == "collapse")
        }
        #endif
        #if os(iOS) && DEBUG
        // Gemeinsame Live-Aktivität mit drei Beispiel-Scoops (Designprüfung im Simulator).
        if args.contains("-livedemo") { LiveActivityManager.shared.startDemo() }
        #endif
        #if DEBUG
        // Mitteilungs-Test im Demo-Modus (`xcrun simctl push`): Erlaubnis und APNs-Registrierung, damit das System
        // die Notification-Service-Extension startet. Das Token geht im Demo-Modus an keinen Server.
        if args.contains("-askpush") {
            Task {
                guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true
                else { return }
                #if os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #else
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            }
        }
        // `-localpush einzelchat,gruppe,…`: Payloads aus scripts/push-tests als lokale Communication Notifications
        // (gleicher Code wie die Extension). Kurz warten, bis die Maskottchen-Bilder geschrieben sind;
        // `-localpushdelay <s>` wartet länger (z. B. um vorher das Aussehen zu bearbeiten).
        if let i = args.firstIndex(of: "-localpush"), i + 1 < args.count {
            let names = args[i + 1].split(separator: ",").map(String.init)
            let delay = args.firstIndex(of: "-localpushdelay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 2
            Task {
                try? await Task.sleep(for: .seconds(delay))
                NotificationTestPush.schedule(names)
            }
        }
        // Leistungsmessung: wechselt automatisch durch alle Chats (während in Theo ein Demo-Lauf läuft)
        if args.contains("-perfbench") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await store.send("Kannst du im Browser suchen?", to: "b_theo")
                let ids = ["b_mila", "g_team", "b_lio", "b_theo", "b_nora", "b_pip"]
                for _ in 0..<3 {
                    for id in ids {
                        store.selectedChatID = id
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                }
                print("[perf] fertig")
            }
        }
        // Leistungsmessung: Profil (rechte Seitenleiste) mehrmals ein- und ausfahren (`-inspectorbench [n]`)
        if let i = args.firstIndex(of: "-inspectorbench") {
            let n = args.indices.contains(i + 1) ? Int(args[i + 1]) ?? 10 : 10
            InspectorBench.shared.run(store: store, count: n)
        }
        #endif
        if let i = args.firstIndex(of: "-skill"), i + 1 < args.count {
            let id = args[i + 1]
            Task {
                if let bot = store.selectedChatID { await store.loadSkills(botID: bot) }
                store.presentedSkillID = id
            }
        }
        if args.contains("-initiative") { store.showInitiative = true }
        if args.contains("-vault") { store.showVault = true }
        if args.contains("-connections") { store.showConnections = true }
        if args.contains("-palette") { store.showCommandPalette = true }
        // Screenshots: Annahme-Blatt einer Demo-Einladung (`-acceptdemo`)
        if args.contains("-acceptdemo") { store.presentedInviteCode = "DEMO-KIKO" }
        if args.contains("-hatchdemo"), store.isMock {
            store.addDemoPending(name: "Kiki", mascot: Mascot(shape: "heart", color: "#FF5FA8", eyes: "sparkle", accessory: "none"))
        }
        #if DEBUG
        // Test: WebSocket-Ereignis bot.updated mit neuem Namen und neuem Aussehen (wie nach Umbenennen auf dem Server)
        if args.contains("-renametest"), store.isMock {
            Task {
                try? await Task.sleep(for: .seconds(2))
                for id in ["b_theo", "b_mila"] {
                    guard var b = store.bot(id) else { continue }
                    b.name = id == "b_theo" ? "Theodor" : "Milana"
                    b.mascot.color = id == "b_theo" ? "#22BFAE" : "#FF7A30"
                    store.apply(.botUpdated(b))
                }
            }
        }
        #endif
        // Demo: Ausfall des Bot-Bildschirms simulieren (`-screenfaildemo [Sekunden]`, Standard 20 s),
        // um „Neu versuchen“ und das automatische Wiederverbinden zu prüfen.
        if let i = args.firstIndex(of: "-screenfaildemo"), store.isMock {
            let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 20 : 20
            store.mockScreenOutage = Date().addingTimeInterval(seconds)
            store.showScreenViewer = true
        }
        // Nur Screenshots: Bildschirm-Ansicht ohne Übernehmen öffnen (mit `-select`: Rechner dieses Scoops)
        if args.contains("-screenviewer"), store.isMock { store.showScreenViewer = true }
        if args.contains("-takeoverdemo"), store.isMock {
            Task {
                _ = await store.takeOverComputer()
                store.showScreenViewer = true
            }
        }
    }

    /// `aisbot://pair?url=…&token=…` koppelt, `aisbot://bot/<id>` öffnet einen Chat,
    /// `aisscoops://invite/<code>` (bzw. `https://…/i/<code>`) zeigt eine Einladung zu einem geteilten Scoop.
    private func handle(_ url: URL) {
        // Kopplungscode aus dem Assistenten von AIS Scoops Server (aisscoops://link?code=…, docs/onboarding.md)
        if store.openPairingLink(url) { return }
        if InviteLink.code(from: url) != nil {
            store.handleInviteURL(url)
            return
        }
        // Rücksprung einer Browser-Anmeldung (Notion direkt), falls er nicht im Anmeldefenster ankam
        if url.scheme?.lowercased() == "aisscoops", url.host()?.lowercased() == "oauth" {
            Task {
                _ = await store.finishOAuth(url)
                await store.loadConnections(fresh: true)
            }
            return
        }
        guard url.scheme?.lowercased() == "aisbot" else { return }
        switch url.host()?.lowercased() {
        case "pair":
            store.handlePairingURL(url)
        case "usage":
            // Widget „Abo-Limits“: Seite „Nutzung und Verbrauch“ öffnen (aisbot://usage/limits)
            UsageRouter.shared.open(tab: url.pathComponents.dropFirst().first.flatMap(UsageTab.init(rawValue:)))
            #if os(iOS)
            store.showSettings = true
            #endif
        case "bot", "group", "chat":
            if let id = url.pathComponents.dropFirst().first, !id.isEmpty {
                store.selectedChatID = id
                store.showInspector = false
            }
        default:
            break
        }
    }
}

/// Menübefehle und Tastenkürzel (⌘N neuer Scoop, ⌘F suchen, ⌘I Profil, ⌘K Befehlspalette, ⌃⌘S Seitenleiste).
struct AppCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neuer Scoop") {
                store.editingBot = nil
                store.showCreateBot = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(store.phase == .unconfigured)
        }
        CommandGroup(after: .newItem) {
            Button("Neue Gruppe") { store.showCreateGroup = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.phase == .unconfigured || store.bots.count < 2)
        }
        CommandGroup(after: .textEditing) {
            Button("Scoops suchen") { store.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Befehlspalette …") { store.showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(store.phase == .unconfigured)
            #if os(macOS)
            // Nur Mac: iPadOS belegt ⌃⌘S selbst („Seitenleiste“); ein zweiter Befehl mit demselben Kürzel lässt
            // UIKit beim Aufbau des Menüs abstürzen. Dort schaltet das System-Kürzel dieselbe Spalte.
            Button(store.sidebarHidden ? "Seitenleiste einblenden" : "Seitenleiste ausblenden") { store.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(store.phase == .unconfigured)
            #endif
            Button(store.showInspector ? "Profil ausblenden" : "Profil einblenden") { store.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.selectedChatID == nil)
        }
    }
}

/// Store-Aufnahmen: `-hidestatusbar` blendet die Statusleiste aus (iPhone Duo: Uhrzeit und Akkuring in der senkrechten
/// Systemleiste am Rand). Blätter sind eigene Präsentationen und brauchen den Modifier selbst.
enum StoreShots {
    static let hideStatusBar = ProcessInfo.processInfo.arguments.contains("-hidestatusbar")
}

extension View {
    @ViewBuilder func storeShotStatusBar() -> some View {
        #if os(iOS)
        statusBarHidden(StoreShots.hideStatusBar)
        #else
        self
        #endif
    }
}
