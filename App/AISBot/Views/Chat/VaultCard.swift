import SwiftUI
import LocalAuthentication

/// Tresor-Formular (v1.10, `meta.kind == "vault"`): Ein Scoop möchte einen Login anlegen. Arman trägt Benutzer und
/// Passwort direkt in der Karte ein und speichert nach Face ID / Touch ID im Tresor des Bot-Rechners.
///
/// Gestaltung wie die Mail-Karte (`MailCard`). Zustände aus `vault.status`: pending (Formular), saved (kompakt,
/// grüner Haken), declined (kompakt, grau). Das Passwort liegt nur so lange im Zustand der Karte, bis es gesendet
/// wird, und wird nie protokolliert.
struct VaultCard: View {
    let message: Message
    let vault: VaultForm
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var username: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    init(message: Message, vault: VaultForm) {
        self.message = message
        self.vault = vault
        _username = State(initialValue: vault.username ?? "")
    }

    private var status: String {
        // Ältere Server ohne `vault.status`: aus dem Freigabe-Zustand ableiten
        if vault.status == "pending", message.meta.state == "declined" { return "declined" }
        if vault.status == "pending", message.meta.state == "approved" { return "saved" }
        return vault.status
    }
    private var isPending: Bool { status == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isPending {
                form
                hint
                if let error { errorText(error) }
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Wird gespeichert …").appFont(13, weight: .medium).foregroundStyle(theme.textSecondary)
                    }
                } else {
                    buttons
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.2), value: status)
        .animation(.smooth(duration: 0.2), value: working)
        .contextMenu {
            Button { Clipboard.copy(copyText) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        #if DEBUG
        .onAppear {
            // Nur Debug + Demo: Passwort vorbelegen, um Speichern ohne Tastatur zu testen (`-vaulttestpassword <pw>`)
            let args = ProcessInfo.processInfo.arguments
            if store.isMock, isPending, password.isEmpty, let i = args.firstIndex(of: "-vaulttestpassword"), args.indices.contains(i + 1) {
                password = args[i + 1]
            }
        }
        #endif
        .onChange(of: status) { _, new in
            // Erledigt (auch von einem anderen Gerät): Eingaben verwerfen
            if new != "pending" { password = ""; showPassword = false; error = nil }
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .appFont(13, weight: .semibold)
                .foregroundStyle(headerTint)
                .scaledFrame(28)
                .background(headerTint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(kicker)
                    .appFont(11.5, weight: .medium).foregroundStyle(theme.textTertiary)
                Text(headline)
                    .appFont(15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !isPending, let detail = compactDetail {
                    Text(detail)
                        .appFont(12.5)
                        .foregroundStyle(theme.textSecondary)
                        .adaptiveLineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerIcon: String {
        switch status {
        case "saved": "checkmark"
        case "declined": "xmark"
        default: "key.fill"
        }
    }

    private var headerTint: Color {
        switch status {
        case "saved": theme.success
        case "declined": theme.textTertiary
        default: theme.warning
        }
    }

    private var kicker: String {
        switch status {
        case "saved": String(localized: "Tresor")
        case "declined": String(localized: "Tresor · Abgelehnt")
        default: String(localized: "Tresor · Login anlegen")
        }
    }

    private var headline: String {
        switch status {
        case "saved": String(localized: "Im Tresor gespeichert")
        case "declined": String(localized: "Nicht gespeichert: \(vault.title)")
        default: vault.title
        }
    }

    /// Kompakte Zeile unter dem Titel (gespeichert/abgelehnt)
    private var compactDetail: String? {
        let parts = [status == "saved" ? vault.title : nil, vault.site, vault.username.flatMap { $0.isEmpty ? nil : $0 }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Formular

    private var form: some View {
        VStack(spacing: 0) {
            row("Webseite") {
                if let link = siteURL {
                    Link(destination: link) {
                        HStack(spacing: 4) {
                            Text(vault.site ?? link.absoluteString).adaptiveLineLimit(1)
                            Image(systemName: "arrow.up.right").appFont(9, weight: .bold)
                        }
                        .appFont(14)
                        .foregroundStyle(theme.link)
                    }
                    .help(link.absoluteString)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(vault.site ?? "–").appFont(14).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            divider
            row("Benutzer") {
                TextField("Name oder E-Mail", text: $username)
                    .textFieldStyle(.plain)
                    .appFont(14)
                    .foregroundStyle(theme.textPrimary)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .disabled(working)
            }
            divider
            row("Passwort") {
                HStack(spacing: 8) {
                    Group {
                        if showPassword {
                            TextField("Passwort", text: $password)
                        } else {
                            SecureField("Passwort", text: $password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .appFont(14)
                    .foregroundStyle(theme.textPrimary)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focus, equals: .password)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .disabled(working)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .appFont(13, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .scaledFrame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Passwort verbergen" : "Passwort anzeigen")
                    .accessibilityLabel(showPassword ? "Passwort verbergen" : "Passwort anzeigen")
                }
            }
        }
        .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
    }

    private var siteURL: URL? {
        guard let s = vault.url, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    private var divider: some View {
        Rectangle().fill(theme.surfaceBorder).frame(height: 0.5).padding(.leading, 12)
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        // Große Schrift (Bedienungshilfen): Beschriftung über dem Feld statt in einer festen Spalte
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: dynamicTypeSize.isAccessibilitySize ? 2 : 10) {
            Text(label)
                .appFont(13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : AppFont.scaled(70, relativeTo: .footnote, in: dynamicTypeSize),
                       alignment: .leading)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var hint: some View {
        Label("Kein Scoop sieht das Passwort.", systemImage: "lock.fill")
            .appFont(12.5)
            .foregroundStyle(theme.textSecondary)
            .labelStyle(HintLabelStyle())
    }

    private func errorText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .appFont(13)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Knöpfe

    private var canSave: Bool { !password.isEmpty && !working }

    private var buttons: some View {
        AdaptiveButtonRow(spacing: 8, stretchWhenStacked: true) {
            Spacer(minLength: 0)
            Button { decline() } label: { Text("Abbrechen").frame(minWidth: 80) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button { save() } label: {
                Label("Im Tresor speichern", systemImage: "key.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(!canSave)
        }
    }

    private func save() {
        guard canSave else { return }
        working = true
        error = nil
        Task {
            if let authError = await DeviceAuth.confirm(reason: String(localized: "Login im Tresor speichern"), skip: skipsAuthentication) {
                error = authError
                working = false
                return
            }
            // Passwort nur für diese eine Anfrage halten, sofort aus dem Zustand nehmen
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let edits = VaultEdits(username: trimmed.isEmpty ? nil : trimmed, password: password)
            password = ""
            showPassword = false
            focus = nil
            error = await store.decideVault(message, approve: true, edits: edits)
            working = false
        }
    }

    private func decline() {
        working = true
        error = nil
        password = ""
        focus = nil
        Task {
            error = await store.decideVault(message, approve: false, edits: nil)
            working = false
        }
    }

    /// Nur Demo/Screenshots: `-vaultdemo` überspringt Face ID / Touch ID (wie beim Tresor).
    private var skipsAuthentication: Bool {
        store.isMock && ProcessInfo.processInfo.arguments.contains("-vaultdemo")
    }

    private var copyText: String {
        [vault.title, vault.url ?? vault.site, vault.username].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Kleines Symbol vor dem Hinweistext, auf Höhe der ersten Zeile.
private struct HintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.appFont(10.5)
            configuration.title
        }
    }
}

/// Face ID / Touch ID / Gerätecode wie beim Tresor (`VaultView`).
enum DeviceAuth {
    /// `nil` = bestätigt, sonst ein Hinweistext.
    static func confirm(reason: String, skip: Bool = false) async -> String? {
        if skip { return nil }
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Abbrechen")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return String(localized: "Auf diesem Gerät ist kein Code oder Face ID / Touch ID eingerichtet.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? nil : String(localized: "Nicht bestätigt.")
        } catch {
            return String(localized: "Nicht bestätigt. Tippe noch einmal auf „Im Tresor speichern“.")
        }
    }
}
