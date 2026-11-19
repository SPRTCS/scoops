import SwiftUI

/// Rendert Bot-Nachrichten mit Markdown (fett, kursiv, Links, Listen, Code, Tabellen).
/// `document`: Darstellung als Dokument (Markdown-Viewer) mit abgestuften Überschriften und mehr Luft.
struct MarkdownView: View {
    var text: String
    /// Scoops, deren @-Erwähnungen in ihrer Farbe hervorgehoben werden
    var mentionBots: [Bot] = []
    var document = false
    @Environment(\.theme) private var theme

    var body: some View {
        let blocks = MarkdownText.blocks(text)
        VStack(alignment: .leading, spacing: document ? 12 : 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .tint(theme.link)
    }

    private func inline(_ s: String) -> Text {
        var attr = MarkdownText.inline(s)
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = theme.link
            attr[run.range].underlineStyle = nil
        }
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].font = .system(size: 13.5, design: .monospaced)
        }
        if !mentionBots.isEmpty {
            Mentions.highlight(&attr, bots: mentionBots, theme: theme)
        }
        return Text(attr)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            // Dokument: einfache Zeilenumbrüche im Absatz sind Leerzeichen (Markdown), Chat behält sie
            inline(document ? Self.softBreaks(s) : s).fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            if document {
                inline(s)
                    .font(.system(size: [28, 22, 18.5, 16.5, 15.5, 15][min(max(level, 1), 6) - 1],
                                  weight: level <= 2 ? .bold : .semibold))
                    .foregroundStyle(level >= 5 ? theme.textSecondary : theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, level <= 2 ? 10 : 4)
                if level == 1 { Divider().overlay(theme.surfaceBorder) }
            } else {
                inline(s).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
        case .bullet(let s, let level):
            let task = Self.checkbox(s)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let task {
                    Image(systemName: task.done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(task.done ? theme.success : theme.textSecondary)
                    inline(task.text)
                        .strikethrough(task.done, color: theme.textTertiary)
                        .foregroundStyle(task.done ? theme.textSecondary : theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(level == 0 ? "•" : "◦").foregroundStyle(theme.textSecondary)
                    inline(s).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, CGFloat(level) * 16 + 4)
        case .numbered(let s, let number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(theme.textSecondary).monospacedDigit()
                inline(s).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.textTertiary).frame(width: 3)
                inline(s).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let s):
            Text(s)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(document ? theme.surface : theme.background.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let header, let rows, let align):
            MarkdownTableView(header: header, rows: rows, align: align, inline: inline)
        case .rule:
            Divider().overlay(theme.surfaceBorder).padding(.vertical, 4)
        }
    }

    /// Weiche Umbrüche → Leerzeichen; harte (zwei Leerzeichen oder „\\“ am Zeilenende) bleiben.
    static func softBreaks(_ s: String) -> String {
        guard s.contains("\n") else { return s }
        let lines = s.components(separatedBy: "\n")
        var out = ""
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 { out += line; break }
            if line.hasSuffix("  ") || line.hasSuffix("\\") {
                out += line.trimmingCharacters(in: CharacterSet(charactersIn: " \\")) + "\n"
            } else {
                out += line + " "
            }
        }
        return out
    }

    /// „[ ] Text“ / „[x] Text“ → Aufgaben-Kästchen
    static func checkbox(_ s: String) -> (done: Bool, text: String)? {
        guard s.count >= 3, s.hasPrefix("["), s.dropFirst(2).hasPrefix("]") else { return nil }
        let mark = s[s.index(after: s.startIndex)]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces))
    }
}

/// Tabelle (GitHub-Markdown): Kopfzeile hervorgehoben, Zeilen mit Trennlinien, bei Bedarf seitlich scrollbar.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let align: [MarkdownAlign]
    let inline: (String) -> Text
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        cell(header[c], column: c).fontWeight(.semibold)
                    }
                }
                .background(theme.hover)
                ForEach(rows.indices, id: \.self) { r in
                    Divider().overlay(theme.surfaceBorder).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], column: c) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.surfaceBorder))
        }
        .scrollIndicators(.automatic)
    }

    private func cell(_ s: String, column: Int) -> some View {
        let a = column < align.count ? align[column] : .leading
        return inline(s)
            .font(.system(size: 14))
            .multilineTextAlignment(a == .center ? .center : a == .trailing ? .trailing : .leading)
            .frame(minWidth: 60, maxWidth: 320,
                   alignment: a == .center ? .center : a == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(a == .center ? .center : a == .trailing ? .trailing : .leading)
    }
}


/// @-Erwähnungen von Scoops im Text: fett, in der Maskottchenfarbe, mit zartem Hintergrund.
enum Mentions {
    static func highlight(_ attr: inout AttributedString, bots: [Bot], theme: Theme) {
        let text = String(attr.characters)
        guard text.contains("@") else { return }
        // Längere Namen zuerst, damit „@Mila Assistenz“ nicht als „@Mila“ endet
        var targets: [(name: String, color: Color, tint: Color)] = bots.map {
            (name: $0.name, color: readable($0.mascot.color, theme: theme), tint: Color(hex: $0.mascot.color))
        }
        targets.append((name: "alle", color: theme.accent, tint: theme.accent))
        targets.sort { $0.name.count > $1.name.count }
        var taken: [Range<String.Index>] = []
        for t in targets {
            var searchStart = text.startIndex
            while let r = text.range(of: "@" + t.name, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                searchStart = r.upperBound
                // Wortgrenzen: davor kein Buchstabe (keine Mailadresse), danach kein Buchstabe
                if r.lowerBound > text.startIndex, text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber { continue }
                if r.upperBound < text.endIndex, text[r.upperBound].isLetter || text[r.upperBound].isNumber { continue }
                if taken.contains(where: { $0.overlaps(r) }) { continue }
                taken.append(r)
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                let len = text.distance(from: r.lowerBound, to: r.upperBound)
                let a = attr.index(attr.startIndex, offsetByCharacters: lo)
                let b = attr.index(a, offsetByCharacters: len)
                attr[a..<b].foregroundColor = t.color
                attr[a..<b].backgroundColor = t.tint.opacity(theme.kind == .hell ? 0.16 : 0.2)
                attr[a..<b].inlinePresentationIntent = .stronglyEmphasized
            }
        }
    }

    /// Maskottchenfarbe mit genug Kontrast zur Blase: im Hell-Theme abgedunkelt (z. B. Gelb → Bernstein),
    /// in Nacht aufgehellt (z. B. dunkles Lila). Gemessen gegen die kontrastärmere der beiden Blasen
    /// (Nutzerblase #E4E4E7 bzw. #2E2E31); Ziel nach WCAG für fetten Text ab 14 pt (≥ 3:1) mit Reserve.
    static func readable(_ hex: String, theme: Theme) -> Color {
        let light = theme.kind == .hell
        let base = RGB(hex: hex)
        let bubble = RGB(hex: light ? "#E4E4E7" : "#2E2E31")
        let target = light ? 3.5 : 4.2
        var c = base
        var t = 0.0
        while contrast(c, bubble) < target, t < 0.9 {
            t += 0.04
            c = base.mix(light ? .black : .white, t)
        }
        return c.opacity(1).color
    }

    /// Kontrastverhältnis nach WCAG 2.1 (relative Leuchtdichte, linearisiertes sRGB).
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func attributed(_ text: String, bots: [Bot], theme: Theme) -> AttributedString {
        var attr = AttributedString(text)
        highlight(&attr, bots: bots, theme: theme)
        return attr
    }
}
