import Foundation
import UserNotifications

/// Mitteilungs-Aktionen für Freigaben (iPhone, Mac und Apple Watch).
///
/// Der Server setzt bei Freigabe-Pushes (ab Server 1.32) `aps.category` = `SCOOP_APPROVAL` bzw.
/// `SCOOP_APPROVAL_ALWAYS` (wenn „Immer erlauben“ möglich ist) und schickt `approval_id` mit. Die Knöpfe laufen im
/// Hintergrund (ohne die App zu öffnen); „Freigeben“ und „Immer erlauben“ verlangen ein entsperrtes Gerät.
/// Auf der Uhr erscheinen dieselben Knöpfe an gespiegelten iPhone-Mitteilungen; die Uhren-App registriert die
/// Kategorien ebenfalls und entscheidet selbst, sonst das iPhone.
nonisolated enum ApprovalNotificationActions {
    static let category = "SCOOP_APPROVAL"
    static let categoryWithAlways = "SCOOP_APPROVAL_ALWAYS"

    static let approveAction = "SCOOP_APPROVE"
    static let declineAction = "SCOOP_DECLINE"
    static let alwaysAction = "SCOOP_APPROVE_ALWAYS"

    static let approvalIDKey = "approval_id"
    static let chatIDKey = "chat_id"

    static var categories: Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: approveAction, title: String(localized: "Freigeben"),
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let decline = UNNotificationAction(identifier: declineAction, title: String(localized: "Ablehnen"), options: [.destructive],
                                           icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let always = UNNotificationAction(identifier: alwaysAction, title: String(localized: "Immer erlauben"),
                                          options: [.authenticationRequired],
                                          icon: UNNotificationActionIcon(systemImageName: "checkmark.seal"))
        return [
            UNNotificationCategory(identifier: category, actions: [approve, decline], intentIdentifiers: [],
                                   options: []),
            UNNotificationCategory(identifier: categoryWithAlways, actions: [approve, decline, always],
                                   intentIdentifiers: [], options: []),
        ]
    }

    /// Registriert die Kategorien zusätzlich zu bereits vorhandenen.
    static func register() {
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let ours = Set(categories.map(\.identifier))
            UNUserNotificationCenter.current()
                .setNotificationCategories(existing.filter { !ours.contains($0.identifier) }.union(categories))
        }
    }

    /// Entscheidung zu einer Aktion (nil = keine Freigabe-Aktion, z. B. normales Antippen)
    static func decision(for actionIdentifier: String) -> String? {
        switch actionIdentifier {
        case approveAction: "approve"
        case declineAction: "decline"
        case alwaysAction: "approve_always"
        default: nil
        }
    }

    static func approvalID(in userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[approvalIDKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
