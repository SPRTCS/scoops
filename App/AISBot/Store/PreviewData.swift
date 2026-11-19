import Foundation

/// Beispieldaten für Demo-Modus (`-mock` oder Server-Adresse `mock://`), Vorschauen und Screenshots.
enum PreviewData {
    /// Demo-Uhr. Store-Aufnahmen (`-storeshots`): heute 09:41, passend zur Statusleiste – sonst die aktuelle Zeit.
    static let now: Date = {
        guard ProcessInfo.processInfo.arguments.contains("-storeshots") else { return Date() }
        return Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
    }()

    /// Laufende Uhr für Demo-Ansichten: bei Store-Aufnahmen die feste Demo-Uhr, sonst die aktuelle Zeit.
    static var clock: Date { ProcessInfo.processInfo.arguments.contains("-storeshots") ? now : Date() }

    static func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let mila = Bot(id: "b_mila", name: "Mila", label: "Assistenz",
                          mascot: Mascot(shape: "pill", color: "#8A2EDB", eyes: "focused", accessory: "glasses", gaze: "right"),
                          character: "Locker, präzise, duzt. Fragt nach, bevor sie etwas verschickt.",
                          model: "claude-haiku-5-5", escalationModel: "claude-sonnet-5-5",
                          pinned: true, section: "Arbeit", createdAt: ago(minutes: 60 * 24 * 12), busy: true,
                          primary: true)
    static let theo = Bot(id: "b_theo", name: "Theo", label: "Recherche",
                          mascot: Mascot(shape: "cloud", color: "#1270E8", eyes: "dashes", accessory: "none", mouth: "smile"),
                          character: "Gründlich, nennt immer Quellen, ein bisschen nerdig.",
                          model: "claude-sonnet-5-5", pinned: true, section: "Arbeit", createdAt: ago(minutes: 60 * 24 * 9))
    static let lio = Bot(id: "b_lio", name: "Lio", label: "Social Media",
                         mascot: Mascot(shape: "egg", color: "#FBBA10", eyes: "relaxed", accessory: "beret", gaze: "right"),
                         character: "Kreativ, verspielt, schreibt knackige Posts.",
                         model: "claude-haiku-5-5", pinned: false, section: "Arbeit", createdAt: ago(minutes: 60 * 24 * 7), unread: 2)
    static let nora = Bot(id: "b_nora", name: "Nora", label: "Finanzen",
                          // Demo für „Eigenes Bild“ (v1.12): erzeugtes Testbild aus MockService.demoPhotoData()
                          mascot: Mascot(shape: "star_soft", color: "#43C62E", eyes: "dashes", accessory: "cap",
                                         photo: MascotPhoto(id: "b_nora", version: 1), mouth: "smile"),
                          character: "Ruhig, genau, erklärt Zahlen in einfachen Worten.",
                          model: "gpt-6.2-sol", pinned: false, section: "Privat", createdAt: ago(minutes: 60 * 24 * 5), unread: 1)
    static let pip = Bot(id: "b_pip", name: "Pip", label: "Erinnerungen",
                         mascot: Mascot(shape: "heart", color: "#F72A7A", eyes: "lashes", accessory: "none", gaze: "left", mouth: "smile"),
                         character: "Freundlich, kurz angebunden, vergisst nie etwas.",
                         model: "claude-haiku-5-5", pinned: false, section: nil, createdAt: ago(minutes: 60 * 24 * 3))

    static var bots: [Bot] {
        [mila, theo, lio, nora, pip].map { b in
            var b = b
            b.lastMessage = messages[b.id]?.last
            // Demo: offene Freigabe → rotes „?“
            b.waiting = (b.lastMessage?.role == .approval && b.lastMessage?.meta.state == "pending") || b.id == "b_lio"
            // Rechner-Zugriff (v1.29): Standard, ein Scoop mit Projektordnern
            var access = b.id == "b_theo"
                ? ScoopAccess(mode: "auto", scope: "projects", folders: ["~/Desktop/Projekte/Website", "~/Code/AIS Bot"])
                : ScoopAccess()
            access.modeLabel = access.accessMode.title
            access.scopeLabel = access.accessScope.title
            b.computerAccess = access
            return b
        }
    }

    /// Meta mit zusätzlichen v1.9-Feldern (Mail, Reaktionen, Scoop-Nachrichten).
    static func meta(_ base: MessageMeta = MessageMeta(), _ edit: (inout MessageMeta) -> Void) -> MessageMeta {
        var m = base
        edit(&m)
        return m
    }

    static let messages: [String: [Message]] = [
        "b_mila": [
            Message(id: "m_1", botId: "b_mila", role: .event, text: "Routine angelegt: Morgenbriefing",
                    createdAt: ago(minutes: 60 * 26), meta: MessageMeta(icon: "clock")),
            Message(id: "m_2", botId: "b_mila", role: .bot,
                    text: "Alles klar! Ab morgen bekommst du werktags um **7:30** dein Briefing: Termine, wichtige Mails und das Wetter in Köln.",
                    createdAt: ago(minutes: 60 * 26 - 1)),
            Message(id: "m_3", botId: "b_mila", role: .event, text: "Routine ausgelöst: Morgenbriefing",
                    createdAt: ago(minutes: 60 * 3), meta: MessageMeta(icon: "sunrise")),
            Message(id: "m_4", botId: "b_mila", role: .bot, text: """
            Guten Morgen Arman! Das steht heute an:

            - **09:00** Call mit Jonas (Agenda fehlt noch)
            - **11:30** Kundentermin in Köln-Deutz
            - **16:00** Zahnarzt, Dr. Weber

            Drei Mails sind wichtig, die Details liegen [in deinem Postfach](https://mail.google.com). Soll ich Jonas schon mal die Agenda schicken?
            """, createdAt: ago(minutes: 60 * 3 - 1), meta: meta { $0.reactions = ["user": "❤️"] }),
            Message(id: "m_5", botId: "b_mila", role: .user, text: "Ja, gern. Kurz und knackig bitte",
                    createdAt: ago(minutes: 60 * 3 - 8), meta: meta {
                        $0.reactions = ["b_mila": "👍"]
                        // v1.15: Antwort auf eine bestimmte Nachricht
                        $0.replyTo = ReplyRef(id: "m_4", role: "bot", authorId: "b_mila", authorName: "Mila",
                                              text: "Guten Morgen Arman! Das steht heute an: 09:00 Call mit Jonas (Agenda fehlt noch) 11:30 Kundentermin in Köln-Deutz …")
                    }),
            Message(id: "m_6", botId: "b_mila", role: .status, text: "",
                    createdAt: ago(minutes: 60 * 3 - 8.2),
                    meta: MessageMeta(runId: "r_1", state: "done", lines: ["Liest die Mail von Jonas", "Schaut in deinen Kalender", "Schreibt einen Entwurf"],
                                      usesComputer: false, model: "claude-haiku-5-5", costUsd: 0.0021,
                                      startedAt: ago(minutes: 60 * 3 - 8.2), finishedAt: ago(minutes: 60 * 3 - 8.4))),
            Message(id: "m_7", botId: "b_mila", role: .approval, text: "Mail an Jonas senden",
                    createdAt: ago(minutes: 60 * 3 - 8.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_1", title: "Mail an Jonas senden",
                                           details: "Betreff: Agenda für heute, 9 Uhr\n\nHi Jonas,\nfür unseren Call: 1. Stand Kampagne, 2. Budget Q1, 3. nächste Schritte.\n\nBis gleich!\nArman",
                                           kind: "mail")) {
                        $0.canAlways = true
                        $0.alwaysLabel = "Mails an jonas@kunde-demo.example (Konto arbeit)"
                        $0.mail = MailDraft(account: "arbeit", accountEmail: "arman@ais-demo.example", to: ["jonas@kunde-demo.example"],
                                            subject: "Agenda für heute, 9 Uhr",
                                            body: "Hi Jonas,\n\nfür unseren Call um 9 Uhr schlage ich vor:\n\n1. Stand der Kampagne\n2. Budget Q1\n3. Nächste Schritte und Termine\n\nWenn dir noch etwas fehlt, schreib es gern kurz dazu. Die Unterlagen vom letzten Mal hänge ich nachher noch an.\n\nBis gleich!\nArman")
                    }),
            Message(id: "m_7b", botId: "b_mila", role: .event, text: "Fähigkeit gespeichert: Agenda für Calls",
                    createdAt: ago(minutes: 60 * 3 - 8.6), meta: MessageMeta(icon: "wand.and.stars")),
            Message(id: "m_7c", botId: "b_mila", role: .event, text: "An Theo: Bahnverbindungen Köln für Donnerstag raussuchen",
                    createdAt: ago(minutes: 12),
                    meta: meta(MessageMeta(icon: "arrow.turn.up.right", authorId: "b_mila")) { $0.peerOut = true; $0.targetId = "b_theo" }),
            Message(id: "m_7d", botId: "b_mila", role: .bot,
                    text: "Hier sind die Verbindungen für Donnerstag: **ICE 1023** ab 7:12, an Köln Hbf 8:58. Zurück ginge der **ICE 1028** um 18:05.",
                    createdAt: ago(minutes: 10),
                    meta: meta(MessageMeta(authorId: "b_theo")) { $0.peer = true; $0.silent = true }),
            // v1.21: Aufsicht – Mila (Haupt-Scoop) schlägt eine Verbesserung für Theo vor
            Message(id: "m_7e", botId: "b_mila", role: .approval, text: "",
                    createdAt: ago(minutes: 9.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_su1",
                                           title: "Verbesserung für Theo: Neue Fähigkeit „Bahnverbindungen“",
                                           details: "Scoop: Theo (Recherche)\n\nÄnderung: Neue Fähigkeit „Bahnverbindungen“",
                                           kind: "scoop_update")) {
                        $0.scoopUpdate = ScoopUpdate(
                            targetId: "b_theo", targetName: "Theo", targetLabel: "Recherche", art: "faehigkeit",
                            label: "Neue Fähigkeit „Bahnverbindungen“",
                            reason: "Am 12.11. und 14.11. hat Arman zweimal nachgefragt („nein, ab Köln Hbf, nicht Deutz“). Theo hat den Abfahrtsbahnhof nicht geprüft.",
                            after: "1. Abfahrts- und Zielbahnhof genau übernehmen (Köln Hbf ≠ Köln Messe/Deutz).\n2. Verbindungen über die DB-Suche abrufen, höchstens 3 zeigen.\n3. Zu jeder Verbindung Umstiege und Preis nennen.")
                    }),
            Message(id: "m_8", botId: "b_mila", role: .user,
                    text: "Kannst du mir ein Hotel in Köln für nächsten Donnerstag suchen? Max. 140 € und nah am Bahnhof.",
                    createdAt: ago(minutes: 2), meta: meta {
                        $0.reactions = ["b_mila": "👍"]
                        $0.replyTo = ReplyRef(id: "m_7d", role: "bot", authorId: "b_theo", authorName: "Theo",
                                              text: "Hier sind die Verbindungen für Donnerstag: ICE 1023 ab 7:12, an Köln Hbf 8:58. Zurück ginge der ICE 1028 um 18:05.")
                    }),
            Message(id: "m_9", botId: "b_mila", role: .status, text: "",
                    createdAt: ago(minutes: 1.9),
                    meta: MessageMeta(runId: "r_2", state: "running",
                                      lines: ["Öffnet den Browser", "Ist im Browser auf booking.com", "Vergleicht 12 Hotels in Köln-Deutz"],
                                      usesComputer: true, model: "claude-haiku-5-5", startedAt: ago(minutes: 1.9))),
        ],
        "b_theo": [
            Message(id: "t_1", botId: "b_theo", role: .user, text: "Was ist neu in Swift 6.4? Kurz bitte.",
                    createdAt: ago(minutes: 60 * 5)),
            Message(id: "t_2", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 60 * 5 - 0.1),
                    meta: MessageMeta(runId: "r_t", state: "done", lines: ["Sucht im Netz", "Liest swift.org", "Fasst zusammen"],
                                      usesComputer: false, model: "claude-sonnet-5-5", costUsd: 0.012,
                                      startedAt: ago(minutes: 60 * 5 - 0.1), finishedAt: ago(minutes: 60 * 5 - 0.5))),
            Message(id: "t_3", botId: "b_theo", role: .bot, text: """
            Die drei wichtigsten Punkte:

            1. **Schnellere Builds** durch inkrementelles Makro-Caching
            2. **Bessere Fehlermeldungen** bei Concurrency
            3. Neue `Observation`-Helfer für Sammlungen

            Quelle: [swift.org/blog](https://swift.org/blog)
            """, createdAt: ago(minutes: 60 * 5 - 0.6)),
            Message(id: "t_4", botId: "b_theo", role: .user,
                    text: "Kannst du T3 bitten, im AIS-Scoops-Server die Fehlermeldung beim Login verständlicher zu machen?",
                    createdAt: ago(minutes: 270)),
            Message(id: "t_5", botId: "b_theo", role: .approval, text: "Auftrag an T3 Code",
                    createdAt: ago(minutes: 269.6),
                    meta: MessageMeta(state: "approved", approvalId: "a_t3a", title: "Auftrag an T3: Login-Fehlermeldung verbessern",
                                      details: "Projekt: AIS Scoops/Server\nAuftrag: Bei falschem Token eine klare deutsche Fehlermeldung zurückgeben und einen Test dafür ergänzen.",
                                      kind: "t3")),
            Message(id: "t_6", botId: "b_theo", role: .event, text: "T3 arbeitet: Login-Fehlermeldung verbessern",
                    createdAt: ago(minutes: 269.2),
                    meta: MessageMeta(icon: "hammer", url: "https://app.t3.codes/threads/demo-login")),
            Message(id: "t_7", botId: "b_theo", role: .event, text: "T3 fertig: Login-Fehlermeldung verbessern",
                    createdAt: ago(minutes: 261),
                    meta: MessageMeta(icon: "hammer", url: "https://app.t3.codes/threads/demo-login")),
            Message(id: "t_8", botId: "b_theo", role: .bot,
                    text: "T3 ist fertig: Die Fehlermeldung lautet jetzt „Der Token passt nicht“, inklusive Test. Soll T3 das auch für abgelaufene Tokens machen?",
                    createdAt: ago(minutes: 260.8)),
            // Build 12: mehrere Läufe am Bot-Rechner (fertig, abgebrochen, angehalten, veraltet „running“, aktuell)
            Message(id: "t_r1", botId: "b_theo", role: .user,
                    text: "Schau bitte im Browser nach Swift-Konferenzen im Frühjahr, am liebsten in Europa.",
                    createdAt: ago(minutes: 55)),
            Message(id: "t_r2", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 54.9),
                    meta: MessageMeta(runId: "r_tc1", state: "done",
                                      lines: ["Öffnet den Browser", "Sucht nach „Swift Konferenz 2027“", "Ist im Browser auf swift.org/events",
                                              "Liest die Konferenzliste", "Öffnet 3 Konferenzseiten", "Vergleicht Termine und Preise",
                                              "Fasst zusammen"],
                                      usesComputer: true, model: "claude-sonnet-5-5", costUsd: 0.018,
                                      startedAt: ago(minutes: 54.9),
                                      finishedAt: ago(minutes: 54.9).addingTimeInterval(37))),
            Message(id: "t_r3", botId: "b_theo", role: .bot, text: """
            Drei passen gut:

            1. **Swift Spring Summit**, Amsterdam, 12.–13. März
            2. **iOS Dev Days**, Köln, 9. April
            3. **SwiftConf Nord**, Kopenhagen, 21. Mai
            """, createdAt: ago(minutes: 54.2)),
            Message(id: "t_r4", botId: "b_theo", role: .user, text: "Super, prüf bitte noch die Hotelpreise in Köln für den 9. April.",
                    createdAt: ago(minutes: 45)),
            Message(id: "t_r5", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 44.9),
                    meta: meta(MessageMeta(runId: "r_tc2", state: "stopped",
                                           lines: ["Öffnet den Browser", "Ist im Browser auf hotels.example"],
                                           usesComputer: true, model: "claude-sonnet-5-5",
                                           startedAt: ago(minutes: 44.9), finishedAt: ago(minutes: 44.5))) {
                        $0.interrupted = true
                    }),
            Message(id: "t_r6", botId: "b_theo", role: .event, text: "Server neu gestartet, Lauf abgebrochen",
                    createdAt: ago(minutes: 44.45), meta: MessageMeta(icon: "arrow.clockwise")),
            Message(id: "t_r7", botId: "b_theo", role: .user, text: "Nochmal bitte, gleiche Suche.", createdAt: ago(minutes: 38)),
            Message(id: "t_r8", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 37.9),
                    meta: MessageMeta(runId: "r_tc3", state: "stopped",
                                      lines: ["Öffnet den Browser", "Ist im Browser auf hotels.example", "Filtert nach Preis"],
                                      usesComputer: true, model: "claude-sonnet-5-5",
                                      startedAt: ago(minutes: 37.9), finishedAt: ago(minutes: 37.8))),
            Message(id: "t_r9", botId: "b_theo", role: .user, text: "Stopp, das reicht erst mal. Schau später noch mal.",
                    createdAt: ago(minutes: 37.6)),
            // Verpasstes Update: steht noch auf „running“, obwohl danach ein neuer Lauf begann → „Beendet“, ohne Live-Bild
            Message(id: "t_r10", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 30),
                    meta: MessageMeta(runId: "r_tc4", state: "running",
                                      lines: ["Öffnet den Browser", "Ist im Browser auf bahn.example"],
                                      usesComputer: true, model: "claude-sonnet-5-5", startedAt: ago(minutes: 30))),
            Message(id: "t_8b", botId: "b_theo", role: .bot,
                    text: "Theo, kannst du für Arman die Bahnverbindungen nach Köln am Donnerstag raussuchen? Ankunft vor 9 Uhr.",
                    createdAt: ago(minutes: 12),
                    meta: meta(MessageMeta(authorId: "b_mila")) { $0.peer = true; $0.silent = true }),
            Message(id: "t_8c", botId: "b_theo", role: .bot,
                    text: "Erledigt, ICE 1023 ab 7:12 passt. Hab es Mila geschickt.",
                    createdAt: ago(minutes: 10), meta: meta { $0.silent = true }),
            Message(id: "t_9", botId: "b_theo", role: .approval, text: "Nachricht an T3 Code",
                    createdAt: ago(minutes: 2),
                    meta: MessageMeta(state: "pending", approvalId: "a_t3b", title: "Nachricht an T3: auch abgelaufene Tokens",
                                      details: "Thread: Login-Fehlermeldung verbessern\nNachricht: Bitte dieselbe klare Meldung auch bei abgelaufenen Tokens zurückgeben.",
                                      kind: "t3")),
            Message(id: "t_10", botId: "b_theo", role: .user, text: "Und schau jetzt bitte noch einmal nach den Hotels in Köln.",
                    createdAt: ago(minutes: 1)),
            // Aktueller Lauf: nur diese Karte zeigt das Live-Bild
            Message(id: "t_11", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 0.9),
                    meta: MessageMeta(runId: "r_tc5", state: "running",
                                      lines: ["Öffnet den Browser", "Ist im Browser auf hotels.example", "Vergleicht 9 Hotels in Köln-Deutz"],
                                      usesComputer: true, model: "claude-sonnet-5-5", startedAt: ago(minutes: 0.9))),
        ],
        "b_lio": [
            // Build 12 (API v1.10): Tresor-Formular – gespeichert, abgelehnt, offen
            Message(id: "l_v1", botId: "b_lio", role: .user,
                    text: "Melde dich bitte im Social-Media-Planer an und plane die Launch-Posts ein.",
                    createdAt: ago(minutes: 60 * 6)),
            Message(id: "l_v2", botId: "b_lio", role: .approval, text: "Login für Social-Media-Planer",
                    createdAt: ago(minutes: 60 * 6 - 0.5),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_v1", title: "Social-Media-Planer", kind: "vault")) {
                        $0.vault = VaultForm(title: "Social-Media-Planer", url: "https://planer.example.com/login",
                                             domain: "planer.example.com", username: "arman@ais-demo.example",
                                             status: "saved", vaultId: "v_demo3")
                    }),
            Message(id: "l_v3", botId: "b_lio", role: .event, text: "Login gespeichert: Social-Media-Planer",
                    createdAt: ago(minutes: 60 * 6 - 1.5), meta: MessageMeta(icon: "key.fill")),
            Message(id: "l_v4", botId: "b_lio", role: .bot, text: "Bin drin! Die drei Posts sind für Freitag 9, 12 und 17 Uhr eingeplant.",
                    createdAt: ago(minutes: 60 * 6 - 3)),
            Message(id: "l_v5", botId: "b_lio", role: .approval, text: "Login für Bildarchiv",
                    createdAt: ago(minutes: 60 * 4),
                    meta: meta(MessageMeta(state: "declined", approvalId: "a_v2", title: "Bildarchiv", kind: "vault")) {
                        $0.vault = VaultForm(title: "Bildarchiv", url: "https://bilder.example.com/anmelden",
                                             domain: "bilder.example.com", username: "", status: "declined")
                    }),
            Message(id: "l_1", botId: "b_lio", role: .bot, text: "Ich hab zwei Entwürfe für deinen X-Post zum App-Launch. Welcher gefällt dir?",
                    createdAt: ago(minutes: 45)),
            Message(id: "l_2", botId: "b_lio", role: .approval, text: "Post auf X veröffentlichen",
                    createdAt: ago(minutes: 44),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_2", title: "Post auf X veröffentlichen",
                                           details: "Unsere neue App ist da! Bots mit Charakter, die für dich arbeiten. Probiert sie aus und sagt uns, was ihr denkt.")) {
                        $0.canAlways = true
                        $0.alwaysLabel = "Wochenpost auf X veröffentlichen"
                    }),
            Message(id: "l_2b", botId: "b_lio", role: .event, text: "Automatisch freigegeben: Story auf Instagram teilen",
                    createdAt: ago(minutes: 43.5), meta: meta(MessageMeta(icon: "checkmark.seal")) { $0.autoApproved = true }),
            Message(id: "l_v6", botId: "b_lio", role: .user, text: "Kannst du die Posts auch im Newsletter-Tool ankündigen?",
                    createdAt: ago(minutes: 8)),
            Message(id: "l_v7", botId: "b_lio", role: .bot,
                    text: "Klar! Dafür brauche ich einen Login. Trag ihn bitte unten ein, das Passwort sehe ich nicht.",
                    createdAt: ago(minutes: 7.6)),
            Message(id: "l_v8", botId: "b_lio", role: .approval, text: "Login für Newsletter-Tool",
                    createdAt: ago(minutes: 7.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_v3", title: "Newsletter-Tool", kind: "vault")) {
                        $0.vault = VaultForm(title: "Newsletter-Tool", url: "https://newsletter.example.com/anmelden",
                                             domain: "newsletter.example.com", username: "arman@ais-demo.example")
                    }),
        ],
        "b_nora": [
            Message(id: "n_1", botId: "b_nora", role: .event, text: "Routine ausgelöst: Monatsabschluss",
                    createdAt: ago(minutes: 60 * 20), meta: MessageMeta(icon: "chart.bar")),
            Message(id: "n_2", botId: "b_nora", role: .bot,
                    text: "Dein Oktober ist durch: **1.240 €** Ausgaben, davon 310 € für Software-Abos. Zwei Abos hast du seit Monaten nicht genutzt. Soll ich bei einem Anbieter anrufen und kündigen?",
                    createdAt: ago(minutes: 60 * 20 - 1)),
            Message(id: "n_3", botId: "b_nora", role: .user, text: "Ja, ruf bei der Testfirma an.", createdAt: ago(minutes: 30)),
            Message(id: "n_4", botId: "b_nora", role: .approval, text: "Anruf: Testfirma",
                    createdAt: ago(minutes: 29.5),
                    meta: MessageMeta(state: "approved", approvalId: "a_call1", title: "Anruf: Testfirma (+49 30 1234567)",
                                      details: "Nummer: +49 30 1234567\nKontext: Abo „Cloud Plus“, Kundennummer 4711\nZiel: Kündigung zum Monatsende bestätigen lassen",
                                      kind: "call")),
            Message(id: "n_5", botId: "b_nora", role: .event, text: "Lucy ruft an: Testfirma",
                    createdAt: ago(minutes: 29), meta: MessageMeta(icon: "phone.connection")),
            Message(id: "n_6", botId: "b_nora", role: .event, text: "Anruf beendet: Testfirma (2 min)",
                    createdAt: ago(minutes: 27), meta: MessageMeta(icon: "phone.down")),
            Message(id: "n_7", botId: "b_nora", role: .bot, text: "Erledigt: Die Kündigung ist bestätigt, das Abo endet zum 30. November.",
                    createdAt: ago(minutes: 26.8)),
            Message(id: "n_m1", botId: "b_nora", role: .approval, text: "Mail an Steuerbüro",
                    createdAt: ago(minutes: 25),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_m1", title: "Mail an Steuerbüro", kind: "mail")) {
                        $0.mail = MailDraft(account: "privat", accountEmail: "arman.privat@example.com", to: ["kanzlei@steuer-demo.example"],
                                            subject: "Belege Oktober", body: "Hallo Frau Brandt,\n\nanbei die Belege für Oktober.\n\nViele Grüße\nArman Samary",
                                            status: "sent", sentAt: ago(minutes: 24))
                    }),
            Message(id: "n_m2", botId: "b_nora", role: .approval, text: "Mail an Musterdienst",
                    createdAt: ago(minutes: 20),
                    meta: meta(MessageMeta(state: "declined", approvalId: "a_m2", title: "Mail an Musterdienst", kind: "mail")) {
                        $0.mail = MailDraft(account: "privat", accountEmail: "arman.privat@example.com", to: ["kuendigung@musterdienst.example"],
                                            subject: "Kündigung Streaming Max", body: "Sehr geehrte Damen und Herren,\n\nhiermit kündige ich mein Abo.",
                                            status: "discarded")
                    }),
            Message(id: "n_m3", botId: "b_nora", role: .approval, text: "Mail an Buchhaltung",
                    createdAt: ago(minutes: 15),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_m3", title: "Mail an Buchhaltung", kind: "mail")) {
                        $0.mail = MailDraft(account: "arbeit", accountEmail: "arman@ais-demo.example", to: ["buchhaltung@fehler.example"],
                                            subject: "Rechnung 2026-114", body: "Hallo,\n\ndie Rechnung 2026-114 ist bezahlt.\n\nGruß\nArman",
                                            status: "failed", error: "Gmail hat die Adresse abgelehnt (550 Empfänger unbekannt).")
                    }),
            Message(id: "n_m4", botId: "b_nora", role: .approval, text: "Antwort an Frau Brandt",
                    createdAt: ago(minutes: 8),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_m4", title: "Antwort an Frau Brandt", kind: "mail")) {
                        $0.mail = MailDraft(account: "privat", accountEmail: "arman.privat@example.com", to: ["kanzlei@steuer-demo.example"],
                                            cc: ["nora.assistenz@example.com"],
                                            subject: "Re: Belege Oktober", body: "Hallo Frau Brandt,\n\ndanke für die schnelle Rückmeldung. Die fehlende Tankquittung reiche ich bis Freitag nach.\n\nViele Grüße\nArman Samary",
                                            threadId: "thread_demo")
                    }),
            // Server 1.35: eigene MCP-Server im Chat verbinden (Qonto mit OAuth, Kassenbuch mit Token über die sichere Karte)
            Message(id: "n_q1", botId: "b_nora", role: .user, text: "Verbinde bitte den Qonto-MCP.", createdAt: ago(minutes: 22)),
            Message(id: "n_q2", botId: "b_nora", role: .approval, text: "", createdAt: ago(minutes: 21.8),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_mcp1", title: "MCP-Server verbinden: Qonto",
                                           details: "Adresse: https://mcp.qonto.com/mcp\nAnmeldung: beim Anbieter (OAuth), danach Karte „Anmelden“\nSchreibende Werkzeuge des Servers laufen immer über Freigabe-Karten.",
                                           kind: "mcp_connect")) { $0.icon = "server.rack" }),
            Message(id: "n_q3", botId: "b_nora", role: .event, text: "Bei Qonto anmelden: in „Apps verbinden“ › Eigene MCP-Server",
                    createdAt: ago(minutes: 21.5),
                    meta: meta(MessageMeta(icon: "person.badge.key", kind: "mcp_login")) {
                        $0.mcpServerId = "mcp_qonto"; $0.mcpServerName = "Qonto"
                    }),
            Message(id: "n_q4", botId: "b_nora", role: .event, text: "Bei Qonto angemeldet · 37 Werkzeuge", createdAt: ago(minutes: 20),
                    meta: MessageMeta(icon: "checkmark.seal")),
            Message(id: "n_q5", botId: "b_nora", role: .bot,
                    text: "Qonto ist verbunden. Kontostand und Buchungen kann ich jetzt direkt lesen; Überweisungen und Karten laufen nur über deine Freigabe.",
                    createdAt: ago(minutes: 19.8)),
            Message(id: "n_q6", botId: "b_nora", role: .user, text: "Das Kassenbuch unter kasse.example.com auch, bitte.", createdAt: ago(minutes: 6)),
            Message(id: "n_q7", botId: "b_nora", role: .approval, text: "", createdAt: ago(minutes: 5.8),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_mcp2", title: "MCP-Server verbinden: Kassenbuch",
                                           details: "Adresse: https://kasse.example.com/mcp\nAnmeldung: Token (Header Authorization)\nSchreibende Werkzeuge des Servers laufen immer über Freigabe-Karten.",
                                           kind: "mcp_connect")) {
                        $0.icon = "server.rack"
                        $0.secretFields = [MessageMeta.SecretField(key: "token", label: "Token")]
                    }),
            Message(id: "n_8", botId: "b_nora", role: .user, text: "Super. Kannst du auch beim zweiten Anbieter anrufen?", createdAt: ago(minutes: 3),
                    meta: meta { $0.reactions = ["b_nora": "🙏", "user": "👍"] }),
            Message(id: "n_9", botId: "b_nora", role: .approval, text: "Anruf: Musterdienst",
                    createdAt: ago(minutes: 2.5),
                    meta: MessageMeta(state: "pending", approvalId: "a_call2", title: "Anruf: Musterdienst (+49 221 7654321)",
                                      details: "Nummer: +49 221 7654321\nKontext: Abo „Streaming Max“\nZiel: Kündigung zum nächstmöglichen Termin",
                                      kind: "call")),
        ],
        "b_pip": [
            Message(id: "p_1", botId: "b_pip", role: .event, text: "Erinnerung angelegt: Mülltonne rausstellen",
                    createdAt: ago(minutes: 60 * 30), meta: MessageMeta(icon: "bell")),
            Message(id: "p_2", botId: "b_pip", role: .bot, text: "Kurze Erinnerung: Morgen früh wird der Biomüll abgeholt.",
                    createdAt: ago(minutes: 60 * 8)),
        ],
    ]

    static let memories: [String: [Memory]] = [
        "b_mila": [
            Memory(id: "mem_1", botId: "b_mila", kind: "profil", text: "Mails nie ohne Freigabe senden", createdAt: ago(minutes: 60 * 24 * 10)),
            Memory(id: "mem_2", botId: "b_mila", kind: "profil", text: "Arman mag kurze, direkte Antworten", createdAt: ago(minutes: 60 * 24 * 9)),
            Memory(id: "mem_3", botId: "b_mila", kind: "fakt", text: "Jonas ist Armans Ansprechpartner für die Kampagne", createdAt: ago(minutes: 60 * 24 * 6)),
            Memory(id: "mem_4", botId: nil, kind: "fakt", text: "Arman wohnt in Köln", createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_5", botId: nil, kind: "fakt", text: "Zeitzone: Europe/Berlin", createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_6", botId: nil, kind: "fakt", text: "Firma: AIS Consulting", createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_7", botId: "b_mila", kind: "tagebuch", text: "Morgenbriefing geschickt, Agenda für Jonas entworfen", createdAt: ago(minutes: 60 * 3)),
            Memory(id: "mem_8", botId: "b_mila", kind: "tagebuch", text: "Hotelrecherche Berlin abgeschlossen (3 Vorschläge)", createdAt: ago(minutes: 60 * 26)),
        ],
    ]

    static let routines: [String: [Routine]] = [
        "b_mila": [
            Routine(id: "rt_1", botId: "b_mila", kind: "routine", title: "Morgenbriefing", schedule: "30 7 * * 1-5",
                    scheduleText: "Werktags um 7:30", prompt: "Termine, Mails, Wetter", enabled: true,
                    nextRun: now.addingTimeInterval(60 * 60 * 10), lastRun: ago(minutes: 60 * 3)),
            Routine(id: "rt_2", botId: "b_mila", kind: "routine", title: "Wochenrückblick", schedule: "0 18 * * 0",
                    scheduleText: "Sonntags um 18:00", prompt: "Was lief diese Woche?", enabled: true,
                    nextRun: now.addingTimeInterval(60 * 60 * 72), lastRun: nil, model: "claude-sonnet-5-5"),
            Routine(id: "rt_3", botId: "b_mila", kind: "erinnerung", title: "Steuerunterlagen an Verena", schedule: "0 9 15 11 *",
                    scheduleText: "Am 15. November um 9:00", prompt: nil, enabled: false,
                    nextRun: now.addingTimeInterval(60 * 60 * 24 * 4), lastRun: nil),
        ],
        "b_pip": [
            Routine(id: "rt_4", botId: "b_pip", kind: "erinnerung", title: "Mülltonne rausstellen", schedule: "0 20 * * 2",
                    scheduleText: "Dienstags um 20:00", prompt: nil, enabled: true, nextRun: nil, lastRun: nil),
        ],
    ]

    /// Dauerhafte Freigaben (v1.20, „Immer erlauben“)
    static let standingApprovals: [String: [StandingApproval]] = [
        "b_mila": [
            StandingApproval(id: "sa_1", botId: "b_mila", key: "freigabe:teamapp-checkouts-abhaken",
                             label: "Friday Checkouts in der Team App abhaken", kind: "freigabe", createdAt: ago(minutes: 60 * 24 * 9)),
            StandingApproval(id: "sa_2", botId: "b_mila", key: "mail:arman@ais-demo.example:verena@steuer-demo.example",
                             label: "Mails an verena@steuer-demo.example (Konto arbeit)", kind: "mail", createdAt: ago(minutes: 60 * 24 * 2)),
        ],
        "b_lio": [
            StandingApproval(id: "sa_3", botId: "b_lio", key: "freigabe:instagram-story-teilen",
                             label: "Story auf Instagram teilen", kind: "freigabe", createdAt: ago(minutes: 60 * 5)),
        ],
    ]

    // MARK: Gruppe (v1.1)

    static let team = ChatGroup(id: "g_team", name: "Launch-Team", memberIds: ["b_mila", "b_theo", "b_lio"],
                                pinned: true, createdAt: ago(minutes: 60 * 24 * 2))

    /// Zweite Gruppe (nicht angepinnt, „Ohne Bereich“) für die Zeilenansicht
    static let alle = ChatGroup(id: "g_alle", name: "Alle", memberIds: ["b_mila", "b_theo", "b_lio", "b_nora", "b_pip"],
                                createdAt: ago(minutes: 60 * 24 * 4))

    static var groups: [ChatGroup] {
        var g = team
        g.lastMessage = groupMessages.last
        var a = alle
        a.lastMessage = Message(id: "ga_1", botId: "g_alle", role: .bot, text: "Guten Morgen zusammen! Heute ist der Launch.",
                                createdAt: ago(minutes: 60 * 6), meta: MessageMeta(authorId: "b_lio"))
        return [g, a]
    }

    static let groupMessages: [Message] = [
        Message(id: "g_1", botId: "g_team", role: .event, text: "Gruppe erstellt: Mila, Theo und Lio",
                createdAt: ago(minutes: 60 * 26), meta: MessageMeta(icon: "person.3")),
        Message(id: "g_2", botId: "g_team", role: .user, text: "@alle Wir launchen am Freitag. Wer übernimmt was?",
                createdAt: ago(minutes: 42)),
        Message(id: "g_3", botId: "g_team", role: .bot,
                text: "Ich schreibe den **X-Post** und zwei Varianten für LinkedIn.",
                createdAt: ago(minutes: 41.5), meta: MessageMeta(authorId: "b_lio")),
        Message(id: "g_4", botId: "g_team", role: .bot,
                text: "Ich sammle Vergleichszahlen zu ähnlichen Apps und lege sie in die Bibliothek.",
                createdAt: ago(minutes: 41.2), meta: MessageMeta(authorId: "b_theo")),
        Message(id: "g_5", botId: "g_team", role: .event, text: "Mila → Theo: Bitte die Zahlen bis Donnerstag ins Briefing",
                createdAt: ago(minutes: 41)),
        Message(id: "g_6", botId: "g_team", role: .status, text: "", createdAt: ago(minutes: 40.8),
                meta: MessageMeta(runId: "r_g1", state: "done", lines: ["Sucht im Netz", "Liest 6 Artikel", "Schreibt eine Zusammenfassung"],
                                  usesComputer: false, model: "claude-sonnet-5-5", costUsd: 0.009,
                                  startedAt: ago(minutes: 40.8), finishedAt: ago(minutes: 39.9), authorId: "b_theo")),
        Message(id: "g_7", botId: "g_team", role: .event, text: "Theo hat eine Datei erstellt",
                createdAt: ago(minutes: 39.8), meta: MessageMeta(icon: "doc.text", fileId: "f_research")),
        Message(id: "g_8", botId: "g_team", role: .user, text: "Hier noch Logo und Briefing. @Mila kannst du die Agenda für Freitag bauen?",
                createdAt: ago(minutes: 12), meta: MessageMeta(fileIds: ["f_logo", "f_brief"])),
        Message(id: "g_9", botId: "g_team", role: .bot,
                text: "Klar! Agenda steht in 10 Minuten. Logo und Briefing liegen jetzt in der Bibliothek.",
                createdAt: ago(minutes: 11.6), meta: MessageMeta(authorId: "b_mila")),
        // Build 12: mehrere Erwähnungen (Hervorhebung in Maskottchenfarbe, Kontrast in Nacht und Hell)
        Message(id: "g_10", botId: "g_team", role: .user,
                text: "@Mila du baust die Agenda, @Theo liefert die Zahlen bis Donnerstag und @Lio die Posts. Passt das?",
                createdAt: ago(minutes: 6)),
        Message(id: "g_11", botId: "g_team", role: .bot,
                text: "Passt! @Theo, schick mir die Zahlen bis Donnerstagmittag, dann baue ich sie ein. @Lio, ich verlinke deine Posts in der Agenda.",
                createdAt: ago(minutes: 5.6), meta: MessageMeta(authorId: "b_mila")),
        // v1.15: Antwort auf eine Scoop-Nachricht (ohne @ antwortet der zitierte Scoop)
        Message(id: "g_12", botId: "g_team", role: .user, text: "Bitte auch eine kurze Variante für Threads.",
                createdAt: ago(minutes: 4),
                meta: meta { $0.replyTo = ReplyRef(id: "g_3", role: "bot", authorId: "b_lio", authorName: "Lio",
                                                   text: "Ich schreibe den X-Post und zwei Varianten für LinkedIn.") }),
        Message(id: "g_13", botId: "g_team", role: .bot,
                text: "Mach ich, kommt mit in den Entwurf.",
                createdAt: ago(minutes: 3.7),
                meta: meta(MessageMeta(authorId: "b_lio")) {
                    $0.replyTo = ReplyRef(id: "g_12", role: "user", authorName: "Arman",
                                          text: "Bitte auch eine kurze Variante für Threads.")
                }),
    ]

    // MARK: Bibliothek (v1.1)

    static let files: [String: [LibraryFile]] = [
        "g_team": [
            LibraryFile(id: "f_logo", chatId: "g_team", authorId: nil, kind: "bild", name: "Logo.png", mime: "image/png",
                        size: 182_311, url: nil, note: nil, createdAt: ago(minutes: 12), downloadUrl: "/api/files/f_logo"),
            LibraryFile(id: "f_brief", chatId: "g_team", authorId: nil, kind: "datei", name: "Briefing-Launch.pdf",
                        mime: "application/pdf", size: 482_133, url: nil, note: nil, createdAt: ago(minutes: 12), downloadUrl: "/api/files/f_brief"),
            LibraryFile(id: "f_research", chatId: "g_team", authorId: "b_theo", kind: "datei", name: "Wettbewerb.md",
                        mime: "text/markdown", size: 4_821, url: nil, note: nil, createdAt: ago(minutes: 39.8), downloadUrl: "/api/files/f_research"),
            LibraryFile(id: "f_link", chatId: "g_team", authorId: "b_lio", kind: "link", name: "Launch-Checkliste in Notion",
                        mime: nil, size: nil, url: "https://www.notion.so", note: "Checkliste für Freitag", createdAt: ago(minutes: 60 * 20), downloadUrl: nil),
        ],
        "b_mila": [
            LibraryFile(id: "f_hotels", chatId: "b_mila", authorId: "b_mila", kind: "datei", name: "Hotels-Koeln-Deutz.md",
                        mime: "text/markdown", size: 2_310, url: nil, note: nil, createdAt: ago(minutes: 60 * 26), downloadUrl: "/api/files/f_hotels"),
            LibraryFile(id: "f_agenda", chatId: "b_mila", authorId: nil, kind: "datei", name: "Agenda-Jonas.pdf",
                        mime: "application/pdf", size: 96_120, url: nil, note: nil, createdAt: ago(minutes: 60 * 3), downloadUrl: "/api/files/f_agenda"),
            LibraryFile(id: "f_booking", chatId: "b_mila", authorId: "b_mila", kind: "link", name: "booking.com – Köln-Deutz",
                        mime: nil, size: nil, url: "https://www.booking.com", note: nil, createdAt: ago(minutes: 2), downloadUrl: nil),
        ],
    ]

    // MARK: Apps verbinden (v1.8)

    /// Apple-Dienste (v1.17): „MacBook Air“ (dieser Mac) mit Erinnerungen an, Kalender freigegeben aber aus,
    /// Kontakte noch nicht freigegeben; zweiter Mac ohne Apple-Freigaben. `-appleready`: alles bereit (Screenshots).
    static var apple: AppleStatus {
        let all = ProcessInfo.processInfo.arguments.contains("-appleready")
        let grants = ["reminders": "granted", "calendar": "granted", "contacts": all ? "granted" : "not_determined"]
        func svc(_ id: String, _ name: String, _ enabled: Bool) -> AppleServiceStatus {
            let perm = grants[id] ?? "unknown"
            let status = perm != "granted" ? "needs_permission" : (enabled ? "ready" : "off")
            return AppleServiceStatus(id: id, name: name, tool: nil, enabled: enabled, permission: perm, available: status == "ready",
                                      status: status, hint: status == "needs_permission" ? "Auf dem Mac in AIS Scoops Server freigeben." : nil,
                                      nodeId: "n_air")
        }
        let device = appleDevice
        return AppleStatus(nodeId: "n_air", nodeName: "MacBook Air", nodeOnline: true, nodeSource: "local", nodeChoice: "auto",
                           nodes: [AppleNode(id: "n_air", name: "MacBook Air", online: true, apple: grants),
                                   AppleNode(id: "n_minibuero", name: "Mac mini Büro", online: true,
                                             apple: ["reminders": "not_determined", "calendar": "not_determined", "contacts": "not_determined"])],
                           services: [svc("reminders", "Erinnerungen", true), svc("calendar", "Kalender", all),
                                      svc("contacts", "Kontakte", all)],
                           device: device, deviceChoice: "auto", devices: device.map { [$0] } ?? [],
                           deviceServices: deviceServices(device, enabled: ["home": all, "alarms": false, "location": all]))
    }

    /// Apple-Gerät (v1.18) im Demo-Modus: auf iPhone/iPad dieses Gerät (die Freigaben kommen dann echt von iOS), auf dem
    /// Mac „Armans iPhone“. `-appleready`: alles erlaubt (Screenshots), `-applenodevice`: noch kein iPhone angemeldet.
    static var appleDevice: AppleDevice? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-applenodevice") { return nil }
        let ready = args.contains("-appleready")
        let here = AppleDeviceAgent.isSupported
        let perms = ready ? ["home": "granted", "alarms": "granted", "location": "always"]
            : ["home": "granted", "alarms": "not_determined", "location": "when_in_use"]
        return AppleDevice(id: here ? AppleDeviceAgent.shared.deviceID : "ios-demo-iphone",
                           name: here ? AppleDeviceAgent.shared.label : "Armans iPhone", kind: "iphone", model: "iPhone18,2",
                           online: true, active: true, lastSeen: Date(), lastActive: nil,
                           capabilities: ["home", "alarms", "location"], permissions: perms, push: true, source: "auto")
    }

    /// Status wie der Server (apple_device.status): bereit nur mit Gerät, Freigabe und eingeschaltetem Dienst.
    static func deviceServices(_ device: AppleDevice?, enabled: [String: Bool]) -> [AppleServiceStatus] {
        [("home", "Home"), ("alarms", "Wecker"), ("location", "Standort")].map { id, name in
            let perm = device?.permissions[id] ?? "unknown"
            let granted = id == "location" ? ["always", "when_in_use"].contains(perm) : perm == "granted"
            let on = enabled[id] ?? false
            let status = device == nil ? "no_device" : (!granted ? "needs_permission" : (on ? "ready" : "off"))
            let hint: String? = switch status {
            case "no_device": "Öffne AIS Scoops auf deinem iPhone, damit es sich anmeldet."
            case "needs_permission": "Auf dem iPhone in AIS Scoops erlauben."
            default: nil
            }
            return AppleServiceStatus(id: id, name: name, tool: nil, enabled: on, permission: perm, available: status == "ready",
                                      status: status, hint: hint, nodeId: nil, deviceId: device?.id,
                                      background: id == "location" ? perm == "always" : nil)
        }
    }

    /// Server 1.35: eigene MCP-Server (Demo)
    static let customMCP: [CustomMCPServer] = [
        CustomMCPServer(id: "mcp_qonto", name: "Qonto", auth: "oauth", status: "ok", tools: 37, writeTools: 21,
                        url: "https://mcp.qonto.com/mcp"),
        CustomMCPServer(id: "mcp_kassenbuch", name: "Kassenbuch", auth: "token", status: "error",
                        error: "HTTP 401 – Token abgelaufen?", tools: 0, url: "https://kasse.example.com/mcp", header: "Authorization"),
        CustomMCPServer(id: "mcp_notizen", name: "Notizen lokal", kind: "stdio", status: "ok", tools: 4, writeTools: 1,
                        command: "/usr/local/bin/notizen-mcp --stdio", envKeys: ["NOTIZEN_KEY"]),
    ]

    static let connections = ConnectionsOverview(maxPerApp: 10, apps: [
        ConnectableApp(slug: "gmail", name: "Gmail", detail: "Mails lesen, Entwürfe schreiben und senden", symbol: "envelope.fill",
                       accounts: [
                        ConnectedAccount(id: "ca_g1", app: "gmail", alias: "privat", email: "arman.privat@example.com", status: "active"),
                        ConnectedAccount(id: "ca_g2", app: "gmail", alias: "arbeit", email: "arman@ais-demo.example", status: "active"),
                        ConnectedAccount(id: "ca_g3", app: "gmail", alias: "newsletter", email: "news@ais-demo.example", status: "expired"),
                       ]),
        ConnectableApp(slug: "notion", name: "Notion", detail: "Seiten und Datenbanken lesen und pflegen", symbol: "doc.text.fill",
                       accounts: [ConnectedAccount(id: "ca_n1", app: "notion", alias: nil, email: "AIS Workspace", status: "active")]),
        ConnectableApp(slug: "googlecalendar", name: "Google Kalender", detail: "Termine lesen und anlegen", symbol: "calendar",
                       accounts: [ConnectedAccount(id: "ca_c1", app: "googlecalendar", alias: "arbeit", email: nil, status: "initiated")]),
        ConnectableApp(slug: "googledrive", name: "Google Drive", detail: "Dateien suchen, lesen und ablegen", symbol: "externaldrive.fill"),
        ConnectableApp(slug: "googlesheets", name: "Google Sheets", detail: "Tabellen lesen und bearbeiten", symbol: "tablecells.fill"),
        ConnectableApp(slug: "slack", name: "Slack", detail: "Nachrichten lesen und schreiben", symbol: "number"),
        ConnectableApp(slug: "github", name: "GitHub", detail: "Issues und Pull Requests", symbol: "chevron.left.forwardslash.chevron.right"),
    ], builtin: [
        BuiltinConnection(id: "teamapp", name: "Team App", detail: "MLP-Team-Daten lesen und schreiben", symbol: "person.3.fill", status: "ok", tools: 121),
        BuiltinConnection(id: "atrium", name: "Atrium lokal", detail: "Kundendaten auf dem Air", symbol: "building.columns.fill", status: "ok", tools: 18),
        BuiltinConnection(id: "atrium_berlin", name: "Atrium Team Berlin", detail: "Team-Daten Berlin", symbol: "building.2.fill", status: "ok", tools: 18),
        BuiltinConnection(id: "atrium_koeln", name: "Atrium Team Köln", detail: "Team-Daten Köln", symbol: "building.2.fill", status: "error", tools: 0),
        BuiltinConnection(id: "t3", name: "T3 Code", detail: "Programmieraufgaben abgeben", symbol: "hammer.fill", status: "ok", tools: 5),
        BuiltinConnection(id: "lucy", name: "Lucy Telefonie", detail: "Anrufe führen lassen", symbol: "phone.fill", status: "off"),
    ])

    // MARK: Apps verbinden: Beispielkatalog (v1.16)

    /// Ausschnitt aus dem Composio-Katalog: die zehn bekannten Apps (Beliebt) und weitere aus allen Kategorien,
    /// mit allen Anmeldearten (Browser, Schlüssel-Formular, ohne Anmeldung, nicht verfügbar).
    static let catalogApps: [CatalogApp] = {
        func app(_ slug: String, _ name: String, _ detail: String, _ cats: [String], _ auth: CatalogApp.Auth = .oauth,
                 symbol: String? = nil, popular: Bool = false) -> CatalogApp {
            CatalogApp(slug: slug, name: name, detail: detail, logoUrl: "https://logos.composio.dev/api/\(slug)", symbol: symbol,
                       categories: cats, auth: auth, popular: popular)
        }
        return [
            app("gmail", "Gmail", "Mails lesen, Entwürfe schreiben, senden", ["communication"], symbol: "envelope.fill", popular: true),
            app("googlecalendar", "Google Kalender", "Termine lesen und anlegen", ["productivity"], symbol: "calendar", popular: true),
            app("outlook", "Outlook", "Microsoft-Mail und -Kalender", ["communication"], symbol: "envelope.badge.fill", popular: true),
            app("notion", "Notion", "Seiten und Datenbanken, z. B. Tasks", ["productivity"], symbol: "doc.text.fill", popular: true),
            app("googledrive", "Google Drive", "Dateien finden und ablegen", ["productivity"], symbol: "externaldrive.fill", popular: true),
            app("googlesheets", "Google Sheets", "Tabellen lesen und füllen", ["productivity"], symbol: "tablecells.fill", popular: true),
            app("googledocs", "Google Docs", "Dokumente lesen und schreiben", ["productivity"], symbol: "doc.richtext.fill", popular: true),
            app("slack", "Slack", "Nachrichten lesen und schreiben", ["communication"], symbol: "number", popular: true),
            app("github", "GitHub", "Repos, Issues, Pull Requests", ["development"],
                symbol: "chevron.left.forwardslash.chevron.right", popular: true),
            app("linkedin", "LinkedIn", "Profil und Beiträge", ["marketing"], symbol: "person.crop.square.fill", popular: true),
            app("figma", "Figma", "Collaborative interface design tool.", ["design"]),
            app("canva", "Canva", "Online design and visual communication platform.", ["design"]),
            app("jira", "Jira", "A tool for bug tracking, issue tracking, and agile project management.", ["productivity", "development"]),
            app("asana", "Asana", "Tool to help teams organize, track, and manage their work.", ["productivity"]),
            app("trello", "Trello", "Web-based, kanban-style, list-making application.", ["productivity"]),
            app("todoist", "Todoist", "Task manager and to-do list app.", ["productivity"]),
            app("discord", "Discord", "Voice, video and text chat for communities.", ["communication"]),
            app("zoom", "Zoom", "Video conferencing and online meetings.", ["communication"]),
            app("hubspot", "HubSpot", "Inbound marketing, sales, and customer service platform.", ["sales", "marketing"]),
            app("salesforce", "Salesforce", "Leading CRM platform for sales and service.", ["sales"]),
            app("stripe", "Stripe", "Online payment processing for internet businesses.", ["finance"]),
            app("supabase", "Supabase", "Open source Firebase alternative with Postgres.", ["development", "data"]),
            app("perplexityai", "Perplexity AI", "AI-powered answer engine with web search.", ["ai", "data"], .fields),
            app("tavily", "Tavily", "Search API built for AI agents and LLMs.", ["ai", "data"], .fields),
            app("freshdesk", "Freshdesk", "Customer support software with ticketing and automation.", ["sales"], .fields),
            app("mailchimp", "Mailchimp", "Email marketing and newsletters.", ["marketing"]),
            app("airtable", "Airtable", "Spreadsheet-database hybrid for teams.", ["productivity", "data"], .fields),
            app("openai", "OpenAI", "Models for text, images and speech.", ["ai"], .fields),
            app("lexoffice", "Lexoffice", "Buchhaltung und Rechnungen für kleine Unternehmen.", ["finance"], .fields),
            app("twitter", "Twitter", "Social network for short posts.", ["marketing"], .unavailable),
            app("snowflake", "Snowflake", "Cloud data warehouse.", ["data"], .unavailable),
            app("hackernews", "Hacker News", "Tech news and discussions.", ["data"], .none),
            app("posthog", "PostHog", "Product analytics, session replays and feature flags.", ["data", "development"], .fields),
            app("propertyradar", "PropertyRadar", "Property data and owner leads.", ["real-estate"], .fields),
        ]
    }()

    /// Formularfelder wie vom Server (`GET /api/connections/catalog/{slug}`) für Schlüssel-Apps der Demo.
    static func authInfo(for app: CatalogApp) -> AppAuthInfo {
        var fields = [AuthField(name: "generic_api_key", label: "API Key",
                                description: "Deinen \(app.name)-Schlüssel findest du in den Einstellungen unter „API Keys“.",
                                secret: true)]
        if app.slug == "freshdesk" || app.slug == "posthog" {
            fields.insert(AuthField(name: "subdomain", label: app.slug == "posthog" ? "Region" : "Subdomain",
                                    description: app.slug == "posthog" ? "eu oder us" : "Der Teil vor .freshdesk.com, z. B. „acme“.",
                                    secret: false), at: 0)
        }
        return AppAuthInfo(slug: app.slug, name: app.name, auth: "fields", scheme: "API_KEY", fields: fields,
                           guideUrl: "https://example.com/\(app.slug)/api-keys")
    }

    // MARK: Bereiche (v1.6): „Privat“ eingeklappt, „Ideen“ leer

    static let sections: [SidebarSection] = [
        SidebarSection(name: "Arbeit"),
        SidebarSection(name: "Privat", collapsed: true),
        SidebarSection(name: "Ideen"),
    ]

    // MARK: Initiative, Fähigkeiten, Tresor (v1.4)

    static let initiative = InitiativeSettings(enabled: true, times: ["07:30", "12:30", "17:30"],
                                               quietStart: "22:00", quietEnd: "07:00", primaryBotId: "b_mila")

    static let skills: [Skill] = [
        Skill(id: "sk_hotel", botId: "b_mila", name: "Hotelsuche Köln",
              description: "Passende Hotels für Termine in Köln finden und vergleichen.",
              steps: "1. Termin und Ort aus dem Kalender holen\n2. Auf booking.com nach Hotels in der Nähe suchen (max. 140 €)\n3. Drei Vorschläge mit Preis und Weg zum Termin schicken\n4. Erst nach Freigabe buchen",
              uses: 4, lastUsed: ago(minutes: 2), createdAt: ago(minutes: 60 * 24 * 6)),
        Skill(id: "sk_agenda", botId: "b_mila", name: "Agenda für Calls",
              description: "Kurze Agenda aus Mails und Notizen bauen und als Entwurf vorbereiten.",
              steps: "1. Letzte Mails mit der Person lesen\n2. Offene Punkte sammeln (max. 3)\n3. Mail-Entwurf schreiben\n4. Freigabe-Karte schicken",
              uses: 2, lastUsed: ago(minutes: 60 * 3), createdAt: ago(minutes: 60 * 24 * 3)),
        Skill(id: "sk_login", botId: nil, name: "Anmeldung mit Tresor-Eintrag",
              description: "Auf einer Webseite mit gespeicherten Zugangsdaten anmelden.",
              steps: "1. Seite im Browser öffnen\n2. Passenden Tresor-Eintrag zur Domain wählen\n3. Mit „login_ausfuellen“ Benutzername und Passwort eintragen lassen\n4. Prüfen, ob die Anmeldung geklappt hat",
              uses: 7, lastUsed: ago(minutes: 60 * 26), createdAt: ago(minutes: 60 * 24 * 9)),
    ]

    static let vault: [VaultEntry] = [
        VaultEntry(id: "v_demo1", title: "Übungsseite", url: "https://the-internet.herokuapp.com/login",
                   domain: "the-internet.herokuapp.com", username: "tomsmith", note: "Nur zum Testen",
                   hasPassword: true, lastUsed: ago(minutes: 60 * 26), createdAt: ago(minutes: 60 * 24 * 9)),
        VaultEntry(id: "v_demo2", title: "Beispiel-Shop", url: "https://shop.example.com/konto",
                   domain: "shop.example.com", username: "arman@example.com", note: "",
                   hasPassword: true, lastUsed: nil, createdAt: ago(minutes: 60 * 24 * 2)),
    ]

    /// Modellkatalog wie vom Server 1.34 (GET /api/models, gekürzt)
    static let modelCatalog = ModelCatalog(
        version: 2026111801, source: "bundled",
        models: [
            .init(id: "claude-haiku-5-5", label: "Haiku 5.5", provider: "anthropic", hint: "Schnell & günstig", rank: 10, available: true),
            .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: "anthropic", hint: "Stärker", rank: 20, available: true),
            .init(id: "claude-opus-5-5", label: "Opus 5.5", provider: "anthropic", hint: "Sehr stark, teuer", rank: 30, available: true),
            .init(id: "claude-fable-5-2", label: "Fable 5.2", provider: "anthropic", hint: "Am stärksten, sehr teuer", rank: 40,
                  available: true),
            .init(id: "gpt-6-luna", label: "GPT-6 Luna", provider: "openai", hint: "Schnell & sehr günstig", rank: 10, available: true),
            .init(id: "gpt-6.1-terra", label: "GPT-6.1 Terra", provider: "openai", hint: "Ausgewogen & günstig", rank: 20, available: true),
            .init(id: "gpt-6.2-sol", label: "GPT-6.2 Sol", provider: "openai", hint: "Stark, Allrounder", rank: 30, available: true),
            .init(id: "gpt-6.2-astra", label: "GPT-6.2 Astra", provider: "openai", hint: "Am stärksten, teuer", rank: 40, available: true),
            .init(id: "gpt-6.1-sol", label: "GPT-6.1 Sol", provider: "openai", rank: 29, deprecated: true, selectable: false),
            .init(id: "gpt-6-astra", label: "GPT-6 Astra", provider: "openai", rank: 39, deprecated: true, selectable: false),
        ],
        replaced: ["gpt-6.1-sol": "gpt-6.2-sol", "gpt-6-astra": "gpt-6.2-astra"],
        defaults: ["anthropic": .init(model: "claude-haiku-5-5", escalation: "claude-sonnet-5-5"),
                   "openai": .init(model: "gpt-6-luna", escalation: "gpt-6.2-sol")])

    static let usage = Usage(todayUsd: 0.12, monthUsd: 3.4,
                             byModel: ["claude-haiku-5-5": 1.52, "claude-sonnet-5-5": 0.91, "gpt-6.2-sol": 0.64, "gpt-6-luna": 0.16,
                                       "claude-opus-5-5": 0.17],
                             byBot: ["b_mila": .init(todayUsd: 0.06, monthUsd: 1.62), "b_theo": .init(todayUsd: 0.04, monthUsd: 0.98),
                                     "b_lio": .init(todayUsd: 0.01, monthUsd: 0.41), "b_nora": .init(todayUsd: 0.01, monthUsd: 0.27),
                                     "b_pip": .init(todayUsd: 0, monthUsd: 0.12)])
}
