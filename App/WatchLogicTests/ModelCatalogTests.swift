import Foundation
import Testing

/// Modellkatalog vom Server (Shared/Models/ModelCatalog.swift, docs/modelle.md). Liegt bei den Uhren-Tests, weil dieses
/// Ziel die gemeinsamen Quellen ohne App-Host kompiliert.
@Suite("Modellkatalog")
struct ModelCatalogTests {
    /// Gekürzte Antwort von GET /api/models (Server 1.34), snake_case wie vom Server
    private let json = """
    {"version": 2026111801, "updated": "2026-11-18", "source": "remote",
     "defaults": {"anthropic": {"model": "claude-haiku-5-5", "escalation": "claude-sonnet-5-5"},
                  "openai": {"model": "gpt-6-luna", "escalation": "gpt-6.2-sol"}},
     "models": [
      {"id": "claude-haiku-5-5", "label": "Haiku 5.5", "provider": "anthropic", "hint": "Schnell & günstig", "rank": 10,
       "price": {"input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_write": 0.125}, "routes": ["api", "claude_abo"],
       "features": [], "replaces": [], "deprecated": false, "selectable": true, "available": false, "routes_available": []},
      {"id": "claude-fable-5-2", "label": "Fable 5.2", "provider": "anthropic", "hint": "Am stärksten, sehr teuer", "rank": 40,
       "deprecated": false, "selectable": true, "available": true, "routes_available": ["abo"]},
      {"id": "claude-opus-5-5", "label": "Opus 5.5", "provider": "anthropic", "rank": 30, "selectable": true},
      {"id": "gpt-6-luna", "label": "GPT-6 Luna", "provider": "openai", "rank": 10, "selectable": true, "available": true},
      {"id": "gpt-6.2-sol", "label": "GPT-6.2 Sol", "provider": "openai", "rank": 30, "selectable": true,
       "replaces": ["gpt-6.1-sol"]},
      {"id": "gpt-6.3-nova", "label": "GPT-6.3 Nova", "provider": "openai", "rank": 50, "selectable": true},
      {"id": "gpt-6.1-sol", "label": "GPT-6.1 Sol", "provider": "openai", "rank": 29, "deprecated": true, "selectable": false}
     ],
     "replaced": {"gpt-6.1-sol": "gpt-6.2-sol"},
     "providers": {"anthropic": {"api": false, "abo": true}}}
    """

    private func catalog() throws -> ModelCatalog {
        try JSONCoding.makeDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    }

    @Test func dekodiertServerantwort() throws {
        let c = try catalog()
        #expect(c.version == 2026111801)
        #expect(c.selectable(of: .anthropic).map(\.id) == ["claude-haiku-5-5", "claude-opus-5-5", "claude-fable-5-2"])
        #expect(c.selectable(of: .openai).map(\.label) == ["GPT-6 Luna", "GPT-6.2 Sol", "GPT-6.3 Nova"])
        #expect(c.model("claude-fable-5-2")?.routesAvailable == ["abo"])
        #expect(c.defaults?["openai"]?.escalation == "gpt-6.2-sol")
    }

    @Test func alteKennungenUndVerstaerkung() throws {
        let c = try catalog()
        #expect(c.resolve("gpt-6.1-sol") == "gpt-6.2-sol")
        #expect(c.resolve("claude-opus-5-5") == "claude-opus-5-5")
        #expect(!c.isSelectable("gpt-6.1-sol") && c.isSelectable("gpt-6.3-nova"))
        #expect(c.nextStronger("gpt-6-luna") == "gpt-6.2-sol")
        #expect(c.nextStronger("gpt-6.1-sol") == "gpt-6.3-nova")
        #expect(c.nextStronger("gpt-6.3-nova") == nil)
        #expect(c.isStronger("claude-fable-5-2", than: "claude-haiku-5-5"))
        #expect(!c.isStronger("claude-haiku-5-5", than: "claude-fable-5-2"))
        #expect(!c.isStronger("gpt-6.3-nova", than: "claude-haiku-5-5"))
    }

    @Test func startmodellFolgtDenEingerichtetenWegen() throws {
        var c = try catalog()
        #expect(c.defaultModel == "gpt-6-luna")  // Haiku nicht eingerichtet, Luna schon
        c.models = c.models.map { var m = $0; m.available = nil; return m }
        #expect(c.defaultModel == "claude-haiku-5-5")
    }

    @Test func eingebauteListeEntsprichtAeltereServer() {
        let b = ModelCatalog.builtIn
        #expect(b.selectable(of: .anthropic).map(\.id) == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        #expect(b.selectable(of: .openai).map(\.id) == ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra"])
        #expect(b.defaultModel == "claude-haiku-5-5")
    }

    @Test func unbekannteKennungenLesbar() {
        #expect(BotModel.prettyName(for: "claude-opus-5-6") == "Opus 5.6")
        #expect(BotModel.prettyName(for: "gpt-6.3-nova") == "GPT-6.3 Nova")
        #expect(BotModel.prettyName(for: "gpt-7") == "GPT-7")
        #expect(BotModel.prettyName(for: "o4-mini") == "o4-mini")
    }

    @MainActor @Test func anzeigenameAusDemKatalog() throws {
        let store = ModelCatalogStore.shared
        let before = store.catalog
        defer { if before.version == 0 { store.useBuiltIn() } else { store.update(before) } }
        store.update(try catalog())
        #expect(BotModel.displayName(for: "gpt-6.3-nova") == "GPT-6.3 Nova")
        #expect(BotModel.displayName(for: "gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(BotModel.displayName(for: "claude-sonnet-9-1") == "Sonnet 9.1")
        #expect(BotModel.providerMark(for: "gpt-6.3-nova") == "OpenAI")
        #expect(BotModel.choices(of: .anthropic).last?.id == "claude-fable-5-2")
        store.useBuiltIn()
        #expect(BotModel.choices(of: .anthropic).map(\.id).contains("claude-fable-5-2") == false)
    }
}
