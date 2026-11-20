# Systemintegration (App 1.3)

Teilen-Menü, Kurzbefehle und Siri, Kontrollzentrum, Action-Button und Spotlight. Alles läuft mit dem bestehenden
Server: Es gibt keine neuen Endpunkte und keine neue Fähigkeit in `/api/health`. Benutzt werden `POST …/messages`,
`POST /api/chats/{id}/files`, `POST /api/tasks` (vor Server 1.22 `POST /api/bots/{id}/tasks`) und
`GET …/messages`.

## Überblick

| Einstieg | Was passiert | Wo es läuft |
|---|---|---|
| Teilen-Menü „An Scoop senden“ | Text, Links, Bilder, PDFs und andere Dateien als normale Nachricht mit Anhängen | Erweiterung `AISBotShare` |
| Kurzbefehl „Scoop fragen“ | sendet eine Frage, wartet auf die Antwort, gibt sie als Text zurück | App (im Hintergrund) |
| Kurzbefehl „Nachricht an Scoop senden“ | sendet, ohne zu warten | App (im Hintergrund) |
| Kurzbefehl „Aufgabe anlegen“ | legt eine Aufgabe im Board an | App (im Hintergrund) |
| Kurzbefehl „Sprechmodus starten“ | öffnet die App im Sprechmodus | App (im Vordergrund) |
| Kurzbefehl „Chat öffnen“ | öffnet den Chat | App (im Vordergrund) |
| Controls „Sprechmodus“, „Scoop öffnen“, „Neue Nachricht“ | öffnen die App an der passenden Stelle | Widget-Erweiterung, Aktion in der App |
| Spotlight | Scoops und Gruppen finden, Tippen öffnet den Chat | App schreibt den Index |

## Grundlage: Zugang aus Erweiterungen

### Was in der App-Gruppe liegt (ohne Zugangsdaten)

Die App schreibt bei jeder Änderung `system-directory.json` in die App-Gruppe (`SystemDirectory`, geschrieben von
`SystemSync`): die Chats (Scoops, Gruppen, mit mir geteilte Scoops) mit Name, Rolle, Aussehen, Haupt-Scoop,
Schreibrecht und dem **Server, zu dem der Chat gehört**, dazu die Adressen der Server. Keine Token, keine
Nachrichten.

- **Ein Scoop gehört zu genau einem Server.** Eigene Scoops und Gruppen gehören zum verbundenen Server
  (`activeServerID`: Convex-ID, `manual` bei Verbindung per API-Token, `demo` im Demo-Modus). Geteilte Scoops
  gehören zum Server ihres Admins. Erweiterungen sprechen immer den Server des gewählten Chats an.
- Wechselt man den Server, schreibt die App das Verzeichnis neu: Die Chats des alten Servers verschwinden aus
  Kurzbefehlen, Controls und Spotlight.
- Solange die Chats noch nicht geladen sind (Start, Verbindungsaufbau, Server antwortet nicht, Hintergrundstart
  für einen Kurzbefehl), bleibt der letzte Stand stehen. Geleert wird erst beim Trennen, Abmelden oder Serverwechsel.
- Daneben liegen vorgerenderte Chat-Bilder (`SystemAvatars/<chat-id>.png`) für Kurzbefehle, Siri und Spotlight
  sowie „zuletzt benutzt“ (UserDefaults der App-Gruppe) für die Reihenfolge im Teilen-Menü.

### Zugangsdaten: Schlüsselbund-Zugriffsgruppe

API-Token und Konto-Sitzung liegen weiter nur im Schlüsselbund (`SharedKeychain`, Dienst `com.ais.aisbot`, Konten
`token` und `cloud-session`, lesbar nach dem ersten Entsperren).

- **iPhone und iPad:** eigene Zugriffsgruppe `$(AppIdentifierPrefix)com.ais.aisbot.shared`
  (`keychain-access-groups`). Nur die App und die Teilen-Erweiterung tragen sie. Widgets und die
  Mitteilungs-Erweiterung kommen nicht an die Zugangsdaten; sie brauchen sie auch nicht.
- **Migration:** Ältere Versionen haben in der Standardgruppe der App gespeichert. Beim Start zieht die App die
  Einträge um (`SharedKeychain.migrate`). Gelesen wird zuerst aus der gemeinsamen Gruppe, sonst aus jeder Gruppe,
  die die App sehen darf: Die Anmeldung bleibt also auch erhalten, wenn der Umzug einmal nicht klappt. Schlägt
  das Schreiben in die Gruppe fehl, landet der Wert wie bisher im Schlüsselbund der App. Test im Simulator:
  Startargument `-keychainselftest` (nur Debug) schreibt eine Zeile `[System] Schlüsselbund-Test: bestanden (6 Fälle,
  Team-Präfix aus der Info.plist)`. Geprüft werden: alter Eintrag vor dem Umzug lesbar, Umzug mit Wert und
  Zugriffsklasse („nach dem ersten Entsperren“), zweiter Umzug ohne Wirkung, neue Kopie gewinnt gegen eine alte,
  Schreiben räumt eine alte Kopie weg, Löschen (Abmelden) entfernt alles.
- **Team-Präfix:** Die Gruppe heißt `<Präfix>com.ais.aisbot.shared`. Das Präfix liest `SharedKeychain` zur Laufzeit aus
  der Info.plist von App und Teilen-Erweiterung (Schlüssel `AppIdentifierPrefix` = `$(AppIdentifierPrefix)`, beim Bauen
  eingesetzt), damit ein Build mit eigenem Team seine eigene Gruppe benutzt. Fehlt der Eintrag oder ist er nicht
  eingesetzt, gilt wie bisher `MYXQKK3T2Z.`. Für bestehende Nutzer ändert sich nichts (gleiches Team, gleiche Gruppe).
- **Erster Start vor dem ersten Entsperren:** Startet iOS die App nach einem Neustart im Hintergrund (Ort, Push für den
  Gerätekanal), sind die Einträge („nach dem ersten Entsperren“) noch nicht lesbar. Der Umzug tut dann nichts und
  löscht nichts. Die App liest die Anmeldung beim ersten Entsperren nach (`protectedDataDidBecomeAvailable`), statt bis
  zum nächsten Neustart abgemeldet zu wirken.
- **Mac:** unverändert der bisherige Schlüsselbund der App, ohne Zugriffsgruppe. Eine Zugriffsgruppe verlangt auf
  dem Mac ein Provisioning-Profil für jedes Target. Die Mac-Erweiterung braucht keine Zugangsdaten (siehe unten).
- **Konto-Sitzung:** In den Schlüsselbund schreibt nur die App. Die Erweiterung benutzt das gespeicherte
  Sitzungs-JWT. Ist es abgelaufen, erneuert sie es nur für sich im Speicher (`POST <site>/auth/refresh`, vergibt
  kein neues Refresh-Token, siehe [accounts.md](accounts.md)). Klappt auch das nicht, legt sie die Sendung ab.

### Der schlanke Client

`SystemAccess.service(for:)` liefert für einen Chat den passenden Dienst (`SystemService`: senden, Datei
hochladen, Aufgabe anlegen, neueste Nachrichten lesen):

1. Läuft die App und kennt sie den Chat, nimmt der Intent ihre Verbindung (`StoreSystemService`): gleiche Anmeldung,
   auch Demo-Modus und Gast-Verbindungen, und der Chat zeigt die Nachricht sofort.
2. Sonst spricht `RemoteSystemService` selbst per URLSession mit dem Server des Chats. Dateien werden von der
   Platte gestreamt (`upload(for:fromFile:)`). Schreibende Anfragen gehen nur dann an die zweite Adresse, wenn
   die erste den Server sicher nicht erreicht hat.
3. Lief die App zuletzt im Demo-Modus und kann sie gerade nicht selbst antworten, spielt `DemoSystemService`
   Senden und Antworten nach.

Dateien: `App/Shared/System/` (Verzeichnis, Client, Schlüsselbund, Ablage, Links), `App/Shared/Intents/`
(Entitäten und die Intents, die die App öffnen), `App/AISBot/System/` (Abgleich, Router, Spotlight, Nachsenden,
Kurzbefehle), `App/AISBotShare/` (Erweiterung), `App/AISBotWidgets/ScoopControls.swift` (Controls).

## Teilen-Menü „An Scoop senden“

Erweiterung `AISBotShare` (`com.ais.aisbot.share`) für iPhone, iPad und Mac. Nimmt Text, Links, Webseiten, Bilder,
Videos, PDFs und andere Dateien an, auch mehrere auf einmal (bis 20). Die Aktivierungsregel ist ein Prädikat
(alle Anhänge sind `public.data`): Die einfachen Schlüssel decken z. B. eine in Safari geöffnete PDF nicht ab.
Gibt eine App zu einer Datei auch ihre Adresse mit (Safari bei PDFs), kommen Datei und Link an.

**Ablauf:** Inhalt prüfen (Karte oben), Scoop oder Gruppe wählen, optional eine Notiz, „An … senden“.
- Zur Wahl stehen alle Chats, in denen man schreiben darf (geteilte Scoops mit Rolle „Lesen“ fehlen). Reihenfolge:
  zuletzt über das System benutzte zuerst, dann nach letzter Aktivität. Figuren und eigene Fotos wie in der App.
- Die Nachricht besteht aus Notiz, geteiltem Text und Links (Seitentitel plus Adresse). Dateien hängen als
  Anhänge daran. Der Scoop antwortet wie auf jede andere Nachricht im Chat.
- Rückmeldung: Fortschrittsbalken über alle Dateien, „An … gesendet“, „Abgelegt, nichts geht verloren“ oder eine
  Fehlermeldung mit „Zurück“ (anderer Scoop, erneut senden) und „Verwerfen“.

**Speicher:** Erweiterungen haben wenig Speicher. Dateien werden deshalb nie als Ganzes geladen: `NSItemProvider`
liefert eine Datei, die sofort in den Ordner der Sendung kopiert wird. Bilder über 6 MB, mit mehr als 5120 Pixeln
Kantenlänge oder in Formaten, die Scoops nicht lesen (HEIC, RAW, TIFF), werden mit ImageIO auf höchstens 2560
Pixel verkleinert und als JPEG abgelegt. Dateien über 25 MB (Grenze des Servers) werden mit Hinweis ausgelassen.

**Ablage (`ShareOutbox`):** Jede Sendung liegt zuerst als Ordner in der App-Gruppe (`ShareOutbox/<id>/` mit
`item.json` und den Dateien). Von dort sendet die Erweiterung.
- Server nicht erreichbar, Anmeldung abgelaufen oder Serverfehler (5xx): Die Sendung bleibt als `queued` liegen.
  Die App sendet sie nach, sobald sie geöffnet wird bzw. der Server wieder antwortet, und meldet „Geteilte Inhalte
  an … gesendet“. Solange etwas liegt, zeigt die App unten den Hinweis „Geteiltes für … wartet“ mit „Jetzt
  senden“ und „Verwerfen“.
- Schon hochgeladene Dateien merkt sich die Sendung (`fileID`), sie werden beim Nachsenden nicht doppelt geladen.
- Wird die Erweiterung mitten im Senden beendet, übernimmt die App nach 90 Sekunden ohne Lebenszeichen.
- Endgültige Fehler (kein Schreibrecht, Chat gelöscht, Datei zu groß) zeigt die Erweiterung sofort.
- Entwürfe, die nie abgeschickt wurden (Blatt weggewischt), werden nach einer Stunde gelöscht.

**Mac:** Die Erweiterung legt die Sendung immer ab und weckt die App (`aisbot://outbox`), die sofort sendet. Sie
selbst braucht weder Netz noch Zugangsdaten.

**Demo-Modus:** Die Erweiterung spielt das Senden nach und übergibt die Sendung still an die App; beim nächsten
Öffnen steht sie im Demo-Chat und der Demo-Scoop antwortet. Mit dem Startargument `-shareofflinedemo` (zusammen mit
`-mock`) gilt der Server als nicht erreichbar: So lassen sich Ablage und Nachsenden prüfen.

## Kurzbefehle und Siri

`ScoopShortcuts` (`AppShortcutsProvider`) meldet fünf Kurzbefehle an. Sie erscheinen ohne Einrichten in der
Kurzbefehle-App, in Spotlight und für Siri, jeweils mit den eigenen Scoops als Auswahl.

| Kurzbefehl | Parameter | Sätze (Beispiele) |
|---|---|---|
| Scoop fragen | Scoop oder Gruppe, Frage, Wartezeit (5–120 s, Standard 25) | „Frag Mila in AIS Scoops“ |
| Nachricht an Scoop senden | Chat, Nachricht | „Schreib Mila in AIS Scoops“ |
| Aufgabe anlegen | eigener Scoop, Titel, Beschreibung (optional) | „Neue Aufgabe für Theo in AIS Scoops“ |
| Sprechmodus starten | Scoop (optional) | „Sprich mit Mila in AIS Scoops“, „AIS Scoops Sprechmodus“ |
| Chat öffnen | Chat (optional), Neue Nachricht | „Öffne Launch-Team in AIS Scoops“ |

- **Scoop fragen** sendet die Frage und fragt den Chat etwa jede Sekunde ab, bis die Antwort des Scoops da ist.
  Ergebnis ist die Antwort als Text ohne Markdown (zum Vorlesen und zur Weiterverwendung im Kurzbefehl). Dauert es
  länger als die Wartezeit, steht im Ergebnis „… arbeitet noch daran. Die Antwort findest du gleich im Chat.“
  Braucht der Scoop eine Freigabe, steht dort „… braucht deine Freigabe: <Titel>“. Die Antwort kommt in beiden
  Fällen normal im Chat an. Siri selbst wartet höchstens rund 30 Sekunden.
- **Nachricht senden:** Ist der Server nicht erreichbar, landet die Nachricht in der Ablage und die App sendet sie
  beim nächsten Öffnen; der Kurzbefehl sagt das.
- **Aufgabe anlegen:** `POST /api/tasks` mit Titel und Auftrag (Beschreibung, sonst der Titel). Nur eigene Scoops:
  Das Board gibt es nur auf dem eigenen Server, und in Gruppen braucht eine Aufgabe einen Akteur.
- Die drei schreibenden Kurzbefehle verlangen ein entsperrtes Gerät (`authenticationPolicy`).
- **Entitäten:** `ChatEntity` (Scoop, geteilter Scoop oder Gruppe) für Kurzbefehle, Siri und Spotlight; welche Chats
  ein Kurzbefehl anbietet, legt sein `optionsProvider` fest. `ScoopEntity` (eigener Scoop) bleibt die Auswahl der
  Widgets und Controls; der Typ ist aus dem Widget-Target nach `App/Shared/Intents` gezogen, bestehende
  Widget-Einstellungen gelten weiter.

## Kontrollzentrum, Sperrbildschirm, Action-Button

Drei `ControlWidget`s in der Widget-Erweiterung (iPhone, iPad, Mac):

| Control | Einstellung | Wirkung |
|---|---|---|
| Sprechmodus | Scoop (ohne Auswahl: Haupt-Scoop) | öffnet die App im Sprechmodus |
| Scoop öffnen | Chat (Scoop oder Gruppe) | öffnet den Chat |
| Neue Nachricht | Scoop (ohne Auswahl: Haupt-Scoop) | öffnet den Chat mit aktivem Eingabefeld |

Alle drei öffnen die App. Vom Sperrbildschirm und über den Action-Button verlangt das System dafür zuerst Face ID
bzw. den Code; die Controls selbst zeigen nur den Namen des gewählten Scoops, nichts aus dem Chat. Die Auswahl der
Controls „Sprechmodus“ und „Neue Nachricht“ bietet eigene Scoops an, „Scoop öffnen“ auch Gruppen und geteilte
Scoops.

## Spotlight

`SpotlightIndexer` trägt jeden Chat des Verzeichnisses in die Systemsuche ein: Name, Unterzeile (Rolle, bei
Gruppen die Mitglieder, bei geteilten Scoops der Admin) und Bild. Nachrichten werden nicht indexiert.
- Abgleich bei jeder Änderung des Verzeichnisses: neue und geänderte Einträge schreiben, entfernte löschen. Beim
  Abmelden, Trennen oder Serverwechsel wird der Index geleert bzw. ersetzt.
- Jeder Treffer ist mit der `ChatEntity` verknüpft. Tippen öffnet den Chat (`OpenChatEntityIntent` bzw.
  `CSSearchableItemActionType`).

## Tiefe Links (`aisbot://`)

| Link | Wirkung |
|---|---|
| `aisbot://chat/<id>` (auch `bot/…`, `group/…`) | Chat öffnen |
| `aisbot://chat/<id>?compose=1`, `aisbot://compose[/<id>]` | Chat öffnen, Eingabefeld aktiv |
| `aisbot://voice[/<id>]` | Sprechmodus, ohne ID mit dem Haupt-Scoop |
| `aisbot://today` | Seite „Heute“ |
| `aisbot://outbox` | abgelegte Sendungen jetzt senden |
| `aisbot://pair?…`, `aisbot://usage/…` | wie bisher (Kopplung, Nutzung) |

`?server=<id>` nennt den Server des Chats. Gehört ein Link zu einem anderen als dem verbundenen Server, sagt die App
das („Dieser Scoop gehört zu einem anderen Server“), statt einen falschen Chat zu öffnen.

`DeepLinkRouter` wertet die Links aus. Kommt ein Link, bevor der Chat geladen ist (Kaltstart, Verbindungsaufbau,
noch kein Server verbunden, Einführung offen), merkt der Router ihn bis zu zehn Minuten vor und löst ihn ein, sobald
der Chat da ist.

**„Heute“:** Die Seite ([heute.md](heute.md)) hängt sich in `AISBotApp` ein (`DeepLinkRouter.shared.openToday`). Beim
Kaltstart wartet der Router, bis die Verbindung steht und damit klar ist, ob der Server die Seite kennt. Ältere Server
und reine Gast-Verbindungen haben keine Seite „Heute“: Dann kommt nur die App nach vorn.

## Signierung

Neu im Projekt (`App/project.yml`):

| Was | Wert |
|---|---|
| Target und Bundle-ID | `AISBotShare`, `com.ais.aisbot.share` (iOS und macOS), eingebettet in `AISBot` |
| App-Gruppe der Erweiterung | iOS `group.com.ais.aisbot`, macOS `MYXQKK3T2Z.com.ais.aisbot` (beide bestehen schon) |
| Schlüsselbund-Gruppe | `$(AppIdentifierPrefix)com.ais.aisbot.shared` in App und Teilen-Erweiterung, nur iOS |

Im Entwicklerportal bzw. beim ersten Archiv:
1. App-ID `com.ais.aisbot.share` anlegen (iOS und macOS) mit der Fähigkeit „App Groups“ und der Gruppe
   `group.com.ais.aisbot`. Automatisches Signieren mit `-allowProvisioningUpdates` legt die App-ID an. Die Zuordnung
   der App-Gruppe gelingt mit dem API-Schlüssel erfahrungsgemäß nicht (siehe `App/README.md`, Abschnitt Release):
   einmal im Portal setzen oder einmal mit dem in Xcode angemeldeten Konto archivieren.
2. „Keychain Sharing“ braucht keine Registrierung: Die Profile erlauben jede Gruppe mit dem Team-Präfix.
3. Für den Mac braucht die Erweiterung ein eigenes Profil (Mac App Store), aber keine weitere Fähigkeit.
4. `App/scripts/upload-testflight.sh` und die `ExportOptions` bleiben unverändert (automatisches Signieren, das neue
   Target hängt am Schema `AISBot`). Xcode Cloud braucht nach dem Anlegen der App-ID nichts weiter.

## Getestet

Simulator iPhone 17 (iOS 27.2), Demo-Modus und eine Server-Attrappe auf `127.0.0.1` (echter Netzweg der
Erweiterung): Teilen aus Safari (Link mit Notiz, PDF) und Fotos (mehrere Bilder, auch an eine Gruppe), Ablage und Nachsenden
mit Hinweis, alle fünf Kurzbefehle in der Kurzbefehle-App („Scoop fragen“, „Nachricht senden“ und „Aufgabe anlegen“
ausgeführt, „Nachricht senden“ auch bei beendeter App), die Controls in der Galerie des Kontrollzentrums samt Start
des Sprechmodus, Spotlight-Treffer mit Öffnen des Chats, Links beim Kaltstart, Umzug der Schlüsselbund-Einträge.
Logik-Tests: `WatchLogicTests/SystemLinkTests.swift`.

Nicht im Simulator prüfbar: Siri (Sprache), der Action-Button, das Entsperren vom Sperrbildschirm aus und alles
auf dem Mac zur Laufzeit (Teilen-Erweiterung, Controls, Spotlight).
