import AppKit
import Foundation
import Observation
import ServiceManagement

/// Rolle der App und alles rund um den eigenen Server: Start, Einrichtung, „Dieser Mac“ als Rechner, Wachhalten.
///
/// - **server**: „AIS Scoops Server“ – betreibt den mitgelieferten Server und steuert diesen Mac direkt.
/// - **connect**: bisheriges Scoops Connect – nur Rechner für einen fremden Server (bestehende Kopplungen).
@Observable
final class ServerController {
    enum Role: String {
        case server, connect
    }

    let model: AppModel
    let manager: ServerManager
    let defaults: UserDefaults
    let test: Bool
    @ObservationIgnored let keepAwake = KeepAwake()

    private(set) var role: Role
    var setupDone: Bool { didSet { defaults.set(setupDone, forKey: "serverSetupDone") } }
    /// Zuletzt geöffneter Schritt des Assistenten: Nach Abbruch oder Neustart geht es dort weiter.
    var savedSetupStep: Int? {
        get { defaults.object(forKey: "serverSetupStep") as? Int }
        set { if let newValue { defaults.set(newValue, forKey: "serverSetupStep") } else { defaults.removeObject(forKey: "serverSetupStep") } }
    }
    var keepSystemAwake: Bool {
        didSet { defaults.set(keepSystemAwake, forKey: "keepSystemAwake"); applyKeepAwake() }
    }
    var keepDisplayAwake: Bool {
        didSet { defaults.set(keepDisplayAwake, forKey: "keepDisplayAwake"); applyKeepAwake() }
    }
    /// Im Testmodus wird „Dieser Mac“ nur gekoppelt, aber nie mit der echten Steuerung verbunden.
    private(set) var testNodeID: String?
    private(set) var notice: String?
    /// Aktive Tailscale-Freigaben (zuletzt gelesen) und ob Tailscale überhaupt da ist.
    private(set) var tailscaleEntries: [Tailscale.ServeEntry] = []
    private(set) var tailscaleChecked = false
    /// Meldung der letzten automatischen Reparatur (Port gewechselt → Kopplung/Freigabe nachgezogen).
    private(set) var repairNote: String?
    private(set) var oldAgentInstalled = OldAISBotAgent.isInstalled

    init(model: AppModel, manager: ServerManager, defaults: UserDefaults, test: Bool) {
        self.model = model
        self.manager = manager
        self.defaults = defaults
        self.test = test
        // Bestehende Installation (Server schon mit einem Konto gekoppelt), die den Assistenten nie angefangen hat:
        // nie in den Assistenten zwingen. Wer ihn angefangen hat (serverSetupStep gesetzt), macht dort weiter.
        let existing = !manager.setup.offline && defaults.object(forKey: "serverSetupStep") == nil
            && manager.readConfig()["owner_id"] != nil
        setupDone = defaults.bool(forKey: "serverSetupDone") || existing
        keepSystemAwake = defaults.object(forKey: "keepSystemAwake") as? Bool ?? !test
        keepDisplayAwake = defaults.bool(forKey: "keepDisplayAwake")
        testNodeID = defaults.string(forKey: "testNodeID")
        if test {
            role = .server
        } else if let r = defaults.string(forKey: "role").flatMap(Role.init(rawValue:)) {
            role = r
        } else if model.isPaired {
            role = .connect  // bestehende Scoops-Connect-Installation: unverändert weiter
        } else {
            role = manager.isAvailable ? .server : .connect
        }
        manager.onRunning = { [weak self] in Task { await self?.serverDidStart() } }
    }

    var isServer: Bool { role == .server }
    var thisMacRegistered: Bool {
        #if DEBUG
        if let p = previewThisMac { return p }
        #endif
        return test ? testNodeID != nil : (model.isPaired && pairedWithOwnServer)
    }

    #if DEBUG
    /// Nur für Renderings des Assistenten (`-rendersetup`)
    @ObservationIgnored var previewThisMac: Bool?
    @ObservationIgnored var previewTailscale: Tailscale.Info?
    @ObservationIgnored var previewTailscaleEntries: [Tailscale.ServeEntry] = []
    #endif

    /// Ist die Rechner-Kopplung dieses Macs die mit dem eigenen Server? (Loopback-Adresse oder der Rechner steht in
    /// der Rechnerliste des eigenen Servers – auch wenn früher eine andere Adresse gespeichert wurde.)
    var pairedWithOwnServer: Bool {
        guard model.isPaired else { return false }
        if let host = URL(string: model.serverURL)?.host(), ["127.0.0.1", "localhost", "::1"].contains(host) { return true }
        return !model.nodeID.isEmpty && manager.nodeIDs.contains(model.nodeID)
    }

    func setRole(_ r: Role) {
        role = r
        defaults.set(r.rawValue, forKey: "role")
        if r == .server { launch() } else { manager.stop(); keepAwake.set(system: false); keepAwake.set(display: false) }
    }

    // MARK: Start

    func launch() {
        guard role == .server else { return }
        manager.start()
        applyKeepAwake()
        if !test, setupDone, !SMAppServiceHelper.isEnabled { SMAppServiceHelper.enable() }
    }

    func applyKeepAwake() {
        let on = role == .server && manager.phase != .stopped
        keepAwake.set(system: on && keepSystemAwake)
        keepAwake.set(display: on && keepDisplayAwake)
    }

    /// Nach JEDEM (Neu-)Start des Servers: „Dieser Mac“ verbindet immer mit http://127.0.0.1:<aktueller Port>
    /// (Token und Kopplung bleiben), alte Einträge desselben Macs werden zusammengeführt, und eine Tailscale-Freigabe,
    /// die noch auf einen alten Port zeigt, wird umgestellt.
    func serverDidStart() async {
        oldAgentInstalled = OldAISBotAgent.isInstalled
        await manager.adoptAppLanguageIfUnset()
        var notes: [String] = []
        if test {
            if let id = testNodeID { _ = try? await manager.adoptThisMac(nodeID: id) }
        } else if pairedWithOwnServer {
            let target = manager.baseURL.absoluteString
            if model.serverURL != target {
                notes.append(String(localized: "Rechner-Verbindung auf \(target) umgestellt (vorher \(model.serverURL))"))
                model.moveServer(to: target)
            } else if model.linkState != .connected {
                model.reconnectNow()
            }
            if let merged = try? await manager.adoptThisMac(nodeID: model.nodeID), !merged.isEmpty {
                notes.append(String(localized: "\(merged.count) alte(r) Eintrag/Einträge dieses Macs zusammengeführt"))
            }
        }
        if !test, let note = await repairTailscale() { notes.append(note) }
        if !notes.isEmpty { repairNote = notes.joined(separator: ". ") + "." }
    }

    /// Tailscale-Freigaben lesen; zeigt unsere Freigabe (Adresse = public_url bzw. tailnet_url) auf einen anderen
    /// Port als den aktuellen, wird sie auf den aktuellen Port umgestellt (gleiche https-Adresse).
    @discardableResult
    func repairTailscale() async -> String? {
        #if DEBUG
        // Renderings: nie Tailscale aufrufen (schon gar nicht `serve`/`funnel`), nur den Beispielzustand zeigen.
        if manager.setup.offline {
            tailscaleEntries = previewTailscaleEntries
            tailscaleChecked = true
            return nil
        }
        #endif
        guard let info = await Tailscale.detect(), info.running else {
            tailscaleEntries = []
            tailscaleChecked = true
            return nil
        }
        var entries = await Tailscale.status(info: info)
        tailscaleEntries = entries
        tailscaleChecked = true
        guard !test, manager.port > 0 else { return nil }
        let ours = Set([manager.publicURL, manager.tailnetURL].compactMap { URL(string: $0) }
            .filter { $0.scheme == "https" }.map { "\($0.host() ?? ""):\($0.port ?? 443)" })
        var fixed: [String] = []
        for e in entries where ours.contains(e.id) {
            guard let tp = e.targetPort, tp != manager.port else { continue }
            if case .success = await Tailscale.share(info: info, localPort: manager.port, publicly: e.funnel, httpsPort: e.httpsPort) {
                fixed.append(e.funnel ? String(localized: "Funnel \(e.url) → Port \(String(manager.port)) (vorher \(String(tp)))")
                                      : String(localized: "Serve \(e.url) → Port \(String(manager.port)) (vorher \(String(tp)))"))
            }
        }
        if !fixed.isEmpty {
            entries = await Tailscale.status(info: info)
            tailscaleEntries = entries
            return String(localized: "Tailscale umgestellt: \(fixed.joined(separator: ", "))")
        }
        return nil
    }

    /// Aktive Freigabe, die auf unseren Server zeigt (Funnel vor Serve).
    var activeShare: Tailscale.ServeEntry? {
        tailscaleEntries.first { $0.funnel && $0.targetPort == manager.port }
            ?? tailscaleEntries.first { $0.targetPort == manager.port }
    }

    /// Alte Installation „AIS Bot“ deaktivieren (nur nach Klick); danach Server auf seinem Port neu starten.
    func disableOldAgent() -> String? {
        guard !test else { return String(localized: "Im Testmodus deaktiviert.") }
        let err = OldAISBotAgent.disable()
        oldAgentInstalled = OldAISBotAgent.isInstalled
        return err
    }

    // MARK: Schlüssel

    var keychainPrefix: String { manager.setup.keychainPrefix }

    func hasKey(_ kind: SecretStore.Kind) -> Bool { SecretStore.exists(kind, prefix: keychainPrefix) }

    func saveKey(_ kind: SecretStore.Kind, value: String) async throws {
        try await SecretStore.save(kind, value: value, prefix: keychainPrefix)
        await keysChanged()
    }

    func deleteKey(_ kind: SecretStore.Kind) async {
        await SecretStore.delete(kind, prefix: keychainPrefix)
        await keysChanged()
    }

    /// Scoops nutzen den Anbieter, für den ein Schlüssel da ist (Claude bevorzugt), Composio wird eingerichtet.
    private func keysChanged() async {
        let provider = hasKey(.anthropic) ? "anthropic" : (hasKey(.openai) ? "openai" : nil)
        if let provider { try? await manager.patchConfig(["provider": provider]) }
        _ = await manager.reloadApps()
        await manager.refresh()
    }

    // MARK: KI-Zugang

    /// Schlüssel vorhanden (Schlüsselbund dieses Macs oder laut Server)
    func modelKey(_ kind: SecretStore.Kind) -> Bool { hasKey(kind) || manager.hasKey(kind.rawValue) }

    /// Abo im Programm angemeldet und als Abrechnung eingestellt („Abo“ bzw. „Abo, bei Limit API“)
    func aboActive(_ provider: String) -> Bool {
        let st = manager.abos?[provider]
        return st?["subscription"]?.bool == true && (st?["mode"]?.string ?? "api") != "api"
    }

    /// Können die Scoops denken? (Schlüssel von Anthropic/OpenAI oder ein aktives Abo)
    var hasModelAccess: Bool {
        modelKey(.anthropic) || modelKey(.openai) || aboActive("claude") || aboActive("openai")
    }

    /// Kurzbeschreibung für Erfolgsanzeige und Abschluss, z. B. „Claude-Abo (Max)“ oder „API-Schlüssel von Anthropic“
    var accessSummary: String? {
        var parts: [String] = []
        for (id, title) in [("claude", "Claude"), ("openai", "ChatGPT")] where aboActive(id) {
            if let plan = manager.abos?[id]?["plan"]?.string, !plan.isEmpty {
                let name = plan.prefix(1).uppercased() + plan.dropFirst()
                parts.append(String(localized: "\(title)-Abo (\(name))", comment: "z. B. „Claude-Abo (Max)“: Anbieter, Tarif"))
            } else {
                parts.append(String(localized: "\(title)-Abo", comment: "z. B. „Claude-Abo“: Anbieter"))
            }
        }
        let keys = [(SecretStore.Kind.anthropic, "Anthropic"), (.openai, "OpenAI")].filter { modelKey($0.0) }.map(\.1)
        if !keys.isEmpty {
            let list = keys.formatted(.list(type: .and).locale(AppLanguage.locale))
            parts.append(String(localized: "API-Schlüssel von \(list)", comment: "Aufzählung der Anbieter, z. B. „Anthropic und OpenAI“"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Nur ein ChatGPT-Abo, kein Claude-Zugang: Scoops auf GPT-Modelle stellen (sonst blieben sie bei Claude).
    func applyProviderForAccess() async {
        let claude = modelKey(.anthropic) || aboActive("claude")
        let openai = modelKey(.openai) || aboActive("openai")
        guard !claude, openai else { return }
        try? await manager.patchConfig(["provider": "openai"])
    }

    // MARK: Dieser Mac

    /// Koppelt diesen Mac als Rechner „direkt“ mit dem eigenen Server und macht ihn zum Standard-Rechner.
    func registerThisMac(name: String) async throws {
        let code = try await manager.nodePairCode()
        let nodeID: String
        if test {
            // Testmodus: nur die Kopplung prüfen, keine Verbindung zur echten Maus-/Tastatursteuerung.
            let claim = try await Pairing.claim(server: manager.baseURL, code: code, name: name, mode: "direct",
                                                os: AppModel.osString, appVersion: AppModel.appVersion + " (Test)")
            nodeID = claim.nodeID
            testNodeID = nodeID
            defaults.set(nodeID, forKey: "testNodeID")
        } else {
            // Alter Eintrag dieses Macs auf dem eigenen Server wird ersetzt, nicht als weiterer „Rechner“ behalten.
            let previous = pairedWithOwnServer ? model.nodeID : ""
            if model.isPaired { model.unpair() }
            try await model.pair(server: manager.baseURL.absoluteString, code: code, name: name, mode: .direct)
            nodeID = model.nodeID
            try await manager.adoptThisMac(nodeID: nodeID, replaces: previous.isEmpty ? [] : [previous], makeDefault: true)
        }
        if test { try await manager.adoptThisMac(nodeID: nodeID, makeDefault: true) }
        try await manager.patchConfig(["default_computer_node": nodeID])
    }

    // MARK: Erreichbarkeit

    /// Tailscale-Adresse speichern. Der Server meldet sie sofort an AIS Scoops Cloud (Herzschlag), damit die App
    /// gleich die https-Adresse bekommt. Funnel: public_url (+ tailnet_url leer lassen), Serve: beide.
    func setPublicURL(_ url: String, tailnet: String? = nil) async throws {
        var body: [String: Any] = ["public_url": url]
        if let tailnet { body["tailnet_url"] = tailnet }
        try await manager.patchConfig(body)
        await repairTailscale()
    }

    /// Nur im WLAN: Server auf allen Netzwerkschnittstellen (Neustart nötig), LAN-Adresse = <Name>.local:<Port>.
    /// Priorität der gemeldeten Adresse: Funnel-URL > Tailnet-URL > LAN – eine https-Adresse wird nicht überschrieben.
    func useLocalNetwork() async throws {
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "localhost"
        let lan = "http://" + (SCDynamicStoreHelper.localHostName ?? host) + ".local:\(manager.port)"
        var body: [String: Any] = ["host": "0.0.0.0", "lan_url": lan]
        if !manager.publicURL.hasPrefix("https://") { body["public_url"] = lan }
        try await manager.patchConfig(body)
        manager.restart()
    }

    func useOnlyThisMac() async throws {
        try await manager.patchConfig(["host": "", "public_url": "", "lan_url": "", "tailnet_url": ""])
        manager.restart()
    }

    /// Adresse, die AIS Scoops auf dem iPhone bekommt.
    var reachabilityKind: String {
        let u = manager.publicURL
        if u.isEmpty { return String(localized: "nur auf diesem Mac") }
        if let e = activeShare, u.hasPrefix(e.url) {
            return e.funnel ? String(localized: "öffentlich (Tailscale Funnel)") : String(localized: "Tailnet (Tailscale Serve)")
        }
        if u.hasPrefix("https://") { return u.contains(".ts.net") ? "Tailscale" : String(localized: "öffentlich") }
        return String(localized: "nur im Heim-WLAN")
    }

    // MARK: Anzeige

    var menuBarSymbol: String {
        if model.isPaired && model.paused { return "pause.circle" }
        if model.isControlled { return "cursorarrow.motionlines" }
        switch manager.phase {
        case .running: return manager.linked ? "server.rack" : "exclamationmark.circle"
        case .starting: return "hourglass"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    // MARK: Beenden

    func prepareForQuit() async {
        keepAwake.set(system: false)
        keepAwake.set(display: false)
        await manager.shutdown()
    }
}

import SystemConfiguration

enum SCDynamicStoreHelper {
    /// Bonjour-Name („Lenas-MacBook-Air“), unter dem der Mac im lokalen Netz als <Name>.local erreichbar ist.
    static var localHostName: String? { SCDynamicStoreCopyLocalHostName(nil) as String? }
}

/// App beim Anmelden starten (der Server läuft als Kindprozess der App).
enum SMAppServiceHelper {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func enable() -> Bool {
        (try? SMAppService.mainApp.register()) != nil
    }
}
