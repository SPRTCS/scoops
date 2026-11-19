import AppKit
import Foundation
import Observation
import Sparkle

/// Selbstaktualisierung über Sparkle (docs/updates.md).
///
/// Feed und Schlüssel stehen in der Info.plist (`SUFeedURL`, `SUPublicEDKey`, siehe project.yml). Sparkle prüft
/// automatisch und lädt neue Versionen im Hintergrund. Installiert wird ohne Dialog, aber erst, wenn kein Scoop
/// arbeitet: Der Server meldet laufende Läufe in `GET /api/setup` (`server.active_runs`), als Rechner zählt eine
/// laufende Steuerung dieses Macs. Danach beendet Sparkle die App (der Server stoppt sauber mit,
/// `applicationShouldTerminate`), ersetzt sie und startet sie neu; der Server fährt mit der App wieder hoch.
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// Nach so langer erfolgloser Suche nach einer ruhigen Minute wird trotzdem installiert.
    static let maxWait: TimeInterval = 6 * 3600
    /// Abstand der Prüfungen, ob gerade ein Scoop arbeitet.
    static let pollInterval: Duration = .seconds(15)
    /// So viele Prüfungen hintereinander ohne Lauf, bevor installiert wird (≈ 30 s Ruhe).
    static let idleChecksNeeded = 2

    /// Heruntergeladene Version, die auf eine ruhige Minute wartet (Anzeige im Menü).
    private(set) var pendingVersion: String?
    private(set) var waitingSince: Date?

    @ObservationIgnored weak var server: ServerController?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    private override init() {
        super.init()
        // Ohne Feed (Entwicklungs-Build ohne Info.plist-Eintrag) bleibt Sparkle aus.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// „Nach Updates suchen …“: Sparkles Dialog (der einzige sichtbare Weg, gedacht für den Klick im Menü).
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: Arbeitet gerade ein Scoop?

    func isBusy() async -> Bool {
        guard let server else { return false }
        if server.model.isControlled { return true }
        guard server.isServer, server.manager.phase == .running else { return false }
        await server.manager.refresh()
        return (server.manager.server?["active_runs"]?.int ?? 0) > 0
    }

    /// Meldung ins Systemprotokoll und ins Server-Protokoll (Menü › „Protokoll öffnen“).
    func log(_ message: String) {
        NSLog("AIS Scoops Server: %@", message)
        guard let url = server?.manager.logURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [Update] \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }

    private func installWhenIdle(version: String, install: @escaping () -> Void) {
        waitTask?.cancel()
        pendingVersion = version
        // Meldet Sparkle bei der nächsten geplanten Prüfung dasselbe (oder ein neueres) Update erneut, zählt die
        // Höchstwartezeit weiter ab der ersten Meldung – sonst setzte jede Prüfung sie zurück.
        let start = waitingSince ?? Date()
        waitingSince = start
        log("Update \(version) geladen, wird installiert, sobald kein Scoop arbeitet")
        waitTask = Task { [weak self] in
            var idle = 0
            var reportedBusy = false
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isBusy() {
                    if !reportedBusy { self.log("Update \(version) wartet: ein Scoop arbeitet gerade") }
                    reportedBusy = true
                    idle = 0
                } else {
                    reportedBusy = false
                    idle += 1
                }
                let waited = Date().timeIntervalSince(start)
                if idle >= Self.idleChecksNeeded || waited >= Self.maxWait {
                    self.log("Installiere Update \(version) (\(idle >= Self.idleChecksNeeded ? "kein Scoop aktiv" : "Höchstwartezeit erreicht")), App startet neu")
                    install()
                    return
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Fertig geladenes Update: nicht erst beim Beenden installieren (die App läuft dauerhaft), sondern sobald
    /// kein Scoop arbeitet. `true` = wir rufen `immediateInstallHandler` selbst auf.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installWhenIdle(version: "\(item.displayVersionString) (\(item.versionString))", install: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        // „Keine neue Version“ ist kein Fehler.
        if code != Int(SUError.noUpdateError.rawValue) {
            log("Update abgebrochen: \(error.localizedDescription)")
        }
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// Menüleisten-App ohne Dock-Symbol: Sparkle soll geplante Hinweise sanft zeigen (sonst Konsolenwarnung).
    /// Bei automatischen Updates erscheinen sie ohnehin nur, wenn Sparkle eine Rückfrage braucht.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
