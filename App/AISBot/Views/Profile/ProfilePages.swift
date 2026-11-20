import SwiftUI
import AVFoundation

// Unterseiten des Scoop-Profils (Drill-down wie in den iOS-Einstellungen). Die Übersicht (`ProfileView`) zeigt nur
// „Anstehend“, „Computer“ und Navigationszeilen; alles Weitere liegt auf diesen Seiten.

// MARK: - Seiten und Navigation

/// Unterseiten des Profils. `rawValue` = Name für das Startargument `-profilepage` (z. B. `manage,costs`).
enum ProfilePage: String, Hashable, CaseIterable {
    case library, model, personality, sharing, guestTools, manage, routines, skills, memory, costs

    var title: String {
        switch self {
        case .library: String(localized: "Bibliothek")
        case .model: String(localized: "Modell", comment: "Profilseite: KI-Modell des Scoops")
        case .personality: String(localized: "Persönlichkeit")
        case .sharing: String(localized: "profile.page.sharing", defaultValue: "Teilen", comment: "Profilseite: Scoop mit anderen teilen (englisch „Sharing“)")
        case .guestTools: String(localized: "Werkzeuge für Geteilte")
        case .manage: String(localized: "Verwalten")
        case .routines: String(localized: "Routinen")
        case .skills: String(localized: "Fähigkeiten")
        case .memory: String(localized: "Gedächtnis")
        case .costs: String(localized: "Kosten")
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .model: "cpu"
        case .personality: "theatermasks"
        case .sharing: "person.2"
        case .guestTools: "wrench.and.screwdriver"
        case .manage: "slider.horizontal.3"
        case .routines: "clock"
        case .skills: "wand.and.stars"
        case .memory: "brain"
        case .costs: "dollarsign.circle"
        }
    }

    /// Darf diese Seite für den Scoop erscheinen? Gäste sehen nur, was ihre Rolle erlaubt.
    @MainActor
    func isAllowed(store: AppStore, botID: String) -> Bool {
        let guest = store.access(for: botID)
        let canEdit = guest.map { $0.role.canEdit } ?? true
        switch self {
        case .library, .manage, .costs: return true
        case .model: return guest == nil
        case .sharing, .guestTools: return store.canShare(botID)
        case .personality, .routines, .skills, .memory: return canEdit
        }
    }

    /// Startseiten für Screenshots: `-profilepage model` bzw. `-profilepage manage,costs`; ältere Argumente
    /// (`-modeldemo`, `-sharingdemo`, `-invitedemo`, `-costdemo`, `-memory`, `-library`) öffnen die passende Seite.
    static var initialPath: [ProfilePage] {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-profilepage"), args.indices.contains(i + 1) {
            return args[i + 1].split(separator: ",").compactMap { ProfilePage(rawValue: String($0)) }
        }
        if args.contains("-modeldemo") { return [.model] }
        if args.contains("-sharingdemo") || args.contains("-invitedemo") { return [.sharing] }
        if args.contains("-costdemo") { return [.manage, .costs] }
        if args.contains("-memory") { return [.manage, .memory] }
        if args.contains("-library") { return [.library] }
        return []
    }
}

/// Stapel des Profils und Schließen. Liegt in der Umgebung, damit Unterseiten zurück und schließen können.
@Observable
final class ProfileRouter {
    var path: [ProfilePage]
    /// Schließt das Profil (Inspector bzw. Blatt). Gesetzt von der Ansicht außerhalb des Stapels: Ein `dismiss`
    /// aus einer Unterseite hieße dort nur „zurück“.
    @ObservationIgnored var onClose: () -> Void = {}

    init(path: [ProfilePage] = []) { self.path = path }

    func back() { if !path.isEmpty { path.removeLast() } }
    func close() { onClose() }
    func popToRoot() { if !path.isEmpty { path = [] } }

    /// Titel des Zurück-Knopfs: die Seite darunter
    func backTitle(for page: ProfilePage?) -> String {
        guard let page, let i = path.lastIndex(of: page), i > 0 else { return String(localized: "Profil") }
        return path[i - 1].title
    }
}

/// Seitenstapel des Profils, auf allen Geräten derselbe (Mac und iPad: Inspector-Spalte, iPhone: Blatt).
///
/// Bewusst kein `NavigationStack`: Im Inspector reicht er `navigationDestination` an den äußeren
/// `NavigationSplitView` weiter (gemessen auf macOS 26: die Unterseite ersetzte den Chat in der Detailspalte), und auf
/// dem iPhone baut SwiftUI das Profil beim Start bzw. beim Umklappen des Duo kurz im `.inspector` des Chats auf. Dort
/// steckte ein eigener `NavigationStack` in der Chat-Navigation: Sein Titel erschien im Chat, der Chat blieb leer.
///
/// Die Übersicht bleibt darunter stehen (Scrollposition bleibt erhalten); jede Seite gleitet von rechts darüber.
/// iOS: Wischen vom linken Rand führt zurück, wie in einem Navigationsstapel.
struct ProfileStack<Root: View>: View {
    let botID: String
    @ViewBuilder var root: Root
    @Environment(ProfileRouter.self) private var router
    @State private var dragOffset: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let path = router.path
        ZStack {
            root
                .accessibilityHidden(!path.isEmpty)
                .allowsHitTesting(path.isEmpty)
            ForEach(Array(path.enumerated()), id: \.offset) { index, page in
                let top = index == path.count - 1
                ProfilePageView(page: page, botID: botID)
                    .accessibilityHidden(!top)
                    .allowsHitTesting(top)
                    .offset(x: top ? dragOffset : 0)
                    .transition(.move(edge: .trailing))
                    .zIndex(Double(index + 1))
            }
        }
        // Nur seitlich: Die Kopfleiste darf bei `profileBarTop` über den sicheren Bereich hinaus nach oben reichen
        .clipShape(HorizontalClip())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #if os(iOS)
        .overlay(alignment: .leading) {
            // Schmaler Streifen am linken Rand: zieht die oberste Seite mit dem Finger nach rechts
            if !path.isEmpty {
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .gesture(backSwipe)
            }
        }
        #endif
        .animation(.snappy(duration: 0.28), value: path)
        .onChange(of: path) { dragOffset = 0 }
    }

    #if os(iOS)
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in dragOffset = max(0, v.translation.width) }
            .onEnded { v in
                let far = v.translation.width > max(80, width * 0.33) || v.predictedEndTranslation.width > width * 0.6
                if far {
                    withAnimation(.snappy(duration: 0.22)) { dragOffset = width }
                    router.back()
                } else {
                    withAnimation(.snappy(duration: 0.22)) { dragOffset = 0 }
                }
            }
    }
    #endif
}

extension EnvironmentValues {
    /// Abstand der Profil-Kopfleiste zur Oberkante der Spalte, wenn sie sich an der Chat-Pille statt am sicheren
    /// Bereich ausrichtet (rechte Spalte auf iPad und iPhone Duo, siehe `InspectorContent.barTop`). `nil`: unterhalb
    /// des sicheren Bereichs mit dem üblichen Abstand (Blatt, Mac).
    @Entry var profileBarTop: CGFloat? = nil
}

/// Rahmen jeder Profilseite: Titel, Zurück und Schließen in einer festen Leiste über dem scrollenden Inhalt, damit der
/// Schließen-Knopf nie über Inhalten liegt; sobald der Inhalt darunter scrollt, erscheint eine Trennlinie.
struct ProfileScaffold<Content: View>: View {
    /// nil = Übersicht (ohne Titel und Zurück)
    var page: ProfilePage?
    @ViewBuilder var content: Content
    /// Optional gelesen: fehlt der Router (Vorschau, früher Aufbau), bleiben Zurück/Schließen wirkungslos statt abzustürzen
    @Environment(ProfileRouter.self) private var router: ProfileRouter?
    @Environment(\.theme) private var theme
    @Environment(\.profileBarTop) private var barTopOverride
    @State private var scrolled = false

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.top, page == nil ? 0 : 14)
                .padding(.bottom, 24)
        }
        .scrollIndicators(page == nil ? .never : .automatic)
        // Bei `barTopOverride` reicht die Liste bis an die Oberkante (Statusleiste); dort keinen Scroll-Kanten-Effekt
        // des Systems. Die eigene Leiste ist deckend und hat ihre eigene Trennlinie.
        .scrollEdgeEffectHidden(barTopOverride != nil, for: .top)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, v in
            scrolled = v
        }
        .safeAreaInset(edge: .top, spacing: 0) { bar }
        // Rechte Spalte auf iPad/Duo: Leiste auf der Höhe der Chat-Pille (`barTopOverride`), gemessen ab der
        // Oberkante der Spalte statt ab dem sicheren Bereich (sonst stünde sie auf dem iPad unter der Statusleiste
        // tiefer als die übrigen Kopfzeilen-Knöpfe)
        .ignoresSafeArea(.container, edges: barTopOverride == nil ? [] : .top)
        // Unterseiten decken die Übersicht vollständig ab
        .background(theme.groupedBackground.ignoresSafeArea())
    }

    private var backTitle: String { router?.backTitle(for: page) ?? String(localized: "Profil") }

    /// Maße wie eine Navigationsleiste des Systems: 44-pt-Knöpfe auf iPhone/iPad (Mindest-Trefferfläche),
    /// 36 pt auf dem Mac (Größe der Glas-Knöpfe in der Fenster-Symbolleiste), Titel 17 pt halbfett.
    /// Abstand der Knöpfe zum Rand: seitlich wie die Inhaltskarten plus etwas Luft, oben etwas tiefer als die Kante
    /// (Blatt-Griff bzw. Fenster-Symbolleiste), damit sie nicht am Rand kleben.
    #if os(macOS)
    private static var buttonSize: CGFloat { 36 }
    static var barHeight: CGFloat { 54 }
    private static var sideInset: CGFloat { 18 }
    private static var topInset: CGFloat { 8 }
    #else
    private static var buttonSize: CGFloat { 44 }
    static var barHeight: CGFloat { 62 }
    private static var sideInset: CGFloat { 20 }
    private static var topInset: CGFloat { 12 }
    #endif

    private var bar: some View {
        ZStack {
            if let page {
                Text(page.title)
                    .appFont(17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Self.buttonSize + 12)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                if page != nil {
                    glassButton("chevron.left", label: String(localized: "Zurück zu \(backTitle)")) { router?.back() }
                        .keyboardShortcut("[", modifiers: .command)
                }
                Spacer(minLength: 0)
                glassButton("xmark", label: String(localized: "Schließen")) { router?.close() }
            }
        }
        .padding(.horizontal, Self.sideInset)
        .frame(height: Self.barHeight)
        .padding(.top, barTopOverride ?? Self.topInset)
        .frame(maxWidth: .infinity)
        .background(theme.groupedBackground)
        .overlay(alignment: .bottom) { GroupedDivider(inset: 0).opacity(scrolled ? 1 : 0) }
        .animation(.easeOut(duration: 0.15), value: scrolled)
    }

    /// Runder Knopf im Liquid-Glass-Stil (wie Zurück/Schließen in den Navigationsleisten von iOS/macOS 26)
    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.fixed(Self.buttonSize * 0.4, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Navigationszeile im Stil der App: Symbol, Titel, rechts Kurzinfo und Pfeil. Öffnet die Seite über den Router
/// (kein `NavigationLink`: der liefe im Inspector in den äußeren Split-View, siehe `ProfileStack`).
struct ProfileNavRow: View {
    let page: ProfilePage
    var value: String?
    var title: String?
    @Environment(ProfileRouter.self) private var router: ProfileRouter?
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button { router?.path.append(page) } label: {
            // Eigene Zeile statt `GroupedLabelRow`: Der Titel hat Vorrang (einzeilig, nie mitten im Wort umbrochen),
            // die Kurzinfo kürzt sich in schmalen Spalten zuerst.
            if dynamicTypeSize.isAccessibilitySize {
                // Große Schrift: Kurzinfo unter dem Titel, beide dürfen umbrechen
                HStack(spacing: 12) {
                    Image(systemName: page.symbol)
                        .appFont(15, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .scaledFrame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title ?? page.title)
                            .appFont(15)
                            .foregroundStyle(theme.textPrimary)
                        if let value {
                            Text(value)
                                .appFont(14.5)
                                .foregroundStyle(theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    DisclosureChevron()
                }
                .groupedRow()
            } else {
            HStack(spacing: 12) {
                Image(systemName: page.symbol)
                    .appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(width: 22)
                Text(title ?? page.title)
                    .appFont(15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                // Kurzinfo und Pfeil eng beieinander (wie in den iOS-Einstellungen); in schmalen Spalten zählt jeder Punkt
                HStack(spacing: 6) {
                    if let value {
                        Text(value)
                            .appFont(14.5)
                            .foregroundStyle(theme.textSecondary)
                            .adaptiveLineLimit(1)
                            .monospacedDigit()
                    }
                    DisclosureChevron()
                }
                // nach dem Titel, aber vor dem Abstandhalter: sonst teilt sich die Kurzinfo den Platz mit ihm
                .layoutPriority(0.5)
            }
            .groupedRow()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title ?? page.title, value].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Öffnet \(page.title)")
    }
}

/// Inhalt einer Unterseite.
struct ProfilePageView: View {
    let page: ProfilePage
    let botID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        ProfileScaffold(page: page) {
            if let bot = store.bot(botID) {
                GroupedStack {
                    if page.isAllowed(store: store, botID: botID) {
                        content(bot)
                    } else {
                        GroupedSection(footer: "Diese Einstellung verwaltet der Admin des Scoops.") {
                            GroupedLabelRow(icon: "lock", title: "Für dich nicht verfügbar", titleColor: theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ bot: Bot) -> some View {
        switch page {
        case .library: LibraryList(chatID: botID)
        case .model: ProfileModelPage(bot: bot)
        case .personality: ProfilePersonalityPage(bot: bot)
        case .sharing: ProfileSharingPage(bot: bot)
        case .guestTools: GuestToolsSection(bot: bot)
        case .manage: ProfileManagePage(bot: bot)
        case .routines: ProfileRoutinesSection(bot: bot)
        case .skills: SkillList(botID: botID)
        case .memory: MemoryList(botID: botID)
        case .costs: CostSection(bot: bot)
        }
    }
}

// MARK: - Kurzinfos

@MainActor
enum ProfileSummary {
    /// Bibliothek: Anzahl Dateien und Links (nil, solange nicht geladen)
    static func library(store: AppStore, chatID: String) -> String? {
        guard let files = store.files[chatID] else { return nil }
        return files.isEmpty ? String(localized: "Leer", comment: "Bibliothek ohne Dateien") : "\(files.count)"
    }

    /// Persönlichkeit: gewählte Stimme
    static func voice(_ bot: Bot) -> String {
        let choice = VoiceChoice(bot.voice)
        if let live = choice.live {
            return live.isEmpty ? String(localized: "Standard", comment: "Standardstimme") : live.prefix(1).uppercased() + live.dropFirst()
        }
        if let id = choice.deviceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v.name }
        return String(localized: "Gerätestimme")
    }

    static func routines(store: AppStore, botID: String) -> String? {
        guard let list = store.routines[botID] else { return nil }
        let active = list.filter(\.enabled).count
        if list.isEmpty { return String(localized: "Keine", comment: "Kurzinfo: keine Einträge") }
        return active == list.count ? "\(active)" : String(localized: "\(active) von \(list.count) an", comment: "Routinen: aktive von allen")
    }

    static func count<T>(_ items: [T]?) -> String? {
        guard let items else { return nil }
        return items.isEmpty ? String(localized: "Keine", comment: "Kurzinfo: keine Einträge") : "\(items.count)"
    }
}

// MARK: - Routinen

/// Routinen eines Scoops, aktive zuerst und nach nächster Ausführung.
@MainActor
func sortedRoutines(store: AppStore, botID: String) -> [Routine] {
    (store.routines[botID] ?? []).sorted { a, b in
        if a.enabled != b.enabled { return a.enabled }
        return (a.nextRun ?? .distantFuture) < (b.nextRun ?? .distantFuture)
    }
}

/// Alle Routinen (Seite „Routinen“ unter „Verwalten“).
struct ProfileRoutinesSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let list = sortedRoutines(store: store, botID: bot.id)
        if list.isEmpty {
            GroupedSection("Routinen",
                           footer: "Sag \(bot.name) im Chat, was regelmäßig passieren soll, etwa „Jeden Morgen um 7:30 ein Briefing“.") {
                GroupedLabelRow(icon: "clock", title: "Keine Routinen", titleColor: theme.textSecondary)
            }
        } else {
            GroupedSection("Routinen", footer: "Halte eine Routine gedrückt, um sie sofort auszuführen, ihr ein eigenes Modell zu geben oder sie zu löschen. Neue Routinen legst du im Chat an.",
                           dividerInset: 50) {
                ForEach(list) { routine in RoutineRow(routine: routine) }
            }
        }
    }
}

// MARK: - Modell

/// Seite „Modell“: Anbieter/Modell wählen, darunter die Verstärkung (Eskalation) des Servers.
struct ProfileModelPage: View {
    let bot: Bot

    var body: some View {
        ModelPickerSections(bot: bot)
        ModelEscalationSection(bot: bot)
    }
}

/// Verstärkung: An welches Modell der Scoop bei schwierigen Aufgaben selbst abgibt (Werkzeug „eskalieren“).
/// Nur Anzeige; der Server legt das Eskalationsmodell beim Anlegen fest. Claude: einmal an `escalationModel`, sofern
/// es stärker ist; OpenAI: Schritt für Schritt an das nächststärkere Modell (Rang im Modellkatalog), sofern an.
struct ModelEscalationSection: View {
    let bot: Bot
    @Environment(\.theme) private var theme

    private var current: String { bot.model ?? BotModel.haiku.rawValue }

    private var catalog: ModelCatalog { ModelCatalogStore.shared.catalog }
    private var isOpenAI: Bool { BotModel.provider(for: current) == .openai }

    /// nil = Eskalation aus; leer = schon das stärkste Modell
    private var chain: [String]? {
        guard let escalation = bot.escalationModel, !escalation.isEmpty else { return nil }
        if isOpenAI {
            var steps: [String] = []
            var model = current
            while let next = catalog.nextStronger(model), !steps.contains(next) { steps.append(next); model = next }
            return steps
        }
        if escalation != current, catalog.isStronger(escalation, than: current) { return [escalation] }
        // Der Server gibt nie an ein schwächeres Modell ab
        return catalog.nextStronger(current) == nil ? [] : nil
    }

    var body: some View {
        GroupedSection(String(localized: "Verstärkung"), footer: footer) {
            GroupedLabelRow(icon: "arrow.up.forward.circle", title: String(localized: "Gibt ab an"), subtitle: subtitle) {
                Text(value)
                    .appFont(14.5)
                    .foregroundStyle(theme.textSecondary)
                    .adaptiveLineLimit(1)
            }
        }
    }

    private var value: String {
        guard let chain else { return String(localized: "Aus", comment: "Verstärkung ausgeschaltet") }
        return chain.first.map(BotModel.displayName(for:)) ?? "–"
    }

    private var subtitle: String? {
        guard let chain else { return nil }
        if chain.isEmpty { return String(localized: "Schon das stärkste Modell") }
        let rest = chain.dropFirst().map(BotModel.displayName(for:))
        guard let first = rest.first else { return nil }
        // „danach B, dann C, dann D“
        let steps = [String(localized: "danach \(first)", comment: "Nächste Stufe der Verstärkung")]
            + rest.dropFirst().map { name in String(localized: "dann \(name)", comment: "Weitere Stufe der Verstärkung") }
        return steps.joined(separator: ", ")
    }

    private var footer: String {
        let name = BotModel.displayName(for: current)
        guard let chain else { return String(localized: "\(bot.name) arbeitet immer mit \(name).") }
        if chain.isEmpty { return String(localized: "\(name) ist schon das stärkste Modell; \(bot.name) arbeitet immer damit.") }
        if isOpenAI {
            let names = catalog.selectable(of: .openai).map { $0.label.split(separator: " ").last.map(String.init) ?? $0.label }
            let steps = names.joined(separator: " → ")
            return String(localized: "Bei schwierigen Aufgaben gibt \(bot.name) selbst an das nächststärkere Modell ab: \(steps).")
        }
        guard let target = chain.first.map(BotModel.displayName(for:)) else {
            return String(localized: "\(name) reicht für die meisten Aufgaben. Wird es schwierig, gibt \(bot.name) selbst an das stärkere Modell ab.")
        }
        return String(localized: "\(name) reicht für die meisten Aufgaben. Wird es schwierig, gibt \(bot.name) selbst an \(target) ab.")
    }
}

// MARK: - Persönlichkeit

/// Seite „Persönlichkeit“: Aussehen, Stimme, Charakter.
struct ProfilePersonalityPage: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        GroupedSection("Aussehen") {
            Button {
                store.editingBot = bot
                store.showCreateBot = true
            } label: {
                HStack(spacing: 12) {
                    MascotView(mascot: bot.mascot, size: 30, seed: bot.id, animated: false)
                    Text("Aussehen bearbeiten").appFont(15).foregroundStyle(theme.textPrimary)
                    Spacer()
                    DisclosureChevron()
                }
                .groupedRow(vertical: 7)
            }
            .buttonStyle(.plain)
        }
        VoicePicker(bot: bot)
        CharacterEditor(bot: bot)
    }
}

// MARK: - Teilen

/// Seite „Teilen“: Personen und Einladungen, Werkzeuge für Geteilte (eigene Seite), Tageslimit, Kosten pro Person.
struct ProfileSharingPage: View {
    let bot: Bot
    @Environment(AppStore.self) private var store

    var body: some View {
        ShareSection(bot: bot)
        if store.sharingUnavailableReason == nil {
            GroupedSection(footer: "Welche Werkzeuge Läufe von Gästen nutzen dürfen.") {
                ProfileNavRow(page: .guestTools, value: GuestToolsSection.summary(store: store, bot: bot), title: String(localized: "Werkzeuge"))
            }
            .task(id: bot.id) {
                await store.loadSharingSettings(botID: bot.id)
                // Für „Kosten pro Person“ (ohne Personen bleibt der Abschnitt leer, sein eigenes Laden liefe nicht)
                await store.loadBotUsage(botID: bot.id)
            }
            GuestBudgetSection(bot: bot)
            CostSection(bot: bot, perPersonOnly: true)
        }
    }
}

// MARK: - Verwalten

/// Seite „Verwalten“: Haupt-Scoop, Routinen, Fähigkeiten, Gedächtnis, Kosten, Seitenleiste, Löschen.
/// Gäste: Kosten, mit „Bearbeiten“ auch Routinen/Fähigkeiten/Gedächtnis, und „Austreten“.
struct ProfileManagePage: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false

    private var guest: BotAccess? { store.access(for: bot.id) }
    private var canEdit: Bool { guest.map { $0.role.canEdit } ?? true }

    var body: some View {
        Group {
            if guest == nil {
                GroupedSection("Haupt-Scoop", footer: "Dein erster Ansprechpartner. Meldet sich von selbst, wenn etwas wichtig ist.") {
                    PrimaryToggleRows(bot: bot)
                }
                GroupedSection(String(localized: "Aufsicht"), footer: ReviewToggleRow.footer(bot)) {
                    ReviewToggleRow(bot: bot)
                }
            }
            GroupedSection(dividerInset: 50) {
                if canEdit {
                    ProfileNavRow(page: .routines, value: ProfileSummary.routines(store: store, botID: bot.id))
                    ProfileNavRow(page: .skills, value: ProfileSummary.count(store.skills[bot.id]))
                    ProfileNavRow(page: .memory, value: ProfileSummary.count(store.memories[bot.id]))
                }
                // Gäste: eigene Kosten (die Seite heißt dort „Deine Kosten“); kurzer Titel, damit „heute …“ in die Spalte passt
                ProfileNavRow(page: .costs, value: CostSection.summary(store: store, bot: bot))
            }
            if guest == nil { sidebarSection } else { leaveSection }
            // Als Vorlage weitergeben (nur eigene Scoops; Gäste können nicht exportieren)
            if store.canExportTemplate(bot.id) { TemplateExportSection(bot: bot) }
            if guest == nil { dangerSection }
        }
        .task(id: bot.id) { await store.loadBotUsage(botID: bot.id) }
        .confirmationDialog("Verlauf leeren?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Verlauf leeren", role: .destructive) { Task { await store.resetHistory(bot.id) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Nachrichten mit \(bot.name) werden gelöscht. Das Gedächtnis bleibt erhalten.")
        }
        .confirmationDialog("„\(bot.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Scoop löschen", role: .destructive) { Task { await store.deleteBot(bot.id) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Verlauf, Gedächtnis und Routinen werden endgültig gelöscht.")
        }
    }

    /// Anheften und Bereich (wie im Kontextmenü der Seitenleiste)
    private var sidebarSection: some View {
        GroupedSection("Seitenleiste", dividerInset: 50) {
            HStack(spacing: 12) {
                Image(systemName: "pin").appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary).scaledFrame(width: 22)
                Text("Angeheftet").appFont(15).foregroundStyle(theme.textPrimary)
                Spacer()
                Toggle("Angeheftet", isOn: Binding(get: { bot.pinned }, set: { on in
                    guard on != bot.pinned else { return }
                    Task { await store.togglePinned(bot) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
            }
            .groupedRow(vertical: 6)
            AdaptiveRow(spacing: 12, stackedSpacing: 2, trailingIndent: 34) {
                HStack(spacing: 12) {
                    Image(systemName: "folder").appFont(15, weight: .medium)
                        .foregroundStyle(theme.textSecondary).scaledFrame(width: 22)
                    Text("Bereich").appFont(15).foregroundStyle(theme.textPrimary).fixedSizeUnlessAccessibility()
                }
            } trailing: {
                Picker("Bereich", selection: Binding(get: { bot.trimmedSection ?? "" }, set: { name in
                    Task { await store.move(chatID: bot.id, toSection: name.isEmpty ? nil : name) }
                })) {
                    Text("Ohne").tag("")
                    ForEach(sectionNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(theme.textSecondary)
                .adaptiveLineLimit(1)
            }
            .groupedRow(vertical: 6)
        }
    }

    /// Bereiche der Seitenleiste (unabhängig von der Suche) plus der aktuelle des Scoops
    private var sectionNames: [String] {
        var names = store.sidebarSections.map(\.name)
        if let current = bot.trimmedSection, !names.contains(current) { names.append(current) }
        return names
    }

    private var dangerSection: some View {
        GroupedSection(footer: "Beim Löschen gehen Verlauf, Gedächtnis und Routinen verloren.", dividerInset: 50) {
            Button { confirmReset = true } label: {
                GroupedLabelRow(icon: "eraser", iconColor: theme.danger, title: "Verlauf leeren", titleColor: theme.danger)
            }
            .buttonStyle(.plain)
            Button { confirmDelete = true } label: {
                GroupedLabelRow(icon: "trash", iconColor: theme.danger, title: "Scoop löschen", titleColor: theme.danger)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var leaveSection: some View {
        if let share = store.share(for: bot.id) {
            let owner = guest?.ownerName ?? share.ownerName
            GroupedSection(footer: "Du siehst \(bot.name) danach nicht mehr. Der Verlauf bleibt bei \(owner).") {
                Button { confirmLeave = true } label: {
                    GroupedLabelRow(icon: "rectangle.portrait.and.arrow.right", iconColor: theme.danger,
                                    title: "Austreten", titleColor: theme.danger)
                }
                .buttonStyle(.plain)
            }
            .confirmationDialog("Aus „\(bot.name)“ austreten?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Austreten", role: .destructive) {
                    Task { if let error = await store.leave(share) { store.errorMessage = error } }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Du kannst nur mit einer neuen Einladung von \(share.ownerName) zurückkommen.")
            }
        }
    }
}
