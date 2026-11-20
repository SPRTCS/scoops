import Foundation

/// Abo-Limits für das Widget „Abo-Limits“ (Server 1.31, docs/nutzung.md). Die App schreibt den Stand beim Laden der
/// Limits in den App-Group-Container; das Widget rendert nur daraus (kein Netzwerk, keine Zugangsdaten).
nonisolated struct LimitsSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    var providers: [Provider]

    nonisolated struct Provider: Codable, Hashable, Sendable, Identifiable {
        var id: String  // "claude" | "openai"
        var name: String  // „Claude“ | „Codex“
        var plan: String?
        /// "ok" | "not_logged_in" | "unavailable"
        var state: String
        var windows: [Window]
        var creditsBalance: Double?
        var resetCredits: Int?
    }

    nonisolated struct Window: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var label: String
        /// "session" (5 Stunden) | "weekly" | "model" | …
        var kind: String
        var usedPercent: Double
        var resetsAt: Date?
        var windowMinutes: Int?

        var leftPercent: Double { max(0, min(100, 100 - usedPercent)) }

        /// Bei gleichmäßigem Verbrauch erwarteter Verbrauch (0–100) zum Zeitpunkt `now`
        func expectedUsed(at now: Date) -> Double? {
            guard let resetsAt else { return nil }
            let span = TimeInterval((windowMinutes ?? 10080) * 60)
            let remaining = max(0, min(span, resetsAt.timeIntervalSince(now)))
            return (1 - remaining / span) * 100
        }

        /// -1 unter Tempo, 0 im Tempo, 1 über Tempo
        func pace(at now: Date) -> Int? {
            guard let e = expectedUsed(at: now) else { return nil }
            if usedPercent < e - 3 { return -1 }
            if usedPercent > e + 3 { return 1 }
            return 0
        }

        /// Nach dem Reset ist der alte Stand überholt
        func isStale(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    }

    var isEmpty: Bool { providers.allSatisfy { $0.windows.isEmpty } }

    /// Engstes Wochenfenster eines Anbieters (für das kleine Widget)
    func tightestWeekly(_ provider: Provider) -> Window? {
        let weekly = provider.windows.filter { $0.kind != "session" }
        return (weekly.isEmpty ? provider.windows : weekly).max { $0.usedPercent < $1.usedPercent }
    }

    static let fileName = "limits-snapshot.json"

    static func load() -> LimitsSnapshot? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: fileName), let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(LimitsSnapshot.self, from: data)
    }

    @discardableResult
    func save() -> Bool {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: Self.fileName) else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(self) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Beispielwerte für Widget-Vorschau und Demo-Modus
    static func demo(now: Date = Date()) -> LimitsSnapshot {
        LimitsSnapshot(generatedAt: now.addingTimeInterval(-4 * 60), providers: [
            Provider(id: "claude", name: "Claude", plan: "Max", state: "ok", windows: [
                Window(id: "seven_day", label: demoText("Wöchentlich", en: "Weekly"), kind: "weekly", usedPercent: 34,
                       resetsAt: now.addingTimeInterval(3 * 86400 + 3 * 3600), windowMinutes: 10080),
                Window(id: "model:fable", label: demoText("Wöchentlich · Fable", en: "Weekly · Fable"), kind: "model", usedPercent: 23,
                       resetsAt: now.addingTimeInterval(3 * 86400 + 3 * 3600), windowMinutes: 10080),
                Window(id: "five_hour", label: demoText("5 Stunden", en: "5 hours"), kind: "session", usedPercent: 38,
                       resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), windowMinutes: 300),
            ]),
            Provider(id: "openai", name: "Codex", plan: "Pro", state: "ok", windows: [
                Window(id: "codex:primary:10080", label: demoText("Wöchentlich", en: "Weekly"), kind: "weekly", usedPercent: 46,
                       resetsAt: now.addingTimeInterval(21 * 3600 + 3 * 60), windowMinutes: 10080),
                Window(id: "codex:secondary:300", label: demoText("5 Stunden", en: "5 hours"), kind: "session", usedPercent: 71,
                       resetsAt: now.addingTimeInterval(95 * 60), windowMinutes: 300),
            ], creditsBalance: 70055.33, resetCredits: 3),
        ])
    }
}
