#if DEBUG
import SwiftUI
import QuartzCore
import os
#if canImport(AppKit)
import AppKit
#endif

/// Nur Debug: misst das Ein- und Ausfahren des Profils (rechte Seitenleiste).
///
/// Startargument `-inspectorbench [n]` (Standard 10 Durchgänge): Nach dem Start wird das Fenster auf
/// 1440 × 900 pt gesetzt (Mac), dann das Profil n-mal ein- und ausgeblendet – wie ⌘I. Ein Display-Link
/// zeichnet die Abstände der Bildwechsel auf, jeweils 0,8 s ab dem Umschalten. Ein „Hänger“ ist ein Bild,
/// das länger als das 1,5-Fache der Bildrate dauert. Zusätzlich Signposts (`AISBot.Inspector`) für Instruments.
@MainActor
final class InspectorBench: NSObject {
    static let shared = InspectorBench()
    static let signposter = OSSignposter(subsystem: "com.ais.aisbot", category: .pointsOfInterest)

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var nominal: CFTimeInterval = 1.0 / 60
    private var intervals: [CFTimeInterval] = []
    private var recording = false
    /// Hauptthread-Arbeit je Runloop-Durchgang (Aufwachen bis Schlafen), unabhängig von der Bildrate des Monitors
    private var busy: [CFTimeInterval] = []
    private var wokeAt: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    /// `-benchverbose`: jeden zu langen Durchgang mit Zeitpunkt seit dem Umschalten ausgeben
    private let verbose = ProcessInfo.processInfo.arguments.contains("-benchverbose")
    private var toggledAt: CFTimeInterval = 0
    private var current = ""

    /// Ausgabe nach stdout (Mac, `open --stdout`) und ins Systemprotokoll (Simulator: `log show`)
    private nonisolated static func out(_ line: String) {
        print(line)
        #if os(iOS)
        NSLog("%@", line)
        #endif
    }

    struct Result {
        var frames: Int
        var hitches: Int
        /// Summe der Überlänge aller Hänger (ms)
        var hitchMs: Double
        var maxMs: Double
        /// Hauptthread-Arbeit im Messfenster (ms)
        var busyMs: Double
        /// Runloop-Durchgänge über 8,33 ms (bei 120 Hz ein verpasstes Bild)
        var over120: Int
        /// längster Durchgang (ms)
        var maxBusyMs: Double
    }

    func run(store: AppStore, count: Int) {
        setvbuf(stdout, nil, _IOLBF, 0)   // zeilenweise ausgeben, auch in eine Datei umgeleitet
        let args = ProcessInfo.processInfo.arguments
        // `-benchdelay <s>`: später anfangen (z. B. damit sich Instruments vorher anhängen kann)
        let delay = args.firstIndex(of: "-benchdelay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 3
        Task {
            try? await Task.sleep(for: .seconds(delay))
            #if os(macOS)
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                w.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
            }
            #endif
            startLink()
            try? await Task.sleep(for: .seconds(1))
            store.showInspector = false
            try? await Task.sleep(for: .seconds(1))
            var open: [Result] = [], close: [Result] = []
            // `-benchidle`: gleiche Messung ohne Umschalten (Grundlast des Chats)
            let idle = args.contains("-benchidle")
            for _ in 0..<count {
                if idle {
                    open.append(await measure("ruhig") {})
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                open.append(await measure("auf") { store.showInspector = true })
                try? await Task.sleep(for: .milliseconds(500))
                close.append(await measure("zu") { store.showInspector = false })
                try? await Task.sleep(for: .milliseconds(500))
            }
            report("Einfahren", open)
            report("Ausfahren", close)
            Self.out(String(format: "[inspector] Bildrate %.1f Hz", 1 / nominal))
            Self.out("[inspector] fertig")
            link?.invalidate()
            link = nil
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }

    private func startLink() {
        #if os(macOS)
        guard let screen = NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        #endif
        l.add(to: .main, forMode: .common)
        link = l
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                     true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                let bench = InspectorBench.shared
                if activity == .afterWaiting {
                    bench.wokeAt = now
                } else if bench.recording, bench.wokeAt > 0 {
                    bench.busy.append(now - bench.wokeAt)
                    if bench.verbose, now - bench.wokeAt > 0.0083 {
                        InspectorBench.out(String(format: "[inspector]   %@ +%.0f ms: %.1f ms", bench.current, (bench.wokeAt - bench.toggledAt) * 1000, (now - bench.wokeAt) * 1000))
                    }
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    @objc private func tick(_ l: CADisplayLink) {
        let d = l.targetTimestamp - l.timestamp
        if d > 0.001 { nominal = d }
        if recording, last > 0 { intervals.append(l.timestamp - last) }
        last = l.timestamp
    }

    private func measure(_ name: StaticString, _ action: () -> Void) async -> Result {
        intervals = []
        busy = []
        last = 0
        recording = true
        let state = Self.signposter.beginInterval(name)
        current = "\(name)"
        toggledAt = CACurrentMediaTime()
        action()
        try? await Task.sleep(for: .milliseconds(800))
        Self.signposter.endInterval(name, state)
        recording = false
        let limit = nominal * 1.5
        let hitches = intervals.filter { $0 > limit }
        return Result(frames: intervals.count, hitches: hitches.count,
                      hitchMs: hitches.reduce(0) { $0 + ($1 - nominal) } * 1000,
                      maxMs: (intervals.max() ?? 0) * 1000,
                      busyMs: busy.reduce(0, +) * 1000,
                      over120: busy.filter { $0 > 1.0 / 120 }.count,
                      maxBusyMs: (busy.max() ?? 0) * 1000)
    }

    private func report(_ label: String, _ results: [Result]) {
        func median(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.isEmpty ? 0 : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        }
        let line = results.map { String(format: "%d/%.0f", $0.hitches, $0.maxMs) }.joined(separator: " ")
        Self.out(String(format: "[inspector] %@: Hänger Median %.1f (max %d), Hänger-Zeit Median %.1f ms, längstes Bild Median %.1f ms (max %.1f ms), Bilder Median %.0f",
                     label,
                     median(results.map { Double($0.hitches) }), results.map(\.hitches).max() ?? 0,
                     median(results.map(\.hitchMs)),
                     median(results.map(\.maxMs)), results.map(\.maxMs).max() ?? 0,
                     median(results.map { Double($0.frames) })))
        Self.out("[inspector] \(label) je Durchgang (Hänger/längstes Bild ms): \(line)")
        Self.out(String(format: "[inspector] %@ Hauptthread: Arbeit Median %.1f ms, Durchgänge > 8,3 ms Median %.1f (max %d), längster Durchgang Median %.1f ms (max %.1f ms)",
                     label,
                     median(results.map(\.busyMs)),
                     median(results.map { Double($0.over120) }), results.map(\.over120).max() ?? 0,
                     median(results.map(\.maxBusyMs)), results.map(\.maxBusyMs).max() ?? 0))
        let busyLine = results.map { String(format: "%d/%.0f", $0.over120, $0.maxBusyMs) }.joined(separator: " ")
        Self.out("[inspector] \(label) je Durchgang Hauptthread (> 8,3 ms / längster ms): \(busyLine)")
    }
}
#endif
