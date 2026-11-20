import Foundation

/// Sprache der Oberfläche (docs/sprache-serverapp.md). Die App kann Deutsch (Quellsprache, auch Rückfall für alle
/// anderen Systemsprachen) und Englisch; macOS wählt anhand der bevorzugten Sprachen des Systems bzw. der App.
nonisolated enum AppLanguage {
    /// „de“ oder „en“: die Sprache, in der die App gerade ihre Texte zeigt.
    static var code: String {
        let first = Bundle.main.preferredLocalizations.first ?? "de"
        return first.hasPrefix("en") ? "en" : "de"
    }

    /// Für Formatierer mitten in übersetzten Sätzen (Aufzählungen): Sprache der App, Region des Systems.
    static var locale: Locale {
        var c = Locale.Components(locale: .current)
        c.languageComponents = Locale.Language.Components(identifier: code)
        return Locale(components: c)
    }

    /// Header `Accept-Language` für Anfragen an den eigenen Server: Er liefert Texte (z. B. Fehlermeldungen aus
    /// `/api/setup…`) dann in derselben Sprache wie die App. Deutsch bleibt Rückfall.
    static var acceptLanguage: String { code == "en" ? "en, de;q=0.5" : "de" }
}
