import Foundation

// Datenmodelle des Verzeichnisses für geteilte Scoops (Convex, docs/sharing.md). Convex liefert IDs als `_id`/`id`
// und Zeitstempel als Millisekunden; die Decoder sind bewusst tolerant, damit sich das Backend frei entwickeln kann.

/// Ein mit mir geteilter Scoop (`shares:mine`).
nonisolated struct SharedScoop: Decodable, Identifiable, Hashable, Sendable {
    /// Share-ID
    var id: String
    var serverId: String
    var serverName: String?
    var publicUrl: String?
    var tailnetUrl: String?
    /// Scoop-ID auf dem Server des Admins
    var botId: String
    var botName: String
    var botMascot: Mascot?
    var ownerId: String?
    var ownerName: String
    var role: ShareRole
    var computer: ComputerAccess
    var online: Bool
    var createdAt: Date?

    init(id: String, serverId: String, serverName: String? = nil, publicUrl: String?, tailnetUrl: String? = nil,
         botId: String, botName: String, botMascot: Mascot?, ownerId: String? = nil, ownerName: String,
         role: ShareRole, computer: ComputerAccess, online: Bool, createdAt: Date? = nil) {
        self.id = id; self.serverId = serverId; self.serverName = serverName; self.publicUrl = publicUrl
        self.tailnetUrl = tailnetUrl; self.botId = botId; self.botName = botName; self.botMascot = botMascot
        self.ownerId = ownerId; self.ownerName = ownerName; self.role = role; self.computer = computer
        self.online = online; self.createdAt = createdAt
    }

    /// Adresse des Admin-Servers: öffentliche URL, sonst die Tailnet-Adresse.
    var connectURL: URL? {
        for candidate in [publicUrl, tailnetUrl] {
            if let s = candidate?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
                var text = s
                if !text.contains("://") { text = "https://" + text }
                while text.hasSuffix("/") { text.removeLast() }
                return URL(string: text)
            }
        }
        return nil
    }

    /// Vorname des Admins für kurze Hinweise („Läuft bei Sophie“)
    var ownerFirstName: String { ownerName.split(separator: " ").first.map(String.init) ?? ownerName }

    private enum CodingKeys: String, CodingKey {
        case id, _id, shareId, serverId, serverName, server, publicUrl, tailnetUrl, serverUrl, url
        case botId, botName, botMascot, ownerId, ownerName, role, computer, online, serverOnline, createdAt
    }

    private struct ServerInfo: Decodable {
        var id: String?
        var name: String?
        var publicUrl: String?
        var tailnetUrl: String?
        var online: Bool?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let server = try? c.decodeIfPresent(ServerInfo.self, forKey: .server)
        id = (try? c.decodeIfPresent(String.self, forKey: .shareId)) ?? (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: ._id)) ?? UUID().uuidString
        serverId = (try? c.decodeIfPresent(String.self, forKey: .serverId)) ?? server?.id ?? ""
        serverName = (try? c.decodeIfPresent(String.self, forKey: .serverName)) ?? server?.name
        publicUrl = (try? c.decodeIfPresent(String.self, forKey: .publicUrl)) ?? server?.publicUrl
            ?? (try? c.decodeIfPresent(String.self, forKey: .serverUrl)) ?? (try? c.decodeIfPresent(String.self, forKey: .url))
        tailnetUrl = (try? c.decodeIfPresent(String.self, forKey: .tailnetUrl)) ?? server?.tailnetUrl
        botId = (try? c.decodeIfPresent(String.self, forKey: .botId)) ?? ""
        botName = (try? c.decodeIfPresent(String.self, forKey: .botName)) ?? "Scoop"
        botMascot = SharedMascot.decode(c, .botMascot)
        ownerId = try? c.decodeIfPresent(String.self, forKey: .ownerId)
        ownerName = (try? c.decodeIfPresent(String.self, forKey: .ownerName)).flatMap { $0.isEmpty ? nil : $0 } ?? "Admin"
        role = (try? c.decodeIfPresent(ShareRole.self, forKey: .role)) ?? .write
        computer = (try? c.decodeIfPresent(ComputerAccess.self, forKey: .computer)) ?? .noAccess
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? (try? c.decodeIfPresent(Bool.self, forKey: .serverOnline))
            ?? server?.online ?? false
        createdAt = SharingDate.decode(c, .createdAt)
    }
}

/// Offene Einladung eines Scoops (Admin, `shares:listForBot`).
nonisolated struct ShareInvite: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var role: ShareRole
    var computer: ComputerAccess
    var expiresAt: Date?
    var createdAt: Date?
    /// Link, falls das Verzeichnis ihn noch kennt (der Code selbst wird nur als Hash gespeichert)
    var url: String?

    init(id: String, role: ShareRole, computer: ComputerAccess, expiresAt: Date?, createdAt: Date? = nil, url: String? = nil) {
        self.id = id; self.role = role; self.computer = computer; self.expiresAt = expiresAt
        self.createdAt = createdAt; self.url = url
    }

    private enum CodingKeys: String, CodingKey { case id, _id, inviteId, role, computer, expiresAt, createdAt, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .inviteId)) ?? (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: ._id)) ?? UUID().uuidString
        role = (try? c.decodeIfPresent(ShareRole.self, forKey: .role)) ?? .write
        computer = (try? c.decodeIfPresent(ComputerAccess.self, forKey: .computer)) ?? .noAccess
        expiresAt = SharingDate.decode(c, .expiresAt)
        createdAt = SharingDate.decode(c, .createdAt)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }
}

/// Personen und offene Einladungen eines Scoops (`shares:listForBot`). Akzeptiert `{shares|members, invites}` oder
/// eine reine Liste von Personen.
nonisolated struct BotShareList: Decodable, Sendable {
    var members: [ShareMember]
    var invites: [ShareInvite]

    init(members: [ShareMember], invites: [ShareInvite]) { self.members = members; self.invites = invites }

    private enum CodingKeys: String, CodingKey { case shares, members, invites }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([ShareMember].self) {
            members = list; invites = []
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decodeIfPresent([ShareMember].self, forKey: .shares))
            ?? (try? c.decodeIfPresent([ShareMember].self, forKey: .members)) ?? []
        invites = (try? c.decodeIfPresent([ShareInvite].self, forKey: .invites)) ?? []
    }
}

/// Neue Einladung (`shares:createInvite`).
nonisolated struct InviteCreated: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var message: String?
    var code: String
    var inviteId: String?
    /// Web-Link (`https://…/i/<code>`), falls das Verzeichnis einen liefert
    var url: String?
    var expiresAt: Date?

    init(code: String, inviteId: String?, url: String?, expiresAt: Date?) {
        ok = true
        self.code = code; self.inviteId = inviteId; self.url = url; self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case ok, error, message, code, inviteId, id, _id, url, link, webUrl, expiresAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? (error == nil)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""
        inviteId = (try? c.decodeIfPresent(String.self, forKey: .inviteId)) ?? (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: ._id))
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? (try? c.decodeIfPresent(String.self, forKey: .webUrl))
            ?? (try? c.decodeIfPresent(String.self, forKey: .link))
        expiresAt = SharingDate.decode(c, .expiresAt)
    }

    /// Link zum Teilen: Web-Link, sonst `aisscoops://invite/<code>`
    var shareURL: URL {
        if let url, let u = URL(string: url), u.scheme?.hasPrefix("http") == true { return u }
        return InviteLink.appURL(code: code)
    }
}

/// Vorschau einer Einladung ohne Anmeldung (`shares:inviteInfo`).
nonisolated struct InviteInfo: Decodable, Sendable, Equatable {
    var botName: String
    var botMascot: Mascot?
    var botLabel: String?
    var ownerName: String
    var role: ShareRole
    var computer: ComputerAccess
    var expiresAt: Date?
    /// `ok` | `expired` | `used` | `invalid` (falls das Verzeichnis den Grund nennt)
    var status: String

    init(botName: String, botMascot: Mascot?, botLabel: String? = nil, ownerName: String, role: ShareRole,
         computer: ComputerAccess, expiresAt: Date?, status: String = "ok") {
        self.botName = botName; self.botMascot = botMascot; self.botLabel = botLabel; self.ownerName = ownerName
        self.role = role; self.computer = computer; self.expiresAt = expiresAt; self.status = status
    }

    var isValid: Bool { status == "ok" || status == "valid" || status == "pending" }

    private enum CodingKeys: String, CodingKey {
        case botName, botMascot, botLabel, ownerName, role, computer, expiresAt, status, valid, ok, error, code, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botName = (try? c.decodeIfPresent(String.self, forKey: .botName)) ?? "Scoop"
        botMascot = SharedMascot.decode(c, .botMascot)
        botLabel = try? c.decodeIfPresent(String.self, forKey: .botLabel)
        ownerName = (try? c.decodeIfPresent(String.self, forKey: .ownerName)) ?? "Jemand"
        role = (try? c.decodeIfPresent(ShareRole.self, forKey: .role)) ?? .write
        computer = (try? c.decodeIfPresent(ComputerAccess.self, forKey: .computer)) ?? .noAccess
        expiresAt = SharingDate.decode(c, .expiresAt)
        if let s = try? c.decodeIfPresent(String.self, forKey: .status) {
            status = s
        } else if let v = (try? c.decodeIfPresent(Bool.self, forKey: .valid)) ?? (try? c.decodeIfPresent(Bool.self, forKey: .ok)) {
            status = v ? "ok" : ((try? c.decodeIfPresent(String.self, forKey: .reason))
                                 ?? (try? c.decodeIfPresent(String.self, forKey: .error))
                                 ?? (try? c.decodeIfPresent(String.self, forKey: .code)) ?? "invalid")
        } else {
            status = "ok"
        }
    }

    /// Erklärung, warum die Einladung nicht mehr gilt
    var problem: String? {
        switch status {
        case "ok", "valid", "pending": nil
        case "expired": "Diese Einladung ist abgelaufen. Bitte frag nach einem neuen Link."
        case "used", "accepted": "Diese Einladung wurde schon angenommen. Jeder Link gilt nur einmal."
        case "revoked": "Diese Einladung wurde zurückgezogen."
        case "own", "self", "owner", "own_scoop": "Das ist dein eigener Scoop."
        default: "Diese Einladung ist ungültig."
        }
    }
}

/// Ergebnis von `shares:accept`: `{"ok": true, "shareId", …}` oder `{"ok": false, "error", "message"}`.
nonisolated struct AcceptResult: Decodable, Sendable {
    var ok: Bool
    var shareId: String?
    var botId: String?
    var serverId: String?
    var error: String?
    var message: String?

    private enum CodingKeys: String, CodingKey { case ok, shareId, botId, serverId, error, message, code }

    init(ok: Bool, shareId: String?, botId: String?, serverId: String?) {
        self.ok = ok; self.shareId = shareId; self.botId = botId; self.serverId = serverId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareId = try? c.decodeIfPresent(String.self, forKey: .shareId)
        botId = try? c.decodeIfPresent(String.self, forKey: .botId)
        serverId = try? c.decodeIfPresent(String.self, forKey: .serverId)
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? (try? c.decodeIfPresent(String.self, forKey: .code))
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? (error == nil)
    }
}

/// `botMascot` darf ein Objekt oder ein JSON-Text sein („kleines JSON für die Liste“).
nonisolated enum SharedMascot {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Mascot? {
        if let m = try? c.decodeIfPresent(Mascot.self, forKey: key) { return m }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), let data = s.data(using: .utf8) else { return nil }
        return try? JSONCoding.makeDecoder().decode(Mascot.self, from: data)
    }

    /// Für `shares:createInvite`: Maskottchen ohne Foto (Convex erlaubt höchstens 2 KB)
    static func forDirectory(_ mascot: Mascot) -> Mascot {
        var m = mascot
        m.photo = nil
        return m
    }
}

/// Einladungslinks: `aisscoops://invite/<code>` und Web-Links `https://…/i/<code>`.
nonisolated enum InviteLink {
    static let scheme = "aisscoops"

    static func appURL(code: String) -> URL {
        URL(string: "\(scheme)://invite/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)")!
    }

    /// Code aus einem Einladungslink (App- oder Web-Link), sonst nil.
    static func code(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        if scheme == Self.scheme || scheme == "aisbot" {
            guard url.host()?.lowercased() == "invite" else { return nil }
            if let c = url.pathComponents.dropFirst().first, !c.isEmpty { return c }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        }
        if scheme == "https" || scheme == "http" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let i = parts.firstIndex(where: { $0 == "i" || $0 == "invite" }), i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }
}

/// Kosten eines Scoops (`GET /api/bots/{id}/usage`), bei geteilten Scoops aufgeteilt nach Person.
/// Admins sehen alle Personen, Gäste nur sich selbst und ihr Tageslimit.
nonisolated struct BotUsage: Decodable, Equatable, Sendable {
    nonisolated struct Person: Decodable, Equatable, Identifiable, Sendable {
        var userId: String?
        var name: String
        var isOwner: Bool
        var role: ShareRole?
        var todayUsd: Double
        var monthUsd: Double
        /// Rest des Tageslimits (nur Gäste)
        var budgetLeftUsd: Double?

        var id: String { userId ?? "owner" }

        init(userId: String?, name: String, isOwner: Bool, role: ShareRole? = nil, todayUsd: Double, monthUsd: Double,
             budgetLeftUsd: Double? = nil) {
            self.userId = userId; self.name = name; self.isOwner = isOwner; self.role = role
            self.todayUsd = todayUsd; self.monthUsd = monthUsd; self.budgetLeftUsd = budgetLeftUsd
        }

        private enum CodingKeys: String, CodingKey { case userId, name, isOwner, role, todayUsd, monthUsd, budgetLeftUsd }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = try? c.decodeIfPresent(String.self, forKey: .userId)
            isOwner = (try? c.decodeIfPresent(Bool.self, forKey: .isOwner)) ?? (userId == nil)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (isOwner ? "Admin" : "Gast")
            role = try? c.decodeIfPresent(ShareRole.self, forKey: .role)
            todayUsd = (try? c.decodeIfPresent(Double.self, forKey: .todayUsd)) ?? 0
            monthUsd = (try? c.decodeIfPresent(Double.self, forKey: .monthUsd)) ?? 0
            budgetLeftUsd = try? c.decodeIfPresent(Double.self, forKey: .budgetLeftUsd)
        }
    }

    var todayUsd: Double
    var monthUsd: Double
    var totalUsd: Double?
    var guestBudget: Double?
    var byPerson: [Person]

    init(todayUsd: Double, monthUsd: Double, totalUsd: Double? = nil, guestBudget: Double? = nil, byPerson: [Person] = []) {
        self.todayUsd = todayUsd; self.monthUsd = monthUsd; self.totalUsd = totalUsd
        self.guestBudget = guestBudget; self.byPerson = byPerson
    }

    private enum CodingKeys: String, CodingKey { case todayUsd, monthUsd, totalUsd, guestBudget, byPerson, persons, people }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todayUsd = (try? c.decodeIfPresent(Double.self, forKey: .todayUsd)) ?? 0
        monthUsd = (try? c.decodeIfPresent(Double.self, forKey: .monthUsd)) ?? 0
        totalUsd = try? c.decodeIfPresent(Double.self, forKey: .totalUsd)
        guestBudget = try? c.decodeIfPresent(Double.self, forKey: .guestBudget)
        byPerson = (try? c.decodeIfPresent([Person].self, forKey: .byPerson))
            ?? (try? c.decodeIfPresent([Person].self, forKey: .persons))
            ?? (try? c.decodeIfPresent([Person].self, forKey: .people)) ?? []
    }

    /// Personen, teuerste zuerst (der Admin zuerst bei Gleichstand)
    var sortedPersons: [Person] {
        byPerson.sorted { ($0.monthUsd, $0.isOwner ? 1 : 0) > ($1.monthUsd, $1.isOwner ? 1 : 0) }
    }
}

/// Server-Pfade für geteilte Scoops (Ist-Stand docs/sharing.md)
nonisolated enum SharingEndpoints {
    /// Gast meldet sein Geräte-Token am Server des Admins
    static let guestDevices = "/api/shared/devices"
}

/// `GET /api/bots/{id}/sharing` (Admin): Werkzeuge für Geteilte, Tageslimit und was sich überhaupt freigeben lässt.
nonisolated struct SharingSettings: Decodable, Equatable, Sendable {
    nonisolated struct Option: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
    }

    nonisolated struct Options: Decodable, Equatable, Sendable {
        var apps: [Option]
        var mcp: [Option]
        /// Gruppe → verfügbar (z. B. `phone: false`, wenn kein Lucy eingerichtet ist)
        var available: [String: Bool]

        init(apps: [Option] = [], mcp: [Option] = [], available: [String: Bool] = [:]) {
            self.apps = apps; self.mcp = mcp; self.available = available
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GuestTools.AnyKey.self)
            var apps: [Option] = [], mcp: [Option] = [], available: [String: Bool] = [:]
            for key in c.allKeys {
                if let list = try? c.decode([Option].self, forKey: key) {
                    if key.stringValue == "apps" { apps = list } else if key.stringValue.hasPrefix("mcp") { mcp = list }
                    available[key.stringValue.hasPrefix("mcp") ? "mcp" : key.stringValue] = !list.isEmpty
                } else if let flag = try? c.decode(Bool.self, forKey: key) {
                    available[key.stringValue] = flag
                }
            }
            self.apps = apps; self.mcp = mcp; self.available = available
        }

        /// Liste für eine Gruppe mit Einzel-Schaltern (`apps`, `mcp`)
        func items(_ group: String) -> [Option] { group == "apps" ? apps : (group == "mcp" ? mcp : []) }
    }

    var guestTools: GuestTools
    var guestBudget: Double
    var options: Options

    init(guestTools: GuestTools, guestBudget: Double, options: Options) {
        self.guestTools = guestTools; self.guestBudget = guestBudget; self.options = options
    }

    private enum CodingKeys: String, CodingKey { case guestTools, guestBudget, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guestTools = (try? c.decodeIfPresent(GuestTools.self, forKey: .guestTools)) ?? .standard
        guestBudget = (try? c.decodeIfPresent(Double.self, forKey: .guestBudget)) ?? 2
        options = (try? c.decodeIfPresent(Options.self, forKey: .options)) ?? Options()
    }
}
