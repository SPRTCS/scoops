import SwiftUI

// Rechner-Zugriff der Scoops (Server 1.29, docs/rechnerzugriff.md): Rechte-Modus („Immer genehmigen“, „Automatisch“,
// „Vollzugriff“) und Bereich („Nur Arbeitsordner“, „Projektordner“, „Überall“). Pro Scoop im Profil (nur Admin), pro
// Aufgabe im Formular und als Pille im Eingabefeld. Projektordner wählt man über die Ordnerliste des Servers.

// MARK: - Festplattenvollzugriff (Status vom Server)

/// Festplattenvollzugriff des Server-Prozesses (`full_disk_access` in GET /api/settings/workspace, ab Server 1.29).
nonisolated struct FullDiskAccessStatus: Decodable, Hashable, Sendable {
    /// `nil` = unbekannt (nicht prüfbar)
    var granted: Bool?
    /// Name, der in den Systemeinstellungen erscheint (z. B. „AIS Scoops Server“ oder „python3.12“)
    var process: String?
    var path: String?
    var app: Bool?
}

/// Hinweiszeile „Festplattenvollzugriff fehlt“ (Einstellungen → Arbeitsordner und Profil → Rechner-Zugriff).
struct FullDiskAccessRow: View {
    let status: FullDiskAccessStatus
    @Environment(\.theme) private var theme

    var body: some View {
        GroupedLabelRow(icon: "lock.trianglebadge.exclamationmark", iconColor: theme.warning,
                        title: String(localized: "Festplattenvollzugriff fehlt"),
                        subtitle: Self.hint(status))
            .accessibilityElement(children: .combine)
    }

    static func hint(_ s: FullDiskAccessStatus) -> String {
        let who = s.process ?? "AIS Scoops Server"
        return String(localized: "Auf dem Server-Mac: Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff → „\(who)“ einschalten (fehlt er, mit „+“ hinzufügen). Dann fragt macOS nicht bei jedem Ordner neu.")
    }
}

// MARK: - Profil: Abschnitt „Rechner-Zugriff“ (nur Admin)

struct ComputerAccessSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showPicker = false
    @State private var fullDisk: FullDiskAccessStatus?

    private var access: ScoopAccess { bot.computerAccess ?? ScoopAccess() }

    var body: some View {
        GroupedSection(String(localized: "Rechner-Zugriff"), footer: footer, dividerInset: 50) {
            modeMenu
            scopeMenu
            if access.accessScope == .projects {
                ForEach(access.folders, id: \.self) { folder in
                    GroupedLabelRow(icon: "folder.fill", iconColor: theme.textSecondary, title: (folder as NSString).lastPathComponent,
                                    subtitle: folder) {
                        Button { remove(folder) } label: {
                            Image(systemName: "minus.circle.fill").appFont(17).foregroundStyle(theme.danger)
                        }
                        .buttonStyle(.plain)
                        .disabled(access.folders.count <= 1)
                        .accessibilityLabel("\(folder) entfernen")
                    }
                }
                Button { showPicker = true } label: {
                    GroupedLabelRow(icon: "folder.badge.plus", iconColor: theme.accent, title: "Ordner hinzufügen …",
                                    titleColor: theme.accent)
                }
                .buttonStyle(.plain)
            }
            if let fullDisk, fullDisk.granted == false {
                FullDiskAccessRow(status: fullDisk)
            }
        }
        .id("computerAccess")
        .task(id: bot.id) {
            guard !store.isMock, let service = store.service else {
                if store.isMock && ProcessInfo.processInfo.arguments.contains("-fdamissing") {
                    fullDisk = FullDiskAccessStatus(granted: false, process: "AIS Scoops Server")
                }
                return
            }
            fullDisk = (try? await service.workspace())?.fullDiskAccess
        }
        .sheet(isPresented: $showPicker) {
            WorkspacePickerSheet(title: String(localized: "Projektordner wählen"), chooseTitle: String(localized: "Diesen Ordner freigeben"),
                                 startPath: access.folders.last ?? "~", onChoose: { path in add(path) })
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(AccessMode.allCases) { m in
                Button { set(mode: m) } label: {
                    if m == access.accessMode { Label(m.title, systemImage: "checkmark") } else { Label(m.title, systemImage: m.icon) }
                }
            }
        } label: {
            GroupedLabelRow(icon: access.accessMode.icon, iconColor: theme.accent, title: access.accessMode.title,
                            subtitle: access.accessMode.detail) { chevrons }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Modus: \(access.accessMode.title)")
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(AccessScope.allCases) { s in
                Button { set(scope: s) } label: {
                    if s == access.accessScope { Label(s.title, systemImage: "checkmark") } else { Label(s.title, systemImage: s.icon) }
                }
            }
        } label: {
            GroupedLabelRow(icon: access.accessScope.icon, iconColor: theme.accent, title: access.accessScope.title,
                            subtitle: access.accessScope.detail) { chevrons }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Standard-Bereich: \(access.accessScope.title)")
    }

    private var chevrons: some View {
        Image(systemName: "chevron.up.chevron.down").appFont(11, weight: .semibold).foregroundStyle(theme.textTertiary)
    }

    private var footer: String {
        String(localized: "Gilt im Chat und für Aufgaben (dort pro Aufgabe änderbar). Mails, Posten, Anrufe und Käufe fragen immer mit einer Karte. \(bot.name) kann den Bereich nie selbst erweitern.")
    }

    private func set(mode: AccessMode) {
        var a = access
        a.mode = mode.rawValue
        Task { await store.setComputerAccess(bot.id, a) }
    }

    private func set(scope: AccessScope) {
        var a = access
        if scope == .projects && a.folders.isEmpty {
            showPicker = true  // erst einen Ordner wählen, dann umstellen (add)
            return
        }
        a.scope = scope.rawValue
        Task { await store.setComputerAccess(bot.id, a) }
    }

    private func add(_ path: String) {
        var a = access
        if !a.folders.contains(path) { a.folders.append(path) }
        a.scope = AccessScope.projects.rawValue
        Task { await store.setComputerAccess(bot.id, a) }
    }

    private func remove(_ path: String) {
        var a = access
        a.folders.removeAll { $0 == path }
        guard !a.folders.isEmpty else { return }
        Task { await store.setComputerAccess(bot.id, a) }
    }
}

// MARK: - Aufgaben: Bereich wählen (Formular und Eingabefeld)

/// Bereich einer Aufgabe: „Wie Scoop“, „Nur Arbeitsordner“, Projektordner (die des Scoops oder eigene) oder „Überall“.
struct TaskScopeMenu: View {
    @Binding var choice: TaskAccessChoice?
    var bot: Bot?
    /// Kompakte Pille (Eingabefeld) statt Zeilenwert (Formular)
    var pill = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showFolders = false

    private var botAccess: ScoopAccess { bot?.computerAccess ?? ScoopAccess() }
    private var effectiveScope: AccessScope { choice?.accessScope ?? botAccess.accessScope }
    private var effectiveFolders: [String] { choice?.accessScope == nil ? botAccess.folders : (choice?.folders ?? []) }

    var body: some View {
        Menu {
            Button { choice = nil } label: {
                let title = String(localized: "Wie Scoop (\(botAccess.scopeText))")
                if choice == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            option(.workspace, nil)
            if botAccess.accessScope == .projects, !botAccess.folders.isEmpty {
                option(.projects, botAccess.folders, title: String(localized: "Projektordner des Scoops"))
            }
            Button { showFolders = true } label: { Label("Projektordner wählen …", systemImage: AccessScope.projects.icon) }
            option(.home, nil)
        } label: {
            if pill {
                TaskPillLabel(icon: effectiveScope.icon, text: pillText, active: choice != nil)
            } else {
                HStack(spacing: 4) {
                    Text(choice == nil ? String(localized: "Wie Scoop") : effectiveScope.text(folders: effectiveFolders))
                        .adaptiveLineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").appFont(10, weight: .semibold)
                }
                .appFont(14.5)
                .foregroundStyle(theme.textSecondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Wo die Aufgabe am Mac arbeiten darf")
        .accessibilityLabel(accessibilityText)
        .sheet(isPresented: $showFolders) {
            ProjectFoldersSheet(initial: effectiveScope == .projects ? effectiveFolders : []) { folders in
                choice = TaskAccessChoice(scope: AccessScope.projects.rawValue, folders: folders)
            }
            .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }

    private var accessibilityText: String {
        let scope = effectiveScope.text(folders: effectiveFolders)
        return choice == nil ? String(localized: "Bereich: wie Scoop, \(scope)") : String(localized: "Bereich: \(scope)")
    }

    /// Kurz für die Pille: „Arbeitsordner“, Ordnername bei einem Projektordner, „2 Ordner“, „Überall“
    private var pillText: String {
        switch effectiveScope {
        case .workspace: return String(localized: "Arbeitsordner")
        case .home: return String(localized: "Überall")
        case .projects:
            let f = effectiveFolders
            return f.count == 1 ? (f[0] as NSString).lastPathComponent : String(localized: "\(f.count) Ordner")
        }
    }

    private func option(_ scope: AccessScope, _ folders: [String]?, title: String? = nil) -> some View {
        Button { choice = TaskAccessChoice(scope: scope.rawValue, folders: folders) } label: {
            let selected = choice?.accessScope == scope && (scope != .projects || choice?.folders == folders)
            Label(title ?? scope.title, systemImage: selected ? "checkmark" : scope.icon)
        }
    }
}

/// Blatt: Projektordner für eine Aufgabe zusammenstellen (Ordnerliste des Servers).
struct ProjectFoldersSheet: View {
    var initial: [String]
    var onDone: ([String]) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var showPicker = false
    @State private var prepared = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Projektordner", icon: AccessScope.projects.icon) { dismiss() }
            ScrollView {
                GroupedStack {
                    GroupedSection("Ordner", footer: "Die Aufgabe darf in diesen Ordnern auf dem Server-Mac arbeiten, zusätzlich zum Arbeitsordner, mit deinem echten Home (Git, SSH, gh).",
                                   dividerInset: 50) {
                        ForEach(folders, id: \.self) { folder in
                            GroupedLabelRow(icon: "folder.fill", iconColor: theme.textSecondary,
                                            title: (folder as NSString).lastPathComponent, subtitle: folder) {
                                Button { folders.removeAll { $0 == folder } } label: {
                                    Image(systemName: "minus.circle.fill").appFont(17).foregroundStyle(theme.danger)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(folder) entfernen")
                            }
                        }
                        Button { showPicker = true } label: {
                            GroupedLabelRow(icon: "folder.badge.plus", iconColor: theme.accent, title: "Ordner hinzufügen …",
                                            titleColor: theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        onDone(folders)
                        dismiss()
                    } label: { Text("Übernehmen").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(folders.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        .onAppear {
            guard !prepared else { return }
            prepared = true
            folders = initial
            if folders.isEmpty { showPicker = true }
        }
        .sheet(isPresented: $showPicker) {
            WorkspacePickerSheet(title: String(localized: "Projektordner wählen"), chooseTitle: String(localized: "Diesen Ordner nehmen"),
                                 startPath: folders.last ?? "~", onChoose: { path in
                if !folders.contains(path) { folders.append(path) }
            })
            .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #else
        .presentationDetents([.large])
        #endif
    }
}

// MARK: - Board: Modus und Bereich einer Aufgabe

/// Kleines Kennzeichen auf der Board-Karte, wenn eine Aufgabe mehr als den Arbeitsordner darf oder anders fragt.
struct TaskAccessBadge: View {
    let access: TaskAccess
    @Environment(\.theme) private var theme

    var body: some View {
        Label(access.scopeText, systemImage: access.accessScope.icon)
            .appFont(11.5, weight: .semibold)
            .adaptiveLineLimit(1)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(theme.hover, in: Capsule())
            .padding(.top, 3)
            .accessibilityLabel("Bereich: \(access.scopeText), Modus \(access.accessMode.title)")
    }

    /// Nur zeigen, wenn es vom Standard (Automatisch, Nur Arbeitsordner) abweicht
    static func shows(_ a: TaskAccess?) -> Bool {
        guard let a else { return false }
        return a.accessScope != .workspace || a.accessMode != .auto || a.custom == true
    }
}

/// Zeile im Aufgaben-Detail: „Rechner-Zugriff: Automatisch · Projektordner (App)“
struct TaskAccessDetail: View {
    let access: TaskAccess
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("\(access.accessMode.title) · \(access.scopeText)", systemImage: access.accessMode.icon)
                .appFont(13, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if access.accessScope == .projects, let folders = access.folders, !folders.isEmpty {
                Text(folders.joined(separator: "\n"))
                    .appFont(11.5)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(access.custom == true
                            ? String(localized: "Rechner-Zugriff: \(access.accessMode.title), \(access.scopeText), nur für diese Aufgabe")
                            : String(localized: "Rechner-Zugriff: \(access.accessMode.title), \(access.scopeText)"))
    }
}
