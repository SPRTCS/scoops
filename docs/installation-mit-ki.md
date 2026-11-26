# AIS Scoops mit einem KI-Agenten einrichten

> **Für Menschen:** Gib diese Datei deinem KI-Agenten, der deinen Mac bedienen kann (Computer Use), zum Beispiel
> Claude oder ChatGPT in der Mac-App. Starte den Agenten am besten **auf dem Mac, der später der Server sein soll**,
> und schreib ihm:
>
> „Lies https://raw.githubusercontent.com/SPRTCS/scoops/main/docs/installation-mit-ki.md und richte mir AIS Scoops
> danach ein. Führ mich Schritt für Schritt durch, ich kenne mich mit Technik nicht aus.“
>
> Du musst nichts davon selbst lesen. Der Agent fragt dich, wenn er dich braucht.

---

**Ab hier spricht diese Anleitung den Agenten an.**

Du richtest für einen Menschen ohne Technikwissen AIS Scoops ein: die App **AIS Scoops** auf iPhone, iPad oder Mac und
die Server-App **AIS Scoops Server** auf einem Mac, der dauerhaft läuft (im Folgenden **Server-Mac**). Das ist oft ein
zweiter Mac, zum Beispiel ein älteres MacBook oder ein Mac mini zu Hause.

Rechne mit 20 bis 40 Minuten. Die meiste Zeit geht für Anmeldungen bei Anbietern drauf.

## 1. Regeln für dich

1. **Erklär einfach.** Kein Fachjargon ohne Erklärung in einem Satz. Sag vor jedem Schritt in einem Satz, was jetzt
   passiert und warum. Sprich in der Sprache des Nutzers.
2. **Ein Schritt nach dem anderen.** Prüf nach jedem Klick mit einem Bildschirmfoto, ob das Erwartete passiert ist,
   bevor du weitermachst. Haken im Assistenten der Server-App sind dein Fortschrittsanzeiger.
3. **Anmeldungen, Passwörter, Zahlungen und Systemdialoge macht der Mensch.** Tipp nie ein Passwort, keinen Code aus
   einer SMS oder Mail und keine Kartendaten ein. Klick keine macOS-Dialoge weg, die nach Passwort, Touch ID oder
   einer Freigabe fragen. Sag stattdessen genau, worauf der Mensch klicken oder was er eingeben soll, und warte.
4. **Schlüssel nie in den Chat.** API-Schlüssel kopierst du beim Anbieter mit dessen Kopieren-Knopf und fügst sie mit
   ⌘V in das Feld der Server-App ein. Schreib sie nie in den Chat, in Dateien oder ins Terminal und lies sie nicht vor.
5. **Nichts an der Installation basteln.** Alles Nötige geht über die Knöpfe der Server-App. Nicht erlaubt sind:
   Konfigurationsdateien bearbeiten (`~/Library/Application Support/AIS Scoops Server/…`), Programme beenden, die einen
   Port belegen, eigene `tailscale serve`- oder `tailscale funnel`-Befehle ausführen, `launchctl` benutzen, im Router
   Ports öffnen. Erlaubt sind die lesenden Prüfbefehle im Anhang.
6. **Das iPhone kannst du nicht bedienen.** Was dort passiert, beschreibst du dem Menschen genau und lässt dir das
   Ergebnis bestätigen, am besten mit einem Bildschirmfoto, das er dir schickt.
7. **Englisches macOS?** Die Server-App und die App gibt es auf Deutsch und Englisch. Die Tabelle im Anhang ordnet die
   Beschriftungen zu.
8. **Kommst du nicht weiter,** lies Abschnitt 6 (Fehlerbehebung). Hilft das nicht, sag dem Menschen ehrlich, wo es
   hängt, statt zu raten.

## 2. Was du wissen musst (kurz)

| Begriff | Bedeutung |
|---|---|
| **Server-Mac** | Der Mac, auf dem die Server-App läuft. Dort wohnen die Scoops, ihre Chats und Dateien. Er sollte am Strom bleiben und nicht schlafen. |
| **AIS Scoops** | Die App, mit der man mit den Scoops chattet (App Store, iPhone, iPad und Mac). |
| **Kopplungscode** | 8 Zeichen wie `K7QX-29PL`, angezeigt von der Server-App, gültig 10 Minuten. Er verbindet die App mit dem Server. |
| **KI-Zugang** | Ein Claude- oder ChatGPT-Abo **oder** ein API-Schlüssel von Anthropic bzw. OpenAI. Ohne geht nichts. |
| **Composio** | Optionaler Dienst, über den die Scoops Gmail, Google Kalender, Notion und viele andere Apps nutzen. Braucht einen eigenen Schlüssel. |
| **Tailscale** | Kostenloser Dienst, der den Server-Mac von unterwegs erreichbar macht, ohne Router-Einstellungen. |
| **Funnel** | Tailscale-Funktion, die den Server unter einer `https://…ts.net:10000`-Adresse im Internet erreichbar macht. Nutzen kann ihn trotzdem nur, wer sich in der App mit dem Konto des Besitzers angemeldet hat. |

### Ports, damit du nicht in die Falle läufst

Der Server lauscht auf dem Mac an **Port 8787** (ist der belegt, weicht er selbst auf 8788 usw. aus). Dieser Port ist
**nur intern**. Für den Menschen gibt es genau drei Arten von Adressen:

| Adresse | Art | Wo sie funktioniert |
|---|---|---|
| `http://<mac-name>.local:8787` oder `http://192.168.…:8787` | Heim-WLAN | nur, wenn iPhone und Server-Mac im selben WLAN sind |
| `https://<mac-name>.<tailnet>.ts.net:8787` | Tailscale Serve („Für meine Geräte“) | nur auf Geräten, auf denen Tailscale **läuft und mit demselben Konto angemeldet** ist |
| `https://<mac-name>.<tailnet>.ts.net:10000` | Tailscale Funnel („Öffentlich“) | überall, auch im Mobilfunk, ohne Tailscale auf dem iPhone |

Daraus folgt:

- Eine **öffentliche Adresse mit `:8787` gibt es nicht.** Funnel erlaubt nur die Ports 443, 8443 und 10000, die
  Server-App nutzt **10000**. Funktioniert eine `…ts.net:8787`-Adresse im WLAN, aber nicht unterwegs, ist das
  Tailscale Serve, und auf dem iPhone ist Tailscale aus. Das ist kein Fehler des Servers.
- **Nie** im Router Port 8787 freigeben, nie eine Adresse von Hand eintragen. Die Server-App meldet die richtige
  Adresse selbst an das Konto, und die App holt sie sich von dort.

## 3. Vorab klären

Frag den Menschen, bevor du anfängst:

1. **Welcher Mac wird der Server-Mac?** Er braucht einen **Apple-Chip (M1 oder neuer)** und **macOS 26 oder neuer**.
   Prüf das unter Apple-Menü  → **Über diesen Mac**. Ist es ein MacBook: Bleibt es am Netzteil?
   Läufst du selbst nicht auf dem Server-Mac, führst du den Menschen dort nur mit Worten durch.
2. **Welches Gerät zum Chatten?** iPhone, iPad oder ein Mac (auch derselbe Server-Mac geht).
3. **Hat er ein KI-Abo?** Claude Pro oder Max, ChatGPT Plus oder Pro. Wenn nein: Er braucht einen API-Schlüssel und
   muss beim Anbieter Guthaben aufladen (ab etwa 5 bis 10 $).
4. **Sollen die Scoops Mails, Kalender oder Notion nutzen?** Dann richtet ihr Composio ein (Schritt 6).
5. **Sollen die Scoops auch unterwegs erreichbar sein?** Fast immer ja. Dann richtet ihr Tailscale Funnel ein
   (Schritt 8).
6. **Dürfen die Scoops am Server-Mac klicken und tippen** (z. B. im Browser nachsehen)? Dann gibt der Mensch dafür
   zwei macOS-Rechte frei (Schritt 7). Wichtig: Was auf diesem Mac angemeldet ist, können die Scoops dann sehen.

## 4. Einrichtung

### Schritt 1: App auf dem Gerät zum Chatten

1. Der Mensch öffnet auf iPhone, iPad oder Mac den App Store und lädt **AIS Scoops**:
   https://apps.apple.com/app/id6833654924
2. App öffnen, **Mit Apple anmelden** antippen, bestätigen (Face ID, Touch ID oder Passwort macht der Mensch).
3. Die App fragt nach einem Server. Hier **noch nichts eingeben**, der Code kommt in Schritt 4.

### Schritt 2: Server-App auf dem Server-Mac installieren

1. Lade die Server-App: https://github.com/SPRTCS/ais-scoops-server/releases/latest/download/AIS-Scoops-Server.dmg
2. Öffne die geladene Datei `AIS-Scoops-Server.dmg` im Ordner **Downloads** und zieh **AIS Scoops Server** in den Ordner
   **Programme** (Applications).
3. Starte **AIS Scoops Server** aus **Programme**. Fragt macOS „Möchtest du die App öffnen?“, lässt du den Menschen
   **Öffnen** klicken. Die App ist von Apple geprüft (notarisiert).
4. Oben rechts in der Menüleiste erscheint ein Server-Symbol, und der **Einrichtungsassistent** öffnet sich. Links
   stehen die Schritte, erledigte bekommen einen grünen Haken.

Ist das Fenster weg: Menüleisten-Symbol → **Einrichtung fortsetzen …**. Updates installiert die App später von selbst.

### Schritt 3: Willkommen

Warte, bis **„Server läuft“** erscheint. Dann **Weiter**.

### Schritt 4: Mit der App verbinden (Kopplung)

1. Der Assistent zeigt groß einen **Kopplungscode** wie `K7QX-29PL`.
2. Der Mensch tippt in der App **Deine Server → Server hinzufügen** (beim ersten Start fragt die App selbst), gibt den
   Code ein und tippt **Koppeln**. Läuft die App auf demselben Mac, kannst du den Code mit **Kopieren** übernehmen und
   selbst einfügen.
3. Im Assistenten steht dann **„Verbunden!“** mit dem Namen des Menschen. Darunter trägst du ein, wie ihn die Scoops
   nennen sollen (Vorname).

Code abgelaufen? Der Assistent zeigt von selbst einen neuen. Steht dort ein Fehler mit **Erneut versuchen**, fehlt
meist kurz das Internet.

### Schritt 5: KI-Zugang

Eins von beidem reicht. Abo ist für die meisten einfacher und kostet nichts extra.

**A) Mit Abo** (Reiter **Mit meinem KI-Abo**)

1. Klick **Mit Claude anmelden** bzw. **Mit ChatGPT anmelden**.
2. Ein Terminal-Fenster öffnet die offizielle Anmeldung, meist geht dazu der Browser auf. Der Mensch meldet sich dort
   selbst an und bestätigt. Du tippst hier nichts.
3. Zurück im Assistenten steht **„Angemeldet“** bzw. **„KI-Zugang steht“**. Das Terminal-Fenster darf danach zu.

Die nötigen Programme (Claude Code, Codex) bringt die Server-App mit. Nichts nachinstallieren.

**B) Mit API-Schlüssel** (Reiter **Mit API-Schlüssel**)

Für Claude (empfohlen):

1. https://console.anthropic.com öffnen. Der Mensch legt ein Konto an oder meldet sich an.
2. Unter **Billing** Guthaben aufladen (z. B. 10 $). Das macht der Mensch, auch die Kartendaten. Empfiehl ein
   monatliches Limit unter **Limits**.
3. https://console.anthropic.com/settings/keys → **Create Key**, Name z. B. `Scoops` → Schlüssel mit dem
   Kopieren-Knopf kopieren. Er beginnt mit `sk-ant-` und wird nur einmal angezeigt.
4. In der Server-App ins Feld bei **Anthropic** klicken, mit ⌘V einfügen, **Prüfen und speichern**. Es erscheint
   **Gespeichert** mit grünem Haken.

Für ChatGPT/OpenAI (optional, auch für Sprechmodus und Diktat): https://platform.openai.com/api-keys → **Create new
secret key** → kopieren → ins Feld bei **OpenAI** einfügen → **Prüfen und speichern**. Guthaben unter
https://platform.openai.com/settings/organization/billing.

Gut zu wissen: Für **Sprechmodus und Diktat** braucht es auch mit Abo einen OpenAI-Schlüssel. Wer das nicht nutzt,
braucht ihn nicht.

### Schritt 6: Composio für Gmail, Kalender, Notion & Co. (optional)

Composio ist der Dienst, über den die Scoops Apps wie Gmail, Google Kalender oder Notion benutzen. Der Schlüssel
gehört dem Menschen; die Konten (z. B. sein Gmail) verbindet er danach in der App.

1. https://platform.composio.dev öffnen. Der Mensch registriert sich (z. B. mit Google oder GitHub) und bestätigt
   gegebenenfalls seine Mail. Es gibt einen kostenlosen Einstieg.
2. Fragt Composio nach einem Namen für Organisation oder Projekt, irgendetwas eintragen, z. B. `Scoops`.
3. Den Schlüssel findest du in den Einstellungen des Projekts: **Settings → API Keys** (je nach Version auch über den
   Projektnamen oben oder links im Menü erreichbar). Gesucht ist ein **Projekt-API-Schlüssel**, kein
   „Organization Access Token“. Gibt es noch keinen, **Create API Key** (Name z. B. `Scoops`) und dann kopieren.
4. In der Server-App eintragen:
   - Während der Einrichtung im Schritt **KI-Zugang**, Reiter **Mit API-Schlüssel**, Aufklapper **Optional: Gmail,
     Kalender, Notion & Co. verbinden**.
   - Oder später, auch bei Abo-Nutzern: Menüleisten-Symbol → **Einstellungen …** → Abschnitt **KI-Schlüssel** →
     Feld **Composio** → einfügen → **Prüfen und speichern**.
5. Meldet die Prüfung einen Fehler, ist es fast immer der falsche Schlüssel (z. B. der Organisations-Token) oder ein
   unvollständig kopierter. Neu kopieren. **Trotzdem speichern** nur, wenn Composio gerade nachweislich gestört ist.
6. Konten verbinden: In der App **Einstellungen → Apps verbinden** → App wählen (z. B. Gmail) → anmelden. Die
   Anmeldung beim Anbieter macht der Mensch. Mehrere Konten pro App gehen.

### Schritt 7: Diesen Mac freigeben (optional)

Nur nötig, wenn die Scoops am Server-Mac klicken und tippen sollen.

1. Im Assistenten bei **Bildschirmaufnahme** und **Bedienungshilfen** jeweils **Erlauben …** klicken. Die
   Systemeinstellungen öffnen sich.
2. Der Mensch schaltet dort **AIS Scoops Server** ein und bestätigt mit Passwort oder Touch ID. Fragt macOS, ob die App
   neu gestartet werden soll, darf er zustimmen.
3. Zurück im Assistenten erkennt er die Freigabe von selbst. Dann **Diesen Mac anschließen** und einen Namen
   vergeben (z. B. „Mac mini zu Hause“).

Hinweis für den Menschen: Arbeitet er selbst gerade an diesem Mac, kann er die Scoops oben in der Menüleiste mit
**Pausieren** anhalten.

### Schritt 8: Von unterwegs erreichbar (empfohlen)

Ohne diesen Schritt geht die App nur im selben WLAN. Für Laien ist **Tailscale Funnel** der einfachste Weg, weil auf
dem iPhone nichts installiert werden muss.

1. **Tailscale-Konto und App auf dem Server-Mac:**
   1. https://tailscale.com/download/mac öffnen und Tailscale installieren (App Store oder Download, beides geht).
   2. Tailscale starten. macOS fragt, ob Tailscale eine **VPN-Konfiguration** hinzufügen darf. Das bestätigt der
      Mensch (**Erlauben**, Passwort oder Touch ID).
   3. Im Tailscale-Menü (Symbol oben rechts) **Log in** bzw. **Anmelden**. Im Browser meldet sich der Mensch an,
      z. B. mit Google, Apple oder Microsoft. Das kostenlose Personal-Konto reicht.
   4. Danach zeigt das Tailscale-Menü **Connected** bzw. **Verbunden**.
2. **Zurück im Assistenten** (Schritt **Von unterwegs erreichbar**): Steht dort „Tailscale ist angemeldet (…)“, weiter.
   Sonst **Erneut prüfen**.
3. Klick **Öffentlich freigeben (Funnel) …** und im Dialog **Freigeben**.
4. **Zeigt der Assistent einen Link** mit einer Meldung wie „Funnel ist in deinem Tailnet noch nicht erlaubt“ oder
   „HTTPS-Zertifikate sind in deinem Tailnet nicht aktiviert“: Link öffnen. Der Mensch bestätigt im Tailscale-Konto
   (Knopf zum Aktivieren bzw. **Enable**). Danach im Assistenten erneut **Öffentlich freigeben (Funnel) …**. Das kann
   zweimal nötig sein, einmal für HTTPS und einmal für Funnel.
5. Geklappt hat es, wenn in den Einstellungen unter **Erreichbarkeit → Adresse** eine Adresse der Form
   `https://<mac-name>.<tailnet>.ts.net:10000` steht. Die App bekommt sie nach wenigen Sekunden von selbst.
6. **Test von außen** (wichtig, siehe Abschnitt 5).

Alternative für Technik-Affine: **Für meine Geräte freigeben** (Tailscale Serve). Dann braucht **jedes** Gerät, das
die Scoops nutzt, die Tailscale-App, angemeldet mit demselben Konto und eingeschaltet. Für Laien nicht empfohlen, weil
die App unterwegs nicht verbindet, sobald Tailscale auf dem iPhone aus ist.

### Schritt 9: Dauerbetrieb

- **Mac wach halten, solange der Server läuft**: an lassen.
- **Bildschirm anlassen**: nur, wenn Scoops am Bildschirm arbeiten sollen, während der Mensch weg ist (Schritt 7).
- MacBook: **Auch zugeklappt wach bleiben** nur, wenn es zugeklappt am Netzteil stehen soll. macOS fragt dafür einmal
  nach dem Passwort (macht der Mensch).
- **Bildschirmsperre:** Ist der Mac gesperrt, können Scoops nicht klicken. Nur auf einem sicher stehenden Mac die
  Passwortabfrage verzögern (Knopf **Einstellungen öffnen**). Lass das den Menschen entscheiden.
- Nach einem Neustart des Macs (Update, Stromausfall) muss sich der Mensch einmal am Mac anmelden, dann startet
  alles von selbst.

### Schritt 10: Fertig und erster Scoop

1. Der Schritt **Fertig** prüft alles: Server läuft, mit AIS Scoops verbunden, KI-Zugang, Mac freigegeben, von
   unterwegs erreichbar. Fehlt etwas, führt **Beheben** bzw. **Einrichten** zum passenden Schritt.
2. In der App: unter **Deine Server** den Server-Mac wählen. Der Start-Scoop **Pip** wartet schon. Mit **+** legt der
   Mensch einen eigenen Scoop an.
3. **Mitteilungen erlauben**, wenn die App fragt. Dann kommen Nachrichten auch bei geschlossener App.

## 5. Abschlusstest

Geh das mit dem Menschen durch und hak es ab:

1. **Chat geht:** Pip eine Nachricht schreiben („Hallo, wer bist du?“). Antwort kommt.
2. **Unterwegs geht:** Auf dem iPhone **WLAN ausschalten** (nur Mobilfunk) und, falls installiert, **Tailscale
   ausschalten**. Dann:
   1. In Safari die Funnel-Adresse mit `/api/health` öffnen, z. B. `https://<mac-name>.<tailnet>.ts.net:10000/api/health`.
      Die Adresse liefert dir **Öffentliche Adresse kopieren** in den Einstellungen der Server-App.
      **Richtig** ist eine kurze Zeile wie `{"error":"Nicht angemeldet"}`. Das heißt: Der Server ist von außen
      erreichbar, nur der Browser ist nicht angemeldet. Genau so soll es sein.
   2. Die App öffnen und Pip schreiben. Antwort kommt.
3. **Apps (falls Composio):** Pip bitten: „Schau, ob in meinem Gmail heute etwas Wichtiges kam.“ Der Scoop greift auf
   das verbundene Konto zu.
4. **Rechner (falls Schritt 7):** Pip bitten: „Öffne auf meinem Mac Safari und such das Wetter für morgen.“

## 6. Fehlerbehebung

### Im WLAN geht es, unterwegs nicht (auch: „Port 8787“, „Server nur im Heim-WLAN erreichbar“)

Öffne in der Server-App Menüleisten-Symbol → **Einstellungen …** → **Erreichbarkeit** und schau, was bei **Adresse**
steht.

| Steht dort | Bedeutung | Lösung |
|---|---|---|
| „nur auf diesem Mac“ | keine Freigabe | Schritt 8 |
| `http://….local:8787` oder `http://192.168.…:8787` | nur Heim-WLAN | Schritt 8 (Funnel) |
| `https://….ts.net:8787` | Tailscale Serve, nur mit Tailscale auf dem iPhone | Entweder auf dem iPhone die Tailscale-App installieren, mit demselben Konto anmelden und **einschalten**, oder (für Laien besser) **Erreichbarkeit einrichten …** → **Öffentlich freigeben (Funnel) …**. Danach steht dort `:10000`. |
| `https://….ts.net:10000` | Funnel ist eingerichtet | weiter unten |

Ist Funnel eingerichtet, die App unterwegs aber trotzdem ohne Verbindung:

1. **Gerade erst eingerichtet?** Bis die Adresse überall bekannt ist und das Zertifikat steht, können einige Minuten
   vergehen (selten bis etwa 10). Fehler wie „Verbindung nicht privat“ oder „Server nicht gefunden“ verschwinden dann
   von selbst. Warten und den Test aus Abschnitt 5 wiederholen.
2. **Läuft Tailscale auf dem Server-Mac?** Tailscale-Menü zeigt **Connected**. Ist es abgemeldet, den Menschen neu
   anmelden lassen.
3. **Steht unter Erreichbarkeit ein oranger Hinweis** „zeigt auf Port …, der Server läuft auf …“? Dann
   **Tailscale prüfen** klicken. Die App stellt die Freigabe selbst auf den richtigen Port um.
4. **Schläft der Mac oder ist er aus?** Schritt 9.
5. **Health-Test in Safari klappt, die App verbindet trotzdem nicht?** Die App hat noch eine alte Adresse. App ganz
   schließen (iPhone: nach oben wischen) und neu öffnen, eine Minute warten. Die App holt sich die neue Adresse vom
   Konto.
6. **Nicht tun:** Port 8787 im Router freigeben, die Adresse in der App von Hand ändern, Funnel auf Port 8787 legen
   (geht nicht, Funnel erlaubt nur 443, 8443 und 10000), Tailscale-Befehle selbst ausführen.

### Weitere Probleme

- **Roter Punkt oder „Server-Fehler“:** Menüleisten-Symbol → **Server neu starten**. Hilft das nicht:
  **Protokoll öffnen** und die letzten Zeilen anschauen (dort stehen keine Schlüssel).
- **„Port 8787 ist belegt durch …“** (gelber Hinweis unter **Server**): Ein anderes Programm nutzt den Port. Nichts
  beenden. Der Server weicht von selbst auf den nächsten freien Port aus, und Tailscale zieht mit. Für die öffentliche
  Adresse (`:10000`) ändert sich nichts.
- **Rechner „Getrennt“** unter **Dieser Mac als Rechner**: **Jetzt verbinden** klicken.
- **Scoops können nicht klicken:** Systemeinstellungen → Datenschutz & Sicherheit → **Bedienungshilfen** und
  **Bildschirmaufnahme** → **AIS Scoops Server** einschalten (macht der Mensch), dann die Server-App beenden
  (**Beenden (stoppt den Server)**) und neu öffnen.
- **Keine Mitteilungen:** In der Server-App unter **Konto** muss „Verbunden“ stehen. Auf dem iPhone: Einstellungen →
  Mitteilungen → AIS Scoops erlauben. App einmal öffnen.
- **Abo „nicht angemeldet“** obwohl angemeldet: In der Server-App **Mit Claude anmelden** bzw. **Mit ChatGPT anmelden**
  erneut, Anmeldung im Browser abschließen lassen.
- **Composio-Schlüssel wird abgelehnt:** Projekt-API-Schlüssel neu erzeugen und kopieren (Schritt 6).

## Anhang A: Beschriftungen Deutsch und Englisch

| Deutsch | Englisch |
|---|---|
| Einstellungen … | Settings… |
| Einrichtung fortsetzen … / Einrichtung erneut öffnen … | Continue Setup… / Open Setup Again… |
| Weiter / Überspringen / Erneut prüfen | Continue / Skip / Check Again |
| Mit meinem KI-Abo / Mit API-Schlüssel | With My AI Subscription / With an API Key |
| Mit Claude anmelden / Mit ChatGPT anmelden | Sign In with Claude / Sign In with ChatGPT |
| Prüfen und speichern / Schlüssel holen | Verify and Save / Get Key |
| Optional: Gmail, Kalender, Notion & Co. verbinden | Optional: Connect Gmail, Calendar, Notion, and More |
| KI-Schlüssel | AI Keys |
| Diesen Mac anschließen | Connect This Mac |
| Erreichbarkeit / Erreichbarkeit einrichten … | Remote Access / Set Up Remote Access… |
| Öffentlich freigeben (Funnel) … / Freigeben | Share Publicly (Funnel)… / Share |
| Für meine Geräte freigeben / Im lokalen Netz freigeben | Share with My Devices / Share on Local Network |
| Öffentliche Adresse kopieren / Tailscale prüfen | Copy Public Address / Check Tailscale |
| Dauerbetrieb | Always On |
| Mac wach halten, solange der Server läuft / Bildschirm anlassen | Keep Mac awake while the server is running / Keep display on |
| Auch zugeklappt wach bleiben | Stay awake with the lid closed |
| Server neu starten / Protokoll öffnen / Jetzt verbinden | Restart Server / Open Log / Connect Now |
| App: Mit Apple anmelden / Deine Server / Server hinzufügen / Koppeln | Sign In with Apple / Your Servers / Add Server / Pair |
| App: Einstellungen → Apps verbinden | Settings → Connect Apps |

## Anhang B: Lesende Prüfbefehle (nur bei Bedarf)

Diese Befehle ändern nichts. Nutze sie nur, wenn die Server-App selbst keine klare Auskunft gibt.

```sh
# Antwortet der Server auf dem Mac? Richtig ist {"error":"Nicht angemeldet"} (Port ggf. aus den Einstellungen)
curl -s http://127.0.0.1:8787/api/health

# Welche Tailscale-Freigaben gibt es? (Tailscale aus /Applications)
TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale funnel status
```

Bei `funnel status` sollte eine Zeile mit `…ts.net:10000 (Funnel on)` und Ziel `http://127.0.0.1:<Port>` stehen,
wobei `<Port>` der Port aus den Einstellungen unter **Erreichbarkeit → Lokal** ist. Stimmt der Port nicht: in der
Server-App **Tailscale prüfen** klicken, nicht selbst umstellen.
