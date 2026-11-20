import Foundation

// MARK: - Stummschalten, Ruhezeiten und Scoop-Vorlagen (App 1.3)
//
// Eigene Protokolle statt neuer Pflichten in `BotService`: Dienste ohne diese Funktionen (ältere Server antworten
// mit 404) bleiben unverändert, und die App fragt mit `as? RuheService` bzw. `as? TemplateService`.

/// Stummschalten (pro Chat) und Ruhezeiten (pro Person), docs/ruhe.md.
protocol RuheService: AnyObject {
    /// `PUT /api/chats/{id}/mute`: `mute.muted == false` hebt auf, `until == nil` heißt dauerhaft
    func setMute(chatID: String, mute: ChatMute) async throws -> ChatMute
    func quietHours() async throws -> QuietHours
    func updateQuietHours(_ value: QuietHours) async throws -> QuietHours
}

/// Scoop-Vorlagen exportieren und importieren (nur eigener Server), docs/vorlagen.md.
protocol TemplateService: AnyObject {
    func exportTemplate(botID: String) async throws -> TemplateExport
    /// Prüft die Datei, ohne etwas anzulegen (`data` = unveränderter Inhalt der Datei)
    func checkTemplate(_ data: Data) async throws -> TemplateCheck
    func importTemplate(_ request: TemplateImportRequest) async throws -> TemplateImportResult
}

extension APIClient: RuheService {
    private struct MuteBody: Encodable {
        var forever: Bool?
        var until: Date?
    }

    private struct MuteResponse: Decodable {
        var mute: ChatMute
    }

    func setMute(chatID: String, mute: ChatMute) async throws -> ChatMute {
        let body = mute.muted ? MuteBody(forever: mute.until == nil ? true : nil, until: mute.until) : MuteBody()
        return try await call("PUT", "/api/chats/\(chatID)/mute", body: body, as: MuteResponse.self).mute
    }

    func quietHours() async throws -> QuietHours {
        try await call("GET", "/api/settings/quiet-hours", as: QuietHours.self)
    }

    func updateQuietHours(_ value: QuietHours) async throws -> QuietHours {
        try await call("PATCH", "/api/settings/quiet-hours", body: value, as: QuietHours.self)
    }
}

extension APIClient: TemplateService {
    func exportTemplate(botID: String) async throws -> TemplateExport {
        try await call("GET", "/api/bots/\(botID)/template", as: TemplateExport.self)
    }

    func checkTemplate(_ data: Data) async throws -> TemplateCheck {
        try await call("POST", "/api/templates/check", rawBody: data, as: TemplateCheck.self)
    }

    func importTemplate(_ request: TemplateImportRequest) async throws -> TemplateImportResult {
        try await call("POST", "/api/templates/import", body: request, as: TemplateImportResult.self)
    }
}
