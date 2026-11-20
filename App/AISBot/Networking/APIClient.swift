import Foundation

/// HTTP-Client für den Bot-Server (URLSession + async/await) inkl. WebSocket.
/// Meldet sich wahlweise mit dem API-Token oder dem Sitzungs-JWT des Kontos an (`ServerAuth`).
final class APIClient: BotService {
    let baseURL: URL
    let auth: ServerAuth
    private let session: URLSession
    private let decoder = JSONCoding.makeDecoder()
    private let encoder = JSONCoding.makeEncoder()
    private lazy var socket = EventSocket(decoder: decoder) { [weak self] in self?.webSocketRequest() }

    /// Aktueller Bearer-Wert (Token oder JWT) für URLs mit `?token=` und einzelne Anfragen
    private var token: String { auth.current }

    var onEvent: ((ServerEvent) -> Void)? {
        didSet { socket.onEvent = onEvent }
    }
    var onSocketState: ((SocketState) -> Void)? {
        didSet { socket.onState = onSocketState }
    }

    init(baseURL: URL, auth: ServerAuth) {
        self.baseURL = baseURL
        self.auth = auth
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        // Sprache der App (docs/sprache.md): Fehler, Hinweise und Kataloge kommen in derselben Sprache
        config.httpAdditionalHeaders = ["Accept-Language": AppLanguage.acceptLanguage]
        self.session = URLSession(configuration: config)
    }

    convenience init(baseURL: URL, token: String) {
        self.init(baseURL: baseURL, auth: .token(token))
    }

    // MARK: Hilfsfunktionen

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// Jeder Verbindungsaufbau holt den aktuellen Wert (ein erneuertes JWT gilt ab dem nächsten Aufbau).
    /// Der Wert geht als Header und – für ältere Server – zusätzlich als `?token=` mit.
    private func webSocketRequest() -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: "/api/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Bei einer Konto-Verbindung: bald ablaufendes JWT vor dem Start des Live-Kanals erneuern.
    private func prepareSocket() async {
        if auth.kind == .account { _ = try? await auth.valid() }
    }

    /// Schickt eine Anfrage mit gültigem Bearer. Antwortet der Server mit 401 und lässt sich das JWT
    /// erneuern, wird genau einmal wiederholt.
    private func send(_ build: (String) throws -> URLRequest) async throws -> (Data, Int) {
        var bearer = try await auth.valid()
        var retried = false
        while true {
            var req = try build(bearer)
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !retried, auth.kind == .account, await auth.renewAfterUnauthorized() {
                retried = true
                bearer = auth.current
                continue
            }
            return (data, status)
        }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                       body: (any Encodable)? = nil, as type: T.Type) async throws -> T {
        let payload = try body.map { try encoder.encode($0) }
        let target = url(path, query: query)
        let (data, status) = try await send { _ in
            var req = URLRequest(url: target)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let payload {
                req.httpBody = payload
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return req
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: data, decoder: decoder)
        }
        if T.self == OKResponse.self, data.isEmpty { return OKResponse(ok: true) as! T }
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func ok(_ method: String, _ path: String, query: [URLQueryItem] = [],
                    body: (any Encodable)? = nil) async throws -> OKResponse {
        try await request(method, path, query: query, body: body, as: OKResponse.self)
    }

    /// Für Erweiterungen in eigenen Dateien (z. B. `APIClient+Ruhe.swift`): JSON-Anfrage wie `request`.
    func call<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, as type: T.Type) async throws -> T {
        try await request(method, path, body: body, as: type)
    }

    /// Wie `call`, aber mit fertigen Rohdaten als Body (z. B. eine Vorlagen-Datei, unverändert an den Server).
    func call<T: Decodable>(_ method: String, _ path: String, rawBody: Data, as type: T.Type) async throws -> T {
        try decoder.decode(T.self, from: try await rawJSON(method, path, body: rawBody))
    }

    /// Gast-Verbindung (geteilter Scoop): Rechner, Diktat und Stimmprobe gelten für diesen Scoop (`?bot=`).
    /// Der Store setzt ihn vor jedem Aufruf auf den ausgewählten Chat.
    var guestBotID: String?

    /// `?node=` für die Rechner-Endpunkte; beim Bot-Rechner weglassen (ältere Server kennen den Parameter nicht).
    /// Gäste adressieren den Rechner über den Scoop (`?bot=`), ein abweichendes `node=` lehnt der Server ab.
    private func nodeQuery(_ node: String) -> [URLQueryItem] {
        if let guestBotID { return [URLQueryItem(name: "bot", value: guestBotID)] }
        return node == ComputerNode.builtinID ? [] : [URLQueryItem(name: "node", value: node)]
    }

    private var guestQuery: [URLQueryItem] { guestBotID.map { [URLQueryItem(name: "bot", value: $0)] } ?? [] }

    // MARK: Endpunkte

    func health() async throws -> Health { try await request("GET", "/api/health", as: Health.self) }
    func bots() async throws -> [Bot] { try await request("GET", "/api/bots", as: [Bot].self) }
    func createBot(_ draft: BotDraft) async throws -> Bot { try await request("POST", "/api/bots", body: draft, as: Bot.self) }
    func updateBot(id: String, patch: BotPatch) async throws -> Bot {
        try await request("PATCH", "/api/bots/\(id)", body: patch, as: Bot.self)
    }
    func deleteBot(id: String) async throws { try await ok("DELETE", "/api/bots/\(id)") }

    /// `/api/groups/{id}` für Gruppen, sonst `/api/bots/{id}`.
    private func chatBase(_ id: String) -> String {
        ChatGroup.isGroupID(id) ? "/api/groups/\(id)" : "/api/bots/\(id)"
    }

    func messages(chatID: String, before: String?, limit: Int) async throws -> [Message] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.insert(URLQueryItem(name: "before", value: before), at: 0) }
        return try await request("GET", "\(chatBase(chatID))/messages", query: q, as: [Message].self)
    }

    // Suche und Chat-Komfort (App 1.3, `ChatComfortService` in Search/SearchModels.swift)

    func searchMessages(query: String, chatID: String?, limit: Int) async throws -> SearchResponse {
        var q = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        if let chatID { q.append(URLQueryItem(name: "chat", value: chatID)) }
        return try await request("GET", "/api/search", query: q, as: SearchResponse.self)
    }

    func messagesAround(chatID: String, messageID: String, before: Int, after: Int) async throws -> MessageWindow {
        let q = [URLQueryItem(name: "before", value: String(before)), URLQueryItem(name: "after", value: String(after))]
        return try await request("GET", "/api/chats/\(chatID)/messages/around/\(messageID)", query: q, as: MessageWindow.self)
    }

    func messagesAfter(chatID: String, messageID: String, limit: Int) async throws -> [Message] {
        let q = [URLQueryItem(name: "after", value: messageID), URLQueryItem(name: "limit", value: String(limit))]
        return try await request("GET", "\(chatBase(chatID))/messages", query: q, as: [Message].self)
    }

    func editMessage(id: String, text: String) async throws -> Message {
        try await request("PATCH", "/api/messages/\(id)", body: MessageEdit(text: text), as: Message.self)
    }

    func send(chatID: String, message: OutgoingMessage) async throws -> Message {
        try await request("POST", "\(chatBase(chatID))/messages", body: message, as: Message.self)
    }

    func stop(chatID: String) async throws { try await ok("POST", "\(chatBase(chatID))/stop") }
    func stopTask(id: String) async throws { try await ok("POST", "/api/tasks/\(id)/stop") }
    func markRead(chatID: String) async throws { try await ok("POST", "\(chatBase(chatID))/read") }
    func reset(chatID: String) async throws { try await ok("POST", "\(chatBase(chatID))/reset") }
    func memories(botID: String) async throws -> [Memory] {
        try await request("GET", "/api/bots/\(botID)/memories", as: [Memory].self)
    }
    func deleteMemory(id: String) async throws { try await ok("DELETE", "/api/memories/\(id)") }
    func routines(botID: String) async throws -> [Routine] {
        try await request("GET", "/api/bots/\(botID)/routines", as: [Routine].self)
    }
    func setRoutine(id: String, enabled: Bool) async throws -> Routine {
        struct Body: Encodable { var enabled: Bool }
        return try await request("PATCH", "/api/routines/\(id)", body: Body(enabled: enabled), as: Routine.self)
    }
    func deleteRoutine(id: String) async throws { try await ok("DELETE", "/api/routines/\(id)") }
    func runRoutine(id: String) async throws { try await ok("POST", "/api/routines/\(id)/run") }

    func decide(approvalID: String, approve: Bool, note: String?) async throws -> Message {
        struct Body: Encodable { var decision: String; var note: String? }
        return try await request("POST", "/api/approvals/\(approvalID)",
                                 body: Body(decision: approve ? "approve" : "decline", note: note), as: Message.self)
    }

    func decideMail(approvalID: String, approve: Bool, edits: MailEdits?) async throws -> Message {
        struct Body: Encodable { var decision: String; var edits: MailEdits? }
        return try await request("POST", "/api/approvals/\(approvalID)",
                                 body: Body(decision: approve ? "approve" : "decline", edits: approve ? edits : nil),
                                 as: Message.self)
    }

    func decideVault(approvalID: String, approve: Bool, edits: VaultEdits?) async throws -> Message {
        struct Body: Encodable { var decision: String; var edits: VaultEdits? }
        // Der Body (mit Passwort) wird nirgends protokolliert; Fehlertexte kommen vom Server ohne Passwort.
        return try await request("POST", "/api/approvals/\(approvalID)",
                                 body: Body(decision: approve ? "approve" : "decline", edits: approve ? edits : nil),
                                 as: Message.self)
    }

    func decideScoopUpdate(approvalID: String, approve: Bool, after: String?) async throws -> Message {
        struct Edits: Encodable { var after: String }
        struct Body: Encodable { var decision: String; var edits: Edits? }
        return try await request("POST", "/api/approvals/\(approvalID)",
                                 body: Body(decision: approve ? "approve" : "decline",
                                            edits: approve ? after.map { Edits(after: $0) } : nil), as: Message.self)
    }

    func decideAlways(approvalID: String, mailEdits: MailEdits?) async throws -> Message {
        struct Body: Encodable { var decision = "approve_always"; var edits: MailEdits? }
        return try await request("POST", "/api/approvals/\(approvalID)", body: Body(edits: mailEdits), as: Message.self)
    }

    func standingApprovals(botID: String) async throws -> [StandingApproval] {
        try await request("GET", "/api/bots/\(botID)/standing-approvals", as: [StandingApproval].self)
    }

    func deleteStandingApproval(botID: String, id: String) async throws {
        try await ok("DELETE", "/api/bots/\(botID)/standing-approvals/\(id)")
    }

    func setRoutineModel(id: String, model: String?) async throws -> Routine {
        /// `{"model": null}` muss als `null` ankommen (= wie der Scoop).
        struct Body: Encodable {
            var model: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(model, forKey: .model)
            }
            enum CodingKeys: String, CodingKey { case model }
        }
        return try await request("PATCH", "/api/routines/\(id)", body: Body(model: model), as: Routine.self)
    }

    func react(messageID: String, emoji: String?) async throws -> Message {
        /// `{"emoji": null}` muss als `null` ankommen (nicht weggelassen werden).
        struct Body: Encodable {
            var emoji: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(emoji, forKey: .emoji)
            }
            enum CodingKeys: String, CodingKey { case emoji }
        }
        return try await request("PUT", "/api/messages/\(messageID)/reaction", body: Body(emoji: emoji), as: Message.self)
    }

    func computer(node: String) async throws -> ComputerState {
        try await request("GET", "/api/computer", query: nodeQuery(node), as: ComputerState.self)
    }
    func usage() async throws -> Usage { try await request("GET", "/api/usage", as: Usage.self) }
    func models() async throws -> ModelCatalog { try await request("GET", "/api/models", as: ModelCatalog.self) }
    func usageDetails(range: String, source: String, refresh: Bool) async throws -> UsageDetails {
        try await request("GET", "/api/usage/details", query: [URLQueryItem(name: "range", value: range),
                                                             URLQueryItem(name: "source", value: source),
                                                             URLQueryItem(name: "refresh", value: refresh ? "1" : "0")],
                          as: UsageDetails.self)
    }
    func usageLimits(refresh: Bool) async throws -> UsageLimits {
        try await request("GET", "/api/usage/limits", query: [URLQueryItem(name: "refresh", value: refresh ? "1" : "0")],
                          as: UsageLimits.self)
    }
    func registerDevice(_ registration: DeviceRegistration) async throws {
        try await ok("POST", "/api/devices", body: registration)
    }

    // MARK: Geteilte Scoops (docs/sharing.md)

    func refreshShares() async throws {
        do { try await ok("POST", "/api/shares/refresh") } catch let e as APIError where e.status == 404 || e.status == 405 {
            // älterer Server: übernimmt die Shares mit dem nächsten Herzschlag
        }
    }

    func registerGuestDevice(_ registration: DeviceRegistration) async throws {
        try await ok("POST", SharingEndpoints.guestDevices, body: registration)
    }

    func botUsage(botID: String) async throws -> BotUsage {
        try await request("GET", "/api/bots/\(botID)/usage", as: BotUsage.self)
    }

    func sharingSettings(botID: String) async throws -> SharingSettings {
        try await request("GET", "/api/bots/\(botID)/sharing", as: SharingSettings.self)
    }

    func unregisterGuestDevice(token: String) async throws {
        struct Body: Encodable { var apnsToken: String }
        try await ok("DELETE", SharingEndpoints.guestDevices, body: Body(apnsToken: token))
    }

    // MARK: Gruppen

    func groups() async throws -> [ChatGroup] { try await request("GET", "/api/groups", as: [ChatGroup].self) }

    func createGroup(name: String, memberIDs: [String]) async throws -> ChatGroup {
        struct Body: Encodable { var name: String; var memberIds: [String] }
        return try await request("POST", "/api/groups", body: Body(name: name, memberIds: memberIDs), as: ChatGroup.self)
    }

    func updateGroup(id: String, patch: GroupPatch) async throws -> ChatGroup {
        try await request("PATCH", "/api/groups/\(id)", body: patch, as: ChatGroup.self)
    }

    func deleteGroup(id: String) async throws { try await ok("DELETE", "/api/groups/\(id)") }

    // MARK: Bibliothek

    func files(chatID: String) async throws -> [LibraryFile] {
        try await request("GET", "/api/chats/\(chatID)/files", as: [LibraryFile].self)
    }

    func uploadFile(chatID: String, name: String, mime: String, data: Data,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> LibraryFile {
        var req = URLRequest(url: url("/api/chats/\(chatID)/files", query: [URLQueryItem(name: "name", value: name)]))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(try await auth.valid())", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (body, response) = try await session.upload(for: req, from: data, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: body, decoder: decoder)
        }
        progress(1)
        return try decoder.decode(LibraryFile.self, from: body)
    }

    func deleteFile(id: String) async throws { try await ok("DELETE", "/api/files/\(id)") }

    func fileURL(id: String) -> URL? {
        url("/api/files/\(id)", query: [URLQueryItem(name: "token", value: token)])
    }

    func downloadFile(_ file: LibraryFile) async throws -> URL {
        let target = url("/api/files/\(file.id)")
        let (data, status) = try await send { _ in URLRequest(url: target) }
        guard status == 200 else {
            throw APIError(status: status, message: String(localized: "Datei konnte nicht geladen werden."))
        }
        return try FileCache.store(data, name: file.name, id: file.id)
    }

    // MARK: Eigenes Scoop-Bild (v1.12)

    func uploadAvatar(botID: String, data: Data) async throws -> Bot {
        let target = url("/api/bots/\(botID)/avatar")
        let (body, status) = try await send { _ in
            var req = URLRequest(url: target)
            req.httpMethod = "PUT"
            req.timeoutInterval = 60
            req.setValue(ScoopPhotoCoding.mimeType(of: data), forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            return req
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: body, decoder: decoder)
        }
        return try decoder.decode(Bot.self, from: body)
    }

    func deleteAvatar(botID: String) async throws -> Bot {
        try await request("DELETE", "/api/bots/\(botID)/avatar", as: Bot.self)
    }

    func avatarData(botID: String, version: Int) async throws -> Data {
        let target = url("/api/bots/\(botID)/avatar", query: [URLQueryItem(name: "v", value: String(version))])
        let (data, status) = try await send { _ in URLRequest(url: target) }
        guard status == 200 else { throw APIError(status: status, message: String(localized: "Bild konnte nicht geladen werden.")) }
        return data
    }

    // MARK: Apps verbinden (v1.8)

    func connections(fresh: Bool) async throws -> ConnectionsOverview {
        try await request("GET", "/api/connections", query: fresh ? [URLQueryItem(name: "fresh", value: "true")] : [],
                          as: ConnectionsOverview.self)
    }
    func linkConnection(app: String, alias: String?) async throws -> ConnectionLink {
        // `native`: Diese App fängt Rücksprünge `aisscoops://oauth/…` ab (Notion direkt, Server 1.25).
        struct Body: Encodable { var alias: String?; var native = true }
        return try await request("POST", "/api/connections/\(app)/link", body: Body(alias: alias), as: ConnectionLink.self)
    }
    func finishOAuth(callbackURL: String) async throws -> ConnectedAccount {
        struct Body: Encodable { var url: String }
        return try await request("POST", "/api/connections/oauth/callback", body: Body(url: callbackURL), as: ConnectedAccount.self)
    }
    func connectedAccount(id: String) async throws -> ConnectedAccount {
        try await request("GET", "/api/connections/accounts/\(id)", as: ConnectedAccount.self)
    }
    func renameConnectedAccount(id: String, alias: String) async throws -> ConnectedAccount {
        struct Body: Encodable { var alias: String }
        return try await request("PATCH", "/api/connections/accounts/\(id)", body: Body(alias: alias), as: ConnectedAccount.self)
    }
    func reconnectAccount(id: String) async throws -> ConnectionLink {
        try await request("POST", "/api/connections/accounts/\(id)/reconnect", as: ConnectionLink.self)
    }
    func deleteConnectedAccount(id: String) async throws { try await ok("DELETE", "/api/connections/accounts/\(id)") }

    // MARK: Eigene MCP-Server (v1.35, docs/mcp.md)

    func mcpServers() async throws -> MCPServerList { try await request("GET", "/api/mcp-servers", as: MCPServerList.self) }
    func probeMCP(url: String) async throws -> MCPProbe {
        try await request("POST", "/api/mcp-servers/probe", body: ["url": url], as: MCPProbe.self)
    }
    func addMCP(_ body: MCPAddRequest) async throws -> MCPAddResult {
        // Body mit Token wird nirgends protokolliert
        try await request("POST", "/api/mcp-servers", body: body, as: MCPAddResult.self)
    }
    func updateMCP(id: String, name: String?, token: String?, header: String?) async throws -> MCPServerList {
        struct Body: Encodable { var name: String?; var token: String?; var header: String? }
        return try await request("PATCH", "/api/mcp-servers/\(id)", body: Body(name: name, token: token, header: header),
                                 as: MCPServerList.self)
    }
    func deleteMCP(id: String) async throws -> MCPServerList {
        try await request("DELETE", "/api/mcp-servers/\(id)", as: MCPServerList.self)
    }
    func loginMCP(id: String) async throws -> MCPLoginLink {
        try await request("POST", "/api/mcp-servers/\(id)/login", as: MCPLoginLink.self)
    }
    func testMCP(id: String) async throws -> MCPTestResult {
        try await request("POST", "/api/mcp-servers/\(id)/test", as: MCPTestResult.self)
    }
    func decideSecrets(approvalID: String, approve: Bool, secrets: [KeyValue]) async throws -> Message {
        struct Edits: Encodable { var secrets: [KeyValue] }
        struct Body: Encodable { var decision: String; var edits: Edits? }
        return try await request("POST", "/api/approvals/\(approvalID)",
                                 body: Body(decision: approve ? "approve" : "decline", edits: approve ? Edits(secrets: secrets) : nil),
                                 as: Message.self)
    }

    // MARK: Apps verbinden: Katalog (v1.16)

    func connectionCatalog(category: String?, query: String?, offset: Int, limit: Int) async throws -> CatalogPage {
        var items = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
        if let category, !category.isEmpty { items.append(URLQueryItem(name: "category", value: category)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await request("GET", "/api/connections/catalog", query: items, as: CatalogPage.self)
    }
    func connectionCategories() async throws -> [CatalogCategory] {
        try await request("GET", "/api/connections/categories", as: CatalogCategoryList.self).categories
    }
    func connectionAuth(app: String) async throws -> AppAuthInfo {
        try await request("GET", "/api/connections/catalog/\(app)", as: AppAuthInfo.self)
    }
    func connectWithFields(app: String, alias: String?, fields: [AuthFieldValue]) async throws -> ConnectResult {
        struct Body: Encodable { var alias: String?; var fields: [AuthFieldValue] }
        return try await request("POST", "/api/connections/\(app)/connect", body: Body(alias: alias, fields: fields),
                                 as: ConnectResult.self)
    }
    func connectionLogo(app: String) async throws -> Data {
        let target = url("/api/connections/logo/\(app)")
        let (data, status) = try await send { _ in URLRequest(url: target) }
        guard status == 200 else { throw APIError(status: status, message: String(localized: "Kein Logo.")) }
        return data
    }

    // MARK: Bereiche (v1.6)

    func sections() async throws -> [SidebarSection] {
        try await request("GET", "/api/sections", as: SectionList.self).sections
    }
    func saveSections(_ sections: [SidebarSection]) async throws -> [SidebarSection] {
        // Antwort laut API wie GET; falls der Server nur {"ok": true} schickt, gilt die gesendete Liste
        var req = SectionList(sections: sections)
        if let resp = try? await request("PUT", "/api/sections", body: req, as: SectionList.self) { req = resp }
        else { _ = try await ok("PUT", "/api/sections", body: SectionList(sections: sections)) }
        return req.sections
    }
    func renameSection(from: String, to: String) async throws {
        struct Body: Encodable { var from: String; var to: String }
        try await ok("POST", "/api/sections/rename", body: Body(from: from, to: to))
    }
    func deleteSection(name: String) async throws {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        try await ok("DELETE", "/api/sections/\(escaped)")
    }

    // MARK: Arbeitsordner der Scoops (Server 1.27)

    func workspace() async throws -> WorkspaceStatus {
        try await request("GET", "/api/settings/workspace", as: WorkspaceStatus.self)
    }
    // v1.30: KI-Abos
    func abos() async throws -> AboStatus {
        try await request("GET", "/api/settings/abos", as: AboStatus.self)
    }
    func setAboMode(provider: String, mode: String) async throws -> AboStatus {
        try await request("PATCH", "/api/settings/abos", body: [provider: mode], as: AboStatus.self)
    }
    func startAboLogin(provider: String) async throws {
        _ = try await request("POST", "/api/settings/abos/\(provider)/login", as: OKResponse.self)
    }
    // v1.36: Computer Use von Codex für ChatGPT-Scoops
    func setCodexComputerUse(_ enabled: Bool) async throws -> AboStatus {
        try await request("PATCH", "/api/settings/abos", body: ["codex_computer_use": enabled], as: AboStatus.self)
    }
    func setWorkspace(path: String) async throws -> WorkspaceStatus {
        try await request("PATCH", "/api/settings/workspace", body: ["path": path], as: WorkspaceStatus.self)
    }
    func browseWorkspace(path: String) async throws -> WorkspaceListing {
        try await request("GET", "/api/settings/workspace/browse", query: [URLQueryItem(name: "path", value: path)],
                          as: WorkspaceListing.self)
    }
    func createWorkspaceFolder(parent: String, name: String) async throws -> WorkspaceListing {
        try await request("POST", "/api/settings/workspace/folder", body: ["parent": parent, "name": name],
                          as: WorkspaceListing.self)
    }

    // MARK: Haupt-Scoop, Fähigkeiten, Tresor (v1.4)

    func initiative() async throws -> InitiativeSettings {
        try await request("GET", "/api/settings/initiative", as: InitiativeSettings.self)
    }
    func updateInitiative(_ patch: InitiativePatch) async throws -> InitiativeSettings {
        try await request("PATCH", "/api/settings/initiative", body: patch, as: InitiativeSettings.self)
    }
    func runInitiative() async throws { try await ok("POST", "/api/initiative/run") }

    func skills(botID: String?) async throws -> [Skill] {
        if let botID { return try await request("GET", "/api/bots/\(botID)/skills", as: [Skill].self) }
        return try await request("GET", "/api/skills", as: [Skill].self)
    }
    func updateSkill(id: String, patch: SkillPatch) async throws -> Skill {
        try await request("PATCH", "/api/skills/\(id)", body: patch, as: Skill.self)
    }
    func deleteSkill(id: String) async throws { try await ok("DELETE", "/api/skills/\(id)") }

    func vault() async throws -> [VaultEntry] { try await request("GET", "/api/vault", as: [VaultEntry].self) }
    func createVaultEntry(_ draft: VaultDraft) async throws -> VaultEntry {
        try await request("POST", "/api/vault", body: draft, as: VaultEntry.self)
    }
    func updateVaultEntry(id: String, draft: VaultDraft) async throws -> VaultEntry {
        try await request("PATCH", "/api/vault/\(id)", body: draft, as: VaultEntry.self)
    }
    func deleteVaultEntry(id: String) async throws { try await ok("DELETE", "/api/vault/\(id)") }

    // MARK: Spracherkennung

    func transcribe(audio: Data, name: String, language: String, prompt: String?, timeout: TimeInterval) async throws -> String {
        var query = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "language", value: language)] + guestQuery
        if let prompt, !prompt.isEmpty { query.append(URLQueryItem(name: "prompt", value: prompt)) }
        var req = URLRequest(url: url("/api/transcribe", query: query))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(try await auth.valid())", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: req, from: audio)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: body, decoder: decoder)
        }
        struct Result: Decodable { var text: String }
        return try decoder.decode(Result.self, from: body).text
    }

    // MARK: Live-Sprechmodus (v1.13)

    func liveVoiceInfo() async throws -> LiveVoiceInfo {
        do {
            return try await request("GET", "/api/voice/live", query: guestQuery, as: LiveVoiceInfo.self)
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            return .unavailable  // älterer Server
        }
    }

    func liveVoiceRequest(chatID: String) async throws -> URLRequest {
        let bearer = try await auth.valid()
        var comps = URLComponents(url: baseURL.appending(path: "/api/voice/live"), resolvingAgainstBaseURL: false)!
        comps.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        // Sprache (docs/sprache.md): Ohne gespeicherte Sprache nimmt der Server `lang` bzw. `Accept-Language`
        comps.queryItems = [URLQueryItem(name: "chat", value: chatID), URLQueryItem(name: "lang", value: AppLanguage.code)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        return req
    }

    func liveVoicePreview(voice: String) async throws -> Data {
        var req = URLRequest(url: url("/api/voice/live/preview", query: guestQuery))
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("Bearer \(try await auth.valid())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["voice": voice])
        let (body, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: body, decoder: decoder)
        }
        return body
    }

    // MARK: Bot-Rechner übernehmen

    func takeover(node: String) async throws -> ComputerState {
        try await request("POST", "/api/computer/takeover", query: nodeQuery(node), as: ComputerState.self)
    }

    func release(node: String) async throws { try await ok("POST", "/api/computer/release", query: nodeQuery(node)) }

    func computerInput(_ input: ComputerInput, node: String) async throws {
        try await ok("POST", "/api/computer/input", query: nodeQuery(node), body: input)
    }

    // MARK: Rechner (v1.11)

    func nodes() async throws -> [ComputerNode] { try await request("GET", "/api/nodes", as: [ComputerNode].self) }
    func pairNode() async throws -> NodePairing { try await request("POST", "/api/nodes/pair", as: NodePairing.self) }
    func renameNode(id: String, name: String) async throws -> ComputerNode {
        struct Body: Encodable { var name: String }
        return try await request("PATCH", "/api/nodes/\(id)", body: Body(name: name), as: ComputerNode.self)
    }
    func deleteNode(id: String) async throws { try await ok("DELETE", "/api/nodes/\(id)") }

    func appleStatus() async throws -> AppleStatus { try await request("GET", "/api/apple", as: AppleStatus.self) }
    func updateApple(_ patch: ApplePatch) async throws -> AppleStatus {
        try await request("PATCH", "/api/apple", body: patch, as: AppleStatus.self)
    }

    // MARK: Gerätekanal (v1.18)

    func sendDeviceMessage(_ text: String) -> Bool { socket.send(text) }

    /// Rohe JSON-Anfrage mit einfachem Decoder (Befehlsparameter bleiben snake_case).
    private func rawJSON(_ method: String, _ path: String, body: Data) async throws -> Data {
        let target = url(path)
        let (data, status) = try await send { _ in
            var req = URLRequest(url: target)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            return req
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: data, decoder: decoder)
        }
        return data
    }

    func registerAppleDevice(_ hello: AppleDeviceHello) async throws -> [AppleDeviceCommand] {
        let data = try await rawJSON("POST", "/api/apple/device", body: try encoder.encode(hello))
        return (try? JSONDecoder().decode(AppleDeviceCommands.self, from: data))?.commands ?? []
    }

    func pollAppleDevice(deviceID: String) async throws -> [AppleDeviceCommand] {
        let body: JSONValue = ["device_id": .string(deviceID)]
        let data = try await rawJSON("POST", "/api/apple/device/poll", body: body.encoded())
        return try JSONDecoder().decode(AppleDeviceCommands.self, from: data).commands
    }

    func sendAppleResult(deviceID: String, commandID: String, result: JSONValue) async throws {
        let body: JSONValue = ["device_id": .string(deviceID), "id": .string(commandID), "result": result]
        _ = try await rawJSON("POST", "/api/apple/device/result", body: body.encoded())
    }

    func sendAppleEvent(deviceID: String, event: JSONValue) async throws {
        var o = event.object ?? [:]
        o["device_id"] = .string(deviceID)
        _ = try await rawJSON("POST", "/api/apple/device/event", body: JSONValue.object(o).encoded())
    }

    func removeAppleDevice(id: String) async throws -> AppleStatus {
        try await request("DELETE", "/api/apple/device/\(id)", as: AppleStatus.self)
    }

    // MARK: Live-Aktivität

    func registerLiveActivity(chatID: String, runID: String, pushToken: String) async throws {
        struct Body: Encodable { var chatId: String; var runId: String; var pushToken: String }
        try await ok("POST", "/api/live-activities", body: Body(chatId: chatID, runId: runID, pushToken: pushToken))
    }

    #if os(iOS)
    /// Antwort ist camelCase mit ActivityKit-Datum (Sekunden seit 2001), daher eigener Decoder statt `request`.
    func liveActivityStatus(ensure: Bool) async throws -> ScoopsLiveStatus {
        let target = url(ensure ? "/api/live-activity/ensure" : "/api/live-activity")
        let (data, status) = try await send { _ in
            var req = URLRequest(url: target)
            req.httpMethod = ensure ? "POST" : "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: data, decoder: decoder)
        }
        return try ScoopsLiveStatus.decode(data)
    }
    #endif

    func screenImageURL(scale: Double, quality: Int, node: String) -> URL? {
        url("/api/computer/screen.jpg", query: [
            URLQueryItem(name: "scale", value: String(format: "%.2f", min(1, max(0.25, scale)))),
            URLQueryItem(name: "q", value: String(min(90, max(20, quality)))),
            URLQueryItem(name: "token", value: token),
        ] + nodeQuery(node))
    }

    func connectEvents() {
        guard auth.kind == .account else { socket.connect(); return }
        Task { [weak self] in
            await self?.prepareSocket()
            self?.socket.connect()
        }
    }
    func disconnectEvents() { socket.disconnect() }
    func reconnectEvents() {
        guard auth.kind == .account else { socket.reconnectNow(); return }
        Task { [weak self] in
            await self?.prepareSocket()
            self?.socket.reconnectNow()
        }
    }

    /// Lädt das aktuelle Bildschirmfoto (kurzer Timeout, damit schwache Verbindungen nicht endlos warten).
    static func fetchScreen(_ url: URL, timeout: TimeInterval = 5) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        let (data, response) = try await screenSession.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static let screenSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.httpMaximumConnectionsPerHost = 1
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["Accept-Language": AppLanguage.acceptLanguage]
        return URLSession(configuration: c)
    }()
}

/// Meldet den Upload-Fortschritt einer einzelnen Anfrage.
nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// Temporäre Ablage für geöffnete Dateien (Quick Look, Teilen).
nonisolated enum FileCache {
    static func store(_ data: Data, name: String, id: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "AISBotFiles/\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appending(path: safe.isEmpty ? "Datei" : safe)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Seite „Heute“

extension APIClient: TodayService {
    func todayOverview(since: Date?) async throws -> TodayOverview {
        let query = since.map { [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: $0))] } ?? []
        return try await request("GET", "/api/today", query: query, as: TodayOverview.self)
    }
}

// MARK: - Aufgaben-Board (v1.22)

extension APIClient: TaskBoardService {
    private struct TaskMessage: Encodable { var message: String? }

    func boardTasks(botID: String?, limit: Int) async throws -> [BotTask] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let botID { query.append(URLQueryItem(name: "bot", value: botID)) }
        return try await request("GET", "/api/tasks", query: query, as: [BotTask].self)
    }

    func task(id: String) async throws -> BotTask {
        try await request("GET", "/api/tasks/\(id)", as: BotTask.self)
    }

    func createTask(_ draft: TaskDraft) async throws -> BotTask {
        try await request("POST", "/api/tasks", body: draft, as: BotTask.self)
    }

    func updateTask(id: String, patch: TaskPatch) async throws -> BotTask {
        try await request("PATCH", "/api/tasks/\(id)", body: patch, as: BotTask.self)
    }

    func deleteTask(id: String) async throws {
        try await ok("DELETE", "/api/tasks/\(id)")
    }

    func taskAction(id: String, action: TaskAction, message: String?) async throws -> BotTask {
        try await request("POST", "/api/tasks/\(id)/\(action.rawValue)", body: TaskMessage(message: message), as: BotTask.self)
    }
}
