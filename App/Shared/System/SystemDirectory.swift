import Foundation

// MARK: - Verzeichnis für Erweiterungen und Intents (docs/system.md)
//
// Die App schreibt in die App-Gruppe, welche Chats es gibt und zu welchem Server sie gehören
// (`system-directory.json`). Teilen-Menü, Kurzbefehle, Controls und Spotlight lesen nur diese Datei.
// Sie enthält keine Zugangsdaten und keine Nachrichten: Token und Sitzung stehen im Schlüsselbund
// (`SharedKeychain`).

/// Ein Server, den Erweiterungen ansprechen dürfen.
nonisolated struct SystemServer: Codable, Hashable, Identifiable, Sendable {
    /// Konto-Server: Convex-ID. Manuell verbunden: `manual`. Demo-Modus: `demo`.
    var id: String
    var name: String
    /// Bevorzugte Adresse
    var url: String
    /// Zweite Adresse (z. B. Tailnet), falls die erste nicht antwortet
    var altURL: String?
    /// Anmeldung mit dem Sitzungs-JWT des Kontos statt eines API-Tokens
    var usesAccount: Bool
    /// Server eines anderen Admins (mit mir geteilte Scoops)
    var guest: Bool

    static let manualID = "manual"
    static let demoID = "demo"

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

/// Mitglied einer Gruppe (für den Gruppen-Avatar)
nonisolated struct SystemChatMember: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var mascot: Mascot
}

/// Ein Chat: Scoop oder Gruppe. Gehört immer zu genau einem Server.
nonisolated struct SystemChat: Codable, Hashable, Identifiable, Sendable {
    /// Scoop-ID (`b_…`) oder Gruppen-ID (`g_…`)
    var id: String
    var serverID: String
    var name: String
    /// Rolle des Scoops („Assistenz“)
    var label: String?
    /// Maskottchen (bei Gruppen leer)
    var mascot: Mascot?
    /// Gruppen: Mitglieder in Reihenfolge
    var members: [SystemChatMember]?
    /// Haupt-Scoop
    var primary: Bool
    var pinned: Bool
    var lastActiveAt: Date?
    /// Darf ich hier schreiben? (geteilte Scoops mit Rolle „Lesen“: nein)
    var canWrite: Bool
    /// Mit mir geteilter Scoop auf dem Server eines anderen
    var shared: Bool
    /// Admin eines geteilten Scoops
    var ownerName: String?

    var isGroup: Bool { ChatGroup.isGroupID(id) }

    /// Unterzeile: Rolle, bei Gruppen die Mitglieder, bei geteilten Scoops der Admin
    var subtitle: String? {
        if isGroup {
            let names = (members ?? []).map(\.name)
            guard !names.isEmpty else { return String(localized: "Gruppe", comment: "Unterzeile eines Gruppenchats") }
            let list = names.formatted(.list(type: .and).locale(.app))
            return String(localized: "Gruppe mit \(list)")
        }
        if shared, let ownerName, !ownerName.isEmpty {
            if let label, !label.isEmpty { return String(localized: "\(label) · von \(ownerName)") }
            return String(localized: "Geteilt von \(ownerName)")
        }
        if let label, !label.isEmpty { return label }
        return nil
    }
}

nonisolated struct SystemDirectory: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int = SystemDirectory.currentVersion
    var generatedAt: Date
    var userName: String
    /// App läuft im Demo-Modus (`-mock`): Erweiterungen spielen Senden und Antworten nach
    var demo: Bool
    /// Nur Demo (`-shareofflinedemo`): Der Server gilt als nicht erreichbar (Ablage und Nachsenden prüfen)
    var demoOffline: Bool = false
    /// Eigener Server, mit dem die App gerade verbunden ist
    var activeServerID: String?
    var servers: [SystemServer]
    var chats: [SystemChat]
    /// Konto-Dienst (HTTP-Actions) zum Erneuern des Sitzungs-JWT
    var cloudSiteURL: String?

    static let empty = SystemDirectory(generatedAt: .distantPast, userName: "", demo: false, activeServerID: nil,
                                       servers: [], chats: [])

    var isEmpty: Bool { chats.isEmpty }

    func chat(_ id: String?) -> SystemChat? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    func server(_ id: String?) -> SystemServer? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    /// Einzelne Scoops (ohne Gruppen)
    var scoops: [SystemChat] { chats.filter { !$0.isGroup } }

    /// Haupt-Scoop, sonst der erste eigene Scoop
    var primaryScoop: SystemChat? {
        scoops.first { $0.primary && !$0.shared } ?? ordered(scoops.filter { !$0.shared }).first ?? ordered(scoops).first
    }

    /// Standardreihenfolge: Haupt-Scoop, angepinnte, dann zuletzt aktive.
    func ordered(_ list: [SystemChat]) -> [SystemChat] {
        list.sorted { a, b in
            if a.primary != b.primary { return a.primary }
            if a.pinned != b.pinned { return a.pinned }
            return (a.lastActiveAt ?? .distantPast) > (b.lastActiveAt ?? .distantPast)
        }
    }

    // MARK: Ablage in der App-Gruppe

    private static let fileName = "system-directory.json"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: fileName)
    }

    static func load() -> SystemDirectory? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let directory = try? d.decode(SystemDirectory.self, from: data),
              directory.version <= currentVersion else { return nil }
        return directory
    }

    /// Verzeichnis der App; fehlt es noch (Update, App seitdem nicht geöffnet), die Scoops aus dem
    /// Widget-Schnappschuss. Damit bleiben eingerichtete Widgets und ihre Auswahl sofort gültig.
    static func current() -> SystemDirectory {
        if let directory = load() { return directory }
        guard let snapshot = SharedContainer.loadSnapshot() else { return .empty }
        let chats = snapshot.bots.map { bot in
            SystemChat(id: bot.id, serverID: "", name: bot.name, label: bot.label, mascot: bot.mascot, members: nil,
                       primary: false, pinned: bot.pinned, lastActiveAt: bot.lastMessageAt, canWrite: true,
                       shared: false, ownerName: nil)
        }
        return SystemDirectory(generatedAt: snapshot.generatedAt, userName: snapshot.userName, demo: false,
                               activeServerID: nil, servers: [], chats: chats)
    }

    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(self) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Zuletzt benutzt (Teilen-Menü, Kurzbefehle)

    private static let recentsKey = "system.recentChats"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedContainer.appGroup) }

    /// Chat-IDs, zuletzt benutzte zuerst
    static var recentChatIDs: [String] { defaults?.stringArray(forKey: recentsKey) ?? [] }

    static func noteUsed(chatID: String) {
        var list = recentChatIDs.filter { $0 != chatID }
        list.insert(chatID, at: 0)
        defaults?.set(Array(list.prefix(12)), forKey: recentsKey)
    }

    /// Ziele für „An Scoop senden“: zuletzt über das System benutzte zuerst, dann die Standardreihenfolge.
    var shareTargets: [SystemChat] {
        let writable = chats.filter(\.canWrite)
        let recents = Self.recentChatIDs
        let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = writable.filter { rank[$0.id] != nil }.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        let rest = writable.filter { rank[$0.id] == nil }.sorted { a, b in
            (a.lastActiveAt ?? .distantPast) > (b.lastActiveAt ?? .distantPast)
        }
        return recent + rest
    }
}
