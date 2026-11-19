#!/bin/zsh
# Baut den Python-Server für die Mac-App „AIS Scoops Server“ als eigenständigen Ordner:
#   <ziel>/bin/python3          relocatable CPython (python-build-standalone über uv, nur Apple Silicon)
#   <ziel>/lib/python3.12/site-packages   Abhängigkeiten aus Server/uv.lock + Paket `aisbot`
# Der Ordner kommt nach „AIS Scoops Server.app/Contents/Resources/server“ (siehe build-server-dmg.sh).
# Gestartet wird er von der App mit `python3 -I -B -u -c "from aisbot.server import main; main()"`.
#
#   scripts/build-server-runtime.sh <ziel-ordner>
set -euo pipefail
OUT="${1:?Zielordner angeben}"
PYVER="${AISBOT_RUNTIME_PYTHON:-3.12}"
ROOT="${0:A:h}/../.."
SERVER="$ROOT/Server"

[[ "$(uname -m)" == "arm64" ]] || { echo "Nur auf Apple Silicon bauen (arm64)."; exit 1; }
command -v uv >/dev/null || { echo "uv fehlt (brew install uv)."; exit 1; }

echo "▸ Python $PYVER (python-build-standalone) holen"
uv python install --quiet "$PYVER"
SRC_PY="$(uv python find --managed-python "$PYVER")"
SRC_HOME="$(cd "$(dirname "$SRC_PY")/.." && pwd -P)"

rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$SRC_HOME" "$OUT"
PY="$OUT/bin/python3"
SITE="$("$PY" -I -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
STDLIB="$("$PY" -I -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')"

echo "▸ Unnötiges entfernen (Tk, Tests, IDLE, pip, Header)"
rm -rf "$OUT"/lib/tcl* "$OUT"/lib/tk* "$OUT"/lib/itcl* "$OUT"/lib/thread* "$OUT"/lib/libtcl* "$OUT"/lib/pkgconfig \
       "$OUT"/include "$OUT"/share \
       "$STDLIB"/test "$STDLIB"/idlelib "$STDLIB"/tkinter "$STDLIB"/turtledemo "$STDLIB"/ensurepip \
       "$STDLIB"/lib2to3 "$STDLIB"/lib-dynload/_tkinter*.so "$STDLIB"/config-3.*-darwin \
       "$SITE"/pip "$SITE"/pip-*.dist-info

echo "▸ Abhängigkeiten aus uv.lock installieren"
REQ="$(mktemp -t aisbot-req)"
(cd "$SERVER" && uv export --quiet --frozen --no-hashes --no-emit-project --no-dev --format requirements-txt > "$REQ")
uv pip install --quiet --python "$PY" --break-system-packages --no-cache --compile-bytecode=false -r "$REQ" 2>/dev/null \
  || uv pip install --quiet --python "$PY" --break-system-packages --no-cache -r "$REQ"
rm -f "$REQ"

# Konsolenskripte der Pakete (absolute Shebangs) und Hilfsprogramme werden nicht gebraucht
find "$OUT/bin" -mindepth 1 ! -name 'python3' ! -name 'python3.12' -delete

echo "▸ Server-Code (aisbot) einfügen"
rsync -a --delete --exclude '__pycache__' "$SERVER/src/aisbot/" "$SITE/aisbot/"

echo "▸ Bytecode vorkompilieren (unchecked-hash: im signierten Bundle wird nie etwas geschrieben)"
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} +
"$PY" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$OUT/lib" >/dev/null || true

echo "▸ Selbsttest (eigener Temp-Datenordner, nie Armans Server)"
T="$(mktemp -d -t aisbot-selftest)"
env -i HOME="$HOME" PATH=/usr/bin:/bin AISBOT_HOME="$T" AISBOT_EDITION=standard AISBOT_OFFLINE=1 \
  AISBOT_KEYCHAIN_PREFIX=ais-scoops-selftest "$PY" -I -B -c \
  'import aisbot.server as s, fastapi, uvicorn, anthropic, cryptography, PIL, claude_agent_sdk, openai_codex; print("ok", s.VERSION, s.profile.edition(), len(s.db.bots()))' \
  | tail -1
rm -rf "$T"
du -sh "$OUT" | awk '{print "▸ Größe: " $1}'
