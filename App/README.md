# AIS Scoops – App (iPhone, iPad, Mac)

Native SwiftUI-App **AIS Scoops** (Projekt „AIS Bot“): ein Messenger, in dem du mit deinen eigenen Bots chattest. Die Bots heißen **Scoops** (der Scoop, die Scoops): kleine, flauschige Kugeln mit Namen, Label, Charakter, Gedächtnis und eigenem Rechner. Die App spricht ausschließlich mit dem Bot-Server über den Vertrag in [`../docs/API.md`](../docs/API.md).

Ein Target `AISBot` für iOS/iPadOS 26 und macOS 26 (nativ, kein Catalyst) plus ein Widget-Target `AISBotWidgets` für beide Plattformen.

## Bauen und starten

Das Projekt wird mit xcodegen erzeugt (`project.yml` ist die Quelle, `AISBot.xcodeproj` wird generiert):

```sh
cd "AIS Bot/App"
/opt/homebrew/bin/xcodegen generate

# Mac (signiert automatisch mit Team MYXQKK3T2Z)
xcodebuild -scheme AISBot -destination 'platform=macOS' -derivedDataPath /tmp/claude-501/aisbot-dd build

# iOS-Simulator
xcodebuild -scheme AISBot -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/claude-501/aisbot-dd build
```

DerivedData liegt bewusst außerhalb von iCloud Drive (`-derivedDataPath`).

### Demo-Modus

Ohne Server läuft die App mit Beispieldaten (5 Scoops, Verlauf mit laufendem Status, Freigabe-Karte, Ereignissen, Markdown):

- Startargument `-mock`, oder
- als Server-Adresse `mock://` eintragen, oder
- in der Einführung „Erst mal ohne Server ausprobieren“.

Einführung für neue Nutzer (Begrüßung → Anmelden → Server koppeln → erster Scoop → erste Antwort → Tipps): [`../docs/onboarding.md`](../docs/onboarding.md). Screenshots einzelner Schritte mit `-mock -onboarding <schritt>[:<detail>]`, z. B. `server:code`, `scoop:look`, `message:reply`.

Im Demo-Modus antworten Scoops simuliert (Tippen, Statuszeilen, Live-Bildschirm, Antwort). Nachrichten mit „such“ oder „Browser“ lösen einen Lauf mit Bot-Rechner aus.

Weitere Startargumente für Screenshots: `-hatchdemo` (Platzhalter „schlüpft“), `-theme nacht|hell`, `-select <chat-id>` (z. B. `b_mila` oder die Demo-Gruppe `g_team`), `-inspector` (Profil offen), `-profilepage <seite>[,<seite>]` (Unterseite im Profil öffnen: `library`, `model`, `personality`, `sharing`, `guestTools`, `manage`, `routines`, `skills`, `memory`, `costs`, z. B. `manage,costs`), `-memory` / `-library` (Profil → Verwalten → Gedächtnis bzw. Bibliothek; im Gruppenprofil der Tab), `-create` (Neuer Scoop), `-creategroup` (Neue Gruppe), `-attachdemo` (Anhänge in der Eingabe), `-voicedemo` (Sprachmodus ohne Mikrofon, Gerätestimme), `-livedemo` (Live-Sprechmodus mit Untertiteln ohne Mikrofon), `-takeoverdemo` (Bot-Rechner übernommen), `-settings`, `-palette` (Befehlspalette offen), `-mocklatency <ms>` (Ladezeit der Nachrichten), `-unread <chat-id> <anzahl>` (Ungelesen-Zähler). Rechner (v1.11): `-settingsnodes` (Einstellungen → Rechner), `-nodesadd` (Rechner hinzufügen), `-computerdemo` (Profil, scrollt zu „Computer“), `-screenviewer` (Bildschirm-Ansicht), `-pairdemo` (Demo-Kopplung meldet nach 6 s einen neuen Mac). Nur Debug-Builds: `-uploadtest` (lädt ein erzeugtes Testbild in den gewählten Chat hoch), `-perflog -perfbench` (misst Chatwechsel), `-nocache` (ohne Zwischenspeicher, für Vergleiche), `-testserver <url> <token>` (verbindet mit einer Testinstanz, nur im Speicher: gespeicherte Verbindung, Schlüsselbund und Widgets bleiben unberührt), `-sidebarshrinktest [collapse]` (Mac: Fenster nach 4 s per `setFrame` schmal, nach weiteren 4 s wieder breit – wie ein Bildschirmwechsel; mit `collapse` klappt AppKit-seitig auch die Seitenleiste ein; protokolliert `[shrinktest]`/`[sidebar]`).

Beispiel Mac:
```sh
open "/tmp/claude-501/aisbot-dd/Build/Products/Debug/AIS Scoops.app" --args -mock -theme hell -select b_mila -inspector
```

### Seitenleiste auf dem Mac

AppKit klappt die linke Seitenleiste selbst ein, wenn das Fenster für alle Spalten zu schmal wird (z. B. Profil offen und Wechsel auf einen schmaleren Bildschirm), und klappt sie danach nur beim Aufziehen mit der Maus wieder aus. `SidebarSync` (`Views/SidebarSync.swift`) beobachtet das Seitenleisten-Item und die Fenster-Ereignisse (Größe, Bildschirm, Auflösung, Vollbild) sowie Profil/Spalten im Store: `sidebarColumns` folgt immer dem echten Zustand, und ist das Fenster wieder breit genug (760 pt, mit Profil 1040 pt), fährt die Leiste von selbst wieder ein – außer der Nutzer hat sie bewusst ausgeblendet (`sidebarHiddenByUser`: ⌃⌘S, Befehlspalette, Knopf, am Trenner zugezogen). Ist sie zu, steht neben den Ampelknöpfen ein runder Glas-Knopf zum Einblenden. Screenshots: `Screenshots/sidebar-*.png`.

### Verbinden mit dem echten Server

- Einführung beim ersten Start (docs/onboarding.md); „Erweitert: Manuell verbinden“ (Server-Adresse + Token, „Verbinden“ prüft per `GET /api/health`) steht direkt auf der ersten Seite.
- Vorschlag auf dem Mac: `http://127.0.0.1:8787`, auf iPhone/iPad: `https://<dein-mac>.<tailnet>.ts.net:8787` (Tailscale).
- Kopplungslink `aisbot://pair?url=<basis-url>&token=<token>` trägt beides ein (URL-Schema `aisbot`).
- Token liegt im Schlüsselbund (`com.ais.aisbot` / `token`), die URL in UserDefaults (`serverURL`).
- Einstellungen → Verbindung: ändern, neu verbinden, trennen.
- Mit Konto (ab API v1.12): „Mit Apple anmelden“ und einen Server aus „Deine Server“ wählen, kein Token nötig. Der Token-Weg bleibt unter „Erweitert → Manuell verbinden“ (siehe „Benutzerkonten“ unten).

### App-Icon und Vorschaubilder neu rendern

Icon, Maskottchen-Übersicht und Widget-Vorschauen werden aus dem SwiftUI-Code gerendert:

```sh
"/tmp/claude-501/aisbot-dd/Build/Products/Debug/AIS Scoops.app/Contents/MacOS/AIS Scoops" -render-assets /tmp/ais-assets
```

Danach `icon-ios.png` als `AppIcon.appiconset/icon-ios-1024.png` und `icon-mac.png` per `sips -z` in die Mac-Größen 16 bis 512@2x kopieren.

## Scoops Connect (macOS-Menüleisten-App)

Eigenes Ziel `ScoopsConnect` (Bundle `com.ais.scoopsconnect`, Produktname seit Version 2.0 **„AIS Scoops Server“**, macOS 26+, ohne Sandbox, Hardened Runtime) im selben Projekt. Die App hat zwei Rollen: **Server** (bringt den Python-Server mit, siehe nächster Abschnitt) und **nur Rechner** (das bisherige Scoops Connect für einen fremden Server; gilt automatisch für bestehende Kopplungen). Schließt weitere Macs als Scoop-Rechner an den Server an – ohne Tailscale, die App baut die Verbindung von sich aus auf (WebSocket `/api/nodes/link`). Konzept: [`../docs/scoops-connect.md`](../docs/scoops-connect.md), Protokoll-Ergänzungen: [`../docs/API.md`](../docs/API.md) Abschnitt v1.11.

Quellen: `ScoopsConnect/` – `App/` (Einstieg, `AppModel` mit Kopplung/WebSocket/Wiederverbinden), `Core/` (JSON, Tasten-Mapping, SSE, Schlüsselbund, Prozesse), `Direct/` (ScreenCaptureKit, CGEvent, Rechte), `VM/` (Lume, Weiterleitung an den Cua-Computer-Server), `Views/`, `Tests/`.

### Bauen und testen

```sh
cd "AIS Bot/App"
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme ScoopsConnect -destination 'platform=macOS' -derivedDataPath /tmp/claude-501/aisbot-dd-connect -allowProvisioningUpdates build
xcodebuild -scheme ScoopsConnect -destination 'platform=macOS' -derivedDataPath /tmp/claude-501/aisbot-dd-connect test   # Tasten-Mapping, SSE, JSON
```

Ohne echten Server (nur harmlose Befehle, keine Klicks/Tasten):

```sh
APP="/tmp/claude-501/aisbot-dd-connect/Build/Products/Debug/AIS Scoops Server.app"
python3 ScoopsConnect/Tests/fake_server.py --port 8799 --hold 10 --bye &
"$APP/Contents/MacOS/AIS Scoops Server" -fakeserver 8799 -pauseafter 4
```

Gegen eine isolierte Server-Testinstanz (eigener Port, Temp-DB – nie die Produktion auf 8787):

```sh
cd "AIS Bot/Server" && uv run python ../App/ScoopsConnect/Tests/e2e_server.py "$APP"
```

Debug-Startargumente: `-fakeserver <port>` (koppelt automatisch mit `-code`, Standard `TEST-2345`, eigene Einstellungen-Domain `com.ais.scoopsconnect.fakeserver`), `-mode direct|vm`, `-pauseafter <s>`, `-onboarding-step 1|2|3`, `-showwindow` (Einstellungen), `-menupreview` (Menü-Panel als Fenster für Screenshots; als letztes Argument angeben). Screenshots: `Screenshots/connect-*.png`.

### Installieren auf weiteren Macs

1. Release bauen (`-configuration Release`) oder den Debug-Build nehmen und `AIS Scoops Server.app` (früher `Scoops Connect.app`) nach `/Applications` kopieren. Eine bestehende Kopplung bleibt erhalten; die App startet dann in der Rolle „nur Rechner“ wie bisher. v1 ist mit **Apple Development** signiert (Team MYXQKK3T2Z): läuft auf Armans eigenen Macs, die mit derselben Apple-ID/Team angemeldet sind; Gatekeeper kann beim ersten Start „Öffnen“ per Rechtsklick verlangen.
2. Für Freunde später: Signatur mit **Developer ID Application** + Notarisierung (`xcrun notarytool submit … --wait`, danach `xcrun stapler staple`).
3. App starten → Onboarding: Server-Adresse + Code aus AIS Scoops (**Einstellungen → Rechner → Rechner hinzufügen**), Name, Modus. Kopplungslink möglich: `scoopsconnect://pair?server=<url>&code=<code>`.
4. Token liegt im Schlüsselbund (Dienst `scoops-connect`, Konto = Server-URL). „Rechner trennen“ oder ein `bye` vom Server löscht es.

### Berechtigungen (Modus „direkt“)

- **Bildschirmaufnahme** (Screenshots) und **Bedienungshilfen** (Maus/Tastatur). Das Onboarding prüft beides live und öffnet die passende Seite in Systemeinstellungen → Datenschutz & Sicherheit. Die App erteilt sich nie selbst Rechte.
- Ohne Recht antworten `screenshot` bzw. Eingabebefehle mit einem klaren Fehler statt stumm zu scheitern.
- Neue Signatur (z. B. Wechsel auf Developer ID) → macOS fragt die Rechte erneut ab.

### Modus „Abgeschirmte VM“

- Braucht Lume (`brew install lume`, die App bietet das an). VM wählen oder neu anlegen: `lume pull macos-tahoe-cua:latest <name>` (Cua-Image mit Computer-Server, großer Download). Start ohne Fenster per `lume run <name> --display none` als Kindprozess, dann Warten auf `http://<vm-ip>:8000/status`; Befehle gehen 1:1 an `/cmd` (SSE-Antwort). Beim Beenden stoppt die App nur VMs, die sie selbst gestartet hat.
- `ais-bot-mac` (die VM des Servers auf dem Air) wird nur angezeigt – nie gestartet, gestoppt oder verändert.
- Die VM-IP liegt im lokalen Netz (192.168.64.x): macOS fragt einmal nach „Lokales Netzwerk“.

### Sicherheit

Befehle nur nach Kopplung; während „Pausieren“ lehnt die App alles mit „Rechner ist pausiert“ ab und meldet `state` an den Server; Tokens werden nicht geloggt. Solange ein Scoop steuert (`activity` vom Server oder aktive Befehle in den letzten 20 s), wechselt das Menüleisten-Symbol und das Menü zeigt „Mila arbeitet gerade“.

## AIS Scoops Server installieren (Mac-App für eigene Scoops)

Mit **AIS Scoops Server** betreibt eine andere Person ihre **eigenen** Scoops auf ihrem Mac – ohne Terminal und ohne Python-Installation. Endnutzer-Anleitung: [`../docs/installation.md`](../docs/installation.md). Konten/Kopplung: [`../docs/accounts.md`](../docs/accounts.md).

### Aufbau

```
AIS Scoops Server.app (Ziel ScoopsConnect, Bundle com.ais.scoopsconnect, Version 2.0)
├─ Contents/MacOS/AIS Scoops Server     Menüleisten-App (SwiftUI): Assistent, Status, Rechner „Dieser Mac“
└─ Contents/Resources/server/           relocatable CPython 3.12 (python-build-standalone über uv)
   ├─ bin/python3                         + Abhängigkeiten aus Server/uv.lock + Paket aisbot (site-packages)
   └─ lib/python3.12/…                    Bytecode vorkompiliert (unchecked-hash), -B: nie Schreibzugriff aufs Bundle
```

- **Server-Betrieb:** Kindprozess der App (`python3 -I -B -u -c "from aisbot.server import main; main()"`) mit Neustart-Überwachung (Backoff 2–30 s, nach 5 Abstürzen in 2 Minuten Fehlerstatus). Die App startet beim Anmelden (`SMAppService.mainApp`). Bewusst **kein eigener LaunchAgent**: ein Prozessbaum, im Testmodus vollständig prüfbar, und für Laien klar – „solange das Symbol in der Menüleiste ist, läuft der Server“. Endet die App (auch durch Absturz), beendet sich der Server über `AISBOT_PARENT_PID` selbst; ein übrig gebliebener Prozess (`server.pid`) wird beim nächsten Start ersetzt.
- **Daten:** `~/Library/Application Support/AIS Scoops Server/` (`config.json`, `data/`, `logs/server.log`, `backups/`). Der Server bekommt `AISBOT_HOME`, `AISBOT_EDITION=standard`, `AISBOT_KEYCHAIN_PREFIX` als Umgebung (siehe `Server/src/aisbot/profile.py`).
- **Port:** 8787, sonst der nächste freie (steht in `config.json` → `port`). Auf Armans Air ist 8787 belegt – die App weicht dann aus.
- **Schlüssel:** im Anmelde-Schlüsselbund unter `ais-bot-anthropic|openai|composio` / `api-key`, geschrieben über `/usr/bin/security -i` (Wert über die Standardeingabe, nie als Argument), damit der Server ohne Rückfrage-Dialog lesen kann. Prüfung vor dem Speichern mit einem kostenlosen Lese-Aufruf (Modell-/Toolkit-Liste).
- **Einrichtungs-API des Servers** (nur 127.0.0.1, ohne Token, über Proxy abgelehnt): `GET /api/setup` (Kopplung + Installationszustand), `POST /api/setup/link` (Kopplungscode Convex), `PATCH /api/setup/config` (`user_name`, `public_url`, `tailnet_url`, `server_name`, `default_computer_node`, `host`, `provider`), `POST /api/setup/node-pair` (Code für „Dieser Mac“), `POST /api/setup/reload` (Composio-Sitzung anlegen, Apps neu laden).
- **Dieser Mac:** Die App koppelt sich selbst als Rechner „direkt“ mit dem eigenen Server (`/api/setup/node-pair` → `/api/nodes/claim`), setzt ihn als `default_computer_node` und ordnet alle Scoops ohne Rechner zu. Ohne VM-Funktion zeigt der Server keinen „Bot-Rechner“, und `?node=vm` zeigt auf diesen Mac.
- **Rollen:** Neue Installation → Server. Bestehende Scoops-Connect-Kopplung → „nur Rechner“ wie bisher. Umschalten im Willkommensschritt bzw. im Kopplungsfenster.

### Assistent

Willkommen → **Konto** (Kopplungscode, eingeben in AIS Scoops unter „Deine Server → Server hinzufügen“; Ansprache/Vorname) → **KI-Schlüssel** (Anthropic und/oder OpenAI, optional Composio; nur OpenAI → Scoops nutzen GPT-Modelle) → **Dieser Mac** (Bildschirmaufnahme, Bedienungshilfen, Anschließen) → **Erreichbarkeit** (Tailscale Serve fürs eigene Tailnet oder Funnel öffentlich auf Port 10000, sonst nur WLAN mit `host 0.0.0.0` + `<Name>.local:<Port>`; jede Änderung erst nach Klick, Funnel mit Rückfrage) → **Dauerbetrieb** (Mac/Bildschirm wach halten per Energie-Zusicherung ohne Passwort; „Ruhezustand dauerhaft aus“ = `pmset -a sleep 0` nur nach Bestätigung über den macOS-Passwortdialog; Sperrbildschirm-Einstellungen öffnen) → Fertig.

Menüleiste (Server-Rolle): Status (läuft/gestoppt, Version, Konto, Adresse), Server neu starten, Protokoll öffnen, Pausieren (Rechner), Einstellungen (Schlüssel ändern, Konto, Erreichbarkeit, Dauerbetrieb), Beenden (stoppt den Server).

### DMG bauen, signieren, notarisieren

```sh
cd "AIS Bot/App"
scripts/build-server-dmg.sh                # Release, Developer ID, Notarisierung, Stapeln → build/server-dmg/*.dmg
NOTARIZE=0 scripts/build-server-dmg.sh     # nur signieren
scripts/build-server-runtime.sh <ordner>   # nur den Python-Teil bauen (wird vom DMG-Skript aufgerufen)
```

- Release-Build ohne Xcode-Signatur, dann Python einfügen und **alles selbst signieren**: jede Mach-O-Datei in `Contents/Resources/server` (≈ 40 `.so`/`.dylib` + `python3.12`) mit `--options runtime --timestamp`, danach die App. Python braucht unter Hardened Runtime **keine** zusätzlichen Entitlements, weil alle Erweiterungen dieselbe Team-ID tragen (Bibliotheksprüfung bleibt an). Bei Bedarf: `PYTHON_ENTITLEMENTS=<plist>`.
- Selbsttest im signierten Bundle (Import aller nativen Module mit Temp-Datenordner), dann DMG mit `dmgbuild` (Hintergrund aus `scripts/dmg-background.py`, Verknüpfung „Programme“, ohne Finder-Fernsteuerung), DMG signieren, `xcrun notarytool submit --key …AuthKey_B2M5G9DH6U.p8 --key-id B2M5G9DH6U --issuer … --wait`, `xcrun stapler staple`.
- Ohne „Developer ID Application“-Zertifikat signiert das Skript mit Apple Development und meldet deutlich, dass nicht notarisiert wurde.
- Nur **Apple Silicon** (arm64): Der Python-Teil ist arm64; Intel-Macs werden nicht unterstützt.

### Testen ohne Armans Server zu stören

```sh
APP="/tmp/claude-501/aisbot-dd-connect/Build/Products/Debug/AIS Scoops Server.app"
scripts/build-server-runtime.sh /tmp/claude-501/scoops-runtime
"$APP/Contents/MacOS/AIS Scoops Server" -testserver /tmp/claude-501/scoops-test \
    -serverpython /tmp/claude-501/scoops-runtime/bin/python3 -autosetup     # -setupstep 0…6 für Screenshots
```

`-testserver <ordner>`: eigener Datenordner, Port 8799 (`-testport`), Schlüsselbund-Präfix `ais-scoops-test`, Konto-Dienst Convex-**Dev**, eigene UserDefaults (`com.ais.scoopsconnect.testserver`), „Dieser Mac“ wird nur gekoppelt, **nie** mit der echten Steuerung verbunden, keine Tailscale-/pmset-Änderungen. `-autosetup` läuft Code anfordern → Dieser Mac → Name → Testschlüssel speichern/löschen → wartet auf Kopplung durch und protokolliert nach `<ordner>/autosetup.log`. Code einlösen mit einer Dev-Testsitzung (`npx convex run devtools:issueTestSession '{"appleSub":"test.…"}'` in `Cloud/`, dann `servers:claimServer`). Server-Tests: `cd Server && uv run python tests/test_standard.py`. Aufräumen: Testordner löschen, `defaults delete com.ais.scoopsconnect.testserver`, Test-Server in Convex-Dev entfernen.

## Architektur

```
App/
├─ project.yml                 xcodegen-Projekt (App + Widget-Extension)
├─ Shared/                     in App UND Widget kompiliert
│  ├─ Models/Models.swift      Bot, Message (+Meta), Memory, Routine, Usage, ServerEvent (WebSocket)
│  ├─ Models/JSONCoding.swift  Decoder (snake_case, tolerante ISO-8601-Daten)
│  ├─ Mascot/                  MascotGeometry (Formen), MascotView (Fell, Gesicht, Accessoires, Animation)
│  ├─ Theme/Theme.swift        Theme-Tokens „Nacht“ und „Hell“
│  ├─ Support/MarkdownText     kleiner Markdown-Parser (Absätze, Listen, Code)
│  └─ Widget/                  WidgetSnapshot (App Group), Widget-Oberflächen, Live-Activity-Attribute
├─ scripts/upload-testflight.sh   Archiv + Upload beider Plattformen (TestFlight)
├─ ExportOptions-ios.plist / ExportOptions-mac.plist
├─ AISBot/
│  ├─ App/AISBotApp.swift      Einstieg, Szenen, Menübefehle, URL-Handling, Startargumente
│  ├─ Networking/              BotService-Protokoll, APIClient (URLSession async/await), EventSocket (WebSocket), Verbindung/Schlüsselbund
│  ├─ Store/                   AppStore (@Observable, MainActor), MockService + PreviewData (Demo-Modus)
│  ├─ Views/                   Root, Seitenleiste, Chat (Blasen, Status, Freigabe, Eingabe), Profil, Anlegen, Einstellungen, Onboarding
│  └─ Support/                 Mitteilungen, Widget-Sync, Live Activity, Asset-Renderer (Mac)
└─ AISBotWidgets/              Widget-Bundle, Intents (Scoop wählen), Timelines, Live Activity (iOS)
```

**Datenfluss:** `AppStore` hält Bots, Nachrichten pro Bot, Gedächtnis, Routinen, Rechner-Status und Tipp-Status. Er lädt über `BotService` (echter `APIClient` oder `MockService`) und wendet WebSocket-Ereignisse (`message.created/updated`, `bot.*`, `computer.updated`, `routine.updated`) an. Alles läuft auf dem MainActor (Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), es gibt keine geteilten veränderlichen Zustände außerhalb des Stores.

**WebSocket:** `URLSessionWebSocketTask` auf `/api/ws?token=…`, `{"type":"ping"}` alle 25 s, Neuverbinden mit exponentiellem Backoff (1, 2, 4 … max. 30 s). Nach dem Neuverbinden lädt der Store Bots, offene Chats und das Profil nach.

**Chat:** lädt die letzten 50 Nachrichten, beim Hochscrollen ältere mit `before=<erste id>`. Scrollposition bleibt beim Nachladen stabil (`defaultScrollAnchor(.bottom, for: .sizeChanges)`), neue Nachrichten scrollen ans Ende. Sichtbarer Chat wird per `POST /read` als gelesen markiert. Stopp-Knopf ersetzt Senden, solange der Scoop arbeitet. Return sendet, ⇧Return bzw. ⌥Return macht eine neue Zeile (Mac/Hardware-Tastatur).

**Navigation:** Mac und iPad: `NavigationSplitView` (Seitenleiste | Chat) mit Profil als `.inspector` rechts. iPhone: `NavigationStack` (Seitenleiste → Chat), Profil als Sheet. Tastenkürzel: ⌘N neuer Scoop, ⌘F suchen, ⌘I Profil, ⌘, Einstellungen, ⌘K Befehlspalette, ⌃⌘S Seitenleiste.

**Mitteilungen:** Kommt über den noch offenen Socket eine Bot-Nachricht, während die App im Hintergrund ist, gibt es eine lokale Mitteilung (Erlaubnis wird beim ersten echten Start erfragt, nicht im Demo-Modus). Tippen öffnet den Chat.

## Funktionen ab API v1.1

**Gruppenchats.** Gruppen (2–6 Scoops) stehen in der Seitenleiste neben den Scoops (Kacheln, Abschnitte, Kontextmenü). Avatar = Haufen aus bis zu drei Maskottchen. „+“ → „Neuer Scoop“ (⌘N) / „Neue Gruppe“ (⌘⇧N). Im Gruppenchat steht über jeder Antwort Mini-Maskottchen + Name des Autors (`meta.author_id`), Tipp-Anzeige pro Mitglied („Mila schreibt …“), Statuszeilen mit Autor, Übergaben („Mila → Lio: …“) als Ereigniszeile mit Pfeil. `@`-Erwähnungen: Beim Tippen von „@“ erscheinen die Mitglieder und „alle“. Gruppenprofil: Name ändern, Mitglieder hinzufügen/entfernen (2–6, Antippen öffnet das Scoop-Profil), Bibliothek, Verlauf leeren, Gruppe löschen (Scoops bleiben). Widgets bleiben bei Scoops.

**Bibliothek.** Dritter Profil-Tab (Scoop und Gruppe): Dateien und Links mit Symbol, Größe, Datum, Autor (Maskottchen oder „Du“). Antippen → Quick Look (Datei wird nach `tmp/AISBotFiles` geladen), Links im Browser; Kontextmenü: Öffnen, Teilen, Link kopieren, Löschen. Ereignisse mit `meta.file_id` erscheinen als Dateikarte. Anhängen über „+“ → Fotos / Dateien, auf dem Mac auch per Drag & Drop und ⌘V (Bild in der Zwischenablage). Anhänge werden sofort hochgeladen (`POST /api/chats/{id}/files?name=`, max. 25 MB) und als Chips mit Fortschritt über der Eingabe gezeigt; entfernte Chips löschen die Datei wieder. Gesendet wird mit `file_ids`; Nutzernachrichten zeigen Bild-Vorschauen bzw. Datei-Chips.

**Sprache (auf dem Gerät, ohne Zusatzkosten).** Diktat: Mikrofon in der Eingabe (bei leerem Feld), Speech-Framework de-DE, auf dem Gerät wenn möglich; nochmals tippen beendet. Sprachmodus (Wellen-Knopf, nur Einzel-Scoops): großes Maskottchen mit Zuhören/Denken/Sprechen, Ende der Rede nach ~1,2 s Stille, Senden mit `"voice": true`, Antwort wird mit `AVSpeechSynthesizer` vorgelesen (Stimme des Scoops oder beste deutsche Stimme, Premium > Erweitert > Standard), danach wird wieder zugehört. Antippen unterbricht das Vorlesen, „Pause“ und „Beenden“. Profil → „Stimme“: deutsche Systemstimmen mit Qualität, Probehören, Speichern per `PATCH {"voice": …}`.

**Live-Aktivität per Push (iPhone).** Siehe „Widgets und Live Activity → Gemeinsame Live-Aktivität“. Kurz: EINE Aktivität `ScoopsLiveAttributes` für alle arbeitenden Scoops; Push-to-Start-Token mit `platform: "ios-scoops-live-start"`; Updates bevorzugt per APNs-Broadcast-Kanal, sonst Token (`POST /api/live-activities`, `chat_id: "scoops"`).

**Bot-Rechner übernehmen.** Im Vollbild des Bot-Bildschirms (Live-Miniatur oder Computer-Karte): „Übernehmen“ (`POST /api/computer/takeover`, 409-Text wird angezeigt). Während der Übernahme: Bild ~3×/s, Banner „Du steuerst“, Klick/Tippen = click, Doppelklick = double_click, Rechtsklick/langes Drücken = right_click, Ziehen = drag, Scrollrad/Trackpad/zwei Finger = scroll. Mac: Hardware-Tastatur direkt (Text als `type`, Sondertasten und ⌘-Kürzel als `key`, z. B. `super+c`). „Tastatur“-Leiste mit Textfeld und Tasten (⏎ ⌫ ⇥ Esc Pfeile ⌘C/V/A/Z) für iPhone/iPad. „Zurückgeben“ bzw. Schließen gibt zurück. Computer-Karte zeigt „Du steuerst“. Vor der Übernahme: Pinch/Doppeltipp zoomt das Bild.

**Formen.** Neben den 10 organischen „Figuren“ (`bean, pear, cloud, egg, blob, star, drop, bun, ghost, flower`; `star` ist jetzt bewusst unregelmäßig) gibt es 14 symmetrische „Formen“: `circle, oval_tall, oval_wide, square, rect_tall, rect_wide, triangle, diamond, hexagon, heart, arrow, pill, flower_round, star_soft`. Ecken sind leicht gerundet (abgerundete Polygone), der Umriss wird gleichmäßig nach Bogenlänge abgetastet, damit das Fell an Ecken nicht ausfranst. Unbekannte Formen fallen auf `bean` zurück. Geometrien werden zwischengespeichert.

## Änderungen ab API v1.2 (Build 3)

**App-Icon.** Gelber Kreis-Scoop (`Mascot.brand`: `circle`, `#FFC83D`, Punktaugen, ohne Accessoire), exakt mittig (Versatz aus der Mitte des Umrisses), auf dem Nacht-Hintergrund. Auch im Onboarding und als Widget-Platzhalter. iOS 1024 ohne Alpha, alle Mac-Größen.

**Diktat.** Nach einer Pause beginnt die Gerät-Erkennung einen neuen Abschnitt; der bisherige Text bleibt jetzt stehen und der neue wird angehängt (Abschnitte werden neu gestartet, solange diktiert wird). Parallel wird die Aufnahme als 16 kHz mono AAC (.m4a) gespeichert. Beim Beenden geht sie an `POST /api/transcribe` (Sprache de, Schreibhilfe = Namen der Scoops/Gruppen + „Arman, MLP, AIS“); der diktierte Teil wird durch den genauen Text ersetzt, Text vor dem Diktat bleibt. Währenddessen „Wird genau erkannt …“ mit Schimmer; bei Fehlern bleibt der Gerätetext. Der Sprachmodus nutzt dieselbe Erkennung (höchstens 6 s, sonst Gerätetext).

**Sofortige Rückmeldung.** „Erstellen“ schließt den Dialog sofort; der neue Scoop bzw. die Gruppe „schlüpft“ als Platzhalter in der Seitenleiste (Plopp-Animation, Wackeln, Funken), bis der Server antwortet. Doppeltes Antippen ist gesperrt. Nachrichten erscheinen sofort als halbtransparente Blase („Wird gesendet …“), werden durch die Server-Nachricht ersetzt (ohne Dublette, auch wenn der WebSocket schneller ist) und zeigen bei Fehlern „Nicht gesendet · Erneut senden“.

**Größere Kopfzeile.** Avatar in der Kapsel oben 40 pt (Gruppen 44 pt).

**Systemleiste (iPhone, iPhone Duo, iPad).** Seitenleiste und Chat haben eine System-Navigationsleiste mit „Neu“ (`square.and.pencil`, Menü Neuer Scoop / Neue Gruppe) und – solange die Tastatur offen ist – „Tastatur schließen“ (`keyboard.chevron.compact.down`). Ab iOS 27 bleibt „Neu“ per `ToolbarItemPlacement.topBarPinnedTrailing` immer sichtbar. Auf dem iPhone Duo setzt das System diese Toolbar-Einträge in seine senkrechte Leiste; dafür gibt es keine eigene Platzierung. `@Environment(\.toolbarVerticalEdge)` / `UITraitCollection.verticalBarEdge` (iOS 27.1) melden nur, an welchem Rand die Leiste liegt.

**Leistung.** Chatwechsel (Mac, Demo-Modus, während ein Scoop arbeitet; 18 Wechsel, Startargumente `-perflog -perfbench`): vorher Median 242 ms bis zum ersten Bild (max. 632 ms), jetzt 65 ms (max. 130 ms); mit offenem Profil 98 ms. Hauptursachen: `SFSpeechRecognizer` (in jeder Eingabe angelegt) und `AVSpeechSynthesizer`/Stimmenliste (im unsichtbaren Profil) blockierten den Hauptthread per Systemdienst-Aufruf; jetzt erst bei Bedarf bzw. einmal im Hintergrund geladen, das Profil wird nur aufgebaut, wenn es sichtbar ist. Außerdem: Maskottchen als Bild zwischengespeichert (`MascotImageCache`), Markdown-Parsing zwischengespeichert, Nachrichtenzeilen `Equatable` mit leichten Sprecher-Werten, Seitenleisten-Avatare ohne Dauer-Animation, Widget-Schnappschuss nicht mehr in der Root-View berechnet, sondern per `withObservationTracking` gebündelt (250 ms).

**Bot-Rechner bei schlechter Verbindung.** Bilder mit `scale`/`q` (Miniaturen 0,4, Vollbild 0,6; bei der Übernahme adaptiv 0,5–0,8 je nach Ladezeit, q 40–50), höchstens eine Anfrage gleichzeitig, 5 s Timeout, Rückfall mit Pausen. Das letzte gute Bild bleibt gedimmt sichtbar („Verbinde neu …“), danach „Keine Verbindung zum Bot-Rechner“ mit „Nochmal versuchen“; „Bot-Rechner schläft“ mit „Aufwecken“ (lädt Status und Bild neu). Eingaben während der Übernahme laufen über eine kleine Warteschlange (höchstens 20, nacheinander, blockiert nie die Oberfläche).

## Build 4 (Feinschliff)

- **Tastatur:** Der Verlauf scrollt nur senkrecht und ist unten-links verankert (`defaultScrollAnchor(.bottomLeading)`), damit beim Ein-/Ausblenden der Tastatur oder durch die senkrechte Leiste des iPhone Duo nichts waagerecht verrutscht. Die Tastatur-Sichtbarkeit kommt vom Fokus der Eingabefelder; der Verlauf-Schleier unter der Eingabe reicht nur bis zur Home-Leiste.
- **Eingabe:** Die ganze Kapsel ist Tippfläche (Leerraum fokussiert das Textfeld, Knöpfe behalten ihre Aktionen).
- **Navigationsknöpfe** auf iPhone/iPad in Textfarbe (weiß in Nacht, #111 in Hell); Links, Schalter und Akzente bleiben blau.
- **Anrufe über Lucy:** Freigaben mit `meta.kind == "call"` zeigen ein Telefon-Symbol und „Anrufen lassen“ / „Nicht anrufen“ (gleicher API-Aufruf). Unbekannte SF-Symbol-Namen aus `meta.icon` fallen auf ein Ersatzsymbol zurück.

## Build 5 (API v1.4)

- **Haupt-Scoop:** Bot-Feld `primary`. Der Haupt-Scoop trägt in der Seitenleiste eine kleine gelbe Krone und steht immer als erste Kachel (auch ohne Anheften). Profil → Aktivität → „Haupt-Scoop“-Schalter (`PATCH {"primary": …}`) mit Link „Initiative einstellen“.
- **Initiative** (Einstellungen und als Blatt aus dem Profil): „Meldet sich von selbst“, Prüfzeiten (hinzufügen/entfernen, Zeitwahl, höchstens 8, gebündelt gespeichert), Ruhezeit von–bis, „Jetzt prüfen lassen“ (`POST /api/initiative/run`, Hinweis „Mila schaut nach …“). Ohne Haupt-Scoop: Erklärung und Auswahl.
- **Fähigkeiten:** Profil → Gedächtnis zeigt oben die Fähigkeiten (eigene + geteilte, „für alle Scoops“, Nutzung/zuletzt). Antippen öffnet das Detail (Beschreibung, Schritte als nummerierte Liste), dort Bearbeiten (`PATCH`) und Löschen. Ereignisse „Fähigkeit gespeichert: …“ sind antippbar und öffnen die Fähigkeit (über `meta.skill_id` oder den Namen). WebSocket `skill.updated` / `skill.deleted`.
- **Tresor** (Einstellungen → Tresor): bei jedem Öffnen Face ID / Touch ID / Gerätecode (`LAContext`, `.deviceOwnerAuthentication`). Liste mit Titel, Domain, Benutzername, zuletzt genutzt, Schloss bei gespeichertem Passwort. Anlegen/Bearbeiten mit Titel, Webseite, Benutzername, Passwort (mit Anzeigen/Verbergen; beim Bearbeiten leer mit „Unverändert“ und nur gesendet, wenn etwas eingegeben wurde), Notiz; Löschen mit Bestätigung. iOS-Felder haben `textContentType` `.username` / `.password`, sodass Passwort-Autofill aus dem iCloud-Schlüsselbund angeboten wird.
- Startargumente: `-skill <id>`, `-initiative`, `-vault` (im Demo-Modus mit `-vaultdemo` ohne Entsperren, `-vaultaddemo` öffnet „Neuer Login“).

## Build 6 (Feinschliff, Aussehen, App-Symbole)

- **Einheitliche Sektionen („inset grouped“):** `Views/Components/Grouped.swift` mit `GroupedSection` (Überschrift in Großbuchstaben, Karte mit 18 pt Radius, Haarlinien zwischen Zeilen, Fußtext), `GroupedLabelRow`, `.groupedRow()` (mind. 44 pt), `SheetHeader`, `GroupedStack` (26 pt Abstand). Neue Tokens `groupedBackground` / `groupedCard` (Nacht #0F0F10 / #1C1C1E, Hell #F2F2F4 / #FFFFFF). Umgestellt: Initiative (Haupt-Scoop · Automatisch melden · Prüfzeiten · Ruhezeit · Jetzt prüfen), Tresor (Liste und Formular), Fähigkeit, Einstellungen, Scoop-Profil (alle drei Tabs), Gruppenprofil, Stimme.
- **Aussehen bearbeiten:** Profil → „Aussehen bearbeiten“ und Seitenleiste → „Aussehen ändern“ öffnen den Maskottchen-Editor (große Vorschau, Formen/Figuren, Farben inkl. eigener Farbe per Farbwähler, Augen, Accessoires, Name, Label). „Sichern“ schickt `PATCH /api/bots/{id}` mit `mascot`.
- **App-Symbole im Grok-Bot-Stil:** großer, exakter Kreis (Form `icon_corner`, nur fürs Symbol) mit Mitte nahe der Ecke unten links (`AppIconArtwork.cornerCenter` 0,08/0,98, Radius 0,84): ihre rechte obere Rundung ragt weit ins Bild, Ober- und rechte Kante laufen fast bis an den Rand. Gesicht mittig in der Fläche (0,47/0,55), leicht geneigt, Licht in Blickrichtung. Zwei Serien in der Auswahl: „Rund“ (Gelb als Standard, Lila, Blau, Pink, Hell; `AppIcon-<Farbe>-2`) und „Lässig“ (flauschig, Brauen, Seitenblick; `AppIcon-Blick-<Farbe>`, Fälle `blickGelb` …), Vorschau-/Dock-Bilder `IconArt-<fall>` (`AppIconVariant`, `AppIconArtwork`). „Klassisch“ ist entfallen: wer es gewählt hatte, bekommt beim Start einmalig wieder das gelbe Standard-Symbol (`AppIconVariant.legacyNames`). iOS/iPadOS: alternative Symbole (`AppIcon-Lila` …, Build-Einstellung `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` nur für iOS-SDKs), Auswahl unter Einstellungen → App-Symbol (`setAlternateIconName`). macOS: Haupt-Symbol im Finder, gewählte Variante als Dock-Symbol zur Laufzeit. Übersicht: `Screenshots/app-icons.png`.
- Startargumente: `-editlook` (Aussehen des gewählten Scoops bearbeiten), `-settingsinitiative`.

## Build 7

- **App-Symbole größer:** Der Scoop füllt die untere linke Hälfte. Körpermitte außerhalb der Ecke unten links, Radius so gewählt, dass der Fellrand knapp vor der Diagonale (oben links → unten rechts) endet; das Gesicht sitzt mittig in der sichtbaren Fläche (≈ 30 %/68 %) und ist leicht nach rechts oben geneigt.
- **Eigene Farbe** im Maskottchen-Editor: runder Regenbogen-Ring in Größe der anderen Farbfelder („+“ ohne eigene Farbe, sonst die gewählte Farbe in der Mitte), gleicher Auswahlring. Raster 6 × 32 pt mit 12 pt Abstand. iOS/iPadOS öffnet `UIColorPickerViewController` als Blatt, macOS das Farbfenster.

## Build 8 (API v1.5)

- **T3 Code:** Freigaben mit `meta.kind == "t3"` zeigen einen Hammer und „An T3 geben“ / „Nicht jetzt“ (entschieden: „An T3 gegeben“ / „Nicht gegeben“), gleicher API-Aufruf wie alle Freigaben.
- **Ereignisse mit `meta.url`** (z. B. „T3 arbeitet: …“, „T3 fertig: …“) sind antippbar, zeigen einen kleinen Pfeil ↗ und öffnen den Link über `openURL` (Links auf app.t3.codes öffnen die T3-App, wenn sie installiert ist).
- **Umbenennen:** `bot.updated` ersetzt den Scoop im Store; Seitenleiste, Kopfzeile, Gruppen-Autoren, Statuszeilen, Dateikarten, Widgets (Schnappschuss) und lokale Mitteilungen lesen Name und Aussehen immer frisch aus dem Store. Test im Demo-Modus: `-renametest` (nur Debug).

## Build 9 (API v1.6 + v1.7)

- **Bereiche in der Seitenleiste:** Reihenfolge vom Server (`GET/PUT /api/sections`), auch leere Bereiche („Scoops hierher ziehen“), danach Bereiche, die nur an Scoops hängen, zuletzt „Ohne Bereich“ (früher „Ohne Gruppe“). Kopfzeile mit Pfeil zum Ein-/Ausklappen (gespeichert per PUT `collapsed`) und Anzahl im eingeklappten Zustand. Kontextmenü der Kopfzeile: Umbenennen (`POST /api/sections/rename`), Nach oben/unten, Ein-/Ausklappen, Neuer Bereich, Bereich löschen (`DELETE`, „Die Scoops landen in ‚Ohne Bereich‘“). Kopfzeilen lassen sich auch ziehen, um Bereiche umzusortieren.
- **Zuordnen:** Zeilen per Ziehen und Ablegen auf einen Bereich (Mac, iPad; iPhone per langem Drücken und Ziehen) oder über „Verschieben nach …“ im Kontextmenü (alle Bereiche, „Ohne Bereich“, „Neuer Bereich …“). Optimistisch, dann `PATCH section`. WebSocket `sections.updated`.
- **Neuer Bereich:** „+“-Menü / Neu-Menü der Navigationsleiste, Kontextmenü auf freier Fläche der Seitenleiste.
- **Modellkatalog (Server 1.34):** Auswahl, Namen und Hinweise kommen aus `GET /api/models` (`ModelCatalogStore`, docs/modelle.md); `BotModel` ist nur noch Rückfall für ältere Server. Neue Modelle brauchen keinen App-Build.
- **OpenAI-Modelle:** Modellwahl in zwei Sektionen „Claude (Anthropic)“ und „OpenAI“ (GPT-6 Luna, GPT-6.1 Sol, GPT-6.1 Terra, GPT-6 Astra), auch im Anlege-Dialog. Im Profil Kennzeichen „Claude“/„OpenAI“ + Modellname. Unbekannte Kennungen werden roh angezeigt (eigene Sektion „Weiteres Modell“). Kosten zeigen die Modellnamen.
- Krone des Haupt-Scoops sitzt jetzt unten rechts neben der Kachel (überdeckt kein Accessoire).
- Behoben: Absturz auf iOS beim langen Drücken einer Zeile (Ziehen-Vorschau las Umgebungswerte außerhalb von `body`).

## Build 10 (API v1.8)

- **Apps verbinden** (Einstellungen → „Apps verbinden“, eigenes Blatt `ConnectionsView`, Startargument `-connections`, `-connectionsmore` klappt „Weitere Apps“ auf): `GET /api/connections` (beim Öffnen `?fresh=true`).
  - „Deine Apps“: je App eine Karte (SF-Symbol aus `symbol`, Name, `detail`), Konten als Zeilen (Alias oder „Standard“, E-Mail klein, Statuspunkt: aktiv grün; abgelaufen/fehlgeschlagen orange mit „Neu anmelden“; initiated/initializing grau „Anmeldung läuft“). Menü (•••), Kontextmenü und auf dem iPhone Wischen: Umbenennen (`PATCH`), Neu anmelden (`POST …/reconnect`), Trennen (`DELETE`, Rückfrage „Die Scoops können dieses Konto dann nicht mehr nutzen.“). „Konto hinzufügen“ ist bei `can_add == false` gesperrt („Höchstens 10 Konten pro App“).
  - Apps ohne Konto eingeklappt unter „Weitere Apps“ mit „Verbinden“.
  - Ablauf: optionaler Name („privat, arbeit“), `POST /api/connections/{app}/link`, Anmeldung in `ASWebAuthenticationSession`, Status alle 3 s per `GET /api/connections/accounts/{id}`. Bei `active` schließt das Fenster, Meldung „Gmail · privat verbunden“, Liste neu mit `fresh=true`. Wird das Fenster ohne Erfolg geschlossen, löscht die App das gerade angelegte Konto, falls es noch `initializing`/`initiated` ist (keine Leichen), und lädt neu. Serverfehler (409, 502) erscheinen als Text unter dem Titel.
  - „Fest verbunden“ (`builtin`): nur Anzeige mit Statuspunkt und „121 Werkzeuge“.
  - Fußzeile: „Die Anmeldung läuft sicher über Composio. Die Scoops sehen nur die Konten, nie deine Passwörter.“
  - Demo-Modus: Gmail mit drei Konten (eins abgelaufen), Notion, Google Kalender mit laufender Anmeldung, weitere Apps, sechs feste Verbindungen. Neue Demo-Konten werden nach etwa 6 s aktiv.
- **iPhone-Seitenleiste:** In kompakter Breite (iPhone, iPhone Duo zugeklappt) höhere Zeilen (ca. 89 pt) mit 62-pt-Maskottchen, Titel 19 pt halbfett, Vorschau 16 pt, mehr Abstand zum Rand. Gilt für Scoops, Gruppen und Platzhalter beim Schlüpfen. iPad und Mac unverändert, angeheftete Kacheln unverändert.
- Behoben: Das Stapelbild von Gruppen mit drei oder mehr Mitgliedern (z. B. „Alle“) wurde unten abgeschnitten; die Mitglieder passen jetzt vollständig in den Rahmen.
- Screenshots: `mac-{nacht,hell}-apps-verbinden.png`, `mac-nacht-apps-verbinden-weitere.png`, `iphone-{nacht,hell}-apps-verbinden.png`, `iphone-seitenleiste-{vorher,nachher}.png`.

## Build 11 (API v1.9)

- **Name „AIS Scoops“:** `PRODUCT_NAME`, `CFBundleDisplayName` und `CFBundleName` der App (iOS, iPadOS, Mac → `AIS Scoops.app`, Mac-Menü und Dock), Anzeigename der Widget-Erweiterung, Fenstertitel, Onboarding („Willkommen bei AIS Scoops“), Einstellungen/Über, Mitteilungs-Rückfalltitel, Widget-Leerzustand und alle Berechtigungstexte (Mikrofon, Spracherkennung, Face ID, Fotos, lokales Netzwerk). Unverändert: Bundle-IDs `com.ais.aisbot` / `.widgets`, App Group `group.com.ais.aisbot`, URL-Schema `aisbot://`, Target- und Schema-Namen (`AISBot`, `AISBotWidgets`), Modulname (`PRODUCT_MODULE_NAME: AISBot`), interne Typnamen. Geprüft mit unsignierten Release-Archiven (iOS und macOS): `Products/Applications/AIS Scoops.app`, Widget eingebettet, Bundle-ID unverändert. `scripts/upload-testflight.sh` und die ExportOptions hängen nicht am Produktnamen. Der App-Name in App Store Connect wird dort separat gepflegt.
- **Chat-Ränder auf iPad/iPhone Duo:** Ursache für „Nachrichten kleben am linken Rand“ (Widget-Link, Seitenleiste auf/zu, Drehen, Auf-/Zuklappen; gemessen im iPad-Simulator mit einem Geometrie-Protokoll): Bei jeder Breitenänderung richtet SwiftUIs Scroll-Verankerung (`defaultScrollAnchor(.bottomLeading, for: .sizeChanges)` mit `scrollTargetLayout`) die linke Kante des Anker-Ziels (einer Zeile) an der linken Sichtkante aus und scrollt dafür auch **waagerecht**, obwohl der Verlauf nur senkrecht scrollt. Die Zeilen waren eine mittige 560-pt-Spalte mit 16 pt Rand, also blieb `contentOffset.x` danach bei 137 pt (Seitenleiste zu) bzw. 16 pt (wieder auf) stehen: Der ganze Verlauf war um diesen Betrag nach links verschoben, das Eingabefeld (außerhalb des ScrollViews) nicht. Lösung: Jede Zeile ist jetzt volle Breite ab x = 0 und setzt Rand und Lesespalte erst innen (`chatColumn`), oben/unten als `contentMargins`. Damit gibt es nichts mehr waagerecht auszurichten, egal wodurch sich die Breite ändert. Dieselbe Verankerung rechnete außerdem die unteren Insets (Eingabefeld) doppelt (rund 91 pt leere Fläche über der Eingabe): Stand der Verlauf am Ende, rückt er nach einer Breitenänderung wieder ans Ende. Geprüft im iPad-Simulator (Hoch-/Querformat, Seitenleiste mehrfach auf/zu, Deeplink `aisbot://bot/…` wie vom Widget, Eingabefeld fokussiert). Das iPhone Duo lässt sich im Simulator nur über den Scharnier-Regler in DeviceHub aufklappen (nicht automatisierbar); dort greift derselbe Mechanismus.
- **iPad/Duo-Seitenleiste:** Die großen iPhone-Zeilen hängen jetzt an `SidebarView(standalone:)` (Stapel-Navigation) statt an der Size-Class, denn die Seitenleisten-Spalte eines Split-Views meldet auf dem iPad ebenfalls „compact“. Aus demselben Grund erscheint „Tastatur schließen“ nur noch beim Chat und nicht zusätzlich in der Seitenleiste (verdrängte dort den Titel „Scoops“).
- **Bot-Rechner „Neu versuchen“:** Der Knopf wartete vorher erst auf `GET /api/computer` (bis 20 s Timeout bei nicht erreichbarem Server), ohne Rückmeldung; zudem lag der Doppeltipp-Zoom als exklusive Geste über dem Bild. Jetzt: sofort „Verbinde …“, laufender Abruf und Wartezeit werden abgebrochen, Fehlerzähler zurückgesetzt, Rechner-Zustand parallel neu abgefragt, Bild-Schleife neu gestartet (`ScreenFeed.restart`). Die Schleife besitzt ihre Task selbst, endet nur beim Schließen und wartet bei fehlendem Dienst, statt still zu enden. Automatisches Wiederverbinden mit Rückfall 2 s, 3 s, 5 s, 8 s, dann alle 10 s; nach Erholung läuft das Bild ohne Zutun weiter und der Rechner-Zustand wird aufgefrischt. Hinweis „Wird automatisch weiter versucht.“ Doppeltipp-Zoom als `simultaneousGesture`.
- **Andere „Neu versuchen“-Knöpfe:** Seitenleiste offline → kompletter Neuaufbau mit Generationszähler (ein älterer, noch laufender Aufbau setzt keinen Zustand mehr und öffnet keinen zweiten Live-Kanal), sichtbar „Verbinde …“. Live-Kanal (WebSocket): Rückfall jetzt 2–10 s statt bis 30 s, fehlgeschlagener Ping löst sofort Neuverbinden aus (halb offene Verbindung nach Server-Neustart), „Neu versuchen“ im Hinweis „Verbinde neu …“ und beim Zurückkehren in die App sofortiges Neuverbinden. Apps verbinden: „Neu versuchen“ zeigt Ladeanzeige, ist währenddessen gesperrt und meldet fehlende Serververbindung.
- **Demo:** `-screenfaildemo [Sekunden]` (nur mit `-mock`) öffnet die Bildschirmansicht mit simuliertem Ausfall (Standard 20 s).
- **Mail-Karte (API v1.9, `meta.kind == "mail"`, `MailCard`):** Kopf mit Brief-Symbol und „Mail“ bzw. „Antwort“ (`thread_id` gesetzt, Betreff dann nur Anzeige). Formular direkt in der Karte: Von (Menü aus den aktiven Gmail-Konten von `GET /api/connections`, Name + Adresse), An, Cc (nur wenn vorhanden oder über „Cc“ hinzugefügt), Betreff, mehrzeiliger Text (lange Texte eingeklappt mit „Mehr“/„Weniger“). „Abbrechen“ (sekundär) → `{"decision":"decline"}`, „Senden“ (primär, wie der Senden-Knopf) → `{"decision":"approve","edits":{…}}` mit nur den geänderten Feldern (`account` = Alias). Zustände aus `mail.status`: draft (bearbeitbar), sending („Wird gesendet …“, sofort optimistisch), sent (kompakt, grüner Haken „Gesendet an … · 12:14“, aufklappbar), failed (Fehlertext), discarded (kompakt, grau „Verworfen“). Ältere Freigaben ohne `mail` zeigen weiter die normale Freigabe-Karte.
- **Reaktionen (v1.9):** Langes Drücken bzw. Rechtsklick: Emoji-Leiste (❤️ 👍 😂 😮 😢 🙏) ganz oben im Kontextmenü (`Picker` im Palette-Stil, schließt nach der Auswahl), darunter „Weitere Emojis …“ (Emoji-Feld mit Auswahl und Eingabe; Mac zusätzlich „Emoji & Symbole“) und „Kopieren“. Doppeltipp = ❤️ (iOS, simultan, Links bleiben antippbar). Mac: Smiley-Knopf neben der Blase beim Überfahren mit derselben Leiste. Kapsel unten an der Blase (wie WhatsApp), gleiche Emojis zusammengefasst mit Anzahl, eigene Reaktion hervorgehoben; Tippen entfernt die eigene (`PUT /api/messages/{id}/reaction` mit `{"emoji": null}`). Reaktionen von Scoops (`meta.reactions["b_…"]`) erscheinen genauso. Sofort optimistisch, bei Fehler zurück. Gleiche Reaktion noch einmal wählen entfernt sie.
- **Plus-Menü:** kompakte, abgerundete Karte als Popover über dem Plus (iOS ohne Blatt, `presentationCompactAdaptation(.popover)`): „Dateien anhängen“, „Fotos anhängen“, Linie, „Routine anlegen“, „Erinnerung“, „Was weißt du über mich?“; Symbol links, Text rechts, dezente Hervorhebung beim Drücken bzw. Überfahren. Das Plus dreht sich beim Öffnen zum ×.
- **Scoops schreiben Scoops (v1.9):** In Einzelchats Nachrichten mit `meta.peer == true` (oder `author_id` ≠ Chat-Scoop) als Blase mit 1,75 pt Rahmen in der Maskottchenfarbe des Autors, darüber Mini-Maskottchen und Name. Ereignisse mit `meta.peer_out` („An Tina: …“) dezent mit Pfeil und Mini-Maskottchen des Ziels.
- Demo-Daten: Mila (Mail-Entwurf, Reaktionen, Ereignis „An Theo: …“, Antwort von Theo mit Rahmen), Theo (Nachricht von Mila), Nora (Mails gesendet, verworfen, fehlgeschlagen, Antwort-Entwurf mit Cc; Adressen mit „fehler“ scheitern beim Senden). Startargumente nur für Demo/Screenshots: `-plusmenu` (Plus-Menü offen), `-scrollto <Nachrichten-ID>`.
- Screenshots: `ipad-chat-raender-vorher*.png`, `ipad-chat-raender-nachher*.png`, `iphone-bildschirm-keine-verbindung.png`, `iphone-bildschirm-verbinde.png`, `iphone-bildschirm-wieder-live.png`, `iphone-zweite-erwaehnung.png`, `{mac,iphone}-{nacht,hell}-mail-zustaende.png`, `iphone-{nacht,hell}-mail-entwurf.png`, `mac-nacht-mail-wird-gesendet.png`, `mac-hell-mail-gesendet.png`, `{mac,iphone}-{nacht,hell}-scoop-nachricht-reaktionen.png`, `iphone-nacht-reagieren-menue.png`, `iphone-nacht-reaktion.png`, `{mac,iphone}-{nacht,hell}-plus-menue.png`.

## Build 12 (Tastatur)

- **@-Erwähnungen per Tastatur** (`ComposerView`): Bei offener Vorschlagsliste bewegen ↑/↓ eine sichtbare Auswahl (Zeile in `theme.selection`, auf dem Mac zusätzlich „↵“), die umläuft. Enter oder Tab übernimmt den gewählten Scoop und sendet nicht, Esc schließt die Liste, ohne den Text zu ändern (erst ein neues „@“ öffnet sie wieder). Die Auswahl startet beim ersten Treffer und springt dorthin zurück, sobald sich die Trefferliste ändert. Ohne Liste bleibt alles wie bisher: Enter sendet, ⇧/⌥Enter macht einen Zeilenumbruch, Pfeile und Tab gehören dem Textfeld. Maus und Touch funktionieren weiter. `mentionQuery(in:)` (mehrere Erwähnungen, auch nach Komma/Zeilenumbruch) ist unverändert.
  - Behoben dabei: Die Erwähnung wird in einem Schritt eingesetzt. Vorher änderte `insertMention` den Text zweimal (kürzen, dann anhängen); das Mac-Textfeld übernahm während eines Tastendrucks nur eine Änderung („Hi @@alle“). Außerdem ging Return auf dem Mac teils über `onSubmit` und sendete trotz offener Liste; `onSubmit` übernimmt jetzt ebenfalls den Vorschlag.
- **Befehlspalette ⌘K** (`Views/CommandPalette.swift`, Ebene über dem Fenster statt Blatt): Suchfeld, gruppierte Treffer mit Symbol (getönte Kachel bzw. Maskottchen), Titel, Untertitel und Tastenkürzel als Tastenkappen; Fußzeile „↑↓ Auswählen · ↵ Öffnen · esc Schließen“. ↑/↓ (auch Tab/⇧Tab) laufen um, Enter führt aus, Esc oder Tippen daneben schließt. Unscharfe Suche über Titel und Stichwörter (`Fuzzy`: Präfix > Wortanfang > Teilstring > Teilfolge ab einem Wortanfang, ohne Groß-/Kleinschreibung und Umlaute; Titeltreffer schlagen Stichwörter). Der beste Abschnitt steht oben, damit Enter sofort das Richtige tut.
  - **Chats:** alle Scoops und Gruppen (ohne Suche die sechs zuletzt aktiven), auch aus eingeklappten Bereichen; Enter öffnet den Chat.
  - **Aktionen:** Neuer Scoop (⌘N), Neue Gruppe (⌘⇧N), Neuer Bereich, Aussehen des gewählten Scoops bearbeiten, Profil ein/aus (⌘I), Bildschirm des Bot-Rechners, Initiative „Jetzt prüfen lassen“ (`POST /api/initiative/run`, Hinweis „Mila schaut nach …“; ohne Haupt-Scoop öffnet sich das Initiative-Blatt), Apps verbinden, Tresor, Einstellungen (⌘,), Seitenleiste ein/aus (⌃⌘S, nicht auf dem iPhone), Zu Hell/Nacht wechseln, Chats durchsuchen (⌘F). Nur vorhandene Blätter, Store-Funktionen und Endpunkte.
  - **Nachrichten in geladenen Chats:** Eine Server-Suche gibt es nicht; die Palette durchsucht lokal die bereits geladenen Nachrichten (ab 2 Zeichen, neueste zuerst, höchstens 8, Treffer fett). Enter öffnet den Chat, scrollt zur Nachricht und hebt sie kurz hervor (`pendingScrollMessageID`).
  - **Erreichbar:** Mac-Menü „Darstellung → Befehlspalette …“ (⌘K, dort auch „Seitenleiste ein-/ausblenden“ ⌃⌘S); iPad mit Tastatur ⌘K; iPhone über den ⌘-Knopf neben der Suche in der Seitenleiste; iPhone und iPad zusätzlich im „Neu“-Menü („Befehle …“). Auf dem iPhone füllt die Palette den Bereich über der Tastatur und hat „Abbrechen“; Aktionen, die die Seitenleiste brauchen (Neuer Bereich, Suche), gehen vorher dorthin zurück.
  - Die Spalten des Split-Views liegen jetzt im Store (`sidebarColumns`), damit Palette und Menü die Seitenleiste schalten können. ⌃⌘S ist nur auf dem Mac ein eigener Menübefehl: iPadOS belegt das Kürzel selbst, ein zweiter Befehl ließ UIKit beim Aufbau des Tastaturmenüs abstürzen (gefunden im Simulator, behoben).
- **@-Hervorhebung in Blasen** (`Mentions` in `MarkdownView.swift`): Die Schriftfarbe wird je Theme auf Kontrast gebracht (`Mentions.readable`, WCAG-Kontrast gegen die kontrastärmere Blase #E4E4E7 bzw. #2E2E31: Hell mind. 3,5 : 1 durch Abdunkeln, z. B. Lios Gelb → Bernstein; Nacht mind. 4,2 : 1 durch Aufhellen, z. B. dunkles Lila). Der zarte Hintergrund behält die echte Maskottchenfarbe.
- **Demo:** Gruppe „Launch-Team“ hat zwei neue Nachrichten mit „@Mila … @Theo … @Lio“ (Nutzer und Mila). Startargument `-palette` öffnet die Palette.
- **Getestet:** Mac (Demo, Tastatur per Bedienungshilfen): Pfeile/Umlauf, Enter/Tab übernehmen, Esc, Klick, Enter sendet ohne Liste, ⇧Enter; Palette mit Pfeilen, Umlauf, Suche, Chat öffnen, Nachricht anspringen, Seitenleiste, Theme, Neue Gruppe, Einstellungen, Initiative. iPhone-Simulator: ⌘-Knopf und „Befehle …“, Suche, Enter über die Bildschirmtastatur, „Chats durchsuchen“, Erwähnungsfarben Nacht/Hell. iPad-Simulator: Palette, Layout der Leiste. Nicht automatisierbar: Pfeiltasten/⌘K mit Hardware-Tastatur im iOS-Simulator (die Werkzeuge senden nur Text, Tab und Return) – gleicher Code wie auf dem Mac, bitte einmal am iPad mit Tastatur prüfen.
- Screenshots: `mac-{nacht,hell}-befehlspalette.png`, `ipad-nacht-befehlspalette.png`, `mac-nacht-erwaehnung-pfeiltasten.png`, `iphone-{nacht,hell}-erwaehnung-farbe.png`.

### Accessoires

- **15 neue Accessoires** (gleicher Plüsch-Stil, nur einfache Pfade und Verläufe, keine Weichzeichner): Kopf `beanie` (Bommelmütze), `tophat` (Zylinder), `cowboy` (Cowboyhut), `partyhat` (Partyhut), `wizard` (Zauberhut), `halo` (Heiligenschein), `hair_bow` (Haarschleife), `cat_ears` (Katzenohren), `bunny_ears` (Hasenohren), `horns` (Hörnchen), `headset` (Headset mit Mikrofon); Gesicht `sunglasses` (Sonnenbrille), `monocle` (Monokel); Hals `tie` (Krawatte), `scarf` (Schal). Liste und deutsche Namen in `Mascot.accessories`, `Mascot.accessoryGroups`, `Mascot.accessoryName(_:)` (`Models.swift`). Der Server speichert den Wert als freien Text, keine Serveränderung nötig. Ältere Builds zeigen unbekannte Werte einfach ohne Accessoire.
- **Sitz auf allen 24 Formen** (`MascotPainter` in `MascotView.swift`): Hüte liegen jetzt auf einer gemeinsamen Auflage `hatSeat(width:)`: Median der Kopfoberkante unter der Krempe, schmale Spitzen (Stern, Dreieck, Tropfen, Raute) werden überdeckt, die Kerbe des Herzens überbrückt (vorher rutschten Mütze, Kappe und Krone dort bis an die Augen), nie tiefer als knapp über den Augen. Neigung folgt der Kopflinie (Bohne, Klecks), Größe der Kopfbreite (0,8–1,15). Hohe Hüte werden verkleinert, damit sie höchstens 0,05 über den Rahmen ragen. Ohren/Hörnchen/Schleife/Blume sitzen per `headPoint(atX:)` auf dem Umriss und folgen dessen Normale.
- **Baskenmütze korrigiert:** war zu klein, nach rechts verschoben und dabei rechts angehoben (rutschte optisch vom Kopf), bei der Bohne über 20° schief. Jetzt flach und bauschig, nach rechts überstehend und dort etwas tiefer (ca. 7°), Band auf dem Kopf, Zipfel oben in der Mitte (`baskenmuetze-vorher.png` / `baskenmuetze-nachher.png`).
- **Weitere Korrekturen:** Brille (und neue Sonnenbrille/Monokel) nutzt dieselbe Augenlage wie das Gesicht (`eyeLayout`); vorher saßen die Gläser bei kleinen Größen (< 60 pt, Augen größer und weiter auseinander) neben den Augen. Kopfhörer-Bügel liegt hinter dem Kopf (nur außerhalb des Umrisses sichtbar) statt quer über Pfeil und Stern, Hörer bei Sternen nicht mehr an den Zackenspitzen. Blume sitzt beim Herz auf dem Bogen statt neben dem Auge. Monokel mit dunklem Rand, damit es auf Gelb erkennbar bleibt.
- **Nicht abgeschnitten:** Die Gesichts-/Accessoire-Ebene hat mit Accessoire 15 % Rand (`MascotFace.overflow`); ohne Accessoire bleibt sie unverändert, das App-Symbol ist pixelgleich zu vorher (geprüft).
- **Auswahl** (Neuer Scoop und „Aussehen bearbeiten“): gruppiert in Kopf, Gesicht, Hals; Raster mit Vorschau am gewählten Scoop (Form, Farbe, Augen) und kurzem Namen.
- **Aufwand:** Accessoires laufen wie bisher in der leichten Gesichtsebene; Fell-Körper und Bildcache unverändert. Pro Bild nur einige Pfade, ein Ankerpunkt-Durchlauf über 240 Umrisspunkte; kleine Details (Rippen, Nähte, Glanz) erst ab 60 pt.
- **Prüfen:** `AIS_RENDER_ONLY=accessories "…/AIS Scoops" -render-assets <Ordner>` (unsignierter Build) rendert nur `accessoires-uebersicht-{nacht,hell}.png` (alle Formen × alle Accessoires, dazu 30/44/62/104 pt) und je Accessoire ein Prüfblatt `check-<id>.png` (alle Formen in 104, 62, 44, 30 pt). Ohne Umgebungsvariable kommen sie zusätzlich zu Icon und Widgets.
- Screenshots: `accessoires-uebersicht-nacht.png`, `accessoires-uebersicht-hell.png`, `baskenmuetze-vorher.png`, `baskenmuetze-nachher.png`, `iphone-nacht-accessoire-auswahl.png`.

### Augenstile (2026-11)

- **Eine Gruppe „Augen“** im Maskottchen-Editor, die fünf gezeichneten Stile vorne (Vorbild Key Visual), danach der verbliebene klassische Stil. Nur Wimpern und Katzenaugen haben Wimpern, keine Wangen per Standard (Schalter „Rote Wangen“ bleibt).

  | Wert | Name | Zeichnung | Standardblick |
  |---|---|---|---|
  | `lashes` | Wimpern | waagerecht, weit offen, Lidschwung und zwei Wimpern außen, feine hohe Brauen (pinkes Herz) | links |
  | `cat` | Katzenaugen | mandelförmig, außen hochgezogen, kräftiger Lidstrich mit langem Schwung, Wimpern (Creme) | links |
  | `relaxed` | Verträumt | Oberlid fast gerade bis über die Pupillenmitte, gerade Brauen mit Abstand (Gelb, Koralle) | rechts |
  | `focused` | Ernst | offen, gerades, leicht gesenktes Lid, Unterlid hebt sich, kräftige gerade Brauen tief, auch klein sichtbar (Violett) | geradeaus |
  | `dashes` | Striche | zwei senkrechte, abgerundete Stäbchen, feine Bögen darüber, ohne Blickrichtung, Mund standardmäßig Lächeln (Stern, Dreieck) | – |
  | `happy` | Zufrieden | klassische geschlossene Bögen (unverändert) | – |

- **Nicht mehr angeboten** (`Mascot.retiredEyeStyles`, nur beim Zeichnen zugeordnet, der gespeicherte Wert bleibt bis zur nächsten Änderung im Editor; der Editor zeigt den Nachfolger als gewählt): `skeptical`, `calm`, `sleepy` → `relaxed`; `dots`, `ovals`, `diamonds` → `dashes`; `sparkle` → `lashes`. Ausnahme: Das App-Symbol (`icon_corner`) behält seine Knopfaugen.
- **Schlüssel:** `lashes`, `relaxed` und `focused` bleiben (passende Bedeutung, gespeicherte Scoops behalten den Wert), `cat` und `dashes` sind neu. Ältere App-Versionen zeichnen unbekannte Werte als Punktaugen.
- **Zufall** wählt nur noch aus den fünf neuen Stilen. Der Server kennt keine Augenlisten (nur `dots` als Standard neuer Scoops, wird als Striche gezeichnet).
- **Mitteilungsbilder:** `NotificationAvatars.renderVersion` = 2, damit vorhandene Bilder einmal neu entstehen.
- **Prüfen:** `AIS_RENDER_ONLY=eyes "…/AIS Scoops" -render-assets <Ordner>` schreibt `augen-varianten.png` (alle Stile auf acht Formen in 120 pt, 44/36/32/28 pt dunkel und hell, Blickrichtungen, Zuordnung der alten Werte, Key-Visual-Nachbau). Ohne App-Start geht es auch per `swiftc` aus `Shared/**` und `MascotStyleSheet.swift` mit einem kleinen `main`, das `EyeVariantsSheet` per `ImageRenderer` schreibt.

### Profil-Seitenleiste ohne Ruckeln (Leistung)

- **Gemessen** am Mac (Demo, Chat „Mila“ mit laufendem Lauf und Live-Bild, Fenster 1440 × 900, optimierter Build `-O`, je 12 × Ein-/Ausfahren, vorher/nachher abwechselnd zweimal): Hauptthread-Arbeit je Runloop-Durchgang, gezählt werden Durchgänge über 8,3 ms (= ein verpasstes Bild bei 120 Hz/ProMotion; der Testmonitor hat nur 60 Hz, deshalb diese Metrik statt Display-Link-Abständen).

  | | vorher | nachher |
  |---|---|---|
  | Einfahren: Durchgänge > 8,3 ms (Median) | 20–21 | 7–7,5 |
  | Einfahren: längster Block (Median / max) | 87 / 129 ms | 39–47 / 61 ms, jetzt **nach** der Gleitbewegung |
  | Ausfahren: Durchgänge > 8,3 ms (Median) | 14–15 | 8,5–10 |
  | Ausfahren: längster Block (Median / max) | 55 / 62 ms | 23–26 / 36 ms |

  Während der eigentlichen Gleitbewegung (+50 bis +350 ms) liegen jetzt fast alle Bilder bei 8–10 ms (Rest: AppKit-Split-View plus laufende Maskottchen-Animationen). iPad-Simulator (nachher, optimiert): lange Durchgänge nur beim Anlegen der Spalte (UIKit) und beim verzögerten Profil-Aufbau, nicht in der Bewegung.
- **Ursachen** (Instruments: SwiftUI- und Time-Profiler-Vorlage, `xctrace`; Gegenproben mit leerem Profil, ruhigem Chat, ohne Verlauf/Eingabe):
  1. Der Chat wird in jedem Bild der Animation schmaler/breiter. SwiftUI vermaß und verschob dabei jede sichtbare Zeile (seit Build 11 sind Zeilen volle Breite und zentrieren innen), dazu Eingabefeld (AppKit-Textfeld) und Scroll-Verankerung. Ohne Verlauf fielen die zu langen Bilder von 14 auf 2, in Chats mit wenig Inhalt gab es nur 2 – die Kosten wuchsen mit dem sichtbaren Inhalt (Attribut-Graph, Layout, Display-Liste; der eigene Code war < 3 % davon).
  2. Das Profil baute sich im ersten Bild komplett auf (Schalter, Menüs, Textfeld, Bot-Rechner-Vorschau, animiertes 104-pt-Maskottchen): rund 50 ms Block. Beim Schließen wurde es sofort abgebaut (ebenfalls ~50 ms) und die Spalte glitt leer hinaus.
  3. Das Umschalten wertete den ganzen `ChatView.body` neu aus (die Mac-Kopfzeile las `showInspector`), das Profil lud beim Öffnen Gedächtnis/Routinen/Rechner/Bibliothek/Fähigkeiten neu und schrieb sie auch unverändert in den Store (invalidiert z. B. Live-Vorschauen).
- **Umsetzung:**
  - `ColumnTransitionStabilizer` / `StableWidthLayout` (`Views/Chat/StableWidth.swift`): Beim Umschalten von Profil oder Seitenleiste behält Verlauf + Eingabe die Breite vom Anfang und wird als Ganzes mittig gesetzt; 120 ms nach dem letzten Breitenwechsel (spätestens 1,2 s) wieder live. Nur wenn die Lesespalte voll ist (Breite ≥ 632 pt), sonst folgt der Chat live wie bisher (kein Umbruch-Sprung, z. B. iPad hochkant). Innerhalb des ScrollViews ändert sich nichts: Die Zeilen bleiben bei x = 0, der Build-11-Fix gegen seitliches Verschieben bleibt unberührt (geprüft am iPad: Profil und Seitenleiste auf/zu, Hoch-/Querformat).
  - Profil (`ProfileView`, `GroupProfileView`): zuerst nur Kopf (Maskottchen statisch aus dem Bildcache) und Tabs, nach 380 ms die oberen Sektionen, 60 ms später Modellwahl/Stimme/Charakter/Verwalten (`ProfileSettle`); Auffrischen der Daten erst danach. Beim Schließen bleibt der Inhalt mit fester Breite stehen und gleitet mit hinaus, Fell-Animation und Bot-Rechner-Abfragen halten sofort an; abgebaut wird 450 ms später (`InspectorContent` in `RootView.swift`).
  - Mac-Kopfzeile als eigene View (`ChatMacHeader`); Breiten-Nachrücken ans Ende gedrosselt (vorher eine Task pro Bild); `loadProfile`, `loadFiles`, `loadSkills`, `refreshComputer` und `computer.updated` schreiben nur noch geänderte Werte.
- **Messhilfe (nur Debug):** `-inspectorbench [n]` setzt das Fenster auf 1440 × 900 und fährt das Profil n-mal ein und aus (wie ⌘I), Ausgabe `[inspector] …` auf stdout (Mac, z. B. `open --stdout <datei> -a …`) bzw. Systemprotokoll (iOS-Simulator). Dazu `-benchverbose` (jeder lange Durchgang mit Zeitpunkt), `-benchidle` (gleiche Messung ohne Umschalten), `-benchdelay <s>`. Signposts „auf“/„zu“ unter Points of Interest für Instruments. Hinweis: Mit `open` gestartet zeigt die App teils kein Fenster (Fensterwiederherstellung); ein zweites `open -a <app>` öffnet es.

### Tresor-Formular (API v1.10)

- **Karte** `VaultCard` (`Views/Chat/VaultCard.swift`) für `role: "approval"` mit `meta.kind == "vault"` und `meta.vault` (`VaultForm` in `Models.swift`), gestaltet wie die Mail-Karte: Schlüssel-Symbol, „Tresor · Login anlegen“, Titel, Formular mit Webseite (Domain, öffnet die URL), Benutzer (vorbelegt aus `vault.username`, `.textContentType(.username)`) und Passwort (`SecureField`, Auge zum Einblenden, `.textContentType(.password)` – iOS bietet die Schlüsselbund-Leiste „Passwörter“ an), Hinweis „Kein Scoop sieht das Passwort.“, Knöpfe „Abbrechen“ und „Im Tresor speichern“ (gesperrt ohne Passwort; Return im Passwortfeld speichert).
- **Speichern:** vorher Face ID / Touch ID / Gerätecode wie beim Tresor (`DeviceAuth`), dann `POST /api/approvals/{id}` mit `{"decision":"approve","edits":{"username":…,"password":…}}` (`decideVault`, `VaultEdits`). Das Passwort wird vor dem Senden aus dem Zustand der Karte genommen und nur für diese eine Anfrage gehalten; `VaultEdits` gibt es in `description`/`debugDescription` nie aus, Anfragen werden nicht protokolliert. Fehlertexte des Servers (`{"error": …}`, z. B. 400) erscheinen rot unter dem Formular, das Passwortfeld ist danach leer. „Abbrechen“ sendet `{"decision":"decline"}`.
- **Zustände** aus `vault.status`: pending (Formular), saved (kompakt, grüner Haken „Im Tresor gespeichert“, darunter Titel · Domain · Benutzer), declined (kompakt, grau „Nicht gespeichert: …“). Ohne `vault.status` wird aus `meta.state` abgeleitet.
- **Demo** (Lio): gespeicherte, abgelehnte und offene Karte; Speichern simuliert Server (Passwort Pflicht, Passwort „fehler“ liefert einen 400-Fehlertext), danach Ereignis „Login gespeichert: …“ und Lio macht weiter. `-vaultdemo` überspringt im Demo-Modus Face ID; nur Debug + Demo: `-vaulttestpassword <pw>` belegt das Passwortfeld vor (Test ohne Tastatur).

### Nur die neueste Live-Karte läuft

- `StatusRow.RunRole` (berechnet einmal pro Chat in `ChatView`): Nur die neueste laufende Statuskarte des Chats zeigt das Live-Bild (`ScreenThumbnail`); ältere Karten zeigen keins, ihre Bild-Abfrage endet (die Abruf-Schleife hängt am sichtbaren Bild und stoppt beim Entfernen, es gibt keine Timer pro Karte), ihr Maskottchen ist statisch.
- Abgeschlossene Läufe (done/stopped/failed) zeigen nie „Live“ und klappen von selbst ein (von Hand aufklappbar): „Fertig · 37 s · 7 Schritte“, „Angehalten“, „Fehlgeschlagen“. `stopped` mit `meta.interrupted == true` (Server-Neustart) zeigt dezent „Abgebrochen“ mit eigenem Symbol und Tooltip. Steht ein älterer Lauf noch auf „running“, obwohl derselbe Scoop schon einen neueren begonnen hat (verpasstes Update), erscheint er als „Beendet“. In Gruppen dürfen mehrere Scoops gleichzeitig laufen; Live hat nur der neueste.
- Demo (Theo): fertiger Lauf mit Bot-Rechner, abgebrochener (Server-Neustart), angehaltener, veralteter „running“-Lauf und ein aktueller Lauf mit Live-Bild.

### OpenAI-Modelle

- Reihenfolge nach Stärke (Luna, Terra, Sol, Astra) kommt aus `BotModel.allCases` und erscheint so im Erstellen-Dialog und im Profil (geprüft). Fußtext im Profil korrigiert: „Bei Bedarf gibt jeder an den nächststärkeren ab: Luna → Terra → Sol → Astra.“

### Getestet (Build 12, Leistung/Tresor/Live-Karten)

- Mac (Demo, Bedienung per Bedienungshilfen): Tresor speichern (Erfolg, Server-Fehler, Abbrechen), Zustände in Nacht und Hell, Live-Karten in Theo, Profil auf/zu mit Messung, Reihenfolge der Modellwahl. iPhone-Simulator (Hell): Karte, Tippen ins Passwortfeld (Schlüsselbund-Leiste erscheint), Speichern über Return. iPad-Simulator: Profil-Spalte hoch/quer auf/zu, Seitenleiste auf/zu, Messung.
- Nicht getestet: Face ID / Touch ID vor dem Speichern (braucht echten Finger/Gerät; der Simulator hat keinen Gerätecode), echte Server-Antworten v1.10 (der echte Server wurde nicht beschrieben), Messung auf 120-Hz-Display (Testmonitor 60 Hz; die Metrik zählt deshalb Hauptthread-Durchgänge über 8,3 ms).
- ~~Offen~~ in Build 13 behoben (siehe dort), schon vorher so (auch bei der Mail-Karte): Ist eine Karte mit Eingabefeldern die **letzte** Nachricht und wird auf dem iPhone ein Feld darin fokussiert, verrechnet der Verlauf die Tastatur doppelt (Inset unten 105 → 399 pt bei 267 pt kleinerem Sichtbereich) und steht zu weit unten; nach kurzem Wischen stimmt es. Mit und ohne den neuen Breiten-Container identisch gemessen.
- Screenshots: `mac-nacht-tresor-karte.png`, `iphone-hell-tresor-karte.png`, `mac-nacht-live-karten.png`.

## Build 13

- **Tastatur bei Karten mit Eingabefeldern** (`ChatView.transcript`): Ursache gemessen im iPhone-Simulator (Demo, Lio, Tresor-Karte als letzte Nachricht, Geometrie-Protokoll über `onScrollGeometryChange`). Der untere Inset selbst stimmt (105 → 399 pt, Sichtbereich 637 → 343 pt). Aber bei jeder Änderung des unteren Insets verschiebt die Verankerung `defaultScrollAnchor(.bottomLeading, for: .sizeChanges)` den Versatz noch einmal um den ganzen Inset: 710 → 1109 pt bei einem Maximum von 710 pt. Beim Eingabefeld unten fing das bisher nur das um 350 ms verzögerte `scrollTo(edge: .bottom)` über `keyboardVisible` auf. Felder in Karten (Mail, Tresor) melden diesen Fokus nicht. UIKit scrollte das fokussierte Feld dann vom falschen Versatz aus nur knapp ins Bild: Das Feld stand oben, darunter blieb eine leere Fläche in Tastaturhöhe, und erst eine Berührung ließ den Verlauf zurückfedern.
  - **Lösung:** Ändert sich der untere Inset (Tastatur ein/aus, mehrzeiliges Eingabefeld, Anhänge) und stand der Verlauf vorher am Ende, rückt er sofort ans Ende (`BottomInsetState`, alter Wert aus derselben Geometrie). Gemessen danach: 710 pt (Tastatur auf) bzw. 416 pt (Tastatur zu). Das Eingabefeld unten sitzt unverändert über der Tastatur.
  - **Dabei gefunden und behoben (schon in Build 12):** War der Verlauf hochgescrollt und man tippte ins Eingabefeld, zielte das Nachrücken auf eine noch geschätzte Lazy-Höhe. Der Verlauf stand dann hinter dem Ende (Versatz 1682 bei Maximum 1168), der Bildschirm war leer bis zur nächsten Berührung. Absicherung: Steht der Verlauf in Ruhe hinter dem Ende (`onScrollPhaseChange` = idle, 120 ms später noch immer), rückt er ans Ende. Das Zurückfedern beim Ziehen bleibt beim System, ebenso kurze Verläufe, die kürzer sind als der Sichtbereich. Der Zustand liegt in einer nicht beobachteten Klasse (`TranscriptScrollState`), damit Scrollen den Chat nicht neu auswertet.
  - Unverändert: Zeilen volle Breite ab x = 0 (Build-11-Fix gegen seitliches Verschieben), `ColumnTransitionStabilizer`/`StableWidth` (Build 12), Nachrücken bei Breitenwechseln.
- **Kante oben auf dem iPhone Duo (zugeklappt):** Laut Nutzer ist der Streifen in Build 12 nicht mehr zu sehen; der Screenshot stammte von einem älteren Build oder war vorübergehend. Nachgeprüft ohne Codeänderung, Pixelwerte der oberen Bildschirmzeilen gemessen:
  - iPhone 18 Pro: Nacht #161618 durchgehend vom ersten Pixel an, auch nach Hochscrollen, Widget-Deeplink `aisbot://bot/b_mila` sowie Quer- und wieder Hochformat. Hell: #FFFEFF durchgehend.
  - iPad Pro 11 Zoll: Nacht und Hell, Seitenleiste auf und zu, hoch und quer, Deeplink. Überall nahtlos.
  - Nicht reproduzierbar, deshalb kein Umbau. Das iPhone Duo selbst ließ sich nicht testen: Der Simulator startete, aber weder die T3-Gerätewerkzeuge (App-Start „xcrun exited with code 64“, Runner „xcodebuild exited early“) noch die Xcode-Gerätewerkzeuge („The device simulator cannot be connected“) konnten ihn bedienen.
- **Getestet** (Demo-Modus, Simulator iOS 27.2):
  - iPhone 18 Pro, Nacht: Tresor-Karte (Passwortfeld), Tastatur auf und zu, Mail-Karte bei Nora (am Ende und mitten im Verlauf), Eingabefeld unten (Fokus, zweizeilig), Eingabefeld bei hochgescrolltem Verlauf, Überziehen am Ende. Hell: Tresor-Karte.
  - iPad: Tresor-Karte mit Hardware-Tastatur-Leiste, Seitenleiste auf und zu, hoch und quer. Verlauf und Eingabe bleiben bündig und mittig.
  - Builds macOS und iOS-Simulator ohne Warnungen.
- **Nicht getestet:** iPhone Duo (siehe oben), Bildschirmtastatur auf dem iPad (der Simulator nutzt die Mac-Tastatur und zeigt nur die Kürzelleiste), echte Geräte.
- **Screenshots:** `iphone-nacht-oberkante-vorher.png` (Screenshot des Nutzers, älterer Build), `iphone-nacht-oberkante-nachher.png` (Build 13, iPhone-Simulator), `iphone-nacht-karte-tastatur-vorher.png`, `iphone-nacht-karte-tastatur-nachher.png`.

## Build 14

### Seitenleiste ohne Profilzeile, Einstellungen in der Leiste

- **Entfernt:** die feste Zeile unten in der Seitenleiste (Avatar mit Initiale, Name aus `/api/health`, im Demo-Modus „Demo-Modus“, Zahnrad), auf allen Plattformen (`SidebarView.userRow`). Avatar und Name hatten keine Aktion; nur das Zahnrad führte weiter. Der Demo-Hinweis steht weiterhin in den Einstellungen unter „Verbindung“. Nichts musste verlegt werden.
- **Einstellungen jetzt:**
  - **iPhone und iPhone Duo zugeklappt:** Zahnrad als dritter Knopf in der Glas-Kapsel mit Suche und ⌘ (beim Duo in der senkrechten Leiste am Rand unter „Neu“). Der große Titel „Scoops“ bleibt in seiner eigenen Zeile.
  - **iPad und iPhone Duo aufgeklappt (Split-Seitenleiste):** Zahnrad in der Kapsel mit der Suche; rechts bleiben „Neu“ und der Seitenleisten-Knopf. Das System zeigt den Titel in der Seitenleisten-Spalte nur inline (`navigationBarTitleDisplayMode(.large)` wirkt dort nicht), und mit dem dritten Knopf wurde er auf „S“ gekürzt, gemessen beim Duo aufgeklappt (Spalte 280 pt). Deshalb blendet die Split-Seitenleiste den System-Titel aus (`toolbar(removing: .title)`) und zeigt „Scoops“ als Überschrift über der Liste (`splitTitle`, 28 pt fett, scrollt mit, Überschrift für VoiceOver). Die Suche erscheint darunter. `navigationTitle` bleibt für Bedienungshilfen und das App-Menü gesetzt.
  - **Mac:** Zahnrad (`SettingsLink`) in der Kopfzeile der Seitenleiste zwischen Suche und „+“. Zusätzlich wie bisher App-Menü bzw. ⌘, und die Befehlspalette.
- **Platz:** Die Liste reicht jetzt bis zur unteren Safe Area. Unter der letzten Zeile bleibt nur die bisherige leere Fläche (Rechtsklick bzw. langes Drücken legt einen Bereich an) plus der Abstand zum Home-Indicator. Das Verbindungsbanner („Verbinde …“, offline) steht bei Bedarf weiterhin unter der Liste.
- **Getestet** (Demo-Modus, Nacht, Simulator iOS 27.2): iPhone Duo zugeklappt (Zahnrad öffnet die Einstellungen, „Privat“ aufgeklappt und ans Ende gescrollt: „Alle“ steht frei über dem Home-Indicator), Duo aufgeklappt per `agent-device fold open` (vorher Titel „S“, danach „Scoops“ vollständig) und wieder zugeklappt. iPad Pro 11 Zoll hochkant: Zahnrad öffnet das Einstellungsblatt, Suche ein und aus, Titel bleibt stehen. Mac: Zahnrad öffnet das Fenster „AIS Scoops-Einstellungen“. Nicht getestet: iPad quer, echte Geräte.
- **Builds:** macOS und iOS-Simulator ohne Warnungen.
- **Screenshots:** `iphone-nacht-seitenleiste-ohne-profil.png` (iPhone Duo zugeklappt), `ipad-nacht-seitenleiste-ohne-profil.png`, `mac-nacht-seitenleiste-ohne-profil.png`.

### Verlauf leer bei mehrzeiliger Eingabe

- **Fehler** (gemeldet auf dem iPhone Duo, zugeklappt, Build 13): Bricht der Text im Eingabefeld in die zweite Zeile um, wird der ganze Verlauf schwarz.
  - **Ursache, gemessen** im iPhone-Simulator (Demo, Nora, Tastatur offen; Geometrie-Protokoll, siehe unten):
    - Eingabefeld (`safeAreaInset`) und Tastatur bildeten den **unteren Inset** des Verlaufs.
    - Bei jeder Änderung dieses Insets setzt die Verankerung `defaultScrollAnchor(.bottomLeading, for: .sizeChanges)` den Versatz um den **ganzen** neuen Inset hinter das Ende, sofern der Verlauf am Ende stand.
    - Beim Umbruch auf zwei Zeilen (Inset 399 → 416 pt): Versatz 1601 bei Maximum 1185, also 416 pt hinter dem Ende bei nur 326 pt Sichtbereich. Der Verlauf war vollständig leer.
    - Dasselbe passiert beim Schrumpfen (416 → 399 pt: 1567 bei Maximum 1168) und bei Tastatur auf und zu.
    - Auch `scrollTo(edge: .bottom)` zielt bei einem unteren Inset um genau diesen Inset zu weit.
    - Im Simulator fing das Build-13-Nachrücken (`BottomInsetState`, Absicherung nach 120 ms) das nach 1–8 Bildern ab: ein Aufblitzen. Auf dem Gerät blieb der Verlauf offenbar leer stehen. Die Absicherung lief nur einmal pro Wechsel und gab auf, wenn ihr eigenes `scrollTo` wieder hinter dem Ende landete.
    - Mit abgeschaltetem Nachrücken stand der leere Zustand rund 125 ms: `iphone-nacht-mehrzeilig-vorher.png` (Bild aus einer Aufnahme, sieht aus wie der Screenshot vom Gerät).
    - Höhenänderungen des Sichtbereichs rechnet dieselbe Verankerung dagegen richtig: Gemessen im ersten Bild exakt am Maximum.
  - **Lösung** (`ChatView`):
    - Die Eingabe liegt jetzt in einem `VStack` **unter** dem Verlauf statt als `safeAreaInset`. Tastatur, wachsendes oder schrumpfendes Feld, Anhänge und @-Liste ändern nur noch die Höhe des ScrollViews, nie seinen unteren Inset.
    - Den unteren Content-Rand (8 pt) gibt es nicht mehr. Der Abstand ist jetzt Teil der letzten Zeile (`.padding(.bottom, 8)` an der Tipp-Blasen-Zeile). Der untere Inset ist damit immer 0, sodass weder Verankerung noch `scrollTo(edge: .bottom)` etwas doppelt rechnen. Der sichtbare Abstand zur Eingabe ist unverändert (10 + 8 + 6 pt).
    - Den Übergang zur Eingabe macht ein 8-pt-Verlauf am unteren Rand des Verlaufs. Vorher lief der Verlauf unter den Schleier der Eingabe; die Farbe ist dieselbe.
    - Das Nachrücken bei Änderungen des unteren Insets bleibt als Absicherung, jetzt nur ohne Berührung.
    - Die Absicherung „hinter dem Ende“ versucht es jetzt bis zu fünfmal (je 120 ms), statt nach einem Versuch aufzugeben.
    - Tastatur auf: Nur wenn der Verlauf am Ende stand, wird nach 350 ms noch einmal ans Ende gerückt. Ein **hochgescrollter Verlauf bleibt stehen**. Vorher sprang er beim Antippen des Eingabefelds ans Ende.
  - **Unverändert:**
    - Zeilen volle Breite ab x = 0 (Build 11)
    - `ColumnTransitionStabilizer`/`StableWidth` (Build 12)
    - Nachrücken bei Breitenwechseln
    - Verhalten der Karten mit Eingabefeldern (Build 13)
- **Geometrie-Protokoll (nur Debug):** Startargument `-scrolllog` schreibt bei jeder Änderung Versatz, Inhaltshöhe, Sichtbereich, Insets, Maximum und Überstand („over“) ins Systemprotokoll (Subsystem `com.ais.aisbot`, Kategorie `scroll`), dazu jedes Nachrücken, Scroll-Phase und „hinter dem Ende“. Mitlesen im Simulator mit `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.ais.aisbot" AND category == "scroll"'`, auf dem Mac mit `/usr/bin/log stream …`.
- **Getestet** (Demo-Modus, Simulator iOS 27.2, Messwert „over“ = Versatz minus Maximum, positiv heißt hinter dem Ende):
  - **iPhone 18 Pro, Nacht, Nora**, Bildschirmtastatur Taste für Taste:
    - Fokus: over 0.
    - 1 → 2 → 3 → 8 Zeilen (Sichtbereich 351 → 334 → 316 → … → 226,7 pt): in jedem Bild over 0, kein Nachrücken nötig.
    - Löschen, bis das Feld schrumpft: over 0.
    - Senden aus 8 Zeilen, danach die Antwort: Verlauf rückt ans Ende, Endstand over 0.
    - Hochgescrollt: Umbruch auf zwei Zeilen, Löschen, Tastatur zu und wieder auf. Der Versatz bleibt jeweils exakt stehen (967,3 pt).
    - Am Ende: Tastatur zu und auf. Jeweils im ersten Bild am Maximum (1273 bzw. 1567).
    - Anhänge (Theo, `-attachdemo`): Fokus, Anhänge entfernen, Chips-Zeile verschwindet. Endstand am Ende.
    - Tresor-Karte bei Lio als letzte Nachricht, Passwortfeld fokussiert: ganze Karte über Eingabe und Tastatur, over 0 (`iphone-nacht-tresor-tastatur-build14.png`). Danach Tastatur interaktiv weggewischt.
    - Mail-Karte bei Nora mitten im Verlauf: Textfeld fokussiert, Einfügemarke im Bild.
  - **iPad Pro 11 Zoll:**
    - Seitenleiste zu und auf, hochkant: over 0.
    - Bildschirmtastatur (in Build 13 nicht testbar): Fokus, 3 Zeilen.
    - Querformat mit offener Tastatur, Seitenleiste zu und auf, zurück hochkant: immer am Ende, Spalte und Eingabe mittig und bündig (`ipad-nacht-mehrzeilig-quer.png`).
  - **Mac:**
    - ⇧Enter bis 9 Zeilen, das Feld wächst bis 8 Zeilen: over 0.
    - Fenster 760–1440 pt breit, 600–900 pt hoch, mit 1 und 8 Zeilen sowie nach dem Löschen: Endstand am Ende, Spalte bündig.
    - Während der Größenänderung meldet das Protokoll zusätzlich Zwischen-Durchläufe (Sichtbereich 32 pt, Kopfzeilen-Inset 74 statt 106 pt, Inhaltshöhen bis 12 000 pt). Eine Bildschirmaufnahme der Größenänderung zeigt in keinem Bild einen leeren oder verschobenen Verlauf: Diese Durchläufe werden nicht gezeichnet.
  - **Builds:** macOS und iOS-Simulator (Clean Build) ohne Warnungen.
- **Beobachtet, nicht geändert:** Beim Einfügen einer neuen Nachricht korrigiert das Lazy-Layout seine geschätzte Höhe (z. B. 1992 → 1863 pt). Für **ein** Bild steht der Versatz dabei 129–136 pt hinter dem Ende, danach läuft die Scroll-Animation ans Ende. Das hängt nicht am Eingabefeld und war schon vorher so.
- **Nicht getestet:**
  - **iPhone Duo:** Der Simulator startet jetzt und lässt sich bedienen (Außenpanel 466 × 678 pt). Der Deeplink-Dialog „Open in AIS Scoops?“ ließ sich aber weder per Knopf, Alert-Befehl noch Tipp schließen und blieb auch nach einem App-Neustart stehen. Der Chat ließ sich deshalb nicht öffnen.
  - Echte Geräte.
  - Hardware-Tastatur-Kürzel im iOS-Simulator.
- **Screenshots:**
  - `iphone-nacht-mehrzeilig-vorher.png`: Build-13-Mechanismus mit abgeschaltetem Nachrücken, Bild aus einer Aufnahme
  - `iphone-nacht-mehrzeilig-nachher.png`: 3 Zeilen
  - `iphone-nacht-mehrzeilig-8-zeilen.png`
  - `iphone-nacht-tresor-tastatur-build14.png`
  - `ipad-nacht-mehrzeilig-quer.png`

## Build 15

### Chat-Kopf als Glas-Pille

- **Vorher:** Oben im Chat lag eine volle, deckende Leiste (iOS: `toolbarBackground(theme.background)`, Mac: Kopfzeile mit deckendem Verlauf). Dazu schnitt der Breiten-Container (`ColumnTransitionStabilizer`, `.clipped()`) den Verlauf an der Unterkante der Leiste ab. Die oberste Nachricht begann deshalb sichtbar abgeschnitten.
- **Jetzt:**
  - Name mit Mini-Maskottchen (36 pt, Gruppen 38 pt) als schwebende Liquid-Glass-Pille (`ChatCapsule`, `.glassEffect(.regular.interactive(), in: .capsule)`), 44 pt hoch wie die Glas-Knöpfe des Systems. Antippen öffnet wie bisher das Profil des Scoops bzw. der Gruppe.
  - Keine deckende Fläche mehr. Der Verlauf läuft unter Pille und Knöpfen bis an den oberen Rand und ist zwischen den Elementen sichtbar. Oben liegt nur der weiche Scroll-Kanten-Effekt (`scrollEdgeEffectStyle(.soft, for: .top)`).
  - Der Clip des Breiten-Containers beschneidet nur noch links und rechts (`HorizontalClip` in `StableWidth.swift`), damit der Verlauf in die obere Safe Area reichen kann.
  - Erste Nachricht: Die Kopfhöhe kommt als oberer Safe-Area-Inset dazu, plus 16 pt Content-Rand. Ganz nach oben gescrollt steht die erste Nachricht frei unter der Pille. Unten ändert sich nichts (unterer Inset bleibt 0, siehe Build 14).
- **iPhone und iPad** (`ChatHeaderBar` in `ChatView.swift`): Pille als `.principal` mit `sharedBackgroundVisibility(.hidden)` (eigenes Glas statt des geteilten Leisten-Glases), Zurück und „Neu“ bleiben System-Glas-Knöpfe. `toolbarBackgroundVisibility(.hidden, for: .navigationBar)`.
- **iPhone Duo:** Das System setzt die Knöpfe in seine senkrechte Leiste und zeigt `.principal` dann nur manchmal. Gemessen im Simulator (iOS 27.2) über den Bedienungshilfen-Baum: aufgeklappt nie, zugeklappt nach einem Neustart nicht, nach dem Zuklappen aus dem aufgeklappten Zustand schon. Aufgeklappt fehlte der Name damit auch schon vor Build 15 (und damit der Weg ins Profil per Kopfzeile). Solange die Leiste senkrecht steht (`@Environment(\.toolbarVerticalEdge)`, ab iOS 27.1), schwebt die Pille deshalb selbst über dem Verlauf (`safeAreaBar(edge: .top)`), zu und auf gleich. Die View-Struktur bleibt dabei gleich, Auf-/Zuklappen baut den Verlauf nicht neu auf.
- **Mac** (`ChatMacHeader`): Pille mittig und „Profil einblenden“ als Glas-Kreis (`GlassEffectContainer`), angehängt per `safeAreaBar` statt `safeAreaInset`. Statt der deckenden Kopfzeile nur ein dezenter Schleier (85 % → 0 % der Hintergrundfarbe, 18 pt über die Kopfzeile hinaus). Das Mac-Glas ist deutlich klarer als auf iOS, Text des Verlaufs schien durch die Pille; deshalb dort ein leichter Ton (`Glass.chatHeader`: `.regular.tint(background 55 %)`). In die Fenster-Toolbar wurde die Pille bewusst nicht verlegt: Titelleiste ist ausgeblendet und die Kopfzeile sitzt ohnehin auf Höhe der Ampel-Knöpfe.

### Seitenleiste: Streifen über der Navigationsleiste

- **Fehler** (gemeldet auf dem iPhone Duo, zugeklappt): In der Seitenleiste nach unten scrollen, bis „Scoops“ verschwindet, dann wieder hoch. Danach erschien oben eine Leisten-Fläche, die nicht bis an die Oberkante reichte; darüber blieb ein Streifen in anderer Farbe. Das war die Ursache der in Build 13 gemeldeten „Kante oben“.
- **Lösung:** Die Leisten-Fläche ist ganz weg (`toolbarBackground(sidebarBackground)` ersetzt durch `toolbarBackgroundVisibility(.hidden, for: .navigationBar)`). Wie im Chat bleiben nur die Glas-Knöpfe und der weiche Scroll-Kanten-Effekt, die Liste läuft darunter bis an den oberen Rand.
- **Andere große Titel:** Die App hat nur eine `NavigationStack` (iPhone: Seitenleiste → Chat). Einstellungen, Profil, Bibliothek, Tresor usw. sind Blätter mit eigener Kopfzeile (`SheetHeader`) ohne System-Navigationsleiste. Dort klappt kein großer Titel ein, und es gibt keine Leisten-Fläche, die zu kurz sein könnte.
- Im Simulator ließ sich der Streifen nicht nachstellen (Demo-Liste, Scrollen per Gerätewerkzeug). Das Vorher-Bild ist deshalb der Screenshot des Nutzers (noch mit der alten Profilzeile, die seit Build 14 entfernt ist).

### Getestet (Demo-Modus, Simulator iOS 27.2, macOS)

- **iPhone Duo zugeklappt, Nacht:** Pille schwebt, Verlauf läuft darunter, Antippen öffnet das Profil-Blatt, ganz oben steht die erste Nachricht frei. Eingabe auf drei Zeilen mit Bildschirmtastatur, dann Tastatur über „Tastatur schließen“ zu: Verlauf jeweils am Ende, nie leer. Seitenleiste runter und wieder hoch: keine Leisten-Fläche. **Hell:** Chat und Seitenleiste ebenso.
- **iPhone Duo aufgeklappt, Nacht:** Pille schwebt auf Höhe der Glas-Knöpfe der Seitenleiste, öffnet das Profil, ganz oben steht die erste Nachricht frei.
- **iPhone 18 Pro, Hell:** Glas-Zurück, Pille, Glas-„Neu“ in der Leiste, ganz nach oben gescrollt erste Nachricht frei.
- **iPad Pro 11 Zoll:** Nacht und Hell. Seitenleiste zu und auf: Spalte und Eingabe bleiben bündig und mittig am Ende (Build 11/12 unverändert), Pille bleibt mittig. Eingabe auf zwei Zeilen (Hardware-Tastatur des Simulators): Verlauf am Ende.
- **Mac:** Nacht und Hell, Pille öffnet die Profil-Seitenleiste (der Glas-Kreis verschwindet dann), ganz nach oben gescrollt erste Nachricht frei.
- **Builds:** macOS (Clean Build) ohne Warnungen. iOS-Simulator ohne Warnungen; der letzte Clean Build im Projektordner scheiterte an fremden, parallel angelegten Dateien (`NotificationAvatarSync.swift` noch nicht im Projekt), deshalb in einer Kopie mit frisch erzeugtem Projekt gebaut.
- **Nicht getestet:** echte Geräte (Glas sieht auf dem Gerät etwas anders aus als im Simulator), Mac mit mehrzeiliger Eingabe und Fenstergröße ändern (Eingabe und unterer Rand unverändert), iPad mit Bildschirmtastatur, iPad quer, Duo halb geöffnet.
- **Beobachtet, nicht geändert:** Am Mac zeigt die Fenster-Toolbar über der Profil-Spalte einen etwas helleren Streifen (rund 40 pt). Gleich mit der alten Kopfzeile, also nicht durch Build 15; `toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` am Inspector half nicht.
- **Screenshots:**
  - `iphone-nacht-chat-pille-vorher.png` (Screenshot des Nutzers, Duo zugeklappt), `mac-nacht-chat-pille-vorher.png` (Build 14)
  - `iphone-nacht-chat-pille.png` (Duo zugeklappt), `iphone-duo-offen-nacht-chat-pille.png`, `iphone-duo-hell-chat-pille.png`, `iphone-hell-chat-pille.png` (iPhone 18 Pro), `ipad-nacht-chat-pille.png`, `mac-nacht-chat-pille.png`
  - `iphone-nacht-seitenleiste-oben-vorher.png` (Screenshot des Nutzers), `iphone-nacht-seitenleiste-oben-nachher.png` (Duo zugeklappt, nach Runter- und Hochscrollen)

### Mitteilungen mit Scoop-Bild

Push-Mitteilungen zeigen wie bei Messengern das Maskottchen des schreibenden Scoops als Absenderbild (iOS Communication Notifications). Das App-Symbol erscheint nur noch klein in der Ecke.

- **Neues Target `AISBotNotifications`** (Notification Service Extension, `com.ais.aisbot.notifications`, iOS und macOS).
  - Liest aus der Payload `author_id`, `author_name`, `chat_id`/`bot_id` und `group_name`.
  - Baut daraus einen `INSendMessageIntent`:
    - Absender als `INPerson`: Name = `author_name`, `personHandle` = `author_id`, Bild = vorgerendertes PNG.
    - `conversationIdentifier` = `chat_id`.
    - Gruppen zusätzlich mit `speakableGroupName` und zwei Beteiligten (ich + Absender).
  - Spendet die `INInteraction` und stellt `content.updating(from:)` zu.
  - Fehlt `author_id` oder das Bild, scheitert `updating(from:)` oder läuft die Zeit ab, geht die Original-Mitteilung unverändert raus.
  - Die Logik steht in `Shared/Notifications/ScoopCommunication.swift`; die Extension selbst ist nur ein dünner Rahmen.
- **Vorgerenderte Bilder** (`Shared/Notifications/NotificationAvatars.swift`, `AISBot/Support/NotificationAvatarSync.swift`):
  - Die Hauptapp rendert pro Scoop ein PNG mit 256 × 256 px in den App-Group-Container unter `NotificationAvatars/`. Die Extension rendert nichts (Speicherlimit).
  - Aufbau: dunkle Fläche mit leichtem Verlauf in der Körperfarbe, die das Quadrat füllt (das System schneidet rund aus). Das Maskottchen steht mittig in 80 % der Fläche, damit Fell und Kopfschmuck im Kreis bleiben.
  - Dateiname `<bot_id>-<FNV-1a-Hash>.png`. Der Hash umfasst Form, Farbe, Augen, Accessoire, Fell-Startwert (Bot-ID), Bildgröße und `renderVersion`.
  - `avatars.json` ordnet `author_id` → Datei und Name zu. Veraltete Dateien werden gelöscht.
  - Ausgelöst über `WidgetSync.update`, also bei App-Start, nach dem Laden der Bot-Liste und nach „Aussehen bearbeiten“. Gerendert wird nur, was sich geändert hat.
  - Bei Änderungen am Bildaufbau `NotificationAvatars.renderVersion` erhöhen.
- **Hauptapp:**
  - Entitlement `com.apple.developer.usernotifications.communication` in iOS Debug, iOS Release und macOS Release. Mac Debug bleibt ohne, damit lokale Mac-Builds kein Profil brauchen; dort greift der Fallback.
  - `NSUserActivityTypes = [INSendMessageIntent]` im Info.plist.
  - Die Capability „Communication Notifications“ der App-ID `com.ais.aisbot` hat Xcode beim Archivieren per API-Key selbst gesetzt.
- **Extension-Entitlements:**
  - iOS: App Group `group.com.ais.aisbot`, gleich für Debug und Release.
  - macOS: Sandbox und `MYXQKK3T2Z.com.ais.aisbot`.
  - Kein Push-Entitlement nötig.
- **Signierung (Stand 12.11.2026):**
  - Die Bundle-ID `com.ais.aisbot.notifications` ist per App-Store-Connect-API registriert (Name „XC com ais aisbot notifications“, UNIVERSAL), mit eingeschalteter Capability App Groups.
  - **Noch nötig, einmalig durch dich:** der App-ID die Gruppe `group.com.ais.aisbot` zuweisen. Das kann weder die API noch Xcode mit dem API-Key („Authentication failed“, „Provisioning profile … doesn't support the group.com.ais.aisbot App Group“). Das ist dieselbe Einschränkung wie oben unter „Release“ für die App Group. So geht es:
    1. [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers/list) öffnen und `com.ais.aisbot.notifications` anklicken.
    2. Bei „App Groups“ (Haken ist schon gesetzt) auf **Configure** bzw. **Edit** klicken.
    3. `group.com.ais.aisbot` auswählen, **Continue**, dann oben rechts **Save** und bestätigen.
    - Alternativ: in Xcode → Einstellungen → Accounts die Apple-ID hinzufügen und einmal `xcodebuild … archive -allowProvisioningUpdates` ohne Key laufen lassen.
  - Danach funktioniert `scripts/upload-testflight.sh 15` unverändert. Skript und ExportOptions mussten nicht angepasst werden.
  - **Geprüft:**
    - iOS-Release-Archiv mit Key: scheitert nur an der fehlenden Gruppen-Zuweisung.
    - Probe-Archiv ohne App-Group-Entitlement in der Extension: Archiv und lokaler Export (`destination export`) erfolgreich. Die App hat das Communication-Entitlement, die Extension `CFBundleVersion` 15. Das Probe-Archiv ist wieder gelöscht.
    - macOS-Release-Archiv und lokaler Export (`.pkg`) mit Key: vollständig erfolgreich.
- **Test im Simulator:** `xcrun simctl push` stellt simulierte Pushes direkt zu und startet die Service Extension nicht. Im Protokoll heißt es „Notification serviced by the communication context service: 0“; die Extension wird nie gestartet, auch nicht nach einer APNs-Registrierung. Ein echter Sandbox-Push an den Simulator ging auch nicht, weil der APNs-Schlüssel des Servers nur für Produktion gilt (`BadEnvironmentKeyInToken`). Deshalb gibt es nur im Debug-Build zwei Startoptionen:
  - `-askpush`: fragt nach der Mitteilungs-Erlaubnis und registriert APNs auch im Demo-Modus. Das Token geht an keinen Server und steht als `[Push] Geräte-Token` im Protokoll.
  - `-localpush einzelchat,gruppe,ohne-bild,freigabe` (optional `-localpushdelay <s>`): schickt dieselben Payloads wie `scripts/push-tests/*.apns` als lokale Mitteilungen durch `ScoopCommunication`. Das ist derselbe Code wie in der Extension (Intent, Spenden, `updating(from:)`). Die erste Mitteilung kommt 6 s nach dem Planen, dann alle 6 s; die App vorher in den Hintergrund schicken.
- **Getestet** (Demo-Modus, iPhone 18 Pro, Simulator iOS 27.2):
  - Einzelchat: Mila mit Maskottchen als Absenderbild.
  - Gruppe: Titel „Mila“, darunter „Launch-Team“, Mila-Bild.
  - Scoop ohne vorgerendertes Bild (`b_neo`): normale Mitteilung mit App-Symbol.
  - Freigabe „Bittet um Freigabe: …“ von Theo: mit Theos Bild.
  - Aussehen bearbeiten (Mila: Bohne → Herz, Sichern): Sofort entsteht eine neue Datei mit neuem Hash, die alte ist gelöscht, `avatars.json` zeigt auf die neue. Die nächste Mitteilung zeigt das Herz.
  - `simctl push` mit den `.apns`-Dateien kommt an, aber ohne Bild (siehe oben).
- **Nicht getestet:** die Extension selbst mit einem echten Push (erst mit TestFlight auf einem Gerät möglich), Mac zur Laufzeit (dort kann nur ein echter Produktions-Push die Extension auslösen), Fokus-/„Trotzdem mitteilen“-Verhalten.
- **Builds:** macOS und iOS-Simulator (Clean Build) ohne Compiler-Warnungen. Das AppIntents-Werkzeug meldet für die Extension nur „Metadata extraction skipped, no AppIntents.framework dependency found“; das ist ein Hinweis, keine Warnung im Code.
- **Screenshots:** `iphone-mitteilung-scoop-bild.png`, `iphone-mitteilung-gruppe.png`, `iphone-mitteilung-freigabe.png`, `iphone-mitteilung-ohne-bild.png` (Fallback), `iphone-mitteilung-nach-aussehen.png` (Mila als Herz nach „Aussehen bearbeiten“).

### Einführung auf dem iPhone Duo (zu- und aufgeklappt)

- **Getestet** (Demo-Modus, Simulator iPhone Duo iOS 27.2, geklappt per `agent-device fold open|closed`, hell und Nacht, Standardschrift und AX1): alle Schritte zu- und aufgeklappt; Klappen mitten im Ablauf mit Name (Tastatur offen), Figur, Farbe-Reiter, Zweck, Charakter, Kopplungscode, Entwurf der ersten Nachricht, während „Warten“ (verbindet danach von selbst) und während der ersten Antwort mit Konfetti. Eingaben, Schritt, Teilseite und Zurück-Weg bleiben, keine doppelten Ansichten, die Tastatur bleibt passend offen. Ende zugeklappt → Chat, aufgeklappt → Split-Layout; „Einführung erneut ansehen“ aus den Einstellungen mit Klappen dazwischen.
- **Fehler und Lösung:**
  - *Code abgelaufen* war mit offener Tastatur unsichtbar (zu- und aufgeklappt, auch auf dem iPhone): Die Meldung steht unter dem Feld, das System scrollt nur bis zum Cursor. `OnboardingPage(scrollTarget:)` hält eine Ansicht ganz sichtbar (beim Setzen, wenn die Tastatur kommt und nach jedem Größenwechsel); Code-Schritt: Meldung bzw. Feld, Name-Schritt: Feld. Vorher war auch das Eingabefeld unten halb abgeschnitten.
  - *Key Visual* auf der ersten Seite: aufgeklappt (669 pt hoch) und zugeklappt schob es Überschrift und Text unter die Knöpfe. Jetzt höchstens gut die Hälfte der sichtbaren Höhe (`containerRelativeFrame`), auf iPhone und iPad unverändert 360 pt.
  - *Zweck-Kacheln:* bei rund 155 pt Breite (Duo zu- und aufgeklappt) „Erinnerun-gen“, „Organisie-ren“, bei AX1 „Recher-che“ und abgeschnittene Zeilen. Jetzt höchstens zwei Zeilen, notfalls leicht verkleinert; bei Bedienungshilfen-Größen eine Spalte.
  - *Kopfzeile bei AX1:* „Überspringen“ wurde zu „Überspring…“ gekürzt. Jetzt ungekürzt, „Schritt x von 5“ bleibt einzeilig.
- **Test:** `testGroessenwechselMittenImAblauf` (Drehen als Größenwechsel; XCUITest kann das Duo nicht klappen). Schlägt ohne die Korrektur an der verdeckten Meldung fehl. Grün auf Duo zugeklappt, iPhone 17 Pro und iPad Pro 11.
- **Grenzen:** XCUITest-Tipps landen auf dem aufgeklappten Duo daneben (App-Fenster füllt den Bildschirm nicht), dort laufen die UI-Tests nicht. Zugeklappt kommt in `testGanzerAblaufDemo` direkt nach dem Start der Tipp auf „Zurück“ (oben links, y 10–50 pt) nicht an; mit `agent-device` an derselben Stelle schon, auf iPhone und iPad ist der Test grün. Kein App-Fehler, der Test bleibt unverändert.
- **Screenshots:** `duo-onb-*` (`-zu-`/`-auf-` = zu-/aufgeklappt, jeweils `-vorher`/`-nachher`): `willkommen`, `code-abgelaufen`, `zweck`, `zweck-ax1`, `kopf-ax1-zu`; `duo-onb-klappen-name.png`, `duo-onb-klappen-zweck-vorher.png` (Zustand vor und nach dem Aufklappen), `duo-onb-ende-auf-zu.png`.

### App-Wechsel: leeres Profil-Sheet und verlorener Entwurf (iPhone Duo, iPad)

- **Fehler:** (1) Profil rechts offen, App gewechselt, zurück: zusätzlich ein leeres, verschwommenes Sheet über dem Chat. (2) Bild im Eingabefeld angehängt (bzw. Text getippt), App gewechselt, zurück: Anhang und Text weg.
- **Ursache, gemessen** (Simulator iPhone Duo aufgeklappt, Protokoll von `scenePhase`, `horizontalSizeClass` und `showInspector`): Im Hintergrund rendert iOS Schnappschüsse in anderer Größe; die Size-Class springt dabei auf `compact` und zurück auf `regular`. `RootView` baute daraufhin das Layout um (Split-View → Stapel → Split-View). Folgen: `ChatView` wurde neu angelegt, Entwurf und Anhänge lagen als `@State` darin und waren weg. Der `.inspector` präsentierte sich in kompakter Breite als Sheet aus dem Chat im Stapel heraus, schrieb im Hintergrund `false/true/false` in `showInspector` und hinterließ nach dem Rückbau ein leeres Sheet. Dasselbe Geister-Sheet entstand auch ohne App-Wechsel beim Aufklappen des Duo mit offenem Profil-Sheet.
- **Lösung:**
  - `RootView` friert die Size-Class fürs Layout ein, solange die Szene nicht aktiv ist (`layoutSizeClass`), und gibt sie per Umgebung an Split-View/Inspector weiter. Im Vordergrund (Auf-/Zuklappen, Stage Manager) folgt das Layout sofort, bei der Rückkehr wird die tatsächliche Size-Class übernommen.
  - Die Bindung des Inspectors ignoriert Hintergrund-Schnappschüsse (gilt dann als zu, Schreibzugriffe werden verworfen), der Zustand im Store bleibt.
  - Kompakt zeigt nicht mehr `.inspector` das Profil-Sheet, sondern ein eigenes Sheet an der Wurzel (`compactInspectorSheet`). Wird die Darstellung breit, schließt SwiftUI es regulär und das Profil steht als Spalte da.
  - Entwürfe (Text und Anhänge) liegen pro Chat im Store (`AppStore.composerDraft(_:)`, `ComposerDraft` in `Store/ComposerDrafts.swift`), überstehen App-, Size-Class- und Chatwechsel und werden erst beim Senden, beim Löschen des Chats, beim Serverwechsel oder beim Trennen verworfen.
  - Zusätzlich auf der Platte (`DraftArchive`): Application Support/`<Bundle-ID>`/Entwuerfe/`<SHA-256 des Servers>`/ mit `entwuerfe.json` (Text, Anhang-Metadaten, schon hochgeladene `LibraryFile`) und je Anhang den Rohdaten (`<uuid>.anhang`). Gesichert wird 300 ms nach jeder Änderung und sofort beim Wechsel in den Hintergrund; geladen einmal pro Server in `connect`. Schon hochgeladene Anhänge werden übernommen, unterbrochene Uploads neu gestartet. Ein eigener Ordner pro Server: Ein Demo-Start (`-mock`) fasst die Entwürfe des echten Servers nicht an. Auf iOS mit Dateischutz „bis zur ersten Entsperrung“.
  - Korrektur dabei: `connect` (auch „Neu versuchen“) ruft `resetData()` auf; Entwürfe hängen daran nicht mehr.
  - Bewusstes Leeren gab es nur in `ChatView.onChange(of: chatID)` (entfernt). `scenePhase` und `onDisappear` leeren den Composer nicht (`ComposerView.onDisappear` beendet nur das Diktat).
- **Getestet** (Demo-Modus, Nacht, iPhone-Duo-Simulator iOS 27.2, App-Wechsel über die Einstellungen-App): aufgeklappt mit Profil (Seitenleiste offen und zu) → kein Sheet, Profil bleibt offen; Foto über den Picker anhängen und Text tippen → App-Wechsel, Chatwechsel (Theo und zurück), Zuklappen: Entwurf bleibt; zugeklappt Profil-Sheet → App-Wechsel → bleibt, Aufklappen → Spalte ohne Geister-Sheet, Zuklappen → Sheet, Schließen per X → Aufklappen: Profil bleibt zu.
- **Getestet, Sicherung auf der Platte** (iPhone Duo aufgeklappt, Demo): Text tippen und Foto anhängen → App-Wechsel → zurück: beides da. In den Hintergrund, App beenden, neu starten: Text und Bild wieder da (Index und Anhangdatei im Container geprüft). Nur Text bei Theo tippen, App im Vordergrund beenden, neu starten: Text da. Beide Entwürfe senden: Index leer, Anhangdatei gelöscht.
- **Builds:** macOS und iOS-Simulator ohne Compiler-Warnungen.
- **Nicht getestet:** iPad-Simulator, echte Geräte, echter Server (nur Demo; Wiederaufnahme eines unterbrochenen Uploads nach Neustart nur im Code).
- **Screenshots:** `duo-entwurf-nach-beenden-neustart.png`, `duo-nur-text-nach-beenden-neustart.png`, `duo-inspector-appwechsel-vorher.png`, `duo-inspector-appwechsel-nachher.png`, `duo-inspector-seitenleiste-zu-appwechsel-nachher.png`, `duo-entwurf-vor-appwechsel.png`, `duo-entwurf-appwechsel-nachher.png`, `duo-entwurf-chatwechsel-nachher.png`, `duo-zugeklappt-entwurf.png`, `duo-zugeklappt-profil-sheet.png`, `duo-zugeklappt-profil-appwechsel.png`, `duo-aufklappen-mit-profil-vorher.png` (Geister-Sheet beim Aufklappen, Stand vor dem Wurzel-Sheet), `duo-aufklappen-mit-profil-nachher.png`.

### Profil-Spalte: heller Streifen oben (Mac)

- **Fehler:** Auf dem Mac hatte die rechte Spalte (Profil) oben in Toolbar-Höhe (rund 52 pt) einen helleren bzw. anders grauen Streifen, der wie eine Kante aussah.
- **Ursache:** `ProfileView`/`GroupProfileView` setzen `groupedBackground` nur innerhalb des sicheren Bereichs. Darüber, unter der Toolbar, schien die Standardfläche der Inspector-Spalte durch.
- **Lösung:** `InspectorContent` legt `groupedBackground` mit `ignoresSafeArea()` hinter das Profil, durchgehend bis ganz oben (Mac, iPad, Duo; auch im kompakten Sheet).
- **Getestet:** Mac Hell und Nacht (Demo, Profil offen, Ruhezustand), iPhone-Duo-Simulator aufgeklappt Hell. Nicht getestet: Mac mit hochgescrolltem Profil (Scrollen per Bedienungshilfe nahm die App nicht an), iPad.
- **Screenshots:** `mac-inspector-oberkante-hell-vorher.png`, `mac-inspector-oberkante-hell-nachher.png`, `mac-inspector-oberkante-nacht-nachher.png`, `duo-inspector-oberkante-hell-nachher.png`.

### Chat öffnet unten bzw. bei Ungelesen

- **Fehler:** Nach einem App-Neustart landete man beim ersten Öffnen eines Chats irgendwo oben im Verlauf, danach scrollte die App sichtbar ans Ende.
- **Ursache, gemessen** (Demo-Modus mit simulierter Ladezeit `-mocklatency 700`, Geometrie-Protokoll `-scrolllog`, Bildschirmaufnahme im Simulator):
  - Nach einem Neustart sind keine Nachrichten im Speicher. Der Verlauf (`ScrollView`) entstand trotzdem sofort, also leer. Seine Startposition (`defaultScrollAnchor(…, for: .initialOffset)`) griff am leeren Inhalt.
  - Kamen die Nachrichten dann vom Server, standen sie oben („Was ist neu in Swift 6.4?“). Danach liefen ein animiertes `scrollTo` (neue letzte Nachricht) und zwei verzögerte `scrollTo` nach 150 und 500 ms sichtbar ans Ende.
  - Auch ein Verlauf, der gleich mit Nachrichten entsteht, steht nur am Ende der **geschätzten** Lazy-Höhe (1156 pt). Wächst sie beim Vermessen (2323 pt), bleibt der Versatz stehen (665 pt). Die Verankerung für `.sizeChanges` greift beim ersten Vermessen nicht.
  - Im Demo-Modus ohne Ladezeit fiel das kaum auf, weil die Nachrichten noch während der Push-Animation da waren.
- **Lösung** (`ChatView.openTranscript()`):
  - Der Verlauf entsteht erst, wenn die Nachrichten da sind. Bis dahin bleibt die Fläche leer; dauert das Laden länger als 400 ms, erscheint eine kleine Ladeanzeige. Ohne Verbindung erscheint wie bisher der leere Verlauf.
  - Danach bleibt der Verlauf unsichtbar, bis die Zeilen vermessen sind (Inhaltshöhe und oberer Inset zwei Bilder lang unverändert, höchstens rund 250 ms) und die Startposition ohne Animation steht. Dann blendet er in 0,15 s ein.
  - Lagen die Nachrichten schon im Speicher (Chatwechsel) und gibt es nichts Ungelesenes, ist der Verlauf sofort sichtbar. Dann stimmt schon das erste Bild.
  - Die drei Nachrück-`scrollTo` beim Öffnen sind entfernt. Neue Nachrichten und Tipp-Blasen rücken weiter animiert ans Ende, aber erst, wenn die Startposition steht.
- **Ungelesen:**
  - Den Zähler `unread` merkt sich der Chat beim Öffnen, bevor `chatBecameVisible` ihn auf 0 setzt und „gelesen“ an den Server meldet. `.task` lief bei Nachrichten im Speicher teils vor `.onAppear`, deshalb merken beide (`captureOpening`).
  - Erste ungelesene Nachricht: Der Server zählt Antworten und Freigaben (`role` `bot` und `approval`) seit dem letzten „gelesen“ (`Server/src/aisbot/db.py`). Von hinten gezählt ist die n-te davon die erste ungelesene (`ChatItem.firstUnreadID`). Reicht der geladene Verlauf nicht so weit zurück, die früheste geladene.
  - Darüber steht ein dezenter Trenner „Neu“ (Linie und Text in `theme.unreadDot`, VoiceOver: „3 ungelesene Nachrichten“). Hat die Nachricht einen Zeitstempel, steht der Trenner darüber. In Gruppen zeigt die erste ungelesene immer den Autor.
  - Startposition: Trenner oben, direkt unter der Glas-Pille (`scrollTo(id:anchor: .top)`, ohne Animation). Passt der Rest ab dort ohnehin auf den Bildschirm, läge das Ziel hinter dem Ende; dann bleibt der Verlauf ganz unten, der Trenner steht mittendrin.
  - Der Trenner bleibt, bis der Chat geschlossen wird.
- **Demo-Startargumente** (nur mit `-mock`): `-mocklatency <ms>` verzögert das Laden der Nachrichten wie ein echter Server. `-unread <chat-id> <anzahl>` setzt den Ungelesen-Zähler (mehrfach möglich), z. B. `-unread b_theo 4 -unread g_team 3`.
- **Glas-Pille mit mehr Luft:** Das Maskottchen (36 pt, Gruppe 38 pt) saß mit 5 pt Rand in der 44 pt hohen Pille; das Fell stieß an den Rand bzw. ragte darüber. Jetzt sitzt es mittig im linken Halbkreis, mit gleichem Abstand links, oben und unten (`ChatCapsule.Metrics`):
  - iPhone, iPad, Duo: Pille 44 pt (wie die Glas-Knöpfe), Maskottchen 30 pt (Gruppe 34 pt), Name 16 pt.
  - Mac: Pille 48 pt, Maskottchen 32 pt (Gruppe 36 pt), etwas mehr Abstand rechts.
  - Der Gruppen-Stapel hält sein Fell schon innerhalb des Rahmens (`GroupAvatar`) und darf deshalb 4 pt größer sein.
- **Getestet** (Demo-Modus, Simulator iOS 27.2, macOS):
  - **iPhone Duo zugeklappt, Nacht** (das iPhone 18 Pro war von der Sitzung des Helfers belegt):
    - Kaltstart mit 700 ms Ladezeit, Theo antippen. Vorher: erst oben, dann sichtbares Scrollen. Nachher: Ladeanzeige, dann Theo direkt unten, ohne Scroll-Bewegung (Bildfolge geprüft, Phase nur „idle“).
    - Theo mit 4 Ungelesenen, mit und ohne Ladezeit: blendet direkt mit „Neu“ unter der Pille ein, darüber angeschnitten der vorige Lauf.
    - Lio (2 ungelesen, Tresor-Karte am Ende): Rest passt, bleibt ganz unten, Trenner mittendrin.
    - Chatwechsel Theo → Mila → Theo: Mila frisch geladen und Theo aus dem Speicher stehen schon während der Push-Animation unten.
    - Kaltstart direkt in die Gruppe (`-select g_team -unread g_team 3`, wie aus einer Mitteilung): erste ungelesene mit Autorzeile oben.
    - Widget-Deeplink `aisbot://bot/b_theo` beim Kaltstart (inklusive Dialog „Open in AIS Scoops?“): direkt beim Trenner.
    - Gegenprüfung Build 13/14: Nora, Eingabe dreizeilig per Bildschirmtastatur, Senden, Antwort: Überstand nie über 1,3 pt in Ruhe, Endstand am Ende. Mail-Karte mitten im Verlauf fokussiert. Tresor-Passwortfeld bei Lio: Karte über Eingabe und Tastatur, Überstand 0. Beim Einfügen der eigenen Nachricht steht der Verlauf wie schon in Build 14 beschrieben für ein Bild rund 125 pt hinter dem Ende, danach animiert am Ende.
    - Gegenprüfung Build 15: ganz nach oben gescrollt steht die erste Nachricht frei unter der Pille.
  - **iPad Pro 11 Zoll, hochkant, Nacht:** Kaltstart mit 600 ms Ladezeit, Theo (4 ungelesen), Mila, Gruppe (2 ungelesen, Verlauf kürzer als der Bildschirm), Theo erneut: keine Sprünge. Seitenleiste zu und auf bei Nora: Verlauf und Eingabe bleiben bündig am Ende (Build 11/12).
  - **Mac, Nacht:** Kaltstart in Mila: unten. Theo (4 ungelesen, 500 ms Ladezeit) über die Seitenleiste: Trenner unter der Pille. Pille öffnet die Profil-Seitenleiste, der Verlauf behält seine Position (`StableWidth`).
  - Pille: Mac (Mila), Duo (Mila, Gruppe), iPad (Theo, Gruppe).
- **Nicht getestet:** echte Geräte und echter Server (der echte Server wurde nicht angefasst), Nachladen älterer Nachrichten, wenn mehr als eine Seite (50) ungelesen ist (Demo-Chats sind kürzer), Bildschirmaufnahme am Mac (dort Screenshots), iPad quer, Duo aufgeklappt mit Ungelesen, Hell-Modus.
- **Builds:** macOS und iOS-Simulator ohne Warnungen in den geänderten Dateien (`ChatView.swift`, `MockService.swift`).
- **Screenshots:** `iphone-nacht-chat-oeffnen-ungelesen.png` (Theo, 4 ungelesen, Duo zugeklappt), `iphone-nacht-chat-oeffnen-unten.png` (Theo nach Kaltstart mit Ladezeit), `mac-nacht-chat-pille-knapp-vorher.png` und `mac-nacht-chat-pille-nachher.png` (Ausschnitt Pille).

## Theme-Tokens

Alle Farben kommen aus `Theme` (`Shared/Theme/Theme.swift`), Views nutzen nur `@Environment(\.theme)`. Umschalten unter Einstellungen → Erscheinungsbild. **Nacht** ist Standard, **Hell** ist Nacht invertiert: neutrales Weiß ohne warmen Stich (früher „Papier“; gespeicherte Wahl `papier` wird automatisch zu `hell`).

| Token | Nacht | Hell | Verwendung |
|---|---|---|---|
| `background` | #121213 | #FFFFFF | Chat |
| `sidebarBackground` | #0B0B0C | #F7F7F8 | Seitenleiste |
| `inspectorBackground` | #0F0F10 | #FAFAFA | Profil |
| `surface` | #1E1E20 | #F2F2F3 | Bot-Blasen, Karten |
| `surfaceRaised` | #1B1B1D | #FFFFFF | Eingabe, Kapsel |
| `surfaceBorder` | Weiß 7 % | #E8E8EA | Haarlinien |
| `userBubble` | #2E2E31 | #E4E4E7 | eigene Nachrichten |
| `textPrimary/Secondary/Tertiary` | #F2F2F3 / #9A9AA1 / #6A6A70 | #111111 / #6B6B70 / #A1A1A6 | Text |
| `accent`, `unreadDot` | #3B8BFF | #2F6FEB | Akzent, Ungelesen-Punkt |
| `sendButton` / `sendButtonIcon` | weiß / schwarz | #111111 / weiß | Senden, „Freigeben“ |
| `cardShadow` | keiner | Schwarz 3,5 %, r 6, y 1 | kaum sichtbar |
| Maße | Seitenleiste 280, Profil 300, Textspalte 560, Blasenradius 18 | gleich | |

Widgets folgen dem System-Erscheinungsbild (dunkel = Nacht, hell = Hell).

Ausnahmen mit festen Farben: die Maskottchen selbst (Farbe kommt aus den Bot-Daten, Accessoires haben eigene Materialfarben), der erfundene Demo-Bildschirm (`MockScreenView`) und die Hintergründe der Widget-Vorschaubilder.

## Maskottchen (Scoops)

`MascotView(mascot:size:mood:seed:animated:showsGround:)` zeichnet komplett in SwiftUI (Canvas), ohne Bilddateien:

1. weicher dunkler Hof hinter dem Körper,
2. hinterer Fellring aus spitz zulaufenden Büscheln entlang des Umrisses (Zufall pro Bot-ID, stabil über FNV-1a + SplitMix64),
3. Körper mit radialem Verlauf (hell oben links, dunkel unten rechts), Innenschatten und Glanz,
4. vorderer Fellring über der Kante, längere Büschel,
5. Fellstruktur aus tausenden kurzen Härchen entlang eines Fließfelds, auch über den Rand hinaus,
6. Gesicht: rosa Bäckchen (weichgezeichnet), glänzende Knopfaugen mit Lichtpunkt, kleiner Mund,
7. Accessoire.

API-Felder: Formen `bean, pear, cloud, egg, blob, star, drop, bun, ghost, flower`, Augen `lashes, cat, relaxed, focused, dashes, happy` (ältere Werte `dots, ovals, diamonds, sleepy, sparkle, skeptical, calm` werden zugeordnet, siehe „Augenstile (2026-11)“), Accessoires `none, beret, bowtie, glasses, headphones, cap, flower, crown, beanie, tophat, cowboy, partyhat, wizard, halo, hair_bow, cat_ears, bunny_ears, horns, headset, sunglasses, monocle, tie, scarf`, beliebige Hex-Farbe. Mütze, Fliege, Kappe und Kopfhörer nehmen automatisch eine Kontrastfarbe zur Körperfarbe.

Stimmungen: `.idle` (Atmen + gelegentliches Blinzeln), `.working` (Hüpfen und Wackeln, offener Mund), `.workingStill` (statische Arbeits-Pose für Widgets: geneigt, Bewegungslinien, Funken). „Bewegung reduzieren“ schaltet Animationen ab. Unter 60 pt wird etwas größer gezeichnet, damit der Körper die Fläche füllt; Fell, Härchen und Gesicht passen sich der Größe an (24 bis 1024 pt getestet).

Der teure Körper ist eine eigene `Equatable`-View und wird beim Atmen nicht neu gezeichnet; nur Gesicht/Accessoire laufen mit der Animation (30 fps). In der Seitenleiste sind Maskottchen statisch, außer der Scoop arbeitet.

## Widgets und Live Activity

Die App schreibt bei jeder Änderung einen kompakten Schnappschuss (`WidgetSnapshot`: id, Name, Label, Maskottchen, angepinnt, arbeitet, aktuelle Statuszeile, Laufbeginn, ungelesen, letzte Nachricht) als JSON in den App-Group-Container und lädt die Widgets neu (gedrosselt auf max. alle 5 s, sofort bei Wechsel des Arbeitsstatus). Widgets lesen nur diesen Schnappschuss, ohne Netzwerk.

- **Klein** („Scoop“, konfigurierbar per AppIntent): Maskottchen, Name, Label, letzte Nachricht, Ungelesen-Zähler. Arbeitet der Scoop: Arbeits-Pose, „Arbeitet · seit 1:54“ (`Text(date, style: .timer)`) und die neueste Statuszeile. Tippen öffnet `aisbot://bot/<id>`.
- **Mittel/Groß** („Deine Scoops“, konfigurierbar, sonst angepinnte zuerst, dann zuletzt aktive; bis 4 bzw. 8): jede Zelle ist ein eigener Link zum Chat, zeigt Maskottchen, Name, Timer oder Label, Ungelesen-Zähler. Groß zeigt zusätzlich die letzte Nachricht des zuletzt aktiven Scoops.
- **Sperrbildschirm (iOS):** rund = Zahl arbeitender Scoops, rechteckig = Status eines Scoops.
- **Timeline:** arbeitet ein Scoop, Aktualisierung nach ~90 s (der Timer läuft von selbst), sonst stündlich.
- **Live Activity (iPhone):** eine gemeinsame Aktivität für alle arbeitenden Scoops, siehe unten.

### Gemeinsame Live-Aktivität (`ScoopsLiveAttributes`)

Statt einer Aktivität pro Lauf (`BotRunAttributes`, hing bei Push-to-Start teils stundenlang auf „Denkt nach“, weil das Update-Token nie beim Server ankam) gibt es EINE Aktivität, die alle gerade arbeitenden Scoops auflistet.

- **Format** (`Shared/Widget/ScoopsLiveAttributes.swift`, JSON camelCase, Datum = Sekunden seit 2001): Attribute `{"title": "AIS Scoops"}`; `ContentState` = `{"scoops": [Entry], "updatedAt": …}`, `Entry` = `id, name, label?, mascot, state (running|done|failed|stopped), statusLine, steps, startedAt, finishedAt?`.
- **Server startet** per Push-to-Start (`attributes-type: "ScoopsLiveAttributes"`). Das Token kommt aus `Activity<ScoopsLiveAttributes>.pushToStartTokenUpdates` → `POST /api/devices` mit `platform: "ios-scoops-live-start"` (wird bei fehlender Verbindung beim nächsten Vordergrund nachgeholt).
- **Updates:** bevorzugt APNs-Broadcast-Kanal (iOS 18+, `pushType: .channel`), sonst Token. Läuft die Aktivität mit Token, meldet die App es → `POST /api/live-activities` (`chat_id: "scoops"`, `run_id: <Server-Sitzung>`).
- **Vordergrund:** Arbeitet ein Scoop und gibt es keine Aktivität → `POST /api/live-activity/ensure` (`{"active", "session", "channel", "content"}`); bei `active` startet die App sie lokal mit dem Server-Inhalt und `pushType: .channel(channel)` bzw. `.token`. Danach aktualisiert die App nur im Vordergrund aus dem Widget-Schnappschuss nach (höchstens alle 30 s ein `ensure`, außer die Menge arbeitender Scoops ändert sich). Demo-Modus: rein lokal ohne Push.
- **Aufräumen** (Start und jedes Zurückkehren in die App): alle alten `BotRunAttributes`-Aktivitäten sofort beenden; mehrere Scoops-Aktivitäten → nur die neueste behalten; arbeitet laut Schnappschuss kein Scoop mehr, endet die Aktivität mit „Alle fertig“ (5 s sichtbar). `BotRunLiveActivity` bleibt vorerst im Widget-Bundle, damit alte Aktivitäten noch gerendert und beendet werden können.
- **Design:** Sperrbildschirm mit Kopfzeile („3 Scoops arbeiten“ / „Tina arbeitet“ / „Alle fertig“) und bis zu 4 Zeilen (laufende zuerst, Timer bzw. Häkchen/Fehler/Stopp, sonst „+N weitere“); Dynamic Island kompakt = überlappende Maskottchen + Anzahl bzw. Timer des einzigen, minimal = erstes Maskottchen, erweitert = bis 3 Zeilen. Jede Zeile öffnet `aisbot://bot/<id>`.
- **Testen:** `-mock -livedemo` startet lokal eine Aktivität mit drei Beispiel-Scoops (nur Debug). Push-to-Start im Simulator: `xcrun simctl push <udid> com.ais.aisbot scripts/push-tests/scoops-live-start.apns`. Screenshots: `Screenshots/scoops-live-lockscreen.png`, `Screenshots/scoops-live-island-compact.png`.

App Group: iOS `group.com.ais.aisbot`. Auf dem Mac `MYXQKK3T2Z.com.ais.aisbot` (Team-Präfix): Damit brauchen lokale Mac-Builds kein Profil mit registriertem Gerät, und das App-Store-Archiv funktioniert ebenfalls.

Die Widget-Bilder in `Screenshots/widgets-*.png` sind mit `ImageRenderer` aus denselben Widget-Views gerendert (Demo-Daten), nicht vom Home-Bildschirm abfotografiert.

## Push (APNs)

- Capability: `aps-environment = production` (iOS, App und Widget) bzw. `com.apple.developer.aps-environment = production` (Mac) in den **Release**-Entitlements. Debug: iOS `development`, Mac ohne Push, damit lokale Mac-Builds ohne Profil laufen (`AISBot/Support/*-Debug.entitlements`).
- Nach erfolgreicher Verbindung fragt die App nach der Mitteilungs-Erlaubnis, registriert sich bei APNs und meldet das Token per `POST /api/devices` (`platform` `ios` bzw. `macos`, `name` = Gerätename). Das passiert bei jedem Start und bei Token-Wechsel erneut (idempotent).
- Payload: `bot_id` und `message_id` neben `aps`. Tippen öffnet den Chat. Ist genau dieser Chat gerade sichtbar, wird das Banner unterdrückt (`willPresent → []`).
- Sobald der Server das Token kennt, erzeugt die App keine eigenen lokalen Mitteilungen mehr (keine Dubletten). Vorher bleibt die lokale Mitteilung über den offenen WebSocket als Rückfallebene.
- **Widget-Push (iOS 26+):** Beide Widgets haben `.pushHandler(ScoopWidgetPushHandler.self)`. Die App liest das Token über `WidgetCenter.shared.currentPushInfo` und meldet es mit `platform: "ios-widgets"`. Der Server schickt `apns-push-type: widgets` an `com.ais.aisbot.push-type.widgets` mit `{"aps":{"content-changed":true}}`. Auf dem Mac gibt es die API auch, sie wird aber noch nicht gemeldet (Server kennt nur `ios-widgets`).
- Live Activities: gemeinsame `ScoopsLiveAttributes`-Aktivität mit Broadcast-Kanal bzw. Token, siehe „Gemeinsame Live-Aktivität“.
- **Absenderbild (Build 15):** Payload zusätzlich mit `author_id`, `author_name`, `chat_id`, `group_name` und `mutable-content: 1`. Die Extension `AISBotNotifications` macht daraus Communication Notifications, siehe „Build 15 → Mitteilungen mit Scoop-Bild“.

## Benutzerkonten (API v1.12, Phase 1)

Konzept und Convex-Schnittstelle: `docs/accounts.md` („Ist-Stand Phase 1“). Das Konto ist **optional**: Wer per Token verbunden ist, bleibt verbunden.

- **Ablauf:** Ohne Verbindung zeigt die App die Anmeldung („Mit Apple anmelden“, Maskottchen-Runde, Hinweis „Inhalte bleiben auf deinem Mac“). Darunter „Erweitert: Manuell verbinden“ (Server-Adresse + Token, wie bisher) und der Demo-Modus. Angemeldet erscheint stattdessen „Hallo, …!“ mit **Deine Server** (Name, online/offline, Version, Adresse). Antippen verbindet mit der Server-URL und dem Sitzungs-JWT; „…“ bzw. Kontextmenü: Umbenennen, Entfernen. **Server hinzufügen**: 8-stelliger Code (`ABCD-2345`), den der Mac nach `bin/aisbot cloud-link` zeigt (später die Server-App).
- **Einstellungen → Konto:** abgemeldet ein optionaler Apple-Knopf; angemeldet Name/E-Mail (→ Blatt mit angemeldeten Geräten samt „Abmelden“ pro Gerät, „Abmelden“, „Konto löschen“ mit Bestätigung) und „Deine Server“ (Server wechseln). Bei einer Konto-Verbindung zeigt „Verbindung“ den Server-Namen, „Server wechseln“ und „Trennen“ statt des Token-Felds.
- **Code:** `AISBot/Account/` – `AccountStore` (Anmeldung, Schlüsselbund, Erneuern, Server, Geräte), `CloudService` (Protokoll; `ConvexCloudService` über die Convex-HTTP-API `/api/query` + `/api/mutation` und die HTTP-Actions `/auth/apple` + `/auth/refresh`, kein SDK; `MockCloudService`), `CloudConfig` (Adresse), `AccountModels`. Oberflächen: `Views/OnboardingView.swift` (Anmeldung, manueller Weg), `Views/Account/ServersView.swift`, `Views/Account/AccountView.swift`. Server-Zugang: `Networking/ServerAuth.swift` – `APIClient`/`EventSocket` nutzen wahlweise API-Token oder Sitzungs-JWT.
- **Convex:** Produktion `https://helpful-puma-445.eu-west-1.convex.cloud` (HTTP-Actions: `.convex.site`). Überschreibbar mit `-cloudurl <…convex.cloud>` oder UserDefaults `cloudURL` (z. B. Dev `https://merry-vole-238.eu-west-1.convex.cloud`).
- **Sitzung:** JSON mit Sitzungs-JWT, Refresh-Token, Ablauf, Nutzer und Apple-Kennung im Schlüsselbund (`com.ais.aisbot` / `cloud-session`). Erneuern im Hintergrund, wenn weniger als 7 Tage übrig sind, sofort bei < 1 Min. und einmal nach jedem 401 (Server oder Convex). `/auth/refresh` mit 401 → lokal abgemeldet. Widerruft man „Mit Apple anmelden“ in den Apple-ID-Einstellungen, meldet die App beim Start ab. Nonce: SHA-256 im Apple-Request, roher Wert an `/auth/apple`.
- **Verbindung:** UserDefaults `serverURL`, `cloudServerID`, `cloudServerName`. Ein vorhandener API-Token bleibt bei einer Konto-Verbindung im Schlüsselbund und wird bei „Manuell verbinden“ vorgeschlagen. Abmelden/Konto löschen trennt nur Konto-Verbindungen; Token-Verbindungen bleiben.
- **Capability:** `com.apple.developer.applesignin = [Default]` in allen vier App-Entitlements (iOS/macOS, Debug/Release). Auch Mac-Debug-Builds brauchen dafür jetzt ein Profil: einmal mit `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` und dem Team-Key bauen (siehe Projekt-AGENTS.md); danach geht `xcodebuild … build` wieder ohne Zusatz.
- **Demo/Screenshots** (mit `-mock`, Beispielkonto „Arman Samary“ mit Mac Studio online und MacBook Air offline): `-accountscreen signin` (Anmeldung; der Apple-Knopf meldet das Beispielkonto ohne Apple an), `-accountscreen servers` („Deine Server“ ohne Verbindung), `-addserver` (Server hinzufügen offen), `-settings -accountsheet` (Konto-Blatt), `-manualconnect` („Manuell verbinden“ aufgeklappt). Kopplungscode `FEHLER00` zeigt die Fehlermeldung, jeder andere fügt „Mac mini“ hinzu. In der Demo verbinden alle Server mit den Demo-Daten.
- **Mac:** `SignInWithAppleButton` ignoriert auf macOS die Höhe; dort zeichnet die App einen eigenen Knopf nach Apples Vorgaben und startet `ASAuthorizationController` selbst (`AppleSignInLauncher`).
- **Geprüft (Demo, iPhone 18 Pro iOS 27.2 und Mac):** Anmeldung → Liste, Code koppeln (Formatierung `K7QX-29PL`, dritter Server erscheint), Verbinden, Einstellungen → Konto, Geräte, Konto löschen (Bestätigung → abgemeldet, Konto-Verbindung getrennt, Einstellungen zeigen den Apple-Knopf).
- **Nicht getestet:** echte Anmeldung bei Apple und gegen Convex-Produktion (braucht ein Gerät bzw. signierten Build mit Apple-ID), Verbinden mit einem echten gekoppelten Server per JWT.
- **Screenshots:** `accounts-iphone-anmelden.png`, `accounts-iphone-deine-server.png`, `accounts-iphone-server-hinzufuegen.png`, `accounts-iphone-einstellungen-konto.png`, `accounts-iphone-konto.png`, `accounts-iphone-konto-loeschen.png`, `accounts-iphone-einstellungen-ohne-konto.png`, `accounts-mac-anmelden.png`, `accounts-mac-deine-server.png`, `accounts-mac-einstellungen-konto.png`, `accounts-mac-konto.png`.

## Geteilte Scoops (API v1.14, Phase 1)

Konzept und verbindliche Schnittstelle: `../docs/sharing.md` („Ist-Stand Phase 1“). Ein Scoop gehört seinem **Admin** und läuft
auf dessen Server mit dessen Konten. Gäste sehen ihn unter **„Mit mir geteilt“**; ihre App spricht direkt mit dem Server
des Admins (eigenes Sitzungs-JWT), Convex kennt nur das Verzeichnis.

- **Admin (Profil eines eigenen Scoops):** Abschnitt **Teilen · n Personen**: Personen (Bild mit Initialen, Name, Rolle ·
  Rechner-Stufe; die Zeile öffnet ein Menü mit Rolle, Rechner und „Entfernen …“ mit Bestätigung), offene Einladungen
  (Menü „Einladung widerrufen“), **Person einladen** (Rolle Lesen/Schreiben/Bearbeiten, Rechner Kein Zugriff/Zusehen/
  Steuern → `shares:createInvite` (Action) → Link mit `ShareLink` und „Link kopieren“). Darunter **Werkzeuge für Geteilte**
  (Websuche, Rechner, verbundene Apps einzeln, MCPs einzeln, Telefon, Mails; Auswahl aus `GET /api/bots/{id}/sharing`,
  Standard nur Websuche) und **Tageslimit pro Gast** (0–100 $, Schritt 0,50 $ bzw. 1 $). Nach jeder Änderung in Convex ruft
  die App `POST /api/shares/refresh` am eigenen Server. Teilen braucht eine Konto-Verbindung (`settings.cloudServerID`),
  sonst erklärt der Abschnitt, warum es nicht geht. Geteilte eigene Scoops tragen in der Seitenleiste ein Personen-Symbol.
- **Kosten pro Scoop und pro Person:** Profil → **Kosten** (heute, Monat, gesamt aus `GET /api/bots/{id}/usage`), bei
  geteilten Scoops zusätzlich **Kosten pro Person · Monat** (Admin und jeder Gast mit Rolle, heutigen Kosten und Balken fürs
  Tageslimit). Gäste sehen nur **Deine Kosten** und „noch x $ von y $“. Einstellungen → Kosten zeigt **Pro Scoop**
  (`/api/usage.by_bot`). Ältere Server (404) → Hinweis „braucht AIS Scoops Server 1.14“. Neu geladen beim Öffnen und nach
  jedem Lauf.
- **Gast:** Seitenleiste **Mit mir geteilt** (`shares:mine`: Scoop, Admin, online/offline-Punkt, letzte Nachricht mit
  Absender; Kontextmenü Profil, Austreten). Ohne eigenen Server zeigt die App trotzdem die Seitenleiste mit einem Hinweis
  „Server verbinden“ (öffnet die Einrichtung als Blatt). Rollen: **Lesen** ohne Eingabefeld (Hinweis „Du kannst hier nur
  mitlesen …“), **Schreiben** normal, **Bearbeiten** mit Aussehen, Routinen, Stimme, Charakter und Gedächtnis (ohne Modell,
  Rechner-Zuordnung, Bereiche). Rechner: **Kein Zugriff** keine Live-Bilder, **Zusehen** Bildschirm ohne „Übernehmen“
  („Nur zusehen“), **Steuern** wie der Admin. Profil zeigt „Läuft bei <Admin>“, „Geteilt mit dir“ (Admin, Server, online,
  Rolle, Rechner) und **Austreten** (mit Bestätigung; meldet das Gerät dort ab, wenn es der letzte Scoop dieses Servers war).
- **Store-Architektur:** `bots` = eigene Scoops, `sharedBots` = geteilte (Platzhalter aus dem Verzeichnis, dann Daten vom
  Admin-Server). `bot(id)` sucht in beiden, `ownBot(id)` nur eigene (Gruppen, Erwähnungen). Je Admin-Server eine
  `GuestConnection` (`APIClient` + `EventSocket` mit dem eigenen Sitzungs-JWT, `Sharing/AppStore+Sharing.swift`).
  `service(for: chatID)` leitet jeden Chat-Aufruf (Nachrichten, Senden, Stopp, Lesestatus, Dateien, Reaktionen, Profil,
  Bilder, Sprechmodus) an den richtigen Server; `scopedService` setzt bei Gästen `?bot=` für Rechner, Diktat und Stimmprobe.
  Ereignisse der Admin-Server gelten nur für deren geteilte Scoops (`applyGuest`, inkl. `share.updated`). Rechner-IDs gelten
  je Server: Beim Wechsel zwischen eigenem und geteiltem Scoop wird der Rechner-Status neu geladen. Abgleich mit Convex beim
  Start, beim Zurückkehren in die App und alle 60 s im Vordergrund; die eigene Ein-Server-Logik bleibt unverändert
  (`resetData` behält geteilte Chats).
- **Gemeinsamer Chat:** Nachrichten anderer Personen links mit Initialen-Bild und Namen (`meta.author_name`, „Admin“-Kapsel),
  eigene rechts (`author_user_id` == eigene Konto-ID; im eigenen Chat ohne Absender = ich). Nachrichten anderer zählen als
  ungelesen. Freigaben: Gäste sehen „Wartet auf Freigabe durch <Admin>“ (bzw. freigegeben/abgelehnt) ohne Knöpfe; der Admin
  sieht unter Karten aus Gast-Läufen „Angefragt von <Name>“. Reaktionen der Gäste (`user:<id>`) werden lokal auf `user`
  abgebildet, die des Admins auf `user:admin`.
- **Einladungslink:** URL-Schema `aisscoops` (neben `aisbot`); `aisscoops://invite/<code>` und `https://<site>/i/<code>`
  öffnen das **Annahme-Blatt** (Scoop-Vorschau, Admin, Rolle, Rechner, Gültigkeit; `shares:inviteInfo` ohne Anmeldung).
  Ohne Anmeldung erscheint „Mit Apple anmelden“, danach **Annehmen** → Scoop öffnet sich. Abgelaufen/benutzt → Erklärung.
- **Push:** Das Gast-Gerät meldet sein Token am Admin-Server über `POST /api/shared/devices` (nach dem Verbinden und bei
  neuem Token); Tippen auf die Mitteilung öffnet den geteilten Chat (`bot_id`), auch bei Kaltstart.
- **Demo/Screenshots** (`-mock`): Mila ist mit Lena (Schreiben, Zusehen) und Jonas (Lesen) geteilt, eine Einladung ist
  offen, Lena schreibt im Chat mit. Unter „Mit mir geteilt“ steht Juna von Sophie Krämer (Schreiben, Zusehen) mit
  wartender Freigabe. `-acceptdemo` zeigt das Annahme-Blatt (Annehmen fügt „Kiko“ hinzu, Codes mit `ALT…` sind abgelaufen),
  `-sharingdemo`/`-costdemo` öffnen im Profil „Teilen“ bzw. „Verwalten → Kosten“, `-invitedemo` öffnet „Person einladen“
  (`-invitedemo link` gleich mit Link).
- **Code:** `AISBot/Sharing/` – `SharingModels.swift` (Verzeichnis, Einladungen, Kosten, Endpunkte), `AccountStore+Sharing.swift`,
  `AppStore+Sharing.swift`, `SharingViews.swift` (Teilen, Einladen, Werkzeuge, Tageslimit, Kosten, Annahme-Blatt, fremde
  Nachrichten, Gast-Freigaben), `MockGuestData.swift`; Modelle in `Shared/Models/Sharing.swift` (Rolle, Rechner-Stufe,
  Personen, `GuestTools`).
- **Nicht getestet:** gegen Convex-Produktion und einen echten Admin-Server mit zweitem Apple-Konto (braucht zwei Geräte bzw.
  Konten), echter Gast-Push. Universal Links sind noch nicht eingerichtet (der https-Link öffnet über eine Weiterleitungsseite).
- **Screenshots:** `sharing-iphone-sidebar.png`, `sharing-iphone-guest-chat.png`, `sharing-iphone-guest-profil.png`,
  `sharing-iphone-accept.png`, `sharing-iphone-teilen.png`, `sharing-iphone-einladen.png`, `sharing-iphone-kosten.png`,
  `sharing-mac-guest.png`, `sharing-mac-teilen.png`, `sharing-mac-kosten.png`, `sharing-mac-accept.png`.

## Release (TestFlight / App Store)

- Version `MARKETING_VERSION = 1.0` (project.yml), Build-Nummer `CURRENT_PROJECT_VERSION`, per Kommandozeile überschreibbar (`CURRENT_PROJECT_VERSION=7`); gilt für App, Widget (`com.ais.aisbot.widgets`) und Mitteilungs-Extension (`com.ais.aisbot.notifications`, ab Build 15).
- `ITSAppUsesNonExemptEncryption = NO`, Mac-Kategorie `public.app-category.productivity`, Icon in allen Größen (iOS 1024 ohne Alpha, Mac 16–512@2x).
- Archive (automatische Signierung, Team-API-Key):
  ```sh
  xcodebuild -scheme AISBot -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/claude-501/aisbot-ios.xcarchive archive -allowProvisioningUpdates -authenticationKeyPath …/AuthKey_B2M5G9DH6U.p8 -authenticationKeyID B2M5G9DH6U -authenticationKeyIssuerID 0129d0a3-d63c-4162-a69b-f6ff28b5314e
  # dasselbe mit -destination 'generic/platform=macOS' → /tmp/claude-501/aisbot-mac.xcarchive
  ```
- Hochladen: `scripts/upload-testflight.sh <build> [ios|mac|all]` archiviert und exportiert mit `ExportOptions-ios.plist` / `ExportOptions-mac.plist` (`app-store-connect`, `destination upload`, Team MYXQKK3T2Z, automatisch). Der Export signiert mit Apple Distribution (Mac-Installer per Cloud-Signierung).
- Hinweis: Die App Group `group.com.ais.aisbot` lässt sich **nicht** über den API-Key anlegen (die App-Store-Connect-API kennt keine App Groups). Sie wurde einmalig über das in Xcode angemeldete Apple-ID-Konto registriert (`xcodebuild … -allowProvisioningUpdates` ohne Key). Seitdem funktioniert das Archiv auch mit dem API-Key.

## Entscheidungen

- **ATS:** `NSAllowsLocalNetworking` (127.0.0.1, `.local`, LAN) plus `NSExceptionDomains` für `ts.net` mit Unterdomänen und erlaubtem HTTP. Tailscale Serve liefert ohnehin HTTPS mit gültigem Zertifikat. Reine IP-Adressen (z. B. Tailscale `http://100.x.y.z:8787`) blockiert ATS nach Apples Doku nicht, deshalb kein `NSAllowsArbitraryLoads`. Noch nicht mit einer echten Tailscale-IP geprüft; falls doch blockiert, gezielt eine Ausnahme ergänzen (TODO).
- **Mac-Sandbox:** App Sandbox + `network.client` + App Group; Widget: Sandbox + App Group.
- **Datumsformat:** ISO-8601 mit beliebig vielen Nachkommastellen; ohne Zeitzone wird UTC angenommen.
- **Gruppe leeren:** Beim Bearbeiten wird ein leerer Abschnitt als `"section": null` gesendet.

## Offene TODOs

- **Push auf echten Geräten testen** (TestFlight): Geräte-, Widget- und Live-Activity-Tokens, Banner-Unterdrückung im offenen Chat.
- **Mikrofon im Simulator:** Auf diesem Mac bricht der iOS-Simulator beim Zugriff auf das Audio-Input (`AURemoteIO::Initialize` RPC-Timeout in AudioToolbox) ab, bevor die App reagieren kann. Diktat und Sprachmodus deshalb auf echtem iPhone/iPad/Mac prüfen (Mikrofon-/Spracherkennungs-Erlaubnis erscheinen korrekt).
- iPad-Layoutfixes (Titelabstand, Tastatur-Kante, Spalten-Sprung beim Widget-Link) sind umgesetzt, aber mangels iPad-Simulator im Gerätepanel nur auf Mac/iPhone geprüft.
- Sprachmodus in Gruppen (optional, noch nicht umgesetzt).
- Widget-Push auf dem Mac melden, sobald der Server eine passende Plattform kennt.
- Übernehmen: Mausbewegungen (`move`) werden nicht gesendet (nur Klicks/Ziehen/Scrollen/Tasten).
- Reine Tailscale-IP per `http://` nicht getestet.

## Eigenes Scoop-Bild (API v1.12)

Statt des Fell-Maskottchens kann ein Scoop ein eigenes Bild haben (Foto oder Grafik).

- **Bearbeiten:** „Aussehen bearbeiten“ (bzw. „Neuer Scoop“) → Umschalter *Maskottchen / Eigenes Bild* → „Foto wählen“ (Mediathek), auf dem Mac auch „Datei …“ oder Bild direkt auf die Vorschau ziehen → Zuschneiden (runde Vorschau, ziehen, Zoom per Regler/zwei Fingern) → „Sichern“ lädt ein quadratisches JPEG/PNG (max. 512 px) hoch. „Zurück zum Maskottchen“ löscht das Bild auf dem Server. Accessoires gibt es nur beim Maskottchen; die Farbe bleibt als Akzent (Ring, solange der Scoop arbeitet).
- **Zentrale Anzeige:** Hat `mascot.photo` einen Wert, zeichnet `MascotView` automatisch das runde Bild (`ScoopPhotoSlot` in `Shared/Mascot/ScoopPhoto.swift`). Damit erscheint es überall, wo ein Scoop-Avatar steht: Seitenleiste, Chat-Kopf, Nachrichten/Statuszeilen, @-Liste, Befehlspalette, Profil, Gruppen-Avatare, Widgets und Live-Aktivität. Beim Arbeiten läuft ein Ring in der Akzentfarbe um das Bild, beim Sprechen pulsiert es leicht.
- **Cache:** `ScoopPhotoCache` lädt jede Version einmal (`GET /api/bots/{id}/avatar?v=…`) in den App-Group-Container (`ScoopPhotos/<id>-<version>.img`) und verwirft alte Versionen. Widgets und Live-Aktivität lesen nur von dort (Fallback: Maskottchen). Für Mitteilungen rendert `NotificationAvatarSync` das Foto vollflächig als PNG.
- **Demo:** Nora hat im Demo-Modus ein erzeugtes Testbild (Abendhimmel, kein echtes Foto). Nur Debug: `-cropdemo` öffnet zusammen mit `-select <id> -editlook` das Zuschneiden mit diesem Bild.
- **Widget-Vorschau rendern:** `AIS_RENDER_ONLY=widgets` rendert nur die Widget-Tafeln (inkl. Demo-Bild). Mit `AIS_RENDER_STDOUT=1` kommen die PNGs als `PNG <name> <base64>` auf stdout – so geht es auch mit einem signierten, sandboxed Build.

## Live-Sprechmodus (API v1.13, GPT-Live-1)

Der Sprechmodus (Wellen-Taste im Eingabefeld) spricht standardmäßig **live** über den Server mit OpenAI GPT-Live-1: natürliche Stimme, jederzeit dazwischenreden, Untertitel beider Seiten, Laufzeit und geschätzte Kosten im Kopf („Live · Marin · 1:23 · ≈ 0,07 $“). Protokoll: `../docs/API.md`, Abschnitt „v1.13 – Live-Sprechmodus“.

- **Dateien:** `AISBot/Voice/LiveVoiceSession.swift` (WebSocket `/api/voice/live`, Zustand, Untertitel, Kosten), `AISBot/Voice/LiveAudio.swift` (AVAudioEngine: Mikrofon → PCM16 24 kHz in 40-ms-Paketen, Wiedergabe über `AVAudioPlayerNode`), `AISBot/Voice/VoiceModeView.swift` (Oberfläche, Live und Gerätestimme).
- **Audio:** iOS `AVAudioSession` `.playAndRecord` / `.voiceChat` mit `.defaultToSpeaker`, `.allowBluetoothHFP` (AirPods), Sprachverarbeitung der Engine (Echo-Unterdrückung) auf iOS und macOS. Bei `AVAudioEngineConfigurationChange` (Route gewechselt, AirPods, Sprachverarbeitung) baut sich die Engine selbst neu auf. Im Simulator ist die Sprachverarbeitung aus, weil sie dort endlos neu konfiguriert. Kein Hintergrundbetrieb.
- **Bedienung:** Maskottchen antippen, während der Scoop spricht → unterbrechen (Wiedergabe sofort leer). „Stumm“ schaltet das Mikrofon ab. Erledigt der Scoop eine Aufgabe (Mails, Kalender, Recherche …), zeigt eine Zeile den Auftrag, und das Maskottchen arbeitet. Nach Ende (Stille 2 Min., Limit 15 Min.) gibt es „Neu starten“.
- **Verlauf:** Gesprochenes steht danach im Chat. Nutzer-Beiträge tragen das Wellen-Symbol, Scoop-Beiträge die Zeile „Live gesprochen“ (`meta.live`).
- **Stimme im Profil:** „Stimme“ wählt die Live-Stimme (Liste vom Server, z. B. Marin, Cedar, Juni, Nuri, Flitz) oder „Gerätestimme (offline)“. „Rückfall (offline)“ ist die Apple-Stimme, falls Live nicht klappt. „Probehören“ spielt eine kurze Probe der Live-Stimme vom Server (WAV, dort zwischengespeichert), bei der Gerätestimme spricht das Gerät. Gespeichert im Feld `voice` als `live:<name>|<Geräte-ID>` bzw. `device:<Geräte-ID>`.
- **Rückfall:** Kein OpenAI-Schlüssel, älterer Server, Gruppe oder Verbindungsfehler (15 s ohne `ready`) → automatisch der bisherige Ablauf mit Gerätestimme, mit Hinweis im Kopf.
- **Testen ohne Armans Server:** Testinstanz mit Live-Mock starten (siehe `Server/tests/test_live_voice.py`), App mit `-testserver http://127.0.0.1:<port> <token>` starten. Im Simulator die Mikrofon-Freigabe vorher setzen.

## Screenshots

`Screenshots/` (nur Demo-Daten):
- Mac Nacht/Hell: Chat mit Profil, Gedächtnis, Markdown, Gruppe (`mac-*-gruppe`), Bibliothek, Anhänge mit @-Vorschlägen, Neue Gruppe, Neuer Scoop (Formen/Figuren), Sprachmodus, Bot-Rechner übernehmen.
- iPhone: Seitenleiste und Chat (Nacht/Hell), Profil-Sheet, Gruppe, Sprachmodus.
- Widgets in beiden Entwürfen, Übersicht aller Maskottchen (`scoops-maskottchen.png`), App-Icon.
- Live-Sprechmodus (`live-*.png`, Testinstanz mit Live-Mock): Gespräch mit Untertiteln, Laufzeit und Kosten (`live-iphone-gespraech`), Chatverlauf mit „Live gesprochen“ und Live-Auftrag (`live-iphone-chatverlauf`), Stimmenauswahl im Profil (`live-iphone-stimme`), Mac beim Warten auf die Mikrofon-Freigabe (`live-mac-gespraech`).
- Geteilte Scoops (`sharing-*.png`): Mit mir geteilt, Gastchat und -profil, Einladung annehmen, Teilen, Einladungslink, Kosten pro Person.
- Eigenes Bild (`photo-*.png`): Bearbeiten, Zuschneiden, Seitenleiste, Chat mit Profil, Ergebnis nach dem Hochladen (Seitenleiste mit Arbeits-Ring, Gruppen-Avatare), Widgets.

`-render-assets` muss mit einem **unsignierten** Build laufen (`CODE_SIGNING_ALLOWED=NO`), weil die Sandbox sonst das Schreiben außerhalb des Containers verhindert.

## Profil: Übersicht und Unterseiten (Build 2026-11)

- **Übersicht** (rechte Spalte bzw. Blatt): Kopf (Maskottchen, Name, Rolle, Modell), **Anstehend** (die nächsten drei
  Routinen, darunter „Alle Routinen“), **Computer** (Rechner, Live-Vorschau), danach Navigationszeilen mit Kurzinfo:
  **Bibliothek** (Anzahl), **Modell** (Name), **Persönlichkeit** (Stimme), **Teilen** („2 Personen“/„Nicht geteilt“) und
  abgesetzt **Verwalten** („heute 0,12 $“). Reihenfolge nach Häufigkeit: Dateien wiederfinden und Modell wechseln
  kommen öfter vor als Persönlichkeit und Teilen, die man meist einmal einrichtet.
- **Unterseiten:** Modell (Claude/OpenAI, darunter „Verstärkung“: an welches Modell der Scoop selbst abgibt, nur
  Anzeige), Persönlichkeit (Aussehen, Stimme, Charakter), Teilen (Personen und Einladungen, „Werkzeuge“ als eigene Seite,
  Tageslimit pro Gast, Kosten pro Person), Verwalten (Haupt-Scoop/Initiative, Routinen, Fähigkeiten, Gedächtnis, Kosten,
  Seitenleiste mit Anheften und Bereich, Verlauf leeren, Löschen), Bibliothek.
- **Gäste** sehen „Geteilt mit dir“, Anstehend/Persönlichkeit/Routinen/Fähigkeiten/Gedächtnis nur mit „Bearbeiten“,
  Computer ab „Zusehen“, kein Modell und kein Teilen; unter Verwalten ihre Kosten und „Austreten“. Seiten ohne Recht
  zeigen „Für dich nicht verfügbar“ (`ProfilePage.isAllowed`).
- **Navigation:** eigener Seitenstapel (`ProfileStack` in `Views/Profile/ProfilePages.swift`) auf allen Geräten, kein
  `NavigationStack`: Im Inspector reichte er `navigationDestination` an den äußeren `NavigationSplitView` weiter (die
  Unterseite ersetzte auf dem Mac den Chat), und auf dem iPhone steckte er beim Start im `.inspector` des Chats (Titel
  „Profil“ im Chat, Chat leer). Feste Kopfleiste mit runden Liquid-Glass-Knöpfen Zurück/Schließen (44 pt iOS, 36 pt Mac)
  und Titel 17 pt; der Inhalt scrollt darunter, das X liegt nie über Inhalten. iOS: Wischen vom linken Rand führt zurück,
  Mac: ⌘[. Anderer Scoop → zurück zur Übersicht.
- **Screenshots:** `profil-iphone-uebersicht.png`, `profil-iphone-modell.png`, `profil-iphone-teilen.png`,
  `profil-mac-uebersicht.png`, `profil-mac-modell.png`, `profil-mac-teilen.png`, `profil-mac-gast-verwalten.png`.

## Antworten auf Nachrichten (API v1.15)

Wie bei Telegram auf eine bestimmte Nachricht antworten, in Scoop-Chats und Gruppen, auf Nutzer- und Scoop-Nachrichten.
Code: `AISBot/Views/Chat/Replies.swift` (Store-Erweiterung, Zitat, Antwort-Leiste, Wischgeste).

- **iPhone/iPad:** Blase nach links wischen. Rechts erscheint ein Antwort-Pfeil, der ab 64 pt einrastet (gefüllt,
  leichtes Haptik-Feedback); Loslassen federt zurück und setzt die Antwort. Die Geste ist ein `UIPanGestureRecognizer`
  (`UIGestureRecognizerRepresentable`), der nur bei klar waagerechter Bewegung nach links beginnt – senkrechtes Scrollen
  und Zurück-Wischen vom linken Rand bleiben unberührt (im Simulator geprüft). Außerdem „Antworten“ im Menü nach langem
  Drücken und als VoiceOver-Aktion.
- **Mac:** „Antworten“ im Kontextmenü und als Knopf (Pfeil) neben dem Smiley beim Überfahren; kein Wischen.
- **Eingabe:** Leiste über dem Feld mit farbigem Strich (Maskottchenfarbe des Scoops, bei Personen Akzent),
  „Antwort an Mila“ bzw. „Antwort auf deine Nachricht“, einzeiliger Auszug, X bzw. Esc bricht ab. Das Feld bekommt den
  Fokus. Die Leiste gehört zum Entwurf (`ComposerDraft.replyTo`) und wird mit ihm gesichert (`DraftArchive`).
- **Blase:** oben ein kompaktes Zitat (Name, eine Zeile; eigene Nachrichten heißen „Du“). Antippen springt zum Original
  (lädt bei Bedarf bis zu 10 ältere Seiten nach) und hebt es kurz hervor.
- **Senden:** `reply_to` mit der ID; der Server legt `meta.reply_to {id, role, author_id, author_name, text}` an, gibt
  dem Modell den Bezug mit und lässt in Gruppen ohne `@` den zitierten Scoop antworten.
- **Demo:** `-replydemo` (Antwort-Leiste auf die letzte Scoop-Nachricht), `-replyjump <id>` (Sprung mit Hervorhebung).
  Beispieldaten: `m_5`, `m_8` (Mila) und `g_12`, `g_13` (Launch-Team).
- **Screenshots:** `antworten-mac-nacht-leiste.png`, `antworten-mac-hell-gruppe-sprung.png` (Sprung zum Original,
  Hover-Knöpfe), `antworten-iphone-nacht-leiste.png`, `antworten-iphone-nacht-gesendet.png`,
  `antworten-iphone-hell-wischen.png` (eingerastet), `antworten-iphone-hell-leiste.png`, `antworten-iphone-hell-menue.png`.
- **Mac-Screenshots:** Der Debug-Build öffnet nach `open -n … --args -ApplePersistenceIgnoreState YES …` erst nach einem
  zweiten `open "<App>"` (Reopen) sein Fenster.

## Apps verbinden: ganzer Katalog (API v1.16)

- **Wie Grok „Connect apps“:** `ConnectionsView` zeigt alle Apps aus dem Composio-Katalog (ca. 1700) statt der festen zehn.
  Kopfzeile „Apps verbinden“ mit Kapsel „N verbunden“ (Tipp filtert auf verbundene Apps), darunter waagerechte
  Kategorie-Chips: Beliebt, Verbunden, Apple, dann die Kategorien vom Server mit deutschen Namen (Produktivität,
  Kommunikation, Design, Entwicklung, Daten, Finanzen, Marketing, Vertrieb & CRM, KI, …; unbekannte im Original).
  Suchfeld unten („Alle Apps durchsuchen“) sucht über alle Apps (250 ms Pause nach dem Tippen).
- **Zeilen:** echtes App-Logo (`AppLogo`: PNG vom eigenen Server `GET /api/connections/logo/{slug}` mit Anmeldung,
  im Speicher gehalten; bis dahin SF-Symbol oder Anfangsbuchstabe), Name, einzeilige Beschreibung, rechts „Verbinden“,
  bei verbundenen Apps „Verbunden“ / „3 Konten“ (orange bei abgelaufenem Konto, „Ausstehend“ bei laufender Anmeldung).
  Verbundene Apps klappen auf und zeigen ihre Konten mit Umbenennen, Neu anmelden, Trennen (Menü •••, Kontextmenü,
  auf dem iPhone Wischen) und „Konto hinzufügen“. Die Liste ist `LazyVStack` und lädt seitenweise nach (60 je Seite).
- **Verbinden je Anmeldeart** (`auth` vom Server): `oauth` wie bisher (Name abfragen, Browserfenster, Status alle 3 s);
  `fields` öffnet `ConnectFieldsSheet` mit den Feldern vom Server (geheime als `SecureField`), optionalem Namen und
  „Wo finde ich die Angaben?“; die Werte gehen über den Server nur an Composio und werden beim Schließen vergessen.
  `none`/`unavailable` zeigen den Hinweis des Servers.
- **Apple:** Der Chip „Apple“ steht direkt nach „Verbunden“ und zeigt `ConnectionsAppleSlot`
  (`Views/ConnectionsAppleSlot.swift`), der die Apple-Dienste (`AppleConnectionsSection`) einhängt. Mit
  `isEnabled = false` bleibt der Chip ausgeblendet; `ConnectionsView` muss dafür nicht angefasst werden.
- **Ältere Server** ohne Katalog (404): die Liste kommt wie bisher aus `GET /api/connections`.
- **Demo:** Beispielkatalog mit 34 Apps aller Anmeldearten (`PreviewData.catalogApps`); Schlüssel mit „falsch“ werden
  abgelehnt. Logos holt die Demo direkt von Composio (SVG; der Mac zeichnet sie, iOS zeigt die Ersatzsymbole).
  Startargumente: `-connectionscategory <id>`, `-connectionsquery <text>`, `-connectionsexpand <slug>`,
  `-connectionsform <slug>` (öffnet das Formular).
- Screenshots: `apps-ipad-nacht-{beliebt,kategorie,suche,schluessel,verbunden}.png`, `apps-ipad-hell-verbunden.png`,
  `apps-iphone-nacht-beliebt.png` (iPhone Duo zugeklappt), `apps-mac-nacht-beliebt.png`, `apps-mac-hell-suche.png`.

## Apple-Dienste (API v1.17)

- **Was:** Die Scoops lesen und schreiben Apple-Erinnerungen und den Apple-Kalender und schlagen Kontakte nach. Das läuft
  über die Mac-App „AIS Scoops Server“ (EventKit/Contacts, Befehle `apple.*` auf dem Node-Link, docs/scoops-connect.md);
  per iCloud ist alles sofort auf dem iPhone.
- **AIS Scoops:** „Apps verbinden“ → Chip **Apple** (`Views/AppleConnectionsSection.swift`, eingehängt über
  `ConnectionsAppleSlot`): Zeilen Erinnerungen, Kalender (Datums-Symbol mit Wochentag und Tag), Kontakte mit
  „Erlauben“/„Erlaubt“. Ein Tipp schaltet den Dienst auf dem Server ein (`PATCH /api/apple`); fehlt die macOS-Freigabe,
  steht darunter „Auf dem Mac in AIS Scoops Server freigeben“. Auswahl „Apple-Rechner“, wenn es mehrere Macs gibt.
  Home, Wecker, Standort laufen seit API v1.18 über das iPhone (siehe unten). Status wird alle 3–10 s nachgeladen, solange
  sichtbar. Gäste sehen den Abschnitt nie (er hängt nur in „Apps verbinden“).
- **Mac-App:** Einstellungen → **Apple-Dienste** (Rolle `connect` und unter „Dieser Mac als Rechner“ in der Rolle
  `server`): je Dienst „Freigeben …“ (System-Dialog), Schalter „Für Scoops nutzen“ oder Link in die Systemeinstellungen.
  Entitlements `personal-information.calendars` und `.addressbook`; `build-server-dmg.sh` signiert mit
  `ScoopsConnect.entitlements`.
- **Demo:** `-mock -connections` und Chip „Apple“; `-appleready` zeigt alle drei Dienste bereit.
- **Screenshots:** `apple-*.png`.

## Apple-Dienste über das iPhone: Home, Wecker, Standort (API v1.18)

- **Was:** Die iOS-App ist selbst ein „Apple-Gerät“ (`Apple/AppleDeviceAgent.swift`): Sie meldet sich mit `device.hello`
  über die Live-Verbindung `/api/ws` an (Fähigkeiten home/alarms/location, iOS-Freigaben, Push-Token, Vorder-/Hintergrund),
  führt `device.cmd` aus und antwortet über den Socket. Im Hintergrund weckt eine stille Push (`apple_cmd`) die App
  (`AppDelegate.didReceiveRemoteNotification`); sie holt die Befehle per `POST /api/apple/device/poll` und antwortet per
  HTTP (`AppStore.appleDeviceService()` baut dafür auch ohne Fenster einen Client aus den gespeicherten Verbindungsdaten).
  Doppelt zugestellte Befehle laufen nur einmal. Der Mac meldet sich nie als Apple-Gerät an.
- **Brücken (nur iOS):** `HomeBridge` (HomeKit; Schlösser, Türen, Garagentore, Alarmanlage nur mit `confirmed`),
  `AlarmBridge` (AlarmKit; Titel/Uhrzeit merkt sich die App in UserDefaults `scoopAlarms`), `LocationBridge` (Ortung,
  Adresse per `MKReverseGeocodingRequest`, Orte per `CLMonitor` „AISScoopsOrte“ + `CLServiceSession(.always)`; Koordinaten
  nur in UserDefaults `scoopPlaces`). Timer-Countdown als Live-Aktivität im Widget-Ziel (`AlarmCountdownLiveActivity`,
  Metadaten `Shared/Widget/ScoopAlarmMetadata.swift`). Gerätebefehle haben snake_case-Parameter und werden deshalb mit
  einem einfachen Decoder gelesen (`Shared/Models/JSONValue.swift`).
- **Oberfläche:** „Apps verbinden“ → Apple → **Über dein iPhone**: „Erlauben“ löst die iOS-Abfrage aus und schaltet den
  Dienst ein, „Orte: „Immer“ erlauben“ mit Erklärung, abgelehnt → „Einstellungen“. Auf dem Mac „Auf dem iPhone erlauben“
  plus Gerätestatus im Fußtext; Geräteauswahl bei mehreren iPhones/iPads.
- **Demo:** `-mock -connections -connectionscategory apple`; auf iPhone/iPad gelten die echten iOS-Freigaben des
  Simulators, `-appleready` zeigt alles erlaubt, `-applenodevice` „noch kein iPhone“.
- **Getestet (Simulator iOS 27.2, Testserver mit `-testserver`):** Anmeldung über `/api/ws`, HomeKit-Abfrage und leere
  Zuhause-Liste, Standort „Beim Verwenden“ und „Immer“ mit simuliertem Ort (Koordinaten + Adresse), Ort anlegen (Adresse
  per Geocoding) und Liste, Befehl während die App im Hintergrund war und innerhalb von 25 s geöffnet wurde, Zeitlimit-
  Meldung. Behoben beim Testen: CLMonitor-Namen nur alphanumerisch (sonst Absturz).
- **Im Simulator nicht prüfbar:** AlarmKit (der Simulator verweigert die Freigabe ohne Abfrage, Schalter „Alarms“ lässt
  sich nicht einschalten), Auslösen von Orten (CLMonitor meldet `.unmonitored`, Persistenz nicht verfügbar), echtes
  Aufwecken per stiller Push (`simctl push` zeigt nur eine Mitteilung). Das prüft Arman per TestFlight.
- **Screenshots:** `apple2-*.png`.
