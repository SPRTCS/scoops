# Aufsicht über die anderen Scoops (Server 1.21)

Ein Scoop mit Aufsicht kann die Arbeit der anderen Scoops prüfen und sie dauerhaft verbessern, etwa in einer
wöchentlichen Routine des Haupt-Scoops: Chats durchgehen → Vorschläge an den Nutzer → nach seinem Feedback umsetzen.

## Wer darf

- Der **Haupt-Scoop** immer.
- Andere Scoops nur mit dem Schalter **„Darf andere Scoops prüfen“** (Scoop-Profil → Verwalten → Aufsicht;
  API `PATCH /api/bots/{id}` `{"can_review": true}`, nur Admin). Standard: aus.
- Die Werkzeuge gibt es nur in Läufen des Admins **im eigenen Einzelchat** des Scoops. Nie:
  - in Gast-Läufen geteilter Scoops,
  - solange der Chat des Scoops mit Gästen geteilt ist (seine Antworten sähen auch die Gäste),
  - in Läufen auf Bitte eines anderen Scoops (`scoop_schreiben`; die Antwort ginge in dessen Chat),
  - in Gruppenchats.
- Gelesen werden nur Scoops und Gruppen **dieses Servers**. Scoops, die andere mit dem Nutzer teilen („Mit mir
  geteilt“), liegen auf fremden Servern und sind nie erreichbar.

## Werkzeuge

| Werkzeug | Inhalt |
|---|---|
| `scoops_ueberblick` (`seit`) | alle anderen Scoops und Gruppen: Modell, Charakter kurz, letzte Aktivität, Nachrichten/Antworten/Läufe und Kosten im Zeitraum (Gast-Anteil getrennt), Fehler, Abbrüche, Korrekturen/Nachfragen, offene/abgelehnte Freigaben, Routinen mit Modell und letztem Lauf, Dauerfreigaben, Zahl der Fähigkeiten/Gedächtnis-Einträge |
| `chat_lesen` (`name`, `seit`, `bis`, `seite`, `nur_probleme`) | Verlauf, ältere zuerst, seitenweise; pro Antwort Modell, Dauer, Kosten und Arbeitsschritte; Nachrichten über 1 200 Zeichen gekürzt; Bilder/Anhänge als Platzhalter; `nur_probleme` = Fehler, Abbrüche (Stopp, Kosten-/Schrittgrenze, Neustart), abgelehnte Freigaben, Korrekturen („nein“, „falsch“, „nochmal“ …) und wiederholte Bitten, jeweils mit Kontext |
| `scoop_details` (`name`) | Charakter/Anweisungen, eigene Fähigkeiten mit Anleitung und ID, Gedächtnis-Einträge mit ID (ohne Einträge von Gästen), Tagebuch, Routinen mit ID/Modell/Auftrag, Dauerfreigaben, Einstellungen; bei Gruppen die Mitglieder. Kein Tresor. |
| `scoop_verbessern` | Vorschlag einer dauerhaften Änderung → Freigabe-Karte (siehe unten) |
| `scoop_schreiben` (vorhanden) | Feedback direkt an einen Scoop; beim Empfänger als „Nachricht von Scoop X (Aufsicht über die Scoops)“ gekennzeichnet. Alle Scoops sind angewiesen, solches Feedback mit `merken` bzw. `faehigkeit_speichern` dauerhaft zu übernehmen. |

**Aufgabenmodus (seit 1.22.1):** Startet der Haupt-Scoop die Prüfung als Hintergrund-Aufgabe (`aufgabe_starten`), bekommt die
Aufgabe `scoops_ueberblick`, `chat_lesen`, `scoop_details` und `scoop_verbessern` ebenfalls (`TaskManager.tools_for`), samt
Aufsicht-Anweisung im Aufgaben-Systemprompt. Vorschlags-Karten pausieren die Aufgabe nicht.

Zeitangaben: `2026-11-09`, `09.11.`, ISO-Zeitpunkt, `7 Tage`, `24h`, `heute`, `gestern`; leer = letzte 7 Tage bis jetzt.

**Grenzen:** jede Ausgabe ≤ 12 000 Zeichen (Seiten à ca. 10 500 Zeichen; der Überblick wird bei vielen Scoops kompakter,
bevor er gekürzt wird), höchstens 3 000 Nachrichten pro Chat und Aufruf. So bleibt ein Wochen-Review günstig;
für die Routine kann ein eigenes Modell gesetzt werden (`routines.model`).

**Datenschutz:** Nachrichten von Gästen geteilter Scoops und alles bis zur nächsten Nachricht des Admins (die Antworten
an den Gast) werden ausgeblendet, ebenso alles mit `meta.guest_run`. Der Systemprompt verbietet, Inhalte aus fremden
Chats an Gäste, in geteilte Chats oder nach außen zu geben.

## Verbesserungen (`scoop_verbessern`)

Arten: `faehigkeit` (neue oder geänderte Anleitung), `gedaechtnis` (neuer Eintrag, optional einen ersetzen),
`anweisungen` (Charakter ergänzen oder ersetzen), `routine_modell`. Jede braucht eine `begruendung` mit Beleg.

1. Der Server prüft den Vorschlag und legt im Chat des vorschlagenden Scoops eine Freigabe-Karte an
   (`meta.kind = "scoop_update"`, `meta.scoop_update` mit Ziel-Scoop, Vorher/Nachher). **Kein „Immer erlauben“**,
   keine automatische Freigabe – auch nicht über manipulierte Dauerfreigaben.
2. Der Nutzer kann den neuen Text in der Karte bearbeiten (`edits.after`) und freigibt oder lehnt ab.
3. Erst nach „Freigeben“ wird angewendet (`oversight.apply_update`). Ereignisse: „Übernommen: …“ im Chat des
   Vorschlagenden (er läuft weiter), „Verbesserung von X: …“ im Chat des geänderten Scoops (mit Hinweis in seinem
   Verlauf, ohne eigenen Lauf).

Code: `Server/src/aisbot/oversight.py`, Einbindung in `bots.py` (`can_oversee`, `_tools`, `_decide_scoop_update`),
Prompt-Abschnitt `prompts.OVERSIGHT`. Test: `Server/tests/test_oversight.py`.
