#if os(iOS)
import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Live-Aktivität für Timer und Wecker, die Scoops über `apple_wecker` stellen (AlarmKit, API v1.18).
/// AlarmKit zeigt Countdown, Pause und Klingeln selbst an, braucht für die Darstellung auf Sperrbildschirm und in der
/// Dynamic Island aber diese Oberfläche in der Widget-Erweiterung. Knöpfe (Pause, Aus) blendet das System ein.
struct AlarmCountdownLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ScoopAlarmMetadata>.self) { context in
            AlarmLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.nacht.background)
                .activitySystemActionForegroundColor(Theme.nacht.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(AlarmText.title(context.attributes), systemImage: AlarmText.icon(context.attributes))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(context.attributes.tintColor)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmRemaining(state: context.state)
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.nacht.textPrimary)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(AlarmText.subtitle(context.state))
                        .font(.caption)
                        .foregroundStyle(Theme.nacht.textSecondary)
                }
            } compactLeading: {
                Image(systemName: AlarmText.icon(context.attributes))
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                AlarmRemaining(state: context.state)
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(context.attributes.tintColor)
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: AlarmText.icon(context.attributes))
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
    }
}

private struct AlarmLockScreenView: View {
    let attributes: AlarmAttributes<ScoopAlarmMetadata>
    let state: AlarmPresentationState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: AlarmText.icon(attributes))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(attributes.tintColor)
                .frame(width: 44, height: 44)
                .background(attributes.tintColor.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(AlarmText.title(attributes))
                    .font(.headline)
                    .foregroundStyle(Theme.nacht.textPrimary)
                    .lineLimit(1)
                Text(AlarmText.subtitle(state))
                    .font(.subheadline)
                    .foregroundStyle(Theme.nacht.textSecondary)
            }
            Spacer(minLength: 8)
            AlarmRemaining(state: state)
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.nacht.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

/// Restzeit: läuft als System-Timer (ohne Updates), pausiert als feste Zahl.
private struct AlarmRemaining: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let c):
            Text(timerInterval: Date.now...max(Date.now, c.fireDate), countsDown: true)
        case .paused(let p):
            Text(Duration.seconds(max(0, p.totalCountdownDuration - p.previouslyElapsedDuration))
                .formatted(.time(pattern: .minuteSecond)))
        case .alert(let a):
            Text(String(format: "%02d:%02d", a.time.hour, a.time.minute))
        @unknown default:
            Text("")
        }
    }
}

private enum AlarmText {
    static func title(_ a: AlarmAttributes<ScoopAlarmMetadata>) -> String {
        a.metadata?.title ?? "AIS Scoops"
    }

    static func icon(_ a: AlarmAttributes<ScoopAlarmMetadata>) -> String {
        a.metadata?.kind == "timer" ? "timer" : "alarm.fill"
    }

    static func subtitle(_ s: AlarmPresentationState) -> String {
        switch s.mode {
        case .countdown: "Timer läuft"
        case .paused: "Pausiert"
        case .alert: "Wecker"
        @unknown default: ""
        }
    }
}
#endif
