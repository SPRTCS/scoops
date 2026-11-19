"""Ende-zu-Ende-Test: echte Scoops-Connect-App gegen eine ISOLIERTE Server-Testinstanz (API v1.11).

Eigene Temp-Datenbank, eigener Port, ohne MCP/VM – niemals die Produktion auf 8787.
Schickt nur harmlose Befehle (Bildschirmgröße, Screenshot, Cursorposition, `echo ok`, Dateien im Temp-Ordner).

    cd Server && uv run python ../App/ScoopsConnect/Tests/e2e_server.py "<Pfad>/AIS Scoops Server.app" [--menu-preview]
"""

from __future__ import annotations

import base64
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="scoops-connect-e2e-"))
TOKEN = "e2e-" + os.urandom(8).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "public_url": f"http://127.0.0.1:{PORT}"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
SERVER_SRC = Path(__file__).resolve().parents[3] / "Server" / "src"
sys.path.insert(0, str(SERVER_SRC))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import server  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=f"http://127.0.0.1:{PORT}", timeout=30)
results: list[tuple[str, bool, str]] = []


def check(name: str, cond, detail: str = "") -> None:
    results.append((name, bool(cond), detail))
    print(("  OK   " if cond else "  FEHL ") + name + (f" – {detail}" if detail else ""), flush=True)


def wait_for(fn, timeout=30.0, step=0.3):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(step)
    return None


def node_info(nid):
    return next((x for x in http.get("/api/nodes", headers=H).json() if x["id"] == nid), None)


def main() -> None:
    app = Path(sys.argv[1])
    # --menu-preview: App zeigt das Menü-Panel als Fenster; der Test hält die Belegung dann HOLD Sekunden,
    # damit es von außen per `screencapture -l` aufgenommen werden kann (Marker „MENU_READY“).
    menu_shot = "--menu-preview" in sys.argv
    hold = float(os.environ.get("HOLD", "8"))
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20,
                         ws_max_size=server.WS_MAX_SIZE)
    threading.Thread(target=uvicorn.Server(cfg).run, daemon=True).start()
    wait_for(lambda: http.get("/api/health").status_code == 200, 15)

    pair = http.post("/api/nodes/pair", headers=H).json()
    print(f"Testinstanz auf Port {PORT}, Code {pair['code']}", flush=True)
    args = [str(next((app / "Contents/MacOS").iterdir())), "-fakeserver", str(PORT), "-code", pair["code"].lower()]
    if menu_shot:
        args.append("-menupreview")
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        node = wait_for(lambda: next((x for x in http.get("/api/nodes", headers=H).json()
                                      if x["id"] != "vm" and x["online"]), None), 30)
        check("Kopplung + Verbindung (online)", node, json.dumps({k: node.get(k) for k in ("id", "name", "mode", "os", "screen")}) if node else "")
        if not node:
            return
        nid = node["id"]
        hub = server.computers.get(nid)

        con = sqlite3.connect(server.db.path)
        con.execute("INSERT INTO bots(id,name,mascot,model,created_at,last_activity) VALUES('b_mila','Mila','{}',"
                    "'claude-haiku-5-5',datetime('now'),datetime('now'))")
        con.commit()

        c = hub.acquire("b_mila")
        try:
            check("get_screen_size über den Hub", c.screen.width > 0, f"{c.screen.width}x{c.screen.height}")
            pos = c.cmd("get_cursor_position")
            check("get_cursor_position", "position" in pos, json.dumps(pos.get("position")))
            png = c.screenshot_png()
            check("screenshot (PNG)", png[:8] == b"\x89PNG\r\n\x1a\n", f"{len(png) // 1024} kB")
            r = c.shell("echo ok")
            check("run_command echo ok", r.get("stdout", "").strip() == "ok" and r.get("return_code") == 0, json.dumps(r)[:120])
            tmp = Path(tempfile.mkdtemp(prefix="scoops-connect-e2e-files-")) / "probe.txt"
            c.cmd("write_bytes", path=str(tmp), content_b64=base64.b64encode(b"hallo vom server").decode())
            back = base64.b64decode(c.cmd("read_bytes", path=str(tmp))["content_b64"])
            check("write_bytes/read_bytes", back == b"hallo vom server" and tmp.read_bytes() == back, str(tmp))
            n = node_info(nid)
            check("Belegung: Mila arbeitet (state busy)", n["state"] == "busy" and n.get("bot_name") == "Mila",
                  f"state={n['state']} bot={n.get('bot_name')}")
            r = http.get("/api/computer/screen.jpg", params={"node": nid, "scale": 0.25}, headers=H)
            check("GET /api/computer/screen.jpg?node=", r.status_code == 200 and r.headers["content-type"] == "image/jpeg")
            if menu_shot:
                print("MENU_READY", flush=True)
                time.sleep(hold)
        finally:
            hub.release()

        r = http.patch(f"/api/nodes/{nid}", json={"name": "Mac mini Büro"}, headers=H).json()
        check("Umbenennen (PATCH)", r["name"] == "Mac mini Büro")
        # Nach `renamed` bleibt der Name auch beim Wiederverbinden (hello überschreibt ihn nicht).
        time.sleep(1)
        check("Rechner bleibt online nach renamed", node_info(nid)["online"])

        r = http.delete(f"/api/nodes/{nid}", headers=H)
        check("Entfernen (DELETE) → bye", r.status_code in (200, 204))
        gone = wait_for(lambda: subprocess.run(["security", "find-generic-password", "-s", "scoops-connect",
                                                "-a", f"http://127.0.0.1:{PORT}"], capture_output=True).returncode != 0, 10)
        check("App löscht ihr Token nach bye", gone)
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        failed = [n for n, ok, _ in results if not ok]
        print(f"\n{len(results) - len(failed)}/{len(results)} Prüfungen bestanden", flush=True)
        os._exit(1 if failed or not results else 0)


if __name__ == "__main__":
    main()
