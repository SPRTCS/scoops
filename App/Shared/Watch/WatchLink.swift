import Foundation

// MARK: - Verbindung iPhone → Apple Watch (WatchConnectivity)
//
// Das iPhone kennt Server-Adressen, API-Token und die Konto-Sitzung (JWT). Es übergibt der Uhr per
// `updateApplicationContext` genau das, was sie braucht, um selbst per URLSession mit dem Server zu sprechen
// (WLAN/LTE, auch ohne iPhone in der Nähe). Die Uhr speichert diese Daten nur im Schlüsselbund. Tokens werden
// nirgends protokolliert: `description` der Typen blendet sie aus.
//
// Ist der Server von der Uhr aus nicht erreichbar (z. B. nur über Tailscale am iPhone), reicht die Uhr
// einzelne Anfragen über das iPhone weiter (`WatchLink.Kind.relay`).

/// Ein Server, den die Uhr ansprechen darf.
nonisolated struct WatchServer: Codable, Hashable, Identifiable, Sendable, CustomStringConvertible {
    /// Convex-Server-ID bei Konto-Servern, sonst `manual`
    var id: String
    var name: String
    /// Bevorzugte Adresse (öffentlich), sonst die Tailnet-Adresse
    var url: String
    /// Zweite Adresse (Tailnet), falls die erste nicht antwortet
    var altURL: String?
    /// Anmeldung mit dem Sitzungs-JWT des Kontos statt eines API-Tokens
    var usesAccount: Bool
    /// API-Token (nur bei `usesAccount == false`)
    var token: String?

    static let manualID = "manual"

    var description: String { "WatchServer(\(id), \(name), account: \(usesAccount), token: \(token == nil ? "–" : "•••"))" }

    /// Basis-URLs in Versuchsreihenfolge (ohne abschließenden Schrägstrich)
    var baseURLs: [URL] {
        [url, altURL].compactMap { raw in
            guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            while s.hasSuffix("/") { s.removeLast() }
            if !s.contains("://") { s = "http://" + s }
            guard let u = URL(string: s), u.host() != nil else { return nil }
            return u
        }
    }
}

/// Kurzfassung eines Chats (Scoop oder Gruppe), die das iPhone mitschickt: Damit kennt die Uhr ihre Scoops samt
/// Aussehen schon, bevor sie selbst den Server erreicht hat (Komplikationen, erste Liste).
nonisolated struct WatchChatSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String?
    /// Maskottchen (bei Gruppen leer)
    var mascot: Mascot?
    /// Gruppen: Maskottchen der ersten Mitglieder
    var members: [Mascot]?
    var unread: Int
    var waiting: Bool
    var preview: String?
    var pinned: Bool

    var isGroup: Bool { ChatGroup.isGroupID(id) }
}

/// Alles, was die Uhr vom iPhone bekommt.
nonisolated struct WatchCredentials: Codable, Equatable, Sendable, CustomStringConvertible {
    static let currentVersion = 1

    var version: Int = WatchCredentials.currentVersion
    var servers: [WatchServer]
    /// Server, mit dem das iPhone gerade verbunden ist
    var activeServerID: String?
    /// Sitzungs-JWT des Kontos (für alle Konto-Server)
    var accountToken: String?
    var accountExpiry: Date?
    var userName: String?
    /// iPhone läuft im Demo-Modus (`-mock`): Uhr zeigt Demo-Daten
    var demo: Bool = false
    /// Chats des aktiven Servers (ohne Nachrichten)
    var chats: [WatchChatSummary] = []
    var updatedAt: Date = Date()

    var description: String {
        "WatchCredentials(servers: \(servers.map(\.id)), active: \(activeServerID ?? "–"), demo: \(demo), "
            + "account: \(accountToken == nil ? "–" : "•••"))"
    }

    var isUsable: Bool { demo || !servers.isEmpty }

    /// Konto-JWT läuft bald ab (Uhr fragt das iPhone nach einem frischen)
    func accountTokenNeedsRefresh(now: Date = Date(), margin: TimeInterval = 24 * 3600) -> Bool {
        guard accountToken != nil else { return servers.contains { $0.usesAccount } }
        guard let accountExpiry else { return false }
        return accountExpiry.timeIntervalSince(now) < margin
    }

    /// Bearer für einen Server (nil = fehlt)
    func bearer(for server: WatchServer) -> String? {
        server.usesAccount ? accountToken : server.token
    }

    func encoded() -> Data? { try? JSONEncoder.watchLink.encode(self) }

    static func decode(_ data: Data) -> WatchCredentials? {
        try? JSONDecoder.watchLink.decode(WatchCredentials.self, from: data)
    }
}

/// Schlüssel und Nachrichtenarten zwischen iPhone und Uhr.
nonisolated enum WatchLink {
    /// applicationContext / Antwort: JSON von `WatchCredentials`
    static let credentialsKey = "credentials"
    static let kindKey = "kind"

    enum Kind: String, Sendable {
        /// Uhr bittet um frische Zugangsdaten (Antwort: `credentialsKey`)
        case credentials
        /// Uhr bittet das iPhone, eine Server-Anfrage für sie auszuführen
        case relay
    }

    // Relay: Anfrage
    static let serverKey = "server"
    static let methodKey = "method"
    static let pathKey = "path"
    static let queryKey = "query"
    static let bodyKey = "body"
    // Relay: Antwort
    static let statusKey = "status"
    static let dataKey = "data"
    static let errorKey = "error"

    /// Nur diese Pfade reicht das iPhone weiter (keine beliebigen URLs)
    static func isRelayablePath(_ path: String) -> Bool {
        path.hasPrefix("/api/") && !path.contains("..") && !path.contains("://")
    }
}
