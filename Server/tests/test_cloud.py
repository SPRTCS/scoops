"""Test für die Konto-Anbindung (Server 1.12): Sitzungs-JWT, Kopplung, Herzschlag, /api/setup.

Startet eine eigene Testinstanz im Prozess (eigene Datenbank, Konfiguration und Schlüsselbund-Eintrag in
einem Temp-Ordner, eigener Port) – niemals die laufende Produktion auf 8787.

Teil 1 spielt Convex mit einem kleinen Fake-Server (eigener RSA-Schlüssel). Teil 2 läuft gegen das
Convex-**Dev**-Deployment aus Cloud/.env.local (überspringen mit AISBOT_SKIP_CONVEX=1).

    cd Server && uv run python tests/test_cloud.py
"""

from __future__ import annotations

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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-cloud-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
KEYCHAIN = "ais-bot-cloud-test-" + os.urandom(4).hex()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, FAKE_PORT = free_port(), free_port()
FAKE = f"http://127.0.0.1:{FAKE_PORT}"
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "public_url": "https://scoops.example.test",
                                             "cloud_url": FAKE, "server_name": "Test-Mac"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_CLOUD_KEYCHAIN=KEYCHAIN,
                  AISBOT_CLOUD_POLL="0.3")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import padding, rsa  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

from aisbot import cloud as cloud_mod, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert cloud_mod.KEYCHAIN_SERVICE == KEYCHAIN, "Test darf nie den echten Schlüsselbund-Eintrag benutzen"
from aisbot.version import VERSION as VERSION_EXPECTED  # noqa: E402
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
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
        if fn():
            return True
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


# -- JWT-Hilfen ----------------------------------------------------------------------
def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def new_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def jwk(key, kid: str) -> dict:
    n = key.public_key().public_numbers()
    return {"kty": "RSA", "kid": kid, "alg": "RS256", "use": "sig",
            "n": b64(n.n.to_bytes((n.n.bit_length() + 7) // 8, "big")), "e": b64(n.e.to_bytes(3, "big"))}


def mint(key, kid: str, **claims) -> str:
    now = int(time.time())
    payload = {"iss": FAKE, "aud": "ais-scoops", "sub": "user_owner", "sid": "sess_1", "iat": now, "exp": now + 3600} | claims
    payload = {k: v for k, v in payload.items() if v is not None}
    h = b64(json.dumps({"alg": "RS256", "kid": kid, "typ": "JWT"}).encode())
    p = b64(json.dumps(payload).encode())
    sig = key.sign(f"{h}.{p}".encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{h}.{p}.{b64(sig)}"


# -- Fake-Convex -------------------------------------------------------------------------
class Fake:
    key = new_key()
    kid = "k1"
    claimed = False
    removed = False
    revoked: list[str] = []
    heartbeats: list[dict] = []
    jwks_hits = 0
    starts: list[dict] = []


class FakeHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # noqa: D401 – leise
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
            Fake.jwks_hits += 1
            return self._send(200, {"keys": [jwk(Fake.key, Fake.kid)]})
        self._send(404, {"error": "?"})

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        if self.path == "/servers/claim/start":
            Fake.starts.append(body)
            return self._send(200, {"code": "ABCD-EFGH", "claimId": "c1", "claimSecret": "cs1",
                                    "expiresAt": int(time.time() * 1000) + 600_000, "ttlSeconds": 600})
        if self.path == "/servers/claim/poll":
            if body.get("claimSecret") != "cs1":
                return self._send(404, {"error": "Kopplung unbekannt", "code": "unknown_claim"})
            if not Fake.claimed:
                return self._send(200, {"status": "pending", "expiresAt": 0})
            return self._send(200, {"status": "claimed", "serverId": "srv1", "serverSecret": "srv-secret-xyz",
                                    "ownerId": "user_owner", "name": "Test-Mac"})
        if self.path == "/servers/heartbeat":
            if self.headers.get("authorization") != "Bearer srv-secret-xyz" or Fake.removed:
                return self._send(401, {"error": "Server ist nicht (mehr) gekoppelt", "code": "unknown_server"})
            Fake.heartbeats.append(body)
            return self._send(200, {"ok": True, "serverId": "srv1", "ownerId": "user_owner", "name": "Test-Mac",
                                    "revokedSessions": Fake.revoked})
        self._send(404, {"error": "?"})


def status_with(token: str, path="/api/health") -> int:
    return http.get(path, headers={"Authorization": f"Bearer {token}"}).status_code


def ws_result(token: str) -> str:
    """'open' wenn /api/ws die Verbindung annimmt, sonst 'rejected'."""
    import asyncio

    async def go():
        try:
            async with connect(f"ws://127.0.0.1:{PORT}/api/ws", additional_headers={"Authorization": f"Bearer {token}"}) as ws:
                await ws.send('{"type":"ping"}')
                await asyncio.wait_for(ws.recv(), 5)
                return "open"
        except Exception:  # noqa: BLE001 – Ablehnung vor dem Handshake (HTTP 403) oder Close 4401
            return "rejected"

    return asyncio.run(go())


def part_fake() -> None:
    print("Bestehendes Verhalten")
    ok(http.get("/api/health").status_code == 401, "Health ohne Token → 401")
    ok(status_with(TOKEN) == 200, "API-Token gilt weiter")
    ok(http.get("/api/health", params={"token": TOKEN}).status_code == 200, "API-Token als ?token= gilt weiter")
    ok(http.get("/api/health", headers={"Authorization": f"Bearer {TOKEN}"}).json()["version"] == VERSION_EXPECTED, f"Version {VERSION_EXPECTED}")
    ok(ws_result(TOKEN) == "open", "WebSocket mit API-Token")
    good = mint(Fake.key, "k1")
    ok(status_with(good) == 401, "JWT vor der Kopplung (kein owner_id) → 401")
    ok(http.get("/api/health", params={"token": "ä-kein-ascii"}).status_code == 401, "Nicht-ASCII-Token → 401 statt Fehler")

    print("/api/setup nur lokal")
    st = http.get("/api/setup").json()
    ok(st["linked"] is False and st["pending"] is None and st["cloud_url"] == FAKE, "GET /api/setup: nicht gekoppelt")
    ok(http.get("/api/setup", headers={"X-Forwarded-For": "100.64.0.7"}).status_code == 403, "über Proxy (X-Forwarded-For) → 403")
    ok(http.get("/api/setup", headers={"Tailscale-User-Login": "x@y"}).status_code == 403, "über Tailscale Serve → 403")
    ok(http.post("/api/setup/link", headers={"X-Forwarded-For": "1.2.3.4"}).status_code == 403, "link über Proxy → 403")

    print("Kopplung (Fake-Convex)")
    r = http.post("/api/setup/link", json={})
    ok(r.status_code == 200 and r.json()["pending"]["code"] == "ABCD-EFGH", "POST /api/setup/link → Code")
    ok(Fake.starts[-1] == {"name": "Test-Mac", "version": VERSION_EXPECTED, "publicUrl": "https://scoops.example.test"},
       "claim/start mit Name, Version, publicUrl")
    st = http.get("/api/setup").json()
    ok(st["pending"]["code"] == "ABCD-EFGH" and 590 <= st["pending"]["ttl_seconds"] <= 600 and not st["linked"],
       "GET /api/setup zeigt Code (pending)")
    time.sleep(1)
    ok(not http.get("/api/setup").json()["linked"], "solange nicht eingelöst: weiter pending")
    Fake.claimed = True
    wait_for(lambda: http.get("/api/setup").json()["linked"], msg="gekoppelt")
    cfg = load_config()
    ok(cfg["owner_id"] == "user_owner" and cfg["cloud_server_id"] == "srv1", "owner_id und cloud_server_id in config.json")
    ok(cloud_mod.get_secret() == "srv-secret-xyz", "serverSecret im (Test-)Schlüsselbund")
    ok("srv-secret-xyz" not in (TMP / "config.json").read_text(), "serverSecret nicht in config.json")
    wait_for(lambda: Fake.heartbeats, msg="erster Herzschlag")
    ok(Fake.heartbeats[-1] == {"publicUrl": "https://scoops.example.test", "version": VERSION_EXPECTED}, "Herzschlag mit publicUrl und Version")
    ok(http.post("/api/setup/link", json={}).status_code == 409, "erneut koppeln ohne force → 409")

    print("Sitzungs-JWT")
    ok(status_with(good) == 200, "gültiges JWT des Inhabers → 200")
    ok(http.get("/api/bots", params={"token": good}).status_code == 200, "JWT als ?token=")
    ok(ws_result(good) == "open", "WebSocket mit JWT")
    ok(status_with(mint(Fake.key, "k1", sub="user_fremd")) == 403, "anderes Konto (Gast ohne Share) → 403 statt 401")
    ok(status_with(mint(Fake.key, "k1", exp=int(time.time()) - 120)) == 401, "abgelaufen → 401")
    ok(status_with(mint(new_key(), "k1")) == 401, "falsche Signatur → 401")
    ok(status_with(mint(Fake.key, "k1", aud="andere-app")) == 401, "falsche Audience → 401")
    ok(status_with(mint(Fake.key, "k1", iss="https://evil.example")) == 401, "falscher Aussteller → 401")
    ok(status_with(mint(Fake.key, "k1", nbf=int(time.time()) + 3600)) == 401, "noch nicht gültig (nbf) → 401")
    h = b64(json.dumps({"alg": "none", "kid": "k1"}).encode())
    p = b64(json.dumps({"iss": FAKE, "aud": "ais-scoops", "sub": "user_owner", "exp": int(time.time()) + 600}).encode())
    ok(status_with(f"{h}.{p}.") == 401, "alg none → 401")
    ok(status_with(good[:-4] + "AAAA") == 401, "manipulierte Signatur → 401")
    ok(ws_result(mint(Fake.key, "k1", sub="user_fremd")) == "rejected", "WebSocket mit fremdem JWT → abgelehnt")
    ok(status_with(TOKEN) == 200, "API-Token weiter gültig")

    print("Ablehnungsgrund fürs Log (ohne Token)")
    key_for = lambda kid: server.cloud.jwks.key(FAKE, kid)  # noqa: E731
    reason = lambda tok: cloud_mod.check_jwt(tok, key_for, issuer=FAKE, audience="ais-scoops")[1]  # noqa: E731
    ok(reason(good) == "", "gültig → kein Grund")
    ok(reason(mint(Fake.key, "k1", exp=int(time.time()) - 120)).startswith("abgelaufen seit"), "Grund: abgelaufen")
    ok(reason(mint(new_key(), "k1")) == "Signatur ungültig", "Grund: Signatur")
    ok(reason(mint(Fake.key, "k1", iss="https://evil.example")).startswith("Aussteller https://evil.example"), "Grund: Aussteller")
    ok(reason(mint(Fake.key, "k1", aud="andere-app")) == "falsche Zielgruppe (aud)", "Grund: Zielgruppe")
    import contextlib
    import io
    buf = io.StringIO()
    server.cloud._rejected_logged.clear()
    with contextlib.redirect_stdout(buf):
        bad = mint(Fake.key, "k1", aud="andere-app")  # (anderes Konto ist seit 1.14 ein Gast, kein Ablehnungsgrund)
        status_with(bad)
        status_with(bad)
    log = buf.getvalue()
    ok(log.count("Sitzungs-JWT abgelehnt – falsche Zielgruppe") == 1, "Log-Zeile mit Grund, höchstens einmal pro Minute")
    ok(bad.split(".")[2][:12] not in log and bad[:20] not in log, "Log enthält kein Token")

    print("JWKS-Zwischenspeicher und Schlüsselwechsel")
    hits = Fake.jwks_hits
    for _ in range(5):
        status_with(good)
    ok(Fake.jwks_hits == hits, "JWKS wird zwischengespeichert")
    Fake.key, Fake.kid = new_key(), "k2"
    server.cloud.jwks._last_try = 0  # Sperrzeit für Neuladen in diesem Test überspringen
    ok(status_with(mint(Fake.key, "k2")) == 200 and Fake.jwks_hits == hits + 1, "neue kid → JWKS neu geladen, akzeptiert")
    good = mint(Fake.key, "k2")

    print("Abgemeldete Sitzung (revokedSessions)")
    Fake.revoked = ["sess_1"]
    server.cloud.heartbeat()
    ok(status_with(good) == 401, "Sitzung in revokedSessions → 401")
    ok(status_with(mint(Fake.key, "k2", sid="sess_2")) == 200, "andere Sitzung weiter gültig")
    Fake.revoked = []
    server.cloud.heartbeat()
    ok(status_with(good) == 200, "nach Herzschlag ohne Widerruf wieder gültig")

    print("Herzschlag im Planer")
    n = len(Fake.heartbeats)
    server.cloud.last_heartbeat = 0
    server.cloud.heartbeat_tick()
    server.cloud.heartbeat_tick()
    ok(len(Fake.heartbeats) == n + 1, "heartbeat_tick: höchstens einmal pro 60 s")

    print("Server in der App entfernt")
    Fake.removed = True
    server.cloud.heartbeat()
    cfg = load_config()
    ok("owner_id" not in cfg and cloud_mod.get_secret() is None, "401 unknown_server → Kopplung aufgehoben")
    ok(status_with(good) == 401, "JWT danach abgelehnt")
    ok(status_with(TOKEN) == 200, "API-Token weiter gültig")
    st = http.get("/api/setup").json()
    ok(not st["linked"] and "entfernt" in (st["last_error"] or ""), "/api/setup zeigt den Grund")


# -- Teil 2: Convex-Dev ----------------------------------------------------------------
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
    site, api = env["CONVEX_SITE_URL"], env["CONVEX_URL"]
    print(f"Convex-Dev ({env['CONVEX_DEPLOYMENT']})")
    cfg = load_config()
    cfg["cloud_url"] = site
    save_config(cfg)
    sub = "test.server-" + os.urandom(4).hex()
    sess = convex_run("devtools:issueTestSession", {"appleSub": sub, "name": "Testlauf"})
    tok = sess["token"]
    try:
        r = http.post("/api/setup/link", json={})
        ok(r.status_code == 200, f"Code von Convex-Dev: {r.json()['pending']['code'][:2]}…")
        code = r.json()["pending"]["code"]
        ok(len(code) == 9 and code[4] == "-", "Format XXXX-XXXX")
        time.sleep(1)
        ok(not http.get("/api/setup").json()["linked"], "pending, bis der Code eingelöst ist")
        res = convex_call(api, "mutation", "servers:claimServer", {"code": code.lower().replace("-", " ")}, tok)
        ok(res["ok"] is True, "claimServer über die Convex-HTTP-API (Sitzungs-JWT)")
        wait_for(lambda: http.get("/api/setup").json()["linked"], 20, "gekoppelt mit Convex-Dev")
        ok(load_config()["owner_id"] == sess["userId"], "owner_id = Nutzer-ID aus Convex")
        servers = convex_call(api, "query", "servers:myServers", {}, tok)
        ok(len(servers) == 1 and servers[0]["online"] and servers[0]["version"] == VERSION_EXPECTED
           and servers[0]["publicUrl"] == "https://scoops.example.test", "Herzschlag: myServers zeigt online, Version, URL")
        before = servers[0]["lastSeenAt"]
        time.sleep(1.1)
        server.cloud.heartbeat()
        ok(convex_call(api, "query", "servers:myServers", {}, tok)[0]["lastSeenAt"] > before, "weiterer Herzschlag aktualisiert lastSeenAt")
        ok(status_with(tok) == 200, "echtes Convex-JWT am Server → 200")
        ok(ws_result(tok) == "open", "echtes Convex-JWT am WebSocket")
        other = convex_run("devtools:issueTestSession", {"appleSub": sub + "-fremd"})
        ok(status_with(other["token"]) == 403, "JWT eines anderen Kontos (Gast ohne Share) → 403")
        convex_call(api, "mutation", "sessions:revokeSession", {}, other["token"])  # fremdes Testkonto abmelden
        convex_call(api, "mutation", "users:deleteAccount", {}, convex_run("devtools:issueTestSession", {"appleSub": sub + "-fremd"})["token"])
        second = convex_run("devtools:issueTestSession", {"appleSub": sub})
        convex_call(api, "mutation", "sessions:revokeSession", {"sessionId": sess["sessionId"]}, second["token"])
        server.cloud.heartbeat()
        ok(status_with(tok) == 401 and status_with(second["token"]) == 200, "abgemeldete Sitzung sofort nach Herzschlag abgelehnt")
        tok = second["token"]
    finally:
        try:
            convex_call(api, "mutation", "users:deleteAccount", {}, tok)
        except Exception as e:  # noqa: BLE001
            print("  (Aufräumen:", e, ")")
    server.cloud.heartbeat()
    ok(not http.get("/api/setup").json()["linked"], "Konto gelöscht → Herzschlag 401 → Kopplung aufgehoben")


def main() -> None:
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeHandler)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
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
