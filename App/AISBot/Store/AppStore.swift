import Foundation
import Observation
import SwiftUI

enum ConnectionPhase: Equatable {
    case unconfigured
    case connecting
    case online
    case offline(String)
}

/// Zentrale App-Daten (MainActor). Lädt über `BotService` und wendet WebSocket-Ereignisse an.
@Observable
final class AppStore {
    // Verbindung
    private(set) var settings: ConnectionSettings
    /// Benutzerkonto (Mit Apple anmelden, „Deine Server“); optional neben dem API-Token
    let account: AccountStore
    /// Einführung für neue Nutzer (docs/onboarding.md)
    let onboarding: OnboardingState
    private(set) var phase: ConnectionPhase = .unconfigured
    private(set) var socketState: SocketState = .disconnected
    private(set) var serverVersion: String?
    var userName: String = "Arman"

    // Daten
    /// Eigene Scoops (eigener Server)
    private(set) var bots: [Bot] = []
    /// Mit mir geteilte Scoops (Server der Admins, docs/sharing.md). Platzhalter aus `shares:mine`, sobald der Server
    /// des Admins antwortet, dessen Scoop-Daten.
    var sharedBots: [Bot] = []
    /// Zustand der Verbindung je Admin-Server (Convex-Server-ID)
    var guestStates: [String: GuestConnectionState] = [:]
    /// Je Admin-Server eine Verbindung (APIClient + Live-Kanal mit dem eigenen Sitzungs-JWT)
    @ObservationIgnored var guestConnections: [String: GuestConnection] = [:]
    @ObservationIgnored var guestRefreshTask: Task<Void, Never>?
    /// Personen und offene Einladungen eigener Scoops (Admin, Abschnitt „Teilen“)
    var shareLists: [String: BotShareList] = [:]
    /// Werkzeuge für Geteilte, Tageslimit und Auswahl je eigenem Scoop (Admin)
    var sharingSettings: [String: SharingSettings] = [:]
    /// Blatt „Einladung annehmen“ (Link geöffnet)
    var presentedInviteCode: String?
    /// Nur geteilte Scoops, kein eigener Server: Einrichtung des eigenen Servers zeigen (Onboarding)
    var showOwnServerSetup = false
    private(set) var groups: [ChatGroup] = []
    /// Nachrichten pro Chat (Bot- oder Gruppen-ID)
    var messages: [String: [Message]] = [:]
    /// Bibliothek pro Chat
    var files: [String: [LibraryFile]] = [:]
    private(set) var hasMoreHistory: [String: Bool] = [:]
    private(set) var loadingHistory: Set<String> = []
    var memories: [String: [Memory]] = [:]
    var routines: [String: [Routine]] = [:]
    /// v1.20: dauerhafte Freigaben („Immer erlauben“) je Scoop, nur für eigene Scoops geladen
    var standingApprovals: [String: [StandingApproval]] = [:]
    /// Zustand des Rechners, der gerade angezeigt wird (`computerNodeID`)
    var computer: ComputerState = .unknown
    /// Alle Rechner (v1.11, Scoops Connect), Bot-Rechner zuerst
    private(set) var nodes: [ComputerNode] = []
    /// Rechner, den Bildschirm-Vorschau und Übernehmen zeigen. Folgt dem Rechner des ausgewählten Scoops,
    /// lässt sich über den Umschalter vorübergehend ändern.
    var computerNodeID: String = ComputerNode.builtinID {
        didSet {
            guard oldValue != computerNodeID else { return }
            computer = node(computerNodeID)?.computerState ?? .unknown
            Task { await refreshComputer() }
        }
    }
    /// Wer tippt gerade: Chat-ID → Bot-IDs (bei Einzelchats ist das die Bot-ID selbst)
    var typing: [String: Set<String>] = [:]
    private(set) var usage: Usage?
    /// Kosten pro Scoop (bei geteilten Scoops pro Person)
    var botUsage: [String: BotUsage] = [:]
    /// Scoops, deren Server die Kosten pro Scoop noch nicht kennt
    var botUsageUnavailable: Set<String> = []

    // Oberfläche
    /// Ausgewählter Chat (Bot- oder Gruppen-ID)
    var selectedChatID: String? {
        didSet {
            if oldValue != selectedChatID {
                PerfLog.chatSwitchStarted(selectedChatID)
                // Wechsel zwischen Servern (eigener ↔ geteilter Scoop): Rechner-IDs gelten je Server
                if guestServerID(for: oldValue) != guestServerID(for: selectedChatID) {
                    computer = .unknown
                    Task { await refreshComputer() }
                }
                syncComputerNode()
            }
        }
    }
    var showInspector = false
    /// Entwürfe der Eingabe (Text und Anhänge) pro Chat. Liegen hier statt als `@State` im Chat, damit sie
    /// App-Wechsel, Size-Class-Wechsel (Auf-/Zuklappen, Hintergrund-Schnappschüsse) und Chatwechsel überstehen:
    /// Dabei wird der Chat neu aufgebaut und verlor vorher Text und Anhänge. Zusätzlich auf der Platte gesichert
    /// (`DraftArchive`), damit sie auch ein Beenden der App durch iOS überstehen. Nicht beobachtet: Das Wörterbuch
    /// ändert sich nur beim ersten Öffnen eines Chats, beobachtet wird der jeweilige Entwurf selbst.
    @ObservationIgnored private var composerDrafts: [String: ComposerDraft] = [:]
    /// Server, zu dem die Entwürfe gehören; `nil`, solange sie noch nicht von der Platte geladen sind
    @ObservationIgnored private var draftsServer: String?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    var showCreateBot = false
    var editingBot: Bot?
    var showCreateGroup = false
    /// Sprachmodus für diesen Chat geöffnet
    var voiceChatID: String?
    /// Datei, die gerade in Quick Look angezeigt wird
    var previewURL: URL?
    /// Vollbild des Bot-Rechners (zentral, z. B. für Startargument `-takeoverdemo`)
    var showScreenViewer = false
    /// Bildschirmtastatur sichtbar (iOS) – für „Tastatur schließen“ in der Systemleiste
    var keyboardVisible = false
    /// Dialog „Neuer Bereich“ / „Bereich umbenennen“ (Seitenleiste). `moveChatID`: danach diesen Chat hineinlegen.
    enum SectionPrompt: Equatable {
        case create(moveChatID: String?)
        case rename(String)
    }
    var sectionPrompt: SectionPrompt?

    /// Geöffnete Fähigkeit (Detail-Sheet), Initiative- und Tresor-Sheets (v1.4)
    var presentedSkillID: String?
    var showInitiative = false
    var showVault = false
    var showConnections = false
    /// v1.22: Aufgaben-Board (Mac/iPad: statt des Chats in der Mitte, iPhone: Blatt)
    var showTaskBoard = false
    /// Aufgaben-Board über alle Scoops (nur eigener Server)
    let taskBoard = TaskBoardStore()

    /// Chat öffnen (Seitenleiste, Befehlspalette): schließt auch das Aufgaben-Board – auch wenn genau dieser Chat
    /// schon gewählt war (dann ändert sich `selectedChatID` nicht und `onChange` greift nicht).
    func openChat(_ id: String) {
        showTaskBoard = false
        selectedChatID = id
    }

    // v1.4
    /// Fähigkeiten pro Scoop (eigene + geteilte)
    private(set) var skills: [String: [Skill]] = [:]
    private(set) var initiative: InitiativeSettings?
    private(set) var vault: [VaultEntry] = []
    var showSettings = false
    /// Blatt „Deine Server“ (z. B. aus der Fehlermeldung „Anderen Server wählen“)
    var showServerSwitcher = false
    var searchText = ""
    var searchFocusRequest = 0

    // Build 12: Befehlspalette (⌘K)
    var showCommandPalette = false
    /// Spalten des Split-Views (Mac/iPad), damit die Palette die Seitenleiste ein- und ausblenden kann
    var sidebarColumns: NavigationSplitViewVisibility = .all
    var sidebarHidden: Bool { sidebarColumns == .detailOnly }
    /// Seitenleiste bewusst ausgeblendet (⌃⌘S, Befehlspalette, Knopf, am Trenner zugezogen). Nur dann bleibt sie zu.
    /// Hat AppKit sie selbst eingeklappt (Fenster zu schmal, z. B. beim Bildschirmwechsel), blendet `SidebarSync`
    /// sie wieder ein, sobald das Fenster breit genug ist.
    @ObservationIgnored var sidebarHiddenByUser = false
    /// Eingabefeld wieder fokussieren (z. B. nach dem Schließen der Palette auf dem Mac)
    var composerFocusRequest = 0
    /// Nach dem Öffnen eines Chats zu dieser Nachricht scrollen (Treffer aus der Palette)
    var pendingScrollMessageID: String?
    /// Kurzer Hinweis unten im Fenster (z. B. „Mila schaut nach …“)
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func toggleSidebar() {
        setSidebarHidden(!sidebarHidden)
    }

    func setSidebarHidden(_ hidden: Bool) {
        sidebarHiddenByUser = hidden
        withAnimation(.snappy) { sidebarColumns = hidden ? .detailOnly : .all }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toast = nil }
        }
    }
    var errorMessage: String?
    /// Erscheinungsbild: System (folgt dem Gerät), Nacht oder Hell
    var appearance: AppearanceMode = .system {
        didSet { if persistsTheme { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") } }
    }
    /// Dunkelmodus des Geräts (setzt RootView aus der Umgebung); zählt nur bei „System“
    var systemDark = true
    /// Wirksamer Entwurf. Setzen wählt ihn fest (z. B. Befehlspalette „Zu Hell wechseln“).
    var theme: ThemeKind {
        get {
            switch appearance {
            case .system: systemDark ? .nacht : .hell
            case .nacht: .nacht
            case .hell: .hell
            }
        }
        set { appearance = newValue == .nacht ? .nacht : .hell }
    }
    /// Wirksame Farben samt `followsSystem` (für `.environment(\.theme, …)` und `.preferredColorScheme`)
    var currentTheme: Theme {
        var t = theme.theme
        t.followsSystem = appearance == .system
        return t
    }
    /// Startargumente (`-theme`) sollen die gespeicherte Wahl nicht überschreiben.
    @ObservationIgnored private var persistsTheme = false

    /// ID des Chats, der gerade sichtbar ist (für Gelesen-Markierung und Mitteilungen).
    var visibleChatID: String?
    var isAppActive = true {
        didSet {
            // Zurück in der App: hängt der Live-Kanal im Rückfall, sofort neu verbinden
            if isAppActive, !oldValue, case .reconnecting = socketState { reconnectEventsNow() }
            // Zurück in der App: Hing der Aufbau (z. B. von iOS mitten im Laden pausiert) oder ist der Server
            // offline, gleich neu versuchen statt den alten Zustand stehen zu lassen.
            if isAppActive, !oldValue { resumeConnectionIfNeeded() }
            // Geteilte Scoops: Verzeichnis und Admin-Server abgleichen
            if isAppActive, !oldValue, account.isSignedIn { Task { await refreshSharedWithMe() } }
            #if os(iOS)
            if isAppActive, !oldValue { LiveActivityManager.shared.appBecameActive() }
            #endif
            // Vor dem Hintergrund sofort sichern: iOS darf die App dort jederzeit beenden
            if !isAppActive, oldValue { saveComposerDraftsNow() }
            // Apple-Gerät (v1.18): Server weiß dann, ob Befehle über den Socket gehen oder eine stille Push brauchen
            if isAppActive != oldValue { AppleDeviceAgent.shared.appActiveChanged(isAppActive) }
        }
    }

    /// Verbindung zum eigenen Server (nil = keiner verbunden)
    private(set) var service: BotService?
    private var hadConnection = false
    private var readTasks: [String: Task<Void, Never>] = [:]

    static let pageSize = 50

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        var s = ConnectionSettings.load()
        let mock = arguments.contains("-mock")
        let storedConnection = !mock && s.isConfigured
        if mock {
            s = ConnectionSettings(serverURL: ConnectionSettings.mockURL, token: "")
            // Einführung im Demo-Modus: bis einschließlich Server-Schritt ohne Verbindung starten
            if let step = OnboardingState.demoLaunchStep(arguments), step <= .server {
                s = ConnectionSettings(serverURL: "", token: "")
            }
            // Screenshots der Anmeldung bzw. der Server-Liste: ohne Verbindung starten
            if let i = arguments.firstIndex(of: "-accountscreen"), i + 1 < arguments.count,
               ["signin", "servers"].contains(arguments[i + 1]) {
                s = ConnectionSettings(serverURL: "", token: "")
            }
        }
        #if DEBUG
        // Nur Debug-Builds: `-testserver <url> <token>` verbindet mit einer Testinstanz, ohne etwas zu speichern
        // (gespeicherte Verbindung und Schlüsselbund bleiben unberührt; Tests mit `-nocache` kombinieren).
        if let i = arguments.firstIndex(of: "-testserver"), i + 2 < arguments.count {
            s = ConnectionSettings(serverURL: arguments[i + 1], token: arguments[i + 2])
            isTestServer = true
        }
        // `-testaccountserver <url> <serverID>`: Konto-Verbindung (Sitzungs-JWT aus `-testaccount`) zu einer
        // Testinstanz, ebenfalls ohne zu speichern
        if let i = arguments.firstIndex(of: "-testaccountserver"), i + 2 < arguments.count {
            s = ConnectionSettings(serverURL: arguments[i + 1], token: "", cloudServerID: arguments[i + 2],
                                   cloudServerName: "Testserver")
            isTestServer = true
        }
        skipPush = arguments.contains("-nopush")
        #endif
        settings = s
        account = AccountStore(mock: mock, arguments: arguments)
        onboarding = OnboardingState(arguments: arguments, hasStoredConnection: storedConnection,
                                     isSignedIn: account.isSignedIn)
        if mock, let step = MockService.onboardingStep, step >= .message, onboarding.firstBotID == nil {
            onboarding.firstBotID = MockService.onboardingFirstBotID
        }
        // Gespeicherte Wahl; ältere Versionen kannten nur „theme“ (nacht/hell) – das bleibt fest. Neu: „System“.
        if let raw = UserDefaults.standard.string(forKey: "appearance"), let a = AppearanceMode(rawValue: raw) {
            appearance = a
        } else if let old = UserDefaults.standard.string(forKey: "theme").flatMap({ ThemeKind(stored: $0) }) {
            appearance = old == .nacht ? .nacht : .hell
        } else {
            appearance = .system
        }
        if let i = arguments.firstIndex(of: "-theme"), i + 1 < arguments.count {
            if arguments[i + 1] == "system" {
                appearance = .system
            } else if let t = ThemeKind(stored: arguments[i + 1]) {
                theme = t
            }
        }
        persistsTheme = true
        observeWidgetSnapshot()
        observeBadge()
        taskBoard.service = { [weak self] in self?.service as? TaskBoardService }
        taskBoard.onError = { [weak self] error in self?.report(error) }
        account.onSignedOut = { [weak self] in
            // Abgemeldet: geteilte Scoops und eine Verbindung über das Konto gelten nicht mehr
            // (Token-Verbindungen bleiben)
            guard let self else { return }
            self.tearDownGuests()
            guard self.settings.usesAccount else { return }
            self.disconnect()
        }
    }

    // MARK: - Widgets (entkoppelt von der Oberfläche, gebündelt alle 250 ms)

    @ObservationIgnored private var widgetTask: Task<Void, Never>?
    /// Debug-Start mit `-testserver`: keine Widget-Daten schreiben
    @ObservationIgnored private(set) var isTestServer = false
    /// Debug-Start mit `-nopush`: keine Mitteilungs-Registrierung beim Server (Tests gegen echte Server)
    @ObservationIgnored private(set) var skipPush = false
    @ObservationIgnored private var lastBadge: Int?

    /// Anzahl Chats (Scoops + Gruppen) mit ungelesenen Nachrichten – rote Zahl am App-Symbol.
    var unreadChatCount: Int {
        bots.filter { $0.unread > 0 }.count + groups.filter { $0.unread > 0 }.count
            + sharedBots.filter { $0.unread > 0 }.count
    }

    private func observeBadge() {
        withObservationTracking {
            _ = unreadChatCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyBadge()
                self?.observeBadge()
            }
        }
    }

    private func applyBadge() {
        let count = (isConfigured || !sharedBots.isEmpty) ? unreadChatCount : 0
        guard count != lastBadge else { return }
        lastBadge = count
        AppBadge.set(count)
    }

    private func observeWidgetSnapshot() {
        withObservationTracking {
            _ = widgetSnapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.widgetSnapshotChanged() }
        }
    }

    private func widgetSnapshotChanged() {
        guard !isTestServer else { return }  // Testinstanz: echte Widgets nicht überschreiben
        widgetTask?.cancel()
        widgetTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            WidgetSync.shared.update(widgetSnapshot)
            observeWidgetSnapshot()
        }
    }

    var isMock: Bool { settings.isMock }
    var isConfigured: Bool { settings.isConfigured }

    // MARK: - Verbindung

    func start() async {
        await account.checkAppleCredentialState()
        if account.isSignedIn { Task { await account.loadServers() } }
        // Mit mir geteilte Scoops (Server der Admins) unabhängig vom eigenen Server
        if account.isSignedIn { Task { await refreshSharedWithMe() } }
        // Konto-Verbindung ohne Anmeldung (abgemeldet, widerrufen): zur Anmeldung
        guard settings.isConfigured, !settings.usesAccount || account.isSignedIn || settings.isMock else {
            phase = .unconfigured
            return
        }
        await connect(with: settings, persist: false)
    }

    /// Höchstdauer für den Verbindungsaufbau (Erreichbarkeit + Anmeldung), danach klare Meldung statt „Verbinde …“
    nonisolated static let handshakeTimeout: Double = 12
    /// Höchstdauer für das erste Laden der Chats nach erfolgreicher Anmeldung
    nonisolated static let initialLoadTimeout: Double = 25
    /// Beginn des laufenden Verbindungsaufbaus (Wächter beim Zurückkehren in die App)
    @ObservationIgnored private var connectStartedAt: Date?

    /// Zugang für den Server: Sitzungs-JWT bei Konto-Servern, sonst API-Token.
    private func serverAuth(for candidate: ConnectionSettings) -> ServerAuth {
        candidate.usesAccount ? .account(account) : .token(candidate.token)
    }

    /// Verbindet mit einem Server aus „Deine Server“ (Server-URL + Sitzungs-JWT).
    func connect(to server: CloudServer) async {
        // Demo: alle Beispiel-Server zeigen die Demo-Daten
        guard let url = account.isMock ? ConnectionSettings.mockURL : server.connectURL else {
            errorMessage = "Für „\(server.name)“ ist noch keine Adresse bekannt. Ist der Server gestartet?"
            return
        }
        await connect(with: ConnectionSettings(serverURL: url, token: ConnectionSettings.storedToken,
                                               cloudServerID: server.id, cloudServerName: server.name),
                      persist: !account.isMock && !isTestServer)
    }

    /// Dienst für den Gerätekanal (v1.18): die laufende Verbindung oder – wenn iOS die App nur im Hintergrund
    /// gestartet hat (stille Push, Ort) – ein eigener Client aus den gespeicherten Verbindungsdaten.
    func appleDeviceService() -> BotService? {
        if let service, !isMock { return service }
        guard !settings.isMock, settings.isConfigured, !settings.usesAccount || account.isSignedIn,
              let base = settings.baseURL else { return nil }
        return APIClient(baseURL: base, auth: serverAuth(for: settings))
    }

    /// Prüft die Verbindung per GET /api/health. Wirft bei Fehler.
    func validate(_ candidate: ConnectionSettings) async throws -> Health {
        if candidate.isMock { return Health(ok: true, version: "demo", userName: "Arman") }
        guard let base = candidate.baseURL else {
            throw APIError(status: 0, message: "Die Server-Adresse ist ungültig.")
        }
        let client = APIClient(baseURL: base, auth: serverAuth(for: candidate))
        return try await client.health()
    }

    /// `followMovedServer`: Bei einem Konto-Server nach einem Fehler einmal prüfen, ob er inzwischen unter einer
    /// anderen Adresse erreichbar ist (z. B. neuer Port nach Update der Server-App), und dann dorthin verbinden.
    func connect(with candidate: ConnectionSettings, persist: Bool, followMovedServer: Bool = true) async {
        // Jeder Aufbau bekommt eine Nummer; ein älterer, noch laufender Aufbau (z. B. doppelt getippt
        // „Neu versuchen“) darf danach weder den Zustand setzen noch einen zweiten Live-Kanal öffnen.
        connectGeneration += 1
        let generation = connectGeneration
        service?.disconnectEvents()
        service = nil
        liveVoice = nil
        settings = candidate
        if persist { candidate.save() }
        phase = .connecting
        connectStartedAt = Date()
        hadConnection = false
        resetData()

        let svc: BotService
        if candidate.isMock {
            svc = MockService()
        } else if let base = candidate.baseURL {
            svc = APIClient(baseURL: base, auth: serverAuth(for: candidate))
        } else {
            phase = .offline("Die Server-Adresse ist ungültig.")
            return
        }
        svc.onEvent = { [weak self] event in self?.apply(event) }
        svc.onSocketState = { [weak self] state in self?.socketChanged(state) }
        service = svc
        // Eigene Scoop-Bilder (v1.12) über die Verbindung des jeweiligen Scoops nachladen
        installPhotoFetcher()
        // Nach `service`: unterbrochene Uploads gesicherter Anhänge starten sofort neu
        restoreComposerDrafts(for: candidate)

        // Jeder Schritt hat eine harte Frist (unabhängig von URLSession, JWT-Erneuerung und App-Pausen): Die App
        // zeigt nie endlos „Verbinde …“, sondern spätestens nach `handshakeTimeout` eine Meldung mit „Neu versuchen“.
        do {
            try await Self.probeLocalNetwork(candidate.baseURL)
            guard generation == connectGeneration else { return }
            let health = try await Self.withDeadline(Self.handshakeTimeout,
                                                     onTimeout: Self.timeoutError(for: candidate)) { try await svc.health() }
            guard generation == connectGeneration else { return }
            serverVersion = health.version
            if let name = health.userName, !name.isEmpty { userName = name }
            try await Self.withDeadline(Self.initialLoadTimeout, onTimeout: APIError(
                status: 0, message: "Der Server antwortet, lädt die Chats aber zu langsam. Bitte später erneut versuchen.")) {
                try await self.reloadAll()
            }
            guard generation == connectGeneration else { return }
            phase = .online
            Task { await self.refreshLimitsWidget() }  // Widget „Abo-Limits“ (Server 1.31)
        } catch {
            guard generation == connectGeneration else { return }
            #if DEBUG
            let elapsed = connectStartedAt.map { String(format: "%.1f s", Date().timeIntervalSince($0)) } ?? "?"
            print("[Verbindung] \(candidate.baseURL?.absoluteString ?? "?") fehlgeschlagen nach \(elapsed): \(error)")
            #endif
            // Konto-Server unter neuer Adresse? Dann direkt dorthin (einmal), statt mit der alten Adresse zu scheitern.
            if followMovedServer, candidate.usesAccount, !candidate.isMock,
               let moved = await movedServerSettings(for: candidate) {
                guard generation == connectGeneration else { return }
                await connect(with: moved, persist: !isTestServer, followMovedServer: false)
                return
            }
            guard generation == connectGeneration else { return }
            phase = .offline(await offlineMessage(for: error, candidate: candidate))
            #if DEBUG
            print("[Verbindung] Meldung nach \(connectStartedAt.map { String(format: "%.1f s", Date().timeIntervalSince($0)) } ?? "?"): \(phase)")
            #endif
        }
        connectStartedAt = nil
        // Auch offline den Live-Kanal starten: Er verbindet selbst neu und meldet sich, sobald der
        // Server wieder da ist (dann lädt `socketChanged` alles nach und setzt `online`).
        svc.connectEvents()
        if !candidate.isMock, !skipPush {
            PushManager.shared.reset()
            PushManager.shared.requestAuthorizationAndRegister()
            await PushManager.shared.syncWithServer()
        }
    }

    // MARK: - Fristen und Meldungen

    /// Führt `operation` aus und wirft `onTimeout`, wenn sie nach `seconds` noch läuft. Die Frist gilt auch dann,
    /// wenn die Operation auf etwas wartet, das sich nicht abbrechen lässt; sie wird danach abgebrochen.
    static func withDeadline<T: Sendable>(_ seconds: Double, onTimeout: Error,
                                          _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let gate = DeadlineGate()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let work = Task { @MainActor in
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                guard gate.open else { return }
                gate.open = false
                cont.resume(with: result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard gate.open else { return }
                gate.open = false
                work.cancel()
                cont.resume(throwing: onTimeout)
            }
        }
    }

    /// Wer zuerst kommt (Ergebnis oder Frist), setzt die Fortsetzung fort; nur auf dem MainActor benutzt.
    private final class DeadlineGate { var open = true }

    private static func hostLabel(_ candidate: ConnectionSettings) -> String {
        guard let url = candidate.baseURL, let host = url.host() else { return candidate.serverURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private static func timeoutError(for candidate: ConnectionSettings) -> APIError {
        let name = candidate.cloudServerName.map { "„\($0)“" } ?? "Der Server"
        return APIError(status: 0, message: "\(name) antwortet nicht (\(hostLabel(candidate))). "
                        + "Läuft der Mac und ist er mit dem Internet verbunden?")
    }

    /// Verständliche Meldung für den Verbindungsbanner. Bei Konto-Servern mit dem Stand aus „Deine Server“.
    private func offlineMessage(for error: Error, candidate: ConnectionSettings) async -> String {
        let name = candidate.cloudServerName.map { "„\($0)“" } ?? "Der Server"
        if let api = error as? APIError, api.status == 401 {
            return candidate.usesAccount
                ? "\(name) lehnt die Anmeldung ab. Ist er noch mit deinem Konto gekoppelt? Sonst: Anderen Server wählen."
                : "Der Server lehnt den Zugangsschlüssel ab. Bitte neu koppeln."
        }
        if let cloud = error as? CloudError, cloud.isUnauthorized {
            return "Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an."
        }
        if candidate.usesAccount, let id = candidate.cloudServerID,
           let server = account.server(id: id), !server.online {
            return "\(name) ist offline. Läuft der Mac und ist er mit dem Internet verbunden?"
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "Keine Internetverbindung."
            case .cannotFindHost, .dnsLookupFailed:
                return "\(name) ist unter \(Self.hostLabel(candidate)) nicht zu finden."
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .secureConnectionFailed:
                return Self.timeoutError(for: candidate).message
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Konto-Server: aktuelle Adresse aus „Deine Server“ (höchstens 6 s). Liefert neue Einstellungen, wenn sich die
    /// Adresse geändert hat – sonst nil.
    private func movedServerSettings(for candidate: ConnectionSettings) async -> ConnectionSettings? {
        guard account.isSignedIn, let id = candidate.cloudServerID else { return nil }
        _ = try? await Self.withDeadline(6, onTimeout: CancellationError()) { await self.account.loadServers() }
        guard let server = account.server(id: id), let url = server.connectURL,
              Self.normalizedURL(url) != Self.normalizedURL(candidate.serverURL) else { return nil }
        return ConnectionSettings(serverURL: url, token: candidate.token, cloudServerID: id, cloudServerName: server.name)
    }

    private static func normalizedURL(_ s: String) -> String {
        ConnectionSettings(serverURL: s, token: "").baseURL?.absoluteString.lowercased() ?? s
    }

    /// Adresse im Heim-Netz (…local, 192.168.x, 10.x, 172.16–31.x)? Solche Adressen sind unterwegs nicht erreichbar.
    nonisolated static func isLocalNetworkHost(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        if host.hasSuffix(".local") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }) {
            return (16...31).contains(second)
        }
        return false
    }

    nonisolated static let localOnlyMessage = "Server nur im Heim-WLAN erreichbar – öffentliche Freigabe in der Server-App einrichten "
        + "(AIS Scoops Server → Erreichbarkeit → Tailscale)."

    /// Bei einer Heim-Netz-Adresse höchstens 10 s warten statt endlos zu laden: Antwortet dort nichts, klar sagen,
    /// dass der Server nur im WLAN erreichbar ist. Jede HTTP-Antwort (auch 401) gilt als erreichbar.
    nonisolated static func probeLocalNetwork(_ base: URL?) async throws {
        guard let base, isLocalNetworkHost(base) else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: URLRequest(url: base.appending(path: "/api/health"), timeoutInterval: 10))
        } catch {
            throw APIError(status: 0, message: localOnlyMessage)
        }
    }

    func disconnect() {
        // Laufenden Aufbau verwerfen, damit er den Zustand danach nicht mehr setzt
        connectGeneration += 1
        connectStartedAt = nil
        service?.disconnectEvents()
        service = nil
        // Bei einer Konto-Verbindung bleibt ein früherer API-Token für „Manuell verbinden“ liegen
        ConnectionSettings.clear(keepToken: settings.usesAccount)
        settings = ConnectionSettings(serverURL: ConnectionSettings.suggestedURL, token: "")
        resetData()
        discardAllComposerDrafts()
        selectedChatID = nil
        // iPhone/iPad: Einstellungen schließen, damit Anmeldung bzw. „Deine Server“ sichtbar werden
        showSettings = false
        phase = .unconfigured
    }

    func handlePairingURL(_ url: URL) {
        guard let s = ConnectionSettings.fromPairingURL(url) else { return }
        Task {
            do {
                _ = try await validate(s)
                await connect(with: s, persist: true)
            } catch {
                errorMessage = "Kopplung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private func resetData() {
        taskBoard.reset()
        showTaskBoard = false
        // Geteilte Chats (andere Server) bleiben erhalten
        let keep = Set(sharedBots.map(\.id))
        bots = []; groups = []; files = files.filter { keep.contains($0.key) }; vault = []; sidebarSections = []
        messages = messages.filter { keep.contains($0.key) }; hasMoreHistory = hasMoreHistory.filter { keep.contains($0.key) }
        memories = memories.filter { keep.contains($0.key) }; routines = routines.filter { keep.contains($0.key) }
        standingApprovals = standingApprovals.filter { keep.contains($0.key) }
        skills = skills.filter { keep.contains($0.key) }; initiative = nil; shareLists = [:]
        botUsage = botUsage.filter { keep.contains($0.key) }; botUsageUnavailable = []
        typing = typing.filter { keep.contains($0.key) }; usage = nil; nodes = []
        if !isGuestChat(selectedChatID) { computer = .unknown }
        // Entwürfe bleiben: `connect` (auch „Neu versuchen“) ruft das bei jedem Aufbau auf. Verworfen werden sie
        // nur bei einem Serverwechsel (`restoreComposerDrafts`) oder beim Trennen.
    }

    private func socketChanged(_ state: SocketState) {
        socketState = state
        if state == .connected {
            // Apple-Gerät (v1.18): bei jedem (Neu-)Verbinden anmelden, sobald der Store online ist
            Task { @MainActor in
                for _ in 0..<40 where phase != .online { try? await Task.sleep(for: .milliseconds(250)) }
                AppleDeviceAgent.shared.socketConnected()
            }
            if hadConnection {
                // Nach Neuverbindung offene Listen nachladen.
                Task {
                    try? await reloadAll()
                    if phase != .online { phase = .online }
                    await PushManager.shared.syncWithServer()
                }
            } else if phase != .online {
                Task {
                    try? await reloadAll()
                    phase = .online
                    await PushManager.shared.syncWithServer()
                }
            }
            hadConnection = true
        }
    }

    func reloadAll() async throws {
        guard let service else { return }
        let loaded = try await service.bots()
        bots = sortBots(loaded)
        await loadModels()
        // Gruppen gibt es ab Server v1.1; ältere Server liefern hier einen Fehler.
        groups = ((try? await service.groups()) ?? []).sorted(by: Self.chatOrder)
        // Bereiche gibt es ab Server v1.6
        if let list = try? await service.sections() { sidebarSections = list }
        let known = Set(bots.map(\.id) + groups.map(\.id))
        let shared = Set(sharedBots.map(\.id) + account.sharedWithMe.map(\.botId))
        // Nach dem Nachladen nur Tipp-Anzeigen behalten, deren Chat laut Server noch arbeitet
        typing = typing.filter { key, _ in
            shared.contains(key) || (known.contains(key) && (bot(key)?.busy == true || group(key)?.busy == true))
        }
        // Geteilte Chats gehören zu anderen Servern; solange „Mit mir geteilt“ noch lädt, nichts abwählen
        if let sel = selectedChatID, !known.contains(sel), !shared.contains(sel),
           account.sharedLoaded || !account.isSignedIn { selectedChatID = nil }
        await loadNodes()
        syncComputerNode()
        if !isGuestChat(selectedChatID) { computer = (try? await service.computer(node: computerNodeID)) ?? computer }
        // Bereits geöffnete eigene Chats aktualisieren (geteilte lädt ihre eigene Verbindung)
        for chatID in messages.keys where !shared.contains(chatID) {
            await loadLatestMessages(chatID: chatID)
        }
        if let sel = selectedChatID {
            if ChatGroup.isGroupID(sel) { await loadFiles(chatID: sel) } else { await loadProfile(botID: sel) }
        }
    }

    /// Modellkatalog des Servers (Server 1.34, docs/modelle.md): Auswahl, Namen und Hinweise ohne App-Update.
    /// Ältere Server (404): eingebaute Liste. Offline: zuletzt geladener Katalog bleibt.
    func loadModels() async {
        guard let service else { return }
        do {
            ModelCatalogStore.shared.update(try await service.models())
        } catch let error as APIError where error.status == 404 {
            ModelCatalogStore.shared.useBuiltIn()
        } catch {}
    }

    private var connectGeneration = 0

    /// „Neu versuchen“: Verbindung komplett neu aufbauen (alter Dienst und Live-Kanal werden beendet).
    func retry() async {
        await connect(with: settings, persist: false)
    }

    /// Beim Zurückkehren in die App: offline oder seit über 15 s „Verbinde …“ → neu verbinden.
    private func resumeConnectionIfNeeded() {
        guard isConfigured, !isMock else { return }
        switch phase {
        case .offline:
            Task { await retry() }
        case .connecting:
            if let started = connectStartedAt, Date().timeIntervalSince(started) > 15 { Task { await retry() } }
        default:
            break
        }
    }

    /// Live-Kanal sofort neu verbinden statt auf den nächsten Rückfall-Zeitpunkt zu warten.
    func reconnectEventsNow() {
        service?.reconnectEvents()
    }

    // MARK: - Ereignisse

    func apply(_ event: ServerEvent) {
        switch event {
        case .messageCreated(let m):
            upsert(m)
            if m.role == .bot { setTyping(chatID: m.chatId, member: m.meta.authorId ?? m.chatId, false) }
            // Nachrichten anderer Personen (geteilter Scoop) zählen als ungelesen
            updateChatSummary(m, countUnread: m.role != .user || !isOwnMessage(m))
            if m.role == .bot { NotificationManager.shared.notifyIfNeeded(message: m, store: self) }
        case .messageUpdated(let m):
            upsert(m)
            if m.meta.task != nil { taskBoard.applyStatus(m) }
            // Lauf beendet → Tipp-Anzeige des Autors zurücksetzen
            if m.role == .status, !m.isRunning { setTyping(chatID: m.chatId, member: m.meta.authorId ?? m.chatId, false) }
            if let idx = bots.firstIndex(where: { $0.id == m.chatId }), bots[idx].lastMessage?.id == m.id {
                bots[idx].lastMessage = m
            }
            if let idx = groups.firstIndex(where: { $0.id == m.chatId }), groups[idx].lastMessage?.id == m.id {
                groups[idx].lastMessage = m
            }
        case .botCreated(let b), .botUpdated(let b):
            if !b.busy { typing[b.id] = nil }
            if selectedChatID == b.id, bot(b.id)?.computerNode != b.computerNode { computerNodeID = b.computerNode }
            if let idx = bots.firstIndex(where: { $0.id == b.id }) {
                var merged = b
                if visibleChatID == b.id { merged.unread = 0 }
                bots[idx] = merged
            } else {
                bots.append(b)
            }
            bots = sortBots(bots)
        case .botDeleted(let id):
            removeBotLocally(id)
        case .botTyping(let chatID, let botID, let isTyping):
            setTyping(chatID: chatID, member: botID, isTyping)
        case .groupCreated(let g), .groupUpdated(let g):
            if !g.busy { typing[g.id] = nil }
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                var merged = g
                if visibleChatID == g.id { merged.unread = 0 }
                groups[idx] = merged
            } else {
                groups.append(g)
            }
            groups.sort(by: Self.chatOrder)
        case .groupDeleted(let id):
            removeGroupLocally(id)
        case .sectionsUpdated(let list):
            sidebarSections = list
        case .skillUpdated(let skill):
            for key in skills.keys where skill.botId == nil || skill.botId == key {
                var list = skills[key] ?? []
                if let i = list.firstIndex(where: { $0.id == skill.id }) { list[i] = skill } else { list.insert(skill, at: 0) }
                skills[key] = list
            }
            if let owner = skill.botId, skills[owner] == nil { skills[owner] = [skill] }
        case .skillDeleted(let id):
            for key in skills.keys { skills[key]?.removeAll { $0.id == id } }
            if presentedSkillID == id { presentedSkillID = nil }
        case .computerUpdated(let c):
            if let i = nodes.firstIndex(where: { $0.id == c.node }) {
                var n = nodes[i]
                n.state = c.state; n.botId = c.botId; n.botName = c.botId.flatMap { bot($0)?.name }
                if let online = c.online { n.online = online } else if n.isBuiltin { n.online = c.state != "asleep" }
                if let paused = c.paused { n.paused = paused }
                if nodes[i] != n { nodes[i] = n }
            }
            if c.node == computerNodeID, computer != c { computer = c }
        case .nodeUpdated(let n):
            if let i = nodes.firstIndex(where: { $0.id == n.id }) {
                if nodes[i] != n { nodes[i] = n }
            } else {
                nodes.append(n)
            }
            nodes = Self.uniqueNodes(nodes)
            if n.id == computerNodeID {
                let c = n.computerState
                if computer.state != c.state || computer.online != c.online || computer.paused != c.paused { computer = c }
            }
        case .nodeDeleted(let id):
            nodes.removeAll { $0.id == id }
            if computerNodeID == id { computerNodeID = ComputerNode.builtinID }
            // Scoops auf dem entfernten Rechner: bis `bot.updated` kommt, auf einen vorhandenen Rechner zeigen
            let fallback = nodes.first?.id ?? ComputerNode.builtinID
            for i in bots.indices where bots[i].computerNode == id { bots[i].computerNode = fallback }
            syncComputerNode()
        case .modelsUpdated:
            Task { await loadModels() }
        case .routineUpdated(let r):
            var list = routines[r.botId] ?? []
            if let idx = list.firstIndex(where: { $0.id == r.id }) { list[idx] = r } else { list.append(r) }
            routines[r.botId] = list
        case .taskUpdated(let t):
            taskBoard.apply(t)
        case .taskDeleted(let id):
            taskBoard.remove(id: id)
        case .deviceCommand(let cmd):
            AppleDeviceAgent.shared.handle(cmd)
        case .pong, .unknown:
            break
        }
    }

    func setTyping(chatID: String, member: String, _ on: Bool) {
        var set = typing[chatID] ?? []
        if on { set.insert(member) } else { set.remove(member) }
        typing[chatID] = set.isEmpty ? nil : set
    }

    func upsert(_ incoming: Message) {
        let m = localized(incoming)
        guard var list = messages[m.chatId] else { return } // Chat noch nicht geladen
        // Server-Version einer optimistisch angezeigten Nachricht ersetzt die lokale Blase
        if m.role == .user, let i = list.firstIndex(where: { $0.localState == .sending && $0.text == m.text }) {
            list.remove(at: i)
        }
        if let idx = list.lastIndex(where: { $0.id == m.id }) {
            list[idx] = m
        } else {
            list.append(m)
            list.sort { $0.createdAt < $1.createdAt }
        }
        messages[m.chatId] = list
        // Neue Datei im Chat → Bibliothek nachladen
        if m.meta.fileId != nil, files[m.chatId] != nil, file(m.meta.fileId) == nil {
            Task { await loadFiles(chatID: m.chatId) }
        }
    }

    func updateChatSummary(_ m: Message, countUnread: Bool) {
        let counts = countUnread && (m.role == .bot || m.role == .approval || (m.role == .user && !isOwnMessage(m)))
        let markRead = visibleChatID == m.chatId && isAppActive
        if let idx = bots.firstIndex(where: { $0.id == m.chatId }) {
            bots[idx].lastMessage = m
            if counts { if markRead { scheduleMarkRead(m.chatId) } else { bots[idx].unread += 1 } }
            bots = sortBots(bots)
        } else if let idx = groups.firstIndex(where: { $0.id == m.chatId }) {
            groups[idx].lastMessage = m
            if counts { if markRead { scheduleMarkRead(m.chatId) } else { groups[idx].unread += 1 } }
            groups.sort(by: Self.chatOrder)
        } else if let idx = sharedBots.firstIndex(where: { $0.id == m.chatId }) {
            sharedBots[idx].lastMessage = m
            if counts {
                if markRead { scheduleMarkRead(m.chatId) } else { sharedBots[idx].unread += 1 }
            }
            sharedBots = sortBots(sharedBots)
        }
    }

    // MARK: - Entwürfe der Eingabe

    /// Entwurf der Eingabe für diesen Chat (wird beim ersten Zugriff angelegt).
    func composerDraft(_ chatID: String) -> ComposerDraft {
        if let draft = composerDrafts[chatID] { return draft }
        let draft = makeComposerDraft()
        composerDrafts[chatID] = draft
        return draft
    }

    private func makeComposerDraft() -> ComposerDraft {
        let draft = ComposerDraft()
        draft.onChange = { [weak self] in self?.scheduleComposerDraftSave() }
        draft.attachments.onChange = { [weak self] in self?.scheduleComposerDraftSave() }
        return draft
    }

    private static func draftServerKey(_ settings: ConnectionSettings) -> String {
        settings.isMock ? ConnectionSettings.mockURL : (settings.baseURL?.absoluteString ?? settings.serverURL)
    }

    /// Gesicherte Entwürfe laden, einmal pro Server (eigener Ordner je Server, siehe `DraftArchive`). Ein schon angelegter, leerer Entwurf wird befüllt statt ersetzt,
    /// damit ein bereits offener Chat dasselbe Objekt behält.
    private func restoreComposerDrafts(for candidate: ConnectionSettings) {
        let server = Self.draftServerKey(candidate)
        guard draftsServer != server else { return }
        // Echter Serverwechsel: Entwürfe des bisherigen verwerfen
        if draftsServer != nil { discardAllComposerDrafts() }
        draftsServer = server
        DraftArchive.server = server
        guard let index = DraftArchive.load(), index.server == server else { return }
        for (chatID, saved) in index.drafts {
            let draft = composerDrafts[chatID] ?? makeComposerDraft()
            guard draft.isEmpty else { continue }
            composerDrafts[chatID] = draft
            draft.text = saved.text
            draft.replyTo = saved.replyTo
            draft.attachments.restore(saved.attachments, chatID: chatID, store: self)
        }
    }

    /// Entwurf eines entfernten Chats verwerfen (Dateien liegen dann ohnehin nicht mehr in seiner Bibliothek).
    private func discardComposerDraft(_ chatID: String) {
        composerDrafts.removeValue(forKey: chatID)?.attachments.reset()
        scheduleComposerDraftSave()
    }

    /// Alle Entwürfe verwerfen, im Speicher und auf der Platte (Serverwechsel, Trennen).
    private func discardAllComposerDrafts() {
        draftSaveTask?.cancel()
        for draft in composerDrafts.values {
            draft.onChange = nil
            draft.attachments.onChange = nil
            draft.attachments.reset()
        }
        composerDrafts = [:]
        draftsServer = nil
        DraftArchive.wipe()
    }

    /// Sicherung kurz entprellt (Tippen, Upload-Fortschritt)
    private func scheduleComposerDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveComposerDraftsNow()
        }
    }

    func saveComposerDraftsNow() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let server = draftsServer else { return }
        var drafts: [String: DraftArchive.SavedDraft] = [:]
        for (chatID, draft) in composerDrafts {
            let attachments = draft.attachments.saved
            guard !draft.text.isEmpty || !attachments.isEmpty || draft.replyTo != nil else { continue }
            drafts[chatID] = DraftArchive.SavedDraft(text: draft.text, attachments: attachments, replyTo: draft.replyTo)
        }
        DraftArchive.save(DraftArchive.Index(server: server, drafts: drafts))
    }

    private func removeBotLocally(_ id: String) {
        discardComposerDraft(id)
        bots.removeAll { $0.id == id }
        messages[id] = nil; memories[id] = nil; routines[id] = nil; typing[id] = nil; files[id] = nil
        standingApprovals[id] = nil
        for i in groups.indices { groups[i].memberIds.removeAll { $0 == id } }
        if selectedChatID == id { selectedChatID = nil; showInspector = false }
    }

    private func removeGroupLocally(_ id: String) {
        discardComposerDraft(id)
        groups.removeAll { $0.id == id }
        messages[id] = nil; typing[id] = nil; files[id] = nil
        if selectedChatID == id { selectedChatID = nil; showInspector = false }
    }

    /// Angepinnte zuerst, dann nach letzter Aktivität.
    func sortBots(_ list: [Bot]) -> [Bot] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let da = a.lastMessage?.createdAt ?? a.createdAt ?? .distantPast
            let db = b.lastMessage?.createdAt ?? b.createdAt ?? .distantPast
            return da > db
        }
    }

    private static func chatOrder(_ a: ChatGroup, _ b: ChatGroup) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return (a.lastMessage?.createdAt ?? a.createdAt ?? .distantPast) > (b.lastMessage?.createdAt ?? b.createdAt ?? .distantPast)
    }

    // MARK: - Abfragen

    func bot(_ id: String?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id } ?? sharedBots.first { $0.id == id }
    }

    /// Nur eigene Scoops (z. B. für Gruppen, Erwähnungen)
    func ownBot(_ id: String?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    func group(_ id: String?) -> ChatGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func chatExists(_ id: String) -> Bool { bot(id) != nil || group(id) != nil }

    func chatName(_ id: String) -> String { bot(id)?.name ?? group(id)?.name ?? "Chat" }

    /// Mitglieder einer Gruppe (in Reihenfolge), bei Einzelchats der Bot selbst.
    func members(of chatID: String) -> [Bot] {
        if let g = group(chatID) { return g.memberIds.compactMap { bot($0) } }
        return bot(chatID).map { [$0] } ?? []
    }

    /// Bots, die in diesem Chat gerade tippen.
    func typingMembers(_ chatID: String) -> [Bot] {
        (typing[chatID] ?? []).compactMap { bot($0) }.sorted { $0.name < $1.name }
    }

    func isTyping(_ chatID: String) -> Bool { !(typing[chatID] ?? []).isEmpty }

    /// Wartet der Scoop bzw. die Gruppe auf mich (Freigabe, Rückfrage einer Aufgabe)? Für das rote „?“.
    func isWaiting(_ chatID: String) -> Bool {
        bot(chatID)?.waiting ?? group(chatID)?.waiting ?? false
    }

    /// Arbeitet der Chat gerade? Quellen: `busy`-Feld, `bot.typing`, laufende Statusnachricht.
    /// Eine „running“-Statuszeile zählt nur, wenn sie jünger als 15 Minuten ist (verpasste Updates
    /// dürfen den Stopp-Knopf nicht dauerhaft festhalten).
    func isBusy(_ chatID: String) -> Bool {
        if isTyping(chatID) { return true }
        if bot(chatID)?.busy == true || group(chatID)?.busy == true { return true }
        guard let status = messages[chatID]?.last(where: { $0.role == .status }), status.isRunning else { return false }
        // Aufgabe wartet auf eine Rückfrage oder Freigabe: der Scoop arbeitet nicht, er wartet auf dich
        if status.meta.task?.state == "waiting" { return false }
        let started = status.meta.startedAt ?? status.createdAt
        return Date().timeIntervalSince(started) < 15 * 60
    }

    /// Eintrag der Seitenleiste: Scoop oder Gruppe.
    enum ChatEntry: Identifiable, Hashable {
        case bot(Bot)
        case group(ChatGroup)

        var id: String {
            switch self { case .bot(let b): b.id; case .group(let g): g.id }
        }
        var pinned: Bool {
            switch self { case .bot(let b): b.pinned; case .group(let g): g.pinned }
        }
        var section: String? {
            switch self { case .bot(let b): b.trimmedSection; case .group(let g): g.trimmedSection }
        }
        var name: String {
            switch self { case .bot(let b): b.name; case .group(let g): g.name }
        }
        var lastMessage: Message? {
            switch self { case .bot(let b): b.lastMessage; case .group(let g): g.lastMessage }
        }
        var unread: Int {
            switch self { case .bot(let b): b.unread; case .group(let g): g.unread }
        }
        var isPrimary: Bool {
            if case .bot(let b) = self { return b.primary }
            return false
        }
        var date: Date {
            switch self {
            case .bot(let b): b.lastMessage?.createdAt ?? b.createdAt ?? .distantPast
            case .group(let g): g.lastMessage?.createdAt ?? g.createdAt ?? .distantPast
            }
        }
    }

    /// Alle Scoops und Gruppen, zuletzt aktive zuerst (ohne Suchfilter).
    var allEntries: [ChatEntry] {
        (bots.map(ChatEntry.bot) + groups.map(ChatEntry.group)).sorted { $0.date > $1.date }
    }

    /// Angepinnte Chats; der Haupt-Scoop steht immer als Erstes (auch ohne Anheften).
    var pinnedEntries: [ChatEntry] {
        let list = allEntries.filter { $0.pinned || $0.isPrimary }
        return filtered(list.filter(\.isPrimary) + list.filter { !$0.isPrimary })
    }

    var primaryBot: Bot? { bots.first(where: \.primary) }

    /// Ein Bereich der Seitenleiste mit seinen (nicht angepinnten) Chats. `name == nil` = „Ohne Bereich“.
    struct SectionGroup: Identifiable {
        var name: String?
        var title: String { name ?? "Ohne Bereich" }
        var entries: [ChatEntry]
        var collapsed: Bool
        var id: String { name ?? "\u{0}ohne" }
    }

    /// Bereiche in Server-Reihenfolge (auch leere), danach Bereiche, die nur an Chats hängen, zuletzt „Ohne Bereich“.
    var sections: [SectionGroup] {
        let unpinned = filtered(allEntries.filter { !$0.pinned && !$0.isPrimary })
        var buckets: [String: [ChatEntry]] = [:]
        for e in unpinned { buckets[e.section ?? "", default: []].append(e) }
        var order = sidebarSections
        for name in Set(unpinned.compactMap(\.section)).sorted() where !order.contains(where: { $0.name == name }) {
            order.append(SidebarSection(name: name))
        }
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        var result: [SectionGroup] = order.compactMap { sec in
            let items = buckets[sec.name] ?? []
            if searching && items.isEmpty { return nil }      // bei der Suche leere Bereiche ausblenden
            return SectionGroup(name: sec.name, entries: items, collapsed: sec.collapsed && !searching)
        }
        let none = buckets[""] ?? []
        if !none.isEmpty || (!searching && !order.isEmpty) {
            result.append(SectionGroup(name: nil, entries: none, collapsed: noSectionCollapsed && !searching))
        }
        return result
    }

    /// Bereiche (geordnet) laut Server.
    private(set) var sidebarSections: [SidebarSection] = []
    /// „Ohne Bereich“ einklappen (nur lokal)
    var noSectionCollapsed = false

    var sectionNames: [String] { sections.compactMap(\.name) }

    // MARK: Bereiche ändern (optimistisch, dann Server)

    func loadSections() async {
        guard let service, let list = try? await service.sections() else { return }
        sidebarSections = list
    }

    private func saveSections(_ list: [SidebarSection]) async {
        let previous = sidebarSections
        sidebarSections = list
        guard let service else { return }
        do { sidebarSections = try await service.saveSections(list) } catch {
            sidebarSections = previous
            report(error)
        }
    }

    /// Alle aktuell sichtbaren Bereiche als Liste (inkl. solcher, die nur an Chats hängen).
    private var materializedSections: [SidebarSection] {
        sections.compactMap { g in g.name.map { SidebarSection(name: $0, collapsed: g.collapsed) } }
    }

    func createSection(_ rawName: String) async -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var list = materializedSections
        if !list.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            list.append(SidebarSection(name: name))
            await saveSections(list)
        }
        return list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name ?? name
    }

    func renameSection(_ from: String, to rawName: String) async {
        let to = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service, !to.isEmpty, to != from else { return }
        // optimistisch
        sidebarSections = sidebarSections.map { $0.name == from ? SidebarSection(name: to, collapsed: $0.collapsed) : $0 }
        for i in bots.indices where bots[i].section == from { bots[i].section = to }
        for i in groups.indices where groups[i].section == from { groups[i].section = to }
        do {
            try await service.renameSection(from: from, to: to)
            await loadSections()
        } catch {
            report(error)
            try? await reloadAll()
        }
    }

    func deleteSection(_ name: String) async {
        guard let service else { return }
        sidebarSections.removeAll { $0.name == name }
        for i in bots.indices where bots[i].section == name { bots[i].section = nil }
        for i in groups.indices where groups[i].section == name { groups[i].section = nil }
        do {
            try await service.deleteSection(name: name)
            await loadSections()
        } catch {
            report(error)
            try? await reloadAll()
        }
    }

    func moveSection(_ name: String, by offset: Int) async {
        var list = materializedSections
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        let j = max(0, min(list.count - 1, i + offset))
        guard i != j else { return }
        list.swapAt(i, j)
        await saveSections(list)
    }

    /// Bereich an die Stelle eines anderen verschieben (Ziehen und Ablegen).
    func moveSection(_ name: String, before target: String) async {
        var list = materializedSections
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        let item = list.remove(at: i)
        let j = list.firstIndex(where: { $0.name == target }) ?? list.count
        list.insert(item, at: j)
        await saveSections(list)
    }

    func toggleCollapsed(_ name: String?) async {
        guard let name else { noSectionCollapsed.toggle(); return }
        var list = materializedSections
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        list[i].collapsed.toggle()
        await saveSections(list)
    }

    /// Scoop oder Gruppe einem Bereich zuordnen (`nil` = Ohne Bereich). Optimistisch, dann PATCH.
    func move(chatID: String, toSection name: String?) async {
        if let i = bots.firstIndex(where: { $0.id == chatID }) {
            guard bots[i].trimmedSection != name else { return }
            let old = bots[i].section
            bots[i].section = name
            guard let service else { return }
            do { apply(.botUpdated(try await service.updateBot(id: chatID, patch: BotPatch(section: .some(name))))) } catch {
                if let j = bots.firstIndex(where: { $0.id == chatID }) { bots[j].section = old }
                report(error)
            }
        } else if let i = groups.firstIndex(where: { $0.id == chatID }) {
            guard groups[i].trimmedSection != name else { return }
            let old = groups[i].section
            groups[i].section = name
            guard let service else { return }
            do { apply(.groupUpdated(try await service.updateGroup(id: chatID, patch: GroupPatch(section: .some(name))))) } catch {
                if let j = groups.firstIndex(where: { $0.id == chatID }) { groups[j].section = old }
                report(error)
            }
        }
    }

    var knownSections: [String] {
        Array(Set(bots.compactMap(\.trimmedSection) + groups.compactMap(\.trimmedSection))).sorted()
    }

    private func filtered(_ list: [ChatEntry]) -> [ChatEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { e in
            if e.name.localizedCaseInsensitiveContains(q) { return true }
            if case .bot(let b) = e, (b.label ?? "").localizedCaseInsensitiveContains(q) { return true }
            return (e.lastMessage?.text ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Chat

    func loadLatestMessages(chatID: String) async {
        guard let service = service(for: chatID) else { return }
        do {
            let page = try await service.messages(chatID: chatID, before: nil, limit: Self.pageSize).map(localized)
            if let existing = messages[chatID], !existing.isEmpty, let firstNew = page.first {
                // Ältere, bereits geladene Nachrichten behalten
                let pageIDs = Set(page.map(\.id))
                let older = existing.filter { $0.createdAt < firstNew.createdAt && !pageIDs.contains($0.id) }
                messages[chatID] = older + page
            } else {
                messages[chatID] = page
                hasMoreHistory[chatID] = page.count >= Self.pageSize
            }
            // Dateikarten und Anhänge brauchen die Bibliothek
            if files[chatID] == nil, page.contains(where: { $0.meta.fileId != nil || !($0.meta.fileIds ?? []).isEmpty }) {
                await loadFiles(chatID: chatID)
            }
        } catch {
            if messages[chatID] == nil { messages[chatID] = [] }
            report(error)
        }
    }

    func loadOlderMessages(chatID: String) async {
        guard let service = service(for: chatID), hasMoreHistory[chatID] == true, !loadingHistory.contains(chatID),
              let first = messages[chatID]?.first else { return }
        loadingHistory.insert(chatID)
        defer { loadingHistory.remove(chatID) }
        do {
            let page = try await service.messages(chatID: chatID, before: first.id, limit: Self.pageSize).map(localized)
            let known = Set(messages[chatID]?.map(\.id) ?? [])
            messages[chatID] = page.filter { !known.contains($0.id) } + (messages[chatID] ?? [])
            hasMoreHistory[chatID] = page.count >= Self.pageSize
        } catch {
            report(error)
        }
    }

    /// Sendet optimistisch: Die Blase erscheint sofort („wird gesendet“) und wird durch die Server-Nachricht ersetzt.
    @discardableResult
    func send(_ text: String, to chatID: String, voice: Bool = false, fileIDs: [String] = [],
              replyTo: ReplyRef? = nil, taskOptions: TaskOptions? = nil) async -> Message? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service(for: chatID) != nil, !trimmed.isEmpty || !fileIDs.isEmpty else { return nil }
        // Eigene Nachricht im geteilten Chat: Absender gleich mitgeben (rechts, ohne Namen)
        let ownUserID = isGuestChat(chatID) || bot(chatID)?.isSharedByMe == true ? account.user?.id : nil
        var meta = MessageMeta(fileIds: fileIDs.isEmpty ? nil : fileIDs)
        if voice { meta.voice = true }
        meta.authorUserId = ownUserID
        meta.replyTo = replyTo
        if let taskOptions, !taskOptions.isEmpty { meta.taskOptions = taskOptions }
        var local = Message(id: "local-\(UUID().uuidString)", botId: chatID, role: .user, text: trimmed,
                            createdAt: Date(), meta: meta)
        local.localState = .sending
        if messages[chatID] == nil { messages[chatID] = [] }
        messages[chatID]?.append(local)
        updateChatSummary(local, countUnread: false)
        return await deliver(local)
    }

    /// Fehlgeschlagene Nachricht erneut senden.
    func retry(_ message: Message) {
        guard message.localState == .failed else { return }
        var m = message
        m.localState = .sending
        replaceLocal(m)
        Task { await deliver(m) }
    }

    private func deliver(_ local: Message) async -> Message? {
        guard let service = service(for: local.chatId) else { return nil }
        let out = OutgoingMessage(text: local.text, voice: local.meta.voice, fileIds: local.meta.fileIds,
                                  replyTo: local.meta.replyTo?.id, task: local.meta.taskOptions)
        do {
            let m = try await service.send(chatID: local.chatId, message: out)
            messages[local.chatId]?.removeAll { $0.id == local.id }
            upsert(m)
            updateChatSummary(m, countUnread: false)
            return m
        } catch {
            var failed = local
            failed.localState = .failed
            replaceLocal(failed)
            report(error)
            return nil
        }
    }

    private func replaceLocal(_ m: Message) {
        guard let idx = messages[m.chatId]?.firstIndex(where: { $0.id == m.id }) else { return }
        messages[m.chatId]?[idx] = m
    }

    func stop(chatID: String) async {
        do { try await service(for: chatID)?.stop(chatID: chatID) } catch { report(error) }
    }

    /// Hintergrund-Aufgabe anhalten (Knopf auf der Aufgaben-Karte)
    func stopTask(_ taskID: String, chatID: String) async {
        do { try await service(for: chatID)?.stopTask(id: taskID) } catch { report(error) }
    }

    func chatBecameVisible(_ chatID: String) {
        visibleChatID = chatID
        scheduleMarkRead(chatID)
    }

    func chatBecameHidden(_ chatID: String) {
        if visibleChatID == chatID { visibleChatID = nil }
    }

    func scheduleMarkRead(_ chatID: String) {
        var hadUnread = false
        if let idx = bots.firstIndex(where: { $0.id == chatID }) {
            hadUnread = bots[idx].unread > 0
            bots[idx].unread = 0
        } else if let idx = sharedBots.firstIndex(where: { $0.id == chatID }) {
            hadUnread = sharedBots[idx].unread > 0
            sharedBots[idx].unread = 0
        } else if let idx = groups.firstIndex(where: { $0.id == chatID }) {
            hadUnread = groups[idx].unread > 0
            groups[idx].unread = 0
        }
        guard hadUnread else { return }
        readTasks[chatID]?.cancel()
        readTasks[chatID] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await service(for: chatID)?.markRead(chatID: chatID)
        }
    }

    func decide(_ message: Message, approve: Bool) async {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return }
        do {
            let updated = try await service.decide(approvalID: approvalID, approve: approve, note: nil)
            upsert(updated)
        } catch {
            report(error)
        }
    }

    /// v1.20: freigeben und künftig automatisch erlauben („Immer erlauben“). Gibt bei Fehler den Text zurück.
    /// Bei der Mail-Karte gehen die geänderten Felder mit; die Dauerfreigabe gilt für die tatsächlichen Empfänger.
    func decideAlways(_ message: Message, mailEdits: MailEdits? = nil) async -> String? {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return "Keine Verbindung zum Server." }
        var optimistic = message
        optimistic.meta.state = "approved"
        optimistic.meta.always = true
        if optimistic.meta.mail != nil { optimistic.meta.mail?.status = "sending" }
        upsert(optimistic)
        do {
            upsert(try await service.decideAlways(approvalID: approvalID, mailEdits: mailEdits?.isEmpty == true ? nil : mailEdits))
            await loadStandingApprovals(botID: message.meta.authorId ?? message.chatId)
            return nil
        } catch {
            upsert(message)
            return self.message(error)
        }
    }

    /// v1.20: dauerhafte Freigaben eines eigenen Scoops laden (Gäste: nichts).
    func loadStandingApprovals(botID: String) async {
        guard access(for: botID) == nil, let service = service(for: botID),
              let list = try? await service.standingApprovals(botID: botID) else { return }
        if standingApprovals[botID] != list { standingApprovals[botID] = list }
    }

    /// v1.20: dauerhafte Freigabe entfernen (künftig fragt der Scoop wieder).
    func deleteStandingApproval(_ item: StandingApproval) async {
        let before = standingApprovals[item.botId]
        standingApprovals[item.botId]?.removeAll { $0.id == item.id }
        do {
            try await service(for: item.botId)?.deleteStandingApproval(botID: item.botId, id: item.id)
        } catch {
            standingApprovals[item.botId] = before
            report(error)
        }
    }

    // MARK: - Mail-Karte und Reaktionen (v1.9)

    /// Aktive Gmail-Konten (für „Von“ in der Mail-Karte).
    var gmailAccounts: [ConnectedAccount] {
        connections?.apps.first { $0.slug == "gmail" }?.accounts.filter { $0.state == .active } ?? []
    }

    /// Mail senden (mit nur geänderten Feldern) bzw. verwerfen. Gibt bei Fehler den Text zurück.
    func decideMail(_ message: Message, approve: Bool, edits: MailEdits?) async -> String? {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return "Keine Verbindung zum Server." }
        // Sofort „Wird gesendet …“ bzw. „Verworfen“ zeigen
        var optimistic = message
        optimistic.meta.mail?.status = approve ? "sending" : "discarded"
        optimistic.meta.state = approve ? "approved" : "declined"
        upsert(optimistic)
        do {
            upsert(try await service.decideMail(approvalID: approvalID, approve: approve, edits: edits?.isEmpty == true ? nil : edits))
            return nil
        } catch {
            upsert(message)
            return self.message(error)
        }
    }

    /// v1.21: Verbesserung für einen anderen Scoop (Aufsicht) freigeben – optional mit bearbeitetem Text – bzw. ablehnen.
    /// Gibt bei Fehler den Text zurück.
    func decideScoopUpdate(_ message: Message, approve: Bool, after: String?) async -> String? {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return "Keine Verbindung zum Server." }
        var optimistic = message
        optimistic.meta.state = approve ? "approved" : "declined"
        optimistic.meta.scoopUpdate?.status = approve ? "applied" : "declined"
        upsert(optimistic)
        do {
            upsert(try await service.decideScoopUpdate(approvalID: approvalID, approve: approve, after: approve ? after : nil))
            return nil
        } catch {
            upsert(message)
            return self.message(error)
        }
    }

    /// Tresor-Formular (v1.10) speichern bzw. ablehnen. Gibt bei Fehler den Text des Servers zurück.
    /// Das Passwort wird nur für diese eine Anfrage übergeben und nirgends gespeichert oder protokolliert.
    func decideVault(_ message: Message, approve: Bool, edits: VaultEdits?) async -> String? {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return "Keine Verbindung zum Server." }
        do {
            upsert(try await service.decideVault(approvalID: approvalID, approve: approve, edits: approve ? edits : nil))
            return nil
        } catch {
            return self.message(error)
        }
    }

    /// Armans Reaktion setzen (`emoji`) oder entfernen (`nil`): sofort anzeigen, bei Fehler zurücksetzen.
    func react(_ message: Message, emoji: String?) {
        guard let service = service(for: message.chatId), message.localState == nil else { return }
        var optimistic = message
        var reactions = optimistic.meta.reactions ?? [:]
        reactions["user"] = emoji
        optimistic.meta.reactions = reactions.isEmpty ? nil : reactions
        upsert(optimistic)
        Task {
            do {
                upsert(try await service.react(messageID: message.id, emoji: emoji))
            } catch {
                // Zurück auf den aktuellen Stand ohne die eigene Änderung
                if var current = messages[message.chatId]?.first(where: { $0.id == message.id }) {
                    var r = current.meta.reactions ?? [:]
                    r["user"] = message.meta.reactions?["user"]
                    current.meta.reactions = r.isEmpty ? nil : r
                    upsert(current)
                }
                report(error)
            }
        }
    }

    // MARK: - Anlegen mit sofortiger Rückmeldung

    /// Platzhalter in der Seitenleiste, solange der Server einen neuen Scoop / eine Gruppe anlegt.
    struct PendingChat: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var mascot: Mascot?
        var memberIDs: [String] = []
    }
    private(set) var pendingChats: [PendingChat] = []

    /// Nur Demo/Screenshots: Platzhalter, der stehen bleibt.
    func addDemoPending(name: String, mascot: Mascot) {
        pendingChats.append(PendingChat(name: name, mascot: mascot))
    }

    /// `photo`: zugeschnittenes eigenes Bild (v1.12), wird nach dem Anlegen hochgeladen.
    func createBotInBackground(_ draft: BotDraft, photo: Data? = nil) {
        let pending = PendingChat(name: draft.name, mascot: draft.mascot)
        pendingChats.append(pending)
        Task {
            let bot = await createBot(draft)
            pendingChats.removeAll { $0.id == pending.id }
            if let bot, let photo { await setAvatar(bot.id, image: photo) }
        }
    }

    func createGroupInBackground(name: String, memberIDs: [String]) {
        let pending = PendingChat(name: name, mascot: nil, memberIDs: memberIDs)
        pendingChats.append(pending)
        Task {
            await createGroup(name: name, memberIDs: memberIDs)
            pendingChats.removeAll { $0.id == pending.id }
        }
    }

    // MARK: - Gruppen

    @discardableResult
    func createGroup(name: String, memberIDs: [String]) async -> ChatGroup? {
        guard let service else { return nil }
        do {
            let g = try await service.createGroup(name: name, memberIDs: memberIDs)
            apply(.groupCreated(g))
            selectedChatID = g.id
            return g
        } catch {
            report(error)
            return nil
        }
    }

    func updateGroup(_ id: String, _ patch: GroupPatch) async {
        guard let service else { return }
        do { apply(.groupUpdated(try await service.updateGroup(id: id, patch: patch))) } catch { report(error) }
    }

    func deleteGroup(_ id: String) async {
        guard let service else { return }
        do {
            try await service.deleteGroup(id: id)
            removeGroupLocally(id)
        } catch { report(error) }
    }

    func toggleGroupPinned(_ g: ChatGroup) async {
        await updateGroup(g.id, GroupPatch(pinned: !g.pinned))
    }

    // MARK: - Bibliothek

    func loadFiles(chatID: String) async {
        guard let service = service(for: chatID) else { return }
        do {
            let list = try await service.files(chatID: chatID)
            if files[chatID] != list { files[chatID] = list }
        } catch {
            if files[chatID] == nil { files[chatID] = [] }
        }
    }

    /// Sucht eine Datei in allen geladenen Bibliotheken.
    func file(_ id: String?) -> LibraryFile? {
        guard let id else { return nil }
        for list in files.values { if let f = list.first(where: { $0.id == id }) { return f } }
        return nil
    }

    func uploadFile(chatID: String, name: String, mime: String, data: Data,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> LibraryFile {
        guard let service = service(for: chatID) else { throw APIError(status: 0, message: "Keine Verbindung.") }
        let f = try await service.uploadFile(chatID: chatID, name: name, mime: mime, data: data, progress: progress)
        files[chatID, default: []].removeAll { $0.id == f.id }
        files[chatID, default: []].insert(f, at: 0)
        return f
    }

    func deleteFile(_ file: LibraryFile) async {
        guard let service = service(for: file.chatId) else { return }
        do {
            try await service.deleteFile(id: file.id)
            for key in files.keys { files[key]?.removeAll { $0.id == file.id } }
        } catch { report(error) }
    }

    /// Lädt eine Datei in den Zwischenspeicher (Quick Look, Teilen, Vorschaubilder).
    func download(_ file: LibraryFile) async -> URL? {
        guard let service = service(for: file.chatId) else { return nil }
        if let cached = downloaded[file.id], FileManager.default.fileExists(atPath: cached.path) { return cached }
        do {
            let url = try await service.downloadFile(file)
            downloaded[file.id] = url
            return url
        } catch {
            report(error)
            return nil
        }
    }

    @ObservationIgnored private var downloaded: [String: URL] = [:]

    // MARK: - Apps verbinden (v1.8)

    private(set) var connections: ConnectionsOverview?
    private(set) var connectionsError: String?
    private(set) var loadingConnections = false

    func loadConnections(fresh: Bool = false) async {
        guard let service else { connectionsError = "Keine Verbindung zum Server."; return }
        loadingConnections = true
        defer { loadingConnections = false }
        do {
            connections = try await service.connections(fresh: fresh)
            connectionsError = nil
        } catch {
            connectionsError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    /// Fehlertext (Server-Text bei `{"error": …}`, sonst lokalisierte Beschreibung).
    func message(_ error: Error) -> String { (error as? APIError)?.message ?? error.localizedDescription }

    func linkConnection(app: String, alias: String?) async -> Result<ConnectionLink, ConnectionError> {
        guard let service else { return .failure(ConnectionError("Keine Verbindung zum Server.")) }
        do { return .success(try await service.linkConnection(app: app, alias: alias)) } catch { return .failure(ConnectionError(message(error))) }
    }

    /// Rücksprung der Browser-Anmeldung an den Server (Notion direkt): Server tauscht den Code gegen Tokens.
    func finishOAuth(_ callbackURL: URL) async -> Result<ConnectedAccount, ConnectionError> {
        guard let service else { return .failure(ConnectionError("Keine Verbindung zum Server.")) }
        do { return .success(try await service.finishOAuth(callbackURL: callbackURL.absoluteString)) } catch { return .failure(ConnectionError(message(error))) }
    }

    func reconnectAccount(_ id: String) async -> Result<ConnectionLink, ConnectionError> {
        guard let service else { return .failure(ConnectionError("Keine Verbindung zum Server.")) }
        do { return .success(try await service.reconnectAccount(id: id)) } catch { return .failure(ConnectionError(message(error))) }
    }

    func connectedAccountStatus(_ id: String) async -> ConnectedAccount? {
        try? await service?.connectedAccount(id: id)
    }

    func renameConnectedAccount(_ id: String, alias: String) async -> String? {
        guard let service else { return "Keine Verbindung zum Server." }
        do {
            _ = try await service.renameConnectedAccount(id: id, alias: alias)
            await loadConnections()
            return nil
        } catch { return message(error) }
    }

    func deleteConnectedAccount(_ id: String) async -> String? {
        guard let service else { return "Keine Verbindung zum Server." }
        do {
            try await service.deleteConnectedAccount(id: id)
            await loadConnections()
            return nil
        } catch { return message(error) }
    }

    // MARK: - Haupt-Scoop und Initiative (v1.4)

    /// v1.21: „Darf andere Scoops prüfen“ (Aufsicht; beim Haupt-Scoop immer an)
    func setCanReview(_ botID: String, _ on: Bool) async {
        await updateBot(botID, BotPatch(canReview: on))
    }

    /// v1.29: Rechner-Zugriff (Rechte-Modus, Standard-Bereich, Projektordner; nur Admin)
    func setComputerAccess(_ botID: String, _ access: ScoopAccess) async {
        await updateBot(botID, BotPatch(computerAccess: access))
    }

    func setPrimary(_ botID: String, _ on: Bool) async {
        await updateBot(botID, BotPatch(primary: on))
        if on { for i in bots.indices where bots[i].id != botID { bots[i].primary = false } }
        await loadInitiative()
    }

    func loadInitiative() async {
        guard let service else { return }
        if let s = try? await service.initiative() { initiative = s }
    }

    func updateInitiative(_ patch: InitiativePatch) async {
        guard let service else { return }
        do { initiative = try await service.updateInitiative(patch) } catch { report(error) }
    }

    /// Löst sofort einen Check aus. Gibt true zurück, wenn der Server ihn angenommen hat.
    @discardableResult
    func runInitiative() async -> Bool {
        guard let service else { return false }
        do { try await service.runInitiative(); return true } catch { report(error); return false }
    }

    // MARK: - Fähigkeiten (v1.4)

    func loadSkills(botID: String) async {
        guard let service = service(for: botID) else { return }
        if let list = try? await service.skills(botID: botID), skills[botID] != list { skills[botID] = list }
    }

    func skill(_ id: String?) -> Skill? {
        guard let id else { return nil }
        for list in skills.values { if let s = list.first(where: { $0.id == id }) { return s } }
        return nil
    }

    /// Fähigkeit zu einem Ereignis „Fähigkeit gespeichert: Name“ finden (per `meta.skill_id` oder Name).
    func skill(for event: Message) async -> Skill? {
        if let s = skill(event.meta.skillId) { return s }
        let name = event.text.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
        func match(_ list: [Skill]) -> Skill? {
            list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                ?? list.first { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
        }
        if let s = match(skills.values.flatMap { $0 }) { return s }
        if let botID = bot(event.chatId)?.id ?? (event.meta.authorId) { await loadSkills(botID: botID) }
        if let s = match(skills.values.flatMap { $0 }) { return s }
        guard let service, let all = try? await service.skills(botID: nil) else { return nil }
        if let id = event.meta.skillId { return all.first { $0.id == id } }
        return match(all)
    }

    func updateSkill(_ id: String, _ patch: SkillPatch) async {
        guard let service = service(for: skill(id)?.botId) else { return }
        do { apply(.skillUpdated(try await service.updateSkill(id: id, patch: patch))) } catch { report(error) }
    }

    func deleteSkill(_ id: String) async {
        guard let service = service(for: skill(id)?.botId) else { return }
        do {
            try await service.deleteSkill(id: id)
            apply(.skillDeleted(id: id))
        } catch { report(error) }
    }

    // MARK: - Tresor (v1.4)

    func loadVault() async {
        guard let service else { return }
        do { vault = try await service.vault() } catch { report(error) }
    }

    func saveVaultEntry(id: String?, draft: VaultDraft) async -> Bool {
        guard let service else { return false }
        do {
            let entry = id == nil ? try await service.createVaultEntry(draft) : try await service.updateVaultEntry(id: id!, draft: draft)
            if let i = vault.firstIndex(where: { $0.id == entry.id }) { vault[i] = entry } else { vault.append(entry) }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteVaultEntry(_ id: String) async {
        guard let service else { return }
        do {
            try await service.deleteVaultEntry(id: id)
            vault.removeAll { $0.id == id }
        } catch { report(error) }
    }

    // MARK: - Genaue Spracherkennung (Server, v1.2)

    /// Schreibhilfe für die Erkennung: Namen der Scoops und häufige Begriffe.
    var transcriptionPrompt: String {
        (bots.map(\.name) + groups.map(\.name) + ["Arman", "MLP", "AIS"]).joined(separator: ", ")
    }

    // MARK: - Live-Sprechmodus (v1.13)

    /// Zuletzt geladene Live-Infos des Servers (Stimmen, Verfügbarkeit)
    var liveVoice: LiveVoiceInfo?

    /// Live-Infos laden (einmal pro Verbindung, mit `refresh` neu).
    @discardableResult
    func loadLiveVoice(refresh: Bool = false, chatID: String? = nil) async -> LiveVoiceInfo {
        // Geteilter Chat: Live-Sprechmodus läuft auf dem Server des Admins (nicht zwischenspeichern)
        if isGuestChat(chatID) {
            guard let guest = scopedService(for: chatID) else { return .unavailable }
            return (try? await guest.liveVoiceInfo()) ?? .unavailable
        }
        if let liveVoice, !refresh { return liveVoice }
        guard let service else { return .unavailable }
        let info = (try? await service.liveVoiceInfo()) ?? .unavailable
        liveVoice = info
        return info
    }

    func liveVoiceRequest(chatID: String) async -> URLRequest? {
        guard let service = service(for: chatID) else { return nil }
        return try? await service.liveVoiceRequest(chatID: chatID)
    }

    /// Stimmprobe (WAV) oder Fehlermeldung
    func liveVoicePreview(voice: String) async -> Result<Data, Error> {
        // Profil eines geteilten Scoops: Stimmprobe vom Server des Admins
        let target = isGuestChat(selectedChatID) ? scopedService(for: selectedChatID) : service
        guard let service = target else { return .failure(APIError(status: 0, message: "Keine Verbindung.")) }
        do { return .success(try await service.liveVoicePreview(voice: voice)) } catch { return .failure(error) }
    }

    /// Schickt eine Aufnahme an `/api/transcribe`. Gibt nil zurück, wenn es nicht klappt (dann bleibt der Gerätetext).
    func transcribe(_ file: URL, timeout: TimeInterval = 20) async -> String? {
        // Ohne eigenen Server (nur geteilte Scoops): Erkennung über den Server des sichtbaren Chats
        guard let service = service ?? scopedService(for: visibleChatID), let data = try? Data(contentsOf: file), !data.isEmpty
        else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let text = try await service.transcribe(audio: data, name: "diktat.m4a", language: "de",
                                                    prompt: transcriptionPrompt, timeout: timeout)
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } catch {
            return nil
        }
    }

    // MARK: - Bot-Rechner übernehmen

    /// Übernimmt den Bot-Rechner. Gibt eine Fehlermeldung zurück (z. B. 409, wenn ein Scoop ihn gerade braucht).
    func takeOverComputer() async -> String? {
        guard let service = computerService else { return "Keine Verbindung." }
        do {
            computer = try await service.takeover(node: computerNodeID)
            return nil
        } catch let e as APIError {
            return e.message
        } catch {
            return "Keine Verbindung zum Rechner – nochmal versuchen."
        }
    }

    func releaseComputer() async {
        guard let service = computerService else { return }
        try? await service.release(node: computerNodeID)
        if let c = try? await service.computer(node: computerNodeID) { computer = c }
    }

    @ObservationIgnored private var inputQueue: [ComputerInput] = []
    @ObservationIgnored private var inputWorker: Task<Void, Never>?

    /// Eingaben „feuern und vergessen“: kleine Warteschlange, nacheinander gesendet, blockiert nie die Oberfläche.
    /// Bei schlechter Verbindung werden alte Einträge verworfen (höchstens 20 in der Schlange).
    func sendComputerInput(_ input: ComputerInput) {
        inputQueue.append(input)
        if inputQueue.count > 20 { inputQueue.removeFirst(inputQueue.count - 20) }
        guard inputWorker == nil else { return }
        inputWorker = Task {
            while !inputQueue.isEmpty {
                let next = inputQueue.removeFirst()
                guard let service = computerService else { break }
                do { try await service.computerInput(next, node: computerNodeID) } catch {
                    if let e = error as? APIError, e.status == 409 || e.status == 403 {
                        // Übernahme beendet (z. B. Zeitüberschreitung) → Zustand neu laden
                        inputQueue.removeAll()
                        if let c = try? await service.computer(node: computerNodeID) { computer = c }
                    }
                }
            }
            inputWorker = nil
        }
    }

    // MARK: - Live-Aktivität

    /// `true`, wenn der Server das Token angenommen hat.
    @discardableResult
    func registerLiveActivity(chatID: String, runID: String, pushToken: String) async -> Bool {
        guard let service, !isMock, !skipPush else { return false }
        do {
            try await service.registerLiveActivity(chatID: chatID, runID: runID, pushToken: pushToken)
            return true
        } catch { return false }
    }

    #if os(iOS)
    /// Stand der gemeinsamen Scoops-Live-Aktivität (`ensure` legt serverseitig eine Sitzung an). nil im Demo-Modus/offline.
    func liveActivityStatus(ensure: Bool) async -> ScoopsLiveStatus? {
        guard let service, !isMock, !skipPush, phase == .online else { return nil }
        return try? await service.liveActivityStatus(ensure: ensure)
    }
    #endif

    // MARK: - Bots

    @discardableResult
    func createBot(_ draft: BotDraft) async -> Bot? {
        guard let service else { return nil }
        do {
            let bot = try await service.createBot(draft)
            if !bots.contains(where: { $0.id == bot.id }) { bots.append(bot); bots = sortBots(bots) }
            selectedChatID = bot.id
            return bot
        } catch {
            report(error)
            return nil
        }
    }

    func updateBot(_ id: String, _ patch: BotPatch) async {
        guard let service = service(for: id) else { return }
        do {
            let updated = try await service.updateBot(id: id, patch: patch)
            if isGuestChat(id) { applySharedBot(updated) } else { apply(.botUpdated(updated)) }
        } catch {
            report(error)
        }
    }

    // MARK: Eigenes Scoop-Bild (v1.12)

    /// Lädt ein zugeschnittenes Bild hoch bzw. setzt den Scoop zurück aufs Maskottchen (`image == nil`).
    @discardableResult
    func setAvatar(_ id: String, image: Data?) async -> Bool {
        guard let service = service(for: id) else { return false }
        do {
            let updated: Bot
            if let image {
                updated = try await service.uploadAvatar(botID: id, data: image)
                // Sofort lokal ablegen, spart den Rück-Download der eigenen Datei
                if let photo = updated.mascot.photo { ScoopPhotoCache.shared.store(image, for: photo) }
            } else {
                updated = try await service.deleteAvatar(botID: id)
                ScoopPhotoCache.shared.remove(botID: id)
            }
            if isGuestChat(id) { applySharedBot(updated) } else { apply(.botUpdated(updated)) }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func togglePinned(_ bot: Bot) async {
        await updateBot(bot.id, BotPatch(pinned: !bot.pinned))
    }

    func deleteBot(_ id: String) async {
        guard let service else { return }
        do {
            try await service.deleteBot(id: id)
            removeBotLocally(id)
        } catch {
            report(error)
        }
    }

    func resetHistory(_ id: String) async {
        guard let service else { return }
        do {
            try await service.reset(chatID: id)
            messages[id] = []
            hasMoreHistory[id] = false
            if let idx = bots.firstIndex(where: { $0.id == id }) { bots[idx].lastMessage = nil; bots[idx].unread = 0 }
            if let idx = groups.firstIndex(where: { $0.id == id }) { groups[idx].lastMessage = nil; groups[idx].unread = 0 }
            await loadLatestMessages(chatID: id)
        } catch {
            report(error)
        }
    }

    // MARK: - Profil

    func loadProfile(botID: String) async {
        guard let service = service(for: botID) else { return }
        // Gäste: Gedächtnis und Routinen nur mit Rolle „Bearbeiten“, Rechner nur ab „Zusehen“
        let access = self.access(for: botID)
        let editable = access?.role.canEdit ?? true
        let m = editable ? (try? await service.memories(botID: botID)) : nil
        let r = editable ? (try? await service.routines(botID: botID)) : nil
        let showsComputer = (access?.computer.canView ?? true) && service === computerService
        let c = showsComputer ? (try? await service.computer(node: computerNodeID)) : nil
        // Nur zuweisen, was sich geändert hat: Jede Zuweisung invalidiert alle Ansichten, die den Wert lesen
        // (z. B. Bot-Rechner-Vorschauen im Chat), auch wenn der Inhalt gleich bleibt.
        if let m, memories[botID] != m { memories[botID] = m }
        if let r, routines[botID] != r { routines[botID] = r }
        if let c, computer != c { computer = c }
        await loadStandingApprovals(botID: botID)
        await loadFiles(chatID: botID)
        await loadSkills(botID: botID)
    }

    func setRoutine(_ routine: Routine, enabled: Bool) async {
        guard let service = service(for: routine.botId) else { return }
        // Optimistisch umschalten
        if var list = routines[routine.botId], let idx = list.firstIndex(where: { $0.id == routine.id }) {
            list[idx].enabled = enabled
            routines[routine.botId] = list
        }
        do {
            let updated = try await service.setRoutine(id: routine.id, enabled: enabled)
            apply(.routineUpdated(updated))
        } catch {
            if var list = routines[routine.botId], let idx = list.firstIndex(where: { $0.id == routine.id }) {
                list[idx].enabled = !enabled
                routines[routine.botId] = list
            }
            report(error)
        }
    }

    /// v1.20: Modell einer Routine ändern (`nil` = wie der Scoop), optimistisch.
    func setRoutineModel(_ routine: Routine, model: String?) async {
        guard let service = service(for: routine.botId) else { return }
        func set(_ value: String?) {
            if var list = routines[routine.botId], let idx = list.firstIndex(where: { $0.id == routine.id }) {
                list[idx].model = value
                routines[routine.botId] = list
            }
        }
        set(model)
        do {
            apply(.routineUpdated(try await service.setRoutineModel(id: routine.id, model: model)))
        } catch {
            set(routine.model)
            report(error)
        }
    }

    func runRoutine(_ routine: Routine) async {
        do { try await service(for: routine.botId)?.runRoutine(id: routine.id) } catch { report(error) }
    }

    func deleteRoutine(_ routine: Routine) async {
        do {
            try await service(for: routine.botId)?.deleteRoutine(id: routine.id)
            routines[routine.botId]?.removeAll { $0.id == routine.id }
        } catch { report(error) }
    }

    func deleteMemory(_ memory: Memory, botID: String) async {
        do {
            try await service(for: botID)?.deleteMemory(id: memory.id)
            for key in memories.keys { memories[key]?.removeAll { $0.id == memory.id } }
        } catch { report(error) }
    }

    /// Kosten eines Scoops laden (über den Server, auf dem er läuft).
    func loadBotUsage(botID: String) async {
        guard let service = service(for: botID) else { return }
        do {
            let u = try await service.botUsage(botID: botID)
            if botUsage[botID] != u { botUsage[botID] = u }
            botUsageUnavailable.remove(botID)
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            botUsageUnavailable.insert(botID)
        } catch {
            // Netzfehler: alten Stand behalten
        }
    }

    func loadUsage() async {
        guard let service else { return }
        do { usage = try await service.usage() } catch { report(error) }
    }

    func screenImageURL(scale: Double, quality: Int) -> URL? {
        computerService?.screenImageURL(scale: scale, quality: quality, node: computerNodeID)
    }

    /// Demo: simulierter Ausfall des Bot-Bildschirms bis zu diesem Zeitpunkt (Startargument `-screenfaildemo [s]`).
    var mockScreenOutage: Date?

    /// Ein Bildschirmfoto laden. Wirft bei fehlender Verbindung (auch wenn die App gerade neu verbindet
    /// und noch kein Dienst da ist), damit die Abruf-Schleife weiter versucht statt zu enden.
    /// Im Demo-Modus `nil` (die Ansicht zeigt den erfundenen Bildschirm).
    func fetchScreen(scale: Double, quality: Int) async throws -> PlatformImage? {
        if isMock {
            try await Task.sleep(for: .milliseconds(250))
            if let until = mockScreenOutage, Date() < until { throw URLError(.cannotConnectToHost) }
            return nil
        }
        guard let url = computerService?.screenImageURL(scale: scale, quality: quality, node: computerNodeID) else {
            throw URLError(.notConnectedToInternet)
        }
        let data = try await APIClient.fetchScreen(url, timeout: 5)
        guard let img = PlatformImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return img
    }

    /// Rechner-Status neu laden (z. B. „Aufwecken / Erneut versuchen“).
    func refreshComputer() async {
        guard let service = computerService else { return }
        let nodeID = computerNodeID
        if let c = try? await service.computer(node: nodeID), computerNodeID == nodeID, computer != c { computer = c }
    }

    // MARK: - Rechner (v1.11, Scoops Connect)

    func node(_ id: String?) -> ComputerNode? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    /// Name eines Rechners für Anzeigen (Bot-Rechner auch ohne geladene Liste)
    func nodeName(_ id: String) -> String {
        node(id)?.name ?? (id == ComputerNode.builtinID ? "Bot-Rechner" : "Rechner")
    }

    /// Rechner des ausgewählten Scoops anzeigen (Gruppen und ältere Server: Bot-Rechner)
    func syncComputerNode() {
        let target = selectedChatID.flatMap { bot($0)?.computerNode } ?? ComputerNode.builtinID
        // Geteilte Scoops: Rechner des Admin-Servers (nicht in der eigenen Rechnerliste)
        let valid = target == ComputerNode.builtinID || nodes.isEmpty || node(target) != nil || isGuestChat(selectedChatID)
        computerNodeID = valid ? target : ComputerNode.builtinID
    }

    func loadNodes() async {
        guard let service else { return }
        // Rechner gibt es ab Server v1.11; ältere Server: nur der Bot-Rechner
        if let list = try? await service.nodes() {
            let unique = Self.uniqueNodes(list)
            if nodes != unique { nodes = unique }
        }
    }

    /// Jede Rechner-ID nur einmal (Schutz gegen doppelte Einträge aus Ereignis und Nachladen).
    static func uniqueNodes(_ list: [ComputerNode]) -> [ComputerNode] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    func pairNode() async throws -> NodePairing {
        guard let service else { throw URLError(.notConnectedToInternet) }
        return try await service.pairNode()
    }

    func renameNode(_ node: ComputerNode, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service, !trimmed.isEmpty, trimmed != node.name else { return }
        do { apply(.nodeUpdated(try await service.renameNode(id: node.id, name: trimmed))) } catch { report(error) }
    }

    func deleteNode(_ node: ComputerNode) async {
        guard let service, !node.isBuiltin else { return }
        do {
            try await service.deleteNode(id: node.id)
            apply(.nodeDeleted(id: node.id))
            for b in bots where b.computerNode == node.id {
                var copy = b; copy.computerNode = ComputerNode.builtinID
                apply(.botUpdated(copy))
            }
        } catch { report(error) }
    }

    /// Rechner eines Scoops festlegen (PATCH computer_node)
    func setComputerNode(_ nodeID: String, for botID: String) async {
        await updateBot(botID, BotPatch(computerNode: nodeID))
    }

    func registerDevice(_ registration: DeviceRegistration) async throws {
        guard let service else { return }
        try await service.registerDevice(registration)
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        errorMessage = error.localizedDescription
    }
}
