#!/bin/bash
# Läuft IN der Bot-VM (Benutzer lume, SIP aus). Installiert den Cua-Computer-Server,
# erteilt ihm Bedienungshilfen- und Bildschirmaufnahme-Rechte und startet ihn bei Anmeldung.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install --quiet --python 3.12 --force "cua-computer-server[macos]"

TOOL_PY="$HOME/.local/share/uv/tools/cua-computer-server/bin/python"
# cua-computer-server 0.3.46 übergibt FastAPI eine Option, die neuere FastAPI-Versionen nicht kennen.
MAIN="$("$TOOL_PY" -c 'import importlib.util as u;print(u.find_spec("computer_server").submodule_search_locations[0])')/main.py"
sed -i '' '/websocket_max_size=WEBSOCKET_MAX_SIZE,/d' "$MAIN"
REAL_PY="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TOOL_PY")"
DB="/Library/Application Support/com.apple.TCC/TCC.db"
for client in "$REAL_PY" "$TOOL_PY"; do
  for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
    echo lume | sudo -S -p "" sqlite3 "$DB" \
      "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('$svc', '$client', 1, 2, 4, 1, 0);"
  done
done

PLIST="$HOME/Library/LaunchAgents/com.aisbot.computer-server.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.aisbot.computer-server</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/.local/bin/cua-computer-server</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>8000</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/computer-server.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/computer-server.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/com.aisbot.computer-server" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Python: $REAL_PY"
echo fertig
