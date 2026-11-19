import SwiftUI

// Arbeitsordner der Scoops (Server 1.27, docs/arbeitsordner.md): ein Ordner auf dem Server-Mac, darin je Scoop ein
// Unterordner. Gespeicherte Dateien und Aufgaben-Ergebnisse landen dort zusätzlich zur Bibliothek. Nur der Admin sieht
// und ändert ihn; ohne Mac-Dateidialog (iPhone/iPad, entfernter Server) wählt man über eine einfache Ordnerliste.

// MARK: Modelle

nonisolated struct WorkspaceStatus: Decodable, Hashable, Sendable {
    var path: String
    var absolute: String?
    var isDefault: Bool?
    var exists: Bool?
    var writable: Bool?
    var icloud: Bool?
    var error: String?
    var scoops: [WorkspaceScoopFolder]?
    var previous: [WorkspacePreviousFolder]?
    /// v1.29: Festplattenvollzugriff des Server-Prozesses
    var fullDiskAccess: FullDiskAccessStatus? = nil
}

nonisolated struct WorkspaceScoopFolder: Decodable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String
    var exists: Bool?
}

/// Früherer Arbeitsordner, in dem noch Dateien liegen (beim Wechsel wird nichts verschoben)
nonisolated struct WorkspacePreviousFolder: Decodable, Hashable, Sendable {
    var path: String
    var folders: [String]
}

nonisolated struct WorkspaceListing: Decodable, Hashable, Sendable {
    var path: String
    var parent: String?
    var name: String?
    var dirs: [WorkspaceDir]
    var truncated: Bool?
}

nonisolated struct WorkspaceDir: Decodable, Hashable, Sendable, Identifiable {
    var name: String
    var path: String
    var id: String { path }
}

// MARK: Standard (ältere Server) und Demo-Modus

extension BotService {
    func workspace() async throws -> WorkspaceStatus {
        throw APIError(status: 404, message: "Der Server kennt den Arbeitsordner noch nicht (ab Server 1.27).")
    }
    func setWorkspace(path: String) async throws -> WorkspaceStatus { try await workspace() }
    func browseWorkspace(path: String) async throws -> WorkspaceListing {
        throw APIError(status: 404, message: "Der Server kennt den Arbeitsordner noch nicht (ab Server 1.27).")
    }
    func createWorkspaceFolder(parent: String, name: String) async throws -> WorkspaceListing {
        try await browseWorkspace(path: parent)
    }
}

extension MockService {
    private static var mockWorkspace = "~/Desktop/Scoops"
    private static var mockTree: [String: [String]] = [
        "~": ["Desktop", "Documents", "Downloads", "Scoops"],
        "~/Desktop": ["Projekte", "Scoops"],
        "~/Desktop/Scoops": ["Ava", "Codi", "Lisa", "Mila", "Tina"],
        "~/Documents": ["Notizen", "Rechnungen"],
    ]

    func workspace() async throws -> WorkspaceStatus {
        let path = Self.mockWorkspace
        let names = Self.mockTree[path] ?? []
        return WorkspaceStatus(path: path, absolute: path, isDefault: path == "~/Scoops", exists: true, writable: true,
                               icloud: path.hasPrefix("~/Desktop") || path.hasPrefix("~/Documents"), error: nil,
                               scoops: names.map { WorkspaceScoopFolder(id: $0, name: $0, path: "\(path)/\($0)", exists: true) },
                               previous: path == "~/Desktop/Scoops" ? [] : [WorkspacePreviousFolder(path: "~/Desktop/Scoops",
                                                                                                    folders: ["Ava", "Codi"])])
    }

    func setWorkspace(path: String) async throws -> WorkspaceStatus {
        guard path.hasPrefix("~") || path.hasPrefix("/") else {
            throw APIError(status: 400, message: "Bitte einen absoluten Pfad angeben (beginnt mit / oder ~/).")
        }
        Self.mockWorkspace = path
        return try await workspace()
    }

    func browseWorkspace(path: String) async throws -> WorkspaceListing {
        let parent: String? = path == "~" ? nil : String(path[..<(path.lastIndex(of: "/") ?? path.endIndex)])
        let name = path == "~" ? "Home" : String(path.split(separator: "/").last ?? "")
        return WorkspaceListing(path: path, parent: parent, name: name,
                                dirs: (Self.mockTree[path] ?? []).map { WorkspaceDir(name: $0, path: "\(path)/\($0)") },
                                truncated: false)
    }

    func createWorkspaceFolder(parent: String, name: String) async throws -> WorkspaceListing {
        Self.mockTree[parent, default: []].append(name)
        Self.mockTree[parent]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return try await browseWorkspace(path: "\(parent)/\(name)")
    }
}

// MARK: Einstellungen → Arbeitsordner

/// Abschnitt in den Einstellungen. Erscheint nur, wenn der Server den Arbeitsordner kennt und du Admin bist.
struct WorkspaceSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var status: WorkspaceStatus?
    /// Server kennt den Arbeitsordner nicht (älter als 1.27) oder du bist nicht Admin → Abschnitt ausblenden
    @State private var unavailable = false
    @State private var showPicker = ProcessInfo.processInfo.arguments.contains("-workspacepicker")

    var body: some View {
        if !unavailable { section }
    }

    private var section: some View {
        Group {
            if status == nil {
                GroupedSection("Arbeitsordner") {
                    GroupedLabelRow(icon: "folder", iconColor: theme.textSecondary, title: "Wird geladen …")
                }
            } else if let status {
                GroupedSection("Arbeitsordner", footer: footer(status)) {
                    Button { showPicker = true } label: {
                        GroupedLabelRow(icon: "folder", iconColor: theme.accent, title: status.path,
                                        subtitle: "Auf dem Server-Mac, je Scoop ein Unterordner") { DisclosureChevron() }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ordner ändern")
                    if let e = status.error, !e.isEmpty {
                        GroupedLabelRow(icon: "exclamationmark.triangle", iconColor: theme.warning, title: "Ordner nicht erreichbar",
                                        subtitle: e)
                    }
                    if let fda = status.fullDiskAccess, fda.granted == false {
                        FullDiskAccessRow(status: fda)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            WorkspacePickerSheet(current: status) { status = $0 }
                .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }

    private func footer(_ s: WorkspaceStatus) -> String {
        var text = "Dateien, die deine Scoops speichern, und Ergebnisse ihrer Aufgaben landen dort zusätzlich zur Bibliothek "
            + "(Unterordner „Dateien“ und „Aufgaben“)."
        if s.icloud == true { text += " Liegt in Schreibtisch oder Dokumente: Mit iCloud siehst du die Dateien auch unterwegs." }
        for prev in s.previous ?? [] {
            text += " Frühere Dateien liegen weiter in \(prev.path) (\(prev.folders.joined(separator: ", "))); verschoben wurde nichts."
        }
        return text
    }

    private func load() async {
        guard let service = store.service else { unavailable = true; return }
        do { status = try await service.workspace() } catch { unavailable = true }
    }
}

/// Ordnerauswahl über den Server: nur Ordner im Home-Ordner des Server-Macs, keine versteckten. Wählt den
/// Arbeitsordner (speichert ihn) oder – mit `onChoose` – einfach einen Ordner (z. B. Projektordner, v1.29).
struct WorkspacePickerSheet: View {
    var current: WorkspaceStatus?
    var title = "Arbeitsordner wählen"
    var chooseTitle = "Diesen Ordner verwenden"
    var startPath: String?
    var onSaved: ((WorkspaceStatus) -> Void)?
    var onChoose: ((String) -> Void)?

    init(current: WorkspaceStatus?, onSaved: @escaping (WorkspaceStatus) -> Void) {
        self.current = current
        self.onSaved = onSaved
    }

    init(title: String, chooseTitle: String, startPath: String?, onChoose: @escaping (String) -> Void) {
        self.title = title
        self.chooseTitle = chooseTitle
        self.startPath = startPath
        self.onChoose = onChoose
    }

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var listing: WorkspaceListing?
    @State private var error: String?
    @State private var saving = false
    @State private var showNewFolder = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title, icon: "folder") { dismiss() }
            ScrollView {
                GroupedStack {
                    GroupedSection("Ausgewählt", footer: "Ordner auf dem Server-Mac. Tippe auf einen Unterordner, um ihn zu öffnen.") {
                        GroupedLabelRow(icon: "folder.fill", iconColor: theme.accent, title: listing?.path ?? "…",
                                        subtitle: current.map { "Bisher: \($0.path)" })
                    }
                    GroupedSection("Ordner", footer: listing?.truncated == true ? "Es werden nur die ersten 500 Ordner gezeigt." : nil) {
                        if let parent = listing?.parent {
                            Button { Task { await open(parent) } } label: {
                                GroupedLabelRow(icon: "arrow.turn.left.up", title: "Zurück", subtitle: parent)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(listing?.dirs ?? []) { dir in
                            Button { Task { await open(dir.path) } } label: {
                                GroupedLabelRow(icon: "folder", iconColor: theme.textSecondary, title: dir.name) { DisclosureChevron() }
                            }
                            .buttonStyle(.plain)
                        }
                        if let listing, listing.dirs.isEmpty {
                            Text("Keine Unterordner").font(.system(size: 15)).foregroundStyle(theme.textSecondary).groupedRow()
                        }
                        Button { newName = ""; showNewFolder = true } label: {
                            GroupedLabelRow(icon: "folder.badge.plus", iconColor: theme.accent, title: "Neuer Ordner …",
                                            titleColor: theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(listing == nil)
                    }
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, GroupedMetrics.rowInset)
                    }
                    Button { Task { await save() } } label: {
                        Text(saving ? "Wird gespeichert …" : chooseTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(listing == nil || saving)
                    if onChoose == nil {
                        Text("Bestehende Dateien werden nicht verschoben. Im neuen Ordner bekommt jeder Scoop seinen eigenen Unterordner.")
                            .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, GroupedMetrics.rowInset)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground)
        .task {
            if listing == nil, !(await open(startPath ?? current?.path ?? "~", quiet: true)) { await open("~") }
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { Task { await create() } }
        } message: {
            Text("Wird in \(listing?.path ?? "~") angelegt.")
        }
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
    }

    @discardableResult
    private func open(_ path: String, quiet: Bool = false) async -> Bool {
        guard let service = store.service else { return false }
        do {
            listing = try await service.browseWorkspace(path: path)
            error = nil
            return true
        } catch {
            if !quiet { self.error = error.localizedDescription }
            return false
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = store.service, let parent = listing?.path, !name.isEmpty else { return }
        do {
            listing = try await service.createWorkspaceFolder(parent: parent, name: name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        if let onChoose, let path = listing?.path {
            onChoose(path)
            dismiss()
            return
        }
        guard let service = store.service, let path = listing?.path else { return }
        saving = true
        defer { saving = false }
        do {
            let s = try await service.setWorkspace(path: path)
            onSaved?(s)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
