# Sprache der Mac-App „AIS Scoops Server“ (Deutsch und Englisch)

Stand: App 1.3, Paket G3. Gegenstück für den Server und das gemeinsame Glossar (gilt auch hier): [sprache.md](sprache.md),
App: [sprache-app.md](sprache-app.md).

Die Mac-App „AIS Scoops Server“ (Target `ScoopsConnect`, auch in der Rolle „Scoops Connect“) spricht Deutsch und
Englisch. **Deutsch ist Quellsprache** und Rückfall für alle anderen Systemsprachen; auf einem deutschen Mac bleibt
jeder Text Zeichen für Zeichen wie vor 1.3. Welche Sprache gilt, entscheidet macOS (Systemeinstellungen → Allgemein →
Sprache & Region, auch pro App).

## Dateien

| Datei | Inhalt |
|---|---|
| `App/ScoopsConnect/Resources/Localizable.xcstrings` | alle Texte der Oberfläche (Quellsprache `de`, dazu `en`, Mehrzahl für zwei Einträge) |
| `App/ScoopsConnect/Resources/InfoPlist.xcstrings` | Texte aus der `Info.plist` (Begründungen für Erinnerungen, Kalender, Kontakte, lokales Netz) |
| `App/ScoopsConnect/App/AppLanguage.swift` | Sprache der App (`de`/`en`), Locale für Aufzählungen, `Accept-Language` |
| `App/project.yml` | `CFBundleLocalizations: [de, en]`, `SWIFT_EMIT_LOC_STRINGS`, Target `ScoopsConnectRenderTests` |
| `App/ScoopsConnect/RenderTests/` | Prüfungen und Renderings ohne Start der App (siehe unten) |

`xcodegen generate` erkennt die Sprachen aus den Catalogs (`knownRegions` = Base, de, en). Die übrigen Targets bleiben
nur deutsch (`CFBundleLocalizations: [de]`).

## Regeln im Code

- `Text("…")`, `Button("…")`, `Label`, `Toggle`, `Section`, `.alert`, `.help` mit Literal sind von selbst übersetzbar.
  Ternäre Ausdrücke aus zwei Literalen ebenfalls.
- Texte, die als `String` durchgereicht werden (Titel in Enums, Statuszeilen, Fehlermeldungen, `NSAlert`,
  `NSOpenPanel`, Bedienungshilfen-Werte), entstehen mit `String(localized: "…")`. Komponenten wie `PermissionRow`,
  `KeyRow`, `HelpDisclosure`, `MenuRow` nehmen `LocalizedStringKey`.
- Ganze Sätze, keine Bruchstücke: Varianten (mit/ohne Port, mit/ohne Kontoname, Zeitfenster des Abos) sind je ein
  eigener Eintrag. Aufzählungen über `ListFormatStyle` mit `AppLanguage.locale` („Anthropic und OpenAI“ /
  „Anthropic and OpenAI“), Uhrzeiten über `formatted(date:time:)`.
- **Ports, PIDs, Fehler- und Exit-Codes** in `String(localized:)` als Text einsetzen (`\(String(port))`): Ganze Zahlen
  bekommen dort sonst Tausendertrennzeichen („Port 8.787“). Zählwerte für die Mehrzahl bleiben `Int`.
- Keine Texte vergleichen: „Trotzdem speichern“ hängt an `KeyCheck.Result.unknown` (früher `contains("trotzdem")`),
  Erfolg in „Von unterwegs“ an einem eigenen Zustand (früher Präfix „✓“).
- Nichts als `static let` speichern, was übersetzt wird (`AboProvider.all` ist berechnet).

Neue Texte: bauen, dann
`xcrun xcstringstool sync App/ScoopsConnect/Resources/Localizable.xcstrings --stringsdata <DerivedData>/…/ScoopsConnect.build/**/*.stringsdata`
(oder Xcode öffnen) und Englisch eintragen. `ScoopsConnectRenderTests` schlägt fehl, solange ein Eintrag ohne
Englisch, „neu“, „zu prüfen“ oder „veraltet“ ist oder Platzhalter abweichen.

## Was bewusst deutsch bleibt

- **Antworten an den Server** (Befehlsergebnisse `success: false`, `bye`-Grund, Meldungen von `CommandRunner`,
  `CommandExecutor`, `DirectExecutor`, `ScreenCapture`, `VMExecutor`, `AppleBridge`): Protokoll, liest das Modell bzw.
  der Server; wie die Werkzeug-Rückgaben auf dem Server ([sprache.md](sprache.md)). `AppleService.protocolTitle`
  hält dafür die deutschen Namen der Dienste fest, `title` ist übersetzt.
- **Protokollzeilen** (`NSLog`, Startzeile in `logs/server.log`, Update-Meldungen in `AppUpdater.log`, `autosetup.log`).
- **Bezeichnung des Schlüsselbund-Eintrags** („AIS Scoops – Anthropic (Claude)“, `SecretStore.Kind.keychainLabel`):
  gleich in jeder Sprache, gelesen wird über Dienst und Konto.
- **Ordner- und Dateinamen** („Dateien“, „Aufgaben“ im Arbeitsordner, `….plist.deaktiviert`), Befehle (`pmset`,
  `brew install lume`), Produktnamen (AIS Scoops, AIS Scoops Server, Scoops Connect, Tailscale Funnel/Serve, Claude Code,
  Codex), Code im Kopplungscode.
- **Texte vom Server** (z. B. `error` aus `/api/setup…`, Status der KI-Abos, Arbeitsordner, Kontofehler): Sie kommen in
  der Sprache aus `Accept-Language` (siehe unten), die App übersetzt sie nicht.
- **Debug-Hilfen**: `SetupSnapshots` (`-rendersetup`) benennt Dateien deutsch.

## Server: Accept-Language und Sprache des Inhabers

- Jede Anfrage an den eigenen Server (`ServerManager.urlRequest`), die Kopplung (`/api/nodes/claim`) und die
  Rechner-Verbindung (`/api/nodes/link`) schicken `Accept-Language`: `de` bzw. `en, de;q=0.5`.
- Nach jedem Start des Servers: Hat der Inhaber noch keine Sprache (`server.language == null`) und kann der Server die
  Sprache der App (`server.languages`), setzt die App sie mit `PATCH /api/setup/config {"language": "en"}`
  (`ServerManager.adoptAppLanguageIfUnset`). Eine gespeicherte Sprache (z. B. von AIS Scoops auf dem iPhone) bleibt
  unangetastet; für Deutsch geht keine Anfrage raus (Standard). Ältere Server melden `languages` nicht: nichts passiert.
- Der Serverprozess startet weiter mit `LANG=de_DE.UTF-8` (nur Zeichensatz; die Sprache regeln Kopfzeile und
  gespeicherte Sprache).

## Sparkle

Sparkle bringt eigene Übersetzungen mit. Englisch steckt im Framework als `Base.lproj/Sparkle.strings`
(Entwicklungssprache des Frameworks `en`), Deutsch als `de.lproj`; geprüft im gebauten Paket
(`AIS Scoops Server.app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources`). Die App selbst meldet
`CFBundleLocalizations` = de, en; `en.lproj` und `de.lproj` enthalten `Localizable.strings`, `.stringsdict` und
`InfoPlist.strings`. Hinweis: Auf einem Mac in einer dritten Sprache (z. B. Französisch) zeigt die App Deutsch,
Sparkles Dialoge aber Sparkles Französisch – wie vor 1.3.

## Prüfen ohne Start der App

Target `ScoopsConnectRenderTests` (im Schema `ScoopsConnect`): übersetzt die App-Quellen ohne `@main` und ohne Sparkle
(`RenderTests/AppUpdaterStub.swift`) noch einmal, startet weder Server noch Updater, fragt keine Rechte an und ruft
Tailscale nie auf (`setup.offline`). `RenderBundle` leitet die Nachschlage-Wege von `Bundle.main` (auch die von
`String(localized:)`) an die Catalogs des Test-Bundles in der gewählten Sprache weiter.

```sh
cd App && xcodegen generate
xcodebuild build-for-testing -project AISBot.xcodeproj -scheme ScoopsConnect -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/scoops-serverapp-en" CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_SCOOPS_RENDER_DIR=~/Desktop/serverapp-bilder xcodebuild test-without-building -project AISBot.xcodeproj \
  -scheme ScoopsConnect -destination 'platform=macOS' -derivedDataPath "$TMPDIR/scoops-serverapp-en" \
  -only-testing:ScoopsConnectRenderTests CODE_SIGNING_ALLOWED=NO
```

- `LocalizationTests`: Catalogs vollständig (beide Dateien), Platzhalter gleich, Mehrzahl in beiden Sprachen, umgebaute
  deutsche Sätze Zeichen für Zeichen wie vorher, englische Sätze ohne Tausendertrennzeichen, `Accept-Language`,
  Regel für die Sprache des Inhabers.
- `RenderTests`: 30 Ansichten je Sprache als PNG (Assistent in allen Schritten und Zuständen, Menüleiste, Einstellungen,
  Rechnerzugriff, KI-Abos, Fehlermeldungen, Rückfrage „Rechner trennen?“, Rechner-Rolle). Ohne
  `SCOOPS_RENDER_DIR` landen sie in einem temporären Ordner. `SCOOPS_RENDER_ONLY=01,30` rendert nur diese Nummern,
  `SCOOPS_RENDER_PLAIN=1` ohne App-Symbol und -Version (für Vergleiche mit älteren Bildern).

Für 1.3 wurden die deutschen Bilder vor und nach der Umstellung pixelweise verglichen: gleich bis auf den
Zeilenumbruch einer Fußzeile (siehe unten) und die gewollte Layout-Korrektur der Schlüsselfelder.

## Bekannte Grenzen

- Nicht gerendert (nur im echten Betrieb sichtbar): SwiftUI-`.alert`s (Funnel, Ruhezustand, alte Installation), Sparkles
  Dialoge, die Berechtigungsdialoge von macOS (deren Text kommt aus `InfoPlist.xcstrings`), `NSOpenPanel`, das
  Menüleisten-Symbol samt Bedienungshilfen-Text, VoiceOver-Ausgaben.
- Die Fortschrittszeile unten in der Seitenleiste des Assistenten („Schritt 1 von 7 · etwa 10 Minuten insgesamt“) bricht
  im Rendering an anderer Stelle um als vorher (gleicher Text; der übersetzte Text trägt jetzt eine Sprache, das
  ändert den Umbruch).
- Die Anleitungen nennen Menüpfade in AIS Scoops („Your Servers → Add Server“, „Settings → Computers → Add Computer“,
  „Settings → Connect Apps“, „Connect Apps → Apple“). Sie passen wörtlich zur englischen App 1.3; ältere, nur deutsche
  Apps zeigen die deutschen Namen.
