#if DEBUG
import AppKit
import SwiftUI

/// Renderings des Einrichtungsassistenten mit Beispielzustand (Startargument `-rendersetup <Ordner>`, nur Debug).
///
/// Läuft ganz am Anfang von `AppDelegate.init` und beendet die App danach: kein Server-Prozess
/// (`ServerManager.Setup.offline` blockiert jede Anfrage), kein Updater, keine Kopplung, keine Berechtigungsabfrage.
/// Einstellungen landen in einer eigenen, danach gelöschten Suite, Schlüsselbund-Präfix ist ein unbenutzter.
///
///     "…/AIS Scoops Server.app/Contents/MacOS/AIS Scoops Server" -rendersetup ~/Desktop/assistent
enum SetupSnapshots {
    private static let suiteName = "com.ais.scoopsconnect.render"

    struct Scenario {
        var file: String
        var step: SetupStep
        var linked = false
        var pending = false
        var keys: Set<String> = []
        var claudeAbo = false
        var publicURL = ""
        var ownScoops = 0
        var thisMac = false
        var screen = true
        var accessibility = false
        var fullDisk = false
        var tailscale = true
    }

    static let scenarios: [Scenario] = [
        Scenario(file: "0-willkommen", step: .welcome),
        Scenario(file: "1-verbinden-code", step: .account, pending: true),
        Scenario(file: "1-verbinden-verbunden", step: .account, linked: true),
        Scenario(file: "2-ki-zugang-leer", step: .keys, linked: true),
        Scenario(file: "2-ki-zugang-abo", step: .keys, linked: true, claudeAbo: true),
        Scenario(file: "2-ki-zugang-schluessel", step: .keys, linked: true, keys: ["anthropic"]),
        Scenario(file: "3-mac", step: .mac, linked: true, claudeAbo: true),
        Scenario(file: "4-unterwegs", step: .reach, linked: true, claudeAbo: true, thisMac: true, accessibility: true),
        Scenario(file: "5-dauerbetrieb", step: .awake, linked: true, claudeAbo: true,
                 publicURL: "https://lenas-mac-mini.tail1234.ts.net", thisMac: true, accessibility: true),
        Scenario(file: "6-fertig-erster-scoop", step: .done, linked: true, claudeAbo: true,
                 publicURL: "https://lenas-mac-mini.tail1234.ts.net", thisMac: true, accessibility: true),
        Scenario(file: "6-fertig-glueckwunsch", step: .done, linked: true, keys: ["anthropic"], ownScoops: 1),
    ]

    static func renderAll(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in scenarios {
            for dark in [false, true] {
                let url = dir.appending(path: "\(s.file)-\(dark ? "dunkel" : "hell").png")
                if render(s, dark: dark, to: url) { print("✓ \(url.path)") } else { print("✗ \(url.lastPathComponent)") }
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        Permissions.previewOverride = nil
    }

    private static func render(_ s: Scenario, dark: Bool, to url: URL) -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(s.step.rawValue, forKey: "serverSetupStep")
        defaults.set(s.thisMac ? "Lenas Mac mini" : "Mac mini", forKey: "nodeName")

        var setup = ServerManager.Setup(home: FileManager.default.temporaryDirectory.appending(path: "ais-render"),
                                        python: nil, sourcePath: nil)
        setup.keychainPrefix = "ais-scoops-render"
        setup.offline = true
        let manager = ServerManager(setup: setup)
        manager.applyPreview(phase: .running, port: 8787, status: status(s))
        let model = AppModel(defaults: defaults)
        let controller = ServerController(model: model, manager: manager, defaults: defaults, test: false)
        controller.previewThisMac = s.thisMac
        controller.previewTailscale = s.tailscale
            ? Tailscale.Info(cli: "/Applications/Tailscale.app/Contents/MacOS/Tailscale", running: true,
                             dnsName: "lenas-mac-mini.tail1234.ts.net")
            : nil
        Permissions.previewOverride = (s.screen, s.accessibility)

        let root = ServerSetupView(controller: controller, initialStep: s.step) {}
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let size = ServerSetupView.size
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.titlebarAppearsTransparent = true
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // SwiftUI erst einmal laufen lassen (onAppear, task), dann zeichnen
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Antwort von `GET /api/setup`, wie sie der Server in diesem Zustand liefern würde
    private static func status(_ s: Scenario) -> JSONValue? {
        let iso = ISO8601DateFormatter()
        var abos: [String: Any] = [
            "claude": ["installed": true, "logged_in": false, "subscription": false, "mode": "api"],
            "openai": ["installed": true, "logged_in": false, "subscription": false, "mode": "api"],
        ]
        if s.claudeAbo {
            abos["claude"] = ["installed": true, "logged_in": true, "subscription": true, "plan": "max", "mode": "abo_api",
                              "usage": ["utilization": 0.18, "window": "five_hour"]]
        }
        let server: [String: Any] = [
            "edition": "standard", "port": 8787, "user_name": "Lena", "owner_name": s.linked ? "Lena Berger" as Any : NSNull(),
            "server_name": "Lenas Mac mini", "public_url": s.publicURL, "tailnet_url": "", "lan_url": "",
            "keys": ["anthropic": s.keys.contains("anthropic"), "openai": s.keys.contains("openai"), "composio": false],
            "bots": 1 + s.ownScoops, "active_runs": 0,
            "own_scoops": ["count": s.ownScoops, "newest": s.ownScoops > 0 ? "Kiwi" as Any : NSNull()],
            "nodes": [], "full_disk_access": ["granted": s.fullDisk, "process": "AIS Scoops Server"],
            "abos": abos,
        ]
        var body: [String: Any] = ["version": "1.33.0", "linked": s.linked, "server": server,
                                   "push": ["enabled": s.linked, "mode": s.linked ? "relay" as Any : NSNull()]]
        if s.pending {
            let exp = Date().addingTimeInterval(9 * 60 + 12)
            body["pending"] = ["code": "K7QX-29PL", "expires_at": iso.string(from: exp), "ttl_seconds": 552]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return JSONValue.decode(data)
    }
}
#endif
