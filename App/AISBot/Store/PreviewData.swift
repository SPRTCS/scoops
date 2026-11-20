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

    static let mila = Bot(id: "b_mila", name: "Mila", label: demoText("Assistenz", en: "Assistant"),
                          mascot: Mascot(shape: "pill", color: "#8A2EDB", eyes: "focused", accessory: "glasses", gaze: "right"),
                          character: demoText("Locker, präzise, duzt. Fragt nach, bevor sie etwas verschickt.",
                                             en: "Casual, precise, on a first-name basis. Checks with you before sending anything."),
                          model: "claude-haiku-5-5", escalationModel: "claude-sonnet-5-5",
                          pinned: true, section: demoText("Arbeit", en: "Work"), createdAt: ago(minutes: 60 * 24 * 12), busy: true,
                          primary: true)
    static let theo = Bot(id: "b_theo", name: "Theo", label: demoText("Recherche", en: "Research"),
                          mascot: Mascot(shape: "cloud", color: "#1270E8", eyes: "dashes", accessory: "none", mouth: "smile"),
                          character: demoText("Gründlich, nennt immer Quellen, ein bisschen nerdig.",
                                             en: "Thorough, always cites sources, a little nerdy."),
                          model: "claude-sonnet-5-5", pinned: true, section: demoText("Arbeit", en: "Work"), createdAt: ago(minutes: 60 * 24 * 9))
    static let lio = Bot(id: "b_lio", name: "Lio", label: "Social Media",
                         mascot: Mascot(shape: "egg", color: "#FBBA10", eyes: "relaxed", accessory: "beret", gaze: "right"),
                         character: demoText("Kreativ, verspielt, schreibt knackige Posts.", en: "Creative, playful, writes punchy posts."),
                         model: "claude-haiku-5-5", pinned: false, section: demoText("Arbeit", en: "Work"), createdAt: ago(minutes: 60 * 24 * 7), unread: 2)
    static let nora = Bot(id: "b_nora", name: "Nora", label: demoText("Finanzen", en: "Finance"),
                          // Demo für „Eigenes Bild“ (v1.12): erzeugtes Testbild aus MockService.demoPhotoData()
                          mascot: Mascot(shape: "star_soft", color: "#43C62E", eyes: "dashes", accessory: "cap",
                                         photo: MascotPhoto(id: "b_nora", version: 1), mouth: "smile"),
                          character: demoText("Ruhig, genau, erklärt Zahlen in einfachen Worten.",
                                             en: "Calm, meticulous, explains numbers in plain words."),
                          model: "gpt-6.2-sol", pinned: false, section: demoText("Privat", en: "Personal"), createdAt: ago(minutes: 60 * 24 * 5), unread: 1)
    static let pip = Bot(id: "b_pip", name: "Pip", label: demoText("Erinnerungen", en: "Reminders"),
                         mascot: Mascot(shape: "heart", color: "#F72A7A", eyes: "lashes", accessory: "none", gaze: "left", mouth: "smile"),
                         character: demoText("Freundlich, kurz angebunden, vergisst nie etwas.",
                                             en: "Friendly, brief, never forgets a thing."),
                         model: "claude-haiku-5-5", pinned: false, section: nil, createdAt: ago(minutes: 60 * 24 * 3))

    static var bots: [Bot] {
        [mila, theo, lio, nora, pip].map { b in
            var b = b
            b.lastMessage = messages[b.id]?.last
            // Demo: offene Freigabe → rotes „?“
            b.waiting = (b.lastMessage?.role == .approval && b.lastMessage?.meta.state == "pending") || b.id == "b_lio"
            // Rechner-Zugriff (v1.29): Standard, ein Scoop mit Projektordnern
            var access = b.id == "b_theo"
                ? ScoopAccess(mode: "auto", scope: "projects", folders: [demoText("~/Desktop/Projekte/Website", en: "~/Desktop/Projects/Website"), "~/Code/AIS Bot"])
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
            Message(id: "m_1", botId: "b_mila", role: .event, text: demoText("Routine angelegt: Morgenbriefing", en: "Routine created: Morning Briefing"),
                    createdAt: ago(minutes: 60 * 26), meta: MessageMeta(icon: "clock")),
            Message(id: "m_2", botId: "b_mila", role: .bot,
                    text: demoText("Alles klar! Ab morgen bekommst du werktags um **7:30** dein Briefing: Termine, wichtige Mails und das Wetter in Köln.",
                                  en: "Got it! Starting tomorrow, you’ll get your briefing every weekday at **7:30 AM**: meetings, important emails, and the weather in New York."),
                    createdAt: ago(minutes: 60 * 26 - 1)),
            Message(id: "m_3", botId: "b_mila", role: .event, text: demoText("Routine ausgelöst: Morgenbriefing", en: "Routine triggered: Morning Briefing"),
                    createdAt: ago(minutes: 60 * 3), meta: MessageMeta(icon: "sunrise")),
            Message(id: "m_4", botId: "b_mila", role: .bot, text: demoText("""
            Guten Morgen Arman! Das steht heute an:

            - **09:00** Call mit Jonas (Agenda fehlt noch)
            - **11:30** Kundentermin in Köln-Deutz
            - **16:00** Zahnarzt, Dr. Weber

            Drei Mails sind wichtig, die Details liegen [in deinem Postfach](https://mail.google.com). Soll ich Jonas schon mal die Agenda schicken?
            """, en: """
            Good morning, Arman! Here’s what’s on today:

            - **9:00 AM** Call with Jonas (no agenda yet)
            - **11:30 AM** Client meeting in Midtown
            - **4:00 PM** Dentist, Dr. Miller

            Three emails look important; the details are [in your inbox](https://mail.google.com). Want me to send Jonas the agenda now?
            """), createdAt: ago(minutes: 60 * 3 - 1), meta: meta { $0.reactions = ["user": "❤️"] }),
            Message(id: "m_5", botId: "b_mila", role: .user, text: demoText("Ja, gern. Kurz und knackig bitte", en: "Yes, please. Short and sweet"),
                    createdAt: ago(minutes: 60 * 3 - 8), meta: meta {
                        $0.reactions = ["b_mila": "👍"]
                        // v1.15: Antwort auf eine bestimmte Nachricht
                        $0.replyTo = ReplyRef(id: "m_4", role: "bot", authorId: "b_mila", authorName: "Mila",
                                              text: demoText("Guten Morgen Arman! Das steht heute an: 09:00 Call mit Jonas (Agenda fehlt noch) 11:30 Kundentermin in Köln-Deutz …",
                                                            en: "Good morning, Arman! Here’s what’s on today: 9:00 AM Call with Jonas (no agenda yet) 11:30 AM Client meeting in Midtown…"))
                    }),
            Message(id: "m_6", botId: "b_mila", role: .status, text: "",
                    createdAt: ago(minutes: 60 * 3 - 8.2),
                    meta: MessageMeta(runId: "r_1", state: "done", lines: [demoText("Liest die Mail von Jonas", en: "Reads Jonas’s email"),
                                                                       demoText("Schaut in deinen Kalender", en: "Checks your calendar"),
                                                                       demoText("Schreibt einen Entwurf", en: "Writes a draft")],
                                      usesComputer: false, model: "claude-haiku-5-5", costUsd: 0.0021,
                                      startedAt: ago(minutes: 60 * 3 - 8.2), finishedAt: ago(minutes: 60 * 3 - 8.4))),
            Message(id: "m_7", botId: "b_mila", role: .approval, text: demoText("Mail an Jonas senden", en: "Send email to Jonas"),
                    createdAt: ago(minutes: 60 * 3 - 8.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_1", title: demoText("Mail an Jonas senden", en: "Send email to Jonas"),
                                           details: demoText("Betreff: Agenda für heute, 9 Uhr\n\nHi Jonas,\nfür unseren Call: 1. Stand Kampagne, 2. Budget Q1, 3. nächste Schritte.\n\nBis gleich!\nArman",
                                                             en: "Subject: Agenda for today, 9 AM\n\nHi Jonas,\nHere’s the agenda for our call: 1. Campaign status, 2. Q1 budget, 3. Next steps.\n\nTalk soon!\nArman"),
                                           kind: "mail")) {
                        $0.canAlways = true
                        $0.alwaysLabel = demoText("Mails an jonas@kunde-demo.example (Konto arbeit)",
                                                  en: "Emails to jonas@client-demo.example (work account)")
                        $0.mail = MailDraft(account: demoText("arbeit", en: "work"), accountEmail: "arman@ais-demo.example",
                                            to: [demoText("jonas@kunde-demo.example", en: "jonas@client-demo.example")],
                                            subject: demoText("Agenda für heute, 9 Uhr", en: "Agenda for today, 9 AM"),
                                            body: demoText("Hi Jonas,\n\nfür unseren Call um 9 Uhr schlage ich vor:\n\n1. Stand der Kampagne\n2. Budget Q1\n3. Nächste Schritte und Termine\n\nWenn dir noch etwas fehlt, schreib es gern kurz dazu. Die Unterlagen vom letzten Mal hänge ich nachher noch an.\n\nBis gleich!\nArman",
                                                           en: "Hi Jonas,\n\nHere’s what I’d suggest for our 9 AM call:\n\n1. Campaign status\n2. Q1 budget\n3. Next steps and dates\n\nIf I missed anything, just add it. I’ll send over the materials from last time later today.\n\nTalk soon!\nArman"))
                    }),
            Message(id: "m_7b", botId: "b_mila", role: .event, text: demoText("Fähigkeit gespeichert: Agenda für Calls", en: "Skill saved: Call Agenda"),
                    createdAt: ago(minutes: 60 * 3 - 8.6), meta: MessageMeta(icon: "wand.and.stars")),
            Message(id: "m_7c", botId: "b_mila", role: .event, text: demoText("An Theo: Bahnverbindungen Köln für Donnerstag raussuchen",
                                                                                en: "To Theo: Find trains to Boston for Thursday"),
                    createdAt: ago(minutes: 12),
                    meta: meta(MessageMeta(icon: "arrow.turn.up.right", authorId: "b_mila")) { $0.peerOut = true; $0.targetId = "b_theo" }),
            Message(id: "m_7d", botId: "b_mila", role: .bot,
                    text: demoText("Hier sind die Verbindungen für Donnerstag: **ICE 1023** ab 7:12, an Köln Hbf 8:58. Zurück ginge der **ICE 1028** um 18:05.",
                                  en: "Here are the trains for Thursday: **Acela 2151** departs 5:00 AM, arrives Boston South Station 8:40 AM. For the trip back, there’s **Acela 2170** at 6:15 PM."),
                    createdAt: ago(minutes: 10),
                    meta: meta(MessageMeta(authorId: "b_theo")) { $0.peer = true; $0.silent = true }),
            // v1.21: Aufsicht – Mila (Haupt-Scoop) schlägt eine Verbesserung für Theo vor
            Message(id: "m_7e", botId: "b_mila", role: .approval, text: "",
                    createdAt: ago(minutes: 9.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_su1",
                                           title: demoText("Verbesserung für Theo: Neue Fähigkeit „Bahnverbindungen“",
                                                           en: "Improvement for Theo: New skill “Train Schedules”"),
                                           details: demoText("Scoop: Theo (Recherche)\n\nÄnderung: Neue Fähigkeit „Bahnverbindungen“",
                                                             en: "Scoop: Theo (Research)\n\nChange: New skill “Train Schedules”"),
                                           kind: "scoop_update")) {
                        $0.scoopUpdate = ScoopUpdate(
                            targetId: "b_theo", targetName: "Theo", targetLabel: demoText("Recherche", en: "Research"), art: "faehigkeit",
                            label: demoText("Neue Fähigkeit „Bahnverbindungen“", en: "New skill “Train Schedules”"),
                            reason: demoText("Am 12.11. und 14.11. hat Arman zweimal nachgefragt („nein, ab Köln Hbf, nicht Deutz“). Theo hat den Abfahrtsbahnhof nicht geprüft.",
                                             en: "On 11/12 and 11/14, Arman had to follow up twice (“no, into South Station, not Back Bay”). Theo didn’t check the arrival station."),
                            after: demoText("1. Abfahrts- und Zielbahnhof genau übernehmen (Köln Hbf ≠ Köln Messe/Deutz).\n2. Verbindungen über die DB-Suche abrufen, höchstens 3 zeigen.\n3. Zu jeder Verbindung Umstiege und Preis nennen.",
                                            en: "1. Use the exact departure and arrival stations (South Station ≠ Back Bay).\n2. Look up trains on Amtrak and show 3 at most.\n3. Include transfers and the fare for each train."))
                    }),
            Message(id: "m_8", botId: "b_mila", role: .user,
                    text: demoText("Kannst du mir ein Hotel in Köln für nächsten Donnerstag suchen? Max. 140 € und nah am Bahnhof.",
                                  en: "Can you find me a hotel in Boston for next Thursday? $250 max, close to the station."),
                    createdAt: ago(minutes: 2), meta: meta {
                        $0.reactions = ["b_mila": "👍"]
                        $0.replyTo = ReplyRef(id: "m_7d", role: "bot", authorId: "b_theo", authorName: "Theo",
                                              text: demoText("Hier sind die Verbindungen für Donnerstag: ICE 1023 ab 7:12, an Köln Hbf 8:58. Zurück ginge der ICE 1028 um 18:05.",
                                                            en: "Here are the trains for Thursday: Acela 2151 departs 5:00 AM, arrives Boston South Station 8:40 AM. For the trip back, there’s Acela 2170 at 6:15 PM."))
                    }),
            Message(id: "m_9", botId: "b_mila", role: .status, text: "",
                    createdAt: ago(minutes: 1.9),
                    meta: MessageMeta(runId: "r_2", state: "running",
                                      lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                              demoText("Ist im Browser auf booking.com", en: "Browses booking.com"),
                                              demoText("Vergleicht 12 Hotels in Köln-Deutz", en: "Compares 12 hotels near South Station")],
                                      usesComputer: true, model: "claude-haiku-5-5", startedAt: ago(minutes: 1.9))),
        ],
        "b_theo": [
            Message(id: "t_1", botId: "b_theo", role: .user, text: demoText("Was ist neu in Swift 6.4? Kurz bitte.", en: "What’s new in Swift 6.4? Keep it short."),
                    createdAt: ago(minutes: 60 * 5)),
            Message(id: "t_2", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 60 * 5 - 0.1),
                    meta: MessageMeta(runId: "r_t", state: "done", lines: [demoText("Sucht im Netz", en: "Searches the web"), demoText("Liest swift.org", en: "Reads swift.org"),
                                                                                  demoText("Fasst zusammen", en: "Summarizes")],
                                      usesComputer: false, model: "claude-sonnet-5-5", costUsd: 0.012,
                                      startedAt: ago(minutes: 60 * 5 - 0.1), finishedAt: ago(minutes: 60 * 5 - 0.5))),
            Message(id: "t_3", botId: "b_theo", role: .bot, text: demoText("""
            Die drei wichtigsten Punkte:

            1. **Schnellere Builds** durch inkrementelles Makro-Caching
            2. **Bessere Fehlermeldungen** bei Concurrency
            3. Neue `Observation`-Helfer für Sammlungen

            Quelle: [swift.org/blog](https://swift.org/blog)
            """, en: """
            The three key points:

            1. **Faster builds** thanks to incremental macro caching
            2. **Better error messages** for concurrency
            3. New `Observation` helpers for collections

            Source: [swift.org/blog](https://swift.org/blog)
            """), createdAt: ago(minutes: 60 * 5 - 0.6)),
            Message(id: "t_4", botId: "b_theo", role: .user,
                    text: demoText("Kannst du T3 bitten, im AIS-Scoops-Server die Fehlermeldung beim Login verständlicher zu machen?",
                                  en: "Can you ask T3 to make the login error message in the AIS Scoops server easier to understand?"),
                    createdAt: ago(minutes: 270)),
            Message(id: "t_5", botId: "b_theo", role: .approval, text: demoText("Auftrag an T3 Code", en: "Task for T3 Code"),
                    createdAt: ago(minutes: 269.6),
                    meta: MessageMeta(state: "approved", approvalId: "a_t3a",
                                      title: demoText("Auftrag an T3: Login-Fehlermeldung verbessern", en: "Task for T3: Improve login error message"),
                                      details: demoText("Projekt: AIS Scoops/Server\nAuftrag: Bei falschem Token eine klare deutsche Fehlermeldung zurückgeben und einen Test dafür ergänzen.",
                                                        en: "Project: AIS Scoops/Server\nTask: Return a clear error message for a wrong token and add a test for it."),
                                      kind: "t3")),
            Message(id: "t_6", botId: "b_theo", role: .event, text: demoText("T3 arbeitet: Login-Fehlermeldung verbessern", en: "T3 is working: Improve login error message"),
                    createdAt: ago(minutes: 269.2),
                    meta: MessageMeta(icon: "hammer", url: "https://app.t3.codes/threads/demo-login")),
            Message(id: "t_7", botId: "b_theo", role: .event, text: demoText("T3 fertig: Login-Fehlermeldung verbessern", en: "T3 done: Improve login error message"),
                    createdAt: ago(minutes: 261),
                    meta: MessageMeta(icon: "hammer", url: "https://app.t3.codes/threads/demo-login")),
            Message(id: "t_8", botId: "b_theo", role: .bot,
                    text: demoText("T3 ist fertig: Die Fehlermeldung lautet jetzt „Der Token passt nicht“, inklusive Test. Soll T3 das auch für abgelaufene Tokens machen?",
                                  en: "T3 is done: the error message now reads “The token doesn’t match,” with a test. Should T3 do the same for expired tokens?"),
                    createdAt: ago(minutes: 260.8)),
            // Build 12: mehrere Läufe am Bot-Rechner (fertig, abgebrochen, angehalten, veraltet „running“, aktuell)
            Message(id: "t_r1", botId: "b_theo", role: .user,
                    text: demoText("Schau bitte im Browser nach Swift-Konferenzen im Frühjahr, am liebsten in Europa.",
                                  en: "Can you look up Swift conferences this spring in the browser? Ideally in the US."),
                    createdAt: ago(minutes: 55)),
            Message(id: "t_r2", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 54.9),
                    meta: MessageMeta(runId: "r_tc1", state: "done",
                                      lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                              demoText("Sucht nach „Swift Konferenz 2027“", en: "Searches for “Swift conference 2027”"),
                                              demoText("Ist im Browser auf swift.org/events", en: "Browses swift.org/events"),
                                              demoText("Liest die Konferenzliste", en: "Reads the conference list"),
                                              demoText("Öffnet 3 Konferenzseiten", en: "Opens 3 conference pages"),
                                              demoText("Vergleicht Termine und Preise", en: "Compares dates and prices"),
                                              demoText("Fasst zusammen", en: "Summarizes")],
                                      usesComputer: true, model: "claude-sonnet-5-5", costUsd: 0.018,
                                      startedAt: ago(minutes: 54.9),
                                      finishedAt: ago(minutes: 54.9).addingTimeInterval(37))),
            Message(id: "t_r3", botId: "b_theo", role: .bot, text: demoText("""
            Drei passen gut:

            1. **Swift Spring Summit**, Amsterdam, 12.–13. März
            2. **iOS Dev Days**, Köln, 9. April
            3. **SwiftConf Nord**, Kopenhagen, 21. Mai
            """, en: """
            Three look like a good fit:

            1. **Swift Spring Summit**, Chicago, March 12–13
            2. **iOS Dev Days**, Boston, April 9
            3. **SwiftConf West**, San Francisco, May 21
            """), createdAt: ago(minutes: 54.2)),
            Message(id: "t_r4", botId: "b_theo", role: .user, text: demoText("Super, prüf bitte noch die Hotelpreise in Köln für den 9. April.",
                                                                                       en: "Great, can you also check hotel prices in Boston for April 9?"),
                    createdAt: ago(minutes: 45)),
            Message(id: "t_r5", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 44.9),
                    meta: meta(MessageMeta(runId: "r_tc2", state: "stopped",
                                           lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                                   demoText("Ist im Browser auf hotels.example", en: "Browses hotels.example")],
                                           usesComputer: true, model: "claude-sonnet-5-5",
                                           startedAt: ago(minutes: 44.9), finishedAt: ago(minutes: 44.5))) {
                        $0.interrupted = true
                    }),
            Message(id: "t_r6", botId: "b_theo", role: .event, text: demoText("Server neu gestartet, Lauf abgebrochen", en: "Server restarted, run canceled"),
                    createdAt: ago(minutes: 44.45), meta: MessageMeta(icon: "arrow.clockwise")),
            Message(id: "t_r7", botId: "b_theo", role: .user, text: demoText("Nochmal bitte, gleiche Suche.", en: "Try again, please. Same search."), createdAt: ago(minutes: 38)),
            Message(id: "t_r8", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 37.9),
                    meta: MessageMeta(runId: "r_tc3", state: "stopped",
                                      lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                              demoText("Ist im Browser auf hotels.example", en: "Browses hotels.example"),
                                              demoText("Filtert nach Preis", en: "Filters by price")],
                                      usesComputer: true, model: "claude-sonnet-5-5",
                                      startedAt: ago(minutes: 37.9), finishedAt: ago(minutes: 37.8))),
            Message(id: "t_r9", botId: "b_theo", role: .user, text: demoText("Stopp, das reicht erst mal. Schau später noch mal.", en: "Stop, that’s enough for now. Check again later."),
                    createdAt: ago(minutes: 37.6)),
            // Verpasstes Update: steht noch auf „running“, obwohl danach ein neuer Lauf begann → „Beendet“, ohne Live-Bild
            Message(id: "t_r10", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 30),
                    meta: MessageMeta(runId: "r_tc4", state: "running",
                                      lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                              demoText("Ist im Browser auf bahn.example", en: "Browses amtrak.example")],
                                      usesComputer: true, model: "claude-sonnet-5-5", startedAt: ago(minutes: 30))),
            Message(id: "t_8b", botId: "b_theo", role: .bot,
                    text: demoText("Theo, kannst du für Arman die Bahnverbindungen nach Köln am Donnerstag raussuchen? Ankunft vor 9 Uhr.",
                                  en: "Theo, can you find Arman a train to Boston on Thursday, arriving before 9 AM?"),
                    createdAt: ago(minutes: 12),
                    meta: meta(MessageMeta(authorId: "b_mila")) { $0.peer = true; $0.silent = true }),
            Message(id: "t_8c", botId: "b_theo", role: .bot,
                    text: demoText("Erledigt, ICE 1023 ab 7:12 passt. Hab es Mila geschickt.", en: "Done. Acela 2151 at 5:00 AM works. Sent it to Mila."),
                    createdAt: ago(minutes: 10), meta: meta { $0.silent = true }),
            Message(id: "t_9", botId: "b_theo", role: .approval, text: demoText("Nachricht an T3 Code", en: "Message to T3 Code"),
                    createdAt: ago(minutes: 2),
                    meta: MessageMeta(state: "pending", approvalId: "a_t3b",
                                      title: demoText("Nachricht an T3: auch abgelaufene Tokens", en: "Message to T3: expired tokens too"),
                                      details: demoText("Thread: Login-Fehlermeldung verbessern\nNachricht: Bitte dieselbe klare Meldung auch bei abgelaufenen Tokens zurückgeben.",
                                                        en: "Thread: Improve login error message\nMessage: Please return the same clear message for expired tokens too."),
                                      kind: "t3")),
            Message(id: "t_10", botId: "b_theo", role: .user, text: demoText("Und schau jetzt bitte noch einmal nach den Hotels in Köln.", en: "Now please check the Boston hotels again."),
                    createdAt: ago(minutes: 1)),
            // Aktueller Lauf: nur diese Karte zeigt das Live-Bild
            Message(id: "t_11", botId: "b_theo", role: .status, text: "", createdAt: ago(minutes: 0.9),
                    meta: MessageMeta(runId: "r_tc5", state: "running",
                                      lines: [demoText("Öffnet den Browser", en: "Opens the browser"),
                                              demoText("Ist im Browser auf hotels.example", en: "Browses hotels.example"),
                                              demoText("Vergleicht 9 Hotels in Köln-Deutz", en: "Compares 9 hotels near South Station")],
                                      usesComputer: true, model: "claude-sonnet-5-5", startedAt: ago(minutes: 0.9))),
        ],
        "b_lio": [
            // Build 12 (API v1.10): Tresor-Formular – gespeichert, abgelehnt, offen
            Message(id: "l_v1", botId: "b_lio", role: .user,
                    text: demoText("Melde dich bitte im Social-Media-Planer an und plane die Launch-Posts ein.",
                                  en: "Please sign in to the social media planner and schedule the launch posts."),
                    createdAt: ago(minutes: 60 * 6)),
            Message(id: "l_v2", botId: "b_lio", role: .approval, text: demoText("Login für Social-Media-Planer", en: "Login for Social Media Planner"),
                    createdAt: ago(minutes: 60 * 6 - 0.5),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_v1", title: demoText("Social-Media-Planer", en: "Social Media Planner"),
                                           kind: "vault")) {
                        $0.vault = VaultForm(title: demoText("Social-Media-Planer", en: "Social Media Planner"),
                                             url: demoText("https://planer.example.com/login", en: "https://planner.example.com/login"),
                                             domain: demoText("planer.example.com", en: "planner.example.com"), username: "arman@ais-demo.example",
                                             status: "saved", vaultId: "v_demo3")
                    }),
            Message(id: "l_v3", botId: "b_lio", role: .event, text: demoText("Login gespeichert: Social-Media-Planer", en: "Login saved: Social Media Planner"),
                    createdAt: ago(minutes: 60 * 6 - 1.5), meta: MessageMeta(icon: "key.fill")),
            Message(id: "l_v4", botId: "b_lio", role: .bot, text: demoText("Bin drin! Die drei Posts sind für Freitag 9, 12 und 17 Uhr eingeplant.",
                                                                                    en: "I’m in! The three posts are scheduled for Friday at 9 AM, noon, and 5 PM."),
                    createdAt: ago(minutes: 60 * 6 - 3)),
            Message(id: "l_v5", botId: "b_lio", role: .approval, text: demoText("Login für Bildarchiv", en: "Login for Image Archive"),
                    createdAt: ago(minutes: 60 * 4),
                    meta: meta(MessageMeta(state: "declined", approvalId: "a_v2", title: demoText("Bildarchiv", en: "Image Archive"),
                                           kind: "vault")) {
                        $0.vault = VaultForm(title: demoText("Bildarchiv", en: "Image Archive"),
                                             url: demoText("https://bilder.example.com/anmelden", en: "https://images.example.com/login"),
                                             domain: demoText("bilder.example.com", en: "images.example.com"), username: "", status: "declined")
                    }),
            Message(id: "l_1", botId: "b_lio", role: .bot, text: demoText("Ich hab zwei Entwürfe für deinen X-Post zum App-Launch. Welcher gefällt dir?",
                                                                                   en: "I’ve got two drafts for your app launch post on X. Which one do you like better?"),
                    createdAt: ago(minutes: 45)),
            Message(id: "l_2", botId: "b_lio", role: .approval, text: demoText("Post auf X veröffentlichen", en: "Publish post on X"),
                    createdAt: ago(minutes: 44),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_2", title: demoText("Post auf X veröffentlichen", en: "Publish post on X"),
                                           details: demoText("Unsere neue App ist da! Bots mit Charakter, die für dich arbeiten. Probiert sie aus und sagt uns, was ihr denkt.",
                                                             en: "Our new app is here! Bots with personality that work for you. Give them a try and tell us what you think."))) {
                        $0.canAlways = true
                        $0.alwaysLabel = demoText("Wochenpost auf X veröffentlichen", en: "Publish weekly post on X")
                    }),
            Message(id: "l_2b", botId: "b_lio", role: .event, text: demoText("Automatisch freigegeben: Story auf Instagram teilen", en: "Auto-approved: Share story on Instagram"),
                    createdAt: ago(minutes: 43.5), meta: meta(MessageMeta(icon: "checkmark.seal")) { $0.autoApproved = true }),
            // Server 1.39: Bild über das ChatGPT-Abo erstellt (bild_erstellen) – Karte mit Vorschau im Verlauf
            Message(id: "l_b1", botId: "b_lio", role: .user,
                    text: demoText("Mach mir bitte noch ein Bild für den Launch-Post: unsere Scoops feiern mit Konfetti, im Querformat.",
                                  en: "Can you also make an image for the launch post? Our Scoops celebrating with confetti, in landscape."),
                    createdAt: ago(minutes: 30)),
            Message(id: "l_b2", botId: "b_lio", role: .status, text: "", createdAt: ago(minutes: 29.8),
                    meta: MessageMeta(runId: "r_lb1", state: "done", lines: [demoText("Erstellt ein Bild", en: "Creates an image")], usesComputer: false,
                                      model: "claude-haiku-5-5", costUsd: 0.002, startedAt: ago(minutes: 29.8),
                                      finishedAt: ago(minutes: 29.2))),
            Message(id: "l_b3", botId: "b_lio", role: .event, text: demoText("Bild erstellt: Scoops feiern den Launch.png", en: "Image created: Scoops Celebrate the Launch.png"),
                    createdAt: ago(minutes: 29.3), meta: MessageMeta(icon: "photo", fileId: "f_lio_post")),
            Message(id: "l_b4", botId: "b_lio", role: .bot,
                    text: demoText("Fertig! 🎉 Das Bild liegt in der Bibliothek und in meinem Ordner. Soll ich noch eine Hochformat-Version für Instagram machen?",
                                  en: "Done! 🎉 The image is in the Library and in my folder. Want a portrait version for Instagram too?"),
                    createdAt: ago(minutes: 29.2)),
            Message(id: "l_v6", botId: "b_lio", role: .user, text: demoText("Kannst du die Posts auch im Newsletter-Tool ankündigen?", en: "Can you announce the posts in the newsletter tool too?"),
                    createdAt: ago(minutes: 8)),
            Message(id: "l_v7", botId: "b_lio", role: .bot,
                    text: demoText("Klar! Dafür brauche ich einen Login. Trag ihn bitte unten ein, das Passwort sehe ich nicht.",
                                  en: "Sure! I’ll need a login for that. Please enter it below; I can’t see the password."),
                    createdAt: ago(minutes: 7.6)),
            Message(id: "l_v8", botId: "b_lio", role: .approval, text: demoText("Login für Newsletter-Tool", en: "Login for Newsletter Tool"),
                    createdAt: ago(minutes: 7.5),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_v3", title: demoText("Newsletter-Tool", en: "Newsletter Tool"),
                                           kind: "vault")) {
                        $0.vault = VaultForm(title: demoText("Newsletter-Tool", en: "Newsletter Tool"),
                                             url: demoText("https://newsletter.example.com/anmelden", en: "https://newsletter.example.com/login"),
                                             domain: "newsletter.example.com", username: "arman@ais-demo.example")
                    }),
        ],
        "b_nora": [
            Message(id: "n_1", botId: "b_nora", role: .event, text: demoText("Routine ausgelöst: Monatsabschluss", en: "Routine triggered: Month-End Review"),
                    createdAt: ago(minutes: 60 * 20), meta: MessageMeta(icon: "chart.bar")),
            Message(id: "n_2", botId: "b_nora", role: .bot,
                    text: demoText("Dein Oktober ist durch: **1.240 €** Ausgaben, davon 310 € für Software-Abos. Zwei Abos hast du seit Monaten nicht genutzt. Soll ich bei einem Anbieter anrufen und kündigen?",
                                  en: "October is wrapped up: **$1,240** in spending, $310 of it on software subscriptions. You haven’t used two of them in months. Want me to call one of the providers and cancel?"),
                    createdAt: ago(minutes: 60 * 20 - 1)),
            Message(id: "n_3", botId: "b_nora", role: .user, text: demoText("Ja, ruf bei der Testfirma an.", en: "Yes, call TestCo."), createdAt: ago(minutes: 30)),
            Message(id: "n_4", botId: "b_nora", role: .approval, text: demoText("Anruf: Testfirma", en: "Call: TestCo"),
                    createdAt: ago(minutes: 29.5),
                    meta: MessageMeta(state: "approved", approvalId: "a_call1",
                                      title: demoText("Anruf: Testfirma (+49 30 1234567)", en: "Call: TestCo (+1 212-555-0147)"),
                                      details: demoText("Nummer: +49 30 1234567\nKontext: Abo „Cloud Plus“, Kundennummer 4711\nZiel: Kündigung zum Monatsende bestätigen lassen",
                                                        en: "Number: +1 212-555-0147\nContext: “Cloud Plus” subscription, customer number 4711\nGoal: Get the cancellation confirmed for the end of the month"),
                                      kind: "call")),
            Message(id: "n_5", botId: "b_nora", role: .event, text: demoText("Lucy ruft an: Testfirma", en: "Lucy is calling: TestCo"),
                    createdAt: ago(minutes: 29), meta: MessageMeta(icon: "phone.connection")),
            Message(id: "n_6", botId: "b_nora", role: .event, text: demoText("Anruf beendet: Testfirma (2 min)", en: "Call ended: TestCo (2 min)"),
                    createdAt: ago(minutes: 27), meta: MessageMeta(icon: "phone.down")),
            Message(id: "n_7", botId: "b_nora", role: .bot, text: demoText("Erledigt: Die Kündigung ist bestätigt, das Abo endet zum 30. November.",
                                                                                    en: "Done: the cancellation is confirmed. The subscription ends on November 30."),
                    createdAt: ago(minutes: 26.8)),
            Message(id: "n_m1", botId: "b_nora", role: .approval, text: demoText("Mail an Steuerbüro", en: "Email to accountant"),
                    createdAt: ago(minutes: 25),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_m1", title: demoText("Mail an Steuerbüro", en: "Email to accountant"),
                                           kind: "mail")) {
                        $0.mail = MailDraft(account: demoText("privat", en: "personal"), accountEmail: "arman.privat@example.com",
                                            to: [demoText("kanzlei@steuer-demo.example", en: "office@cpa-demo.example")],
                                            subject: demoText("Belege Oktober", en: "October receipts"),
                                            body: demoText("Hallo Frau Brandt,\n\nanbei die Belege für Oktober.\n\nViele Grüße\nArman Samary",
                                                           en: "Hi Linda,\n\nAttached are my receipts for October.\n\nBest,\nArman Samary"),
                                            status: "sent", sentAt: ago(minutes: 24))
                    }),
            Message(id: "n_m2", botId: "b_nora", role: .approval, text: demoText("Mail an Musterdienst", en: "Email to SampleStream"),
                    createdAt: ago(minutes: 20),
                    meta: meta(MessageMeta(state: "declined", approvalId: "a_m2", title: demoText("Mail an Musterdienst", en: "Email to SampleStream"),
                                           kind: "mail")) {
                        $0.mail = MailDraft(account: demoText("privat", en: "personal"), accountEmail: "arman.privat@example.com",
                                            to: [demoText("kuendigung@musterdienst.example", en: "cancel@samplestream.example")],
                                            subject: demoText("Kündigung Streaming Max", en: "Cancel Streaming Max"),
                                            body: demoText("Sehr geehrte Damen und Herren,\n\nhiermit kündige ich mein Abo.",
                                                           en: "Hello,\n\nI’d like to cancel my subscription, effective immediately."),
                                            status: "discarded")
                    }),
            Message(id: "n_m3", botId: "b_nora", role: .approval, text: demoText("Mail an Buchhaltung", en: "Email to Accounting"),
                    createdAt: ago(minutes: 15),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_m3", title: demoText("Mail an Buchhaltung", en: "Email to Accounting"),
                                           kind: "mail")) {
                        $0.mail = MailDraft(account: demoText("arbeit", en: "work"), accountEmail: "arman@ais-demo.example",
                                            to: [demoText("buchhaltung@fehler.example", en: "accounting@error.example")],
                                            subject: demoText("Rechnung 2026-114", en: "Invoice 2026-114"),
                                            body: demoText("Hallo,\n\ndie Rechnung 2026-114 ist bezahlt.\n\nGruß\nArman",
                                                           en: "Hi,\n\nInvoice 2026-114 has been paid.\n\nThanks,\nArman"),
                                            status: "failed", error: demoText("Gmail hat die Adresse abgelehnt (550 Empfänger unbekannt).",
                                                                              en: "Gmail rejected the address (550 recipient unknown)."))
                    }),
            Message(id: "n_m4", botId: "b_nora", role: .approval, text: demoText("Antwort an Frau Brandt", en: "Reply to Linda Brandt"),
                    createdAt: ago(minutes: 8),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_m4", title: demoText("Antwort an Frau Brandt", en: "Reply to Linda Brandt"),
                                           kind: "mail")) {
                        $0.mail = MailDraft(account: demoText("privat", en: "personal"), accountEmail: "arman.privat@example.com",
                                            to: [demoText("kanzlei@steuer-demo.example", en: "office@cpa-demo.example")],
                                            cc: [demoText("nora.assistenz@example.com", en: "nora.assistant@example.com")],
                                            subject: demoText("Re: Belege Oktober", en: "Re: October receipts"),
                                            body: demoText("Hallo Frau Brandt,\n\ndanke für die schnelle Rückmeldung. Die fehlende Tankquittung reiche ich bis Freitag nach.\n\nViele Grüße\nArman Samary",
                                                           en: "Hi Linda,\n\nThanks for getting back to me so quickly. I’ll send the missing gas receipt by Friday.\n\nBest,\nArman Samary"),
                                            threadId: "thread_demo")
                    }),
            // Server 1.35: eigene MCP-Server im Chat verbinden (Qonto mit OAuth, Kassenbuch mit Token über die sichere Karte)
            Message(id: "n_q1", botId: "b_nora", role: .user, text: demoText("Verbinde bitte den Qonto-MCP.", en: "Please connect the Mercury MCP."), createdAt: ago(minutes: 22)),
            Message(id: "n_q2", botId: "b_nora", role: .approval, text: "", createdAt: ago(minutes: 21.8),
                    meta: meta(MessageMeta(state: "approved", approvalId: "a_mcp1", title: demoText("MCP-Server verbinden: Qonto", en: "Connect MCP server: Mercury"),
                                           details: demoText("Adresse: https://mcp.qonto.com/mcp\nAnmeldung: beim Anbieter (OAuth), danach Karte „Anmelden“\nSchreibende Werkzeuge des Servers laufen immer über Freigabe-Karten.",
                                                             en: "Address: https://mcp.mercury.com/mcp\nSign-in: with the provider (OAuth), then the “Sign In” card\nTools on this server that make changes always need an approval card."),
                                           kind: "mcp_connect")) { $0.icon = "server.rack" }),
            Message(id: "n_q3", botId: "b_nora", role: .event, text: demoText("Bei Qonto anmelden: in „Apps verbinden“ › Eigene MCP-Server",
                                                                                 en: "Sign in to Mercury: “Connect Apps” › Custom MCP Servers"),
                    createdAt: ago(minutes: 21.5),
                    meta: meta(MessageMeta(icon: "person.badge.key", kind: "mcp_login")) {
                        $0.mcpServerId = "mcp_qonto"; $0.mcpServerName = demoText("Qonto", en: "Mercury")
                    }),
            Message(id: "n_q4", botId: "b_nora", role: .event, text: demoText("Bei Qonto angemeldet · 37 Werkzeuge", en: "Signed in to Mercury · 37 tools"), createdAt: ago(minutes: 20),
                    meta: MessageMeta(icon: "checkmark.seal")),
            Message(id: "n_q5", botId: "b_nora", role: .bot,
                    text: demoText("Qonto ist verbunden. Kontostand und Buchungen kann ich jetzt direkt lesen; Überweisungen und Karten laufen nur über deine Freigabe.",
                                  en: "Mercury is connected. I can now read your balance and transactions directly; transfers and cards always need your approval."),
                    createdAt: ago(minutes: 19.8)),
            Message(id: "n_q6", botId: "b_nora", role: .user, text: demoText("Das Kassenbuch unter kasse.example.com auch, bitte.", en: "The ledger at ledger.example.com too, please."), createdAt: ago(minutes: 6)),
            Message(id: "n_q7", botId: "b_nora", role: .approval, text: "", createdAt: ago(minutes: 5.8),
                    meta: meta(MessageMeta(state: "pending", approvalId: "a_mcp2", title: demoText("MCP-Server verbinden: Kassenbuch", en: "Connect MCP server: Ledger"),
                                           details: demoText("Adresse: https://kasse.example.com/mcp\nAnmeldung: Token (Header Authorization)\nSchreibende Werkzeuge des Servers laufen immer über Freigabe-Karten.",
                                                             en: "Address: https://ledger.example.com/mcp\nSign-in: token (Authorization header)\nTools on this server that make changes always need an approval card."),
                                           kind: "mcp_connect")) {
                        $0.icon = "server.rack"
                        $0.secretFields = [MessageMeta.SecretField(key: "token", label: "Token")]
                    }),
            Message(id: "n_8", botId: "b_nora", role: .user, text: demoText("Super. Kannst du auch beim zweiten Anbieter anrufen?", en: "Great. Can you call the second provider too?"), createdAt: ago(minutes: 3),
                    meta: meta { $0.reactions = ["b_nora": "🙏", "user": "👍"] }),
            Message(id: "n_9", botId: "b_nora", role: .approval, text: demoText("Anruf: Musterdienst", en: "Call: SampleStream"),
                    createdAt: ago(minutes: 2.5),
                    meta: MessageMeta(state: "pending", approvalId: "a_call2",
                                      title: demoText("Anruf: Musterdienst (+49 221 7654321)", en: "Call: SampleStream (+1 312-555-0198)"),
                                      details: demoText("Nummer: +49 221 7654321\nKontext: Abo „Streaming Max“\nZiel: Kündigung zum nächstmöglichen Termin",
                                                        en: "Number: +1 312-555-0198\nContext: “Streaming Max” subscription\nGoal: Cancel as soon as possible"),
                                      kind: "call")),
        ],
        "b_pip": [
            Message(id: "p_1", botId: "b_pip", role: .event, text: demoText("Erinnerung angelegt: Mülltonne rausstellen", en: "Reminder set: Take out the trash"),
                    createdAt: ago(minutes: 60 * 30), meta: MessageMeta(icon: "bell")),
            Message(id: "p_2", botId: "b_pip", role: .bot, text: demoText("Kurze Erinnerung: Morgen früh wird der Biomüll abgeholt.", en: "Quick reminder: recycling gets picked up tomorrow morning."),
                    createdAt: ago(minutes: 60 * 8)),
        ],
    ]

    static let memories: [String: [Memory]] = [
        "b_mila": [
            Memory(id: "mem_1", botId: "b_mila", kind: "profil", text: demoText("Mails nie ohne Freigabe senden", en: "Never send emails without approval"), createdAt: ago(minutes: 60 * 24 * 10)),
            Memory(id: "mem_2", botId: "b_mila", kind: "profil", text: demoText("Arman mag kurze, direkte Antworten", en: "Arman likes short, direct answers"), createdAt: ago(minutes: 60 * 24 * 9)),
            Memory(id: "mem_3", botId: "b_mila", kind: "fakt", text: demoText("Jonas ist Armans Ansprechpartner für die Kampagne", en: "Jonas is Arman’s contact for the campaign"), createdAt: ago(minutes: 60 * 24 * 6)),
            Memory(id: "mem_4", botId: nil, kind: "fakt", text: demoText("Arman wohnt in Köln", en: "Arman lives in New York"), createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_5", botId: nil, kind: "fakt", text: demoText("Zeitzone: Europe/Berlin", en: "Time zone: America/New_York"), createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_6", botId: nil, kind: "fakt", text: demoText("Firma: AIS Consulting", en: "Company: AIS Consulting"), createdAt: ago(minutes: 60 * 24 * 12)),
            Memory(id: "mem_7", botId: "b_mila", kind: "tagebuch", text: demoText("Morgenbriefing geschickt, Agenda für Jonas entworfen", en: "Sent the morning briefing, drafted an agenda for Jonas"), createdAt: ago(minutes: 60 * 3)),
            Memory(id: "mem_8", botId: "b_mila", kind: "tagebuch", text: demoText("Hotelrecherche Berlin abgeschlossen (3 Vorschläge)", en: "Finished hotel research for Washington, D.C. (3 options)"), createdAt: ago(minutes: 60 * 26)),
        ],
    ]

    static let routines: [String: [Routine]] = [
        "b_mila": [
            Routine(id: "rt_1", botId: "b_mila", kind: "routine", title: demoText("Morgenbriefing", en: "Morning Briefing"), schedule: "30 7 * * 1-5",
                    scheduleText: demoText("Werktags um 7:30", en: "Weekdays at 7:30 AM"),
                    prompt: demoText("Termine, Mails, Wetter", en: "Meetings, emails, weather"), enabled: true,
                    nextRun: now.addingTimeInterval(60 * 60 * 10), lastRun: ago(minutes: 60 * 3)),
            Routine(id: "rt_2", botId: "b_mila", kind: "routine", title: demoText("Wochenrückblick", en: "Weekly Recap"), schedule: "0 18 * * 0",
                    scheduleText: demoText("Sonntags um 18:00", en: "Sundays at 6:00 PM"),
                    prompt: demoText("Was lief diese Woche?", en: "How did this week go?"), enabled: true,
                    nextRun: now.addingTimeInterval(60 * 60 * 72), lastRun: nil, model: "claude-sonnet-5-5"),
            Routine(id: "rt_3", botId: "b_mila", kind: "erinnerung", title: demoText("Steuerunterlagen an Verena", en: "Send tax documents to Rachel"), schedule: "0 9 15 11 *",
                    scheduleText: demoText("Am 15. November um 9:00", en: "November 15 at 9:00 AM"), prompt: nil, enabled: false,
                    nextRun: now.addingTimeInterval(60 * 60 * 24 * 4), lastRun: nil),
        ],
        "b_pip": [
            Routine(id: "rt_4", botId: "b_pip", kind: "erinnerung", title: demoText("Mülltonne rausstellen", en: "Take out the trash"), schedule: "0 20 * * 2",
                    scheduleText: demoText("Dienstags um 20:00", en: "Tuesdays at 8:00 PM"), prompt: nil, enabled: true, nextRun: nil, lastRun: nil),
        ],
    ]

    /// Dauerhafte Freigaben (v1.20, „Immer erlauben“)
    static let standingApprovals: [String: [StandingApproval]] = [
        "b_mila": [
            StandingApproval(id: "sa_1", botId: "b_mila", key: "freigabe:teamapp-checkouts-abhaken",
                             label: demoText("Friday Checkouts in der Team App abhaken", en: "Check off Friday checkouts in Team App"), kind: "freigabe", createdAt: ago(minutes: 60 * 24 * 9)),
            StandingApproval(id: "sa_2", botId: "b_mila", key: "mail:arman@ais-demo.example:verena@steuer-demo.example",
                             label: demoText("Mails an verena@steuer-demo.example (Konto arbeit)", en: "Emails to rachel@cpa-demo.example (work account)"), kind: "mail", createdAt: ago(minutes: 60 * 24 * 2)),
        ],
        "b_lio": [
            StandingApproval(id: "sa_3", botId: "b_lio", key: "freigabe:instagram-story-teilen",
                             label: demoText("Story auf Instagram teilen", en: "Share story on Instagram"), kind: "freigabe", createdAt: ago(minutes: 60 * 5)),
        ],
    ]

    // MARK: Gruppe (v1.1)

    static let team = ChatGroup(id: "g_team", name: demoText("Launch-Team", en: "Launch Team"), memberIds: ["b_mila", "b_theo", "b_lio"],
                                pinned: true, createdAt: ago(minutes: 60 * 24 * 2))

    /// Zweite Gruppe (nicht angepinnt, „Ohne Bereich“) für die Zeilenansicht
    static let alle = ChatGroup(id: "g_alle", name: demoText("Alle", en: "Everyone"), memberIds: ["b_mila", "b_theo", "b_lio", "b_nora", "b_pip"],
                                createdAt: ago(minutes: 60 * 24 * 4))

    static var groups: [ChatGroup] {
        var g = team
        g.lastMessage = groupMessages.last
        var a = alle
        a.lastMessage = Message(id: "ga_1", botId: "g_alle", role: .bot, text: demoText("Guten Morgen zusammen! Heute ist der Launch.", en: "Good morning, everyone! It’s launch day."),
                                createdAt: ago(minutes: 60 * 6), meta: MessageMeta(authorId: "b_lio"))
        return [g, a]
    }

    static let groupMessages: [Message] = [
        Message(id: "g_1", botId: "g_team", role: .event, text: demoText("Gruppe erstellt: Mila, Theo und Lio", en: "Group created: Mila, Theo, and Lio"),
                createdAt: ago(minutes: 60 * 26), meta: MessageMeta(icon: "person.3")),
        Message(id: "g_2", botId: "g_team", role: .user, text: demoText("@alle Wir launchen am Freitag. Wer übernimmt was?", en: "@all We’re launching Friday. Who’s taking what?"),
                createdAt: ago(minutes: 42)),
        Message(id: "g_3", botId: "g_team", role: .bot,
                text: demoText("Ich schreibe den **X-Post** und zwei Varianten für LinkedIn.", en: "I’ll write the **X post** and two versions for LinkedIn."),
                createdAt: ago(minutes: 41.5), meta: MessageMeta(authorId: "b_lio")),
        Message(id: "g_4", botId: "g_team", role: .bot,
                text: demoText("Ich sammle Vergleichszahlen zu ähnlichen Apps und lege sie in die Bibliothek.",
                              en: "I’ll gather benchmark numbers for similar apps and put them in the Library."),
                createdAt: ago(minutes: 41.2), meta: MessageMeta(authorId: "b_theo")),
        Message(id: "g_5", botId: "g_team", role: .event, text: demoText("Mila → Theo: Bitte die Zahlen bis Donnerstag ins Briefing",
                                                                                en: "Mila → Theo: Please add the numbers to the briefing by Thursday"),
                createdAt: ago(minutes: 41)),
        Message(id: "g_6", botId: "g_team", role: .status, text: "", createdAt: ago(minutes: 40.8),
                meta: MessageMeta(runId: "r_g1", state: "done", lines: [demoText("Sucht im Netz", en: "Searches the web"), demoText("Liest 6 Artikel", en: "Reads 6 articles"),
                                                                              demoText("Schreibt eine Zusammenfassung", en: "Writes a summary")],
                                  usesComputer: false, model: "claude-sonnet-5-5", costUsd: 0.009,
                                  startedAt: ago(minutes: 40.8), finishedAt: ago(minutes: 39.9), authorId: "b_theo")),
        Message(id: "g_7", botId: "g_team", role: .event, text: demoText("Theo hat eine Datei erstellt", en: "Theo created a file"),
                createdAt: ago(minutes: 39.8), meta: MessageMeta(icon: "doc.text", fileId: "f_research")),
        Message(id: "g_8", botId: "g_team", role: .user, text: demoText("Hier noch Logo und Briefing. @Mila kannst du die Agenda für Freitag bauen?",
                                                                                en: "Here’s the logo and the briefing. @Mila, can you put together the agenda for Friday?"),
                createdAt: ago(minutes: 12), meta: MessageMeta(fileIds: ["f_logo", "f_brief"])),
        Message(id: "g_9", botId: "g_team", role: .bot,
                text: demoText("Klar! Agenda steht in 10 Minuten. Logo und Briefing liegen jetzt in der Bibliothek.",
                              en: "Sure! The agenda will be ready in 10 minutes. The logo and briefing are in the Library now."),
                createdAt: ago(minutes: 11.6), meta: MessageMeta(authorId: "b_mila")),
        // Build 12: mehrere Erwähnungen (Hervorhebung in Maskottchenfarbe, Kontrast in Nacht und Hell)
        Message(id: "g_10", botId: "g_team", role: .user,
                text: demoText("@Mila du baust die Agenda, @Theo liefert die Zahlen bis Donnerstag und @Lio die Posts. Passt das?",
                              en: "@Mila, you’re on the agenda, @Theo has the numbers by Thursday, and @Lio takes the posts. Sound good?"),
                createdAt: ago(minutes: 6)),
        Message(id: "g_11", botId: "g_team", role: .bot,
                text: demoText("Passt! @Theo, schick mir die Zahlen bis Donnerstagmittag, dann baue ich sie ein. @Lio, ich verlinke deine Posts in der Agenda.",
                              en: "Sounds good! @Theo, send me the numbers by Thursday noon and I’ll work them in. @Lio, I’ll link your posts in the agenda."),
                createdAt: ago(minutes: 5.6), meta: MessageMeta(authorId: "b_mila")),
        // v1.15: Antwort auf eine Scoop-Nachricht (ohne @ antwortet der zitierte Scoop)
        Message(id: "g_12", botId: "g_team", role: .user, text: demoText("Bitte auch eine kurze Variante für Threads.", en: "Please do a short version for Threads too."),
                createdAt: ago(minutes: 4),
                meta: meta { $0.replyTo = ReplyRef(id: "g_3", role: "bot", authorId: "b_lio", authorName: "Lio",
                                                   text: demoText("Ich schreibe den X-Post und zwei Varianten für LinkedIn.",
                                                                   en: "I’ll write the X post and two versions for LinkedIn.")) }),
        Message(id: "g_13", botId: "g_team", role: .bot,
                text: demoText("Mach ich, kommt mit in den Entwurf.", en: "Will do. I’ll add it to the draft."),
                createdAt: ago(minutes: 3.7),
                meta: meta(MessageMeta(authorId: "b_lio")) {
                    $0.replyTo = ReplyRef(id: "g_12", role: "user", authorName: "Arman",
                                          text: demoText("Bitte auch eine kurze Variante für Threads.", en: "Please do a short version for Threads too."))
                }),
    ]

    // MARK: Bibliothek (v1.1)

    static let files: [String: [LibraryFile]] = [
        "g_team": [
            LibraryFile(id: "f_logo", chatId: "g_team", authorId: nil, kind: "bild", name: "Logo.png", mime: "image/png",
                        size: 182_311, url: nil, note: nil, createdAt: ago(minutes: 12), downloadUrl: "/api/files/f_logo"),
            LibraryFile(id: "f_brief", chatId: "g_team", authorId: nil, kind: "datei", name: demoText("Briefing-Launch.pdf", en: "Launch-Briefing.pdf"),
                        mime: "application/pdf", size: 482_133, url: nil, note: nil, createdAt: ago(minutes: 12), downloadUrl: "/api/files/f_brief"),
            LibraryFile(id: "f_research", chatId: "g_team", authorId: "b_theo", kind: "datei", name: demoText("Wettbewerb.md", en: "Competitors.md"),
                        mime: "text/markdown", size: 4_821, url: nil, note: nil, createdAt: ago(minutes: 39.8), downloadUrl: "/api/files/f_research"),
            LibraryFile(id: "f_link", chatId: "g_team", authorId: "b_lio", kind: "link", name: demoText("Launch-Checkliste in Notion", en: "Launch Checklist in Notion"),
                        mime: nil, size: nil, url: "https://www.notion.so", note: demoText("Checkliste für Freitag", en: "Checklist for Friday"), createdAt: ago(minutes: 60 * 20), downloadUrl: nil),
        ],
        "b_lio": [
            LibraryFile(id: "f_lio_post", chatId: "b_lio", authorId: "b_lio", kind: "bild", name: demoText("Scoops feiern den Launch.png", en: "Scoops Celebrate the Launch.png"),
                        mime: "image/png", size: 1_482_311, url: nil, note: nil, createdAt: ago(minutes: 29.3),
                        downloadUrl: "/api/files/f_lio_post"),
        ],
        "b_mila": [
            LibraryFile(id: "f_hotels", chatId: "b_mila", authorId: "b_mila", kind: "datei", name: demoText("Hotels-Koeln-Deutz.md", en: "Hotels-Boston-South-Station.md"),
                        mime: "text/markdown", size: 2_310, url: nil, note: nil, createdAt: ago(minutes: 60 * 26), downloadUrl: "/api/files/f_hotels"),
            LibraryFile(id: "f_agenda", chatId: "b_mila", authorId: nil, kind: "datei", name: "Agenda-Jonas.pdf",
                        mime: "application/pdf", size: 96_120, url: nil, note: nil, createdAt: ago(minutes: 60 * 3), downloadUrl: "/api/files/f_agenda"),
            LibraryFile(id: "f_booking", chatId: "b_mila", authorId: "b_mila", kind: "link", name: demoText("booking.com – Köln-Deutz", en: "booking.com – Boston South Station"),
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
                                      status: status, hint: status == "needs_permission"
                                          ? demoText("Auf dem Mac in AIS Scoops Server freigeben.", en: "Allow access in AIS Scoops Server on the Mac.") : nil,
                                      nodeId: "n_air")
        }
        let device = appleDevice
        return AppleStatus(nodeId: "n_air", nodeName: "MacBook Air", nodeOnline: true, nodeSource: "local", nodeChoice: "auto",
                           nodes: [AppleNode(id: "n_air", name: "MacBook Air", online: true, apple: grants),
                                   AppleNode(id: "n_minibuero", name: demoText("Mac mini Büro", en: "Office Mac mini"), online: true,
                                             apple: ["reminders": "not_determined", "calendar": "not_determined", "contacts": "not_determined"])],
                           services: [svc("reminders", demoText("Erinnerungen", en: "Reminders"), true),
                                      svc("calendar", demoText("Kalender", en: "Calendar"), all),
                                      svc("contacts", demoText("Kontakte", en: "Contacts"), all)],
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
                           name: here ? AppleDeviceAgent.shared.label : demoText("Armans iPhone", en: "Arman’s iPhone"), kind: "iphone", model: "iPhone18,2",
                           online: true, active: true, lastSeen: Date(), lastActive: nil,
                           capabilities: ["home", "alarms", "location"], permissions: perms, push: true, source: "auto")
    }

    /// Status wie der Server (apple_device.status): bereit nur mit Gerät, Freigabe und eingeschaltetem Dienst.
    static func deviceServices(_ device: AppleDevice?, enabled: [String: Bool]) -> [AppleServiceStatus] {
        [("home", "Home"), ("alarms", demoText("Wecker", en: "Alarm")), ("location", demoText("Standort", en: "Location"))].map { id, name in
            let perm = device?.permissions[id] ?? "unknown"
            let granted = id == "location" ? ["always", "when_in_use"].contains(perm) : perm == "granted"
            let on = enabled[id] ?? false
            let status = device == nil ? "no_device" : (!granted ? "needs_permission" : (on ? "ready" : "off"))
            let hint: String? = switch status {
            case "no_device": demoText("Öffne AIS Scoops auf deinem iPhone, damit es sich anmeldet.", en: "Open AIS Scoops on your iPhone so it can sign in.")
            case "needs_permission": demoText("Auf dem iPhone in AIS Scoops erlauben.", en: "Allow it in AIS Scoops on the iPhone.")
            default: nil
            }
            return AppleServiceStatus(id: id, name: name, tool: nil, enabled: on, permission: perm, available: status == "ready",
                                      status: status, hint: hint, nodeId: nil, deviceId: device?.id,
                                      background: id == "location" ? perm == "always" : nil)
        }
    }

    /// Server 1.35: eigene MCP-Server (Demo)
    static let customMCP: [CustomMCPServer] = [
        CustomMCPServer(id: "mcp_qonto", name: demoText("Qonto", en: "Mercury"), auth: "oauth", status: "ok", tools: 37, writeTools: 21,
                        url: demoText("https://mcp.qonto.com/mcp", en: "https://mcp.mercury.com/mcp")),
        CustomMCPServer(id: "mcp_kassenbuch", name: demoText("Kassenbuch", en: "Ledger"), auth: "token", status: "error",
                        error: demoText("HTTP 401 – Token abgelaufen?", en: "HTTP 401: token expired?"), tools: 0,
                        url: demoText("https://kasse.example.com/mcp", en: "https://ledger.example.com/mcp"), header: "Authorization"),
        CustomMCPServer(id: "mcp_notizen", name: demoText("Notizen lokal", en: "Local Notes"), kind: "stdio", status: "ok", tools: 4, writeTools: 1,
                        command: demoText("/usr/local/bin/notizen-mcp --stdio", en: "/usr/local/bin/notes-mcp --stdio"),
                        envKeys: [demoText("NOTIZEN_KEY", en: "NOTES_KEY")]),
    ]

    static let connections = ConnectionsOverview(maxPerApp: 10, apps: [
        ConnectableApp(slug: "gmail", name: "Gmail", detail: demoText("Mails lesen, Entwürfe schreiben und senden", en: "Read email, write and send drafts"),
                       symbol: "envelope.fill",
                       accounts: [
                        ConnectedAccount(id: "ca_g1", app: "gmail", alias: demoText("privat", en: "personal"), email: "arman.privat@example.com", status: "active"),
                        ConnectedAccount(id: "ca_g2", app: "gmail", alias: demoText("arbeit", en: "work"), email: "arman@ais-demo.example", status: "active"),
                        ConnectedAccount(id: "ca_g3", app: "gmail", alias: "newsletter", email: "news@ais-demo.example", status: "expired"),
                       ]),
        ConnectableApp(slug: "notion", name: "Notion", detail: demoText("Seiten und Datenbanken lesen und pflegen", en: "Read and maintain pages and databases"),
                       symbol: "doc.text.fill",
                       accounts: [ConnectedAccount(id: "ca_n1", app: "notion", alias: nil, email: "AIS Workspace", status: "active")]),
        ConnectableApp(slug: "googlecalendar", name: demoText("Google Kalender", en: "Google Calendar"),
                       detail: demoText("Termine lesen und anlegen", en: "Read and create events"), symbol: "calendar",
                       accounts: [ConnectedAccount(id: "ca_c1", app: "googlecalendar", alias: demoText("arbeit", en: "work"), email: nil, status: "initiated")]),
        ConnectableApp(slug: "googledrive", name: "Google Drive", detail: demoText("Dateien suchen, lesen und ablegen", en: "Search, read, and store files"),
                       symbol: "externaldrive.fill"),
        ConnectableApp(slug: "googlesheets", name: "Google Sheets", detail: demoText("Tabellen lesen und bearbeiten", en: "Read and edit spreadsheets"),
                       symbol: "tablecells.fill"),
        ConnectableApp(slug: "slack", name: "Slack", detail: demoText("Nachrichten lesen und schreiben", en: "Read and write messages"), symbol: "number"),
        ConnectableApp(slug: "github", name: "GitHub", detail: demoText("Issues und Pull Requests", en: "Issues and pull requests"), symbol: "chevron.left.forwardslash.chevron.right"),
    ], builtin: [
        BuiltinConnection(id: "teamapp", name: "Team App", detail: demoText("MLP-Team-Daten lesen und schreiben", en: "Read and write team data"), symbol: "person.3.fill", status: "ok", tools: 121),
        BuiltinConnection(id: "atrium", name: demoText("Atrium lokal", en: "Atrium Local"),
                          detail: demoText("Kundendaten auf dem Air", en: "Client data on the Air"), symbol: "building.columns.fill", status: "ok", tools: 18),
        BuiltinConnection(id: "atrium_berlin", name: demoText("Atrium Team Berlin", en: "Atrium Team New York"),
                          detail: demoText("Team-Daten Berlin", en: "New York team data"), symbol: "building.2.fill", status: "ok", tools: 18),
        BuiltinConnection(id: "atrium_koeln", name: demoText("Atrium Team Köln", en: "Atrium Team Boston"),
                          detail: demoText("Team-Daten Köln", en: "Boston team data"), symbol: "building.2.fill", status: "error", tools: 0),
        BuiltinConnection(id: "t3", name: "T3 Code", detail: demoText("Programmieraufgaben abgeben", en: "Hand off coding tasks"), symbol: "hammer.fill", status: "ok", tools: 5),
        BuiltinConnection(id: "lucy", name: demoText("Lucy Telefonie", en: "Lucy Phone"),
                          detail: demoText("Anrufe führen lassen", en: "Make calls for you"), symbol: "phone.fill", status: "off"),
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
            app("gmail", "Gmail", demoText("Mails lesen, Entwürfe schreiben, senden", en: "Read, draft, and send email"), ["communication"], symbol: "envelope.fill", popular: true),
            app("googlecalendar", demoText("Google Kalender", en: "Google Calendar"), demoText("Termine lesen und anlegen", en: "Read and create events"), ["productivity"], symbol: "calendar", popular: true),
            app("outlook", "Outlook", demoText("Microsoft-Mail und -Kalender", en: "Microsoft email and calendar"), ["communication"], symbol: "envelope.badge.fill", popular: true),
            app("notion", "Notion", demoText("Seiten und Datenbanken, z. B. Tasks", en: "Pages and databases, such as tasks"), ["productivity"], symbol: "doc.text.fill", popular: true),
            app("googledrive", "Google Drive", demoText("Dateien finden und ablegen", en: "Find and store files"), ["productivity"], symbol: "externaldrive.fill", popular: true),
            app("googlesheets", "Google Sheets", demoText("Tabellen lesen und füllen", en: "Read and fill in spreadsheets"), ["productivity"], symbol: "tablecells.fill", popular: true),
            app("googledocs", "Google Docs", demoText("Dokumente lesen und schreiben", en: "Read and write documents"), ["productivity"], symbol: "doc.richtext.fill", popular: true),
            app("slack", "Slack", demoText("Nachrichten lesen und schreiben", en: "Read and write messages"), ["communication"], symbol: "number", popular: true),
            app("github", "GitHub", demoText("Repos, Issues, Pull Requests", en: "Repos, issues, pull requests"), ["development"],
                symbol: "chevron.left.forwardslash.chevron.right", popular: true),
            app("linkedin", "LinkedIn", demoText("Profil und Beiträge", en: "Profile and posts"), ["marketing"], symbol: "person.crop.square.fill", popular: true),
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
            // Englisch: amerikanisches Gegenstück zu Lexoffice
            AppLanguage.isGerman ? app("lexoffice", "Lexoffice", "Buchhaltung und Rechnungen für kleine Unternehmen.", ["finance"], .fields)
                : app("quickbooks", "QuickBooks", "Accounting and invoicing for small businesses.", ["finance"], .fields),
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
                                description: demoText("Deinen \(app.name)-Schlüssel findest du in den Einstellungen unter „API Keys“.",
                                                     en: "You’ll find your \(app.name) key in its settings under “API Keys.”"),
                                secret: true)]
        if app.slug == "freshdesk" || app.slug == "posthog" {
            fields.insert(AuthField(name: "subdomain", label: app.slug == "posthog" ? "Region" : "Subdomain",
                                    description: app.slug == "posthog" ? demoText("eu oder us", en: "eu or us")
                                        : demoText("Der Teil vor .freshdesk.com, z. B. „acme“.", en: "The part before .freshdesk.com, like “acme.”"),
                                    secret: false), at: 0)
        }
        return AppAuthInfo(slug: app.slug, name: app.name, auth: "fields", scheme: "API_KEY", fields: fields,
                           guideUrl: "https://example.com/\(app.slug)/api-keys")
    }

    // MARK: Bereiche (v1.6): „Privat“ eingeklappt, „Ideen“ leer

    static let sections: [SidebarSection] = [
        SidebarSection(name: demoText("Arbeit", en: "Work")),
        SidebarSection(name: demoText("Privat", en: "Personal"), collapsed: true),
        SidebarSection(name: demoText("Ideen", en: "Ideas")),
    ]

    // MARK: Initiative, Fähigkeiten, Tresor (v1.4)

    static let initiative = InitiativeSettings(enabled: true, times: ["07:30", "12:30", "17:30"],
                                               quietStart: "22:00", quietEnd: "07:00", primaryBotId: "b_mila")

    static let skills: [Skill] = [
        Skill(id: "sk_hotel", botId: "b_mila", name: demoText("Hotelsuche Köln", en: "Boston Hotel Search"),
              description: demoText("Passende Hotels für Termine in Köln finden und vergleichen.",
                                    en: "Find and compare hotels near your meetings in Boston."),
              steps: demoText("1. Termin und Ort aus dem Kalender holen\n2. Auf booking.com nach Hotels in der Nähe suchen (max. 140 €)\n3. Drei Vorschläge mit Preis und Weg zum Termin schicken\n4. Erst nach Freigabe buchen",
                              en: "1. Get the meeting time and place from the calendar\n2. Search booking.com for nearby hotels ($250 max)\n3. Send three options with price and distance to the meeting\n4. Book only after approval"),
              uses: 4, lastUsed: ago(minutes: 2), createdAt: ago(minutes: 60 * 24 * 6)),
        Skill(id: "sk_agenda", botId: "b_mila", name: demoText("Agenda für Calls", en: "Call Agenda"),
              description: demoText("Kurze Agenda aus Mails und Notizen bauen und als Entwurf vorbereiten.",
                                    en: "Build a short agenda from emails and notes and save it as a draft."),
              steps: demoText("1. Letzte Mails mit der Person lesen\n2. Offene Punkte sammeln (max. 3)\n3. Mail-Entwurf schreiben\n4. Freigabe-Karte schicken",
                              en: "1. Read recent emails with the person\n2. Collect open items (3 max)\n3. Write an email draft\n4. Send an approval card"),
              uses: 2, lastUsed: ago(minutes: 60 * 3), createdAt: ago(minutes: 60 * 24 * 3)),
        Skill(id: "sk_login", botId: nil, name: demoText("Anmeldung mit Tresor-Eintrag", en: "Sign In with Vault Entry"),
              description: demoText("Auf einer Webseite mit gespeicherten Zugangsdaten anmelden.",
                                    en: "Sign in to a website with saved credentials."),
              steps: demoText("1. Seite im Browser öffnen\n2. Passenden Tresor-Eintrag zur Domain wählen\n3. Mit „login_ausfuellen“ Benutzername und Passwort eintragen lassen\n4. Prüfen, ob die Anmeldung geklappt hat",
                              en: "1. Open the page in the browser\n2. Pick the Vault entry that matches the domain\n3. Fill in username and password with “login_ausfuellen”\n4. Check that the sign-in worked"),
              uses: 7, lastUsed: ago(minutes: 60 * 26), createdAt: ago(minutes: 60 * 24 * 9)),
    ]

    static let vault: [VaultEntry] = [
        VaultEntry(id: "v_demo1", title: demoText("Übungsseite", en: "Practice Site"), url: "https://the-internet.herokuapp.com/login",
                   domain: "the-internet.herokuapp.com", username: "tomsmith", note: demoText("Nur zum Testen", en: "For testing only"),
                   hasPassword: true, lastUsed: ago(minutes: 60 * 26), createdAt: ago(minutes: 60 * 24 * 9)),
        VaultEntry(id: "v_demo2", title: demoText("Beispiel-Shop", en: "Sample Shop"),
                   url: demoText("https://shop.example.com/konto", en: "https://shop.example.com/account"),
                   domain: "shop.example.com", username: "arman@example.com", note: "",
                   hasPassword: true, lastUsed: nil, createdAt: ago(minutes: 60 * 24 * 2)),
    ]

    /// Modellkatalog wie vom Server 1.34 (GET /api/models, gekürzt)
    static let modelCatalog = ModelCatalog(
        version: 2026111801, source: "bundled",
        models: [
            .init(id: "claude-haiku-5-5", label: "Haiku 5.5", provider: "anthropic", hint: demoText("Schnell & günstig", en: "Fast & affordable"), rank: 10,
                  available: true),
            .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: "anthropic", hint: demoText("Stärker", en: "Stronger"), rank: 20, available: true),
            .init(id: "claude-opus-5-5", label: "Opus 5.5", provider: "anthropic", hint: demoText("Sehr stark, teuer", en: "Very strong, expensive"), rank: 30, available: true),
            .init(id: "claude-fable-5-2", label: "Fable 5.2", provider: "anthropic", hint: demoText("Am stärksten, sehr teuer", en: "Strongest, very expensive"), rank: 40,
                  available: true),
            .init(id: "gpt-6-luna", label: "GPT-6 Luna", provider: "openai", hint: demoText("Schnell & sehr günstig", en: "Fast & very affordable"), rank: 10, available: true),
            .init(id: "gpt-6.1-terra", label: "GPT-6.1 Terra", provider: "openai", hint: demoText("Ausgewogen & günstig", en: "Balanced & affordable"), rank: 20, available: true),
            .init(id: "gpt-6.2-sol", label: "GPT-6.2 Sol", provider: "openai", hint: demoText("Stark, Allrounder", en: "Strong all-rounder"), rank: 30, available: true),
            .init(id: "gpt-6.2-astra", label: "GPT-6.2 Astra", provider: "openai", hint: demoText("Am stärksten, teuer", en: "Strongest, expensive"), rank: 40, available: true),
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
