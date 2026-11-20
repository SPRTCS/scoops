"""Seite „Heute“ der App: offene Freigaben über alle Chats und Aufgaben und ein gebündelter Überblick.

`pending_approvals` beantwortet `GET /api/approvals`, `overview` beantwortet `GET /api/today` (docs/API.md, „Seite
Heute“). Beides nur für den Inhaber: Freigaben entscheidet allein der Admin, und Aufgaben, Routinen und Gruppen sehen
Gäste geteilter Scoops ohnehin nicht (server.py hängt beide Endpunkte an `auth`).

Alles wird aus der Datenbank und dem Laufzustand gelesen, der Aufruf ändert nichts. Live bleibt die Seite über die
vorhandenen Ereignisse (`message.created/updated`, `bot.updated`, `group.updated`, `task.updated`, `routine.updated`).
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta

from croniter import croniter

from .bots import is_group
from .db import TZ
from .tasks import FINAL, OPEN, parse_when

# „Seit gestern erledigt“: mindestens die letzten 24 Stunden; war der letzte Besuch länger her, seitdem (höchstens 7 Tage)
DONE_WINDOW = timedelta(hours=24)
DONE_MAX_BACK = timedelta(days=7)
# Grenzen, damit die Antwort auch auf einem lange genutzten Server klein bleibt
MAX_APPROVALS = 200
MAX_REVIEW = 100
MAX_DONE = 100
MAX_MORE_TODAY = 48


def _iso(dt: datetime | None) -> str | None:
    return dt.astimezone(TZ).isoformat(timespec="seconds") if dt else None


def _meta(row) -> dict:
    try:
        d = json.loads(row["meta"] or "{}")
    except (TypeError, ValueError):
        d = {}
    return d if isinstance(d, dict) else {}


def pending_approvals(svc, now: datetime | None = None) -> list[dict]:
    """Offene Freigaben über alle Einzelchats, Gruppen und Hintergrund-Aufgaben, neueste zuerst.

    „Offen“ wie beim roten „?“ (`BotService.waiting_on_user`): Karte steht auf `pending` und ist jünger als 48 Stunden;
    ältere gelten als liegengeblieben. Hält eine Aufgabe wegen der Karte an, bleibt sie ohne Frist offen. Karten, deren
    Chat, Scoop oder Nachricht es nicht mehr gibt (Scoop gelöscht, Verlauf geleert), zählen nicht.
    """
    db = svc.db
    now = now or datetime.now(TZ)
    out: list[dict] = []
    for a in db.q("SELECT * FROM approvals WHERE state='pending' ORDER BY created_at DESC, rowid DESC"):
        chat_id = a["chat_id"] or a["bot_id"]
        if not svc.chat_exists(chat_id) or not db.bot_row(a["bot_id"]):
            continue
        msg = db.one("SELECT * FROM messages WHERE id=?", (a["message_id"],))
        if not msg or msg["role"] != "approval":
            continue
        meta = _meta(msg)
        if meta.get("state", "pending") != "pending":
            continue
        task = svc.tasks.row(a["task_id"]) if svc.tasks and a["task_id"] else None
        created = parse_when(a["created_at"], strict=False) or now
        # Aufgabe wartet genau auf diese Art Entscheidung: keine Frist
        holds_task = bool(task and task["state"] == "waiting")
        expires = None if holds_task else created + svc.WAITING_MAX_AGE
        if expires is not None and expires <= now:
            continue
        out.append({
            "id": a["id"], "chat_id": chat_id, "bot_id": a["bot_id"], "kind": meta.get("kind") or "freigabe",
            "title": a["title"], "created_at": a["created_at"], "expires_at": _iso(expires),
            "task_id": task["id"] if task else None, "task_title": task["title"] if task else None,
            "requested_by": (meta.get("requested_by") or {}).get("name"),
            "message": db.msg_dict(msg),
        })
        if len(out) >= MAX_APPROVALS:
            break
    return out


def chat_runs(svc) -> list[dict]:
    """Chat-Läufe, die gerade arbeiten (ohne Hintergrund-Aufgaben, die stehen in `tasks`), mit letzter Statuszeile.
    Stille Läufe (Initiative) haben keine Statuskarte und erscheinen nicht."""
    db = svc.db
    out: list[dict] = []
    for chat_id, st in list(svc.runs.items()):
        if not svc.chat_exists(chat_id):
            continue
        status = None
        for r in db.q("SELECT * FROM messages WHERE bot_id=? AND role='status' ORDER BY seq DESC LIMIT 8", (chat_id,)):
            meta = _meta(r)
            if meta.get("state") == "running" and not meta.get("task"):
                status = (r, meta)
                break
        if not status:
            continue
        r, meta = status
        lines = meta.get("lines") or []
        actor = meta.get("author_id") or st.current or (None if is_group(chat_id) else chat_id)
        out.append({"chat_id": chat_id, "bot_id": actor, "run_id": meta.get("run_id"), "message_id": r["id"],
                    "line": lines[-1] if lines else None, "steps": len(lines),
                    "started_at": meta.get("started_at") or r["created_at"],
                    "uses_computer": bool(meta.get("uses_computer"))})
    out.sort(key=lambda x: x["started_at"] or "", reverse=True)
    return out


def planned_today(svc, now: datetime, day_end: datetime) -> list[dict]:
    """Routinen und Erinnerungen, die heute noch laufen (nächster Lauf bis Mitternacht Berliner Zeit), nach Uhrzeit.
    `more_today`: weitere Läufe derselben Routine heute nach dem nächsten. Geplante Aufgaben stehen in `tasks`."""
    db = svc.db
    out: list[dict] = []
    for r in db.routines():
        if not r.get("enabled") or not r.get("next_run") or not db.bot_row(r["bot_id"]):
            continue
        at = parse_when(r["next_run"], strict=False)
        if at is None or at > day_end:
            continue
        more = 0
        if r["kind"] != "erinnerung":
            try:
                it = croniter(r["schedule"], max(at, now))
                while more < MAX_MORE_TODAY and it.get_next(datetime) <= day_end:
                    more += 1
            except Exception:  # noqa: BLE001 – unlesbarer Zeitplan: nur der nächste Lauf
                more = 0
        out.append({"id": r["id"], "kind": r["kind"], "bot_id": r["bot_id"], "chat_id": r["bot_id"], "title": r["title"],
                    "at": _iso(at), "schedule_text": r.get("schedule_text") or "", "more_today": more})
    out.sort(key=lambda x: x["at"])
    return out


def routines_done(svc, since: datetime) -> list[dict]:
    """Routinen und Erinnerungen, die seit `since` gelaufen sind (je Routine der letzte Lauf), neueste zuerst."""
    db = svc.db
    out: list[dict] = []
    for r in db.routines():
        at = parse_when(r.get("last_run"), strict=False)
        if at is None or at < since or not db.bot_row(r["bot_id"]):
            continue
        out.append({"id": r["id"], "kind": r["kind"], "bot_id": r["bot_id"], "chat_id": r["bot_id"], "title": r["title"],
                    "at": _iso(at)})
    out.sort(key=lambda x: x["at"], reverse=True)
    return out[:MAX_DONE]


def page_tasks(svc, since: datetime, day_end: datetime) -> list[dict]:
    """Aufgaben, die die Seite zeigt: in Arbeit (auch wartend), „Zu prüfen“, heute noch geplant und seit `since`
    abgeschlossen. Die App ordnet sie selbst den Abschnitten zu und hält sie über `task.updated` aktuell."""
    db, tasks = svc.db, svc.tasks
    if not tasks:
        return []
    final = ",".join(f"'{s}'" for s in FINAL)
    rows: dict[str, dict] = {}
    for r in db.q(f"SELECT * FROM tasks WHERE state IN ({','.join(repr(s) for s in OPEN)})"):
        rows[r["id"]] = dict(r)
    for r in db.q(f"SELECT * FROM tasks WHERE state IN ({final}) AND (review IS NULL OR review='review') "
                  "ORDER BY finished_at DESC LIMIT ?", (MAX_REVIEW,)):
        rows[r["id"]] = dict(r)
    for r in db.q("SELECT * FROM tasks WHERE state='scheduled'"):
        when = parse_when(r["scheduled_at"], strict=False)
        if when is None or when <= day_end:
            rows[r["id"]] = dict(r)
    for r in db.q(f"SELECT * FROM tasks WHERE state IN ({final}) AND review='done' "
                  "ORDER BY finished_at DESC LIMIT ?", (MAX_DONE,)):
        done = parse_when(r["finished_at"], strict=False)
        if done is not None and done >= since:
            rows[r["id"]] = dict(r)
    out = [tasks.public(t) for t in rows.values() if svc.chat_exists(t["chat_id"])]
    out.sort(key=lambda t: t.get("created_at") or "", reverse=True)
    return out


def done_since(value, now: datetime) -> datetime:
    """Beginn von „Seit gestern erledigt“: 24 Stunden zurück; liegt der letzte Besuch (`since` der App) weiter
    zurück, dieser – höchstens 7 Tage. Unlesbare Werte zählen wie fehlende."""
    base = now - DONE_WINDOW
    visit = parse_when(value, strict=False) if value else None
    if visit is None or visit >= base:
        return base
    return max(visit, now - DONE_MAX_BACK)


def overview(svc, since=None, now: datetime | None = None) -> dict:
    """Alles für die Seite „Heute“ in einer Antwort."""
    now = now or datetime.now(TZ)
    day_end = now.replace(hour=23, minute=59, second=59, microsecond=0)
    start = done_since(since, now)
    approvals = pending_approvals(svc, now)
    tasks = page_tasks(svc, start, day_end)
    running = chat_runs(svc)
    planned = planned_today(svc, now, day_end)
    done = routines_done(svc, start)

    def col(name: str) -> list[dict]:
        return [t for t in tasks if t.get("column") == name]

    # Rückfragen von Aufgaben (keine Freigabe-Karte; die Antwort geht über den Chat)
    questions = [t for t in col("active") if t["state"] == "waiting" and t.get("waiting_kind") == "frage"]
    working = [t for t in col("active") if t["state"] in ("queued", "running")]
    return {
        "now": _iso(now), "since": _iso(start), "day_end": _iso(day_end),
        "approvals": approvals,
        "tasks": tasks,
        "running": running,
        "planned": planned,
        "routines_done": done,
        "counts": {
            "approvals": len(approvals),
            "questions": len(questions),
            "waiting": len(approvals) + len(questions),
            "review": len(col("review")),
            "running": len(running) + len(working),
            "planned": len(planned) + len(col("planned")),
            "done": len(done) + len(col("done")),
        },
    }
