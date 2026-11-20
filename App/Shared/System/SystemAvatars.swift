import Foundation

/// Vorgerenderte Chat-Bilder für Systemflächen (Kurzbefehle, Siri, Auswahl der Controls, Spotlight): Scoop-Figur
/// bzw. eigenes Foto, bei Gruppen die ersten Mitglieder. Die App schreibt sie als PNG in die App-Gruppe
/// (`SystemAvatars/`), Erweiterungen und Intents lesen nur.
nonisolated enum SystemAvatars {
    private static let folderName = "SystemAvatars"

    static var folderURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    static func fileURL(chatID: String) -> URL? {
        let safe = String(chatID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return folderURL?.appending(path: "\(safe).png")
    }

    /// Bild eines Chats, nur wenn die Datei auch existiert
    static func imageURL(chatID: String) -> URL? {
        guard let url = fileURL(chatID: chatID), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
