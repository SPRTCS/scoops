import Foundation
import Observation

/// Modus „Abgeschirmte VM“: findet Lume, listet VMs, legt bei Bedarf eine VM aus dem Cua-Image an,
/// startet sie ohne Fenster und wartet auf ihren Computer-Server (Port 8000).
///
/// Geschützt: VMs in `protectedNames` (auf dem MacBook Air `ais-bot-mac`, die der Server direkt nutzt)
/// werden nur gelesen – nie gestartet, gestoppt oder verändert.
@Observable
final class LumeManager {
    struct VM: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let status: String
        let ip: String?
        let display: String?
        let os: String?
        var isRunning: Bool { status == "running" }
        var isProtected: Bool { LumeManager.protectedNames.contains(name) }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case ready(URL)
        case failed(String)
    }

    /// VMs, die der Server selbst steuert und die Scoops Connect nie anfassen darf.
    nonisolated static let protectedNames: Set<String> = ["ais-bot-mac"]
    /// Cua-Image mit vorinstalliertem Computer-Server (ghcr.io/trycua/macos-tahoe-cua).
    nonisolated static let cuaImage = "macos-tahoe-cua:latest"
    nonisolated static let defaultVMName = "scoops-vm"

    private(set) var lumePath: String?
    private(set) var lumeVersion: String?
    private(set) var vms: [VM] = []
    private(set) var phase: Phase = .idle
    private(set) var log: [String] = []
    private(set) var isBusy = false
    /// Name der VM, die wir selbst gestartet haben (nur diese stoppen wir beim Beenden).
    private(set) var startedByUs: String?

    private var runProcess: Process?
    private var task: Task<Void, Never>?

    var baseURL: URL? { if case .ready(let url) = phase { url } else { nil } }

    nonisolated static func findLume() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/lume", "/usr/local/bin/lume", "\(home)/.local/bin/lume"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() async {
        lumePath = Self.findLume()
        guard let lume = lumePath else { vms = []; lumeVersion = nil; return }
        if lumeVersion == nil {
            let v = await ProcessRunner.run(lume, ["--version"], timeout: 10)
            lumeVersion = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let out = await ProcessRunner.run(lume, ["ls", "--format", "json"], timeout: 20)
        vms = Self.parseList(out.stdout)
    }

    nonisolated static func parseList(_ text: String) -> [VM] {
        guard let start = text.firstIndex(of: "["), let json = JSONValue.decode(String(text[start...])),
              let arr = json.array else { return [] }
        return arr.compactMap { v in
            guard let name = v["name"]?.string else { return nil }
            return VM(name: name, status: v["status"]?.string ?? "unbekannt", ip: v["ipAddress"]?.string,
                      display: v["display"]?.string, os: v["os"]?.string)
        }
    }

    /// Installiert Lume über Homebrew (`brew install lume`).
    func installLume() {
        guard let brew = Self.brewPath else {
            phase = .failed("Homebrew fehlt. Installiere es von brew.sh oder Lume von cua.ai/docs/lume.")
            return
        }
        runJob("Installiere Lume …") { [weak self] in
            let r = await ProcessRunner.run(brew, ["install", "lume"], timeout: 1800, onLine: { line in
                Task { @MainActor in self?.appendLog(line) }
            })
            return r.status == 0 ? nil : "brew install lume ist fehlgeschlagen (Code \(r.status))."
        }
    }

    /// Lädt das Cua-Image als neue VM (`lume pull macos-tahoe-cua:latest <name>`). Dauert je nach Leitung lange.
    func createVM(named rawName: String) {
        guard let lume = lumePath else { return }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(name) else { phase = .failed("Ungültiger VM-Name (nur a–z, 0–9, - und _)."); return }
        guard !Self.protectedNames.contains(name), !vms.contains(where: { $0.name == name }) else {
            phase = .failed("Eine VM namens „\(name)“ gibt es schon."); return
        }
        runJob("Lade Cua-macOS-Image (\(Self.cuaImage)) als „\(name)“ …") { [weak self] in
            let r = await ProcessRunner.run(lume, ["pull", Self.cuaImage, name], timeout: 6 * 3600, onLine: { line in
                Task { @MainActor in self?.appendLog(line) }
            })
            return r.status == 0 ? nil : "lume pull ist fehlgeschlagen (Code \(r.status))."
        }
    }

    nonisolated static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Startet die VM (falls nötig) ohne Fenster und wartet auf den Computer-Server.
    func start(_ name: String) {
        guard let lume = lumePath else { phase = .failed("Lume ist nicht installiert."); return }
        guard !Self.protectedNames.contains(name) else {
            phase = .failed("„\(name)“ wird vom Server direkt genutzt und bleibt unangetastet.")
            return
        }
        task?.cancel()
        isBusy = true
        phase = .working("Starte „\(name)“ …")
        task = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            let current = self.vms.first { $0.name == name }
            if current == nil { self.finish(.failed("VM „\(name)“ nicht gefunden.")); return }
            if current?.isRunning != true {
                self.launch(lume: lume, name: name)
            }
            self.phase = .working("Warte auf die IP-Adresse der VM …")
            var ip: String?
            for _ in 0..<120 where !Task.isCancelled {
                let r = await ProcessRunner.run(lume, ["get", name, "--format", "json"], timeout: 15)
                if let start = r.stdout.firstIndex(where: { $0 == "[" || $0 == "{" }),
                   let v = JSONValue.decode(String(r.stdout[start...])) {
                    let obj = v.array?.first ?? v
                    if obj["status"]?.string == "running", let a = obj["ipAddress"]?.string, !a.isEmpty { ip = a; break }
                }
                if let p = self.runProcess, !p.isRunning, self.startedByUs == name {
                    self.finish(.failed("Die VM hat sich direkt wieder beendet. Details: ~/Library/Logs/lume")); return
                }
                try? await Task.sleep(for: .seconds(3))
            }
            guard let ip, let base = URL(string: "http://\(ip):8000") else {
                self.finish(.failed("Die VM hat keine IP-Adresse bekommen.")); return
            }
            self.phase = .working("Warte auf den Computer-Server in der VM (\(ip):8000) …")
            for _ in 0..<200 where !Task.isCancelled {
                if await Self.statusOK(base) { self.finish(.ready(base)); await self.refresh(); return }
                try? await Task.sleep(for: .seconds(3))
            }
            self.finish(.failed("Der Computer-Server in der VM antwortet nicht auf \(ip):8000/status."))
        }
    }

    /// Startet `lume run <name> --display none` als Kindprozess. Er lebt, solange Scoops Connect läuft.
    private func launch(lume: String, name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lume)
        p.arguments = ["run", name, "--display", "none"]
        p.standardInput = FileHandle.nullDevice
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Scoops Connect")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appending(path: "\(name).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = h
            p.standardError = h
        }
        do {
            try p.run()
            runProcess = p
            startedByUs = name
        } catch {
            phase = .failed("lume run konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    nonisolated static func statusOK(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appending(path: "status"), timeoutInterval: 3)
        req.httpMethod = "GET"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Prüft, ob eine bereits bereite VM noch antwortet; sonst zurück auf „idle“.
    func verify() async {
        guard let base = baseURL else { return }
        if !(await Self.statusOK(base)) { phase = .failed("Der Computer-Server der VM antwortet nicht mehr.") }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
        if case .working = phase { phase = .idle }
    }

    /// Stoppt nur eine VM, die Scoops Connect selbst gestartet hat (nie geschützte VMs).
    func stopIfStartedByUs() async {
        task?.cancel()
        guard let name = startedByUs, !Self.protectedNames.contains(name), let lume = lumePath ?? Self.findLume() else { return }
        _ = await ProcessRunner.run(lume, ["stop", name], timeout: 60)
        if let p = runProcess, p.isRunning { p.terminate() }
        runProcess = nil
        startedByUs = nil
        phase = .idle
    }

    // MARK: intern

    private func runJob(_ title: String, _ body: @escaping () async -> String?) {
        task?.cancel()
        isBusy = true
        log = []
        phase = .working(title)
        task = Task { [weak self] in
            let error = await body()
            guard let self else { return }
            await self.refresh()
            self.finish(error.map { .failed($0) } ?? .idle)
        }
    }

    private func finish(_ p: Phase) {
        phase = p
        isBusy = false
    }

    private func appendLog(_ line: String) {
        // Fortschrittsbalken überschreiben sich mit \r – nur die letzten Zeilen behalten.
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
