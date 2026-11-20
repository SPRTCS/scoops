# Sprache der App „AIS Scoops“ (Deutsch und Englisch)

Stand: App 1.3, Paket G2. Gegenstücke: Server und Glossar [sprache.md](sprache.md), Server-App
[sprache-serverapp.md](sprache-serverapp.md). Regeln für neuen Code: `App/README.md`, Abschnitt „Sprachen“.

Die App (iPhone, iPad, Mac), ihre Widgets und Live-Aktivitäten, die Teilen- und Mitteilungs-Erweiterung, die Uhr mit
Komplikationen, die Kurzbefehle und Controls sprechen Deutsch und Englisch. **Deutsch ist Quellsprache und Rückfall**;
auf einem deutschen Gerät bleibt jeder Text wie vor 1.3. Welche Sprache gilt, entscheidet das System (bevorzugte
Sprachen des Geräts bzw. „Sprache“ pro App); `AppLanguage.code` liefert „de“ oder „en“.

## Aufbau

| Datei | Inhalt |
|---|---|
| `App/Shared/Localization/Localizable.xcstrings` | alle Oberflächentexte, ein Catalog für alle Targets |
| `App/*/InfoPlist.xcstrings` | je Target: Anzeigename, Berechtigungen (App), Dateityp „Scoop-Vorlage“ |
| `App/AISBot/Resources/AppShortcuts.xcstrings` | Siri-Sätze der Kurzbefehle (deutsch im Code, englisch als `stringSet`) |
| `App/Shared/Support/AppLanguage.swift` | Sprache, `Locale.app`, `Accept-Language`, Sprache für Diktat/Stimme, `demoText` |
| `App/AISBot/Networking/APIClient+Sprache.swift` | `LanguageService`: Sprache der Person auf dem Server |
| `App/scripts/strings.py` | bauen, abgleichen, Übersetzungen einspielen, prüfen |

**Ein gemeinsamer Catalog statt einem je Target:** `Shared` wird in fünf Targets kompiliert (App, Widgets,
Teilen-Erweiterung, Uhr, Tests), Komplikationen und Mitteilungs-Erweiterung nehmen einzelne Dateien daraus.
`String(localized:)` und `Text("…")` suchen im Bundle des jeweiligen Targets. Liegt derselbe Catalog in jedem Target,
findet jeder Code-Pfad seine Texte, ohne Tabellennamen im Code und ohne doppelte, auseinanderlaufende Übersetzungen.
Preis: Jede Erweiterung trägt alle Texte (rund 0,6 MB Quelle, kompiliert je Sprache wenige hundert KB). Eigene
Tabellen für Shared-Code hätten bei jedem `Text("…")` in Shared einen `tableName` verlangt und Fehler leicht gemacht.

**Demo-Inhalte nicht im Catalog:** Der Demo-Modus (`-mock`, Uhr `-demo`) ist Beispielinhalt, keine Oberfläche. Er steht
zweisprachig im Code (`demoText("deutsch", en: "english")`, Werte über `AppLanguage.isGerman`). So bleibt die deutsche
Demo Zeichen für Zeichen gleich, die englische darf inhaltlich abweichen (USD, New York/Boston, US-Firmen), und
mehrere hundert lange Chattexte landen nicht in jeder Erweiterung.

## Server-Vertrag (docs/sprache.md)

- **Accept-Language** bei jeder Anfrage: `APIClient` (Sitzung und Bildschirm-Abruf), `EventSocket`, Sprechmodus
  (zusätzlich `?lang=`), `SystemService` (Teilen-Erweiterung, Kurzbefehle, Controls), Uhr (`WatchAPI`) und die
  Weiterleitung der Uhr über das iPhone (`WatchBridge`). Englisch: `en, de;q=0.5`, sonst `de`.
- **Gespeicherte Sprache:** Nach dem Verbinden fragt die App `GET /api/health` → `languages`. Kann der Server die
  App-Sprache und weicht `stored` aus `GET /api/settings/language` ab, setzt sie `PATCH /api/settings/language`.
  Ebenso als Gast auf fremden Servern (mit dem Konto, eigene Sprache des Gasts). Ältere Server ohne `languages`:
  keine Anfrage, alles wie bisher. Demo-Modus: nichts.
- **Diktat:** `POST /api/transcribe?language=` mit der App-Sprache statt fest `de`.
- `language.updated` per WebSocket wird nicht ausgewertet: Die App-Sprache bestimmt das Gerät, nicht der Server.

## Stellen, an denen die App Texte ausgewertet hat

| Stelle | Vorher | Jetzt |
|---|---|---|
| `Shared/Support/OnboardingLogic.swift` `isFreshServer` | Label „Start“ + Anfang „Hallo! Ich bin **“ | `meta.welcome` (neu in `MessageMeta`); Text nur Rückfall für ältere Server |
| `AISBot/Search/AppStore+Suche.swift` (2×) | `APIError.message.contains("Nachricht")` | `APIError.fromServer` (Fehlerfeld des Servers vs. `{"detail":"Not Found"}`) |
| `AISBot/Views/Chat/MessageViews.swift` Fähigkeits-Ereignis | Textanfang „Fähigkeit gespeichert“ | nur `meta.skill_id` / `meta.icon` |
| `Shared/Models/Tasks.swift`, `MessageViews.swift` | „Wartet auf “ + `waiting_for` geklebt | ganzer übersetzter Satz mit `waiting_for` als Platzhalter |
| `AISBot/Store/AppStore.swift` `skill(for:)` | Name hinter „:“ | zuerst `meta.skill_id`, Text als Rückfall (klappt in beiden Sprachen) |
| `AISBot/Views/Chat/Replies.swift` | `name == "Du"` (3×) | `AppStore.isOwnReply` |
| `AISBot/Views/Chat/ComposerMode.swift` | Vorspann der Eingabemodi verglichen | Tabelle Deutsch/Englisch, erkennt beide |
| `ComposerView.swift`, `MarkdownView.swift` | `@alle` | `@alle`/`@all`/`@everyone` (Server versteht alle) |
| `Shared/Widget/LimitsWidgetViews.swift` | `replacingOccurrences("Wöchentlich", "Woche")` | Label am „ · “ getrennt |
| `OnboardingMessageStep.swift` `purpose(for:)` | Label-Text des Scoops | Zweck-ID des Entwurfs, Label als Rückfall |
| `ServersView.swift` `offlineText` | „vor “ aus relativer Zeit entfernt | nur noch auf Deutsch |
| `UsageView.swift` Stand-Zeile | Quelle als Textstück eingeklebt | drei ganze Sätze |

Bleibt bewusst: Pfeil „→“ in Übergabe-Ereignissen (sprachneutral), `CloudService.isUnauthorized` vergleicht
zusätzlich „nicht angemeldet“ (deutsche Meldungen des Konto-Dienstes; Status 401/403 zuerst).

## Was deutsch bleibt

- Rückgaben der Apple-Brücken an den Server bzw. das Modell (`AppleBridgeError` in Home, Wecker, Standort): Protokoll,
  wie die Werkzeug-Rückgaben auf dem Server. Das Modell antwortet dem Nutzer in seiner Sprache.
- Protokollzeilen, Debug-Werkzeuge (`-perfbench`, `-keychainselftest`, `-render-assets`, Maskottchen-Übersicht),
  Ordnernamen im Arbeitsordner („Dateien“, „Aufgaben“), Befehl `/aufgabe`, Produktnamen.
- Texte vom Server sind so, wie der Server sie liefert (Englisch ab Server mit Sprachen; in geteilten Chats und Gruppen
  in der Sprache des Inhabers, siehe sprache.md).

## Glossar

Es gilt das gemeinsame Glossar in [sprache.md](sprache.md#glossar-server-app-und-server-app), dort auch Schreibweise
(Title Case für Knöpfe und Titel) und die geprüften Menüpfade zwischen App, Server-App und Server.

## Prüfen

`python3 scripts/strings.py check` (nach `build`): Catalogs vollständig, Platzhalter, keine Umlaute im Englischen,
keine deutschen Literale am Catalog vorbei. UI-Test `EnglishUITests` (Einführung und Hauptansichten auf Englisch).
Englisch im Simulator: `-mock -AppleLanguages "(en)" -AppleLocale en_US`. Achtung: Simulatoren übernehmen manchmal
Format-Vorgaben des Macs (24-Stunden-Uhr, Komma) in `defaults -g` (`AppleICU…`); die App folgt ihnen wie gewollt.

## Bekannte Grenzen

- Mehrzahl auf Deutsch übernimmt alte Eigenheiten Zeichen für Zeichen (z. B. „1 Protokolle“, „1 brauchen dich“).
- Formate folgen jetzt Sprache und Region des Geräts (vorher fest `de_DE`): Ein deutsches Gerät mit Region Österreich
  oder eigener Uhrzeit-Vorgabe sieht deren Formate.
- Nur auf echten Geräten prüfbar: Siri-Sätze, Mitteilungen samt Absenderbild, Wecker (AlarmKit), Mac-App zur Laufzeit,
  Uhr (kein watchOS-Simulator installiert; gebaut, nicht angesehen).
