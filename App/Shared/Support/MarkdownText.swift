import Foundation
import Synchronization

/// Kleiner Markdown-Parser: Absätze, Aufzählungen (auch Aufgaben-Kästchen), nummerierte Listen, Überschriften mit
/// Ebene, Zitate, Code, Tabellen (GitHub-Stil) und Trennlinien.
/// Inline-Formatierung (fett, kursiv, Links, Code) übernimmt `AttributedString(markdown:)`.
nonisolated enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    /// Ebene 1–6 (`#` … `######`)
    case heading(String, level: Int)
    case bullet(String, level: Int)
    case numbered(String, number: String)
    case quote(String)
    case code(String)
    /// Tabelle: Kopfzeile und Zeilen (Zellen als Inline-Markdown), Ausrichtung je Spalte
    case table(header: [String], rows: [[String]], align: [MarkdownAlign])
    /// `---`, `***`, `___`
    case rule
}

nonisolated enum MarkdownAlign: Hashable, Sendable {
    case leading, center, trailing
}

nonisolated enum MarkdownText {
    // Zwischenspeicher: Parsen (Regex) passiert pro Text nur einmal, nicht bei jedem Neuzeichnen.
    private static let blockCache = Mutex<[String: [MarkdownBlock]]>([:])
    private static let plainCache = Mutex<[String: String]>([:])
    private static let inlineCache = Mutex<[String: AttributedString]>([:])
    private static let cacheLimit = 2000
    private static let noCache = ProcessInfo.processInfo.arguments.contains("-nocache")

    private static func remember<V: Sendable>(_ cache: borrowing Mutex<[String: V]>, _ key: String, _ make: () -> V) -> V {
        if noCache { return make() }
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let value = make()
        cache.withLock { dict in
            if dict.count > cacheLimit { dict.removeAll(keepingCapacity: true) }
            dict[key] = value
        }
        return value
    }

    static func blocks(_ text: String) -> [MarkdownBlock] {
        remember(blockCache, text) { parseBlocks(text) }
    }

    private static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]? = nil

        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let code = codeLines {
                    result.append(.code(code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flush(); codeLines = []
                }
                continue
            }
            if codeLines != nil { codeLines?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }

            // Tabelle: Kopfzeile mit „|“, darunter die Trennzeile (|---|:--:|)
            if trimmed.contains("|"), i < lines.count, let align = tableSeparator(lines[i]) {
                let header = tableCells(trimmed)
                if header.count == align.count || (header.count > 1 && align.count > 1) {
                    flush()
                    i += 1
                    var rows: [[String]] = []
                    while i < lines.count {
                        let row = lines[i].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        var cells = tableCells(row)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        i += 1
                    }
                    let a = align.count >= header.count ? Array(align.prefix(header.count))
                        : align + Array(repeating: .leading, count: header.count - align.count)
                    result.append(.table(header: header, rows: rows, align: a))
                    continue
                }
            }
            if trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
                flush(); result.append(.rule); continue
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if let m = trimmed.firstMatch(of: #/^[-*+•]\s+(.*)$/#) {
                flush(); result.append(.bullet(String(m.1), level: min(indent / 2, 3))); continue
            }
            if let m = trimmed.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush(); result.append(.numbered(String(m.2), number: String(m.1))); continue
            }
            if let m = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*?)\s*#*$/#) {
                flush(); result.append(.heading(String(m.2), level: m.1.count)); continue
            }
            if let m = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                flush(); result.append(.quote(String(m.1))); continue
            }
            paragraph.append(trimmed)
        }
        if let code = codeLines { result.append(.code(code.joined(separator: "\n"))) }
        flush()
        return result
    }

    /// Trennzeile einer Tabelle (`| --- | :---: | ---: |`) → Ausrichtung je Spalte, sonst nil.
    private static func tableSeparator(_ raw: String) -> [MarkdownAlign]? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-"), line.contains("|") || line.contains("---") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var out: [MarkdownAlign] = []
        for c in cells {
            guard c.firstMatch(of: #/^:?-{1,}:?$/#) != nil else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .trailing : .leading)
        }
        return out
    }

    /// Zellen einer Tabellenzeile (äußere „|“ optional, „\|“ bleibt im Text).
    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; cur.append(ch); continue }
            if ch == "|" { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// Inline-Markdown als AttributedString (Fallback: reiner Text).
    static func inline(_ s: String) -> AttributedString {
        remember(inlineCache, s) { parseInline(s) }
    }

    private static func parseInline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        var attr = (try? AttributedString(markdown: stripCitationMarks(s), options: opts)) ?? AttributedString(s)
        linkBareURLs(&attr)
        return attr
    }

    /// Rohe Quellenmarken der OpenAI-Websuche („\u{E200}cite\u{E202}turn1search4\u{E201}“) aus älteren Nachrichten entfernen.
    static func stripCitationMarks(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value == 0xE200 }) else { return s }
        return s.replacingOccurrences(of: "\\s*\u{E200}[^\u{E201}]*\u{E201}", with: "", options: .regularExpression)
    }

    nonisolated(unsafe) private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Nackte Webadressen (https://…, www.…) anklickbar machen, sofern sie nicht schon ein Markdown-Link sind.
    private static func linkBareURLs(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        guard plain.contains("http") || plain.contains("www."), let detector = urlDetector else { return }
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true,
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: attr),
                  let upper = AttributedString.Index(range.upperBound, within: attr) else { continue }
            let r = lower..<upper
            if attr[r].runs.contains(where: { $0.link != nil }) { continue }
            attr[r].link = url
        }
    }

    /// Reiner Text ohne Markdown-Zeichen, einzeilig (für Vorschauen).
    static func plain(_ text: String) -> String {
        remember(plainCache, text) { parsePlain(text) }
    }

    private static func parsePlain(_ text: String) -> String {
        let parts = blocks(text).map { block -> String in
            switch block {
            case .paragraph(let s), .heading(let s, _), .bullet(let s, _), .numbered(let s, _), .quote(let s), .code(let s):
                return String(inline(s).characters)
            case .table(let header, let rows, _):
                return ([header] + rows).map { $0.map { String(inline($0).characters) }.joined(separator: " ") }.joined(separator: " ")
            case .rule:
                return ""
            }
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
