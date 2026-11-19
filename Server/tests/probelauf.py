"""Probedurchlauf (docs/probelauf.md): spielt die wichtigsten Abläufe eines Scoops einmal komplett durch, über die
HTTP-API und die echten Werkzeug-Handler. Er findet Fehler im Zusammenspiel, die die Einzeltests nicht sehen
(z. B. fehlende Werkzeuge in Aufgaben, „Zu viele Nachrichten zwischen Scoops“ aus Aufgaben, „beschäftigt“ trotz
wartender Freigabe, Composio-Vorschau statt vollständiger Daten).

Zwei Stufen:
- offline (Standard): Testserver im Prozess mit Fake-Modell und Fake-Agent. Der Fake-Agent ruft die Werkzeuge so auf,
  wie es ein Modell täte: über den echten MCP-Endpunkt der Aufgaben (`/mcp/task`, tools/list und tools/call) bzw.
  über die Werkzeuge, die `service._tools` dem Chat-Lauf anbietet. Kostenlos, unter einer Minute.
- `--live`: eigener, frisch gestarteter Testserver (eigener Datenordner, eigener Port, Schlüsselbund-Präfix nur für
  den Test) mit echtem, günstigem Modell (claude-haiku-5-5). Kostet wenige Cent. Fasst nie Armans Server, Scoops,
  Chats oder Daten an und sendet nichts nach außen (Freigaben werden abgelehnt). Composio nur lesend, nur wenn
  verbunden.

    Server/bin/probelauf            # offline
    Server/bin/probelauf --live     # zusätzlich mit echtem Modell
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

SERVER_DIR = Path(__file__).resolve().parents[1]
SRC = SERVER_DIR / "src"
LIVE_MODEL = "claude-haiku-5-5"
PROD_PORT = 8787
PROD_DATA = Path.home() / ".local/share/ais-bot"
OVERSIGHT_TOOLS = {"scoops_ueberblick", "chat_lesen", "scoop_details", "scoop_verbessern"}
# Werkzeuge, die nur Aufgaben haben (tasks.tools_for legt sie selbst an). Alles andere muss dem Chat entsprechen.
TASK_ONLY = {"zwischenstand", "nachricht_an_nutzer", "rueckfrage_stellen", "datei_in_bibliothek", "datei_aus_bibliothek",
             "bildschirm_aufgabe", "app_werkzeug_suchen", "app_werkzeug_nutzen"}
TOO_MANY = "Zu viele Nachrichten"

COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
GREEN, RED, GREY, BOLD, RESET = (("\033[32m", "\033[31m", "\033[90m", "\033[1m", "\033[0m") if COLOR else ("",) * 5)


class Fail(AssertionError):
    pass


class Skip(Exception):
    pass


def check(cond, msg: str) -> None:
    if not cond:
        raise Fail(msg)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait(fn: Callable, timeout: float, what: str, every: float = 0.05):
    end = time.time() + timeout
    last_err = None
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Fail:
            raise  # eindeutig rot (z. B. Aufgabe fehlgeschlagen): nicht bis zur Zeitgrenze warten
        except Exception as e:  # noqa: BLE001 – kurz nicht erreichbar o. Ä.: weiter warten
            last_err = e
        time.sleep(every)
    raise Fail(f"Zeitüberschreitung ({timeout:.0f} s): {what}" + (f" (zuletzt: {last_err})" if last_err else ""))


# -- Gemeinsamer Kontext und HTTP-Helfer (beide Stufen) ------------------------------------------------------------------
@dataclass
class Ctx:
    live: bool
    base: str
    token: str
    tmp: Path
    workspace: Path
    data: Path
    http: object = None
    lucy: str = ""
    helfer: str = ""
    names: dict = field(default_factory=dict)
    shared: dict = field(default_factory=dict)  # Ergebnisse, die spätere Abläufe nutzen
    task_timeout: float = 30.0
    chat_timeout: float = 20.0

    @property
    def H(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"}

    def get(self, path: str, **params):
        r = self.http.get(path, headers=self.H, params=params or None)
        check(r.status_code == 200, f"GET {path} → {r.status_code} {r.text[:200]}")
        return r.json()

    def post(self, path: str, body: dict | None = None, expect: int = 200):
        r = self.http.post(path, headers=self.H, json=body or {})
        check(r.status_code == expect, f"POST {path} → {r.status_code} {r.text[:200]}")
        return r.json() if r.content else None

    def msgs(self, chat: str) -> list[dict]:
        return self.get(f"/api/bots/{chat}/messages", limit=200)

    def ids(self, chat: str) -> set[str]:
        return {m["id"] for m in self.msgs(chat)}

    def new(self, chat: str, before: set[str]) -> list[dict]:
        return [m for m in self.msgs(chat) if m["id"] not in before]

    def say(self, chat: str, text: str, **extra) -> dict:
        return self.post(f"/api/bots/{chat}/messages", {"text": text, **extra})

    def task(self, tid: str) -> dict:
        return self.get(f"/api/tasks/{tid}")

    def bot(self, bid: str) -> dict:
        return self.get(f"/api/bots/{bid}")

    def idle(self, timeout: float | None = None) -> None:
        def quiet():
            h = self.get("/api/health")
            return h["active_runs"] == 0 and h["active_tasks"] == 0
        wait(quiet, timeout or max(self.task_timeout, 30), "alle Läufe beendet", every=0.2)

    def wait_task(self, tid: str, states=("done",), timeout: float | None = None) -> dict:
        finals = {"done", "failed", "stopped", "limit"}

        def done():
            t = self.task(tid)
            if t["state"] in finals and t["state"] not in states:
                raise Fail(f"Aufgabe endete mit „{t['state']}“ statt {'/'.join(states)}: {t.get('error') or t.get('result') or ''}"[:400])
            return t if t["state"] in states else None
        try:
            return wait(done, timeout or self.task_timeout, f"Aufgabe {tid} → {'/'.join(states)}", every=0.1 if not self.live else 1.0)
        except Fail as e:
            if "endete mit" in str(e):
                raise
            t = self.task(tid)
            raise Fail(f"{e} – Zustand {t['state']}, Schritte: {t.get('lines', [])[-3:]}") from None

    def find_task(self, pred: Callable[[dict], bool], what: str, timeout: float | None = None) -> dict:
        return wait(lambda: next((t for t in self.get("/api/tasks", limit=200) if pred(t)), None),
                    timeout or self.chat_timeout, what, every=0.1 if not self.live else 1.0)

    def bot_reply(self, chat: str, before: set[str], pred: Callable[[dict], bool] = lambda m: True,
                  timeout: float | None = None, what: str = "Antwort des Scoops") -> dict:
        return wait(lambda: next((m for m in self.new(chat, before) if m["role"] == "bot" and pred(m)), None),
                    timeout or self.chat_timeout, what, every=0.1 if not self.live else 1.0)

    def pending_approval(self, chat: str, before: set[str]) -> dict:
        return wait(lambda: next((m for m in self.new(chat, before) if m["role"] == "approval"
                                  and (m.get("meta") or {}).get("state") == "pending"), None),
                    self.task_timeout, "Freigabe-Karte im Chat", every=0.1 if not self.live else 1.0)


# -- Abläufe ---------------------------------------------------------------------------------------------------------------
# Jeder Ablauf bekommt den Kontext und prüft über die HTTP-API. Offline-Texte enthalten Marker ([probe:…]), auf die
# Fake-Modell und Fake-Agent reagieren; live stehen dort echte Anweisungen an den Test-Scoop.
FLOWS: list[tuple[str, str, Callable, str | None]] = []  # (Nr., Titel, Funktion, Grund, warum nicht live)


def flow(nr: str, title: str, offline_only: str | None = None):
    def deco(fn):
        FLOWS.append((nr, title, fn, offline_only))
        return fn
    return deco


def text_for(c: Ctx, offline: str, live: str) -> str:
    return live if c.live else offline


@flow("1", "Chat-Nachricht → Scoop antwortet")
def f_chat(c: Ctx) -> str:
    before = c.ids(c.lucy)
    c.say(c.lucy, text_for(c, "Hallo, kurzer Test [probe:chat]", "Probelauf: Antworte nur mit dem Wort PROBELAUF."))
    m = c.bot_reply(c.lucy, before)
    want = "probelauf" if c.live else "hallo, hier ist"
    check(want in m["text"].lower(), f"unerwartete Antwort: {m['text'][:120]!r}")
    c.idle()
    return f"Antwort: „{m['text'][:40]}“"


@flow("2", "/aufgabe und aufgabe_starten → fertig → Bericht → „Zu prüfen“ → abnehmen → „Abgeschlossen“")
def f_task(c: Ctx) -> str:
    before = c.ids(c.lucy)
    prompt = text_for(c, "Pinguin-Bericht schreiben [probe:standard]",
                      "Lege die Datei ergebnis/Probelauf.md mit dem Inhalt „Probelauf erfolgreich“ an. Lege außerdem im "
                      "Arbeitsordner (nicht in ergebnis/) die Datei Zwischenstand.md mit dem Inhalt „Zwischenstand“ an und gib "
                      "sie mit dem Werkzeug datei_in_bibliothek in die Bibliothek. Sonst nichts: kein Web, keine anderen Werkzeuge.")
    c.say(c.lucy, "/aufgabe " + prompt)
    t = c.find_task(lambda t: t["chat_id"] == c.lucy and t["prompt"] == prompt, "Aufgabe aus /aufgabe angelegt")
    check(t["origin"] == "user", f"Herkunft {t['origin']} statt user")
    t = c.wait_task(t["id"])
    check(t["column"] == "review" and t["review"] == "review", f"fertig, aber Spalte {t['column']} statt „Zu prüfen“")
    ev = wait(lambda: next((m for m in c.new(c.lucy, before) if m["role"] == "event"
                            and (m.get("meta") or {}).get("task_id") == t["id"] and m["text"].startswith("Aufgabe fertig")), None),
              c.chat_timeout, "Ereignis „Aufgabe fertig“ im Chat")
    def report():
        ms = c.new(c.lucy, before)
        after = ms[[m["id"] for m in ms].index(ev["id"]) + 1:]
        return next((m for m in after if m["role"] == "bot"), None)
    rep = wait(report, c.task_timeout, "Bericht des Scoops im Chat nach „Aufgabe fertig“", every=0.1 if not c.live else 1.0)
    if not c.live:
        check("Bericht:" in rep["text"], f"Bericht fehlt: {rep['text'][:100]!r}")
    c.idle()
    a = c.post(f"/api/tasks/{t['id']}/accept")
    check(a["column"] == "done" and a["reviewed_at"], f"nach Abnahme Spalte {a['column']}")
    check(any(x["id"] == t["id"] for x in c.get("/api/tasks", column="done", limit=200)), "nicht unter „Abgeschlossen“ gelistet")
    c.shared["task_files"] = (t["id"], t["title"])
    if c.live:
        return f"{t['id']} in {t['active_minutes']} min, {t['cost_usd']:.3f} $"
    # Offline zusätzlich: derselbe Weg über das Chat-Werkzeug aufgabe_starten (wie ein Modell es aufruft)
    before = c.ids(c.lucy)
    c.say(c.lucy, "Mach das bitte im Hintergrund [probe:aufgabe-starten]")
    t2 = c.find_task(lambda x: x["chat_id"] == c.lucy and "über aufgabe_starten" in x["title"], "Aufgabe aus aufgabe_starten")
    check(t2["origin"] == "scoop", f"Herkunft {t2['origin']} statt scoop")
    out = FAKE.tool_results.get("aufgabe_starten", "")
    check("Aufgabe gestartet" in out, f"aufgabe_starten meldet: {out[:120]!r}")
    t2 = c.wait_task(t2["id"])
    check(t2["column"] == "review", f"aufgabe_starten: Spalte {t2['column']}")
    c.idle()
    c.post(f"/api/tasks/{t2['id']}/accept")
    return "beide Wege (/aufgabe, aufgabe_starten)"


@flow("3", "Aufgabe schreibt anderem Scoop (scoop_schreiben) → wartet → macht mit der Antwort weiter")
def f_peer(c: Ctx) -> str:
    before_l, before_h = c.ids(c.lucy), c.ids(c.helfer)
    helfer = c.names[c.helfer]
    prompt = text_for(c, "Frag den Helfer [probe:scoop]",
                      f"Schreib mit dem Werkzeug scoop_schreiben dem Scoop „{helfer}“ genau diese Nachricht: „Probelauf: Was ist "
                      "2+2? Antworte nur mit der Zahl.“ mit antwort_erwartet true. Die Antwort kommt in diese Aufgabe zurück; "
                      "nenne sie dann im Abschlussbericht. Sonst nichts.")
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": prompt, "title": "Probe: anderem Scoop schreiben"})
    t = c.wait_task(t["id"])
    if not c.live:
        out = FAKE.task_results.get((t["id"], "scoop_schreiben"), "")
        check(out and TOO_MANY not in out, f"scoop_schreiben aus der Aufgabe: {out[:160]!r}")
        check("geschickt" in out, f"scoop_schreiben meldet: {out[:160]!r}")
    check(TOO_MANY not in (t.get("result") or ""), f"Aufgabe meldet „{TOO_MANY}“")
    got = wait(lambda: next((m for m in c.new(c.helfer, before_h) if m["role"] == "bot"
                             and (m.get("meta") or {}).get("peer") and (m.get("meta") or {}).get("author_id") == c.lucy), None),
               c.task_timeout, f"Nachricht kommt bei {helfer} an")
    check("2+2" in got["text"], f"Nachricht beim Helfer: {got['text'][:100]!r}")
    back = wait(lambda: next((m for m in c.new(c.lucy, before_l) if m["role"] == "bot"
                              and (m.get("meta") or {}).get("author_id") == c.helfer and (m.get("meta") or {}).get("peer")), None),
                c.task_timeout, "Antwort des Helfers kommt zurück")
    check("4" in back["text"], f"Antwort des Helfers: {back['text'][:100]!r}")
    # Seit 1.29: Die Aufgabe wartet auf die Antwort und macht mit ihr weiter – sie steht im Ergebnis
    t = c.wait_task(t["id"])
    check("4" in (t.get("result") or ""), f"Antwort im Ergebnis der Aufgabe: {(t.get('result') or '')[:120]!r}")
    c.idle()
    for chat, b in ((c.lucy, before_l), (c.helfer, before_h)):
        bad = [m for m in c.new(chat, b) if TOO_MANY in (m.get("text") or "")]
        check(not bad, f"„{TOO_MANY}“ im Chat: {bad[0]['text'][:120] if bad else ''}")
    return f"Antwort „{back['text'][:20]}“"


@flow("4", "Aufgabe wartet auf Freigabe → Chat nicht beschäftigt → Entscheidung → Aufgabe macht weiter")
def f_approval(c: Ctx) -> str:
    before = c.ids(c.lucy)
    prompt = text_for(c, "Etwas mit Freigabe [probe:freigabe]",
                      "Fordere mit dem Werkzeug freigabe_anfordern eine Freigabe an: titel „Probelauf-Test (nichts wird "
                      "gesendet)“, details „Reiner Test des Probedurchlaufs, es passiert nichts“, art und art_bezeichnung leer. "
                      "Danach hörst du auf und wartest. Wirst du fortgesetzt, schreib nur einen Satz Abschlussbericht, ob "
                      "freigegeben oder abgelehnt wurde. Sonst nichts.")
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": prompt, "title": "Probe: Freigabe"})
    t = c.wait_task(t["id"], states=("waiting",))
    card = c.pending_approval(c.lucy, before)
    # Der Aufgaben-Lauf endet kurz nach dem Wechsel auf „waiting“ (Worker räumt auf); danach zählt der Zustand
    wait(lambda: c.get("/api/health")["active_tasks"] == 0, 10, "Aufgaben-Lauf nach dem Pausieren beendet", every=0.05)
    b = c.bot(c.lucy)
    check(b["waiting"] is True, "Bot-Feld waiting ist nicht wahr, obwohl die Aufgabe auf eine Freigabe wartet")
    check(b["busy"] is False, "Chat gilt als beschäftigt, obwohl die Aufgabe nur auf eine Freigabe wartet")
    # Der Chat nimmt währenddessen normal Nachrichten an
    mid = c.ids(c.lucy)
    c.say(c.lucy, text_for(c, "Zwischendurch eine Frage [probe:chat]", "Probelauf: Antworte nur mit OK."))
    c.bot_reply(c.lucy, mid, what="Antwort im Chat, während die Aufgabe wartet")
    wait(lambda: c.get("/api/health")["active_runs"] == 0, c.chat_timeout, "Chat-Lauf fertig")
    check(c.task(t["id"])["state"] == "waiting", "Aufgabe wartet nicht mehr, obwohl noch nicht entschieden ist")
    decision = "decline" if c.live else "approve"  # live: nie etwas freigeben
    c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": decision})
    t = c.wait_task(t["id"])
    if not c.live:
        msg = FAKE.agent_messages.get(t["id"], [])
        check(len(msg) == 2 and "freigegeben" in msg[-1], f"Fortsetzung nach Freigabe fehlt: {msg[-1:]}")
    c.idle()
    b = c.bot(c.lucy)
    check(b["waiting"] is False and b["busy"] is False, f"nach der Entscheidung waiting={b['waiting']} busy={b['busy']}")
    return ("abgelehnt" if c.live else "freigegeben") + ", Aufgabe fertig"


@flow("5", "Aufgabe aus einer Routine → gekennzeichnet (routine_id) und fertig direkt „Abgeschlossen“")
def f_routine(c: Ctx) -> str:
    before = c.ids(c.lucy)
    c.say(c.lucy, text_for(
        c, "Leg eine Routine an [probe:routine-anlegen]",
        "Lege mit dem Werkzeug routine_anlegen eine Routine an: titel „Probe-Routine“, cron „0 3 1 1 *“, zeitplan_text "
        "„jährlich am 1.1. um 3 Uhr“, modell „wie_scoop“, auftrag: „Starte mit aufgabe_starten eine Hintergrund-Aufgabe mit "
        "dem Titel Routine-Probe und dem Auftrag: Lege die Datei ergebnis/Routine.md mit dem Inhalt OK an. Sonst nichts.“ "
        "Antworte danach nur mit OK."))
    c.bot_reply(c.lucy, before, timeout=c.task_timeout)
    c.idle()
    r = wait(lambda: next((x for x in c.get(f"/api/bots/{c.lucy}/routines") if "Probe-Routine" in x["title"]), None),
             c.chat_timeout, "Routine angelegt")
    c.post(f"/api/routines/{r['id']}/run")
    t = c.find_task(lambda x: x.get("routine_id") == r["id"], "Aufgabe aus der Routine", timeout=c.task_timeout)
    check(t["origin"] == "routine", f"Herkunft {t['origin']} statt routine")
    check(t.get("routine_title") == r["title"], f"Routine-Titel fehlt ({t.get('routine_title')})")
    t = c.wait_task(t["id"])
    check(t["column"] == "done" and t["review"] == "done", f"Routine-Aufgabe in Spalte {t['column']} statt „Abgeschlossen“")
    c.idle()
    c.http.delete(f"/api/routines/{r['id']}", headers=c.H)
    return f"routine_id {r['id']}"


@flow("6", "Offene Aufgabe startet nicht von selbst → manuell starten")
def f_open(c: Ctx) -> str:
    prompt = text_for(c, "Später erledigen [probe:standard]", "Lege die Datei ergebnis/Offen.md mit dem Inhalt „OK“ an. Sonst nichts.")
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": prompt, "title": "Probe: offen", "backlog": True})
    check(t["state"] == "open" and t["column"] == "open", f"angelegt mit {t['state']}/{t['column']} statt Offen")
    if c.live:
        time.sleep(20)  # mindestens ein Durchlauf des Planers (alle 15 s)
    else:
        PROBE.tasks.start_due()  # der Planer selbst
        time.sleep(0.5)
        check(t["id"] not in FAKE.agent_messages, "Fake-Agent wurde für die offene Aufgabe gestartet")
    check(c.task(t["id"])["state"] == "open", "offene Aufgabe hat von selbst gestartet")
    r = c.post(f"/api/tasks/{t['id']}/start")
    check(r["column"] in ("active", "review"), f"nach Start Spalte {r['column']}")
    t = c.wait_task(t["id"])
    check(t["column"] == "review", f"fertig in Spalte {t['column']}")
    c.idle()
    if not c.live:  # auch per Chat-Werkzeug: termin „offen“
        c.say(c.lucy, "Sammel das für später [probe:aufgabe-offen]")
        t2 = c.find_task(lambda x: x["title"] == "Probe: gesammelt", "gesammelte Aufgabe aus aufgabe_starten")
        check(t2["state"] == "open", f"aufgabe_starten mit termin „offen“: {t2['state']}")
        c.idle()
        check(c.task(t2["id"])["state"] == "open", "gesammelte Aufgabe hat von selbst gestartet")
    return "erst nach „Starten“ gelaufen"


@flow("7", "Datei speichern und Aufgaben-Ergebnis → Bibliothek und Arbeitsordner")
def f_files(c: Ctx) -> str:
    folder = c.workspace / c.names[c.lucy]
    found = []
    if not c.live:
        before = c.ids(c.lucy)
        c.say(c.lucy, "Speicher mir eine Notiz [probe:datei-speichern]")
        c.bot_reply(c.lucy, before)
        out = FAKE.tool_results.get("datei_speichern", "")
        check("Arbeitsordner" in out, f"datei_speichern meldet keinen Arbeitsordner: {out[:160]!r}")
        lib = {f["name"] for f in c.get(f"/api/chats/{c.lucy}/files")}
        check("Probe-Notiz.md" in lib, "datei_speichern: nicht in der Bibliothek")
        p = folder / "Dateien" / "Probe-Notiz.md"
        check(p.is_file() and "Probe" in p.read_text(), f"datei_speichern: fehlt im Arbeitsordner ({p})")
        found.append("Notiz")
    if "task_files" not in c.shared:
        raise Fail("keine Aufgabe aus Ablauf 2 (der muss vorher grün sein)")
    tid, title = c.shared["task_files"]
    t = c.task(tid)
    names = {f["name"] for f in t["file_items"]}
    want = {"Probelauf.md", "Zwischenstand.md"} if c.live else {f"Ergebnis-{tid}.md", "Zwischenstand.md"}
    check(want <= names, f"Aufgaben-Dateien in der Bibliothek: {sorted(names)} (erwartet {sorted(want)})")
    lib = {f["name"] for f in c.get(f"/api/chats/{c.lucy}/files")}
    check(want <= lib, "Aufgaben-Ergebnis fehlt in der Bibliothek des Chats")
    key = title.replace("/", "-").replace(":", "-")[:20]
    tdirs = [d for d in (folder / "Aufgaben").glob("*") if d.is_dir() and key in d.name]
    check(tdirs, f"kein Aufgabenordner unter {folder / 'Aufgaben'}")
    have = {p.name for d in tdirs for p in d.iterdir()}
    check(want <= have, f"Arbeitsordner der Aufgabe hat {sorted(have)}, erwartet {sorted(want)}")
    found.append("Aufgabe (ergebnis/ und datei_in_bibliothek)")
    return ", ".join(found)


def tool_sets(c: Ctx, bid: str) -> tuple[set[str], set[str]]:
    """(Chat-Werkzeuge, Aufgaben-Werkzeuge) eines Scoops: aus einem echten Chat-Lauf (extra_tools des Fake-Modells)
    und einer echten Aufgabe (tools/list am MCP-Endpunkt)."""
    key = f"tools_{bid}"
    if key in c.shared:
        return c.shared[key]
    before = c.ids(bid)
    FAKE.chat_tools.pop(bid, None)
    c.say(bid, "Werkzeug-Check [probe:chat]")
    c.bot_reply(bid, before)
    chat = FAKE.chat_tools.get(bid)
    check(chat, "Chat-Lauf ohne Werkzeugliste")
    t = c.post("/api/tasks", {"chat_id": bid, "prompt": "Werkzeug-Check [probe:standard]", "title": "Probe: Werkzeuge"})
    c.wait_task(t["id"])
    c.idle()
    task = FAKE.task_tools.get(t["id"])
    check(task, "Aufgabe ohne tools/list")
    c.shared[key] = (set(chat), set(task))
    return c.shared[key]


@flow("8", "Aufgabe hat alle Chat-Werkzeuge außer TASK_EXCLUDED (Gleichheitscheck)", offline_only="nur offline: vergleicht Werkzeuglisten im Prozess")
def f_tool_parity(c: Ctx) -> str:
    excluded = PROBE.tasks_mod.TASK_EXCLUDED
    out = []
    for bid in (c.lucy, c.helfer):
        chat, task = tool_sets(c, bid)
        missing = (chat - excluded) - task
        check(not missing, f"{c.names[bid]}: in Aufgaben fehlen {sorted(missing)}")
        extra = (task - TASK_ONLY) - (chat - excluded)
        check(not extra, f"{c.names[bid]}: Aufgaben haben Werkzeuge, die der Chat nicht hat: {sorted(extra)} "
                         "(neues Aufgaben-Werkzeug? dann TASK_ONLY im Probelauf ergänzen)")
        leaked = excluded & task
        check(not leaked, f"{c.names[bid]}: ausgeschlossene Werkzeuge in Aufgaben: {sorted(leaked)}")
        out.append(f"{c.names[bid]} {len(chat - excluded)}")
    return "gleich: " + ", ".join(out) + " Werkzeuge"


@flow("9", "Composio lesend: große Notion-Abfrage kommt vollständig und kompakt an (keine Vorschau)")
def f_composio(c: Ctx) -> str:
    if c.live:
        return live_composio()
    fake = PROBE.install_composio()
    try:
        # a) Aufgabe: über app_werkzeug_suchen/app_werkzeug_nutzen am MCP-Endpunkt
        t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": "Notion-Aufgaben auswerten [probe:composio]",
                                  "title": "Probe: Notion"})
        t = c.wait_task(t["id"])
        found = FAKE.task_results.get((t["id"], "app_werkzeug_suchen"), "")
        check("composio__COMPOSIO_MULTI_EXECUTE_TOOL" in found, f"app_werkzeug_suchen findet Composio nicht: {found[:160]!r}")
        res = FAKE.task_results.get((t["id"], "app_werkzeug_nutzen"), "")
        _check_full(res, fake, "Aufgabe")
        c.idle()
        # b) Chat: das Modell ruft das Hub-Werkzeug direkt
        before = c.ids(c.lucy)
        c.say(c.lucy, "Was steht in Notion an? [probe:composio]")
        c.bot_reply(c.lucy, before)
        _check_full(FAKE.tool_results.get("composio", ""), fake, "Chat")
        c.idle()
    finally:
        PROBE.uninstall_composio()
    return f"{fake.rows} Zeilen vollständig, Tool Router nicht gebraucht"


def _check_full(text: str, fake, where: str) -> None:
    try:
        d = json.loads(text)
    except (TypeError, ValueError):
        raise Fail(f"{where}: Composio-Ergebnis ist kein JSON: {str(text)[:160]!r}") from None
    r = (d.get("results") or [{}])[0]
    rows = (r.get("data") or {}).get("results") or []
    check("vorschau" not in r and "Vorschau" not in json.dumps(d, ensure_ascii=False),
          f"{where}: nur eine Vorschau statt vollständiger Daten")
    check(len(rows) == fake.rows, f"{where}: {len(rows)} von {fake.rows} Zeilen (Vorschau statt vollständiger Daten?)")
    check(rows[0].get("Task") == "Aufgabe 1" and rows[-1].get("Task") == f"Aufgabe {fake.rows}",
          f"{where}: Werte nicht kompakt/vollständig: {json.dumps(rows[0], ensure_ascii=False)[:160]}")
    check("notion.so" not in json.dumps(d), f"{where}: nicht kompakt (URLs enthalten)")
    check(fake.router_calls == 0, f"{where}: lesende Abfrage ging über den Tool Router (Vorschau-Gefahr)")


@flow("10", "Haupt-Scoop: Aufsicht-Werkzeuge in Chat und Aufgabe, andere Scoops ohne", offline_only="nur offline: vergleicht Werkzeuglisten im Prozess")
def f_oversight(c: Ctx) -> str:
    lc, lt = tool_sets(c, c.lucy)
    hc, ht = tool_sets(c, c.helfer)
    check(OVERSIGHT_TOOLS <= lc, f"Haupt-Scoop im Chat ohne {sorted(OVERSIGHT_TOOLS - lc)}")
    check(OVERSIGHT_TOOLS <= lt, f"Haupt-Scoop in Aufgaben ohne {sorted(OVERSIGHT_TOOLS - lt)}")
    check(not (OVERSIGHT_TOOLS & hc), f"anderer Scoop hat im Chat {sorted(OVERSIGHT_TOOLS & hc)}")
    check(not (OVERSIGHT_TOOLS & ht), f"anderer Scoop hat in Aufgaben {sorted(OVERSIGHT_TOOLS & ht)}")
    return "4 Aufsicht-Werkzeuge nur beim Haupt-Scoop"


@flow("11", "Erinnerung setzen → kommt pünktlich im Chat an")
def f_reminder(c: Ctx) -> str:
    before = c.ids(c.lucy)
    when = (datetime.now().astimezone() + timedelta(seconds=40 if c.live else 2)).replace(microsecond=0)
    c.say(c.lucy, text_for(c, "Erinner mich gleich [probe:erinnerung]",
                           f"Setze mit dem Werkzeug erinnerung_setzen eine Erinnerung: zeitpunkt „{when.isoformat()}“, text "
                           "„Probe-Erinnerung“. Antworte danach nur mit OK."))
    c.bot_reply(c.lucy, before, timeout=c.task_timeout)
    m = c.bot_reply(c.lucy, before, lambda m: m["text"].startswith("⏰"), timeout=90 if c.live else 25,
                    what="Erinnerung (Planer alle 15 s)")
    check("Probe-Erinnerung" in m["text"], f"Text der Erinnerung: {m['text'][:80]!r}")
    c.idle()
    return "über den Planer ausgelöst"


@flow("12", "Dauerfreigabe „Immer erlauben“: nächste gleiche Freigabe läuft ohne Warten durch",
      offline_only="nur offline: live wird nie etwas freigegeben")
def f_standing(c: Ctx) -> str:
    before = c.ids(c.lucy)
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": "Wochenbericht senden [probe:dauer]", "title": "Probe: Dauer 1"})
    c.wait_task(t["id"], states=("waiting",))
    card = c.pending_approval(c.lucy, before)
    check((card.get("meta") or {}).get("can_always"), "Karte bietet „Immer erlauben“ nicht an")
    c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": "approve_always"})
    c.wait_task(t["id"])
    c.idle()
    st = c.get(f"/api/bots/{c.lucy}/standing-approvals")
    check(any(s["key"].endswith("probe-wochenbericht-senden") for s in st), f"Dauerfreigabe nicht gespeichert: {st}")
    before = c.ids(c.lucy)
    t2 = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": "Wochenbericht senden [probe:dauer]", "title": "Probe: Dauer 2"})
    t2 = c.wait_task(t2["id"])
    check(len(FAKE.agent_messages.get(t2["id"], [])) == 1, "zweite Aufgabe hat trotz Dauerfreigabe gewartet")
    check(not any(m["role"] == "event" and m["text"].startswith("Automatisch freigegeben") for m in c.new(c.lucy, before)),
          "Zeile „Automatisch freigegeben“ im Chat (soll still laufen)")
    c.idle()
    for s in st:
        c.http.delete(f"/api/bots/{c.lucy}/standing-approvals/{s['id']}", headers=c.H)
    return "zweite Aufgabe automatisch freigegeben"


# -- Rechner-Zugriff (1.29, docs/rechnerzugriff.md) --------------------------------------------------------------------
CLEANUP: list[Callable[[], None]] = []  # läuft am Ende von main (os._exit überspringt atexit)


def probe_project(c: Ctx) -> Path:
    """Kleiner Projektordner im Home (Projektordner müssen im Home liegen), mit Git, wird am Ende gelöscht."""
    if "project" not in c.shared:
        base = Path.home() / f".aisbot-probelauf-{os.urandom(3).hex()}"
        proj = base / "Projekt"
        proj.mkdir(parents=True)
        CLEANUP.append(lambda: shutil.rmtree(base, ignore_errors=True))
        (proj / "README.md").write_text("Probe-Projekt\nZweite Zeile\n")
        subprocess.run(["/usr/bin/git", "init", "-q"], cwd=proj, capture_output=True)
        c.shared["project"] = proj
    return c.shared["project"]


@flow("13", "Aufgabe mit Projektordner → arbeitet direkt dort (Bereich und Anweisung), außerhalb gesperrt")
def f_project_task(c: Ctx) -> str:
    proj = probe_project(c)
    prompt = text_for(c, f"Projekt bearbeiten [probe:projekt]",
                      f"Lies die Datei {proj}/README.md und schreib ihre erste Zeile in eine neue Datei {proj}/notiz.txt "
                      "(direkt dort, nicht im Aufgabenordner). Danach nur ein Satz Abschlussbericht.")
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": prompt, "title": "Probe: Projektordner",
                              "access": {"scope": "projects", "folders": [str(proj)]}})
    acc = t.get("access") or {}
    check(acc.get("scope") == "projects" and acc.get("custom") and "Projektordner" in acc.get("label", ""),
          f"Bereich der Aufgabe fehlt im Board-JSON: {acc}")
    t = c.wait_task(t["id"])
    note = proj / "notiz.txt"
    check(note.exists() and "Probe-Projekt" in note.read_text(), "notiz.txt im Projektordner fehlt oder ist falsch")
    if not c.live:
        r = FAKE.task_results.get((t["id"], "perm"), "")
        check(r == "ok", f"Rechte-Prüfung in der Aufgabe: {r}")
    c.idle()
    return "notiz.txt direkt im Projektordner" + ("" if c.live else ", außerhalb und Zugangsdaten gesperrt")


@flow("14", "Modus „Automatisch“: riskanter Befehl (git push) → Freigabe-Karte → Entscheidung → weiter")
def f_risky(c: Ctx) -> str:
    proj = probe_project(c)
    before = c.ids(c.lucy)
    prompt = text_for(c, "Pushen [probe:push]",
                      f"Führe im Ordner {proj} genau diesen Befehl im Terminal (Bash) aus: git push origin main – nichts "
                      "anderes vorher. Wird eine Freigabe angefragt, hör auf und warte. Wirst du fortgesetzt, schreib nur "
                      "einen Satz Abschlussbericht und führe nichts mehr aus.")
    t = c.post("/api/tasks", {"chat_id": c.lucy, "prompt": prompt, "title": "Probe: riskanter Befehl",
                              "access": {"scope": "projects", "folders": [str(proj)]}})
    c.wait_task(t["id"], states=("waiting",))
    card = c.pending_approval(c.lucy, before)
    details = ((card.get("meta") or {}).get("details") or "")
    check("git push" in details, f"Karte nennt den Befehl nicht: {details[:120]}")
    decision = "decline" if c.live else "approve"  # live: nie etwas freigeben
    c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": decision})
    t = c.wait_task(t["id"])
    if not c.live:
        check(FAKE.task_results.get((t["id"], "push")) == "erlaubt", "nach der Freigabe war der Befehl nicht erlaubt")
    c.idle()
    return ("abgelehnt" if c.live else "freigegeben → Befehl einmal erlaubt") + ", Aufgabe fertig"


@flow("15", "Chat am Rechner: persistente Shell und Datei-Werkzeuge im Bereich",
      offline_only="nur offline: braucht einen Rechner (Scoops Connect), hier ein lokaler Fake")
def f_chat_files(c: Ctx) -> str:
    import base64 as b64
    proj = probe_project(c)
    p = PROBE
    from aisbot.bots import RunState
    from aisbot.engine import ComputerHub

    class Local:
        online = True

        def alive(self) -> bool:
            return True

        def send(self, command: str, params: dict) -> dict:
            if command == "run_command":
                r = subprocess.run(["/bin/zsh", "-lc", params["command"]], capture_output=True, text=True, timeout=50)
                return {"success": True, "stdout": r.stdout, "stderr": r.stderr, "return_code": r.returncode}
            if command == "read_bytes":
                return {"success": True, "content_b64": b64.b64encode(Path(params["path"]).read_bytes()).decode()}
            if command == "write_bytes":
                Path(params["path"]).write_bytes(b64.b64decode(params["content_b64"]))
                return {"success": True}
            return {"success": False, "error": command}

    hub = ComputerHub(node_id="n_probe", name="Probe-Mac", transport=Local())
    saved = p.service.hub_for
    p.service.hub_for = lambda bid: hub
    try:
        r = c.http.patch(f"/api/bots/{c.helfer}", headers=c.H,
                         json={"computer_access": {"mode": "auto", "scope": "projects", "folders": [str(proj)]}})
        check(r.status_code == 200, f"Rechner-Zugriff setzen: {r.status_code} {r.text[:200]}")
        tools = {t.schema["name"]: t for t in p.service._tools(c.helfer, c.helfer, 0, RunState())}
        for n in ("terminal", "rechner_datei_lesen", "rechner_dateien_suchen", "rechner_datei_ersetzen", "rechner_datei_schreiben"):
            check(n in tools, f"Chat-Werkzeug {n} fehlt")
        term = tools["terminal"].handler
        term({"command": f"cd {proj} && export PROBE_VAR=da"})
        out = term({"command": "pwd; echo $PROBE_VAR; git status --short | head -3"})
        check(str(proj) in out and "da" in out, f"Shell merkt Ordner/Umgebung nicht: {out[:200]}")
        out = tools["rechner_datei_schreiben"].handler({"pfad": "chat.txt", "inhalt": "eins\nzwei\n"})
        check(out.startswith("Geschrieben"), f"Schreiben im Projektordner: {out}")
        out = tools["rechner_datei_ersetzen"].handler({"pfad": "chat.txt", "alt": "zwei", "neu": "drei"})
        check(out.startswith("Ersetzt") and "drei" in (proj / "chat.txt").read_text(), f"Ersetzen: {out}")
        out = tools["rechner_datei_lesen"].handler({"pfad": "chat.txt", "ab_zeile": 2, "zeilen": 1})
        check("2\tdrei" in out, f"Lesen mit Zeilenbereich: {out}")
        out = tools["rechner_dateien_suchen"].handler({"muster": "Probe-Projekt", "art": "inhalt"})
        check("README.md:1" in out, f"Suche im Inhalt: {out[:200]}")
        out = tools["rechner_datei_lesen"].handler({"pfad": str(proj.parent.parent / ".zshrc")})
        check(out.startswith("Abgelehnt"), f"Lesen außerhalb des Bereichs nicht abgelehnt: {out[:120]}")
        out = term({"command": "git push origin main"})
        check("Freigabe angefragt" in out, f"git push ohne Karte: {out[:200]}")
        a = p.db.one("SELECT * FROM approvals WHERE bot_id=? AND state='pending' AND details LIKE '%git push%'", (c.helfer,))
        check(a is not None, "Karte für git push fehlt")
        c.post(f"/api/approvals/{a['id']}", {"decision": "decline"})
    finally:
        p.service.hub_for = saved
        c.http.patch(f"/api/bots/{c.helfer}", headers=c.H, json={"computer_access": {"mode": "auto", "scope": "workspace"}})
    c.idle()
    return "Shell merkt Ordner, Datei-Werkzeuge im Bereich, außerhalb abgelehnt, git push → Karte"


# -- KI-Abos (docs/abos.md) --------------------------------------------------------------------------------------------
def _abo_mode(c: Ctx, provider: str, mode: str) -> None:
    r = c.http.patch("/api/settings/abos", headers=c.H, json={provider: mode})
    check(r.status_code == 200 and r.json()[provider]["mode"] == mode, f"Abrechnungsmodus {provider}={mode}: {r.text[:200]}")


def _abo_flow(c: Ctx, provider: str) -> str:
    who = "Claude" if provider == "claude" else "ChatGPT"
    bid = c.helfer if provider == "claude" else c.shared.get("gpt_bot")
    if provider == "openai" and not bid:
        model = "gpt-6-luna"
        b = c.post("/api/bots", {"name": "Probe-Codi", "mascot": {"shape": "bean", "color": "#7C5CFF", "eyes": "dots",
                                                                  "accessory": "none"}, "model": model,
                                 "character": "Test-Scoop des Probedurchlaufs. Befolge Anweisungen wörtlich und knapp."})
        bid = c.shared["gpt_bot"] = b["id"]
        c.idle(timeout=120 if c.live else 15)
    if c.live:
        st = c.get("/api/settings/abos", refresh="true")[provider]
        if not st["subscription"]:
            raise Skip(f"{who}-Abo nicht angemeldet (Server-App → KI-Abos → „Mit {who} anmelden“)")
    _abo_mode(c, provider, "abo")
    try:
        before = c.ids(bid)
        c.say(bid, text_for(c, "Merk dir die Probe-Zahl 41 [probe:abo-merken]",
                            "Probelauf: Speichere mit deinem Werkzeug merken den Text „Probe-Zahl 41“ (nur für dich) und "
                            "antworte danach nur mit dem Wort GEMERKT."))
        m = c.bot_reply(bid, before, what=f"Antwort über das {who}-Abo")
        check((m.get("meta") or {}).get("run_info", {}).get("billing") == "abo", f"Antwort lief nicht übers Abo: {m.get('meta')}")
        check("gemerkt" in m["text"].lower(), f"unerwartete Antwort: {m['text'][:120]!r}")
        mems = c.get(f"/api/bots/{bid}/memories")
        check(any("41" in x["text"] for x in mems), "Werkzeug merken wurde im Abo-Lauf nicht ausgeführt")
        st = next((x for x in c.new(bid, before) if x["role"] == "status"), None)
        check(st is None or (st["meta"].get("billing") == "abo" and not st["meta"].get("cost_usd")), "Statuszeile mit Kosten")
        c.idle()
        before = c.ids(bid)
        c.say(bid, text_for(c, "Welche Zahl? [probe:abo-folge]",
                            "Probelauf: Welche Probe-Zahl habe ich dir eben genannt? Antworte nur mit der Zahl."))
        m = c.bot_reply(bid, before, what="Folgeantwort aus derselben Sitzung")
        check("41" in m["text"], f"Sitzung nicht fortgesetzt: {m['text'][:120]!r}")
        c.idle()
        if provider == "claude":  # Aufgabe übers Abo (Claude Code mit dem Login des Nutzers, ohne API-Schlüssel)
            prompt = text_for(c, "Abo-Bericht schreiben [probe:standard]",
                              "Lege die Datei ergebnis/Abo.md mit dem Inhalt „Abo erfolgreich“ an. Sonst nichts: kein Web, "
                              "keine anderen Werkzeuge.")
            c.say(bid, "/aufgabe " + prompt)
            t = c.find_task(lambda t: t["chat_id"] == bid and t["prompt"] == prompt, "Abo-Aufgabe angelegt")
            t = c.wait_task(t["id"])
            check(t.get("billing") == "abo" and not t["cost_usd"], f"Aufgabe lief nicht übers Abo: {t.get('billing')} "
                                                                     f"{t['cost_usd']}")
            c.idle()
            c.post(f"/api/tasks/{t['id']}/accept")
            before = c.ids(bid)
            c.say(bid, text_for(c, "Bitte posten [probe:abo-freigabe]",
                                "Probelauf: Fordere mit freigabe_anfordern eine Freigabe an (titel „Probe posten“, details "
                                "„nur ein Test“, art und art_bezeichnung leer) und antworte danach nur mit WARTE."))
            card = c.pending_approval(bid, before)
            c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": "decline"})
            c.idle()
        u = c.get("/api/usage")
        check(u.get("abo", {}).get("month_runs", 0) >= 2, f"Abo-Läufe nicht getrennt gezählt: {u.get('abo')}")
        extra = ""
        if not c.live:  # Abo am Limit simulieren: derselbe Lauf geht mit Hinweis über die API
            _abo_mode(c, provider, "abo_api")
            before = c.ids(bid)
            c.say(bid, "Noch eine Frage [probe:abo-limit]")
            m = c.bot_reply(bid, before, what="Antwort über die API nach Abo-Limit")
            ev = [x for x in c.new(bid, before) if x["role"] == "event" and (x.get("meta") or {}).get("abo_fallback")]
            check(ev and "am Limit" in ev[0]["text"], "Hinweis „Abo am Limit – weiter über den API-Schlüssel“ fehlt")
            check((m.get("meta") or {}).get("run_info", {}).get("billing") != "abo", "Antwort lief trotz Limit übers Abo")
            c.idle()
            extra = ", Limit → API mit Hinweis"
        return (f"Werkzeug, Sitzung fortgesetzt{', Aufgabe, Freigabe-Karte' if provider == 'claude' else ''}, "
                f"Nutzung ohne Betrag{extra}")
    finally:
        _abo_mode(c, provider, "api")




@flow("16", "Chat übers Claude-Abo (Claude Code): Werkzeug, Sitzung, Aufgabe, Freigabe-Karte, Abo-Nutzung, Limit → API")
def f_abo_claude(c: Ctx) -> str:
    return _abo_flow(c, "claude")


@flow("17", "Chat übers ChatGPT-Abo (Codex): Werkzeug über /mcp/abo, Thread fortgesetzt, Limit → API")
def f_abo_codex(c: Ctx) -> str:
    return _abo_flow(c, "openai")


@flow("18", "Eigener MCP-Server im Chat: prüfen → Karte mit sicherem Token → verbunden → lesen direkt, schreiben mit Karte",
      offline_only="nutzt einen lokalen Fake-MCP im Testserver")
def f_custom_mcp(c: Ctx) -> str:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fake_mcp import TOKEN as FAKE_TOKEN, DictStore, FakeMCP
    svc = PROBE.service
    svc.custom_mcp.store_factory = DictStore  # nie der echte Schlüsselbund
    fake = FakeMCP().start()
    url = fake.url("token")
    # 1. Scoop prüft und bereitet die Verbindung vor (Token nicht im Chat)
    before = c.ids(c.lucy)
    c.say(c.lucy, f"Verbinde bitte diesen MCP-Server [probe:mcp-verbinden] {url}")
    card = c.pending_approval(c.lucy, before)
    check("Anmeldung: token" in FAKE.tool_results.get("mcp_server_pruefen", ""), "mcp_server_pruefen erkennt den Token-Bedarf nicht")
    fields = (card.get("meta") or {}).get("secret_fields") or []
    check([f["key"] for f in fields] == ["token"], f"Karte ohne sicheres Token-Feld: {card.get('meta')}")
    c.idle()
    # 2. Arman trägt das Token in der Karte ein und gibt frei
    c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": "approve", "edits": {"secrets": {"token": FAKE_TOKEN}}})
    st = wait(lambda: next((x for x in c.get("/api/mcp-servers")["servers"] if x["status"] == "ok"), None), c.task_timeout,
              "MCP-Server verbunden")
    check(st["tools"] == 3, f"erwartet 3 Werkzeuge, bekommen {st['tools']}")
    c.idle()
    dump = json.dumps(c.msgs(c.lucy)) + (c.tmp / "config.json").read_text()
    check(FAKE_TOKEN not in dump, "Token im Chatverlauf oder in config.json")
    # 3. Werkzeuge kommen im nächsten Lauf an: lesend direkt, schreibend nur mit Karte
    before = c.ids(c.lucy)
    c.say(c.lucy, "Nutz den neuen Server [probe:mcp-nutzen]")
    card = c.pending_approval(c.lucy, before)
    check("Apfel" in FAKE.tool_results.get("mcp-lesen", ""), f"lesendes Werkzeug lief nicht: {FAKE.tool_results.get('mcp-lesen')}")
    check(not any(x[1] == "create_item" for x in fake.calls), "schreibendes Werkzeug lief ohne Freigabe")
    c.idle()
    c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": "approve"})
    wait(lambda: any(x[1] == "create_item" for x in fake.calls), c.task_timeout, "nach Freigabe ausgeführt")
    c.idle()
    c.http.delete(f"/api/mcp-servers/{st['id']}", headers=c.H)
    return f"{st['name']}: 3 Werkzeuge, Token nur im Schlüsselbund, Schreiben mit Karte"


@flow("19", "Computer Use von Codex: nur am Server-Mac, Sperre im Hub, App-Freigabe als Karte, Rückfall bei fehlenden Rechten",
      offline_only="Fake-Codex und Fake-App im Testserver (echte Messung: docs/computer.md)")
def f_codex_cu(c: Ctx) -> str:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import fake_codex_cu as fc
    from aisbot import abos, codex_cu, engine_abo, workspace
    from aisbot.engine import ComputerHub
    svc = PROBE.service
    app = c.tmp / "Codex Computer Use.app"
    client = app / codex_cu.CLIENT_REL
    client.parent.mkdir(parents=True, exist_ok=True)
    client.write_text("#!/bin/sh\n")
    client.chmod(0o755)

    class Node:  # „dieser Mac“ über Scoops Connect
        online, paused, apple, name = True, False, None, "Server-Mac"
        screen = {"width": 1440, "height": 900}

        def alive(self) -> bool:
            return True

        def post(self, msg: dict) -> None:
            pass

    local, vm = ComputerHub(node_id="probe-mac", name="Server-Mac", transport=Node()), ComputerHub(node_id="vm")
    local.screen_size = vm.screen_size = lambda: (1440, 900)
    hubs = {"hub": local}
    saved = (svc.hub_for, workspace.hub_on_server_mac, svc.codex_abo.run, os.environ.get("AISBOT_CODEX_CU_APP"))
    svc.hub_for = lambda bot_id: hubs["hub"]
    workspace.hub_on_server_mac = lambda hub, db: getattr(hub, "node_id", "") == "probe-mac"
    os.environ["AISBOT_CODEX_CU_APP"] = str(app)
    svc.codex_abo.run = engine_abo.CodexChatEngine.run.__get__(svc.codex_abo)  # echte Engine, Fake-Codex
    restore = fc.install()
    codex_cu.clear_block()
    bid = c.shared.get("gpt_bot")
    got: dict = {}
    try:
        if not bid:
            bid = c.shared["gpt_bot"] = c.post("/api/bots", {"name": "Probe-Codi", "model": "gpt-6-luna", "mascot": {
                "shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}})["id"]
            c.idle()
        _abo_mode(c, "openai", "abo")

        def script(cl, items):
            got["action"] = cl.ask(fc.ELICIT, fc.action_request("get_app_state"))
            got["holder"] = local.holder
            yield fc.started(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}))
            got["app"] = cl.ask(fc.ELICIT, fc.app_request("Safari"))
            yield fc.completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text="Computer Use state"))
            yield fc.started(fc.McpToolCallThreadItem("type_text", {"app": "Safari", "text": "example.com"}))
            yield fc.completed(fc.McpToolCallThreadItem("type_text", {"app": "Safari"}, text="ok"))
            yield from fc.done("Überschrift: Example Domain")

        fc.FakeCodex.script = script
        before = c.ids(bid)
        c.say(bid, "Öffne in Safari example.com und lies die Überschrift vor.")
        card = c.pending_approval(bid, before)
        check((card.get("meta") or {}).get("kind") == "codex_cu" and "Safari" in card["meta"]["title"],
              f"App-Freigabe nicht als Karte: {card.get('meta')}")
        check(got.get("holder") == bid, f"Bildschirm im Hub nicht belegt ({got.get('holder')})")
        c.post(f"/api/approvals/{card['meta']['approval_id']}", {"decision": "approve"})
        m = c.bot_reply(bid, before, what="Antwort mit Computer Use")
        check("Example Domain" in m["text"] and got["app"].get("action") == "accept", "Lauf nach Freigabe nicht fertig")
        cx = fc.FakeCodex.instances[-1]
        servers = {o.split(".")[1] for o in cx.overrides if o.startswith("mcp_servers.")}
        check(servers == {"scoops", "computer-use"} and "features.plugins=false" in cx.overrides,
              f"Codex-Konfiguration: {servers}")
        lines = [x for s in c.new(bid, before) if s["role"] == "status" for x in s["meta"].get("lines", [])]
        check("Schaut auf Safari" in lines and "Tippt „example.com“" in lines, f"Fortschrittszeilen: {lines}")
        check(local.holder is None, "Bildschirm nach dem Lauf nicht frei")
        c.idle()

        # Fehlende Rechte → Hinweis, Sperre; nächster Lauf über den alten Weg mit Zeile
        def script_rights(cl, items):
            cl.ask(fc.ELICIT, fc.action_request("get_app_state"))
            yield fc.started(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}))
            yield fc.completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text=(
                "Computer Use permissions are still pending. The user has not finished granting Accessibility and "
                "Screen Recording permissions in the ChatGPT Computer Use window.")))
            yield from fc.done("Mache über den Scoops-Bildschirm weiter.")

        fc.FakeCodex.script = script_rights
        before = c.ids(bid)
        c.say(bid, "Nochmal bitte.")
        c.bot_reply(bid, before, what="Antwort nach fehlenden Rechten")
        c.idle()
        ev = [x for x in c.new(bid, before) if x["role"] == "event" and (x.get("meta") or {}).get("codex_cu") == "rechte"]
        check(ev and "Bedienungshilfen" in ev[0]["text"], "Hinweis zu den macOS-Rechten fehlt")
        st = c.get("/api/settings/abos")["codex_computer_use"]
        check(not st["available"] and st["reason"] == "macOS-Rechte fehlen", f"Status nach fehlenden Rechten: {st}")
        fc.FakeCodex.script = None
        before = c.ids(bid)
        c.say(bid, "Und jetzt?")
        c.bot_reply(bid, before, what="Antwort auf dem alten Weg")
        check("computer-use" not in " ".join(fc.FakeCodex.instances[-1].overrides), "gesperrt, aber computer-use geladen")
        codex_cu.clear_block()
        c.idle()

        # VM: alter Weg
        hubs["hub"] = vm
        before = c.ids(bid)
        c.say(bid, "Auf der VM.")
        c.bot_reply(bid, before, what="Antwort an der VM")
        check("computer-use" not in " ".join(fc.FakeCodex.instances[-1].overrides), "VM, aber computer-use geladen")
        c.idle()
    finally:
        restore()
        svc.hub_for, workspace.hub_on_server_mac, svc.codex_abo.run = saved[:3]
        if saved[3] is None:
            os.environ.pop("AISBOT_CODEX_CU_APP", None)
        else:
            os.environ["AISBOT_CODEX_CU_APP"] = saved[3]
        codex_cu.clear_block()
        svc.codex_abo.close_all()
        _abo_mode(c, "openai", "api")
        abos.set_status_for_tests("openai", {"installed": True, "logged_in": True, "subscription": True, "plan": "probe"})
    return "Karte „Computer Use: Safari bedienen“, Sperre im Hub, Zeilen, Rechte fehlen → Hinweis und alter Weg, VM unverändert"


# -- Ausführen und Ausgabe -------------------------------------------------------------------------------------------------
def run_flows(c: Ctx, only: set[str] | None) -> list[tuple[str, str, str, str, float]]:
    rows = []
    for nr, title, fn, offline_only in FLOWS:
        if only and nr not in only:
            continue
        t0 = time.time()
        if c.live and offline_only:
            rows.append((nr, title, "skip", offline_only, 0.0))
            _line(rows[-1])
            continue
        try:
            detail = fn(c) or ""
            rows.append((nr, title, "ok", detail, time.time() - t0))
        except Skip as e:
            rows.append((nr, title, "skip", str(e), time.time() - t0))
        except Fail as e:
            rows.append((nr, title, "fail", str(e), time.time() - t0))
        except Exception as e:  # noqa: BLE001
            tb = traceback.extract_tb(e.__traceback__)[-1]
            rows.append((nr, title, "fail", f"{type(e).__name__}: {e} ({Path(tb.filename).name}:{tb.lineno})", time.time() - t0))
        _line(rows[-1])
        if rows[-1][2] == "fail":
            try:  # Folgefehler vermeiden: auf Ruhe warten
                c.idle(timeout=60 if c.live else 15)
            except Exception:  # noqa: BLE001
                pass
    return rows


def _line(row) -> None:
    nr, title, state, detail, secs = row
    mark = {"ok": f"{GREEN}✔ grün{RESET}", "fail": f"{RED}✘ ROT {RESET}", "skip": f"{GREY}– übersprungen{RESET}"}[state]
    print(f"{mark}  {nr:>2}. {title} {GREY}({secs:.1f} s){RESET}", flush=True)
    if detail:
        color = RED if state == "fail" else GREY
        print(f"       {color}{'Grund: ' if state == 'fail' else ''}{detail}{RESET}", flush=True)


def summary(rows, started: float, extra: str = "") -> int:
    bad = [r for r in rows if r[2] == "fail"]
    good = sum(1 for r in rows if r[2] == "ok")
    skipped = sum(1 for r in rows if r[2] == "skip")
    dur = time.time() - started
    print()
    if bad:
        print(f"{RED}{BOLD}ROT: {len(bad)} von {len(rows)} Abläufen fehlgeschlagen{RESET} ({good} grün, {skipped} übersprungen, "
              f"{dur:.0f} s){extra}")
        for r in bad:
            print(f"  {RED}✘ {r[0]}. {r[1]}{RESET}\n    {r[3]}")
    else:
        print(f"{GREEN}{BOLD}GRÜN: alle {good} Abläufe bestanden{RESET} ({skipped} übersprungen, {dur:.0f} s){extra}")
    return 1 if bad else 0


# == Offline-Stufe ==========================================================================================================
class Probe:
    """Testserver im Prozess (wie die Einzeltests) mit Fake-Modell und Fake-Agent."""

    def __init__(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="aisbot-probelauf-"))
        self.token = "probe-" + os.urandom(8).hex()
        self.port = free_port()
        self.workspace = self.tmp / "Scoops"
        (self.tmp / "config.json").write_text(json.dumps({"api_token": self.token, "user_name": "Arman"}))
        os.environ.update(AISBOT_DATA=str(self.tmp / "data"), AISBOT_CONFIG=str(self.tmp / "config.json"),
                          AISBOT_OFFLINE="1", AISBOT_PORT=str(self.port), AISBOT_COMPUTER_URL="http://127.0.0.1:9",
                          AISBOT_WORKSPACE=str(self.workspace))
        sys.path.insert(0, str(SRC))
        import httpx
        import uvicorn
        from aisbot import server, tasks as tasks_mod
        from aisbot.config import Usage, UsageBook
        from aisbot.engine import Outcome
        self.httpx, self.uvicorn = httpx, uvicorn
        self.server, self.tasks_mod = server, tasks_mod
        self.Usage, self.UsageBook, self.Outcome = Usage, UsageBook, Outcome
        if not str(server.db.path).startswith(str(self.tmp)):
            raise SystemExit("Abbruch: Der Probelauf würde nicht die Test-Datenbank benutzen.")
        self.db, self.service, self.tasks = server.db, server.service, server.tasks
        self._composio_saved = None

    def start(self) -> Ctx:
        srv = self.uvicorn.Server(self.uvicorn.Config(self.server.app, host="127.0.0.1", port=self.port, log_level="warning"))
        threading.Thread(target=srv.run, daemon=True).start()
        c = Ctx(live=False, base=f"http://127.0.0.1:{self.port}", token=self.token, tmp=self.tmp, workspace=self.workspace,
                data=self.tmp / "data")
        c.http = self.http = self.httpx.Client(base_url=c.base, timeout=30)
        wait(lambda: c.http.get("/api/health", headers=c.H).status_code == 200, 15, "Testserver startet")
        FAKE.install(self)
        mascot = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
        for name, attr in (("Probe-Lucy", "lucy"), ("Probe-Helfer", "helfer")):
            b = c.post("/api/bots", {"name": name, "mascot": mascot, "model": LIVE_MODEL})
            setattr(c, attr, b["id"])
            c.names[b["id"]] = name
        r = c.http.patch(f"/api/bots/{c.lucy}", headers=c.H, json={"primary": True})
        check(r.status_code == 200, f"Haupt-Scoop setzen: {r.status_code}")
        FAKE.helfer = c.helfer
        c.idle()
        return c

    # Composio: Fake-REST (große Notion-Datenbank) + Fake-Tool-Router, der nur eine Vorschau liefert (der alte Fehler)
    def install_composio(self):
        from aisbot import connections as conn_mod
        from aisbot.composio_direct import ComposioDirect
        from aisbot.connections import Connections
        fake = FakeComposio(self.httpx)
        self._composio_saved = (conn_mod._key, self.service.mcp_hub.composio_direct)  # noqa: SLF001
        conn_mod._key = lambda: "probe-key"  # noqa: SLF001 – nie der echte Schlüssel
        conns = Connections(lambda: {"composio_session_id": "trs_probe", "composio_user_id": "probe"})
        conns.http = self.httpx.Client(transport=self.httpx.MockTransport(fake.handler))
        self.service.mcp_hub.composio_direct = ComposioDirect(conns)
        self.service.mcp_hub.servers["composio"] = fake
        return fake

    def uninstall_composio(self) -> None:
        from aisbot import connections as conn_mod
        self.service.mcp_hub.servers.pop("composio", None)
        if self._composio_saved:
            conn_mod._key, self.service.mcp_hub.composio_direct = self._composio_saved  # noqa: SLF001


class FakeComposio:
    """Composio als MCP-Server im Hub (Tool Router) plus REST-API. Der Router liefert für große Abfragen nur eine
    Vorschau – genau das, was den Scoop früher Daten erfinden ließ."""
    name = "composio"
    url = token = None

    def __init__(self, httpx) -> None:
        self.httpx = httpx
        self.rows = 120
        self.router_calls = 0

    def tools(self) -> list[dict]:
        return [{"name": "COMPOSIO_MULTI_EXECUTE_TOOL", "description": "Executes Composio tools of connected apps (Notion, "
                 "Gmail …) in parallel: multi execute, Notion datenbank abfragen.",
                 "inputSchema": {"type": "object", "properties": {"tools": {"type": "array"}}}},
                {"name": "COMPOSIO_SEARCH_TOOLS", "description": "Search Composio tools.",
                 "inputSchema": {"type": "object", "properties": {}}}]

    def call(self, tool: str, args: dict):
        self.router_calls += 1
        data = {"results": [{"response": {"successful": True, "data_preview": {"results": [{"Task": "{object}"}],
                                                                                "...": f"{self.rows - 1} more items"}},
                             "tool_slug": t.get("tool_slug"), "index": i} for i, t in enumerate(args.get("tools") or [])],
                "remote_file_info": {"file_path": "/mnt/files/x.json", "message": "Complete response was large"}}
        return [{"type": "text", "text": json.dumps({"successful": True, "data": data})}]

    def handler(self, request):
        r, path = self.httpx.Response, request.url.path
        if path.endswith("/v3/connected_accounts") and request.method == "GET":
            return r(200, json={"items": [{"id": "ca_notion", "status": "ACTIVE", "alias": "", "toolkit": {"slug": "notion"},
                                           "created_at": "2026-11-01T00:00:00Z", "state": {"val": {"displayName": "probe"}},
                                           "auth_config": {"id": "ac", "is_composio_managed": True}}]})
        if "/tool_router/session/" in path:
            return r(200, json={"config": {"auth_configs": {}}})
        if path.endswith("/v3/auth_configs"):
            return r(200, json={"items": []})
        if path.endswith("/v3/tools/execute/NOTION_QUERY_DATABASE"):
            def page(i):
                rt = [{"type": "text", "plain_text": f"Aufgabe {i}", "text": {"content": f"Aufgabe {i}"}, "annotations": {}}]
                return {"object": "page", "id": f"p-{i:04d}", "url": f"https://www.notion.so/p{i}", "icon": None,
                        "created_by": {"id": "u"}, "properties": {
                            "Task": {"type": "title", "title": rt},
                            "Status": {"type": "status", "status": {"name": "offen" if i % 2 else "erledigt"}},
                            "Fälligkeit": {"type": "date", "date": {"start": f"2026-12-{1 + i % 28:02d}"}}}}
            return r(200, json={"successful": True, "data": {"response_data": {
                "object": "list", "results": [page(i) for i in range(1, self.rows + 1)], "has_more": False, "next_cursor": None}}})
        return r(404, json={"error": {"message": "unbekannt"}})


class FakeAI:
    """Fake-Modell (Chat-Läufe) und Fake-Agent (Aufgaben). Beide rufen die Werkzeuge auf, die der Server wirklich
    anbietet: im Chat die `extra_tools` des Laufs (bzw. das MCP-Hub-Werkzeug), in Aufgaben den MCP-Endpunkt."""

    def __init__(self) -> None:
        self.chat_tools: dict[str, set[str]] = {}      # Scoop → Werkzeuge des letzten Chat-Laufs
        self.tool_results: dict[str, str] = {}         # letztes Ergebnis je Chat-Werkzeug
        self.task_tools: dict[str, list[str]] = {}     # Aufgabe → tools/list
        self.task_results: dict[tuple, str] = {}       # (Aufgabe, Werkzeug) → Ergebnistext
        self.agent_messages: dict[str, list[str]] = {}  # Aufgabe → Nachrichten an den Agenten (Start, Fortsetzungen)
        self.helfer = ""
        self.p: Probe | None = None

    def install(self, p: Probe) -> None:
        self.p = p
        p.service.engine.run = self.chat
        p.service.openai_engine.run = self.chat
        # KI-Abos: Fake für Claude Code bzw. Codex. Werkzeuge über die echte Abo-Strecke (engine_abo.prepare/run_tool,
        # bei Codex über den MCP-Endpunkt /mcp/abo mit Token), Sitzung wie die Programme.
        p.service.claude_abo.run = lambda **kw: self.abo_chat("claude", **kw)
        p.service.codex_abo.run = lambda **kw: self.abo_chat("openai", **kw)
        from aisbot import abos
        for prov in ("claude", "openai"):
            abos.set_status_for_tests(prov, {"installed": True, "logged_in": True, "subscription": True, "plan": "probe"})
        abos.has_api_key = lambda provider: True
        p.tasks._run_claude = self.agent
        p.tasks._run_openai = self.agent

    def abo_chat(self, provider: str, **kw):
        from aisbot import abos, engine_abo
        from aisbot.config import UsageBook
        from aisbot.engine import Outcome
        text = "\n".join(b.get("text", "") for b in engine_abo.flatten(kw.get("messages") or [], intro=not kw.get("session_id"))
                         if b.get("type") == "text")
        if "[probe:abo-limit]" in text:
            raise abos.SubscriptionUnavailable(provider, f"{provider}-Abo-Limit erreicht (Probe)", limit=True)
        ctx, lines = engine_abo.prepare(kw.get("extra_tools"), None, None, False, None, kw.get("on_line"), kw.get("cancel"),
                                        kw.get("holder") or "", None)
        sessions = self.__dict__.setdefault("abo_sessions", {})
        sid = kw.get("session_id") or f"probe-{provider}-{len(sessions) + 1}"
        mem = sessions.setdefault(sid, [])
        mem.append(text)

        def call(name: str, args: dict) -> str:
            if provider == "openai":  # wie Codex: über den MCP-Endpunkt mit Prozess-Token
                tok = "probe-abo-" + os.urandom(4).hex()
                engine_abo.MCP_TOKENS[tok] = [ctx, ctx.tools]
                try:
                    h = {"Authorization": f"Bearer {tok}"}
                    lst = self.p.http.post("/mcp/abo", headers=h, json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
                    if name not in {t["name"] for t in lst.json()["result"]["tools"]}:
                        raise Fail(f"/mcp/abo bietet {name} nicht an")
                    r = self.p.http.post("/mcp/abo", headers=h, json={"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                                     "params": {"name": name, "arguments": args}})
                    res = r.json()["result"]
                    if res["isError"]:
                        raise Fail(f"{name} über /mcp/abo: {res['content']}")
                    return res["content"][0]["text"]
                finally:
                    engine_abo.MCP_TOKENS.pop(tok, None)
            blocks, err = engine_abo.run_tool(ctx, name, args)
            if err:
                raise Fail(f"{name} im Abo-Lauf: {blocks}")
            return blocks[0].get("text", "")

        if "[probe:abo-merken]" in text:
            call("merken", {"text": "Probe-Zahl 41", "fuer_alle_bots": False})
            final = "Gemerkt."
        elif "[probe:abo-folge]" in text:
            if not any("41" in t for t in mem[:-1]):
                raise Fail("Fortsetzung kam nicht in derselben Sitzung an")
            if "Probe-Zahl 41" in text:
                raise Fail("Fortsetzung schickte den ganzen Verlauf statt nur der neuen Nachricht")
            final = "41"
        elif "[probe:abo-freigabe]" in text:
            call("freigabe_anfordern", {"titel": "Probe posten", "details": "nur ein Test", "art": "", "art_bezeichnung": ""})
            final = "Warte auf Freigabe."
        else:
            final = "OK"
        book = UsageBook(billing="abo")
        book.add_counts(kw["model"], 100, 10, 0, 0, 1)
        out = Outcome(final, "end_turn", book, lines, False, kw["model"], ctx.used_tools, None)
        out.session_id, out.billing = sid, "abo"
        return out

    # -- Chat --------------------------------------------------------------------------------------------------------------
    def chat(self, **kw):
        p = self.p
        holder = kw.get("holder") or ""
        extra = {t.schema["name"]: t for t in kw.get("extra_tools") or []}
        msgs = kw.get("messages") or []
        last = msgs[-1]["content"] if msgs else []
        text = "\n".join(b.get("text", "") for b in last if isinstance(b, dict) and b.get("type") == "text")
        self.chat_tools[holder] = set(extra)

        def use(name: str, args: dict) -> str:
            if name not in extra:
                raise Fail(f"Chat-Werkzeug {name} fehlt im Lauf")
            out = extra[name].handler(args)
            self.tool_results[name] = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
            return self.tool_results[name]

        if holder == self.helfer and "[probe:frage]" in text:
            final = "4"
        elif "[probe:aufgabe-starten]" in text:
            use("aufgabe_starten", {"titel": "Probe über aufgabe_starten", "auftrag": "Kurzbericht schreiben [probe:standard]"})
            final = "Ich kümmere mich im Hintergrund darum."
        elif "[probe:aufgabe-offen]" in text:
            use("aufgabe_starten", {"titel": "Probe: gesammelt", "auftrag": "Irgendwann [probe:standard]", "termin": "offen"})
            final = "Gesammelt."
        elif "[probe:routine-anlegen]" in text:
            use("routine_anlegen", {"titel": "Probe-Routine", "cron": "0 3 1 1 *", "zeitplan_text": "jährlich",
                                    "auftrag": "Bericht als Aufgabe starten [probe:routine]", "modell": "wie_scoop"})
            final = "Routine angelegt."
        elif "Deine Routine" in text and "[probe:routine]" in text:
            use("aufgabe_starten", {"titel": "Routine-Bericht", "auftrag": "Routine-Bericht schreiben [probe:standard]"})
            final = "Läuft als Aufgabe."
        elif "[probe:datei-speichern]" in text:
            use("datei_speichern", {"name": "Probe-Notiz.md", "inhalt": "# Probe-Notiz\n"})
            final = "Gespeichert."
        elif "[probe:erinnerung]" in text:
            when = (datetime.now().astimezone() + timedelta(seconds=2)).replace(microsecond=0)
            use("erinnerung_setzen", {"zeitpunkt": when.isoformat(), "text": "Probe-Erinnerung"})
            final = "Erinnerung gesetzt."
        elif "[probe:composio]" in text and "Hintergrund-Aufgabe" not in text:
            hub = kw.get("mcp_hub")
            out = hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", _composio_args())
            self.tool_results["composio"] = out[0]["text"] if isinstance(out, list) else str(out)
            final = "Hier die Aufgaben aus Notion."
        elif "[probe:mcp-verbinden]" in text:
            url = text.split("[probe:mcp-verbinden]", 1)[1].split()[0]
            use("mcp_server_pruefen", {"url": url})
            use("mcp_server_verbinden", {"name": "Probe-Kasse", "url": url, "anmeldung": "auto"})
            final = "Trag das Token bitte in der Karte ein."
        elif "[probe:mcp-nutzen]" in text:
            hub = kw.get("mcp_hub")
            names = {x["name"] for x in hub.tool_schemas()}
            if "mcp_probe_kasse__list_items" not in names:
                raise Fail(f"Werkzeuge des eigenen MCP fehlen im Lauf: {sorted(names)[:8]}")
            out = hub.call("mcp_probe_kasse__list_items", {})
            self.tool_results["mcp-lesen"] = out[0]["text"] if isinstance(out, list) else str(out)
            self.tool_results["mcp-schreiben"] = str(hub.call("mcp_probe_kasse__create_item", {"title": "Probe"}))
            final = "Gelesen; das Anlegen wartet auf deine Freigabe."
        elif "Hintergrund-Aufgabe" in text:
            final = "Bericht: Die Aufgabe ist fertig, Details in der Datei."
        elif "[probe:chat]" in text:
            final = "Hallo, hier ist dein Scoop."
        else:
            final = "OK"
        u = p.Usage(kw["model"])
        u.input_tokens = 10
        book = p.UsageBook()
        book.by_model[kw["model"]] = u
        return p.Outcome(final, "end_turn", book, [], False, kw["model"], 1,
                         list(msgs) + [{"role": "assistant", "content": [{"type": "text", "text": final}]}])

    # -- Aufgabe (statt Claude Agent SDK / Codex) ----------------------------------------------------------------------------
    def agent(self, run, message: str):
        p, t = self.p, run.task
        self.agent_messages.setdefault(t["id"], []).append(message)
        url = f"http://127.0.0.1:{p.port}/mcp/task"
        seq = iter(range(1, 1000))

        def rpc(method: str, params: dict | None = None) -> dict:
            r = p.httpx.post(url, headers={"Authorization": f"Bearer {run.token}"}, timeout=60,
                             json={"jsonrpc": "2.0", "id": next(seq), "method": method, "params": params or {}})
            if r.status_code != 200:
                raise RuntimeError(f"MCP {method}: {r.status_code}")
            return r.json()["result"]

        def call(name: str, args: dict) -> str:
            if name not in names:
                raise RuntimeError(f"Werkzeug {name} fehlt in tools/list der Aufgabe")
            res = rpc("tools/call", {"name": name, "arguments": args})
            txt = "\n".join(b.get("text", "") for b in res.get("content") or [] if b.get("type") == "text")
            self.task_results[(t["id"], name)] = txt
            if res.get("isError"):
                raise RuntimeError(f"{name}: {txt[:200]}")
            return txt

        rpc("initialize", {"protocolVersion": "2025-06-18"})
        names = [x["name"] for x in rpc("tools/list")["tools"]]
        self.task_tools[t["id"]] = names
        u = p.Usage(t["model"])
        u.input_tokens, u.output_tokens = 20_000, 500
        run.usage = {t["model"]: u}
        wd = Path(t["workdir"])
        prompt = t["prompt"]
        if "[probe:scoop]" in prompt:
            if "Antwort von" in message:  # fortgesetzt mit der Antwort des anderen Scoops
                return f"Fertig. {message[:200]}", "end"
            call("scoop_schreiben", {"name": "Probe-Helfer", "nachricht": "Was ist 2+2? [probe:frage]"})
            return "Habe Probe-Helfer gefragt, warte auf die Antwort.", "end"
        if "[probe:freigabe]" in prompt or "[probe:dauer]" in prompt:
            if "freigegeben" in message or "abgelehnt" in message:
                return f"Weiter nach Entscheidung: {message[:80]}", "end"
            art = ("probe-wochenbericht-senden", "Probe-Wochenbericht senden") if "[probe:dauer]" in prompt else ("", "")
            out = call("freigabe_anfordern", {"titel": "Probe-Wochenbericht senden", "details": "Nur ein Test",
                                              "art": art[0], "art_bezeichnung": art[1]})
            if "Automatisch freigegeben" in out:
                return "Ohne Warten erledigt (Dauerfreigabe).", "end"
            return "Warte auf die Freigabe.", "end"
        if "[probe:projekt]" in prompt:
            # wie das Claude Agent SDK: Rechte-Prüfung je Werkzeug (can_use_tool), dann direkt im Projektordner arbeiten
            run.__dict__["_tools"] = p.tasks.tools_for(run)
            acc = p.tasks.access_for(t)
            proj = Path(os.path.expanduser(acc.folders[0]))
            perm = lambda n, i: p.tasks.claude_permission(run, acc, str(wd.resolve()), n, i)[0]  # noqa: E731
            checks = {"Lesen im Projekt": perm("Read", {"file_path": str(proj / "README.md")}),
                      "Schreiben im Projekt": perm("Write", {"file_path": str(proj / "notiz.txt")}),
                      "Bash im Projekt": perm("Bash", {"command": f"cd {proj} && git status"}),
                      "nicht außerhalb": not perm("Write", {"file_path": str(Path.home() / "probe-ausserhalb.txt")}),
                      "keine Zugangsdaten": not perm("Read", {"file_path": str(Path.home() / ".ssh" / "id_ed25519")})}
            bad = [k for k, v in checks.items() if not v]
            self.task_results[(t["id"], "perm")] = "ok" if not bad else ", ".join(bad)
            (proj / "notiz.txt").write_text((proj / "README.md").read_text().splitlines()[0] + "\n")
            return "notiz.txt geschrieben.", "end"
        if "[probe:push]" in prompt:
            run.__dict__["_tools"] = p.tasks.tools_for(run)
            acc = p.tasks.access_for(t)
            allowed, msg = p.tasks.claude_permission(run, acc, str(wd.resolve()), "Bash", {"command": "git push origin main"})
            if "freigegeben" in message:
                self.task_results[(t["id"], "push")] = "erlaubt" if allowed else f"nicht erlaubt: {msg}"
                return "Gepusht (Probe).", "end"
            if allowed:
                raise RuntimeError("git push ohne Freigabe erlaubt")
            return "Warte auf die Freigabe.", "end"
        if "[probe:composio]" in prompt:
            call("app_werkzeug_suchen", {"suche": "notion datenbank abfragen"})
            call("app_werkzeug_nutzen", {"name": "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                         "argumente_json": json.dumps(_composio_args())})
            return "Notion ausgewertet.", "end"
        # Standard: Zwischenstand, Ergebnisdatei, eine Datei sofort in die Bibliothek
        call("zwischenstand", {"text": "Quellen gelesen"})
        (wd / "ergebnis").mkdir(exist_ok=True)
        (wd / "ergebnis" / f"Ergebnis-{t['id']}.md").write_text("# Ergebnis\n")
        (wd / "Zwischenstand.md").write_text("Zwischenstand\n")
        call("datei_in_bibliothek", {"pfad": "Zwischenstand.md"})
        return "Fertig. Ergebnis in ergebnis/.", "end"


def _composio_args() -> dict:
    return {"tools": [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": "db-probe", "page_size": 100}}],
            "sync_response_to_workbench": False}


FAKE = FakeAI()
PROBE: Probe | None = None


def offline(only: set[str] | None) -> int:
    global PROBE
    started = time.time()
    print(f"{BOLD}Probedurchlauf offline{RESET} (Testserver im Prozess, Fake-Modell, keine Kosten)\n", flush=True)
    PROBE = Probe()
    try:
        c = PROBE.start()
        rows = run_flows(c, only)
        code = summary(rows, started)
    finally:
        shutil.rmtree(PROBE.tmp, ignore_errors=True)
    return code


# == Live-Stufe =============================================================================================================
def _keychain_anthropic() -> str:
    sys.path.insert(0, str(SRC))
    from aisbot.config import anthropic_api_key  # Standard-Präfix wie die Server-Konfiguration
    return anthropic_api_key()


def _assert_isolated(tmp: Path, port: int) -> None:
    if port == PROD_PORT:
        raise SystemExit("Abbruch: Testport ist der Produktionsport.")
    if str(tmp.resolve()).startswith(str(PROD_DATA.resolve())):
        raise SystemExit("Abbruch: Testordner liegt im Produktionsordner.")


def live(only: set[str] | None) -> int:
    started = time.time()
    print(f"{BOLD}Probedurchlauf live{RESET} (eigener Testserver, echtes Modell {LIVE_MODEL}, kostet wenige Cent)\n", flush=True)
    import httpx
    tmp = Path(tempfile.mkdtemp(prefix="aisbot-probelauf-live-"))
    port = free_port()
    _assert_isolated(tmp, port)
    token = "probe-live-" + os.urandom(8).hex()
    ws = tmp / "Scoops"
    # Persönliche Zusatzfunktionen aus (kein VM-Wächter, keine Telefonie, kein T3, kein Atrium); kleine Limits
    cfg = {"api_token": token, "user_name": "Arman", "edition": "personal", "vm_enabled": False,
           "features": {f: False for f in ("vm", "lucy", "t3", "teamapp", "atrium", "personal_hints")},
           "task_mode": "all", "task_budget_usd": 0.5, "task_max_minutes": 8, "task_max_parallel": 2}
    (tmp / "config.json").write_text(json.dumps(cfg))
    try:
        key = _keychain_anthropic()
    except Exception as e:  # noqa: BLE001
        print(f"{RED}Kein Anthropic-Schlüssel im Schlüsselbund: {e}{RESET}")
        return 1
    env = {k: v for k, v in os.environ.items() if not k.startswith(("AISBOT_", "ANTHROPIC_", "OPENAI_"))}
    env.update(PYTHONPATH=str(SRC), PYTHONUNBUFFERED="1", AISBOT_DATA=str(tmp / "data"), AISBOT_CONFIG=str(tmp / "config.json"),
               AISBOT_HOME=str(tmp), AISBOT_PORT=str(port), AISBOT_HOST="127.0.0.1", AISBOT_WORKSPACE=str(ws), AISBOT_OFFLINE="1",
               AISBOT_SKIP_CONVEX="1", AISBOT_COMPUTER_URL="http://127.0.0.1:9", ANTHROPIC_API_KEY=key,
               # eigener Schlüsselbund-Präfix: Composio, Notion, Push, Kopplung, Tresor usw. finden nichts Echtes
               AISBOT_KEYCHAIN_PREFIX="ais-scoops-probelauf-" + os.urandom(3).hex(),
               AISBOT_CLOUD_KEYCHAIN="ais-scoops-probelauf-cloud-" + os.urandom(3).hex())
    log = open(tmp / "server.log", "w")
    proc = subprocess.Popen([sys.executable, "-c", "from aisbot.server import main; main()"], cwd=str(tmp), env=env,
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    c = Ctx(live=True, base=f"http://127.0.0.1:{port}", token=token, tmp=tmp, workspace=ws, data=tmp / "data",
            task_timeout=300.0, chat_timeout=120.0)
    c.http = httpx.Client(base_url=c.base, timeout=60)
    code, cost = 1, None
    try:
        wait(lambda: proc.poll() is None and c.http.get("/api/health", headers=c.H).status_code == 200, 60,
             "Testserver startet", every=0.5)
        h = c.get("/api/health")
        print(f"{GREY}Testserver {h['version']} auf Port {port}, Daten in {tmp}{RESET}\n", flush=True)
        mascot = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
        char = ("Test-Scoop des automatischen Probedurchlaufs. Befolge Anweisungen wörtlich und knapp, ohne Rückfragen und "
                "ohne Zusatzarbeit. Nichts nach außen senden.")
        for name, attr in (("Probe-Lucy", "lucy"), ("Probe-Helfer", "helfer")):
            b = c.post("/api/bots", {"name": name, "mascot": mascot, "model": LIVE_MODEL, "character": char})
            setattr(c, attr, b["id"])
            c.names[b["id"]] = name
        c.http.patch(f"/api/bots/{c.lucy}", headers=c.H, json={"primary": True})
        c.idle(timeout=120)
        rows = run_flows(c, only)
        try:
            c.idle(timeout=120)
        except Fail:
            pass
        cost = c.get("/api/usage")
        extra = f", Kosten {cost['month_usd']:.4f} $ ({', '.join(f'{m} {v:.4f} $' for m, v in cost['by_model'].items())})"
        code = summary(rows, started, extra)
    except Fail as e:
        print(f"{RED}ROT: {e}{RESET}")
        print(f"{GREY}Server-Protokoll: {tmp / 'server.log'}{RESET}")
    finally:
        _stop(proc)
        log.close()
        if code == 0:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"{GREY}Testdaten bleiben zur Ansicht: {tmp}{RESET}")
    return code


def _stop(proc: subprocess.Popen) -> None:
    """Testserver samt Kindprozessen (Claude-Agent der Aufgaben) beenden – nur diese eigene Prozessgruppe."""
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(10)
    except Exception:  # noqa: BLE001
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass


class ReadOnlyComposio:
    """Echte Composio-Verbindung nur lesend: Konten per GET, Ausführen nur für lesende Werkzeuge (is_readonly).
    Kein Löschen alter Anmeldungen, kein Ändern der Sitzung, kein Tool Router (der könnte schreiben)."""

    def __init__(self, conns, is_readonly) -> None:
        self.c, self.is_readonly = conns, is_readonly

    def _cfg(self):
        return self.c._cfg()  # noqa: SLF001

    def _req(self, method: str, path: str, **kw):
        slug = path.rsplit("/", 1)[-1]
        if method == "GET" or (method == "POST" and "/v3/tools/execute/" in path and self.is_readonly(slug)):
            return self.c._req(method, path, **kw)  # noqa: SLF001
        raise RuntimeError(f"Probelauf: {method} {path} ist nicht lesend und gesperrt")

    def accounts(self, fresh: bool = False) -> list[dict]:
        _, _, uid = self._cfg()
        items = self._req("GET", "/v3/connected_accounts", params={"user_ids": uid, "limit": 200}).get("items", [])
        return [{"id": a["id"], "app": a["toolkit"]["slug"], "alias": a.get("alias") or "", "status": "active"}
                for a in items if a.get("status") == "ACTIVE"]


def live_composio() -> str:
    """Composio/Notion lesend mit Armans echter Verbindung, aber ohne seinen Server: nur, wenn verbunden."""
    sys.path.insert(0, str(SRC))
    from aisbot import composio_direct as cd
    from aisbot.connections import Connections
    try:
        prod = json.loads((PROD_DATA / "config.json").read_text())  # nur zwei IDs lesen, nichts schreiben
    except (OSError, ValueError):
        raise Skip("keine Composio-Sitzung eingerichtet") from None
    sid, uid = prod.get("composio_session_id"), prod.get("composio_user_id")
    if not sid or not uid:
        raise Skip("Composio nicht eingerichtet")
    conns = Connections(lambda: {"composio_session_id": sid, "composio_user_id": uid})
    try:
        conns._cfg()  # noqa: SLF001 – Schlüssel vorhanden?
    except Exception:  # noqa: BLE001
        raise Skip("kein Composio-Schlüssel im Schlüsselbund") from None
    ro = ReadOnlyComposio(conns, cd.is_readonly)
    try:
        notion = [a for a in ro.accounts() if a["app"] == "notion"]
    except Exception as e:  # noqa: BLE001
        raise Skip(f"Composio nicht erreichbar: {str(e)[:120]}") from None
    if not notion:
        raise Skip("Notion ist über Composio nicht verbunden")
    direct = cd.ComposioDirect(ro)

    def no_router(_args):
        raise RuntimeError("Probelauf: Tool Router gesperrt (nur lesend per REST)")
    out = direct.multi_execute({"tools": [{"tool_slug": "NOTION_SEARCH_NOTION_PAGE",
                                           "arguments": {"query": "", "page_size": 100}}],
                                "sync_response_to_workbench": False}, no_router)
    d = json.loads(out[0]["text"]) if isinstance(out, list) else {}
    r = (d.get("results") or [{}])[0]
    check(r.get("successful"), f"Notion-Suche nicht erfolgreich: {json.dumps(r, ensure_ascii=False)[:200]}")
    check("vorschau" not in r and "nur eine Vorschau" not in json.dumps(d, ensure_ascii=False),
          "nur eine Vorschau statt vollständiger Daten")
    data = r.get("data") or {}
    rows = next((v for v in data.values() if isinstance(v, list)), []) if isinstance(data, dict) else []
    size = len(json.dumps(d, ensure_ascii=False))
    check(size <= cd.LIMIT + 2000, f"Antwort nicht kompakt ({size} Zeichen)")
    return f"Notion lesend: {len(rows)} Einträge vollständig, {size} Zeichen"


# == Start ==================================================================================================================
def main() -> None:
    ap = argparse.ArgumentParser(description="Probedurchlauf der wichtigsten Scoop-Abläufe (docs/probelauf.md)")
    ap.add_argument("--live", action="store_true", help="zusätzlich mit echtem Modell gegen einen eigenen Testserver")
    ap.add_argument("--nur", default="", help="nur diese Abläufe, z. B. --nur 2,4")
    a = ap.parse_args()
    only = {x.strip() for x in a.nur.split(",") if x.strip()} or None
    code = offline(only)
    if a.live:
        print()
        if code:
            print(f"{RED}Live-Stufe ausgelassen: Erst die roten Offline-Abläufe beheben (spart Kosten).{RESET}")
        else:
            code = live(only)
    for fn in CLEANUP:
        fn()
    sys.stdout.flush()
    os._exit(code)  # Server-Threads im Prozess nicht abwarten


if __name__ == "__main__":
    main()
