import SwiftUI

/// Wofür der erste Scoop da ist: setzt Label und Charakter und bestimmt die Startnachrichten im nächsten Schritt.
struct OnboardingPurpose: Identifiable, Hashable {
    var id: String
    var title: LocalizedStringKey
    var icon: String
    /// Label des Scoops (z. B. „Recherche“)
    var label: String?
    /// Vorschlag für den Charakter
    var character: String
    /// Vorgeschlagene erste Nachrichten
    var starters: [String]

    static func == (a: OnboardingPurpose, b: OnboardingPurpose) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static var all: [OnboardingPurpose] { [
        .init(id: "alltag", title: "Alltag und Erinnerungen", icon: "checklist", label: String(localized: "Alltag"),
              character: String(localized: "freundlich, praktisch, denkt mit und erinnert mich an Dinge"),
              starters: [String(localized: "Was kannst du alles für mich tun?"),
                         String(localized: "Erinnere mich morgen um 9 an den Zahnarzt"),
                         String(localized: "Merk dir: Ich trinke keinen Kaffee")]),
        .init(id: "recherche", title: "Recherche", icon: "magnifyingglass", label: String(localized: "Recherche"),
              character: String(localized: "gründlich, neugierig, nennt seine Quellen"),
              starters: [String(localized: "Such mir drei einfache Rezepte für Kürbissuppe"),
                         String(localized: "Was gibt es Neues in der KI-Welt?"),
                         String(localized: "Was kannst du alles für mich tun?")]),
        .init(id: "schreiben", title: "Schreiben", icon: "pencil.line", label: String(localized: "Schreiben"),
              character: String(localized: "klar, freundlich und auf den Punkt"),
              starters: [String(localized: "Schreib eine kurze, freundliche Absage für ein Meeting"),
                         String(localized: "Hilf mir mit einem Text für eine Geburtstagskarte"),
                         String(localized: "Was kannst du alles für mich tun?")]),
        .init(id: "planen", title: "Planen und Organisieren", icon: "calendar", label: String(localized: "Planung"),
              character: String(localized: "strukturiert, motivierend, behält den Überblick"),
              starters: [String(localized: "Plan mit mir meine Woche"),
                         String(localized: "Mach mir eine Packliste für ein Wochenende am See"),
                         String(localized: "Was kannst du alles für mich tun?")]),
        .init(id: "lernen", title: "Lernen", icon: "graduationcap", label: String(localized: "Lernen"),
              character: String(localized: "geduldig, erklärt einfach und fragt nach"),
              starters: [String(localized: "Erklär mir einfach, wie ein Kredit funktioniert"),
                         String(localized: "Frag mich fünf englische Vokabeln ab"),
                         String(localized: "Was kannst du alles für mich tun?")]),
        .init(id: "frei", title: "Etwas anderes", icon: "sparkles", label: nil, character: "",
              starters: [String(localized: "Hallo! Wer bist du?"),
                         String(localized: "Was kannst du alles für mich tun?"),
                         String(localized: "Erzähl mir einen guten Witz")]),
    ] }

    static func find(_ id: String?) -> OnboardingPurpose? { all.first { $0.id == id } }
}

/// Schritt 4: ersten Scoop gestalten – Name, Aussehen (Figur, Farbe, Augen), wofür er da ist. Nutzt die Bausteine des
/// Scoop-Editors (MascotPickers.swift). Der Entwurf übersteht einen Neustart.
struct OnboardingScoopStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lookTab: LookTab = .shape
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private enum LookTab: Hashable { case shape, color, eyes }

    private static let nameIdeas = ["Fina", "Nova", "Momo", "Lumi", "Bruno", "Pixel"]

    var body: some View {
        Group {
            if let id = store.onboarding.firstBotID, let bot = store.bot(id) {
                createdView(bot)
            } else if creating, let draft = store.onboarding.draft {
                hatchingView(draft)
            } else {
                editor
            }
        }
        .onAppear(perform: prepareDraft)
    }

    private func prepareDraft() {
        let onboarding = store.onboarding
        if onboarding.draft == nil { onboarding.draft = .init(mascot: Mascot.random()) }
        if let page = onboarding.demoScoopPage {
            onboarding.demoScoopPage = nil
            var draft = onboarding.draft!
            switch page {
            case "look", "purpose":
                // Screenshots: Fina wie Figur 06 „Creme“
                draft.page = page == "look" ? 1 : 2
                if draft.name.isEmpty { draft.name = "Fina" }
                var m = Mascot(shape: "circle", color: "#F1DDBB", eyes: "cat", accessory: "none")
                m.mouth = "smile"
                m.gaze = "right"
                draft.mascot = m
            default: draft.page = 0
            }
            onboarding.draft = draft
        }
    }

    /// Bindung an den Entwurf (legt ihn bei Bedarf an)
    private var draft: Binding<OnboardingState.ScoopDraft> {
        Binding(get: { store.onboarding.draft ?? .init(mascot: Mascot.default) },
                set: { store.onboarding.draft = $0 })
    }

    private var displayName: String {
        let name = draft.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "dein Scoop") : name
    }

    // MARK: Editor

    private var editor: some View {
        let page = draft.wrappedValue.page
        return OnboardingPage(scrollTarget: page == 0 && nameFocused ? "nameField" : nil) {
            preview
            Group {
                switch page {
                case 0: namePage
                case 1: lookPage
                default: purposePage
                }
            }
            .id(page)
            .transition(.opacity)
        } actions: {
            subPageDots(page)
            if page < 2 {
                Button("Weiter") { turn(to: page + 1) }
                    .buttonStyle(OnboardingButtonStyle())
                    .disabled(draft.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { Task { await create() } } label: {
                    Text("\(displayName) erstellen")
                }
                .buttonStyle(OnboardingButtonStyle())
                .disabled(creating || store.phase != .online)
                .keyboardShortcut(.defaultAction)
                if store.phase != .online {
                    Text("Keine Verbindung zum Server. Die App verbindet sich gleich neu.")
                        .font(.footnote)
                        .foregroundStyle(theme.warning)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: page)
    }

    private func turn(to page: Int) {
        nameFocused = false
        draft.wrappedValue.page = page
    }

    private var preview: some View {
        VStack(spacing: 8) {
            MascotView(mascot: draft.wrappedValue.mascot, size: 116, seed: "onboarding-draft", showsGround: true)
                .animation(.spring(duration: 0.35, bounce: 0.4), value: draft.wrappedValue.mascot)
                .accessibilityHidden(true)
            if draft.wrappedValue.page > 0 {
                Text(displayName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .padding(.top, 12)
    }

    private func subPageDots(_ page: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == page ? theme.textPrimary : theme.surfaceBorder)
                    .frame(width: i == page ? 18 : 7, height: 7)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Teil \(page + 1) von 3")
    }

    // MARK: Name

    private var namePage: some View {
        VStack(spacing: 18) {
            OnboardingTitle(title: "Wie soll dein Scoop heißen?",
                            text: "Pip ist schon da und hilft dir beim Start. Jetzt gestaltest du deinen ganz eigenen Scoop.")
            TextField("Name deines Scoops", text: draft.name)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(nameFocused ? theme.accent : theme.surfaceBorder, lineWidth: nameFocused ? 1.5 : 1))
                .focused($nameFocused)
                .submitLabel(.next)
                .onSubmit { if !draft.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty { turn(to: 1) } }
                .frame(maxWidth: 360)
                .id("nameField")
            VStack(spacing: 8) {
                Text("Oder nimm einen Vorschlag:")
                    .font(.footnote)
                    .foregroundStyle(theme.textTertiary)
                ChipFlow(spacing: 8) {
                    ForEach(Self.nameIdeas, id: \.self) { idea in
                        chip(idea, selected: draft.wrappedValue.name == idea) { draft.wrappedValue.name = idea }
                    }
                }
            }
        }
        #if os(macOS)
        // iPhone/iPad: nicht sofort die Tastatur, sonst verdeckt sie die Namensvorschläge
        .onAppear { if draft.wrappedValue.name.isEmpty { nameFocused = true } }
        #endif
    }

    // MARK: Aussehen

    private var lookPage: some View {
        VStack(spacing: 16) {
            OnboardingTitle(title: "Wie sieht \(displayName) aus?", text: "Such dir Figur, Farbe und Augen aus. Ändern kannst du das jederzeit.")
            HStack(spacing: 10) {
                Picker("Aussehen", selection: $lookTab) {
                    Text("Figur").tag(LookTab.shape)
                    Text("Farbe").tag(LookTab.color)
                    Text("Augen").tag(LookTab.eyes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    draft.wrappedValue.mascot = Mascot.random()
                } label: {
                    Image(systemName: "dice")
                        .font(.system(.body, weight: .semibold))
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help("Zufälliges Aussehen")
                .accessibilityLabel("Zufälliges Aussehen")
            }
            .frame(maxWidth: 420)
            Group {
                switch lookTab {
                case .shape:
                    MascotShapeGrid(mascot: draft.mascot, shapes: Mascot.organicShapes + Mascot.geometricShapes, previewSize: 44)
                case .color:
                    MascotColorPalette(mascot: draft.mascot)
                        .frame(maxWidth: .infinity)
                case .eyes:
                    MascotEyeGrid(mascot: draft.mascot, columns: 5)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .themedCard(theme, radius: 20)
        }
    }

    // MARK: Zweck

    private var purposePage: some View {
        VStack(spacing: 16) {
            OnboardingTitle(title: "Wobei hilft dir \(displayName)?", text: "Damit weiß \(displayName), worauf es ankommt. Du kannst ihn trotzdem alles fragen.")
            // Bedienungshilfen-Schriftgrößen: eine Spalte, sonst zerbrechen die Wörter in den schmalen Kacheln
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150), spacing: 10)],
                      spacing: 10) {
                ForEach(OnboardingPurpose.all) { purpose in
                    purposeTile(purpose)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Charakter (optional)")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                TextField("Wie soll dein Scoop sein? Etwa „locker, präzise, duzt“", text: draft.character, axis: .vertical)
                    .lineLimit(2...4)
                    .modifier(FieldStyle(alignment: .leading))
            }
        }
    }

    private func purposeTile(_ purpose: OnboardingPurpose) -> some View {
        let selected = draft.wrappedValue.purpose == purpose.id
        return Button {
            var d = draft.wrappedValue
            let previous = OnboardingPurpose.find(d.purpose)
            d.purpose = purpose.id
            // Charakter nur ersetzen, solange er noch der Vorschlag des vorherigen Zwecks (oder leer) ist
            if d.character.isEmpty || d.character == previous?.character { d.character = purpose.character }
            draft.wrappedValue = d
        } label: {
            HStack(spacing: 8) {
                Image(systemName: purpose.icon)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(selected ? theme.sendButtonIcon : theme.accent)
                    .frame(minWidth: 22)
                // Höchstens zwei Zeilen, notfalls etwas kleiner: Bei rund 155 pt breiten Kacheln (iPhone Duo zu- und
                // aufgeklappt) trennte das System sonst „Erinnerun-gen“ und „Organisie-ren“.
                Text(purpose.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(selected ? theme.sendButtonIcon : theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 54)
            .background(selected ? theme.sendButton : theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? .clear : theme.surfaceBorder))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(selected ? theme.sendButtonIcon : theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? theme.sendButton : theme.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : theme.surfaceBorder))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Erstellen

    private func create() async {
        guard let d = store.onboarding.draft, !creating else { return }
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { turn(to: 0); return }
        creating = true
        let purpose = OnboardingPurpose.find(d.purpose)
        let character = d.character.trimmingCharacters(in: .whitespacesAndNewlines)
        var mascot = d.mascot
        mascot.photo = nil
        // Modell: Standard des Servers (OpenAI-only-Server nutzen dann GPT)
        let bot = await store.createBot(BotDraft(name: name, label: purpose?.label, mascot: mascot,
                                                 character: character.isEmpty ? nil : character, model: nil))
        creating = false
        guard let bot else { return }
        store.onboarding.firstBotID = bot.id
        store.onboarding.advance()
    }

    private func hatchingView(_ draft: OnboardingState.ScoopDraft) -> some View {
        OnboardingPage {
            MascotView(mascot: draft.mascot, size: 130, mood: .working, seed: "onboarding-draft", showsGround: true)
                .padding(.top, 50)
                .accessibilityHidden(true)
            OnboardingTitle(title: "\(displayName) schlüpft …", text: "Einen Moment, dein Scoop zieht gerade auf deinem Server ein.")
            ProgressView()
        } actions: {
            EmptyView()
        }
    }

    /// Scoop ist schon erstellt (z. B. zurück aus „Erste Nachricht“)
    private func createdView(_ bot: Bot) -> some View {
        OnboardingPage {
            MascotView(mascot: bot.mascot, size: 130, seed: bot.id, showsGround: true)
                .padding(.top, 40)
                .accessibilityHidden(true)
            OnboardingTitle(title: "\(bot.name) ist da!", text: "Aussehen und Charakter kannst du jederzeit im Profil ändern.")
        } actions: {
            Button("Weiter") { store.onboarding.go(to: .message) }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
            Button("Aussehen bearbeiten") {
                store.editingBot = bot
                store.showCreateBot = true
            }
            .buttonStyle(OnboardingButtonStyle(kind: .plain))
        }
    }
}

/// Einfache Fließ-Anordnung für Vorschlags-Chips (zentriert, bricht um)
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
