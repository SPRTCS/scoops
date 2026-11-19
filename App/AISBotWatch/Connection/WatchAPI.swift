import Foundation

struct WatchAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Server-Zugriff der Uhr. Spricht direkt per URLSession mit dem Server (WLAN/LTE, über das iPhone als
/// Netzwerk-Proxy, wenn es in der Nähe ist). Antwortet der Server nicht, reicht das iPhone die Anfrage weiter.
/// Bei 401 holt die Uhr frische Zugangsdaten vom iPhone und versucht es einmal neu.
final class WatchAPI {
    private(set) var server: WatchServer
    private var credentials: WatchCredentials
    /// Wird aufgerufen, wenn das iPhone frische Zugangsdaten geliefert hat
    var onCredentials: ((WatchCredentials) -> Void)?
    /// Letzte erfolgreiche Basis-Adresse (öffentlich oder Tailnet)
    private var workingBase: URL?
    /// Letzter Weg: direkt oder über das iPhone (Anzeige)
    private(set) var lastRoute: Route = .direct

    enum Route { case direct, phone }

    private let session: URLSession
    private let decoder = JSONCoding.makeDecoder()
    private let encoder = JSONCoding.makeEncoder()

    init(server: WatchServer, credentials: WatchCredentials) {
        self.server = server
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func update(credentials: WatchCredentials) {
        self.credentials = credentials
        if let fresh = credentials.servers.first(where: { $0.id == server.id }) { server = fresh }
    }

    // MARK: Endpunkte

    func bots() async throws -> [Bot] { try await request("GET", "/api/bots", as: [Bot].self) }
    func groups() async throws -> [ChatGroup] { try await request("GET", "/api/groups", as: [ChatGroup].self) }

    private func chatBase(_ id: String) -> String {
        ChatGroup.isGroupID(id) ? "/api/groups/\(id)" : "/api/bots/\(id)"
    }

    func messages(chatID: String, limit: Int) async throws -> [Message] {
        try await request("GET", "\(chatBase(chatID))/messages", query: [URLQueryItem(name: "limit", value: String(limit))],
                          as: [Message].self)
    }

    func send(chatID: String, text: String) async throws -> Message {
        struct Body: Encodable { var text: String }
        return try await request("POST", "\(chatBase(chatID))/messages", body: Body(text: text), as: Message.self)
    }

    func markRead(chatID: String) async throws {
        _ = try await raw("POST", "\(chatBase(chatID))/read", body: nil)
    }

    func stop(chatID: String) async throws {
        _ = try await raw("POST", "\(chatBase(chatID))/stop", body: nil)
    }

    func decide(approvalID: String, decision: ApprovalDecision) async throws -> Message {
        struct Body: Encodable { var decision: String }
        return try await request("POST", "/api/approvals/\(approvalID)", body: Body(decision: decision.wireValue),
                                 as: Message.self)
    }

    /// Eigenes Scoop-Bild, klein (der Server verkleinert per `size`)
    func avatar(botID: String, version: Int, size: Int = 128) async throws -> Data {
        let (data, status) = try await perform("GET", "/api/bots/\(botID)/avatar",
                                               query: [URLQueryItem(name: "v", value: String(version)),
                                                       URLQueryItem(name: "size", value: String(size))], body: nil)
        guard status == 200 else { throw WatchAPIError(status: status, message: "Bild konnte nicht geladen werden.") }
        return data
    }

    // MARK: Anfragen

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                       body: (any Encodable)? = nil, as: T.Type) async throws -> T {
        let data = try await raw(method, path, query: query, body: body.map { try encoder.encode($0) })
        return try decoder.decode(T.self, from: data)
    }

    private struct ErrorBody: Decodable { var error: String? }

    @discardableResult
    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?) async throws -> Data {
        let (data, status) = try await perform(method, path, query: query, body: body)
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error
                ?? (status == 401 ? "Anmeldung abgelaufen. Öffne AIS Scoops auf dem iPhone."
                    : HTTPURLResponse.localizedString(forStatusCode: status))
            throw WatchAPIError(status: status, message: message)
        }
        return data
    }

    /// Direkt → (401) frische Zugangsdaten → (Netzfehler) über das iPhone
    private func perform(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> (Data, Int) {
        if credentials.bearer(for: server) == nil || (server.usesAccount && credentials.accountTokenNeedsRefresh()) {
            await refreshCredentials()
        }
        var networkError: Error?
        do {
            var (data, status) = try await direct(method, path, query: query, body: body)
            if status == 401, await refreshCredentials() {
                (data, status) = try await direct(method, path, query: query, body: body)
            }
            lastRoute = .direct
            return (data, status)
        } catch {
            networkError = error
            // Schreibende Anfragen nur weiterreichen, wenn sie den Server sicher nicht erreicht haben (keine Doppelten)
            if method != "GET", !Self.neverReachedServer(error) { throw error }
        }
        // Server von der Uhr aus nicht erreichbar: über das iPhone
        if let (status, data) = await WatchSession.shared.relay(serverID: server.id, method: method, path: path,
                                                                query: query, body: body) {
            lastRoute = .phone
            return (data, status)
        }
        throw networkError ?? WatchAPIError(status: 0, message: "Server nicht erreichbar.")
    }

    private func direct(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> (Data, Int) {
        guard let bearer = credentials.bearer(for: server), !bearer.isEmpty else {
            throw WatchAPIError(status: 401, message: "Keine Zugangsdaten. Öffne AIS Scoops auf dem iPhone.")
        }
        let bases = workingBase.map { w in [w] + server.baseURLs.filter { $0 != w } } ?? server.baseURLs
        guard !bases.isEmpty else { throw WatchAPIError(status: 0, message: "Keine Server-Adresse.") }
        var lastError: Error?
        for base in bases {
            var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            do {
                let (data, response) = try await session.data(for: req)
                workingBase = base
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WatchAPIError(status: 0, message: "Server nicht erreichbar.")
    }

    private static func neverReachedServer(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return error is WatchAPIError }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection, .internationalRoamingOff,
                .dataNotAllowed].contains(e.code)
    }

    /// Fragt das iPhone nach frischen Zugangsdaten. true = es gibt neue.
    @discardableResult
    private func refreshCredentials() async -> Bool {
        guard let fresh = await WatchSession.shared.requestCredentials(), fresh != credentials else { return false }
        update(credentials: fresh)
        onCredentials?(fresh)
        return true
    }
}
