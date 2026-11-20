import AppIntents
import SwiftUI
import WidgetKit

@main
struct AISBotWatchWidgets: WidgetBundle {
    var body: some Widget {
        ApprovalsComplication()
        ScoopComplication()
    }
}

// MARK: - Gemeinsames

/// Liest die Daten, die die Uhren-App in die App-Gruppe schreibt (`WatchWidgetExporter`).
enum ComplicationData {
    static func snapshot() -> WatchWidgetSnapshot? { WatchWidgetSnapshot.load() }

    /// Vorgerenderter Avatar; `small` = 72-px-Fassung (Ecke: WidgetKit erlaubt dort nur ca. 80 px)
    static func avatar(_ chat: WatchWidgetChat?, small: Bool = false) -> UIImage? {
        guard let file = chat?.avatarFile,
              let url = WatchWidgetSnapshot.avatarURL(small ? WatchWidgetSnapshot.smallAvatarName(file) : file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

extension Color {
    /// `#RRGGBB` (eigene kleine Fassung, die Erweiterung bringt das Theme nicht mit)
    static func widgetHex(_ hex: String?) -> Color {
        let s = (hex ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        let v = UInt64(s, radix: 16) ?? 0x3B94F6
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Avatar als Bild in voller Farbe (auch auf getönten Zifferblättern erkennbar)
struct ComplicationAvatar: View {
    var image: UIImage?
    var color: Color
    var name: String

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fit)
        } else {
            Text(String(name.prefix(1)))
                .font(.system(.title3, design: .rounded, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color.opacity(0.6), in: Circle())
        }
    }
}

// MARK: - Offene Freigaben

struct ApprovalsEntry: TimelineEntry {
    var date: Date
    var count: Int
    var first: WatchWidgetApproval?
    var more: Int
    var relevance: TimelineEntryRelevance? { TimelineEntryRelevance(score: count > 0 ? Float(40 + min(count, 10)) : 0) }
}

struct ApprovalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ApprovalsEntry {
        ApprovalsEntry(date: .now, count: 2, first: WatchWidgetSnapshot.preview.approvals.first, more: 1)
    }

    func getSnapshot(in context: Context, completion: @escaping (ApprovalsEntry) -> Void) {
        completion(context.isPreview && ComplicationData.snapshot() == nil ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ApprovalsEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func entry() -> ApprovalsEntry {
        let s = ComplicationData.snapshot()
        let count = s?.pendingApprovals ?? 0
        return ApprovalsEntry(date: .now, count: count, first: s?.approvals.first, more: max(0, count - 1))
    }
}

struct ApprovalsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ScoopsApprovals", provider: ApprovalsProvider()) { entry in
            ApprovalsComplicationView(entry: entry)
                .widgetURL(WatchRoute.approvalsURL)
        }
        .configurationDisplayName("Offene Freigaben")
        .description("Wie viele Freigaben deiner Scoops auf dich warten.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ApprovalsComplicationView: View {
    var entry: ApprovalsEntry
    @Environment(\.widgetFamily) private var family

    private var symbol: String { entry.count > 0 ? "checkmark.shield.fill" : "checkmark.seal" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(entry.count > 0 ? .orange : .secondary)
                        .widgetAccentable()
                    Text("\(entry.count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                }
            }
            .containerBackground(.clear, for: .widget)
            .accessibilityLabel(label)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(entry.count > 0 ? .orange : .secondary)
                .widgetAccentable()
                .widgetLabel { Text("\(entry.count) Freigaben") }
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Label(entry.count == 0 ? String(localized: "Keine Freigaben") : String(localized: "\(entry.count) Freigaben offen"),
                  systemImage: symbol)
                .containerBackground(.clear, for: .widget)
        default:
            rectangular
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [.orange.opacity(entry.count > 0 ? 0.55 : 0.2), .orange.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
    }

    private var label: String { String(localized: "\(entry.count) offene Freigaben") }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(.orange)
                    .widgetAccentable()
                Text("Freigaben")
                    .font(.headline)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text("\(entry.count)")
                    .font(.headline.monospacedDigit())
            }
            if let first = entry.first {
                Text(first.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(entry.more > 0 ? String(localized: "\(first.chatName) · +\(entry.more) weitere") : first.chatName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Alles erledigt")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ein Scoop

struct ScoopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scoop"
    static let defaultQuery = ScoopEntityQuery()

    var id: String
    var name: String
    var subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: subtitle.map { "\($0)" })
    }

    init(id: String, name: String, subtitle: String?) {
        self.id = id; self.name = name; self.subtitle = subtitle
    }

    init(_ chat: WatchWidgetChat) {
        id = chat.id
        name = chat.name
        subtitle = chat.isGroup ? String(localized: "Gruppe", comment: "Unterzeile eines Gruppenchats") : chat.label
    }
}

struct ScoopEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScoopEntity] {
        let chats = ComplicationData.snapshot()?.chats ?? []
        return identifiers.compactMap { id in chats.first { $0.id == id }.map(ScoopEntity.init) }
    }

    func suggestedEntities() async throws -> [ScoopEntity] {
        (ComplicationData.snapshot()?.chats ?? []).map(ScoopEntity.init)
    }

    func defaultResult() async -> ScoopEntity? {
        ComplicationData.snapshot()?.chats.first.map(ScoopEntity.init)
    }
}

struct SelectScoopIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Scoop wählen"
    static let description = IntentDescription("Zeigt einen Scoop auf dem Zifferblatt. Ein Tipp öffnet den Chat zum Diktieren.")

    @Parameter(title: "Scoop")
    var scoop: ScoopEntity?

    init() {}
    init(scoop: ScoopEntity) { self.scoop = scoop }
}

struct ScoopEntry: TimelineEntry {
    var date: Date
    var chat: WatchWidgetChat?
    var avatar: UIImage?
    var smallAvatar: UIImage? { ComplicationData.avatar(chat, small: true) }
    var relevance: TimelineEntryRelevance? {
        guard let chat else { return nil }
        return TimelineEntryRelevance(score: chat.waiting ? 30 : (chat.unread > 0 ? 20 : 1))
    }
}

struct ScoopProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ScoopEntry {
        ScoopEntry(date: .now, chat: WatchWidgetSnapshot.preview.chats.first, avatar: nil)
    }

    func snapshot(for configuration: SelectScoopIntent, in context: Context) async -> ScoopEntry {
        entry(for: configuration) ?? placeholder(in: context)
    }

    func timeline(for configuration: SelectScoopIntent, in context: Context) async -> Timeline<ScoopEntry> {
        Timeline(entries: [entry(for: configuration) ?? ScoopEntry(date: .now, chat: nil, avatar: nil)],
                 policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    /// watchOS: Jeder Scoop erscheint beim Einrichten des Zifferblatts als eigene Komplikation
    func recommendations() -> [AppIntentRecommendation<SelectScoopIntent>] {
        (ComplicationData.snapshot()?.chats ?? []).prefix(12).map { chat in
            AppIntentRecommendation(intent: SelectScoopIntent(scoop: ScoopEntity(chat)), description: Text(chat.name))
        }
    }

    private func entry(for configuration: SelectScoopIntent) -> ScoopEntry? {
        let snapshot = ComplicationData.snapshot()
        let chat = configuration.scoop.flatMap { snapshot?.chat($0.id) } ?? snapshot?.chats.first
        guard let chat else { return nil }
        return ScoopEntry(date: .now, chat: chat, avatar: ComplicationData.avatar(chat))
    }
}

struct ScoopComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScoopsScoop", intent: SelectScoopIntent.self, provider: ScoopProvider()) { entry in
            ScoopComplicationView(entry: entry)
                .widgetURL(entry.chat.map { WatchRoute.chatURL($0.id, compose: true) } ?? WatchRoute.homeURL)
        }
        .configurationDisplayName("Scoop")
        .description("Ein Scoop auf dem Zifferblatt. Antippen öffnet den Chat zum Diktieren.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ScoopComplicationView: View {
    var entry: ScoopEntry
    @Environment(\.widgetFamily) private var family

    private var name: String { entry.chat?.name ?? "Scoop" }
    private var color: Color { Color.widgetHex(entry.chat?.color) }
    private var unread: Int { entry.chat?.unread ?? 0 }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                ComplicationAvatar(image: entry.avatar, color: color, name: name)
                    .padding(3)
            }
            .overlay(alignment: .topTrailing) {
                // Innerhalb des Kreises (die runde Komplikation schneidet die Ecken ab)
                if entry.chat?.waiting == true || unread > 0 {
                    Circle()
                        .fill(entry.chat?.waiting == true ? Color.red : Color.blue)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                        .widgetAccentable()
                        .padding(5)
                }
            }
            .containerBackground(.clear, for: .widget)
            .accessibilityLabel(accessibility)
        case .accessoryCorner:
            ComplicationAvatar(image: entry.smallAvatar, color: color, name: name)
                .padding(2)
                .widgetLabel { Text(unread > 0 ? "\(name) · \(unread)" : name) }
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Text(unread > 0 ? String(localized: "\(name) · \(unread) neu")
                 : (entry.chat?.waiting == true ? String(localized: "\(name) wartet") : name))
                .containerBackground(.clear, for: .widget)
        default:
            HStack(spacing: 7) {
                ComplicationAvatar(image: entry.avatar, color: color, name: name)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                            .widgetAccentable()
                        if unread > 0 {
                            Text("· \(unread)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if entry.chat?.waiting == true {
                            Image(systemName: "questionmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    Text(entry.chat?.preview ?? String(localized: "Antippen und diktieren"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .containerBackground(for: .widget) {
                LinearGradient(colors: [color.opacity(0.55), color.opacity(0.12)], startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
            .accessibilityLabel(accessibility)
        }
    }

    private var accessibility: String {
        var parts = [name]
        if unread > 0 { parts.append(String(localized: "\(unread) ungelesen")) }
        if entry.chat?.waiting == true { parts.append(String(localized: "wartet auf dich")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Deep Links (gleiches Format wie `WatchRoute` in der App)

enum WatchRoute {
    static let scheme = "aisscoops-watch"
    static var approvalsURL: URL { URL(string: "\(scheme)://approvals")! }
    static var homeURL: URL { URL(string: "\(scheme)://home")! }
    static func chatURL(_ id: String, compose: Bool) -> URL {
        URL(string: "\(scheme)://chat/\(id)\(compose ? "?compose=1" : "")")!
    }
}

// MARK: - Vorschau (liest die Demo-Daten, die die Uhren-App mit `-demo` in die App-Gruppe schreibt)

extension ScoopEntry {
    static func preview(_ id: String) -> ScoopEntry {
        let chat = ComplicationData.snapshot()?.chat(id) ?? WatchWidgetSnapshot.preview.chats.first { $0.id == id }
            ?? WatchWidgetSnapshot.preview.chats[0]
        return ScoopEntry(date: .now, chat: chat, avatar: ComplicationData.avatar(chat))
    }
}

extension ApprovalsEntry {
    static var preview: ApprovalsEntry {
        let s = ComplicationData.snapshot() ?? WatchWidgetSnapshot.preview
        return ApprovalsEntry(date: .now, count: s.pendingApprovals, first: s.approvals.first,
                              more: max(0, s.pendingApprovals - 1))
    }
}

#Preview("Freigaben rund", as: .accessoryCircular) {
    ApprovalsComplication()
} timeline: {
    ApprovalsEntry.preview
}

#Preview("Freigaben rechteckig", as: .accessoryRectangular) {
    ApprovalsComplication()
} timeline: {
    ApprovalsEntry.preview
}

#Preview("Freigaben Ecke", as: .accessoryCorner) {
    ApprovalsComplication()
} timeline: {
    ApprovalsEntry.preview
}

#Preview("Freigaben Zeile", as: .accessoryInline) {
    ApprovalsComplication()
} timeline: {
    ApprovalsEntry.preview
}

#Preview("Scoop rund", as: .accessoryCircular) {
    ScoopComplication()
} timeline: {
    ScoopEntry.preview("b_lucy")
    ScoopEntry.preview("b_mila")
    ScoopEntry.preview("g_team")
}

#Preview("Scoop rechteckig", as: .accessoryRectangular) {
    ScoopComplication()
} timeline: {
    ScoopEntry.preview("b_lucy")
    ScoopEntry.preview("b_theo")
}

#Preview("Scoop Ecke", as: .accessoryCorner) {
    ScoopComplication()
} timeline: {
    ScoopEntry.preview("b_lucy")
}

#Preview("Scoop Zeile", as: .accessoryInline) {
    ScoopComplication()
} timeline: {
    ScoopEntry.preview("b_lucy")
}
