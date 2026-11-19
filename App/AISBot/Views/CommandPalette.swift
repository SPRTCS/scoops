import SwiftUI

// MARK: - Modell

/// Ein Eintrag der Befehlspalette: Chat, Aktion oder Nachrichtentreffer.
struct PaletteItem: Identifiable {
    enum Icon {
        /// SF-Symbol in einer getönten Kachel
        case symbol(String, Color)
        /// Maskottchen bzw. Gruppenstapel eines Chats
        case chat(String)
    }

    let id: String
    var title: String
    /// Optional mit hervorgehobenem Treffer (Nachrichten)
    var attributedTitle: AttributedString?
    var subtitle: String?
    var icon: Icon
    var keywords: [String] = []
    /// Tastenkürzel als einzelne Tasten, z. B. ["⌘", "⇧", "N"]
    var shortcut: [String] = []
    var action: @MainActor () async -> Void
}

struct PaletteSection: Identifiable {
    let id: String
    var title: String
    var items: [PaletteItem]
}

/// Unscharfe Suche: Präfix > Wortanfang > Teilstring > Teilfolge (Buchstaben in Reihenfolge, Lücken kosten Punkte).
/// Groß-/Kleinschreibung und Umlaute/Akzente werden ignoriert („einstellungen“ findet „Einstellungen“, „uber“ „Über“).
enum Fuzzy {
    private static let locale = Locale(identifier: "de_DE")

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }

    /// Höher = besser, `nil` = kein Treffer. Beide Werte bereits gefaltet.
    static func score(_ q: String, in text: String) -> Int? {
        guard !q.isEmpty else { return 0 }
        if text.hasPrefix(q) { return 1000 - min(text.count, 200) }
        if let r = text.range(of: q) {
            let pos = text.distance(from: text.startIndex, to: r.lowerBound)
            let wordStart = !text[text.index(before: r.lowerBound)].isLetter
            return (wordStart ? 800 : 600) - min(pos, 150)
        }
        // Teilfolge (z. B. „nb“ → „Neuer Bereich“): ab zwei Zeichen und nur ab einem Wortanfang, sonst trifft fast alles
        guard q.count >= 2 else { return nil }
        let t = Array(text), qs = Array(q)
        func isWordStart(_ i: Int) -> Bool { i == 0 || !t[i - 1].isLetter }
        guard let first = t.indices.first(where: { t[$0] == qs[0] && isWordStart($0) }) else { return nil }
        var score = 320, last = first, ti = first + 1
        for c in qs.dropFirst() {
            guard let i = t[ti...].firstIndex(of: c) else { return nil }
            if isWordStart(i) { score += 14 }
            score += i == last + 1 ? 6 : -min(i - last, 12) * 4
            last = i
            ti = i + 1
        }
        return score >= 260 ? score : nil
    }

    /// Jedes Wort der Suche muss im Titel oder in einem Stichwort vorkommen (Stichwörter zählen weniger).
    static func match(_ query: String, title: String, keywords: [String]) -> Int? {
        let tokens = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let t = fold(title)
        let kws = keywords.map(fold)
        var total = 0
        for tok in tokens {
            var best = score(tok, in: t)
            for k in kws {
                // Gedeckelt: Ein Treffer im Titel („Neue Gruppe“) geht einem Stichwort-Präfix („gruppe“) immer vor
                if let s = score(tok, in: k) { best = max(best ?? .min, min(s, 640) - 120) }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }
}

// MARK: - Ansicht

/// Befehlspalette (⌘K) im Stil von Raycast/Linear: Suchfeld oben, darunter gruppierte Treffer mit Symbol,
/// Titel und Tastenkürzel. ↑/↓ (auch Tab/⇧Tab) wählt, Enter führt aus, Esc schließt. Liegt als Ebene über
/// dem ganzen Fenster (keine Präsentation), damit danach geöffnete Blätter nicht kollidieren.
struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var query = ""
    @State private var selection = 0
    @State private var contentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// iPhone (bzw. iPhone Duo zugeklappt): Stapel-Navigation, meist ohne Hardware-Tastatur
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        let sections = buildSections()
        let flat = sections.flatMap(\.items)
        ZStack(alignment: .top) {
            Color.black.opacity(theme.kind == .nacht ? 0.42 : 0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityLabel("Befehlspalette schließen")
                .accessibilityAddTraits(.isButton)

            card(sections: sections, flat: flat)
                .frame(maxWidth: compact ? .infinity : 640)
                .frame(maxHeight: compact ? .infinity : nil, alignment: .top)
                .padding(.horizontal, compact ? 10 : 24)
                .padding(.top, compact ? 6 : 84)
                .padding(.bottom, compact ? 10 : 24)
        }
        .onChange(of: query) { selection = 0 }
        .task {
            // Fokus erst nach dem Einblenden setzen (auf dem Mac sonst gelegentlich verschluckt)
            try? await Task.sleep(for: .milliseconds(40))
            fieldFocused = true
        }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }

    // MARK: Karte

    private func card(sections: [PaletteSection], flat: [PaletteItem]) -> some View {
        let selected = flat.indices.contains(selection) ? flat[selection].id : nil
        return VStack(spacing: 0) {
            searchField(flat: flat)
            Rectangle().fill(theme.surfaceBorder).frame(height: 1)
            if flat.isEmpty {
                emptyState
            } else {
                results(sections: sections, selectedID: selected)
            }
            if !compact {
                Rectangle().fill(theme.surfaceBorder).frame(height: 1)
                footer
            }
        }
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(theme.kind == .nacht ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(theme.kind == .nacht ? 0.55 : 0.16), radius: 40, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Befehlspalette")
    }

    private func searchField(flat: [PaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: compact ? 17 : 16, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            TextField("Suchen oder Befehl eingeben …", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 17 : 16.5))
                .foregroundStyle(theme.textPrimary)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .onSubmit { runSelected(flat) }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in move(1, count: flat.count) }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in move(-1, count: flat.count) }
                .onKeyPress(.return, phases: .down) { _ in runSelected(flat); return .handled }
                .onKeyPress(.escape, phases: .down) { _ in dismiss(); return .handled }
                .onKeyPress(.tab, phases: .down) { press in move(press.modifiers.contains(.shift) ? -1 : 1, count: flat.count) }
            if compact {
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)
            } else {
                KeyCaps(keys: ["esc"])
            }
        }
        .padding(.horizontal, 16)
        .frame(height: compact ? 54 : 56)
    }

    private func results(sections: [PaletteSection], selectedID: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            row(item, selected: item.id == selectedID)
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: compact ? .infinity : min(max(contentHeight, 60), 430))
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button { run(item) } label: {
            HStack(spacing: 11) {
                icon(item.icon, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        if let a = item.attributedTitle { Text(a) } else { Text(item.title) }
                    }
                    .font(.system(size: compact ? 16 : 14.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.system(size: compact ? 13.5 : 12))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !compact {
                    if !item.shortcut.isEmpty {
                        KeyCaps(keys: item.shortcut)
                    } else if selected {
                        KeyCaps(keys: ["↵"])
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: compact ? 52 : 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.selection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(radius: 10))
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon, selected: Bool) -> some View {
        let size: CGFloat = compact ? 32 : 26
        switch icon {
        case .chat(let id):
            ChatAvatar(chatID: id, size: size, animateWhenBusy: false)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(theme.kind == .nacht ? 0.17 : 0.12),
                            in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nichts gefunden")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("Versuch es mit einem Scoop-Namen oder einem Befehl wie „Tresor“.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .frame(maxHeight: compact ? .infinity : nil, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.top, compact ? 30 : 0)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                MascotView(mascot: .brand, size: 16, seed: "palette", animated: false)
                Text("AIS Scoops").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            hint(["↑", "↓"], "Auswählen")
            hint(["↵"], "Öffnen")
            hint(["esc"], "Schließen")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCaps(keys: keys)
            Text(label).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: Tastatur und Ausführen

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = ((selection + delta) % count + count) % count
        return .handled
    }

    private func runSelected(_ flat: [PaletteItem]) {
        guard flat.indices.contains(selection) else { return }
        run(flat[selection])
    }

    private func run(_ item: PaletteItem) {
        // Doppeltes Auslösen (Enter + onSubmit) abfangen
        guard store.showCommandPalette else { return }
        withAnimation(.snappy(duration: 0.18)) { store.showCommandPalette = false }
        Task {
            // Erst die Ebene schließen, dann Blatt/Fokus/Navigation
            try? await Task.sleep(for: .milliseconds(120))
            await item.action()
        }
    }

    private func dismiss() {
        guard store.showCommandPalette else { return }
        withAnimation(.snappy(duration: 0.18)) { store.showCommandPalette = false }
        #if os(macOS)
        store.composerFocusRequest += 1
        #endif
    }

    // MARK: Inhalte

    private func buildSections() -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chats = chatItems()
        let actions = actionItems()
        guard !q.isEmpty else {
            // Ohne Suche: zuletzt aktive Chats, dann alle Aktionen
            return [PaletteSection(id: "chats", title: "Chats", items: Array(chats.prefix(6))),
                    PaletteSection(id: "actions", title: "Aktionen", items: actions)]
                .filter { !$0.items.isEmpty }
        }
        func ranked(_ items: [PaletteItem]) -> [(PaletteItem, Int)] {
            items.compactMap { item in Fuzzy.match(q, title: item.title, keywords: item.keywords).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
        }
        var scored: [(PaletteSection, Int)] = []
        let rc = ranked(chats), ra = ranked(actions)
        if let best = rc.first?.1 { scored.append((PaletteSection(id: "chats", title: "Chats", items: rc.map(\.0)), best)) }
        if let best = ra.first?.1 { scored.append((PaletteSection(id: "actions", title: "Aktionen", items: ra.map(\.0)), best)) }
        // Bester Treffer oben, damit Enter sofort das Richtige tut
        var result = scored.sorted { $0.1 > $1.1 }.map(\.0)
        let messages = messageItems(q)
        if !messages.isEmpty {
            result.append(PaletteSection(id: "messages", title: "Nachrichten in geladenen Chats", items: messages))
        }
        return result
    }

    private func chatItems() -> [PaletteItem] {
        // Mit mir geteilte Scoops (andere Server)
        let shared = store.sharedBots.compactMap { b -> PaletteItem? in
            guard let share = store.share(for: b.id) else { return nil }
            let id = b.id
            return PaletteItem(id: "chat:\(id)", title: b.name, subtitle: "Geteilt von \(share.ownerName)", icon: .chat(id),
                               keywords: ["chat", "scoop", "geteilt", share.ownerName, b.label ?? ""]) { [store] in
                store.openChat(id)
            }
        }
        return store.allEntries.map { entry in
            var keywords = ["chat"]
            let subtitle: String
            switch entry {
            case .bot(let b):
                keywords += ["scoop", b.label ?? ""]
                subtitle = [b.label, b.primary ? "Haupt-Scoop" : nil].compactMap { $0 }.joined(separator: " · ")
            case .group(let g):
                let members = g.memberIds.compactMap { store.bot($0)?.name }
                keywords += ["gruppe"] + members
                subtitle = "Gruppe · " + members.joined(separator: ", ")
            }
            if let s = entry.section { keywords.append(s) }
            let id = entry.id
            return PaletteItem(id: "chat:\(id)", title: entry.name, subtitle: subtitle.isEmpty ? nil : subtitle,
                               icon: .chat(id), keywords: keywords) { [store] in
                store.openChat(id)
            }
        } + shared
    }

    private func actionItems() -> [PaletteItem] {
        let store = store
        let theme = theme
        let compact = compact
        var items: [PaletteItem] = []

        items.append(PaletteItem(id: "a:newbot", title: "Neuer Scoop", icon: .symbol("sparkles", theme.accent),
                                 keywords: ["anlegen", "erstellen", "bot", "neu"], shortcut: ["⌘", "N"]) {
            store.editingBot = nil
            store.showCreateBot = true
        })
        if store.bots.count >= 2 {
            items.append(PaletteItem(id: "a:newgroup", title: "Neue Gruppe", icon: .symbol("person.3.fill", theme.accent),
                                     keywords: ["gruppenchat", "anlegen", "erstellen", "team"], shortcut: ["⌘", "⇧", "N"]) {
                store.showCreateGroup = true
            })
        }
        items.append(PaletteItem(id: "a:newsection", title: "Neuer Bereich", subtitle: "Ordnet die Seitenleiste",
                                 icon: .symbol("rectangle.stack.badge.plus", theme.accent),
                                 keywords: ["bereich", "ordner", "section", "seitenleiste", "anlegen"]) {
            await Self.showSidebarIfNeeded(store, compact: compact)
            store.sectionPrompt = .create(moveChatID: nil)
        })
        if let bot = store.bot(store.selectedChatID) {
            items.append(PaletteItem(id: "a:look", title: "Aussehen von \(bot.name) bearbeiten",
                                     icon: .symbol("paintpalette.fill", Color(hex: "#FF5FA8")),
                                     keywords: ["aussehen", "maskottchen", "farbe", "form", "augen", "accessoire", "look"]) {
                store.editingBot = bot
                store.showCreateBot = true
            })
        }
        if store.selectedChatID != nil {
            items.append(PaletteItem(id: "a:inspector", title: store.showInspector ? "Profil ausblenden" : "Profil einblenden",
                                     icon: .symbol("sidebar.right", theme.textSecondary),
                                     keywords: ["profil", "inspector", "details", "gedächtnis", "bibliothek"],
                                     shortcut: ["⌘", "I"]) {
                store.showInspector.toggle()
            })
        }
        items.append(PaletteItem(id: "a:screen", title: "Bildschirm des Bot-Rechners öffnen",
                                 icon: .symbol("display", Color(hex: "#22BFAE")),
                                 keywords: ["computer", "rechner", "live", "übernehmen", "steuern", "screen"]) {
            store.showScreenViewer = true
        })
        let primary = store.primaryBot
        items.append(PaletteItem(id: "a:initiative", title: "Initiative: Jetzt prüfen lassen",
                                 subtitle: primary.map { "\($0.name) schaut sofort nach" } ?? "Erst einen Haupt-Scoop wählen",
                                 icon: .symbol("sparkle.magnifyingglass", theme.warning),
                                 keywords: ["initiative", "prüfen", "haupt-scoop", "melden", "jetzt"]) {
            if let primary {
                if await store.runInitiative() { store.showToast("\(primary.name) schaut nach …") }
            } else {
                store.showInitiative = true
            }
        })
        items.append(PaletteItem(id: "a:tasks", title: "Aufgaben", subtitle: "Board aller Scoops: geplant, in Arbeit, zu prüfen",
                                 icon: .symbol("checklist", ComposerMode.task.color),
                                 keywords: ["aufgaben", "board", "kanban", "tasks", "geplant", "prüfen", "hintergrund"]) {
            store.showTaskBoard = true
        })
        items.append(PaletteItem(id: "a:connections", title: "Apps verbinden", icon: .symbol("link", theme.accent),
                                 keywords: ["verbindungen", "gmail", "notion", "kalender", "konto", "composio", "apps"]) {
            store.showConnections = true
        })
        items.append(PaletteItem(id: "a:vault", title: "Tresor", icon: .symbol("lock.shield.fill", theme.success),
                                 keywords: ["passwörter", "logins", "zugangsdaten", "tresor", "vault"]) {
            store.showVault = true
        })
        items.append(PaletteItem(id: "a:settings", title: "Einstellungen", icon: .symbol("gearshape.fill", theme.textSecondary),
                                 keywords: ["optionen", "server", "verbindung", "app-symbol", "settings"], shortcut: ["⌘", ","]) {
            store.showSettings = true
        })
        if !compact {
            items.append(PaletteItem(id: "a:sidebar", title: store.sidebarHidden ? "Seitenleiste einblenden" : "Seitenleiste ausblenden",
                                     icon: .symbol("sidebar.left", theme.textSecondary),
                                     keywords: ["seitenleiste", "sidebar", "ein", "aus", "umschalten"], shortcut: ["⌃", "⌘", "S"]) {
                store.toggleSidebar()
            })
        }
        let toHell = store.theme == .nacht
        items.append(PaletteItem(id: "a:theme", title: toHell ? "Zu Hell wechseln" : "Zu Nacht wechseln",
                                 subtitle: "Erscheinungsbild: jetzt \(store.theme.displayName)",
                                 icon: .symbol(toHell ? "sun.max.fill" : "moon.fill", toHell ? theme.warning : Color(hex: "#8B5CF6")),
                                 keywords: ["theme", "erscheinungsbild", "hell", "nacht", "dunkel", "dark", "light", "modus"]) {
            withAnimation(.easeInOut(duration: 0.25)) { store.theme = toHell ? .hell : .nacht }
        })
        if store.appearance != .system {
            items.append(PaletteItem(id: "a:theme-system", title: "Erscheinungsbild wie System",
                                     subtitle: "Nacht bei Dunkelmodus, Hell bei Hellmodus des Geräts",
                                     icon: .symbol("circle.lefthalf.filled", theme.textSecondary),
                                     keywords: ["theme", "erscheinungsbild", "system", "automatisch", "dark", "light", "modus"]) {
                withAnimation(.easeInOut(duration: 0.25)) { store.appearance = .system }
            })
        }
        items.append(PaletteItem(id: "a:search", title: "Chats durchsuchen", subtitle: "Suche in der Seitenleiste",
                                 icon: .symbol("magnifyingglass", theme.textSecondary),
                                 keywords: ["suche", "suchen", "finden", "filter", "chat-suche"], shortcut: ["⌘", "F"]) {
            await Self.showSidebarIfNeeded(store, compact: compact)
            store.searchFocusRequest += 1
        })
        return items
    }

    /// Treffer in bereits geladenen Nachrichten (lokal, ohne Server-Suche). Neueste zuerst, höchstens 8.
    private func messageItems(_ q: String) -> [PaletteItem] {
        let tokens = Fuzzy.fold(q).split(whereSeparator: \.isWhitespace).map(String.init)
        guard q.count >= 2, !tokens.isEmpty else { return [] }
        var hits: [Message] = []
        for (chatID, list) in store.messages where store.chatExists(chatID) {
            for m in list where (m.role == .user || m.role == .bot) && !m.text.isEmpty {
                let folded = Fuzzy.fold(m.text)
                if tokens.allSatisfy({ folded.contains($0) }) { hits.append(m) }
            }
        }
        hits.sort { $0.createdAt > $1.createdAt }
        return hits.prefix(8).map { m in
            let author: String
            if m.role == .user { author = store.isOwnMessage(m) ? "Du" : store.authorName(of: m) } else { author = store.bot(m.meta.authorId ?? m.chatId)?.name ?? store.chatName(m.chatId) }
            let place = ChatGroup.isGroupID(m.chatId) ? "\(author) in \(store.chatName(m.chatId))" : author
            let chatID = m.chatId, messageID = m.id
            return PaletteItem(id: "msg:\(m.id)", title: m.text, attributedTitle: Self.snippet(m.text, highlight: tokens[0], theme: theme),
                               subtitle: "\(place) · \(Formatting.dayTime(m.createdAt))",
                               icon: m.role == .user ? .symbol("person.fill", theme.textSecondary) : .chat(m.meta.authorId ?? m.chatId)) { [store] in
                store.pendingScrollMessageID = messageID
                store.openChat(chatID)
            }
        }
    }

    /// Ausschnitt um den Treffer (eine Zeile), Treffer fett in Textfarbe.
    private static func snippet(_ text: String, highlight token: String, theme: Theme) -> AttributedString {
        let flat = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " ")
        var start = flat.startIndex
        if let r = flat.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]),
           flat.distance(from: flat.startIndex, to: r.lowerBound) > 28 {
            start = flat.index(r.lowerBound, offsetBy: -24)
            // An Wortgrenze beginnen
            if let space = flat[start..<r.lowerBound].firstIndex(of: " ") { start = flat.index(after: space) }
        }
        let shown = (start > flat.startIndex ? "…" : "") + String(flat[start...])
        var attr = AttributedString(shown)
        attr.foregroundColor = theme.textSecondary
        if let r = shown.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]),
           let lo = AttributedString.Index(r.lowerBound, within: attr), let hi = AttributedString.Index(r.upperBound, within: attr) {
            attr[lo..<hi].foregroundColor = theme.textPrimary
            attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }

    /// iPhone: Seitenleiste nach vorn holen (Bereich anlegen und Suche leben dort).
    private static func showSidebarIfNeeded(_ store: AppStore, compact: Bool) async {
        guard compact, store.selectedChatID != nil else { return }
        store.selectedChatID = nil
        try? await Task.sleep(for: .milliseconds(450))
    }
}

/// Tasten als kleine Kappen („⌘“ „⇧“ „N“), wie in Raycast/Linear.
struct KeyCaps: View {
    let keys: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 5 : 0)
                    .background(theme.kind == .nacht ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.surfaceBorder))
            }
        }
        .accessibilityHidden(true)
    }
}
