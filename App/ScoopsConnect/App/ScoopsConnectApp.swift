import AppKit
import SwiftUI

@main
struct ScoopsConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: delegate.model, server: delegate.server)
        } label: {
            MenuBarLabel(model: delegate.model, server: delegate.server)
        }
        .menuBarExtraStyle(.window)

        Window("AIS Scoops Server", id: WindowID.main) {
            MainWindowView(model: delegate.model, server: delegate.server)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(delegate.showWindowAtLaunch ? .presented : .suppressed)

        // Nur für Screenshots/Tests (Debug, `-menupreview`): das Menü-Panel als normales Fenster.
        Window("Menü-Vorschau", id: WindowID.menuPreview) {
            MenuPanel(model: delegate.model, server: delegate.server)
                .background(.regularMaterial)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(LaunchOptions.shared.menuPreview ? .presented : .suppressed)
    }
}

/// Symbol in der Menüleiste; öffnet außerdem das Hauptfenster, wenn ein Kopplungslink ankommt.
private struct MenuBarLabel: View {
    let model: AppModel
    let server: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: server.isServer ? server.menuBarSymbol : model.menuBarSymbol)
            .accessibilityLabel(server.isServer ? "AIS Scoops Server – \(server.manager.statusTitle)"
                                                : "Scoops Connect – \(model.statusTitle)")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
    }
}

enum WindowID {
    static let main = "main"
    static let menuPreview = "menu-preview"
}

/// Startargumente. Test- und Screenshot-Schalter wirken nur in Debug-Builds.
struct LaunchOptions {
    static let shared = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    var fakeServer: URL?
    var fakeCode = "TEST-2345"
    var fakeMode: AppModel.Mode = .direct
    var onboardingStep: Int?
    var menuPreview = false
    /// Hauptfenster auch im Testmodus öffnen (Screenshots der Einstellungen).
    var showWindow = false
    /// Test: nach so vielen Sekunden Verbindung automatisch pausieren (prüft die Ablehnung im Fake-Server).
    var pauseAfter: Double?
    /// AIS Scoops Server im Testmodus: eigener Datenordner, Port 8799, eigener Schlüsselbund-Präfix, Convex-Dev,
    /// keine echte Steuerung dieses Macs. Wirkt auch in Release-Builds (prüft die signierte App).
    var testServerHome: URL?
    var testServerPort = 8799
    /// Entwicklung: Python und Server-Code von außerhalb des Bundles.
    var serverPython: URL?
    var serverSource: URL?
    /// Test (nur mit -testserver): Assistent ohne Klicks durchlaufen – Kopplungscode, Testschlüssel, „Dieser Mac“.
    var autoSetup = false
    /// Screenshots: Assistent direkt bei Schritt N öffnen (0 = Willkommen … 6 = Fertig).
    var setupStep: Int?
    /// Renderings aller Assistenten-Schritte mit Beispielzustand als PNG in diesen Ordner, dann beenden. Startet
    /// keinen Server, liest und schreibt keine Einstellungen der echten App (SetupSnapshots.swift, nur Debug).
    var renderSetupDir: URL?

    init(arguments args: [String]) {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
            return args[i + 1]
        }
        if let dir = value(after: "-testserver") { testServerHome = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
        if let p = value(after: "-testport"), let n = Int(p) { testServerPort = n }
        // Update-Test (docs/updates.md): Eine Testkopie mit eigener Bundle-ID merkt sich Testordner und Port in ihren
        // Einstellungen, damit sie auch nach dem Neustart durch Sparkle (ohne Startargumente) im Testmodus bleibt.
        // Die echte App (com.ais.scoopsconnect) liest das nie.
        if testServerHome == nil, let id = Bundle.main.bundleIdentifier, id != "com.ais.scoopsconnect",
           let dir = UserDefaults.standard.string(forKey: "TestServerHome") {
            testServerHome = URL(fileURLWithPath: dir)
            let p = UserDefaults.standard.integer(forKey: "TestServerPort")
            if p > 0 { testServerPort = p }
        }
        #if DEBUG
        if let p = value(after: "-serverpython") { serverPython = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if let p = value(after: "-serversrc") { serverSource = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        autoSetup = args.contains("-autosetup") && testServerHome != nil
        if let n = value(after: "-setupstep").flatMap(Int.init) { setupStep = n }
        if let d = value(after: "-rendersetup") { renderSetupDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath) }
        if args.contains("-fakeserver") {
            let port = value(after: "-fakeserver") ?? "8799"
            fakeServer = URL(string: "http://127.0.0.1:\(port)")
        }
        if let c = value(after: "-code") { fakeCode = c }
        if let m = value(after: "-mode"), let mode = AppModel.Mode(rawValue: m) { fakeMode = mode }
        if let s = value(after: "-onboarding-step"), let n = Int(s) { onboardingStep = n }
        menuPreview = args.contains("-menupreview")
        showWindow = args.contains("-showwindow")
        if let s = value(after: "-pauseafter") { pauseAfter = Double(s) }
        #endif
    }

    func showMainWindow(paired: Bool) -> Bool {
        if menuPreview { return false }
        if onboardingStep != nil || showWindow { return true }
        // Testläufe gegen den Fake-Server koppeln automatisch und brauchen kein Fenster.
        return !paired && fakeServer == nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let server: ServerController

    override init() {
        let options = LaunchOptions.shared
        #if DEBUG
        // Vor allem anderen: kein Updater, keine Kopplung, kein Server – nur Bilder rendern und beenden.
        if let dir = options.renderSetupDir {
            SetupSnapshots.renderAll(to: dir)
            exit(0)
        }
        #endif
        var defaults = UserDefaults.standard
        // Testläufe nutzen eigene Einstellungen, damit eine echte Kopplung unberührt bleibt.
        if options.fakeServer != nil, let suite = UserDefaults(suiteName: "com.ais.scoopsconnect.fakeserver") {
            defaults = suite
        } else if options.testServerHome != nil, let suite = UserDefaults(suiteName: "com.ais.scoopsconnect.testserver") {
            defaults = suite
        }
        model = AppModel(defaults: defaults)
        let test = options.testServerHome != nil
        var setup = ServerManager.Setup(home: options.testServerHome ?? ServerManager.defaultHome,
                                        python: options.serverPython ?? ServerManager.bundledPython,
                                        sourcePath: options.serverSource)
        if test {
            setup.preferredPort = options.testServerPort
            setup.keychainPrefix = "ais-scoops-test"
            setup.cloudURL = ServerManager.devCloudURL
            setup.test = true
        }
        server = ServerController(model: model, manager: ServerManager(setup: setup), defaults: defaults, test: test)
        super.init()
        AppUpdater.shared.server = server
    }

    /// Hauptfenster beim Start: Einrichtung (Server) bzw. Kopplung (Rechner) noch offen.
    var showWindowAtLaunch: Bool {
        let o = LaunchOptions.shared
        if o.menuPreview { return false }
        if server.isServer { return !server.setupDone || o.showWindow || o.setupStep != nil }
        return o.showMainWindow(paired: model.isPaired)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.shared
        // Fake-Server-Läufe starten immer mit frischer Kopplung (alte Test-Tokens sind dort ungültig).
        if options.fakeServer != nil, model.isPaired { model.unpair() }
        // Im Testmodus des Servers wird die echte Steuerung dieses Macs nie verbunden.
        if !server.test { model.start() }
        server.launch()
        if let server = options.fakeServer, !model.isPaired {
            Task {
                do {
                    try await model.pair(server: server.absoluteString, code: options.fakeCode,
                                         name: "Testrechner", mode: options.fakeMode)
                } catch {
                    NSLog("Scoops Connect: Fake-Kopplung fehlgeschlagen: %@", error.localizedDescription)
                }
            }
        }
        if let seconds = options.pauseAfter {
            Task {
                while model.linkState != .connected { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(seconds))
                model.setPaused(true)
            }
        }
        if options.autoSetup { Task { await runAutoSetup() } }
        if showWindowAtLaunch || options.menuPreview {
            NSApp.activate()
        }
    }

    /// Testlauf der Einrichtung über dieselben Funktionen wie der Assistent; Protokoll in <Testordner>/autosetup.log.
    private func runAutoSetup() async {
        let m = server.manager
        let logURL = m.setup.home.appending(path: "autosetup.log")
        func log(_ s: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
        }
        for _ in 0..<120 where m.phase != .running { try? await Task.sleep(for: .milliseconds(500)) }
        log("phase=\(m.phase) port=\(m.port) version=\(m.version ?? "-") keychainPrefix=\(m.setup.keychainPrefix)")
        log("portConflict=\(m.portConflict?.summary ?? "-") oldAgent=\(server.oldAgentInstalled) publicURL=\(m.publicURL) lanURL=\(m.lanURL)")
        do {
            try await m.startLink()
            log("code=\(m.pendingCode ?? "-") ttl=\(m.pendingTTL ?? -1)")
            try await server.registerThisMac(name: "Testrechner")
            log("node=\(server.testNodeID ?? "-") registered=\(server.thisMacRegistered) modelPaired=\(model.isPaired)")
            // Neukopplung desselben Macs: ersetzt den Eintrag (gleiche Geräte-ID) statt einen weiteren anzulegen.
            let first = server.testNodeID
            try await server.registerThisMac(name: "Testrechner")
            await m.refresh()
            log("reregister node=\(server.testNodeID ?? "-") sameID=\(first == server.testNodeID) nodes=\(m.nodeIDs.count) default=\(m.server?["default_computer_node"]?.string ?? "-")")
            // Neustart: Port muss gleich bleiben (früher wich der Server auf den nächsten Port aus).
            let before = m.port
            m.restart()
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<60 where m.phase != .running { try? await Task.sleep(for: .milliseconds(500)) }
            log("restart port \(before) → \(m.port) phase=\(m.phase) stable=\(before == m.port)")
            try await m.patchConfig(["user_name": "Testperson"])
            log("user_name=\(m.userName ?? "-")")
            try await server.saveKey(.anthropic, value: "sk-ant-test-" + String(repeating: "0", count: 24))
            log("anthropic_saved=\(server.hasKey(.anthropic)) server_sees=\(m.hasKey("anthropic")) model=\(m.server?["default_model"]?.string ?? "-")")
            await server.deleteKey(.anthropic)
            log("anthropic_deleted=\(!server.hasKey(.anthropic)) server_sees=\(m.hasKey("anthropic"))")
            for _ in 0..<200 where !m.linked { try? await Task.sleep(for: .milliseconds(500)); await m.refresh() }
            log("linked=\(m.linked) owner=\(m.ownerName ?? "-") user_name=\(m.userName ?? "-")")
        } catch {
            log("FEHLER: \(error.localizedDescription)")
        }
        log("fertig")
    }

    /// `scoopsconnect://pair?server=<url>&code=<code>` füllt das Onboarding vor.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "scoopsconnect" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        PairingPrefill.shared.server = items.first { $0.name == "server" || $0.name == "url" }?.value
        PairingPrefill.shared.code = items.first { $0.name == "code" }?.value
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.prepareForQuit()
            await server.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@Observable
final class PairingPrefill {
    static let shared = PairingPrefill()
    var server: String?
    var code: String?
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("ScoopsConnectOpenMainWindow")
}
