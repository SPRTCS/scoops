import AppIntents
import Foundation

// MARK: - Intents, die die App öffnen (Kurzbefehle, Siri, Controls, Action-Button)
//
// Sie liegen in `Shared`, weil Controls ihre Aktion in App und Widget-Erweiterung kennen müssen. Ausgeführt
// werden sie in der App: Der Link geht an `SystemBridge`, dort übernimmt `DeepLinkRouter`. Das Öffnen der App
// verlangt vom Sperrbildschirm aus das Entsperren; darum kümmert sich das System.

/// Öffnet den Chat eines Scoops oder einer Gruppe.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Chat öffnen"
    static let description = IntentDescription(
        "Öffnet AIS Scoops im Chat eines Scoops oder einer Gruppe. Ohne Auswahl öffnet sich dein Haupt-Scoop.",
        categoryName: "Scoops")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Chat", description: "Scoop oder Gruppe. Ohne Auswahl: dein Haupt-Scoop.")
    var chat: ChatEntity?

    @Parameter(title: "Neue Nachricht", description: "Eingabefeld gleich aktivieren.", default: false)
    var compose: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$chat) öffnen") {
            \.$compose
        }
    }

    init() {}

    init(chat: ChatEntity?, compose: Bool = false) {
        self.chat = chat
        self.compose = compose
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let server = chat.flatMap { $0.serverID.isEmpty ? nil : $0.serverID }
        SystemBridge.shared.open(.chat(id: chat?.id, server: server, compose: compose))
        return .result()
    }
}

/// Öffnet die App direkt im Sprechmodus.
struct StartVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Sprechmodus starten"
    static let description = IntentDescription(
        "Öffnet AIS Scoops im Sprechmodus. Ohne Auswahl sprichst du mit deinem Haupt-Scoop.",
        categoryName: "Scoops")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Scoop", description: "Ohne Auswahl: dein Haupt-Scoop.", optionsProvider: WritableScoopOptions())
    var scoop: ChatEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Sprechmodus mit \(\.$scoop) starten")
    }

    init() {}

    init(scoop: ChatEntity?) {
        self.scoop = scoop
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let server = scoop.flatMap { $0.serverID.isEmpty ? nil : $0.serverID }
        SystemBridge.shared.open(.voice(id: scoop?.id, server: server))
        return .result()
    }
}

/// Tippen auf einen Scoop oder eine Gruppe in der Systemsuche: öffnet den Chat. Erscheint nicht als eigene Aktion
/// in der Kurzbefehle-App (dafür gibt es „Chat öffnen“).
struct OpenChatEntityIntent: OpenIntent {
    static let title: LocalizedStringResource = "Chat öffnen"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Chat")
    var target: ChatEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemBridge.shared.open(.chat(id: target.id, server: target.serverID.isEmpty ? nil : target.serverID, compose: false))
        return .result()
    }
}
