import Foundation
import CryptoKit
import Observation

/// Noch nicht gesendeter Entwurf eines Chats: Text und Anhänge. Gehört dem Store (`AppStore.composerDraft`),
/// nicht der Chat-Ansicht, damit Neuaufbauten der Ansicht ihn nicht verwerfen. Jede Änderung meldet `onChange`,
/// der Store sichert den Entwurf daraufhin auf der Platte (`DraftArchive`), damit er auch ein Beenden der App
/// durch iOS im Hintergrund übersteht.
@Observable
final class ComposerDraft {
    var text = "" {
        didSet { if text != oldValue { onChange?() } }
    }
    /// Antwort auf eine bestimmte Nachricht (Leiste über dem Eingabefeld, API v1.15)
    var replyTo: ReplyRef? {
        didSet { if replyTo != oldValue { onChange?() } }
    }
    /// Eigene Nachricht wird gerade bearbeitet (App 1.3): Hinweis-Chip über dem Eingabefeld, Senden ersetzt den Text.
    /// Nicht gesichert: Nach einem Neustart steht der Text als normaler Entwurf da.
    var editing: EditTarget?

    struct EditTarget: Equatable {
        var messageID: String
        /// Text der Nachricht vor dem Bearbeiten
        var original: String
        /// Was vorher im Eingabefeld stand (kommt nach dem Bearbeiten oder Abbrechen zurück)
        var previousDraft: String
    }

    let attachments = AttachmentQueue()
    @ObservationIgnored var onChange: (() -> Void)?

    var isEmpty: Bool { text.isEmpty && attachments.isEmpty && replyTo == nil }
}

/// Entwürfe auf der Platte: ein Index (`entwuerfe.json`: Text und Anhang-Metadaten pro Chat) und die Rohdaten
/// jedes Anhangs als eigene Datei. Liegt in Application Support (nicht Caches, das System darf Caches leeren).
/// Pro Server ein eigener Ordner (Datei-IDs und Chats gelten nur dort). So verwirft ein Demo-Start (`-mock`)
/// nie die Entwürfe des echten Servers; beim Wechsel des Servers in den Einstellungen verwirft der Store den
/// Ordner des bisherigen.
enum DraftArchive {
    struct SavedAttachment: Codable {
        var id: UUID
        var name: String
        var mime: String
        var size: Int
        /// Schon hochgeladen: nach dem Neustart nicht erneut hochladen
        var file: LibraryFile?
    }

    struct SavedDraft: Codable {
        var text: String
        var attachments: [SavedAttachment]
        /// Antwort-Leiste (fehlt in älteren Sicherungen)
        var replyTo: ReplyRef?
    }

    struct Index: Codable {
        var server: String
        var drafts: [String: SavedDraft]
    }

    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Unterordner mit Bundle-ID: auf dem Mac ohne Sandbox ist Application Support geteilt
        return base.appending(path: Bundle.main.bundleIdentifier ?? "com.ais.aisbot", directoryHint: .isDirectory)
            .appending(path: "Entwuerfe", directoryHint: .isDirectory)
    }()

    /// Server, dessen Entwürfe gerade gelten (setzt der Store vor dem Laden)
    static var server = "" {
        didSet { directory = folder(for: server) }
    }
    private(set) static var directory = folder(for: "")

    /// Ordnername aus dem Server (gekürzter SHA-256, keine Adresse im Dateisystem)
    private static func folder(for server: String) -> URL {
        let hash = SHA256.hash(data: Data(server.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: hash, directoryHint: .isDirectory)
    }

    /// Geschützt bis zur ersten Entsperrung (Schreiben auch im Hintergrund möglich)
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private static var indexURL: URL { directory.appending(path: "entwuerfe.json") }

    static func fileURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).anhang") }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Index laden und dabei verwaiste Anhangdateien entfernen (z. B. nach Senden kurz vor dem Beenden).
    static func load() -> Index? {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        let referenced = Set(index.drafts.values.flatMap { $0.attachments.map { fileURL($0.id).lastPathComponent } })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "anhang" && !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        return index
    }

    static func save(_ index: Index) {
        ensureDirectory()
        // Einfacher Coder (nicht `JSONCoding`): snake_case würde auch die Chat-IDs als Wörterbuch-Schlüssel umschreiben
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: writeOptions)
    }

    /// Rohdaten eines Anhangs sichern (im Hintergrund, Anhänge können bis 25 MB groß sein).
    @discardableResult
    static func storeData(_ data: Data, id: UUID) -> URL {
        ensureDirectory()
        let url = fileURL(id)
        let options = writeOptions
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: options)
        }
        return url
    }

    static func removeFile(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// Entwürfe des aktuellen Servers verwerfen (Serverwechsel, Trennen)
    static func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }
}
