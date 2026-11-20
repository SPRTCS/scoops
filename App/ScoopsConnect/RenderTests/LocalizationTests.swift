import Foundation
import Testing

/// Sprachen der Server-App (docs/sprache-serverapp.md): String Catalogs vollständig, Deutsch Zeichen für Zeichen wie
/// vor der Umstellung, Englisch mit Mehrzahl und ohne Tausendertrennzeichen in Ports und Codes.
@MainActor
@Suite("Sprachen der Server-App", .serialized)
struct LocalizationTests {
    init() {
        RenderBundle.install(source: Bundle(for: RenderBundleToken.self))
    }

    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources")

    private static func catalog(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: resources.appending(path: name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Alle Zustände eines Eintrags (auch in Mehrzahl-Varianten)
    private static func units(_ loc: Any?) -> [[String: Any]] {
        guard let loc = loc as? [String: Any] else { return [] }
        if let unit = loc["stringUnit"] as? [String: Any] { return [unit] }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            return plural.values.flatMap { units($0) }
        }
        return []
    }

    private static func placeholders(_ s: String) -> [String] {
        let re = /%(?:\d+\$)?(lld|ld|d|@|f)/
        return s.matches(of: re).map { String($0.output.1) }.sorted()
    }

    @Test("Jeder Eintrag hat Englisch, keiner ist neu, veraltet oder zu prüfen", arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func catalogComplete(file: String) throws {
        let cat = try Self.catalog(file)
        #expect(cat["sourceLanguage"] as? String == "de")
        let strings = try #require(cat["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            #expect(entry["extractionState"] as? String != "stale", "veraltet: \(key)")
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            let en = Self.units(locs["en"])
            #expect(!en.isEmpty, "ohne Englisch: \(key)")
            for unit in en + Self.units(locs["de"]) {
                #expect(unit["state"] as? String == "translated", "Zustand \(unit["state"] ?? "-"): \(key)")
            }
            if file == "Localizable.xcstrings" {
                for unit in en {
                    let value = unit["value"] as? String ?? ""
                    #expect(Self.placeholders(value) == Self.placeholders(key), "Platzhalter: \(key) → \(value)")
                }
            }
        }
    }

    @Test("Info.plist-Texte: jeder Berechtigungstext der App steht im Catalog")
    func infoPlistCovered() throws {
        let info = try #require(NSDictionary(contentsOf: Self.resources.deletingLastPathComponent().appending(path: "Info.plist")))
        let strings = try #require(try Self.catalog("InfoPlist.xcstrings")["strings"] as? [String: Any])
        for case let key as String in info.allKeys where key.hasSuffix("UsageDescription") {
            #expect(strings[key] != nil, "fehlt in InfoPlist.xcstrings: \(key)")
        }
    }

    private func inLanguage<T>(_ lang: String, _ body: () throws -> T) rethrows -> T {
        let old = RenderBundle.language
        RenderBundle.language = lang
        defer { RenderBundle.language = old }
        return try body()
    }

    @Test("Deutsch: umgebaute Sätze sind Zeichen für Zeichen wie vorher")
    func germanUnchanged() {
        inLanguage("de") {
            #expect(ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: 4242, name: "python3", path: "/opt/homebrew/bin/python3",
                                               isOldAISBot: false).summary
                    == "Port 8787 ist belegt durch „python3“ (PID 4242), /opt/homebrew/bin/python3. Der Server läuft deshalb auf Port 8788.")
            #expect(ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: 4242, name: "", path: nil, isOldAISBot: false).summary
                    == "Port 8787 ist belegt durch „unbekannt“ (PID 4242). Der Server läuft deshalb auf Port 8788.")
            #expect(ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: nil, name: "", path: nil, isOldAISBot: false).summary
                    == "Port 8787 ist belegt durch ein anderes Programm. Der Server läuft deshalb auf Port 8788.")
            let server = URL(string: "http://127.0.0.1:8787")
            #expect(AppModel.describe(URLError(.cannotConnectToHost), server: server) == "Verbindung abgelehnt (Port 8787) – dort läuft kein Server")
            #expect(AppModel.describe(URLError(.cannotConnectToHost), server: URL(string: "https://x.example"))
                    == "Verbindung abgelehnt – dort läuft kein Server")
            #expect(AppModel.describe(URLError(.timedOut), server: server) == "Zeitüberschreitung bei 127.0.0.1 (Port 8787)")
            #expect(AppModel.describe(URLError(.badServerResponse), server: server) == "Unerwartete Antwort vom Server (Port 8787)")
            #expect(Pairing.Failure.server(1234).localizedDescription == "Der Server hat mit Fehler 1234 geantwortet.")
            #expect(KeyCheck.result(status: 500) == .unknown("Prüfung nicht eindeutig (Fehler 500). Du kannst ihn trotzdem speichern."))
            #expect(Tailscale.explain("", status: 1, timedOut: false, publicly: false).message == "Tailscale-Fehler 1")

            let c = Fixture(keys: ["anthropic", "openai"], claudeAbo: true).makeController()
            #expect(c.accessSummary == "Claude-Abo (Max) · API-Schlüssel von Anthropic und OpenAI")
            #expect(Fixture(keys: ["openai"]).makeController().accessSummary == "API-Schlüssel von OpenAI")
            #expect(SetupStep.keys.title == "KI-Zugang")
            #expect(AppLanguage.acceptLanguage == "de")
        }
    }

    @Test("Englisch: Sätze, Aufzählung, keine Tausendertrennzeichen")
    func english() {
        inLanguage("en") {
            #expect(ServerManager.PortOccupant(port: 8787, newPort: 8788, pid: 4242, name: "python3", path: "/opt/homebrew/bin/python3",
                                               isOldAISBot: false).summary
                    == "Port 8787 is in use by “python3” (PID 4242), /opt/homebrew/bin/python3, so the server is running on port 8788.")
            #expect(AppModel.describe(URLError(.cannotConnectToHost), server: URL(string: "http://127.0.0.1:8787"))
                    == "Connection refused (port 8787). No server is running there.")
            #expect(Pairing.Failure.server(1234).localizedDescription == "The server responded with error 1234.")
            let c = Fixture(keys: ["anthropic", "openai"], claudeAbo: true).makeController()
            #expect(c.accessSummary == "Claude subscription (Max) · API key from Anthropic and OpenAI")
            #expect(SetupStep.keys.title == "AI Access")
            #expect(AppModel.Mode.direct.short == "Direct")
            #expect(AppLanguage.acceptLanguage == "en, de;q=0.5")
        }
    }

    @Test("Mehrzahl in beiden Sprachen (Catalog des Test-Bundles, ohne Umleitung)")
    func plurals() throws {
        let source = Bundle(for: RenderBundleToken.self)
        func text(_ key: String, _ lang: String, _ n: Int) throws -> String {
            let path = try #require(source.path(forResource: lang, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            return String.localizedStringWithFormat(bundle.localizedString(forKey: key, value: nil, table: nil), n)
        }
        let own = "Du hast schon %lld eigene Scoops."
        #expect(try text(own, "en", 1) == "You already have 1 Scoop of your own.")
        #expect(try text(own, "en", 3) == "You already have 3 Scoops of your own.")
        #expect(try text(own, "de", 3) == "Du hast schon 3 eigene Scoops.")
        let merged = "%lld alte(r) Eintrag/Einträge dieses Macs zusammengeführt"
        #expect(try text(merged, "en", 1) == "Merged 1 old entry for this Mac")
        #expect(try text(merged, "en", 2) == "Merged 2 old entries for this Mac")
        #expect(try text(merged, "de", 2) == "2 alte(r) Eintrag/Einträge dieses Macs zusammengeführt")
    }

    @Test("Sprache des Inhabers: nur setzen, wenn noch keine gespeichert ist und der Server sie kann")
    func ownerLanguage() {
        func adopt(_ lang: String, stored: String?, languages: [String]?) -> String? {
            var f = Fixture()
            f.storedLanguage = stored
            f.serverLanguages = languages
            return inLanguage(lang) { f.makeController().manager.languageToAdopt }
        }
        #expect(adopt("en", stored: nil, languages: ["de", "en"]) == "en")
        #expect(adopt("en", stored: "de", languages: ["de", "en"]) == nil)   // schon gesetzt (z. B. vom iPhone)
        #expect(adopt("en", stored: nil, languages: nil) == nil)             // Server vor 1.3
        #expect(adopt("de", stored: nil, languages: ["de", "en"]) == nil)    // Deutsch ist Standard: keine Anfrage
    }

    @Test("Anfragen an den eigenen Server tragen die Sprache der App")
    func acceptLanguageHeader() throws {
        let c = Fixture().makeController()
        let de = try inLanguage("de") { try c.manager.urlRequest("GET", "api/setup") }
        let en = try inLanguage("en") { try c.manager.urlRequest("PATCH", "api/setup/config", body: ["x": 1]) }
        #expect(de.value(forHTTPHeaderField: "Accept-Language") == "de")
        #expect(en.value(forHTTPHeaderField: "Accept-Language") == "en, de;q=0.5")
        #expect(en.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}
