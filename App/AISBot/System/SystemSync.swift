import AppIntents
import Foundation
import Observation
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Systemintegration der App (docs/system.md)
//
// Eine Stelle verbindet die App mit Teilen-Menü, Kurzbefehlen, Controls und Spotlight: Sie schreibt das
// Verzeichnis für Erweiterungen (`SystemDirectory`), hält den Spotlight-Index aktuell, sendet abgelegte Inhalte
// nach und nimmt Links entgegen.

extension AppStore {
    /// ID des eigenen Servers für Erweiterungen (nil = keiner verbunden)
    var systemServerID: String? {
        guard settings.isConfigured else { return nil }
        if settings.isMock { return SystemServer.demoID }
        return settings.cloudServerID ?? SystemServer.manualID
    }

    /// Chats samt Server für Erweiterungen und Intents. Ohne Zugangsdaten und ohne Nachrichten.
    var systemDirectory: SystemDirectory {
        var servers: [SystemServer] = []
        let activeID = systemServerID
        if let activeID, !settings.isMock {
            let cloud = account.server(id: settings.cloudServerID)
            let alternative = [cloud?.publicUrl, cloud?.tailnetUrl].compactMap { $0 }
                .first { !$0.isEmpty && $0 != settings.serverURL }
            servers.append(SystemServer(id: activeID,
                                        name: settings.cloudServerName ?? cloud?.name ?? settings.baseURL?.host() ?? "Server",
                                        url: settings.serverURL, altURL: alternative, usesAccount: settings.usesAccount,
                                        guest: false))
        } else if let activeID {
            servers.append(SystemServer(id: activeID, name: "Demo", url: ConnectionSettings.mockURL, altURL: nil,
                                        usesAccount: false, guest: false))
        }
        var chats: [SystemChat] = []
        if let activeID {
            chats += bots.map { b in
                SystemChat(id: b.id, serverID: activeID, name: b.name, label: b.label, mascot: b.mascot, members: nil,
                           primary: b.primary, pinned: b.pinned, lastActiveAt: b.lastMessage?.createdAt ?? b.createdAt,
                           canWrite: true, shared: false, ownerName: nil)
            }
            chats += groups.map { g in
                SystemChat(id: g.id, serverID: activeID, name: g.name, label: nil, mascot: nil,
                           members: g.memberIds.compactMap { ownBot($0) }
                               .map { SystemChatMember(id: $0.id, name: $0.name, mascot: $0.mascot) },
                           primary: false, pinned: g.pinned, lastActiveAt: g.lastMessage?.createdAt ?? g.createdAt,
                           canWrite: true, shared: false, ownerName: nil)
            }
        }
        // Mit mir geteilte Scoops liegen auf den Servern ihrer Admins
        for b in sharedBots {
            guard let share = share(for: b.id) else { continue }
            if !servers.contains(where: { $0.id == share.serverId }) {
                // Adressen aus dem Verzeichnis kommen teils ohne Schema: wie `SharedScoop.connectURL` https annehmen
                let urls = [share.publicUrl, share.tailnetUrl].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.map { $0.contains("://") ? $0 : "https://" + $0 }
                servers.append(SystemServer(id: share.serverId, name: share.serverName ?? share.ownerName,
                                            url: isMock ? ConnectionSettings.mockURL : (urls.first ?? ""),
                                            altURL: urls.dropFirst().first, usesAccount: true, guest: true))
            }
            chats.append(SystemChat(id: b.id, serverID: share.serverId, name: b.name, label: b.label, mascot: b.mascot,
                                    members: nil, primary: false, pinned: b.pinned,
                                    lastActiveAt: b.lastMessage?.createdAt ?? b.createdAt, canWrite: canWrite(b.id),
                                    shared: true, ownerName: ownerName(of: b.id)))
        }
        return SystemDirectory(generatedAt: .distantPast, userName: userName, demo: isMock,
                               demoOffline: isMock && ProcessInfo.processInfo.arguments.contains("-shareofflinedemo"),
                               activeServerID: activeID, servers: servers, chats: chats,
                               cloudSiteURL: isMock ? nil : CloudConfig.siteURL.absoluteString)
    }
}

/// Hält Verzeichnis, Spotlight, Kurzbefehl-Parameter und Controls aktuell (gebündelt, wie `WidgetSync`).
final class SystemSync {
    static let shared = SystemSync()

    private weak var store: AppStore?
    private var last: SystemDirectory?
    private var task: Task<Void, Never>?

    /// Einmal beim Start der App (auch beim Hintergrundstart für einen Kurzbefehl).
    func start(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        // Zugangsdaten älterer Versionen für die Teilen-Erweiterung erreichbar machen (ohne erneutes Anmelden)
        SharedKeychain.migrate()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-keychainselftest") { print("[System] \(SharedKeychain.selfTest())") }
        #endif
        last = SystemDirectory.load().map { var d = $0; d.generatedAt = .distantPast; return d }
        SystemBridge.shared.appService = { [weak store] chat in
            guard let store, store.service(for: chat.id) != nil, store.chatExists(chat.id) else { return nil }
            return StoreSystemService(store: store)
        }
        // Läuft die App im Demo-Modus oder ist niemand angemeldet, braucht es kein JWT
        if !store.isMock {
            SystemBridge.shared.accountToken = { @MainActor [weak store] force in
                guard let account = store?.account, account.isSignedIn else { return nil }
                if force { _ = await account.forceRefresh() }
                return try? await account.validToken()
            }
        }
        DeepLinkRouter.shared.start(store: store)
        ShareOutboxSender.shared.start(store: store)
        observe()
        changed()
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.systemDirectory
            _ = store.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.changed()
                self?.observe()
            }
        }
    }

    private func changed() {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        guard let store, !store.isTestServer else { return }  // Testinstanz: echte Daten nicht überschreiben
        var directory = store.systemDirectory
        if let last {
            // Demo-Daten bleiben stehen, bis es eine echte Verbindung gibt (Kurzbefehl startet die App ohne `-mock`)
            if last.demo, !store.isMock, !store.isConfigured, store.sharedBots.isEmpty { return }
            // Solange die Chats noch nicht geladen sind, gilt der letzte Stand weiter: beim Start, während des
            // Verbindungsaufbaus, wenn der Server gerade nicht antwortet und wenn das System die App nur im
            // Hintergrund für einen Kurzbefehl gestartet hat (dann verbindet sie sich gar nicht). Sonst wären
            // Kurzbefehle, Controls und Spotlight jedes Mal kurz leer.
            let ownPending = store.isConfigured && store.phase != .online && store.bots.isEmpty
                && last.activeServerID == directory.activeServerID && last.demo == directory.demo
            let sharedPending = store.account.isSignedIn && !store.account.sharedLoaded && store.sharedBots.isEmpty
                && last.demo == directory.demo
            if ownPending || sharedPending {
                let kept = last.chats.filter { ($0.shared && sharedPending) || (!$0.shared && ownPending) }
                directory.chats = kept + directory.chats.filter { chat in !kept.contains { $0.id == chat.id } }
                for server in last.servers where !directory.servers.contains(where: { $0.id == server.id })
                    && kept.contains(where: { $0.serverID == server.id }) {
                    directory.servers.append(server)
                }
            }
        }
        guard directory != last else { return }
        last = directory
        var stamped = directory
        stamped.generatedAt = Date()
        stamped.save()
        // Neue oder umbenannte Scoops in Siri-Sätzen und in der Auswahl der Controls
        ScoopShortcuts.updateAppShortcutParameters()
        #if canImport(WidgetKit)
        ControlCenter.shared.reloadAllControls()
        #endif
        // Spotlight und Chat-Bilder; sind die Bilder fertig, die Kurzbefehle noch einmal auffrischen
        SpotlightIndexer.shared.update(directory: directory) {
            ScoopShortcuts.updateAppShortcutParameters()
        }
    }
}

// MARK: - Verbindung der laufenden App für Intents und die Ablage

/// Führt Aktionen von Kurzbefehlen und das Nachsenden über die Verbindung der App aus: gleiche Anmeldung,
/// gleicher Demo-Modus, und der Chat zeigt die Nachricht sofort.
/// Klasse und Methoden sind ausdrücklich `@MainActor`: Das Protokoll ist `nonisolated`, seine Erfüller wären es sonst auch.
@MainActor
final class StoreSystemService: SystemService {
    private let store: AppStore

    init(store: AppStore) { self.store = store }

    private func service(_ chatID: String) throws -> BotService {
        guard let service = store.service(for: chatID) else { throw SystemError.notConnected }
        return service
    }

    private static func mapped(_ error: Error) -> SystemError {
        guard let api = error as? APIError else { return SystemError.from(error) }
        switch api.status {
        case 0: return .offline
        case 401: return .unauthorized
        case 403: return SystemError(kind: .forbidden, message: api.message, status: 403)
        case 404: return SystemError(kind: .notFound, message: api.message, status: 404)
        case 413: return SystemError(kind: .tooLarge, message: api.message, status: 413)
        default: return SystemError(kind: .server, message: api.message, status: api.status)
        }
    }

    @MainActor
    func send(chatID: String, text: String, fileIDs: [String]) async throws -> SystemSentMessage {
        do {
            let message = try await service(chatID).send(chatID: chatID, message: OutgoingMessage(
                text: text, voice: nil, fileIds: fileIDs.isEmpty ? nil : fileIDs))
            store.upsert(message)
            store.updateChatSummary(message, countUnread: false)
            return SystemSentMessage(id: message.id, createdAt: message.createdAt)
        } catch {
            throw Self.mapped(error)
        }
    }

    @MainActor
    func upload(chatID: String, file: URL, name: String, mime: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= AttachmentQueue.maxBytes else {
            throw SystemError(kind: .tooLarge, message: String(localized: "„\(name)“ ist größer als 25 MB."), status: 413)
        }
        do {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            return try await store.uploadFile(chatID: chatID, name: name, mime: mime, data: data, progress: progress).id
        } catch {
            throw Self.mapped(error)
        }
    }

    @MainActor
    func createTask(chatID: String, actorID: String?, title: String?, prompt: String) async throws -> SystemTaskRef {
        guard !store.isGuestChat(chatID), let board = store.service as? TaskBoardService else {
            throw SystemError(kind: .forbidden, message: String(localized: "Aufgaben gehen nur bei deinen eigenen Scoops."), status: 403)
        }
        do {
            let task = try await board.createTask(TaskDraft(chatId: chatID, actorId: actorID, prompt: prompt, title: title))
            await store.taskBoard.load()
            return SystemTaskRef(id: task.id, title: task.title)
        } catch {
            throw Self.mapped(error)
        }
    }

    @MainActor
    func recentMessages(chatID: String, limit: Int) async throws -> [Message] {
        do {
            return try await service(chatID).messages(chatID: chatID, before: nil, limit: limit)
        } catch {
            throw Self.mapped(error)
        }
    }
}
