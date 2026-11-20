#if DEBUG
import Foundation
import UserNotifications

/// Nur Debug: `-localpush einzelchat,gruppe,ohne-bild,freigabe` schickt dieselben Payloads wie
/// `scripts/push-tests/*.apns` als lokale Mitteilungen durch `ScoopCommunication` (Spenden + `updating(from:)`),
/// also durch denselben Code wie die Notification-Service-Extension. Grund: `xcrun simctl push` stellt im
/// Simulator direkt zu und startet die Extension nicht. Erste Mitteilung nach 6 s, dann alle 6 s.
nonisolated enum NotificationTestPush {
    static var payloads: [String: (title: String, body: String, info: [String: String])] { [
        "einzelchat": ("Mila", demoText("Ich habe die drei Angebote verglichen. Das mittlere ist am günstigsten.",
                                         en: "I compared the three quotes. The middle one is the cheapest."),
                       ["bot_id": "b_mila", "chat_id": "b_mila", "message_id": "m_test_1",
                        "author_id": "b_mila", "author_name": "Mila"]),
        "gruppe": (demoText("Mila in Launch-Team", en: "Mila in Launch Team"),
                   demoText("Die Landingpage ist fertig, Theo kann jetzt die Texte prüfen.",
                            en: "The landing page is done. Theo can review the copy now."),
                   ["bot_id": "g_team", "chat_id": "g_team", "message_id": "m_test_2",
                    "author_id": "b_mila", "author_name": "Mila", "group_name": demoText("Launch-Team", en: "Launch Team")]),
        "ohne-bild": ("Neo", demoText("Hallo! Für mich gibt es noch kein vorgerendertes Bild.",
                                      en: "Hi! There’s no pre-rendered image for me yet."),
                      ["bot_id": "b_neo", "chat_id": "b_neo", "message_id": "m_test_3",
                       "author_id": "b_neo", "author_name": "Neo"]),
        "freigabe": ("Theo", demoText("Bittet um Freigabe: Mail an kunde@example.com senden",
                                      en: "Asks for approval: Send email to customer@example.com"),
                     ["bot_id": "b_theo", "chat_id": "b_theo", "message_id": "m_test_4",
                      "author_id": "b_theo", "author_name": "Theo"]),
    ] }

    static func schedule(_ names: [String]) {
        for (i, name) in names.enumerated() {
            guard let p = payloads[name] else { continue }
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            content.threadIdentifier = p.info["chat_id"] ?? "aisbot"
            content.userInfo = p.info
            ScoopCommunication.process(content) { updated in
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(6 * (i + 1)), repeats: false)
                let request = UNNotificationRequest(identifier: "test-\(name)-\(UUID().uuidString)", content: updated, trigger: trigger)
                // `updating(from:)` liefert ein neues Objekt; dasselbe heißt: Original ohne Absenderbild.
                let kind = updated === content ? "Original" : "Communication"
                UNUserNotificationCenter.current().add(request) { error in
                    NSLog("[Push] Test „%@“ geplant als %@: %@", name, kind, error?.localizedDescription ?? "ok")
                }
            }
        }
    }
}
#endif
