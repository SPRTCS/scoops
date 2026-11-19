import AppIntents
import SwiftUI
import WidgetKit

// Widget „Abo-Limits“ (Server 1.31, docs/nutzung.md): Wochen-, 5-Stunden- und Modellfenster von Claude und Codex.
// Daten: Schnappschuss der App im App-Group-Container (`limits-snapshot.json`). Das Widget ruft selbst nichts ab –
// die Zugangsdaten zum Server liegen nur in der App. Die Timeline schaltet zu jedem Reset weiter, damit ein
// abgelaufenes Fenster nicht als „voll“ stehen bleibt.

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitsSnapshot?
}

struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry { LimitsEntry(date: Date(), snapshot: .demo()) }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        let snap = LimitsSnapshot.load()
        completion(LimitsEntry(date: Date(), snapshot: context.isPreview && (snap?.isEmpty ?? true) ? .demo() : snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let now = Date()
        let snap = LimitsSnapshot.load()
        // Einträge alle 30 Minuten (Reset-Zeiten und Tempo wandern mit) plus zu jedem Reset in den nächsten 6 Stunden
        var dates = (0..<12).map { now.addingTimeInterval(Double($0) * 1800) }
        let resets = (snap?.providers ?? []).flatMap(\.windows).compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
        dates.append(contentsOf: resets.map { $0.addingTimeInterval(5) })
        let entries = dates.sorted().map { LimitsEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LimitsWidget", provider: LimitsProvider()) { entry in
            LimitsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Abo-Limits")
        .description("Wie viel von deinen Claude- und ChatGPT-Abos übrig ist – Woche, 5 Stunden und pro Modell.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LimitsWidgetEntryView: View {
    let entry: LimitsEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = Theme.forScheme(scheme)
        LimitsWidgetView(snapshot: entry.snapshot, size: family == .systemSmall ? .small : (family == .systemLarge ? .large : .medium),
                         theme: theme, now: entry.date)
            .environment(\.theme, theme)
            .containerBackground(for: .widget) { theme.background }
    }
}

#if os(iOS)
// MARK: - Sperrbildschirm

/// Auswahl im Widget „Abo-Limits“ auf dem Sperrbildschirm
enum LimitsLockProviderOption: String, AppEnum {
    case both, claude, openai

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Abo"
    static let caseDisplayRepresentations: [LimitsLockProviderOption: DisplayRepresentation] = [
        .both: "Claude und Codex", .claude: "Claude", .openai: "Codex (ChatGPT)",
    ]

    var choice: LimitsLockChoice { LimitsLockChoice(rawValue: rawValue) ?? .both }
}

struct LimitsLockIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Abo wählen"
    static let description = IntentDescription("Welche Wochenlimits das Widget zeigt.")

    @Parameter(title: "Abo", default: .both)
    var provider: LimitsLockProviderOption

    init() {}
}

struct LimitsLockEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitsSnapshot?
    let choice: LimitsLockChoice
}

struct LimitsLockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LimitsLockEntry { LimitsLockEntry(date: Date(), snapshot: .demo(), choice: .both) }

    func snapshot(for configuration: LimitsLockIntent, in context: Context) async -> LimitsLockEntry {
        let snap = LimitsSnapshot.load()
        return LimitsLockEntry(date: Date(), snapshot: context.isPreview && (snap?.isEmpty ?? true) ? .demo() : snap,
                               choice: configuration.provider.choice)
    }

    func timeline(for configuration: LimitsLockIntent, in context: Context) async -> Timeline<LimitsLockEntry> {
        // Wie „Abo-Limits“: alle 30 Minuten plus zu jedem Reset in den nächsten 6 Stunden
        let now = Date()
        let snap = LimitsSnapshot.load()
        var dates = (0..<12).map { now.addingTimeInterval(Double($0) * 1800) }
        let resets = (snap?.providers ?? []).flatMap(\.windows).compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
        dates.append(contentsOf: resets.map { $0.addingTimeInterval(5) })
        let entries = dates.sorted().map { LimitsLockEntry(date: $0, snapshot: snap, choice: configuration.provider.choice) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600)))
    }
}

/// Abo-Limits auf dem Sperrbildschirm: Wochenstand von Claude und/oder Codex – als Balken, Ring oder Zeile über der Uhr.
struct LimitsLockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LimitsLockWidget", intent: LimitsLockIntent.self, provider: LimitsLockProvider()) { entry in
            LimitsLockEntryView(entry: entry)
        }
        .configurationDisplayName("Wochenlimits")
        .description("Wie viel von deinen Claude- und ChatGPT-Abos diese Woche übrig ist.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct LimitsLockEntryView: View {
    let entry: LimitsLockEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                LimitsAccessoryCircularView(snapshot: entry.snapshot, choice: entry.choice, now: entry.date)
            case .accessoryInline:
                LimitsAccessoryInlineView(snapshot: entry.snapshot, choice: entry.choice, now: entry.date)
            default:
                LimitsAccessoryRectangularView(snapshot: entry.snapshot, choice: entry.choice, now: entry.date)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}
#endif
