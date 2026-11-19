import Foundation

// MARK: - Reine Logik der Uhr (testbar ohne Oberfläche, siehe WatchLogicTests)

/// Vereinfachtes Markdown für den kleinen Bildschirm: Überschriften fett, Listen mit „•“, Tabellen als Zeilen,
/// Code und Zitate als normaler Text. Inline-Markdown (fett, kursiv, Code, Links) bleibt erhalten und wird beim
/// Anzeigen von `AttributedString(markdown:)` gesetzt.
nonisolated enum WatchText {
    /// Standardlänge, ab der eine Nachricht gekürzt und „mehr“ angeboten wird
    static let defaultLimit = 280

    static func simplified(_ markdown: String) -> String {
        let clean = MarkdownText.stripCitationMarks(markdown)
        var lines: [String] = []
        for block in MarkdownText.blocks(clean) {
            switch block {
            case .paragraph(let s):
                lines.append(s)
            case .heading(let s, _):
                let t = s.trimmingCharacters(in: .whitespaces)
                lines.append(t.hasPrefix("**") ? t : "**\(t)**")
            case .bullet(let s, let level):
                lines.append(String(repeating: "  ", count: min(level, 2)) + "• " + s)
            case .numbered(let s, let number):
                lines.append("\(number). \(s)")
            case .quote(let s):
                lines.append("„\(s)“")
            case .code(let s):
                lines.append(s)
            case .table(let header, let rows, _):
                if !header.isEmpty { lines.append("**" + header.joined(separator: " · ") + "**") }
                for row in rows { lines.append(row.joined(separator: " · ")) }
            case .rule:
                continue
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kürzt an einer Wortgrenze und schließt offene Markdown-Zeichen, damit kein „**“ stehen bleibt.
    /// - Returns: gekürzter Text und ob gekürzt wurde
    static func truncated(_ text: String, limit: Int = defaultLimit) -> (text: String, isTruncated: Bool) {
        guard text.count > limit, limit > 0 else { return (text, false) }
        var cut = String(text.prefix(limit))
        // Zeilen- oder Wortgrenze in den letzten 25 % suchen
        let minKeep = Int(Double(limit) * 0.75)
        if let idx = cut.lastIndex(where: { $0 == "\n" || $0 == " " }),
           cut.distance(from: cut.startIndex, to: idx) >= minKeep {
            cut = String(cut[..<idx])
        }
        cut = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cut.last, ",;:–-(".contains(last) { cut.removeLast() }
        cut = closeOpenMarkers(cut)
        return (cut + " …", true)
    }

    /// Schließt unpaarige `**`, `*`/`_` und `` ` `` am Ende (kein halber Link: offenes `[` wird entfernt).
    static func closeOpenMarkers(_ s: String) -> String {
        var out = s
        // Halber Link „[Text](http…“ oder „[Text“ → nur den Text behalten
        if let open = out.lastIndex(of: "["), !out[open...].contains(")") {
            let tail = out[out.index(after: open)...]
            let label = tail.split(separator: "]", maxSplits: 1).first.map(String.init) ?? String(tail)
            out = String(out[..<open]) + label
        }
        if out.components(separatedBy: "`").count % 2 == 0 { out += "`" }
        let bold = out.components(separatedBy: "**").count - 1
        if bold % 2 == 1 { out += "**" }
        let singles = out.replacingOccurrences(of: "**", with: "").filter { $0 == "*" }.count
        if singles % 2 == 1 { out += "*" }
        return out
    }

    /// Inline-Markdown als AttributedString (fällt auf reinen Text zurück)
    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// Einzeilige Vorschau ohne Markdown
    static func preview(_ message: Message?, limit: Int = 90) -> String? {
        guard let message else { return nil }
        let raw = message.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.count > limit ? String(raw.prefix(limit - 1)) + "…" : raw
    }
}

/// Entscheidung über eine Freigabe
nonisolated enum ApprovalDecision: String, CaseIterable, Sendable {
    case approve
    case decline
    case always = "approve_always"

    var wireValue: String { rawValue }

    /// Zustand der Karte nach der Entscheidung (optimistisch)
    var resultingState: String { self == .decline ? "declined" : "approved" }

    var title: String {
        switch self {
        case .approve: "Freigeben"
        case .decline: "Ablehnen"
        case .always: "Immer erlauben"
        }
    }
}

/// Was die Uhr über eine Freigabe-Karte zeigt und welche Knöpfe sie anbietet.
nonisolated struct ApprovalPresentation: Equatable, Sendable {
    var title: String
    var kindLabel: String
    var icon: String
    /// Kurze Zusammenfassung (wenige Zeilen)
    var summary: String
    var state: State
    var canAlways: Bool
    /// Manche Freigaben gehen nur am iPhone (z. B. Login speichern braucht ein Passwort)
    var needsPhone: Bool

    enum State: String, Sendable { case pending, approved, declined, other }

    var stateLabel: String {
        switch state {
        case .pending: "Wartet auf dich"
        case .approved: "Freigegeben"
        case .declined: "Abgelehnt"
        case .other: "Erledigt"
        }
    }

    var availableDecisions: [ApprovalDecision] {
        guard state == .pending, !needsPhone else { return [] }
        return canAlways ? [.approve, .decline, .always] : [.approve, .decline]
    }

    init(title: String, kindLabel: String, icon: String, summary: String, state: State, canAlways: Bool, needsPhone: Bool) {
        self.title = title; self.kindLabel = kindLabel; self.icon = icon; self.summary = summary
        self.state = state; self.canAlways = canAlways; self.needsPhone = needsPhone
    }

    init(_ message: Message) {
        let meta = message.meta
        let kind = meta.kind ?? ""
        let rawState = meta.state ?? "pending"
        state = State(rawValue: rawState) ?? (rawState == "saved" || rawState == "applied" ? .approved : .other)
        canAlways = meta.canAlways == true
        needsPhone = kind == "vault"
        var title = (meta.title ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        var summary = ""
        switch kind {
        case "mail":
            kindLabel = "Mail"
            icon = "envelope.fill"
            if let mail = meta.mail {
                if title.isEmpty { title = mail.subject }
                let to = (mail.to + mail.cc).joined(separator: ", ")
                summary = ["An: \(to)", mail.subject.isEmpty ? nil : "Betreff: \(mail.subject)",
                           WatchText.truncated(MarkdownText.plain(mail.body), limit: 160).text]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        case "call":
            kindLabel = "Anruf"
            icon = "phone.fill"
        case "t3", "t3_send":
            kindLabel = "T3 Code"
            icon = "hammer.fill"
        case "vault":
            kindLabel = "Login speichern"
            icon = "key.fill"
            if let vault = meta.vault {
                if title.isEmpty { title = vault.title }
                summary = [vault.site, vault.username].compactMap { $0 }.joined(separator: "\n")
            }
        case "apple", "home":
            kindLabel = "Apple"
            icon = "house.fill"
        case "rechner":
            kindLabel = "Rechner"
            icon = "desktopcomputer"
        case "scoop_update":
            kindLabel = "Scoop ändern"
            icon = "slider.horizontal.3"
            if let update = meta.scoopUpdate {
                summary = WatchText.truncated(MarkdownText.plain(update.reason ?? update.after), limit: 160).text
            }
        default:
            kindLabel = "Freigabe"
            icon = "checkmark.shield.fill"
        }
        if summary.isEmpty, let details = meta.details, !details.isEmpty {
            summary = WatchText.truncated(WatchText.simplified(details), limit: 200).text
        }
        self.title = title.isEmpty ? "Freigabe" : title
        self.summary = summary
    }
}

/// Offene Freigaben über alle Chats
nonisolated enum WatchApprovals {
    /// Offene Karten aus den geladenen Nachrichten, neueste zuerst, ohne Doppelte (gleiche `approval_id`)
    static func pending(in messages: [String: [Message]]) -> [Message] {
        var seen = Set<String>()
        return messages.values.joined()
            .filter { $0.isPendingApproval }
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.meta.approvalId ?? $0.id).inserted }
    }

    /// Wendet eine Entscheidung optimistisch auf eine Karte an
    static func applying(_ decision: ApprovalDecision, to message: Message) -> Message {
        var m = message
        m.meta.state = decision.resultingState
        if decision == .always { m.meta.always = true }
        return m
    }
}

/// Deep Links in die Uhren-App (Komplikationen, Mitteilungen)
nonisolated enum WatchRoute: Equatable, Sendable {
    case chat(id: String, compose: Bool)
    case approvals
    case home

    static let scheme = "aisscoops-watch"

    var url: URL {
        switch self {
        case .chat(let id, let compose):
            var comps = URLComponents()
            comps.scheme = Self.scheme
            comps.host = "chat"
            comps.path = "/" + id
            if compose { comps.queryItems = [URLQueryItem(name: "compose", value: "1")] }
            return comps.url!
        case .approvals:
            return URL(string: "\(Self.scheme)://approvals")!
        case .home:
            return URL(string: "\(Self.scheme)://home")!
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host()?.lowercased() {
        case "chat":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
            let compose = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "compose" }?.value == "1"
            self = .chat(id: id, compose: compose)
        case "approvals":
            self = .approvals
        case "home", nil:
            self = .home
        default:
            return nil
        }
    }
}

/// Reihenfolge der Chats auf der Uhr: angeheftete zuerst, dann nach letzter Aktivität
nonisolated enum WatchChatOrder {
    static func sorted<T>(_ items: [T], pinned: (T) -> Bool, lastActivity: (T) -> Date?) -> [T] {
        items.enumerated().sorted { a, b in
            let pa = pinned(a.element), pb = pinned(b.element)
            if pa != pb { return pa }
            let da = lastActivity(a.element) ?? .distantPast, db = lastActivity(b.element) ?? .distantPast
            if da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
    }
}
