#if DEBUG
import SwiftUI

/// Vorschauen mit Demo-Daten (auch für die Screenshots in App/Screenshots/watch/)
private func demoStore() -> WatchStore { WatchStore(arguments: ["-demo"]) }

private struct PreviewHost<Content: View>: View {
    @State private var store = demoStore()
    @ViewBuilder var content: (WatchStore) -> Content

    var body: some View {
        NavigationStack { content(store) }
            .environment(store)
            .environment(\.theme, .nacht)
    }
}

#Preview("1 Scoops") {
    PreviewHost { _ in ChatListView() }
}

#Preview("2 Chat") {
    PreviewHost { _ in ChatView(chatID: "b_lucy", anchor: .top) }
}

#Preview("2b Chat unten") {
    PreviewHost { _ in ChatView(chatID: "b_lucy") }
}

#Preview("3 Eingabe") {
    PreviewHost { _ in ComposeView(chatID: "b_lucy") }
}

#Preview("4 Freigabe-Karte") {
    PreviewHost { store in
        ScrollView {
            if let card = store.messages["b_lucy"]?.last { ApprovalCard(message: card) }
        }
        .navigationTitle("Lucy")
    }
}

#Preview("5 Freigaben") {
    PreviewHost { _ in ApprovalsView() }
}

#Preview("6 Gruppe") {
    PreviewHost { _ in ChatView(chatID: "g_team", anchor: .top) }
}

#Preview("7 Verbinden") {
    @Previewable @State var store = WatchStore(arguments: [])
    NavigationStack { ConnectView() }
        .environment(store)
}
#endif
