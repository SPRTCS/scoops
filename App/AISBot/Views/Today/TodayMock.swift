import Foundation

// MARK: - Demo-Daten für die Seite „Heute“ (`-mock`)

extension MockService: TodayService {
    /// Wie `GET /api/today`: offene Freigaben aus den Demo-Chats, Aufgaben aus dem Demo-Board, laufende Chat-Läufe,
    /// heute fällige und gelaufene Routinen. `-heuteleer` zeigt die Seite ohne Inhalt.
    func todayOverview(since: Date?) async throws -> TodayOverview {
        let src = todaySource
        guard !src.isGuest else { throw APIError(status: 403, message: demoText("Kein Zugriff: Dieser Bereich gehört dem Admin des Servers.", en: "No access: this section belongs to the server admin.")) }
        let now = PreviewData.clock
        let day = now.addingTimeInterval(-24 * 3600)
        let start = since.map { $0 < day ? max($0, now.addingTimeInterval(-7 * 86_400)) : day } ?? day
        if TodayStore.demoEmpty {
            return TodayOverview(since: start, approvals: [], tasks: [], running: [], planned: [], routinesDone: [])
        }

        // Offene Freigaben; eine davon stammt aus einer Hintergrund-Aufgabe
        var approvals: [TodayApproval] = []
        for list in src.messages.values {
            for m in list where m.isPendingApproval && m.meta.guestView != true {
                guard var a = TodayApproval(message: m) else { continue }
                if a.id == "a_2", let task = MockTaskStore.shared.tasks.first(where: { $0.id == "t_post" }) {
                    a.taskId = task.id
                    a.taskTitle = task.title
                    a.expiresAt = nil
                }
                approvals.append(a)
            }
        }
        approvals.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let tasks = MockTaskStore.shared.tasks.filter { t in
            switch t.boardColumn {
            case .active, .review: return true
            case .planned: return t.scheduledAt.map { $0 <= endOfDay } ?? false
            case .done: return t.finishedAt.map { $0 >= start } ?? false
            case .open, .archived: return false
            }
        }

        // Chat-Läufe: neueste laufende Statuszeile eines Scoops, der gerade arbeitet
        var running: [TodayRun] = []
        for bot in src.bots where bot.busy {
            guard let m = src.messages[bot.id]?.last(where: { $0.role == .status }), m.isRunning, m.meta.task == nil else { continue }
            running.append(TodayRun(chatId: bot.id, botId: bot.id, runId: m.meta.runId, messageId: m.id,
                                    line: m.meta.lines?.last, steps: m.meta.lines?.count,
                                    startedAt: m.meta.startedAt ?? m.createdAt, usesComputer: m.meta.usesComputer))
        }

        // Heute geplant: Routinen mit Lauf bis Mitternacht, dazu drei feste Beispiele (nur was noch vor uns liegt)
        var planned = src.routines.filter { $0.enabled }.compactMap { r -> TodayPlanned? in
            guard let at = r.nextRun, at <= endOfDay else { return nil }
            return TodayPlanned(id: r.id, kind: r.kind, botId: r.botId, title: r.title, at: at,
                                scheduleText: r.scheduleText, moreToday: 0)
        }
        func today(_ hour: Int, _ minute: Int) -> Date? {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: now).flatMap { $0 > now ? $0 : nil }
        }
        let nextHour = cal.date(byAdding: .hour, value: 1, to: cal.date(bySetting: .minute, value: 0, of: now) ?? now)
        if let at = nextHour.flatMap({ cal.dateInterval(of: .hour, for: $0)?.start }), at > now, at < endOfDay,
           cal.component(.hour, from: at) <= 18 {
            planned.append(TodayPlanned(id: "rt_demo", kind: "routine", botId: "b_mila", title: demoText("Mail-Check", en: "Email Check"), at: at,
                                        scheduleText: demoText("Stündlich von 8 bis 18 Uhr", en: "Hourly from 8 AM to 6 PM"), moreToday: 18 - cal.component(.hour, from: at)))
        }
        if let at = today(18, 30) {
            planned.append(TodayPlanned(id: "rt_abend", kind: "routine", botId: "b_theo", title: demoText("Abendbericht Wettbewerb", en: "Evening Competitor Report"),
                                        at: at, scheduleText: demoText("Täglich um 18:30", en: "Daily at 6:30 PM"), moreToday: 0))
        }
        if let at = today(20, 0), cal.component(.weekday, from: now) == 3 {  // Erinnerung „Dienstags um 20:00“
            planned.append(TodayPlanned(id: "rt_4", kind: "erinnerung", botId: "b_pip", title: demoText("Mülltonne rausstellen", en: "Take out the trash"),
                                        at: at, scheduleText: demoText("Dienstags um 20:00", en: "Tuesdays at 8:00 PM"), moreToday: 0))
        }
        if let at = today(23, 30) {
            planned.append(TodayPlanned(id: "rt_tag", kind: "routine", botId: "b_mila", title: demoText("Tagesrückblick", en: "Daily Recap"),
                                        at: at, scheduleText: demoText("Täglich um 23:30", en: "Daily at 11:30 PM"), moreToday: 0))
        }
        planned.sort { $0.at < $1.at }

        let done = src.routines.compactMap { r -> TodayRoutineDone? in
            guard let at = r.lastRun, at >= start else { return nil }
            return TodayRoutineDone(id: r.id, kind: r.kind, botId: r.botId, title: r.title, at: at)
        }.sorted { $0.at > $1.at }

        return TodayOverview(since: start, approvals: approvals, tasks: tasks, running: running, planned: planned,
                             routinesDone: done)
    }
}
