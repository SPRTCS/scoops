# Neu in 1.3

Stand: 20.11.2026 · **App 1.3** (iPhone, iPad, Mac, Watch) · **Server 1.39.0** · Mac-App **AIS Scoops Server 2.0**
(eigene Versionsnummer, bringt den Server mit). Zweig `release/1.3`.

Kurzer Überblick; die Einzelheiten stehen in den verlinkten Dateien, die Schnittstelle in [API.md](API.md#app-13-server-ab-139).

| Bereich | Was neu ist | Doku |
|---|---|---|
| Suche und Chat-Komfort | Suche über alle Chats mit Sprung zur Fundstelle, Zum-Ende-Knopf, eigene Nachricht bearbeiten, Link-Vorschauen | [suche-chat.md](suche-chat.md) |
| Heute | Startseite über alle Scoops: offene Freigaben (Postfach), Aufgaben zum Prüfen, laufende Arbeit, Routinen des Tages; Board- und Bibliothekssuche | [heute.md](heute.md) |
| Systemintegration | Teilen-Menü, Kurzbefehle und Siri, Controls im Kontrollzentrum und Action-Button, Spotlight | [system.md](system.md) |
| Ruhe | Chats stummschalten, Ruhezeiten pro Person | [ruhe.md](ruhe.md) |
| Scoop-Vorlagen | Scoop als `.scoop`-Datei teilen und importieren, ohne Persönliches; drei Beispiele | [vorlagen.md](vorlagen.md), [vorlagen/](vorlagen/) |
| Bilder | Scoops erstellen und bearbeiten Bilder, nur über das ChatGPT-Abo (Codex), kein API-Weg | [bilder.md](bilder.md) |
| Mitwachsende Schrift | App auf iPhone und iPad folgt der Textgröße des Systems (Dynamic Type) | [../App/README.md](../App/README.md#schriftgröße-dynamic-type) |
| Englisch | App, Server und Server-App sprechen Deutsch und Englisch; Sprache pro Person auf dem Server | [sprache.md](sprache.md) (Vertrag, Glossar), [sprache-app.md](sprache-app.md), [sprache-serverapp.md](sprache-serverapp.md) |

## Zusammenspiel der Versionen

- **App 1.3 mit älterem Server:** Der Server meldet seine Fähigkeiten in `GET /api/health` (`search`, `today`, `mute`,
  `quiet_hours`, `templates`, `images`, `languages`). Fehlt ein Feld, blendet die App die Funktion aus. Ohne
  `languages` setzt sie keine Sprache; die Servertexte bleiben dann deutsch, auch in der englischen App
  (geprüft gegen Server 1.38.2).
- **Ältere App mit Server 1.39:** Die alte App schickt `Accept-Language: de` und setzt keine Sprache; alles bleibt wie
  bisher.
- **Sprache:** Die App setzt nach dem Verbinden die Sprache der Person auf dem Server (`PATCH /api/settings/language`);
  danach kommen Ereignisse, Statuszeilen, Freigabe-Karten, Mitteilungen und Fehlermeldungen in dieser Sprache. Die
  Mac-App setzt die Sprache des Inhabers nur, wenn noch keine gespeichert ist.

## Prüfen

- Server: `Server/bin/test` (alle Testdateien, darunter `test_i18n.py` für die Vollständigkeit der englischen Tabellen
  und `test_englisch.py`), Probedurchlauf offline mit 21 Abläufen ([probelauf.md](probelauf.md), Ablauf 21 = Englisch).
- App: `App/scripts/strings.py check`, `App/scripts/check-fonts.sh`, UI-Tests `AISBotUITests` (deutsch und englisch),
  `WatchLogicTests`; Server-App: `ScoopsConnectTests`, `ScoopsConnectRenderTests` (Catalogs, Renderings je Sprache).
