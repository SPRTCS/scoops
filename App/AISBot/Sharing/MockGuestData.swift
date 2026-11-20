import Foundation

/// Demo-Inhalte für geteilte Scoops: Junas Chat bei Sophie (ich bin Gast mit „Schreiben“ und „Zusehen“) und
/// Nachrichten von Lena in Milas Chat (ich bin Admin).
enum MockGuestData {
    private static func ago(_ minutes: Double) -> Date { PreviewData.now.addingTimeInterval(-minutes * 60) }
    private static let me = MockCloudService.demoUser

    static let juna = Bot(id: "b_juna", name: "Juna", label: demoText("Teamevents", en: "Team Events"), mascot: MockSharing.junaMascot,
                          character: demoText("Herzlich, organisiert, denkt an alle.", en: "Warm, organized, thinks of everyone."),
                          createdAt: ago(60 * 24 * 20), busy: false)
    static let kiko = Bot(id: "b_kiko", name: "Kiko", label: demoText("Reiseplanung", en: "Travel Planning"), mascot: MockSharing.kiko.botMascot ?? .default,
                          createdAt: ago(60 * 24 * 4))

    private static func user(_ id: String, _ chat: String, _ text: String, _ minutes: Double,
                             author: (String, String)? = nil) -> Message {
        var meta = MessageMeta()
        meta.authorUserId = author?.0
        meta.authorName = author?.1
        return Message(id: id, botId: chat, role: .user, text: text, createdAt: ago(minutes), meta: meta)
    }

    static let junaMessages: [Message] = [
        user("mj_1", "b_juna", demoText("Juna, plan bitte unser Teamwochenende in Köln. Arman ist auch dabei.", en: "Juna, please plan our team weekend in Chicago. Arman is coming too."), 95),
        Message(id: "mj_2", botId: "b_juna", role: .bot,
                text: demoText("Gern, Sophie! Ich schlage den **28.–30. November** vor. Arman, passt dir das?", en: "Happy to, Sophie! How about **November 28–30**? Arman, does that work for you?"), createdAt: ago(94)),
        user("mj_3", "b_juna", demoText("Passt mir gut. Bitte etwas mit Blick auf den Rhein 🙂", en: "Works for me. Something with a view of the lake, please 🙂"), 60, author: (me.id, me.name ?? "Arman")),
        Message(id: "mj_4", botId: "b_juna", role: .status, text: "", createdAt: ago(59),
                meta: MessageMeta(runId: "r_j1", state: "done", lines: [demoText("Öffnet den Browser", en: "Opens the browser"), demoText("Vergleicht Hotels", en: "Compares hotels")],
                                  usesComputer: true, model: "claude-sonnet-5-5", costUsd: 0.021,
                                  startedAt: ago(59), finishedAt: ago(57))),
        Message(id: "mj_5", botId: "b_juna", role: .bot,
                text: demoText("Ich hab zwei Hotels mit Rheinblick gefunden:\n\n- **Hotel Rheinblick**, 128 € pro Nacht\n- **Deutzer Hof**, 119 € mit Frühstück\n\nSoll ich beim Rheinblick anfragen?",
                              en: "I found two hotels with a lake view:\n\n- **The Lakeview**, $219 per night\n- **River North Inn**, $199 with breakfast\n\nShould I reach out to The Lakeview?"),
                createdAt: ago(56)),
        user("mj_6", "b_juna", demoText("Ja, frag beim Rheinblick für 6 Personen an.", en: "Yes, ask The Lakeview about rooms for six."), 12, author: (me.id, me.name ?? "Arman")),
        Message(id: "mj_7", botId: "b_juna", role: .approval,
                text: demoText("Mail an Hotel Rheinblick senden", en: "Send email to The Lakeview"), createdAt: ago(11),
                meta: MessageMeta(approvalId: "ap_juna", title: demoText("Mail an Hotel Rheinblick senden", en: "Send email to The Lakeview"),
                                  details: demoText("Anfrage für 6 Personen, 28.–30. November, Zimmer mit Rheinblick.",
                                                    en: "Request for 6 guests, November 28–30, lake-view rooms."))),
    ]

    static let kikoMessages: [Message] = [
        Message(id: "mk_1", botId: "b_kiko", role: .bot,
                text: demoText("Hallo! Ich plane Sophies Reisen. Du kannst hier mitlesen.", en: "Hi! I plan Sophie’s trips. You can follow along here."), createdAt: ago(30)),
    ]

    static let junaMemories: [Memory] = [
        Memory(id: "mem_j1", botId: "b_juna", kind: "fact", text: demoText("Team mag Rheinblick und kurze Wege.", en: "The team loves lake views and everything within walking distance."), createdAt: ago(60)),
    ]

    /// Mila (eigener Scoop) ist mit Lena geteilt: Lena schreibt mit.
    static let milaGuestMessages: [Message] = [
        user("mm_g1", "b_mila", demoText("Hi Mila, kannst du mir die Agenda für Donnerstag schicken?", en: "Hi Mila, can you send me the agenda for Thursday?"), 8, author: ("u_lena", "Lena Berger")),
        Message(id: "mm_g2", botId: "b_mila", role: .bot,
                text: demoText("Klar, Lena! Donnerstag: **9:00** Standup, **11:00** Kundentermin, **15:00** Review.", en: "Sure, Lena! Thursday: **9:00 AM** standup, **11:00 AM** client meeting, **3:00 PM** review."),
                createdAt: ago(7)),
    ]

    static func usage(botID: String, guest: Bool) -> BotUsage {
        if guest {
            // Gast sieht nur sich selbst und sein Tageslimit
            return BotUsage(todayUsd: 0.34, monthUsd: 2.10, guestBudget: 2,
                            byPerson: [.init(userId: me.id, name: me.name ?? demoText("Du", en: "You"), isOwner: false, role: .write,
                                             todayUsd: 0.34, monthUsd: 2.10, budgetLeftUsd: 1.66)])
        }
        guard botID == "b_mila" else {
            let base = Double(botID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 300) / 100
            return BotUsage(todayUsd: base / 8, monthUsd: base, byPerson: [])
        }
        return BotUsage(todayUsd: 0.46, monthUsd: 7.85, totalUsd: 21.30, guestBudget: 2, byPerson: [
            .init(userId: nil, name: me.name ?? demoText("Du", en: "You"), isOwner: true, todayUsd: 0.21, monthUsd: 5.12),
            .init(userId: "u_lena", name: "Lena Berger", isOwner: false, role: .write, todayUsd: 0.25, monthUsd: 2.48,
                  budgetLeftUsd: 1.75),
            .init(userId: "u_jonas", name: "Jonas Weber", isOwner: false, role: .read, todayUsd: 0, monthUsd: 0.25,
                  budgetLeftUsd: 2),
        ])
    }
}
