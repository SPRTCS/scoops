import Foundation
import SwiftUI

// Suche über alle Chats, Sprung zu einer Fundstelle (auch wenn sie noch nicht geladen ist) und eigene Nachricht
// bearbeiten (App 1.3). Server-Seite: docs/API.md „Suche und Chat-Komfort“.

/// Ergebnis einer Suche über Server und geladene Nachrichten.
struct MessageSearchResult {
    var hits: [SearchHit] = []
    /// Alle Treffer (auch die nicht geladenen), soweit bekannt
    var total = 0
    /// Nur in geladenen Nachrichten gesucht (älterer Server oder offline)
    var local = false
    var error: String?
}

/// Dienste, die eine der neuen Funktionen nicht kennen (älterer Server eines Admins, dessen Scoop mit mir geteilt
/// ist: Gäste dürfen `/api/health` nicht abfragen, die App merkt es erst an der Antwort 404/405).
private enum ComfortSupport {
    static var noSearch: Set<ObjectIdentifier> = []
    static var noEdit: Set<ObjectIdentifier> = []

    /// Fehlende Route (älterer Server: `{"detail": "Not Found"}`), nicht eine Fehlermeldung des Servers wie „Nachricht
    /// nicht gefunden“ (`{"error": …}`). Sprachunabhängig über `APIError.fromServer`.
    static func isMissingRoute(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return (api.status == 404 || api.status == 405) && !api.fromServer
    }
}

extension AppStore {
    // MARK: - Suche

    /// Sucht in allen Chats (`chatID == nil`) bzw. in einem Chat. Server-Suche, wo der Server sie kann; sonst
    /// (älterer Server, offline) in den geladenen Nachrichten.
    func searchMessages(_ query: String, chatID: String? = nil, limit: Int = 30) async -> MessageSearchResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return MessageSearchResult() }
        var result = MessageSearchResult()
        var localChats: [String] = []
        // Welche Server gefragt werden: der des Chats bzw. der eigene und alle, bei denen ich Gast bin
        var targets: [(service: ChatComfortService, own: Bool)] = []
        if let chatID {
            if let svc = searchService(for: chatID) { targets = [(svc, !isGuestChat(chatID))] } else { localChats = [chatID] }
        } else {
            if let svc = service as? ChatComfortService, capabilities.search {
                targets.append((svc, true))
            } else {
                localChats += messages.keys.filter { !isGuestChat($0) }
            }
            for (_, connection) in guestConnections {
                if let svc = connection.service as? ChatComfortService, !ComfortSupport.noSearch.contains(ObjectIdentifier(svc)) {
                    targets.append((svc, false))
                } else {
                    localChats += account.sharedWithMe.filter { $0.serverId == connection.serverID }.map(\.botId)
                }
            }
        }
        for target in targets {
            do {
                let response = try await target.service.searchMessages(query: q, chatID: chatID, limit: limit)
                result.hits += response.hits
                result.total += response.total ?? response.hits.count
            } catch {
                if Task.isCancelled { return result }
                if ComfortSupport.isMissingRoute(error), !target.own {
                    ComfortSupport.noSearch.insert(ObjectIdentifier(target.service))
                } else if target.own || chatID != nil {
                    result.error = message(error)
                }
                // Server nicht erreichbar oder zu alt: wenigstens die geladenen Nachrichten durchsuchen
                localChats += chatID.map { [$0] } ?? messages.keys.filter { isGuestChat($0) != target.own }
            }
        }
        if !localChats.isEmpty {
            let local = localSearch(q, chats: Set(localChats))
            result.hits += local
            result.total += local.count
            result.local = true
        }
        result.hits.sort { $0.createdAt > $1.createdAt }
        if result.hits.count > limit { result.hits = Array(result.hits.prefix(limit)) }
        result.total = max(result.total, result.hits.count)
        return result
    }

    private func searchService(for chatID: String) -> ChatComfortService? {
        guard let svc = service(for: chatID) as? ChatComfortService else { return nil }
        if isGuestChat(chatID) { return ComfortSupport.noSearch.contains(ObjectIdentifier(svc)) ? nil : svc }
        return capabilities.search ? svc : nil
    }

    /// Treffer in bereits geladenen Nachrichten (neueste zuerst).
    func localSearch(_ query: String, chats: Set<String>) -> [SearchHit] {
        let tokens = LocalSearch.tokens(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for (chatID, list) in messages where chats.contains(chatID) && chatExists(chatID) {
            for m in list where m.localState == nil && LocalSearch.matches(m, tokens: tokens) {
                let (snippet, marks) = LocalSearch.snippet(LocalSearch.searchableText(m), tokens: tokens)
                hits.append(SearchHit(messageId: m.id, chatId: chatID, chatKind: ChatGroup.isGroupID(chatID) ? "group" : "bot",
                                      chatName: chatName(chatID), role: m.role,
                                      authorId: m.role == .user ? m.meta.authorUserId : (m.meta.authorId ?? chatID),
                                      authorName: m.role == .user ? authorName(of: m) : nil,
                                      createdAt: m.createdAt, snippet: snippet, marks: marks))
            }
        }
        return hits.sorted { $0.createdAt > $1.createdAt }
    }

    /// Wer hat den Treffer geschrieben („Du“, Name der Person, Scoop) und in welchem Chat.
    func searchHitSource(_ hit: SearchHit) -> String {
        let author: String
        if hit.role == .user {
            let own = hit.authorId == nil || hit.authorId == account.user?.id || (!isGuestChat(hit.chatId) && bot(hit.chatId)?.isSharedByMe != true)
            author = own ? String(localized: "Du", comment: "Suchtreffer: Absender ist man selbst")
                : (hit.authorName ?? String(localized: "Jemand", comment: "Suchtreffer: unbekannter Absender"))
        } else if hit.role == .approval {
            author = String(localized: "Freigabe", comment: "Suchtreffer: Absender ist eine Freigabe-Karte")
        } else if hit.role == .event {
            author = String(localized: "Ereignis", comment: "Suchtreffer: Absender ist ein Ereignis im Verlauf")
        } else {
            author = bot(hit.authorId)?.name ?? hit.authorName ?? chatName(hit.chatId)
        }
        let chat = chatExists(hit.chatId) ? chatName(hit.chatId) : (hit.chatName ?? "Chat")
        return author == chat ? chat : String(localized: "\(author) in \(chat)", comment: "Suchtreffer: Absender in Chat")
    }

    // MARK: - Sprung zu einer Nachricht

    /// Sorgt dafür, dass die Nachricht im Verlauf des Chats steht. Ist sie nicht geladen: erst wenige ältere Seiten
    /// nachladen, sonst gezielt den Ausschnitt rund um die Nachricht holen. Liegen dahinter noch neuere Nachrichten,
    /// zeigt der Chat nur diesen Ausschnitt (`detachedChats`), bis man ans Ende zurückkehrt.
    func ensureMessageLoaded(_ id: String, chatID: String) async -> Bool {
        func loaded() -> Bool { messages[chatID]?.contains(where: { $0.id == id }) == true }
        if loaded() { return true }
        let comfort = searchService(for: chatID)
        // Schon offener Verlauf: nahe Nachrichten über das normale Nachladen holen (der Verlauf bleibt am Stück).
        // Ältere Server kennen nur diesen Weg, dort bis zu zehn Seiten.
        if messages[chatID] != nil, !detachedChats.contains(chatID) {
            var pages = 0
            while !loaded(), hasMoreHistory[chatID] == true, pages < (comfort == nil ? 10 : 2) {
                let before = messages[chatID]?.count ?? 0
                await loadOlderMessages(chatID: chatID)
                pages += 1
                if (messages[chatID]?.count ?? 0) == before { break }
            }
            if loaded() { return true }
        }
        guard let comfort else {
            // Älterer Server, Chat noch nicht geöffnet: die jüngsten Nachrichten laden und dort suchen
            if messages[chatID] == nil { await loadLatestMessages(chatID: chatID) }
            return loaded()
        }
        do {
            let window = try await comfort.messagesAround(chatID: chatID, messageID: id, before: 30, after: 30)
            let existing = messages[chatID] ?? []
            if !window.hasNewer {
                // Ausschnitt reicht bis zur jüngsten Nachricht: normaler Verlauf
                detachedChats.remove(chatID)
                setTranscript(chatID: chatID, window.messages, hasOlder: window.hasOlder)
            } else if !detachedChats.contains(chatID), let first = existing.first,
                      let overlap = window.messages.firstIndex(where: { $0.id == first.id }) {
                // Schließt lückenlos an den geladenen Verlauf an: davor einfügen
                setTranscript(chatID: chatID, Array(window.messages[..<overlap]) + existing, hasOlder: window.hasOlder)
            } else {
                detachedChats.insert(chatID)
                setTranscript(chatID: chatID, window.messages, hasOlder: window.hasOlder)
            }
            return loaded()
        } catch {
            if ComfortSupport.isMissingRoute(error), isGuestChat(chatID), let svc = service(for: chatID) as? ChatComfortService {
                ComfortSupport.noSearch.insert(ObjectIdentifier(svc))
                return await ensureMessageLoaded(id, chatID: chatID)
            }
            return false
        }
    }

    /// Treffer öffnen: Verlauf bereitstellen, Chat zeigen, zur Nachricht springen und sie kurz hervorheben.
    func openSearchHit(_ hit: SearchHit) async {
        let found = await ensureMessageLoaded(hit.messageId, chatID: hit.chatId)
        pendingScrollMessageID = nil
        if found { pendingScrollMessageID = hit.messageId } else { errorMessage = String(localized: "Die Nachricht ist nicht mehr im Verlauf.") }
        openChat(hit.chatId)
    }

    /// Zurück zu den jüngsten Nachrichten (aus einem Ausschnitt heraus).
    func returnToLatest(_ chatID: String) async {
        guard detachedChats.contains(chatID), let service = service(for: chatID) else { return }
        do {
            let page = try await service.messages(chatID: chatID, before: nil, limit: Self.pageSize)
            detachedChats.remove(chatID)
            setTranscript(chatID: chatID, page, hasOlder: page.count >= Self.pageSize)
        } catch {
            report(error)
        }
    }

    /// Im Ausschnitt die nächsten neueren Nachrichten anhängen. Sind keine mehr übrig, ist der Verlauf wieder vollständig.
    func loadNewerMessages(chatID: String) async {
        guard detachedChats.contains(chatID), let last = messages[chatID]?.last,
              let service = service(for: chatID) as? ChatComfortService else { return }
        do {
            let page = try await service.messagesAfter(chatID: chatID, messageID: last.id, limit: Self.pageSize)
            let known = Set(messages[chatID]?.map(\.id) ?? [])
            setTranscript(chatID: chatID, (messages[chatID] ?? []) + page.filter { !known.contains($0.id) },
                          hasOlder: hasMoreHistory[chatID] ?? false)
            if page.count < Self.pageSize { detachedChats.remove(chatID) }
        } catch {
            report(error)
        }
    }

    /// Chat verlassen: Ein Ausschnitt wird verworfen, beim nächsten Öffnen stehen wieder die jüngsten Nachrichten da.
    func leaveDetachedWindow(_ chatID: String) {
        guard detachedChats.contains(chatID), pendingScrollMessageID == nil else { return }
        detachedChats.remove(chatID)
        messages[chatID] = nil
    }

    /// Nachricht aus dem Verlauf entfernen (`message.deleted`: Antwort auf die alte Fassung einer bearbeiteten Nachricht).
    func removeMessageLocally(_ id: String, chatID: String) {
        messages[chatID]?.removeAll { $0.id == id }
    }

    // MARK: - Eigene Nachricht bearbeiten

    enum MessageEditAction {
        /// Jüngste eigene Nachricht: Text ersetzen, der Scoop antwortet neu
        case edit
        /// Ältere eigene Nachricht: Text ins Eingabefeld, geht als neue Nachricht raus
        case resend

        var title: String { self == .edit ? String(localized: "Bearbeiten") : String(localized: "Erneut senden …") }
        var icon: String { self == .edit ? "pencil" : "arrow.uturn.forward" }
    }

    /// Was das Kontextmenü an dieser Nachricht anbietet (`nil` = nichts: fremde Nachricht, Scoop, noch nicht gesendet).
    func editAction(for m: Message) -> MessageEditAction? {
        guard m.role == .user, isOwnMessage(m), m.localState == nil, !m.id.hasPrefix("local-"), !m.text.isEmpty,
              canWrite(m.chatId) else { return nil }
        let list = messages[m.chatId] ?? []
        let isLatest = list.last(where: { $0.role == .user && isOwnMessage($0) && $0.localState == nil })?.id == m.id
        let isTask = m.meta.taskOptions != nil || ComposerMode.parse(m.text)?.mode == .task
        guard isLatest, !detachedChats.contains(m.chatId), m.meta.live != true, !isTask, canEditOnServer(m.chatId) else {
            return .resend
        }
        return .edit
    }

    private func canEditOnServer(_ chatID: String) -> Bool {
        guard let svc = service(for: chatID) as? ChatComfortService else { return false }
        if isGuestChat(chatID) { return !ComfortSupport.noEdit.contains(ObjectIdentifier(svc)) }
        return capabilities.messageEdit
    }

    /// „Bearbeiten“ bzw. „Erneut senden …“ aus dem Kontextmenü: Text ins Eingabefeld, Feld fokussieren.
    func startEditing(_ m: Message) {
        guard let action = editAction(for: m) else { return }
        let draft = composerDraft(m.chatId)
        switch action {
        case .edit:
            // Schon getippter Entwurf kommt nach dem Bearbeiten (oder Abbrechen) zurück
            let previous = draft.editing?.previousDraft ?? draft.text
            draft.replyTo = nil
            draft.editing = ComposerDraft.EditTarget(messageID: m.id, original: m.text, previousDraft: previous)
            draft.text = m.text
        case .resend:
            draft.editing = nil
            draft.text = m.text
        }
        composerFocusRequest += 1
    }

    func cancelEditing(chatID: String) {
        let draft = composerDraft(chatID)
        guard let target = draft.editing else { return }
        draft.editing = nil
        draft.text = target.previousDraft
    }

    /// Bearbeitete Fassung abschicken. Die Blase zeigt den neuen Text sofort; lehnt der Server ab, steht wieder der alte da.
    func submitEdit(chatID: String, text: String) async {
        let draft = composerDraft(chatID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = draft.editing, !trimmed.isEmpty else { return }
        draft.editing = nil
        draft.text = target.previousDraft
        guard trimmed != target.original.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let svc = service(for: chatID) as? ChatComfortService,
              let original = messages[chatID]?.first(where: { $0.id == target.messageID }) else { return }
        var shown = original
        shown.text = trimmed
        shown.meta.edited = MessageMeta.EditInfo(at: Date(), mode: nil)
        replaceMessage(shown)
        do {
            upsert(try await svc.editMessage(id: target.messageID, text: trimmed))
        } catch {
            replaceMessage(original)
            if ComfortSupport.isMissingRoute(error) {
                // Älterer Server: Bearbeiten gibt es dort nicht. Text bleibt im Feld und kann neu gesendet werden.
                ComfortSupport.noEdit.insert(ObjectIdentifier(svc))
                draft.text = trimmed
                errorMessage = String(localized: "Dieser Server kann Nachrichten noch nicht bearbeiten. Du kannst den Text als neue Nachricht senden.")
            } else {
                draft.editing = target
                draft.text = trimmed
                report(error)
            }
        }
    }

    private func replaceMessage(_ m: Message) {
        guard let idx = messages[m.chatId]?.firstIndex(where: { $0.id == m.id }) else { return }
        messages[m.chatId]?[idx] = m
    }
}
