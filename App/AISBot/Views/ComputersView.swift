import SwiftUI

// Rechner (Server v1.11, „Scoops Connect“): Der eingebaute Bot-Rechner plus Macs, die über die App
// Scoops Connect angeschlossen sind. Einstellungen → Rechner, Auswahl im Scoop-Profil, Umschalter im Bildschirm.

/// Abschnitt „Rechner“ in den Einstellungen: Liste mit Status, Hinzufügen, Umbenennen, Entfernen.
struct ComputersSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showAdd = ProcessInfo.processInfo.arguments.contains("-nodesadd")
    @State private var renameTarget: ComputerNode?
    @State private var nameInput = ""
    @State private var deleteTarget: ComputerNode?

    var body: some View {
        // Eigener Schlüssel: Überschrift heißt englisch „Computers“ (Mehrzahl), „Rechner“ sonst „Computer“
        GroupedSection(String(localized: "settings.section.computers", defaultValue: "Rechner",
                              comment: "Abschnitt in den Einstellungen mit allen Rechnern (englisch Mehrzahl: Computers)"),
                       footer: footer, dividerInset: 62) {
            ForEach(list) { node in row(node) }
            Button { showAdd = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill").appFont(18).foregroundStyle(theme.accent)
                        .frame(width: 34)
                    Text("Rechner hinzufügen").appFont(15).foregroundStyle(theme.accent)
                    Spacer()
                }
                .groupedRow()
            }
            .buttonStyle(.plain)
            .disabled(store.phase != .online && !store.isMock)
        }
        .task { await store.loadNodes() }
        .sheet(isPresented: $showAdd) {
            AddComputerSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        .alert("Rechner umbenennen", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $nameInput)
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
            Button("Sichern") {
                if let target = renameTarget { Task { await store.renameNode(target, to: nameInput) } }
                renameTarget = nil
            }
        } message: {
            Text("So heißt der Rechner in der App und bei deinen Scoops.")
        }
        .confirmationDialog(deleteTarget.map { t in String(localized: "„\(t.name)“ entfernen?") } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Rechner entfernen", role: .destructive) {
                if let target = deleteTarget { Task { await store.deleteNode(target) } }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Ohne geladene Liste (ältere Server) wenigstens der Bot-Rechner
    private var list: [ComputerNode] {
        store.nodes.isEmpty
            ? [ComputerNode(id: ComputerNode.builtinID, name: String(localized: "Bot-Rechner"), mode: "vm", builtin: true,
                            online: store.computer.state != "asleep", state: store.computer.state)]
            : store.nodes
    }

    private var footer: String {
        String(localized: "An diesen Rechnern arbeiten deine Scoops. Weitere Macs schließt du mit der App Scoops Connect an; welcher Scoop wo arbeitet, legst du in seinem Profil fest.")
    }

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let users = store.bots.filter { $0.computerNode == target.id }.map(\.name)
        var text = String(localized: "Scoops Connect auf diesem Mac wird getrennt und muss neu gekoppelt werden.")
        if !users.isEmpty {
            let names = users.formatted(.list(type: .and).locale(.app))
            text += " " + (users.count == 1
                ? String(localized: "\(names) arbeitet dann wieder am Bot-Rechner.", comment: "Ein Scoop (Name)")
                : String(localized: "\(names) arbeiten dann wieder am Bot-Rechner.", comment: "Mehrere Scoops (Aufzählung)"))
        }
        return text
    }

    private func row(_ node: ComputerNode) -> some View {
        HStack(spacing: 12) {
            ComputerSymbol(node: node, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).appFont(15).foregroundStyle(theme.textPrimary).adaptiveLineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(statusColor(node)).frame(width: 7, height: 7)
                    Text(subtitle(node)).appFont(12.5).foregroundStyle(theme.textSecondary).adaptiveLineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Menu {
                menu(node)
            } label: {
                Image(systemName: "ellipsis.circle").appFont(17).foregroundStyle(theme.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aktionen für \(node.name)")
        }
        .groupedRow(vertical: 8)
        .contextMenu { menu(node) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ node: ComputerNode) -> some View {
        Button { nameInput = node.name; renameTarget = node } label: { Label("Umbenennen", systemImage: "pencil") }
        if !node.isBuiltin {
            Divider()
            Button(role: .destructive) { deleteTarget = node } label: { Label("Entfernen", systemImage: "trash") }
        }
    }

    private func subtitle(_ node: ComputerNode) -> String {
        var parts = [node.statusText]
        if node.isBuiltin {
            parts.append(String(localized: "Eingebaut", comment: "Rechner: der eingebaute Bot-Rechner"))
        } else {
            parts.append(node.mode == "vm" ? "VM" : String(localized: "Direkt", comment: "Rechner-Modus: Mac direkt gesteuert (statt VM)"))
            if !node.online, let seen = node.lastSeen {
                let ago = seen.formatted(.relative(presentation: .named).locale(.app))
                parts.append(String(localized: "zuletzt \(ago)", comment: "Rechner zuletzt gesehen, z. B. „zuletzt vor 2 Stunden“"))
            }
        }
        let users = store.bots.filter { $0.computerNode == node.id }.count
        if users > 0 { parts.append(String(localized: "\(users) Scoops")) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ node: ComputerNode) -> Color { ComputerSymbol.statusColor(node, theme: theme) }
}

/// Symbol eines Rechners in einer abgerundeten Kachel mit Statuspunkt.
struct ComputerSymbol: View {
    let node: ComputerNode
    var size: CGFloat = 34
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: node.symbol)
            .font(.fixed(size * 0.44, weight: .semibold))
            .foregroundStyle(node.online ? theme.textPrimary : theme.textTertiary)
            .frame(width: size, height: size)
            .background(theme.selection, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }

    static func statusColor(_ node: ComputerNode, theme: Theme) -> Color {
        if !node.online { return theme.textTertiary }
        if node.paused { return theme.warning }
        switch node.state {
        case "busy": return theme.accent
        case "user": return theme.warning
        default: return theme.success
        }
    }
}

/// „Rechner hinzufügen“: Kopplungscode mit Countdown und Kurzanleitung für Scoops Connect.
struct AddComputerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: NodePairing?
    @State private var error: String?
    @State private var loading = false
    @State private var copied = false
    /// Rechner, die beim Öffnen schon da waren; ein neuer Eintrag = erfolgreich gekoppelt
    @State private var knownIDs: Set<String>?

    private var newNode: ComputerNode? {
        guard let knownIDs else { return nil }
        return store.nodes.first { !knownIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Rechner hinzufügen", icon: "desktopcomputer") { dismiss() }
            ScrollView {
                VStack(spacing: 22) {
                    if let node = newNode {
                        success(node)
                    } else {
                        codeCard
                        steps
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground)
        .task {
            if knownIDs == nil { knownIDs = Set(store.nodes.map(\.id)) }
            await newCode()
        }
        .task {
            // Fallback, falls das Ereignis „node.updated“ verloren geht: Liste regelmäßig nachladen
            while !Task.isCancelled && newNode == nil {
                try? await Task.sleep(for: .seconds(4))
                await store.loadNodes()
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #else
        .presentationDetents([.large])
        #endif
    }

    // MARK: Code

    private var codeCard: some View {
        VStack(spacing: 14) {
            if let pairing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, pairing.expiresAt.timeIntervalSince(context.date))
                    VStack(spacing: 12) {
                        Text(pairing.code)
                            .appFont(40, weight: .bold, design: .monospaced)
                            .tracking(3)
                            .foregroundStyle(left > 0 ? theme.textPrimary : theme.textTertiary)
                            .strikethrough(left <= 0, color: theme.textTertiary)
                            .textSelection(.enabled)
                            .minimumScaleFactor(0.6)
                            .adaptiveLineLimit(1)
                            .accessibilityLabel("Code \(pairing.code.map(String.init).joined(separator: " "))")
                        if left > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "timer")
                                Text("Gültig noch \(Self.countdown(left))").monospacedDigit()
                            }
                            .appFont(13)
                            .foregroundStyle(left < 60 ? theme.warning : theme.textSecondary)
                            AdaptiveButtonRow(spacing: 10) {
                                Button {
                                    Clipboard.copy(pairing.code)
                                    copied = true
                                } label: {
                                    Label(copied ? "Kopiert" : "Code kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Warte auf den Mac …").appFont(12.5).foregroundStyle(theme.textSecondary)
                                }
                            }
                        } else {
                            Text("Code abgelaufen").appFont(13, weight: .semibold).foregroundStyle(theme.danger)
                            Button("Neuen Code anzeigen") { Task { await newCode() } }
                                .buttonStyle(PillButtonStyle(kind: .primary))
                                .disabled(loading)
                        }
                    }
                }
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").appFont(26).foregroundStyle(theme.warning)
                    Text(error).appFont(13).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    Button("Nochmal versuchen") { Task { await newCode() } }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
            } else {
                ProgressView().frame(height: 110)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
            .strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
    }

    private var steps: some View {
        GroupedSection("So geht's", footer: "Der Code gilt 10 Minuten und nur einmal. Scoops Connect verbindet sich danach von selbst, auch nach einem Neustart.") {
            step(1, "Scoops Connect auf dem Mac öffnen", String(localized: "Die App erscheint danach oben in der Menüleiste."))
            step(2, "Code eingeben", serverHint)
            step(3, "Modus wählen und Zugriff erlauben",
                 String(localized: "„Diesen Mac direkt steuern“ für einen reinen Scoop-Rechner, „Abgeschirmte VM“, wenn du selbst daran arbeitest. Danach Bildschirmaufnahme und Bedienungshilfen erlauben."))
        }
    }

    private var serverHint: String {
        if let url = pairing?.serverUrl, !url.isEmpty {
            let address = url.replacingOccurrences(of: "https://", with: "")
            return String(localized: "Server-Adresse: \(address)")
        }
        return String(localized: "Server-Adresse wie in dieser App unter Verbindung.")
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .appFont(13, weight: .bold)
                .foregroundStyle(theme.textOnAccent)
                .frame(width: 24, height: 24)
                .background(theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).appFont(15, weight: .medium).foregroundStyle(theme.textPrimary)
                Text(detail).appFont(12.5).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .groupedRow(vertical: 10)
    }

    // MARK: Erfolg

    private func success(_ node: ComputerNode) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .appFont(52)
                .foregroundStyle(theme.success)
                .padding(.top, 30)
            Text("„\(node.name)“ ist verbunden")
                .appFont(19, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Wähle im Profil eines Scoops unter „Computer“, ob er an diesem Rechner arbeiten soll.")
                .appFont(13.5)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Fertig") { dismiss() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private func newCode() async {
        loading = true
        error = nil
        copied = false
        do {
            pairing = try await store.pairNode()
        } catch let e as APIError where e.status == 404 {
            pairing = nil
            error = String(localized: "Dein Server kennt noch keine weiteren Rechner. Bitte erst auf Version 1.11 aktualisieren.")
        } catch {
            pairing = nil
            self.error = String(localized: "Kein Code erhalten: \(error.localizedDescription)")
        }
        loading = false
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Auswahl „Rechner“ im Scoop-Profil. Offline-Rechner sind gekennzeichnet, bleiben aber wählbar.
struct ComputerNodePicker: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let current = store.node(bot.computerNode)
        Menu {
            ForEach(store.nodes) { node in
                Button {
                    Task { await store.setComputerNode(node.id, for: bot.id) }
                } label: {
                    if node.id == bot.computerNode {
                        Label(itemTitle(node), systemImage: "checkmark")
                    } else {
                        Text(itemTitle(node))
                    }
                }
            }
        } label: {
            // Große Schrift: gewählter Rechner unter „Rechner“
            AdaptiveRow(spacing: 12, stackedSpacing: 2) {
                Text("Rechner").appFont(15).foregroundStyle(theme.textPrimary)
            } trailing: {
                HStack(spacing: 12) {
                    if let current, !current.isAvailable {
                        Text(current.statusText).appFont(12.5).foregroundStyle(theme.warning)
                    }
                    Text(current?.name ?? store.nodeName(bot.computerNode))
                        .appFont(15).foregroundStyle(theme.textSecondary).adaptiveLineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .appFont(11, weight: .semibold).foregroundStyle(theme.textTertiary)
                }
            }
            .groupedRow()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Rechner: \(current?.name ?? store.nodeName(bot.computerNode))")
    }

    private func itemTitle(_ node: ComputerNode) -> String {
        node.isAvailable ? node.name : "\(node.name) (\(node.statusText.lowercased()))"
    }
}

/// Umschalter zwischen den Rechnern in der Bildschirm-Ansicht (nur wenn es mehrere gibt).
struct ComputerNodeSwitcher: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    var disabled = false

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Rechner", selection: $store.computerNodeID) {
                ForEach(store.nodes) { node in
                    Text(node.isAvailable ? node.name : "\(node.name) (\(node.statusText.lowercased()))").tag(node.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.node(store.computerNodeID)?.symbol ?? "cube.transparent")
                Text(store.nodeName(store.computerNodeID)).adaptiveLineLimit(1)
                Image(systemName: "chevron.down").appFont(10, weight: .bold)
            }
            .appFont(13, weight: .medium)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.surfaceBorder))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .help("Rechner wechseln")
    }
}
