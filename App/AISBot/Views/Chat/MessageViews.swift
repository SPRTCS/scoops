import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Leichte, vergleichbare Sprecher-Info (statt ganzem Bot, dessen `unread`/`lastMessage` sich oft ändern).
struct SpeakerInfo: Equatable {
    var id: String
    var name: String
    var mascot: Mascot
}

extension Bot {
    var speaker: SpeakerInfo { SpeakerInfo(id: id, name: name, mascot: mascot) }
}

/// Eine Zeile im Verlauf. Equatable, damit unveränderte Zeilen beim Neuzeichnen des Chats übersprungen werden.
struct MessageRow: View, Equatable {
    let message: Message
    let chatID: String
    /// In Gruppen: Mini-Maskottchen + Name über der Blase.
    var showsAuthor: Bool = false
    /// Wer spricht: Autor in Gruppen, sonst der Bot des Chats.
    var speaker: SpeakerInfo?
    /// Statuszeilen: Rolle des Laufs im Chat (nur der neueste laufende zeigt das Live-Bild)
    var run: StatusRow.RunRole = .finished

    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.chatID == b.chatID && a.showsAuthor == b.showsAuthor && a.speaker == b.speaker
            && a.run == b.run
    }

    /// Nachricht eines anderen Scoops in einem Einzelchat (v1.9 „Scoops schreiben Scoops“)
    private var isPeer: Bool {
        guard message.role == .bot, !ChatGroup.isGroupID(chatID) else { return false }
        return message.meta.peer == true || (message.meta.authorId.map { $0 != chatID } ?? false)
    }

    var body: some View {
        switch message.role {
        case .user: UserBubble(message: message, showsOwnLabel: showsAuthor && !ChatGroup.isGroupID(chatID))
        case .bot:
            VStack(alignment: .leading, spacing: 5) {
                if (showsAuthor || isPeer), let speaker { AuthorHeader(bot: speaker) }
                BotBubble(message: message, peerColor: isPeer ? speaker.map { Color(hex: $0.mascot.color) } : nil)
            }
        case .event:
            if message.meta.kind == "mcp_login", message.meta.mcpServerId != nil {
                MCPLoginCard(message: message)
            } else if let fileID = message.meta.fileId {
                VStack(spacing: 6) {
                    EventLine(message: message)
                    FileCard(fileID: fileID, fallbackText: message.text)
                }
            } else {
                EventLine(message: message)
            }
        case .status:
            if let speaker { StatusRow(message: message, bot: speaker, showsName: ChatGroup.isGroupID(chatID), run: run) }
        case .approval:
            VStack(alignment: .leading, spacing: 5) {
                if showsAuthor, message.meta.authorId != nil, let speaker { AuthorHeader(bot: speaker) }
                // Geteilter Scoop: Gäste sehen nur „Wartet auf Freigabe durch <Admin>“, ohne Knöpfe
                GuestApprovalGate(message: message) {
                    if message.meta.kind == "mail", let mail = message.meta.mail {
                        MailCard(message: message, mail: mail)
                    } else if message.meta.kind == "vault", let vault = message.meta.vault {
                        VaultCard(message: message, vault: vault)
                    } else if message.meta.kind == "scoop_update", let update = message.meta.scoopUpdate {
                        ScoopUpdateCard(message: message, update: update)
                    } else if let fields = message.meta.secretFields, !fields.isEmpty {
                        MCPSecretCard(message: message, fields: fields)
                    } else {
                        ApprovalCard(message: message)
                    }
                }
            }
        case .unknown:
            if !message.text.isEmpty { EventLine(message: message) }
        }
    }
}

/// Mini-Maskottchen + Name über einer Blase im Gruppenchat.
struct AuthorHeader: View {
    let bot: SpeakerInfo
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            MascotView(mascot: bot.mascot, size: 20, seed: bot.id, animated: false)
            Text(bot.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.leading, 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Blasen

struct BotBubble: View {
    let message: Message
    /// Nachricht eines anderen Scoops: Rahmen in seiner Maskottchenfarbe
    var peerColor: Color? = nil
    @Environment(\.theme) private var theme
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownView(text: message.text, mentionBots: store.bots)
                .font(.system(size: 15))
                .lineSpacing(3.5)
                .foregroundStyle(theme.textPrimary)
                #if os(macOS)
                .textSelection(.enabled)
                #endif
                // Antwort auf eine Nachricht (v1.15): Zitat oben in der Blase
                .withReplyQuote(message.meta.replyTo, chatID: message.chatId)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .themedCard(theme, radius: theme.bubbleRadius)
                .overlay {
                    if let peerColor {
                        RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous)
                            .strokeBorder(peerColor, lineWidth: 1.75)
                    }
                }
                .messageReactions(message, trailing: false, copyText: message.text)
            if message.meta.live == true {
                // Im Live-Sprechmodus gesprochen (v1.13)
                Label("Live gesprochen", systemImage: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 6)
                    .padding(.top, 3)
            }
        }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAction(named: "Kopieren") { Clipboard.copy(message.text) }
    }
}

struct UserBubble: View {
    let message: Message
    /// Geteilter Scoop: „Du“ über der eigenen Nachrichtengruppe (damit klar ist, wer was geschrieben hat)
    var showsOwnLabel = false
    @Environment(\.theme) private var theme
    @Environment(AppStore.self) private var store

    var body: some View {
        // Geteilter Scoop: Nachrichten anderer Personen links mit Name und Bild
        if store.isOwnMessage(message) { ownBubble } else { ForeignUserBubble(message: message) }
    }

    /// Text der eigenen Blase; gesendete Modi (Aufgabe, Routine …) mit farbigem Chip davor.
    @ViewBuilder private var bubbleText: some View {
        if let parsed = ComposerMode.parse(message.text) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ComposerModeChip(mode: parsed.mode, compact: true)
                    if parsed.mode == .task, let o = message.meta.taskOptions { taskOptionsText(o) }
                }
                if !parsed.rest.isEmpty { plainText(parsed.rest) }
            }
        } else {
            plainText(message.text)
        }
    }

    /// Termin/Modell aus dem Aufgaben-Chip, z. B. „Mo 08:00 · Sonnet 5.5“
    private func taskOptionsText(_ o: TaskOptions) -> some View {
        let start = o.backlog == true ? "Offen gesammelt" : o.scheduledAt.map { Formatting.dayTime($0) }
        let scope = o.access?.accessScope.map { $0.text(folders: o.access?.folders ?? []) }
        let parts = [start, o.model.map { BotModel.displayName(for: $0) }, scope].compactMap { $0 }
        let icon = o.backlog == true ? "tray" : (o.scheduledAt == nil ? "cpu" : "calendar.badge.clock")
        return Label(parts.joined(separator: " · "), systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
    }

    private func plainText(_ s: String) -> some View {
        Text(Mentions.attributed(s, bots: store.bots, theme: theme))
            .font(.system(size: 15))
            .lineSpacing(3)
            .foregroundStyle(theme.textPrimary)
            #if os(macOS)
            .textSelection(.enabled)
            #endif
    }

    private var ownBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let to = message.meta.toPeople, !to.isEmpty {
                Label("Nur an \(to.joined(separator: ", "))", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.trailing, 4)
            } else if showsOwnLabel {
                Text("Du")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
            if message.text.isEmpty, let ref = message.meta.replyTo {
                // Nur Anhänge: Zitat über den Anhängen
                ReplyQuote(ref: ref, chatID: message.chatId).frame(maxWidth: 280)
            }
            if let ids = message.meta.fileIds, !ids.isEmpty {
                MessageAttachments(fileIDs: ids)
            }
            if !message.text.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    Spacer(minLength: 60)
                    if message.meta.voice == true {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.bottom, 10)
                            .accessibilityLabel(message.meta.live == true ? "Live gesprochen" : "Gesprochen")
                    }
                    bubbleText
                        .withReplyQuote(message.meta.replyTo, chatID: message.chatId)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ReplyQuote.accessibilityPrefix(message.meta.replyTo) + "Du: \(message.text)")
                        .accessibilityAction(named: "Kopieren") { Clipboard.copy(message.text) }
                        .accessibilityAction(named: "Zur Originalnachricht") { jumpToOriginal() }
                        .messageReactions(message, trailing: true, copyText: message.text)
                }
                .opacity(message.localState == .sending ? 0.6 : 1)
            }
            if message.localState == .failed {
                Button { store.retry(message) } label: {
                    Label("Nicht gesendet · Erneut senden", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.danger)
                }
                .buttonStyle(.plain)
            } else if message.localState == .sending {
                Text("Wird gesendet …")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.smooth(duration: 0.2), value: message.localState)
    }

    private func jumpToOriginal() {
        guard let id = message.meta.replyTo?.id else { return }
        Task { await store.jumpToMessage(id, chatID: message.chatId) }
    }
}

struct EventLine: View {
    let message: Message
    @Environment(\.theme) private var theme
    @Environment(AppStore.self) private var store

    /// „Fähigkeit gespeichert: …“ öffnet die Fähigkeit.
    private var isSkillEvent: Bool {
        message.meta.skillId != nil || message.meta.icon == "wand.and.stars" || message.text.hasPrefix("Fähigkeit gespeichert")
    }

    @Environment(\.openURL) private var openURL

    /// Ereignis mit Link (z. B. T3-Thread): antippbar, öffnet den Link (app.t3.codes öffnet die T3-App, wenn installiert).
    private var link: URL? {
        guard let s = message.meta.url, let u = URL(string: s), u.scheme != nil else { return nil }
        return u
    }

    var body: some View {
        if let link {
            Button { openURL(link) } label: { line }
                .buttonStyle(.plain)
                .help(link.absoluteString)
                .accessibilityHint("Öffnet den Link")
        } else if isSkillEvent {
            Button {
                Task { if let s = await store.skill(for: message) { store.presentedSkillID = s.id } }
            } label: {
                line
            }
            .buttonStyle(.plain)
            .help("Fähigkeit öffnen")
            .accessibilityHint("Öffnet die Fähigkeit")
        } else {
            line
        }
    }

    /// „An Tina: …“ – dieser Scoop hat einem anderen geschrieben (v1.9)
    private var peerTarget: Bot? {
        guard message.meta.peerOut == true, let id = message.meta.targetId else { return nil }
        return store.bot(id)
    }

    private var line: some View {
        HStack(spacing: 5) {
            if message.meta.peerOut == true {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 10.5, weight: .semibold))
                if let target = peerTarget {
                    MascotView(mascot: target.mascot, size: 16, seed: target.id, animated: false)
                }
            } else {
                Image(systemName: SymbolName.resolve(message.meta.icon,
                                                     fallback: message.text.contains("→") ? "arrow.right.circle" : "info.circle"))
                    .font(.system(size: 11, weight: .medium))
            }
            Text(message.text)
                .font(.system(size: 12))
            if link != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
            } else if isSkillEvent {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(isSkillEvent || link != nil ? theme.accent : theme.textSecondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Tippen

struct TypingBubble: View {
    let bot: Bot
    var showsName = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            MascotView(mascot: bot.mascot, size: 26, mood: .working, seed: bot.id)
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        let phase = reduceMotion ? 0.5 : (sin(t * 6 - Double(i) * 0.9) + 1) / 2
                        Circle()
                            .fill(theme.textSecondary)
                            .frame(width: 7, height: 7)
                            .opacity(0.35 + 0.65 * phase)
                            .offset(y: -2.5 * phase)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .themedCard(theme, radius: theme.bubbleRadius)
            if showsName {
                Text("\(bot.name) schreibt …")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bot.name) schreibt")
    }
}

// MARK: - Status

struct StatusRow: View {
    let message: Message
    let bot: SpeakerInfo
    /// In Gruppen: Name des Scoops vor „Fertig“ usw.
    var showsName = false
    var run: RunRole = .finished
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var showScreen = false

    /// Rolle eines Laufs im Chat (berechnet in `ChatView`, siehe `RunRole.roles(in:chatID:)`).
    enum RunRole: Equatable {
        /// neuester laufender Lauf des Chats: nur er zeigt das Live-Bild des Bot-Rechners
        case current
        /// läuft (z. B. ein anderer Scoop in einer Gruppe), aber nicht der neueste: ohne Live-Bild
        case running
        /// läuft laut Server noch, aber derselbe Scoop hat danach schon einen neuen Lauf begonnen (verpasstes Update)
        case superseded
        /// abgeschlossen (done/stopped/failed)
        case finished

        /// Rollen aller Statuszeilen eines Chats in einem Durchgang.
        static func roles(in messages: [Message], chatID: String) -> [String: RunRole] {
            var roles: [String: RunRole] = [:]
            var seenAuthors: Set<String> = []
            var currentAssigned = false
            for m in messages.reversed() where m.role == .status {
                // Aufgaben laufen neben dem Chat: eigene „Spur“, ein späterer Chat-Lauf verdrängt sie nicht
                let author = m.meta.task.map { "task:\($0.id)" } ?? (m.meta.authorId ?? chatID)
                defer { seenAuthors.insert(author) }
                guard m.isRunning else { roles[m.id] = .finished; continue }
                if seenAuthors.contains(author) {
                    roles[m.id] = .superseded
                } else if !currentAssigned {
                    roles[m.id] = .current
                    currentAssigned = true
                } else {
                    roles[m.id] = .running
                }
            }
            return roles
        }
    }

    private var state: String { message.meta.state ?? "done" }
    /// Läuft wirklich noch (bewegtes Maskottchen, letzte Zeile); veraltete „running“-Zeilen gelten als beendet
    private var running: Bool { state == "running" && run != .superseded }
    /// Nur der neueste laufende Lauf zeigt das Live-Bild – ältere Karten fragen den Bildschirm nicht mehr ab.
    /// Geteilte Scoops: Live-Bild nur ab Rechner-Stufe „Zusehen“ (sonst nur „arbeitet am Rechner“)
    private var showsLive: Bool {
        running && run == .current && message.meta.usesComputer == true && store.computerAccess(message.chatId).canView
    }
    /// Durch einen Server-Neustart abgebrochen (v1.10)
    private var interrupted: Bool { state == "stopped" && message.meta.interrupted == true }
    private var lines: [String] { message.meta.lines ?? [] }
    /// Hintergrund-Aufgabe (Aufgabenmodus, v1.19)
    private var task: MessageMeta.TaskInfo? { message.meta.task }
    private var waiting: Bool { running && task?.state == "waiting" }
    @State private var stopping = false

    private var title: String {
        let base = baseTitle
        return showsName && !running ? "\(bot.name) · \(base)" : base
    }

    private var baseTitle: String {
        if let task {
            if run == .superseded { return "Aufgabe beendet" }
            switch state {
            case "running":
                if waiting {
                    if task.waitingKind == "scoop" { return "Aufgabe wartet auf \(task.waitingFor ?? "einen anderen Scoop")" }
                    return "Aufgabe wartet auf dich"
                }
                return task.state == "queued" ? "Aufgabe wartet auf einen Platz" : "\(bot.name) arbeitet an einer Aufgabe …"
            case "failed": return "Aufgabe fehlgeschlagen"
            case "stopped":
                if interrupted { return "Aufgabe unterbrochen" }
                return task.state == "limit" ? "Aufgabe am Limit angehalten" : "Aufgabe angehalten"
            default:
                if let s = message.meta.startedAt, let f = message.meta.finishedAt {
                    return "Aufgabe fertig · \(Formatting.duration(f.timeIntervalSince(s)))"
                }
                return "Aufgabe fertig"
            }
        }
        if run == .superseded { return "Beendet" }
        switch state {
        case "running": return "\(bot.name) arbeitet …"
        case "failed": return "Fehlgeschlagen"
        case "stopped": return interrupted ? "Abgebrochen" : "Angehalten"
        default:
            if let s = message.meta.startedAt, let f = message.meta.finishedAt {
                return "Fertig · \(Formatting.duration(f.timeIntervalSince(s)))"
            }
            return "Fertig"
        }
    }

    private var stepText: String {
        lines.count == 1 ? "1 Schritt" : "\(lines.count) Schritte"
    }

    private var icon: (String, Color) {
        if run == .superseded { return ("stop.circle", theme.textTertiary) }
        switch state {
        case "failed": return ("exclamationmark.triangle.fill", theme.warning)
        case "stopped": return (interrupted ? "bolt.horizontal.circle" : "stop.circle", theme.textTertiary)
        default: return ("checkmark.circle.fill", theme.success)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running {
                        // Nur der aktuelle Lauf bewegt sich (spart Animationen bei mehreren Karten)
                        MascotView(mascot: bot.mascot, size: 22, mood: .working, seed: bot.id, animated: run == .current)
                    } else {
                        Image(systemName: icon.0).foregroundStyle(icon.1).font(.system(size: 14))
                            .frame(width: 22, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(title).foregroundStyle(running ? theme.textPrimary : theme.textSecondary)
                            if !lines.isEmpty {
                                Text("· \(stepText)").foregroundStyle(theme.textTertiary)
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        if let task, let t = task.title, !t.isEmpty {
                            Label(t, systemImage: "checklist")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                        if running, !expanded, let last = lines.last {
                            Text(last)
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    if !lines.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        let current = running && idx == lines.count - 1
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: current ? "circle.dotted" : "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(current ? theme.accent : theme.textTertiary)
                                .frame(width: 14)
                                .symbolEffect(.rotate, isActive: current)
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(current ? theme.textPrimary : theme.textSecondary)
                        }
                    }
                    if let note = task?.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.leading, 22)
                    }
                    if let task, running {
                        Button {
                            stopping = true
                            Task { await store.stopTask(task.id, chatID: message.chatId); stopping = false }
                        } label: {
                            Label(stopping ? "Wird angehalten …" : "Aufgabe anhalten", systemImage: "stop.circle")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .disabled(stopping)
                        .padding(.leading, 22)
                        .accessibilityLabel("Aufgabe anhalten")
                    }
                    if !running, let model = message.meta.model {
                        let cost = message.meta.costUsd.map { " · \(Formatting.usd($0))" } ?? ""
                        Text("\(BotModel.displayName(for: model))\(cost)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.leading, 22)
                    }
                }
                .padding(.leading, 7)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showsLive {
                Button { showScreen = true } label: {
                    ScreenThumbnail(cornerRadius: 10)
                        .frame(width: 220)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                Circle().fill(theme.danger).frame(width: 6, height: 6)
                                Text("Live").font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(7)
                        }
                }
                .buttonStyle(.plain)
                .help("Bildschirm groß anzeigen")
                .accessibilityLabel("Live-Bildschirm von \(bot.name) öffnen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(theme.surface.opacity(running ? 0.75 : 0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.surfaceBorder))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: lines.count)
        .help(interrupted ? "Durch einen Neustart des Servers abgebrochen" : "")
        // Ältere bzw. fertige Läufe klappen von selbst ein (von Hand wieder aufklappbar)
        .onChange(of: running) { _, now in if !now { withAnimation(.snappy(duration: 0.25)) { expanded = false } } }
        .onChange(of: run) { _, now in if now != .current { withAnimation(.snappy(duration: 0.25)) { expanded = false } } }
        .sheet(isPresented: $showScreen) {
            ScreenViewer(botName: bot.name)
                .environment(\.theme, theme)
                .environment(store)
        }
    }
}

// MARK: - Freigabe

struct ApprovalCard: View {
    let message: Message
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var working = false
    @State private var confirmAlways = false
    @State private var error: String?

    private var state: String { message.meta.state ?? "pending" }
    /// v1.20: Server erlaubt „Immer erlauben“ (nie bei Anrufen, Tresor, Schlössern, Zahlungen oder Gast-Freigaben)
    private var canAlways: Bool { message.meta.canAlways == true && message.meta.guestView != true }
    private var alwaysLabel: String { message.meta.alwaysLabel ?? message.meta.title ?? message.text }
    private var scoopName: String { store.bot(message.meta.authorId ?? message.chatId)?.name ?? "Der Scoop" }
    /// Anruf über Lucy (`meta.kind == "call"`) bzw. Auftrag an T3 Code (`"t3"`): eigenes Symbol und Beschriftungen.
    private var isCall: Bool { message.meta.kind == "call" }
    private var isT3: Bool { message.meta.kind == "t3" }

    private var kindIcon: String { isCall ? "phone.arrow.up.right" : (isT3 ? "hammer.fill" : "hand.raised.fill") }
    private var kindColor: Color { isCall ? theme.success : (isT3 ? theme.accent : theme.warning) }
    private var kindLabel: String? { isCall ? "Anruf" : (isT3 ? "T3 Code" : nil) }
    private var approveTitle: String { isCall ? "Anrufen lassen" : (isT3 ? "An T3 geben" : "Freigeben") }
    private var declineTitle: String { isCall ? "Nicht anrufen" : (isT3 ? "Nicht jetzt" : "Ablehnen") }
    private var approvedTitle: String { isCall ? "Anruf freigegeben" : (isT3 ? "An T3 gegeben" : "Freigegeben") }
    private var declinedTitle: String { isCall ? "Nicht angerufen" : (isT3 ? "Nicht gegeben" : "Abgelehnt") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kindIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(kindColor)
                    .frame(width: 26, height: 26)
                    .background(kindColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(state == "pending" ? (kindLabel.map { "\($0) · Freigabe nötig" } ?? "Freigabe nötig") : (kindLabel ?? "Freigabe"))
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textTertiary)
                    Text(message.meta.title ?? message.text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            if let details = message.meta.details, !details.isEmpty {
                Text(details)
                    .font(.system(size: 13.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(theme.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    #if os(macOS)
                    .textSelection(.enabled)
                    #endif
            }
            switch state {
            case "pending":
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            decide(true)
                        } label: {
                            Text(approveTitle).frame(minWidth: 90)
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        Button {
                            decide(false)
                        } label: {
                            Text(declineTitle).frame(minWidth: 80)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        if working { ProgressView().controlSize(.small) }
                    }
                    if canAlways {
                        AlwaysAllowButton { confirmAlways = true }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(working)
            case "approved":
                Label(message.meta.always == true ? "Immer erlaubt" : approvedTitle,
                      systemImage: message.meta.always == true ? "checkmark.seal.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.success)
            default:
                Label(declinedTitle, systemImage: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { Clipboard.copy(message.meta.details ?? message.text) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        .alwaysAllowConfirmation(isPresented: $confirmAlways, label: alwaysLabel, scoopName: scoopName) {
            working = true
            error = nil
            Task {
                error = await store.decideAlways(message)
                working = false
            }
        }
    }

    private func decide(_ approve: Bool) {
        working = true
        Task {
            await store.decide(message, approve: approve)
            working = false
        }
    }
}

// MARK: - Verbesserung für einen Scoop (v1.21, Aufsicht)

/// Freigabe-Karte `kind == "scoop_update"`: Ein Scoop mit Aufsicht schlägt eine dauerhafte Änderung bei einem anderen
/// Scoop vor. Zeigt Ziel-Scoop, Art, Begründung und Vorher/Nachher; der neue Text ist vor dem Freigeben bearbeitbar.
/// Kein „Immer erlauben“ (der Server lehnt es für diese Art ab).
struct ScoopUpdateCard: View {
    let message: Message
    let update: ScoopUpdate
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft: String
    @State private var working = false
    @State private var error: String?
    @State private var showBefore = false

    init(message: Message, update: ScoopUpdate) {
        self.message = message
        self.update = update
        _draft = State(initialValue: update.after)
    }

    private var status: String {
        if update.status == "pending", message.meta.state == "declined" { return "declined" }
        return update.status
    }
    private var isPending: Bool { status == "pending" && message.meta.state != "approved" }
    private var target: Bot? { update.targetId.flatMap { store.bot($0) } }
    private var proposer: String { store.bot(message.meta.authorId ?? message.chatId)?.name ?? "Dein Scoop" }
    private var isModel: Bool { update.art == "routine_modell" }
    private var targetTitle: String {
        if let target { return target.title }
        guard let label = update.targetLabel, !label.isEmpty else { return update.targetName }
        return "\(update.targetName) · \(label)"
    }
    private var edited: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) != update.after.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            targetRow
            if let reason = update.reason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Warum").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    Text(reason).font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isModel {
                modelChange
            } else {
                if let before = update.before, !before.isEmpty { beforeBox(before) }
                afterBox
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: 480, alignment: .leading)
        .themedCard(theme, radius: theme.bubbleRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.2), value: status)
        .animation(.smooth(duration: 0.2), value: editing)
        .contextMenu {
            Button { Clipboard.copy(message.meta.details ?? update.after) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        .onChange(of: update.after) { _, new in if !editing { draft = new } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(headerTint)
                .frame(width: 28, height: 28)
                .background(headerTint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(isPending ? "Verbesserung · Freigabe nötig" : "Verbesserung · \(update.artTitle)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textTertiary)
                Text(update.label ?? update.artTitle)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerIcon: String {
        switch status {
        case "applied": "checkmark"
        case "declined": "xmark"
        case "failed": "exclamationmark.triangle.fill"
        default: update.artIcon
        }
    }

    private var headerTint: Color {
        switch status {
        case "applied": theme.success
        case "declined": theme.textTertiary
        case "failed": theme.danger
        default: theme.accent
        }
    }

    /// „Für Mila · MLP“ mit Maskottchen, darunter wer vorschlägt
    private var targetRow: some View {
        HStack(spacing: 8) {
            if let target {
                MascotView(mascot: target.mascot, size: 22, seed: target.id, animated: false)
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: 18)).foregroundStyle(theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Für \(targetTitle)")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("Vorschlag von \(proposer) · \(update.artTitle)")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modelChange: some View {
        HStack(spacing: 8) {
            Text(update.before ?? "wie Scoop").strikethrough().foregroundStyle(theme.textTertiary)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
            Text(update.after).fontWeight(.semibold).foregroundStyle(theme.textPrimary)
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func beforeBox(_ before: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showBefore.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Vorher").font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: showBefore ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(before)
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(showBefore ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .textSelection(.enabled)
                #endif
        }
    }

    private var afterBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(update.before?.isEmpty == false ? "Nachher" : "Neu")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.textTertiary)
                if update.edited == true || (isPending && edited) {
                    Text("bearbeitet").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accent)
                }
                Spacer()
                if isPending, update.editable, !working {
                    Button(editing ? "Fertig" : "Bearbeiten") { editing.toggle() }
                        .font(.system(size: 12.5, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                }
            }
            Group {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110, maxHeight: 260)
                } else {
                    Text(isPending ? draft : update.after)
                        .font(.system(size: 13.5))
                        .foregroundStyle(theme.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case "pending":
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { decide(true) } label: { Text("Freigeben").frame(minWidth: 90) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { decide(false) } label: { Text("Ablehnen").frame(minWidth: 80) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    if working { ProgressView().controlSize(.small) }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(working)
        case "applied":
            Label("Übernommen bei \(update.targetName)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.success)
        case "failed":
            Label("Nicht übernommen" + (update.error.map { ": \($0)" } ?? ""), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Label("Abgelehnt", systemImage: "xmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary)
        }
    }

    private func decide(_ approve: Bool) {
        working = true
        error = nil
        editing = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            error = await store.decideScoopUpdate(message, approve: approve, after: approve && update.editable && edited ? text : nil)
            working = false
        }
    }
}

/// v1.20: dezenter dritter Knopf auf Freigabe- und Mail-Karte („Immer erlauben“).
struct AlwaysAllowButton: View {
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Label("Immer erlauben", systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Freigeben und künftig ohne Rückfrage erlauben")
    }
}

extension View {
    /// Rückfrage vor „Immer erlauben“: was künftig automatisch freigegeben wird und wo man es wieder entfernt.
    func alwaysAllowConfirmation(isPresented: Binding<Bool>, label: String, scoopName: String,
                                 action: @escaping () -> Void) -> some View {
        confirmationDialog("„\(label)“ immer erlauben?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Freigeben und immer erlauben", action: action)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(scoopName) fragt dafür nicht mehr, sondern führt es direkt aus und meldet es im Chat. Entfernen kannst du das im Profil unter „Dauerhafte Freigaben“.")
        }
    }
}

/// Kapsel-Buttons im Theme (primär = Akzent, sekundär = Fläche).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .secondary ? theme.surfaceBorder : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.sendButtonIcon
        case .secondary: theme.textPrimary
        case .destructive: theme.textOnAccent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: theme.sendButton
        case .secondary: theme.surfaceRaised
        case .destructive: theme.danger
        }
    }
}

/// SF-Symbol-Namen vom Server prüfen: Unbekannte Namen (andere OS-Version, Tippfehler) fallen auf ein Ersatzsymbol zurück.
enum SymbolName {
    private static var known: [String: Bool] = [:]

    static func resolve(_ name: String?, fallback: String) -> String {
        guard let name, !name.isEmpty else { return fallback }
        if let ok = known[name] { return ok ? name : fallback }
        #if canImport(UIKit)
        let ok = UIImage(systemName: name) != nil
        #else
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
        known[name] = ok
        return ok ? name : fallback
    }
}
