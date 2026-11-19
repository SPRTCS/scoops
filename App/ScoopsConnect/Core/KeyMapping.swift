import CoreGraphics
import Foundation

/// Übersetzt Tastennamen im Cua/pyautogui-Stil in macOS-Tastencodes.
///
/// Reine Logik ohne Seiteneffekte, damit sie per Unit-Test geprüft werden kann. Einzelne Zeichen werden
/// zuerst über die aktuelle Tastaturbelegung gesucht (`layoutLookup`, z. B. Deutsch: „z“ liegt auf der
/// physischen Y-Taste), sonst über die US-Belegung; Zeichen ohne Taste gehen als Unicode-Text raus.
nonisolated enum KeyMapping {
    /// Ergebnis der Auflösung eines Tastennamens.
    enum Action: Equatable, Sendable {
        /// Normale Taste; `flags` enthält nötige Zusatz-Modifikatoren (z. B. Umschalt für „A“ oder „!“).
        case key(code: CGKeyCode, flags: CGEventFlags)
        /// Modifikator-Taste (Befehl, Wahl, Control, Umschalt, Fn).
        case modifier(code: CGKeyCode, flag: CGEventFlags)
        /// Zeichen ohne passende Taste – wird per `CGEventKeyboardSetUnicodeString` getippt.
        case text(String)
    }

    /// Sucht ein Zeichen in der aktuellen Tastaturbelegung: (Tastencode, braucht Umschalt).
    typealias LayoutLookup = (Character) -> (code: CGKeyCode, shift: Bool)?

    // MARK: Tastencodes (Carbon kVK_*), physische Positionen auf ANSI-Tastaturen

    static let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
        "command": (55, .maskCommand), "cmd": (55, .maskCommand), "win": (55, .maskCommand),
        "winleft": (55, .maskCommand), "winright": (54, .maskCommand), "super": (55, .maskCommand),
        "meta": (55, .maskCommand), "commandright": (54, .maskCommand),
        "shift": (56, .maskShift), "shiftleft": (56, .maskShift), "shiftright": (60, .maskShift),
        "option": (58, .maskAlternate), "alt": (58, .maskAlternate), "optionleft": (58, .maskAlternate),
        "altleft": (58, .maskAlternate), "optionright": (61, .maskAlternate), "altright": (61, .maskAlternate),
        "ctrl": (59, .maskControl), "control": (59, .maskControl), "ctrlleft": (59, .maskControl),
        "ctrlright": (62, .maskControl), "controlright": (62, .maskControl),
        "fn": (63, .maskSecondaryFn),
    ]

    static let named: [String: CGKeyCode] = [
        "enter": 36, "return": 36, "\n": 36, "\r": 36,
        "tab": 48, "\t": 48,
        "space": 49, " ": 49,
        "backspace": 51,
        "esc": 53, "escape": 53,
        "delete": 117, "del": 117, "forwarddelete": 117,
        "capslock": 57,
        "home": 115, "end": 119,
        "pageup": 116, "pgup": 116, "pagedown": 121, "pgdn": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "help": 114, "insert": 114,
        "volumeup": 72, "volumedown": 73, "volumemute": 74,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        // Ziffernblock wie pyautogui
        "num0": 82, "num1": 83, "num2": 84, "num3": 85, "num4": 86, "num5": 87, "num6": 88,
        "num7": 89, "num8": 91, "num9": 92, "decimal": 65, "add": 69, "subtract": 78,
        "multiply": 67, "divide": 75,
    ]

    /// Aliasse aus `Server/src/aisbot/computer.py` und xdotool-Namen, die trotzdem ankommen können.
    static let aliases: [String: String] = [
        "kp_enter": "enter", "page_up": "pageup", "prior": "pageup", "page_down": "pagedown",
        "next": "pagedown", "super_l": "command", "control_l": "ctrl", "ctrl_l": "ctrl",
        "alt_l": "option", "shift_l": "shift", "arrowleft": "left", "arrowright": "right",
        "arrowup": "up", "arrowdown": "down", "minus": "-", "plus": "+", "equal": "=",
        "period": ".", "comma": ",", "slash": "/", "spacebar": "space",
    ]

    /// US-ANSI-Belegung ohne Umschalt.
    static let usUnshifted: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// US-ANSI-Belegung mit Umschalt: Zeichen → Grundzeichen der Taste.
    static let usShifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

    /// Normalisiert einen Namen (Kleinschreibung bei Namen, Aliasse). Einzelne Zeichen bleiben erhalten,
    /// damit „A“ (mit Umschalt) und „a“ unterscheidbar sind.
    static func normalize(_ name: String) -> String {
        if name.count == 1 { return name }
        let low = name.trimmingCharacters(in: .whitespaces).lowercased()
        if low.isEmpty { return " " }
        return aliases[low] ?? low
    }

    static func resolve(_ name: String, layout: LayoutLookup? = nil) -> Action? {
        let key = normalize(name)
        if let (code, flag) = modifiers[key] { return .modifier(code: code, flag: flag) }
        if let code = named[key] { return .key(code: code, flags: []) }
        guard key.count == 1, let ch = key.first else { return nil }
        if let hit = layout?(ch) {
            return .key(code: hit.code, flags: hit.shift ? .maskShift : [])
        }
        if let code = usUnshifted[ch] { return .key(code: code, flags: []) }
        if ch.isUppercase, ch.isASCII, let lower = ch.lowercased().first, let code = usUnshifted[lower] {
            return .key(code: code, flags: .maskShift)
        }
        if let base = usShifted[ch], let code = usUnshifted[base] { return .key(code: code, flags: .maskShift) }
        return .text(String(ch))
    }

    /// Zerlegt Text für `type_text`: Zeilenumbrüche und Tabs als echte Tasten, alles andere als
    /// Unicode-Stücke (höchstens `chunk` UTF-16-Einheiten, Grenze von CGEventKeyboardSetUnicodeString).
    enum TextPiece: Equatable, Sendable {
        case key(CGKeyCode)
        case unicode(String)
    }

    static func pieces(for text: String, chunk: Int = 16) -> [TextPiece] {
        var out: [TextPiece] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var current = ""
            for ch in buffer {
                if current.utf16.count + String(ch).utf16.count > chunk, !current.isEmpty {
                    out.append(.unicode(current)); current = ""
                }
                current.append(ch)
            }
            if !current.isEmpty { out.append(.unicode(current)) }
            buffer = ""
        }
        for ch in text {
            switch ch {
            case "\n", "\r", "\r\n": flush(); out.append(.key(36))
            case "\t": flush(); out.append(.key(48))
            default: buffer.append(ch)
            }
        }
        flush()
        return out
    }
}
