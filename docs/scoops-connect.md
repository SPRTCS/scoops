# Scoops Connect – weitere Rechner für die Scoops

Stand: 13.11.2026 · Version 1 (Armans eigene Rechner; Mehrbenutzer kommt später)

## Ziel

Beliebige Macs als „Scoop-Rechner“ an den AIS-Scoops-Server anschließen, ohne Tailscale. Eine kleine
macOS-App **Scoops Connect** läuft auf dem Rechner und baut von sich aus eine Verbindung zum Server auf
(ausgehend, wie T3 Connect). Der Server schickt darüber dieselben Befehle, die er heute per HTTP an den
Cua-Computer-Server in der VM schickt.

Zwei Modi in der App:

| Modus | Wofür | Was die App tut |
|---|---|---|
| **Diesen Mac direkt steuern** | Rechner, der nur für die Scoops da ist (nichts Privates angemeldet) | führt Befehle selbst aus: ScreenCaptureKit, CGEvent, Prozesse |
| **Abgeschirmte VM** | Rechner, an dem man auch selbst arbeitet | betreibt eine Lume-VM mit Cua-Computer-Server und leitet Befehle an sie weiter |

Die bestehende VM auf dem MacBook Air bleibt als eingebauter Rechner `vm` („Bot-Rechner“) erhalten und
wird weiter direkt per HTTP (127.0.0.1:18000) angesprochen. Sie braucht kein Scoops Connect.

## Kopplung (Pairing)

1. In der AIS-Scoops-App: Einstellungen → **Rechner** → „Rechner hinzufügen“.
   `POST /api/nodes/pair` (Auth wie alle API-Aufrufe) → `{"code": "K7QX-29PL", "expires_at": "<iso>", "server_url": "<public_url>"}`.
   Code: 8 Zeichen aus `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, gültig 10 Minuten, einmalig.
2. In Scoops Connect: Server-Adresse (vorbelegt mit der öffentlichen Adresse, wenn per Link übergeben) + Code eingeben.
   `POST /api/nodes/claim` **ohne** Auth, Body `{"code", "name", "mode": "direct"|"vm", "os": "macOS 27.0", "app_version"}`
   → `{"node_id": "n_…", "node_token": "<geheim>", "server_url": "…"}`. Ungültig/abgelaufen → 404; mehr als 10 Fehlversuche pro Minute → 429.
3. Scoops Connect speichert `node_token` im Schlüsselbund (Dienst `scoops-connect`, Konto = Server-URL) und verbindet sich.

Der Server speichert nur einen SHA-256-Hash des Tokens.

## Verbindung (WebSocket)

`GET wss://<server>/api/nodes/link` mit Header `Authorization: Bearer <node_token>`.
Alle Nachrichten sind JSON-Textframes.

Rechner → Server, direkt nach dem Verbinden:
```json
{"type": "hello", "node_id": "n_…", "name": "Mac mini Büro", "mode": "direct", "os": "macOS 27.0",
 "app_version": "1.0 (1)", "screen": {"width": 1512, "height": 982}, "paused": false}
```

Server → Rechner, ein Befehl (gleiches Format wie Cua `/cmd`):
```json
{"type": "cmd", "id": "c_8f3a…", "command": "left_click", "params": {"x": 200, "y": 300}}
```

Rechner → Server, Antwort (gleiches JSON, das Cua als `data: {…}` liefert):
```json
{"type": "result", "id": "c_8f3a…", "result": {"success": true, …}}
```
Fehler: `{"success": false, "error": "…"}`. Der Server wartet höchstens 60 s (Screenshots 30 s).

Weitere Nachrichten:
- `{"type": "ping"}` / `{"type": "pong"}` alle 20 s in beide Richtungen; nach 60 s ohne Lebenszeichen gilt die Verbindung als tot.
- `{"type": "state", "paused": true}` vom Rechner, wenn jemand dort „Pausieren“ drückt. Der Server lehnt dann Befehle mit „Rechner ist pausiert“ ab.
- `{"type": "bye", "reason": "…"}` vom Server, z. B. wenn der Rechner in der App entfernt wurde (Token ungültig). Scoops Connect löscht dann das Token.

Wiederverbinden: exponentiell 1 s → 30 s, unbegrenzt.

## Befehle (Teilmenge des Cua-Computer-Servers, die der Server nutzt)

| command | params | result (zusätzlich zu `success`) |
|---|---|---|
| `get_screen_size` | – | `{"size": {"width", "height"}}` (logische Punkte) |
| `screenshot` | – | `{"image_data": "<base64 PNG>"}` in logischer Auflösung (Retina auf Punkte herunterskaliert) |
| `get_cursor_position` | – | `{"position": {"x", "y"}}` |
| `move_cursor` | `x, y` | – |
| `left_click`, `right_click`, `double_click` | `x?, y?` | – |
| `mouse_down`, `mouse_up` | `x?, y?, button?` ("left"/"right") | – |
| `drag` | `path: [[x,y],…]`, `button?`, `duration?` | – |
| `scroll` | `x, y` (Scroll-Delta in Zeilen, Vorzeichen wie Cua) | – |
| `type_text` | `text` | – |
| `press_key` | `key` | – |
| `hotkey` | `keys: [..]` z. B. `["command","t"]` | – |
| `key_down`, `key_up` | `key` | – |
| `run_command` | `command` (zsh) | `{"stdout", "stderr", "return_code"}` |
| `read_bytes` | `path`, `offset?`, `length?` | `{"content_b64": "…"}` |
| `write_bytes` | `path`, `content_b64`, `append?` | – |

**Zeitgrenzen (App ab Server 1.18.3):** Die App führt diese Befehle nacheinander aus, beantwortet jeden aber
spätestens nach 55 s (`screenshot`: 27 s) selbst mit `success: false` und einer klaren Meldung, z. B. „read_bytes
hängt …“. Das liegt knapp unter den Grenzen des Servers (60 s, `screenshot` 30 s, `Server/src/aisbot/nodes.py`).
Ein hängender Befehl blockiert so nie die folgenden (`App/ScoopsConnect/Core/CommandRunner.swift`). `run_command`
bricht den Prozess nach 50 s ab und liefert die Ausgabe bis dahin.

**`read_bytes`:** höchstens 25 MB pro Abruf (wie `datei_vom_rechner`, Base64 + JSON passen in eine
WebSocket-Nachricht, App und Server erlauben 64 MiB). Will der Aufruf mehr (ohne `length` bzw. `length` > 25 MB) und
hat die Datei mehr, lehnt die App mit Größenangabe ab, statt abzuschneiden. Liegt die Datei nur in iCloud
(bzw. ist sie „dataless“), stößt die App den Download an und antwortet sofort mit dem Hinweis, es gleich noch einmal
zu versuchen. Der Server fragt bei `datei_vom_rechner` `length = 25 MB + 1` an.

### Apple-Dienste (Server 1.17, nur die Mac-App „AIS Scoops Server“)

Home, Wecker und Standort (Server 1.18) laufen nicht über den Mac, sondern über die iOS-App AIS Scoops als
„Apple-Gerät“ (Gerätekanal über `/api/ws`, siehe docs/API.md v1.18). Der Mac meldet diese Fähigkeiten nie.

Laufen neben der Bildschirm-Steuerung (eigene Aufgabe, kein Warten hinter Screenshots) und auch bei **Pausieren**.
Ohne Freigabe antwortet die App mit `success: false` und einer klaren Meldung; Freigabe-Dialoge zeigt sie nie wegen
eines Befehls, nur über „Freigeben“ in den Einstellungen. Datumswerte ISO 8601 („2026-11-20“ = ganztägig,
„2026-11-20T09:00“ ohne Zone = Zeitzone des Macs); Antworten mit Zeitzone des Macs.

| command | params | result (zusätzlich zu `success`) |
|---|---|---|
| `apple.status` | – | `{"apple": {"reminders", "calendar", "contacts"}}` |
| `apple.reminders.lists` | – | `{"lists": [{id, title, color, account, writable, default}]}` |
| `apple.reminders.list` | `list?` (Name oder ID), `status?` open/completed/all, `due_before?`, `query?`, `limit?` | `{"reminders": [Erinnerung]}` (+ `{"more": n}`) |
| `apple.reminders.get` | `id` | `{"reminder": Erinnerung}` |
| `apple.reminders.add` | `title`, `notes?`, `due?`, `list?`, `priority?` none/low/medium/high | `{"reminder": …}` (mit Uhrzeit → Hinweis zur Fälligkeit) |
| `apple.reminders.update` | `id`, `title?`, `notes?`, `due?` ("" entfernt), `list?`, `priority?`, `completed?` | `{"reminder": …}` |
| `apple.reminders.complete` | `id`, `completed?` (Standard true) | `{"reminder": …}` |
| `apple.reminders.delete` | `id` | `{"deleted": …}` |
| `apple.calendar.calendars` | – | `{"calendars": [{id, title, color, account, writable, default}]}` |
| `apple.calendar.events` | `from?`, `to?` (Standard heute), `calendar?`, `query?`, `limit?` | `{"from", "to", "events": [Termin]}` |
| `apple.calendar.get` | `id` | `{"event": Termin}` |
| `apple.calendar.add` | `title`, `start`, `end?` (+1 h), `all_day?`, `calendar?`, `location?`, `notes?`, `alarm_minutes?` | `{"event": …}` |
| `apple.calendar.update` | `id`, Felder wie add, `span?` this/future | `{"event": …}` |
| `apple.calendar.delete` | `id`, `span?` | `{"deleted": …}` |
| `apple.contacts.search` | `query` (Name, Firma, Mail, Telefon) und/oder `birthdays_days`, `limit?` | `{"contacts": [{id, name, organization, job_title, phones, emails, birthday, birthday_in_days?, addresses}]}` |

Erinnerung: `{id, title, notes?, list, list_id, due?, due_all_day?, priority, completed, completed_at?, url?}`.
Termin: `{id, title, start, end, all_day, calendar, calendar_id, recurring, location?, notes?, url?, attendees?}`;
bei Serien ist `id` = `<eventIdentifier>@<Unix-Zeit des Vorkommens>`, damit genau dieses Vorkommen gemeint ist.

Freigaben stehen im `hello` und in jedem `state` als `"apple": {"reminders": "granted", "calendar": "denied",
"contacts": "not_determined"}` (weitere Werte `restricted`, `write_only`, `disabled`). Die App prüft sie alle 3 s
und schickt bei einer Änderung sofort ein `state`. Entitlements (Hardened Runtime):
`com.apple.security.personal-information.calendars` und `.addressbook`; Nutzungstexte
`NSRemindersFullAccessUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSContactsUsageDescription`.

Tastennamen wie Cua/pyautogui: `command`, `option`, `control`, `shift`, `enter`/`return`, `tab`, `escape`, `space`,
`backspace`, `delete`, `up`/`down`/`left`/`right`, `home`, `end`, `pageup`, `pagedown`, `f1`…`f12`, einzelne Zeichen.
Maßgeblich ist, was `Server/src/aisbot/computer.py` sendet – im Zweifel dort nachsehen.

## Server

- Tabelle `nodes(id, name, mode, token_hash, os, app_version, created_at, last_seen)`, Tabelle `node_pairings(code, expires_at, used)`.
- `ComputerHub` gibt es pro Rechner (eigene Sperre, eigener Übernahme-Zustand). Registry `computers`: `vm` (HTTP, wie heute) + je verbundenem Knoten ein Hub mit WebSocket-Transport. `Computer` bekommt einen austauschbaren Transport, `cmd()` bleibt gleich.
- Scoop-Feld `computer_node` (NULL = `vm`). Engine/OpenAI-Engine nutzen den Hub des Scoops.
- API (alle mit Auth):
  - `GET /api/nodes` → `[{id, name, mode, online, paused, os, app_version, last_seen, screen, state, bot_id}]` inkl. `vm`.
  - `PATCH /api/nodes/{id}` `{name}` · `DELETE /api/nodes/{id}` (nicht für `vm`; trennt mit `bye`).
  - `POST /api/nodes/pair`, `POST /api/nodes/claim` (ohne Auth), `GET /api/nodes/link` (WebSocket, Node-Token).
  - Bisherige Rechner-Endpunkte bekommen optional `?node=<id>` (Standard `vm`): `GET /api/computer`, `/api/computer/screen.jpg`, `/takeover`, `/release`, `/input`.
  - Scoop bearbeiten: `computer_node` im bestehenden PATCH des Scoops.
- Event `computer.state` enthält zusätzlich `node_id`.

## AIS-Scoops-App

- Einstellungen → Abschnitt **Rechner**: Liste (Name, Modus, online/offline/pausiert, wer arbeitet gerade), „Rechner hinzufügen“ zeigt Code + Anleitung + Ablaufzeit, Umbenennen, Entfernen.
- Scoop-Profil (Inspector): Auswahl „Rechner“ (Standard: Bot-Rechner).
- Bildschirm-Ansicht/Übernehmen: zeigt den Rechner des jeweiligen Scoops (`?node=`), mit Umschalter, wenn es mehrere gibt.

## Scoops Connect (macOS-App)

- Eigenes Xcode-Ziel `ScoopsConnect` im Projekt `App/` (Bundle `com.ais.scoopsconnect`), **ohne Sandbox**, Menüleisten-App (`MenuBarExtra`) plus kleines Einstellungsfenster.
- Onboarding: Server-Adresse + Code → Modus wählen → Berechtigungen (Bildschirmaufnahme, Bedienungshilfen) mit Direkt-Links in die Systemeinstellungen und Live-Prüfung.
- Menü: Status (verbunden/getrennt, „Mila arbeitet gerade“ aus `hello`/Server-Infos), **Pausieren**, Rechner trennen, Beim Anmelden starten (`SMAppService`).
- Sichtbarer Hinweis, solange ein Scoop steuert (Menüleisten-Symbol wechselt, optional dezenter Rahmen).
- Modus „direkt“: Befehle selbst ausführen.
- Modus „VM“: prüft/installiert Lume (Homebrew), legt bei Bedarf eine VM aus dem Cua-Image an, startet sie, wartet auf deren Computer-Server und leitet Befehle 1:1 an `http://<vm-ip>:8000/cmd` weiter.
- Verteilung v1: auf Armans eigenen Macs mit Apple-Development-Signatur. Für Freunde später Developer-ID + Notarisierung.

## KI-Abos in der Mac-App (Server 1.30)

Einrichtung Schritt 2 und Einstellungen → „KI-Abos“: Status von Claude Code und Codex, „Mit Claude anmelden“ /
„Mit ChatGPT anmelden“ (öffnet den offiziellen Login im Terminal) und Abrechnungsmodus pro Anbieter. Endpunkte
`/api/setup/abos…` (nur lokal). Ablauf und Regeln: [`docs/abos.md`](abos.md).

## Später (nicht in v1)

Benutzerkonten auf dem Server (eigene Scoops, Daten und Composio-Konten pro Person), damit Freunde ihre eigenen Rechner verbinden können.
