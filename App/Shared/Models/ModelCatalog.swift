import Foundation
import Observation

// MARK: - Modellkatalog (GET /api/models, docs/modelle.md)

/// Ein Modell aus dem Katalog des Servers. Neue Modelle kommen so ohne App-Build in die Auswahl.
nonisolated struct CatalogModel: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    /// "anthropic" | "openai"
    var provider: String
    var hint: String?
    var rank: Int
    var routes: [String]?
    var replaces: [String]?
    var deprecated: Bool?
    var selectable: Bool?
    /// Nur für den Admin: läuft auf diesem Server (Schlüssel oder Abo)
    var available: Bool?
    var routesAvailable: [String]?

    var modelProvider: ModelProvider? { ModelProvider(rawValue: provider) }
    var isSelectable: Bool { selectable ?? !(deprecated ?? false) }
}

nonisolated struct ModelCatalog: Codable, Equatable, Sendable {
    var version: Int
    var source: String?
    var models: [CatalogModel]
    /// Alte Kennung → Nachfolger
    var replaced: [String: String]?
    /// Startmodell und Verstärkung je Anbieter ("anthropic"/"openai")
    var defaults: [String: ProviderDefaults]?

    nonisolated struct ProviderDefaults: Codable, Equatable, Sendable {
        var model: String
        var escalation: String?
    }

    /// Startmodell für neue Scoops: Claude-Standard, außer nur OpenAI ist auf dem Server eingerichtet
    var defaultModel: String {
        let claude = defaults?["anthropic"]?.model ?? BotModel.haiku.rawValue
        let openai = defaults?["openai"]?.model ?? BotModel.luna.rawValue
        if model(claude)?.available == false, model(openai)?.available == true { return openai }
        return claude
    }

    /// Eingebaute Liste = was ältere Server (vor 1.34, ohne `/api/models`) annehmen. Gilt auch im Demo-Modus und beim
    /// ersten Start ohne Verbindung.
    static let builtIn = ModelCatalog(
        version: 0, source: "app",
        models: BotModel.allCases.enumerated().map { i, m in
            CatalogModel(id: m.rawValue, label: m.displayName, provider: m.provider.rawValue, hint: m.hint, rank: i)
        },
        replaced: [:], defaults: nil)

    /// Wählbare Modelle eines Anbieters, nach Stärke
    func selectable(of provider: ModelProvider) -> [CatalogModel] {
        models.filter { $0.isSelectable && $0.provider == provider.rawValue }.sorted { $0.rank < $1.rank }
    }

    /// Alte Kennungen → Nachfolger (wie der Server)
    func resolve(_ id: String) -> String {
        var id = id, seen = Set<String>()
        while let next = replaced?[id], !seen.contains(id) { seen.insert(id); id = next }
        return id
    }

    func model(_ id: String) -> CatalogModel? {
        models.first { $0.id == id } ?? models.first { $0.id == resolve(id) }
    }

    func isSelectable(_ id: String) -> Bool { models.contains { $0.id == id && $0.isSelectable } }

    /// Nächststärkeres wählbares Modell desselben Anbieters (OpenAI-Verstärkung Schritt für Schritt)
    func nextStronger(_ id: String) -> String? {
        guard let m = model(resolve(id)), let p = m.modelProvider else { return nil }
        return selectable(of: p).first { $0.rank > m.rank }?.id
    }

    /// Ist `escalation` stärker als `model` (gleicher Anbieter)? Der Server gibt nur dann an Claude-Modelle ab.
    func isStronger(_ escalation: String, than model: String) -> Bool {
        guard let e = self.model(resolve(escalation)), let m = self.model(resolve(model)) else { return true }
        return e.provider == m.provider && e.rank > m.rank
    }
}

/// Aktueller Modellkatalog (eigener Server, sonst zuletzt gespeichert, sonst eingebaut). Beobachtbar: Auswahl und
/// Anzeigenamen folgen einem neuen Katalog sofort.
@MainActor @Observable
final class ModelCatalogStore {
    static let shared = ModelCatalogStore()
    private static let defaultsKey = "modelCatalog.v1"

    private(set) var catalog: ModelCatalog

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONCoding.makeDecoder().decode(ModelCatalog.self, from: data), !saved.models.isEmpty {
            catalog = saved
        } else {
            catalog = .builtIn
        }
    }

    /// Katalog des eigenen Servers übernehmen (und für den nächsten Start merken)
    func update(_ new: ModelCatalog) {
        guard !new.models.isEmpty, new != catalog else { return }
        catalog = new
        if let data = try? JSONCoding.makeEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Älterer Server ohne Katalog: eingebaute Liste
    func useBuiltIn() {
        catalog = .builtIn
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// Anzeigenamen aus dem Katalog eines anderen Servers (geteilte Scoops) ergänzen, ohne die Auswahl zu ändern
    func absorbLabels(from other: ModelCatalog) {
        let known = Set(catalog.models.map(\.id))
        let extra = other.models.filter { !known.contains($0.id) }
            .map { var m = $0; m.selectable = false; m.available = nil; return m }
        guard !extra.isEmpty else { return }
        catalog.models += extra
    }
}

extension BotModel {
    /// Lesbarer Name auch für Kennungen, die weder Katalog noch App kennen („claude-opus-5-6“ → „Opus 5.6“,
    /// „gpt-6.3-nova“ → „GPT-6.3 Nova“); sonst unverändert.
    nonisolated static func prettyName(for raw: String) -> String {
        let m = raw.lowercased()
        if m.hasPrefix("claude-") {
            let parts = m.dropFirst(7).split(separator: "-").map(String.init)
            guard let name = parts.first, name.allSatisfy(\.isLetter) else { return raw }
            let version = parts.dropFirst()
            if !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return name.capitalized + " " + version.joined(separator: ".")
            }
            return parts.map(\.capitalized).joined(separator: " ")
        }
        if m.hasPrefix("gpt-") {
            let bits = m.dropFirst(4).split(separator: "-").map(String.init)
            guard let first = bits.first else { return raw }
            let rest = bits.dropFirst().map(\.capitalized)
            return "GPT-" + first + (rest.isEmpty ? "" : " " + rest.joined(separator: " "))
        }
        return raw
    }
}
