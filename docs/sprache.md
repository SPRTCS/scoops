# Sprache: Deutsch und Englisch

Stand: App 1.3, Paket G1 (Server). Umsetzung: `Server/src/aisbot/i18n.py`, englische Texte in
`Server/src/aisbot/i18n_en/`, Sprachvorgabe für die Scoops in `Server/src/aisbot/prompts.py` (`language_note`).
Tests: `Server/tests/test_i18n.py` (Tabelle gegen Quelltext), `Server/tests/test_englisch.py` (Abläufe auf Englisch),
Probedurchlauf Ablauf 21 ([probelauf.md](probelauf.md)).

Der Server spricht Deutsch und Englisch. **Deutsch ist Standard und Quellsprache**: Für deutsche Nutzer bleibt jeder
Text Zeichen für Zeichen wie bisher. Eine englische Person bekommt vom Server keine deutschen Texte, und ihre Scoops
sprechen Englisch mit ihr.

## Welche Sprache gilt

Die Sprache gehört zu einer **Person**: dem Inhaber des Servers und getrennt jedem Gast geteilter Scoops
([sharing.md](sharing.md)). Sie liegt auf dem Server (Tabelle `user_languages`, Inhaber mit `user_id = ""`), damit auch
Mitteilungen, Routinen, Aufgaben und Initiative die richtige Sprache haben, wenn gerade keine App fragt.

| Wofür | Sprache |
|---|---|
| Antwort auf eine Anfrage (Fehlermeldungen, Kataloge, Hinweise, Einstellungen) | `?lang=` > gespeicherte Sprache der anfragenden Person > `Accept-Language` > Deutsch |
| Einrichtung (`/api/setup…`, Mac-App vor der Kopplung) | `?lang=` > `Accept-Language` > gespeicherte Sprache des Inhabers > Deutsch |
| Gespeicherte Texte in Chats (Ereigniszeilen, Statuszeilen, Freigabe-Karten, Board-Einträge) | Sprache des **Inhabers** beim Entstehen, auch in Gruppen und geteilten Chats |
| Hintergrund (Routinen, Erinnerungen, Aufgaben, Initiative, Planer) und Mitteilungen an den Inhaber | Sprache des Inhabers |
| Texte ausdrücklich für einen Gast (z. B. sein Tageslimit, Sprechmodus des Gasts) | Sprache des Gasts |
| Antworten des Scoops | Sprache der Person, für die der Lauf ist (Gast-Lauf: Gast, sonst Inhaber); schreibt die Person erkennbar in einer anderen Sprache, folgt der Scoop ihr |

Ohne gespeicherte Sprache gilt im Hintergrund Deutsch. `Accept-Language` wird nicht gespeichert; sie wirkt nur auf
die Antwort der jeweiligen Anfrage. Alte Einträge werden beim Wechsel nicht umgeschrieben (Ausnahme: die Begrüßung des
Start-Scoops, siehe unten).

## Vertrag für die Apps

### Endpunkt

`GET /api/settings/language` und `PATCH /api/settings/language` – für den Inhaber und (getrennt) für Gäste mit
mindestens einem Share, wie `/api/settings/quiet-hours`.

```json
{"language": "en", "stored": "en", "available": ["de", "en"], "default": "de"}
```

- `language`: wirksame Sprache dieser Anfrage (gespeichert, sonst `Accept-Language`, sonst `de`).
- `stored`: gespeicherte Sprache oder `null`.
- `PATCH` mit `{"language": "en"}` bzw. `"de"` speichert; `{"language": null}` löscht (dann gilt wieder die Kopfzeile
  bzw. Deutsch). Regionale Codes werden gekürzt (`en-GB` → `en`). Unbekannte Sprache oder fehlendes Feld → 400.
- WebSocket: `language.updated` mit denselben Daten an die Geräte genau dieser Person (Gäste über ihre Verbindungen).
- Die Einrichtung setzt die Sprache des Inhabers auch über `PATCH /api/setup/config` mit `{"language": "en"}` (nur lokal,
  wie die übrigen Einrichtungsfelder). `GET /api/setup` meldet sie unter `server.language` (gespeichert oder `null`) und
  `server.languages`.

### Kopfzeile, Parameter, Fähigkeit

- Jede Anfrage darf `Accept-Language` mitschicken (URLSession tut das von selbst nach den Sprachen der App). Der Server
  nimmt die erste unterstützte Sprache nach q-Wert. `?lang=de|en` geht für diese eine Antwort vor.
- `GET /api/health` → zusätzlich `"languages": ["de", "en"]` und `"language"` (wirksame Sprache der Anfrage). Gäste
  bekommen dieselben Felder in `GET /api/shared/me`. Fehlt `languages` (älterer Server), schickt die App nichts und
  zeigt keine Sprachwahl für den Server.
- Sprechmodus (`/api/voice/live`, WebSocket ohne Middleware): gespeicherte Sprache der sprechenden Person, sonst
  `?lang=` bzw. `Accept-Language` des WebSocket-Aufbaus. Probehören (`POST /api/voice/live/preview`) hat je Sprache
  einen eigenen Probesatz.

### Empfohlener Ablauf in der App

1. Beim Start und wenn sich die Sprache der App ändert: `GET /api/health` (Gäste: `/api/shared/me`). Steht die
   App-Sprache in `languages` und weicht `stored` von ihr ab, `PATCH /api/settings/language` mit der App-Sprache.
   Die Server-App (Scoops Connect / AIS Scoops Server) setzt in der Einrichtung `language` über `/api/setup/config`.
2. Spricht die App eine Sprache, die der Server nicht kann (oder ist der Server älter), nichts setzen: Der Server
   bleibt bei Deutsch.
3. Gäste setzen ihre eigene Sprache; sie ändert nichts für den Inhaber.

### Was der Server übersetzt liefert

- Fehlermeldungen (`{"error": "…"}`), Hinweise und Status in Einstellungen (KI-Abos, Arbeitsordner, Apple-Dienste,
  Verbindungen, eigene MCP-Server, Rechner, Nutzung und Limits, Ausgabenlimit, Demo-Sperre).
- Kataloge: Modell-Hinweise (`/api/models`), Apps und Kategorien (`/api/connections/…`), Stimmen des Sprechmodus.
- Texte, die im Chat gespeichert werden: Ereigniszeilen (`role = "event"`), Statuszeilen (`meta.lines`), Freigabe-Karten
  (Text, Titel und Details, soweit der Server sie baut), Fehlertexte als Antwort des Scoops, Hinweise wie „Sag „mach
  weiter“ …“, Zeitplan-Texte von Erinnerungen und Vorlagen (`schedule_text`).
- Aufgaben: Statuszeilen (`lines`), Ereignisse, `error`, `waiting_for` bei `waiting_kind = "scoop"` (Englisch klein
  geschrieben: „reply from Lio“, damit es hinter „Waiting for“ passt).
- Mitteilungen (Titel und Text, auch „Asks for approval: …“), Live-Aktivitäten (Statuszeile, Sammel-Aktivität).
- Einrichtungstexte für die Mac-App, Begrüßung und Charakter des Start-Scoops, Standardnamen (z. B. Dateinamen „Image …“).

Nicht übersetzt werden: Texte, die ein Modell oder ein Mensch geschrieben hat (Antworten, Titel von Aufgaben,
Gedächtnis-Einträge, Namen), Werte von Fremddiensten (Composio-Beschreibungen kommen englisch, Fehlertexte von Apple,
OpenAI usw. unverändert), Feldnamen, Aufzählungswerte und IDs.

### Was die App selbst übersetzt

- Alle eigenen Oberflächentexte, auch die, die sie aus Aufzählungswerten baut: Zustände und Spalten von Aufgaben
  (`state`, `column`, `waiting_kind`), Arten von Freigaben (`kind`), Rollen (`read|write|edit|admin`), Rechner-Stufen,
  `kind` von Routinen (`routine|erinnerung`), Bibliotheksarten (`datei|bild|link`), Gedächtnisarten.
- Datum, Uhrzeit, Zahlen und Beträge aus ISO-Zeitstempeln und Zahlenfeldern (der Server formatiert nur in fertigen Sätzen).
- Zusammengesetzte Texte wie „Wartet auf \(waiting_for)“ bzw. „Waiting for \(waiting_for)“.

### Stellen, an denen Apps Servertexte ausgewertet haben

Erledigt in App 1.3: Die App erkennt die Begrüßung des Start-Scoops an `meta.welcome` (Textanfang nur noch als Rückfall
für ältere Server), fehlende Nachrichten an `APIError.fromServer` statt am Wort „Nachricht“, gespeicherte Fähigkeiten an
`meta.skill_id`, und sie baut „Waiting for …“ um `waiting_for` selbst. Einzelheiten und die übrigen Stellen:
[sprache-app.md](sprache-app.md#stellen-an-denen-die-app-texte-ausgewertet-hat). Die Server-App vergleicht keine Texte
mehr ([sprache-serverapp.md](sprache-serverapp.md#regeln-im-code)).

Der Server selbst wertet eigene Texte an diesen Stellen aus und erkennt beide Sprachen: harmlose Arbeitsschritte beim
Bearbeiten einer Nachricht (`chat_edit.py`), Tagebuch-Einträge in Gruppen, die Sperrliste für „Immer erlauben“
(Titel mit Zahlung, Login, Schloss … – auch englische Wörter), `@alle`/`@all`/`@everyone`, Vorlagen-Erkennung von
Apple-Diensten.

## Scoops sprechen die Sprache der Person

Die Anweisungen an die Modelle bleiben deutsch. Für Englisch hängt der Server einen kurzen Block auf Englisch an
(`prompts.language_note`): alles, was Menschen lesen (Antworten, Rückfragen, gesprochene Antworten, Titel und
Zusammenfassungen von Aufgaben, Gedächtnis- und Tagebucheinträge, Titel von Routinen, Texte von Freigabe-Karten,
Dateinamen und -inhalte), auf Englisch; keine deutschen Beispielsätze oder Begrüßungen aus den Anweisungen übernehmen;
Steuerzeichen wie `[NICHTS]` unverändert; schreibt die Person erkennbar in einer anderen Sprache, folgt der Scoop ihr.
Für Deutsch kommt nichts dazu, der Prompt bleibt gleich.

Der Block kommt in allen Wegen an (geprüft in `test_englisch.py`):

- Chat, Gruppen, Initiative des Haupt-Scoops, Routinen und Erinnerungen (`bots.py::_run_once`), über API-Engine,
  OpenAI-Engine, Claude Code (Abo) und Codex (Abo);
- Aufgaben (`tasks.py::_system`: Claude Agent SDK `append`, Codex `developer_instructions`, Responses-Schleife); der
  Satz „sprechende Dateinamen auf Deutsch“ wird für Englisch zu „auf Englisch“;
- Sprechmodus (`live_voice.py`: „Sprich Englisch“, englische Begrüßung);
- Gast-Läufe: mit der Sprache und dem Namen des Gasts.

**Start-Scoop „Pip“** (Edition `standard`): Er entsteht beim ersten Start, bevor eine Sprache bekannt ist. Wird die
Sprache des Inhabers gesetzt, tauscht der Server Begrüßung, Label und Charakter, solange der Chat nur aus der
unveränderten Begrüßung besteht und Label/Charakter unverändert sind (`message.updated`, `bot.updated`). Die
Begrüßung trägt `meta.welcome = true`.

## Glossar (Server, App und Server-App)

Das einzige Glossar für alle drei Teile; [sprache-app.md](sprache-app.md) und [sprache-serverapp.md](sprache-serverapp.md)
verweisen hierher. **Schreibweise:** Knöpfe, Titel, Abschnitte, Menüpunkte, Tabs und Picker-Optionen in **Title Case**
nach Apple („Quiet Hours“, „Voice Mode“, „Connect Apps“, „Always Allow“), im Satz klein („turn on quiet hours“).
Amerikanisches Englisch, knapp, freundlich und direkt; Anführungszeichen “…” mit Satzzeichen innen, Oxford Comma,
Ellipse ohne Leerzeichen („Loading…“), Uhrzeit im 12-Stunden-Format („9:00 AM“, Server: `i18n.clock`).

| Deutsch | Englisch (Bezeichnung) | im Satz |
|---|---|---|
| Scoop, Scoops | Scoop, Scoops | Scoop (immer groß) |
| Haupt-Scoop | Main Scoop | Main Scoop |
| Freigabe, Freigabe-Karte | Approval | approval, approval card |
| Freigeben / Ablehnen / Immer erlauben | Approve / Decline / Always Allow | |
| Dauerhafte Freigaben | Standing Approvals | standing approvals |
| Routine, Erinnerung, Aufgabe | Routine, Reminder, Task | routine, reminder, task |
| Board – Offen, Geplant, In Arbeit, Zu prüfen, Abgeschlossen | Open, Scheduled, Running, Review, Done | (iPhone-Segment „Geplant“: Planned) |
| Bibliothek, Tresor | Library, Vault | library, vault |
| Apps verbinden, Verbindung | Connect Apps | connection |
| Eigene MCP-Server | Custom MCP Servers | custom MCP server |
| Ruhezeiten, Stummschalten | Quiet Hours, Mute | quiet hours, mute |
| Vorlage, Scoop-Vorlage | Template | template, Scoop template |
| Heute | Today | |
| Sprechmodus, Diktat | Voice Mode | voice mode, dictation |
| Gedächtnis, Fähigkeit | Memory, Skill | memory, skill |
| Charakter (Profil „Persönlichkeit“) | Personality (Profilseite: Persona) | personality |
| Rechner, Bot-Rechner, Rechnerzugriff | Computers (Abschnitt), Bot Computer, Computer Access | computer |
| Arbeitsordner | Workspace | workspace |
| Gast, geteilt, Mit mir geteilt | Shared with Me | guest, shared |
| Inhaber / Admin, Gruppe | | owner / admin, group |
| KI-Abos, KI-Abo | AI Subscriptions | AI subscription |
| Abrechnung: API-Schlüssel / Abo / Abo, bei Limit API | API Key / Subscription / Subscription, Then API | API key |
| Nutzung und Verbrauch, Kosten, Ausgabenlimit | Usage and Costs, Costs | spending limit |
| Einrichtung, koppeln, Kopplungscode | Setup, Pairing Code | setup, pair, pairing code |
| Deine Server, Server hinzufügen | Your Servers, Add Server | |
| Einführung | Onboarding | |
| Befehlspalette, Bereich (Seitenleiste) | Command Palette, Section | |
| Server-App: Erreichbarkeit, KI-Zugang, Mit der App verbinden | Remote Access, AI Access, Connect the App | |
| Server-Mac, Server-App | | server Mac, server app |
| Statuszeilen (3. Person Präsens) | | „Checks your calendar“, „Opens Safari“ |

Produktnamen bleiben: AIS Scoops, Scoops Connect, AIS Scoops Server, Claude Code, Codex, ChatGPT.

**Menüpfade über Grenzen hinweg** müssen wörtlich zur englischen Bezeichnung des Ziels passen. Geprüft für 1.3:
Server-App → App „Your Servers → Add Server“, „Settings → Computers → Add Computer“, „Settings → Connect Apps“,
„Connect Apps → Apple“; App → Server-App „Connect the App“, „AIS Scoops Server → Remote Access → Tailscale“;
Server → beide Apps „AI Subscriptions“, „Connect Apps“ › „Custom MCP Servers“, „Subscription, Then API“, „API Key“.

## Für Entwickler

```python
from .i18n import N_, translate, tx, txn

raise HTTPException(404, tx("Bot nicht gefunden"))
self._add(chat_id, "event", tx("Routine angelegt: {title} · {schedule}", title=t, schedule=s))
txn("{n} Scoop arbeitet", "{n} Scoops arbeiten", n)
MODES = {"ask": N_("Immer genehmigen")}          # beim Import gebaut → bei der Ausgabe translate(MODES[m])
```

- Der deutsche Text bleibt im Code und ist der Schlüssel. Erstes Argument immer ein fester String (kein f-String),
  Platzhalter als Schlüsselwörter. Ganze Sätze übersetzen, nicht stückeln.
- Die Sprache steht in einer Kontextvariable: Anfragen setzt die Middleware `language` in `server.py`, alles andere
  nimmt die Sprache des Inhabers. Für Texte an einen bestimmten Gast `with i18n.for_user(uid):`, für Chat-Texte aus der
  Anfrage eines Gasts `with i18n.for_owner():`.
- `i18n.decimal`, `i18n.weekday`, `i18n.month`, `i18n.clock` für Zahlen, Daten und Uhrzeiten in Sätzen.
- Neue Texte: in die passende Bereichsdatei `i18n_en/<bereich>.py` (`chat`, `aufgaben`, `server`, `dienste`, `engines`,
  `kataloge`). Gleiche deutsche Texte in mehreren Bereichen müssen gleich übersetzt sein.
- `tests/test_i18n.py` meldet fehlende und übrige Einträge, Platzhalter ohne Wert oder mit Abweichung, f-Strings,
  falsche Mehrzahl, Umlaute im Englischen.
- Modellkatalog: Ein Eintrag darf `hint_en` mitbringen (hat Vorrang, auch in einer Fernkopie); sonst übersetzt die
  Tabelle den deutschen `hint`.

### Was bewusst deutsch bleibt

- Systemanweisungen, Werkzeugbeschreibungen, Rückgaben von Werkzeugen an das Modell und `[Ereignis: …]`-Hinweise: Sie
  liest nur das Modell, die Sprachvorgabe regelt die Ausgabe. Ein Umbau würde das Verhalten der deutschen Scoops ändern.
- Protokollzeilen, Ausgaben der Kommandozeile (`bin/aisbot`), Prüffehler des Modellkatalogs (nur für die Pflege).
- Ordnernamen auf der Platte („Dateien“, „Aufgaben“) im Arbeitsordner.
- Werte in `meta`, die Apps nicht anzeigen (z. B. `meta.prompt` von Bild-Ereignissen).

## Eine weitere Sprache hinzufügen (z. B. Französisch)

1. `i18n.LANGS` um `"fr"` ergänzen und in `i18n._table` die Tabelle laden (z. B. Paket `i18n_fr` mit denselben
   Bereichen; `__init__.py` von `i18n_en` als Vorlage).
2. Alle Einträge übersetzen; `tests/test_i18n.py` für die neue Tabelle laufen lassen (Schleife über die Sprachen
   ergänzen).
3. `prompts.LANGUAGE_NOTES["fr"]` (am besten in der Zielsprache) und in `live_voice.py` `SPEAK`, `GREETING`,
   `PREVIEW_*` ergänzen; `i18n._WEEKDAYS`, `_WEEKDAYS_SHORT`, `_MONTHS`; Datumsformate an den Stellen, die
   `i18n.current() == "de"` abfragen (z. B. `tasks._human_time`, Erinnerungen in `bots.py`).
4. Start-Scoop, Modell-Hinweise (`hint_fr` im Katalog), Glossar hier ergänzen; `test_englisch.py` als Vorlage für
   einen Test der neuen Sprache.

## Bekannte Lücken

- Geteilte Chats und Gruppen speichern Texte in der Sprache des Inhabers: Ein englischer Gast eines deutschen Inhabers
  sieht dort deutsche Ereignis- und Statuszeilen (so vorgegeben). Antworten des Scoops an den Gast sind englisch.
- Texte, die im Hintergrund entstehen und später über eine Anfrage gelesen werden (z. B. `last_error` der Kopplung
  oder des Arbeitsordners, eine gespeicherte Abo-Sperre), haben die Sprache des Inhabers, nicht die der anfragenden
  Mac-App.
- Ohne Namen in Konto und Einrichtung heißt der Nutzer in Prompts und in `user_name` weiter „du“.
- Neuere Modell-Hinweise aus einer Fernkopie ohne `hint_en` und ohne Tabelleneintrag bleiben deutsch.
- Wechselt die Sprache mitten in einer fortgesetzten Codex-Sitzung, ist offen, ob Codex neue `base_instructions`
  übernimmt; spätestens ein neuer Thread hat die neue Vorgabe.
- Ältere Apps (vor 1.3) sind nur deutsch und senden `Accept-Language: de`; sie bekommen weiter deutsche Texte.
