# AIS Bot – Server-API (v1, Stand: Server 1.40, App 1.3)

Vertrag zwischen Bot-Server (Python, läuft auf dem Agenten-Air) und der App (SwiftUI, iPhone/iPad/Mac).

## Verbindung

- Basis-URL: über Tailscale `https://<dein-mac>.<tailnet>.ts.net` (Tailscale Serve, gültiges Zertifikat) oder lokal `http://127.0.0.1:8787`.
- Jede Anfrage: Header `Authorization: Bearer <token>`. Für Bild-URLs und WebSocket alternativ `?token=<token>`.
- Kopplung: Der Server erzeugt einen Link `aisbot://pair?url=<basis-url>&token=<token>`. Die App übernimmt beides. Alternativ trägt man URL und Token in den Einstellungen ein.
- JSON in snake_case. Zeitstempel als ISO-8601 mit Zeitzone (`2026-11-11T21:05:00+01:00`). IDs sind Strings.

## Objekte

### Bot
```json
{
  "id": "b_9f2c",
  "name": "Mila",
  "label": "Assistenz",
  "mascot": {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"},
  "character": "locker, präzise, duzt",
  "model": "claude-haiku-5-5",
  "escalation_model": "claude-sonnet-5-5",
  "pinned": true,
  "section": "Arbeit",
  "created_at": "…",
  "last_message": { Message } | null,
  "unread": 2,
  "busy": false
}
```
- `mascot.shape`: `bean | pear | cloud | egg | blob | star | drop | bun | ghost | flower` sowie (v1.1) die symmetrischen Formen `circle | oval_tall | oval_wide | square | rect_tall | rect_wide | triangle | diamond | hexagon | heart | arrow | pill | flower_round | star_soft`. Unbekannte Werte zeigt die App als `bean`.
- `mascot.color`: Hex-Farbe
- `mascot.eyes`: `dots | ovals | diamonds | happy | sleepy | sparkle`
- `mascot.accessory`: `none | beret | bowtie | glasses | headphones | cap | flower | crown | beanie | tophat | cowboy | partyhat | wizard | halo | hair_bow | cat_ears | bunny_ears | horns | headset | sunglasses | monocle | tie | scarf` (freier Text; ab App-Build 12 alle genannten, ältere Apps zeigen unbekannte Werte ohne Accessoire)
- `model`: `claude-haiku-5-5 | claude-sonnet-5-5 | claude-opus-5-5`
- `avatar` (v1.12): `{"version": 1794577394092, "url": "/api/bots/{id}/avatar?v=…"}` oder `null` = Maskottchen. Mit eigenem Bild steht zusätzlich `mascot.photo = {"id": "<bot-id>", "version": …}` im Maskottchen (abgeleitet, wird beim Speichern ignoriert). Siehe „v1.12 – Eigenes Scoop-Bild“.

### Message
```json
{"id": "m_123", "bot_id": "b_9f2c", "role": "bot", "text": "…", "created_at": "…", "meta": {}}
```
`role`:
- `user`: Nachricht von Arman (rechts, Blase)
- `bot`: Antwort des Bots (links, Blase, Markdown: **fett**, Listen, Links)
- `event`: kleine, zentrierte Systemzeile („Routine angelegt: Morgenbriefing“, „Routine ausgelöst: …“). `meta.icon`: SF-Symbol-Name (optional)
- `status`: Arbeitsfortschritt eines Laufs, wird während des Laufs per `message.updated` aktualisiert. `meta`:
  ```json
  {"run_id": "r_1", "state": "running|done|failed|stopped", "lines": ["Schaut in deinen Kalender", "Ist im Browser auf google.com"],
   "uses_computer": true, "model": "claude-haiku-5-5", "cost_usd": 0.0021, "started_at": "…", "finished_at": "…"}
  ```
  Darstellung: eine ruhige, einklappbare Zeile („Mila arbeitet … · 3 Schritte“ bzw. „Fertig · 12 s“). Solange `uses_computer` und `running`: Live-Miniatur des Bot-Bildschirms.
- `approval`: Freigabe-Karte. `meta`: `{"approval_id": "a_1", "title": "Mail an Jonas senden", "details": "Betreff …\n\nText …", "state": "pending|approved|declined"}`. Buttons „Freigeben“ / „Ablehnen“ solange `pending`.

### Memory
```json
{"id": "mem_1", "bot_id": "b_9f2c" | null, "kind": "profil|fakt|tagebuch", "text": "Mails nie ohne Freigabe senden", "created_at": "…"}
```
`bot_id = null` heißt: gilt für alle Bots (geteilte Fakten).

### Routine
```json
{"id": "rt_1", "bot_id": "b_9f2c", "kind": "routine|erinnerung", "title": "Morgenbriefing",
 "schedule": "30 7 * * 1-5", "schedule_text": "Werktags um 7:30", "prompt": "…",
 "enabled": true, "next_run": "…", "last_run": "…" | null, "model": "claude-haiku-5-5" | null}
```
`model` (ab 1.20): eigenes Modell für die Läufe dieser Routine, `null` = Modell des Scoops.

## Endpunkte

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/health` | – | `{"ok": true, "version": "1.0.0", "user_name": "Arman"}` |
| GET | `/api/bots` | – | `[Bot]` (angepinnte zuerst, dann nach letzter Aktivität) |
| POST | `/api/bots` | `{name, label?, mascot, character?, model?}` | `Bot` (der Bot schickt danach von selbst eine erste Begrüßung) |
| GET | `/api/bots/{id}` | – | `Bot` |
| PATCH | `/api/bots/{id}` | beliebige Felder von Bot außer id | `Bot` |
| DELETE | `/api/bots/{id}` | – | `{"ok": true}` (löscht Verlauf, Gedächtnis, Routinen) |
| GET | `/api/bots/{id}/messages?before=<message_id>&limit=50` | – | `[Message]` aufsteigend nach Zeit |
| POST | `/api/bots/{id}/messages` | `{text, reply_to?}` (v1.15) | `Message` (die gespeicherte Nutzernachricht; der Lauf startet im Hintergrund) |
| POST | `/api/bots/{id}/stop` | – | `{"ok": true}` |
| POST | `/api/bots/{id}/read` | – | `{"ok": true}` (unread = 0) |
| POST | `/api/bots/{id}/reset` | – | `{"ok": true}` (Verlauf leeren, Gedächtnis bleibt) |
| GET | `/api/bots/{id}/memories` | – | `[Memory]` (Bot-eigene + geteilte) |
| DELETE | `/api/memories/{id}` | – | `{"ok": true}` |
| GET | `/api/bots/{id}/routines` | – | `[Routine]` |
| PATCH | `/api/routines/{id}` | `{enabled?, model?}` (`model` ab 1.20, nur Admin; `null` = wie Scoop) | `Routine` |
| DELETE | `/api/routines/{id}` | – | `{"ok": true}` |
| POST | `/api/routines/{id}/run` | – | `{"ok": true}` (sofort ausführen) |
| POST | `/api/approvals/{id}` | `{"decision": "approve" \| "decline" \| "approve_always", "note": "…"?}` (`approve_always` ab 1.20) | `Message` (die aktualisierte Karte) |
| GET | `/api/computer` | – | `{"state": "awake|busy|asleep", "bot_id": "b_…" \| null}` |
| GET | `/api/computer/screen.jpg` | – | JPEG des Bot-Bildschirms (ca. 1024×768, Qualität 60) |
| GET | `/api/usage` | – | `{"today_usd": 0.12, "month_usd": 3.4, "by_model": {"claude-haiku-5-5": 0.8}}` |
| POST | `/api/devices` | `{"apns_token": "…", "platform": "ios|macos", "name": "…"}` | `{"ok": true}` (für Push, sobald eingerichtet) |

Fehler: HTTP-Status ≥ 400 mit `{"error": "Text"}`, auf Deutsch oder in der Sprache der anfragenden Person (ab App 1.3, siehe [sprache.md](sprache.md)).

## WebSocket `/api/ws?token=…`

Server → App, je Nachricht ein JSON-Objekt:

| `type` | `data` |
|---|---|
| `message.created` | `Message` |
| `message.updated` | `Message` (z. B. Status-Zeilen, Freigabe-Zustand) |
| `bot.created` / `bot.updated` | `Bot` |
| `bot.deleted` | `{"id": "…"}` |
| `bot.typing` | `{"bot_id": "…", "typing": true}` |
| `computer.updated` | `{"state": "…", "bot_id": "…" \| null}` |
| `routine.updated` | `Routine` |

App → Server: `{"type": "ping"}` alle 25 s. Der Server antwortet `{"type": "pong"}`. Bei Verbindungsabbruch verbindet die App neu und lädt die offenen Listen nach.

---

# v1.1 – Gruppenchats, Bibliothek, Sprache, Live-Aktivität per Push

Alles Bisherige bleibt gültig. Neu:

## Chats allgemein

Ein **Chat** ist entweder ein einzelner Scoop (`chat_id` = Bot-ID `b_…`) oder eine **Gruppe** (`chat_id` = Gruppen-ID `g_…`). Nachrichten tragen weiter das Feld `bot_id`. Bei Gruppen steht dort die Gruppen-ID. Nachrichten von Scoops in Gruppen (`role` `bot`, `status`, `approval`) haben zusätzlich `meta.author_id` (Bot-ID des Scoops, der spricht). Nutzer-Nachrichten haben kein `author_id`.

Alle Endpunkte unter `/api/bots/{id}/…` für Nachrichten, `stop`, `read`, `reset` funktionieren auch mit einer Gruppen-ID unter `/api/groups/{id}/…` (gleiche Pfade, gleiche Bodies).

## Gruppen

```json
{"id": "g_1a2b", "name": "Team", "member_ids": ["b_…", "b_…"], "pinned": false, "section": null,
 "created_at": "…", "last_message": { Message } | null, "unread": 0, "busy": false, "busy_ids": ["b_…"]}
```
- 2 bis 6 Scoops. `busy_ids`: welche Mitglieder gerade arbeiten.
- Wer antwortet: `@Name` spricht einen Scoop gezielt an (mehrere möglich), `@alle` alle. Ohne Erwähnung entscheidet der Server, wer am besten passt (meist einer, höchstens zwei). Scoops können in der Gruppe Aufgaben an andere Mitglieder übergeben (Ereigniszeile „Mila → Lio: …“).
- Freigaben funktionieren auch in Gruppen.

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/groups` | – | `[Group]` |
| POST | `/api/groups` | `{name, member_ids}` | `Group` |
| GET/PATCH/DELETE | `/api/groups/{id}` | PATCH: `{name?, member_ids?, pinned?, section?}` | `Group` / `{"ok": true}` (löscht nur Gruppe und Gruppenverlauf, nicht die Scoops) |
| GET | `/api/groups/{id}/messages?before=&limit=` | – | `[Message]` |
| POST | `/api/groups/{id}/messages` | `{text, voice?, file_ids?, reply_to?}` | `Message` |
| POST | `/api/groups/{id}/stop` · `/read` · `/reset` | – | `{"ok": true}` |

WebSocket: `group.created`, `group.updated` (`Group`), `group.deleted` (`{"id"}`). `bot.typing` hat bei Gruppen zusätzlich `chat_id` (Gruppen-ID) und `bot_id` (wer tippt).

## Bibliothek (Dateien und Links)

```json
{"id": "f_9c1d", "chat_id": "b_…" | "g_…", "author_id": "b_…" | null, "kind": "datei|bild|link",
 "name": "Angebot.pdf", "mime": "application/pdf", "size": 48213, "url": null, "note": "", "created_at": "…",
 "download_url": "/api/files/f_9c1d"}
```
- `author_id = null`: von Arman hochgeladen. Sonst vom Scoop erstellt (z. B. Recherche als Markdown, Datei vom Bot-Rechner, gemerkter Link).
- Scoops erzeugen Dateien selbst. Dazu erscheint im Chat eine Nachricht `role: "event"` mit `meta.icon` und `meta.file_id`, die App zeigt dafür eine Dateikarte (Name, Größe, Antippen = öffnen/teilen).

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/chats/{chat_id}/files` | – | `[File]` (neueste zuerst) |
| POST | `/api/chats/{chat_id}/files?name=<Dateiname>` | Rohdaten der Datei, `Content-Type` = MIME-Typ (max. 25 MB) | `File` |
| GET | `/api/files/{id}` (`?token=` erlaubt) | – | die Datei (mit passendem `Content-Type`, `Content-Disposition: inline`) |
| DELETE | `/api/files/{id}` | – | `{"ok": true}` |

**Anhänge:** Erst Datei hochladen, dann `POST …/messages` mit `{"text": "…", "file_ids": ["f_…"]}`. Die Nutzernachricht hat dann `meta.file_ids`. Bilder und PDFs sieht der Scoop direkt, Textdateien liest er.

## Sprache

- `POST …/messages` mit `"voice": true` heißt: Die Nachricht wurde gesprochen (Diktat im Sprachmodus). Die Nutzernachricht hat `meta.voice = true`. Der Scoop antwortet dann kurz, gesprochen formuliert und ohne Markdown, damit die App die Antwort vorlesen kann.
- Bot-Feld `voice` (String oder `null`): Kennung der Stimme, die die App zum Vorlesen nimmt (z. B. eine `AVSpeechSynthesisVoice.identifier`). Setzen per `PATCH /api/bots/{id}` `{"voice": "…"}`. Der Server speichert es nur.

## Live-Aktivität per Push (iPhone)

- Push-to-Start-Token: `POST /api/devices` `{"apns_token": "<hex>", "platform": "ios-liveactivity-start"}`.
- Token einer laufenden Aktivität: `POST /api/live-activities` `{"chat_id": "b_…", "run_id": "r_…", "push_token": "<hex>"}`.
- Der Server startet beim Beginn eines Laufs per Push eine Aktivität (falls ein Push-to-Start-Token da ist und für den Lauf noch keine Aktivität gemeldet wurde), aktualisiert sie bei jedem Arbeitsschritt und beendet sie am Ende (`dismissal-date` + 2 Minuten).
- Topic `com.ais.aisbot.push-type.liveactivity`, `attributes-type` = `BotRunAttributes`. `attributes` und `content-state` exakt wie das Swift-Struct (camelCase-Schlüssel: `botID`, `botName`, `botLabel`, `mascot{shape,color,eyes,accessory}`, `runID`; `state`, `statusLine`, `steps`, `startedAt`, `finishedAt`). Datumswerte als Sekunden seit 1.1.2001 (Standard von `JSONDecoder`/ActivityKit).

## Bot-Rechner übernehmen (v1.1)

- `GET /api/computer` liefert zusätzlich `width`/`height` (Bildschirm in Punkten, z. B. 1024×768). `state` kann jetzt auch `"user"` sein (Arman steuert).
- `POST /api/computer/takeover` → Arman übernimmt. Antwort wie `GET /api/computer`. `409` mit Fehlertext, wenn ein Scoop den Rechner länger als 15 s belegt. Scoops, die den Rechner brauchen, warten, bis Arman zurückgibt. Nach 10 Minuten ohne Eingabe gibt der Server automatisch zurück.
- `POST /api/computer/input` (nur während der Übernahme), Koordinaten in Bildschirmpunkten (gleiches Koordinatensystem wie `screen.jpg`):
  - `{"type": "click"|"double_click"|"right_click", "x", "y", "modifiers"?}` (`modifiers` z. B. `"super"`, `"shift"`, `"super+shift"`)
  - `{"type": "move", "x", "y"}` · `{"type": "drag", "x", "y", "x2", "y2"}`
  - `{"type": "scroll", "x", "y", "direction": "up|down|left|right", "amount": 3}`
  - `{"type": "type", "text": "…"}` (Unicode, auch Umlaute) · `{"type": "key", "text": "return"|"super+c"|…, "repeat"?}`
- `POST /api/computer/release` → zurückgeben.
- Während der Übernahme liefert `screen.jpg` höchstens alle 0,3 s ein neues Bild.
- WebSocket `computer.updated` enthält jetzt auch `width`/`height` und `state: "user"`.

## v1.2 – Diktat und Bildschirm sparsam

- `POST /api/transcribe?name=diktat.m4a&language=de[&prompt=…]` mit den Audiodaten als Body (`Content-Type` z. B. `audio/mp4` für AAC-m4a, `audio/wav`; max. 25 MB) → `{"text": "…", "model": "gpt-transcribe"}`. Nutzt OpenAI GPT-Transcribe (ca. 0,45 Cent pro Minute). `prompt` kann Namen und Fachbegriffe als Schreibhilfe enthalten (z. B. Scoop-Namen). Fehler: 503 ohne OpenAI-Schlüssel, 502 bei Fehlern von OpenAI.
- `GET /api/computer/screen.jpg?scale=0.5&q=50`: `scale` 0,25–1 (Standard 1), `q` JPEG-Qualität 20–90 (Standard 60). Volle Größe ≈ 80–100 KB, `scale=0.6&q=50` ≈ 35 KB, `scale=0.5&q=50` ≈ 25 KB.

## v1.3 – Telefonie (Lucy, GPT-Live-1)

- Scoops haben die Werkzeuge `anrufen` und `anrufe_lesen`. Lucy (Projekt `Documents/Telefonie`, Twilio + OpenAI `gpt-live-1`) führt die Gespräche.
- `anrufen` erzeugt eine Freigabe-Nachricht mit `meta.kind = "call"`. Erst `POST /api/approvals/{id}` mit `approve` lässt den **Server** wählen, nicht das Modell. Die Zielnummer wird nur für genau diesen Prozess freigegeben, es gibt keine Wiederwahl. Ist Lucy nicht betriebsbereit, wird nicht gewählt.
- Ereigniszeilen: „Lucy ruft an: …“ (`phone.connection`), „Anruf beendet: …“ (`phone.down`). Danach berichtet der Scoop das Ergebnis aus Lucys Protokoll.

## v1.4 – Haupt-Scoop mit Initiative, Fähigkeiten, Tresor

### Haupt-Scoop und Initiative
- Bot-Feld `primary` (bool). Höchstens ein Scoop ist Haupt-Scoop. Setzen per `PATCH /api/bots/{id}` `{"primary": true}` (der bisherige verliert es, beide bekommen `bot.updated`). Entfernen per `{"primary": false}`.
- Der Haupt-Scoop prüft zu festen Zeiten von selbst (To-dos, Mails, Freigaben, Termine) und schreibt **nur**, wenn es etwas Relevantes gibt. Diese stillen Läufe erzeugen keine Statuszeile und kein Tippen. Kommt eine Nachricht, ist es eine normale `bot`-Nachricht mit Push.
- `GET /api/settings/initiative` → `{"enabled": true, "times": ["07:30","12:30","17:30"], "quiet_start": "22:00", "quiet_end": "07:00", "primary_bot_id": "b_…" | null}`
- `PATCH /api/settings/initiative` mit beliebigen Feldern davon (`times`: bis 8 Zeiten „HH:MM“). Antwort wie GET.
- `POST /api/initiative/run` → sofort einen Check auslösen (zum Ausprobieren).

### Fähigkeiten (Skills)
```json
{"id": "sk_…", "bot_id": "b_…" | null, "name": "Anmeldung mit Tresor-Eintrag", "description": "…", "steps": "1. …\n2. …",
 "uses": 3, "last_used": "…" | null, "created_at": "…", "updated_at": "…"}
```
- `bot_id = null`: gilt für alle Scoops. Scoops legen Fähigkeiten selbst an (Ereignis „Fähigkeit gespeichert: …“, Icon `wand.and.stars`) und lesen sie vor passenden Aufgaben.
- `GET /api/skills` (alle) · `GET /api/bots/{id}/skills` (eigene + geteilte) · `PATCH /api/skills/{id}` `{name?, description?, steps?}` · `DELETE /api/skills/{id}`
- WebSocket: `skill.updated` (Skill), `skill.deleted` (`{"id"}`).

### Tresor (Logins)
```json
{"id": "v_…", "title": "Übungsseite", "url": "https://…/login", "domain": "the-internet.herokuapp.com", "username": "tomsmith",
 "note": "", "has_password": true, "last_used": "…" | null, "created_at": "…", "updated_at": "…"}
```
- Passwörter liegen nur im Schlüsselbund des Air. Die API gibt sie **nie** zurück, nur `has_password`.
- `GET /api/vault` · `POST /api/vault` `{title, url, username?, password?, note?}` · `PATCH /api/vault/{id}` (gleiche Felder; `password` nur senden, wenn es geändert werden soll) · `DELETE /api/vault/{id}`
- Scoops sehen Titel, Domain und Benutzername und können mit dem Werkzeug `login_ausfuellen` Benutzername und Passwort direkt in den Bot-Rechner tippen lassen, nur wenn vorne Safari, Chrome oder Dia mit einer Seite der Domain offen ist. In Claude-Aufgaben füllt der Bildschirm-Helfer (`bildschirm_aufgabe`) aus, weil nur er den Rechner belegt.

## v1.5 – T3 Code und Tempo

- Scoops können Programmieraufgaben an T3 Code abgeben (`t3_auftrag`, `t3_nachricht`, `t3_threads`, `t3_thread_lesen`, `t3_projekte`). Starten und Nachrichten an T3 brauchen eine Freigabe: Approval mit `meta.kind = "t3"`.
- Ereigniszeilen mit Icon `hammer`: „T3 arbeitet: …“, „T3 fertig: …“, „T3 braucht Antwort: …“. Sie haben `meta.url` (Link in die T3-App, `https://app.t3.codes/threads/…`) und `meta.t3_thread_id`.
- Allgemein: Ereigniszeilen mit `meta.url` sollen antippbar sein und den Link öffnen.
- Server-Tempo: Composio und die Team App laufen jetzt über eine eigene, dauerhafte MCP-Verbindung des Servers statt über den MCP-Connector der Claude API (spart ca. 5 s pro Antwort). Läufe starten mit Denkaufwand `low` und schalten ab dem ersten Werkzeugaufruf auf `medium`.

## v1.6 – Bereiche in der Seitenleiste

- Bereiche (z. B. „Arbeit“, „Privat“) sind eine geordnete Liste auf dem Server, damit sie auf allen Geräten gleich sind, auch wenn ein Bereich leer ist. Scoops und Gruppen ordnet man über ihr Feld `section` zu (PATCH `/api/bots/{id}` bzw. `/api/groups/{id}` mit `{"section": "Arbeit"}` oder `null` für „Ohne Bereich“).
- `GET /api/sections` → `{"sections": [{"name": "Arbeit", "collapsed": false}, …]}` (gespeicherte Reihenfolge, dazu Bereiche, die nur an Scoops hängen)
- `PUT /api/sections` `{"sections": [{"name", "collapsed"}, …]}` → speichert Reihenfolge, neue leere Bereiche und den Einklapp-Zustand
- `POST /api/sections/rename` `{"from": "Arbeit", "to": "Job"}` → benennt um, inklusive aller zugeordneten Scoops und Gruppen
- `DELETE /api/sections/{name}` → löscht den Bereich, seine Scoops und Gruppen landen in „Ohne Bereich“
- WebSocket: `sections.updated` mit `{"sections": […]}`

## v1.7 – OpenAI-Modelle

- Bot-Feld `model` erlaubt zusätzlich: `gpt-6-luna` (schnell & sehr günstig), `gpt-6.1-sol` (Allrounder), `gpt-6.1-terra` (Mittelklasse), `gpt-6-astra` (am stärksten, teuer). Setzen per `PATCH /api/bots/{id}` `{"model": "gpt-6.1-sol"}` oder beim Erstellen.
- OpenAI-Scoops haben dieselben Fähigkeiten. Den Bildschirm des Bot-Rechners bedienen sie seit Server 1.10 selbst mit OpenAIs eingebautem Werkzeug `computer` (Notfall-Schalter `openai_native_computer: false` in config.json → alter Weg über eine Claude-Teilaufgabe). Eskalation innerhalb von OpenAI nach Stärke: Luna → Terra → Sol → Astra.
- Kosten erscheinen in `/api/usage` unter den OpenAI-Modellnamen.

## v1.8 – Apps verbinden

Server-Version 1.8.0. Konten bei Composio (OAuth läuft auf connect.composio.dev), bis zu `max_per_app` (10) Konten pro App. Fehler kommen als `{"error": "…"}` (409 = Regelverstoß wie Limit/doppelter Name, 502 = Composio nicht erreichbar).

- `GET /api/connections[?fresh=true]` →
  ```json
  {"max_per_app": 10,
   "apps": [{"slug": "gmail", "name": "Gmail", "detail": "Mails lesen, …", "symbol": "envelope.fill",
             "logo_url": "https://logos.composio.dev/api/gmail",   // SVG, optional
             "can_add": true,
             "accounts": [{"id": "ca_…", "app": "gmail", "alias": "privat", "email": "lena@example.com",
                           "status": "active|expired|failed|initiated", "created_at": "…"}]}],
   "builtin": [{"id": "teamapp|atrium|atrium_berlin|atrium_koeln|t3|lucy", "name": "Team App", "detail": "…",
                "symbol": "person.3.fill", "status": "ok|error|off", "tools": 121}]}
  ```
  `apps` ist sortiert (Vorschläge zuerst); Apps ohne Konto haben `accounts: []`. `builtin` sind fest eingerichtete Verbindungen (nur Anzeige).
- `POST /api/connections/{slug}/link` `{"alias": "arbeit"}` (Name optional, eindeutig pro App) → `{"url": "https://connect.composio.dev/link/lk_…", "account_id": "ca_…"}`. Die App öffnet `url` (ASWebAuthenticationSession bzw. Safari-Sheet; es gibt keinen Rücksprung-Link) und fragt währenddessen alle 3 s `GET /api/connections/accounts/{account_id}` ab, bis `status == "active"` (dann Sheet schließen, Liste neu laden) oder `failed`.
- `GET /api/connections/accounts/{id}` → Konto (`status` wie oben, `initializing` = Anmeldung läuft).
- `PATCH /api/connections/accounts/{id}` `{"alias": "…"}` → Konto umbenennen (Scoops wählen Konten über diesen Namen).
- `POST /api/connections/accounts/{id}/reconnect` → wie `link`, für abgelaufene Konten; das alte Konto verschwindet nach erfolgreicher Anmeldung von selbst.
- `DELETE /api/connections/accounts/{id}` → Konto trennen (vorher in der App bestätigen lassen).

## v1.9 – Mail-Karte und Reaktionen

Server-Version 1.9.0.

**Mail-Karte.** Scoops versenden Mails nur noch über das Werkzeug `mail_vorbereiten` (direktes Senden über Composio ist gesperrt). Es entsteht eine Nachricht `role: "approval"` mit `meta.kind == "mail"` und
```json
"mail": {"app": "gmail", "account": "arbeit", "account_email": "lena@example.org",
         "to": ["a@b.de"], "cc": [], "subject": "…", "body": "…", "thread_id": null,
         "status": "draft|sending|sent|failed|discarded", "error": null, "sent_at": null}
```
(`thread_id` gesetzt = Antwort in einem bestehenden Verlauf; der Betreff ist dann nur Anzeige). `meta.state` bleibt wie bei Freigaben (`pending|approved|declined`), `meta.details` ist eine Textfassung für ältere App-Versionen.
- Senden: `POST /api/approvals/{approval_id}` `{"decision": "approve", "edits": {"account": "privat", "to": ["…"], "cc": ["…"], "subject": "…", "body": "…"}}`. `edits` ist optional, nur geänderte Felder nötig; `account` = Name (`alias`) eines aktiven Gmail-Kontos aus `GET /api/connections`. Danach `mail.status` = `sending`, per `message.updated` dann `sent` oder `failed` (+ `error`); zusätzlich eine Ereignis-Nachricht („Mail gesendet an …“).
- Abbrechen: `{"decision": "decline"}` → `mail.status = "discarded"`, Ereignis „Mail verworfen: …“.

**Reaktionen.** `meta.reactions` jeder Nachricht ist ein Objekt `{akteur: emoji}`, Akteur `"user"` (Arman) oder eine Scoop-ID (`b_…`). Eine Reaktion pro Akteur und Nachricht.
- `PUT /api/messages/{message_id}/reaction` `{"emoji": "👍"}` setzt/ersetzt Armans Reaktion, `{"emoji": null}` entfernt sie → aktualisierte Nachricht, außerdem `message.updated` per WebSocket.
- Scoops reagieren selbst mit dem Werkzeug `reagieren` (auf Armans letzte Nachricht); antworten sie danach nicht, entsteht keine Textnachricht.

**Scoops schreiben Scoops (v1.9).** In Einzelchats kann ein Scoop einem anderen mit dem Werkzeug `scoop_schreiben` schreiben.
- Beim Empfänger erscheint eine Nachricht `role: "bot"` mit `meta.peer == true`, `meta.author_id` = Absender-Scoop, `meta.silent == true` (keine Mitteilung). Die Antwort des Empfängers landet in seinem Chat als normale Bot-Nachricht mit `silent`, und zusätzlich im Chat des Absenders als `role: "bot"` mit `peer: true` und `author_id` = antwortender Scoop.
- Beim Absender steht außerdem eine Ereigniszeile `role: "event"` mit `meta.peer_out == true`, `author_id`, `target_id`, Text „An Tina: …“.
- Darstellung in der App: Nachrichten mit `meta.peer == true` (oder in Einzelchats mit `author_id` ≠ Chat-Scoop) bekommen einen farbigen Rahmen in der Maskottchenfarbe des Autors, darüber Mini-Maskottchen und Name des Autors. `meta.silent` heißt nur: keine Push-Mitteilung.

## v1.10 – Tresor-Formular

Server-Version 1.10.0. Scoops legen Logins mit dem Werkzeug `tresor_eintrag_anlegen` an. Im Chat erscheint `role: "approval"` mit `meta.kind == "vault"` und
```json
"vault": {"title": "MLP Team App", "url": "https://…", "domain": "…", "username": "",
          "status": "pending|saved|declined", "vault_id": null}
```
- Speichern: `POST /api/approvals/{approval_id}` `{"decision": "approve", "edits": {"username": "…", "password": "…", "title": "…", "url": "…"}}`. `password` ist Pflicht (sonst 400 mit `{"error": …}`); `title`/`url` optional. Das Passwort landet nur im Schlüsselbund des Servers. Gibt es für die Domain schon einen Eintrag, wird er aktualisiert. Danach `vault.status = "saved"`, `vault.vault_id`, Ereignis „Login gespeichert: …“; der Scoop macht automatisch weiter.
- Ablehnen: `{"decision": "decline"}` → `vault.status = "declined"`.
- Darstellung in der App: Karte mit Schlüssel-Symbol, Titel, Webseite (Domain), Feld Benutzer (vorbelegt), Passwortfeld (SecureField, mit Einblenden-Auge, Passwort-Autofill erlaubt: `.textContentType(.password)` bzw. `.username`), Hinweis „Kein Scoop sieht das Passwort.“, Knöpfe „Abbrechen“ und „Im Tresor speichern“. Optional Face ID vor dem Speichern wie beim Tresor. Zustände saved (grüner Haken „Im Tresor gespeichert“) und declined kompakt.

## v1.11 – Rechner (Scoops Connect)

Server-Version 1.11.0. Konzept: `docs/scoops-connect.md`. Neben dem eingebauten Bot-Rechner (`id: "vm"`, VM auf dem Air, per HTTP) können weitere Macs über die App **Scoops Connect** angeschlossen werden. Jeder Scoop arbeitet an genau einem Rechner.

**Rechner-Objekt** (`GET /api/nodes` → Liste, `vm` immer zuerst):
```json
{"id": "n_3fa9c01d2e", "name": "Mac mini Büro", "mode": "direct|vm", "builtin": false,
 "online": true, "paused": false, "os": "macOS 27.0", "app_version": "1.0 (1)", "last_seen": "2026-11-13T10:12:00+01:00",
 "screen": {"width": 1512, "height": 982}, "state": "awake|busy|user|asleep", "bot_id": "b_…" | null,
 "bot_name": "Mila" | null, "created_at": "…"}
```
`vm`: `builtin: true`, `mode: "vm"`, `online` = Computer-Server erreichbar, nicht löschbar. `state` wie bei `GET /api/computer` (offline oder pausiert → `asleep`); `bot_id`/`bot_name` = Scoop, der gerade daran arbeitet.

**Endpunkte** (alle mit Auth, außer `claim` und `link`):
- `GET /api/nodes` → Liste wie oben.
- `PATCH /api/nodes/{id}` `{"name": "…"}` → umbenennen (auch `vm`), Antwort = Rechner-Objekt.
- `DELETE /api/nodes/{id}` → entfernen (nicht `vm` → 400). Ein verbundener Rechner bekommt `bye` und wird getrennt; Scoops mit diesem Rechner fallen auf `vm` zurück (`bot.updated`).
- `POST /api/nodes/pair` → `{"code": "K7QX-29PL", "expires_at": "<iso>", "ttl_seconds": 600, "server_url": "https://…"}`. Code: 8 Zeichen, 10 Minuten gültig, einmalig. Die App zeigt Code, Countdown und die Anleitung „Scoops Connect auf dem Mac öffnen → Code eingeben“.
- `POST /api/nodes/claim` (ohne Auth, für Scoops Connect) `{"code", "name", "mode": "direct|vm", "os", "app_version"}` → `{"node_id", "node_token", "server_url"}`. Groß-/Kleinschreibung, Bindestrich und Leerzeichen im Code sind egal. Ungültig/abgelaufen/benutzt → 404; mehr als 10 Fehlversuche pro Minute → 429.
- `GET /api/nodes/link` – WebSocket für Scoops Connect, `Authorization: Bearer <node_token>` (oder `?token=`). Protokoll siehe `docs/scoops-connect.md`. Zusätzlich zum dort Beschriebenen schickt der Server (Rechner sollen unbekannte Typen ignorieren):
  - `{"type": "welcome", "node_id", "name"}` als Antwort auf `hello`,
  - `{"type": "activity", "state": "awake|busy|user|asleep", "bot_id", "bot_name"}` bei jeder Belegungsänderung („Mila arbeitet gerade“),
  - `{"type": "renamed", "name"}` nach Umbenennen in der App.
  Unbekanntes Token → `bye` + Close-Code 4401. `state` vom Rechner darf neben `paused` auch `screen` enthalten.
- **Geräte-ID (rückwärtskompatibel):** `claim` und `hello` dürfen `"device_id"` enthalten (Scoops Connect/AIS Scoops Server:
  `mac-` + SHA-256 der Hardware-UUID, gekürzt). Koppelt sich ein Mac mit bekannter Geräte-ID neu, behält der Server den
  bisherigen Eintrag (gleiche `node_id`, Scoops bleiben zugeordnet), ersetzt nur das Token und trennt die alte Verbindung;
  weitere Einträge derselben Geräte-ID werden zusammengeführt (`node.deleted`, `bot.updated`). Antwort von `claim`
  zusätzlich `"replaced": [<node_id>…]`, `"reused": true|false`. `hello` trägt eine fehlende Geräte-ID nach.
- `computer_node` in Scoop-Antworten ist der **tatsächliche** Rechner: ohne VM-Funktion (Edition „standard“) der
  Standard-Rechner statt `vm`; zeigt ein Scoop auf einen entfernten Rechner, der Standard-/Ersatz-Rechner. Beim Start räumt
  der Server Verweise von Scoops und `default_computer_node` auf nicht mehr vorhandene Rechner auf.

**Bestehende Rechner-Endpunkte** nehmen optional `?node=<id>` (Standard `vm`; unbekannt → 404): `GET /api/computer`, `GET /api/computer/screen.jpg`, `POST /api/computer/takeover`, `/release`, `/input`. Ist der Rechner offline oder pausiert, liefern `screen.jpg` und `input` sofort `503` mit `{"error": "… offline …"}` bzw. `"Rechner ist pausiert …"`.
- `GET /api/computer` enthält zusätzlich `node_id`, bei Scoops-Connect-Rechnern auch `online` und `paused`.

**Scoop-Feld** `computer_node` im Bot-Objekt: Rechner-ID, Standard `"vm"`. Ändern über `PATCH /api/bots/{id}` `{"computer_node": "n_…"}` (`"vm"` oder `null` = Bot-Rechner; unbekannte ID → 400). Läufe des Scoops (Claude und OpenAI) arbeiten an diesem Rechner; ist er offline oder pausiert, steht das in der Systemanweisung und Bildschirm-/Terminal-Werkzeuge melden sofort einen klaren Fehler.

**WebSocket `/api/ws`** (App):
- `computer.updated` enthält zusätzlich `node_id` (bei Scoops-Connect-Rechnern auch `online`, `paused`). Die App filtert nach dem Rechner, den sie gerade zeigt; Ereignisse ohne `node_id` (ältere Server) gelten für `vm`.
- `node.updated` → Rechner-Objekt (gekoppelt, verbunden, getrennt, pausiert, umbenannt).
- `node.deleted` → `{"id": "n_…"}`.

## v1.12 – Benutzerkonten (Anmeldung mit Apple)

Server-Version 1.12.0. Konzept und Convex-Schnittstelle: `docs/accounts.md` (Abschnitt „Ist-Stand Phase 1“).

**Anmeldung am Server:** Jeder Endpunkt mit Auth (REST und `/api/ws`) akzeptiert als `Authorization: Bearer …` bzw. `?token=…`
- weiterhin das bisherige **API-Token** (`api_token`, Kopplung per QR/Link) – unverändert, oder
- ein **Sitzungs-JWT** von AIS Scoops Cloud (Convex), wenn der Server mit dem Konto gekoppelt ist: RS256-Signatur gegen
  `<cloud_url>/.well-known/jwks.json` (1 h zwischengespeichert, bei unbekannter `kid` neu geladen), `iss` = `cloud_url`,
  `aud` = `"ais-scoops"`, `exp`/`nbf` (60 s Toleranz), `sub` = `owner_id` des Servers, `sid` nicht abgemeldet
  (Liste kommt mit jedem Herzschlag). Ohne Kopplung wird kein JWT akzeptiert. Ungültig → 401 `{"error": "Nicht angemeldet"}`,
  WebSocket → Ablehnung (Close 4401 bzw. HTTP 403 vor dem Handshake), wie bisher.

Die App holt nach einem 401 mit JWT einmal ein frisches Token (`/auth/refresh`) und versucht es erneut.

**Einrichtung (nur lokal):** Beide Endpunkte antworten nur auf direkte Aufrufe von `127.0.0.1`/`::1` ohne Proxy-Header
(`X-Forwarded-For`, `Forwarded`, `Tailscale-User-Login` …); über Tailscale Serve/öffentliche URL → `403`.
- `GET /api/setup` →
  ```json
  {"version": "1.12.0", "cloud_url": "https://helpful-puma-445.eu-west-1.convex.site", "linked": false,
   "owner_id": null, "server_id": null,
   "pending": {"code": "K7QX-29PL", "expires_at": "2026-11-13T15:10:00+0100", "ttl_seconds": 594} | null,
   "last_heartbeat_at": "2026-11-13T15:01:00+0100" | null, "last_error": null}
  ```
- `POST /api/setup/link` `{"force": false}` → fordert bei Convex einen Kopplungscode an (Antwort wie `GET /api/setup`
  mit `pending`). Der Server pollt im Hintergrund alle 3 s, bis der Code in der App eingelöst wurde, legt dann das
  `serverSecret` im Schlüsselbund ab (`ais-bot-cloud`/`server-secret`) und schreibt `owner_id`/`cloud_server_id` in
  `config.json`. Schon gekoppelt und `force` nicht gesetzt → `409`; Convex nicht erreichbar → `502`.
- Kommandozeile: `bin/aisbot cloud-link` (zeigt den Code und wartet auf die Bestätigung), `--status`, `--force` (neu koppeln).
  Läuft der Server nicht, koppelt die Kommandozeile selbst.
- **Ergänzung für die Mac-App „AIS Scoops Server“ (ohne neue Versionsnummer, rückwärtskompatibel):**
  `GET /api/setup` enthält zusätzlich `"server": {"edition", "port", "home", "user_name", "owner_name", "server_name",
  "public_url", "tailnet_url", "host", "host_configured", "default_model", "default_computer_node",
  "keys": {"anthropic", "openai", "composio"} (nur ob vorhanden), "composio_ready", "bots", "active_runs",
  "nodes": [{"id", "name", "online"}], "own_scoops": {"count", "newest"}}`. `own_scoops` zählt die selbst angelegten
  Scoops ohne den Start-Scoop Pip (`newest` = Name des neuesten); der Assistent gratuliert damit zum ersten Scoop.
  `PATCH /api/setup/config` mit beliebigen dieser Felder: `user_name`, `public_url`, `tailnet_url` (http/https), `server_name`,
  `default_computer_node` (ordnet ohne VM-Funktion auch alle Scoops ohne Rechner zu), `host` (`127.0.0.1`/`0.0.0.0`, wirkt nach
  Neustart), `provider` (`anthropic`/`openai`: Standardmodelle und bestehende Scoops umstellen); leerer Text entfernt den Wert.
  Ab App 1.3 auch `language` (`de`/`en`/`null`, Sprache des Inhabers, `GET /api/setup` → `server.language`,
  `server.languages`); alle Einrichtungstexte kommen nach `?lang=` bzw. `Accept-Language` ([sprache.md](sprache.md)).
  Antwort wie `GET /api/setup`. `POST /api/setup/node-pair` → Rechner-Kopplungscode wie `POST /api/nodes/pair` (ohne Token).
  `POST /api/setup/reload` → legt bei Bedarf die Composio-Sitzung an und lädt die Apps (MCP) neu.
  `POST /api/setup/this-mac` `{"node_id", "device_id", "replaces": [], "make_default": false}` → „Dieser Mac“ ist Rechner
  `node_id`: Geräte-ID speichern, frühere Einträge desselben Macs zusammenführen (gleiche Geräte-ID, `replaces`, sowie alte
  Einträge ohne Geräte-ID mit gleichem Namen, die offline sind; Scoops werden umgehängt) und ohne VM-Funktion als
  Standard-Rechner setzen, falls keiner gültig gesetzt ist (oder `make_default`). Antwort wie `GET /api/setup` plus `"merged"`.
  Zusätzlich: `lan_url` (Heim-WLAN-Adresse) in `PATCH /api/setup/config` und `GET /api/setup` (`server.lan_url`,
  `server.effective_computer_node`). Ändern sich `public_url`/`tailnet_url`, meldet der Server sie sofort per Herzschlag an
  Convex (inkl. `tailnetUrl`). Beim Start zieht er eine LAN-Adresse (`http://….local:<port>`, private IP) auf den
  tatsächlichen Port; https-/Tailscale-Adressen bleiben unverändert.
  Convex liefert bei `claim/poll` (claimed) und `heartbeat` zusätzlich `ownerName`; der Server speichert ihn als `owner_name`.

**Herzschlag:** Ist der Server gekoppelt, meldet der Planer alle 60 s `public_url` und Version an Convex
(`POST /servers/heartbeat`). Antwortet Convex mit `401 unknown_server` (Server in der App entfernt oder Konto gelöscht),
hebt der Server die Kopplung auf (`owner_id`/Secret weg); das API-Token gilt weiter.

**config.json** (neu, optional): `cloud_url` (Standard: Produktion), `owner_id`, `cloud_server_id`, `server_name`
(Anzeigename beim Koppeln, Standard: Computername).

Tests: `cd Server && uv run python tests/test_cloud.py` (Teil 2 gegen Convex-Dev; `AISBOT_SKIP_CONVEX=1` überspringt ihn).

**App (Build mit Konten):** Bei einem Server aus „Deine Server“ schickt die App das Sitzungs-JWT genau dort, wo bisher das
API-Token stand: `Authorization: Bearer <JWT>` für REST, beim WebSocket `/api/ws` als Header **und** `?token=<JWT>`,
außerdem `?token=` bei Datei- und Bildschirm-URLs (`/api/files/{id}`, `/api/computer/screen.jpg`). Vor Anfragen und vor jedem
WebSocket-Aufbau erneuert sie ein JWT, das in weniger als 7 Tagen abläuft; nach einem 401 genau einmal sofort. Server ohne
Kopplung lassen sich weiter per Token verbinden („Erweitert → Manuell verbinden“, `aisbot://pair?…`). Details: `App/README.md`.

## v1.12 – Eigenes Scoop-Bild

Statt des gezeichneten Maskottchens kann ein Scoop ein eigenes Bild (Foto oder Grafik) haben. Der Server schneidet es mittig quadratisch zu, verkleinert auf höchstens 512 px und legt es unter `<daten>/avatars/<bot-id>.jpg|png` ab (Transparenz → PNG, sonst JPEG). Handyfotos werden anhand der EXIF-Ausrichtung gedreht.

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| PUT | `/api/bots/{id}/avatar` | rohe Bilddaten (`Content-Type` z. B. `image/jpeg`, `image/png`, `image/heic`; max. 15 MB) | `Bot` mit neuem `avatar` (400 bei unlesbaren Daten, 413 zu groß) |
| DELETE | `/api/bots/{id}/avatar` | – | `Bot` mit `avatar: null` (zurück zum Maskottchen) |
| GET | `/api/bots/{id}/avatar?v=<version>&size=<64…512>` | – | Bild (`image/jpeg` bzw. `image/png`); 404 ohne Bild |

- Auth wie überall (Header oder `?token=`).
- Cache: Mit passender `?v=` antwortet der Server `Cache-Control: private, max-age=31536000, immutable`, sonst `no-cache`. `ETag` pro Version und Größe, `If-None-Match` → 304. `X-Avatar-Version` nennt die aktuelle Version.
- `?size=` liefert eine verkleinerte Fassung (z. B. 128 für Widgets), ohne die gespeicherte Datei zu ändern.
- Nach PUT/DELETE: WebSocket `bot.updated` und Widget-Neuladen per Push.
- Pushes und Live-Aktivitäten enthalten **keine Bilddaten**, nur `mascot.photo = {id, version}` (wenige Bytes). App, Widgets, Live-Aktivität und Mitteilungen lesen das Bild aus dem App-Group-Cache (`ScoopPhotos/<id>-<version>.img`); die App lädt eine neue Version einmal nach.
- Scoop löschen entfernt auch das Bild.

## v1.13 – Mitteilungen für alle Server (Push-Relay) und App-Badge

Server-Version 1.13.0. Details zu Convex und den Schutzmaßnahmen: `docs/accounts.md`, Abschnitt „Push-Relay“.

- **Transport:** Mit eigenem APNs-Schlüssel (`apns_key_id` + Schlüsselbund `ais-bot-apns`/`p8`) schickt der Server
  wie bisher direkt an APNs. Ohne Schlüssel, aber mit Konto gekoppelt, gehen alle Pushes (Mitteilungen, Badge, Widgets,
  Live-Aktivität inkl. Push-to-Start und Broadcast-Kanäle) über AIS Scoops Cloud (`<cloud_url>/push/*`). Für die App
  ändert sich nichts: Tokens wie bisher über `POST /api/devices` und `POST /api/live-activities` melden.
- `GET /api/health` → zusätzlich `"push_mode": "direct" | "relay" | null`; `push_enabled` = einer der Wege verfügbar.
- `POST /api/devices` → `push_enabled` ist jetzt auch auf Servern ohne eigenen Schlüssel `true`, sobald sie gekoppelt sind.
- `GET /api/setup` (nur lokal) → zusätzlich `"push": {"enabled": true, "mode": "relay", "error": null}`
  (`error` z. B. „Push-Relay ist in der Cloud nicht eingerichtet“).
- **App-Badge** = Anzahl Chats (Scoops + Gruppen) mit `unread > 0`, nicht die Summe der Nachrichten.
  - Jede Mitteilung enthält `aps.badge` (Stand nach dem Hochzählen von `unread`).
  - Wird ein Chat gelesen (`POST /api/bots/{id}/read`, `POST /api/groups/{id}/read`, eigene Nachricht im Chat) oder
    gelöscht, kommt nach 2 s (entprellt) ein stiller Push `{"aps": {"badge": N}}` mit `apns-push-type: alert`,
    Priorität 5 an alle App-Geräte (`platform` `ios`/`macos`), nur wenn sich N seit dem letzten Push geändert hat.
  - Die App sollte die Zahl beim Öffnen zusätzlich selbst setzen (Summe der Chats mit `unread > 0` aus `/api/bots` und `/api/groups`).

## v1.13 – Live-Sprechmodus (GPT-Live-1)

Der Sprechmodus spricht standardmäßig **live** über OpenAI `gpt-live-1` (Sprache zu Sprache, Stimme z. B. `marin`). Der OpenAI-Schlüssel bleibt auf dem Server (Schlüsselbund `<präfix>-openai`, Konto `api-key`), die App spricht nur mit dem Server. Ohne Schlüssel oder bei einem Fehler nimmt die App automatisch die Gerätestimme (bisheriger Ablauf mit `/api/transcribe` und `voice: true`). Umsetzung: `Server/src/aisbot/live_voice.py`.

**Stimme pro Scoop** (Feld `voice` von `PATCH /api/bots/{id}`):

| Wert | Bedeutung |
|---|---|
| `live:<name>` bzw. `live:<name>\|<Geräte-ID>` | Live-Stimme (z. B. `live:marin`), optional mit eigener Rückfall-Gerätestimme |
| `device` bzw. `device:<Geräte-ID>` | Gerätestimme (offline), kein Live |
| leer oder alte Geräte-ID (vor v1.13) | Live mit der Standardstimme des Servers, Geräte-ID als Rückfall |

**`GET /api/voice/live`** → `{available, reason, model: "gpt-live-1", default_voice, voices: [{id, name, note}], max_seconds, idle_seconds, price_per_minute_usd}`. `available` ist false ohne OpenAI-Schlüssel oder mit `live_voice.enabled: false`. Ältere Server antworten 404 → App nimmt die Gerätestimme.

**`POST /api/voice/live/preview`** `{voice}` → `audio/wav` (24 kHz, mono), ein kurzer Probesatz in der Live-Stimme. Wird pro Stimme einmal erzeugt (kurze Live-Sitzung, < 1 Cent) und unter `data/voice-previews/` zwischengespeichert. 400 bei unbekannter Stimme, 503 ohne Schlüssel.

**WebSocket `/api/voice/live?chat=<bot-id>`** (Anmeldung wie `/api/ws`: `Authorization: Bearer <Token oder Sitzungs-JWT>`, notfalls `?token=`). Nur Einzelchats.

- Binär, beide Richtungen: PCM16 little-endian, mono, **24 kHz**. App → Server: Mikrofon in Paketen (App: 40 ms, höchstens 1 s pro Paket), ab `ready` durchgehend, auch Stille. Server → App: Stimme des Scoops. Live liefert einen **durchgehenden** Strom (auch Stille, etwa in Echtzeit), also einfach der Reihe nach abspielen.
- App → Server (JSON): `{"type":"stop"}` · `{"type":"mute","muted":true|false}` (→ `session.input_audio.mute/unmute`) · `{"type":"interrupt"}` (Antippen: App leert die Wiedergabe, Live hört auf zu sprechen) · `{"type":"ping"}` → `pong`.
- Server → App (JSON):
  - `ready` `{voice, model, rate: 24000, max_seconds, idle_seconds, price_per_minute_usd}`: erst jetzt Mikrofon senden
  - `transcript` `{role: "user"|"assistant", text}`: Untertitel-Delta
  - `turn` `{role, text, message_id}`: Beitrag abgeschlossen und als Chat-Nachricht gespeichert
  - `interrupt`: Nutzer redet dazwischen → noch gepuffertes Antwort-Audio verwerfen (Barge-in)
  - `task` `{state: "running"|"done", text}`: der Scoop erledigt gerade eine Aufgabe im normalen Lauf
  - `usage` `{seconds, cost_usd}`: jede Sekunde
  - `end` `{reason: stopped|idle|limit|expired|closed|error, message}` · `error` `{message, fallback: true}`: Live nicht möglich → Gerätestimme

**Verlauf:** Gesprochenes landet als normale Nachrichten im Chat: Nutzer `role=user`, `meta {voice: true, live: true}`; Scoop `role=bot`, `meta {voice: true, live: true, silent: true}` (keine Mitteilung). Delegierte Aufgaben erscheinen als Ereignis „Live-Auftrag: …“ (`meta {icon: "waveform", live: true}`), danach die normale (ausführliche) Antwort des Scoop-Laufs.

**Der Scoop bleibt der Scoop:** Systemanweisung der Live-Sitzung aus Name, Rolle, Charakter, Gedächtnis-Auszug (geteilte Fakten, Profil, Tagebuch) und den letzten 14 Chat-Nachrichten. Echte Aufgaben delegiert Live über ein Responses-Backend (`delegation.type = "responses"`, Modell `live_voice.backend`, Standard `gpt-6-luna`) mit dem Werkzeug `aufgabe_an_scoop(auftrag)`: Der Server legt das Ereignis an, stößt den normalen Lauf an (Warteschlange in `bots.py`), wartet (max. 5 Min.) und gibt die Antwort als `function_call_output` zurück (`response.item.create` + `response.create`). Live sagt vorher kurz „Ich schau kurz nach …“ und spricht danach eine Zusammenfassung.

**Grenzen und Kosten:** `gpt-live-1` kostet 0,05 $ pro Minute (sekundengenau, `session.usage.updated`), Backend-Tokens extra. Beides wird nach der Sitzung in `usage` gebucht (Modelle `gpt-live-1` und Backend-Modell, sichtbar in `/api/usage`). Nach 2 Min. ohne Sprache endet die Sitzung (`idle`), harte Grenze 15 Min. (`limit`, 15 s vorher verabschiedet sich der Scoop). Höchstens 2 gleichzeitige Live-Sitzungen pro Server. Einstellbar in `config.json`:

```json
"live_voice": {"enabled": true, "default_voice": "marin", "backend": "gpt-6-luna", "backend_reasoning": "none",
               "max_minutes": 15, "idle_seconds": 120}
```

Test (gemockter Live-Endpunkt, eigene Instanz, nie Port 8787): `cd Server && uv run python tests/test_live_voice.py`. Für Diagnose: `AISBOT_LIVE_DEBUG=1` (Byte-Zähler und Transkript-Zeitstempel im Log), `AISBOT_LIVE_URL` (anderer Live-Endpunkt, nur Tests).

## v1.14 – Geteilte Scoops (Gäste)

Server-Version 1.14.0. Vollständige Schnittstelle mit Beispielen (Convex-Funktionen, Gast-Endpunkte, Rechte-Matrix,
WebSocket-Filter, Push an Gäste): `docs/sharing.md`, Abschnitt „Ist-Stand Phase 1“. Umsetzung: `Server/src/aisbot/sharing.py`.

- **Prinzipal pro Anfrage:** API-Token oder Sitzungs-JWT des Inhabers → Admin, alles wie bisher. Gültiges Sitzungs-JWT
  eines **anderen** Kontos → Gast: **403** auf allen Endpunkten außer den ausdrücklich freigegebenen (früher 401).
  401 bleibt für ungültige/abgelaufene/abgemeldete Tokens.
- Gast-Endpunkte: dieselben Pfade wie beim Admin (Scoop-Liste, Nachrichten, Dateien, Reaktionen, Lesen, Bearbeiten
  mit Rolle edit, Sprechmodus mit `?bot=`, Rechner mit `?bot=` nach Rechner-Stufe) plus `GET /api/shared/me`,
  `POST`/`DELETE /api/shared/devices`.
- **Nachrichten:** Nutzer-Nachrichten tragen `meta.author_user_id`, `meta.author_name`, `meta.author_role`
  (`admin`|`read`|`write`|`edit`), sobald der Server mit einem Konto gekoppelt ist. Reaktionen von Gästen: `meta.reactions["user:<id>"]`.
- **Scoop (Admin):** zusätzlich `shared {count, members[]}`, `guest_tools {web, computer, apps[], mcp[], phone, mail}`,
  `guest_budget` (US-$ pro Gast und Tag, Standard 2). `PATCH /api/bots/{id}` nimmt `guest_tools`/`guest_budget` an;
  `GET`/`PATCH /api/bots/{id}/sharing` (mit Auswahl-Optionen); `POST /api/shares/refresh`.
- **Kosten:** `GET /api/usage` → zusätzlich `by_bot`; neu `GET /api/bots/{id}/usage` (pro Person).
- **WebSocket:** Gäste nur Ereignisse geteilter Scoops (umgeformt); neues Ereignis `share.updated`; Close **4403**,
  wenn ein Gast keinen Share (mehr) hat.
- Freigabe-Karten aus Gast-Läufen tragen beim Admin `meta.requested_by {user_id, name}`.

## v1.15 – Antworten auf Nachrichten

Server-Version 1.15.0. Wie bei Telegram kann man auf eine bestimmte Nachricht antworten.

- `POST /api/bots/{id}/messages` und `POST /api/groups/{id}/messages` nehmen optional `reply_to` an (ID einer
  Nachricht). Zitierbar sind nur `user`- und `bot`-Nachrichten **desselben Chats**; andere IDs (anderer Chat, unbekannt,
  Ereignis, Freigabe, Status, kein String) werden stillschweigend ignoriert. Für Gäste gelten die bestehenden Prüfungen
  (nur geteilte Scoops mit Rolle `write`/`edit`).
- Die neue Nutzer-Nachricht trägt dann in `meta`:
  ```json
  "reply_to": {"id": "m_123", "role": "bot", "author_id": "b_9f2c", "author_name": "Mila",
               "text": "Morgen um 9 Uhr ist das Teammeeting …"}
  ```
  `text` ist ein einzeiliger Auszug ohne Markdown, höchstens 200 Zeichen (gekürzt mit „…“; nur Anhang → „Anhang“).
  `author_id` ist bei Scoops die Scoop-ID, bei Personen `author_user_id` der zitierten Nachricht (fehlt ohne Konto).
  Der Auszug ist eine Momentaufnahme; die App springt per `id` zur Originalnachricht.
- Modell: Vor die Nachricht kommt im Verlauf ein Hinweis, z. B. `[Antwort auf Nachricht von Mila: „…“]` bzw.
  `[Antwort auf deine Nachricht: „…“]`, wenn der antwortende Scoop die zitierte Nachricht selbst geschrieben hat.
- Gruppen: Antwortet man ohne `@Name` auf die Nachricht eines Scoops, antwortet dieser Scoop (kein Routing-Modell).
  `@Name`/`@alle` haben Vorrang.

## v1.16 – Apps verbinden: ganzer Composio-Katalog

Alle Endpunkte nur für den Inhaber (`auth`); Gäste geteilter Scoops bekommen 403 (Standard verweigern). Die bisherigen
Endpunkte (`GET /api/connections`, `…/link`, `…/accounts/{id}` mit PATCH/DELETE/reconnect, höchstens 10 Konten je App)
bleiben unverändert; `link` funktioniert jetzt für jeden Slug aus dem Katalog.

- **Katalog:** der Server lädt `GET /api/v3/toolkits` von Composio (seitenweise, ca. 1700 Apps, ohne veraltete) und
  speichert eine kompakte Fassung in `data/composio_catalog.json`. Älter als 24 h → im Hintergrund neu laden, die alte
  Liste gilt solange weiter. Ohne Composio-Schlüssel oder offline: die zehn bekannten Apps (`source: "fallback"`).
- `GET /api/connections/catalog?category=&q=&limit=60&offset=0` →
  ```json
  {"items": [{"slug": "gmail", "name": "Gmail", "detail": "Mails lesen, Entwürfe schreiben, senden",
              "logo_url": "https://logos.composio.dev/api/gmail", "symbol": "envelope.fill",
              "category": "communication", "categories": ["communication"], "auth": "oauth",
              "auth_schemes": ["OAUTH2"], "popular": true, "connected": 2, "accounts": [{…wie v1.8…}],
              "can_add": true, "tools": 61}],
   "total": 10, "offset": 0, "next_offset": null, "connected_apps": 4, "max_per_app": 10,
   "source": "composio", "updated_at": "2026-11-14T10:40:00+00:00"}
  ```
  `category`: `popular` (die zehn bekannten Apps in fester Reihenfolge), `connected` (Apps mit Konten, auch abgelaufene),
  eine Kategorie-ID aus `/categories` oder leer (alle; bekannte Apps vorn, dann nach Beliebtheit bei Composio).
  `q` sucht in Name, Slug, Beschreibung und Kategorie (Namensanfang vor Wortanfang vor Teilstring). `limit` ≤ 200.
  `connected` = aktive Konten, `accounts` ohne `initializing`. `detail`: deutscher Text für die bekannten Apps, sonst
  der erste Satz der (englischen) Composio-Beschreibung.
  `auth`: `oauth` (Anmeldung im Browser über `…/link`: Composio-verwaltetes OAuth, DCR_OAUTH oder eine eigene
  Auth-Config im Projekt), `fields` (Formular: API_KEY, BEARER_TOKEN, BASIC, BASIC_WITH_JWT), `none` (keine Anmeldung
  nötig), `unavailable` (keine verwaltete Anmeldung; `…/link` → 422 mit Erklärung).
- `GET /api/connections/categories` →
  `{"categories": [{"id": "popular", "name": "Beliebt", "count": 10}, {"id": "connected", "name": "Verbunden", "count": 4},
  {"id": "productivity", "name": "Produktivität", "count": 413}, …], "total": 1742, "source": "composio"}`.
  Eigene Gruppen mit deutschem Namen (Reihenfolge fest): `productivity` Produktivität, `communication` Kommunikation,
  `design` Design, `development` Entwicklung, `data` Daten, `finance` Finanzen, `marketing` Marketing, `sales`
  Vertrieb & CRM, `ai` KI, `commerce` Handel, `hr` Personal, `education` Bildung, `lifestyle` Freizeit. Composio-
  Kategorien ohne Zuordnung erscheinen ab 8 Apps mit ihrem Originalnamen (ID = Name in Kleinbuchstaben mit `-`).
- `GET /api/connections/catalog/{slug}` →
  `{"slug", "name", "detail", "logo_url", "auth", "scheme": "API_KEY", "fields": [{"name": "generic_api_key",
  "label": "API Key", "description": "…", "secret": true, "required": true, "default": null}], "message": null,
  "guide_url": null, "max_per_app": 10}`. Felder aus `auth_config_details[].fields.connected_account_initiation`
  (Pflicht zuerst). Bei `none`/`unavailable` steht der Hinweis in `message`. Unbekannte App → 404.
- `POST /api/connections/{slug}/connect` `{"alias": "privat"?, "fields": [{"name": "generic_api_key", "value": "…"}]}`
  (auch `{"fields": {"name": "value"}}`) → `{"account_id": "ca_…", "status": "active"}`. Der Server nimmt eine
  vorhandene Auth-Config der Anmeldeart oder legt eine eigene an (`use_custom_auth`, ohne Zugangsdaten; die
  Tool-Router-Sitzung findet sie für das Toolkit von selbst) und legt das Konto mit `connection.state.val` an.
  Die Werte gehen nur an Composio: nicht gespeichert, nicht protokolliert, in Fehlermeldungen geschwärzt.
  Fehler: Pflichtfeld fehlt, Name doppelt, mehr als 10 Konten, Angaben abgelehnt → 409 mit Text; App ohne Formular
  (`oauth`, `unavailable`, `none`) → 422; Composio-Fehler → 502.
- `GET /api/connections/logo/{slug}` → `image/png` (128 px). Composio liefert SVG, das die Apps nicht direkt zeigen
  können; der Server wandelt mit `sips` um und hält das Bild 30 Tage in `data/connection_logos/`. Kein Logo → 404.
- `POST /api/connections/{slug}/link` bei einer App ohne verwaltete Anmeldung (Composio `ToolRouterV2_NoManagedAuth`)
  → 422 „Für X bietet Composio keine fertige Anmeldung an …“; unbekannte App → 404.

## v1.17 – Apple-Dienste (Erinnerungen, Kalender, Kontakte)

Server-Version 1.17.0. Die Scoops greifen über einen **Apple-Rechner** auf Apple-Erinnerungen, Apple-Kalender und Kontakte
zu: ein Mac mit „AIS Scoops Server“ (Rolle `server` oder `connect`), der per `/api/nodes/link` verbunden ist und die
macOS-Freigaben hat (EventKit, Contacts). Der Server leitet jede Aktion als Befehl `apple.*` dorthin weiter
(docs/scoops-connect.md). Änderungen landen per iCloud sofort auf dem iPhone, auch in Routinen.

- **Apple-Rechner:** config.json `apple_node` (ausdrücklich gewählt), sonst der Rechner auf **demselben Mac** wie der
  Server (gleiche Geräte-ID wie im `hello`), sonst `default_computer_node`. Nie der VM-Bot-Rechner.
- **Freigaben** meldet der Mac im `hello`/`state`: `apple: {reminders, calendar, contacts}` mit `granted`, `denied`,
  `not_determined`, `restricted`, `write_only`, `disabled` (in der Mac-App ausgeschaltet). Fehlt das Feld (alte App),
  gilt `unknown`. `GET /api/nodes` zeigt sie je Rechner als `apple` (Gäste bekommen das Feld nie).
- `GET /api/apple` →
  ```json
  {"node_id": "n_…", "node_name": "MacBook Air", "node_online": true, "node_source": "local", "node_choice": "auto",
   "nodes": [{"id": "n_…", "name": "MacBook Air", "online": true, "apple": {"reminders": "granted", …}}],
   "services": [{"id": "reminders", "name": "Erinnerungen", "tool": "apple_erinnerungen", "enabled": true,
                 "permission": "granted", "available": true, "status": "ready", "hint": null, "node_id": "n_…"}, …]}
  ```
  `node_source`: `config` | `local` | `default` | `none`. `status` je Dienst: `ready`, `off` (ausgeschaltet),
  `needs_permission` (Freigabe auf dem Mac fehlt; `hint` „Auf dem Mac in AIS Scoops Server freigeben.“),
  `needs_update` (Mac-App zu alt), `offline`, `no_node`. Reihenfolge immer reminders, calendar, contacts.
- `PATCH /api/apple` `{reminders?: bool, calendar?: bool, contacts?: bool, node?: "n_…" | ""}` → wie GET.
  Nicht-bool → 400, unbekannter Rechner oder `vm` → 404, `node: ""` = automatisch. Speichert `apple_services` und
  `apple_node` in config.json. Standard: alle Dienste aus.
- **Werkzeuge** (Claude und OpenAI): `apple_erinnerungen` (aktion `listen`, `anzeigen`, `anlegen`, `aendern`,
  `erledigen`, `loeschen`), `apple_kalender` (`kalender`, `termine`, `anlegen`, `aendern`, `loeschen`; Serien:
  `alle_folgenden`), `apple_kontakte` (`suchen`, `geburtstage`; nur lesen). Ein Werkzeug erscheint nur, wenn der Dienst
  eingeschaltet ist, der Apple-Rechner verbunden ist und dort die Freigabe `granted` ist. Fällt er während eines Laufs
  aus, bekommt der Scoop eine klare Fehlermeldung („… ist offline … Sag Arman Bescheid“). Kurzer Systemprompt-Hinweis:
  für Erinnerungen, Termine und Kontakte zuerst diese Werkzeuge statt Composio/Google Kalender.
- **Löschen** von Erinnerungen und Terminen läuft über eine Freigabe-Karte (`meta.kind = "apple"`, Titel z. B.
  „Termin löschen: „Zahnarzt“ (14.11.2026, 10:00)“); erst nach „Freigeben“ schickt der Server `apple.*.delete`.
  Anlegen, Ändern und Abhaken sind frei.
- **Gäste** geteilter Scoops bekommen diese Werkzeuge nie (`sharing.NEVER_FOR_GUESTS`, unabhängig von
  „Werkzeuge für Geteilte“); sie stehen auch nicht in den Auswahl-Optionen von `GET /api/bots/{id}/sharing`.
- **Pause** in der Mac-App betrifft nur Bildschirm, Maus und Tastatur; `apple.*` läuft weiter.
- **WebSocket:** Ereignis `apple.updated` (gleiche Daten wie `GET /api/apple`) nach PATCH und wenn sich Freigaben
  oder die Verbindung des Apple-Rechners ändern. Nur an den Inhaber.

## v1.18 – Apple-Dienste über das iPhone (Home, Wecker, Standort)

Server-Version 1.18.0. Umsetzung: `Server/src/aisbot/apple_device.py`, App: `App/AISBot/Apple/`. HomeKit, AlarmKit
(iOS 26+) und Geofences gibt es nur auf iPhone/iPad. Die iOS-App AIS Scoops meldet sich deshalb beim eigenen Server als
**Apple-Gerät** an; der Mac-Client meldet diese Fähigkeiten nie (ein Gerät mit `kind: "mac"` bekommt `capabilities: []`).

**Gerät und Auswahl.** Tabelle `apple_devices` (ID, Name, Art `iphone|ipad|mac`, Modell, OS, App-Version, Fähigkeiten,
Freigaben, Push-Token, `last_seen`, `last_active`). Gewählt wird config.json `apple_device` (ausdrücklich), sonst das
**zuletzt aktive iPhone**, sonst das zuletzt aktive iPad. „Aktiv“ = App im Vordergrund (hello mit `active: true`).

**Anmeldung (Live-Verbindung `/api/ws`, nur Inhaber).** App → Server, bei jedem Verbinden und wenn sich Freigaben oder
das Push-Token ändern:
```json
{"type": "device.hello", "device_id": "ios-…", "name": "Armans iPhone", "kind": "iphone", "model": "iPhone18,2",
 "os": "iOS 27.2", "app_version": "1.1 (40)", "capabilities": ["home", "alarms", "location"],
 "permissions": {"home": "granted", "alarms": "not_determined", "location": "when_in_use"},
 "push_token": "<hex>", "active": true}
```
Freigaben: `home`/`alarms` → `granted|denied|not_determined|restricted|unknown`; `location` →
`always|when_in_use|denied|not_determined|restricted`. Antwort `{"type": "device.welcome", "data": Gerät}` und danach
alle noch offenen `device.cmd`. App im Hintergrund: `{"type": "device.state", "active": false}` (zurück: neues hello).
Gäste: `device.*` wird ignoriert.

**Befehle.** Server → App `{"type": "device.cmd", "data": {"id": "dc_…", "device_id", "command", "params", "created_at"}}`,
App → Server `{"type": "device.result", "id": "dc_…", "result": {"success": true, …}}` (Fehler
`{"success": false, "error": "…"}`). Ablauf im Server (`AppleDevices.call`):
1. App verbunden und aktiv → über den Socket; ohne Antwort nach 3 s zusätzlich wecken.
2. Sonst **stille Push** an das Push-Token (`{"aps": {"content-available": 1}, "apple_cmd": "dc_…"}`, `apns-push-type:
   background`, Priorität 5; direkt oder über das Convex-Relay, Push-Art `background`). Die App holt in einer
   Hintergrund-Aufgabe die offenen Befehle und antwortet per HTTP.
3. Nach **25 s** ohne Antwort bekommt der Scoop: „iPhone nicht erreichbar – öffne AIS Scoops auf „…“. Im Hintergrund kann
   iOS das Aufwecken verzögern oder auslassen …“. Öffnet Arman die App innerhalb der 25 s, läuft der Befehl dann.

**Ehrlich:** Im Hintergrund ist das **nicht garantiert**. iOS stellt stille Pushes nach eigenem Ermessen zu (Drosselung,
Energiesparmodus, Fokus/Ladezustand), und gar nicht, wenn die App im App-Umschalter beendet wurde. Doppelt zugestellte
Befehle (Socket + Push) führt die App nur einmal aus.

**HTTP für den Hintergrund** (alle mit Auth, nur Inhaber; unbekannte `device_id` → 404):
| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| POST | `/api/apple/device` | wie `device.hello` (ohne `type`) | `{"device": Gerät, "commands": [Befehl]}` (400 bei ungültiger ID) |
| POST | `/api/apple/device/poll` | `{"device_id"}` | `{"commands": [Befehl]}` |
| POST | `/api/apple/device/result` | `{"device_id", "id", "result"}` | `{"ok": true, "resolved": bool}` |
| POST | `/api/apple/device/event` | `{"device_id", "type": "geofence", "id": "gf_…", "event": "enter"\|"exit", "at": "<iso>"}` | `{"ok": true, "handled": bool}` |
| DELETE | `/api/apple/device/{id}` | – | wie `GET /api/apple` (entfernt Gerät und seine Orte) |

**Befehle an das Gerät** (`params`/Ergebnis zusätzlich zu `success`):
| command | params | result |
|---|---|---|
| `apple.home.overview` | `home?`, `room?` (Teilname) | `{"homes": [{id, name, primary, rooms[], accessories[], scenes[{id, name, sensitive}]}]}` |
| `apple.home.get` | `id` (Gerät, Dienst oder Name) | `{"accessory": {id, name, room, category, reachable, sensitive, services[{id, name, type, sensitive?, on?, brightness?, current_temperature?, target_temperature?, humidity?, position?, lock_state?, door_state?, security_state?, contact?, motion?}]}}` (Werte frisch gelesen) |
| `apple.home.set` | `id`, `on?`, `brightness?` 0–100, `target_temperature?`, `position?` 0–100, `lock?` secured/unsecured, `door?` open/closed, `security?` off/stay/away/night, `confirmed?` | `{"changed": [...], "accessory": …}` |
| `apple.home.scene` | `id`, `confirmed?` | `{"scene": {id, name, executed}}` |
| `apple.alarms.list` | – | `{"alarms": [{id, title, kind: alarm\|timer, state, time?, weekdays?, date?, seconds?, ends_at?}]}` |
| `apple.alarms.add` | `title`, `time` "HH:MM" + `weekdays?` [monday …] oder `date` (ISO, ohne Zone = Ortszeit) | `{"alarm": …}` |
| `apple.alarms.timer` | `seconds` (5 s – 24 h), `title` | `{"alarm": …}` (Countdown als Live-Aktivität) |
| `apple.alarms.delete` | `id` | `{"deleted": {id, title}}` |
| `apple.location.current` | – | `{latitude, longitude (5 Stellen), accuracy_m, timestamp, address?, place?}` |
| `apple.location.geofence_add` | `id`, `name`, `address` oder `here: true`, `radius` 100–2000, `on_entry`, `on_exit` | `{"geofence": {id, name, address, radius, on_entry, on_exit, created_at}}` (ohne Koordinaten) |
| `apple.location.geofences` | – | `{"geofences": [… + inside?, monitored?]}` |
| `apple.location.geofence_delete` | `id` | `{"deleted": {id, name}}` |

Schlösser, Garagentore, Alarmanlagen und Türen (Diensttypen `lock`, `garage_door`, `security_system`, `door`) schaltet die
App nur mit `confirmed: true`; den setzt der Server erst nach „Freigeben“ auf einer Freigabe-Karte.

**Werkzeuge** (Claude und OpenAI, nur wenn ein passendes Gerät existiert, der Dienst eingeschaltet ist und die Freigabe
erteilt wurde; Standort: `always` oder `when_in_use`):
- `apple_home`: `uebersicht` (zuhause, raum), `geraet` (id), `schalten` (id + an, helligkeit, temperatur, position;
  verriegeln, oeffnen, modus), `szene` (id oder Name). Schalten eines empfindlichen Geräts oder eine Szene mit solchen
  Geräten → Freigabe-Karte `meta.kind = "apple"`, `meta.icon = "house.fill"`, Titel z. B. „Haustür (Flur): entriegeln“;
  nach Freigabe Ereignis „Haustür: entriegeln“ und der Scoop macht weiter.
- `apple_wecker`: `stellen` (uhrzeit HH:MM oder zeitpunkt, titel, wiederholen „mo,mi,fr“ / „werktags“ / „wochenende“ /
  „täglich“), `timer` (minuten/sekunden, titel), `anzeigen`, `loeschen` (ohne Freigabe: nur eigene Wecker der App).
- `apple_standort`: `wo`, `ort_anlegen` (name, adresse oder hier, radius_m, bei betreten/verlassen/beides, notiz; braucht
  „Immer“), `orte`, `ort_loeschen`. Der Server speichert pro Ort nur Name, Chat, Scoop, Notiz, Auslöser und Radius
  (Tabelle `apple_geofences`), **keine Koordinaten**. Beim Auslösen: lokale Mitteilung auf dem iPhone, `POST …/event`,
  im Chat das Ereignis „Büro betreten“ (`meta.icon = "location.fill"`, `geofence_id`, `geofence_event`) und der Scoop
  bekommt die Notiz als Auftrag. Doppelte Meldungen innerhalb von 90 s werden ignoriert.
- Gäste geteilter Scoops bekommen diese Werkzeuge **nie** (`sharing.NEVER_FOR_GUESTS`). Kurzer Systemprompt-Hinweis.

**`GET /api/apple`** zusätzlich (ältere Felder unverändert; die neuen Dienste stehen bewusst in einer eigenen Liste,
damit ältere Apps sie nicht als Mac-Dienste anzeigen):
```json
{"device": {"id": "ios-…", "name": "Armans iPhone", "kind": "iphone", "model": "iPhone18,2", "os": "iOS 27.2",
            "app_version": "1.1 (40)", "online": true, "active": false, "last_seen": "…", "last_active": "…",
            "capabilities": ["home", "alarms", "location"], "permissions": {…}, "push": true, "source": "auto"} | null,
 "device_choice": "auto",
 "devices": [Gerät, …],
 "device_services": [{"id": "home", "name": "Home", "tool": "apple_home", "enabled": true, "permission": "granted",
                      "available": true, "status": "ready", "hint": null, "device_id": "ios-…"},
                     {"id": "alarms", "name": "Wecker", …}, {"id": "location", "name": "Standort", …, "background": true}]}
```
`status`: `ready`, `off`, `needs_permission` („Auf dem iPhone in AIS Scoops erlauben.“), `unsupported`, `no_device`.
**`PATCH /api/apple`** nimmt zusätzlich `home`, `alarms`, `location` (bool, sonst 400) und `device` (ID oder `""` =
automatisch; unbekannt oder Mac → 404). `apple_services` in config.json enthält dann alle sechs Dienste. `apple.updated`
kommt auch bei Geräteänderungen (anmelden, verbinden, trennen, Freigaben).

**App:** „Apps verbinden“ → Apple → Abschnitt **Über dein iPhone**. Auf iPhone/iPad löst „Erlauben“ die iOS-Abfrage aus
(HomeKit, AlarmKit, Standort „Beim Verwenden“) und schaltet den Dienst danach ein; eigene Zeile „Orte: „Immer“ erlauben“
mit Erklärung. Abgelehnt → „Einstellungen“. Auf dem Mac: „Auf dem iPhone erlauben“ und der Gerätestatus. Info.plist:
`NSHomeKitUsageDescription`, `NSAlarmKitUsageDescription`, `NSLocationWhenInUseUsageDescription`,
`NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes: [remote-notification]`; Entitlement
`com.apple.developer.homekit` (iOS). Timer-Countdown: `AISBotWidgets/AlarmCountdownLiveActivity.swift`.

Tests: `cd Server && uv run python tests/test_apple_device.py` (gemocktes iPhone über `/api/ws`, Push gemockt).

## v1.19 – Aufgabenmodus und ausdauernde Chat-Läufe

Ausführlich: [`docs/aufgaben.md`](aufgaben.md).

**Chat-Läufe:** Schrittgrenze 150 (Claude, vorher 60) bzw. 120 (OpenAI, vorher 40); die Kostengrenze je Lauf (1,50 $)
bremst weiter. Serverseitige Compaction: Claude `compact_20260112` (Beta `compact-2026-01-12`, Auslöser 120.000
Eingabe-Token, neben `clear_tool_uses`), OpenAI `context_management: [{"type": "compaction", "compact_threshold": 120000}]`.
Bricht ein Lauf ab (Stopp, Kosten-/Schrittgrenze, Fehler, Neustart), speichert der Server seinen Verlauf
(`<data>/resume/`, 24 h). Schreibt der Nutzer danach „mach weiter“ (auch „weiter“, „fortsetzen“, „continue“), setzt der
Scoop genau dort fort. Statuskarte: `meta.resumed = true`.

**Aufgabe** (Objekt):
```json
{"id": "t_…", "bot_id": "b_…", "chat_id": "b_…|g_…", "title": "…", "prompt": "…", "origin": "scoop|user|chat",
 "engine": "claude|openai", "model": "…", "state": "queued|running|waiting|done|failed|stopped|limit",
 "cost_usd": 0.12, "budget_usd": 3.0, "max_minutes": 60, "active_minutes": 4.2, "result": "Abschlussbericht",
 "error": null, "files": ["f_…"], "waiting_for": "Frage oder Freigabe-Titel" | null, "note": "letzter Zwischenstand",
 "status_message_id": "m_…", "created_at": "…", "started_at": "…", "finished_at": "…"}
```

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/bots/{id}/tasks` | – | `[Aufgabe]` (neueste zuerst) |
| POST | `/api/bots/{id}/tasks` | `{prompt, title?, budget_usd?, max_minutes?, actor_id?}` (`actor_id` in Gruppen) | `Aufgabe` |
| GET | `/api/tasks?limit=30` | – | `[Aufgabe]` aller Chats |
| GET | `/api/tasks/{id}` | – | `Aufgabe` |
| POST | `/api/tasks/{id}/stop` | – | `Aufgabe` |
| POST | `/api/tasks/{id}/continue` | `{message?}` | `Aufgabe` (wartend/angehalten/fertig fortsetzen) |
| GET | `/api/tasks/settings` | – | `{task_mode, task_max_parallel, task_budget_usd, task_max_minutes, task_openai_engine, task_effort, task_archive_days, codex_available, codex_blocked_reason}` (`task_archive_days`: archivierte Aufgaben nach so vielen Tagen löschen, 0 = nie, ab 1.40) |
| PATCH | `/api/tasks/settings` | Felder wie oben | Einstellungen |

Nur der Inhaber (Gäste: 403). `POST /api/bots/{id}/stop` hält auch die Aufgaben des Chats an. `GET /api/health` hat
zusätzlich `active_tasks`. `Bot.busy` ist `true`, solange eine Aufgabe des Chats läuft.

**Im Chat:** Nachricht `/aufgabe <Auftrag>` startet ohne Chat-Lauf direkt eine Aufgabe. Scoops haben die Werkzeuge
`aufgabe_starten`, `aufgaben_status`, `aufgabe_fortsetzen`, `aufgabe_stoppen` (nicht für Gäste).

**Statuskarte einer Aufgabe:** normale `status`-Nachricht mit `meta.task = {"id", "title", "state", "engine", "note",
"budget_usd", "max_minutes"}`. `meta.state` bleibt `running`, solange die Aufgabe läuft oder wartet (`task.state =
"waiting"`), danach `done|failed|stopped`. Ereignisse und Nachrichten aus der Aufgabe tragen `meta.task_id`
(„Aufgabe fertig: … · 0.12 $“; „Aus der Aufgabe: Bericht.md“ mit `file_id` nur noch bei `datei_in_bibliothek`). Am Ende
schreibt der Scoop das Ergebnis im Chat; vom Scoop gezeigte Dateien folgen als Ereignis „Ergebnis: Bericht.md“ mit
`file_id` (Werkzeug `datei_zeigen`, ab Server 1.38). App ab v1.19: Kennzeichnung „Aufgabe“ mit Titel, Zwischenstand, Knopf „Aufgabe anhalten“; eine Aufgaben-Karte gilt
nie als von einem späteren Chat-Lauf „überholt“.

**`POST /mcp/task`:** MCP (Streamable HTTP, JSON-Antworten) für die Agent-SDKs einer laufenden Aufgabe. Bearer-Token gilt
nur für diesen Lauf; GET/DELETE → 405. Nicht für Apps.

## v1.20 – „Immer erlauben“ und Modell pro Routine

### Dauerhafte Freigaben („Immer erlauben“)

Pro Scoop kann der Admin wiederkehrende Freigaben dauerhaft erlauben. Freigabe-Nachrichten (`role = "approval"`) tragen
dann `meta.can_always = true` und `meta.always_label` (lesbare Bezeichnung, z. B. „Friday Checkouts in der Team App
abhaken“). Fehlt `can_always`, gibt es kein „Immer erlauben“ (Knopf nicht zeigen).

- Entscheiden: `POST /api/approvals/{id}` `{"decision": "approve_always", "edits"?: …}` = freigeben **und** künftig für
  diesen Scoop automatisch freigeben. Geht nur bei `can_always`, sonst 400 (`{"error": …}`). Danach `meta.state =
  "approved"`, `meta.always = true`; zusätzlich Ereignis „Immer erlaubt: …“ (`icon = "checkmark.seal"`). Bei Mails gilt
  `edits` wie bei `approve`; die Dauerfreigabe gilt dann für die tatsächlich gesendeten Empfänger.
- Schlüssel je Art: allgemeine Freigabe (`freigabe_anfordern`) nur, wenn der Scoop eine `art` setzt (stabiler Schlüssel
  wie `teamapp-checkouts-abhaken`, zu allgemeine Schlüssel zählen nicht); Mail je Konto und Empfänger (an + cc);
  T3-Auftrag je Projekt; Nachricht an T3 je Thread; Apple Home nur unkritische Befehle je Gerät/Szene.
- **Nie** dauerhaft erlaubbar (serverseitig erzwungen): Anrufe (`kind = "call"`), Tresor/Logins (`"vault"`), Löschen in
  Erinnerungen/Kalender, Schlösser, Türen, Garagentore, Alarmanlage/Sicherheit, Zahlungen/Käufe, Zugangsdaten, und
  Freigaben aus Gast-Läufen geteilter Scoops (Gäste können nichts dauerhaft erlauben; Dauerfreigaben greifen in
  Gast-Läufen nicht).
- Fordert der Scoop später dieselbe Art an, entsteht **keine** Karte: Der Server führt sofort und still aus (ab Server
  1.38.1 ohne Ereignis im Chat; das einmalige „Immer erlaubt: …“ beim Erteilen reicht, der Schritt steht in der
  Lauf-Karte). Bis 1.38.0 kam jedes Mal ein Ereignis „Automatisch freigegeben: …“ (`meta.auto_approved`).
  Der Scoop kennt seine Dauerfreigaben aus dem Systemprompt.

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/bots/{id}/standing-approvals` | – | `[{"id": "sa_…", "bot_id", "key", "label", "kind": "freigabe\|mail\|t3\|t3_send\|apple", "created_at"}]` |
| DELETE | `/api/bots/{id}/standing-approvals/{sid}` | – | `{"ok": true}` (künftig wieder fragen) |

Nur der Inhaber (Gäste: 403).

### Modell pro Routine

`Routine.model` (`null` = Modell des Scoops). Ändern per `PATCH /api/routines/{id}` `{"model": "claude-haiku-5-5"}`
bzw. `{"model": null}` (nur der Admin, unbekanntes Modell → 400). Ein Routinenlauf nutzt dieses Modell (Claude- und
OpenAI-Scoops); Kosten und Statusnachricht (`meta.model`) zeigen das tatsächlich genutzte Modell. Ist für das Modell
kein Schlüssel hinterlegt, läuft die Routine mit dem Modell des Scoops (Hinweis im Server-Log). Scoops setzen das Modell
über `routine_anlegen` (`modell`, Standard `wie_scoop`) und das neue Werkzeug `routine_aendern`.

## v1.21 – Aufsicht über die anderen Scoops

Der Haupt-Scoop und Scoops mit dem Schalter „Darf andere Scoops prüfen“ können die anderen Scoops und Gruppen dieses
Servers prüfen und Verbesserungen vorschlagen (Details: `docs/aufsicht.md`).

- Bot-Felder: `can_review` (bool, gespeicherter Schalter, Standard `false`) und `reviewer` (bool, wirksam: Haupt-Scoop
  oder `can_review`, aber `false`, solange der Scoop geteilt ist). Setzen per `PATCH /api/bots/{id}`
  `{"can_review": true}` – nur der Admin (Gäste: 403). Beim Haupt-Scoop ist die Aufsicht immer an.
- Werkzeuge der Scoops (nur in Läufen des Admins im eigenen Einzelchat; nie in Gast-Läufen, geteilten Chats, Gruppen
  oder Läufen auf Bitte eines anderen Scoops): `scoops_ueberblick`, `chat_lesen`, `scoop_details`, `scoop_verbessern`.
  Ausgaben höchstens 12 000 Zeichen pro Aufruf (`chat_lesen` seitenweise). Gast-Nachrichten geteilter Scoops und die
  Antworten darauf werden nie ausgeliefert, Bilder nur als Platzhalter, kein Tresor.
- Neue Freigabe-Art `meta.kind = "scoop_update"` (im Chat des vorschlagenden Scoops) mit
  `meta.scoop_update = {"target_id", "target_name", "target_label", "art": "faehigkeit|gedaechtnis|anweisungen|routine_modell",
  "label", "reason", "before"?, "after", "editable", "status": "pending|applied|declined|failed", "error"?, "edited"?}`
  (+ je Art z. B. `skill_name`, `routine_title`, `mode`). Nie `can_always`; `approve_always` → 400.
- Entscheiden: `POST /api/approvals/{id}` `{"decision": "approve" | "decline", "edits"?: {"after": "…"}, "note"?}`.
  `edits.after` (nur bei `editable`) ersetzt den neuen Text (Anleitung der Fähigkeit, Gedächtnis-Eintrag bzw. kompletter
  neuer Charakter). Erst dann wird angewendet; Ereignis „Übernommen: …“ im Chat des Vorschlagenden und „Verbesserung
  von <Name>: …“ (`icon = "wand.and.stars"`) im Chat des geänderten Scoops.
- Bot-Antworten tragen zusätzlich `meta.run_info = {"run_id", "model", "cost_usd", "steps", "seconds", "stop_reason"}`,
  Statuszeilen `meta.stop_reason`, Fehlermeldungen `meta.failed = true`, Nachrichten aus Gast-Läufen
  `meta.guest_run = true` (für die Aufsicht; Gäste sehen `run_info` nicht).

## v1.22 – Aufgaben-Board, geplante Aufgaben, Abnahme

Details: `docs/aufgaben.md` („Board“). Alle Endpunkte nur für den Admin (Gäste geteilter Scoops: 403, keine Ereignisse).

### Aufgabe (Erweiterung)

Neue Felder: `scheduled_at` (Termin, ISO mit Zeitzone, nur bei `state = "scheduled"`), `review` (`null` | `"review"` |
`"done"` | `"archived"`, Abnahme getrennt vom Laufzustand), `reviewed_at`, `archived_at`, `model_choice` (gewähltes Modell,
`null` = wie Scoop; `model` ist das wirksame Modell), `column` (`planned` | `active` | `review` | `done` | `archived`),
`steps` (Schritte der Statuskarte), `waiting_kind` (`frage` | `freigabe`), `updated_at`. Neuer Laufzustand `scheduled`.
Fertige, fehlgeschlagene, gestoppte und am Limit angehaltene Aufgaben landen mit `review = "review"` in „Zu prüfen“.

| Spalte | Bedingung |
|---|---|
| `planned` (Geplant) | `state = scheduled` |
| `active` (In Arbeit) | `state` in `queued`, `running`, `waiting` |
| `review` (Zu prüfen) | beendet, `review` = `review` (oder `null`) |
| `done` (Abgeschlossen) | beendet, `review = done` |
| `archived` (Archiv) | beendet, `review = archived` |

### Endpunkte

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/tasks?limit=&bot=&chat=&column=` | Liste über alle Scoops (neueste zuerst, `limit` bis 500, `column` kommagetrennt) |
| POST | `/api/tasks` | Anlegen: `{chat_id, actor_id?, prompt, title?, model?, scheduled_at?}`; ohne Termin sofort, sonst geplant (Termin in der Vergangenheit = sofort). `origin = "board"` |
| GET | `/api/tasks/{id}` | Detail mit `lines` (Schritt-Verlauf) und `file_items` (Dateien wie `/api/files`) |
| PATCH | `/api/tasks/{id}` | Nur geplante: `title`, `prompt`, `model` (`null`/`"wie_scoop"` = wie Scoop), `scheduled_at` |
| DELETE | `/api/tasks/{id}` | Offene, geplante und (ab 1.40) archivierte (sonst 409) |
| POST | `/api/tasks/archive/clear` | Archiv leeren (ab 1.40): `{bot?}` → `{deleted}`; löscht archivierte Aufgaben endgültig samt Arbeitsordner, Ergebnisdateien bleiben in der Bibliothek. `GET /api/health` meldet `task_archive_cleanup: true` |
| POST | `/api/tasks/{id}/start` | Geplante sofort starten |
| POST | `/api/tasks/{id}/accept` | „Erledigt“: → Abgeschlossen |
| POST | `/api/tasks/{id}/rework` | „Nacharbeiten“ `{message}`: setzt fort, Abnahme zurückgesetzt |
| POST | `/api/tasks/{id}/archive` / `restore` | Archivieren / zurück (abgenommene → Abgeschlossen, sonst Zu prüfen) |

`POST /api/tasks/{id}/stop` und `/continue` wie in v1.19; `continue` setzt die Abnahme zurück, geplante Aufgaben → 400.
`POST /api/bots/{id}/tasks` nimmt zusätzlich `model` und `scheduled_at`. Zustandsfehler → 409, unbekannte Aufgabe → 404.

**Nachricht mit Aufgaben-Chip:** `POST /api/bots/{id}/messages` mit `text = "/aufgabe …"` nimmt optional
`task: {model?, scheduled_at?}` (Chip-Pillen „Termin“ und „Modell“ der App). Sie stehen in `meta.task_options` der
Nutzernachricht; der Text bleibt `/aufgabe …`.

**Ereignisse (WebSocket):** `task.updated` (Aufgabe wie oben, bei jeder Änderung) und `task.deleted` (`{id}`).

**Scoop-Werkzeuge:** `aufgabe_starten` mit optionalem `termin` (Berliner Zeit `JJJJ-MM-TTTHH:MM`), neu `aufgabe_abnehmen`.
Der Chat-Lauf kennt geplante und „Zu prüfen“-Aufgaben seines Chats und die Regeln, wann er eine Aufgabe startet. Nach
12 Werkzeug-/Bildschirmschritten in einem Chat-Lauf bekommt der Scoop einmal den Hinweis, den Rest als Aufgabe abzugeben.

## v1.27 – Arbeitsordner der Scoops

Ein Ordner auf dem Server-Mac, darin je Scoop ein Unterordner (`Dateien/`, `Aufgaben/<JJJJ-MM-TT Titel>/`). Details:
`docs/arbeitsordner.md`. Alle Endpunkte nur für den Admin (Gäste → 403).

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/settings/workspace` | Stand: `{path, absolute, default, is_default, exists, writable, icloud, error, scoops: [{id, name, folder, path, exists}], previous: [{path, absolute, folders}], browse_root}` |
| PATCH | `/api/settings/workspace` | `{path}` (absolut oder `~/…`): prüfen, anlegen, beschreibbar? → Stand wie GET; ungültig → 400 mit Text |
| GET | `/api/settings/workspace/browse?path=~` | Ordnerauswahl ohne Mac-Dialog: `{path, absolute, parent, name, dirs: [{name, path}], truncated}` – nur Ordner im Home-Ordner, keine versteckten |
| POST | `/api/settings/workspace/folder` | `{parent, name}`: Unterordner anlegen → Auflistung des neuen Ordners |

Die Mac-App „AIS Scoops Server“ setzt den Ordner lokal über `PATCH /api/setup/config` mit `workspace_dir`; `GET /api/setup`
liefert den Stand unter `server.workspace`. Hängt ein Zugriff (offene macOS-Datenschutz-Abfrage), antworten die Endpunkte
nach etwa 8 s mit 400 und einem Hinweis, statt zu warten.

## v1.29 – Rechner-Zugriff (Modus und Bereich)

Ausführlich: `docs/rechnerzugriff.md`.

- Bot-JSON (nur Admin): `computer_access: {mode: "ask"|"auto"|"full", scope: "workspace"|"projects"|"home",
  folders: ["~/…"], mode_label, scope_label}`. Ändern: `PATCH /api/bots/{id}` mit `computer_access` (Teiländerung;
  400 mit `error`-Text bei ungültigen Ordnern, Projektordner ohne Ordner usw.; Gäste 403).
- Aufgaben: `access: {scope, folders}` bei `POST /api/tasks`, `POST /api/bots/{id}/tasks`, `PATCH /api/tasks/{id}`
  (`{}` = wie Scoop) und in `task` der Nachricht (`/aufgabe …`). Antwort: `access: {mode, scope, folders, mode_label,
  scope_label, label, custom}`.
- Chat-Werkzeug `aufgabe_starten`: neuer Parameter `ordner` ('' = wie Scoop, 'arbeitsordner', 'überall',
  'projektordner' oder Pfade mit ';'), nie weiter als die Einstellung des Scoops.
- Freigabe-Karten aus Chat-Werkzeugen am Rechner: `meta.kind = "rechner"`; nach Freigabe führt der Server aus und
  meldet „Ausgeführt: …“.
- `GET /api/settings/workspace` und `GET /api/setup` (`server`): `full_disk_access: {granted: true|false|null,
  process, path, app, settings_url}`.

## v1.30 – KI-Abos (Claude Code / Codex mit Abo statt API-Schlüssel)

Ausführlich in [`docs/abos.md`](abos.md).

- `GET /api/settings/abos` (Admin): `{"claude": {label, mode, mode_label, configured, route, api_key, installed,
  logged_in, subscription, method, plan, account, limit, usage, login_command}, "openai": {…}, "modes": [{id, label}]}`.
  `mode`: `api` („API-Schlüssel“), `abo` („Abo“), `abo_api` („Abo, bei Limit API“).
- `PATCH /api/settings/abos` `{"claude": "abo_api", "openai": "api"}` → Status. Ungültig → 400.
- `POST /api/settings/abos/{claude|openai}/login` → öffnet auf dem Server-Mac den Login des Programms (Terminal)
  → `{started, command, status}`.
- Nur lokal für die Mac-App: `GET /api/setup/abos`, `GET /api/setup/abos/refresh`, `PATCH /api/setup/abos`,
  `POST /api/setup/abos/{provider}/login`; `GET /api/setup` → `server.abos`.
- `GET /api/usage` → zusätzlich `abo: {today_runs, month_runs, by_model: {model: {runs, input_tokens, output_tokens}}}`.
  Abo-Läufe haben keinen Betrag; `today_usd`/`month_usd` sind nur API-Kosten.
- Statuszeile: `meta.billing` (`abo`/`api`), `meta.abo_fallback` (Abo am Limit → API). Antwort: `meta.run_info.billing`,
  `meta.abo_session`. Ereignis mit `meta.abo_fallback` = Hinweis „Abo am Limit – weiter über den API-Schlüssel“.
- Aufgabe: Feld `billing` (`abo`/`api`) der laufenden Agent-Session.

## v1.31 – Nutzung und Verbrauch

- `GET /api/usage/details?range=24h|7d|30d|90d&source=all|scoops|other` und `GET /api/usage/limits?refresh=1` (Admin),
  Felder siehe [nutzung.md](nutzung.md). `GET /api/health` meldet `usage_details: true`. `/api/usage` unverändert.


## v1.32 – Freigabe-Knöpfe an Mitteilungen (iPhone, Mac, Apple Watch)

- Pushes zu Freigabe-Karten (`role = "approval"`) tragen `aps.category`: `SCOOP_APPROVAL` (Freigeben, Ablehnen) bzw.
  `SCOOP_APPROVAL_ALWAYS` (zusätzlich „Immer erlauben“, wenn `meta.can_always`). Logins speichern (`kind = "vault"`)
  braucht ein Passwort und bekommt keine Kategorie.
- Zusätzlich neben `aps`: `approval_id` und `approval_kind` (wie `meta.kind`). Die App entscheidet über
  `POST /api/approvals/{approval_id}` im Hintergrund. Andere Pushes bleiben unverändert.
- Apple-Watch-App: [`docs/watch.md`](watch.md).

## Ausgabenlimit und Demo-Server (ab 1.33.0)

- `spend_limits` in der Server-Konfiguration (`{"daily_usd": 5, "monthly_usd": 25}`): Ist ein Limit erreicht, startet kein
  Lauf. Der Scoop schreibt stattdessen ohne Modellaufruf eine Bot-Nachricht mit `meta.spend_limit = true`.
  Aufgaben-Endpunkte antworten dann mit dem Limit-Text als Fehler.
- Demo-Server (`"demo": true`, [demo-server.md](demo-server.md)): Endpunkte für Arbeitsordner, Abos, Einrichtung, Rechner
  koppeln, Apple, Apps verbinden, Tresor anlegen, Aufgaben starten, Transkription, Initiative und Teilen antworten mit
  `403 {"error": "Auf dem Demo-Server ausgeschaltet."}`.

## Modellkatalog (ab 1.34.0)

Welche Modelle Scoops nutzen dürfen, steht nicht mehr fest in Server und App, sondern im Modellkatalog
([modelle.md](modelle.md)). Neue Modelle kommen über die Fernkopie `models.json` ohne App-Build und ohne Server-Release.

- `GET /api/models` (Admin und Gäste mit Share): Katalog für die Apps.

  ```json
  {"version": 2026111801, "updated": "2026-11-18", "source": "bundled",
   "defaults": {"anthropic": {"model": "claude-haiku-5-5", "escalation": "claude-sonnet-5-5"},
                "openai": {"model": "gpt-6-luna", "escalation": "gpt-6.2-sol"}},
   "models": [{"id": "claude-fable-5-2", "label": "Fable 5.2", "provider": "anthropic",
               "hint": "Am stärksten, sehr teuer", "rank": 40,
               "price": {"input": 8.0, "output": 40.0, "cache_read": 0.2, "cache_write": 10.0},
               "routes": ["api", "claude_abo"], "features": ["fallback", "web_new"], "replaces": [],
               "deprecated": false, "selectable": true,
               "available": true, "routes_available": ["abo"]}],
   "replaced": {"gpt-6.1-sol": "gpt-6.2-sol", "gpt-6-astra": "gpt-6.2-astra"},
   "providers": {"anthropic": {"api": false, "abo": true}, "openai": {"api": true, "abo": false}}}
  ```

  - `source`: `bundled` (mit dem Server ausgeliefert), `cache` oder `remote` (Fernkopie). `version` wächst mit jeder
    Änderung.
  - `models`: wählbare (`selectable: true`, nach Anbieter und Rang) und abgelöste Modelle (`deprecated: true`, nur für
    Anzeigenamen alter Läufe und Kosten). Reine Preiseinträge für die Nutzungsseite fehlen hier.
  - `routes`: Wege, die das Modell kann (`api`, `claude_abo`, `chatgpt_abo`). Nur für den Admin: `available` und
    `routes_available` (`api` = Schlüssel hinterlegt, `abo` = Abo-Modus an und im Programm mit Abo angemeldet) sowie
    `providers`.
  - `replaced`: alte Kennung → Nachfolger. Der Server nimmt alte Kennungen in `POST/PATCH /api/bots` und
    `PATCH /api/routines/{id}` an und speichert den Nachfolger. Gespeicherte Scoops, Routinen und offene Aufgaben stellt
    er beim Start und nach jedem Katalogwechsel selbst um; die Kostenhistorie behält die alten Kennungen und Preise.
- WebSocket `models.updated` `{"version": …}`: Der Server hat einen neueren Katalog übernommen; Apps laden
  `GET /api/models` neu.
- `GET /api/health` meldet `models_catalog` (aktive Version). Ältere Server ohne `/api/models` antworten mit 404; die
  App nutzt dann ihre eingebaute Liste.
- Verstärkung (Werkzeug `eskalieren`): Claude-Scoops geben nur an ein stärkeres Claude-Modell ab (höherer `rank`),
  OpenAI-Scoops Schritt für Schritt an das nächststärkere wählbare OpenAI-Modell.

## Eigene MCP-Server (v1.35)

Vollständig in [mcp.md](mcp.md#api-v135): `GET/POST /api/mcp-servers`, `POST /api/mcp-servers/probe`,
`PATCH/DELETE /api/mcp-servers/{id}`, `POST /api/mcp-servers/{id}/login`, `POST /api/mcp-servers/{id}/test`;
`GET /api/connections` liefert zusätzlich `custom_mcp` und `custom_mcp_supported`. Rücksprung über
`POST /api/connections/oauth/callback` (`aisscoops://oauth/mcp…` bzw. `http://127.0.0.1:47615/oauth/mcp…`).
Freigabe-Karten mit sicherer Eingabe: `meta.secret_fields`, Entscheidung mit `edits.secrets` (Liste `[{key, value}]`
oder Objekt). Ereignis `meta.kind = mcp_login` öffnet die Anmeldung.

## App 1.3 (Server ab 1.39)

Neue Fähigkeiten für App 1.3 (Überblick: [neu-in-1.3.md](neu-in-1.3.md)). Ein Server meldet in `GET /api/health`, was er kann; fehlt ein Feld (älterer Server),
blendet die App die Funktion aus bzw. nimmt den bisherigen Weg. Gäste fragen `/api/health` nicht ab, für sie stehen die
Felder, die für Gäste gelten, in `GET /api/shared/me`.

| Feld in `/api/health` | Wert | Für Gäste (`/api/shared/me`) | App bei älterem Server |
|---|---|---|---|
| `search` | `true` | ja | sucht nur in geladenen Nachrichten |
| `message_edit` | `true` | ja | nur „Erneut senden …“ statt „Bearbeiten“ |
| `today` | `true` | – (nur Admin) | keine Seite „Heute“, Startansicht wie bisher |
| `mute` | `true` | ja | kein „Stummschalten“ (erkennt es auch am Feld `mute` im Scoop-JSON) |
| `quiet_hours` | `true` | ja | „Ruhezeiten“ ausgegraut („Server aktualisieren“) |
| `templates` | `1` (höchste lesbare Formatversion) | – (nur Admin) | kein Export und Import von Vorlagen |
| `images` | `{"supported", "available", "via", "hint"}` | – | nichts (Bilder kommen ohnehin als Dateien an) |
| `languages` | `["de", "en"]`, dazu `language` (wirksame Sprache der Anfrage) | ja | keine Sprachwahl für den Server, Texte deutsch |

- **Neue Routen für Gäste geteilter Scoops:** `GET /api/search`, `GET /api/chats/{chat_id}/messages/around/{mid}`,
  `PATCH /api/messages/{mid}`, `PUT /api/chats/{chat_id}/mute`, `GET`/`PATCH /api/settings/quiet-hours`.
  **Nur für den Admin:** `GET /api/today`, `GET /api/approvals`, `GET /api/bots/{id}/template`,
  `POST /api/templates/check`, `POST /api/templates/import` (Gäste: 403). Geprüft in `Server/tests/test_sharing.py`.
- **Neue WebSocket-Ereignisse:** `message.deleted` (`{"id", "bot_id"}`, Antwort nach dem Bearbeiten verworfen; auch an
  Gäste des Scoops) und `quiet_hours.updated` (gleiche Daten wie `GET /api/settings/quiet-hours`, an die Geräte der
  Person). Die App hält damit auch die Seite „Heute“ aktuell.
- **Systemintegration** (Teilen-Menü, Kurzbefehle, Controls, Spotlight, tiefe Links `aisbot://…`): keine neuen Routen
  und kein Health-Feld; sie nutzt die vorhandenen Endpunkte, siehe [`system.md`](system.md).

### Suche und Chat-Komfort

Ausführlich: [`docs/suche-chat.md`](suche-chat.md). Umsetzung: `Server/src/aisbot/suche.py`, `chat_edit.py`.

- **Fähigkeiten:** `GET /api/health` → zusätzlich `"search": true`, `"message_edit": true` (für Gäste dieselben Felder
  in `GET /api/shared/me`). Ohne die Felder sucht die App nur in geladenen Nachrichten und bearbeitet nicht.
- **Suche:** `GET /api/search?q=…&limit=30&chat=<chat_id>&before=<message_id>` →
  `{"query", "hits": [{"message_id", "chat_id", "chat_kind": "bot|group", "chat_name", "role", "author_id",
  "author_name", "created_at", "snippet", "marks": [[start, ende], …]}], "total", "truncated", "index"}`. Neueste zuerst,
  `limit` bis 200. Durchsucht `user`, `bot`, `event` und `approval` (Titel, Details) in Einzel- und Gruppenchats;
  Teilwörter („rechn“ findet „Rechnung“), Groß-/Kleinschreibung und Umlaute egal, Sonderzeichen ohne Fehler.
  Gäste: nur geteilte Scoops, keine Freigabe-Karten; `chat=<nicht geteilt>` → 403.
- **Zur Fundstelle:** `GET /api/chats/{chat_id}/messages/around/{message_id}?before=25&after=25` →
  `{"messages": [Message], "has_older", "has_newer"}`. `GET /api/bots/{id}/messages` und
  `/api/groups/{id}/messages` nehmen zusätzlich `after=<message_id>` (die nächsten Nachrichten, aufsteigend).
- **Bearbeiten:** `PATCH /api/messages/{message_id}` `{"text": "…"}` → `Message` mit
  `meta.edited = {"at", "mode": "replaced" | "corrected"}`. Nur die jüngste eigene Nachricht (sonst 409), Gäste ab
  Rolle „Schreiben“ nur eigene (403). `replaced`: Antwort auf die alte Fassung verworfen, der Scoop antwortet neu.
  `corrected`: Die alte Fassung hat schon etwas ausgelöst; nichts wird gelöscht, Ereignis „Nachricht bearbeitet“, der
  Scoop bekommt die Korrektur als neuen Auftrag.
- **Nachrichten:** Statuszeilen tragen `meta.effects` (bool: Der Lauf kann etwas bewirkt haben), Antworten
  `meta.run_info.effects`.
- **WebSocket:** neu `message.deleted` mit `{"id": "m_…", "bot_id": "<chat_id>"}` (auch an Gäste des Scoops).

### Seite „Heute“ und Freigaben-Postfach

Überblick über alle Scoops in einer Antwort und ein Postfach für offene Freigaben. Verhalten der App:
[`heute.md`](heute.md). Umsetzung: `Server/src/aisbot/today.py`, Tests: `Server/tests/test_today.py`. Beide Endpunkte nur
für den Admin (Gäste geteilter Scoops: 403); sie lesen nur.

- `GET /api/health` → zusätzlich `"today": true`. Fehlt das Feld (ältere Server), blendet die App die Seite aus.
- `GET /api/approvals` → `{"approvals": [Freigabe], "count": 3}`: offene Freigaben aus Einzelchats, Gruppen und
  Hintergrund-Aufgaben, neueste zuerst.

  ```json
  {"id": "a_1", "chat_id": "b_…|g_…", "bot_id": "b_…", "kind": "freigabe|mail|vault|call|t3|apple|scoop_update|…",
   "title": "Mail an Jonas senden", "created_at": "…", "expires_at": "…" | null,
   "task_id": "t_…" | null, "task_title": "Belege abgleichen" | null, "requested_by": "Lena" | null,
   "message": { Message }}
  ```
  - `bot_id` = Scoop, der fragt (in Gruppen der Akteur). `message` ist die vollständige Karten-Nachricht
    (`role: "approval"`, `meta.approval_id == id`), damit Apps dieselben Karten wie im Chat zeigen. Entschieden wird wie
    bisher über `POST /api/approvals/{id}`.
  - „Offen“ wie beim roten „?“ (`Bot.waiting`): Karte steht auf `pending` und ist jünger als 48 Stunden
    (`expires_at`); ältere gelten als liegengeblieben. Hält eine Aufgabe wegen der Karte an (`state = waiting`), gibt es
    keine Frist (`expires_at: null`). Karten, deren Chat, Scoop oder Nachricht es nicht mehr gibt, zählen nicht.
  - `requested_by`: Name des Gasts, aus dessen Lauf die Freigabe stammt (geteilter Scoop).
- `GET /api/today?since=<ISO-8601>` → alles für die Seite:

  ```json
  {"now": "…", "since": "…", "day_end": "…",
   "approvals": [Freigabe],
   "tasks": [Aufgabe],
   "running": [{"chat_id": "b_…|g_…", "bot_id": "b_…" | null, "run_id": "r_…", "message_id": "m_…",
                "line": "Öffnet Safari", "steps": 2, "started_at": "…", "uses_computer": true}],
   "planned": [{"id": "rt_…", "kind": "routine|erinnerung", "bot_id": "b_…", "chat_id": "b_…", "title": "Mail-Check",
                "at": "…", "schedule_text": "Stündlich", "more_today": 3}],
   "routines_done": [{"id": "rt_…", "kind": "routine|erinnerung", "bot_id": "b_…", "chat_id": "b_…",
                      "title": "Morgenbriefing", "at": "…"}],
   "counts": {"approvals": 3, "questions": 1, "waiting": 4, "review": 2, "running": 2, "planned": 3, "done": 5}}
  ```
  - `since` (Parameter): letzter Besuch der Seite. „Erledigt“ reicht mindestens 24 Stunden zurück; war der letzte
    Besuch länger her, bis dorthin, höchstens 7 Tage. Die Antwort nennt den wirksamen Beginn (`since`) und das Ende
    von „heute“ (`day_end`, Mitternacht Europe/Berlin).
  - `tasks`: Aufgaben wie im Board (`GET /api/tasks`), die die Seite braucht: in Arbeit (auch wartend, `column =
    "active"`), „Zu prüfen“ (`review`, höchstens 100), geplant mit Termin bis `day_end` (`planned`) und seit `since`
    abgeschlossen (`done`). Die App ordnet sie selbst zu und hält sie über `task.updated`/`task.deleted` aktuell.
    Rückfragen von Aufgaben (`state = "waiting"`, `waiting_kind = "frage"`) zählen zu „wartet auf dich“
    (`counts.questions`), Warten auf einen anderen Scoop (`waiting_kind = "scoop"`) nicht.
  - `running`: Chat-Läufe mit laufender Statuskarte (letzte Zeile in `line`); Hintergrund-Aufgaben stehen in `tasks`,
    stille Läufe (Initiative) erscheinen nicht. Stopp wie bisher: `POST /api/bots/{id}/stop` bzw.
    `POST /api/tasks/{id}/stop`.
  - `planned`: eingeschaltete Routinen und Erinnerungen mit nächstem Lauf bis `day_end`, nach Uhrzeit; `more_today` =
    weitere Läufe derselben Routine heute. `routines_done`: Routinen und Erinnerungen mit Lauf seit `since` (je
    Routine der letzte), neueste zuerst.
  - `counts.waiting` = `approvals` + `questions` (Zähler am Eintrag „Heute“).
- **Live:** keine neuen Ereignisse. Karten kommen und gehen über `message.created`/`message.updated` (`meta.state`),
  `bot.updated`/`group.updated` melden `waiting` und `busy`, dazu `task.updated`, `routine.updated`, `bot.deleted`,
  `group.deleted` und `message.deleted` (nach dem Bearbeiten verworfene Antwort, auch eine laufende Statuskarte).
  Freigaben stummer Chats stehen wie alle anderen im Postfach.
- **Verlauf leeren** (`POST /api/bots/{id}/reset`, `/api/groups/{id}/reset`) setzt offene Freigaben des Chats jetzt auf
  `declined` (ohne etwas auszuführen): Die Karten sind weg, also wartet dort nichts mehr (`waiting: false`).
### Stummschalten, Ruhezeiten und Scoop-Vorlagen

Vollständig in [ruhe.md](ruhe.md) und [vorlagen.md](vorlagen.md). Kurzfassung:

- **Stummschalten** (pro Chat und Person): Scoop- und Gruppen-JSON tragen `mute: {"muted": bool, "until": "<ISO>" | null}`
  (`until: null` bei `muted: true` = dauerhaft; Gäste sehen ihre eigene Stummschaltung). Ändern mit
  `PUT /api/chats/{chat_id}/mute` und `{"forever": true}`, `{"until": "<ISO>"}`, `{"minutes": 60}` bzw. `{}` zum
  Aufheben → `{"chat_id", "mute"}`. Inhaber für alle Chats, Gäste (ab Rolle Lesen) für geteilte Scoops. Aus stummen
  Chats schickt der Server keine Mitteilungen; Freigabe-Anfragen und Erinnerungen kommen trotzdem. Stumme Chats zählen
  nicht in `aps.badge`.
- **Ruhezeiten** (pro Person): `GET`/`PATCH /api/settings/quiet-hours` →
  `{"enabled", "start": "22:00", "end": "07:00", "days": [1…7], "approvals", "timezone": "Europe/Berlin", "active"}`.
  In der Ruhezeit tragen Mitteilungen `aps."interruption-level": "passive"` und keinen `sound` (Priorität 5).
  WebSocket: `quiet_hours.updated`. Erinnerungen tragen neben `aps` zusätzlich `"reminder": true`.
- **Scoop-Vorlagen** (nur Inhaber): `GET /api/bots/{id}/template`, `POST /api/templates/check`,
  `POST /api/templates/import`. Dateiformat `.scoop` mit `"format": 1`.
- **`GET /api/health`** meldet zusätzlich `"mute": true`, `"quiet_hours": true` und `"templates": 1` (höchste lesbare
  Formatversion). `GET /api/shared/me` meldet Gästen `"mute": true` und `"quiet_hours": true`.
- `PATCH /api/routines/{id}` mit `{"enabled": true}`: Ist der Termin einer Routine verstrichen, setzt der Server den
  nächsten Termin laut Zeitplan, statt sofort zu laufen (Erinnerungen unverändert).

### Bilder über das ChatGPT-Abo

Ausführlich in [`docs/bilder.md`](bilder.md). Keine neuen Endpunkte.

- `GET /api/health` → zusätzlich `"images": {"supported": true, "available": bool, "via": "chatgpt_abo", "hint": str|null}`.
  `available`: ChatGPT-Abo in Codex angemeldet (und nicht mit `images: false` abgeschaltet); `hint`: was der Nutzer tun
  kann („In den Einstellungen unter „KI-Abos“ ChatGPT verbinden …“). Ältere Server haben das Feld nicht.
- Fertige Bilder: Ereignis (`role = "event"`) mit `meta.file_id` (Bibliotheksdatei, `kind = "bild"`), `meta.icon = "photo"`,
  `meta.image = true`, Text „Bild erstellt: <Name>“ bzw. „Bild bearbeitet: <Name>“, in Aufgaben zusätzlich `meta.task_id`,
  in Gruppen `meta.author_id`. Die App zeigt Ereignisse mit Bilddatei ab 1.3 als Bildvorschau (ältere als Dateikarte).
- Statuszeile: „Erstellt ein Bild“ bzw. „Bearbeitet ein Bild“; Bildläufe stehen in `GET /api/usage` unter `abo`
  (Modell des Bildlaufs, ohne Betrag).
- Werkzeuge der Scoops: `bild_erstellen`, `bild_bearbeiten` (Chat und Aufgaben, nicht für Gäste).

### Sprache (Deutsch und Englisch)

Vollständig in [`sprache.md`](sprache.md) (Vertrag, Glossar, was die App selbst übersetzt). Umsetzung:
`Server/src/aisbot/i18n.py`, Tabellen in `Server/src/aisbot/i18n_en/`. Kurzfassung:

- **Pro Person** (Inhaber und jeder Gast getrennt): `GET`/`PATCH /api/settings/language` →
  `{"language": "en", "stored": "en" | null, "available": ["de", "en"], "default": "de"}`; `PATCH` mit
  `{"language": "de" | "en" | null}` (`null` = löschen), sonst 400. WebSocket `language.updated` an die Geräte der Person.
- **Rückfall:** Ohne gespeicherte Sprache gilt `Accept-Language` für die Antwort der jeweiligen Anfrage, sonst Deutsch;
  `?lang=` geht vor. Hintergrund (Routinen, Aufgaben, Initiative, Mitteilungen an den Inhaber) nimmt die gespeicherte
  Sprache des Inhabers, sonst Deutsch.
- **Einrichtung:** `/api/setup…` richtet sich nach `?lang=` bzw. `Accept-Language`; `PATCH /api/setup/config` nimmt
  `language` (Sprache des Inhabers), `GET /api/setup` meldet `server.language` und `server.languages`.
- **Fähigkeit:** `GET /api/health` und `GET /api/shared/me` → `"languages": ["de", "en"]`, `"language": "<wirksam>"`.
- **Gespeicherte Texte** (Ereigniszeilen, Statuszeilen, Karten, Board) entstehen in der Sprache des Inhabers, auch in
  Gruppen und geteilten Chats; alte Einträge bleiben. Feldnamen, Aufzählungswerte und IDs ändern sich nicht.
- **Start-Scoop:** Die Begrüßung trägt `meta.welcome = true` (sprachunabhängig, für die Einführung der App) und folgt
  der Sprache des Inhabers, solange niemand mit dem Start-Scoop geschrieben hat.
- **Modellkatalog:** Einträge dürfen `hint_en` haben; `/api/models` liefert `hint` in der Sprache der Anfrage.
