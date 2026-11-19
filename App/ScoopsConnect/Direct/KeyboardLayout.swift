import Carbon.HIToolbox
import CoreGraphics

/// Liest die aktuelle Tastaturbelegung, damit „command+z“ auf einer deutschen Tastatur die Z-Taste drückt
/// (physisch dort, wo auf US-Tastaturen Y liegt).
enum KeyboardLayout {
    /// Zeichen → (Tastencode, braucht Umschalt) für die aktuelle Belegung.
    static func currentMap() -> [Character: (code: CGKeyCode, shift: Bool)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var map: [Character: (code: CGKeyCode, shift: Bool)] = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                // Modifikator-Zustand für UCKeyTranslate: (Carbon-Modifikatoren >> 8) & 0xFF
                let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for code in 0..<128 {
                    // Ziffernblock und Funktionstasten auslassen, damit „1“ die normale Ziffer bleibt.
                    if (65...92).contains(code) { continue }
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, chars.count, &length, &chars)
                    guard status == noErr, length == 1 else { continue }
                    let s = String(utf16CodeUnits: chars, count: length)
                    guard let ch = s.first, s.count == 1, !ch.isWhitespace, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { continue }
                    if map[ch] == nil { map[ch] = (CGKeyCode(code), shift) }
                }
            }
        }
        return map
    }
}
