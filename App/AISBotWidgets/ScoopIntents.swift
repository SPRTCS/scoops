import AppIntents
import WidgetKit

// `ScoopEntity` und `ScoopQuery` liegen in `Shared/Intents/ScoopEntities.swift` (gemeinsam mit Kurzbefehlen und Controls).
// In der Widget-Erweiterung bietet die Auswahl nur eigene Scoops an: genau die, die der Widget-Schnappschuss kennt.

struct SelectScoopIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Scoop wählen"
    static let description = IntentDescription("Zeigt einen Scoop mit Status und letzter Nachricht.")

    @Parameter(title: "Scoop")
    var scoop: ScoopEntity?

    init() {}
}

struct SelectScoopsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Scoops wählen"
    static let description = IntentDescription("Direktzugriff auf mehrere Scoops. Ohne Auswahl: angepinnte zuerst, dann zuletzt aktive.")

    @Parameter(title: "Scoops", size: [.systemMedium: 4, .systemLarge: 8])
    var scoops: [ScoopEntity]?

    init() {}
}
