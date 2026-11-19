import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// Rote Zahl am App-Symbol (iPhone/iPad: Home-Bildschirm, Mac: Dock).
/// Zählt Chats mit ungelesenen Nachrichten, nicht die Nachrichten selbst.
/// Läuft die App nicht, setzt der Server die Zahl über `aps.badge` in Mitteilungen bzw. stille Badge-Pushes.
enum AppBadge {
    @MainActor
    static func set(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }
}
