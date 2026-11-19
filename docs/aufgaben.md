# Aufgabenmodus (Server 1.19, Board 1.22, Offen 1.23)

Scoops können größere Aufgaben in einen **Hintergrund-Lauf** geben, der so ausdauernd arbeitet wie Claude Code oder
Codex: eigener Arbeitsordner mit Dateien, Shell und Web, viele Schritte, Ergebnisdateien in der Bibliothek. Der Chat
bleibt frei, der Fortschritt erscheint als Schrittkarte. Code: `Server/src/aisbot/tasks.py`, Tests:
`Server/tests/test_tasks.py`, API: `docs/API.md` („v1.19“).

## Starten

- **Der Scoop entscheidet:** Werkzeug `aufgabe_starten(titel, auftrag)` für Recherchen mit Bericht, Dokumente, Auswertungen,
  mehrstufige Arbeiten. Sagt der Nutzer „als Aufgabe“ oder „im Hintergrund“, nimmt der Scoop es ebenfalls.
- **Der Nutzer ausdrücklich:** Nachricht `/aufgabe <Auftrag>` (startet ohne Chat-Lauf) oder `POST /api/bots/{id}/tasks`.
- Weitere Chat-Werkzeuge: `aufgaben_status`, `aufgabe_fortsetzen(aufgabe_id, hinweis)` (Antwort auf eine Rückfrage,
  „mach weiter“ nach Limit/Fehler/Stopp), `aufgabe_stoppen`. Der Chat-Lauf sieht offene Aufgaben im Systemprompt.
- Aufgaben starten keine Aufgaben. **Gäste** geteilter Scoops bekommen keinen Aufgabenmodus (kein Werkzeug, API nur für
  den Inhaber).

## Board, Planung und Abnahme (1.22)

- **Board in der App** (Knopf „Aufgaben“ in der rechten Leiste bzw. Seitenleiste, ⌘K „Aufgaben“): alle Scoops zusammen,
  filterbar nach Scoop. Spalten **Geplant → In Arbeit → Zu prüfen → Abgeschlossen**, **Archiv** als eigener Reiter.
  iPhone: Spalten per Segment; iPad/Mac nebeneinander mit Drag & Drop (Geplant → In Arbeit = starten, Zu prüfen →
  Abgeschlossen = abnehmen, → Archiv, Archiv → zurück), sonst Knöpfe und Kontextmenü. Live über `task.updated`, als
  Rückfall alle 20 s neu laden, solange das Board offen ist.
- **Laufzustand und Abnahme getrennt:** `state` (scheduled/queued/running/waiting/done/failed/stopped/limit) und `review`
  (`review` → `done` → `archived`). Jede beendete Aufgabe kommt nach „Zu prüfen“, auch Fehler/Stopp/Limit (deutlich
  markiert, „Fortsetzen“). „Nacharbeiten“ mit Hinweis setzt im selben Arbeitsordner fort. Aufgaben von vor 1.22 gelten
  beim ersten Start als abgenommen.
- **Geplant:** `scheduled_at` (Berliner Zeit). Der Planer (`scheduler_loop`, alle 15 s, `tasks.start_due`) startet
  fällige Aufgaben; der Zustand steht in der DB, ein verpasster Termin (Server aus) wird beim nächsten Durchlauf
  nachgeholt. Erst beim Start entstehen Statuskarte und Chat-Kontext in `AUFTRAG.md`; „Wie Scoop“ nimmt dann das
  aktuelle Modell des Scoops.
- **Modell pro Aufgabe:** `model_choice` (`null` = wie Scoop); `model`/`engine` werden beim Start gesetzt. Kosten pro
  Aufgabe wie bisher in `cost_usd` (aus den Usage-Daten des Laufs).
- **Im Chat:** Plus-Menü → „Aufgabe starten“ setzt den blauen Aufgaben-Chip; daneben die Pillen „Jetzt ▾“ (Termin) und
  „Wie Scoop ▾“ (Modell). Gesendet wird `/aufgabe <Text>` mit `task: {scheduled_at, model}`; die Optionen stehen in
  `meta.task_options`.
- **Scoops starten öfter selbst:** `aufgabe_starten` (mit `termin`) für alles Mehrstufige am Bildschirm, über mehrere
  Apps/Konten, Recherchen mit Bericht, Dokumente, Abgleiche, Posten mit Kontowechsel; kurze Fragen bleiben im Chat. Der
  Chat-Lauf kennt die Regeln und die geplanten/„Zu prüfen“-Aufgaben seines Chats; `aufgabe_abnehmen`, wenn Arman sagt,
  dass es passt. Weiche Heuristik (`engine.HANDOFF_AFTER = 12`): nach 12 Werkzeug-/Bildschirmschritten in einem
  Chat-Lauf einmal der Hinweis „Gib den Rest als Aufgabe ab“, keine Zwangsumleitung.
- **Offen (Backlog, 1.23):** Spalte ganz links. `state='open'`: gesammelt, startet nie von selbst (auch der Planer fasst
  sie nicht an). Anlegen: Board „+“ bei Offen bzw. Formular „Start: Offen“ (`POST /api/tasks` mit `backlog: true`),
  Eingabefeld-Pille „Offen sammeln“ (`task: {backlog: true}`), Scoop `aufgabe_starten` mit `termin: 'offen'`. Weiter:
  „Starten“ (`/start`), „Planen“ (`PATCH scheduled_at` → `scheduled`), `PATCH backlog: true` legt eine geplante zurück,
  Löschen wie bei geplanten. Drag & Drop: Offen → In Arbeit startet, Offen → Geplant öffnet die Terminwahl,
  Geplant → Offen legt zurück. Der Scoop sieht offene Aufgaben seines Chats im Prompt und startet sie nur auf
  ausdrücklichen Wunsch (`aufgabe_fortsetzen` startet offene/geplante).
- **Routinen (1.26):** Startet ein Scoop während eines Routine-Laufs eine Aufgabe (`aufgabe_starten`), trägt sie
  `routine_id` und `origin='routine'` (der Lauf kennt seine Routine über `RunState.routine_id`; `fire_routine` gibt sie
  immer mit, auch ohne eigenes Modell). Fertig → direkt „Abgeschlossen“ (`review='done'`), weil Routinen ständig
  wiederkommen; verbessert wird die Routine selbst. Fehler, Stopp und Limit bleiben unter „Zu prüfen“. Board und Detail
  zeigen „Routine · <Titel>“ (`routine_title`). Sammelknöpfe: „Alle abhaken“ (Zu prüfen, nur fertige) und
  „Alle archivieren“ (Abgeschlossen), je mit Rückfrage.
- **Schnellknöpfe auf den Karten (App):** Zu prüfen → „Abhaken“ (accept) und „Ablehnen“ (Kommentar optional → `rework`;
  ohne Kommentar ein allgemeiner Nacharbeits-Hinweis), Fehler/Stopp → „Fortsetzen“, Offen → „Starten“/„Planen“.
- Tests: `Server/tests/test_task_board.py`, Heuristik in `Server/tests/test_nudge.py`.

## Ausführung

| Scoop-Modell | Weg | Paket (Python, im Lockfile) |
|---|---|---|
| Claude (`claude-*`) | **Claude Agent SDK** (`ClaudeSDKClient`), Werkzeuge von Claude Code (Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch, TodoWrite, Subagenten) | `claude-agent-sdk` 0.2.182, bringt die Claude-Code-CLI 2.1.325 als Mach-O mit (`claude_agent_sdk/_bundled/claude`, ~350 MB) |
| OpenAI (`gpt-*`) | **Codex SDK** (`openai_codex.Codex`, spricht `codex app-server` über stdio) | `openai-codex` 0.169.0 + `openai-codex-cli-bin` (gebündelte `codex`, `codex-exec-server`, `codex-code-mode-host`, zusammen ~410 MB) |
| OpenAI, Codex gesperrt | **Responses-Schleife** (`engine_openai.py`) mit Arbeitsordner-Werkzeugen `shell`, `ordner_auflisten`, `datei_lesen_ordner`, `datei_schreiben_ordner` und Websuche | – |

> **Ab 1.30: KI-Abos.** Im Abrechnungsmodus „Abo“ bzw. „Abo, bei Limit API“ laufen Aufgaben mit dem Login des Nutzers
> in Claude Code (Standard-Konfiguration, ohne Schlüssel) bzw. Codex (eigener `CODEX_HOME` mit ChatGPT-Login) statt mit
> API-Schlüssel; Details, Regeln und Begründung in [`docs/abos.md`](abos.md). Der folgende Abschnitt beschreibt den
> Weg „API-Schlüssel“.

Belegt (Stand 15.11.2026): Das Agent SDK gibt es für Python und TypeScript, das Python-Paket enthält die CLI und
authentifiziert per `ANTHROPIC_API_KEY` (im API-Weg; Abo-Weg siehe docs/abos.md). OpenAI bietet das Codex
SDK für TypeScript (`@openai/codex-sdk`) und Python (`openai-codex`, ≥ 3.10, mit fester CLI-Version). Beide laufen mit dem
Modell des Scoops.

**Codex und Armans OpenAI-Organisation:** (Mit ChatGPT-Anmeldung, also im Abo-Weg ab 1.30, gilt die Sperre nicht.)
OpenAI lehnt Codex-Anfragen mit dem API-Schlüssel ab
(`codex_byok_restricted_by_api_credit_promo`: Die Organisation ist im Programm „monatliche API-Credits mit
ChatGPT-Abo“; nur der Org-Owner kann das unter platform.openai.com › Billing beenden). Der Server erkennt das, merkt sich
die Sperre 24 h (`settings.codex_blocked_until`) und nimmt automatisch die Responses-Schleife. `GET /api/tasks/settings`
zeigt `codex_available` und den Grund. Wird die Sperre aufgehoben, greift Codex ab dem nächsten Versuch von selbst
(oder sofort mit `task_openai_engine = "codex"`).

**Schlüssel:** aus dem Schlüsselbund wie bisher (`kc("anthropic")`, `kc("openai")`), nur als Umgebungsvariable an den
Agent-Prozess: Claude `ANTHROPIC_API_KEY` (mit `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, Shell-Befehle sehen ihn nicht),
Codex über einen eigenen Anbieter `model_providers.aisopenai.env_key = "AISBOT_OPENAI_KEY"` mit
`cli_auth_credentials_store = "ephemeral"` und `shell_environment_policy.inherit = "core"`. Nichts landet in Dateien
oder Logs. Eigene Konfigurationsordner: `<data>/tasks/.claude` (`CLAUDE_CONFIG_DIR`, `setting_sources=[]`) und
`<data>/tasks/.codex` (`CODEX_HOME`); Armans `~/.claude` und `~/.codex` bleiben unberührt.

## Arbeitsordner und Grenzen

> **Ab 1.29:** Rechte-Modus und Bereich pro Scoop und pro Aufgabe (Projektordner, „Überall“, echtes Home für Git/SSH/gh,
> Freigabe-Karten für riskante Befehle) stehen in [`docs/rechnerzugriff.md`](rechnerzugriff.md). Die folgenden
> Punkte beschreiben den Bereich „Nur Arbeitsordner“ (Standard).

- Jede Aufgabe: `<data>/tasks/<id>/` mit `AUFTRAG.md` (Auftrag + letzte Chatnachrichten), `eingang/` (aus der Bibliothek
  geholte Dateien), `ergebnis/` (kommt am Ende in die Bibliothek; ist er leer, neue Dateien oben im Ordner).
- **Claude:** `cwd` = Arbeitsordner, Bash-Sandbox an (`allowUnsandboxedCommands: false`), `can_use_tool` erlaubt Schreiben
  und Lesen nur im Arbeitsordner (und `/tmp`), lehnt unbekannte Werkzeuge ab; `Read`-Verbote (`//…`) für Zugangsdaten und
  Serverdaten (`tasks.sensitive_paths()`: config.json, aisbot.db, Bibliothek anderer Chats, ~/.ssh, Schlüsselbunde,
  ~/Documents, ~/Desktop …). AskUserQuestion, Pläne, Worktrees, Cron usw. sind abgeschaltet.
- **Codex:** Sandbox `workspace-write` mit Netz, `approval_policy = never`; fragt Codex trotzdem nach mehr Rechten, lehnt
  der Server ab (`_codex_decline`).
- **Responses-Schleife:** `shell` läuft unter `sandbox-exec` (schreiben nur im Arbeitsordner und `/private/tmp`, Lesen der
  geschützten Pfade verboten, schlanke Umgebung ohne Schlüssel, 5 Minuten je Befehl).

## Unsere Werkzeuge (MCP)

Der Server stellt sie unter `POST /mcp/task` bereit (MCP Streamable HTTP, nur JSON-Antworten, `initialize`,
`tools/list`, `tools/call`, `ping`). Das Bearer-Token gilt nur für den laufenden Abschnitt einer Aufgabe und verfällt
danach. Claude bekommt es im `mcp_servers`-Header, Codex über `bearer_token_env_var` und mit
`default_tools_approval_mode = "approve"` (ab 1.30; mit „auto“ blockte Codex jedes Werkzeug wegen der Richtlinie „never“). Werkzeuge:

- Bibliothek: `datei_aus_bibliothek`, `datei_in_bibliothek`, `dateien_auflisten`, `datei_speichern`, `link_merken`,
  `datei_vom_rechner`, `datei_auf_rechner`
- Verbundene Apps (Composio, Team App, Atrium …): `app_werkzeug_suchen`, `app_werkzeug_nutzen` (Mails senden blockt
  `mcp_client` weiter, nur über `mail_vorbereiten`)
- Apple-Dienste (`apple_*`), Rechner: `bildschirm_aufgabe` (Claude Sonnet 5.5 am Rechner des Scoops), Telefon:
  `anrufen` (nur Karte), `anrufe_lesen`
- Gedächtnis: `merken`, `erinnerung_suchen`, `erinnerung_setzen`, `faehigkeit_lesen`, `faehigkeit_speichern`
- Kommunikation: `zwischenstand` (Meilenstein in der Karte), `nachricht_an_nutzer`, `rueckfrage_stellen` (pausiert)
- Freigaben: `mail_vorbereiten`, `anrufen`, Apple-Löschen/-Schalten, `freigabe_anfordern`

## Freigaben

Es gelten die bestehenden Karten unverändert. Durchgesetzt werden sie in unserer Werkzeugschicht, also für beide SDKs
gleich und unabhängig davon, was ein Agent-Prozess selbst erlaubt:

- **Mail, Anruf, Apple-Löschen/-Schalten:** Das Werkzeug legt die Karte an, die Aufgabe arbeitet weiter. Nach der
  Freigabe führt der Server die Aktion aus (wie im Chat) und meldet das Ergebnis im Chat. Lucy ruft nur nach Freigabe der
  konkreten Anrufkarte an.
- **`freigabe_anfordern`** (z. B. vor dem Löschen außerhalb des Arbeitsordners, Posten, Buchen): Karte mit
  `approvals.task_id`, die Aufgabe hält an (`state = waiting`). Die Entscheidung setzt die Aufgabe in derselben
  Session/demselben Thread fort (`bots.decide` → `tasks.on_decision`), ohne zusätzlichen Chat-Lauf.
- **Rückfragen:** `rueckfrage_stellen` schreibt die Frage in den Chat und pausiert. Der Chat-Scoop gibt die Antwort mit
  `aufgabe_fortsetzen` weiter.
- Die SDK-eigenen Mechanismen sichern die Grenze von Shell und Dateien: bei Claude `can_use_tool` (siehe oben), bei Codex
  der Freigabe-Handler (lehnt alles ab, was die Sandbox verlassen will).

## Fortschritt, Stopp, Neustart

- Eine Statuskarte je Aufgabe (`meta.task`). Kleinigkeiten werden zusammengefasst: gleiche Tätigkeit hintereinander
  ergibt eine Zeile mit Zähler („Liest quelle5.md · 6×“), interne Schritte erscheinen nicht, höchstens 80 Zeilen,
  Updates höchstens alle 2 s.
- Stopp-Knopf im Chat und „Aufgabe anhalten“ auf der Karte: `client.interrupt()` bzw. `turn.interrupt()`, Zustand
  `stopped`, kein Abschlussbericht.
- Neustart (Deploy, Absturz, App-Update): Der Zustand steht in der Tabelle `tasks` (`session_id` = Claude-Session bzw.
  Codex-Thread bzw. `resp:<id>` mit Verlauf in `.aufgabe/verlauf.json`). Beim Start beendet der Server einen verwaisten
  Agent-Prozess (`tasks.pid`, nur Claude-/Codex-CLI) und setzt fort (`resume=<session>` bzw. `thread_resume`).
  Aufgaben zählen nicht zu `active_runs`, ein Deploy wartet also nicht auf sie.
- Ende: Ergebnisdateien → Bibliothek und Scoop-Ordner, **still** (ab Server 1.38 keine Zeile je Datei im Chat),
  Ereignis „Aufgabe fertig: … · 0.12 $“, danach schreibt der Scoop das Ergebnis in seinem Charakter (Kurzfassung
  zuerst). Dateien, die der Nutzer wirklich öffnen soll, zeigt er mit `datei_zeigen` als Karte „Ergebnis: …“ unter
  seiner Antwort (meist eine, oft keine). Status-, Zwischen- und Protokolldateien (z. B. von Routinen) bleiben nur in
  der Bibliothek. `datei_in_bibliothek` während der Aufgabe zeigt die Datei weiterhin sofort.

## Kosten und Grenzen (Standards, config.json)

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `task_mode` | `"all"` | `"all"`, `"off"` oder Liste von Scoop-IDs |
| `task_max_parallel` | 3 | gleichzeitig laufende Aufgaben (1–10), weitere warten |
| `task_budget_usd` | 3.00 | Kostenlimit je Aufgabe (bis 25 $); `max_budget_usd` für Claude, eigene Prüfung für alle |
| `task_max_minutes` | 60 | Arbeitszeit je Aufgabe (bis 8 h); Warten auf Freigaben zählt nicht |
| `task_openai_engine` | `"auto"` | `auto` (Codex, sonst Responses-Schleife), `codex`, `responses` |
| `task_effort` | `"medium"` | Denkaufwand der Claude-Aufgaben |

Kosten laufen über `UsageBook`-Preise in die Tabelle `usage` (alle 20 s und am Ende, je Modell), die Aufgabe zeigt
`cost_usd`. „Mach weiter“ nach dem Limit gibt einen weiteren Rahmen in Höhe des Standards. Ändern:
`PATCH /api/tasks/settings`.

## Chat-Läufe (gleiche Version)

- Schrittgrenzen 150 (Claude) bzw. 120 (OpenAI), Kostengrenze je Lauf weiter 1,50 $.
- Compaction: Claude `compact_20260112` bei 120.000 Eingabe-Token zusammen mit `clear_tool_uses_20250919`, das volle
  `response.content` bleibt im Verlauf (Compaction-Kosten aus `usage.iterations` werden mitgezählt). OpenAI
  `context_management` mit `compact_threshold`; Eingaben vor dem Compaction-Element fallen weg.
- „Mach weiter“: Verlauf abgebrochener Läufe in `<data>/resume/` (alle 20 s und am Ende, 24 h gültig).

## Mac-App „AIS Scoops Server“

`build-server-runtime.sh` installiert beide SDKs aus `uv.lock` mit. `build-server-dmg.sh` signiert die mitgelieferten
Agent-Binärdateien mit Developer ID und Hardened Runtime und **behält ihre Entitlements** (`--preserve-metadata=entitlements`:
JIT bzw. unsignierter ausführbarer Speicher, ohne die Bun/V8 nicht startet). Der Selbsttest startet beide CLIs im
signierten Bundle (`claude --version`, `codex --version`). Agent-Shells bekommen das Python des Servers (in der App das
mitgelieferte) vorn in den PATH (`tasks.agent_path()`), weil `/usr/bin/python3` auf Macs ohne Entwicklerwerkzeuge nur ein
Platzhalter ist. Geprüft (15.11.2026): DMG 397 MB, Developer ID, notarisiert und gestapelt; der signierte Bundle-Server
(Port 8798, eigener Datenordner, `env -i` mit PATH `/usr/bin:/bin:/usr/sbin:/sbin`) erledigt je eine Aufgabe mit Haiku
(Agent SDK, 0,017 $) und Luna (Responses-Schleife, 0,032 $) inklusive Websuche, Terminal und Datei in der Bibliothek.

## Pilot (15.11.2026)

Erst nur Codi (`task_mode: ["b_7f7ebee64a"]`, Pilot-Limit 1 $ / 20 min), danach `task_mode: "all"` mit den Standards.

| Lauf | Modell / Weg | Ergebnis | Kosten Aufgabe |
|---|---|---|---|
| Testinstanz: Web-Recherche → `Leitzins.md` | Haiku 5.5 / Agent SDK | fertig in 30 s, Datei in der Bibliothek | 0,021 $ |
| Testinstanz: CSV + Python + Freigabekarte | Haiku 5.5 / Agent SDK | wartet, nach Freigabe fortgesetzt, 2 Dateien | 0,009 $ |
| Testinstanz: Absturz (SIGKILL) mitten im Lauf | Haiku 5.5 / Agent SDK | verwaister Prozess beendet, gleiche Session, ab Datei 3 weiter | 0,007 $ |
| Testinstanz: Recherche → `Sonnenfinsternis.md` | GPT-6 Luna / Responses (Codex gesperrt) | fertig, Zwischenstand in der Karte | 0,053 $ |
| Testinstanz: Absturz mitten im Lauf | GPT-6 Luna / Responses | aus `verlauf.json` fortgesetzt | 0,002 $ |
| Testinstanz: „als Aufgabe“ im Chat | Haiku und Luna | Scoop ruft `aufgabe_starten`, Abschluss im Charakter | je < 0,01 $ |
| **Codi:** Recherche Mindestlohn/Minijobs 2027 → Dokument | GPT-6.1 Sol / Responses | fertig in 55 s, Datei in der Bibliothek | 0,105 $ |
| **Codi:** CSV + Anteile, Neustart per `bin/deploy`, Freigabekarte | Claude Sonnet 5.5 / Agent SDK (Codi kurz umgestellt) | Neustart überstanden, Freigabe → fortgesetzt, 2 Dateien | 0,253 $ |

Dazu Chat-Läufe (Start und Abschlussbericht) bei Codi zusammen ~0,42 $. Codex selbst: Konfiguration und
MCP-Verbindung geprüft (initialize, tools/list mit Bearer-Token aus `bearer_token_env_var`), Modellaufrufe von OpenAI
für die Organisation gesperrt (siehe oben).
