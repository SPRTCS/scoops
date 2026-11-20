import SwiftUI
import Network

// Eigene MCP-Server (Server 1.35, docs/mcp.md): In „Apps verbinden“ lassen sich eigene MCP-Server hinzufügen
// (Remote ohne Anmeldung, mit Token oder mit OAuth; „Erweitert“: lokaler Befehl auf dem Server-Mac). Tokens gehen nur an
// den Server (Schlüsselbund), die App speichert sie nicht.

// MARK: - API

nonisolated struct MCPServerList: Decodable, Sendable {
    var servers: [CustomMCPServer]
}

nonisolated struct MCPProbe: Decodable, Sendable {
    /// none | token | oauth
    var auth: String
    var detail: String?
    var name: String?
}

/// Anmelde-Link für OAuth. `loopbackPort`: Der Anbieter erlaubt nur Loopback-Rücksprünge (z. B. Qonto); die App hört
/// während der Anmeldung kurz auf 127.0.0.1:<port> und reicht den Rücksprung weiter.
nonisolated struct MCPLoginLink: Decodable, Sendable {
    var url: String
    var serverId: String?
    var callbackScheme: String?
    var loopbackPort: Int?
    var loopbackPath: String?
}

nonisolated struct MCPTestResult: Decodable, Sendable {
    var ok: Bool
    var tools: Int?
    var error: String?
}

nonisolated struct MCPAddResult: Decodable, Sendable {
    var server: CustomMCPServer?
    var oauth: MCPLoginLink?
    var test: MCPTestResult?
    var error: String?
}

nonisolated struct KeyValue: Codable, Hashable, Sendable {
    var key: String
    var value: String
}

nonisolated struct MCPAddRequest: Encodable, Sendable {
    var kind = "remote"
    var name: String?
    var url: String?
    /// auto | none | token | oauth
    var auth: String?
    var token: String?
    var header: String?
    var command: String?
    var args: [String]?
    /// Liste statt Dictionary: der JSON-Encoder (snake_case) würde Namen wie `API_KEY` umschreiben
    var env: [KeyValue]?
}

extension BotService {
    func mcpServers() async throws -> MCPServerList {
        throw APIError(status: 404, message: String(localized: "Dein Server kennt eigene MCP-Server noch nicht. Bitte den Server aktualisieren (ab 1.35)."))
    }
    func probeMCP(url: String) async throws -> MCPProbe { _ = try await mcpServers(); throw CancellationError() }
    func addMCP(_ request: MCPAddRequest) async throws -> MCPAddResult { _ = try await mcpServers(); throw CancellationError() }
    func updateMCP(id: String, name: String?, token: String?, header: String?) async throws -> MCPServerList { try await mcpServers() }
    func deleteMCP(id: String) async throws -> MCPServerList { try await mcpServers() }
    func loginMCP(id: String) async throws -> MCPLoginLink { _ = try await mcpServers(); throw CancellationError() }
    func testMCP(id: String) async throws -> MCPTestResult { _ = try await mcpServers(); throw CancellationError() }
    /// Freigabe-Karte mit sicherer Eingabe (Token, Umgebungswerte). Die Werte gehen nur mit dieser Anfrage an den Server.
    func decideSecrets(approvalID: String, approve: Bool, secrets: [KeyValue]) async throws -> Message {
        try await decide(approvalID: approvalID, approve: approve, note: nil)
    }
}

// MARK: - Loopback-Rücksprung

/// Hört während einer Anmeldung auf 127.0.0.1:<port> (nur Loopback) und meldet den ersten passenden Aufruf
/// (`GET <path>?code=…&state=…`). Antwortet dem Browser mit einer kurzen Seite. RFC 8252 §7.3.
final class LoopbackCatcher: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aisscoops.loopback")
    private var fired = false

    func start(port: UInt16, path: String, onURL: @escaping @Sendable (URL) -> Void) throws {
        stop()
        fired = false
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
                guard let self else { conn.cancel(); return }
                let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
                let target = parts.count >= 2 ? String(parts[1]) : ""
                let url = URL(string: "http://127.0.0.1:\(port)\(target)")
                let match = url.map { $0.path == path } ?? false
                let title = String(localized: "Angemeldet")
                let text = String(localized: "Du kannst dieses Fenster schließen und zu AIS Scoops zurückkehren.")
                let notFound = String(localized: "Nicht gefunden", comment: "Browserseite: falsche Rücksprung-Adresse")
                let html = match
                    ? "<html><meta charset=utf-8><body style='font-family:-apple-system;padding:40px'><h2>\(title)</h2>"
                        + "<p>\(text)</p></body></html>"
                    : "<html><body>\(notFound)</body></html>"
                let body = Data(html.utf8)
                let response = "HTTP/1.1 \(match ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                if match, let url, !self.fired {
                    self.fired = true
                    onURL(url)
                }
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit { listener?.cancel() }
}

// MARK: - Anmelden (OAuth)

/// Öffnet die Anmeldung eines eigenen MCP-Servers und gibt den Rücksprung an den Server. `nil` = Erfolg, sonst Fehlertext,
/// `""` = abgebrochen.
@MainActor
enum MCPLogin {
    static func run(_ link: MCPLoginLink, login: WebLoginSession, store: AppStore) async -> String? {
        if store.isMock { try? await Task.sleep(for: .milliseconds(600)); return nil }  // Demo: ohne Browser
        guard let url = URL(string: link.url) else { return String(localized: "Der Server hat keinen gültigen Anmelde-Link geliefert.") }
        let callback: URL? = await withCheckedContinuation { cont in
            if let port = link.loopbackPort, port > 0, port < 65536 {
                login.start(url: url, loopbackPort: UInt16(port), path: link.loopbackPath ?? "/oauth/mcp") { cont.resume(returning: $0) }
            } else {
                login.start(url: url, callbackScheme: link.callbackScheme ?? "aisscoops") { cont.resume(returning: $0) }
            }
        }
        guard let callback else { return "" }
        switch await store.finishOAuth(callback) {
        case .success: return nil
        case .failure(let e): return e.message
        }
    }
}

// MARK: - Bereich in „Apps verbinden“

struct CustomMCPSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var servers: [CustomMCPServer] = []
    @State private var loaded = false
    @State private var unsupported = false
    @State private var busyID: String?
    @State private var error: String?
    @State private var showAdd = false
    @State private var renameTarget: CustomMCPServer?
    @State private var tokenTarget: CustomMCPServer?
    @State private var deleteTarget: CustomMCPServer?
    @State private var input = ""
    @State private var login = WebLoginSession()
    var onToast: (String) -> Void = { _ in }

    private var args: [String] { ProcessInfo.processInfo.arguments }

    var body: some View {
        GroupedSection(String(localized: "Eigene MCP-Server"), footer: footer, dividerInset: 68) {
            if unsupported {
                GroupedLabelRow(icon: "arrow.triangle.2.circlepath", iconColor: theme.textSecondary,
                                title: "Server aktualisieren",
                                subtitle: "Eigene MCP-Server gibt es ab Server 1.35. Aktualisiere den Server in der App „AIS Scoops Server“.")
            } else {
                ForEach(servers) { row($0) }
                addButton
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) {
            MCPAddSheet { result in
                Task { await afterAdd(result) }
            }
            .environment(store)
            .environment(\.theme, theme)
        }
        .alert("MCP-Server umbenennen", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $input).autocorrectionDisabled()
            Button("Umbenennen") {
                if let t = renameTarget { let n = input; Task { await update(t, name: n, token: nil) } }
                renameTarget = nil
            }
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Unter diesem Namen kennen ihn die Scoops.")
        }
        .alert("Neues Token", isPresented: Binding(get: { tokenTarget != nil }, set: { if !$0 { tokenTarget = nil } })) {
            SecureField("Token", text: $input)
            Button("Speichern") {
                if let t = tokenTarget { let v = input; Task { await update(t, name: nil, token: v) } }
                input = ""
                tokenTarget = nil
            }
            Button("Abbrechen", role: .cancel) { input = ""; tokenTarget = nil }
        } message: {
            Text("Das Token geht direkt in den Schlüsselbund deines Servers. Die Scoops sehen es nie.")
        }
        .confirmationDialog(deleteTarget.map { t in String(localized: "„\(t.name)“ entfernen?") } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                if let t = deleteTarget { Task { await remove(t) } }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Die Scoops können seine Werkzeuge dann nicht mehr nutzen. Zugangsdaten werden auf dem Server gelöscht.")
        }
    }

    private var footer: String? {
        if unsupported { return nil }
        if let error { return error }
        return String(localized: "Werkzeuge, die etwas ändern, laufen immer über eine Freigabe-Karte. Du kannst einen Scoop auch bitten: „Verbinde den Qonto-MCP“.")
    }

    private var addButton: some View {
        Button {
            showAdd = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .appFont(16, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    .dynamicTypeSize(...AppFont.controlCap)
                    .frame(width: 40, height: 40)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("MCP-Server hinzufügen")
                    .appFont(15, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 0)
                if !loaded { ProgressView().controlSize(.small) }
            }
            .groupedRow(vertical: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(login.isActive)
        .accessibilityIdentifier("mcp.add")
    }

    private func row(_ s: CustomMCPServer) -> some View {
        // Große Schrift: Status, Anmelden und Menü unter Name und Beschreibung
        AdaptiveRow(spacing: 12, minSpacer: 6, trailingIndent: 52) {
            HStack(spacing: 12) {
                Image(systemName: s.kind == "stdio" ? "terminal.fill" : "server.rack")
                    .appFont(16, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .dynamicTypeSize(...AppFont.controlCap)
                    .frame(width: 40, height: 40)
                    .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).appFont(15).foregroundStyle(theme.textPrimary).adaptiveLineLimit(1)
                    Text(detail(s)).appFont(12)
                        .foregroundStyle(s.status == "ok" ? theme.textSecondary : (s.status == "login" ? theme.warning : theme.danger))
                        .adaptiveLineLimit(2)
                }
            }
        } trailing: {
            rowControls(s)
        }
        .groupedRow(vertical: 9)
    }

    @ViewBuilder private func rowControls(_ s: CustomMCPServer) -> some View {
        HStack(spacing: 12) {
            if busyID == s.id {
                ProgressView().controlSize(.small)
            } else if s.status == "login" {
                Button("Anmelden") { Task { await signIn(s) } }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    .disabled(login.isActive)
            } else if s.tools > 0 {
                Text("\(s.tools) Werkzeuge")
                    .appFont(12).foregroundStyle(theme.textTertiary).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            Circle().fill(dotColor(s.status)).frame(width: 9, height: 9)
                .overlay(Circle().fill(dotColor(s.status).opacity(0.25)).frame(width: 17, height: 17))
                .accessibilityLabel(s.status == "ok" ? "verbunden" : (s.status == "login" ? "Anmeldung nötig" : "Fehler"))
            Menu {
                Button { input = s.name; renameTarget = s } label: { Label("Umbenennen", systemImage: "pencil") }
                if s.auth == "oauth" {
                    Button { Task { await signIn(s) } } label: { Label("Neu anmelden", systemImage: "person.badge.key") }
                }
                if s.kind == "remote", s.auth != "oauth" {
                    Button { input = ""; tokenTarget = s } label: { Label(s.auth == "token" ? "Token ändern" : "Token eintragen", systemImage: "key") }
                }
                Button { Task { await test(s) } } label: { Label("Verbindung testen", systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) { deleteTarget = s } label: { Label("Entfernen", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .appFont(14, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aktionen für \(s.name)")
        }
    }

    private func detail(_ s: CustomMCPServer) -> String {
        switch s.status {
        case "login": return String(localized: "Anmeldung nötig · \(s.subtitle)")
        case "error": return s.error.map { e in String(localized: "Fehler: \(e)") } ?? String(localized: "Nicht erreichbar")
        default:
            let auth: String
            if s.kind == "stdio" {
                auth = String(localized: "Lokal", comment: "Eigener MCP-Server: lokaler Befehl auf dem Server-Mac")
            } else {
                switch s.auth {
                case "token": auth = "Token"
                case "oauth": auth = String(localized: "Angemeldet")
                default: auth = String(localized: "Ohne Anmeldung")
                }
            }
            return "\(auth) · \(s.subtitle)"
        }
    }

    private func dotColor(_ status: String) -> Color {
        switch status {
        case "ok": theme.success
        case "login": theme.warning
        default: theme.danger
        }
    }

    // MARK: Aktionen

    private func load() async {
        guard let service = store.service else { return }
        do {
            servers = try await service.mcpServers().servers
            unsupported = false
            error = nil
        } catch let e as APIError where e.status == 404 {
            unsupported = true
        } catch {
            self.error = store.message(error)
        }
        loaded = true
        #if DEBUG
        if store.isMock, args.contains("-mcpadd"), !showAdd { showAdd = true }
        #endif
    }

    private func afterAdd(_ result: MCPAddResult) async {
        await load()
        guard let server = result.server else { return }
        if let link = result.oauth {
            busyID = server.id
            let err = await MCPLogin.run(link, login: login, store: store)
            busyID = nil
            if let err, !err.isEmpty { error = err } else if err == nil { onToast(String(localized: "\(server.name) verbunden")) }
            await load()
        } else if result.test?.ok == true {
            let tools = result.test?.tools ?? 0
            onToast(String(localized: "\(server.name) verbunden · \(tools) Werkzeuge"))
        } else if let e = result.error ?? result.test?.error {
            error = "\(server.name): \(e)"
        }
    }

    private func signIn(_ s: CustomMCPServer) async {
        guard let service = store.service else { return }
        busyID = s.id
        defer { busyID = nil }
        do {
            let link = try await service.loginMCP(id: s.id)
            let err = await MCPLogin.run(link, login: login, store: store)
            if let err, !err.isEmpty { error = err } else if err == nil { onToast(String(localized: "Bei \(s.name) angemeldet")); error = nil }
        } catch {
            self.error = store.message(error)
        }
        await load()
    }

    private func update(_ s: CustomMCPServer, name: String?, token: String?) async {
        guard let service = store.service else { return }
        busyID = s.id
        defer { busyID = nil }
        do {
            servers = try await service.updateMCP(id: s.id, name: name?.trimmingCharacters(in: .whitespaces),
                                                 token: token?.trimmingCharacters(in: .whitespacesAndNewlines), header: nil).servers
            error = nil
        } catch {
            self.error = store.message(error)
        }
    }

    private func test(_ s: CustomMCPServer) async {
        guard let service = store.service else { return }
        busyID = s.id
        defer { busyID = nil }
        do {
            let r = try await service.testMCP(id: s.id)
            if r.ok {
                let tools = r.tools ?? 0
                onToast(String(localized: "\(s.name): \(tools) Werkzeuge"))
                error = nil
            } else {
                error = "\(s.name): \(r.error ?? String(localized: "Fehler"))"
            }
        } catch {
            self.error = store.message(error)
        }
        await load()
    }

    private func remove(_ s: CustomMCPServer) async {
        guard let service = store.service else { return }
        busyID = s.id
        defer { busyID = nil }
        do {
            servers = try await service.deleteMCP(id: s.id).servers
            onToast(String(localized: "\(s.name) entfernt"))
        } catch {
            self.error = store.message(error)
        }
    }
}

// MARK: - Hinzufügen

struct MCPAddSheet: View {
    var onAdded: (MCPAddResult) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum Auth: String, CaseIterable, Identifiable {
        case none, token, oauth
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: String(localized: "Keine", comment: "MCP-Server: Art der Anmeldung (keine)")
            case .token: "Token"
            case .oauth: String(localized: "Anmeldung (OAuth)")
            }
        }
        /// Kurz für die Segmente (iPhone-Breite)
        var short: String { self == .oauth ? String(localized: "Anmeldung", comment: "MCP-Server: Art der Anmeldung (Abschnitt bzw. Segment)") : title }
    }

    @State private var name = ""
    @State private var url = ""
    @State private var auth: Auth = .none
    @State private var detected: Auth?
    @State private var probing = false
    @State private var token = ""
    @State private var header = ""
    @State private var local = false
    @State private var command = ""
    @State private var arguments = ""
    @State private var env: [KeyValue] = []
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: String?

    private var cleanURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        if local { return !command.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let u = URL(string: cleanURL), u.scheme?.hasPrefix("http") == true, u.host() != nil else { return false }
        return auth != .token || !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("MCP-Server hinzufügen", icon: "server.rack", onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: GroupedMetrics.sectionSpacing) {
                    GroupedSection(footer: local ? nil : "Adresse des MCP-Servers (Streamable HTTP), z. B. https://mcp.qonto.com/mcp") {
                        field("Name", text: $name, placeholder: String(localized: "z. B. Qonto"), key: "name")
                        if !local {
                            field("Adresse", text: $url, placeholder: "https://…/mcp", key: "url", url: true)
                        }
                    }
                    if local {
                        localSection
                    } else {
                        authSection
                    }
                    Toggle(isOn: $local.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erweitert: lokaler Befehl").appFont(15).foregroundStyle(theme.textPrimary)
                            Text("Startet ein Programm auf dem Server-Mac (stdio), z. B. Atrium --mcp.")
                                .appFont(12).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, GroupedMetrics.rowInset)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .appFont(13.5).foregroundStyle(theme.textPrimary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.warning.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
                    }
                    Label("Zugangsdaten gehen direkt in den Schlüsselbund deines Servers. Werkzeuge, die etwas ändern, laufen immer über eine Freigabe-Karte.",
                          systemImage: "lock.fill")
                        .appFont(12.5).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, GroupedMetrics.rowInset)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            AdaptiveButtonRow(spacing: 10, stretchWhenStacked: true) {
                Button("Abbrechen") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button { submit() } label: {
                    if busy { ProgressView().controlSize(.small).tint(theme.sendButtonIcon) }
                    else { Text(!local && auth == .oauth ? "Weiter zur Anmeldung" : "Hinzufügen") }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!canSubmit || busy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mcp.submit")
            }
            // Fußzeile eines Blatts: wächst bis zur größten normalen Stufe mit, bleibt so in einer Zeile
            .dynamicTypeSize(...AppFont.controlCap)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 500, height: 640)
        #else
        .presentationDetents([.large])
        #endif
        .task(id: cleanURL) { await probe() }
        .onAppear {
            focus = "name"
            #if DEBUG
            let a = ProcessInfo.processInfo.arguments
            if store.isMock, let i = a.firstIndex(of: "-mcpaddurl"), i + 1 < a.count { url = a[i + 1]; name = "Qonto" }
            #endif
        }
        .onDisappear { token = ""; env = [] }
    }

    private var authSection: some View {
        GroupedSection(String(localized: "Anmeldung", comment: "MCP-Server: Art der Anmeldung (Abschnitt bzw. Segment)"), footer: authFooter) {
            Picker("Anmeldung", selection: $auth) {
                ForEach(Auth.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .groupedRow()
            if auth == .token {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token").appFont(12.5, weight: .semibold).foregroundStyle(theme.textSecondary)
                    SecureField("Token oder API-Schlüssel", text: $token)
                        .textFieldStyle(.plain).appFont(15.5)
                        .focused($focus, equals: "token")
                }
                .groupedRow(vertical: 11)
                field("Header (optional)", text: $header, placeholder: "Authorization", key: "header")
            }
        }
    }

    private var authFooter: String {
        if probing { return String(localized: "Prüfe, ob der Server eine Anmeldung braucht …") }
        let hint: String
        switch auth {
        case .none: hint = String(localized: "Der Server braucht keine Anmeldung.")
        case .token: hint = String(localized: "Das Token geht als „Authorization: Bearer …“ mit, oder unter dem angegebenen Header.")
        case .oauth: hint = String(localized: "Nach „Weiter“ meldest du dich beim Anbieter an. Die Scoops bekommen nur den Zugang, nie dein Passwort.")
        }
        return detected.map { d in String(localized: "Automatisch erkannt: \(d.title).") + " " + hint } ?? hint
    }

    private var localSection: some View {
        GroupedSection("Lokaler Befehl", footer: "Läuft auf dem Server-Mac mit dessen Rechten. Werte der Umgebungsvariablen gehen in den Schlüsselbund.") {
            field("Programm", text: $command, placeholder: "/Applications/Atrium.app/Contents/MacOS/Atrium", key: "command")
            field("Argumente", text: $arguments, placeholder: "--mcp", key: "args")
            ForEach(env.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("NAME", text: $env[i].key)
                        .textFieldStyle(.plain).appFont(14, design: .monospaced)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .frame(maxWidth: 140)
                    SecureField("Wert", text: $env[i].value).textFieldStyle(.plain).appFont(14)
                    Button { env.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(theme.textTertiary) }
                        .buttonStyle(.plain)
                }
                .groupedRow()
            }
            Button { env.append(KeyValue(key: "", value: "")) } label: {
                Label("Umgebungsvariable", systemImage: "plus").appFont(14, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .groupedRow()
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, key: String, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).appFont(12.5, weight: .semibold).foregroundStyle(theme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).appFont(15.5).foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
                #endif
                .focused($focus, equals: key)
        }
        .groupedRow(vertical: 11)
    }

    private func probe() async {
        guard !local, let u = URL(string: cleanURL), u.scheme?.hasPrefix("http") == true, u.host() != nil,
              let service = store.service else { detected = nil; return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        probing = true
        defer { probing = false }
        do {
            let p = try await service.probeMCP(url: cleanURL)
            guard !Task.isCancelled else { return }
            let a = Auth(rawValue: p.auth) ?? .none
            detected = a
            auth = a
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let n = p.name, !n.isEmpty {
                name = n.replacingOccurrences(of: " MCP", with: "")
            }
            error = nil
        } catch {
            detected = nil
            if !Task.isCancelled { self.error = store.message(error) }
        }
    }

    private func submit() {
        guard let service = store.service else { error = String(localized: "Keine Verbindung zum Server."); return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = MCPAddRequest(name: n.isEmpty ? nil : n)
        if local {
            req.kind = "stdio"
            req.command = command.trimmingCharacters(in: .whitespaces)
            req.args = arguments.split(separator: " ").map(String.init)
            req.env = env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            req.url = cleanURL
            req.auth = auth.rawValue
            if auth == .token {
                req.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                let h = header.trimmingCharacters(in: .whitespaces)
                req.header = h.isEmpty ? nil : h
            }
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await service.addMCP(req)
                token = ""
                env = []
                dismiss()
                onAdded(result)
            } catch {
                self.error = store.message(error)
            }
        }
    }
}
