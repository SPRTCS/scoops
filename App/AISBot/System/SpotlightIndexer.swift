import AppIntents
import CoreSpotlight
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Scoops und Gruppen in der Systemsuche (docs/system.md): Name, Rolle und Bild. Nachrichten werden nicht
/// indexiert. Der Index folgt dem Verzeichnis für Erweiterungen: Jede Änderung (neuer Scoop, Umbenennen,
/// neues Aussehen, Löschen, Serverwechsel, Abmelden, Trennen) gleicht ihn ab; ohne Chats ist er leer.
///
/// Nebenbei entstehen hier die Chat-Bilder für Kurzbefehle und Controls (`SystemAvatars`): dasselbe Bild, einmal
/// gerendert.
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private static let domain = "chats"
    private static let signaturesKey = "spotlight.signatures.v2"
    private var task: Task<Void, Never>?

    /// Kennung eines Treffers: `chat|<server>|<chat-id>`
    static func itemID(_ chat: SystemChat) -> String { "chat|\(chat.serverID)|\(chat.id)" }

    static func link(forItemID id: String) -> DeepLink? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "chat", !parts[2].isEmpty else { return nil }
        return .chat(id: parts[2], server: parts[1].isEmpty ? nil : parts[1], compose: false)
    }

    /// Was am Treffer sichtbar ist. Ändert es sich, wird der Eintrag neu geschrieben (samt Bild).
    private static func signature(_ chat: SystemChat) -> String {
        let look: String
        if let mascot = chat.mascot {
            look = NotificationAvatarSync.appearanceKey(mascot, seed: chat.id)
        } else {
            look = (chat.members ?? []).prefix(3).map { NotificationAvatarSync.appearanceKey($0.mascot, seed: $0.id) }
                .joined(separator: "+")
        }
        // Sprache gehört dazu: Beschreibung und Suchwörter sind übersetzt
        return [chat.name, chat.subtitle ?? "", look, AppLanguage.code].joined(separator: "\u{1}")
    }

    /// `completion`: Bilder und Index sind auf dem neuen Stand.
    func update(directory: SystemDirectory, completion: @escaping () -> Void = {}) {
        let wanted = Dictionary(directory.chats.map { (Self.itemID($0), $0) }, uniquingKeysWith: { a, _ in a })
        let indexing = CSSearchableIndex.isIndexingAvailable()
        task?.cancel()
        task = Task {
            let index = CSSearchableIndex.default()
            let known = UserDefaults.standard.dictionary(forKey: Self.signaturesKey) as? [String: String] ?? [:]
            if wanted.isEmpty {
                // Abgemeldet, getrennt oder kein Chat mehr: alles entfernen
                guard !known.isEmpty else { return }
                if indexing { try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
                if let folder = SystemAvatars.folderURL { try? FileManager.default.removeItem(at: folder) }
                UserDefaults.standard.removeObject(forKey: Self.signaturesKey)
                completion()
                return
            }
            let stale = known.keys.filter { wanted[$0] == nil }
            if !stale.isEmpty, indexing { try? await index.deleteSearchableItems(withIdentifiers: stale) }
            let keptChatIDs = Set(wanted.values.map(\.id))
            for id in stale {
                // Bild nur entfernen, wenn es den Chat auf keinem Server mehr gibt
                guard let chatID = id.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init),
                      !keptChatIDs.contains(chatID), let url = SystemAvatars.fileURL(chatID: chatID) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
            var signatures = known.filter { wanted[$0.key] != nil }
            var items: [CSSearchableItem] = []
            if let folder = SystemAvatars.folderURL {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for (id, chat) in wanted.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                let signature = Self.signature(chat)
                guard known[id] != signature || SystemAvatars.imageURL(chatID: chat.id) == nil else { continue }
                // Eigenes Scoop-Bild: erst laden, sonst zeigte der Treffer dauerhaft das Maskottchen
                if let photo = chat.mascot?.photo { _ = await ScoopPhotoCache.shared.ensure(photo) }
                let image = Self.thumbnail(chat)
                if let image, let url = SystemAvatars.fileURL(chatID: chat.id) { try? image.write(to: url, options: .atomic) }
                items.append(Self.item(id: id, chat: chat, thumbnail: image))
                signatures[id] = signature
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            if !items.isEmpty, indexing {
                do { try await index.indexSearchableItems(items) } catch { return }
            }
            UserDefaults.standard.set(signatures, forKey: Self.signaturesKey)
            completion()
        }
    }

    private static func item(id: String, chat: SystemChat, thumbnail: Data?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = chat.name
        attributes.displayName = chat.name
        attributes.contentDescription = chat.subtitle ?? (chat.isGroup ? String(localized: "Gruppe in AIS Scoops")
                                                                       : String(localized: "Scoop in AIS Scoops"))
        var keywords = ["AIS Scoops", chat.isGroup ? String(localized: "Gruppe", comment: "Suchwort in Spotlight für einen Gruppenchat") : "Scoop", chat.name]
        if let label = chat.label, !label.isEmpty { keywords.append(label) }
        keywords += (chat.members ?? []).map(\.name)
        attributes.keywords = keywords
        attributes.thumbnailData = thumbnail
        let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attributes)
        // Derselbe Chat wie die Entität der Kurzbefehle: ein Treffer statt zwei, Tippen öffnet den Chat
        item.associateAppEntity(ChatEntity(chat), priority: 10)
        // Standard wäre ein Monat; die Chats bleiben, bis die App sie entfernt
        item.expirationDate = .distantFuture
        return item
    }

    /// Bild wie in Mitteilungen: Scoop-Figur bzw. eigenes Foto, bei Gruppen die ersten Mitglieder.
    private static func thumbnail(_ chat: SystemChat) -> Data? {
        let side: CGFloat = 90
        let content: AnyView
        if let mascot = chat.mascot {
            content = AnyView(NotificationAvatarArtwork(mascot: mascot, seed: chat.id, side: side))
        } else {
            let members = (chat.members ?? []).map { Bot(id: $0.id, name: $0.name, mascot: $0.mascot) }
            content = AnyView(ZStack {
                Color(hex: "#1B1B1D")
                GroupAvatar(members: members, size: side * 0.86)
            }
            .frame(width: side, height: side)
            .environment(\.theme, .nacht))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
