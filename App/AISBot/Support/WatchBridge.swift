#if os(iOS)
import Foundation
import Observation
import WatchConnectivity

/// iPhone-Seite der Apple-Watch-Verbindung (docs/watch.md).
///
/// Übergibt der Uhr per `updateApplicationContext` Server-Adressen, API-Token bzw. das Sitzungs-JWT des Kontos und
/// eine Kurzfassung der Chats. WatchConnectivity überträgt verschlüsselt zwischen gekoppelten Geräten; die Uhr legt
/// die Daten nur im Schlüsselbund ab. Nichts davon wird protokolliert.
///
/// Außerdem beantwortet das iPhone Anfragen der Uhr: frische Zugangsdaten (Konto-JWT erneuert) und – falls die Uhr den
/// Server nicht selbst erreicht – einzelne Server-Anfragen, die das iPhone mit seinen eigenen Zugangsdaten ausführt.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private weak var store: AppStore?
    private var lastSent: Data?
    private var syncTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    func start(store: AppStore) {
        guard WCSession.isSupported(), self.store == nil else { return }
        self.store = store
        WCSession.default.delegate = self
        WCSession.default.activate()
        observe()
    }

    // MARK: Zugangsdaten zusammenstellen

    /// Server, die die Uhr nutzen darf: der verbundene (API-Token oder Konto) und alle Konto-Server.
    func makeCredentials() -> WatchCredentials? {
        guard let store else { return nil }
        if store.isMock {
            return WatchCredentials(servers: [], activeServerID: nil, userName: store.userName, demo: true,
                                    chats: chatSummaries(store))
        }
        let account = store.account
        let settings = store.settings
        var servers: [WatchServer] = []
        var activeID: String?
        if settings.isConfigured, !settings.isMock {
            if let cloudID = settings.cloudServerID {
                if account.isSignedIn {
                    let cloud = account.server(id: cloudID)
                    servers.append(WatchServer(id: cloudID, name: settings.cloudServerName ?? cloud?.name ?? "Server",
                                               url: settings.serverURL, altURL: Self.alternative(cloud, primary: settings.serverURL),
                                               usesAccount: true, token: nil))
                    activeID = cloudID
                }
            } else if !settings.token.isEmpty {
                let host = settings.baseURL?.host() ?? "Server"
                servers.append(WatchServer(id: WatchServer.manualID, name: host, url: settings.serverURL, altURL: nil,
                                           usesAccount: false, token: settings.token))
                activeID = WatchServer.manualID
            }
        }
        if account.isSignedIn {
            for cloud in account.servers where !servers.contains(where: { $0.id == cloud.id }) {
                guard let url = cloud.connectURL else { continue }
                servers.append(WatchServer(id: cloud.id, name: cloud.name, url: url,
                                           altURL: Self.alternative(cloud, primary: url), usesAccount: true, token: nil))
            }
        }
        let creds = account.credentials
        return WatchCredentials(servers: servers, activeServerID: activeID,
                                accountToken: servers.contains(where: \.usesAccount) ? creds?.token : nil,
                                accountExpiry: servers.contains(where: \.usesAccount) ? creds?.expiry : nil,
                                userName: store.userName, demo: false, chats: chatSummaries(store))
    }

    private static func alternative(_ cloud: CloudServer?, primary: String) -> String? {
        guard let cloud else { return nil }
        return [cloud.publicUrl, cloud.tailnetUrl].compactMap { $0 }.first { !$0.isEmpty && $0 != primary }
    }

    private func chatSummaries(_ store: AppStore) -> [WatchChatSummary] {
        let byID = Dictionary(store.bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bots = store.bots.prefix(30).map { b in
            WatchChatSummary(id: b.id, name: b.name, label: b.label, mascot: b.mascot, members: nil, unread: b.unread,
                             waiting: b.waiting, preview: WatchText.preview(b.lastMessage, limit: 60), pinned: b.pinned)
        }
        let groups = store.groups.prefix(10).map { g in
            WatchChatSummary(id: g.id, name: g.name, label: nil, mascot: nil,
                             members: g.memberIds.prefix(3).compactMap { byID[$0]?.mascot }, unread: g.unread,
                             waiting: g.waiting, preview: WatchText.preview(g.lastMessage, limit: 60), pinned: g.pinned)
        }
        return bots + groups
    }

    // MARK: Abgleich

    /// Beobachtet Verbindung, Konto und Chats und schickt Änderungen gebündelt an die Uhr.
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.settings
            _ = store.account.credentials
            _ = store.account.servers
            _ = store.bots
            _ = store.groups
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSync()
                self?.observe()
            }
        }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    func sync() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              var creds = makeCredentials() else { return }
        creds.updatedAt = .distantPast  // gleicher Inhalt → gleiche Daten → nicht erneut senden
        guard let compare = creds.encoded(), compare != lastSent else { return }
        creds.updatedAt = Date()
        guard let data = creds.encoded() else { return }
        do {
            try session.updateApplicationContext([WatchLink.credentialsKey: data])
            lastSent = compare
        } catch {
            // Nächster Versuch beim nächsten Wechsel
        }
    }

    // MARK: Anfragen der Uhr

    private func freshCredentials() async -> WatchCredentials? {
        guard let store else { return nil }
        // Konto-JWT für die Uhr möglichst lange gültig halten: erneuern, wenn es in weniger als drei Tagen abläuft
        if store.account.isSignedIn {
            _ = try? await store.account.validToken()
            if let expiry = store.account.credentials?.expiry, expiry.timeIntervalSinceNow < 3 * 86400 {
                _ = await store.account.forceRefresh()
            }
        }
        return makeCredentials()
    }

    /// Führt eine Server-Anfrage für die Uhr aus (nur `/api/…`, nur bekannte Server).
    private func relay(_ message: [String: Any]) async -> [String: Any] {
        guard let store, let creds = makeCredentials(),
              let serverID = message[WatchLink.serverKey] as? String,
              let server = creds.servers.first(where: { $0.id == serverID }),
              let method = message[WatchLink.methodKey] as? String, ["GET", "POST"].contains(method),
              let path = message[WatchLink.pathKey] as? String, WatchLink.isRelayablePath(path) else {
            return [WatchLink.statusKey: 400, WatchLink.errorKey: "Ungültige Anfrage"]
        }
        let bearer: String
        if server.usesAccount {
            guard let token = try? await store.account.validToken() else { return [WatchLink.statusKey: 401] }
            bearer = token
        } else {
            bearer = server.token ?? ""
        }
        let query = (message[WatchLink.queryKey] as? [String: String] ?? [:])
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        for base in server.baseURLs {
            var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = method
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body = message[WatchLink.bodyKey] as? Data {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let (data, response) = try? await session.data(for: req) {
                return [WatchLink.statusKey: (response as? HTTPURLResponse)?.statusCode ?? 0, WatchLink.dataKey: data]
            }
        }
        return [WatchLink.statusKey: 0, WatchLink.errorKey: "Server nicht erreichbar"]
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in WatchBridge.shared.sync() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Uhr gewechselt: neu aktivieren und Zugangsdaten an die neue Uhr schicken
        session.activate()
        Task { @MainActor in WatchBridge.shared.lastSent = nil }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchBridge.shared.lastSent = nil
            WatchBridge.shared.sync()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            let bridge = WatchBridge.shared
            switch (message[WatchLink.kindKey] as? String).flatMap(WatchLink.Kind.init(rawValue:)) {
            case .credentials:
                if let creds = await bridge.freshCredentials(), let data = creds.encoded() {
                    reply([WatchLink.credentialsKey: data])
                } else {
                    reply([:])
                }
            case .relay:
                reply(await bridge.relay(message))
            case nil:
                reply([:])
            }
        }
    }
}
#endif
