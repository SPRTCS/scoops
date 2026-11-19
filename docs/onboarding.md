# Einführung in der App AIS Scoops

Stand: 17.11.2026 · App 1.1 (iPhone, iPad, Mac)

Neue Nutzer werden Schritt für Schritt vom ersten Start bis zur ersten Antwort ihres ersten eigenen Scoops begleitet.
Das Gegenstück auf dem Mac ist der Assistent von **AIS Scoops Server** (`App/ScoopsConnect/Server/ServerSetupView.swift`).
Begriffe in beiden Apps: „AIS Scoops“ (App), „AIS Scoops Server“ (Mac-App), „Server“, „Kopplungscode“, „Scoop“.

Quellen: `App/AISBot/Views/Onboarding/` (Oberfläche, Zustand), `App/Shared/Support/OnboardingLogic.swift` (reine Logik,
getestet in `App/WatchLogicTests/OnboardingLogicTests.swift`), Editor-Bausteine in
`App/AISBot/Views/Components/MascotPickers.swift`.

## Ablauf

| Schritt | Inhalt |
|---|---|
| 1 Willkommen | Drei kurze Seiten mit den Maskottchen: was Scoops sind, dass sie auf dem eigenen Mac wohnen, was jetzt kommt. „Überspringen“ führt zur Anmeldung. Auf der ersten Seite: **Erweitert: Manuell verbinden** und **Erst mal ohne Server ausprobieren**. |
| 2 Anmelden | „Mit Apple anmelden“ (bestehender Knopf). Angemeldet geht es von selbst weiter. Manuell verbinden und Demo stehen auch hier. |
| 3 Server | Gibt es schon Server im Konto: Liste „Deine Server“ zum Antippen. Sonst Anleitung: Mac mit Apple-Chip und macOS 26, „AIS Scoops Server“ laden (iPhone/iPad: **Link an meinen Mac senden** über das Teilen-Menü, dazu „Link kopieren“; Mac: direkt laden), Assistent zeigt im Schritt „Mit der App verbinden“ einen Kopplungscode. Danach Code eingeben → Warten, bis der Server online ist → automatisch verbinden. |
| 4 Erster Scoop | Geführte Erstellung in drei Teilen: Name (mit Vorschlägen), Aussehen (Figur, Farbe, Augen, Zufall), wofür er da ist (Alltag, Recherche, Schreiben, Planen, Lernen, Etwas anderes; setzt Label und Charakter). Modell: Standard des Servers. |
| 5 Erste Nachricht | Echter Verlauf mit denselben Zeilen wie im Chat, drei Startnachrichten passend zum Zweck, eigenes Eingabefeld. Die erste Antwort wird gefeiert (Konfetti, auf dem iPhone ein Erfolgs-Haptik). |
| Tipps | Einmalig: Scoops teilen (nur mit Konto), Widgets, Apple Watch (nur iPhone). Abschaltbar unter Einstellungen → Einführung. Danach öffnet sich der Chat mit dem neuen Scoop. |

Oben steht immer „Schritt x von 5“ mit Balken und ein Zurück-Knopf (Esc auf Mac/Tastatur). Zurück geht auch innerhalb
eines Schritts (Begrüßungsseiten, Code → Anleitung, Teile des Scoop-Editors; während des Verbindens bricht Zurück ab).
Im Scoop- und Nachrichten-Schritt beendet „Später“ die Einführung.

## Kopplung

**Unverändert** gegenüber vorher: Der Assistent auf dem Mac zeigt einen Kopplungscode (10 Minuten gültig), die App
löst ihn mit `servers:claimServer` ein (docs/accounts.md). „Deine Server → Server hinzufügen“ funktioniert wie bisher;
nur der veraltete Hinweis auf `bin/aisbot cloud-link` im Blatt wurde durch den Assistenten ersetzt.

Neu ist nur, was die App nach dem Einlösen tut (rein App-seitig, keine Server- oder Convex-Änderung):

1. Die Server-ID aus `claimServer` wird lokal gemerkt (`onboarding.pairing`), damit ein Neustart beim Warten weitermacht.
2. Alle 3 Sekunden `servers:myServers`. Sobald der Server `online` ist und eine Adresse hat (`publicUrl` oder
   `tailnetUrl`), verbindet die App wie beim Antippen in „Deine Server“.
3. Nach 45 Sekunden ohne Meldung: Hinweis „Läuft AIS Scoops Server?“ mit „Erneut prüfen“. Online ohne Adresse: Hinweis
   auf den Assistentenschritt „Von unterwegs erreichbar“.

Fehlerfälle: `invalid_code` → „Code abgelaufen oder ungültig“ mit Hinweis auf einen neuen Code im Assistenten;
`rate_limited` und andere Fehler mit der Meldung des Konto-Dienstes. Scheitert das Verbinden („Server nicht
erreichbar“), zeigt der Schritt die Meldung, Hinweise (Menüleisten-Symbol, Mac wach, gleiches WLAN oder Tailscale)
sowie „Erneut versuchen“ und „Anderen Server wählen“.

`CloudError` trägt dafür jetzt den fachlichen Code (`code`, z. B. `invalid_code`).

### Kopplungslink (neu)

`aisscoops://link?code=K7QX-29PL` (auch `aisbot://link?code=…`, Groß-/Kleinschreibung und Bindestrich egal) öffnet
den Code-Schritt mit vorausgefülltem Code. Gedacht für einen QR-Code neben dem Code im Mac-Assistenten (baut später
jemand anderes). Verhalten:

- Kein Server verbunden (Einführung oder „Anmelden und Server“): Code-Schritt; noch nicht angemeldet → erst Anmelden,
  der Code bleibt im Speicher und steht danach im Feld.
- Schon ein Server verbunden: Blatt „Server hinzufügen“ mit dem Code.
- Gekoppelt wird erst nach Tippen auf „Koppeln“, nie automatisch. Der Code wird nicht gespeichert.

Parser: `OnboardingLogic.pairingCode(from:)` (getestet), Einstieg `AppStore.openPairingLink` (vor den Einladungslinks
in `AISBotApp.handle`). Universal Link (`https://ais-con.com/s/<code>`) gibt es noch nicht.

App-Store-Adresse von AIS Scoops: `AISScoopsApp.appStoreURL` (`App/ScoopsConnect/Server/ServerSetupView.swift`),
`https://apps.apple.com/app/id6833654924`.

## Wer sieht die Einführung?

- **Bestandsnutzer nie.** Beim ersten Start dieser Version gilt: Gibt es eine gespeicherte Verbindung, ist die
  Einführung sofort erledigt (`OnboardingLogic.initialStep`). Arman und alle TestFlight-Nutzer mit Verbindung fallen
  also nicht hinein.
- Neu installiert, aber noch angemeldet (Sitzung im Schlüsselbund): Start direkt beim Server-Schritt.
- Verbindet sich jemand während der Einführung mit einem Server, der schon eigene Scoops oder Gruppen hat, endet sie
  sofort. Als „frisch“ gilt ein Server ohne Scoops oder nur mit dem automatisch angelegten Start-Scoop **Pip**
  (Label „Start“, letzte Nachricht ist seine Begrüßung; `seed_fresh_install` in `Server/src/aisbot/server.py`).
  Der in der Einführung erstellte Scoop zählt dabei nicht mit.
- Demo-Knopf und Manuell verbinden (App-Prüfung, `docs/demo-server.md`): Der Demo-Server hat eigene Scoops, also
  endet die Einführung direkt nach dem Verbinden – Prüfer landen wie bisher in der vollen App.
- Nur geteilte Scoops, kein eigener Server: Wie bisher die App mit „Mit mir geteilt“. Im Server-Schritt gibt es dafür
  „Ohne eigenen Server weiter“.
- Ist die Einführung erledigt und kein Server verbunden (abgemeldet, getrennt), zeigt die App nur Anmelden und Server
  (ohne Fortschrittsanzeige), wie der frühere Startbildschirm. Ebenso das Blatt „Server verbinden“ für Gäste.

## Gespeicherter Stand

UserDefaults der App, Schlüssel `onboarding.*`, ohne Geheimnisse: Schritt, Seite der Begrüßung, „erneut ansehen“,
ID des ersten Scoops, gefeiert, Tipps an/aus, gekoppelte Server-ID mit Zeitpunkt, Entwurf des ersten Scoops (Name,
Aussehen, Zweck, Charakter, Teilseite). Abbruch und Neustart setzen an derselben Stelle wieder ein. Der Kopplungscode
selbst wird nie gespeichert.

## Einstellungen

Einstellungen → **Einführung**: „Einführung erneut ansehen“ (alle Schritte; Server-Schritt zeigt dann „Verbunden“,
Scoop-Schritt legt auf Wunsch einen weiteren Scoop an, sonst „Später“) und „Tipps am Ende zeigen“.

## Startargumente (Tests, Screenshots)

`-onboarding <schritt>[:<detail>]` setzt den Stand zurück und beginnt beim Schritt. Mit `-mock` liegt der Stand in
einer eigenen Domain (`com.ais.aisbot.onboarding-demo`), die echte Einführung bleibt unberührt; der Demo-Server startet
dann frisch (nur Pip), das Demo-Konto ohne Server (`-mockservers`: mit den zwei Beispiel-Servern) und bis
einschließlich Anmeldung abgemeldet.

| Argument | Zeigt |
|---|---|
| `welcome`, `welcome:2`, `welcome:3` | Begrüßung, Seite 1–3 |
| `signin` | Anmelden |
| `server` | Server-Schritt (Anleitung bzw. mit `-mockservers` die Liste) |
| `server:guide`, `server:choose`, `server:code` | Unterseiten |
| `server:waiting` | Demo-Kopplung, der Server meldet sich nach ca. 4 s und die App verbindet |
| `server:expired` | Code abgelaufen |
| `server:unreachable` | Server nicht erreichbar |
| `scoop`, `scoop:look`, `scoop:purpose` | Erster Scoop, Teil 1–3 |
| `message`, `message:reply` | Erste Nachricht (mit `reply`: erster Vorschlag wird gesendet, Antwort gefeiert) |
| `tips` | Tipps |
| `resume` | nur `-mock`: gespeicherten Demo-Stand fortsetzen (Neustart-Test) |

Beispiel: `-mock -onboarding server:code -theme hell`. Ohne `-mock` wirkt das Argument auf den echten Stand (nur im
Simulator verwenden).

## Bilder

- Erste Begrüßungsseite: Key Visual `Marketing/keyvisual/ais-scoops-square-hell|dunkel.png`, verkleinert als Assets
  `WelcomeKeyvisualLight`/`WelcomeKeyvisualDark` (1200 px JPEG), Auswahl nach Erscheinungsbild der App.
- Deko-Scoops (Begrüßung, Anmelden, Server, Warten, Tipps): gerenderte Figuren aus `Marketing/figuren` als Assets
  `ScoopFigure01…07` (480 px, Rand beschnitten), `ScoopFigureView`/`WelcomeCrew` in `Views/OnboardingView.swift`.
  Beim Warten und Verbinden schweben sie leicht (aus bei „Bewegung reduzieren“).
- Der eigene Scoop bleibt `MascotView`: Nur sie zeigt Form, Farbe und Augen so, wie man sie gerade wählt.
- Demo-Scoop der Einführung (`-mock -onboarding message`, `scoop:look`): **Fina**, gestaltet wie Figur 06 „Creme“.

Neue Bilder: `magick <figur>.png -trim +repage -resize 480x480 -background none -gravity south -extent 480x480 -strip`.

## Tests

- Logik: `WatchLogicTests/OnboardingLogicTests.swift` (Bestandsnutzer, frischer Server, Schritte, erste Antwort,
  Startargument, Kopplungslink).
- Oberfläche: Ziel/Schema `AISBotUITests` (iOS-Simulator). `testGanzerAblaufDemo` tippt den ganzen Ablauf im
  Demo-Modus durch (inkl. abgelaufenem Code), `testNeustartSetztFort` beendet die App mitten im Scoop-Schritt und prüft
  die Wiederaufnahme, `testScreenshotsJedesSchritts` legt jeden Schritt hell und dunkel als Anhang ab,
  `testLokalerTestserver` läuft gegen einen echten Server mit „Manuell verbinden“ (nur mit
  `TEST_RUNNER_ONB_SERVER_URL`/`TEST_RUNNER_ONB_SERVER_TOKEN`, sonst übersprungen; Testinstanz in eigenem Ordner mit
  Fake-Modell, nie Armans Server). `testGroessenwechselMittenImAblauf` dreht mitten im Ablauf (Name, Figur, Code)
  und prüft Eingaben, Zurück-Weg und dass „Code abgelaufen“ trotz Tastatur sichtbar bleibt.
- iPhone Duo: Auf- und Zuklappen geht nur über das Scharnier-Ereignis (`agent-device fold open|closed`), nicht in
  XCUITest. Die UI-Tests laufen zugeklappt; aufgeklappt landen XCUITest-Tipps neben dem App-Fenster. Ergebnisse und
  Grenzen: App/README.md, „Einführung auf dem iPhone Duo“.

```sh
cd App && xcodebuild -project AISBot.xcodeproj -scheme AISBotUITests -destination 'platform=iOS Simulator,name=<Gerät>' \
  -resultBundlePath /tmp/onboarding.xcresult test
xcrun xcresulttool export attachments --path /tmp/onboarding.xcresult --output-path /tmp/onboarding-shots
```

## Download-Adresse

`ScoopsLinks.serverDownload` in `App/AISBot/Views/Onboarding/OnboardingState.swift`, derzeit
`https://ais-con.com/scoops` (TODO: endgültige Seite eintragen, sobald sie online ist).

## Offen

- Es gibt im Repository noch keinen String-Katalog (`Localizable.xcstrings`); die Texte stehen wie im Rest der App als
  `LocalizedStringKey`/`String(localized:)` im Code und werden mit dem Katalog automatisch erfasst.

## Abstimmung mit dem Assistenten von AIS Scoops Server

- **Schrittnamen im Mac-Assistenten:** 1 Willkommen, 2 **Mit der App verbinden** (zeigt den Kopplungscode), 3 KI-Zugang,
  4 Diesen Mac freigeben, 5 **Von unterwegs erreichbar**, 6 Dauerbetrieb, 7 Fertig. Die App verweist mit genau diesen
  Namen darauf (Server-Schritt, Blatt „Server hinzufügen“, Hinweise bei fehlender Adresse und „nicht erreichbar“).
- **QR-Code für den Kopplungscode:** Der Einstieg in der App ist da (`aisscoops://link?code=…`, siehe „Kopplungslink“).
  Der Mac-Assistent kann den QR-Code mit genau dieser Adresse zeigen.
- **Erster Scoop:** `GET /api/setup` meldet `server.own_scoops = {count, newest}` (ohne Pip). Der Abschluss des
  Mac-Assistenten sagt „Erstelle jetzt deinen ersten Scoop in AIS Scoops“ und gratuliert, sobald `count > 0` ist –
  das passt zum Schritt „Erster Scoop“ der App.
