import Foundation

/// Kompakter Stand für Widgets, den die App in den App-Group-Container schreibt.
/// Widgets rendern nur aus diesem Schnappschuss (kein Netzwerk).
nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    var userName: String
    var bots: [WidgetBot]

    static let empty = WidgetSnapshot(generatedAt: .distantPast, userName: "Arman", bots: [])

    /// Standardreihenfolge: angepinnt zuerst, dann zuletzt aktiv.
    var orderedBots: [WidgetBot] {
        bots.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (a.lastMessageAt ?? .distantPast) > (b.lastMessageAt ?? .distantPast)
        }
    }

    var busyCount: Int { bots.filter(\.busy).count }

    func bot(_ id: String) -> WidgetBot? { bots.first { $0.id == id } }
}

nonisolated struct WidgetBot: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String?
    var mascot: Mascot
    var pinned: Bool
    var busy: Bool
    /// Neueste Statuszeile des laufenden Laufs („Ist im Browser auf google.com“).
    var statusLine: String?
    var runStartedAt: Date?
    /// Lauf-ID des aktuellen Laufs (für Live-Aktivitäten), v1.1
    var runId: String?
    var unread: Int
    var lastMessagePreview: String?
    var lastMessageAt: Date?

    var title: String {
        if let label, !label.isEmpty { return "\(name) · \(label)" }
        return name
    }

    var deepLink: URL { URL(string: "aisbot://bot/\(id)")! }
}

nonisolated enum SharedContainer {
    /// iOS: `group.com.ais.aisbot`. macOS: Team-präfixierte Gruppe, die ohne Provisioning-Profil
    /// funktioniert (für `group.`-Gruppen verlangt macOS ein Profil mit registriertem Gerät).
    #if os(macOS)
    static let appGroup = "MYXQKK3T2Z.com.ais.aisbot"
    #else
    static let appGroup = "group.com.ais.aisbot"
    #endif
    private static let fileName = "widget-snapshot.json"

    static var snapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: fileName)
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
