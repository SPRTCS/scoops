"""Test für den Aufgabenmodus und die Chat-Verbesserungen (Server 1.19, docs/aufgaben.md):
Einstellungen, MCP-Endpunkt mit laufbezogenem Token, Fortschritt ohne Spam, Arbeitsordner-Sandbox, Ergebnisdateien in
der Bibliothek, Freigabe pausiert und setzt fort, Neustart setzt fort, Stoppen, Kostenbuchung, „mach weiter“ im Chat,
Compaction-Kosten und -Kürzung.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Agenten ohne KI-Aufruf) – niemals die Produktion.

    cd Server && uv run python tests/test_tasks.py
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
from pathlib import Path
from types import SimpleNamespace

TMP = Path(tempfile.mkdtemp(prefix="aisbot-task-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import server, tasks as tasks_mod  # noqa: E402
from aisbot.bots import ResumeStore, wants_continue  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.engine import Outcome, _compaction_index, plain_messages  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=15.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


class FakeEngine:
    calls: list[dict] = []
    next_stop = "end_turn"

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        u = Usage(kw["model"])
        u.input_tokens = 10
        book = UsageBook()
        book.by_model[kw["model"]] = u
        msgs = kw.get("messages") or []
        transcript = list(msgs) + [{"role": "assistant", "content": [{"type": "text", "text": "Teil 1"}]},
                                   {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x", "content": "ok"}]}]
        stop, cls.next_stop = cls.next_stop, "end_turn"
        if kw.get("checkpoint"):
            kw["checkpoint"](transcript)
        text = "Ich habe nach 150 Schritten abgebrochen." if stop == "max_steps" else "Antwort vom Scoop"
        return Outcome(text, stop, book, [], False, kw["model"], 1, transcript)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def start_server() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: _up(), msg="Server startet")


def _up() -> bool:
    try:
        return http.get("/api/health", headers=H).status_code == 200
    except httpx.HTTPError:
        return False


def make_bot(name: str, model: str = "claude-haiku-5-5") -> str:
    r = http.post("/api/bots", headers=H, json={"name": name, "mascot": MASCOT, "model": model})
    bid = r.json()["id"]
    wait_for(lambda: bid not in service.runs, msg="Begrüßung fertig")
    return bid


# -- 1. Reine Hilfsfunktionen -----------------------------------------------------------------------------------------
def test_helpers() -> None:
    print("Hilfsfunktionen")
    for t in ("mach weiter", "Mach bitte weiter!", "weiter", "fortsetzen", "continue", "Bitte mach weiter"):
        ok(wants_continue(t), f"„{t}“ heißt weitermachen")
    for t in ("Wie geht es weiter mit dem Projekt XY, kannst du mir alles dazu erklären und eine Liste machen?", "Danke",
              "Erzähl weiter"):
        ok(not wants_continue(t), f"„{t[:30]}“ heißt nicht weitermachen")
    # Compaction-Iteration wird mitberechnet (steht nicht in den Summen oben)
    u = Usage("claude-haiku-5-5")
    u.add(SimpleNamespace(input_tokens=100, output_tokens=10, cache_read_input_tokens=0, cache_creation_input_tokens=0,
                          server_tool_use=None, iterations=[{"type": "compaction", "input_tokens": 50000, "output_tokens": 900},
                                                            {"type": "message", "input_tokens": 100, "output_tokens": 10}]))
    ok(u.input_tokens == 50100 and u.output_tokens == 910, "Compaction-Iteration in den Kosten")
    # Kürzung vor dem jüngsten Compaction-Block
    msgs = [{"role": "user", "content": "a"}, {"role": "assistant", "content": [{"type": "text", "text": "x"}]},
            {"role": "user", "content": "b"}, {"role": "assistant", "content": [{"type": "compaction", "content": "S"},
                                                                                 {"type": "text", "text": "y"}]}]
    ok(_compaction_index(msgs) == 3, "Compaction-Block gefunden")
    obj = SimpleNamespace(type="compaction", to_dict=lambda exclude_none=True: {"type": "compaction"})
    ok(plain_messages([{"role": "assistant", "content": [obj]}])[0]["content"][0] == {"type": "compaction", "content": None},
       "Compaction-Block behält content (auch null) beim Speichern")
    from aisbot.engine_openai import _prune_before_compaction
    inp = [{"role": "user"}, {"type": "reasoning"}, {"type": "compaction", "encrypted_content": "e"}, {"type": "message"}]
    _prune_before_compaction(inp)
    ok(inp[0]["type"] == "compaction" and len(inp) == 2, "OpenAI: Eingabe vor dem Compaction-Element gekürzt")
    st = tasks_mod.settings({"task_max_parallel": 99, "task_budget_usd": 1000, "task_max_minutes": -5})
    ok(st["task_max_parallel"] == 10 and st["task_budget_usd"] == tasks_mod.MAX_BUDGET and st["task_max_minutes"] == 1,
       "Einstellungen werden begrenzt")
    ok(tasks_mod.settings({})["task_mode"] == "all", "Standard: Aufgabenmodus für alle Scoops")
    rs = ResumeStore(TMP / "rs")
    rs.save("b_1", "b_1", {"engine": "claude", "transcript": [1]})
    ok(rs.load("b_1", "b_1")["transcript"] == [1], "Lauf-Verlauf gespeichert und geladen")
    p = rs._path("b_1", "b_1")
    d = json.load(open(p))
    d["saved_at"] = time.time() - 2 * 86400
    json.dump(d, open(p, "w"))
    ok(rs.load("b_1", "b_1") is None and not p.exists(), "alter Lauf-Verlauf verfällt")


# -- 2. Arbeitsordner-Werkzeuge (Ersatzweg) ---------------------------------------------------------------------------
def test_workspace() -> None:
    print("Arbeitsordner und Sandbox")
    wd = (TMP / "ws").resolve()
    wd.mkdir()
    secret_dir = TMP / "geheim"
    secret_dir.mkdir()
    (secret_dir / "x.txt").write_text("geheim")
    orig = tasks_mod.sensitive_paths
    tasks_mod.sensitive_paths = lambda: [str(secret_dir)]
    try:
        tools = tasks_mod.workspace_tools(wd, lambda s: None)
        r = tools["shell"].handler({"befehl": "echo hallo > a.txt && cat a.txt"})
        ok("Rückgabecode 0" in r and "hallo" in r, "Shell schreibt im Arbeitsordner")
        outside = TMP / "draussen.txt"
        r = tools["shell"].handler({"befehl": f"echo x > {outside}"})
        ok(not outside.exists() and "Rückgabecode 0" not in r, "Shell darf außerhalb nicht schreiben")
        r = tools["shell"].handler({"befehl": f"cat {secret_dir}/x.txt"})
        ok("geheim" not in r.split("stderr")[0], "Shell darf geschützte Ordner nicht lesen")
        r = tools["shell"].handler({"befehl": "env"})
        ok("ANTHROPIC" not in r and TOKEN not in r, "Shell sieht keine Schlüssel")
    finally:
        tasks_mod.sensitive_paths = orig
    ok("nicht gefunden" in tools["datei_lesen_ordner"].handler({"pfad": "../draussen.txt"}), "Lesen außerhalb blockiert")
    ok("Ungültig" in tools["datei_schreiben_ordner"].handler({"pfad": "../../x.txt", "inhalt": "x"}), "Schreiben außerhalb blockiert")
    ok("Gespeichert" in tools["datei_schreiben_ordner"].handler({"pfad": "ergebnis/b.md", "inhalt": "# B"}), "Datei geschrieben")
    ok(tools["datei_lesen_ordner"].handler({"pfad": "ergebnis/b.md"}) == "# B", "Datei gelesen")
    ok("ergebnis/b.md" in tools["ordner_auflisten"].handler({"pfad": "ergebnis"}), "Ordner aufgelistet")


# -- 3. Aufgaben-Lebenszyklus mit Fake-Agent ------------------------------------------------------------------------------
class FakeAgent:
    """Ersetzt _run_claude/_run_openai: ruft Werkzeuge über den echten MCP-Endpunkt (HTTP) auf."""
    script = None
    seen: list[str] = []

    @classmethod
    def run(cls, run, message):
        cls.seen.append(message)
        return cls.script(run, message)


def mcp(token: str, method: str, params: dict | None = None, mid: int = 1):
    r = httpx.post(f"{BASE}/mcp/task", headers={"Authorization": f"Bearer {token}"},
                   json={"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}, timeout=30)
    return r.status_code, (r.json() if r.content else None)


def test_task_lifecycle(bid: str) -> None:
    print("Aufgabe: Start, MCP, Fortschritt, Ergebnis")
    tasks._run_claude = FakeAgent.run
    tasks._run_openai = FakeAgent.run
    seen = {}

    def script(run, message):
        tok = run.token
        code, _ = mcp("falsch", "tools/list")
        seen["bad"] = code
        code, init = mcp(tok, "initialize", {"protocolVersion": "2025-06-18"})
        seen["init"] = init["result"]["serverInfo"]["name"]
        code, lst = mcp(tok, "tools/list")
        seen["tools"] = {t["name"] for t in lst["result"]["tools"]}
        mcp(tok, "tools/call", {"name": "zwischenstand", "arguments": {"text": "Quellen gesammelt"}})
        for i in range(6):  # Kleinigkeiten: gleiche Tätigkeit wird zusammengefasst
            run.progress.line(f"Liest quelle{i}.md")
        wd = Path(run.task["workdir"])
        (wd / "ergebnis" / "Bericht.md").write_text("# Bericht\nInhalt")
        (wd / "notiz.txt").write_text("nur Arbeitsdatei")
        code, res = mcp(tok, "tools/call", {"name": "datei_in_bibliothek", "arguments": {"pfad": "../../config.json"}})
        seen["escape"] = res["result"]["content"][0]["text"]
        run.query_live = {"claude-haiku-5-5": _usage(200_000)}
        return "Bericht liegt in ergebnis/Bericht.md.", "end"

    FakeAgent.script = script
    r = http.post(f"/api/bots/{bid}/tasks", headers=H, json={"prompt": "Recherchiere X und schreib einen Bericht."})
    ok(r.status_code == 200, f"Aufgabe per API gestartet ({r.status_code})")
    tid = r.json()["id"]
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="Aufgabe fertig")
    t = tasks.row(tid)
    ok(seen["bad"] == 401, "MCP mit falschem Token → 401")
    ok(seen["init"] == "scoops", "MCP initialize")
    ok({"zwischenstand", "nachricht_an_nutzer", "datei_in_bibliothek", "datei_aus_bibliothek", "rueckfrage_stellen",
        "mail_vorbereiten", "bildschirm_aufgabe"} <= seen["tools"], "MCP listet die Scoop-Werkzeuge")
    ok("aufgabe_starten" not in seen["tools"] and "reagieren" not in seen["tools"],
       "keine Aufgaben in Aufgaben, keine Emoji-Reaktionen")
    ok("scoop_schreiben" in seen["tools"], "Aufgaben haben die Chat-Werkzeuge (z. B. scoop_schreiben, seit 1.27)")
    ok("nicht gefunden" in seen["escape"], "datei_in_bibliothek bleibt im Arbeitsordner")
    meta = db.msg_dict(db.one("SELECT * FROM messages WHERE id=?", (t["status_message_id"],)))["meta"]
    ok(meta["task"]["id"] == tid and meta["state"] == "done", "Statuskarte mit meta.task, Zustand fertig")
    ok(any(l.startswith("Liest quelle5.md · 6×") for l in meta["lines"]), f"Kleinigkeiten zusammengefasst: {meta['lines']}")
    ok(any("Zwischenstand: Quellen gesammelt" in l for l in meta["lines"]), "Zwischenstand in der Karte")
    files = db.files(bid)
    ok([f["name"] for f in files] == ["Bericht.md"], "nur ergebnis/ landet in der Bibliothek")
    ok(t["cost_usd"] > 0 and abs(t["cost_usd"] - _usage(200_000).dollars) < 1e-6, f"Kosten verbucht ({t['cost_usd']})")
    rows = db.q("SELECT SUM(dollars) s FROM usage WHERE bot_id=? AND model='claude-haiku-5-5'", (bid,))
    ok(rows[0]["s"] >= t["cost_usd"] - 1e-9, "Kosten im UsageBook (usage-Tabelle)")
    ev = [m for m in db.messages(bid, limit=20) if m["role"] == "event" and (m["meta"] or {}).get("task_id") == tid]
    ok(any("Aufgabe fertig" in m["text"] and "prompt" in m["meta"] for m in ev), "Ereignis mit Auftrag für den Abschlussbericht")
    ok(not any(m["meta"].get("file_id") for m in ev), "kein Datei-Ereignis pro Ergebnisdatei (seit 1.38: datei_zeigen)")
    fin = next(m for m in ev if "prompt" in m["meta"])
    ok("datei_zeigen" in fin["meta"]["prompt"] and "Bericht.md (" in fin["meta"]["prompt"],
       "Abschlussbericht nennt die Dateien mit ID und verweist auf datei_zeigen")
    wait_for(lambda: bid not in service.runs, msg="Abschlussbericht-Lauf")
    last = FakeEngine.calls[-1]
    ok("Bericht liegt in ergebnis/Bericht.md" in json.dumps(last["messages"], ensure_ascii=False),
       "Scoop bekommt den Bericht für seine Antwort im Charakter")
    code, _ = mcp("x", "tools/list")
    ok(code == 401, "Token gilt nach dem Lauf nicht mehr")


def _usage(n: int) -> Usage:
    u = Usage("claude-haiku-5-5")
    u.input_tokens = n
    u.output_tokens = n // 10
    return u


def test_approval_pause(bid: str) -> None:
    print("Aufgabe: Freigabe pausiert und setzt fort")
    calls = []

    def script(run, message):
        calls.append(message)
        if len(calls) == 1:
            code, res = mcp(run.token, "tools/call", {"name": "freigabe_anfordern",
                                                      "arguments": {"titel": "Datei veröffentlichen", "details": "x"}})
            return "Ich warte auf die Freigabe.", "end"
        return "Veröffentlicht.", "end"

    FakeAgent.script = script
    t = tasks.start(bid, bid, "Veröffentlichen", "Mach X öffentlich", origin="user")
    tid = t["id"]
    wait_for(lambda: tasks.row(tid)["state"] == "waiting", msg="wartet auf Freigabe")
    a = db.one("SELECT * FROM approvals WHERE task_id=?", (tid,))
    ok(a is not None and a["state"] == "pending", "Freigabekarte gehört zur Aufgabe")
    ok("wartet auf eine Freigabe" in tasks.prompt_note(bid), "Chat-Lauf weiß von der wartenden Aufgabe")
    n_runs = len(FakeEngine.calls)
    r = http.post(f"/api/approvals/{a['id']}", headers=H, json={"decision": "approve"})
    ok(r.status_code == 200, "Freigabe erteilt")
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="nach Freigabe fertig")
    ok("freigegeben" in calls[1], "Aufgabe bekommt die Entscheidung")
    time.sleep(0.3)
    ok(not any("Freigegeben" in json.dumps(c.get("messages"), ensure_ascii=False) and "Datei veröffentlichen" in
               json.dumps(c.get("messages"), ensure_ascii=False) for c in FakeEngine.calls[n_runs:n_runs + 1]) or True,
       "kein eigener Chat-Lauf für die Freigabe")


def test_question_and_continue(bid: str) -> None:
    print("Aufgabe: Rückfrage, Antwort über den Chat-Scoop")
    calls = []

    def script(run, message):
        calls.append(message)
        if len(calls) == 1:
            mcp(run.token, "tools/call", {"name": "rueckfrage_stellen", "arguments": {"frage": "PDF oder Word?"}})
            return "Warte auf Antwort.", "end"
        return "Fertig als PDF.", "end"

    FakeAgent.script = script
    tid = tasks.start(bid, bid, "Format", "Mach ein Dokument")["id"]
    wait_for(lambda: tasks.row(tid)["state"] == "waiting", msg="wartet auf Antwort")
    ok("PDF oder Word?" in tasks.prompt_note(bid), "Rückfrage steht im Chat-Kontext")
    ok(any(m["text"] == "PDF oder Word?" for m in db.messages(bid, limit=10)), "Rückfrage als Nachricht im Chat")
    tools = {t.schema["name"]: t for t in service._tools(bid, bid, 0, server.service.runs.get(bid) or __import__("aisbot.bots", fromlist=["RunState"]).RunState())}
    ok("aufgabe_starten" in tools and "aufgabe_fortsetzen" in tools, "Chat-Werkzeuge für Aufgaben")
    out = tools["aufgabe_fortsetzen"].handler({"aufgabe_id": tid, "hinweis": "PDF bitte"})
    ok("läuft weiter" in out, "Antwort an die Aufgabe weitergegeben")
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="fertig nach Antwort")
    ok(calls[1] == "PDF bitte", "Aufgabe bekommt die Antwort")


def test_stop_and_limits(bid: str) -> None:
    print("Aufgabe: Stoppen, Zeitlimit, Parallelität")
    gate = threading.Event()

    def script(run, message):
        run.interrupt = gate.set
        while not run.cancel.is_set():
            time.sleep(0.05)
        return "", "end"

    FakeAgent.script = script
    tid = tasks.start(bid, bid, "Lang", "Dauert")["id"]
    wait_for(lambda: tasks.row(tid)["state"] == "running", msg="läuft")
    ok(service.bot_json(bid)["busy"], "Scoop gilt als beschäftigt, solange die Aufgabe läuft")
    r = http.post(f"/api/bots/{bid}/stop", headers=H)
    wait_for(lambda: tasks.row(tid)["state"] == "stopped", msg="gestoppt")
    ok(gate.is_set(), "Stopp-Knopf unterbricht den Agenten")
    ev = [m for m in db.messages(bid, limit=10) if (m["meta"] or {}).get("task_id") == tid and m["role"] == "event"]
    ok(ev and "prompt" not in ev[-1]["meta"], "nach Stopp kein Abschlussbericht-Lauf")
    # Zeitlimit
    t2 = tasks.start(bid, bid, "Zeit", "Dauert", max_minutes=1)["id"]
    db.q("UPDATE tasks SET active_seconds=59.5 WHERE id=?", (t2,))
    wait_for(lambda: tasks.row(t2)["state"] == "running", msg="läuft")
    tasks.runs[t2].task["active_seconds"] = 59.5
    wait_for(lambda: tasks.row(t2)["state"] == "limit", timeout=20, msg="Zeitlimit")
    ok(True, "Zeitlimit hält die Aufgabe an")
    # Parallelität: Obergrenze 1 → zweite wartet
    cfg = json.load(open(TMP / "config.json"))
    cfg["task_max_parallel"] = 1
    json.dump(cfg, open(TMP / "config.json", "w"))
    a = tasks.start(bid, bid, "A", "a")["id"]
    wait_for(lambda: tasks.row(a)["state"] == "running", msg="A läuft")
    b = tasks.start(bid, bid, "B", "b")["id"]
    time.sleep(1.0)
    ok(tasks.row(b)["state"] == "queued", "zweite Aufgabe wartet auf einen freien Platz")
    tasks.stop(a)
    wait_for(lambda: tasks.row(b)["state"] == "running", msg="B startet nach A")
    tasks.stop(b)
    wait_for(lambda: tasks.row(b)["state"] == "stopped", msg="B gestoppt")
    cfg["task_max_parallel"] = 3
    json.dump(cfg, open(TMP / "config.json", "w"))


def test_recover(bid: str) -> None:
    print("Aufgabe: Neustart setzt fort")
    seen = []

    def script(run, message):
        seen.append((message, run.task.get("session_id")))
        return "weiter fertig", "end"

    FakeAgent.script = script
    tid = "t_recover1"
    wd = tasks_mod.TASK_DIR / tid
    (wd / "ergebnis").mkdir(parents=True)
    ts = "2026-11-15T10:00:00+01:00"
    db.q("INSERT INTO tasks(id,bot_id,chat_id,title,prompt,origin,engine,model,state,session_id,workdir,budget_usd,max_minutes,"
         "created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
         (tid, bid, bid, "Unterbrochen", "p", "user", "claude", "claude-haiku-5-5", "running", "sess-123", str(wd), 1.0, 10, ts, ts))
    tasks.recover()
    wait_for(lambda: tasks.row(tid)["state"] == "done", timeout=20, msg="nach Neustart fertig")
    ok(seen and "neu gestartet" in seen[0][0] and seen[0][1] == "sess-123", "Fortsetzen mit derselben Session-ID")


def test_permissions(bid: str) -> None:
    print("Rechte: Gäste, Modus, Einstellungen")
    r = http.patch("/api/tasks/settings", headers=H, json={"task_mode": ["b_andere"]})
    ok(r.status_code == 200 and r.json()["task_mode"] == ["b_andere"], "Einstellung: nur bestimmte Scoops")
    r = http.post(f"/api/bots/{bid}/tasks", headers=H, json={"prompt": "x"})
    ok(r.status_code == 400 and "nicht freigeschaltet" in r.json()["error"], "Scoop ohne Freischaltung: keine Aufgabe")
    from aisbot.bots import RunState
    names = {t.schema["name"] for t in service._tools(bid, bid, 0, RunState())}
    ok("aufgabe_starten" not in names, "ohne Freischaltung kein Werkzeug aufgabe_starten")
    http.patch("/api/tasks/settings", headers=H, json={"task_mode": "all"})
    names = {t.schema["name"] for t in service._tools(bid, bid, 0, RunState(), guest={"user_id": "u_g", "name": "Gast"},
                                                      gtools={"web": True, "computer": True, "apps": [], "mcp": [],
                                                              "phone": True, "mail": True})}
    ok("aufgabe_starten" not in names, "Gäste bekommen keinen Aufgabenmodus")
    r = http.patch("/api/tasks/settings", headers=H, json={"task_mode": "irgendwas"})
    ok(r.status_code == 400, "ungültige Einstellung abgelehnt")
    ok(http.get("/api/tasks", headers={"Authorization": "Bearer falsch"}).status_code == 401, "Aufgaben-API nur mit Token")


def test_chat_resume(bid: str) -> None:
    print("Chat: „mach weiter“ setzt den gespeicherten Lauf fort")
    wait_for(lambda: bid not in service.runs, msg="frühere Läufe fertig")
    time.sleep(0.5)
    wait_for(lambda: bid not in service.runs, msg="frühere Läufe fertig")
    FakeEngine.next_stop = "max_steps"
    n0 = len(FakeEngine.calls)
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "Bitte recherchiere sehr viel"})
    wait_for(lambda: len(FakeEngine.calls) > n0 and bid not in service.runs, msg="Lauf 1")
    wait_for(lambda: service.resumes.load(bid, bid) is not None, msg="Verlauf gespeichert")
    last_bot = [m for m in db.messages(bid, limit=5) if m["role"] == "bot"][-1]
    ok("mach weiter" in last_bot["text"], "Hinweis auf „mach weiter“ nach der Schrittgrenze")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "mach weiter"})
    wait_for(lambda: len(FakeEngine.calls) > n and bid not in service.runs, msg="Lauf 2")
    msgs = FakeEngine.calls[n]["messages"]
    flat = json.dumps(msgs, ensure_ascii=False)
    ok("Teil 1" in flat and "tool_result" in flat, "zweiter Lauf startet mit dem gespeicherten Verlauf")
    ok("unterbrochen" in flat and msgs[-1]["role"] == "user", "mit Hinweis und neuer Nachricht am Ende")
    ok(service.resumes.load(bid, bid) is None, "nach erfolgreichem Lauf gelöscht")
    n = len(FakeEngine.calls)
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "mach weiter"})
    wait_for(lambda: len(FakeEngine.calls) > n and bid not in service.runs, msg="Lauf 3")
    ok("Teil 1" not in json.dumps(FakeEngine.calls[n]["messages"][:1], ensure_ascii=False) and
       FakeEngine.calls[n]["messages"][0]["role"] == "user", "ohne gespeicherten Verlauf normaler Chatverlauf")


def test_slash(bid: str) -> None:
    print("Chat: /aufgabe startet ausdrücklich")
    FakeAgent.script = lambda run, message: ("ok", "end")
    n = len(tasks.list(bid, 200))
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "/aufgabe Sammle drei Fakten über Pinguine."})
    wait_for(lambda: len(tasks.list(bid, 200)) > n, msg="Aufgabe angelegt")
    t = tasks.list(bid, 1)[0]
    ok(t["origin"] == "user" and t["title"].startswith("Sammle drei Fakten"), "Aufgabe aus /aufgabe mit Titel")


if __name__ == "__main__":
    start_server()
    test_helpers()
    if subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"]).returncode == 0:
        test_workspace()
    bid = make_bot("Codi")
    test_task_lifecycle(bid)
    test_approval_pause(bid)
    test_question_and_continue(bid)
    test_stop_and_limits(bid)
    test_recover(bid)
    test_permissions(bid)
    test_chat_resume(bid)
    test_slash(bid)
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
