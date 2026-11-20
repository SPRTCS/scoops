import Foundation

/// Zugangsdaten für den eigenen Bot-Server: entweder der bisherige API-Token (Kopplung, „Manuell verbinden“)
/// oder das Sitzungs-JWT des Kontos (Server aus „Deine Server“). Beides geht als `Authorization: Bearer …`
/// bzw. `?token=…` (Bilder, WebSocket) an den Server; der Server prüft selbst, was es ist.
final class ServerAuth {
    enum Kind: Equatable { case token, account }

    let kind: Kind
    private let currentValue: () -> String
    private let validValue: () async throws -> String
    private let renewValue: () async -> Bool

    private init(kind: Kind, current: @escaping () -> String, valid: @escaping () async throws -> String,
                 renew: @escaping () async -> Bool) {
        self.kind = kind
        self.currentValue = current
        self.validValue = valid
        self.renewValue = renew
    }

    /// Fester API-Token
    static func token(_ token: String) -> ServerAuth {
        ServerAuth(kind: .token, current: { token }, valid: { token }, renew: { false })
    }

    /// Sitzungs-JWT des Kontos; wird bei Bedarf über den Konto-Dienst erneuert.
    static func account(_ account: AccountStore) -> ServerAuth {
        ServerAuth(kind: .account,
                   current: { [weak account] in account?.credentials?.token ?? "" },
                   valid: { [weak account] in
                       guard let account else { throw CloudError(status: 401, message: String(localized: "Nicht angemeldet")) }
                       return try await account.validToken()
                   },
                   renew: { [weak account] in await account?.forceRefresh() ?? false })
    }

    /// Aktueller Wert ohne Netz (für URLs mit `?token=`, z. B. Bilder und Bildschirm-Vorschau)
    var current: String { currentValue() }

    /// Gültiger Wert; erneuert ein bald ablaufendes JWT vorher.
    func valid() async throws -> String { try await validValue() }

    /// Nach einer 401-Antwort: JWT sofort erneuern. `true`, wenn ein neuer Versuch lohnt.
    func renewAfterUnauthorized() async -> Bool { await renewValue() }
}
