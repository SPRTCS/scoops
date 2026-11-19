import Foundation

/// Rechner-Zugriff zum Senden (ohne die Anzeige-Texte des Servers).
nonisolated struct ComputerAccessPatch: Encodable, Sendable {
    var mode: String
    var scope: String
    var folders: [String]
}

/// Neuer Bot (POST /api/bots).
nonisolated struct BotDraft: Encodable, Sendable {
    var name: String
    var label: String?
    var mascot: Mascot
    var character: String?
    var model: String?
}

/// Teiländerung eines Bots (PATCH /api/bots/{id}); nil-Felder werden nicht gesendet.
/// `section`: `nil` = nicht ändern, `.some(nil)` = Gruppe leeren (sendet `"section": null`).
nonisolated struct BotPatch: Encodable, Sendable {
    var name: String?
    var label: String?
    var mascot: Mascot?
    var character: String?
    var model: String?
    var pinned: Bool?
    var section: String??
    /// Stimme (v1.1): `nil` = nicht ändern, `.some(nil)` = zurücksetzen.
    var voice: String??
    /// Haupt-Scoop (v1.4)
    var primary: Bool?
    /// Geteilte Scoops: Werkzeuge für Läufe von Gästen und Tageslimit pro Gast in $ (nur Admin)
    var guestTools: GuestTools?
    var guestBudget: Double?
    /// Rechner des Scoops (v1.11), `"vm"` = Bot-Rechner
    var computerNode: String?
    /// v1.21: „Darf andere Scoops prüfen“ (nur Admin)
    var canReview: Bool?
    /// v1.29: Rechner-Zugriff (Modus, Standard-Bereich, Projektordner; nur Admin)
    var computerAccess: ScoopAccess?

    private enum CodingKeys: String, CodingKey {
        case name, label, mascot, character, model, pinned, section, voice, primary, computerNode, guestTools, guestBudget
        case canReview, computerAccess
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(mascot, forKey: .mascot)
        try c.encodeIfPresent(character, forKey: .character)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encodeIfPresent(primary, forKey: .primary)
        try c.encodeIfPresent(canReview, forKey: .canReview)
        if let a = computerAccess {
            try c.encode(ComputerAccessPatch(mode: a.mode, scope: a.scope, folders: a.folders), forKey: .computerAccess)
        }
        try c.encodeIfPresent(computerNode, forKey: .computerNode)
        try c.encodeIfPresent(guestTools, forKey: .guestTools)
        try c.encodeIfPresent(guestBudget, forKey: .guestBudget)
        if let section {
            if let value = section { try c.encode(value, forKey: .section) } else { try c.encodeNil(forKey: .section) }
        }
        if let voice {
            if let value = voice { try c.encode(value, forKey: .voice) } else { try c.encodeNil(forKey: .voice) }
        }
    }
}

/// Änderung einer Gruppe (PATCH /api/groups/{id}).
nonisolated struct GroupPatch: Encodable, Sendable {
    var name: String?
    var memberIds: [String]?
    var pinned: Bool?
    var section: String??

    private enum CodingKeys: String, CodingKey { case name, memberIds, pinned, section }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(memberIds, forKey: .memberIds)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        if let section {
            if let value = section { try c.encode(value, forKey: .section) } else { try c.encodeNil(forKey: .section) }
        }
    }
}

/// Änderung der Initiative (PATCH /api/settings/initiative); nil-Felder werden nicht gesendet.
nonisolated struct InitiativePatch: Encodable, Sendable {
    var enabled: Bool?
    var times: [String]?
    var quietStart: String?
    var quietEnd: String?
}

/// Änderung einer Fähigkeit (PATCH /api/skills/{id}).
nonisolated struct SkillPatch: Encodable, Sendable {
    var name: String?
    var description: String?
    var steps: String?
}

/// Tresor-Eintrag anlegen/ändern. `password` nur senden, wenn es gesetzt/geändert werden soll.
nonisolated struct VaultDraft: Encodable, Sendable {
    var title: String
    var url: String
    var username: String?
    var password: String?
    var note: String?
}

/// Nachricht senden (Einzel- und Gruppenchat).
nonisolated struct OutgoingMessage: Encodable, Sendable {
    var text: String
    var voice: Bool?
    var fileIds: [String]?
    /// v1.15: ID der zitierten Nachricht (wird als `reply_to` gesendet; ältere Server ignorieren es)
    var replyTo: String? = nil
    /// v1.22: Termin/Modell für „/aufgabe …“ (wird als `task` gesendet)
    var task: TaskOptions? = nil
}

/// Gerät für Push registrieren (POST /api/devices).
nonisolated struct DeviceRegistration: Encodable, Sendable {
    var apnsToken: String
    /// ios | macos | ios-widgets
    var platform: String
    var name: String
}

enum SocketState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

/// Gemeinsame Schnittstelle für echten Server und Demo-Modus.
protocol BotService: AnyObject {
    var onEvent: ((ServerEvent) -> Void)? { get set }
    var onSocketState: ((SocketState) -> Void)? { get set }

    func health() async throws -> Health
    func bots() async throws -> [Bot]
    func createBot(_ draft: BotDraft) async throws -> Bot
    func updateBot(id: String, patch: BotPatch) async throws -> Bot
    func deleteBot(id: String) async throws
    // Chats: chatID = Bot-ID (b_…) oder Gruppen-ID (g_…)
    func messages(chatID: String, before: String?, limit: Int) async throws -> [Message]
    func send(chatID: String, message: OutgoingMessage) async throws -> Message
    func stop(chatID: String) async throws
    /// v1.19: eine Hintergrund-Aufgabe anhalten (`POST /api/tasks/{id}/stop`)
    func stopTask(id: String) async throws
    func markRead(chatID: String) async throws
    func reset(chatID: String) async throws
    func memories(botID: String) async throws -> [Memory]
    func deleteMemory(id: String) async throws
    func routines(botID: String) async throws -> [Routine]
    func setRoutine(id: String, enabled: Bool) async throws -> Routine
    func deleteRoutine(id: String) async throws
    func runRoutine(id: String) async throws
    func decide(approvalID: String, approve: Bool, note: String?) async throws -> Message
    /// Mail-Karte (v1.9): senden mit optionalen Änderungen bzw. verwerfen.
    func decideMail(approvalID: String, approve: Bool, edits: MailEdits?) async throws -> Message
    /// Tresor-Formular (v1.10): Login speichern (`edits` mit Passwort) bzw. ablehnen (`edits == nil`).
    func decideVault(approvalID: String, approve: Bool, edits: VaultEdits?) async throws -> Message
    /// v1.20: freigeben und künftig automatisch erlauben (`approve_always`); `mailEdits` nur bei der Mail-Karte.
    func decideAlways(approvalID: String, mailEdits: MailEdits?) async throws -> Message
    /// v1.20: dauerhafte Freigaben eines Scoops (nur Admin)
    func standingApprovals(botID: String) async throws -> [StandingApproval]
    func deleteStandingApproval(botID: String, id: String) async throws
    /// v1.20: Modell einer Routine (`nil` = wie der Scoop)
    func setRoutineModel(id: String, model: String?) async throws -> Routine
    /// v1.21: Verbesserung für einen anderen Scoop freigeben (`after` = bearbeiteter neuer Text) bzw. ablehnen
    func decideScoopUpdate(approvalID: String, approve: Bool, after: String?) async throws -> Message
    /// Reaktion setzen/ersetzen (`emoji`) bzw. entfernen (`nil`) (v1.9).
    func react(messageID: String, emoji: String?) async throws -> Message
    /// Zustand eines Rechners (`node`: Rechner-ID, Standard Bot-Rechner `vm`)
    func computer(node: String) async throws -> ComputerState
    func usage() async throws -> Usage
    /// Server 1.34: Modellkatalog (docs/modelle.md); ältere Server antworten mit 404
    func models() async throws -> ModelCatalog
    /// v1.31: Seite „Nutzung und Verbrauch“ (docs/nutzung.md)
    func usageDetails(range: String, source: String, refresh: Bool) async throws -> UsageDetails
    func usageLimits(refresh: Bool) async throws -> UsageLimits
    func registerDevice(_ registration: DeviceRegistration) async throws

    // Gruppen (v1.1)
    func groups() async throws -> [ChatGroup]
    func createGroup(name: String, memberIDs: [String]) async throws -> ChatGroup
    func updateGroup(id: String, patch: GroupPatch) async throws -> ChatGroup
    func deleteGroup(id: String) async throws

    // Bibliothek (v1.1)
    func files(chatID: String) async throws -> [LibraryFile]
    func uploadFile(chatID: String, name: String, mime: String, data: Data,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> LibraryFile
    func deleteFile(id: String) async throws
    /// Lädt eine Datei in eine temporäre Datei und gibt deren URL zurück.
    func downloadFile(_ file: LibraryFile) async throws -> URL
    /// URL mit `?token=` (z. B. für Bild-Vorschauen).
    func fileURL(id: String) -> URL?

    // Eigenes Scoop-Bild (v1.12): hochladen (quadratisches JPEG/PNG), zurück zum Maskottchen, Bilddaten laden
    func uploadAvatar(botID: String, data: Data) async throws -> Bot
    func deleteAvatar(botID: String) async throws -> Bot
    func avatarData(botID: String, version: Int) async throws -> Data

    // Genaue Spracherkennung auf dem Server (v1.2)
    func transcribe(audio: Data, name: String, language: String, prompt: String?, timeout: TimeInterval) async throws -> String

    // Live-Sprechmodus mit GPT-Live-1 (v1.13)
    func liveVoiceInfo() async throws -> LiveVoiceInfo
    /// Anfrage für den WebSocket `/api/voice/live?chat=<id>` (mit gültiger Anmeldung)
    func liveVoiceRequest(chatID: String) async throws -> URLRequest
    /// Kurze Stimmprobe als WAV
    func liveVoicePreview(voice: String) async throws -> Data

    // Rechner übernehmen (v1.1, `node` seit v1.11)
    func takeover(node: String) async throws -> ComputerState
    func release(node: String) async throws
    func computerInput(_ input: ComputerInput, node: String) async throws

    // Rechner (v1.11, Scoops Connect)
    func nodes() async throws -> [ComputerNode]
    func pairNode() async throws -> NodePairing
    func renameNode(id: String, name: String) async throws -> ComputerNode
    func deleteNode(id: String) async throws

    // Apple-Dienste über den Apple-Rechner (v1.17): Erinnerungen, Kalender, Kontakte
    func appleStatus() async throws -> AppleStatus
    func updateApple(_ patch: ApplePatch) async throws -> AppleStatus

    // Dieses iPhone als Apple-Gerät (v1.18): Home, Wecker, Standort
    /// Nachricht über den Live-Kanal (`device.hello`, `device.state`, `device.result`); `false` = nicht verbunden
    func sendDeviceMessage(_ text: String) -> Bool
    /// Anmelden per HTTP (Hintergrund); Antwort: offene Befehle
    func registerAppleDevice(_ hello: AppleDeviceHello) async throws -> [AppleDeviceCommand]
    func pollAppleDevice(deviceID: String) async throws -> [AppleDeviceCommand]
    func sendAppleResult(deviceID: String, commandID: String, result: JSONValue) async throws
    func sendAppleEvent(deviceID: String, event: JSONValue) async throws
    func removeAppleDevice(id: String) async throws -> AppleStatus

    // Apps verbinden (v1.8)
    func connections(fresh: Bool) async throws -> ConnectionsOverview
    func linkConnection(app: String, alias: String?) async throws -> ConnectionLink
    /// Rücksprung aus dem Browser (`aisscoops://oauth/…`) an den Server geben (Server 1.25, Notion direkt)
    func finishOAuth(callbackURL: String) async throws -> ConnectedAccount
    func connectedAccount(id: String) async throws -> ConnectedAccount
    func renameConnectedAccount(id: String, alias: String) async throws -> ConnectedAccount
    func reconnectAccount(id: String) async throws -> ConnectionLink
    func deleteConnectedAccount(id: String) async throws
    // Apps verbinden: ganzer Composio-Katalog (v1.16)
    func connectionCatalog(category: String?, query: String?, offset: Int, limit: Int) async throws -> CatalogPage
    func connectionCategories() async throws -> [CatalogCategory]
    func connectionAuth(app: String) async throws -> AppAuthInfo
    func connectWithFields(app: String, alias: String?, fields: [AuthFieldValue]) async throws -> ConnectResult
    func connectionLogo(app: String) async throws -> Data

    // Bereiche der Seitenleiste (v1.6)
    func sections() async throws -> [SidebarSection]
    func saveSections(_ sections: [SidebarSection]) async throws -> [SidebarSection]
    func renameSection(from: String, to: String) async throws
    func deleteSection(name: String) async throws

    // Arbeitsordner der Scoops auf dem Server-Mac (Server 1.27, nur Admin; Standard: ältere Server → 404)
    func workspace() async throws -> WorkspaceStatus
    // v1.30: KI-Abos (docs/abos.md)
    func abos() async throws -> AboStatus
    // Eigene MCP-Server (v1.35, docs/mcp.md; Standard in CustomMCPSection.swift: „Server aktualisieren“)
    func mcpServers() async throws -> MCPServerList
    func probeMCP(url: String) async throws -> MCPProbe
    func addMCP(_ request: MCPAddRequest) async throws -> MCPAddResult
    func updateMCP(id: String, name: String?, token: String?, header: String?) async throws -> MCPServerList
    func deleteMCP(id: String) async throws -> MCPServerList
    func loginMCP(id: String) async throws -> MCPLoginLink
    func testMCP(id: String) async throws -> MCPTestResult
    func decideSecrets(approvalID: String, approve: Bool, secrets: [KeyValue]) async throws -> Message
    func setAboMode(provider: String, mode: String) async throws -> AboStatus
    func startAboLogin(provider: String) async throws
    // v1.36: Computer Use von Codex an/aus (Standard in AboSettings.swift: ältere Server → wie abos())
    func setCodexComputerUse(_ enabled: Bool) async throws -> AboStatus
    func setWorkspace(path: String) async throws -> WorkspaceStatus
    func browseWorkspace(path: String) async throws -> WorkspaceListing
    func createWorkspaceFolder(parent: String, name: String) async throws -> WorkspaceListing

    // Haupt-Scoop, Fähigkeiten, Tresor (v1.4)
    func initiative() async throws -> InitiativeSettings
    func updateInitiative(_ patch: InitiativePatch) async throws -> InitiativeSettings
    func runInitiative() async throws
    func skills(botID: String?) async throws -> [Skill]
    func updateSkill(id: String, patch: SkillPatch) async throws -> Skill
    func deleteSkill(id: String) async throws
    func vault() async throws -> [VaultEntry]
    func createVaultEntry(_ draft: VaultDraft) async throws -> VaultEntry
    func updateVaultEntry(id: String, draft: VaultDraft) async throws -> VaultEntry
    func deleteVaultEntry(id: String) async throws

    // Live-Aktivität per Push (v1.1)
    func registerLiveActivity(chatID: String, runID: String, pushToken: String) async throws
    #if os(iOS)
    /// Gemeinsame Scoops-Live-Aktivität: Stand abfragen (`GET /api/live-activity`) bzw. Sitzung sicherstellen
    /// (`POST /api/live-activity/ensure`).
    func liveActivityStatus(ensure: Bool) async throws -> ScoopsLiveStatus
    #endif
    /// URL des Bildschirmfotos inkl. `?token=` (nil im Demo-Modus).
    func screenImageURL(scale: Double, quality: Int, node: String) -> URL?

    // Geteilte Scoops (docs/sharing.md)
    /// Eigenen Server die Shares sofort neu aus Convex laden lassen (`POST /api/shares/refresh`)
    func refreshShares() async throws
    /// Gast-Gerät am Server eines Admins für Mitteilungen melden
    func registerGuestDevice(_ registration: DeviceRegistration) async throws
    /// Kosten eines Scoops, bei geteilten Scoops pro Person (`GET /api/bots/{id}/usage`)
    func botUsage(botID: String) async throws -> BotUsage
    /// Werkzeuge für Geteilte, Tageslimit und Auswahl-Optionen (`GET /api/bots/{id}/sharing`, Admin)
    func sharingSettings(botID: String) async throws -> SharingSettings
    /// Gast-Gerät abmelden (Austreten)
    func unregisterGuestDevice(token: String) async throws

    func connectEvents()
    func disconnectEvents()
    /// Live-Kanal sofort neu aufbauen (Rückfall-Zähler zurücksetzen).
    func reconnectEvents()
}

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}


/// Standard für Dienste ohne Live-Sprechmodus (Demo-Modus): nicht verfügbar → Gerätestimme.
extension BotService {
    func refreshShares() async throws {}
    func registerGuestDevice(_ registration: DeviceRegistration) async throws { try await registerDevice(registration) }
    func botUsage(botID: String) async throws -> BotUsage {
        throw APIError(status: 404, message: "Der Server kennt die Kosten pro Scoop noch nicht.")
    }
    func sharingSettings(botID: String) async throws -> SharingSettings {
        throw APIError(status: 404, message: "Der Server kennt das Teilen noch nicht.")
    }
    func unregisterGuestDevice(token: String) async throws {}

    // v1.20: ältere Server bzw. Dienste ohne diese Funktionen
    func decideAlways(approvalID: String, mailEdits: MailEdits?) async throws -> Message {
        throw APIError(status: 404, message: "Der Server kennt „Immer erlauben“ noch nicht.")
    }
    func standingApprovals(botID: String) async throws -> [StandingApproval] { [] }
    func deleteStandingApproval(botID: String, id: String) async throws {
        throw APIError(status: 404, message: "Der Server kennt dauerhafte Freigaben noch nicht.")
    }
    func setRoutineModel(id: String, model: String?) async throws -> Routine {
        throw APIError(status: 404, message: "Der Server kennt Modelle pro Routine noch nicht.")
    }
    /// Demo-Modus und Dienste ohne Katalog: eingebaute Liste
    func models() async throws -> ModelCatalog {
        throw APIError(status: 404, message: "Der Server kennt den Modellkatalog noch nicht.")
    }
    // v1.21: ohne bearbeiteten Text wie eine normale Freigabe
    func decideScoopUpdate(approvalID: String, approve: Bool, after: String?) async throws -> Message {
        try await decide(approvalID: approvalID, approve: approve, note: nil)
    }

    // Gerätekanal (v1.18): im Demo-Modus ohne Server
    func sendDeviceMessage(_ text: String) -> Bool { false }
    func registerAppleDevice(_ hello: AppleDeviceHello) async throws -> [AppleDeviceCommand] { [] }
    func pollAppleDevice(deviceID: String) async throws -> [AppleDeviceCommand] { [] }
    func sendAppleResult(deviceID: String, commandID: String, result: JSONValue) async throws {}
    func sendAppleEvent(deviceID: String, event: JSONValue) async throws {}
    func removeAppleDevice(id: String) async throws -> AppleStatus { try await appleStatus() }

    func liveVoiceInfo() async throws -> LiveVoiceInfo { .unavailable }
    func liveVoiceRequest(chatID: String) async throws -> URLRequest {
        throw APIError(status: 503, message: "Im Demo-Modus nicht verfügbar.")
    }
    func liveVoicePreview(voice: String) async throws -> Data {
        throw APIError(status: 503, message: "Im Demo-Modus nicht verfügbar.")
    }
}
