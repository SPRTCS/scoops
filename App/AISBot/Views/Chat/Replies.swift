import SwiftUI
#if os(iOS)
import UIKit
#endif

// Antworten auf eine bestimmte Nachricht (API v1.15, wie bei Telegram):
// Blase nach links wischen (iOS) bzw. „Antworten“ im Kontextmenü / Knopf beim Überfahren (Mac) → Leiste über dem
// Eingabefeld. Gesendet wird `reply_to`, der Server legt `meta.reply_to` mit Auszug an. In der Blase steht oben
// ein kompaktes Zitat; Antippen springt zur Originalnachricht und hebt sie kurz hervor.

extension AppStore {
    /// Auf diese Nachricht kann geantwortet werden: Nutzer- und Scoop-Nachrichten, schon gesendet, Schreibrecht.
    func canReply(to m: Message) -> Bool {
        (m.role == .user || m.role == .bot) && m.localState == nil && !m.id.hasPrefix("local-") && canWrite(m.chatId)
    }

    /// Bezug für die Antwort-Leiste und die optimistische Blase (der Server legt seinen eigenen an).
    func replyRef(for m: Message) -> ReplyRef {
        var text = MarkdownText.plain(m.text)
        if text.count > 200 { text = String(text.prefix(199)).trimmingCharacters(in: .whitespaces) + "…" }
        if text.isEmpty, m.meta.fileIds?.isEmpty == false { text = "Anhang" }
        if m.role == .user {
            let name = isOwnMessage(m) ? (m.meta.authorName ?? userName) : authorName(of: m)
            return ReplyRef(id: m.id, role: "user", authorId: m.meta.authorUserId, authorName: name, text: text)
        }
        let author = m.meta.authorId ?? m.chatId
        return ReplyRef(id: m.id, role: "bot", authorId: author, authorName: bot(author)?.name ?? "Scoop", text: text)
    }

    /// Antwort beginnen: Leiste im Entwurf des Chats setzen und das Eingabefeld fokussieren.
    func startReply(to m: Message) {
        guard canReply(to: m) else { return }
        composerDraft(m.chatId).replyTo = replyRef(for: m)
        composerFocusRequest += 1
    }

    /// Zur zitierten Nachricht springen: ältere Seiten nachladen, bis sie da ist (höchstens 10 Seiten), dann
    /// scrollt der Chat dorthin und hebt sie kurz hervor (`pendingScrollMessageID`).
    func jumpToMessage(_ id: String, chatID: String) async {
        var pages = 0
        while messages[chatID]?.contains(where: { $0.id == id }) != true, hasMoreHistory[chatID] == true, pages < 10 {
            let before = messages[chatID]?.count ?? 0
            await loadOlderMessages(chatID: chatID)
            pages += 1
            if (messages[chatID]?.count ?? 0) == before { break }
        }
        guard messages[chatID]?.contains(where: { $0.id == id }) == true else {
            errorMessage = "Die Originalnachricht ist nicht mehr im Verlauf."
            return
        }
        pendingScrollMessageID = nil
        pendingScrollMessageID = id
    }

    /// Farbe des Zitat-Strichs: Maskottchenfarbe des Scoops, bei Personen die Akzentfarbe.
    func replyColor(_ ref: ReplyRef, theme: Theme) -> Color {
        if ref.role == "bot", let id = ref.authorId, let b = bot(id) { return Color(hex: b.mascot.color) }
        return theme.accent
    }

    /// Anzeigename im Zitat: eigene Nachrichten heißen „Du“.
    func replyName(_ ref: ReplyRef, chatID: String) -> String {
        if ref.role == "user", let m = messages[chatID]?.first(where: { $0.id == ref.id }), isOwnMessage(m) { return "Du" }
        return ref.authorName ?? (ref.role == "bot" ? "Scoop" : "Jemand")
    }
}

// MARK: - Zitat in der Blase

/// Kompaktes Zitat oben in einer Blase: farbiger Strich, Name, eine Zeile Auszug. Antippen springt zum Original.
struct ReplyQuote: View {
    let ref: ReplyRef
    let chatID: String

    /// Vorspann für VoiceOver-Beschriftungen von Blasen, die ihre Kinder zusammenfassen
    static func accessibilityPrefix(_ ref: ReplyRef?) -> String {
        guard let ref else { return "" }
        return "Antwort auf \(ref.authorName ?? "Nachricht"): \(ref.text ?? ""). "
    }
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let color = store.replyColor(ref, theme: theme)
        let name = store.replyName(ref, chatID: chatID)
        Button {
            Task { await store.jumpToMessage(ref.id, chatID: chatID) }
        } label: {
            HStack(spacing: 8) {
                Capsule().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(ref.text?.isEmpty == false ? ref.text! : "Nachricht")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
            }
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(theme.kind == .nacht ? 0.20 : 0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Zur Originalnachricht springen")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name == "Du" ? "Antwort auf deine Nachricht: \(ref.text ?? "")"
                                         : "Antwort auf \(name): \(ref.text ?? "")")
        .accessibilityHint("Springt zur Originalnachricht")
        .accessibilityAddTraits(.isButton)
    }
}

/// Blaseninhalt mit Zitat oben: Die Blase ist so breit wie der Text, mindestens aber wie das Zitat
/// (Zitat höchstens `quoteCap` breit). Das Zitat füllt dann die volle Blasenbreite.
struct ReplyBubbleLayout: Layout {
    var spacing: CGFloat = 6
    var quoteCap: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = contentWidth(proposal: proposal, subviews: subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for s in subviews {
            let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h + spacing
        }
    }

    /// Erstes Element = Zitat (Idealbreite, gedeckelt), die übrigen = Inhalt (bei der angebotenen Breite gemessen).
    private func contentWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let available = proposal.width ?? .infinity
        guard let quote = subviews.first else { return 0 }
        var width = min(quote.sizeThatFits(.unspecified).width, quoteCap, available)
        for s in subviews.dropFirst() {
            width = max(width, min(s.sizeThatFits(ProposedViewSize(width: available, height: nil)).width, available))
        }
        return width.isFinite ? width : 0
    }
}

extension View {
    /// Setzt das Zitat (falls vorhanden) über den Blaseninhalt.
    @ViewBuilder
    func withReplyQuote(_ ref: ReplyRef?, chatID: String) -> some View {
        if let ref {
            ReplyBubbleLayout {
                ReplyQuote(ref: ref, chatID: chatID)
                self
            }
        } else {
            self
        }
    }
}

// MARK: - Antwort-Leiste über dem Eingabefeld

struct ReplyComposerBar: View {
    let ref: ReplyRef
    let chatID: String
    var onCancel: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let color = store.replyColor(ref, theme: theme)
        let name = store.replyName(ref, chatID: chatID)
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            Capsule().fill(color).frame(width: 3, height: 32)
            Button {
                Task { await store.jumpToMessage(ref.id, chatID: chatID) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name == "Du" ? "Antwort auf deine Nachricht" : "Antwort an \(name)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(ref.text?.isEmpty == false ? ref.text! : "Nachricht")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zur Originalnachricht springen")
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(theme.hover, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Antwort abbrechen (Esc)")
            .accessibilityLabel("Antwort abbrechen")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.surfaceBorder))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name == "Du" ? "Antwort auf deine Nachricht" : "Antwort an \(name)")
    }
}

// MARK: - Wischen zum Antworten

/// Nachricht nach links wischen (iOS/iPadOS): Rechts erscheint ein Antwort-Pfeil, der ab `threshold` einrastet
/// (leichtes Haptik-Feedback). Loslassen federt zurück und setzt die Antwort. Nur nach links und klar waagerecht,
/// damit Scrollen, Zurück-Wischen und die Seitenleiste unberührt bleiben. Auf dem Mac ohne Geste
/// (Kontextmenü „Antworten“ und Knopf beim Überfahren).
struct ReplySwipeModifier: ViewModifier {
    let message: Message
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    #if os(iOS)
    @State private var offset: CGFloat = 0
    @State private var locked = false
    #endif

    static let threshold: CGFloat = 64
    static let maxPull: CGFloat = 96

    func body(content: Content) -> some View {
        if store.canReply(to: message) {
            #if os(iOS)
            content
                .offset(x: offset)
                // Pfeil nur während des Wischens (sonst nicht im Bedienungshilfen-Baum)
                .overlay(alignment: .trailing) { if offset < 0 { arrow } }
                .gesture(ReplyPanGesture(onChange: update, onEnd: finish))
                .sensoryFeedback(.impact(weight: .light), trigger: locked) { _, new in new }
                .accessibilityAction(named: "Antworten") { store.startReply(to: message) }
            #else
            content
                .accessibilityAction(named: "Antworten") { store.startReply(to: message) }
            #endif
        } else {
            content
        }
    }

    #if os(iOS)
    private var progress: CGFloat { min(1, -offset / Self.threshold) }

    private var arrow: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(locked ? theme.sendButtonIcon : theme.textSecondary)
            .frame(width: 32, height: 32)
            .background(locked ? theme.sendButton : theme.surfaceRaised, in: Circle())
            .overlay(Circle().strokeBorder(theme.surfaceBorder, lineWidth: locked ? 0 : 1))
            .scaleEffect(locked ? 1.12 : 0.55 + 0.45 * progress)
            .opacity(progress)
            .padding(.trailing, 4)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: locked)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func update(_ dx: CGFloat) {
        let pull = max(0, -dx)
        // Gummiband hinter dem Maximum
        let eased = pull <= Self.maxPull ? pull : Self.maxPull + (pull - Self.maxPull) * 0.2
        offset = -eased
        let nowLocked = pull >= Self.threshold
        if nowLocked != locked { locked = nowLocked }
    }

    private func finish(_ dx: CGFloat, _ cancelled: Bool) {
        let trigger = locked && !cancelled
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { offset = 0 }
        locked = false
        if trigger { store.startReply(to: message) }
    }
    #endif
}

#if os(iOS)
/// Waagerechte Wischgeste per UIKit: beginnt nur bei klar waagerechter Bewegung nach links. So bleibt das
/// senkrechte Scrollen des Verlaufs (und das Zurück-Wischen vom linken Rand nach rechts) unberührt –
/// ein SwiftUI-`DragGesture` im ScrollView würde das Scrollen blockieren.
struct ReplyPanGesture: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .began, .changed: onChange(dx)
        case .ended: onEnd(dx, false)
        case .cancelled, .failed: onEnd(dx, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            let t = pan.translation(in: pan.view)
            // Nur nach links und deutlich waagerecht (Geschwindigkeit bzw. bisheriger Weg)
            let horizontal = abs(v.x) > abs(v.y) * 1.8 || abs(t.x) > abs(t.y) * 2
            return horizontal && (v.x < 0 || t.x < 0)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Mit dem Scrollen des Verlaufs zusammen erlaubt (der bewegt sich bei waagerechtem Wischen kaum),
            // mit anderen Wischgesten (z. B. Zurück vom Rand) nicht.
            other.view is UIScrollView
        }
    }
}
#endif

extension View {
    func replySwipe(_ message: Message) -> some View { modifier(ReplySwipeModifier(message: message)) }
}
