import Foundation
import Synchronization

/// Zeitgrenzen für Server-Befehle.
///
/// Der Server wartet auf jede Antwort höchstens 60 s, auf `screenshot` 30 s (`Server/src/aisbot/nodes.py`,
/// `CMD_TIMEOUT`/`SCREENSHOT_TIMEOUT`). Die App antwortet knapp davor selbst mit einem klaren Fehler. Vor allem aber
/// wartet sie nicht weiter auf einen hängenden Befehl (z. B. `read_bytes` auf eine Datei, die erst aus iCloud
/// geladen wird): Befehle laufen nacheinander, und ein hängender Befehl hielt früher alle folgenden auf, bis die
/// Verbindung neu aufgebaut wurde.
nonisolated enum CommandDeadline {
    static let general: Duration = .seconds(55)
    static let screenshot: Duration = .seconds(27)

    static func limit(for command: String) -> Duration { command == "screenshot" ? screenshot : general }

    static func timeoutMessage(_ command: String, after limit: Duration) -> String {
        let s = Int(limit.components.seconds)
        switch command {
        case "read_bytes":
            return "read_bytes hängt (keine Antwort nach \(s) s). Die Datei lädt evtl. noch aus iCloud oder liegt "
                + "auf einem nicht erreichbaren Laufwerk. In einer Minute noch einmal versuchen."
        case "write_bytes":
            return "write_bytes hängt (keine Antwort nach \(s) s). Der Zielordner ist evtl. nicht erreichbar."
        case "screenshot":
            return "screenshot hängt (keine Antwort nach \(s) s). Die Bildschirmaufnahme reagiert gerade nicht."
        default:
            return "\(command) hängt (keine Antwort nach \(s) s). Die App wartet nicht weiter darauf."
        }
    }

    /// Führt `work` aus und liefert sein Ergebnis, nach `limit` aber spätestens einen Fehler.
    ///
    /// Bewusst ohne `withTaskGroup`/`async let`: Strukturierte Nebenläufigkeit wartet beim Verlassen auf alle
    /// Kinder, ein blockierender Aufruf hielte den Aufrufer also trotzdem fest. Hier laufen Arbeit und Wecker als
    /// unstrukturierte Tasks; wer zuerst fertig ist, setzt die Continuation fort, der andere läuft ins Leere.
    /// Eine hängende Arbeit läuft im Hintergrund weiter, ihr Ergebnis wird verworfen.
    ///
    /// Wird der Aufrufer abgebrochen (Verbindung getrennt, `runSession` räumt seine Task-Gruppe ab), kehrt `run`
    /// sofort zurück. Sonst wartete die Gruppe auf den hängenden Befehl und die App verbände sich nie neu.
    static func run(_ command: String, limit: Duration,
                    _ work: @escaping @Sendable () async -> JSONValue) async -> JSONValue {
        let once = Once()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
                once.arm(cont)
                let timer = Task {
                    // Enge Toleranz: Die App läuft im Hintergrund, macOS darf Wecker sonst spürbar verschieben.
                    try? await Task.sleep(for: limit, tolerance: .milliseconds(200))
                    if Task.isCancelled { return }
                    once.resume(CmdResult.fail(timeoutMessage(command, after: limit)))
                }
                Task {
                    let result = await work()
                    timer.cancel()
                    once.resume(result)
                }
            }
        } onCancel: {
            once.resume(CmdResult.fail("\(command) abgebrochen (Verbindung getrennt)"))
        }
    }

    /// Ergebnis, das genau einmal geliefert wird (vom Schnellsten: Arbeit, Wecker oder Abbruch). Der Abbruch kann
    /// kommen, bevor die Continuation steht; dann wird das Ergebnis gemerkt und beim Scharfschalten geliefert.
    private final class Once: Sendable {
        private struct State {
            var cont: CheckedContinuation<JSONValue, Never>?
            var early: JSONValue?
            var done = false
        }

        private let state = Mutex(State())

        func arm(_ c: CheckedContinuation<JSONValue, Never>) {
            let early = state.withLock { s -> JSONValue? in
                if s.done { return s.early }
                s.cont = c
                return nil
            }
            if let early { c.resume(returning: early) }
        }

        func resume(_ value: JSONValue) {
            let c = state.withLock { s -> CheckedContinuation<JSONValue, Never>? in
                if s.done { return nil }
                s.done = true
                guard let c = s.cont else { s.early = value; return nil }
                s.cont = nil
                return c
            }
            c?.resume(returning: value)
        }
    }
}
