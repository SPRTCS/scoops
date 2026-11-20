import Foundation
import SwiftUI

// Suche und Chat-Komfort (App 1.3, docs/API.md „Suche und Chat-Komfort“): Modelle und Schnittstelle zum Server.

/// Treffer der Suche über alle Chats (`GET /api/search`) bzw. der lokalen Suche in geladenen Nachrichten.
nonisolated struct SearchHit: Decodable, Hashable, Identifiable, Sendable {
    var messageId: String
    var chatId: String
    /// `bot` oder `group`
    var chatKind: String?
    var chatName: String?
    var role: MessageRole
    /// Scoop-ID bzw. Konto-ID der Person
    var authorId: String?
    var authorName: String?
    var createdAt: Date
    /// Einzeiliger Ausschnitt um die Fundstelle
    var snippet: String
    /// Markierte Bereiche im Ausschnitt als `[start, ende)` in Unicode-Skalaren
    var marks: [[Int]]

    var id: String { messageId }

    init(messageId: String, chatId: String, chatKind: String? = nil, chatName: String? = nil, role: MessageRole,
         authorId: String? = nil, authorName: String? = nil, createdAt: Date, snippet: String, marks: [[Int]] = []) {
        self.messageId = messageId; self.chatId = chatId; self.chatKind = chatKind; self.chatName = chatName
        self.role = role; self.authorId = authorId; self.authorName = authorName; self.createdAt = createdAt
        self.snippet = snippet; self.marks = marks
    }

    private enum CodingKeys: String, CodingKey {
        case messageId, chatId, chatKind, chatName, role, authorId, authorName, createdAt, snippet, marks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        chatId = try c.decode(String.self, forKey: .chatId)
        chatKind = try? c.decodeIfPresent(String.self, forKey: .chatKind)
        chatName = try? c.decodeIfPresent(String.self, forKey: .chatName)
        role = (try? c.decode(MessageRole.self, forKey: .role)) ?? .unknown
        authorId = try? c.decodeIfPresent(String.self, forKey: .authorId)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        snippet = (try? c.decodeIfPresent(String.self, forKey: .snippet)) ?? ""
        marks = (try? c.decodeIfPresent([[Int]].self, forKey: .marks)) ?? []
    }

    /// Ausschnitt als Text mit hervorgehobener Fundstelle (Treffer fett in Textfarbe, Rest gedämpft).
    func attributedSnippet(theme: Theme) -> AttributedString {
        let scalars = Array(snippet.unicodeScalars)
        func piece(_ range: Range<Int>, hit: Bool) -> AttributedString {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            var a = AttributedString(String(view))
            a.foregroundColor = hit ? theme.textPrimary : theme.textSecondary
            if hit { a.inlinePresentationIntent = .stronglyEmphasized }
            return a
        }
        var out = AttributedString()
        var cursor = 0
        for mark in marks where mark.count == 2 {
            let lo = max(cursor, min(mark[0], scalars.count)), hi = max(lo, min(mark[1], scalars.count))
            if lo > cursor { out += piece(cursor..<lo, hit: false) }
            if hi > lo { out += piece(lo..<hi, hit: true) }
            cursor = hi
        }
        if cursor < scalars.count { out += piece(cursor..<scalars.count, hit: false) }
        return out
    }
}

nonisolated struct SearchResponse: Decodable, Sendable {
    var hits: [SearchHit]
    /// Alle Treffer auf dem Server (auch die nicht mitgeschickten)
    var total: Int?
    var truncated: Bool?
}

/// Ausschnitt eines Verlaufs rund um eine Nachricht (`GET /api/chats/{id}/messages/around/{mid}`).
nonisolated struct MessageWindow: Decodable, Sendable {
    var messages: [Message]
    var hasOlder: Bool
    var hasNewer: Bool
}

/// Text einer bearbeiteten Nachricht (`PATCH /api/messages/{id}`).
nonisolated struct MessageEdit: Encodable, Sendable {
    var text: String
}

/// Ergänzung zu `BotService` für Suche, Sprung zu einer Fundstelle und Bearbeiten. Eigenes Protokoll, damit ältere
/// Dienste unverändert bleiben; der Store fragt per `as? ChatComfortService`.
protocol ChatComfortService: AnyObject {
    /// Volltextsuche (neueste zuerst). `chatID`: nur dieser Chat.
    func searchMessages(query: String, chatID: String?, limit: Int) async throws -> SearchResponse
    /// Nachrichten rund um `messageID` (aufsteigend)
    func messagesAround(chatID: String, messageID: String, before: Int, after: Int) async throws -> MessageWindow
    /// Die nächsten Nachrichten nach `messageID` (aufsteigend)
    func messagesAfter(chatID: String, messageID: String, limit: Int) async throws -> [Message]
    /// Jüngste eigene Nachricht bearbeiten; der Scoop antwortet auf die neue Fassung
    func editMessage(id: String, text: String) async throws -> Message
}

extension APIClient: ChatComfortService {}
extension MockService: ChatComfortService {}

/// Was der eigene Server kann (aus `/api/health`). Ältere Server melden die Felder nicht: Dann sucht die App nur in
/// geladenen Nachrichten und bietet statt „Bearbeiten“ nur „Erneut senden …“ an.
struct ServerCapabilities: Equatable {
    var search = false
    var messageEdit = false

    init() {}

    init(_ health: Health) {
        search = health.search == true
        messageEdit = health.messageEdit == true
    }
}

// MARK: - Lokale Suche (Rückfall für ältere Server und offline)

enum LocalSearch {
    /// Durchsuchbarer Text wie im Index des Servers: bei Freigabe-Karten Titel und Details.
    static func searchableText(_ m: Message) -> String {
        m.role == .approval ? [m.meta.title, m.meta.details].compactMap { $0 }.joined(separator: " ") : m.text
    }

    static func tokens(_ query: String) -> [String] {
        var seen: [String] = []
        for t in Fuzzy.fold(query).split(whereSeparator: \.isWhitespace).map(String.init) where !seen.contains(t) {
            seen.append(t)
        }
        return seen
    }

    static func matches(_ m: Message, tokens: [String]) -> Bool {
        guard [.user, .bot, .event, .approval].contains(m.role) else { return false }
        let folded = Fuzzy.fold(searchableText(m))
        return !folded.isEmpty && tokens.allSatisfy { folded.contains($0) }
    }

    /// Einzeiliger Ausschnitt um die erste Fundstelle mit Markierungen (Unicode-Skalare, wie vom Server).
    static func snippet(_ text: String, tokens: [String]) -> (String, [[Int]]) {
        let flat = MarkdownText.plain(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var start = flat.startIndex
        if let first = tokens.compactMap({ flat.range(of: $0, options: options)?.lowerBound }).min(),
           flat.distance(from: flat.startIndex, to: first) > 36 {
            start = flat.index(first, offsetBy: -32)
            if let space = flat[start..<first].firstIndex(of: " ") { start = flat.index(after: space) }
        }
        var shown = String(flat[start...])
        if shown.count > 150 { shown = String(shown.prefix(150)) + "…" }
        if start > flat.startIndex { shown = "…" + shown }
        var marks: [[Int]] = []
        for token in tokens {
            var from = shown.startIndex
            while let r = shown.range(of: token, options: options, range: from..<shown.endIndex) {
                let lo = shown.unicodeScalars.distance(from: shown.unicodeScalars.startIndex, to: r.lowerBound)
                let hi = shown.unicodeScalars.distance(from: shown.unicodeScalars.startIndex, to: r.upperBound)
                marks.append([lo, hi])
                from = r.upperBound
            }
        }
        marks.sort { $0[0] < $1[0] }
        var merged: [[Int]] = []
        for m in marks {
            if let last = merged.last, m[0] <= last[1] { merged[merged.count - 1][1] = max(last[1], m[1]) } else { merged.append(m) }
        }
        return (shown, merged)
    }
}
