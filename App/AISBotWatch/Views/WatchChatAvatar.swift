import SwiftUI

/// Avatar eines Chats auf der Uhr: Maskottchen bzw. eigenes Bild eines Scoops, bei Gruppen bis zu drei Mitglieder.
struct WatchChatAvatar: View {
    var chat: WatchChat
    var size: CGFloat
    var animated = true
    var showsWaiting = true

    var body: some View {
        avatar
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if showsWaiting && chat.waiting {
                    Text("?")
                        .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(Color.red, in: Circle())
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                        .offset(x: size * 0.08, y: -size * 0.06)
                        .accessibilityLabel("Wartet auf dich")
                }
            }
    }

    @ViewBuilder private var avatar: some View {
        if let mascot = chat.mascot {
            MascotView(mascot: mascot, size: size, mood: chat.busy ? .working : .idle, seed: chat.id,
                       animated: animated && chat.busy)
        } else if !chat.members.isEmpty {
            MemberCluster(members: Array(chat.members.prefix(3)), size: size, seed: chat.id)
        } else {
            Image(systemName: "person.3.fill")
                .font(.system(size: size * 0.38))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.gray.opacity(0.25), in: Circle())
        }
    }
}

/// Gruppenavatar: bis zu drei Maskottchen, vollständig im Rahmen
struct MemberCluster: View {
    var members: [Mascot]
    var size: CGFloat
    var seed: String

    var body: some View {
        let m = size * (members.count >= 3 ? 0.56 : 0.62)
        let d = (size - m) / 2 * 0.86
        ZStack {
            ForEach(Array(members.enumerated()), id: \.offset) { idx, mascot in
                MascotView(mascot: mascot, size: m, seed: "\(seed)-\(idx)", animated: false)
                    .offset(offset(idx, count: members.count, d: d))
                    .zIndex(Double(3 - idx))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func offset(_ idx: Int, count: Int, d: CGFloat) -> CGSize {
        switch (count, idx) {
        case (1, _): .zero
        case (2, 0): CGSize(width: -d * 0.8, height: -d * 0.55)
        case (2, _): CGSize(width: d * 0.8, height: d * 0.6)
        case (_, 0): CGSize(width: 0, height: -d * 0.95)
        case (_, 1): CGSize(width: -d, height: d * 0.75)
        default: CGSize(width: d, height: d * 0.75)
        }
    }
}
