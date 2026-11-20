import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Entitäten für Widgets, Controls, Kurzbefehle und Siri (docs/system.md)
//
// Quelle ist das Verzeichnis in der App-Gruppe (`SystemDirectory`), das die App bei jeder Änderung schreibt.
// Die Typen liegen in `Shared`, damit App und Widget-Erweiterung dieselben benutzen.

/// Bild einer Entität: das vorgerenderte Chat-Bild aus der App-Gruppe (`SystemAvatars`, sonst das der Mitteilungen),
/// zur Not ein Symbol.
private nonisolated func entityImage(chat: SystemChat) -> DisplayRepresentation.Image {
    let url = SystemAvatars.imageURL(chatID: chat.id) ?? (chat.isGroup ? nil : NotificationAvatars.imageURL(forBotID: chat.id))
    if let url, let data = try? Data(contentsOf: url) {
        return DisplayRepresentation.Image(data: data)
    }
    return DisplayRepresentation.Image(systemName: chat.isGroup ? "person.3.fill" : "face.smiling")
}

/// Ein eigener Scoop: Auswahl in Widgets und Controls (dort seit jeher gespeichert, der Typname bleibt deshalb).
/// Kurzbefehle, Siri und Spotlight benutzen `ChatEntity`, die auch Gruppen und geteilte Scoops kennt.
nonisolated struct ScoopEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scoop", numericFormat: "\(placeholder: .int) Scoops")
    static let defaultQuery = ScoopQuery()

    var id: String
    var name: String
    var label: String?
    /// Server, zu dem der Scoop gehört (leer = unbekannt)
    var serverID: String = ""

    var displayRepresentation: DisplayRepresentation {
        guard let chat = SystemDirectory.current().chat(id) else {
            if let label, !label.isEmpty { return DisplayRepresentation(title: "\(name)", subtitle: "\(label)") }
            return DisplayRepresentation(title: "\(name)")
        }
        if let subtitle = chat.subtitle {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: entityImage(chat: chat))
        }
        return DisplayRepresentation(title: "\(name)", image: entityImage(chat: chat))
    }

    init(_ chat: SystemChat) {
        id = chat.id; name = chat.name; label = chat.label; serverID = chat.serverID
    }

    init(_ bot: WidgetBot) {
        id = bot.id; name = bot.name; label = bot.label
    }
}

nonisolated struct ScoopQuery: EntityStringQuery {
    func entities(for identifiers: [ScoopEntity.ID]) async throws -> [ScoopEntity] {
        let directory = SystemDirectory.current()
        return identifiers.compactMap { id in directory.chat(id).flatMap { $0.isGroup ? nil : ScoopEntity($0) } }
    }

    func entities(matching string: String) async throws -> [ScoopEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.scoops)
            .filter { $0.name.localizedCaseInsensitiveContains(string) || ($0.label ?? "").localizedCaseInsensitiveContains(string) }
            .map(ScoopEntity.init)
    }

    /// Nur eigene Scoops: Widgets zeigen ausschließlich Scoops des verbundenen Servers.
    func suggestedEntities() async throws -> [ScoopEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.scoops.filter { !$0.shared }).map(ScoopEntity.init)
    }

    /// Standard: der Haupt-Scoop
    func defaultResult() async -> ScoopEntity? {
        SystemDirectory.current().primaryScoop.map(ScoopEntity.init)
    }
}

/// Ein Chat: Scoop (eigener oder mit mir geteilter) oder Gruppe. Die Entität für Kurzbefehle, Siri und Spotlight.
/// Welche Chats ein Kurzbefehl anbietet, legt sein `optionsProvider` fest (z. B. Aufgaben nur für eigene Scoops).
nonisolated struct ChatEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat", numericFormat: "\(placeholder: .int) Chats")
    static let defaultQuery = ChatQuery()

    var id: String
    var name: String
    var serverID: String = ""

    var isGroup: Bool { ChatGroup.isGroupID(id) }

    var displayRepresentation: DisplayRepresentation {
        guard let chat = SystemDirectory.current().chat(id) else { return DisplayRepresentation(title: "\(name)") }
        if let subtitle = chat.subtitle {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: entityImage(chat: chat))
        }
        return DisplayRepresentation(title: "\(name)", image: entityImage(chat: chat))
    }

    init(_ chat: SystemChat) {
        id = chat.id; name = chat.name; serverID = chat.serverID
    }

    /// Auswahl eines Controls bzw. Widgets als Chat
    init(_ scoop: ScoopEntity) {
        id = scoop.id; name = scoop.name; serverID = scoop.serverID
    }
}

/// Auswahl: einzelne Scoops, denen ich schreiben darf (eigene und geteilte), ohne Gruppen.
nonisolated struct WritableScoopOptions: DynamicOptionsProvider {
    func results() async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.scoops.filter(\.canWrite)).map(ChatEntity.init)
    }
}

/// Auswahl: Scoops und Gruppen, denen ich schreiben darf.
nonisolated struct WritableChatOptions: DynamicOptionsProvider {
    func results() async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.chats.filter(\.canWrite)).map(ChatEntity.init)
    }
}

/// Auswahl: nur eigene Scoops (Aufgaben-Board gibt es nur auf dem eigenen Server).
nonisolated struct OwnScoopOptions: DynamicOptionsProvider {
    func results() async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.scoops.filter { !$0.shared }).map(ChatEntity.init)
    }
}

nonisolated struct ChatQuery: EntityStringQuery {
    func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return identifiers.compactMap { directory.chat($0).map(ChatEntity.init) }
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.chats)
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(ChatEntity.init)
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        let directory = SystemDirectory.current()
        return directory.ordered(directory.chats).map(ChatEntity.init)
    }

    func defaultResult() async -> ChatEntity? {
        SystemDirectory.current().primaryScoop.map(ChatEntity.init)
    }
}
