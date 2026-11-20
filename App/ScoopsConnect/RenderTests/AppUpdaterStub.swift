import Foundation
import Observation

/// Ersatz für `AppUpdater` (App/AppUpdater.swift) in den Render-Tests: gleiche Schnittstelle, aber ohne Sparkle.
/// Es wird nie nach Updates gesucht und nichts geladen.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    var isAvailable = true
    var pendingVersion: String?
    @ObservationIgnored weak var server: ServerController?

    func checkForUpdates() {}
}
