import Foundation

/// Demo-Inhalte für geteilte Scoops: Junas Chat bei Sophie (ich bin Gast mit „Schreiben“ und „Zusehen“) und
/// Nachrichten von Lena in Milas Chat (ich bin Admin).
enum MockGuestData {
    private static func ago(_ minutes: Double) -> Date { PreviewData.now.addingTimeInterval(-minutes * 60) }
    private static let me = MockCloudService.demoUser

    static let juna = Bot(id: "b_juna", name: "Juna", label: "Teamevents", mascot: MockSharing.junaMascot,
                          character: "Herzlich, organisiert, denkt an alle.",
                          createdAt: ago(60 * 24 * 20), busy: false)
    static let kiko = Bot(id: "b_kiko", name: "Kiko", label: "Reiseplanung", mascot: MockSharing.kiko.botMascot ?? .default,
                          createdAt: ago(60 * 24 * 4))

    private static func user(_ id: String, _ chat: String, _ text: String, _ minutes: Double,
                             author: (String, String)? = nil) -> Message {
        var meta = MessageMeta()
        meta.authorUserId = author?.0
        meta.authorName = author?.1
        return Message(id: id, botId: chat, role: .user, text: text, createdAt: ago(minutes), meta: meta)
    }

    static let junaMessages: [Message] = [
        user("mj_1", "b_juna", "Juna, plan bitte unser Teamwochenende in Köln. Arman ist auch dabei.", 95),
        Message(id: "mj_2", botId: "b_juna", role: .bot,
                text: "Gern, Sophie! Ich schlage den **28.–30. November** vor. Arman, passt dir das?", createdAt: ago(94)),
        user("mj_3", "b_juna", "Passt mir gut. Bitte etwas mit Blick auf den Rhein 🙂", 60, author: (me.id, me.name ?? "Arman")),
        Message(id: "mj_4", botId: "b_juna", role: .status, text: "", createdAt: ago(59),
                meta: MessageMeta(runId: "r_j1", state: "done", lines: ["Öffnet den Browser", "Vergleicht Hotels"],
                                  usesComputer: true, model: "claude-sonnet-5-5", costUsd: 0.021,
                                  startedAt: ago(59), finishedAt: ago(57))),
        Message(id: "mj_5", botId: "b_juna", role: .bot,
                text: "Ich hab zwei Hotels mit Rheinblick gefunden:\n\n- **Hotel Rheinblick**, 128 € pro Nacht\n- **Deutzer Hof**, 119 € mit Frühstück\n\nSoll ich beim Rheinblick anfragen?",
                createdAt: ago(56)),
        user("mj_6", "b_juna", "Ja, frag beim Rheinblick für 6 Personen an.", 12, author: (me.id, me.name ?? "Arman")),
        Message(id: "mj_7", botId: "b_juna", role: .approval, text: "Mail an Hotel Rheinblick senden", createdAt: ago(11),
                meta: MessageMeta(approvalId: "ap_juna", title: "Mail an Hotel Rheinblick senden",
                                  details: "Anfrage für 6 Personen, 28.–30. November, Zimmer mit Rheinblick.")),
    ]

    static let kikoMessages: [Message] = [
        Message(id: "mk_1", botId: "b_kiko", role: .bot,
                text: "Hallo! Ich plane Sophies Reisen. Du kannst hier mitlesen.", createdAt: ago(30)),
    ]

    static let junaMemories: [Memory] = [
        Memory(id: "mem_j1", botId: "b_juna", kind: "fact", text: "Team mag Rheinblick und kurze Wege.", createdAt: ago(60)),
    ]

    /// Mila (eigener Scoop) ist mit Lena geteilt: Lena schreibt mit.
    static let milaGuestMessages: [Message] = [
        user("mm_g1", "b_mila", "Hi Mila, kannst du mir die Agenda für Donnerstag schicken?", 8, author: ("u_lena", "Lena Berger")),
        Message(id: "mm_g2", botId: "b_mila", role: .bot,
                text: "Klar, Lena! Donnerstag: **9:00** Standup, **11:00** Kundentermin, **15:00** Review.",
                createdAt: ago(7)),
    ]

    static func usage(botID: String, guest: Bool) -> BotUsage {
        if guest {
            // Gast sieht nur sich selbst und sein Tageslimit
            return BotUsage(todayUsd: 0.34, monthUsd: 2.10, guestBudget: 2,
                            byPerson: [.init(userId: me.id, name: me.name ?? "Du", isOwner: false, role: .write,
                                             todayUsd: 0.34, monthUsd: 2.10, budgetLeftUsd: 1.66)])
        }
        guard botID == "b_mila" else {
            let base = Double(botID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 300) / 100
            return BotUsage(todayUsd: base / 8, monthUsd: base, byPerson: [])
        }
        return BotUsage(todayUsd: 0.46, monthUsd: 7.85, totalUsd: 21.30, guestBudget: 2, byPerson: [
            .init(userId: nil, name: me.name ?? "Du", isOwner: true, todayUsd: 0.21, monthUsd: 5.12),
            .init(userId: "u_lena", name: "Lena Berger", isOwner: false, role: .write, todayUsd: 0.25, monthUsd: 2.48,
                  budgetLeftUsd: 1.75),
            .init(userId: "u_jonas", name: "Jonas Weber", isOwner: false, role: .read, todayUsd: 0, monthUsd: 0.25,
                  budgetLeftUsd: 2),
        ])
    }
}
