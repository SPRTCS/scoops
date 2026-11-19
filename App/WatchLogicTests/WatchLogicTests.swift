import Foundation
import Testing

@Suite("Uhr: Text")
struct WatchTextTests {
    @Test func kurzerTextBleibt() {
        let r = WatchText.truncated("Hallo Arman", limit: 50)
        #expect(r.text == "Hallo Arman")
        #expect(!r.isTruncated)
    }

    @Test func kuerztAnWortgrenze() {
        let text = String(repeating: "Wort ", count: 100)
        let r = WatchText.truncated(text, limit: 42)
        #expect(r.isTruncated)
        #expect(r.text.hasSuffix(" …"))
        #expect(!r.text.dropLast(2).hasSuffix("Wor"))
        #expect(r.text.count <= 44)
    }

    @Test func schliesstOffenesFett() {
        let r = WatchText.truncated("Das ist **sehr wichtig und noch viel mehr Text danach", limit: 25)
        #expect(r.isTruncated)
        let body = String(r.text.dropLast(2))
        #expect(body.components(separatedBy: "**").count % 2 == 1)
    }

    @Test func halberLinkWirdText() {
        #expect(WatchText.closeOpenMarkers("Siehe [Dokumentation](https://exa") == "Siehe Dokumentation")
        #expect(WatchText.closeOpenMarkers("Code `let x") == "Code `let x`")
    }

    @Test func markdownVereinfacht() {
        let md = "# Agenda\n\n- Punkt eins\n- Punkt **zwei**\n\n1. Erstens\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\n> Zitat"
        let s = WatchText.simplified(md)
        #expect(s.contains("**Agenda**"))
        #expect(s.contains("• Punkt eins"))
        #expect(s.contains("• Punkt **zwei**"))
        #expect(s.contains("1. Erstens"))
        #expect(s.contains("**A · B**"))
        #expect(s.contains("1 · 2"))
        #expect(s.contains("„Zitat“"))
        #expect(!s.contains("---"))
        #expect(!s.contains("#"))
    }

    @Test func vorschauEinzeilig() {
        let m = Message(id: "m1", botId: "b_1", role: .bot, text: "**Hallo**\n\nZweite Zeile", createdAt: Date())
        #expect(WatchText.preview(m) == "Hallo Zweite Zeile")
        let lang = Message(id: "m2", botId: "b_1", role: .bot, text: String(repeating: "a", count: 200), createdAt: Date())
        #expect(WatchText.preview(lang, limit: 20)?.count == 20)
    }
}

@Suite("Uhr: Freigaben")
struct WatchApprovalTests {
    private func approval(_ id: String, chat: String = "b_1", state: String = "pending", kind: String? = nil,
                          minutesAgo: Double = 0, canAlways: Bool = false) -> Message {
        var meta = MessageMeta(state: state, approvalId: "a_\(id)", title: "Titel \(id)", details: "Details", kind: kind)
        meta.canAlways = canAlways
        return Message(id: id, botId: chat, role: .approval, text: "", createdAt: Date().addingTimeInterval(-minutesAgo * 60),
                       meta: meta)
    }

    @Test func offeneUeberAlleChatsNeuesteZuerst() {
        let msgs = ["b_1": [approval("1", minutesAgo: 10), approval("2", state: "approved")],
                    "g_1": [approval("3", chat: "g_1", minutesAgo: 1)]]
        let pending = WatchApprovals.pending(in: msgs)
        #expect(pending.map(\.id) == ["3", "1"])
    }

    @Test func doppelteKartenNurEinmal() {
        let a = approval("1")
        var b = approval("1b")
        b.meta.approvalId = a.meta.approvalId
        #expect(WatchApprovals.pending(in: ["b_1": [a], "g_1": [b]]).count == 1)
    }

    @Test func knoepfeJeZustand() {
        #expect(ApprovalPresentation(approval("1")).availableDecisions == [.approve, .decline])
        #expect(ApprovalPresentation(approval("1", canAlways: true)).availableDecisions == [.approve, .decline, .always])
        #expect(ApprovalPresentation(approval("1", state: "approved")).availableDecisions.isEmpty)
        // Login speichern braucht ein Passwort → nur am iPhone
        let vault = ApprovalPresentation(approval("1", kind: "vault"))
        #expect(vault.needsPhone)
        #expect(vault.availableDecisions.isEmpty)
    }

    @Test func zustaendeUndArten() {
        #expect(ApprovalPresentation(approval("1", state: "declined")).stateLabel == "Abgelehnt")
        #expect(ApprovalPresentation(approval("1", state: "applied")).state == .approved)
        #expect(ApprovalPresentation(approval("1", kind: "call")).kindLabel == "Anruf")
        #expect(ApprovalPresentation(approval("1", kind: "t3")).icon == "hammer.fill")
    }

    @Test func mailZusammenfassung() {
        var m = approval("1", kind: "mail")
        m.meta.mail = MailDraft(account: "arbeit", accountEmail: nil, to: ["jonas@example.com"], subject: "Agenda",
                                body: "Hallo **Jonas**")
        let p = ApprovalPresentation(m)
        #expect(p.summary.contains("An: jonas@example.com"))
        #expect(p.summary.contains("Betreff: Agenda"))
        #expect(p.summary.contains("Hallo Jonas"))
    }

    @Test func entscheidungOptimistisch() {
        let a = approval("1")
        #expect(WatchApprovals.applying(.decline, to: a).meta.state == "declined")
        let always = WatchApprovals.applying(.always, to: a)
        #expect(always.meta.state == "approved")
        #expect(always.meta.always == true)
        #expect(ApprovalDecision.always.wireValue == "approve_always")
    }

    @Test func mitteilungsAktionen() {
        #expect(ApprovalNotificationActions.decision(for: ApprovalNotificationActions.approveAction) == "approve")
        #expect(ApprovalNotificationActions.decision(for: ApprovalNotificationActions.declineAction) == "decline")
        #expect(ApprovalNotificationActions.decision(for: ApprovalNotificationActions.alwaysAction) == "approve_always")
        #expect(ApprovalNotificationActions.decision(for: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        // Jede Mitteilungs-Entscheidung ist eine gültige Entscheidung der Uhr
        for action in [ApprovalNotificationActions.approveAction, ApprovalNotificationActions.declineAction,
                       ApprovalNotificationActions.alwaysAction] {
            #expect(ApprovalNotificationActions.decision(for: action).flatMap(ApprovalDecision.init(rawValue:)) != nil)
        }
        #expect(ApprovalNotificationActions.approvalID(in: ["approval_id": "a_1"]) == "a_1")
        #expect(ApprovalNotificationActions.approvalID(in: ["approval_id": ""]) == nil)
    }
}

@Suite("Uhr: Deep Links und Reihenfolge")
struct WatchRouteTests {
    @Test func chatMitEingabe() {
        let url = WatchRoute.chat(id: "b_lucy", compose: true).url
        #expect(url.absoluteString == "aisscoops-watch://chat/b_lucy?compose=1")
        #expect(WatchRoute(url: url) == .chat(id: "b_lucy", compose: true))
        #expect(WatchRoute(url: URL(string: "aisscoops-watch://chat/g_team")!) == .chat(id: "g_team", compose: false))
    }

    @Test func andereZiele() {
        #expect(WatchRoute(url: URL(string: "aisscoops-watch://approvals")!) == .approvals)
        #expect(WatchRoute(url: URL(string: "aisbot://chat/b_1")!) == nil)
        #expect(WatchRoute(url: URL(string: "aisscoops-watch://chat/b_1%2F..")!) == nil)
    }

    @Test func angehefteteZuerstDannAktivitaet() {
        struct C { var id: String; var pinned: Bool; var date: Date? }
        let now = Date()
        let items = [C(id: "a", pinned: false, date: now.addingTimeInterval(-60)),
                     C(id: "b", pinned: true, date: now.addingTimeInterval(-3600)),
                     C(id: "c", pinned: false, date: now),
                     C(id: "d", pinned: false, date: nil)]
        let sorted = WatchChatOrder.sorted(items, pinned: \.pinned, lastActivity: \.date)
        #expect(sorted.map(\.id) == ["b", "c", "a", "d"])
    }
}

@Suite("Uhr: Zugangsdaten")
struct WatchCredentialsTests {
    private let server = WatchServer(id: "manual", name: "Air", url: "https://air.example.ts.net:8787/", altURL: nil,
                                     usesAccount: false, token: "geheim-123")

    @Test func beschreibungOhneToken() {
        let creds = WatchCredentials(servers: [server], activeServerID: "manual", accountToken: "jwt-geheim")
        #expect(!creds.description.contains("geheim"))
        #expect(!server.description.contains("geheim"))
    }

    @Test func rundreise() throws {
        let creds = WatchCredentials(servers: [server], activeServerID: "manual", accountToken: nil,
                                     chats: [WatchChatSummary(id: "b_1", name: "Lucy", label: nil,
                                                              mascot: Mascot(shape: "pill", color: "#8A2EDB", eyes: "focused", accessory: "none"),
                                                              members: nil, unread: 2, waiting: true, preview: "Hi", pinned: true)])
        let data = try #require(creds.encoded())
        let back = try #require(WatchCredentials.decode(data))
        #expect(back.servers == creds.servers)
        #expect(back.chats.first?.mascot?.color == "#8A2EDB")
        #expect(back.bearer(for: server) == "geheim-123")
    }

    @Test func adressenUndAblauf() {
        #expect(server.baseURLs.map(\.absoluteString) == ["https://air.example.ts.net:8787"])
        let account = WatchServer(id: "s1", name: "Air", url: "https://a.example", altURL: "http://100.1.2.3:8787",
                                  usesAccount: true, token: nil)
        #expect(account.baseURLs.count == 2)
        let soon = WatchCredentials(servers: [account], accountToken: "x", accountExpiry: Date().addingTimeInterval(3600))
        #expect(soon.accountTokenNeedsRefresh())
        let later = WatchCredentials(servers: [account], accountToken: "x", accountExpiry: Date().addingTimeInterval(9 * 86400))
        #expect(!later.accountTokenNeedsRefresh())
        #expect(WatchCredentials(servers: [account], accountToken: nil).accountTokenNeedsRefresh())
    }

    @Test func nurApiPfadeWeiterreichen() {
        #expect(WatchLink.isRelayablePath("/api/bots"))
        #expect(!WatchLink.isRelayablePath("/mcp/task"))
        #expect(!WatchLink.isRelayablePath("/api/../setup"))
        #expect(!WatchLink.isRelayablePath("https://evil.example/api/x"))
    }
}
