import SwiftUI

/// Blatt „An Scoop senden“ im Teilen-Menü: Inhalt, Scoop-Auswahl, optionale Notiz, Senden mit Rückmeldung.
struct ShareView: View {
    @Bindable var model: ShareModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var noteFocused: Bool

    private var theme: Theme {
        var t: Theme = colorScheme == .dark ? .nacht : .hell
        t.followsSystem = true
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.surfaceBorder)
            ZStack {
                switch model.phase {
                case .loading:
                    status(symbol: nil, title: String(localized: "Inhalte werden vorbereitet …"), text: nil)
                case .unavailable(let text):
                    status(symbol: "exclamationmark.bubble", title: String(localized: "Hier geht gerade nichts"), text: text, tint: theme.textSecondary) {
                        actionButton("Schließen", primary: true) { model.cancel() }
                    }
                case .ready:
                    form
                case .sending:
                    sending
                case .sent(let text):
                    status(symbol: "checkmark.circle.fill", title: text, text: nil, tint: theme.success)
                case .queued(let text):
                    status(symbol: "tray.and.arrow.down.fill", title: String(localized: "Abgelegt, nichts geht verloren"), text: text, tint: theme.warning) {
                        actionButton("Fertig", primary: true) { model.done() }
                    }
                case .failed(let text):
                    status(symbol: "xmark.octagon.fill", title: String(localized: "Nicht gesendet"), text: text, tint: theme.danger) {
                        actionButton("Zurück", primary: true) { model.backToEditing() }
                        actionButton("Verwerfen", primary: false) { model.cancel() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        .environment(\.theme, theme)
        .tint(theme.accent)
        .animation(.snappy(duration: 0.22), value: model.phase)
        .task { await model.load() }
    }

    // MARK: Kopf

    private var header: some View {
        ZStack {
            Text("An Scoop senden")
                .appFont(16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            HStack {
                if showsCancel {
                    Button("Abbrechen") { model.cancel() }
                        .appFont(16)
                        .foregroundStyle(theme.textPrimary)
                        .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        // Titel in der Mitte, „Abbrechen“ links: nur bis zwei Stufen über Standard, sonst überlappen sie
        .dynamicTypeSize(...AppFont.compactCap)
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var showsCancel: Bool {
        switch model.phase {
        case .loading, .ready: true
        default: false
        }
    }

    // MARK: Auswahl

    private var form: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ShareContentCard(content: model.content, thumbnails: model.thumbnails)
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Senden an")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 8)], spacing: 10) {
                            ForEach(model.targets) { chat in
                                ShareTargetTile(chat: chat, selected: chat.id == model.selectedID) {
                                    model.selectedID = chat.id
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Notiz")
                        TextField("Was soll der Scoop damit tun? (optional)", text: $model.note, axis: .vertical)
                            .lineLimit(1...5)
                            .appFont(15.5)
                            .foregroundStyle(theme.textPrimary)
                            .focused($noteFocused)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.surfaceBorder))
                    }
                    .id("notiz")
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            // Mit Tastatur bleibt das Notizfeld über dem Senden-Knopf sichtbar
            .onChange(of: noteFocused) {
                guard noteFocused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { proxy.scrollTo("notiz", anchor: .bottom) }
                }
            }
            .onChange(of: model.note) { proxy.scrollTo("notiz", anchor: .bottom) }
            }
            sendBar
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .appFont(13, weight: .semibold)
            .foregroundStyle(theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var sendBar: some View {
        Button {
            noteFocused = false
            model.send()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .appFont(14, weight: .bold)
                Text(model.selected.map { String(localized: "An \($0.name) senden") } ?? String(localized: "Senden"))
                    .appFont(16, weight: .semibold)
                    .adaptiveLineLimit(1)
            }
            .foregroundStyle(model.canSend ? theme.sendButtonIcon : theme.textTertiary)
            .frame(maxWidth: .infinity)
            // Wächst mit der Schrift (bei Standardgröße 50 pt)
            .scaledMinFrame(minHeight: 50, relativeTo: .callout)
            .background(model.canSend ? theme.sendButton : theme.sendButtonDisabled,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .keyboardShortcut(.defaultAction)
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        .background(theme.groupedBackground)
    }

    // MARK: Rückmeldung

    private var sending: some View {
        VStack(spacing: 18) {
            if let chat = model.selected {
                SystemChatAvatar(chat: chat, size: 76)
            }
            Text(model.selected.map { String(localized: "Wird an \($0.name) gesendet …") } ?? String(localized: "Wird gesendet …"))
                .appFont(16, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(theme.accent)
                .frame(maxWidth: 220)
                .accessibilityLabel("Fortschritt")
            Text(model.progress.formatted(.percent.precision(.fractionLength(0)).locale(.app)))
                .appFont(13, weight: .medium).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .padding(28)
    }

    private func status(symbol: String?, title: String, text: String?, tint: Color = .secondary,
                        @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .appFont(46, weight: .medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title)
                .appFont(17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let text {
                Text(text)
                    .appFont(14.5)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) { actions() }
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
    }

    private func actionButton(_ title: LocalizedStringKey, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .appFont(15.5, weight: .semibold)
                .foregroundStyle(primary ? theme.sendButtonIcon : theme.textPrimary)
                .frame(maxWidth: 240)
                .scaledMinFrame(minHeight: 44, relativeTo: .callout)
                .background(primary ? theme.sendButton : theme.circleButton,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Karte mit dem, was gesendet wird: Bilder und Dateien, Links, Text und Hinweise auf Ausgelassenes.
private struct ShareContentCard: View {
    let content: ShareContent
    let thumbnails: [String: CGImage]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !content.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(content.attachments) { attachment in
                            if attachment.isImage {
                                imageTile(attachment)
                            } else {
                                fileChip(attachment)
                            }
                        }
                    }
                }
            }
            ForEach(content.links, id: \.self) { link in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link")
                        .appFont(13, weight: .semibold)
                        .foregroundStyle(theme.link)
                        .scaledFrame(20)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = link.title, !title.isEmpty {
                            Text(title)
                                .appFont(14.5, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                                .adaptiveLineLimit(2)
                        }
                        Text(link.url.host() ?? link.url.absoluteString)
                            .appFont(13)
                            .foregroundStyle(theme.textSecondary)
                            .adaptiveLineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Link: \(link.title ?? link.url.absoluteString)")
            }
            ForEach(content.texts, id: \.self) { text in
                Text(text)
                    .appFont(14.5)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(5)
            }
            ForEach(content.skipped, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .appFont(13)
                    .foregroundStyle(theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).strokeBorder(theme.surfaceBorder))
    }

    private func imageTile(_ attachment: ShareOutboxItem.Attachment) -> some View {
        ZStack {
            theme.surfaceRaised
            if let image = thumbnails[attachment.file] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .appFont(20)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Bild \(attachment.name)")
    }

    private func fileChip(_ attachment: ShareOutboxItem.Attachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: attachment))
                .appFont(20)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .appFont(13.5, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(1)
                Text(Int64(attachment.size).formatted(.byteCount(style: .file).locale(.app)))
                    .appFont(12)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .scaledMinFrame(minHeight: 74, relativeTo: .footnote)
        .frame(maxWidth: 220)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func symbol(for attachment: ShareOutboxItem.Attachment) -> String {
        if attachment.mime == "application/pdf" { return "doc.richtext.fill" }
        if attachment.mime.hasPrefix("video/") { return "film.fill" }
        if attachment.mime.hasPrefix("audio/") { return "waveform" }
        if attachment.mime.hasPrefix("text/") { return "doc.text.fill" }
        return "doc.fill"
    }
}

/// Auswahlkachel eines Scoops bzw. einer Gruppe
private struct ShareTargetTile: View {
    let chat: SystemChat
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                SystemChatAvatar(chat: chat, size: 52)
                    .padding(5)
                    .background(Circle().fill(selected ? theme.selection : .clear))
                    .overlay(Circle().strokeBorder(selected ? theme.accent : .clear, lineWidth: 2))
                Text(chat.name)
                    .appFont(12.5, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                    // Kachel im Raster: einzeilig (wie angeheftete Scoops), sonst bricht „Launch-Team“ mitten im Wort
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chat.subtitle.map { "\(chat.name), \($0)" } ?? chat.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Scoop-Figur bzw. eigenes Foto wie in der App; bei Gruppen die ersten drei Mitglieder als Haufen.
struct SystemChatAvatar: View {
    let chat: SystemChat
    var size: CGFloat

    var body: some View {
        Group {
            if let mascot = chat.mascot {
                MascotView(mascot: mascot, size: size, seed: chat.id, animated: false)
            } else {
                let shown = Array((chat.members ?? []).prefix(3))
                let member = size * (shown.count >= 3 ? 0.56 : 0.62)
                ZStack {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, m in
                        MascotView(mascot: m.mascot, size: member, seed: m.id, animated: false)
                            .offset(offset(index, count: shown.count, member: member))
                            .zIndex(Double(3 - index))
                    }
                    if shown.isEmpty {
                        Image(systemName: "person.3.fill")
                            .font(.fixed(size * 0.36))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Wie `GroupAvatar` in der App
    private func offset(_ index: Int, count: Int, member: CGFloat) -> CGSize {
        let d = (size - member) / 2 * 0.86
        switch (count, index) {
        case (1, _): return .zero
        case (2, 0): return CGSize(width: -d * 0.8, height: -d * 0.55)
        case (2, _): return CGSize(width: d * 0.8, height: d * 0.6)
        case (_, 0): return CGSize(width: 0, height: -d * 0.95)
        case (_, 1): return CGSize(width: -d, height: d * 0.75)
        default: return CGSize(width: d, height: d * 0.75)
        }
    }
}
