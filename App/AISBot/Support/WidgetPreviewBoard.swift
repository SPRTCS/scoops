#if os(macOS)
import SwiftUI

/// Vorschaubilder der Widgets mit Demo-Daten (für Screenshots/README).
enum WidgetPreviewBoard {
    static var snapshot: WidgetSnapshot {
        let bots = PreviewData.bots.map { b -> WidgetBot in
            let running = PreviewData.messages[b.id]?.last(where: { $0.isRunning })
            return WidgetBot(id: b.id, name: b.name, label: b.label, mascot: b.mascot, pinned: b.pinned, busy: b.busy,
                             statusLine: b.busy ? running?.meta.lines?.last : nil,
                             runStartedAt: b.busy ? running?.meta.startedAt : nil,
                             unread: b.unread, lastMessagePreview: b.lastMessage?.previewText,
                             lastMessageAt: b.lastMessage?.createdAt)
        }
        return WidgetSnapshot(generatedAt: Date(), userName: "Arman", bots: bots)
    }

    static func boards() -> [(String, AnyView)] {
        [("widgets-nacht", AnyView(board(.nacht))), ("widgets-hell", AnyView(board(.hell)))]
    }

    private static func board(_ theme: Theme) -> some View {
        let snap = snapshot
        let ordered = snap.orderedBots
        let mila = snap.bot("b_mila")
        let lio = snap.bot("b_lio")
        let featured = ordered.max { ($0.lastMessageAt ?? .distantPast) < ($1.lastMessageAt ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 22) {
                frame(theme, w: 170, h: 170) { ScoopSmallView(bot: mila, theme: theme) }
                frame(theme, w: 170, h: 170) { ScoopSmallView(bot: lio, theme: theme) }
                VStack(spacing: 16) {
                    accessory(theme) { ScoopCountAccessoryView(busyCount: snap.busyCount).frame(width: 68, height: 68) }
                    accessory(theme) { ScoopStatusAccessoryView(bot: mila).frame(width: 160, height: 68) }
                }
            }
            frame(theme, w: 364, h: 170) { ScoopGridView(bots: Array(ordered.prefix(4)), large: false, featured: nil, theme: theme, linkable: false) }
            frame(theme, w: 364, h: 382) { ScoopGridView(bots: Array(ordered.prefix(8)), large: true, featured: featured, theme: theme, linkable: false) }
        }
        .padding(32)
        .background(
            LinearGradient(colors: theme.kind == .nacht ? [Color(hex: "#20263A"), Color(hex: "#3B2A4F")]
                                                        : [Color(hex: "#D9DEE6"), Color(hex: "#EEF0F4")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.colorScheme)
    }

    private static func frame<C: View>(_ theme: Theme, w: CGFloat, h: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(width: w, height: h)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.background)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous).inset(by: -20))
    }

    private static func accessory<C: View>(_ theme: Theme, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
