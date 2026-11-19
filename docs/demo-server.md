# Demo-Server für die App-Prüfung

Stand: 17.11.2026 · Server 1.33.0

Damit die Prüfer von Apple die App mit einem echten Server testen können, läuft auf Armans MacBook Air (dem Heim-Server,
der nie schläft) eine **zweite, abgeschottete Server-Instanz**. Sie ist öffentlich über Tailscale Funnel erreichbar. Die
Prüfer verbinden sich ohne Konto über **„Erweitert: Manuell verbinden“** mit Adresse und Token und sehen die volle
Besitzer-Ansicht mit Demo-Scoops.

| | |
|---|---|
| Öffentliche Adresse | `https://<mac>.<tailnet>.ts.net:10000/demo` |
| Lokal | `http://127.0.0.1:8790` |
| Token | `api_token` in `~/.local/share/ais-scoops-demo/config.json` (nur dort und in den ASC-Review-Notizen, nie im Repo) |
| Ordner | `~/.local/share/ais-scoops-demo` (Code, Python, Daten, Protokolle, Arbeitsordner) |
| LaunchAgent | `com.ais-scoops.demo` (`~/Library/LaunchAgents/com.ais-scoops.demo.plist`, KeepAlive, startet nach Anmeldung) |
| Schlüssel | Schlüsselbund `ais-scoops-demo-anthropic` / `api-key` (Kopie von Armans Anthropic-Schlüssel) |
| Skripte | `Server/bin/demo-server` (Einrichtung und Betrieb), `Server/bin/demo-seed` (Demo-Inhalte) |

## Warum dieser Weg

- **Manuell verbinden** (Adresse + API-Token) gibt es in der App schon, ohne Konto und ohne Ablaufzeit. Kopplungscodes
  (10 Minuten) und Einladungen zu geteilten Scoops (7 Tage, einmalig) taugen für eine Prüfung über Tage nicht.
- Der Prüfer bekommt die Besitzer-Ansicht: alle Scoops, Gruppe, Routinen, Freigabe-Karten, Bibliothek.
- Pfad `/demo` auf dem bestehenden Funnel-Port 10000: Funnel erlaubt nur 443, 8443 und 10000; 443 ist T3 (nur im
  Tailnet) und darf nicht öffentlich werden. Der Pfad ändert Armans Freigabe auf `/` nicht. Tailscale schneidet `/demo`
  vor dem Weiterleiten ab; die App hängt ihre Pfade an die Basis-Adresse an (HTTP und WebSocket getestet).

## Abschottung

1. **Eigene Instanz:** eigener Ordner (`AISBOT_HOME`), Port 8790, eigenes Token, Schlüsselbund-Präfix `ais-scoops-demo`,
   Edition `standard` (keine Lucy, T3, Atrium, Team App, VM), eigener LaunchAgent. `HOME` und `TMPDIR` des Prozesses zeigen
   in den Demo-Ordner.
2. **Demo-Modus** (`"demo": true` in der Konfiguration, `Server/src/aisbot/demo.py`):
   - immer `claude-haiku-5-5`, keine Eskalation, nie über ein KI-Abo (Claude Code/Codex);
   - nur die Werkzeuge aus `demo.ALLOWED_TOOLS`: Gedächtnis, Routinen, Erinnerungen, Freigaben, Mail-Entwurf,
     Bibliothek, Fähigkeiten, andere Scoops, Websuche bei Anthropic. Kein Rechner, keine Shell, keine Apple-Dienste, kein
     Composio/MCP, kein Tresor, keine Hintergrund-Aufgaben;
   - `mail_vorbereiten` nutzt das Postfach „Demo“. „Senden“ verschickt nichts, im Chat steht „Demo: Mail … freigegeben
     (nicht wirklich gesendet)“;
   - gesperrte Endpunkte (403 „Auf dem Demo-Server ausgeschaltet.“): Arbeitsordner, Abos, Einrichtung, Rechner koppeln,
     Apple, Apps verbinden, Tresor anlegen, Aufgaben starten, Transkription/Sprechmodus, Initiative, Teilen;
   - Nutzungsseite liest keine Protokolle von Claude Code/Codex dieses Macs und fragt keine Abo-Limits ab.
3. **macOS-Sandbox** (`~/.local/share/ais-scoops-demo/demo.sb`, gestartet über `sandbox-exec`): Lesen und Schreiben unter
   `/Users`, `/Volumes`, `/private/tmp` und `/private/var/folders` nur im Demo-Ordner, also kein Zugriff auf Armans Dateien,
   Daten, Schlüsselbund und Mails. Keine Apple Events, keine Verbindungen zu anderen lokalen Diensten (Armans Server 8787,
   T3, Telefonie) außer dem eigenen Port. Geprüft: Lesen von `~/.local/share/ais-bot/config.json`, `ls ~`,
   Schlüsselbund-Abfrage und `curl 127.0.0.1:8787` scheitern in der Sandbox; der laufende Prozess ist laut
   `sandbox_check` in der Sandbox.
4. **Eigene Python-Kopie** (`python/` im Demo-Ordner): Datenschutz-Freigaben (Bedienungshilfen, Bildschirm, Kalender …)
   hängen am Programmpfad. Armans Server nutzt dieselbe uv-Installation; die Kopie erbt nichts davon.

Grenze: Die Sandbox kann keine einzelnen IP-Bereiche sperren. Geräte im Tailnet (100.x) wären technisch erreichbar,
aber kein Demo-Werkzeug öffnet selbst Verbindungen (Websuche läuft bei Anthropic).

## Limits

`spend_limits` in der Konfiguration (für jede Installation nutzbar, `demo.budget_left`): **5 $ pro Tag, 25 $ pro Monat**
(Europe/Berlin). Gezählt wird alles aus der Tabelle `usage`. Ist ein Limit erreicht, startet kein Lauf mehr; der Scoop
antwortet ohne Modellaufruf: „Das Tageslimit dieses Servers (5.00 $) ist erreicht … (Daily spending limit of this server
reached …)“. Ein laufender Lauf bekommt höchstens das Restbudget (und wie immer höchstens 1,50 $). Eine Chat-Antwort mit
Haiku kostet etwa 0,2 Cent.

Ändern: Werte in `config.json` anpassen; gilt sofort, ohne Neustart.

Besser als der kopierte Schlüssel: In der Anthropic-Konsole einen **eigenen Schlüssel** in einem eigenen Workspace mit
Ausgabenlimit anlegen und mit `security add-generic-password -U -s ais-scoops-demo-anthropic -a api-key -w` eintragen
(fragt den Wert ab), danach `Server/bin/demo-server stop` und `start`.

## Betrieb

```sh
Server/bin/demo-server status      # Dienst, HTTP-Status, Funnel-Pfad, Kosten heute/Monat
Server/bin/demo-server logs [n]    # letzte Zeilen aus ~/.local/share/ais-scoops-demo/logs/server.log
Server/bin/demo-server stop        # anhalten (bis start oder zur nächsten Anmeldung; dauerhaft: uninstall --keep-data)
Server/bin/demo-server start
Server/bin/demo-server install     # Code aus dem Repo neu einspielen und neu starten (Daten und Token bleiben)
Server/bin/demo-seed --karte       # neue offene Mail-Karte bei Lio, z. B. nachdem ein Prüfer sie freigegeben hat
```

Neu aufsetzen (frische Daten, gleiches Token): `demo-server stop`, `data/`, `backups/` und `workspace/` im Demo-Ordner
löschen, `demo-server install`, `demo-seed`.

Erstinstallation: `demo-server install`, `demo-server copy-key` (kopiert den Schlüssel über stdin, nie über die
Befehlszeile), `demo-server stop` und `start`, `demo-server funnel`, `demo-seed`.

## Demo-Inhalte (`demo-seed`)

Scoops im neuen Stil: **Pip** (Assistant, pinkes Herz), **Theo** (Research, blaue Wolke), **Lio** (Writing, gelbes Ei mit
Barett), **Nora** (Planning, grüner Stern mit Kappe), Gruppe **Team** (Pip, Theo, Lio). Beispiel-Chats auf Englisch, eine
Routine bei Nora (werktags 8:00, motivierender Tagesplan) und eine offene Mail-Karte bei Lio (Einladung zum Pizza-Lunch an
sam@example.com).

## Abbau nach der Prüfung

```sh
Server/bin/demo-server uninstall               # Dienst, LaunchAgent, Funnel-Pfad /demo, Schlüsselbund-Eintrag, Ordner
Server/bin/demo-server uninstall --keep-data   # wie oben, Ordner bleibt
```

Danach in App Store Connect den Abschnitt „FULL TEST WITH A LIVE SERVER“ aus den Review-Notizen (iOS und macOS)
entfernen und `tailscale funnel status` prüfen: Es bleiben `/` auf 10000 (Armans Server) und 8443 (Telefonie).
Wer den Token kennt, kommt nach dem Abbau nirgends mehr hin: Armans Server hat ein anderes Token.
