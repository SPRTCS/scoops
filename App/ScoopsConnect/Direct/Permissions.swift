import AppKit
import ApplicationServices
import CoreGraphics

/// Prüft die beiden Rechte, die der direkte Modus braucht. Erteilt sie nie selbst.
enum Permissions {
    static var screenRecording: Bool {
        #if DEBUG
        if let p = previewOverride { return p.screen }
        #endif
        return CGPreflightScreenCaptureAccess()
    }
    static var accessibility: Bool {
        #if DEBUG
        if let p = previewOverride { return p.accessibility }
        #endif
        return AXIsProcessTrusted()
    }

    #if DEBUG
    /// Nur für Renderings des Assistenten (`-rendersetup`)
    static var previewOverride: (screen: Bool, accessibility: Bool)?
    #endif

    /// Fragt die Bildschirmaufnahme an (zeigt beim ersten Mal den System-Dialog).
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Trägt die App in die Bedienungshilfen-Liste ein und zeigt den System-Dialog.
    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Festplattenvollzugriff (Server 1.29, docs/rechnerzugriff.md): prüft ohne Abfrage. Die Datenschutz-Datenbank des
    /// Nutzers ist nur mit Festplattenvollzugriff lesbar; ohne liefert macOS sofort einen Fehler, ein Dialog erscheint
    /// nie. Der Server läuft als Kindprozess der App und hat damit dieselbe Freigabe.
    static var fullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Library/Application Support/com.apple.TCC/TCC.db",
                     home + "/Library/Application Support/com.apple.TCC/TCC.db"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let h = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? h.close() }
            return (try? h.read(upToCount: 16)) != nil
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil
    }

    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
