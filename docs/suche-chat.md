# Suche und Chat-Komfort (App 1.3)

Vier Funktionen rund um den Chat: Suche über alle Chats, Zum-Ende-Knopf, eigene Nachricht bearbeiten, Link-Vorschauen.
Server: `Server/src/aisbot/suche.py`, `Server/src/aisbot/chat_edit.py`, Endpunkte in `server.py`. App:
`App/AISBot/Search/`. Tests: `Server/tests/test_suche.py`, `Server/tests/test_chat_edit.py`.

Ob ein Server das kann, meldet `GET /api/health` mit `"search": true` und `"message_edit": true` (für Gäste dieselben
Felder in `GET /api/shared/me`, weil sie `/api/health` nicht abfragen dürfen). Fehlen die Felder, sucht die App nur in
geladenen Nachrichten und bietet statt „Bearbeiten“ nur „Erneut senden …“ an.

## Suche über alle Chats

### Index

Eigene FTS5-Tabelle `message_fts` (eine Spalte `text`, Zeilen-ID = `messages.seq`). Der bisherige Index `search_fts`
bleibt, wie er ist: Ihn nutzen die Scoops für `erinnerung_suchen` (Gedächtnis-Einträge, Nachrichten mit Namen davor).

| Thema | Umsetzung |
|---|---|
| Inhalt | `user`, `bot`, `event` (Text der Zeile) und `approval` (Titel und Details der Karte), aus Einzel- und Gruppenchats. Statuszeilen (Arbeitsschritte) nicht, auch nicht der interne Auftrag eines Ereignisses (`meta.prompt`). |
| Aktuell halten | Drei Trigger an `messages` (Einfügen, Ändern von `text`/`meta`, Löschen). Damit ist der Index unabhängig davon, welcher Code eine Nachricht schreibt oder löscht (auch Chat zurücksetzen und Scoop löschen). Reaktionen und Zustandswechsel ändern den Index nicht. |
| Bestehende Datenbanken | `suche.ensure(db)` läuft beim Start: legt Tabelle und Trigger an und baut den Index einmal aus allen Nachrichten auf. Später nur noch, wenn sich die Fassung (`suche.VERSION`) ändert oder Zeilen fehlen (z. B. Datenbank aus einer älteren Sicherung). Dauer steht im Protokoll („Suchindex (trigram) aufgebaut: …“). |
| Teilwörter | Tokenizer `trigram` mit `remove_diacritics`: „rechn“ findet „Rechnung“ und „Reisekostenabrechnung“, Groß-/Kleinschreibung und Umlaute/Akzente sind egal („buro“ findet „Büro“). |
| Ältere SQLite | Ohne `trigram` fällt der Index auf `unicode61` mit Präfixen zurück (Wortanfänge: „rechn“ findet „Rechnung“, nicht „Abrechnung“). Ganz ohne FTS5 sieht die Suche die jüngsten 4000 Nachrichten der Reihe nach durch. `index` in der Antwort nennt die Art. |
| Eingabe | Jedes Wort wird als Zeichenkette in Anführungszeichen gesucht, alle Wörter müssen in derselben Nachricht stehen. Sonderzeichen (`"`, `*`, `(`, `AND`, `NEAR` …) lösen deshalb keinen FTS-Fehler aus. Wörter mit ein bis zwei Zeichen kann der Trigram-Index nicht prüfen; sie werden an den Kandidaten nachgeprüft. Unter zwei Zeichen insgesamt: keine Treffer. |

### `GET /api/search?q=…&limit=30&chat=<chat_id>&before=<message_id>`

Treffer neueste zuerst. `limit` 1–200. `chat`: nur dieser Chat (unbekannt → 404). `before`: nur Nachrichten vor dieser
(Blättern).

```json
{"query": "rechn",
 "hits": [{"message_id": "m_9f2c", "chat_id": "g_1a2b", "chat_kind": "group", "chat_name": "Team",
           "role": "bot", "author_id": "b_77aa", "author_name": "Lio", "created_at": "2026-11-19T10:12:00+01:00",
           "snippet": "Ich habe die Reisekostenabrechnung vorbereitet.", "marks": [[26, 31]]}],
 "total": 12, "truncated": false, "index": "trigram"}
```

- `role`: `user` | `bot` | `event` | `approval`. `author_id`: Scoop-ID, bei Personen die Konto-ID (fehlt ohne Konto).
- `snippet`: eine Zeile ohne Markdown rund um die erste Fundstelle (höchstens etwa 150 Zeichen, „…“ an gekürzten Enden).
  `marks`: markierte Bereiche im Ausschnitt als `[start, ende)` in Unicode-Codepoints.
- `total`: alle Treffer, `truncated`: es gibt mehr als mitgeschickt.

**Gäste geteilter Scoops** (`shared(via="any")`): nur Nachrichten der mit ihnen geteilten Scoops, keine Gruppen, keine
Freigabe-Karten (deren Inhalt sehen sie auch im Chat nicht). `chat=<nicht geteilt>` → 403. Auch `total` zählt nur das.

### Zur Fundstelle springen

- `GET /api/chats/{chat_id}/messages/around/{message_id}?before=25&after=25` →
  `{"messages": [Message …], "has_older": true, "has_newer": true}` (aufsteigend, je höchstens 100 davor/danach;
  Nachricht nicht in diesem Chat → 404). Gäste: Rolle „Lesen“ am Scoop, Nachrichten in der Gast-Ansicht.
- `GET /api/bots/{id}/messages?after=<message_id>&limit=50` (ebenso `/api/groups/{id}/messages`): die nächsten Nachrichten
  nach dieser, aufsteigend. Ohne `after` unverändert.

### App

- **Befehlspalette (⌘K):** Abschnitt „Nachrichten“ kommt von der Serversuche. Eingabe wird 260 ms entprellt, Antworten
  auf überholte Eingaben werden verworfen (`MessageSearchModel`). Zustände: Ladezeile „Sucht in allen Chats …“, Treffer,
  „Nichts gefunden“. Älterer Server oder offline: Abschnitt „Nachrichten in geladenen Chats“ wie bisher.
- **Seitenleiste:** Das Suchfeld filtert die Scoops und zeigt darunter „Nachrichten“ mit Treffern aus allen Chats. Auf
  dem iPhone steht das Feld immer über der Chatliste (vorher nur hinter der Lupe), auf iPad und Mac über die Lupe bzw.
  ⇧⌘F.
- **Treffer öffnen:** `AppStore.openSearchHit` stellt den Verlauf bereit, öffnet den Chat, setzt die Nachricht in die
  Mitte und hinterlegt sie kurz. Ist sie nicht geladen: bei offenem Chat erst bis zu zwei ältere Seiten, sonst gezielt
  der Ausschnitt rund um die Nachricht (`around`). Liegen dahinter neuere Nachrichten, zeigt der Chat nur diesen
  Ausschnitt (`detachedChats`): am Ende steht „Neuere Nachrichten laden“, der Zum-Ende-Knopf lädt die jüngsten
  Nachrichten. Neues vom Server erscheint im Ausschnitt nicht; Senden kehrt erst ans Ende zurück. Beim Verlassen des
  Chats wird der Ausschnitt verworfen.
- **Suche im Chat:** Lupe im Chat-Kopf (iPhone/iPad: Navigationsleiste, Mac: neben „Profil einblenden“) bzw. ⌘F. Auf dem
  iPhone stehen im Chat-Kopf seitdem Lupe, „Aufgaben“ und ein Drei-Punkte-Menü mit „Neu“, „Apps verbinden“ und
  „Befehle …“ (`SystemBarItems.collapseActions`), sonst bliebe vom Namen des Chats nur „…“; „Aufgaben“ bleibt so mit
  einem Tipp erreichbar. In der Chatliste ist alles unverändert. Leiste
  unter dem Chat-Kopf mit Feld, „3 von 12“, älterer/neuerer Treffer, Schließen. Return = älterer Treffer, ⇧Return =
  neuerer, Esc = schließen, am Mac auch ⌘G / ⇧⌘G. Bis 200 Treffer („200+“). Der aktuelle Treffer bleibt hinterlegt.
- **Tastenkürzel am Mac:** ⌘F sucht im sichtbaren Bereich: im geöffneten Chat im Verlauf, im Aufgaben-Board in den
  Aufgaben, sonst (Seite „Heute“, kein Chat) in der Seitenleiste. ⇧⌘F ist immer „Scoops und Nachrichten suchen“.
- **Treffer gelöschter Chats** (Scoop gelöscht, Freigabe entzogen) zeigt die App nicht mehr; der Server entfernt die
  Nachrichten ohnehin aus dem Index (Trigger). Importierte Vorlagen und Sendungen aus dem Teilen-Menü sind normale
  Nachrichten und damit sofort auffindbar.

## Zum-Ende-Knopf

Runder Glas-Knopf unten rechts im Verlauf. Er erscheint, sobald man mehr als 260 pt vom Ende weggescrollt hat (oder in
einem Ausschnitt steht), und springt ans Ende. Kommen währenddessen neue Nachrichten (Scoop, Freigabe, andere Person),
bleibt der Verlauf stehen und der Knopf zeigt ihre Anzahl. Steht man am Ende, rückt der Verlauf wie bisher nach; eigene
Nachrichten rücken immer nach. Der Knopf liegt im Verlauf, also immer über Eingabefeld, Anhängen, Antwort-Leiste und
Tastatur. Nur eine Bewegung (Finger, Mausrad, Sprung zu einer Nachricht) gilt als „weggescrollt“; wächst der Inhalt in
Ruhe, bleibt der Verlauf am Ende.

## Eigene Nachricht bearbeiten

### `PATCH /api/messages/{message_id}` `{"text": "…"}` → `Message`

Nur die **jüngste eigene** Nachricht eines Chats (Admin: nicht die eines Gasts; Gast mit Rolle „Schreiben“: nur eigene).
Der Server hält einen laufenden Chat-Lauf an (Hintergrund-Aufgaben laufen weiter), ersetzt den Text sofort und setzt
`meta.edited = {"at": "<iso>", "mode": "replaced" | "corrected"}`. `mode` fehlt, solange der Lauf noch anhält; der
Endpunkt wartet darauf höchstens 6 s, danach kommt der Rest per WebSocket. Anhänge (`meta.file_ids`) bleiben.

| Fehler | Wann |
|---|---|
| 400 | leerer Text (und keine Anhänge) |
| 403 | fremde Nachricht, Rolle „Lesen“ |
| 404 | unbekannt oder keine Nutzernachricht |
| 409 | nicht die jüngste eigene Nachricht; `/aufgabe …`; im Live-Sprechmodus gesprochen |

**Neu antworten (`replaced`).** Alles nach der Nachricht wird verworfen (`message.deleted` je Nachricht), danach
antwortet der Scoop auf die neue Fassung. Bedingung: Die alte Fassung hat nichts ausgelöst. Erlaubt sind nach der
Nachricht nur Antworten und Arbeitsschritte von Läufen mit `effects = false`, „Angehalten“ und Abo-Hinweise.

| Engine | Zurücksetzen |
|---|---|
| Claude- und OpenAI-API | Der Verlauf entsteht bei jedem Lauf aus der Datenbank. Dazu wird der gespeicherte Stand für „mach weiter“ verworfen. |
| Claude Code, Codex (KI-Abo) | Die Sitzung des Chats wird verworfen (`abo_sessions`). Der nächste Lauf beginnt eine neue und bekommt den sichtbaren Verlauf als Mitschrift, wie nach einer verlorenen Sitzung. |
| Gruppen | wie oben für alle Mitglieder; danach wird mit der neuen Fassung neu verteilt, wer antwortet. |

Außerdem verschwinden der Tagebuch-Eintrag der verworfenen Antwort und Reaktionen der Scoops auf die alte Fassung.

**Korrektur (`corrected`).** Sobald nach der Nachricht etwas anderes steht (Freigabe-Karte, Ereignis wie Routine, Datei
oder Übergabe, Aufgabe, Nachricht einer anderen Person, ein Lauf mit Wirkung oder ohne `effects`-Angabe), wird nichts
gelöscht und nichts zurückgenommen. Im Chat erscheint das Ereignis „Nachricht bearbeitet“ (`meta.icon = "pencil"`,
`meta.edit_of`), und der Scoop bekommt alte und neue Fassung als Auftrag: auf die korrigierte Fassung antworten, nichts
stillschweigend rückgängig machen, nichts doppelt ausführen. In Gruppen antworten die Scoops, die auf die alte Fassung
geantwortet haben.

**`effects`.** Jeder Chat-Lauf vermerkt, ob er etwas bewirkt haben kann: `meta.effects` in der Statuszeile und
`meta.run_info.effects` in der Antwort. `false` nur, wenn ausschließlich gelesen wurde: Websuche, Lesen im Abo-Weg,
Werkzeugsuche und die lesenden eigenen Werkzeuge (`chat_edit.READONLY_TOOLS`). Jedes andere eigene Werkzeug, jeder
Aufruf einer verbundenen App, der Rechner und jeder unbekannte Arbeitsschritt zählen als Wirkung. Läufe älterer Server
tragen das Feld nicht und führen deshalb immer zur Korrektur.

**WebSocket:** neu `message.deleted` mit `{"id": "m_…", "bot_id": "<chat_id>"}` (auch an Gäste des Scoops). Ältere
Apps ignorieren das Ereignis und zeigen die verworfene Antwort bis zum nächsten Laden.

### App

- Kontextmenü an eigenen Nachrichten (Mac: Rechtsklick, iPhone/iPad: langes Drücken, VoiceOver-Aktion): an der jüngsten
  „Bearbeiten“, an älteren „Erneut senden …“ (auch wenn der Server nicht bearbeiten kann, bei Aufgaben und im
  Ausschnitt).
- „Bearbeiten“: Text wandert ins Eingabefeld, darüber der Chip „Nachricht bearbeiten“ mit dem bisherigen Text und
  Abbrechen (auch Esc). Der Senden-Knopf zeigt einen Haken. Was vorher im Feld stand, kommt danach zurück.
- „Erneut senden …“: Text ins Eingabefeld, geht als neue Nachricht raus, der Verlauf bleibt unverändert.
- Bearbeitete Nachrichten tragen „Bearbeitet“ unter der Blase.

## Link-Vorschauen

Unter Nachrichten von dir und von Scoops erscheint für den **ersten** Link eine Karte mit Bild (oder Symbol), Titel und
Domain. Tippen öffnet den Link. Umsetzung nur auf dem Gerät mit LinkPresentation (`LPMetadataProvider`, Zeitlimit 8 s),
der Server ist nicht beteiligt (`App/AISBot/Search/LinkPreviews.swift`).

- **Keine Vorschau:** Links in Codeblöcken und Inline-Code, Freigabe-Karten, sowie lokale und private Adressen:
  `localhost`, Namen ohne Punkt, `.local`, `.ts.net`, `.internal`, `.lan`, `.home.arpa`, IPv4 in 10.x, 127.x, 192.168.x,
  172.16–31.x, 169.254.x, 100.64–127.x (Tailscale) und alle IPv6-Literale. Ist der erste Link so eine Adresse, gibt es
  für die Nachricht keine Vorschau.
- **Zwischenspeicher:** Arbeitsspeicher und Datei (`Caches/<Bundle-ID>/LinkVorschauen/`, JSON plus verkleinertes Bild,
  320 px). Erfolg gilt 14 Tage, Fehlschlag 6 Stunden. Ein Abruf pro Adresse, auch bei mehreren Zeilen gleichzeitig.
- **Kein Springen:** Die Karte hat von Anfang an ihre feste Höhe (68 pt) und zeigt zuerst Domain und Pfad; Titel und
  Bild füllen später dieselbe Fläche. Die Zeilenhöhe ändert sich nicht, die Scrollposition bleibt.
- **Einstellungen → Chat → „Link-Vorschauen“**, Standard an (`UserDefaults` `linkPreviews`).
- Demo-Modus: feste Vorschauen für die Beispiel-Links (`DemoLinkPreviews`), andere Links ruft auch die Demo ab.

## Demo-Modus und Startargumente

Mit `-mock` funktionieren alle vier Funktionen ohne Server (`MockService` als `ChatComfortService`): Suche über die
Demodaten (auch im geteilten Scoop Juna), Ausschnitt und Nachladen, Bearbeiten mit beiden Wegen (im Chat von Lio steht
nach der jüngsten Nachricht eine Freigabe-Karte, dort greift die Korrektur).

| Argument | Wirkung |
|---|---|
| `-longchat [n]` | hängt `n` (Standard 320) ältere Nachrichten vor Pips Chat; die Fundstelle „Lavendelhonig“ liegt weit vor dem Ende |
| `-incoming <chat-id> [sekunden]` | nach der Wartezeit treffen drei Nachrichten ein (Zähler am Zum-Ende-Knopf) |
| `-oldserver` | Demo-Server meldet keine Fähigkeiten: lokale Suche, nur „Erneut senden …“ |
| `-scrolllog` | nur Debug: protokolliert auch „far from end“ und „new last“ (Kategorie `scroll`) |
