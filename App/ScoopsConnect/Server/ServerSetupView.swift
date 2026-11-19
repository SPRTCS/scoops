import AppKit
import SwiftUI

/// Einrichtungsassistent von „AIS Scoops Server“ (Ablauf in docs/installation.md):
/// Willkommen → Mit der App verbinden → KI-Zugang → Diesen Mac freigeben → Von unterwegs → Dauerbetrieb → Fertig.
///
/// Links zeigt eine Seitenleiste alle Schritte mit ihrem Stand; erreichte Schritte lassen sich dort anklicken, „Zurück“
/// geht immer. Der aktuelle Schritt wird gespeichert (`ServerController.savedSetupStep`), damit es nach einem
/// Abbruch oder Neustart an derselben Stelle weitergeht.
struct ServerSetupView: View {
    let controller: ServerController
    let onFinish: () -> Void

    @State private var step: SetupStep
    @State private var furthest: SetupStep
    @State private var userName = ""

    init(controller: ServerController, initialStep: SetupStep = .welcome, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
        _userName = State(initialValue: controller.manager.userName.flatMap { $0 == "du" ? nil : $0 } ?? "")
        // Wurde die Einrichtung schon einmal abgeschlossen, sind alle Schritte frei anklickbar.
        _furthest = State(initialValue: controller.setupDone ? .done
            : max(initialStep, SetupStep(rawValue: controller.savedSetupStep ?? 0) ?? .welcome))
    }

    static let size = CGSize(width: 860, height: 640)

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(controller: controller, step: step, furthest: furthest) { go(to: $0) }
                .frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                SetupHeader(step: step)
                ScrollView {
                    content
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(step)  // jeder Schritt beginnt oben
                Divider()
                footer
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { if !controller.setupDone { controller.savedSetupStep = step.rawValue } }
        .onChange(of: step) { _, new in
            furthest = max(furthest, new)
            if !controller.setupDone { controller.savedSetupStep = new.rawValue }
        }
        .animation(.snappy, value: step)
    }

    private var manager: ServerManager { controller.manager }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep(controller: controller)
        case .account: AccountStep(controller: controller, userName: $userName)
        case .keys: AccessStep(controller: controller)
        case .mac: ThisMacStep(controller: controller)
        case .reach: ReachStep(controller: controller)
        case .awake: AwakeStep(controller: controller)
        case .done: DoneStep(controller: controller) { go(to: $0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Zurück") { go(to: step.previous) }
                    .keyboardShortcut("[", modifiers: .command)
            } else if manager.isAvailable {
                Button("Nur als Rechner für einen anderen Server …") { controller.setRole(.connect) }
                    .buttonStyle(.link)
            }
            Spacer()
            if let hint = blockedHint {
                Text(hint).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            if let skip = step.skipTitle, !stepComplete {
                Button(skip) { go(to: step.next) }
            }
            Button(step == .done ? "Fertig" : "Weiter") { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(blockedHint != nil)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    /// Erklärung, warum „Weiter“ noch nicht geht (nil = geht).
    private var blockedHint: String? {
        switch step {
        case .welcome:
            if case .failed = manager.phase { return "Der Server läuft nicht." }
            return manager.phase == .running ? nil : "Warte, bis der Server läuft …"
        case .account:
            return manager.linked ? nil : "Weiter, sobald AIS Scoops verbunden ist."
        case .keys:
            return controller.hasModelAccess ? nil : "Erst Abo verbinden oder Schlüssel speichern."
        default:
            return nil
        }
    }

    private var stepComplete: Bool {
        switch step {
        case .account: manager.linked
        case .mac: controller.thisMacRegistered
        case .reach: !manager.publicURL.isEmpty
        default: false
        }
    }

    private func go(to s: SetupStep) {
        step = s
    }

    private func advance() {
        switch step {
        case .account:
            let name = userName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { Task { try? await manager.patchConfig(["user_name": name]) } }
        case .keys:
            Task { await controller.applyProviderForAccess() }
        case .done:
            controller.setupDone = true
            controller.savedSetupStep = nil
            if !controller.test && !manager.setup.offline { SMAppServiceHelper.enable() }
            onFinish()
            return
        default:
            break
        }
        go(to: step.next)
    }
}

enum SetupStep: Int, CaseIterable, Comparable {
    case welcome, account, keys, mac, reach, awake, done

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    var next: SetupStep { SetupStep(rawValue: rawValue + 1) ?? .done }
    var previous: SetupStep { SetupStep(rawValue: rawValue - 1) ?? .welcome }

    enum Need { case required, recommended, optional }

    var need: Need? {
        switch self {
        case .account, .keys: .required
        case .awake: .recommended
        case .mac, .reach: .optional
        case .welcome, .done: nil
        }
    }

    /// Zweiter Knopf neben „Weiter“, solange der Schritt nicht erledigt ist
    var skipTitle: String? {
        switch self {
        case .account: "Später verbinden"
        case .mac, .reach: "Überspringen"
        default: nil
        }
    }

    var title: String {
        switch self {
        case .welcome: "Willkommen"
        case .account: "Mit der App verbinden"
        case .keys: "KI-Zugang"
        case .mac: "Diesen Mac freigeben"
        case .reach: "Von unterwegs erreichbar"
        case .awake: "Dauerbetrieb"
        case .done: "Fertig"
        }
    }

    var headline: String {
        switch self {
        case .welcome: "Willkommen bei AIS Scoops Server"
        case .account: "Mit AIS Scoops verbinden"
        case .keys: "KI-Zugang einrichten"
        case .mac: "Diesen Mac für die Scoops freigeben"
        case .reach: "Von unterwegs erreichbar machen"
        case .awake: "Damit deine Scoops immer können"
        case .done: "Alles bereit"
        }
    }

    /// Warum dieser Schritt nötig ist (unter der Überschrift)
    var why: String {
        switch self {
        case .welcome: "Deine eigenen Scoops, auf deinem Mac. Der Assistent begleitet dich Schritt für Schritt."
        case .account: "Damit AIS Scoops auf iPhone, iPad oder Mac diesen Server findet und dir Mitteilungen schicken kann."
        case .keys: "Deine Scoops denken mit einem KI-Modell. Ohne Abo oder Schlüssel können sie nicht antworten."
        case .mac: "Damit Scoops auf diesem Mac Programme öffnen, klicken und tippen können. Ohne diesen Schritt chatten sie nur."
        case .reach: "Ohne diesen Schritt erreicht AIS Scoops den Server nur, wenn du direkt an diesem Mac bist."
        case .awake: "Scoops arbeiten auch, wenn du nicht am Mac sitzt, etwa für Erinnerungen oder Aufgaben von unterwegs."
        case .done: "Prüfe kurz, ob alles steht. Danach geht es in der App weiter."
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .account: "iphone.and.arrow.forward"
        case .keys: "sparkles"
        case .mac: "desktopcomputer"
        case .reach: "network"
        case .awake: "bolt.horizontal.circle"
        case .done: "flag.checkered"
        }
    }
}

// MARK: - Rahmen: Seitenleiste und Kopfzeile

private struct SetupSidebar: View {
    let controller: ServerController
    let step: SetupStep
    let furthest: SetupStep
    let go: (SetupStep) -> Void

    private var m: ServerManager { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconView(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AIS Scoops Server").font(.headline)
                    Text("Einrichtung").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SetupStep.allCases, id: \.self) { s in
                    row(s)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(step.rawValue), total: Double(SetupStep.allCases.count - 1))
                    .accessibilityLabel("Fortschritt der Einrichtung")
                    .accessibilityValue("Schritt \(step.rawValue + 1) von \(SetupStep.allCases.count)")
                Text("Schritt \(step.rawValue + 1) von \(SetupStep.allCases.count) · etwa 10 Minuten insgesamt")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    StatusDot(color: m.dotColor)
                    Text(m.statusTitle).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    private enum RowState { case done, current, open, skipped }

    private func state(_ s: SetupStep) -> RowState {
        if s == step { return .current }
        let complete: Bool? = switch s {
        case .welcome: m.phase == .running
        case .account: m.linked
        case .keys: controller.hasModelAccess
        case .mac: controller.thisMacRegistered
        case .reach: !m.publicURL.isEmpty
        case .awake: s < furthest ? controller.keepSystemAwake : nil
        case .done: nil
        }
        if complete == true { return .done }
        return s < furthest ? .skipped : .open
    }

    private func row(_ s: SetupStep) -> some View {
        let st = state(s)
        let enabled = s <= furthest
        return Button { go(s) } label: {
            HStack(spacing: 10) {
                ZStack {
                    switch st {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .current:
                        Image(systemName: "\(s.rawValue + 1).circle.fill").foregroundStyle(Color.accentColor)
                    case .skipped:
                        Image(systemName: "minus.circle").foregroundStyle(.orange)
                    case .open:
                        Image(systemName: "\(s.rawValue + 1).circle").foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title)
                        .font(.callout.weight(st == .current ? .semibold : .regular))
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    if let label = needLabel(s, st) {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(st == .current ? Color.accentColor.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Schritt \(s.rawValue + 1): \(s.title)")
        .accessibilityValue(accessibilityValue(st, s))
        .accessibilityAddTraits(st == .current ? .isSelected : [])
    }

    private func needLabel(_ s: SetupStep, _ st: RowState) -> String? {
        if st == .skipped { return s.need == .optional ? "Übersprungen" : "Noch offen" }
        switch s.need {
        case .optional: return "Optional"
        case .recommended: return "Empfohlen"
        default: return nil
        }
    }

    private func accessibilityValue(_ st: RowState, _ s: SetupStep) -> String {
        switch st {
        case .done: "erledigt"
        case .current: "aktueller Schritt"
        case .skipped: s.need == .optional ? "übersprungen" : "noch offen"
        case .open: s.need == .optional ? "optional, noch nicht erreicht" : "noch nicht erreicht"
        }
    }
}

private struct SetupHeader: View {
    let step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Schritt \(step.rawValue + 1) von \(SetupStep.allCases.count)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let need = step.need { NeedBadge(need: need) }
            }
            Text(step.headline).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(step.why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }
}

struct NeedBadge: View {
    let need: SetupStep.Need
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
            .accessibilityLabel(text)
    }
    private var text: String {
        switch need { case .required: "Nötig"; case .recommended: "Empfohlen"; case .optional: "Optional" }
    }
    private var color: Color {
        switch need { case .required: .accentColor; case .recommended: .green; case .optional: .secondary }
    }
}

// MARK: - Bausteine

/// Hinweisbox mit Symbol (Info, Warnung, Erfolg).
struct InfoBox: View {
    enum Style { case info, warning, success }
    let style: Style
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
    private var symbol: String {
        switch style { case .info: "info.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .success: "checkmark.circle.fill" }
    }
    private var color: Color {
        switch style { case .info: .accentColor; case .warning: .orange; case .success: .green }
    }
}

/// Karte mit Nummer bzw. Symbol und Inhalt (Anleitungsschritte, Optionen).
struct SetupCard<Content: View>: View {
    var number: Int?
    var symbol: String?
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityHidden(true)
            } else if let symbol {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.headline) }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
    }
}

struct ServerStatusLine: View {
    let manager: ServerManager
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: manager.dotColor)
            Text(manager.statusTitle).font(.callout.weight(.medium))
            if let v = manager.version { Text("· Version \(v)").font(.callout).foregroundStyle(.secondary) }
            if manager.port > 0 { Text("· Port \(String(manager.port))").font(.callout).foregroundStyle(.secondary) }
            if manager.phase == .starting { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ServerManager {
    var dotColor: Color {
        switch statusColorName {
        case "green": .green
        case "yellow": .yellow
        case "red": .red
        default: .secondary
        }
    }
}

/// Wo es AIS Scoops gibt (App Store, iPhone/iPad/Mac).
enum AISScoopsApp {
    static let appStoreURL: URL? = URL(string: "https://apps.apple.com/app/id6833654924")
}

private struct Bullet: View {
    let symbol: String
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1. Willkommen

private struct WelcomeStep: View {
    let controller: ServerController
    private var m: ServerManager { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Mit **AIS Scoops Server** wohnen deine Scoops auf diesem Mac, mit deinen Daten und deinem eigenen KI-Zugang. In der App **AIS Scoops** auf iPhone, iPad oder Mac chattest du dann mit ihnen.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Das brauchst du").font(.headline)
                Bullet(symbol: "apple.logo", text: "Ein **Apple-Konto**, damit du dich in AIS Scoops mit „Mit Apple anmelden“ anmeldest")
                Bullet(symbol: "iphone", text: "**AIS Scoops aus dem App Store** auf iPhone, iPad oder Mac")
                Bullet(symbol: "sparkles", text: "Ein **KI-Abo** (Claude Pro oder Max, ChatGPT Plus oder Pro) **oder** einen API-Schlüssel von Anthropic oder OpenAI")
                Bullet(symbol: "point.3.connected.trianglepath.dotted", text: "Optional: **Tailscale**, wenn du deine Scoops auch unterwegs nutzen möchtest")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("So geht es weiter (etwa 10 Minuten)").font(.headline)
                ForEach([SetupStep.account, .keys, .mac, .reach, .awake], id: \.self) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).foregroundStyle(.tint).frame(width: 22).accessibilityHidden(true)
                        Text(s.title)
                        if let need = s.need, need != .required { NeedBadge(need: need) }
                    }
                }
            }

            serverCard
            if controller.test {
                InfoBox(style: .info, text: "**Testmodus:** eigener Datenordner, Port \(String(m.port)), Konto-Dienst Dev. Dieser Mac wird nicht wirklich gesteuert.")
            }
        }
    }

    @ViewBuilder
    private var serverCard: some View {
        SetupCard(symbol: "server.rack", title: "Dein Server") {
            ServerStatusLine(manager: m)
            switch m.phase {
            case .running:
                Text("Läuft auf diesem Mac. Klick auf **Weiter**.").font(.callout).foregroundStyle(.secondary)
            case .starting, .stopped:
                Text("Der Server startet. Das dauert beim ersten Mal bis zu einer Minute.").font(.callout).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Erneut starten") { m.restart(); controller.applyKeepAwake() }
                    Button("Protokoll öffnen") { m.openLogs() }
                }
            }
        }
    }
}

// MARK: - 2. Mit der App verbinden

private struct AccountStep: View {
    let controller: ServerController
    @Binding var userName: String
    @State private var error: String?
    @State private var requesting = false
    @State private var copied = false
    @State private var renewed = false
    /// Verbunden, aber auf Wunsch mit einem anderen Konto neu koppeln (Code mit `force`)
    @State private var relinking = false
    @State private var lastExpiry: Date?

    private var m: ServerManager { controller.manager }

    /// Kein gültiger Code da, obwohl einer gebraucht wird (erster Aufruf, abgelaufen)
    private var needsCode: Bool {
        (!m.linked || relinking) && m.pendingCode == nil && m.phase == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if m.linked && !relinking {
                linkedCard
            } else {
                instructions
                codeBox
            }
            if let error { InfoBox(style: .warning, text: "\(error)") }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Wie sollen dich deine Scoops nennen?").font(.headline)
                TextField("Vorname", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Dein Vorname für die Scoops")
                Text("Zum Beispiel dein Vorname. Lässt sich später in den Einstellungen ändern.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await prepare() }
        .task(id: needsCode) { await renewWhileNeeded() }
        .onChange(of: m.pendingCode) { old, new in
            if let exp = m.pendingExpiry { lastExpiry = exp }
            // Code vor Ablauf verschwunden → eingelöst (bei „Anderes Konto“ bleibt `linked` die ganze Zeit wahr)
            if old != nil, new == nil, let exp = lastExpiry, exp.timeIntervalSinceNow > 3 { relinking = false }
        }
        .onChange(of: m.ownerName) { _, new in
            if userName.isEmpty, let first = new?.split(separator: " ").first { userName = String(first) }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupCard(number: 1) {
                Text("Lade **AIS Scoops aus dem App Store** auf dein iPhone, iPad oder deinen Mac und öffne die App.")
                    .fixedSize(horizontal: false, vertical: true)
                if let url = AISScoopsApp.appStoreURL {
                    Link("Im App Store öffnen", destination: url).font(.callout)
                }
            }
            SetupCard(number: 2) {
                Text("Melde dich mit **Mit Apple anmelden** an.").fixedSize(horizontal: false, vertical: true)
            }
            SetupCard(number: 3) {
                Text("Tippe auf **Deine Server → Server hinzufügen** (beim ersten Start fragt dich die App selbst danach) und gib diesen **Kopplungscode** ein:")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var codeBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let code = m.pendingCode {
                HStack(alignment: .center, spacing: 18) {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .tracking(5)
                        .textSelection(.enabled)
                        .accessibilityLabel("Kopplungscode")
                        .accessibilityValue(code.map { $0 == "-" ? "Strich" : String($0) }.joined(separator: " "))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityHint("Legt den Kopplungscode in die Zwischenablage")
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Warte auf die Eingabe in AIS Scoops …").font(.callout)
                    Spacer()
                    if let exp = m.pendingExpiry {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(exp.timeIntervalSince(ctx.date)))
                            Text("Gültig noch \(left / 60):\(String(format: "%02d", left % 60)) Min.")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Text(renewed ? "Der alte Code war abgelaufen, das hier ist ein neuer. Läuft er ab, kommt automatisch der nächste."
                             : "Läuft der Code ab, erscheint automatisch ein neuer.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(m.phase == .running ? "Code wird angefordert …" : "Warte auf den Server …").font(.callout)
                    Spacer()
                    if error != nil {
                        Button("Erneut versuchen") { Task { await request() } }.disabled(requesting)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private var linkedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verbunden!").font(.title3.weight(.semibold))
                    Text(m.ownerName.map { "AIS Scoops ist mit diesem Server verbunden, Konto von **\($0)**." }
                         ?? "AIS Scoops ist mit diesem Server verbunden.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("In der App findest du ihn unter **Deine Server**. Mitteilungen deiner Scoops kommen ab jetzt auch, wenn die App zu ist.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Mit einem anderen Konto verbinden …") {
                relinking = true
                renewed = false
                Task { await request() }
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.10)))
        .accessibilityElement(children: .contain)
    }

    private func prepare() async {
        for _ in 0..<60 where m.status == nil { try? await Task.sleep(for: .milliseconds(500)) }
        if userName.isEmpty {
            // Server-Vorschlag: gesetzte Ansprache > Vorname aus dem Konto > Vorname des macOS-Benutzers
            userName = m.userName.flatMap { $0 == "du" ? nil : $0 }
                ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        }
        lastExpiry = m.pendingExpiry
    }

    /// Fordert einen Code an, solange einer fehlt (auch nach Ablauf); bei Fehlern alle 15 Sekunden erneut.
    private func renewWhileNeeded() async {
        guard needsCode else { return }
        let hadCode = lastExpiry != nil
        while !Task.isCancelled, needsCode {
            await request()
            if m.pendingCode != nil {
                renewed = hadCode
                break
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func request() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        do {
            try await m.startLink(force: relinking)
            lastExpiry = m.pendingExpiry
            error = nil
        } catch {
            self.error = "Code konnte nicht angefordert werden: \(error.localizedDescription)"
        }
    }
}

// MARK: - 7. Fertig

private struct DoneStep: View {
    let controller: ServerController
    let go: (SetupStep) -> Void
    private var m: ServerManager { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                check(ok: m.phase == .running, title: "Server läuft",
                      detail: m.phase == .running ? "Startet nach dem Anmelden am Mac von selbst." : "Der Server ist gerade nicht bereit.",
                      fix: m.phase == .running ? nil : .welcome)
                check(ok: m.linked, title: m.linked ? "Mit AIS Scoops verbunden" : "Noch nicht mit AIS Scoops verbunden",
                      detail: m.linked ? (m.ownerName.map { "Konto von \($0)" } ?? "Konto verbunden") : "Ohne Verbindung findet die App diesen Server nicht.",
                      fix: m.linked ? nil : .account)
                check(ok: controller.hasModelAccess, title: controller.hasModelAccess ? "KI-Zugang ok" : "Noch kein KI-Zugang",
                      detail: controller.accessSummary ?? "Ohne Abo oder Schlüssel können die Scoops nicht antworten.",
                      fix: controller.hasModelAccess ? nil : .keys)
                check(ok: controller.thisMacRegistered, optional: true,
                      title: controller.thisMacRegistered ? "Dieser Mac ist freigegeben" : "Dieser Mac ist nicht freigegeben",
                      detail: controller.thisMacRegistered ? "Scoops können hier klicken und tippen." : "Optional. Die Scoops chatten trotzdem.",
                      fix: controller.thisMacRegistered ? nil : .mac)
                check(ok: m.publicURL.hasPrefix("https://"), optional: true,
                      title: m.publicURL.hasPrefix("https://") ? "Von unterwegs erreichbar: Ja" : "Von unterwegs erreichbar: Nein",
                      detail: reachDetail, fix: m.publicURL.hasPrefix("https://") ? nil : .reach)
            }
            nextStepCard
            Text("Der Server läuft weiter, solange oben in der Menüleiste das Symbol zu sehen ist. Dort findest du Einstellungen, Protokoll und „Einrichtung erneut öffnen“.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reachDetail: String {
        let u = m.publicURL
        if u.hasPrefix("https://") { return u }
        if !u.isEmpty { return "Nur im selben WLAN wie dieser Mac (\(u))." }
        return "Nur hier am Mac. Optional, lässt sich jederzeit nachholen."
    }

    private func check(ok: Bool, optional: Bool = false, title: String, detail: String, fix: SetupStep?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle" : "exclamationmark.circle.fill"))
                .foregroundStyle(ok ? Color.green : (optional ? Color.secondary : Color.orange))
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let fix {
                Button(optional ? "Einrichten" : "Beheben") { go(fix) }
                    .controlSize(.small)
                    .accessibilityLabel("\(optional ? "Einrichten" : "Beheben"): \(title)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var nextStepCard: some View {
        if let count = m.ownScoopCount, count > 0 {
            HStack(alignment: .top, spacing: 14) {
                Text("🎉").font(.system(size: 38)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glückwunsch zu deinem ersten Scoop!").font(.title3.weight(.semibold))
                    Text(m.newestOwnScoop.map { "**\($0)** ist bereit. Schreib ihm in AIS Scoops, wobei er dir helfen soll." }
                         ?? "Er ist bereit. Schreib ihm in AIS Scoops, wobei er dir helfen soll.")
                        .fixedSize(horizontal: false, vertical: true)
                    if count > 1 {
                        Text("Du hast schon \(count) eigene Scoops.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.10)))
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nächster Schritt").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                Text("Erstelle jetzt deinen ersten Scoop in AIS Scoops").font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Öffne **AIS Scoops** und wähle unter **Deine Server** diesen Mac.")
                    Text("2. Tippe auf **+** (Neuer Scoop).")
                    Text("3. Gib ihm einen Namen und einen Charakter, zum Beispiel „Kiwi, hilft mir beim Kochen“.")
                    Text("4. Schreib ihm deine erste Nachricht.")
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("Dein Start-Scoop **Pip** wartet dort auch schon und erklärt dir gern alles.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if m.ownScoopCount != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sobald dein Scoop da ist, siehst du es hier.").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
        }
    }
}
