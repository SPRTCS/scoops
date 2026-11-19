"""Test für den Demo-Modus und das Ausgabenlimit (docs/demo-server.md).

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, Edition standard) –
niemals die laufende Produktion. Läufe nutzen eine Fake-Engine (kein KI-Aufruf).

    cd Server && uv run python tests/test_demo.py
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
from types import SimpleNamespace

TMP = Path(tempfile.mkdtemp(prefix="aisbot-demo-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
TOKEN = "demo-test-" + os.urandom(6).hex()
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "demo": True, "user_name": "Reviewer",
                                             "spend_limits": {"daily_usd": 5, "monthly_usd": 20}}))
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-demotest-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import abos, demo, server  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
http = httpx.Client(base_url=f"http://127.0.0.1:{PORT}", timeout=20, headers={"Authorization": f"Bearer {TOKEN}"})
service = server.service
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
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


class FakeEngine:
    calls: list[dict] = []
    cost = 0.002
    action = None

    @classmethod
    def run(cls, **kw):
        tools = {t.schema["name"]: t for t in kw.get("extra_tools") or []}
        cls.calls.append({"tools": set(tools), "model": kw["model"], "escalation": kw.get("escalation_model"),
                          "allow_computer": kw.get("allow_computer"), "mcp": kw.get("mcp_hub"), "budget": kw.get("budget"),
                          "system": "\n".join(b["text"] for b in kw["system"] if isinstance(b, dict) and b.get("text"))})
        text = "Hallo"
        if cls.action:
            text = cls.action(tools) or text
        u = SimpleNamespace(dollars=cls.cost, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        return Outcome(text, "end_turn", SimpleNamespace(by_model={kw["model"]: u}, dollars=cls.cost), [], False,
                       kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def send(bot_id: str, text: str) -> dict:
    n = len(FakeEngine.calls)
    r = http.post(f"/api/bots/{bot_id}/messages", json={"text": text})
    assert r.status_code == 200, r.text
    wait_for(lambda: len(FakeEngine.calls) > n, msg="Lauf gestartet")
    wait_for(lambda: not service.runs, msg="Lauf beendet")
    return FakeEngine.calls[-1]


def main() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: _up(), msg="Server gestartet")
    bot = server.db.bots()[0]
    bid = bot["id"]
    server.db.q("UPDATE bots SET model='claude-opus-5-5' WHERE id=?", (bid,))

    print("Demo-Modus: Modell, Werkzeuge, Prompt")
    ok(demo.active(), "demo: true aus config.json")
    call = send(bid, "Hi")
    ok(call["model"] == demo.MODEL and call["escalation"] is None, "immer Haiku, keine Eskalation")
    ok(call["allow_computer"] is False and call["mcp"] is None, "kein Rechner, keine MCP-/Composio-Werkzeuge")
    ok(call["tools"] and call["tools"] <= demo.ALLOWED_TOOLS, f"nur erlaubte Werkzeuge ({sorted(call['tools'] - demo.ALLOWED_TOOLS)})")
    for name in ("terminal", "aufgabe_starten", "tresor_eintrag_anlegen", "login_ausfuellen", "datei_vom_rechner",
                 "datei_auf_rechner"):
        ok(name not in call["tools"], f"ohne {name}")
    ok({"mail_vorbereiten", "freigabe_anfordern", "routine_anlegen", "merken"} <= call["tools"], "Mail, Freigabe, Routine, Gedächtnis da")
    ok("[Demo server]" in call["system"], "Demo-Hinweis im Prompt")
    ok(abos.mode("claude") == "api" and abos.mode("openai") == "api", "nie über ein KI-Abo")

    print("Mail-Karte: Freigeben verschickt nichts")
    executed = []
    service.connections.execute = lambda *a, **k: executed.append(a)  # dürfte nie aufgerufen werden
    FakeEngine.action = lambda tools: tools["mail_vorbereiten"].handler(
        {"konto": "Demo", "an": "team@example.com", "betreff": "Wochenbericht", "text": "Hallo Team"})
    send(bid, "Schreib dem Team")
    FakeEngine.action = None
    appr = wait_for(lambda: server.db.one("SELECT * FROM approvals WHERE state='pending'"), msg="Mail-Karte")
    r = http.post(f"/api/approvals/{appr['id']}", json={"decision": "approve"})
    ok(r.status_code == 200, "Mail-Karte freigegeben")
    ev = wait_for(lambda: server.db.one("SELECT text FROM messages WHERE role='event' AND text LIKE 'Demo: Mail%'"),
                  msg="Ereignis nach Senden")
    ok("nicht wirklich gesendet" in ev["text"], "Ereignis „nicht wirklich gesendet“")
    ok(not executed, "kein Aufruf an Composio/Gmail")
    wait_for(lambda: not service.runs, msg="Fortsetzung beendet")

    print("Gesperrte Endpunkte")
    for method, path, body in (("GET", "/api/settings/workspace/browse?path=~", None),
                               ("PATCH", "/api/settings/workspace", {"path": "~"}),
                               ("POST", f"/api/bots/{bid}/tasks", {"prompt": "x"}),
                               ("POST", "/api/tasks", {"prompt": "x"}),
                               ("POST", "/api/settings/abos/claude/login", {}),
                               ("PATCH", "/api/settings/abos", {"claude": "abo"}),
                               ("POST", "/api/nodes/pair", {}),
                               ("POST", "/api/nodes/claim", {"code": "AAAA-BBBB"}),
                               ("PATCH", "/api/apple", {}),
                               ("POST", "/api/connections/gmail/connect", {}),
                               ("POST", "/api/vault", {})):
        r = http.request(method, path, json=body)
        ok(r.status_code == 403 and r.json()["error"] == demo.DISABLED_TEXT, f"{method} {path.split('?')[0]} → 403")
    ok(http.get("/api/bots").status_code == 200, "normale Endpunkte gehen")
    try:
        service.tasks.start(bid, bid, "x", "y")
        ok(False, "Aufgabe gestartet")
    except Exception as e:  # noqa: BLE001
        ok("Demo-Server" in str(e), "Aufgaben im Demo aus (auch direkt)")

    print("Ausgabenlimit")
    ok(demo.limits() == (5.0, 20.0), "Limits aus config.json")
    today, month = demo.spent(server.db)
    ok(0 < today == month < 0.1, f"Kosten heute/Monat gezählt ({today:.3f} $)")
    call = send(bid, "noch was")
    ok(call["budget"] <= 1.5, "Laufbudget ≤ RUN_BUDGET")
    server.db.q("INSERT INTO usage(bot_id,model,dollars,created_at,billing) VALUES(?,?,?,?,?)",
                (bid, demo.MODEL, 4.999, server.db.one("SELECT created_at FROM usage ORDER BY id DESC")["created_at"], None))
    left, text = demo.budget_left(server.db)
    ok(left == 0.0 and "Tageslimit" in text, "Tageslimit erreicht")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{bid}/messages", json={"text": "und jetzt?"})
    msg = wait_for(lambda: server.db.one("SELECT text, meta FROM messages WHERE role='bot' AND text LIKE 'Das Tageslimit%'"),
                   msg="Limit-Nachricht")
    time.sleep(0.3)
    ok(len(FakeEngine.calls) == n, "kein Modellaufruf nach erreichtem Limit")
    ok(json.loads(msg["meta"]).get("spend_limit") is True, "Nachricht als Limit gekennzeichnet")
    ok(service.tasks.start_due() == [], "geplante Aufgaben starten nicht")

    print("Ohne Demo-Modus")
    cfg = load_config()
    cfg.pop("demo")
    cfg["spend_limits"] = {"daily_usd": 100, "monthly_usd": 5}
    save_config(cfg)
    ok(not demo.active() and not demo.blocked("GET", "/api/settings/workspace/browse"), "Sperren aus")
    left, text = demo.budget_left(server.db)
    ok(left == 0.0 and "Monatslimit" in text, "Monatslimit greift auch ohne Demo")
    cfg["spend_limits"] = {}
    save_config(cfg)
    ok(demo.budget_left(server.db) == (None, None), "ohne spend_limits unbegrenzt")
    call = send(bid, "normal")
    ok(call["model"] == "claude-opus-5-5" and not call["tools"] <= demo.ALLOWED_TOOLS, "eigenes Modell und alle Werkzeuge wieder aktiv")
    ok("[Demo server]" not in call["system"], "kein Demo-Hinweis")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


def _up() -> bool:
    try:
        return http.get("/api/health").status_code == 200
    except httpx.HTTPError:
        return False


if __name__ == "__main__":
    main()
