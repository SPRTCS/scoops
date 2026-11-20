import SwiftUI
import UniformTypeIdentifiers

/// Chat mit einem Scoop oder einer Gruppe: Verlauf, Zeitstempel, Ereignisse, Status, Freigaben, Eingabe.
struct ChatView: View {
    let chatID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = ScrollPosition(edge: .bottom)
    /// Startposition steht (unten bzw. bei der ersten ungelesenen Nachricht). Vorher bleibt der Verlauf unsichtbar,
    /// statt sichtbar zu springen – siehe `openTranscript()`.
    @State private var positioned = false
    /// Ungelesen-Zähler beim Öffnen (gemerkt, bevor `chatBecameVisible` ihn auf 0 setzt)
    @State private var openedUnread: Int?
    /// Nachrichten lagen beim Öffnen schon vor (Chatwechsel); `nil` bis zum Öffnen (`captureOpening`)
    @State private var cachedAtOpen: Bool?
    /// Laden ist durch, auch ohne Ergebnis (keine Verbindung): dann wie bisher den leeren Verlauf zeigen
    @State private var loadFinished = false
    /// Trenner „Neu“ vor dieser Nachricht (erste ungelesene beim Öffnen)
    @State private var unreadAnchorID: String?
    /// Laden dauert länger: dezente Ladeanzeige statt leerem Verlauf
    @State private var slowLoad = false
    @State private var dropTargeted = false
    /// Verlauf steht am Ende (für das Nachrücken nach Breitenänderungen)
    @State private var atBottom = true
    /// Kurz hervorgehobene Nachricht (Sprung aus der Befehlspalette)
    @State private var flashedID: String?
    /// Nachrücken ans Ende nach Breitenwechseln (gedrosselt)
    @State private var widthSettle: Task<Void, Never>?
    /// Scroll-Zustand ohne Beobachtung (ändert sich pro Bild, soll den Chat nicht neu auswerten)
    @State private var scrollState = TranscriptScrollState()
    /// Hochgescrollt (weiter als `awayDistance` vom Ende): Zum-Ende-Knopf zeigen, neue Nachrichten nur zählen
    @State private var awayFromEnd = false
    /// Neue Nachrichten, die eingetroffen sind, während man hochgescrollt hatte (Zahl am Zum-Ende-Knopf)
    @State private var unseenCount = 0
    /// Suche in diesem Chat (Leiste unter dem Chat-Kopf, ⌘F)
    @State private var find = ChatFindState()

    /// Ab diesem Abstand zum Ende gilt der Verlauf als hochgescrollt (etwa ein Drittel eines iPhone-Bildschirms)
    private static let awayDistance: CGFloat = 260
    /// Der Chat zeigt nur einen Ausschnitt (Sprung zu einer älteren Fundstelle), neuere Nachrichten sind nicht geladen
    private var detached: Bool { store.detachedChats.contains(chatID) }

    private var isGroup: Bool { ChatGroup.isGroupID(chatID) }
    /// Geteilter Scoop (mit mir geteilt oder von mir geteilt): über jeder Nachrichtengruppe steht, von wem sie ist
    private var isShared: Bool { store.share(for: chatID) != nil || store.bot(chatID)?.isSharedByMe == true }
    /// Entwurf (Text und Anhänge) liegt im Store, nicht als `@State`: Die Ansicht wird bei App-Wechsel bzw.
    /// Size-Class-Wechsel und beim Chatwechsel neu aufgebaut, der Entwurf soll das überstehen.
    private var draft: ComposerDraft { store.composerDraft(chatID) }
    private var attachments: AttachmentQueue { draft.attachments }
    private var messages: [Message] { store.messages[chatID] ?? [] }
    /// Nachrichten liegen vor (geladen oder schon im Speicher)
    private var loaded: Bool { store.messages[chatID] != nil || loadFinished }
    /// Ungelesen laut Store. Wird beim Erscheinen auf 0 gesetzt, deshalb danach `openedUnread`.
    private var unreadCount: Int { openedUnread ?? store.bot(chatID)?.unread ?? store.group(chatID)?.unread ?? 0 }
    /// Verlauf sichtbar: Startposition steht – oder die Nachrichten lagen beim Öffnen schon vor und es gibt nichts
    /// Ungelesenes. Dann stimmt schon das erste Bild (`defaultScrollAnchor(…, for: .initialOffset)`), kein Ausblenden.
    private var transcriptShown: Bool {
        // Sprung zu einer Fundstelle: erst zeigen, wenn die Nachricht in der Mitte steht (siehe `openTranscript`)
        positioned || (cachedAtOpen != false && loaded && unreadCount == 0 && store.pendingScrollMessageID == nil)
    }

    var body: some View {
        let _ = PerfLog.chatBody(chatID)
        ZStack {
            theme.background.ignoresSafeArea()
            if store.chatExists(chatID) {
                // Feste Breite während das Profil bzw. die Seitenleiste ein-/ausfährt (siehe `ColumnTransitionStabilizer`)
                ColumnTransitionStabilizer(minimumWidth: theme.contentMaxWidth + 72) {
                    // Eingabe UNTER dem Verlauf statt als `safeAreaInset`: Tastatur und wachsendes Eingabefeld
                    // ändern so nur die Höhe des ScrollViews, nie seinen unteren Inset. Inset-Änderungen am Ende
                    // verrechnet die Verankerung (`defaultScrollAnchor(.bottomLeading, for: .sizeChanges)`) falsch:
                    // Sie setzt den Versatz um den GANZEN neuen Inset hinter das Ende (gemessen beim Zeilenumbruch:
                    // 1601 bei Maximum 1185, Sichtbereich 326 pt – der Verlauf ist leer), und auch
                    // `scrollTo(edge: .bottom)` zielt um den unteren Inset zu weit. Höhenänderungen des Containers
                    // rechnet die Verankerung dagegen richtig: Das Ende bleibt am Ende, ein hochgescrollter Verlauf
                    // bleibt stehen. Der untere Inset ist deshalb 0 (auch kein unterer Content-Rand).
                    VStack(spacing: 0) {
                        // Den ScrollView erst anlegen, wenn die Nachrichten da sind: Ein leerer ScrollView verbraucht
                        // seine Startposition (`.initialOffset`) am leeren Inhalt, die nachgeladenen Nachrichten
                        // standen dann oben bzw. mittendrin und das Nachrücken ans Ende war sichtbar (Build 15).
                        if loaded {
                            transcript
                                .opacity(transcriptShown ? 1 : 0)
                                .animation(.easeOut(duration: 0.15), value: transcriptShown)
                                .accessibilityHidden(!transcriptShown)
                                .overlay(alignment: .bottom) {
                                    // Weicher Übergang zur Eingabe (vorher lief der Verlauf unter ihren Schleier). Nur so
                                    // hoch wie der Abstand unter der letzten Zeile, damit am Ende nichts verdeckt wird.
                                    LinearGradient(colors: [theme.background.opacity(0), theme.background],
                                                   startPoint: .top, endPoint: .bottom)
                                        .frame(height: 8)
                                        .allowsHitTesting(false)
                                }
                                // Zum-Ende-Knopf: schwebt unten rechts im Verlauf, also immer über Eingabefeld,
                                // Anhängen, Antwort-Leiste und Tastatur (die liegen unter dem Verlauf, siehe oben)
                                .overlay(alignment: .bottomTrailing) {
                                    if positioned, awayFromEnd || detached {
                                        ScrollToEndButton(unseen: unseenCount) { jumpToEnd() }
                                            .padding(.trailing, 16)
                                            .padding(.bottom, 12)
                                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                                    }
                                }
                                .animation(.snappy(duration: 0.2), value: awayFromEnd || detached)
                                .overlay(alignment: .top) {
                                    if find.active {
                                        ChatFindBar(chatID: chatID, find: find, onShow: showFindHit, onClose: closeFind)
                                            .transition(.move(edge: .top).combined(with: .opacity))
                                    }
                                }
                                .animation(.snappy(duration: 0.2), value: find.active)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay { if slowLoad { ProgressView().controlSize(.small) } }
                        }
                        Group {
                            // Geteilter Scoop mit Rolle „Lesen“: kein Eingabefeld, nur ein Hinweis
                            if store.canWrite(chatID) {
                                ComposerView(chatID: chatID, text: Bindable(draft).text, replyTo: Bindable(draft).replyTo,
                                             attachments: attachments)
                            } else {
                                ReadOnlyComposerHint(chatID: chatID)
                            }
                        }
                            .frame(maxWidth: theme.contentMaxWidth + 40)
                            .padding(.horizontal, 16)
                            // iPhone/iPad: knapp über dem Home-Balken (der sichere Bereich hält den Abstand selbst);
                            // vorher 14 pt zusätzlich, das Feld saß sichtbar zu hoch. Mit Tastatur etwas Luft.
                            #if os(iOS)
                            .padding(.bottom, store.keyboardVisible ? 8 : 2)
                            #else
                            .padding(.bottom, 14)
                            #endif
                            .padding(.top, 6)
                            .frame(maxWidth: .infinity)
                    }
                }
                #if os(macOS)
                // Eigene View: Nur die Kopfzeile hängt an `showInspector`, nicht der ganze Chat.
                // `safeAreaBar` statt `safeAreaInset`: Der Verlauf läuft unter Pille und Knopf bis an den oberen
                // Rand, das System legt nur den dezenten Scroll-Kanten-Effekt darunter (keine deckende Fläche).
                .safeAreaBar(edge: .top, spacing: 0) { ChatMacHeader(chatID: chatID) }
                #endif
            } else {
                ContentUnavailableView("Chat nicht gefunden", systemImage: "questionmark.circle")
            }
            if dropTargeted { dropOverlay }
        }
        // Dateien per Drag & Drop anhängen (Mac, iPad)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL { attachments.add(fileURL: url, chatID: chatID, store: store) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        #if os(iOS)
        .modifier(ChatHeaderBar(chatID: chatID))
        #endif
        .task(id: chatID) {
            await openTranscript()
            if isGroup { await store.loadFiles(chatID: chatID) } else { await store.loadProfile(botID: chatID) }
            // Nur Demo/Screenshots: zu einer Nachricht scrollen (`-scrollto <id>`)
            let args = ProcessInfo.processInfo.arguments
            if store.isMock, let i = args.firstIndex(of: "-scrollto"), args.indices.contains(i + 1) {
                try? await Task.sleep(for: .milliseconds(300))
                position.scrollTo(id: args[i + 1], anchor: .top)
            }
            // Nur Demo/Screenshots: Antwort-Leiste auf die letzte Scoop-Nachricht (`-replydemo`) bzw. Sprung zum
            // Original eines Zitats mit Hervorhebung (`-replyjump <id>`)
            if store.isMock, args.contains("-replydemo"), draft.replyTo == nil,
               let target = messages.last(where: { $0.role == .bot && store.canReply(to: $0) }) {
                store.startReply(to: target)
            }
            if store.isMock, let i = args.firstIndex(of: "-replyjump"), args.indices.contains(i + 1) {
                try? await Task.sleep(for: .milliseconds(600))
                await store.jumpToMessage(args[i + 1], chatID: chatID)
            }
            await scrollToPendingMessage()
        }
        .onChange(of: store.pendingScrollMessageID) { _, id in
            // Treffer im bereits offenen Chat
            if id != nil, positioned { Task { await scrollToPendingMessage() } }
        }
        .onAppear {
            PerfLog.chatAppeared(chatID)
            // Vor `chatBecameVisible` merken: Das setzt den Zähler auf 0 und meldet „gelesen“ an den Server.
            captureOpening()
            store.chatBecameVisible(chatID)
            // Nur Demo/Screenshots: Beispiel-Anhänge in der Eingabe
            if store.isMock, ProcessInfo.processInfo.arguments.contains("-attachdemo"), attachments.isEmpty {
                let logo = LibraryFile(id: "demo-logo", chatId: chatID, authorId: nil, kind: "bild", name: "Logo.png",
                                       mime: "image/png", size: nil, url: nil, note: nil, createdAt: nil, downloadUrl: nil)
                let pdf = LibraryFile(id: "demo-pdf", chatId: chatID, authorId: nil, kind: "datei", name: demoText("Angebot-Q1.pdf", en: "Quote-Q1.pdf"),
                                      mime: "application/pdf", size: nil, url: nil, note: nil, createdAt: nil, downloadUrl: nil)
                attachments.add(data: MockFiles.content(for: logo), name: logo.name, mime: "image/png", chatID: chatID, store: store)
                attachments.add(data: MockFiles.content(for: pdf), name: pdf.name, mime: "application/pdf", chatID: chatID, store: store)
                draft.text = demoText("Kannst du das Angebot prüfen? @", en: "Can you review the quote? @")
            }
            #if DEBUG
            // Nur Debug-Builds: echten Upload mit einem erzeugten Testbild prüfen (`-uploadtest`)
            if ProcessInfo.processInfo.arguments.contains("-uploadtest"), attachments.isEmpty {
                let probe = LibraryFile(id: "probe", chatId: chatID, authorId: nil, kind: "bild", name: "Testbild.png",
                                        mime: "image/png", size: nil, url: nil, note: nil, createdAt: nil, downloadUrl: nil)
                attachments.add(data: MockFiles.content(for: probe), name: "AIS-Scoops-Testbild.png", mime: "image/png",
                                chatID: chatID, store: store)
            }
            #endif
        }
        .onDisappear {
            store.chatBecameHidden(chatID)
            store.leaveDetachedWindow(chatID)
        }
        .onChange(of: chatID) { old, new in
            store.chatBecameHidden(old)
            store.leaveDetachedWindow(old)
            store.chatBecameVisible(new)
            find.close()
            awayFromEnd = false
            unseenCount = 0
            // Entwürfe bleiben pro Chat im Store erhalten (siehe `draft`)
        }
        .onChange(of: store.chatFindRequest) { _, _ in
            // Knopf im Chat-Kopf bzw. ⌘F: Suchleiste zeigen (noch einmal = wieder schließen)
            if find.active { closeFind() } else { find.active = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.chatBecameVisible(chatID) }
        }
        .onChange(of: messages.last?.id) { _, _ in
            // Nicht beim Laden: Die Startposition setzt `openTranscript()` ohne Animation.
            guard positioned else { return }
            followNewMessage()
        }
        .onChange(of: store.keyboardVisible) { _, visible in
            // Tastatur verkleinert den sichtbaren Bereich. Am Ende hält die Verankerung den Verlauf am Ende; das
            // Nachrücken ist nur eine Absicherung. Ein hochgescrollter Verlauf bleibt, wo er ist.
            guard visible, atBottom else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if atBottom { position.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: store.isTyping(chatID)) { _, typing in
            // Hochgescrollt bzw. im Ausschnitt bleibt der Verlauf stehen
            if typing, positioned, !awayFromEnd, !detached {
                withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
            }
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Zum Anhängen loslassen", systemImage: "paperclip")
                    .appFont(15, weight: .semibold)
                    .foregroundStyle(theme.accent)
            }
            .padding(14)
            .allowsHitTesting(false)
    }


    private var transcript: some View {
        // Nur senkrecht scrollen; waagerecht bleibt die Spalte fest (keine Verschiebung beim Ein-/Ausblenden der
        // Tastatur oder durch die senkrechte Systemleiste des iPhone Duo).
        ScrollView(.vertical) {
            TranscriptStack {
                if store.hasMoreHistory[chatID] == true {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 36)
                        .onAppear { Task { await store.loadOlderMessages(chatID: chatID) } }
                        .chatColumn(theme.contentMaxWidth)
                }
                if loaded && messages.isEmpty {
                    emptyChat.chatColumn(theme.contentMaxWidth)
                }
                let runs = StatusRow.RunRole.roles(in: messages, chatID: chatID)
                ForEach(ChatItem.build(messages, unreadBefore: unreadAnchorID)) { item in
                    switch item {
                    case .unread:
                        UnreadDivider(count: openedUnread ?? 0)
                            .chatColumn(theme.contentMaxWidth)
                    case .stamp(let date, _):
                        Text(Formatting.dayTime(date))
                            .appFont(12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                            .chatColumn(theme.contentMaxWidth)
                    case .message(let m, let grouped):
                        MessageRow(message: m, chatID: chatID, showsAuthor: (isGroup || isShared) && !grouped,
                                   speaker: speakers[m.meta.authorId ?? chatID]
                                       ?? m.meta.authorId.flatMap { store.bot($0)?.speaker },
                                   run: runs[m.id] ?? .finished)
                            .equatable()
                            // Nach links wischen = antworten (v1.15)
                            .replySwipe(m)
                            .padding(.top, grouped ? -4 : 0)
                            .chatColumn(theme.contentMaxWidth)
                            .background {
                                if flashedID == m.id || (find.active && find.current?.messageId == m.id) {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(theme.accent.opacity(0.10))
                                        .frame(maxWidth: theme.contentMaxWidth + 24)
                                        .padding(.vertical, -4)
                                        .transition(.opacity)
                                }
                            }
                    }
                }
                // Ausschnitt (Sprung zu einer älteren Fundstelle): neuere Nachrichten erst auf Wunsch
                if detached {
                    NewerMessagesRow { await loadNewer() }.chatColumn(theme.contentMaxWidth)
                }
                // Animation nur für die Tipp-Blasen, nicht für das Layout der ganzen Spalte
                // (sonst „springt“ die Spalte beim ersten Anzeigen, z. B. nach einem Widget-Link).
                VStack(spacing: 10) {
                    ForEach(detached ? [] : typingBubbleMembers) { bot in
                        TypingBubble(bot: bot, showsName: isGroup)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.smooth(duration: 0.25), value: typingBubbleMembers.map(\.id))
                // Abstand zur Eingabe als Teil der letzten Zeile statt als unterer Content-Rand: Jeder untere Inset
                // wird von `scrollTo(edge: .bottom)` und der Verankerung doppelt gerechnet (siehe `transcript`).
                .padding(.bottom, 8)
                .chatColumn(theme.contentMaxWidth)
            }
            // Weder Spaltenbreite noch seitlicher Rand am Stapel selbst: Jede Zeile ist volle Breite (linke
            // Kante immer bei x = 0) und setzt Rand und Spalte erst innen – siehe `chatColumn`. Oben/unten als
            // Content-Margins statt Padding, damit auch das senkrechte Verankern nicht um den Rand springt.
            .frame(maxWidth: .infinity)
            .transaction { if !positioned { $0.animation = nil } }
        }
        // Oben: Der ScrollView reicht bis an den Bildschirm- bzw. Fensterrand (unter Kopf-Pille und Knöpfe), die
        // Höhe der Kopfzeile kommt als oberer Safe-Area-Inset dazu. Ganz nach oben gescrollt steht die erste
        // Nachricht deshalb frei unter der Pille, darüber noch 16 pt.
        .contentMargins(.top, 16, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollPosition($position)
        // Größenänderungen (Seitenleiste auf/zu, Drehen, Duo auf-/zuklappen, Tastatur): SwiftUI richtet dabei
        // das Anker-Ziel (eine Zeile) mit seiner linken Kante an der linken Sichtkante aus und scrollt dafür
        // auch WAAGERECHT, obwohl der Verlauf nur senkrecht scrollt. Lag die linke Kante der Zeilen nicht bei
        // x = 0 (mittige 560-pt-Spalte bzw. 16 pt Rand), blieb der Verlauf um genau diesen Betrag (137 bzw.
        // 16 pt) verschoben – „Nachrichten kleben am linken Rand“. Deshalb ist jede Zeile volle Breite ab x = 0
        // und setzt Rand und Spalte erst innen (`chatColumn`).
        .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
        .defaultScrollAnchor(.bottomLeading, for: .sizeChanges)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.automatic)
        // Am Ende bleiben, wenn sich die Breite ändert (Seitenleiste, Drehen, Duo): Das eingebaute Verankern
        // verrechnet dabei die unteren Insets (Eingabefeld) doppelt und ließ eine leere Fläche über der Eingabe.
        .onScrollGeometryChange(for: Bool.self) { g in
            // sichtbarer Bereich ohne den Streifen unter dem Eingabefeld
            g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 24
        } action: { _, bottom in atBottom = bottom }
        // Hochgescrollt? Nur eine Bewegung (Finger, Mausrad, Sprung zu einer Nachricht) entfernt vom Ende; wächst der
        // Inhalt in Ruhe (neue Nachricht, während man unten steht), folgt der Verlauf wie bisher.
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height - (g.visibleRect.maxY - g.contentInsets.bottom) > Self.awayDistance
        } action: { _, far in
            #if DEBUG
            ScrollLog.note("far from end \(far), idle \(scrollState.idle), positioned \(positioned)")
            #endif
            if !far {
                awayFromEnd = false
                unseenCount = 0
            } else if !scrollState.idle, positioned {
                awayFromEnd = true
            }
        }
        // Unterer Inset ändert sich (seit Build 14 eigentlich nie: Eingabe und Tastatur liegen unter dem Verlauf, der
        // untere Inset ist 0). Bleibt als Absicherung: Am Ende setzt die Verankerung den Versatz bei jeder Änderung
        // des unteren Insets um den GANZEN neuen Inset hinter das Ende (Build 13 gemessen beim Zeilenumbruch: 1601
        // bei Maximum 1185, Sichtbereich 326 pt, Inset 416 pt – leerer Verlauf). Höhenänderungen des Sichtbereichs
        // (Tastatur, Eingabefeld wächst/schrumpft, Anhänge) verrechnet sie dagegen richtig; dort wird bewusst NICHT
        // nachgerückt, denn auch `scrollTo(edge: .bottom)` zielt um den unteren Inset zu weit.
        .onScrollGeometryChange(for: BottomInsetState.self) { g in
            BottomInsetState(inset: g.contentInsets.bottom,
                             atBottom: g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 24)
        } action: { old, new in
            guard abs(old.inset - new.inset) > 0.5, old.atBottom, scrollState.idle else { return }
            #if DEBUG
            ScrollLog.note("inset \(old.inset) -> \(new.inset): scrollTo bottom")
            #endif
            position.scrollTo(edge: .bottom)
        }
        // Absicherung: Verlauf steht in Ruhe HINTER dem Ende (leere Fläche bis hin zum leeren Bildschirm), etwa wenn
        // `scrollTo(edge: .bottom)` auf eine noch geschätzte Lazy-Höhe zielt (Build 13 gemessen: Versatz 1682 bei
        // Maximum 1168). Ein ScrollView federt das nur nach einer Berührung zurück; hier rückt er ans Ende, sobald
        // nicht gescrollt wird – und versucht es erneut, bis er wirklich am Ende steht (`settleBeyondEnd`).
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height > g.containerSize.height
                && g.visibleRect.maxY - g.contentInsets.bottom - g.contentSize.height > 2
        } action: { _, beyond in
            #if DEBUG
            ScrollLog.note("beyond end \(beyond), idle \(scrollState.idle)")
            #endif
            scrollState.beyondEnd = beyond
            if beyond { settleBeyondEnd() }
        }
        .onScrollGeometryChange(for: LayoutProbe.self) { g in
            LayoutProbe(height: g.contentSize.height,
                        over: g.visibleRect.maxY - g.contentInsets.bottom - g.contentSize.height,
                        insetTop: g.contentInsets.top)
        } action: { _, probe in
            // Höhe und oberer Inset: Auch das Eintreffen der Kopfzeile (Inset 0 → 90 pt) zählt als Layout-Änderung
            scrollState.layout = [probe.height, probe.insetTop]
            scrollState.overshoot = probe.over
        }
        .onScrollPhaseChange { _, phase in
            #if DEBUG
            ScrollLog.note("phase \(phase)")
            #endif
            scrollState.idle = phase == .idle
            scrollState.touching = phase == .tracking || phase == .interacting || phase == .decelerating
            if phase == .idle, scrollState.beyondEnd { settleBeyondEnd() }
            // Nach jeder Bewegung nachmessen (z. B. Sprung ohne Animation)
            if phase == .idle, positioned {
                awayFromEnd = -scrollState.overshoot > Self.awayDistance
                // Während der Berührung kam etwas Neues und man ist am Ende geblieben: jetzt nachrücken
                if scrollState.followAfterTouch, !awayFromEnd, !detached {
                    withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
                }
                scrollState.followAfterTouch = false
            }
        }
        #if DEBUG
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentOffset.y, g.contentSize.height, g.containerSize.height, g.contentInsets.top, g.contentInsets.bottom,
             g.visibleRect.minY, g.visibleRect.maxY]
        } action: { _, v in
            // Ende-Wert = größter regulärer Versatz (UIKit-Versatz; `containerSize` ist ohne Insets)
            let maxY = v[1] - v[2] - v[3]
            ScrollLog.note(String(format: "offset %.1f content %.1f container %.1f insetT %.1f insetB %.1f visible %.1f–%.1f max %.1f over %.1f",
                                  v[0], v[1], v[2], v[3], v[4], v[5], v[6], maxY, v[0] - maxY))
        }
        #endif
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { old, new in
            guard old > 0, abs(old - new) > 0.5, atBottom else { return }
            // Gedrosselt: höchstens ein wartendes Nachrücken (vorher eine Task pro Bild beim Fensterziehen)
            guard widthSettle == nil else { return }
            widthSettle = Task {
                try? await Task.sleep(for: .milliseconds(40))
                widthSettle = nil
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Chat öffnen (Kaltstart, Chatwechsel, Widget/Mitteilung): Der Verlauf erscheint ohne sichtbares Scrollen ganz
    /// unten bzw. mit der ersten ungelesenen Nachricht oben (darüber der Trenner „Neu“).
    ///
    /// Vorher (gemessen im Simulator mit `-mocklatency 700`, Geometrie-Protokoll `-scrolllog`): Der ScrollView entstand
    /// leer, die Startposition (`.initialOffset`) griff am leeren Inhalt. Die nachgeladenen Nachrichten standen oben,
    /// dann liefen ein animiertes `scrollTo` (neue letzte Nachricht) und zwei verzögerte (150/500 ms) sichtbar ans Ende.
    /// Auch ein ScrollView, der gleich mit Nachrichten entsteht, steht nur am Ende der GESCHÄTZTEN Lazy-Höhe (1156 pt);
    /// wächst sie beim Vermessen (2323 pt), bleibt der Versatz stehen (665 pt) – die Verankerung für `.sizeChanges`
    /// greift hier nicht.
    ///
    /// Jetzt: ScrollView erst mit Nachrichten (siehe `body`), unsichtbar, bis die Zeilen vermessen sind und die
    /// Startposition steht: ganz unten, oder der Trenner „Neu“ oben – außer der Rest ab dort passt ohnehin auf den
    /// Bildschirm (dann ganz unten). Alles ohne Animation. Lagen die Nachrichten schon vor (Chatwechsel) und gibt es
    /// nichts Ungelesenes, ist der Verlauf sofort sichtbar; dann wird nur abgesichert.
    private func openTranscript() async {
        // `.task` kann vor `.onAppear` laufen (gemessen bei Nachrichten im Speicher) – deshalb auch hier.
        captureOpening()
        if !loaded {
            let spinner = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { slowLoad = true }
            }
            await store.loadLatestMessages(chatID: chatID)
            spinner.cancel()
            slowLoad = false
            loadFinished = true
        }
        guard !Task.isCancelled else { return }
        var t = Transaction()
        t.disablesAnimations = true
        let anchor = ChatItem.firstUnreadID(in: messages, unread: unreadCount)
        if let anchor { unreadAnchorID = anchor }
        // Erst SwiftUI den neuen Inhalt verarbeiten und vermessen lassen. `positioned` bleibt so lange false, damit
        // das Nachladen nicht als „neue letzte Nachricht“ animiert ans Ende scrollt.
        await waitForLayout()
        if anchor != nil {
            withTransaction(t) { position.scrollTo(id: ChatItem.unreadID, anchor: .top) }
            await waitForLayout()
        }
        // Sprung zu einer Fundstelle (Suche): Der Chat öffnet gleich mit der Nachricht in der Mitte.
        if let id = store.pendingScrollMessageID, messages.contains(where: { $0.id == id }) {
            store.pendingScrollMessageID = nil
            withTransaction(t) { position.scrollTo(id: id, anchor: .center) }
            await waitForLayout()
            positioned = true
            awayFromEnd = -scrollState.overshoot > Self.awayDistance
            scrollState.count = messages.count
            await flash(id)
            return
        }
        // Ganz unten (ohne Ungelesenes), bzw. kurzer Rest: Das Ziel liegt hinter dem Ende, weil alles ab dem Trenner
        // auf den Bildschirm passt → ans Ende. Zweiter Durchgang, falls sich Lazy-Höhen dabei noch einmal ändern.
        for _ in 0..<2 {
            let off = scrollState.overshoot
            let wantBottom = anchor == nil ? off < -1 : off > 1
            guard wantBottom else { break }
            withTransaction(t) { position.scrollTo(edge: .bottom) }
            await waitForLayout()
        }
        #if DEBUG
        ScrollLog.note("open: unread \(openedUnread ?? 0) anchor \(anchor ?? "–") over \(scrollState.overshoot) messages \(messages.count) cached \(cachedAtOpen.map(String.init) ?? "nil")")
        #endif
        positioned = true
        // Start beim Trenner „Neu“ mit viel Verlauf darunter: Der Zum-Ende-Knopf steht gleich bereit
        awayFromEnd = -scrollState.overshoot > Self.awayDistance
        scrollState.count = messages.count
    }

    /// Zustand beim Öffnen merken (einmal): Ungelesen-Zähler und ob die Nachrichten schon vorlagen.
    private func captureOpening() {
        if openedUnread == nil { openedUnread = unreadCount }
        if cachedAtOpen == nil { cachedAtOpen = loaded }
    }

    /// Wartet, bis sich Inhaltshöhe und oberer Inset zwei Bilder lang nicht mehr ändert (Lazy-Zeilen vermessen), höchstens ~250 ms.
    private func waitForLayout() async {
        var last: [CGFloat] = []
        var stable = 0
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(16))
            if scrollState.layout == last { stable += 1 } else { stable = 0 }
            last = scrollState.layout
            if stable >= 2 { return }
        }
    }

    /// Steht der Verlauf hinter dem Ende, kurz warten (Lazy-Zeilen vermessen sich noch) und, falls weiterhin
    /// hinter dem Ende und ohne Berührung, ans Ende rücken. Landet das Nachrücken selbst noch einmal hinter dem
    /// Ende (geschätzte Höhen), meldet die Geometrie keinen neuen Wechsel – deshalb hier bis zu fünf Versuche.
    private func settleBeyondEnd() {
        scrollState.settle?.cancel()
        scrollState.settle = Task {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, scrollState.idle, scrollState.beyondEnd else { return }
                #if DEBUG
                ScrollLog.note("settle beyond end: scrollTo bottom")
                #endif
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Zur Nachricht aus der Suche bzw. einem Zitat scrollen und sie kurz hervorheben.
    private func scrollToPendingMessage() async {
        guard let id = store.pendingScrollMessageID, messages.contains(where: { $0.id == id }) else { return }
        store.pendingScrollMessageID = nil
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.smooth(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
        await flash(id)
    }

    /// Zeile kurz hinterlegen (Treffer der Suche, Original eines Zitats).
    private func flash(_ id: String) async {
        withAnimation(.easeOut(duration: 0.2)) { flashedID = id }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.6)) { if flashedID == id { flashedID = nil } }
    }

    /// Neue letzte Nachricht: Steht der Verlauf am Ende (oder hat man selbst gesendet), rückt er wie bisher nach.
    /// Hat man hochgescrollt, bleibt er stehen und der Zum-Ende-Knopf zählt die neue Nachricht.
    private func followNewMessage() {
        guard let last = messages.last else { return }
        let grew = messages.count > scrollState.count, shrunk = messages.count < scrollState.count
        scrollState.count = messages.count
        // Im Ausschnitt ändert sich das Ende nur durch Nachladen; entfernte Nachrichten (bearbeitet) zählen nicht
        guard !detached, !shrunk, !scrollState.loadingNewer else { return }
        let own = last.role == .user && store.isOwnMessage(last)
        #if DEBUG
        ScrollLog.note("new last \(last.role.rawValue), away \(awayFromEnd), idle \(scrollState.idle), over \(scrollState.overshoot)")
        #endif
        if awayFromEnd, !own {
            if grew, last.role == .bot || last.role == .approval || last.role == .user { unseenCount += 1 }
            return
        }
        // Finger auf dem Verlauf: nicht unter dem Finger wegscrollen, nach dem Loslassen nachholen
        if scrollState.touching, !own {
            scrollState.followAfterTouch = true
            return
        }
        withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }

    /// Zum-Ende-Knopf: ans Ende scrollen; aus einem Ausschnitt heraus erst die jüngsten Nachrichten laden.
    private func jumpToEnd() {
        unseenCount = 0
        guard detached else {
            withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
            return
        }
        Task {
            await store.returnToLatest(chatID)
            await waitForLayout()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { position.scrollTo(edge: .bottom) }
            awayFromEnd = false
            scrollState.count = messages.count
        }
    }

    /// „Neuere Nachrichten laden“ im Ausschnitt: anhängen und die Leseposition halten. Die Verankerung am Ende würde
    /// sonst mit dem neuen Inhalt mitwandern (50 Nachrichten weiter); die bisher letzte Nachricht bleibt unten stehen.
    private func loadNewer() async {
        let anchor = messages.last?.id
        scrollState.loadingNewer = true
        await store.loadNewerMessages(chatID: chatID)
        if let anchor {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { position.scrollTo(id: anchor, anchor: .bottom) }
            await waitForLayout()
            withTransaction(t) { position.scrollTo(id: anchor, anchor: .bottom) }
        }
        scrollState.count = messages.count
        scrollState.loadingNewer = false
        awayFromEnd = -scrollState.overshoot > Self.awayDistance
    }

    /// Treffer der Suche im Chat zeigen: bei Bedarf nachladen, hinscrollen (bleibt hinterlegt, solange die Suche offen ist).
    private func showFindHit(_ hit: SearchHit) {
        Task { await store.jumpToMessage(hit.messageId, chatID: chatID) }
    }

    private func closeFind() {
        find.close()
        #if os(iOS)
        KeyboardMonitor.dismiss()
        #else
        store.composerFocusRequest += 1
        #endif
    }

    /// Sprecher (Bot des Chats bzw. Gruppenmitglieder) als leichte Werte für die Zeilen.
    private var speakers: [String: SpeakerInfo] {
        var map: [String: SpeakerInfo] = [:]
        for b in store.members(of: chatID) { map[b.id] = b.speaker }
        if let b = store.bot(chatID) { map[b.id] = b.speaker }
        return map
    }

    /// Tippende Scoops, deren Arbeit nicht schon eine laufende Statuszeile zeigt.
    private var typingBubbleMembers: [Bot] {
        let runningAuthors = Set(messages.filter(\.isRunning).map { $0.meta.authorId ?? chatID })
        return store.typingMembers(chatID).filter { !runningAuthors.contains($0.id) }
    }

    @ViewBuilder
    private var emptyChat: some View {
        if let bot = store.bot(chatID) {
            VStack(spacing: 12) {
                MascotView(mascot: bot.mascot, size: 110, seed: bot.id, showsGround: true)
                Text("Sag \(bot.name) Hallo").font(.title3.weight(.semibold)).foregroundStyle(theme.textPrimary)
                Text("Erzähl, wobei \(bot.name) dir helfen soll. Regeln und Vorlieben merkt sich dein Scoop von selbst.")
                    .font(.callout).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(.top, 80)
        } else if let group = store.group(chatID) {
            VStack(spacing: 12) {
                GroupAvatar(members: store.members(of: chatID), size: 120)
                Text(group.name).font(.title3.weight(.semibold)).foregroundStyle(theme.textPrimary)
                Text("Schreib der Gruppe. Mit @Name sprichst du einen Scoop direkt an, mit @alle alle zusammen.")
                    .font(.callout).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(.top, 80)
        }
    }
}

/// Unterer Inset des Verlaufs und ob er vorher am Ende stand (Absicherung, siehe `transcript`).
private struct BottomInsetState: Equatable {
    var inset: CGFloat
    var atBottom: Bool
}

/// Bewusst nicht `@Observable`: Wird während des Scrollens geschrieben, ohne den Chat neu auszuwerten.
private final class TranscriptScrollState {
    var idle = true
    var beyondEnd = false
    var settle: Task<Void, Never>?
    /// Für das Öffnen (`openTranscript`): Inhaltshöhe und oberer Inset sowie Überstand hinter dem Ende
    /// (positiv = hinter dem Ende, negativ = oberhalb des Endes)
    var layout: [CGFloat] = []
    var overshoot: CGFloat = 0
    /// Zahl der Nachrichten beim letzten Wechsel am Ende (neue Nachricht von entfernter unterscheiden, `followNewMessage`)
    var count = 0
    /// „Neuere Nachrichten laden“ läuft: Der Verlauf rückt dabei nicht ans Ende
    var loadingNewer = false
    /// Finger bzw. Schwung auf dem Verlauf (nicht: animiertes Scrollen der App)
    var touching = false
    /// Während der Berührung kam eine neue Nachricht: nach dem Loslassen nachrücken, falls man am Ende steht
    var followAfterTouch = false
}

/// Inhaltshöhe und Überstand hinter dem Ende (siehe `TranscriptScrollState`).
private struct LayoutProbe: Equatable {
    var height: CGFloat
    var over: CGFloat
    var insetTop: CGFloat
}

/// Eintrag im Verlauf: Zeitstempel-Trenner oder Nachricht.
enum ChatItem: Identifiable {
    case stamp(Date, id: String)
    case message(Message, grouped: Bool)
    /// Trenner „Neu“ vor der ersten ungelesenen Nachricht (Ziel der Startposition)
    case unread

    static let unreadID = "unread-divider"

    var id: String {
        switch self {
        case .stamp(_, let id): "stamp-\(id)"
        case .message(let m, _): m.id
        case .unread: Self.unreadID
        }
    }

    /// Zeitstempel, wenn mehr als 20 Minuten zwischen zwei Nachrichten liegen.
    /// „grouped“: gleiche Rolle und (in Gruppen) gleicher Autor kurz hintereinander.
    /// `unreadBefore`: Trenner „Neu“ vor dieser Nachricht (vor ihrem Zeitstempel, falls sie einen hat).
    static func build(_ messages: [Message], unreadBefore: String? = nil) -> [ChatItem] {
        var items: [ChatItem] = []
        var previous: Message?
        for m in messages {
            let gap = previous.map { m.createdAt.timeIntervalSince($0.createdAt) } ?? .infinity
            let stamped = gap > 20 * 60
            let firstUnread = m.id == unreadBefore
            if firstUnread { items.append(.unread) }
            if stamped { items.append(.stamp(m.createdAt, id: m.id)) }
            // Gleicher Absender: gleicher Scoop bzw. (geteilte Scoops) gleiche Person
            let sameAuthor = previous?.meta.authorId == m.meta.authorId
                && previous?.meta.authorUserId == m.meta.authorUserId
            let grouped = !stamped && !firstUnread && previous?.role == m.role && (m.role == .bot || m.role == .user)
                && gap < 120 && sameAuthor
            items.append(.message(m, grouped: grouped))
            previous = m
        }
        return items
    }

    /// Erste ungelesene Nachricht: Der Server zählt Antworten und Freigaben (`bot`, `approval`) seit dem letzten
    /// „gelesen“. Von hinten gezählt ist die n-te davon die erste ungelesene; reicht der geladene Verlauf nicht
    /// so weit zurück, die früheste geladene.
    static func firstUnreadID(in messages: [Message], unread: Int) -> String? {
        guard unread > 0 else { return nil }
        var counted = 0
        var earliest: String?
        for m in messages.reversed() where m.role == .bot || m.role == .approval {
            counted += 1
            earliest = m.id
            if counted == unread { break }
        }
        return earliest
    }
}

/// Dezenter Trenner „Neu“ über der ersten ungelesenen Nachricht.
private struct UnreadDivider: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            line
            Text("Neu")
                .appFont(12, weight: .semibold)
                .foregroundStyle(theme.unreadDot)
            line
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) ungelesene Nachrichten")
    }

    private var line: some View {
        Rectangle()
            .fill(theme.unreadDot.opacity(0.35))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

#if os(macOS)
/// Kopfzeile über dem Mac-Chat (Build 15): Glas-Pille mittig, rechts „Profil einblenden“ als Glas-Kreis, solange
/// das Profil zu ist. Keine Fläche dahinter – der Verlauf läuft darunter durch (siehe `safeAreaBar` in `ChatView`).
struct ChatMacHeader: View {
    let chatID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        GlassEffectContainer {
            ZStack {
                ChatCapsule(chatID: chatID) { store.showInspector.toggle() }
                HStack(spacing: 8) {
                    Spacer()
                    Button { store.chatFindRequest += 1 } label: {
                        Image(systemName: "magnifyingglass")
                            .appFont(14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .scaledFrame(36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(Glass.chatHeader(theme), in: .circle)
                    .help("Im Chat suchen (⌘F)")
                    .accessibilityLabel("Im Chat suchen")
                    if !store.showInspector {
                        Button { store.showInspector = true } label: {
                            Image(systemName: "sidebar.right")
                                .appFont(14, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                                .scaledFrame(36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(Glass.chatHeader(theme), in: .circle)
                        .help("Profil einblenden")
                        .accessibilityLabel("Profil einblenden")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(alignment: .top) {
            // Sehr dezenter Schleier statt Fläche: hält Text unter der Pille ruhig, der Verlauf bleibt sichtbar.
            LinearGradient(stops: [.init(color: theme.background.opacity(0.85), location: 0),
                                   .init(color: theme.background.opacity(0.55), location: 0.5),
                                   .init(color: theme.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -18)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}
#endif

/// Höhe der Chat-Kopfzeile auf dem Bildschirm (Mitte der Pille, globale Koordinaten), solange die Pille links steht
/// (iPhone Duo, iPad). Die Profilspalte daneben (`RootView.profileColumn`) setzt ihre Kopfleiste mit dem
/// Schließen-Knopf auf genau diese Höhe, wie die Knöpfe der Seitenleiste (siehe `InspectorContent.barTop`).
/// `nil` auf dem iPhone (Pille in der Mitte, Profil als Blatt).
///
/// Die Pille liegt in der Navigationsleiste (UIKit). Verschiebt UIKit deren Einträge (Auf-/Zuklappen, Drehen),
/// erfährt SwiftUI davon nicht immer, die gemessene Höhe blieb dann auf einem Zwischenstand der Animation stehen
/// (Duo nach dem Aufklappen: 17 pt zu hoch). `measure()` baut den Messpunkt neu auf und misst damit frisch.
/// Nur iOS genutzt, steht für die gemeinsame `InspectorContent` auf allen Plattformen.
@Observable
final class ChatHeaderAnchor {
    var midY: CGFloat?
    /// Erhöht von `measure()`: Identität des Messpunkts an der Pille
    private(set) var generation = 0

    func measure() { generation &+= 1 }
}

#if os(iOS)
/// Kopf des Chats auf iPhone, iPhone Duo und iPad (Build 15): Name als schwebende Glas-Pille, Zurück/Neu als
/// Glas-Knöpfe der Systemleiste. Die Leiste hat keine deckende Fläche mehr: Der Verlauf läuft unter Pille und
/// Knöpfen bis an den oberen Rand, oben liegt nur der weiche Scroll-Kanten-Effekt des Systems.
///
/// Normalerweise steht die Pille als `.principal` in der Navigationsleiste (eigenes Glas, deshalb ohne den
/// geteilten Leisten-Hintergrund). Ausnahme iPhone Duo: Dort setzt das System die Knöpfe in seine senkrechte
/// Leiste am Rand und zeigt `.principal` nur manchmal (Simulator iOS 27.2: aufgeklappt nie, zugeklappt nach einem
/// Neustart nicht, nach dem Zuklappen schon; gemessen über den Bedienungshilfen-Baum). Solange die Leiste senkrecht
/// steht, schwebt die Pille deshalb selbst oben über dem Verlauf – zu und auf gleich. Auf dem iPad steht sie
/// ebenfalls links, die übrigen Knöpfe stehen dort unten in der Seitenleiste (siehe `Placement`).
private struct ChatHeaderBar: ViewModifier {
    let chatID: String

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarReader(chatID: chatID))
        } else {
            content.modifier(Placement(chatID: chatID, floating: false))
        }
    }

    /// `toolbarVerticalEdge` gibt es erst ab iOS 27.1: gesetzt, solange die Systemleiste senkrecht steht.
    @available(iOS 27.1, *)
    private struct VerticalBarReader: ViewModifier {
        let chatID: String
        @Environment(\.toolbarVerticalEdge) private var verticalEdge

        func body(content: Content) -> some View {
            content.modifier(Placement(chatID: chatID, floating: verticalEdge != nil))
        }
    }

    private struct Placement: ViewModifier {
        let chatID: String
        let floating: Bool
        @Environment(AppStore.self) private var store

        /// Test: `-floatingHeader` erzwingt die Anordnung für die senkrechte Systemleiste
        private static let forceFloating = ProcessInfo.processInfo.arguments.contains("-floatingHeader")

        @Environment(ChatHeaderAnchor.self) private var headerAnchor: ChatHeaderAnchor?
        @Environment(\.horizontalSizeClass) private var sizeClass

        /// Pille als führendes Element (senkrechte Systemleiste, iPad); volle Breite, sonst kürzt die Leiste den Namen.
        /// Meldet ihre Höhe auf dem Bildschirm, damit die Profilspalte ihren Schließen-Knopf daneben ausrichtet.
        private var leadingCapsule: some View {
            ChatCapsule(chatID: chatID) { store.showInspector.toggle() }
                .fixedSize()
                .background {
                    Color.clear
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { headerAnchor?.midY = $0 }
                        .id(headerAnchor?.generation)
                }
        }

        func body(content: Content) -> some View {
            let vertical = floating || Self.forceFloating
            // iPad mit waagerechter Leiste: Pille links wie beim Duo, „Neu“, „Apps verbinden“ und „Aufgaben“ unten in
            // der Seitenleiste (`SidebarActionBar`), damit das Nachrichtenfeld ganz unten bleibt. Ist die Seitenleiste
            // eingeklappt, stehen sie oben rechts im Chat: dort sind sie ohne Umweg erreichbar, und eine eigene
            // untere Leiste würde das Nachrichtenfeld wieder nach oben schieben.
            let wide = !vertical && sizeClass == .regular
            let actionsInSidebar = wide && sidebarCarriesActions(store: store, verticalBar: false)
            let leading = vertical || wide
            content
                .toolbar {
                    if leading {
                        // Senkrechte Systemleiste (iPad mit Leiste am Rand, iPhone Duo): `.principal` zeigt das System
                        // dort nicht zuverlässig. Als führendes Element steht die Pille in derselben Zeile wie der
                        // Seitenleisten-Knopf – gleiche Höhe, kein Absatz darunter (vorher eigene Leiste unter der
                        // Navigationsleiste, dadurch tiefer als der Knopf). iPad mit waagerechter Leiste ebenso.
                        if #available(iOS 27, *) {
                            // Vorrang vor den Knöpfen rechts: die wandern bei Platzmangel ins Überlauf-Menü
                            ToolbarItem(placement: .topBarLeading) { leadingCapsule }
                                .sharedBackgroundVisibility(.hidden)
                                .visibilityPriority(.high)
                        } else {
                            ToolbarItem(placement: .topBarLeading) { leadingCapsule }
                                .sharedBackgroundVisibility(.hidden)
                        }
                    } else {
                        ToolbarItem(placement: .principal) {
                            ChatCapsule(chatID: chatID) { store.showInspector.toggle() }
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    // Suche in diesem Chat (App 1.3): eigener Knopf rechts im Chat-Kopf
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.chatFindRequest += 1 } label: {
                            Label("Im Chat suchen", systemImage: "magnifyingglass")
                        }
                        .accessibilityLabel("Im Chat suchen")
                    }
                    // iPhone (Pille in der Mitte): Suche, Aufgaben und ein Drei-Punkte-Menü (Neu, Apps verbinden),
                    // damit neben den Knöpfen Platz für den Namen bleibt
                    SystemBarItems(keyboardVisible: store.keyboardVisible, showActions: !actionsInSidebar,
                                   collapseActions: !leading)
                }
                .navigationBarTitleDisplayMode(.inline)
                // Nie eine deckende Leisten-Fläche, auch nicht beim Scrollen (nur der Scroll-Kanten-Effekt)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .modifier(NeverMinimize())
                // iPhone (Pille in der Mitte, Profil als Blatt): keine Ausrichtung
                .onChange(of: leading, initial: true) { _, v in if !v { headerAnchor?.midY = nil } }
        }
    }

    /// Leiste beim Scrollen nicht einklappen (iOS 27 minimiert sie sonst): Seitenleisten-Knopf, Name und Knöpfe
    /// bleiben immer sichtbar.
    private struct NeverMinimize: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 27, *) {
                content.toolbarMinimizationBehavior(.never, for: .navigationBar)
            } else {
                content
            }
        }
    }
}
#endif

/// Schwebende Glas-Pille oben: Mini-Maskottchen + Name, öffnet das Profil (Scoop bzw. Gruppe).
struct ChatCapsule: View {
    let chatID: String
    var action: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let name = store.chatName(chatID)
        // Gruppen-Stapel hält sein Fell schon innerhalb des Rahmens (`GroupAvatar`), darf deshalb etwas größer sein
        let mascot = Metrics.mascot + (ChatGroup.isGroupID(chatID) ? 4 : 0)
        Button(action: action) {
            HStack(spacing: Metrics.spacing) {
                // Maskottchen mittig im linken Halbkreis der Kapsel (gleicher Abstand links, oben und unten), mit
                // Luft für das Fell. Vorher 36 pt (Gruppe 38 pt) bei 5 pt Rand in 44 pt: Das Fell stieß an den Rand.
                ChatAvatar(chatID: chatID, size: mascot)
                    .frame(width: mascot, height: mascot)
                Text(name)
                    .appFont(Metrics.fontSize, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(1)
            }
            .padding(.leading, (Metrics.height - mascot) / 2)
            .padding(.trailing, Metrics.trailing)
            .frame(height: Metrics.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Kapsel in der Navigationsleiste (feste Höhe): Name wächst bis zur größten normalen Stufe mit
        .dynamicTypeSize(...AppFont.controlCap)
        // Liquid Glass wie die System-Knöpfe (Zurück, Neu); `interactive` gibt das Druck-Feedback des Systems.
        .glassEffect(Glass.chatHeader(theme), in: .capsule)
        .help("Profil von \(name)")
        .accessibilityLabel("Profil von \(name) öffnen")
    }

    /// Maße der Pille. iOS: 44 pt hoch wie die Glas-Knöpfe der Systemleiste. Mac: etwas größer (dort gibt es keine
    /// System-Knöpfe gleicher Höhe, die Kopfzeile hat Platz).
    private enum Metrics {
        #if os(macOS)
        static let height: CGFloat = 48
        static let mascot: CGFloat = 32
        static let fontSize: CGFloat = 16
        static let spacing: CGFloat = 9
        static let trailing: CGFloat = 20
        #else
        static let height: CGFloat = 44
        static let mascot: CGFloat = 30
        static let fontSize: CGFloat = 16
        static let spacing: CGFloat = 8
        static let trailing: CGFloat = 18
        #endif
    }
}

extension Glass {
    /// Glas der Chat-Kopfzeile. iOS: wie die System-Knöpfe. Mac: Das Mac-Glas ist deutlich klarer, Text des
    /// Verlaufs schien durch die Pille hindurch; ein leichter Ton in der Hintergrundfarbe hält den Namen lesbar.
    static func chatHeader(_ theme: Theme) -> Glass {
        #if os(macOS)
        .regular.tint(theme.background.opacity(0.55)).interactive()
        #else
        .regular.interactive()
        #endif
    }
}

extension View {
    /// Inhalt auf die Lesespalte begrenzen und mittig setzen, die Zeile selbst bleibt volle Breite.
    /// Wichtig für das Scroll-Verankern im Verlauf (siehe `ChatView.transcript`).
    func chatColumn(_ maxWidth: CGFloat) -> some View {
        frame(maxWidth: maxWidth).padding(.horizontal, 16).frame(maxWidth: .infinity)
    }
}

/// Stapel des Verlaufs: normalerweise `LazyVStack`. Bei Bedienungshilfen-Größen ein `VStack`: Die Zeilen sind dann so
/// hoch, dass die geschätzten Höhen des LazyVStack beim Vermessen um Tausende Punkte schrumpfen; nach dem Sprung ans
/// Ende legte er mitunter gar keine Zeile an (leerer Verlauf bis zur ersten Berührung, gemessen bei Mila im
/// Demo-Modus, AX3–AX5). Der Verlauf lädt seitenweise, ein voll angelegter Stapel bleibt überschaubar.
private struct TranscriptStack<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) { content }.scrollTargetLayout()
        } else {
            LazyVStack(spacing: 10) { content }.scrollTargetLayout()
        }
    }
}
