import SwiftUI

/// Seitenleiste: Suche, „+“, Einstellungen, angepinnte Kacheln, Abschnitte.
/// Seit Build 14 ohne Profilzeile unten: Sie zeigte nur Initiale und Namen, das Zahnrad steht jetzt in der Leiste
/// (Mac: Kopfzeile, iOS: Navigationsleiste), die Liste reicht bis zur Safe Area.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var botToDelete: Bot?
    @State private var groupToDelete: ChatGroup?
    @State private var sectionToDelete: String?
    @State private var sectionName = ""
    @State private var dropTarget: String?
    /// Seitenleiste allein auf dem Bildschirm (iPhone bzw. iPhone Duo zugeklappt, Stapel-Navigation).
    /// Bewusst nicht über die Size-Class: Die Seitenleisten-Spalte eines NavigationSplitView meldet auf
    /// iPad/Duo ebenfalls „compact“.
    var standalone = false

    /// Zeilenmaße: auf dem iPhone (kompakte Breite, auch iPhone Duo zugeklappt) deutlich größer.
    private struct RowMetrics {
        var avatar: CGFloat, title: CGFloat, preview: CGFloat, vertical: CGFloat, spacing: CGFloat, leading: CGFloat
    }
    private var metrics: RowMetrics {
        if standalone {
            return RowMetrics(avatar: 62, title: 19, preview: 16, vertical: 13, spacing: 14, leading: 14)
        }
        return RowMetrics(avatar: 38, title: 14.5, preview: 13, vertical: 7, spacing: 12, leading: 10)
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    #if os(iOS)
                    if !standalone { splitTitle }
                    #endif
                    // iPhone: Suchfeld immer sichtbar über der Chatliste (Scoops und Nachrichten); sonst über die Lupe
                    if searching || standalone { searchField.padding(.horizontal, 12).padding(.bottom, 10) }
                    // Seite „Heute“ (Freigaben-Postfach) als fester erster Eintrag; bei der Suche nur Scoops
                    if store.today.available, store.searchText.isEmpty {
                        TodaySidebarRow(standalone: standalone).padding(.bottom, standalone ? 4 : 8)
                    }
                    if !store.pinnedEntries.isEmpty { pinnedGrid }
                    ForEach(store.pendingChats) { pending in pendingRow(pending) }
                    ForEach(store.sections) { section in sectionBlock(section) }
                    if !store.sharedEntries.isEmpty { sharedSection }
                    if store.phase == .unconfigured, !store.sharedBots.isEmpty { ownServerHint }
                    if store.bots.isEmpty, store.sharedBots.isEmpty, store.phase == .online { emptyState }
                    // Ab zwei Zeichen übernimmt die Nachrichtensuche darunter den leeren Zustand
                    if !store.searchText.isEmpty, store.searchText.trimmingCharacters(in: .whitespaces).count < 2,
                       store.pinnedEntries.isEmpty, store.sections.isEmpty, store.sharedEntries.isEmpty,
                       !store.bots.isEmpty || !store.sharedBots.isEmpty {
                        Text("Kein Scoop gefunden")
                            .font(.callout).foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    // Treffer in Nachrichten aller Chats (App 1.3, Search/MessageSearchViews.swift)
                    if !store.searchText.isEmpty { SidebarMessageHits(large: standalone) }
                }
                .padding(.bottom, 12)
                // Leere Fläche unten: Rechtsklick / langes Drücken legt einen neuen Bereich an
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { store.sectionPrompt = .create(moveChatID: nil) } label: {
                            Label("Neuer Bereich", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
            }
            .scrollIndicators(.never)
            #if os(iOS)
            // Oben nur der weiche Scroll-Kanten-Effekt unter den Glas-Knöpfen (siehe `toolbarBackgroundVisibility`)
            .scrollEdgeEffectStyle(.soft, for: .top)
            #endif
            connectionBanner
        }
        // Hintergrund auch unter Tastatur und Safe Area, damit beim Tippen keine Ecke/Kante sichtbar wird
        .background { theme.sidebarBackground.ignoresSafeArea() }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Scoop löschen", role: .destructive) {
                if let b = botToDelete { Task { await store.deleteBot(b.id) } }
                botToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { botToDelete = nil }
        } message: {
            Text("Verlauf, Gedächtnis und Routinen werden ebenfalls gelöscht.")
        }
        .confirmationDialog("„\(groupToDelete?.name ?? "")“ löschen?",
                            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Gruppe löschen", role: .destructive) {
                if let g = groupToDelete { Task { await store.deleteGroup(g.id) } }
                groupToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { groupToDelete = nil }
        } message: {
            Text("Der Gruppenverlauf wird gelöscht. Die Scoops bleiben erhalten.")
        }
        .confirmationDialog("Bereich „\(sectionToDelete ?? "")“ löschen?",
                            isPresented: Binding(get: { sectionToDelete != nil }, set: { if !$0 { sectionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Bereich löschen", role: .destructive) {
                if let n = sectionToDelete { Task { await store.deleteSection(n) } }
                sectionToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { sectionToDelete = nil }
        } message: {
            Text("Die Scoops landen in „Ohne Bereich“.")
        }
        .alert(promptTitle, isPresented: Binding(get: { store.sectionPrompt != nil },
                                                 set: { if !$0 { store.sectionPrompt = nil } })) {
            TextField("Name des Bereichs", text: $sectionName)
            Button(promptAction) { submitPrompt() }
            Button("Abbrechen", role: .cancel) { store.sectionPrompt = nil }
        } message: {
            Text(promptMessage)
        }
        .onChange(of: store.sectionPrompt) { _, prompt in
            if case .rename(let name) = prompt { sectionName = name } else { sectionName = "" }
        }
        #if os(iOS)
        .onChange(of: searchFocused) { _, isFocused in store.keyboardVisible = isFocused }
        #endif
        .onChange(of: store.searchFocusRequest) {
            withAnimation(.snappy) { searching = true }
            searchFocused = true
        }
        #if os(iOS)
        .navigationTitle("Scoops")
        // Split-Seitenleiste (iPad, Duo aufgeklappt): Das System zeigt den Titel dort nur inline. Neben Suche,
        // Einstellungen, Neu und dem Seitenleisten-Knopf wurde er auf „S“ gekürzt; er steht deshalb als
        // Überschrift über der Liste (`splitTitle`). Das iPhone behält den großen System-Titel.
        .toolbar(removing: standalone ? nil : .title)
        // Build 15: keine Leisten-Fläche mehr. Mit `toolbarBackground(sidebarBackground)` blendete iOS nach dem
        // Wiederaufklappen des großen Titels eine Leisten-Fläche ein, die nicht bis an die Oberkante reichte (Streifen
        // in anderer Farbe darüber, iPhone Duo zugeklappt). Jetzt wie im Chat: nur Glas-Knöpfe und der weiche
        // Scroll-Kanten-Effekt, die Liste läuft darunter bis an den oberen Rand.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            // iPhone: Das Suchfeld steht immer über der Liste, die Lupe gibt es nur in der Split-Seitenleiste
            if !standalone {
                ToolbarItem(placement: .topBarLeading) {
                    Button { toggleSearch() } label: {
                        Label(searching ? "Suche schließen" : "Suchen", systemImage: searching ? "xmark" : "magnifyingglass")
                    }
                }
            }
            // Befehlspalette nur auf dem iPhone als eigener Knopf (iPad: ⌘K und „Befehle …“ im Neu-Menü;
            // ein dritter Knopf verdrängte dort den Titel „Scoops“).
            if standalone {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.showCommandPalette = true } label: {
                        Label("Befehle", systemImage: "command")
                    }
                }
            }
            // Einstellungen (seit Build 14 hier statt in der Profilzeile unten), in derselben Glas-Kapsel
            // wie Suche und Befehle.
            ToolbarItem(placement: .topBarLeading) {
                Button { store.showSettings = true } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                }
            }
            // „Tastatur schließen“, „Neu“, „Apps verbinden“ und „Aufgaben“ oben nur, wenn die Seitenleiste allein
            // sichtbar ist (iPhone). iPad: unten in der Seitenleiste (`SidebarActionBar`), Duo aufgeklappt: in der
            // senkrechten Leiste des Chats.
            if standalone {
                SystemBarItems(keyboardVisible: store.keyboardVisible)
            }
        }
        .modifier(SidebarActionBar(enabled: !standalone))
        #endif
    }

    // MARK: Mit mir geteilt

    @State private var shareToLeave: SharedScoop?
    @State private var sharedCollapsed = false

    /// Geteilte Scoops anderer (docs/sharing.md): Scoop, Admin, online/offline
    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { sharedCollapsed.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(9.5, weight: .bold)
                        .rotationEffect(.degrees(sharedCollapsed ? 0 : 90))
                        .scaledFrame(width: 12)
                    Text("Mit mir geteilt").appFont(12.5, weight: .semibold)
                    Image(systemName: "person.2.fill").appFont(10)
                    Spacer()
                }
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sharedCollapsed ? "Mit mir geteilt, eingeklappt" : "Mit mir geteilt")
            if !sharedCollapsed {
                ForEach(store.sharedEntries, id: \.bot.id) { entry in sharedRow(entry.bot, entry.share) }
            }
        }
        .padding(.bottom, 4)
        .confirmationDialog("Aus „\(shareToLeave?.botName ?? "")“ austreten?",
                            isPresented: Binding(get: { shareToLeave != nil }, set: { if !$0 { shareToLeave = nil } }),
                            titleVisibility: .visible) {
            Button("Austreten", role: .destructive) {
                if let share = shareToLeave {
                    Task { if let error = await store.leave(share) { store.errorMessage = error } }
                }
                shareToLeave = nil
            }
            Button("Abbrechen", role: .cancel) { shareToLeave = nil }
        } message: {
            if let owner = shareToLeave?.ownerName {
                Text("Zurück geht es nur mit einer neuen Einladung von \(owner).")
            } else {
                Text("Zurück geht es nur mit einer neuen Einladung vom Admin.")
            }
        }
    }

    private func sharedRow(_ bot: Bot, _ share: SharedScoop) -> some View {
        let selected = store.selectedChatID == bot.id
        let busy = store.isBusy(bot.id)
        let online = store.isGuestOnline(share)
        let m = metrics
        return Button { store.openChat(bot.id) } label: {
            HStack(spacing: m.spacing) {
                ChatAvatar(chatID: bot.id, size: m.avatar, animateWhenBusy: false)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(online ? theme.success : theme.textTertiary)
                            .frame(width: m.avatar * 0.24, height: m.avatar * 0.24)
                            .overlay(Circle().strokeBorder(theme.sidebarBackground, lineWidth: 2))
                            .offset(x: 1, y: 1)
                            .accessibilityHidden(true)
                    }
                VStack(alignment: .leading, spacing: m.title > 15 ? 3 : 2) {
                    HStack(spacing: 5) {
                        Text(bot.title)
                            .appFont(m.title, weight: m.title > 15 ? .semibold : .medium)
                            .foregroundStyle(theme.textPrimary)
                            .adaptiveLineLimit(1, large: 1, accessibility: 2)
                        if bot.isMuted { MutedBadge(size: m.title * 0.68) }
                    }
                    Group {
                        if busy {
                            Text("Arbeitet …").foregroundStyle(theme.accent)
                        } else if let last = bot.lastMessage {
                            Text(sharedPreview(last)).foregroundStyle(theme.textSecondary)
                        } else {
                            Text("von \(share.ownerName)").foregroundStyle(theme.textSecondary)
                        }
                    }
                    .appFont(m.preview)
                    .adaptiveLineLimit(1, large: 2, accessibility: 3)
                    Text("\(share.ownerFirstName) · \(online ? "online" : "offline")")
                        .appFont(m.preview - 2)
                        .foregroundStyle(theme.textTertiary)
                        .adaptiveLineLimit(1, large: 1, accessibility: 2)
                }
                Spacer(minLength: 4)
                if bot.unread > 0 { UnreadDot(muted: bot.isMuted) }
            }
            .padding(.leading, m.leading)
            .padding(.trailing, 10)
            .padding(.vertical, m.vertical)
            .background {
                if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.selection) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(radius: 14))
        .padding(.horizontal, 8)
        .contextMenu {
            Button {
                store.openChat(bot.id)
                store.showInspector = true
            } label: { Label("Profil", systemImage: "info.circle") }
            MuteMenu(chatID: bot.id, store: store)
            Divider()
            Button(role: .destructive) { shareToLeave = share } label: {
                Label("Austreten", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .accessibilityLabel(sharedAccessibility(bot, share, online: online))
    }

    private func sharedAccessibility(_ bot: Bot, _ share: SharedScoop, online: Bool) -> String {
        let status = online ? "online" : "offline"
        var parts = [String(localized: "\(bot.name), geteilt von \(share.ownerName), \(status)")]
        if bot.isMuted { parts.append(String(localized: "stumm", comment: "Bedienungshilfen: Chat ist stummgeschaltet")) }
        if bot.unread > 0 { parts.append(String(localized: "\(bot.unread) ungelesen")) }
        return parts.joined(separator: ", ")
    }

    private func sharedPreview(_ m: Message) -> String {
        if m.role == .user {
            return store.isOwnMessage(m) ? String(localized: "Du: \(m.previewText)") : "\(store.authorName(of: m)): \(m.previewText)"
        }
        return m.previewText
    }

    /// Nur geteilte Scoops, kein eigener Server: Hinweis auf den eigenen Server
    private var ownServerHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Eigene Scoops").appFont(13.5, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text("Für eigene Scoops brauchst du einen eigenen AIS-Scoops-Server auf deinem Mac.")
                .appFont(12.5).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Server verbinden") { store.showOwnServerSetup = true }
                .appFont(13, weight: .semibold).buttonStyle(.plain).foregroundStyle(theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(theme, radius: 12)
        .padding(.horizontal, 12).padding(.top, 14)
    }

    private var deleteTitle: String {
        let name = botToDelete?.name ?? ""
        return String(localized: "„\(name)“ löschen?")
    }

    // MARK: Kopfzeile

    @ViewBuilder
    private var topBar: some View {
        #if os(macOS)
        HStack(spacing: 10) {
            Spacer()
            searchToggle
            TaskBoardCircleButton()
            SettingsLink {
                CircleIconLabel(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Einstellungen (⌘,)")
            .accessibilityLabel("Einstellungen")
            Menu {
                NewChatMenuItems()
            } label: {
                CircleIconLabel(systemName: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Neuer Scoop (⌘N) oder neue Gruppe (⌘⇧N)")
            .accessibilityLabel("Neu")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(minHeight: 52)
        #else
        // iOS: Titel und Knöpfe stehen in der System-Navigationsleiste (siehe toolbar)
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Titel „Scoops“ in der Split-Seitenleiste (siehe `toolbar(removing:)`), scrollt mit der Liste.
    private var splitTitle: some View {
        Text("Scoops")
            .appFont(28, weight: .bold)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
    #endif

    private var searchToggle: some View {
        CircleIconButton(systemName: searching ? "xmark" : "magnifyingglass", help: String(localized: "Scoops und Nachrichten suchen (⇧⌘F)")) {
            toggleSearch()
        }
    }

    private func toggleSearch() {
        withAnimation(.snappy) {
            searching.toggle()
            if !searching { store.searchText = "" }
        }
        searchFocused = searching
    }

    private var searchField: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
            TextField("Scoops und Nachrichten suchen", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onKeyPress(.escape) {
                    withAnimation(.snappy) { searching = false; store.searchText = "" }
                    searchFocused = false
                    return .handled
                }
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.surfaceBorder))
    }

    // MARK: Angepinnt

    private var pinnedGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 6)], spacing: 6) {
            ForEach(store.pinnedEntries) { entry in
                let selected = store.selectedChatID == entry.id
                Button { store.openChat(entry.id) } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            ChatAvatar(chatID: entry.id, size: 58, animateWhenBusy: false, showsWaiting: true)
                            if entry.unread > 0 { UnreadDot(muted: store.isMuted(entry.id)).offset(x: 2, y: 4) }
                        }
                        // Stumm: durchgestrichene Glocke unten links (rechts sitzt die Krone des Haupt-Scoops)
                        .overlay(alignment: .bottomLeading) {
                            if store.isMuted(entry.id) {
                                MutedBadge(size: 10)
                                    .padding(4)
                                    .background(theme.sidebarBackground, in: Circle())
                                    .offset(x: -6, y: 2)
                            }
                        }
                        // Krone unten rechts neben dem Körper (überdeckt weder Gesicht noch Accessoire)
                        .overlay(alignment: .bottomTrailing) {
                            if entry.isPrimary { PrimaryBadge(size: 17).offset(x: 9, y: 1) }
                        }
                        Text(entry.name)
                            .appFont(12.5, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.selection)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(HoverButtonStyle(radius: 14))
                .contextMenu { menu(entry) }
                .accessibilityLabel(store.isMuted(entry.id) ? String(localized: "\(entry.name), angepinnt, stumm")
                                    : String(localized: "\(entry.name), angepinnt"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Bereiche

    private var promptTitle: String {
        if case .rename = store.sectionPrompt { return String(localized: "Bereich umbenennen") }
        return String(localized: "Neuer Bereich")
    }
    private var promptAction: String {
        if case .rename = store.sectionPrompt { return String(localized: "Umbenennen") }
        return String(localized: "Anlegen")
    }
    private var promptMessage: String {
        if case .create(let id?) = store.sectionPrompt {
            return String(localized: "„\(store.chatName(id))“ wird in den neuen Bereich verschoben.")
        }
        return String(localized: "Bereiche ordnen deine Scoops und Gruppen in der Seitenleiste, z. B. „Arbeit“ oder „Privat“.")
    }

    private func submitPrompt() {
        let prompt = store.sectionPrompt
        let name = sectionName
        store.sectionPrompt = nil
        Task {
            switch prompt {
            case .create(let moveID):
                if let created = await store.createSection(name), let moveID {
                    await store.move(chatID: moveID, toSection: created)
                }
            case .rename(let old):
                await store.renameSection(old, to: name)
            case nil:
                break
            }
        }
    }

    /// Bereich: Kopfzeile (einklappbar, Ziel zum Ablegen) und seine Zeilen.
    private func sectionBlock(_ section: AppStore.SectionGroup) -> some View {
        let targeted = dropTarget == section.id
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(section)
            if !section.collapsed {
                ForEach(section.entries) { entry in
                    let preview = dragPreview(entry)   // jetzt (im body) erzeugen, nicht erst beim Ziehen
                    row(entry)
                        .draggable(entry.id) { preview }
                }
                if section.entries.isEmpty {
                    Text(section.name == nil ? "Hierher ziehen, um aus dem Bereich zu nehmen" : "Scoops hierher ziehen")
                        .appFont(12.5)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.surfaceBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(.bottom, 4)
        .background {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5))
                    .padding(.horizontal, 6)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, into: section)
        } isTargeted: { on in
            if on { dropTarget = section.id } else if dropTarget == section.id { dropTarget = nil }
        }
        .animation(.snappy(duration: 0.2), value: section.collapsed)
    }

    /// Ablegen: Chat-IDs → in den Bereich verschieben; „section:Name“ → Bereich davor einsortieren.
    private func handleDrop(_ items: [String], into section: AppStore.SectionGroup) -> Bool {
        dropTarget = nil
        var handled = false
        for item in items {
            if item.hasPrefix("section:") {
                let name = String(item.dropFirst("section:".count))
                guard let target = section.name, name != target else { continue }
                Task { await store.moveSection(name, before: target) }
                handled = true
            } else if store.chatExists(item) {
                Task { await store.move(chatID: item, toSection: section.name) }
                handled = true
            }
        }
        return handled
    }

    private func sectionHeader(_ section: AppStore.SectionGroup) -> some View {
        Button {
            Task { await store.toggleCollapsed(section.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .appFont(9.5, weight: .bold)
                    .rotationEffect(.degrees(section.collapsed ? 0 : 90))
                    .scaledFrame(width: 12)
                Text(section.title)
                    .appFont(12.5, weight: .semibold)
                if section.collapsed && !section.entries.isEmpty {
                    Text("\(section.entries.count)")
                        .appFont(11, weight: .semibold)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.selection, in: Capsule())
                }
                Spacer()
            }
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.collapsed
                            ? String(localized: "Bereich \(section.title), eingeklappt, \(section.entries.count) Einträge")
                            : String(localized: "Bereich \(section.title)"))
        .accessibilityHint(section.collapsed ? "Ausklappen" : "Einklappen")
        .modifier(SectionDragModifier(name: section.name))
        .contextMenu { sectionMenu(section) }
    }

    @ViewBuilder
    private func sectionMenu(_ section: AppStore.SectionGroup) -> some View {
        if let name = section.name {
            Button { store.sectionPrompt = .rename(name) } label: { Label("Umbenennen", systemImage: "pencil") }
            let names = store.sectionNames
            Button { Task { await store.moveSection(name, by: -1) } } label: { Label("Nach oben", systemImage: "arrow.up") }
                .disabled(names.first == name)
            Button { Task { await store.moveSection(name, by: 1) } } label: { Label("Nach unten", systemImage: "arrow.down") }
                .disabled(names.last == name)
        }
        Button { Task { await store.toggleCollapsed(section.name) } } label: {
            Label(section.collapsed ? "Ausklappen" : "Einklappen",
                  systemImage: section.collapsed ? "chevron.down" : "chevron.right")
        }
        Button { store.sectionPrompt = .create(moveChatID: nil) } label: {
            Label("Neuer Bereich", systemImage: "rectangle.stack.badge.plus")
        }
        if let name = section.name {
            Divider()
            Button(role: .destructive) { sectionToDelete = name } label: { Label("Bereich löschen", systemImage: "trash") }
        }
    }

    /// Vorschau beim Ziehen: Avatar + Name. Wird außerhalb der Hierarchie (und außerhalb von `body`) gezeichnet,
    /// daher hier keine @Environment-Werte lesen: `DragPreview` bekommt alles als Werte.
    private func dragPreview(_ entry: AppStore.ChatEntry) -> some View {
        let members: [Bot]
        switch entry {
        case .bot(let b): members = [b]
        case .group(let g): members = g.memberIds.compactMap { id in store.bots.first { $0.id == id } }
        }
        return DragPreview(name: entry.name, members: members, isGroup: { if case .group = entry { true } else { false } }(),
                           theme: theme)
    }

    /// „Verschieben nach …“ für Scoops und Gruppen.
    @ViewBuilder
    private func moveMenu(_ chatID: String, current: String?) -> some View {
        Menu {
            ForEach(store.sectionNames, id: \.self) { name in
                Button {
                    Task { await store.move(chatID: chatID, toSection: name) }
                } label: {
                    if current == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Button {
                Task { await store.move(chatID: chatID, toSection: nil) }
            } label: {
                if current == nil { Label("Ohne Bereich", systemImage: "checkmark") } else { Text("Ohne Bereich") }
            }
            Divider()
            Button { store.sectionPrompt = .create(moveChatID: chatID) } label: {
                Label("Neuer Bereich …", systemImage: "rectangle.stack.badge.plus")
            }
        } label: {
            Label("Verschieben nach", systemImage: "folder")
        }
    }

    // MARK: Zeile

    private func row(_ entry: AppStore.ChatEntry) -> some View {
        let selected = store.selectedChatID == entry.id
        let busy = store.isBusy(entry.id)
        let m = metrics
        return Button { store.openChat(entry.id) } label: {
            HStack(spacing: m.spacing) {
                ChatAvatar(chatID: entry.id, size: m.avatar, animateWhenBusy: false, showsWaiting: true)
                VStack(alignment: .leading, spacing: m.title > 15 ? 3 : 2) {
                    HStack(spacing: 5) {
                        Text(title(entry))
                            .appFont(m.title, weight: m.title > 15 ? .semibold : .medium)
                            .foregroundStyle(theme.textPrimary)
                            .adaptiveLineLimit(1, large: 1, accessibility: 2)
                        // Mit anderen geteilt (Admin)
                        if case .bot(let b) = entry, b.isSharedByMe {
                            Image(systemName: "person.2.fill")
                                .appFont(m.title * 0.62)
                                .foregroundStyle(theme.textTertiary)
                                .accessibilityLabel("geteilt")
                        }
                        if store.isMuted(entry.id) { MutedBadge(size: m.title * 0.68) }
                    }
                    Group {
                        if busy, let line = busyLine(entry) {
                            Text(line).foregroundStyle(theme.accent)
                        } else {
                            Text(preview(entry)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .appFont(m.preview)
                    .adaptiveLineLimit(1, large: 2, accessibility: 3)
                }
                Spacer(minLength: 4)
                if entry.unread > 0 { UnreadDot(muted: store.isMuted(entry.id)) }
            }
            .padding(.leading, m.leading)
            .padding(.trailing, 10)
            .padding(.vertical, m.vertical)
            .background {
                if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.selection) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(radius: 14))
        .padding(.horizontal, 8)
        .contextMenu { menu(entry) }
        .accessibilityLabel(rowAccessibility(entry))
    }

    private func rowAccessibility(_ entry: AppStore.ChatEntry) -> String {
        var parts = [title(entry)]
        if store.isMuted(entry.id) { parts.append(String(localized: "stumm", comment: "Bedienungshilfen: Chat ist stummgeschaltet")) }
        if entry.unread > 0 { parts.append(String(localized: "\(entry.unread) ungelesen")) }
        return parts.joined(separator: ", ")
    }

    /// Platzhalter, bis der Server den neuen Scoop / die Gruppe bestätigt.
    private func pendingRow(_ pending: AppStore.PendingChat) -> some View {
        HStack(spacing: 12) {
            HatchingAvatar(mascot: pending.mascot, members: pending.memberIDs.compactMap { store.bot($0) }, size: metrics.avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.name)
                    .appFont(metrics.title, weight: metrics.title > 15 ? .semibold : .medium)
                    .foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(1, large: 1, accessibility: 2)
                Text(pending.mascot == nil ? "Gruppe wird erstellt …" : "Schlüpft gerade …")
                    .appFont(metrics.preview)
                    .foregroundStyle(theme.accent)
            }
            Spacer(minLength: 4)
            ProgressView().controlSize(.small)
        }
        .padding(.leading, metrics.leading)
        .padding(.trailing, 10)
        .padding(.vertical, metrics.vertical)
        .background(theme.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pending.name) wird erstellt")
    }

    private func title(_ entry: AppStore.ChatEntry) -> String {
        switch entry {
        case .bot(let b): b.title
        case .group(let g): g.name
        }
    }

    private func preview(_ entry: AppStore.ChatEntry) -> String {
        switch entry {
        case .bot(let b):
            if let m = b.lastMessage, m.role == .user, b.isSharedByMe, !store.isOwnMessage(m) {
                return "\(store.authorName(of: m)): \(m.previewText)"
            }
            return b.lastMessage?.previewText ?? (b.label ?? " ")
        case .group(let g):
            guard let m = g.lastMessage else {
                return g.memberIds.compactMap { store.bot($0)?.name }.joined(separator: ", ")
            }
            if let author = store.bot(m.meta.authorId) { return "\(author.name): \(m.previewText)" }
            if m.role == .user { return String(localized: "Du: \(m.previewText)") }
            return m.previewText
        }
    }

    private func busyLine(_ entry: AppStore.ChatEntry) -> String? {
        switch entry {
        case .bot(let b):
            return (store.isTyping(b.id) || b.busy) ? String(localized: "Arbeitet …") : nil
        case .group(let g):
            let names = (Set(g.busyIds).union(store.typing[g.id] ?? [])).compactMap { store.bot($0)?.name }.sorted()
            if names.isEmpty { return nil }
            if names.count == 1 { return String(localized: "\(names[0]) arbeitet …") }
            let list = names.joined(separator: ", ")
            return String(localized: "\(list) arbeiten …", comment: "Mehrere Scoops arbeiten, Namen mit Komma getrennt")
        }
    }

    @ViewBuilder
    private func menu(_ entry: AppStore.ChatEntry) -> some View {
        switch entry {
        case .bot(let b): botMenu(b)
        case .group(let g): groupMenu(g)
        }
    }

    @ViewBuilder
    private func groupMenu(_ g: ChatGroup) -> some View {
        Button {
            Task { await store.toggleGroupPinned(g) }
        } label: {
            Label(g.pinned ? "Lösen" : "Anheften", systemImage: g.pinned ? "pin.slash" : "pin")
        }
        Button {
            store.openChat(g.id)
            store.showInspector = true
        } label: {
            Label("Bearbeiten", systemImage: "pencil")
        }
        MuteMenu(chatID: g.id, store: store)
        moveMenu(g.id, current: g.trimmedSection)
        Divider()
        Button(role: .destructive) {
            groupToDelete = g
        } label: {
            Label("Löschen", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func botMenu(_ bot: Bot) -> some View {
        Button {
            Task { await store.togglePinned(bot) }
        } label: {
            Label(bot.pinned ? "Lösen" : "Anheften", systemImage: bot.pinned ? "pin.slash" : "pin")
        }
        Button {
            store.editingBot = bot
            store.showCreateBot = true
        } label: {
            Label("Aussehen ändern", systemImage: "paintbrush")
        }
        MuteMenu(chatID: bot.id, store: store)
        moveMenu(bot.id, current: bot.trimmedSection)
        if store.canExportTemplate(bot.id) {
            Button { store.exportTemplate(bot.id) } label: {
                Label("Als Vorlage exportieren …", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            botToDelete = bot
        } label: {
            Label("Löschen", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            MascotView(mascot: .brand, size: 72, seed: "app-icon")
            Text("Noch keine Scoops").font(.headline).foregroundStyle(theme.textPrimary)
            Text("Leg deinen ersten Scoop an. Er bekommt einen Namen, einen Charakter und ein eigenes Gedächtnis.")
                .font(.callout).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            Button("Neuer Scoop") { store.editingBot = nil; store.showCreateBot = true }
                .buttonStyle(.borderedProminent).tint(theme.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: Verbindung

    @ViewBuilder
    private var connectionBanner: some View {
        switch store.phase {
        case .offline(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(theme.warning)
                    Text(message).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    Button("Neu versuchen") { Task { await store.retry() } }
                    Button(store.settings.usesAccount ? "Anderen Server wählen" : "Einstellungen") {
                        if store.settings.usesAccount { store.showServerSwitcher = true } else { store.showSettings = true }
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(theme.accent)
                .padding(.leading, 26)
            }
            .padding(10)
            .themedCard(theme, radius: 12)
            .padding(.horizontal, 12).padding(.bottom, 6)
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(store.settings.cloudServerName.map { name in String(localized: "Verbinde mit \(name) …") }
                     ?? String(localized: "Verbinde …"))
                    .font(.caption).foregroundStyle(theme.textSecondary).adaptiveLineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 6)
        case .online:
            if case .reconnecting = store.socketState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Verbinde neu …").font(.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button("Neu versuchen") { store.reconnectEventsNow() }
                        .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 20).padding(.bottom, 6)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Kleine Bausteine

struct UnreadDot: View {
    /// Stummer Chat: Der Punkt bleibt, aber dezent (grau statt Akzent)
    var muted = false
    @Environment(\.theme) private var theme
    var body: some View {
        Circle().fill(muted ? theme.textTertiary.opacity(0.7) : theme.unreadDot).frame(width: 8, height: 8)
            .accessibilityLabel("Ungelesen")
    }
}

struct CircleIconLabel: View {
    var systemName: String
    var size: CGFloat = 34
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: systemName)
            .font(.fixed(size * 0.42, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .frame(width: size, height: size)
            .background(theme.circleButton, in: Circle())
            .overlay(Circle().strokeBorder(theme.surfaceBorder))
            .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius / 2, y: 1)
            .contentShape(Circle())
    }
}

struct CircleIconButton: View {
    var systemName: String
    var help: String
    var size: CGFloat = 34
    var action: () -> Void

    /// Hilfe/Bedienungshilfen-Text als übersetzbarer Text (Literale landen im String Catalog).
    init(systemName: String, help: LocalizedStringResource, size: CGFloat = 34, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = String(localized: help); self.size = size; self.action = action
    }

    /// Hilfe-Text als fertiger Text.
    @_disfavoredOverload
    init(systemName: String, help: String, size: CGFloat = 34, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.size = size; self.action = action
    }

    var body: some View {
        Button(action: action) { CircleIconLabel(systemName: systemName, size: size) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Dezente Hover-Hervorhebung (Mac/iPad mit Zeiger) und Druck-Feedback.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .background {
                    if hovering || configuration.isPressed {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.hover)
                    }
                }
                .onHover { hovering = $0 }
        }
    }
}

/// Bereichs-Kopfzeile ziehbar machen (zum Umsortieren); „Ohne Bereich“ bleibt fest.
private struct SectionDragModifier: ViewModifier {
    let name: String?
    func body(content: Content) -> some View {
        if let name {
            content.draggable("section:\(name)")
        } else {
            content
        }
    }
}

/// Vorschau beim Ziehen (nur Werte, keine Umgebung nötig).
private struct DragPreview: View {
    let name: String
    let members: [Bot]
    let isGroup: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            if isGroup {
                GroupAvatar(members: members, size: 28)
            } else if let b = members.first {
                MascotView(mascot: b.mascot, size: 28, seed: b.id, animated: false)
            }
            Text(name).appFont(13.5, weight: .semibold).foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.surfaceRaised, in: Capsule())
        .environment(\.theme, theme)
    }
}
