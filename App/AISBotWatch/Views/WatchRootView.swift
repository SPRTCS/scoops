import SwiftUI

struct WatchRootView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            Group {
                if store.mode == .unconfigured {
                    ConnectView()
                } else {
                    ChatListView()
                }
            }
            .navigationDestination(for: WatchDestination.self) { destination in
                switch destination {
                case .chat(let id): ChatView(chatID: id, anchor: WatchLaunch.chatAnchor)
                case .approvals: ApprovalsView()
                }
            }
        }
    }
}

// MARK: - Scoop-Liste

struct ChatListView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        let chats = store.chats
        List {
            if !store.approvals.isEmpty {
                NavigationLink(value: WatchDestination.approvals) {
                    ApprovalsBanner(count: store.approvals.count)
                }
                .listRowBackground(Color.clear)
            }
            if let error = store.errorMessage, chats.isEmpty || store.lastUpdated == nil {
                ErrorRow(text: error) { Task { await store.refresh() } }
            }
            let scoops = chats.filter { !$0.isGroup }
            if !scoops.isEmpty {
                Section {
                    ForEach(scoops) { chat in
                        NavigationLink(value: WatchDestination.chat(chat.id)) { ChatRow(chat: chat) }
                    }
                }
            }
            let groups = chats.filter(\.isGroup)
            if !groups.isEmpty {
                Section("Gruppen") {
                    ForEach(groups) { chat in
                        NavigationLink(value: WatchDestination.chat(chat.id)) { ChatRow(chat: chat) }
                    }
                }
            }
            if chats.isEmpty && store.loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
            Section { FooterRows() }
        }
        .navigationTitle("Scoops")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("Aktualisieren")
            }
        }
        .task { await store.refresh() }
    }
}

struct ApprovalsBanner: View {
    var count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.body)
                .foregroundStyle(.orange)
            Text("Freigaben")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count == 1 ? "1 offene Freigabe" : "\(count) offene Freigaben")
    }
}

struct ChatRow: View {
    var chat: WatchChat

    var body: some View {
        HStack(spacing: 9) {
            WatchChatAvatar(chat: chat, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(chat.name)
                        .font(.headline)
                        .lineLimit(1)
                    if chat.busy {
                        Image(systemName: "ellipsis")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                }
                if let preview = chat.preview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(chat.unread > 0 ? .primary : .secondary)
                        .lineLimit(2)
                } else if let label = chat.label {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if chat.unread > 0 {
                Text("\(chat.unread)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel("\(chat.unread) ungelesen")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorRow: View {
    var text: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Erneut versuchen", action: retry)
                .buttonStyle(.glass)
        }
        .listRowBackground(Color.clear)
    }
}

/// Server-Wahl, Demo-Hinweis, Stand
private struct FooterRows: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        if store.servers.count > 1 {
            NavigationLink {
                ServerPickerView()
            } label: {
                Label(store.activeServer?.name ?? "Server", systemImage: "server.rack")
                    .font(.footnote)
            }
        }
        if store.mode == .demo {
            VStack(alignment: .leading, spacing: 4) {
                Label("Demo-Modus", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                Text("Beispieldaten, nichts wird gesendet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if store.credentials?.demo != true {
                    Button("Demo beenden") { store.leaveDemo() }
                        .font(.footnote)
                }
            }
        } else if let updated = store.lastUpdated {
            HStack(spacing: 4) {
                if store.viaPhone { Image(systemName: "iphone") }
                Text("Stand \(updated.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
        }
    }
}

struct ServerPickerView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(store.servers) { server in
            Button {
                store.selectServer(server.id)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(server.name).font(.headline)
                        if let host = server.baseURLs.first?.host() {
                            Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if server.id == store.activeServerID {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Server")
    }
}

// MARK: - Nicht verbunden

struct ConnectView: View {
    @Environment(WatchStore.self) private var store
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                MascotView(mascot: WatchDemo.lucy.mascot, size: 54, seed: "connect", animated: false)
                Text("Mit dem iPhone verbinden")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Öffne AIS Scoops auf deinem iPhone. Die Uhr übernimmt die Verbindung automatisch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    asking = true
                    Task {
                        await store.askPhone()
                        asking = false
                    }
                } label: {
                    if asking { ProgressView() } else { Label("Erneut versuchen", systemImage: "iphone") }
                }
                .buttonStyle(.glassProminent)
                Button("Demo ansehen") { store.enterDemo() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("AIS Scoops")
    }
}
