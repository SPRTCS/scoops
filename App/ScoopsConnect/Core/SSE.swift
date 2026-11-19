import Foundation

/// Der Cua-Computer-Server antwortet auf `/cmd` als Server-Sent Events (`data: {…}`).
nonisolated enum SSE {
    /// Liefert das letzte JSON-Objekt aus allen `data:`-Zeilen. Ist der Körper reines JSON
    /// (ohne `data:`), wird er direkt gelesen.
    static func lastJSON(in body: Data) -> JSONValue? {
        // „\r\n“ ist in Swift ein einziges Zeichen – deshalb vorher vereinheitlichen.
        let text = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var payloads: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                if !current.isEmpty { payloads.append(current.joined(separator: "\n")); current = [] }
            } else if line.hasPrefix("data:") {
                var v = line.dropFirst(5)
                if v.first == " " { v = v.dropFirst() }
                current.append(String(v))
            }
        }
        if !current.isEmpty { payloads.append(current.joined(separator: "\n")) }
        for p in payloads.reversed() {
            if let v = JSONValue.decode(p), v.object != nil { return v }
        }
        if payloads.isEmpty, let v = JSONValue.decode(body), v.object != nil { return v }
        return nil
    }
}
