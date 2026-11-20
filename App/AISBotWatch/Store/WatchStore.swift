import Foundation
import Observation
import WatchKit
import WidgetKit

/// Ein Eintrag der Scoop-Liste (Scoop oder Gruppe), aus Live-Daten oder der Kurzfassung vom iPhone.
struct WatchChat: Identifiable, Hashable {
    var id: String
    var name: String
    var label: String?
    var mascot: Mascot?
    var members: [Mascot]
    var unread: Int
    var waiting: Bool
    var busy: Bool
    var lastMessage: Message?
    var previewText: String?
    var pinned: Bool

    var isGroup: Bool { ChatGroup.isGroupID(id) }
    var preview: String? { WatchText.preview(lastMessage) ?? previewText }
}

/// Ziele im NavigationStack
enum WatchDestination: Hashable {
    case chat(String)
    case approvals
}

/// Daten der Uhren-App (MainActor). Lädt per `WatchAPI`, im Demo-Modus aus `WatchDemo`.
@Observable
final class WatchStore {
    enum Mode: Equatable { case unconfigured, demo, live }

    private(set) var mode: Mode = .unconfigured
    private(set) var credentials: WatchCredentials?
    private(set) var activeServerID: String?

    private(set) var bots: [Bot] = []
    private(set) var groups: [ChatGroup] = []
    var messages: [String: [Message]] = [:]
    /// Offene Freigaben über alle Chats, neueste zuerst
    private(set) var approvals: [Message] = []

    private(set) var loading = false
    private(set) var loadingChats: Set<String> = []
    private(set) var deciding: Set<String> = []
    private(set) var lastUpdated: Date?
    var errorMessage: String?
    /// Letzte Anfrage lief über das iPhone (Hinweis in der Liste)
    private(set) var viaPhone = false

    var path: [WatchDestination] = []
    /// Chat, dessen Eingabe gleich geöffnet werden soll (Komplikation „Scoop“)
    var pendingCompose: String?

    @ObservationIgnored private var api: WatchAPI?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    static let activeServerKey = "watchActiveServerID"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains("-demo") {
            enterDemo()
        } else if let saved = WatchKeychain.load() {
            apply(saved, persist: false)
        }
        WatchSession.shared.onCredentials = { [weak self] creds in self?.apply(creds, persist: true) }
        ScoopPhotoCache.shared.fetcher = { [weak self] photo in
            guard let api = self?.api else { throw WatchAPIError(status: 0, message: String(localized: "Nicht verbunden")) }
            return try await api.avatar(botID: photo.id, version: photo.version)
        }
    }

    // MARK: - Verbindung

    var servers: [WatchServer] { credentials?.servers ?? [] }
    var activeServer: WatchServer? { servers.first { $0.id == activeServerID } }
    var userName: String { credentials?.userName ?? "" }

    /// Neue Zugangsdaten (vom iPhone oder aus dem Schlüsselbund)
    func apply(_ creds: WatchCredentials, persist: Bool) {
        if persist { WatchKeychain.save(creds) }
        let previous = credentials
        credentials = creds
        if creds.demo {
            if mode != .demo { enterDemo() }
            return
        }
        guard !creds.servers.isEmpty else {
            mode = .unconfigured
            api = nil
            return
        }
        let preferred = UserDefaults.standard.string(forKey: Self.activeServerKey)
        let chosen = [preferred, activeServerID, creds.activeServerID].compactMap { $0 }
            .first { id in creds.servers.contains { $0.id == id } } ?? creds.servers[0].id
        let switched = chosen != activeServerID || mode != .live
        activeServerID = chosen
        mode = .live
        if switched || api == nil, let server = creds.servers.first(where: { $0.id == chosen }) {
            if switched { bots = []; groups = []; messages = [:]; approvals = [] }
            let client = WatchAPI(server: server, credentials: creds)
            client.onCredentials = { [weak self] fresh in self?.apply(fresh, persist: true) }
            api = client
            Task { await refresh() }
        } else {
            api?.update(credentials: creds)
            if previous?.accountToken != creds.accountToken, errorMessage != nil { Task { await refresh() } }
        }
        if bots.isEmpty && groups.isEmpty { exportWidgets() }
    }

    func selectServer(_ id: String) {
        guard id != activeServerID, let creds = credentials else { return }
        UserDefaults.standard.set(id, forKey: Self.activeServerKey)
        activeServerID = nil
        path = []
        apply(creds, persist: false)
    }

    func enterDemo() {
        mode = .demo
        api = nil
        bots = WatchDemo.bots
        groups = WatchDemo.groups
        messages = WatchDemo.messages
        recomputeApprovals()
        lastUpdated = Date()
        exportWidgets()
    }

    /// Demo verlassen (nur ohne iPhone-Demo)
    func leaveDemo() {
        guard credentials?.demo != true else { return }
        bots = []; groups = []; messages = [:]; approvals = []
        mode = .unconfigured
        if let creds = credentials, !creds.servers.isEmpty { apply(creds, persist: false) }
    }

    /// Fragt das iPhone aktiv nach den Zugangsdaten (Knopf „Erneut versuchen“)
    func askPhone() async {
        if let creds = await WatchSession.shared.requestCredentials() { apply(creds, persist: true) }
    }

    // MARK: - Liste

    var chats: [WatchChat] {
        let live: [WatchChat]
        if !bots.isEmpty || !groups.isEmpty {
            let byID = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            live = bots.filter { $0.access == nil }.map { b in
                WatchChat(id: b.id, name: b.name, label: b.label, mascot: b.mascot, members: [], unread: b.unread,
                          waiting: b.waiting, busy: b.busy, lastMessage: b.lastMessage, pinned: b.pinned)
            } + groups.map { g in
                WatchChat(id: g.id, name: g.name, label: nil, mascot: nil,
                          members: g.memberIds.compactMap { byID[$0]?.mascot }, unread: g.unread, waiting: g.waiting,
                          busy: g.busy, lastMessage: g.lastMessage, pinned: g.pinned)
            }
        } else if mode == .live, let summary = credentials?.chats {
            live = summary.map { s in
                WatchChat(id: s.id, name: s.name, label: s.label, mascot: s.mascot, members: s.members ?? [],
                          unread: s.unread, waiting: s.waiting, busy: false, previewText: s.preview, pinned: s.pinned)
            }
        } else {
            live = []
        }
        return WatchChatOrder.sorted(live, pinned: \.pinned, lastActivity: { $0.lastMessage?.createdAt })
    }

    func chat(_ id: String) -> WatchChat? { chats.first { $0.id == id } }
    func bot(_ id: String?) -> Bot? { id.flatMap { id in bots.first { $0.id == id } } }

    var totalUnread: Int { chats.reduce(0) { $0 + $1.unread } }

    // MARK: - Laden

    func refresh() async {
        if mode == .demo { lastUpdated = Date(); return }
        guard let api else { return }
        if let running = refreshTask { await running.value; return }
        let task = Task { await performRefresh(api) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(_ api: WatchAPI) async {
        loading = true
        defer { loading = false }
        do {
            let b = try await api.bots()
            let g = try? await api.groups()
            guard api === self.api else { return }
            bots = b
            groups = g ?? []
            errorMessage = nil
            lastUpdated = Date()
            viaPhone = api.lastRoute == .phone
            await loadWaitingChats(api)
        } catch {
            if api === self.api { errorMessage = Self.describe(error) }
        }
        exportWidgets()
    }

    /// Lädt die letzten Nachrichten der Chats, die auf dich warten (offene Freigaben)
    private func loadWaitingChats(_ api: WatchAPI) async {
        let waiting = chats.filter(\.waiting).map(\.id)
        // Nacheinander (meist nur ein, zwei Chats); die Uhr spart so Funk und Akku
        for id in waiting.prefix(8) {
            if let list = try? await api.messages(chatID: id, limit: 25) { merge(list, into: id) }
        }
        recomputeApprovals()
    }

    func loadMessages(_ chatID: String) async {
        if mode == .demo { return }
        guard let api else { return }
        if messages[chatID] == nil { loadingChats.insert(chatID) }
        defer { loadingChats.remove(chatID) }
        do {
            let list = try await api.messages(chatID: chatID, limit: 40)
            merge(list, into: chatID)
            recomputeApprovals()
            errorMessage = nil
        } catch {
            if messages[chatID] == nil { errorMessage = Self.describe(error) }
        }
    }

    /// Übernimmt Server-Nachrichten; lokale, noch nicht bestätigte Nachrichten bleiben stehen.
    private func merge(_ list: [Message], into chatID: String) {
        let local = (messages[chatID] ?? []).filter { $0.localState != nil }
        let serverTexts = Set(list.filter { $0.role == .user }.suffix(5).map(\.text))
        messages[chatID] = list + local.filter { !serverTexts.contains($0.text) }
    }

    private func upsert(_ message: Message) {
        var list = messages[message.chatId] ?? []
        if let i = list.firstIndex(where: { $0.id == message.id }) { list[i] = message } else { list.append(message) }
        messages[message.chatId] = list
    }

    func markRead(_ chatID: String) {
        if let i = bots.firstIndex(where: { $0.id == chatID }) { bots[i].unread = 0 }
        if let i = groups.firstIndex(where: { $0.id == chatID }) { groups[i].unread = 0 }
        guard mode == .live, let api else { return }
        Task { try? await api.markRead(chatID: chatID); exportWidgets() }
    }

    func isBusy(_ chatID: String) -> Bool { chat(chatID)?.busy ?? false }

    /// Solange ein Chat sichtbar ist: alle paar Sekunden nachladen (watchOS erlaubt keine WebSockets für Apps)
    func poll(_ chatID: String) async {
        var tick = 0
        while !Task.isCancelled {
            let busy = isBusy(chatID) || (messages[chatID]?.last?.isRunning ?? false)
                || (messages[chatID]?.last?.role == .user)
            try? await Task.sleep(for: .seconds(busy ? 2.5 : 6))
            guard !Task.isCancelled else { return }
            await loadMessages(chatID)
            tick += 1
            if tick % 2 == 0 { await refresh() }
        }
    }

    // MARK: - Senden

    func send(_ text: String, to chatID: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var local = Message(id: "local-\(UUID().uuidString)", botId: chatID, role: .user, text: trimmed, createdAt: Date())
        local.localState = .sending
        upsert(local)
        WKInterfaceDevice.current().play(.click)
        if mode == .demo {
            try? await Task.sleep(for: .milliseconds(500))
            local.localState = nil
            upsert(local)
            for reply in WatchDemo.reply(to: trimmed, chatID: chatID) {
                try? await Task.sleep(for: .seconds(1.2))
                upsert(reply)
            }
            return
        }
        guard let api else { return }
        do {
            let saved = try await api.send(chatID: chatID, text: trimmed)
            messages[chatID]?.removeAll { $0.id == local.id }
            upsert(saved)
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(for: .seconds(1.5))
            await loadMessages(chatID)
        } catch {
            local.localState = .failed
            upsert(local)
            errorMessage = Self.describe(error)
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func retry(_ message: Message) async {
        messages[message.chatId]?.removeAll { $0.id == message.id }
        await send(message.text, to: message.chatId)
    }

    func stop(_ chatID: String) async {
        guard mode == .live, let api else { return }
        try? await api.stop(chatID: chatID)
        await refresh()
    }

    // MARK: - Freigaben

    private func recomputeApprovals() {
        let waiting = Set(chats.filter(\.waiting).map(\.id))
        let relevant = mode == .demo ? messages : messages.filter { waiting.contains($0.key) }
        approvals = WatchApprovals.pending(in: relevant)
    }

    func isDeciding(_ message: Message) -> Bool { deciding.contains(message.meta.approvalId ?? message.id) }

    /// Entscheidet über eine Karte (optimistisch, bei Fehler zurück)
    @discardableResult
    func decide(_ message: Message, _ decision: ApprovalDecision) async -> Bool {
        let key = message.meta.approvalId ?? message.id
        guard !deciding.contains(key) else { return false }
        deciding.insert(key)
        defer { deciding.remove(key) }
        upsert(WatchApprovals.applying(decision, to: message))
        approvals.removeAll { ($0.meta.approvalId ?? $0.id) == key }
        if mode == .demo {
            try? await Task.sleep(for: .milliseconds(350))
            WKInterfaceDevice.current().play(decision == .decline ? .directionDown : .success)
            exportWidgets()
            return true
        }
        guard let api, let approvalID = message.meta.approvalId else { return false }
        do {
            upsert(try await api.decide(approvalID: approvalID, decision: decision))
            WKInterfaceDevice.current().play(decision == .decline ? .directionDown : .success)
            exportWidgets()
            Task { await refresh() }
            return true
        } catch {
            upsert(message)
            recomputeApprovals()
            errorMessage = Self.describe(error)
            WKInterfaceDevice.current().play(.failure)
            return false
        }
    }

    /// Entscheidung aus einer Mitteilung (nur Freigabe-ID bekannt)
    func decide(approvalID: String, decision: ApprovalDecision) async -> Bool {
        if let message = messages.values.joined().first(where: { $0.meta.approvalId == approvalID }) {
            return await decide(message, decision)
        }
        guard mode == .live, let api else { return false }
        do {
            upsert(try await api.decide(approvalID: approvalID, decision: decision))
            await refresh()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Deep Links

    func open(_ route: WatchRoute) {
        switch route {
        case .chat(let id, let compose):
            path = [.chat(id)]
            pendingCompose = compose ? id : nil
        case .approvals:
            path = [.approvals]
        case .home:
            path = []
        }
    }

    // MARK: - Komplikationen

    func exportWidgets() {
        WatchWidgetExporter.export(store: self)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? WatchAPIError { return e.message }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return String(localized: "Kein Netz.")
            case .timedOut: return String(localized: "Server antwortet nicht.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return String(localized: "Server nicht erreichbar.")
            default: return String(localized: "Verbindung fehlgeschlagen.")
            }
        }
        if error is DecodingError { return String(localized: "Antwort des Servers nicht lesbar.") }
        return error.localizedDescription
    }
}
