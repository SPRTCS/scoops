import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Bildschirmfotos über ScreenCaptureKit, in logischer Auflösung (Punkte statt Retina-Pixel).
enum ScreenCapture {
    enum Failure: LocalizedError {
        case noPermission, noDisplay, encoding
        var errorDescription: String? {
            switch self {
            case .noPermission: "Bildschirmaufnahme ist für Scoops Connect nicht erlaubt (Systemeinstellungen → Datenschutz & Sicherheit)."
            case .noDisplay: "Kein Bildschirm gefunden."
            case .encoding: "Bildschirmfoto konnte nicht als PNG gespeichert werden."
            }
        }
    }

    /// Bildschirm, den die Scoops sehen und bedienen: der Hauptbildschirm, außer ScreenCaptureKit kann ihn
    /// nicht aufnehmen (z. B. zugeklapptes MacBook mit externem/virtuellem Bildschirm) – dann der erste
    /// aufnehmbare. Größe, Screenshot und Mauskoordinaten beziehen sich immer auf diesen Bildschirm.
    static func targetDisplay() async -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        guard Permissions.screenRecording,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return main }
        if content.displays.contains(where: { $0.displayID == main }) { return main }
        return content.displays.first?.displayID ?? main
    }

    static func png(of displayID: CGDirectDisplayID) async throws -> Data {
        guard Permissions.screenRecording else { throw Failure.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        // Eigene Fenster (Einstellungen, Menü) nicht mit aufnehmen.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let size = CGDisplayBounds(display.displayID).size
        config.width = max(1, Int(size.width.rounded()))
        config.height = max(1, Int(size.height.rounded()))
        config.showsCursor = true
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try png(image)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encoding }
        return data as Data
    }
}
