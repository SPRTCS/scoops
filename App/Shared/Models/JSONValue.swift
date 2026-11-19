import Foundation

// Kopie von ScoopsConnect/Core/JSONValue.swift (eigenes Ziel, deshalb doppelt) für den Gerätekanal der iOS-App
// (API v1.18: Befehle `apple.home.*`, `apple.alarms.*`, `apple.location.*`). Schlüssel bleiben wie gesendet
// (snake_case), deshalb immer mit einem einfachen `JSONDecoder` ohne Schlüssel-Umwandlung lesen.

/// Schlanker, `Sendable`-fähiger JSON-Wert für das WebSocket-Protokoll und die Befehlsparameter.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Ganze Zahlen als Int schreiben (Koordinaten, return_code), damit der Server keine 200.0 sieht.
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0.rounded()) } }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    static func int(_ v: Int) -> JSONValue { .number(Double(v)) }

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    var jsonString: String { String(decoding: encoded(), as: UTF8.self) }

    static func decode(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }
    static func decode(_ text: String) -> JSONValue? { decode(Data(text.utf8)) }
}

/// Bequeme Ergebnisse im Cua-Format (`success` + Zusatzfelder).
nonisolated enum CmdResult {
    static func ok(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o = extra
        o["success"] = .bool(true)
        return .object(o)
    }

    static func fail(_ message: String) -> JSONValue {
        .object(["success": .bool(false), "error": .string(message)])
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(integerLiteral value: Int) { self = .number(Double(value)) }
    nonisolated init(floatLiteral value: Double) { self = .number(value) }
    nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }

    /// Optionaler Text: `nil` → `.null`
    nonisolated static func text(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    nonisolated static func num(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }
}
