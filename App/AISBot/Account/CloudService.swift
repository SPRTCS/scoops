import Foundation

/// Alles, was die App vom Konto-Dienst braucht. `ConvexCloudService` spricht mit Convex,
/// `MockCloudService` liefert ein Beispielkonto mit zwei Servern (Demo-Modus `-mock`).
protocol CloudService: AnyObject {
    // Anmeldung (HTTP-Actions, ohne Sitzung)
    func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthResponse
    func refresh(refreshToken: String?, token: String) async throws -> AuthResponse

    // Mit Sitzungs-JWT
    func me(token: String) async throws -> CloudUser?
    func myServers(token: String) async throws -> [CloudServer]
    func claimServer(code: String, token: String) async throws -> ClaimResult
    func renameServer(id: String, name: String, token: String) async throws
    func removeServer(id: String, token: String) async throws
    func mySessions(token: String) async throws -> [CloudSession]
    /// `id == nil`: eigene Sitzung (Abmelden)
    func revokeSession(id: String?, token: String) async throws
    func deleteAccount(token: String) async throws

    // Geteilte Scoops (docs/sharing.md) – Admin
    func createInvite(_ request: InviteRequest, token: String) async throws -> InviteCreated
    func listShares(serverID: String, botID: String, token: String) async throws -> BotShareList
    func updateShare(id: String, role: ShareRole?, computer: ComputerAccess?, token: String) async throws
    func removeShare(id: String, token: String) async throws
    func revokeInvite(id: String, token: String) async throws
    // Gast
    /// Ohne Anmeldung (Vorschau im Annahme-Blatt); `token` nur, wenn vorhanden
    func inviteInfo(code: String, token: String?) async throws -> InviteInfo
    func acceptInvite(code: String, token: String) async throws -> AcceptResult
    func sharedWithMe(token: String) async throws -> [SharedScoop]
    func leaveShare(id: String, token: String) async throws
}

/// Neue Einladung (`shares:createInvite`): Scoop auf dem eigenen Server, Rolle und Rechner-Stufe.
nonisolated struct InviteRequest: Encodable, Sendable {
    var serverId: String
    var botId: String
    var role: ShareRole
    var computer: ComputerAccess
    /// Für die Vorschau beim Gast (Convex kennt keine Inhalte, nur diese Anzeige-Daten; Maskottchen ohne Foto)
    var botName: String
    var botMascot: Mascot?
}

/// Daten aus „Mit Apple anmelden“ für `POST /auth/apple`.
nonisolated struct AppleSignInRequest: Encodable, Sendable {
    var identityToken: String
    var authorizationCode: String?
    /// Name und E-Mail liefert Apple nur bei der allerersten Anmeldung.
    var fullName: String?
    var givenName: String?
    var familyName: String?
    var email: String?
    /// Roher Nonce; Apple hat dessen SHA-256 im Token (`nonce`).
    var nonce: String?
    var deviceName: String
    var platform: String
}

/// Fehler des Konto-Dienstes mit lesbarem Text.
struct CloudError: LocalizedError {
    var status: Int
    var message: String
    /// Fachlicher Fehlercode des Konto-Dienstes, z. B. `invalid_code`, `rate_limited` (claimServer)
    var code: String? = nil
    var errorDescription: String? { message }

    /// Sitzung ungültig oder abgelaufen
    var isUnauthorized: Bool {
        status == 401 || status == 403 || message.localizedCaseInsensitiveContains("unauthenticated")
            || message.localizedCaseInsensitiveContains("nicht angemeldet")
    }
}

// MARK: - Convex

/// Schlanker Convex-Client über die HTTP-API (`POST /api/query`, `/api/mutation`) und die HTTP-Actions
/// (`POST /auth/apple`, `/auth/refresh`). Kein SDK nötig: die App ruft nur wenige Funktionen, ohne Live-Abos.
final class ConvexCloudService: CloudService {
    /// Namen der Convex-Funktionen (`datei:funktion`), Ist-Stand aus docs/accounts.md.
    enum Function {
        static let me = "users:me"
        static let deleteAccount = "users:deleteAccount"
        static let myServers = "servers:myServers"
        static let claimServer = "servers:claimServer"
        static let renameServer = "servers:renameServer"
        static let removeServer = "servers:removeServer"
        static let mySessions = "sessions:mySessions"
        static let revokeSession = "sessions:revokeSession"
        // Geteilte Scoops (docs/sharing.md)
        static let createInvite = "shares:createInvite"
        static let listForBot = "shares:listForBot"
        static let updateShare = "shares:update"
        static let removeShare = "shares:remove"
        static let revokeInvite = "shares:revokeInvite"
        static let inviteInfo = "shares:inviteInfo"
        static let accept = "shares:accept"
        static let mine = "shares:mine"
        static let leave = "shares:leave"
    }

    private let cloudURL: URL
    private let siteURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    init(cloudURL: URL = CloudConfig.cloudURL, siteURL: URL = CloudConfig.siteURL) {
        self.cloudURL = cloudURL
        self.siteURL = siteURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: HTTP-Actions

    func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthResponse {
        try await action("/auth/apple", body: request, token: nil)
    }

    func refresh(refreshToken: String?, token: String) async throws -> AuthResponse {
        struct Body: Encodable { var refreshToken: String? }
        return try await action("/auth/refresh", body: Body(refreshToken: refreshToken), token: token)
    }

    private func action<B: Encodable, T: Decodable>(_ path: String, body: B, token: String?) async throws -> T {
        var req = URLRequest(url: siteURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CloudError(status: status, message: "Unerwartete Antwort vom Konto-Dienst.")
        }
    }

    // MARK: Queries und Mutations

    func me(token: String) async throws -> CloudUser? {
        try await call(.query, Function.me, args: EmptyArgs(), token: token, as: CloudUser?.self)
    }

    func myServers(token: String) async throws -> [CloudServer] {
        try await call(.query, Function.myServers, args: EmptyArgs(), token: token, as: [CloudServer].self)
    }

    func claimServer(code: String, token: String) async throws -> ClaimResult {
        struct Args: Encodable { var code: String }
        return try await call(.mutation, Function.claimServer, args: Args(code: code), token: token, as: ClaimResult.self)
    }

    func renameServer(id: String, name: String, token: String) async throws {
        struct Args: Encodable { var serverId: String; var name: String }
        let result = try await call(.mutation, Function.renameServer, args: Args(serverId: id, name: name), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Der Server wurde nicht gefunden.") }
    }

    func removeServer(id: String, token: String) async throws {
        struct Args: Encodable { var serverId: String }
        let result = try await call(.mutation, Function.removeServer, args: Args(serverId: id), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Der Server wurde nicht gefunden.") }
    }

    func mySessions(token: String) async throws -> [CloudSession] {
        try await call(.query, Function.mySessions, args: EmptyArgs(), token: token, as: [CloudSession].self)
    }

    func revokeSession(id: String?, token: String) async throws {
        struct Args: Encodable { var sessionId: String? }
        let result = try await call(.mutation, Function.revokeSession, args: Args(sessionId: id), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Die Anmeldung wurde nicht gefunden.") }
    }

    func deleteAccount(token: String) async throws {
        let result = try await call(.mutation, Function.deleteAccount, args: EmptyArgs(), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 500, message: "Das Konto konnte nicht gelöscht werden.") }
    }

    // MARK: Geteilte Scoops

    func createInvite(_ request: InviteRequest, token: String) async throws -> InviteCreated {
        // Action (nicht Mutation); fachliche Fehler kommen als `{"ok": false, "error", "message"}`
        let result = try await call(.action, Function.createInvite, args: request, token: token, as: InviteCreated.self)
        guard result.ok, !result.code.isEmpty else {
            let text: String
            switch result.error {
            case "not_owner": text = "Nur der Inhaber des Servers kann diesen Scoop teilen."
            case "too_many_invites": text = "Es gibt schon 20 offene Einladungen für diesen Scoop. Widerrufe zuerst eine."
            case "too_many_shares": text = "Dieser Scoop ist schon mit 50 Personen geteilt."
            case "rate_limited": text = "Zu viele Einladungen in kurzer Zeit. Bitte später erneut versuchen."
            default: text = "Die Einladung konnte nicht erstellt werden."
            }
            throw CloudError(status: 400, message: result.message ?? text)
        }
        return result
    }

    func listShares(serverID: String, botID: String, token: String) async throws -> BotShareList {
        struct Args: Encodable { var serverId: String; var botId: String }
        return try await call(.query, Function.listForBot, args: Args(serverId: serverID, botId: botID), token: token,
                              as: BotShareList.self)
    }

    func updateShare(id: String, role: ShareRole?, computer: ComputerAccess?, token: String) async throws {
        struct Args: Encodable { var shareId: String; var role: ShareRole?; var computer: ComputerAccess? }
        let result = try await call(.mutation, Function.updateShare, args: Args(shareId: id, role: role, computer: computer),
                                    token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Diese Person hat keinen Zugriff mehr.") }
    }

    func removeShare(id: String, token: String) async throws {
        struct Args: Encodable { var shareId: String }
        let result = try await call(.mutation, Function.removeShare, args: Args(shareId: id), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Diese Person hat keinen Zugriff mehr.") }
    }

    func revokeInvite(id: String, token: String) async throws {
        struct Args: Encodable { var inviteId: String }
        let result = try await call(.mutation, Function.revokeInvite, args: Args(inviteId: id), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Die Einladung gibt es nicht mehr.") }
    }

    func inviteInfo(code: String, token: String?) async throws -> InviteInfo {
        struct Args: Encodable { var code: String }
        let info = try await call(.query, Function.inviteInfo, args: Args(code: code), token: token, as: InviteInfo?.self)
        guard let info else { throw CloudError(status: 404, message: "Diese Einladung gibt es nicht (mehr).") }
        return info
    }

    func acceptInvite(code: String, token: String) async throws -> AcceptResult {
        struct Args: Encodable { var code: String }
        return try await call(.mutation, Function.accept, args: Args(code: code), token: token, as: AcceptResult.self)
    }

    func sharedWithMe(token: String) async throws -> [SharedScoop] {
        try await call(.query, Function.mine, args: EmptyArgs(), token: token, as: [SharedScoop].self)
    }

    func leaveShare(id: String, token: String) async throws {
        struct Args: Encodable { var shareId: String }
        let result = try await call(.mutation, Function.leave, args: Args(shareId: id), token: token, as: OKResult.self)
        guard result.ok else { throw CloudError(status: 404, message: "Du hast schon keinen Zugriff mehr.") }
    }

    private enum Kind: String { case query, mutation, action }
    /// `errorData` eines `ConvexError` (z. B. `{"code": "unauthenticated", "message": "Nicht angemeldet"}`)
    private struct ErrorData: Decodable { var code: String?; var message: String? }
    /// Körper für `/api/query` und `/api/mutation`
    private struct CallBody<Args: Encodable>: Encodable { var path: String; var args: Args; var format = "json" }
    private struct EmptyArgs: Encodable {}

    /// Convex-Antwort: `{"status":"success","value":…}` oder `{"status":"error","errorMessage":…}`.
    private struct Envelope<T: Decodable>: Decodable {
        var status: String
        var value: T?
        var errorMessage: String?
        var errorData: ErrorData?

        private enum CodingKeys: String, CodingKey { case status, value, errorMessage, errorData }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(String.self, forKey: .status)
            errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
            errorData = try? c.decodeIfPresent(ErrorData.self, forKey: .errorData)
            value = status == "success" ? try c.decodeIfPresent(T.self, forKey: .value) : nil
        }
    }

    private func call<A: Encodable, T: Decodable>(_ kind: Kind, _ path: String, args: A, token: String?,
                                                  as type: T.Type) async throws -> T {
        var req = URLRequest(url: cloudURL.appending(path: "/api/\(kind.rawValue)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try encoder.encode(CallBody(path: path, args: args))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? decoder.decode(Envelope<T>.self, from: data) else {
            throw Self.error(status: (200..<300).contains(status) ? 0 : status, data: data)
        }
        guard envelope.status == "success" else {
            if envelope.errorData?.code == "unauthenticated" {
                throw CloudError(status: 401, message: envelope.errorData?.message ?? "Nicht angemeldet")
            }
            throw CloudError(status: status, message: envelope.errorData?.message ?? Self.readable(envelope.errorMessage))
        }
        if let value = envelope.value { return value }
        // `null` ist für optionale Rückgaben gültig (z. B. `users:me` ohne Konto)
        if let none = try? decoder.decode(T.self, from: Data("null".utf8)) { return none }
        throw CloudError(status: status, message: "Unerwartete Antwort vom Konto-Dienst.")
    }

    private static func error(status: Int, data: Data) -> CloudError {
        struct Body: Decodable { var error: String?; var message: String?; var errorMessage: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let text = body?.error ?? body?.message ?? body?.errorMessage
        return CloudError(status: status, message: readable(text ?? HTTPURLResponse.localizedString(forStatusCode: status)))
    }

    /// Convex hängt Funktionsname und Stacktrace an (`[CONVEX M(servers:claimServer)] … Uncaught Error: Text`).
    private static func readable(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return "Der Konto-Dienst hat einen Fehler gemeldet."
        }
        if let r = s.range(of: "Uncaught Error: ") { s = String(s[r.upperBound...]) }
        else if let r = s.range(of: "Server Error") { s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        if let at = s.range(of: "    at ") { s = String(s[..<at.lowerBound]) }
        return s.isEmpty ? "Der Konto-Dienst hat einen Fehler gemeldet." : s
    }
}

// MARK: - Demo

/// Beispielkonto mit zwei Servern für den Demo-Modus und Screenshots. Kopplungscode `DEMO2345` (oder jeder
/// andere 8-stellige Code) fügt einen dritten Server hinzu, `FEHLER00` liefert einen Fehler.
final class MockCloudService: CloudService {
    static let demoUser = CloudUser(id: "u_demo", name: "Arman Samary", email: "arman@example.com")

    private var servers: [CloudServer] = [
        CloudServer(id: "s_studio", name: "Mac Studio", publicUrl: "https://mac-studio.tailnet.ts.net:8787",
                    version: "1.12.0", online: true,
                    lastSeenAt: Date().addingTimeInterval(-25)),
        CloudServer(id: "s_air", name: "MacBook Air", publicUrl: "https://macbook-air.tailnet.ts.net:8787",
                    version: "1.11.2", online: false, lastSeenAt: Date().addingTimeInterval(-3 * 3600)),
    ]
    /// Einführung im Demo-Modus: neues Konto ohne geteilte Scoops
    private var onboardingFresh = false
    /// Gerade per Code gekoppelte Server: melden sich erst nach ein paar Sekunden (wie ein echter Mac)
    private var claimedAt: [String: Date] = [:]
    private var sessions: [CloudSession] = [
        CloudSession(id: "sess_this", deviceName: Device.name, platform: Device.platform,
                     createdAt: Date().addingTimeInterval(-6 * 86400), lastUsedAt: Date(), current: true),
        CloudSession(id: "sess_ipad", deviceName: "iPad Pro", platform: "ipados",
                     createdAt: Date().addingTimeInterval(-20 * 86400), lastUsedAt: Date().addingTimeInterval(-2 * 86400),
                     current: false),
        CloudSession(id: "sess_mac", deviceName: "MacBook Air", platform: "macos",
                     createdAt: Date().addingTimeInterval(-40 * 86400), lastUsedAt: Date().addingTimeInterval(-9 * 3600),
                     current: false),
    ]

    /// Einführung im Demo-Modus (`-mock -onboarding …`): neues Konto ohne Server, außer mit `-mockservers`
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if OnboardingState.demoLaunchStep(arguments) != nil {
            // Neues Konto: noch nichts mit mir geteilt (sonst zeigte die App statt der Einführung „Mit mir geteilt“)
            onboardingFresh = true
            if !arguments.contains("-mockservers") { servers = [] }
        }
    }

    static func demoCredentials() -> CloudCredentials {
        CloudCredentials(token: "demo.\(UUID().uuidString)", refreshToken: "demo-refresh",
                         expiresAt: Date().addingTimeInterval(30 * 86400), user: demoUser, appleUserID: nil)
    }

    private func pause() async { try? await Task.sleep(for: .milliseconds(350)) }

    func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthResponse {
        await pause()
        let creds = Self.demoCredentials()
        return try JSONDecoder().decode(AuthResponse.self, from: JSONEncoder().encode(
            ["token": creds.token, "refreshToken": creds.refreshToken ?? ""]))
    }

    func refresh(refreshToken: String?, token: String) async throws -> AuthResponse {
        try JSONDecoder().decode(AuthResponse.self, from: JSONEncoder().encode(["token": "demo.\(UUID().uuidString)"]))
    }

    func me(token: String) async throws -> CloudUser? { Self.demoUser }

    func myServers(token: String) async throws -> [CloudServer] {
        await pause()
        return servers.map { server in
            guard let claimed = claimedAt[server.id], Date().timeIntervalSince(claimed) < 4 else { return server }
            var s = server
            s.online = false
            s.lastSeenAt = nil
            return s
        }
    }

    func claimServer(code: String, token: String) async throws -> ClaimResult {
        await pause()
        if code.uppercased().hasPrefix("FEHLER") {
            var result = ClaimResult(serverId: nil, name: nil)
            result.ok = false
            result.error = "invalid_code"
            result.message = "Dieser Code ist ungültig oder abgelaufen."
            return result
        }
        let server = CloudServer(id: "s_\(UUID().uuidString.prefix(6))", name: "Mac mini",
                                 publicUrl: "https://mac-mini.tailnet.ts.net:8787",
                                 version: "1.12.0", online: true, lastSeenAt: Date())
        servers.append(server)
        claimedAt[server.id] = Date()
        return ClaimResult(serverId: server.id, name: server.name)
    }

    func renameServer(id: String, name: String, token: String) async throws {
        await pause()
        if let i = servers.firstIndex(where: { $0.id == id }) { servers[i].name = name }
    }

    func removeServer(id: String, token: String) async throws {
        await pause()
        servers.removeAll { $0.id == id }
    }

    func mySessions(token: String) async throws -> [CloudSession] {
        await pause()
        return sessions
    }

    func revokeSession(id: String?, token: String) async throws {
        await pause()
        sessions.removeAll { $0.id == (id ?? "sess_this") }
    }

    func deleteAccount(token: String) async throws { await pause() }

    // MARK: Geteilte Scoops (Demo)

    /// Demo: Mila (eigener Scoop) ist mit zwei Personen geteilt, eine Einladung ist offen.
    private var shareLists: [String: BotShareList] = ["b_mila": MockSharing.milaShares]
    /// Demo: Juna von Sophie ist mit mir geteilt (Schreiben, Zusehen). Einladung `DEMO-JUNA` fügt „Kiko“ hinzu.
    private var mine: [SharedScoop] = [MockSharing.juna]

    func createInvite(_ request: InviteRequest, token: String) async throws -> InviteCreated {
        await pause()
        let code = "DEMO\(Int.random(in: 1000...9999))"
        let invite = ShareInvite(id: "inv_\(code)", role: request.role, computer: request.computer,
                                 expiresAt: Date().addingTimeInterval(7 * 86400), createdAt: Date())
        shareLists[request.botId, default: BotShareList(members: [], invites: [])].invites.insert(invite, at: 0)
        return InviteCreated(code: code, inviteId: invite.id, url: nil, expiresAt: invite.expiresAt)
    }

    func listShares(serverID: String, botID: String, token: String) async throws -> BotShareList {
        await pause()
        return shareLists[botID] ?? BotShareList(members: [], invites: [])
    }

    func updateShare(id: String, role: ShareRole?, computer: ComputerAccess?, token: String) async throws {
        await pause()
        for key in shareLists.keys {
            guard let i = shareLists[key]?.members.firstIndex(where: { $0.id == id }) else { continue }
            if let role { shareLists[key]?.members[i].role = role }
            if let computer { shareLists[key]?.members[i].computer = computer }
        }
    }

    func removeShare(id: String, token: String) async throws {
        await pause()
        for key in shareLists.keys { shareLists[key]?.members.removeAll { $0.id == id } }
    }

    func revokeInvite(id: String, token: String) async throws {
        await pause()
        for key in shareLists.keys { shareLists[key]?.invites.removeAll { $0.id == id } }
    }

    func inviteInfo(code: String, token: String?) async throws -> InviteInfo {
        await pause()
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        if normalized.hasPrefix("ALT") {
            return InviteInfo(botName: "Ben", botMascot: nil, ownerName: "Sophie Krämer", role: .read, computer: .noAccess,
                              expiresAt: Date().addingTimeInterval(-3600), status: "expired")
        }
        return InviteInfo(botName: MockSharing.kiko.botName, botMascot: MockSharing.kiko.botMascot, botLabel: "Reiseplanung",
                          ownerName: MockSharing.kiko.ownerName, role: MockSharing.kiko.role,
                          computer: MockSharing.kiko.computer, expiresAt: Date().addingTimeInterval(6 * 86400))
    }

    func acceptInvite(code: String, token: String) async throws -> AcceptResult {
        await pause()
        if !mine.contains(where: { $0.id == MockSharing.kiko.id }) { mine.append(MockSharing.kiko) }
        return AcceptResult(ok: true, shareId: MockSharing.kiko.id, botId: MockSharing.kiko.botId,
                            serverId: MockSharing.kiko.serverId)
    }

    func sharedWithMe(token: String) async throws -> [SharedScoop] {
        await pause()
        return onboardingFresh ? [] : mine
    }

    func leaveShare(id: String, token: String) async throws {
        await pause()
        mine.removeAll { $0.id == id }
    }
}

/// Beispieldaten für geteilte Scoops im Demo-Modus.
enum MockSharing {
    static let lena = ShareMember(id: "sh_lena", userId: "u_lena", name: "Lena Berger", role: .write, computer: .view,
                                  createdAt: Date().addingTimeInterval(-5 * 86400))
    static let jonas = ShareMember(id: "sh_jonas", userId: "u_jonas", name: "Jonas Weber", role: .read, computer: .noAccess,
                                   createdAt: Date().addingTimeInterval(-2 * 86400))
    static let milaShares = BotShareList(
        members: [lena, jonas],
        invites: [ShareInvite(id: "inv_demo", role: .edit, computer: .noAccess,
                              expiresAt: Date().addingTimeInterval(5 * 86400), createdAt: Date().addingTimeInterval(-2 * 86400))])

    static let sophieServer = "s_sophie"
    static let junaMascot = Mascot(shape: "egg", color: "#FA5438", eyes: "relaxed", accessory: "headphones", gaze: "left")
    static let juna = SharedScoop(id: "sh_juna", serverId: sophieServer, serverName: "Sophies Mac",
                                  publicUrl: "https://sophies-mac.tailnet.ts.net:8787", botId: "b_juna", botName: "Juna",
                                  botMascot: junaMascot, ownerId: "u_sophie", ownerName: "Sophie Krämer",
                                  role: .write, computer: .view, online: true, createdAt: Date().addingTimeInterval(-3 * 86400))
    static let kiko = SharedScoop(id: "sh_kiko", serverId: sophieServer, serverName: "Sophies Mac",
                                  publicUrl: "https://sophies-mac.tailnet.ts.net:8787", botId: "b_kiko", botName: "Kiko",
                                  botMascot: Mascot(shape: "circle", color: "#F1DDBB", eyes: "cat", accessory: "none", gaze: "left", mouth: "smile"),
                                  ownerId: "u_sophie", ownerName: "Sophie Krämer", role: .read, computer: .noAccess,
                                  online: true, createdAt: Date())
}
