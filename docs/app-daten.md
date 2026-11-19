# Daten aus verbundenen Apps (Server 1.24, Notion direkt 1.25)

Wie die Scoops Daten aus Notion, Gmail, Kalender & Co. bekommen, und warum sie dabei vollständige statt
abgeschnittener Ergebnisse sehen.

## Das Problem

Die Scoops nutzen Apps über den Composio-Tool-Router (MCP-Server `composio`, Werkzeug
`COMPOSIO_MULTI_EXECUTE_TOOL`). Ist eine Antwort groß, liefert der Tool Router nur eine **Vorschau**:

- `data.results[i].response.data_preview` mit wenigen Zeilen, verschachtelte Werte als `"{object}"`
  (z. B. `"date":"{object}"` statt der Fälligkeit),
- `data.remote_file_info`: „Complete response was large (… tokens). Full data saved to sandbox in /mnt/files/mex/….json“,
- `next_steps`: Das Modell soll die Datei mit `COMPOSIO_REMOTE_WORKBENCH` (Python) auswerten.

Die Grenze gilt für die **ganze** Antwort: Ist ein Teilaufruf groß, bekommen alle Teilaufrufe nur eine Vorschau.
Schwache Modelle werten die Datei nicht aus, sondern bauen Listen aus alten Chat-Nachrichten zusammen. So hat
der Scoop „Tina“ Fälligkeitsdaten von Notion-Tasks erfunden.

## Die Lösung: `Server/src/aisbot/composio_direct.py`

`MCPHub.call` gibt jeden Aufruf von `COMPOSIO_MULTI_EXECUTE_TOOL` an `ComposioDirect.multi_execute` (gesetzt in
`server.py`). Das gilt für alle Nutzer und Server, ohne Einstellungen.

### 1. Lesende Werkzeuge direkt ausführen

**Entscheidung:** Eindeutig lesende Werkzeuge führt der Server **gleich selbst** per REST aus, statt erst die
Vorschau abzuwarten und dann nachzuholen.

- **Warum:** Nachholen hieße, jede große Abfrage zweimal auszuführen (doppelte Zeit, doppelte API-Last). Direkt
  kostet einen Aufruf und liefert immer die vollständigen Daten. Gemessen bei 100 Notion-Tasks: etwa 1 s für den
  REST-Aufruf.
- **Wie:** `POST https://backend.composio.dev/api/v3/tools/execute/<SLUG>`, Header `x-api-key` (Composio-Schlüssel
  aus dem Schlüsselbund). Body: `user_id` = `composio_user_id` der Installation, `connected_account_id`,
  `version: "latest"` (dieselbe Werkzeugversion wie beim Tool Router), `arguments` unverändert.
- **Lesend** heißt: Das erste oder letzte Wort nach dem App-Namen ist QUERY, LIST, GET, SEARCH, FETCH, RETRIEVE,
  FIND oder READ, und **kein** schreibendes Wort steht im Namen (CREATE, UPDATE, DELETE, SEND, ADD, MOVE, ARCHIVE,
  RUN, EXECUTE, MARK, SET … siehe `WRITE_WORDS`). Im Zweifel gilt ein Werkzeug als schreibend und geht an den
  Tool Router. Beispiele: `NOTION_QUERY_DATABASE`, `GMAIL_FETCH_EMAILS` und `GOOGLECALENDAR_EVENTS_LIST` sind
  lesend. `NOTION_UPDATE_PAGE`, `SNOWFLAKE_RUN_QUERY` und `GITHUB_GET_OR_CREATE_…` sind es nicht.
- **Konto:** Der Tool Router wählt das Konto über `tools[].account` (Alias oder Konto-ID). Der Server löst das
  genauso auf, über Alias, E-Mail oder ID (`Connections.accounts`). Ohne Angabe nimmt er das einzige aktive Konto
  der App. Hat die App **mehrere** Konten und der Scoop nennt keins, entscheidet weiter der Tool Router. Der
  Server rät kein Konto.

### 2. Rückfall auf den Tool Router

Folgende Fälle gehen an den Tool Router, mit denselben übrigen Feldern (`thought`, `current_step` …):

- schreibende und unklare Werkzeuge,
- mehrere Konten ohne Angabe,
- Fehler der Composio-API (Werkzeug oder Konto per REST unbekannt, Ausfall).

Ein **Werkzeugfehler** wie falsche Argumente oder fehlende Notion-Freigabe ist dagegen ein Ergebnis und kommt
ehrlich zurück. Es gibt keinen zweiten Versuch und keine doppelte Ausführung.

Liefert der Tool Router für ein lesendes Werkzeug doch eine Vorschau, holt der Server es per REST nach. Bleibt
eine Vorschau übrig (schreibendes Werkzeug, Konto unklar), steht oben im Ergebnis ein `hinweis`: nur Vorschau,
nichts daraus zusammenbauen, nichts aus alten Nachrichten ergänzen, gezielter nachladen. Die Vorschau selbst
steht unter `vorschau`, nicht unter `data`.

### 3. Kompaktieren

`compact()` gilt für alle Apps:

- **entfernt:** `null`, leere Texte, Listen und Objekte; Metadaten wie `request_id`, `object` und `parent`; URLs
  (`url`, `*_url`, `*Link`, `href`); `icon`, `cover`, `created_by` und `last_edited_by`; Base64-Daten (ersetzt
  durch „[Binärdaten, N Zeichen]“),
- **macht flach:** Objekte mit nur einem Schlüssel (`{"a":{"b":1}}` wird zu `{"a.b":1}`),
- **kürzt:** sehr lange Texte ab 6.000 Zeichen.

IDs von Datensätzen bleiben bewusst erhalten (Notion-Seiten-ID, Gmail `threadId`/`messageId`, Kalender-Termin-ID),
weil die Scoops damit gezielt antworten oder ändern.

**Notion-Seiten** werden zu `{"id": …, "<Eigenschaft>": <Wert>, "created_time", "last_edited_time"}`:

| Notion-Typ | Wert |
|---|---|
| `title`, `rich_text` | Text |
| `date` | `"2026-11-16"` bzw. `{"start","end"}` |
| `status`, `select` | Name |
| `multi_select` | Liste der Namen |
| `people`, `created_by` | Namen (sonst „N Person(en)“) |
| `relation` | Titel der verknüpften Seiten, sonst „N verknüpft“ |
| `formula`, `rollup` | berechneter Wert |
| `checkbox`, `number`, `url`, `email`, `phone_number` | Wert (auch `false` und `0`) |
| `unique_id`, `files`, `verification` | Kurzform |

Verknüpfte Seiten bekommen ihre Titel aus demselben Ergebnis. Fremde Seiten schlägt der Server mit
`NOTION_FETCH_ROW` nach: höchstens 25 je Aufruf, parallel, 15 Minuten zwischengespeichert. Datenbanken werden zu
Titel plus Eigenschafts-Schema (`select: a | b | c`).

### 4. Obergrenze und ehrliche Hinweise

Die ganze Antwort ist höchstens 40.000 Zeichen lang (`LIMIT`), aufgeteilt auf die Teilaufrufe. Ist sie zu groß,
wird die größte Zeilenliste gekürzt. Dazu kommt ein Hinweis: „Gekürzt: N von M Zeilen dieser Seite gezeigt … frag
sie gezielt ab (Filter oder kleinere Seitengröße) statt sie zu raten.“ Meldet die App weitere Seiten
(`has_more`/`next_cursor`, `nextPageToken`), steht im Hinweis: „N Zeilen geladen. Es gibt weitere …“ mit dem Cursor.

Zusätzlich steht in der Systemanweisung (`prompts.py`, Arbeitsweise): Werkzeugdaten nie aus Vorschauen, gekürzten
Antworten oder alten Chat-Nachrichten ergänzen. Fehlt etwas, nachladen oder sagen, was fehlt.

### Messung (Armans Server, Notion-Tasks, 100 Zeilen)

| | Größe | Inhalt |
|---|---|---|
| Tool Router | Vorschau mit 2 Zeilen, Datum `"{object}"`, Rest in der Sandbox | unbrauchbar |
| REST roh | 262.856 Byte | vollständig |
| kompakt (1.24) | 25.460 Zeichen | 100 Zeilen mit Titel, Fälligkeit, Status, Bereich (Titel), KW, ID |

## Tests

`Server/tests/test_composio_direct.py` (Composio komplett gemockt) prüft:

- welche Werkzeuge als lesend gelten,
- die Direktausführung mit gleichem User, Konto und gleichen Argumenten,
- dass schreibende Werkzeuge nie per REST laufen,
- Reihenfolge und Mischung mit dem Tool Router,
- Vorschau nachholen bzw. Hinweis, Rückfälle, Obergrenze und Kompaktieren.

## Notion direkt (Server 1.25, `Server/src/aisbot/notion_mcp.py`)

Eigene MCP-Server beliebiger Anbieter (z. B. Qonto) mit demselben OAuth-Muster: [mcp.md](mcp.md) (Server 1.35).

Notion hat einen eigenen, offiziellen MCP-Server: `https://mcp.notion.com/mcp`. Seine Antworten sind kompakt,
Seiten kommen als Markdown. Zeilen einer Datenbank liefert er über Ansichten oder SQL
(`notion-query-data-sources`). Ist er verbunden, nutzen die Scoops ihn statt Composio-Notion. Ohne ihn bleibt alles
wie oben (Composio-Notion mit 1.24-Fix).

### Für Nutzer

„Apps verbinden“ › Notion › Verbinden › optionalen Namen eingeben › bei Notion anmelden und Seiten freigeben.
Danach erscheint unter Notion das Konto „Notion direkt“ mit dem Workspace-Namen. Darüber lässt es sich umbenennen,
neu anmelden oder trennen. Bereits verbundene Composio-Notion-Konten bleiben sichtbar und lassen sich trennen.

### Anmeldung ohne Handarbeit (OAuth 2.1)

Stand der Doku und live geprüft am 16.11.2026:
[build-mcp-client](https://developers.notion.com/guides/mcp/build-mcp-client),
`https://mcp.notion.com/.well-known/oauth-authorization-server`.

1. **Metadaten:** `/.well-known/oauth-authorization-server` liefert `/authorize`, `/token` (auch Widerruf) und
   `/register`. PKCE gibt es nur mit S256, Scope `default`.
2. **Dynamic Client Registration (RFC 7591):** offen und ohne Konto. Jeder Server registriert sich beim ersten
   Verbinden selbst als öffentlicher Client (`token_endpoint_auth_method: none`). Die `client_id` bleibt im
   Schlüsselbund und wird wiederverwendet. Eine neue Registrierung würde laut Notion frühere Anmeldungen verwaisen
   lassen.
3. **Redirect:** `aisscoops://oauth/notion`, das URL-Schema der App. Notion erlaubt eigene Schemata, HTTPS und
   Loopback, lehnt aber `http://name.local` ab („Redirect URI must use HTTPS unless it is a loopback HTTP URI“).
   Deshalb nicht die Server-Adresse: Das Schema funktioniert auf jedem Server, egal ob Tailscale, LAN oder nur
   lokal. Notion-Enterprise-Admins sehen alle Installationen als dieselbe App, weil Notion Clients am Redirect
   erkennt.
4. **Ablauf:**
   - Die App schickt `POST /api/connections/notion/link` mit `{"alias", "native": true}`.
   - Der Server registriert sich bei Bedarf, erzeugt PKCE-Verifier und `state` (nur im Speicher, 15 Minuten) und
     antwortet mit `{url, account_id: "notion-mcp", callback_scheme: "aisscoops"}`.
   - Die App öffnet `url` in ASWebAuthenticationSession mit Rücksprung-Schema `aisscoops` und gibt die
     Rücksprung-Adresse an `POST /api/connections/oauth/callback` (`{"url": "aisscoops://oauth/notion?code=…&state=…"}`).
   - Der Server tauscht den Code gegen Tokens (mit `code_verifier` und `resource`), speichert sie und lädt den
     MCPHub neu.
   - Kommt der Rücksprung ausnahmsweise über `onOpenURL` an, reicht die App ihn genauso weiter.
5. **Tokens:** im Schlüsselbund, Dienst `<prefix>-notion-mcp`, Konto `oauth` (JSON, Base64). Geschrieben über
   `security -i` (stdin), damit nichts in der Prozessliste steht.
   - Das Access-Token gilt etwa 8 h und wird 5 Minuten vor Ablauf automatisch erneuert, immer nur einmal
     gleichzeitig.
   - Das Refresh-Token wird bei jeder Erneuerung ersetzt und sofort gespeichert.
   - Antwortet der MCP mit 401, erneuert der Server einmal und wiederholt den Aufruf.
   - Bei `invalid_grant` gilt die Verbindung als abgelaufen: kein weiterer Versuch. Das Konto zeigt „expired“,
     die App bietet „Neu anmelden“, der Hub fällt auf Composio-Notion zurück.
   - Refresh-Tokens halten laut Notion höchstens 180 Tage. Danach einmal neu anmelden.
6. **Trennen:** Der Server widerruft das Token bei Notion (best effort) und löscht es. Die Registrierung bleibt.

### Einbindung

- **MCPHub:** Server `notion` mit der URL `https://mcp.notion.com/mcp`, das Token holt der Hub bei jedem Aufruf
  frisch (`MCPServer.token` darf eine Funktion sein). Immer geladen sind `notion-search`, `notion-fetch`,
  `notion-query-data-sources`, `notion-update-page` und `notion-create-pages`. Die übrigen Werkzeuge gibt es über
  die Werkzeugsuche.
- **Composio-Notion ausblenden:** Solange Notion direkt Werkzeuge liefert, lehnt der Hub `NOTION_*` über
  Composio ohne ausdrückliches `account` ab und verweist auf `notion__…`. Mit `account` bleibt ein zweiter
  Workspace über Composio möglich. Ist Notion direkt gestört (keine Werkzeuge), läuft Composio-Notion wie bisher.
- **Systemanweisung:** Die Systemanweisung bekommt einen Zusatz, solange Notion direkt verbunden ist:
  „Notion ist direkt verbunden … nur diese Werkzeuge …“ (`notion_mcp.PROMPT_HINT`).
- **Gäste:** Wer Composio-Notion für einen geteilten Scoop freigibt, gibt damit auch Notion direkt frei.
- **Ältere Apps:** Sie schicken kein `native` und verbinden Notion weiter über Composio. Das Konto „Notion direkt“
  sehen sie trotzdem und können es trennen.

### Einschränkungen (Notion)

- SQL-Abfragen auf Datenbanken sind nur bei Business und Enterprise mit Notion AI unbegrenzt. Andere Pläne teilen
  sich ein Kontingent pro Workspace. Abfragen über gespeicherte Ansichten gehen in jedem Plan.
  `notion-query-multiple-data-sources` braucht Business oder Enterprise mit Notion AI.
- Enterprise-Workspaces können eigene MCP-Clients sperren oder freigeben lassen.
- Ein Notion-MCP-Token gilt nur für den MCP, nicht für die Notion-REST-API.

### Tests

`Server/tests/test_notion_mcp.py` (Notion komplett gemockt, Schlüsselbund im Speicher) prüft:

- Registrierung, PKCE und `state`,
- Rücksprung inklusive Fehlerfälle,
- Erneuern mit Rotation, `invalid_grant` und Ablauf,
- Trennen,
- Hub: 401 mit erneutem Versuch, Composio-Notion ausblenden, Gäste,
- die API-Endpunkte.
