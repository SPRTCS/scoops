# AIS Scoops – Benutzerkonten (Produkt-Grundlage)

Stand: 13.11.2026 · Phase 1, Phase 2, Push-Relay

## Ziel

AIS Scoops soll langfristig ein Produkt für Dritte werden. Jede Kundin, jeder Kunde betreibt **einen eigenen Server**
auf dem eigenen Mac, mit **eigenen API-Schlüsseln** (Anthropic/OpenAI, Composio …). Ein zentraler Dienst auf
**Convex** kennt nur Konten, Geräte und Server – **keine Chats, keine Schlüssel, keine Inhalte**.

Anmeldung: **Mit Apple anmelden** (iOS, iPadOS, macOS).

Armans heutiger Server ist der erste Server des ersten Kontos; bestehende Kopplungen (API-Token) laufen weiter.

## Bausteine

```
 App (iPhone/iPad/Mac) ──Sign in with Apple──▶ Convex (Konten, Server-Verzeichnis)
        │                                              ▲
        │  Sitzungs-JWT (von Convex signiert)           │ Registrierung, Herzschlag (URL, Version, online)
        ▼                                              │
 Eigener AIS-Scoops-Server (Mac des Kunden) ───────────┘
   prüft das JWT selbst (JWKS von Convex): Inhaber = angemeldeter Nutzer
```

### Convex (neues Projekt `ais-scoops`, Ordner `Cloud/` im Repo)

- **Tabellen**
  - `users`: appleSub (eindeutig), email?, name?, createdAt, lastLoginAt
  - `servers`: ownerId, name, publicUrl, tailnetUrl?, version, lastSeenAt, secretHash, createdAt
  - `serverClaims`: code (8 Zeichen, wie Scoops Connect), serverId?, ownerId?, expiresAt, status (`pending`/`claimed`)
  - `sessions`: userId, deviceName, platform, createdAt, lastUsedAt, revokedAt?
- **Anmeldung (HTTP-Action `POST /auth/apple`)**: App schickt Apples `identityToken` (+ `authorizationCode`, Name/E-Mail beim ersten Mal). Convex prüft das Token gegen Apples JWKS (`https://appleid.apple.com/auth/keys`, `aud` = `com.ais.aisbot`, `iss` = `https://appleid.apple.com`), legt den Nutzer an/aktualisiert ihn und gibt ein **eigenes Sitzungs-JWT** zurück (RS256, Lebensdauer 30 Tage, `sub` = userId, `sid` = sessionId) plus Refresh-Mechanismus (`POST /auth/refresh`).
- **JWKS** unter `GET /.well-known/jwks.json` (HTTP-Route); `auth.config.ts` nutzt denselben Schlüssel als `customJwt`-Provider, damit Queries/Mutations `ctx.auth` haben.
- **Server koppeln (wie ein TV-Code)**:
  1. Server ruft `POST /servers/claim/start` → `{code, claimId}`; zeigt den Code an (Kommandozeile/Log und `GET /api/setup` lokal).
  2. Nutzer gibt den Code in der App ein → Mutation `claimServer(code)` verknüpft mit seinem Konto.
  3. Server pollt `POST /servers/claim/poll` → bekommt `serverId` + `serverSecret` (einmalig, nur Hash gespeichert).
- **Herzschlag**: Server `POST /servers/heartbeat` (Bearer serverSecret) alle 60 s mit `publicUrl`, `version`.
- **App-Queries**: `myServers` (Name, URL, online = lastSeen < 3 min, Version), `renameServer`, `removeServer`, `mySessions`, `revokeSession`, `deleteAccount` (App-Store-Pflicht).

### Server (Python, bestehend)

- Neues Modul `cloud.py`: Kopplung starten/abschließen, `serverSecret` im Schlüsselbund (`ais-bot-cloud`/`server-secret`), Herzschlag im Planer, Convex-URL in `config.json` (`cloud_url`).
- **Auth erweitern**: Neben dem bisherigen API-Token wird ein **Convex-Sitzungs-JWT** akzeptiert, wenn Signatur (JWKS, zwischengespeichert) stimmt, nicht abgelaufen und `sub` == Inhaber des Servers (`owner_id` aus der Kopplung). Gilt für REST und WebSockets.
- `GET /api/setup` (nur von 127.0.0.1): Kopplungsstatus und Code für die Einrichtung.
- Keine Inhalte zu Convex. Nur Name, URL, Version, Online-Status.

### App (SwiftUI)

- **Anmelde-Bildschirm** vor dem bisherigen Verbinden: „Mit Apple anmelden“ (AuthenticationServices). Sitzungs-JWT im Schlüsselbund, automatisches Erneuern.
- **Server-Auswahl**: Liste „Deine Server“ aus Convex (online/offline, Version). Tippen verbindet mit `publicUrl` und Sitzungs-JWT statt API-Token. „Server hinzufügen“ → Code-Eingabe (Kopplung) + kurze Anleitung.
- **Konto** in den Einstellungen: Name/E-Mail, Geräte (Sitzungen) mit Abmelden, Konto löschen.
- **Übergang**: Bestehende Kopplung per API-Token bleibt als „Erweitert → Manuell verbinden“ erhalten.
- Capability „Sign in with Apple“ für `com.ais.aisbot` (iOS/macOS).

## Später (nicht Phase 1)

- ~~**Server zum Installieren** für Kunden~~ → umgesetzt in Phase 2 (siehe unten).
- **Erreichbarkeit ohne Tailscale** für Kunden: eigener Relay-Dienst (wie T3 Connect) oder Cloudflare Tunnel pro Server.
- **Abo/Lizenz** (StoreKit), Developer-ID + Notarisierung für Scoops Connect/Server, Datenschutzerklärung, App-Store-Freigabe.

## Ist-Stand Phase 1 (Backend, 13.11.2026)

Convex-Projekt **`ais-scoops`** (Team `arman-samary`, Region EU/Irland), Code in `Cloud/` (siehe `Cloud/README.md`).

| | Funktionen (Queries/Mutations) | HTTP-Actions |
|---|---|---|
| **Produktion** | `https://helpful-puma-445.eu-west-1.convex.cloud` | `https://helpful-puma-445.eu-west-1.convex.site` |
| Dev (Tests) | `https://merry-vole-238.eu-west-1.convex.cloud` | `https://merry-vole-238.eu-west-1.convex.site` |

Die App setzt `CloudConfig.defaultCloudURL = "https://helpful-puma-445.eu-west-1.convex.cloud"`; `.convex.cloud → .convex.site` ergibt die HTTP-Adresse.
Alle Zeitstempel sind **Millisekunden seit 1970** (Zahl). IDs sind Convex-IDs (Text).
Fehler der HTTP-Actions: Status ≠ 200, Körper `{"error": "<lesbarer deutscher Text>", "code": "<maschinenlesbar>"}`.

### Sitzungs-JWT

RS256, Header `kid`, Lebensdauer 30 Tage. Claims: `iss` = HTTP-Adresse (`https://helpful-puma-445.eu-west-1.convex.site`),
`aud` = `"ais-scoops"`, `sub` = Nutzer-ID, `sid` = Sitzungs-ID, `iat`, `exp`.
Öffentliche Schlüssel: `GET <site>/.well-known/jwks.json` → `{"keys": [{"kty":"RSA","n":…,"e":"AQAB","kid":…,"alg":"RS256","use":"sig"}]}`.
Der private Schlüssel liegt nur als Convex-Umgebungsvariable `SESSION_PRIVATE_KEY` im jeweiligen Deployment (dev und prod haben verschiedene Schlüssel).

### `POST <site>/auth/apple`

```json
{"identityToken": "<Apple-JWT>", "authorizationCode": "…", "nonce": "<roher Nonce, optional>",
 "fullName": "Arman Samary", "givenName": "Arman", "familyName": "Samary", "email": "…",
 "deviceName": "iPhone von Arman", "platform": "ios|ipados|macos|visionos"}
```
Pflicht ist nur `identityToken`. Geprüft: Signatur gegen `https://appleid.apple.com/auth/keys`, `iss` = `https://appleid.apple.com`,
`aud` = `com.ais.aisbot` (iOS und macOS; weitere per Umgebungsvariable `APPLE_AUDIENCES`), `exp` (60 s Toleranz).
Wird `nonce` mitgeschickt, muss das Token-Feld `nonce` dem rohen Wert oder dessen SHA-256 (hex) entsprechen.
Name: `fullName`, sonst `givenName + familyName` (Apple liefert ihn nur beim ersten Mal; vorhandene Namen werden nie überschrieben).
E-Mail: aus dem Token, sonst aus `email`. `authorizationCode` wird derzeit nicht ausgewertet.

Antwort 200:
```json
{"token": "<Sitzungs-JWT>", "expiresAt": 1765630000000, "refreshToken": "<undurchsichtig, 43 Zeichen>",
 "sessionId": "k57…", "user": {"id": "j97…", "name": "Arman Samary", "email": "…@privaterelay.appleid.com"}}
```
Fehler: 400 `bad_request` (kein Token), 401 `invalid_apple_token` / `invalid_nonce`, 429 `rate_limited` (30 Versuche / 10 Min. / IP).

### `POST <site>/auth/refresh`

`{"refreshToken": "…"}` (ein zusätzlicher `Authorization`-Header wird ignoriert) → Antwort wie `/auth/apple` mit **neuem** `token`/`expiresAt`;
`refreshToken` bleibt gleich (keine Rotation), gültig bis zum Abmelden oder 180 Tage ohne Nutzung.
401 `invalid_session` → neu mit Apple anmelden. 429 bei mehr als 60 Anfragen / 10 Min. / IP.
Empfehlung für die App: erneuern, wenn `expiresAt` näher als 7 Tage ist, und nach jedem 401 eines Servers einmal.

### Server koppeln (Server-Seite, ohne Anmeldung)

- `POST <site>/servers/claim/start` `{"name": "Agenten-Air", "version": "1.12.0", "publicUrl": "https://….ts.net", "tailnetUrl": "…"}`
  → `{"code": "K7QX-29PL", "claimId": "…", "claimSecret": "…", "expiresAt": 1765…, "ttlSeconds": 600}`.
  Code: 8 Zeichen aus `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, Anzeige `XXXX-XXXX`, 10 Minuten gültig, einmalig. 429 ab 20 Codes / Stunde / IP.
- `POST <site>/servers/claim/poll` `{"claimId": "…", "claimSecret": "…"}` →
  - `{"status": "pending", "expiresAt": …}` (200),
  - `{"status": "claimed", "serverId": "…", "serverSecret": "…", "ownerId": "<Nutzer-ID>", "name": "…"}` (200; Convex speichert nur den SHA-256 des Secrets; jede Abholung vor dem ersten Herzschlag erzeugt ein neues Secret),
  - 410 `{"status": "expired", "code": "expired", …}`, 404 `unknown_claim` (falsches claimSecret, unbekannt oder schon per Herzschlag bestätigt).
- `POST <site>/servers/heartbeat`, Header `Authorization: Bearer <serverSecret>`, `{"publicUrl": "…", "tailnetUrl": "…", "version": "1.12.0"}`
  → `{"ok": true, "serverId": "…", "ownerId": "…", "name": "…", "revokedSessions": ["<sid>", …]}`.
  `revokedSessions` = abgemeldete Sitzungen des Inhabers der letzten 31 Tage; der Server lehnt deren JWTs sofort ab.
  401 `unknown_server` → Server wurde in der App entfernt oder das Konto gelöscht; der Python-Server löst daraufhin seine Kopplung.

### Funktionen für die App

Aufruf über die Convex-HTTP-API: `POST <cloud>/api/query` bzw. `/api/mutation`, Header `Authorization: Bearer <Sitzungs-JWT>`,
Körper `{"path": "<datei:funktion>", "args": {…}, "format": "json"}` → `{"status": "success", "value": …}` oder
`{"status": "error", "errorMessage": "…", "errorData": {"code": "unauthenticated", "message": "Nicht angemeldet"}}`.
Ohne gültige oder mit abgemeldeter Sitzung werfen alle Funktionen `ConvexError {code: "unauthenticated"}` (Text enthält „unauthenticated“).

| Pfad | Art | Argumente | Rückgabe |
|---|---|---|---|
| `users:me` | query | `{}` | `{"id", "name", "email", "createdAt", "sessionId"}` |
| `users:deleteAccount` | mutation | `{}` | `{"ok": true}` – löscht Nutzer, Sitzungen, Server, Kopplungen |
| `servers:myServers` | query | `{}` | `[{"id", "name", "publicUrl", "tailnetUrl" \| null, "version", "lastSeenAt" \| null, "online", "createdAt"}]` (`online` = Herzschlag < 3 Min.) |
| `servers:claimServer` | mutation | `{"code": "k7qx 29pl", "name"?: "…"}` | `{"ok": true, "serverId", "name"}` **oder** `{"ok": false, "error": "invalid_code" \| "rate_limited", "message": "<Text>"}` |
| `servers:renameServer` | mutation | `{"serverId", "name"}` | `{"ok": true}` / `{"ok": false}` (nicht gefunden/fremd) |
| `servers:removeServer` | mutation | `{"serverId"}` | `{"ok": true}` / `{"ok": false}` |
| `sessions:mySessions` | query | `{}` | `[{"id", "deviceName", "platform", "createdAt", "lastUsedAt", "current"}]` (nur aktive, zuletzt genutzte zuerst) |
| `sessions:revokeSession` | mutation | `{"sessionId"?}` (ohne = eigene Sitzung, also Abmelden) | `{"ok": true}` / `{"ok": false}` |

**Wichtig für die App:** `claimServer` wirft bei falschem Code **nicht**, sondern liefert `ok: false` (sonst würde Convex den
Fehlversuchszähler zurückrollen). Die App muss `ok` prüfen und `message` anzeigen. Code-Eingabe tolerant (Groß-/Kleinschreibung,
Bindestrich, Leerzeichen). Rate-Limit: 10 Fehlversuche je Nutzer in 10 Minuten, danach `rate_limited` (auch für richtige Codes).
Nach `claimServer` erscheint der Server sofort in `myServers` (`online: false`, `lastSeenAt: null`) und wird nach dem
Abholen des Secrets und dem ersten Herzschlag (wenige Sekunden) `online`.

### Python-Server (1.12.0)

- Bearer-Token für REST und `/api/ws`: entweder das bisherige `api_token` **oder** ein Sitzungs-JWT, wenn Signatur (JWKS von `cloud_url`,
  1 h zwischengespeichert, bei unbekannter `kid` neu geladen), `iss` = `cloud_url`, `aud` = `ais-scoops`, `exp` und `sub == owner_id` stimmen
  und `sid` nicht in `revokedSessions` steht. Ohne Kopplung (`owner_id` fehlt) wird kein JWT akzeptiert.
- `config.json`: `cloud_url` (HTTP-Adresse, Standard Produktion), `owner_id`, `cloud_server_id`. `serverSecret` im Schlüsselbund
  (`ais-bot-cloud` / `server-secret`).
- Herzschlag im Planer alle 60 s mit `publicUrl` (= `public_url`), `version`.
- `GET /api/setup` – nur direkt von 127.0.0.1/::1 (nicht über Tailscale Serve/Proxy): Kopplungsstatus, siehe docs/API.md (v1.12).
- `bin/aisbot cloud-link` startet die Kopplung über den laufenden Server und zeigt den Code, bis er eingelöst ist.

## Phase 2: AIS Scoops Server (Mac-App, 13.11.2026)

Das Ziel `ScoopsConnect` heißt jetzt **„AIS Scoops Server“** (Bundle bleibt `com.ais.scoopsconnect`) und bringt den
Python-Server mit (relocatable CPython 3.12 in `Contents/Resources/server`). Details: `App/README.md` Abschnitt
„AIS Scoops Server installieren“, Endnutzer-Anleitung: `docs/installation.md`.

- **Edition** (`Server/src/aisbot/profile.py`): `personal` (Standard, Armans Air – alles wie bisher) oder `standard`
  (Mac-App). `standard` = Datenordner `~/Library/Application Support/AIS Scoops Server`, keine VM, kein Lucy/T3/Team App/
  Atrium, keine persönlichen Prompt-Hinweise, Ansprache = config `user_name` → Kontoname (`owner_name` aus Convex) →
  macOS-Vorname, Initiative standardmäßig aus, Start-Scoop **Pip** ohne KI-Aufruf. Einzelne Funktionen per
  `config.json → features` schaltbar.
- **Convex:** `claim/poll` und `heartbeat` liefern zusätzlich `ownerName` (Dev deployt; **Produktion noch deployen**:
  `cd Cloud && npx convex deploy`). Ohne Deploy fällt der Server auf den macOS-Vornamen zurück.
- **Erreichbarkeit ohne Tailscale** bleibt offen (nur WLAN). Kandidaten: eigener Relay oder Cloudflare Tunnel pro Server.
- **Push** (APNs): umgesetzt als **Push-Relay** in Convex, siehe nächster Abschnitt.


## Push-Relay (13.11.2026, Server 1.13.0)

Ziel: Mitteilungen, App-Badge, Widget-Aktualisierung und Live-Aktivitäten (Push-to-Start, Updates, Ende,
Broadcast-Kanäle) für **alle** AIS-Scoops-Server. Der APNs-Schlüssel (.p8, Team `MYXQKK3T2Z`, Topic `com.ais.aisbot`)
liegt nur in Convex (Umgebungsvariablen) und auf Armans Server – fremde Server bekommen ihn nie.

```
 Kunden-Server (ohne Schlüssel) ──Bearer serverSecret──▶ Convex /push/* ──HTTP/2, JWT ES256──▶ APNs ──▶ iPhone/Mac
 Armans Server (eigener Schlüssel) ─────────────────────────────── direkt wie bisher ─────────▶ APNs
```

### Transportwahl im Server (`Server/src/aisbot/push.py`)

- **direkt**: `apns_key_id` in config.json und Schlüssel im Schlüsselbund (`ais-bot-apns`/`p8`) → unverändert direkt zu
  APNs (Armans Server; das Relay wird dann gar nicht gefragt).
- **Relay**: sonst, wenn mit einem Konto gekoppelt (`owner_id` + serverSecret) und Convex das Relay meldet
  (`POST /push/status` → `configured`, im Hintergrund alle 10 Min. erneuert, blockiert nie).
- `pusher.enabled` = einer der beiden Wege verfügbar. Die Wahl gilt 30 s; Koppeln/Entkoppeln setzt sie sofort zurück.
- Alles läuft in Hintergrund-Threads mit Zeitlimits (Relay 15–30 s); Fehler werden protokolliert, Läufe nie blockiert.
- Tokens, die die App meldet (`POST /api/devices`, `POST /api/live-activities`), meldet der Server im Relay-Modus an
  Convex (`/push/register`); vor jedem Versand werden noch nicht gemeldete Tokens nachgemeldet, bei `UnknownToken`
  einmal neu gemeldet und wiederholt.
- Antwortet das Relay mit `Unregistered`, `ExpiredToken` oder `BadDeviceToken` (in beiden Umgebungen), löscht der
  Server das Token aus `devices`/`live_tokens`.
- `GET /api/health` → zusätzlich `push_mode` (`direct`/`relay`/`null`); `GET /api/setup` → `"push": {"enabled", "mode", "error"}`.
  Die Mac-App „AIS Scoops Server“ zeigt das unter Konto („Mitteilungen: Aktiv (über AIS Scoops Cloud)“).

### App-Badge

Badge = **Anzahl Chats (Scoops und Gruppen) mit ungelesenen Nachrichten** (`DB.unread_chat_count()`), nicht die Summe
der Nachrichten. Jede Mitteilung trägt `aps.badge`. Wird ein Chat gelesen (`unread=0`: Lesen eines Scoops/einer Gruppe,
eigene Nachricht im Chat) oder ein Chat gelöscht, schickt der Server nach 2 s Entprellung einen stillen Badge-Push
`{"aps": {"badge": N}}` (`apns-push-type: alert`, Priorität 5) an die App-Geräte – nur wenn sich N geändert hat.
Gilt für beide Transportwege.

### Convex-Schnittstelle (`<site>/push/*`)

Alle Endpunkte: `POST`, Header `Authorization: Bearer <serverSecret>` (wie der Herzschlag). Unbekannt/fehlend →
`401 unknown_server`. Fehlerformat wie überall: `{"error": "<Text>", "code": "<code>"}`.

- `POST /push/status` `{}` → `{"ok": true, "configured": true, "maxPayloadBytes": 4096}`.
- `POST /push/register` `{"tokens": [{"token": "<hex>", "platform": "ios"}, …]}` (höchstens 100)
  → `{"ok": true, "registered": 3, "rejected": [{"token", "reason": "BadDeviceToken" | "UnknownPlatform" | "KindMismatch"}]}`.
  Plattform → Token-Art: `ios`/`ipados`/`macos`/`visionos`/leer → **app**; `ios-widgets` → **widgets**;
  `ios-scoops-live-start`, `ios-liveactivity-start`, `liveactivity` (Update-Token einer laufenden Aktivität) → **liveactivity**.
- `POST /push/send` `{"pushes": [{"token": "<hex>", "pushType": "alert" | "background" | "widgets" | "liveactivity",
  "topic"?: "<voll oder Suffix>", "priority"?: "10" | "5" | "1", "payload": {"aps": {…}, …}, "expiration"?: <Unix-Sekunden>}]}`
  (1–100 Einträge) → `{"ok": true, "sent": 2, "results": [{"token", "status": 200, "env": "production"}, {"token", "status": 410, "reason": "Unregistered"}, …]}`
  in derselben Reihenfolge. Gründe neben denen von APNs: `UnknownToken` (403, nicht vom Inhaber gemeldet),
  `TopicDisallowed` (403/400), `InvalidPushType`, `BadPriority`, `PayloadEmpty` (kein `aps`), `PayloadTooLarge` (413),
  `BadExpirationDate`, `ApnsUnreachable` (502). Ganze Anfrage: `429 rate_limited`, `503 relay_not_configured`, `400 bad_request`.
- `POST /push/channel` `{"action": "create"}` → `{"ok": true, "channelId": "…"}` bzw. `{"ok": false, "status", "reason"}`
  (Broadcast bei Apple nicht freigeschaltet o. ä.); `{"action": "delete", "channelId": "…"}` → `{"ok": true}`.
  Fremder/unbekannter Kanal → `404 unknown_channel`; mehr als 20 offene Kanäle → `429 too_many_channels`.
- `POST /push/broadcast` `{"channelId", "payload": {"aps": {…}}, "priority"?: "10", "expiration"?: <Unix-Sekunden, Standard +1 h, höchstens +24 h>}`
  → `{"ok": true}` / `{"ok": false, "status", "reason"}`. Convex setzt `apns-push-type: LiveActivity` und die Pflicht-Kopfzeile `apns-expiration`.

### Schutzmaßnahmen

- **Topic fest:** Convex leitet das Topic aus `pushType` ab (`com.ais.aisbot`, `….push-type.widgets`,
  `….push-type.liveactivity`); ein mitgeschicktes `topic` muss dazu passen. VoIP, Complication, Location usw. sind nicht möglich.
- **Nur eigene Tokens:** Gesendet wird nur an Tokens, die ein Server **desselben Kontos** gemeldet hat (Tabelle
  `pushTokens`, Schlüssel Konto + Token), und nur mit passender Art (App-Token bekommt keine Widget-/Live-Pushes und
  umgekehrt). Ein Konto kann Einträge anderer Konten nicht überschreiben. Höchstens 200 Tokens je Konto (die am längsten
  ungenutzten fallen heraus); Live-Update-Tokens verfallen nach 2 Tagen, alle anderen nach 90 Tagen ohne Nutzung.
- **Größe:** `payload` ≤ 4096 Byte (Mitteilung, Live-Aktivität, Broadcast), `aps` Pflicht.
- **Ratenbegrenzung** (fester Zeitfenster-Zähler je Server): 120 Pushes/Minute und 1800/Stunde, zusätzlich 3600/Stunde
  je Konto; Broadcasts 60/Minute und 1800/Stunde; 60 neue Kanäle/Stunde; 300 Token-Meldungen/Stunde.
  (Live-Aktivitäten aktualisieren höchstens alle 4 s ≈ 900/Stunde.)
- **Kanäle gehören dem anlegenden Server** (Tabelle `pushChannels`); nur er kann senden/löschen. Ein Cron löscht stündlich
  Kanäle, die älter als 6 h sind oder deren Server entfernt wurde, auch bei Apple.
- **Keine Inhalte gespeichert:** Payloads werden nur durchgereicht; gespeichert werden Token, Art, Plattform, gelernte
  Umgebung, Zeitstempel. `users:deleteAccount` löscht auch die Tokens.

### APNs in Convex (`Cloud/convex/apns.ts`, `"use node"`)

- `node:http2`, eine Sitzung pro Aufruf (am Ende geschlossen), 10 s Zeitlimit je Anfrage.
- Provider-JWT ES256 (`kid` = `APNS_KEY_ID`, `iss` = `APNS_TEAM_ID`), 40 Minuten zwischengespeichert (pro Node-Instanz).
- Umgebung wie bisher: erst production (bzw. die für das Token gelernte), bei `BadDeviceToken` die andere. Der Schlüssel
  ist bei Apple nur für **Production** freigegeben; antwortet die Sandbox mit `BadEnvironmentKeyInToken`, zählt das
  Ergebnis aus production (`BadDeviceToken`).
- Umgebungsvariablen in Dev **und** Prod: `APNS_KEY_P8` (PEM, auch als Base64/Hex möglich), `APNS_KEY_ID`, `APNS_TEAM_ID`.
  Gesetzt per Pipe direkt aus dem Schlüsselbund, nie ausgegeben (siehe `Cloud/README.md`).

### Tests

- `cd Cloud && npm test` – `tests/push.test.ts` (APNs über einen Mock von `node:http2`; JWT wird gegen den Testschlüssel geprüft).
- `cd Server && uv run python tests/test_push.py` – isolierte Instanz (Edition standard, ohne Schlüssel): Fake-Relay
  (Mitteilung mit Badge, entprellter Badge-Push, Widgets, Live-Aktivität mit Kanal/Broadcast/Update-Token, Aufräumen,
  Cloud nicht erreichbar) und gegen Convex-Dev mit echtem APNs, nur mit erfundenen Tokens (erwartet `BadDeviceToken`).

### Offen

- Tokens meldet heute der Server. Stärker wäre, wenn die App ihre Tokens selbst mit dem Sitzungs-JWT bei Convex
  registriert (dann könnte auch ein manipulierter Server nur an Geräte seines Kontos pushen, die sich wirklich dort angemeldet haben).
- Sandbox-Builds (Xcode-Debug) bekommen keine Pushes, solange der Schlüssel nur für Production gilt.

## Geteilte Scoops (13.11.2026, Server 1.14.0)

Konten können Scoops miteinander teilen (Rollen, Rechner-Stufen, Einladungslinks). Convex speichert nur das Verzeichnis
(`shares`, `invites`); der Server akzeptiert seitdem auch Sitzungs-JWTs **anderer** Konten als Gast, aber nur für die
ausdrücklich freigegebenen Endpunkte (sonst 403). Spezifikation und Schnittstelle: `docs/sharing.md`.
