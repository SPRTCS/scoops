#!/bin/zsh
# Veröffentlicht eine neue Version der Mac-App „AIS Scoops Server“ als Sparkle-Update (docs/updates.md).
#
#   App/scripts/release-server.sh                       # bauen, notarisieren, Release in SPRTCS/ais-scoops-server
#   NOTES="Was neu ist" App/scripts/release-server.sh   # eigener Text für Release und Update
#   PUBLISH=0 App/scripts/release-server.sh             # alles bis auf das Veröffentlichen (Ergebnis in build/server-release)
#
# Ablauf: veröffentlichten Feed laden → build-server-dmg.sh (Developer ID, notarisiert) → ZIP mit dem
# Sparkle-Schlüssel signieren (sign_update, Schlüsselbund-Account „ais-scoops-server“) → appcast.xml um die neue
# Version ergänzen → Tag und GitHub-Release im öffentlichen Repo (nur Releases, kein Code) → prüfen, dass Feed und
# Download ohne Anmeldung erreichbar sind. Keine Kopie auf den Schreibtisch (Updates kommen per Sparkle); DESKTOP=1 legt sie dort ab.
#
# Der private Sparkle-Schlüssel liegt im Schlüsselbund (Dienst https://sparkle-project.org, Account ais-scoops-server);
# das Skript gibt ihn nie aus.
set -euo pipefail

APPDIR="${0:A:h}/.."
ROOT="${APPDIR:A}/.."
REPO="${RELEASE_REPO:-SPRTCS/ais-scoops-server}"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
ACCOUNT="${SPARKLE_ACCOUNT:-ais-scoops-server}"
PUBLISH="${PUBLISH:-1}"
DESKTOP="${DESKTOP:-0}"
KEEP_ITEMS="${KEEP_ITEMS:-10}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
WORK="${WORK:-${TMPDIR:-/tmp}/ais-scoops-server-build}"
OUT="$APPDIR/build/server-release"

step() { print -P "%F{blue}▸%f $*"; }
die() { print -P "%F{red}✗%f $*" >&2; exit 1; }

# -- 0. Vorprüfungen -----------------------------------------------------------------------
print -P "%F{yellow}Größere Änderung? Vorher Server/bin/probelauf ausführen (docs/probelauf.md).%f"
cd "$ROOT"
if [[ "${ALLOW_DIRTY:-0}" != 1 ]]; then
  dirty="$(git status --porcelain -- App/ScoopsConnect App/project.yml App/scripts Server/src Server/pyproject.toml Server/uv.lock)"
  [[ -z "$dirty" ]] || die "Nicht eingecheckte Änderungen im App-/Server-Code (ALLOW_DIRTY=1 erzwingt):\n$dirty"
fi
if [[ "$PUBLISH" == 1 ]]; then
  gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet (gh auth login)."
  vis="$(gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null)" || die "Repo $REPO nicht gefunden."
  [[ "$vis" == PUBLIC ]] || die "$REPO ist nicht öffentlich ($vis): Sparkle lädt ohne Anmeldung."
fi

rm -rf "$OUT"
mkdir -p "$OUT"
step "Veröffentlichten Feed laden"
code="$(curl -sL -o "$OUT/published.xml" -w '%{http_code}' "$FEED" || echo 000)"
if [[ "$code" == 200 ]]; then
  :
elif [[ "$code" == 404 && "$PUBLISH" == 1 && -z "$(gh release list --repo "$REPO" --limit 1 2>/dev/null)" ]]; then
  step "Noch kein Release in $REPO: neuer Feed"
  rm -f "$OUT/published.xml"
elif [[ "$code" == 404 && "$PUBLISH" != 1 ]]; then
  rm -f "$OUT/published.xml"
else
  die "Feed $FEED antwortet $code. Ohne den veröffentlichten Feed gingen frühere Einträge verloren."
fi

# -- 1. Bauen (Developer ID, notarisiert) ----------------------------------------------------
step "App und DMG bauen (Build $BUILD_NUMBER)"
BUILD_NUMBER="$BUILD_NUMBER" WORK="$WORK" OUT="$OUT/build" "$APPDIR/scripts/build-server-dmg.sh" | tee "$OUT/build.log"
grep -q "Signiert (Developer ID), notarisiert und gestapelt" "$OUT/build.log" \
  || die "Der Build ist nicht mit Developer ID signiert und notarisiert – so wird nichts veröffentlicht."
DMG="$(print -l "$OUT"/build/AIS-Scoops-Server-*-"$BUILD_NUMBER".dmg | head -1)"
ZIP="$(print -l "$OUT"/build/AIS-Scoops-Server-*-"$BUILD_NUMBER".zip | head -1)"
[[ -f "$DMG" && -f "$ZIP" ]] || die "DMG oder ZIP fehlt in $OUT/build"
APP="$WORK/stage/AIS Scoops Server.app"
INFO="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")"
BUILT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")"
[[ "$BUILT" == "$BUILD_NUMBER" ]] || die "Build-Nummer im Bundle ($BUILT) ≠ $BUILD_NUMBER"
SERVER_VERSION="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$ROOT/Server/src/aisbot/version.py")"

# -- 2. Sparkle-Werkzeuge und Schlüssel -----------------------------------------------------
BIN="$WORK/derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$BIN/sign_update" ]] || die "Sparkle-Werkzeuge fehlen ($BIN)"
PUB="$("$BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null)" \
  || die "Kein Sparkle-Schlüssel im Schlüsselbund (Account $ACCOUNT). Siehe docs/updates.md."
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$INFO")"
[[ "$PUB" == "$PLIST_KEY" ]] || die "SUPublicEDKey der App passt nicht zum Schlüssel im Schlüsselbund ($ACCOUNT)."
FEED_IN_APP="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$INFO")"
[[ "$FEED_IN_APP" == "$FEED" ]] || die "SUFeedURL der App ($FEED_IN_APP) ≠ $FEED"
codesign --verify --deep --strict "$APP" || die "Signatur der App ungültig"

step "Update signieren (EdDSA)"
# sign_update darf den Schlüsselbund-Eintrag nicht ohne Passwortabfrage lesen (er gehört generate_keys). Deshalb
# exportiert generate_keys ihn kurz in einen privaten Ordner (umask 077), sign_update liest ihn dort, danach wird er
# überschrieben und gelöscht. Ausgegeben wird er nie.
KEYDIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ais-sparkle.XXXXXX")"
trap 'rm -P "$KEYDIR/key" 2>/dev/null; rm -rf "$KEYDIR"' EXIT
"$BIN/generate_keys" --account "$ACCOUNT" -x "$KEYDIR/key" >/dev/null 2>&1 || die "Schlüssel ließ sich nicht lesen ($ACCOUNT)"
SIG_ATTRS="$("$BIN/sign_update" --ed-key-file "$KEYDIR/key" "$ZIP")"   # sparkle:edSignature="…" length="…"
rm -P "$KEYDIR/key"
rmdir "$KEYDIR"
[[ "$SIG_ATTRS" == *'sparkle:edSignature="'* ]] || die "sign_update lieferte keine Signatur"

# -- 3. Appcast ------------------------------------------------------------------------------
TAG="v$VERSION-$BUILD_NUMBER"
ZIP_NAME="${ZIP:t}"
DMG_NAME="${DMG:t}"
NOTES="${NOTES:-App $VERSION ($BUILD_NUMBER) mit Server $SERVER_VERSION.}"
step "appcast.xml ergänzen ($TAG)"
/usr/bin/python3 -I - "$OUT/published.xml" "$OUT/appcast.xml" "$VERSION" "$BUILD_NUMBER" \
  "https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME" "$SIG_ATTRS" "$NOTES" "$KEEP_ITEMS" <<'PY'
import html, os, re, sys
from email.utils import formatdate
src, dst, version, build, url, sig, notes, keep = sys.argv[1:]
items = []
if os.path.exists(src):
    xml = open(src, encoding="utf-8").read()
    items = re.findall(r"<item>.*?</item>", xml, re.S)
builds = [int(b) for i in items for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", i)]
if builds and int(build) <= max(builds):
    sys.exit(f"Build {build} ist nicht höher als der höchste veröffentlichte ({max(builds)}).")
item = f"""<item>
            <title>Version {html.escape(version)} ({build})</title>
            <pubDate>{formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
            <enclosure url="{html.escape(url)}" {sig} type="application/octet-stream"/>
        </item>"""
items = [item] + items[: int(keep) - 1]
body = "\n        ".join(items)
open(dst, "w", encoding="utf-8").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>AIS Scoops Server</title>
        <language>de</language>
        {body}
    </channel>
</rss>
""")
PY
/usr/bin/xmllint --noout "$OUT/appcast.xml" || die "appcast.xml ist kein gültiges XML"
cp "$DMG" "$OUT/AIS-Scoops-Server.dmg"   # fester Name: …/releases/latest/download/AIS-Scoops-Server.dmg

if [[ "$PUBLISH" != 1 ]]; then
  step "PUBLISH=0: nichts veröffentlicht. Dateien: $OUT"
  exit 0
fi

# -- 4. Veröffentlichen ----------------------------------------------------------------------
step "GitHub-Release $TAG in $REPO"
gh release create "$TAG" --repo "$REPO" --latest --title "AIS Scoops Server $VERSION ($BUILD_NUMBER)" \
  --notes "$NOTES" "$ZIP" "$DMG" "$OUT/AIS-Scoops-Server.dmg" "$OUT/appcast.xml"

# -- 5. Öffentlich erreichbar? (ohne Anmeldung) ------------------------------------------------
step "Prüfe Feed und Download ohne Anmeldung"
ok=0
for i in {1..20}; do
  if env -u GH_TOKEN -u GITHUB_TOKEN curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "$FEED" -o "$OUT/check.xml" 2>/dev/null \
     && grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$OUT/check.xml"; then ok=1; break; fi
  /bin/sleep 3
done
[[ "$ok" == 1 ]] || die "Der öffentliche Feed zeigt Build $BUILD_NUMBER nicht: $FEED"
env -u GH_TOKEN -u GITHUB_TOKEN curl -fsSL --max-time 300 "https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME" -o "$OUT/check.zip" \
  || die "ZIP nicht öffentlich ladbar"
[[ "$(shasum -a 256 < "$OUT/check.zip")" == "$(shasum -a 256 < "$ZIP")" ]] || die "Geladenes ZIP weicht ab"
dmg_code="$(curl -sL --max-time 60 -o /dev/null -w '%{http_code}' "https://github.com/$REPO/releases/latest/download/AIS-Scoops-Server.dmg")"
[[ "$dmg_code" == 200 ]] || die "DMG-Link antwortet $dmg_code"
rm -f "$OUT/check.zip" "$OUT/check.xml"
print -P "%F{green}✓%f Feed und Download öffentlich erreichbar."

if [[ "$DESKTOP" == 1 ]]; then
  ditto "$DMG" "$HOME/Desktop/AIS Scoops Server.dmg"
  step "DMG: ~/Desktop/AIS Scoops Server.dmg"
fi
echo
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "Feed:    $FEED"
