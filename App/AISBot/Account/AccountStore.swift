import AuthenticationServices
import CryptoKit
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Benutzerkonto (Phase 1, docs/accounts.md): „Mit Apple anmelden“, Sitzungs-JWT im Schlüsselbund,
/// automatisches Erneuern, Server-Verzeichnis und angemeldete Geräte.
///
/// Das Konto ist optional: Wer per API-Token verbunden ist, bleibt verbunden und kann sich später unter
/// Einstellungen → Konto anmelden.
@Observable
final class AccountStore {
    /// Gültige Sitzung (nil = abgemeldet)
    private(set) var credentials: CloudCredentials?
    /// „Deine Server“
    private(set) var servers: [CloudServer] = []
    private(set) var serversLoaded = false
    private(set) var loadingServers = false
    /// Mit mir geteilte Scoops (`shares:mine`, docs/sharing.md)
    var sharedWithMe: [SharedScoop] = []
    var sharedLoaded = false
    /// Einladung, die nach der Anmeldung angenommen werden soll (Link geöffnet, noch nicht angemeldet)
    var pendingInviteCode: String?
    /// Angemeldete Geräte
    private(set) var sessions: [CloudSession] = []
    private(set) var loadingSessions = false
    private(set) var signingIn = false
    /// Letzter Fehler für die Anmelde- bzw. Server-Ansicht
    var errorMessage: String?

    let isMock: Bool
    @ObservationIgnored let service: CloudService
    /// Laufende Erneuerung (nur eine gleichzeitig)
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    /// Nonce der laufenden Apple-Anfrage
    @ObservationIgnored private var pendingNonce: String?
    /// Wird nach dem Abmelden/Löschen aufgerufen (AppStore trennt dann eine Konto-Verbindung).
    @ObservationIgnored var onSignedOut: (() -> Void)?

    var user: CloudUser? { credentials?.user }
    var isSignedIn: Bool { credentials != nil }

    private static let keychainAccount = "cloud-session"

    init(mock: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) {
        isMock = mock
        if mock {
            service = MockCloudService()
            // Demo: Beispielkonto angemeldet, außer für Screenshots der Anmeldung (`-accountscreen signin`)
            let screen = arguments.firstIndex(of: "-accountscreen").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            // Einführung im Demo-Modus: Begrüßung und Anmeldung starten abgemeldet
            let signedOut = screen == "signin" || (OnboardingState.demoLaunchStep(arguments).map { $0 <= .signIn } ?? false)
            credentials = signedOut ? nil : MockCloudService.demoCredentials()
        } else {
            service = ConvexCloudService()
            credentials = Self.loadCredentials()
            observeAppleRevocation()
        }
        #if DEBUG
        // Nur Debug-Builds: `-testaccount <datei.json>` meldet mit einer Test-Sitzung an (z. B. aus
        // `devtools:issueTestSession` im Convex-Dev-Deployment; mit `-cloudurl` kombinieren). Die Sitzung lebt nur
        // im Speicher: Schlüsselbund und gespeicherte Anmeldung bleiben unberührt.
        if !mock, let i = arguments.firstIndex(of: "-testaccount"), i + 1 < arguments.count,
           let data = FileManager.default.contents(atPath: arguments[i + 1]),
           let test = try? JSONDecoder().decode(TestSession.self, from: data) {
            ephemeral = true
            credentials = CloudCredentials(
                token: test.token, refreshToken: test.refreshToken,
                expiresAt: test.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                user: CloudUser(id: test.userId ?? JWT.claim("sub", in: test.token) ?? "", name: test.name ?? "Testkonto",
                                email: nil),
                appleUserID: nil)
        }
        #endif
    }

    #if DEBUG
    /// Format von `-testaccount` (Felder wie `devtools:issueTestSession`; `expiresAt` in Millisekunden)
    private struct TestSession: Decodable {
        var token: String
        var refreshToken: String?
        var expiresAt: Double?
        var userId: String?
        var name: String?
    }
    #endif
    /// Test-Sitzung (`-testaccount`): nichts in den Schlüsselbund schreiben
    @ObservationIgnored private var ephemeral = false

    // MARK: - Schlüsselbund

    private static func loadCredentials() -> CloudCredentials? {
        guard let raw = Keychain.read(account: keychainAccount), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CloudCredentials.self, from: data)
    }

    private func store(_ creds: CloudCredentials?) {
        credentials = creds
        guard !isMock, !ephemeral else { return }
        if let creds, let data = try? JSONEncoder().encode(creds), let raw = String(data: data, encoding: .utf8) {
            Keychain.write(raw, account: Self.keychainAccount)
        } else {
            Keychain.delete(account: Self.keychainAccount)
        }
    }

    // MARK: - Mit Apple anmelden

    /// Konfiguriert die Apple-Anfrage (Name + E-Mail, Nonce).
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        let nonce = Self.randomNonce()
        pendingNonce = nonce
        request.nonce = Self.sha256(nonce)
        errorMessage = nil
    }

    /// Ergebnis von `SignInWithAppleButton`.
    func complete(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if let e = error as? ASAuthorizationError, e.code == .canceled { return }
            errorMessage = "Anmeldung abgebrochen: \(error.localizedDescription)"
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple hat keine Anmeldedaten geliefert."
                return
            }
            let name = credential.fullName
            let fullName = name.flatMap { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            let request = AppleSignInRequest(
                identityToken: identityToken,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                fullName: (fullName?.isEmpty ?? true) ? nil : fullName,
                givenName: name?.givenName, familyName: name?.familyName,
                email: credential.email, nonce: pendingNonce,
                deviceName: Device.name, platform: Device.platform)
            await signIn(with: request, appleUserID: credential.user)
        }
    }

    /// Demo-Modus: Beispielkonto ohne Apple.
    func signInDemo() async {
        guard isMock else { return }
        signingIn = true
        try? await Task.sleep(for: .milliseconds(450))
        store(MockCloudService.demoCredentials())
        signingIn = false
        await loadServers()
    }

    private func signIn(with request: AppleSignInRequest, appleUserID: String) async {
        signingIn = true
        errorMessage = nil
        defer { signingIn = false; pendingNonce = nil }
        do {
            let response = try await service.signInWithApple(request)
            var user = response.user ?? CloudUser(id: JWT.claim("sub", in: response.token) ?? "", name: nil, email: nil)
            // Apple liefert Name/E-Mail nur beim ersten Mal; fehlen sie in der Antwort, die eigenen nehmen
            if user.name == nil { user.name = request.fullName }
            if user.email == nil { user.email = request.email ?? JWT.claim("email", in: request.identityToken) }
            store(CloudCredentials(token: response.token, refreshToken: response.refreshToken,
                                   expiresAt: response.expiresAt, user: user, appleUserID: appleUserID))
            await loadServers()
        } catch {
            errorMessage = "Anmeldung fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Sitzung erneuern

    /// Gültiges Sitzungs-JWT. Läuft es in weniger als einer Minute ab, wird vorher erneuert; in den letzten
    /// sieben Tagen der Laufzeit (30 Tage) im Hintergrund (Empfehlung des Backends).
    func validToken() async throws -> String {
        guard let creds = credentials else { throw CloudError(status: 401, message: "Nicht angemeldet") }
        guard let expiry = creds.expiry else { return creds.token }
        let left = expiry.timeIntervalSinceNow
        if left < 60 { return try await refresh() }
        if left < 7 * 86400, refreshTask == nil {
            Task { _ = try? await self.refresh() }
        }
        return creds.token
    }

    /// Nach 401 vom eigenen Server oder von Convex: sofort erneuern.
    func forceRefresh() async -> Bool {
        guard credentials != nil else { return false }
        return (try? await refresh()) != nil
    }

    @discardableResult
    private func refresh() async throws -> String {
        if let running = refreshTask { return try await running.value }
        guard let creds = credentials else { throw CloudError(status: 401, message: "Nicht angemeldet") }
        let task = Task { () throws -> String in
            let response = try await service.refresh(refreshToken: creds.refreshToken, token: creds.token)
            guard var current = self.credentials, current.token == creds.token else {
                return self.credentials?.token ?? response.token
            }
            current.token = response.token
            current.refreshToken = response.refreshToken ?? current.refreshToken
            current.expiresAt = response.expiresAt
            if let user = response.user, !user.id.isEmpty {
                current.user.id = user.id
                current.user.name = user.name ?? current.user.name
                current.user.email = user.email ?? current.user.email
            }
            self.store(current)
            return response.token
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch let e as CloudError where e.isUnauthorized {
            // Sitzung widerrufen (anderes Gerät, Konto gelöscht): lokal abmelden
            signOutLocally()
            throw e
        }
    }

    /// Ruft eine Konto-Funktion auf und erneuert bei abgelaufener Sitzung einmal.
    func authorized<T>(_ body: (String) async throws -> T) async throws -> T {
        let token = try await validToken()
        do {
            return try await body(token)
        } catch let e as CloudError where e.isUnauthorized {
            let fresh = try await refresh()
            return try await body(fresh)
        }
    }

    // MARK: - Server

    func loadServers() async {
        guard isSignedIn else { return }
        loadingServers = true
        defer { loadingServers = false }
        do {
            servers = try await authorized { try await service.myServers(token: $0) }
            serversLoaded = true
            errorMessage = nil
        } catch {
            if isSignedIn { errorMessage = "Server konnten nicht geladen werden: \(error.localizedDescription)" }
        }
    }

    func server(id: String?) -> CloudServer? { servers.first { $0.id == id } }

    /// Koppelt einen Server per Code (Server zeigt ihn an: `bin/aisbot cloud-link`).
    func claimServer(code: String) async throws -> ClaimResult {
        let normalized = Self.normalizeCode(code)
        let result = try await authorized { try await service.claimServer(code: normalized, token: $0) }
        guard result.ok else {
            let fallback = result.error == "rate_limited"
                ? "Zu viele Versuche. Bitte warte ein paar Minuten."
                : "Dieser Code ist ungültig oder abgelaufen."
            throw CloudError(status: 400, message: result.message ?? fallback, code: result.error)
        }
        await loadServers()
        // Der Server meldet sich nach dem Abholen seines Schlüssels in wenigen Sekunden: kurz danach nachladen
        Task {
            try? await Task.sleep(for: .seconds(6))
            await self.loadServers()
        }
        return result
    }

    func renameServer(_ server: CloudServer, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await authorized { try await service.renameServer(id: server.id, name: trimmed, token: $0) }
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i].name = trimmed }
    }

    func removeServer(_ server: CloudServer) async throws {
        try await authorized { try await service.removeServer(id: server.id, token: $0) }
        servers.removeAll { $0.id == server.id }
    }

    /// Großbuchstaben, ohne Leer- und Bindestriche (Anzeige z. B. `ABCD-2345`).
    static func normalizeCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Geräte

    func loadSessions() async {
        guard isSignedIn else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            let sid = credentials?.sessionID
            sessions = try await authorized { try await service.mySessions(token: $0) }
                .map { s in var s = s; if let sid, s.id == sid { s.current = true }; return s }
                .sorted { ($0.current ? 1 : 0, $0.lastUsedAt ?? .distantPast) > ($1.current ? 1 : 0, $1.lastUsedAt ?? .distantPast) }
        } catch {
            if isSignedIn { errorMessage = "Geräte konnten nicht geladen werden: \(error.localizedDescription)" }
        }
    }

    func revoke(_ session: CloudSession) async throws {
        try await authorized { try await service.revokeSession(id: session.id, token: $0) }
        sessions.removeAll { $0.id == session.id }
        if session.current { signOutLocally() }
    }

    // MARK: - Abmelden, Konto löschen

    /// Meldet dieses Gerät ab (Sitzung beim Konto-Dienst widerrufen, so gut es geht) und löscht die Daten lokal.
    func signOut() async {
        if let creds = credentials, !isMock {
            // Ohne ID widerruft Convex die eigene Sitzung
            try? await service.revokeSession(id: nil, token: creds.token)
        }
        signOutLocally()
    }

    /// Löscht das Konto samt Server-Verknüpfungen und Sitzungen beim Konto-Dienst (App-Store-Pflicht).
    /// Die eigenen Server und ihre Daten bleiben auf den Macs; sie sind danach keinem Konto mehr zugeordnet.
    func deleteAccount() async throws {
        try await authorized { try await service.deleteAccount(token: $0) }
        signOutLocally()
    }

    private func signOutLocally() {
        refreshTask?.cancel()
        refreshTask = nil
        store(nil)
        servers = []
        serversLoaded = false
        sessions = []
        sharedWithMe = []
        sharedLoaded = false
        onSignedOut?()
    }

    // MARK: - Apple-Widerruf

    /// Beim Start: Hat die Person die Anmeldung bei Apple widerrufen (Einstellungen → Apple-ID), abmelden.
    func checkAppleCredentialState() async {
        guard !isMock, let appleID = credentials?.appleUserID else { return }
        let state = await withCheckedContinuation { (cont: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleID) { state, _ in cont.resume(returning: state) }
        }
        if state == .revoked { signOutLocally() }
    }

    private func observeAppleRevocation() {
        NotificationCenter.default.addObserver(forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkAppleCredentialState() }
        }
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset[Int.random(in: 0..<charset.count, using: &generator)] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Gerätename und Plattform für die Geräteliste.
enum Device {
    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }
}
