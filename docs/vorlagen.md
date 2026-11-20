# Scoop-Vorlagen

Stand: App 1.3. Umsetzung: `Server/src/aisbot/vorlagen.py`; App: `App/AISBot/Templates/`. Beispiele: [`vorlagen/`](vorlagen/).

Eine Vorlage ist eine Datei, mit der andere einen Scoop bei sich anlegen können: Aussehen, Rolle, Anweisungen,
Fähigkeiten und Routinen. Sie enthält nichts Persönliches und keine Zugänge.

## Was drin ist und was nie

**Enthalten:** Name, Aussehen (Form, Farbe, Augen, Accessoire; das eigene Bild nur auf Wunsch), Rolle, Charakter und
Anweisungen, Fähigkeiten, Routinen (Zeitplan und Auftrag), bevorzugtes Modell, Hinweise auf benötigte Verbindungen
(„braucht Gmail“).

**Nie enthalten:** Gedächtnis, Chatverlauf, Dateien, Tresor, Konten und Tokens von Verbindungen, dauerhafte Freigaben,
Rechte (Rechner-Zugriff, Teilen), Nutzungsdaten, Name oder Adressen des Besitzers, Erinnerungen. Der Export liest diese
Daten gar nicht erst.

Die Anweisungen selbst kann der Server nicht beurteilen. Steht dort ein Name oder eine Adresse, landet er in der Datei.
Darum zeigt die App vor dem Export genau, was in die Datei kommt, und weist auf Namen, Mailadressen und Telefonnummern
in den Texten hin.

## Exportieren

Profil → Verwalten → **Als Vorlage exportieren**, oder Scoop in der Seitenleiste gedrückt halten (Mac: Rechtsklick).

Die Vorschau zeigt jeden Teil mit Schalter: Aussehen, eigenes Bild (standardmäßig aus), Charakter und Anweisungen, jede
Fähigkeit, jede Routine, Modell, jede benötigte Verbindung. Fähigkeiten, die für alle Scoops gelten, sind standardmäßig
aus. Dazu ein Feld für eine kurze Beschreibung. Danach **Teilen** (Teilen-Menü: AirDrop, Nachrichten, Mail …) oder
**Sichern unter** am Mac bzw. **In Dateien sichern** auf iPhone und iPad.

Gäste eines geteilten Scoops können ihn nicht exportieren (Menüpunkt fehlt, der Server antwortet mit 403).

## Importieren

- Datei öffnen: antippen bzw. doppelklicken, „Öffnen mit“, AirDrop, am Mac und iPad auch ins Fenster ziehen.
- Beim Anlegen: **+** → Neuer Scoop → **Aus Vorlage …**. Am Mac zusätzlich Ablage → **Scoop aus Vorlage …** (⌘O).

Vor dem Anlegen zeigt die Vorschau die Figur, den Namen (änderbar), die Rolle, die **vollständigen** Anweisungen, jede
Fähigkeit und jede Routine mit Schalter, die benötigten Verbindungen mit Stand (verbunden oder fehlt noch) und das
Modell. Erst **Scoop anlegen** legt etwas an.

## Sicherheit

Eine Vorlage ist fremder Inhalt. Darum gilt:

- **Standardrechte.** Der neue Scoop startet mit dem Standard für den Rechner-Zugriff (Automatisch, nur Arbeitsordner),
  ohne dauerhafte Freigaben, nicht geteilt, nicht angeheftet, nicht als Haupt-Scoop. Diese Felder gibt es im Format
  nicht; stehen sie trotzdem in einer Datei, fallen sie weg.
- **Routinen pausiert.** Sie werden ausgeschaltet angelegt und laufen erst, wenn der Nutzer sie im Profil einschaltet.
- **Kein automatischer Lauf.** Nach dem Import steht nur eine Zeile im Chat. Der Scoop arbeitet erst, wenn der Nutzer
  ihm schreibt (ein normal angelegter Scoop stellt sich dagegen sofort vor).
- **Strenge Prüfung auf dem Server:** Dateigröße höchstens 1,5 MB, Längengrenzen für jeden Text, höchstens 30
  Fähigkeiten und 20 Routinen, nur bekannte Formen, Augen und Accessoires, Farbe als `#RRGGBB`, Zeitplan als Cron mit
  genau fünf Feldern. Unbekannte Felder werden ignoriert. Steuerzeichen und unsichtbare Richtungszeichen werden entfernt.
  Es gibt keine Pfade und nichts Ausführbares.
- **Bild:** muss sich als Bild öffnen lassen und wird immer neu kodiert (256 px), nie unverändert gespeichert.
- **Zeitplan in Worten** berechnet der Server selbst aus dem Cron-Ausdruck. Dem Text in der Datei traut er nicht. Läuft
  eine Routine öfter als stündlich, warnt die Vorschau („rund 288-mal pro Tag“).
- **Modell:** wird nur übernommen, wenn es auf dem Server eingerichtet ist und der Nutzer den Schalter anlässt, sonst
  gilt das Standardmodell.
- **Alles oder nichts.** Scoop, Fähigkeiten, Routinen und Bild entstehen in einer Transaktion. Scheitert ein Teil,
  bleibt nichts zurück.
- **Neuere Formatversion:** Der Server lehnt sie mit einer verständlichen Meldung ab („… mit einer neueren Version von
  AIS Scoops erstellt (Format 2) …“). Die App prüft das schon vor dem Hochladen.

## Format

JSON, UTF-8, Endung `.scoop`, Typ `com.ais.aisbot.scoop-template` (exportierter UTType, konform zu `public.json`,
MIME `application/vnd.ais.scoop+json`).

```json
{
  "format": 1,
  "type": "ais-scoops-template",
  "name": "Mona",
  "label": "Morgenbriefing",
  "description": "Fasst jeden Werktag um 7:30 zusammen, was heute ansteht.",
  "appearance": {"shape": "circle", "color": "#FBBA10", "eyes": "lashes", "accessory": "headset",
                 "gaze": "right", "mouth": "smile"},
  "character": "Du bist ruhig, freundlich und kommst sofort zum Punkt. …",
  "model": "claude-haiku-5-5",
  "skills": [{"name": "Tagesüberblick schreiben", "description": "Aufbau des Morgenbriefings", "steps": "1. …\n2. …"}],
  "routines": [{"title": "Morgenbriefing", "schedule": "30 7 * * 1-5", "schedule_text": "Werktags um 7:30",
                "prompt": "Schreib das Morgenbriefing für heute."}],
  "requires": [{"kind": "app", "id": "gmail", "name": "Gmail", "note": "Zum Lesen der Mails."}]
}
```

| Feld | Pflicht | Grenze | Bedeutung |
|---|---|---|---|
| `format` | ja | Ganzzahl ≥ 1 | Formatversion, derzeit `1`. Höhere Zahlen lehnt der Server ab. |
| `type` | ja | `ais-scoops-template` | Kennzeichen, dass es eine Scoop-Vorlage ist |
| `name` | ja | 40 Zeichen, einzeilig | Name des Scoops (beim Import änderbar) |
| `label` | – | 60 Zeichen | Rolle, zum Beispiel „Assistenz“ |
| `description` | – | 600 Zeichen | Kurzbeschreibung für andere; landet nicht im Prompt |
| `appearance` | – | | `shape`, `color`, `eyes`, `accessory`, dazu `gaze`, `mouth`, `cheeks` (Werte wie im Bot-Objekt, [API.md](API.md)). Unbekannte Werte werden zum Standard. |
| `appearance.photo` | – | 600 000 Zeichen Base64 | `{"mime": "image/jpeg", "data": "<Base64>"}`, eigenes Bild |
| `character` | – | 8000 Zeichen | Charakter und Anweisungen (Prompt) |
| `model` | – | 80 Zeichen | Bevorzugtes Modell (Kennung aus dem Modellkatalog) |
| `skills[]` | – | 30 Einträge | `name` (80, Pflicht, eindeutig), `description` (400), `steps` (6000, Pflicht) |
| `routines[]` | – | 20 Einträge | `title` (80, Pflicht), `schedule` (Cron mit fünf Feldern, Pflicht), `prompt` (4000, Pflicht), `model` |
| `routines[].schedule_text` | – | | Zeitplan in Worten, nur für Menschen, die die Datei lesen. Beim Import neu berechnet. |
| `requires[]` | – | 30 Einträge | `kind` (`app`, `mcp`, `apple`, `other`), `id` (Kennung, bei `app` der Composio-Slug), `name` (60, Pflicht), `note` (200) |

Regeln für spätere Versionen: Neue optionale Felder kommen ohne neue Formatnummer dazu (ältere Server ignorieren sie).
Die Nummer steigt nur, wenn eine ältere Version die Datei falsch verstehen würde.

`requires` ist ein Hinweis, keine Bedingung: Der Import klappt auch ohne die Verbindung. Beim Export erkennt der Server
Verbindungen an Wörtern in den Texten (Gmail, Google Kalender, Outlook, Notion, Google Drive, Sheets, Docs, Slack,
GitHub, LinkedIn, weitere verbundene Apps, eigene MCP-Server, Apple-Dienste). In der Vorschau lässt sich jede Zeile
abwählen.

## Beispiele

Unter [`vorlagen/`](vorlagen/) liegen drei Vorlagen ohne persönliche Daten, mit denen auch die Tests importieren:

| Datei | Scoop | Enthält |
|---|---|---|
| `Morgenbriefing.scoop` | Mona, Morgenbriefing | 1 Fähigkeit, 2 Routinen, braucht Gmail und Google Kalender |
| `Recherche.scoop` | Theo, Recherche | 2 Fähigkeiten, keine Verbindungen |
| `Lernbegleiter.scoop` | Lumi, Lernbegleiter | 1 Fähigkeit, 1 Routine |

## API

Alle drei Endpunkte nur für den Inhaber (Gäste: 403).

| Methode | Pfad | Body | Antwort |
|---|---|---|---|
| GET | `/api/bots/{id}/template` | – | `{"template": {…}, "optional": {"skills": […], "photo": {…} \| null}, "warnings": [{"where", "text"}], "file_name": "Mila.scoop"}` |
| POST | `/api/templates/check` | Inhalt der Datei (oder `{"template": {…}}`) | `{"template": {…}, "model": {"id", "resolved", "available", "default"}, "notes": […]}` |
| POST | `/api/templates/import` | `{"template": {…}, "name"?, "routines"?: [0, 2], "skills"?: [0], "use_model"?: true, "use_photo"?: true}` | `{"bot": Bot, "skills": 1, "routines": 2, "model_from_template": false}` |

- **Export:** `template` ist, was standardmäßig in die Datei kommt. `optional` kommt nur auf Wunsch dazu (Fähigkeiten für
  alle Scoops, Bild). Die App baut die Datei aus dem, was in der Vorschau eingeschaltet ist.
- **Prüfen:** legt nichts an. Die Antwort enthält die geprüfte Vorlage, wie sie angelegt würde: je Routine zusätzlich
  `schedule_text` (vom Server) und `runs_per_day`, je Verbindung `status` (`connected`, `missing`, `unknown`).
- **Import:** `routines` und `skills` sind Positionen in der Vorlage; ohne Angabe alle. `name` ersetzt den Namen.
  Ereignisse wie beim normalen Anlegen: `bot.created`, `skill.updated`, `routine.updated`, `message.created`.
- Fehler: 400 mit Text (keine Vorlage, neueres Format, Text zu lang, ungültiger Zeitplan …), 413 zu groß.
- `GET /api/health` meldet `"templates": 1` (höchste lesbare Formatversion). Ältere Server haben das Feld nicht; die App
  blendet Export und Import dann aus.

## Tests

`cd Server && uv run python tests/test_vorlagen.py` (98 Prüfungen: Export ohne Privates, strenge Prüfung, Standardrechte,
pausierte Routinen, kein Lauf, alles oder nichts, Hin und zurück, die drei Beispielvorlagen). Gäste: `test_sharing.py`.
Demo-Modus der App: `-mock -templatedemo` zeigt die Import-Vorschau, `-mock -select b_mila -templateexport` die
Export-Vorschau.
