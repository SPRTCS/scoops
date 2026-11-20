import Foundation
import Security

/// API-Schlüssel im Anmelde-Schlüsselbund des Nutzers, so abgelegt, wie der Python-Server sie liest
/// (`security find-generic-password -s <präfix>-anthropic -a api-key -w`).
///
/// Geschrieben wird über `/usr/bin/security` selbst (Befehl über die Standardeingabe, nie als Argument), damit
/// `security` als Ersteller ohne Rückfrage-Dialog lesen darf. Werte werden nie geloggt oder angezeigt.
nonisolated enum SecretStore {
    enum Kind: String, CaseIterable, Sendable {
        case anthropic, openai, composio

        var title: String {
            switch self {
            case .anthropic: "Anthropic (Claude)"
            case .openai: String(localized: "OpenAI (GPT, Diktat)")
            case .composio: String(localized: "Composio (Gmail, Kalender, Notion …)")
            }
        }

        /// Bezeichnung des Schlüsselbund-Eintrags: bewusst fest (unabhängig von der Sprache der App), damit derselbe
        /// Eintrag nicht je nach Sprache anders heißt. Gelesen wird über Dienst und Konto, nie über die Bezeichnung.
        var keychainLabel: String {
            switch self {
            case .anthropic: "Anthropic (Claude)"
            case .openai: "OpenAI (GPT, Diktat)"
            case .composio: "Composio (Gmail, Kalender, Notion …)"
            }
        }
    }

    static func service(_ kind: Kind, prefix: String) -> String { "\(prefix)-\(kind.rawValue)" }
    static let account = "api-key"

    /// Nur Zeichen, die in API-Schlüsseln vorkommen – schützt die `security -i`-Befehlszeile vor Einschleusungen.
    static func isPlausible(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...400).contains(v.count) else { return false }
        return v.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }
            && v.allSatisfy(\.isASCII)
    }

    /// Ist ein Eintrag vorhanden? (Liest nur Attribute, nie den Wert – kein Dialog.)
    static func exists(_ kind: Kind, prefix: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(kind, prefix: prefix),
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func save(_ kind: Kind, value: String, prefix: String) async throws {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausible(v) else { throw SaveError.implausible }
        let label = "AIS Scoops – \(kind.keychainLabel)"
        let cmd = "add-generic-password -U -s \"\(service(kind, prefix: prefix))\" -a \"\(account)\" -l \"\(label)\" -w \"\(v)\"\n"
        let r = await runSecurity(stdin: cmd)
        guard r == 0, exists(kind, prefix: prefix) else { throw SaveError.keychain }
    }

    static func delete(_ kind: Kind, prefix: String) async {
        _ = await runSecurity(stdin: "delete-generic-password -s \"\(service(kind, prefix: prefix))\" -a \"\(account)\"\n")
    }

    enum SaveError: LocalizedError {
        case implausible, keychain
        var errorDescription: String? {
            switch self {
            case .implausible: String(localized: "Das sieht nicht wie ein API-Schlüssel aus.")
            case .keychain: String(localized: "Der Schlüssel konnte nicht im Schlüsselbund gespeichert werden.")
            }
        }
    }

    private static func runSecurity(stdin text: String) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["-q", "-i"]
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try p.run()
                pipe.fileHandleForWriting.write(Data(text.utf8))  // Ende der Eingabe beendet `security -i`
                try? pipe.fileHandleForWriting.close()
            } catch {
                cont.resume(returning: -1)
            }
        }
    }
}

/// Prüft API-Schlüssel mit einem harmlosen Lese-Aufruf (Modell- bzw. Toolkit-Liste). Nichts kostet Geld.
nonisolated enum KeyCheck {
    enum Result: Equatable, Sendable {
        case valid
        case invalid(String)
        case unknown(String)
    }

    static func check(_ kind: SecretStore.Kind, key: String) async -> Result {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var req: URLRequest
        switch kind {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            req.setValue(k, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        case .composio:
            req = URLRequest(url: URL(string: "https://backend.composio.dev/api/v3/toolkits?limit=1")!)
            req.setValue(k, forHTTPHeaderField: "x-api-key")
        }
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return result(status: code)
        } catch {
            return .unknown(Self.offlineMessage)
        }
    }

    /// Ergebnis zu einem HTTP-Status des Anbieters (eigene Funktion für Tests und Renderings)
    static func result(status code: Int) -> Result {
        switch code {
        case 200..<300: .valid
        case 401, 403: .invalid(String(localized: "Der Schlüssel wurde abgelehnt. Bitte prüfen und neu einfügen."))
        default: .unknown(String(localized: "Prüfung nicht eindeutig (Fehler \(String(code))). Du kannst ihn trotzdem speichern."))
        }
    }

    static var offlineMessage: String {
        String(localized: "Keine Internetverbindung zur Prüfung. Du kannst ihn trotzdem speichern.")
    }
}
