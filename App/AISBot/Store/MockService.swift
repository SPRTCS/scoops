import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Demo-Server im Speicher. Simuliert Antworten, Statuszeilen, Freigaben, Gruppen, Bibliothek
/// und WebSocket-Ereignisse.
final class MockService: BotService {
    var onEvent: ((ServerEvent) -> Void)?
    var onSocketState: ((SocketState) -> Void)?

    private var bots: [Bot] = PreviewData.bots.map { b in
        var b = b; b.unread = DemoArgs.unread[b.id] ?? b.unread
        if b.id == "b_theo" { b.computerNode = "n_minibuero" }  // Demo: Theo recherchiert am Mac mini
        return b
    }
    private var groupList: [ChatGroup] = PreviewData.groups.map { g in
        var g = g; g.unread = DemoArgs.unread[g.id] ?? g.unread; return g
    }
    private var messages: [String: [Message]] = {
        var m = PreviewData.messages
        m["g_team"] = PreviewData.groupMessages
        return m
    }()
    private var memories: [String: [Memory]] = PreviewData.memories
    private var routines: [String: [Routine]] = PreviewData.routines
    private var standing: [String: [StandingApproval]] = PreviewData.standingApprovals
    private var library: [String: [LibraryFile]] = PreviewData.files.merging(PreviewData.libraryDemoFiles) { $0 + $1 }
    private var computerState = ComputerState(state: "busy", botId: "b_mila", width: 1024, height: 768, nodeId: "vm")
    /// Demo-Rechner (v1.11): Bot-Rechner + zwei über Scoops Connect angeschlossene Macs
    private var nodeList: [ComputerNode] = [
        ComputerNode(id: "vm", name: demoText("Bot-Rechner", en: "Bot Computer"), mode: "vm", builtin: true, online: true, os: "macOS (VM)",
                     screen: .init(width: 1024, height: 768), state: "busy", botId: "b_mila", botName: "Mila"),
        ComputerNode(id: "n_minibuero", name: demoText("Mac mini Büro", en: "Office Mac mini"), mode: "direct", online: true, os: "macOS 27.0",
                     appVersion: "1.0 (1)", lastSeen: Date(), screen: .init(width: 1512, height: 982),
                     createdAt: Date().addingTimeInterval(-86_400 * 3)),
        ComputerNode(id: "n_mbpro", name: "MacBook Pro", mode: "vm", online: false, os: "macOS 27.0",
                     appVersion: "1.0 (1)", lastSeen: Date().addingTimeInterval(-2 * 3600),
                     screen: .init(width: 1440, height: 900), state: "asleep", createdAt: Date().addingTimeInterval(-86_400)),
    ]
    /// Demo eines Admin-Servers, auf dem ich Gast bin (nil = eigener Demo-Server)
    private var guestServer: String?

    /// Eigener Demo-Server: Mila ist mit zwei Personen geteilt (docs/sharing.md)
    init() {
        if let step = Self.onboardingStep {
            setUpFreshServer(withFirstScoop: step >= .message)
            return
        }
        if let i = bots.firstIndex(where: { $0.id == "b_mila" }) {
            bots[i].shared = BotShareSummary(count: 2, members: MockSharing.milaShares.members)
            bots[i].guestTools = GuestTools(flags: ["web": true, "computer": false, "phone": false, "mail": false],
                                            items: ["apps": ["googlecalendar": true, "notion": false, "gmail": false],
                                                    "mcp": ["atrium": false, "teamapp": false]])
            bots[i].guestBudget = 2
        }
        messages["b_mila", default: []].append(contentsOf: MockGuestData.milaGuestMessages)
        // `-longchat [n]`: langer Verlauf in Pips Chat (Sprung zu einer alten Fundstelle, Zum-Ende-Knopf)
        if let n = ComfortDemo.requestedCount {
            let existing = messages[ComfortDemo.chatID] ?? []
            messages[ComfortDemo.chatID] = ComfortDemo.longHistory(count: n, before: existing.first?.createdAt ?? Date()) + existing
        }
        applyDemoMutes()  // `-mutedemo`: Beispiel für stumme Chats (MockService+Ruhe.swift)
    }

    // MARK: Einführung im Demo-Modus

    /// `-mock -onboarding <schritt>`: frisch eingerichteter Server wie nach der Installation von „AIS Scoops Server“
    static let onboardingStep = OnboardingState.demoLaunchStep(ProcessInfo.processInfo.arguments)
    /// Scoop, den die Einführung ab dem Schritt „Erste Nachricht“ als schon erstellt annimmt
    static let onboardingFirstBotID = "b_fina"

    /// Nur der Start-Scoop Pip mit seiner Begrüßung (wie `seed_fresh_install` im Server), auf Wunsch zusätzlich
    /// der erste eigene Scoop Fina.
    private func setUpFreshServer(withFirstScoop: Bool) {
        let pip = Bot(id: "b_pip", name: "Pip", label: OnboardingLogic.seededLabel,
                      mascot: Mascot(shape: "bean", color: "#FF8FB1", eyes: "dots", accessory: "none"),
                      character: demoText("fröhlich, geduldig und neugierig", en: "cheerful, patient, and curious"), model: BotModel.haiku.rawValue, pinned: true,
                      createdAt: Date().addingTimeInterval(-600), primary: true)
        // Englisch wie die Begrüßung des englischen Servers („Hi! I'm **Pip**, your first Scoop. …“)
        let welcome = Message(id: "m_pip_welcome", botId: pip.id, role: .bot, text: demoText("""
            \(OnboardingLogic.seededWelcomePrefix)Pip**, dein erster Scoop. 🍦

            Scoops sind kleine Helfer, die für dich recherchieren, Texte schreiben und an Dinge erinnern. \
            Wobei soll ich dir helfen?
            """, en: """
            Hi! I’m **Pip**, your first Scoop. 🍦

            Scoops are little helpers that research for you, write, and remind you of things. \
            What can I help you with?
            """), createdAt: Date().addingTimeInterval(-600), meta: { var m = MessageMeta(); m.welcome = true; return m }())
        bots = [pip]
        groupList = []
        messages = [pip.id: [welcome]]
        memories = [:]
        routines = [:]
        standing = [:]
        library = [:]
        computerState = ComputerState(state: "awake", botId: nil, width: 1024, height: 768, nodeId: "vm")
        nodeList = [nodeList[0]]
        nodeList[0].state = "awake"
        nodeList[0].botId = nil
        nodeList[0].botName = nil
        guard withFirstScoop else { return }
        // Fina wie Figur 06 „Creme“ aus dem Marketing: runde Kugel, mandelförmige Augen, Creme
        var fina = Bot(id: Self.onboardingFirstBotID, name: "Fina", label: demoText("Alltag", en: "Everyday"),
                       mascot: Mascot(shape: "circle", color: "#F1DDBB", eyes: "cat", accessory: "none"),
                       character: demoText("locker, hilfsbereit, duzt", en: "casual, helpful, friendly"), model: BotModel.haiku.rawValue, createdAt: Date())
        fina.mascot.mouth = "smile"
        fina.mascot.gaze = "right"
        bots.append(fina)
        messages[fina.id] = [Message(id: "m_fina_hello", botId: fina.id, role: .bot,
                                     text: demoText("Hi, ich bin **Fina**! Sag mir einfach, wobei ich dir helfen soll.",
                                                   en: "Hi, I’m **Fina**! Just tell me what you’d like help with."),
                                     createdAt: Date())]
    }

    /// Server von Sophie (Demo-Gast): nur der geteilte Scoop Juna (bzw. Kiko nach Annahme der Demo-Einladung).
    init(guestServer: String) {
        self.guestServer = guestServer
        bots = [MockGuestData.juna, MockGuestData.kiko]
        groupList = []
        messages = ["b_juna": MockGuestData.junaMessages, "b_kiko": MockGuestData.kikoMessages]
        memories = ["b_juna": MockGuestData.junaMemories]
        routines = [:]
        standing = [:]
        library = [:]
        computerState = ComputerState(state: "busy", botId: "b_juna", width: 1024, height: 768, nodeId: "vm")
        nodeList = [nodeList[0]]
        nodeList[0].botId = "b_juna"
        nodeList[0].botName = "Juna"
    }

    private var pairingTask: Task<Void, Never>?
    private var runs: [String: Task<Void, Never>] = [:]
    private var counter = 0

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_mock\(counter)"
    }

    private func emit(_ e: ServerEvent) { onEvent?(e) }

    // MARK: Zugriff für Erweiterungen in eigenen Dateien (App 1.3: MockService+Ruhe.swift, MockService+Templates.swift)

    /// Ruhezeit im Demo-Modus
    var demoQuietHours = QuietHours.standard

    func demoBot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    func demoGroup(_ id: String) -> ChatGroup? { groupList.first { $0.id == id } }
    func demoRoutines(_ botID: String) -> [Routine] { routines[botID] ?? [] }
    func demoSkills(_ botID: String) -> [Skill] { skillList.filter { $0.botId == botID || $0.botId == nil } }
    func demoAvatar(_ botID: String) -> Data? {
        avatars[botID] ?? (demoBot(botID)?.mascot.photo != nil ? Self.demoPhotoData() : nil)
    }
    func demoID(_ prefix: String) -> String { nextID(prefix) }
    /// Kennungen der Apps mit aktivem Konto (für „benötigte Verbindungen“ einer Vorlage)
    var demoConnectedApps: Set<String> {
        Set(connectionData.apps.filter { $0.accounts.contains { $0.status == "active" } }.map(\.slug))
    }

    /// Scoop bzw. Gruppe ändern und – wie der Server – als Ereignis melden.
    @discardableResult
    func demoUpdate(chatID: String, announce: Bool = true, bot: (inout Bot) -> Void = { _ in },
                    group: (inout ChatGroup) -> Void = { _ in }) -> Bool {
        if let i = bots.firstIndex(where: { $0.id == chatID }) {
            bot(&bots[i])
            var b = bots[i]
            b.lastMessage = messages[chatID]?.last
            if announce { emit(.botUpdated(b)) }
            return true
        }
        if let i = groupList.firstIndex(where: { $0.id == chatID }) {
            group(&groupList[i])
            var g = groupList[i]
            g.lastMessage = messages[chatID]?.last
            if announce { emit(.groupUpdated(g)) }
            return true
        }
        return false
    }

    /// Fertigen Scoop samt Routinen, Fähigkeiten, Bild und erster Zeile im Chat aufnehmen (Import einer Vorlage).
    func demoAdd(bot: Bot, routines newRoutines: [Routine], skills newSkills: [Skill], avatar: Data?, first: Message) {
        bots.append(bot)
        messages[bot.id] = [first]
        routines[bot.id] = newRoutines
        skillList.append(contentsOf: newSkills)
        if let avatar { avatars[bot.id] = avatar }
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    // MARK: Bots

    func health() async throws -> Health {
        // `-oldserver`: wie ein Server vor App 1.3 (keine Suche über alle Chats, kein Bearbeiten, keine Seite „Heute“,
        // kein Stummschalten, keine Ruhezeiten, keine Vorlagen).
        // Seite „Heute“ nur auf dem eigenen Demo-Server (Gast-Verbindungen bekommen sie nicht)
        let modern = !ProcessInfo.processInfo.arguments.contains("-oldserver")
        return Health(ok: true, version: "demo", userName: "Arman", search: modern, messageEdit: modern,
                      today: modern && guestServer == nil, mute: modern, quietHours: modern,
                      templates: modern ? 1 : nil, taskArchiveCleanup: modern)
    }

    func bots() async throws -> [Bot] {
        bots.map { b in var b = b; b.lastMessage = messages[b.id]?.last; return b }
    }

    func createBot(_ draft: BotDraft) async throws -> Bot {
        try? await Task.sleep(for: .seconds(1.6))   // wie der echte Server: Anlegen dauert einen Moment
        let bot = Bot(id: nextID("b"), name: draft.name, label: draft.label, mascot: draft.mascot,
                      character: draft.character, model: draft.model ?? BotModel.haiku.rawValue,
                      pinned: false, section: nil, createdAt: Date())
        bots.append(bot)
        messages[bot.id] = []
        Task {
            guard await pause(0.7) else { return }
            emit(.botTyping(chatId: bot.id, botId: bot.id, typing: true))
            guard await pause(1.2) else { return }
            let hello = Message(id: nextID("m"), botId: bot.id, role: .bot,
                                text: demoText("Hi Arman, ich bin **\(bot.name)**! Sag mir einfach, wobei ich dir helfen soll, und ich merke mir, wie du es haben willst.",
                                                en: "Hi Arman, I’m **\(bot.name)**! Just tell me what you’d like help with, and I’ll remember how you like things done."),
                                createdAt: Date())
            messages[bot.id, default: []].append(hello)
            emit(.botTyping(chatId: bot.id, botId: bot.id, typing: false))
            emit(.messageCreated(hello))
        }
        return bot
    }

    func updateBot(id: String, patch: BotPatch) async throws -> Bot {
        guard let idx = bots.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Scoop nicht gefunden.", en: "Scoop not found.")) }
        if let v = patch.name { bots[idx].name = v }
        if let v = patch.label { bots[idx].label = v }
        if let v = patch.mascot { let photo = bots[idx].mascot.photo; bots[idx].mascot = v; bots[idx].mascot.photo = photo }
        if let v = patch.character { bots[idx].character = v }
        if let v = patch.model { bots[idx].model = v }
        if let v = patch.pinned { bots[idx].pinned = v }
        if let v = patch.section { bots[idx].section = (v?.isEmpty ?? true) ? nil : v }
        if let sec = bots[idx].section, !sectionList.contains(where: { $0.name == sec }) {
            sectionList.append(SidebarSection(name: sec))
        }
        if let v = patch.voice { bots[idx].voice = v }
        if let v = patch.guestTools { bots[idx].guestTools = v }
        if let v = patch.guestBudget { bots[idx].guestBudget = min(100, max(0, v)) }
        if let v = patch.computerNode {
            guard nodeList.contains(where: { $0.id == v }) else { throw APIError(status: 400, message: demoText("Unbekannter Rechner", en: "Unknown computer")) }
            bots[idx].computerNode = v
        }
        if var v = patch.computerAccess {
            if v.scope == AccessScope.projects.rawValue && v.folders.isEmpty {
                throw APIError(status: 400, message: demoText("Für „Projektordner“ bitte mindestens einen Ordner wählen.",
                                                               en: "Choose at least one folder for “Project Folders.”"))
            }
            v.modeLabel = v.accessMode.title
            v.scopeLabel = v.accessScope.title
            bots[idx].computerAccess = v
        }
        if let v = patch.canReview {
            bots[idx].canReview = v
            bots[idx].reviewer = v || bots[idx].primary
        }
        if let v = patch.primary {
            if v { for i in bots.indices where bots[i].id != id && bots[i].primary {
                bots[i].primary = false
                var other = bots[i]; other.lastMessage = messages[other.id]?.last
                emit(.botUpdated(other))
            } }
            bots[idx].primary = v
        }
        var b = bots[idx]
        b.lastMessage = messages[id]?.last
        return b
    }

    // MARK: Eigenes Scoop-Bild (v1.12)

    /// Hochgeladene Bilder im Speicher. Nora hat im Demo-Modus von Anfang an ein erzeugtes Testbild.
    private var avatars: [String: Data] = [:]

    func uploadAvatar(botID: String, data: Data) async throws -> Bot {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { throw APIError(status: 404, message: demoText("Scoop nicht gefunden.", en: "Scoop not found.")) }
        guard ScoopPhotoCoding.image(from: data) != nil else { throw APIError(status: 400, message: demoText("Kein lesbares Bild", en: "Not a readable image")) }
        try? await Task.sleep(for: .milliseconds(400))
        avatars[botID] = data
        bots[idx].mascot.photo = MascotPhoto(id: botID, version: Int(Date().timeIntervalSince1970 * 1000))
        var b = bots[idx]; b.lastMessage = messages[botID]?.last
        emit(.botUpdated(b))
        return b
    }

    func deleteAvatar(botID: String) async throws -> Bot {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { throw APIError(status: 404, message: demoText("Scoop nicht gefunden.", en: "Scoop not found.")) }
        avatars[botID] = nil
        bots[idx].mascot.photo = nil
        var b = bots[idx]; b.lastMessage = messages[botID]?.last
        emit(.botUpdated(b))
        return b
    }

    func avatarData(botID: String, version: Int) async throws -> Data {
        if let data = avatars[botID] { return data }
        guard bots.first(where: { $0.id == botID })?.mascot.photo != nil else { throw APIError(status: 404, message: demoText("Kein eigenes Bild", en: "No custom image")) }
        return Self.demoPhotoData()
    }

    /// Erzeugtes Testbild (Abendhimmel mit Sonne und Hügeln) – bewusst kein echtes Foto.
    static func demoPhotoData() -> Data {
        let view = ZStack {
            LinearGradient(colors: [Color(hex: "#1E2A78"), Color(hex: "#7B3FA0"), Color(hex: "#FF7A59"), Color(hex: "#FFC36B")],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hex: "#FFE9A8")).frame(width: 170, height: 170).blur(radius: 2).offset(y: 40)
            Circle().fill(Color(hex: "#FFE9A8").opacity(0.35)).frame(width: 260, height: 260).blur(radius: 30).offset(y: 40)
            Ellipse().fill(Color(hex: "#2B2350")).frame(width: 700, height: 260).offset(x: -120, y: 230)
            Ellipse().fill(Color(hex: "#3A2F63")).frame(width: 640, height: 230).offset(x: 190, y: 250)
            Ellipse().fill(Color(hex: "#15122B")).frame(width: 760, height: 220).offset(y: 300)
        }
        .frame(width: 512, height: 512)
        .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { return Data() }
        return ScoopPhotoCoding.encode(cg) ?? Data()
    }

    func deleteBot(id: String) async throws {
        bots.removeAll { $0.id == id }
        messages[id] = nil
        for i in groupList.indices { groupList[i].memberIds.removeAll { $0 == id } }
    }

    // MARK: Chats

    func messages(chatID: String, before: String?, limit: Int) async throws -> [Message] {
        // `-mocklatency <ms>`: Ladezeit wie beim echten Server (Chat öffnen nach Kaltstart nachstellen)
        if DemoArgs.latency > 0 { try? await Task.sleep(for: .milliseconds(DemoArgs.latency)) }
        let all = messages[chatID] ?? []
        var end = all.count
        if let before, let idx = all.firstIndex(where: { $0.id == before }) { end = idx }
        return Array(all[max(0, end - limit)..<end])
    }

    func send(chatID: String, message: OutgoingMessage) async throws -> Message {
        try? await Task.sleep(for: .milliseconds(350))
        var meta = MessageMeta(fileIds: message.fileIds)
        if message.voice == true { meta.voice = true }
        if guestServer != nil {
            // Server des Admins trägt den Absender ein (Gast = Demo-Konto)
            meta.authorUserId = MockCloudService.demoUser.id
            meta.authorName = MockCloudService.demoUser.name
        }
        meta.replyTo = replyRef(chatID: chatID, id: message.replyTo)
        let m = Message(id: nextID("m"), botId: chatID, role: .user, text: message.text, createdAt: Date(), meta: meta)
        messages[chatID, default: []].append(m)
        if ChatGroup.isGroupID(chatID) {
            let replied = meta.replyTo?.role == "bot" ? meta.replyTo?.authorId : nil
            simulateGroupRun(groupID: chatID, prompt: message.text, repliedTo: replied)
        } else {
            simulateRun(chatID: chatID, author: nil, prompt: message.text, voice: message.voice == true)
        }
        return m
    }

    // MARK: Suche und Chat-Komfort (App 1.3, `ChatComfortService`)

    /// Wie `GET /api/search`: alle Wörter müssen vorkommen, neueste zuerst, Ausschnitt mit Markierung.
    func searchMessages(query: String, chatID: String?, limit: Int) async throws -> SearchResponse {
        try? await Task.sleep(for: .milliseconds(max(DemoArgs.latency, 220)))
        let tokens = LocalSearch.tokens(query)
        guard !tokens.isEmpty, tokens.reduce(0, { $0 + $1.count }) >= 2 else { return SearchResponse(hits: [], total: 0, truncated: false) }
        var found: [Message] = []
        for (id, list) in messages where chatID == nil || chatID == id {
            found += list.filter { LocalSearch.matches($0, tokens: tokens) }
        }
        found.sort { $0.createdAt > $1.createdAt }
        let hits = found.prefix(limit).map { m -> SearchHit in
            let (snippet, marks) = LocalSearch.snippet(LocalSearch.searchableText(m), tokens: tokens)
            let group = ChatGroup.isGroupID(m.chatId)
            let chatName = group ? groupList.first { $0.id == m.chatId }?.name : bots.first { $0.id == m.chatId }?.name
            let author = m.meta.authorId ?? (group ? nil : m.chatId)
            let authorName = m.role == .user ? (m.meta.authorName ?? "Arman") : (bots.first { $0.id == author }?.name ?? chatName)
            return SearchHit(messageId: m.id, chatId: m.chatId, chatKind: group ? "group" : "bot", chatName: chatName,
                             role: m.role, authorId: m.role == .user ? m.meta.authorUserId : author, authorName: authorName,
                             createdAt: m.createdAt, snippet: snippet, marks: marks)
        }
        return SearchResponse(hits: Array(hits), total: found.count, truncated: found.count > hits.count)
    }

    func messagesAround(chatID: String, messageID: String, before: Int, after: Int) async throws -> MessageWindow {
        if DemoArgs.latency > 0 { try? await Task.sleep(for: .milliseconds(DemoArgs.latency)) }
        let all = messages[chatID] ?? []
        guard let idx = all.firstIndex(where: { $0.id == messageID }) else {
            throw APIError(status: 404, message: demoText("Nachricht nicht gefunden", en: "Message not found"))
        }
        let lo = max(0, idx - before), hi = min(all.count, idx + after + 1)
        return MessageWindow(messages: Array(all[lo..<hi]), hasOlder: lo > 0, hasNewer: hi < all.count)
    }

    func messagesAfter(chatID: String, messageID: String, limit: Int) async throws -> [Message] {
        let all = messages[chatID] ?? []
        guard let idx = all.firstIndex(where: { $0.id == messageID }) else { return [] }
        return Array(all[(idx + 1)..<min(all.count, idx + 1 + limit)])
    }

    /// Wie `PATCH /api/messages/{id}`: Der Lauf hält an, die Antwort auf die alte Fassung verschwindet und der Scoop
    /// antwortet neu. Steht dazwischen eine Freigabe-Karte oder ein Ereignis, bleibt alles stehen und der Scoop bekommt
    /// die Korrektur als neuen Auftrag („Nachricht bearbeitet“).
    func editMessage(id: String, text: String) async throws -> Message {
        try? await Task.sleep(for: .milliseconds(300))
        guard let chatID = messages.first(where: { $0.value.contains { $0.id == id } })?.key,
              var list = messages[chatID], let idx = list.firstIndex(where: { $0.id == id }), list[idx].role == .user else {
            throw APIError(status: 404, message: demoText("Nachricht nicht gefunden", en: "Message not found"))
        }
        guard !list[(idx + 1)...].contains(where: { $0.role == .user }) else {
            throw APIError(status: 409, message: demoText("Nur deine jüngste Nachricht lässt sich bearbeiten. Ältere kannst du erneut senden.",
                                                           en: "Only your latest message can be edited. You can resend older ones."))
        }
        runs[chatID]?.cancel()
        runs[chatID] = nil
        let followers = Array(list[(idx + 1)...])
        let clean = followers.allSatisfy { $0.role == .bot || ($0.role == .status && $0.meta.task == nil) }
        var edited = list[idx]
        edited.text = text
        edited.meta.voice = nil
        edited.meta.edited = MessageMeta.EditInfo(at: Date(), mode: clean ? "replaced" : "corrected")
        list[idx] = edited
        if clean { list.removeSubrange((idx + 1)...) }
        messages[chatID] = list
        emit(.messageUpdated(edited))
        if clean {
            for m in followers { emit(.messageDeleted(id: m.id, chatId: chatID)) }
        } else {
            for m in followers where m.isRunning {
                var stopped = m
                stopped.meta.state = "stopped"
                stopped.meta.finishedAt = Date()
                replace(stopped)
                emit(.messageUpdated(stopped))
            }
            let note = Message(id: nextID("m"), botId: chatID, role: .event, text: demoText("Nachricht bearbeitet", en: "Message edited"), createdAt: Date(),
                               meta: MessageMeta(icon: "pencil"))
            messages[chatID, default: []].append(note)
            emit(.messageCreated(note))
        }
        emit(.botTyping(chatId: chatID, botId: chatID, typing: false))
        setBusy(chatID, member: chatID, false)
        if ChatGroup.isGroupID(chatID) {
            simulateGroupRun(groupID: chatID, prompt: text)
        } else {
            simulateRun(chatID: chatID, author: nil, prompt: text, voice: false)
        }
        return edited
    }

    /// Demo `-incoming <chat-id> [sekunden]`: Nachrichten treffen von selbst ein (siehe `ComfortDemo.incoming`).
    private func scheduleDemoIncoming() {
        guard let plan = ComfortDemo.incoming, guestServer == nil else { return }
        Task {
            guard await pause(plan.delay) else { return }
            for text in ComfortDemo.incomingTexts {
                let author = ChatGroup.isGroupID(plan.chatID) ? groupList.first { $0.id == plan.chatID }?.memberIds.first : nil
                let m = Message(id: nextID("m"), botId: plan.chatID, role: .bot, text: text, createdAt: Date(),
                                meta: MessageMeta(authorId: author))
                messages[plan.chatID, default: []].append(m)
                emit(.messageCreated(m))
                guard await pause(1.5) else { return }
            }
        }
    }

    /// Wie der Server (v1.15): nur Nutzer-/Scoop-Nachrichten desselben Chats, Auszug höchstens 200 Zeichen.
    private func replyRef(chatID: String, id: String?) -> ReplyRef? {
        guard let id, let m = messages[chatID]?.first(where: { $0.id == id }), m.role == .user || m.role == .bot
        else { return nil }
        var text = MarkdownText.plain(m.text)
        if text.count > 200 { text = String(text.prefix(199)).trimmingCharacters(in: .whitespaces) + "…" }
        if text.isEmpty, m.meta.fileIds?.isEmpty == false { text = demoText("Anhang", en: "Attachment") }
        if m.role == .user {
            return ReplyRef(id: m.id, role: "user", authorId: m.meta.authorUserId,
                            authorName: m.meta.authorName ?? "Arman", text: text)
        }
        let author = m.meta.authorId ?? chatID
        return ReplyRef(id: m.id, role: "bot", authorId: author,
                        authorName: bots.first { $0.id == author }?.name ?? "Scoop", text: text)
    }

    /// Wer in der Gruppe antwortet: @Name, @alle, der zitierte Scoop oder (ohne Erwähnung) das erste passende Mitglied.
    private func simulateGroupRun(groupID: String, prompt: String, repliedTo: String? = nil) {
        guard let group = groupList.first(where: { $0.id == groupID }) else { return }
        let members = group.memberIds.compactMap { id in bots.first { $0.id == id } }
        var responders: [Bot]
        if prompt.localizedCaseInsensitiveContains("@alle")
            || (!AppLanguage.isGerman && ["@all", "@everyone"].contains { prompt.localizedCaseInsensitiveContains($0) }) {
            responders = members
        } else {
            responders = members.filter { prompt.localizedCaseInsensitiveContains("@\($0.name)") }
            if responders.isEmpty, let replied = members.first(where: { $0.id == repliedTo }) { responders = [replied] }
            if responders.isEmpty, let first = members.first { responders = [first] }
        }
        runs[groupID]?.cancel()
        runs[groupID] = Task {
            for bot in responders {
                await runSteps(chatID: groupID, author: bot.id, prompt: prompt, voice: false)
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func simulateRun(chatID: String, author: String?, prompt: String, voice: Bool) {
        runs[chatID]?.cancel()
        runs[chatID] = Task {
            await runSteps(chatID: chatID, author: author, prompt: prompt, voice: voice)
        }
    }

    private func runSteps(chatID: String, author: String?, prompt: String, voice: Bool) async {
        let speaker = author ?? chatID
        guard await pause(0.5) else { return }
        emit(.botTyping(chatId: chatID, botId: speaker, typing: true))
        setBusy(chatID, member: speaker, true)
        // Passende Themen-Antwort (z. B. Startvorschläge der Einführung) braucht keinen Rechner
        let usesComputer = Self.topicReply(to: prompt) == nil
            && (Self.asksForSearch(prompt) || prompt.localizedCaseInsensitiveContains("browser"))
        var status = Message(id: nextID("m"), botId: chatID, role: .status, text: "", createdAt: Date(),
                             meta: MessageMeta(runId: nextID("r"), state: "running", lines: [demoText("Denkt nach", en: "Thinking")],
                                               usesComputer: usesComputer, model: BotModel.haiku.rawValue,
                                               startedAt: Date(), authorId: author))
        messages[chatID, default: []].append(status)
        emit(.messageCreated(status))
        if usesComputer { emit(.computerUpdated(ComputerState(state: "busy", botId: speaker))) }
        let answer = demoText("Formuliert eine Antwort", en: "Writes a reply")
        let steps = usesComputer ? [demoText("Öffnet den Browser", en: "Opens the browser"),
                                    demoText("Sucht im Netz", en: "Searches the web"),
                                    demoText("Vergleicht Ergebnisse", en: "Compares results")]
                                 : (voice ? [answer] : [demoText("Schaut in sein Gedächtnis", en: "Checks its memory"), answer])
        for step in steps {
            guard await pause(voice ? 0.6 : 1.1) else { return }
            status.meta.lines?.append(step)
            replace(status)
            emit(.messageUpdated(status))
        }
        guard await pause(0.6) else { return }
        status.meta.state = "done"
        status.meta.finishedAt = Date()
        status.meta.costUsd = 0.0014
        replace(status)
        emit(.messageUpdated(status))
        let name = bots.first { $0.id == speaker }?.name ?? "Scoop"
        let reply = Message(id: nextID("m"), botId: chatID, role: .bot,
                            text: Self.reply(to: prompt, name: name, voice: voice, inGroup: author != nil),
                            createdAt: Date(), meta: MessageMeta(authorId: author))
        messages[chatID, default: []].append(reply)
        emit(.botTyping(chatId: chatID, botId: speaker, typing: false))
        emit(.messageCreated(reply))
        setBusy(chatID, member: speaker, false)
        if usesComputer { emit(.computerUpdated(ComputerState(state: "awake", botId: nil))) }
    }

    private static func reply(to prompt: String, name: String, voice: Bool, inGroup: Bool) -> String {
        if voice {
            return demoText("Klar, mache ich. Das ist eine Demo-Antwort im Sprachmodus, ganz ohne Markdown, damit ich sie dir vorlesen kann.",
                            en: "Sure, I’ll do that. This is a demo reply in voice mode, without any Markdown, so I can read it aloud to you.")
        }
        if inGroup {
            return demoText("Hier \(name): Ich übernehme das. Das ist eine **Demo-Antwort** aus der Gruppe.",
                            en: "\(name) here: I’ll take care of it. This is a **demo reply** from the group.")
        }
        if let topical = topicReply(to: prompt) { return topical }
        if asksForSearch(prompt) {
            return demoText("Ich hab drei passende Treffer gefunden:\n\n- **Hotel Rheinblick**, 128 €, 4 min zum Bahnhof\n- **Deutzer Hof**, 119 €, mit Frühstück\n- **Kompakt Inn**, 99 €, etwas laut\n\nSoll ich eins davon reservieren?",
                            en: "I found three good matches:\n\n- **The Harborview**, $229, 4 min to the station\n- **Back Bay Inn**, $209, breakfast included\n- **Compact Inn**, $179, a bit noisy\n\nWant me to book one of them?")
        }
        return demoText("Mach ich! Das ist eine **Demo-Antwort**, im echten Betrieb antwortet hier dein Scoop vom Server.",
                        en: "On it! This is a **demo reply**. In real use, your Scoop replies here from your server.")
    }

    /// Bittet die Nachricht um eine Suche? Deutsch „such…“ wie bisher; auf Englisch search, find, look for/up.
    private static func asksForSearch(_ prompt: String) -> Bool {
        let words = AppLanguage.isGerman ? ["such"] : ["search", "find", "look for", "look up"]
        return words.contains { prompt.localizedCaseInsensitiveContains($0) }
    }

    /// Antworten, die zum Thema passen (vor allem die Startvorschläge der Einführung, OnboardingPurpose), damit
    /// Demo und Screenshots keine unpassende Antwort zeigen.
    private static func topicReply(to prompt: String) -> String? {
        let p = prompt.lowercased()
        // Englische Stichwörter nur auf Englisch, damit sich auf Deutsch nichts ändert
        func has(_ words: String..., en: String...) -> Bool {
            (words + (AppLanguage.isGerman ? [] : en)).contains { p.contains($0) }
        }
        if has("rezept", "kürbis", "suppe", en: "recipe", "pumpkin", "soup") {
            return demoText("Hier sind drei einfache Rezepte für Kürbissuppe:\n\n- **Klassisch mit Hokkaido**: Kürbis, Zwiebel, Brühe, ein Schuss Sahne, 30 Minuten\n- **Mit Kokos und Ingwer**: Kokosmilch, frischer Ingwer, etwas Limette, 25 Minuten\n- **Ofenkürbis mit Apfel**: Kürbis und Apfel rösten, dann pürieren, 40 Minuten\n\nSoll ich dir für eins die Einkaufsliste schreiben?",
                            en: "Here are three easy pumpkin soup recipes:\n\n- **Classic with butternut squash**: squash, onion, broth, a splash of cream, 30 minutes\n- **With coconut and ginger**: coconut milk, fresh ginger, a little lime, 25 minutes\n- **Roasted pumpkin and apple**: roast pumpkin and apple, then blend, 40 minutes\n\nWant me to write you a shopping list for one of them?")
        }
        if has("erinner", en: "remind") {
            return demoText("Erledigt! Ich erinnere dich **morgen um 9:00** an den Zahnarzt. Soll ich dich zusätzlich am Vorabend vorwarnen?",
                            en: "Done! I’ll remind you about the dentist **tomorrow at 9:00 AM**. Want a heads-up the evening before, too?")
        }
        if has("merk dir", en: "remember") {
            return demoText("Gemerkt: Du trinkst **keinen Kaffee**. Ich schlage dir künftig Tee oder etwas anderes vor.",
                            en: "Got it: you **don’t drink coffee**. From now on, I’ll suggest tea or something else instead.")
        }
        if has("was kannst du", en: "what can you do") {
            return demoText("Eine ganze Menge! Zum Beispiel:\n\n- **Recherchieren** und Ergebnisse zusammenfassen\n- **Texte schreiben**: Mails, Absagen, Glückwünsche\n- **An Dinge erinnern** und Termine im Blick behalten\n- **Mir merken**, was dir wichtig ist\n\nWomit fangen wir an?",
                            en: "Quite a lot! For example:\n\n- **Research** things and summarize the results\n- **Write**: emails, polite no’s, congratulations\n- **Remind you** of things and keep an eye on your calendar\n- **Remember** what matters to you\n\nWhere should we start?")
        }
        if has("ki-welt", "neues", en: "what's new", "what’s new", "whats new", "ai news") {
            return demoText("Drei Themen, über die gerade viel gesprochen wird:\n\n- **Kleinere Modelle**, die direkt auf dem Gerät laufen\n- **KI-Helfer**, die selbstständig Aufgaben am Computer erledigen\n- **Neue Regeln** für KI in der EU\n\nSoll ich bei einem Thema tiefer graben?",
                            en: "Three topics everyone’s talking about right now:\n\n- **Smaller models** that run right on your device\n- **AI helpers** that get tasks done on a computer on their own\n- **New rules** for AI in the US and the EU\n\nWant me to dig deeper into one of them?")
        }
        if has("absage", en: "declin", "can't make", "can’t make") {
            return demoText("Wie wäre es damit?\n\n> Hallo zusammen, leider schaffe ich es morgen nicht zum Meeting. Ich lese das Protokoll nach und melde mich, falls ich etwas beitragen kann. Danke für euer Verständnis!\n\nSoll ich es noch kürzer oder förmlicher machen?",
                            en: "How about this?\n\n> Hi everyone, unfortunately I can’t make it to tomorrow’s meeting. I’ll read the notes afterward and reach out if I have anything to add. Thanks for understanding!\n\nWant it shorter or more formal?")
        }
        if has("geburtstag", en: "birthday") {
            return demoText("Ein Vorschlag:\n\n> Alles Liebe zum Geburtstag! Auf ein Jahr voller schöner Momente, guter Gespräche und mindestens einem richtig großen Stück Kuchen.\n\nFür wen ist die Karte? Dann mache ich sie persönlicher.",
                            en: "Here’s an idea:\n\n> Happy birthday! Here’s to a year full of great moments, good conversations, and at least one really big slice of cake.\n\nWho’s the card for? Then I can make it more personal.")
        }
        if has("woche", en: "my week") {
            return demoText("Gern! Erzähl mir kurz, was diese Woche fest ansteht (Termine, Abgaben, Sport). Dann verteile ich den Rest so, dass jeder Tag machbar bleibt.",
                            en: "Sure! Tell me what’s already set this week (meetings, deadlines, workouts). Then I’ll spread out the rest so every day stays manageable.")
        }
        if has("packliste", en: "packing") {
            return demoText("Für ein Wochenende am See:\n\n- Badesachen und Handtuch\n- Sonnencreme und Kappe\n- Pulli für den Abend\n- Snacks und Wasserflasche\n- Ladekabel\n\nZeltet ihr oder schlaft ihr in einer Unterkunft?",
                            en: "For a weekend at the lake:\n\n- Swimsuit and towel\n- Sunscreen and a cap\n- A sweater for the evening\n- Snacks and a water bottle\n- Charging cable\n\nAre you camping or staying somewhere?")
        }
        if has("kredit", en: "loan", "credit") {
            return demoText("Ganz einfach: Die Bank leiht dir Geld, und du zahlst es in **Raten** zurück. Dazu kommen **Zinsen**, das ist der Preis fürs Leihen. Je länger die Laufzeit, desto kleiner die Rate, aber desto mehr Zinsen zahlst du insgesamt.",
                            en: "It’s simple: the bank lends you money, and you pay it back in **installments**. On top of that comes **interest**, which is the price of borrowing. The longer the term, the smaller each payment, but the more interest you pay overall.")
        }
        if has("vokabel", en: "vocab", "quiz me") {
            return demoText("Los geht’s! Was heißt **„Eichhörnchen“** auf Englisch?",
                            en: "Let’s go! How do you say **“squirrel”** in Spanish?")
        }
        if has("witz", en: "joke") {
            return demoText("Treffen sich zwei Kürbisse. Sagt der eine: „Na, was machst du an Halloween?“ – „Ich hab nichts vor, bin eher der ausgehöhlte Typ.“ 🎃",
                            en: "Two pumpkins meet. One asks, “So, what are you doing for Halloween?” The other says, “Nothing much. I’m feeling a little hollow.” 🎃")
        }
        if has("wer bist du", "hallo", en: "who are you", "hello") {
            return demoText("Hallo! Ich bin dein neuer Scoop. Sag mir einfach, wobei ich dir helfen kann.",
                            en: "Hi! I’m your new Scoop. Just tell me what I can help you with.")
        }
        return nil
    }

    private func replace(_ m: Message) {
        guard let idx = messages[m.botId]?.firstIndex(where: { $0.id == m.id }) else { return }
        messages[m.botId]?[idx] = m
    }

    private func setBusy(_ chatID: String, member: String, _ busy: Bool) {
        if ChatGroup.isGroupID(chatID) {
            guard let idx = groupList.firstIndex(where: { $0.id == chatID }) else { return }
            if busy { groupList[idx].busyIds.append(member) } else { groupList[idx].busyIds.removeAll { $0 == member } }
            groupList[idx].busy = !groupList[idx].busyIds.isEmpty
            var g = groupList[idx]
            g.lastMessage = messages[chatID]?.last
            emit(.groupUpdated(g))
            return
        }
        guard let idx = bots.firstIndex(where: { $0.id == chatID }) else { return }
        bots[idx].busy = busy
        var b = bots[idx]
        b.lastMessage = messages[chatID]?.last
        emit(.botUpdated(b))
    }

    func stopTask(id: String) async throws {
        for (chatID, list) in messages {
            guard var m = list.last(where: { $0.meta.task?.id == id && $0.isRunning }) else { continue }
            m.meta.state = "stopped"
            m.meta.task?.state = "stopped"
            m.meta.finishedAt = Date()
            replace(m)
            emit(.messageUpdated(m))
            _ = chatID
        }
    }

    func stop(chatID: String) async throws {
        runs[chatID]?.cancel()
        runs[chatID] = nil
        if var running = messages[chatID]?.last(where: { $0.isRunning }) {
            running.meta.state = "stopped"
            running.meta.finishedAt = Date()
            replace(running)
            emit(.messageUpdated(running))
            emit(.botTyping(chatId: chatID, botId: running.meta.authorId ?? chatID, typing: false))
            setBusy(chatID, member: running.meta.authorId ?? chatID, false)
        } else {
            setBusy(chatID, member: chatID, false)
        }
        emit(.computerUpdated(ComputerState(state: "awake", botId: nil)))
    }

    func markRead(chatID: String) async throws {
        if let idx = bots.firstIndex(where: { $0.id == chatID }) { bots[idx].unread = 0 }
        if let idx = groupList.firstIndex(where: { $0.id == chatID }) { groupList[idx].unread = 0 }
    }

    func reset(chatID: String) async throws { messages[chatID] = [] }

    // MARK: Profil

    func memories(botID: String) async throws -> [Memory] {
        let shared = PreviewData.memories["b_mila"]?.filter { $0.botId == nil } ?? []
        let own = (memories[botID] ?? []).filter { $0.botId != nil }
        return own + shared
    }

    func deleteMemory(id: String) async throws {
        for key in memories.keys { memories[key]?.removeAll { $0.id == id } }
    }

    func routines(botID: String) async throws -> [Routine] { routines[botID] ?? [] }

    /// Demodaten für die Seite „Heute“ (Views/Today/TodayMock.swift): Nachrichten, Routinen und Scoops, wie sie gerade sind
    var todaySource: (messages: [String: [Message]], routines: [Routine], bots: [Bot], isGuest: Bool) {
        (messages, routines.values.flatMap { $0 }, bots, guestServer != nil)
    }

    func setRoutine(id: String, enabled: Bool) async throws -> Routine {
        for key in routines.keys {
            if let idx = routines[key]?.firstIndex(where: { $0.id == id }) {
                routines[key]?[idx].enabled = enabled
                return routines[key]![idx]
            }
        }
        throw APIError(status: 404, message: demoText("Routine nicht gefunden.", en: "Routine not found."))
    }

    func deleteRoutine(id: String) async throws {
        for key in routines.keys { routines[key]?.removeAll { $0.id == id } }
    }

    func runRoutine(id: String) async throws {
        guard let r = routines.values.flatMap({ $0 }).first(where: { $0.id == id }) else { return }
        let event = Message(id: nextID("m"), botId: r.botId, role: .event,
                            text: demoText("Routine ausgelöst: \(r.title)", en: "Routine triggered: \(r.title)"),
                            createdAt: Date(), meta: MessageMeta(icon: "clock"))
        messages[r.botId, default: []].append(event)
        emit(.messageCreated(event))
        simulateRun(chatID: r.botId, author: nil, prompt: r.prompt ?? r.title, voice: false)
    }

    func decideMail(approvalID: String, approve: Bool, edits: MailEdits?) async throws -> Message {
        guard let key = messages.keys.first(where: { messages[$0]?.contains { $0.meta.approvalId == approvalID } == true }),
              let idx = messages[key]?.firstIndex(where: { $0.meta.approvalId == approvalID }),
              var mail = messages[key]?[idx].meta.mail else {
            throw APIError(status: 404, message: demoText("Freigabe nicht gefunden.", en: "Approval not found."))
        }
        guard mail.status == "draft" || mail.status == "failed" else {
            throw APIError(status: 409, message: demoText("Diese Mail ist schon erledigt.", en: "This email has already been handled."))
        }
        if approve {
            if let e = edits {
                if let a = e.account {
                    mail.account = a
                    mail.accountEmail = PreviewData.connections.apps.first { $0.slug == "gmail" }?
                        .accounts.first { $0.alias == a }?.email ?? mail.accountEmail
                }
                if let to = e.to { mail.to = to }
                if let cc = e.cc { mail.cc = cc }
                if let subject = e.subject { mail.subject = subject }
                if let body = e.body { mail.body = body }
            }
            mail.status = "sending"
            mail.error = nil
            messages[key]?[idx].meta.state = "approved"
        } else {
            mail.status = "discarded"
            messages[key]?[idx].meta.state = "declined"
        }
        messages[key]?[idx].meta.mail = mail
        let result = messages[key]![idx]
        let id = result.id
        let finalMail = mail
        Task {
            guard await pause(approve ? 1.6 : 0.3) else { return }
            guard let i = messages[key]?.firstIndex(where: { $0.id == id }) else { return }
            var text = demoText("Mail verworfen: \(finalMail.subject)", en: "Email discarded: \(finalMail.subject)")
            if approve {
                // Demo: Adressen mit „fehler“ (englisch „error“) scheitern, damit sich der Fehlerzustand zeigen lässt
                let failing = AppLanguage.isGerman ? "fehler" : "error"
                if finalMail.to.contains(where: { $0.contains(failing) }) {
                    messages[key]?[i].meta.mail?.status = "failed"
                    messages[key]?[i].meta.mail?.error = demoText("Gmail hat die Adresse abgelehnt (550 Empfänger unbekannt).",
                                                                  en: "Gmail rejected the address (550 recipient unknown).")
                    emit(.messageUpdated(messages[key]![i]))
                    return
                }
                messages[key]?[i].meta.mail?.status = "sent"
                messages[key]?[i].meta.mail?.sentAt = Date()
                emit(.messageUpdated(messages[key]![i]))
                text = demoText("Mail gesendet an \(finalMail.to.joined(separator: ", "))",
                                en: "Email sent to \(finalMail.to.joined(separator: ", "))")
            }
            let event = Message(id: nextID("m"), botId: key, role: .event, text: text, createdAt: Date(),
                                meta: MessageMeta(icon: approve ? "paperplane" : "trash"))
            messages[key, default: []].append(event)
            emit(.messageCreated(event))
        }
        return result
    }

    func decideVault(approvalID: String, approve: Bool, edits: VaultEdits?) async throws -> Message {
        try? await Task.sleep(for: .milliseconds(approve ? 700 : 250))
        guard let key = messages.keys.first(where: { messages[$0]?.contains { $0.meta.approvalId == approvalID } == true }),
              let idx = messages[key]?.firstIndex(where: { $0.meta.approvalId == approvalID }),
              var vault = messages[key]?[idx].meta.vault else {
            throw APIError(status: 404, message: demoText("Freigabe nicht gefunden.", en: "Approval not found."))
        }
        guard vault.status == "pending" else { throw APIError(status: 409, message: demoText("Dieser Login ist schon erledigt.", en: "This login has already been handled.")) }
        if approve {
            // Wie der Server: Passwort ist Pflicht (400). Demo: „fehler“ (englisch „error“) scheitert, um den Fehlerzustand zu zeigen.
            guard let edits, !edits.password.isEmpty else { throw APIError(status: 400, message: demoText("Bitte gib ein Passwort ein.", en: "Please enter a password.")) }
            if edits.password == (AppLanguage.isGerman ? "fehler" : "error") {
                throw APIError(status: 400, message: demoText("Der Schlüsselbund auf dem Bot-Rechner hat das Speichern abgelehnt.", en: "The keychain on the bot computer refused to save it."))
            }
            if let u = edits.username { vault.username = u }
            vault.status = "saved"
            vault.vaultId = nextID("v")
            messages[key]?[idx].meta.state = "approved"
        } else {
            vault.status = "declined"
            messages[key]?[idx].meta.state = "declined"
        }
        messages[key]?[idx].meta.vault = vault
        let result = messages[key]![idx]
        let saved = vault
        let author = result.meta.authorId
        Task {
            guard await pause(0.4) else { return }
            let text = approve ? demoText("Login gespeichert: \(saved.title)", en: "Login saved: \(saved.title)")
                               : demoText("Login nicht gespeichert: \(saved.title)", en: "Login not saved: \(saved.title)")
            let event = Message(id: nextID("m"), botId: key, role: .event, text: text, createdAt: Date(),
                                meta: MessageMeta(icon: approve ? "key.fill" : "key.slash"))
            messages[key, default: []].append(event)
            emit(.messageCreated(event))
            guard approve, await pause(1.0) else { return }
            let reply = Message(id: nextID("m"), botId: key, role: .bot,
                                text: demoText("Danke! Ich melde mich jetzt bei **\(saved.site ?? saved.title)** an und mache weiter.",
                                                en: "Thanks! I’m signing in to **\(saved.site ?? saved.title)** now and will keep going."),
                                createdAt: Date(), meta: MessageMeta(authorId: author))
            messages[key, default: []].append(reply)
            emit(.messageCreated(reply))
        }
        return result
    }

    func react(messageID: String, emoji: String?) async throws -> Message {
        try? await Task.sleep(for: .milliseconds(150))
        for key in messages.keys {
            if let idx = messages[key]?.firstIndex(where: { $0.id == messageID }) {
                var reactions = messages[key]![idx].meta.reactions ?? [:]
                reactions["user"] = emoji
                messages[key]![idx].meta.reactions = reactions.isEmpty ? nil : reactions
                let m = messages[key]![idx]
                emit(.messageUpdated(m))
                return m
            }
        }
        throw APIError(status: 404, message: demoText("Nachricht nicht gefunden.", en: "Message not found."))
    }

    func decideAlways(approvalID: String, mailEdits: MailEdits?) async throws -> Message {
        guard let key = messages.keys.first(where: { messages[$0]?.contains { $0.meta.approvalId == approvalID } == true }),
              let original = messages[key]?.first(where: { $0.meta.approvalId == approvalID }) else {
            throw APIError(status: 404, message: demoText("Freigabe nicht gefunden.", en: "Approval not found."))
        }
        guard original.meta.canAlways == true else {
            throw APIError(status: 400, message: demoText("Diese Freigabe kann nicht dauerhaft erlaubt werden.", en: "This approval can’t be set to Always Allow."))
        }
        var m: Message
        if original.meta.mail != nil {
            m = try await decideMail(approvalID: approvalID, approve: true, edits: mailEdits)
        } else {
            m = try await decide(approvalID: approvalID, approve: true, note: nil)
        }
        m.meta.always = true
        if let idx = messages[key]?.firstIndex(where: { $0.id == m.id }) { messages[key]?[idx].meta.always = true }
        let botID = original.meta.authorId ?? key
        let label = original.meta.alwaysLabel ?? original.meta.title ?? demoText("Freigabe", en: "Approval")
        if standing[botID]?.contains(where: { $0.label == label }) != true {
            standing[botID, default: []].append(StandingApproval(id: nextID("sa"), botId: botID, key: "freigabe:\(label)",
                                                                 label: label, kind: original.meta.mail != nil ? "mail" : "freigabe",
                                                                 createdAt: Date()))
        }
        let event = Message(id: nextID("m"), botId: key, role: .event, text: demoText("Immer erlaubt: \(label)", en: "Always allowed: \(label)"),
                            createdAt: Date(),
                            meta: MessageMeta(icon: "checkmark.seal"))
        messages[key, default: []].append(event)
        emit(.messageCreated(event))
        return m
    }

    func standingApprovals(botID: String) async throws -> [StandingApproval] { standing[botID] ?? [] }

    /// v1.21: Verbesserung für einen anderen Scoop (Aufsicht) – erst nach Freigabe „angewendet“, Ereignis in beiden Chats.
    func decideScoopUpdate(approvalID: String, approve: Bool, after: String?) async throws -> Message {
        guard let key = messages.keys.first(where: { messages[$0]?.contains { $0.meta.approvalId == approvalID } == true }),
              let idx = messages[key]?.firstIndex(where: { $0.meta.approvalId == approvalID }),
              var update = messages[key]?[idx].meta.scoopUpdate else {
            throw APIError(status: 404, message: demoText("Freigabe nicht gefunden.", en: "Approval not found."))
        }
        guard messages[key]?[idx].meta.state == "pending" else { return messages[key]![idx] }
        update.status = approve ? "applied" : "declined"
        if approve, let after, !after.isEmpty, after != update.after { update.after = after; update.edited = true }
        messages[key]?[idx].meta.state = approve ? "approved" : "declined"
        messages[key]?[idx].meta.scoopUpdate = update
        let card = messages[key]![idx]
        emit(.messageUpdated(card))
        let label = update.label ?? update.artTitle
        let event = Message(id: nextID("m"), botId: key, role: .event,
                            text: approve ? demoText("Übernommen: \(label) bei \(update.targetName)", en: "Applied: \(label) for \(update.targetName)")
                                : demoText("Abgelehnt: \(card.meta.title ?? label)", en: "Declined: \(card.meta.title ?? label)"),
                            createdAt: Date(), meta: MessageMeta(icon: approve ? "wand.and.stars" : "xmark.circle"))
        messages[key, default: []].append(event)
        emit(.messageCreated(event))
        if approve, let target = update.targetId {
            let from = bots.first { $0.id == key }?.name ?? demoText("Ein Scoop", en: "A Scoop")
            let note = Message(id: nextID("m"), botId: target, role: .event,
                               text: demoText("Verbesserung von \(from): \(label)", en: "Improvement from \(from): \(label)"),
                               createdAt: Date(), meta: MessageMeta(icon: "wand.and.stars"))
            messages[target, default: []].append(note)
            emit(.messageCreated(note))
        }
        return card
    }

    func deleteStandingApproval(botID: String, id: String) async throws {
        standing[botID]?.removeAll { $0.id == id }
    }

    func setRoutineModel(id: String, model: String?) async throws -> Routine {
        for key in routines.keys {
            if let idx = routines[key]?.firstIndex(where: { $0.id == id }) {
                routines[key]?[idx].model = model
                return routines[key]![idx]
            }
        }
        throw APIError(status: 404, message: demoText("Routine nicht gefunden.", en: "Routine not found."))
    }

    func decide(approvalID: String, approve: Bool, note: String?) async throws -> Message {
        for key in messages.keys {
            if let idx = messages[key]?.firstIndex(where: { $0.meta.approvalId == approvalID }) {
                messages[key]?[idx].meta.state = approve ? "approved" : "declined"
                let m = messages[key]![idx]
                if approve {
                    Task {
                        guard await pause(1.0) else { return }
                        let done = Message(id: nextID("m"), botId: key, role: .bot,
                                           text: demoText("Erledigt, ist raus.", en: "Done, it’s sent."), createdAt: Date())
                        messages[key, default: []].append(done)
                        emit(.messageCreated(done))
                    }
                }
                return m
            }
        }
        throw APIError(status: 404, message: demoText("Freigabe nicht gefunden.", en: "Approval not found."))
    }

    func computer(node: String) async throws -> ComputerState {
        if node == ComputerNode.builtinID { return computerState }
        guard let n = nodeList.first(where: { $0.id == node }) else { throw APIError(status: 404, message: demoText("Rechner nicht gefunden", en: "Computer not found")) }
        return n.computerState
    }
    func usage() async throws -> Usage { PreviewData.usage }
    func models() async throws -> ModelCatalog { PreviewData.modelCatalog }
    func usageDetails(range: String, source: String, refresh: Bool) async throws -> UsageDetails {
        try? await Task.sleep(for: .milliseconds(refresh ? 500 : 150))
        return UsageMockData.details(range: range, source: source)
    }
    func usageLimits(refresh: Bool) async throws -> UsageLimits {
        try? await Task.sleep(for: .milliseconds(refresh ? 600 : 150))
        return UsageMockData.limits()
    }
    func sharingSettings(botID: String) async throws -> SharingSettings {
        let b = bots.first { $0.id == botID }
        return SharingSettings(guestTools: b?.guestTools ?? .standard, guestBudget: b?.guestBudget ?? 2, options: .init(
            apps: [.init(id: "gmail", name: "Gmail"), .init(id: "googlecalendar", name: demoText("Google Kalender", en: "Google Calendar")),
                   .init(id: "notion", name: "Notion")],
            mcp: [.init(id: "atrium", name: "Atrium"), .init(id: "teamapp", name: "Team App")],
            available: ["web": true, "computer": true, "phone": true, "mail": true]))
    }

    func botUsage(botID: String) async throws -> BotUsage {
        try? await Task.sleep(for: .milliseconds(200))
        return MockGuestData.usage(botID: botID, guest: guestServer != nil)
    }
    func registerDevice(_ registration: DeviceRegistration) async throws {}
    func screenImageURL(scale: Double, quality: Int, node: String) -> URL? { nil }

    // MARK: Gruppen

    func groups() async throws -> [ChatGroup] {
        groupList.map { g in var g = g; g.lastMessage = messages[g.id]?.last; return g }
    }

    func createGroup(name: String, memberIDs: [String]) async throws -> ChatGroup {
        try? await Task.sleep(for: .seconds(1.2))
        let g = ChatGroup(id: nextID("g"), name: name, memberIds: memberIDs, createdAt: Date())
        groupList.append(g)
        let names = memberIDs.compactMap { id in bots.first { $0.id == id }?.name }
        let event = Message(id: nextID("m"), botId: g.id, role: .event,
                            text: demoText("Gruppe erstellt: \(names.joined(separator: ", "))",
                                          en: "Group created: \(names.formatted(.list(type: .and).locale(.app)))"), createdAt: Date(),
                            meta: MessageMeta(icon: "person.3"))
        messages[g.id] = [event]
        return g
    }

    func updateGroup(id: String, patch: GroupPatch) async throws -> ChatGroup {
        guard let idx = groupList.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Gruppe nicht gefunden.", en: "Group not found.")) }
        if let v = patch.name { groupList[idx].name = v }
        if let v = patch.memberIds { groupList[idx].memberIds = v }
        if let v = patch.pinned { groupList[idx].pinned = v }
        if let v = patch.section { groupList[idx].section = v }
        if let sec = groupList[idx].section, !sectionList.contains(where: { $0.name == sec }) {
            sectionList.append(SidebarSection(name: sec))
        }
        var g = groupList[idx]
        g.lastMessage = messages[id]?.last
        return g
    }

    func deleteGroup(id: String) async throws {
        groupList.removeAll { $0.id == id }
        messages[id] = nil
    }

    // MARK: Bibliothek

    func files(chatID: String) async throws -> [LibraryFile] {
        (library[chatID] ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func uploadFile(chatID: String, name: String, mime: String, data: Data,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> LibraryFile {
        for step in 1...8 {
            try await Task.sleep(for: .milliseconds(120))
            progress(Double(step) / 8)
        }
        let file = LibraryFile(id: nextID("f"), chatId: chatID, authorId: nil,
                               kind: mime.hasPrefix("image/") ? "bild" : "datei", name: name, mime: mime,
                               size: data.count, url: nil, note: nil, createdAt: Date(), downloadUrl: nil)
        library[chatID, default: []].insert(file, at: 0)
        uploads[file.id] = data
        return file
    }

    private var uploads: [String: Data] = [:]

    func deleteFile(id: String) async throws {
        for key in library.keys { library[key]?.removeAll { $0.id == id } }
    }

    func fileURL(id: String) -> URL? { nil }

    func downloadFile(_ file: LibraryFile) async throws -> URL {
        if let data = uploads[file.id] { return try FileCache.store(data, name: file.name, id: file.id) }
        return try FileCache.store(MockFiles.content(for: file), name: file.name, id: file.id)
    }

    func registerLiveActivity(chatID: String, runID: String, pushToken: String) async throws {}

    #if os(iOS)
    /// Demo: kein Server-Push; der LiveActivityManager startet die Aktivität im Demo-Modus selbst (lokal).
    func liveActivityStatus(ensure: Bool) async throws -> ScoopsLiveStatus {
        ScoopsLiveStatus(active: false, session: nil, channel: nil, content: nil)
    }
    #endif

    func transcribe(audio: Data, name: String, language: String, prompt: String?, timeout: TimeInterval) async throws -> String {
        // Im Demo-Modus gibt es keine Server-Erkennung: Text vom Gerät bleibt stehen.
        try? await Task.sleep(for: .milliseconds(600))
        throw APIError(status: 503, message: String(localized: "Im Demo-Modus nicht verfügbar."))
    }

    // MARK: Apps verbinden

    private var connectionData = PreviewData.connections
    private var pendingLinks: [String: (app: String, alias: String?, replaces: String?, created: Date)] = [:]

    func connections(fresh: Bool) async throws -> ConnectionsOverview {
        try? await Task.sleep(for: .milliseconds(fresh ? 500 : 150))
        var data = connectionData
        for i in data.apps.indices { data.apps[i].canAdd = data.apps[i].accounts.count < data.maxPerApp }
        return data
    }

    private func appIndex(ofAccount id: String) -> (Int, Int)? {
        for (a, app) in connectionData.apps.enumerated() {
            if let i = app.accounts.firstIndex(where: { $0.id == id }) { return (a, i) }
        }
        return nil
    }

    func linkConnection(app: String, alias: String?) async throws -> ConnectionLink {
        guard let a = try mockAppIndex(app) else { throw APIError(status: 404, message: demoText("Unbekannte App.", en: "Unknown app.")) }
        if let cat = PreviewData.catalogApps.first(where: { $0.slug == app }), cat.authKind == .unavailable {
            throw APIError(status: 422, message: Self.noReadySignIn(cat.name))
        }
        let clean = alias?.trimmingCharacters(in: .whitespaces)
        if let clean, !clean.isEmpty, connectionData.apps[a].accounts.contains(where: { $0.alias == clean }) {
            throw APIError(status: 409, message: demoText("Bei \(connectionData.apps[a].name) gibt es schon ein Konto „\(clean)“.",
                                                           en: "\(connectionData.apps[a].name) already has an account named “\(clean)”."))
        }
        guard connectionData.apps[a].accounts.count < connectionData.maxPerApp else {
            throw APIError(status: 409, message: demoText("Höchstens \(connectionData.maxPerApp) Konten pro App.",
                                                           en: "Up to \(connectionData.maxPerApp) accounts per app."))
        }
        let id = nextID("ca")
        connectionData.apps[a].accounts.append(ConnectedAccount(id: id, app: app, alias: clean, email: nil, status: "initializing",
                                                                createdAt: Date()))
        pendingLinks[id] = (app, clean, nil, Date())
        return ConnectionLink(url: "https://example.com/composio-demo/\(app)", accountId: id)
    }

    func finishOAuth(callbackURL: String) async throws -> ConnectedAccount {
        guard let a = try mockAppIndex("notion") else { throw APIError(status: 404, message: demoText("Unbekannte App.", en: "Unknown app.")) }
        let acc = ConnectedAccount(id: "notion-mcp", app: "notion", alias: demoText("Notion direkt", en: "Notion direct"),
                                   email: demoText("Demo-Workspace", en: "Demo Workspace"),
                                   status: "active", createdAt: Date())
        connectionData.apps[a].accounts.removeAll { $0.id == acc.id }
        connectionData.apps[a].accounts.append(acc)
        return acc
    }

    func connectedAccount(id: String) async throws -> ConnectedAccount {
        guard let (a, i) = appIndex(ofAccount: id) else { throw APIError(status: 404, message: demoText("Konto nicht gefunden.", en: "Account not found.")) }
        // Demo: nach 6 s gilt die Anmeldung als erfolgreich
        if let p = pendingLinks[id], Date().timeIntervalSince(p.created) > 6 {
            connectionData.apps[a].accounts[i].status = "active"
            connectionData.apps[a].accounts[i].email = "arman.demo@example.com"
            if let old = p.replaces { connectionData.apps[a].accounts.removeAll { $0.id == old } }
            pendingLinks[id] = nil
        }
        guard let (a2, i2) = appIndex(ofAccount: id) else { throw APIError(status: 404, message: demoText("Konto nicht gefunden.", en: "Account not found.")) }
        return connectionData.apps[a2].accounts[i2]
    }

    func renameConnectedAccount(id: String, alias: String) async throws -> ConnectedAccount {
        guard let (a, i) = appIndex(ofAccount: id) else { throw APIError(status: 404, message: demoText("Konto nicht gefunden.", en: "Account not found.")) }
        if connectionData.apps[a].accounts.contains(where: { $0.alias == alias && $0.id != id }) {
            throw APIError(status: 409, message: demoText("Diesen Namen gibt es bei \(connectionData.apps[a].name) schon.",
                                                           en: "\(connectionData.apps[a].name) already has an account with that name."))
        }
        connectionData.apps[a].accounts[i].alias = alias
        return connectionData.apps[a].accounts[i]
    }

    func reconnectAccount(id: String) async throws -> ConnectionLink {
        guard let (a, i) = appIndex(ofAccount: id) else { throw APIError(status: 404, message: demoText("Konto nicht gefunden.", en: "Account not found.")) }
        let old = connectionData.apps[a].accounts[i]
        let newID = nextID("ca")
        connectionData.apps[a].accounts.append(ConnectedAccount(id: newID, app: old.app, alias: old.alias, email: old.email,
                                                                status: "initializing", createdAt: Date()))
        pendingLinks[newID] = (connectionData.apps[a].slug, old.alias, old.id, Date())
        return ConnectionLink(url: "https://example.com/composio-demo/\(connectionData.apps[a].slug)", accountId: newID)
    }

    func deleteConnectedAccount(id: String) async throws {
        for a in connectionData.apps.indices { connectionData.apps[a].accounts.removeAll { $0.id == id } }
        pendingLinks[id] = nil
    }

    // MARK: Eigene MCP-Server (v1.35, Demo)

    private var mcpData = PreviewData.customMCP

    func mcpServers() async throws -> MCPServerList {
        try? await Task.sleep(for: .milliseconds(200))
        return MCPServerList(servers: mcpData)
    }

    func probeMCP(url: String) async throws -> MCPProbe {
        try? await Task.sleep(for: .milliseconds(400))
        guard let u = URL(string: url), u.host() != nil else { throw APIError(status: 400, message: demoText("Bitte eine vollständige Adresse eingeben.", en: "Please enter a complete address.")) }
        if u.host()?.contains("qonto") == true || u.host()?.contains("mercury") == true {
            return MCPProbe(auth: "oauth", detail: demoText("Anmeldung über den Anbieter", en: "Sign in with the provider"),
                            name: demoText("Qonto MCP", en: "Mercury MCP"))
        }
        if u.path.contains("token") || u.host()?.contains("kasse") == true || u.host()?.contains("ledger") == true {
            return MCPProbe(auth: "token", detail: demoText("Token nötig", en: "Token required"), name: nil)
        }
        return MCPProbe(auth: "none", detail: demoText("Keine Anmeldung nötig", en: "No sign-in needed"), name: nil)
    }

    func addMCP(_ request: MCPAddRequest) async throws -> MCPAddResult {
        try? await Task.sleep(for: .milliseconds(600))
        let name = request.name ?? (request.kind == "stdio" ? demoText("Lokal", en: "Local") : URL(string: request.url ?? "")?.host() ?? "MCP")
        var id = "mcp_" + name.lowercased().filter { $0.isLetter || $0.isNumber }
        while mcpData.contains(where: { $0.id == id }) { id += "_2" }
        let auth = request.kind == "stdio" ? "none" : (request.auth == "auto" ? "none" : (request.auth ?? "none"))
        // Demo: OAuth gilt sofort als angemeldet (kein Browser)
        let server = CustomMCPServer(id: id, name: name, kind: request.kind, auth: auth, status: "ok", tools: 6, writeTools: 2,
                                     url: request.url, command: request.command.map { ([$0] + (request.args ?? [])).joined(separator: " ") },
                                     header: request.header, envKeys: request.env?.map(\.key))
        mcpData.append(server)
        return MCPAddResult(server: server, oauth: nil, test: MCPTestResult(ok: true, tools: 6, error: nil), error: nil)
    }

    func updateMCP(id: String, name: String?, token: String?, header: String?) async throws -> MCPServerList {
        guard let i = mcpData.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Diesen MCP-Server gibt es nicht.", en: "This MCP server doesn’t exist.")) }
        if let name, !name.isEmpty { mcpData[i].name = name }
        if let token, !token.isEmpty { mcpData[i].auth = "token"; mcpData[i].status = "ok"; mcpData[i].error = nil; mcpData[i].tools = 9 }
        return MCPServerList(servers: mcpData)
    }

    func deleteMCP(id: String) async throws -> MCPServerList {
        mcpData.removeAll { $0.id == id }
        return MCPServerList(servers: mcpData)
    }

    func loginMCP(id: String) async throws -> MCPLoginLink {
        guard let i = mcpData.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Diesen MCP-Server gibt es nicht.", en: "This MCP server doesn’t exist.")) }
        mcpData[i].status = "ok"
        return MCPLoginLink(url: "https://example.com/authorize", serverId: id, callbackScheme: "aisscoops", loopbackPort: nil, loopbackPath: nil)
    }

    func testMCP(id: String) async throws -> MCPTestResult {
        try? await Task.sleep(for: .milliseconds(500))
        guard let s = mcpData.first(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Diesen MCP-Server gibt es nicht.", en: "This MCP server doesn’t exist.")) }
        return s.status == "ok" ? MCPTestResult(ok: true, tools: s.tools, error: nil) : MCPTestResult(ok: false, tools: 0, error: s.error)
    }

    // MARK: Apps verbinden: Katalog (v1.16)

    /// Index der App in den Demo-Konten; Apps aus dem Beispielkatalog werden bei Bedarf ergänzt.
    private func mockAppIndex(_ slug: String) throws -> Int? {
        if let a = connectionData.apps.firstIndex(where: { $0.slug == slug }) { return a }
        guard let cat = PreviewData.catalogApps.first(where: { $0.slug == slug }) else { return nil }
        connectionData.apps.append(ConnectableApp(slug: cat.slug, name: cat.name, detail: cat.detail, symbol: cat.symbol))
        return connectionData.apps.count - 1
    }

    private func mockCatalog() -> [CatalogApp] {
        var list = PreviewData.catalogApps
        for app in connectionData.apps where !list.contains(where: { $0.slug == app.slug }) { list.append(CatalogApp(app)) }
        return list.map { app in
            var a = app
            a.accounts = connectionData.apps.first { $0.slug == app.slug }?.accounts.filter { $0.status != "initializing" } ?? []
            a.connected = a.accounts.filter { $0.state == .active }.count
            a.canAdd = a.connected < connectionData.maxPerApp
            return a
        }
    }

    func connectionCatalog(category: String?, query: String?, offset: Int, limit: Int) async throws -> CatalogPage {
        try? await Task.sleep(for: .milliseconds(offset == 0 ? 250 : 400))
        let all = mockCatalog()
        var list: [CatalogApp]
        switch category ?? "" {
        case "", CatalogCategory.popular: list = (category ?? "").isEmpty ? all : all.filter(\.popular)
        case CatalogCategory.connected: list = all.filter(\.isConnected)
        case let c: list = all.filter { $0.categories.contains(c) }
        }
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            list = list.filter { $0.name.localizedStandardContains(q) || $0.slug.localizedStandardContains(q)
                || ($0.detail ?? "").localizedStandardContains(q) }
                .sorted { ($0.name.lowercased().hasPrefix(q.lowercased()) ? 0 : 1) < ($1.name.lowercased().hasPrefix(q.lowercased()) ? 0 : 1) }
        }
        let page = Array(list.dropFirst(offset).prefix(limit))
        return CatalogPage(items: page, total: list.count, nextOffset: offset + limit < list.count ? offset + limit : nil,
                           connectedApps: all.filter { $0.connected > 0 }.count, maxPerApp: connectionData.maxPerApp)
    }

    func connectionCategories() async throws -> [CatalogCategory] {
        let all = mockCatalog()
        var out = [CatalogCategory(id: CatalogCategory.popular, name: demoText("Beliebt", en: "Popular"), count: all.filter(\.popular).count),
                   CatalogCategory(id: CatalogCategory.connected, name: demoText("Verbunden", en: "Connected"),
                                   count: all.filter(\.isConnected).count)]
        for (id, name) in [("productivity", demoText("Produktivität", en: "Productivity")),
                           ("communication", demoText("Kommunikation", en: "Communication")), ("design", "Design"),
                           ("development", demoText("Entwicklung", en: "Development")), ("data", demoText("Daten", en: "Data")),
                           ("finance", demoText("Finanzen", en: "Finance")), ("marketing", "Marketing"),
                           ("sales", demoText("Vertrieb & CRM", en: "Sales & CRM")), ("ai", demoText("KI", en: "AI")),
                           ("real-estate", "Real estate")] {
            let n = all.filter { $0.categories.contains(id) }.count
            if n > 0 { out.append(CatalogCategory(id: id, name: name, count: n)) }
        }
        return out
    }

    func connectionAuth(app: String) async throws -> AppAuthInfo {
        try? await Task.sleep(for: .milliseconds(200))
        guard let cat = mockCatalog().first(where: { $0.slug == app }) else { throw APIError(status: 404, message: demoText("Diese App gibt es bei Composio nicht.", en: "Composio doesn’t have this app.")) }
        switch cat.authKind {
        case .fields: return PreviewData.authInfo(for: cat)
        case .unavailable:
            return AppAuthInfo(slug: cat.slug, name: cat.name, auth: "unavailable",
                               message: Self.noReadySignIn(cat.name))
        case .none:
            return AppAuthInfo(slug: cat.slug, name: cat.name, auth: "none",
                               message: demoText("\(cat.name) braucht keine Anmeldung. Die Scoops können die App direkt nutzen.",
                                                 en: "\(cat.name) doesn’t need a sign-in. Your Scoops can use the app right away."))
        case .oauth: return AppAuthInfo(slug: cat.slug, name: cat.name, auth: "oauth")
        }
    }

    /// Wie der Server, wenn Composio für eine App keine fertige Anmeldung hat
    private static func noReadySignIn(_ name: String) -> String {
        demoText("Für \(name) bietet Composio keine fertige Anmeldung an. Dafür müsste zuerst "
                 + "im Composio-Konto eine eigene Anmeldung (Auth-Config) für diese App hinterlegt werden.",
                 en: "Composio doesn't offer a ready-made sign-in for \(name). To connect it, a custom sign-in (auth config) for "
                 + "this app has to be set up in the Composio account first.")
    }

    /// Demo: Schlüssel mit „falsch“ werden abgelehnt, sonst ist das Konto sofort aktiv.
    func connectWithFields(app: String, alias: String?, fields: [AuthFieldValue]) async throws -> ConnectResult {
        try? await Task.sleep(for: .milliseconds(700))
        let info = try await connectionAuth(app: app)
        guard info.auth == "fields" else { throw APIError(status: 422, message: demoText("\(info.name) verbindest du über die Anmeldung im Browser.",
                                                                                  en: "Connect \(info.name) by signing in through your browser.")) }
        let values = Dictionary(fields.map { ($0.name, $0.value.trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { a, _ in a })
        for f in info.fields where f.required && (values[f.name] ?? "").isEmpty {
            throw APIError(status: 409, message: demoText("Bitte „\(f.label)“ ausfüllen.", en: "Please fill in “\(f.label).”"))
        }
        if values.values.contains(where: { $0.localizedCaseInsensitiveContains(AppLanguage.isGerman ? "falsch" : "wrong") }) {
            throw APIError(status: 409, message: demoText("\(info.name) hat die Angaben abgelehnt. Bitte prüfe sie und versuche es noch einmal.",
                                                           en: "\(info.name) rejected these details. Please check them and try again."))
        }
        guard let a = try mockAppIndex(app) else { throw APIError(status: 404, message: demoText("Unbekannte App.", en: "Unknown app.")) }
        let clean = alias?.trimmingCharacters(in: .whitespaces)
        if let clean, !clean.isEmpty, connectionData.apps[a].accounts.contains(where: { $0.alias?.lowercased() == clean.lowercased() }) {
            throw APIError(status: 409, message: demoText("Diesen Namen gibt es für diese App schon", en: "This app already has an account with that name"))
        }
        guard connectionData.apps[a].accounts.count < connectionData.maxPerApp else {
            throw APIError(status: 409, message: demoText("Höchstens \(connectionData.maxPerApp) Konten pro App",
                                                           en: "Up to \(connectionData.maxPerApp) accounts per app"))
        }
        let id = nextID("ca")
        connectionData.apps[a].accounts.append(ConnectedAccount(id: id, app: app, alias: clean?.isEmpty == false ? clean : nil,
                                                                email: values["subdomain"].map { "\($0).\(app).com" },
                                                                status: "active", createdAt: Date()))
        return ConnectResult(accountId: id, status: "active")
    }

    /// Demo: Logo direkt von Composio (SVG). Der Mac zeichnet es selbst; auf iOS bleibt sonst das Ersatzsymbol.
    func connectionLogo(app: String) async throws -> Data {
        guard let url = URL(string: "https://logos.composio.dev/api/\(app)") else { throw APIError(status: 404, message: demoText("Kein Logo.", en: "No logo.")) }
        let (data, _) = try await URLSession.shared.data(from: url)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let img = NSImage(data: data), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        #endif
        return data
    }

    // MARK: Bereiche

    private var sectionList: [SidebarSection] = PreviewData.sections

    func sections() async throws -> [SidebarSection] { sectionList }

    func saveSections(_ sections: [SidebarSection]) async throws -> [SidebarSection] {
        sectionList = sections
        emit(.sectionsUpdated(sectionList))
        return sectionList
    }

    func renameSection(from: String, to: String) async throws {
        if let i = sectionList.firstIndex(where: { $0.name == from }) { sectionList[i].name = to }
        for i in bots.indices where bots[i].section == from { bots[i].section = to }
        for i in groupList.indices where groupList[i].section == from { groupList[i].section = to }
        emit(.sectionsUpdated(sectionList))
    }

    func deleteSection(name: String) async throws {
        sectionList.removeAll { $0.name == name }
        for i in bots.indices where bots[i].section == name { bots[i].section = nil }
        for i in groupList.indices where groupList[i].section == name { groupList[i].section = nil }
        emit(.sectionsUpdated(sectionList))
    }

    // MARK: Haupt-Scoop, Fähigkeiten, Tresor

    private var initiativeSettings = PreviewData.initiative
    private var skillList: [Skill] = PreviewData.skills
    private var vaultList: [VaultEntry] = PreviewData.vault

    func initiative() async throws -> InitiativeSettings {
        var s = initiativeSettings
        s.primaryBotId = bots.first(where: \.primary)?.id
        return s
    }

    func updateInitiative(_ patch: InitiativePatch) async throws -> InitiativeSettings {
        if let v = patch.enabled { initiativeSettings.enabled = v }
        if let v = patch.times { initiativeSettings.times = Array(v.prefix(8)) }
        if let v = patch.quietStart { initiativeSettings.quietStart = v }
        if let v = patch.quietEnd { initiativeSettings.quietEnd = v }
        return try await initiative()
    }

    func runInitiative() async throws {
        guard let primary = bots.first(where: \.primary) else { return }
        Task {
            guard await pause(2.5) else { return }
            let m = Message(id: nextID("m"), botId: primary.id, role: .bot,
                            text: demoText("Kurz geschaut: Zwei neue Mails sind wichtig, und um 16 Uhr ist der Zahnarzt. Sonst alles ruhig.",
                                            en: "Quick check: two new emails look important, and the dentist is at 4 PM. Otherwise, all quiet."),
                            createdAt: Date())
            messages[primary.id, default: []].append(m)
            emit(.messageCreated(m))
        }
    }

    func skills(botID: String?) async throws -> [Skill] {
        guard let botID else { return skillList }
        return skillList.filter { $0.botId == nil || $0.botId == botID }
    }

    func updateSkill(id: String, patch: SkillPatch) async throws -> Skill {
        guard let idx = skillList.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Fähigkeit nicht gefunden.", en: "Skill not found.")) }
        if let v = patch.name { skillList[idx].name = v }
        if let v = patch.description { skillList[idx].description = v }
        if let v = patch.steps { skillList[idx].steps = v }
        skillList[idx].updatedAt = Date()
        return skillList[idx]
    }

    func deleteSkill(id: String) async throws { skillList.removeAll { $0.id == id } }

    func vault() async throws -> [VaultEntry] { vaultList }

    func createVaultEntry(_ draft: VaultDraft) async throws -> VaultEntry {
        let e = VaultEntry(id: nextID("v"), title: draft.title, url: draft.url, domain: URL(string: draft.url)?.host(),
                           username: draft.username, note: draft.note, hasPassword: !(draft.password ?? "").isEmpty,
                           createdAt: Date(), updatedAt: Date())
        vaultList.append(e)
        return e
    }

    func updateVaultEntry(id: String, draft: VaultDraft) async throws -> VaultEntry {
        guard let idx = vaultList.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Eintrag nicht gefunden.", en: "Entry not found.")) }
        vaultList[idx].title = draft.title
        vaultList[idx].url = draft.url
        vaultList[idx].domain = URL(string: draft.url)?.host()
        vaultList[idx].username = draft.username
        vaultList[idx].note = draft.note
        if let p = draft.password, !p.isEmpty { vaultList[idx].hasPassword = true }
        vaultList[idx].updatedAt = Date()
        return vaultList[idx]
    }

    func deleteVaultEntry(id: String) async throws { vaultList.removeAll { $0.id == id } }

    // MARK: Bot-Rechner übernehmen

    func takeover(node: String) async throws -> ComputerState {
        if node != ComputerNode.builtinID {
            guard let i = nodeList.firstIndex(where: { $0.id == node }) else { throw APIError(status: 404, message: demoText("Rechner nicht gefunden", en: "Computer not found")) }
            guard nodeList[i].online else {
                throw APIError(status: 503, message: demoText("„\(nodeList[i].name)“ ist offline.", en: "“\(nodeList[i].name)” is offline."))
            }
            nodeList[i].state = "user"; nodeList[i].botId = nil; nodeList[i].botName = nil
            emit(.computerUpdated(nodeList[i].computerState))
            return nodeList[i].computerState
        }
        computerState = ComputerState(state: "user", botId: nil, width: 1024, height: 768, nodeId: "vm")
        emit(.computerUpdated(computerState))
        return computerState
    }

    func release(node: String) async throws {
        if let i = nodeList.firstIndex(where: { $0.id == node }), node != ComputerNode.builtinID {
            nodeList[i].state = "awake"
            emit(.computerUpdated(nodeList[i].computerState))
            return
        }
        computerState = ComputerState(state: "awake", botId: nil, width: 1024, height: 768, nodeId: "vm")
        emit(.computerUpdated(computerState))
    }

    // MARK: Rechner (v1.11)

    func nodes() async throws -> [ComputerNode] {
        var list = nodeList
        list[0].state = computerState.state; list[0].botId = computerState.botId
        list[0].botName = computerState.botId.flatMap { id in bots.first { $0.id == id }?.name }
        return list
    }

    /// Demo-Kopplung: Nach ein paar Sekunden meldet sich ein neuer Mac (wie Scoops Connect nach Codeeingabe).
    func pairNode() async throws -> NodePairing {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let raw = String((0..<8).map { _ in alphabet.randomElement()! })
        let pairing = NodePairing(code: "\(raw.prefix(4))-\(raw.suffix(4))", expiresAt: Date().addingTimeInterval(600),
                                  ttlSeconds: 600, serverUrl: "https://demo.aisscoops.test")
        if ProcessInfo.processInfo.arguments.contains("-pairdemo") {
            pairingTask?.cancel()
            pairingTask = Task {
                guard await pause(6) else { return }
                let node = ComputerNode(id: nextID("n"), name: demoText("iMac Wohnzimmer", en: "Living Room iMac"), mode: "direct", online: true,
                                        os: "macOS 27.0", appVersion: "1.0 (1)", lastSeen: Date(),
                                        screen: .init(width: 2048, height: 1152), createdAt: Date())
                nodeList.append(node)
                emit(.nodeUpdated(node))
            }
        }
        return pairing
    }

    func renameNode(id: String, name: String) async throws -> ComputerNode {
        guard let i = nodeList.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, message: demoText("Rechner nicht gefunden", en: "Computer not found")) }
        nodeList[i].name = name
        emit(.nodeUpdated(nodeList[i]))
        return nodeList[i]
    }

    func deleteNode(id: String) async throws {
        guard id != ComputerNode.builtinID else { throw APIError(status: 400, message: demoText("Der Bot-Rechner kann nicht entfernt werden", en: "The bot computer can’t be removed")) }
        nodeList.removeAll { $0.id == id }
        for i in bots.indices where bots[i].computerNode == id {
            bots[i].computerNode = ComputerNode.builtinID
            var b = bots[i]; b.lastMessage = messages[b.id]?.last
            emit(.botUpdated(b))
        }
        emit(.nodeDeleted(id: id))
    }

    // MARK: Apple-Dienste (v1.17)

    private var appleData = PreviewData.apple

    func appleStatus() async throws -> AppleStatus {
        try? await Task.sleep(for: .milliseconds(200))
        refreshAppleDevice()
        return appleData
    }

    /// v1.18 im Demo-Modus: Ist das Apple-Gerät dieses iPhone, gelten seine echten iOS-Freigaben (wie nach einem hello).
    private func refreshAppleDevice() {
        guard var dev = appleData.device else { return }
        if AppleDeviceAgent.isSupported, dev.id == AppleDeviceAgent.shared.deviceID,
           !ProcessInfo.processInfo.arguments.contains("-appleready") {
            AppleDeviceAgent.shared.refreshPermissions()
            for (k, v) in AppleDeviceAgent.shared.permissions { dev.permissions[k] = v == "unknown" ? "not_determined" : v }
            appleData.device = dev
            appleData.devices = [dev]
        }
        let enabled = Dictionary(uniqueKeysWithValues: (appleData.deviceServices ?? []).map { ($0.id, $0.enabled) })
        appleData.deviceServices = PreviewData.deviceServices(dev, enabled: enabled)
    }

    /// Wie der Server: Ein Dienst ist erst „bereit“, wenn er eingeschaltet ist und der Mac die Freigabe hat.
    func updateApple(_ patch: ApplePatch) async throws -> AppleStatus {
        try? await Task.sleep(for: .milliseconds(250))
        if let node = patch.node {
            guard node.isEmpty || appleData.nodes.contains(where: { $0.id == node }) else {
                throw APIError(status: 404, message: demoText("Rechner nicht gefunden", en: "Computer not found"))
            }
            let target = appleData.nodes.first { $0.id == (node.isEmpty ? "n_air" : node) }
            appleData.nodeChoice = node.isEmpty ? "auto" : node
            appleData.nodeSource = node.isEmpty ? "local" : "config"
            appleData.nodeId = target?.id
            appleData.nodeName = target?.name
            appleData.nodeOnline = target?.online ?? false
        }
        if let device = patch.device {
            guard device.isEmpty || appleData.devices?.contains(where: { $0.id == device }) == true else {
                throw APIError(status: 404, message: demoText("Gerät nicht gefunden", en: "Device not found"))
            }
            appleData.deviceChoice = device.isEmpty ? "auto" : device
        }
        var enabled = Dictionary(uniqueKeysWithValues: (appleData.deviceServices ?? []).map { ($0.id, $0.enabled) })
        if let v = patch.home { enabled["home"] = v }
        if let v = patch.alarms { enabled["alarms"] = v }
        if let v = patch.location { enabled["location"] = v }
        appleData.deviceServices = PreviewData.deviceServices(appleData.device, enabled: enabled)
        refreshAppleDevice()
        let grants = appleData.nodes.first { $0.id == appleData.nodeId }?.apple ?? [:]
        for i in appleData.services.indices {
            let id = appleData.services[i].id
            switch id {
            case "reminders": if let v = patch.reminders { appleData.services[i].enabled = v }
            case "calendar": if let v = patch.calendar { appleData.services[i].enabled = v }
            default: if let v = patch.contacts { appleData.services[i].enabled = v }
            }
            var s = appleData.services[i]
            s.permission = grants[id] ?? "unknown"
            s.nodeId = appleData.nodeId
            if !appleData.nodeOnline {
                s.status = "offline"
                s.hint = demoText("„\(appleData.nodeName ?? "Mac")“ ist gerade nicht verbunden.",
                                  en: "“\(appleData.nodeName ?? "Mac")” isn’t connected right now.")
            }
            else if s.permission != "granted" {
                s.status = "needs_permission"
                s.hint = demoText("Auf dem Mac in AIS Scoops Server freigeben.", en: "Allow access in AIS Scoops Server on the Mac.")
            }
            else if !s.enabled { s.status = "off"; s.hint = nil }
            else { s.status = "ready"; s.hint = nil }
            s.available = s.status == "ready"
            appleData.services[i] = s
        }
        return appleData
    }

    func computerInput(_ input: ComputerInput, node: String) async throws {
        #if DEBUG
        print("[Demo] Eingabe: \(input.type) \(input.x ?? -1),\(input.y ?? -1) \(input.text ?? "")")
        #endif
    }

    // MARK: Ereignisse

    func connectEvents() {
        onSocketState?(.connecting)
        Task {
            guard await pause(0.2) else { return }
            onSocketState?(.connected)
        }
        scheduleDemoIncoming()
    }

    func disconnectEvents() {
        for t in runs.values { t.cancel() }
        runs = [:]
        onSocketState?(.disconnected)
    }

    func reconnectEvents() { onSocketState?(.connected) }
}

/// Erzeugt Beispielinhalte für Demo-Dateien (Text, Bild, PDF).
enum MockFiles {
    static func content(for file: LibraryFile) -> Data {
        if file.id == "f_lio_post" { return partyImageData() }
        if file.isImage { return imageData() }
        if (file.mime ?? "") == "application/pdf" { return pdfData(title: file.name) }
        let text = demoText("""
        # Wettbewerbsanalyse KW 47

        **Kurzfassung:** Drei der fünf Wettbewerber haben diese Woche neue Funktionen gezeigt. Am wichtigsten ist der
        Preissturz bei *Nova Assist* – Details unten. Quelle: [Herstellerseite](https://example.com).

        ## Überblick

        | Anbieter | Neuheit | Preis/Monat | Einschätzung |
        |---|---|---:|:---:|
        | Nova Assist | Sprachmodus | 9 € | hoch |
        | Helio | Kalender-Sync | 19 € | mittel |
        | Taskly | Teams | 29 € | gering |

        ## Empfehlungen

        1. Preise für das Einsteiger-Paket prüfen
        2. Sprachmodus stärker bewerben
           - Demo-Video bis Freitag
           - Landingpage anpassen

        ### Offene Punkte

        - [x] Preise erfasst
        - [ ] Screenshots der neuen Funktionen
        - [ ] Rückmeldung von Arman

        ---

        > Hinweis: Zahlen stammen von den öffentlichen Preisseiten, Stand 16.11.

        ```
        quelle: nova-assist.example/preise
        ```
        """, en: """
        # Competitor Analysis, Week 47

        **Summary:** Three of the five competitors showed new features this week. The biggest news is the
        price cut at *Nova Assist*; details below. Source: [vendor page](https://example.com).

        ## Overview

        | Vendor | New Feature | Price/Month | Impact |
        |---|---|---:|:---:|
        | Nova Assist | Voice mode | $9 | high |
        | Helio | Calendar sync | $19 | medium |
        | Taskly | Teams | $29 | low |

        ## Recommendations

        1. Review pricing for the starter plan
        2. Promote voice mode more
           - Demo video by Friday
           - Update the landing page

        ### Open Items

        - [x] Prices collected
        - [ ] Screenshots of the new features
        - [ ] Feedback from Arman

        ---

        > Note: Figures come from the public pricing pages, as of 11/16.

        ```
        source: nova-assist.example/pricing
        ```
        """)
        return Data(text.utf8)
    }

    private static func imageData() -> Data {
        let view = ZStack {
            LinearGradient(colors: [Color(hex: "#8B5CF6"), Color(hex: "#3D84F5")], startPoint: .topLeading, endPoint: .bottomTrailing)
            MascotView(mascot: Mascot(shape: "bun", color: "#FFFFFF", eyes: "happy", accessory: "none"),
                       size: 260, seed: "logo", animated: false)
        }
        .frame(width: 400, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Demo für „Bild erstellt“ (Server 1.39): Scoops feiern mit Konfetti, Querformat 3:2.
    private static func partyImageData() -> Data {
        let confetti: [(CGFloat, CGFloat, String)] = [(60, 50, "#FFD23F"), (140, 90, "#3D84F5"), (520, 60, "#43C62E"),
                                                       (470, 120, "#FFFFFF"), (90, 300, "#FFFFFF"), (560, 320, "#FFD23F"),
                                                       (300, 40, "#F72A7A"), (250, 360, "#3D84F5"), (400, 350, "#43C62E")]
        let view = ZStack {
            LinearGradient(colors: [Color(hex: "#FF8A3D"), Color(hex: "#F72A7A")], startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(Array(confetti.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: c.2)).frame(width: 16, height: 9)
                    .rotationEffect(.degrees(Double(c.0).truncatingRemainder(dividingBy: 90)))
                    .position(x: c.0, y: c.1)
            }
            HStack(alignment: .bottom, spacing: 18) {
                MascotView(mascot: Mascot(shape: "pill", color: "#8A2EDB", eyes: "happy", accessory: "none"), size: 120,
                           seed: "party1", animated: false)
                MascotView(mascot: Mascot(shape: "egg", color: "#FBBA10", eyes: "happy", accessory: "beret"), size: 160,
                           seed: "party2", animated: false)
                MascotView(mascot: Mascot(shape: "cloud", color: "#1270E8", eyes: "happy", accessory: "none"), size: 120,
                           seed: "party3", animated: false)
            }
            .offset(y: 40)
        }
        .frame(width: 600, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return imageData() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private static func pdfData(title: String) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 742, width: 595, height: 100))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for i in 0..<12 { ctx.fill(CGRect(x: 60, y: 680 - i * 40, width: 475 - (i % 3) * 80, height: 12)) }
        ctx.endPDFPage()
        ctx.closePDF()
        _ = title
        return out as Data
    }
}

/// Startargumente nur für den Demo-Modus (Tests und Screenshots).
private enum DemoArgs {
    /// `-mocklatency <ms>`: Verzögerung beim Laden der Nachrichten
    static let latency: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-mocklatency"), args.indices.contains(i + 1) else { return 0 }
        return max(0, Int(args[i + 1]) ?? 0)
    }()

    /// `-unread <chat-id> <anzahl>` (mehrfach möglich): Ungelesen-Zähler eines Chats vorgeben
    static let unread: [String: Int] = {
        let args = ProcessInfo.processInfo.arguments
        var map: [String: Int] = [:]
        for (i, a) in args.enumerated() where a == "-unread" && args.indices.contains(i + 2) {
            if let n = Int(args[i + 2]) { map[args[i + 1]] = max(0, n) }
        }
        return map
    }()
}
