"""Test: Neukopplung ersetzt alte Rechner, gelöschte/verwaiste Rechner verschwinden überall (Edition „standard“).

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, ohne MCP/VM-Wächter) –
niemals die laufende Produktion auf 8787.

    cd Server && uv run python tests/test_nodes_replace.py
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-replace-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
# Alte LAN-Adresse mit falschem Port: der Server zieht sie beim Start auf den tatsächlichen Port.
(TMP / "config.json").write_text(json.dumps({"public_url": "http://Lenas-Mac.local:8787", "lan_url": "http://192.168.1.5:8787"}))
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-test-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import server  # noqa: E402
from aisbot.profile import _read_config  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
BASE = f"http://127.0.0.1:{PORT}"
WS = f"ws://127.0.0.1:{PORT}/api/nodes/link"
H = {"Authorization": f"Bearer {server.TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
published: list[tuple[str, dict]] = []
_orig_publish = server.events.publish


def _record(kind: str, data: dict) -> None:
    published.append((kind, data))
    _orig_publish(kind, data)


server.events.publish = _record


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=5.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


class FakeNode:
    """Minimaler Scoops-Connect-Rechner: hello (optional mit Geräte-ID), merkt sich bye/Schließcode."""

    def __init__(self, token: str, device_id: str | None = None):
        self.token, self.device_id = token, device_id
        self.bye: str | None = None
        self.welcome: dict | None = None
        self.close_code: int | None = None
        self.closed = threading.Event()
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_until_complete, args=(self._run(),), daemon=True).start()

    async def _run(self) -> None:
        try:
            async with connect(WS, additional_headers={"Authorization": f"Bearer {self.token}"}) as ws:
                hello = {"type": "hello", "name": "x", "mode": "direct", "os": "macOS 27.0", "app_version": "2.0 (1)",
                         "screen": {"width": 320, "height": 200}, "paused": False}
                if self.device_id:
                    hello["device_id"] = self.device_id
                await ws.send(json.dumps(hello))
                try:
                    async for raw in ws:
                        m = json.loads(raw)
                        if m.get("type") == "bye":
                            self.bye = m.get("reason")
                        elif m.get("type") == "welcome":
                            self.welcome = m
                        elif m.get("type") == "ping":
                            await ws.send('{"type":"pong"}')
                        elif m.get("type") == "cmd":
                            await ws.send(json.dumps({"type": "result", "id": m["id"], "result": {
                                "success": True, "size": {"width": 320, "height": 200}}}))
                finally:
                    self.close_code = ws.close_code
        except Exception as e:  # noqa: BLE001
            self.error = e
        finally:
            self.closed.set()


def claim(name: str, device: str | None = None) -> dict:
    code = http.post("/api/setup/node-pair").json()["code"]
    body = {"code": code, "name": name, "mode": "direct", "os": "macOS 27.0", "app_version": "2.0 (1)"}
    if device:
        body["device_id"] = device
    r = http.post("/api/nodes/claim", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def node_ids() -> list[str]:
    return [n["id"] for n in http.get("/api/nodes", headers=H).json()]


def bot(bid: str) -> dict:
    return http.get(f"/api/bots/{bid}", headers=H).json()


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")

    print("LAN-Adresse folgt dem Port")
    c = _read_config()
    ok(c["public_url"] == f"http://Lenas-Mac.local:{PORT}", "public_url (…local) auf aktuellen Port gezogen")
    ok(c["lan_url"] == f"http://192.168.1.5:{PORT}", "lan_url (private IP) auf aktuellen Port gezogen")
    ok(server.lan_url_for_port("https://lena.tail1.ts.net:10000", 1234) is None, "https-/Tailscale-Adresse bleibt unberührt")

    bots = http.get("/api/bots", headers=H).json()
    ok(len(bots) >= 1, "Start-Scoop vorhanden")
    pip = bots[0]["id"]

    print("Neukopplung mit gleicher Geräte-ID ersetzt den Eintrag")
    a = claim("Dieser Mac", device="dev-AAA")
    na = a["node_id"]
    ok(not a["reused"] and node_ids() == [na], "erste Kopplung legt Rechner an")
    http.patch("/api/setup/config", json={"default_computer_node": na})
    ok(bot(pip)["computer_node"] == na, "Start-Scoop arbeitet am neuen Rechner")
    old = FakeNode(a["node_token"])
    wait_for(lambda: old.welcome is not None, msg="alte Verbindung steht")
    published.clear()
    b = claim("Dieser Mac", device="dev-AAA")
    ok(b["reused"] and b["node_id"] == na and b["node_token"] != a["node_token"], "zweite Kopplung: gleiche ID, neues Token")
    ok(node_ids() == [na], "kein zweiter Eintrag in /api/nodes")
    ok(old.closed.wait(5), "alte Verbindung (altes Token) wurde getrennt")
    again = FakeNode(a["node_token"])
    again.closed.wait(5)
    rejected = (again.bye and "nicht" in again.bye) or "4401" in repr(getattr(again, "error", ""))
    ok(rejected, "altes Token gilt nicht mehr (bye bzw. Schließcode 4401)")
    new = FakeNode(b["node_token"])
    wait_for(lambda: new.welcome is not None, msg="neue Verbindung")
    ok(new.welcome["node_id"] == na, "neues Token verbindet mit demselben Rechner")
    ok(bot(pip)["computer_node"] == na, "Scoop bleibt zugeordnet")

    print("Alte Einträge ohne Geräte-ID werden über „Dieser Mac“ zusammengeführt")
    l1 = claim("Johannas Mac")["node_id"]
    l2 = claim("Johannas Mac")["node_id"]
    other = claim("Mac mini Büro")["node_id"]
    server.db.update_bot(pip, {"computer_node": l1})
    cur = claim("Johannas Mac", device="dev-BBB")["node_id"]
    ok(len({l1, l2, other, cur}) == 4 and set(node_ids()) == {na, l1, l2, other, cur}, "vorher: 5 Rechner (3× gleicher Name)")
    published.clear()
    r = http.post("/api/setup/this-mac", json={"node_id": cur, "device_id": "dev-BBB", "make_default": True})
    ok(r.status_code == 200 and sorted(r.json()["merged"]) == sorted([l1, l2]), "this-mac führt beide Alt-Einträge zusammen")
    ok(set(node_ids()) == {na, other, cur}, "Alt-Einträge aus /api/nodes verschwunden, fremder Mac bleibt")
    deleted = {d["id"] for k, d in published if k == "node.deleted"}
    ok(deleted == {l1, l2}, "node.deleted für beide Alt-Einträge")
    ok(bot(pip)["computer_node"] == cur, "Scoop vom Alt-Eintrag auf den aktuellen Rechner umgehängt")
    ok(any(k == "bot.updated" and d["id"] == pip for k, d in published), "bot.updated für umgehängten Scoop")
    ok(_read_config()["default_computer_node"] == cur, "aktueller Rechner ist Standard-Rechner")
    row = server.db.one("SELECT device_id FROM nodes WHERE id=?", (cur,))
    ok(row["device_id"] == "dev-BBB", "Geräte-ID gespeichert")
    ok(http.post("/api/setup/this-mac", json={"node_id": "n_gibtsnicht"}).status_code == 404, "unbekannter Rechner → 404")
    ok(http.post("/api/setup/this-mac", json={"node_id": cur}, headers={"X-Forwarded-For": "1.2.3.4"}).status_code == 403,
       "this-mac nur lokal")

    print("Ausdrückliches Ersetzen (replaces) und hello mit Geräte-ID")
    tagged = claim("Alter Name")
    r = http.post("/api/setup/this-mac", json={"node_id": cur, "device_id": "dev-BBB", "replaces": [tagged["node_id"]]})
    ok(tagged["node_id"] in r.json()["merged"] and tagged["node_id"] not in node_ids(), "replaces entfernt genannten Eintrag")
    t2 = claim("Mac ohne ID")
    fn = FakeNode(t2["node_token"], device_id="dev-CCC")
    wait_for(lambda: fn.welcome is not None, msg="welcome")
    row = server.db.one("SELECT device_id FROM nodes WHERE id=?", (t2["node_id"],))
    ok(row["device_id"] == "dev-CCC", "hello trägt fehlende Geräte-ID nach")
    t3 = claim("Mac ohne ID", device="dev-CCC")
    ok(t3["reused"] and t3["node_id"] == t2["node_id"], "spätere Neukopplung erkennt den Mac an der Geräte-ID")
    ok(fn.closed.wait(5), "alte Verbindung getrennt")

    print("Gelöschter Rechner verschwindet überall")
    server.db.update_bot(pip, {"computer_node": other})
    http.patch("/api/setup/config", json={"default_computer_node": other})
    published.clear()
    ok(http.delete(f"/api/nodes/{other}", headers=H).status_code == 200, "DELETE /api/nodes/{id}")
    ok(other not in node_ids(), "nicht mehr in /api/nodes")
    ok(other not in [n["id"] for n in http.get("/api/setup").json()["server"]["nodes"]], "nicht mehr in /api/setup")
    ok(("node.deleted", {"id": other}) in published, "node.deleted veröffentlicht")
    b = bot(pip)
    ok(b["computer_node"] != other and b["computer_node"] in node_ids(), f"Scoop zeigt auf existierenden Rechner ({b['computer_node']})")
    ok(_read_config()["default_computer_node"] in node_ids(), "Standard-Rechner auf existierenden Rechner umgestellt")
    ok(all(x["computer_node"] in node_ids() for x in http.get("/api/bots", headers=H).json()), "kein Scoop zeigt auf Gelöschtes")

    print("Verwaiste Verweise beim Start aufräumen")
    server.db.q("UPDATE bots SET computer_node='n_geist' WHERE id=?", (pip,))
    c = _read_config()
    c["default_computer_node"] = "n_geist"
    server.save_config(c)
    out = server.computers.cleanup_orphans()
    ok(pip in out["bots"] and server.db.bot_row(pip)["computer_node"] is None, "Scoop-Verweis auf n_geist entfernt")
    ok(out["default_after"] in node_ids(), "Standard-Rechner auf vorhandenen Rechner gesetzt")
    ok(bot(pip)["computer_node"] == out["default_after"], "Scoop arbeitet am Standard-Rechner (statt „vm“)")
    ok(server.computers.for_bot({"computer_node": "n_geist"}).node_id in node_ids(), "for_bot fällt auf vorhandenen Rechner zurück")

    print("Adressänderung wird sofort gemeldet")
    calls = []
    server.cloud.heartbeat_tick = lambda: calls.append(time.time())
    server.cloud.owner_id = lambda: "owner_test"
    http.patch("/api/setup/config", json={"public_url": "https://lena.tail1.ts.net:10000"})
    wait_for(lambda: calls, 3, "Herzschlag sofort ausgelöst")
    ok(True, "public_url geändert → Herzschlag sofort")
    calls.clear()
    http.patch("/api/setup/config", json={"user_name": "Lena"})
    time.sleep(0.3)
    ok(not calls, "ohne Adressänderung kein Sofort-Herzschlag")

    print(f"\n{passed} Prüfungen bestanden")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil
        shutil.rmtree(TMP, ignore_errors=True)
    sys.stdout.flush()
    os._exit(0)
