"""Anbindung an T3 Code (Coding-Agenten) auf dem Air.

Scoops geben Programmieraufgaben an T3 ab, ähnlich wie Grok Bot an Cursor-Agenten. Gesteuert wird
über die T3-Kommandozeile (`~/.t3/bin/t3 thread …`) des laufenden T3-Servers auf diesem Mac.
Projekte werden nur lesend aus T3s lokaler Datenbank gelesen. Weitere Macs (MacBook Pro) sind
erreichbar, sobald sie in T3 als Umgebung verknüpft sind; der T3-Agent arbeitet dann dort.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess

T3 = os.path.expanduser("~/.t3/bin/t3")
STATE_DB = os.path.expanduser("~/.t3/userdata/statev2.sqlite")


def available() -> bool:
    return os.path.exists(T3)


def _run(args: list[str], stdin: str | None = None, timeout: float = 90) -> dict | list:
    r = subprocess.run([T3, *args, "--json"], input=stdin, capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/bin:/bin:" + os.environ.get("PATH", "")})
    if r.returncode not in (0, 2):
        raise RuntimeError((r.stderr or r.stdout).strip()[:400] or f"t3 Exitcode {r.returncode}")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Unerwartete Antwort von t3: {r.stdout[:200]}") from e


def projects() -> list[dict]:
    con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute("SELECT project_id, title, workspace_root FROM projection_projects "
                           "WHERE deleted_at IS NULL AND archived_at IS NULL ORDER BY title").fetchall()
    finally:
        con.close()
    return [{"id": r[0], "title": r[1], "path": r[2]} for r in rows if not r[2].endswith("/.t3/scratch")]


def find_project(key: str) -> dict | None:
    key_l = key.strip().lower()
    ps = projects()
    for p in ps:
        if key_l in (p["id"].lower(), p["title"].lower(), p["path"].lower()):
            return p
    hits = [p for p in ps if key_l in p["title"].lower() or key_l in p["path"].lower()]
    return hits[0] if len(hits) == 1 else None


def start(project_id: str, message: str, title: str | None = None) -> dict:
    args = ["thread", "start", project_id, "-"]
    if title:
        args += ["--title", title[:80]]
    d = _run(args, stdin=message)
    return d.get("thread", d) if isinstance(d, dict) else {}


def send(thread_id: str, message: str) -> dict:
    d = _run(["thread", "send", thread_id, "-"], stdin=message)
    return d if isinstance(d, dict) else {}


def show(thread_id: str, n: int = 2) -> dict:
    d = _run(["thread", "show", thread_id, "--messages", str(n)])
    return d if isinstance(d, dict) else {}


def list_threads(project_id: str) -> list[dict]:
    d = _run(["thread", "list", "--project", project_id])
    return d if isinstance(d, list) else []


def is_done(t: dict) -> bool:
    return bool(t.get("settled")) and not t.get("activeRunId")


def needs_answer(t: dict) -> bool:
    return int(t.get("pendingRequestCount") or 0) > 0


def scratch_project_id() -> str | None:
    """T3s Projekt „No project“ (Arbeitsordner ~/.t3/scratch) auf diesem Mac."""
    con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=5)
    try:
        r = con.execute("SELECT project_id FROM projection_projects WHERE workspace_root LIKE '%/.t3/scratch' "
                        "AND deleted_at IS NULL LIMIT 1").fetchone()
    finally:
        con.close()
    return r[0] if r else None
