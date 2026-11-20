import Foundation

/// Sprache der App (App/README.md „Sprachen“, Vertrag mit dem Server: docs/sprache.md).
///
/// Deutsch ist Quellsprache und Rückfall für alle anderen Systemsprachen; Englisch kommt über die String Catalogs
/// (`Shared/Localization/Localizable.xcstrings`). Welche Sprache gilt, entscheidet das System anhand der bevorzugten
/// Sprachen des Geräts bzw. der App. Die Sprache wechselt nie während die App läuft (iOS startet die App neu, macOS
/// zeigt die neue Sprache nach einem Neustart), deshalb wird sie einmal bestimmt.
nonisolated enum AppLanguage {
    /// „de“ oder „en“: die Sprache, in der die App gerade ihre Texte zeigt.
    static let code: String = {
        let bundle = Bundle.main
        // Unit-Tests (Bundle.main ist das Testprogramm) und fremde Hosts: Texte kommen ohnehin deutsch aus dem Code.
        guard bundle.bundleIdentifier?.hasPrefix("com.ais.") == true else { return "de" }
        return (bundle.preferredLocalizations.first ?? "de").hasPrefix("en") ? "en" : "de"
    }()

    static var isGerman: Bool { code == "de" }
    static var isEnglish: Bool { code == "en" }

    /// Für Formatierer (Datum, Uhrzeit, Zahlen, Beträge, Aufzählungen): Sprache der App, Region und Vorlieben des
    /// Systems (z. B. 24-Stunden-Uhr). Auf einem deutschen Gerät mit Region Deutschland ist das `de_DE`.
    static let locale: Locale = {
        var c = Locale.Components(locale: .current)
        c.languageComponents = Locale.Language.Components(identifier: code)
        return Locale(components: c)
    }()

    /// Kopfzeile `Accept-Language` für Anfragen an den Server (docs/sprache.md): Er liefert Fehler, Hinweise und
    /// Kataloge dann in derselben Sprache wie die App. Deutsch bleibt Rückfall.
    static var acceptLanguage: String { code == "en" ? "en, de;q=0.5" : "de" }

    /// Sprache für Spracherkennung, Diktat und Sprachausgabe als BCP-47-Code, z. B. „de-DE“ oder „en-US“: Sprache der App
    /// mit der Region des Geräts, wenn die Kombination üblich ist, sonst die Hauptregion der Sprache.
    static var speechIdentifier: String {
        let region = Locale.current.region?.identifier ?? ""
        let englishRegions: Set<String> = ["US", "GB", "AU", "CA", "IE", "NZ", "IN", "ZA", "SG"]
        let germanRegions: Set<String> = ["DE", "AT", "CH"]
        if code == "en" { return "en-" + (englishRegions.contains(region) ? region : "US") }
        return "de-" + (germanRegions.contains(region) ? region : "DE")
    }
}

extension Locale {
    /// Locale der App-Sprache (siehe `AppLanguage.locale`). Für alle sichtbaren Formate statt fester deutscher Locale.
    nonisolated static var app: Locale { AppLanguage.locale }
}

/// Beispielinhalt des Demo-Modus in beiden Sprachen (`-mock`, Uhr `-demo`). Die deutsche Fassung bleibt im Code wie
/// bisher; die englische steht direkt daneben und darf inhaltlich angepasst sein (Orte, Firmen, Währung). Bewusst
/// nicht im String Catalog: Beispielinhalt ist keine Oberfläche, und der Catalog wird in jede Erweiterung kopiert.
nonisolated func demoText(_ de: String, en: String) -> String {
    AppLanguage.isGerman ? de : en
}
