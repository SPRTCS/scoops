"""Test für die Seite „Heute“ und das Freigaben-Postfach (today.py, docs/API.md „Seite Heute“):
`GET /api/approvals` (offene Freigaben über Einzelchats, Gruppen und Aufgaben; Entscheidung, Ablauf, gelöschter
Scoop, gelöschte Gruppe, geleerter Verlauf), `GET /api/today` (Aufgaben je Abschnitt, laufende Chat-Läufe, heute
geplante Routinen und Erinnerungen, seit dem letzten Besuch Erledigtes), Health-Feld `today`, Gast-Ausschluss.

Läuft in beiden Editionen: erst `personal`, danach startet sich der Test selbst noch einmal mit
`AISBOT_EDITION=standard`. Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Agenten ohne KI-Aufruf) –
niemals die Produktion.

    cd Server && uv run python tests/test_today.py
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
from datetime import datetime, timedelta
from pathlib import Path

CHILD = os.environ.get("AISBOT_TODAY_TEST_CHILD") == "1"
EDITION = "standard" if CHILD else "personal"
TMP = Path(tempfile.mkdtemp(prefix=f"aisbot-today-test-{EDITION}-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION=EDITION, AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_KEYCHAIN_PREFIX="aisbot-today-test",
                  AISBOT_SKIP_CONVEX="1")
for k in ("AISBOT_DATA", "AISBOT_CONFIG"):
    os.environ.pop(k, None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import abos, profile, server, today  # noqa: E402
from aisbot.bots import RunState  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.db import TZ, new_id, now_iso  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

# Unabhängig vom Rechner: so tun, als wären API-Schlüssel hinterlegt (sonst hängt der Start am Schlüsselbund).
abos.mode = lambda name: "api"
abos.has_api_key = lambda name: True

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
    @classmethod
    def run(cls, **kw):
        u = Usage(kw["model"])
        u.input_tokens = 10
        book = UsageBook()
        book.by_model[kw["model"]] = u
        return Outcome("Antwort vom Scoop", "end_turn", book, [], False, kw["model"], 1, list(kw.get("messages") or []))


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


class FakeAgent:
    """Ersetzt _run_claude/_run_openai: zwei Schritte, dann fertig."""

    @classmethod
    def run(cls, run, message):
        for step in ("Liest Quellen", "Schreibt Bericht.md"):
            run.progress.line(step)
        return "Fertig.", "end"


tasks._run_claude = FakeAgent.run
tasks._run_openai = FakeAgent.run


def start_server() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(_up, msg="Server startet")


def _up() -> bool:
    try:
        return http.get("/api/health", headers=H).status_code == 200
    except httpx.HTTPError:
        return False


def make_bot(name: str) -> str:
    r = http.post("/api/bots", headers=H, json={"name": name, "mascot": MASCOT, "model": "claude-haiku-5-5"})
    bid = r.json()["id"]
    wait_for(lambda: bid not in service.runs, msg="Begrüßung fertig")
    return bid


def idle() -> None:
    wait_for(lambda: not service.runs and not tasks.runs, timeout=20, msg="alles ruhig")


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def inbox() -> dict:
    r = http.get("/api/approvals", headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def ids() -> list[str]:
    return [a["id"] for a in inbox()["approvals"]]


def page(**params) -> dict:
    r = http.get("/api/today", headers=H, params=params)
    assert r.status_code == 200, r.text
    return r.json()


def card(chat_id: str, actor: str, title: str, action: dict | None = None, extra: dict | None = None,
         always: tuple[str, str] | None = None) -> str:
    """Freigabe-Karte wie ein Werkzeug des Scoops anlegen; gibt die Freigabe-ID zurück."""
    before = {r["id"] for r in db.q("SELECT id FROM approvals")}
    service._ask_card(chat_id, actor, None, title, f"Details zu {title}", action, extra, always)
    return next(r["id"] for r in db.q("SELECT id FROM approvals ORDER BY rowid DESC") if r["id"] not in before)


def age(aid: str, hours: float) -> None:
    db.q("UPDATE approvals SET created_at=? WHERE id=?", (iso(datetime.now(TZ) - timedelta(hours=hours)), aid))


def add_task(chat_id: str, actor: str, title: str, state: str, review: str | None = None, pending: dict | None = None,
             finished: datetime | None = None, scheduled: datetime | None = None) -> str:
    """Aufgabe direkt in die Tabelle legen (ohne Lauf), wie sie nach einem Lauf dasteht."""
    tid = new_id("t")
    ts = now_iso()
    (TMP / "tasks" / tid).mkdir(parents=True, exist_ok=True)  # Arbeitsordner (Anhalten beim Löschen des Scoops liest ihn)
    db.q("INSERT INTO tasks(id,bot_id,chat_id,title,prompt,origin,engine,model,state,workdir,budget_usd,max_minutes,"
         "pending,created_at,started_at,finished_at,updated_at,review,scheduled_at) "
         "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
         (tid, actor, chat_id, title, f"Auftrag: {title}", "board", "claude", "claude-haiku-5-5", state,
          str(TMP / "tasks" / tid), 3.0, 60, json.dumps(pending) if pending else None, ts,
          None if state in ("scheduled", "open") else ts, iso(finished) if finished else None, ts, review,
          iso(scheduled) if scheduled else None))
    return tid


def add_routine(bot_id: str, title: str, kind: str = "routine", schedule: str = "0 * * * *", enabled: bool = True,
                next_run: datetime | None = None, last_run: datetime | None = None) -> str:
    rid = new_id("rt")
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,last_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
         (rid, bot_id, kind, title, schedule, "Stündlich" if kind == "routine" else "", f"Auftrag {title}", int(enabled),
          iso(next_run) if next_run else None, iso(last_run) if last_run else None, now_iso()))
    return rid


# -- 1. Leerer Server -----------------------------------------------------------------------------------------------
def test_empty() -> None:
    print(f"Edition {EDITION}: Health und leerer Zustand")
    ok(profile.edition() == EDITION, f"Edition {EDITION} aktiv")
    h = http.get("/api/health", headers=H).json()
    ok(h.get("today") is True, "Health meldet die Seite „Heute“ (today: true)")
    ok(inbox() == {"approvals": [], "count": 0}, "ohne Freigaben: leeres Postfach")
    p = page()
    ok(p["approvals"] == [] and p["tasks"] == [] and p["running"] == [] and p["planned"] == []
       and p["routines_done"] == [], "Seite ohne Inhalt: alle Abschnitte leer")
    ok(all(v == 0 for v in p["counts"].values()), f"alle Zähler 0 ({p['counts']})")
    now, since, end = (datetime.fromisoformat(p[k]) for k in ("now", "since", "day_end"))
    ok(timedelta(hours=23, minutes=59) < now - since <= timedelta(hours=24) and end.date() == now.date(),
       "ohne `since`: die letzten 24 Stunden, „heute“ endet um Mitternacht")
    ok(http.get("/api/approvals").status_code == 401 and http.get("/api/today").status_code == 401,
       "ohne Token → 401")


# -- 2. Freigaben-Postfach --------------------------------------------------------------------------------------------
def test_inbox(mila: str, theo: str, gid: str) -> dict:
    print("Freigaben-Postfach: Einzelchat, Gruppe, Aufgabe")
    a1 = card(mila, mila, "Post auf X veröffentlichen", always=("x-posten", "Auf X posten"))
    a2 = card(theo, theo, "Mail an Jonas senden",
              {"kind": "mail", "app": "gmail", "account": "arbeit", "to": ["jonas@example.org"], "subject": "Hallo", "body": "Text"},
              {"kind": "mail", "mail": {"to": ["jonas@example.org"], "subject": "Hallo", "body": "Text", "status": "draft"}})
    a3 = card(gid, theo, "Ordner aufräumen")
    box = inbox()
    ok(box["count"] == 3 and [a["id"] for a in box["approvals"]] == [a3, a2, a1], "drei offene Freigaben, neueste zuerst")
    by = {a["id"]: a for a in box["approvals"]}
    ok(by[a1]["chat_id"] == mila and by[a1]["bot_id"] == mila and by[a1]["kind"] == "freigabe",
       "Einzelchat: Chat und Scoop, Art „freigabe“")
    m1 = by[a1]["message"]
    ok(m1["role"] == "approval" and m1["bot_id"] == mila and m1["meta"]["approval_id"] == a1
       and m1["meta"]["state"] == "pending" and m1["meta"]["can_always"] is True,
       "vollständige Karten-Nachricht dabei (für dieselben Karten wie im Chat, inkl. „Immer erlauben“)")
    ok(by[a2]["kind"] == "mail" and by[a2]["message"]["meta"]["mail"]["subject"] == "Hallo", "Mail-Karte mit Entwurf")
    ok(by[a3]["chat_id"] == gid and by[a3]["bot_id"] == theo and by[a3]["message"]["meta"]["author_id"] == theo,
       "Gruppe: Chat ist die Gruppe, Scoop ist der Fragende")
    ok(by[a1]["expires_at"] and by[a1]["task_id"] is None and by[a1]["task_title"] is None,
       "Chat-Freigabe: mit Frist, ohne Aufgabe")
    exp = datetime.fromisoformat(by[a1]["expires_at"]) - datetime.fromisoformat(by[a1]["created_at"])
    ok(exp == service.WAITING_MAX_AGE, "Frist = 48 Stunden wie beim roten „?“")
    ok(page()["counts"]["approvals"] == 3 and len(page()["approvals"]) == 3, "GET /api/today enthält dieselben Freigaben")

    print("Freigaben-Postfach: Hintergrund-Aufgabe")
    tid = add_task(mila, mila, "Belege abgleichen", "waiting", pending={"kind": "freigabe", "text": "Zahlung auslösen"})
    a4 = card(mila, mila, "Zahlung auslösen", {"kind": "task", "task_id": tid})
    db.q("UPDATE approvals SET task_id=? WHERE id=?", (tid, a4))
    e = next(a for a in inbox()["approvals"] if a["id"] == a4)
    ok(e["task_id"] == tid and e["task_title"] == "Belege abgleichen", "Freigabe aus einer Aufgabe nennt die Aufgabe")
    ok(e["expires_at"] is None, "Aufgabe hält wegen der Karte an: keine Frist")
    age(a4, 72)
    ok(a4 in ids(), "… und bleibt auch nach 48 Stunden offen")
    db.q("UPDATE tasks SET state='stopped', review='review' WHERE id=?", (tid,))
    ok(a4 not in ids(), "Aufgabe wartet nicht mehr: alte Karte zählt nicht mehr")
    db.q("UPDATE approvals SET state='declined' WHERE id=?", (a4,))
    db.q("DELETE FROM tasks WHERE id=?", (tid,))
    return {"a1": a1, "a2": a2, "a3": a3}


def test_decisions(mila: str, theo: str, gid: str, a: dict) -> None:
    print("Zähler stimmt: Entscheidung, Ablauf, Verlauf geleert, Gruppe und Scoop gelöscht")
    events: list[tuple[str, dict]] = []
    orig = service.publish
    service.publish = lambda typ, data: (events.append((typ, data)), orig(typ, data))[1]
    try:
        r = http.post(f"/api/approvals/{a['a1']}", headers=H, json={"decision": "decline"})
    finally:
        service.publish = orig
    ok(r.status_code == 200 and r.json()["meta"]["state"] == "declined", "Ablehnen über die API")
    ok(a["a1"] not in ids() and inbox()["count"] == 2, "entschiedene Freigabe verschwindet sofort aus dem Postfach")
    ok(any(t == "message.updated" and d["meta"].get("approval_id") == a["a1"] and d["meta"]["state"] == "declined"
           for t, d in events), "andere Geräte erfahren es über message.updated")
    ok(any(t == "bot.updated" and d["id"] == mila and d["waiting"] is False for t, d in events),
       "bot.updated meldet „wartet nicht mehr“")
    idle()

    age(a["a2"], 47)
    ok(a["a2"] in ids(), "47 Stunden alt: noch offen")
    age(a["a2"], 49)
    ok(a["a2"] not in ids() and inbox()["count"] == 1, "nach 48 Stunden abgelaufen: zählt nicht mehr")
    age(a["a2"], 1)
    ok(a["a2"] in ids(), "(Frist zurückgesetzt)")

    # Computer-Use-Karte, auf die niemand mehr wartet
    a5 = card(theo, theo, "Computer Use: Safari", {"kind": "codex_cu", "app": "Safari", "wait": "tok-heute"})
    ok(a5 in ids(), "Computer-Use-Karte offen")
    service._expire_cu_card("tok-heute", "abgelaufen")
    ok(a5 not in ids(), "abgelaufene Computer-Use-Karte verschwindet")

    # Karte, deren Nachricht schon entschieden aussieht (z. B. nach einem Absturz mitten in der Entscheidung)
    a6 = card(theo, theo, "Halb entschieden")
    row = db.one("SELECT * FROM approvals WHERE id=?", (a6,))
    meta = json.loads(db.one("SELECT meta FROM messages WHERE id=?", (row["message_id"],))["meta"])
    db.update_message(row["message_id"], meta={**meta, "state": "approved"})
    ok(a6 not in ids(), "Karte zeigt schon „freigegeben“: nicht mehr im Postfach")
    db.q("UPDATE approvals SET state='approved' WHERE id=?", (a6,))

    r = http.post(f"/api/bots/{theo}/reset", headers=H)
    ok(r.status_code == 200 and a["a2"] not in ids(), "Verlauf geleert: Karten des Chats sind weg")
    ok(service.bot_json(theo)["waiting"] is False, "… und das rote „?“ auch")
    ok(ids() == [a["a3"]], "übrig: die Freigabe in der Gruppe")

    a7 = card(gid, mila, "Zweite Gruppen-Freigabe")
    ok(set(ids()) == {a["a3"], a7}, "zwei Freigaben in der Gruppe")
    http.delete(f"/api/bots/{theo}", headers=H)
    ok(ids() == [a7], "Scoop gelöscht: seine Freigabe in der Gruppe zählt nicht mehr")
    http.delete(f"/api/groups/{gid}", headers=H)
    ok(inbox() == {"approvals": [], "count": 0}, "Gruppe gelöscht: Postfach leer")
    idle()


# -- 3. Seite „Heute“ --------------------------------------------------------------------------------------------------
def test_page(mila: str, nora: str) -> None:
    print("Seite „Heute“: Aufgaben je Abschnitt")
    # Fester Zeitpunkt morgen 10:00: unabhängig von der Uhrzeit des Testlaufs, und der Planer startet nichts davon
    base = (datetime.now(TZ) + timedelta(days=1)).replace(hour=10, minute=0, second=0, microsecond=0)

    def view(since=None) -> dict:
        return today.overview(service, since, now=base)

    r = http.post("/api/tasks", headers=H, json={"chat_id": mila, "prompt": "Recherchiere Pinguine.", "title": "Pinguine"})
    t_review = r.json()["id"]
    wait_for(lambda: tasks.row(t_review)["state"] == "done", msg="Aufgabe fertig")
    idle()
    t_problem = add_task(nora, nora, "CRM-Abgleich", "failed", review="review", finished=base - timedelta(hours=1))
    t_frage = add_task(nora, nora, "Belege Oktober", "waiting", pending={"kind": "frage", "text": "Nachfragen?"})
    t_scoop = add_task(nora, nora, "Wartet auf Mila", "waiting", pending={"kind": "scoop", "text": "Mila"})
    t_run = add_task(mila, mila, "Launch-Post", "running")
    t_today = add_task(mila, mila, "Wochenrückblick", "scheduled", scheduled=base + timedelta(hours=5))
    t_later = add_task(mila, mila, "Übermorgen", "scheduled", scheduled=base + timedelta(days=1))
    t_open = add_task(mila, mila, "Nur gesammelt", "open")
    t_done = add_task(nora, nora, "Reiseplan", "done", review="done", finished=base - timedelta(hours=3))
    t_old = add_task(nora, nora, "Alter Bericht", "done", review="done", finished=base - timedelta(hours=40))
    t_arch = add_task(nora, nora, "Archiviert", "done", review="archived", finished=base - timedelta(hours=2))

    p = view()
    by = {t["id"]: t for t in p["tasks"]}
    ok({t_review, t_problem} <= set(by) and by[t_review]["column"] == "review" and by[t_problem]["column"] == "review",
       "Zum Prüfen: fertige Aufgabe und Aufgabe mit Problem")
    ok(by[t_review]["steps"] == 2, "Aufgaben wie im Board (mit Schritten)")
    ok(by[t_frage]["state"] == "waiting" and by[t_frage]["waiting_kind"] == "frage" and by[t_frage]["waiting_for"] == "Nachfragen?",
       "Rückfrage einer Aufgabe ist dabei")
    ok(t_run in by and by[t_run]["column"] == "active", "Läuft gerade: laufende Aufgabe")
    ok(t_today in by and by[t_today]["column"] == "planned", "Heute geplant: Aufgabe mit Termin heute")
    ok(t_later not in by and t_open not in by, "Termin an einem anderen Tag und „Offen“ erscheinen nicht")
    ok(t_done in by and by[t_done]["column"] == "done", "Seit gestern erledigt: abgenommene Aufgabe der letzten 24 Stunden")
    ok(t_old not in by and t_arch not in by, "älter als 24 Stunden bzw. archiviert: nicht dabei")
    c = p["counts"]
    ok(c["review"] == 2 and c["questions"] == 1 and c["waiting"] == c["approvals"] + 1,
       f"Zähler: 2 zu prüfen, 1 Rückfrage (Warten auf einen Scoop zählt nicht) ({c})")
    ok(t_scoop in by and c["running"] == 1, "Warten auf einen anderen Scoop: in der Liste, aber weder „läuft“ noch „wartet auf dich“")

    print("Seite „Heute“: seit dem letzten Besuch")
    p = view(iso(base - timedelta(days=2)))
    ok(t_old in {t["id"] for t in p["tasks"]} and datetime.fromisoformat(p["since"]) == base - timedelta(days=2),
       "letzter Besuch vor zwei Tagen: Erledigtes seitdem")
    p = view(iso(base - timedelta(hours=2)))
    ok(datetime.fromisoformat(p["since"]) == base - timedelta(hours=24), "letzter Besuch vor zwei Stunden: trotzdem 24 Stunden")
    p = view(iso(base - timedelta(days=30)))
    ok(datetime.fromisoformat(p["since"]) == base - timedelta(days=7), "höchstens 7 Tage zurück")
    ok(datetime.fromisoformat(view("kein Datum")["since"]) == base - timedelta(hours=24), "unlesbares `since` wie keines")
    r = http.get("/api/today", headers=H, params={"since": iso(datetime.now(TZ) - timedelta(days=3))})
    got = datetime.now(TZ) - datetime.fromisoformat(r.json()["since"])
    ok(r.status_code == 200 and timedelta(days=2, hours=23) < got < timedelta(days=3, minutes=1), "`since` als Parameter der API")

    print("Seite „Heute“: Routinen und Erinnerungen")
    r_hour = add_routine(mila, "Mail-Check", next_run=base + timedelta(hours=2))          # 12:00, danach 13 … 23 Uhr
    r_rem = add_routine(nora, "Steuerbüro anrufen", kind="erinnerung", schedule=iso(base + timedelta(hours=3)),
                        next_run=base + timedelta(hours=3))
    r_off = add_routine(mila, "Ausgeschaltet", enabled=False, next_run=base + timedelta(hours=1))
    r_tom = add_routine(mila, "Morgen früh", schedule="30 7 * * *", next_run=base + timedelta(hours=21, minutes=30))
    r_ran = add_routine(nora, "Morgenbriefing", schedule="30 7 * * *", next_run=base + timedelta(hours=21, minutes=30),
                        last_run=base - timedelta(hours=2, minutes=30))
    r_fired = add_routine(nora, "Zahnarzt", kind="erinnerung", schedule=iso(base - timedelta(hours=5)), enabled=False,
                          last_run=base - timedelta(hours=5))
    r_longago = add_routine(mila, "Wochenbericht", schedule="0 9 * * 1", next_run=base + timedelta(days=5),
                            last_run=base - timedelta(days=2))
    p = view()
    ok([x["id"] for x in p["planned"]] == [r_hour, r_rem], "Heute geplant: Routine und Erinnerung, nach Uhrzeit")
    first = p["planned"][0]
    ok(first["bot_id"] == mila and first["kind"] == "routine" and first["title"] == "Mail-Check"
       and datetime.fromisoformat(first["at"]) == base + timedelta(hours=2), "Eintrag mit Scoop, Art, Titel und Uhrzeit")
    ok(first["more_today"] == 11 and p["planned"][1]["more_today"] == 0,
       f"stündliche Routine: heute noch 11 weitere Läufe, Erinnerung keine ({first['more_today']})")
    ok(r_off not in [x["id"] for x in p["planned"]] and r_tom not in [x["id"] for x in p["planned"]],
       "ausgeschaltete Routine und Lauf morgen: nicht dabei")
    ok([x["id"] for x in p["routines_done"]] == [r_ran, r_fired], "gelaufen: Routine und Erinnerung der letzten 24 Stunden, neueste zuerst")
    ok(r_longago in [x["id"] for x in view(iso(base - timedelta(days=3)))["routines_done"]],
       "seit dem letzten Besuch: auch der Lauf vor zwei Tagen")
    ok(p["counts"]["planned"] == 3 and p["counts"]["done"] == 3, f"Zähler geplant/erledigt zählen Aufgaben mit ({p['counts']})")

    print("Seite „Heute“: laufende Chat-Läufe")
    st = RunState()
    st.current = mila
    status = db.add_message(mila, "status", "", {"run_id": "r_heute", "state": "running",
                                                 "lines": ["Schaut in den Kalender", "Öffnet Safari"],
                                                 "uses_computer": True, "started_at": now_iso()})
    task_status = db.add_message(nora, "status", "", {"state": "running", "lines": ["Liest"], "task": {"id": t_frage}})
    service.runs[mila] = st
    service.runs[nora] = RunState()
    try:
        run = view()["running"]
        ok(len(run) == 1 and run[0]["chat_id"] == mila and run[0]["bot_id"] == mila and run[0]["line"] == "Öffnet Safari"
           and run[0]["steps"] == 2 and run[0]["uses_computer"] is True and run[0]["message_id"] == status["id"],
           "Chat-Lauf mit letzter Statuszeile; die Statuskarte einer Aufgabe zählt hier nicht")
        ok(view()["counts"]["running"] == 2, "Zähler „läuft“: Chat-Lauf + laufende Aufgabe")
    finally:
        service.runs.pop(mila, None)
        service.runs.pop(nora, None)
    meta = json.loads(db.one("SELECT meta FROM messages WHERE id=?", (status["id"],))["meta"])
    db.update_message(status["id"], meta={**meta, "state": "done"})
    db.q("DELETE FROM messages WHERE id=?", (task_status["id"],))
    ok(view()["running"] == [], "Lauf beendet: nichts läuft mehr")

    http.delete(f"/api/bots/{nora}", headers=H)
    p = view()
    ok(all(x["bot_id"] != nora for x in p["planned"] + p["routines_done"]), "Scoop gelöscht: seine Routinen sind weg")
    ok(all(t["chat_id"] != nora for t in p["tasks"]), "… und seine Aufgaben erscheinen nicht mehr")


# -- 4. Gäste ------------------------------------------------------------------------------------------------------------
def test_guests(mila: str) -> None:
    print("Gäste geteilter Scoops bekommen die Seite nicht")
    card(mila, mila, "Nur für den Admin")
    orig_verify, orig_owner = server.cloud.verify_any, server.cloud.owner_id
    server.cloud.verify_any = lambda tok: {"sub": "u_gast", "sid": "s1"} if tok == "gast-jwt" else None
    server.cloud.owner_id = lambda: "u_admin"
    try:
        G = {"Authorization": "Bearer gast-jwt"}
        ok(http.get("/api/approvals", headers=G).status_code == 403, "Gast: Freigaben-Postfach → 403")
        ok(http.get("/api/today", headers=G).status_code == 403, "Gast: Seite „Heute“ → 403")
        ok(http.get("/api/health", headers=G).status_code == 403, "Gast: Health (mit dem Feld `today`) → 403")
    finally:
        server.cloud.verify_any, server.cloud.owner_id = orig_verify, orig_owner
    ok(inbox()["count"] == 1, "der Admin sieht die Freigabe")


if __name__ == "__main__":
    start_server()
    for r in db.bots():  # Edition „standard“ legt einen Start-Scoop an; der Test beginnt ohne Scoops
        service.delete_bot(r["id"])
    test_empty()
    mila, theo, nora = make_bot("Mila"), make_bot("Theo"), make_bot("Nora")
    gid = http.post("/api/groups", headers=H, json={"name": "Team", "member_ids": [mila, theo]}).json()["id"]
    cards = test_inbox(mila, theo, gid)
    test_decisions(mila, theo, gid, cards)
    test_page(mila, nora)
    test_guests(mila)
    total = passed
    if not CHILD:
        print("\nNoch einmal mit der Edition „standard“ …", flush=True)
        res = subprocess.run([sys.executable, __file__], env={**os.environ, "AISBOT_TODAY_TEST_CHILD": "1"},
                             capture_output=True, text=True, timeout=240)
        tail = [line for line in res.stdout.splitlines() if line.strip()]
        if res.returncode != 0:
            print(res.stdout[-3000:], res.stderr[-3000:], sep="\n")
            raise SystemExit("Edition „standard“ fehlgeschlagen")
        child = int(tail[-1].split()[1])
        print(f"  ✓ Edition „standard“: {child} Prüfungen bestanden")
        total += child
    print(f"\nAlle {total} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
