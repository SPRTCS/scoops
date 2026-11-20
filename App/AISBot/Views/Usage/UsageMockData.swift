import Foundation

/// Demo-Modus (`-mock`): realistische Nutzung (Größenordnung wie auf Armans Server), damit die Seite im Simulator ohne
/// Server vollständig aussieht. Werte sind deterministisch (gleiche Bilder bei jedem Start).
enum UsageMockData {
    private struct ModelSpec {
        let id: String, label: String, provider: UsageProvider
        let share: Double  // Anteil an den Kosten des Anbieters
        let pIn: Double, pOut: Double, pRead: Double, pWrite: Double
    }

    private static let models: [ModelSpec] = [
        .init(id: "claude-opus-5-5", label: "Opus 5.5", provider: .claude, share: 0.66, pIn: 4, pOut: 20, pRead: 0.2, pWrite: 5),
        .init(id: "claude-fable-5-2", label: "Fable 5.2", provider: .claude, share: 0.29, pIn: 8, pOut: 40, pRead: 0.2, pWrite: 10),
        .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", provider: .claude, share: 0.04, pIn: 2, pOut: 10, pRead: 0.1, pWrite: 2.5),
        .init(id: "claude-haiku-5-5", label: "Haiku 5.5", provider: .claude, share: 0.01, pIn: 0.1, pOut: 0.5, pRead: 0.01, pWrite: 0.125),
        .init(id: "gpt-6.2-astra", label: "GPT-6.2 Astra", provider: .openai, share: 0.9, pIn: 8, pOut: 40, pRead: 0.4, pWrite: 8),
        .init(id: "gpt-6.2-sol", label: "GPT-6.2 Sol", provider: .openai, share: 0.07, pIn: 2, pOut: 10, pRead: 0.1, pWrite: 2),
        .init(id: "gpt-6.1-terra", label: "GPT-6.1 Terra", provider: .openai, share: 0.03, pIn: 1, pOut: 5, pRead: 0.05, pWrite: 1.25),
    ]

    /// Kostenanteile nach Typ (wie in echten Protokollen: Cache lesen dominiert)
    private static let typeShare = (input: 0.08, cacheRead: 0.6, cacheWrite: 0.15, output: 0.17)

    private static func noise(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 2654435761 &+ salt &* 40503 &+ 12345)
        x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
        return Double(x % 10_000) / 10_000
    }

    /// Tokens zu einem Betrag (grobe Umrechnung über die Typen und Preise des Modells)
    private static func tokens(for cost: Double, _ m: ModelSpec) -> (input: Int, read: Int, write: Int, output: Int) {
        let i = cost * typeShare.input / m.pIn * 1e6
        let r = cost * typeShare.cacheRead / m.pRead * 1e6
        let w = cost * typeShare.cacheWrite / m.pWrite * 1e6
        let o = cost * typeShare.output / m.pOut * 1e6
        return (Int(i), Int(r), Int(w), Int(o))
    }

    static func details(range: String, source: String) -> UsageDetails {
        let r = UsageRange(rawValue: range) ?? .month
        let hourly = r == .day
        let n = hourly ? 24 : (r == .week ? 7 : (r == .month ? 30 : 90))
        let cal = Calendar(identifier: .gregorian)
        let now = PreviewData.clock
        let scoopsShare = source == "scoops" ? 1.0 : (source == "other" ? 0.0 : 0.015)
        let factor = source == "scoops" ? 0.015 : (source == "other" ? 0.985 : 1.0)

        var series: [UsageDetails.Point] = []
        var claudeTotal = 0.0, openaiTotal = 0.0
        for i in 0..<n {
            let back = n - 1 - i
            let date = hourly ? cal.date(byAdding: .hour, value: -back, to: now)! : cal.date(byAdding: .day, value: -back, to: now)!
            let wave = 0.55 + 0.45 * sin(Double(i) / (hourly ? 3.5 : 4.2)) + noise(i, 7) * 0.9
            let quiet = !hourly && noise(i, 3) < 0.08
            var c = (hourly ? 9.5 : 165) * max(0.05, wave + (i > n * 2 / 3 ? 0.9 : 0)) * (quiet ? 0.04 : 1)
            var o = (hourly ? 2.4 : 62) * max(0.05, 0.4 + noise(i, 11) * 1.6) * (quiet ? 0.1 : 1)
            if hourly {
                let h = cal.component(.hour, from: date)
                if h < 7 { c *= 0.08; o *= 0.1 }  // nachts kaum Betrieb
            }
            c *= factor; o *= factor
            claudeTotal += c; openaiTotal += o
            let ct = Int(c * 285_000), ot = Int(o * 85_000)
            let key = hourly ? date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false))
                             : date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            // Achsenbeschriftung wie der Server (englisch „9:00“ bzw. „11/20“)
            let hour = cal.component(.hour, from: date), day = cal.component(.day, from: date), month = cal.component(.month, from: date)
            let label = hourly ? demoText("\(hour) Uhr", en: "\(hour):00")
                               : demoText("\(day).\(month).", en: "\(month)/\(day)")
            series.append(.init(key: key, label: label, costUsd: c + o, tokens: ct + ot,
                                claude: .init(costUsd: c, tokens: ct, apiUsd: c * scoopsShare * 0.6),
                                openai: .init(costUsd: o, tokens: ot, apiUsd: o * scoopsShare * 0.6)))
        }
        let total = claudeTotal + openaiTotal
        let apiUsd = total * scoopsShare * 0.6

        var modelRows: [UsageDetails.Row] = []
        var tIn = 0, tRead = 0, tWrite = 0, tOut = 0
        for m in models {
            let cost = (m.provider == .claude ? claudeTotal : openaiTotal) * m.share
            let t = tokens(for: cost, m)
            tIn += t.input; tRead += t.read; tWrite += t.write; tOut += t.output
            let tok = t.input + t.read + t.write + t.output
            modelRows.append(.init(id: m.id, label: m.label, provider: m.provider.rawValue, costUsd: cost,
                                   apiUsd: cost * scoopsShare * 0.6, aboUsd: cost * (1 - scoopsShare * 0.6), tokens: tok,
                                   input: t.input, output: t.output, cacheRead: t.read, cacheWrite: t.write,
                                   requests: Int(cost * 6)))
        }
        let tokTotal = tIn + tRead + tWrite + tOut
        modelRows = modelRows.map { var r = $0; r.shareCost = r.costUsd / total; r.shareTokens = Double(r.tokens) / Double(tokTotal); return r }
            .sorted { $0.costUsd > $1.costUsd }

        func provRow(_ p: UsageProvider, _ cost: Double) -> UsageDetails.Row {
            let ms = modelRows.filter { $0.provider == p.rawValue }
            let tok = ms.reduce(0) { $0 + $1.tokens }
            return .init(id: p.rawValue, label: p == .claude ? "Claude" : "OpenAI", costUsd: cost, apiUsd: cost * scoopsShare * 0.6,
                         aboUsd: cost * (1 - scoopsShare * 0.6), tokens: tok, requests: ms.reduce(0) { $0 + $1.requests },
                         scoopsUsd: cost * scoopsShare, scoopsTokens: Int(Double(tok) * scoopsShare),
                         shareCost: cost / total, shareTokens: Double(tok) / Double(tokTotal))
        }
        let providers = [provRow(.claude, claudeTotal), provRow(.openai, openaiTotal)]

        var sources: [UsageDetails.Row] = []
        if source != "other" {
            sources.append(.init(id: "scoops", label: "AIS Scoops", costUsd: total * scoopsShare, apiUsd: apiUsd,
                                 aboUsd: total * scoopsShare - apiUsd, tokens: Int(Double(tokTotal) * scoopsShare),
                                 shareCost: scoopsShare, shareTokens: scoopsShare))
        }
        if source != "scoops" {
            sources.append(.init(id: "other", label: demoText("Andere Apps auf diesem Mac", en: "Other apps on this Mac"), costUsd: total * (1 - scoopsShare),
                                 aboUsd: total * (1 - scoopsShare), tokens: Int(Double(tokTotal) * (1 - scoopsShare)),
                                 shareCost: 1 - scoopsShare, shareTokens: 1 - scoopsShare))
        }

        let appSpecs: [(String, String, UsageProvider, Double)] = source == "scoops"
            ? [("claude:AIS Scoops", "AIS Scoops", .claude, claudeTotal / total), ("openai:AIS Scoops", "AIS Scoops", .openai, openaiTotal / total)]
            : [("claude:T3 Code", "T3 Code", .claude, 0.5), ("openai:Codex Desktop", "Codex Desktop", .openai, 0.21),
               ("claude:Claude Code (Terminal)", "Claude Code (Terminal)", .claude, 0.16),
               ("openai:T3 Code", "T3 Code", .openai, 0.09), ("claude:Claude Desktop", "Claude Desktop", .claude, 0.025)]
                + (source == "all" ? [("claude:AIS Scoops", "AIS Scoops", .claude, 0.01), ("openai:AIS Scoops", "AIS Scoops", .openai, 0.005)] : [])
        let apps = appSpecs.map { s in
            UsageDetails.Row(id: s.0, label: s.1, provider: s.2.rawValue, costUsd: total * s.3,
                             tokens: Int(Double(tokTotal) * s.3), shareCost: s.3, shareTokens: s.3)
        }

        let days = hourly ? [] : series.reversed().filter { $0.costUsd > 0 }.map { p in
            UsageDetails.Row(id: p.key, label: p.label, costUsd: p.costUsd, tokens: p.tokens,
                             shareCost: p.costUsd / total, shareTokens: Double(p.tokens) / Double(tokTotal))
        }
        let scoopNames = [("b_mila", "Mila", 0.42), ("b_theo", "Theo", 0.27), ("b_lio", "Lio", 0.16), ("b_nora", "Nora", 0.1),
                          ("b_pip", "Pip", 0.05)]
        let scoopTotal = source == "other" ? 0 : total * (source == "scoops" ? 1 : scoopsShare)
        let scoops = scoopTotal == 0 ? [] : scoopNames.map { s in
            UsageDetails.Row(id: s.0, label: s.1, costUsd: scoopTotal * s.2, apiUsd: scoopTotal * s.2 * 0.6,
                             tokens: Int(Double(tokTotal) * scoopsShare * s.2), shareCost: scoopTotal * s.2 / total)
        }
        let byType = UsageDetails.ByType(input: total * typeShare.input, cacheRead: total * typeShare.cacheRead,
                                         cacheWrite: total * typeShare.cacheWrite, output: total * typeShare.output)
        var totals = UsageDetails.Totals()
        totals.costUsd = total; totals.apiUsd = apiUsd; totals.aboUsd = total - apiUsd
        totals.tokens = tokTotal; totals.input = tIn; totals.cacheRead = tRead; totals.cacheWrite = tWrite; totals.output = tOut
        totals.requests = modelRows.reduce(0) { $0 + $1.requests }
        totals.sessions = Int(Double(n) * (hourly ? 1.4 : 10.5) * factor) + 1
        totals.scoopsUsd = total * scoopsShare; totals.scoopsTokens = Int(Double(tokTotal) * scoopsShare)
        totals.cacheSavingsUsd = total * typeShare.cacheRead * 13
        totals.cachedShare = Double(tRead) / Double(tIn + tRead + tWrite)
        let accountTokens = source == "scoops" ? nil : UsageDetails.Account(openai: .init(
            tokens: Int(Double(providers[1].tokens) * 1.18), label: demoText("Laut OpenAI (alle Geräte)", en: "According to OpenAI (all devices)")))
        return UsageDetails(range: r.rawValue, bucket: hourly ? "hour" : "day", source: source, totals: totals, byType: byType,
                            providers: providers, sources: sources, apps: apps, models: modelRows, days: days,
                            scoops: scoops, series: series, account: accountTokens,
                            logs: .init(available: true, state: "idle", files: 387, lastScan: nil, error: nil),
                            notes: nil)
    }

    static func limits() -> UsageLimits {
        let now = PreviewData.clock
        func iso(_ d: Date) -> String { UsageFormat.iso.string(from: d) }
        return UsageLimits(providers: [
            .init(id: "claude", label: "Claude", appLabel: demoText("Claude-Abo (Claude Code)", en: "Claude subscription (Claude Code)"), loggedIn: true, subscription: true,
                  state: "ok", plan: "Max", source: "live", at: iso(now), windows: [
                    .init(id: "five_hour", label: demoText("5-Stunden-Fenster", en: "5-hour window"), kind: "session", usedPercent: 38,
                          resetsAt: iso(now.addingTimeInterval(2 * 3600 + 14 * 60)), windowMinutes: 300),
                    .init(id: "seven_day", label: demoText("Wöchentlich", en: "Weekly"), kind: "weekly", usedPercent: 33,
                          resetsAt: iso(now.addingTimeInterval(3 * 86400 + 3 * 3600)), windowMinutes: 10080),
                    .init(id: "model:fable", label: demoText("Wöchentlich · Fable", en: "Weekly · Fable"), kind: "model", usedPercent: 23,
                          resetsAt: iso(now.addingTimeInterval(3 * 86400 + 3 * 3600)), windowMinutes: 10080),
                  ], credits: nil, extraUsage: .init(enabled: false, usedPercent: nil), extra: nil, error: nil),
            .init(id: "openai", label: "OpenAI", appLabel: demoText("ChatGPT-Abo (Codex)", en: "ChatGPT subscription (Codex)"), loggedIn: true, subscription: true,
                  state: "ok", plan: "Pro", source: "live", at: iso(now), windows: [
                    .init(id: "codex:primary:10080", label: demoText("Wöchentlich", en: "Weekly"), kind: "weekly", usedPercent: 46,
                          resetsAt: iso(now.addingTimeInterval(21 * 3600 + 3 * 60)), windowMinutes: 10080),
                    .init(id: "codex:secondary:300", label: demoText("5-Stunden-Fenster", en: "5-hour window"), kind: "session", usedPercent: 71,
                          resetsAt: iso(now.addingTimeInterval(95 * 60)), windowMinutes: 300),
                  ], credits: .init(hasCredits: true, unlimited: false, balance: 70055.33), extraUsage: nil,
                  extra: .init(resetCredits: 3), error: nil),
        ], scopeNote: demoText("Gesamtes Abo, alle Apps und Geräte", en: "Entire subscription, all apps and devices"))
    }
}
