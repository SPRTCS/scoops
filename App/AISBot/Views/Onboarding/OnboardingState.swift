import Foundation
import Observation

/// Feste Adressen rund um die Einführung.
enum ScoopsLinks {
    /// Download der Mac-App „AIS Scoops Server“.
    /// TODO: Endgültige Download-Seite eintragen, sobald sie online ist (bisher gab es keine Adresse in Code oder Docs).
    static let serverDownload = URL(string: "https://ais-con.com/scoops")!
    /// Kurzform für Texte, z. B. „ais-con.com/scoops“
    static var serverDownloadDisplay: String {
        (serverDownload.host() ?? "") + serverDownload.path()
    }
}

/// Stand der Einführung (docs/onboarding.md): aktueller Schritt und alles, was für die Wiederaufnahme nach einem
/// Neustart nötig ist. Liegt lokal in UserDefaults und enthält keine Geheimnisse (keine Tokens, keine Codes).
///
/// Bestandsnutzer (gespeicherte Verbindung beim ersten Start dieser Version) bekommen sofort `done` und sehen die
/// Einführung nie. Im Demo-Modus (`-mock`) gilt `done`, außer mit `-onboarding <schritt>`; dann liegt der Stand in
/// einer eigenen Domain, damit Tests nie den echten Stand verändern.
@Observable
final class OnboardingState {
    /// Gespeicherter Schritt
    private(set) var step: OnboardingStep
    /// Seite der Begrüßung (0…2)
    var welcomePage: Int { didSet { save() } }
    /// „Einführung erneut ansehen“ (Einstellungen): alle Schritte, auch wenn schon alles eingerichtet ist
    private(set) var replay: Bool
    /// Der in der Einführung erstellte Scoop
    var firstBotID: String? { didSet { save() } }
    /// Erste Antwort gefeiert
    var celebrated: Bool { didSet { save() } }
    /// Tipps am Ende zeigen (Einstellungen → Einführung)
    var showsTips: Bool { didSet { save() } }
    /// Eingelöster Kopplungscode: auf diesen Server warten (übersteht einen Neustart)
    var pairing: Pairing? { didSet { save() } }
    /// Entwurf des ersten Scoops (übersteht einen Neustart)
    var draft: ScoopDraft? { didSet { saveDraftSoon() } }
    /// Unterzustand des Server-Schritts (Anleitung, Code, …), nur für die laufende Sitzung
    var serverStage: OnboardingServerStage?
    /// Kopplungscode aus einem Link (`aisscoops://link?code=…`), wird im Code-Schritt eingetragen. Nur im Speicher.
    var pendingCode: String?
    /// Kopplungslink, während schon ein Server verbunden ist: Blatt „Server hinzufügen“ mit diesem Code
    var linkSheetCode: String?
    /// Nur Startargumente: Fehlerzustand im Server-Schritt vorgeben (`expired`, `unreachable`)
    @ObservationIgnored var demoServerError: String?
    /// Nur Startargumente: Seite im Scoop-Schritt (`name`, `look`, `purpose`)
    @ObservationIgnored var demoScoopPage: String?
    /// Nur Startargumente: erste Antwort sofort zeigen (`message:reply`)
    @ObservationIgnored var demoReply = false

    struct Pairing: Codable, Equatable {
        var serverID: String
        var name: String?
        var claimedAt: Date
    }

    /// Entwurf aus der geführten Erstellung
    struct ScoopDraft: Codable, Equatable {
        var name: String = ""
        var mascot: Mascot
        /// Gewählter Zweck (`OnboardingPurpose.id`), nil = noch keiner
        var purpose: String?
        var character: String = ""
        /// Seite im Scoop-Schritt (0 Name, 1 Aussehen, 2 Zweck)
        var page: Int = 0
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    private enum Key {
        static let step = "onboarding.step"
        static let page = "onboarding.welcomePage"
        static let replay = "onboarding.replay"
        static let firstBot = "onboarding.firstBotID"
        static let celebrated = "onboarding.celebrated"
        static let tips = "onboarding.showTips"
        static let pairing = "onboarding.pairing"
        static let draft = "onboarding.draft"
    }

    /// Domain für Tests im Demo-Modus
    static let demoSuite = "com.ais.aisbot.onboarding-demo"

    /// Schritt, mit dem der Demo-Modus startet (für AppStore/AccountStore, bevor es den Zustand gibt)
    static func demoLaunchStep(_ arguments: [String]) -> OnboardingStep? {
        guard arguments.contains("-mock"), let request = OnboardingLogic.launchRequest(arguments) else { return nil }
        if let step = request.step { return step }
        let stored = UserDefaults(suiteName: demoSuite)?.string(forKey: Key.step)
        return stored.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments, hasStoredConnection: Bool, isSignedIn: Bool) {
        let mock = arguments.contains("-mock")
        let request = OnboardingLogic.launchRequest(arguments)
        if mock {
            defaults = request == nil ? nil : UserDefaults(suiteName: Self.demoSuite)
        } else {
            defaults = .standard
        }
        let d = defaults
        if let request, let forced = request.step {
            // Startargument: Stand zurücksetzen und beim gewünschten Schritt beginnen
            for key in [Key.step, Key.page, Key.replay, Key.firstBot, Key.celebrated, Key.pairing, Key.draft] {
                d?.removeObject(forKey: key)
            }
            step = forced
        } else if let raw = d?.string(forKey: Key.step), let stored = OnboardingStep(rawValue: raw) {
            step = stored
        } else if mock && request == nil {
            step = .done
        } else {
            step = OnboardingLogic.initialStep(hasStoredConnection: hasStoredConnection, isSignedIn: isSignedIn)
        }
        welcomePage = d?.integer(forKey: Key.page) ?? 0
        replay = d?.bool(forKey: Key.replay) ?? false
        firstBotID = d?.string(forKey: Key.firstBot)
        celebrated = d?.bool(forKey: Key.celebrated) ?? false
        showsTips = (d?.object(forKey: Key.tips) as? Bool) ?? true
        pairing = d?.data(forKey: Key.pairing).flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) }
        draft = d?.data(forKey: Key.draft).flatMap { try? JSONDecoder().decode(ScoopDraft.self, from: $0) }

        if let request, request.step != nil, let detail = request.detail {
            applyLaunchDetail(detail)
        }
        loading = false
        save()
    }

    /// `-onboarding <schritt>:<detail>`: Unterseiten und Zustände für Screenshots
    private func applyLaunchDetail(_ detail: String) {
        switch (step, detail) {
        case (.welcome, _): welcomePage = max(0, min(2, (Int(detail) ?? 1) - 1))
        case (.server, "choose"), (.server, "guide"), (.server, "code"), (.server, "waiting"):
            serverStage = OnboardingServerStage(rawValue: detail)
        case (.server, "expired"):
            serverStage = .code
            demoServerError = detail
        case (.server, "unreachable"):
            demoServerError = detail
        case (.scoop, _): demoScoopPage = detail
        case (.message, "reply"): demoReply = true
        default: break
        }
    }

    var isActive: Bool { step != .done }

    // MARK: Schritte

    func go(to newStep: OnboardingStep) {
        guard newStep != step else { return }
        step = newStep
        if newStep == .done { finish() } else { save() }
    }

    /// Weiter zum nächsten Schritt (Tipps nur, wenn eingeschaltet)
    func advance() {
        var next = step.next
        if next == .tips && !showsTips { next = .done }
        go(to: next)
    }

    /// Ein Schritt zurück (die Begrüßung blättert zuerst ihre Seiten zurück)
    func back() {
        if step == .welcome {
            if welcomePage > 0 { welcomePage -= 1 }
            return
        }
        if let previous = step.previous { go(to: previous) }
    }

    /// Verbindung steht: weiter je nach Server (frisch → erster Scoop, Bestandsnutzer → fertig)
    func connected(freshServer: Bool) {
        pairing = nil
        serverStage = nil
        let next = OnboardingLogic.stepAfterConnecting(current: step, freshServer: freshServer, replay: replay)
        go(to: next)
    }

    /// „Einführung erneut ansehen“
    func startReplay() {
        replay = true
        welcomePage = 0
        firstBotID = nil
        celebrated = false
        draft = nil
        pairing = nil
        serverStage = nil
        step = .welcome
        save()
    }

    /// Einführung beenden (auch „Später“)
    func finish() {
        step = .done
        replay = false
        pairing = nil
        draft = nil
        serverStage = nil
        save()
    }

    // MARK: Speichern

    private func save() {
        guard !loading, let d = defaults else { return }
        d.set(step.rawValue, forKey: Key.step)
        d.set(welcomePage, forKey: Key.page)
        d.set(replay, forKey: Key.replay)
        d.set(firstBotID, forKey: Key.firstBot)
        d.set(celebrated, forKey: Key.celebrated)
        d.set(showsTips, forKey: Key.tips)
        if let pairing, let data = try? JSONEncoder().encode(pairing) {
            d.set(data, forKey: Key.pairing)
        } else {
            d.removeObject(forKey: Key.pairing)
        }
        saveDraft()
    }

    private func saveDraftSoon() {
        guard !loading else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveDraft()
        }
    }

    private func saveDraft() {
        guard !loading, let d = defaults else { return }
        if let draft, let data = try? JSONEncoder().encode(draft) {
            d.set(data, forKey: Key.draft)
        } else {
            d.removeObject(forKey: Key.draft)
        }
    }
}
