import SwiftUI
import WidgetKit

// Widget-Oberflächen. Liegen im Shared-Ordner, damit die App sie für Vorschaubilder rendern kann.

extension Theme {
    /// Widgets folgen dem System: dunkel = Nacht, hell = Hell.
    static func forScheme(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .nacht : .hell }
}

/// Kleines Widget: ein gewählter Scoop.
struct ScoopSmallView: View {
    var bot: WidgetBot?
    var theme: Theme

    var body: some View {
        if let bot {
            VStack(alignment: .leading, spacing: 0) {
                WidgetBrand(theme: theme)
                    .padding(.bottom, 2)
                HStack(alignment: .top) {
                    MascotView(mascot: bot.mascot, size: 56, mood: bot.busy ? .workingStill : .idle,
                               seed: bot.id, animated: false)
                        .padding(.leading, -5)
                    Spacer(minLength: 0)
                    if bot.unread > 0 { UnreadBadge(count: bot.unread, theme: theme) }
                }
                Spacer(minLength: 2)
                Text(bot.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if bot.busy {
                    HStack(spacing: 3) {
                        Text("Arbeitet")
                        Text("·")
                        if let start = bot.runStartedAt {
                            Text("seit \(Text(start, style: .timer))")
                        }
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    Text(bot.statusLine ?? String(localized: "Arbeitet …"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                } else {
                    if let label = bot.label, !label.isEmpty {
                        Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
                    }
                    Text(bot.lastMessagePreview ?? String(localized: "Noch keine Nachrichten"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(bot.deepLink)
        } else {
            VStack(spacing: 6) {
                MascotView(mascot: .brand, size: 50, seed: "app-icon", animated: false)
                Text("Scoop wählen")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("Halte das Widget gedrückt, um einen Scoop auszusuchen.")
                    .font(.system(size: 10.5)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            }
        }
    }
}

/// Dezente Absenderzeile oben links: nur der Schriftzug „AIS Scoops“.
/// Absender oben links: das bunte AIS-Scoops-Logo (Lockup, Hell/Dunkel aus WidgetAssets)
struct WidgetBrand: View {
    var theme: Theme

    var body: some View {
        LimitsLogo(height: 12)
    }
}

/// Mittleres und großes Widget: Raster mehrerer Scoops für den Direktzugriff.
struct ScoopGridView: View {
    var bots: [WidgetBot]
    var large: Bool
    var featured: WidgetBot?
    var theme: Theme
    /// ImageRenderer kann `Link` nicht darstellen; für Vorschaubilder abschaltbar.
    var linkable: Bool = true

    var body: some View {
        let busy = bots.filter(\.busy).count
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            HStack {
                WidgetBrand(theme: theme)
                Spacer()
                if busy > 0 {
                    Text("\(busy) arbeiten")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.accent)
                }
            }
            if bots.isEmpty {
                Text("Noch keine Scoops. Öffne AIS Scoops, um loszulegen.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = large ? 2 : 1
                VStack(spacing: large ? 8 : 0) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(0..<4, id: \.self) { c in
                                let idx = r * 4 + c
                                if idx < bots.count {
                                    if linkable {
                                        Link(destination: bots[idx].deepLink) { cell(bots[idx]) }
                                    } else {
                                        cell(bots[idx])
                                    }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: large ? nil : .infinity)
            }
            if large, let f = featured {
                if linkable {
                    Link(destination: f.deepLink) { featuredCard(f) }
                } else {
                    featuredCard(f)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func cell(_ bot: WidgetBot) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                MascotView(mascot: bot.mascot, size: 52, mood: bot.busy ? .workingStill : .idle, seed: bot.id, animated: false)
                if bot.unread > 0 { UnreadBadge(count: bot.unread, theme: theme).offset(x: 4, y: 0) }
            }
            Text(bot.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Group {
                if bot.busy, let start = bot.runStartedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(theme.accent)
                } else if bot.busy {
                    Text("Arbeitet").foregroundStyle(theme.accent)
                } else {
                    Text(bot.label ?? " ").foregroundStyle(theme.textTertiary)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(bot.busy ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func featuredCard(_ bot: WidgetBot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MascotView(mascot: bot.mascot, size: 34, mood: bot.busy ? .workingStill : .idle, seed: bot.id, animated: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(bot.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let at = bot.lastMessageAt {
                        Text(at, style: .time).font(.system(size: 10.5)).foregroundStyle(theme.textTertiary)
                    }
                }
                Text(bot.busy ? (bot.statusLine ?? String(localized: "Arbeitet …")) : (bot.lastMessagePreview ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.surfaceBorder))
    }
}

struct UnreadBadge: View {
    var count: Int
    var theme: Theme

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(theme.textOnAccent)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(theme.unreadDot, in: Capsule())
    }
}

/// Sperrbildschirm rund: Zahl der arbeitenden Scoops.
struct ScoopCountAccessoryView: View {
    var busyCount: Int

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: busyCount > 0 ? "sparkles" : "moon.zzz")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(busyCount)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
        }
        .accessibilityLabel("\(busyCount) Scoops arbeiten")
    }
}

/// Sperrbildschirm rechteckig: Status eines Scoops.
struct ScoopStatusAccessoryView: View {
    var bot: WidgetBot?

    var body: some View {
        if let bot {
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.headline).widgetAccentable()
                if bot.busy {
                    HStack(spacing: 3) {
                        Text("Arbeitet ·")
                        if let s = bot.runStartedAt { Text(s, style: .timer).monospacedDigit() }
                    }
                    .font(.caption)
                    Text(bot.statusLine ?? "").font(.caption2).lineLimit(1)
                } else {
                    Text(bot.lastMessagePreview ?? String(localized: "Ruht", comment: "Scoop arbeitet gerade nicht")).font(.caption).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(bot.deepLink)
        } else {
            Text("Kein Scoop gewählt").font(.caption)
        }
    }
}

/// Sperrbildschirm rund: ein Scoop als Figur. Arbeitet er, liegt ein Ring um ihn; ungelesene Nachrichten zeigt ein Punkt.
struct ScoopAvatarAccessoryView: View {
    var bot: WidgetBot?

    var body: some View {
        if let bot {
            ZStack {
                AccessoryWidgetBackground()
                MascotView(mascot: bot.mascot, size: 50, mood: bot.busy ? .workingStill : .idle, seed: bot.id, animated: false)
                    .widgetAccentable()
                if bot.busy {
                    Circle().strokeBorder(lineWidth: 2.5).widgetAccentable()
                } else if bot.unread > 0 {
                    Circle().frame(width: 10, height: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(5)
                        .widgetAccentable()
                }
            }
            .widgetURL(bot.deepLink)
            .accessibilityLabel(bot.busy ? String(localized: "\(bot.name) arbeitet")
                                : (bot.unread > 0 ? String(localized: "\(bot.name), neue Nachricht") : bot.name))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 22))
            }
            .accessibilityLabel("Kein Scoop gewählt")
        }
    }
}
