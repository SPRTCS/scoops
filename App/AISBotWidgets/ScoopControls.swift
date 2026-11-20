import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Controls für Kontrollzentrum, Sperrbildschirm und Action-Button (docs/system.md)
//
// Alle drei öffnen die App über einen Intent aus `Shared/Intents/OpenIntents.swift`. Vom Sperrbildschirm aus
// verlangt das System dafür zuerst das Entsperren. Die Controls selbst zeigen nichts Vertrauliches: nur den
// Namen des gewählten Scoops.

/// Einstellung „Scoop“ der Controls „Sprechmodus“ und „Neue Nachricht“. Ohne Auswahl gilt der Haupt-Scoop.
struct ScoopControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Scoop wählen"
    static let description = IntentDescription("Ohne Auswahl gilt dein Haupt-Scoop.")

    @Parameter(title: "Scoop")
    var scoop: ScoopEntity?

    init() {}
}

/// Einstellung „Chat“ des Controls „Scoop öffnen“ (Scoop oder Gruppe).
struct ChatControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Chat wählen"
    static let description = IntentDescription("Scoop oder Gruppe. Ohne Auswahl gilt dein Haupt-Scoop.")

    @Parameter(title: "Chat")
    var chat: ChatEntity?

    init() {}
}

/// „Sprechmodus“: öffnet die App direkt im Sprechmodus.
struct VoiceModeControl: ControlWidget {
    static let kind = "com.ais.aisbot.control.voice"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: ScoopControlConfiguration.self) { configuration in
            ControlWidgetButton(action: StartVoiceModeIntent(scoop: configuration.scoop.map(ChatEntity.init))) {
                Label {
                    Text("Sprechmodus")
                    if let name = configuration.scoop?.name { Text(name) }
                } icon: {
                    Image(systemName: "waveform")
                }
            }
        }
        .displayName("Sprechmodus")
        .description("Sprich direkt mit einem Scoop. Ohne Auswahl mit deinem Haupt-Scoop.")
    }
}

/// „Scoop öffnen“: öffnet den Chat eines Scoops oder einer Gruppe.
struct OpenChatControl: ControlWidget {
    static let kind = "com.ais.aisbot.control.open"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: ChatControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenChatIntent(chat: configuration.chat)) {
                Label {
                    Text(configuration.chat?.name ?? String(localized: "Scoop öffnen"))
                    if configuration.chat != nil { Text("Chat öffnen") }
                } icon: {
                    Image(systemName: configuration.chat?.isGroup == true ? "bubble.left.and.bubble.right.fill" : "bubble.left.fill")
                }
            }
        }
        .displayName("Scoop öffnen")
        .description("Öffnet den Chat eines Scoops oder einer Gruppe.")
    }
}

/// „Neue Nachricht“: öffnet den Chat mit aktivem Eingabefeld.
struct NewMessageControl: ControlWidget {
    static let kind = "com.ais.aisbot.control.compose"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: ScoopControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenChatIntent(chat: configuration.scoop.map(ChatEntity.init), compose: true)) {
                Label {
                    Text("Neue Nachricht")
                    if let name = configuration.scoop?.name { Text(name) }
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .displayName("Neue Nachricht")
        .description("Schreib einem Scoop sofort. Ohne Auswahl deinem Haupt-Scoop.")
    }
}
