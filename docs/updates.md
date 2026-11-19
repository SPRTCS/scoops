# Updates der Mac-App „AIS Scoops Server“

Die App (Xcode-Ziel `ScoopsConnect`, Bundle `com.ais.scoopsconnect`) aktualisiert sich selbst über
[Sparkle](https://sparkle-project.org). Mit der App kommt auch der Python-Server neu, er liegt im Bundle unter
`Contents/Resources/server`.

## Wie es beim Nutzer abläuft

- Sparkle prüft beim ersten Start sofort, danach alle 3 Stunden (`SUScheduledCheckInterval`), und lädt eine neue
  Version still im Hintergrund.
- Installiert wird ohne Dialog, aber erst, wenn kein Scoop arbeitet: `App/ScoopsConnect/App/AppUpdater.swift`
  (`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`) fragt alle 15 s `GET /api/setup` ab
  (`server.active_runs`). Bei der Rechner-Rolle zählt auch eine laufende Steuerung dieses Macs. Nach zwei ruhigen
  Prüfungen hintereinander (etwa 30 s) wird installiert, spätestens aber nach 6 Stunden Wartezeit.
- Dann beendet Sparkle die App. Der Server stoppt dabei sauber mit (`applicationShouldTerminate`). Sparkle ersetzt
  das Bundle und startet die App neu, der Server fährt mit ihr wieder hoch.
- Während ein Update wartet, zeigt das Menü „Update … wird installiert, sobald kein Scoop arbeitet“. Von Hand: Menü
  bzw. Einstellungen › Updates › „Nach Updates suchen …“ (zeigt Sparkles Dialog).

## Wo was liegt

- **Feed und Downloads:** öffentliches Repo [`SPRTCS/ais-scoops-server`](https://github.com/SPRTCS/ais-scoops-server).
  Es enthält nur Releases und eine README, keinen Code. Der Code bleibt im privaten `SPRTCS/ais-scoops`.
  - Feed (`SUFeedURL`): `https://github.com/SPRTCS/ais-scoops-server/releases/latest/download/appcast.xml`
  - Neuinstallation: `https://github.com/SPRTCS/ais-scoops-server/releases/latest/download/AIS-Scoops-Server.dmg`
- **Sparkle-Schlüssel (EdDSA):** im Anmelde-Schlüsselbund von Armans Mac, Dienst `https://sparkle-project.org`,
  Account `ais-scoops-server`. Der öffentliche Teil steht als `SUPublicEDKey` in `App/project.yml`. Jedes Update muss
  mit diesem Schlüssel signiert sein, sonst installiert die App es nicht. Den privaten Schlüssel nie ausgeben, kopieren
  oder einchecken.
  - Sicherung oder Umzug auf einen anderen Mac: `generate_keys --account ais-scoops-server -x <Datei>` exportiert,
    `generate_keys --account ais-scoops-server -f <Datei>` importiert. Die Datei danach sicher löschen.
    `generate_keys` liegt nach einem Build unter
    `$TMPDIR/ais-scoops-server-build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
  - Geht der Schlüssel verloren, können installierte Apps keine Updates mehr annehmen. Dann hilft nur eine neue
    Version mit neuem Schlüssel, die jeder Nutzer einmal von Hand installiert.
- **Notarisierung:** App-Store-Connect-API-Schlüssel wie in `App/scripts/build-server-dmg.sh` (wird nur gelesen).

## Ein Release veröffentlichen

```sh
App/scripts/release-server.sh
NOTES="Kurzer Text, was neu ist" App/scripts/release-server.sh   # mit eigenem Text
PUBLISH=0 App/scripts/release-server.sh                           # nur bauen und Feed erzeugen, nichts veröffentlichen
```

Vorher committen: Das Skript bricht ab, wenn App- oder Server-Code nicht eingecheckt ist (`ALLOW_DIRTY=1` erzwingt).
Die Build-Nummer ist ein Zeitstempel (`YYYYMMDDHHMM`) und steigt damit von selbst. Sparkle vergleicht nur sie.

Das Skript:

1. lädt den veröffentlichten Feed (frühere Einträge bleiben erhalten, die letzten 10),
2. baut über `build-server-dmg.sh` (Developer ID, Hardened Runtime, Sparkle von innen nach außen signiert,
   notarisiert, gestapelt) die DMG und das Update-ZIP,
3. prüft `SUFeedURL` und `SUPublicEDKey` der gebauten App gegen Repo und Schlüsselbund,
4. signiert das ZIP mit `sign_update`. Dafür exportiert `generate_keys` den Schlüssel kurz in einen privaten
   Temp-Ordner, weil `sign_update` den Schlüsselbund-Eintrag nicht ohne Passwortabfrage lesen darf. Die Datei wird
   gleich danach überschrieben und gelöscht,
5. schreibt `appcast.xml` und legt Tag `v<Version>-<Build>` und GitHub-Release mit ZIP, DMG, `AIS-Scoops-Server.dmg`
   und `appcast.xml` an (`--latest`),
6. prüft ohne Anmeldung, dass der Feed die neue Build-Nummer zeigt und ZIP und DMG ladbar sind,
7. legt standardmäßig keine DMG auf den Schreibtisch, weil installierte Apps sich selbst aktualisieren (`DESKTOP=1` legt sie unter `~/Desktop/AIS Scoops Server.dmg` ab, z. B. für eine Erstinstallation).

Ein Release zurückziehen: das GitHub-Release löschen. Dann zeigt `latest` wieder auf das vorige mit dessen
`appcast.xml`. Bereits aktualisierte Apps bleiben auf der neuen Version, Sparkle stuft nicht herab.

## Testen

```sh
App/scripts/update-test.sh "<A>/AIS Scoops Server.app" ["<B>/AIS Scoops Server.app"]
```

Ende-zu-Ende-Test mit Kopien unter eigener Bundle-ID (`com.ais.scoopsconnect.updatetest`), Test-Schlüssel, lokalem
Feed (Port 8796), Testserver (Port 8797) und einem Platzhalter-Modell (Port 8798), das einen echten Scoop-Lauf
festhält. Er prüft: Download, keine Installation während des Laufs, stille Installation danach, Neustart von App und
Server. Der echte Server (8787) und eine laufende echte App bleiben unberührt, alle Reste werden entfernt. Die
Testkopie merkt sich ihren Testordner über den Einstellungsschlüssel `TestServerHome`. Die echte App liest ihn nie.

`xcodebuild` lädt Pakete mit `-packageAuthorizationProvider netrc`. Sonst fragt es nach dem github.com-Eintrag im
Schlüsselbund und hängt ohne sichtbaren Dialog.
