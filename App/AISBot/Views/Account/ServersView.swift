import SwiftUI

/// Abschnitt „Deine Server“ mit Liste, Verbinden, Umbenennen, Entfernen und „Server hinzufügen“.
/// Wird beim Start (ohne Verbindung) und im Blatt „Server wechseln“ verwendet.
struct ServerListSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    /// Nach dem Verbinden (z. B. Blatt schließen)
    var onConnect: (() -> Void)?
    /// „Server hinzufügen“ selbst übernehmen (Einführung: geführte Kopplung statt Blatt)
    var onAdd: (() -> Void)?

    @State private var showAdd = ProcessInfo.processInfo.arguments.contains("-addserver")
    @State private var renaming: CloudServer?
    @State private var newName = ""
    @State private var removing: CloudServer?
    @State private var connectingID: String?

    var body: some View {
        let account = store.account
        GroupedStack {
            GroupedSection("Deine Server", footer: footer, dividerInset: 62) {
                if account.servers.isEmpty {
                    emptyRow
                } else {
                    ForEach(account.servers) { server in
                        ServerRow(server: server,
                                  isCurrent: store.settings.cloudServerID == server.id && store.phase != .unconfigured,
                                  connecting: connectingID == server.id,
                                  onConnect: { connect(server) },
                                  onRename: { newName = server.name; renaming = server },
                                  onRemove: { removing = server })
                    }
                }
                Button { if let onAdd { onAdd() } else { showAdd = true } } label: {
                    GroupedLabelRow(icon: "plus.circle.fill", iconColor: theme.accent, title: "Server hinzufügen",
                                    subtitle: "Mit dem Kopplungscode, den dein Mac anzeigt") { DisclosureChevron() }
                        .padding(.leading, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .task { await account.loadServers() }
        .sheet(isPresented: $showAdd) {
            AddServerSheet()
                .environment(\.theme, theme)
                .environment(store)
                .preferredColorScheme(theme.preferredScheme)
        }
        .alert("Server umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Sichern") {
                guard let server = renaming else { return }
                let name = newName
                renaming = nil
                Task {
                    do { try await account.renameServer(server, to: name) }
                    catch { store.errorMessage = "Umbenennen fehlgeschlagen: \(error.localizedDescription)" }
                }
            }
        }
        .confirmationDialog(removing.map { "„\($0.name)“ aus dem Konto entfernen?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                guard let server = removing else { return }
                removing = nil
                Task {
                    do {
                        try await account.removeServer(server)
                        if store.settings.cloudServerID == server.id { store.disconnect() }
                    } catch {
                        store.errorMessage = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
                    }
                }
            }
        } message: {
            Text("Der Server läuft auf deinem Mac weiter, mit allen Scoops und Chats. Er erscheint nur nicht mehr in deiner Liste, bis du ihn neu koppelst.")
        }
    }

    private var footer: String? {
        if let error = store.account.errorMessage { return error }
        return store.account.servers.isEmpty ? nil : "Tippe auf einen Server, um dich zu verbinden. Online heißt: Er hat sich in den letzten drei Minuten gemeldet."
    }

    @ViewBuilder
    private var emptyRow: some View {
        if store.account.loadingServers && !store.account.serversLoaded {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Lade deine Server …").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
            }
            .groupedRow(vertical: 14)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Noch kein Server").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("Starte AIS Scoops Server auf deinem Mac und koppele ihn mit „Server hinzufügen“.")
                    .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
            }
            .groupedRow(vertical: 12)
        }
    }

    private func connect(_ server: CloudServer) {
        connectingID = server.id
        Task {
            await store.connect(to: server)
            connectingID = nil
            if store.phase != .unconfigured { onConnect?() }
        }
    }
}

/// Eine Zeile in „Deine Server“.
struct ServerRow: View {
    let server: CloudServer
    var isCurrent: Bool
    var connecting: Bool
    var onConnect: () -> Void
    var onRename: () -> Void
    var onRemove: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onConnect) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: server.name.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Circle()
                            .fill(server.online ? theme.success : theme.textTertiary)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(theme.groupedCard, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.name).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textPrimary)
                            if isCurrent {
                                Text("Verbunden")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(theme.success)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(theme.success.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(server.online ? theme.success : theme.textSecondary)
                            .lineLimit(1)
                        if let host = server.displayHost, !host.isEmpty {
                            Text(host)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    if connecting { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(connecting)

            Menu {
                Button("Verbinden", systemImage: "arrow.right.circle", action: onConnect)
                Button("Umbenennen", systemImage: "pencil", action: onRename)
                Divider()
                Button("Entfernen", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Optionen für \(server.name)")
        }
        .groupedRow(vertical: 9)
        .contextMenu {
            Button("Umbenennen", systemImage: "pencil", action: onRename)
            Button("Entfernen", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts: [String] = [server.online ? "Online" : offlineText]
        if let v = server.version, !v.isEmpty { parts.append("v\(v)") }
        return parts.joined(separator: " · ")
    }

    private var offlineText: String {
        guard let seen = server.lastSeenAt else { return "Offline" }
        return "Offline seit \(seen.formatted(.relative(presentation: .named)).replacingOccurrences(of: "vor ", with: ""))"
    }
}

/// „Server hinzufügen“: Code eingeben, den der Mac anzeigt (`claimServer`).
struct AddServerSheet: View {
    /// Vorausgefüllter Kopplungscode (Kopplungslink)
    var initialCode = ""
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var normalized: String { AccountStore.normalizeCode(code) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Server hinzufügen", icon: "plus.circle") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Öffne auf deinem Mac die App „AIS Scoops Server“. Noch nicht installiert? Du bekommst sie auf \(ScoopsLinks.serverDownloadDisplay).")
                        step(2, "Der Assistent zeigt im Schritt „Mit der App verbinden“ einen Kopplungscode mit acht Zeichen, zum Beispiel ABCD-2345.")
                        step(3, "Gib den Code hier ein. Der Server erscheint danach unter „Deine Server“.")
                    }
                    .padding(16)
                    .themedCard(theme, radius: 16)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kopplungscode").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textSecondary)
                        PairingCodeField(code: $code, focused: $focused, onSubmit: claim)
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.danger)
                        }
                    }

                    Button(action: claim) {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? "Kopple …" : "Koppeln")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(working || normalized.count != 8)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
        }
        .background(theme.groupedBackground)
        .onAppear {
            if code.isEmpty, !initialCode.isEmpty { code = initialCode }
            focused = true
        }
        #if os(macOS)
        .frame(width: 440, height: 500)
        #else
        .presentationDetents([.large])
        #endif
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.sendButtonIcon)
                .frame(width: 24, height: 24)
                .background(theme.sendButton, in: Circle())
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func claim() {
        guard normalized.count == 8, !working else { return }
        working = true
        error = nil
        Task {
            do {
                let result = try await store.account.claimServer(code: normalized)
                store.showToast("„\(result.name ?? "Server")“ hinzugefügt")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Großes Eingabefeld für den Kopplungscode (formatiert `abcd2345` → `ABCD-2345`).
struct PairingCodeField: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        TextField("ABCD-2345", text: $code)
            .font(.system(.title, design: .monospaced, weight: .semibold))
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused.wrappedValue ? theme.accent : theme.surfaceBorder, lineWidth: focused.wrappedValue ? 1.5 : 1))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            #endif
            .focused(focused)
            .onSubmit(onSubmit)
            .onChange(of: code) { _, value in
                let formatted = Self.format(value)
                if formatted != value { code = formatted }
            }
            .accessibilityLabel("Kopplungscode")
            .accessibilityHint("Acht Zeichen, die der Assistent von AIS Scoops Server anzeigt")
    }

    /// `abcd2345` → `ABCD-2345` (höchstens acht Zeichen)
    static func format(_ raw: String) -> String {
        let chars = Array(AccountStore.normalizeCode(raw).prefix(8))
        guard chars.count > 4 else { return String(chars) }
        return String(chars[..<4]) + "-" + String(chars[4...])
    }
}

/// Blatt „Server wechseln“ (Einstellungen → Konto).
struct ServerSwitcherSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Deine Server", icon: "server.rack") { dismiss() }
            ScrollView {
                ServerListSection(onConnect: { dismiss() })
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }
}
