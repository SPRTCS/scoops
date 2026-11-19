import AppKit
import Foundation
import IOKit.pwr_mgt

/// Tailscale-Erkennung und -Freigabe (Serve im eigenen Tailnet, optional Funnel = öffentlich).
/// Befehle laufen nur nach ausdrücklichem Klick und werden vorher erklärt.
nonisolated enum Tailscale {
    struct Info: Sendable, Equatable {
        var cli: String
        var running: Bool
        var dnsName: String?  // z. B. lenas-mac.tail1234.ts.net
        /// Was Tailscale gemeldet hat, falls die Erkennung scheitert (für die Anzeige)
        var diagnostic: String? = nil
    }

    /// Reihenfolge: eigenständige CLI zuerst, dann die App-Binärdatei (App-Store- bzw. Standalone-App).
    static let candidates = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static var isInstalled: Bool {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
            || FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
    }

    /// Die App-Binärdatei verhält sich ohne Terminal wie die Mac-App (startet die Oberfläche statt zu antworten).
    /// `TAILSCALE_BE_CLI=1` erzwingt den Kommandozeilen-Modus.
    static var cliEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TAILSCALE_BE_CLI"] = "1"
        return env
    }

    static func run(_ cli: String, _ args: [String], timeout: TimeInterval) async -> ProcessRunner.Output {
        await ProcessRunner.run(cli, args, timeout: timeout, environment: cliEnvironment)
    }

    static func detect() async -> Info? {
        let clis = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard !clis.isEmpty else { return nil }
        var lastDiag: String?
        for cli in clis {
            let r = await run(cli, ["status", "--json"], timeout: 10)
            // Vor dem JSON stehen manchmal Warnungen (z. B. Versionshinweise) – nur den JSON-Teil lesen.
            let text = r.stdout
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
                  let json = JSONValue.decode(String(text[start...end])) else {
                let msg = (r.stderr + "\n" + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                lastDiag = msg.isEmpty ? "Keine Antwort von \(cli) (Status \(r.status))." : String(msg.prefix(300))
                continue
            }
            let state = json["BackendState"]?.string ?? ""
            var dns = json["Self"]?["DNSName"]?.string
            while dns?.hasSuffix(".") == true { dns?.removeLast() }
            let online = json["Self"]?["Online"]?.bool ?? false
            let running = state == "Running" || online
            let diag = running ? nil : "Tailscale meldet den Zustand „\(state.isEmpty ? "unbekannt" : state)“."
            return Info(cli: cli, running: running, dnsName: dns?.isEmpty == false ? dns : nil, diagnostic: diag)
        }
        return Info(cli: clis[0], running: false, diagnostic: lastDiag)
    }

    /// HTTPS-Port der öffentlichen Freigabe (Funnel erlaubt nur 443, 8443 und 10000).
    static let funnelPort = 10000

    /// `tailscale serve` (nur Tailnet) bzw. `tailscale funnel` (öffentlich) auf den lokalen Server – immer auf den
    /// AKTUELLEN Port `localPort`. `httpsPort` = Port der https-Adresse (Standard: Funnel 10000, sonst = localPort).
    /// Rückgabe: die neue Adresse oder eine verständliche Fehlermeldung (mit Link, falls Tailscale einen liefert).
    static func share(info: Info, localPort: Int, publicly: Bool, httpsPort: Int? = nil) async -> Result<String, ShareError> {
        guard let dns = info.dnsName else { return .failure(ShareError(message: "Tailscale ist nicht angemeldet.")) }
        let https = httpsPort ?? (publicly ? funnelPort : localPort)
        let r = await run(info.cli, [publicly ? "funnel" : "serve", "--bg", "--https=\(https)",
                                     "http://127.0.0.1:\(localPort)"], timeout: 25)
        let out = (r.stderr + "\n" + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !r.timedOut else { return .failure(explain(out, status: r.status, timedOut: r.timedOut, publicly: publicly)) }
        // Prüfen, ob die Freigabe wirklich aktiv ist und auf den richtigen Port zeigt.
        let entries = await status(info: info)
        if !entries.isEmpty, !entries.contains(where: { $0.httpsPort == https && $0.targetPort == localPort && (!publicly || $0.funnel) }) {
            return .failure(ShareError(message: "Tailscale hat die Freigabe nicht übernommen (\(publicly ? "Funnel" : "Serve") auf Port \(https) → \(localPort) fehlt). " + String(out.prefix(300))))
        }
        return .success("https://\(dns):\(https)")
    }

    /// Typische Tailscale-Meldungen verständlich machen; ein Freigabe-Link aus der Ausgabe wird mitgegeben.
    static func explain(_ out: String, status: Int32, timedOut: Bool, publicly: Bool) -> ShareError {
        let link = out.range(of: #"https://login\.tailscale\.com/[^\s"']+"#, options: .regularExpression)
            .flatMap { URL(string: String(out[$0])) }
        let lower = out.lowercased()
        if lower.contains("funnel is not enabled") || lower.contains("/f/funnel") || (publicly && lower.contains("funnel") && link != nil) {
            return ShareError(message: "Funnel ist in deinem Tailnet noch nicht erlaubt. Öffne den Link, erlaube Funnel für diesen Mac und klicke danach erneut auf „Öffentlich freigeben“.", link: link)
        }
        if lower.contains("https") && (lower.contains("not enabled") || lower.contains("/f/serve") || lower.contains("certificate")) {
            return ShareError(message: "HTTPS-Zertifikate sind in deinem Tailnet nicht aktiviert. Öffne den Link (oder Tailscale-Adminkonsole → DNS → HTTPS-Zertifikate aktivieren) und versuche es dann erneut.", link: link)
        }
        if let link {
            return ShareError(message: "Tailscale braucht eine Bestätigung im Browser. Öffne den Link und versuche es danach erneut.", link: link)
        }
        if timedOut {
            return ShareError(message: "Tailscale hat nicht geantwortet (Zeitüberschreitung). Ist Tailscale angemeldet und verbunden?", link: nil)
        }
        return ShareError(message: out.isEmpty ? "Tailscale-Fehler \(status)" : String(out.prefix(400)), link: nil)
    }

    struct ShareError: Error, Sendable {
        let message: String
        var link: URL? = nil
    }

    /// Eine aktive Freigabe laut `tailscale serve status --json`.
    struct ServeEntry: Sendable, Equatable, Identifiable {
        var host: String
        var httpsPort: Int
        var target: String
        var funnel: Bool
        var id: String { "\(host):\(httpsPort)" }
        var url: String { "https://\(host)\(httpsPort == 443 ? "" : ":\(httpsPort)")" }
        /// Lokaler Port des Ziels (nur bei http://127.0.0.1:<port> bzw. localhost)
        var targetPort: Int? {
            guard let u = URL(string: target), ["127.0.0.1", "localhost"].contains(u.host() ?? "") else { return nil }
            return u.port ?? 80
        }
    }

    /// Aktive Serve-/Funnel-Konfiguration (nur lesend).
    static func status(info: Info) async -> [ServeEntry] {
        let r = await run(info.cli, ["serve", "status", "--json"], timeout: 10)
        let text = r.stdout
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = JSONValue.decode(String(text[start...end])) else { return [] }
        guard case .object(let web)? = json["Web"] else { return [] }
        var out: [ServeEntry] = []
        for (key, value) in web {
            guard let colon = key.lastIndex(of: ":"), let port = Int(key[key.index(after: colon)...]) else { continue }
            let target = value["Handlers"]?["/"]?["Proxy"]?.string ?? ""
            let funnel = json["AllowFunnel"]?[key]?.bool ?? false
            out.append(ServeEntry(host: String(key[..<colon]), httpsPort: port, target: target, funnel: funnel))
        }
        return out.sorted { ($0.funnel ? 0 : 1, $0.httpsPort) < ($1.funnel ? 0 : 1, $1.httpsPort) }
    }
}

/// Alte Entwickler-Installation „AIS Bot“ (LaunchAgent `com.ais-bot.server`, Daten in ~/.local/share/ais-bot).
/// Sie kann Port 8787 dauerhaft belegen. Deaktiviert wird sie nur nach ausdrücklichem Klick; gelöscht wird nichts.
enum OldAISBotAgent {
    static let label = "com.ais-bot.server"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// `launchctl bootout` und Umbenennen der plist in „….plist.deaktiviert“ (rückgängig: zurückbenennen und
    /// `launchctl bootstrap gui/<uid> <plist>`). Daten unter ~/.local/share/ais-bot bleiben unangetastet.
    static func disable() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        var target = plistURL.deletingLastPathComponent().appending(path: "\(label).plist.deaktiviert")
        if FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appending(path: "\(label).plist.deaktiviert-\(Int(Date().timeIntervalSince1970))")
        }
        do {
            try FileManager.default.moveItem(at: plistURL, to: target)
        } catch {
            return "Die Datei \(plistURL.path) ließ sich nicht umbenennen: \(error.localizedDescription)"
        }
        return nil
    }
}

/// Hält den Mac wach, solange der Server läuft (ohne Passwort, über eine Energie-Zusicherung wie `caffeinate`).
final class KeepAwake {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    var system: Bool { systemAssertion != 0 }
    var display: Bool { displayAssertion != 0 }

    func set(system on: Bool) {
        toggle(&systemAssertion, on: on, type: kIOPMAssertionTypePreventUserIdleSystemSleep as String)
    }

    func set(display on: Bool) {
        toggle(&displayAssertion, on: on, type: kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
    }

    private func toggle(_ id: inout IOPMAssertionID, on: Bool, type: String) {
        if on, id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "AIS Scoops Server: Scoops sollen jederzeit arbeiten können" as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

/// Systemeinstellungen, die ein Administrator-Passwort brauchen: nur nach Klick, mit macOS-Passwortdialog.
enum AdminSetting {
    /// Ruhezustand bei Inaktivität ausschalten (`pmset -a sleep 0`). Zeigt den Systemdialog für das Passwort.
    static func disableSystemSleep() -> String? {
        run("/usr/bin/pmset -a sleep 0")
    }

    /// Ruhezustand wieder auf macOS-Standard (Netzteil 1 Minute nach Bildschirm, hier: 30 Minuten).
    static func restoreSystemSleep() -> String? {
        run("/usr/bin/pmset -a sleep 30")
    }

    private static func run(_ command: String) -> String? {
        let source = "do shell script \"\(command)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            return err[NSAppleScript.errorMessage] as? String ?? "Unbekannter Fehler"
        }
        return err == nil ? nil : "Abgebrochen"
    }

    static var sleepDisabled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let values = out.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("sleep ") }
        return !values.isEmpty && values.allSatisfy { $0.split(separator: " ").last == "0" }
    }

    static func openLockScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
    }

    static func openEnergySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }
}
