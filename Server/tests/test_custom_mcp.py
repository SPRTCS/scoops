"""Test für eigene MCP-Server (Server 1.35, custom_mcp.py, docs/mcp.md).

Lokaler Fake-MCP (tests/fake_mcp.py) ohne Anmeldung, mit Token und mit OAuth 2.1; Schlüsselbund im Speicher;
eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine) – niemals die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_custom_mcp.py
    (auch mit pytest: pytest tests/test_custom_mcp.py)
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-custom-mcp-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as _s:
    _s.bind(("127.0.0.1", 0))
    PORT = _s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
for k in ("AISBOT_HOME",):
    os.environ.pop(k, None)
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_EDITION="standard",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-mcptest-" + os.urandom(3).hex(),
                  ANTHROPIC_API_KEY="test-placeholder", OPENAI_API_KEY="test-placeholder")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import custom_mcp as cmod, server  # noqa: E402
from aisbot.bots import RunState  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402
from aisbot.sharing import ScopedMCP  # noqa: E402
from fake_mcp import STDIO_SCRIPT, TOKEN as FAKE_TOKEN, DictStore, FakeMCP  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service = server.db, server.service
cm = service.custom_mcp
cm.store_factory = DictStore  # Schlüsselbund im Speicher
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=30)
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=15.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


def fake_run(**kw):
    u = Usage(kw["model"])
    u.input_tokens = 10
    book = UsageBook()
    book.by_model[kw["model"]] = u
    return Outcome("Erledigt.", "end_turn", book, [], False, kw["model"], 1, [])


service.engine.run = fake_run
service.openai_engine.run = fake_run
FAKE: FakeMCP | None = None
BOT = ""


def setup() -> None:
    global FAKE, BOT
    if FAKE:
        return
    FAKE = FakeMCP().start()
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: _up(), msg="Server startet")
    r = http.post("/api/bots", headers=H, json={"name": "Mila", "mascot": MASCOT, "model": "claude-haiku-5-5"})
    BOT = r.json()["id"]
    wait_for(lambda: BOT not in service.runs, msg="Begrüßung fertig")


def _up() -> bool:
    try:
        return http.get("/api/health", headers=H).status_code == 200
    except httpx.HTTPError:
        return False


def servers() -> dict:
    return {s["id"]: s for s in http.get("/api/mcp-servers", headers=H).json()["servers"]}


def config_text() -> str:
    return (TMP / "config.json").read_text()


def idle() -> None:
    wait_for(lambda: BOT not in service.runs, msg="Lauf fertig")


def last(role: str) -> dict | None:
    r = db.one("SELECT * FROM messages WHERE bot_id=? AND role=? ORDER BY seq DESC LIMIT 1", (BOT, role))
    return db.msg_dict(r) if r else None


def chat_tools(guest=None) -> dict:
    gtools = service.guest_settings(BOT)["guest_tools"] if guest else None
    return {t.schema["name"]: t for t in service._tools(BOT, BOT, 0, RunState(), guest=guest, gtools=gtools)}


# -- Tests ------------------------------------------------------------------------------------------------------------
def test_detect_and_open() -> None:
    setup()
    print("Erkennen und Server ohne Anmeldung")
    ok(cm.probe(FAKE.url("open"))["auth"] == "none", "offener Server: keine Anmeldung")
    ok(cm.probe(FAKE.url("token"))["auth"] == "token", "401 ohne Metadaten: Token nötig")
    p = cm.probe(FAKE.url("oauth"))
    ok(p["auth"] == "oauth" and p["name"] == "Fake Bank MCP", "401 mit resource_metadata: OAuth, Name aus den Metadaten")
    r = http.post("/api/mcp-servers/probe", headers=H, json={"url": "ftp://x"})
    ok(r.status_code == 400, "ungültige Adresse → 400 mit Text")
    r = http.post("/api/mcp-servers", headers=H, json={"name": "Offen", "url": FAKE.url("open")})
    ok(r.status_code == 200 and r.json()["server"]["id"] == "mcp_offen" and r.json()["test"]["tools"] == 3,
       "hinzufügen: ID mit Präfix mcp_, 3 Werkzeuge geladen")
    st = servers()["mcp_offen"]
    ok(st["status"] == "ok" and st["tools"] == 3 and st["write_tools"] == 2, "Status ok, 2 schreibende Werkzeuge erkannt")
    names = {s["name"] for s in service.mcp_hub.tool_schemas()}
    ok({"mcp_offen__list_items", "mcp_offen__create_item", "mcp_offen__make_transfer"} <= names,
       "Werkzeuge im Hub, Name mit Punkt API-tauglich ersetzt")
    out = service.mcp_hub.call("mcp_offen__make_transfer", {"amount": 1})
    ok(FAKE.calls[-1][1] == "make.transfer" and "ausgeführt" in out[0]["text"], "ersetzter Name wird zurückgeführt")
    r = http.post("/api/mcp-servers", headers=H, json={"name": "Offen", "url": FAKE.url("open")})
    ok(r.json()["server"]["id"] == "mcp_offen_2", "gleicher Name → eindeutige ID")
    http.delete("/api/mcp-servers/mcp_offen_2", headers=H)
    conn = http.get("/api/connections", headers=H)
    ok(conn.status_code == 200 and conn.json().get("custom_mcp_supported") and conn.json()["custom_mcp"][0]["id"] == "mcp_offen",
       "GET /api/connections liefert die eigenen MCP-Server (auch ohne Composio)")


def test_token() -> None:
    setup()
    print("Server mit Token")
    r = http.post("/api/mcp-servers", headers=H, json={"name": "Werkzeug", "url": FAKE.url("token")})
    ok(r.status_code == 400 and "Token" in r.json()["error"], "Token nötig, aber keins angegeben → 400 mit Hinweis")
    r = http.post("/api/mcp-servers", headers=H, json={"name": "Werkzeug", "url": FAKE.url("token"), "token": FAKE_TOKEN})
    ok(r.status_code == 200 and r.json()["server"]["auth"] == "token" and r.json()["test"]["ok"], "mit Token verbunden")
    ok(FAKE_TOKEN not in config_text(), "Token steht nicht in config.json")
    ok(DictStore.data["mcp_werkzeug"]["token"] == FAKE_TOKEN, "Token im Schlüsselbund-Eintrag des Servers")
    ok(FAKE_TOKEN not in json.dumps(servers()), "API gibt das Token nie aus")
    r = http.post("/api/mcp-servers", headers=H, json={"name": "Header", "url": FAKE.url("token"), "auth": "token",
                                                       "header": "X-Api-Key", "token": FAKE_TOKEN})
    ok(r.json()["test"]["ok"], "eigener Header-Name (X-Api-Key)")
    r = http.patch("/api/mcp-servers/mcp_header", headers=H, json={"name": "Header neu"})
    ok(servers()["mcp_header"]["name"] == "Header neu", "umbenennen")
    r = http.delete("/api/mcp-servers/mcp_header", headers=H)
    ok("mcp_header" not in servers() and "mcp_header" not in DictStore.data and "mcp_header" not in service.mcp_hub.servers,
       "entfernen: Liste, Schlüsselbund und Hub aufgeräumt")


def test_oauth() -> None:
    setup()
    print("OAuth 2.1 (Discovery, Registrierung, PKCE, Refresh)")
    r = http.post("/api/mcp-servers", headers=H, json={"url": FAKE.url("oauth")})
    body = r.json()
    ok(r.status_code == 200 and body["server"]["auth"] == "oauth" and body["server"]["name"] == "Fake Bank", "OAuth erkannt")
    sid = body["server"]["id"]
    ok(servers()[sid]["status"] == "login", "vor der Anmeldung: Status „Anmeldung nötig“")
    url = body["oauth"]["url"]
    ok(url.startswith(FAKE.base + "/as/authorize?") and "code_challenge_method=S256" in url
       and "redirect_uri=aisscoops%3A%2F%2Foauth%2Fmcp" in url and "offline_access" in url, "Authorize-URL mit PKCE und Scopes")
    ok(len(FAKE.registrations) == 1 and FAKE.registrations[0]["token_endpoint_auth_method"] == "none",
       "einmalige Registrierung als öffentlicher Client")
    r = http.post("/api/connections/oauth/callback", headers=H, json={"url": FAKE.authorize(url)})
    ok(r.status_code == 200 and r.json()["tools"] == 3, "Rücksprung über den vorhandenen Endpunkt → 3 Werkzeuge")
    ok(servers()[sid]["status"] == "ok", "Status ok")
    ok(not any(k in config_text() for k in ("access_token", "refresh_token", "client-1")), "keine Tokens in config.json")
    r = http.post("/api/connections/oauth/callback", headers=H, json={"url": "aisscoops://oauth/mcp?code=x&state=y"})
    ok(r.status_code == 400, "unbekannter state → 400")
    # Refresh: Access-Token läuft ab → 401 → einmal erneuern und wiederholen
    old_rt = DictStore.data[sid]["refresh_token"]
    FAKE.expire_access()
    out = service.mcp_hub.call(f"{sid}__list_items", {})
    ok("Apfel" in out[0]["text"] and DictStore.data[sid]["refresh_token"] != old_rt, "401 → Refresh mit Rotation, Aufruf klappt")
    d = DictStore.data[sid]
    d["expires_at"] = time.time() + 60  # innerhalb der 5 Minuten vor Ablauf
    cm._cache.pop(sid, None)
    before = len(FAKE.token_calls)
    cm.access_token(sid)
    ok(len(FAKE.token_calls) == before + 1, "erneuert 5 Minuten vor Ablauf")
    # invalid_grant → abgelaufen, „Neu anmelden“
    FAKE.refresh.clear()
    FAKE.expire_access()
    try:
        cm.access_token(sid, force_refresh=True)
        ok(False, "invalid_grant muss scheitern")
    except cmod.McpAuthError:
        pass
    ok(servers()[sid]["status"] == "login", "invalid_grant → Status „Anmeldung nötig“")
    r = http.post(f"/api/mcp-servers/{sid}/login", headers=H)
    ok(r.status_code == 200 and len(FAKE.registrations) == 1, "neu anmelden ohne neue Registrierung")
    r = http.post("/api/connections/oauth/callback", headers=H, json={"url": FAKE.authorize(r.json()["url"])})
    ok(servers()[sid]["status"] == "ok", "nach neuer Anmeldung wieder ok")
    r = http.post("/api/connections/oauth/callback", headers=H, json={"url": "aisscoops://oauth/notion?code=x&state=y"})
    ok(r.status_code == 404, "Notion-Rücksprung geht weiter an Notion (offline: 404), nicht an eigene MCPs")
    rt = DictStore.data[sid]["refresh_token"]
    http.delete(f"/api/mcp-servers/{sid}", headers=H)
    ok(rt in FAKE.revoked and sid not in DictStore.data, "entfernen widerruft das Token und löscht den Eintrag")
    # Anbieter mit Allowlist (wie Qonto): App-Schema abgelehnt → Loopback-Redirect
    FAKE.loopback_only = True
    try:
        n = len(FAKE.registrations)
        r = http.post("/api/mcp-servers", headers=H, json={"name": "Allowlist", "url": FAKE.url("oauth")})
        o = r.json()["oauth"]
        ok(o.get("loopback_port") == cmod.LOOPBACK_PORT and o["redirect_uri"] == cmod.LOOPBACK_URI
           and "redirect_uri=http%3A%2F%2F127.0.0.1%3A47615%2Foauth%2Fmcp" in o["url"] and len(FAKE.registrations) == n + 1,
           "Schema abgelehnt → Registrierung mit Loopback, App bekommt den Port")
        cb = FAKE.authorize(o["url"])
        ok(cb.startswith("http://127.0.0.1:47615/oauth/mcp?"), "Rücksprung an Loopback")
        r = http.post("/api/connections/oauth/callback", headers=H, json={"url": cb})
        ok(r.status_code == 200 and r.json()["tools"] == 3, "Loopback-Rücksprung über denselben Endpunkt → verbunden")
        r = http.post("/api/mcp-servers/mcp_allowlist/login", headers=H)
        ok(r.json().get("loopback_port") and len(FAKE.registrations) == n + 1, "neu anmelden: gleiche Loopback-Registrierung")
        http.delete("/api/mcp-servers/mcp_allowlist", headers=H)
    finally:
        FAKE.loopback_only = False


def test_stdio() -> None:
    setup()
    print("Lokaler Befehl (stdio)")
    script = TMP / "fake_stdio.py"
    script.write_text(STDIO_SCRIPT)
    r = http.post("/api/mcp-servers", headers=H, json={"kind": "stdio", "name": "Lokal", "command": sys.executable,
                                                       "args": [str(script)], "env": {"FAKE_KEY": "lokal-geheim"}})
    ok(r.status_code == 200 and r.json()["test"]["tools"] == 1, "stdio-Server mit Umgebungsvariable verbunden")
    ok("lokal-geheim" not in config_text() and "FAKE_KEY" in config_text(), "Wert nur im Schlüsselbund, Name in config.json")
    out = service.mcp_hub.call("mcp_lokal__env_lesen", {})
    ok("gesetzt" in out[0]["text"], "Umgebungsvariable kommt im Prozess an")
    r = http.post("/api/mcp-servers", headers=H, json={"kind": "stdio", "command": "/gibt/es/nicht"})
    ok(r.status_code == 400, "unbekanntes Programm → 400")
    http.delete("/api/mcp-servers/mcp_lokal", headers=H)


def test_approvals_and_sharing() -> None:
    setup()
    print("Freigaben und Teilen")
    gate = service.mcp_gate(BOT, BOT)
    n = len(FAKE.calls)
    out = gate.call("mcp_offen__list_items", {})
    ok(len(FAKE.calls) == n + 1 and "Apfel" in out[0]["text"], "lesendes Werkzeug läuft ohne Nachfrage")
    out = gate.call("mcp_offen__create_item", {"title": "Test"})
    ok(len(FAKE.calls) == n + 1 and "Freigabe angefragt" in out, "schreibendes Werkzeug: nicht ausgeführt, Karte")
    card = last("approval")
    ok(card["meta"]["kind"] == "mcp" and card["meta"].get("can_always") and "Test" in card["meta"]["details"],
       "Karte mit Argumenten und „Immer erlauben“")
    r = http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "approve_always"})
    ok(r.status_code == 200, "Immer erlauben")
    wait_for(lambda: any(c[1] == "create_item" for c in FAKE.calls[n:]), msg="nach Freigabe ausgeführt")
    ev = wait_for(lambda: (lambda m: m if m and m["text"].startswith("Ausgeführt") else None)(last("event")), msg="Ereignis")
    ok("ausgeführt" in ev["meta"]["prompt"], "Ergebnis geht als Ereignis an den Scoop")
    idle()
    m = len(FAKE.calls)
    out = gate.call("mcp_offen__create_item", {"title": "Zweiter"})
    ok(len(FAKE.calls) == m + 1 and "ausgeführt" in out[0]["text"], "Dauerfreigabe: zweiter Aufruf läuft direkt")
    out = gate.call("mcp_offen__make_transfer", {"amount": 5})
    card = last("approval")
    ok(isinstance(out, str) and not card["meta"].get("can_always") and "unumkehrbar" in card["meta"]["details"],
       "Überweisung: Karte ohne „Immer erlauben“, Hinweis unumkehrbar")
    r = http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "decline"})
    idle()
    ok(not any(c[1] == "make.transfer" and c[2].get("amount") == 5 for c in FAKE.calls), "abgelehnt → nicht ausgeführt")
    from aisbot.engine_abo import hub_tools
    abo = hub_tools(service.mcp_gate(BOT, BOT), lambda _s: None)
    k = len(FAKE.calls)
    out = abo["mcp_offen__make_transfer"].handler({"amount": 7})
    ok(len(FAKE.calls) == k and "Freigabe angefragt" in out, "Abo-Weg (Claude Code/Codex): dieselbe Freigabe-Hülle")
    card = last("approval")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "decline"})
    idle()
    sh = http.get(f"/api/bots/{BOT}/sharing", headers=H).json()
    ok({"id": "mcp_offen", "name": "Offen"} in sh["options"]["mcp"], "Teilen: eigener MCP in der Gruppe „MCPs“")
    gtools = service.guest_settings(BOT)["guest_tools"]
    ok("mcp_offen" not in gtools["mcp"], "für Gäste standardmäßig aus")
    scoped = service.mcp_gate(BOT, BOT, {"user_id": "u_g", "name": "Gina", "role": "write"},
                              ScopedMCP(service.mcp_hub, gtools["mcp"], gtools["apps"]))
    ok(not any(s["name"].startswith("mcp_offen__") for s in scoped.tool_schemas()), "Gast-Lauf sieht keine eigenen MCPs")
    ok(not any(n.startswith("mcp_server_") for n in chat_tools({"user_id": "u_g", "name": "Gina", "role": "write"})),
       "Gäste haben keine Werkzeuge zum Verbinden")
    ok(http.get("/api/mcp-servers", headers={"Authorization": "Bearer gast"}).status_code in (401, 403),
       "API nur für den Inhaber")
    note = service.custom_mcp_note()
    ok(note and "Offen (`mcp_offen__…`)" in note, "Hinweis in der Systemanweisung")
    # Aufgaben: app_werkzeug_nutzen mit schreibendem Werkzeug → Karte statt Ausführung
    task_hub = service.tasks._hub_tools(type("R", (), {"task": {"chat_id": BOT, "bot_id": BOT, "id": "t_x"},
                                                       "progress": type("P", (), {"line": lambda self, s: None})()})())
    found = task_hub["app_werkzeug_suchen"].handler({"suche": "create item"})
    ok("mcp_offen__create_item" in found, "Aufgabe findet das Werkzeug über die Suche")
    k = len(FAKE.calls)
    for s in service.standing_approvals(BOT):
        service.delete_standing(BOT, s["id"])
    out = task_hub["app_werkzeug_nutzen"].handler({"name": "mcp_offen__create_item", "argumente_json": '{"title": "A"}'})
    ok(len(FAKE.calls) == k and "angefragt" in out and "Aufgabenmodus" in out, "Aufgabe: schreibend nur mit Karte")
    card = last("approval")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "decline"})
    idle()


def test_chat_tools() -> None:
    setup()
    print("Im Chat verbinden (Scoop-Werkzeuge)")
    t = chat_tools()
    ok({"mcp_server_pruefen", "mcp_server_verbinden", "mcp_server_liste", "mcp_server_entfernen",
        "mcp_server_token_setzen", "mcp_server_anmelden"} <= set(t), "Werkzeuge für den Inhaber vorhanden")
    out = t["mcp_server_pruefen"].handler({"url": FAKE.url("token")})
    ok("Anmeldung: token" in out and "NICHT im Chat" in out, "prüfen: Token nötig, Hinweis auf sichere Karte")
    out = t["mcp_server_verbinden"].handler({"name": "Kasse", "url": FAKE.url("token"), "anmeldung": "auto"})
    card = last("approval")
    ok("Freigabe angefragt" in out and card["meta"]["kind"] == "mcp_connect"
       and card["meta"]["secret_fields"][0]["key"] == "token" and not card["meta"].get("can_always"),
       "Karte mit sicherem Token-Feld, ohne „Immer erlauben“")
    aid = card["meta"]["approval_id"]
    r = http.post(f"/api/approvals/{aid}", headers=H, json={"decision": "approve"})
    ok(r.status_code == 400 and "Token" in r.json()["error"], "ohne Token nicht freigebbar")
    r = http.post(f"/api/approvals/{aid}", headers=H, json={"decision": "approve", "edits": {"secrets": {"token": FAKE_TOKEN}}})
    ok(r.status_code == 200, "Freigabe mit Token aus der Karte")
    wait_for(lambda: "mcp_kasse" in servers() and servers()["mcp_kasse"]["status"] == "ok", msg="Kasse verbunden")
    ev = wait_for(lambda: (lambda m: m if m and "Kasse" in m["text"] else None)(last("event")), msg="Ereignis")
    ok("3 Werkzeuge" in ev["text"] and "Schlüsselbund" in ev["meta"]["prompt"], "Scoop erfährt Werkzeuganzahl, nicht das Token")
    idle()
    dump = json.dumps([dict(r) for r in db.q("SELECT text, meta FROM messages")]) + json.dumps(
        [dict(r) for r in db.q("SELECT * FROM approvals")])
    ok(FAKE_TOKEN not in dump and FAKE_TOKEN not in config_text(), "Token weder im Chatverlauf noch in Freigaben/config")
    ok("Kasse" in t["mcp_server_liste"].handler({}), "Liste zeigt den Server")
    # OAuth über den Chat: Karte „Anmelden“, nach dem Rücksprung erfährt es der Scoop
    t["mcp_server_verbinden"].handler({"name": "Bank", "url": FAKE.url("oauth")})
    card = last("approval")
    ok(not card["meta"].get("secret_fields"), "OAuth: keine Token-Eingabe")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "approve"})
    login = wait_for(lambda: next((dict(r) for r in db.q("SELECT * FROM messages WHERE bot_id=? AND role='event'", (BOT,))
                                   if '"mcp_login"' in (r["meta"] or "")), None), msg="Anmelde-Karte")
    meta = json.loads(login["meta"])
    ok(meta["mcp_server_id"] == "mcp_bank" and "Apps verbinden" in login["text"], "Karte „Bei Bank anmelden“ im Chat")
    idle()
    r = http.post("/api/mcp-servers/mcp_bank/login", headers=H)
    http.post("/api/connections/oauth/callback", headers=H, json={"url": FAKE.authorize(r.json()["url"])})
    ev = wait_for(lambda: (lambda m: m if m and m["text"].startswith("Bei Bank angemeldet") else None)(last("event")),
                  msg="angemeldet")
    ok("3 Werkzeuge" in ev["text"] and "list_items" in ev["meta"]["prompt"], "Scoop erfährt die Anmeldung, lesendes Werkzeug genannt")
    idle()
    # Token neu setzen und entfernen
    t["mcp_server_token_setzen"].handler({"server": "Kasse"})
    card = last("approval")
    ok(card["meta"]["kind"] == "mcp_secret" and not card["meta"].get("can_always"), "Token-Karte für vorhandenen Server")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "decline"})
    idle()
    t["mcp_server_entfernen"].handler({"server": "mcp_bank"})
    card = last("approval")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H, json={"decision": "approve"})
    wait_for(lambda: "mcp_bank" not in servers(), msg="entfernt")
    ok("mcp_bank" not in DictStore.data, "über den Chat entfernt (mit Freigabe), Schlüsselbund aufgeräumt")
    idle()
    # stdio über den Chat: Werte der Umgebungsvariablen nur in der Karte
    t["mcp_server_verbinden"].handler({"name": "Skript", "befehl": sys.executable, "argumente": str(TMP / "fake_stdio.py"),
                                       "umgebungsvariablen": "FAKE_KEY"})
    card = last("approval")
    ok(card["meta"]["secret_fields"] == [{"key": "env:FAKE_KEY", "label": "FAKE_KEY"}] and not card["meta"].get("can_always"),
       "lokaler Befehl: immer Karte, Wert sicher eintragen, kein „Immer erlauben“")
    http.post(f"/api/approvals/{card['meta']['approval_id']}", headers=H,
              json={"decision": "approve", "edits": {"secrets": {"env:FAKE_KEY": "x1"}}})
    wait_for(lambda: servers().get("mcp_skript", {}).get("status") == "ok", msg="stdio verbunden")
    ok("x1" not in config_text(), "Wert nicht in config.json")
    idle()


def run_all() -> None:
    test_detect_and_open()
    test_token()
    test_oauth()
    test_stdio()
    test_approvals_and_sharing()
    test_chat_tools()


if __name__ == "__main__":
    run_all()
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
