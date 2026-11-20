import SwiftUI

/// Mail-Karte (v1.9, `meta.kind == "mail"`): Entwurf direkt in der Karte bearbeiten und senden bzw. verwerfen.
/// Zustände aus `mail.status`: draft (Formular), sending, sent (kompakt, aufklappbar), failed, discarded.
struct MailCard: View {
    let message: Message
    let mail: MailDraft
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var account: String
    @State private var to: String
    @State private var cc: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var showsCc: Bool
    @State private var bodyExpanded = false
    @State private var expanded = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmAlways = false

    init(message: Message, mail: MailDraft) {
        self.message = message
        self.mail = mail
        _account = State(initialValue: mail.account ?? "")
        _to = State(initialValue: mail.to.joined(separator: ", "))
        _cc = State(initialValue: mail.cc.joined(separator: ", "))
        _subject = State(initialValue: mail.subject)
        _bodyText = State(initialValue: mail.body)
        _showsCc = State(initialValue: !mail.cc.isEmpty)
    }

    private var status: String { mail.status }
    private var isDraft: Bool { status == "draft" && message.meta.state != "declined" }
    private var kindTitle: String {
        mail.isReply ? String(localized: "mail.reply", defaultValue: "Antwort", comment: "Mail-Karte: Antwort auf eine Mail (englisch „Reply“)") : String(localized: "Mail")
    }
    /// Lange Texte erst eingeklappt
    private var bodyIsLong: Bool { bodyText.count > 280 || bodyText.split(separator: "\n", omittingEmptySubsequences: false).count > 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch status {
            case "draft" where isDraft, "sending":
                form(editable: isDraft && !working)
                if let error { errorText(error) }
                if status == "sending" || working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Wird gesendet …").appFont(13, weight: .medium).foregroundStyle(theme.textSecondary)
                    }
                } else {
                    buttons
                }
            default:
                if expanded { form(editable: false) }
                if status == "failed", let e = mail.error ?? error { errorText(e) }
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.2), value: expanded)
        .animation(.smooth(duration: 0.2), value: status)
        .task(id: isDraft) {
            // Konten für „Von“ laden, falls noch nicht da
            if isDraft, store.connections == nil { await store.loadConnections() }
        }
        .contextMenu {
            Button { Clipboard.copy(plainText) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        .alwaysAllowConfirmation(isPresented: $confirmAlways, label: alwaysLabel,
                                 scoopName: store.bot(message.meta.authorId ?? message.chatId)?.name ?? String(localized: "Der Scoop", comment: "Rückfall für den Namen am Satzanfang")) {
            decideAlways()
        }
    }

    // MARK: Kopf

    private var header: some View {
        Button {
            if !isDraft && status != "sending" { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: headerIcon)
                    .appFont(13, weight: .semibold)
                    .foregroundStyle(headerTint)
                    .scaledFrame(28)
                    .background(headerTint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindTitle)
                        .appFont(11.5, weight: .medium).foregroundStyle(theme.textTertiary)
                    Text(headline)
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if !isDraft && status != "sending" {
                    Image(systemName: "chevron.down")
                        .appFont(11, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDraft || status == "sending")
        .accessibilityHint(isDraft || status == "sending" ? "" : (expanded ? "Zuklappen" : "Aufklappen"))
    }

    private var headerIcon: String {
        switch status {
        case "sent": "checkmark"
        case "failed": "exclamationmark"
        case "discarded": "xmark"
        default: mail.isReply ? "arrowshape.turn.up.left.fill" : "envelope.fill"
        }
    }

    private var headerTint: Color {
        switch status {
        case "sent": theme.success
        case "failed": theme.danger
        case "discarded": theme.textTertiary
        default: theme.accent
        }
    }

    private var headline: String {
        switch status {
        case "sent":
            let time = (mail.sentAt ?? message.createdAt).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.app))
            let recipients = mail.to.joined(separator: ", ")
            return String(localized: "Gesendet an \(recipients) · \(time)")
        case "failed": return String(localized: "Nicht gesendet: \(mail.subject)")
        case "discarded": return String(localized: "Verworfen: \(mail.subject)")
        default: return mail.subject.isEmpty ? (message.meta.title ?? message.text) : mail.subject
        }
    }

    // MARK: Formular

    private func form(editable: Bool) -> some View {
        VStack(spacing: 0) {
            row("Von") { fromField(editable: editable) }
            divider
            row("An") { field("Empfänger", text: $to, editable: editable, email: true) }
            if showsCc || !cc.isEmpty {
                divider
                row("Cc") { field("Kopie an", text: $cc, editable: editable, email: true) }
            }
            divider
            row("Betreff") {
                if mail.isReply {
                    // Antwort in einem Verlauf: Betreff nur Anzeige
                    Text(subject).appFont(14).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    field("Betreff", text: $subject, editable: editable)
                }
            }
            divider
            bodyArea(editable: editable)
        }
        .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
    }

    private var divider: some View {
        Rectangle().fill(theme.surfaceBorder).frame(height: 0.5).padding(.leading, 12)
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        // Große Schrift (Bedienungshilfen): Beschriftung über dem Feld statt in einer festen Spalte
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: dynamicTypeSize.isAccessibilitySize ? 2 : 10) {
            Text(label)
                .appFont(13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : AppFont.scaled(54, relativeTo: .footnote, in: dynamicTypeSize),
                       alignment: .leading)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func field(_ placeholder: LocalizedStringKey, text: Binding<String>, editable: Bool, email: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .appFont(14)
            .foregroundStyle(theme.textPrimary)
            .disabled(!editable)
            .autocorrectionDisabled(email)
            #if os(iOS)
            .textInputAutocapitalization(email ? .never : .sentences)
            .keyboardType(email ? .emailAddress : .default)
            #endif
    }

    @ViewBuilder
    private func fromField(editable: Bool) -> some View {
        let accounts = store.gmailAccounts
        let current = accounts.first { $0.alias == account || ($0.alias == nil && account.isEmpty) }
        let label = HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(current?.displayName ?? (account.isEmpty ? String(localized: "Standard", comment: "Mail-Karte: Standard-Konto als Absender") : account))
                    .appFont(14, weight: .medium).foregroundStyle(theme.textPrimary)
                if let email = current?.email ?? mail.accountEmail {
                    Text(email).appFont(12).foregroundStyle(theme.textTertiary).adaptiveLineLimit(1)
                }
            }
            if editable && accounts.count > 1 {
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(10, weight: .semibold).foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            if editable && !showsCc && cc.isEmpty {
                Button("Cc") { showsCc = true }
                    .appFont(12.5, weight: .semibold)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel("Cc hinzufügen")
            }
        }
        if editable && accounts.count > 1 {
            Menu {
                ForEach(accounts) { a in
                    Button {
                        account = a.alias ?? ""
                    } label: {
                        if (a.alias ?? "") == account {
                            Label("\(a.displayName) · \(a.email ?? "")", systemImage: "checkmark")
                        } else {
                            Text("\(a.displayName) · \(a.email ?? "")")
                        }
                    }
                }
            } label: { label }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Von: \(current?.displayName ?? account)")
        } else {
            label
        }
    }

    @ViewBuilder
    private func bodyArea(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editable && (bodyExpanded || !bodyIsLong) {
                TextField("Text", text: $bodyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(14)
                    .lineSpacing(2.5)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(3...)
            } else {
                Text(bodyText)
                    .appFont(14)
                    .lineSpacing(2.5)
                    .foregroundStyle(editable ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(bodyExpanded || !bodyIsLong ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if bodyIsLong { bodyExpanded = true } }
                    #if os(macOS)
                    .textSelection(.enabled)
                    #endif
            }
            if bodyIsLong {
                Button(bodyExpanded ? "Weniger" : "Mehr") {
                    withAnimation(.smooth(duration: 0.2)) { bodyExpanded.toggle() }
                }
                .appFont(13, weight: .semibold)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .appFont(13)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Knöpfe

    private var buttons: some View {
        // Schmale Karte (iPhone): „Immer erlauben“ unter die Knöpfe
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                alwaysButton
                Spacer(minLength: 0)
                pills
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    pills
                }
                alwaysButton
            }
        }
    }

    private var pills: some View {
        AdaptiveButtonRow(spacing: 8) {
            Button { decide(false) } label: { Text("Abbrechen").frame(minWidth: 80) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button { decide(true) } label: {
                Label("Senden", systemImage: "paperplane.fill").frame(minWidth: 90)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(addresses(to).isEmpty)
        }
        // Nur senkrecht fest: Bei großer Schrift dürfen die Knöpfe untereinander stehen
        .fixedSize(horizontal: false, vertical: true)
    }

    /// v1.20: Mails an diese Empfänger künftig ohne Rückfrage senden
    @ViewBuilder
    private var alwaysButton: some View {
        if message.meta.canAlways == true {
            AlwaysAllowButton { confirmAlways = true }
                .disabled(addresses(to).isEmpty)
                .fixedSize()
        }
    }

    private func addresses(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Nur geänderte Felder
    private var edits: MailEdits {
        var e = MailEdits()
        if account != (mail.account ?? "") { e.account = account }
        let toList = addresses(to), ccList = addresses(cc)
        if toList != mail.to { e.to = toList }
        if ccList != mail.cc { e.cc = ccList }
        if !mail.isReply, subject != mail.subject { e.subject = subject }
        if bodyText != mail.body { e.body = bodyText }
        return e
    }

    private func decideAlways() {
        working = true
        error = nil
        let e = edits
        Task {
            error = await store.decideAlways(message, mailEdits: e)
            working = false
        }
    }

    /// Bezeichnung der Dauerfreigabe mit den aktuell eingetragenen Empfängern
    private var alwaysLabel: String {
        let rcpt = (addresses(to) + addresses(cc)).map { $0.lowercased() }
        let list = rcpt.joined(separator: ", ")
        return rcpt.isEmpty ? (message.meta.alwaysLabel ?? String(localized: "Mails")) : String(localized: "Mails an \(list)")
    }

    private func decide(_ approve: Bool) {
        working = true
        error = nil
        let e = approve ? edits : nil
        Task {
            error = await store.decideMail(message, approve: approve, edits: e)
            working = false
        }
    }

    private var plainText: String {
        let from = mail.accountEmail ?? mail.account ?? ""
        let to = mail.to.joined(separator: ", ")
        var lines = [String(localized: "Von: \(from)"), String(localized: "An: \(to)")]
        if !mail.cc.isEmpty { lines.append("Cc: \(mail.cc.joined(separator: ", "))") }
        lines.append(String(localized: "Betreff: \(mail.subject)"))
        return lines.joined(separator: "\n") + "\n\n" + mail.body
    }
}
