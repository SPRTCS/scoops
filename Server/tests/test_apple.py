"""Test der Apple-Dienste (Server 1.17): Erinnerungen, Kalender, Kontakte über einen gemockten Apple-Rechner.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, Edition standard, ohne
MCP/VM-Wächter) – niemals die Produktion. Ein Fake-„AIS Scoops Server“ verbindet sich per WebSocket, meldet seine
Apple-Freigaben im hello und beantwortet die `apple.*`-Befehle aus einem kleinen Speicher. Kein KI-Aufruf: Die
Werkzeuge werden direkt über `service._tools` aufgerufen.

    cd Server && uv run python tests/test_apple.py
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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-apple-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-appletest-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import apple as apple_mod, server, sharing  # noqa: E402
from aisbot.bots import RunState, load_config, save_config  # noqa: E402
from aisbot.version import VERSION  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
LOCAL_DEVICE = "mac-" + "ab" * 12
apple_mod._device_checked, apple_mod._device_id = True, LOCAL_DEVICE  # „dieser Mac“ im Test
BASE = f"http://127.0.0.1:{PORT}"
WS = f"ws://127.0.0.1:{PORT}/api/nodes/link"
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0


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


class FakeAppleNode:
    """Spielt „AIS Scoops Server“ in der Rolle connect: hello mit Apple-Freigaben, beantwortet apple.*-Befehle."""

    def __init__(self, token: str, device: str, apple: dict | None, paused: bool = False):
        self.token, self.device, self.apple, self.paused = token, device, apple, paused
        self.commands: list[dict] = []
        self.welcome: dict | None = None
        self.closed = threading.Event()
        self.reminders: dict[str, dict] = {}
        self.events = {"ev1@1763110800": {"id": "ev1@1763110800", "title": "Zahnarzt", "start": "2026-11-14T10:00:00+01:00",
                                          "end": "2026-11-14T11:00:00+01:00", "all_day": False, "calendar": "Privat",
                                          "location": "Praxis", "recurring": False}}
        self.loop = asyncio.new_event_loop()
        self.ws = None
        threading.Thread(target=self.loop.run_until_complete, args=(self._run(),), daemon=True).start()

    async def _run(self) -> None:
        try:
            async with connect(WS, additional_headers={"Authorization": f"Bearer {self.token}"}) as ws:
                self.ws = ws
                hello = {"type": "hello", "node_id": "?", "name": "Fake-Air", "mode": "direct", "os": "macOS 27.0",
                         "app_version": "2.1 (1)", "screen": {"width": 320, "height": 200}, "paused": self.paused,
                         "device_id": self.device}
                if self.apple is not None:
                    hello["apple"] = self.apple
                await ws.send(json.dumps(hello))
                async for raw in ws:
                    m = json.loads(raw)
                    t = m.get("type")
                    if t == "welcome":
                        self.welcome = m
                    elif t == "ping":
                        await ws.send('{"type":"pong"}')
                    elif t == "cmd":
                        self.commands.append(m)
                        await ws.send(json.dumps({"type": "result", "id": m["id"], "result": self.answer(m)}))
        except Exception as e:  # noqa: BLE001
            self.error = e
        finally:
            self.closed.set()

    def answer(self, m: dict) -> dict:
        c, p = m["command"], m.get("params") or {}
        if c == "apple.reminders.lists":
            return {"success": True, "lists": [{"id": "L1", "title": "Erinnerungen", "default": True}]}
        if c == "apple.reminders.add":
            rid = f"R{len(self.reminders) + 1}"
            self.reminders[rid] = {"id": rid, "title": p["title"], "notes": p.get("notes"), "due": p.get("due"),
                                   "list": p.get("list") or "Erinnerungen", "priority": p.get("priority") or "none",
                                   "completed": False}
            return {"success": True, "reminder": self.reminders[rid]}
        if c == "apple.reminders.list":
            want = p.get("status", "open")
            rs = [r for r in self.reminders.values() if want == "all" or r["completed"] == (want == "completed")]
            return {"success": True, "reminders": rs}
        if c in ("apple.reminders.get", "apple.reminders.update", "apple.reminders.complete", "apple.reminders.delete"):
            r = self.reminders.get(p.get("id"))
            if not r:
                return {"success": False, "error": "Erinnerung nicht gefunden"}
            if c == "apple.reminders.complete":
                r["completed"] = bool(p.get("completed", True))
            if c == "apple.reminders.update":
                r.update({k: v for k, v in (("title", p.get("title")), ("due", p.get("due"))) if v is not None})
            if c == "apple.reminders.delete":
                del self.reminders[p["id"]]
                return {"success": True, "deleted": r}
            return {"success": True, "reminder": r}
        if c == "apple.calendar.calendars":
            return {"success": True, "calendars": [{"id": "C1", "title": "Privat", "writable": True}]}
        if c == "apple.calendar.events":
            return {"success": True, "events": list(self.events.values())}
        if c == "apple.calendar.get":
            ev = self.events.get(p.get("id"))
            return {"success": True, "event": ev} if ev else {"success": False, "error": "Termin nicht gefunden"}
        if c == "apple.calendar.delete":
            return {"success": True, "deleted": self.events.pop(p["id"])}
        if c == "apple.contacts.search":
            return {"success": True, "contacts": [{"id": "K1", "name": "Testperson", "phones": [], "emails": []}]}
        return {"success": False, "error": f"Unbekannter Befehl {c}"}

    def send(self, data: dict) -> None:
        asyncio.run_coroutine_threadsafe(self.ws.send(json.dumps(data)), self.loop).result(5)

    def close(self) -> None:
        if self.ws and not self.closed.is_set():
            asyncio.run_coroutine_threadsafe(self.ws.close(), self.loop)
        self.closed.wait(15)


def pair(device: str) -> tuple[str, str]:
    code = server.computers.create_pairing()["code"]
    r = http.post("/api/nodes/claim", json={"code": code, "name": "Fake-Air", "mode": "direct", "device_id": device})
    assert r.status_code == 200, r.text
    return r.json()["node_id"], r.json()["node_token"]


def tools_of(bot_id: str, **kw) -> dict:
    return {t.schema["name"]: t for t in server.service._tools(bot_id, bot_id, 0, RunState(), **kw)}


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    H = {"Authorization": f"Bearer {server.TOKEN}"}
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    enqueued: list[tuple] = []
    server.service.enqueue = lambda chat_id, actor_id, depth=0, opts=None: enqueued.append((chat_id, actor_id, opts))

    print("Grundlagen")
    ok(VERSION >= "1.17.0", "Version ab 1.17.0")
    ok(http.get("/api/apple").status_code == 401, "GET /api/apple ohne Token → 401")
    st = http.get("/api/apple", headers=H).json()
    ok(st["node_id"] is None and all(s["status"] == "no_node" for s in st["services"]), "ohne Rechner: no_node")
    ok([s["id"] for s in st["services"]] == ["reminders", "calendar", "contacts"], "drei Dienste in fester Reihenfolge")
    bot = http.post("/api/bots", headers=H, json={"name": "Tina"}).json()
    bid = bot["id"]
    ok(not set(tools_of(bid)) & apple_mod.TOOL_NAMES, "ohne Apple-Rechner keine Apple-Werkzeuge")

    print("Apple-Rechner auf demselben Mac")
    other_id, other_tok = pair("mac-anderer")
    nid, ntok = pair(LOCAL_DEVICE)
    node = FakeAppleNode(ntok, LOCAL_DEVICE, {"reminders": "granted", "calendar": "granted", "contacts": "denied"})
    wait_for(lambda: node.welcome is not None, msg="welcome")
    st = http.get("/api/apple", headers=H).json()
    ok(st["node_id"] == nid and st["node_source"] == "local" and st["node_online"], "Rechner mit gleicher Geräte-ID gewählt")
    svc = {s["id"]: s for s in st["services"]}
    ok(svc["reminders"]["permission"] == "granted" and svc["reminders"]["status"] == "off", "Freigabe da, Dienst aus")
    ok(svc["contacts"]["status"] == "needs_permission" and "Mac" in svc["contacts"]["hint"], "Kontakte: Freigabe fehlt")
    n = next(x for x in http.get("/api/nodes", headers=H).json() if x["id"] == nid)
    ok(n["apple"]["reminders"] == "granted" and n["apple"]["contacts"] == "denied", "GET /api/nodes zeigt Freigaben")
    ok(not set(tools_of(bid)) & apple_mod.TOOL_NAMES, "ausgeschaltet → keine Werkzeuge")

    print("Einschalten (PATCH /api/apple)")
    ok(http.patch("/api/apple", headers=H, json={"reminders": "ja"}).status_code == 400, "kein bool → 400")
    ok(http.patch("/api/apple", headers=H, json={"node": "n_gibtsnicht"}).status_code == 404, "unbekannter Rechner → 404")
    ok(http.patch("/api/apple", headers=H, json={"node": "vm"}).status_code == 404, "Bot-Rechner nicht wählbar")
    st = http.patch("/api/apple", headers=H, json={"reminders": True, "calendar": True, "contacts": True}).json()
    svc = {s["id"]: s for s in st["services"]}
    ok(svc["reminders"]["available"] and svc["calendar"]["available"], "Erinnerungen und Kalender bereit")
    ok(svc["contacts"]["enabled"] and not svc["contacts"]["available"], "Kontakte eingeschaltet, aber ohne Freigabe")
    ok({k: v for k, v in load_config()["apple_services"].items() if v} == {"reminders": True, "calendar": True, "contacts": True}, "config apple_services")
    names = set(tools_of(bid))
    ok({"apple_erinnerungen", "apple_kalender"} <= names and "apple_kontakte" not in names,
       "Werkzeuge nur für Dienste mit Freigabe")
    hint = apple_mod.prompt_hint(server.apple.active_services(), "Lena")
    ok(hint and "apple_erinnerungen" in hint and "Composio" in hint and "apple_kontakte" not in hint, "Prompt-Hinweis")

    print("Freigabe ändert sich (state)")
    node.send({"type": "state", "paused": False, "apple": {"reminders": "granted", "calendar": "granted", "contacts": "granted"}})
    wait_for(lambda: "apple_kontakte" in tools_of(bid), msg="Kontakte-Werkzeug nach Freigabe")
    ok(True, "state mit neuer Freigabe → apple_kontakte erscheint")

    print("Erinnerungen")
    t = tools_of(bid)
    rem = t["apple_erinnerungen"].handler
    out = rem({"aktion": "anlegen", "titel": "AIS Scoops Test", "faellig": "2026-11-20T09:00", "prioritaet": "hoch"})
    cmd = node.commands[-1]
    ok(cmd["command"] == "apple.reminders.add" and cmd["params"] == {"title": "AIS Scoops Test", "due": "2026-11-20T09:00",
                                                                      "priority": "high"}, "anlegen → apple.reminders.add")
    ok('"id":"R1"' in out, "Antwort enthält die ID")
    ok('"AIS Scoops Test"' in rem({"aktion": "anzeigen"}), "anzeigen → offene Erinnerungen")
    ok(node.commands[-1]["params"] == {"status": "open", "limit": 50}, "Standardfilter offen, 50")
    rem({"aktion": "erledigen", "id": "R1"})
    ok(node.commands[-1]["command"] == "apple.reminders.complete" and node.reminders["R1"]["completed"], "erledigen")
    ok("Fehler: id fehlt" in rem({"aktion": "aendern"}), "aendern ohne id → Fehler")
    n_before = len(node.commands)
    out = rem({"aktion": "loeschen", "id": "R1"})
    ok("Freigabe angefragt" in out and "R1" in node.reminders, "loeschen → Freigabe, noch nicht gelöscht")
    ok([c["command"] for c in node.commands[n_before:]] == ["apple.reminders.get"], "vorher nur gelesen (Titel für die Karte)")
    appr = server.db.one("SELECT * FROM approvals WHERE bot_id=? ORDER BY rowid DESC LIMIT 1", (bid,))
    msg = server.db.one("SELECT * FROM messages WHERE id=?", (appr["message_id"],))
    meta = json.loads(msg["meta"])
    ok(meta["kind"] == "apple" and "AIS Scoops Test" in meta["title"] and msg["role"] == "approval", "Freigabe-Karte mit Titel")
    ok(http.post(f"/api/approvals/{appr['id']}", headers=H, json={"decision": "approve"}).status_code == 200, "freigeben")
    wait_for(lambda: "R1" not in node.reminders, msg="gelöscht nach Freigabe")
    ok(node.commands[-1]["command"] == "apple.reminders.delete", "nach Freigabe → apple.reminders.delete")
    wait_for(lambda: any(e[1] == bid for e in enqueued), msg="Scoop fortgesetzt")
    ev = server.db.one("SELECT * FROM messages WHERE bot_id=? AND role='event' ORDER BY seq DESC LIMIT 1", (bid,))
    ok("gelöscht" in ev["text"], "Ereignis „Erinnerung gelöscht“")

    print("Kalender, Kontakte")
    cal = tools_of(bid)["apple_kalender"].handler
    out = cal({"aktion": "termine", "von": "2026-11-14", "bis": "2026-11-15"})
    ok(node.commands[-1]["params"] == {"from": "2026-11-14", "to": "2026-11-15", "limit": 100} and "Zahnarzt" in out,
       "termine → apple.calendar.events")
    ok("titel und beginn" in cal({"aktion": "anlegen", "titel": "X"}), "anlegen ohne beginn → Fehler")
    out = cal({"aktion": "loeschen", "id": "ev1@1763110800"})
    ok("Freigabe angefragt" in out and "ev1@1763110800" in node.events, "Termin löschen → Freigabe")
    appr = server.db.one("SELECT * FROM approvals WHERE bot_id=? ORDER BY rowid DESC LIMIT 1", (bid,))
    ok("14.11.2026, 10:00" in appr["title"], "Karte mit Datum")
    http.post(f"/api/approvals/{appr['id']}", headers=H, json={"decision": "decline"})
    time.sleep(0.3)
    ok("ev1@1763110800" in node.events, "abgelehnt → bleibt")
    kon = tools_of(bid)["apple_kontakte"].handler
    ok("Testperson" in kon({"aktion": "suchen", "suche": "Test"}), "Kontakte suchen")
    kon({"aktion": "geburtstage", "tage": 14})
    ok(node.commands[-1]["params"] == {"birthdays_days": 14, "limit": 20}, "Geburtstage")

    print("Pause betrifft nur die Steuerung")
    node.send({"type": "state", "paused": True})
    wait_for(lambda: server.computers.get(nid).transport.paused, msg="pausiert")
    ok('"lists"' in tools_of(bid)["apple_erinnerungen"].handler({"aktion": "listen"}), "Apple-Befehl trotz Pause")
    node.send({"type": "state", "paused": False})

    print("Gäste")
    guest = {"user_id": "u_gast", "name": "Gast", "role": "write"}
    allg = sharing.normalize_tools({"web": True, "computer": True, "mail": True, "phone": True, "apple": True,
                                    "apps": ["gmail"], "mcp": ["atrium"]})
    ok("apple" not in allg, "Werkzeug-Schalter kennt keinen Apple-Schlüssel")
    ok(not set(tools_of(bid, guest=guest, gtools=allg)) & apple_mod.TOOL_NAMES, "Gast-Lauf: nie Apple-Werkzeuge")
    ok(not sharing.guest_tool_names(allg) & apple_mod.TOOL_NAMES, "guest_tool_names ohne Apple")
    opts = http.get(f"/api/bots/{bid}/sharing", headers=H).json()["options"]
    ok("apple" not in json.dumps(opts).lower(), "Allowlist-Katalog für Gäste ohne Apple")
    p = sharing.Principal("guest", "u_gast")
    server.db.q("UPDATE bots SET computer_node=? WHERE id=?", (nid, bid))
    server.shares.shares = [sharing.Share("s_1", bid, "u_gast", "Gast", "write", "view")]
    ok(server.guest_event("apple.updated", server.apple.status(), p) is None, "apple.updated nie an Gäste")
    ev = server.guest_event("node.updated", {"id": nid, "name": "Fake-Air", "apple": {"reminders": "granted"}}, p)
    ok(ev is not None and "apple" not in ev[1], "node.updated für Gäste ohne Apple-Freigaben")
    server.shares.shares = []

    print("Auswahl des Apple-Rechners")
    other = FakeAppleNode(other_tok, "mac-anderer", {"reminders": "denied", "calendar": "granted", "contacts": "granted"})
    wait_for(lambda: other.welcome is not None, msg="zweiter Rechner")
    st = http.patch("/api/apple", headers=H, json={"node": other_id}).json()
    ok(st["node_id"] == other_id and st["node_source"] == "config" and st["node_choice"] == other_id, "ausdrücklich gewählt")
    ok(len(st["nodes"]) == 2, "beide Rechner zur Auswahl")
    names = set(tools_of(bid))
    ok("apple_erinnerungen" not in names and "apple_kalender" in names, "Werkzeuge folgen den Freigaben des gewählten Macs")
    st = http.patch("/api/apple", headers=H, json={"node": ""}).json()
    ok(st["node_id"] == nid and st["node_choice"] == "auto", "zurück auf automatisch (dieser Mac)")
    apple_mod._device_id = None
    cfgd = load_config()
    cfgd["default_computer_node"] = other_id
    save_config(cfgd)
    ok(http.get("/api/apple", headers=H).json()["node_source"] == "default", "ohne lokalen Mac → default_computer_node")
    apple_mod._device_id = LOCAL_DEVICE

    print("Offline und alte App")
    node.close()
    wait_for(lambda: not server.computers.get(nid).transport.online, msg="getrennt")
    st = http.get("/api/apple", headers=H).json()
    ok(not st["node_online"] and all(s["status"] == "offline" for s in st["services"]), "offline")
    ok(not set(tools_of(bid)) & apple_mod.TOOL_NAMES, "offline → keine Werkzeuge")
    out = rem({"aktion": "listen"})  # Werkzeug aus einem laufenden Lauf, Rechner fällt dazwischen aus
    ok(out.startswith("Fehler:") and "offline" in out and "Bescheid" in out, "klare Fehlermeldung an den Scoop")
    old = FakeAppleNode(ntok, LOCAL_DEVICE, None)
    wait_for(lambda: old.welcome is not None, msg="alte App")
    st = http.get("/api/apple", headers=H).json()
    ok(all(s["status"] == "needs_update" for s in st["services"]), "alte App ohne Apple-Meldung → needs_update")
    old.close()
    other.close()

    time.sleep(0.5)  # letzte Ereignisse (Trennen) abarbeiten lassen, bevor der Server stoppt
    srv.should_exit = True
    wait_for(lambda: not srv.started or srv.should_exit, 5, "Server stoppt")
    time.sleep(0.5)
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
