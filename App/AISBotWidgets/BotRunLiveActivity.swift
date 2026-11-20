#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity: Scoop arbeitet (Sperrbildschirm + Dynamic Island).
struct BotRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BotRunAttributes.self) { context in
            LockScreenRunView(context: context)
                .activityBackgroundTint(Theme.nacht.background)
                .activitySystemActionForegroundColor(Theme.nacht.textPrimary)
                .widgetURL(URL(string: "aisbot://bot/\(context.attributes.botID)"))
        } dynamicIsland: { context in
            let running = context.state.state == "running"
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        MascotView(mascot: context.attributes.mascot, size: 40, mood: running ? .workingStill : .idle,
                                   seed: context.attributes.botID, animated: false)
                        Text(context.attributes.botName).font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if running {
                        Text(context.state.startedAt, style: .timer)
                            .monospacedDigit().font(.headline).foregroundStyle(Theme.nacht.accent)
                            .frame(maxWidth: 70, alignment: .trailing)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.nacht.success).font(.title2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                MascotView(mascot: context.attributes.mascot, size: 24, mood: running ? .workingStill : .idle,
                           seed: context.attributes.botID, animated: false)
            } compactTrailing: {
                if running {
                    Text(context.state.startedAt, style: .timer)
                        .monospacedDigit().font(.caption2).foregroundStyle(Theme.nacht.accent)
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Theme.nacht.success)
                }
            } minimal: {
                MascotView(mascot: context.attributes.mascot, size: 22, mood: .workingStill,
                           seed: context.attributes.botID, animated: false)
            }
            .widgetURL(URL(string: "aisbot://bot/\(context.attributes.botID)"))
            .keylineTint(Color(hex: context.attributes.mascot.color))
        }
    }
}

private struct LockScreenRunView: View {
    let context: ActivityViewContext<BotRunAttributes>

    var body: some View {
        let theme = Theme.nacht
        let running = context.state.state == "running"
        HStack(spacing: 12) {
            MascotView(mascot: context.attributes.mascot, size: 56, mood: running ? .workingStill : .idle,
                       seed: context.attributes.botID, animated: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(context.attributes.botName).font(.headline).foregroundStyle(theme.textPrimary)
                    Spacer()
                    if running {
                        Text("seit \(Text(context.state.startedAt, style: .timer))")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(theme.accent)
                    } else {
                        Label("Fertig", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(theme.success)
                    }
                }
                Text(running ? context.state.statusLine : String(localized: "Fertig, schau in den Chat."))
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .environment(\.theme, theme)
    }
}
#endif
