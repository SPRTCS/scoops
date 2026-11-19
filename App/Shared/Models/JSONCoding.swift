import Foundation

/// JSON-Konfiguration für die Server-API: snake_case und tolerante ISO-8601-Daten.
nonisolated enum JSONCoding {
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let s = try c.decode(String.self)
            if let date = ISO8601Parser.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültiges Datum: \(s)")
        }
        return d
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

/// Parser für ISO-8601 mit oder ohne Sekundenbruchteile (beliebig viele Stellen),
/// mit Zeitzone (`Z`, `+01:00`, `+0100`) oder ohne (dann UTC).
nonisolated enum ISO8601Parser {
    static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 11 {
            // „2026-11-11 21:05:00“ (Leerzeichen statt T) ebenfalls akzeptieren
            let idx = s.index(s.startIndex, offsetBy: 10)
            if s[idx] == " " { s.replaceSubrange(idx...idx, with: "T") }
        }
        // Sekundenbruchteile herauslösen
        var fraction: Double = 0
        if let dot = s.firstIndex(of: "."), let tIndex = s.firstIndex(of: "T"), dot > tIndex {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let digits = String(s[s.index(after: dot)..<end])
            fraction = Double("0." + digits) ?? 0
            s.removeSubrange(dot..<end)
        }
        // Zeitzone ergänzen, falls keine angegeben
        if let tIndex = s.firstIndex(of: "T") {
            let timePart = s[tIndex...]
            let hasZone = timePart.contains("Z") || timePart.contains("+") || timePart.dropFirst(1).contains("-")
            if !hasZone { s += "Z" }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d.addingTimeInterval(fraction) }
        f.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
        if let d = f.date(from: s) { return d.addingTimeInterval(fraction) }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
