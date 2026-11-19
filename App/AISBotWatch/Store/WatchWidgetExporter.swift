import SwiftUI
import WidgetKit

/// Schreibt die Daten der Komplikationen in die App-Gruppe: kleine JSON-Datei und vorgerenderte Avatare
/// (PNG, 100 × 100 px und 72 × 72 px). Komplikationen werden nur neu geladen, wenn sich etwas geändert hat.
enum WatchWidgetExporter {
    static let avatarPoints: CGFloat = 50
    /// Erhöhen, wenn sich das Aussehen der vorgerenderten Avatare ändert (alte Dateien werden ersetzt)
    static let renderVersion = 2
    private static var pending: Task<Void, Never>?

    static func export(store: WatchStore) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await write(store: store)
        }
    }

    private static func write(store: WatchStore) async {
        guard let folder = WatchWidgetSnapshot.folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var avatarsChanged = false
        var items: [WatchWidgetChat] = []
        var keep = Set<String>()
        for chat in store.chats {
            let file = avatarFileName(chat)
            let small = WatchWidgetSnapshot.smallAvatarName(file)
            keep.formUnion([file, small])
            if let url = WatchWidgetSnapshot.avatarURL(file), let smallURL = WatchWidgetSnapshot.avatarURL(small),
               !FileManager.default.fileExists(atPath: url.path) || !FileManager.default.fileExists(atPath: smallURL.path) {
                if let photo = chat.mascot?.photo { await ScoopPhotoCache.shared.ensure(photo) }
                if let png = renderAvatar(chat, scale: 2), let smallPNG = renderAvatar(chat, scale: 1.44) {
                    try? png.write(to: url, options: .atomic)
                    try? smallPNG.write(to: smallURL, options: .atomic)
                    avatarsChanged = true
                }
            }
            items.append(WatchWidgetChat(id: chat.id, name: chat.name, label: chat.label, isGroup: chat.isGroup,
                                         unread: chat.unread, waiting: chat.waiting, preview: chat.preview,
                                         color: chat.mascot?.color ?? chat.members.first?.color, avatarFile: file))
        }
        // Alte Avatare entfernen
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.hasPrefix("a-") && !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
        let names = Dictionary(store.chats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let snapshot = WatchWidgetSnapshot(
            chats: items,
            pendingApprovals: store.approvals.count,
            approvals: store.approvals.prefix(3).map {
                WatchWidgetApproval(title: ApprovalPresentation($0).title, chatName: names[$0.chatId] ?? "Scoop",
                                    chatID: $0.chatId)
            },
            serverName: store.mode == .demo ? "Demo" : store.activeServer?.name,
            demo: store.mode == .demo)
        if snapshot.save() || avatarsChanged {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Dateiname aus Aussehen (stabil über Starts, ändert sich mit dem Maskottchen bzw. Bild)
    static func avatarFileName(_ chat: WatchChat) -> String {
        let mascots = chat.mascot.map { [$0] } ?? Array(chat.members.prefix(3))
        let key = mascots.map { m in
            [m.shape, m.color, m.eyes, m.accessory, m.gaze ?? "", m.mouth ?? "",
             m.photo.map { "\($0.id)@\($0.version)" } ?? ""].joined(separator: "|")
        }.joined(separator: "+")
        return "a-\(renderVersion)-\(ScoopPhotoCache.safeID(chat.id))-\(fnv(key)).png"
    }

    private static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    private static func renderAvatar(_ chat: WatchChat, scale: CGFloat) -> Data? {
        let view = WatchChatAvatar(chat: chat, size: avatarPoints, animated: false, showsWaiting: false)
            .environment(\.theme, .nacht)
            .frame(width: avatarPoints, height: avatarPoints)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.uiImage else { return nil }
        return image.pngData()
    }
}
