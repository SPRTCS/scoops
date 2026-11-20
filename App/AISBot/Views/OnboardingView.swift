import AuthenticationServices
import SwiftUI

/// Gerenderte Scoop-Figuren aus dem Marketing (Marketing/figuren, als Assets `ScoopFigure01…07` in der App).
/// Für Deko in der Einführung; eigene Scoops zeigt weiter `MascotView`, weil nur sie Form, Farbe und Augen abbildet.
enum ScoopFigure: String, CaseIterable {
    case violettBrille = "01", gelbBarett = "02", blauWolke = "03", pinkHerz = "04", gruenStern = "05",
         creme = "06", koralleKopfhoerer = "07"

    var image: Image { Image("ScoopFigure\(rawValue)") }
}

/// Eine gerenderte Figur in fester Größe (unten ausgerichtet, VoiceOver ignoriert sie)
struct ScoopFigureView: View {
    var figure: ScoopFigure
    var size: CGFloat
    /// Leichtes Schweben (Warten, Verbinden); aus bei „Bewegung reduzieren“
    var floating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let image = figure.image
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        if floating && !reduceMotion {
            image.phaseAnimator([false, true]) { content, up in
                content.offset(y: up ? -size * 0.05 : 0).scaleEffect(up ? 1.02 : 1, anchor: .bottom)
            } animation: { _ in .easeInOut(duration: 1.2) }
        } else {
            image
        }
    }
}

/// Die Scoop-Runde über Begrüßung, Anmeldung und Tipps (gerenderte Figuren).
struct WelcomeCrew: View {
    var scale: CGFloat = 1

    private let crew: [(ScoopFigure, CGFloat)] = [
        (.gruenStern, 64), (.violettBrille, 76), (.creme, 96), (.pinkHerz, 76), (.koralleKopfhoerer, 64),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: -10 * scale) {
            ForEach(Array(crew.enumerated()), id: \.offset) { _, item in
                ScoopFigureView(figure: item.0, size: item.1 * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

/// „Mit Apple anmelden“ im Stil der App (weiß in Nacht, schwarz in Hell). Im Demo-Modus meldet der Knopf
/// das Beispielkonto an, ohne Apple zu fragen.
struct AppleSignInButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    var height: CGFloat = 50

    var body: some View {
        let account = store.account
        ZStack {
            #if os(macOS)
            // Auf dem Mac ignoriert `SignInWithAppleButton` die Höhe; eigener Knopf nach Apples Vorgaben
            // (Logo + „Mit Apple anmelden“, weiß bzw. schwarz), gleicher Ablauf über ASAuthorizationController.
            Button { AppleSignInLauncher.shared.start(account) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.fixed(height * 0.36, weight: .medium))
                    Text("Mit Apple anmelden").font(.fixed(height * 0.34, weight: .semibold))
                }
                .foregroundStyle(theme.kind == .nacht ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(theme.kind == .nacht ? Color.white : Color.black,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(account.signingIn)
            .opacity(account.signingIn ? 0.6 : 1)
            #else
            SignInWithAppleButton(.signIn) { request in
                account.prepare(request)
            } onCompletion: { result in
                Task { await account.complete(result) }
            }
            .signInWithAppleButtonStyle(theme.kind == .nacht ? .white : .black)
            .id(theme.kind)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(account.signingIn)
            .opacity(account.signingIn ? 0.6 : 1)
            #endif

            if account.isMock {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await account.signInDemo() } }
                    .accessibilityHidden(true)
            }
            if account.signingIn {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#if os(macOS)
/// Startet „Mit Apple anmelden“ ohne `SignInWithAppleButton` (Mac) und reicht das Ergebnis an den AccountStore.
final class AppleSignInLauncher: NSObject {
    static let shared = AppleSignInLauncher()
    private weak var account: AccountStore?
    private var controller: ASAuthorizationController?

    func start(_ account: AccountStore) {
        if account.isMock { Task { await account.signInDemo() }; return }
        self.account = account
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        controller = nil
        guard let account else { return }
        Task { await account.complete(result) }
    }
}

extension AppleSignInLauncher: ASAuthorizationControllerDelegate,
                               ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
}
#endif

/// Bisheriger Weg: Server-Adresse + Token (bzw. Kopplungslink `aisbot://pair?…`).
struct ManualConnectForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var url = ConnectionSettings.suggestedURL
    @State private var token = ConnectionSettings.storedToken
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Server-Adresse").appFont(12.5, weight: .medium).foregroundStyle(theme.textSecondary)
                TextField("https://…ts.net", text: $url)
                    .modifier(FieldStyle(alignment: .leading))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Token").appFont(12.5, weight: .medium).foregroundStyle(theme.textSecondary)
                SecureField("Token vom Server", text: $token)
                    .modifier(FieldStyle(alignment: .leading))
                    .onSubmit(connect)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .appFont(12.5)
                    .foregroundStyle(theme.danger)
            }
            Button(action: connect) {
                HStack {
                    if checking { ProgressView().controlSize(.small) }
                    Text(checking ? "Verbinde …" : "Verbinden")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(checking || url.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)

            Text("Den Kopplungslink (`aisbot://pair?…`) zeigt dir der Server an. Öffnest du ihn auf diesem Gerät, wird alles automatisch eingetragen.")
                .appFont(12)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func connect() {
        let candidate = ConnectionSettings(serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                           token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !candidate.isMock else {
            Task { await store.connect(with: candidate, persist: true) }
            return
        }
        guard candidate.baseURL != nil else { error = String(localized: "Die Server-Adresse ist ungültig."); return }
        guard !candidate.token.isEmpty else { error = String(localized: "Bitte gib den Token ein."); return }
        checking = true
        error = nil
        Task {
            do {
                _ = try await store.validate(candidate)
                await store.connect(with: candidate, persist: true)
            } catch let e as APIError where e.status == 401 || e.status == 403 {
                error = String(localized: "Der Token passt nicht.")
            } catch {
                self.error = String(localized: "Server nicht erreichbar: \(error.localizedDescription)")
            }
            checking = false
        }
    }
}
