# AIS Scoops auf deinem Mac einrichten

Diese Anleitung ist für dich, wenn du deine **eigenen Scoops** haben möchtest. Die Scoops wohnen auf deinem Mac,
du chattest mit ihnen in der App **AIS Scoops** auf iPhone, iPad oder Mac. Du brauchst kein Terminal und
musst nichts programmieren. Rechne mit etwa 10 Minuten.

## Was du brauchst

- Einen **Mac mit Apple-Chip** (M1 oder neuer) und **macOS 26** oder neuer. Am besten einen Mac, der zu Hause
  am Strom bleibt.
- Ein **Apple-Konto**. Damit meldest du dich in der App mit „Mit Apple anmelden“ an.
- Die App **AIS Scoops aus dem App Store** auf iPhone, iPad oder Mac.
- Ein **KI-Abo** (Claude Pro oder Max, ChatGPT Plus oder Pro) **oder** einen **API-Schlüssel** von Anthropic oder
  OpenAI. Wie du einen Schlüssel bekommst, steht unten.
- Optional: **Tailscale** (kostenlos), wenn du deine Scoops auch unterwegs nutzen möchtest.

## 1. Server installieren

1. Lade **AIS Scoops Server** von [ais-con.com/scoops](https://ais-con.com/scoops) und zieh die App in den Ordner
   **Programme**.
2. Starte **AIS Scoops Server** aus dem Programme-Ordner. Fragt macOS „Möchtest du die App öffnen?“, klick auf
   **Öffnen**.
3. Oben rechts in der Menüleiste erscheint ein kleines Server-Symbol, und der **Einrichtungsassistent** öffnet sich.

## 2. Der Assistent

Links im Fenster siehst du alle Schritte und wie weit du bist. Erledigte Schritte haben einen grünen Haken.
Mit **Zurück** oder einem Klick auf einen früheren Schritt gehst du jederzeit zurück. Schließt du das Fenster
oder startet der Mac neu, geht es beim nächsten Öffnen an derselben Stelle weiter (Menüleiste ›
**Einrichtung fortsetzen …**).

1. **Willkommen** – was passiert und was du brauchst. Der Server startet dabei; warte, bis „Server läuft“ erscheint.
2. **Mit der App verbinden** (nötig) – der Assistent zeigt groß einen **Kopplungscode** wie `K7QX-29PL`.
   - Öffne **AIS Scoops** auf iPhone, iPad oder Mac und melde dich mit **Mit Apple anmelden** an.
   - Tippe auf **Deine Server → Server hinzufügen** (beim ersten Start fragt dich die App selbst danach) und gib den
     Code ein. **Kopieren** legt ihn in die Zwischenablage, falls die App auf demselben Mac läuft.
   - Ein Code gilt 10 Minuten. Läuft er ab, zeigt der Assistent von selbst einen neuen.
   - Sobald du ihn eingegeben hast, steht im Assistenten **„Verbunden!“** mit deinem Namen. Darunter trägst du ein,
     wie dich deine Scoops nennen sollen.
3. **KI-Zugang** (nötig) – eins von beidem reicht:
   - **Mit meinem KI-Abo:** auf **Mit Claude anmelden** bzw. **Mit ChatGPT anmelden** klicken. Ein Terminal-Fenster
     öffnet die offizielle Anmeldung im Browser. Kommst du zurück, zeigt der Assistent „Angemeldet“.
   - **Mit API-Schlüssel:** Schlüssel einfügen und **Prüfen und speichern** klicken. „Wo bekomme ich den
     Schlüssel?“ erklärt die Schritte beim Anbieter. Schlüssel liegen nur im Schlüsselbund deines Macs.
   - Steht der Zugang, erscheint **„KI-Zugang steht“**, und es geht weiter.
4. **Diesen Mac freigeben** (optional) – damit Scoops auf deinem Mac klicken und tippen können (z. B. im Browser).
   Klick bei **Bildschirmaufnahme** und **Bedienungshilfen** auf **Erlauben …** und schalte in den
   Systemeinstellungen **AIS Scoops Server** ein. Kommst du zurück, erkennt der Assistent die Freigabe von selbst.
   Danach **Diesen Mac anschließen**. Wichtig: Was auf dem Mac angemeldet ist, können die Scoops sehen. Arbeitest du
   selbst gerade am Mac, drück oben in der Menüleiste auf **Pausieren**. Ohne diesen Schritt chatten die Scoops nur.
5. **Von unterwegs erreichbar** (optional) – siehe Abschnitt 4 unten. Kannst du mit **Überspringen** später
   nachholen.
6. **Dauerbetrieb** (empfohlen) – lass **Mac wach halten** eingeschaltet. Wenn die Scoops auch am Bildschirm
   arbeiten sollen, während du weg bist, schalte **Bildschirm anlassen** ein.
7. **Fertig** – der Assistent prüft, ob alles steht: Server läuft, mit AIS Scoops verbunden, KI-Zugang ok, dieser
   Mac freigegeben, von unterwegs erreichbar. Fehlt etwas, bringt dich **Beheben** bzw. **Einrichten** direkt zum
   passenden Schritt. Danach heißt es: **Erstelle jetzt deinen ersten Scoop in AIS Scoops** (Abschnitt 3). Hast du
   schon einen angelegt, gratuliert dir der Assistent.

Die Einrichtung lässt sich jederzeit wieder öffnen: Menüleiste › **Einrichtung erneut öffnen …** oder in den
Einstellungen unter **Allgemein**. Ein Server, der schon eingerichtet ist, öffnet den Assistenten nie von selbst.

## 3. Dein erster Scoop

1. Öffne **AIS Scoops** und wähle unter **Deine Server** deinen Mac.
2. Tippe auf **+** (Neuer Scoop), gib ihm einen Namen und einen Charakter und schreib ihm deine erste Nachricht.
3. Dein Start-Scoop **Pip** wartet dort auch schon und erklärt dir gern alles.
4. Erlaube **Mitteilungen**, wenn die App fragt. Dann bekommst du Nachrichten deiner Scoops auch, wenn die App zu ist,
   die Zahl am App-Symbol zeigt, in wie vielen Chats etwas Ungelesenes liegt, Widgets bleiben aktuell und arbeitende
   Scoops erscheinen als Live-Aktivität auf dem Sperrbildschirm.

## 4. Von unterwegs erreichbar (optional)

Ohne diesen Schritt funktioniert die App nur, wenn du direkt am Mac bist. Für unterwegs:

- **Mit Tailscale (empfohlen, kostenlos):** Lade Tailscale auf Mac und iPhone
  (https://tailscale.com/download), melde dich auf beiden mit demselben Konto an. Der Assistent erkennt Tailscale,
  sobald du zurückkommst. Dann im Assistenten bzw. in den Einstellungen unter **Erreichbarkeit** auf
  **Für meine Geräte freigeben** klicken.
  „Öffentlich freigeben“ geht auch ohne Tailscale auf dem iPhone, muss aber in deinem Tailscale-Konto erlaubt sein.
- **Nur im WLAN zu Hause:** **Im lokalen Netz freigeben** – dann klappt es, wenn iPhone und Mac im selben WLAN sind.

## Gut zu wissen

- **Solange das Symbol oben in der Menüleiste ist, läuft der Server.** Über das Symbol: Neu starten, Protokoll,
  Pausieren, Einstellungen (z. B. Schlüssel ändern) und Beenden.
- **Updates kommen von selbst.** Die App lädt neue Versionen im Hintergrund und installiert sie, sobald gerade kein
  Scoop arbeitet. Danach startet sie neu, der Server läuft gleich wieder. Von Hand: Menüleiste › **Nach Updates
  suchen …** (Details für Arman: [updates.md](updates.md)).
- **Nach einem Neustart** des Macs (Update, Stromausfall) musst du dich einmal selbst anmelden. Danach startet
  alles von selbst.
- **Kosten:** Die KI-Kosten laufen über dein Konto bei Anthropic/OpenAI. Eine normale Chat-Antwort kostet meist
  weniger als einen Cent. Lege dort ein monatliches Limit fest.
- **Mitteilungen** funktionieren, sobald der Server mit deinem Konto verbunden ist – du musst dafür nichts einrichten.
  Sie laufen über AIS Scoops Cloud zu Apple. In den Einstellungen des Servers steht dann unter **Konto**:
  „Mitteilungen: Aktiv (über AIS Scoops Cloud)“.
- **Deine Daten** (Chats, Gedächtnis, Dateien) bleiben auf deinem Mac
  (Ordner `Library/Application Support/AIS Scoops Server`). Das Konto kennt nur deinen Namen, deinen Server und
  die Mitteilungs-Kennungen deiner Geräte. Der Text einer Mitteilung wird nur durchgereicht, nicht gespeichert.

## KI-Schlüssel bekommen

- **Anthropic (Claude):** https://console.anthropic.com → anmelden → **Billing**: Guthaben aufladen (z. B. 10 $) →
  **API Keys** → **Create Key** → Schlüssel kopieren (beginnt mit `sk-ant-`).
- **OpenAI (optional):** https://platform.openai.com → **API keys** → **Create new secret key**.
- **Composio (optional, für Gmail, Kalender, Notion):** https://platform.composio.dev → **API Keys**.
  Konten verbindest du danach in AIS Scoops unter **Einstellungen → Apps verbinden**.

## Wenn etwas nicht klappt

- **Roter Punkt / „Server-Fehler“:** Menüleiste → **Server neu starten**. Hilft das nicht: **Protokoll öffnen** und
  Arman die letzten Zeilen schicken (keine Schlüssel mitschicken – die stehen dort auch nicht drin).
- **Code abgelaufen:** Der Assistent zeigt von selbst einen neuen. Kommt keiner, steht dort ein Hinweis mit
  **Erneut versuchen** (meist fehlt kurz die Internetverbindung).
- **Keine Mitteilungen:** Ist der Server mit dem Konto verbunden (Einstellungen → Konto)? Hast du Mitteilungen für
  AIS Scoops erlaubt (iPhone: Einstellungen → Mitteilungen → AIS Scoops)? Öffne die App einmal, damit sie sich beim
  Server meldet.
- **Server erscheint in der App als offline:** Läuft der Mac und ist das Menüleisten-Symbol da? Ist der Mac im
  Internet? Unterwegs: Ist die Erreichbarkeit (Abschnitt 4) eingerichtet?
- **Scoops können nicht klicken:** Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen bzw.
  Bildschirmaufnahme → **AIS Scoops Server** einschalten, dann die App einmal beenden und neu öffnen.
- **App lädt endlos / „Server nur im Heim-WLAN erreichbar“:** Unter **Erreichbarkeit** steht eine Adresse wie
  `http://…local:8787`. Die geht nur im selben WLAN. Für unterwegs: **Erreichbarkeit einrichten …** → Tailscale →
  **Öffentlich freigeben (Funnel)**. Danach steht dort `https://<dein-mac>.<tailnet>.ts.net:10000`, und die App bekommt
  die Adresse nach wenigen Sekunden. Meldet Tailscale „Funnel ist nicht erlaubt“ oder „HTTPS-Zertifikate nicht
  aktiviert“, zeigt der Assistent einen Link: öffnen, im Tailscale-Konto erlauben, dann erneut klicken.
  **Öffentliche Adresse kopieren** legt die Adresse in die Zwischenablage (z. B. zum Prüfen im Browser).

## Fehlerbehebung: Rechner getrennt

In den Einstellungen unter **Dieser Mac als Rechner** steht rot „Getrennt: …“ mit dem Grund, z. B.
„Verbindung abgelehnt (Port 8787) – dort läuft kein Server“.

1. **Jetzt verbinden** klicken. Die App stellt die Verbindung dabei immer auf `http://127.0.0.1:<aktueller Port>` des
   eigenen Servers um (Kopplung und Token bleiben). Das passiert auch automatisch bei jedem Start und Neustart des Servers.
2. **Steht unter „Server“ ein gelber Hinweis „Port 8787 ist belegt durch …“?** Dann blockiert ein anderes Programm den
   Port (Name, PID und Pfad stehen dabei). Der Server weicht automatisch auf den nächsten freien Port aus (z. B. 8788) und
   zieht mit: „Dieser Mac“, die WLAN-Adresse und eine Tailscale-Freigabe zeigen danach auf den neuen Port. Der neue Port
   bleibt gespeichert, damit sich die Adresse nicht ständig ändert.
3. **Hinweis „ältere AIS-Bot-Installation“:** Auf Macs, auf denen früher die Entwickler-Version lief, startet ein alter
   Hintergrunddienst (`com.ais-bot.server`) einen zweiten Server auf Port 8787. Mit **Alte Installation deaktivieren …**
   wird er gestoppt und startet nicht mehr bei der Anmeldung. Gelöscht wird nichts: Die Datei
   `~/Library/LaunchAgents/com.ais-bot.server.plist` heißt danach `….plist.deaktiviert`, die alten Daten unter
   `~/.local/share/ais-bot` bleiben. Rückgängig: Datei zurückbenennen und neu anmelden.
4. **Mehrere gleichnamige Rechner in der App (Scoop-Profil → Computer):** Koppelt sich dieser Mac neu, ersetzt er jetzt
   seinen alten Eintrag (gleiche Geräte-ID) statt einen weiteren anzulegen. Alte doppelte Einträge („Dieser Mac“ von
   früheren Kopplungen, offline, gleicher Name) führt die Server-App beim nächsten Start automatisch zusammen; Scoops, die
   noch auf einem alten Eintrag standen, arbeiten danach an diesem Mac. Andere alte Einträge lassen sich in AIS Scoops unter
   **Einstellungen → Rechner** entfernen – sie verschwinden dann auch aus der Auswahl im Scoop-Profil.
5. Hilft das alles nicht: **Protokoll öffnen** und die letzten Zeilen an Arman schicken.
