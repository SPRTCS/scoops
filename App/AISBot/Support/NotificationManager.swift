import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// Mitteilungen: APNs-Pushes vom Server (Payload: `bot_id`, `message_id` neben `aps`) und als
/// Rückfallebene lokale Mitteilungen, solange der Server unser APNs-Token noch nicht kennt.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Wird beim Tippen auf eine Mitteilung aufgerufen (öffnet den Chat).
    var onOpenBot: ((String) -> Void)?
    weak var store: AppStore?

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        // Freigeben/Ablehnen direkt an Freigabe-Mitteilungen (auch gespiegelt auf der Apple Watch)
        ApprovalNotificationActions.register()
    }

    func notifyIfNeeded(message: Message, store: AppStore) {
        guard !isAppInForeground(store: store) else { return }
        // Der Server schickt bereits einen Push – keine doppelte Mitteilung.
        guard !PushManager.shared.isRegisteredWithServer else { return }
        let bot = store.bot(message.botId)
        let content = UNMutableNotificationContent()
        content.title = bot?.name ?? "AIS Scoops"
        content.body = String(MarkdownText.plain(message.text).prefix(240))
        content.sound = .default
        content.threadIdentifier = message.botId
        content.userInfo = ["bot_id": message.botId]
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func isAppInForeground(store: AppStore) -> Bool {
        #if os(macOS)
        return NSApplication.shared.isActive
        #else
        return store.isAppActive
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Banner unterdrücken, wenn genau dieser Chat gerade sichtbar ist.
    /// Bewusst die Variante mit Completion-Handler, der auf dem Hauptthread aufgerufen wird: Die `async`-Varianten
    /// riefen den UIKit-Handler auf einem Hintergrund-Thread auf – das brachte die App beim Antippen einer
    /// Mitteilung zum Absturz (SIGABRT in `userNotificationCenter(_:didReceive:)`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let botID = notification.request.content.userInfo["bot_id"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var visible = false
                if let store = NotificationManager.shared.store, let botID {
                    visible = store.visibleChatID == botID && store.isAppActive
                }
                completionHandler(visible ? [] : [.banner, .list, .sound])
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let botID = userInfo["bot_id"] as? String
        // Knopf „Freigeben“/„Ablehnen“/„Immer erlauben“: im Hintergrund entscheiden, ohne die App zu öffnen
        if let decision = ApprovalNotificationActions.decision(for: response.actionIdentifier),
           let approvalID = ApprovalNotificationActions.approvalID(in: userInfo) {
            DispatchQueue.main.async {
                _ = MainActor.assumeIsolated {
                    Task {
                        await NotificationManager.shared.decide(approvalID: approvalID, decision: decision)
                        completionHandler()
                    }
                }
            }
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let botID { NotificationManager.shared.open(botID) }
                completionHandler()
            }
        }
    }

    /// Entscheidung aus einer Mitteilung. Ohne laufende Verbindung baut der Store einen Client aus den gespeicherten
    /// Verbindungsdaten. Schlägt es fehl, kommt eine kurze lokale Mitteilung.
    private func decide(approvalID: String, decision: String) async {
        guard let service = store?.appleDeviceService() else {
            notifyDecisionFailed("Keine Verbindung zum Server.")
            return
        }
        do {
            let updated: Message
            switch decision {
            case "approve_always": updated = try await service.decideAlways(approvalID: approvalID, mailEdits: nil)
            default: updated = try await service.decide(approvalID: approvalID, approve: decision == "approve", note: nil)
            }
            store?.apply(.messageUpdated(updated))
        } catch {
            notifyDecisionFailed(error.localizedDescription)
        }
    }

    private func notifyDecisionFailed(_ reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Freigabe nicht übermittelt"
        content.body = "\(reason) Öffne AIS Scoops, um es nochmal zu versuchen."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-failed-\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }

    /// Chat öffnen; kommt die Mitteilung beim Kaltstart, bevor die Oberfläche bereit ist, wird sie nachgeholt.
    var pendingBotID: String?

    func open(_ botID: String) {
        if let onOpenBot { onOpenBot(botID) } else { pendingBotID = botID }
    }
}
