"""Test für Stummschalten und Ruhezeiten (docs/ruhe.md): pro Person (Inhaber und Gäste getrennt), Mitteilungen
fallen an der Quelle weg bzw. kommen still an, Freigaben und Erinnerungen kommen durch, Zeitzonen und Sommerzeit,
Initiative des Haupt-Scoops wird nachgeholt.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Eintrag, Edition standard) – niemals
die laufende Produktion. Convex und das Push-Relay spielt ein Fake (eigener RSA-Schlüssel), Läufe eine Fake-Engine.

    cd Server && uv run python tests/test_ruhe.py
"""

from __future__ import annotations

import base64
import json
import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from zoneinfo import ZoneInfo

TMP = Path(tempfile.mkdtemp(prefix="aisbot-ruhe-test-"))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, FAKE_PORT = free_port(), free_port()
FAKE = f"http://127.0.0.1:{FAKE_PORT}"
PREFIX = "ais-scoops-ruhetest-" + os.urandom(3).hex()
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

from aisbot import cloud as cloud_mod, profile, ruhe as ruhe_mod, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert cloud_mod.KEYCHAIN_SERVICE.startswith(PREFIX), "Test darf nie den echten Kopplungs-Eintrag benutzen"
assert profile.kc("apns").startswith(PREFIX), "Test darf nie Armans APNs-Schlüssel lesen"
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
db, service, ruhe = server.db, server.service, server.ruhe
passed = 0
BERLIN = ZoneInfo("Europe/Berlin")
TOK_OWNER, TOK_LEA, TOK_MAX = "a" * 64, "b" * 64, "c" * 64


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


# -- JWTs und Fake-Convex (wie test_sharing.py) ------------------------------------------------------
def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OWNER_ID = "user_owner"
SECRET = "server-secret-" + os.urandom(4).hex()


def mint(sub: str) -> str:
    now = int(time.time())
    payload = {"iss": FAKE, "aud": "ais-scoops", "sub": sub, "sid": f"sess_{sub}", "iat": now, "exp": now + 3600}
    h = b64(json.dumps({"alg": "RS256", "kid": "k1", "typ": "JWT"}).encode())
    p = b64(json.dumps(payload).encode())
    return f"{h}.{p}.{b64(KEY.sign(f'{h}.{p}'.encode(), padding.PKCS1v15(), hashes.SHA256()))}"


def jwk() -> dict:
    n = KEY.public_key().public_numbers()
    return {"kty": "RSA", "kid": "k1", "alg": "RS256", "use": "sig",
            "n": b64(n.n.to_bytes((n.n.bit_length() + 7) // 8, "big")), "e": b64(n.e.to_bytes(3, "big"))}


class Fake:
    shares: list[dict] = []
    pushes: list[dict] = []
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
                                    "ownerName": "Arman", "revokedSessions": [], "sharesVersion": 1})
        if self.path == "/shares/sync":
            return self._send(200, {"ok": True, "sharesVersion": 1, "shares": Fake.shares})
        if self.path == "/push/status":
            return self._send(200, {"ok": True, "configured": True})
        if self.path == "/push/register":
            return self._send(200, {"ok": True, "registered": len(body.get("tokens") or []), "rejected": []})
        if self.path == "/push/send":
            with Fake.lock:
                Fake.pushes += body.get("pushes") or []
            return self._send(200, {"ok": True, "results": [{"token": p["token"], "status": 200} for p in body["pushes"]]})
        self._send(404, {"code": "not_found"})


class FakeEngine:
    calls: list[dict] = []

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        u = SimpleNamespace(dollars=0.001, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        return Outcome("Antwort vom Scoop", "end_turn", SimpleNamespace(by_model={kw["model"]: u}, dollars=0.001), [], False,
                       kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def H(tok: str) -> dict:
    return {"Authorization": f"Bearer {tok}"}


OWNER = H(API_TOKEN)
LEA, MAX, NONE = (H(mint(u)) for u in ("u_lea", "u_max", "u_none"))


def alerts(chat: str | None = None, token: str | None = None) -> list[dict]:
    """Sichtbare Mitteilungen (ohne reine Badge-Pushes), optional für einen Chat bzw. ein Gerät."""
    with Fake.lock:
        out = [p for p in Fake.pushes if p["pushType"] == "alert" and "alert" in p["payload"]["aps"]]
    return [p for p in out if (chat is None or p["payload"].get("chat_id") == chat) and (token is None or p["token"] == token)]


def settle(marker_chat: str) -> None:
    """Wartet, bis der Versand durch ist: eine Mitteilung in einem anderen (nie stummen) Chat kommt nach allem davor."""
    n = len(alerts(marker_chat, TOK_OWNER))
    service._add(marker_chat, "bot", "Markierung")
    wait_for(lambda: len(alerts(marker_chat, TOK_OWNER)) > n, msg="Versand abgeschlossen")


def share(sid, bot, uid, name, role):
    return {"shareId": sid, "botId": bot, "granteeId": uid, "granteeName": name, "role": role, "computer": "none",
            "createdAt": 1, "updatedAt": 1}


# -- Teil 1: Ruhezeit rechnen (Zeitzonen, Mitternacht, Sommerzeit) -----------------------------------------
def part_math() -> None:
    print("Ruhezeit rechnen")
    q = {"enabled": True, "start": "22:00", "end": "07:00", "days": [1, 2, 3, 4, 5], "approvals": True, "timezone": "Europe/Berlin"}

    def at(y, mo, d, h, mi, tz=BERLIN):
        return datetime(y, mo, d, h, mi, tzinfo=tz)

    ok(ruhe_mod.quiet_at(q, at(2026, 11, 16, 22, 0)), "Montag 22:00 → Ruhezeit beginnt")
    ok(ruhe_mod.quiet_at(q, at(2026, 11, 17, 6, 59)), "Dienstag 06:59 → noch Ruhezeit (gehört zum Montag)")
    ok(not ruhe_mod.quiet_at(q, at(2026, 11, 17, 7, 0)), "Dienstag 07:00 → vorbei")
    ok(not ruhe_mod.quiet_at(q, at(2026, 11, 16, 21, 59)), "Montag 21:59 → noch nicht")
    ok(ruhe_mod.quiet_at(q, at(2026, 11, 21, 3, 0)), "Samstag 03:00 → Ruhezeit vom Freitag läuft weiter")
    ok(not ruhe_mod.quiet_at(q, at(2026, 11, 21, 23, 0)), "Samstag 23:00 → Samstag nicht gewählt")
    ok(not ruhe_mod.quiet_at(q, at(2026, 11, 23, 3, 0)), "Montag 03:00 → Sonntag nicht gewählt")
    ok(not ruhe_mod.quiet_at({**q, "enabled": False}, at(2026, 11, 16, 23, 0)), "ausgeschaltet → nie")
    day = {**q, "start": "13:00", "end": "15:00"}
    ok(ruhe_mod.quiet_at(day, at(2026, 11, 16, 14, 0)) and not ruhe_mod.quiet_at(day, at(2026, 11, 16, 15, 0))
       and not ruhe_mod.quiet_at(day, at(2026, 11, 21, 14, 0)), "Ruhezeit am Tag (13–15 Uhr), nur an gewählten Tagen")
    ok(ruhe_mod.quiet_at({**q, "start": "08:00", "end": "08:00", "days": [1]}, at(2026, 11, 16, 12, 0))
       and not ruhe_mod.quiet_at({**q, "start": "08:00", "end": "08:00", "days": [1]}, at(2026, 11, 17, 12, 0)),
       "Von = Bis → ganzer Tag an den gewählten Tagen")
    # Gerät in New York, Server in Berlin: es zählt die Uhr der Person
    ny = {**q, "timezone": "America/New_York", "days": [1, 2, 3, 4, 5, 6, 7]}
    ok(ruhe_mod.quiet_at(ny, at(2026, 11, 17, 5, 0)), "New York: 05:00 Berlin = 23:00 dort → Ruhezeit")
    ok(not ruhe_mod.quiet_at(ny, at(2026, 11, 17, 23, 0)), "New York: 23:00 Berlin = 17:00 dort → keine Ruhezeit")
    ok(ruhe_mod.quiet_at(ny, datetime(2026, 11, 17, 4, 0, tzinfo=timezone.utc)), "UTC-Zeitpunkt wird umgerechnet")
    # Sommerzeit: 29.03.2026 springt die Uhr in Berlin von 02:00 auf 03:00, am 25.10. zurück
    alln = {**q, "days": [1, 2, 3, 4, 5, 6, 7]}
    ok(ruhe_mod.quiet_at(alln, datetime(2026, 3, 29, 4, 59, tzinfo=timezone.utc)), "Umstellung im März: 06:59 MESZ → Ruhezeit")
    ok(not ruhe_mod.quiet_at(alln, datetime(2026, 3, 29, 5, 0, tzinfo=timezone.utc)), "Umstellung im März: 07:00 MESZ → vorbei")
    ok(ruhe_mod.quiet_at(alln, datetime(2026, 10, 25, 5, 59, tzinfo=timezone.utc))
       and not ruhe_mod.quiet_at(alln, datetime(2026, 10, 25, 6, 0, tzinfo=timezone.utc)), "Umstellung im Oktober: Ende um 07:00 MEZ")
    ok(ruhe_mod.quiet_at({**alln, "timezone": "Mars/Olympus"}, at(2026, 11, 16, 23, 0)), "unbekannte Zeitzone → Zeit des Servers")


# -- Teil 2: Aufbau -----------------------------------------------------------------------------------------
def setup_world() -> dict:
    cfg = load_config()
    cfg.update(api_token=API_TOKEN, cloud_url=FAKE, owner_id=OWNER_ID, cloud_server_id="srv_1", owner_name="Arman",
               user_name="Arman", server_name="Test-Mac")
    save_config(cfg)
    server.TOKEN = API_TOKEN
    cloud_mod.set_secret(SECRET)
    server.pusher.reset_mode()
    mila = service.create_bot({"name": "Mila", "label": "Haushalt"})["id"]
    theo = service.create_bot({"name": "Theo"})["id"]
    wait_for(lambda: not service.runs, 10, "Vorstellungs-Läufe fertig")
    group = service.create_group("Team", [mila, theo])["id"]
    Fake.shares = [share("sh_lea", mila, "u_lea", "Lea", "write"), share("sh_max", mila, "u_max", "Max", "read")]
    ok(http.post("/api/shares/refresh", headers=OWNER).json()["shares"] == 2, "zwei Gäste auf Mila")
    ok(http.post("/api/devices", headers=OWNER, json={"apns_token": TOK_OWNER, "platform": "ios"}).status_code == 200,
       "Gerät des Inhabers gemeldet")
    for h, tok in ((LEA, TOK_LEA), (MAX, TOK_MAX)):
        ok(http.post("/api/shared/devices", headers=h, json={"apns_token": tok, "platform": "ios"}).status_code == 200,
           "Gast-Gerät gemeldet")
    wait_for(lambda: server.pusher.mode() == "relay", msg="Relay bereit")
    db.q("UPDATE bots SET unread=0")  # auch der Start-Scoop Pip: Die Badge-Zahl im Test zählt nur Mila und Theo
    return {"mila": mila, "theo": theo, "group": group}


# -- Teil 3: Stummschalten ----------------------------------------------------------------------------------
def part_mute(w: dict) -> None:
    M, T, G = w["mila"], w["theo"], w["group"]
    print("Fähigkeiten und Ausgangslage")
    h = http.get("/api/health", headers=OWNER).json()
    ok(h["mute"] is True and h["quiet_hours"] is True and h["templates"] == 1, "/api/health meldet mute, quiet_hours, templates")
    me = http.get("/api/shared/me", headers=LEA).json()
    ok(me["mute"] is True and me["quiet_hours"] is True, "/api/shared/me meldet Gästen die Fähigkeiten")
    b = http.get(f"/api/bots/{M}", headers=OWNER).json()
    ok(b["mute"] == {"muted": False, "until": None}, "Scoop-JSON hat immer das Feld mute")
    ok(http.get(f"/api/groups/{G}", headers=OWNER).json()["mute"] == {"muted": False, "until": None}, "Gruppen-JSON ebenso")

    print("Stummschalten (Inhaber)")
    r = http.put(f"/api/chats/{M}/mute", headers=OWNER, json={"forever": True})
    ok(r.status_code == 200 and r.json() == {"chat_id": M, "mute": {"muted": True, "until": None}}, "dauerhaft stumm")
    ok(http.get(f"/api/bots/{M}", headers=OWNER).json()["mute"]["muted"] is True, "steht im Scoop-JSON")
    ok([x for x in http.get("/api/bots", headers=OWNER).json() if x["id"] == T][0]["mute"]["muted"] is False, "andere Scoops bleiben laut")
    r = http.put(f"/api/chats/{G}/mute", headers=OWNER, json={"minutes": 60})
    until = datetime.fromisoformat(r.json()["mute"]["until"])
    ok(r.status_code == 200 and 3500 < (until - datetime.now(timezone.utc)).total_seconds() <= 3600, "Gruppe für 1 Stunde stumm")
    morgen = (datetime.now(BERLIN) + timedelta(days=1)).replace(hour=7, minute=0, second=0, microsecond=0)
    r = http.put(f"/api/chats/{G}/mute", headers=OWNER, json={"until": morgen.isoformat()})
    ok(r.status_code == 200 and datetime.fromisoformat(r.json()["mute"]["until"]) == morgen, "bis morgen früh (Zeitpunkt mit Zone)")
    ok(http.put(f"/api/chats/{G}/mute", headers=OWNER, json={"until": "2020-01-01T00:00:00+01:00"}).status_code == 400,
       "Zeitpunkt in der Vergangenheit → 400")
    ok(http.put(f"/api/chats/{G}/mute", headers=OWNER, json={"until": "morgen"}).status_code == 400, "kein Zeitpunkt → 400")
    ok(http.put(f"/api/chats/{G}/mute", headers=OWNER, json={"minutes": -5}).status_code == 400, "negative Dauer → 400")
    ok(http.put("/api/chats/b_gibtsnicht/mute", headers=OWNER, json={"forever": True}).status_code == 404, "unbekannter Chat → 404")
    ok(http.put(f"/api/chats/{G}/mute", headers={"Authorization": "Bearer kaputt"}, json={}).status_code == 401, "ohne Anmeldung → 401")
    r = http.put(f"/api/chats/{G}/mute", headers=OWNER, json={})
    ok(r.json()["mute"] == {"muted": False, "until": None}, "leerer Body hebt die Stummschaltung auf")

    print("Mitteilungen aus stummen Chats fallen an der Quelle weg")
    service._add(M, "bot", "Nachricht im stummen Chat")
    settle(T)
    ok(not alerts(M, TOK_OWNER), "stummer Chat → keine Mitteilung an den Inhaber")
    ok(db.bot_row(M)["unread"] == 1, "der Ungelesen-Zähler läuft weiter")
    ok(alerts(T, TOK_OWNER)[-1]["payload"]["aps"]["badge"] == 1, "am App-Symbol zählt der stumme Chat nicht mit (nur Theo)")
    p = alerts(T, TOK_OWNER)[-1]
    ok(p["payload"]["aps"].get("sound") == "default" and "interruption-level" not in p["payload"]["aps"] and p["priority"] == "10",
       "normale Mitteilung: mit Ton, ohne interruption-level, Priorität 10")
    ok(len(alerts(M, TOK_LEA)) == 1 and len(alerts(M, TOK_MAX)) == 1, "die Gäste bekommen sie trotzdem (Stummschaltung pro Person)")

    print("Freigaben und Erinnerungen kommen trotz Stummschaltung durch")
    service._add(M, "approval", "", {"approval_id": "a_r1", "title": "Mail senden", "state": "pending", "kind": "mail"})
    p = wait_for(lambda: alerts(M, TOK_OWNER), msg="Freigabe-Mitteilung")[-1]["payload"]
    ok(p["aps"]["category"] == "SCOOP_APPROVAL" and p["aps"].get("sound") == "default" and p["approval_id"] == "a_r1",
       "Freigabe-Anfrage im stummen Chat → Mitteilung mit Knöpfen und Ton")
    rid = "rt_" + os.urandom(3).hex()
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,1,?,datetime('now'))", (rid, M, "erinnerung", "Zahnarzt", "2026-01-01T09:00:00+01:00", "",
                                                       "Zahnarzt um 9", "2026-01-01T09:00:00+01:00"))
    n = len(alerts(M, TOK_OWNER))
    service.fire_routine(db.routine_dict(db.one("SELECT * FROM routines WHERE id=?", (rid,))))
    p = wait_for(lambda: len(alerts(M, TOK_OWNER)) > n and alerts(M, TOK_OWNER), msg="Erinnerung")[-1]["payload"]
    ok(p["aps"]["alert"]["body"].startswith("⏰") and p["aps"].get("sound") == "default" and p.get("reminder") is True,
       "Erinnerung im stummen Chat → normale Mitteilung")

    print("Pro Person: Gäste schalten nur für sich stumm")
    ok(http.get(f"/api/bots/{M}", headers=LEA).json()["mute"] == {"muted": False, "until": None},
       "Gast sieht die Stummschaltung des Admins nicht")
    r = http.put(f"/api/chats/{M}/mute", headers=LEA, json={"forever": True})
    ok(r.status_code == 200 and r.json()["mute"]["muted"] is True, "Gast (Schreiben) schaltet für sich stumm")
    ok(http.put(f"/api/chats/{M}/mute", headers=MAX, json={}).status_code == 200, "Gast (Lesen) darf das auch")
    http.put(f"/api/chats/{M}/mute", headers=OWNER, json={})
    ok(http.get(f"/api/bots/{M}", headers=OWNER).json()["mute"]["muted"] is False
       and http.get(f"/api/bots/{M}", headers=LEA).json()["mute"]["muted"] is True
       and http.get("/api/bots", headers=MAX).json()[0]["mute"]["muted"] is False, "jede Person hat ihren eigenen Stand")
    ok(http.put(f"/api/chats/{T}/mute", headers=LEA, json={"forever": True}).status_code == 403, "nicht geteilter Scoop → 403")
    ok(http.put(f"/api/chats/{G}/mute", headers=LEA, json={"forever": True}).status_code == 403, "Gruppe → 403 für Gäste")
    ok(http.put(f"/api/chats/{M}/mute", headers=NONE, json={"forever": True}).status_code == 403, "Konto ohne Share → 403")
    nl, nm, no = len(alerts(M, TOK_LEA)), len(alerts(M, TOK_MAX)), len(alerts(M, TOK_OWNER))
    service._add(M, "bot", "Für alle außer Lea")
    wait_for(lambda: len(alerts(M, TOK_MAX)) > nm and len(alerts(M, TOK_OWNER)) > no, msg="Mitteilung an Max und Inhaber")
    settle(T)
    ok(len(alerts(M, TOK_LEA)) == nl, "Lea (stumm) bekommt nichts, Max und der Inhaber schon")
    http.put(f"/api/chats/{M}/mute", headers=LEA, json={})

    print("Ablauf einer befristeten Stummschaltung")
    ruhe.set_mute(None, T, True, datetime.now(timezone.utc) + timedelta(seconds=1))
    ok(ruhe.is_muted(None, T), "Theo für eine Sekunde stumm")
    time.sleep(1.2)
    ok(not ruhe.is_muted(None, T) and http.get(f"/api/bots/{T}", headers=OWNER).json()["mute"]["muted"] is False,
       "nach Ablauf sofort wieder laut (auch ohne Aufräumen)")
    ok(db.one("SELECT 1 FROM mutes WHERE chat_id=?", (T,)) is not None, "Eintrag liegt noch in der Tabelle")
    server.ruhe_tick()
    ok(db.one("SELECT 1 FROM mutes WHERE chat_id=?", (T,)) is None, "Planer räumt abgelaufene Einträge weg")


# -- Teil 4: Ruhezeiten -----------------------------------------------------------------------------------
def part_quiet(w: dict) -> None:
    M, T = w["mila"], w["theo"]
    print("Ruhezeiten einstellen")
    q = http.get("/api/settings/quiet-hours", headers=OWNER).json()
    ok(q == {"enabled": False, "start": "22:00", "end": "07:00", "days": [1, 2, 3, 4, 5, 6, 7], "approvals": True,
             "timezone": "Europe/Berlin", "active": False}, "Standard: aus, 22–7 Uhr, alle Tage, Freigaben melden")
    for bad in ({"start": "25:00"}, {"end": "7"}, {"days": [0]}, {"days": "mo"}, {"enabled": "ja"}, {"timezone": "Mars/Olympus"},
                {"approvals": 1}):
        ok(http.patch("/api/settings/quiet-hours", headers=OWNER, json=bad).status_code == 400, f"ungültig {bad} → 400")
    ok(http.get("/api/settings/quiet-hours", headers=OWNER).json() == q, "ungültige Eingaben ändern nichts")
    # Ganztägig für heute (in der Zeitzone des Geräts), damit der Test zu jeder Uhrzeit läuft
    r = http.patch("/api/settings/quiet-hours", headers=OWNER,
                   json={"enabled": True, "start": "00:00", "end": "00:00", "timezone": "America/New_York", "unbekannt": 1})
    ok(r.status_code == 200 and r.json()["active"] is True and r.json()["timezone"] == "America/New_York"
       and "unbekannt" not in r.json(), "eingeschaltet (Teiländerung, unbekannte Felder fallen weg)")
    ok(http.get("/api/settings/quiet-hours", headers=LEA).json()["enabled"] is False, "Gäste haben ihre eigene Einstellung")

    print("In der Ruhezeit kommen Mitteilungen still an")
    n = len(alerts(T, TOK_OWNER))
    service._add(T, "bot", "Leise bitte")
    p = wait_for(lambda: len(alerts(T, TOK_OWNER)) > n and alerts(T, TOK_OWNER), msg="stille Mitteilung")[-1]
    ok(p["payload"]["aps"].get("interruption-level") == "passive" and "sound" not in p["payload"]["aps"]
       and p["priority"] == "5" and p["payload"]["aps"]["alert"]["body"] == "Leise bitte",
       "Inhaber: interruption-level passive, ohne Ton, Priorität 5")
    nl = len(alerts(M, TOK_LEA))
    service._add(M, "bot", "Für alle")
    g = wait_for(lambda: len(alerts(M, TOK_LEA)) > nl and alerts(M, TOK_LEA), msg="Gast-Mitteilung")[-1]
    ok(g["payload"]["aps"].get("sound") == "default" and "interruption-level" not in g["payload"]["aps"],
       "Gast ohne Ruhezeit: normale Mitteilung (Ruhezeit pro Person)")
    wait_for(lambda: alerts(M, TOK_OWNER) and alerts(M, TOK_OWNER)[-1]["payload"]["aps"]["alert"]["body"] == "Für alle",
             msg="Mitteilung an den Inhaber")
    ok(alerts(M, TOK_OWNER)[-1]["payload"]["aps"].get("interruption-level") == "passive", "derselbe Chat beim Inhaber still")

    print("Freigaben trotzdem melden (Standard an) und Erinnerungen")
    service._add(T, "approval", "", {"approval_id": "a_q1", "title": "Anruf", "state": "pending"})
    p = wait_for(lambda: [x for x in alerts(T, TOK_OWNER) if x["payload"].get("approval_id") == "a_q1"], msg="Freigabe")[-1]
    ok(p["payload"]["aps"].get("sound") == "default" and "interruption-level" not in p["payload"]["aps"],
       "Freigabe in der Ruhezeit → normal (Schalter an)")
    http.patch("/api/settings/quiet-hours", headers=OWNER, json={"approvals": False})
    service._add(T, "approval", "", {"approval_id": "a_q2", "title": "Anruf", "state": "pending"})
    p = wait_for(lambda: [x for x in alerts(T, TOK_OWNER) if x["payload"].get("approval_id") == "a_q2"], msg="Freigabe still")[-1]
    ok(p["payload"]["aps"].get("interruption-level") == "passive" and p["payload"]["aps"]["category"] == "SCOOP_APPROVAL",
       "Schalter aus → Freigabe kommt still an (mit Knöpfen)")
    rid = "rt_" + os.urandom(3).hex()
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,1,?,datetime('now'))", (rid, T, "erinnerung", "Flug", "2026-01-01T05:30:00+01:00", "",
                                                       "Zum Flughafen", "2026-01-01T05:30:00+01:00"))
    due = [r for r in service.due_routines() if r["id"] == rid]
    ok(len(due) == 1, "die Erinnerung ist in der Ruhezeit fällig (wird nicht verschoben)")
    service.fire_routine(due[0])
    p = wait_for(lambda: [x for x in alerts(T, TOK_OWNER) if x["payload"].get("reminder")], msg="Erinnerung")[-1]
    ok(p["payload"]["aps"].get("sound") == "default" and "interruption-level" not in p["payload"]["aps"],
       "Erinnerung auf eine Uhrzeit → meldet sich auch in der Ruhezeit mit Ton")
    ok(db.one("SELECT enabled FROM routines WHERE id=?", (rid,))["enabled"] == 0 and
       db.one("SELECT 1 FROM messages WHERE bot_id=? AND text LIKE '⏰%'", (T,)) is not None, "Erinnerung steht im Chat, nichts geht verloren")

    print("Ruhezeit eines Gasts")
    r = http.patch("/api/settings/quiet-hours", headers=MAX, json={"enabled": True, "start": "00:00", "end": "00:00",
                                                                    "timezone": "Asia/Tokyo"})
    ok(r.status_code == 200 and r.json()["active"] is True, "Gast (Lesen) stellt seine Ruhezeit ein")
    ok(http.patch("/api/settings/quiet-hours", headers=NONE, json={"enabled": True}).status_code == 403, "Konto ohne Share → 403")
    http.patch("/api/settings/quiet-hours", headers=OWNER, json={"enabled": False})
    nm, nl = len(alerts(M, TOK_MAX)), len(alerts(M, TOK_LEA))
    service._add(M, "bot", "Max schläft")
    wait_for(lambda: len(alerts(M, TOK_MAX)) > nm and len(alerts(M, TOK_LEA)) > nl, msg="Mitteilungen an Gäste")
    ok(alerts(M, TOK_MAX)[-1]["payload"]["aps"].get("interruption-level") == "passive"
       and alerts(M, TOK_LEA)[-1]["payload"]["aps"].get("sound") == "default"
       and "badge" not in alerts(M, TOK_MAX)[-1]["payload"]["aps"], "Max still, Lea normal; Gast-Mitteilungen ohne Badge")
    wait_for(lambda: alerts(M, TOK_OWNER)[-1]["payload"]["aps"]["alert"]["body"] == "Max schläft", msg="Inhaber")
    ok(alerts(M, TOK_OWNER)[-1]["payload"]["aps"].get("sound") == "default", "Inhaber (Ruhezeit aus) wieder normal")
    http.patch("/api/settings/quiet-hours", headers=MAX, json={"enabled": False})


# -- Teil 5: Initiative und Routinen ----------------------------------------------------------------------
def part_initiative(w: dict) -> None:
    print("Initiative des Haupt-Scoops in der Ruhezeit")
    T = w["theo"]
    db.set_primary(T)
    db.set_setting("initiative", json.dumps({"enabled": True, "times": ["07:30", "12:30"], "quiet_start": "22:00",
                                             "quiet_end": "07:00"}))
    db.set_setting("initiative_last", "")
    runs: list[tuple] = []
    original = server.run_initiative
    server.run_initiative = lambda bot_id, zeit, first: runs.append((bot_id, zeit, first))
    try:
        day = datetime(2026, 11, 18, tzinfo=BERLIN)  # Mittwoch
        http.patch("/api/settings/quiet-hours", headers=OWNER,
                   json={"enabled": True, "start": "22:00", "end": "08:00", "days": [1, 2, 3, 4, 5, 6, 7],
                         "timezone": "Europe/Berlin", "approvals": True})
        server.initiative_tick(day.replace(hour=7, minute=30))
        ok(runs == [] and json.loads(db.setting("initiative_deferred"))["first"] is True,
           "07:30 liegt in der Ruhezeit (bis 08:00) → kein Check, vorgemerkt")
        server.initiative_tick(day.replace(hour=7, minute=45))
        ok(runs == [], "07:45 → weiter still")
        server.initiative_tick(day.replace(hour=8, minute=0))
        ok(runs == [(T, "08:00", True)], "08:00, Ruhezeit vorbei → Check wird einmal nachgeholt (als erster des Tages)")
        server.initiative_tick(day.replace(hour=8, minute=1))
        ok(len(runs) == 1 and not db.setting("initiative_deferred"), "danach nichts mehr")
        server.initiative_tick(day.replace(hour=12, minute=30))
        ok(runs[-1] == (T, "12:30", False) and len(runs) == 2, "12:30 außerhalb der Ruhezeit → normaler Check")
        server.initiative_tick(day.replace(hour=12, minute=30, second=20))
        ok(len(runs) == 2, "dieselbe Minute → nicht doppelt")
        # Vorgemerkter Check verfällt nach 12 Stunden (z. B. Server war aus)
        db.set_setting("initiative_deferred", json.dumps({"at": (day - timedelta(days=1)).isoformat(), "first": True}))
        server.initiative_tick(day.replace(hour=13, minute=0))
        ok(len(runs) == 2 and not db.setting("initiative_deferred"), "alter vorgemerkter Check verfällt")
        http.patch("/api/settings/quiet-hours", headers=OWNER, json={"enabled": False})
        server.initiative_tick((day + timedelta(days=1)).replace(hour=7, minute=30))
        ok(runs[-1] == (T, "07:30", True) and len(runs) == 3, "ohne Ruhezeit läuft der Check um 07:30 wie bisher")
        server.initiative_tick((day + timedelta(days=1)).replace(hour=6, minute=0))
        ok(len(runs) == 3, "eigene Ruhezeit der Initiative (22–7 Uhr) gilt weiter")
    finally:
        server.run_initiative = original

    print("Pausierte Routine einschalten")
    M = w["mila"]
    rid = "rt_" + os.urandom(3).hex()
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,0,?,datetime('now'))", (rid, M, "routine", "Morgens", "0 7 * * *", "Täglich um 7:00", "x",
                                                       "2020-01-01T07:00:00+01:00"))
    r = http.patch(f"/api/routines/{rid}", headers=OWNER, json={"enabled": True}).json()
    ok(r["enabled"] is True and r["next_run"] > datetime.now(BERLIN).isoformat(timespec="seconds")
       and not [x for x in service.due_routines() if x["id"] == rid],
       "verstrichener Termin → nächster Termin laut Zeitplan statt sofortigem Lauf")


def main() -> None:
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeHandler)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    part_math()
    w = setup_world()
    part_mute(w)
    part_quiet(w)
    part_initiative(w)
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
