import AppKit
import SwiftUI
import Testing

/// Rendert die wichtigsten Ansichten der Server-App auf Deutsch und Englisch, ohne die App zu starten
/// (docs/sprache-serverapp.md). Bilder landen in `SCOOPS_RENDER_DIR` (bei `xcodebuild test` als
/// `TEST_RUNNER_SCOOPS_RENDER_DIR=<ordner>` setzen), sonst in einem temporären Ordner.
@MainActor
@Suite("Server-App rendern", .serialized)
struct RenderTests {
    init() {
        RenderBundle.install(source: Bundle(for: RenderBundleToken.self))
    }

    struct Item {
        let number: String
        let name: String
        let render: @MainActor (RenderLanguage) -> [Data]
    }

    static let setupSize = ServerSetupView.size

    static func setup(_ step: SetupStep, _ f: Fixture) -> @MainActor (RenderLanguage) -> [Data] {
        { lang in
            let c = f.makeController()
            return Renderer.render(ServerSetupView(controller: c, initialStep: step) {}, size: setupSize, language: lang)
        }
    }

    static let reachEntries = [
        Tailscale.ServeEntry(host: "lenas-mac-mini.tail1234.ts.net", httpsPort: 10000, target: "http://127.0.0.1:8787", funnel: true),
        Tailscale.ServeEntry(host: "lenas-mac-mini.tail1234.ts.net", httpsPort: 8443, target: "http://127.0.0.1:8786", funnel: false),
    ]

    static var items: [Item] {
        var done = Fixture(claudeAbo: true, publicURL: "https://lenas-mac-mini.tail1234.ts.net:10000", thisMac: true)
        done.setupDone = false
        let settings = Fixture(setupDone: true, keys: ["anthropic", "openai"], claudeAbo: true,
                               publicURL: "https://lenas-mac-mini.tail1234.ts.net:10000", lanURL: "http://Lenas-Mac-mini.local:8787",
                               ownScoops: 2, thisMac: true, tailscaleEntries: reachEntries, workspaceICloud: true,
                               portConflict: ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: 4242, name: "python3",
                                                                       path: "/opt/homebrew/bin/python3", isOldAISBot: false),
                               lastApple: "apple.calendar.add", pendingUpdate: "2.1 (214)")
        return [
            Item(number: "01", name: "assistent-willkommen", render: setup(.welcome, Fixture(linked: false))),
            Item(number: "02", name: "assistent-willkommen-fehler") { lang in
                // Texte wie in ServerManager (dort mit String(localized:) erzeugt)
                let f = Fixture(phase: .failed(String(localized: "Der Server stürzt immer wieder ab (Code \(String(1))). Details im Protokoll.")),
                                linked: false)
                return setup(.welcome, f)(lang)
            },
            Item(number: "03", name: "assistent-verbinden-code", render: setup(.account, Fixture(linked: false, pending: true))),
            Item(number: "04", name: "assistent-verbinden-verbunden", render: setup(.account, Fixture())),
            Item(number: "05", name: "assistent-ki-zugang-abo-leer", render: setup(.keys, Fixture())),
            Item(number: "06", name: "assistent-ki-zugang-abo-angemeldet",
                 render: setup(.keys, Fixture(claudeAbo: true, openaiLoggedInNoAbo: true, openaiMode: "abo"))),
            Item(number: "07", name: "assistent-ki-zugang-schluessel", render: setup(.keys, Fixture(keys: ["anthropic"]))),
            Item(number: "08", name: "assistent-dieser-mac", render: setup(.mac, Fixture(claudeAbo: true, accessibility: false, fullDisk: false))),
            Item(number: "09", name: "assistent-dieser-mac-angeschlossen", render: setup(.mac, Fixture(claudeAbo: true, thisMac: true))),
            Item(number: "10", name: "assistent-unterwegs", render: setup(.reach, Fixture(claudeAbo: true, thisMac: true))),
            Item(number: "11", name: "assistent-unterwegs-ohne-tailscale",
                 render: setup(.reach, Fixture(claudeAbo: true, lanURL: "http://Lenas-Mac-mini.local:8787", thisMac: true, tailscale: false))),
            Item(number: "12", name: "assistent-dauerbetrieb", render: setup(.awake, done)),
            Item(number: "13", name: "assistent-fertig-erster-scoop", render: setup(.done, done)),
            Item(number: "14", name: "assistent-fertig-glueckwunsch",
                 render: setup(.done, Fixture(keys: ["anthropic"], ownScoops: 3))),
            Item(number: "15", name: "assistent-fertig-offen", render: setup(.done, Fixture(phase: .starting, linked: false))),
            Item(number: "16", name: "assistent-willkommen-server-startet") { lang in
                var f = Fixture(phase: .starting, linked: false)
                f.serverAvailable = true
                return setup(.welcome, f)(lang)
            },
            Item(number: "20", name: "menueleiste") { lang in
                let c = Fixture(setupDone: true, claudeAbo: true, publicURL: "https://lenas-mac-mini.tail1234.ts.net:10000",
                                thisMac: true).makeController()
                return Renderer.render(MenuPanel(model: c.model, server: c).fixedSize(), size: CGSize(width: 300, height: 420),
                                       language: lang, trim: true, material: true)
            },
            Item(number: "21", name: "menueleiste-scoop-steuert") { lang in
                let c = Fixture(setupDone: true, claudeAbo: true, thisMac: true, botName: "Kiwi",
                                pendingUpdate: "2.1 (214)").makeController()
                return Renderer.render(MenuPanel(model: c.model, server: c).fixedSize(), size: CGSize(width: 300, height: 480),
                                       language: lang, trim: true, material: true)
            },
            Item(number: "22", name: "menueleiste-einrichtung-offen") { lang in
                let c = Fixture(phase: .starting, linked: false).makeController()
                return Renderer.render(MenuPanel(model: c.model, server: c).fixedSize(), size: CGSize(width: 300, height: 420),
                                       language: lang, trim: true, material: true)
            },
            Item(number: "30", name: "einstellungen") { lang in
                let c = settings.makeController()
                return Renderer.render(ServerSettingsView(controller: c) { _ in }, size: CGSize(width: 640, height: 3600),
                                       language: lang, trim: true)
            },
            Item(number: "31", name: "einstellungen-nicht-verbunden") { lang in
                // Fehler des Servers (cloudError, workspaceError) kommen vom Server in der Sprache aus Accept-Language;
                // hier nachgestellt. Systemfehler (localizedDescription) liefert macOS in der Sprache der App.
                let en = lang == .en
                let denied = en ? "Permission denied" : "Zugriff verweigert"
                var f = Fixture(setupDone: true, phase: .failed(String(localized: "Datenordner nicht beschreibbar: \(denied)")), linked: false,
                                cloudError: en ? "Can’t reach AIS Scoops Cloud" : "AIS Scoops Cloud nicht erreichbar",
                                lastError: "Traceback (most recent call last):\n  …\nOSError: [Errno 48] Address already in use")
                f.workspaceError = en ? "The folder ~/Documents/Scoops isn’t writable." : "Ordner ~/Documents/Scoops ist nicht beschreibbar."
                let c = f.makeController()
                return Renderer.render(ServerSettingsView(controller: c) { _ in }, size: CGSize(width: 640, height: 3600),
                                       language: lang, trim: true)
            },
            Item(number: "40", name: "rechnerzugriff") { lang in
                let c = Fixture(setupDone: true, thisMac: true, screen: false, accessibility: false, fullDisk: false,
                                apple: [.reminders: "granted", .calendar: "denied", .contacts: "not_determined"]).makeController()
                let view = Form {
                    Section("Dieser Mac als Rechner") { PermissionsSection(model: c.model) }
                    FullDiskAccessSection(manager: c.manager)
                    WorkspaceSection(manager: c.manager)
                    Section("Apple-Dienste") { AppleServicesSection(model: c.model) }
                }.formStyle(.grouped).frame(width: 640)
                return Renderer.render(view, size: CGSize(width: 640, height: 2000), language: lang, trim: true)
            },
            Item(number: "41", name: "ki-abos") { lang in
                let c = Fixture(claudeAbo: true, claudeLimit: true, openaiMode: "abo").makeController()
                let view = Form { AbosSection(manager: c.manager); Section("KI-Schlüssel") { KeysStep(controller: c) } }
                    .formStyle(.grouped).frame(width: 640)
                return Renderer.render(view, size: CGSize(width: 640, height: 1600), language: lang, trim: true)
            },
            Item(number: "50", name: "fehlermeldungen") { lang in
                Renderer.render(ErrorGallery().frame(width: 640), size: CGSize(width: 640, height: 2400), language: lang, trim: true)
            },
            Item(number: "51", name: "dialog-rechner-trennen") { lang in
                Renderer.render(alert: unpairAlert(), language: lang)
            },
            Item(number: "60", name: "rechner-kopplung-1") { lang in
                let c = Fixture(role: "connect", linked: false).makeController()
                return Renderer.render(MainWindowView(model: c.model, server: c), size: CGSize(width: 560, height: 520), language: lang)
            },
            Item(number: "61", name: "rechner-kopplung-2") { lang in
                let c = Fixture(role: "connect", linked: false).makeController()
                return Renderer.render(OnboardingView(model: c.model, initialStep: 2) {}.frame(width: 560),
                                       size: CGSize(width: 560, height: 560), language: lang)
            },
            Item(number: "62", name: "rechner-kopplung-3") { lang in
                let c = Fixture(role: "connect", linked: false, accessibility: false).makeController()
                return Renderer.render(OnboardingView(model: c.model, initialStep: 3) {}.frame(width: 560),
                                       size: CGSize(width: 560, height: 620), language: lang)
            },
            Item(number: "63", name: "rechner-einstellungen") { lang in
                let c = Fixture(role: "connect", paired: true,
                                linkState: .waiting(seconds: 8, reason: AppModel.describe(URLError(.cannotConnectToHost),
                                                                                         server: URL(string: "https://lenas-mac-mini.tail1234.ts.net:8787")))).makeController()
                return Renderer.render(SettingsView(model: c.model).frame(width: 560), size: CGSize(width: 560, height: 1700),
                                       language: lang, trim: true)
            },
            Item(number: "64", name: "rechner-menueleiste") { lang in
                let c = Fixture(role: "connect", paired: true, paused: true).makeController()
                return Renderer.render(MenuPanel(model: c.model, server: c).fixedSize(), size: CGSize(width: 300, height: 420),
                                       language: lang, trim: true, material: true)
            },
        ]
    }

    static var outputDir: URL {
        if let d = ProcessInfo.processInfo.environment["SCOOPS_RENDER_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "scoops-render-\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test("Wichtige Ansichten auf Deutsch und Englisch rendern")
    func renderAll() throws {
        let dir = Self.outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["SCOOPS_RENDER_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for lang in RenderLanguage.allCases {
            for item in Self.items where only?.contains(item.number) ?? true {
                RenderBundle.language = lang.rawValue  // auch für Texte, die schon beim Aufbau des Beispielzustands entstehen
                let parts = item.render(lang)
                #expect(!parts.isEmpty, "\(item.number)-\(item.name) (\(lang.rawValue)) ist leer")
                for (i, png) in parts.enumerated() {
                    let part = parts.count > 1 ? "-teil\(i + 1)" : ""
                    try png.write(to: dir.appending(path: "\(item.number)-\(item.name)\(part)-\(lang.rawValue).png"))
                }
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: Fixture.suiteName)
        Permissions.previewOverride = nil
        print("Render-Bilder: \(dir.path)")
    }
}

final class RenderBundleToken {}

/// Typische Fehlermeldungen der Server-App in einer Ansicht (so, wie sie in den Hinweisboxen erscheinen).
struct ErrorGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.messages.enumerated()), id: \.offset) { _, m in
                InfoBox(style: .warning, text: "\(m)")
            }
        }
        .padding(20)
    }

    static var messages: [String] {
        var out: [String] = [
            Pairing.Failure.invalidURL, .invalidCode, .rateLimited, .server(502), .badResponse,
            .network(RenderBundle.language == "en" ? "The request timed out." : "Zeitüberschreitung bei der Anforderung."),
        ].map { $0.localizedDescription }
        out += [SecretStore.SaveError.implausible.localizedDescription, SecretStore.SaveError.keychain.localizedDescription]
        for r in [KeyCheck.result(status: 401), KeyCheck.result(status: 500), .unknown(KeyCheck.offlineMessage)] {
            switch r {
            case .invalid(let m), .unknown(let m): out.append(m)
            case .valid: break
            }
        }
        out += [
            ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: 4242, name: "", path: nil, isOldAISBot: false).summary,
            ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: nil, name: "", path: nil, isOldAISBot: false).summary,
        ]
        out += [
            Tailscale.explain("Funnel is not enabled on your tailnet. https://login.tailscale.com/f/funnel?node=abc", status: 1,
                              timedOut: false, publicly: true).message,
            Tailscale.explain("error: HTTPS certificates are not enabled", status: 1, timedOut: false, publicly: false).message,
            Tailscale.explain("", status: 1, timedOut: true, publicly: false).message,
        ]
        let server = URL(string: "https://lenas-mac-mini.tail1234.ts.net:8787")
        out += [URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.cannotFindHost), URLError(.notConnectedToInternet)]
            .map { AppModel.describe($0, server: server) }
        return out
    }
}
