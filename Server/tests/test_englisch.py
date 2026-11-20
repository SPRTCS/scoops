"""Englisch für Inhaber und Gäste (docs/sprache.md): Sprache pro Person speichern, `Accept-Language` als Rückfall,
und eine englische Person bekommt vom Server keine deutschen Texte: Fehlermeldungen, Statuszeilen, Ereignisse,
Freigabe-Karten, Mitteilungen, Board, Heute, Suche, Vorlagen, Ruhezeiten, Bilder, Modelle, Start-Scoop. Dazu: Die
Sprachvorgabe kommt in allen Wegen im Prompt an (API-Engine, OpenAI, Claude Code, Codex, Aufgaben), Gäste bekommen ihre
eigene Sprache, und Deutsch bleibt danach unverändert.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, Edition standard) – niemals
die laufende Produktion. Convex und das Push-Relay spielt ein Fake, Läufe eine Fake-Engine, Aufgaben ein Fake-Agent.

    cd Server && uv run python tests/test_englisch.py
"""

from __future__ import annotations

import base64
import json
import os
import re
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace as NS

TMP = Path(tempfile.mkdtemp(prefix="aisbot-englisch-test-"))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, FAKE_PORT = free_port(), free_port()
FAKE = f"http://127.0.0.1:{FAKE_PORT}"
PREFIX = "ais-scoops-englischtest-" + os.urandom(3).hex()
API_TOKEN = "test-token-" + os.urandom(6).hex()
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX=PREFIX, AISBOT_CLOUD_KEYCHAIN=PREFIX + "-cloud", AISBOT_NO_TERMINAL="1",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_WORKSPACE=str(TMP / "Scoops"))
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import padding, rsa  # noqa: E402

from aisbot import cloud as cloud_mod, i18n, profile, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402
from aisbot.config import Usage  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402
from aisbot.prompts import language_note  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert cloud_mod.KEYCHAIN_SERVICE.startswith(PREFIX), "Test darf nie den echten Kopplungs-Eintrag benutzen"
assert profile.kc("apns").startswith(PREFIX), "Test darf nie Armans APNs-Schlüssel lesen"
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
db, service, tasks = server.db, server.service, server.tasks
passed = 0
TOK_OWNER, TOK_LEA, TOK_MAX = "a" * 64, "b" * 64, "c" * 64
EN = {"Accept-Language": "en-US,en;q=0.9"}

# Typische deutsche Wörter und Zeichen in Texten, die der Server selbst erzeugt. Eingaben des Fake-Modells sind englisch,
# ein Treffer kommt also vom Server.
GERMAN = re.compile(
    r"[äöüÄÖÜß]|\b(und|nicht|der|die|das|den|dem|ist|wird|wurde|mit|für|bitte|noch|kein|keine|nur|oder|schon|"
    r"Aufgabe|Freigabe|Erinnerung|Routine angelegt|Ruhezeit|Vorlage|Datei|Fehler|gefunden|fertig|angelegt|gestartet|"
    r"gespeichert|abgelehnt|freigegeben|Werktags|Stündlich|täglich|Uhr|Schaut|Liest|Sucht|Schreibt|Merkt|Setzt|Arbeitet|"
    r"Bittet|Gast|Rolle|Sprache)\b")


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def english(text, what: str) -> None:
    hit = GERMAN.search(str(text or ""))
    ok(not hit, f"{what} englisch" + (f" – Treffer „{hit.group(0)}“ in {str(text)[:160]!r}" if hit else ""))


def wait_for(fn, timeout=10.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


# -- JWTs, Fake-Convex und Push-Relay (wie test_ruhe.py) ------------------------------------------------------------
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
                                    "ownerName": "Sam", "revokedSessions": [], "sharesVersion": 1})
        if self.path == "/shares/sync":
            return self._send(200, {"ok": True, "sharesVersion": 1, "shares": Fake.shares})
        if self.path in ("/push/status", "/push/register"):
            return self._send(200, {"ok": True, "configured": True, "registered": len(body.get("tokens") or []),
                                    "rejected": []})
        if self.path == "/push/send":
            with Fake.lock:
                Fake.pushes += body.get("pushes") or []
            return self._send(200, {"ok": True, "results": [{"token": p["token"], "status": 200} for p in body["pushes"]]})
        self._send(404, {"code": "not_found"})


def alerts(token: str) -> list[dict]:
    with Fake.lock:
        return [p for p in Fake.pushes if p["token"] == token and p["pushType"] == "alert" and "alert" in p["payload"]["aps"]]


# -- Fake-Modell und Fake-Agent ---------------------------------------------------------------------------------------
class FakeEngine:
    """Ruft die Werkzeuge aus `todo` mit ihrer echten Statuszeile auf (wie die Engine) und antwortet englisch."""
    calls: list[dict] = []
    todo: list[tuple[str, dict]] = []

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        tools = {t.schema["name"]: t for t in kw.get("extra_tools") or []}
        for name, args in cls.todo:
            t = tools[name]
            if kw.get("on_line") and t.status:
                kw["on_line"](t.status(args))
            t.handler(args)
        cls.todo = []
        u = Usage(kw["model"])
        u.input_tokens = 10
        return Outcome("Done, see above.", "end_turn", NS(by_model={kw["model"]: u}, dollars=0.001), [], False,
                       kw["model"], 1)


def system_text(kw: dict) -> str:
    s = kw.get("system")
    return s if isinstance(s, str) else "\n".join(b.get("text", "") for b in s or [])


class FakeAgent:
    """Statt Claude Agent SDK/Codex: Arbeitsschritte mit den echten Statuszeilen der Aufgaben, eine Ergebnisdatei."""

    @staticmethod
    def run(run, message):
        from aisbot.tasks import tool_line
        for name, inp in (("Read", {"file_path": "/tmp/notes.md"}), ("WebSearch", {"query": "pumpkin"}),
                          ("Bash", {"command": "ls"}), ("TodoWrite", {})):
            run.progress.line(tool_line(name, inp, {}))
        u = Usage(run.task["model"])
        u.input_tokens = 1000
        run.usage = {run.task["model"]: u}
        (Path(run.task["workdir"]) / "ergebnis" / f"Report-{run.task['id']}.md").write_text("# Report\n")
        return "Finished. Report in ergebnis/.", "end"


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run
REAL_RUN_CLAUDE = tasks._run_claude
tasks._run_claude = FakeAgent.run
tasks._run_openai = FakeAgent.run


def H(tok: str, **extra) -> dict:
    return {"Authorization": f"Bearer {tok}", **extra}


OWNER = H(API_TOKEN)
LEA, MAX = H(mint("u_lea")), H(mint("u_max"))


def share(sid, bot, uid, name, role):
    return {"shareId": sid, "botId": bot, "granteeId": uid, "granteeName": name, "role": role, "computer": "none",
            "createdAt": 1, "updatedAt": 1}


def msgs(chat: str) -> list[dict]:
    return http.get(f"/api/bots/{chat}/messages", headers=OWNER, params={"limit": 200}).json()


def run_chat(chat: str, text: str, todo: list[tuple[str, dict]], headers=OWNER) -> list[dict]:
    """Nachricht schicken, Fake-Lauf abwarten, neue Nachrichten zurückgeben."""
    before = {m["id"] for m in msgs(chat)}
    FakeEngine.todo = todo
    r = http.post(f"/api/bots/{chat}/messages", headers=headers, json={"text": text})
    assert r.status_code == 200, r.text
    wait_for(lambda: any(m["role"] == "bot" and m["id"] not in before for m in msgs(chat)) and not service.runs,
             msg="Antwort des Scoops")
    return [m for m in msgs(chat) if m["id"] not in before]


# -- Teil 1: Sprache wählen und speichern ---------------------------------------------------------------------------
def setup_world() -> dict:
    cfg = load_config()
    cfg.update(api_token=API_TOKEN, cloud_url=FAKE, owner_id=OWNER_ID, cloud_server_id="srv_1", owner_name="Sam",
               user_name="Sam", server_name="Test-Mac")
    save_config(cfg)
    server.TOKEN = API_TOKEN
    cloud_mod.set_secret(SECRET)
    server.pusher.reset_mode()
    mila = service.create_bot({"name": "Mila", "label": "Home"})["id"]
    theo = service.create_bot({"name": "Theo"})["id"]
    wait_for(lambda: not service.runs, 10, "Vorstellungs-Läufe fertig")
    Fake.shares = [share("sh_lea", mila, "u_lea", "Lea", "write"), share("sh_max", mila, "u_max", "Max", "write")]
    ok(http.post("/api/shares/refresh", headers=OWNER).json()["shares"] == 2, "zwei Gäste auf Mila")
    ok(http.post("/api/devices", headers=OWNER, json={"apns_token": TOK_OWNER, "platform": "ios"}).status_code == 200,
       "Gerät des Inhabers gemeldet")
    for h, tok in ((LEA, TOK_LEA), (MAX, TOK_MAX)):
        http.post("/api/shared/devices", headers=h, json={"apns_token": tok, "platform": "ios"})
    wait_for(lambda: server.pusher.mode() == "relay", msg="Relay bereit")
    return {"mila": mila, "theo": theo}


def part_settings(w: dict) -> None:
    print("Sprache pro Person, Kopfzeile, Fähigkeiten")
    r = http.get("/api/settings/language", headers=OWNER).json()
    ok(r == {"language": "de", "stored": None, "available": ["de", "en"], "default": "de"}, f"Inhaber ohne Einstellung: {r}")
    ok(http.get("/api/settings/language", headers={**OWNER, **EN}).json()["language"] == "en",
       "ohne Einstellung gilt Accept-Language für die Antwort")
    h = http.get("/api/health", headers=OWNER).json()
    ok(h["languages"] == ["de", "en"] and h["language"] == "de", "Health meldet languages und die wirksame Sprache")
    ok(http.get("/api/bots/b_nope", headers=OWNER).json()["error"] == "Bot nicht gefunden", "ohne Kopfzeile: Deutsch wie bisher")
    english(http.get("/api/bots/b_nope", headers={**OWNER, **EN}).json()["error"], "404 nach Accept-Language")
    ok(http.get("/api/bots/b_nope", headers={**OWNER, "Accept-Language": "fr-FR, en;q=0.5"}).json()["error"]
       == "Scoop not found", "Accept-Language: erste unterstützte Sprache nach q-Wert")
    ok(http.get("/api/bots/b_nope", headers=OWNER, params={"lang": "en"}).json()["error"] == "Scoop not found",
       "Parameter lang geht vor")
    bad = http.patch("/api/settings/language", headers=OWNER, json={"language": "fr"})
    ok(bad.status_code == 400 and bad.json()["error"].startswith("Unbekannte Sprache"), "unbekannte Sprache → 400 (Deutsch)")
    ok(http.patch("/api/settings/language", headers=OWNER, json={}).status_code == 400, "ohne language → 400")
    # Gäste getrennt vom Inhaber
    r = http.patch("/api/settings/language", headers=LEA, json={"language": "en-GB"})
    ok(r.status_code == 200 and r.json()["stored"] == "en" and r.json()["language"] == "en", "Gast Lea speichert Englisch")
    ok(http.get("/api/settings/language", headers=OWNER).json()["stored"] is None, "Inhaber bleibt unberührt")
    ok(http.get("/api/settings/language", headers=MAX).json()["stored"] is None, "anderer Gast bleibt unberührt")
    me = http.get("/api/shared/me", headers=LEA).json()
    ok(me["languages"] == ["de", "en"] and me["language"] == "en", "/api/shared/me meldet Sprachen für Gäste")
    english(http.get(f"/api/bots/{w['theo']}", headers=LEA).json()["error"], "Gast Lea: 403 für fremden Scoop")
    ok("nicht" in http.get(f"/api/bots/{w['theo']}", headers=MAX).json()["error"], "Gast Max ohne Einstellung: Deutsch")
    english(http.patch("/api/settings/quiet-hours", headers=LEA, json={"start": "25:00"}).json()["error"],
            "Gast Lea: Ruhezeiten-Fehler")
    # Einrichtung (Mac-App): Kopfzeile bzw. Parameter
    ok("host:" in http.patch("/api/setup/config", json={"host": "1.2.3.4"}).json()["error"], "Einrichtung ohne Kopfzeile")
    english(http.patch("/api/setup/config", headers=EN, json={"host": "1.2.3.4"}).json()["error"],
            "Einrichtung mit Accept-Language")
    english(http.patch("/api/setup/config", params={"lang": "en"}, json={"host": "1.2.3.4"}).json()["error"],
            "Einrichtung mit ?lang=en")
    st = http.get("/api/setup").json()["server"]
    ok(st["language"] is None and st["languages"] == ["de", "en"], "GET /api/setup meldet Sprache des Inhabers")


def part_seed(w: dict) -> None:
    print("Start-Scoop folgt der Sprache des Inhabers")
    pip = db.setting("seed_bot")
    first = msgs(pip)
    ok(len(first) == 1 and first[0]["text"].startswith("Hallo! Ich bin **Pip**") and first[0]["meta"].get("welcome") is True,
       "Begrüßung deutsch mit meta.welcome")
    r = http.patch("/api/setup/config", json={"language": "en"})
    ok(r.status_code == 200 and r.json()["server"]["language"] == "en", "Einrichtung setzt Englisch für den Inhaber")
    m = msgs(pip)
    ok(len(m) == 1 and m[0]["text"].startswith("Hi! I'm **Pip**") and m[0]["meta"].get("welcome") is True,
       "Begrüßung jetzt englisch, meta.welcome bleibt")
    b = http.get(f"/api/bots/{pip}", headers=OWNER).json()
    ok(b["label"] == "Start", "Label „Start“ bleibt (Einführung der App erkennt es)")
    english(b["character"], "Charakter des Start-Scoops")
    english(m[0]["text"].replace("Pip", ""), "Begrüßung")


def part_chat(w: dict) -> None:
    print("Chat auf Englisch: Prompt, Statuszeilen, Ereignisse, Karte, Mitteilung")
    M = w["theo"]
    when = (datetime.now().astimezone() + timedelta(days=2)).replace(hour=9, minute=30, second=0, microsecond=0)
    new = run_chat(M, "Please remember and plan [en]", [
        ("merken", {"text": "Sam drinks no coffee", "fuer_alle_bots": False}),
        ("routine_anlegen", {"titel": "Morning briefing", "cron": "30 7 * * 1-5", "zeitplan_text": "Weekdays at 7:30",
                             "auftrag": "Brief Sam", "modell": "wie_scoop"}),
        ("erinnerung_setzen", {"zeitpunkt": when.isoformat(), "text": "Dentist"}),
        ("datei_speichern", {"name": "Notes.md", "inhalt": "# Notes\n"}),
        ("freigabe_anfordern", {"titel": "Post the photo", "details": "Post it on X", "art": "", "art_bezeichnung": ""}),
    ])
    sysp = system_text(FakeEngine.calls[-1])
    ok(language_note("en", "Sam") in sysp, "Sprachvorgabe für Englisch im Systemprompt (API-Weg)")
    status = next(m for m in new if m["role"] == "status")
    ok(len(status["meta"]["lines"]) == 5, "fünf Statuszeilen")
    for line in status["meta"]["lines"]:
        english(line, f"Statuszeile „{line}“")
    for m in new:
        if m["role"] == "event":
            english(m["text"].replace("Morning briefing", "").replace("Dentist", "").replace("Notes.md", ""),
                    f"Ereignis „{m['text']}“")
    card = next(m for m in new if m["role"] == "approval")
    english(card["text"], "Text der Freigabe-Karte")
    wait_for(lambda: any("Post the photo" in p["payload"]["aps"]["alert"]["body"] for p in alerts(TOK_OWNER)),
             msg="Mitteilung zur Freigabe")
    push = next(p for p in alerts(TOK_OWNER) if "Post the photo" in p["payload"]["aps"]["alert"]["body"])
    english(push["payload"]["aps"]["alert"]["body"].replace("Post the photo", ""), "Mitteilung „Asks for approval“")
    before = {m["id"] for m in msgs(M)}
    r = http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=OWNER, json={"decision": "decline"})
    ok(r.status_code == 200, "Freigabe abgelehnt")
    wait_for(lambda: not service.runs, msg="Fortsetzung fertig")
    for m in msgs(M):
        if m["id"] not in before and m["role"] == "event":
            english(m["text"].replace("Post the photo", ""), f"Ereignis nach der Entscheidung „{m['text']}“")
    english(http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=OWNER,
                      json={"decision": "approve"}).json().get("error"), "Fehler bei schon entschiedener Karte")
    rt = http.get(f"/api/bots/{M}/routines", headers=OWNER).json()
    reminder = next(r for r in rt if r["kind"] == "erinnerung")
    english(reminder["schedule_text"], f"Zeitplan der Erinnerung „{reminder['schedule_text']}“")
    # Heute: geplante Routinen und Erinnerungen, laufende Zeilen
    today = http.get("/api/today", headers=OWNER).json()
    for key in ("planned", "routines_done", "running"):
        for item in today.get(key) or []:
            english(item.get("schedule_text") or item.get("line") or "", f"Heute/{key}")
    # Suche findet die englischen Ereignisse
    hits = http.get("/api/search", headers=OWNER, params={"q": "Routine created"}).json()["hits"]
    ok(any(h["role"] == "event" for h in hits), "Suche findet englische Ereigniszeile")


def part_tasks(w: dict) -> None:
    print("Aufgaben und Board auf Englisch, Sprachvorgabe in den Aufgaben-Prompts")
    T = w["theo"]
    t = http.post("/api/tasks", headers=OWNER, json={"chat_id": T, "prompt": "Write a report", "title": "Report"}).json()
    wait_for(lambda: tasks.row(t["id"])["state"] == "done", msg="Aufgabe fertig")
    t = http.get(f"/api/tasks/{t['id']}", headers=OWNER).json()
    for line in t.get("lines") or []:
        english(line.replace("notes.md", ""), f"Aufgabenzeile „{line}“")
    ev = wait_for(lambda: next((m for m in msgs(T) if m["role"] == "event" and (m["meta"] or {}).get("task_id") == t["id"]
                                and m["text"].startswith(("Task done", "Aufgabe fertig"))), None), msg="Ereignis")
    ok(ev["text"].startswith("Task done: Report"), f"Ereignis „{ev['text']}“")
    board = http.get("/api/tasks", headers=OWNER, params={"limit": 50}).json()
    for x in board:
        english(x.get("error") or "", "Board: Fehlertext")
        english(x.get("waiting_for") or "", "Board: wartet auf")
    http.post(f"/api/tasks/{t['id']}/accept", headers=OWNER)
    err = http.post(f"/api/tasks/{t['id']}/start", headers=OWNER)
    ok(err.status_code >= 400, "fertige Aufgabe starten → Fehler")
    english(err.json()["error"], "TaskError")
    english(http.get("/api/tasks/t_nope", headers=OWNER).json()["error"], "Aufgabe nicht gefunden")
    english(http.post("/api/tasks", headers=OWNER, json={"chat_id": T}).json()["error"], "Aufgabe ohne Auftrag")
    # Prompts: Aufgaben-Systemanweisung (Claude-Preset, Codex, Responses-Schleife nutzen dieselbe), Claude Agent SDK
    row = tasks.row(t["id"])
    sysp = tasks._system(row, "x")
    ok(language_note("en", "Sam") in sysp and "Dateinamen auf Englisch" in sysp, "Aufgaben-Prompt mit Sprachvorgabe")
    captured = {}

    class Stop(Exception):
        pass

    class FakeSDK:
        def __init__(self, options):
            captured["opts"] = options
            raise Stop()

    import claude_agent_sdk
    from aisbot import tasks as tasks_mod
    real = claude_agent_sdk.ClaudeSDKClient
    claude_agent_sdk.ClaudeSDKClient = FakeSDK
    try:
        run = tasks_mod.Run(row, tasks_mod.Progress(service, row), "tok")
        run.billing = "abo"  # wie test_abos.py: Abo-Weg braucht keinen API-Schlüssel
        try:
            REAL_RUN_CLAUDE(run, "x")
        except Stop:
            pass
    finally:
        claude_agent_sdk.ClaudeSDKClient = real
    ok(language_note("en", "Sam") in captured["opts"].system_prompt["append"], "Claude Agent SDK (Aufgabe): Vorgabe im append")


def part_engines() -> None:
    print("Sprachvorgabe in allen Engines (API, OpenAI, Claude Code, Codex)")
    import fake_codex_cu as fc
    from aisbot import abos, engine_abo
    import aisbot.engine_openai as eo
    from aisbot.engine import ComputerHub, Engine
    note = language_note("en", "Sam")
    system = [{"type": "text", "text": "Du bist Pip."}, {"type": "text", "text": note}]
    hub = ComputerHub("http://127.0.0.1:9")
    got = {}

    class Msgs:
        def create(self, **kw):
            got["api"] = kw["system"]
            return NS(usage=NS(input_tokens=1, output_tokens=1, cache_read_input_tokens=0, cache_creation_input_tokens=0,
                               server_tool_use=None), stop_reason="end_turn", content=[NS(type="text", text="Hi")])
    eng = Engine(hub, client=NS(beta=NS(messages=Msgs())))
    eng.run(system=system, messages=[{"role": "user", "content": "hi"}], model="claude-haiku-5-5", budget=1, hub=hub)
    ok(note in [b["text"] for b in got["api"]], "API-Engine")
    oe = eo.OpenAIEngine(eng)

    def post(key, body, cancel):
        got["openai"] = body["instructions"]
        return NS(status_code=200, json=lambda: {"usage": {}, "output": [
            {"type": "message", "content": [{"type": "output_text", "text": "Hi"}]}]})
    oe._post = post
    real_key = eo._key
    eo._key = lambda: "sk-test"
    try:
        oe.run(system=system, messages=[{"role": "user", "content": "hi"}], model="gpt-6-luna", budget=1, hub=hub,
               allow_computer=False)
    finally:
        eo._key = real_key
    ok(note in got["openai"], "OpenAI-Engine")
    abos.set_status_for_tests("claude", {"installed": True, "logged_in": True, "subscription": True})
    cc = engine_abo.ClaudeCodeEngine(eng, cwd=None)

    async def run_async(**kw):
        got["claude"] = kw["sys_text"]
        return "Hi", "end_turn", "sid", "claude-haiku-5-5"
    cc._run_async = run_async
    cc._reaper = object()
    cc.run(system=system, messages=[{"role": "user", "content": "hi"}], model="claude-haiku-5-5", hub=hub, allow_computer=False)
    ok(note in got["claude"], "Claude Code (Abo)")
    restore = fc.install()
    try:
        abos.set_status_for_tests("openai", {"installed": True, "logged_in": True, "subscription": True, "method": "chatgpt"})
        fc.FakeCodex.script = lambda client, items: iter(fc.done("Hi"))
        cx = engine_abo.CodexChatEngine(eng)
        cx._reaper = object()
        cx.run(system=system, messages=[{"role": "user", "content": "hi"}], model="gpt-6-luna", hub=hub, allow_computer=False)
        ok(note in fc.FakeCodex.instances[-1].plain[-1][1]["base_instructions"], "Codex (Abo)")
    finally:
        restore()


def part_misc(w: dict) -> None:
    print("Vorlagen, Ruhezeiten, Bilder, Modelle, Verbindungen, Stummschalten")
    T = w["theo"]
    exp = http.get(f"/api/bots/{T}/template", headers=OWNER).json()
    tpl = exp.get("template") or exp
    english(json.dumps({k: v for k, v in exp.items() if k != "template"}, ensure_ascii=False), "Vorlage: Export-Hinweise")
    chk = http.post("/api/templates/check", headers=OWNER, json={"format": 1, "kind": "scoop"})
    ok(chk.status_code == 400, "kaputte Vorlage → 400")
    english(chk.json()["error"], "Vorlagen-Prüfung")
    good = {**tpl, "routines": [{"title": "Briefing", "schedule": "30 7 * * 1-5", "prompt": "Brief me"}]}
    out = http.post("/api/templates/check", headers=OWNER, json={"template": good})
    ok(out.status_code == 200, "gültige Vorlage geprüft" + ("" if out.status_code == 200 else f" {out.text[:200]}"))
    st = out.json()["template"]["routines"][0]["schedule_text"]
    ok(st and not GERMAN.search(st), f"Vorlage: Zeitplan englisch „{st}“")
    for n in out.json()["notes"]:
        english(n, "Vorlage: Hinweis zur Vorschau")
    english(http.patch("/api/settings/quiet-hours", headers=OWNER, json={"days": [9]}).json()["error"], "Ruhezeiten-Fehler")
    english(http.put(f"/api/chats/{T}/mute", headers=OWNER, json={"minutes": -1}).json()["error"], "Stummschalten-Fehler")
    img = http.get("/api/health", headers=OWNER).json()["images"]
    english(img.get("hint") or "", "Bilder: Hinweis in /api/health")
    from aisbot import bilder
    with i18n.use("en"):  # Bildläufe selbst brauchen ein ChatGPT-Abo; Texte der Ereignisse und Fehler direkt prüfen
        english(bilder.failure_text("usageLimitExceeded", time.time() + 3600), "Bilder: Limit-Text")
        english(bilder.failure_text("serverError", None).replace("serverError", ""), "Bilder: Fehlertext")
    for m in http.get("/api/models", headers=OWNER).json().get("models", []):
        english(m.get("hint") or "", f"Modell-Hinweis {m.get('id')}")
    cats = http.get("/api/connections/categories", headers=OWNER)
    if cats.status_code == 200:
        names = [c["name"] for c in (cats.json() if isinstance(cats.json(), list) else cats.json().get("categories", []))]
        ok("Popular" in names, "Verbindungen: Kategorie „Popular“")


def part_guests(w: dict) -> None:
    print("Gäste: eigene Sprache im Prompt und für Texte an sie, Chat bleibt in der Sprache des Inhabers")
    M = w["mila"]
    http.patch("/api/settings/language", headers=OWNER, json={"language": "de"})
    run_chat(M, "Hi Mila, how are you?", [], headers=LEA)
    s = system_text(FakeEngine.calls[-1])
    ok(language_note("en", "Lea") in s, "Gast-Lauf (Lea, Englisch): Sprachvorgabe mit ihrem Namen")
    run_chat(M, "Hallo Mila", [], headers=MAX)
    ok("Language:" not in system_text(FakeEngine.calls[-1]), "Gast-Lauf (Max, Deutsch): keine Vorgabe")
    run_chat(M, "Hallo", [], headers=OWNER)
    ok("Language:" not in system_text(FakeEngine.calls[-1]), "Lauf des Inhabers (Deutsch): Prompt wie bisher")
    # Tageslimit: Text ist für den Gast (seine Sprache), auch wenn der Inhaber Deutsch spricht
    service.set_guest_settings(M, {"guest_budget": 0})
    before = {m["id"] for m in msgs(M)}
    http.post(f"/api/bots/{M}/messages", headers=LEA, json={"text": "One more?"})
    lim = wait_for(lambda: next((m for m in msgs(M) if m["id"] not in before and (m["meta"] or {}).get("guest_limit")), None),
                   msg="Tageslimit-Nachricht")
    english(lim["text"].replace("$", ""), "Tageslimit an Gast Lea")
    service.set_guest_settings(M, {"guest_budget": 2})


def part_back_to_german(w: dict) -> None:
    print("Zurück auf Deutsch: alles wie vorher")
    r = http.patch("/api/settings/language", headers=OWNER, json={"language": None}).json()
    ok(r["stored"] is None and r["language"] == "de", "Inhaber zurück auf Deutsch")
    ok(http.get("/api/bots/b_nope", headers=OWNER).json()["error"] == "Bot nicht gefunden", "Fehler wieder deutsch")
    new = run_chat(w["theo"], "Merk dir das", [("merken", {"text": "x", "fuer_alle_bots": False})])
    st = next(m for m in new if m["role"] == "status")
    ok(st["meta"]["lines"] == ["Merkt sich etwas"], "Statuszeile wieder deutsch")
    ok("Language:" not in system_text(FakeEngine.calls[-1]), "Prompt ohne Sprachvorgabe")
    pip = db.setting("seed_bot")
    ok(msgs(pip)[0]["text"].startswith("Hallo! Ich bin **Pip**"), "Start-Scoop wieder deutsch (noch unbenutzt)")
    ok(i18n.tx("Bot nicht gefunden") == "Bot nicht gefunden", "Hintergrund ohne Einstellung: Deutsch")


def main() -> None:
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeHandler)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")
    w = setup_world()
    part_settings(w)
    part_seed(w)
    part_chat(w)
    part_tasks(w)
    part_engines()
    part_misc(w)
    part_guests(w)
    part_back_to_german(w)
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
