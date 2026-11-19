import SwiftUI

/// Schritt 3: Server. Vorhandenen Server wählen, sonst Anleitung (Mac, „AIS Scoops Server“ laden, Kopplungscode),
/// Code eingeben, warten bis der Server online ist, verbinden. Fehler: Code abgelaufen, Server nicht erreichbar.
///
/// Die Kopplung selbst ist unverändert (`servers:claimServer`, docs/accounts.md); siehe docs/onboarding.md.
struct OnboardingServerStep: View {
    var mode: OnboardingFlowView.Mode = .guided
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var code = ""
    @State private var claiming = false
    @State private var codeError: CodeError?
    @State private var slow = false
    @State private var noAddress = false
    @State private var demoUnreachable = false
    @FocusState private var codeFocused: Bool

    private enum CodeError: Equatable {
        case expired
        case other(String)
    }

    /// Unterzustand: gesetzt, sonst aus dem gespeicherten Stand (Kopplung läuft → warten; Server da → Auswahl)
    private var stage: OnboardingServerStage {
        let onboarding = store.onboarding
        if let stage = onboarding.serverStage { return stage }
        if onboarding.pairing != nil { return .waiting }
        return store.account.servers.isEmpty ? .guide : .choose
    }

    /// Verbindungszustand, der den Schritt bestimmt (nur, solange die Einführung beim Server steht)
    private enum Situation { case connected, connecting, unreachable(String), choosing }

    private var situation: Situation {
        if demoUnreachable {
            return .unreachable("Der Server antwortet nicht. Ist dein Mac wach und im selben Netz?")
        }
        switch store.phase {
        case .online: return mode == .guided ? .connected : .connecting
        case .connecting: return .connecting
        case .offline(let message): return .unreachable(message)
        case .unconfigured: return .choosing
        }
    }

    var body: some View {
        Group {
            switch situation {
            case .connected: connectedView
            case .connecting: connectingView
            case .unreachable(let message): unreachableView(message)
            case .choosing:
                switch stage {
                case .choose: chooseView
                case .guide: guideView
                case .code: codeView
                case .waiting: waitingView
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: stage)
        .onAppear(perform: applyDemoState)
    }

    private func applyDemoState() {
        let onboarding = store.onboarding
        guard let demo = onboarding.demoServerError else {
            if onboarding.serverStage == .waiting, onboarding.pairing == nil, store.account.isMock {
                // `-onboarding server:waiting`: Demo-Kopplung, Server meldet sich nach ein paar Sekunden
                Task { await claim(demoCode: "DEMO-2345") }
            }
            return
        }
        onboarding.demoServerError = nil
        if demo == "expired" {
            codeError = .expired
        } else if demo == "unreachable" {
            demoUnreachable = true
        }
    }

    // MARK: Server wählen

    private var chooseView: some View {
        OnboardingPage {
            OnboardingTitle(title: "Wähle deinen Server",
                            text: "Deine Scoops wohnen auf deinem Mac. Tippe auf den Server, mit dem du dich verbinden möchtest.")
                .padding(.top, 20)
            ServerListSection(onAdd: { store.onboarding.serverStage = .guide })
            sharedOnlyCard
            OnboardingAlternatives()
        } actions: {
            Button("Neuen Mac einrichten") { store.onboarding.serverStage = .guide }
                .buttonStyle(OnboardingButtonStyle(kind: .secondary))
        }
    }

    // MARK: Anleitung

    private var guideView: some View {
        OnboardingPage {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(theme.textSecondary)
                .overlay(alignment: .bottomTrailing) {
                    ScoopFigureView(figure: .creme, size: 44).offset(x: 20, y: 8)
                }
                .padding(.top, 20)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Verbinde deinen Mac",
                            text: "Deine Scoops brauchen einen Mac, auf dem sie wohnen. Den richtest du einmal ein, danach erreichst du sie von überall.")
            OnboardingInfoCard(icon: "laptopcomputer", title: "Das brauchst du",
                               text: "Einen Mac mit Apple-Chip (M1 oder neuer) und macOS 26. Am besten einen, der zu Hause am Strom bleibt.")
            VStack(alignment: .leading, spacing: 16) {
                OnboardingNumberedRow(number: 1, text: "Lade auf dem Mac die App „AIS Scoops Server“ von \(ScoopsLinks.serverDownloadDisplay).")
                downloadButtons
                OnboardingNumberedRow(number: 2, text: "Öffne die App. Ein Assistent führt dich durch die Einrichtung.")
                OnboardingNumberedRow(number: 3, text: "Im Schritt „Mit der App verbinden“ zeigt er dir einen Kopplungscode. Den gibst du gleich hier ein.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(theme, radius: 20)
            sharedOnlyCard
            OnboardingAlternatives()
        } actions: {
            Button("Ich habe einen Kopplungscode") { store.onboarding.serverStage = .code }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// iPhone/iPad: Link an den Mac senden (AirDrop, Nachrichten, Mail). Mac: direkt laden.
    private var downloadButtons: some View {
        let url = ScoopsLinks.serverDownload
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { downloadButtonContent(url) }
            VStack(alignment: .leading, spacing: 10) { downloadButtonContent(url) }
        }
        .padding(.leading, 40)
    }

    @ViewBuilder
    private func downloadButtonContent(_ url: URL) -> some View {
        #if os(iOS)
        ShareLink(item: url,
                  subject: Text("AIS Scoops Server"),
                  message: Text("Lade AIS Scoops Server auf deinen Mac, damit deine Scoops dort wohnen können.")) {
            Label("Link an meinen Mac senden", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PillButtonStyle(kind: .primary))
        .accessibilityHint("Zum Beispiel per AirDrop, Nachrichten oder Mail")
        #else
        Link(destination: url) {
            Label("AIS Scoops Server laden", systemImage: "arrow.down.circle")
        }
        .buttonStyle(PillButtonStyle(kind: .primary))
        #endif
        Button {
            Clipboard.copy(url.absoluteString)
            store.showToast("Link kopiert")
        } label: {
            Label("Link kopieren", systemImage: "doc.on.doc")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
    }

    /// Nur geteilte Scoops (Einladung angenommen): ohne eigenen Server weiter
    @ViewBuilder
    private var sharedOnlyCard: some View {
        if mode == .guided, !store.sharedBots.isEmpty {
            OnboardingInfoCard(icon: "person.2.fill", title: "Mit dir wurden Scoops geteilt",
                               text: "Du kannst sie sofort nutzen. Einen eigenen Server kannst du später verbinden.") {
                Button("Ohne eigenen Server weiter") { store.onboarding.finish() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Code eingeben

    /// Bei offener Tastatur sichtbar halten: die Fehlermeldung (steht unter dem Feld), sonst das Feld
    private var codeScrollTarget: String? {
        if codeError != nil { return "codeError" }
        return codeFocused ? "codeField" : nil
    }

    private var codeView: some View {
        OnboardingPage(scrollTarget: codeScrollTarget) {
            Image(systemName: "number.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.accent)
                .padding(.top, 20)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Gib deinen Kopplungscode ein",
                            text: "Du findest ihn im Assistenten von „AIS Scoops Server“ auf deinem Mac, im Schritt „Mit der App verbinden“. Ein Code gilt 10 Minuten.")
            if store.account.isSignedIn {
                PairingCodeField(code: $code, focused: $codeFocused, onSubmit: { Task { await claim() } })
                    .frame(maxWidth: 360)
                    .id("codeField")
                    .onChange(of: code) { _, _ in if codeError != nil, !claiming { codeError = nil } }
            } else {
                OnboardingInfoCard(icon: "person.crop.circle.badge.exclamationmark", title: "Erst anmelden",
                                   text: "Zum Koppeln mit einem Code brauchst du ein Konto.") {
                    AppleSignInButton(height: 44).padding(.top, 6)
                }
            }
            Group {
                switch codeError {
                case .expired:
                    OnboardingInfoCard(icon: "clock.badge.exclamationmark", tint: theme.danger,
                                       title: "Code abgelaufen oder ungültig",
                                       text: "Fordere im Assistenten auf deinem Mac einen neuen Code an und gib ihn hier ein. Ein Code gilt 10 Minuten.")
                case .other(let message):
                    OnboardingInfoCard(icon: "exclamationmark.triangle", tint: theme.danger,
                                       title: "Das hat nicht geklappt", text: "\(message)")
                case nil:
                    EmptyView()
                }
            }
            .id("codeError")
        } actions: {
            Button {
                Task { await claim() }
            } label: {
                HStack(spacing: 8) {
                    if claiming { ProgressView().controlSize(.small) }
                    Text(claiming ? "Kopple …" : "Koppeln")
                }
            }
            .buttonStyle(OnboardingButtonStyle())
            .disabled(claiming || AccountStore.normalizeCode(code).count != 8 || !store.account.isSignedIn)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { codeFocused = store.account.isSignedIn }
        // Kopplungslink: Code eintragen (auch, wenn der Schritt schon offen ist)
        .task(id: store.onboarding.pendingCode) {
            guard let pending = store.onboarding.pendingCode else { return }
            store.onboarding.pendingCode = nil
            code = pending
            codeError = nil
        }
    }

    private func claim(demoCode: String? = nil) async {
        let normalized = AccountStore.normalizeCode(demoCode ?? code)
        guard normalized.count == 8, !claiming else { return }
        claiming = true
        codeError = nil
        defer { claiming = false }
        do {
            let result = try await store.account.claimServer(code: normalized)
            guard let serverID = result.serverId else {
                codeError = .other("Der Konto-Dienst hat keinen Server gemeldet. Bitte versuch es noch einmal.")
                return
            }
            code = ""
            store.onboarding.pairing = .init(serverID: serverID, name: result.name, claimedAt: Date())
            store.onboarding.serverStage = .waiting
        } catch let e as CloudError where e.code == "invalid_code" || (e.status == 400 && e.code == nil) {
            codeError = .expired
        } catch {
            codeError = .other(error.localizedDescription)
        }
    }

    // MARK: Warten auf den Server

    private var waitingView: some View {
        let pairing = store.onboarding.pairing
        let name = pairing?.name ?? String(localized: "dein Server")
        let server = pairing.flatMap { store.account.server(id: $0.serverID) }
        return OnboardingPage {
            ScoopFigureView(figure: .koralleKopfhoerer, size: 110, floating: true)
                .padding(.top, 24)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Fast geschafft",
                            text: "Dein Code wurde angenommen. Sobald sich „\(name)“ meldet, verbinden wir dich automatisch.")
            VStack(alignment: .leading, spacing: 14) {
                checkRow("Code angenommen", state: .done)
                checkRow("Server meldet sich", state: server?.online == true ? .done : .running)
                checkRow("Verbindung zu deinen Scoops", state: .pending)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(theme, radius: 20)
            if noAddress {
                OnboardingInfoCard(icon: "network.slash", tint: theme.warning, title: "Dein Server hat noch keine Adresse",
                                   text: "Er ist online, aber die App weiß noch nicht, wie sie ihn erreicht. Öffne im Assistenten auf deinem Mac den Schritt „Von unterwegs erreichbar“ und wähle, wie du ihn erreichen möchtest.")
            } else if slow {
                OnboardingInfoCard(icon: "hourglass", tint: theme.warning, title: "Dein Server meldet sich noch nicht",
                                   text: "Läuft „AIS Scoops Server“ auf deinem Mac? Das Symbol muss oben rechts in der Menüleiste zu sehen sein, und der Mac darf nicht schlafen.")
            }
        } actions: {
            if slow || noAddress {
                Button("Erneut prüfen") { Task { await checkPairing() } }
                    .buttonStyle(OnboardingButtonStyle())
            }
            Button("Anderen Code eingeben") {
                store.onboarding.pairing = nil
                store.onboarding.serverStage = .code
            }
            .buttonStyle(OnboardingButtonStyle(kind: slow || noAddress ? .secondary : .plain))
        }
        .task(id: pairing?.serverID) { await pollPairing() }
    }

    private enum CheckState { case done, running, pending }

    private func checkRow(_ title: LocalizedStringKey, state: CheckState) -> some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                case .running:
                    ProgressView().controlSize(.small)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(theme.textTertiary)
                }
            }
            .font(.title3)
            .frame(width: 28)
            Text(title)
                .font(.body)
                .foregroundStyle(state == .pending ? theme.textSecondary : theme.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(state == .done ? Text("Erledigt") : state == .running ? Text("Läuft") : Text("Ausstehend"))
    }

    /// Alle drei Sekunden „Deine Server“ laden, bis der gekoppelte Server online ist und eine Adresse hat; dann verbinden.
    private func pollPairing() async {
        guard let pairing = store.onboarding.pairing else { return }
        slow = false
        noAddress = false
        while !Task.isCancelled, store.onboarding.pairing == pairing, store.phase == .unconfigured {
            if await checkPairing() { return }
            if Date().timeIntervalSince(pairing.claimedAt) > 45 { slow = true }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// `true`, wenn die Verbindung gestartet wurde
    @discardableResult
    private func checkPairing() async -> Bool {
        guard let pairing = store.onboarding.pairing else { return false }
        await store.account.loadServers()
        guard let server = store.account.server(id: pairing.serverID), server.online else { return false }
        guard store.account.isMock || server.connectURL != nil else {
            noAddress = true
            return false
        }
        noAddress = false
        await store.connect(to: server)
        return true
    }

    // MARK: Verbinden, verbunden, nicht erreichbar

    private var serverName: String {
        store.settings.cloudServerName ?? store.settings.baseURL?.host() ?? String(localized: "deinem Server")
    }

    private var connectingView: some View {
        OnboardingPage {
            ScoopFigureView(figure: .blauWolke, size: 110, floating: true)
                .padding(.top, 40)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Verbinde …", text: "Die App meldet sich bei „\(serverName)“ an und lädt deine Scoops.")
            ProgressView()
        } actions: {
            Button("Abbrechen") { store.disconnect() }
                .buttonStyle(OnboardingButtonStyle(kind: .plain))
        }
    }

    private var connectedView: some View {
        OnboardingPage {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(theme.success)
                .padding(.top, 40)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Verbunden", text: "Du bist mit „\(serverName)“ verbunden.")
        } actions: {
            Button("Weiter") { store.onboarding.go(to: .scoop) }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
            Button("Anderen Server wählen") { store.disconnect() }
                .buttonStyle(OnboardingButtonStyle(kind: .plain))
        }
    }

    private func unreachableView(_ message: String) -> some View {
        OnboardingPage {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(theme.warning)
                .padding(.top, 28)
                .accessibilityHidden(true)
            OnboardingTitle(title: "Server nicht erreichbar", text: "\(message)")
            VStack(spacing: 12) {
                OnboardingInfoCard(icon: "menubar.rectangle", title: "Läuft der Server?",
                                   text: "Auf deinem Mac muss „AIS Scoops Server“ geöffnet sein: Das Symbol steht oben rechts in der Menüleiste. Der Mac darf nicht schlafen.")
                OnboardingInfoCard(icon: "wifi", title: "Gleiches Netz oder Tailscale",
                                   text: "Zu Hause klappt es im selben WLAN. Für unterwegs richtest du im Assistenten auf dem Mac den Schritt „Von unterwegs erreichbar“ ein.")
            }
        } actions: {
            Button("Erneut versuchen") {
                demoUnreachable = false
                guard store.phase != .unconfigured else { return }
                Task { await store.connect(with: store.settings, persist: !store.isTestServer) }
            }
            .buttonStyle(OnboardingButtonStyle())
            .keyboardShortcut(.defaultAction)
            Button("Anderen Server wählen") {
                demoUnreachable = false
                store.onboarding.serverStage = nil
                if store.phase != .unconfigured { store.disconnect() }
            }
            .buttonStyle(OnboardingButtonStyle(kind: .plain))
        }
    }
}
