import Foundation
import QuartzCore

/// Einfache Messung „Chatwechsel bis erstes Bild“ (nur Debug-Ausgabe, Startargument `-perflog`).
enum PerfLog {
    private static var started: (id: String, t: CFTimeInterval)?
    static let enabled = ProcessInfo.processInfo.arguments.contains("-perflog")

    static func chatSwitchStarted(_ id: String?) {
        guard enabled, let id else { return }
        started = (id, CACurrentMediaTime())
        bodyLogged = nil
    }

    private static var bodyLogged: String?
    static func chatBody(_ id: String) {
        guard enabled, let s = started, s.id == id, bodyLogged != id else { return }
        bodyLogged = id
        print(String(format: "[perf] body %@ %.1f ms", id, (CACurrentMediaTime() - s.t) * 1000))
    }

    /// Aufruf in `onAppear` des Chats; gemessen wird bis zum nächsten Runloop-Durchlauf (nach dem Commit).
    static func chatAppeared(_ id: String) {
        guard enabled, let s = started, s.id == id else { return }
        let appear = (CACurrentMediaTime() - s.t) * 1000
        DispatchQueue.main.async {
            let frame = (CACurrentMediaTime() - s.t) * 1000
            print(String(format: "[perf] chat %@ onAppear %.1f ms, nächster Runloop %.1f ms", id, appear, frame))
        }
        started = nil
    }
}

#if DEBUG
import OSLog

/// Geometrie-Protokoll des Verlaufs (nur Debug, Startargument `-scrolllog`): Versatz, Inhaltshöhe, Insets und
/// Ende-Wert je Änderung. Ausgabe im Systemprotokoll, Subsystem `com.ais.aisbot`, Kategorie `scroll`.
enum ScrollLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-scrolllog")
    private static let logger = Logger(subsystem: "com.ais.aisbot", category: "scroll")
    static func note(_ text: String) {
        guard enabled else { return }
        logger.log("[scroll] \(text, privacy: .public)")
    }
}
#endif
