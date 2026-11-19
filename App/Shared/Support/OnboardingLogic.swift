import Foundation

/// Schritte der Einführung (docs/onboarding.md). Die Reihenfolge der Fälle ist die Reihenfolge im Ablauf.
nonisolated enum OnboardingStep: String, CaseIterable, Codable, Comparable, Sendable {
    /// 2–3 Seiten mit den Maskottchen: was Scoops sind (überspringbar)
    case welcome
    /// Mit Apple anmelden
    case signIn = "signin"
    /// Server wählen bzw. koppeln (Kopplungscode) und verbinden
    case server
    /// Ersten eigenen Scoop gestalten
    case scoop
    /// Erste Nachricht, erste Antwort feiern
    case message
    /// Kurze, einmalige Tipps (zählen nicht als Schritt)
    case tips
    /// Einführung abgeschlossen (oder nie nötig: Bestandsnutzer)
    case done

    /// Schritte mit Fortschrittsanzeige „Schritt x von y“
    static let counted: [OnboardingStep] = [.welcome, .signIn, .server, .scoop, .message]

    /// 1-basierte Nummer in „Schritt x von y“, `nil` für Tipps und Fertig
    var number: Int? { Self.counted.firstIndex(of: self).map { $0 + 1 } }

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool {
        let all = allCases
        return all.firstIndex(of: a)! < all.firstIndex(of: b)!
    }

    /// Schritt vor/nach diesem (ohne `done`)
    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }

    var next: OnboardingStep {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return .done }
        return all[i + 1]
    }
}

/// Unterzustände des Server-Schritts (nur für Startargumente und Wiederaufnahme)
nonisolated enum OnboardingServerStage: String, Codable, Sendable {
    /// Liste „Deine Server“ (wenn es schon welche gibt)
    case choose
    /// Anleitung: Mac, „AIS Scoops Server“ laden, Assistent zeigt den Kopplungscode
    case guide
    /// Kopplungscode eingeben
    case code
    /// Code eingelöst, warte darauf, dass der Server online ist und antwortet
    case waiting
}

/// Reine Entscheidungen der Einführung, ohne Oberfläche (getestet in WatchLogicTests/OnboardingLogicTests.swift).
nonisolated enum OnboardingLogic {
    /// Begrüßungstext des Start-Scoops „Pip“, den jede neue Server-Installation anlegt
    /// (`WELCOME_SCOOP`/`WELCOME_TEXT` in Server/src/aisbot/server.py).
    static let seededWelcomePrefix = "Hallo! Ich bin **"
    static let seededLabel = "Start"

    /// Erster Start mit dieser App-Version (noch kein gespeicherter Stand): Wer schon verbunden war, ist
    /// Bestandsnutzer und sieht die Einführung nie. Wer nur angemeldet ist (z. B. neu installiert, Sitzung im
    /// Schlüsselbund), überspringt Begrüßung und Anmeldung.
    static func initialStep(hasStoredConnection: Bool, isSignedIn: Bool) -> OnboardingStep {
        if hasStoredConnection { return .done }
        return isSignedIn ? .server : .welcome
    }

    /// Ist der Server frisch eingerichtet? Leer oder nur der automatisch angelegte Start-Scoop, mit dem noch niemand
    /// geschrieben hat, und keine Gruppen. Dann führt die Einführung weiter zum ersten eigenen Scoop; sonst
    /// (Bestandsnutzer mit eigenen Scoops) endet sie.
    static func isFreshServer(bots: [Bot], groupCount: Int) -> Bool {
        guard groupCount == 0 else { return false }
        if bots.isEmpty { return true }
        guard bots.count == 1, let only = bots.first else { return false }
        guard only.label == seededLabel else { return false }
        guard let last = only.lastMessage else { return true }
        return last.role == .bot && last.text.hasPrefix(seededWelcomePrefix)
    }

    /// Nächster Schritt, sobald die Verbindung zum Server steht (aus Begrüßung, Anmeldung oder Server-Schritt).
    /// `replay`: „Einführung erneut ansehen“ – dann geht es immer weiter zum ersten Scoop.
    static func stepAfterConnecting(current: OnboardingStep, freshServer: Bool, replay: Bool) -> OnboardingStep {
        guard current <= .server else { return current }
        if replay { return current == .server ? .scoop : current }
        return freshServer ? .scoop : .done
    }

    /// Erste Antwort im Einführungs-Chat: eine Scoop-Nachricht nach der ersten eigenen Nachricht, sobald kein Lauf mehr
    /// arbeitet (sonst zählte z. B. eine verspätete Begrüßung des neuen Scoops schon als Antwort).
    static func firstReply(in messages: [Message]) -> Message? {
        guard let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return nil }
        let after = messages[messages.index(after: firstUser)...]
        guard !after.contains(where: \.isRunning) else { return nil }
        return after.last { $0.role == .bot && !$0.text.isEmpty }
    }

    /// Kopplungslink `aisscoops://link?code=K7QX-29PL` (auch `aisbot://link?code=…`), z. B. aus dem QR-Code im
    /// Assistenten von AIS Scoops Server. Liefert den Code ohne Trennzeichen in Großbuchstaben, nur bei acht Zeichen.
    static func pairingCode(from url: URL) -> String? {
        guard ["aisscoops", "aisbot"].contains(url.scheme?.lowercased() ?? ""), url.host()?.lowercased() == "link",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        let code = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return code.count == 8 ? code : nil
    }

    /// Startargument `-onboarding <schritt>[:<detail>]`, z. B. `welcome`, `welcome:2`, `signin`, `server`,
    /// `server:code`, `server:waiting`, `server:expired`, `server:unreachable`, `scoop`, `scoop:look`,
    /// `message`, `message:reply`, `tips`, `done`, oder `resume` (gespeicherten Stand nehmen, nur Demo-Modus).
    static func launchRequest(_ arguments: [String]) -> (step: OnboardingStep?, detail: String?)? {
        guard let i = arguments.firstIndex(of: "-onboarding") else { return nil }
        guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return (.welcome, nil) }
        let parts = arguments[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0].lowercased()
        let detail = parts.count > 1 ? parts[1] : nil
        if name == "resume" { return (nil, detail) }
        let step = OnboardingStep(rawValue: name) ?? (name == "sign-in" ? .signIn : nil)
        return (step ?? .welcome, detail)
    }
}
