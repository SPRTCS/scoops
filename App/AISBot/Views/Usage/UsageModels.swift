import Foundation
import WidgetKit

// Seite „Nutzung und Verbrauch“ (Server 1.31, docs/nutzung.md): Kosten und Tokens aller Abo-Apps auf dem Server-Mac
// (Protokolle von Claude Code und Codex) plus echte API-Kosten der Scoops, dazu die Abo-Limits (kontoweit).

nonisolated struct UsageDetails: Decodable, Sendable, Equatable {
    var range: String
    var bucket: String
    var source: String
    var totals: Totals
    var byType: ByType
    var providers: [Row]
    var sources: [Row]
    var apps: [Row]
    var models: [Row]
    var days: [Row]
    var scoops: [Row]
    var series: [Point]
    var account: Account?
    var logs: Logs?
    var notes: [String]?

    nonisolated struct Totals: Decodable, Sendable, Equatable {
        var costUsd: Double = 0
        var apiUsd: Double = 0
        var aboUsd: Double = 0
        var tokens: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
        var reasoning: Int = 0
        var requests: Int = 0
        var sessions: Int = 0
        var scoopsUsd: Double = 0
        var scoopsTokens: Int = 0
        var cacheSavingsUsd: Double = 0
        var cachedShare: Double = 0
        var unpricedTokens: Int?
    }

    nonisolated struct ByType: Decodable, Sendable, Equatable {
        var input: Double = 0
        var cacheRead: Double = 0
        var cacheWrite: Double = 0
        var output: Double = 0
    }

    /// Zeile einer Aufteilung (Anbieter, Quelle, App, Modell, Tag, Scoop)
    nonisolated struct Row: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var provider: String?
        var costUsd: Double = 0
        var apiUsd: Double = 0
        var aboUsd: Double = 0
        var tokens: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
        var requests: Int = 0
        var scoopsUsd: Double = 0
        var scoopsTokens: Int = 0
        var shareCost: Double = 0
        var shareTokens: Double = 0
        var priceEstimated: Bool?
        var unpricedTokens: Int?

        init(id: String, label: String, provider: String? = nil, costUsd: Double = 0, apiUsd: Double = 0,
             aboUsd: Double = 0, tokens: Int = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
             cacheWrite: Int = 0, requests: Int = 0, scoopsUsd: Double = 0, scoopsTokens: Int = 0,
             shareCost: Double = 0, shareTokens: Double = 0, priceEstimated: Bool? = nil) {
            self.id = id; self.label = label; self.provider = provider; self.costUsd = costUsd; self.apiUsd = apiUsd
            self.aboUsd = aboUsd; self.tokens = tokens; self.input = input; self.output = output
            self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.requests = requests
            self.scoopsUsd = scoopsUsd; self.scoopsTokens = scoopsTokens; self.shareCost = shareCost
            self.shareTokens = shareTokens; self.priceEstimated = priceEstimated
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
            label = (try? c.decode(String.self, forKey: .label)) ?? id
            provider = try? c.decodeIfPresent(String.self, forKey: .provider)
            func d(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? 0 }
            func i(_ k: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? 0 }
            costUsd = d(.costUsd); apiUsd = d(.apiUsd); aboUsd = d(.aboUsd); tokens = i(.tokens); input = i(.input)
            output = i(.output); cacheRead = i(.cacheRead); cacheWrite = i(.cacheWrite); requests = i(.requests)
            scoopsUsd = d(.scoopsUsd); scoopsTokens = i(.scoopsTokens); shareCost = d(.shareCost)
            shareTokens = d(.shareTokens)
            priceEstimated = try? c.decodeIfPresent(Bool.self, forKey: .priceEstimated)
            unpricedTokens = try? c.decodeIfPresent(Int.self, forKey: .unpricedTokens)
        }

        enum CodingKeys: String, CodingKey {
            case id, label, provider, costUsd, apiUsd, aboUsd, tokens, input, output, cacheRead, cacheWrite, requests
            case scoopsUsd, scoopsTokens, shareCost, shareTokens, priceEstimated, unpricedTokens
        }
    }

    /// Ein Balken/Punkt im Verlauf (Tag oder Stunde), aufgeteilt nach Anbieter
    nonisolated struct Point: Decodable, Sendable, Equatable, Identifiable {
        var key: String
        var label: String
        var costUsd: Double
        var tokens: Int
        var claude: Part
        var openai: Part
        var id: String { key }

        nonisolated struct Part: Decodable, Sendable, Equatable {
            var costUsd: Double = 0
            var tokens: Int = 0
            var apiUsd: Double = 0
        }

        func part(_ provider: UsageProvider) -> Part { provider == .claude ? claude : openai }
    }

    nonisolated struct Account: Decodable, Sendable, Equatable {
        var openai: Provider?
        nonisolated struct Provider: Decodable, Sendable, Equatable {
            var tokens: Int
            var label: String?
        }
    }

    nonisolated struct Logs: Decodable, Sendable, Equatable {
        var available: Bool?
        var state: String?
        var files: Int?
        var lastScan: String?
        var error: String?
    }

    func provider(_ p: UsageProvider) -> Row? { providers.first { $0.id == p.rawValue } }
}

nonisolated struct UsageLimits: Decodable, Sendable, Equatable {
    var providers: [Provider]
    var scopeNote: String?

    nonisolated struct Provider: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var appLabel: String?
        var loggedIn: Bool?
        var subscription: Bool?
        var state: String
        var plan: String?
        var source: String?
        var at: String?
        var windows: [Window]
        var credits: Credits?
        var extraUsage: ExtraUsage?
        var extra: Extra?
        var error: String?
    }

    nonisolated struct Window: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var kind: String?
        var usedPercent: Double?
        var resetsAt: String?
        var windowMinutes: Int?
    }

    nonisolated struct Credits: Decodable, Sendable, Equatable {
        var hasCredits: Bool?
        var unlimited: Bool?
        var balance: Double?
    }

    nonisolated struct ExtraUsage: Decodable, Sendable, Equatable {
        var enabled: Bool?
        var usedPercent: Double?
    }

    nonisolated struct Extra: Decodable, Sendable, Equatable {
        var resetCredits: Int?
    }
}

enum UsageProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, openai
    var id: String { rawValue }
}

enum UsageRange: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d", quarter = "90d"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .day: String(localized: "24 h", comment: "Nutzung: Zeitraum kurz, 24 Stunden")
        case .week: String(localized: "7 T", comment: "Nutzung: Zeitraum kurz, 7 Tage")
        case .month: String(localized: "30 T", comment: "Nutzung: Zeitraum kurz, 30 Tage")
        case .quarter: String(localized: "90 T", comment: "Nutzung: Zeitraum kurz, 90 Tage")
        }
    }
    var long: String {
        switch self {
        case .day: String(localized: "Letzte 24 h", comment: "Nutzung: Zeitraum")
        case .week: String(localized: "7 Tage", comment: "Nutzung: Zeitraum")
        case .month: String(localized: "30 Tage", comment: "Nutzung: Zeitraum")
        case .quarter: String(localized: "90 Tage", comment: "Nutzung: Zeitraum")
        }
    }
}

enum UsageSource: String, CaseIterable, Identifiable {
    case all, scoops, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "Alle Apps")
        case .scoops: String(localized: "Nur Scoops")
        case .other: String(localized: "Andere Apps")
        }
    }
}

extension BotService {
    func usageDetails(range: String, source: String, refresh: Bool) async throws -> UsageDetails {
        throw APIError(status: 404, message: String(localized: "Der Server kennt diese Ansicht noch nicht (ab Server 1.31)."))
    }
    func usageLimits(refresh: Bool) async throws -> UsageLimits {
        throw APIError(status: 404, message: String(localized: "Der Server kennt diese Ansicht noch nicht (ab Server 1.31)."))
    }
}

extension AppStore {
    /// Seite „Nutzung und Verbrauch“ braucht Server 1.31 (Demo-Modus immer)
    var supportsUsageDetails: Bool {
        if isMock { return true }
        guard let v = serverVersion else { return false }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 31)
    }
}

/// Kompakte Zahlen: deutsch „12 Mrd.“, „36,8 Mio.“, „134 Tsd.“, englisch „12B“, „36.8M“, „134K“
enum UsageFormat {
    /// Sprache der App (bisher fest `de_DE`)
    static var locale: Locale { .app }

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        let german = AppLanguage.isGerman
        func f(_ x: Double, _ unit: String) -> String {
            let digits = x >= 100 ? 0 : 1
            let s = x.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
            return german ? "\(s) \(unit)" : s + unit
        }
        switch abs(v) {
        case 1e9...: return f(v / 1e9, german ? "Mrd." : "B")
        case 1e6...: return f(v / 1e6, german ? "Mio." : "M")
        case 1e4...: return f(v / 1e3, german ? "Tsd." : "K")
        default: return n.formatted(.number.locale(locale))
        }
    }

    /// Achsenbeschriftung: „1,5 Mrd.“, „500 Mio.“
    static func axisTokens(_ v: Double) -> String { v == 0 ? "0" : tokens(Int(v)) }

    static func usd(_ v: Double, cents: Bool = true) -> String {
        if !cents || v >= 10_000 {
            return v.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(0)))
        }
        return v.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(2)))
    }

    static func axisUsd(_ v: Double) -> String {
        v == 0 ? "0" : v.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(0)))
    }

    /// Deutsch „12,5 %“, Englisch „12.5%“
    static func percent(_ share: Double) -> String {
        if AppLanguage.isGerman {
            return (share * 100).formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " %"
        }
        return share.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }

    /// „3 T 3 h“, „21 h 3 min“, „12 min“ (englisch „3d 3h“, „21h 3m“, „12 min“)
    static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 {
            return h > 0 ? String(localized: "\(d) T \(h) h", comment: "Nutzung: Zeit bis zum Reset, Tage und Stunden")
                : String(localized: "\(d) T", comment: "Nutzung: Zeit bis zum Reset, Tage")
        }
        if h > 0 {
            return m > 0 ? String(localized: "\(h) h \(m) min", comment: "Nutzung: Zeit bis zum Reset, Stunden und Minuten")
                : String(localized: "\(h) h", comment: "Nutzung: Zeit bis zum Reset, Stunden")
        }
        let minutes = max(m, 1)
        return String(localized: "\(minutes) min", comment: "Nutzung: Zeit bis zum Reset, Minuten")
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - Widget „Abo-Limits“

extension LimitsSnapshot {
    /// Stand der Seite in den Widget-Schnappschuss übernehmen
    init(_ limits: UsageLimits, at date: Date = Date()) {
        let providers = limits.providers.map { p in
            LimitsSnapshot.Provider(
                id: p.id, name: p.id == "claude" ? "Claude" : "Codex", plan: p.plan, state: p.state,
                windows: p.windows.compactMap { w in
                    guard let used = w.usedPercent else { return nil }
                    let label = w.kind == "session" ? String(localized: "5 Stunden", comment: "Abo-Limit: 5-Stunden-Fenster") : w.label
                    return LimitsSnapshot.Window(id: w.id, label: label, kind: w.kind ?? "weekly", usedPercent: used,
                                                 resetsAt: UsageFormat.date(w.resetsAt), windowMinutes: w.windowMinutes)
                },
                creditsBalance: p.credits?.unlimited == true ? nil : p.credits?.balance,
                resetCredits: p.extra?.resetCredits)
        }
        // „Stand“ = Zeitpunkt der Abfrage beim Anbieter (live), sonst jetzt
        let at = limits.providers.compactMap { UsageFormat.date($0.at) }.max() ?? date
        self.init(generatedAt: at, providers: providers)
    }
}

extension AppStore {
    /// Limits für das Widget holen und ablegen (beim Verbinden; die Seite selbst schreibt bei jedem Laden).
    func refreshLimitsWidget(force: Bool = false) async {
        guard supportsUsageDetails, !isTestServer, let service else { return }
        if !force, let old = LimitsSnapshot.load(), Date().timeIntervalSince(old.generatedAt) < 600 { return }
        guard let limits = try? await service.usageLimits(refresh: false) else { return }
        Self.storeLimitsForWidget(limits, mock: isMock)
    }

    static func storeLimitsForWidget(_ limits: UsageLimits, mock: Bool) {
        let snap = mock ? LimitsSnapshot.demo(now: PreviewData.clock) : LimitsSnapshot(limits)
        if snap.save() { WidgetCenter.shared.reloadTimelines(ofKind: "LimitsWidget") }
    }
}

/// Deep Link `aisbot://usage[/limits|/tokens]` aus dem Widget: Seite öffnen
@MainActor @Observable
final class UsageRouter {
    static let shared = UsageRouter()
    var requests = 0
    var tab: UsageTab?
    private(set) var pending = false

    func open(tab: UsageTab?) {
        self.tab = tab
        pending = true
        requests += 1
    }

    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}
