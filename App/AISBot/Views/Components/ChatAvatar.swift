import SwiftUI

/// Avatar eines Chats: Maskottchen eines Scoops oder Cluster aus bis zu drei Mitgliedern einer Gruppe.
struct ChatAvatar: View {
    let chatID: String
    var size: CGFloat
    /// Animiert (Arbeits-Pose), wenn der Chat beschäftigt ist.
    var animateWhenBusy = true
    /// Rotes „?“ oben rechts, wenn der Scoop auf den Nutzer wartet (Seitenleiste, angeheftete Kacheln)
    var showsWaiting = false
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        avatar
            .overlay(alignment: .topTrailing) {
                if showsWaiting && store.isWaiting(chatID) {
                    WaitingBadge(size: max(17, size * 0.4))
                        .offset(x: size * 0.06, y: -size * 0.04)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: showsWaiting && store.isWaiting(chatID))
    }

    @ViewBuilder private var avatar: some View {
        if let bot = store.bot(chatID) {
            let busy = store.isBusy(chatID)
            if busy && !animateWhenBusy && !reduceMotion && bot.mascot.photo == nil {
                // Seitenleiste & Co.: statt Funken schaukelt der Scoop von Seite zu Seite. Das Bild bleibt statisch
                // (Cache), nur die Drehung läuft als Animation im Render-Server – günstig auch bei vielen Scoops.
                // Scoops mit eigenem Bild schaukeln nicht, sie leuchten (ScoopPhotoGlow, auch bei .workingStill).
                MascotView(mascot: bot.mascot, size: size, mood: .working, seed: bot.id, animated: false)
                    .modifier(WorkingWobble(seed: bot.id))
            } else {
                MascotView(mascot: bot.mascot, size: size,
                           mood: busy ? (animateWhenBusy ? .working : .workingStill) : .idle, seed: bot.id,
                           animated: busy && animateWhenBusy)
            }
        } else if let group = store.group(chatID) {
            GroupAvatar(members: group.memberIds.compactMap { store.bot($0) }, size: size,
                        busyIDs: Set(group.busyIds).union(store.typing[chatID] ?? []))
        } else {
            Circle().fill(.gray.opacity(0.2)).frame(width: size, height: size)
        }
    }
}

/// Arbeitender Scoop (Maskottchen, nicht eigenes Bild): wackelt gleichmäßig von Seite zu Seite (um den Fußpunkt). Jeder Scoop startet etwas versetzt,
/// damit mehrere arbeitende Scoops nicht im Gleichtakt schaukeln.
struct WorkingWobble: ViewModifier {
    var seed: String
    var angle: Double = 10
    @State private var swing = false

    func body(content: Content) -> some View {
        let delay = Double(abs(seed.hashValue % 400)) / 1000
        content
            .rotationEffect(.degrees(swing ? angle : -angle), anchor: .bottom)
            .onAppear {
                swing = false
                withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(delay)) { swing = true }
            }
    }
}

/// Rotes Kennzeichen „?“: Der Scoop wartet auf dich (Freigabe oder Rückfrage). Bewusst ohne Zahl.
struct WaitingBadge: View {
    var size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        Text("?")
            .font(.system(size: size * 0.68, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(theme.danger, in: Circle())
            .overlay(Circle().strokeBorder(theme.sidebarBackground, lineWidth: max(1.5, size * 0.11)))
            .accessibilityLabel("Wartet auf dich")
    }
}

/// Kleiner Haufen aus bis zu drei Maskottchen (Gruppenavatar).
struct GroupAvatar: View {
    let members: [Bot]
    var size: CGFloat
    var busyIDs: Set<String> = []

    var body: some View {
        let shown = Array(members.prefix(3))
        // Mitglieder so klein, dass der Stapel samt Fell vollständig in den Rahmen passt (nichts abgeschnitten)
        let m = size * (shown.count >= 3 ? 0.56 : 0.62)
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, bot in
                MascotView(mascot: bot.mascot, size: m, mood: busyIDs.contains(bot.id) ? .working : .idle,
                           seed: bot.id, animated: false)
                    .offset(offset(idx, count: shown.count, member: m))
                    .zIndex(Double(3 - idx))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Versatz innerhalb des Rahmens: höchstens (Rahmen − Mitglied) / 2, abzüglich Platz fürs Fell.
    private func offset(_ idx: Int, count: Int, member m: CGFloat) -> CGSize {
        let d = (size - m) / 2 * 0.86
        switch (count, idx) {
        case (1, _): return .zero
        case (2, 0): return CGSize(width: -d * 0.8, height: -d * 0.55)
        case (2, _): return CGSize(width: d * 0.8, height: d * 0.6)
        case (_, 0): return CGSize(width: 0, height: -d * 0.95)
        case (_, 1): return CGSize(width: -d, height: d * 0.75)
        default: return CGSize(width: d, height: d * 0.75)
        }
    }
}

/// „Schlüpfen“: Maskottchen ploppt auf, wackelt und funkelt, solange der Server einen Scoop/eine Gruppe anlegt.
struct HatchingAvatar: View {
    var mascot: Mascot?
    var members: [Bot] = []
    var size: CGFloat
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Group {
                    if let mascot {
                        MascotView(mascot: mascot, size: size, mood: .workingStill, seed: "hatch-\(mascot.color)", animated: false)
                    } else {
                        GroupAvatar(members: members, size: size)
                    }
                }
                .rotationEffect(.degrees(reduceMotion ? 0 : sin(t * 9) * 6), anchor: .bottom)
                .scaleEffect(appeared ? 1 : 0.15, anchor: .bottom)
                .opacity(appeared ? 1 : 0)
                ForEach(0..<3, id: \.self) { i in
                    let a = t * 2.2 + Double(i) * 2.1
                    Image(systemName: "sparkle")
                        .font(.system(size: size * (0.16 + 0.05 * Double(i))))
                        .foregroundStyle(Color(hex: "#FFD84D"))
                        .opacity(0.5 + 0.5 * sin(a * 1.7))
                        .offset(x: cos(a) * size * 0.55, y: sin(a) * size * 0.45 - size * 0.1)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.55)) { appeared = true } }
        .accessibilityHidden(true)
    }
}
