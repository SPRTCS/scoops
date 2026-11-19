import AppKit
import Observation
import ServiceManagement
import SystemConfiguration

/// Zentraler Zustand von Scoops Connect: Kopplung, WebSocket-Verbindung zum Server, Pause, Modus.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable, Identifiable {
        case direct, vm
        var id: String { rawValue }
        var title: String { self == .direct ? "Diesen Mac direkt steuern" : "Abgeschirmte VM" }
        var short: String { self == .direct ? "Direkt" : "VM" }
    }

    enum LinkState: Equatable {
        case unpaired
        case connecting
        case connected
        case waiting(seconds: Int, reason: String)
    }

    /// Wie eine Sitzung endete – bestimmt, ob wir neu verbinden oder das Token löschen.
    private enum SessionEnd {
        case closed(String)
        case bye(String)
        case unauthorized
    }

    // MARK: Einstellungen

    let defaults: UserDefaults
    private(set) var serverURL: String
    private(set) var nodeID: String
    var nodeName: String { didSet { defaults.set(nodeName, forKey: "nodeName") } }
    private(set) var mode: Mode
    var vmName: String { didSet { defaults.set(vmName, forKey: "vmName") } }
    private(set) var paused: Bool

    // MARK: Laufzeit

    private(set) var linkState: LinkState = .unpaired
    private(set) var connectedSince: Date?
    /// Name des Scoops, der gerade arbeitet (falls der Server ihn mitteilt).
    private(set) var activeBotName: String?
    /// Belegung laut Server: awake, busy, user (Mensch hat in AIS Scoops übernommen), asleep.
    private(set) var activityState: String?
    /// Solange gesetzt, steuert ein Scoop diesen Rechner (aktiver Befehl in den letzten 20 s).
    private(set) var recentlyControlled = false
    private(set) var lastCommand: String?
    private(set) var commandCount = 0
    private(set) var notice: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Wird für Live-Prüfung der Rechte im Fenster hochgezählt.
    private(set) var permissionTick = 0
    /// Apple-Freigaben (Erinnerungen, Kalender, Kontakte), wie sie der Server im hello/state sieht.
    private(set) var appleGrants: [AppleService: String] = AppleBridge.grants
    /// Zuletzt ausgeführter Apple-Befehl (für die Anzeige), z. B. „apple.reminders.add“.
    private(set) var lastAppleCommand: (command: String, at: Date)?

    let lume = LumeManager()
    @ObservationIgnored private lazy var direct = DirectExecutor()
    @ObservationIgnored private lazy var vmExec = VMExecutor(lume: lume)
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var lastSeen = Date()
    @ObservationIgnored private var lastPingSent = Date.distantPast
    @ObservationIgnored private var controlClear: Task<Void, Never>?
    @ObservationIgnored private var failedAuth = 0
    @ObservationIgnored private var appleWatch: Task<Void, Never>?
    @ObservationIgnored private let wsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    /// Gekoppelt = Server-Adresse + Token im Schlüsselbund vorhanden.
    private(set) var isPaired = false
    var isControlled: Bool {
        !paused && (activeBotName != nil || activityState == "busy" || activityState == "user" || recentlyControlled)
    }
    var executor: CommandExecutor { mode == .direct ? direct : vmExec }

    /// Token nur im Speicher und im Schlüsselbund – nie loggen.
    @ObservationIgnored private var token: String?

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }()

    static let osString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    /// Gerätename aus den Systemeinstellungen. Nicht `Host.current()`: das löst DNS auf und blockiert den Start.
    static var defaultName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        nodeID = defaults.string(forKey: "nodeID") ?? ""
        nodeName = defaults.string(forKey: "nodeName") ?? Self.defaultName
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .direct
        vmName = defaults.string(forKey: "vmName") ?? ""
        paused = defaults.bool(forKey: "paused")
        token = serverURL.isEmpty ? nil : Keychain.token(account: serverURL)
        isPaired = token != nil
    }

    // MARK: Start

    func start() {
        Task { await lume.refresh() }
        watchApple()
        guard isPaired else { linkState = .unpaired; return }
        connect()
        if mode == .vm { startVMIfConfigured() }
    }

    // MARK: Kopplung

    func pair(server rawServer: String, code: String, name: String, mode: Mode) async throws {
        guard let url = Pairing.normalizeServer(rawServer) else { throw Pairing.Failure.invalidURL }
        let trimmedName = name.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultName : name
        let claim = try await Pairing.claim(server: url, code: code, name: trimmedName, mode: mode.rawValue,
                                            os: Self.osString, appVersion: Self.appVersion)
        let account = url.absoluteString
        guard Keychain.save(token: claim.token, account: account) else {
            throw Pairing.Failure.network("Token konnte nicht im Schlüsselbund gespeichert werden.")
        }
        serverURL = account
        token = claim.token
        isPaired = true
        nodeID = claim.nodeID
        nodeName = trimmedName
        self.mode = mode
        paused = false
        defaults.set(false, forKey: "paused")
        defaults.set(account, forKey: "serverURL")
        defaults.set(claim.nodeID, forKey: "nodeID")
        defaults.set(mode.rawValue, forKey: "mode")
        notice = nil
        failedAuth = 0
        connect()
    }

    /// Eigener Server auf neuem Port (AIS Scoops Server): Token unter der neuen Adresse ablegen und neu verbinden.
    func moveServer(to newURL: String) {
        guard isPaired, let token, newURL != serverURL, Keychain.save(token: token, account: newURL) else { return }
        Keychain.delete(account: serverURL)
        serverURL = newURL
        defaults.set(newURL, forKey: "serverURL")
        connect()
    }

    /// Trennt den Rechner: Verbindung schließen, Token löschen.
    func unpair(reason: String? = nil) {
        if let ws = socket {
            let bye = JSONValue.object(["type": .string("bye"), "reason": .string("Vom Rechner getrennt")])
            ws.send(.string(bye.jsonString)) { _ in }
        }
        linkTask?.cancel()
        linkTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        executor.reset()
        if !serverURL.isEmpty { Keychain.delete(account: serverURL) }
        token = nil
        isPaired = false
        nodeID = ""
        defaults.removeObject(forKey: "nodeID")
        linkState = .unpaired
        connectedSince = nil
        activeBotName = nil
        recentlyControlled = false
        notice = reason
    }

    // MARK: Pause, Modus, Anmeldung

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        defaults.set(value, forKey: "paused")
        if value { executor.reset() }
        sendState()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        executor.reset()
        mode = newMode
        defaults.set(newMode.rawValue, forKey: "mode")
        if newMode == .vm { startVMIfConfigured() }
        // Neu verbinden, damit `hello` den neuen Modus meldet.
        if isPaired { connect() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Anmeldeobjekt: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func tickPermissions() { permissionTick &+= 1 }

    // MARK: Apple-Dienste

    /// System-Dialog für die Freigabe zeigen; danach Server sofort informieren.
    func requestApple(_ s: AppleService) async {
        _ = await AppleBridge.shared.request(s)
        if AppleBridge.systemPermission(s) == "granted" { setAppleEnabled(s, true) }
        refreshApple()
    }

    /// Schalter in dieser App: Freigabe bleibt in macOS, die Scoops nutzen den Dienst aber nicht.
    func setAppleEnabled(_ s: AppleService, _ on: Bool) {
        UserDefaults.standard.set(!on, forKey: AppleBridge.disabledKey(s))
        refreshApple()
    }

    func appleEnabled(_ s: AppleService) -> Bool { !AppleBridge.isDisabled(s) }

    func openAppleSettings(_ s: AppleService) {
        if let url = URL(string: s.settingsURL) { NSWorkspace.shared.open(url) }
    }

    /// Freigaben neu lesen; bei Änderung `state` an den Server (Werkzeuge erscheinen/verschwinden sofort).
    func refreshApple() {
        let now = AppleBridge.grants
        guard now != appleGrants else { return }
        appleGrants = now
        sendState()
    }

    /// Freigaben ändern sich auch in den Systemeinstellungen: alle 3 s prüfen (nur Statusabfragen, billig).
    private func watchApple() {
        appleWatch?.cancel()
        appleWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshApple()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: VM

    func startVMIfConfigured() {
        guard mode == .vm, !vmName.isEmpty, !LumeManager.protectedNames.contains(vmName) else { return }
        startVM(vmName)
    }

    func startVM(_ name: String) {
        vmName = name
        lume.start(name)
        Task {
            while case .working = lume.phase { try? await Task.sleep(for: .seconds(1)) }
            if lume.baseURL != nil { sendState() }
        }
    }

    // MARK: Verbindung

    func connect() {
        linkTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        linkTask = Task { await connectionLoop() }
    }

    func reconnectNow() { if isPaired { connect() } }

    private func connectionLoop() async {
        var delay: Double = 1
        while !Task.isCancelled {
            guard let token, let server = URL(string: serverURL) else { linkState = .unpaired; return }
            linkState = .connecting
            let end = await runSession(server: server, token: token)
            if Task.isCancelled { return }
            // Lief die Verbindung eine Weile stabil, wieder bei 1 s anfangen.
            if let since = connectedSince, Date().timeIntervalSince(since) > 30 { delay = 1 }
            connectedSince = nil
            activeBotName = nil
            activityState = nil
            executor.reset()
            var reason = "Verbindung getrennt"
            switch end {
            case .bye(let r):
                unpair(reason: "Der Server hat den Rechner entfernt" + (r.isEmpty ? "." : ": \(r)"))
                return
            case .unauthorized:
                failedAuth += 1
                if failedAuth >= 3 {
                    unpair(reason: "Der Server kennt dieses Token nicht mehr. Bitte neu koppeln.")
                    return
                }
                reason = "Server lehnt das Token ab"
            case .closed(let r):
                reason = r
            }
            let wait = Int(delay)
            linkState = .waiting(seconds: wait, reason: reason)
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private func runSession(server: URL, token: String) async -> SessionEnd {
        guard var comps = URLComponents(url: server.appending(path: "api/nodes/link"), resolvingAgainstBaseURL: false) else {
            return .closed("Ungültige Server-Adresse")
        }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        guard let url = comps.url else { return .closed("Ungültige Server-Adresse") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = wsSession.webSocketTask(with: req)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        ws.resume()
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            if socket === ws { socket = nil }
        }

        do {
            try await ws.send(.string(await hello().jsonString))
        } catch {
            return classify(ws, error)
        }
        linkState = .connected
        connectedSince = Date()
        failedAuth = 0
        lastSeen = Date()
        lastPingSent = Date()

        let (commands, queue) = AsyncStream.makeStream(of: JSONValue.self)
        return await withTaskGroup(of: SessionEnd?.self) { group in
            group.addTask { await self.receiveLoop(ws, queue) }
            group.addTask { await self.heartbeat(ws) }
            group.addTask { await self.commandLoop(ws, commands); return nil }
            var end: SessionEnd = .closed("Verbindung getrennt")
            for await result in group {
                if let result { end = result; break }
            }
            queue.finish()
            group.cancelAll()
            ws.cancel(with: .goingAway, reason: nil)
            return end
        }
    }

    private func classify(_ ws: URLSessionWebSocketTask, _ error: Error) -> SessionEnd {
        if let code = (ws.response as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 { return .unauthorized }
        return .closed(Self.describe(error, server: URL(string: serverURL)))
    }

    /// Verständlicher Grund für die Statuszeile, z. B. „Verbindung abgelehnt (Port 8787)“.
    static func describe(_ error: Error, server: URL?) -> String {
        let ns = error as NSError
        let port = server?.port.map { " (Port \($0))" } ?? ""
        let host = server?.host() ?? "Server"
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorCannotConnectToHost: return "Verbindung abgelehnt\(port) – dort läuft kein Server"
        case NSURLErrorTimedOut: return "Zeitüberschreitung bei \(host)\(port)"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Adresse \(host) nicht gefunden"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "Keine Netzwerkverbindung"
        case NSURLErrorBadServerResponse: return "Unerwartete Antwort vom Server\(port)"
        default: return ns.localizedDescription
        }
    }

    private func hello() async -> JSONValue {
        var o: [String: JSONValue] = [
            "type": .string("hello"), "node_id": .string(nodeID), "name": .string(nodeName),
            "mode": .string(mode.rawValue), "os": .string(Self.osString), "app_version": .string(Self.appVersion),
            "paused": .bool(paused), "device_id": .string(Pairing.deviceID), "apple": AppleBridge.grantsJSON,
        ]
        if let s = await currentScreen() {
            o["screen"] = .object(["width": .int(Int(s.width)), "height": .int(Int(s.height))])
        }
        if mode == .vm { o["vm"] = .object(["name": .string(vmName), "ready": .bool(lume.baseURL != nil)]) }
        return .object(o)
    }

    private func currentScreen() async -> CGSize? {
        if let s = await executor.screenSize() { return s }
        // VM noch nicht bereit: Auflösung aus `lume ls` (z. B. „1280x800“).
        if mode == .vm, let d = lume.vms.first(where: { $0.name == vmName })?.display {
            let parts = d.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        return nil
    }

    private func sendState() {
        guard let ws = socket, linkState == .connected else { return }
        Task {
            var o: [String: JSONValue] = ["type": .string("state"), "paused": .bool(paused), "apple": AppleBridge.grantsJSON]
            if let s = await currentScreen() {
                o["screen"] = .object(["width": .int(Int(s.width)), "height": .int(Int(s.height))])
            }
            try? await ws.send(.string(JSONValue.object(o).jsonString))
        }
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask, _ queue: AsyncStream<JSONValue>.Continuation) async -> SessionEnd? {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                // 4401 = Token unbekannt (Server hat den Rechner entfernt).
                if ws.closeCode.rawValue == 4401 { return .bye("Token ungültig") }
                if let code = ws.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !code.isEmpty {
                    return .closed(code)
                }
                return .closed("Verbindung vom Server geschlossen")
            }
            lastSeen = Date()
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            guard let msg = JSONValue.decode(text), let type = msg["type"]?.string else { continue }
            switch type {
            case "ping":
                try? await ws.send(.string(#"{"type":"pong"}"#))
            case "pong":
                break
            case "cmd":
                if msg["command"]?.string?.hasPrefix("apple.") == true {
                    // Apple-Dienste laufen neben der Bildschirm-Steuerung (kein Warten hinter Screenshots) und auch,
                    // wenn die Steuerung pausiert ist: Pause betrifft nur Maus, Tastatur und Bildschirm.
                    runApple(ws, msg)
                } else {
                    queue.yield(msg)
                }
            case "bye":
                return .bye(msg["reason"]?.string ?? "")
            case "welcome", "renamed":
                // Der Name in der Server-DB zählt (z. B. nach Umbenennen in AIS Scoops).
                if let name = msg["name"]?.string, !name.isEmpty, name != nodeName { nodeName = name }
                if type == "welcome", let id = msg["node_id"]?.string, !id.isEmpty, id != nodeID {
                    nodeID = id
                    defaults.set(id, forKey: "nodeID")
                }
            case "activity":
                applyActivity(msg)
            default:
                break
            }
        }
        return nil
    }

    /// `{"type": "activity", "state": "awake|busy|user|asleep", "bot_id", "bot_name"}` (API v1.11).
    private func applyActivity(_ msg: JSONValue) {
        activityState = msg["state"]?.string
        let name = msg["bot_name"]?.string
        if let name, !name.isEmpty, activityState == nil || activityState == "busy" {
            activeBotName = name
        } else {
            activeBotName = nil
        }
    }

    private func heartbeat(_ ws: URLSessionWebSocketTask) async -> SessionEnd? {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return nil }
            if Date().timeIntervalSince(lastSeen) > 60 { return .closed("Keine Antwort vom Server seit 60 s") }
            if Date().timeIntervalSince(lastPingSent) >= 20 {
                lastPingSent = Date()
                try? await ws.send(.string(#"{"type":"ping"}"#))
            }
        }
        return nil
    }

    private func commandLoop(_ ws: URLSessionWebSocketTask, _ commands: AsyncStream<JSONValue>) async {
        for await msg in commands {
            let id = msg["id"] ?? .null
            let command = msg["command"]?.string ?? ""
            let params = msg["params"] ?? .object([:])
            let result: JSONValue
            if paused {
                result = CmdResult.fail("Rechner ist pausiert")
            } else if !isPaired {
                result = CmdResult.fail("Rechner ist nicht gekoppelt")
            } else {
                if Commands.active.contains(command) { markControlled(command) }
                // Mit Zeitgrenze: Ein hängender Befehl (z. B. read_bytes auf eine Datei aus iCloud) blockiert
                // die folgenden nicht mehr. Die Reihenfolge bleibt, Befehle laufen weiter nacheinander.
                result = await CommandDeadline.run(command, limit: CommandDeadline.limit(for: command)) { @MainActor in
                    await self.executor.execute(command, params: params)
                }
            }
            commandCount += 1
            let reply = JSONValue.object(["type": .string("result"), "id": id, "result": result])
            do {
                try await ws.send(.string(reply.jsonString))
            } catch {
                return
            }
        }
    }

    private func runApple(_ ws: URLSessionWebSocketTask, _ msg: JSONValue) {
        let id = msg["id"] ?? .null
        let command = msg["command"]?.string ?? ""
        let params = msg["params"] ?? .object([:])
        lastAppleCommand = (command, Date())
        Task {
            let result = await AppleBridge.shared.execute(command, params: params)
            let reply = JSONValue.object(["type": .string("result"), "id": id, "result": result])
            try? await ws.send(.string(reply.jsonString))
        }
    }

    private func markControlled(_ command: String) {
        lastCommand = command
        recentlyControlled = true
        controlClear?.cancel()
        controlClear = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { recentlyControlled = false }
        }
    }

    // MARK: Beenden

    func prepareForQuit() async {
        if let ws = socket {
            ws.cancel(with: .goingAway, reason: nil)
        }
        linkTask?.cancel()
        executor.reset()
        await lume.stopIfStartedByUs()
    }

    // MARK: Anzeige

    var statusTitle: String {
        if paused, isPaired { return "Pausiert" }
        switch linkState {
        case .unpaired: return "Nicht gekoppelt"
        case .connecting: return "Verbinde …"
        case .connected: return "Verbunden"
        case .waiting(let s, _): return "Getrennt – neuer Versuch in \(s) s"
        }
    }

    /// Kurzform für die Statuszeile der Server-App: „Getrennt: Verbindung abgelehnt (Port 8787)“.
    var statusLine: String {
        if paused, isPaired { return "Pausiert" }
        switch linkState {
        case .waiting(_, let reason): return "Getrennt: \(reason)"
        default: return statusTitle
        }
    }

    var statusDetail: String? {
        switch linkState {
        case .waiting(_, let reason): return reason
        case .connected:
            if let h = URL(string: serverURL)?.host() { return h }
            return nil
        default: return notice
        }
    }

    var controlTitle: String {
        if let n = activeBotName { return "\(n) arbeitet gerade" }
        if activityState == "user" { return "Wird über AIS Scoops gesteuert" }
        return "Ein Scoop steuert gerade"
    }

    var menuBarSymbol: String {
        if !isPaired { return "link.badge.plus" }
        if paused { return "pause.circle" }
        if isControlled { return "cursorarrow.motionlines" }
        switch linkState {
        case .connected: return "link.circle.fill"
        default: return "link.circle"
        }
    }
}
