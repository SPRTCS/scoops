import Foundation

// MARK: - Geteilte Scoops (docs/sharing.md, Phase 1)

/// Rolle einer geteilten Person. Der Admin (Ersteller) ist keine Rolle eines Shares.
nonisolated enum ShareRole: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case read, write, edit

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        self = ShareRole(rawValue: raw) ?? .write
    }

    var title: String {
        switch self {
        case .read: String(localized: "Lesen", comment: "Geteilter Scoop: Rolle nur lesen")
        case .write: String(localized: "share.role.write", defaultValue: "Schreiben", comment: "Geteilter Scoop: Rolle mitschreiben (englisch „Write“)")
        case .edit: String(localized: "Bearbeiten", comment: "Geteilter Scoop: Rolle bearbeiten")
        }
    }

    var detail: String {
        switch self {
        case .read: String(localized: "Sieht den Chat, kann aber nichts schreiben.")
        case .write: String(localized: "Schreibt mit, schickt Dateien und nutzt den Sprechmodus.")
        case .edit: String(localized: "Wie Schreiben, ändert zusätzlich Name, Aussehen, Charakter, Stimme, Routinen und Gedächtnis.")
        }
    }

    var symbol: String {
        switch self {
        case .read: "eye"
        case .write: "text.bubble"
        case .edit: "pencil"
        }
    }

    var canWrite: Bool { self != .read }
    var canEdit: Bool { self == .edit }
}

/// Rechner-Zugriff einer geteilten Person (unabhängig von der Rolle).
nonisolated enum ComputerAccess: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case noAccess = "none", view, control

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        self = ComputerAccess(rawValue: raw) ?? .noAccess
    }

    var title: String {
        switch self {
        case .noAccess: String(localized: "Kein Zugriff")
        case .view: String(localized: "Zusehen", comment: "Rechner-Zugriff: nur zusehen")
        case .control: String(localized: "Steuern", comment: "Rechner-Zugriff: Maus und Tastatur")
        }
    }

    /// Kurz für Listen: „Kein Rechner“, „Zusehen“, „Steuern“
    var shortTitle: String {
        switch self {
        case .noAccess: String(localized: "Kein Rechner")
        case .view: String(localized: "Zusehen", comment: "Rechner-Zugriff: nur zusehen")
        case .control: String(localized: "Steuern", comment: "Rechner-Zugriff: Maus und Tastatur")
        }
    }

    var detail: String {
        switch self {
        case .noAccess: String(localized: "Bildschirm und Rechner-Karten bleiben unsichtbar.")
        case .view: String(localized: "Sieht den Live-Bildschirm des Rechners, nur lesend.")
        case .control: String(localized: "Sieht zu und kann Maus und Tastatur übernehmen.")
        }
    }

    var symbol: String {
        switch self {
        case .noAccess: "eye.slash"
        case .view: "display"
        case .control: "cursorarrow.motionlines"
        }
    }

    var canView: Bool { self != .noAccess }
    var canControl: Bool { self == .control }
}

/// Eine geteilte Person in der Personenliste des Admins (`shared.members` im Scoop-JSON bzw. `shares:listForBot`).
nonisolated struct ShareMember: Codable, Hashable, Identifiable, Sendable {
    /// Share-ID (Convex)
    var id: String
    var userId: String?
    var name: String
    /// Bild der Person (optional, z. B. Apple liefert keins)
    var pictureUrl: String?
    var role: ShareRole
    var computer: ComputerAccess
    var createdAt: Date?

    init(id: String, userId: String? = nil, name: String, pictureUrl: String? = nil, role: ShareRole,
         computer: ComputerAccess, createdAt: Date? = nil) {
        self.id = id; self.userId = userId; self.name = name; self.pictureUrl = pictureUrl
        self.role = role; self.computer = computer; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, _id, shareId, userId, granteeId, name, granteeName, displayName, pictureUrl, avatarUrl, picture
        case role, computer, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .shareId))
            ?? (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: ._id)) ?? UUID().uuidString
        userId = ((try? c.decodeIfPresent(String.self, forKey: .granteeId)))
            ?? ((try? c.decodeIfPresent(String.self, forKey: .userId)))
        let rawName = ((try? c.decodeIfPresent(String.self, forKey: .name)))
            ?? ((try? c.decodeIfPresent(String.self, forKey: .granteeName)))
            ?? ((try? c.decodeIfPresent(String.self, forKey: .displayName)))
        name = rawName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? String(localized: "Unbekannt", comment: "Name einer geteilten Person ohne Namen")
        pictureUrl = ((try? c.decodeIfPresent(String.self, forKey: .pictureUrl)))
            ?? ((try? c.decodeIfPresent(String.self, forKey: .avatarUrl)))
            ?? ((try? c.decodeIfPresent(String.self, forKey: .picture)))
        role = (try? c.decodeIfPresent(ShareRole.self, forKey: .role)) ?? .write
        computer = (try? c.decodeIfPresent(ComputerAccess.self, forKey: .computer)) ?? .noAccess
        createdAt = SharingDate.decode(c, .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .shareId)
        try c.encodeIfPresent(userId, forKey: .granteeId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(pictureUrl, forKey: .pictureUrl)
        try c.encode(role, forKey: .role)
        try c.encode(computer, forKey: .computer)
    }

    /// Initiale für das runde Bild
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
}

/// `shared` im Scoop-JSON des Admins: Anzahl und Personen.
nonisolated struct BotShareSummary: Codable, Hashable, Sendable {
    var count: Int
    var members: [ShareMember]

    init(count: Int, members: [ShareMember]) { self.count = count; self.members = members }

    private enum CodingKeys: String, CodingKey { case count, members }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decodeIfPresent([ShareMember].self, forKey: .members)) ?? []
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? members.count
    }
}

/// Sicht eines Gasts auf einen geteilten Scoop (Scoop-JSON vom Server des Admins, Feld `access`).
nonisolated struct BotAccess: Codable, Hashable, Sendable {
    var role: ShareRole
    var computer: ComputerAccess
    var ownerName: String?
    var ownerId: String?
    var shareId: String?
    var serverName: String?

    init(role: ShareRole, computer: ComputerAccess, ownerName: String? = nil, ownerId: String? = nil, shareId: String? = nil) {
        self.role = role; self.computer = computer; self.ownerName = ownerName; self.ownerId = ownerId
        self.shareId = shareId
    }
}

/// Werkzeuge, die Läufe von Gästen nutzen dürfen (`guest_tools`). Gruppen sind Schalter (`web`, `computer`,
/// `phone`, `mail`); `apps` und `mcp` können zusätzlich pro App bzw. MCP geschaltet sein (`{"gmail": true}`).
/// Unbekannte Gruppen des Servers bleiben erhalten und werden mit ihrer Kennung angezeigt.
nonisolated struct GuestTools: Codable, Hashable, Sendable {
    /// Gruppe → an/aus
    var flags: [String: Bool]
    /// Gruppe → (Eintrag → an/aus), z. B. `apps` → `gmail`
    var items: [String: [String: Bool]]

    init(flags: [String: Bool] = [:], items: [String: [String: Bool]] = [:]) {
        self.flags = flags; self.items = items
    }

    /// Standard laut Spezifikation: nur Websuche (und Antworten).
    static let standard = GuestTools(flags: [Group.web.rawValue: true])

    /// Bekannte Werkzeug-Gruppen in Anzeige-Reihenfolge
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case web, computer, apps, mcp, phone, mail
        var id: String { rawValue }

        var title: String {
            switch self {
            case .web: String(localized: "Websuche")
            case .computer: String(localized: "Rechner", comment: "Rechner (Computer)")
            case .apps: String(localized: "Verbundene Apps")
            case .mcp: String(localized: "MCPs")
            case .phone: String(localized: "Telefon (Lucy)")
            case .mail: String(localized: "Mails")
            }
        }

        var detail: String {
            switch self {
            case .web: String(localized: "Im Netz suchen und lesen")
            case .computer: String(localized: "Bildschirm, Browser, Terminal")
            case .apps: String(localized: "Deine Konten über Composio")
            case .mcp: String(localized: "Zum Beispiel Atrium, Team App")
            case .phone: String(localized: "Anrufe, nur mit deiner Freigabe")
            case .mail: String(localized: "Senden nur mit deiner Freigabe")
            }
        }

        var symbol: String {
            switch self {
            case .web: "globe"
            case .computer: "desktopcomputer"
            case .apps: "square.grid.2x2"
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .phone: "phone"
            case .mail: "envelope"
            }
        }
    }

    func isOn(_ group: String) -> Bool {
        if let flag = flags[group] { return flag }
        if let list = items[group] { return list.values.contains(true) }
        return false
    }

    func isOn(_ group: String, item: String) -> Bool { items[group]?[item] ?? flags[group] ?? false }

    /// Alle Gruppen, die angezeigt werden: bekannte zuerst, danach unbekannte des Servers.
    var allGroups: [String] {
        let known = Group.allCases.map(\.rawValue)
        let extra = Set(flags.keys).union(items.keys).subtracting(known).sorted()
        return known + extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var flags: [String: Bool] = [:]
        var items: [String: [String: Bool]] = [:]
        for key in c.allKeys {
            let name = GuestTools.normalize(key.stringValue)
            if let b = try? c.decode(Bool.self, forKey: key) {
                flags[name] = b
            } else if let dict = try? c.decode([String: Bool].self, forKey: key) {
                items[name] = dict
            } else if let list = try? c.decode([String].self, forKey: key) {
                // Liste freigegebener Einträge (z. B. `"apps": ["gmail"]`)
                items[name] = Dictionary(uniqueKeysWithValues: list.map { ($0, true) })
            }
        }
        self.flags = flags
        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in flags where items[k] == nil { try c.encode(v, forKey: AnyKey(k)) }
        // Apps und MCPs als Liste der freigegebenen Kennungen (`"apps": ["gmail"]`)
        for (k, v) in items { try c.encode(v.filter(\.value).keys.sorted(), forKey: AnyKey(k)) }
    }

    /// `webSearch` (nach `convertFromSnakeCase`) bzw. `web_search` → `web`
    private static func normalize(_ raw: String) -> String {
        switch raw {
        case "webSearch", "web_search", "search": return Group.web.rawValue
        case "composio", "connections": return Group.apps.rawValue
        case "mcps": return Group.mcp.rawValue
        case "lucy", "call", "calls": return Group.phone.rawValue
        case "gmail", "email", "mails": return Group.mail.rawValue
        default: return raw
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Zeitstempel als Millisekunden (Convex), Sekunden oder ISO-Text.
nonisolated enum SharingDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return ISO8601Parser.parse(s) }
        return nil
    }
}
