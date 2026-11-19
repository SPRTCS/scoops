import AppIntents
import WidgetKit

/// Ein Scoop als auswählbare Entität (Daten aus dem App-Group-Schnappschuss).
struct ScoopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scoop"
    static let defaultQuery = ScoopQuery()

    var id: String
    var name: String
    var label: String?

    var displayRepresentation: DisplayRepresentation {
        if let label, !label.isEmpty {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(label)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(_ bot: WidgetBot) {
        id = bot.id; name = bot.name; label = bot.label
    }
}

struct ScoopQuery: EntityQuery {
    func entities(for identifiers: [ScoopEntity.ID]) async throws -> [ScoopEntity] {
        let snap = SharedContainer.loadSnapshot() ?? .empty
        return identifiers.compactMap { id in snap.bot(id).map(ScoopEntity.init) }
    }

    func suggestedEntities() async throws -> [ScoopEntity] {
        (SharedContainer.loadSnapshot() ?? .empty).orderedBots.map(ScoopEntity.init)
    }

    func defaultResult() async -> ScoopEntity? {
        (SharedContainer.loadSnapshot() ?? .empty).orderedBots.first.map(ScoopEntity.init)
    }
}

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
