# Eigene MCP-Server (Server 1.35)

Jeder Nutzer kann eigene MCP-Server anbinden, so wie Atrium und die Team App auf Armans Server fest eingebaut sind.
Das gilt für alle Editionen. Anlass war der offizielle Qonto-MCP (`https://mcp.qonto.com/mcp`).

Code: `Server/src/aisbot/custom_mcp.py` (Liste, Schlüsselbund, Erkennen, OAuth, Freigabe-Hülle), `mcp_client.py`
(Header-Wahl, Fehlertext, Namensumsetzung), `bots.py` (Freigabe-Karten, Chat-Werkzeuge, `mcp_gate`), `server.py`
(API), App: `App/AISBot/Views/CustomMCPSection.swift`, `Views/Chat/MCPCards.swift`.
Tests: `Server/tests/test_custom_mcp.py` (mit `tests/fake_mcp.py`), Probedurchlauf Ablauf 18.

## Für Nutzer

**In der App:** „Apps verbinden“ › Bereich **„Eigene MCP-Server“** › **„MCP-Server hinzufügen“**. Name und Adresse
eingeben; die App fragt den Server, ob er eine Anmeldung braucht („Keine“, „Token“ oder „Anmeldung (OAuth)“), die
Auswahl lässt sich ändern. Bei OAuth öffnet sich gleich die Anmeldung beim Anbieter (wie bei Notion direkt). Unter
„Erweitert: lokaler Befehl“ lässt sich ein Programm auf dem Server-Mac starten (stdio, z. B. `Atrium --mcp`).
Jede Zeile zeigt einen Status-Punkt (grün ok, rot Fehler, orange Anmeldung nötig) und die Werkzeuganzahl; über das
Menü: Umbenennen, Neu anmelden bzw. Token ändern, Verbindung testen, Entfernen (mit Nachfrage).

**Im Chat:** „Verbinde bitte den Qonto-MCP.“ Der Scoop sucht die Adresse bei bekannten Diensten selbst, prüft den
Server (`mcp_server_pruefen`) und legt eine **Freigabe-Karte** an (`mcp_server_verbinden`), in der man Adresse und
Anmeldeart sieht. Braucht der Server ein Token, steht in der Karte ein **sicheres Eingabefeld**; der Wert geht direkt in
den Schlüsselbund des Servers, der Scoop sieht nur „Token gespeichert“. Bei OAuth erscheint nach der Freigabe die Karte
**„Bei … anmelden“**; nach der Anmeldung meldet der Scoop die Werkzeuganzahl und probiert ein lesendes Werkzeug.
Weitere Werkzeuge: `mcp_server_liste`, `mcp_server_token_setzen` (neues Token über die sichere Karte),
`mcp_server_anmelden` (Karte „Neu anmelden“), `mcp_server_entfernen` (mit Freigabe). Gäste geteilter Scoops haben
diese Werkzeuge nicht.

## Arten

| Art | Wie | Geheimnisse |
|---|---|---|
| Remote ohne Anmeldung | Streamable HTTP, kein Header | – |
| Remote mit Token | `Authorization: Bearer …` oder eigener Header (Wert unverändert, z. B. `X-Api-Key`) | Token |
| Remote mit OAuth 2.1 | siehe unten | Registrierung, Access-/Refresh-Token |
| Lokal (stdio) | Befehl + Argumente + Umgebungsvariablen, nur der Inhaber | Werte der Umgebungsvariablen |

## Speicher

- `config.json` → `custom_mcp`: `[{id, name, kind: remote|stdio, url | command, auth: none|token|oauth, header?,
  env_keys?, created_at}]`. **Keine Geheimnisse.**
- Schlüsselbund: ein Eintrag pro Server, Dienst `<prefix>-mcp-<id>`, Konto `secret`, JSON als Base64, geschrieben über
  `security -i` (stdin, nie in der Prozessliste). Inhalt je nach Art: `token`, `env`, OAuth (`as` = Endpunkte,
  `resource`, `scope`, `client_id`, `access_token`, `refresh_token`, `expires_at`, `expired`).
- IDs: `mcp_<name>` (z. B. `mcp_qonto`, bei gleichem Namen `mcp_qonto_2`). Das Präfix verhindert Kollisionen mit
  `composio`, `notion`, `teamapp` und `atrium…`. Werkzeuge im Hub: `mcp_qonto__<werkzeug>`; Zeichen außerhalb von
  `[A-Za-z0-9_-]` in Werkzeugnamen werden durch `_` ersetzt und beim Aufruf zurückgeführt (sonst lehnt die API die
  ganze Anfrage ab).
- Entfernen löscht Listeneintrag und Schlüsselbund-Eintrag und widerruft OAuth-Tokens (best effort).

## Erkennen und OAuth

1. `POST <url>` mit `initialize` ohne Token. 2xx → keine Anmeldung. 401/403 → `WWW-Authenticate: Bearer
   resource_metadata="…"` lesen, sonst `/.well-known/oauth-protected-resource<pfad>` bzw. ohne Pfad (RFC 9728).
   Gefunden → OAuth; sonst Authorization-Server-Metadaten am Ursprung probieren, sonst → Token nötig.
2. Authorization-Server aus `authorization_servers[0]`, Metadaten über `/.well-known/oauth-authorization-server<pfad>`
   (RFC 8414, mit Pfad-Einfügung) oder OpenID-Konfiguration. PKCE nur mit `S256`.
3. **Dynamic Client Registration** einmal pro Server als öffentlicher Client (`token_endpoint_auth_method: none`,
   `redirect_uris: ["aisscoops://oauth/mcp"]`). Lehnt der Anbieter das App-Schema ab (Fehlertext mit „redirect“, so
   bei **Qonto**: Allowlist, nur Loopback erlaubt), registriert der Server sich mit dem Loopback-Rücksprung
   `http://127.0.0.1:47615/oauth/mcp` (RFC 8252 §7.3). Die `client_id` und der verwendete Rücksprung bleiben im
   Schlüsselbund; „Neu anmelden“ registriert nicht neu.
4. Scopes: aus `WWW-Authenticate scope=…`, sonst `scopes_supported` der Ressource; `offline_access` kommt dazu, wenn
   der Anmelde-Dienst es anbietet. `resource` = Wert aus den Ressourcen-Metadaten (bei Qonto `https://mcp.qonto.com`).
5. Authorize-URL mit `state` und PKCE-Verifier nur im Speicher (15 Minuten). Die App öffnet sie mit
   ASWebAuthenticationSession (Schema `aisscoops`) und schickt den Rücksprung an den vorhandenen Endpunkt
   `POST /api/connections/oauth/callback`. Der Server verteilt nach Pfad: `aisscoops://oauth/mcp` und
   `http://127.0.0.1:47615/oauth/mcp` → eigene MCP-Server, `aisscoops://oauth/notion` → Notion direkt (unverändert in
   `notion_mcp.py`).
   **Loopback:** Liefert der Server `loopback_port`, hört die App während der Anmeldung kurz auf `127.0.0.1:47615`
   (`LoopbackCatcher`, Network-Framework, nur Loopback; macOS-Berechtigung `com.apple.security.network.server`),
   antwortet dem Browser mit „Angemeldet“, schließt das Anmeldefenster und reicht die Adresse genauso weiter. Ältere
   Apps können das nicht; sie zeigen dann keinen Rücksprung (App aktualisieren).
6. Tokens: Erneuern 5 Minuten vor Ablauf, immer nur einmal gleichzeitig pro Server, neues Refresh-Token sofort
   gespeichert. Antwortet der MCP mit 401, erneuert der Hub einmal und wiederholt den Aufruf. `invalid_grant` →
   Status „Anmeldung nötig“, Server verschwindet aus dem Hub, die App zeigt „Neu anmelden“.

Notion bleibt bewusst auf `notion_mcp.py` (eigene Tests, laufende Anmeldungen, Composio-Ausblendung); der generische
Kern hat dieselben Regeln, ein Umzug ist später ohne neue Anmeldung möglich, wenn die gespeicherten Felder übernommen
werden.

## Einbindung in die Scoops

- `server.mcp_servers()` = fest eingebaute + `custom_mcp.specs()` (auch im Test-/Offline-Modus, dort nur, was die
  Testinstanz selbst anlegt). OAuth-Server kommen erst nach der Anmeldung in den Hub. Das Token ist eine Funktion
  (`TokenFn`, Gleichheit über die ID), damit Refresh greift und `MCPHub.configure` die Werkzeugliste nicht verwirft.
- **Alle Engines** bekommen denselben Hub: Messages API (große Server mit `defer_loading` über die BM25-Werkzeugsuche,
  ab 16 Werkzeugen), Claude-Abo (In-Process-MCP `scoops`: häufige direkt, sonst `app_werkzeug_suchen/nutzen`),
  ChatGPT-Abo (über `/mcp/abo`, gleiche Liste), Aufgaben (`app_werkzeug_suchen/nutzen` am `/mcp/task`).
- Systemanweisung: Zusatz „Eigene MCP-Server von Arman: Qonto (`mcp_qonto__…`) …“, solange Werkzeuge da sind;
  Regel in `prompts.base_rules`, wie der Scoop Server verbindet (prüfen, nur Fehlendes fragen, Geheimnisse nur über
  die Karte).
- Statuszeile im Chat: „Nutzt Qonto“.

## Sicherheit

- **Schreibende Werkzeuge** (alles ohne `readOnlyHint: true`) laufen über `custom_mcp.ApprovalGate`: Statt
  auszuführen legt der Server eine Freigabe-Karte an (Titel „Qonto: <Werkzeug>“, Beschreibung, Argumente; Hinweis bei
  `destructiveHint`). Nach „Freigeben“ führt der Server genau diesen Aufruf aus und gibt dem Scoop das Ergebnis
  (Ereignis + Fortsetzung). In Aufgaben wartet die Aufgabe nicht (wie Mail-Karten), das Ergebnis kommt im Chat.
- **„Immer erlauben“** je Werkzeug (`mcp:<server>__<werkzeug>`), außer für Geld, Karten, IBAN/SEPA, Passwörter u. Ä.
  (`custom_mcp.NEVER_ALWAYS_TOOL` und die Sperrliste aus `bots._NEVER_ALWAYS`). Bei Qonto also z. B. nie für
  Überweisungen oder Karten.
- Lesende Werkzeuge laufen ohne Nachfrage.
- Verbinden, Token setzen und Entfernen aus dem Chat: immer Karte, nie „Immer erlauben“. Lokale Befehle zeigen den
  vollständigen Befehl in der Karte.
- **Geteilte Scoops:** Eigene MCPs stehen in der Freigabe-Gruppe „MCPs“ (mit ihrem Namen) und sind für Gäste
  standardmäßig aus. Gäste-Freigaben landen wie immer beim Inhaber, ohne „Immer erlauben“.
- Alle Endpunkte nur für den Inhaber (`auth`, Gäste 403). Tokens und Umgebungswerte gibt die API nie aus.
- Geheimnisse nie im Chat: Die sichere Karte schickt sie in `edits.secrets` nur mit der Entscheidung; sie werden
  weder in der Nachricht noch in der Freigabe gespeichert.

## API (v1.35)

- `GET /api/mcp-servers` → `{servers: [{id, name, kind, auth, status: ok|error|login, error, tools, write_tools,
  url | command, header?, env_keys?, created_at}], supported: true, callback_scheme}`. Dieselbe Liste steht in
  `GET /api/connections` unter `custom_mcp` (dazu `custom_mcp_supported: true`; ältere Server haben das Feld nicht →
  die App zeigt „Server aktualisieren“). Ist Composio nicht eingerichtet, aber es gibt eigene MCPs, liefert
  `/api/connections` trotzdem 200 mit `apps: []` und `composio_error`.
- `POST /api/mcp-servers/probe` `{url}` → `{auth: none|token|oauth, detail, name}`.
- `POST /api/mcp-servers` `{name?, url, auth: auto|none|token|oauth, token?, header?}` bzw. `{kind: "stdio", name?,
  command, args?, env?}` → `{server, oauth?: {url, server_id, callback_scheme}, test?: {ok, tools, error}, servers…}`.
- `PATCH /api/mcp-servers/{id}` `{name?, token?, header?}`, `DELETE /api/mcp-servers/{id}`,
  `POST /api/mcp-servers/{id}/login` (OAuth starten/neu anmelden → `{url, callback_scheme}`),
  `POST /api/mcp-servers/{id}/test` → `{ok, tools, error, servers…}`.
- Rücksprung: `POST /api/connections/oauth/callback` `{url: "aisscoops://oauth/mcp?code=…&state=…"}`.
- Chat-Karten: Freigabe `meta.kind = mcp` (Werkzeug), `mcp_connect`, `mcp_secret`, `mcp_remove`; mit
  `meta.secret_fields = [{key, label}]` zeigt die App sichere Felder und schickt `{"decision": "approve", "edits":
  {"secrets": {key: wert}}}`. Anmelde-Karte: Ereignis `meta.kind = mcp_login` mit `mcp_server_id`,
  `mcp_server_name`; die App holt beim Tippen `POST /api/mcp-servers/{id}/login`.

## Qonto (geprüft am 18.11.2026)

`POST https://mcp.qonto.com/mcp` → 401 `resource_metadata="https://mcp.qonto.com/.well-known/oauth-protected-resource"`;
Ressource `https://mcp.qonto.com`, Authorization-Server `https://mcp.qonto.com` (`/authorize`, `/token`, `/register`,
PKCE S256, `token_endpoint_auth_methods_supported: none`), Scopes u. a. `offline_access`, `organization.read`,
`card.read`, `request_transfers.write`.

- Registrierung mit `aisscoops://oauth/mcp` → 400 „this redirect_uri is not allowed; … request that its redirect_uri be
  allowed“ (Qonto führt eine Allowlist). Mit `http://127.0.0.1:47615/oauth/mcp` → `client_id`. Darum der
  Loopback-Rückfall.
- Erzeugte Authorize-URL (`https://mcp.qonto.com/authorize?…` mit `client_id`, `redirect_uri` Loopback, PKCE S256,
  `state`, `resource=https://mcp.qonto.com`, alle Scopes inkl. `offline_access`) → 302 zur Qonto-Anmeldung
  (`oauth.qonto.com/oauth2/auth`). Die Anmeldung selbst macht der Nutzer in der App.
- Möchte man ohne Loopback auskommen, müsste Qonto `aisscoops://oauth/mcp` freischalten (Formular im Fehlertext).
