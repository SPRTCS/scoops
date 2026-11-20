import Foundation

// Datenmodelle des Konto-Dienstes (Convex). Convex liefert Zeitstempel als Millisekunden seit 1970
// und IDs als `_id`; die Decoder akzeptieren zusätzlich `id`, damit sich das Backend frei entwickeln kann.

/// Angemeldeter Nutzer.
nonisolated struct CloudUser: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var email: String?

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return String(localized: "Apple-Konto")
    }

    private enum CodingKeys: String, CodingKey { case id, _id, userId, name, email }

    init(id: String, name: String?, email: String?) {
        self.id = id; self.name = name; self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: ._id)
            ?? c.decodeIfPresent(String.self, forKey: .userId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(email, forKey: .email)
    }
}

/// Ein eigener AIS-Scoops-Server im Konto (`myServers`).
nonisolated struct CloudServer: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var publicUrl: String?
    var tailnetUrl: String?
    var version: String?
    var online: Bool
    var lastSeenAt: Date?

    /// Adresse, mit der die App verbindet: öffentliche URL, sonst die Tailnet-Adresse.
    var connectURL: String? {
        for candidate in [publicUrl, tailnetUrl] {
            if let s = candidate?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        }
        return nil
    }

    /// Kurze Anzeige der Adresse ohne Schema.
    var displayHost: String? {
        guard let s = connectURL else { return nil }
        return URL(string: s)?.host() ?? s
    }

    private enum CodingKeys: String, CodingKey {
        case id, _id, serverId, name, publicUrl, tailnetUrl, version, online, lastSeenAt
    }

    init(id: String, name: String, publicUrl: String?, tailnetUrl: String? = nil, version: String?,
         online: Bool, lastSeenAt: Date?) {
        self.id = id; self.name = name; self.publicUrl = publicUrl; self.tailnetUrl = tailnetUrl
        self.version = version; self.online = online; self.lastSeenAt = lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: ._id)
            ?? c.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Server"
        publicUrl = try c.decodeIfPresent(String.self, forKey: .publicUrl)
        tailnetUrl = try c.decodeIfPresent(String.self, forKey: .tailnetUrl)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        lastSeenAt = try c.decodeMillis(forKey: .lastSeenAt)
        if let flag = try c.decodeIfPresent(Bool.self, forKey: .online) {
            online = flag
        } else if let seen = lastSeenAt {
            online = Date().timeIntervalSince(seen) < 180
        } else {
            online = false
        }
    }
}

/// Angemeldetes Gerät (`mySessions`).
nonisolated struct CloudSession: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var deviceName: String
    var platform: String?
    var createdAt: Date?
    var lastUsedAt: Date?
    /// Vom Backend gesetzt oder lokal über `sid` des Sitzungs-JWT ermittelt.
    var current: Bool

    var platformIcon: String {
        switch platform?.lowercased() {
        case "macos", "mac": "laptopcomputer"
        case "ipados", "ipad": "ipad"
        default: "iphone"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, _id, sessionId, deviceName, platform, createdAt, _creationTime, lastUsedAt, current, isCurrent
    }

    init(id: String, deviceName: String, platform: String?, createdAt: Date?, lastUsedAt: Date?, current: Bool) {
        self.id = id; self.deviceName = deviceName; self.platform = platform
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.current = current
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: ._id)
            ?? c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? String(localized: "Gerät")
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        createdAt = try c.decodeMillis(forKey: .createdAt) ?? c.decodeMillis(forKey: ._creationTime)
        lastUsedAt = try c.decodeMillis(forKey: .lastUsedAt)
        current = try c.decodeIfPresent(Bool.self, forKey: .current)
            ?? c.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
    }
}

/// Ergebnis der Kopplung per Code (`claimServer`): `{"ok": true, "serverId", "name"}` oder
/// `{"ok": false, "error": "invalid_code" | "rate_limited", "message": "…"}` (wirft bewusst nicht).
nonisolated struct ClaimResult: Decodable, Sendable {
    var ok: Bool
    var serverId: String?
    var name: String?
    var error: String?
    var message: String?

    private enum CodingKeys: String, CodingKey { case ok, serverId, name, error, message }

    init(serverId: String?, name: String?) {
        ok = true; self.serverId = serverId; self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? (serverId != nil)
    }
}

/// `{"ok": true}` / `{"ok": false}` von `renameServer`, `removeServer`, `revokeSession`, `deleteAccount`.
nonisolated struct OKResult: Decodable, Sendable {
    var ok: Bool
    private enum CodingKeys: String, CodingKey { case ok }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c?.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
    }
}

/// Sitzung der App beim Konto-Dienst (Schlüsselbund).
nonisolated struct CloudCredentials: Codable, Equatable, Sendable {
    /// Sitzungs-JWT (RS256, von Convex signiert), Bearer für Convex und eigene Server
    var token: String
    var refreshToken: String?
    var expiresAt: Date?
    var user: CloudUser
    /// Apple-Benutzerkennung, um den Widerruf der Apple-Anmeldung zu bemerken
    var appleUserID: String?

    /// Ablauf laut Antwort, sonst laut `exp` im JWT.
    var expiry: Date? { expiresAt ?? JWT.expiry(token) }
    var sessionID: String? { JWT.claim("sid", in: token) }
}

/// Antwort von `POST /auth/apple` und `POST /auth/refresh`.
nonisolated struct AuthResponse: Decodable, Sendable {
    var token: String
    var refreshToken: String?
    var expiresAt: Date?
    var user: CloudUser?

    private enum CodingKeys: String, CodingKey {
        case token, accessToken, sessionToken, jwt, refreshToken, expiresAt, user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let t = try c.decodeIfPresent(String.self, forKey: .token)
            ?? c.decodeIfPresent(String.self, forKey: .accessToken)
            ?? c.decodeIfPresent(String.self, forKey: .sessionToken)
            ?? c.decodeIfPresent(String.self, forKey: .jwt) else {
            throw DecodingError.keyNotFound(CodingKeys.token, .init(codingPath: c.codingPath,
                                                                     debugDescription: "Kein Sitzungs-Token in der Antwort"))
        }
        token = t
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeMillis(forKey: .expiresAt)
        user = try c.decodeIfPresent(CloudUser.self, forKey: .user)
    }
}

// MARK: - Hilfen

nonisolated extension KeyedDecodingContainer {
    /// Zeitstempel als Millisekunden (Convex), Sekunden (< 10^11) oder ISO-8601-Text.
    func decodeMillis(forKey key: Key) throws -> Date? {
        if let n = try? decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}

/// Liest Felder aus einem JWT, ohne die Signatur zu prüfen (das tun Convex und der Server).
nonisolated enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func claim(_ name: String, in token: String) -> String? { payload(token)?[name] as? String }

    static func expiry(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
