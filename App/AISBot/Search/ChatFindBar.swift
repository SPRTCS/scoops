import SwiftUI
import Observation

// Chat-Komfort im Verlauf (App 1.3): Suche nur in diesem Chat (Leiste unter dem Chat-Kopf, am Mac ⌘F), der runde
// Zum-Ende-Knopf über dem Eingabefeld und die Zeile „Neuere Nachrichten laden“ in einem Ausschnitt.

/// Zustand der Suche im Chat: Eingabe, Treffer (neueste zuerst) und der gerade gezeigte Treffer.
@Observable
final class ChatFindState {
    var active = false
    var text = ""
    /// Position in `model.hits` (0 = jüngster Treffer)
    var index = 0
    let model = MessageSearchModel()

    /// Höchstens so viele Treffer lädt die Suche im Chat (darüber zeigt die Leiste „200+“)
    static let limit = 200

    var current: SearchHit? { model.hits.indices.contains(index) ? model.hits[index] : nil }

    func close() {
        active = false
        text = ""
        index = 0
        model.reset()
    }
}

/// Suchleiste im Chat: Feld, Trefferzahl („3 von 12“), älterer/neuerer Treffer, schließen.
/// Tastatur: Return = älterer Treffer, ⇧Return = neuerer, Esc = schließen (am Mac auch ⌘G / ⇧⌘G).
struct ChatFindBar: View {
    let chatID: String
    @Bindable var find: ChatFindState
    /// Zum Treffer springen (lädt ihn bei Bedarf nach) und ihn hervorheben
    var onShow: (SearchHit) -> Void
    var onClose: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var hits: [SearchHit] { find.model.hits }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .appFont(14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            TextField("In \(store.chatName(chatID)) suchen", text: $find.text)
                .textFieldStyle(.plain)
                .appFont(15)
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onSubmit { step(1) }
                .onKeyPress(.return, phases: .down) { press in
                    step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in onClose(); return .handled }
                .accessibilityLabel("Im Chat suchen")
                .accessibilitySortPriority(4)
            status.accessibilitySortPriority(3)
            Rectangle().fill(theme.surfaceBorder).frame(width: 1, height: 20)
            stepButton("chevron.up", label: "Älterer Treffer", delta: 1)
                #if os(macOS)
                .keyboardShortcut("g", modifiers: .command)
                #endif
            stepButton("chevron.down", label: "Neuerer Treffer", delta: -1)
                #if os(macOS)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                #endif
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(28)
                    .background(theme.hover, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Suche schließen (Esc)")
            .accessibilityLabel("Suche schließen")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        // Deckende Fläche statt Glas: Der Verlauf läuft darunter durch, Feld und Trefferzahl müssen lesbar bleiben
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.surfaceBorder))
        .shadow(color: .black.opacity(theme.kind == .nacht ? 0.45 : 0.14), radius: 14, y: 5)
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suche im Chat")
        .task {
            // Fokus erst nach dem Einblenden setzen (auf dem Mac sonst gelegentlich verschluckt)
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        #if os(iOS)
        .onChange(of: focused) { _, isFocused in store.keyboardVisible = isFocused }
        #endif
        .onChange(of: find.text) { _, text in
            find.model.update(text, chatID: chatID, limit: ChatFindState.limit, store: store)
        }
        .onChange(of: hits.map(\.id)) { _, ids in
            // Neue Trefferliste: beim jüngsten Treffer beginnen
            find.index = 0
            if let first = hits.first, !ids.isEmpty { onShow(first) }
        }
    }

    /// Rechts vom Feld: Ladeanzeige, „Keine Treffer“ oder „3 von 12“
    @ViewBuilder
    private var status: some View {
        if find.model.phase == .loading {
            ProgressView().controlSize(.small).accessibilityLabel("Suche läuft")
        } else if find.model.phase == .done {
            let more = find.model.total > hits.count
            Text(hits.isEmpty ? "Keine Treffer" : "\(find.index + 1) von \(hits.count)\(more ? "+" : "")")
                .appFont(13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(hits.isEmpty ? theme.textTertiary : theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(hits.isEmpty ? "Keine Treffer" : "Treffer \(find.index + 1) von \(hits.count)")
        }
    }

    private func stepButton(_ symbol: String, label: LocalizedStringKey, delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .appFont(13, weight: .semibold)
                .foregroundStyle(hits.count > 1 ? theme.textPrimary : theme.textTertiary)
                .scaledFrame(30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hits.count < 2)
        .help(label)
        .accessibilityLabel(label)
    }

    /// `delta` 1 = älterer Treffer, −1 = neuerer; läuft am Ende um.
    private func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        find.index = ((find.index + delta) % hits.count + hits.count) % hits.count
        if let hit = find.current { onShow(hit) }
    }
}

/// Runder Knopf unten rechts im Verlauf: springt ans Ende. Erscheint, wenn man hochgescrollt hat; kommen
/// währenddessen neue Nachrichten, zeigt er deren Anzahl.
struct ScrollToEndButton: View {
    var unseen: Int
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .appFont(15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .scaledFrame(40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.chatHeader(theme), in: .circle)
        .overlay(alignment: .top) {
            if unseen > 0 {
                Text(unseen > 99 ? "99+" : "\(unseen)")
                    .appFont(11.5, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(theme.textOnAccent)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(theme.accent, in: Capsule())
                    .offset(y: -9)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .help(unseen > 0 ? "Zu den neuen Nachrichten" : "Zum Ende springen")
        .accessibilityLabel(unseen == 0 ? String(localized: "Zum Ende springen")
                            : String(localized: "Zum Ende springen, \(unseen) neue Nachrichten"))
        .animation(.snappy(duration: 0.2), value: unseen)
    }
}

/// Zeile am Ende eines Ausschnitts (Sprung zu einer älteren Fundstelle): lädt die nächsten neueren Nachrichten.
/// Das Laden macht der Chat (`onLoad`), damit er dabei die Leseposition hält.
struct NewerMessagesRow: View {
    var onLoad: () async -> Void
    @Environment(\.theme) private var theme
    @State private var loading = false

    var body: some View {
        Button {
            guard !loading else { return }
            loading = true
            Task {
                await onLoad()
                loading = false
            }
        } label: {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle").appFont(13, weight: .medium)
                }
                Text("Neuere Nachrichten laden").appFont(13, weight: .medium)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(theme.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.surfaceBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityHint("Du siehst einen älteren Ausschnitt dieses Chats")
    }
}
