import AppKit
import SwiftUI

// Hilfen für die Render-Tests der Server-App (docs/sprache-serverapp.md): Sprache umschalten, Beispielzustand bauen,
// Ansichten offscreen in ein PNG zeichnen. Nichts davon startet einen Server, den Updater oder fragt Rechte an.

/// Ersatz für `Bundle.main` im Testprozess: Die App-Quellen schlagen Texte in `Bundle.main` nach (im Testprozess ist das
/// `xctest`). Diese Klasse leitet jede Nachschlage-Anfrage an das Test-Bundle weiter, das dieselben String Catalogs wie
/// die App enthält, und zwar mit der gewählten Sprache. So lassen sich beide Sprachen in einem Lauf rendern.
///
/// Weitergeleitet wird an dieselbe Foundation-Methode des Test-Bundles (auch an die nicht öffentlichen, die
/// `String(localized:)` und `Text` nutzen), damit Mehrzahl-Regeln und Markdown genau wie in der App ausgewertet werden.
nonisolated final class RenderBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var language = "de"
    nonisolated(unsafe) static var source: Bundle?

    override var preferredLocalizations: [String] { [Self.language] }
    override var localizations: [String] { ["de", "en"] }
    override var developmentLocalization: String? { "de" }

    /// Die gebaute App neben dem Test-Bundle (Symbol und Version für die Bilder)
    static var appBundle: Bundle? {
        // SCOOPS_RENDER_PLAIN=1: ohne Symbol und Version der App (Vergleich mit älteren Bildern)
        guard let source, ProcessInfo.processInfo.environment["SCOOPS_RENDER_PLAIN"] == nil else { return nil }
        return Bundle(url: source.bundleURL.deletingLastPathComponent().appending(path: "AIS Scoops Server.app"))
    }

    /// Version wie in der App (statt der von `xctest`)
    override var infoDictionary: [String: Any]? {
        var info = super.infoDictionary ?? [:]
        if let app = Self.appBundle?.infoDictionary {
            for key in ["CFBundleShortVersionString", "CFBundleVersion"] { info[key] = app[key] }
        }
        return info
    }

    private typealias Msg4 = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> Unmanaged<AnyObject>
    private typealias Msg6 = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?, AnyObject?, Bool)
        -> Unmanaged<AnyObject>

    /// `-[source <sel>key value table extra]`
    private static func call(_ sel: String, _ k: NSString, _ v: NSString?, _ t: NSString?, _ extra: AnyObject?) -> AnyObject {
        guard let source else { return v ?? k }
        let s = NSSelectorFromString(sel)
        let fn = unsafeBitCast(source.method(for: s), to: Msg4.self)
        return fn(source, s, k, v, t, extra).takeUnretainedValue()
    }

    /// Einmal pro Prozess: `Bundle.main` auf diese Klasse umstellen. Nur im Testprozess.
    static func install(source: Bundle) {
        self.source = source
        guard !(Bundle.main is RenderBundle) else { return }
        let cls: AnyClass = RenderBundle.self
        func add(_ sel: String, _ block: Any, _ types: String) {
            let imp = imp_implementationWithBlock(block)
            if !class_addMethod(cls, NSSelectorFromString(sel), imp, types) {
                class_replaceMethod(cls, NSSelectorFromString(sel), imp, types)
            }
        }
        var lang: NSString { language as NSString }
        var langs: NSArray { [language] as NSArray }
        let plain: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> AnyObject = { _, k, v, t in
            call("localizedStringForKey:value:table:localization:", k, v, t, lang)
        }
        add("localizedStringForKey:value:table:", plain, "@@:@@@")
        let one: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> AnyObject = { _, k, v, t, _ in
            call("localizedStringForKey:value:table:localization:", k, v, t, lang)
        }
        add("localizedStringForKey:value:table:localization:", one, "@@:@@@@")
        let many: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> AnyObject = { _, k, v, t, _ in
            call("localizedStringForKey:value:table:localizations:", k, v, t, langs)
        }
        add("localizedStringForKey:value:table:localizations:", many, "@@:@@@@")
        let manyPrivate: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> AnyObject = { _, k, v, t, _ in
            call("_localizedStringForKey:value:table:localizations:", k, v, t, langs)
        }
        add("_localizedStringForKey:value:table:localizations:", manyPrivate, "@@:@@@@")
        let markdown: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?, AnyObject?, Bool) -> AnyObject = {
            _, k, v, t, _, _, prevent in
            guard let src = RenderBundle.source else { return v ?? k }
            let sel = NSSelectorFromString("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:")
            let fn = unsafeBitCast(src.method(for: sel), to: Msg6.self)
            return fn(src, sel, k, v, t, src.localizations as NSArray, lang, prevent).takeUnretainedValue()
        }
        add("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:", markdown, "@@:@@@@@B")
        let attributed: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> AnyObject = { _, k, v, t in
            call("localizedAttributedStringForKey:value:table:localization:", k, v, t, lang)
        }
        add("localizedAttributedStringForKey:value:table:", attributed, "@@:@@@")
        let attributedOne: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> AnyObject = { _, k, v, t, _ in
            call("localizedAttributedStringForKey:value:table:localization:", k, v, t, lang)
        }
        add("localizedAttributedStringForKey:value:table:localization:", attributedOne, "@@:@@@@")
        object_setClass(Bundle.main, RenderBundle.self)
    }
}

enum RenderLanguage: String, CaseIterable {
    case de, en
    var locale: Locale { Locale(identifier: self == .de ? "de_DE" : "en_US") }
}

@MainActor
enum Renderer {
    /// Zeichnet `view` in ein Fenster der Größe `size` (Punkte) und liefert ein PNG mit `scale` Pixeln pro Punkt.
    /// `trim`: unten gleichfarbigen Rand abschneiden (Formulare mit großzügiger Höhe). `maxPixelHeight`: höhere Bilder
    /// werden in mehrere Teile geschnitten.
    static func render(_ view: some View, size: CGSize, language: RenderLanguage, dark: Bool = false, scale: CGFloat = 1.5,
                       trim: Bool = false, maxPixelHeight: Int = 1600, material: Bool = false) -> [Data] {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if let icon = RenderBundle.appBundle?.image(forResource: "AppIcon") { NSApp.applicationIconImage = icon }
        RenderBundle.language = language.rawValue
        let root = view
            .background(material ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            .environment(\.locale, language.locale)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.titlebarAppearsTransparent = true
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
        }
        defer { window.contentView = nil }
        return snapshot(host, scale: scale, trim: trim, maxPixelHeight: maxPixelHeight)
    }

    /// Zeichnet ein `NSAlert` (wie es `runModal()` zeigen würde, aber ohne es anzuzeigen).
    static func render(alert: NSAlert, language: RenderLanguage, scale: CGFloat = 1.5) -> [Data] {
        RenderBundle.language = language.rawValue
        if let icon = RenderBundle.appBundle?.image(forResource: "AppIcon") { alert.icon = icon }
        alert.layout()
        guard let view = alert.window.contentView else { return [] }
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        return snapshot(view, scale: scale, trim: false, maxPixelHeight: 1600)
    }

    private static func snapshot(_ view: NSView, scale: CGFloat, trim: Bool, maxPixelHeight: Int) -> [Data] {
        let bounds = view.bounds
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard var image = rep.cgImage else { return [] }
        if trim, let trimmed = trimBottom(image) { image = trimmed }
        var parts: [Data] = []
        var y = 0
        while y < image.height {
            let height = min(maxPixelHeight, image.height - y)
            guard let slice = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else { break }
            let out = NSBitmapImageRep(cgImage: slice)
            if let png = out.representation(using: .png, properties: [:]) { parts.append(png) }
            y += height
        }
        return parts
    }

    /// Schneidet oben und unten alle Zeilen ab, die nur die Farbe der obersten bzw. untersten Zeile haben (Rand 24 px).
    private static func trimBottom(_ image: CGImage) -> CGImage? {
        let rep = NSBitmapImageRep(cgImage: image)
        func uniform(_ y: Int, _ color: NSColor?) -> Bool {
            stride(from: 0, to: image.width, by: 3).allSatisfy { rep.colorAt(x: $0, y: y) == color }
        }
        let bottom = rep.colorAt(x: 4, y: image.height - 1)
        var last = image.height - 1
        while last > 0, uniform(last, bottom) { last -= 1 }
        let top = rep.colorAt(x: 4, y: 0)
        var first = 0
        while first < last, uniform(first, top) { first += 1 }
        let y0 = max(0, first - 24)
        let y1 = min(image.height, last + 1 + 24)
        return image.cropping(to: CGRect(x: 0, y: y0, width: image.width, height: y1 - y0))
    }
}

/// Beispielzustand für eine Ansicht: Server-Status wie aus `GET /api/setup`, Rechte, Kopplung „Dieser Mac“.
struct Fixture {
    var role = "server"
    var setupDone = false
    var phase: ServerManager.Phase = .running
    var linked = true
    var pending = false
    var keys: Set<String> = []
    var claudeAbo = false
    var claudeLimit = false
    var openaiLoggedInNoAbo = false
    var openaiMode = "api"
    var publicURL = ""
    var lanURL = ""
    var ownScoops = 0
    var thisMac = false
    var screen = true
    var accessibility = true
    var fullDisk = true
    var tailscale = true
    var tailscaleEntries: [Tailscale.ServeEntry] = []
    var workspaceICloud = false
    var workspaceError: String?
    var cloudError: String?
    var portConflict: ServerManager.PortOccupant?
    var lastError: String?
    var paired = false
    var linkState: AppModel.LinkState = .connected
    var paused = false
    var botName: String?
    var apple: [AppleService: String] = [.reminders: "granted", .calendar: "granted", .contacts: "not_determined"]
    var lastApple: String?
    var nodeName = "Lenas Mac mini"
    var pendingUpdate: String?
    /// Sprache des Inhabers auf dem Server (`server.language`) und was der Server kann (`server.languages`, nil = alt)
    var storedLanguage: String?
    var serverLanguages: [String]?
    /// Mitgeliefertes Python „vorhanden“ (zeigt z. B. den Link „Nur als Rechner …“); gestartet wird nie etwas.
    var serverAvailable = false

    static let suiteName = "com.ais.scoopsconnect.rendertests"

    @MainActor
    func makeController() -> ServerController {
        AppModel.previewName = "Lenas Mac mini"
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults.set(role, forKey: "role")
        defaults.set(setupDone, forKey: "serverSetupDone")
        defaults.set(nodeName, forKey: "nodeName")
        defaults.set(false, forKey: "keepDisplayAwake")
        defaults.set(true, forKey: "keepSystemAwake")

        var setup = ServerManager.Setup(home: FileManager.default.temporaryDirectory.appending(path: "ais-render"),
                                        python: serverAvailable ? URL(fileURLWithPath: "/usr/bin/true") : nil, sourcePath: nil)
        setup.keychainPrefix = "ais-scoops-render"
        setup.offline = true
        let manager = ServerManager(setup: setup)
        manager.applyPreview(phase: phase, port: 8787, status: status(), portConflict: portConflict, lastError: lastError)
        let model = AppModel(defaults: defaults)
        if paired || thisMac {
            model.applyPreview(paired: true, linkState: linkState,
                               serverURL: role == "server" ? "http://127.0.0.1:8787" : "https://lenas-mac-mini.tail1234.ts.net",
                               nodeID: "n_7f3a9c", paused: paused, botName: botName, apple: apple, lastApple: lastApple)
        } else {
            model.applyPreview(paired: false, linkState: .unpaired, apple: apple, lastApple: lastApple)
        }
        let controller = ServerController(model: model, manager: manager, defaults: defaults, test: false)
        controller.previewThisMac = thisMac
        controller.previewTailscale = tailscale
            ? Tailscale.Info(cli: "/Applications/Tailscale.app/Contents/MacOS/Tailscale", running: true,
                             dnsName: "lenas-mac-mini.tail1234.ts.net")
            : nil
        controller.previewTailscaleEntries = tailscaleEntries
        Permissions.previewOverride = (screen, accessibility)
        AppUpdater.shared.pendingVersion = pendingUpdate
        return controller
    }

    private func status() -> JSONValue? {
        let iso = ISO8601DateFormatter()
        var claude: [String: Any] = ["installed": true, "logged_in": false, "subscription": false, "mode": "api"]
        var openai: [String: Any] = ["installed": true, "logged_in": false, "subscription": false, "mode": openaiMode]
        if claudeAbo {
            claude = ["installed": true, "logged_in": true, "subscription": true, "plan": "max", "mode": "abo_api",
                      "usage": ["utilization": 0.18, "window": "five_hour"]]
            if claudeLimit {
                claude["limit"] = ["until": "2026-11-19T17:30:00Z"]
            }
        }
        if openaiLoggedInNoAbo {
            openai["logged_in"] = true
        }
        var workspace: [String: Any] = ["path": "~/Documents/Scoops", "absolute": "/tmp/ais-render/Scoops",
                                        "icloud": workspaceICloud,
                                        "previous": [["path": "~/Desktop/Scoops", "folders": ["Kiwi", "Pip"]]]]
        if let workspaceError { workspace["error"] = workspaceError }
        var server: [String: Any] = [
            "edition": "standard", "port": 8787, "user_name": "Lena",
            "owner_name": linked ? "Lena Berger" as Any : NSNull(),
            "server_name": "Lenas Mac mini", "public_url": publicURL, "tailnet_url": "", "lan_url": lanURL,
            "keys": ["anthropic": keys.contains("anthropic"), "openai": keys.contains("openai"),
                     "composio": keys.contains("composio")],
            "bots": 1 + ownScoops, "active_runs": 0,
            "own_scoops": ["count": ownScoops, "newest": ownScoops > 0 ? "Kiwi" as Any : NSNull()],
            "nodes": thisMac ? [["id": "n_7f3a9c"]] : [],
            "full_disk_access": ["granted": fullDisk, "process": "AIS Scoops Server"],
            "abos": ["claude": claude, "openai": openai],
            "workspace": workspace,
        ]
        server["default_model"] = "claude-sonnet"
        if let serverLanguages {
            server["languages"] = serverLanguages
            server["language"] = storedLanguage as Any? ?? NSNull()
        }
        var body: [String: Any] = ["version": "1.33.0", "linked": linked, "server": server,
                                   "push": ["enabled": linked, "mode": linked ? "relay" as Any : NSNull()]]
        if let cloudError { body["last_error"] = cloudError }
        if pending {
            let exp = Date().addingTimeInterval(9 * 60 + 12.5)
            body["pending"] = ["code": "K7QX-29PL", "expires_at": iso.string(from: exp), "ttl_seconds": 552]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return JSONValue.decode(data)
    }
}
