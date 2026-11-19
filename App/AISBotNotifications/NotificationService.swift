import Foundation
import UserNotifications

/// Notification Service Extension: macht Server-Pushes zu Communication Notifications mit dem
/// Maskottchen des schreibenden Scoops (siehe `ScoopCommunication`). Rendert selbst nichts, sondern
/// liest nur die vorgerenderten PNGs der Hauptapp aus dem App-Group-Container.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: CommunicationDelivery?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        delivery = ScoopCommunication.process(request.content, deliver: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.finishWithFallback()
    }
}
