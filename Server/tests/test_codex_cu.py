"""Test für Computer Use von Codex (Server 1.36, codex_cu.py, docs/computer.md).

Prüft offline mit Fake-Codex (tests/fake_codex_cu.py) und Fake-App:
- Erkennen: nur ChatGPT-Abo + Rechner = Server-Mac + Schalter an + App da + nicht gesperrt; sonst alter Weg.
- Codex-Konfiguration: genau der MCP-Server `computer-use` (über das Startprogramm) im Scoops-CODEX_HOME, sonst nichts.
- Startprogramm: posix_spawn mit disclaim + SETEXEC (Elternprozess bleibt).
- Gate: Bildschirm-Sperre im Hub vor jeder Aktion, andere Scoops warten, „Übernehmen“ pausiert, Abbruch lehnt ab.
- Freigaben: App-Freigabe von Computer Use → Freigabe-Karte im Chat bzw. der Aufgabe, nichts still genehmigt.
- Chat und Aufgaben über die echten Engines: `bildschirm` bzw. `bildschirm_aufgabe` nur als Ersatz; fehlende Rechte →
  Hinweis im Chat, Sperre, nächster Lauf auf dem alten Weg mit Zeile im Verlauf.
- API: Schalter `codex_computer_use` in /api/settings/abos.

Eigene Testinstanz (Temp-Ordner, eigener Port), nie ein echtes Abo, nie die echte App.

    cd Server && AISBOT_SKIP_CONVEX=1 .venv/bin/python tests/test_codex_cu.py
"""

from __future__ import annotations

import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-cu-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
FAKE_APP = TMP / "Codex Computer Use.app"
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_NO_TERMINAL="1",
                  AISBOT_CODEX_CU_APP=str(FAKE_APP))
os.environ.pop("AISBOT_ABO", None)
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from PIL import Image  # noqa: E402

from aisbot import abos, codex_cu, engine_abo, server, workspace  # noqa: E402
from aisbot.engine import USER_HOLDER, ComputerHub  # noqa: E402
import fake_codex_cu as fc  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
http = httpx.Client(base_url=f"http://127.0.0.1:{PORT}", timeout=20)
H = {"Authorization": f"Bearer {TOKEN}"}
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


# -- Fakes ------------------------------------------------------------------------------------------------------------
def make_fake_app() -> None:
    c = FAKE_APP / codex_cu.CLIENT_REL
    c.parent.mkdir(parents=True, exist_ok=True)
    c.write_text("#!/bin/sh\necho fake\n")
    c.chmod(0o755)


class FakeComputer:
    def __init__(self) -> None:
        buf = io.BytesIO()
        Image.new("RGB", (40, 30), "white").save(buf, "PNG")
        self.png = buf.getvalue()
        self.shots = 0

    def screenshot_png(self) -> bytes:
        self.shots += 1
        return self.png


class FakeTransport:
    online, paused, apple = True, False, None
    screen = {"width": 1440, "height": 900}
    name = "Server-Mac"

    def alive(self) -> bool:
        return True

    def post(self, msg: dict) -> None:
        pass


class LocalHub(ComputerHub):
    """Rechner-Knoten „dieser Mac“ (Scoops Connect auf dem Server-Mac)."""

    def __init__(self, node_id: str = "local") -> None:
        super().__init__(url="http://127.0.0.1:9", node_id=node_id, name="Server-Mac", transport=FakeTransport())
        self._computer = FakeComputer()

    def screen_size(self):
        return 1440, 900


LOCAL, VM = LocalHub("local"), LocalHub("vm")
workspace.hub_on_server_mac = lambda hub, db_: getattr(hub, "node_id", "") == "local"
HUBS = {"hub": LOCAL}
service.hub_for = lambda bot_id: HUBS["hub"]
abos.set_status_for_tests("openai", {"installed": True, "logged_in": True, "subscription": True, "method": "chatgpt",
                                     "plan": "pro"})
abos.has_api_key = lambda provider: True


def set_cfg(**kv) -> None:
    cfg = json.loads((TMP / "config.json").read_text())
    cfg.update(kv)
    (TMP / "config.json").write_text(json.dumps(cfg))


def start_server() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: _up(), msg="Server startet")


def _up() -> bool:
    try:
        return http.get("/api/health", headers=H).status_code == 200
    except httpx.HTTPError:
        return False


def make_bot(name: str, model: str = "gpt-6-luna") -> str:
    bid = http.post("/api/bots", headers=H, json={"name": name, "mascot": MASCOT, "model": model}).json()["id"]
    wait_for(lambda: bid not in service.runs, msg="Begrüßung fertig")
    return bid


def send(bid: str, text: str, timeout: float = 20) -> None:
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": text})
    time.sleep(0.2)
    wait_for(lambda: bid not in service.runs, timeout, msg="Lauf fertig")


def msgs(bid: str) -> list[dict]:
    r = http.get(f"/api/bots/{bid}/messages", headers=H, params={"limit": 200}).json()
    return r["messages"] if isinstance(r, dict) else r


def approve_next(bid: str, decision: str = "approve", seen: set | None = None) -> threading.Thread:
    """Gibt die nächste offene Computer-Use-Karte im Chat frei (wie Arman in der App)."""
    seen = seen if seen is not None else set()

    def run() -> None:
        def find():
            for m in msgs(bid):
                meta = m.get("meta") or {}
                if m["role"] == "approval" and meta.get("kind") == "codex_cu" and meta.get("state") == "pending" \
                        and m["id"] not in seen:
                    return m
            return None
        m = wait_for(find, 15, "Computer-Use-Karte")
        seen.add(m["id"])
        http.post(f"/api/approvals/{m['meta']['approval_id']}", headers=H, json={"decision": decision})
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def mcp_servers(overrides) -> set[str]:
    return {o.split(".")[1] for o in overrides if o.startswith("mcp_servers.")}


# -- 1. Grundlagen ----------------------------------------------------------------------------------------------------
def test_basics() -> None:
    print("Erkennen, Zeilen, Fehler deuten")
    ok(codex_cu.line("click", {"app": "com.apple.Safari"}) == "Klickt in Safari", "Zeile „Klickt in Safari“ (Bundle-ID)")
    ok(codex_cu.line("type_text", {"app": "Safari", "text": "example.com"}) == "Tippt „example.com“", "Zeile „Tippt …“")
    ok(codex_cu.line("get_app_state", {"app": "Finder"}) == "Schaut auf Finder", "Zeile „Schaut auf Finder“")
    ok(codex_cu.classify("Computer Use permissions are still pending. The user has not finished granting Accessibility "
                         "and Screen Recording permissions") == "rechte", "fehlende Rechte erkannt")
    ok(codex_cu.classify("Computer Use could not start because its runtime app is missing.") == "fehlt", "fehlende App erkannt")
    ok(codex_cu.classify("bootstrapTimedOut") == "fehler" and codex_cu.classify(
        "Computer Use server error -10000: Sender process is not authenticated") == "fehler", "Startfehler erkannt")
    ok(codex_cu.classify("Computer Use approval denied via MCP elicitation for app 'com.apple.finder'.") is None,
       "abgelehnte App ist kein Fehler von Computer Use")

    # Startprogramm: disclaim + SETEXEC, der gestartete Prozess ersetzt das Startprogramm (Elternprozess bleibt)
    out = subprocess.run([sys.executable, "-I", codex_cu.LAUNCHER, "/bin/sh", "-c", "echo $PPID; echo $0 \"$@\"", "sh",
                          "hallo", "welt"], capture_output=True, text=True, timeout=10)
    lines = out.stdout.split("\n")
    ok(out.returncode == 0 and lines[1] == "sh hallo welt", f"Startprogramm reicht Argumente durch ({out.stderr[:200]})")
    ok(int(lines[0]) == os.getpid(), "Startprogramm ersetzt sich selbst (Codex bleibt Elternprozess)")
    ok("ohne eigene Verantwortlichkeit" not in out.stderr, "disclaim gesetzt (kein Rückfall auf execv)")


def test_decide() -> None:
    print("Wann Computer Use von Codex, wann der alte Weg")
    make_fake_app()
    codex_cu.clear_block()
    ok(codex_cu.decide(LOCAL, db) == (True, None), "Server-Mac + App da → Computer Use")
    ok(codex_cu.decide(VM, db) == (False, None), "VM bzw. anderer Mac → wie bisher, ohne Zeile")
    set_cfg(codex_computer_use=False)
    ok(codex_cu.decide(LOCAL, db) == (False, None), "Schalter aus → wie bisher")
    set_cfg(codex_computer_use=True)
    os.environ["AISBOT_CODEX_CU_APP"] = str(TMP / "fehlt.app")
    use, reason = codex_cu.decide(LOCAL, db)
    ok(not use and "nicht installiert" in reason, "App fehlt → alter Weg mit Grund")
    st = codex_cu.status()
    ok(not st["installed"] and "ChatGPT- bzw. Codex-App" in st["hint"], "Status mit Einrichtungs-Hinweis")
    os.environ["AISBOT_CODEX_CU_APP"] = str(FAKE_APP)
    codex_cu.block("rechte", "permissions are still pending")
    use, reason = codex_cu.decide(LOCAL, db)
    ok(not use and "Rechte" in reason, "fehlende Rechte gemerkt → alter Weg mit Grund")
    ok(json.loads((TMP / "data" / "abo" / "codex_cu.json").read_text())["kind"] == "rechte", "Sperre überlebt Neustart")
    ok("Bedienungshilfen" in codex_cu.status()["hint"], "Hinweis nennt Bedienungshilfen und Bildschirmaufnahme")
    codex_cu.clear_block()

    home = abos.codex_home()
    ov = codex_cu.overrides(home)
    link = home / "computer-use" / codex_cu.APP_NAME
    ok(link.is_symlink() and os.readlink(link) == str(FAKE_APP), "Scoops-CODEX_HOME verweist auf die installierte App")
    ok(mcp_servers(ov) == {"computer-use"}, "genau ein MCP-Server: computer-use")
    args = json.loads(next(o for o in ov if ".args=" in o).split("=", 1)[1])
    ok(args[:2] == ["-I", codex_cu.LAUNCHER] and args[2].endswith(codex_cu.CLIENT_REL) and args[3] == "mcp",
       "Client startet über das Startprogramm")
    ok(any(o == 'mcp_servers.computer-use.default_tools_approval_mode="prompt"' for o in ov), "Aktionen laufen über uns")
    full = service.codex_abo._overrides(True, cu=True)
    ok(mcp_servers(full) == {"scoops", "computer-use"} and "features.plugins=false" in full and
       "features.apps=false" in full, "Chat-Codex: nur scoops + computer-use, keine Plugins/Apps")
    ok(mcp_servers(service.codex_abo._overrides(True)) == {"scoops"}, "ohne Computer Use kein computer-use")
    ok(mcp_servers(tasks._codex_overrides(None, abo=True, cu=True)) == {"scoops", "computer-use"},
       "Aufgaben-Codex: nur scoops + computer-use")


# -- 2. Gate: Sperre, Übernehmen, Freigaben ----------------------------------------------------------------------------
def test_gate() -> None:
    print("Sperre im Hub, Übernehmen, Freigaben")
    hub = LocalHub("local")
    lines: list[str] = []
    cancel = threading.Event()
    hints: list = []
    asked: list = []

    def ask(app, msg):
        asked.append(app)
        return app == "Safari"

    g = codex_cu.Gate(hub, lines.append, cancel, acquire=lambda: hub.acquire("bot1", cancel), release=hub.release,
                      ask_app=ask, on_unavailable=lambda k, h: hints.append((k, h)))
    ok(g.handle(fc.ELICIT, fc.action_request("click")) == {"action": "accept"} and hub.holder == "bot1",
       "vor der Aktion: Rechner im Hub belegt, dann freigegeben")
    g.item_started(fc.McpToolCallThreadItem("click", {"app": "Safari"}))
    g.item_completed(fc.McpToolCallThreadItem("click", {"app": "Safari"}, text="ok"))
    ok("Klickt in Safari" in lines, "Fortschrittszeile aus dem Codex-Ereignis")

    # anderer Scoop wartet
    other = codex_cu.Gate(hub, lambda s: None, None, acquire=lambda: hub.acquire("bot2"), release=hub.release)
    res: dict = {}
    t2 = threading.Thread(target=lambda: res.update(r=other.handle(fc.ELICIT, fc.action_request())), daemon=True)
    t2.start()
    time.sleep(0.4)
    ok("r" not in res and hub.holder == "bot1", "anderer Scoop wartet, solange der Bildschirm belegt ist")

    # Übernehmen: zwischen zwei Aktionen gibt der Scoop frei
    got: dict = {}
    t = threading.Thread(target=lambda: got.update(ok=hub.take_over(5)), daemon=True)
    t.start()
    t.join(6)
    ok(got.get("ok") and hub.holder == USER_HOLDER, "Übernehmen klappt während des Laufs")
    ok(any(x.startswith("Pausiert") for x in lines), "Zeile „Pausiert: Arman hat den Bildschirm übernommen“")
    nxt: dict = {}
    t3 = threading.Thread(target=lambda: nxt.update(r=g.handle(fc.ELICIT, fc.action_request())), daemon=True)
    t3.start()
    time.sleep(0.4)
    ok("r" not in nxt, "nächste Aktion wartet, bis Arman zurückgibt")
    hub.give_back()
    wait_for(lambda: "r" in nxt or "r" in res, 5, "nach dem Zurückgeben geht es weiter")
    # Wer zuerst dran ist, ist egal; danach den anderen durchlassen
    if "r" in res:
        other.close()
    wait_for(lambda: "r" in nxt, 5, "Scoop macht weiter")
    ok(nxt["r"] == {"action": "accept"} and "Macht am Bildschirm weiter" in lines, "Scoop macht nach Rückgabe weiter")
    g.item_completed(fc.McpToolCallThreadItem("click", {"app": "Safari"}, text="ok"))

    # App-Freigaben
    ok(g.handle(fc.ELICIT, fc.app_request("Safari")) == {"action": "accept", "content": {}}, "App freigegeben → accept")
    ok(g.handle(fc.ELICIT, fc.app_request("Mail")) == {"action": "decline"} and asked == ["Safari", "Mail"],
       "App abgelehnt → decline (nichts still genehmigt)")
    url = dict(fc.app_request("X"), mode="url", url="https://example.com")
    ok(g.handle(fc.ELICIT, url) == {"action": "decline"}, "URL-Elicitation abgelehnt")
    h = codex_cu.handler(lambda: g, lambda m, p: {"decision": "decline"})
    ok(h("item/commandExecution/requestApproval", {}) == {"decision": "decline"}, "Shell-Ausweitung weiter abgelehnt")
    ok(codex_cu.handler(lambda: None, lambda m, p: {})(fc.ELICIT, fc.app_request()) == {"action": "decline"},
       "ohne laufendes Gate: Computer-Use-Anfragen abgelehnt")

    # Fehlende Rechte → Rückfall erlaubt, Sperre, Hinweis
    g.item_completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text=(
        "Computer Use permissions are still pending. The user has not finished granting Accessibility and Screen "
        "Recording permissions in the ChatGPT Computer Use window.")))
    ok(g.failed == "rechte" and hints and hints[0][0] == "rechte", "fehlende Rechte: Gate meldet Rückfall und Hinweis")
    ok(codex_cu.blocked()["kind"] == "rechte", "Computer Use für eine Weile gesperrt")
    codex_cu.clear_block()
    cancel.set()
    ok(g.handle(fc.ELICIT, fc.action_request()) == {"action": "decline"}, "angehalten → Aktion abgelehnt")
    g.close()
    other.close()
    ok(hub.holder is None, "Rechner nach dem Lauf frei")


# -- 3. Chat über die echte Codex-Engine ------------------------------------------------------------------------------
def test_chat() -> None:
    print("Chat übers ChatGPT-Abo mit Computer Use von Codex")
    set_cfg(billing={"openai": "abo"}, codex_computer_use=True)
    codex_cu.clear_block()
    bid = make_bot("Cody")
    service.codex_abo.close_all()
    got: dict = {}

    def script(client, items):
        got["holder_before"] = LOCAL.holder
        got["action"] = client.ask(fc.ELICIT, fc.action_request("get_app_state"))
        got["holder"] = LOCAL.holder
        yield fc.started(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}))
        got["app"] = client.ask(fc.ELICIT, fc.app_request("Safari"))
        yield fc.completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text="Computer Use state"))
        tok = client.owner.env.get("AISBOT_ABO_TOKEN")
        tools = engine_abo.MCP_TOKENS[tok][1]
        got["bildschirm"] = tools["bildschirm"].handler({"action": "screenshot"})
        yield from fc.done("Die Überschrift lautet „Example Domain“.")

    fc.FakeCodex.script = script
    seen: set = set()
    approve_next(bid, seen=seen)
    send(bid, "Öffne in Safari example.com und lies die Überschrift vor.")
    cx = fc.FakeCodex.instances[-1]
    ok(mcp_servers(cx.overrides) == {"scoops", "computer-use"}, "Codex-Prozess mit genau scoops + computer-use")
    params = (cx._client.resumes[-1][1] if cx._client.resumes else cx._client.starts[-1])  # Thread des Chats fortgesetzt
    pol = params.approval_policy.root.granular
    ok(pol.mcp_elicitations and not pol.sandbox_approval, "Thread mit Richtlinie granular (nur Elicitations)")
    ok(got["holder_before"] is None and got["action"] == {"action": "accept"} and got["holder"] == bid,
       "vor der ersten Aktion belegt der Scoop den Bildschirm im Hub")
    ok(got["app"] == {"action": "accept", "content": {}}, "App-Freigabe kam als Karte und wurde nach „Freigeben“ erteilt")
    ok(isinstance(got["bildschirm"], str) and "computer-use" in got["bildschirm"],
       "bildschirm verweist auf computer-use, solange das klappt")
    ms = msgs(bid)
    card = next(m for m in ms if m["role"] == "approval" and (m.get("meta") or {}).get("kind") == "codex_cu")
    ok(card["meta"]["state"] == "approved" and "Safari" in card["meta"]["title"], "Karte „Computer Use: Safari bedienen“")
    st = [m for m in ms if m["role"] == "status"][-1]
    ok("Schaut auf Safari" in st["meta"].get("lines", []), f"Statuszeilen: {st['meta'].get('lines')}")
    ok(any(m["role"] == "bot" and "Example Domain" in m["text"] for m in ms), "Antwort des Scoops")
    ok(LOCAL.holder is None, "Bildschirm nach dem Lauf frei")

    # Fehlende Rechte: Hinweis, Rückfall auf bildschirm im selben Lauf
    def script_rights(client, items):
        client.ask(fc.ELICIT, fc.action_request("get_app_state"))
        yield fc.started(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}))
        yield fc.completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text=(
            "Computer Use permissions are still pending. The user has not finished granting Accessibility and "
            "Screen Recording permissions in the ChatGPT Computer Use window.")))
        tools = engine_abo.MCP_TOKENS[client.owner.env.get("AISBOT_ABO_TOKEN")][1]
        got["fallback"] = tools["bildschirm"].handler({"action": "screenshot"})
        yield from fc.done("Über den Scoops-Bildschirm erledigt.")

    fc.FakeCodex.script = script_rights
    shots = LOCAL._computer.shots
    send(bid, "Nochmal bitte.")
    ok(isinstance(got["fallback"], list) and LOCAL._computer.shots > shots, "Rückfall: bildschirm arbeitet im selben Lauf")
    ms = msgs(bid)
    ok(any(m["role"] == "event" and (m.get("meta") or {}).get("codex_cu") == "rechte" and "Bedienungshilfen" in m["text"]
           for m in ms), "Hinweis im Chat: Rechte für Bedienungshilfen/Bildschirmaufnahme einrichten")
    st = [m for m in ms if m["role"] == "status"][-1]
    ok(any("keine macOS-Rechte" in x for x in st["meta"].get("lines", [])), "Zeile im Verlauf: keine macOS-Rechte")

    # Nächster Lauf: gesperrt → alter Weg, mit Zeile warum
    def script_old(client, items):
        tools = engine_abo.MCP_TOKENS[client.owner.env.get("AISBOT_ABO_TOKEN")][1]
        got["old"] = tools["bildschirm"].handler({"action": "screenshot"})
        yield from fc.done("Fertig.")

    fc.FakeCodex.script = script_old
    send(bid, "Und noch einmal.")
    cx = fc.FakeCodex.instances[-1]
    ok("computer-use" not in mcp_servers(cx.overrides) and cx.plain, "gesperrt: Codex ohne computer-use, alter Thread-Weg")
    st = [m for m in msgs(bid) if m["role"] == "status"][-1]
    ok(any("Bildschirm über Scoops statt Codex Computer Use (Codex Computer Use fehlen macOS-Rechte)" in x
           for x in st["meta"].get("lines", [])), "Zeile im Verlauf, warum der alte Weg")
    codex_cu.clear_block()

    # VM: wie bisher, keine Zeile
    HUBS["hub"] = VM
    before = {m["id"] for m in msgs(bid)}
    send(bid, "Auf der VM bitte.")
    cx = fc.FakeCodex.instances[-1]
    new_lines = [x for m in msgs(bid) if m["id"] not in before and m["role"] == "status" for x in m["meta"].get("lines", [])]
    ok("computer-use" not in mcp_servers(cx.overrides) and not any("Codex Computer Use" in x for x in new_lines),
       "Scoop an der VM: alter Weg ohne Zusatzzeile")
    HUBS["hub"] = LOCAL

    # Schalter über die API
    r = http.get("/api/settings/abos", headers=H).json()["codex_computer_use"]
    ok(r["supported"] and r["enabled"] and r["installed"] and r["available"], "API: Schalter und Zustand")
    r = http.patch("/api/settings/abos", headers=H, json={"codex_computer_use": False}).json()["codex_computer_use"]
    ok(r["enabled"] is False, "API: Schalter aus")
    fc.FakeCodex.script = None
    send(bid, "Ohne Computer Use.")
    ok("computer-use" not in mcp_servers(fc.FakeCodex.instances[-1].overrides), "Schalter aus → Codex ohne computer-use")
    ok(http.patch("/api/settings/abos", headers=H, json={"codex_computer_use": "ja"}).status_code == 400,
       "API: ungültiger Wert → 400")
    http.patch("/api/settings/abos", headers=H, json={"codex_computer_use": True})
    service.codex_abo.close_all()
    return bid


# -- 4. Aufgaben ------------------------------------------------------------------------------------------------------
def test_task(bid: str) -> None:
    print("Codex-Aufgabe mit Computer Use")
    from aisbot import tasks as tasks_mod
    orig = tasks._run_engine
    tasks._run_engine = lambda run, message: ("Fertig.", "end")
    try:
        tid = tasks.start(bid, bid, "CU-Test", "Öffne Safari", origin="user")["id"]
        wait_for(lambda: tasks.row(tid)["state"] in ("done", "failed"), msg="Aufgabe angelegt")
    finally:
        tasks._run_engine = orig
    t = tasks.row(tid)
    got: dict = {}

    def script(client, items):
        got["action"] = client.ask(fc.ELICIT, fc.action_request("click"))
        got["holder"] = LOCAL.holder
        yield fc.started(fc.McpToolCallThreadItem("click", {"app": "Safari"}))
        yield fc.completed(fc.McpToolCallThreadItem("click", {"app": "Safari"}, text="ok"))
        got["sub"] = run.__dict__["_tools"]["bildschirm_aufgabe"].handler({"auftrag": "Schau nach"})
        got["app"] = client.ask(fc.ELICIT, fc.app_request("Safari"))
        yield from fc.done("Fertig mit Computer Use.")

    fc.FakeCodex.script = script
    run = tasks_mod.Run(t, tasks_mod.Progress(service, t), "tok")
    run.billing = "abo"
    approve_next(bid)
    final, stop = tasks._run_codex(run, "Öffne Safari")
    cx = fc.FakeCodex.instances[-1]
    ok(final == "Fertig mit Computer Use." and mcp_servers(cx.overrides) == {"scoops", "computer-use"},
       "Codex-Aufgabe mit computer-use")
    ok(got["action"] == {"action": "accept"} and got["holder"] == bid, "Aufgabe belegt den Bildschirm im Hub")
    ok("computer-use" in got["sub"] and run.used_computer, "bildschirm_aufgabe (Claude) entfällt, solange Computer Use klappt")
    ok(got["app"] == {"action": "accept", "content": {}}, "App-Freigabe in der Aufgabe über die Karte im Chat")
    ok(LOCAL.holder is None, "Bildschirm nach der Aufgabe frei")

    # Computer Use fehlt mitten in der Aufgabe → Claude-Teilaufgabe als Ersatz, Rechner vorher freigegeben
    calls: list = []
    real_run = service.engine.run

    def fake_engine_run(**kw):
        calls.append(LOCAL.holder)
        from aisbot.config import UsageBook
        from aisbot.engine import Outcome
        return Outcome("Überschrift: Example Domain", "end_turn", UsageBook(), [], True, kw["model"], 1, None)

    def script_missing(client, items):
        client.ask(fc.ELICIT, fc.action_request("get_app_state"))
        yield fc.started(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}))
        yield fc.completed(fc.McpToolCallThreadItem("get_app_state", {"app": "Safari"}, text=(
            "Computer Use could not start because its runtime app is missing.")))
        got["sub2"] = run.__dict__["_tools"]["bildschirm_aufgabe"].handler({"auftrag": "Lies die Überschrift"})
        yield from fc.done("Fertig über den Ersatz.")

    service.engine.run = fake_engine_run
    fc.FakeCodex.script = script_missing
    try:
        run = tasks_mod.Run(t, tasks_mod.Progress(service, t), "tok")
        run.billing = "abo"
        final, _ = tasks._run_codex(run, "Lies die Überschrift")
    finally:
        service.engine.run = real_run
    ok(got["sub2"] == "Überschrift: Example Domain" and calls == [None], "Ersatz über bildschirm_aufgabe, Rechner vorher frei")
    ok(codex_cu.blocked()["kind"] == "fehlt", "fehlende App gemerkt")
    codex_cu.clear_block()


def main() -> None:
    restore = fc.install()
    try:
        start_server()
        test_basics()
        test_decide()
        test_gate()
        bid = test_chat()
        test_task(bid)
    finally:
        restore()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    import traceback
    try:
        main()
    except BaseException:  # noqa: BLE001
        traceback.print_exc()
        sys.stdout.flush()
        os._exit(1)
    sys.stdout.flush()
    os._exit(0)
