# Seite „Heute“ und Freigaben-Postfach (App 1.3)

Bei mehreren Scoops sah man bisher nirgends auf einen Blick, wer auf einen wartet: Freigabe-Karten standen nur im
jeweiligen Chat und in der Mitteilung. Die Seite „Heute“ ist der Startpunkt über alle Scoops.
API: [`API.md`](API.md) („Seite Heute“), Server: `Server/src/aisbot/today.py`, App: `App/AISBot/Views/Today/`.

## Wo sie steht

- **Fester Eintrag „Heute“** ganz oben in der Seitenleiste bzw. Chatliste, mit rotem Zähler. Bei der Suche in der
  Seitenleiste ist er ausgeblendet.
- **iPad und Mac:** Startansicht in der Mitte, solange kein Chat gewählt ist. Der Eintrag wählt den Chat ab.
- **iPhone:** eigene Seite über der Chatliste. Ein von dort geöffneter Chat liegt darüber, „Zurück“ führt wieder zu „Heute“.
- **Befehlspalette:** „Heute“. **Mac:** ⇧⌘H (Menü „Darstellung“), auf der Seite ⌘R zum Aktualisieren. iPadOS belegt
  ⇧⌘H selbst, dort gibt es das Kürzel nicht.
- **Link** `aisbot://today` (Kurzbefehle, Widgets, [system.md](system.md)): öffnet die Seite, beim Kaltstart sobald die
  Verbindung steht. Ohne Seite (älterer Server, nur Gast) kommt nur die App nach vorn.
- Nur für den **eigenen Server**. Gäste geteilter Scoops können keine Freigaben entscheiden und sehen weder Aufgaben noch
  Routinen; reine Gast-Verbindungen bekommen die Seite deshalb nicht (der Server antwortet 403). Ungelesene Chats mit
  mir geteilter Scoops stehen trotzdem unter „Seit gestern erledigt“, die kennt die App ohnehin.
- **Ältere Server** (Health ohne `today`): Eintrag, Palette und Startansicht bleiben wie bisher („Wähle einen Scoop“).
  Nach einem Server-Update erscheint die Seite beim nächsten Verbinden von selbst.

## Abschnitte

Jeder Abschnitt erscheint nur, wenn es etwas gibt. Ist alles leer, zeigt die Seite den Haupt-Scoop (sonst den ersten,
ohne Scoops die Marken-Figur) mit „Alles ruhig“ und den Knöpfen „Neue Aufgabe“ und „Aufgaben öffnen“.

1. **Wartet auf dich:** alle offenen Freigaben aus Einzelchats, Gruppen und Hintergrund-Aufgaben. Gezeigt werden
   dieselben Karten wie im Verlauf (`MessageRow`: Freigabe, Mail, Tresor, Verbesserung, sichere Eingabe), also mit
   denselben Aktionen: Freigeben, Ablehnen, „Immer erlauben“, Bearbeiten. Über jeder Karte steht, wer fragt und wo
   („im Chat“, „in Team“, „Aufgabe „…““); Antippen springt zur Karte im Chat. Dazu Rückfragen von Aufgaben mit
   „Antworten“ (öffnet die Aufgabe).
2. **Zum Prüfen:** Aufgaben im Status „Prüfen“ und Aufgaben mit Problem, als Board-Karten mit „Abhaken“, „Ablehnen“
   bzw. „Fortsetzen“. Antippen öffnet die Aufgabe.
3. **Läuft gerade:** Chat-Läufe mit ihrer letzten Statuszeile und laufende Aufgaben, jeweils mit Stopp.
4. **Heute geplant:** Routinen, Erinnerungen und geplante Aufgaben, die heute noch laufen, mit Uhrzeit und Scoop.
5. **Seit gestern erledigt:** abgenommene Aufgaben und gelaufene Routinen der letzten 24 Stunden. War der letzte Besuch
   länger her, reicht der Abschnitt bis dorthin (höchstens 7 Tage) und heißt „Seit deinem letzten Besuch erledigt“; ein
   Punkt markiert, was seitdem dazugekommen ist. Darüber Chats mit ungelesenen Nachrichten.

## Der Zähler

Am Eintrag „Heute“ steht, was auf den Nutzer wartet: **offene Freigaben + Rückfragen von Aufgaben**. Das ist genau die
Zahl der Einträge unter „Wartet auf dich“. Der Zähler am App-Symbol bleibt, was er war: Chats mit Ungelesenem, ohne
stumme Chats ([ruhe.md](ruhe.md); App und Server zählen gleich).

**Stumme Chats:** Ihre Freigaben stehen wie alle anderen unter „Wartet auf dich“ und zählen am Eintrag „Heute“ mit
(Freigaben kommen auch als Mitteilung trotz Stummschaltung durch). Unter „Seit gestern erledigt“ stehen ungelesene stumme
Chats hinter den anderen, mit durchgestrichener Glocke und grauem Zähler wie in der Seitenleiste.

„Offen“ ist eine Freigabe wie beim roten „?“ am Scoop: Karte unentschieden und jünger als 48 Stunden; hält eine Aufgabe
wegen der Karte an, ohne Frist. Damit die Zahl immer stimmt:

- **Entscheidung, auch auf einem anderen Gerät, an der Mitteilung oder auf der Watch:** `message.updated` mit dem neuen
  Zustand. Die Karte zählt sofort nicht mehr, zeigt noch kurz das Ergebnis und verschwindet dann.
- **Neue Karte:** `message.created`, der Chat muss dafür nicht geladen sein. Aufgabe und Frist holt ein Abgleich kurz danach.
- **Ablauf:** Jede Karte trägt ihre Frist (`expires_at`); die App blendet sie zum Zeitpunkt aus. Abgelaufene
  Computer-Use-Karten meldet der Server als abgelehnt.
- **Scoop oder Gruppe gelöscht:** `bot.deleted`/`group.deleted` entfernen alles dazu sofort.
- **Nachricht bearbeitet** ([suche-chat.md](suche-chat.md)): `message.deleted` entfernt eine verworfene Karte bzw.
  laufende Statuskarte sofort. Freigabe-Karten verwirft das Bearbeiten nie (dann gilt „Korrektur“), es bleiben also
  keine verwaisten Karten im Postfach. **Verlauf geleert:** Der
  Server setzt die offenen Freigaben des Chats auf abgelehnt und meldet `waiting: false`; die App gleicht dann ab.
- **Rückfall:** Abgleich nach jedem (Neu-)Verbinden, beim Öffnen der Seite, beim Zurückkehren in die App und jede
  Minute, solange die Seite sichtbar ist. Meldet ein Scoop „wartet“ (rotes „?“), ohne dass die Seite die Karte kennt,
  gleicht sie ebenfalls ab.

## Demo-Modus

`-mock` zeigt die offenen Freigaben der Demo-Chats, die Aufgaben des Demo-Boards, Milas laufende Recherche und
Beispiel-Routinen. Startargumente: `-heute` öffnet die Seite (iPhone), `-heuteleer` zeigt sie ohne Inhalt.
