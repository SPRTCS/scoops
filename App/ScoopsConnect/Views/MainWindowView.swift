import SwiftUI

/// Hauptfenster: Onboarding, solange nicht gekoppelt, danach die Einstellungen.
struct MainWindowView: View {
    let model: AppModel
    let server: ServerController
    @State private var forcedStep = LaunchOptions.shared.onboardingStep
    @State private var finishedOnboarding = false

    var body: some View {
        if server.isServer {
            ServerWindowView(controller: server)
        } else {
            connectBody
        }
    }

    private var connectBody: some View {
        connectContent
            .safeAreaInset(edge: .bottom) {
                if !model.isPaired && server.manager.isAvailable {
                    Button("Stattdessen eigenen AIS Scoops Server auf diesem Mac betreiben") { server.setRole(.server) }
                        .buttonStyle(.link)
                        .padding(.bottom, 10)
                }
            }
    }

    private var connectContent: some View {
        Group {
            if !model.isPaired || (forcedStep != nil && !finishedOnboarding) {
                OnboardingView(model: model, initialStep: forcedStep ?? 1) { finishedOnboarding = true; forcedStep = nil }
            } else {
                SettingsView(model: model)
            }
        }
        .frame(width: 560)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Int
    @State private var server = ""
    @State private var code = ""
    @State private var name = AppModel.defaultName
    @State private var mode: AppModel.Mode = .direct
    @State private var pairing = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case server, code, name }

    init(model: AppModel, initialStep: Int, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        _step = State(initialValue: max(1, min(3, initialStep)))
        _server = State(initialValue: PairingPrefill.shared.server ?? model.serverURL)
        _code = State(initialValue: PairingPrefill.shared.code ?? "")
        _mode = State(initialValue: model.isPaired ? model.mode : LaunchOptions.shared.fakeMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 1: connectStep
                case 2: modeStep
                default: setupStep
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            Divider()
            footer
        }
        .onAppear { if step == 1 { focus = server.isEmpty ? .server : .code } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView(size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scoops Connect").font(.title2.weight(.semibold))
                Text("Diesen Mac als Rechner für deine Scoops anschließen")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StepIndicator(step: step)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Mit dem Server verbinden").font(.headline)
            Text("Öffne in AIS Scoops **Einstellungen → Rechner → Rechner hinzufügen** und gib den angezeigten Code hier ein. Er gilt 10 Minuten.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Server-Adresse", text: $server, prompt: Text(verbatim: "https://dein-server.example"))
                    .focused($focus, equals: .server)
                TextField("Code", text: $code, prompt: Text(verbatim: "K7QX-29PL"))
                    .font(.body.monospaced())
                    .focused($focus, equals: .code)
                    .onSubmit(next)
                TextField("Name dieses Macs", text: $name)
                    .focused($focus, equals: .name)
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            errorView
        }
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. Wie sollen die Scoops diesen Mac nutzen?").font(.headline)
            ForEach(AppModel.Mode.allCases) { m in
                ModeCard(mode: m, selected: mode == m) { mode = m }
            }
            Text("Das lässt sich später in den Einstellungen ändern.")
                .font(.caption)
                .foregroundStyle(.secondary)
            errorView
        }
    }

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mode == .direct {
                Text("3. Berechtigungen erteilen").font(.headline)
                Text("macOS fragt einmalig nach zwei Rechten. Scoops Connect erteilt sie nie selbst.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                PermissionsSection(model: model)
            } else {
                Text("3. Virtuelle Maschine einrichten").font(.headline)
                VMSetupView(model: model)
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if step > 1 && step < 3 {
                Button("Zurück") { error = nil; step -= 1 }
            }
            Spacer()
            if pairing { ProgressView().controlSize(.small) }
            switch step {
            case 1:
                Button("Weiter", action: next)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Pairing.normalizeServer(server) == nil || code.filter { $0.isLetter || $0.isNumber }.count < 8)
            case 2:
                Button(model.isPaired ? "Weiter" : "Koppeln") { Task { await pair() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pairing)
            default:
                Button("Fertig") {
                    onFinish()
                    dismissWindow(id: WindowID.main)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func next() {
        guard Pairing.normalizeServer(server) != nil else { error = "Bitte eine gültige Server-Adresse eingeben."; return }
        error = nil
        step = 2
    }

    private func pair() async {
        if model.isPaired {
            model.setMode(mode)
            step = 3
            return
        }
        pairing = true
        defer { pairing = false }
        do {
            try await model.pair(server: server, code: code, name: name, mode: mode)
            error = nil
            PairingPrefill.shared.code = nil
            step = 3
        } catch {
            self.error = error.localizedDescription
            if case Pairing.Failure.invalidCode = error { step = 1 }
        }
    }
}

private struct StepIndicator: View {
    let step: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: i == step ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement()
        .accessibilityLabel("Schritt \(step) von 3")
    }
}

// MARK: - Einstellungen

struct SettingsView: View {
    let model: AppModel
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconView(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scoops Connect").font(.title3.weight(.semibold))
                        Text("Version \(AppModel.appVersion) · \(AppModel.osString)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Verbindung") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(color: model.statusColor)
                        Text(model.statusTitle)
                    }
                }
                if let d = model.statusDetail, model.linkState != .connected {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Server", value: model.serverURL)
                LabeledContent("Rechner-ID", value: model.nodeID.isEmpty ? "–" : model.nodeID)
                TextField("Name", text: $name)
                    .onSubmit { model.nodeName = name; model.reconnectNow() }
                HStack {
                    Button("Neu verbinden") { model.nodeName = name; model.reconnectNow() }
                    Spacer()
                    Button("Rechner trennen …", role: .destructive) { confirmUnpair(model) }
                }
            }

            Section("Modus") {
                Picker("Modus", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(AppModel.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if model.mode == .direct {
                Section("Berechtigungen") { PermissionsSection(model: model) }
            } else {
                Section("Virtuelle Maschine") { VMSetupView(model: model) }
            }

            Section("Apple-Dienste") { AppleServicesSection(model: model) }

            Section("Allgemein") {
                Toggle("Pausieren (Scoops dürfen gerade nichts tun)", isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
                Toggle("Beim Anmelden starten", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onAppear { name = model.nodeName }
    }
}
