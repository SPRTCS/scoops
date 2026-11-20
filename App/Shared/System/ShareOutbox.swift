import Foundation

// MARK: - Ablage für geteilte Inhalte (Teilen-Menü → App, docs/system.md)
//
// Jede Sendung aus dem Teilen-Menü liegt zuerst als Ordner in der App-Gruppe (`ShareOutbox/<id>/`): `item.json`
// und die Dateien daneben. Die Erweiterung sendet von dort. Erreicht sie den Server nicht (oder wird sie
// beendet), bleibt der Ordner liegen und die App sendet ihn beim nächsten Öffnen nach. Auf dem Mac übergibt die
// Erweiterung grundsätzlich an die App.

nonisolated struct ShareOutboxItem: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// Inhalte werden noch gesammelt (Erweiterung offen, noch nicht „Senden“ getippt)
        case staging
        /// Die Erweiterung sendet gerade selbst
        case sending
        /// Wartet darauf, dass die App nachsendet
        case queued
    }

    struct Attachment: Codable, Hashable, Identifiable, Sendable {
        /// Dateiname im Ordner der Sendung
        var file: String
        /// Anzeigename für den Server
        var name: String
        var mime: String
        var size: Int
        /// Schon hochgeladen: ID in der Bibliothek des Chats (kein zweiter Upload beim Nachsenden)
        var fileID: String?

        var id: String { file }
        var isImage: Bool { mime.hasPrefix("image/") }
    }

    var id: String
    var createdAt: Date
    var chatID: String
    var serverID: String
    var chatName: String
    /// Nachrichtentext: Notiz, geteilter Text und Links
    var text: String
    var attachments: [Attachment]
    var state: State
    /// Lebenszeichen der Erweiterung: Bleibt es aus, übernimmt die App
    var touchedAt: Date
    /// Grund, warum die Sendung noch liegt (Anzeige in der App)
    var lastError: String?
    /// Aus dem Demo-Modus: Nur die App im Demo-Modus sendet sie (in ihren Demo-Chat)
    var demo: Bool = false
    /// Ohne Hinweis nachsenden (Demo: Die Erweiterung hat „Gesendet“ schon gezeigt)
    var silent: Bool = false

    var summary: String {
        var parts: [String] = []
        let images = attachments.filter(\.isImage).count
        let files = attachments.count - images
        if images > 0 { parts.append(String(localized: "\(images) Bilder")) }
        if files > 0 { parts.append(String(localized: "\(files) Dateien")) }
        if parts.isEmpty {
            parts.append(text.isEmpty ? String(localized: "Leer", comment: "Geteilte Sendung ohne Inhalt")
                                      : String(localized: "share.kind.text", defaultValue: "Text", comment: "Geteilte Sendung nur mit Text"))
        }
        return parts.joined(separator: ", ")
    }
}

nonisolated enum ShareOutbox {
    private static let folderName = "ShareOutbox"
    private static let manifestName = "item.json"
    /// So lange gilt eine Sendung ohne Lebenszeichen noch als „die Erweiterung sendet gerade“
    static let takeoverAfter: TimeInterval = 90
    /// Angefangene, nie abgeschickte Sendungen (Teilen abgebrochen oder Erweiterung beendet) räumt die App danach weg
    static let stagingLifetime: TimeInterval = 3600

    static var folderURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    static func folder(of id: String) -> URL? { folderURL?.appending(path: id, directoryHint: .isDirectory) }

    static func fileURL(_ attachment: ShareOutboxItem.Attachment, in item: ShareOutboxItem) -> URL? {
        folder(of: item.id)?.appending(path: attachment.file)
    }

    /// Neue, leere Sendung samt Ordner
    static func begin() -> ShareOutboxItem? {
        let item = ShareOutboxItem(id: UUID().uuidString, createdAt: Date(), chatID: "", serverID: "", chatName: "",
                                   text: "", attachments: [], state: .staging, touchedAt: Date(), lastError: nil)
        guard let folder = folder(of: item.id) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return save(item) ? item : nil
    }

    @discardableResult
    static func save(_ item: ShareOutboxItem) -> Bool {
        guard let url = folder(of: item.id)?.appending(path: manifestName) else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(item) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func load(_ id: String) -> ShareOutboxItem? {
        guard let url = folder(of: id)?.appending(path: manifestName), let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ShareOutboxItem.self, from: data)
    }

    private static let aliveName = "alive"

    /// Lebenszeichen der sendenden Erweiterung (billiger als das Manifest neu zu schreiben)
    static func touch(_ id: String) {
        guard let url = folder(of: id)?.appending(path: aliveName) else { return }
        try? Data().write(to: url)
    }

    /// Letztes Lebenszeichen: Manifest oder `touch`
    private static func lastSign(_ item: ShareOutboxItem) -> Date {
        let alive = folder(of: item.id)?.appending(path: aliveName)
        let touched = (try? alive?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return max(item.touchedAt, touched ?? .distantPast)
    }

    static func remove(_ id: String) {
        guard let folder = folder(of: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func all() -> [ShareOutboxItem] {
        guard let folder = folderURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap(load).sorted { $0.createdAt < $1.createdAt }
    }

    /// Verwaiste Entwürfe wegräumen: Teilen-Blatt weggewischt oder Erweiterung beendet, bevor „Senden“ getippt wurde.
    static func removeStaleDrafts(now: Date = Date()) {
        for item in all() where item.state == .staging && now.timeIntervalSince(lastSign(item)) > stagingLifetime {
            remove(item.id)
        }
    }

    /// Sendungen, die jetzt die App übernehmen soll: ausdrücklich abgelegte und solche, deren Erweiterung sich
    /// nicht mehr meldet.
    static func pendingForApp(now: Date = Date()) -> [ShareOutboxItem] {
        removeStaleDrafts(now: now)
        return all().filter { item in
            switch item.state {
            case .queued: true
            case .sending: now.timeIntervalSince(lastSign(item)) > takeoverAfter
            case .staging: false
            }
        }
    }

    /// Sendet eine Sendung: fehlende Uploads nachholen, dann die Nachricht mit allen Anhängen. Der Zwischenstand
    /// (hochgeladene Dateien) wird nach jedem Schritt gesichert. Bei Erfolg ist der Ordner weg.
    /// `progress`: 0…1 über alle Dateien.
    static func deliver(_ original: ShareOutboxItem, using service: SystemService,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var item = original
        let total = max(1, item.attachments.reduce(0) { $0 + max(1, $1.size) })
        var done = item.attachments.filter { $0.fileID != nil }.reduce(0) { $0 + max(1, $1.size) }
        progress(Double(done) / Double(total))
        for index in item.attachments.indices where item.attachments[index].fileID == nil {
            let attachment = item.attachments[index]
            guard let url = fileURL(attachment, in: item), FileManager.default.fileExists(atPath: url.path) else {
                throw SystemError(kind: .server, message: String(localized: "„\(attachment.name)“ ist nicht mehr vorhanden."))
            }
            let base = done
            let weight = max(1, attachment.size)
            let fileID = try await service.upload(chatID: item.chatID, file: url, name: attachment.name,
                                                  mime: attachment.mime) { fraction in
                progress(min(1, (Double(base) + fraction * Double(weight)) / Double(total)))
            }
            done += weight
            item.attachments[index].fileID = fileID
            item.touchedAt = Date()
            save(item)
        }
        progress(1)
        _ = try await service.send(chatID: item.chatID, text: item.text, fileIDs: item.attachments.compactMap(\.fileID))
        remove(item.id)
        SystemDirectory.noteUsed(chatID: item.chatID)
    }
}
