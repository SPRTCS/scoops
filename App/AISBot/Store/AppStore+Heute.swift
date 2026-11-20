import Foundation

// MARK: - Seite „Heute“ (Views/Today, docs/API.md „Seite Heute“)

extension AppStore {
    /// Seite „Heute“ öffnen: iPad/Mac zeigen sie in der Mitte, solange kein Chat gewählt ist; auf dem iPhone liegt sie
    /// im Stapel über der Chatliste (`showToday`).
    func openToday() {
        guard today.available else { return }
        showTaskBoard = false
        selectedChatID = nil
        showToday = true
    }

    /// Chat von der Seite „Heute“ aus öffnen und bei Bedarf zu einer Nachricht springen (Freigabe-Karte, Statuskarte).
    /// Auf dem iPhone bleibt „Heute“ darunter im Stapel, „Zurück“ führt wieder dorthin.
    func openChatFromToday(_ chatID: String, messageID: String? = nil) {
        guard chatExists(chatID) else { return }
        openChat(chatID)
        guard let messageID else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await jumpToMessage(messageID, chatID: chatID)
        }
    }

    /// Nach dem (Neu-)Verbinden und beim Zurückkehren in die App: Seite „Heute“ und Zähler abgleichen. Kennt der
    /// Server die Seite noch nicht, kurz nachsehen, ob er inzwischen aktualisiert wurde.
    func refreshToday() {
        guard let service else { return }
        Task {
            if !today.available, !isMock, let health = try? await service.health(), health.today == true {
                today.available = true
            }
            await today.load()
        }
    }

    /// Ereignisse des eigenen Servers an die Seite „Heute“ weitergeben (Nachrichten kommen über `upsert`).
    func applyToday(_ event: ServerEvent) {
        guard today.available else { return }
        switch event {
        case .botCreated(let b), .botUpdated(let b):
            today.chatChanged(id: b.id, busy: b.busy, waiting: b.waiting)
        case .groupCreated(let g), .groupUpdated(let g):
            today.chatChanged(id: g.id, busy: g.busy, waiting: g.waiting)
        case .botDeleted(let id), .groupDeleted(let id):
            today.chatDeleted(id)
        case .taskUpdated(let t):
            today.taskChanged(t)
        case .taskDeleted(let id):
            today.taskDeleted(id)
        case .routineUpdated:
            today.routineChanged()
        case .messageDeleted(let id, _):
            // Nach dem Bearbeiten einer Nachricht verworfene Antwort (auch eine laufende Statuskarte)
            today.messageDeleted(id)
        default:
            break
        }
    }

    /// Chats mit ungelesenen Nachrichten (eigene, Gruppen und mit mir geteilte), zuletzt aktive zuerst. Stumme Chats
    /// stehen dahinter: Sie sind ungelesen, sollen sich aber nicht vordrängen (wie der graue Punkt in der Seitenleiste;
    /// am App-Symbol zählen sie gar nicht). Ihre Freigaben stehen trotzdem unter „Wartet auf dich“.
    var unreadChats: [ChatEntry] {
        guard !TodayStore.demoEmpty else { return [] }
        return (allEntries + sharedBots.map(ChatEntry.bot)).filter { $0.unread > 0 }.sorted {
            let (a, b) = (isMuted($0.id), isMuted($1.id))
            return a != b ? !a : $0.date > $1.date
        }
    }
}
