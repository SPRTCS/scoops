import AppKit
import Darwin
import Foundation
import Observation

/// Betreibt den mitgelieferten Python-Server (Contents/Resources/server) als Kindprozess mit Neustart-Überwachung.
///
/// Bewusst kein eigener LaunchAgent: Solange das Eis-Symbol in der Menüleiste ist, läuft der Server – „Beenden“
/// stoppt beides. Die App selbst startet beim Anmelden (SMAppService.mainApp). Daten liegen unter
/// ~/Library/Application Support/AIS Scoops Server (config.json, data/, logs/, backups/).
@Observable
final class ServerManager {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    /// Wo und wie der Server läuft. `test` = isolierte Testinstanz (eigener Ordner, Port, Schlüsselbund-Präfix, Convex-Dev).
    struct Setup {
        var home: URL
        var python: URL?
        var sourcePath: URL?
        var preferredPort = 8787
        var keychainPrefix = "ais-bot"
        var cloudURL: String?
        var test = false
        /// Nur Ansicht (Renderings des Assistenten, `-rendersetup`): kein Prozess, keine Anfragen an einen Server.
        var offline = false
    }

    static let devCloudURL = "https://merry-vole-238.eu-west-1.convex.site"

    let setup: Setup
    private(set) var phase: Phase = .stopped
    private(set) var port: Int = 0
    /// Letzter Stand von `GET /api/setup` (Kopplung, Schlüssel, Name, Adresse, Rechner).
    private(set) var status: JSONValue?
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    /// Der gespeicherte Port war beim letzten Start durch ein anderes Programm belegt (Anzeige in den Einstellungen).
    private(set) var portConflict: PortOccupant?
    /// Wird aufgerufen, sobald der Server (wieder) antwortet – nach jedem Start, Neustart und Portwechsel.
    @ObservationIgnored var onRunning: (() -> Void)?

    /// Wer einen Port belegt (per `lsof` und `proc_pidpath`).
    struct PortOccupant: Equatable {
        var port: Int
        var newPort: Int
        var pid: Int32?
        var name: String
        var path: String?
        /// Alte Entwickler-Installation „AIS Bot“ (LaunchAgent com.ais-bot.server, ~/.local/share/ais-bot)
        var isOldAISBot: Bool

        var summary: String {
            let who = pid.map { "„\(name)“ (PID \($0))" } ?? "ein anderes Programm"
            return "Port \(port) ist belegt durch \(who)\(path.map { ", \($0)" } ?? ""). Der Server läuft deshalb auf Port \(newPort)."
        }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var wantRunning = false
    @ObservationIgnored private var crashes: [Date] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    init(setup: Setup) {
        self.setup = setup
    }

    // MARK: Pfade

    var isAvailable: Bool { setup.python.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }
    var configURL: URL { setup.home.appending(path: "config.json") }
    var logURL: URL { setup.home.appending(path: "logs/server.log") }
    var dataURL: URL { setup.home.appending(path: "data") }
    private var pidURL: URL { setup.home.appending(path: "server.pid") }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Standard-Datenordner der Mac-App.
    static var defaultHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AIS Scoops Server", directoryHint: .isDirectory)
    }

    /// Mitgeliefertes Python im App-Bundle.
    static var bundledPython: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let py = res.appending(path: "server/bin/python3")
        return FileManager.default.isExecutableFile(atPath: py.path) ? py : nil
    }

    // MARK: Status-Abkürzungen

    var linked: Bool { status?["linked"]?.bool ?? false }
    var pendingCode: String? { status?["pending"]?["code"]?.string }
    var pendingTTL: Int? { status?["pending"]?["ttl_seconds"]?.int }
    /// Ablauf des Kopplungscodes (für den Countdown im Assistenten, unabhängig vom Abfragetakt)
    var pendingExpiry: Date? {
        if let iso = status?["pending"]?["expires_at"]?.string,
           let d = ISO8601DateFormatter().date(from: iso) ?? Self.fractionalISO.date(from: iso) { return d }
        return pendingTTL.map { Date().addingTimeInterval(TimeInterval($0)) }
    }
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    var server: JSONValue? { status?["server"] }
    var version: String? { status?["version"]?.string }
    var userName: String? { server?["user_name"]?.string }
    var ownerName: String? { server?["owner_name"]?.string }
    var publicURL: String { server?["public_url"]?.string ?? "" }
    var serverName: String { server?["server_name"]?.string ?? AppModel.defaultName }
    var host: String { server?["host_configured"]?.string ?? "127.0.0.1" }
    var tailnetURL: String { server?["tailnet_url"]?.string ?? "" }
    var lanURL: String { server?["lan_url"]?.string ?? "" }
    /// IDs der Rechner dieses Servers (aus /api/setup).
    var nodeIDs: Set<String> { Set((server?["nodes"]?.array ?? []).compactMap { $0["id"]?.string }) }
    func hasKey(_ name: String) -> Bool { server?["keys"]?[name]?.bool ?? false }
    var hasAnyModelKey: Bool { hasKey("anthropic") || hasKey("openai") }
    /// Selbst angelegte Scoops (ohne den Start-Scoop Pip); `nil` bei älteren Servern, die das nicht melden
    var ownScoopCount: Int? { server?["own_scoops"]?["count"]?.int }
    var newestOwnScoop: String? { server?["own_scoops"]?["newest"]?.string }
    var cloudError: String? { status?["last_error"]?.string }
    /// Mitteilungen: „relay“ (über AIS Scoops Cloud), „direct“ (eigener APNs-Schlüssel) oder nil (aus).
    var pushMode: String? { status?["push"]?["mode"]?.string }
    var pushError: String? { status?["push"]?["error"]?.string }
    var pushSummary: String {
        switch pushMode {
        case "relay": return "Aktiv (über AIS Scoops Cloud)"
        case "direct": return "Aktiv (eigener Push-Schlüssel)"
        default: return linked ? "Aus" : "Aus – erst mit Konto verbinden"
        }
    }

    // MARK: Konfiguration vor dem Start

    /// Legt den Datenordner an und schreibt Edition und Port in config.json (nur fehlende Werte).
    ///
    /// Port bleibt stabil: Belegt ihn ein übrig gebliebener eigener Serverprozess, wird dieser beendet. Nur wenn ein
    /// FREMDES Programm ihn belegt, weicht der Server aus – `portConflict` sagt dann, wer es ist.
    func prepareConfig() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: setup.home.appending(path: "logs"), withIntermediateDirectories: true)
        var cfg = readConfig()
        if cfg["edition"] == nil { cfg["edition"] = "standard" }
        if setup.test, cfg["cloud_url"] == nil { cfg["cloud_url"] = setup.cloudURL ?? Self.devCloudURL }
        var p = (cfg["port"] as? Int) ?? 0
        if p == 0 {
            p = Self.freePort(startingAt: setup.preferredPort)
            cfg["port"] = p
        } else if !Self.portIsFree(p) {
            killStale()
            var occupant = Self.listener(on: p)
            if let o = occupant, isOwnServer(o) {
                Self.terminate(pid: o.pid ?? 0)
                occupant = nil
            }
            if !Self.waitUntilFree(p, seconds: occupant == nil ? 5 : 1) {
                let newPort = Self.freePort(startingAt: p + 1)
                var o = occupant ?? PortOccupant(port: p, newPort: newPort, pid: nil, name: "unbekannt", path: nil,
                                                 isOldAISBot: false)
                o.newPort = newPort
                o.isOldAISBot = o.isOldAISBot || OldAISBotAgent.isInstalled
                portConflict = o
                p = newPort
                cfg["port"] = p
            } else {
                portConflict = nil
            }
        } else {
            portConflict = nil
        }
        port = p
        try writeConfig(cfg)
    }

    /// Unser eigener (übrig gebliebener) Serverprozess: PID aus server.pid oder Python aus einem
    /// „AIS Scoops Server“-Bundle. Bewusst NICHT über den Python-Pfad allein (Entwicklung: gleiches Python wie
    /// andere Server auf diesem Mac).
    private func isOwnServer(_ o: PortOccupant) -> Bool {
        if let pid = o.pid, let own = stalePID(), pid == own { return true }
        return o.path?.contains("AIS Scoops Server.app/Contents/Resources/server/") ?? false
    }

    /// Programm, das auf `port` lauscht (`lsof -nP -iTCP:<port> -sTCP:LISTEN`). nil = keins gefunden bzw. fremder Nutzer.
    static func listener(on port: Int) -> PortOccupant? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var pid: Int32?
        var name = "unbekannt"
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), name == "unbekannt" { name = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var path: String?
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let old = path?.contains("/.local/share/ais-bot/") ?? false
        return PortOccupant(port: port, newPort: port, pid: pid, name: name, path: path, isOldAISBot: old)
    }

    private static func terminate(pid: Int32) {
        guard pid > 1, kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        for _ in 0..<30 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private static func waitUntilFree(_ port: Int, seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if portIsFree(port) { return true }
            usleep(150_000)
        } while Date() < end
        return portIsFree(port)
    }

    func readConfig() -> [String: Any] {
        guard let d = try? Data(contentsOf: configURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private func writeConfig(_ cfg: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        let tmp = configURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }

    /// Frei = niemand lauscht auf 0.0.0.0 oder 127.0.0.1. SO_REUSEADDR wie beim Server selbst (uvicorn), damit
    /// Verbindungen im Zustand TIME_WAIT nach einem Neustart nicht als „belegt“ zählen.
    static func portIsFree(_ port: Int) -> Bool {
        canBind(port, address: INADDR_ANY) && canBind(port, address: inet_addr("127.0.0.1"))
    }

    private static func canBind(_ port: Int, address: in_addr_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = address
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    static func freePort(startingAt start: Int) -> Int {
        for p in start..<(start + 200) where portIsFree(p) { return p }
        return start
    }

    // MARK: Starten, Stoppen

    func start() {
        guard !setup.offline else { return }
        guard isAvailable else {
            phase = .failed("Der Server fehlt in dieser App. Bitte AIS Scoops Server neu herunterladen und installieren.")
            return
        }
        wantRunning = true
        crashes.removeAll()
        do {
            try prepareConfig()
        } catch {
            phase = .failed("Datenordner nicht beschreibbar: \(error.localizedDescription)")
            return
        }
        spawn()
        startPolling()
    }

    func stop() {
        wantRunning = false
        terminateProcess()
        phase = .stopped
        status = nil
    }

    /// Neustart auf demselben Port: erst warten, bis der alte Prozess beendet ist und den Port freigegeben hat.
    /// (Früher wurde sofort neu geprüft – der noch laufende alte Prozess belegte den Port, der Server wich auf
    /// 8788 aus und „Dieser Mac“ verband weiter mit 8787.)
    func restart() {
        guard !setup.offline else { return }
        wantRunning = true
        crashes.removeAll()
        let old = process
        terminateProcess()
        phase = .starting
        Task {
            for _ in 0..<70 where old?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
            guard wantRunning, process == nil else { return }
            do { try prepareConfig() } catch { phase = .failed("Datenordner nicht beschreibbar: \(error.localizedDescription)") }
            spawn()
            startPolling()
        }
    }

    /// Beim Beenden der App: Server sauber herunterfahren (SIGTERM, nach 5 s SIGKILL).
    func shutdown() async {
        wantRunning = false
        pollTask?.cancel()
        guard let p = process, p.isRunning else { return }
        p.terminate()
        for _ in 0..<50 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func terminateProcess() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        if p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func stalePID() -> pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return nil }
        return pid
    }

    /// Ein von einem früheren App-Lauf übrig gebliebener Serverprozess (z. B. nach Absturz) wird beendet.
    private func killStale() {
        guard let pid = stalePID(), kill(pid, 0) == 0 else { return }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path.contains("python") else { return }
        }
        kill(pid, SIGTERM)
        for _ in 0..<30 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private func rotateLog() {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 10_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    }

    private func spawn() {
        guard let python = setup.python else { return }
        killStale()
        rotateLog()
        let p = Process()
        p.executableURL = python
        let main = "from aisbot.server import main; main()"
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "de_DE.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "AISBOT_EDITION": "standard",
            "AISBOT_HOME": setup.home.path,
            "AISBOT_KEYCHAIN_PREFIX": setup.keychainPrefix,
            "PYTHONUNBUFFERED": "1",
            "AISBOT_PARENT_PID": String(getpid()),  // Server beendet sich, wenn die App weg ist
        ]
        if setup.test {
            // Testinstanz (Update-Test, docs/updates.md): darf auf ein Test-Modell zeigen, damit ein Lauf entsteht.
            let outer = ProcessInfo.processInfo.environment
            for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY"] { if let v = outer[key] { env[key] = v } }
        }
        if let src = setup.sourcePath {
            // Entwicklung: Server-Code aus dem Repo, Python aus einer beliebigen Umgebung.
            env["PYTHONPATH"] = src.path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            p.arguments = ["-u", "-c", main]
        } else {
            // -I: nichts aus der Umgebung/dem Nutzerordner laden, -B: nie Bytecode ins signierte Bundle schreiben.
            p.arguments = ["-I", "-B", "-u", "-c", main]
        }
        p.environment = env
        p.currentDirectoryURL = setup.home
        p.standardInput = FileHandle.nullDevice
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            let stamp = ISO8601DateFormatter().string(from: Date())
            h.write(Data("\n— \(stamp) Start durch AIS Scoops Server \(AppModel.appVersion), Port \(port) —\n".utf8))
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.processEnded(proc, status: code) }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
            phase = .starting
            lastError = nil
            try? "\(p.processIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("Server ließ sich nicht starten: \(error.localizedDescription)")
        }
    }

    private func processEnded(_ proc: Process, status code: Int32) {
        guard proc === process else { return }
        process = nil
        try? FileManager.default.removeItem(at: pidURL)
        guard wantRunning else { phase = .stopped; return }
        crashes.append(Date())
        crashes.removeAll { Date().timeIntervalSince($0) > 120 }
        let tail = Self.logTail(logURL, lines: 3)
        if crashes.count >= 5 {
            phase = .failed("Der Server stürzt immer wieder ab (Code \(code)). Details im Protokoll.")
            lastError = tail
            return
        }
        phase = .starting
        let delay = Double(min(30, 1 << crashes.count))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if wantRunning, process == nil {
                try? prepareConfig()  // z. B. Port inzwischen von einem anderen Programm belegt
                spawn()
            }
        }
    }

    static func logTail(_ url: URL, lines: Int) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    // MARK: Status

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let fast = self.phase != .running || self.pendingCode != nil
                try? await Task.sleep(for: .seconds(fast ? 1.5 : 5))
            }
        }
    }

    func refresh() async {
        guard !setup.offline, port > 0, process != nil || phase == .running else { return }
        do {
            let s = try await get("api/setup")
            status = s
            if case .failed = phase {} else if phase != .running {
                phase = .running
                onRunning?()
            }
        } catch {
            if phase == .running, process == nil { phase = wantRunning ? .starting : .stopped }
        }
    }

    // MARK: Einrichtungs-API (nur 127.0.0.1, siehe Server: /api/setup…)

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> JSONValue {
        if setup.offline { throw APIError(message: "Vorschau: keine Verbindung zum Server") }
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = JSONValue.decode(data) ?? .null
        guard (200..<300).contains(code) else {
            throw APIError(message: json["error"]?.string ?? "Server antwortet mit Fehler \(code)")
        }
        return json
    }

    func get(_ path: String) async throws -> JSONValue { try await request("GET", path) }

    /// Kopplungscode für das Konto anfordern (Convex). Der Server pollt selbst, bis er eingelöst ist.
    func startLink(force: Bool = false) async throws {
        status = try await request("POST", "api/setup/link", body: ["force": force])
        startPolling()
    }

    func patchConfig(_ values: [String: Any]) async throws {
        status = try await request("PATCH", "api/setup/config", body: values)
    }

    func nodePairCode() async throws -> String {
        let r = try await request("POST", "api/setup/node-pair")
        guard let code = r["code"]?.string else { throw APIError(message: "Kein Kopplungscode erhalten") }
        return code
    }

    /// „Dieser Mac“ ist Rechner `nodeID`: Geräte-ID speichern, alte Einträge desselben Macs zusammenführen.
    @discardableResult
    func adoptThisMac(nodeID: String, replaces: [String] = [], makeDefault: Bool = false) async throws -> [String] {
        let r = try await request("POST", "api/setup/this-mac", body: [
            "node_id": nodeID, "device_id": Pairing.deviceID, "replaces": replaces, "make_default": makeDefault,
        ])
        status = r
        return (r["merged"]?.array ?? []).compactMap(\.string)
    }

    func reloadApps() async -> JSONValue? {
        try? await request("POST", "api/setup/reload")
    }

    // MARK: KI-Abos (docs/abos.md): Status über die Programme, Login-Ablauf der Programme starten, Abrechnungsmodus

    /// Letzter Stand von `GET /api/setup/abos` (sonst `abos` aus /api/setup)
    private(set) var abosStatus: JSONValue?

    var abos: JSONValue? { abosStatus ?? server?["abos"] }

    func refreshAbos(force: Bool = false) async {
        if let r = try? await request("GET", force ? "api/setup/abos/refresh" : "api/setup/abos") { abosStatus = r }
    }

    func setAboMode(_ provider: String, _ mode: String) async throws {
        abosStatus = try await request("PATCH", "api/setup/abos", body: [provider: mode])
    }

    /// Öffnet auf diesem Mac ein Terminal mit dem offiziellen Login (`claude auth login` bzw. `codex login`).
    func startAboLogin(_ provider: String) async throws {
        let r = try await request("POST", "api/setup/abos/\(provider)/login")
        if let st = r["status"] { abosStatus = st }
    }

    // MARK: Vorschau

    #if DEBUG
    /// Nur für Renderings des Assistenten (`-rendersetup`, `setup.offline`): Zustand setzen, ohne Server.
    func applyPreview(phase: Phase, port: Int, status: JSONValue?) {
        guard setup.offline else { return }
        self.phase = phase
        self.port = port
        self.status = status
        abosStatus = status?["server"]?["abos"]
    }
    #endif

    // MARK: Anzeige

    var statusTitle: String {
        switch phase {
        case .stopped: return "Server gestoppt"
        case .starting: return "Server startet …"
        case .running: return "Server läuft"
        case .failed: return "Server-Fehler"
        }
    }

    var statusColorName: String {
        switch phase {
        case .running: return linked ? "green" : "yellow"
        case .starting: return "yellow"
        case .stopped: return "gray"
        case .failed: return "red"
        }
    }

    func openLogs() {
        NSWorkspace.shared.open(logURL)
    }

    func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
}
