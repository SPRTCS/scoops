# AIS Scoops Cloud (Convex)

Zentraler Konto-Dienst von AIS Scoops: **Konten (Mit Apple anmelden), Server-Verzeichnis, Kopplungscodes, Sitzungen,
Push-Relay und geteilte Scoops** (APNs für Server ohne eigenen Schlüssel).
Keine Chats, keine API-Schlüssel, keine Inhalte – die bleiben auf dem Server der Kundin/des Kunden.
Konzept und exakte Schnittstelle (Request/Response): [`../docs/accounts.md`](../docs/accounts.md), Abschnitt „Ist-Stand Phase 1“.

## Deployments

Projekt `ais-scoops` bei Convex, Region EU (Irland).

| | Funktionen (`/api/query`, `/api/mutation`) | HTTP-Actions |
|---|---|---|
| Produktion `helpful-puma-445` | `https://helpful-puma-445.eu-west-1.convex.cloud` | `https://helpful-puma-445.eu-west-1.convex.site` |
| Dev `merry-vole-238` | `https://merry-vole-238.eu-west-1.convex.cloud` | `https://merry-vole-238.eu-west-1.convex.site` |


## Aufbau

```
convex/
  schema.ts        users, servers, serverClaims, sessions, pushTokens, pushChannels, shares, invites, rateLimits
  auth.config.ts   customJwt: eigene Sitzungs-JWTs (RS256, aud "ais-scoops", iss = CONVEX_SITE_URL)
  http.ts          POST /auth/apple, /auth/refresh · GET /.well-known/jwks.json
                   POST /servers/claim/start, /servers/claim/poll, /servers/heartbeat
                   POST /push/status, /push/register, /push/send, /push/channel, /push/broadcast (Bearer serverSecret)
                   POST /shares/sync (Bearer serverSecret) · GET /i/<code> (Einladungsseite)
  auth.ts          interne Mutations: Anmelden, Erneuern, Rate-Limit pro IP
  claims.ts        interne Mutations: Code anlegen, Abholen (serverSecret), Herzschlag, Aufräumen
  servers.ts       myServers, claimServer, renameServer, removeServer
  users.ts         me, deleteAccount
  sessions.ts      mySessions, revokeSession
  shares.ts        Geteilte Scoops: createInvite (action), listForBot, listForServer, update, remove, revokeInvite,
                   inviteInfo (ohne Login), accept, mine, leave; syncForServer (intern) – docs/sharing.md
  push.ts          Push-Relay: Tokens melden, Prüfen vor dem Versand (Besitz, Art, Ratenbegrenzung), Kanäle
  apns.ts          "use node": Versand an APNs über HTTP/2 (node:http2), JWT ES256, Kanäle anlegen/löschen, Broadcast
  crons.ts         alle 6 h aufräumen (abgelaufene Codes, alte Zähler, widerrufene Sitzungen > 31 Tage),
                   alle 12 h alte Push-Tokens, stündlich alte/verwaiste Broadcast-Kanäle (auch bei Apple)
  devtools.ts      issueTestSession – nur intern und nur mit ALLOW_DEV_TOOLS=1 (Dev), für Server/tests/test_cloud.py
  lib/tokens.ts    Sitzungs-JWT signieren, JWKS, Prüfung von Apples identityToken (jose)
  lib/crypto.ts    Codes (8 Zeichen ABCDEFGHJKLMNPQRSTUVWXYZ23456789, 10 Min.), Zufall, SHA-256
  lib/session.ts   viewer() (JWT + nicht widerrufene Sitzung), Rate-Limit, Server löschen
  lib/push.ts      Regeln des Relays: Topics, Token-Arten je Plattform, Größen, Grenzen, Prüfung eines Eintrags
tests/cloud.test.ts  convex-test/vitest (Apple-Tokens mit eigenem Testschlüssel, Test-JWKS eingeschleust)
tests/push.test.ts   Push-Relay mit gemocktem node:http2 (APNs)
tests/shares.test.ts Geteilte Scoops: alle Rechtefälle, Sync, Aufräumen, Push an Gäste
```

Geheimnisse werden nur gehasht gespeichert (SHA-256): `serverSecret`, `claimSecret`, Refresh-Tokens.
Zufallswerte entstehen ausschließlich in HTTP-Actions (echte Zufälligkeit), nie in Mutations.

## Umgebungsvariablen (nur Namen; Werte nie ins Repo)

| Name | Wo | Zweck |
|---|---|---|
| `SESSION_PRIVATE_KEY` | dev + prod (verschiedene Schlüssel) | RSA-2048, PKCS#8-PEM. Signiert Sitzungs-JWTs; JWKS wird daraus abgeleitet (`kid` = JWK-Thumbprint) |
| `APPLE_AUDIENCES` | optional | Kommagetrennte erlaubte `aud` für Apple-Tokens, Standard `com.ais.aisbot` |
| `ALLOW_DEV_TOOLS` | nur dev (`1`) | schaltet `devtools:issueTestSession` frei |
| `CONVEX_SITE_URL` | automatisch | Aussteller (`iss`) der Sitzungs-JWTs |
| `APNS_KEY_P8` | dev + prod | APNs-Schlüssel (.p8) für das Push-Relay; PEM, Base64 der PEM oder Hex |
| `APNS_KEY_ID` | dev + prod | Key-ID des APNs-Schlüssels (10 Zeichen) |
| `APNS_TEAM_ID` | dev + prod | Team `MYXQKK3T2Z` |

Neuen Schlüssel setzen (Wert über stdin, nicht in der Shell-Historie):
```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/key.pem
npx convex env set SESSION_PRIVATE_KEY < /tmp/key.pem          # dev
npx convex env set --prod SESSION_PRIVATE_KEY < /tmp/key.pem   # prod
rm /tmp/key.pem
```
APNs-Schlüssel setzen – direkt aus dem Schlüsselbund von Armans Server per Pipe, ohne Ausgabe und ohne Datei
(`security -w` liefert mehrzeilige Werte hexkodiert; übergeben wird einzeiliges Base64 der PEM):
```sh
for FLAG in "" --prod; do
  python3 -c 'import base64,subprocess,sys;p=subprocess.run(["security","find-generic-password","-s","ais-bot-apns","-a","p8","-w"],capture_output=True,text=True).stdout.strip();p=p if "PRIVATE KEY" in p else bytes.fromhex(p).decode();sys.stdout.write(base64.b64encode(p.encode()).decode())'     | npx convex env set $FLAG APNS_KEY_P8 >/dev/null
  npx convex env set $FLAG APNS_KEY_ID "<apns_key_id aus config.json>"
  npx convex env set $FLAG APNS_TEAM_ID MYXQKK3T2Z
done
```
Ohne diese Variablen antwortet `/push/status` mit `configured: false` und `/push/send` mit `503 relay_not_configured`.

Achtung: Ein Schlüsselwechsel macht alle laufenden Sitzungen ungültig (Apps melden sich per Refresh neu an –
Refresh-Tokens bleiben gültig, weil sie nicht vom Schlüssel abhängen).

## Entwickeln, testen, deployen

```sh
cd Cloud
npm install --legacy-peer-deps   # node_modules ist per xattr von iCloud ausgenommen
npm test                         # vitest + convex-test (64 Tests: Konten, Push-Relay, geteilte Scoops)
npm run typecheck
npx convex dev --once            # Dev-Deployment aktualisieren (.env.local zeigt auf dev:merry-vole-238)
npx convex deploy -y             # Produktion
```

Server-Seite (Python) und Integrationstest gegen Dev: `Server/src/aisbot/cloud.py`, `Server/tests/test_cloud.py`;
Push-Relay: `Server/src/aisbot/push.py`, `Server/tests/test_push.py`. Schnittstelle: `../docs/accounts.md`, „Push-Relay“.
