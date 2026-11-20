import Foundation

// MARK: - Schlanker Zugang zum Server für Erweiterungen und Intents (docs/system.md)
//
// Teilen-Menü und Kurzbefehle sprechen selbst per URLSession mit dem Server des jeweiligen Chats. Adressen
// kommen aus `SystemDirectory`, Zugangsdaten aus dem Schlüsselbund (`SharedKeychain`). Läuft die App, nimmt sie
// stattdessen ihre eigene Verbindung (`SystemBridge.appService`).

nonisolated struct SystemError: LocalizedError, Sendable {
    enum Kind: Sendable {
        /// Kein Server verbunden bzw. keine Zugangsdaten für Erweiterungen
        case notConnected
        /// Server nicht erreichbar (Netz, Zeitüberschreitung)
        case offline
        /// Anmeldung abgelaufen; die App erneuert sie beim nächsten Öffnen
        case unauthorized
        /// Kein Schreibrecht (geteilter Scoop mit Rolle „Lesen“)
        case forbidden
        /// Chat gibt es auf diesem Server nicht (mehr)
        case notFound
        case tooLarge
        case server
    }

    var kind: Kind
    var message: String
    var status: Int = 0

    var errorDescription: String? { message }

    /// Später noch einmal versuchen lohnt (Ablage statt Verlust)
    var isTransient: Bool {
        switch kind {
        case .offline, .unauthorized: true
        case .server: status >= 500 || status == 429 || status == 408
        default: false
        }
    }

    static var notConnected: SystemError {
        SystemError(kind: .notConnected, message: String(localized: "Öffne AIS Scoops und verbinde dich mit deinem Server."))
    }
    static var offline: SystemError {
        SystemError(kind: .offline, message: String(localized: "Der Server ist gerade nicht erreichbar."))
    }
    static var unauthorized: SystemError {
        SystemError(kind: .unauthorized, message: String(localized: "Die Anmeldung ist abgelaufen. Öffne AIS Scoops einmal."),
                    status: 401)
    }

    static func from(_ error: Error) -> SystemError {
        if let e = error as? SystemError { return e }
        if error is URLError || error is CancellationError { return .offline }
        return SystemError(kind: .server, message: error.localizedDescription)
    }
}

/// Gesendete Nachricht (nur was Intents brauchen)
nonisolated struct SystemSentMessage: Sendable {
    var id: String
    var createdAt: Date
}

nonisolated struct SystemTaskRef: Sendable {
    var id: String
    var title: String
}

/// Was Erweiterungen und Intents mit einem Chat tun können.
nonisolated protocol SystemService: Sendable {
    func send(chatID: String, text: String, fileIDs: [String]) async throws -> SystemSentMessage
    /// Lädt eine Datei von der Platte hoch (ohne sie in den Speicher zu laden). Liefert die Datei-ID.
    func upload(chatID: String, file: URL, name: String, mime: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// Aufgabe im Board anlegen (startet sofort)
    func createTask(chatID: String, actorID: String?, title: String?, prompt: String) async throws -> SystemTaskRef
    /// Neueste Nachrichten, aufsteigend nach Zeit
    func recentMessages(chatID: String, limit: Int) async throws -> [Message]
}

/// Verbindung zwischen System-Einstiegen (Intents, Links) und der laufenden App. In Erweiterungen bleibt alles leer.
@MainActor
final class SystemBridge {
    static let shared = SystemBridge()

    /// Öffnet einen Link in der App (`DeepLinkRouter`). Solange die App noch startet, wird er vorgemerkt.
    var linkHandler: ((DeepLink) -> Void)? {
        didSet {
            guard let linkHandler, !pendingLinks.isEmpty else { return }
            let links = pendingLinks
            pendingLinks = []
            links.forEach(linkHandler)
        }
    }
    private var pendingLinks: [DeepLink] = []

    /// Verbindung der laufenden App für diesen Chat (auch Demo-Modus); nil = selbst verbinden
    var appService: ((SystemChat) -> SystemService?)?
    /// Gültiges Sitzungs-JWT aus der App (`force`: nach einem 401 sofort erneuern)
    var accountToken: (@Sendable (_ force: Bool) async -> String?)?

    func open(_ link: DeepLink) {
        if let linkHandler { linkHandler(link) } else { pendingLinks.append(link) }
    }
}

/// Einstieg: passender Dienst für einen Chat.
nonisolated enum SystemAccess {
    /// Chat aus dem Verzeichnis, sonst ein klarer Fehler
    static func chat(_ id: String, in directory: SystemDirectory = .current()) throws -> SystemChat {
        guard let chat = directory.chat(id) else {
            throw SystemError(kind: directory.isEmpty ? .notConnected : .notFound,
                              message: directory.isEmpty ? SystemError.notConnected.message
                                : String(localized: "Diesen Scoop gibt es nicht mehr. Öffne AIS Scoops, um die Liste zu aktualisieren."))
        }
        return chat
    }

    static func service(for chat: SystemChat, directory: SystemDirectory = .current()) async throws -> SystemService {
        if let live = await MainActor.run(body: { SystemBridge.shared.appService?(chat) }) { return live }
        if directory.demo { return DemoSystemService(directory: directory) }
        guard let server = directory.server(chat.serverID), !server.baseURLs.isEmpty else { throw SystemError.notConnected }
        return RemoteSystemService(server: server, cloudSiteURL: directory.cloudSiteURL)
    }
}

// MARK: - Zugangsdaten

/// Sitzung des Kontos, wie die App sie im Schlüsselbund ablegt (nur die Felder, die Erweiterungen brauchen)
private nonisolated struct StoredSession: Decodable {
    var token: String
    var refreshToken: String?
    var expiresAt: Date?

    var expiry: Date? { expiresAt ?? SystemJWT.expiry(token) }
}

nonisolated enum SystemJWT {
    /// Ablauf (`exp`) eines JWT, ohne die Signatur zu prüfen (das tut der Server)
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Bearer für einen Server: API-Token oder Sitzungs-JWT. Erweiterungen erneuern ein abgelaufenes JWT nur für
/// sich im Speicher (`/auth/refresh` vergibt kein neues Refresh-Token, docs/accounts.md); in den Schlüsselbund
/// schreibt allein die App.
actor SystemCredentials {
    static let shared = SystemCredentials()

    private var renewed: (token: String, expiry: Date?)?

    func bearer(for server: SystemServer, cloudSiteURL: String?, force: Bool = false) async throws -> String {
        guard server.usesAccount else {
            guard let token = SharedKeychain.read(account: SharedKeychain.tokenAccount), !token.isEmpty else {
                throw SystemError.notConnected
            }
            return token
        }
        // Läuft die App, liefert sie das JWT (und erneuert es wie gewohnt)
        if let provider = await MainActor.run(body: { SystemBridge.shared.accountToken }) {
            if let token = await provider(force), !token.isEmpty { return token }
            throw SystemError.unauthorized
        }
        if !force, let renewed, (renewed.expiry ?? .distantFuture).timeIntervalSinceNow > 60 { return renewed.token }
        guard let raw = SharedKeychain.read(account: SharedKeychain.sessionAccount), let data = raw.data(using: .utf8),
              let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            throw SystemError.notConnected
        }
        if !force, (session.expiry ?? .distantFuture).timeIntervalSinceNow > 60 { return session.token }
        guard let fresh = await renew(session, cloudSiteURL: cloudSiteURL) else { throw SystemError.unauthorized }
        return fresh
    }

    private func renew(_ session: StoredSession, cloudSiteURL: String?) async -> String? {
        struct Body: Encodable { var refreshToken: String }
        struct Response: Decodable { var token: String; var expiresAt: Double? }
        guard let refreshToken = session.refreshToken, let cloudSiteURL, let site = URL(string: cloudSiteURL) else { return nil }
        var req = URLRequest(url: site.appending(path: "/auth/refresh"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(refreshToken: refreshToken))
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let out = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        renewed = (out.token, out.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? SystemJWT.expiry(out.token))
        return out.token
    }
}

// MARK: - Echter Server

nonisolated struct RemoteSystemService: SystemService {
    let server: SystemServer
    let cloudSiteURL: String?

    /// Größte Datei, die der Server annimmt (docs/API.md, Bibliothek)
    static let maxUploadBytes = 25 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func chatBase(_ id: String) -> String {
        ChatGroup.isGroupID(id) ? "/api/groups/\(id)" : "/api/bots/\(id)"
    }

    func send(chatID: String, text: String, fileIDs: [String]) async throws -> SystemSentMessage {
        struct Body: Encodable { var text: String; var fileIds: [String]? }
        let body = try JSONCoding.makeEncoder().encode(Body(text: text, fileIds: fileIDs.isEmpty ? nil : fileIDs))
        let data = try await perform("POST", "\(chatBase(chatID))/messages", body: .json(body))
        let message = try decode(Message.self, from: data)
        return SystemSentMessage(id: message.id, createdAt: message.createdAt)
    }

    func upload(chatID: String, file: URL, name: String, mime: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxUploadBytes else {
            throw SystemError(kind: .tooLarge, message: String(localized: "„\(name)“ ist größer als 25 MB."), status: 413)
        }
        let data = try await perform("POST", "/api/chats/\(chatID)/files", query: [URLQueryItem(name: "name", value: name)],
                                     body: .file(file, mime: mime), timeout: 180, progress: progress)
        progress(1)
        return try decode(LibraryFile.self, from: data).id
    }

    func createTask(chatID: String, actorID: String?, title: String?, prompt: String) async throws -> SystemTaskRef {
        struct Body: Encodable { var chatId: String; var actorId: String?; var prompt: String; var title: String? }
        struct Legacy: Encodable { var prompt: String; var title: String?; var actorId: String? }
        let encoder = JSONCoding.makeEncoder()
        do {
            let body = try encoder.encode(Body(chatId: chatID, actorId: actorID, prompt: prompt, title: title))
            let task = try decode(BotTask.self, from: try await perform("POST", "/api/tasks", body: .json(body)))
            return SystemTaskRef(id: task.id, title: task.title)
        } catch let error as SystemError where error.status == 404 || error.status == 405 {
            // Server vor 1.22 (ohne Board): Aufgabe über den Chat anlegen (v1.19)
            let body = try encoder.encode(Legacy(prompt: prompt, title: title, actorId: actorID))
            do {
                let task = try decode(BotTask.self, from: try await perform("POST", "\(chatBase(chatID))/tasks", body: .json(body)))
                return SystemTaskRef(id: task.id, title: task.title)
            } catch let error as SystemError where error.status == 404 || error.status == 405 {
                throw SystemError(kind: .server, message: String(localized: "Dein Server kennt noch keine Aufgaben. Bitte aktualisiere ihn."),
                                  status: error.status)
            }
        }
    }

    func recentMessages(chatID: String, limit: Int) async throws -> [Message] {
        let data = try await perform("GET", "\(chatBase(chatID))/messages",
                                     query: [URLQueryItem(name: "limit", value: String(limit))])
        return try decode([Message].self, from: data)
    }

    // MARK: Anfragen

    private enum Payload {
        case json(Data)
        case file(URL, mime: String)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.makeDecoder().decode(type, from: data)
        } catch {
            throw SystemError(kind: .server, message: String(localized: "Unerwartete Antwort vom Server."))
        }
    }

    private struct ErrorBody: Decodable { var error: String? }

    /// Probiert die Adressen der Reihe nach. Nach einem 401 mit Konto-Sitzung einmal mit frischem JWT.
    private func perform(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Payload? = nil,
                         timeout: TimeInterval = 20, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var bearer = try await SystemCredentials.shared.bearer(for: server, cloudSiteURL: cloudSiteURL)
        var (data, status) = try await attempt(method, path, query: query, body: body, bearer: bearer, timeout: timeout,
                                               progress: progress)
        if status == 401, server.usesAccount {
            bearer = try await SystemCredentials.shared.bearer(for: server, cloudSiteURL: cloudSiteURL, force: true)
            (data, status) = try await attempt(method, path, query: query, body: body, bearer: bearer, timeout: timeout,
                                               progress: progress)
        }
        guard (200..<300).contains(status) else {
            let text = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            switch status {
            case 401: throw SystemError.unauthorized
            case 403: throw SystemError(kind: .forbidden, message: text ?? String(localized: "Dafür fehlt dir hier die Berechtigung."), status: status)
            case 404: throw SystemError(kind: .notFound, message: text ?? String(localized: "Diesen Chat gibt es auf dem Server nicht mehr."), status: status)
            case 413: throw SystemError(kind: .tooLarge, message: text ?? String(localized: "Die Datei ist zu groß (höchstens 25 MB)."), status: status)
            default:
                throw SystemError(kind: .server, message: text ?? HTTPURLResponse.localizedString(forStatusCode: status),
                                  status: status)
            }
        }
        return data
    }

    private func attempt(_ method: String, _ path: String, query: [URLQueryItem], body: Payload?, bearer: String,
                         timeout: TimeInterval, progress: (@Sendable (Double) -> Void)?) async throws -> (Data, Int) {
        for base in server.baseURLs {
            var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
            req.httpMethod = method
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            // Sprache der App (docs/sprache.md): Fehlermeldungen des Servers in derselben Sprache
            req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response): (Data, URLResponse)
                switch body {
                case .json(let payload):
                    req.httpBody = payload
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    (data, response) = try await Self.session.data(for: req)
                case .file(let url, let mime):
                    req.setValue(mime, forHTTPHeaderField: "Content-Type")
                    (data, response) = try await Self.session.upload(for: req, fromFile: url,
                                                                     delegate: progress.map(SystemUploadProgress.init))
                case nil:
                    (data, response) = try await Self.session.data(for: req)
                }
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                // Schreibende Anfragen nur an der nächsten Adresse wiederholen, wenn sie den Server sicher nicht
                // erreicht haben (sonst käme eine Nachricht doppelt an)
                if method != "GET", !Self.neverReachedServer(error) { break }
            }
        }
        throw SystemError.offline
    }

    private static func neverReachedServer(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection, .internationalRoamingOff,
                .dataNotAllowed].contains(e.code)
    }
}

/// Fortschritt eines Uploads (0…1)
private nonisolated final class SystemUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

// MARK: - Demo-Modus

/// Spielt Senden, Hochladen und Antworten nach, wenn die App zuletzt im Demo-Modus lief (`-mock`) und gerade
/// nicht selbst antworten kann (Erweiterung, Kurzbefehl ohne laufende App).
nonisolated struct DemoSystemService: SystemService {
    let directory: SystemDirectory

    private func checkOnline() throws {
        if directory.demoOffline { throw SystemError.offline }
    }

    func send(chatID: String, text: String, fileIDs: [String]) async throws -> SystemSentMessage {
        try checkOnline()
        try await Task.sleep(for: .milliseconds(450))
        DemoReplies.remember(question: text, chatID: chatID)
        return SystemSentMessage(id: "m_demo_\(UUID().uuidString.prefix(8))", createdAt: Date())
    }

    func upload(chatID: String, file: URL, name: String, mime: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try checkOnline()
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(110))
            progress(Double(step) / 6)
        }
        return "f_demo_\(UUID().uuidString.prefix(8))"
    }

    func createTask(chatID: String, actorID: String?, title: String?, prompt: String) async throws -> SystemTaskRef {
        try checkOnline()
        try await Task.sleep(for: .milliseconds(400))
        let fallback = prompt.split(separator: "\n").first.map(String.init) ?? demoText("Aufgabe", en: "Task")
        return SystemTaskRef(id: "t_demo_\(UUID().uuidString.prefix(8))", title: title ?? fallback)
    }

    func recentMessages(chatID: String, limit: Int) async throws -> [Message] {
        try checkOnline()
        guard let pending = DemoReplies.pending(chatID: chatID) else { return [] }
        // Antwort erscheint nach gut zwei Sekunden
        guard Date().timeIntervalSince(pending.askedAt) > 2.2 else { return [] }
        let name = directory.chat(chatID)?.name ?? "Scoop"
        return [Message(id: "m_demo_reply", botId: chatID, role: .bot,
                        text: DemoReplies.answer(to: pending.question, name: name),
                        createdAt: pending.askedAt.addingTimeInterval(2.2))]
    }
}

/// Merkt sich die letzte Demo-Frage je Chat (nur im Speicher des Prozesses).
private nonisolated enum DemoReplies {
    struct Pending: Sendable { var question: String; var askedAt: Date }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: Pending] = [:]

    static func remember(question: String, chatID: String) {
        lock.withLock { store[chatID] = Pending(question: question, askedAt: Date()) }
    }

    static func pending(chatID: String) -> Pending? { lock.withLock { store[chatID] } }

    static func answer(to question: String, name: String) -> String {
        let q = question.lowercased()
        if q.contains("wetter") || q.contains("weather") {
            return demoText("Heute bleibt es trocken bei 9 Grad, am Nachmittag kommt die Sonne durch.",
                            en: "It’ll stay dry today at 48°F, with sun breaking through in the afternoon.")
        }
        if q.contains("termin") || q.contains("kalender") || q.contains("calendar") || q.contains("meeting") {
            return demoText("Du hast heute zwei Termine: um 10 Uhr das Team-Update und um 15:30 Uhr den Zahnarzt.",
                            en: "You have two events today: the team update at 10 AM and the dentist at 3:30 PM.")
        }
        return demoText("Hier ist \(name) aus dem Demo-Modus. Ich habe deine Frage bekommen: „\(question)“. "
                            + "Mit einem echten Server antworte ich dir hier richtig.",
                        en: "\(name) here, from demo mode. I got your question: “\(question)”. "
                            + "With a real server, I’d answer you properly here.")
    }
}
