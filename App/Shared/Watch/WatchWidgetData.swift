import Foundation

// MARK: - Daten für die Komplikationen der Uhr (App-Gruppe)
//
// Die Uhren-App schreibt nach jedem Laden eine kleine JSON-Datei und vorgerenderte Avatare (PNG, ca. 100 px)
// in den App-Group-Container. Die Widget-Erweiterung liest nur diese Dateien – sie lädt nichts aus dem Netz und
// zeichnet keine Maskottchen selbst (knapper Speicher). Bewusst ohne Abhängigkeit von `Models.swift`.

nonisolated struct WatchWidgetChat: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String?
    var isGroup: Bool
    var unread: Int
    var waiting: Bool
    var preview: String?
    /// Farbe des Maskottchens (Hex), für Ränder und Platzhalter
    var color: String?
    /// Dateiname des vorgerenderten Avatars im Ordner `WatchWidget/`
    var avatarFile: String?
}

nonisolated struct WatchWidgetApproval: Codable, Hashable, Sendable {
    var title: String
    var chatName: String
    var chatID: String
}

nonisolated struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
    var chats: [WatchWidgetChat] = []
    var pendingApprovals: Int = 0
    /// Die neuesten offenen Freigaben (für die rechteckige Komplikation)
    var approvals: [WatchWidgetApproval] = []
    var serverName: String?
    var demo: Bool = false
    var updatedAt: Date = Date()

    func chat(_ id: String) -> WatchWidgetChat? { chats.first { $0.id == id } }

    // MARK: Dateien

    static let appGroup = "group.com.ais.aisbot"

    static var folderURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "WatchWidget", directoryHint: .isDirectory)
    }

    static var fileURL: URL? { folderURL?.appending(path: "snapshot.json") }

    static func avatarURL(_ file: String) -> URL? { folderURL?.appending(path: file) }

    /// Kleine Fassung (72 px) eines Avatars, z. B. für die Ecken-Komplikation
    static func smallAvatarName(_ file: String) -> String {
        file.hasSuffix(".png") ? String(file.dropLast(4)) + "-s.png" : file + "-s"
    }

    static func load() -> WatchWidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.watchLink.decode(WatchWidgetSnapshot.self, from: data)
    }

    /// Speichert und gibt zurück, ob sich etwas geändert hat (sonst kein Neuladen der Komplikationen nötig)
    @discardableResult
    func save() -> Bool {
        guard let folder = Self.folderURL, let url = Self.fileURL else { return false }
        var comparable = self
        comparable.updatedAt = .distantPast
        if var old = Self.load() {
            old.updatedAt = .distantPast
            if old == comparable { return false }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.watchLink.encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Beispieldaten (Widget-Vorschau, Demo)
    static let preview = WatchWidgetSnapshot(
        chats: [
            WatchWidgetChat(id: "b_lucy", name: "Lucy", label: "Assistenz", isGroup: false, unread: 2, waiting: true,
                            preview: "Soll ich die Mail an Jonas senden?", color: "#FF5FA8", avatarFile: nil),
            WatchWidgetChat(id: "b_mila", name: "Mila", label: "MLP", isGroup: false, unread: 0, waiting: false,
                            preview: "Termine für morgen stehen.", color: "#7C5CFF", avatarFile: nil),
        ],
        pendingApprovals: 2,
        approvals: [WatchWidgetApproval(title: "Mail an Jonas senden", chatName: "Lucy", chatID: "b_lucy")],
        serverName: "Demo", demo: true)
}

// Gemeinsame JSON-Kodierung für WatchConnectivity und App-Gruppe (Datum als Sekunden)
nonisolated extension JSONEncoder {
    static var watchLink: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

nonisolated extension JSONDecoder {
    static var watchLink: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
