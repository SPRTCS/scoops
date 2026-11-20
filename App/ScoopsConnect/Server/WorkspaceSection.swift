import AppKit
import SwiftUI

// Arbeitsordner der Scoops (Server 1.27, docs/arbeitsordner.md): Darin hat jeder Scoop einen Unterordner, in dem seine
// Dateien und Aufgaben-Ergebnisse zusätzlich zur Bibliothek landen. Gesetzt über PATCH /api/setup/config
// (`workspace_dir`), der Server prüft und legt den Ordner an.

extension ServerManager {
    var workspace: JSONValue? { server?["workspace"] }
    /// Anzeige mit `~`, z. B. „~/Desktop/Scoops“
    var workspacePath: String? { workspace?["path"]?.string }
    var workspaceURL: URL? { workspace?["absolute"]?.string.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var workspaceError: String? { workspace?["error"]?.string }
    var workspaceIsICloud: Bool { workspace?["icloud"]?.bool ?? false }
    /// Frühere Arbeitsordner, in denen noch Dateien liegen (werden beim Wechsel nicht verschoben)
    var workspacePrevious: [(path: String, folders: [String])] {
        (workspace?["previous"]?.array ?? []).compactMap { p in
            guard let path = p["path"]?.string else { return nil }
            return (path, (p["folders"]?.array ?? []).compactMap(\.string))
        }
    }

    func setWorkspace(_ url: URL) async throws {
        try await patchConfig(["workspace_dir": url.path])
    }
}

struct WorkspaceSection: View {
    let manager: ServerManager
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Section {
            LabeledContent("Arbeitsordner") {
                Text(manager.workspacePath ?? "–")
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Auswählen …") { choose() }
                    .disabled(saving || manager.phase != .running)
                Button("Im Finder zeigen") { reveal() }
                    .disabled(manager.workspaceURL == nil)
                if saving { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            if let e = manager.workspaceError, !e.isEmpty, message == nil {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            if manager.workspaceIsICloud {
                Text("Liegt in Schreibtisch/Dokumente: Mit iCloud-Synchronisierung siehst du die Dateien auch auf anderen Geräten. macOS fragt beim ersten Zugriff einmal, ob der Server dort Dateien ablegen darf – bitte „Erlauben“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.workspacePrevious, id: \.path) { prev in
                Text("Frühere Dateien liegen weiter in \(prev.path) (\(prev.folders.joined(separator: ", "))). Sie wurden nicht verschoben.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Arbeitsordner")
        } footer: {
            Text("Jeder Scoop hat hier einen eigenen Ordner. Dateien, die er speichert, und Ergebnisse seiner Aufgaben landen dort zusätzlich zur Bibliothek (Unterordner „Dateien“ und „Aufgaben“).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Auswählen", comment: "Knopf im Ordner-Dialog")
        panel.message = String(localized: "Ordner für die Dateien deiner Scoops wählen")
        panel.directoryURL = manager.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        message = nil
        Task {
            do { try await manager.setWorkspace(url) } catch { message = error.localizedDescription }
            saving = false
        }
    }

    private func reveal() {
        guard let url = manager.workspaceURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
