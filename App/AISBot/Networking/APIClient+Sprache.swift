import Foundation

// MARK: - Sprache (App 1.3, Vertrag in docs/sprache.md)
//
// Die App spricht Deutsch oder Englisch (`AppLanguage`). Jede Anfrage trägt `Accept-Language` (APIClient, EventSocket,
// Sprechmodus, Teilen-Erweiterung, Kurzbefehle, Uhr); damit kommen Fehlermeldungen, Hinweise und Kataloge schon in der
// richtigen Sprache. Was der Server im Hintergrund erzeugt (Ereignis- und Statuszeilen, Mitteilungen, Routinen,
// Antworten der Scoops), richtet sich nach der *gespeicherten* Sprache der Person. Die setzt die App beim Verbinden:
// Kann der Server die App-Sprache (`languages` in `/api/health` bzw. `/api/shared/me`) und weicht die gespeicherte
// Sprache ab, schickt sie `PATCH /api/settings/language`. Ältere Server ohne `languages`: nichts passiert, der Server
// bleibt bei Deutsch.

/// Antwort von `GET`/`PATCH /api/settings/language`.
nonisolated struct LanguageSettings: Codable, Sendable, Equatable {
    /// Wirksame Sprache dieser Anfrage (gespeichert, sonst `Accept-Language`, sonst „de“)
    var language: String
    /// Gespeicherte Sprache der Person oder `nil`
    var stored: String?
    var available: [String]?
}

/// Sprachfelder aus `/api/health` (Inhaber) bzw. `/api/shared/me` (Gast); fehlen bei Servern vor 1.3.
nonisolated struct ServerLanguageInfo: Decodable, Sendable {
    var languages: [String]?
    var language: String?
}

/// Sprache der Person auf dem Server lesen und setzen. Eigenes Protokoll wie `RuheService`: Demo und ältere Dienste
/// kennen es nicht, die App fragt mit `as? LanguageService`.
protocol LanguageService: AnyObject {
    /// Welche Sprachen der Server kann (`nil`: älterer Server ohne Sprachen)
    func serverLanguages() async throws -> [String]?
    func languageSettings() async throws -> LanguageSettings
    func setLanguage(_ code: String) async throws -> LanguageSettings
}

extension LanguageService {
    /// Setzt die Sprache der App als gespeicherte Sprache der Person, wenn der Server sie kann und sie abweicht.
    /// Gibt die gesetzte Sprache zurück, `nil` wenn nichts zu tun war. Fehler (offline, alter Server) schluckt die
    /// Funktion: Die Sprache ist eine Verbesserung, kein Muss.
    @discardableResult
    func adoptAppLanguage(_ code: String = AppLanguage.code) async -> String? {
        guard let languages = try? await serverLanguages(), languages.contains(code) else { return nil }
        guard let current = try? await languageSettings(), current.stored != code else { return nil }
        return (try? await setLanguage(code)).map { _ in code }
    }
}

extension APIClient: LanguageService {
    private struct LanguageBody: Encodable { var language: String }

    func serverLanguages() async throws -> [String]? {
        try await call("GET", "/api/health", as: ServerLanguageInfo.self).languages
    }

    func languageSettings() async throws -> LanguageSettings {
        try await call("GET", "/api/settings/language", as: LanguageSettings.self)
    }

    func setLanguage(_ code: String) async throws -> LanguageSettings {
        try await call("PATCH", "/api/settings/language", body: LanguageBody(language: code), as: LanguageSettings.self)
    }
}
