"""Tresor-Login in Browsern und Aufgaben (Server 1.40.2): Safari, Chrome und Dia, der Bildschirm-Helfer füllt in
Claude-Aufgaben aus, Codex-Aufgaben direkt. Eigene Testinstanz, Fake-Rechner, Fake-Passwort, nie der echte Schlüsselbund.

    cd Server && AISBOT_SKIP_CONVEX=1 uv run python tests/test_tresor.py
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace as NS

TMP = Path(tempfile.mkdtemp(prefix="aisbot-tresor-test-"))
(TMP / "config.json").write_text(json.dumps({"api_token": "test-" + os.urandom(6).hex(), "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_NO_TERMINAL="1", AISBOT_SKIP_CONVEX="1")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from aisbot import abos, server, tasks as tasks_mod, vault  # noqa: E402
from aisbot.config import UsageBook  # noqa: E402
from aisbot.engine import ComputerHub, Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
SECRET = "fake-pw-" + os.urandom(4).hex()
vault.get_secret = lambda _id: SECRET
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


class FakeComputer:
    def __init__(self):
        self.app, self.url, self.typed, self.keys = "Dia", "https://example-team.vercel.app/login", [], []

    def shell(self, _script: str) -> dict:
        return {"stdout": f"APP={self.app}\n" + (f"{self.url}\n" if self.url else "")}

    def type_text(self, text: str) -> None:
        self.typed.append(text)

    def key(self, k: str) -> None:
        self.keys.append(k)


print("Adresse lesen (echtes Shell-Skript, osascript als Attrappe)")
stub = TMP / "bin"
stub.mkdir()
(stub / "osascript").write_text("""#!/bin/sh
case "$*" in
  *"System Events"*) echo "$FRONT";;
  *'application "Safari"'*"front document"*) echo https://safari.example/a;;
  *'application "Google Chrome"'*"active tab of front window"*) echo https://chrome.example/b;;
  *'application "Dia"'*"active tab of front window"*) echo https://dia.example/c;;
esac
""")
(stub / "osascript").chmod((stub / "osascript").stat().st_mode | stat.S_IEXEC)


class ShellComputer:
    def __init__(self, front):
        self.env = {**os.environ, "PATH": f"{stub}:/bin:/usr/bin", "FRONT": front}

    def shell(self, script):
        return {"stdout": subprocess.run(["/bin/sh", "-c", script], env=self.env, capture_output=True, text=True).stdout}


ok(vault.current_page(ShellComputer("Safari")) == ("Safari", "https://safari.example/a"), "Safari")
ok(vault.current_page(ShellComputer("Google Chrome")) == ("Google Chrome", "https://chrome.example/b"), "Chrome")
ok(vault.current_page(ShellComputer("Dia")) == ("Dia", "https://dia.example/c"), "Dia")
ok(vault.current_page(ShellComputer("Terminal")) == ("Terminal", None), "anderes Programm: keine Adresse")
ok(vault.current_page(NS(shell=lambda s: {"stdout": "APP=Dia\nmissing value\n"})) == ("Dia", None), "„missing value“ ist keine Adresse")
ok(not vault.domain_matches("https://example-team.vercel.app.evil.test/", "example-team.vercel.app"), "fremde Domain mit gleichem Anfang")

hub, pc = ComputerHub(node_id="fake"), FakeComputer()
hub._computer, hub.transport = pc, NS(online=True)
hub.screen_size = lambda: (1440, 900)
service.hub_for = lambda _bot: hub
BID = service.create_bot({"name": "Tresor-Test", "mascot": {"shape": "bean", "color": "#7C5CFF", "eyes": "dots",
                                                              "accessory": "none"}, "model": "claude-opus-5-5"})["id"]
VID = "v_testeintrag"
stamp = "2026-11-23T12:00:00+01:00"
db.q("INSERT INTO vault (id,title,url,domain,username,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
     (VID, "Team App", "https://example-team.vercel.app", "example-team.vercel.app", "arman", stamp, stamp))

orig = tasks._run_engine
tasks._run_engine = lambda run, message: ("Fertig.", "end")
tid = tasks.start(BID, BID, "Tresor-Test", "Anmelden", origin="user")["id"]
end = time.time() + 15
while tasks.row(tid)["state"] not in ("done", "failed", "review") and time.time() < end:
    time.sleep(0.05)
tasks._run_engine = orig
t = tasks.row(tid)
run = tasks_mod.Run(t, tasks_mod.Progress(service, t), "tok")
tools = tasks.tools_for(run)
ARGS = {"eintrag_id": VID, "feld": "beides", "absenden": True}


def reset(app="Dia", url="https://example-team.vercel.app/login"):
    pc.app, pc.url, pc.typed, pc.keys = app, url, [], []


print("Claude-Aufgabe")
reset()
out = tools["login_ausfuellen"].handler(ARGS)
ok("bildschirm_aufgabe" in out and VID in out and not pc.typed, "ohne belegten Rechner: nennt den Helfer, tippt nichts")
ok("Screenshot" not in out and SECRET not in out, "kein Hinweis auf einen unmöglichen Screenshot, kein Passwort")

seen = {}


def fake_engine(**kw):
    seen["tools"] = [x.schema["name"] for x in kw.get("extra_tools") or []]
    seen["system"] = kw["system"]
    helper = {x.schema["name"]: x for x in kw["extra_tools"]}["login_ausfuellen"]
    hub.acquire(kw["holder"])
    try:
        seen["out"] = helper.handler(ARGS)
    finally:
        hub.release()
    return Outcome("Angemeldet.", "end_turn", UsageBook(), [], True, kw["model"], 2, None)


real_engine, real_route = service.engine.run, abos.route
service.engine.run, abos.route = fake_engine, lambda _p: "api"
try:
    reset()
    res = tools["bildschirm_aufgabe"].handler({"auftrag": f"Melde dich mit {VID} an"})
finally:
    service.engine.run, abos.route = real_engine, real_route
ok(res == "Angemeldet." and seen["tools"] == ["login_ausfuellen"], "Helfer bekommt genau das Tresor-Werkzeug")
ok(VID in seen["system"] and SECRET not in seen["system"] and "Dia" in seen["system"], "Helfer kennt den Eintrag, nie das Passwort")
ok(pc.typed == ["arman", SECRET] and pc.keys == ["tab", "return"], "Helfer füllt in Dia aus und sendet ab")
ok(seen["out"].startswith("Ausgefüllt") and SECRET not in seen["out"], "Antwort ohne Passwort")
ok(hub.holder is None, "Rechner danach frei")

print("Sperren beim Ausfüllen")
helper_login = next(x for x in service._tools(t["chat_id"], BID, 0, __import__("aisbot.bots", fromlist=["RunState"]).RunState())
                    if x.schema["name"] == "login_ausfuellen")
hub.acquire(BID)
try:
    for app, url, want, name in (
            ("Dia", "https://andere-seite.test/login", "passt nicht", "falsche Domain in Dia"),
            ("Dia", "https://example-team.vercel.app.evil.test/", "passt nicht", "ähnliche fremde Domain"),
            ("Terminal", None, "Safari, Chrome oder Dia", "anderes Programm vorne"),
            ("Dia", None, "Automation", "Adresse nicht lesbar: Hinweis auf macOS-Erlaubnis")):
        reset(app, url)
        out = helper_login.handler(ARGS)
        ok(want in out and not pc.typed and not pc.keys, f"{name}: nichts getippt")
    for app in ("Safari", "Google Chrome", "Dia"):
        reset(app)
        out = helper_login.handler(ARGS)
        ok(out.startswith("Ausgefüllt") and pc.typed == ["arman", SECRET], f"{app}: passende Seite wird ausgefüllt")
finally:
    hub.release()

print("Codex-Aufgabe (Computer Use)")
run.__dict__["_cu_gate"] = NS(failed=None)
reset()
out = tools["login_ausfuellen"].handler(ARGS)
ok("computer-use" in out and "bildschirm_aufgabe" not in out and not pc.typed, "Rechner noch nicht belegt: Hinweis auf computer-use")
hub.acquire(BID)
try:
    reset()
    out = tools["login_ausfuellen"].handler(ARGS)
finally:
    hub.release()
ok(out.startswith("Ausgefüllt") and pc.typed == ["arman", SECRET], "mit belegtem Rechner füllt die Codex-Aufgabe selbst aus")

print(f"\n{passed} Prüfungen bestanden")
