import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Eingabe-Kapsel: „+“ (Anhänge, Vorlagen), mehrzeiliges Textfeld, rechts Diktat / Sprachmodus / Senden / Stopp.
/// Mac/Hardware-Tastatur: Return sendet, ⇧Return fügt eine neue Zeile ein.
struct ComposerView: View {
    let chatID: String
    @Binding var text: String
    /// Antwort auf eine bestimmte Nachricht (Leiste über dem Eingabefeld, v1.15)
    @Binding var replyTo: ReplyRef?
    let attachments: AttachmentQueue
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showPlus = false
    @State private var dictation = Dictation()
    @State private var dictationBase = ""
    /// Server-Erkennung läuft („Wird genau erkannt …“)
    @State private var refining = false
    /// Mit ↑/↓ gewählter Vorschlag der @-Liste (startet beim ersten Treffer)
    @State private var mentionIndex = 0
    /// Position des „@“, dessen Liste per Esc geschlossen wurde (Text bleibt unverändert)
    @State private var mentionDismissedAt: Int?
    /// Gewählter Modus (Aufgabe, Routine, Erinnerung, Gedächtnis) als Chip vor dem Text
    @State private var mode: ComposerMode?
    /// Aufgaben-Chip: geplanter Start (`nil` = jetzt) und Modell (`nil` = wie Scoop)
    @State private var taskDate: Date?
    /// Aufgaben-Chip: nur sammeln (Spalte „Offen“)
    @State private var taskBacklog = false
    @State private var taskModel: String?
    /// v1.29: Bereich am Mac für die Aufgabe (`nil` = wie Scoop)
    @State private var taskAccess: TaskAccessChoice?

    private var isGroup: Bool { ChatGroup.isGroupID(chatID) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { store.isBusy(chatID) }
    private var hasContent: Bool { !trimmed.isEmpty || !attachments.fileIDs.isEmpty }
    private var canSend: Bool { (hasContent || mode?.sendsEmpty == true) && !attachments.isUploading }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !mentionSuggestions.isEmpty { mentionList }
            if !attachments.isEmpty { AttachmentChips(queue: attachments) }
            if refining { RefiningHint() }
            if let replyTo {
                ReplyComposerBar(ref: replyTo, chatID: chatID) { self.replyTo = nil }
            }
            inputRow
        }
        .animation(.snappy(duration: 0.18), value: mode)
        .animation(.snappy(duration: 0.22), value: replyTo?.id)
        // Antwort gewählt (Wischen, Kontextmenü): Eingabefeld fokussieren, auch auf dem iPhone
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { attachments.add(fileURL: url, chatID: chatID, store: store) }
            }
        }
        // Neue Trefferliste → Auswahl wieder beim ersten Treffer
        .onChange(of: mentionSuggestions) { mentionIndex = 0 }
        // Erwähnung beendet (Leerzeichen, gelöscht …) → Esc-Sperre aufheben
        .onChange(of: mentionAnchor) { _, anchor in if anchor == nil { mentionDismissedAt = nil } }
        .onChange(of: dictation.transcript) { _, partial in
            guard dictation.isRecording else { return }
            text = combined(partial)
        }
        .task {
            // Nur Demo/Screenshots: Plus-Menü geöffnet zeigen (`-plusmenu`)
            if store.isMock, ProcessInfo.processInfo.arguments.contains("-plusmenu") {
                try? await Task.sleep(for: .milliseconds(900))
                showPlus = true
            }
        }
        .onDisappear {
            dictation.stop()
            store.keyboardVisible = false
        }
        #if os(iOS)
        // Fokus im Eingabefeld = Bildschirmtastatur sichtbar → „Tastatur schließen“ in der Systemleiste
        .onChange(of: focused) { _, isFocused in store.keyboardVisible = isFocused }
        #endif
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            plusMenu
                .padding(.bottom, 1)

            // Modus-Chip (und bei Aufgaben Start/Modell) als eigene Zeile im Eingabefeld, Text darunter in voller
            // Breite. Vorher stand der Chip in der Textzeile (Grundlinie eines mehrzeiligen TextFields ist unter iOS
            // unzuverlässig: Chip zu hoch, Leiste verzerrt) und die Aufgaben-Optionen als Zeile über dem Feld.
            VStack(alignment: .leading, spacing: 4) {
            if let mode {
                modeRow(mode)
                    .padding(.top, 4)
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            }
            TextField(mode?.placeholder ?? "Nachricht an \(store.chatName(chatID))", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .focused($focused)
                .onSubmit(submit)
                .padding(.vertical, 6)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                        return .handled
                    }
                    // Offene @-Liste: Enter übernimmt den gewählten Scoop und sendet nicht
                    if let name = selectedMention {
                        insertMention(name)
                        return .handled
                    }
                    send()
                    return .handled
                }
                // @-Liste per Tastatur (Mac, iPad/iPhone mit Hardware-Tastatur). Ohne Liste bleiben die Tasten
                // beim Textfeld (Cursor bewegen, Fokus wechseln, …).
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in moveMention(1) }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in moveMention(-1) }
                .onKeyPress(.tab, phases: .down) { press in
                    guard let name = selectedMention, !press.modifiers.contains(.shift) else { return .ignored }
                    insertMention(name)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    guard !mentionSuggestions.isEmpty else {
                        // Esc bricht eine Antwort ab
                        guard replyTo != nil else { return .ignored }
                        replyTo = nil
                        return .handled
                    }
                    mentionDismissedAt = mentionAnchor
                    return .handled
                }
                #if os(macOS)
                .onKeyPress(characters: ["v"], phases: .down) { press in
                    // ⌘V mit Bild in der Zwischenablage → als Anhang einfügen
                    guard press.modifiers.contains(.command) else { return .ignored }
                    return pasteImageIfAvailable() ? .handled : .ignored
                }
                #endif
                // Rückschritt im leeren Feld entfernt den Modus (wie bei ChatGPT)
                .onKeyPress(.delete, phases: .down) { _ in
                    guard text.isEmpty, mode != nil else { return .ignored }
                    withAnimation(.snappy(duration: 0.18)) { mode = nil }
                    return .handled
                }
            }
            .animation(.snappy(duration: 0.18), value: mode)

            trailingButtons
                .padding(.bottom, 1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        // Ganze Kapsel als Tippfläche: Leerraum fokussiert das Textfeld (Knöpfe behalten ihre eigenen Aktionen)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.surfaceRaised)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture { focused = true }
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(dictation.isRecording ? theme.danger.opacity(0.6) : theme.surfaceBorder))
        .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius, y: theme.cardShadowY)
        #if os(macOS)
        // Auf dem Mac direkt lostippen; auf dem iPhone soll die Tastatur nicht den Verlauf verdecken.
        .onAppear { focused = true }
        .onChange(of: chatID) { focused = true }
        .onChange(of: store.composerFocusRequest) { focused = true }
        #endif
    }

    /// Plus-Menü als kompakte Karte (statt Standard-Kontextmenü): Anhänge oben, Vorlagen darunter.
    private var plusMenu: some View {
        Button { showPlus.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(theme.hover, in: Circle())
                .rotationEffect(.degrees(showPlus ? 45 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Anhängen und Vorlagen")
        .accessibilityLabel("Anhängen")
        .animation(.snappy(duration: 0.2), value: showPlus)
        .popover(isPresented: $showPlus, attachmentAnchor: .rect(.bounds), arrowEdge: Self.plusArrowEdge) {
            PlusMenuCard(items: plusItems) { item in
                showPlus = false
                // Erst nach dem Schließen des Popovers die nächste Ansicht zeigen
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    item.action()
                }
            }
            .environment(\.theme, theme)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(theme.surfaceRaised)
            #endif
        }
    }

    /// Karte über dem Plus-Knopf: macOS und iOS deuten `arrowEdge` unterschiedlich.
    #if os(macOS)
    private static let plusArrowEdge: Edge = .top
    #else
    private static let plusArrowEdge: Edge = .bottom
    #endif

    private var plusItems: [PlusMenuCard.Item] {
        [
            .init(title: "Dateien anhängen", icon: "paperclip") { showFiles = true },
            .init(title: "Fotos anhängen", icon: "photo.on.rectangle") { showPhotos = true },
        ] + ComposerMode.allCases.filter { $0 != .task || !isGroup }.map { m in
            .init(title: m.menuTitle, icon: m.icon, group: 1, tint: m.color) { choose(m) }
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if dictation.isRecording {
            roundButton("stop.fill", fill: theme.danger, icon: .white, help: "Diktat beenden") { stopDictation() }
        } else if canSend {
            roundButton("arrow.up", fill: theme.sendButton, icon: theme.sendButtonIcon, help: "Senden (Return)", action: send)
                .accessibilityLabel("Senden")
        } else if hasContent && attachments.isUploading {
            ProgressView().controlSize(.small).frame(width: 30, height: 30)
        } else if busy {
            roundButton("stop.fill", fill: theme.sendButton, icon: theme.sendButtonIcon, help: "Stoppen") {
                Task { await store.stop(chatID: chatID) }
            }
            .accessibilityLabel("Stoppen")
        } else {
            HStack(spacing: 4) {
                Button { startDictation() } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Diktieren")
                .accessibilityLabel("Diktieren")
                if !isGroup {
                    roundButton("waveform", fill: theme.sendButton, icon: theme.sendButtonIcon, help: "Sprachmodus") {
                        dictation.stop()
                        store.voiceChatID = chatID
                    }
                    .accessibilityLabel("Sprachmodus starten")
                }
            }
        }
    }

    private func roundButton(_ symbol: String, fill: Color, icon: Color, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 11 : 14, weight: .bold))
                .foregroundStyle(icon)
                .frame(width: 30, height: 30)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Erwähnungen

    /// Aktuelles „@…“-Wort am Ende des Textes (beliebig viele Erwähnungen pro Nachricht).
    private var mentionQuery: String? {
        // Gruppen (Scoops) und geteilte Scoops (Personen, „@Johanna“)
        guard isGroup || !store.people(in: chatID).isEmpty else { return nil }
        return Self.mentionQuery(in: text)
    }

    /// Text nach dem letzten „@“, wenn dieses am Ende des Textes noch getippt wird. Trennt an jedem
    /// Leerraum (auch geschütztes Leerzeichen und Zeilenumbruch, die die iOS-Tastatur einfügen kann)
    /// und erlaubt Satzzeichen direkt davor („…,@Lio“, „(@Mila“).
    nonisolated static func mentionQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let query = text[text.index(after: at)...]
        guard query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            // „name@domain“ ist eine Mailadresse, keine Erwähnung
            guard before.isWhitespace || before.isPunctuation || before.isSymbol else { return nil }
        }
        return String(query)
    }

    /// Position (Zeichen ab Textanfang) des „@“ der gerade getippten Erwähnung.
    private var mentionAnchor: Int? {
        guard mentionQuery != nil, let at = text.lastIndex(of: "@") else { return nil }
        return text.distance(from: text.startIndex, to: at)
    }

    private var mentionSuggestions: [String] {
        guard let q = mentionQuery else { return [] }
        // Per Esc geschlossen: erst beim nächsten „@“ wieder anzeigen
        if let dismissed = mentionDismissedAt, dismissed == mentionAnchor { return [] }
        // Geteilter Scoop: auch Personen („@Johanna“ = nur an sie, der Scoop antwortet nicht)
        let names = store.members(of: chatID).map(\.name) + store.people(in: chatID) + ["alle"]
        let hits = q.isEmpty ? names : names.filter { $0.lowercased().hasPrefix(q.lowercased()) }
        // Vollständig getippte Erwähnung nicht mehr vorschlagen
        if hits.count == 1, hits[0].lowercased() == q.lowercased() { return [] }
        return hits
    }

    /// Gewählter Vorschlag (nil, wenn keine Liste offen ist).
    private var selectedMention: String? {
        let list = mentionSuggestions
        guard !list.isEmpty else { return nil }
        return list.indices.contains(mentionIndex) ? list[mentionIndex] : list[0]
    }

    /// ↑/↓ in der offenen Liste, umlaufend.
    private func moveMention(_ delta: Int) -> KeyPress.Result {
        let count = mentionSuggestions.count
        guard count > 0 else { return .ignored }
        mentionIndex = ((mentionIndex + delta) % count + count) % count
        return .handled
    }

    private var mentionList: some View {
        let selected = selectedMention
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(mentionSuggestions, id: \.self) { name in
                let isSelected = name == selected
                Button { insertMention(name) } label: {
                    HStack(spacing: 8) {
                        if let bot = store.members(of: chatID).first(where: { $0.name == name }) {
                            MascotView(mascot: bot.mascot, size: 24, seed: bot.id, animated: false)
                        } else if name != "alle" {
                            // Person im geteilten Scoop
                            PersonAvatar(name: name, size: 24)
                        } else {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.accent)
                                .frame(width: 24, height: 24)
                        }
                        Text("@\(name)").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.textPrimary)
                        if name == "alle" {
                            Text(isGroup ? "alle Scoops der Gruppe" : "alle im Chat").font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        } else if !isGroup, store.members(of: chatID).first(where: { $0.name == name }) == nil {
                            Text("nur an diese Person").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                        #if os(macOS)
                        if isSelected { KeyCaps(keys: ["↵"]) }
                        #endif
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(radius: 10))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(maxWidth: 300)
        .themedCard(theme, radius: 14, fill: theme.surfaceRaised)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func insertMention(_ name: String) {
        guard let q = mentionQuery else { return }
        // In einem Schritt zuweisen: Zwei Änderungen hintereinander (erst kürzen, dann anhängen) übernimmt das
        // Mac-Textfeld während eines Tastendrucks nur teilweise („@@alle“).
        var updated = text
        updated.removeLast(q.count + 1)
        updated += "@\(name) "
        text = updated
        focused = true
    }

    /// Return im Textfeld (auch über `onSubmit`): Bei offener @-Liste wird übernommen, nicht gesendet.
    private func submit() {
        if let name = selectedMention {
            insertMention(name)
        } else {
            send()
        }
    }

    // MARK: Aktionen

    /// Modus aus dem Plus-Menü: Chip setzen, alte Vorlagen-Texte aus dem Feld nehmen, fokussieren.
    private func choose(_ m: ComposerMode) {
        if let parsed = ComposerMode.parse(text) { text = parsed.rest }
        withAnimation(.snappy(duration: 0.18)) { mode = m }
        focused = true
    }

    /// Zeile im Eingabefeld: Modus-Chip, bei Aufgaben dazu Start und Modell (gehen strukturiert an den Server).
    /// Bricht auf schmalen Bildschirmen um.
    private func modeRow(_ mode: ComposerMode) -> some View {
        TaskFlowLayout(spacing: 6, lineSpacing: 6) {
            ComposerModeChip(mode: mode) { withAnimation(.snappy(duration: 0.18)) { self.mode = nil } }
            if mode == .task {
                TaskSchedulePill(date: $taskDate, backlog: $taskBacklog)
                TaskModelMenu(model: $taskModel, scoopModel: store.bot(chatID)?.model, pill: true)
                if let bot = store.bot(chatID), bot.computerAccess != nil {
                    TaskScopeMenu(choice: $taskAccess, bot: bot, pill: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .task ? "Aufgabe mit Start, Modell und Bereich" : "Modus \(mode.title)")
    }

    private func send() {
        guard canSend else { return }
        let value = mode?.compose(trimmed) ?? trimmed
        let options = mode == .task ? TaskOptions(model: taskModel, scheduledAt: taskBacklog ? nil : taskDate,
                                                  backlog: taskBacklog ? true : nil, access: taskAccess) : nil
        mode = nil
        taskDate = nil
        taskBacklog = false
        taskModel = nil
        taskAccess = nil
        let ids = attachments.fileIDs
        let reply = replyTo
        dictation.stop()
        text = ""
        replyTo = nil
        attachments.reset()
        Task { await store.send(value, to: chatID, fileIDs: ids, replyTo: reply, taskOptions: options) }
    }

    private func combined(_ dictated: String) -> String {
        dictationBase.isEmpty ? dictated : dictationBase + " " + dictated
    }

    private func startDictation() {
        dictationBase = trimmed
        Task {
            if let error = await dictation.start(continuous: true) {
                store.errorMessage = error
            }
        }
    }

    /// Diktat beenden: Gerätetext bleibt stehen, die Aufnahme wird auf dem Server genau erkannt und ersetzt dann
    /// den diktierten Teil (Text vor dem Diktat bleibt). Bei Fehlern bleibt der Gerätetext.
    private func stopDictation() {
        let onDevice = dictation.transcript
        dictation.stop()
        focused = true
        guard let recording = dictation.lastRecording else { return }
        let expected = combined(onDevice)
        refining = true
        Task {
            let precise = await store.transcribe(recording)
            refining = false
            if let precise, text.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines) {
                text = combined(precise)
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for (idx, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
                .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ",", with: "")
            let name = "Foto-\(stamp)\(items.count > 1 ? "-\(idx + 1)" : "").\(ext)"
            attachments.add(data: data, name: name, mime: type.preferredMIMEType ?? "image/jpeg", chatID: chatID, store: store)
        }
        photoItems = []
    }

    #if os(macOS)
    /// Bild aus der Zwischenablage anhängen. Gibt false zurück, wenn dort nur Text liegt.
    private func pasteImageIfAvailable() -> Bool {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) != nil, pb.data(forType: .png) == nil, pb.data(forType: .tiff) == nil { return false }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { attachments.add(fileURL: url, chatID: chatID, store: store) }
            return true
        }
        if let png = pb.data(forType: .png) {
            attachments.add(data: png, name: "Eingefügtes Bild.png", mime: "image/png", chatID: chatID, store: store)
            return true
        }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            attachments.add(data: png, name: "Eingefügtes Bild.png", mime: "image/png", chatID: chatID, store: store)
            return true
        }
        return false
    }
    #endif
}

/// Dezenter Hinweis mit Schimmer, während der Server genau erkennt.
struct RefiningHint: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
            Label("Wird genau erkannt …", systemImage: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: max(0, phase - 0.2)),
                                           .init(color: theme.textPrimary.opacity(0.9), location: phase),
                                           .init(color: .clear, location: min(1, phase + 0.2))],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(Label("Wird genau erkannt …", systemImage: "waveform").font(.system(size: 12, weight: .medium)))
                }
        }
        .padding(.leading, 10)
        .transition(.opacity)
        .accessibilityLabel("Wird genau erkannt")
    }
}

/// Kompakte Karte des Plus-Menüs: Zeilen mit Symbol links und Text, Gruppen durch feine Linie getrennt.
struct PlusMenuCard: View {
    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var icon: String
        var group = 0
        /// Modusfarbe (Aufgabe, Routine …): Symbol farbig und fett wie der Chip
        var tint: Color?
        var action: () -> Void
    }

    let items: [Item]
    var onSelect: (Item) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0, items[idx - 1].group != item.group {
                    Rectangle().fill(theme.surfaceBorder).frame(height: 0.5)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                }
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: item.tint == nil ? .regular : .semibold))
                            .foregroundStyle(item.tint ?? theme.textSecondary)
                            .frame(width: 22)
                        Text(item.title)
                            .font(.system(size: 16))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlusRowStyle())
            }
        }
        .padding(6)
        .frame(width: 270)
        #if os(macOS)
        .background(theme.surfaceRaised)
        #endif
    }
}

/// Zeile im Plus-Menü: dezente Hervorhebung beim Drücken bzw. Überfahren (Mac).
private struct PlusRowStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
    }
}
