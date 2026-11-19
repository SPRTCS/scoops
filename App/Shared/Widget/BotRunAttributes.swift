#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity für einen laufenden Scoop-Lauf (Dynamic Island + Sperrbildschirm).
nonisolated struct BotRunAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// running | done | failed | stopped
        var state: String
        var statusLine: String
        var steps: Int
        var startedAt: Date
        var finishedAt: Date?
    }

    var botID: String
    var botName: String
    var botLabel: String?
    var mascot: Mascot
    var runID: String
}
#endif
