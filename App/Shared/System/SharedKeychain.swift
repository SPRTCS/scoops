import Foundation
import Security

/// Schlüsselbund für App und Erweiterungen (Teilen-Menü, Kurzbefehle).
///
/// Zugangsdaten liegen weiter nur im Schlüsselbund, nie im Klartext in der App-Gruppe. Auf iPhone und iPad
/// stehen sie in einer eigenen Zugriffsgruppe (`keychain-access-groups`), die nur die App und die
/// Teilen-Erweiterung in ihren Entitlements tragen. Die übrigen Erweiterungen (Widgets, Mitteilungen) kommen
/// nicht heran.
///
/// Auf dem Mac bleibt alles beim bisherigen Schlüsselbund der App: Eine Zugriffsgruppe verlangt dort ein
/// Provisioning-Profil für jedes Target. Die Mac-Erweiterung braucht keine Zugangsdaten, sie reicht geteilte
/// Inhalte an die App weiter (`ShareOutbox`).
///
/// Werte werden nie protokolliert.
nonisolated enum SharedKeychain {
    static let service = "com.ais.aisbot"
    /// API-Token des manuell verbundenen Servers
    static let tokenAccount = "token"
    /// Sitzung des Kontos (JSON von `CloudCredentials`)
    static let sessionAccount = "cloud-session"

    #if os(iOS)
    /// `$(AppIdentifierPrefix)com.ais.aisbot.shared` aus den Entitlements. Das Präfix (Team, mit Punkt) steht in der
    /// Info.plist von App und Teilen-Erweiterung (`AppIdentifierPrefix`, beim Bauen eingesetzt), damit ein Build mit
    /// einem anderen Team seine eigene Gruppe findet. Fehlt der Eintrag, gilt das Team dieses Projekts wie bisher.
    static let accessGroup: String? = prefix.value + "com.ais.aisbot.shared"
    #else
    static let accessGroup: String? = nil
    #endif

    /// Team des Projekts (wie bei der Mac-App-Gruppe `MYXQKK3T2Z.com.ais.aisbot`): Rückfall ohne Info.plist-Eintrag
    static let fallbackPrefix = "MYXQKK3T2Z."

    /// Präfix der Zugriffsgruppe und woher es stammt (`Info.plist` oder Rückfall)
    static let prefix: (value: String, fromInfoPlist: Bool) = resolvePrefix(
        Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)

    /// Nimmt das Präfix aus der Info.plist, wenn es nach einer Team-ID aussieht (eingesetzt, nicht leer, endet mit
    /// Punkt); sonst den Rückfall. Getrennt, damit Tests es ohne Bundle prüfen können.
    static func resolvePrefix(_ raw: String?) -> (value: String, fromInfoPlist: Bool) {
        let v = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let ok = v.count > 1 && v.hasSuffix(".") && !v.contains("$") && !v.contains("(")
            && v.dropLast().allSatisfy { $0.isLetter || $0.isNumber }
        return ok ? (v, true) : (fallbackPrefix, false)
    }

    private static func query(account: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func data(account: String, group: String?) -> Data? {
        var q = query(account: account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Liest zuerst aus der gemeinsamen Gruppe, sonst aus jeder Gruppe, die dieser Prozess sehen darf
    /// (Einträge älterer App-Versionen, bis `migrate` sie umgezogen hat).
    static func read(account: String) -> String? {
        if let group = accessGroup, let data = data(account: account, group: group) {
            return String(data: data, encoding: .utf8)
        }
        return data(account: account, group: nil).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Schreibt in die gemeinsame Gruppe. Fehlt das Entitlement (z. B. unsignierter Testlauf), landet der Wert wie
    /// bisher im Schlüsselbund der App: Die Anmeldung bleibt erhalten, nur die Erweiterungen sehen ihn dann nicht.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        if let group = accessGroup, store(data, account: account, group: group) {
            // Kopie einer älteren App-Version entfernen, damit es nur eine Wahrheit gibt
            removeLegacyCopies(account: account)
            return true
        }
        return store(data, account: account, group: nil)
    }

    private static func store(_ data: Data, account: String, group: String?) -> Bool {
        let q = query(account: account, group: group)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        // Ohne Gruppe: löscht den Eintrag in allen sichtbaren Gruppen
        SecItemDelete(query(account: account, group: nil) as CFDictionary)
    }

    /// Zugriffsgruppen, in denen es einen Eintrag gibt
    private static func groups(account: String) -> [String] {
        var q = query(account: account, group: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccessGroup as String] as? String }
    }

    private static func removeLegacyCopies(account: String) {
        guard let shared = accessGroup else { return }
        for group in groups(account: account) where group != shared {
            SecItemDelete(query(account: account, group: group) as CFDictionary)
        }
    }

    #if DEBUG
    /// Nur Debug (`-keychainselftest`): spielt den Umzug mit einem eigenen Konto durch, so wie ihn ein Gerät mit einer
    /// älteren Version erlebt. Echte Zugangsdaten bleiben unberührt. Liefert eine Zeile für die Konsole (ohne Werte).
    ///
    /// Fälle: (1) alter Eintrag in der Standardgruppe der App ist vor dem Umzug lesbar (Update von 1.2, Token- und
    /// Konto-Weg nutzen denselben Pfad); (2) Umzug in die gemeinsame Gruppe, Wert und Zugriffsklasse „nach dem ersten
    /// Entsperren“ bleiben (Hintergrundstart durch Push); (3) zweiter Umzug ändert nichts; (4) liegen alte und neue
    /// Kopie, gewinnt die neue; (5) Schreiben räumt eine alte Kopie weg; (6) Löschen (Abmelden) entfernt alles.
    static func selfTest() -> String {
        guard let shared = accessGroup else { return "Schlüsselbund-Test: auf diesem System ohne gemeinsame Gruppe" }
        let account = "selftest"
        // Standardgruppe älterer Versionen: Team-Präfix + Bundle-ID der App (application-identifier)
        let legacy = prefix.value + (Bundle.main.bundleIdentifier ?? "com.ais.aisbot")
        func reset() { SecItemDelete(query(account: account, group: nil) as CFDictionary) }
        var failed: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failed.append(name) } }

        reset()
        let added = store(Data("alt".utf8), account: account, group: legacy)
        check(added && groups(account: account) == [legacy], "alt anlegen")
        check(read(account: account) == "alt", "(1) vor dem Umzug lesbar")
        migrate(accounts: [account])
        check(groups(account: account) == [shared], "(2) umgezogen")
        check(read(account: account) == "alt", "(2) Wert erhalten")
        check(accessibility(account: account, group: shared) == (kSecAttrAccessibleAfterFirstUnlock as String),
              "(2) lesbar nach dem ersten Entsperren")
        migrate(accounts: [account])
        check(groups(account: account) == [shared] && read(account: account) == "alt", "(3) zweiter Umzug ändert nichts")

        check(store(Data("neu".utf8), account: account, group: shared), "neu schreiben")
        check(store(Data("alt".utf8), account: account, group: legacy), "alte Kopie dazulegen")
        migrate(accounts: [account])
        check(groups(account: account) == [shared] && read(account: account) == "neu", "(4) neue Kopie gewinnt")

        check(store(Data("alt".utf8), account: account, group: legacy), "alte Kopie erneut")
        check(write("neuer", account: account), "(5) schreiben")
        check(groups(account: account) == [shared] && read(account: account) == "neuer", "(5) alte Kopie entfernt")

        delete(account: account)
        check(groups(account: account).isEmpty && read(account: account) == nil, "(6) Löschen entfernt alles")
        reset()
        let source = prefix.fromInfoPlist ? "Team-Präfix aus der Info.plist" : "Team-Präfix aus dem Rückfall"
        return failed.isEmpty
            ? "Schlüsselbund-Test: bestanden (6 Fälle, \(source))"
            : "Schlüsselbund-Test: FEHLGESCHLAGEN (\(source)): " + failed.joined(separator: ", ")
    }

    /// Zugriffsklasse eines Eintrags (`kSecAttrAccessible`)
    private static func accessibility(account: String, group: String) -> String? {
        var q = query(account: account, group: group)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }
    #endif

    /// Einmal beim Start der App: Einträge älterer Versionen (Standardgruppe der App) in die gemeinsame Gruppe
    /// umziehen, damit Erweiterungen ohne erneutes Anmelden funktionieren. Mehrfaches Aufrufen schadet nicht.
    /// Schlägt das Schreiben fehl, bleibt der alte Eintrag unverändert liegen.
    static func migrate(accounts: [String] = [tokenAccount, sessionAccount]) {
        guard let shared = accessGroup else { return }
        for account in accounts {
            let found = groups(account: account)
            guard found.contains(where: { $0 != shared }) else { continue }
            if found.contains(shared) {
                // Schon umgezogen (neuerer Stand), alte Kopie blieb zurück
                removeLegacyCopies(account: account)
                continue
            }
            guard let legacy = found.first, let value = data(account: account, group: legacy) else { continue }
            if store(value, account: account, group: shared) { removeLegacyCopies(account: account) }
        }
    }
}
