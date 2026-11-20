import Foundation

/// Tiefe Links der App (Schema `aisbot://`), wie sie Widgets, Controls, Kurzbefehle, Spotlight und das
/// Teilen-Menü benutzen. Kopplung (`aisbot://pair`) und Nutzung (`aisbot://usage`) wertet weiter `AISBotApp` aus.
///
/// | Link | Wirkung |
/// |---|---|
/// | `aisbot://chat/<id>` (auch `bot/…`, `group/…`) | Chat öffnen |
/// | `aisbot://chat/<id>?compose=1`, `aisbot://compose[/<id>]` | Chat öffnen, Eingabefeld aktiv („Neue Nachricht“) |
/// | `aisbot://voice[/<id>]` | Sprechmodus, ohne ID mit dem Haupt-Scoop |
/// | `aisbot://today` | Seite „Heute“ |
/// | `aisbot://outbox` | geteilte Inhalte aus der Ablage jetzt senden |
///
/// `?server=<id>` nennt den Server, zu dem der Chat gehört (ein Scoop gehört zu genau einem Server).
nonisolated enum DeepLink: Hashable, Sendable {
    case chat(id: String?, server: String?, compose: Bool)
    case voice(id: String?, server: String?)
    case today
    case outbox

    static let scheme = "aisbot"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let id = url.pathComponents.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let server = value("server")
        switch host {
        case "bot", "group", "chat":
            guard let id else { return nil }
            self = .chat(id: id, server: server, compose: ["1", "true"].contains(value("compose") ?? ""))
        case "compose":
            self = .chat(id: id, server: server, compose: true)
        case "voice":
            self = .voice(id: id, server: server)
        case "today":
            self = .today
        case "outbox":
            self = .outbox
        default:
            return nil
        }
    }

    var url: URL {
        var comps = URLComponents()
        comps.scheme = Self.scheme
        var query: [URLQueryItem] = []
        switch self {
        case .chat(let id, let server, let compose):
            if let id {
                comps.host = "chat"
                comps.path = "/" + id
                if compose { query.append(URLQueryItem(name: "compose", value: "1")) }
            } else {
                comps.host = "compose"
            }
            if let server, !server.isEmpty { query.append(URLQueryItem(name: "server", value: server)) }
        case .voice(let id, let server):
            comps.host = "voice"
            if let id { comps.path = "/" + id }
            if let server, !server.isEmpty { query.append(URLQueryItem(name: "server", value: server)) }
        case .today:
            comps.host = "today"
        case .outbox:
            comps.host = "outbox"
        }
        if !query.isEmpty { comps.queryItems = query }
        return comps.url ?? URL(string: "aisbot://chat")!
    }

    /// Link auf einen Chat aus dem Verzeichnis (mit Server)
    static func chat(_ chat: SystemChat, compose: Bool = false) -> DeepLink {
        .chat(id: chat.id, server: chat.serverID.isEmpty ? nil : chat.serverID, compose: compose)
    }
}
