#if os(iOS)
import ActivityKit
import Foundation

/// EINE gemeinsame Live-Aktivität für alle gerade arbeitenden Scoops (Sperrbildschirm + Dynamic Island).
///
/// Der Server startet sie per Push-to-Start (`attributes-type: "ScoopsLiveAttributes"`,
/// `attributes: {"title": "AIS Scoops"}`) und aktualisiert sie per Broadcast-Kanal (iOS 18+) oder Token.
/// JSON exakt camelCase, Datum = Sekunden seit 2001 (Standard-Codierung von ActivityKit).
nonisolated struct ScoopsLiveAttributes: ActivityAttributes {
    nonisolated struct Entry: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var label: String?
        var mascot: Mascot
        /// running | done | failed | stopped
        var state: String
        var statusLine: String
        var steps: Int
        var startedAt: Date
        var finishedAt: Date?

        var isRunning: Bool { state == "running" }
    }

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var scoops: [Entry]
        var updatedAt: Date

        /// Laufende zuerst (älteste oben), danach abgeschlossene (zuletzt beendete oben).
        var ordered: [Entry] {
            scoops.sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }
                if a.isRunning { return a.startedAt < b.startedAt }
                return (a.finishedAt ?? a.startedAt) > (b.finishedAt ?? b.startedAt)
            }
        }

        var running: [Entry] { ordered.filter(\.isRunning) }
    }

    var title: String

    static let defaultTitle = "AIS Scoops"
}

/// Antwort von `GET /api/live-activity` bzw. `POST /api/live-activity/ensure`.
/// Schlüssel camelCase, `content` im ActivityKit-Format (Datum = Sekunden seit 2001) → einfacher `JSONDecoder()`.
nonisolated struct ScoopsLiveStatus: Codable, Hashable, Sendable {
    var active: Bool
    /// Server-Sitzung (wird als `run_id` beim Melden des Aktivitäts-Tokens verwendet).
    var session: String?
    /// APNs-Broadcast-Kanal (iOS 18+); nil → Aktivität mit `pushType: .token`.
    var channel: String?
    var content: ScoopsLiveAttributes.ContentState?

    static func decode(_ data: Data) throws -> ScoopsLiveStatus {
        try JSONDecoder().decode(ScoopsLiveStatus.self, from: data)
    }
}
#endif
