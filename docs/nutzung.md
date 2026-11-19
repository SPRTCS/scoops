# Nutzung und Verbrauch (Server 1.31)

Seite in der App: Einstellungen → Kosten → **Nutzung und Verbrauch** (nur Admin). Vorbild ist die Usage-Ansicht von
T3 Code: Tabs **Kosten / Tokens / Limits**, Zeitraum 24 h / 7 T / 30 T / 90 T. Code: `Server/src/aisbot/usage_logs.py`
(Protokolle), `usage_report.py` (Auswertung), `usage_limits.py` (Limits), App `App/AISBot/Views/UsageView.swift`.
Tests: `Server/tests/test_usage.py` (nur synthetische Protokolle).

## Was gezählt wird

Die Seite zeigt den Verbrauch des **ganzen Abo-Kontos**, soweit er auf diesem Mac sichtbar ist, nicht nur den der Scoops.

| Teil | Quelle | Betrag |
|---|---|---|
| Abo-Verbrauch aller Apps auf dem Server-Mac (Claude Code im Terminal, T3 Code, Codex Desktop, VS Code, Scoops …) | lokale Sitzungsprotokolle von Claude Code und Codex | Schätzung zum API-Listenpreis (Modellkatalog, [modelle.md](modelle.md)) |
| Echte API-Kosten der Scoops (API-Schlüssel) | Tabelle `usage`, `billing IS NULL` | wie gebucht |
| Abo-Läufe der Scoops ohne Protokolleintrag | Tabelle `usage`, `billing='abo'` | Schätzung (nur als Ersatz, sonst doppelt) |
| Limits (Woche, 5 Stunden, pro Modell, Credits) | die Programme selbst, kontoweit | – |

**Nicht enthalten in Kosten/Tokens:** Nutzung auf anderen Geräten und in claude.ai bzw. ChatGPT im Browser. In den Limits
steckt sie (die Fenster gelten für das ganze Konto). Für OpenAI zeigt der Tokens-Tab zusätzlich den kontoweiten
Tagesverlauf laut Codex (`account/usage/read`, alle Geräte, nur Gesamt-Tokens ohne Modell/Art).

**Offizielle kontoweite Quelle?** Recherche (17.11.2026): Anthropic hat für Abos keine Verlaufs-API (die Usage-/Cost-API
gilt nur für API-Organisationen); Claude Code liefert per `get_usage` nur die Limit-Fenster. Codex liefert
`account/usage/read` (Tokens pro Tag, kontoweit, ohne Modelle). Darum Kosten aus den Protokollen wie ccusage/T3 Code.

## Protokolle (usage_logs.py)

- Claude: `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects`, `$CLAUDE_CONFIG_DIR/projects`; Scoops:
  `<data>/abo/projects`, `<data>/abo/chats/projects`, `<data>/tasks/t_*/projects` (Claude Code legt die Sitzungen im
  Abo-Weg unter `<cwd>/projects` ab). Nicht: `<data>/tasks/.claude` (API-Aufgaben, stehen mit Kosten in `usage`).
- Codex: `~/.codex/sessions`, `~/.codex/archived_sessions` (auch `.jsonl.zst`, Paket `zstandard`), Scoops:
  `<data>/abo/codex/sessions|archived_sessions`.
- Gelesen werden nur Zeitstempel, Modell, Token-Zähler (input, output, cache_read, cache_write, reasoning),
  Sitzungs-ID, App-Kennung (`entrypoint` bzw. `originator`) und – nur zur Zuordnung „Scoops“ – das Arbeitsverzeichnis.
  Inhalte werden nie gespeichert, geloggt oder ausgegeben; Zeilen ohne Zähler werden gar nicht geparst.
  Login-Dateien (`auth.json`, `.credentials.json`, Schlüsselbund) werden nie angefasst (Test prüft das).
- Duplikate: Claude über `message.id` + `requestId` (größter Zählerstand), Codex über kumulative `total_token_usage`
  (Differenz je Datei, Schlüssel `Sitzung:Summe`, Reset → `last_token_usage`). Codex-Eingabe enthält den Cache und
  wird aufgeteilt; Reasoning steckt in der Ausgabe und wird nur informativ gezählt.
- Inkrementell: Tabelle `log_files` (Größe, mtime, Offset, Codex-Stand), Ergebnisse in `log_usage`. Erster Durchlauf
  auf Armans Mac (~6 GB): ~14 s, danach Millisekunden. Durchlauf beim Serverstart und beim Öffnen der Seite (höchstens
  jede Minute, Hintergrund-Thread). Einträge bleiben, auch wenn Claude Code alte Protokolle löscht.
- Test-/Offline-Modus: keine fremden Protokolle (nur `AISBOT_USAGE_HOME`, falls gesetzt).

## Limits (usage_limits.py)

- **Claude:** Steuerbefehl `get_usage` der gebündelten Claude-Code-CLI (wie `/usage`, `skip_behaviors`), über das Agent SDK
  im Abo-Weg gestartet, **ohne Modellaufruf**: `five_hour`, `seven_day`, `seven_day_opus/sonnet`, `model_scoped`
  (z. B. „Wöchentlich · Fable“), `extra_usage`. Ersatz: alle `unifiedWindows` der letzten `RateLimitEvent`s aus
  Scoops-Läufen (`abos.note_info` → `<data>/abo/limits.json`, übersteht Neustarts).
- **Codex:** `account/rateLimits/read` (primary/secondary, `rateLimitsByLimitId`, Credits, Limit-Resets) und
  `account/usage/read` über den Codex-App-Server im CODEX_HOME der Scoops, ohne Modellaufruf. Ersatz: jüngste
  `rate_limits` aus den lokalen Codex-Protokollen.
- Live höchstens jede Minute (ohne `refresh` alle 5 Minuten), nur für Anbieter mit Abo-Login, Stand in `settings`.
- Der Server sieht dabei nie Anmeldedaten; die Programme fragen ihr Konto selbst ab.

## API

- `GET /api/usage/details?range=24h|7d|30d|90d&source=all|scoops|other&refresh=0|1` (Admin) →
  `{range, bucket: hour|day, source, start, end, totals: {cost_usd, api_usd, abo_usd, tokens, input, output, cache_read,
  cache_write, reasoning, requests, sessions, scoops_usd, scoops_tokens, cache_savings_usd, cached_share},
  by_type: {input, cache_read, cache_write, output}, providers: [{id, label, …Summen, share_cost, share_tokens}],
  sources: [{id: scoops|other, …}], apps: […], models: [{id, label, provider, …, price_estimated?, unpriced_tokens?}],
  days: […], scoops: [{id, label, …}], series: [{key, label, cost_usd, tokens, api_usd, claude: {cost_usd, tokens,
  api_usd}, openai: {…}}], account: {openai: {tokens, days, at, label}}|null, logs: {available, state, files,
  last_scan, seconds, error}, notes: […]}`.
- `GET /api/usage/limits?refresh=0|1` (Admin) → `{providers: [{id, label, app_label, logged_in, subscription,
  state: ok|not_logged_in|unavailable, plan, source: live|event|logs, at, windows: [{id, label, kind, used_percent,
  resets_at, window_minutes}], credits: {has_credits, unlimited, balance}|null, extra_usage, extra: {reset_credits},
  error}], scope_note, generated_at}`.
- `GET /api/health` → `usage_details: true` (ältere Server: App blendet den Knopf aus bzw. zeigt „Server aktualisieren“).
- `GET /api/usage` bleibt unverändert.

## Grenzen

- Preise sind Listenpreise (Schätzung); Modelle ohne eigenen Preis bekommen den Preis ihrer Familie
  („Preis geschätzt“), unbekannte (z. B. `codex-auto-review`) bleiben ohne Betrag (Tokens zählen).
- Apps, die mit API-Schlüssel statt Abo über Claude Code/Codex laufen, lassen sich in den Protokollen nicht sicher
  unterscheiden und zählen mit.
- `get_usage` ist laut Claude Code experimentell; ändert sich die Form, greift der gespeicherte Stand.
