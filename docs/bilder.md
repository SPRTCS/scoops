# Bilder erstellen und bearbeiten (Server 1.39, App 1.3)

Scoops erstellen neue Bilder und bearbeiten vorhandene, und zwar **ausschließlich über das ChatGPT-Abo** des Nutzers:
Der Server lässt das unveränderte Codex mit dessen eigenem ChatGPT-Login (Scoops-`CODEX_HOME`, `abos.codex_home`) das
eingebaute Bildwerkzeug `image_generation` benutzen. Es gibt keinen Weg über die API und keinen Rückfall darauf. Es gelten
alle Regeln aus [`docs/abos.md`](abos.md): offizielles Programm, eigener Login, nie Tokens oder Anmeldedateien lesen,
Schlüssel-Variablen geleert.

Code: `Server/src/aisbot/bilder.py` (Bildlauf, Speichern, Werkzeuge), `engine_abo.CodexChatEngine` (eingebautes
Bildwerkzeug im Chat), `bots.py` (Werkzeuge und Hinweis), App: `App/AISBot/Views/Chat/Attachments.swift`
(`ImageFileCard`). Tests: `Server/tests/test_bilder.py`, Probedurchlauf Ablauf 20.

## Erkundung (19.11.2026, Codex 0.169.0 aus `openai-codex-cli-bin`, ChatGPT Pro)

Geprüft mit genau den Einstellungen der Scoop-Läufe: Shell aus (`features.shell_tool=false`), Sandbox nur lesend,
Freigaben `deny_all`, Websuche aus, keine Plugins/Apps/MCP-Server.

| Frage | Ergebnis |
|---|---|
| Geht das ohne Shell und mit Nur-Lese-Sandbox? | Ja. Das Bildwerkzeug ist ein eigenes Werkzeug von Codex (`features list`: `image_generation stable true`), keine Shell. |
| Wie meldet das SDK das Ergebnis? | `item/started` und `item/completed` mit einem Thread-Item `type = "imageGeneration"` (SDK-Klasse `ResultThreadItem`): `status`, `savedPath`, `result` (das Bild als Base64), `revisedPrompt` (von Codex umformulierte, meist englische Beschreibung), `transparentBackground`, `inputImages` (Pfad + SHA-256 der lokalen Eingabebilder), `failure` (nur `usageLimitExceeded` mit `limitId`, `resetsAt`). |
| Wo landet die Datei? | `<CODEX_HOME>/generated_images/<Thread-ID>/<Item-ID>.png`, auch mit Nur-Lese-Sandbox (schreibt Codex selbst, nicht das Modell). Inhalt identisch mit `result`. |
| Formate, Größen | PNG. 1:1 → 1254×1254, 3:2 → 1536×1024, 16:9 → 1672×941 (Seitenverhältnis steht in der Beschreibung). Etwa 1,3–3 MB je Bild. |
| Transparenter Hintergrund | Ja: PNG mit Alpha, `transparentBackground: true`. |
| Bearbeiten | Eingabebilder als `LocalImageInput` (Pfad) oder `ImageInput` (Data-URL). Ein Bild (Apfel rot → grün): Ausschnitt, Licht, Wassertropfen, Stiel und Größe (1254×1254) blieben gleich, nur die Farbe änderte sich. Zwei Bilder kombiniert (Sonnen-Sticker in das Apfelfoto, 16:9): Sticker sauber freigestellt eingesetzt, Foto unverändert, Hintergrund seitlich erweitert. Codex sieht sich lokale Eingaben vorher mit `view_image` an. |
| Dauer | 22–38 s je Bild von Start bis Ende, davon 12–23 s reine Bilderzeugung; Bearbeiten etwas länger. Start des Codex-Prozesses unter 1 s. |
| Abbrechen | `turn.interrupt()` beendet den Zug sofort (`status: interrupted`), ein halbfertiges Bild wird nicht abgelegt. |
| Fehler und Limits | Bild-Limit als `failure.type = usageLimitExceeded` am Item; Abo-Limit oder abgelaufene Anmeldung als Fehler im `turn/completed` (wie bei Chat-Läufen). Inhaltliche Ablehnungen kommen als Text ohne Bild-Item. |

Testbilder der Erkundung: 4 fertige Bilder und ein abgebrochener Lauf (Apfel, transparenter Sonnen-Sticker 3:2, Apfel
grün bearbeitet, beide kombiniert 16:9).

## Wie es läuft

### ChatGPT-Scoops im Codex-Weg (Chat übers ChatGPT-Abo)

- Der Codex-Chat-Thread bekommt das eingebaute Bildwerkzeug (`features.image_generation=true`) und eine Zeile in der
  Systemanweisung (`bilder.NATIVE_PROMPT`): dass er Bilder erstellen und bearbeiten kann, wie er ein Bild aus der
  Bibliothek vorher mit `datei_lesen` ins Gespräch holt, dass der Server fertige Bilder selbst speichert und zeigt.
- `CodexChatEngine._turn` meldet Bild-Items an `bilder.ChatImages`: Statuszeile „Erstellt ein Bild“, fertiges Bild →
  Bibliothek, Arbeitsordner, Karte im Chat; die Datei in `generated_images` wird danach gelöscht.
- Die Werkzeuge `bild_erstellen`/`bild_bearbeiten` fallen in diesen Läufen weg (keine doppelten Wege).
- Name: „Bild JJJJ-MM-TT HH.MM.png“ (Codex' umformulierte Beschreibung ist meist englisch und lang).

### Alle anderen Läufe: Werkzeuge

Claude-Scoops (Claude-Abo und API), OpenAI-Scoops im API-Weg und Hintergrund-Aufgaben (Claude Agent SDK, Codex, eigene
Schleife) bekommen zwei Werkzeuge:

| Werkzeug | Parameter |
|---|---|
| `bild_erstellen` | `beschreibung` (Pflicht), `format` (`auto`, `1:1`, `3:2`, `2:3`, `16:9`, `9:16`, `4:3`, `3:4`; Standard 1:1), `transparent`, `dateiname` |
| `bild_bearbeiten` | `bilder` (1–4: Bibliotheks-ID `f_…` – auch Anhänge, die der Nutzer gerade geschickt hat –, `zuletzt` = neuestes Bild im Chat, oder Pfad relativ zum Arbeitsordner des Scoops bzw. der Aufgabe), `anweisung` (Pflicht), `format` (leer = wie Bild 1), `transparent`, `dateiname` |

Jeder Aufruf ist ein **eigener, vom Chat getrennter Codex-Lauf** (`bilder.generate`): neuer Codex-Prozess mit dem
Scoops-`CODEX_HOME`, Shell aus, Web aus, keine MCP-Server, Nur-Lese-Sandbox, flüchtiger Thread (`ephemeral`), eigener
Temp-Ordner `<data>/abo/bilder/<Lauf>/` mit den vorbereiteten Eingabebildern, Modell `gpt-6.2-sol` (config
`image_model`), Aufwand `low`. Die Anweisung an Codex: genau ein Bild, keine Rückfragen, beim Bearbeiten alles Übrige
unverändert lassen, sonst „Abgelehnt: <Grund>“.

Ergebnis an den Scoop: Text mit Name, Bibliotheks-ID, Pfad im Arbeitsordner (bzw. `bilder/…` in der Aufgabe), Maßen,
Format, Dauer – und **das Bild selbst** (bis 1024 px, JPEG bzw. PNG bei Transparenz), damit er es ansehen und mit
`bild_bearbeiten` nachbessern kann. Eine `.jpg`- oder `.webp`-Endung im Dateinamen speichert in diesem Format.

## Ablage und Anzeige

- **Bibliothek** des Chats (`kind = "bild"`), **Arbeitsordner** `<Scoop>/Dateien/` (docs/arbeitsordner.md). Aus Aufgaben:
  `<Scoop>/Aufgaben/<JJJJ-MM-TT Titel>/`, zusätzlich `bilder/<Name>` im Arbeitsordner der Aufgabe (nicht `ergebnis/`, sonst
  käme es am Ende doppelt in die Bibliothek), und die Datei steht in der Dateiliste der Aufgabe.
- **Im Chat** sofort ein Ereignis „Bild erstellt: <Name>“ bzw. „Bild bearbeitet: <Name>“ mit `meta.file_id`. Die App
  zeigt solche Karten ab 1.3 als Bildvorschau (`ImageFileCard`, Seitenverhältnis des Bildes, höchstens 300 Punkte hoch,
  Antippen öffnet die Vorschau); ältere Apps zeigen die bekannte Dateikarte. `meta.prompt` nennt dem Scoop im nächsten
  Lauf Name und Bibliotheks-ID.
- **Statuszeile** „Erstellt ein Bild“ bzw. „Bearbeitet ein Bild“, solange der Lauf malt. Der **Stopp-Knopf** bricht den
  Bildlauf ab (Chat: `RunState.cancel`; Aufgabe: Stopp der Aufgabe), Codex wird unterbrochen und beendet.

## Verfügbarkeit

- Die Werkzeuge (und das eingebaute Bildwerkzeug) gibt es nur, wenn Codex auf dem Server **mit ChatGPT angemeldet** ist
  (`codex login status`, über `abos.login_status`). Unabhängig vom Abrechnungsmodus, weil es keinen API-Weg gibt.
  Abschalten: `"images": false` in `config.json`.
- Ohne ChatGPT-Abo bekommt der Scoop einen Satz in der Systemanweisung: Wünscht sich der Nutzer ein Bild, sagt er, dass
  man dafür in den Einstellungen unter „KI-Abos“ ChatGPT verbindet. Kein anderer Weg.
- Abo-Limit, Bild-Limit (`usageLimitExceeded`, mit Uhrzeit) und abgelaufene Anmeldung kommen als verständlicher Text an
  den Scoop (nach dem Muster von `abos.SubscriptionUnavailable`); ein Abo-Limit im Zug wird wie bei Chat-Läufen vermerkt,
  ein reines Bild-Limit nicht (Chats laufen weiter übers Abo). Inhaltliche Ablehnungen gibt der Scoop ehrlich weiter.
- `GET /api/health` → `images: {supported, available, via: "chatgpt_abo", hint}`.
- Test-/Offline-Modus (`AISBOT_OFFLINE=1`): nur mit ausdrücklichem `"images": true`, damit Tests nie ein echtes Abo nutzen.
  Demo-Server: nie.

## Grenzen

| | Wert |
|---|---|
| Zeitlimit je Bild | 5 Minuten (`bilder.TIMEOUT`), danach Unterbrechung und Meldung |
| Gleichzeitige Bildläufe | 2 je Server (`MAX_PARALLEL`); weitere warten bis zu 3 Minuten mit Zeile „Wartet auf einen freien Platz für Bilder“ |
| Eingabebilder | höchstens 4, je höchstens 25 MB; über 2048 px oder über 8 MB werden sie vorher verkleinert; PNG, JPEG, WebP, GIF, HEIC (über `sips`) |
| Aufräumen | Temp-Ordner, Datei und Thread-Ordner in `generated_images` und der Codex-Prozess nach jedem Lauf (auch bei Fehlern) |

## Gäste, Editionen, Nutzung

- **Gäste geteilter Scoops:** Gast-Läufe gehen nie über das Abo des Admins (docs/abos.md). Darum keine Bildwerkzeuge in
  Gast-Läufen (sie stehen auch nicht in `sharing.GUEST_BASE_TOOLS`) und kein eingebautes Bildwerkzeug (Gast-Läufe nehmen
  immer die API). Bilder aus Läufen des Admins sehen Gäste wie andere Dateien des Chats.
- **Editionen:** gleich in `personal` und `standard`; das Scoops-`CODEX_HOME` liegt im jeweiligen Datenordner.
- **Nutzung:** Jeder Bildlauf zählt als Abo-Lauf (`usage.billing = 'abo'`, 0 $) mit dem Modell des Bildlaufs und
  erscheint in `/api/usage` unter `abo` und auf der Seite „Nutzung und Verbrauch“ wie andere Abo-Läufe. Bilder im
  Codex-Chat-Thread stecken im Abo-Lauf des Chats.
- **Codex-Aufgaben** haben das eingebaute Bildwerkzeug aus (`features.image_generation=false`, auch im API-Weg, damit
  Codex nie mit dem API-Schlüssel malt); sie nutzen `bild_erstellen`/`bild_bearbeiten`.

## Ende-zu-Ende geprüft (19.11.2026)

Testserver (eigener `AISBOT_HOME`, eigener Port, Edition `standard`), Codex mit dem ChatGPT-Login dieses Macs (eigene
MCP-Server des Nutzers abgeschaltet), ChatGPT-Scoop mit echter Codex-Chat-Engine, Claude-Scoop mit Attrappe des
Claude-Modells (ruft die Werkzeuge auf, der Bildlauf ist echt).

| Schritt | Weg | Dauer (ganzer Chat-Lauf) | Ergebnis |
|---|---|---:|---|
| ChatGPT-Scoop: „roter Leuchtturm auf einer Klippe, Querformat 3:2“ | eingebautes Bildwerkzeug im Chat-Thread | 25 s | 1536×1024 PNG, Karte im Chat, Bibliothek, `Gina/Dateien/` |
| ChatGPT-Scoop: Apfel.png aus der Bibliothek blau färben | `datei_lesen` → eingebautes Bildwerkzeug | 24 s | 1254×1254, nur die Farbe geändert (Stiel, Licht, Ausschnitt gleich) |
| Claude-Scoop: Kaffeetasse mit Latte-Art, 1:1 | `bild_erstellen` (eigener Codex-Lauf) | 20 s | 1254×1254 PNG, Bild im Werkzeug-Ergebnis |
| Claude-Scoop: Tasse gelb, `bilder: ["zuletzt"]`, `dateiname: "Kaffee gelb.png"` | `bild_bearbeiten` | 25 s | nur die Tasse gelb, Rest gleich |

`/api/usage` zählte die Läufe unter `abo` (`gpt-6.2-sol`, 0 $). `generated_images` und `<data>/abo/bilder` waren danach
leer. Im Mittel etwa 22.000 Eingabe-Token je Abo-Lauf (vor allem Codex' Grundanweisungen). Wie stark ein Bild das
Abo-Kontingent belastet, meldet Codex nicht gesondert.

## Nach dem Deploy auf dem echten Server prüfen

- `GET /api/health` → `images.available = true` (Scoops-`CODEX_HOME` mit ChatGPT angemeldet).
- Ein ChatGPT-Scoop und ein Claude-Scoop erstellen je ein Bild; Karte mit Vorschau in der App, Datei in `~/Scoops/<Scoop>/Dateien/`.
- „Mach das blauer“ auf ein gerade geschicktes Foto (Anhang) – bei ChatGPT-Scoops direkt, bei Claude-Scoops mit
  `bild_bearbeiten`.
- `<data>/abo/codex/generated_images` und `<data>/abo/bilder` bleiben leer.
