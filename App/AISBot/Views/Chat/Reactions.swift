import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Reaktionen (v1.9): Schnellauswahl, Kapsel unter der Blase, Emoji-Feld.
enum Reactions {
    static let quick = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    /// Platzhalter-Tag in der Palette für „…“ (weitere Emojis)
    static let moreTag = "__more__"

    /// Gruppiert nach Emoji, Reihenfolge: zuerst Armans, dann nach Häufigkeit.
    static func groups(_ reactions: [String: String]) -> [(emoji: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in reactions.values { counts[e, default: 0] += 1 }
        let mine = reactions["user"]
        return counts.map { ($0.key, $0.value) }
            .sorted { a, b in
                if a.0 == mine { return true }
                if b.0 == mine { return false }
                return a.1 != b.1 ? a.1 > b.1 : a.0 < b.0
            }
    }
}

/// Kapsel mit den Reaktionen unten an der Blase (wie WhatsApp). Tippen entfernt die eigene Reaktion.
struct ReactionCapsule: View {
    let message: Message
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var reactions: [String: String] { message.meta.reactions ?? [:] }

    var body: some View {
        let groups = Reactions.groups(reactions)
        let mine = reactions["user"]
        Button {
            if mine != nil { store.react(message, emoji: nil) }
        } label: {
            HStack(spacing: 2) {
                ForEach(groups.prefix(4), id: \.emoji) { g in
                    Text(g.emoji).appFont(14)
                }
                if reactions.count > 1 {
                    Text("\(reactions.count)")
                        .appFont(12, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(mine != nil ? theme.accent.opacity(theme.kind == .nacht ? 0.28 : 0.14) : theme.surfaceRaised,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(theme.background, lineWidth: 2))
            .shadow(color: .black.opacity(theme.kind == .nacht ? 0.35 : 0.12), radius: 2.5, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mine != nil ? "Deine Reaktion entfernen" : "")
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(mine != nil ? "Entfernt deine Reaktion" : "")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private var accessibilityText: String {
        let parts = reactions.sorted { $0.key < $1.key }.map { actor, emoji in
            let name = store.reactionActorName(actor, chatID: message.chatId)
            return String(localized: "\(emoji) von \(name)", comment: "Reaktion für VoiceOver: Emoji und wer (Dativ: „von dir“)")
        }
        let list = parts.joined(separator: ", ")
        return String(localized: "Reaktionen: \(list)")
    }
}

/// Reaktionen an einer Blase: Kapsel unten, Doppeltipp = ❤️ (iOS), „+“/„…“ öffnet das Emoji-Feld.
/// iOS/iPadOS: Langes Drücken hebt die Blase hervor und zeigt darüber eine große Emoji-Leiste aus Glas,
/// darunter die Aktionen (`ReactionOverlay`). Das System-Kontextmenü legt die Emoji-Größe fest und war zu klein.
/// Mac: Kontextmenü mit Emoji-Palette und Smiley-Knopf beim Überfahren.
struct ReactionsModifier<Preview: View>: ViewModifier {
    let message: Message
    /// Kapsel und Smiley-Knopf an der rechten (eigene Nachricht) bzw. linken Seite
    let trailing: Bool
    let copyText: String
    /// Die Blase noch einmal, für die hervorgehobene Kopie im Overlay. `content` des Modifiers bleibt in
    /// einer Präsentation leer, deshalb wird die Ansicht selbst mitgegeben (siehe `messageReactions`).
    let preview: Preview
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showsPicker = false
    @State private var hovering = false
    @State private var showsHoverBar = false
    #if os(iOS)
    @State private var showsOverlay = false
    /// Blase verstecken, solange ihre Kopie im Overlay liegt (sonst doppelt sichtbar)
    @State private var hidesOriginal = false
    /// „+“ im Overlay: Emoji-Feld erst öffnen, wenn das Overlay weg ist
    @State private var opensPickerAfterOverlay = false
    /// „Antworten“ im Overlay: Antwort erst setzen, wenn das Overlay weg ist (sonst greift der Fokus nicht)
    @State private var repliesAfterOverlay = false
    /// „Bearbeiten“ bzw. „Erneut senden …“ im Overlay: ebenfalls erst danach
    @State private var editsAfterOverlay = false
    /// Lage der Blase im Fenster. Bewusst kein beobachteter Zustand: Beim Scrollen ändert sie sich ständig,
    /// gebraucht wird sie nur im Moment des langen Drückens.
    @State private var frameBox = FrameBox()
    #endif

    private var hasReactions: Bool { !(message.meta.reactions ?? [:]).isEmpty }

    func body(content: Content) -> some View {
        HStack(alignment: .center, spacing: 6) {
            #if os(macOS)
            if trailing { hoverButtons }
            #endif
            bubble(content)
                .overlay(alignment: trailing ? .bottomTrailing : .bottomLeading) {
                    if hasReactions {
                        ReactionCapsule(message: message)
                            .offset(x: trailing ? -10 : 10, y: 17)
                    }
                }
                .accessibilityAction(named: "Mit Herz reagieren") { store.react(message, emoji: "❤️") }
                .modifier(EditAccessibilityAction(message: message))
                #if os(iOS)
                .accessibilityAction(named: message.localState == nil ? "Reagieren" : "Aktionen") { openOverlay() }
                #endif
            #if os(macOS)
            if !trailing { hoverButtons }
            #endif
        }
        .padding(.bottom, hasReactions ? 18 : 0)
        .animation(.smooth(duration: 0.2), value: message.meta.reactions)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: showsOverlay) { _, new in new }
        .fullScreenCover(isPresented: $showsOverlay, onDismiss: {
            hidesOriginal = false
            if opensPickerAfterOverlay {
                opensPickerAfterOverlay = false
                showsPicker = true
            }
            if repliesAfterOverlay {
                repliesAfterOverlay = false
                store.startReply(to: message)
            }
            if editsAfterOverlay {
                editsAfterOverlay = false
                store.startEditing(message)
            }
        }) {
            ReactionOverlay(
                message: message,
                sourceFrame: frameBox.rect,
                trailing: trailing,
                onShown: { hidesOriginal = true },
                onReact: { emoji in
                    store.react(message, emoji: emoji == message.meta.reactions?["user"] ? nil : emoji)
                },
                onMore: { opensPickerAfterOverlay = true },
                onCopy: { Clipboard.copy(copyText) },
                onReply: store.canReply(to: message) ? { repliesAfterOverlay = true } : nil,
                edit: store.editAction(for: message).map { action in
                    (title: action.title, icon: action.icon, run: { editsAfterOverlay = true })
                },
                onFinish: {
                    hidesOriginal = false
                    withoutAnimation { showsOverlay = false }
                }
            ) {
                preview.allowsHitTesting(false)
            }
            .environment(store)
            .environment(\.theme, theme)
            .presentationBackground(.clear)
        }
        #endif
        .sheet(isPresented: $showsPicker) {
            EmojiPickerSheet { emoji in
                store.react(message, emoji: emoji)
            }
            .environment(\.theme, theme)
            .preferredColorScheme(theme.preferredScheme)
        }
    }

    /// Blase mit Eingabe: Mac Kontextmenü, iOS langes Drücken und Doppeltipp
    @ViewBuilder
    private func bubble(_ content: Content) -> some View {
        #if os(iOS)
        content
            .opacity(hidesOriginal ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameBox.rect = $0 }
            // Alles simultan: Scrollen, Links und Knöpfe in der Blase bleiben bedienbar
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard message.localState == nil else { return }
                store.react(message, emoji: "❤️")
            })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in openOverlay() })
        #else
        content
            .contextMenu {
                if message.localState == nil {
                    // Emoji-Leiste ganz oben im Menü
                    Picker("", selection: selection) {
                        ForEach(Reactions.quick, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.palette)
                    // Nach der Auswahl schließen (Palette bleibt sonst offen)
                    .menuActionDismissBehavior(.enabled)
                    .accessibilityLabel("Reagieren")
                    Button { showsPicker = true } label: { Label("Weitere Emojis …", systemImage: "face.smiling") }
                    Divider()
                }
                if store.canReply(to: message) {
                    Button { store.startReply(to: message) } label: {
                        Label("Antworten", systemImage: "arrowshape.turn.up.left")
                    }
                }
                // Eigene Nachricht: jüngste bearbeiten, ältere erneut senden (App 1.3)
                if let action = store.editAction(for: message) {
                    Button { store.startEditing(message) } label: { Label(action.title, systemImage: action.icon) }
                }
                Button { Clipboard.copy(copyText) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
            }
        #endif
    }

    #if os(iOS)
    private func openOverlay() {
        guard !showsOverlay, !showsPicker, frameBox.rect.width > 0 else { return }
        // Ohne Einschub-Animation: Das Overlay blendet sich selbst ein
        withoutAnimation { showsOverlay = true }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }
    #endif

    private var selection: Binding<String> {
        Binding(get: { message.meta.reactions?["user"] ?? "" }, set: { new in
            if new == Reactions.moreTag {
                showsPicker = true
            } else {
                // Gleiche Reaktion noch einmal gewählt → entfernen
                store.react(message, emoji: new == message.meta.reactions?["user"] ? nil : new)
            }
        })
    }

    #if os(macOS)
    /// Beim Überfahren: Antworten und Reagieren (Antworten außen, damit der Smiley an der Blase bleibt)
    private var hoverButtons: some View {
        HStack(spacing: 4) {
            if trailing { replyButton }
            hoverButton
            if !trailing { replyButton }
        }
    }

    @ViewBuilder
    private var replyButton: some View {
        if store.canReply(to: message) {
            Button { store.startReply(to: message) } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .appFont(12.5, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .scaledFrame(26)
                    .background(theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Antworten")
            .accessibilityLabel("Antworten")
            .opacity(hovering ? 1 : 0)
        }
    }

    private var hoverButton: some View {
        Button { showsHoverBar = true } label: {
            Image(systemName: "face.smiling")
                .appFont(14)
                .foregroundStyle(theme.textTertiary)
                .scaledFrame(26)
                .background(theme.surfaceRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Reagieren")
        .opacity(hovering || showsHoverBar ? 1 : 0)
        .disabled(message.localState != nil)
        .popover(isPresented: $showsHoverBar, arrowEdge: .top) {
            HStack(spacing: 4) {
                ForEach(Reactions.quick, id: \.self) { e in
                    Button {
                        showsHoverBar = false
                        store.react(message, emoji: e == message.meta.reactions?["user"] ? nil : e)
                    } label: {
                        Text(e).appFont(28)
                            .frame(width: 40, height: 40)
                            .background(e == message.meta.reactions?["user"] ? theme.accent.opacity(0.2) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(e)
                    .accessibilityAddTraits(e == message.meta.reactions?["user"] ? .isSelected : [])
                }
                Button {
                    showsHoverBar = false
                    showsPicker = true
                } label: {
                    Image(systemName: "ellipsis")
                        .appFont(16, weight: .semibold)
                        .scaledFrame(40)
                        .background(theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Weitere Emojis")
                .accessibilityLabel("Weitere Emojis")
            }
            .padding(8)
        }
    }
    #endif
}

#if os(iOS)
/// Lage der Blase, ohne dass jede Änderung die Ansicht neu zeichnet.
private final class FrameBox {
    var rect: CGRect = .zero
}

/// Langes Drücken auf eine Blase (wie WhatsApp/iMessage): Hintergrund abgedunkelt und unscharf, die Blase
/// hervorgehoben an ihrer Stelle, darüber eine Glas-Kapsel mit großen Emojis, darunter die Aktionen.
/// Passt die Blase nicht dazwischen, rückt sie ins Bild bzw. wird auf den sichtbaren Ausschnitt begrenzt.
private struct ReactionOverlay<Bubble: View>: View {
    let message: Message
    /// Blase im globalen Koordinatenraum (Fenster)
    let sourceFrame: CGRect
    let trailing: Bool
    var onShown: () -> Void
    var onReact: (String) -> Void
    var onMore: () -> Void
    var onCopy: () -> Void
    /// „Antworten“ (nil = nicht möglich, z. B. ohne Schreibrecht)
    var onReply: (() -> Void)?
    /// „Bearbeiten“ bzw. „Erneut senden …“ an eigenen Nachrichten (nil = nicht möglich)
    var edit: (title: String, icon: String, run: () -> Void)?
    /// Nach der Ausblend-Animation: Overlay entfernen
    var onFinish: () -> Void
    @ViewBuilder var bubble: Bubble

    @Environment(\.theme) private var theme
    @State private var appeared = false
    @State private var picked: String?

    private var allowsReactions: Bool { message.localState == nil }
    private var mine: String? { message.meta.reactions?["user"] }

    // Maße
    private let margin: CGFloat = 12
    private let gap: CGFloat = 10
    private let barPadding: CGFloat = 6
    private let cellSpacing: CGFloat = 2
    private let menuRowHeight: CGFloat = 48
    private let menuWidth: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            let layout = Layout(
                source: sourceFrame.offsetBy(dx: -window.minX, dy: -window.minY),
                size: window.size,
                safeTop: insets.top, safeBottom: window.height - insets.bottom,
                bar: allowsReactions ? barSize(width: window.width) : .zero,
                menuHeight: menuHeight, gap: gap, margin: margin
            )
            ZStack(alignment: .topLeading) {
                backdrop
                bubbleCopy(layout)
                if allowsReactions { bar(layout) }
                menu(layout)
            }
            .frame(width: window.width, height: window.height, alignment: .topLeading)
            // VoiceOver bleibt im Overlay, der Verlauf dahinter ist bis zum Schließen stumm
            .accessibilityAddTraits(.isModal)
        }
        .ignoresSafeArea()
        .onAppear {
            onShown()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { appeared = true }
        }
        .accessibilityAction(.escape) { close() }
        .sensoryFeedback(.selection, trigger: picked)
    }

    // MARK: Teile

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(theme.kind == .nacht ? 0.35 : 0.14))
            .opacity(appeared ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityElement()
            .accessibilityLabel("Schließen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { close() }
    }

    @ViewBuilder
    private func bubbleCopy(_ l: Layout) -> some View {
        let s = l.source
        let dy = appeared ? l.bubbleShift : 0
        bubble
            .frame(width: s.width, height: s.height)
            .scaleEffect(appeared && !l.clipsBubble ? 1.03 : 1, anchor: trailing ? .trailing : .leading)
            .shadow(color: .black.opacity(appeared ? 0.18 : 0), radius: 14, y: 6)
            .offset(x: s.minX, y: s.minY + dy)
            .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
            // Sehr lange Blasen nur im freien Bereich zwischen Leiste und Menü zeigen
            .mask(alignment: .topLeading) {
                if l.clipsBubble {
                    Rectangle()
                        .frame(width: l.size.width, height: l.visibleBottom - l.visibleTop)
                        .offset(y: l.visibleTop)
                } else {
                    Rectangle()
                }
            }
            .accessibilityHidden(true)
    }

    private func bar(_ l: Layout) -> some View {
        let cell = l.bar.height - 2 * barPadding
        let emojiSize = min(34, (cell * 0.7).rounded())
        return HStack(spacing: cellSpacing) {
            ForEach(Reactions.quick, id: \.self) { e in
                let selected = e == mine
                Button {
                    picked = e
                    onReact(e)
                    close()
                } label: {
                    Text(e)
                        .font(.fixed(emojiSize))
                        .frame(width: cell, height: cell)
                        .background(selected ? theme.accent.opacity(theme.kind == .nacht ? 0.38 : 0.22) : .clear, in: Circle())
                        .scaleEffect(picked == e ? 1.25 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(e)
                .accessibilityHint(selected ? "Entfernt deine Reaktion" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button {
                onMore()
                close()
            } label: {
                Image(systemName: "plus")
                    .font(.fixed((cell * 0.42).rounded(), weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: cell, height: cell)
                    .background(theme.textPrimary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Weitere Emojis")
        }
        .padding(barPadding)
        .glassEffect(.regular.interactive(), in: .capsule)
        .scaleEffect(appeared ? 1 : 0.5, anchor: trailing ? .bottomTrailing : .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .offset(x: l.barX(trailing: trailing), y: l.barY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reagieren")
        .accessibilitySortPriority(2)
    }

    private var menuHeight: CGFloat { menuRowHeight * CGFloat(1 + (onReply == nil ? 0 : 1) + (edit == nil ? 0 : 1)) + 8 }

    private func menu(_ l: Layout) -> some View {
        let width = min(menuWidth, l.size.width - 2 * margin)
        return VStack(spacing: 0) {
            if let onReply {
                menuRow(Text("Antworten"), icon: "arrowshape.turn.up.left") { onReply() }
                Divider().padding(.leading, 16)
            }
            if let edit {
                menuRow(Text(edit.title), icon: edit.icon) { edit.run() }
                Divider().padding(.leading, 16)
            }
            menuRow(Text("Kopieren"), icon: "doc.on.doc") { onCopy() }
        }
        .padding(.vertical, 4)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .scaleEffect(appeared ? 1 : 0.5, anchor: trailing ? .topTrailing : .topLeading)
        .opacity(appeared ? 1 : 0)
        .offset(x: l.menuX(trailing: trailing, width: width), y: l.menuY)
        .accessibilitySortPriority(1)
    }

    private func menuRow(_ title: Text, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            close()
        } label: {
            HStack {
                title
                Spacer()
                Image(systemName: icon)
            }
            .appFont(16)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Ablauf

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { appeared = false } completion: { onFinish() }
    }

    /// Größe der Emoji-Leiste: 6 Emojis + „+“, Felder 44–52 pt je nach Breite (schmales iPhone bis iPad).
    private func barSize(width: CGFloat) -> CGSize {
        let count = CGFloat(Reactions.quick.count + 1)
        let available = min(width - 2 * margin, 420)
        let cell = min(52, max(40, ((available - 2 * barPadding - (count - 1) * cellSpacing) / count).rounded(.down)))
        return CGSize(width: count * cell + (count - 1) * cellSpacing + 2 * barPadding, height: cell + 2 * barPadding)
    }

    /// Anordnung von Leiste, Blase und Menü im Fenster (lokale Koordinaten).
    struct Layout {
        let source: CGRect
        let size: CGSize
        let bar: CGSize
        let menuHeight: CGFloat
        let margin: CGFloat
        /// Verschiebung der Blase, damit Leiste und Menü Platz haben
        let bubbleShift: CGFloat
        /// Sichtbarer Bereich der Blase (nach Verschiebung)
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        let clipsBubble: Bool
        let gap: CGFloat

        init(source: CGRect, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat,
             bar: CGSize, menuHeight: CGFloat, gap: CGFloat, margin: CGFloat) {
            self.source = source
            self.size = size
            self.bar = bar
            self.menuHeight = menuHeight
            self.margin = margin
            self.gap = gap
            // Freier Bereich für die Blase zwischen Leiste (oben) und Menü (unten)
            let windowTop = safeTop + 8 + (bar.height > 0 ? bar.height + gap : 0)
            let windowBottom = max(windowTop + 60, safeBottom - 8 - menuHeight - gap)
            let h = source.height
            let newTop: CGFloat
            if h <= windowBottom - windowTop {
                newTop = min(max(source.minY, windowTop), windowBottom - h)
            } else if source.minY > windowTop {
                newTop = windowTop                 // Anfang der Blase zeigen
            } else if source.maxY < windowBottom {
                newTop = windowBottom - h          // Ende der Blase zeigen
            } else {
                newTop = source.minY               // gerade sichtbaren Teil behalten
            }
            bubbleShift = newTop - source.minY
            visibleTop = max(newTop, windowTop)
            visibleBottom = min(newTop + h, windowBottom)
            clipsBubble = h > windowBottom - windowTop
        }

        var barY: CGFloat { visibleTop - gap - bar.height }
        var menuY: CGFloat { visibleBottom + gap }

        func barX(trailing: Bool) -> CGFloat { x(for: bar.width, trailing: trailing) }
        func menuX(trailing: Bool, width: CGFloat) -> CGFloat { x(for: width, trailing: trailing) }

        /// An der Blasenseite ausrichten, aber nie über den Rand hinaus
        private func x(for width: CGFloat, trailing: Bool) -> CGFloat {
            let desired = trailing ? source.maxX - width : source.minX
            return min(max(desired, margin), max(margin, size.width - margin - width))
        }
    }
}
#endif

extension View {
    func messageReactions(_ message: Message, trailing: Bool, copyText: String) -> some View {
        modifier(ReactionsModifier(message: message, trailing: trailing, copyText: copyText, preview: self))
    }
}

/// Emoji-Feld: beliebiges Emoji eintippen (Systemtastatur bzw. „Emoji & Symbole“ auf dem Mac) oder aus der Auswahl tippen.
struct EmojiPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var typed = ""
    @FocusState private var focused: Bool

    private static let emojis: [String] = Array(
        "😀😃😄😁😆🥹😅🤣😊😇🙂😉😍🥰😘😋😛😜🤪🤓😎🥳🤩😏😌😴🤔🫡🤗🤭🫢😶🙄😬😮‍💨😳🥺😢😭😤😡🤯😱😨🤝👏🙌👐🤲🙏✌️🤞🫶👌🤌👈👉👆👇☝️💪👀🧠❤️🧡💛💚💙💜🤍🖤💔❤️‍🔥💯✨🔥⭐️🌟⚡️🎉🎊🎁🏆✅❌⚠️❓❗️💡📌📎📅⏰🚀🛠️💰📈📉☕️🍕🍻🌈☀️🌙"
    ).map(String.init)

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Reagieren", icon: "face.smiling") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        TextField("Emoji eingeben", text: $typed)
                            .focused($focused)
                            .modifier(FieldStyle(alignment: .leading))
                            .onChange(of: typed) { _, new in
                                if let e = new.last(where: { $0.isEmojiLike }) { pick(String(e)) }
                            }
                        #if os(macOS)
                        Button("Emoji & Symbole") {
                            focused = true
                            NSApp.orderFrontCharacterPalette(nil)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        #endif
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                        ForEach(Self.emojis, id: \.self) { e in
                            Button { pick(e) } label: {
                                Text(e).appFont(32).frame(width: 48, height: 48)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(e)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 420, height: 460)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func pick(_ e: String) {
        onPick(e)
        dismiss()
    }
}

private extension Character {
    /// Emoji (auch zusammengesetzte) statt Buchstaben/Ziffern
    var isEmojiLike: Bool {
        unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}

/// VoiceOver: „Bearbeiten“ bzw. „Erneut senden …“ als Aktion an eigenen Nachrichten (App 1.3).
private struct EditAccessibilityAction: ViewModifier {
    let message: Message
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        if let action = store.editAction(for: message) {
            content.accessibilityAction(named: Text(action.title)) { store.startEditing(message) }
        } else {
            content
        }
    }
}
