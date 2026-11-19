import CoreGraphics
import Foundation
import Testing

@Suite("Tasten-Mapping wie Cua/pyautogui")
struct KeyMappingTests {
    @Test("Benannte Tasten", arguments: [
        ("enter", CGKeyCode(36)), ("return", 36), ("Return", 36), ("tab", 48), ("escape", 53), ("esc", 53),
        ("space", 49), (" ", 49), ("backspace", 51), ("delete", 117), ("up", 126), ("down", 125),
        ("left", 123), ("right", 124), ("home", 115), ("end", 119), ("pageup", 116), ("pagedown", 121),
        ("page_up", 116), ("f1", 122), ("F5", 96), ("f12", 111), ("arrowleft", 123),
    ])
    func named(name: String, code: CGKeyCode) {
        #expect(KeyMapping.resolve(name) == .key(code: code, flags: []))
    }

    @Test("Modifikatoren", arguments: [
        ("command", CGKeyCode(55), CGEventFlags.maskCommand), ("cmd", 55, .maskCommand), ("super", 55, .maskCommand),
        ("option", 58, .maskAlternate), ("alt", 58, .maskAlternate), ("control", 59, .maskControl),
        ("ctrl", 59, .maskControl), ("shift", 56, .maskShift), ("fn", 63, .maskSecondaryFn),
    ])
    func modifiers(name: String, code: CGKeyCode, flag: CGEventFlags) {
        #expect(KeyMapping.resolve(name) == .modifier(code: code, flag: flag))
    }

    @Test("Einzelne Zeichen (US-Belegung)")
    func singleCharacters() {
        #expect(KeyMapping.resolve("a") == .key(code: 0, flags: []))
        #expect(KeyMapping.resolve("t") == .key(code: 17, flags: []))
        #expect(KeyMapping.resolve("z") == .key(code: 6, flags: []))
        #expect(KeyMapping.resolve("1") == .key(code: 18, flags: []))
        #expect(KeyMapping.resolve("A") == .key(code: 0, flags: .maskShift))
        #expect(KeyMapping.resolve("!") == .key(code: 18, flags: .maskShift))
        #expect(KeyMapping.resolve("?") == .key(code: 44, flags: .maskShift))
        #expect(KeyMapping.resolve("minus") == .key(code: 27, flags: []))
        #expect(KeyMapping.resolve("period") == .key(code: 47, flags: []))
    }

    @Test("Aktuelle Tastaturbelegung hat Vorrang (deutsch: z liegt auf Y-Position)")
    func layoutLookup() {
        let german: KeyMapping.LayoutLookup = { ch in
            switch ch {
            case "z": (16, false)
            case "y": (6, false)
            case "ä": (39, false)
            default: nil
            }
        }
        #expect(KeyMapping.resolve("z", layout: german) == .key(code: 16, flags: []))
        #expect(KeyMapping.resolve("ä", layout: german) == .key(code: 39, flags: []))
        // Benannte Tasten hängen nie von der Belegung ab.
        #expect(KeyMapping.resolve("enter", layout: german) == .key(code: 36, flags: []))
    }

    @Test("Zeichen ohne Taste werden als Unicode-Text getippt")
    func unicodeFallback() {
        #expect(KeyMapping.resolve("é") == .text("é"))
        #expect(KeyMapping.resolve("😀") == .text("😀"))
        #expect(KeyMapping.resolve("unbekannt") == nil)
    }

    @Test("type_text: Zeilenumbrüche/Tabs als Tasten, Rest in Unicode-Stücken")
    func textPieces() {
        let p = KeyMapping.pieces(for: "Hallo\nWelt\tä", chunk: 16)
        #expect(p == [.unicode("Hallo"), .key(36), .unicode("Welt"), .key(48), .unicode("ä")])
        let long = String(repeating: "x", count: 40)
        let chunks = KeyMapping.pieces(for: long, chunk: 16)
        #expect(chunks == [.unicode(String(repeating: "x", count: 16)), .unicode(String(repeating: "x", count: 16)),
                           .unicode(String(repeating: "x", count: 8))])
        // Emoji (2 UTF-16-Einheiten) werden nicht zerteilt.
        let emoji = KeyMapping.pieces(for: String(repeating: "😀", count: 9), chunk: 16)
        #expect(emoji.count == 2)
    }
}

@Suite("Protokoll-Hilfen")
struct ProtocolTests {
    @Test("SSE: letztes data-Objekt gewinnt")
    func sse() {
        let body = Data("data: {\"success\": true, \"size\": {\"width\": 1280, \"height\": 800}}\n\n".utf8)
        let v = SSE.lastJSON(in: body)
        #expect(v?["success"]?.bool == true)
        #expect(v?["size"]?["width"]?.int == 1280)
        let plain = Data("{\"success\": false, \"error\": \"x\"}".utf8)
        #expect(SSE.lastJSON(in: plain)?["error"]?.string == "x")
        let crlf = Data("event: x\r\ndata: {\"a\":1}\r\n\r\ndata: {\"a\":2}\r\n\r\n".utf8)
        #expect(SSE.lastJSON(in: crlf)?["a"]?.int == 2)
    }

    @Test("JSON: ganze Zahlen ohne Nachkommastellen")
    func jsonInts() {
        let v = JSONValue.object(["x": .number(200), "y": .number(1.5)])
        let s = v.jsonString
        #expect(s.contains("\"x\":200"))
        #expect(s.contains("\"y\":1.5"))
        #expect(JSONValue.decode(#"{"type":"cmd","params":{"keys":["command","t"]}}"#)?["params"]?["keys"]?.array?.count == 2)
    }
}
