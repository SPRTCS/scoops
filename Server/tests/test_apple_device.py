"""Test Apple-Dienste Phase 2 (Server 1.18): Home, Wecker und Standort über ein gemocktes iPhone.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, Edition standard) – niemals
die Produktion. Ein Fake-iPhone verbindet sich über `/api/ws`, meldet sich mit `device.hello` (Fähigkeiten,
Freigaben) an und beantwortet `device.cmd` aus einem kleinen Speicher. Im „Hintergrund“ antwortet es nicht über den
Socket; dann muss der Server per stiller Push wecken (gemockt), und das Gerät holt den Befehl per HTTP ab.
Kein KI-Aufruf: Werkzeuge werden direkt über `service._tools` aufgerufen.

    cd Server && uv run python tests/test_apple_device.py
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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-appledev-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-appledevtest-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import apple as apple_mod, apple_device, server, sharing  # noqa: E402
from aisbot.bots import RunState, load_config  # noqa: E402
from aisbot.version import VERSION  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
apple_mod._device_checked, apple_mod._device_id = True, None
BASE = f"http://127.0.0.1:{PORT}"
WS = f"ws://127.0.0.1:{PORT}/api/ws"
http = httpx.Client(base_url=BASE, timeout=30)
H = {"Authorization": f"Bearer {server.TOKEN}"}
PUSH = "ab" * 32
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


class FakeIPhone:
    """Spielt AIS Scoops auf dem iPhone: device.hello über /api/ws, beantwortet device.cmd (oder schweigt im Hintergrund)."""

    def __init__(self, device_id: str, name: str = "Armans iPhone", kind: str = "iphone", perms: dict | None = None,
                 caps=("home", "alarms", "location"), push: str | None = PUSH):
        self.device_id, self.name, self.kind, self.caps, self.push = device_id, name, kind, list(caps), push
        self.perms = perms or {"home": "granted", "alarms": "granted", "location": "when_in_use"}
        self.commands: list[dict] = []
        self.welcome: dict | None = None
        self.answer_on_socket = True
        self.closed = threading.Event()
        self.alarms: dict[str, dict] = {}
        self.geofences: dict[str, dict] = {}
        self.lights = {"acc_licht": {"on": False, "brightness": 40}}
        self.locked = True
        self.loop = asyncio.new_event_loop()
        self.ws = None
        threading.Thread(target=self.loop.run_until_complete, args=(self._run(),), daemon=True).start()

    def hello(self, active: bool = True) -> dict:
        return {"type": "device.hello", "device_id": self.device_id, "name": self.name, "kind": self.kind,
                "model": "iPhone18,1", "os": "iOS 27.2", "app_version": "1.1 (40)", "capabilities": self.caps,
                "permissions": self.perms, "push_token": self.push, "active": active}

    async def _run(self) -> None:
        try:
            async with connect(WS, additional_headers=H) as ws:
                self.ws = ws
                await ws.send(json.dumps(self.hello()))
                async for raw in ws:
                    m = json.loads(raw)
                    t = m.get("type")
                    if t == "device.welcome":
                        self.welcome = m["data"]
                    elif t == "device.cmd":
                        self.commands.append(m["data"])
                        if self.answer_on_socket:
                            await ws.send(json.dumps({"type": "device.result", "id": m["data"]["id"],
                                                      "result": self.answer(m["data"])}))
        finally:
            self.closed.set()

    def answer(self, c: dict) -> dict:
        cmd, p = c["command"], c.get("params") or {}
        if cmd == "apple.home.overview":
            return {"success": True, "homes": [{"id": "h1", "name": "Zuhause", "primary": True,
                                                "rooms": [{"id": "r1", "name": "Wohnzimmer"}],
                                                "accessories": [
                                                    {"id": "acc_licht", "name": "Stehlampe", "room": "Wohnzimmer",
                                                     "services": [{"id": "s1", "type": "lightbulb", **self.lights["acc_licht"]}]},
                                                    {"id": "acc_schloss", "name": "Haustür", "room": "Flur", "sensitive": True,
                                                     "services": [{"id": "s2", "type": "lock", "locked": self.locked}]}],
                                                "scenes": [{"id": "sc_abend", "name": "Abend", "sensitive": False},
                                                           {"id": "sc_weg", "name": "Ich gehe", "sensitive": True}]}]}
        if cmd == "apple.home.get":
            if p["id"] == "acc_licht":
                return {"success": True, "accessory": {"id": "acc_licht", "name": "Stehlampe", "room": "Wohnzimmer",
                                                       "services": [{"type": "lightbulb", **self.lights["acc_licht"]}]}}
            if p["id"] == "acc_schloss":
                return {"success": True, "accessory": {"id": "acc_schloss", "name": "Haustür", "room": "Flur",
                                                       "sensitive": True, "services": [{"type": "lock"}]}}
            return {"success": False, "error": "Gerät nicht gefunden"}
        if cmd == "apple.home.set":
            if p["id"] == "acc_schloss":
                if not p.get("confirmed"):
                    return {"success": False, "error": "Braucht Freigabe"}
                self.locked = p.get("lock") == "secured"
                return {"success": True, "accessory": {"id": "acc_schloss", "locked": self.locked}}
            self.lights["acc_licht"].update({k: v for k, v in (("on", p.get("on")), ("brightness", p.get("brightness")))
                                             if v is not None})
            return {"success": True, "accessory": {"id": p["id"], **self.lights["acc_licht"]}}
        if cmd == "apple.home.scene":
            return {"success": True, "scene": {"id": p["id"], "executed": True}}
        if cmd == "apple.alarms.add":
            aid = f"A{len(self.alarms) + 1}"
            self.alarms[aid] = {"id": aid, **p, "kind": "alarm"}
            return {"success": True, "alarm": self.alarms[aid]}
        if cmd == "apple.alarms.timer":
            aid = f"T{len(self.alarms) + 1}"
            self.alarms[aid] = {"id": aid, **p, "kind": "timer"}
            return {"success": True, "alarm": self.alarms[aid]}
        if cmd == "apple.alarms.list":
            return {"success": True, "alarms": list(self.alarms.values())}
        if cmd == "apple.alarms.delete":
            return {"success": True, "deleted": self.alarms.pop(p["id"])} if p["id"] in self.alarms else \
                {"success": False, "error": "Wecker nicht gefunden"}
        if cmd == "apple.location.current":
            return {"success": True, "latitude": 52.52, "longitude": 13.405, "accuracy_m": 12,
                    "address": "Teststraße 1, 10115 Berlin"}
        if cmd == "apple.location.geofence_add":
            self.geofences[p["id"]] = {"id": p["id"], "name": p["name"], "radius": p["radius"]}
            return {"success": True, "geofence": self.geofences[p["id"]]}
        if cmd == "apple.location.geofences":
            return {"success": True, "geofences": [dict(g) for g in self.geofences.values()]}
        if cmd == "apple.location.geofence_delete":
            return {"success": True, "deleted": self.geofences.pop(p["id"], None)}
        return {"success": False, "error": f"Unbekannter Befehl {cmd}"}

    def send(self, data: dict) -> None:
        asyncio.run_coroutine_threadsafe(self.ws.send(json.dumps(data)), self.loop).result(5)

    def close(self) -> None:
        if self.ws and not self.closed.is_set():
            asyncio.run_coroutine_threadsafe(self.ws.close(), self.loop)
        self.closed.wait(10)


def tools_of(bot_id: str, **kw) -> dict:
    return {t.schema["name"]: t for t in server.service._tools(bot_id, bot_id, 0, RunState(), **kw)}


def last_approval(bid: str):
    return server.db.one("SELECT * FROM approvals WHERE bot_id=? ORDER BY rowid DESC LIMIT 1", (bid,))


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    enqueued: list[tuple] = []
    server.service.enqueue = lambda chat_id, actor_id, depth=0, opts=None: enqueued.append((chat_id, actor_id, opts))
    wakes: list[tuple[str, dict]] = []
    server.pusher.wake = lambda token, data=None: wakes.append((token, data or {})) or True

    print("Grundlagen")
    ok(tuple(map(int, VERSION.split("."))) >= (1, 18, 0), "Version ab 1.18.0")
    st = http.get("/api/apple", headers=H).json()
    ok([s["id"] for s in st["services"]] == ["reminders", "calendar", "contacts"], "Mac-Dienste unverändert (alte Apps)")
    ok([s["id"] for s in st["device_services"]] == ["home", "alarms", "location"], "neue Liste device_services")
    ok(st["device"] is None and all(s["status"] == "no_device" for s in st["device_services"]), "ohne iPhone: no_device")
    bid = http.post("/api/bots", headers=H, json={"name": "Tina"}).json()["id"]
    ok(not set(tools_of(bid)) & apple_device.TOOL_NAMES, "ohne Gerät keine Werkzeuge")
    ok(http.post("/api/apple/device", json={"device_id": "ios-x"}).status_code == 401, "Geräte-Endpunkt nur mit Token")
    ok(http.post("/api/apple/device", headers=H, json={"device_id": "?"}).status_code == 400, "ungültige Geräte-ID → 400")

    print("Mac meldet keine Fähigkeiten")
    r = http.post("/api/apple/device", headers=H, json={"device_id": "mac-test-123", "kind": "mac", "name": "MacBook",
                                                         "capabilities": ["home", "alarms", "location"]})
    ok(r.status_code == 200 and r.json()["device"]["capabilities"] == [], "Mac: Fähigkeiten verworfen")
    ok(http.get("/api/apple", headers=H).json()["device"] is None, "Mac ist kein Apple-Gerät")

    print("iPhone meldet sich über /api/ws an")
    phone = FakeIPhone("ios-iphone-0001")
    wait_for(lambda: phone.welcome is not None, msg="device.welcome")
    st = http.get("/api/apple", headers=H).json()
    ok(st["device"]["id"] == "ios-iphone-0001" and st["device"]["online"] and st["device"]["source"] == "auto",
       "iPhone gewählt, online")
    svc = {s["id"]: s for s in st["device_services"]}
    ok(svc["home"]["status"] == "off" and svc["home"]["permission"] == "granted", "Home freigegeben, aber aus")
    ok(svc["location"]["status"] == "off" and svc["location"]["background"] is False, "Standort „Beim Verwenden“")
    ok(not set(tools_of(bid)) & apple_device.TOOL_NAMES, "ausgeschaltet → keine Werkzeuge")

    print("Einschalten (PATCH /api/apple)")
    ok(http.patch("/api/apple", headers=H, json={"home": "ja"}).status_code == 400, "kein bool → 400")
    ok(http.patch("/api/apple", headers=H, json={"device": "ios-gibtsnicht"}).status_code == 404, "unbekanntes Gerät → 404")
    ok(http.patch("/api/apple", headers=H, json={"device": "mac-test-123"}).status_code == 404, "Mac nicht wählbar")
    st = http.patch("/api/apple", headers=H, json={"home": True, "alarms": True, "location": True}).json()
    ok(all(s["available"] for s in st["device_services"]), "alle drei bereit")
    ok(load_config()["apple_services"] == {"reminders": False, "calendar": False, "contacts": False, "home": True,
                                           "alarms": True, "location": True}, "config apple_services mit allen sechs")
    st = http.patch("/api/apple", headers=H, json={"reminders": True}).json()
    ok(load_config()["apple_services"]["home"] is True, "PATCH eines Mac-Dienstes lässt iPhone-Dienste stehen")
    names = set(tools_of(bid))
    ok(apple_device.TOOL_NAMES <= names, "apple_home, apple_wecker, apple_standort da")
    hint = apple_mod.prompt_hint(server.apple.active_services(), "Lena")
    ok(hint and "apple_home" in hint and "apple_standort" in hint and "25 s" in hint, "Prompt-Hinweis")

    print("Home")
    home = tools_of(bid)["apple_home"].handler
    out = home({"aktion": "uebersicht", "raum": "Wohnzimmer"})
    ok(phone.commands[-1]["command"] == "apple.home.overview" and phone.commands[-1]["params"] == {"room": "Wohnzimmer"}
       and "Stehlampe" in out, "uebersicht → apple.home.overview")
    out = home({"aktion": "schalten", "id": "acc_licht", "an": True, "helligkeit": 140})
    ok([c["command"] for c in phone.commands[-2:]] == ["apple.home.get", "apple.home.set"], "Licht: lesen, dann schalten")
    ok(phone.commands[-1]["params"] == {"id": "acc_licht", "on": True, "brightness": 100} and phone.lights["acc_licht"]["on"],
       "Licht direkt an (Helligkeit begrenzt)")
    ok("nichts zu schalten" in home({"aktion": "schalten", "id": "acc_licht"}), "schalten ohne Wert → Fehler")
    n = len(phone.commands)
    out = home({"aktion": "schalten", "id": "acc_schloss", "verriegeln": False})
    ok("Freigabe angefragt" in out and phone.locked, "Schloss: Freigabe, noch verriegelt")
    ok([c["command"] for c in phone.commands[n:]] == ["apple.home.get"], "vor der Freigabe nur gelesen")
    appr = last_approval(bid)
    meta = json.loads(server.db.one("SELECT meta FROM messages WHERE id=?", (appr["message_id"],))["meta"])
    ok(meta["kind"] == "apple" and meta["icon"] == "house.fill" and "Haustür" in meta["title"]
       and "entriegeln" in meta["title"], "Freigabe-Karte „Haustür (Flur): entriegeln“")
    ok(http.post(f"/api/approvals/{appr['id']}", headers=H, json={"decision": "approve"}).status_code == 200, "freigeben")
    wait_for(lambda: not phone.locked, msg="entriegelt nach Freigabe")
    ok(phone.commands[-1]["params"].get("confirmed") is True, "freigegebener Befehl trägt confirmed")
    wait_for(lambda: any(e[1] == bid for e in enqueued), msg="Scoop fortgesetzt")
    last_event = lambda: server.db.one("SELECT * FROM messages WHERE bot_id=? AND role='event' ORDER BY seq DESC LIMIT 1", (bid,))
    ok(wait_for(lambda: "Haustür" in (last_event() or {"text": ""})["text"], msg="Ereignis"), "Ereignis nach dem Schalten")
    out = home({"aktion": "szene", "id": "Abend"})
    ok(phone.commands[-1]["command"] == "apple.home.scene" and phone.commands[-1]["params"] == {"id": "sc_abend"},
       "harmlose Szene per Name direkt")
    out = home({"aktion": "szene", "id": "sc_weg"})
    ok("Freigabe angefragt" in out and phone.commands[-1]["command"] == "apple.home.overview", "Szene mit Schloss → Freigabe")
    http.post(f"/api/approvals/{last_approval(bid)['id']}", headers=H, json={"decision": "decline"})
    time.sleep(0.3)
    ok(phone.commands[-1]["command"] == "apple.home.overview", "abgelehnt → nicht ausgeführt")

    print("Wecker")
    alarm = tools_of(bid)["apple_wecker"].handler
    alarm({"aktion": "stellen", "uhrzeit": "6:45", "titel": "Laufen", "wiederholen": "werktags"})
    ok(phone.commands[-1]["command"] == "apple.alarms.add" and phone.commands[-1]["params"] == {
        "title": "Laufen", "time": "06:45", "weekdays": ["monday", "tuesday", "wednesday", "thursday", "friday"]},
       "stellen 6:45 werktags")
    alarm({"aktion": "stellen", "uhrzeit": "07:00", "wiederholen": "mo, mi, Fr"})
    ok(phone.commands[-1]["params"]["weekdays"] == ["monday", "wednesday", "friday"], "Wochentage aus Kürzeln")
    ok("Fehler" in alarm({"aktion": "stellen", "uhrzeit": "25:00"}), "ungültige Uhrzeit → Fehler")
    ok("Fehler" in alarm({"aktion": "stellen", "uhrzeit": "7:00", "wiederholen": "manchmal"}), "ungültiges Wiederholen")
    alarm({"aktion": "timer", "minuten": 10, "titel": "Nudeln"})
    ok(phone.commands[-1]["params"] == {"seconds": 600, "title": "Nudeln"}, "timer 10 min → 600 s")
    ok("Fehler" in alarm({"aktion": "timer", "minuten": 0}), "timer ohne Dauer → Fehler")
    ok('"Nudeln"' in alarm({"aktion": "anzeigen"}), "anzeigen")
    alarm({"aktion": "loeschen", "id": "T3"})
    ok("T3" not in phone.alarms, "löschen ohne Freigabe (eigene Wecker)")

    print("Standort")
    loc = tools_of(bid)["apple_standort"].handler
    out = loc({"aktion": "wo"})
    ok(phone.commands[-1]["command"] == "apple.location.current" and "Berlin" in out, "wo → Koordinaten und Adresse")
    out = loc({"aktion": "ort_anlegen", "name": "Büro", "adresse": "Hauptstraße 1, Berlin"})
    ok("Immer" in out and phone.commands[-1]["command"] == "apple.location.current", "Ort ohne „Immer“ → klarer Fehler")
    phone.perms["location"] = "always"
    phone.send(phone.hello())
    wait_for(lambda: http.get("/api/apple", headers=H).json()["device_services"][2]["background"], msg="always gemeldet")
    out = loc({"aktion": "ort_anlegen", "name": "Büro", "adresse": "Hauptstraße 1, Berlin", "bei": "betreten",
               "notiz": "An die Post erinnern", "radius_m": 50})
    gcmd = phone.commands[-1]
    ok(gcmd["command"] == "apple.location.geofence_add" and gcmd["params"]["radius"] == 100
       and gcmd["params"]["on_entry"] and not gcmd["params"]["on_exit"], "ort_anlegen → geofence_add (Radius ≥ 100)")
    gid = gcmd["params"]["id"]
    row = server.db.one("SELECT * FROM apple_geofences WHERE id=?", (gid,))
    ok(row and row["chat_id"] == bid and row["note"] == "An die Post erinnern", "Server merkt Chat, Scoop und Notiz")
    ok("latitude" not in row.keys(), "keine Koordinaten auf dem Server")
    ok("An die Post" in loc({"aktion": "orte"}), "orte mit Notiz")
    enqueued.clear()
    r = http.post("/api/apple/device/event", headers=H, json={"device_id": phone.device_id, "type": "geofence", "id": gid,
                                                              "event": "enter", "at": "2026-11-14T09:12:00+01:00"})
    ok(r.json().get("handled") is True, "Betreten gemeldet")
    ev = server.db.one("SELECT * FROM messages WHERE bot_id=? AND role='event' ORDER BY seq DESC LIMIT 1", (bid,))
    meta = json.loads(ev["meta"])
    ok(ev["text"] == "Büro betreten" and "Post" in meta["prompt"] and "09:12" in meta["prompt"], "Nachricht im Chat")
    ok(enqueued and enqueued[-1][:2] == (bid, bid), "Scoop reagiert")
    r = http.post("/api/apple/device/event", headers=H, json={"device_id": phone.device_id, "type": "geofence", "id": gid,
                                                              "event": "enter"})
    ok(r.json().get("duplicate"), "doppelte Meldung ignoriert")
    r = http.post("/api/apple/device/event", headers=H, json={"device_id": phone.device_id, "type": "geofence", "id": gid,
                                                              "event": "exit"})
    ok(r.json().get("handled") is False, "Verlassen nicht gewünscht → kein Lauf")
    ok(http.post("/api/apple/device/event", headers=H, json={"device_id": "ios-fremd-999", "type": "geofence",
                                                             "id": gid}).status_code == 404, "fremdes Gerät → 404")
    loc({"aktion": "ort_loeschen", "id": gid})
    ok(gid not in phone.geofences and not server.db.one("SELECT 1 FROM apple_geofences WHERE id=?", (gid,)), "Ort gelöscht")

    print("Hintergrund: stille Push und Abholen per HTTP")
    phone.answer_on_socket = False
    phone.send({"type": "device.state", "active": False})
    time.sleep(0.2)
    wakes.clear()

    def on_wake(token, data=None):
        wakes.append((token, data or {}))

        def fetch():
            time.sleep(0.3)
            cmds = http.post("/api/apple/device/poll", headers=H, json={"device_id": phone.device_id}).json()["commands"]
            for c in cmds:
                http.post("/api/apple/device/result", headers=H,
                          json={"device_id": phone.device_id, "id": c["id"], "result": phone.answer(c)})
        threading.Thread(target=fetch, daemon=True).start()
        return True

    server.pusher.wake = on_wake
    t0 = time.time()
    out = alarm({"aktion": "anzeigen"})
    ok('"alarms"' in out and time.time() - t0 < 3, "Befehl über Push + HTTP erledigt")
    ok(wakes and wakes[0][0] == PUSH and wakes[0][1]["apple_cmd"].startswith("dc_"), "stille Push mit Befehls-ID")

    print("Zeitlimit")
    server.pusher.wake = lambda token, data=None: True  # Push geht raus, App wacht aber nicht auf
    apple_device.WAIT_S = 1.5
    t0 = time.time()
    out = alarm({"aktion": "anzeigen"})
    ok(out.startswith("Fehler:") and "nicht erreichbar" in out and "öffne AIS Scoops" in out, "„iPhone nicht erreichbar“")
    ok(time.time() - t0 < 4, "wartet nur bis zum Zeitlimit")
    ok(not apple_device.AppleDevices.pending_for(server.apple_devices, phone.device_id), "keine hängenden Befehle")
    apple_device.WAIT_S = 25.0
    phone.answer_on_socket = True
    phone.send({"type": "device.state", "active": True})

    print("Mehrere Geräte")
    time.sleep(1.1)
    http.post("/api/apple/device", headers=H, json={"device_id": "ios-ipad-0002", "kind": "ipad", "name": "iPad",
                                                     "capabilities": ["home", "alarms", "location"],
                                                     "permissions": {"home": "granted"}})
    ok(http.get("/api/apple", headers=H).json()["device"]["id"] == phone.device_id, "iPad aktiver, aber iPhone bevorzugt")
    time.sleep(1.1)
    http.post("/api/apple/device", headers=H, json={"device_id": "ios-iphone-0003", "kind": "iphone", "name": "Zweit-iPhone",
                                                     "capabilities": ["home"], "permissions": {"home": "denied"}})
    st = http.get("/api/apple", headers=H).json()
    ok(st["device"]["id"] == "ios-iphone-0003", "zuletzt aktives iPhone gewählt")
    ok(not set(tools_of(bid)) & apple_device.TOOL_NAMES, "Werkzeuge folgen den Freigaben des gewählten Geräts")
    st = http.patch("/api/apple", headers=H, json={"device": phone.device_id}).json()
    ok(st["device"]["id"] == phone.device_id and st["device"]["source"] == "config" and st["device_choice"] == phone.device_id,
       "ausdrücklich gewählt (config apple_device)")
    ok(len(st["devices"]) == 3, "Geräteliste ohne Mac")
    ok(apple_device.TOOL_NAMES <= set(tools_of(bid)), "Werkzeuge wieder da")

    print("Gäste")
    guest = {"user_id": "u_gast", "name": "Gast", "role": "write"}
    allg = sharing.normalize_tools({"web": True, "computer": True, "mail": True, "phone": True,
                                    "apps": ["gmail"], "mcp": ["atrium"]})
    ok(apple_device.TOOL_NAMES <= sharing.NEVER_FOR_GUESTS, "NEVER_FOR_GUESTS enthält die neuen Werkzeuge")
    ok(not set(tools_of(bid, guest=guest, gtools=allg)) & apple_device.TOOL_NAMES, "Gast-Lauf: nie Home/Wecker/Standort")
    p = sharing.Principal("guest", "u_gast")
    ok(server.guest_event("apple.updated", server.apple.status(), p) is None, "apple.updated nie an Gäste")

    print("Offline, Gerät entfernen")
    phone.close()
    wait_for(lambda: not http.get("/api/apple", headers=H).json()["device"]["online"], msg="offline")
    ok(apple_device.TOOL_NAMES <= set(tools_of(bid)), "offline bleibt wählbar (Push weckt)")
    st = http.delete(f"/api/apple/device/{phone.device_id}", headers=H).json()
    ok(st["device"]["id"] == "ios-iphone-0003" and st["device_choice"] == "auto", "entfernt → Auswahl zurück auf auto")
    ok(http.delete("/api/apple/device/ios-weg-000", headers=H).status_code == 404, "unbekanntes Gerät → 404")

    time.sleep(0.3)
    srv.should_exit = True
    time.sleep(0.5)
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
