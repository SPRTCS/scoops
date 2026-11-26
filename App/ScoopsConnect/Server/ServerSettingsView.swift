import AppKit
import SwiftUI

/// Hauptfenster in der Server-Rolle: Einrichtung, solange sie nicht abgeschlossen ist, danach die Einstellungen.
struct ServerWindowView: View {
    let controller: ServerController
    @State private var setupStep: SetupStep?
    private let request = SetupRequest.shared

    init(controller: ServerController) {
        self.controller = controller
        // Startargument `-setupstep N` (Screenshots), sonst eine angefangene Einrichtung dort fortsetzen, wo sie war.
        let resume = controller.setupDone ? nil
            : (controller.savedSetupStep.flatMap(SetupStep.init(rawValue:)) ?? .welcome)
        _setupStep = State(initialValue: LaunchOptions.shared.setupStep.flatMap(SetupStep.init(rawValue:)) ?? resume)
    }

    var body: some View {
        Group {
            if let step = setupStep ?? (controller.setupDone ? nil : .welcome) {
                ServerSetupView(controller: controller, initialStep: step) { setupStep = nil }
                    .id(step)
            } else {
                ServerSettingsView(controller: controller) { setupStep = $0 }
            }
        }
        .onChange(of: request.step, initial: true) { _, s in
            guard let s else { return }
            setupStep = s
            request.step = nil
        }
    }
}

/// „Einrichtung erneut öffnen“ aus dem Menüleisten-Fenster: Das Hauptfenster zeigt dann den Assistenten.
@Observable
final class SetupRequest {
    static let shared = SetupRequest()
    var step: SetupStep?
}

struct ServerSettingsView: View {
    @Bindable var controller: ServerController
    let openSetup: (SetupStep) -> Void
    @State private var userName = ""
    @State private var confirmDisableAgent = false
    @State private var agentMessage: String?

    private var m: ServerManager { controller.manager }
    private var model: AppModel { controller.model }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconView(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AIS Scoops Server").font(.title3.weight(.semibold))
                        Text("App \(AppModel.appVersion) · \(AppModel.osString)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.test { Text("TESTMODUS").font(.caption.bold()).foregroundStyle(.orange) }
                }
            }

            Section("Server") {
                ServerStatusLine(manager: m)
                if case .failed(let msg) = m.phase { Text(msg).font(.caption).foregroundStyle(.red) }
                if let c = m.portConflict {
                    InfoBox(style: .warning, text: "\(c.summary)")
                }
                if controller.oldAgentInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoBox(style: .info, text: "Auf diesem Mac ist noch eine **ältere AIS-Bot-Installation** eingerichtet (Hintergrunddienst „\(OldAISBotAgent.label)“). Sie startet bei jeder Anmeldung einen eigenen Server, der Port 8787 belegen kann.")
                        HStack {
                            Button("Alte Installation deaktivieren …") { confirmDisableAgent = true }
                                .disabled(controller.test)
                            if controller.test { Text("(im Testmodus gesperrt)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let agentMessage { Text(agentMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let note = controller.repairNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let e = m.lastError, !e.isEmpty { Text(e).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3) }
                LabeledContent("Datenordner") { Text(m.setup.home.path).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                HStack {
                    Button("Neu starten") { m.restart(); controller.applyKeepAwake() }
                    if m.phase == .stopped {
                        Button("Starten") { m.start(); controller.applyKeepAwake() }
                    } else {
                        Button("Stoppen") { m.stop(); controller.applyKeepAwake() }
                    }
                    Spacer()
                    Button("Protokoll öffnen") { m.openLogs() }
                    Button("Im Finder zeigen") { m.revealData() }
                }
            }

            Section("Konto") {
                LabeledContent("Status") {
                    if m.linked, let owner = m.ownerName {
                        Text("Verbunden (\(owner))", comment: "Konto: verbunden, mit Name des Kontos")
                    } else {
                        Text(m.linked ? "Verbunden" : "Nicht verbunden")
                    }
                }
                if let e = m.cloudError, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.orange) }
                LabeledContent("Mitteilungen") { Text(m.pushSummary) }
                if let e = m.pushError, !e.isEmpty, m.linked { Text(e).font(.caption).foregroundStyle(.orange) }
                HStack {
                    TextField("Ansprache (Vorname)", text: $userName)
                        .onSubmit { save(["user_name": userName]) }
                    Button("Speichern") { save(["user_name": userName]) }
                }
                Button(m.linked ? "Mit anderem Konto verbinden …" : "Mit Konto verbinden …") { openSetup(.account) }
            }

            WorkspaceSection(manager: m)
            FullDiskAccessSection(manager: m)
            AbosSection(manager: m)

            Section("KI-Schlüssel") {
                KeysStep(controller: controller)
            }

            Section("Dieser Mac als Rechner") {
                if controller.thisMacRegistered {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            StatusDot(color: model.statusColor)
                            Text(controller.test ? String(localized: "Gekoppelt (Testmodus, nicht verbunden)") : model.statusLine)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if !controller.test, model.linkState != .connected {
                        HStack {
                            Text("Verbindet mit \(model.serverURL)").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Jetzt verbinden") { Task { await controller.serverDidStart(); model.reconnectNow() } }
                        }
                    }
                    Toggle("Pausieren (Scoops dürfen gerade nichts tun)",
                           isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
                    PermissionsSection(model: model)
                } else {
                    Button("Diesen Mac anschließen …") { openSetup(.mac) }
                }
            }

            if controller.thisMacRegistered {
                Section("Apple-Dienste") { AppleServicesSection(model: model) }
            }

            Section("Erreichbarkeit") {
                LabeledContent("Adresse") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(m.publicURL.isEmpty ? String(localized: "nur auf diesem Mac") : m.publicURL).textSelection(.enabled)
                        Text(controller.reachabilityKind).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !m.lanURL.isEmpty, m.lanURL != m.publicURL {
                    LabeledContent("Heim-WLAN") { Text(m.lanURL).textSelection(.enabled) }
                }
                LabeledContent("Lokal") { Text(m.baseURL.absoluteString).textSelection(.enabled) }
                if controller.tailscaleChecked {
                    if controller.tailscaleEntries.isEmpty {
                        LabeledContent("Tailscale") { Text("keine Freigabe aktiv").foregroundStyle(.secondary) }
                    } else {
                        ForEach(controller.tailscaleEntries) { e in
                            LabeledContent(e.funnel ? "Tailscale Funnel" : "Tailscale Serve" as String) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(e.url) → \(e.target)").textSelection(.enabled)
                                    if let tp = e.targetPort, tp != m.port, e.url == m.publicURL || e.url == m.tailnetURL {
                                        Text("zeigt auf Port \(String(tp)), der Server läuft auf \(String(m.port))").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
                if !m.publicURL.isEmpty, !m.publicURL.hasPrefix("https://") {
                    Text("Diese Adresse funktioniert nur, wenn das iPhone im selben WLAN ist. Für unterwegs: „Erreichbarkeit einrichten …“ → Tailscale.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Erreichbarkeit einrichten …") { openSetup(.reach) }
                    Button("Öffentliche Adresse kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.publicURL, forType: .string)
                    }
                    .disabled(m.publicURL.isEmpty)
                    Spacer()
                    Button("Tailscale prüfen") { Task { await controller.repairTailscale() } }
                }
            }

            Section("Dauerbetrieb") {
                Toggle("Mac wach halten, solange der Server läuft", isOn: $controller.keepSystemAwake)
                Toggle("Bildschirm anlassen", isOn: $controller.keepDisplayAwake)
                if LidAwake.hasLid { LidAwakeRow(disabled: controller.test) }
                Button("Weitere Tipps …") { openSetup(.awake) }
            }

            Section("Allgemein") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Button("Einrichtung erneut öffnen") { openSetup(.welcome) }
            }

            if AppUpdater.shared.isAvailable {
                Section("Updates") {
                    LabeledContent("Version", value: AppModel.appVersion)
                    Group {
                        if let v = AppUpdater.shared.pendingVersion {
                            Text("Update \(v) ist geladen und wird installiert, sobald kein Scoop arbeitet.")
                        } else {
                            Text("Neue Versionen werden automatisch geladen und installiert, sobald kein Scoop arbeitet. Der Server startet danach von selbst neu.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Button("Nach Updates suchen …") { AppUpdater.shared.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 620)
        .onAppear { userName = m.userName ?? "" }
        .task { if !controller.test { await controller.repairTailscale() } }
        .alert("Ältere AIS-Bot-Installation deaktivieren?", isPresented: $confirmDisableAgent) {
            Button("Deaktivieren") {
                agentMessage = controller.disableOldAgent()
                    ?? String(localized: "✓ Deaktiviert. Die Datei heißt jetzt „\(OldAISBotAgent.label).plist.deaktiviert“; Daten unter ~/.local/share/ais-bot bleiben erhalten.")
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Hintergrunddienst „\(OldAISBotAgent.label)“ wird gestoppt und startet nicht mehr bei der Anmeldung. Gelöscht wird nichts: Die Startdatei in ~/Library/LaunchAgents wird nur umbenannt, die Daten bleiben. Rückgängig: Datei zurückbenennen und neu anmelden.")
        }
    }

    private func save(_ values: [String: Any]) {
        Task { try? await m.patchConfig(values) }
    }
}

/// Menüleisten-Abschnitt in der Server-Rolle: Status, Konto, Adresse, Neustart, Protokoll.
struct ServerMenuSection: View {
    let controller: ServerController
    private var m: ServerManager { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(color: m.dotColor)
                Text(m.statusTitle).font(.caption.weight(.medium))
                if let v = m.version { Text("· \(v)").font(.caption).foregroundStyle(.tertiary) }
            }
            Group {
                if m.linked, let owner = m.ownerName {
                    Text("Konto: \(owner)")
                } else if m.linked {
                    Text("Konto: verbunden")
                } else {
                    Text("Noch nicht mit einem Konto verbunden")
                }
            }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if m.linked { Text("Mitteilungen: \(m.pushSummary)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Text(m.publicURL.isEmpty ? String(localized: "Nur auf diesem Mac erreichbar") : m.publicURL)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !controller.setupDone {
                Text("Einrichtung noch nicht abgeschlossen").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
