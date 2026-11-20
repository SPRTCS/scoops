import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import LinkPresentation

// Link-Vorschauen (App 1.3): Für den ersten Link einer Nachricht (von dir oder von einem Scoop) erscheint unter dem
// Text eine kompakte Karte mit Titel, Domain und Bild. Die Daten holt das Gerät selbst mit LinkPresentation
// (`LPMetadataProvider`), der Server ist nicht beteiligt. Zwischenspeicher im Arbeitsspeicher und als Datei
// (Caches), Zeitlimit pro Abruf. Abschaltbar in den Einstellungen („Link-Vorschauen“).
//
// Die Karte hat von Anfang an ihre feste Höhe (erst Domain, dann Titel und Bild in derselben Fläche): Trifft die
// Vorschau später ein, ändert sich die Höhe der Zeile nicht und der Verlauf springt nicht.

// MARK: - Link finden

enum LinkFinder {
    /// Erster Link der Nachricht, falls er eine Vorschau bekommen darf. Links in Codeblöcken und Inline-Code zählen
    /// nicht; ist der erste Link eine lokale oder private Adresse, gibt es keine Vorschau.
    static func previewURL(in text: String) -> URL? {
        guard text.contains("http") else { return nil }
        let plain = withoutCode(text)
        guard let match = plain.firstMatch(of: /https?:\/\/[^\s<>"'`\]]+/) else { return nil }
        var raw = String(match.output)
        // Markdown-Link „[Text](https://…)“ und Satzzeichen am Ende
        if let close = raw.firstIndex(of: ")"), !raw[..<close].contains("(") { raw = String(raw[..<close]) }
        while let last = raw.last, ".,;:!?…»“”’'\"*_".contains(last) { raw.removeLast() }
        guard let url = URL(string: raw), isPublic(url) else { return nil }
        return url
    }

    /// Fenced-Codeblöcke (``` … ```) und Inline-Code (`…`) entfernen.
    static func withoutCode(_ text: String) -> String {
        var out = ""
        var fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced || line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            out += line.replacing(/`[^`\n]*`/, with: " ") + "\n"
        }
        return out
    }

    /// Öffentliche Web-Adresse? Nicht: localhost, Namen ohne Punkt, `.local`/`.ts.net`/interne Endungen und private
    /// bzw. lokale IP-Bereiche (10.x, 192.168.x, 172.16–31.x, 127.x, 169.254.x, 100.64–127.x von Tailscale, IPv6).
    static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty, url.user == nil else { return false }
        if host.contains(":") || host.hasPrefix("[") { return false }  // IPv6-Literal
        if host == "localhost" || !host.contains(".") { return false }
        for suffix in [".local", ".localhost", ".ts.net", ".internal", ".lan", ".home.arpa", ".intranet", ".corp", ".test"]
        where host.hasSuffix(suffix) { return false }
        let parts = host.split(separator: ".").map { Int($0) }
        if parts.count == 4, parts.allSatisfy({ $0 != nil }) {
            let p = parts.map { $0! }
            if p[0] == 10 || p[0] == 127 || p[0] == 0 { return false }
            if p[0] == 192 && p[1] == 168 { return false }
            if p[0] == 172 && (16...31).contains(p[1]) { return false }
            if p[0] == 169 && p[1] == 254 { return false }
            if p[0] == 100 && (64...127).contains(p[1]) { return false }
        }
        return true
    }

    /// Domain für die Karte, ohne „www.“
    static func displayHost(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Daten und Zwischenspeicher

struct LinkPreviewData: Codable, Equatable, Sendable {
    var url: URL
    var title: String?
    var hasImage: Bool
    var fetchedAt: Date
    /// Abruf fehlgeschlagen (Zeitlimit, keine Metadaten): Karte zeigt nur die Domain
    var failed: Bool
}

/// Holt und merkt Link-Vorschauen. Ein Abruf pro Adresse, auch wenn mehrere Zeilen sie gleichzeitig anfragen.
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()

    /// Zeitlimit eines Abrufs (LinkPresentation lädt Seite, Symbol und Bild)
    static let timeout: TimeInterval = 8
    private static let keepSuccess: TimeInterval = 14 * 86_400
    private static let keepFailure: TimeInterval = 6 * 3600
    private static let thumbnailPixels = 320

    private var memory: [URL: LinkPreviewData] = [:]
    private var running: [URL: Task<LinkPreviewData, Never>] = [:]
    private let images = NSCache<NSURL, ImageBox>()
    /// Demo-Modus: feste Vorschauen für die Beispiel-Links, ohne Netz (setzt die Karte aus dem Store)
    var demo = false

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: Bundle.main.bundleIdentifier ?? "com.ais.aisbot", directoryHint: .isDirectory)
            .appending(path: "LinkVorschauen", directoryHint: .isDirectory)
    }()

    private func file(_ url: URL, _ ext: String) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(hash).\(ext)")
    }

    private func isFresh(_ d: LinkPreviewData) -> Bool {
        Date().timeIntervalSince(d.fetchedAt) < (d.failed ? Self.keepFailure : Self.keepSuccess)
    }

    /// Schon bekannte Vorschau (Arbeitsspeicher, sonst Datei), ohne Netz. Für das erste Bild einer Zeile.
    func cached(_ url: URL) -> LinkPreviewData? {
        if let d = memory[url], isFresh(d) { return d }
        if demo, let d = DemoLinkPreviews.data(for: url) {
            memory[url] = d
            return d
        }
        guard let raw = try? Data(contentsOf: file(url, "json")),
              let d = try? JSONDecoder().decode(LinkPreviewData.self, from: raw), isFresh(d) else { return nil }
        memory[url] = d
        return d
    }

    /// Vorschau laden (aus dem Zwischenspeicher oder vom Netz). Liefert immer etwas: bei Fehlern `failed`.
    func load(_ url: URL) async -> LinkPreviewData {
        if let d = cached(url) { return d }
        if let task = running[url] { return await task.value }
        let task = Task { await self.fetch(url) }
        running[url] = task
        let result = await task.value
        running[url] = nil
        return result
    }

    /// Vorschaubild (verkleinert), falls vorhanden.
    func image(for url: URL) -> CGImage? {
        if let box = images.object(forKey: url as NSURL) { return box.image }
        guard let source = CGImageSourceCreateWithURL(file(url, "jpg") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images.setObject(ImageBox(image), forKey: url as NSURL)
        return image
    }

    private func fetch(_ url: URL) async -> LinkPreviewData {
        let (title, imageData) = await Self.metadata(for: url)
        var data = LinkPreviewData(url: url, title: title?.trimmingCharacters(in: .whitespacesAndNewlines), hasImage: false,
                                   fetchedAt: Date(), failed: false)
        if data.title?.isEmpty != false { data.title = nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let imageData, let thumb = Self.thumbnail(imageData) {
            if let dest = CGImageDestinationCreateWithURL(file(url, "jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    data.hasImage = true
                    images.setObject(ImageBox(thumb), forKey: url as NSURL)
                }
            }
        }
        data.failed = data.title == nil && !data.hasImage
        memory[url] = data
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: file(url, "json"), options: .atomic) }
        return data
    }

    /// Titel und Bilddaten über LinkPresentation. Die nicht übertragbaren Objekte (Metadaten, Anbieter) bleiben in den
    /// Rückrufen; heraus kommen nur Text und Daten. Läuft nie länger als `timeout` plus kurze Reserve.
    private static func metadata(for url: URL) async -> (String?, Data?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(String?, Data?), Never>) in
            let once = Once(continuation)
            let provider = LPMetadataProvider()
            provider.timeout = timeout
            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard let metadata else { return once.resume((nil, nil)) }
                let title = metadata.title
                guard let item = metadata.imageProvider ?? metadata.iconProvider else { return once.resume((title, nil)) }
                _ = item.loadDataRepresentation(for: .image) { data, _ in once.resume((title, data)) }
            }
            // Absicherung, falls ein Rückruf ausbleibt
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 4) { once.resume((nil, nil)) }
        }
    }

    /// Setzt die Fortsetzung genau einmal fort (Rückruf und Absicherung laufen um die Wette).
    private nonisolated final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(String?, Data?), Never>?
        init(_ continuation: CheckedContinuation<(String?, Data?), Never>) { self.continuation = continuation }
        func resume(_ value: (String?, Data?)) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Feste Vorschauen für die Beispiel-Links des Demo-Modus (`-mock`), damit Demo und Screenshots ohne Netz auskommen.
enum DemoLinkPreviews {
    private static var titles: [String: String] { [
        "mail.google.com": demoText("Gmail – Posteingang", en: "Gmail – Inbox"),
        "www.swift.org": "Swift.org – Welcome to Swift",
        "swift.org": "Swift.org – Welcome to Swift",
        "www.bahn.de": demoText("Deutsche Bahn: Fahrplan, Tickets und Reiseauskunft",
                                en: "Deutsche Bahn: Timetables, Tickets and Travel Information"),
        "www.booking.com": demoText("Hotels in Köln – Unterkünfte nahe Hauptbahnhof",
                                    en: "Hotels in Boston – Places to Stay near South Station"),
        "app.t3.codes": "T3 Code",
    ] }

    static func data(for url: URL) -> LinkPreviewData? {
        guard let host = url.host()?.lowercased(), let title = titles[host] else { return nil }
        return LinkPreviewData(url: url, title: title, hasImage: false, fetchedAt: Date(), failed: false)
    }
}

// MARK: - Ansicht

/// Vorschau zum ersten Link einer Nachricht (oder nichts: kein Link, private Adresse, in den Einstellungen aus).
struct MessageLinkPreview: View {
    let text: String
    @AppStorage(LinkPreviewSettings.key) private var enabled = true

    var body: some View {
        if enabled, let url = LinkFinder.previewURL(in: text) {
            LinkPreviewCard(url: url)
        }
    }
}

enum LinkPreviewSettings {
    /// Schalter „Link-Vorschauen“ (Standard an)
    static let key = "linkPreviews"
}

/// Kompakte Karte: links Bild (oder Symbol), rechts Titel und Domain. Feste Höhe, Tippen öffnet den Link.
struct LinkPreviewCard: View {
    let url: URL
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(AppStore.self) private var store
    @State private var data: LinkPreviewData?
    @State private var image: CGImage?

    static let height: CGFloat = 68

    var body: some View {
        let host = LinkFinder.displayHost(url)
        let shown = data ?? LinkPreviewStore.shared.cached(url)
        Button { openURL(url) } label: {
            HStack(spacing: 10) {
                thumbnail(shown)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shown?.title ?? fallbackTitle(host))
                        .appFont(13.5, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: "link").appFont(9.5, weight: .semibold)
                        Text(host).appFont(12).adaptiveLineLimit(1)
                    }
                    .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: Self.height)
            .frame(maxWidth: 320, alignment: .leading)
            .themedCard(theme, radius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Link: \(shown?.title ?? host), \(host)")
        .accessibilityHint("Öffnet den Link")
        .accessibilityAddTraits(.isLink)
        .task(id: url) {
            LinkPreviewStore.shared.demo = store.isMock
            let loaded = await LinkPreviewStore.shared.load(url)
            guard !Task.isCancelled else { return }
            if loaded.hasImage { image = LinkPreviewStore.shared.image(for: url) }
            if data != loaded { withAnimation(.easeOut(duration: 0.2)) { data = loaded } }
        }
    }

    /// Solange der Titel fehlt (lädt noch, nichts gefunden): letzter Teil des Pfads oder die Domain.
    private func fallbackTitle(_ host: String) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? host : last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    @ViewBuilder
    private func thumbnail(_ shown: LinkPreviewData?) -> some View {
        let side = Self.height - 16
        Group {
            if let image = image ?? (shown?.hasImage == true ? LinkPreviewStore.shared.image(for: url) : nil) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "globe")
                    .appFont(20, weight: .regular)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.hover)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Einstellungen

/// Abschnitt „Chat“ der Einstellungen: Schalter „Link-Vorschauen“.
struct ChatSettingsSection: View {
    @AppStorage(LinkPreviewSettings.key) private var linkPreviews = true
    @Environment(\.theme) private var theme

    var body: some View {
        GroupedSection("Chat", footer: "Zeigt unter Nachrichten mit einem Link eine kleine Karte mit Titel und Bild. Dein Gerät ruft dafür die verlinkte Seite ab. Für lokale und private Adressen gibt es nie eine Vorschau.") {
            GroupedLabelRow(icon: "link", iconColor: theme.accent, title: "Link-Vorschauen",
                            subtitle: "Titel, Domain und Bild zum ersten Link") {
                Toggle("Link-Vorschauen", isOn: $linkPreviews)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
            }
        }
    }
}
