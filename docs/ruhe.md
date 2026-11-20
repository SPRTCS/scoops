# Stummschalten und Ruhezeiten

Stand: App 1.3. Umsetzung: `Server/src/aisbot/ruhe.py`, `push.py`; App: `App/AISBot/Ruhe/`, `App/Shared/Models/Ruhe.swift`.

Zwei Wege, weniger gestört zu werden:

- **Stummschalten** gilt für einen Chat (Scoop oder Gruppe): keine Mitteilungen mehr aus diesem Chat.
- **Ruhezeiten** gelten für alles: In der Ruhezeit kommen Mitteilungen still an.

Beides liegt auf dem Server und gilt **pro Person**, für den Inhaber und getrennt für jeden Gast eines geteilten Scoops
([sharing.md](sharing.md)). So gilt es auf allen Geräten, und Mitteilungen fallen schon an der Quelle weg, also auch auf
der Apple Watch und bei geöffneter App.

## Stummschalten

- In der App: Scoop oder Gruppe in der Seitenleiste gedrückt halten (Mac: Rechtsklick) → **Stummschalten** mit
  **1 Stunde**, **8 Stunden**, **Bis morgen früh** (das nächste 7:00 Uhr auf dem Gerät) oder **Dauerhaft**. Danach steht
  dort **Stummschaltung aufheben**. Dasselbe im Profil unter **Mitteilungen**.
- Stumme Chats zeigen eine durchgestrichene Glocke. Der Punkt für Ungelesenes bleibt, ist aber grau. Am App-Symbol
  zählen stumme Chats nicht mit.
- Bei einem geteilten Scoop schaltet jede Person nur für sich stumm. Der Admin sieht nicht, wer stummgeschaltet hat.
- Live-Aktivitäten und Widgets bleiben unverändert.
- Seite „Heute“ ([heute.md](heute.md)): Freigaben stummer Chats stehen weiter unter „Wartet auf dich“ und zählen am
  Eintrag „Heute“ mit. Ungelesene stumme Chats stehen unter „Seit gestern erledigt“ hinter den anderen, grau.
- Befehlspalette: „<Chat> stummschalten“ (bis morgen früh) bzw. „Stummschaltung … aufheben“ für den geöffneten Chat,
  „Ruhezeiten“ öffnet das Blatt direkt.

## Ruhezeiten

Einstellungen → **Mitteilungen** → **Ruhezeiten**: an oder aus, **Von** und **Bis**, Wochentage, **Freigaben trotzdem
melden** (Standard an).

- In der Ruhezeit kommen Mitteilungen ohne Ton und Banner an und stehen nur in der Mitteilungszentrale
  (APNs `interruption-level: passive`, Priorität 5).
- Eine Ruhezeit über Mitternacht (22:00 bis 07:00) gehört zu dem Wochentag, an dem sie beginnt: „Mo bis Fr“ heißt
  Montagabend bis Samstagmorgen. Von = Bis heißt den ganzen Tag.
- **Zeitzone:** Gerechnet wird in der Zeitzone des Geräts, auf dem die Ruhezeit eingestellt wurde (IANA-Kennung wie
  `Europe/Berlin`), nicht in der des Servers. Sommer- und Winterzeit stimmen damit von selbst. iPhone und iPad melden
  eine geänderte Zeitzone beim nächsten Verbinden (Reisen), der Mac ändert sie nur beim Speichern.
- Wer nur Gast ist (kein eigener Server), stellt die Ruhezeit genauso ein. Die App gibt sie an die Server der Admins
  weiter, dort gilt sie für diese Person.

## Was trotzdem durchkommt

| Mitteilung | Chat stumm | Ruhezeit |
|---|---|---|
| Antwort eines Scoops, Nachricht einer Person | keine Mitteilung | still |
| **Freigabe-Anfrage** | normal | normal; still, wenn „Freigaben trotzdem melden“ aus ist |
| **Erinnerung** auf eine Uhrzeit (`erinnerung_setzen`) | normal | normal |
| Ergebnis einer Routine | keine Mitteilung | still |

Begründung: Wartet ein Scoop auf eine Freigabe, bleibt er sonst unbemerkt hängen. Eine Erinnerung hat jemand
ausdrücklich auf eine Uhrzeit gelegt; sie still zuzustellen hieße, sie zu verlieren. Freigaben aus geteilten Scoops
gehen wie bisher nur an den Admin.

## Routinen, Erinnerungen und der Haupt-Scoop

- **Erinnerungen** feuern zur gesetzten Zeit, auch in der Ruhezeit, und melden sich mit Ton. Nichts wird verschoben.
- **Routinen** laufen nach ihrem Zeitplan weiter. Ihr Ergebnis steht im Chat; die Mitteilung dazu kommt in der Ruhezeit
  still an.
- **Initiative des Haupt-Scoops** (`/api/settings/initiative`): In der Ruhezeit des Inhabers meldet er sich nicht von
  selbst. Fällt ein Check hinein (zum Beispiel 7:30 bei Ruhezeit bis 8:00), merkt der Server ihn vor und holt ihn
  einmal direkt nach dem Ende der Ruhezeit nach, höchstens 12 Stunden später. Die eigene Ruhezeit der Initiative
  (`quiet_start`/`quiet_end`, Serverzeit) gilt unverändert zusätzlich.
- Wird eine pausierte Routine wieder eingeschaltet, läuft sie zum nächsten Termin laut Zeitplan und nicht sofort, auch
  wenn ihr alter Termin verstrichen ist.

## API

Scoop- und Gruppen-JSON tragen `mute`:

```json
"mute": {"muted": true, "until": "2026-11-20T06:00:00+00:00"}
```

`until: null` bei `muted: true` heißt dauerhaft. Das Feld ist immer da; daran erkennt die App, dass der Server
stummschalten kann (ältere Server liefern es nicht, die App blendet den Menüpunkt dann aus). Gäste sehen im Scoop-JSON
ihre eigene Stummschaltung, nie die des Admins.

| Methode | Pfad | Wer | Body | Antwort |
|---|---|---|---|---|
| PUT | `/api/chats/{chat_id}/mute` | Inhaber; Gäste ab Rolle Lesen für geteilte Scoops | `{"forever": true}` oder `{"until": "<ISO mit Zone>"}` oder `{"minutes": 60}`; `{}` hebt auf | `{"chat_id", "mute": {…}}` |
| GET | `/api/settings/quiet-hours` | Inhaber; Gäste mit mindestens einem Share | – | `{"enabled", "start": "22:00", "end": "07:00", "days": [1…7], "approvals", "timezone", "active"}` |
| PATCH | `/api/settings/quiet-hours` | wie GET | beliebige Felder davon | wie GET |

- `days`: 1 = Montag bis 7 = Sonntag. `active`: gerade Ruhezeit. Standard: aus, 22:00 bis 07:00, alle Tage,
  `approvals: true`, `Europe/Berlin`.
- Fehler: 400 mit Text (Zeitpunkt in der Vergangenheit, länger als ein Jahr, ungültige Uhrzeit, unbekannte Zeitzone),
  404 unbekannter Chat, 403 für Gäste bei nicht geteilten Scoops und bei Gruppen.
- Nach dem Stummschalten kommt `bot.updated` bzw. `group.updated` an die Geräte dieser Person, nach `PATCH` das Ereignis
  `quiet_hours.updated` (gleiche Daten wie GET). Läuft eine befristete Stummschaltung ab, räumt der Planer sie
  innerhalb von 15 Sekunden weg und meldet es ebenso.
- `GET /api/health` meldet `"mute": true` und `"quiet_hours": true`, `GET /api/shared/me` für Gäste dasselbe.
- Mitteilungen zu Erinnerungen tragen zusätzlich `"reminder": true` neben `aps`.

Tabellen: `mutes (user_id, chat_id, until, created_at)` und `quiet_hours (user_id, value, updated_at)`; `user_id` ist
beim Inhaber leer, bei Gästen die Konto-ID.

## Alte und neue Versionen

- Neue App, alter Server: „Stummschalten“ fehlt in Menü und Profil, „Ruhezeiten“ ist ausgegraut („Server aktualisieren“).
- Alte App, neuer Server: unverändert. Das Feld `mute` und stille Mitteilungen brauchen keine App-Änderung; einstellen
  lässt sich beides dann nur über ein Gerät mit der neuen App.

## Tests

`cd Server && uv run python tests/test_ruhe.py` (88 Prüfungen: Zeitzonen und Sommerzeit, Stummschalten pro Person,
Mitteilungen über ein Fake-Relay, Freigaben und Erinnerungen, Ruhezeit eines Gasts, Initiative, Routinen). In der App:
`WatchLogicTests/RuheTests.swift`. Demo-Modus: `-mock -mutedemo` zeigt stumme Chats, `-mock -settings -quiethours` das
Blatt „Ruhezeiten“.
