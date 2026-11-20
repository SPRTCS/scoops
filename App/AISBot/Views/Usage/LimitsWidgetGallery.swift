import SwiftUI

/// Nur für Screenshots/Prüfung (`-mock -settings -usage -widgetgallery`): das Widget „Abo-Limits“ in allen drei
/// Größen mit denselben Ansichten wie die Widget-Erweiterung, hell und dunkel.
struct LimitsWidgetGallery: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var snapshot: LimitsSnapshot = .demo(now: PreviewData.clock)
    /// iPhone-Größen der Widget-Familien (pt)
    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)
    private let large = CGSize(width: 364, height: 382)

    var body: some View {
        let theme = Theme.forScheme(scheme)
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 20) {
                    tile(.small, small, theme)
                    tile(.small, small, theme, snap: LimitsSnapshot(generatedAt: PreviewData.clock, providers: [
                        snapshot.providers[0],
                        .init(id: "openai", name: "Codex", plan: nil, state: "not_logged_in", windows: []),
                    ]))
                }
                tile(.medium, medium, theme)
                tile(.large, large, theme)
                tile(.medium, medium, theme, snap: LimitsSnapshot(generatedAt: PreviewData.clock, providers: []))
                // Scoops-Widgets mit demselben Logo
                HStack(spacing: 20) {
                    frame(small, theme) { ScoopSmallView(bot: demoBots.first, theme: theme) }
                    frame(small, theme) { ScoopSmallView(bot: demoBots[1], theme: theme) }
                }
                frame(medium, theme) {
                    ScoopGridView(bots: demoBots, large: false, featured: demoBots[0], theme: theme, linkable: false)
                }
                frame(large, theme) {
                    ScoopGridView(bots: demoBots, large: true, featured: demoBots[0], theme: theme, linkable: false)
                }
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: scheme == .dark ? [Color(hex: "#1B2440"), Color(hex: "#05060A")]
                                                            : [Color(hex: "#9CC3FF"), Color(hex: "#E9D9FF")],
                                    startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onTapGesture(count: 2) { dismiss() }
    }

    private func frame<C: View>(_ dim: CGSize, _ theme: Theme, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(width: dim.width, height: dim.height)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .environment(\.theme, theme)
    }

    private var demoBots: [WidgetBot] {
        let now = PreviewData.clock
        return [
            WidgetBot(id: "b_mila", name: "Mila", label: demoText("Assistenz", en: "Assistant"),
                      mascot: Mascot(shape: "bean", color: "#8B5CF6", eyes: "dots", accessory: "bowtie"),
                      pinned: true, busy: true, statusLine: demoText("Ist im Browser auf booking.com", en: "Browses booking.com"),
                      runStartedAt: now.addingTimeInterval(-72), unread: 0,
                      lastMessagePreview: demoText("Guten Morgen Arman! Das steht heute an …", en: "Good morning, Arman! Here’s what’s on today…"), lastMessageAt: now),
            WidgetBot(id: "b_theo", name: "Theo", label: demoText("Recherche", en: "Research"),
                      mascot: Mascot(shape: "cloud", color: "#3D84F5", eyes: "ovals", accessory: "glasses"),
                      pinned: true, busy: false, statusLine: nil, runStartedAt: nil, unread: 1,
                      lastMessagePreview: demoText("Die drei wichtigsten Punkte …", en: "The three key points…"), lastMessageAt: now.addingTimeInterval(-3600)),
            WidgetBot(id: "b_lio", name: "Lio", label: "Social Media",
                      mascot: Mascot(shape: "star", color: "#FFB524", eyes: "sparkle", accessory: "beret"),
                      pinned: false, busy: false, statusLine: nil, runStartedAt: nil, unread: 2,
                      lastMessagePreview: demoText("Freigabe: Post auf X veröffentlichen", en: "Approval: Publish post on X"), lastMessageAt: now.addingTimeInterval(-7200)),
            WidgetBot(id: "b_nora", name: "Nora", label: demoText("Finanzen", en: "Finance"),
                      mascot: Mascot(shape: "egg", color: "#22BFAE", eyes: "happy", accessory: "headphones"),
                      pinned: false, busy: false, statusLine: nil, runStartedAt: nil, unread: 0,
                      lastMessagePreview: demoText("Dein Oktober ist durch …", en: "October is wrapped up…"), lastMessageAt: now.addingTimeInterval(-9000)),
        ]
    }

    private func tile(_ size: LimitsWidgetSize, _ dim: CGSize, _ theme: Theme, snap: LimitsSnapshot? = nil) -> some View {
        LimitsWidgetView(snapshot: snap ?? snapshot, size: size, theme: theme)
            .padding(16)
            .frame(width: dim.width, height: dim.height)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .environment(\.theme, theme)
    }
}
