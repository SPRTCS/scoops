import AppKit
import CoreGraphics

/// Modus „Diesen Mac direkt steuern“: führt die Befehle selbst aus.
final class DirectExecutor: CommandExecutor {
    private let input = InputController()
    /// Zielbildschirm (siehe `ScreenCapture.targetDisplay`); Koordinaten der Scoops sind relativ zu ihm.
    private var display = CGMainDisplayID()

    private var bounds: CGRect { CGDisplayBounds(display) }

    private func refreshDisplay() async { display = await ScreenCapture.targetDisplay() }

    func screenSize() async -> CGSize? {
        await refreshDisplay()
        return bounds.size
    }

    func reset() { input.releaseAll() }

    func execute(_ command: String, params: JSONValue) async -> JSONValue {
        let p = params
        switch command {
        case "get_screen_size":
            await refreshDisplay()
            let s = bounds.size
            return CmdResult.ok(["size": .object(["width": .int(Int(s.width)), "height": .int(Int(s.height))])])

        case "screenshot":
            do {
                await refreshDisplay()
                let png = try await ScreenCapture.png(of: display)
                return CmdResult.ok(["image_data": .string(png.base64EncodedString())])
            } catch {
                return CmdResult.fail(error.localizedDescription)
            }

        case "get_cursor_position":
            let c = input.cursor
            let o = bounds.origin
            return CmdResult.ok(["position": .object(["x": .int(Int(c.x - o.x)), "y": .int(Int(c.y - o.y))])])

        case "run_command":
            guard let cmd = p["command"]?.string else { return CmdResult.fail("command fehlt") }
            // Knapp unter der Zeitgrenze des Befehls (CommandDeadline): So kommt die Ausgabe bis dahin noch an.
            return await ProcessRunner.shell(cmd, timeout: 50)

        case "read_bytes":
            guard let path = p["path"]?.string else { return CmdResult.fail("path fehlt") }
            let offset = p["offset"]?.int ?? 0
            let length = p["length"]?.int
            return await FileBytes.readAsync(path: path, offset: offset, length: length)

        case "write_bytes":
            guard let path = p["path"]?.string, let b64 = p["content_b64"]?.string else {
                return CmdResult.fail("path oder content_b64 fehlt")
            }
            let append = p["append"]?.bool ?? false
            return await FileBytes.writeAsync(path: path, base64: b64, append: append)

        default:
            return await executeInput(command, p)
        }
    }

    /// Maus- und Tastaturbefehle. Ohne Bedienungshilfen-Recht verwirft macOS die Ereignisse stumm,
    /// deshalb melden wir dann ausdrücklich einen Fehler.
    private func executeInput(_ command: String, _ p: JSONValue) async -> JSONValue {
        let known: Set<String> = Commands.active.subtracting(["run_command", "write_bytes"])
        guard known.contains(command) else { return CmdResult.fail("Unbekannter Befehl: \(command)") }
        guard Permissions.accessibility else {
            return CmdResult.fail("Bedienungshilfen-Recht fehlt für Scoops Connect (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen).")
        }
        let origin = bounds.origin
        let point = Self.point(p).map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        let button = InputController.Button(rawValue: p["button"]?.string?.lowercased() ?? "left") ?? .left

        switch command {
        case "move_cursor":
            guard let point else { return CmdResult.fail("x und y fehlen") }
            input.move(to: point)
        case "left_click": input.click(.left, at: point)
        case "right_click": input.click(.right, at: point)
        case "double_click": input.click(.left, at: point, count: 2)
        case "mouse_down": input.down(button, at: point)
        case "mouse_up": input.up(button, at: point)
        case "drag":
            let path = (p["path"]?.array ?? []).compactMap { v -> CGPoint? in
                guard let a = v.array, a.count >= 2, let x = a[0].double, let y = a[1].double else { return nil }
                return CGPoint(x: x + origin.x, y: y + origin.y)
            }
            guard path.count >= 2 else { return CmdResult.fail("path braucht mindestens zwei Punkte") }
            await input.drag(path: path, button: button, duration: p["duration"]?.double ?? 0.5)
        case "scroll":
            input.scroll(dx: p["x"]?.int ?? 0, dy: p["y"]?.int ?? 0)
        case "type_text":
            guard let text = p["text"]?.string else { return CmdResult.fail("text fehlt") }
            await input.type(text)
        case "press_key", "key_down", "key_up":
            guard let name = p["key"]?.string, let action = resolve(name) else {
                return CmdResult.fail("Unbekannte Taste: \(p["key"]?.string ?? "–")")
            }
            switch command {
            case "press_key": input.press(action)
            case "key_down": input.perform(action, down: true)
            default: input.perform(action, down: false)
            }
        case "hotkey":
            let names = (p["keys"]?.array ?? []).compactMap(\.string)
            guard !names.isEmpty else { return CmdResult.fail("keys fehlt") }
            var actions: [KeyMapping.Action] = []
            for n in names {
                guard let a = resolve(n) else { return CmdResult.fail("Unbekannte Taste: \(n)") }
                actions.append(a)
            }
            input.hotkey(actions)
        default:
            return CmdResult.fail("Unbekannter Befehl: \(command)")
        }
        return CmdResult.ok()
    }

    private func resolve(_ name: String) -> KeyMapping.Action? {
        let layout = KeyboardLayout.currentMap()
        return KeyMapping.resolve(name) { layout[$0] }
    }

    private static func point(_ p: JSONValue) -> CGPoint? {
        guard let x = p["x"]?.double, let y = p["y"]?.double else { return nil }
        return CGPoint(x: x, y: y)
    }
}
