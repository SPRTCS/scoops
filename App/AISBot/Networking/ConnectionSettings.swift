import Foundation
import Security

/// Server-Adresse (UserDefaults) und Token (Schlüsselbund).
///
/// Zwei Wege: `token` (bisherige Kopplung per API-Token, „Manuell verbinden“) oder `cloudServerID`
/// (Server aus „Deine Server“, Anmeldung mit dem Sitzungs-JWT des Kontos statt eines Tokens).
struct ConnectionSettings: Equatable {
    var serverURL: String
    var token: String
    /// Server aus dem Konto (Convex-ID); nil = Verbindung per API-Token
    var cloudServerID: String?
    /// Anzeigename des Konto-Servers
    var cloudServerName: String?

    static let mockURL = "mock://"

    init(serverURL: String, token: String, cloudServerID: String? = nil, cloudServerName: String? = nil) {
        self.serverURL = serverURL
        self.token = token
        self.cloudServerID = cloudServerID
        self.cloudServerName = cloudServerName
    }

    /// Verbindung über das Konto (Sitzungs-JWT)
    var usesAccount: Bool { cloudServerID != nil }
    var isMock: Bool { serverURL.lowercased().hasPrefix("mock://") }
    var isConfigured: Bool {
        isMock || (!serverURL.isEmpty && (usesAccount || !token.isEmpty) && baseURL != nil)
    }

    /// Normalisierte Basis-URL ohne abschließenden Schrägstrich.
    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    /// Vorschlag im Feld „Manuell verbinden“: auf dem Mac der lokale Server, auf iPhone/iPad leer (Platzhalter
    /// „https://…ts.net“). Keine feste Tailnet-Adresse im Store-Build – fremde Nutzer und die App-Prüfung sehen sie sonst.
    static var suggestedURL: String {
        #if os(macOS)
        "http://127.0.0.1:8787"
        #else
        ""
        #endif
    }

    private static let urlKey = "serverURL"
    private static let cloudServerKey = "cloudServerID"
    private static let cloudServerNameKey = "cloudServerName"

    static func load() -> ConnectionSettings {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: urlKey) ?? ""
        let token = Keychain.read(account: "token") ?? ""
        return ConnectionSettings(serverURL: url, token: token,
                                  cloudServerID: defaults.string(forKey: cloudServerKey),
                                  cloudServerName: defaults.string(forKey: cloudServerNameKey))
    }

    /// Speichert Adresse und Weg. Der API-Token bleibt bei einer Konto-Verbindung im Schlüsselbund liegen,
    /// damit „Manuell verbinden“ ihn später wieder vorschlägt.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: Self.urlKey)
        if let cloudServerID {
            defaults.set(cloudServerID, forKey: Self.cloudServerKey)
            defaults.set(cloudServerName, forKey: Self.cloudServerNameKey)
        } else {
            defaults.removeObject(forKey: Self.cloudServerKey)
            defaults.removeObject(forKey: Self.cloudServerNameKey)
            if token.isEmpty {
                Keychain.delete(account: "token")
            } else {
                Keychain.write(token, account: "token")
            }
        }
    }

    /// Trennen: Adresse und Konto-Server vergessen. `keepToken` lässt den API-Token liegen (Konto-Verbindung).
    static func clear(keepToken: Bool = false) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: urlKey)
        defaults.removeObject(forKey: cloudServerKey)
        defaults.removeObject(forKey: cloudServerNameKey)
        if !keepToken { Keychain.delete(account: "token") }
    }

    /// Zuletzt gespeicherter API-Token (Vorschlag für „Manuell verbinden“)
    static var storedToken: String { Keychain.read(account: "token") ?? "" }

    /// Wertet `aisbot://pair?url=…&token=…` aus.
    static func fromPairingURL(_ url: URL) -> ConnectionSettings? {
        guard url.scheme?.lowercased() == "aisbot", url.host()?.lowercased() == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        guard let server = items.first(where: { $0.name == "url" })?.value, !server.isEmpty else { return nil }
        let token = items.first(where: { $0.name == "token" })?.value ?? ""
        return ConnectionSettings(serverURL: server, token: token)
    }
}

/// Minimaler Schlüsselbund-Zugriff (generisches Passwort). Die Einträge liegen in der gemeinsamen Zugriffsgruppe
/// für App und Teilen-Erweiterung (`SharedKeychain`, docs/system.md); Einträge älterer Versionen werden weiter
/// gefunden und beim Start umgezogen.
enum Keychain {
    static func read(account: String) -> String? { SharedKeychain.read(account: account) }

    static func write(_ value: String, account: String) { SharedKeychain.write(value, account: account) }

    static func delete(account: String) { SharedKeychain.delete(account: account) }
}
