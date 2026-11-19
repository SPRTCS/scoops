import SwiftUI

/// Abschnitt „Konto“ ganz oben in den Einstellungen. Angemeldet: Profil und „Deine Server“;
/// abgemeldet: optionale Anmeldung (bestehende Token-Verbindungen bleiben unberührt).
struct AccountSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showAccount = ProcessInfo.processInfo.arguments.contains("-accountsheet")
    @State private var showServers = false

    var body: some View {
        let account = store.account
        if let user = account.user {
            GroupedSection("Konto", footer: "Dein Konto verbindet deine Geräte mit deinen Servern. Inhalte bleiben auf deinem Mac.", dividerInset: 62) {
                Button { showAccount = true } label: {
                    HStack(spacing: 12) {
                        AccountAvatar(user: user, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Text(user.email ?? "Mit Apple angemeldet").font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        DisclosureChevron()
                    }
                    .groupedRow(vertical: 10)
                }
                .buttonStyle(.plain)
                Button { showServers = true } label: {
                    GroupedLabelRow(icon: "server.rack", iconColor: theme.accent, title: "Deine Server", subtitle: serversSummary) {
                        DisclosureChevron()
                    }
                    .padding(.leading, 9)
                }
                .buttonStyle(.plain)
            }
            .task { if !account.serversLoaded { await account.loadServers() } }
            .sheet(isPresented: $showAccount) {
                AccountSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
            }
            .sheet(isPresented: $showServers) {
                ServerSwitcherSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
            }
        } else {
            GroupedSection("Konto", footer: "Optional: Mit einem Konto siehst du deine Server auf jedem Gerät und verbindest dich ohne Token. Deine jetzige Verbindung bleibt bestehen.") {
                VStack(alignment: .leading, spacing: 12) {
                    AppleSignInButton(height: 44)
                    if let error = account.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.danger)
                    }
                }
                .groupedRow(vertical: 12)
            }
        }
    }

    private var serversSummary: String {
        let servers = store.account.servers
        guard !servers.isEmpty else { return store.account.serversLoaded ? "Noch kein Server gekoppelt" : "Lade …" }
        let online = servers.filter(\.online).count
        let total = "\(servers.count) \(servers.count == 1 ? "Server" : "Server")"
        if let current = store.settings.cloudServerName, store.settings.usesAccount {
            return "Verbunden mit \(current) · \(online) von \(total) online"
        }
        return "\(online) von \(total) online"
    }
}

/// Runder Avatar mit Initialen.
struct AccountAvatar: View {
    let user: CloudUser
    var size: CGFloat = 38
    @Environment(\.theme) private var theme

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(hex: "#8B5CF6"), Color(hex: "#3D84F5")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let source = user.name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? user.name! : (user.email ?? "?")
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// Konto-Details: Profil, angemeldete Geräte, Abmelden, Konto löschen.
struct AccountSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var revoking: CloudSession?
    @State private var deleting = false

    var body: some View {
        let account = store.account
        VStack(spacing: 0) {
            SheetHeader("Konto", icon: "person.crop.circle") { dismiss() }
            ScrollView {
                GroupedStack {
                    if let user = account.user {
                        profile(user)
                    }
                    devices
                    GroupedSection(footer: "Meldet nur dieses Gerät ab. Verbindungen per Token bleiben bestehen.") {
                        Button { confirmSignOut = true } label: {
                            GroupedLabelRow(icon: "rectangle.portrait.and.arrow.right", iconColor: theme.textSecondary,
                                            title: "Abmelden")
                        }
                        .buttonStyle(.plain)
                    }
                    GroupedSection(footer: "Löscht dein Konto, die Liste deiner Server und alle Anmeldungen. Deine Server laufen auf deinen Macs weiter, mit allen Scoops und Chats.") {
                        Button { confirmDelete = true } label: {
                            GroupedLabelRow(icon: "trash", iconColor: theme.danger, title: "Konto löschen", titleColor: theme.danger) {
                                if deleting { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(deleting)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground)
        .task { await account.loadSessions() }
        .onChange(of: account.isSignedIn) { _, signedIn in if !signedIn { dismiss() } }
        .confirmationDialog("Auf diesem Gerät abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) {
                Task { await account.signOut() }
            }
        } message: {
            Text(store.settings.usesAccount ? "Die Verbindung zu deinem Server wird getrennt." : "Deine Verbindung per Token bleibt bestehen.")
        }
        .alert("Konto endgültig löschen?", isPresented: $confirmDelete) {
            Button("Abbrechen", role: .cancel) {}
            Button("Konto löschen", role: .destructive) { deleteAccount() }
        } message: {
            Text("Das lässt sich nicht rückgängig machen. Dein Konto, deine Server-Liste und alle Anmeldungen werden gelöscht. Deine Server und ihre Daten bleiben auf deinen Macs.")
        }
        .confirmationDialog(revoking.map { "„\($0.deviceName)“ abmelden?" } ?? "",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) {
                guard let session = revoking else { return }
                revoking = nil
                Task {
                    do { try await account.revoke(session) }
                    catch { store.errorMessage = "Abmelden fehlgeschlagen: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("Das Gerät muss sich danach neu mit Apple anmelden.")
        }
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
    }

    private func profile(_ user: CloudUser) -> some View {
        VStack(spacing: 10) {
            AccountAvatar(user: user, size: 72)
            VStack(spacing: 3) {
                Text(user.displayName).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
                if let email = user.email {
                    Text(email).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                }
                Label("Mit Apple angemeldet", systemImage: "apple.logo")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var devices: some View {
        let account = store.account
        return GroupedSection("Angemeldete Geräte", footer: "Geräte, auf denen du mit diesem Konto angemeldet bist.", dividerInset: 50) {
            if account.sessions.isEmpty {
                HStack(spacing: 10) {
                    if account.loadingSessions { ProgressView().controlSize(.small) }
                    Text(account.loadingSessions ? "Lade …" : "Keine Geräte gefunden")
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                }
                .groupedRow()
            } else {
                ForEach(account.sessions) { session in
                    HStack(spacing: 12) {
                        Image(systemName: session.platformIcon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.deviceName).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                            Text(detail(session)).font(.system(size: 12.5)).foregroundStyle(session.current ? theme.success : theme.textSecondary)
                        }
                        Spacer()
                        if !session.current {
                            Button("Abmelden") { revoking = session }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                        }
                    }
                    .groupedRow(vertical: 9)
                }
            }
        }
    }

    private func detail(_ session: CloudSession) -> String {
        if session.current { return "Dieses Gerät" }
        guard let used = session.lastUsedAt else { return "Angemeldet" }
        return "Zuletzt aktiv \(used.formatted(.relative(presentation: .named)))"
    }

    private func deleteAccount() {
        deleting = true
        Task {
            do {
                try await store.account.deleteAccount()
                store.showToast("Konto gelöscht")
            } catch {
                store.errorMessage = "Konto konnte nicht gelöscht werden: \(error.localizedDescription)"
            }
            deleting = false
        }
    }
}
