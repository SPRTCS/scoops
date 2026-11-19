#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Gemeinsame Live-Aktivität: alle gerade arbeitenden Scoops (Sperrbildschirm + Dynamic Island).
struct ScoopsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScoopsLiveAttributes.self) { context in
            ScoopsLockScreenView(state: context.state)
                .activityBackgroundTint(Theme.nacht.background)
                .activitySystemActionForegroundColor(Theme.nacht.textPrimary)
                .widgetURL(ScoopsLive.link(for: context.state.ordered.first))
        } dynamicIsland: { context in
            let state = context.state
            let running = state.running
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ScoopsMascotStack(entries: Array(state.ordered.prefix(3)), size: 26)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ScoopsLive.headline(state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.nacht.textPrimary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if running.count > 3 {
                        Text("+\(running.count - 3)")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Theme.nacht.textSecondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(state.ordered.prefix(3)) { entry in
                            Link(destination: ScoopsLive.link(for: entry)) {
                                ScoopsLiveRow(entry: entry, mascotSize: 26)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                ScoopsMascotStack(entries: Array((running.isEmpty ? state.ordered : running).prefix(3)), size: 22)
            } compactTrailing: {
                if running.count == 1, let only = running.first {
                    ScoopsTimer(start: only.startedAt)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.nacht.accent)
                        .frame(maxWidth: 44)
                } else if running.count > 1 {
                    Text("\(running.count)")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Theme.nacht.accent)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Theme.nacht.success)
                }
            } minimal: {
                if let first = state.ordered.first {
                    MascotView(mascot: first.mascot, size: 22, mood: first.isRunning ? .workingStill : .idle,
                               seed: first.id, animated: false)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Theme.nacht.success)
                }
            }
            .widgetURL(ScoopsLive.link(for: state.ordered.first))
            .keylineTint(Theme.nacht.accent)
        }
    }
}

// MARK: - Bausteine

nonisolated enum ScoopsLive {
    /// „3 Scoops arbeiten“ / „Tina arbeitet“ / „Alle fertig“
    static func headline(_ state: ScoopsLiveAttributes.ContentState) -> String {
        let running = state.running
        switch running.count {
        case 0: return "Alle fertig"
        case 1: return "\(running[0].name) arbeitet"
        default: return "\(running.count) Scoops arbeiten"
        }
    }

    /// „ – MLP“ (Rolle/Untertitel des Scoops), leer ohne Rolle.
    static func roleSuffix(_ entry: ScoopsLiveAttributes.Entry) -> String {
        guard let label = entry.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return "" }
        return " – \(label)"
    }

    /// Öffnet den Chat (gleiches Schema wie Widgets und Mitteilungen).
    static func link(for entry: ScoopsLiveAttributes.Entry?) -> URL {
        guard let entry, let url = URL(string: "aisbot://bot/\(entry.id)") else { return URL(string: "aisbot://")! }
        return url
    }

    static func symbol(for state: String) -> (name: String, color: Color) {
        switch state {
        case "failed": return ("exclamationmark.circle.fill", Theme.nacht.danger)
        case "stopped": return ("stop.circle.fill", Theme.nacht.textSecondary)
        default: return ("checkmark.circle.fill", Theme.nacht.success)
        }
    }

    static func endedText(_ entry: ScoopsLiveAttributes.Entry) -> String {
        switch entry.state {
        case "failed": return "Fehlgeschlagen"
        case "stopped": return "Angehalten"
        default: return "Fertig"
        }
    }
}

/// Laufender Timer ab Laufbeginn (zählt hoch, ohne Updates).
private struct ScoopsTimer: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...start.addingTimeInterval(24 * 3600), countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Überlappende Maskottchen (max. 3).
private struct ScoopsMascotStack: View {
    let entries: [ScoopsLiveAttributes.Entry]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.38) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                MascotView(mascot: entry.mascot, size: size, mood: entry.isRunning ? .workingStill : .idle,
                           seed: entry.id, animated: false)
                    .zIndex(Double(entries.count - index))
            }
        }
    }
}

/// Eine Zeile: Maskottchen, Name, Statuszeile, rechts Timer bzw. Endsymbol.
private struct ScoopsLiveRow: View {
    let entry: ScoopsLiveAttributes.Entry
    var mascotSize: CGFloat = 28

    var body: some View {
        let theme = Theme.nacht
        HStack(spacing: 10) {
            MascotView(mascot: entry.mascot, size: mascotSize, mood: entry.isRunning ? .workingStill : .idle,
                       seed: entry.id, animated: false)
                .frame(width: mascotSize, height: mascotSize)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.name)\(Text(ScoopsLive.roleSuffix(entry)).foregroundStyle(theme.textSecondary))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(entry.isRunning ? entry.statusLine : ScoopsLive.endedText(entry))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isRunning {
                ScoopsTimer(start: entry.startedAt)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 58, alignment: .trailing)
            } else {
                let symbol = ScoopsLive.symbol(for: entry.state)
                Image(systemName: symbol.name)
                    .font(.title3)
                    .foregroundStyle(symbol.color)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Sperrbildschirm: Kopfzeile + bis zu 4 Zeilen (+N weitere).
private struct ScoopsLockScreenView: View {
    let state: ScoopsLiveAttributes.ContentState
    private let maxRows = 4

    var body: some View {
        let theme = Theme.nacht
        let ordered = state.ordered
        let shown = Array(ordered.prefix(maxRows))
        let hidden = ordered.count - shown.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: state.running.isEmpty ? "checkmark.circle.fill" : "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.running.isEmpty ? theme.success : theme.accent)
                Text(ScoopsLive.headline(state))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                if hidden > 0 {
                    Text("+\(hidden) weitere")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text("AIS Scoops")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            ForEach(shown) { entry in
                Link(destination: ScoopsLive.link(for: entry)) {
                    ScoopsLiveRow(entry: entry, mascotSize: shown.count > 3 ? 26 : 28)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .environment(\.theme, theme)
    }
}

#if DEBUG
extension ScoopsLiveAttributes.ContentState {
    static var preview: Self {
        let now = Date()
        return .init(scoops: [
            .init(id: "b_mila", name: "Mila", label: "MLP", mascot: Mascot(shape: "bean", color: "#FF5FA8", eyes: "dots", accessory: "beret"),
                  state: "running", statusLine: "Vergleicht drei Angebote", steps: 4, startedAt: now.addingTimeInterval(-94)),
            .init(id: "b_theo", name: "Theo", label: nil, mascot: Mascot(shape: "cloud", color: "#3D84F5", eyes: "ovals", accessory: "glasses"),
                  state: "running", statusLine: "Ist im Browser auf google.com", steps: 7, startedAt: now.addingTimeInterval(-312)),
            .init(id: "b_tina", name: "Tina", label: nil, mascot: Mascot(shape: "egg", color: "#FFB524", eyes: "happy", accessory: "none"),
                  state: "done", statusLine: "Fertig", steps: 3, startedAt: now.addingTimeInterval(-600), finishedAt: now.addingTimeInterval(-30)),
        ], updatedAt: now)
    }
}

#Preview("Sperrbildschirm", as: .content, using: ScoopsLiveAttributes(title: "AIS Scoops")) {
    ScoopsLiveActivity()
} contentStates: {
    ScoopsLiveAttributes.ContentState.preview
}
#endif
#endif
