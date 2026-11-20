import SwiftUI

// Chat-Karten für eigene MCP-Server (Server 1.35, docs/mcp.md):
// - `MCPSecretCard`: Freigabe-Karte mit sicherer Eingabe (`meta.secret_fields`), z. B. „MCP-Server verbinden“ mit Token.
//   Die Werte gehen nur mit der Entscheidung an den Server (Schlüsselbund) und stehen nie im Chat.
// - `MCPLoginCard`: Ereignis „Bei … anmelden“ (`meta.kind == "mcp_login"`), öffnet die Anmeldung beim Anbieter.

extension AppStore {
    /// Freigabe mit sicheren Werten. Gibt bei Fehler den Text zurück.
    func decideSecrets(_ message: Message, approve: Bool, secrets: [KeyValue]) async -> String? {
        guard let service = service(for: message.chatId), let approvalID = message.meta.approvalId else { return String(localized: "Keine Verbindung zum Server.") }
        do {
            upsert(try await service.decideSecrets(approvalID: approvalID, approve: approve, secrets: approve ? secrets : []))
            return nil
        } catch {
            return self.message(error)
        }
    }
}

struct MCPSecretCard: View {
    let message: Message
    let fields: [MessageMeta.SecretField]
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var values: [String: String] = [:]
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: String?

    private var state: String { message.meta.state ?? "pending" }
    private var complete: Bool {
        fields.allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var isConnect: Bool { message.meta.kind == "mcp_connect" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: message.meta.icon == "terminal" ? "terminal.fill" : (isConnect ? "server.rack" : "key.fill"))
                    .appFont(13)
                    .foregroundStyle(theme.warning)
                    .scaledFrame(26)
                    .background(theme.warning.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(state == "pending" ? "MCP-Server · Freigabe nötig" : "MCP-Server")
                        .appFont(11.5, weight: .medium).foregroundStyle(theme.textTertiary)
                    Text(message.meta.title ?? message.text)
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let details = message.meta.details, !details.isEmpty {
                Text(details)
                    .appFont(13.5)
                    .lineSpacing(2.5)
                    .foregroundStyle(theme.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            switch state {
            case "pending":
                ForEach(fields) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(f.label).appFont(12.5, weight: .semibold).foregroundStyle(theme.textSecondary)
                        SecureField(f.label, text: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0; error = nil }))
                            .textFieldStyle(.plain)
                            .appFont(15)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.surfaceBorder))
                            .focused($focus, equals: f.key)
                            .submitLabel(.done)
                            .onSubmit { if complete { decide(true) } }
                            .accessibilityIdentifier("secret.\(f.key)")
                    }
                }
                Label("Geht direkt in den Schlüsselbund deines Servers. Der Scoop sieht den Wert nie.", systemImage: "lock.fill")
                    .appFont(12).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                AdaptiveButtonRow(spacing: 8) {
                    Button { decide(true) } label: { Text(isConnect ? "Verbinden" : "Speichern").frame(minWidth: 90) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(!complete)
                    Button { decide(false) } label: { Text("Ablehnen").frame(minWidth: 80) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .appFont(12.5).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case "approved":
                Label(isConnect ? "Freigegeben, wird verbunden" : "Gespeichert", systemImage: "checkmark.circle.fill")
                    .appFont(13, weight: .medium).foregroundStyle(theme.success)
            default:
                Label("Abgelehnt", systemImage: "xmark.circle.fill")
                    .appFont(13, weight: .medium).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: state) { _, new in if new != "pending" { values = [:] } }
        .onDisappear { values = [:] }
    }

    private func decide(_ approve: Bool) {
        working = true
        error = nil
        let secrets = fields.map { KeyValue(key: $0.key, value: (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        Task {
            error = await store.decideSecrets(message, approve: approve, secrets: secrets)
            if error == nil { values = [:] }
            working = false
        }
    }
}

struct MCPLoginCard: View {
    let message: Message
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var login = WebLoginSession()
    @State private var working = false
    @State private var done = false
    @State private var error: String?

    private var name: String { message.meta.mcpServerName ?? String(localized: "MCP-Server") }

    var body: some View {
        if store.isGuestChat(message.chatId) {
            EventLine(message: message)  // Gäste: nur die Zeile, ohne Anmelden
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark" : "person.badge.key.fill")
                    .appFont(13)
                    .foregroundStyle(done ? theme.success : theme.accent)
                    .scaledFrame(26)
                    .background((done ? theme.success : theme.accent).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("MCP-Server · Anmeldung").appFont(11.5, weight: .medium).foregroundStyle(theme.textTertiary)
                    Text(done ? "Bei \(name) angemeldet" : "Bei \(name) anmelden")
                        .appFont(15, weight: .semibold).foregroundStyle(theme.textPrimary)
                }
            }
            if !done {
                Text("Du meldest dich direkt beim Anbieter an. Die Scoops bekommen nur den Zugang, nie dein Passwort.")
                    .appFont(13).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AdaptiveButtonRow(spacing: 8) {
                    Button { start() } label: { Text("Anmelden").frame(minWidth: 90) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(working)
                        .accessibilityIdentifier("mcp.login")
                    if working { ProgressView().controlSize(.small) }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(12.5).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start() {
        guard let id = message.meta.mcpServerId, let service = store.service(for: message.chatId) else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let link = try await service.loginMCP(id: id)
                if store.isMock { done = true; return }
                let err = await MCPLogin.run(link, login: login, store: store)
                if let err { if !err.isEmpty { error = err } } else { done = true }
            } catch {
                self.error = store.message(error)
            }
        }
    }
}
