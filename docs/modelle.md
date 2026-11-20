# Modelle hinzufügen (Modellkatalog)

Welche KI-Modelle die Scoops nutzen können, steht in **einer Datei**: dem Modellkatalog. Server und Apps lesen ihn,
nichts davon ist mehr fest eingebaut. Ein neues Modell braucht deshalb **keinen neuen App-Build und kein
Server-Release**.

## Wo der Katalog liegt

| Ort | Wofür |
| --- | --- |
| [`models.json`](https://github.com/SPRTCS/ais-scoops-server/blob/main/models.json) im öffentlichen Repo `SPRTCS/ais-scoops-server` | **Hier trägst du neue Modelle ein.** Jeder Server lädt die Datei beim Start und danach etwa alle 24 Stunden. |
| `Server/src/aisbot/models_catalog.json` | Gebündelte Kopie, kommt mit jedem Server-Release. Gilt, solange die Fernkopie nicht neuer ist oder nicht erreichbar ist. |
| `<Datenordner>/models_catalog.json` | Zwischenspeicher der zuletzt übernommenen Fernkopie (übersteht Neustarts und Offline-Phasen). |

Es gilt immer der Katalog mit der **höchsten `version`**. Ist die Fernkopie fehlerhaft, gilt einfach weiter der
bisherige Katalog (der Server schreibt den Grund ins Protokoll, `GET /api/health` zeigt die aktive Version unter
`models_catalog`).

## Ein Modell hinzufügen

1. Auf GitHub [`models.json`](https://github.com/SPRTCS/ais-scoops-server/edit/main/models.json) öffnen (Stift-Symbol).
2. Unter `models` einen Eintrag ergänzen, z. B.:

   ```json
   {"id": "gpt-6.3-nova", "label": "GPT-6.3 Nova", "provider": "openai", "hint": "Neu, sehr stark", "rank": 50,
    "price": {"input": 3.00, "output": 15.00, "cache_read": 0.30, "cache_write": 3.00},
    "routes": ["api", "chatgpt_abo"]}
   ```

3. **`version` erhöhen** (Datum plus laufende Nummer, z. B. `2026112001`). Ohne höhere Version übernimmt kein Server
   die Änderung.
4. Speichern („Commit changes“).

**Wie schnell kommt es an?** GitHub liefert die neue Datei nach wenigen Minuten aus. Jeder Server holt sie beim
nächsten Start oder spätestens nach etwa 24 Stunden. Sofort geht es mit einem Neustart des Servers (z. B. Mac-App „AIS
Scoops Server“ beenden und wieder öffnen). Die Apps laden die Liste beim nächsten Verbinden neu, ein laufender Server meldet
den Wechsel außerdem sofort per `models.updated`.

## Felder

| Feld | Pflicht | Bedeutung |
| --- | --- | --- |
| `id` | ja | Kennung beim Anbieter. Nur `claude-…` (Anthropic) oder `gpt-…` (OpenAI), Kleinbuchstaben, Ziffern, `.` und `-`. |
| `label` | ja | Anzeigename in der App, z. B. „Fable 5.2“. |
| `provider` | ja | `anthropic` oder `openai`, muss zur Kennung passen. |
| `hint` | nein | Kurzer deutscher Hinweis unter dem Namen („Schnell & günstig“). |
| `hint_en` | nein | Englische Fassung des Hinweises (höchstens 80 Zeichen). Fehlt sie, übersetzt der Server bekannte Hinweise aus seiner Tabelle (`i18n_en/kataloge.py`), sonst bleibt der deutsche Hinweis ([sprache.md](sprache.md)). |
| `rank` | ja | Stärke innerhalb des Anbieters (größer = stärker). Bestimmt Reihenfolge und Verstärkung. |
| `price` | ja | US-Dollar pro 1 Mio. Tokens: `input`, `output`, `cache_read`, `cache_write`. Cache-Werte dürfen fehlen (dann 10 % bzw. 125 % der Eingabe). |
| `routes` | nein | Wege: `api` (API-Schlüssel), `claude_abo` (Claude-Abo über Claude Code), `chatgpt_abo` (ChatGPT-Abo über Codex). Standard nur `api`. |
| `features` | nein | Nur Claude: `web_new` (neue Websuche/Web-Abruf) und `fallback` (Ausweichen bei Ablehnung, `fallbacks: "default"`). Bei neuen großen Claude-Modellen meist beide. |
| `replaces` | nein | Alte Kennungen, die dieses Modell ablöst. |
| `deprecated` | nein | `true` = nicht mehr wählbar, bleibt nur für Anzeigenamen und Preise alter Läufe. |
| `pricing_only` | nein | `true` = nur für die Bewertung der Nutzungsseite (Modelle anderer Apps), nie wählbar. |

Oben in der Datei legt `defaults` je Anbieter das Startmodell neuer Scoops (`model`) und die Verstärkung
(`escalation`) fest.

## Ein Modell ablösen (z. B. GPT-6.1 Sol → GPT-6.2 Sol)

1. Neues Modell eintragen mit `"replaces": ["gpt-6.1-sol"]`.
2. Beim alten Eintrag `"deprecated": true` setzen. **Nicht löschen:** Sein Preis bewertet weiter die alte
   Kostenhistorie.
3. `version` erhöhen.

Die Server stellen dann Scoops, Routinen und offene Aufgaben mit der alten Kennung automatisch auf das neue Modell um.
Ältere Apps, die noch die alte Kennung schicken, werden ebenfalls auf das neue Modell abgebildet.

## Was der Server prüft

Eine Fernkopie wird nur übernommen, wenn alles stimmt: Schema 1, ganzzahlige höhere `version`, nur `claude-…`/`gpt-…`
Kennungen, Anbieter passt zur Kennung, plausible Preise (Eingabe 0,001–500 $, Ausgabe nicht billiger als Eingabe,
Cache-Lesen nicht teurer als Eingabe), Wege passen zum Anbieter, Standardmodelle sind wählbar, höchstens 256 KB. Außerdem
darf **kein bekanntes Modell verschwinden**: Alles, was der Server schon kennt, muss in der Datei bleiben (notfalls als
`deprecated`) oder über `replaces` abgelöst sein.

## Prüfen, ob ein Modell wirklich läuft

`Server/bin/modellprobe` (auf dem Server-Mac) schickt je wählbarem Modell einen Minimalaufruf mit den hinterlegten
API-Schlüsseln (zusammen deutlich unter einem Cent) und zeigt ✓/✗. `Server/bin/modellprobe gpt-6.3-nova` prüft nur ein
Modell. Für die Fernkopie vorher einmal lokal prüfen:

```bash
cd Server && .venv/bin/python -c "import json,sys; sys.path.insert(0,'src'); from aisbot import models_catalog as m; \
print(m.validate(json.load(open('/pfad/zu/models.json')), require=m.bundled()).version)"
```

## Bei Server-Releases

Die gebündelte Datei `Server/src/aisbot/models_catalog.json` und `models.json` im Release-Repo sollten gleich sein. Wer
ein Modell zuerst auf GitHub einträgt, übernimmt die Änderung beim nächsten Release in die gebündelte Datei (gleiche
oder höhere `version`).

Abschalten oder andere Adresse: `config.json` → `"models_url": ""` (aus) bzw. eigene URL; Umgebung `AISBOT_MODELS_URL`
hat Vorrang.
