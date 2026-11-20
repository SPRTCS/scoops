"""Test für Bilder über das ChatGPT-Abo (Server 1.39, bilder.py, docs/bilder.md).

Prüft offline mit Fake-Codex (tests/fake_codex_cu.py, liefert `imageGeneration`-Items wie Codex 0.169):
- Verfügbarkeit: nur mit ChatGPT-Login in Codex, abschaltbar, im Test nur mit ausdrücklichem `images: true`; ohne Abo
  ein Satz in der Systemanweisung; Feld `images` in /api/health.
- Werkzeuge bild_erstellen/bild_bearbeiten in Chat-Läufen (nicht für Gäste, nicht ohne Abo) und in Aufgaben.
- Bildlauf: eigener Codex-Prozess ohne Shell, ohne Web, ohne MCP-Server, Nur-Lese-Sandbox, flüchtiger Thread;
  Eingabebilder aus Bibliothek, „zuletzt“ und Arbeitsordner (nur im Bereich), Größen- und Anzahlgrenzen, Verkleinern.
- Ergebnis: Bibliothek, Arbeitsordner (Dateien/ bzw. Aufgaben/), Karte im Chat, Bild im Werkzeug-Ergebnis, Nutzung als
  Abo-Lauf; Temp-Ordner und Codex-Datei aufgeräumt.
- Fehler: Limit, abgelaufene Anmeldung, Ablehnung, Zeitlimit, Stopp, höchstens zwei Bildläufe gleichzeitig.
- ChatGPT-Scoop im Codex-Weg: eingebautes Bildwerkzeug an, fertige Bilder landen in Bibliothek und Chat.
- Codex-Aufgaben: eingebautes Bildwerkzeug aus (nie über den API-Schlüssel).

Eigene Testinstanz (Temp-Ordner, eigener Port), nie ein echtes Abo, kein Netz.

    cd Server && AISBOT_SKIP_CONVEX=1 .venv/bin/python tests/test_bilder.py
"""

from __future__ import annotations

import base64
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace as NS

TMP = Path(tempfile.mkdtemp(prefix="aisbot-bilder-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_NO_TERMINAL="1",
                  AISBOT_WORKSPACE=str(TMP / "Scoops"))
os.environ.pop("AISBOT_ABO", None)
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from PIL import Image  # noqa: E402

from aisbot import abos, bilder, engine_abo, server, sharing, workspace  # noqa: E402
from aisbot.bots import RunState, load_config  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402
import fake_codex_cu as fc  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
http = httpx.Client(base_url=f"http://127.0.0.1:{PORT}", timeout=20)
H = {"Authorization": f"Bearer {TOKEN}"}
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
LOGGED_IN = {"installed": True, "logged_in": True, "subscription": True, "method": "chatgpt", "plan": "pro"}
LOGGED_OUT = {"installed": True, "logged_in": False, "subscription": False}
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


def set_cfg(**kv) -> None:
    cfg = json.loads((TMP / "config.json").read_text())
    for k, v in kv.items():
        if v is None:
            cfg.pop(k, None)
        else:
            cfg[k] = v
    (TMP / "config.json").write_text(json.dumps(cfg))


def png(w: int = 64, h: int = 48, color="red", mode: str = "RGB") -> bytes:
    buf = io.BytesIO()
    Image.new(mode, (w, h), color).save(buf, "PNG")
    return buf.getvalue()


# -- Fake-Codex: Bild-Items wie Codex 0.169 ----------------------------------------------------------------------------
HANDLES: list = []
_orig_turn = fc.FakeThread.turn


def _turn(self, items, effort=None):
    h = _orig_turn(self, items, effort)
    h.thread_id = self.id
    HANDLES.append(h)
    return h


fc.FakeThread.turn = _turn
SEEN: list[dict] = []  # pro Zug: Texte und Eingabebilder (Größe, Pixel), solange die Dateien noch da sind


def image_item(thread_id: str, data: bytes | None = None, status: str = "completed", failure=None, file: bool = True,
               revised: str = "A red apple") -> NS:
    data = png(120, 80, "green") if data is None and status == "completed" else data
    path = None
    if data and file:
        d = bilder.generated_dir() / thread_id
        d.mkdir(parents=True, exist_ok=True)
        path = d / f"exec-{os.urandom(3).hex()}.png"
        path.write_bytes(data)
    return NS(type="imageGeneration", id="exec-1", status=status, saved_path=str(path) if path else None,
              result=base64.b64encode(data).decode() if data else "", failure=failure, revised_prompt=revised,
              transparent_background=False)


def record(items) -> dict:
    texts = [getattr(i, "text", "") for i in items if hasattr(i, "text")]
    imgs = []
    for i in items:
        p = getattr(i, "path", None)
        if p:
            im = Image.open(p)
            imgs.append({"path": p, "size": im.size, "bytes": Path(p).stat().st_size})
    d = {"texts": texts, "images": imgs}
    SEEN.append(d)
    return d


def handle_for(items):
    return next(h for h in reversed(HANDLES) if h.items is items)


def script_ok(data: bytes | None = None, file: bool = True):
    def script(client, items):
        record(items)
        h = handle_for(items)
        it = image_item(h.thread_id, data, file=file)
        yield fc.started(NS(type="imageGeneration", id="exec-1", status="in_progress"))
        yield fc.completed(it)
        yield from fc.done("Fertig.")
    return script


def script_block(release: threading.Event):
    def script(client, items):
        record(items)
        h = handle_for(items)
        yield fc.started(NS(type="imageGeneration", id="exec-1", status="in_progress"))
        while not release.is_set() and not h.interrupted.is_set():
            time.sleep(0.02)
        if h.interrupted.is_set():
            yield fc.ev("turn/completed", turn=NS(error=None, items=[]))
            return
        yield fc.completed(image_item(h.thread_id))
        yield from fc.done("Fertig.")
    return script


# -- Server und Scoops ------------------------------------------------------------------------------------------------
class FakeApi:
    calls: list[dict] = []

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        u = Usage(kw["model"])
        book = UsageBook()
        book.by_model[kw["model"]] = u
        return Outcome("OK", "end_turn", book, [], False, kw["model"], 1, list(kw.get("messages") or []))


service.engine.run = FakeApi.run
service.openai_engine.run = FakeApi.run
service.claude_abo.run = FakeApi.run
abos.has_api_key = lambda provider: True


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


def tool_map(bid: str, st: RunState | None = None, **kw) -> dict:
    return {t.schema["name"]: t for t in service._tools(bid, bid, 0, st or RunState(), **kw)}


def system_text(kw: dict) -> str:
    sysp = kw.get("system")
    return sysp if isinstance(sysp, str) else "\n".join(b.get("text", "") for b in sysp or [])


def bilder_tmp_empty() -> bool:
    d = abos.abo_dir() / "bilder"
    return not d.exists() or not any(d.iterdir())


def generated_empty() -> bool:
    d = bilder.generated_dir()
    return not d.exists() or not any(d.rglob("*.png"))


# -- 1. Verfügbarkeit -------------------------------------------------------------------------------------------------
def test_available() -> None:
    print("Verfügbarkeit")
    abos.set_status_for_tests("openai", LOGGED_IN)
    set_cfg(images=None)
    ok(bilder.available() == (False, "offline"), "Test-/Offline-Modus ohne images: true → aus (nie still ein echtes Abo)")
    set_cfg(images=True)
    ok(bilder.available() == (True, None), "ChatGPT-Abo angemeldet → verfügbar")
    ok(bilder.prompt_note("Arman") is None, "mit Abo kein Hinweis in der Systemanweisung")
    abos.set_status_for_tests("openai", LOGGED_OUT)
    ok(bilder.available() == (False, "nicht verbunden"), "ohne ChatGPT-Login → nicht verfügbar")
    note = bilder.prompt_note("Arman") or ""
    ok("KI-Abos" in note and "ChatGPT" in note and "API" in note, "ohne Abo: ein Satz, was zu tun ist, kein API-Weg")
    h = http.get("/api/health", headers=H).json()["images"]
    ok(h["supported"] and not h["available"] and "KI-Abos" in (h["hint"] or ""), f"/api/health meldet images: {h}")
    abos.set_status_for_tests("openai", {"installed": True, "logged_in": True, "subscription": False, "method": "api_key"})
    ok(not bilder.available()[0], "Codex nur mit API-Schlüssel angemeldet → nicht verfügbar (kein API-Weg)")
    abos.set_status_for_tests("openai", LOGGED_IN)
    set_cfg(images=False)
    ok(bilder.available() == (False, "aus"), "abschaltbar mit images: false")
    set_cfg(images=True)
    h = http.get("/api/health", headers=H).json()["images"]
    ok(h == {"supported": True, "available": True, "via": "chatgpt_abo", "hint": None}, "/api/health: verfügbar")


# -- 2. Werkzeuge in den Läufen ---------------------------------------------------------------------------------------
def test_tools_in_runs(bid: str) -> None:
    print("Werkzeuge in Chat-Läufen")
    FakeApi.calls.clear()
    send(bid, "Mal mir was.")
    names = {t.schema["name"] for t in FakeApi.calls[-1]["extra_tools"]}
    ok({"bild_erstellen", "bild_bearbeiten"} <= names, "Claude-Scoop: bild_erstellen und bild_bearbeiten im Lauf")
    ok("ChatGPT verbinden" not in system_text(FakeApi.calls[-1]), "mit Abo kein Abo-Hinweis")
    abos.set_status_for_tests("openai", LOGGED_OUT)
    send(bid, "Und jetzt?")
    names = {t.schema["name"] for t in FakeApi.calls[-1]["extra_tools"]}
    ok(not names & set(bilder.IMAGE_TOOLS), "ohne ChatGPT-Abo keine Bildwerkzeuge")
    ok("ChatGPT verbinden" in system_text(FakeApi.calls[-1]), "ohne Abo: Hinweis in der Systemanweisung")
    abos.set_status_for_tests("openai", LOGGED_IN)
    guest = {"user_id": "u_gast", "name": "Gast"}
    gtools = sharing.normalize_tools({"web": True, "computer": True, "mail": True, "phone": True})
    ok(not set(tool_map(bid, guest=guest, gtools=gtools)) & set(bilder.IMAGE_TOOLS),
       "Gast-Läufe nie mit Bildwerkzeugen (Abo des Admins ist persönlich)")
    schema = tool_map(bid)["bild_bearbeiten"].schema
    ok(schema["input_schema"]["required"] == ["bilder", "anweisung"] and "ChatGPT-Abo" in schema["description"],
       "bild_bearbeiten: bilder + anweisung, Beschreibung nennt das ChatGPT-Abo")


# -- 3. Bild erstellen -------------------------------------------------------------------------------------------------
def test_create(bid: str) -> str:
    print("bild_erstellen")
    before = {m["id"] for m in msgs(bid)}
    fc.FakeCodex.script = script_ok(png(200, 100, (10, 200, 30)))
    n0 = len(fc.FakeCodex.instances)
    out = tool_map(bid)["bild_erstellen"].handler({"beschreibung": "Ein grüner Frosch auf einem Seerosenblatt",
                                                   "format": "16:9", "transparent": True})
    ok(isinstance(out, list) and out[1]["type"] == "image" and out[1]["source"]["data"],
       "Ergebnis mit Text und dem Bild selbst (zum Ansehen und Nachbessern)")
    text = out[0]["text"]
    ok("Ein grüner Frosch auf einem Seerosenblatt.png" in text and "200×100 PNG" in text, f"Text nennt Name und Maße: {text[:160]}")
    cx = fc.FakeCodex.instances[-1]
    ok(len(fc.FakeCodex.instances) == n0 + 1, "eigener Codex-Prozess für den Bildlauf")
    ov = cx.overrides
    ok("features.shell_tool=false" in ov and 'web_search="disabled"' in ov and "features.image_generation=true" in ov,
       "Codex ohne Shell und Web, Bildwerkzeug an")
    ok(not any(o.startswith("mcp_servers.") for o in ov) and "features.plugins=false" in ov,
       "keine MCP-Server, keine Plugins")
    ok(cx.env.get("CODEX_HOME") == str(abos.codex_home()) and cx.env.get("OPENAI_API_KEY") == "",
       "Scoops-CODEX_HOME (ChatGPT-Login), API-Schlüssel geleert")
    kw = cx.plain[-1][1]
    ok(str(kw["sandbox"]).endswith("read_only") and kw["ephemeral"] and "Bildgenerator" in kw["base_instructions"],
       "Nur-Lese-Sandbox, flüchtiger Thread, eigene Anweisung")
    ok("Seitenverhältnis: 16:9" in SEEN[-1]["texts"][0] and "Transparenter Hintergrund" in SEEN[-1]["texts"][0],
       "Auftrag mit Seitenverhältnis und transparentem Hintergrund")
    files = [f for f in db.files(bid) if f["name"] == "Ein grüner Frosch auf einem Seerosenblatt.png"]
    ok(files and files[0]["kind"] == "bild" and files[0]["author_id"] == bid, "in der Bibliothek des Chats")
    fid = files[0]["id"]
    ws = workspace.files_dir(db.bot_row(bid), load_config()) / "Ein grüner Frosch auf einem Seerosenblatt.png"
    ok(ws.exists() and Image.open(ws).size == (200, 100), "Kopie im Arbeitsordner (Dateien/)")
    ev = [m for m in msgs(bid) if m["id"] not in before and m["role"] == "event"]
    ok(ev and ev[-1]["meta"].get("file_id") == fid and ev[-1]["meta"].get("icon") == "photo"
       and ev[-1]["text"].startswith("Bild erstellt:"), "Karte „Bild erstellt: …“ mit Bild im Chat")
    ok(fid in (ev[-1]["meta"].get("prompt") or ""), "der Scoop sieht im Verlauf die Bibliotheks-ID")
    ok(generated_empty() and bilder_tmp_empty(), "Codex-Datei und Temp-Ordner aufgeräumt")
    rows = db.q("SELECT model, billing, dollars FROM usage WHERE bot_id=? AND model=?", (bid, bilder.image_model()))
    ok(rows and rows[-1]["billing"] == "abo" and rows[-1]["dollars"] == 0, "Nutzung als Abo-Lauf ohne Betrag")
    u = http.get("/api/usage", headers=H).json()["abo"]
    ok(u["month_runs"] >= 1 and bilder.image_model() in u["by_model"], "erscheint in der Nutzungsübersicht (Abo)")
    # gewünschter Dateiname mit .jpg → JPEG; ohne Datei nur Base64 im Item
    fc.FakeCodex.script = script_ok(png(50, 50, "blue"), file=False)
    out = tool_map(bid)["bild_erstellen"].handler({"beschreibung": "Logo", "dateiname": "Logo Entwurf.jpg"})
    f = next(f for f in db.files(bid) if f["name"] == "Logo Entwurf.jpg")
    ok(f["mime"] == "image/jpeg" and Image.open(db.file_row(f["id"])["path"]).format == "JPEG",
       "Dateiname .jpg → als JPEG gespeichert (Bild aus dem Base64-Feld)")
    ok("Seitenverhältnis: 1:1" in SEEN[-1]["texts"][0], "ohne format: 1:1")
    return fid


# -- 4. Bild bearbeiten -----------------------------------------------------------------------------------------------
def test_edit(bid: str, other: str, fid: str) -> None:
    print("bild_bearbeiten")
    tm = tool_map(bid)
    fc.FakeCodex.script = script_ok()
    ws_dir = workspace.bot_dir(db.bot_row(bid), load_config())
    (ws_dir / "Entwürfe").mkdir(parents=True, exist_ok=True)
    (ws_dir / "Entwürfe" / "gross.png").write_bytes(png(3000, 2000, "yellow"))
    out = tm["bild_bearbeiten"].handler({"bilder": [fid, "Entwürfe/gross.png"], "anweisung": "Frosch blau färben"})
    ok(isinstance(out, list) and "Bearbeitet und gespeichert" in out[0]["text"], f"bearbeitet: {str(out)[:200]}")
    seen = SEEN[-1]
    ok(len(seen["images"]) == 2 and max(seen["images"][1]["size"]) == bilder.INPUT_MAX_SIDE,
       "zwei Eingabebilder als lokale Dateien, großes auf 2048 px verkleinert")
    ok("Bild 1 = Ein grüner Frosch auf einem Seerosenblatt.png" in seen["texts"][0] and "wie Bild 1" in seen["texts"][0],
       "Auftrag nennt die Bilder in Reihenfolge, Seitenverhältnis wie Bild 1")
    ok(any(m["role"] == "event" and m["text"].startswith("Bild bearbeitet:") for m in msgs(bid)), "Karte „Bild bearbeitet“")
    # Anhang des Nutzers („zuletzt“ = neuestes Bild im Chat)
    att = db.add_file(bid, None, "Urlaub.jpg", png(30, 30, "white"), "image/png")
    tm["bild_bearbeiten"].handler({"bilder": ["zuletzt"], "anweisung": "Himmel blauer"})
    ok(SEEN[-1]["texts"][0].count("angehängte Bild") == 1, "„zuletzt“ nimmt das neueste Bild im Chat")
    ok(SEEN[-1]["images"][0]["size"] == (30, 30), "Anhang des Nutzers als Eingabe")
    n = len(SEEN)
    foreign = db.add_file(other, None, "Fremd.png", png(), "image/png")
    r = tm["bild_bearbeiten"].handler({"bilder": [foreign["id"]], "anweisung": "x"})
    ok(isinstance(r, str) and "nicht gefunden" in r and len(SEEN) == n, "Bild aus einem anderen Chat → abgelehnt, kein Lauf")
    outside = TMP / "draussen.png"
    outside.write_bytes(png())
    r = tm["bild_bearbeiten"].handler({"bilder": [str(outside)], "anweisung": "x"})
    ok(isinstance(r, str) and "außerhalb" in r, f"Pfad außerhalb des Bereichs → abgelehnt ({r[:80]})")
    r = tm["bild_bearbeiten"].handler({"bilder": [att["id"]] * 5, "anweisung": "x"})
    ok(isinstance(r, str) and "Höchstens 4" in r, "mehr als 4 Eingabebilder → abgelehnt")
    txt = db.add_file(bid, bid, "Notiz.md", b"# Hallo", "text/markdown")
    r = tm["bild_bearbeiten"].handler({"bilder": [txt["id"]], "anweisung": "x"})
    ok(isinstance(r, str) and "kein Bild" in r, "Textdatei als Eingabe → abgelehnt")
    old = bilder.INPUT_MAX_BYTES
    bilder.INPUT_MAX_BYTES = 50
    try:
        r = tm["bild_bearbeiten"].handler({"bilder": [fid], "anweisung": "x"})
        ok(isinstance(r, str) and "größer als" in r, "zu große Eingabe → abgelehnt")
    finally:
        bilder.INPUT_MAX_BYTES = old
    ok(len(SEEN) == n, "abgelehnte Eingaben starten keinen Codex-Lauf")
    r = tm["bild_bearbeiten"].handler({"bilder": [], "anweisung": "x"})
    ok(isinstance(r, str) and "bilder fehlt" in r, "ohne Eingabebild → Hinweis")


# -- 5. Fehler, Stopp, Grenzen ----------------------------------------------------------------------------------------
def test_errors(bid: str) -> None:
    print("Fehler, Stopp, Grenzen")
    tm = tool_map(bid)

    def script_fail(client, items):
        h = handle_for(items)
        fail = NS(root=NS(type="usageLimitExceeded", limit_id="images", resets_at=int(time.time()) + 3600))
        yield fc.completed(image_item(h.thread_id, None, status="failed", failure=fail))
        yield from fc.done("Limit.")

    fc.FakeCodex.script = script_fail
    r = tm["bild_erstellen"].handler({"beschreibung": "Ein Hund"})
    ok(isinstance(r, str) and "Bild-Limit des ChatGPT-Abos" in r and "wieder ab" in r and "API" in r,
       f"Bild-Limit → verständliche Meldung, kein API-Weg ({r[:120]})")
    ok(abos.limited("openai") is None, "Bild-Limit schickt Chats nicht auf die API")

    def script_turn_error(msg):
        def script(client, items):
            yield fc.ev("turn/completed", turn=NS(error=NS(message=msg), items=[]))
        return script

    fc.FakeCodex.script = script_turn_error("You've hit your usage limit. Try again later.")
    r = tm["bild_erstellen"].handler({"beschreibung": "Ein Hund"})
    ok("Kein Bild" in r and "API" in r and abos.limited("openai"), "Abo-Limit im Zug → Meldung, Limit vermerkt")
    abos.clear_limit("openai")
    fc.FakeCodex.script = script_turn_error("401 Unauthorized: token expired")
    r = tm["bild_erstellen"].handler({"beschreibung": "Ein Hund"})
    ok("neu verbinden" in r and "KI-Abos" in r, "abgelaufene Anmeldung → neu verbinden")

    def script_refuse(client, items):
        yield from fc.done("Abgelehnt: Das verstößt gegen die Inhaltsrichtlinien.")

    fc.FakeCodex.script = script_refuse
    r = tm["bild_erstellen"].handler({"beschreibung": "etwas Verbotenes"})
    ok("Codex hat kein Bild erzeugt: Das verstößt gegen die Inhaltsrichtlinien" in r and "ehrlich" in r,
       "inhaltliche Ablehnung → Grund an den Scoop")
    abos.set_status_for_tests("openai", LOGGED_OUT)
    r = tm["bild_erstellen"].handler({"beschreibung": "Ein Hund"})
    ok("kein ChatGPT-Abo verbunden" in r and "KI-Abos" in r, "Abo zwischendurch abgemeldet → Satz, was zu tun ist")
    abos.set_status_for_tests("openai", LOGGED_IN)

    # Zeitlimit
    release = threading.Event()
    fc.FakeCodex.script = script_block(release)
    t0 = time.time()
    try:
        bilder.generate("Ein Hund", timeout=0.6)
        ok(False, "Zeitlimit")
    except bilder.ImageError as e:
        ok("Zeitlimit" in str(e) and time.time() - t0 < 5, "Zeitlimit → Lauf unterbrochen, Meldung")
    ok(bilder.active_runs() == 0 and bilder_tmp_empty(), "nach Zeitlimit aufgeräumt")

    # höchstens zwei gleichzeitig, Stopp bricht ab
    sts = [RunState() for _ in range(3)]
    results: list = [None, None, None]

    def go(k: int) -> None:
        results[k] = tool_map(bid, st=sts[k])["bild_erstellen"].handler({"beschreibung": f"Bild {k}"})

    threads = [threading.Thread(target=go, args=(k,), daemon=True) for k in range(3)]
    for t in threads:
        t.start()
        time.sleep(0.15)
    wait_for(lambda: bilder.active_runs() == 2, 5, "zwei Bildläufe aktiv")
    time.sleep(0.3)
    ok(bilder.active_runs() == 2, f"höchstens {bilder.MAX_PARALLEL} Bildläufe gleichzeitig, der dritte wartet")
    sts[0].cancel.set()
    wait_for(lambda: results[0] is not None, 5, "Stopp beendet den Lauf")
    ok("Abgebrochen" in results[0], "Stopp im Chat bricht den Bildlauf ab")
    wait_for(lambda: bilder.active_runs() == 2, 5, "der wartende startet")
    release.set()
    for t in threads:
        t.join(10)
    ok(all(isinstance(x, list) for x in results[1:]), "die anderen beiden werden fertig")
    ok(bilder.active_runs() == 0 and bilder_tmp_empty() and generated_empty(), "alles aufgeräumt")


# -- 6. ChatGPT-Scoop im Codex-Weg ------------------------------------------------------------------------------------
def test_codex_chat() -> None:
    print("ChatGPT-Scoop: eingebautes Bildwerkzeug von Codex")
    set_cfg(billing={"openai": "abo"})
    service.codex_abo.run = engine_abo.CodexChatEngine.run.__get__(service.codex_abo)  # echte Engine, Fake-Codex
    bid = make_bot("Cody", "gpt-6-luna")
    service.codex_abo.close_all()
    got: dict = {}

    def script(client, items):
        tok = client.owner.env.get("AISBOT_ABO_TOKEN")
        got["tools"] = set(engine_abo.MCP_TOKENS[tok][1])
        tid = next(t for t in reversed(HANDLES) if t.items is items).thread_id
        yield fc.started(NS(type="imageGeneration", id="exec-9", status="in_progress"))
        yield fc.completed(image_item(tid, png(90, 90, "orange")))
        yield from fc.done("Hier ist dein Bild.")

    fc.FakeCodex.script = script
    before = {m["id"] for m in msgs(bid)}
    send(bid, "Mal mir eine Orange.")
    cx = fc.FakeCodex.instances[-1]
    ok("features.image_generation=true" in cx.overrides, "Codex-Chat mit eingebautem Bildwerkzeug")
    ok(not got["tools"] & set(bilder.IMAGE_TOOLS), "keine doppelten Werkzeuge (bild_* nicht über /mcp/abo)")
    kw = cx.plain[-1][1]
    ok("eingebauten Bildwerkzeug" in kw["base_instructions"], "Systemanweisung erklärt das Bildwerkzeug")
    new = [m for m in msgs(bid) if m["id"] not in before]
    ev = [m for m in new if m["role"] == "event" and (m.get("meta") or {}).get("file_id")]
    ok(ev and ev[0]["text"].startswith("Bild erstellt: Bild "), "fertiges Bild als Karte im Chat")
    f = db.file_row(ev[0]["meta"]["file_id"])
    ok(f and f["chat_id"] == bid and f["kind"] == "bild", "in der Bibliothek des Chats")
    ok((workspace.files_dir(db.bot_row(bid), load_config()) / f["name"]).exists(), "Kopie im Arbeitsordner")
    st = next(m for m in new if m["role"] == "status")
    ok("Erstellt ein Bild" in st["meta"].get("lines", []), "Statuszeile „Erstellt ein Bild“")
    ok(generated_empty(), "Codex-Datei nach dem Speichern entfernt")
    ok(any(m["role"] == "bot" and "Hier ist dein Bild" in m["text"] for m in new), "Antwort des Scoops")
    # abgeschaltet: Bildwerkzeug aus
    set_cfg(images=False)
    fc.FakeCodex.script = None
    send(bid, "Noch eins.")
    ok("features.image_generation=false" in fc.FakeCodex.instances[-1].overrides, "images: false → Bildwerkzeug aus")
    set_cfg(images=True, billing={})
    service.codex_abo.close_all()


# -- 7. Aufgaben ------------------------------------------------------------------------------------------------------
def test_task(bid: str) -> None:
    print("Aufgaben")
    from aisbot import tasks as tasks_mod
    orig = tasks._run_engine
    tasks._run_engine = lambda run, message: ("Fertig.", "end")
    try:
        tid = tasks.start(bid, bid, "Bild-Test", "Mach ein Bild", origin="user")["id"]
        wait_for(lambda: tasks.row(tid)["state"] in ("done", "failed"), msg="Aufgabe angelegt")
    finally:
        tasks._run_engine = orig
    t = tasks.row(tid)
    run = tasks_mod.Run(t, tasks_mod.Progress(service, t), "tok")
    tl = tasks.tools_for(run)
    ok({"bild_erstellen", "bild_bearbeiten"} <= set(tl), "Aufgaben haben die Bildwerkzeuge")
    fc.FakeCodex.script = script_ok(png(40, 40, "purple"))
    out = tl["bild_erstellen"].handler({"beschreibung": "Ein lila Quadrat"})
    ok(isinstance(out, list) and "im Arbeitsordner der Aufgabe: bilder/Ein lila Quadrat.png" in out[0]["text"],
       f"Pfad im Arbeitsordner der Aufgabe zurück ({out[0]['text'][:200] if isinstance(out, list) else out})")
    wd = Path(t["workdir"])
    ok((wd / "bilder" / "Ein lila Quadrat.png").exists(), "Bild liegt im Arbeitsordner der Aufgabe (bilder/)")
    t2 = tasks.row(tid)
    fid = next(f["id"] for f in db.files(bid) if f["name"] == "Ein lila Quadrat.png")
    ok(fid in json.loads(t2["files"] or "[]"), "bei der Aufgabe als Datei vermerkt")
    task_dir = workspace.task_dir(db.bot_row(bid), load_config(), t2)
    ok((task_dir / "Ein lila Quadrat.png").exists(), "Kopie im Arbeitsordner unter Aufgaben/<Datum Titel>/")
    ev = [m for m in msgs(bid) if (m.get("meta") or {}).get("file_id") == fid]
    ok(ev and ev[0]["meta"].get("task_id") == tid, "Karte im Chat mit Bezug zur Aufgabe")
    # Eingabe relativ zum Arbeitsordner der Aufgabe
    (wd / "eingang").mkdir(exist_ok=True)
    (wd / "eingang" / "foto.png").write_bytes(png(20, 20))
    out = tl["bild_bearbeiten"].handler({"bilder": ["eingang/foto.png"], "anweisung": "heller"})
    ok(isinstance(out, list), "Eingabebild relativ zum Arbeitsordner der Aufgabe")
    ov = " ".join(tasks._codex_overrides()) + " " + " ".join(tasks._codex_overrides(abo=True))
    ok(ov.count("features.image_generation=false") == 2, "Codex-Aufgaben: eingebautes Bildwerkzeug aus (nie über die API)")


def main() -> None:
    restore = fc.install()
    try:
        start_server()
        abos.set_status_for_tests("openai", LOGGED_IN)
        test_available()
        bid = make_bot("Malo")
        other = make_bot("Andere")
        test_tools_in_runs(bid)
        fid = test_create(bid)
        test_edit(bid, other, fid)
        test_errors(bid)
        test_codex_chat()
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
