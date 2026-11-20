import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct ScoopEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let bots: [WidgetBot]
}

/// Läuft ein Scoop, aktualisieren wir nach ~90 s (der „seit“-Timer läuft von selbst), sonst stündlich.
private func policy(for bots: [WidgetBot]) -> TimelineReloadPolicy {
    let busy = bots.contains(where: \.busy)
    return .after(Date().addingTimeInterval(busy ? 90 : 3600))
}

private func demoSnapshot() -> WidgetSnapshot {
    let mila = WidgetBot(id: "b_mila", name: "Mila", label: demoText("Assistenz", en: "Assistant"),
                         mascot: Mascot(shape: "bean", color: "#8B5CF6", eyes: "dots", accessory: "bowtie"),
                         pinned: true, busy: true, statusLine: demoText("Ist im Browser auf booking.com", en: "Browses booking.com"),
                         runStartedAt: Date().addingTimeInterval(-72), unread: 0,
                         lastMessagePreview: demoText("Guten Morgen Arman! Das steht heute an …", en: "Good morning, Arman! Here’s what’s on today…"), lastMessageAt: Date())
    let theo = WidgetBot(id: "b_theo", name: "Theo", label: demoText("Recherche", en: "Research"),
                         mascot: Mascot(shape: "cloud", color: "#3D84F5", eyes: "ovals", accessory: "glasses"),
                         pinned: true, busy: false, statusLine: nil, runStartedAt: nil, unread: 1,
                         lastMessagePreview: demoText("Die drei wichtigsten Punkte …", en: "The three key points…"), lastMessageAt: Date().addingTimeInterval(-3600))
    let lio = WidgetBot(id: "b_lio", name: "Lio", label: "Social Media",
                        mascot: Mascot(shape: "star", color: "#FFB524", eyes: "sparkle", accessory: "beret"),
                        pinned: false, busy: false, statusLine: nil, runStartedAt: nil, unread: 2,
                        lastMessagePreview: demoText("Freigabe: Post auf X veröffentlichen", en: "Approval: Publish post on X"), lastMessageAt: Date().addingTimeInterval(-7200))
    let nora = WidgetBot(id: "b_nora", name: "Nora", label: demoText("Finanzen", en: "Finance"),
                         mascot: Mascot(shape: "egg", color: "#22BFAE", eyes: "happy", accessory: "headphones"),
                         pinned: false, busy: false, statusLine: nil, runStartedAt: nil, unread: 0,
                         lastMessagePreview: demoText("Dein Oktober ist durch …", en: "October is wrapped up…"), lastMessageAt: Date().addingTimeInterval(-9000))
    return WidgetSnapshot(generatedAt: Date(), userName: "Arman", bots: [mila, theo, lio, nora])
}

private func currentSnapshot(_ context: TimelineProviderContext) -> WidgetSnapshot {
    if context.isPreview, (SharedContainer.loadSnapshot()?.bots.isEmpty ?? true) { return demoSnapshot() }
    return SharedContainer.loadSnapshot() ?? .empty
}

struct SingleScoopProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ScoopEntry {
        let s = demoSnapshot()
        return ScoopEntry(date: Date(), snapshot: s, bots: Array(s.bots.prefix(1)))
    }

    func snapshot(for configuration: SelectScoopIntent, in context: Context) async -> ScoopEntry {
        entry(for: configuration, context: context)
    }

    func timeline(for configuration: SelectScoopIntent, in context: Context) async -> Timeline<ScoopEntry> {
        let e = entry(for: configuration, context: context)
        return Timeline(entries: [e], policy: policy(for: e.bots))
    }

    private func entry(for configuration: SelectScoopIntent, context: Context) -> ScoopEntry {
        let snap = currentSnapshot(context)
        let bot = configuration.scoop.flatMap { snap.bot($0.id) } ?? snap.orderedBots.first
        return ScoopEntry(date: Date(), snapshot: snap, bots: bot.map { [$0] } ?? [])
    }
}

struct ScoopGridProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ScoopEntry {
        let s = demoSnapshot()
        return ScoopEntry(date: Date(), snapshot: s, bots: s.orderedBots)
    }

    func snapshot(for configuration: SelectScoopsIntent, in context: Context) async -> ScoopEntry {
        entry(for: configuration, context: context)
    }

    func timeline(for configuration: SelectScoopsIntent, in context: Context) async -> Timeline<ScoopEntry> {
        let e = entry(for: configuration, context: context)
        return Timeline(entries: [e], policy: policy(for: e.bots))
    }

    private func entry(for configuration: SelectScoopsIntent, context: Context) -> ScoopEntry {
        let snap = currentSnapshot(context)
        let limit = context.family == .systemLarge ? 8 : 4
        var bots: [WidgetBot]
        if let chosen = configuration.scoops, !chosen.isEmpty {
            bots = chosen.compactMap { snap.bot($0.id) }
        } else {
            bots = snap.orderedBots
        }
        bots = Array(bots.prefix(limit))
        return ScoopEntry(date: Date(), snapshot: snap, bots: bots)
    }
}

// MARK: - Widgets

struct ScoopWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScoopWidget", intent: SelectScoopIntent.self, provider: SingleScoopProvider()) { entry in
            ScoopWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Scoop")
        .description("Ein Scoop mit Arbeitsstatus und letzter Nachricht – auch rund auf dem Sperrbildschirm.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .pushHandler(ScoopWidgetPushHandler.self)
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

struct ScoopWidgetEntryView: View {
    let entry: ScoopEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = Theme.forScheme(scheme)
        Group {
            #if os(iOS)
            if family == .accessoryRectangular {
                ScoopStatusAccessoryView(bot: entry.bots.first)
            } else if family == .accessoryCircular {
                ScoopAvatarAccessoryView(bot: entry.bots.first)
            } else {
                ScoopSmallView(bot: entry.bots.first, theme: theme)
            }
            #else
            ScoopSmallView(bot: entry.bots.first, theme: theme)
            #endif
        }
        .environment(\.theme, theme)
        .containerBackground(for: .widget) { theme.background }
    }
}

struct ScoopsGridWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScoopsGridWidget", intent: SelectScoopsIntent.self, provider: ScoopGridProvider()) { entry in
            ScoopsGridEntryView(entry: entry)
        }
        .configurationDisplayName("Deine Scoops")
        .description("Direktzugriff auf mehrere Scoops. Zeigt, wer gerade arbeitet.")
        .supportedFamilies([.systemMedium, .systemLarge])
        #if os(iOS)
        .pushHandler(ScoopWidgetPushHandler.self)
        #endif
    }
}

struct ScoopsGridEntryView: View {
    let entry: ScoopEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = Theme.forScheme(scheme)
        let featured = entry.snapshot.bots.max { ($0.lastMessageAt ?? .distantPast) < ($1.lastMessageAt ?? .distantPast) }
        ScoopGridView(bots: entry.bots, large: family == .systemLarge, featured: featured, theme: theme)
            .environment(\.theme, theme)
            .containerBackground(for: .widget) { theme.background }
    }
}

#if os(iOS)
/// Sperrbildschirm: Anzahl arbeitender Scoops.
struct ScoopsCountWidget: Widget {
    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> ScoopEntry { ScoopEntry(date: Date(), snapshot: demoSnapshot(), bots: []) }
        func getSnapshot(in context: Context, completion: @escaping (ScoopEntry) -> Void) {
            completion(ScoopEntry(date: Date(), snapshot: currentSnapshot(context), bots: []))
        }
        func getTimeline(in context: Context, completion: @escaping (Timeline<ScoopEntry>) -> Void) {
            let snap = currentSnapshot(context)
            completion(Timeline(entries: [ScoopEntry(date: Date(), snapshot: snap, bots: [])], policy: policy(for: snap.bots)))
        }
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScoopsCountWidget", provider: Provider()) { entry in
            ScoopCountAccessoryView(busyCount: entry.snapshot.busyCount)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "aisbot://open"))
        }
        .configurationDisplayName("Arbeitende Scoops")
        .description("Wie viele Scoops gerade arbeiten.")
        .supportedFamilies([.accessoryCircular])
    }
}
#endif

#if os(iOS)
/// Widget-Push (iOS 26+): Der Server schickt `apns-push-type: widgets` an
/// `com.ais.aisbot.push-type.widgets` mit `{"aps":{"content-changed":true}}`; WidgetKit lädt dann die
/// Timelines neu. Das Token meldet die App selbst (WidgetCenter.currentPushInfo → POST /api/devices,
/// platform "ios-widgets"); hier wird es nur für die App im App-Group-Container abgelegt.
struct ScoopWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let hex = pushInfo.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults(suiteName: SharedContainer.appGroup)?.set(hex, forKey: "widgetPushToken")
    }
}
#endif
