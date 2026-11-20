import SwiftUI

/// Eingabe für einen Scoop: Diktat, Scribble oder Tastatur über die Systemeingabe der Uhr, dazu Schnellantworten.
struct ComposeView: View {
    var chatID: String
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Werden als eigene Nachricht gesendet (in der Sprache der App)
    static var quickReplies: [String] {
        [String(localized: "Ja, mach das"), String(localized: "Nein, lass es"),
         String(localized: "Später", comment: "Schnellantwort auf der Uhr"), String(localized: "Wie ist der Stand?"),
         String(localized: "Danke!")]
    }

    var body: some View {
        let chat = store.chat(chatID)
        let name = chat?.name ?? "Scoop"
        ScrollView {
            VStack(spacing: 8) {
                if let chat {
                    HStack(spacing: 6) {
                        WatchChatAvatar(chat: chat, size: 28, animated: false, showsWaiting: false)
                        Text("An \(name)")
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                TextFieldLink(prompt: Text(chat?.isGroup == true ? "Was soll die Gruppe tun?" : "Was soll \(name) tun?")) {
                    Label("Diktieren oder schreiben", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    send(text)
                }
                .buttonStyle(.glassProminent)

                Text("Schnellantworten")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                ForEach(Self.quickReplies, id: \.self) { reply in
                    Button {
                        send(reply)
                    } label: {
                        Text(reply).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Nachricht")
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await store.send(trimmed, to: chatID) }
        dismiss()
    }
}
