import SwiftUI

/// Markdown-Datei als formatiertes Dokument (Berichte aus Aufgaben, Notizen der Scoops): Überschriften, Listen,
/// Aufgaben-Kästchen, Tabellen, Code. Quick Look zeigt `.md` nur als Rohtext; deshalb öffnet `previewURL` solche
/// Dateien hier (RootView). Umschalter „Quelltext“, Teilen und Kopieren.
struct MarkdownDocumentView: View {
    let url: URL

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var showSource = false
    @State private var copied = false

    /// Dateiendungen, die dieser Viewer statt Quick Look zeigt
    static func handles(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased())
    }

    private var title: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title, icon: "doc.richtext") {
                HStack(spacing: 8) {
                    CircleIconButton(systemName: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right",
                                     help: showSource ? "Formatiert anzeigen" : "Quelltext anzeigen", size: 30) {
                        withAnimation(.snappy(duration: 0.2)) { showSource.toggle() }
                    }
                    CircleIconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Text kopieren", size: 30) {
                        copy()
                    }
                    ShareLink(item: url) { CircleIconLabel(systemName: "square.and.arrow.up", size: 30) }
                        .buttonStyle(.plain)
                        .help("Teilen")
                        .accessibilityLabel("Teilen")
                }
            } onClose: { dismiss() }
            Divider().overlay(theme.surfaceBorder)
            content
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: url) { text = Self.load(url) }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 560, idealHeight: 760)
        #else
        .presentationDetents([.large])
        .presentationSizing(.page)
        #endif
    }

    @ViewBuilder private var content: some View {
        if let text {
            ScrollView {
                Group {
                    if showSource {
                        Text(text)
                            .appFont(13.5, design: .monospaced)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownView(text: text, document: true)
                            .appFont(16)
                            .lineSpacing(4)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy() {
        guard let text else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// UTF-8, sonst Latin-1 (ältere Dateien), sonst Fehlerhinweis
    static func load(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return String(localized: "*Die Datei konnte nicht gelesen werden.*") }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Datei-Vorschau als Sheet-Element
struct PreviewDocument: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
