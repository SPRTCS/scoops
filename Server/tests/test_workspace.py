"""Test für den Arbeitsordner der Scoops (Server 1.27, docs/arbeitsordner.md): Standardordner, Setzen mit Prüfung,
Unterordner pro Scoop, Spiegeln von datei_speichern und Aufgaben-Ergebnissen, datei_auf_rechner ohne Pfad,
Umbenennen, Wechsel ohne Verschieben, Ordnerauswahl (nur Home, keine versteckten Ordner), Systemanweisungen,
Einrichtungs-Endpunkte der Mac-App, nur Admin.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Agenten ohne KI-Aufruf) – niemals die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_workspace.py
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-workspace-test-")).resolve()
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
os.environ.pop("AISBOT_WORKSPACE", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import server, workspace  # noqa: E402
from aisbot.bots import RunState, load_config  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.db import TZ  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
DEFAULT = TMP / "Scoops"


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


def fake_run(**kw):
    u = Usage(kw["model"])
    u.input_tokens = 10
    book = UsageBook()
    book.by_model[kw["model"]] = u
    return Outcome("Antwort vom Scoop", "end_turn", book, [], False, kw["model"], 1, list(kw.get("messages") or []))


service.engine.run = fake_run
service.openai_engine.run = fake_run


def fake_agent(run, message):
    run.progress.line("Schreibt Bericht.md")
    run.usage = {run.task["model"]: Usage(run.task["model"])}
    (Path(run.task["workdir"]) / "ergebnis" / "Bericht.md").write_text("# Pinguine\n")
    (Path(run.task["workdir"]) / "ergebnis" / "Daten.csv").write_text("a;b\n1;2\n")
    return "Fertig. Ergebnis in ergebnis/.", "end"


tasks._run_claude = fake_agent
tasks._run_openai = fake_agent


def start_server() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: _up(), msg="Server startet")


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


def tool(bid: str, name: str):
    return next(x for x in service._tools(bid, bid, 0, RunState()) if x.schema["name"] == name).handler


def test_names() -> None:
    print("Namen für den Finder")
    ok(workspace.folder_name("Lisa") == "Lisa", "einfacher Name bleibt")
    ok(workspace.folder_name("A/B: C") == "A-B- C", "/ und : werden ersetzt")
    ok(workspace.folder_name("..geheim") == "geheim", "keine versteckten Ordner")
    ok(workspace.folder_name("   ", "b_1") == "b_1", "leerer Name → ID")
    ok(workspace.file_name("../../etc/passwd") == "passwd", "Dateiname ohne Pfadanteile")
    ok(workspace.task_folder("Pinguine: Bericht", "2026-11-16T10:00:00+01:00") == "2026-11-16 Pinguine- Bericht",
       "Aufgabenordner „JJJJ-MM-TT Titel“")


def test_default(bid: str) -> None:
    print("Standardordner und Unterordner pro Scoop")
    ok(workspace.default_dir() == str(DEFAULT), "Testinstanz schreibt nie in den echten Home-Ordner")
    os.environ.pop("AISBOT_DATA")
    os.environ.pop("AISBOT_OFFLINE")
    try:
        ok(workspace.default_dir() == "~/Scoops", "Standard für echte Server: ~/Scoops")
    finally:
        os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_OFFLINE="1")
    ok((DEFAULT / "Codi").is_dir(), "neuer Scoop → Ordner <arbeitsordner>/Codi/")
    r = http.get("/api/settings/workspace", headers=H)
    st = r.json()
    ok(r.status_code == 200 and st["absolute"] == str(DEFAULT) and st["is_default"], "GET liefert den Standardordner")
    ok(any(s["id"] == bid and s["exists"] and s["path"].endswith("/Codi") for s in st["scoops"]), "Scoop-Ordner im Status")
    ok(http.get("/api/settings/workspace").status_code == 401, "ohne Anmeldung kein Zugriff")


def test_save(bid: str) -> None:
    print("datei_speichern spiegelt nach <Scoop>/Dateien/")
    save = tool(bid, "datei_speichern")
    out = save({"name": "Notiz.md", "inhalt": "# Hallo\n"})
    f = DEFAULT / "Codi" / "Dateien" / "Notiz.md"
    ok(f.read_text() == "# Hallo\n", "Datei liegt im Scoop-Ordner")
    ok("Bibliothek" in out and "/Codi/Dateien/Notiz.md" in out, f"Antwort nennt den Ort ({out})")
    ok(db.q("SELECT COUNT(*) AS n FROM files WHERE chat_id=?", (bid,))[0]["n"] == 1, "Bibliothek wie bisher")
    save({"name": "Notiz.md", "inhalt": "# Hallo\n"})
    ok(sorted(p.name for p in f.parent.iterdir()) == ["Notiz.md"], "gleicher Inhalt → keine Doppelung")
    save({"name": "Notiz.md", "inhalt": "# Neu\n"})
    ok((f.parent / "Notiz (2).md").read_text() == "# Neu\n" and f.read_text() == "# Hallo\n",
       "anderer Inhalt → „Notiz (2).md“, nichts überschrieben")


def test_put_on_mac(bid: str) -> None:
    print("datei_auf_rechner ohne Pfad → Arbeitsordner (Rechner = Server-Mac)")
    fid = db.files(bid)[0]["id"]
    orig = workspace.hub_on_server_mac
    workspace.hub_on_server_mac = lambda hub, db_: True
    try:
        out = tool(bid, "datei_auf_rechner")({"datei_id": fid, "pfad": ""})
    finally:
        workspace.hub_on_server_mac = orig
    ok("Arbeitsordner" in out and "/Codi/Dateien/" in out, f"Zielordner in der Antwort ({out})")
    ok(len(list((DEFAULT / "Codi" / "Dateien").iterdir())) == 2, "gleiche Datei nicht doppelt abgelegt")
    ok(not workspace.hub_on_server_mac(service.hub_for(bid), db), "Bot-Rechner (VM) zählt nicht als Server-Mac")


def test_prompts(bid: str) -> None:
    print("Systemanweisungen nennen den echten Arbeitsordner")
    note = service.workspace_note(bid)
    ok(note and "Arbeitsordner" in note and str(DEFAULT / "Codi") in note and "älteren Pfadangaben" in note,
       "Chat: Arbeitsordner mit Vorrang vor dem Gedächtnis")
    t = {"id": "t_x", "chat_id": bid, "bot_id": bid, "workdir": str(TMP / "w"), "title": "Pinguine",
         "created_at": "2026-11-16T09:00:00+01:00", "budget_usd": 3.0, "max_minutes": 60}
    sysmsg = tasks._system(t, "")
    ok("Dein Arbeitsordner auf dem Mac: " + str(DEFAULT / "Codi") in sysmsg, "Aufgabe: Scoop-Ordner genannt")
    ok("Sicherungskopie des Originals" in sysmsg and "2026-11-16 Pinguine" in sysmsg,
       "Aufgabe: Arbeitsordner, genannte Dateien erlaubt, Ergebnisse gespiegelt")


def test_task(bid: str) -> None:
    print("Aufgaben-Ergebnisse → <Scoop>/Aufgaben/<Datum Titel>/")
    r = http.post("/api/tasks", headers=H, json={"chat_id": bid, "prompt": "Recherchiere Pinguine.", "title": "Pinguin-Bericht"})
    tid = r.json()["id"]
    wait_for(lambda: tasks.row(tid)["state"] == "done", msg="Aufgabe fertig")
    wait_for(lambda: bid not in service.runs and not tasks.runs, timeout=20, msg="alles ruhig")
    day = datetime.fromisoformat(tasks.row(tid)["created_at"]).astimezone(TZ).strftime("%Y-%m-%d")
    d = DEFAULT / "Codi" / "Aufgaben" / f"{day} Pinguin-Bericht"
    ok((d / "Bericht.md").read_text() == "# Pinguine\n" and (d / "Daten.csv").is_file(), f"Ergebnisse in {d.name}/")
    names = {f["name"] for f in db.files(bid)}
    ok({"Bericht.md", "Daten.csv"} <= names, "Bibliothek bekommt sie weiterhin")


def test_rename(bid: str) -> None:
    print("Umbenennen nimmt den Ordner mit")
    r = http.patch(f"/api/bots/{bid}", headers=H, json={"name": "Codina"})
    ok(r.status_code == 200, "Scoop umbenannt")
    ok(not (DEFAULT / "Codi").exists() and (DEFAULT / "Codina" / "Dateien" / "Notiz.md").is_file(),
       "Ordner Codi → Codina, Dateien bleiben")
    other = make_bot("Tina")
    (DEFAULT / "Lisa").mkdir()
    http.patch(f"/api/bots/{other}", headers=H, json={"name": "Lisa"})
    ok((DEFAULT / "Tina").is_dir() and (DEFAULT / "Lisa").is_dir(), "Zielname schon vergeben → nichts überschrieben")
    http.patch(f"/api/bots/{other}", headers=H, json={"name": "Tina"})


def test_set(bid: str) -> None:
    print("Ordner setzen: Prüfung, Anlegen, Wechsel ohne Verschieben")
    bad = [("relativ/pfad", "absoluten Pfad"), ("~", "Home-Ordner"), ("/", "Home-Ordner"),
           (str(TMP / "data" / "x"), "Systemordner")]
    for raw, word in bad:
        r = http.patch("/api/settings/workspace", headers=H, json={"path": raw})
        ok(r.status_code == 400 and word in r.json().get("detail", r.text), f"abgelehnt: {raw!r}")
    (TMP / "datei.txt").write_text("x")
    r = http.patch("/api/settings/workspace", headers=H, json={"path": str(TMP / "datei.txt")})
    ok(r.status_code == 400, "Datei statt Ordner → 400")
    locked = TMP / "gesperrt"
    locked.mkdir()
    os.chmod(locked, 0o500)
    try:
        r = http.patch("/api/settings/workspace", headers=H, json={"path": str(locked)})
        ok(r.status_code == 400 and "schreiben" in r.text, "nicht beschreibbar → 400 mit Erklärung")
    finally:
        os.chmod(locked, 0o700)
    new = TMP / "Neu" / "Arbeit"
    r = http.patch("/api/settings/workspace", headers=H, json={"path": str(new)})
    st = r.json()
    ok(r.status_code == 200 and st["absolute"] == str(new) and (new / "Codina").is_dir() and (new / "Tina").is_dir(),
       "neuer Ordner angelegt, Scoop-Ordner darin")
    ok(load_config()["workspace_dir"] == str(new), "in config.json gespeichert")
    ok((DEFAULT / "Codina" / "Dateien" / "Notiz.md").is_file(), "alte Dateien werden nicht verschoben")
    ok([p["absolute"] for p in st["previous"]] == [str(DEFAULT)] and "Codina" in st["previous"][0]["folders"],
       "Status zeigt, wo die alten Dateien liegen")
    tool(bid, "datei_speichern")({"name": "Neu.md", "inhalt": "x"})
    ok((new / "Codina" / "Dateien" / "Neu.md").is_file(), "neue Dateien landen im neuen Ordner")
    r = http.patch("/api/settings/workspace", headers=H, json={"path": str(DEFAULT)})
    ok(r.json()["previous"][0]["absolute"] == str(new) and len(r.json()["previous"]) == 1, "zurück: Liste ohne Doppelung")


def test_hang(bid: str) -> None:
    print("Hängender Zugriff (offene macOS-Abfrage) blockiert nichts")
    orig_save, orig_timeout = workspace.save_bytes, workspace.IO_TIMEOUT
    workspace.save_bytes = lambda *a: time.sleep(3)
    workspace.IO_TIMEOUT = 0.3
    try:
        t0 = time.time()
        out = tool(bid, "datei_speichern")({"name": "Haengt.md", "inhalt": "x"})
        ok(time.time() - t0 < 2 and out.startswith("Gespeichert in der Bibliothek") and "Arbeitsordner" not in out,
           "datei_speichern kommt nach der Zeitgrenze zurück, Bibliothek trotzdem gespeichert")
        ok("Erlauben" in (workspace.last_error or ""), "Status erklärt die offene Freigabe")
        orig_browse = workspace._browse
        workspace._browse = lambda raw: time.sleep(3)
        r = http.get("/api/settings/workspace/browse", headers=H, params={"path": "~"})
        workspace._browse = orig_browse
        ok(r.status_code == 400 and "Erlauben" in r.text, "Ordnerauswahl antwortet mit Hinweis statt zu hängen")
    finally:
        workspace.save_bytes, workspace.IO_TIMEOUT = orig_save, orig_timeout
        workspace.last_error = None


def test_browse() -> None:
    print("Ordnerauswahl für iPhone/iPad")
    root = TMP / "home"
    for d in ("Desktop/Scoops", "Dokumente", ".versteckt", "Programm.app"):
        (root / d).mkdir(parents=True)
    (root / "datei.txt").write_text("x")
    workspace.BROWSE_ROOT = root
    r = http.get("/api/settings/workspace/browse", headers=H, params={"path": "~"})
    b = r.json()
    ok(r.status_code == 200 and [d["name"] for d in b["dirs"]] == ["Desktop", "Dokumente"] and b["parent"] is None,
       "nur sichtbare Ordner, keine Dateien, oberste Ebene")
    r = http.get("/api/settings/workspace/browse", headers=H, params={"path": str(root / "Desktop")})
    ok(r.json()["dirs"][0]["name"] == "Scoops" and r.json()["parent"] == str(root), "Unterordner mit Weg zurück")
    r = http.get("/api/settings/workspace/browse", headers=H, params={"path": "/etc"})
    ok(r.status_code == 400, "außerhalb von Home → 400")
    r = http.get("/api/settings/workspace/browse", headers=H, params={"path": str(root / "Desktop" / ".." / "..")})
    ok(r.status_code == 400, "kein Ausbruch über ..")
    r = http.post("/api/settings/workspace/folder", headers=H, json={"parent": str(root / "Dokumente"), "name": "Scoops Ablage"})
    ok(r.status_code == 200 and (root / "Dokumente" / "Scoops Ablage").is_dir() and r.json()["name"] == "Scoops Ablage",
       "neuen Ordner anlegen")
    r = http.post("/api/settings/workspace/folder", headers=H, json={"parent": str(root), "name": ".geheim"})
    ok(r.status_code == 400, "kein versteckter Ordner")


def test_setup() -> None:
    print("Mac-App: Einrichtungs-Endpunkte (nur lokal)")
    st = http.get("/api/setup").json()
    ok(st["server"]["workspace"]["absolute"] == str(DEFAULT), "GET /api/setup enthält den Arbeitsordner")
    target = TMP / "MacApp"
    r = http.patch("/api/setup/config", json={"workspace_dir": str(target)})
    ok(r.status_code == 200 and r.json()["server"]["workspace"]["absolute"] == str(target) and (target / "Codina").is_dir(),
       "PATCH /api/setup/config setzt workspace_dir")
    r = http.patch("/api/setup/config", json={"workspace_dir": "nicht/absolut"})
    ok(r.status_code == 400, "ungültig → 400")
    r = http.patch("/api/setup/config", headers={"X-Forwarded-For": "1.2.3.4"}, json={"workspace_dir": str(DEFAULT)})
    ok(r.status_code == 403, "über Tailscale/Proxy gesperrt")


if __name__ == "__main__":
    start_server()
    test_names()
    bid = make_bot("Codi")
    test_default(bid)
    test_save(bid)
    test_put_on_mac(bid)
    test_prompts(bid)
    test_task(bid)
    test_rename(bid)
    test_set(bid)
    test_hang(bid)
    test_browse()
    test_setup()
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
