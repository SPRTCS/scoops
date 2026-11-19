# Rechner-Zugriff der Scoops (Server 1.29)

Scoops arbeiten am Mac wie Claude Code oder Codex: im Chat mit einer Shell, die erhalten bleibt, und mit
Datei-Werkzeugen, in Aufgaben mit den Werkzeugen ihres Agenten. Wie viel sie dabei ohne Rückfrage dürfen, regeln
**Rechte-Modus** und **Bereich** pro Scoop. Code: `Server/src/aisbot/access.py` (Regeln), `computer_tools.py`
(Chat-Werkzeuge), `tasks.py` (Aufgaben), Tests: `Server/tests/test_rechnerzugriff.py`, Probedurchlauf Abläufe 13–15.

## Rechte-Modus

| Modus | Was ohne Rückfrage geht | Was eine Freigabe-Karte braucht |
|---|---|---|
| **Immer genehmigen** (`ask`) | Lesen im Bereich (`ls`, `cat`, `grep`, `git status/diff/log` …) und alles im eigenen Arbeitsordner über die Datei-Werkzeuge | jeder Shell-Befehl, der etwas verändert; jede Dateiänderung außerhalb des Arbeitsordners |
| **Automatisch** (`auto`, Standard) | alles im Bereich | Löschen oder Überschreiben außerhalb des Arbeitsordners, `git push`/Force/`reset --hard`/`clean -f`, `rm -r` auf breite Pfade (`/`, `~`, `~/Documents` …), Installationen (`brew`, `npm -g`, `pip` außerhalb einer venv, `gem`, `cargo install`, `curl … \| sh`), Systemeinstellungen (`defaults write`, `launchctl`, `pmset` …), Datei-Uploads ins Netz (`curl -F …@`, `scp`, `rsync host:` …) |
| **Vollzugriff** (`full`) | alle lokale Arbeit im Bereich | nur `sudo` und Passwörter/Schlüsselbund |

Für alle Modi gilt: Mails, Posten, Anrufe und Käufe laufen weiter über die bestehenden Karten. `sudo`, `security …
-w` und Passwort-Befehle gibt es nie ohne den Nutzer. Zusammenfassen ist erlaubt: Im Modus „Immer genehmigen“ legt
der Scoop einen Plan als eine Karte vor (`freigabe_anfordern`); nach der Freigabe arbeitet die Aufgabe wie
„Automatisch“ weiter (riskante Befehle fragen trotzdem).

Die Befehlsprüfung (`access.assess_command`) arbeitet mit Wortlisten und Mustern wie die Freigabe-Regeln von Claude
Code. Sie zerlegt Ketten (`;`, `&&`, `|`, `$(…)`), folgt `cd` und löst Pfade mit `~`, `..` und Symlinks auf. Die
harte Grenze für Shell-Befehle ist die Sandbox (unten), nicht die Musterprüfung.

## Bereich

| Bereich | Wo der Scoop lesen und schreiben darf | Umgebung |
|---|---|---|
| **Nur Arbeitsordner** (`workspace`, Standard) | sein Ordner im Arbeitsordner (z. B. `~/Desktop/Scoops/Codi`), bei Aufgaben dazu der Aufgabenordner | wie bisher (schlanke Umgebung, Zugangsdaten gesperrt) |
| **Projektordner** (`projects`) | zusätzlich ein oder mehrere gewählte Ordner im Home | echtes `HOME`, `PATH` der Login-Shell, SSH-Agent: Git, SSH, `gh` und angemeldete CLIs funktionieren |
| **Überall** (`home`) | das ganze Home | wie Projektordner |

- Pfade außerhalb werden abgelehnt, auch über `..` oder Symlinks (`access.within` mit `realpath`).
- Zugangsdaten (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config/gh/hosts.yml`, Schlüsselbunde …) liest kein
  Datei-Werkzeug, auch nicht mit „Überall“. Git/SSH/`gh` in der Shell dürfen sie benutzen.
- Server-Daten (`config.json`, Datenbank, Bibliothek, Protokolle) sind für Aufgaben immer gesperrt.
- **Der Scoop kann den Bereich nicht erweitern.** Bei `aufgabe_starten` darf er mit `ordner` nur enger wählen
  (`access.narrow`): einen Unterordner seiner Projektordner, „arbeitsordner“ oder – wenn erlaubt – „überall“.
  Weiter geht nur der Nutzer (Profil, Board, Eingabefeld). Ein einzelner Befehl außerhalb des Bereichs geht nur über
  eine Freigabe-Karte und läuft dann ohne Sandbox.
- Projektordner: absolut oder `~/…`, im Home, nicht das Home selbst, nicht `~/Library`, höchstens 12, müssen auf dem
  Server-Mac existieren. Gespeichert mit `~`. Auswahl über die Ordnerliste des Servers
  (`GET /api/settings/workspace/browse`).

## Einstellen

- **Pro Scoop** (nur Admin): App → Profil des Scoops → „Rechner-Zugriff“: Modus, Standard-Bereich, Projektordner
  (hinzufügen über die Ordnerliste, entfernen mit −). API: `PATCH /api/bots/{id}` mit
  `computer_access: {mode, scope, folders}` (Teiländerung möglich). Das Bot-JSON des Admins enthält
  `computer_access` mit `mode_label`/`scope_label`; Gäste sehen und ändern es nicht.
- **Pro Aufgabe:** Board-Formular „Bereich am Mac“, Pille im Eingabefeld neben Start und Modell, Scoop-Parameter
  `ordner`. API: `access: {scope, folders}` bei `POST /api/tasks`, `POST /api/bots/{id}/tasks`, `PATCH /api/tasks/{id}`
  (offene/geplante; `{}` = wie Scoop) und in den Eingabefeld-Optionen `task: {access: …}`. Der Modus kommt immer vom
  Scoop. Board und Detail zeigen `access: {mode, scope, folders, label, custom}`.
- **Standard** für bestehende und neue Scoops: „Automatisch“ und „Nur Arbeitsordner“ (Spalte `bots.computer_access`
  leer). Das entspricht ungefähr dem bisherigen Verhalten.

## Chat-Läufe: Werkzeuge wie Claude Code

Nicht für Gäste geteilter Scoops; dort bleibt das eingebaute `terminal` wie bisher.

- **`terminal`** (ersetzt das eingebaute, gleiche Ausgabe „Rückgabecode … stdout … stderr …“): Pro Chat und Rechner
  bleiben aktueller Ordner und exportierte Variablen erhalten (z. B. `cd`, `source .venv/bin/activate`). Umsetzung:
  Der Server merkt sich Ordner und geänderte Variablen; jeder Befehl startet in einer frischen Login-Shell mit diesem
  Zustand, ein EXIT-Trap meldet den neuen Zustand zurück. Aliase und Shell-Funktionen bleiben nicht erhalten; nach einem
  Neustart des Servers beginnt die Shell wieder im Arbeitsordner. Start: Arbeitsordner des Scoops.
- Auf echten Macs läuft jeder Befehl in einer macOS-Sandbox (`sandbox-exec`): schreiben nur im Bereich, in
  `/private/tmp`, den eigenen temporären Ordnern und Caches (`~/Library/Caches`, `~/.npm` …). Lesen und Netz sind frei.
  Bei der VM (Bot-Rechner) gilt nur der Modus, kein Bereich.
- `ausserhalb_bereich: true`: nur wenn der Nutzer ausdrücklich will, dass ein Befehl außerhalb schreibt → Karte.
- Lange Ausgaben: höchstens 12.000 Zeichen stdout und 4.000 stderr, Anfang und Ende bleiben, dazwischen ein Hinweis
  mit der Zahl ausgelassener Zeichen (auch beim eingebauten `terminal` der Gäste jetzt mit Hinweis).
- **`rechner_datei_lesen`** (`pfad`, `ab_zeile`, `zeilen`; mit Zeilennummern, Standard 400 Zeilen, Hinweis auf den
  Rest), **`rechner_dateien_suchen`** (`art: name` Glob wie `**/*.swift`, `art: inhalt` Regex per grep, `dateimuster`),
  **`rechner_datei_ersetzen`** (`alt` → `neu`, muss eindeutig sein, `alle`), **`rechner_datei_schreiben`**.
  Relative Pfade gelten ab dem Ordner der Shell. Auf dem Server-Mac direkt im Server-Prozess, sonst über Scoops
  Connect (`read_bytes`/`write_bytes`/`run_command`).
- **Freigabe im Chat:** Braucht ein Befehl oder eine Dateiänderung eine Freigabe, zeigt das Werkzeug eine Karte
  (`meta.kind = "rechner"`). Nach „Freigeben“ führt der Server genau das aus (Befehl ohne Sandbox), schreibt
  „Ausgeführt: …“ in den Chat und setzt den Scoop mit dem Ergebnis fort. Kein „Immer erlauben“ für diese Karten.
- Aufgaben bekommen diese Chat-Werkzeuge nicht (`TASK_EXCLUDED`), sie haben die ihres Agenten.
- **Chat über KI-Abos (1.30, [`docs/abos.md`](abos.md)):** Läuft ein Chat über Claude Code, gibt es dieselben
  Werkzeuge per MCP; von den eingebauten Claude-Code-Werkzeugen nur Read/Glob/Grep (am Server-Mac, geprüft mit
  `tasks.agent_permission` wie in Aufgaben) und Websuche. Schreiben und Shell laufen weiter über `terminal` und
  `rechner_datei_*` mit diesen Karten. Codex hat im Chat keine eigene Shell.

## Aufgaben

- **Claude Agent SDK:** `can_use_tool` prüft jedes Werkzeug (`TaskService.claude_permission`): Read/Glob/Grep nur im
  Bereich, Write/Edit nach Modus, Bash über die Befehlsprüfung. Sandbox an, Bash wird nicht mehr automatisch erlaubt
  (`autoAllowBashIfSandboxed: false`), Schreiben in der Sandbox: Aufgabenordner plus `add_dirs` (Arbeitsordner,
  Projektordner bzw. Home) und `Edit(…)`-Regeln. `dangerouslyDisableSandbox` nur nach Freigabe. Weite Bereiche:
  `HOME`, `PATH` der Login-Shell, `SSH_AUTH_SOCK` (auch als erlaubter Unix-Socket der Sandbox), lokale Ports.
- **Freigabe in Aufgaben:** Der Schritt legt eine Karte an, die Aufgabe pausiert (`waiting`). Nach der Freigabe ist
  genau dieser Befehl bzw. diese Datei **einmal** erlaubt (Einzel-Freigabe in `tasks.access.grants`) und die Aufgabe
  läuft weiter. Ablehnen → die Aufgabe arbeitet ohne weiter.
- **Codex:** Bereich hart über `sandbox_workspace_write.writable_roots`; weite Bereiche mit voller Umgebung
  (`shell_environment_policy.inherit = "all"`). Den Modus setzt Codex über Anweisung und `freigabe_anfordern` um, weil das
  Codex SDK Befehle nicht einzeln zur Prüfung an den Server gibt (Freigabe-Richtlinie „never“).
- **Responses-Schleife** (Ersatzweg): `shell` mit Befehlsprüfung und Sandbox über den Bereich (`access.sandbox_profile`),
  Datei-Werkzeuge mit absoluten Pfaden im Bereich; echtes Home bei weiten Bereichen.
- **Anweisung:** nennt Modus und Bereich. Dateien im Bereich bearbeitet die Aufgabe **direkt dort** (bei Git über
  Commits nachvollziehbar, sonst mit Sicherungskopie). Für vom Nutzer genannte Dateien **außerhalb** des Bereichs
  bleibt die 1.27.1-Regel (am Bildschirm oder holen, bearbeiten, zurücklegen, vorher Sicherungskopie).
- Lese-Verbote der Sandbox (`tasks.read_denies`): Liegt ein erlaubter Ordner in einem gesperrten (z. B. Arbeitsordner
  auf dem Schreibtisch), wird nur der Rest daneben gesperrt.

## Festplattenvollzugriff (macOS)

Ohne Festplattenvollzugriff fragt macOS für Schreibtisch, Dokumente, Downloads, iCloud usw. einzeln nach – und für
nicht signierte Programme nach jedem Update erneut. Der Server prüft den Status **ohne Abfrage** (Lesetest auf
`/Library/Application Support/com.apple.TCC/TCC.db`, nur mit Vollzugriff lesbar; auf macOS 27 gibt es die Kopie im
Home nicht mehr, Rückfall `~/Library/Safari`) und meldet ihn als
`full_disk_access: {granted, process, path}` in `GET /api/settings/workspace` und `GET /api/setup`.

- **Mac-App „AIS Scoops Server“:** Einrichtung „Diesen Mac freigeben“ und Einstellungen → „Festplattenvollzugriff“
  mit Status, Anleitung und Knopf zu Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`). Freizugeben ist **„AIS Scoops
  Server“**: Der Server (mitgeliefertes Python) und alle Agenten laufen als Kindprozesse der App, macOS rechnet ihre
  Zugriffe der App zu. Die App ist mit Developer ID signiert, die Freigabe übersteht Updates.
- **App (iPhone/iPad/Mac):** Einstellungen → Arbeitsordner und Profil → Rechner-Zugriff zeigen „Festplattenvollzugriff
  fehlt“ mit Anleitung, wenn der Server es meldet.
- **Armans Server (LaunchAgent, `Server/bin/deploy`):** Der Server-Prozess ist
  `~/.local/share/ais-bot/svc/bin/python`, ein Symlink auf das uv-Python
  `~/.local/share/uv/python/cpython-3.12.13-macos-aarch64-none/bin/python3.12` (ad-hoc signiert). Diese Datei braucht
  den Festplattenvollzugriff (Name in der Liste: „python3.12“). Chat-Befehle (`terminal`) laufen über Scoops Connect,
  also „AIS Scoops Server“. Nach einem Update von uv-Python (neuer Ordner `cpython-3.12.x`) muss die Freigabe für die
  neue Datei erneut erteilt werden; der Status in der App zeigt das.

## Entscheidungen

- „Überschreiben“ heißt eine ganze Datei ersetzen (`>`, `cp`/`mv` auf eine vorhandene Datei, Write auf eine
  vorhandene Datei). Gezielte Änderungen (Edit, `rechner_datei_ersetzen`, `sed -i`) sind im Modus „Automatisch“ im
  Bereich frei – sonst wäre Arbeit in Projektordnern kaum möglich.
- Der Chat-Terminal war bisher ohne Grenze. Jetzt schreibt er im Standard nur im Arbeitsordner; was außerhalb nötig ist,
  geht mit einer Karte (bisherige Fähigkeit bleibt, aber mit Zustimmung).
- Bereich und Projektordner beziehen sich auf den Server-Mac. Arbeitet ein Scoop an einem anderen Mac, werden
  `~`-Pfade dort aufgelöst.
- Codex: nur Bereich hart, Modus über Anweisung (siehe oben). Bei Armans Organisation ist Codex ohnehin gesperrt.
