"""Test für Push über das Relay (AIS Scoops Cloud) und die Badge-Zahl (Server 1.13).

Eigene Testinstanz im Prozess, Edition „standard“, ohne eigenen APNs-Schlüssel (eigener Schlüsselbund-Präfix,
eigener Kopplungs-Eintrag), eigener Port – niemals die laufende Produktion auf 8787 und nie Armans Schlüssel.

Teil 1 spielt das Relay mit einem kleinen Fake-Server (prüft, was der Server schickt). Teil 2 läuft gegen das
Convex-**Dev**-Deployment aus Cloud/.env.local mit echtem APNs, aber nur mit einem erfundenen Token
(erwartet: sauber `BadDeviceToken`); überspringen mit AISBOT_SKIP_CONVEX=1.

    cd Server && uv run python tests/test_push.py
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-push-test-"))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, FAKE_PORT = free_port(), free_port()
FAKE = f"http://127.0.0.1:{FAKE_PORT}"
PREFIX = "ais-scoops-pushtest-" + os.urandom(3).hex()
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX=PREFIX, AISBOT_CLOUD_KEYCHAIN=PREFIX + "-cloud",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import cloud as cloud_mod, profile, push as push_mod, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert cloud_mod.KEYCHAIN_SERVICE.startswith(PREFIX), "Test darf nie den echten Kopplungs-Eintrag benutzen"
assert profile.kc("apns").startswith(PREFIX), "Test darf nie Armans APNs-Schlüssel lesen"
push_mod.BADGE_DEBOUNCE_S = 0.3
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
pusher = server.pusher
passed = 0
TOK_IPHONE = "1" * 64
TOK_MAC = "2" * 64
TOK_WIDGET = "3" * 64
TOK_START = "4" * 64
TOK_GONE = "5" * 64
TOK_LIVE = "6" * 160


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=10.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


# -- Fake-Relay ------------------------------------------------------------------------------
class Fake:
    configured = True
    registered: dict[str, str] = {}
    register_calls: list[list[dict]] = []
    sends: list[dict] = []
    channels: list[tuple[str, str]] = []
    broadcasts: list[dict] = []
    auth: list[str] = []
    lock = threading.Lock()


class FakeHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        with Fake.lock:
            Fake.auth.append(self.headers.get("authorization") or "")
        if self.headers.get("authorization") != "Bearer relay-secret":
            return self._send(401, {"error": "?", "code": "unknown_server"})
        if self.path == "/servers/heartbeat":
            return self._send(200, {"ok": True, "serverId": "srv", "ownerId": "user_x", "revokedSessions": []})
        if self.path == "/push/status":
            return self._send(200, {"ok": True, "configured": Fake.configured})
        if self.path == "/push/register":
            with Fake.lock:
                Fake.register_calls.append(body["tokens"])
                for t in body["tokens"]:
                    Fake.registered[t["token"]] = t["platform"]
            return self._send(200, {"ok": True, "registered": len(body["tokens"]), "rejected": []})
        if self.path == "/push/send":
            if not Fake.configured:
                return self._send(503, {"error": "?", "code": "relay_not_configured"})
            results = []
            with Fake.lock:
                for p in body["pushes"]:
                    Fake.sends.append(p)
                    if p["token"] not in Fake.registered:
                        results.append({"token": p["token"], "status": 403, "reason": "UnknownToken"})
                    elif p["token"] == TOK_GONE:
                        results.append({"token": p["token"], "status": 410, "reason": "Unregistered"})
                    else:
                        results.append({"token": p["token"], "status": 200, "env": "production"})
            return self._send(200, {"ok": True, "results": results})
        if self.path == "/push/channel":
            with Fake.lock:
                Fake.channels.append((body["action"], body.get("channelId", "")))
            if body["action"] == "create":
                return self._send(200, {"ok": True, "channelId": "Q0hBTk5FTC0x"})
            return self._send(200, {"ok": True})
        if self.path == "/push/broadcast":
            with Fake.lock:
                Fake.broadcasts.append(body)
            return self._send(200, {"ok": True})
        self._send(404, {"error": "?"})


def sends_of(push_type: str) -> list[dict]:
    with Fake.lock:
        return [s for s in Fake.sends if s["pushType"] == push_type]


def api(method: str, path: str, **kw) -> httpx.Response:
    tok = load_config()["api_token"]
    return http.request(method, path, headers={"Authorization": f"Bearer {tok}"}, **kw)


def link(url: str, secret: str, owner: str = "user_x") -> None:
    cfg = load_config()
    cfg.update(cloud_url=url, owner_id=owner, cloud_server_id="srv")
    save_config(cfg)
    cloud_mod.set_secret(secret)
    pusher.reset_mode()


def part_badge() -> None:
    print("Badge-Zahl (unread_chat_count)")
    db = server.db
    pip = db.bots()[0]["id"]
    ok(db.unread_chat_count() == 1, "frische Installation: Pip hat eine ungelesene Begrüßung → 1")
    gid = server.service.create_group("Team", [pip])["id"]
    db.add_message(gid, "bot", "Hallo Gruppe")
    db.add_message(gid, "bot", "Noch etwas")
    ok(db.unread_chat_count() == 2, "Gruppe mit 2 ungelesenen zählt als 1 Chat → 2")
    db.add_message(pip, "approval", "Freigabe?")
    ok(db.unread_chat_count() == 2, "weitere Nachricht im selben Chat ändert nichts")
    api("POST", f"/api/groups/{gid}/read")
    ok(db.unread_chat_count() == 1, "Gruppe gelesen → 1")
    ok(not pusher.enabled and pusher.mode() is None, "ohne Schlüssel und ohne Kopplung: keine Mitteilungen")
    st = http.get("/api/setup").json()
    ok(st["push"] == {"enabled": False, "mode": None, "error": None}, "/api/setup: push aus")
    server.service.delete_group(gid)


def part_fake() -> None:
    print("Relay-Modus (Fake-Relay)")
    link(FAKE, "relay-secret")
    ok(pusher.mode() == "relay" and pusher.enabled, "gekoppelt, ohne eigenen Schlüssel → Relay")
    wait_for(lambda: pusher.relay._configured is True, msg="/push/status abgefragt")
    st = http.get("/api/setup").json()
    ok(st["push"]["enabled"] and st["push"]["mode"] == "relay", "/api/setup zeigt Push über das Relay")
    ok(api("GET", "/api/health").json()["push_mode"] == "relay", "/api/health: push_mode relay")
    for tok, plat in ((TOK_IPHONE, "ios"), (TOK_MAC, "macos"), (TOK_WIDGET, "ios-widgets"),
                      (TOK_START, "ios-scoops-live-start")):
        r = api("POST", "/api/devices", json={"apns_token": tok, "platform": plat, "name": "Test"})
        ok(r.status_code == 200 and r.json()["push_enabled"] is True, f"/api/devices {plat}")
    wait_for(lambda: len(Fake.registered) >= 4, msg="Tokens bei der Cloud gemeldet")
    ok(Fake.registered == {TOK_IPHONE: "ios", TOK_MAC: "macos", TOK_WIDGET: "ios-widgets",
                           TOK_START: "ios-scoops-live-start"}, "Tokens mit Plattform gemeldet")
    ok(set(Fake.auth) == {"Bearer relay-secret"}, "Relay-Aufrufe mit serverSecret")

    print("Mitteilung mit Badge")
    pip = server.db.bots()[0]["id"]
    t0 = time.time()
    server.service._add(pip, "bot", "Bin fertig mit der Recherche.")
    ok(time.time() - t0 < 0.5, "Mitteilung blockiert den Lauf nicht")
    alerts = wait_for(lambda: len(sends_of("alert")) >= 2 and sends_of("alert"), msg="Mitteilung über das Relay")
    ok({a["token"] for a in alerts} == {TOK_IPHONE, TOK_MAC}, "nur an App-Geräte (nicht Widget/Live-Start)")
    a = alerts[0]
    ok(a["payload"]["aps"]["alert"]["body"] == "Bin fertig mit der Recherche." and a["priority"] == "10"
       and a["topic"] == "com.ais.aisbot", "Titel/Text, Priorität 10, Topic")
    ok(a["payload"]["aps"]["badge"] == server.db.unread_chat_count() == 1, "aps.badge = Anzahl Chats mit Ungelesenem (1)")
    gid = server.service.create_group("Projekt", [pip])["id"]
    n = len(sends_of("alert"))
    server.service._add(gid, "bot", "Neues in der Gruppe")
    wait_for(lambda: len(sends_of("alert")) >= n + 2, msg="zweite Mitteilung")
    ok(sends_of("alert")[-1]["payload"]["aps"]["badge"] == 2, "zweiter Chat ungelesen → badge 2")
    ok("category" not in sends_of("alert")[-1]["payload"]["aps"], "normale Mitteilung ohne Kategorie")

    print("Freigabe-Mitteilung mit Knöpfen (Kategorie, approval_id)")
    for meta, cat in (({"approval_id": "a_p1", "title": "Mail senden", "state": "pending", "kind": "mail"}, "SCOOP_APPROVAL"),
                      ({"approval_id": "a_p2", "title": "Checkouts", "state": "pending", "can_always": True},
                       "SCOOP_APPROVAL_ALWAYS"),
                      ({"approval_id": "a_p3", "title": "Login", "state": "pending", "kind": "vault"}, None)):
        n = len(sends_of("alert"))
        server.service._add(pip, "approval", "", meta)
        wait_for(lambda: len(sends_of("alert")) >= n + 2, msg="Freigabe-Mitteilung")
        p = sends_of("alert")[-1]["payload"]
        ok(p["aps"].get("category") == cat and p["approval_id"] == meta["approval_id"]
           and p["approval_kind"] == meta.get("kind") and p["aps"]["alert"]["body"].startswith("Bittet um Freigabe"),
           f"Freigabe {meta.get('kind') or 'allgemein'} → Kategorie {cat}")

    print("Stiller Badge-Push beim Lesen (entprellt, nur bei Änderung)")
    n = len(sends_of("alert"))
    api("POST", f"/api/bots/{pip}/read")
    api("POST", f"/api/bots/{pip}/read")
    badge = wait_for(lambda: len(sends_of("alert")) >= n + 2 and sends_of("alert")[n:], msg="Badge-Push")
    time.sleep(0.6)
    ok(len(sends_of("alert")) == n + 2, "zwei schnelle Lesevorgänge → ein Badge-Push je Gerät")
    ok(all(b["payload"] == {"aps": {"badge": 1}} and b["priority"] == "5" for b in badge), "Payload {aps: {badge: 1}}, Priorität 5")
    api("POST", f"/api/bots/{pip}/read")
    time.sleep(0.8)
    ok(len(sends_of("alert")) == n + 2, "unveränderte Zahl → kein weiterer Push")
    server.db.q("UPDATE groups SET unread=0 WHERE id=?", (gid,))
    server.pusher.badge_changed()
    wait_for(lambda: len(sends_of("alert")) >= n + 4, msg="Badge 0")
    ok(sends_of("alert")[-1]["payload"] == {"aps": {"badge": 0}}, "alles gelesen → badge 0")

    print("Widgets")
    pusher.reload_widgets()
    w = wait_for(lambda: sends_of("widgets"), msg="Widget-Push")
    ok(w[0]["token"] == TOK_WIDGET and w[0]["topic"] == "com.ais.aisbot.push-type.widgets"
       and w[0]["payload"] == {"aps": {"content-changed": True}}, "Widget-Push mit eigenem Topic")

    print("Live-Aktivität: Kanal, Push-to-Start, Broadcast, Update-Token, Ende")
    bot = server.service.bot_json(pip)
    meta = {"state": "running", "lines": ["Sucht"], "started_at": "2026-11-13T10:00:00+01:00"}
    live = pusher.live_start(bot, "run-1", meta)
    ok(live is not None, "live_start im Relay-Modus")
    wait_for(lambda: ("create", "") in Fake.channels, msg="Kanal angelegt")
    start = wait_for(lambda: sends_of("liveactivity"), msg="Push-to-Start")
    aps = start[0]["payload"]["aps"]
    ok(start[0]["token"] == TOK_START and aps["event"] == "start" and aps["input-push-channel"] == "Q0hBTk5FTC0x",
       "Push-to-Start an das Start-Token mit Kanal")
    ok(start[0]["topic"] == "com.ais.aisbot.push-type.liveactivity", "Live-Topic")
    session = pusher.board.session
    r = api("POST", "/api/live-activities", json={"push_token": TOK_LIVE, "run_id": session})
    ok(r.status_code == 200, "Update-Token gemeldet")
    wait_for(lambda: Fake.registered.get(TOK_LIVE) == "liveactivity", msg="Update-Token bei der Cloud")
    live.update({**meta, "lines": ["Sucht", "Liest Seite"]})
    up = wait_for(lambda: Fake.broadcasts, timeout=8, msg="Broadcast-Update")
    ok(up[0]["channelId"] == "Q0hBTk5FTC0x" and up[0]["payload"]["aps"]["event"] == "update", "Update per Broadcast")
    live.end({**meta, "state": "done", "finished_at": "2026-11-13T10:01:00+01:00"})
    wait_for(lambda: any(b["payload"]["aps"]["event"] == "end" for b in Fake.broadcasts), msg="Ende per Broadcast")
    wait_for(lambda: any(s["token"] == TOK_LIVE and s["payload"]["aps"]["event"] == "end" for s in sends_of("liveactivity")),
             msg="Ende auch an das Update-Token")
    ok(True, "Ende per Broadcast und an das Update-Token")
    server.db.q("UPDATE live_sessions SET ended_at=datetime('now','-31 minutes') WHERE session=?", (session,))
    pusher.board.ended = None
    pusher.board.sweep(set())
    wait_for(lambda: ("delete", "Q0hBTk5FTC0x") in Fake.channels, msg="alter Kanal gelöscht")
    ok(True, "alte Kanäle werden über das Relay gelöscht")

    print("Aufräumen und Fehlerfälle")
    api("POST", "/api/devices", json={"apns_token": TOK_GONE, "platform": "ios"})
    wait_for(lambda: TOK_GONE in Fake.registered, msg="Token gemeldet")
    server.service._add(pip, "bot", "Noch eine Nachricht")
    wait_for(lambda: not server.db.one("SELECT 1 FROM devices WHERE token=?", (TOK_GONE,)), msg="Unregistered entfernt")
    ok(True, "Unregistered → Token lokal gelöscht")
    Fake.registered.pop(TOK_IPHONE)
    pusher.relay._registered.add(TOK_IPHONE)  # Server glaubt, es sei gemeldet – Cloud kennt es nicht (mehr)
    n = len([s for s in Fake.sends if s["token"] == TOK_IPHONE])
    server.service._add(pip, "bot", "Und noch eine")
    wait_for(lambda: len([s for s in Fake.sends if s["token"] == TOK_IPHONE]) >= n + 2, msg="Wiederholung")
    ok(Fake.registered.get(TOK_IPHONE) == "ios", "UnknownToken → neu gemeldet und einmal wiederholt")

    Fake.configured = False
    pusher.relay._status_at = 0
    pusher.reset_mode()
    pusher.relay._status_at = 0
    wait_for(lambda: (pusher.mode(), pusher.relay._configured is False)[1], msg="Status neu gelesen")
    ok(pusher.mode() is None and not pusher.enabled, "Relay in der Cloud nicht eingerichtet → Mitteilungen aus")
    Fake.configured = True
    pusher.reset_mode()

    cfg = load_config()
    cfg["cloud_url"] = "http://127.0.0.1:9"  # nicht erreichbar
    save_config(cfg)
    pusher.reset_mode()
    t0 = time.time()
    server.service._add(pip, "bot", "Cloud weg")
    api("POST", f"/api/bots/{pip}/read")
    ok(time.time() - t0 < 1.0, "Cloud nicht erreichbar: Läufe und Lesen blockieren nicht")
    time.sleep(1)
    ok(api("GET", "/api/health").status_code == 200, "Server läuft weiter")

    cloud_mod.delete_secret()
    cfg = load_config()
    for k in ("owner_id", "cloud_server_id"):
        cfg.pop(k, None)
    save_config(cfg)
    pusher.reset_mode()
    ok(pusher.mode() is None, "Kopplung aufgehoben → keine Mitteilungen")


# -- Teil 2: Convex-Dev mit echtem APNs (nur erfundene Tokens) ------------------------------------
CLOUD_DIR = ROOT.parent / "Cloud"


def dev_env() -> dict:
    env = {}
    for line in (CLOUD_DIR / ".env.local").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.split("#")[0].strip()
    assert env.get("CONVEX_DEPLOYMENT", "").startswith("dev:"), "Teil 2 läuft nur gegen ein Dev-Deployment"
    return env


def convex_run(fn: str, args: dict) -> dict:
    r = subprocess.run(["npx", "convex", "run", fn, json.dumps(args)], cwd=CLOUD_DIR, capture_output=True, text=True,
                       timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-500:])
    return json.loads(r.stdout)


def convex_call(cloud_url: str, kind: str, path: str, args: dict, token: str) -> dict:
    r = httpx.post(f"{cloud_url}/api/{kind}", json={"path": path, "args": args, "format": "json"},
                   headers={"Authorization": f"Bearer {token}"}, timeout=30)
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError(data.get("errorMessage"))
    return data["value"]


def part_convex_dev() -> None:
    env = dev_env()
    site, apiurl = env["CONVEX_SITE_URL"], env["CONVEX_URL"]
    print(f"Convex-Dev ({env['CONVEX_DEPLOYMENT']}) mit echtem APNs, erfundene Tokens")
    cfg = load_config()
    cfg["cloud_url"] = site
    save_config(cfg)
    sess = convex_run("devtools:issueTestSession", {"appleSub": "test.push-" + os.urandom(4).hex(), "name": "Pushtest"})
    tok = sess["token"]
    try:
        code = http.post("/api/setup/link", json={}).json()["pending"]["code"]
        ok(convex_call(apiurl, "mutation", "servers:claimServer", {"code": code}, tok)["ok"], "Testserver mit Dev-Konto gekoppelt")
        wait_for(lambda: http.get("/api/setup").json()["linked"], 20, "gekoppelt")
        pusher.reset_mode()
        ok(pusher.mode() == "relay", "Relay-Modus gegen Convex-Dev")
        wait_for(lambda: pusher.relay._configured is not None, 15, "Status von Convex")
        ok(pusher.relay._configured is True, "Convex-Dev: APNs-Schlüssel eingerichtet (configured)")
        secret = cloud_mod.get_secret()
        fake = os.urandom(32).hex()
        raw = httpx.post(site + "/push/send", headers={"Authorization": f"Bearer {secret}"}, timeout=30, json={
            "pushes": [{"token": fake, "pushType": "alert", "payload": {"aps": {"badge": 0}}}]}).json()
        ok(raw["results"][0]["reason"] == "UnknownToken", "nicht gemeldetes Token → UnknownToken, kein Versand")
        r = httpx.post(site + "/push/send", headers={"Authorization": "Bearer falsch"}, timeout=30,
                       json={"pushes": [{"token": fake, "payload": {"aps": {}}}]})
        ok(r.status_code == 401, "falsches serverSecret → 401")
        res = pusher.relay.send([{"token": fake, "pushType": "alert", "priority": "5", "payload": {"aps": {"badge": 0}}}],
                                lambda t: "ios")
        ok(res[0]["status"] == 400 and res[0]["reason"] == "BadDeviceToken",
           f"Probeversand an erfundenes Token → BadDeviceToken (APNs echt, Schlüssel gültig): {res[0]}")
        api("POST", "/api/devices", json={"apns_token": fake, "platform": "ios"})
        pip = server.db.bots()[0]["id"]
        server.service._add(pip, "bot", "Probe")
        wait_for(lambda: not server.db.one("SELECT 1 FROM devices WHERE token=?", (fake,)), 30, "Fake-Token entfernt")
        ok(True, "über notify: BadDeviceToken → Token lokal entfernt")
        res = pusher.relay.send([{"token": fake, "pushType": "widgets", "payload": {"aps": {"content-changed": True}}}],
                                lambda t: "ios")
        ok(res[0]["reason"] in ("TopicDisallowed", "UnknownToken"), f"App-Token mit Widget-Push abgelehnt ({res[0]['reason']})")
        ch = pusher.relay.create_channel()
        if ch:
            pusher.relay.delete_channel(ch)
            ok(True, "Broadcast-Kanal über das Relay angelegt und gelöscht")
        else:
            print("  (Broadcast-Kanal nicht angelegt – Broadcast für die App bei Apple nicht freigeschaltet?)")
    finally:
        try:
            convex_call(apiurl, "mutation", "users:deleteAccount", {}, tok)
        except Exception as e:  # noqa: BLE001
            print("  (Aufräumen:", e, ")")
    server.cloud.heartbeat()
    ok(not http.get("/api/setup").json()["linked"], "Testkonto gelöscht → Kopplung aufgehoben")


def main() -> None:
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeHandler)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning")
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    ok(profile.edition() == "standard", "Edition standard")
    part_badge()
    part_fake()
    if os.environ.get("AISBOT_SKIP_CONVEX") == "1" or not (CLOUD_DIR / ".env.local").exists():
        print("Teil Convex-Dev übersprungen (AISBOT_SKIP_CONVEX=1 oder kein Cloud/.env.local)")
    else:
        part_convex_dev()
    srv.should_exit = True
    fake.shutdown()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil

        cloud_mod.delete_secret()
        shutil.rmtree(TMP, ignore_errors=True)
