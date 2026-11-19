"""Test für die KI-Abos (Server 1.30, docs/abos.md): Abrechnungsmodus und Weg pro Anbieter, Fallback auf die API bei
Abo-Limit (mit Hinweis), Chat über Claude Code/Codex mit Sitzung pro Chat (nur neue Nachrichten), Abo-Nutzung getrennt
ohne Betrag, Aufgaben im Abo-Modus ohne Schlüssel und eigene Config, Erkennung von Limits in der Claude-Code-Engine
(Fake-SDK-Nachrichten) und dass nirgends Anmeldedaten gelesen werden.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engines ohne KI-Aufruf) – niemals die Produktion und
nie ein echtes Abo.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_abos.py
"""

from __future__ import annotations

import asyncio
import builtins
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-abo-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_NO_TERMINAL="1")
os.environ.pop("AISBOT_ABO", None)
SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import abos, engine_abo, server  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.engine import ExtraTool, Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
LOGGED_IN = {"installed": True, "logged_in": True, "subscription": True, "method": "claude.ai", "plan": "max"}
LOGGED_OUT = {"installed": True, "logged_in": False, "subscription": False}


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


def set_billing(**modes) -> None:
    cfg = json.loads((TMP / "config.json").read_text())
    cfg["billing"] = {k: v for k, v in modes.items() if v}
    (TMP / "config.json").write_text(json.dumps(cfg))


# -- Fake-Engines ---------------------------------------------------------------------------------------------------
class FakeApi:
    calls: list[dict] = []

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        u = Usage(kw["model"])
        u.input_tokens = 1000
        book = UsageBook()
        book.by_model[kw["model"]] = u
        return Outcome("Antwort über API", "end_turn", book, [], False, kw["model"], 1, list(kw.get("messages") or []))


class FakeAbo:
    calls: list[dict] = []
    fail: abos.SubscriptionUnavailable | None = None
    sid = "sess-1"

    @classmethod
    def run(cls, **kw):
        cls.calls.append(kw)
        if cls.fail:
            e, cls.fail = cls.fail, None
            raise e
        book = UsageBook(billing="abo")
        book.add_counts(kw["model"], 500, 50, 2000, 0, 1)
        if kw.get("on_line"):
            kw["on_line"]("Schaut nach")
        out = Outcome("Antwort übers Abo", "end_turn", book, ["Schaut nach"], False, kw["model"], 1, None)
        out.session_id = kw.get("session_id") or cls.sid
        out.billing = "abo"
        return out


service.engine.run = FakeApi.run
service.openai_engine.run = FakeApi.run
service.claude_abo.run = FakeAbo.run
service.codex_abo.run = FakeAbo.run
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
    r = http.post("/api/bots", headers=H, json={"name": name, "mascot": MASCOT, "model": model})
    bid = r.json()["id"]
    wait_for(lambda: bid not in service.runs, msg="Begrüßung fertig")
    return bid


def send(bid: str, text: str) -> None:
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": text})
    time.sleep(0.2)
    wait_for(lambda: bid not in service.runs, msg="Lauf fertig")


def text_of(kw: dict) -> str:
    return json.dumps(kw.get("messages"), ensure_ascii=False)


# -- 1. Modus und Weg -----------------------------------------------------------------------------------------------
def test_modes() -> None:
    print("Abrechnungsmodus und Weg")
    abos.clear_limit("claude")
    abos.set_status_for_tests("claude", LOGGED_IN)
    abos.set_status_for_tests("openai", LOGGED_OUT)
    set_billing()
    ok(abos.mode("claude") == "api", "ohne Einstellung im Test-/Offline-Modus: API (nie still übers echte Abo)")
    os.environ["AISBOT_ABO"] = "1"
    ok(abos.mode("claude") == "abo_api", "ohne Einstellung, mit Abo-Login: automatisch „Abo, bei Limit API“")
    ok(abos.mode("openai") == "api", "ohne Einstellung, ohne Login: „API-Schlüssel“ (Standard für andere Nutzer)")
    os.environ.pop("AISBOT_ABO")
    set_billing(claude="abo_api", openai="abo")
    ok(abos.route("claude") == "abo", "abo_api + Login → Abo")
    ok(abos.route("openai") == "abo", "abo ohne Login → Abo-Weg (meldet dann klar „nicht angemeldet“)")
    set_billing(claude="abo_api", openai="abo_api")
    ok(abos.route("openai") == "api", "abo_api ohne Login → API")
    abos.note_limit("claude", "Limit", time.time() + 60)
    ok(abos.route("claude") == "api", "Limit vermerkt → API bis zur Rücksetzzeit")
    set_billing(claude="abo")
    ok(abos.route("claude") == "abo", "Modus „Abo“ weicht nie auf die API aus")
    abos.clear_limit("claude")
    set_billing(claude="api")
    ok(abos.route("claude") == "api", "Modus „API-Schlüssel“")
    for t, k in (("Claude AI usage limit reached|1795186800", "limit"), ("429 Too Many Requests", "limit"),
                 ("You've hit your usage limit", "limit"), ("Not logged in · Please run /login", "auth"),
                 ("OAuth token has expired", "auth"), ("tool failed: file not found", None)):
        ok(abos.classify(t) == k, f"Fehler gedeutet: „{t[:30]}“ → {k}")
    r = http.patch("/api/settings/abos", headers=H, json={"claude": "abo_api", "openai": {"mode": "abo"}})
    ok(r.status_code == 200 and r.json()["claude"]["mode"] == "abo_api" and r.json()["openai"]["mode"] == "abo",
       "PATCH /api/settings/abos setzt den Modus pro Anbieter")
    ok(http.patch("/api/settings/abos", headers=H, json={"claude": "gratis"}).status_code == 400, "ungültiger Modus → 400")
    st = http.get("/api/settings/abos", headers=H).json()
    ok(st["claude"]["logged_in"] and st["claude"]["plan"] == "max" and st["claude"]["mode_label"] == "Abo, bei Limit API",
       "Status: angemeldet, Abo-Art, Modus mit Beschriftung")
    ok("login_command" in st["openai"] and "codex" in (st["openai"]["login_command"] or "") and "login" in
       st["openai"]["login_command"], "Login-Befehl ist der offizielle `codex login`")
    ok(http.get("/api/setup/abos").status_code == 200 and http.get("/api/setup").json()["server"]["abos"]["claude"],
       "Server-App: /api/setup/abos und abos in /api/setup (nur lokal)")
    r = http.post("/api/settings/abos/claude/login", headers=H)
    ok(r.status_code == 200 and r.json()["started"] is False and "auth login" in r.json()["command"],
       "„Mit Claude anmelden“ startet `claude auth login` (im Test kein Terminal)")
    ok(http.get("/api/settings/abos", headers={"Authorization": "Bearer falsch"}).status_code == 401, "nur mit Token")


# -- 2. Chat über das Abo -------------------------------------------------------------------------------------------
def test_chat(bid: str) -> None:
    print("Chat über Claude Code mit Abo")
    set_billing(claude="abo_api")
    abos.set_status_for_tests("claude", LOGGED_IN)
    db.drop_abo_session(bid)  # Begrüßung lief evtl. schon übers Abo
    n_api, n_abo = len(FakeApi.calls), len(FakeAbo.calls)
    send(bid, "Hallo, erste Frage")
    ok(len(FakeAbo.calls) == n_abo + 1 and len(FakeApi.calls) == n_api, "Lauf ging über das Abo, nicht über die API")
    kw = FakeAbo.calls[-1]
    ok(kw["session_id"] is None and "erste Frage" in text_of(kw), "erste Nachricht: neue Sitzung mit Verlauf")
    ok(kw["session_key"] == f"{bid}|{bid}", "Sitzung pro Chat und Scoop")
    ok(any(t.schema["name"] == "merken" for t in kw["extra_tools"]), "Scoops-Werkzeuge gehen an den Abo-Lauf")
    sess = db.abo_session(bid, bid, "claude")
    ok(sess and sess["session_id"] == "sess-1", "Sitzung gespeichert")
    bot_msg = [m for m in db.messages(bid, limit=5) if m["role"] == "bot"][-1]
    ok(bot_msg["text"] == "Antwort übers Abo" and bot_msg["meta"].get("abo_session") == "sess-1"
       and bot_msg["meta"]["run_info"].get("billing") == "abo", "Antwort mit Sitzungs-Markierung und billing=abo")
    send(bid, "Zweite Frage")
    kw = FakeAbo.calls[-1]
    ok(kw["session_id"] == "sess-1", "zweite Nachricht setzt die Sitzung fort")
    sent = text_of(kw)
    ok("Zweite Frage" in sent and "erste Frage" not in sent and "Antwort übers Abo" not in sent,
       "nur neue Nachrichten geschickt (eigene Antwort steht schon in der Sitzung)")
    ok("erste Frage" in json.dumps(kw["fresh_messages"], ensure_ascii=False), "ganzer Verlauf als Ersatz, falls die Sitzung weg ist")
    row = db.one("SELECT dollars, billing, input_tokens FROM usage WHERE bot_id=? ORDER BY id DESC LIMIT 1", (bid,))
    ok(row["billing"] == "abo" and row["dollars"] == 0 and row["input_tokens"] == 500, "Nutzung als Abo gebucht, 0 $")
    u = http.get("/api/usage", headers=H).json()
    ok(u["abo"]["month_runs"] >= 2 and u["abo"]["by_model"].get("claude-haiku-5-5"), "GET /api/usage: Abo-Läufe getrennt")
    ok(u["month_usd"] == 0, "Abo-Läufe ohne Betrag")
    status = [m for m in db.messages(bid, limit=10) if m["role"] == "status"]
    ok(status and status[-1]["meta"].get("billing") == "abo" and status[-1]["meta"]["cost_usd"] == 0,
       "Statuszeile mit billing=abo und ohne Kosten")

    print("Fallback bei Abo-Limit")
    FakeAbo.fail = abos.SubscriptionUnavailable("claude", "Claude-Abo-Limit erreicht (seven_day)", limit=True)
    abos.note_limit("claude", "Claude-Abo-Limit erreicht", time.time() + 3600)
    abos.clear_limit("claude")  # die Engine vermerkt das Limit selbst; hier erst beim Fehler
    n_api = len(FakeApi.calls)
    send(bid, "Dritte Frage")
    ok(len(FakeApi.calls) == n_api + 1, "Abo am Limit → derselbe Lauf über die API")
    ok("Dritte Frage" in text_of(FakeApi.calls[-1]), "API-Lauf bekommt den Chatverlauf")
    ev = [m for m in db.messages(bid, limit=10) if m["role"] == "event" and m["meta"].get("abo_fallback")]
    ok(ev and "am Limit" in ev[-1]["text"] and "API" in ev[-1]["text"], "sichtbarer Hinweis im Chat")
    st = [m for m in db.messages(bid, limit=10) if m["role"] == "status"][-1]
    ok(st["meta"].get("abo_fallback") and any("am Limit" in x for x in st["meta"]["lines"]), "Hinweis auch in der Statuszeile")
    row = db.one("SELECT dollars, billing FROM usage WHERE bot_id=? ORDER BY id DESC LIMIT 1", (bid,))
    ok(row["billing"] is None and row["dollars"] > 0, "API-Lauf mit Kosten gebucht")
    abos.note_limit("claude", "Limit", time.time() + 3600)
    n_abo, n_api = len(FakeAbo.calls), len(FakeApi.calls)
    send(bid, "Vierte Frage")
    ok(len(FakeAbo.calls) == n_abo and len(FakeApi.calls) == n_api + 1, "während des Limits gleich über die API")
    ev2 = [m for m in db.messages(bid, limit=10) if m["role"] == "event" and m["meta"].get("abo_fallback")]
    ok(len(ev2) == len(ev), "Hinweis nur einmal je Limit")
    abos.clear_limit("claude")

    print("Modus „Abo“ ohne Fallback")
    set_billing(claude="abo")
    FakeAbo.fail = abos.SubscriptionUnavailable("claude", "Claude Code ist nicht mit einem Claude-Abo angemeldet.")
    n_api = len(FakeApi.calls)
    send(bid, "Fünfte Frage")
    last = [m for m in db.messages(bid, limit=5) if m["role"] == "bot"][-1]
    ok(len(FakeApi.calls) == n_api and last["meta"].get("failed") and "KI-Abos" in last["text"],
       "klare Meldung mit Hinweis auf die Server-App, keine API")
    abos.clear_limit("claude")
    set_billing(claude="api")
    n_abo = len(FakeAbo.calls)
    send(bid, "Sechste Frage")
    ok(len(FakeAbo.calls) == n_abo, "Modus „API-Schlüssel“: kein Abo-Lauf")


def test_openai_chat() -> None:
    print("Chat über Codex mit ChatGPT-Abo")
    set_billing(openai="abo_api")
    abos.set_status_for_tests("openai", {**LOGGED_IN, "method": "chatgpt", "plan": "pro"})
    bid = make_bot("Gipi", "gpt-6-luna")
    n_abo = len(FakeAbo.calls)
    send(bid, "Hallo Codex")
    ok(len(FakeAbo.calls) > n_abo and FakeAbo.calls[-1]["model"] == "gpt-6-luna", "OpenAI-Scoop läuft über Codex-Abo")
    ok(db.abo_session(bid, bid, "openai"), "Codex-Thread pro Chat gespeichert")
    set_billing(openai="api")


# -- 3. Claude-Code-Engine mit Fake-SDK-Nachrichten -----------------------------------------------------------------
def test_claude_engine_messages() -> None:
    print("Claude-Code-Engine: Sitzung, Nutzung, Limit, Ankündigung")
    from claude_agent_sdk import (AssistantMessage, RateLimitEvent, RateLimitInfo, ResultMessage, SystemMessage,
                                  TextBlock, ToolUseBlock)

    class FakeClient:
        def __init__(self, script):
            self.script, self.queries, self.interrupted = script, [], False

        async def query(self, prompt):
            if isinstance(prompt, str):
                self.queries.append(prompt)
            else:
                async for m in prompt:
                    self.queries.append(m)

        async def receive_response(self):
            for m in self.script.pop(0):
                yield m

        async def interrupt(self):
            self.interrupted = True

        async def set_model(self, m):
            self.model = m

    def result(text, sid="s-9", is_error=False, subtype="success", errors=None, status=None):
        return ResultMessage(subtype=subtype, duration_ms=1, duration_api_ms=1, is_error=is_error, num_turns=1,
                             session_id=sid, result=text, errors=errors, api_error_status=status,
                             model_usage={"claude-haiku-5-5": {"inputTokens": 7, "outputTokens": 3,
                                                               "cacheReadInputTokens": 100, "cacheCreationInputTokens": 0}})

    init = SystemMessage("init", {"session_id": "s-9", "apiKeySource": "none"})
    eng = engine_abo.ClaudeCodeEngine(service.engine)
    lines: list[str] = []
    ctx = engine_abo.RunCtx(tools={}, line=lines.append, cancel=None, hub=None, holder="b", allow_computer=False)
    names = (AssistantMessage, RateLimitEvent, ResultMessage, SystemMessage, TextBlock, ToolUseBlock)

    def run(script, content=None):
        w = engine_abo._Warm(FakeClient(script), "k", None, [ctx])
        book = UsageBook(billing="abo")
        out = asyncio.run(eng._turns(w, ctx, content or [{"type": "text", "text": "hi"}], "claude-haiku-5-5", book, None,
                                     None, *names))
        return out, book, w

    (final, stop, sid, model), book, w = run([[init, AssistantMessage([ToolUseBlock("t1", "WebSearch", {"query": "Wetter"}),
                                                                      TextBlock("Sonnig.")], "claude-haiku-5-5"),
                                              result("Sonnig.")]])
    ok(final == "Sonnig." and stop == "end_turn" and sid == "s-9", "Antwort und Session-ID aus Claude Code")
    ok(book.dollars == 0 and book.by_model["claude-haiku-5-5"].cache_read_tokens == 100, "Nutzung gezählt, 0 $ (Abo)")
    ok("Sucht im Web: Wetter" in lines, "Statuszeile für eingebaute Websuche")
    ok(w.client.queries[0]["message"]["content"][0]["text"] == "hi", "Nachricht als Streaming-Eingabe (Inhaltsblöcke)")
    (final, *_), _, w = run([[init, result("Ich schaue jetzt gleich im Kalender nach.")], [init, result("Morgen ist frei.")]])
    ok(final == "Morgen ist frei." and w.client.queries[1].startswith("[System"), "Ankündigung ohne Werkzeug → Anstoß")
    limit = RateLimitEvent(RateLimitInfo(status="rejected", resets_at=int(time.time()) + 3600, raw={
        "status": "rejected", "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": int(time.time()) + 3600}}}),
        "u", "s-9")
    abos.clear_limit("claude")
    try:
        run([[init, limit, AssistantMessage([TextBlock("Limit")], "claude-haiku-5-5", error="rate_limit"),
              result("Limit", is_error=True, status=429)]])
        ok(False, "Limit muss SubscriptionUnavailable werfen")
    except abos.SubscriptionUnavailable as e:
        ok(e.limit and e.provider == "claude", "Abo-Limit erkannt → SubscriptionUnavailable(limit)")
    ok(abos.limited("claude") and abos.status()["claude"]["usage"]["window"] == "five_hour",
       "Limit vermerkt und Auslastung für die Anzeige")
    abos.clear_limit("claude")
    try:
        run([[SystemMessage("init", {"session_id": "s", "apiKeySource": "ANTHROPIC_API_KEY"}), result("x")]])
        ok(False, "API-Schlüssel statt Login muss abgelehnt werden")
    except abos.SubscriptionUnavailable:
        ok(True, "nutzt Claude Code einen API-Schlüssel statt des Logins → abgelehnt")
    try:
        run([[init, result("", is_error=True, subtype="error_during_execution",
                           errors=["No conversation found with session ID: s-1"])]])
        ok(False, "fehlende Sitzung muss erkannt werden")
    except engine_abo._ResumeFailed:
        ok(True, "Sitzung nicht mehr da → neu beginnen mit ganzem Verlauf")

    # Unbekannte Sitzung schon beim Start (ResultError in connect, Server 1.37): frisch mit Verlauf statt Fehler im Chat
    starts: list[bool] = []

    async def client_for(key, sid, *a, fresh=False):
        starts.append(fresh)
        if not fresh:
            raise RuntimeError("Claude Code returned an error result: No conversation found with session ID: "
                               "1e253708 (exit code: 1)")
        return engine_abo._Warm(FakeClient([[init, result("Neu da.")]]), "k2", None, [ctx])

    eng._client_for = client_for
    final, *_ = asyncio.run(eng._run_async(key="k2", session_id="alt", sys_text="", model="claude-haiku-5-5",
                                           effort="low", tools={}, builtin=[], ctx_box=[ctx], ctx=ctx,
                                           messages=[{"role": "user", "content": "hi"}], fresh_messages=None,
                                           usage=UsageBook(billing="abo"), max_steps=3, on_text=None, escalation=None))
    ok(starts == [False, True] and final == "Neu da.", "Sitzung beim Start unbekannt → einmal frisch, keine Fehlermeldung")
    ok(abos.resume_failed("No conversation found with session ID: x") and not abos.resume_failed("ENOENT mkdir"),
       "Erkennung „Sitzung nicht gefunden“")


def test_flatten_and_tools() -> None:
    print("Nachrichten und Werkzeuge im Abo-Weg")
    msgs = [{"role": "user", "content": [{"type": "text", "text": "Hallo"}]},
            {"role": "assistant", "content": [{"type": "text", "text": "Hi!"}]},
            {"role": "user", "content": [{"type": "text", "text": "Was ist auf dem Bild?"},
                                         {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA"}}]}]
    f = engine_abo.flatten(msgs, intro=True)
    texts = [b.get("text") for b in f if b["type"] == "text"]
    ok(texts[0].startswith("[Bisheriger Chatverlauf") and "Du: Hi!" in texts and "[Neu]" in texts, "neue Sitzung: Mitschrift")
    ok(any(b["type"] == "image" for b in f), "Bilder bleiben erhalten")
    f2 = engine_abo.flatten(msgs[2:], intro=False)
    ok(f2[0]["text"] == "Was ist auf dem Bild?", "Fortsetzung: nur die neue Nachricht")
    calls = []
    t = ExtraTool({"name": "merken", "input_schema": {"type": "object", "properties": {}}},
                  lambda i: calls.append(i) or "ok", lambda i: "Merkt sich etwas")
    lines: list[str] = []
    ctx = engine_abo.RunCtx(tools={"merken": t}, line=lines.append, cancel=None, hub=None, holder="b", allow_computer=False)
    blocks, err = engine_abo.run_tool(ctx, "merken", {"text": "x"})
    ok(not err and blocks[0]["text"] == "ok" and lines == ["Merkt sich etwas"], "Werkzeug ausgeführt mit Statuszeile")
    tok = "tok-test"
    engine_abo.MCP_TOKENS[tok] = [ctx, {"merken": t}]
    code, out = engine_abo.mcp_handle(tok, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    ok(code == 200 and out["result"]["tools"][0]["name"] == "merken", "MCP /mcp/abo: tools/list")
    code, out = engine_abo.mcp_handle("falsch", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    ok(code == 401, "MCP /mcp/abo: falsches Token → 401")
    r = http.post("/mcp/abo", headers={"Authorization": f"Bearer {tok}"},
                  json={"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "merken", "arguments": {}}})
    ok(r.status_code == 200 and r.json()["result"]["isError"] is False, "MCP /mcp/abo über HTTP")
    engine_abo.MCP_TOKENS.pop(tok)
    ok(engine_abo.ClaudeCodeEngine._permission(ctx, "Bash", {"command": "ls"})[0] is False, "Chat: Bash nicht eingebaut")
    ok(engine_abo.ClaudeCodeEngine._permission(ctx, "Read", {"file_path": "/etc/hosts"})[0] is False,
       "Chat: Read ohne Rechner-Zugriff abgelehnt")
    from aisbot import access
    acc = access.Access(mode="auto", scope="workspace", folders=[], workspace=str(TMP), task_dir=None, user="Arman")
    ctx.access = acc
    (TMP / "notiz.txt").write_text("x")
    ok(engine_abo.ClaudeCodeEngine._permission(ctx, "Read", {"file_path": str(TMP / "notiz.txt")})[0],
       "Chat: Read im Bereich erlaubt (gleiche Prüfung wie Aufgaben)")
    ok(not engine_abo.ClaudeCodeEngine._permission(ctx, "Read", {"file_path": str(Path.home() / ".ssh/id_rsa")})[0],
       "Chat: Zugangsdaten nie lesbar")
    ok(not engine_abo.ClaudeCodeEngine._permission(ctx, "Read", {"file_path": str(Path.home() / ".claude/.credentials.json")})[0],
       "Chat: Claude-Login-Datei nie lesbar")


# -- 4. Aufgaben im Abo-Modus ---------------------------------------------------------------------------------------
def test_tasks(bid: str) -> None:
    print("Aufgaben im Abo-Modus")
    from aisbot import tasks as tasks_mod
    set_billing(claude="abo_api")
    abos.set_status_for_tests("claude", LOGGED_IN)
    seen: list[str] = []
    orig = tasks._run_engine

    def fake_engine(run, message):
        seen.append(run.billing)
        if run.billing == "abo" and len(seen) == 1:
            raise abos.SubscriptionUnavailable("claude", "Limit", limit=True)
        return "Fertig.", "end"

    tasks._run_engine = fake_engine
    try:
        tid = tasks.start(bid, bid, "Abo-Test", "Mach etwas", origin="user")["id"]
        wait_for(lambda: tasks.row(tid)["state"] in ("done", "failed"), msg="Aufgabe fertig")
        t = tasks.row(tid)
        ok(seen == ["abo", "api"] and t["state"] == "done", "Abo-Limit in der Aufgabe → weiter über API")
        ok(t["billing"] == "api", "Aufgabe merkt sich den Weg der Session")
        st = db.one("SELECT meta FROM messages WHERE id=?", (t["status_message_id"],))
        ok("Abo-Limit erreicht" in st["meta"], "Hinweis in der Aufgabenkarte")
        set_billing(claude="abo")
        seen.clear()
        tid = tasks.start(bid, bid, "Abo-Test 2", "Mach etwas", origin="user")["id"]
        wait_for(lambda: tasks.row(tid)["state"] in ("done", "failed"), msg="Aufgabe 2 fertig")
        ok(tasks.row(tid)["state"] == "failed" and "Abo" in (tasks.row(tid)["error"] or ""), "Modus „Abo“: klarer Fehler")
    finally:
        tasks._run_engine = orig

    # Optionen für Claude Code im Abo-Modus: kein Schlüssel, keine eigene Config, keine Kostengrenze
    captured = {}

    class Stop(Exception):
        pass

    class FakeSDK:
        def __init__(self, options):
            captured["opts"] = options
            raise Stop()

    import claude_agent_sdk
    real = claude_agent_sdk.ClaudeSDKClient
    claude_agent_sdk.ClaudeSDKClient = FakeSDK
    try:
        t = tasks.row(tid)
        run = tasks_mod.Run(t, tasks_mod.Progress(service, t), "tok")
        run.billing = "abo"
        try:
            tasks._run_claude(run, "x")
        except Stop:
            pass
        env = captured["opts"].env
        ok(env.get("ANTHROPIC_API_KEY") == "" and "CLAUDE_CONFIG_DIR" not in env and
           env.get("CLAUDE_CODE_OAUTH_TOKEN") == "", "Abo-Aufgabe: Schlüssel-Variablen geleert, Standard-Login")
        ok(captured["opts"].max_budget_usd is None and captured["opts"].setting_sources == [],
           "Abo-Aufgabe: keine Kostengrenze in $, keine Nutzer-Einstellungen")
        # Gespeicherte Sitzung unbekannt (Server 1.37): einmal frisch mit Hinweis statt Fehlschlag
        calls: list[tuple] = []
        real_async = tasks._claude_async

        async def fake_async(run, message):
            calls.append((run.task.get("session_id"), message))
            if len(calls) == 1:
                raise RuntimeError("Claude Code returned an error result: No conversation found with session ID: s-alt")
            return "Weiter.", "end"

        tasks._claude_async = fake_async
        try:
            tasks._set(t, session_id="s-alt")
            out = tasks._run_claude(run, "mach weiter")
        finally:
            tasks._claude_async = real_async
        ok(out == ("Weiter.", "end") and calls[0][0] == "s-alt" and calls[1][0] is None
           and calls[1][1].startswith("[Hinweis") and calls[1][1].endswith("mach weiter"),
           "Aufgabe: Sitzung unbekannt → einmal frisch mit Hinweis")
        ov = tasks._codex_overrides(None, abo=True)
        ok(not any("ephemeral" in o or "env_key" in o for o in ov) and any('cli_auth_credentials_store="file"' in o for o in ov),
           "Codex im Abo-Modus: persistenter Login statt ephemeral, kein API-Anbieter")
        ok(abos.codex_env()["CODEX_HOME"].startswith(str(TMP)) and abos.codex_env()["OPENAI_API_KEY"] == "",
           "Codex: eigener CODEX_HOME im Datenordner, kein Schlüssel")
    finally:
        claude_agent_sdk.ClaudeSDKClient = real
    deny = tasks_mod.server_private_paths()
    ok(str(TMP / "data" / "abo") in deny and any(p.endswith(".codex/auth.json") for p in deny),
       "Abo-Login-Ordner für Aufgaben immer gesperrt (auch „Überall“)")


# -- 5. Nirgends Anmeldedaten lesen ---------------------------------------------------------------------------------
def test_no_tokens() -> None:
    print("Keine Anmeldedaten lesen")
    forbidden = re.compile(r"setup-token|Claude Code-credentials|find-generic-password[^\n]*(claude|codex)", re.I)
    for p in SRC.glob("aisbot/*.py"):
        for i, line in enumerate(p.read_text().splitlines(), 1):
            ok_line = not forbidden.search(line) or line.lstrip().startswith("#") or '"""' in line or "kein" in line
            if not ok_line:
                raise AssertionError(f"{p.name}:{i}: {line.strip()}")
    reads = re.compile(r"(open|read_text|read_bytes|load)\([^)]*(credentials|auth\.json)", re.I)
    hits = [f"{p.name}:{i}" for p in SRC.glob("aisbot/*.py") for i, line in enumerate(p.read_text().splitlines(), 1)
            if reads.search(line)]
    ok(not hits, f"kein Code öffnet Login-Dateien {hits}")
    ok(True, "kein setup-token, kein Schlüsselbund-Zugriff auf Claude-/Codex-Logins")
    # Laufzeit: Status nur über die Programme (auth status / login status), nie Dateien öffnen
    abos.clear_status()
    seen_cmds: list[list[str]] = []
    opened: list[str] = []
    real_run, real_open = subprocess.run, builtins.open

    def spy_run(cmd, *a, **k):
        seen_cmds.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0, json.dumps({"loggedIn": True, "authMethod": "claude.ai",
                                                               "subscriptionType": "max"}) if "auth" in cmd else
                                           "Logged in using ChatGPT", "")

    def spy_open(f, *a, **k):
        opened.append(str(f))
        return real_open(f, *a, **k)

    abos.subprocess.run = spy_run
    abos._codex_account = lambda: {"plan": "pro"}
    builtins.open = spy_open
    try:
        st = abos.status(refresh=True)
    finally:
        abos.subprocess.run = real_run
        builtins.open = real_open
    ok(st["claude"]["subscription"] and st["openai"]["subscription"], "Status über die Programme ermittelt")
    ok(all(c[1:3] == ["auth", "status"] or "login" in c and c[-1] == "status" for c in seen_cmds),
       f"nur `claude auth status` und `codex login status` aufgerufen ({len(seen_cmds)} Aufrufe)")
    ok(not [f for f in opened if "credential" in f or "auth.json" in f or "Keychain" in f],
       "keine Login-Datei geöffnet")
    os.environ["CLAUDE_CONFIG_DIR"] = "/tmp/fremder-claude-ordner"
    env = abos.claude_env()
    ok(all(env[k] == "" for k in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN")),
       "Claude-Code-Umgebung ohne Schlüssel und ohne fremde Tokens")
    # Leerer CLAUDE_CONFIG_DIR macht Claude Code den Konfigordner "" (mkdir '' → ENOENT): weglassen, geerbten entfernen
    ok("CLAUDE_CONFIG_DIR" not in env and "CLAUDE_CONFIG_DIR" not in os.environ,
       "CLAUDE_CONFIG_DIR weder leer übergeben noch geerbt (Standard-Konfigordner von Claude Code)")


def test_result_files(bid: str) -> None:
    print("Ergebnisdateien: still in die Bibliothek, im Chat nur, was der Scoop zeigt")
    from aisbot.bots import RunState
    orig = tasks._run_engine

    def fake_engine(run, message):
        d = Path(run.task["workdir"]) / "ergebnis"
        d.mkdir(parents=True, exist_ok=True)
        (d / "Bericht.md").write_text("# Bericht")
        (d / "Gmail_Status.md").write_text("intern")
        (d / "Deduplizierung.csv").write_text("a,b")
        return "Fertig.", "end"

    tasks._run_engine = fake_engine
    try:
        tid = tasks.start(bid, bid, "Dateien-Test", "Mach etwas", origin="user")["id"]
        wait_for(lambda: tasks.row(tid)["state"] in ("done", "failed"), msg="Aufgabe fertig")
        t = tasks.row(tid)
        fids = json.loads(t["files"] or "[]")
        ok(len(fids) == 3, f"alle drei Ergebnisdateien in der Bibliothek ({len(fids)})")
        evs = db.q("SELECT text, meta FROM messages WHERE bot_id=? AND role='event' AND meta LIKE ?", (bid, f'%{tid}%'))
        ok(not [e for e in evs if e["text"].startswith("Aus der Aufgabe")], "keine Zeile je Datei im Chat")
        done = [json.loads(e["meta"]) for e in evs if e["text"].startswith("Aufgabe fertig")]
        prompt = done[0].get("prompt", "") if done else ""
        ok("datei_zeigen" in prompt and all(f in prompt for f in fids), "Bericht nennt Datei-IDs und datei_zeigen")
    finally:
        tasks._run_engine = orig
    st = RunState()
    tools = {x.schema["name"]: x for x in service._tools(bid, bid, 0, st)}
    rep = next(f for f in fids if db.file_row(f)["name"] == "Bericht.md")
    out = tools["datei_zeigen"].handler({"datei_id": rep})
    ok("unter deiner Antwort" in out and st.show_files == [rep], "datei_zeigen merkt die Datei vor")
    ok("nicht gefunden" in tools["datei_zeigen"].handler({"datei_id": "f_gibtsnicht"}), "fremde/unbekannte Datei abgelehnt")
    service._show_files(bid, st, None)
    last = db.one("SELECT text, meta FROM messages WHERE bot_id=? ORDER BY seq DESC LIMIT 1", (bid,))
    ok(last["text"] == "Ergebnis: Bericht.md" and json.loads(last["meta"])["file_id"] == rep and st.show_files == [],
       "gezeigte Datei als Karte unter der Antwort")
    ok("datei_zeigen" in tasks_mod_excluded(), "in Hintergrund-Aufgaben nicht verfügbar (dort datei_in_bibliothek)")


def tasks_mod_excluded():
    from aisbot import tasks as tasks_mod
    return tasks_mod.TASK_EXCLUDED


def main() -> None:
    start_server()
    test_modes()
    bid = make_bot("Abi")
    test_chat(bid)
    test_openai_chat()
    test_claude_engine_messages()
    test_flatten_and_tools()
    test_tasks(bid)
    test_result_files(bid)
    test_no_tokens()
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
