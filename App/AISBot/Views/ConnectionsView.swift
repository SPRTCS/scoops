import SwiftUI
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Einstellungen → „Apps verbinden“ (wie „Connect apps“ bei Grok): alle Apps aus dem Composio-Katalog mit
/// Kategorie-Chips und Suche, eigene Konten je App (aufklappen, umbenennen, trennen) und fest eingerichtete Verbindungen.
struct ConnectionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var catalog = ConnectionCatalogModel()
    @State private var expanded: Set<String> = []
    @State private var namePrompt: NamePrompt?
    @State private var aliasInput = ""
    @State private var renameTarget: ConnectedAccount?
    @State private var deleteTarget: (account: ConnectedAccount, app: CatalogApp)?
    @State private var formTarget: FormTarget?
    @State private var notice: Notice?
    @State private var busySlug: String?
    @State private var errorText: String?
    @State private var toast: String?
    @State private var login = WebLoginSession()
    @State private var didStart = false
    @FocusState private var searchFocused: Bool

    /// Name abfragen, bevor ein Konto per Browser verbunden wird.
    struct NamePrompt: Identifiable { let app: CatalogApp; var id: String { app.slug } }
    /// Formular für Apps mit API-Schlüssel o. Ä.
    struct FormTarget: Identifiable { let app: CatalogApp; let info: AppAuthInfo; var id: String { app.slug } }
    /// Hinweis (keine Anmeldung nötig / nicht verfügbar).
    struct Notice: Identifiable { let title: String; let message: String; var id: String { title } }

    private var overview: ConnectionsOverview? { store.connections }
    private var args: [String] { ProcessInfo.processInfo.arguments }
    private func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Apps verbinden", icon: "link", trailing: { headerTrailing }, onClose: { dismiss() })
            chipBar
            // Fehler fest unter den Chips (bleibt sichtbar, auch wenn die Liste gescrollt ist)
            if let error = errorText ?? catalog.error ?? (catalog.legacy ? store.connectionsError : nil) {
                errorBanner(error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 680)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            list
            searchBar
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 600, height: 760)
        #endif
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.sendButtonIcon)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.sendButton, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
        .animation(.snappy, value: errorText)
        .task { await start() }
        .task(id: catalog.query) {
            // Suche: kurz warten, bis das Tippen pausiert
            guard didStart else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await catalog.reload(store.service, overview: overview, quiet: true)
        }
        // Name des neuen Kontos (Anmeldung im Browser)
        .alert("\(namePrompt?.app.name ?? "") verbinden", isPresented: Binding(get: { namePrompt != nil },
                                                                          set: { if !$0 { namePrompt = nil } })) {
            TextField("z. B. privat, arbeit", text: $aliasInput)
                .autocorrectionDisabled()
            Button("Weiter") {
                if let app = namePrompt?.app { startLink(app, alias: aliasInput) }
                namePrompt = nil
            }
            Button("Abbrechen", role: .cancel) { namePrompt = nil }
        } message: {
            Text("Optionaler Name. Über diesen Namen sagst du den Scoops, welches Konto sie nehmen sollen.")
        }
        // Umbenennen
        .alert("Konto umbenennen", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $aliasInput)
                .autocorrectionDisabled()
            Button("Umbenennen") {
                if let acc = renameTarget {
                    let name = aliasInput.trimmingCharacters(in: .whitespaces)
                    Task {
                        errorText = await store.renameConnectedAccount(acc.id, alias: name)
                        await catalog.reload(store.service, overview: overview, quiet: true)
                    }
                }
                renameTarget = nil
            }
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Über diesen Namen sagst du den Scoops, welches Konto sie nehmen sollen.")
        }
        // Trennen
        .confirmationDialog(deleteTarget.map { "\($0.app.name) · \($0.account.displayName) trennen?" } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Trennen", role: .destructive) {
                if let t = deleteTarget {
                    Task {
                        errorText = await store.deleteConnectedAccount(t.account.id)
                        await catalog.reload(store.service, overview: overview, quiet: true)
                    }
                }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Die Scoops können dieses Konto dann nicht mehr nutzen.")
        }
        // Keine Anmeldung nötig / nicht verfügbar
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
        // Formular für Schlüssel-Apps
        .sheet(item: $formTarget) { target in
            ConnectFieldsSheet(app: target.app, info: target.info) { title in
                show(toast: "\(title) verbunden")
                expanded.insert(target.app.slug)
                Task { await refresh(fresh: true) }
            }
            .environment(store)
            .environment(\.theme, theme)
        }
    }

    // MARK: Laden

    private func start() async {
        if let c = arg("-connectionscategory") { catalog.selected = c }
        if let q = arg("-connectionsquery") { catalog.query = q }
        if let e = arg("-connectionsexpand") { expanded.insert(e) }
        let cats = Task { await catalog.loadCategories(store.service) }
        let first = Task { await catalog.reload(store.service, overview: overview) }
        await store.loadConnections(fresh: true)
        await cats.value
        await first.value
        didStart = true
        // Konten frisch von Composio: Liste still nachziehen (Status, Anzahl)
        await catalog.reload(store.service, overview: overview, quiet: true)
        if let slug = arg("-connectionsform"), let app = catalog.items.first(where: { $0.slug == slug })
            ?? PreviewData.catalogApps.first(where: { $0.slug == slug }) {
            begin(app)
        }
    }

    private func refresh(fresh: Bool) async {
        await store.loadConnections(fresh: fresh)
        await catalog.reload(store.service, overview: overview, quiet: true)
    }

    private func select(_ id: String) {
        guard id != catalog.selected || catalog.isSearching else { return }
        searchFocused = false
        catalog.query = ""
        catalog.selected = id
        Task { await catalog.reload(store.service, overview: overview) }
    }

    // MARK: Kopf, Chips, Suche

    @ViewBuilder
    private var headerTrailing: some View {
        if catalog.loading || store.loadingConnections { ProgressView().controlSize(.small) }
        if catalog.connectedApps > 0 {
            let on = catalog.selected == CatalogCategory.connected && !catalog.isSearching
            Button { select(CatalogCategory.connected) } label: {
                HStack(spacing: 6) {
                    Circle().fill(theme.success).frame(width: 7, height: 7)
                    Text("\(catalog.connectedApps) verbunden")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(theme.success.opacity(on ? 0.24 : 0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.success.opacity(on ? 0.6 : 0), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(catalog.connectedApps) Apps verbunden, nur verbundene zeigen")
        }
    }

    private var chipBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(catalog.chips) { chip in
                        chipButton(chip).id(chip.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onChange(of: catalog.selected) { _, id in withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
        }
        .padding(.bottom, 12)
    }

    private func chipButton(_ chip: CatalogCategory) -> some View {
        let on = chip.id == catalog.selected && !catalog.isSearching
        return Button { select(chip.id) } label: {
            HStack(spacing: 5) {
                if chip.id == CatalogCategory.popular {
                    Image(systemName: "star.fill").font(.system(size: 10.5, weight: .semibold))
                } else if chip.id == CatalogCategory.connected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
                } else if chip.id == CatalogCategory.apple {
                    Image(systemName: "apple.logo").font(.system(size: 11, weight: .semibold))
                }
                Text(chip.displayName).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(on ? theme.groupedBackground : theme.textPrimary)
            .padding(.horizontal, 13).padding(.vertical, 7.5)
            .background(on ? theme.textPrimary : theme.groupedCard, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : theme.surfaceBorder, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.displayName)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            TextField("Alle Apps durchsuchen", text: Binding(get: { catalog.query }, set: { catalog.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 15.5))
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused($searchFocused)
            if !catalog.query.isEmpty {
                Button { catalog.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.surfaceBorder, lineWidth: 0.75))
        .shadow(color: theme.cardShadow, radius: 8, y: 2)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    // MARK: Liste

    private var showsApple: Bool { catalog.selected == CatalogCategory.apple && !catalog.isSearching }
    private var showsBuiltin: Bool {
        !catalog.isSearching && (catalog.selected == CatalogCategory.popular || catalog.selected == CatalogCategory.connected)
    }

    private var listTitle: String {
        if catalog.isSearching { return "Suchergebnisse" }
        return catalog.chips.first { $0.id == catalog.selected }?.displayName
            ?? CatalogCategory(id: catalog.selected, name: catalog.selected).displayName
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GroupedMetrics.sectionSpacing) {
                if showsApple {
                    ConnectionsAppleSlot()
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text(listTitle.uppercased())
                            if catalog.loaded, catalog.total > 0 { Text("\(catalog.total)").monospacedDigit() }
                        }
                        .font(.system(size: 12, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, GroupedMetrics.rowInset)
                        .accessibilityAddTraits(.isHeader)
                        appCard
                    }
                }
                if showsBuiltin, let builtin = overview?.builtin, !builtin.isEmpty { builtinSection(builtin) }
                // Eigene MCP-Server (Server 1.35): unter „Fest verbunden“, auf „Beliebt“ und „Verbunden“
                if showsBuiltin { CustomMCPSection(onToast: { show(toast: $0) }) }
                if catalog.loaded, !showsApple {
                    Text("Die Anmeldung läuft sicher über Composio. Die Scoops sehen nur die Konten, nie deine Passwörter.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refresh(fresh: true) }
        .modifier(SwipeContainer())
    }

    @ViewBuilder
    private var appCard: some View {
        if catalog.items.isEmpty {
            emptyState
        } else {
            // Lazy: der Katalog hat weit über 1000 Apps; Zeilen und Logos entstehen erst beim Scrollen.
            LazyVStack(spacing: 0) {
                ForEach(Array(catalog.items.enumerated()), id: \.element.slug) { index, app in
                    if index > 0 { GroupedDivider(inset: 70) }
                    appRow(app)
                    if expanded.contains(app.slug), app.isConnected { accountRows(app) }
                }
                if catalog.hasMore {
                    GroupedDivider(inset: 70)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Weitere Apps laden …").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    .groupedRow()
                    .frame(maxWidth: .infinity)
                    .onAppear { Task { await catalog.loadMore(store.service) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
                .strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if !catalog.loaded || catalog.loading {
                ProgressView()
            } else if catalog.isSearching {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(theme.textTertiary)
                Text("Keine App gefunden für „\(catalog.query.trimmingCharacters(in: .whitespaces))“.")
                    .font(.system(size: 14.5)).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            } else if catalog.selected == CatalogCategory.connected {
                Image(systemName: "link").font(.system(size: 26)).foregroundStyle(theme.textTertiary)
                Text("Noch keine App verbunden.").font(.system(size: 14.5)).foregroundStyle(theme.textSecondary)
                Button("Beliebte Apps ansehen") { select(CatalogCategory.popular) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            } else {
                Text("In dieser Kategorie gibt es keine Apps.").font(.system(size: 14.5)).foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
    }

    private func appRow(_ app: CatalogApp) -> some View {
        HStack(spacing: 12) {
            AppLogo(slug: app.slug, name: app.name, symbol: app.symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let d = app.detail, !d.isEmpty {
                    Text(d).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            rowControl(app)
        }
        .groupedRow(vertical: 10)
        .onTapGesture { if app.isConnected { toggle(app) } }
    }

    @ViewBuilder
    private func rowControl(_ app: CatalogApp) -> some View {
        if busySlug == app.slug {
            ProgressView().controlSize(.small).frame(minWidth: 44)
        } else if app.isConnected {
            let open = expanded.contains(app.slug)
            let problem = app.accounts.contains { $0.state == .problem }
            let pending = !problem && app.accounts.allSatisfy { $0.state == .pending }
            Button { toggle(app) } label: {
                HStack(spacing: 5) {
                    Image(systemName: problem ? "exclamationmark.circle.fill" : (pending ? "clock.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(problem ? theme.warning : (pending ? theme.textTertiary : theme.success))
                        .accessibilityHidden(true)
                    Text(app.accounts.count > 1 ? "\(app.accounts.count) Konten" : (pending ? "Ausstehend" : "Verbunden"))
                        .foregroundStyle(theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(theme.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.surfaceBorder))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(app.name): \(app.accounts.count == 1 ? "1 Konto" : "\(app.accounts.count) Konten"), \(open ? "zuklappen" : "aufklappen")")
        } else if app.authKind == .none {
            Text("Ohne Anmeldung").font(.system(size: 12.5)).foregroundStyle(theme.textTertiary)
                .lineLimit(1).fixedSize()
                .onTapGesture { begin(app) }
        } else {
            Button("Verbinden") { begin(app) }
                .lineLimit(1)
                .fixedSize()
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .accessibilityLabel("\(app.name) verbinden")
                .disabled(login.isActive)
        }
    }

    private func toggle(_ app: CatalogApp) {
        withAnimation(.snappy) {
            if expanded.contains(app.slug) { expanded.remove(app.slug) } else { expanded.insert(app.slug) }
        }
    }

    /// Konten einer verbundenen App (aufgeklappt) und „Konto hinzufügen“.
    @ViewBuilder
    private func accountRows(_ app: CatalogApp) -> some View {
        ForEach(app.accounts) { account in
            GroupedDivider(inset: 70)
            accountRow(account, app: app)
        }
        GroupedDivider(inset: 70)
        Button { begin(app) } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.system(size: 18))
                    .foregroundStyle(app.canAdd ? theme.accent : theme.textTertiary)
                    .frame(width: 40)
                Text("Konto hinzufügen")
                    .font(.system(size: 15))
                    .foregroundStyle(app.canAdd ? theme.accent : theme.textTertiary)
                Spacer()
                if !app.canAdd {
                    Text("Höchstens \(catalog.maxPerApp) Konten").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
            .groupedRow()
        }
        .buttonStyle(.plain)
        .disabled(!app.canAdd || login.isActive)
    }

    private func accountRow(_ account: ConnectedAccount, app: CatalogApp) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: color(account.state))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                if let email = account.email, !email.isEmpty {
                    Text(email).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            switch account.state {
            case .active:
                Text("Aktiv").font(.system(size: 12.5)).foregroundStyle(theme.textTertiary)
            case .problem:
                Button { startReconnect(account, app: app) } label: {
                    Text("Neu anmelden").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.warning)
            case .pending:
                Text("Anmeldung läuft").font(.system(size: 12.5)).foregroundStyle(theme.textTertiary)
            }
            Menu {
                accountMenu(account, app: app)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(theme.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aktionen für \(account.displayName)")
        }
        .groupedRow(vertical: 8)
        .background(theme.groupedBackground.opacity(0.35))
        .contextMenu { accountMenu(account, app: app) }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteTarget = (account, app) } label: { Label("Trennen", systemImage: "trash") }
            Button { aliasInput = account.alias ?? ""; renameTarget = account } label: { Label("Umbenennen", systemImage: "pencil") }
        }
        #endif
    }

    @ViewBuilder
    private func accountMenu(_ account: ConnectedAccount, app: CatalogApp) -> some View {
        Button { aliasInput = account.alias ?? ""; renameTarget = account } label: { Label("Umbenennen", systemImage: "pencil") }
        if app.authKind != .fields {
            Button { startReconnect(account, app: app) } label: { Label("Neu anmelden", systemImage: "arrow.clockwise") }
        }
        Divider()
        Button(role: .destructive) { deleteTarget = (account, app) } label: { Label("Trennen", systemImage: "trash") }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
            Text(text).font(.system(size: 13.5)).foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { errorText = nil; Task { await refresh(fresh: true) } } label: {
                if store.loadingConnections || catalog.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Neu versuchen").font(.system(size: 13, weight: .semibold))
                }
            }
            .disabled(store.loadingConnections || catalog.loading)
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
        }
        .padding(14)
        .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
    }

    private func builtinSection(_ list: [BuiltinConnection]) -> some View {
        GroupedSection("Fest verbunden", footer: "Diese Verbindungen sind auf dem Server eingerichtet und lassen sich hier nicht ändern.",
                       dividerInset: 68) {
            ForEach(list) { b in
                HStack(spacing: 12) {
                    AppLogo(slug: "builtin-\(b.id)", name: b.name, symbol: b.symbol ?? "server.rack", size: 40, remote: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                        if let d = b.detail, !d.isEmpty {
                            Text(d).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    if let t = b.tools, t > 0 {
                        Text(t == 1 ? "1 Werkzeug" : "\(t) Werkzeuge").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                    StatusDot(color: builtinColor(b.status))
                        .accessibilityLabel(b.status == "ok" ? "verbunden" : (b.status == "error" ? "Fehler" : "aus"))
                }
                .groupedRow(vertical: 9)
            }
        }
    }

    private func color(_ state: ConnectedAccount.State) -> Color {
        switch state {
        case .active: theme.success
        case .problem: theme.warning
        case .pending: theme.textTertiary
        }
    }

    private func builtinColor(_ status: String) -> Color {
        switch status {
        case "ok": theme.success
        case "error": theme.warning
        default: theme.textTertiary
        }
    }

    private func show(toast text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    // MARK: Verbinden

    /// Verbinden je nach Anmeldeart: Browser (Name abfragen), Formular (Felder vom Server) oder Hinweis.
    private func begin(_ app: CatalogApp) {
        errorText = nil
        if app.authKind == .oauth {
            aliasInput = ""
            namePrompt = NamePrompt(app: app)
            return
        }
        guard let service = store.service else { errorText = "Keine Verbindung zum Server."; return }
        busySlug = app.slug
        Task {
            defer { busySlug = nil }
            do {
                let info = try await service.connectionAuth(app: app.slug)
                switch info.auth {
                case "fields": formTarget = FormTarget(app: app, info: info)
                case "oauth":
                    aliasInput = ""
                    namePrompt = NamePrompt(app: app)
                default:
                    notice = Notice(title: app.name, message: info.message
                                    ?? "\(app.name) lässt sich hier im Moment nicht verbinden.")
                }
            } catch {
                errorText = store.message(error)
            }
        }
    }

    private func startLink(_ app: CatalogApp, alias: String) {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        Task {
            switch await store.linkConnection(app: app.slug, alias: clean.isEmpty ? nil : clean) {
            case .success(let link): run(link, title: "\(app.name)\(clean.isEmpty ? "" : " · \(clean)")", slug: app.slug)
            case .failure(let e): errorText = e.message
            }
            await refresh(fresh: false)
        }
    }

    private func startReconnect(_ account: ConnectedAccount, app: CatalogApp) {
        errorText = nil
        Task {
            switch await store.reconnectAccount(account.id) {
            case .success(let link): run(link, title: "\(app.name) · \(account.displayName)", slug: app.slug)
            case .failure(let e): errorText = e.message
            }
            await refresh(fresh: false)
        }
    }

    /// Öffnet die Anmeldung und fragt alle 3 s den Status ab; bei „active“ wird das Fenster geschlossen.
    /// Mit Rücksprung-Schema (Notion direkt, Server 1.25): Das Fenster schließt beim Rücksprung, die App gibt ihn an
    /// den Server weiter, der die Anmeldung abschließt.
    private func run(_ link: ConnectionLink, title: String, slug: String) {
        guard let url = URL(string: link.url) else { errorText = "Der Server hat keinen gültigen Anmelde-Link geliefert."; return }
        if let scheme = link.callbackScheme, !scheme.isEmpty {
            busySlug = slug
            login.start(url: url, callbackScheme: scheme) { callback in
                Task {
                    defer { busySlug = nil }
                    guard let callback else { return }  // abgebrochen: nichts zu tun
                    switch await store.finishOAuth(callback) {
                    case .success:
                        expanded.insert(slug)
                        show(toast: "\(title) verbunden")
                    case .failure(let e):
                        errorText = e.message
                    }
                    await refresh(fresh: true)
                }
            }
            return
        }
        login.start(url: url) {
            // Fenster geschlossen (vom Nutzer oder nach Erfolg). Eine abgebrochene Anmeldung hinterlässt ein
            // Konto im Zustand „initializing“: das gleich wieder entfernen, damit nichts liegen bleibt.
            Task {
                if let acc = await store.connectedAccountStatus(link.accountId),
                   ["initializing", "initiated"].contains(acc.status) {
                    _ = await store.deleteConnectedAccount(link.accountId)
                }
                await refresh(fresh: true)
            }
        }
        Task {
            while login.isActive {
                try? await Task.sleep(for: .seconds(3))
                guard login.isActive, let account = await store.connectedAccountStatus(link.accountId) else { continue }
                if account.status == "active" {
                    login.finish()
                    expanded.insert(slug)
                    show(toast: "\(title) verbunden")
                    await refresh(fresh: true)
                    return
                }
                if account.status == "failed" {
                    login.finish()
                    errorText = "Die Anmeldung bei \(title) hat nicht geklappt. Bitte versuche es noch einmal."
                    await refresh(fresh: true)
                    return
                }
            }
        }
    }
}

/// Formular für Apps mit API-Schlüssel, Token oder Benutzername/Passwort. Die Werte gehen über den eigenen Server
/// direkt an Composio; die App speichert sie nicht und vergisst sie beim Schließen.
struct ConnectFieldsSheet: View {
    let app: CatalogApp
    let info: AppAuthInfo
    var onDone: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var alias = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: String?

    private var canSubmit: Bool {
        info.fields.allSatisfy { !$0.required || !(values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("\(info.name) verbinden", onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: GroupedMetrics.sectionSpacing) {
                    HStack(spacing: 14) {
                        AppLogo(slug: app.slug, name: app.name, symbol: app.symbol, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Text(schemeLabel).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, GroupedMetrics.rowInset)

                    GroupedSection("Zugangsdaten") {
                        ForEach(info.fields) { field in fieldRow(field) }
                    }

                    GroupedSection("Name (optional)",
                                   footer: "Über diesen Namen sagst du den Scoops, welches Konto sie nehmen sollen.") {
                        TextField("z. B. privat, arbeit", text: $alias)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .autocorrectionDisabled()
                            .focused($focus, equals: "_alias")
                            .groupedRow()
                    }

                    if let guide = info.guideUrl, let url = URL(string: guide) {
                        Link(destination: url) {
                            Label("Wo finde ich die Angaben?", systemImage: "questionmark.circle")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, GroupedMetrics.rowInset)
                    }

                    if let error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                            Text(error).font(.system(size: 13.5)).foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.warning.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
                    }

                    Label("Die Angaben gehen direkt an Composio. Dein Server speichert sie nicht und schreibt sie in kein Protokoll.",
                          systemImage: "lock.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, GroupedMetrics.rowInset)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            HStack(spacing: 10) {
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button { submit() } label: {
                    if busy { ProgressView().controlSize(.small).tint(theme.sendButtonIcon) } else { Text("Verbinden") }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!canSubmit || busy)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 480, height: 600)
        #else
        .presentationDetents([.large])
        #endif
        .onAppear {
            for f in info.fields where !f.secret { if let d = f.defaultValue { values[f.name] = d } }
            focus = info.fields.first?.name
        }
        .onDisappear { values = [:] }
    }

    private var schemeLabel: String {
        switch info.scheme ?? "" {
        case "BEARER_TOKEN": "Mit Zugangs-Token verbinden"
        case "BASIC", "BASIC_WITH_JWT": "Mit Benutzername und Passwort verbinden"
        default: "Mit API-Schlüssel verbinden"
        }
    }

    private func binding(_ f: AuthField) -> Binding<String> {
        Binding(get: { values[f.name] ?? "" }, set: { values[f.name] = $0; error = nil })
    }

    private func fieldRow(_ f: AuthField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(f.required ? f.label : "\(f.label) (optional)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Group {
                if f.secret {
                    SecureField(f.label, text: binding(f))
                } else {
                    TextField(f.defaultValue ?? f.label, text: binding(f))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15.5))
            .foregroundStyle(theme.textPrimary)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($focus, equals: f.name)
            .onSubmit { submitIfReady() }
            if let d = f.description, !d.isEmpty {
                Text(d).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .groupedRow(vertical: 11)
    }

    private func submitIfReady() { if canSubmit, !busy { submit() } }

    private func submit() {
        guard let service = store.service else { error = "Keine Verbindung zum Server."; return }
        let fields = info.fields.compactMap { f -> AuthFieldValue? in
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : AuthFieldValue(name: f.name, value: v)
        }
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await service.connectWithFields(app: app.slug, alias: name.isEmpty ? nil : name, fields: fields)
                values = [:]
                onDone(name.isEmpty ? info.name : "\(info.name) · \(name)")
                dismiss()
            } catch {
                self.error = store.message(error)
            }
        }
    }
}

/// Runder Status-Punkt.
private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().fill(color.opacity(0.25)).frame(width: 17, height: 17))
    }
}

/// Anmeldung im System-Browserfenster (ASWebAuthenticationSession). Es gibt keinen Rücksprung-Link:
/// Das Fenster wird nach erfolgreichem Status-Polling per `finish()` geschlossen oder vom Nutzer.
@MainActor
@Observable
final class WebLoginSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var isActive = false
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var onClose: (() -> Void)?
    @ObservationIgnored private var catcher: LoopbackCatcher?
    @ObservationIgnored private var loopbackCallback: ((URL?) -> Void)?

    func start(url: URL, onClose: @escaping () -> Void) {
        finish()
        self.onClose = onClose
        // Rücksprung-Schema, das nie aufgerufen wird: Das Fenster bleibt offen, bis wir es schließen.
        let s = ASWebAuthenticationSession(url: url, callback: .customScheme("aisbot-login")) { [weak self] _, _ in
            Task { @MainActor in self?.closed() }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        isActive = s.start()
        if !isActive { closed() }
    }

    /// Anmeldung mit Rücksprung (`<scheme>://…`): `onCallback` bekommt die Rücksprung-Adresse, bei Abbruch nil.
    func start(url: URL, callbackScheme: String, onCallback: @escaping (URL?) -> Void) {
        finish()
        let s = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callback, _ in
            Task { @MainActor in
                self?.session = nil
                self?.isActive = false
                onCallback(callback)
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        isActive = s.start()
        if !isActive { session = nil; onCallback(nil) }
    }

    /// Anmeldung mit Loopback-Rücksprung (Server 1.35, eigene MCP-Server wie Qonto, die kein App-Schema erlauben):
    /// Die App hört kurz auf 127.0.0.1:<port>, schließt das Fenster beim Rücksprung und gibt die Adresse weiter.
    func start(url: URL, loopbackPort: UInt16, path: String, onCallback: @escaping (URL?) -> Void) {
        finish()
        loopbackCallback = onCallback
        let c = LoopbackCatcher()
        do {
            try c.start(port: loopbackPort, path: path) { [weak self] u in
                Task { @MainActor in self?.deliverLoopback(u) }
            }
        } catch {
            deliverLoopback(nil)
            return
        }
        catcher = c
        let s = ASWebAuthenticationSession(url: url, callback: .customScheme("aisscoops")) { [weak self] callback, _ in
            Task { @MainActor in self?.deliverLoopback(callback) }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        isActive = s.start()
        if !isActive { deliverLoopback(nil) }
    }

    private func deliverLoopback(_ url: URL?) {
        catcher?.stop()
        catcher = nil
        guard let cb = loopbackCallback else { return }
        loopbackCallback = nil
        if let session {
            self.session = nil
            session.cancel()
        }
        isActive = false
        cb(url)
    }

    func finish() {
        if loopbackCallback != nil { deliverLoopback(nil) }
        guard let session else { return }
        self.session = nil
        session.cancel()
        isActive = false
    }

    private func closed() {
        session = nil
        isActive = false
        let cb = onClose
        onClose = nil
        cb?()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            if let scene = scenes.first { return scene.windows.first ?? UIWindow(windowScene: scene) }
            return scenes.flatMap(\.windows).first!
            #else
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// Wischaktionen außerhalb von `List` (ab iOS 27 per `swipeActionsContainer()`); vorher bleibt das Menü „…“.
private struct SwipeContainer: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27, *) { content.swipeActionsContainer() } else { content }
        #else
        content
        #endif
    }
}
