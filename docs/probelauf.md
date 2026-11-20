# Probedurchlauf (ab Server 1.27.2)

Der Probedurchlauf spielt die wichtigsten Abläufe eines Scoops einmal komplett durch: über die HTTP-API, mit den echten
Werkzeug-Handlern und dem echten MCP-Endpunkt der Aufgaben. Die Einzeltests unter `Server/tests/` prüfen Bausteine; der
Probedurchlauf findet Fehler im **Zusammenspiel**, bevor Nutzer darüber stolpern. Beispiele, die so durchgerutscht
waren: Aufgaben ohne Aufsicht und `scoop_schreiben`, `scoop_schreiben` aus Aufgaben scheiterte immer an „Zu viele
Nachrichten zwischen Scoops“, eine wartende Freigabe ließ den Chat „beschäftigt“ aussehen, Composio lieferte bei großen
Notion-Abfragen nur eine Vorschau.

Code: `Server/tests/probelauf.py`, Start: `Server/bin/probelauf`.

## Wann ausführen

**Vor größeren Änderungen und vor Releases mit solchen Änderungen**, nicht bei jedem Release automatisch:
neue Funktionen, Umbauten an Werkzeugen, Aufgaben, Freigaben, Routinen oder App-Anbindungen (Composio, Notion).
`App/scripts/release-server.sh` erinnert am Anfang mit einer Zeile daran, startet ihn aber nicht und bricht nicht ab.

```sh
Server/bin/probelauf             # offline, kostenlos, unter einer Minute
Server/bin/probelauf --live      # danach zusätzlich mit echtem Modell, ~5–7 Cent (nur, wenn offline alles grün ist)
Server/bin/probelauf --nur 3,4   # nur einzelne Abläufe
```

Ausgabe: pro Ablauf eine Zeile **grün** oder **ROT**, bei Rot darunter der Grund, am Ende eine Zusammenfassung.
Exit-Code 0 = alles grün, 1 = mindestens ein Ablauf rot.

## Was geprüft wird

| Nr. | Ablauf | offline | live |
|----:|--------|:-------:|:----:|
| 1 | Chat-Nachricht → Scoop antwortet | ✓ | ✓ |
| 2 | `/aufgabe …` (und offline auch `aufgabe_starten`) → Aufgabe läuft → fertig → Bericht im Chat → „Zu prüfen“ → abnehmen → „Abgeschlossen“ | ✓ | ✓ |
| 3 | Aus einer **Aufgabe** einem anderen Scoop schreiben (`scoop_schreiben`) → Nachricht kommt an, Antwort kommt zurück, nirgends „Zu viele Nachrichten“ | ✓ | ✓ |
| 4 | Aufgabe fordert Freigabe an → wartet → Bot-Feld `waiting` wahr, `busy` falsch, der Chat antwortet währenddessen → Entscheidung → Aufgabe macht weiter → `waiting` wieder falsch | ✓ | ✓ (abgelehnt) |
| 5 | Routine startet eine Aufgabe → `routine_id` und Herkunft `routine`, fertig direkt „Abgeschlossen“ | ✓ | ✓ |
| 6 | Offene Aufgabe (Spalte „Offen“) startet nicht von selbst (auch nicht durch den Planer) → manuell starten; offline auch `aufgabe_starten` mit `termin: offen` | ✓ | ✓ |
| 7 | `datei_speichern` und Aufgaben-Ergebnis (`ergebnis/` und `datei_in_bibliothek`) landen in der Bibliothek **und** im Arbeitsordner des Scoops (`Dateien/`, `Aufgaben/<Datum Titel>/`, siehe `docs/arbeitsordner.md`) | ✓ | ✓ |
| 8 | **Gleichheitscheck:** Aufgaben haben alle Chat-Werkzeuge außer `TASK_EXCLUDED` (und nur die eigenen Aufgaben-Werkzeuge zusätzlich) | ✓ | – |
| 9 | Composio lesend: eine große Notion-Abfrage kommt vollständig und kompakt an, keine Vorschau, kein Tool Router (Aufgabe über `app_werkzeug_suchen/nutzen`, Chat über das Hub-Werkzeug) | ✓ (Fake) | ✓ (nur wenn verbunden) |
| 10 | Haupt-Scoop hat die Aufsicht-Werkzeuge im Chat **und** in Aufgaben, andere Scoops nicht | ✓ | – |
| 11 | Erinnerung setzen (`erinnerung_setzen`) → kommt über den Planer im Chat an | ✓ | ✓ |
| 12 | Dauerfreigabe „Immer erlauben“: die nächste gleiche Freigabe einer Aufgabe läuft ohne Warten durch | ✓ | – |
| 13 | Aufgabe mit Projektordner (`access`) → arbeitet direkt im Ordner, außerhalb und Zugangsdaten gesperrt (live: echtes Claude Agent SDK mit geöffneter Sandbox) | ✓ | ✓ |
| 14 | Modus „Automatisch“: `git push` in einer Aufgabe → Freigabe-Karte → Entscheidung → genau dieser Befehl einmal erlaubt | ✓ | ✓ (abgelehnt) |
| 15 | Chat am Rechner: persistente Shell (Ordner, Variablen), Datei-Werkzeuge im Bereich, außerhalb abgelehnt, `git push` → Karte | ✓ (lokaler Fake-Rechner) | – |
| 16 | **Chat übers Claude-Abo** (Claude Code, docs/abos.md): Werkzeug `merken`, Sitzung fortgesetzt (nur neue Nachricht), `/aufgabe` über das Abo (`billing = abo`, 0 $), Freigabe-Karte, Abo-Läufe in `/api/usage`; offline zusätzlich Limit → derselbe Lauf über die API mit Hinweis | ✓ (Fake-Programm, echte Werkzeug-Strecke) | ✓ (Armans Claude-Login) |
| 17 | **Chat übers ChatGPT-Abo** (Codex): Werkzeug über `/mcp/abo` mit Prozess-Token, Thread fortgesetzt; offline Limit → API | ✓ | ✓ (übersprungen ohne ChatGPT-Login im Scoops-`CODEX_HOME`) |
| 18 | **Eigener MCP-Server im Chat** (docs/mcp.md): Fake-MCP mit Token; Scoop prüft (`mcp_server_pruefen`), Karte mit sicherem Token-Feld, Freigabe mit Token → verbunden, 3 Werkzeuge; Token weder im Chat noch in `config.json`; nächster Lauf: lesendes Werkzeug direkt, schreibendes nur mit Karte, nach Freigabe ausgeführt | ✓ (lokaler Fake-MCP, Schlüsselbund im Speicher) | – |
| 19 | **Computer Use von Codex** (docs/computer.md): echte Codex-Chat-Engine mit Fake-Codex und Fake-App; Codex-Prozess mit genau `scoops` + `computer-use`, Bildschirm vor der ersten Aktion im Hub belegt, App-Freigabe als Karte „Computer Use: Safari bedienen“ → nach Freigabe weiter, Zeilen „Schaut auf Safari“/„Tippt …“; fehlende Rechte → Hinweis im Chat, Status „macOS-Rechte fehlen“, nächster Lauf ohne `computer-use`; VM unverändert | ✓ (Fake-Codex) | – |
| 20 | **Bilder übers ChatGPT-Abo** (docs/bilder.md): Claude-Scoop ruft `bild_erstellen` und bearbeitet das Ergebnis mit `bild_bearbeiten` (echter Bildlauf mit Fake-Codex: zwei Codex-Prozesse ohne MCP-Server) → Karten „Bild erstellt/bearbeitet“, Bibliothek, Arbeitsordner, Bild im Werkzeug-Ergebnis; Aufgabe ruft `bild_erstellen` über `/mcp/task` → Pfad `bilder/…`, Datei bei der Aufgabe vermerkt; ChatGPT-Scoop übers Abo mit eingebautem Bildwerkzeug (`features.image_generation=true`) → Bild im Chat; ohne ChatGPT-Login keine Werkzeuge, dafür Hinweis in der Systemanweisung | ✓ (Fake-Codex) | – |
| 21 | **Englisch** ([sprache.md](sprache.md)): Inhaber setzt Englisch → Health meldet `languages`, Fehlermeldung englisch, Sprachvorgabe im Systemprompt des Chats und im Prompt der Aufgabe, Ereignisse („Routine created“, „Task done“), Statuszeilen der Aufgabe und Rahmen der Freigabe-Karte ohne Deutsch; danach zurück auf Deutsch → wieder „Bot nicht gefunden“, mit `Accept-Language: en` englisch | ✓ | – |

13–15 legen kurz einen Projektordner `~/.aisbot-probelauf-<zufall>/Projekt` an (Projektordner müssen im Home liegen)
und löschen ihn am Ende wieder.

8, 10, 12, 18, 19, 20 und 21 vergleichen Werkzeuglisten bzw. nutzen lokale Fakes im Prozess bzw. müssten live etwas freigeben; sie laufen nur offline. Ablauf 20 live würde echte
Bilder vom Abo kosten; die echte Messung steht in `docs/bilder.md`.

16 und 17 schalten den Abrechnungsmodus des Testservers kurz auf „Abo“ und am Ende zurück auf „API-Schlüssel“. Live
nutzen sie die Logins der Programme auf diesem Mac (Claude Code: Standard-Konfiguration; Codex: `CODEX_HOME` des
Testservers, also meist „übersprungen“). Offline nimmt der Probedurchlauf nie ein echtes Abo (`AISBOT_OFFLINE=1`).

## Offline (Standard)

- Testserver im Prozess wie die Einzeltests: eigener Temp-Ordner (Daten, Konfiguration, Arbeitsordner), eigener Port,
  `AISBOT_OFFLINE=1`. Bricht ab, falls die Datenbank nicht im Temp-Ordner liegt.
- **Fake-Modell** für Chat-Läufe: ruft die Werkzeuge auf, die `service._tools` dem Lauf wirklich anbietet (`extra_tools`),
  bzw. das Composio-Werkzeug des MCP-Hubs. Fehlt ein Werkzeug, wird der Ablauf rot.
- **Fake-Agent** für Aufgaben (statt Claude Agent SDK/Codex): spricht den echten MCP-Endpunkt `/mcp/task` mit dem
  Lauf-Token an (`initialize`, `tools/list`, `tools/call`), so wie die Agent-SDKs. Die Werkzeugliste für Ablauf 8 und 10
  ist also genau die, die ein Modell in der Aufgabe sieht.
- Composio offline: Fake-REST mit 120 Notion-Zeilen und ein Fake-Tool-Router, der nur eine Vorschau liefert (der alte
  Fehler). Grün nur, wenn alle Zeilen kompakt ankommen und der Router nicht gebraucht wurde.
- Laufzeit etwa 16 s (davon ~12 s Warten auf den Planer für die Erinnerung). Kosten: keine.
- Neues Werkzeug nur für Aufgaben (wie `zwischenstand`)? Dann `TASK_ONLY` in `probelauf.py` ergänzen, sonst meldet
  Ablauf 8 es als Abweichung.

## `--live`

- Läuft nur, wenn offline alles grün ist. Startet einen **eigenen Testserver** als Prozess: eigener Temp-Ordner als
  `AISBOT_HOME` (Daten, Konfiguration, Protokolle, Arbeitsordner), zufälliger Port, `AISBOT_OFFLINE=1` (kein
  Composio-/Notion-/Atrium-MCP im Server, keine Initiative, keine Sicherungen), persönliche Zusatzfunktionen aus (kein
  VM-Wächter, keine Telefonie, kein T3), eigener Schlüsselbund-Präfix (Push, Kopplung, Tresor, Composio finden nichts
  Echtes). Nur der Anthropic-Schlüssel wird aus dem Schlüsselbund gelesen (wie die Server-Konfiguration) und dem
  Testserver als Umgebungsvariable übergeben, nie ausgegeben.
- Zwei Test-Scoops („Probe-Lucy“ als Haupt-Scoop, „Probe-Helfer“) mit **claude-haiku-5-5**; Aufgaben mit Limit 0,50 $
  und 8 Minuten. Echte Anweisungen an den Test-Scoop, Aufgaben laufen wie in Produktion mit dem Claude Agent SDK.
- **Kosten und Dauer:** am Ende aus `GET /api/usage` des Testservers (frische Datenbank, also genau dieser Lauf).
  Erste Läufe am 16.11.2026: 0,054 $ für alle Live-Abläufe plus 0,015 $ für eine Wiederholung von Ablauf 3, also rund
  **5–7 Cent** je vollständigem Lauf. Dauer etwa 3 Minuten (davon knapp 1 Minute Warten auf die Erinnerung und 20 s
  Warten auf den Planer bei der offenen Aufgabe), dazu die Offline-Stufe vorneweg.
- **Fasst nie an:** Armans Server (Port 8787), seine Scoops, Chats und Daten (`~/.local/share/ais-bot/data`), seine
  Konfiguration (nur `composio_session_id`/`composio_user_id` werden gelesen), Notion direkt (OAuth-Token bleiben
  unberührt), die VM, Simulatoren, Browser oder Debug-Apps.
- **Sendet nichts nach außen:** keine Mails, Anrufe oder Posts. Die Freigabe in Ablauf 4 wird **abgelehnt**.
- **Composio/Notion nur lesend** und nur, wenn Notion über Composio verbunden ist (sonst „übersprungen“ mit Grund): Konten
  per GET, Ausführen nur für lesende Werkzeuge (`composio_direct.is_readonly`), Tool Router und alles Schreibende
  gesperrt, kein Aufräumen alter Anmeldungen.
- Bei Grün wird der Temp-Ordner gelöscht, bei Rot bleibt er mit `server.log` zur Ansicht (Pfad steht in der Ausgabe).
