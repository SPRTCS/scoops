# Apple-Watch-App „AIS Scoops“

Die Uhren-App wird mit der iOS-App ausgeliefert (`AIS Scoops.app/Watch/AIS Scoops.app`, Bundle-ID
`com.ais.aisbot.watchkitapp`, watchOS 26+). Ziele in `App/project.yml`: `AISBotWatch` (App), `AISBotWatchWidgets`
(Komplikationen, `com.ais.aisbot.watchkitapp.widgets`) und `WatchLogicTests` (Logik-Tests auf dem Mac).

## Was die Uhr kann

- **Scoops und Gruppen** mit Maskottchen bzw. eigenem Bild, Ungelesen-Zähler, rotem „?“ (wartet auf dich) und
  Arbeitsanzeige. Angeheftete zuerst, dann nach letzter Aktivität.
- **Chat:** die letzten 30 Nachrichten, Markdown vereinfacht (Überschriften fett, Listen mit „•“, Tabellen als Zeilen),
  lange Nachrichten gekürzt mit „mehr“. Laufende Arbeit als Statuszeile, „Anhalten“ in der Symbolleiste.
- **Eingabe:** „Antworten“ öffnet Diktat, Scribble oder Tastatur (Systemeingabe der Uhr) und Schnellantworten.
- **Freigaben:** Karte im Chat mit Freigeben / Ablehnen / „Immer erlauben“ (nur wenn der Server `can_always` meldet,
  mit Rückfrage). Übersicht „Offene Freigaben“ über alle Scoops. Logins speichern geht nur am iPhone (Passwort).
- **Mitteilungen:** Freigabe-Pushes haben ab Server 1.32 Knöpfe (siehe API.md v1.32). Auf der Uhr erscheinen sie an
  gespiegelten iPhone-Mitteilungen; die Uhren-App registriert dieselben Kategorien und entscheidet selbst, das iPhone
  ebenso (`NotificationManager`), auch wenn die App nicht läuft.
- **Komplikationen** (auch im Smart Stack):
  - „Offene Freigaben“: Zahl offener Freigaben (rund, Ecke, rechteckig mit erster Freigabe, Zeile). Antippen öffnet
    die Übersicht. Mit offenen Freigaben steigt die Relevanz im Smart Stack.
  - „Scoop“ (konfigurierbar per App Intent `SelectScoopIntent`): beim Einrichten des Zifferblatts erscheint jeder Scoop
    als eigene Komplikation (`recommendations()`), mehrere gleichzeitig möglich. Zeigt den Avatar (rund), mit Name,
    Ungelesen und letzter Nachricht (Ecke/rechteckig/Zeile). Antippen öffnet den Chat mit der Eingabe
    (`aisscoops-watch://chat/<id>?compose=1`); Diktat ist dann einen Tipp entfernt.

## Wie die Uhr den Server erreicht

1. Das iPhone (`App/AISBot/Support/WatchBridge.swift`) schickt per WatchConnectivity (`updateApplicationContext`,
   zwischen gekoppelten Geräten verschlüsselt) die Server der Uhr: den verbundenen Server (API-Token oder Konto) und
   alle Konto-Server aus „Deine Server“, dazu das Sitzungs-JWT des Kontos und eine Kurzfassung der Chats. Im
   Demo-Modus (`-mock`) nur `demo: true`.
2. Die Uhr speichert das nur im Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) und spricht dann
   **selbst** per URLSession mit dem Server: über das iPhone als Netzwerk-Proxy, wenn es in der Nähe ist, sonst über
   WLAN/LTE. Dafür muss der Server von außen erreichbar sein (öffentliche Adresse, z. B. Tailscale Funnel).
3. Läuft das JWT in weniger als 24 h ab oder antwortet der Server mit 401, fragt die Uhr das iPhone nach frischen
   Zugangsdaten (das iPhone erneuert die Sitzung, wenn sie in weniger als drei Tagen abläuft). Die Uhr erneuert nie
   selbst (keine konkurrierenden Refresh-Tokens).
4. Erreicht die Uhr den Server nicht (z. B. nur Tailnet-Adresse), reicht sie die Anfrage ans iPhone weiter
   (`WatchLink.Kind.relay`, nur `/api/…`, nur bekannte Server; schreibende Anfragen nur, wenn sie den Server sicher nicht
   erreicht haben).
5. Kein WebSocket (watchOS erlaubt das Apps nicht): Ein offener Chat lädt alle 2,5–6 s nach, die Liste beim Öffnen
   und etwa alle 20–30 min im Hintergrund (für die Komplikationen).

Tokens erscheinen in keinem Log; `description` der Typen blendet sie aus. Mehrere Server: in der Liste unten „Server“.

## Daten der Komplikationen

Die Uhren-App schreibt nach jedem Laden `WatchWidget/snapshot.json` und vorgerenderte Avatare (`a-<id>-<hash>.png`,
100 px) in die App-Gruppe `group.com.ais.aisbot` der Uhr. Die Erweiterung liest nur diese Dateien.

## Testen

- Logik: `xcodebuild -project App/AISBot.xcodeproj -scheme WatchLogicTests -destination platform=macOS test`
- Simulator mit Demo-Daten: Startargumente `-demo`, optional `-open approvals` bzw. `-open chat:b_lucy [-compose]`.
- Screenshots für App Store Connect: `App/Screenshots/watch/` (nicht im Repo).

## Signierung

App-IDs `com.ais.aisbot.watchkitapp` und `com.ais.aisbot.watchkitapp.widgets` sind registriert (Fähigkeit App Groups,
Gruppe `group.com.ais.aisbot`). Lokal scheiterte `xcodebuild archive` mit nur dem API-Key an der ersten Zuordnung der
App Group („Authentication failed“); mit dem in Xcode angemeldeten Konto und `-allowProvisioningUpdates` lief das Archiv
durch. Seitdem ist die Zuordnung im Portal gesetzt, Xcode Cloud signiert selbst.
