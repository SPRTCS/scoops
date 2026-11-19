# AIS Bot – Server

Python-Server (FastAPI) für die Scoops: Chat, Gedächtnis, Routinen, Erinnerungen, Freigaben, Bot-Rechner (macOS-VM per Computer Use), Composio (Gmail, Notion …) und die MLP Team App (MCP, lesen und schreiben). Läuft als LaunchAgent auf dem Agenten-MacBook-Air. Die API für die App steht in [../docs/API.md](../docs/API.md).

## Betrieb

```bash
cd "AIS Bot/Server"
bin/deploy                      # Code nach ~/.local/share/ais-bot kopieren, Dienst (neu) starten
bin/aisbot pair                 # Kopplungslink für die App (aisbot://pair?url=…&token=…)
bin/aisbot run "Aufgabe"        # einzelne Aufgabe direkt testen (Kommandozeile)
tail -f ~/.local/share/ais-bot/logs/server.log
```

- **Dienst:** LaunchAgent `com.ais-bot.server`, hört nur auf `127.0.0.1:8787`.
- **Zugang von iPhone/iPad:** Tailscale Serve `https://<dein-mac>.<tailnet>.ts.net:8787` (nur im eigenen Tailnet; abschalten mit `tailscale serve --https=8787 off`). Der bestehende Dienst auf Port 443 (3773) bleibt unberührt.
- **Daten:** `~/.local/share/ais-bot/data/aisbot.db` (SQLite: Scoops, Nachrichten, Gedächtnis mit Volltextsuche, Routinen, Freigaben, Kosten, Geräte).
- **Konfiguration:** `~/.local/share/ais-bot/config.json` (API-Token der App, Composio-Sitzung, öffentliche URL, später APNs-Key-ID). Geheimnisse liegen im Schlüsselbund: `ais-bot-anthropic`, `ais-bot-composio`, `ais-bot-mcp-teamapp`, später `ais-bot-apns`.
- **Warum außerhalb von Documents:** launchd-Dienste dürfen ohne Freigabe nicht auf Documents (iCloud) zugreifen. `bin/deploy` kopiert deshalb den Code und nutzt eine eigene Python-Umgebung (`~/.local/share/ais-bot/svc`).

## Editionen (Armans Server vs. Mac-App)

`src/aisbot/profile.py` legt fest, wo der Server seine Daten hat und welche persönlichen Zusatzfunktionen aktiv sind.
Ohne Angaben ist es **Armans Installation** (`personal`): `~/.local/share/ais-bot`, Port 8787, Lucy, T3, Team App, Atrium,
VM-Bot-Rechner, persönliche Prompt-Hinweise – unverändert. Die Mac-App „AIS Scoops Server“ startet den Server mit
`AISBOT_EDITION=standard` und `AISBOT_HOME=~/Library/Application Support/AIS Scoops Server` (Details: `../App/README.md`).

| Variable / config.json | Wirkung |
|---|---|
| `AISBOT_HOME` | Basisordner (`config.json`, `data/`, `logs/`, `backups/`) |
| `AISBOT_EDITION` bzw. `edition` | `personal` (Standard) oder `standard` |
| `features` (config) | z. B. `{"lucy": false}` – einzeln: `vm`, `lucy`, `t3`, `teamapp`, `atrium`, `personal_hints` |
| `AISBOT_KEYCHAIN_PREFIX` | Präfix der Schlüsselbund-Dienste (Standard `ais-bot`; Tests nutzen eigene) |
| `port`, `host` (config) | Port/Bindung, wenn keine Umgebungsvariable gesetzt ist |
| `user_name` / `owner_name` (config) | Ansprache; `owner_name` kommt vom Konto (Convex) |
| `default_model`, `default_escalation_model` (config) | Modelle für neue Scoops |

Test der Edition `standard`: `uv run python tests/test_standard.py` (eigener Temp-Ordner, nie die Produktion).

## Aufbau

| Datei | Aufgabe |
|---|---|
| `src/aisbot/server.py` | HTTP-API, WebSocket, Planer für Routinen, Bildschirm-Vorschau |
| `src/aisbot/bots.py` | Scoop-Dienst: Läufe pro Scoop (Warteschlange, Stopp), Verlauf → Claude, Werkzeuge für Gedächtnis, Routinen, Erinnerungen, Freigaben, Tagebuch |
| `src/aisbot/engine.py` | Agenten-Schleife: Claude + Computer-Toolset + Terminal + MCP (mit Werkzeugsuche) + Eskalation Haiku → Sonnet, geteilter Bot-Rechner mit Sperre |
| `src/aisbot/prompts.py` | Identität, Charakter, Stil, Arbeits- und Gedächtnisregeln |
| `src/aisbot/db.py` | SQLite-Schicht |
| Diktat | `POST /api/transcribe` → OpenAI GPT-Transcribe (Schlüssel im Schlüsselbund `ais-bot-openai`) |
| `src/aisbot/push.py` | APNs (Mitteilungen, Widget-Aktualisierung), aktiv sobald ein Schlüssel hinterlegt ist |
| `src/aisbot/computer.py` | Treiber für den Computer-Server in der VM |
| `src/aisbot/agent.py` | Einzelaufgaben von der Kommandozeile |
| `vm/setup-computer-server.sh` | richtet den Computer-Server in der VM ein (Rechte, Autostart) |

## Modelle und Kosten

- Standard: **Haiku 5.5**. Kommt ein Scoop nicht weiter, übergibt er selbst an **Sonnet 5.5** (Werkzeug `eskalieren`). Pro Scoop einstellbar (auch Opus 5.5).
- Kostengrenze pro Lauf: 1,50 $. Kosten je Lauf stehen in der Statuszeile, Summen unter `/api/usage`.
- Gemessen: Wetter per Safari ≈ 0,15 Cent, Notion-To-dos ≈ 0,6 Cent, normale Chat-Antwort < 0,2 Cent (Haiku).

## Bot-Rechner (VM)

- `ais-bot-mac` (Lume, macOS 26.5, Benutzer `lume`, SIP aus, Deutsch/Berlin). Darin läuft der Cua-Computer-Server mit Bedienungshilfen- und Bildschirmrechten.
- Erreichbar über den LaunchAgent `com.ais-bot.vm-tunnel` (SSH-Tunnel): `127.0.0.1:18000` → Computer-Server, `127.0.0.1:18022` → SSH. So braucht kein Programm die macOS-Freigabe „Lokales Netzwerk“.
- Läuft als LaunchAgent `com.ais-bot.vm` (`lume run ais-bot-mac --display none`, KeepAlive) und startet nach Absturz/Neustart von selbst. Nicht mit `lume run --detach` aus einer Terminal-Sitzung starten: Solche Prozesse enden mit der Sitzung, und `lume ls` zeigt dann fälschlich „running“.
- Ruhezustand in der VM ist aus (`pmset sleep 0`, `systemsetup -setcomputersleep Never`).
- Status `lume ls` · Neustart `launchctl kickstart -k gui/$(id -u)/com.ais-bot.vm` · Zuschauen `lume attach ais-bot-mac`.
- Ruhezustand des Air ist aus (`pmset -a disablesleep 1`), er läuft auch zugeklappt.

## Atrium (Kontext-Gedächtnis)

- **Lokaler Vault** (`atrium__…`): startet `/Applications/Atrium.app/Contents/MacOS/Atrium --mcp` als stdio-MCP (`MCPStdioServer`). Nicht `~/bin/atrium-mcp`: Ein launchd-Dienst darf den iCloud-Vault nicht direkt lesen (TCC blockiert `open()` ohne Fehlermeldung), die sandboxed App schon. Das Verbindungs-Token kommt aus Atrium → Einstellungen → MCP-Server und liegt im Schlüsselbund (`ais-bot-atrium` / `mcp-token`), der KI-Schlüssel unter `ais-bot-atrium` / `api-key`.
- **Team-Bereiche** (Cloud, `atrium_berlin__…`, `atrium_koeln__…`): Remote-MCP (Streamable HTTP), URLs in `config.json` → `atrium_teams`, Zugänge im Schlüsselbund `ais-bot-atrium-team` (Konten `berlin`, `koln`). Dort pflegen die Scoops die Beraterkontexte. `update_space`/`update_project` nur mit Freigabe.
