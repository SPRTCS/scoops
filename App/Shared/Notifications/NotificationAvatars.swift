import Foundation

/// Vorgerenderte Maskottchen-Bilder für Mitteilungen (Communication Notifications).
///
/// Die Hauptapp rendert pro Scoop ein PNG in den App-Group-Container (`NotificationAvatars/`)
/// und schreibt eine Zuordnung `author_id → Datei` (`avatars.json`). Die Notification-Service-Extension
/// liest nur diese Dateien und rendert selbst nichts (Speicherlimit der Extension).
///
/// Der Dateiname enthält einen Hash des Aussehens (Form, Farbe, Augen, Accessoire, Fell-Startwert und
/// Render-Version). Ändert sich das Aussehen, entsteht eine neue Datei, und die Zuordnung zeigt sofort darauf.
nonisolated enum NotificationAvatars {
    /// iOS: `group.com.ais.aisbot`, macOS: Team-präfixierte Gruppe (wie `SharedContainer.appGroup`).
    #if os(macOS)
    static let appGroup = "MYXQKK3T2Z.com.ais.aisbot"
    #else
    static let appGroup = "group.com.ais.aisbot"
    #endif

    /// Bei Änderungen am Bildaufbau (Hintergrund, Größe, Ausschnitt) erhöhen, damit alle Bilder neu entstehen.
    static let renderVersion = 2  // 2: Augenstile neu gezeichnet (2026-11)
    /// Kantenlänge der PNGs in Pixeln.
    static let pixelSize = 256

    private static let folderName = "NotificationAvatars"
    private static let indexName = "avatars.json"

    struct Entry: Codable, Hashable, Sendable {
        var name: String
        var file: String
    }

    struct Index: Codable, Hashable, Sendable {
        var version: Int
        /// Schlüssel: Bot-ID (`b_…`), wie sie der Server als `author_id` schickt.
        var bots: [String: Entry]
    }

    static var folderURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    static var indexURL: URL? { folderURL?.appending(path: indexName) }

    static func loadIndex() -> Index? {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    @discardableResult
    static func saveIndex(_ index: Index) -> Bool {
        guard let url = indexURL else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Pfad des vorgerenderten Bilds für einen Scoop, nur wenn die Datei auch existiert.
    static func imageURL(forBotID botID: String) -> URL? {
        guard let folder = folderURL, let entry = loadIndex()?.bots[botID] else { return nil }
        let url = folder.appending(path: entry.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Dateiname aus Bot-ID und Aussehens-Schlüssel, z. B. `b_mila-3f9a0c1d2e4b5a67.png`.
    static func fileName(botID: String, appearanceKey: String) -> String {
        let safeID = String(botID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return "\(safeID)-\(fnv1a64Hex("v\(renderVersion)|\(pixelSize)|\(appearanceKey)")).png"
    }

    /// FNV-1a (64 Bit) als 16-stelliger Hex-String – stabil über Starts und Plattformen (anders als `Hasher`).
    static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
