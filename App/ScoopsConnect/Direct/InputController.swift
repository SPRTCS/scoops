import CoreGraphics
import Foundation

/// Maus und Tastatur über CGEvent. Koordinaten in Punkten, Ursprung oben links (wie Cua).
final class InputController {
    enum Button: String { case left, right, middle }

    private let source = CGEventSource(stateID: .hidSystemState)
    /// Per `key_down` gehaltene Modifikatoren; gelten auch für Klicks („Befehl gedrückt halten + klicken“).
    private(set) var heldModifiers: CGEventFlags = []
    private var buttonsDown: Set<Button> = []

    var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // MARK: Maus

    func move(to p: CGPoint) {
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(.left) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(.right) { type = .rightMouseDragged; button = .right }
        else if buttonsDown.contains(.middle) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        post(mouse: type, at: p, button: button)
    }

    func click(_ button: Button, at p: CGPoint?, count: Int = 1) {
        let point = p ?? cursor
        if p != nil { move(to: point) }
        for n in 1...max(1, count) {
            post(mouse: downType(button), at: point, button: cgButton(button), clickState: n)
            post(mouse: upType(button), at: point, button: cgButton(button), clickState: n)
        }
    }

    func down(_ button: Button, at p: CGPoint?) {
        let point = p ?? cursor
        if p != nil { move(to: point) }
        buttonsDown.insert(button)
        post(mouse: downType(button), at: point, button: cgButton(button))
    }

    func up(_ button: Button, at p: CGPoint?) {
        let point = p ?? cursor
        if p != nil { move(to: point) }
        buttonsDown.remove(button)
        post(mouse: upType(button), at: point, button: cgButton(button))
    }

    /// Zieht entlang `path` (mindestens zwei Punkte) in `duration` Sekunden.
    func drag(path: [CGPoint], button: Button, duration: Double) async {
        guard let first = path.first else { return }
        move(to: first)
        down(button, at: nil)
        let steps = max(path.count - 1, 1) * 10
        let segments = zip(path, path.dropFirst()).map { ($0, $1) }
        let pause = max(0, duration) / Double(max(steps, 1))
        for (a, b) in segments {
            for i in 1...10 {
                let t = Double(i) / 10
                move(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
            }
        }
        up(button, at: path.last)
    }

    /// Scrollt um `dx`/`dy` Zeilen. Vorzeichen wie Cua/pynput: positives `dy` scrollt nach oben,
    /// `dx` geht unverändert als zweite Radachse raus.
    func scroll(dx: Int, dy: Int) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0)
        event?.flags = heldModifiers
        event?.post(tap: .cghidEventTap)
    }

    // MARK: Tastatur

    func perform(_ action: KeyMapping.Action, down isDown: Bool, extraFlags: CGEventFlags = []) {
        switch action {
        case .modifier(let code, let flag):
            if isDown { heldModifiers.insert(flag) } else { heldModifiers.remove(flag) }
            postKey(code, down: isDown, flags: heldModifiers.union(extraFlags))
        case .key(let code, let flags):
            postKey(code, down: isDown, flags: heldModifiers.union(flags).union(extraFlags))
        case .text(let s):
            if isDown { typeUnicode(s) }
        }
    }

    func press(_ action: KeyMapping.Action) {
        perform(action, down: true)
        perform(action, down: false)
    }

    /// Tastenkombination: Modifikatoren drücken, Tasten tippen, Modifikatoren rückwärts loslassen.
    func hotkey(_ actions: [KeyMapping.Action]) {
        let mods = actions.filter { if case .modifier = $0 { true } else { false } }
        let keys = actions.filter { if case .modifier = $0 { false } else { true } }
        var flags: CGEventFlags = []
        for m in mods {
            if case .modifier(let code, let flag) = m {
                flags.insert(flag)
                postKey(code, down: true, flags: heldModifiers.union(flags))
            }
        }
        for k in keys {
            switch k {
            case .key(let code, let f):
                postKey(code, down: true, flags: heldModifiers.union(flags).union(f))
                postKey(code, down: false, flags: heldModifiers.union(flags).union(f))
            case .text(let s): typeUnicode(s)
            case .modifier: break
            }
        }
        for m in mods.reversed() {
            if case .modifier(let code, let flag) = m {
                flags.remove(flag)
                postKey(code, down: false, flags: heldModifiers.union(flags))
            }
        }
    }

    func type(_ text: String) async {
        for piece in KeyMapping.pieces(for: text) {
            switch piece {
            case .key(let code):
                postKey(code, down: true, flags: [])
                postKey(code, down: false, flags: [])
            case .unicode(let s):
                typeUnicode(s)
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Lässt alles los, was noch gedrückt ist (z. B. beim Pausieren oder Trennen).
    func releaseAll() {
        for b in buttonsDown { up(b, at: nil) }
        for (_, (code, flag)) in KeyMapping.modifiers where heldModifiers.contains(flag) {
            heldModifiers.remove(flag)
            postKey(code, down: false, flags: heldModifiers)
        }
    }

    // MARK: intern

    private func typeUnicode(_ s: String) {
        let units = Array(s.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            units.withUnsafeBufferPointer { buf in
                e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            e.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func post(mouse type: CGEventType, at p: CGPoint, button: CGMouseButton, clickState: Int = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.flags = heldModifiers
        e.post(tap: .cghidEventTap)
    }

    private func cgButton(_ b: Button) -> CGMouseButton {
        switch b { case .left: .left; case .right: .right; case .middle: .center }
    }

    private func downType(_ b: Button) -> CGEventType {
        switch b { case .left: .leftMouseDown; case .right: .rightMouseDown; case .middle: .otherMouseDown }
    }

    private func upType(_ b: Button) -> CGEventType {
        switch b { case .left: .leftMouseUp; case .right: .rightMouseUp; case .middle: .otherMouseUp }
    }
}
