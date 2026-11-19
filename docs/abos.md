# KI-Abos statt API-Schlüssel (Server 1.30)

Die Scoops können über ein **Claude-Abo** (Pro/Max) bzw. ein **ChatGPT-Abo** (Plus/Pro) arbeiten statt über
API-Schlüssel – nach demselben Muster wie T3 Code: Der Server steuert die **unveränderten offiziellen Programme**
(Claude Code über das Claude Agent SDK, Codex über das Codex SDK), und der Nutzer meldet sich **in diesen Programmen
selbst** an. Code: `Server/src/aisbot/abos.py` (Modus, Status, Login-Start, Limits), `engine_abo.py` (Chat über Claude
Code bzw. Codex), `tasks.py` (Aufgaben), Tests: `Server/tests/test_abos.py`, Probedurchlauf Abläufe 16–17.

## Regeln (Anthropic-/OpenAI-Bedingungen)

- Scoops sammelt, liest, speichert, gibt weiter oder gibt **nie** Abo-Anmeldedaten oder Tokens aus. Kein
  `claude setup-token`, kein Auslesen von Schlüsselbund-Einträgen, `~/.claude/.credentials*`, `~/.codex/auth.json` oder
  `<data>/abo/codex/auth.json`. Test: `test_abos.py` („Keine Anmeldedaten lesen“) prüft Quelltext und Laufzeit.
- Angemeldet wird **nur** über den Login-Ablauf der Programme: `claude auth login --claudeai` bzw. `codex login`
  (ChatGPT im Browser). Server und Server-App starten ihn nur (Terminal-Fenster) und fragen danach den Status über die
  Programme ab: `claude auth status --json`, `codex login status` und Codex’ `account/read` (Abo-Art, ohne Token).
- Die Programm-Binärdateien bleiben unverändert (die gebündelten aus `claude-agent-sdk` und `openai-codex-cli-bin`),
  eingebaute Anmeldewege werden nicht entfernt.
- Im Abo-Weg werden Schlüssel-Variablen für das Programm **geleert** (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN` …; bei Codex `OPENAI_API_KEY`, `CODEX_API_KEY` …), damit garantiert der
  Login des Programms gilt. Meldet Claude Code trotzdem eine Schlüsselquelle (`apiKeySource` ≠ `none`), bricht der Lauf ab.
- `CLAUDE_CONFIG_DIR` wird **nicht** geleert, sondern weggelassen (ein geerbter Wert wird aus der Umgebung des
  Serverprozesses entfernt). Claude Code nimmt einen leeren Wert als Konfigordner `""`: Sitzungen landeten relativ im
  Arbeitsordner, und ab und zu brach ein Lauf mit „API Error: ENOENT: no such file or directory, mkdir“ ab (bis Server
  1.36). Ein auf `~/.claude` gesetzter Wert ginge auch nicht, weil Claude Code dann einen anderen Schlüsselbund-Eintrag
  für den Login sucht. Alte Sitzungen aus dem Arbeitsordner werden nicht übernommen; der Chat startet dann einmal frisch
  mit dem bisherigen Verlauf.
- **Gäste geteilter Scoops** laufen nie über das Abo des Admins (immer API-Schlüssel mit Gast-Tageslimit): Das Abo ist
  persönlich und wird nicht an andere weitergereicht.
- Abo-Login-Ordner und -Dateien sind für Aufgaben, Chat-Datei-Werkzeuge und Shell-Sandbox immer gesperrt, auch mit
  Bereich „Überall“ (`tasks.server_private_paths`, `access.is_secret`).

## Abrechnungsmodus pro Anbieter

`config.json` → `"billing": {"claude": …, "openai": …}`; einstellbar in der Server-App (Einstellungen → „KI-Abos“,
Einrichtung Schritt 2) und in der App (Einstellungen → „KI-Abos“, nur Admin). API: `GET/PATCH /api/settings/abos`.

| Modus | Bedeutung |
|---|---|
| `api` – „API-Schlüssel“ | wie bisher |
| `abo` – „Abo“ | nur über das Abo; ohne Login oder am Limit scheitert der Lauf mit klarer Meldung („In der Server-App unter KI-Abos …“) |
| `abo_api` – „Abo, bei Limit API“ | über das Abo; am Limit oder bei einem Abo-Fehler mit kurzem sichtbarem Hinweis über den API-Schlüssel |

**Standard ohne Eintrag:** „API-Schlüssel“, bis der Nutzer im Programm mit Abo angemeldet ist – danach automatisch
„Abo, bei Limit API“. Server ohne Abo-Login verhalten sich also wie bisher. Im Test-/Offline-Modus (`AISBOT_OFFLINE=1`)
greift die Automatik nie (nur mit ausdrücklicher Einstellung), damit Tests und Probedurchlauf nie still ein echtes Abo
nutzen. Armans Server: beide Anbieter ausdrücklich auf `abo_api`.

**Weg pro Lauf** (`abos.route`): `abo`, wenn der Modus nicht `api` ist und das Programm ein Abo meldet; bei `abo_api`
und vermerktem Limit bis zur Rücksetzzeit (sonst 15 Minuten) gleich `api`. Limit-Erkennung: Claude Code meldet
`RateLimitEvent` (`status: rejected`, Fenster und Auslastung), `AssistantMessage.error = rate_limit`, HTTP 429 oder
Texte wie „usage limit reached“; Codex meldet Fehler im `turn/completed`. Auth-Fehler (abgemeldet, abgelaufen) werden
wie Limits behandelt, nur mit 5 Minuten Pause.

**Hinweis beim Ausweichen:** Statuszeile „Claude-Abo am Limit – weiter über den API-Schlüssel“ und einmal je Limit ein
Ereignis im Chat (`meta.abo_fallback`). Hatte der Abo-Lauf schon Werkzeuge benutzt, bekommt der API-Lauf die bisherigen
Schritte als Hinweis („nichts wiederholen“). Aufgaben: Zeile in der Aufgabenkarte, neue Agent-Session im selben
Arbeitsordner mit Hinweis auf `AUFTRAG.md` (eine Session gehört zu einem Weg).

## Was über Abo läuft und was über API

| Funktion | Mit Abo | Bemerkung |
|---|---|---|
| Chat Claude-Scoops | **Abo** (Claude Code, `ClaudeCodeEngine`) | Sitzung pro Chat, Werkzeuge per In-Process-MCP |
| Chat OpenAI-Scoops | **Abo** (Codex, `CodexChatEngine`) | Thread pro Chat, Werkzeuge über `/mcp/abo` |
| Aufgaben, Routinen (Chat-Läufe und Aufgaben), Übergaben zwischen Scoops | **Abo** | Routinen sind Chat-Läufe; Übergaben laufen im Chat bzw. in Aufgaben |
| Bildschirm-Teilaufgabe der Aufgaben (`bildschirm_aufgabe`, Sonnet am Rechner) | **Abo** (Claude Code mit Werkzeug `bildschirm`) | sonst API; bei OpenAI-Scoops über Codex am Server-Mac nur noch Ersatz (Computer Use von Codex, docs/computer.md) |
| Bildschirm von OpenAI-Scoops im Codex-Weg am Server-Mac | **Abo** (Computer Use von Codex, ab 1.36) | VM/anderer Mac: `bildschirm` wie bisher |
| Gruppen-Routing (wer antwortet) | **Abo** (Claude Code, ein kurzer Aufruf) | bei Fehlern API |
| Initiative des Haupt-Scoops, Erinnerungen, Freigabe-Fortsetzungen | **Abo** | normale Chat-Läufe |
| Gast-Läufe geteilter Scoops | API | Abo ist persönlich |
| „Mach weiter“ nach abgebrochenem **API**-Lauf | API | setzt den gespeicherten API-Verlauf fort |
| Sprechmodus (`live_voice.py`, GPT-Live-1), Telefon (Lucy) | API | kein Abo-Weg |
| Diktat (`/api/transcribe`) | API | kein Abo-Weg |
| Bildgenerierung, Embeddings | API | der Server nutzt beides derzeit nicht |
| OpenAI-Scoop am Rechner im API-Weg (`openai_native_computer: false`) | API | Claude-Teilaufgabe wie bisher |

## Chat über Claude Code (`engine_abo.ClaudeCodeEngine`)

- **Gleiche Schnittstelle** wie `Engine.run` (gibt `Outcome` zurück, dazu `session_id` und `billing="abo"`). `bots.py`
  baut Systemanweisung, Werkzeuge, Statuszeilen, Freigabe-Karten, Übergaben und Anhänge wie bisher.
- **Sitzung pro Chat** (Tabelle `abo_sessions`: Chat, Scoop, Anbieter → Session-ID, letzte gesendete `seq`). Neue Läufe
  schicken nur die Nachrichten seit dem letzten Lauf (`bots._history(since_seq=…)`), eigene Antworten aus der Sitzung
  (`meta.abo_session`) nicht noch einmal. Ohne Sitzung oder wenn sie weg ist: ganzer Verlauf als Mitschrift
  („[Bisheriger Chatverlauf …]“, „Du: …“, „[Neu]“). Kompaktierung und „mach weiter“ übernimmt die Sitzung selbst.
- **Werkzeuge:** alle Scoops-Werkzeuge (`bots._tools`) als In-Process-MCP-Server `scoops` (`mcp__scoops__<name>`),
  verbundene Apps wie bei OpenAI (häufige direkt, sonst `app_werkzeug_suchen`/`app_werkzeug_nutzen`), dazu
  `bildschirm` (Bot-Rechner bzw. Rechner des Scoops: Aktionen wie das Computer-Use-Werkzeug, nach jeder Aktion ein
  neues Bildschirmfoto als Bild) und `eskalieren` (wechselt per `set_model`).
- **Eingebaute Werkzeuge:** WebSearch/WebFetch (wenn erlaubt); Read/Glob/Grep nur, wenn der Scoop am Server-Mac arbeitet,
  geprüft mit `tasks.agent_permission` (gleiche Prüfung wie Aufgaben: Bereich, Zugangsdaten gesperrt). Bash, Write,
  Edit, Subagenten, Pläne usw. sind aus; Schreiben und Shell laufen über `terminal`/`rechner_datei_*` mit den Karten
  aus `docs/rechnerzugriff.md`.
- **Modellwahl:** Modell des Scoops bzw. der Routine (`model`), Verstärkung über `eskalieren`.
- **Startzeit:** ein warmer Prozess pro aktivem Chat (Streaming-Eingabe), höchstens 4, nach 10 Minuten ohne Lauf
  beendet. Ändern sich Systemanweisung, Modell oder Werkzeuge, startet der Prozess neu und setzt die Sitzung fort.
  Gemessen (16.11.2026, Haiku, Max-Abo): Verbindungsaufbau 0,3 s, erste Antwort mit Werkzeug und Bildschirm 4 s, warmer
  Folgezug 0,9 s, kalter Neustart mit fortgesetzter Sitzung 1,4 s.
- **Konfiguration:** Standard-Konfiguration von Claude Code (der normale Login des Nutzers), aber
  `setting_sources=[]` und `strict_mcp_config`: eigene Einstellungen, Hooks, Plugins, CLAUDE.md und MCP-Server des Nutzers
  lädt der Lauf nicht. Sitzungen liegen in Claude Codes Projektordner für `<data>/abo/chats`.
- Kosten: keine Beträge, Token je Modell als Abo-Lauf (`usage.billing = 'abo'`, `dollars = 0`); die Kostengrenze je Lauf
  gilt nicht, die Schrittgrenze (150) schon.

## Chat über Codex (`engine_abo.CodexChatEngine`)

- Thread pro Chat (`thread_resume`), Systemanweisung als `base_instructions`, Bilder als Eingabe, Werkzeuge über den
  MCP-Endpunkt `POST /mcp/abo` mit einem Token pro warmem Codex-Prozess (`mcp_servers.scoops.bearer_token_env_var`),
  Werkzeugfreigabe `default_tools_approval_mode = "approve"` (sonst blockt Codex jedes MCP-Werkzeug, weil die
  Freigabe-Richtlinie „never“ ist; gilt seit 1.30 auch für Codex-Aufgaben).
- Shell aus (`features.shell_tool=false`), Sandbox nur lesend, keine Plugins/Apps/Browser/Gedächtnis von Codex;
  Websuche je nach Erlaubnis. Den Rechner bedient der Scoop mit `bildschirm`, `terminal` und `rechner_datei_*`.
- **Computer Use von Codex (ab 1.36, docs/computer.md):** Arbeitet der Scoop am Server-Mac selbst und ist die App
  „Codex Computer Use“ da und nutzbar, bekommt der Codex-Prozess genau einen weiteren MCP-Server, `computer-use`
  (Schalter `codex_computer_use`, Standard an). Er bedient den Bildschirm dann damit; `bildschirm` ist nur noch Ersatz,
  wenn Computer Use scheitert. Threads laufen dafür mit der Freigabe-Richtlinie `granular` (nur MCP-Elicitations an den
  Server: App-Freigaben → Freigabe-Karten, Aktions-Anfragen → Bildschirm-Sperre im Hub).
- **Eigener `CODEX_HOME`** (`<data>/abo/codex`): Codex lädt immer `config.toml` aus seinem Home, also auch alle
  MCP-Server und Plugins des Nutzers (auf Armans Mac z. B. 1Password und Computer-Use), und das lässt sich per Override
  nicht abschalten. Computer Use kommt seit 1.36 gezielt als einziger Zusatz dazu (Verweis
  `computer-use/Codex Computer Use.app` auf die installierte App, siehe docs/computer.md). Darum meldet sich der Nutzer für die Scoops einmal in diesem Ordner an. Login-Speicher: Datei
  (`cli_auth_credentials_store = "file"`), damit Updates der signierten App keine Schlüsselbund-Abfragen auslösen;
  `forced_login_method = "chatgpt"`. Der Server liest die Datei nie, nur Codex.
- Geprüft (16.11.2026, Armans ChatGPT Pro, einmalig mit seinem bestehenden Codex-Login und abgeschalteten eigenen
  MCP-Servern): Antwort mit Scoops-Werkzeug über `/mcp/abo` 7,8 s, Folgezug im selben Thread 1,3 s, 0 $. Die
  API-Sperre der Organisation (`codex_byok_restricted…`) gilt mit ChatGPT-Anmeldung nicht.

## Aufgaben, Routinen, Übergaben

- `tasks._run_section` wählt pro Abschnitt den Weg (`abos.route`) und merkt ihn in `tasks.billing`.
- **Claude (Abo):** Claude Agent SDK mit der **Standard-Konfiguration** (ohne eigenen `CLAUDE_CONFIG_DIR`, Schlüssel
  geleert) statt `<data>/tasks/.claude`. Begründung: Ein eigener Config-Ordner bedeutet einen eigenen Login, der
  separat abläuft und den Nutzer ein zweites Mal anmelden lässt; die Standard-Konfiguration nutzt den Login, den der
  Nutzer ohnehin für Claude Code pflegt (Token-Erneuerung macht das Programm), und `setting_sources=[]` plus
  `strict_mcp_config` halten seine Einstellungen, Hooks und MCP-Server trotzdem heraus. Keine Kostengrenze in $
  (`max_budget_usd` aus), Zeitlimit bleibt.
- **Codex (Abo):** persistenter Login im eigenen `CODEX_HOME` statt Schlüssel mit `ephemeral`.
- **Codex (Abo) am Server-Mac, ab 1.36:** Die Aufgabe bedient den Bildschirm selbst mit Computer Use von Codex;
  `bildschirm_aufgabe` (Claude-Teilaufgabe) entfällt dann und bleibt nur Ersatz, wenn Computer Use nicht verfügbar ist
  oder scheitert (docs/computer.md). App-Freigaben erscheinen als Karte im Chat der Aufgabe.
- Routinen und Übergaben sind Chat-Läufe bzw. Aufgaben und folgen damit automatisch dem Weg.

## Server-App „AIS Scoops Server“

- Einrichtung Schritt 2 „KI-Abo oder Schlüssel“ und Einstellungen → „KI-Abos“
  (`App/ScoopsConnect/Server/AbosSection.swift`): Status pro Anbieter (angemeldet, Abo-Art wie „Max“ oder „Pro“, falls das
  Programm sie meldet), Knopf „Mit Claude anmelden“ bzw. „Mit ChatGPT anmelden“, Auswahl des Modus, Limit/Auslastung.
- Der Knopf ruft `POST /api/setup/abos/{claude|openai}/login` (nur lokal). Der Server öffnet ein Terminal-Fenster mit
  dem Login-Befehl des Programms (`<data>/abo/anmelden-<anbieter>.command`), das Programm öffnet den Browser. Die App
  fragt danach alle 4 s den Status ab, bis die Anmeldung da ist.
- `claude` und `codex` kommen mit der Server-Runtime: Das Python-Paket `claude-agent-sdk` bringt die Claude-Code-CLI mit
  (`claude_agent_sdk/_bundled/claude`), `openai-codex-cli-bin` die Codex-CLI (`codex_cli_bin/bin/codex`).
  `build-server-runtime.sh` installiert beide aus `uv.lock`, `build-server-dmg.sh` signiert sie (docs/aufgaben.md);
  eine eigene Installation ist nicht nötig.

## API (v1.30)

- `GET /api/settings/abos` (Admin) bzw. `GET /api/setup/abos` (nur lokal, `…/refresh` frisch):
  `{"claude": {label, mode, mode_label, configured, route, api_key, installed, logged_in, subscription, method, plan,
  account, limit: {reason, until}|null, usage: {status, window, utilization, resets_at, at}|null, login_command},
  "openai": {…}, "modes": [{id, label}]}`. `GET /api/setup` enthält dasselbe unter `server.abos`.
- `PATCH /api/settings/abos` bzw. `PATCH /api/setup/abos`: `{"claude": "abo_api", "openai": "api"}` (auch
  `{"claude": {"mode": …}}`) → Status.
- `POST /api/settings/abos/{provider}/login` bzw. `POST /api/setup/abos/{provider}/login`: öffnet den Login am Server-Mac
  → `{started, command, status}`.
- `GET /api/usage`: zusätzlich `abo: {today_runs, month_runs, by_model: {model: {runs, input_tokens, output_tokens}}}`;
  `today_usd`/`month_usd` enthalten nur API-Kosten.
- Chat: Statuszeile `meta.billing` (`abo`/`api`), `meta.abo_fallback`; Antwort `meta.run_info.billing`,
  `meta.abo_session`. Aufgaben: Feld `billing` der laufenden Session.
- `POST /mcp/abo`: MCP für Codex-Chat-Läufe (Token pro Prozess, nicht für Menschen).
- Ab 1.36: `GET /api/settings/abos` enthält `codex_computer_use: {supported, enabled, installed, app, available, reason,
  hint}`; `PATCH /api/settings/abos {"codex_computer_use": true|false}`. Ältere Server haben das Feld nicht → die App
  blendet den Schalter aus. Chat-Karte `meta.kind = codex_cu` (App-Freigabe), Ereignis `meta.codex_cu` (Rechte fehlen).

## Grenzen und Risiken

- **Große Bildschirmbilder (Fix in 1.35):** Der Claude Agent SDK liest die Zeilen von Claude Code standardmäßig nur bis
  1 MB. Ein Screenshot einer vollen Webseite (PNG, Base64) im Werkzeug-Ergebnis von `bildschirm` war größer, der Lauf
  brach mit „JSON message exceeded maximum buffer size“ ab (`bildschirm_aufgabe` in Aufgaben). Seitdem setzen alle
  `ClaudeAgentOptions` `max_buffer_size = abos.SDK_MAX_BUFFER` (64 MB), Screenshots über 600 KB gehen als JPEG
  (Qualität 85, gleiche Pixelmaße, `computer.compact_image`), und ein solcher Fehler heißt ehrlich „Interner Fehler im
  Scoops-Server: … zu groß“ statt nach abgebrochener Bildschirmverbindung (`abos.explain_sdk_error`). Test:
  `Server/tests/test_screen_buffer.py`.
- **Latenz:** Erster Lauf eines Chats startet einen Prozess (Claude ~0,3 s, Codex einige Sekunden); danach warm.
  Wechsel von Systemanweisung (neue Erinnerung), Modell oder Werkzeugen starten den Prozess neu (~1,5 s).
- **Abo-Limits:** Scoops, Aufgaben und Armans eigene Arbeit in Claude Code/Codex/T3 teilen sich die Limits des Abos.
  „Abo, bei Limit API“ fängt das ab; „Abo“ hält dann an.
- **Was im Abo-Weg anders ist:** keine serverseitige Compaction-/Prompt-Caching-Steuerung (macht das Programm), keine
  Kostengrenze in $, Server-Werkzeuge der Messages API (Tool-Search-BM25, MCP-Connector) entfallen zugunsten der eigenen
  Werkzeugsuche, OpenAI-Scoops bedienen den Rechner über `bildschirm` (am Server-Mac ab 1.36 über Computer Use von
  Codex) statt über OpenAIs `computer`-Werkzeug, PDFs gehen
  an Codex nur als Verweis. „Mach weiter“ nach einem abgebrochenen Abo-Lauf setzt die Sitzung fort.
- **Anbieterbedingungen:** Der Weg folgt dem Muster „offizielles Programm, eigener Login des Nutzers“ (wie T3 Code).
  Ändern Anthropic oder OpenAI ihre Bedingungen für Abos in Drittprogrammen, auf „API-Schlüssel“ stellen.
