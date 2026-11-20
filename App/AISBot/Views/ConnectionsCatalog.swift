import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Modelle (API v1.16: Katalog aller Composio-Apps)

/// Eine App aus dem Composio-Katalog (`GET /api/connections/catalog`).
nonisolated struct CatalogApp: Codable, Hashable, Identifiable, Sendable {
    /// oauth = Anmeldung im Browser, fields = Formular (API-Schlüssel …), none = keine Anmeldung nötig,
    /// unavailable = Composio bietet keine fertige Anmeldung.
    enum Auth: String, Sendable { case oauth, fields, none, unavailable }

    var slug: String
    var name: String
    var detail: String?
    var logoUrl: String?
    var symbol: String?
    var category: String?
    var categories: [String]
    var auth: String
    var popular: Bool
    /// Anzahl aktiver Konten
    var connected: Int
    var accounts: [ConnectedAccount]
    var canAdd: Bool
    var id: String { slug }

    var authKind: Auth { Auth(rawValue: auth) ?? .oauth }
    var isConnected: Bool { !accounts.isEmpty }

    init(slug: String, name: String, detail: String? = nil, logoUrl: String? = nil, symbol: String? = nil,
         categories: [String] = [], auth: Auth = .oauth, popular: Bool = false, accounts: [ConnectedAccount] = [],
         canAdd: Bool = true) {
        self.slug = slug; self.name = name; self.detail = detail; self.logoUrl = logoUrl; self.symbol = symbol
        self.category = categories.first; self.categories = categories; self.auth = auth.rawValue
        self.popular = popular; self.accounts = accounts; self.canAdd = canAdd
        self.connected = accounts.filter { $0.state == .active }.count
    }

    /// Ältere Server ohne Katalog: Apps aus `GET /api/connections`.
    init(_ app: ConnectableApp) {
        self.init(slug: app.slug, name: app.name, detail: app.detail, logoUrl: app.logoUrl, symbol: app.symbol,
                  popular: true, accounts: app.accounts, canAdd: app.canAdd)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        auth = (try? c.decodeIfPresent(String.self, forKey: .auth)) ?? "oauth"
        popular = (try? c.decodeIfPresent(Bool.self, forKey: .popular)) ?? false
        connected = (try? c.decodeIfPresent(Int.self, forKey: .connected)) ?? 0
        accounts = (try? c.decodeIfPresent([ConnectedAccount].self, forKey: .accounts)) ?? []
        canAdd = (try? c.decodeIfPresent(Bool.self, forKey: .canAdd)) ?? true
    }
}

nonisolated struct CatalogPage: Codable, Sendable {
    var items: [CatalogApp]
    var total: Int
    var nextOffset: Int?
    var connectedApps: Int
    var maxPerApp: Int

    init(items: [CatalogApp], total: Int, nextOffset: Int?, connectedApps: Int, maxPerApp: Int = 10) {
        self.items = items; self.total = total; self.nextOffset = nextOffset; self.connectedApps = connectedApps
        self.maxPerApp = maxPerApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([CatalogApp].self, forKey: .items)) ?? []
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? items.count
        nextOffset = try? c.decodeIfPresent(Int.self, forKey: .nextOffset)
        connectedApps = (try? c.decodeIfPresent(Int.self, forKey: .connectedApps)) ?? 0
        maxPerApp = (try? c.decodeIfPresent(Int.self, forKey: .maxPerApp)) ?? 10
    }
}

/// Kategorie-Chip (`GET /api/connections/categories`); der Server liefert deutsche Namen bzw. das Original.
nonisolated struct CatalogCategory: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var count: Int

    static let popular = "popular"
    static let connected = "connected"
    /// Einhängestelle „Apple“ (eigener View aus `ConnectionsAppleSlot.swift`, kommt nicht vom Server)
    static let apple = "apple"

    init(id: String, name: String, count: Int = 0) { self.id = id; self.name = name; self.count = count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
    }

    /// Name in der App-Sprache für bekannte Kategorien, sonst der Name vom Server (Composio-Original).
    var displayName: String { Self.germanNames[id] ?? name }

    static var germanNames: [String: String] { [
        "popular": String(localized: "Beliebt", comment: "Kategorie in „Apps verbinden“"),
        "connected": String(localized: "Verbunden", comment: "Kategorie in „Apps verbinden“: verbundene Apps"),
        "apple": "Apple",
        "productivity": String(localized: "Produktivität", comment: "Kategorie in „Apps verbinden“"),
        "communication": String(localized: "Kommunikation", comment: "Kategorie in „Apps verbinden“"),
        "design": String(localized: "Design", comment: "Kategorie in „Apps verbinden“"),
        "development": String(localized: "Entwicklung", comment: "Kategorie in „Apps verbinden“"),
        "data": String(localized: "Daten", comment: "Kategorie in „Apps verbinden“"),
        "finance": String(localized: "Finanzen", comment: "Kategorie in „Apps verbinden“"),
        "marketing": String(localized: "Marketing", comment: "Kategorie in „Apps verbinden“"),
        "sales": String(localized: "Vertrieb & CRM", comment: "Kategorie in „Apps verbinden“"),
        "ai": String(localized: "KI", comment: "Kategorie in „Apps verbinden“: künstliche Intelligenz"),
        "commerce": String(localized: "Handel", comment: "Kategorie in „Apps verbinden“"),
        "hr": String(localized: "Personal", comment: "Kategorie in „Apps verbinden“: Personalwesen (HR)"),
        "education": String(localized: "Bildung", comment: "Kategorie in „Apps verbinden“"),
        "lifestyle": String(localized: "Freizeit", comment: "Kategorie in „Apps verbinden“"),
    ] }
}

nonisolated struct CatalogCategoryList: Codable, Sendable {
    var categories: [CatalogCategory]
}

/// Wie sich eine App verbinden lässt (`GET /api/connections/catalog/{slug}`).
nonisolated struct AppAuthInfo: Codable, Sendable {
    var slug: String
    var name: String
    var detail: String?
    var logoUrl: String?
    var auth: String
    var scheme: String?
    var fields: [AuthField]
    var message: String?
    var guideUrl: String?

    init(slug: String, name: String, auth: String, scheme: String? = nil, fields: [AuthField] = [],
         message: String? = nil, guideUrl: String? = nil) {
        self.slug = slug; self.name = name; self.auth = auth; self.scheme = scheme; self.fields = fields
        self.message = message; self.guideUrl = guideUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        auth = (try? c.decodeIfPresent(String.self, forKey: .auth)) ?? "oauth"
        scheme = try? c.decodeIfPresent(String.self, forKey: .scheme)
        fields = (try? c.decodeIfPresent([AuthField].self, forKey: .fields)) ?? []
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        guideUrl = try? c.decodeIfPresent(String.self, forKey: .guideUrl)
    }
}

nonisolated struct AuthField: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var label: String
    var description: String?
    var secret: Bool
    var required: Bool
    var defaultValue: String?
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, label, description, secret, required, defaultValue = "default" }

    init(name: String, label: String, description: String? = nil, secret: Bool, required: Bool = true,
         defaultValue: String? = nil) {
        self.name = name; self.label = label; self.description = description; self.secret = secret
        self.required = required; self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? name
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        secret = (try? c.decodeIfPresent(Bool.self, forKey: .secret)) ?? true
        required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? true
        defaultValue = try? c.decodeIfPresent(String.self, forKey: .defaultValue)
    }
}

/// Wert eines Formularfelds. Als Liste gesendet, damit der snake_case-Encoder die Feldnamen nicht verändert.
nonisolated struct AuthFieldValue: Codable, Sendable {
    var name: String
    var value: String
}

nonisolated struct ConnectResult: Codable, Sendable {
    var accountId: String?
    var status: String?
}

// MARK: - Zustand der Liste

/// Katalog-Liste für „Apps verbinden“: Kategorie, Suche, seitenweises Nachladen.
@MainActor
@Observable
final class ConnectionCatalogModel {
    static let pageSize = 60

    var selected: String = CatalogCategory.popular
    var query: String = ""
    private(set) var categories: [CatalogCategory] = [
        CatalogCategory(id: CatalogCategory.popular, name: String(localized: "Beliebt", comment: "Kategorie in „Apps verbinden“")),
        CatalogCategory(id: CatalogCategory.connected,
                        name: String(localized: "Verbunden", comment: "Kategorie in „Apps verbinden“: verbundene Apps")),
    ]
    private(set) var items: [CatalogApp] = []
    private(set) var total = 0
    private(set) var connectedApps = 0
    private(set) var maxPerApp = 10
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var loaded = false
    private(set) var error: String?
    /// Der Server kennt den Katalog noch nicht (< 1.16): Liste aus `GET /api/connections`.
    private(set) var legacy = false
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var generation = 0

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasMore: Bool { nextOffset != nil }

    func loadCategories(_ service: BotService?) async {
        guard let service, !legacy else { return }
        if let list = try? await service.connectionCategories(), !list.isEmpty { categories = list }
    }

    /// Erste Seite für Kategorie/Suche neu laden. `quiet`: Liste stehen lassen, bis die Antwort da ist.
    func reload(_ service: BotService?, overview: ConnectionsOverview?, quiet: Bool = false) async {
        generation += 1
        let gen = generation
        guard let service else { error = String(localized: "Keine Verbindung zum Server."); return }
        if legacy { applyLegacy(overview); return }
        if !quiet { loading = true }
        defer { if gen == generation { loading = false } }
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            let page = try await service.connectionCatalog(category: q.isEmpty ? selected : nil, query: q.isEmpty ? nil : q,
                                                           offset: 0, limit: Self.pageSize)
            guard gen == generation else { return }
            apply(page, replace: true)
            error = nil
        } catch let e as APIError where e.status == 404 {
            guard gen == generation else { return }
            legacy = true
            applyLegacy(overview)
        } catch {
            guard gen == generation else { return }
            if !(error is CancellationError) { self.error = (error as? APIError)?.message ?? error.localizedDescription }
        }
        loaded = true
    }

    func loadMore(_ service: BotService?) async {
        guard let service, let offset = nextOffset, !loadingMore, !loading, !legacy else { return }
        let gen = generation
        loadingMore = true
        defer { loadingMore = false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if let page = try? await service.connectionCatalog(category: q.isEmpty ? selected : nil, query: q.isEmpty ? nil : q,
                                                           offset: offset, limit: Self.pageSize),
           gen == generation {
            apply(page, replace: false)
        }
    }

    private func apply(_ page: CatalogPage, replace: Bool) {
        if replace {
            items = page.items
        } else {
            let known = Set(items.map(\.slug))
            items += page.items.filter { !known.contains($0.slug) }
        }
        total = page.total
        nextOffset = page.nextOffset
        connectedApps = page.connectedApps
        maxPerApp = page.maxPerApp
    }

    private func applyLegacy(_ overview: ConnectionsOverview?) {
        let all = (overview?.apps ?? []).map(CatalogApp.init)
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = selected == CatalogCategory.connected && q.isEmpty ? all.filter(\.isConnected) : all
        if !q.isEmpty { list = list.filter { $0.name.localizedStandardContains(q) || ($0.detail ?? "").localizedStandardContains(q) } }
        items = list
        total = list.count
        nextOffset = nil
        connectedApps = all.filter { $0.connected > 0 }.count
        maxPerApp = overview?.maxPerApp ?? 10
        loaded = overview != nil
    }

    /// Chips in der Reihenfolge Beliebt, Verbunden, (Apple), dann die Kategorien vom Server.
    var chips: [CatalogCategory] {
        var out = categories.filter { $0.id == CatalogCategory.popular || $0.id == CatalogCategory.connected }
        if out.isEmpty { out = [CatalogCategory(id: CatalogCategory.popular, name: String(localized: "Beliebt", comment: "Kategorie in „Apps verbinden“")),
                                CatalogCategory(id: CatalogCategory.connected,
                                                name: String(localized: "Verbunden", comment: "Kategorie in „Apps verbinden“: verbundene Apps"))] }
        if ConnectionsAppleSlot.isEnabled { out.append(CatalogCategory(id: CatalogCategory.apple, name: "Apple")) }
        out += categories.filter { $0.id != CatalogCategory.popular && $0.id != CatalogCategory.connected
            && $0.id != CatalogCategory.apple }
        return out
    }
}

// MARK: - Logos

/// Lädt App-Logos als PNG vom eigenen Server (`GET /api/connections/logo/{slug}`, mit Anmeldung; Composio liefert
/// SVG, das der Server umwandelt) und hält sie im Speicher. Fehlschläge werden gemerkt (kein erneuter Abruf).
@MainActor
final class AppLogoCache {
    static let shared = AppLogoCache()
    private var images: [String: Image] = [:]
    private var failed: Set<String> = []
    private var running: [String: Task<Image?, Never>] = [:]

    func cached(_ slug: String) -> Image? { images[slug] }

    func image(_ slug: String, service: BotService?) async -> Image? {
        if let img = images[slug] { return img }
        if failed.contains(slug) { return nil }
        guard let service else { return nil }
        if let task = running[slug] { return await task.value }
        let task = Task<Image?, Never> {
            guard let data = try? await service.connectionLogo(app: slug) else { return nil }
            #if canImport(UIKit)
            guard let ui = UIImage(data: data) else { return nil }
            return Image(uiImage: ui)
            #else
            guard let ns = NSImage(data: data) else { return nil }
            return Image(nsImage: ns)
            #endif
        }
        running[slug] = task
        let img = await task.value
        running[slug] = nil
        if let img { images[slug] = img } else { failed.insert(slug) }
        return img
    }
}

/// Echtes App-Logo auf heller Kachel; bis es geladen ist (oder ohne Logo) das SF-Symbol bzw. der Anfangsbuchstabe.
struct AppLogo: View {
    let slug: String
    var name: String
    var symbol: String?
    var size: CGFloat = 40
    /// false: nur Symbol/Initial (z. B. fest eingerichtete Verbindungen ohne Composio-Logo)
    var remote = true
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var image: Image?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            if remote, let image = image ?? AppLogoCache.shared.cached(slug) {
                shape.fill(Color.white)
                image.resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.16)
            } else {
                shape.fill(theme.selection)
                if let symbol, !symbol.isEmpty {
                    Image(systemName: SymbolName.resolve(symbol, fallback: "app.connected.to.app.below.fill"))
                        .font(.fixed(size * 0.44, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.fixed(size * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: slug) {
            if remote, image == nil { image = await AppLogoCache.shared.image(slug, service: store.service) }
        }
    }
}
