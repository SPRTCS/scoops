"""Test für geteilte Scoops (Server 1.14, docs/sharing.md): Standard verweigern, Rollen, Rechner-Stufen, WS-Filter,
Gast-Läufe, Freigaben beim Admin, Tageslimit, Push an Gäste, Share entfernen wirkt sofort.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Eintrag, Edition standard) –
niemals die laufende Produktion. Teil 1 spielt Convex mit einem Fake (eigener RSA-Schlüssel, /shares/sync,
Push-Relay). Läufe nutzen eine Fake-Engine (kein KI-Aufruf). Teil 2 läuft gegen Convex-**Dev**
(überspringen mit AISBOT_SKIP_CONVEX=1).

    cd Server && uv run python tests/test_sharing.py
"""

from __future__ import annotations

import asyncio
import base64
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
from types import SimpleNamespace

TMP = Path(tempfile.mkdtemp(prefix="aisbot-sharing-test-"))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, FAKE_PORT = free_port(), free_port()
FAKE = f"http://127.0.0.1:{FAKE_PORT}"
PREFIX = "ais-scoops-sharetest-" + os.urandom(3).hex()
API_TOKEN = "test-token-" + os.urandom(6).hex()
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX=PREFIX, AISBOT_CLOUD_KEYCHAIN=PREFIX + "-cloud",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import padding, rsa  # noqa: E402
from fastapi.routing import APIRoute, APIWebSocketRoute  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import cloud as cloud_mod, profile, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert cloud_mod.KEYCHAIN_SERVICE.startswith(PREFIX), "Test darf nie den echten Kopplungs-Eintrag benutzen"
assert profile.kc("apns").startswith(PREFIX), "Test darf nie Armans APNs-Schlüssel lesen"
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
db, service = server.db, server.service
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=10.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


# -- JWTs ---------------------------------------------------------------------------------
def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def mint(sub: str, sid: str | None = None) -> str:
    now = int(time.time())
    payload = {"iss": FAKE, "aud": "ais-scoops", "sub": sub, "sid": sid or f"sess_{sub}", "iat": now, "exp": now + 3600}
    h = b64(json.dumps({"alg": "RS256", "kid": "k1", "typ": "JWT"}).encode())
    p = b64(json.dumps(payload).encode())
    return f"{h}.{p}.{b64(KEY.sign(f'{h}.{p}'.encode(), padding.PKCS1v15(), hashes.SHA256()))}"


def jwk() -> dict:
    n = KEY.public_key().public_numbers()
    return {"kty": "RSA", "kid": "k1", "alg": "RS256", "use": "sig",
            "n": b64(n.n.to_bytes((n.n.bit_length() + 7) // 8, "big")), "e": b64(n.e.to_bytes(3, "big"))}


OWNER_ID = "user_owner"
SECRET = "server-secret-" + os.urandom(4).hex()


# -- Fake-Convex ----------------------------------------------------------------------------
class Fake:
    version = 1
    shares: list[dict] = []
    revoked: list[str] = []
    syncs: list[dict] = []
    registered: list[dict] = []
    pushes: list[dict] = []


def share(sid, bot, uid, name, role, computer="none"):
    return {"shareId": sid, "botId": bot, "granteeId": uid, "granteeName": name, "role": role, "computer": computer,
            "createdAt": 1, "updatedAt": 1}


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

    def do_GET(self):  # noqa: N802
        if self.path == "/.well-known/jwks.json":
            return self._send(200, {"keys": [jwk()]})
        self._send(404, {})

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        if self.headers.get("authorization") != f"Bearer {SECRET}":
            return self._send(401, {"code": "unknown_server"})
        if self.path == "/servers/heartbeat":
            return self._send(200, {"ok": True, "serverId": "srv_1", "ownerId": OWNER_ID, "name": "Test-Mac",
                                    "ownerName": "Arman", "revokedSessions": Fake.revoked, "sharesVersion": Fake.version})
        if self.path == "/shares/sync":
            Fake.syncs.append(body)
            for b in body.get("removeBots") or []:
                Fake.shares = [s for s in Fake.shares if s["botId"] != b]
            return self._send(200, {"ok": True, "sharesVersion": Fake.version, "shares": Fake.shares})
        if self.path == "/push/status":
            return self._send(200, {"ok": True, "configured": True, "maxPayloadBytes": 4096})
        if self.path == "/push/register":
            Fake.registered += body.get("tokens") or []
            return self._send(200, {"ok": True, "registered": len(body.get("tokens") or []), "rejected": []})
        if self.path == "/push/send":
            Fake.pushes += body.get("pushes") or []
            return self._send(200, {"ok": True, "sent": len(body["pushes"]),
                                    "results": [{"token": p["token"], "status": 200} for p in body["pushes"]]})
        self._send(404, {"code": "not_found"})


# -- Fake-Engine (kein KI-Aufruf) --------------------------------------------------------------
class FakeEngine:
    calls: list[dict] = []
    cost = 0.001
    action = None  # optional: fn(kwargs) → im Lauf z. B. ein Werkzeug aufrufen

    @classmethod
    def run(cls, **kw):
        tools = {t.schema["name"]: t for t in kw.get("extra_tools") or []}
        rec = {"tools": set(tools), "allow_computer": kw.get("allow_computer", True), "allow_web": kw.get("allow_web", True),
               "mcp": kw.get("mcp_hub"), "budget": kw.get("budget"),
               "system": "\n".join(b["text"] for b in kw["system"] if isinstance(b, dict) and b.get("text")),
               "messages": kw["messages"]}
        cls.calls.append(rec)
        text = "Antwort vom Scoop"
        if cls.action:
            text = cls.action(tools) or text
        u = SimpleNamespace(dollars=cls.cost, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        usage = SimpleNamespace(by_model={kw["model"]: u}, dollars=cls.cost)
        return Outcome(text, "end_turn", usage, [], False, kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def last_call(after: int, timeout=10.0) -> dict:
    wait_for(lambda: len(FakeEngine.calls) > after, timeout, "Lauf gestartet")
    wait_for(lambda: not service.runs, timeout, "Lauf beendet")
    return FakeEngine.calls[-1]


# -- Hilfen -------------------------------------------------------------------------------------
def H(tok: str) -> dict:
    return {"Authorization": f"Bearer {tok}"}


OWNER = H(API_TOKEN)
OWNER_JWT = H(mint(OWNER_ID))
LEA, MAX, CARL, VIEW, CTRL, NONE = (H(mint(u)) for u in ("u_lea", "u_max", "u_carl", "u_view", "u_ctrl", "u_none"))


async def ws_collect(tok: str, seconds: float, action=None) -> tuple[list[dict], int | None]:
    """Verbindet sich mit /api/ws, führt `action` aus und sammelt Ereignisse. Rückgabe (Ereignisse, Close-Code)."""
    events, code = [], None
    try:
        async with connect(f"ws://127.0.0.1:{PORT}/api/ws", additional_headers={"Authorization": f"Bearer {tok}"}) as ws:
            await asyncio.sleep(0.2)
            if action:
                await asyncio.to_thread(action)
            end = time.time() + seconds
            while time.time() < end:
                try:
                    raw = await asyncio.wait_for(ws.recv(), max(0.05, end - time.time()))
                    events.append(json.loads(raw))
                except asyncio.TimeoutError:
                    break
            code = None
    except Exception as e:  # noqa: BLE001
        code = getattr(getattr(e, "rcvd", None), "code", None) or -1
    return events, code


def ws_closed_code(tok: str) -> int | None:
    async def go():
        try:
            async with connect(f"ws://127.0.0.1:{PORT}/api/ws", additional_headers={"Authorization": f"Bearer {tok}"}) as ws:
                await asyncio.wait_for(ws.recv(), 3)
                return None
        except Exception as e:  # noqa: BLE001
            return getattr(getattr(e, "rcvd", None), "code", None) or -1
    return asyncio.run(go())


# -- Aufbau --------------------------------------------------------------------------------
def setup_world() -> dict:
    cfg = load_config()
    cfg.update(api_token=API_TOKEN, cloud_url=FAKE, owner_id=OWNER_ID, cloud_server_id="srv_1", owner_name="Arman",
               user_name="Arman", server_name="Test-Mac", public_url="https://scoops.example.test")
    save_config(cfg)
    server.TOKEN = API_TOKEN
    cloud_mod.set_secret(SECRET)
    server.pusher.reset_mode()
    shared_bot = service.create_bot({"name": "Mila", "label": "Haushalt"})["id"]
    other_bot = service.create_bot({"name": "Privat"})["id"]
    wait_for(lambda: not service.runs, 10, "Vorstellungs-Läufe fertig")
    Fake.shares = [share("sh_lea", shared_bot, "u_lea", "Lea", "write"),
                   share("sh_max", shared_bot, "u_max", "Max", "read"),
                   share("sh_carl", shared_bot, "u_carl", "Carl", "edit"),
                   share("sh_view", shared_bot, "u_view", "Vera", "read", "view"),
                   share("sh_ctrl", shared_bot, "u_ctrl", "Conny", "write", "control")]
    ok(http.post("/api/shares/refresh", headers=OWNER).json()["shares"] == 5, "Admin lädt die Shares (POST /api/shares/refresh)")
    # Gegenstände für die Routen-Prüfung (in beiden Scoops)
    ids = {}
    for key, bot in (("s", shared_bot), ("o", other_bot)):
        m = db.add_message(bot, "user", "Hallo", {})
        f = db.add_file(bot, None, "notiz.txt", b"Inhalt", "text/plain")
        mem = db.add_memory(bot, "profil", "Mag Tee")
        rid = "rt_" + key + os.urandom(3).hex()
        db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,prompt,enabled,next_run,created_at) "
             "VALUES(?,?,?,?,?,?,1,?,datetime('now'))", (rid, bot, "routine", "Morgens", "0 7 * * *", "x", "2099-01-01T07:00:00"))
        sk = db.save_skill(bot, f"Fähigkeit {key}", "d", "schritte")
        ids[key] = {"bot_id": bot, "chat_id": bot, "mid": m["id"], "fid": f["id"], "mem_id": mem["id"], "rid": rid,
                    "sid": sk["id"]}
    g = service.create_group("Team", [shared_bot, other_bot])
    for k in ids:
        ids[k].update(gid=g["id"], aid="a_x", node_id="vm", vid="v_x", account_id="acc_x", app_slug="gmail",
                      name="Bereich")
    return {"shared": shared_bot, "other": other_bot, "ids": ids, "group": g["id"]}


# Endpunkte, die für Gäste freigegeben sind: (Methode, Pfad) → (Rolle, Rechner-Stufe) – alles andere muss 403 sein.
GUEST_ROUTES = {
    ("GET", "/api/shared/me"): ("any", None), ("POST", "/api/shared/devices"): ("any", None),
    ("DELETE", "/api/shared/devices"): ("any", None), ("GET", "/api/bots"): ("any", None),
    ("GET", "/api/models"): ("any", None),
    # Stummschalten und Ruhezeiten gelten pro Person: Gäste ändern nur ihre eigenen (docs/ruhe.md)
    ("PUT", "/api/chats/{chat_id}/mute"): ("read", None),
    ("GET", "/api/settings/quiet-hours"): ("any", None), ("PATCH", "/api/settings/quiet-hours"): ("any", None),
    # Sprache gilt pro Person: Gäste lesen und setzen nur ihre eigene (docs/sprache.md)
    ("GET", "/api/settings/language"): ("any", None), ("PATCH", "/api/settings/language"): ("any", None),
    ("GET", "/api/bots/{bot_id}"): ("read", None), ("PATCH", "/api/bots/{bot_id}"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/messages"): ("read", None), ("POST", "/api/bots/{bot_id}/messages"): ("write", None),
    ("POST", "/api/bots/{bot_id}/stop"): ("write", None), ("POST", "/api/bots/{bot_id}/read"): ("read", None),
    ("PUT", "/api/messages/{mid}/reaction"): ("write", None),
    # App 1.3: Suche (nur geteilte Scoops), Ausschnitt um eine Fundstelle, eigene Nachricht bearbeiten
    ("GET", "/api/search"): ("any", None), ("GET", "/api/chats/{chat_id}/messages/around/{mid}"): ("read", None),
    ("PATCH", "/api/messages/{mid}"): ("write", None),
    ("GET", "/api/chats/{chat_id}/files"): ("read", None), ("POST", "/api/chats/{chat_id}/files"): ("write", None),
    ("GET", "/api/files/{fid}"): ("read", None), ("DELETE", "/api/files/{fid}"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/avatar"): ("read", None), ("PUT", "/api/bots/{bot_id}/avatar"): ("edit", None),
    ("DELETE", "/api/bots/{bot_id}/avatar"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/memories"): ("edit", None), ("DELETE", "/api/memories/{mem_id}"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/routines"): ("edit", None), ("PATCH", "/api/routines/{rid}"): ("edit", None),
    ("DELETE", "/api/routines/{rid}"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/skills"): ("edit", None), ("PATCH", "/api/skills/{sid}"): ("edit", None),
    ("DELETE", "/api/skills/{sid}"): ("edit", None),
    ("GET", "/api/bots/{bot_id}/usage"): ("read", None),
    ("POST", "/api/transcribe"): ("write", None),
    ("GET", "/api/voice/live"): ("write", None), ("POST", "/api/voice/live/preview"): ("write", None),
    ("GET", "/api/computer"): ("read", "view"), ("GET", "/api/computer/screen.jpg"): ("read", "view"),
    ("POST", "/api/computer/takeover"): ("read", "control"), ("POST", "/api/computer/release"): ("read", "control"),
    ("POST", "/api/computer/input"): ("read", "control"),
}
# ohne Anmeldung bzw. nur lokal (eigene Prüfungen in test_cloud/test_nodes)
UNAUTH = {("POST", "/api/nodes/claim"), ("GET", "/api/setup"), ("PATCH", "/api/setup/config"), ("POST", "/api/setup/link"),
          ("POST", "/api/setup/this-mac"), ("POST", "/api/setup/node-pair"), ("POST", "/api/setup/reload"),
          ("POST", "/mcp/task"),  # eigenes laufbezogenes Token (test_tasks.py)
          ("GET", "/api/setup/abos"), ("GET", "/api/setup/abos/refresh"), ("PATCH", "/api/setup/abos"), ("POST", "/api/setup/abos/{provider}/login"),
          ("POST", "/mcp/abo")}  # KI-Abos: nur lokal bzw. Token pro Codex-Prozess (test_abos.py)
QUERY_BOT = {"/api/transcribe", "/api/voice/live", "/api/voice/live/preview", "/api/computer", "/api/computer/screen.jpg",
             "/api/computer/takeover", "/api/computer/release", "/api/computer/input"}
BODIES = {("PATCH", "/api/bots/{bot_id}"): {"name": "Mila"}, ("POST", "/api/bots/{bot_id}/messages"): {"text": "hi"},
          ("PUT", "/api/messages/{mid}/reaction"): {"emoji": "👍"}, ("PATCH", "/api/routines/{rid}"): {"enabled": True},
          ("PATCH", "/api/skills/{sid}"): {"name": "x"}, ("POST", "/api/shared/devices"): {"apns_token": "ab" * 32},
          ("DELETE", "/api/shared/devices"): {"apns_token": "ab" * 32}, ("POST", "/api/computer/input"): {"type": "move", "x": 1, "y": 1},
          ("PATCH", "/api/settings/language"): {"language": "de"}}
# App 1.3 (Suche/Bearbeiten, Heute, Systemintegration, Ruhe/Vorlagen): was Gäste dürfen und was nur der Admin darf.
# Die Systemintegration (Teilen, Kurzbefehle) bringt keine eigenen Routen mit, sie benutzt die vorhandenen.
APP13_GUEST_ROUTES = {
    ("GET", "/api/search"), ("GET", "/api/chats/{chat_id}/messages/around/{mid}"), ("PATCH", "/api/messages/{mid}"),
    ("PUT", "/api/chats/{chat_id}/mute"), ("GET", "/api/settings/quiet-hours"), ("PATCH", "/api/settings/quiet-hours"),
    ("GET", "/api/settings/language"), ("PATCH", "/api/settings/language"),
}
APP13_OWNER_ONLY = {
    ("GET", "/api/today"), ("GET", "/api/approvals"),
    ("GET", "/api/bots/{bot_id}/template"), ("POST", "/api/templates/check"), ("POST", "/api/templates/import"),
}
SKIP_CALL = {("DELETE", "/api/files/{fid}"), ("DELETE", "/api/memories/{mem_id}"), ("DELETE", "/api/routines/{rid}"),
             ("DELETE", "/api/skills/{sid}"),  # zerstörend: Erlaubnis nur prüfen, wenn erwartet verboten
             ("PATCH", "/api/messages/{mid}")}  # nur eigene Nachrichten (fremde → 403), Erlaubtes prüft test_chat_edit.py


def routes():
    for r in server.app.routes:
        if isinstance(r, APIRoute):
            for m in r.methods - {"HEAD", "OPTIONS"}:
                yield m, r.path
        elif isinstance(r, APIWebSocketRoute):
            yield "WS", r.path


def call(method: str, path: str, ids: dict, headers: dict) -> int:
    url = path
    for k, v in ids.items():
        url = url.replace("{" + k + "}", v)
    params = {"bot": ids["bot_id"]} if path in QUERY_BOT else {}
    if path == "/api/chats/{chat_id}/files" and method == "POST":
        params["name"] = "a.txt"
    body = BODIES.get((method, path))
    r = http.request(method, url, headers={**headers, "content-type": "application/json"}, params=params,
                     content=json.dumps(body if body is not None else {}).encode())
    return r.status_code


def allowed_for(sh: dict | None, need: tuple) -> bool:
    role, comp = need
    if sh is None:
        return False
    if role == "any":
        return True
    rank = {"read": 1, "write": 2, "edit": 3}
    crank = {"none": 0, "view": 1, "control": 2}
    return rank[sh["role"]] >= rank[role] and (comp is None or crank[sh["computer"]] >= crank[comp])


# -- Teil 1 ----------------------------------------------------------------------------------
def part_fake(w: dict) -> None:
    S, O = w["shared"], w["other"]
    ids = w["ids"]

    print("Standard verweigern: alle Routen systematisch")
    all_routes = sorted(set(routes()))
    http_routes = [(m, p) for m, p in all_routes if m != "WS" and (m, p) not in UNAUTH and p not in ("/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc")]
    ok(len(http_routes) > 75, f"{len(http_routes)} HTTP-Routen gefunden")
    unknown = [(m, p) for m, p in GUEST_ROUTES if (m, p) not in set(http_routes)]
    ok(not unknown, f"alle Gast-Routen existieren ({unknown})")
    # 1) Gast ohne jeden Share: überall 403
    bad = [(m, p, c) for m, p in http_routes if (c := call(m, p, ids["s"], NONE)) != 403]
    ok(not bad, f"Gast ohne Share → 403 auf allen {len(http_routes)} Routen {bad[:5]}")
    ok(call("GET", "/api/health", ids["s"], {"Authorization": "Bearer kaputt"}) == 401, "ungültiges Token bleibt 401")
    # 2) Gäste mit Share: nicht geteilter Scoop überall 403, nicht freigegebene Routen 403, freigegebene je nach Rolle
    for tok, sh in ((LEA, Fake.shares[0]), (MAX, Fake.shares[1]), (CARL, Fake.shares[2]), (VIEW, Fake.shares[3]), (CTRL, Fake.shares[4])):
        wrong_bot = [(m, p, c) for m, p in http_routes if "{" in p or p in QUERY_BOT
                     if (c := call(m, p, ids["o"], tok)) != 403]
        ok(not wrong_bot, f"{sh['granteeName']} ({sh['role']}/{sh['computer']}): fremder Scoop → überall 403 {wrong_bot[:4]}")
        errors = []
        for m, p in http_routes:
            need = GUEST_ROUTES.get((m, p))
            expect_ok = need is not None and allowed_for(sh, need)
            if expect_ok and (m, p) in SKIP_CALL:
                continue
            c = call(m, p, ids["s"], tok)
            if (c == 403) == expect_ok:
                errors.append((m, p, c))
        ok(not errors, f"{sh['granteeName']}: geteilter Scoop – genau die erlaubten Routen (Rolle/Rechner) {errors[:5]}")
    ok(call("GET", "/api/health", ids["s"], OWNER) == 200 and call("GET", "/api/health", ids["s"], OWNER_JWT) == 200,
       "Admin (API-Token und Sitzungs-JWT) unverändert")
    for m, p in [("GET", "/api/bots"), ("GET", "/api/vault"), ("GET", "/api/usage"), ("GET", "/api/groups")]:
        ok(call(m, p, ids["s"], OWNER) == 200, f"Admin {m} {p} → 200")

    print("Lesen darf nicht schreiben, Schreiben darf nicht bearbeiten")
    ok(http.post(f"/api/bots/{S}/messages", headers=MAX, json={"text": "Hallo"}).status_code == 403, "Lesen: Nachricht senden → 403")
    ok(http.get(f"/api/bots/{S}/messages", headers=MAX).status_code == 200, "Lesen: Verlauf lesen → 200")
    ok(http.patch(f"/api/bots/{S}", headers=LEA, json={"name": "X"}).status_code == 403, "Schreiben: Scoop umbenennen → 403")
    r = http.patch(f"/api/bots/{S}", headers=CARL, json={"character": "geduldig"})
    ok(r.status_code == 200 and r.json()["character"] == "geduldig" and "model" not in r.json(), "Bearbeiten: Charakter ändern → 200 (Gast-Ansicht)")
    for field in ({"model": "claude-opus-5-5"}, {"computer_node": "vm"}, {"primary": True}, {"guest_tools": {"computer": True}},
                  {"guest_budget": 99}, {"section": "x"}):
        ok(http.patch(f"/api/bots/{S}", headers=CARL, json=field).status_code == 403, f"Bearbeiten: {list(field)[0]} → 403 (nur Admin)")
    mems = http.get(f"/api/bots/{S}/memories", headers=CARL).json()
    ok(mems and all(m["bot_id"] == S for m in mems), "Bearbeiten: nur Gedächtnis dieses Scoops")
    gmem = db.add_memory(None, "fakt", "Privat: Arman hat Geburtstag am 1.1.")
    ok(gmem["id"] not in {m["id"] for m in http.get(f"/api/bots/{S}/memories", headers=CARL).json()}
       and http.delete(f"/api/memories/{gmem['id']}", headers=CARL).status_code == 403, "„Für alle Scoops“-Gedächtnis für Gäste tabu")
    ok(http.post(f"/api/bots/{S}/reset", headers=CARL).status_code == 403 and http.delete(f"/api/bots/{S}", headers=CARL).status_code == 403,
       "Bearbeiten: Zurücksetzen/Löschen → 403")
    ok(http.get(f"/api/bots/{S}/template", headers=CARL).status_code == 403
       and http.post("/api/templates/import", headers=CARL, json={"template": {"format": 1, "type": "ais-scoops-template", "name": "X"}}).status_code == 403
       and http.post("/api/templates/check", headers=CARL, json={}).status_code == 403,
       "Bearbeiten: Scoop als Vorlage exportieren oder Vorlagen importieren → 403 (nur Admin)")
    # App 1.3 als Ganzes: Jede neue Route ist entweder ausdrücklich für Gäste freigegeben oder nur für den Admin.
    # (Die Schleife oben prüft ohnehin jede Route; hier steht, was gewollt ist, damit eine neue Route auffällt.)
    new_routes = set(APP13_GUEST_ROUTES) | APP13_OWNER_ONLY
    ok(new_routes <= set(routes()), f"alle Routen von App 1.3 vorhanden ({sorted(new_routes - set(routes()))})")
    ok(all(r in GUEST_ROUTES for r in APP13_GUEST_ROUTES) and not (APP13_OWNER_ONLY & set(GUEST_ROUTES)),
       "App 1.3: Suche, Ausschnitt, Bearbeiten, Stummschalten, Ruhezeiten für Gäste; Heute, Postfach, Vorlagen nicht")
    ok(all(http.get(u, headers=h).status_code == 403 for u in ("/api/today", "/api/approvals") for h in (CARL, LEA, VIEW))
       and http.get("/api/today", headers=OWNER).status_code == 200
       and http.get("/api/approvals", headers=OWNER).status_code == 200,
       "Seite „Heute“ und Freigaben-Postfach: Gäste (jede Rolle) → 403, Admin → 200")
    me = http.get("/api/shared/me", headers=LEA).json()
    ok(me["role"] == "guest" and me["name"] == "Lea" and me["shares"][0]["role"] == "write", "GET /api/shared/me")
    ok(http.get("/api/shared/me", headers=OWNER).json()["role"] == "owner", "/api/shared/me für den Admin")
    lst = http.get("/api/bots", headers=LEA).json()
    ok([b["id"] for b in lst] == [S], "Gast sieht nur geteilte Scoops")
    gb = lst[0]
    ok(gb["access"] == {"share_id": "sh_lea", "role": "write", "computer": "none", "owner_id": OWNER_ID, "owner_name": "Arman",
                        "server_name": "Test-Mac"} and not {"model", "guest_tools", "shared", "computer_node"} & set(gb),
       "Gast-Ansicht: access, kein Modell/Teilen/Rechner")
    ab = http.get(f"/api/bots/{S}", headers=OWNER).json()
    ok(ab["shared"]["count"] == 5 and ab["guest_tools"] == {"web": True, "computer": False, "apps": [], "mcp": [], "phone": False,
                                                           "mail": False} and ab["guest_budget"] == 2.0,
       "Admin-Ansicht: shared, guest_tools (Standard nur Websuche), guest_budget 2 $")

    print("Rechner-Stufen")
    ok(http.get("/api/computer", headers=LEA, params={"bot": S}).status_code == 403, "Kein Zugriff: Rechner-Status → 403")
    ok(http.get("/api/computer", headers=VIEW, params={"bot": S}).status_code == 200, "Zusehen: Rechner-Status → 200")
    ok(http.get("/api/computer/screen.jpg", headers=VIEW, params={"bot": S}).status_code != 403, "Zusehen: Bildschirm erlaubt")
    ok(http.post("/api/computer/takeover", headers=VIEW, params={"bot": S}).status_code == 403, "Zusehen: Übernehmen → 403")
    ok(http.post("/api/computer/release", headers=CTRL, params={"bot": S}).status_code == 200, "Steuern: Freigeben/Übernehmen erlaubt")
    ok(http.get("/api/computer", headers=VIEW, params={"bot": S, "node": "n_fremd"}).status_code == 403, "anderer Rechner (node) → 403")
    ok("computer_node" in http.get(f"/api/bots/{S}", headers=VIEW).json(), "Zusehen: Scoop-JSON nennt den Rechner")

    print("WebSocket-Filter")
    ok(ws_closed_code(NONE["Authorization"][7:]) == 4403, "Gast ohne Share: WS → 4403")

    def act():
        service._add(S, "bot", "Für alle sichtbar")
        service._add(O, "bot", "Geheim im anderen Scoop")
        service._add(S, "approval", "", {"approval_id": "a_ws", "title": "Mail an Bank", "details": "IBAN …", "state": "pending",
                                         "kind": "mail", "mail": {"to": ["bank@example.com"], "body": "geheim"}})
        service._add(S, "status", "", {"state": "running", "lines": ["Öffnet Safari mit Kontoauszug"], "uses_computer": True})
        service._emit_chat(S)
        service._emit_chat(O)
        server.events.publish("sections.updated", {"sections": []})
        server.events.publish("group.updated", service.group_json(w["group"]))
    evs, _ = asyncio.run(ws_collect(LEA["Authorization"][7:], 1.5, act))
    texts = [e["data"].get("text") for e in evs if e["type"] == "message.created"]
    ok("Für alle sichtbar" in texts and "Geheim im anderen Scoop" not in texts, "nur Nachrichten geteilter Scoops")
    appr = next(e["data"] for e in evs if e["type"] == "message.created" and e["data"]["role"] == "approval")
    ok(appr["meta"]["title"] == "Wartet auf Freigabe durch Arman" and "mail" not in appr["meta"] and "IBAN" not in json.dumps(appr),
       "Freigabe-Karte: nur „Wartet auf Freigabe durch Arman“")
    stat = next(e["data"] for e in evs if e["type"] == "message.created" and e["data"]["role"] == "status")
    ok(stat["meta"]["lines"] == ["Arbeitet am Rechner"], "Statuszeile ohne Rechner-Zugriff: nur „Arbeitet am Rechner“")
    ups = [e["data"] for e in evs if e["type"] == "bot.updated"]
    ok(ups and all(u["id"] == S and "model" not in u and "access" in u for u in ups), "bot.updated nur geteilt, in Gast-Ansicht")
    ok(not any(e["type"] in ("sections.updated", "group.updated", "bot.created") for e in evs), "keine Gruppen/Bereiche")
    evs_v, _ = asyncio.run(ws_collect(VIEW["Authorization"][7:], 1.0, lambda: service._add(
        S, "status", "", {"state": "running", "lines": ["Öffnet Safari"], "uses_computer": True})))
    st_v = next(e["data"] for e in evs_v if e["type"] == "message.created")
    ok(st_v["meta"]["lines"] == ["Öffnet Safari"], "mit Rechner-Stufe Zusehen: echte Statuszeilen")
    evs_c, _ = asyncio.run(ws_collect(LEA["Authorization"][7:], 1.0, lambda: service.computers.vm.notify()))
    evs_c2, _ = asyncio.run(ws_collect(VIEW["Authorization"][7:], 1.0, lambda: service.computers.vm.notify()))
    ok(not any(e["type"] == "computer.updated" for e in evs_c) and any(e["type"] == "computer.updated" for e in evs_c2),
       "computer.updated nur mit Rechner-Stufe")
    evs_o, _ = asyncio.run(ws_collect(API_TOKEN, 1.0, lambda: service._add(O, "bot", "Admin sieht alles")))
    ok(any(e["data"].get("text") == "Admin sieht alles" for e in evs_o if e["type"] == "message.created"), "Admin-WS unverändert")
    msgs = http.get(f"/api/bots/{S}/messages", headers=LEA).json()
    ok(all("IBAN" not in json.dumps(m) for m in msgs), "REST-Verlauf ebenfalls gefiltert")

    print("Läufe: Gast nur mit freigegebenen Werkzeugen")
    n = len(FakeEngine.calls)
    r = http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Wie wird das Wetter?"})
    ok(r.status_code == 200 and r.json()["meta"]["author_user_id"] == "u_lea" and r.json()["meta"]["author_role"] == "write",
       "Nachricht trägt Absender (author_user_id/name/role)")
    c = last_call(n)
    ok(not c["allow_computer"] and c["allow_web"], "Gast-Lauf: kein Rechner, Websuche erlaubt")
    ok(c["tools"] <= {"merken", "reagieren", "datei_speichern", "dateien_auflisten", "datei_lesen", "datei_zeigen", "link_merken",
                      "faehigkeit_lesen", "freigabe_anfordern"} and "tresor_eintrag_anlegen" not in c["tools"]
       and "login_ausfuellen" not in c["tools"] and "routine_anlegen" not in c["tools"], "Gast-Lauf: nur Grundwerkzeuge, kein Tresor/Routinen")
    ok(c["mcp"].tool_schemas() == [] and c["budget"] <= 2.0, "Gast-Lauf: keine Apps/MCPs, Budget ≤ Tageslimit")
    ok("Lea (Gast, Rolle Schreiben)" in c["system"] and "Privates von Arman" in c["system"], "Systemanweisung nennt Absender und Rolle")
    hist = json.dumps(c["messages"], ensure_ascii=False)
    ok("Lea (Gast): Wie wird das Wetter?" in hist, "Verlauf mit Namen der Person")
    secret = service._add(O, "bot", "Nur im privaten Scoop")
    own = [m for m in db.messages(S, limit=5) if m["role"] == "bot"][-1]
    n = len(FakeEngine.calls)
    r = http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Danke!", "reply_to": own["id"]})
    ok(r.status_code == 200 and r.json()["meta"]["reply_to"]["id"] == own["id"], "Gast: Antwort im geteilten Chat gespeichert")
    last_call(n)
    n = len(FakeEngine.calls)
    r = http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Und das?", "reply_to": secret["id"]})
    ok(r.status_code == 200 and "reply_to" not in r.json()["meta"] and "privaten" not in json.dumps(last_call(n)["messages"]),
       "Gast: reply_to auf fremden Scoop ignoriert, nichts davon im Modell-Kontext")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=OWNER, json={"text": "Und morgen?"})
    c = last_call(n)
    ok(c["allow_computer"] and "tresor_eintrag_anlegen" in c["tools"] and c["mcp"] is service.mcp_hub
       and "stammt von Arman (Admin)" in c["system"], "Admin-Lauf: alle Werkzeuge wie bisher")
    r = http.patch(f"/api/bots/{S}/sharing", headers=OWNER, json={"guest_tools": {"computer": True, "mail": True, "apps": ["gmail"], "evil": 1}})
    ok(r.status_code == 200 and r.json()["guest_tools"]["computer"] and "evil" not in r.json()["guest_tools"], "Admin: Werkzeuge für Geteilte setzen")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Schau am Rechner nach"})
    c = last_call(n)
    ok(c["allow_computer"] and "mail_vorbereiten" in c["tools"] and "datei_vom_rechner" in c["tools"]
       and "tresor_eintrag_anlegen" not in c["tools"], "freigegebene Werkzeuge kommen dazu (nie Tresor)")
    from aisbot.sharing import ScopedMCP
    sm = ScopedMCP(service.mcp_hub, [], ["gmail"])
    ok(sm._allowed("composio__COMPOSIO_MULTI_EXECUTE_TOOL") and not sm._allowed("composio__COMPOSIO_REMOTE_WORKBENCH")
       and not sm._allowed("atrium__list_areas"), "Composio nur Suche/Ausführen, MCPs nur freigegebene")
    try:
        sm.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", {"tools": [{"tool_slug": "NOTION_SEARCH"}]})
        ok(False, "Notion hätte blockiert werden müssen")
    except RuntimeError:
        ok(True, "Composio-App ohne Freigabe (Notion) wird blockiert")
    http.patch(f"/api/bots/{S}", headers=OWNER, json={"guest_tools": {"computer": False, "mail": False, "apps": []}})

    print("Freigaben aus Gast-Läufen landen beim Admin")
    FakeEngine.action = lambda tools: (tools["freigabe_anfordern"].handler({"titel": "Tisch reservieren", "details": "Freitag 19 Uhr"}), "Ich frage Arman.")[1]
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Reservier einen Tisch"})
    last_call(n)
    FakeEngine.action = None
    a = db.one("SELECT * FROM approvals WHERE title='Tisch reservieren'")
    ok(a and a["guest_user_id"] == "u_lea", "Freigabe gespeichert mit Gast-Herkunft")
    am = [m for m in http.get(f"/api/bots/{S}/messages", headers=OWNER).json() if m["role"] == "approval" and m["meta"].get("approval_id") == a["id"]][0]
    ok(am["meta"]["requested_by"] == {"user_id": "u_lea", "name": "Lea"} and am["meta"]["details"] == "Freitag 19 Uhr", "Admin sieht Details und wer anfragt")
    gm = [m for m in http.get(f"/api/bots/{S}/messages", headers=LEA).json() if m["id"] == am["id"]][0]
    ok(gm["meta"]["title"] == "Wartet auf Freigabe durch Arman" and gm["meta"]["details"] == "", "Gast sieht nur „Wartet auf Freigabe“")
    ok(http.post(f"/api/approvals/{a['id']}", headers=CTRL, json={"decision": "approve"}).status_code == 403, "Gast kann nicht freigeben")
    n = len(FakeEngine.calls)
    ok(http.post(f"/api/approvals/{a['id']}", headers=OWNER, json={"decision": "approve"}).status_code == 200, "Admin gibt frei")
    c = last_call(n)
    ok(not c["allow_computer"] and "tresor_eintrag_anlegen" not in c["tools"], "Fortsetzung bleibt Gast-Lauf (eingeschränkt)")

    print("Tageslimit pro Gast")
    http.patch(f"/api/bots/{S}", headers=OWNER, json={"guest_budget": 0.05})
    FakeEngine.cost = 0.06
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=CTRL, json={"text": "Teure Frage"})
    last_call(n)
    FakeEngine.cost = 0.001
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=CTRL, json={"text": "Noch eine"})
    wait_for(lambda: any("Tageslimit erreicht" in m["text"] for m in db.messages(S, limit=3)), 10, "Tageslimit-Antwort")
    time.sleep(0.3)
    ok(len(FakeEngine.calls) == n, "Limit erreicht: kein KI-Aufruf, Antwort „Tageslimit erreicht“")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Ich darf noch?"})
    c = last_call(n)
    ok(c["budget"] <= 0.05, "anderer Gast hat eigenes Limit (Laufbudget ≤ Rest)")
    u = http.get(f"/api/bots/{S}/usage", headers=OWNER).json()
    conny = next(x for x in u["by_person"] if x["user_id"] == "u_ctrl")
    ok(u["by_person"][0]["is_owner"] and conny["today_usd"] >= 0.06 and conny["budget_left_usd"] == 0, "Kosten pro Person (Admin)")
    ug = http.get(f"/api/bots/{S}/usage", headers=CTRL).json()
    ok([x["user_id"] for x in ug["by_person"]] == ["u_ctrl"], "Gast sieht nur eigene Kosten")
    ok(S in http.get("/api/usage", headers=OWNER).json()["by_bot"], "/api/usage.by_bot")
    http.patch(f"/api/bots/{S}", headers=OWNER, json={"guest_budget": 2})

    print("Lesestatus, Reaktionen, Dateien")
    http.post(f"/api/bots/{S}/read", headers=OWNER)
    service._add(S, "bot", "Neu")
    ok(http.get(f"/api/bots/{S}", headers=MAX).json()["unread"] >= 1, "Gast hat eigenen Ungelesen-Zähler")
    http.post(f"/api/bots/{S}/read", headers=MAX)
    ok(http.get(f"/api/bots/{S}", headers=MAX).json()["unread"] == 0 and http.get(f"/api/bots/{S}", headers=OWNER).json()["unread"] >= 1,
       "Gast-Lesen ändert nicht den Zähler des Admins")
    r = http.put(f"/api/messages/{ids['s']['mid']}/reaction", headers=LEA, json={"emoji": "👍"})
    ok(r.json()["meta"]["reactions"].get("user:u_lea") == "👍", "Reaktion des Gasts unter user:<id>")
    other_file = ids["o"]["fid"]
    r = http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Datei", "file_ids": [other_file, ids["s"]["fid"]]})
    ok(r.json()["meta"]["file_ids"] == [ids["s"]["fid"]], "fremde Datei kann nicht angehängt werden")
    wait_for(lambda: not service.runs, 10)

    print("Push an Gäste")
    ok(http.post("/api/shared/devices", headers=LEA, json={"apns_token": "a1" * 32, "platform": "ios"}).status_code == 200, "Gast meldet Gerät")
    http.post("/api/shared/devices", headers=MAX, json={"apns_token": "b2" * 32, "platform": "ios"})
    db.q("INSERT OR REPLACE INTO devices(token,platform,name,created_at) VALUES(?,?,?,datetime('now'))", ("c3" * 32, "ios", "Admin"))
    ok(http.post("/api/shared/devices", headers=LEA, json={"apns_token": "c3" * 32}).status_code == 409, "Admin-Gerät nicht als Gast meldbar")
    wait_for(lambda: any(t.get("userId") == "u_lea" for t in Fake.registered), 10, "Relay-Meldung mit userId")
    ok(True, "Relay: Gast-Token mit userId gemeldet")
    Fake.pushes.clear()
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{S}/messages", headers=LEA, json={"text": "Push-Test"})
    last_call(n)
    wait_for(lambda: any(p["token"] == "b2" * 32 for p in Fake.pushes) and sum(p["token"] == "a1" * 32 for p in Fake.pushes) >= 1, 10, "Pushes")
    time.sleep(0.5)
    to_max = [p for p in Fake.pushes if p["token"] == "b2" * 32]
    to_lea = [p for p in Fake.pushes if p["token"] == "a1" * 32]
    to_admin = [p for p in Fake.pushes if p["token"] == "c3" * 32]
    ok(any(p["payload"]["aps"]["alert"]["title"].startswith("Lea") for p in to_max), "anderer Gast bekommt Leas Nachricht")
    ok(not any(p["payload"]["aps"]["alert"]["body"] == "Push-Test" for p in to_lea), "Absenderin bekommt ihre eigene Nachricht nicht")
    ok(any(p["payload"]["aps"]["alert"]["body"] == "Antwort vom Scoop" for p in to_lea), "Absenderin bekommt die Antwort des Scoops")
    ok(all("badge" not in p["payload"]["aps"] and p["payload"]["shared"] and p["payload"]["server_id"] == "srv_1" for p in to_lea + to_max),
       "Gast-Push ohne Badge, mit shared/server_id")
    ok(any("Lea" in p["payload"]["aps"]["alert"]["title"] for p in to_admin), "Admin bekommt Gast-Nachricht als Push")

    print("Share entfernen wirkt sofort (≤ 60 s über den Herzschlag)")
    async def removal():
        async with connect(f"ws://127.0.0.1:{PORT}/api/ws", additional_headers={"Authorization": LEA["Authorization"]}) as ws:
            await asyncio.sleep(0.2)
            Fake.shares = [s for s in Fake.shares if s["granteeId"] != "u_lea"]
            Fake.version += 1
            t0 = time.time()
            await asyncio.to_thread(server.cloud.heartbeat)  # läuft alle 60 s im Planer
            got = []
            try:
                while True:
                    got.append(json.loads(await asyncio.wait_for(ws.recv(), 5)))
            except Exception as e:  # noqa: BLE001
                return got, getattr(getattr(e, "rcvd", None), "code", None), time.time() - t0
    got, code, secs = asyncio.run(removal())
    ok(any(e["type"] == "share.updated" and e["data"]["shares"] == [] for e in got) and code == 4403,
       f"WS: share.updated, dann Close 4403 ({secs:.1f} s nach dem Herzschlag)")
    ok(http.get(f"/api/bots/{S}", headers=LEA).status_code == 403 and http.get("/api/bots", headers=LEA).status_code == 403,
       "danach REST → 403")
    ok(http.get(f"/api/bots/{S}", headers=MAX).status_code == 200, "andere Gäste behalten Zugriff")
    Fake.revoked = ["sess_u_max"]
    server.cloud.heartbeat()
    ok(http.get(f"/api/bots/{S}", headers=MAX).status_code == 401, "abgemeldete Gast-Sitzung → 401")
    Fake.revoked = []
    server.cloud.heartbeat()

    print("Scoop löschen räumt Shares auf")
    Fake.syncs.clear()
    http.delete(f"/api/bots/{S}", headers=OWNER)
    wait_for(lambda: any(S in (s.get("removeBots") or []) for s in Fake.syncs), 10, "removeBots an Convex")
    ok(http.get(f"/api/bots/{S}", headers=CARL).status_code == 403, "gelöschter Scoop: Gast → 403, Convex räumt auf (removeBots)")


# -- Teil 2: Convex-Dev ------------------------------------------------------------------------
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
    r = subprocess.run(["npx", "convex", "run", fn, json.dumps(args)], cwd=CLOUD_DIR, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-500:])
    return json.loads(r.stdout)


def convex_call(api: str, kind: str, path: str, args: dict, token: str):
    r = httpx.post(f"{api}/api/{kind}", json={"path": path, "args": args, "format": "json"},
                   headers={"Authorization": f"Bearer {token}"}, timeout=30)
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError(data.get("errorMessage"))
    return data["value"]


def part_convex_dev() -> None:
    env = dev_env()
    site, api = env["CONVEX_SITE_URL"], env["CONVEX_URL"]
    print(f"Convex-Dev ({env['CONVEX_DEPLOYMENT']})")
    cfg = load_config()
    for k in ("owner_id", "cloud_server_id", "owner_name"):
        cfg.pop(k, None)
    cfg["cloud_url"] = site
    save_config(cfg)
    cloud_mod.delete_secret()
    server.shares.clear()
    sub = "test.share-" + os.urandom(4).hex()
    admin = convex_run("devtools:issueTestSession", {"appleSub": sub + "-admin", "name": "Admin Test"})
    guest = convex_run("devtools:issueTestSession", {"appleSub": sub + "-gast", "name": "Gast Test"})
    try:
        code = http.post("/api/setup/link", json={"force": True}).json()["pending"]["code"]
        ok(convex_call(api, "mutation", "servers:claimServer", {"code": code}, admin["token"])["ok"], "Server mit Admin-Konto gekoppelt")
        wait_for(lambda: http.get("/api/setup").json()["linked"], 20, "gekoppelt")
        server_id = load_config()["cloud_server_id"]
        bot = service.create_bot({"name": "Geteilt-Test"})["id"]
        wait_for(lambda: not service.runs, 10)
        gh = H(guest["token"])
        ok(http.get("/api/bots", headers=gh).status_code == 403, "echtes Gast-JWT ohne Share → 403")
        ok(http.get("/api/bots", headers=H(admin["token"])).status_code == 200, "echtes Admin-JWT → 200")
        inv = convex_call(api, "action", "shares:createInvite", {"serverId": server_id, "botId": bot, "botName": "Geteilt-Test",
                                                                 "role": "write", "computer": "none"}, admin["token"])
        ok(inv["ok"] and inv["url"].startswith(site + "/i/"), "Einladung über Convex-Dev (https-Link)")
        ok(httpx.get(inv["url"], timeout=20).status_code == 200, "Einladungsseite erreichbar")
        info = convex_call(api, "query", "shares:inviteInfo", {"code": inv["code"]}, guest["token"])
        ok(info["valid"] and info["ownerName"] == "Admin Test", "inviteInfo zeigt Admin und Scoop")
        acc = convex_call(api, "mutation", "shares:accept", {"code": inv["appUrl"]}, guest["token"])
        ok(acc["ok"], "Gast nimmt an")
        mine = convex_call(api, "query", "shares:mine", {}, guest["token"])
        ok(mine and mine[0]["publicUrl"] == "https://scoops.example.test" and mine[0]["online"], "shares:mine mit Server-Adresse, online")
        # ohne Refresh: Cache lädt beim ersten Zugriff des Gasts (gedrosselt) nach
        server.shares._miss_at = 0
        lst = http.get("/api/bots", headers=gh)
        ok(lst.status_code == 200 and [b["id"] for b in lst.json()] == [bot], "Gast sieht den geteilten Scoop sofort nach Annahme")
        n = len(FakeEngine.calls)
        r = http.post(f"/api/bots/{bot}/messages", headers=gh, json={"text": "Hallo vom Gast"})
        ok(r.status_code == 200 and r.json()["meta"]["author_name"] == "Gast Test", "Gast schreibt (Name aus Convex)")
        c = last_call(n)
        ok(not c["allow_computer"], "Gast-Lauf eingeschränkt")
        members = convex_call(api, "query", "shares:listForBot", {"serverId": server_id, "botId": bot}, admin["token"])["members"]
        ok(len(members) == 1, "listForBot (Admin)")
        try:
            convex_call(api, "query", "shares:listForBot", {"serverId": server_id, "botId": bot}, guest["token"])
            ok(False, "Gast darf listForBot nicht")
        except RuntimeError:
            ok(True, "listForBot für den Gast verweigert")
        convex_call(api, "mutation", "shares:update", {"shareId": members[0]["shareId"], "role": "read"}, admin["token"])
        server.cloud.heartbeat()  # meldet neue sharesVersion → Neuladen
        wait_for(lambda: http.post(f"/api/bots/{bot}/messages", headers=gh, json={"text": "x"}).status_code == 403, 15,
                 "Rolle read wirkt")
        ok(http.get(f"/api/bots/{bot}/messages", headers=gh).status_code == 200, "nach Herzschlag: Rolle Lesen wirkt (Lesen ja, Schreiben 403)")
        convex_call(api, "mutation", "shares:remove", {"shareId": members[0]["shareId"]}, admin["token"])
        t0 = time.time()
        server.cloud.heartbeat()
        wait_for(lambda: http.get(f"/api/bots/{bot}", headers=gh).status_code == 403, 15, "Entfernen wirkt")
        ok(True, f"Share entfernt → 403 ({time.time() - t0:.1f} s nach dem Herzschlag)")
    finally:
        for s in (guest, admin):
            try:
                convex_call(api, "mutation", "users:deleteAccount", {}, s["token"])
            except Exception as e:  # noqa: BLE001
                print("  (Aufräumen:", e, ")")
    server.cloud.heartbeat()
    ok(not http.get("/api/setup").json()["linked"], "Testkonten gelöscht, Kopplung aufgehoben")


def main() -> None:
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeHandler)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    w = setup_world()
    part_fake(w)
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
