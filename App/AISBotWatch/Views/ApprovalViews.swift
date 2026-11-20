import SwiftUI

/// Freigabe-Karte mit Freigeben / Ablehnen (und „Immer erlauben“, wo der Server es anbietet)
struct ApprovalCard: View {
    var message: Message
    /// In der Übersicht: Kopfzeile mit Scoop
    var showsChat = false
    @Environment(WatchStore.self) private var store
    @State private var confirmAlways = false

    var body: some View {
        let p = ApprovalPresentation(message)
        let deciding = store.isDeciding(message)
        VStack(alignment: .leading, spacing: 6) {
            if showsChat, let chat = store.chat(message.chatId) {
                Button {
                    store.path.append(.chat(chat.id))
                } label: {
                    HStack(spacing: 5) {
                        WatchChatAvatar(chat: chat, size: 20, animated: false, showsWaiting: false)
                        Text(chat.name).font(.footnote.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Label(p.kindLabel, systemImage: p.icon)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(p.state == .pending ? .orange : .secondary)
            Text(p.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !p.summary.isEmpty {
                Text(Self.plainSummary(p.summary))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !p.availableDecisions.isEmpty {
                VStack(spacing: 5) {
                    Button {
                        decide(.approve)
                    } label: {
                        Label("Freigeben", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    Button(role: .destructive) {
                        decide(.decline)
                    } label: {
                        Label("Ablehnen", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    if p.canAlways {
                        Button {
                            confirmAlways = true
                        } label: {
                            Label("Immer erlauben", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .font(.footnote)
                    }
                }
                .disabled(deciding)
                .opacity(deciding ? 0.5 : 1)
                .overlay { if deciding { ProgressView() } }
                .padding(.top, 2)
            } else if p.state == .pending && p.needsPhone {
                Label("Am iPhone erledigen", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label(message.meta.always == true ? String(localized: "Immer erlaubt") : p.stateLabel,
                      systemImage: p.state == .declined ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(p.state == .declined ? Color.secondary : Color.green)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(p.state == .pending ? .orange.opacity(0.18) : .clear),
                     in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .confirmationDialog("Immer erlauben?", isPresented: $confirmAlways, titleVisibility: .visible) {
            Button("Immer erlauben") { decide(.always) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(message.meta.alwaysLabel ?? String(localized: "Künftig fragt der Scoop hierfür nicht mehr."))
        }
    }

    /// Zusammenfassung ohne anklickbare Links (Adressen sollen nicht blau und tippbar sein)
    static func plainSummary(_ s: String) -> AttributedString {
        var a = WatchText.attributed(s)
        a.link = nil
        return a
    }

    private func decide(_ decision: ApprovalDecision) {
        Task { await store.decide(message, decision) }
    }
}

/// „Offene Freigaben“ über alle Scoops
struct ApprovalsView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        Group {
            if store.approvals.isEmpty {
                ContentUnavailableView {
                    Label("Alles erledigt", systemImage: "checkmark.seal")
                } description: {
                    Text("Keine offenen Freigaben.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.approvals) { message in
                            ApprovalCard(message: message, showsChat: true)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .navigationTitle("Freigaben")
        .task { await store.refresh() }
    }
}
