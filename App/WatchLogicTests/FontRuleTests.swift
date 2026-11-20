import Foundation
import SwiftUI
import Testing

/// Schriftgröße (Dynamic Type, App/README.md → „Schriftgröße“): Zuordnung der festen Größen zu Textstilen, Mac
/// unverändert, und keine neuen festen Größen in den Oberflächen (dieselbe Regel wie `App/scripts/check-fonts.sh`).
@Suite("Schriftgröße (Dynamic Type)")
struct FontRuleTests {
    @Test("Feste Größen gehören zum nächstliegenden Textstil")
    func sizesMapToNearestTextStyle() {
        #expect(AppFont.textStyle(for: 10) == .caption2)
        #expect(AppFont.textStyle(for: 11) == .caption2)
        #expect(AppFont.textStyle(for: 12) == .caption)
        #expect(AppFont.textStyle(for: 12.5) == .footnote)
        #expect(AppFont.textStyle(for: 13.5) == .footnote)
        #expect(AppFont.textStyle(for: 15) == .subheadline)
        #expect(AppFont.textStyle(for: 16) == .callout)
        #expect(AppFont.textStyle(for: 17) == .body)
        #expect(AppFont.textStyle(for: 20) == .title3)
        #expect(AppFont.textStyle(for: 22) == .title2)
        #expect(AppFont.textStyle(for: 28) == .title)
        #expect(AppFont.textStyle(for: 40) == .largeTitle)
    }

    /// Mac (dieses Testziel läuft auf macOS): feste Größen in jeder Stufe, das Mac-Design bleibt unverändert.
    @Test("Mac: feste Größen in jeder Stufe")
    func macKeepsFixedSizes() {
        for size in DynamicTypeSize.allCases {
            #expect(AppFont.scaled(15, in: size) == 15)
            #expect(AppFont.scaled(28, relativeTo: .title, in: size) == 28)
        }
    }

    @Test("Keine neuen festen Schriftgrößen in den Oberflächen")
    func noNewFixedFontSizes() throws {
        // …/App/WatchLogicTests/FontRuleTests.swift → …/App
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["AISBot", "Shared", "AISBotShare"].map { app.appendingPathComponent($0) }
        // Ohne Quellen (z. B. anderer Rechner) gibt es nichts zu prüfen
        guard roots.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }
        let allowed = ["Shared/Theme/AppFont.swift", "Shared/Widget/", "AISBot/Support/AssetRenderer.swift",
                       "AISBot/Support/MascotStyleSheet.swift"]
        var hits: [String] = []
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let rel = String(file.path.dropFirst(app.path.count + 1))
                guard !allowed.contains(where: { rel.hasPrefix($0) }) else { continue }
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    if code.contains(".system(size:") || code.contains("systemFont(ofSize:") {
                        hits.append("\(rel):\(i + 1): \(code)")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "Feste Schriftgrößen (statt .appFont bzw. .font(.fixed(…))):\n\(hits.joined(separator: "\n"))")
    }
}
