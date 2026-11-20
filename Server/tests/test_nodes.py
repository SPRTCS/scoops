"""Test für Scoops Connect (Server 1.11): Kopplung, WebSocket-Rechner, Befehle über den Hub.

Startet eine eigene Testinstanz im Prozess (eigene Datenbank und Konfiguration in einem Temp-Ordner,
eigener Port, ohne MCP/VM-Wächter) – niemals die laufende Produktion auf 8787.

    cd Server && uv run python tests/test_nodes.py
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import socket
import sqlite3
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-nodes-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "public_url": "https://scoops.example.test"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from PIL import Image  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import server  # noqa: E402
from aisbot.engine import Engine  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
from aisbot.version import VERSION as VERSION_EXPECTED  # noqa: E402
BASE = f"http://127.0.0.1:{PORT}"
WS = f"ws://127.0.0.1:{PORT}/api/nodes/link"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def png(w: int, h: int, color=(200, 30, 30)) -> str:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


class FakeNode:
    """Spielt Scoops Connect: hello, beantwortet cmd, ping/pong, merkt sich bye."""

    def __init__(self, token: str, screen=(320, 200)):
        self.token, self.screen = token, screen
        self.received: list[dict] = []
        self.commands: list[dict] = []
        self.bye: str | None = None
        self.welcome: dict | None = None
        self.closed = threading.Event()
        self.connected = threading.Event()
        self.ignore: set[str] = set()
        self.loop = asyncio.new_event_loop()
        self.ws = None
        threading.Thread(target=self.loop.run_until_complete, args=(self._run(),), daemon=True).start()

    async def _run(self) -> None:
        try:
            async with connect(WS, additional_headers={"Authorization": f"Bearer {self.token}"}) as ws:
                self.ws = ws
                try:
                    await ws.send(json.dumps({"type": "hello", "node_id": "?", "name": "Fake-Mac", "mode": "direct",
                                              "os": "macOS 27.0", "app_version": "1.0 (1)",
                                              "screen": {"width": self.screen[0], "height": self.screen[1]}, "paused": False}))
                except Exception:  # noqa: BLE001 – Server hat schon „bye“ geschickt und geschlossen (unbekanntes Token,
                    pass           # unter Last schneller als das hello): die Nachricht steht noch zum Lesen bereit
                self.connected.set()
                async for raw in ws:
                    m = json.loads(raw)
                    self.received.append(m)
                    t = m.get("type")
                    if t == "bye":
                        self.bye = m.get("reason")
                    elif t == "welcome":
                        self.welcome = m
                    elif t == "ping":
                        await ws.send('{"type":"pong"}')
                    elif t == "cmd":
                        self.commands.append(m)
                        if m["command"] in self.ignore:
                            continue
                        await ws.send(json.dumps({"type": "result", "id": m["id"], "result": self.answer(m)}))
        except Exception as e:  # noqa: BLE001
            self.error = e
        finally:
            self.connected.set()
            self.closed.set()

    def answer(self, m: dict) -> dict:
        c, p = m["command"], m.get("params") or {}
        if c == "get_screen_size":
            return {"success": True, "size": {"width": self.screen[0], "height": self.screen[1]}}
        if c == "screenshot":  # Retina: doppelte Auflösung, der Server skaliert herunter
            return {"success": True, "image_data": png(self.screen[0] * 2, self.screen[1] * 2)}
        if c == "get_cursor_position":
            return {"success": True, "position": {"x": 11, "y": 22}}
        if c == "run_command":
            return {"success": True, "stdout": "/Users/fake" if "HOME" in p.get("command", "") else "ok\n",
                    "stderr": "", "return_code": 0}
        if c == "explode":
            return {"success": False, "error": "kaputt"}
        if c == "read_bytes":  # Pfad /groesse/<Bytes>: Datei dieser Größe, `length` wie die Mac-App
            size = int(p["path"].rsplit("/", 1)[-1])
            n = size if p.get("length") is None else min(size, p["length"])
            return {"success": True, "content_b64": base64.b64encode(b"x" * n).decode()}
        return {"success": True}

    def send(self, data: dict) -> None:
        asyncio.run_coroutine_threadsafe(self.ws.send(json.dumps(data)), self.loop).result(5)

    def close(self) -> None:
        if self.ws and not self.closed.is_set():
            asyncio.run_coroutine_threadsafe(self.ws.close(), self.loop)  # Schließ-Handshake läuft im Hintergrund
        self.closed.wait(15)


def wait_for(fn, timeout=5.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20,
                         ws_max_size=server.WS_MAX_SIZE)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")

    print("Grundlagen")
    ok(http.get("/api/health").status_code == 401, "Health ohne Token → 401")
    ok(http.get("/api/health", headers=H).json()["version"] == VERSION_EXPECTED, f"Version {VERSION_EXPECTED}")
    nodes = http.get("/api/nodes", headers=H).json()
    ok(nodes[0]["id"] == "vm" and nodes[0]["builtin"] and nodes[0]["name"] == "Bot-Rechner", "GET /api/nodes enthält vm")
    ok(http.post("/api/nodes/pair").status_code == 401, "pair ohne Token → 401")
    ok(http.delete("/api/nodes/vm", headers=H).status_code == 400, "vm nicht löschbar")

    print("Kopplung")
    ok(http.post("/api/nodes/claim", json={"code": "AAAA-BBBB"}).status_code == 404, "falscher Code → 404")
    p = http.post("/api/nodes/pair", headers=H).json()
    ok(len(p["code"]) == 9 and p["code"][4] == "-" and p["server_url"] == "https://scoops.example.test",
       f"Code {p['code'][:2]}…, server_url aus public_url")
    claim = {"code": p["code"].lower().replace("-", " "), "name": "Mac mini Büro", "mode": "direct", "os": "macOS 27.0",
             "app_version": "1.0 (1)"}
    r = http.post("/api/nodes/claim", json=claim)
    ok(r.status_code == 200 and r.json()["node_id"].startswith("n_"), "claim → node_id + Token (Code tolerant geschrieben)")
    nid, ntok = r.json()["node_id"], r.json()["node_token"]
    ok(http.post("/api/nodes/claim", json=claim).status_code == 404, "Code nur einmal gültig")
    row = sqlite3.connect(server.db.path).execute("SELECT token_hash FROM nodes WHERE id=?", (nid,)).fetchone()
    ok(row and row[0] != ntok and len(row[0]) == 64, "DB speichert nur SHA-256-Hash")
    n = next(x for x in http.get("/api/nodes", headers=H).json() if x["id"] == nid)
    ok(not n["online"] and n["name"] == "Mac mini Büro" and n["state"] == "asleep", "neuer Rechner offline")

    print("Offline-Verhalten")
    t0 = time.time()
    r = http.get("/api/computer/screen.jpg", params={"node": nid}, headers=H)
    ok(r.status_code == 503 and "offline" in r.json()["error"] and time.time() - t0 < 2, "Bildschirm offline → 503 sofort")
    ok(http.get("/api/computer", params={"node": "n_gibtsnicht"}, headers=H).status_code == 404, "unbekannter Rechner → 404")
    hub = server.computers.get(nid)
    ok("offline" in server.service.computer_note(hub), "Prompt-Hinweis: offline")

    print("Verbindung")
    bad = FakeNode("falsches-token")
    bad.closed.wait(5)
    # Der Server schickt bye und schließt mit 4401; je nach Zeitpunkt sieht der Client nur den Schließcode.
    ok((bad.bye and "nicht" in bad.bye) or "4401" in repr(getattr(bad, "error", "")),
       f"falsches Token → bye/4401 ({bad.received} {getattr(bad, 'error', '')!r})")
    node = FakeNode(ntok)
    node.connected.wait(5)
    wait_for(lambda: node.welcome is not None, msg="welcome")
    ok(node.welcome["node_id"] == nid, "hello → welcome mit node_id")
    n = next(x for x in http.get("/api/nodes", headers=H).json() if x["id"] == nid)
    ok(n["online"] and n["screen"] == {"width": 320, "height": 200} and n["os"] == "macOS 27.0", "online mit Bildschirm")
    st = http.get("/api/computer", params={"node": nid}, headers=H).json()
    ok(st["state"] == "awake" and st["node_id"] == nid and st["width"] == 320, "GET /api/computer?node= → awake")
    ok(server.service.computer_note(hub) and "offline" not in server.service.computer_note(hub), "kein Offline-Hinweis mehr")

    print("Befehle über den Hub (Thread → WebSocket)")
    c = hub.acquire("b_test")
    ok(c.screen.width == 320, "get_screen_size")
    blocks = Engine._exec_computer(c, "screenshot", {})
    img = Image.open(io.BytesIO(base64.b64decode(blocks[0]["source"]["data"])))
    ok(img.size == (320, 200), "screenshot auf logische Größe skaliert (640×400 → 320×200)")
    Engine._exec_computer(c, "left_click", {"coordinate": [12, 34]})
    last = node.commands[-1]
    ok(last["command"] == "left_click" and last["params"] == {"x": 12, "y": 34}, "left_click mit x/y")
    Engine._exec_computer(c, "key", {"text": "cmd+t"})
    ok(node.commands[-1]["command"] == "hotkey" and node.commands[-1]["params"]["keys"] == ["command", "t"], "hotkey")
    ok(Engine._exec_computer(c, "cursor_position", {}) == "[11, 22]", "get_cursor_position")
    ok("Rückgabecode 0" in Engine._exec_terminal(c, {"command": "echo hi"}), "run_command")
    ok(hub.expand_home("~/Downloads/x") == "/Users/fake/Downloads/x", "~ wird auf dem Rechner aufgelöst")
    try:
        c.cmd("explode")
        ok(False, "Fehler wird gemeldet")
    except Exception as e:  # noqa: BLE001
        ok("kaputt" in str(e), "success:false → ComputerError")
    # parallel: zwei Threads gleichzeitig (eigene ids)
    res: list = []
    ts = [threading.Thread(target=lambda: res.append(c.cmd("get_cursor_position"))) for _ in range(5)]
    [t.start() for t in ts]
    [t.join(10) for t in ts]
    ok(len(res) == 5, "5 parallele Befehle korrekt zugeordnet")
    ok(http.get("/api/computer", params={"node": nid}, headers=H).json()["state"] == "busy", "belegt → busy")
    hub.release()
    ok(http.get("/api/computer", headers=H).json()["node_id"] == "vm", "vm bleibt Standard ohne ?node=")

    print("Bildschirm und Übernehmen über die API")
    r = http.get("/api/computer/screen.jpg", params={"node": nid, "scale": 0.5}, headers=H)
    ok(r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
       and Image.open(io.BytesIO(r.content)).size == (160, 100), "screen.jpg?node= (scale 0.5)")
    ok(http.post("/api/computer/input", params={"node": nid}, json={"type": "click", "x": 1, "y": 2}, headers=H).status_code == 409,
       "Eingabe ohne Übernahme → 409")
    ok(http.post("/api/computer/takeover", params={"node": nid}, headers=H).json()["state"] == "user", "takeover?node=")
    ok(server.computer_hub.holder is None, "vm bleibt frei")
    r = http.post("/api/computer/input", params={"node": nid}, json={"type": "click", "x": 5, "y": 6}, headers=H)
    ok(r.status_code == 200 and node.commands[-1]["command"] == "left_click" and node.commands[-1]["params"] == {"x": 5, "y": 6},
       "input?node= → left_click")
    http.post("/api/computer/input", params={"node": nid}, json={"type": "type", "text": "Hallo"}, headers=H)
    ok(node.commands[-1] == {**node.commands[-1], "command": "type_text", "params": {"text": "Hallo"}}, "type_text")
    ok(http.post("/api/computer/release", params={"node": nid}, headers=H).json()["ok"], "release?node=")
    ok(hub.holder is None, "wieder frei")

    print("Scoop-Feld computer_node")
    con = sqlite3.connect(server.db.path)
    con.execute("INSERT INTO bots(id,name,mascot,model,created_at,last_activity) VALUES('b_t1','Testi','{}','claude-haiku-5-5',"
                "datetime('now'),datetime('now'))")
    con.commit()
    ok(http.get("/api/bots/b_t1", headers=H).json()["computer_node"] == "vm", "Standard computer_node = vm")
    ok(http.patch("/api/bots/b_t1", json={"computer_node": "n_falsch"}, headers=H).status_code == 400, "unbekannter Rechner → 400")
    ok(http.patch("/api/bots/b_t1", json={"computer_node": nid}, headers=H).json()["computer_node"] == nid, "PATCH computer_node")
    ok(server.service.hub_for("b_t1") is hub, "Engine bekommt den Hub des Scoops")
    ok(http.patch("/api/bots/b_t1", json={"computer_node": None}, headers=H).json()["computer_node"] == "vm", "zurück auf vm")
    http.patch("/api/bots/b_t1", json={"computer_node": nid}, headers=H)

    print("Dateien vom Rechner (Server 1.18.3)")
    from aisbot.bots import FILE_FROM_COMPUTER_MAX, RunState
    tools = {t.schema["name"]: t for t in server.service._tools("b_t1", "b_t1", 0, RunState())}
    holen = tools["datei_vom_rechner"].handler
    r = holen({"pfad": "/groesse/20000000", "name": "gross.bin"})
    ok("20000000 Bytes" in r, f"20 MB (Base64 ~27 MB > 16 MiB Standard) kommen über den WebSocket: {r}")
    ok(node.commands[-1]["params"]["length"] == FILE_FROM_COMPUTER_MAX + 1, "datei_vom_rechner fragt höchstens 25 MB + 1 an")
    r = holen({"pfad": "/groesse/50000000", "name": "riesig.bin"})
    ok(r.startswith("Fehler: Datei ist größer als 25 MB"), f"zu groß → klare Meldung, nur 25 MB + 1 übertragen: {r[:60]}")
    ok(node.closed.is_set() is False, "Verbindung bleibt dabei offen")

    print("Pausieren")
    node.send({"type": "state", "paused": True})
    wait_for(lambda: hub.paused, msg="pausiert")
    r = http.get("/api/computer/screen.jpg", params={"node": nid}, headers=H)
    # Zwischenspeicher (1 s) kann noch ein Bild liefern; danach muss die Pause greifen
    time.sleep(1.1)
    r = http.get("/api/computer/screen.jpg", params={"node": nid}, headers=H)
    ok(r.status_code == 503 and "pausiert" in r.json()["error"], "pausiert → 503 „Rechner ist pausiert“")
    ok("pausiert" in server.service.computer_note(hub), "Prompt-Hinweis: pausiert")
    n = next(x for x in http.get("/api/nodes", headers=H).json() if x["id"] == nid)
    ok(n["paused"] and n["state"] == "asleep", "Liste zeigt pausiert")
    node.send({"type": "state", "paused": False})
    wait_for(lambda: not hub.paused, msg="fortgesetzt")

    print("Umbenennen, Trennen, Entfernen")
    r = http.patch(f"/api/nodes/{nid}", json={"name": "Büro-Mac"}, headers=H).json()
    ok(r["name"] == "Büro-Mac", "PATCH name")
    wait_for(lambda: any(m.get("type") == "renamed" for m in node.received), msg="renamed an Rechner")
    ok(http.patch("/api/nodes/vm", json={"name": "Air-VM"}, headers=H).json()["name"] == "Air-VM", "vm umbenennbar")
    http.patch("/api/nodes/vm", json={"name": "Bot-Rechner"}, headers=H)
    # Befehl, auf den der Rechner nie antwortet, und dann trennen: Warten endet sofort mit Fehler
    node.ignore.add("get_cursor_position")
    err: list = []
    th = threading.Thread(target=lambda: err.append(_try(lambda: hub.computer.cmd("get_cursor_position"))))
    th.start()
    time.sleep(0.3)
    node.close()
    th.join(5)
    ok(err and "getrennt" in str(err[0]), "offener Befehl endet beim Trennen mit Fehler")
    wait_for(lambda: not hub.transport.online, msg="offline nach Trennen")
    node2 = FakeNode(ntok)
    wait_for(lambda: node2.welcome is not None, msg="wiederverbunden")
    ok(hub.transport.online, "Wiederverbinden mit gleichem Token")
    r = http.delete(f"/api/nodes/{nid}", headers=H)
    ok(r.status_code == 200, "DELETE /api/nodes/{id}")
    node2.closed.wait(5)
    ok(node2.bye and "entfernt" in node2.bye, "verbundener Rechner bekommt bye")
    ok(http.get("/api/bots/b_t1", headers=H).json()["computer_node"] == "vm", "Scoop fällt auf vm zurück")
    again = FakeNode(ntok)
    again.closed.wait(5)
    ok(again.bye is not None, "altes Token → bye")
    ok(all(x["id"] != nid for x in http.get("/api/nodes", headers=H).json()), "Rechner aus der Liste entfernt")

    print("Rate-Limit")
    codes = [http.post("/api/nodes/claim", json={"code": f"ZZZZ{i:04d}"}).status_code for i in range(12)]
    ok(429 in codes, f"mehr als 10 Fehlversuche/min → 429 ({codes.count(404)}×404, {codes.count(429)}×429)")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


def _try(fn):
    try:
        return fn()
    except Exception as e:  # noqa: BLE001
        return e


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil
        shutil.rmtree(TMP, ignore_errors=True)
