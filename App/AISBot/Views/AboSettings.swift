import SwiftUI

// KI-Abos (Server 1.30, docs/abos.md): Die Scoops können über ein Claude- bzw. ChatGPT-Abo arbeiten statt über
// API-Schlüssel. Angemeldet wird nur in den offiziellen Programmen (Claude Code, Codex) auf dem Server-Mac; die App zeigt
// den Status, stellt den Abrechnungsmodus pro Anbieter ein und kann den Login am Server-Mac starten (Terminal-Fenster).

nonisolated struct AboStatus: Decodable, Sendable, Equatable {
    var claude: AboProviderStatus?
    var openai: AboProviderStatus?
    /// Server 1.36: Computer Use von Codex für ChatGPT-Scoops (fehlt bei älteren Servern → Schalter ausgeblendet)
    var codexComputerUse: CodexComputerUseStatus?
}

/// Computer Use von Codex (docs/computer.md): ChatGPT-Scoops bedienen den Server-Mac mit Codex statt über den
/// Scoops-Bildschirm. `available` = App da und nutzbar; sonst `reason` (kurz) und `hint` (wie einrichten).
nonisolated struct CodexComputerUseStatus: Decodable, Sendable, Equatable {
    var supported: Bool?
    var enabled: Bool
    var installed: Bool?
    var available: Bool?
    var reason: String?
    var hint: String?
}

nonisolated struct AboProviderStatus: Decodable, Sendable, Equatable {
    var label: String?
    var mode: String
    var modeLabel: String?
    var loggedIn: Bool?
    var subscription: Bool?
    var installed: Bool?
    var apiKey: Bool?
    var plan: String?
    var limit: Limit?
    var usage: UsageInfo?

    nonisolated struct Limit: Decodable, Sendable, Equatable {
        var reason: String?
        var until: String?
    }

    nonisolated struct UsageInfo: Decodable, Sendable, Equatable {
        var status: String?
        var window: String?
        var utilization: Double?
        var resetsAt: String?
    }
}

enum AboMode: String, CaseIterable, Identifiable {
    case api, abo, aboApi = "abo_api"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .api: String(localized: "API-Schlüssel")
        case .abo: String(localized: "Abo", comment: "Abrechnungsmodus: nur über das KI-Abo")
        case .aboApi: String(localized: "Abo, bei Limit API")
        }
    }
    var detail: String {
        switch self {
        case .api: String(localized: "Kosten über deinen API-Schlüssel")
        case .abo: String(localized: "Nur über das Abo, am Limit mit Hinweis anhalten")
        case .aboApi: String(localized: "Über das Abo, am Limit mit Hinweis über den API-Schlüssel")
        }
    }
}

extension BotService {
    func abos() async throws -> AboStatus {
        throw APIError(status: 404, message: String(localized: "Der Server kennt KI-Abos noch nicht (ab Server 1.30)."))
    }
    func setAboMode(provider: String, mode: String) async throws -> AboStatus { try await abos() }
    func startAboLogin(provider: String) async throws { _ = try await abos() }
    func setCodexComputerUse(_ enabled: Bool) async throws -> AboStatus { try await abos() }
}

/// Nur beim Start mit `-mock` (Simulator, UI-Tests): KI-Abos mit Beispielwerten. Der Demo-Modus in der App bleibt ohne.
extension MockService {
    private static var mockAboModes = ["claude": "abo_api", "openai": "abo_api"]
    private static var mockCodexCU = true
    private var mockAbosEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-mock") }

    func abos() async throws -> AboStatus {
        guard mockAbosEnabled else {
            throw APIError(status: 404, message: String(localized: "Der Server kennt KI-Abos noch nicht (ab Server 1.30)."))
        }
        func provider(_ id: String, _ label: String, _ plan: String) -> AboProviderStatus {
            let mode = Self.mockAboModes[id] ?? "api"
            return AboProviderStatus(label: label, mode: mode, modeLabel: AboMode(rawValue: mode)?.title, loggedIn: true,
                                     subscription: true, installed: true, apiKey: true, plan: plan, limit: nil,
                                     usage: .init(status: "allowed", window: "five_hour", utilization: 0.18, resetsAt: nil))
        }
        return AboStatus(claude: provider("claude", "Claude (Claude Code)", "max"),
                         openai: provider("openai", "ChatGPT (Codex)", "pro"),
                         codexComputerUse: CodexComputerUseStatus(supported: true, enabled: Self.mockCodexCU, installed: true,
                                                                  available: true, reason: nil, hint: nil))
    }

    func setAboMode(provider: String, mode: String) async throws -> AboStatus {
        Self.mockAboModes[provider] = mode
        return try await abos()
    }

    func startAboLogin(provider: String) async throws { _ = try await abos() }

    func setCodexComputerUse(_ enabled: Bool) async throws -> AboStatus {
        Self.mockCodexCU = enabled
        return try await abos()
    }
}

/// Einstellungen → „KI-Abos“ (nur Admin, ab Server 1.30).
struct AboSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var status: AboStatus?
    @State private var unavailable = false
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        if !unavailable {
            GroupedSection(String(localized: "KI-Abos"), footer: footer) {
                if let status {
                    if let c = status.claude { providerRows("claude", "Claude", "sparkles", c) }
                    if let o = status.openai { providerRows("openai", "ChatGPT", "bubble.left.and.bubble.right", o) }
                    if let cu = status.codexComputerUse, cu.supported != false, status.openai != nil {
                        codexComputerUseRow(cu)
                    }
                } else {
                    GroupedLabelRow(icon: "creditcard", iconColor: theme.textSecondary, title: "Wird geladen …")
                }
            }
            .task { await load() }
        }
    }

    private var footer: String {
        var t = String(localized: "Mit einem Claude- oder ChatGPT-Abo laufen Chat, Aufgaben und Routinen über Claude Code bzw. Codex auf dem Server-Mac statt über den API-Schlüssel. Angemeldet wird im Programm selbst; die App sieht keine Anmeldedaten. Sprechmodus und Diktat nutzen weiter den Schlüssel, Bilder entstehen nur über das ChatGPT-Abo.")
        if let message { t = message + "\n\n" + t }
        return t
    }

    @ViewBuilder
    private func providerRows(_ id: String, _ title: String, _ icon: String, _ st: AboProviderStatus) -> some View {
        let mode = AboMode(rawValue: st.mode) ?? .api
        let program = id == "claude" ? "Claude Code" : "Codex"
        GroupedLabelRow(icon: icon, iconColor: st.subscription == true ? theme.accent : theme.textSecondary, title: title,
                        subtitle: subtitle(st)) {
            Button(st.subscription == true ? "Neu anmelden" : "Anmelden") { Task { await login(id, title) } }
                .appFont(14, weight: .medium)
                .disabled(busy || st.installed == false)
                .accessibilityHint("Öffnet auf dem Server-Mac die Anmeldung von \(program)")
        }
        Menu {
            ForEach(AboMode.allCases) { m in
                Button { Task { await set(id, m) } } label: {
                    if m == mode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        } label: {
            GroupedLabelRow(icon: "arrow.triangle.branch", iconColor: theme.accent, title: mode.title, subtitle: mode.detail) {
                Image(systemName: "chevron.up.chevron.down").appFont(11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): Abrechnung \(mode.title)")
    }

    /// Schalter „Computer Use von Codex“ (Server 1.36). Ältere Server liefern das Feld nicht; dann gibt es keinen Schalter.
    @ViewBuilder
    private func codexComputerUseRow(_ cu: CodexComputerUseStatus) -> some View {
        GroupedLabelRow(icon: "cursorarrow.click.2", iconColor: cu.enabled ? theme.accent : theme.textSecondary,
                        title: String(localized: "Computer Use von Codex"), subtitle: codexComputerUseSubtitle(cu)) {
            Toggle("Computer Use von Codex", isOn: Binding(get: { cu.enabled }, set: { on in
                Task { await setCodexComputerUse(on) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.accent)
            .disabled(busy)
        }
        .accessibilityHint("ChatGPT-Scoops bedienen den Server-Mac mit dem Computer Use von Codex")
    }

    private func codexComputerUseSubtitle(_ cu: CodexComputerUseStatus) -> String {
        let base = String(localized: "ChatGPT-Scoops im Abo bedienen den Server-Mac selbst mit Codex statt über den Scoops-Bildschirm. Gilt nur für Scoops, die am Server-Mac arbeiten; jede App gibst du einmal per Karte frei.")
        guard cu.enabled, cu.available == false else { return base }
        return (cu.hint ?? cu.reason.map { reason in String(localized: "Gerade nicht nutzbar: \(reason).") } ?? base)
    }

    private func setCodexComputerUse(_ on: Bool) async {
        guard let service = store.service else { return }
        busy = true
        defer { busy = false }
        do { status = try await service.setCodexComputerUse(on) } catch {
            message = error.localizedDescription
        }
    }

    private func subtitle(_ st: AboProviderStatus) -> String {
        var parts: [String] = []
        if st.subscription == true {
            if let plan = st.plan.map({ $0.prefix(1).uppercased() + $0.dropFirst() }) {
                parts.append(String(localized: "Angemeldet · \(plan)", comment: "KI-Abo: angemeldet mit Tarif, z. B. „Angemeldet · Max“"))
            } else {
                parts.append(String(localized: "Angemeldet"))
            }
        } else if st.loggedIn == true {
            parts.append(String(localized: "Angemeldet, aber ohne Abo"))
        } else {
            parts.append(String(localized: "Nicht angemeldet"))
        }
        if let lim = st.limit, let until = lim.until, let d = ISO8601DateFormatter().date(from: until) {
            let time = d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.app))
            parts.append(String(localized: "Limit erreicht, API bis \(time)"))
        } else if let u = st.usage?.utilization {
            let percent = String(Int((u * 100).rounded()))
            parts.append(String(localized: "Auslastung \(percent) %"))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let service = store.service else { unavailable = true; return }
        do { status = try await service.abos() } catch { unavailable = true }
    }

    private func set(_ provider: String, _ mode: AboMode) async {
        guard let service = store.service else { return }
        busy = true
        defer { busy = false }
        do { status = try await service.setAboMode(provider: provider, mode: mode.rawValue) } catch {
            message = error.localizedDescription
        }
    }

    private func login(_ provider: String, _ title: String) async {
        guard let service = store.service else { return }
        busy = true
        defer { busy = false }
        do {
            try await service.startAboLogin(provider: provider)
            message = String(localized: "Auf dem Server-Mac ist ein Terminal-Fenster mit der Anmeldung bei \(title) offen. Dort bzw. im Browser anmelden.")
            for _ in 0..<45 {
                try? await Task.sleep(for: .seconds(4))
                if let s = try? await service.abos() {
                    status = s
                    if (provider == "claude" ? s.claude : s.openai)?.subscription == true { message = nil; break }
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
