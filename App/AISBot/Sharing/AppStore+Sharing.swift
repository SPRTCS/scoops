import Foundation
import SwiftUI

/// Zustand der Verbindung zu einem Admin-Server (geteilte Scoops).
enum GuestConnectionState: Equatable {
    case connecting
    case online
    case offline(String)
}

/// Verbindung zum Server eines Admins: eigener Client und Live-Kanal mit dem Sitzungs-JWT des Gasts.
/// Der Server erkennt den Gast am JWT (`sub` ≠ Inhaber) und liefert nur dessen geteilte Scoops.
final class GuestConnection {
    let serverID: String
    let baseURL: URL?
    let service: BotService
    /// Live-Kanal war schon einmal verbunden (danach heißt „verbunden“: nachladen)
    var hadConnection = false
    /// Geräte-Token, die dieser Server schon kennt
    var registeredTokens: Set<String> = []

    init(serverID: String, baseURL: URL?, service: BotService) {
        self.serverID = serverID
        self.baseURL = baseURL
        self.service = service
    }
}

// MARK: - Zuordnung Chat → Server

extension AppStore {
    /// Share des Gasts für diesen Chat (nur bei „Mit mir geteilt“)
    func share(for chatID: String?) -> SharedScoop? {
        guard let chatID else { return nil }
        return account.sharedWithMe.first { $0.botId == chatID }
    }

    /// Chat liegt auf dem Server eines anderen (ich bin Gast)
    func isGuestChat(_ chatID: String?) -> Bool { share(for: chatID) != nil }

    /// Convex-Server-ID des Admin-Servers eines geteilten Chats (nil = eigener Server)
    func guestServerID(for chatID: String?) -> String? { share(for: chatID)?.serverId }

    /// Verbindung, über die dieser Chat läuft: Server des Admins bei geteilten Scoops, sonst der eigene.
    func service(for chatID: String?) -> BotService? {
        if let serverID = guestServerID(for: chatID) { return guestConnections[serverID]?.service }
        return service
    }

    /// Verbindung für Bildschirm, Übernehmen und Rechner-Status: folgt dem ausgewählten Chat. Gäste adressieren den
    /// Rechner über den Scoop (`?bot=`), siehe `APIClient.guestBotID`.
    var computerService: BotService? { scopedService(for: isGuestChat(selectedChatID) ? selectedChatID : nil) }

    /// Wie `service(for:)`; bei Gast-Verbindungen zusätzlich auf diesen Scoop festgelegt (Rechner, Diktat, Stimmprobe).
    func scopedService(for chatID: String?) -> BotService? {
        let svc = service(for: chatID)
        if isGuestChat(chatID), let client = svc as? APIClient { client.guestBotID = chatID }
        return svc
    }

    /// Rolle, Rechner-Stufe und Admin für einen geteilten Chat (nil = eigener Scoop, volle Rechte).
    /// Quelle: `shares:mine`; liefert der Server des Admins eine aktuellere Sicht (`access`), gilt die.
    func access(for chatID: String?) -> BotAccess? {
        guard let share = share(for: chatID) else { return nil }
        if let live = bot(chatID)?.access {
            var a = live
            if a.ownerName?.isEmpty ?? true { a.ownerName = share.ownerName }
            return a
        }
        return BotAccess(role: share.role, computer: share.computer, ownerName: share.ownerName,
                         ownerId: share.ownerId, shareId: share.id)
    }

    /// Darf ich in diesem Chat schreiben (eigener Scoop oder Rolle ab „Schreiben“)?
    func canWrite(_ chatID: String?) -> Bool { access(for: chatID)?.role.canWrite ?? true }
    /// Darf ich das Profil bearbeiten (eigener Scoop oder Rolle „Bearbeiten“)?
    func canEditProfile(_ chatID: String?) -> Bool { access(for: chatID)?.role.canEdit ?? true }
    /// Rechner-Stufe (eigener Scoop: volle Kontrolle)
    func computerAccess(_ chatID: String?) -> ComputerAccess { access(for: chatID)?.computer ?? .control }

    /// Name des Admins eines geteilten Chats
    /// Personen in einem geteilten Scoop-Chat (ohne mich), für „@Person“ im Eingabefeld: Admin, Mitglieder und alle,
    /// die dort schon geschrieben haben. Leer in nicht geteilten Chats.
    func people(in chatID: String) -> [String] {
        let shared = share(for: chatID) != nil || bot(chatID)?.isSharedByMe == true
        guard shared else { return [] }
        var names: [String] = []
        if let owner = ownerName(of: chatID) { names.append(owner) }
        names += (shareLists[chatID]?.members ?? bot(chatID)?.shared?.members ?? []).map(\.name)
        for m in messages[chatID] ?? [] where m.role == .user && !isOwnMessage(m) { names.append(authorName(of: m)) }
        let me = account.user?.name?.trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        for n in names.map({ $0.trimmingCharacters(in: .whitespaces) })
        where !n.isEmpty && n != me && !out.contains(n) && isNotScoopName(n, chatID) {
            out.append(n)
        }
        return out
    }

    private func isNotScoopName(_ name: String, _ chatID: String) -> Bool {
        bot(chatID)?.name.caseInsensitiveCompare(name) != .orderedSame
    }

    func ownerName(of chatID: String?) -> String? { access(for: chatID)?.ownerName ?? share(for: chatID)?.ownerName }

    /// Eigene Nachricht? In geteilten Chats tragen Nachrichten von Menschen den Absender (`author_user_id`).
    func isOwnMessage(_ m: Message) -> Bool {
        guard m.role == .user else { return false }
        let me = account.user?.id
        if isGuestChat(m.chatId) {
            // Beim Admin-Server: ohne Absender schreibt der Admin selbst
            guard let author = m.meta.authorUserId else { return m.localState != nil }
            return author == me
        }
        guard let author = m.meta.authorUserId else { return true }
        if let me { return author == me }
        // Ohne Konto: fremd nur, wenn der Absender eine der geteilten Personen ist
        return !(bot(m.chatId)?.shared?.members.contains { $0.userId == author } ?? false)
    }

    /// Geteilter Chat (Gast): Der Server führt meine Reaktion unter `user:<meine ID>` und die des Admins unter
    /// `user`. Lokal gilt wie im eigenen Chat `user` = ich, der Admin steht unter `user:admin`.
    func localized(_ m: Message) -> Message {
        guard isGuestChat(m.chatId), let reactions = m.meta.reactions, !reactions.isEmpty else { return m }
        let mine = account.user.map { "user:\($0.id)" }
        var out: [String: String] = [:]
        for (actor, emoji) in reactions {
            if actor == "user" { out["user:admin"] = emoji } else if actor == mine { out["user"] = emoji } else { out[actor] = emoji }
        }
        var copy = m
        copy.meta.reactions = out
        return copy
    }

    /// Name zu einem Reaktions-Akteur (`user`, `user:<id>`, `user:admin`, Scoop-ID)
    func reactionActorName(_ actor: String, chatID: String) -> String {
        if actor == "user" { return String(localized: "dir", comment: "Reaktion für VoiceOver, Dativ nach „von“: „❤️ von dir“") }
        if actor == "user:admin" { return ownerName(of: chatID) ?? String(localized: "dem Admin", comment: "Reaktion für VoiceOver, Dativ nach „von“") }
        if actor.hasPrefix("user:") {
            let id = String(actor.dropFirst(5))
            let members = shareLists[chatID]?.members ?? bot(chatID)?.shared?.members ?? []
            return members.first { $0.userId == id }?.name ?? String(localized: "jemandem", comment: "Reaktion für VoiceOver, Dativ nach „von“")
        }
        return bot(actor)?.name ?? String(localized: "einem Scoop", comment: "Reaktion für VoiceOver, Dativ nach „von“")
    }

    /// Anzeigename des Absenders einer fremden Nachricht im geteilten Chat.
    func authorName(of m: Message) -> String {
        if let name = m.meta.authorName, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let id = m.meta.authorUserId {
            if let member = (shareLists[m.chatId]?.members ?? bot(m.chatId)?.shared?.members ?? []).first(where: { $0.userId == id }) {
                return member.name
            }
            if let share = share(for: m.chatId), share.ownerId == id { return share.ownerName }
        } else if let owner = ownerName(of: m.chatId) {
            return owner
        }
        return String(localized: "Jemand")
    }

    // MARK: - „Mit mir geteilt“ laden und verbinden

    /// Liste aus Convex holen und die Verbindungen zu den Admin-Servern abgleichen.
    func refreshSharedWithMe() async {
        guard account.isSignedIn else {
            tearDownGuests()
            return
        }
        await account.loadSharedWithMe()
        syncGuestConnections()
        startGuestRefreshLoop()
    }

    /// Alle 60 s (nur im Vordergrund) neu abgleichen: Rollen, Online-Status, neue/entfernte Shares.
    private func startGuestRefreshLoop() {
        guard guestRefreshTask == nil else { return }
        guestRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                guard self.isAppActive, self.account.isSignedIn else { continue }
                await self.account.loadSharedWithMe()
                self.syncGuestConnections()
            }
        }
    }

    /// Verbindungen und Platzhalter an `sharedWithMe` anpassen.
    func syncGuestConnections() {
        let shares = account.sharedWithMe
        let byServer = Dictionary(grouping: shares, by: \.serverId)
        // Nicht mehr geteilte Server trennen
        for (id, connection) in guestConnections where byServer[id] == nil {
            connection.service.disconnectEvents()
            guestConnections[id] = nil
            guestStates[id] = nil
        }
        // Nicht mehr geteilte Scoops entfernen
        let botIDs = Set(shares.map(\.botId))
        for b in sharedBots where !botIDs.contains(b.id) { removeSharedLocally(b.id) }
        // Platzhalter, bis der Server des Admins antwortet (Name und Aussehen aus dem Verzeichnis)
        var list = sharedBots
        for share in shares where !list.contains(where: { $0.id == share.botId }) {
            list.append(Bot(id: share.botId, name: share.botName, mascot: share.botMascot ?? .default,
                            createdAt: share.createdAt))
        }
        if list != sharedBots { sharedBots = sortBots(list) }
        // Neue Server verbinden (bzw. neu, wenn sich die Adresse geändert hat)
        for (serverID, serverShares) in byServer {
            let url = serverShares.lazy.compactMap(\.connectURL).first
            if let existing = guestConnections[serverID], existing.baseURL == url { continue }
            guestConnections[serverID]?.service.disconnectEvents()
            connectGuest(serverID: serverID, url: url)
        }
    }

    private func connectGuest(serverID: String, url: URL?) {
        let svc: BotService
        if isMock {
            svc = MockService(guestServer: serverID)
        } else if let url {
            svc = APIClient(baseURL: url, auth: .account(account))
        } else {
            guestConnections[serverID] = nil
            guestStates[serverID] = .offline(String(localized: "Für diesen Server ist noch keine Adresse bekannt."))
            return
        }
        let connection = GuestConnection(serverID: serverID, baseURL: url, service: svc)
        guestConnections[serverID] = connection
        guestStates[serverID] = .connecting
        svc.onEvent = { [weak self] event in self?.applyGuest(event, serverID: serverID) }
        svc.onSocketState = { [weak self, weak connection] state in
            guard let self, let connection, self.guestConnections[serverID] === connection else { return }
            if state == .connected {
                if connection.hadConnection { Task { await self.loadGuest(serverID) } }
                connection.hadConnection = true
            }
        }
        installPhotoFetcher()
        Task {
            await loadGuest(serverID)
            svc.connectEvents()
            // Eigene Sprache als Gast setzen (docs/sprache.md); ändert nichts für den Inhaber
            await (svc as? LanguageService)?.adoptAppLanguage()
        }
    }

    /// Geteilte Scoops eines Admin-Servers laden (der Server liefert Gästen nur ihre geteilten Scoops).
    func loadGuest(_ serverID: String) async {
        guard let connection = guestConnections[serverID] else { return }
        let ids = Set(account.sharedWithMe.filter { $0.serverId == serverID }.map(\.botId))
        if guestStates[serverID] != .online { guestStates[serverID] = .connecting }
        do {
            let loaded = try await Self.withDeadline(Self.handshakeTimeout, onTimeout: APIError(
                status: 0, message: String(localized: "Der Server antwortet nicht."))) { try await connection.service.bots() }
            guard guestConnections[serverID] === connection else { return }
            for b in loaded where ids.contains(b.id) { applySharedBot(b) }
            guestStates[serverID] = .online
            // Anzeigenamen der Modelle dieses Servers (Server 1.34), ohne die eigene Auswahl zu ändern
            if let other = try? await connection.service.models() { ModelCatalogStore.shared.absorbLabels(from: other) }
            // Offene geteilte Chats nachladen
            for chatID in messages.keys where ids.contains(chatID) { await loadLatestMessages(chatID: chatID) }
            if let sel = selectedChatID, ids.contains(sel) { await loadProfile(botID: sel) }
            // Nur Gast (kein eigener Server): Mitteilungs-Erlaubnis hier einholen; das Token meldet `didRegister`
            if !isMock, !skipPush, PushManager.shared.deviceToken == nil {
                PushManager.shared.requestAuthorizationAndRegister()
            }
            await registerGuestPush(serverID)
            await syncQuietHours(toGuest: serverID)  // Ruhezeit gilt pro Person, auch auf den Servern der Admins
        } catch {
            guard guestConnections[serverID] === connection else { return }
            let text: String
            if let api = error as? APIError, api.status == 401 || api.status == 403 {
                text = String(localized: "Kein Zugriff mehr. Vielleicht wurde die Freigabe beendet.")
                Task { await account.loadSharedWithMe(); syncGuestConnections() }
            } else {
                text = String(localized: "Der Server ist gerade nicht erreichbar.")
            }
            guestStates[serverID] = .offline(text)
        }
    }

    /// Online-Status für die Seitenleiste: Verbindung steht, sonst laut Verzeichnis.
    func isGuestOnline(_ share: SharedScoop) -> Bool {
        switch guestStates[share.serverId] {
        case .online: return true
        case .offline: return false
        default: return share.online
        }
    }

    /// Ereignisse eines Admin-Servers: nur die geteilten Scoops dieses Servers.
    func applyGuest(_ event: ServerEvent, serverID: String) {
        let ids = Set(account.sharedWithMe.filter { $0.serverId == serverID }.map(\.botId))
        switch event {
        case .messageCreated(let m):
            guard ids.contains(m.chatId) else { return }
            upsert(m)
            if m.role == .bot { setTyping(chatID: m.chatId, member: m.meta.authorId ?? m.chatId, false) }
            updateChatSummary(m, countUnread: !isOwnMessage(m))
            if m.role == .bot { NotificationManager.shared.notifyIfNeeded(message: m, store: self) }
        case .messageUpdated(let m):
            guard ids.contains(m.chatId) else { return }
            upsert(m)
            if m.role == .status, !m.isRunning { setTyping(chatID: m.chatId, member: m.meta.authorId ?? m.chatId, false) }
            if let i = sharedBots.firstIndex(where: { $0.id == m.chatId }), sharedBots[i].lastMessage?.id == m.id {
                sharedBots[i].lastMessage = m
            }
        case .messageDeleted(let id, let chatID):
            guard ids.contains(chatID) else { return }
            removeMessageLocally(id, chatID: chatID)
        case .botCreated(let b), .botUpdated(let b):
            guard ids.contains(b.id) else { return }
            applySharedBot(b)
        case .botDeleted(let id):
            guard ids.contains(id) else { return }
            Task { await refreshSharedWithMe() }
        case .botTyping(let chatID, let botID, let isTyping):
            guard ids.contains(chatID) else { return }
            setTyping(chatID: chatID, member: botID, isTyping)
        case .computerUpdated(let c):
            // Nur, wenn gerade ein Scoop dieses Servers ausgewählt ist (Rechner-IDs gelten je Server)
            guard guestServerID(for: selectedChatID) == serverID, c.node == computerNodeID, computer != c else { return }
            computer = c
        case .skillUpdated, .skillDeleted, .routineUpdated:
            apply(event)
        case .unknown(let type) where type == "share.updated":
            // Rechte geändert: Verzeichnis und Scoop-Daten neu laden
            Task {
                await account.loadSharedWithMe()
                syncGuestConnections()
                await loadGuest(serverID)
            }
        default:
            break
        }
    }

    /// Scoop-Daten eines Admin-Servers übernehmen.
    func applySharedBot(_ b: Bot) {
        var merged = b
        if !b.busy { typing[b.id] = nil }
        if visibleChatID == b.id { merged.unread = 0 }
        if let i = sharedBots.firstIndex(where: { $0.id == b.id }) {
            if merged.lastMessage == nil { merged.lastMessage = sharedBots[i].lastMessage }
            guard sharedBots[i] != merged else { return }
            sharedBots[i] = merged
        } else {
            sharedBots.append(merged)
        }
        sharedBots = sortBots(sharedBots)
        if selectedChatID == b.id, computerNodeID != b.computerNode { computerNodeID = b.computerNode }
    }

    private func removeSharedLocally(_ id: String) {
        sharedBots.removeAll { $0.id == id }
        messages[id] = nil; memories[id] = nil; routines[id] = nil; typing[id] = nil; files[id] = nil
        if selectedChatID == id { selectedChatID = nil; showInspector = false }
    }

    /// Alle Gast-Verbindungen beenden (abgemeldet).
    func tearDownGuests() {
        guestRefreshTask?.cancel()
        guestRefreshTask = nil
        for c in guestConnections.values { c.service.disconnectEvents() }
        guestConnections = [:]
        guestStates = [:]
        for b in sharedBots { removeSharedLocally(b.id) }
    }

    /// Eigene Scoop-Bilder über die Verbindung des jeweiligen Scoops nachladen.
    func installPhotoFetcher() {
        ScoopPhotoCache.shared.fetcher = { [weak self] photo in
            guard let svc = self?.service(for: photo.id) else { throw CancellationError() }
            return try await svc.avatarData(botID: photo.id, version: photo.version)
        }
    }

    /// Gast-Gerät am Server des Admins für Mitteilungen melden (Gast-Endpunkt laut docs/sharing.md).
    func registerGuestPush(_ serverID: String) async {
        guard !isMock, !skipPush, let connection = guestConnections[serverID],
              let token = PushManager.shared.deviceToken else { return }
        let key = "\(PushManager.shared.platformName):\(token)"
        guard !connection.registeredTokens.contains(key) else { return }
        do {
            try await connection.service.registerGuestDevice(
                DeviceRegistration(apnsToken: token, platform: PushManager.shared.platformName, name: Device.name))
            connection.registeredTokens = [key]
        } catch {
            #if DEBUG
            print("[Teilen] Gast-Gerät bei \(serverID) nicht gemeldet: \(error.localizedDescription)")
            #endif
        }
    }

    /// Nach einem neuen Geräte-Token: alle Admin-Server neu melden.
    func registerGuestPushEverywhere() async {
        for id in guestConnections.keys { await registerGuestPush(id) }
    }

    // MARK: - Seitenleiste „Mit mir geteilt“

    /// Geteilte Scoops mit Share, gefiltert nach der Suche, zuletzt aktive zuerst.
    var sharedEntries: [(bot: Bot, share: SharedScoop)] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return sharedBots.compactMap { b -> (Bot, SharedScoop)? in
            guard let share = share(for: b.id) else { return nil }
            if !q.isEmpty {
                let hit = b.name.localizedCaseInsensitiveContains(q) || (b.label ?? "").localizedCaseInsensitiveContains(q)
                    || share.ownerName.localizedCaseInsensitiveContains(q)
                    || (b.lastMessage?.text ?? "").localizedCaseInsensitiveContains(q)
                guard hit else { return nil }
            }
            return (b, share)
        }
    }

    // MARK: - Einladung annehmen und austreten (Gast)

    /// Einladungslink geöffnet: Annahme-Blatt zeigen (ohne Anmeldung zuerst „Mit Apple anmelden“).
    func handleInviteURL(_ url: URL) {
        guard let code = InviteLink.code(from: url) else { return }
        presentedInviteCode = code
    }

    /// Einladung annehmen und den Scoop gleich öffnen. Gibt bei Fehler den Text zurück.
    func acceptInvite(code: String) async -> String? {
        do {
            let result = try await account.acceptInvite(code: code)
            syncGuestConnections()
            startGuestRefreshLoop()
            if let botID = result.botId ?? account.sharedWithMe.last?.botId {
                selectedChatID = botID
                showInspector = false
            }
            return nil
        } catch {
            return message(error)
        }
    }

    /// Selbst austreten. Gibt bei Fehler den Text zurück.
    func leave(_ share: SharedScoop) async -> String? {
        // Letzter Scoop auf diesem Server: Mitteilungen dort abmelden (so gut es geht)
        if account.sharedWithMe.filter({ $0.serverId == share.serverId }).count <= 1,
           let token = PushManager.shared.deviceToken {
            try? await guestConnections[share.serverId]?.service.unregisterGuestDevice(token: token)
        }
        do {
            try await account.leave(share)
            syncGuestConnections()
            showToast(String(localized: "Du bist aus „\(share.botName)“ ausgetreten"))
            return nil
        } catch {
            return message(error)
        }
    }

    // MARK: - Teilen verwalten (Admin)

    /// Convex-ID des eigenen Servers (Teilen braucht eine Verbindung über das Konto)
    var ownCloudServerID: String? {
        if isMock { return settings.cloudServerID ?? "s_studio" }
        return settings.usesAccount ? settings.cloudServerID : nil
    }

    /// Eigener Scoop, den ich teilen kann (nicht bei geteilten Scoops anderer)
    func canShare(_ botID: String) -> Bool {
        !isGuestChat(botID) && ownBot(botID) != nil
    }

    /// Warum Teilen gerade nicht geht (nil = geht)
    var sharingUnavailableReason: String? {
        if !account.isSignedIn { return String(localized: "Melde dich unter Einstellungen → Konto mit Apple an, um Scoops zu teilen.") }
        if ownCloudServerID == nil {
            return String(localized: "Teilen geht nur, wenn du über dein Konto mit dem Server verbunden bist (Einstellungen → Deine Server).")
        }
        return nil
    }

    func loadShareList(botID: String) async {
        guard let serverID = ownCloudServerID, account.isSignedIn else { return }
        do {
            let list = try await account.shareList(serverID: serverID, botID: botID)
            shareLists[botID] = list
        } catch {
            if shareLists[botID] == nil, let summary = bot(botID)?.shared {
                shareLists[botID] = BotShareList(members: summary.members, invites: [])
            }
            #if DEBUG
            print("[Teilen] shares:listForBot fehlgeschlagen: \(error.localizedDescription)")
            #endif
        }
    }

    /// Einladungslink erzeugen. Wirft mit lesbarem Text.
    func createInvite(botID: String, role: ShareRole, computer: ComputerAccess) async throws -> InviteCreated {
        guard let serverID = ownCloudServerID, let bot = ownBot(botID) else {
            throw CloudError(status: 0, message: sharingUnavailableReason ?? String(localized: "Dieser Scoop lässt sich nicht teilen."))
        }
        let created = try await account.createInvite(InviteRequest(
            serverId: serverID, botId: botID, role: role, computer: computer, botName: bot.name,
            botMascot: SharedMascot.forDirectory(bot.mascot)))
        await loadShareList(botID: botID)
        return created
    }

    func updateShare(_ member: ShareMember, botID: String, role: ShareRole? = nil, computer: ComputerAccess? = nil) async {
        // Optimistisch
        if let i = shareLists[botID]?.members.firstIndex(where: { $0.id == member.id }) {
            if let role { shareLists[botID]?.members[i].role = role }
            if let computer { shareLists[botID]?.members[i].computer = computer }
        }
        do {
            try await account.updateShare(id: member.id, role: role, computer: computer)
            await refreshServerShares()
        } catch {
            report(error)
        }
        await loadShareList(botID: botID)
    }

    func removeShare(_ member: ShareMember, botID: String) async {
        shareLists[botID]?.members.removeAll { $0.id == member.id }
        do {
            try await account.removeShare(id: member.id)
            await refreshServerShares()
            showToast(String(localized: "\(member.name) hat keinen Zugriff mehr"))
        } catch {
            report(error)
        }
        await loadShareList(botID: botID)
    }

    func revokeInvite(_ invite: ShareInvite, botID: String) async {
        shareLists[botID]?.invites.removeAll { $0.id == invite.id }
        do { try await account.revokeInvite(id: invite.id) } catch { report(error) }
        await loadShareList(botID: botID)
    }

    /// Eigenen Server die Shares sofort neu laden lassen (sonst nach dem nächsten Herzschlag).
    func refreshServerShares() async {
        try? await service?.refreshShares()
        // Zähler im Scoop-JSON aktualisieren
        if let list = try? await service?.bots() {
            for b in list where bot(b.id)?.shared != b.shared { apply(.botUpdated(b)) }
        }
    }

    /// Werkzeuge für Geteilte, Tageslimit und Auswahl laden (`GET /api/bots/{id}/sharing`).
    func loadSharingSettings(botID: String) async {
        guard let service, let settings = try? await service.sharingSettings(botID: botID) else { return }
        if sharingSettings[botID] != settings { sharingSettings[botID] = settings }
    }

    /// Werkzeuge für Geteilte setzen (Server-Einstellung pro Scoop).
    func setGuestTools(_ tools: GuestTools, botID: String) async {
        sharingSettings[botID]?.guestTools = tools
        await updateBot(botID, BotPatch(guestTools: tools))
        await loadSharingSettings(botID: botID)
    }

    /// Tageslimit pro Gast in $ setzen (0–100).
    func setGuestBudget(_ usd: Double, botID: String) async {
        let value = min(100, max(0, usd))
        sharingSettings[botID]?.guestBudget = value
        await updateBot(botID, BotPatch(guestBudget: value))
        await loadBotUsage(botID: botID)
    }
}
