import SwiftUI
import Observation

/// Zustand einer Nachrichtensuche (Befehlspalette, Seitenleiste, Suche im Chat): entprellt die Eingabe, verwirft
/// Antworten auf überholte Eingaben und kennt Laden, Treffer, leer und Fehler.
@Observable
final class MessageSearchModel {
    enum Phase: Equatable {
        /// Eingabe zu kurz (unter zwei Zeichen): keine Suche
        case idle
        case loading
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var hits: [SearchHit] = []
    private(set) var total = 0
    /// Nur geladene Nachrichten durchsucht (älterer Server oder offline)
    private(set) var local = false
    private(set) var error: String?
    /// Eingabe, zu der `hits` gehören
    private(set) var query = ""

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Neue Eingabe: nach kurzer Pause suchen. Ältere, noch laufende Suchen zählen nicht mehr.
    func update(_ text: String, chatID: String? = nil, limit: Int = 30, store: AppStore, delay: Duration = .milliseconds(260)) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let mine = generation
        task?.cancel()
        guard q.count >= 2 else {
            phase = .idle; hits = []; total = 0; error = nil; query = q
            return
        }
        if q == query, error == nil {
            // Treffer zu dieser Eingabe liegen schon vor (z. B. zurück zur vorigen Eingabe)
            phase = .done
            return
        }
        phase = .loading
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await store.searchMessages(q, chatID: chatID, limit: limit)
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.hits = result.hits
            self.total = result.total
            self.local = result.local
            self.error = result.error
            self.query = q
            self.phase = .done
        }
    }

    func reset() {
        generation += 1
        task?.cancel()
        phase = .idle; hits = []; total = 0; error = nil; query = ""
    }
}

// MARK: - Treffer in der Seitenleiste

/// Abschnitt „Nachrichten“ unter den gefilterten Chats der Seitenleiste: Treffer aus allen Chats, Ladezustand, leer.
struct SidebarMessageHits: View {
    /// Große Zeilen (iPhone, Seitenleiste allein auf dem Bildschirm)
    var large = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var search = MessageSearchModel()

    var body: some View {
        let typed = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 0) {
            if typed.count >= 2 {
                HStack(spacing: 6) {
                    Text(search.local && search.phase == .done ? "Nachrichten in geladenen Chats" : "Nachrichten")
                        .appFont(12.5, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityAddTraits(.isHeader)
                    if search.phase == .loading {
                        ProgressView().controlSize(.mini).accessibilityLabel("Suche läuft")
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
                if search.phase == .done, search.hits.isEmpty {
                    Text(search.error ?? String(localized: "Nichts mit „\(typed)“ gefunden."))
                        .appFont(large ? 15 : 13)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                // Treffer eines inzwischen gelöschten Chats (Scoop gelöscht, Freigabe entzogen) nicht mehr zeigen
                ForEach(search.hits.filter { store.chatExists($0.chatId) }) { hit in SearchHitRow(hit: hit, large: large) }
                if search.phase == .done, search.total > search.hits.count {
                    Text("\(search.total - search.hits.count) weitere Treffer. Gib mehr ein, um einzugrenzen.")
                        .appFont(large ? 13.5 : 12)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 16).padding(.top, 6)
                }
            }
        }
        .onChange(of: store.searchText, initial: true) { _, text in search.update(text, store: store) }
    }
}

/// Eine Fundstelle: Bild des Chats, Ausschnitt mit markiertem Treffer, darunter Absender, Chat und Zeit.
struct SearchHitRow: View {
    let hit: SearchHit
    var large = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let source = store.searchHitSource(hit)
        Button {
            Task { await store.openSearchHit(hit) }
        } label: {
            HStack(alignment: .top, spacing: large ? 12 : 10) {
                ChatAvatar(chatID: hit.chatId, size: large ? 40 : 30, animateWhenBusy: false)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.attributedSnippet(theme: theme))
                        .appFont(large ? 15.5 : 13.5)
                        .adaptiveLineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(source) · \(Formatting.dayTime(hit.createdAt))")
                        .appFont(large ? 13 : 11.5)
                        .foregroundStyle(theme.textTertiary)
                        .adaptiveLineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, large ? 9 : 7)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(radius: 12))
        .accessibilityLabel("\(hit.snippet), \(source), \(Formatting.dayTime(hit.createdAt))")
        .accessibilityHint("Öffnet den Chat an dieser Nachricht")
        .padding(.horizontal, 8)
    }
}
