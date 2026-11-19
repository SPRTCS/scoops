import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Eingabe auf der Bildschirmfläche, normiert auf 0…1 (unabhängig von der Darstellungsgröße).
enum RemoteEvent {
    case click(CGPoint, modifiers: String?)
    case doubleClick(CGPoint)
    case rightClick(CGPoint)
    case drag(from: CGPoint, to: CGPoint)
    case scroll(CGPoint, direction: String, amount: Int)
    case type(String)
    case key(String)
}

/// Fängt Klicks, Gesten, Scrollen und (auf dem Mac) die Hardware-Tastatur ab.
/// Liegt genau über dem Bildschirmbild (Seitenverhältnis wie der Bot-Rechner), daher gibt es kein Letterboxing.
struct RemoteSurface: View {
    var onEvent: (RemoteEvent) -> Void

    var body: some View {
        RemoteSurfaceRepresentable(onEvent: onEvent)
            .accessibilityLabel("Bildschirm des Bot-Rechners, du steuerst")
    }
}

#if os(macOS)
private struct RemoteSurfaceRepresentable: NSViewRepresentable {
    var onEvent: (RemoteEvent) -> Void

    func makeNSView(context: Context) -> RemoteNSView {
        let v = RemoteNSView()
        v.onEvent = onEvent
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: RemoteNSView, context: Context) {
        nsView.onEvent = onEvent
    }
}

final class RemoteNSView: NSView {
    var onEvent: ((RemoteEvent) -> Void)?
    private var downPoint: CGPoint?
    private var dragged = false
    private var scrollAccumulator: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(1, p.x / max(bounds.width, 1))), y: max(0, min(1, p.y / max(bounds.height, 1))))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = normalized(event)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downPoint else { return }
        let p = normalized(event)
        if hypot((p.x - d.x) * bounds.width, (p.y - d.y) * bounds.height) > 5 { dragged = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = downPoint else { return }
        let p = normalized(event)
        downPoint = nil
        if dragged {
            onEvent?(.drag(from: d, to: p))
        } else if event.clickCount == 2 {
            onEvent?(.doubleClick(p))
        } else if event.clickCount == 1 {
            onEvent?(.click(p, modifiers: Self.modifierString(event.modifierFlags)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onEvent?(.rightClick(normalized(event)))
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX / 12 : event.scrollingDeltaX
        scrollAccumulator += abs(dy) > abs(dx) ? dy : 0
        let p = normalized(event)
        if abs(dx) > abs(dy), abs(dx) >= 1 {
            onEvent?(.scroll(p, direction: dx > 0 ? "left" : "right", amount: Int(min(10, abs(dx)))))
        }
        if abs(scrollAccumulator) >= 1 {
            let amount = Int(min(10, abs(scrollAccumulator)))
            onEvent?(.scroll(p, direction: scrollAccumulator > 0 ? "up" : "down", amount: amount))
            scrollAccumulator = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let special = Self.specialKey(event.keyCode) {
            let mods = Self.modifierString(flags)
            onEvent?(.key(mods.map { "\($0)+\(special)" } ?? special))
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            // Tastenkürzel wie ⌘C → "super+c"
            let base = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard !base.isEmpty, let mods = Self.modifierString(flags) else { return }
            onEvent?(.key("\(mods)+\(base)"))
            return
        }
        if let text = event.characters, !text.isEmpty {
            onEvent?(.type(text))
        }
    }

    // ⌘-Kürzel nicht ans Menü geben, solange die Fläche den Fokus hat (außer ⌘W/⌘Q zum Schließen)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.modifierFlags.contains(.command), ["w", "q"].contains(key) { return false }
        keyDown(with: event)
        return true
    }

    static func modifierString(_ flags: NSEvent.ModifierFlags) -> String? {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("super") }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    static func specialKey(_ code: UInt16) -> String? {
        switch code {
        case 36, 76: "return"
        case 48: "tab"
        case 51: "backspace"
        case 117: "delete"
        case 53: "escape"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 115: "home"
        case 119: "end"
        case 116: "page_up"
        case 121: "page_down"
        default: nil
        }
    }
}
#else
private struct RemoteSurfaceRepresentable: UIViewRepresentable {
    var onEvent: (RemoteEvent) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.5
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        // Sekundärklick (Trackpad/Maus am iPad)
        let secondary = UITapGestureRecognizer(target: c, action: #selector(Coordinator.secondary(_:)))
        secondary.buttonMaskRequired = .secondary
        for g in [double, single, long, drag, scroll, secondary] { v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    final class Coordinator: NSObject {
        var onEvent: (RemoteEvent) -> Void
        private var dragStart: CGPoint?
        private var scrollAccumulator: CGFloat = 0

        init(onEvent: @escaping (RemoteEvent) -> Void) { self.onEvent = onEvent }

        private func norm(_ g: UIGestureRecognizer, _ p: CGPoint? = nil) -> CGPoint {
            guard let v = g.view else { return .zero }
            let pt = p ?? g.location(in: v)
            return CGPoint(x: max(0, min(1, pt.x / max(v.bounds.width, 1))), y: max(0, min(1, pt.y / max(v.bounds.height, 1))))
        }

        @objc func tap(_ g: UITapGestureRecognizer) { onEvent(.click(norm(g), modifiers: nil)) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { onEvent(.doubleClick(norm(g))) }
        @objc func secondary(_ g: UITapGestureRecognizer) { onEvent(.rightClick(norm(g))) }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { onEvent(.rightClick(norm(g))) }
        }

        @objc func drag(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                guard let v = g.view else { return }
                let t = g.translation(in: v)
                let loc = g.location(in: v)
                dragStart = norm(g, CGPoint(x: loc.x - t.x, y: loc.y - t.y))
            case .ended:
                if let s = dragStart { onEvent(.drag(from: s, to: norm(g))) }
                dragStart = nil
            case .cancelled, .failed:
                dragStart = nil
            default:
                break
            }
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            scrollAccumulator += t.y / 18
            if abs(scrollAccumulator) >= 1 {
                // Inhalt folgt dem Finger: nach oben wischen = nach unten scrollen
                onEvent(.scroll(norm(g), direction: scrollAccumulator > 0 ? "up" : "down",
                                amount: Int(min(10, abs(scrollAccumulator)))))
                scrollAccumulator = 0
            }
        }
    }
}
#endif
