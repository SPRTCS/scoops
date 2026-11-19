import Foundation
import Intents
import UserNotifications

/// Macht aus einer Scoop-Mitteilung eine Communication Notification: Absender ist der schreibende Scoop
/// mit seinem Maskottchen als Bild (wie bei Messengern), Gruppen mit Gruppennamen.
///
/// Genutzt von der Notification-Service-Extension (Server-Pushes) und im Debug-Build von der
/// Testoption `-localpush` der App (gleicher Ablauf als lokale Mitteilung, weil `simctl push` die Extension
/// im Simulator nicht startet).
///
/// Payload (neben `aps`): `bot_id`/`chat_id`, `message_id`, `author_id` (`b_…`), `author_name`,
/// `group_name` (nur bei Gruppen). Das Bild rendert die Hauptapp vorab in den App-Group-Container
/// (`NotificationAvatars`). Fehlt es, geht die Original-Mitteilung unverändert raus.
nonisolated enum ScoopCommunication {
    /// Spendet die Interaktion und übergibt danach den aktualisierten Inhalt (oder das Original) an `deliver`.
    /// Rückgabe: Griff, um bei Zeitablauf das Original zuzustellen.
    @discardableResult
    static func process(_ content: UNNotificationContent,
                        deliver: @escaping (UNNotificationContent) -> Void) -> CommunicationDelivery {
        let delivery = CommunicationDelivery(fallback: content, handler: deliver)
        guard let intent = messageIntent(for: content) else {
            delivery.finishWithFallback()
            return delivery
        }
        delivery.intent = intent
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { _ in
            // Auch wenn das Spenden scheitert, kann `updating(from:)` noch klappen.
            delivery.finishUpdatingFromIntent()
        }
        return delivery
    }

    /// Baut den `INSendMessageIntent` – oder nil, wenn Absender oder vorgerendertes Bild fehlen.
    static func messageIntent(for content: UNNotificationContent) -> INSendMessageIntent? {
        let info = content.userInfo
        guard let authorID = nonEmpty(info["author_id"]),
              let imageURL = NotificationAvatars.imageURL(forBotID: authorID),
              let imageData = try? Data(contentsOf: imageURL)
        else { return nil }

        let authorName = nonEmpty(info["author_name"])
            ?? NotificationAvatars.loadIndex()?.bots[authorID]?.name
            ?? content.title
        let chatID = nonEmpty(info["chat_id"]) ?? nonEmpty(info["bot_id"]) ?? authorID
        let groupName = nonEmpty(info["group_name"])

        let sender = INPerson(personHandle: INPersonHandle(value: authorID, type: .unknown),
                              nameComponents: nil,
                              displayName: authorName,
                              image: INImage(imageData: imageData),
                              contactIdentifier: nil,
                              customIdentifier: authorID)

        var recipients: [INPerson]?
        var speakableGroupName: INSpeakableString?
        if let groupName {
            // Gruppe: mindestens zwei Beteiligte und ein Gruppenname, sonst zeigt das System einen Einzelchat.
            let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown),
                              nameComponents: nil, displayName: nil, image: nil,
                              contactIdentifier: nil, customIdentifier: "me", isMe: true)
            recipients = [me, sender]
            speakableGroupName = INSpeakableString(spokenPhrase: groupName)
        }

        return INSendMessageIntent(recipients: recipients,
                                   outgoingMessageType: .outgoingMessageText,
                                   content: content.body,
                                   speakableGroupName: speakableGroupName,
                                   conversationIdentifier: chatID,
                                   serviceName: nil,
                                   sender: sender,
                                   attachments: nil)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// Stellt genau einmal zu – entweder das Ergebnis oder (bei Zeitablauf/Fehler) die Original-Mitteilung.
nonisolated final class CommunicationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private let fallback: UNNotificationContent
    /// Wird vor dem Spenden gesetzt und danach nur noch gelesen.
    fileprivate var intent: INSendMessageIntent?

    init(fallback: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.fallback = fallback
        self.handler = handler
    }

    func finishWithFallback() { finish(fallback) }

    /// Absender, Bild und Gruppe aus dem Intent übernehmen; scheitert das, geht das Original raus.
    fileprivate func finishUpdatingFromIntent() {
        guard let intent, let updated = try? fallback.updating(from: intent) else {
            finish(fallback)
            return
        }
        finish(updated)
    }

    private func finish(_ content: UNNotificationContent) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?(content)
    }
}
