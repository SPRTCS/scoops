#!/bin/zsh
# Baut „AIS Scoops Server.dmg“: Release-Build der Mac-App (Ziel ScoopsConnect) + mitgelieferter Python-Server,
# signiert mit „Developer ID Application“ (Hardened Runtime, alle eingebetteten Binärdateien), DMG mit Hintergrund
# und Programme-Verknüpfung, Notarisierung (notarytool, API-Schlüssel) und Stapeln. Daneben das ZIP, aus dem Sparkle
# Updates installiert (Veröffentlichen: scripts/release-server.sh, docs/updates.md).
#
#   scripts/build-server-dmg.sh                 # alles, Ergebnis in App/build/server-dmg/
#   NOTARIZE=0 scripts/build-server-dmg.sh      # ohne Notarisierung (nur signieren)
#   BUILD_NUMBER=7 scripts/build-server-dmg.sh  # Build-Nummer setzen (Standard: Zeitstempel)
#
# Fehlt das Developer-ID-Zertifikat, wird zum Testen mit „Apple Development“ signiert und nicht notarisiert;
# das Skript sagt das am Ende deutlich. Der API-Schlüssel (.p8) wird nur gelesen, nie kopiert oder ausgegeben.
set -euo pipefail
setopt null_glob

APPDIR="${0:A:h}/.."
OUT="${OUT:-$APPDIR/build/server-dmg}"   # nur die fertige DMG (+ Notarisierungsprotokoll)
# Arbeitsordner außerhalb von iCloud/Documents: dort hängen Finder-/Dateianbieter-Attribute an, die codesign ablehnt.
WORK="${WORK:-${TMPDIR:-/tmp}/ais-scoops-server-build}"
TEAM="MYXQKK3T2Z"
APP_NAME="AIS Scoops Server"
VOLNAME="AIS Scoops Server"
ASC_KEY="${ASC_KEY:-$HOME/Documents/Projects/Apps/AuthKey_${ASC_KEY_ID:-B2M5G9DH6U}.p8}"
ASC_KEY_ID="${ASC_KEY_ID:-B2M5G9DH6U}"
ASC_ISSUER="${ASC_ISSUER:-0129d0a3-d63c-4162-a69b-f6ff28b5314e}"
NOTARIZE="${NOTARIZE:-1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DD="$WORK/derived"
STAGE="$WORK/stage"
APP="$STAGE/$APP_NAME.app"

step() { print -P "%F{blue}▸%f $*"; }
die() { print -P "%F{red}✗%f $*" >&2; exit 1; }

# -- Signier-Identität -----------------------------------------------------------------
IDENTITY="$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" | head -1 | tr -d '"' || true)"
if [[ -n "$IDENTITY" ]]; then
  DEV_ID=1
else
  DEV_ID=0
  NOTARIZE=0
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"
  [[ -n "$IDENTITY" ]] || die "Kein Signier-Zertifikat gefunden (security find-identity -v -p codesigning)."
fi
step "Signiere mit: $IDENTITY"

rm -rf "$WORK/stage" "$WORK/dmg" "$OUT"
mkdir -p "$OUT" "$STAGE" "$WORK/dmg"

# -- 1. App bauen (unsigniert; signiert wird unten nach dem Einfügen des Servers) ----------
# Pakete (Sparkle) ohne Schlüsselbund laden: sonst fragt xcodebuild nach dem github.com-Eintrag und hängt.
step "Release-Build (Build $BUILD_NUMBER)"
cd "$APPDIR"
[[ -x /opt/homebrew/bin/xcodegen ]] && /opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project AISBot.xcodeproj -scheme ScoopsConnect -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" -packageAuthorizationProvider netrc CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build -quiet
ditto "$DD/Build/Products/Release/$APP_NAME.app" "$APP"

# -- 2. Python-Server einfügen ------------------------------------------------------------
step "Python-Server einfügen"
"$APPDIR/scripts/build-server-runtime.sh" "$APP/Contents/Resources/server"

# -- 3. Signieren -------------------------------------------------------------------------
xattr -cr "$APP"
ENT_DIR="$WORK/entitlements"
mkdir -p "$ENT_DIR"
# App: Entitlements aus dem Projekt (Hardened Runtime: Kalender/Erinnerungen und Kontakte für die Apple-Dienste).
# Ohne sie lehnt macOS den Zugriff ab, ohne überhaupt nachzufragen.
cp "$APPDIR/ScoopsConnect/ScoopsConnect.entitlements" "$ENT_DIR/app.plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.calendars' "$ENT_DIR/app.plist" >/dev/null \
  || die "Entitlement personal-information.calendars fehlt in ScoopsConnect.entitlements"
# Python braucht unter Hardened Runtime keine Ausnahmen, solange alle Erweiterungen mit derselben Team-ID
# signiert sind (Bibliotheksprüfung). Zusätzliche Rechte nur bei Bedarf über PYTHON_ENTITLEMENTS.
cat > "$ENT_DIR/python.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PL
if [[ -n "${PYTHON_ENTITLEMENTS:-}" ]]; then cp "$PYTHON_ENTITLEMENTS" "$ENT_DIR/python.plist"; fi

SIGN=(codesign --force --options runtime --sign "$IDENTITY")
[[ "$DEV_ID" == 1 ]] && SIGN+=(--timestamp) || SIGN+=(--timestamp=none)

step "Eingebettete Binärdateien signieren"
count=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then
    if [[ "$f" == */bin/python3.* ]]; then
      "${SIGN[@]}" --entitlements "$ENT_DIR/python.plist" "$f" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: $f"
    elif codesign -d --entitlements - --xml "$f" 2>/dev/null | grep -q "<key>"; then
      # Agent-CLIs des Aufgabenmodus (claude, codex …, docs/aufgaben.md): JIT-Entitlements der Hersteller behalten,
      # sonst startet die Laufzeit (Bun/V8) unter Hardened Runtime nicht.
      "${SIGN[@]}" --preserve-metadata=entitlements "$f" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: $f"
    else
      "${SIGN[@]}" "$f" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: $f"
    fi
    count=$((count + 1))
  fi
done < <(find "$APP/Contents/Resources/server" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
step "$count Binärdateien signiert"

# Sparkle (Selbstaktualisierung, docs/updates.md): von innen nach außen mit Developer ID und Hardened Runtime,
# wie in Sparkles Anleitung; der Downloader behält seine Entitlements.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPK" ]]; then
  step "Sparkle signieren"
  "${SIGN[@]}" "$SPK/Versions/B/XPCServices/Installer.xpc" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc" >/dev/null 2>&1 \
    || die "Signieren fehlgeschlagen: Downloader.xpc"
  "${SIGN[@]}" "$SPK/Versions/B/Autoupdate" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: Autoupdate"
  "${SIGN[@]}" "$SPK/Versions/B/Updater.app" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: Updater.app"
  "${SIGN[@]}" "$SPK" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: Sparkle.framework"
fi

step "App signieren"
"${SIGN[@]}" --entitlements "$ENT_DIR/app.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# -- 4. Selbsttest im signierten Bundle (Hardened Runtime, eigener Temp-Ordner, nie Armans Server) --
step "Selbsttest des signierten Servers"
T="$(mktemp -d -t aisbot-dmgtest)"
env -i HOME="$HOME" PATH=/usr/bin:/bin AISBOT_HOME="$T" AISBOT_EDITION=standard AISBOT_OFFLINE=1 \
  AISBOT_KEYCHAIN_PREFIX=ais-scoops-selftest "$APP/Contents/Resources/server/bin/python3" -I -B -c \
  'import aisbot.server as s, ssl, sqlite3, uvloop, pydantic_core, cryptography.hazmat.bindings._rust, PIL.Image; print("Selbsttest ok:", s.VERSION, s.profile.edition())' \
  | tail -1 || die "Der signierte Server startet nicht (Hardened Runtime?)."
# Aufgabenmodus: beide Agent-CLIs müssen im signierten Bundle starten (Entitlements, Bibliotheksprüfung)
SITE_DIR="$(find "$APP/Contents/Resources/server/lib" -maxdepth 2 -type d -name site-packages | head -1)"
env -i HOME="$T" PATH=/usr/bin:/bin "$SITE_DIR/claude_agent_sdk/_bundled/claude" --version | tail -1 \
  || die "Claude-CLI (Agent SDK) startet im signierten Bundle nicht."
env -i HOME="$T" PATH=/usr/bin:/bin CODEX_HOME="$T/codex" "$SITE_DIR/codex_cli_bin/bin/codex" --version | tail -1 \
  || die "Codex-CLI startet im signierten Bundle nicht."
rm -rf "$T"

# -- 5. DMG -------------------------------------------------------------------------------
step "DMG bauen"
BG="$WORK/dmg/background.png"
uv run --quiet --no-project --with pillow python "$APPDIR/scripts/dmg-background.py" "$BG"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$WORK/dmg/AIS-Scoops-Server-$VERSION-$BUILD_NUMBER.dmg"
cat > "$WORK/dmg/dmg-settings.py" <<PY
import os
application = "$APP"
appname = os.path.basename(application)
format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Programme": "/Applications"}
background = "$BG"
icon_size = 128
text_size = 13
window_rect = ((200, 120), (640, 400))
icon_locations = {appname: (160, 190), "Programme": (480, 190)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
PY
uv run --quiet --no-project --with dmgbuild python -m dmgbuild -s "$WORK/dmg/dmg-settings.py" "$VOLNAME" "$DMG"
"${SIGN[@]}" "$DMG"

# -- 6. Notarisieren ------------------------------------------------------------------------
if [[ "$NOTARIZE" == 1 ]]; then
  [[ -r "$ASC_KEY" ]] || die "API-Schlüssel nicht lesbar: $ASC_KEY"
  step "Notarisieren (kann einige Minuten dauern)"
  xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait \
    --output-format json > "$OUT/notary.json" || true
  STATUS="$(/usr/bin/python3 -c "import json;print(json.load(open('$OUT/notary.json')).get('status',''))" 2>/dev/null || echo "")"
  if [[ "$STATUS" != "Accepted" ]]; then
    SUB="$(/usr/bin/python3 -c "import json;print(json.load(open('$OUT/notary.json')).get('id',''))" 2>/dev/null || echo "")"
    [[ -n "$SUB" ]] && xcrun notarytool log "$SUB" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" "$OUT/notary-log.json" || true
    die "Notarisierung: ${STATUS:-Fehler} (Details: $OUT/notary-log.json)"
  fi
  step "Stapeln"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # Die Notarisierung der DMG deckt die App darin ab: Ticket auch an die App heften (für das Sparkle-ZIP).
  xcrun stapler staple "$APP" >/dev/null 2>&1 || print -P "%F{yellow}Hinweis:%f App ließ sich nicht stapeln (Gatekeeper prüft dann online)."
fi

# -- 6b. Update-Archiv für Sparkle (scripts/release-server.sh) ------------------------------------
ZIP="$OUT/AIS-Scoops-Server-$VERSION-$BUILD_NUMBER.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# -- 7. Prüfen ------------------------------------------------------------------------------
step "Gatekeeper-Prüfung"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true
spctl -a -vv -t exec "$APP" 2>&1 || true
FINAL="$OUT/${DMG:t}"
ditto "$DMG" "$FINAL"
xattr -c "$FINAL" 2>/dev/null || true
du -h "$FINAL" | awk '{print "Größe: " $1}'
echo
echo "DMG: $FINAL"
echo "ZIP: $ZIP"
if [[ "$DEV_ID" != 1 ]]; then
  print -P "%F{yellow}ACHTUNG:%f Kein „Developer ID Application“-Zertifikat – nur mit Apple Development signiert und NICHT notarisiert."
  print -P "Diese DMG läuft nur auf Armans eigenen Macs. Nach dem Anlegen des Zertifikats das Skript erneut ausführen."
elif [[ "$NOTARIZE" != 1 ]]; then
  print -P "%F{yellow}Hinweis:%f Signiert mit Developer ID, aber nicht notarisiert (NOTARIZE=0)."
else
  print -P "%F{green}✓%f Signiert (Developer ID), notarisiert und gestapelt."
fi
