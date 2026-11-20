import Foundation

// MARK: - Scoop-Vorlagen im Demo-Modus (`-mock`)

/// Beispielvorlage für den Demo-Modus (`-templatedemo`), inhaltlich wie docs/vorlagen/Morgenbriefing.scoop.
enum MockTemplates {
    static let sample = ScoopTemplate(
        name: "Mona", label: demoText("Morgenbriefing", en: "Morning Briefing"),
        description: demoText("Fasst jeden Werktag um 7:30 zusammen, was heute ansteht: Termine, wichtige Mails und offene Aufgaben.",
                              en: "Sums up your day every weekday at 7:30 AM: meetings, important emails, and open tasks."),
        appearance: {
            var m = Mascot(shape: "circle", color: "#FBBA10", eyes: "lashes", accessory: "headset")
            m.gaze = "right"; m.mouth = "smile"
            return ScoopTemplate.Appearance(mascot: m)
        }(),
        character: demoText("""
            Du bist ruhig, freundlich und kommst sofort zum Punkt. Du duzt.

            Deine Aufgabe ist der Überblick am Morgen. Schreib kurz: höchstens fünf Punkte, das Wichtigste zuerst, \
            jeder Punkt ein Satz.

            Regeln:
            - Du liest nur. Du verschickst nichts und änderst nichts, ohne vorher zu fragen.
            - Werbung, Newsletter und automatische Benachrichtigungen lässt du weg.
            - Wenn nichts Wichtiges ansteht, sagst du das in einem Satz.
            """, en: """
            You’re calm, friendly, and get straight to the point. Keep it casual.

            Your job is the morning overview. Keep it short: five points at most, the most important first, \
            one sentence each.

            Rules:
            - You only read. You don’t send or change anything without asking first.
            - Leave out ads, newsletters, and automated notifications.
            - If nothing important is coming up, say so in one sentence.
            """),
        model: "claude-haiku-5-5",
        skills: [.init(name: demoText("Tagesüberblick schreiben", en: "Write Daily Overview"),
                       description: demoText("Aufbau des Morgenbriefings", en: "How the morning briefing is structured"),
                       steps: demoText("1. Termine von heute aus dem Kalender holen.\n2. Ungelesene Mails seit gestern Abend durchsehen.\n3. Briefing schreiben: zuerst der erste Termin, dann höchstens vier weitere Punkte.",
                                       en: "1. Pull today’s meetings from the calendar.\n2. Check unread emails since last night.\n3. Write the briefing: lead with the first meeting, then add up to four more points."))],
        routines: [.init(title: demoText("Morgenbriefing", en: "Morning Briefing"), schedule: "30 7 * * 1-5",
                         scheduleText: demoText("Werktags um 7:30", en: "Weekdays at 7:30 AM"),
                         prompt: demoText("Schreib das Morgenbriefing für heute. Nutze die Fähigkeit „Tagesüberblick schreiben“.",
                                          en: "Write today’s morning briefing using the “Write Daily Overview” skill.")),
                   .init(title: demoText("Wochenrückblick", en: "Weekly Recap"), schedule: "0 16 * * 5",
                         scheduleText: demoText("Fr um 16:00", en: "Fri at 4:00 PM"),
                         prompt: demoText("Fasse die Woche in höchstens fünf Punkten zusammen: Was ist erledigt, was ist offen geblieben?",
                                          en: "Sum up the week in five points at most: what got done, and what’s still open?"))],
        requires: [.init(kind: "app", id: "gmail", name: "Gmail", note: demoText("Zum Lesen der Mails.", en: "To read your email.")),
                   .init(kind: "app", id: "googlecalendar", name: demoText("Google Kalender", en: "Google Calendar"),
                         note: demoText("Für die Termine des Tages.", en: "For the day’s meetings."))])

    static var sampleFile: Data { (try? sample.fileData()) ?? Data() }

    /// Grobe Häufigkeit für die Vorschau: „*/5 * * * *“ → 288 Läufe pro Tag (der Server rechnet genau)
    static func runsPerDay(_ cron: String) -> Double? {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }
        if parts[1] == "*" {
            if parts[0] == "*" { return 1440 }
            if parts[0].hasPrefix("*/"), let n = Double(parts[0].dropFirst(2)), n > 0 { return (1440 / n).rounded() }
            return 24
        }
        if parts[1].hasPrefix("*/"), let n = Double(parts[1].dropFirst(2)), n > 0 { return (24 / n).rounded() }
        if parts[4] == "1-5" { return 0.71 }
        return parts[4] == "*" && parts[2] == "*" ? 1 : 0.14
    }

    /// Verbindungen, die in den Texten eines Demo-Scoops vorkommen
    static func requirements(in text: String) -> [ScoopTemplate.Requirement] {
        let known: [(String, String, [String])] = [
            // Englische Stichwörter nur auf Englisch, damit sich auf Deutsch nichts ändert
            ("gmail", "Gmail", ["gmail", "mail"]),
            ("googlecalendar", demoText("Google Kalender", en: "Google Calendar"),
             ["kalender", "termin"] + (AppLanguage.isGerman ? [] : ["calendar", "meeting"])),
            ("notion", "Notion", ["notion"]), ("slack", "Slack", ["slack"]),
        ]
        let lower = text.lowercased()
        return known.filter { $0.2.contains { lower.contains($0) } }
            .map { ScoopTemplate.Requirement(kind: "app", id: $0.0, name: $0.1, note: nil) }
    }
}

extension MockService: TemplateService {
    func exportTemplate(botID: String) async throws -> TemplateExport {
        try? await Task.sleep(for: .milliseconds(350))
        guard let bot = demoBot(botID) else { throw APIError(status: 404, message: demoText("Scoop nicht gefunden.", en: "Scoop not found.")) }
        let all = demoSkills(botID)
        func item(_ s: Skill) -> ScoopTemplate.SkillItem { .init(name: s.name, description: s.description, steps: s.steps ?? "") }
        let routines = demoRoutines(botID).filter { $0.kind == "routine" }.map {
            ScoopTemplate.RoutineItem(title: $0.title, schedule: $0.schedule ?? "0 7 * * *", scheduleText: $0.scheduleText,
                                      prompt: $0.prompt ?? $0.title, model: $0.model)
        }
        let own = all.filter { $0.botId == botID }.map(item)
        let texts = [bot.character ?? ""] + own.map { "\($0.description ?? "") \($0.steps)" } + routines.map(\.prompt)
        var mascot = bot.mascot
        mascot.photo = nil
        let template = ScoopTemplate(name: bot.name, label: bot.label, appearance: .init(mascot: mascot),
                                     character: bot.character, model: bot.model, skills: own, routines: routines,
                                     requires: MockTemplates.requirements(in: texts.joined(separator: "\n")))
        var warnings: [TemplateExport.Warning] = []
        if texts.contains(where: { $0.contains("Arman") }) {
            warnings.append(.init(where: demoText("Charakter und Anweisungen", en: "Personality and instructions"),
                                  text: demoText("Die Texte enthalten den Namen „Arman“.", en: "The text includes the name “Arman.”")))
        }
        let photo = demoAvatar(botID).map { ScoopTemplate.Appearance.Photo(mime: "image/jpeg", data: $0.base64EncodedString()) }
        return TemplateExport(template: template,
                              optional: .init(skills: all.filter { $0.botId == nil }.map(item), photo: photo),
                              warnings: warnings, fileName: ScoopTemplate.fileName(for: bot.name))
    }

    func checkTemplate(_ data: Data) async throws -> TemplateCheck {
        try? await Task.sleep(for: .milliseconds(450))
        guard var template = try? JSONCoding.makeDecoder().decode(ScoopTemplate.self, from: data),
              template.type == ScoopTemplate.typeID,
              !template.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError(status: 400, message: demoText("Das ist keine Scoop-Vorlage.", en: "This isn’t a Scoop template."))
        }
        guard template.format <= ScoopTemplate.currentFormat else {
            throw APIError(status: 400, message: demoText("Diese Vorlage wurde mit einer neueren Version von AIS Scoops erstellt (Format \(template.format)).",
                                                           en: "This template was created with a newer version of AIS Scoops (format \(template.format))."))
        }
        let connected = demoConnectedApps
        template.routines = template.routines.map { var r = $0; r.runsPerDay = MockTemplates.runsPerDay($0.schedule); return r }
        template.requires = template.requires.map { item in
            var q = item
            q.status = item.kind == "app" ? (connected.contains(item.id ?? "") ? "connected" : "missing") : "unknown"
            return q
        }
        var notes = [demoText("Der Scoop startet mit den Standardrechten und ohne dauerhafte Freigaben.",
                              en: "The Scoop starts with default permissions and no standing approvals.")]
        if !template.routines.isEmpty {
            notes.append(demoText("Routinen werden pausiert angelegt. Du schaltest sie im Profil ein.",
                                  en: "Routines start out paused. Turn them on in the profile."))
        }
        return TemplateCheck(template: template,
                             model: template.model.map { .init(id: $0, available: true, default: BotModel.haiku.rawValue) },
                             notes: notes)
    }

    func importTemplate(_ request: TemplateImportRequest) async throws -> TemplateImportResult {
        try? await Task.sleep(for: .milliseconds(900))
        let t = request.template
        let id = demoID("b")
        var mascot = t.appearance?.mascot ?? .default
        let photo = request.usePhoto ? t.appearance?.photoData : nil
        if photo != nil { mascot.photo = MascotPhoto(id: id, version: Int(Date().timeIntervalSince1970)) }
        var bot = Bot(id: id, name: request.name, label: t.label, mascot: mascot, character: t.character,
                      model: request.useModel ? (t.model ?? BotModel.haiku.rawValue) : BotModel.haiku.rawValue,
                      createdAt: Date())
        bot.mute = .off
        let routines = request.routines.filter { t.routines.indices.contains($0) }.map { i -> Routine in
            let r = t.routines[i]
            // Pausiert: Routinen aus einer Vorlage laufen erst, wenn man sie einschaltet
            return Routine(id: demoID("rt"), botId: id, kind: "routine", title: r.title, schedule: r.schedule,
                           scheduleText: r.scheduleLine, prompt: r.prompt, enabled: false,
                           nextRun: Date().addingTimeInterval(86_400), lastRun: nil, model: request.useModel ? r.model : nil)
        }
        let skills = request.skills.filter { t.skills.indices.contains($0) }.map { i -> Skill in
            let s = t.skills[i]
            return Skill(id: demoID("sk"), botId: id, name: s.name, description: s.description, steps: s.steps, createdAt: Date())
        }
        // Wie die Ereigniszeile des Servers (Deutsch unverändert, Englisch wie i18n_en)
        let n = routines.count
        var hint = demoText("\(bot.name) ist da (aus einer Vorlage)", en: "\(bot.name) is here (from a template)")
        if !routines.isEmpty {
            hint += demoText(" · \(n) \(n == 1 ? "Routine" : "Routinen") pausiert", en: " · \(n) \(n == 1 ? "routine" : "routines") paused")
        }
        let first = Message(id: demoID("m"), botId: id, role: .event, text: hint, createdAt: Date())
        bot.lastMessage = first
        demoAdd(bot: bot, routines: routines, skills: skills, avatar: photo, first: first)
        return TemplateImportResult(bot: bot, skills: skills.count, routines: routines.count)
    }
}
