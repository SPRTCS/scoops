import Foundation

/// Demo-Daten der Uhr (Previews, Simulator-Screenshots, iPhone mit `-mock`, „Demo ansehen“ ohne Verbindung).
enum WatchDemo {
    static let now = Date()
    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let lucy = Bot(id: "b_lucy", name: "Lucy", label: "Assistenz",
                          mascot: Mascot(shape: "pill", color: "#8A2EDB", eyes: "focused", accessory: "glasses", gaze: "right"),
                          pinned: true, unread: 2, primary: true)
    static let theo = Bot(id: "b_theo", name: "Theo", label: "Recherche",
                          mascot: Mascot(shape: "cloud", color: "#1270E8", eyes: "dashes", accessory: "none", mouth: "smile"),
                          pinned: true, busy: true)
    static let mila = Bot(id: "b_mila", name: "Mila", label: "MLP",
                          mascot: Mascot(shape: "heart", color: "#F72A7A", eyes: "lashes", accessory: "none", gaze: "left",
                                         mouth: "smile"))
    static let lio = Bot(id: "b_lio", name: "Lio", label: "Social Media",
                         mascot: Mascot(shape: "egg", color: "#FBBA10", eyes: "relaxed", accessory: "beret", gaze: "right"),
                         unread: 1)
    static let pip = Bot(id: "b_pip", name: "Pip", label: "Erinnerungen",
                         mascot: Mascot(shape: "star_soft", color: "#43C62E", eyes: "cat", accessory: "cap", mouth: "smile"))

    static var bots: [Bot] {
        var list = [lucy, theo, mila, lio, pip]
        let last = messages
        for i in list.indices {
            list[i].lastMessage = last[list[i].id]?.last { $0.role != .status }
            list[i].waiting = last[list[i].id]?.contains { $0.isPendingApproval } ?? false
        }
        return list
    }

    static var groups: [ChatGroup] {
        var team = ChatGroup(id: "g_team", name: "Team Köln", memberIds: ["b_lucy", "b_mila", "b_lio"], unread: 0)
        team.lastMessage = messages["g_team"]?.last
        return [team]
    }

    static var messages: [String: [Message]] {
        var mail = MessageMeta(state: "pending", approvalId: "a_mail", title: "Mail an Jonas senden", kind: "mail")
        mail.canAlways = true
        mail.alwaysLabel = "Mails an jonas@kunde-demo.example"
        mail.mail = MailDraft(account: "arbeit", accountEmail: "arman@ais-demo.example", to: ["jonas@kunde-demo.example"],
                              subject: "Agenda für morgen, 9 Uhr",
                              body: "Hi Jonas,\n\nfür unseren Call schlage ich vor: 1. Stand der Kampagne, 2. Budget Q1, 3. nächste Schritte.\n\nBis morgen!\nArman")
        var call = MessageMeta(state: "pending", approvalId: "a_call", title: "Praxis Dr. Weber anrufen",
                               details: "Nummer: 0221 555 0142\nAnliegen: Termin für Donnerstagvormittag verschieben", kind: "call")
        call.authorId = "b_mila"
        let t3 = MessageMeta(state: "pending", approvalId: "a_t3", title: "Auftrag an T3: Login-Fehlermeldung",
                             details: "Projekt: AIS Scoops/Server\nAuftrag: Bei falschem Token eine klare deutsche Fehlermeldung zurückgeben und einen Test ergänzen.",
                             kind: "t3")
        return [
            "b_lucy": [
                Message(id: "l1", botId: "b_lucy", role: .user, text: "Bereite bitte die Agenda für morgen mit Jonas vor.",
                        createdAt: ago(14)),
                Message(id: "l2", botId: "b_lucy", role: .status, text: "", createdAt: ago(13.8),
                        meta: MessageMeta(state: "done", lines: ["Schaut in deinen Kalender", "Liest die letzten Mails mit Jonas"],
                                          startedAt: ago(13.8), finishedAt: ago(13))),
                Message(id: "l3", botId: "b_lucy", role: .bot,
                        text: "Erledigt! Ich habe die **Agenda** aus euren letzten Mails zusammengestellt:\n\n1. Stand der Kampagne\n2. Budget Q1\n3. Nächste Schritte\n\nDer Termin ist **morgen um 9:00** im Kalender, Raum Köln-Süd. Jonas hatte in seiner letzten Mail noch gefragt, ob ihr das Reporting für Oktober kurz anschauen könnt – das habe ich als Punkt 4 notiert, falls Zeit bleibt. Soll ich ihm die Agenda schicken?",
                        createdAt: ago(13)),
                Message(id: "l4", botId: "b_lucy", role: .approval, text: "", createdAt: ago(12.5), meta: mail),
            ],
            "b_theo": [
                Message(id: "t1", botId: "b_theo", role: .user, text: "Gibt es Neuigkeiten zum Login-Fehler?", createdAt: ago(40)),
                Message(id: "t2", botId: "b_theo", role: .bot,
                        text: "Ja: Bei falschem Token kommt bisher nur „401“. Ich würde T3 bitten, eine klare Meldung einzubauen.",
                        createdAt: ago(39)),
                Message(id: "t3", botId: "b_theo", role: .approval, text: "", createdAt: ago(38), meta: t3),
                Message(id: "t4", botId: "b_theo", role: .status, text: "", createdAt: ago(1),
                        meta: MessageMeta(state: "running", lines: ["Sucht Hotels in Köln", "Vergleicht Preise"],
                                          startedAt: ago(1))),
            ],
            "b_mila": [
                Message(id: "m1", botId: "b_mila", role: .bot, text: "Die Termine für morgen stehen. Um 14 Uhr ist noch frei.",
                        createdAt: ago(95)),
            ],
            "b_lio": [
                Message(id: "o1", botId: "b_lio", role: .bot,
                        text: "Neuer Post-Entwurf für LinkedIn ist fertig: „Drei Dinge, die ich diese Woche über KI-Assistenten gelernt habe“.",
                        createdAt: ago(180)),
            ],
            "b_pip": [
                Message(id: "p1", botId: "b_pip", role: .event, text: "Erinnerung angelegt: Müll rausbringen",
                        createdAt: ago(300), meta: MessageMeta(icon: "bell")),
            ],
            "g_team": [
                Message(id: "g1", botId: "g_team", role: .user, text: "Wer kümmert sich um den Praxistermin?", createdAt: ago(25)),
                Message(id: "g2", botId: "g_team", role: .bot, text: "Mach ich! Ich rufe kurz in der Praxis an.",
                        createdAt: ago(24), meta: MessageMeta(authorId: "b_mila")),
                Message(id: "g3", botId: "g_team", role: .approval, text: "", createdAt: ago(23.5), meta: call),
            ],
        ]
    }

    /// Kurze Demo-Antwort auf eine eigene Nachricht
    static func reply(to text: String, chatID: String) -> [Message] {
        let author = ChatGroup.isGroupID(chatID) ? "b_lucy" : nil
        return [Message(id: "demo-\(UUID().uuidString)", botId: chatID, role: .bot,
                        text: "Alles klar, ich kümmere mich darum und melde mich, sobald es erledigt ist.",
                        createdAt: Date(), meta: MessageMeta(authorId: author))]
    }
}
