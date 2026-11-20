# Arbeitsordner der Scoops (Server 1.27)

Der Nutzer wählt einen **Arbeitsordner auf dem Server-Mac**. Darin hat jeder Scoop einen Unterordner mit seinem Namen. Was
Scoops an Dateien erzeugen, liegt so an einer Stelle im Finder, zusätzlich zur Bibliothek in der App. Code:
`Server/src/aisbot/workspace.py`, Tests: `Server/tests/test_workspace.py`, API: `docs/API.md` („v1.27“).

```
<Arbeitsordner>/
  Codi/
    Dateien/                         einzeln gespeicherte Dateien
    Aufgaben/2026-11-16 Pinguin-Bericht/   Ergebnisse einer Hintergrund-Aufgabe
  Lisa/
  …
```

## Einstellung

- `workspace_dir` in `config.json` (mit `~` gespeichert, z. B. `~/Desktop/Scoops`).
- **Standard für neue Server: `~/Scoops`.** Begründung: liegt außerhalb von Schreibtisch und Dokumente. Dort fragt macOS
  nicht nach einer Datenschutz-Freigabe für den Server, und iCloud lagert keine Dateien aus („Speicher optimieren“). Wer
  die Dateien auch unterwegs sehen will, wählt einen Ordner in Schreibtisch/Dokumente (iCloud).
- Testinstanzen (eigener Datenordner bzw. `AISBOT_OFFLINE=1`) nehmen `<Datenordner>/../Scoops`, damit Tests nie im echten
  Home-Ordner schreiben. `AISBOT_WORKSPACE` überschreibt den Standard.
- Beim Setzen prüft der Server: absoluter Pfad oder `~/…`, nicht Home oder `/`, nicht im Datenordner oder `~/Library`,
  anlegbar, beschreibbar (echte Testdatei). Fehler kommen als verständlicher Text zurück.
- Ändern: Mac-App „AIS Scoops Server“ → Einstellungen → Arbeitsordner („Auswählen …“, „Im Finder zeigen“), oder in der
  App unter Einstellungen → Arbeitsordner (nur Admin; Ordnerliste über den Server, auch auf iPhone/iPad).

## Was wohin kommt

- **`datei_speichern`**: Bibliothek wie bisher, dazu eine Kopie in `<Scoop>/Dateien/`. Der Scoop bekommt den Pfad zurück.
- **Bilder** (`bild_erstellen`, `bild_bearbeiten` und Bilder von ChatGPT-Scoops, ab 1.39, `docs/bilder.md`): Bibliothek
  und `<Scoop>/Dateien/`; aus einer Aufgabe `<Scoop>/Aufgaben/<JJJJ-MM-TT Titel>/` und `bilder/` im Arbeitsordner der Aufgabe.
- **Aufgaben-Ergebnisse** (`ergebnis/` bzw. `datei_in_bibliothek`): Bibliothek wie bisher, dazu
  `<Scoop>/Aufgaben/<JJJJ-MM-TT Titel>/`. Die Aufgabe selbst arbeitet weiter isoliert in `<Daten>/tasks/<id>/` und
  darf den Scoop-Ordner nicht selbst anfassen; kopiert wird vom Server.
- **`datei_auf_rechner` ohne Pfad**: Läuft der Rechner des Scoops auf dem Server-Mac (Scoops Connect, direkt, gleiche
  Geräte-ID), landet die Datei in `<Scoop>/Dateien/`. Andere Rechner (VM, anderer Mac) behalten `~/Downloads`.
- Nichts wird überschrieben: gleicher Name mit anderem Inhalt → `Name (2).md`; gleicher Inhalt → keine Doppelung.
- Spiegeln ist „best effort“: Ein Fehler (z. B. fehlende Freigabe) bricht das Speichern in der Bibliothek nie ab. Er
  steht im Protokoll und im Status (`error`). Jeder Dateizugriff hat eine Zeitgrenze von 8 s, damit ein Scoop-Lauf nie an
  einer offenen macOS-Abfrage hängt.

## Entscheidungen

- **Gruppen:** Dateien landen im Ordner des Scoops, der sie erzeugt (der handelnde Scoop), nicht in einem Gruppenordner.
- **Umbenennen:** Der Ordner wird mit umbenannt. Gibt es den neuen Namen schon, bleibt der alte Ordner unverändert
  liegen, und der Scoop nutzt ab jetzt den Ordner mit dem neuen Namen. Gelöschte Scoops: Ordner bleibt.
- **Ordnernamen:** Scoop-Name, `/` und `:` werden zu `-`, keine führenden Punkte.
- **Wechsel des Arbeitsordners:** Nichts wird verschoben. Der neue Ort wird angelegt, die alten Ordner bleiben. Der Status
  (`previous`, bis zu drei) zeigt in App und Mac-App, wo noch alte Dateien liegen. Verschieben macht der Nutzer selbst im
  Finder.

## Rechner-Zugriff (1.29)

Der Ordner des Scoops ist sein Standard-Bereich („Nur Arbeitsordner“): Dort arbeiten Chat-Werkzeuge und Aufgaben
direkt. Projektordner, „Überall“, Rechte-Modus und Festplattenvollzugriff: [`docs/rechnerzugriff.md`](rechnerzugriff.md).

## Anweisungen an die Scoops

- Chat: eigener Block „Dein Arbeitsordner auf dem Mac: …“ (bzw. „liegt auf dem Server-Mac …“, wenn der Rechner des Scoops
  ein anderer ist). Er gilt ausdrücklich vor älteren Pfadangaben im Gedächtnis. Gäste bekommen ihn nicht.
- Aufgaben: „Dein Arbeitsordner auf dem Mac: …“ plus der Zielordner der Ergebnisse; die Regel „Arbeite nur im
  Arbeitsordner“ der Aufgabe bleibt.

## macOS-Datenschutz (Schreibtisch, Dokumente)

Liegt der Ordner in Schreibtisch oder Dokumente, fragt macOS beim ersten Zugriff, ob der Server dort Dateien nutzen darf.
Auf Armans Server (LaunchAgent) heißt die Abfrage „python3.12“, bei der Mac-App „AIS Scoops Server“. Einmal „Erlauben“
reicht. Wer „Nicht erlauben“ wählt, bekommt im Status einen Fehler; dann einen Ordner außerhalb wählen oder in den
Systemeinstellungen → Datenschutz → Dateien und Ordner nachträglich erlauben.
