import Foundation
import Testing

/// Reine Logik der Einführung der iPhone-/Mac-App (Shared/Support/OnboardingLogic.swift). Liegt bei den Uhren-Tests,
/// weil dieses Ziel die gemeinsamen Quellen ohne App-Host kompiliert.
@Suite("Einführung")
struct OnboardingLogicTests {
    private func bot(_ id: String, label: String? = nil, last: Message? = nil) -> Bot {
        Bot(id: id, name: id, label: label, mascot: Mascot(shape: "bean", color: "#FF8FB1", eyes: "dots", accessory: "none"),
            lastMessage: last)
    }

    private func message(_ role: MessageRole, _ text: String, at seconds: Double = 0) -> Message {
        Message(id: UUID().uuidString, botId: "b", role: role, text: text, createdAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func bestandsnutzerSiehtNieDieEinfuehrung() {
        #expect(OnboardingLogic.initialStep(hasStoredConnection: true, isSignedIn: false) == .done)
        #expect(OnboardingLogic.initialStep(hasStoredConnection: true, isSignedIn: true) == .done)
    }

    @Test func neuInstalliertMitKontoStartetBeimServer() {
        #expect(OnboardingLogic.initialStep(hasStoredConnection: false, isSignedIn: true) == .server)
        #expect(OnboardingLogic.initialStep(hasStoredConnection: false, isSignedIn: false) == .welcome)
    }

    @Test func frischerServerNurMitPip() {
        let pip = bot("b_pip", label: "Start", last: message(.bot, "Hallo! Ich bin **Pip**, dein erster Scoop. 🍦"))
        #expect(OnboardingLogic.isFreshServer(bots: [], groupCount: 0))
        #expect(OnboardingLogic.isFreshServer(bots: [pip], groupCount: 0))
    }

    @Test func serverMitEigenenScoopsIstNichtFrisch() {
        let pip = bot("b_pip", label: "Start", last: message(.bot, "Hallo! Ich bin **Pip**, dein erster Scoop."))
        let mila = bot("b_mila", label: "Assistenz")
        #expect(!OnboardingLogic.isFreshServer(bots: [pip, mila], groupCount: 0))
        #expect(!OnboardingLogic.isFreshServer(bots: [mila], groupCount: 0))
        #expect(!OnboardingLogic.isFreshServer(bots: [pip], groupCount: 1))
        // Mit Pip schon geschrieben: letzte Nachricht ist eine andere Antwort
        let used = bot("b_pip", label: "Start", last: message(.bot, "Gern, hier sind drei Rezepte …"))
        #expect(!OnboardingLogic.isFreshServer(bots: [used], groupCount: 0))
    }

    @Test func frischerServerErkenntBegruessungAmMerkmal() {
        // Neuere Server: `meta.welcome` an der Begrüßung, Text und Label in der Sprache der App
        var hi = message(.bot, "Hi! I'm **Pip**, your first Scoop. 🍦")
        hi.meta.welcome = true
        #expect(OnboardingLogic.isFreshServer(bots: [bot("b_pip", label: "Starter", last: hi)], groupCount: 0))
        #expect(OnboardingLogic.isFreshServer(bots: [bot("b_pip", label: "Start", last: hi)], groupCount: 0))
        #expect(!OnboardingLogic.isFreshServer(bots: [bot("b_pip", label: "Start", last: hi)], groupCount: 1))
        // Mit Pip schon geschrieben: neue Antwort ohne Merkmal, auch wenn sie zufällig so beginnt
        let used = bot("b_pip", label: "Start", last: message(.bot, "Hi! I'm **Pip** and here are three recipes …"))
        #expect(!OnboardingLogic.isFreshServer(bots: [used], groupCount: 0))
        var notWelcome = message(.bot, "Hallo! Ich bin **Pip**, schön dich zu sehen.")
        notWelcome.meta.welcome = false
        #expect(!OnboardingLogic.isFreshServer(bots: [bot("b_pip", label: "Start", last: notWelcome)], groupCount: 0))
    }

    @Test func nachDemVerbinden() {
        #expect(OnboardingLogic.stepAfterConnecting(current: .server, freshServer: true, replay: false) == .scoop)
        #expect(OnboardingLogic.stepAfterConnecting(current: .welcome, freshServer: true, replay: false) == .scoop)
        #expect(OnboardingLogic.stepAfterConnecting(current: .server, freshServer: false, replay: false) == .done)
        // Erneut ansehen: Bestandsserver führt trotzdem weiter, aber erst aus dem Server-Schritt
        #expect(OnboardingLogic.stepAfterConnecting(current: .server, freshServer: false, replay: true) == .scoop)
        #expect(OnboardingLogic.stepAfterConnecting(current: .welcome, freshServer: false, replay: true) == .welcome)
        // Spätere Schritte bleiben (Neuverbinden mitten im Scoop-Schritt)
        #expect(OnboardingLogic.stepAfterConnecting(current: .message, freshServer: false, replay: false) == .message)
    }

    @Test func ersteAntwortErstNachEigenerNachricht() {
        let greeting = message(.bot, "Hi, ich bin Kiwi!", at: 1)
        #expect(OnboardingLogic.firstReply(in: [greeting]) == nil)
        let mine = message(.user, "Hallo", at: 2)
        let status = message(.status, "", at: 3)
        #expect(OnboardingLogic.firstReply(in: [greeting, mine, status]) == nil)
        let reply = message(.bot, "Hallo zurück!", at: 4)
        #expect(OnboardingLogic.firstReply(in: [greeting, mine, status, reply])?.id == reply.id)
        // Lauf arbeitet noch (verspätete Begrüßung): noch nicht feiern
        var running = message(.status, "", at: 3)
        running.meta.state = "running"
        let lateGreeting = message(.bot, "Hi, ich bin Kiwi!", at: 3)
        #expect(OnboardingLogic.firstReply(in: [mine, lateGreeting, running]) == nil)
    }

    @Test func startargument() {
        #expect(OnboardingLogic.launchRequest(["app"]) == nil)
        #expect(OnboardingLogic.launchRequest(["app", "-onboarding"])?.step == .welcome)
        let server = OnboardingLogic.launchRequest(["app", "-onboarding", "server:code", "-mock"])
        #expect(server?.step == .server)
        #expect(server?.detail == "code")
        #expect(OnboardingLogic.launchRequest(["app", "-onboarding", "signin"])?.step == .signIn)
        let resume = OnboardingLogic.launchRequest(["app", "-onboarding", "resume"])
        #expect(resume != nil && resume?.step == nil)
        #expect(OnboardingLogic.launchRequest(["app", "-onboarding", "-mock"])?.step == .welcome)
    }

    @Test func schritteUndNummern() {
        #expect(OnboardingStep.welcome.number == 1)
        #expect(OnboardingStep.message.number == 5)
        #expect(OnboardingStep.tips.number == nil)
        #expect(OnboardingStep.signIn < .server)
        #expect(OnboardingStep.message.next == .tips)
        #expect(OnboardingStep.done.next == .done)
        #expect(OnboardingStep.welcome.previous == nil)
    }
}

@Suite("Einführung: Kopplungslink")
struct OnboardingPairingLinkTests {
    @Test func liestCode() {
        #expect(OnboardingLogic.pairingCode(from: URL(string: "aisscoops://link?code=K7QX-29PL")!) == "K7QX29PL")
        #expect(OnboardingLogic.pairingCode(from: URL(string: "aisbot://link?code=k7qx29pl")!) == "K7QX29PL")
    }

    @Test func ignoriertAnderes() {
        #expect(OnboardingLogic.pairingCode(from: URL(string: "aisscoops://link?code=ZUKURZ")!) == nil)
        #expect(OnboardingLogic.pairingCode(from: URL(string: "aisscoops://invite/ABCD2345")!) == nil)
        #expect(OnboardingLogic.pairingCode(from: URL(string: "https://example.com/link?code=K7QX29PL")!) == nil)
        #expect(OnboardingLogic.pairingCode(from: URL(string: "aisscoops://link")!) == nil)
    }
}
