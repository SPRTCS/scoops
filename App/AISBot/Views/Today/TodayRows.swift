import SwiftUI

// MARK: - Bausteine der Seite „Heute“

/// Überschrift eines Abschnitts mit Symbol und Anzahl.
struct TodaySectionHeader: View {
    let title: String
    let icon: String
    let tint: Color
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appFont(12, weight: .semibold)
                .foregroundStyle(tint)
                .scaledFrame(26)
                .background(tint.opacity(0.14), in: Circle())
            Text(title)
                .appFont(17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .appFont(12, weight: .semibold).monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(theme.hover, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Karte mit Zeilen und Haarlinien dazwischen.
struct TodayListCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { GroupedDivider(inset: 60) }
                    rows[i]
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .themedCard(theme)
    }
}

/// Zeile, die etwas öffnet: Fläche antippbar, rechts optional ein eigener Knopf (z. B. Stopp).
private struct TodayRowButton<Label: View, Trailing: View>: View {
    /// Was VoiceOver für die Zeile vorliest
    var spoken: String
    var action: () -> Void
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                label
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(radius: 0))
            .accessibilityLabel(spoken)
            trailing
        }
    }
}

/// „seit 21:53“ am Zeilenende; fehlt der Platz (iPhone), entfällt die Uhrzeit zugunsten von Titel und Statuszeile.
private struct TodayRunLayout<Avatar: View>: View {
    var title: String
    var line: String
    var since: Date?
    @ViewBuilder var avatar: Avatar
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            avatar
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    texts
                    Spacer(minLength: 6)
                    if let since {
                        Text("seit \(Formatting.time(since))")
                            .appFont(12).monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                    }
                }
                HStack(spacing: 0) {
                    texts
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .appFont(14.5, weight: .medium)
                .foregroundStyle(theme.textPrimary)
            Text(line)
                .appFont(13)
                .foregroundStyle(theme.accent)
                .contentTransition(.opacity)
        }
        .adaptiveLineLimit(1, large: 2, accessibility: 3)
    }
}

/// Runder Stopp-Knopf am Ende einer Zeile unter „Läuft gerade“.
private struct TodayStopButton: View {
    let label: String
    let action: () async -> Void
    @State private var stopping = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            stopping = true
            Task {
                await action()
                stopping = false
            }
        } label: {
            ZStack {
                if stopping {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stop.fill").appFont(11, weight: .bold).foregroundStyle(theme.textPrimary)
                }
            }
            .scaledFrame(32)
            .background(theme.circleButton, in: Circle())
            .overlay(Circle().strokeBorder(theme.surfaceBorder))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .help(label)
        .accessibilityLabel(label)
        .padding(.trailing, 12)
    }
}

// MARK: - 1. Wartet auf dich

/// Offene Freigabe: Kopf (wer fragt, in welchem Chat oder welcher Aufgabe; springt dorthin) und darunter dieselbe
/// Karte wie im Chat, mit denselben Aktionen.
struct TodayApprovalItem: View {
    let approval: TodayApproval
    /// Gerade entschieden: Die Karte zeigt noch kurz das Ergebnis
    var settled = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var botID: String { approval.botId ?? approval.message.meta.authorId ?? approval.chatId }
    private var bot: Bot? { store.bot(botID) }
    private var name: String { bot?.name ?? store.chatName(approval.chatId) }

    /// „im Chat“, „in Team“ oder „in der Aufgabe …“
    private var place: String {
        var parts: [String] = []
        if let title = approval.taskTitle, !title.isEmpty {
            parts.append(String(localized: "Aufgabe „\(title)“"))
        } else if approval.taskId != nil {
            parts.append(String(localized: "Aus einer Aufgabe"))
        }
        if ChatGroup.isGroupID(approval.chatId) {
            let group = store.chatName(approval.chatId)
            parts.append(String(localized: "in \(group)", comment: "Ort einer Freigabe: in einer Gruppe"))
        } else if parts.isEmpty {
            parts.append(String(localized: "im Chat"))
        }
        if let d = approval.createdAt { parts.append(Formatting.dayTime(d)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.openChatFromToday(approval.chatId, messageID: approval.message.id)
            } label: {
                HStack(spacing: 9) {
                    if let bot {
                        MascotView(mascot: bot.mascot, size: 28, seed: bot.id, animated: false)
                    } else {
                        ChatAvatar(chatID: approval.chatId, size: 28, animateWhenBusy: false)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(name) fragt")
                            .appFont(14, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text(place)
                            .appFont(12)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .adaptiveLineLimit(1, large: 2, accessibility: 3)
                    Image(systemName: "chevron.right")
                        .appFont(10, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(HoverButtonStyle(radius: 10))
            .help(ChatGroup.isGroupID(approval.chatId) ? "Zur Gruppe springen" : "Zum Chat springen")
            .accessibilityLabel("\(name) fragt, \(place)")
            .accessibilityHint("Springt zur Nachricht im Chat")

            // Dieselben Karten wie im Verlauf (Freigabe, Mail, Tresor, Verbesserung, sichere Eingabe)
            MessageRow(message: approval.message, chatID: approval.chatId)
        }
        .opacity(settled ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rückfrage einer Hintergrund-Aufgabe (keine Freigabe-Karte): Frage lesen, in der Aufgabe antworten.
struct TodayQuestionCard: View {
    let task: BotTask
    var onAnswer: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var bot: Bot? { store.bot(task.botId) }

    /// „Lio fragt“ bzw. „Ein Scoop fragt“
    private var asker: String {
        guard let name = bot?.name else { return String(localized: "Ein Scoop fragt") }
        return String(localized: "\(name) fragt")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.openChatFromToday(task.chatId, messageID: task.statusMessageId)
            } label: {
                HStack(spacing: 9) {
                    if let bot { MascotView(mascot: bot.mascot, size: 28, seed: bot.id, animated: false) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(asker)
                            .appFont(14, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text(place)
                            .appFont(12)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .adaptiveLineLimit(1, large: 2, accessibility: 3)
                    Image(systemName: "chevron.right")
                        .appFont(10, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(HoverButtonStyle(radius: 10))
            .accessibilityLabel("\(asker), \(place)")
            .accessibilityHint("Springt zur Aufgabe im Chat")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                        .appFont(13)
                        .foregroundStyle(theme.warning)
                        .scaledFrame(26)
                        .background(theme.warning.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rückfrage").appFont(11.5, weight: .medium).foregroundStyle(theme.textTertiary)
                        Text(task.title).appFont(15, weight: .semibold).foregroundStyle(theme.textPrimary)
                    }
                }
                if let question = task.waitingFor, !question.isEmpty {
                    Text(question)
                        .appFont(13.5)
                        .lineSpacing(2.5)
                        .foregroundStyle(theme.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.background.opacity(theme.kind == .nacht ? 0.7 : 1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button(action: onAnswer) { Text("Antworten").frame(minWidth: 90) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .themedCard(theme, radius: theme.bubbleRadius)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var place: String {
        var parts = [String(localized: "Aufgabe „\(task.title)“")]
        if ChatGroup.isGroupID(task.chatId) {
            let group = store.chatName(task.chatId)
            parts.append(String(localized: "in \(group)", comment: "Ort einer Freigabe: in einer Gruppe"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 3. Läuft gerade

/// Chat-Lauf: Scoop, letzte Statuszeile, Stopp. Antippen springt zur Statuskarte im Chat.
struct TodayRunRow: View {
    let run: TodayRun
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var botID: String { run.botId ?? run.chatId }
    private var name: String { store.bot(botID)?.name ?? store.chatName(run.chatId) }
    private var title: String {
        guard ChatGroup.isGroupID(run.chatId) else { return name }
        let group = store.chatName(run.chatId)
        return String(localized: "\(name) in \(group)", comment: "Scoop arbeitet in einer Gruppe")
    }

    var body: some View {
        let line = run.line ?? String(localized: "Arbeitet …")
        TodayRowButton(spoken: "\(title), \(line)") {
            store.openChatFromToday(run.chatId, messageID: run.messageId)
        } label: {
            TodayRunLayout(title: title, line: line, since: run.startedAt) {
                ChatAvatar(chatID: botID, size: 34, animateWhenBusy: false)
            }
        } trailing: {
            TodayStopButton(label: String(localized: "\(name) anhalten")) { await store.stop(chatID: run.chatId) }
        }
        .animation(.snappy(duration: 0.2), value: run.line)
    }
}

/// Hintergrund-Aufgabe, die arbeitet oder auf einen Platz wartet. Antippen öffnet die Aufgabe.
struct TodayRunningTaskRow: View {
    let task: BotTask
    var onOpen: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var bot: Bot? { store.bot(task.botId) }

    private var subtitle: String {
        var parts = [bot?.name ?? "Scoop", String(localized: "Aufgabe")]
        if task.state == "queued" {
            parts.append(String(localized: "wartet auf einen Platz"))
        } else if let note = task.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        TodayRowButton(spoken: "\(task.title), \(subtitle)", action: onOpen) {
            TodayRunLayout(title: task.title, line: subtitle, since: task.startedAt) {
                if let bot {
                    ChatAvatar(chatID: bot.id, size: 34, animateWhenBusy: false)
                } else {
                    Circle().fill(theme.hover).frame(width: 34, height: 34)
                }
            }
        } trailing: {
            TodayStopButton(label: String(localized: "Aufgabe „\(task.title)“ anhalten")) { await store.taskBoard.perform(task.id, .stop) }
        }
    }
}

// MARK: - 4. Heute geplant

/// Scoop, der die Arbeit macht, mit kleinem Abzeichen für die Art (Routine, Erinnerung, Aufgabe) unten rechts.
/// So erkennt man in „Heute geplant“ und „Seit gestern erledigt“ auf einen Blick, wer dran ist.
private struct TodayScoopIcon: View {
    let bot: Bot?
    let symbol: String
    let tint: Color
    @Environment(\.theme) private var theme
    @AppMetric private var size: CGFloat = 34

    var body: some View {
        Group {
            if let bot {
                ChatAvatar(chatID: bot.id, size: size, animateWhenBusy: false)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: symbol)
                            .font(.fixed(size * 0.27, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: size * 0.48, height: size * 0.48)
                            .background(theme.surface, in: Circle())
                            .background(tint.opacity(0.16), in: Circle())
                            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 1.5))
                            .offset(x: size * 0.1, y: size * 0.08)
                    }
            } else {
                // Scoop unbekannt (gelöscht, noch nicht geladen): wie bisher nur das Symbol der Art
                Image(systemName: symbol)
                    .appFont(14, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.13), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// Routine, Erinnerung oder geplante Aufgabe mit Uhrzeit und Scoop.
struct TodayPlannedRow: View {
    let item: TodayPlannedItem
    var action: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var bot: Bot? {
        switch item {
        case .routine(let r): store.bot(r.botId)
        case .task(let t): store.bot(t.botId)
        }
    }

    private var title: String {
        switch item { case .routine(let r): r.title; case .task(let t): t.title }
    }

    private var mode: ComposerMode {
        switch item {
        case .routine(let r): r.isReminder ? .reminder : .routine
        case .task: .task
        }
    }

    private var detail: String {
        var parts = [bot?.name ?? "Scoop", mode.title]
        if case .routine(let r) = item, let more = r.moreToday, more > 0 {
            parts.append(String(localized: "danach noch \(more)× heute", comment: "Weitere Läufe einer Routine heute"))
        }
        return parts.joined(separator: " · ")
    }

    private var time: String {
        item.date <= Date() ? String(localized: "gleich", comment: "Geplanter Lauf steht unmittelbar bevor") : Formatting.time(item.date)
    }

    var body: some View {
        TodayRowButton(spoken: "\(time), \(title), \(detail)", action: action) {
            HStack(spacing: 12) {
                TodayScoopIcon(bot: bot, symbol: mode.icon, tint: mode.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appFont(14.5, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(detail)
                        .appFont(13)
                        .foregroundStyle(theme.textSecondary)
                }
                .adaptiveLineLimit(1, large: 2, accessibility: 3)
                Spacer(minLength: 6)
                Text(time)
                    .appFont(14, weight: .semibold).monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(1)
            }
        } trailing: { EmptyView() }
    }
}

// MARK: - 5. Seit gestern erledigt

/// Chat mit ungelesenen Nachrichten.
struct TodayUnreadRow: View {
    let entry: AppStore.ChatEntry
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var preview: String {
        guard let m = entry.lastMessage else { return " " }
        if ChatGroup.isGroupID(entry.id), let author = store.bot(m.meta.authorId) { return "\(author.name): \(m.previewText)" }
        return m.previewText
    }

    var body: some View {
        let muted = store.isMuted(entry.id)
        let spoken = muted
            ? String(localized: "\(entry.name), stumm, \(entry.unread) ungelesen, \(preview)")
            : String(localized: "\(entry.name), \(entry.unread) ungelesen, \(preview)")
        TodayRowButton(spoken: spoken) {
            store.openChat(entry.id)
        } label: {
            HStack(spacing: 12) {
                ChatAvatar(chatID: entry.id, size: 34, animateWhenBusy: false)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .appFont(14.5, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        if muted { MutedBadge(size: 10) }
                    }
                    Text(preview)
                        .appFont(13)
                        .foregroundStyle(theme.textSecondary)
                }
                .adaptiveLineLimit(1, large: 2, accessibility: 3)
                Spacer(minLength: 6)
                Text(entry.unread == 1 ? "1 neu" : "\(entry.unread) neu")
                    .appFont(11.5, weight: .semibold).monospacedDigit()
                    .foregroundStyle(theme.textOnAccent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    // Stummer Chat: grau wie der Punkt in der Seitenleiste
                    .background(muted ? theme.textTertiary.opacity(0.7) : theme.unreadDot, in: Capsule())
            }
        } trailing: { EmptyView() }
    }
}

/// Abgenommene Aufgabe oder gelaufene Routine.
struct TodayDoneRow: View {
    let item: TodayDoneItem
    /// Seit dem letzten Besuch dazugekommen
    var isNew = false
    var action: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var bot: Bot? {
        switch item {
        case .task(let t): store.bot(t.botId)
        case .routine(let r): store.bot(r.botId)
        }
    }

    private var title: String {
        switch item { case .task(let t): t.title; case .routine(let r): r.title }
    }

    private var kind: String {
        switch item {
        case .task(let t): t.isRoutine ? String(localized: "Aufgabe aus Routine") : String(localized: "Aufgabe")
        case .routine(let r): r.isReminder ? String(localized: "Erinnerung") : String(localized: "Routine gelaufen")
        }
    }

    /// Art des Eintrags als Abzeichen am Scoop (Aufgabe aus einer Routine zeigt das Routinen-Symbol)
    private var badge: (String, Color) {
        switch item {
        case .task(let t): t.isRoutine ? (ComposerMode.routine.icon, ComposerMode.routine.color)
                                       : (ComposerMode.task.icon, ComposerMode.task.color)
        case .routine(let r): r.isReminder ? (ComposerMode.reminder.icon, ComposerMode.reminder.color)
                                           : (ComposerMode.routine.icon, ComposerMode.routine.color)
        }
    }

    /// Erledigte Aufgaben tragen rechts neben Tag und Uhrzeit ein grünes Häkchen
    private var isFinishedTask: Bool {
        if case .task = item { return true }
        return false
    }

    var body: some View {
        TodayRowButton(spoken: spoken, action: action) {
            HStack(spacing: 12) {
                TodayScoopIcon(bot: bot, symbol: badge.0, tint: badge.1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .appFont(14.5, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        if isNew { UnreadDot() }
                    }
                    Text("\(bot?.name ?? "Scoop") · \(kind)")
                        .appFont(13)
                        .foregroundStyle(theme.textSecondary)
                }
                .adaptiveLineLimit(1, large: 2, accessibility: 3)
                Spacer(minLength: 6)
                // In Bedienungshilfen-Größen steht das Häkchen unter der Uhrzeit, sonst nimmt es dem Titel die Breite
                let timeStack = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 6))
                timeStack {
                    Text(Formatting.dayTime(item.date))
                        .appFont(12).monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                        .adaptiveLineLimit(1)
                    if isFinishedTask {
                        Image(systemName: "checkmark.circle.fill")
                            .appFont(15, weight: .semibold)
                            .foregroundStyle(theme.success)
                            .accessibilityHidden(true)
                    }
                }
            }
        } trailing: { EmptyView() }
    }

    private var spoken: String {
        let base = "\(title), \(bot?.name ?? "Scoop"), \(kind), \(Formatting.dayTime(item.date))"
        return isNew ? String(localized: "\(base), neu", comment: "Vorlesetext: seit dem letzten Besuch dazugekommen") : base
    }
}

// MARK: - Eintrag in der Seitenleiste

/// Zähler der Seite „Heute“ (Widget in der Seitenleiste und Kopf der Seite). Farben und Symbole wie die Abschnitte.
enum TodayCounter: CaseIterable, Identifiable {
    case waiting, review, running, planned
    var id: Self { self }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .review: "eye.fill"
        case .running: "bolt.fill"
        case .planned: "calendar"
        }
    }

    @MainActor func tint(_ theme: Theme) -> Color {
        switch self {
        case .waiting: theme.warning
        case .review: ComposerMode.task.color
        case .running: theme.accent
        case .planned: ComposerMode.routine.color
        }
    }

    /// Kurz fürs Widget, ausführlich für den Kopf der Seite
    func label(long: Bool) -> String {
        switch self {
        case .waiting: long ? String(localized: "warten auf dich", comment: "Zähler Heute, nach der Zahl")
                            : String(localized: "warten", comment: "Zähler Heute (kurz), nach der Zahl")
        case .review: long ? String(localized: "zum Prüfen", comment: "Zähler Heute, nach der Zahl")
                           : String(localized: "prüfen", comment: "Zähler Heute (kurz), nach der Zahl")
        case .running: String(localized: "arbeiten", comment: "Zähler Heute, nach der Zahl")
        case .planned: long ? String(localized: "heute geplant", comment: "Zähler Heute, nach der Zahl")
                            : String(localized: "geplant", comment: "Zähler Heute (kurz), nach der Zahl")
        }
    }

    @MainActor func count(_ today: TodayStore) -> Int {
        switch self {
        case .waiting: today.waitingCount
        case .review: today.review.count
        case .running: today.runningCount
        case .planned: today.plannedCount
        }
    }

    /// Vorlesetext, z. B. „9 warten auf dich“
    @MainActor static func spoken(_ today: TodayStore) -> String {
        allCases.compactMap { c in
            let n = c.count(today)
            return n > 0 ? "\(n) \(c.label(long: true))" : nil
        }.joined(separator: ", ")
    }
}

/// Zähler-Kapsel: Symbol, Zahl und (wenn Platz ist) Bezeichnung
struct TodayCountChip: View {
    let counter: TodayCounter
    let count: Int
    var long = false
    var showsLabel = true
    var large = false
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = counter.tint(theme)
        HStack(spacing: large ? 6 : 4) {
            Image(systemName: counter.symbol).appFont(large ? 13 : 11, weight: .semibold).foregroundStyle(tint)
            Text("\(count)")
                .appFont(large ? 15 : 13, weight: .bold).monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())
            if showsLabel {
                Text(counter.label(long: long)).appFont(large ? 14 : 12.5, weight: .medium).foregroundStyle(theme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, large ? 12 : 9)
        .padding(.vertical, large ? 7 : 5)
        .background(tint.opacity(theme.colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(counter.label(long: true))")
    }
}

/// Fester Eintrag „Heute“ ganz oben in der Seitenleiste bzw. Chatliste: kleines Widget mit Datum und Zählern für
/// alles, was wartet, geprüft werden will, gerade arbeitet oder heute noch ansteht.
struct TodaySidebarRow: View {
    /// iPhone (Chatliste allein auf dem Bildschirm): etwas größer
    var standalone = false
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var today: TodayStore { store.today }

    /// In der Mitte zu sehen (iPad/Mac: kein Chat gewählt, kein Board)
    private var selected: Bool { !standalone && store.selectedChatID == nil && !store.showTaskBoard }

    private var counters: [(TodayCounter, Int)] {
        TodayCounter.allCases.map { ($0, $0.count(today)) }.filter { $0.1 > 0 }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button { store.openToday() } label: {
            VStack(alignment: .leading, spacing: standalone ? 9 : 8) {
                // „Heute“ und daneben das kurze Datum („Sa., 21. Nov.“)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Heute")
                        .appFont(standalone ? 21 : 17, weight: .bold)
                        .foregroundStyle(theme.textPrimary)
                    Text(today.clock.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Formatting.locale)))
                        .appFont(standalone ? 15 : 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                }
                .adaptiveLineLimit(1, large: 1, accessibility: 2)
                content
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .padding(standalone ? 14 : 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(theme.pinnedTile))
            .overlay { if selected { shape.strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5) } }
            .contentShape(shape)
        }
        .buttonStyle(HoverButtonStyle(radius: 18))
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.25), value: counters.map(\.1))
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if os(macOS)
        .help("Heute (⇧⌘H)")
        #endif
    }

    @ViewBuilder private var content: some View {
        if !today.loaded {
            Text("Freigaben und Aufgaben").appFont(standalone ? 15 : 13).foregroundStyle(theme.textSecondary)
        } else if counters.isEmpty {
            Text("Alles ruhig").appFont(standalone ? 15 : 13).foregroundStyle(theme.textSecondary)
        } else {
            // Immer eine Zeile: mit Bezeichnung, wenn sie passt, sonst nur Symbol und Zahl
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(counters, labels: true) }
                HStack(spacing: 6) { chips(counters, labels: false) }
                HStack(spacing: 4) { chips(counters, labels: false, small: true) }
            }
        }
    }

    private func chips(_ items: [(TodayCounter, Int)], labels: Bool, small: Bool = false) -> some View {
        ForEach(items, id: \.0) { counter, count in
            TodayCountChip(counter: counter, count: count, showsLabel: labels, large: standalone && !small)
        }
    }

    private var accessibilityText: String {
        guard today.loaded else { return String(localized: "Heute") }
        let detail = TodayCounter.spoken(today)
        return detail.isEmpty ? String(localized: "Heute, alles ruhig") : String(localized: "Heute, \(detail)")
    }
}
