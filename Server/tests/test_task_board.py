"""Test für das Aufgaben-Board (Server 1.22, docs/aufgaben.md „Board“): geplante Aufgaben und Planer (auch nach
Neustart), Abnahme getrennt vom Laufzustand (Zu prüfen → Abgeschlossen → Archiv → wiederherstellen), Nacharbeiten,
Modell pro Aufgabe, Kosten und Schritte, Board-Liste mit Filtern, Gast-Ausschluss, Chip-Optionen von „/aufgabe“,
`aufgabe_starten` mit `termin`, `aufgabe_abnehmen`, Systemprompt.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Agenten ohne KI-Aufruf) – niemals die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_task_board.py
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-board-test-"))
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
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.db import TZ  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402
from aisbot.sharing import Principal  # noqa: E402

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

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        u = Usage(kw["model"])
        u.input_tokens = 10
        book = UsageBook()
        book.by_model[kw["model"]] = u
        return Outcome("Antwort vom Scoop", "end_turn", book, [], False, kw["model"], 1, list(kw.get("messages") or []))


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


class FakeAgent:
    """Ersetzt _run_claude/_run_openai: ein paar Schritte, etwas Kosten, eine Ergebnisdatei."""
    seen: list[tuple[str, str, str]] = []  # (task_id, model, message)
    hold = threading.Event()

    @classmethod
    def run(cls, run, message):
        cls.seen.append((run.task["id"], run.task["model"], message))
        for step in ("Liest Quellen", "Schreibt Bericht.md", "Prüft das Ergebnis"):
            run.progress.line(step)
        u = Usage(run.task["model"])
        u.input_tokens, u.output_tokens = 100_000, 2_000
        run.usage = {run.task["model"]: u}
        (Path(run.task["workdir"]) / "ergebnis" / f"Ergebnis-{run.task['id']}.md").write_text("# Ergebnis\n")
        end = time.time() + 10
        while cls.hold.is_set() and time.time() < end and not run.cancel.is_set():
            time.sleep(0.05)
        return "Fertig. Ergebnis in ergebnis/.", "end"


tasks._run_claude = FakeAgent.run
tasks._run_openai = FakeAgent.run


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


def idle(bid: str) -> None:
    wait_for(lambda: bid not in service.runs and not tasks.runs, timeout=20, msg="alles ruhig")


def get(tid: str) -> dict:
    return http.get(f"/api/tasks/{tid}", headers=H).json()


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


# -- 1. Sofort starten, Zu prüfen, Abnahme, Archiv --------------------------------------------------------------------
def test_review_flow(bid: str) -> None:
    print("Board: Sofort-Aufgabe → Zu prüfen → Abgeschlossen → Archiv → wiederherstellen")
    events: list[tuple[str, dict]] = []
    orig = service.publish
    service.publish = lambda typ, data: (events.append((typ, data)) if typ.startswith("task.") else None, orig(typ, data))[1]
    try:
        r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Recherchiere Pinguine und schreib einen Bericht.",
                                                     "title": "Pinguin-Bericht"})
        ok(r.status_code == 200 and r.json()["title"] == "Pinguin-Bericht", f"POST /api/tasks startet ({r.status_code})")
        tid = r.json()["id"]
        ok(r.json()["origin"] == "board" and r.json()["column"] in ("active", "review"), "Herkunft board, Spalte In Arbeit")
        wait_for(lambda: tasks.row(tid)["state"] == "done", msg="Aufgabe fertig")
        idle(bid)
        t = get(tid)
        ok(t["column"] == "review" and t["review"] == "review", "fertig → Spalte „Zu prüfen“ (Abnahme getrennt vom Lauf)")
        ok(t["cost_usd"] > 0, f"Kosten pro Aufgabe ({t['cost_usd']})")
        ok(t["steps"] == 3 and t["lines"][:3] == ["Liest Quellen", "Schreibt Bericht.md", "Prüft das Ergebnis"], f"Schritte und Verlauf ({t['steps']})")
        ok(t["file_items"] and t["file_items"][0]["name"].startswith("Ergebnis-"), "Ergebnisdateien mit Namen im Detail")
        ok(any(typ == "task.updated" and d["id"] == tid and d["column"] == "review" for typ, d in events),
           "Ereignis task.updated hält das Board live")
        ok(any(typ == "task.updated" and d["id"] == tid and d["state"] == "running" for typ, d in events),
           "Ereignis auch beim Start")
        lst = http.get("/api/tasks", headers=H, params={"column": "review"}).json()
        ok([x["id"] for x in lst] == [tid], "Liste mit Spaltenfilter")
        r = http.post(f"/api/tasks/{tid}/accept", headers=H)
        ok(r.status_code == 200 and r.json()["column"] == "done" and r.json()["reviewed_at"], "Erledigt → Abgeschlossen")
        r = http.post(f"/api/tasks/{tid}/archive", headers=H)
        ok(r.json()["column"] == "archived" and r.json()["archived_at"], "Archivieren")
        ok(http.get("/api/tasks", headers=H, params={"column": "review,done"}).json() == [], "Archiv taucht im Board nicht auf")
        r = http.post(f"/api/tasks/{tid}/restore", headers=H)
        ok(r.json()["column"] == "done" and not r.json()["archived_at"], "Wiederherstellen → wieder Abgeschlossen")
        r = http.post(f"/api/tasks/{tid}/restore", headers=H)
        ok(r.status_code == 409, "Wiederherstellen ohne Archiv → 409")
    finally:
        service.publish = orig
    return tid


def test_rework(bid: str, tid: str) -> None:
    print("Board: Nacharbeiten mit Hinweis")
    r = http.post(f"/api/tasks/{tid}/rework", headers=H, json={"message": ""})
    ok(r.status_code == 409, "Nacharbeiten ohne Hinweis abgelehnt")
    n = len(FakeAgent.seen)
    r = http.post(f"/api/tasks/{tid}/rework", headers=H, json={"message": "Bitte noch Quellen ergänzen."})
    ok(r.status_code == 200 and r.json()["review"] is None, "Nacharbeiten setzt die Abnahme zurück")
    wait_for(lambda: len(FakeAgent.seen) > n, msg="Aufgabe läuft wieder")
    ok("Bitte noch Quellen ergänzen." in FakeAgent.seen[-1][2] and "Nacharbeit" in FakeAgent.seen[-1][2],
       "Hinweis kommt in derselben Aufgabe an")
    wait_for(lambda: tasks.row(tid)["state"] == "done" and tasks.row(tid)["review"] == "review", msg="wieder Zu prüfen")
    idle(bid)
    ok(get(tid)["column"] == "review", "nach der Nacharbeit wieder „Zu prüfen“")
    r = http.post(f"/api/tasks/{tid}/accept", headers=H)
    ok(r.json()["column"] == "done", "danach abgenommen")


# -- 2. Geplante Aufgaben ---------------------------------------------------------------------------------------------
def test_planned(bid: str) -> None:
    print("Board: geplante Aufgaben, Ändern, Löschen, sofort starten")
    later = datetime.now(TZ) + timedelta(hours=3)
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Wochenbericht erstellen",
                                                 "scheduled_at": later.astimezone().isoformat()})
    t = r.json()
    ok(r.status_code == 200 and t["state"] == "scheduled" and t["column"] == "planned", "mit Termin → Geplant")
    ok(t["model"] == "claude-haiku-5-5" and t["model_choice"] is None, "Modell „wie Scoop“ (wirksames Modell angezeigt)")
    ok(t["status_message_id"] is None and not tasks.runs, "geplant: noch keine Statuskarte, kein Lauf")
    ev = [m for m in db.messages(bid, limit=10) if m["role"] == "event" and (m["meta"] or {}).get("task_id") == t["id"]]
    ok(ev and "Aufgabe geplant" in ev[-1]["text"], f"Ereignis im Chat ({ev[-1]['text'] if ev else '-'})")
    tid = t["id"]
    # Ändern
    r = http.patch(f"/api/tasks/{tid}", headers=H, json={"title": "Wochenbericht KW 47", "model": "claude-sonnet-5-5",
                                                       "scheduled_at": iso(later + timedelta(hours=1))})
    ok(r.status_code == 200 and r.json()["title"] == "Wochenbericht KW 47", "Titel geändert")
    ok(r.json()["model_choice"] == "claude-sonnet-5-5" and r.json()["model"] == "claude-sonnet-5-5", "Modell geändert")
    ok(tasks_mod.parse_when(r.json()["scheduled_at"]) == (later + timedelta(hours=1)).replace(microsecond=0),
       "Termin geändert (Zeitzone korrekt)")
    r = http.patch(f"/api/tasks/{tid}", headers=H, json={"model": "gpt-gibts-nicht"})
    ok(r.status_code == 409 and "gibt es nicht" in r.json()["error"], "unbekanntes Modell abgelehnt")
    r = http.patch(f"/api/tasks/{tid}", headers=H, json={"scheduled_at": "morgen"})
    ok(r.status_code == 409, "unlesbarer Termin abgelehnt")
    r = http.post(f"/api/tasks/{tid}/accept", headers=H)
    ok(r.status_code == 409, "geplante Aufgabe kann nicht abgenommen werden")
    r = http.post(f"/api/tasks/{tid}/continue", headers=H, json={"message": "los"})
    ok(r.status_code == 400, "geplante Aufgabe nicht per continue starten")
    # Sofort starten
    n = len(FakeAgent.seen)
    r = http.post(f"/api/tasks/{tid}/start", headers=H)
    ok(r.status_code == 200 and r.json()["column"] in ("active", "review"), "sofort starten")
    wait_for(lambda: len(FakeAgent.seen) > n, msg="geplante Aufgabe läuft")
    ok(FakeAgent.seen[-1][1] == "claude-sonnet-5-5" and tasks.row(tid)["engine"] == "claude", "läuft mit dem gewählten Modell")
    ok(http.post(f"/api/tasks/{tid}/start", headers=H).status_code == 409, "zweiter Start abgelehnt")
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="fertig")
    idle(bid)
    ok(http.patch(f"/api/tasks/{tid}", headers=H, json={"title": "x"}).status_code == 409, "nur geplante lassen sich ändern")
    ok(http.delete(f"/api/tasks/{tid}", headers=H).status_code == 409, "nur geplante lassen sich löschen")
    # Löschen
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Später etwas", "scheduled_at": iso(later)})
    did = r.json()["id"]
    wd = Path(tasks.row(did)["workdir"])
    r = http.delete(f"/api/tasks/{did}", headers=H)
    ok(r.status_code == 200 and tasks.row(did) is None and not wd.exists(), "geplante Aufgabe gelöscht (mit Arbeitsordner)")
    ok(http.get(f"/api/tasks/{did}", headers=H).status_code == 404, "danach 404")
    # Termin in der Vergangenheit = sofort
    n = len(FakeAgent.seen)
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Gleich",
                                                 "scheduled_at": iso(datetime.now(TZ) - timedelta(minutes=5))})
    ok(r.json()["state"] != "scheduled", "Termin in der Vergangenheit startet sofort")
    wait_for(lambda: len(FakeAgent.seen) > n and not tasks.runs, msg="fertig")
    idle(bid)


def test_scheduler(bid: str) -> None:
    print("Planer: fällige Aufgaben starten, auch nach einem Neustart")
    soon = datetime.now(TZ) + timedelta(hours=1)
    a = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Geplant A", "scheduled_at": iso(soon)}).json()["id"]
    b = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Geplant B", "scheduled_at": iso(soon)}).json()["id"]
    ok(tasks.start_due() == [], "nichts fällig")
    # „Neustart“: neuer TaskService auf derselben DB; recover() fasst geplante nicht an
    fresh = tasks_mod.TaskService(service, PORT)
    fresh._run_claude = FakeAgent.run
    fresh._run_openai = FakeAgent.run
    fresh.recover()
    ok(tasks.row(a)["state"] == "scheduled" and tasks.row(b)["state"] == "scheduled", "Neustart lässt geplante Aufgaben stehen")
    db.q("UPDATE tasks SET scheduled_at=? WHERE id=?", (iso(datetime.now(TZ) - timedelta(minutes=30)), a))
    started = fresh.start_due()
    ok(started == [a], f"verpasster Termin wird nach dem Neustart nachgeholt ({started})")
    ok(fresh.start_due() == [], "kein doppelter Start")
    ok(not fresh._claim_scheduled(a), "Zugriff auf schon gestartete Aufgabe verweigert")
    wait_for(lambda: tasks.row(a)["state"] == "done", msg="geplante Aufgabe fertig")
    msgs = db.messages(bid, limit=30)
    card = next(m for m in msgs if m["id"] == tasks.row(a)["status_message_id"])
    ok(any("Geplanter Start" in ln for ln in card["meta"]["lines"]), "Statuskarte zeigt den geplanten Start")
    idle(bid)
    http.delete(f"/api/tasks/{b}", headers=H)


# -- 3. Filter, Gäste ----------------------------------------------------------------------------------------------
def test_list_and_guests(bid: str, other: str) -> None:
    print("Liste über alle Scoops, Filter, Gast-Ausschluss")
    r = http.post("/api/tasks", headers=H, json={"chat_id": other, "prompt": "Etwas für Tina",
                                                 "scheduled_at": iso(datetime.now(TZ) + timedelta(days=1))})
    oid = r.json()["id"]
    all_ = http.get("/api/tasks", headers=H, params={"limit": 300}).json()
    ok({bid, other} <= {t["bot_id"] for t in all_}, "Liste enthält Aufgaben aller Scoops")
    only = http.get("/api/tasks", headers=H, params={"bot": other}).json()
    ok([t["id"] for t in only] == [oid], "Filter nach Scoop")
    ok(all(t["column"] == "planned" for t in http.get("/api/tasks", headers=H, params={"column": "planned"}).json()),
       "Filter nach Spalte")
    r = http.post("/api/tasks", headers=H, json={"chat_id": "b_gibtsnicht", "prompt": "x"})
    ok(r.status_code == 404, "unbekannter Chat → 404")
    # Gast mit gültigem Konto-JWT (geteilter Scoop): kein Zugriff auf das Board
    orig_verify, orig_owner = server.cloud.verify_any, server.cloud.owner_id
    server.cloud.verify_any = lambda tok: {"sub": "u_gast", "sid": "s1"} if tok == "gast-jwt" else None
    server.cloud.owner_id = lambda: "u_admin"
    try:
        G = {"Authorization": "Bearer gast-jwt"}
        ok(http.get("/api/tasks", headers=G).status_code == 403, "Gast: Liste → 403")
        ok(http.post("/api/tasks", headers=G, json={"chat_id": bid, "prompt": "x"}).status_code == 403, "Gast: Anlegen → 403")
        ok(http.get(f"/api/tasks/{oid}", headers=G).status_code == 403, "Gast: Detail → 403")
        ok(http.post(f"/api/tasks/{oid}/start", headers=G).status_code == 403, "Gast: Aktionen → 403")
        ok(http.delete(f"/api/tasks/{oid}", headers=G).status_code == 403, "Gast: Löschen → 403")
    finally:
        server.cloud.verify_any, server.cloud.owner_id = orig_verify, orig_owner
    guest = Principal("guest", "u_gast", "s1")
    ok(server.guest_event("task.updated", tasks.public(tasks.row(oid)), guest) is None
       and server.guest_event("task.deleted", {"id": oid}, guest) is None, "Gäste bekommen keine Aufgaben-Ereignisse")
    # Gast schickt „/aufgabe“ mit Chip-Optionen: wird nicht als Aufgabe gestartet
    n = db.one("SELECT COUNT(*) n FROM tasks")["n"]
    from aisbot.sharing import Share
    sh = Share(share_id="sh1", bot_id=bid, user_id="u_gast", name="Gast", role="write", computer="none")
    service.post_user_message(bid, "/aufgabe Gast will etwas", guest=sh,
                              task_options={"scheduled_at": iso(datetime.now(TZ) + timedelta(hours=2))})
    ok(db.one("SELECT COUNT(*) n FROM tasks")["n"] == n, "Gäste starten keine Aufgaben (auch nicht per /aufgabe)")
    idle(bid)
    http.delete(f"/api/tasks/{oid}", headers=H)


# -- 4. Chat: /aufgabe mit Chip-Optionen, Werkzeuge, Systemprompt -------------------------------------------------------
def test_chat(bid: str) -> None:
    print("Chat: /aufgabe mit Termin und Modell, aufgabe_starten mit termin, aufgabe_abnehmen, Systemprompt")
    idle(bid)
    when = datetime.now(TZ) + timedelta(hours=5)
    r = http.post(f"/api/bots/{bid}/messages", headers=H,
                  json={"text": "/aufgabe Poste auf X vom Konto @ais den Wochenrückblick.",
                        "task": {"scheduled_at": when.astimezone().isoformat(), "model": "claude-sonnet-5-5"}})
    m = r.json()
    ok(m["text"].startswith("/aufgabe ") and m["meta"]["task_options"]["model"] == "claude-sonnet-5-5",
       "Nachricht bleibt „/aufgabe …“ (Chip im Verlauf), Optionen in meta.task_options")
    t = tasks.list(bid, 1)[0]
    ok(t["state"] == "scheduled" and t["model_choice"] == "claude-sonnet-5-5" and t["origin"] == "user",
       "Chip-Optionen: geplant mit gewähltem Modell")
    ok(not service.runs.get(bid), "kein Chat-Lauf für /aufgabe")
    http.delete(f"/api/tasks/{t['id']}", headers=H)
    r = http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "/aufgabe Gleich erledigen bitte.",
                                                                "task": {"model": "wie_scoop"}})
    ok("task_options" not in (r.json()["meta"] or {}), "„Wie Scoop“ ohne Termin: keine Optionen nötig")
    wait_for(lambda: tasks.list(bid, 1)[0]["state"] == "done", msg="sofort gestartet und fertig")
    idle(bid)
    # Werkzeuge
    from aisbot.bots import RunState
    tools = {t.schema["name"]: t for t in service._tools(bid, bid, 0, RunState())}
    ok("termin" in tools["aufgabe_starten"].schema["input_schema"]["properties"], "aufgabe_starten kennt termin")
    desc = tools["aufgabe_starten"].schema["description"]
    ok("Bildschirm" in desc and "Konto" in desc, "Werkzeugbeschreibung nennt Bildschirm- und Kontowechsel-Arbeit")
    out = tools["aufgabe_starten"].handler({"titel": "Morgenbericht", "auftrag": "Bericht schreiben",
                                            "termin": (datetime.now(TZ) + timedelta(days=1)).strftime("%Y-%m-%dT08:00")})
    ok("geplant" in out, f"aufgabe_starten mit termin plant ({out[:60]})")
    planned = tasks.list(bid, 1)[0]
    ok(planned["state"] == "scheduled" and planned["scheduled_at"].endswith(("+01:00", "+02:00"))
       and "T08:00:00" in planned["scheduled_at"], "termin als Berliner Zeit")
    note = tasks.prompt_note(bid, bid)
    ok("aufgabe_starten" in note and "Kontowechsel" in note, "Systemprompt: wann eine Aufgabe passt")
    ok("geplant für" in note, "Systemprompt: geplante Aufgaben des Chats")
    review = next(t for t in tasks.list(bid, 50) if t["column"] == "review")
    ok(review["id"] in note and "Zu prüfen" in note, "Systemprompt: „Zu prüfen“-Aufgaben des Chats")
    out = tools["aufgabe_abnehmen"].handler({"aufgabe_id": review["id"]})
    ok("abgenommen" in out and tasks.row(review["id"])["review"] == "done", "aufgabe_abnehmen → Abgeschlossen")
    ok("nicht gefunden" in tools["aufgabe_abnehmen"].handler({"aufgabe_id": "t_fremd"}), "nur Aufgaben dieses Chats")
    ok(review["id"] not in (tasks.prompt_note(bid, bid) or ""), "abgenommene stehen nicht mehr im Prompt")
    gtools = {t.schema["name"] for t in service._tools(bid, bid, 0, RunState(), guest={"user_id": "u_g", "name": "Gast"},
                                                         gtools={"web": True, "computer": True, "apps": [], "mcp": [],
                                                                 "phone": True, "mail": True})}
    ok("aufgabe_abnehmen" not in gtools and "aufgabe_starten" not in gtools, "Gäste: keine Aufgaben-Werkzeuge")
    http.delete(f"/api/tasks/{planned['id']}", headers=H)


def test_migration() -> None:
    print("Übernahme alter Aufgaben")
    ok(db.setting("tasks_board_migrated") == "1", "einmalige Übernahme vermerkt")
    ts = "2026-11-01T10:00:00+01:00"
    db.q("INSERT INTO tasks(id,bot_id,chat_id,title,prompt,engine,model,state,workdir,budget_usd,max_minutes,created_at,"
         "updated_at,finished_at) VALUES('t_alt','b_x','b_x','Alt','x','claude','claude-haiku-5-5','done','/tmp/x',1,1,?,?,?)",
         (ts, ts, ts))
    db.q("DELETE FROM settings WHERE key='tasks_board_migrated'")
    tasks_mod.TaskService(service, PORT)
    r = tasks.row("t_alt")
    ok(r["review"] == "done" and r["reviewed_at"] == ts, "Aufgaben von vor 1.22 gelten als abgenommen")
    db.q("DELETE FROM tasks WHERE id='t_alt'")


def test_backlog(bid: str) -> None:
    print("Offen (Backlog): sammeln, planen, zurücklegen, starten, Planer fasst sie nicht an")
    n_msgs = len(db.messages(bid, limit=200))
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Irgendwann: Ordner aufräumen", "backlog": True})
    t = r.json()
    ok(r.status_code == 200 and t["state"] == "open" and t["column"] == "open", "backlog → Offen")
    ok(t["status_message_id"] is None and not tasks.runs, "offen: kein Lauf, keine Statuskarte")
    ok(len(db.messages(bid, limit=200)) == n_msgs, "offen: keine Nachricht im Chat")
    tid = t["id"]
    db.q("UPDATE tasks SET scheduled_at=? WHERE id=?", (iso(datetime.now(TZ) - timedelta(hours=1)), tid))
    ok(tid not in tasks.start_due(), "Planer startet offene Aufgaben nie")
    db.q("UPDATE tasks SET scheduled_at=NULL WHERE id=?", (tid,))
    ok(any(x["id"] == tid for x in http.get("/api/tasks?column=open", headers=H).json()), "Filter column=open")
    ok(not any(x["id"] == tid for x in http.get("/api/tasks?column=planned", headers=H).json()), "nicht unter Geplant")
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "x", "backlog": True,
                                                 "scheduled_at": iso(datetime.now(TZ) + timedelta(hours=2))})
    ok(r.json()["state"] == "open" and r.json()["scheduled_at"] is None, "backlog schlägt Termin")
    http.delete(f"/api/tasks/{r.json()['id']}", headers=H)
    ok(http.post(f"/api/tasks/{tid}/continue", headers=H, json={"message": "los"}).status_code == 400, "offen nicht per continue")
    ok(http.post(f"/api/tasks/{tid}/accept", headers=H).status_code == 409, "offen nicht abnehmbar")
    note = tasks.prompt_note(bid, bid) or ""
    ok("offen (von" in note and tid in note, "Scoop sieht die offene Aufgabe im Prompt")
    # planen → Geplant, zurücklegen → Offen
    later = datetime.now(TZ) + timedelta(hours=4)
    r = http.patch(f"/api/tasks/{tid}", headers=H, json={"scheduled_at": iso(later), "title": "Ordner aufräumen"})
    ok(r.status_code == 200 and r.json()["state"] == "scheduled" and r.json()["column"] == "planned", "Offen → Geplant mit Termin")
    r = http.patch(f"/api/tasks/{tid}", headers=H, json={"backlog": True})
    ok(r.json()["state"] == "open" and r.json()["scheduled_at"] is None, "Geplant → zurück nach Offen")
    ok(r.json()["title"] == "Ordner aufräumen", "Titel bleibt")
    # löschen
    d = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Weg damit", "backlog": True}).json()["id"]
    ok(http.delete(f"/api/tasks/{d}", headers=H).status_code == 200 and tasks.row(d) is None, "offene Aufgabe gelöscht")
    # starten
    n = len(FakeAgent.seen)
    r = http.post(f"/api/tasks/{tid}/start", headers=H)
    ok(r.status_code == 200 and r.json()["column"] in ("active", "review"), "offene Aufgabe gestartet")
    wait_for(lambda: len(FakeAgent.seen) > n, msg="offene Aufgabe läuft")
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="fertig")
    idle(bid)
    # Scoop-Werkzeug: termin='offen' sammelt, aufgabe_fortsetzen startet sie
    from aisbot.bots import RunState
    tl = {x.schema["name"]: x for x in service._tools(bid, bid, 0, RunState())}
    out = tl["aufgabe_starten"].handler({"titel": "Später", "auftrag": "Newsletter-Ideen sammeln", "termin": "offen"})
    sid = next(r["id"] for r in db.q("SELECT id FROM tasks WHERE title='Später'"))
    ok("Offen" in out and tasks.row(sid)["state"] == "open", "Scoop sammelt mit termin='offen'")
    n = len(FakeAgent.seen)
    out = tl["aufgabe_fortsetzen"].handler({"aufgabe_id": sid, "hinweis": ""})
    ok("gestartet" in out, f"aufgabe_fortsetzen startet die offene Aufgabe ({out[:60]})")
    wait_for(lambda: len(FakeAgent.seen) > n and tasks.row(sid)["state"] == "done", msg="fertig")
    idle(bid)
    # Eingabefeld (/aufgabe mit backlog)
    service.post_user_message(bid, "/aufgabe Steuerbelege sortieren", task_options={"backlog": True})
    row = dict(db.q("SELECT * FROM tasks WHERE prompt='Steuerbelege sortieren'")[0])
    ok(row["state"] == "open", "/aufgabe mit backlog sammelt nur")
    http.delete(f"/api/tasks/{row['id']}", headers=H)


def test_routine_tasks(bid: str) -> None:
    print("Routinen: Aufgaben aus einem Routine-Lauf sind gekennzeichnet und landen fertig direkt unter Abgeschlossen")
    from aisbot.bots import RunState
    from aisbot.db import now_iso
    rid = "rt_test_board"
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,?,?,?)", (rid, bid, "routine", "Täglicher Check", "0 9 * * *", "täglich 9 Uhr", "Prüfen", 1,
                                         None, now_iso()))
    st = RunState()
    st.routine_id = rid
    tl = {x.schema["name"]: x for x in service._tools(bid, bid, 0, st)}
    n = len(FakeAgent.seen)
    tl["aufgabe_starten"].handler({"titel": "Check aus Routine", "auftrag": "Prüfe etwas"})
    tid = next(r["id"] for r in db.q("SELECT id FROM tasks WHERE title='Check aus Routine'"))
    row = tasks.row(tid)
    ok(row["routine_id"] == rid and row["origin"] == "routine", "Aufgabe kennt ihre Routine (origin routine)")
    wait_for(lambda: len(FakeAgent.seen) > n and tasks.row(tid)["state"] == "done", msg="Routine-Aufgabe fertig")
    idle(bid)
    t = get(tid)
    ok(t["review"] == "done" and t["column"] == "done", f"fertig → direkt Abgeschlossen ({t['column']})")
    ok(t["routine_id"] == rid and t["routine_title"] == "Täglicher Check", "Board zeigt den Routinen-Namen")
    # ohne Routine wie bisher „Zu prüfen“
    st2 = RunState()
    tl2 = {x.schema["name"]: x for x in service._tools(bid, bid, 0, st2)}
    n = len(FakeAgent.seen)
    tl2["aufgabe_starten"].handler({"titel": "Normale Aufgabe X", "auftrag": "Etwas"})
    nid = next(r["id"] for r in db.q("SELECT id FROM tasks WHERE title='Normale Aufgabe X'"))
    wait_for(lambda: len(FakeAgent.seen) > n and tasks.row(nid)["state"] == "done", msg="normale Aufgabe fertig")
    idle(bid)
    ok(get(nid)["column"] == "review" and get(nid).get("routine_id") is None, "ohne Routine: Zu prüfen")
    # fehlgeschlagene Routine-Aufgabe bleibt sichtbar
    db.q("UPDATE tasks SET review=NULL WHERE id=?", (tid,))
    tasks._finish(tasks.row(tid), "failed", None, None, error="Test")
    ok(get(tid)["column"] == "review", "fehlgeschlagene Routine-Aufgabe: Zu prüfen")
    # Routine ohne eigenes Modell: routine_id kommt trotzdem im Lauf an
    seen = {}
    orig = service.enqueue
    service.enqueue = lambda chat, actor, depth=0, opts=None: seen.update(opts or {})
    try:
        service.fire_routine(dict(service.db.routine_dict(db.one("SELECT * FROM routines WHERE id=?", (rid,)))))
    finally:
        service.enqueue = orig
    ok(seen.get("routine_id") == rid and "model" not in seen, f"Routine-Lauf trägt routine_id auch ohne Modell ({seen})")


def test_waiting_badge(bid: str) -> None:
    print("Kennzeichen „wartet auf dich“ und scoop_schreiben im Aufgabenmodus")
    from types import SimpleNamespace
    from aisbot.db import now_iso
    ok(service.bot_json(bid)["waiting"] is False, "ohne offene Freigabe: wartet nicht")
    db.q("INSERT INTO approvals(id,bot_id,message_id,title,details,state,created_at,chat_id) VALUES(?,?,?,?,?,?,?,?)",
         ("a_wait_test", bid, "m_x", "Test", "", "pending", now_iso(), bid))
    ok(service.bot_json(bid)["waiting"] is True, "offene Freigabe → wartet auf dich")
    db.q("UPDATE approvals SET created_at=? WHERE id='a_wait_test'", ("2026-01-01T10:00:00+01:00",))
    ok(service.bot_json(bid)["waiting"] is False, "liegengebliebene alte Freigabe (> 48 h) zählt nicht")
    db.q("DELETE FROM approvals WHERE id='a_wait_test'")
    tid = next(r["id"] for r in db.q("SELECT id FROM tasks WHERE chat_id=? AND state='done' LIMIT 1", (bid,)))
    db.q("UPDATE tasks SET state='waiting' WHERE id=?", (tid,))
    ok(service.bot_json(bid)["waiting"] is True, "Aufgabe mit Rückfrage/Freigabe → wartet auf dich")
    db.q("UPDATE tasks SET state='done' WHERE id=?", (tid,))
    run = SimpleNamespace(task={"id": "t_x", "chat_id": bid, "bot_id": bid, "workdir": tempfile.mkdtemp(), "title": "T"},
                          progress=SimpleNamespace(update=lambda **_: None, line=lambda *_: None), pending=None)
    ok("scoop_schreiben" in tasks.tools_for(run), "Aufgaben dürfen anderen Scoops schreiben")
    from aisbot.bots import RunState
    chat = {x.schema["name"] for x in service._tools(bid, bid, 0, RunState())}
    have = set(tasks.tools_for(run))
    missing = chat - have - tasks_mod.TASK_EXCLUDED
    ok(not missing, f"Aufgabe hat alle Chat-Werkzeuge außer den Aufgaben-Steuerungen (fehlend: {sorted(missing)})")
    ok(not (have & {"aufgabe_starten", "reagieren"}), "keine Aufgabe in der Aufgabe, keine Emoji-Reaktion")
    other = next(r for r in db.q("SELECT id, name FROM bots WHERE id!=?", (bid,)))
    sent = []
    orig = service.enqueue
    service.enqueue = lambda chat, actor, depth=0, opts=None: sent.append((chat, depth))
    try:
        out = tasks.tools_for(run)["scoop_schreiben"].handler({"name": other["name"], "nachricht": "Kurze Frage aus der Aufgabe"})
    finally:
        service.enqueue = orig
    ok("geschickt" in out and sent and sent[0][0] == other["id"],
       f"Aufgabe kann einem anderen Scoop schreiben (kein falsches Nachrichtenlimit: {out[:60]})")


def test_task_waits_for_peer(bid: str) -> None:
    print("Aufgabe schreibt einem anderen Scoop und wartet auf dessen Antwort, dann macht sie damit weiter")
    from types import SimpleNamespace
    other = next(r for r in db.q("SELECT id, name FROM bots WHERE id!=?", (bid,)))
    t = tasks.start(bid, bid, "Peer-Test", "Frag den anderen Scoop", origin="board")
    wait_for(lambda: tasks.row(t["id"])["state"] == "done", msg="Peer-Test fertig")
    idle(bid)
    row = tasks.row(t["id"])
    run = SimpleNamespace(task=row, progress=SimpleNamespace(update=lambda **_: None, line=lambda *_: None), pending=None)
    sent = []
    orig = service.enqueue
    service.enqueue = lambda chat, actor, depth=0, opts=None: sent.append((chat, actor, opts))
    try:
        out = tasks.tools_for(run)["scoop_schreiben"].handler({"name": other["name"], "nachricht": "Wie viel ist 2+2?"})
    finally:
        service.enqueue = orig
    ok(run.pending and json.loads(run.pending)["kind"] == "scoop", "Aufgabe pausiert und wartet auf den anderen Scoop")
    ok("Hör jetzt auf" in out and sent and sent[0][2]["peer"]["task_id"] == t["id"], "Anfrage trägt die Aufgaben-ID")
    # Zustand „wartet“ wie nach dem Lauf setzen, dann Antwort zustellen
    db.q("UPDATE tasks SET state='waiting', pending=? WHERE id=?", (run.pending, t["id"]))
    ok(service.bot_json(bid)["waiting"] is False, "Warten auf einen Scoop zeigt kein rotes „?“ (wartet nicht auf dich)")
    n = len(FakeAgent.seen)
    ok(tasks.deliver_peer_reply(t["id"], other["name"], "4", bid, bid), "Antwort geht in die Aufgabe")
    wait_for(lambda: len(FakeAgent.seen) > n, msg="Aufgabe fortgesetzt")
    ok(FakeAgent.seen[-1][0] == t["id"] and "Antwort von" in FakeAgent.seen[-1][2] and "4" in FakeAgent.seen[-1][2], "Aufgabe macht mit der Antwort weiter")
    wait_for(lambda: tasks.row(t["id"])["state"] == "done", msg="fertig")
    idle(bid)
    ok(not tasks.deliver_peer_reply(t["id"], other["name"], "noch was", bid, bid), "fertige Aufgabe: Antwort geht wie bisher in den Chat")


if __name__ == "__main__":
    start_server()
    test_migration()
    bid = make_bot("Codi")
    other = make_bot("Tina")
    tid = test_review_flow(bid)
    test_rework(bid, tid)
    test_planned(bid)
    test_scheduler(bid)
    test_backlog(bid)
    test_routine_tasks(bid)
    test_waiting_badge(bid)
    test_task_waits_for_peer(bid)
    test_list_and_guests(bid, other)
    test_chat(bid)
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
