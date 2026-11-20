import Foundation
import Observation
import SwiftUI

// MARK: - Bibliothek: Suche, Filter nach Typ, Sortierung

/// Dateityp für den Filter der Bibliothek. Angeboten werden nur Typen, die im Chat vorkommen.
nonisolated enum LibraryKind: String, CaseIterable, Identifiable, Sendable {
    case images, pdfs, documents, tables, presentations, code, links, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: String(localized: "Bilder")
        case .pdfs: "PDFs"
        case .documents: String(localized: "Dokumente")
        case .tables: String(localized: "Tabellen")
        case .presentations: String(localized: "Präsentationen")
        case .code: String(localized: "Code", comment: "Dateityp in der Bibliothek: Quelltext")
        case .links: String(localized: "Links", comment: "Dateityp in der Bibliothek: Weblinks")
        case .other: String(localized: "Sonstiges")
        }
    }

    var symbol: String {
        switch self {
        case .images: "photo"
        case .pdfs: "doc.richtext"
        case .documents: "doc.text"
        case .tables: "tablecells"
        case .presentations: "rectangle.on.rectangle.angled"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .links: "link"
        case .other: "doc"
        }
    }

    private static let documentExts: Set<String> = ["doc", "docx", "pages", "txt", "md", "markdown", "rtf", "odt", "tex"]
    private static let tableExts: Set<String> = ["xls", "xlsx", "csv", "tsv", "numbers", "ods"]
    private static let slideExts: Set<String> = ["ppt", "pptx", "key", "odp"]
    private static let codeExts: Set<String> = [
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "json", "html", "htm", "css", "scss", "sh", "zsh", "yml", "yaml",
        "xml", "sql", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "rs", "go", "rb", "php", "toml", "ipynb", "plist",
    ]

    /// Typ einer Datei aus Art, MIME-Typ und Endung.
    init(_ file: LibraryFile) {
        let mime = (file.mime ?? "").lowercased()
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.isLink {
            self = .links
        } else if file.isImage {
            self = .images
        } else if mime == "application/pdf" || ext == "pdf" {
            self = .pdfs
        } else if Self.tableExts.contains(ext) || mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" {
            self = .tables
        } else if Self.slideExts.contains(ext) || mime.contains("presentation") || mime.contains("powerpoint") {
            self = .presentations
        } else if Self.codeExts.contains(ext) || mime == "application/json" || mime.contains("javascript") || mime == "text/html" {
            self = .code
        } else if Self.documentExts.contains(ext) || mime.contains("wordprocessing") || mime.contains("msword")
                    || mime == "text/plain" || mime == "text/markdown" || mime == "application/rtf" {
            self = .documents
        } else {
            self = .other
        }
    }
}

/// Reihenfolge der Bibliothek.
nonisolated enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, name, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: String(localized: "Neueste zuerst")
        case .oldest: String(localized: "Älteste zuerst")
        case .name: String(localized: "Name", comment: "Sortierung nach Dateiname")
        case .size: String(localized: "Größe", comment: "Sortierung nach Dateigröße")
        }
    }

    func sorted(_ files: [LibraryFile]) -> [LibraryFile] {
        switch self {
        case .newest: files.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest: files.sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        case .name: files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: files.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }
}

/// Wahl in der Bibliothek, solange die App läuft: Sortierung für alle Bibliotheken, Suche und Typ je Chat.
@Observable
final class LibraryChoices {
    static let shared = LibraryChoices()

    var sort: LibrarySort = .newest
    private var searches: [String: String] = [:]
    private var kinds: [String: LibraryKind] = [:]

    func search(_ chatID: String) -> String { searches[chatID] ?? "" }
    func setSearch(_ text: String, chatID: String) { searches[chatID] = text.isEmpty ? nil : text }

    func kind(_ chatID: String) -> LibraryKind? { kinds[chatID] }
    func setKind(_ kind: LibraryKind?, chatID: String) { kinds[chatID] = kind }

    /// Dateien eines Chats nach Suche (Dateiname), Typ und Sortierung. Ein gewählter Typ, den es im Chat nicht mehr
    /// gibt (letzte Datei gelöscht), filtert nicht.
    func apply(to files: [LibraryFile], chatID: String) -> [LibraryFile] {
        var list = files
        if let kind = kinds[chatID], files.contains(where: { LibraryKind($0) == kind }) {
            list = list.filter { LibraryKind($0) == kind }
        }
        let tokens = Fuzzy.fold(search(chatID)).split(whereSeparator: \.isWhitespace).map(String.init)
        if !tokens.isEmpty {
            list = list.filter { file in
                let name = Fuzzy.fold(file.name)
                return tokens.allSatisfy { name.contains($0) }
            }
        }
        return sort.sorted(list)
    }
}

/// Leiste über der Bibliothek: Suchfeld, Filter nach Typ, Sortierung. Passt auch in die schmale Profil-Spalte.
struct LibraryToolbar: View {
    let chatID: String
    /// Alle Dateien des Chats (bestimmt, welche Typen angeboten werden)
    let files: [LibraryFile]
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var choices: LibraryChoices { .shared }

    /// Vorkommende Typen in fester Reihenfolge, mit Anzahl
    private var kinds: [(kind: LibraryKind, count: Int)] {
        let counts = Dictionary(grouping: files, by: LibraryKind.init).mapValues(\.count)
        return LibraryKind.allCases.compactMap { k in counts[k].map { (k, $0) } }
    }

    private var activeKind: LibraryKind? {
        guard let k = choices.kind(chatID), kinds.contains(where: { $0.kind == k }) else { return nil }
        return k
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").appFont(13).foregroundStyle(theme.textTertiary)
                TextField("Dateien durchsuchen", text: Binding(get: { choices.search(chatID) },
                                                               set: { choices.setSearch($0, chatID: chatID) }))
                    .textFieldStyle(.plain)
                    .appFont(14)
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onKeyPress(.escape) {
                        guard !choices.search(chatID).isEmpty else { return .ignored }
                        choices.setSearch("", chatID: chatID)
                        return .handled
                    }
                if !choices.search(chatID).isEmpty {
                    Button { choices.setSearch("", chatID: chatID) } label: {
                        Image(systemName: "xmark.circle.fill").appFont(13).foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suche leeren")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(theme.groupedCard, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? theme.accent.opacity(0.6) : theme.surfaceBorder, lineWidth: focused ? 1 : 0.5))

            if kinds.count > 1 { kindMenu }
            sortMenu
        }
        .padding(.horizontal, 2)
    }

    private var kindMenu: some View {
        Menu {
            Button { choices.setKind(nil, chatID: chatID) } label: {
                if activeKind == nil { Label("Alle Typen", systemImage: "checkmark") } else { Text("Alle Typen") }
            }
            Divider()
            ForEach(kinds, id: \.kind) { entry in
                Button { choices.setKind(entry.kind, chatID: chatID) } label: {
                    Label("\(entry.kind.title) (\(entry.count))", systemImage: activeKind == entry.kind ? "checkmark" : entry.kind.symbol)
                }
            }
        } label: {
            menuIcon(activeKind == nil ? "line.3.horizontal.decrease" : activeKind!.symbol, active: activeKind != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Nach Typ filtern")
        .accessibilityLabel(activeKind.map { kind in String(localized: "Filter: \(kind.title)") } ?? String(localized: "Nach Typ filtern"))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button { choices.sort = sort } label: {
                    if choices.sort == sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                }
            }
        } label: {
            menuIcon("arrow.up.arrow.down", active: choices.sort != .newest)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sortieren")
        .accessibilityLabel("Sortieren: \(choices.sort.title)")
    }

    private func menuIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .appFont(13, weight: .semibold)
            .foregroundStyle(active ? theme.accent : theme.textSecondary)
            .scaledFrame(32)
            .background(active ? theme.accent.opacity(0.14) : theme.groupedCard, in: Circle())
            .overlay(Circle().strokeBorder(active ? theme.accent.opacity(0.4) : theme.surfaceBorder, lineWidth: 0.5))
            .contentShape(Circle())
    }
}


// MARK: - Demo-Daten (`-mock`)

extension PreviewData {
    /// Größere Bibliothek für Theo (Recherche) mit allen Typen, damit Suche, Filter und Sortierung im Demo-Modus
    /// etwas zu tun haben. Mila und die Demo-Gruppe behalten ihre wenigen Dateien (dort bleibt die Leiste verborgen).
    static var libraryDemoFiles: [String: [LibraryFile]] {
        func file(_ id: String, _ name: String, _ mime: String, _ size: Int?, hours: Double, by author: String? = "b_theo",
                  kind: String = "datei", url: String? = nil) -> LibraryFile {
            LibraryFile(id: id, chatId: "b_theo", authorId: author, kind: kind, name: name, mime: mime, size: size,
                        url: url, note: nil, createdAt: ago(minutes: hours * 60), downloadUrl: nil)
        }
        return ["b_theo": [
            file("f_t1", demoText("Marktbericht Pflegeroboter.pdf", en: "Care Robot Market Report.pdf"), "application/pdf", 842_113, hours: 2.7),
            file("f_t2", demoText("Wettbewerber-Vergleich.xlsx", en: "Competitor Comparison.xlsx"), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", 96_400, hours: 5),
            file("f_t3", demoText("Quellen.md", en: "Sources.md"), "text/markdown", 4_812, hours: 5.2),
            file("f_t4", demoText("Swift-Konferenzen-2027.md", en: "Swift-Conferences-2027.md"), "text/markdown", 3_204, hours: 26),
            file("f_t5", demoText("Diagramm Marktanteile.png", en: "Market Share Chart.png"), "image/png", 312_880, hours: 27, kind: "bild"),
            file("f_t6", demoText("Foto Messestand.jpg", en: "Trade Show Booth.jpg"), "image/jpeg", 1_204_551, hours: 50, by: nil, kind: "bild"),
            file("f_t7", demoText("Präsentation Ergebnisse.pptx", en: "Results Presentation.pptx"), "application/vnd.openxmlformats-officedocument.presentationml.presentation", 2_480_332, hours: 52),
            file("f_t8", demoText("preise.csv", en: "prices.csv"), "text/csv", 1_930, hours: 74),
            file("f_t9", demoText("auswertung.py", en: "analysis.py"), "text/x-python", 2_611, hours: 74.5),
            file("f_t10", demoText("Angebot Studie.docx", en: "Study Proposal.docx"), "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 48_213, hours: 98, by: nil),
            file("f_t11", demoText("Rohdaten.zip", en: "Raw Data.zip"), "application/zip", 5_812_004, hours: 120),
            file("f_t12", "swift.org – Events", "text/html", nil, hours: 121, kind: "link", url: "https://www.swift.org/events/"),
        ]]
    }
}
