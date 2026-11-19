import Foundation

/// Geteilte Scoops im Konto-Dienst (docs/sharing.md): Einladungen und Personen (Admin), „Mit mir geteilt“ (Gast).
/// Inhalte laufen nie über Convex – hier geht es nur um das Verzeichnis.
extension AccountStore {
    // MARK: Gast

    /// „Mit mir geteilt“ laden. Gibt `true` zurück, wenn sich die Liste geändert hat.
    @discardableResult
    func loadSharedWithMe() async -> Bool {
        guard isSignedIn else { return false }
        do {
            let list = try await authorized { try await service.sharedWithMe(token: $0) }
            sharedLoaded = true
            guard list != sharedWithMe else { return false }
            sharedWithMe = list
            return true
        } catch {
            #if DEBUG
            print("[Teilen] shares:mine fehlgeschlagen: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Vorschau einer Einladung, auch ohne Anmeldung.
    func inviteInfo(code: String) async throws -> InviteInfo {
        let token = isSignedIn ? (try? await validToken()) : nil
        return try await service.inviteInfo(code: code, token: token)
    }

    /// Einladung annehmen; danach steht der Scoop in `sharedWithMe`.
    func acceptInvite(code: String) async throws -> AcceptResult {
        let result = try await authorized { try await service.acceptInvite(code: code, token: $0) }
        guard result.ok else {
            let text: String
            switch result.error {
            case "expired": text = "Diese Einladung ist abgelaufen. Bitte frag nach einem neuen Link."
            case "used": text = "Diese Einladung wurde schon angenommen. Jeder Link gilt nur einmal."
            case "own", "self", "owner", "own_scoop": text = "Das ist dein eigener Scoop – du bist hier schon Admin."
            case "rate_limited": text = "Zu viele Versuche. Bitte warte ein paar Minuten."
            default: text = "Diese Einladung ist ungültig."
            }
            throw CloudError(status: 400, message: result.message ?? text)
        }
        await loadSharedWithMe()
        return result
    }

    /// Selbst austreten.
    func leave(_ share: SharedScoop) async throws {
        try await authorized { try await service.leaveShare(id: share.id, token: $0) }
        sharedWithMe.removeAll { $0.id == share.id }
    }

    // MARK: Admin

    func createInvite(_ request: InviteRequest) async throws -> InviteCreated {
        try await authorized { try await service.createInvite(request, token: $0) }
    }

    func shareList(serverID: String, botID: String) async throws -> BotShareList {
        try await authorized { try await service.listShares(serverID: serverID, botID: botID, token: $0) }
    }

    func updateShare(id: String, role: ShareRole? = nil, computer: ComputerAccess? = nil) async throws {
        try await authorized { try await service.updateShare(id: id, role: role, computer: computer, token: $0) }
    }

    func removeShare(id: String) async throws {
        try await authorized { try await service.removeShare(id: id, token: $0) }
    }

    func revokeInvite(id: String) async throws {
        try await authorized { try await service.revokeInvite(id: id, token: $0) }
    }
}
