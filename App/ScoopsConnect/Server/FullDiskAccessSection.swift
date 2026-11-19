import AppKit
import SwiftUI

// Festplattenvollzugriff (Server 1.29, docs/rechnerzugriff.md): Damit Scoops in Projektordnern und im ganzen Home
// arbeiten können, ohne dass macOS bei jedem Ordner (Schreibtisch, Dokumente, iCloud …) neu fragt. Die Freigabe gilt
// für „AIS Scoops Server“; der Server und seine Agenten laufen als Kindprozesse der App und erben sie. Sie bleibt bei
// Updates erhalten (gleiche Developer-ID-Signatur). Die App prüft nur und öffnet die Systemeinstellungen, sie
// erteilt nichts selbst.

extension ServerManager {
    /// Vom Server gemeldet (`full_disk_access` in /api/setup); `nil`, solange der Server nichts meldet
    var fullDiskGranted: Bool? { server?["full_disk_access"]?["granted"]?.bool }
    var fullDiskProcess: String? { server?["full_disk_access"]?["process"]?.string }
}

struct FullDiskAccessView: View {
    let manager: ServerManager
    @State private var tick = 0

    /// Server-Meldung zuerst (sie zeigt die Identität, die wirklich zählt), sonst die eigene Prüfung der App
    private var granted: Bool {
        _ = tick
        return manager.fullDiskGranted ?? Permissions.fullDiskAccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionRow(
                title: "Festplattenvollzugriff",
                detail: "Damit Scoops in deinen Projektordnern und im Home arbeiten können, ohne dass macOS bei jedem Ordner neu fragt.",
                symbol: "internaldrive",
                granted: granted,
                request: Permissions.openFullDiskAccessSettings,
                openSettings: Permissions.openFullDiskAccessSettings)
            if !granted {
                Text("So geht’s: Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff → „\(manager.fullDiskProcess ?? "AIS Scoops Server")“ einschalten. Fehlt der Eintrag, mit „+“ die App aus dem Programme-Ordner hinzufügen. Danach den Server einmal neu starten. Die Freigabe bleibt bei Updates erhalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Nach dem Erlauben in den Systemeinstellungen ohne Neustart der Ansicht aktualisieren
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !granted { await manager.refresh(); tick += 1 }
            }
        }
    }
}

struct FullDiskAccessSection: View {
    let manager: ServerManager

    var body: some View {
        Section {
            FullDiskAccessView(manager: manager)
        } header: {
            Text("Festplattenvollzugriff")
        } footer: {
            Text("Ohne Festplattenvollzugriff arbeiten Scoops weiter im Arbeitsordner; für Ordner in Schreibtisch, Dokumente oder iCloud fragt macOS dann einzeln nach.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
