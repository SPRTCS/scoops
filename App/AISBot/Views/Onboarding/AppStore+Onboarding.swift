import Foundation

extension AppStore {
    /// Soll statt der App die Einführung erscheinen (und in welcher Form)?
    ///
    /// - Einführung läuft: geführt. Ausnahme: Nur geteilte Scoops, kein eigener Server (z. B. Gast, der vor dieser
    ///   Version schon eingeladen war) – dann wie bisher die App mit „Mit mir geteilt“.
    /// - Einführung fertig, aber kein Server verbunden: nur Anmelden und Server (wie der frühere Startbildschirm).
    var onboardingPresentation: OnboardingFlowView.Mode? {
        let unconfigured = phase == .unconfigured
        if onboarding.isActive {
            if unconfigured, !sharedBots.isEmpty, !onboarding.replay { return nil }
            return .guided
        }
        return unconfigured && sharedBots.isEmpty ? .connectOnly : nil
    }

    /// Kopplungslink `aisscoops://link?code=…` (QR-Code im Assistenten von AIS Scoops Server): öffnet den Code-Schritt
    /// mit vorausgefülltem Code. Ist schon ein Server verbunden, das Blatt „Server hinzufügen“. Gekoppelt wird erst
    /// nach Tippen auf „Koppeln“.
    func openPairingLink(_ url: URL) -> Bool {
        guard let raw = OnboardingLogic.pairingCode(from: url) else { return false }
        let code = PairingCodeField.format(raw)
        if let mode = onboardingPresentation, phase == .unconfigured {
            onboarding.pairing = nil
            onboarding.pendingCode = code
            onboarding.serverStage = .code
            if mode == .guided, onboarding.step < .server {
                onboarding.go(to: account.isSignedIn ? .server : .signIn)
            }
        } else {
            onboarding.linkSheetCode = code
        }
        return true
    }

    /// Verbindung steht (Wechsel auf `online`): Einführung bis zum Server-Schritt weiterführen. Frischer Server (nur Pip)
    /// → erster Scoop; Bestandsnutzer mit eigenen Scoops → Einführung endet.
    func onboardingDidConnect() {
        guard onboarding.isActive, onboarding.step <= .server else { return }
        // Der in der Einführung erstellte Scoop zählt nicht (Zurück zum Server-Schritt, Neuverbinden)
        let own = bots.filter { $0.id != onboarding.firstBotID }
        onboarding.connected(freshServer: OnboardingLogic.isFreshServer(bots: own, groupCount: groups.count))
    }
}
