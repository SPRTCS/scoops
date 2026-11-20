import AppKit
import SwiftUI

// Schritte 3 bis 6 des Einrichtungsassistenten (ServerSetupView.swift). KeysStep, KeyRow, ReachStep und AwakeStep
// nutzen auch die Einstellungen.

/// Kommt der Nutzer aus den Systemeinstellungen (oder Tailscale, Terminal …) zurück, prüft der Assistent sofort neu.
private extension View {
    func onAppBecomesActive(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in action() }
    }
}

// MARK: - 3. KI-Zugang

struct AccessStep: View {
    let controller: ServerController
    enum Choice: Hashable { case abo, key }
    @State private var choice: Choice

    init(controller: ServerController, choice: Choice? = nil) {
        self.controller = controller
        let hasKey = controller.modelKey(.anthropic) || controller.modelKey(.openai)
        _choice = State(initialValue: choice ?? (hasKey ? .key : .abo))
    }

    private var m: ServerManager { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Du hast zwei Möglichkeiten. **Eine davon reicht.**")
            Picker("Weg zum KI-Modell", selection: $choice) {
                Text("Mit meinem KI-Abo").tag(Choice.abo)
                Text("Mit API-Schlüssel").tag(Choice.key)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            switch choice {
            case .abo: aboContent
            case .key: keyContent
            }

            statusBox
        }
        .onAppBecomesActive { Task { await m.refreshAbos(force: true); await m.refresh() } }
    }

    private var aboContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hast du **Claude Pro oder Max** oder **ChatGPT Plus oder Pro**, arbeiten deine Scoops über dein Abo. Das kostet nichts extra, zählt aber auf die Limits deines Abos.")
                .fixedSize(horizontal: false, vertical: true)
            AbosView(manager: m, compact: true)
            HelpDisclosure(title: "Wo bekomme ich ein Abo, und wie melde ich mich an?") {
                Text("1. Abo abschließen: **Claude** unter claude.ai (Pro oder Max) oder **ChatGPT** unter chatgpt.com (Plus oder Pro).")
                Text("2. Hier auf **Mit Claude anmelden** bzw. **Mit ChatGPT anmelden** klicken. Ein Terminal-Fenster öffnet die offizielle Anmeldung, meist geht dazu der Browser auf.")
                Text("3. Im Browser anmelden und bestätigen. Der Stand hier aktualisiert sich von selbst, sobald du zurückkommst.")
                Text("AIS Scoops sieht deine Anmeldedaten nie, sie bleiben im Programm des Anbieters (Claude Code bzw. Codex).")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Link("claude.ai öffnen", destination: URL(string: "https://claude.ai/upgrade")!)
                    Link("chatgpt.com öffnen", destination: URL(string: "https://chatgpt.com/#pricing")!)
                }
            }
        }
    }

    private var keyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mit einem eigenen Schlüssel zahlst du direkt beim Anbieter, was deine Scoops verbrauchen. Eine normale Chat-Antwort kostet meist weniger als einen Cent.")
                .fixedSize(horizontal: false, vertical: true)
            KeyRow(controller: controller, kind: .anthropic, badge: "Empfohlen",
                   help: "Für Claude-Modelle. Der Schlüssel beginnt mit „sk-ant-“.",
                   link: "https://console.anthropic.com/settings/keys",
                   guide: ["Auf console.anthropic.com anmelden oder ein Konto anlegen.",
                           "Unter **Billing** Guthaben aufladen, zum Beispiel 10 $, und am besten ein Monatslimit setzen.",
                           "Unter **API Keys** auf **Create Key** klicken, den Schlüssel kopieren und hier einfügen."])
            KeyRow(controller: controller, kind: .openai, badge: "Optional",
                   help: "Für GPT-Modelle und Diktat.",
                   link: "https://platform.openai.com/api-keys",
                   guide: ["Auf platform.openai.com anmelden.",
                           "Unter **Billing** Guthaben aufladen.",
                           "Unter **API keys** auf **Create new secret key** klicken und den Schlüssel hier einfügen."])
            HelpDisclosure(title: "Optional: Gmail, Kalender, Notion & Co. verbinden") {
                KeyRow(controller: controller, kind: .composio, badge: "Optional",
                       help: "Konten verbindest du danach in AIS Scoops unter Einstellungen → Apps verbinden.",
                       link: "https://platform.composio.dev",
                       guide: ["Auf platform.composio.dev anmelden.", "Unter **API Keys** einen Schlüssel erstellen und hier einfügen."])
            }
            Text("Schlüssel liegen nur im **Schlüsselbund dieses Macs**, nicht in der Cloud und nicht bei AIS. Für Sprechmodus und Diktat braucht es einen Schlüssel auch mit Abo, Bilder entstehen nur über das ChatGPT-Abo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusBox: some View {
        if controller.hasModelAccess {
            InfoBox(style: .success, text: "**KI-Zugang steht:** \(controller.accessSummary ?? String(localized: "bereit")). Deine Scoops können loslegen.")
        } else {
            InfoBox(style: .info, text: choice == .abo
                    ? "Noch kein KI-Zugang. Melde dich oben mit deinem Abo an, oder wechsle zu **Mit API-Schlüssel**."
                    : "Noch kein KI-Zugang. Füge einen Schlüssel ein und klick auf **Prüfen und speichern**.")
        }
    }
}

/// Aufklappbare Hilfe „Wo bekomme ich das?“
struct HelpDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label(title, systemImage: "questionmark.circle").font(.callout.weight(.medium))
        }
    }
}

/// Schlüsselabschnitt der Einstellungen (im Assistenten: AccessStep)
struct KeysStep: View {
    let controller: ServerController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ohne Abo brauchen deine Scoops einen eigenen Schlüssel. Die Kosten laufen direkt über dein Konto beim Anbieter (eine normale Chat-Antwort kostet meist weniger als einen Cent). Für Sprechmodus und Diktat braucht es den Schlüssel auch mit Abo, Bilder entstehen nur über das ChatGPT-Abo.")
                .fixedSize(horizontal: false, vertical: true)
            KeyRow(controller: controller, kind: .anthropic, badge: "Empfohlen",
                   help: "Schlüssel erstellen unter console.anthropic.com → API Keys.",
                   link: "https://console.anthropic.com/settings/keys")
            KeyRow(controller: controller, kind: .openai, badge: "Optional",
                   help: "GPT-Modelle, Sprechmodus und Diktat. platform.openai.com → API keys.",
                   link: "https://platform.openai.com/api-keys")
            KeyRow(controller: controller, kind: .composio, badge: "Optional",
                   help: "Verbindet Gmail, Kalender, Notion & Co. platform.composio.dev → API Keys.",
                   link: "https://platform.composio.dev")
            InfoBox(style: .info, text: "Schlüssel werden nur im **Schlüsselbund dieses Macs** gespeichert, nicht in der Cloud und nicht bei AIS.")
        }
    }
}

/// Eine Schlüsselzeile: Eingabe (verdeckt), Prüfen und Speichern, Status, Entfernen, optional eine Anleitung.
struct KeyRow: View {
    let controller: ServerController
    let kind: SecretStore.Kind
    var badge: LocalizedStringKey?
    let help: LocalizedStringKey
    let link: String
    var guide: [LocalizedStringKey] = []

    @State private var value = ""
    @State private var busy = false
    @State private var message: String?
    @State private var ok = false
    /// Prüfung war nicht eindeutig (kein Netz, unerwartete Antwort): „Trotzdem speichern“ anbieten
    @State private var canForce = false
    @State private var stored: Bool

    init(controller: ServerController, kind: SecretStore.Kind, badge: LocalizedStringKey? = nil, help: LocalizedStringKey, link: String,
         guide: [LocalizedStringKey] = []) {
        self.controller = controller
        self.kind = kind
        self.badge = badge
        self.help = help
        self.link = link
        self.guide = guide
        _stored = State(initialValue: controller.modelKey(kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(kind.title).font(.headline)
                if let badge { Text(badge).font(.caption2).foregroundStyle(.secondary) }
                if stored {
                    Label("Gespeichert", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
                }
                Spacer()
                Link("Schlüssel holen", destination: URL(string: link)!).font(.caption)
                    .accessibilityLabel(Text("Schlüssel für \(kind.title) holen"))
            }
            HStack {
                // Platzhalter statt Beschriftung: In den Einstellungen (Form) stünde der Text sonst als umbrechendes Label
                // links neben einem schmalen Feld.
                SecureField(text: $value, prompt: Text(stored ? "Neuen Schlüssel einfügen, um ihn zu ersetzen" : "Schlüssel einfügen")) {
                    EmptyView()
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Schlüssel für \(kind.title)"))
                .onSubmit { Task { await save(force: false) } }
                Button(busy ? "Prüfe …" : "Prüfen und speichern") { Task { await save(force: false) } }
                    .disabled(busy || value.trimmingCharacters(in: .whitespaces).isEmpty)
                if stored {
                    Button(role: .destructive) { Task { await controller.deleteKey(kind); stored = false } } label: {
                        Image(systemName: "trash")
                    }
                    .help("Schlüssel entfernen")
                    .accessibilityLabel(Text("Schlüssel für \(kind.title) entfernen"))
                }
            }
            if let message {
                HStack {
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(ok ? .green : .orange)
                    if !ok, !value.isEmpty, canForce {
                        Button("Trotzdem speichern") { Task { await save(force: true) } }.font(.caption)
                    }
                }
            } else {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !guide.isEmpty && !stored {
                HelpDisclosure(title: "Wo bekomme ich den Schlüssel?") {
                    ForEach(Array(guide.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").monospacedDigit()
                            Text(line)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .onAppear { stored = controller.modelKey(kind) }
    }

    private func save(force: Bool) async {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        canForce = false
        guard SecretStore.isPlausible(v) else { ok = false; message = SecretStore.SaveError.implausible.localizedDescription; return }
        busy = true
        defer { busy = false }
        if !force {
            switch await KeyCheck.check(kind, key: v) {
            case .valid: break
            case .invalid(let m): ok = false; message = m; return
            case .unknown(let m): ok = false; message = m; canForce = true; return
            }
        }
        do {
            try await controller.saveKey(kind, value: v)
            value = ""
            stored = true
            ok = true
            message = force ? String(localized: "Im Schlüsselbund gespeichert (ohne Prüfung).")
                : String(localized: "Geprüft und im Schlüsselbund gespeichert.")
        } catch {
            ok = false
            message = error.localizedDescription
        }
    }
}

// MARK: - 4. Diesen Mac freigeben

struct ThisMacStep: View {
    let controller: ServerController
    @State private var name = AppModel.defaultName
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zum Beispiel, um im Browser etwas nachzusehen oder ein Formular auszufüllen. Dafür braucht die App zwei Rechte von macOS. Du erteilst sie selbst in den Systemeinstellungen; kommst du zurück, erkennt der Assistent die Freigabe von allein.")
                .fixedSize(horizontal: false, vertical: true)
            InfoBox(style: .warning, text: "Was auf diesem Mac angemeldet ist, können die Scoops sehen. Arbeitest du gerade selbst am Mac, drück oben in der Menüleiste auf **Pausieren**.")
            if controller.test {
                InfoBox(style: .info, text: "**Testmodus:** Rechte werden nur angezeigt; die Kopplung wird geprüft, die Steuerung aber nicht verbunden.")
            }
            Text("1. Rechte erteilen").font(.headline)
            PermissionsSection(model: controller.model)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Zusätzlich").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    NeedBadge(need: .optional)
                }
                FullDiskAccessView(manager: controller.manager)
            }
            Divider()
            Text("2. Diesen Mac anschließen").font(.headline)
            if controller.thisMacRegistered {
                InfoBox(style: .success, text: "**\(controller.model.isPaired ? controller.model.nodeName : name)** ist als Rechner für deine Scoops angeschlossen.")
            } else {
                Text("Danach können deine Scoops diesen Mac als Rechner nutzen. Den Namen siehst du später in AIS Scoops.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Name dieses Macs", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        .accessibilityLabel("Name dieses Macs")
                    Button(busy ? String(localized: "Verbinde …") : String(localized: "Diesen Mac anschließen")) { Task { await register() } }
                        .disabled(busy || controller.manager.phase != .running)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if let error { InfoBox(style: .warning, text: "\(error)") }
        }
        .onAppBecomesActive {
            controller.model.tickPermissions()
            Task { await controller.manager.refresh() }
        }
    }

    private func register() async {
        busy = true
        defer { busy = false }
        do {
            try await controller.registerThisMac(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? AppModel.defaultName : name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 5. Von unterwegs erreichbar

struct ReachStep: View {
    let controller: ServerController
    @State private var tailscale: Tailscale.Info?
    @State private var checked = false

    init(controller: ServerController) {
        self.controller = controller
        #if DEBUG
        if controller.manager.setup.offline {
            _tailscale = State(initialValue: controller.previewTailscale)
            _checked = State(initialValue: true)
        }
        #endif
    }
    @State private var busy = false
    @State private var message: String?
    @State private var messageOK = false
    @State private var messageLink: URL?
    @State private var confirmFunnel = false

    private var m: ServerManager { controller.manager }
    private var reachable: Bool { m.publicURL.hasPrefix("https://") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: reachable ? "checkmark.circle.fill" : (m.publicURL.isEmpty ? "circle.dashed" : "wifi"))
                    .font(.title2)
                    .foregroundStyle(reachable ? Color.green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reachable ? "Von unterwegs erreichbar: Ja" : "Von unterwegs erreichbar: Nein").font(.headline)
                    Text(m.publicURL.isEmpty ? String(localized: "Im Moment nur auf diesem Mac.") : "\(controller.reachabilityKind): \(m.publicURL)")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            Text("Am einfachsten geht das mit **Tailscale** (kostenlos). Du kannst diesen Schritt auch überspringen und später in den Einstellungen nachholen.")
                .fixedSize(horizontal: false, vertical: true)
            if controller.test {
                InfoBox(style: .info, text: "**Testmodus:** Tailscale- und Netzwerkänderungen sind deaktiviert.")
            }
            SetupCard(symbol: "point.3.connected.trianglepath.dotted", title: "Tailscale (empfohlen)") {
                if !checked {
                    ProgressView().controlSize(.small)
                } else if let ts = tailscale, ts.running, ts.dnsName != nil {
                    Label("Tailscale ist angemeldet (\(ts.dnsName ?? "")).", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                    HStack {
                        Button("Für meine Geräte freigeben") { Task { await share(publicly: false) } }
                        Button("Öffentlich freigeben (Funnel) …") { confirmFunnel = true }
                    }
                    .disabled(busy || controller.test)
                    Text("„Für meine Geräte“: Das iPhone braucht ebenfalls Tailscale. „Öffentlich“: geht ohne Tailscale auf dem iPhone; der Server ist dann im Internet erreichbar, aber nur mit Anmeldung nutzbar.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if Tailscale.isInstalled {
                    Text("Tailscale ist installiert, aber nicht angemeldet. Öffne Tailscale und melde dich an. Kommst du zurück, prüft der Assistent von selbst.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let diag = tailscale?.diagnostic {
                        Text(diag).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Erneut prüfen") { Task { checked = false; await detect() } }
                } else {
                    Text("1. Lade Tailscale für Mac und iPhone.\n2. Melde dich auf beiden mit demselben Konto an.\n3. Komm hierher zurück, der Assistent erkennt Tailscale von selbst.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Link("Tailscale laden", destination: URL(string: "https://tailscale.com/download/mac")!)
                        Button("Erneut prüfen") { Task { await detect() } }
                    }
                }
            }
            SetupCard(symbol: "wifi", title: "Nur im WLAN zu Hause") {
                Text("Ohne Tailscale: Die App erreicht den Server nur, wenn iPhone und Mac im selben WLAN sind.").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Im lokalen Netz freigeben") { Task { await run { try await controller.useLocalNetwork() } } }
                    .disabled(busy || controller.test)
            }
            if !m.publicURL.isEmpty {
                Button("Freigabe zurücknehmen (nur dieser Mac)") { Task { await run { try await controller.useOnlyThisMac() } } }
                    .buttonStyle(.link)
                    .disabled(busy || controller.test)
            }
            if let message {
                InfoBox(style: messageOK ? .success : .warning, text: "\(message)")
                if let messageLink {
                    Link("In Tailscale öffnen: \(messageLink.absoluteString)", destination: messageLink)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .task { await detect() }
        .onAppBecomesActive { Task { await detect() } }
        .alert("Server öffentlich freigeben?", isPresented: $confirmFunnel) {
            Button("Freigeben") { Task { await share(publicly: true) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Tailscale Funnel macht den Server unter einer https-Adresse im Internet erreichbar. Nutzen kann ihn nur, wer mit deinem Konto angemeldet ist. Funnel muss in deinem Tailscale-Konto erlaubt sein.")
        }
    }

    private func detect() async {
        #if DEBUG
        if m.setup.offline { tailscale = controller.previewTailscale; checked = true; return }
        #endif
        tailscale = await Tailscale.detect()
        checked = true
    }

    private func share(publicly: Bool) async {
        guard let ts = tailscale, !controller.test else { return }
        busy = true
        messageLink = nil
        messageOK = false
        message = publicly ? String(localized: "Richte Funnel auf Port \(String(m.port)) ein …")
            : String(localized: "Richte Tailscale Serve auf Port \(String(m.port)) ein …")
        defer { busy = false }
        // Immer der AKTUELLE Port des Servers (kann nach einem Ausweichen z. B. 8788 statt 8787 sein).
        switch await Tailscale.share(info: ts, localPort: m.port, publicly: publicly) {
        case .success(let url):
            do {
                try await controller.setPublicURL(url, tailnet: publicly ? nil : url)
                messageOK = true
                message = String(localized: "✓ Erreichbar unter \(url). AIS Scoops bekommt die Adresse in wenigen Sekunden.")
            } catch {
                message = String(localized: "Freigabe aktiv, aber die Adresse ließ sich nicht speichern: \(error.localizedDescription)")
            }
        case .failure(let e):
            message = String(localized: "Tailscale meldet: \(e.message)")
            messageLink = e.link
        }
    }

    private func run(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        messageLink = nil
        do {
            try await action()
            messageOK = true
            message = m.publicURL.hasPrefix("https://")
                ? String(localized: "✓ Gespeichert. Der Server startet kurz neu; die öffentliche Adresse \(m.publicURL) bleibt bestehen.")
                : String(localized: "✓ Gespeichert. Der Server startet kurz neu.")
        } catch {
            messageOK = false
            message = error.localizedDescription
        }
    }
}

// MARK: - 6. Dauerbetrieb

struct AwakeStep: View {
    @Bindable var controller: ServerController
    @State private var sleepOff = false
    @State private var message: String?
    @State private var confirmSleep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dafür sollte der Mac wach bleiben. Am besten steht er am Strom.")
                .fixedSize(horizontal: false, vertical: true)
            SetupCard {
                Toggle(isOn: $controller.keepSystemAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac wach halten, solange der Server läuft").font(.headline)
                        Text("Verhindert den Ruhezustand bei Inaktivität. Am Netzteil empfohlen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Toggle(isOn: $controller.keepDisplayAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bildschirm anlassen").font(.headline)
                        Text("Nur nötig, wenn Scoops am Bildschirm arbeiten sollen, während du weg bist.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SetupCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ruhezustand dauerhaft ausschalten").font(.headline)
                        Text(sleepOff ? "Ist ausgeschaltet." : "Auch wenn die App einmal nicht läuft. macOS fragt dafür nach deinem Passwort.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if sleepOff {
                        Label("Aus", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else {
                        Button("Ausschalten …") { confirmSleep = true }.disabled(controller.test)
                    }
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bildschirmsperre").font(.headline)
                        Text("Ist der Mac gesperrt, können Scoops nicht klicken. Stell unter Sperrbildschirm „Passwort anfordern“ auf einen langen Zeitraum, aber nur auf einem Mac, der sicher steht.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Einstellungen öffnen") { AdminSetting.openLockScreenSettings() }
                }
            }
            InfoBox(style: .info, text: "Nach einem Neustart des Macs (z. B. Update oder Stromausfall) meldest du dich einmal selbst an. Danach startet AIS Scoops Server von allein.")
            if let message { InfoBox(style: .warning, text: "\(message)") }
        }
        .task { sleepOff = AdminSetting.sleepDisabled }
        .onAppBecomesActive { sleepOff = AdminSetting.sleepDisabled }
        .alert("Ruhezustand ausschalten?", isPresented: $confirmSleep) {
            Button("Ausschalten") {
                message = AdminSetting.disableSystemSleep()
                sleepOff = AdminSetting.sleepDisabled
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Es wird „pmset -a sleep 0“ ausgeführt. macOS zeigt dafür den Passwort-Dialog. Rückgängig: Systemeinstellungen → Energie.")
        }
    }
}
