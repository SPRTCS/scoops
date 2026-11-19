#!/bin/zsh
# Ende-zu-Ende-Test der Selbstaktualisierung (docs/updates.md): Version A aktualisiert sich still auf Version B,
# wartet dabei, solange ein Scoop arbeitet, startet neu und fährt ihren Server wieder hoch.
#
#   App/scripts/update-test.sh "<A>/AIS Scoops Server.app" ["<B>/AIS Scoops Server.app"]
#
# Ohne B wird A mit Build-Nummer +1 als B verwendet. Alles läuft isoliert und wird danach entfernt:
#   - Kopien unter eigener Bundle-ID (com.ais.scoopsconnect.updatetest) in einem Wegwerf-Ordner, mit eigenem
#     Test-Schlüssel (Ed25519, nur für diesen Lauf) und eigenem Feed auf 127.0.0.1:$FEED_PORT,
#   - die App im Testmodus (eigener Datenordner, Server auf $SERVER_PORT, Schlüsselbund-Präfix ais-scoops-test,
#     keine Steuerung dieses Macs); die Testkopie merkt sich das in ihren eigenen Einstellungen (TestServerHome),
#   - ein Platzhalter-Modell auf $FAKE_PORT (ANTHROPIC_BASE_URL) hält einen echten Scoop-Lauf fest, bis der Test
#     ihn freigibt.
# Der echte Server (Port 8787) und eine laufende echte App werden nicht angefasst.
set -euo pipefail
zmodload zsh/datetime

OLD="${1:?Pfad zu Version A (.app)}"
NEW="${2:-}"
FEED_PORT="${FEED_PORT:-8796}"
SERVER_PORT="${SERVER_PORT:-8797}"
FAKE_PORT="${FAKE_PORT:-8798}"
TEST_ID="com.ais.scoopsconnect.updatetest"
SUITE="com.ais.scoopsconnect.testserver"
APP_NAME="AIS Scoops Server.app"
# Echter Pfad (/private/var/…): so heißen auch die laufenden Prozesse, pgrep findet sie nur damit.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ais-update-test.XXXXXX")" && pwd -P)"
INST="$WORK/installed/$APP_NAME"
EXE="$INST/Contents/MacOS/AIS Scoops Server"
HOME_DIR="$WORK/home"
pids=()
suite_backup=""

say() { print -P "%F{blue}▸%f $(strftime %H:%M:%S $EPOCHSECONDS) $*"; }
pass() { print -P "%F{green}PASS%f  $*"; }
fail() { print -P "%F{red}FAIL%f  $*"; exit 1; }
plist() { /usr/libexec/PlistBuddy "$@"; }

cleanup() {
  set +e
  for p in $(pgrep -f "$WORK/installed/" 2>/dev/null); do kill "$p" 2>/dev/null; done
  for i in {1..50}; do pgrep -f "$WORK/installed/" >/dev/null || break; sleep 0.2; done
  for p in $(pgrep -f "$WORK/installed/" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  for p in $pids; do kill "$p" 2>/dev/null; done
  [[ -d "$WORK/installed" ]] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$INST" 2>/dev/null
  defaults delete "$TEST_ID" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$TEST_ID.plist"
  rm -rf "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/HTTPStorages/$TEST_ID" "$HOME/Library/HTTPStorages/$TEST_ID.binarycookies" \
         "$HOME/Library/Saved Application State/$TEST_ID.savedState" "$HOME/Library/Application Support/$TEST_ID"
  if [[ -n "$suite_backup" && -f "$suite_backup" ]]; then
    defaults import "$SUITE" "$suite_backup"
  else
    defaults delete "$SUITE" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$SUITE.plist"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# -- Vorbereitung ------------------------------------------------------------------------------
for p in $FEED_PORT $SERVER_PORT $FAKE_PORT; do
  [[ $p == 8787 ]] && fail "Port 8787 gehört dem echten Server"
  nc -z -G 1 127.0.0.1 $p 2>/dev/null && fail "Port $p ist belegt"
done
IDENT="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENT" ]] || IDENT="$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENT" ]] || fail "Keine Signier-Identität"

mkdir -p "$WORK/installed" "$WORK/new" "$WORK/feed" "$HOME_DIR"
# Kopien zuerst ohne „.app“ vorbereiten und erst danach umbenennen: Eine geladene, von Gatekeeper geprüfte App
# schützt macOS (App-Verwaltung) auch in Kopien vor Änderungen, solange sie als App-Bundle erkennbar ist.
PREP_OLD="$WORK/prep-old"
PREP_NEW="$WORK/prep-new"
COPY=(ditto --noextattr --noqtn)
$COPY "$OLD" "$PREP_OLD"
if [[ -n "$NEW" ]]; then
  $COPY "$NEW" "$PREP_NEW"
else
  $COPY "$OLD" "$PREP_NEW"
  b="$(plist -c 'Print CFBundleVersion' "$OLD/Contents/Info.plist")"
  plist -c "Set CFBundleVersion $((b + 1))" "$PREP_NEW/Contents/Info.plist"
fi
FROM="$(plist -c 'Print CFBundleVersion' "$PREP_OLD/Contents/Info.plist")"
TO="$(plist -c 'Print CFBundleVersion' "$PREP_NEW/Contents/Info.plist")"
(( TO > FROM )) || fail "B ($TO) ist nicht neuer als A ($FROM)"

# Test-Schlüssel mit dem Python aus dem Bundle (cryptography ist dabei); verlässt den Wegwerf-Ordner nie.
PY="$PREP_OLD/Contents/Resources/server/bin/python3"
TEST_PUB="$("$PY" -I -B -c '
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.generate()
open(sys.argv[1], "wb").write(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption()))
print(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode())' "$WORK/test.key")"

codesign -d --entitlements - --xml "$PREP_OLD" > "$WORK/ent.plist" 2>/dev/null
retag() {
  plist -c "Set CFBundleIdentifier $TEST_ID" -c "Set SUFeedURL http://127.0.0.1:$FEED_PORT/appcast.xml" \
        -c "Set SUPublicEDKey $TEST_PUB" "$1/Contents/Info.plist"
  codesign --force --options runtime --timestamp=none --sign "$IDENT" --entitlements "$WORK/ent.plist" "$1" 2>/dev/null
  codesign --verify --deep --strict "$1" || fail "Testkopie nicht gültig signiert: $1"
}
retag "$PREP_OLD"
retag "$PREP_NEW"
mv "$PREP_OLD" "$INST"
mv "$PREP_NEW" "$WORK/new/$APP_NAME"
PY="$INST/Contents/Resources/server/bin/python3"

ZIP="$WORK/feed/AIS-Scoops-Server-$TO.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK/new/$APP_NAME" "$ZIP"
SIG="$("$PY" -I -B -c '
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
print(base64.b64encode(k.sign(open(sys.argv[2], "rb").read())).decode())' "$WORK/test.key" "$ZIP")"
cat > "$WORK/feed/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Updatetest</title>
    <item>
      <title>Version B</title>
      <sparkle:version>$TO</sparkle:version>
      <sparkle:shortVersionString>$(plist -c 'Print CFBundleShortVersionString' "$INST/Contents/Info.plist")</sparkle:shortVersionString>
      <enclosure url="http://127.0.0.1:$FEED_PORT/${ZIP:t}" sparkle:edSignature="$SIG" length="$(stat -f %z "$ZIP")" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
/usr/bin/xmllint --noout "$WORK/feed/appcast.xml" || fail "Test-Feed ungültig"

# Feed-Server: liefert das ZIP erst ganz, wenn $WORK/gate-download existiert (bis dahin tröpfchenweise, damit die
# Verbindung offen bleibt). So entsteht der Scoop-Lauf sicher, bevor das Update fertig geladen ist.
cat > "$WORK/feed.py" <<'PY'
import http.server, os, sys, time
root, gate, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, fmt, *args): print(time.strftime("%H:%M:%S"), fmt % args, flush=True)
    def do_GET(self):
        path = os.path.join(root, self.path.lstrip("/").split("?")[0])
        if not path.endswith(".zip") or not os.path.exists(path):
            return super().do_GET()
        data = open(path, "rb").read()
        print(time.strftime("%H:%M:%S"), "ZIP angefragt", flush=True)
        self.send_response(200); self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        sent = 0
        while not os.path.exists(gate) and sent < len(data) - 1:
            self.wfile.write(data[sent:sent + 1]); self.wfile.flush(); sent += 1; time.sleep(2)
        self.wfile.write(data[sent:]); self.wfile.flush()
        print(time.strftime("%H:%M:%S"), "ZIP ausgeliefert", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
# Platzhalter-Modell (Anthropic-Messages-API): antwortet erst, wenn $WORK/gate-run existiert.
cat > "$WORK/fake.py" <<'PY'
import http.server, json, os, sys, time
gate, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        print(time.strftime("%H:%M:%S"), "Modell-Anfrage", self.path, flush=True)
        for _ in range(600):
            if os.path.exists(gate): break
            time.sleep(0.5)
        body = json.dumps({"id": "msg_updatetest", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
                           "content": [{"type": "text", "text": "Fertig."}], "stop_reason": "end_turn",
                           "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        print(time.strftime("%H:%M:%S"), "Modell-Antwort gesendet", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
/usr/bin/python3 -I "$WORK/feed.py" "$WORK/feed" "$WORK/gate-download" $FEED_PORT > "$WORK/feed.log" 2>&1 &
pids+=($!)
/usr/bin/python3 -I "$WORK/fake.py" "$WORK/gate-run" $FAKE_PORT > "$WORK/fake.log" 2>&1 &
pids+=($!)

# Einstellungen der Testkopie (eigene Domain) und des Testmodus (Sicherung, danach zurück).
if defaults read "$SUITE" >/dev/null 2>&1; then
  suite_backup="$WORK/suite-backup.plist"
  defaults export "$SUITE" "$suite_backup"
fi
defaults write "$SUITE" serverSetupDone -bool true         # kein Einrichtungsfenster
defaults write "$TEST_ID" TestServerHome "$HOME_DIR"
defaults write "$TEST_ID" TestServerPort -int $SERVER_PORT

# -- Version A starten -------------------------------------------------------------------------
START=$EPOCHSECONDS
say "Starte A ($FROM) im Testmodus, Server-Port $SERVER_PORT"
open -n -g --env "ANTHROPIC_BASE_URL=http://127.0.0.1:$FAKE_PORT" --env "ANTHROPIC_API_KEY=sk-ant-updatetest" "$INST"
setup() { curl -s -m 3 "http://127.0.0.1:$SERVER_PORT/api/setup"; }
for i in {1..120}; do setup | grep -q '"server"' && break; sleep 1; done
setup | grep -q '"server"' || fail "Testserver von A antwortet nicht"
APP_PID_A="$(pgrep -f "$EXE" | head -1 || true)"
[[ -n "$APP_PID_A" ]] || fail "Prozess von A nicht gefunden"
SERVER_PID_A="$(cat "$HOME_DIR/server.pid")"
say "A läuft (App-PID $APP_PID_A, Server-PID $SERVER_PID_A)"

for i in {1..90}; do grep -q "ZIP angefragt" "$WORK/feed.log" && break; sleep 1; done
grep -q "ZIP angefragt" "$WORK/feed.log" || { cat "$WORK/feed.log"; fail "Sparkle hat B nicht angefragt"; }
say "Sparkle lädt B (Download wird gehalten)"

TOKEN="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['api_token'])" "$HOME_DIR/config.json")"
api() { curl -s -m 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
BOT="$(api -X POST "http://127.0.0.1:$SERVER_PORT/api/bots" -d '{"name":"Updatetest"}' | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
api -X POST "http://127.0.0.1:$SERVER_PORT/api/bots/$BOT/messages" -d '{"text":"Bitte kurz warten."}' >/dev/null
runs() { setup | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["server"].get("active_runs",0))'; }
for i in {1..30}; do [[ "$(runs)" -ge 1 ]] && grep -q "Modell-Anfrage" "$WORK/fake.log" && break; sleep 1; done
[[ "$(runs)" -ge 1 ]] || fail "Kein aktiver Scoop-Lauf"
say "Scoop-Lauf aktiv (active_runs=$(runs)), Modell hält ihn fest"

touch "$WORK/gate-download"
for i in {1..60}; do grep -q "ZIP ausgeliefert" "$WORK/feed.log" && break; sleep 1; done
LOADED=$EPOCHSECONDS
say "B vollständig geladen"

# Solange der Lauf aktiv ist, darf nichts installiert werden (mindestens 4 Prüfzyklen à 15 s).
for i in {1..60}; do
  sleep 1
  [[ "$(plist -c 'Print CFBundleVersion' "$INST/Contents/Info.plist" 2>/dev/null)" == "$FROM" ]] \
    || fail "Während eines aktiven Laufs installiert (nach $i s)"
  kill -0 "$APP_PID_A" 2>/dev/null || fail "A wurde während eines aktiven Laufs beendet (nach $i s)"
done
[[ "$(runs)" -ge 1 ]] || fail "Lauf endete unerwartet"
pass "A wartet bei aktivem Lauf: 60 s nach dem Download noch Version $FROM, Lauf aktiv, App läuft"

touch "$WORK/gate-run"
for i in {1..30}; do [[ "$(runs)" == 0 ]] && break; sleep 1; done
RUN_END=$EPOCHSECONDS
say "Lauf beendet (active_runs=$(runs))"

for i in {1..180}; do
  [[ "$(plist -c 'Print CFBundleVersion' "$INST/Contents/Info.plist" 2>/dev/null)" == "$TO" ]] && break
  sleep 1
done
[[ "$(plist -c 'Print CFBundleVersion' "$INST/Contents/Info.plist")" == "$TO" ]] || fail "Nicht auf B aktualisiert"
INSTALLED=$EPOCHSECONDS
say "Bundle ist jetzt B ($TO)"

for i in {1..120}; do
  APP_PID_B="$(pgrep -f "$EXE" | head -1 || true)"
  [[ -n "$APP_PID_B" && "$APP_PID_B" != "$APP_PID_A" ]] && setup | grep -q '"server"' && break
  sleep 1
done
[[ -n "${APP_PID_B:-}" && "$APP_PID_B" != "$APP_PID_A" ]] || fail "B wurde nicht neu gestartet"
setup | grep -q '"server"' || fail "Server von B antwortet nicht"
SERVER_PID_B="$(cat "$HOME_DIR/server.pid")"
[[ "$SERVER_PID_B" != "$SERVER_PID_A" ]] || fail "Server wurde nicht neu gestartet"
kill -0 "$APP_PID_A" 2>/dev/null && fail "Alte App-Instanz läuft noch"
ls "$WORK/installed" | grep -qvxF "$APP_NAME" && fail "Reste neben der App: $(ls "$WORK/installed")"
codesign --verify --deep --strict "$INST" || fail "Installiertes Bundle nicht versiegelt"
UP=$EPOCHSECONDS
say "B läuft (App-PID $APP_PID_B, Server-PID $SERVER_PID_B, Port $SERVER_PORT antwortet)"
pass "A ($FROM) → B ($TO) still aktualisiert: Download nach $((LOADED - START)) s, Lauf-Ende +$((RUN_END - LOADED)) s, \
installiert $((INSTALLED - RUN_END)) s nach Lauf-Ende, App und Server wieder oben nach weiteren $((UP - INSTALLED)) s"

echo "── Server-Protokoll der Testkopie (Updates und Starts) ──"
grep -E "\[Update\]|Start durch AIS Scoops Server" "$HOME_DIR/logs/server.log" | sed 's/^/  /' || true
echo "── Feed ──"; sed 's/^/  /' "$WORK/feed.log" | grep -v "code 404" || true
echo "── Modell ──"; sed 's/^/  /' "$WORK/fake.log"
