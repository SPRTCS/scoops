import SwiftUI

/// Einführung für neue Nutzer (docs/onboarding.md): Begrüßung → Anmelden → Server → erster Scoop → erste Nachricht
/// → Tipps. Ersetzt den bisherigen Startbildschirm ohne Verbindung.
///
/// `connectOnly`: Einführung ist erledigt, aber gerade kein Server verbunden (abgemeldet, getrennt) bzw. Blatt
/// „Eigenen Server einrichten“ für Gäste. Dann nur Anmelden und Server, ohne Fortschrittsanzeige.
struct OnboardingFlowView: View {
    enum Mode { case guided, connectOnly }
    var mode: Mode = .guided

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    /// Angezeigter Schritt: gespeicherter Schritt, außer es fehlt die Verbindung für Scoop/Nachricht/Tipps
    private var displayedStep: OnboardingStep {
        let needsServer: OnboardingStep = store.account.isSignedIn ? .server : .signIn
        if mode == .connectOnly { return needsServer }
        let step = store.onboarding.step
        if step > .server && store.phase == .unconfigured { return needsServer }
        return step
    }

    var body: some View {
        let step = displayedStep
        VStack(spacing: 0) {
            if mode == .guided, step != .done {
                OnboardingHeader(step: step, canGoBack: canGoBack(step), skip: skipAction(step), onBack: goBack)
            } else if mode == .connectOnly, isPresented {
                // Als Blatt („Eigenen Server einrichten“ für Gäste): Schließen
                HStack {
                    Spacer()
                    Button("Schließen") { dismiss() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            ZStack {
                content(for: step)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .animation(.smooth(duration: 0.35), value: step)
        .onChange(of: store.account.isSignedIn) { _, signedIn in
            // Angemeldet: weiter zum Server
            if signedIn, mode == .guided, store.onboarding.step == .signIn { store.onboarding.go(to: .server) }
        }
    }

    @ViewBuilder
    private func content(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: OnboardingWelcomeStep()
        case .signIn: OnboardingSignInStep(mode: mode)
        case .server: OnboardingServerStep(mode: mode)
        case .scoop: OnboardingScoopStep()
        case .message: OnboardingMessageStep()
        case .tips: OnboardingTipsStep()
        case .done: Color.clear
        }
    }

    // MARK: Zurück und Überspringen

    private func canGoBack(_ step: OnboardingStep) -> Bool {
        step != .welcome || store.onboarding.welcomePage > 0
    }

    private func goBack() {
        let onboarding = store.onboarding
        switch displayedStep {
        case .server:
            // Laufender Verbindungsaufbau oder Fehler: abbrechen und zurück zur Auswahl
            if onboarding.step <= .server, store.phase != .unconfigured, store.phase != .online {
                store.disconnect()
                return
            }
            switch onboarding.serverStage {
            case .waiting:
                onboarding.pairing = nil
                onboarding.serverStage = .code
                return
            case .code:
                onboarding.serverStage = .guide
                return
            case .guide where !store.account.servers.isEmpty:
                onboarding.serverStage = .choose
                return
            default: break
            }
        case .scoop:
            if onboarding.firstBotID == nil, var draft = onboarding.draft, draft.page > 0 {
                draft.page -= 1
                onboarding.draft = draft
                return
            }
        default: break
        }
        if displayedStep != onboarding.step {
            // Ohne Verbindung angezeigter Server-/Anmelde-Schritt: Zurück führt zur Anmeldung
            if displayedStep == .server { onboarding.go(to: .signIn) }
            return
        }
        onboarding.back()
    }

    private func skipAction(_ step: OnboardingStep) -> OnboardingHeader.Skip? {
        let onboarding = store.onboarding
        switch step {
        case .welcome:
            return .init(title: "Überspringen", hint: "Zur Anmeldung") { onboarding.go(to: .signIn) }
        case .scoop where onboarding.firstBotID == nil, .message:
            return .init(title: "Später", hint: "Einführung beenden, du kannst sie in den Einstellungen erneut ansehen") {
                onboarding.finish()
            }
        default:
            return nil
        }
    }
}

// MARK: - Kopfzeile

/// Zurück, „Schritt x von y“ mit Balken, optional „Überspringen“/„Später“.
struct OnboardingHeader: View {
    struct Skip {
        var title: LocalizedStringKey
        var hint: LocalizedStringKey
        var action: () -> Void
    }

    let step: OnboardingStep
    var canGoBack: Bool
    var skip: Skip?
    var onBack: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let total = OnboardingStep.counted.count
        let number = step.number ?? total
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(theme.surfaceRaised, in: Circle())
                    .overlay(Circle().strokeBorder(theme.surfaceBorder))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityLabel("Zurück")
            .keyboardShortcut(.cancelAction)

            VStack(spacing: 6) {
                Text(step == .tips ? "Fertig" : "Schritt \(number) von \(total)")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    ForEach(1...total, id: \.self) { i in
                        Capsule()
                            .fill(i <= number ? theme.accent : theme.surfaceBorder)
                            .frame(height: 5)
                    }
                }
                .frame(maxWidth: 220)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step == .tips ? Text("Einführung fertig") : Text("Schritt \(number) von \(total): \(step.title)"))

            Group {
                if let skip {
                    Button(action: skip.action) {
                        // Ungekürzt (größere Schrift: vorher „Überspring…“), die Mitte gibt dafür Platz ab
                        Text(skip.title)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(skip.hint)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
            .frame(height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }
}

extension OnboardingStep {
    /// Kurzer Name für VoiceOver
    var title: String {
        switch self {
        case .welcome: String(localized: "Willkommen")
        case .signIn: String(localized: "Anmelden")
        case .server: String(localized: "Server verbinden")
        case .scoop: String(localized: "Erster Scoop")
        case .message: String(localized: "Erste Nachricht")
        case .tips: String(localized: "Tipps")
        case .done: String(localized: "Fertig")
        }
    }
}

// MARK: - Seitenlayout

/// Eine Seite der Einführung: scrollbarer Inhalt, unten feste Knöpfe. Begrenzte Breite (iPad, Mac, Duo aufgeklappt).
///
/// `scrollTarget`: ID (`.id(…)`) einer Ansicht im Inhalt, die ganz sichtbar bleiben soll, solange sie gesetzt ist
/// (Eingabefeld mit Tastatur, Fehlermeldung darunter). Das System scrollt nur bis zum Cursor: Auf dem iPhone Duo
/// (zugeklappt wie aufgeklappt) blieb das Feld halb unter den Knöpfen und die Meldung „Code abgelaufen“ ganz
/// verdeckt. Gescrollt wird beim Setzen, wenn die Tastatur erscheint und nach jeder Größenänderung (Auf-/Zuklappen).
struct OnboardingPage<Content: View, Actions: View>: View {
    var scrollTarget: AnyHashable? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) { content }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 540)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { _, _ in reveal(proxy) }
                .onChange(of: scrollTarget) { _, _ in reveal(proxy) }
            }
            VStack(spacing: 10) { actions }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
                .background(theme.background)
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }
        // Nach dem Layout der neuen Größe (Tastatur, Klappen) scrollen, sonst zählt noch die alte Höhe
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(scrollTarget, anchor: .bottom) }
        }
    }
}

/// Große Überschrift mit Text darunter (Dynamic Type)
struct OnboardingTitle: View {
    var title: LocalizedStringKey
    var text: LocalizedStringKey?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440)
    }
}

/// Breiter, runder Knopf der Einführung
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: kind == .plain ? 36 : 50)
            .padding(.horizontal, 16)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.surfaceBorder)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.sendButtonIcon
        case .secondary: theme.textPrimary
        case .plain: theme.textSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: theme.sendButton
        case .secondary: theme.surfaceRaised
        case .plain: .clear
        }
    }
}

/// Karte mit Symbol, Titel und Text (Anleitung, Hinweise, Fehler)
struct OnboardingInfoCard<Accessory: View>: View {
    var icon: String
    var tint: Color?
    var title: LocalizedStringKey
    var text: LocalizedStringKey?
    @ViewBuilder var accessory: Accessory
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(tint ?? theme.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                if let text {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(theme, radius: 20)
        .accessibilityElement(children: .combine)
    }
}

extension OnboardingInfoCard where Accessory == EmptyView {
    init(icon: String, tint: Color? = nil, title: LocalizedStringKey, text: LocalizedStringKey? = nil) {
        self.init(icon: icon, tint: tint, title: title, text: text) { EmptyView() }
    }
}

/// Nummerierte Zeile (Anleitungen)
struct OnboardingNumberedRow: View {
    var number: Int
    var text: LocalizedStringKey
    var done = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle().fill(done ? theme.success : theme.sendButton)
                if done {
                    Image(systemName: "checkmark").font(.system(.caption, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(theme.sendButtonIcon)
                }
            }
            .frame(width: 28, height: 28)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// „Erweitert: Manuell verbinden“ (Adresse + Token) und der Demo-Knopf. Steht direkt auf dem ersten Bildschirm:
/// Apples Prüfer verbinden sich so mit dem Demo-Server (docs/demo-server.md).
struct OnboardingAlternatives: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showManual = ProcessInfo.processInfo.arguments.contains("-manualconnect")

    var body: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.snappy) { showManual.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Erweitert: Manuell verbinden")
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .rotationEffect(.degrees(showManual ? 180 : 0))
                }
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Mit Server-Adresse und Token verbinden, ohne Konto")

            if showManual {
                ManualConnectForm()
                    .padding(18)
                    .themedCard(theme, radius: 20)
                    .frame(maxWidth: 440)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                Task { await store.connect(with: ConnectionSettings(serverURL: ConnectionSettings.mockURL, token: ""), persist: true) }
            } label: {
                Label("Erst mal ohne Server ausprobieren", systemImage: "sparkles")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}
