import SwiftUI

/// Inhalt des Menüleisten-Fensters: Status, Hinweis „Scoop steuert“, Pause, Einstellungen, Trennen, Beenden.
struct MenuPanel: View {
    let model: AppModel
    let server: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if server.isServer {
                ServerMenuSection(controller: server)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if model.isControlled {
                controlBanner
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 10)

            if server.isServer {
                serverRows.padding(6)
                Divider().padding(.horizontal, 10)
            }

            VStack(spacing: 2) {
                if model.isPaired {
                    MenuRow(title: model.paused ? "Fortsetzen" : "Pausieren",
                            symbol: model.paused ? "play.fill" : "pause.fill") {
                        model.setPaused(!model.paused)
                    }
                    if model.mode == .vm {
                        vmLine
                    }
                }
                MenuRow(title: server.isServer ? (server.setupDone ? "Einstellungen …" : "Einrichtung fortsetzen …")
                                               : (model.isPaired ? "Einstellungen …" : "Rechner koppeln …"),
                        symbol: "gearshape") {
                    openWindow(id: WindowID.main)
                    NSApp.activate()
                }
                if server.isServer && server.setupDone {
                    MenuRow(title: "Einrichtung erneut öffnen …", symbol: "wand.and.sparkles") {
                        SetupRequest.shared.step = .welcome
                        openWindow(id: WindowID.main)
                        NSApp.activate()
                    }
                }
                if model.isPaired && !server.isServer {
                    MenuRow(title: "Rechner trennen …", symbol: "xmark.circle", destructive: true) {
                        confirmUnpair(model)
                    }
                }
                if AppUpdater.shared.isAvailable {
                    MenuRow(title: "Nach Updates suchen …", symbol: "arrow.down.circle") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
            }
            .padding(6)

            Divider().padding(.horizontal, 10)

            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark").frame(width: 18)
                    Text("Beim Anmelden starten")
                    Spacer()
                    Toggle("Beim Anmelden starten",
                           isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                MenuRow(title: server.isServer ? "Beenden (stoppt den Server)" : "Scoops Connect beenden", symbol: "power") {
                    NSApp.terminate(nil)
                }
                versionLine
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    /// App-Version; wartet ein geladenes Update auf eine ruhige Minute, steht das dahinter.
    private var versionLine: some View {
        Group {
            if let v = AppUpdater.shared.pendingVersion {
                Text("Version \(AppModel.appVersion) · Update \(v) wird installiert, sobald kein Scoop arbeitet")
            } else {
                Text("Version \(AppModel.appVersion)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var serverRows: some View {
        VStack(spacing: 2) {
            MenuRow(title: "Server neu starten", symbol: "arrow.clockwise") {
                server.manager.restart()
                server.applyKeepAwake()
            }
            MenuRow(title: "Protokoll öffnen", symbol: "doc.text.magnifyingglass") { server.manager.openLogs() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.isServer ? "AIS Scoops Server" : (model.isPaired ? model.nodeName : "Scoops Connect"))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: model.statusColor)
                    Text(headerStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isPaired {
                        Text("· \(model.mode.short)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let d = model.statusDetail {
                    Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var controlBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.motionlines")
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.controlTitle).font(.callout.weight(.semibold))
                Text("Bitte Maus und Tastatur nicht benutzen.")
                    .font(.caption2)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.gradient))
        .accessibilityElement(children: .combine)
    }

    private var vmLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").frame(width: 18).foregroundStyle(.secondary)
            Text(vmStatus).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Zweite Zeile im Kopf: in der Server-Rolle der Zustand von „Dieser Mac“ als Rechner
    private var headerStatus: String {
        guard server.isServer else { return model.statusTitle }
        guard server.thisMacRegistered else { return String(localized: "Rechner: nicht angeschlossen") }
        return server.test ? String(localized: "Rechner: Test") : String(localized: "Rechner: \(model.statusTitle)")
    }

    private var vmStatus: String {
        let name = model.vmName.isEmpty ? String(localized: "Keine VM gewählt") : model.vmName
        switch model.lume.phase {
        case .ready: return String(localized: "\(name): bereit", comment: "Zustand der VM")
        case .working: return String(localized: "\(name): startet …", comment: "Zustand der VM")
        case .failed: return String(localized: "\(name): Fehler", comment: "Zustand der VM")
        case .idle: return name
        }
    }
}

/// Menüähnliche Zeile mit Hover-Hervorhebung.
private struct MenuRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .foregroundStyle(hovering ? Color.white : (destructive ? Color.red : Color.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        // In der Screenshot-Vorschau keine Hervorhebung durch den zufällig dort stehenden Mauszeiger.
        .onHover { hovering = $0 && !LaunchOptions.shared.menuPreview }
    }
}
