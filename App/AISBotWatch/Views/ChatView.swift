import SwiftUI

/// Chat auf der Uhr: die letzten Nachrichten, Freigabe-Karten und unten „Antworten“.
struct ChatView: View {
    var chatID: String
    /// Startposition (Vorschau/Screenshots: `.top`)
    var anchor: UnitPoint = .bottom
    @Environment(WatchStore.self) private var store
    @State private var composing = false

    /// So viele Nachrichten zeigt die Uhr (ältere bleiben am iPhone)
    static let visibleCount = 30

    var body: some View {
        let chat = store.chat(chatID)
        let all = store.messages[chatID] ?? []
        let visible = Self.visible(all)
        ScrollView {
            LazyVStack(spacing: 7) {
                if store.loadingChats.contains(chatID) && all.isEmpty {
                    ProgressView().padding(.top, 20)
                } else if all.isEmpty {
                    Text("Noch keine Nachrichten")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                ForEach(visible) { message in
                    MessageRow(message: message, isGroup: ChatGroup.isGroupID(chatID))
                        .id(message.id)
                }
                Button {
                    composing = true
                } label: {
                    Label("Antworten", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 6)
                .id("compose")
            }
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(anchor)
        .navigationTitle(chat?.name ?? "Chat")
        .toolbar {
            if chat?.busy == true, store.mode == .live {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.stop(chatID) }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("Anhalten")
                }
            }
        }
        .sheet(isPresented: $composing) {
            ComposeView(chatID: chatID)
        }
        .task(id: chatID) {
            if store.pendingCompose == chatID {
                store.pendingCompose = nil
                composing = true
            }
            store.markRead(chatID)
            await store.loadMessages(chatID)
            await store.poll(chatID)
        }
    }

    /// Letzte Nachrichten; abgeschlossene Statuszeilen entfallen (auf der Uhr zählt das Ergebnis)
    static func visible(_ all: [Message]) -> [Message] {
        let lastStatus = all.last { $0.role == .status }?.id
        return Array(all.filter { m in
            switch m.role {
            case .status: m.id == lastStatus && m.isRunning
            case .unknown: false
            default: true
            }
        }.suffix(visibleCount))
    }
}

// MARK: - Nachricht

struct MessageRow: View {
    var message: Message
    var isGroup: Bool
    @Environment(WatchStore.self) private var store

    var body: some View {
        switch message.role {
        case .user: UserBubble(message: message)
        case .bot: BotBubble(message: message, author: author)
        case .approval: ApprovalCard(message: message)
        case .event: EventLine(message: message)
        case .status: StatusLine(message: message, name: author?.name ?? store.chat(message.chatId)?.name ?? "Scoop")
        case .unknown: EmptyView()
        }
    }

    /// Autor in Gruppen bzw. bei Nachrichten anderer Scoops
    private var author: Bot? {
        let id = message.meta.authorId
        if isGroup || (id != nil && id != message.chatId) { return store.bot(id) }
        return nil
    }
}

struct UserBubble: View {
    var message: Message
    @Environment(WatchStore.self) private var store

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 2) {
                ExpandableText(text: message.text, foreground: .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(message.localState == .sending ? 0.6 : 1)
                if message.localState == .failed {
                    Button {
                        Task { await store.retry(message) }
                    } label: {
                        Label("Nicht gesendet – nochmal", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct BotBubble: View {
    var message: Message
    var author: Bot?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let author {
                HStack(spacing: 4) {
                    MascotView(mascot: author.mascot, size: 16, seed: author.id, animated: false)
                    Text(author.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(hex: author.mascot.color))
                }
            }
            HStack {
                ExpandableText(text: WatchText.simplified(message.text), foreground: .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 12)
            }
        }
    }
}

/// Text mit Inline-Markdown; lange Texte gekürzt, „mehr“ klappt auf
struct ExpandableText: View {
    var text: String
    var foreground: Color
    var limit = WatchText.defaultLimit
    @State private var expanded = false

    var body: some View {
        let cut = WatchText.truncated(text, limit: limit)
        VStack(alignment: .leading, spacing: 3) {
            Text(WatchText.attributed(expanded ? text : cut.text))
                .font(.body)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
            if cut.isTruncated {
                Button(expanded ? "weniger" : "mehr") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(foreground == .white ? .white.opacity(0.85) : Color.accentColor)
            }
        }
    }
}

struct EventLine: View {
    var message: Message

    var body: some View {
        Label {
            Text(message.text)
        } icon: {
            Image(systemName: message.meta.icon ?? "info.circle")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

struct StatusLine: View {
    var message: Message
    var name: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .frame(width: 16, height: 16)
                .scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(name) arbeitet …")
                    .font(.caption.weight(.semibold))
                if let line = message.meta.lines?.last {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}
