# AIS Scoops – Geteilte Scoops

Stand: 13.11.2026 · Konzept + Umsetzung Phase 1

## Idee

Ein Scoop gehört genau einer Person: dem **Admin**. Das ist die Person, die ihn erstellt hat. Er läuft auf
**ihrem Server**, mit **ihren API-Schlüsseln**, und arbeitet an **ihren Rechnern**. Der Admin kann den Scoop mit
anderen AIS-Scoops-Nutzern teilen. Diese sehen den Scoop in ihrer App unter **„Mit mir geteilt“** und arbeiten
mit ihm. Ihre App verbindet sich dafür direkt mit dem Server des Admins. Inhalte laufen nie über die Cloud.

## Rollen (pro geteilter Person und Scoop)

| Rolle | Chat lesen | Schreiben, Dateien senden, Sprechmodus | Scoop bearbeiten¹ | Teilen verwalten | Löschen |
|---|---|---|---|---|---|
| **Lesen** | ✓ | – | – | – | – |
| **Schreiben** (Standard) | ✓ | ✓ | – | – | – |
| **Bearbeiten** | ✓ | ✓ | ✓ | – | – |
| **Admin** (Ersteller, nicht übertragbar in Phase 1) | ✓ | ✓ | ✓ | ✓ | ✓ |

¹ „Bearbeiten“ bedeutet: Name, Rolle, Aussehen/Bild, Charakter, Stimme, Skills, Routinen, Gedächtnis-Einträge
ansehen und ändern. Modell, Werkzeug-Freigaben, Rechner-Zuordnung, Teilen und Löschen bleiben beim Admin.

## Rechner-Zugriff (pro geteilter Person, unabhängig von der Rolle)

| Stufe | Bedeutung |
|---|---|
| **Kein Zugriff** (Standard) | Live-Bildschirm und Rechner-Karten unsichtbar; Statuszeilen zeigen nur „arbeitet am Rechner“. |
| **Zusehen** | Live-Bildschirm des Rechners, an dem der Scoop arbeitet, ansehen (nur lesen). |
| **Steuern** | Zusehen und Übernehmen (Maus/Tastatur), wie der Admin. |

## Schutz des Admins

Ein geteilter Scoop arbeitet mit den Konten des Admins. Darum gilt:

- **Werkzeuge für Geteilte**: Der Admin legt pro geteiltem Scoop fest, welche Werkzeuge in Läufen genutzt werden
  dürfen, die von Gästen ausgelöst wurden. Zur Auswahl stehen Websuche, Rechner, verbundene Apps (Composio) pro
  App, MCPs (Atrium, Team App …), Telefon (Lucy) und Mails. **Standard: nur Websuche und Antworten.** Läufe des Admins
  selbst nutzen weiter alles.
- **Freigaben** (Mail senden, Anruf, Tresor, kritische Aktionen), die in Gast-Läufen entstehen, landen **immer beim
  Admin**. Gäste sehen nur „Wartet auf Freigabe durch <Admin>“.
- **Tresor** und **Passwörter** sind für Gäste nie sichtbar. Gast-Läufe bekommen keine Tresor-Werkzeuge.
- **Gedächtnis**: Der Scoop hat ein gemeinsames Gedächtnis. Die Systemanweisung sagt ihm, wer gerade schreibt
  (Name + Rolle), und dass er Privates des Admins nicht an Gäste weitergibt.
- **Budget**: Tageslimit pro Gast in $ (Standard 2 $), danach antwortet der Scoop dem Gast „Tageslimit erreicht“.

## Chat-Modell

Ein geteilter Scoop hat **einen gemeinsamen Chat**. Alle Berechtigten sehen alle Nachrichten. Jede Nachricht trägt
den Absender (Name, kleines Bild), wie in einer Gruppe. Läuft der Scoop schon, werden neue Nachrichten wie bisher
eingereiht.

## Einladen

1. Admin: Scoop-Profil → **Teilen** → **Person einladen** → Rolle + Rechner-Zugriff wählen → **Einladungslink**
   (`https://…/i/<code>` bzw. `aisscoops://invite/<code>`) teilen (Teilen-Sheet). Gültig 7 Tage, einmalig.
2. Gast tippt den Link an → AIS Scoops öffnet sich (Anmeldung mit Apple, falls nötig) → **„Annehmen“**.
3. Der Scoop erscheint beim Gast unter „Mit mir geteilt“, beim Admin in der Personenliste des Scoops.
   Admin kann Rolle und Rechner-Zugriff jederzeit ändern oder die Person entfernen. Gäste können selbst austreten.

## Architektur

### Convex (Verzeichnis, keine Inhalte)

- `shares`: `serverId`, `ownerId`, `botId` (Scoop-ID auf dem Server), `botName`, `botMascot` (kleines JSON für die
  Liste), `granteeId`, `role` (`read|write|edit`), `computer` (`none|view|control`), `createdAt`, `updatedAt`.
- `invites`: `code` (Hash gespeichert), `serverId`, `ownerId`, `botId`, `role`, `computer`, `expiresAt`, `usedBy?`.
- Admin-Funktionen (Sitzungs-JWT, nur Inhaber des Servers): `shares:createInvite`, `shares:listForBot`,
  `shares:update`, `shares:remove`, `shares:revokeInvite`.
- Gast-Funktionen: `shares:inviteInfo(code)` (Scoop-Name, Admin-Name, Rolle – ohne Login), `shares:accept(code)`,
  `shares:mine` (geteilte Scoops inkl. Server-URL + Online-Status), `shares:leave(shareId)`.
- Server-Endpunkt (serverSecret): `POST /shares/sync` → alle Shares dieses Servers (für den Server-Cache), der Herzschlag
  meldet zusätzlich eine `sharesVersion`, damit der Server bei Änderungen sofort neu lädt.
- Push-Relay: Ein Server darf zusätzlich an Geräte von Gästen senden, die einen Share auf diesem Server haben.

### Server (Python)

- **Principal pro Anfrage**: Das Bearer-Token ist (a) API-Token/Sitzungs-JWT des **Inhabers** → volle Rechte wie bisher,
  oder (b) Sitzungs-JWT eines **Gasts** (gültige Signatur, `sub` ≠ Inhaber) → Gast mit seinen Shares aus dem Cache.
- **Standard: verweigern.** Alle bisherigen Endpunkte bleiben für Gäste gesperrt (403). Für Gäste freigegeben werden nur
  ausdrücklich markierte Endpunkte, jeweils mit Prüfung von Scoop + Rolle: Scoop-Liste (nur geteilte), Nachrichten
  lesen/schreiben, Dateien des Chats, Reaktionen, Lesestatus, Scoop bearbeiten (Rolle edit, nur erlaubte Felder),
  Sprechmodus (write), Rechner-Status/Bildschirm/Übernehmen (nach Rechner-Stufe), Avatar lesen.
- **WebSocket** `/api/ws`: Gäste bekommen nur Ereignisse ihrer geteilten Scoops (Nachrichten, Laufstatus, Scoop-Änderungen);
  Rechner-Ereignisse nur mit Stufe view/control.
- **Läufe**: Nachrichten bekommen `author_user_id`/`author_name`. Gast-Läufe nutzen nur die freigegebenen Werkzeuge,
  Freigaben gehen an den Admin, Budget pro Gast. Pushes an alle Beteiligten (außer dem Absender).
- Scoop-JSON für den Admin: `shared: {count, members: [...]}`, `guest_tools: {...}`, `guest_budget`.

### App

- **Admin**: Scoop-Profil → Abschnitt **Teilen**: Personenliste (Name, Rolle, Rechner-Stufe, ändern/entfernen),
  **Person einladen** (Rolle, Rechner-Zugriff → Link teilen), offene Einladungen, **Werkzeuge für Geteilte**, Tageslimit.
- **Gast**: Seitenleiste-Abschnitt **„Mit mir geteilt“** mit den geteilten Scoops (Name, Admin, online/offline). Die App
  hält dafür neben dem eigenen Server weitere Verbindungen zu den Servern der Admins (je Server ein Client + WebSocket).
  Die Oberfläche passt sich der Rolle an: Lesen ohne Eingabefeld, Bearbeiten mit Profil-Bearbeitung, Rechner-Ansicht
  nach Stufe. Hinweis „Läuft bei <Admin>“ im Profil.
- **Einladungslink** öffnen → Annahme-Blatt (Scoop-Vorschau, Admin, Rolle) → Annehmen.
- Eigene Nachrichten rechts, die anderer Personen links mit Name/Bild.

## Phasen

- **Phase 1 (jetzt):** Rollen, Rechner-Stufen, Einladen per Link, „Mit mir geteilt“, gemeinsamer Chat, Server-Scoping
  (Standard verweigern), Werkzeug-Freigaben für Geteilte, Freigaben beim Admin, Tageslimit, Push an Gäste.
- **Phase 2:** Admin-Rolle übertragen, private Verläufe pro Person, Live-Aktivität für Gäste, geteilte Gruppen.

## Ist-Stand Phase 1 (Backend: Convex + Server 1.14.0)

> **Status:** Backend fertig. Convex ist in Dev und Prod deployt, Armans Server läuft mit 1.14.0. Dieser Abschnitt ist
> die verbindliche Schnittstelle für die App.
> Änderungen werden hier nachgetragen; Datum/Uhrzeit der letzten Änderung steht in der nächsten Zeile.
>
> Letzte Änderung: 13.11.2026, abends – Server umgesetzt, alle Tests grün, deployt.

### Entscheidung: Wer verwaltet Einladungen/Shares?

Die App spricht **direkt mit Convex** (Sitzungs-JWT, wie bei `servers:*`). Der Server ist kein Proxy: Er kennt
die Shares nur aus seinem Cache (`/shares/sync`). Begründung: Convex ist ohnehin die Quelle der Wahrheit, prüft die
Server-Inhaberschaft selbst und funktioniert auch, wenn der Server gerade offline ist. Damit Änderungen sofort am
Server wirken, ruft die Admin-App danach `POST /api/shares/refresh` am eigenen Server auf (sonst spätestens nach
dem nächsten Herzschlag, ≤ 60 s).

Werkzeuge für Geteilte und Tageslimit sind **Server-Einstellungen** (pro Scoop), weil sie Läufe auf dem Server betreffen.

### Begriffe und Werte

- **Rolle** `role`: `read` < `write` < `edit` (Admin ist der Inhaber des Servers, kein Wert in Shares).
- **Rechner-Stufe** `computer`: `none` < `view` < `control`.
- Zeitstempel in Convex: Millisekunden seit 1970. Am Server: ISO-Text wie bisher.

### Convex-Funktionen (App, Sitzungs-JWT)

Aufruf wie in docs/accounts.md: `POST <cloud>/api/query|mutation|action`, `{"path", "args", "format": "json"}`.
Mutations/Actions werfen bei fachlichen Fehlern **nicht**, sondern liefern `{"ok": false, "error": "<code>", "message": "<Text>"}`.
Ohne Anmeldung werfen alle (außer `inviteInfo`) `ConvexError {code: "unauthenticated"}`.

| Pfad | Art | Wer | Argumente | Rückgabe |
|---|---|---|---|---|
| `shares:createInvite` | **action** | Admin | `{"serverId", "botId": "b_…", "botName", "botMascot"?: {…≤2 KB}, "role"?: "write", "computer"?: "none"}` | `{"ok": true, "inviteId", "code", "url": "https://<site>/i/<code>", "appUrl": "aisscoops://invite/<code>", "expiresAt", "role", "computer"}` · Fehler `not_owner`, `bad_request`, `too_many_invites` (20 offene/Scoop), `too_many_shares` (50/Scoop), `rate_limited` (30/h) |
| `shares:listForBot` | query | Admin | `{"serverId", "botId"}` | `{"members": [{"shareId", "userId", "name", "role", "computer", "createdAt", "updatedAt"}], "invites": [{"inviteId", "role", "computer", "createdAt", "expiresAt"}]}` (offene Einladungen ohne Code); Nicht-Admin → wirft `forbidden` |
| `shares:listForServer` | query | Admin | `{"serverId"}` | `[{"botId", "count"}]` (für „geteilt“-Kennzeichen) |
| `shares:update` | mutation | Admin | `{"shareId", "role"?, "computer"?}` | `{"ok": true}` / `not_found` |
| `shares:remove` | mutation | Admin | `{"shareId"}` | `{"ok": true}` / `not_found` |
| `shares:revokeInvite` | mutation | Admin | `{"inviteId"}` | `{"ok": true}` / `not_found` |
| `shares:inviteInfo` | query | **jeder, ohne Login** | `{"code"}` (Code, ganzer https-Link oder `aisscoops://invite/…`) | `{"valid": true, "botId", "botName", "botMascot", "ownerName", "serverName", "role", "computer", "expiresAt"}` oder `{"valid": false, "reason": "unknown" \| "used" \| "expired"}` |
| `shares:accept` | mutation | Gast | `{"code"}` (wie oben) | `{"ok": true, "shareId", "serverId", "botId", "already": bool}` · Fehler `invalid_code`, `used`, `expired`, `own_scoop`, `rate_limited` (10 Fehlversuche/10 Min.) |
| `shares:mine` | query | Gast | `{}` | `[{"shareId", "serverId", "botId", "botName", "botMascot", "role", "computer", "ownerId", "ownerName", "serverName", "publicUrl", "tailnetUrl", "version", "online", "lastSeenAt", "createdAt"}]` |
| `shares:leave` | mutation | Gast | `{"shareId"}` | `{"ok": true}` / `not_found` |

- Admin = **aktueller Inhaber des Servers** (`servers.ownerId`), geprüft bei jedem Aufruf.
- Einladungscode: 22 Zeichen `[A-Za-z0-9_-]` (128 Bit), nur SHA-256 gespeichert, 7 Tage gültig, **einmalig**. Ein
  entfernter Gast kommt mit demselben Link nicht zurück (`used`). Eine zweite Einladung an denselben Gast
  aktualisiert dessen Share (Rolle/Rechner), statt ihn zu verdoppeln.
- **https-Einladungslink**: `GET https://<site>/i/<code>` liefert eine kleine Seite, die sofort `aisscoops://invite/<code>`
  öffnet (Knopf „In AIS Scoops öffnen“). Die App muss das URL-Schema **`aisscoops`** (zusätzlich zu `aisbot`)
  registrieren und `aisscoops://invite/<code>` öffnen. (Universal Links sind noch nicht eingerichtet.)
- Server entfernen (`servers:removeServer`) löscht alle Shares und Einladungen des Servers; Konto löschen
  (`users:deleteAccount`) löscht zusätzlich alle Shares, in denen das Konto Gast ist.

### Convex-HTTP für den Server (Bearer serverSecret)

- `POST <site>/shares/sync` `{"bots"?: [{"botId", "name", "mascot"?}], "removeBots"?: ["b_…"]}`
  → `{"ok": true, "sharesVersion": 3, "shares": [{"shareId", "botId", "granteeId", "granteeName", "role", "computer", "createdAt", "updatedAt"}]}`.
  `bots` hält Name/Maskottchen in „Mit mir geteilt“ aktuell, `removeBots` (gelöschte Scoops) entfernt deren Shares.
- `POST <site>/servers/heartbeat` liefert zusätzlich `"sharesVersion"`; `revokedSessions` enthält auch abgemeldete
  Sitzungen der Gäste mit Share auf diesem Server.
- Push-Relay: `POST /push/register` akzeptiert je Eintrag `"userId"` (Gast). Ohne Share auf diesem Server →
  `rejected: [{token, reason: "NotShared"}]`. `/push/send` erlaubt Tokens des Inhabers **und** von Gästen, solange
  sie einen Share auf diesem Server haben (danach `403 UnknownToken`).

### Server (Python 1.14.0): Gäste

**Anmeldung:** Gast-Apps schicken ihr eigenes Sitzungs-JWT (`Authorization: Bearer …` bzw. `?token=` am WebSocket)
an die `publicUrl` aus `shares:mine`. Der Server unterscheidet:
- API-Token oder Sitzungs-JWT des Inhabers → **Admin**, alles wie bisher.
- gültiges Sitzungs-JWT eines anderen Kontos → **Gast**. Ohne passenden Share **403** `{"error": "…"}` (nicht 401!).
  401 heißt weiterhin: Token ungültig/abgelaufen/abgemeldet → JWT erneuern.

**Standard verweigern:** Alle Endpunkte, die nicht in der folgenden Tabelle stehen, antworten Gästen mit 403.
Dieselben Pfade und JSON-Formate wie beim Admin, damit die App ihren Client wiederverwenden kann.

| Endpunkt | Mindestens | Hinweise |
|---|---|---|
| `GET /api/shared/me` | 1 Share | `{"role": "guest", "user_id", "name", "server_name", "owner_name", "version", "shares": [{"bot_id", "share_id", "role", "computer"}]}` (Admin: `{"role": "owner", …, "shares": []}`). Lädt bei leerem Cache einmal neu (frisch angenommen). |
| `GET /api/bots` | 1 Share | nur geteilte Scoops (Gast-Ansicht, s. u.) |
| `GET /api/bots/{id}` | read | |
| `PATCH /api/bots/{id}` | edit | nur `name`, `label`, `mascot`, `character`, `voice`; jedes andere Feld → 403 |
| `GET /api/bots/{id}/messages` | read | Gast-Ansicht der Nachrichten (s. u.) |
| `POST /api/bots/{id}/messages` | write | `file_ids` nur aus diesem Chat |
| `POST /api/bots/{id}/stop` | write | |
| `POST /api/bots/{id}/read` | read | Lesestatus **pro Gast** (ändert nicht den des Admins) |
| `PUT /api/messages/{mid}/reaction` | write | Reaktion des Gasts steht in `meta.reactions["user:<userId>"]` (Admin weiter `"user"`) |
| `GET /api/chats/{id}/files`, `GET /api/files/{fid}` | read | nur Dateien dieses Chats |
| `POST /api/chats/{id}/files?name=` | write | |
| `DELETE /api/files/{fid}` | edit | |
| `GET /api/bots/{id}/avatar` | read | |
| `PUT`/`DELETE /api/bots/{id}/avatar` | edit | |
| `GET /api/bots/{id}/memories`, `DELETE /api/memories/{mid}` | edit | nur Einträge dieses Scoops (keine „für alle Scoops“) |
| `GET /api/bots/{id}/routines`, `PATCH`/`DELETE /api/routines/{rid}` | edit | Routine jetzt ausführen bleibt beim Admin |
| `GET /api/bots/{id}/skills`, `PATCH`/`DELETE /api/skills/{sid}` | edit | nur Fähigkeiten dieses Scoops |
| `GET /api/bots/{id}/usage` | read | nur eigene Zeile + eigenes Limit (s. u.) |
| `POST /api/transcribe?bot=<id>` | write | Diktat; höchstens 100 pro Gast und Tag |
| `GET /api/voice/live?bot=<id>`, `POST /api/voice/live/preview?bot=<id>` | write | Gäste müssen `bot` mitschicken |
| WebSocket `/api/voice/live?chat=<id>&token=` | write | Sprechmodus; Dauer begrenzt durch das Tageslimit, Kosten zählen zum Gast |
| `GET /api/computer?bot=<id>`, `GET /api/computer/screen.jpg?bot=<id>` | Rechner `view` | Rechner = der des Scoops; ein abweichendes `node=` → 403 |
| `POST /api/computer/takeover|release|input?bot=<id>` | Rechner `control` | |
| `POST /api/shared/devices` | 1 Share | `{"apns_token", "platform": "ios"|"macos", "name"?}` → `{"ok": true, "push_enabled"}`. Getrennt von `/api/devices` (Admin). |
| `DELETE /api/shared/devices` | 1 Share | `{"apns_token"}` → `{"ok": true}` (z. B. beim Austreten/Abmelden) |
| WebSocket `/api/ws?token=` | 1 Share | gefiltert, s. u. |

Freigaben entscheiden (`POST /api/approvals/…`), Scoop löschen/zurücksetzen, Gruppen, Tresor, Apps, Rechner-
Verwaltung, Einstellungen, Live-Aktivitäten, `/api/health`, `/api/usage` u. a. bleiben **nur Admin**.

**Gast-Ansicht eines Scoops:** `{"id", "name", "label", "mascot", "avatar", "character", "voice", "created_at", "busy",
"unread" (pro Gast), "last_message", "pinned": false, "section": null, "primary": false,
"computer_node" (nur bei Rechner view/control), "access": {"share_id", "role", "computer", "owner_id", "owner_name", "server_name"}}`.
Kein `model`, keine Teilen-Daten, keine Werkzeug-Freigaben.

**Gast-Ansicht der Nachrichten:** wie beim Admin, aber
- Freigabe-Karten (`role: "approval"`): `text: ""`, `meta: {"state", "title": "Wartet auf Freigabe durch <Admin>" | "Freigegeben durch <Admin>" | "Abgelehnt durch <Admin>", "details": "", "guest_view": true}` – keine Mail-Entwürfe, kein Tresor.
- Ereignisse ohne `meta.prompt`/`url`; Statuszeilen bei Rechner-Stufe `none` mit `lines: ["Arbeitet am Rechner"]`.

**Absender an Nachrichten** (alle Nutzer-Nachrichten, auch beim Admin, sobald der Server gekoppelt ist):
`meta.author_user_id` (Konto-ID), `meta.author_name`, `meta.author_role` (`admin` | `read` | `write` | `edit`).
Fehlt `author_user_id` (ältere Nachrichten), stammt sie vom Admin. Eigene Nachricht = `author_user_id` == eigene Konto-ID.

**WebSocket für Gäste:** nur Ereignisse geteilter Scoops: `message.created`/`message.updated` (Gast-Ansicht),
`bot.updated` (Gast-Ansicht), `bot.deleted`, `bot.typing`; `routine.updated`/`skill.updated` nur mit Rolle edit;
`computer.updated`/`node.updated` nur mit Rechner view/control und nur für den Rechner des Scoops.
Neu: `share.updated` `{"shares": [{"bot_id", "share_id", "role", "computer"}]}`, wenn sich Rechte ändern; verliert der
Gast den letzten Share, schließt der Server die Verbindung mit Code **4403**.

**Push an Gäste:** Antworten des Scoops und Nachrichten anderer Personen im geteilten Chat gehen an alle Beteiligten
außer dem Absender. Gast-Mitteilungen tragen kein `aps.badge` und zusätzlich
`{"shared": true, "server_id": "<Convex-Server-ID>", "owner_id", "bot_id", "chat_id", "message_id", "author_name"}`.
Freigabe-Anfragen gehen nur an den Admin.

### Server: Admin

- Scoop-JSON (Admin) zusätzlich: `"shared": {"count": 1, "members": [{"share_id", "user_id", "name", "role", "computer"}]}`,
  `"guest_tools": {"web": true, "computer": false, "apps": ["gmail", …], "mcp": ["atrium", …], "phone": false, "mail": false}`,
  `"guest_budget": 2.0` (US-$ pro Gast und Tag).
- `PATCH /api/bots/{id}` akzeptiert zusätzlich `guest_tools` (Teilobjekt, unbekannte Schlüssel fallen weg) und `guest_budget` (0–100).
- `GET /api/bots/{id}/sharing` → `{"guest_tools", "guest_budget", "members": […], "options": {"apps": [{"id": "gmail", "name": "Gmail"}],
  "mcp": [{"id": "atrium", "name": "Atrium"}], "phone": bool, "mail": bool, "computer": true, "web": true}}` (Auswahl für „Werkzeuge für Geteilte“).
- `POST /api/shares/refresh` → `{"ok": true, "shares": <Anzahl>}`: nach jeder Änderung über Convex aufrufen, dann wirkt sie sofort.
- **Kosten:** `GET /api/usage` zusätzlich `"by_bot": {"<bot_id>": {"today_usd", "month_usd"}}`.
  `GET /api/bots/{id}/usage` → `{"bot_id", "today_usd", "month_usd", "total_usd", "guest_budget",
  "by_person": [{"user_id": null, "name": "Arman", "is_owner": true, "today_usd", "month_usd"},
  {"user_id": "j97…", "name": "Lena", "role": "write", "today_usd", "month_usd", "budget_left_usd"}]}`
  (Gast: nur eigene Zeile, Summen nur seiner Kosten). Zeitraum heute/Monat in Serverzeit (Europe/Berlin), Sprechmodus zählt mit.

### Server: Läufe für Gäste

- Ein Lauf gilt als **Gast-Lauf**, wenn seit der letzten Antwort des Scoops eine Gast-Nachricht im Chat steht (oder er die
  Fortsetzung einer Freigabe aus einem Gast-Lauf ist). Dann: nur „Werkzeuge für Geteilte“ (Standard: Websuche und
  Antworten), nie Tresor/Logins, keine Routinen anlegen, keine anderen Scoops anschreiben, kein T3; Dateien nur aus diesem Chat.
- Freigaben aus Gast-Läufen landen beim Admin (`meta.requested_by: {"user_id", "name"}` in der Admin-Ansicht).
- Tageslimit: Ist das Budget des Gasts aufgebraucht, antwortet der Scoop ohne KI-Aufruf
  „Tageslimit erreicht …“; sonst ist das Laufbudget höchstens der Rest.
- Systemanweisung: nennt Admin, geteilte Personen mit Rolle und den aktuellen Absender; Privates des Admins nicht an Gäste.

### Sicherheitsmodell (Umsetzung)

- `server.py`: `principal_of(token)` → `OWNER` | Gast-`Principal(user_id, sid)` | `None`. Die Abhängigkeit `auth` (alle
  bisherigen Endpunkte) lässt **nur den Inhaber** durch: Gäste → 403, kein/ungültiges Token → 401. Für Gäste freigegeben ist
  ein Endpunkt nur, wenn er statt `auth` die Abhängigkeit `shared(role, computer, via)` hat. Sie leitet den Scoop zentral ab
  (`BOT_OF`: Pfad, `?bot=`, Nachricht, Datei, Gedächtnis, Routine, Fähigkeit) und prüft den Share aus dem Cache.
  Gruppen-Chats (`g_…`) sind nie teilbar.
- Abgemeldete Sitzungen (auch die von Gästen) kommen mit dem Herzschlag und werden sofort abgelehnt (401).
- Share-Cache (`sharing.ShareCache`): Er lädt neu bei neuer `sharesVersion` im Herzschlag (≤ 60 s), bei
  `POST /api/shares/refresh` sofort, und gedrosselt (alle 5 s), wenn ein Gast etwas anfragt, das der Cache noch
  nicht kennt. Ohne Kopplung ist er leer, dann gibt es keine Gäste. Ist Convex nicht erreichbar, bleibt der letzte
  Stand gültig; nach einem Neustart gibt es bis zum ersten Abgleich keine Gäste.
- Gast-Läufe: `sharing.guest_tool_names` (eigene Werkzeuge), `ScopedMCP` (MCP-Server bzw. Composio-Apps; bei
  Composio nur Suche/Schemas/Ausführen geprüfter Slugs, kein Workbench), Engine-Schalter `allow_computer`/`allow_web`,
  kein Tresor und keine Konten im Prompt (außer bei freigegebenen Apps oder Mails), Laufbudget ≤ Rest des Tageslimits.

### Tests

- `cd Cloud && npm test`: 64 Tests, davon 21 in `tests/shares.test.ts`. Abgedeckt: Einladen, Annehmen (einmalig,
  eigener Scoop, abgelaufen, Rate-Limit), Admin-Rechte über die Server-Inhaberschaft, Gäste nur eigene Shares,
  `/shares/sync`, Herzschlag mit `sharesVersion` und Gast-Sitzungen, Server entfernen und Konto löschen räumen auf,
  Push-Relay für Gast-Geräte.
- `cd Server && uv run python tests/test_sharing.py`: 110 Prüfungen, davon 94 mit Fake-Convex und 16 gegen Convex-Dev.
  - Alle 81 HTTP-Routen werden systematisch durchlaufen: Ein Gast ohne Share bekommt überall 403. Jede Rolle und
    Rechner-Stufe bekommt genau die freigegebenen Routen, auf einem fremden Scoop überall 403.
  - Außerdem: Lesen ≠ Schreiben ≠ Bearbeiten, Rechner-Stufen, WS-Filter (Freigaben, Statuszeilen, Gruppen),
    Gast-Lauf ohne Werkzeuge, Freigabe beim Admin samt eingeschränkter Fortsetzung, Tageslimit, Lesestatus,
    Reaktionen, fremde Dateien, Push an Gäste ohne Badge.
  - Share entfernen wirkt nach dem Herzschlag sofort (WS 4403, REST 403); eine abgemeldete Gast-Sitzung bekommt 401.
- Bestehende Server-Tests bleiben grün. `test_cloud.py` erwartet für „anderes Konto“ jetzt 403 (Gast) statt 401.

### Dateien

Convex: `Cloud/convex/shares.ts` (neu), `Cloud/convex/lib/shares.ts` (neu), `schema.ts`, `http.ts` (`/shares/sync`, `/i/<code>`),
`push.ts`, `claims.ts`, `lib/session.ts`, `users.ts`, `crons.ts`, `tests/shares.test.ts` (neu).
Server: `sharing.py` (neu), `server.py`, `bots.py`, `push.py`, `cloud.py`, `db.py` (Migrationen `bots.sharing`, `usage.user_id`,
`approvals.guest_user_id`, Tabellen `guest_devices`, `guest_reads`), `engine.py`, `engine_openai.py`, `live_voice.py`,
`version.py`, `tests/test_sharing.py` (neu).

### Offen (Phase 1 → später)

- Ein Gast kann Routinen des Admins ein- und ausschalten (Rolle Bearbeiten). Routinen laufen danach als Läufe des Admins.
- Gesprochene Beiträge des Admins im Sprechmodus gehen auch als Push an die Gäste.
- Gast-Tokens meldet der Server bei Convex an (wie beim Admin). Stärker wäre, wenn die App sie selbst meldet.
- Universal Links für `https://<site>/i/<code>` sind nicht eingerichtet; die Seite öffnet das URL-Schema.
- Nach einem Server-Neustart sind Gäste bis zum ersten Herzschlag (wenige Sekunden) gesperrt.
