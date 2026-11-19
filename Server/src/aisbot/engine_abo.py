"""Chat-Läufe über KI-Abos (docs/abos.md): Claude Code (Claude Agent SDK) bzw. Codex (Codex SDK) mit dem Login des
Nutzers statt API-Schlüssel. Gleiche Schnittstelle wie `engine.Engine.run` (Outcome), damit bots.py, Statuszeilen,
Freigabe-Karten, Übergaben, Anhänge, Erinnerung und Werkzeuge unverändert bleiben.

- **Sitzung pro Chat:** Claude-Code-Session bzw. Codex-Thread wird fortgesetzt (Tabelle `abo_sessions`); bots.py
  schickt nur die Nachrichten seit dem letzten Lauf. Kompaktierung macht das Programm selbst.
- **Werkzeuge:** Die Scoops-Werkzeuge (ExtraTool aus bots._tools, verbundene Apps, Bot-Rechner) laufen bei Claude als
  In-Process-MCP-Server, bei Codex über den MCP-Endpunkt `/mcp/abo` dieses Servers (Token pro Prozess). Freigaben bleiben
  die bekannten Karten unserer Werkzeuge.
- **Eingebaute Werkzeuge:** Claude: WebSearch/WebFetch (wenn erlaubt), Read/Glob/Grep nur im Bereich des Rechner-Zugriffs
  (gleiche Prüfung wie Aufgaben, `tasks.agent_permission`); Schreiben und Shell nur über unsere Werkzeuge `terminal` und
  `rechner_datei_*` (mit Karten). Codex: Shell aus, Sandbox nur lesend, Websuche je nach Erlaubnis.
- **Bot-Rechner:** MCP-Werkzeug `bildschirm` mit Bild-Ergebnis (das native Computer-Use-Werkzeug gibt es dort nicht).
- **Startzeit:** ein warmer Prozess pro aktivem Chat (Streaming-Eingabe), nach 10 Minuten ohne Nutzung beendet.

Nie Tokens lesen oder weitergeben: Die Programme laufen mit ihrem eigenen Login, Schlüssel-Variablen werden geleert.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import secrets
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import abos
from .config import UsageBook
from .engine import (HANDOFF_HINT, MAX_NUDGES, NUDGE, ComputerHub, Engine, ExtraTool, Outcome, announces_action,
                     handoff_due, hands_off, mcp_line, status_line)

IDLE_CLOSE = 600.0  # warme Prozesse nach 10 Minuten ohne Lauf beenden
MAX_WARM = 4  # höchstens so viele warme Claude-Code-Prozesse gleichzeitig (je einige hundert MB)
MCP_NAME_MAX = 51  # Claude: „mcp__scoops__“ + Name ≤ 64 Zeichen
CLAUDE_TOOLS_READ = ("Read", "Glob", "Grep")
CLAUDE_TOOLS_WEB = ("WebSearch", "WebFetch")
SCREEN_ACTIONS = ("screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
                  "left_click_drag", "mouse_move", "scroll", "type", "key", "hold_key", "wait", "cursor_position")


# -- Hintergrund-Ereignisschleife für das Agent SDK -------------------------------------------------------------------
class _Loop:
    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop | None = None
        self._lock = threading.Lock()

    def get(self) -> asyncio.AbstractEventLoop:
        with self._lock:
            if self.loop is None or not self.loop.is_running():
                loop = asyncio.new_event_loop()
                ready = threading.Event()

                def run() -> None:
                    asyncio.set_event_loop(loop)
                    loop.call_soon(ready.set)
                    loop.run_forever()

                threading.Thread(target=run, daemon=True, name="abo-loop").start()
                ready.wait(5)
                self.loop = loop
            return self.loop

    def run(self, coro, timeout: float | None = None):
        return asyncio.run_coroutine_threadsafe(coro, self.get()).result(timeout)


LOOP = _Loop()


# -- gemeinsamer Laufzustand -------------------------------------------------------------------------------------------
@dataclass
class RunCtx:
    """Was die Werkzeuge eines warmen Prozesses im laufenden Chat-Lauf brauchen (wird pro Lauf ersetzt)."""

    tools: dict[str, ExtraTool]
    line: Callable[[str], None]
    cancel: threading.Event | None
    hub: ComputerHub | None
    holder: str
    allow_computer: bool
    access: object | None = None  # access.Access für Read/Glob/Grep (None = keine eingebauten Datei-Werkzeuge)
    tool_steps: int = 0
    handed_off: bool = False
    hinted: bool = False
    used_tools: int = 0
    computer: object | None = None
    used_computer: bool = False
    escalate_to: str | None = None
    lock: threading.Lock = field(default_factory=threading.Lock)

    def get_computer(self):
        if self.computer is None:
            if self.hub.holder and self.hub.holder != self.holder:
                self.line("Wartet, bis der Rechner frei ist")
            self.computer = self.hub.acquire(self.holder, self.cancel)
            self.used_computer = True
        return self.computer

    def release(self) -> None:
        if self.computer is not None:
            self.computer = None
            self.hub.release()


def flatten(messages: list[dict], intro: bool) -> list[dict]:
    """Chat-Züge (Claude-Format) → Inhaltsblöcke EINER Nutzer-Nachricht. Bei einer neuen Sitzung (intro) steht der
    bisherige Verlauf als Mitschrift davor, eigene frühere Antworten als „Du:“."""
    out: list[dict] = []
    if intro and len(messages) > 1:
        out.append({"type": "text", "text": "[Bisheriger Chatverlauf zur Orientierung – du setzt das Gespräch fort]"})
    last_user = max((i for i, m in enumerate(messages) if m["role"] == "user"), default=-1)
    for i, m in enumerate(messages):
        content = m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": str(m["content"])}]
        if intro and i == last_user and i > 0:
            out.append({"type": "text", "text": "[Neu]"})
        for b in content:
            if b.get("type") == "text" and b.get("text"):
                t = b["text"]
                out.append({"type": "text", "text": f"Du: {t}" if m["role"] == "assistant" else t})
            elif b.get("type") in ("image", "document") and m["role"] == "user":
                out.append(b)
    return out or [{"type": "text", "text": "[Ereignis: Du bist dran. Mach im Gespräch weiter.]"}]


def _tool_result_blocks(out) -> list[dict]:
    """Ergebnis eines ExtraTool (Text oder Blöcke mit Bildern) → MCP-Inhalt."""
    from .tasks import _mcp_content
    return _mcp_content(out)


def hub_tools(mcp_hub, line: Callable[[str], None]) -> dict[str, ExtraTool]:
    """Verbundene Apps (MCP-Hub: Composio, Team App, Atrium …): häufige Werkzeuge direkt, der Rest über Suche/Nutzen
    (wie die OpenAI-Engine). Namen bleiben die des Hubs."""
    if not mcp_hub:
        return {}
    schemas = mcp_hub.tool_schemas() or []
    direct = [s for s in schemas if not s.get("defer_loading") and len(s["name"]) <= MCP_NAME_MAX]
    known = {s["name"]: s for s in schemas}
    out: dict[str, ExtraTool] = {}
    for s in direct:
        def call(i: dict, _n=s["name"]):
            srv, _, tname = _n.partition("__")
            line(mcp_line(srv, tname, i))
            return mcp_hub.call(_n, i)
        out[s["name"]] = ExtraTool({"name": s["name"], "description": (s.get("description") or "")[:1024],
                                    "input_schema": s.get("input_schema") or {"type": "object", "properties": {}}}, call)
    if len(known) > len(direct):
        def suchen(i: dict) -> str:
            q = [w for w in str(i.get("suche") or "").lower().split() if len(w) > 2]
            scored = []
            for n, s in known.items():
                text = (n + " " + (s.get("description") or "")).lower()
                score = sum(text.count(w) for w in q)
                if score:
                    scored.append((score, n, s))
            scored.sort(key=lambda x: -x[0])
            if not scored:
                return "Kein passendes Werkzeug gefunden. Andere Suchbegriffe versuchen."
            return "\n\n".join(f"{n}: {(s.get('description') or '')[:300]}\nParameter: "
                               f"{json.dumps(s.get('input_schema') or {}, ensure_ascii=False)[:1200]}" for _, n, s in scored[:6])

        def nutzen(i: dict):
            name = str(i.get("name") or "")
            if name not in known:
                return "Unbekanntes Werkzeug. Erst mit app_werkzeug_suchen suchen."
            try:
                args = json.loads(i.get("argumente_json") or "{}")
            except json.JSONDecodeError:
                return "argumente_json ist kein gültiges JSON."
            srv, _, tname = name.partition("__")
            line(mcp_line(srv, tname, args))
            return mcp_hub.call(name, args)

        s = {"type": "string"}
        out["app_werkzeug_suchen"] = ExtraTool({
            "name": "app_werkzeug_suchen", "description": "Sucht weitere Werkzeuge der verbundenen Apps (Team App, Gmail, "
            "Notion, Atrium …) nach Stichworten.", "input_schema": {"type": "object", "properties": {"suche": s},
                                                                   "required": ["suche"]}}, suchen,
            lambda i: "Sucht das passende Werkzeug")
        out["app_werkzeug_nutzen"] = ExtraTool({
            "name": "app_werkzeug_nutzen", "description": "Führt ein mit app_werkzeug_suchen gefundenes Werkzeug aus. "
            "argumente_json = Argumente als JSON-Text.", "input_schema": {
                "type": "object", "properties": {"name": s, "argumente_json": s}, "required": ["name", "argumente_json"]}},
            nutzen)
    return out


def screen_tool(ctx_ref: Callable[[], RunCtx], w: int, h: int) -> ExtraTool:
    """Bot-Rechner als MCP-Werkzeug mit Bild-Ergebnis. Nach jeder Aktion kommt gleich ein neues Bildschirmfoto zurück."""
    props = {
        "action": {"type": "string", "enum": list(SCREEN_ACTIONS)},
        "coordinate": {"type": "array", "items": {"type": "integer"}, "description": "[x, y] in Bildschirmpunkten"},
        "start_coordinate": {"type": "array", "items": {"type": "integer"}, "description": "Start beim Ziehen"},
        "text": {"type": "string", "description": "Text (type) bzw. Taste/Kombination (key, z. B. cmd+t) bzw. "
                                                  "Zusatztaste beim Klicken"},
        "scroll_direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
        "scroll_amount": {"type": "integer"},
        "region": {"type": "array", "items": {"type": "integer"}, "description": "zoom: [x1, y1, x2, y2]"},
        "duration": {"type": "number"}, "repeat": {"type": "integer"},
    }

    def run(i: dict):
        ctx = ctx_ref()
        if not ctx.allow_computer or ctx.hub is None:
            return "Fehler: Der Rechner ist in diesem Lauf nicht freigegeben."
        name = str(i.get("action") or "screenshot")
        if name not in SCREEN_ACTIONS:
            return f"Unbekannte Aktion {name}"
        c = ctx.get_computer()
        res = Engine._exec_computer(c, name, i)
        if isinstance(res, list):
            return res
        if name in ("cursor_position",):
            return res
        try:
            return [{"type": "text", "text": "OK, Bildschirm danach:"}] + Engine._exec_computer(c, "screenshot", {})
        except Exception as e:  # noqa: BLE001
            return f"OK (kein Bildschirmfoto: {e})"

    return ExtraTool({"name": "bildschirm", "description": (
        f"Bedient deinen Mac (Bildschirm {w}x{h} Punkte) wie ein Mensch: action=screenshot zeigt den Bildschirm; "
        "left_click/double_click/right_click mit coordinate [x, y]; type mit text; key mit text (z. B. „cmd+t“, "
        "„return“); scroll mit coordinate, scroll_direction, scroll_amount; left_click_drag mit start_coordinate und "
        "coordinate; zoom mit region; wait mit duration. Nach jeder Aktion kommt ein neues Bildschirmfoto zurück. "
        "Tastenkürzel: cmd = Command-Taste."),
        "input_schema": {"type": "object", "properties": props, "required": ["action"]}},
        run, lambda i: status_line(str(i.get("action") or "screenshot"), i))


def _escalate_tool(target: str) -> ExtraTool:
    def run(i: dict) -> str:
        return f"Übergeben. Ab dem nächsten Schritt arbeitet {target} mit dem bisherigen Verlauf weiter."
    return ExtraTool({"name": "eskalieren", "description": (
        "Übergibt die Aufgabe an ein stärkeres Modell, das mit dem bisherigen Verlauf weiterarbeitet. Nutze das, wenn die "
        "Aufgabe viele Schritte mit Abwägungen braucht oder du zweimal am selben Schritt gescheitert bist."),
        "input_schema": {"type": "object", "properties": {"grund": {"type": "string"}}, "required": ["grund"]}},
        run, lambda i: "Holt sich Verstärkung")


def prepare(extra_tools, mcp_hub, hub, allow_computer: bool, escalation_model: str | None, on_line, cancel, holder: str,
            access) -> tuple[RunCtx, list[str]]:
    """Werkzeuge und Laufzustand eines Abo-Chat-Laufs: Scoops-Werkzeuge, verbundene Apps, Bildschirm, Verstärkung."""
    lines: list[str] = []

    def line(s: str) -> None:
        if s:
            lines.append(s)
            if on_line:
                on_line(s)

    tools = {t.schema["name"]: t for t in (extra_tools or [])}
    tools.update({k: v for k, v in hub_tools(mcp_hub, line).items() if k not in tools})
    ctx = RunCtx(tools=tools, line=line, cancel=cancel, hub=hub, holder=holder, allow_computer=allow_computer, access=access)
    if allow_computer and hub is not None:
        w, h = hub.screen_size()
        tools["bildschirm"] = screen_tool(lambda: ctx, w, h)
    if escalation_model:
        tools["eskalieren"] = _escalate_tool(escalation_model)
    return ctx, lines


def run_tool(ctx: RunCtx, name: str, args: dict):
    """Ein Scoops-Werkzeug im laufenden Lauf ausführen (synchron, im Arbeits-Thread). Status, Abgabe-Hinweis."""
    ex = ctx.tools.get(name)
    if ex is None:
        return [{"type": "text", "text": f"Unbekanntes Werkzeug {name}"}], True
    if ctx.cancel is not None and ctx.cancel.is_set():
        return [{"type": "text", "text": "Der Lauf wurde angehalten."}], True
    with ctx.lock:
        ctx.used_tools += 1
        ctx.tool_steps += 1
        ctx.handed_off = ctx.handed_off or hands_off(name)
    if ex.status:
        try:
            ctx.line(ex.status(args))
        except Exception:  # noqa: BLE001
            pass
    try:
        out = ex.handler(args)
        err = False
    except Exception as e:  # noqa: BLE001 – Fehler gehen ans Modell zurück
        print(f"Werkzeugfehler {name}: {str(e)[:300]}", flush=True)
        out, err = f"Fehler: {e}", True
    blocks = _tool_result_blocks(out)
    if handoff_due(ctx.tool_steps, ctx.tools, ctx.handed_off, ctx.hinted):
        ctx.hinted = True
        blocks.append({"type": "text", "text": HANDOFF_HINT.format(n=ctx.tool_steps)})
    return blocks, err


def _schema_key(tools: dict[str, ExtraTool]) -> str:
    return hashlib.sha256(json.dumps([[n, t.schema] for n, t in sorted(tools.items())], sort_keys=True,
                                     ensure_ascii=False, default=str).encode()).hexdigest()


def _limit_info(raw: dict) -> dict:
    """RateLimitEvent der Claude-CLI → Anzeige (Auslastung des engsten Fensters)."""
    windows = raw.get("unifiedWindows") or {}
    best = None
    for name, w in windows.items():
        u = w.get("utilization")
        if u is not None and (best is None or u > best[1]):
            best = (name, u, w.get("resetsAt"))
    # Alle Fenster für die Seite „Nutzung und Verbrauch“ (nur Auslastung, Rücksetzzeit, Status; usage_limits.py)
    keep = {name: {k: w.get(k) for k in ("utilization", "resetsAt", "status") if w.get(k) is not None}
            for name, w in windows.items() if isinstance(w, dict)}
    return {"status": raw.get("status"), "window": best[0] if best else raw.get("rateLimitType"),
            "utilization": best[1] if best else raw.get("utilization"),
            "resets_at": (best[2] if best else None) or raw.get("resetsAt"), "windows": keep}


# -- Claude Code (Agent SDK) -------------------------------------------------------------------------------------------
@dataclass
class _Warm:
    client: object
    key: str
    session_id: str | None
    ctx_box: list  # [RunCtx]
    last_used: float = field(default_factory=time.time)
    busy: bool = False


class ClaudeCodeEngine:
    """Chat über Claude Code mit dem Claude-Login des Nutzers."""

    provider = "claude"

    def __init__(self, api_engine: Engine, cwd: Path | None = None):
        self.api = api_engine
        self.cwd = cwd
        self.warm: dict[str, _Warm] = {}
        self._reaper: threading.Thread | None = None
        self._plock = threading.Lock()

    def _workdir(self) -> str:
        d = self.cwd or (abos.abo_dir() / "chats")
        d.mkdir(parents=True, exist_ok=True)
        return str(d)

    # Warme Prozesse aufräumen
    def _reap_loop(self) -> None:
        while True:
            time.sleep(30)
            try:
                self.close_idle()
            except Exception as e:  # noqa: BLE001
                print("Abo-Prozesse aufräumen:", e, flush=True)

    def close_idle(self, idle: float = IDLE_CLOSE) -> None:
        with self._plock:
            old = [k for k, w in self.warm.items() if not w.busy and time.time() - w.last_used > idle]
            gone = [self.warm.pop(k) for k in old]
        for w in gone:
            self._disconnect(w)

    def close_all(self) -> None:
        with self._plock:
            gone = list(self.warm.values())
            self.warm.clear()
        for w in gone:
            self._disconnect(w)

    def _disconnect(self, w: _Warm) -> None:
        try:
            LOOP.run(w.client.disconnect(), timeout=15)
        except Exception:  # noqa: BLE001
            pass

    def run(self, *, system, messages: list[dict], model: str, escalation_model: str | None = None,
            effort: str = "low", work_effort: str | None = "medium", extra_tools: list[ExtraTool] | None = None,
            mcp_hub=None, budget: float = 1.0, max_steps: int = 150, holder: str = "cli",
            on_line: Callable[[str], None] | None = None, on_text: Callable[[str], None] | None = None,
            cancel: threading.Event | None = None, hub: ComputerHub | None = None, allow_computer: bool = True,
            allow_web: bool = True, session_key: str | None = None, session_id: str | None = None,
            fresh_messages: list[dict] | None = None, access=None, **_ignored) -> Outcome:
        """`messages`: neue Züge seit der letzten Sitzung (bzw. der ganze Verlauf ohne Sitzung). `fresh_messages`: ganzer
        Verlauf, falls die Sitzung nicht fortgesetzt werden kann. Wirft abos.SubscriptionUnavailable bei Login-/Limit-Fehlern."""
        if self._reaper is None:
            self._reaper = threading.Thread(target=self._reap_loop, daemon=True, name="abo-reaper")
            self._reaper.start()
        st = abos.login_status("claude")
        if not st.get("subscription"):
            raise abos.SubscriptionUnavailable("claude", "Claude Code ist nicht mit einem Claude-Abo angemeldet.")
        hub = hub or self.api.hub
        ctx, lines = prepare(extra_tools, mcp_hub, hub, allow_computer, escalation_model if escalation_model != model else None,
                             on_line, cancel, holder, access)
        tools, box = ctx.tools, [ctx]
        sys_text = system if isinstance(system, str) else "\n\n".join(b.get("text", "") for b in system
                                                                     if b.get("type") == "text")
        sys_text += ("\n\nTechnik: Du läufst in Claude Code. Deine Werkzeuge heißen mcp__scoops__<name>; nutze sie wie "
                     "beschrieben. Eingebaute Datei-Werkzeuge (Read, Glob, Grep) nur mit absoluten Pfaden im erlaubten "
                     "Bereich; schreiben und Befehle nur über terminal und rechner_datei_*." if access is not None else
                     "\n\nTechnik: Du läufst in Claude Code. Deine Werkzeuge heißen mcp__scoops__<name>; nutze sie wie "
                     "beschrieben.")
        builtin = (list(CLAUDE_TOOLS_WEB) if allow_web else []) + (list(CLAUDE_TOOLS_READ) if access is not None else [])
        usage = UsageBook(billing="abo")
        model_end = model
        try:
            final, stop, sid, model_end = LOOP.run(self._run_async(
                key=session_key or f"once:{secrets.token_hex(4)}", session_id=session_id, sys_text=sys_text,
                model=model, effort=work_effort or effort, tools=tools, builtin=builtin, ctx_box=box, ctx=ctx,
                messages=messages, fresh_messages=fresh_messages, usage=usage, max_steps=max_steps, on_text=on_text,
                escalation=escalation_model if "eskalieren" in tools else None))
        except abos.SubscriptionUnavailable:
            raise
        except Exception as e:
            msg = abos.explain_sdk_error(e)
            if msg != str(e):
                print("Claude Code:", str(e)[:300], flush=True)
                raise RuntimeError(msg) from e
            raise
        finally:
            ctx.release()
        out = Outcome(final, stop, usage, lines, ctx.used_computer, model_end, ctx.used_tools, None)
        out.session_id = sid  # type: ignore[attr-defined]
        out.billing = "abo"  # type: ignore[attr-defined]
        return out

    async def _client_for(self, key: str, session_id: str | None, sys_text: str, model: str, effort: str,
                          tools: dict[str, ExtraTool], builtin: list[str], ctx_box: list, max_steps: int, fresh: bool):
        from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient, PermissionResultAllow, PermissionResultDeny,
                                      create_sdk_mcp_server, tool)
        okey = hashlib.sha256(json.dumps([sys_text, model, effort, builtin, max_steps, _schema_key(tools)],
                                         ensure_ascii=False).encode()).hexdigest()
        stale = None
        with self._plock:
            w = self.warm.get(key)
            if w is not None and w.busy:
                key = f"{key}:{secrets.token_hex(3)}"  # gleichzeitiger Lauf im selben Chat: eigener Prozess
                w = None
            elif w is not None and (w.key != okey or fresh or w.session_id != session_id):
                stale, w = self.warm.pop(key), None
        if stale is not None:
            try:
                await stale.client.disconnect()
            except Exception:  # noqa: BLE001
                pass
        if w is not None:
            w.ctx_box[0] = ctx_box[0]
            return w
        # Werkzeuge als In-Process-MCP-Server; Aufrufe gehen an den Lauf, der den Prozess gerade nutzt
        box: list = [ctx_box[0]]
        loop = asyncio.get_running_loop()
        sdk_tools = []
        for name, ex in tools.items():
            schema = ex.schema.get("input_schema") or {"type": "object", "properties": {}}

            def make(n):
                async def handler(args):
                    blocks, err = await loop.run_in_executor(None, run_tool, box[0], n, args or {})
                    return {"content": blocks, "is_error": err}
                return handler
            sdk_tools.append(tool(name, (ex.schema.get("description") or name)[:4000], schema)(make(name)))
        server = create_sdk_mcp_server("scoops", tools=sdk_tools)

        async def can_use_tool(name: str, inp: dict, _ctx):
            ok, msg = self._permission(box[0], name, inp)
            return PermissionResultAllow() if ok else PermissionResultDeny(message=msg)

        wd = self._workdir()
        opts = ClaudeAgentOptions(
            model=model, cwd=wd, resume=None if fresh else session_id, setting_sources=[], strict_mcp_config=True,
            system_prompt=sys_text, tools=builtin, mcp_servers={"scoops": server},
            can_use_tool=can_use_tool, permission_mode="default", max_turns=max_steps,
            effort=effort, env=abos.claude_env({"DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
                                                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                                                "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                                                "CLAUDE_AGENT_SDK_CLIENT_APP": "ais-scoops-server"}),
            disallowed_tools=["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "Task", "Agent", "TodoWrite",
                              "AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "Skill", "SlashCommand"],
            max_buffer_size=abos.SDK_MAX_BUFFER, stderr=lambda s: None)
        client = ClaudeSDKClient(options=opts)
        await client.connect()
        w = _Warm(client, okey, None if fresh else session_id, box)
        with self._plock:
            if len(self.warm) >= MAX_WARM:
                oldest = min((x for x in self.warm.items() if not x[1].busy), key=lambda x: x[1].last_used, default=None)
                if oldest:
                    self.warm.pop(oldest[0])
                    asyncio.ensure_future(oldest[1].client.disconnect())
            self.warm[key] = w
        return w

    @staticmethod
    def _permission(ctx: RunCtx, name: str, inp: dict) -> tuple[bool, str]:
        if name.startswith("mcp__scoops__"):
            return True, ""
        if name in CLAUDE_TOOLS_WEB:
            return True, ""
        if name in CLAUDE_TOOLS_READ and ctx.access is not None:
            from .tasks import agent_permission
            wd = str(Path.home())
            return agent_permission(ctx.access, wd, name, inp, gate=lambda *a, **k: (
                False, "Dafür nimm terminal bzw. rechner_datei_* (mit Freigabe-Karte)."))
        return False, f"{name} gibt es im Chat nicht. Nimm deine Werkzeuge (terminal, rechner_datei_*)."

    async def _run_async(self, *, key: str, session_id: str | None, sys_text: str, model: str, effort: str,
                         tools: dict, builtin: list, ctx_box: list, ctx: RunCtx, messages: list[dict],
                         fresh_messages: list[dict] | None, usage: UsageBook, max_steps: int, on_text,
                         escalation: str | None) -> tuple[str, str, str | None, str]:
        from claude_agent_sdk import (AssistantMessage, RateLimitEvent, ResultMessage, SystemMessage, TextBlock,
                                      ToolUseBlock)
        try:
            from claude_agent_sdk import ProcessError
        except ImportError:  # pragma: no cover
            ProcessError = RuntimeError  # noqa: N806
        fresh = not session_id
        attempt = 0
        while True:
            try:
                w = await self._client_for(key, session_id, sys_text, model, effort, tools, builtin, ctx_box, max_steps,
                                           fresh=fresh)
            except Exception as e:  # noqa: BLE001
                # Unbekannte Sitzung meldet Claude Code schon beim Start (ResultError in connect): frisch mit Verlauf
                if fresh or not abos.resume_failed(str(e)):
                    raise
                print("Claude-Sitzung nicht gefunden, starte frisch mit dem Verlauf:", str(e)[:200], flush=True)
                with self._plock:
                    self.warm.pop(key, None)
                fresh, session_id = True, None
                continue
            w.busy, w.last_used = True, time.time()
            try:
                content = flatten(fresh_messages if (fresh and fresh_messages) else messages, intro=fresh)
                return await self._turns(w, ctx, content, model, usage, on_text, escalation, AssistantMessage,
                                         RateLimitEvent, ResultMessage, SystemMessage, TextBlock, ToolUseBlock)
            except _ResumeFailed:
                attempt += 1
                with self._plock:
                    self.warm.pop(key, None)
                try:
                    await w.client.disconnect()
                except Exception:  # noqa: BLE001
                    pass
                if attempt > 1 or fresh:
                    raise RuntimeError("Claude-Code-Sitzung ließ sich nicht starten.")
                fresh, session_id = True, None
            except (ProcessError, ConnectionError, OSError) as e:
                with self._plock:
                    self.warm.pop(key, None)
                kind = abos.classify(str(e))
                if kind:
                    raise abos.SubscriptionUnavailable("claude", str(e)[:300], limit=kind == "limit",
                                                       started=ctx.used_tools > 0) from e
                raise
            finally:
                w.busy, w.last_used = False, time.time()
                if key.startswith("once:"):  # einmaliger Lauf (z. B. Bildschirm-Teilaufgabe): Prozess gleich beenden
                    with self._plock:
                        if self.warm.get(key) is w:
                            self.warm.pop(key, None)
                    try:
                        await w.client.disconnect()
                    except Exception:  # noqa: BLE001
                        pass

    async def _turns(self, w: _Warm, ctx: RunCtx, content: list[dict], model: str, usage: UsageBook, on_text,
                     escalation, AssistantMessage, RateLimitEvent, ResultMessage, SystemMessage, TextBlock,
                     ToolUseBlock) -> tuple[str, str, str | None, str]:
        client = w.client
        sid = w.session_id
        final, stop = "", "end_turn"
        nudges = 0
        model_now = model
        msg: dict | str = {"type": "user", "message": {"role": "user", "content": content}, "parent_tool_use_id": None}

        async def stream_one(m):
            yield m

        watcher = asyncio.ensure_future(self._watch_cancel(client, ctx))
        try:
            while True:
                if isinstance(msg, dict):
                    await client.query(stream_one(msg))
                else:
                    await client.query(msg)
                texts: list[str] = []
                err_text, err_kind = "", None
                async for m in client.receive_response():
                    if isinstance(m, SystemMessage) and m.subtype == "init":
                        sid = (m.data or {}).get("session_id") or sid
                        if (m.data or {}).get("apiKeySource") not in (None, "none"):
                            raise abos.SubscriptionUnavailable("claude", "Claude Code nutzt einen API-Schlüssel statt "
                                                               "des Abo-Logins.")
                    elif isinstance(m, RateLimitEvent):
                        info = _limit_info(m.rate_limit_info.raw or {})
                        abos.note_info("claude", info)
                        if m.rate_limit_info.status == "rejected":
                            err_kind = "limit"
                            err_text = err_text or f"Claude-Abo-Limit erreicht ({info.get('window') or 'Limit'})"
                            abos.note_limit("claude", err_text, m.rate_limit_info.resets_at)
                    elif isinstance(m, AssistantMessage):
                        sid = m.session_id or sid
                        if m.error in ("rate_limit", "billing_error"):
                            err_kind = "limit"
                            err_text = err_text or f"Claude-Abo: {m.error}"
                        elif m.error == "authentication_failed":
                            err_kind = "auth"
                            err_text = err_text or "Claude-Code-Anmeldung abgelaufen"
                        for b in m.content:
                            if isinstance(b, ToolUseBlock):
                                if b.name == "WebSearch":
                                    q = str((b.input or {}).get("query") or "")
                                    ctx.line(f"Sucht im Web: {q[:50]}" if q else "Sucht im Web")
                                elif b.name == "WebFetch":
                                    ctx.line("Liest eine Webseite")
                                elif b.name in CLAUDE_TOOLS_READ:
                                    ctx.line("Liest Dateien auf dem Mac")
                                elif b.name == "mcp__scoops__eskalieren" and escalation:
                                    model_now = escalation
                                    try:
                                        await client.set_model(escalation)
                                    except Exception as e:  # noqa: BLE001
                                        print("Abo-Eskalation:", e, flush=True)
                            elif isinstance(b, TextBlock) and b.text.strip():
                                texts.append(b.text.strip())
                                if on_text:
                                    on_text(b.text.strip())
                    elif isinstance(m, ResultMessage):
                        sid = m.session_id or sid
                        for mdl, d in (m.model_usage or {}).items():
                            d = d if isinstance(d, dict) else getattr(d, "__dict__", {})
                            usage.add_counts(mdl, d.get("inputTokens") or d.get("input_tokens"),
                                             d.get("outputTokens") or d.get("output_tokens"),
                                             d.get("cacheReadInputTokens") or d.get("cache_read_input_tokens"),
                                             d.get("cacheCreationInputTokens") or d.get("cache_creation_input_tokens"),
                                             1, d.get("webSearchRequests") or 0)
                        errs = "; ".join(m.errors or [])
                        if m.is_error and not (ctx.cancel and ctx.cancel.is_set()):
                            text = f"{m.subtype} {errs} {m.result or ''} {m.api_error_status or ''}"
                            if abos.resume_failed(text):
                                raise _ResumeFailed(text)
                            kind = err_kind or abos.classify(text) or ("limit" if m.api_error_status == 429 else None)
                            if kind:
                                if kind == "limit":
                                    abos.note_limit("claude", err_text or text[:200])
                                raise abos.SubscriptionUnavailable("claude", err_text or text[:300], limit=kind == "limit",
                                                                   started=ctx.used_tools > 0)
                            if m.subtype == "error_max_turns":
                                stop = "max_steps"
                                final = final or "Ich habe nach vielen Schritten abgebrochen."
                                break
                            raise RuntimeError(f"Claude Code: {text[:300]}")
                        if ctx.cancel and ctx.cancel.is_set():
                            stop = "stopped"
                        final = (m.result or "\n\n".join(texts)).strip()
                if err_kind and not final:
                    if err_kind == "limit":
                        abos.note_limit("claude", err_text)
                    raise abos.SubscriptionUnavailable("claude", err_text, limit=err_kind == "limit",
                                                       started=ctx.used_tools > 0)
                if stop in ("stopped", "max_steps"):
                    break
                if (nudges < MAX_NUDGES and not ctx.handed_off and announces_action(final)):
                    nudges += 1
                    msg = NUDGE
                    continue
                break
        finally:
            watcher.cancel()
        if stop == "stopped":
            final = ""
        w.session_id = sid
        abos.clear_limit("claude")
        return final, stop, sid, model_now

    @staticmethod
    async def _watch_cancel(client, ctx: RunCtx) -> None:
        if not ctx.cancel:
            return
        while not ctx.cancel.is_set():
            await asyncio.sleep(0.3)
        try:
            await client.interrupt()
        except Exception:  # noqa: BLE001
            pass


class _ResumeFailed(RuntimeError):
    pass


# -- Codex (ChatGPT-Abo) ----------------------------------------------------------------------------------------------
# Token → Kasten mit dem RunCtx des laufenden Chat-Laufs (MCP-Endpunkt /mcp/abo)
MCP_TOKENS: dict[str, list] = {}


def mcp_handle(token: str | None, payload) -> tuple[int, object | None]:
    """MCP (Streamable HTTP, nur JSON) für Codex-Chat-Läufe. Token gilt für einen warmen Codex-Prozess, Werkzeuge kommen
    aus dem Lauf, der ihn gerade nutzt."""
    box = MCP_TOKENS.get(token or "")
    ctx: RunCtx | None = box[0] if box else None
    if ctx is None:
        return 401, {"jsonrpc": "2.0", "id": None, "error": {"code": -32001, "message": "Ungültiges Token"}}
    if isinstance(payload, list):
        out = [r for r in (_rpc(box, p) for p in payload) if r is not None]
        return (200, out) if out else (202, None)
    r = _rpc(box, payload)
    return (200, r) if r is not None else (202, None)


def _rpc(box: list, p) -> dict | None:
    if not isinstance(p, dict):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
    mid, method, params = p.get("id"), p.get("method"), p.get("params") or {}
    if mid is None:
        return None
    ok = lambda res: {"jsonrpc": "2.0", "id": mid, "result": res}  # noqa: E731
    ctx: RunCtx = box[0]
    if method == "initialize":
        return ok({"protocolVersion": params.get("protocolVersion") or "2025-06-18",
                   "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "scoops", "version": "1.0"}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": [{"name": n, "description": (t.schema.get("description") or "")[:4000],
                              "inputSchema": t.schema.get("input_schema") or {"type": "object", "properties": {}}}
                             for n, t in box[1].items()]})
    if method == "tools/call":
        blocks, err = run_tool(ctx, str(params.get("name") or ""), params.get("arguments") or {})
        return ok({"content": blocks, "isError": err})
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Methode {method} unbekannt"}}


@dataclass
class _WarmCodex:
    codex: object
    key: str
    token: str
    box: list
    last_used: float = field(default_factory=time.time)
    busy: bool = False
    temp: bool = False  # nur für einen Lauf (gleichzeitiger Lauf im selben Chat): danach beenden
    gate: object | None = None  # codex_cu.Gate des laufenden Laufs (Computer Use von Codex), sonst None


class CodexChatEngine:
    """Chat über Codex mit dem ChatGPT-Login des Nutzers (eigener CODEX_HOME, siehe abos.codex_home)."""

    provider = "openai"

    def __init__(self, api_engine: Engine, port: int = 8787):
        self.api = api_engine
        self.port = port
        self.warm: dict[str, _WarmCodex] = {}
        self._plock = threading.Lock()
        self._reaper: threading.Thread | None = None

    def close_idle(self, idle: float = IDLE_CLOSE) -> None:
        with self._plock:
            old = [k for k, w in self.warm.items() if not w.busy and time.time() - w.last_used > idle]
            gone = [self.warm.pop(k) for k in old]
        for w in gone:
            self._close(w)

    def close_all(self) -> None:
        with self._plock:
            gone = list(self.warm.values())
            self.warm.clear()
        for w in gone:
            self._close(w)

    @staticmethod
    def _close(w: _WarmCodex) -> None:
        MCP_TOKENS.pop(w.token, None)
        try:
            w.codex.close()
        except Exception:  # noqa: BLE001
            pass

    def _reap_loop(self) -> None:
        while True:
            time.sleep(30)
            try:
                self.close_idle()
            except Exception as e:  # noqa: BLE001
                print("Codex-Prozesse aufräumen:", e, flush=True)

    def _overrides(self, allow_web: bool, cu: bool = False) -> tuple[str, ...]:
        url = f"http://127.0.0.1:{self.port}/mcp/abo"
        extra: tuple[str, ...] = ()
        if cu:  # Computer Use von Codex: nur dieser eine MCP-Server (codex_cu.py)
            from . import codex_cu
            extra = codex_cu.overrides(abos.codex_home())
        return abos.codex_overrides() + extra + (
            "features.shell_tool=false", f'web_search="{"live" if allow_web else "disabled"}"',
            'shell_environment_policy.inherit="core"',
            f'mcp_servers.scoops.url="{url}"', 'mcp_servers.scoops.bearer_token_env_var="AISBOT_ABO_TOKEN"',
            "mcp_servers.scoops.tool_timeout_sec=900", "mcp_servers.scoops.startup_timeout_sec=20",
            'mcp_servers.scoops.default_tools_approval_mode="approve"')

    def _codex_for(self, key: str, allow_web: bool, tools: dict[str, ExtraTool], ctx: RunCtx,
                   cu: bool = False) -> _WarmCodex:
        from openai_codex import Codex, CodexConfig
        okey = hashlib.sha256(json.dumps([allow_web, _schema_key(tools), cu]).encode()).hexdigest()
        temp = key.startswith("once:")
        with self._plock:
            w = self.warm.get(key)
            if w and w.busy:
                temp, w = True, None  # nicht den laufenden Prozess ersetzen: eigener, danach beendet
            elif w and w.key != okey:
                self.warm.pop(key, None)
                self._close(w)
                w = None
        if w is not None:
            w.box[0], w.box[1] = ctx, tools
            return w
        token = secrets.token_urlsafe(24)
        box = [ctx, tools]
        MCP_TOKENS[token] = box
        wd = str(abos.abo_dir() / "chats")
        Path(wd).mkdir(parents=True, exist_ok=True)
        try:
            codex = Codex(CodexConfig(codex_bin=abos.codex_bin(), config_overrides=self._overrides(allow_web, cu), cwd=wd,
                                      env=abos.codex_env({"AISBOT_ABO_TOKEN": token})))
        except Exception:
            MCP_TOKENS.pop(token, None)
            raise
        w = _WarmCodex(codex, okey, token, box, temp=temp)
        # nichts ausweiten (Shell aus, Sandbox nur lesend); Anfragen von Computer Use gehen an das Gate des Laufs
        from .codex_cu import handler
        codex._client._approval_handler = handler(lambda: w.gate, _decline)
        if not temp:
            with self._plock:
                self.warm[key] = w
        return w

    def run(self, *, system, messages: list[dict], model: str, escalation_model: str | None = None,
            effort: str = "low", work_effort: str | None = "medium", extra_tools: list[ExtraTool] | None = None,
            mcp_hub=None, budget: float = 1.0, max_steps: int = 120, holder: str = "cli",
            on_line: Callable[[str], None] | None = None, on_text: Callable[[str], None] | None = None,
            cancel: threading.Event | None = None, hub: ComputerHub | None = None, allow_computer: bool = True,
            allow_web: bool = True, session_key: str | None = None, session_id: str | None = None,
            fresh_messages: list[dict] | None = None, access=None, codex_cu: dict | None = None,
            **_ignored) -> Outcome:
        """`codex_cu` (bots._abo_plan): {"use": bool, "reason": str|None, "ask_app", "on_unavailable", "user"} – Computer
        Use von Codex statt `bildschirm` (codex_cu.py), nur am Server-Mac."""
        from openai_codex import ApprovalMode, ImageInput, Sandbox, TextInput
        if self._reaper is None:
            self._reaper = threading.Thread(target=self._reap_loop, daemon=True, name="codex-reaper")
            self._reaper.start()
        st = abos.login_status("openai")
        if not st.get("subscription"):
            raise abos.SubscriptionUnavailable("openai", "Codex ist nicht mit ChatGPT angemeldet.")
        hub = hub or self.api.hub
        ctx, lines = prepare(extra_tools, mcp_hub, hub, allow_computer, None, on_line, cancel, holder, None)
        tools = ctx.tools
        cu = dict(codex_cu or {})
        use_cu = bool(cu.get("use")) and allow_computer and hub is not None and "bildschirm" in tools
        gate = None
        if use_cu:
            from . import codex_cu as cu_mod
            gate = cu_mod.Gate(hub, ctx.line, cancel, acquire=ctx.get_computer, release=ctx.release,
                               ask_app=(lambda app, msg: cu["ask_app"](app, msg, cancel)) if cu.get("ask_app") else None,
                               on_unavailable=cu.get("on_unavailable"),
                               user=cu.get("user") or "Arman")
        if "bildschirm" in tools:
            tools["bildschirm"] = _screen_fallback(tools["bildschirm"], gate, None if use_cu else cu.get("reason"), ctx)
        sys_text = system if isinstance(system, str) else "\n\n".join(b.get("text", "") for b in system
                                                                     if b.get("type") == "text")
        sys_text += ("\n\nTechnik: Deine Werkzeuge kommen vom MCP-Server „scoops“. Eine eigene Shell hast du hier nicht; "
                     "für den Mac nimmst du terminal und rechner_datei_* bzw. bildschirm.")
        if gate is not None:
            from .codex_cu import PROMPT
            sys_text += "\n\n" + PROMPT.format(user=cu.get("user") or "Arman", fallback="Das Werkzeug bildschirm")
        usage = UsageBook(billing="abo")
        try:
            w = self._codex_for(session_key or f"once:{secrets.token_hex(4)}", allow_web, tools, ctx, cu=gate is not None)
        except Exception:
            if gate is not None:
                gate.close()
            raise
        w.busy, w.last_used, w.gate = True, time.time(), gate
        final, stop, sid = "", "end_turn", session_id
        try:
            codex = w.codex
            kw = dict(model=model, sandbox=Sandbox.read_only, approval_mode=ApprovalMode.deny_all, base_instructions=sys_text)
            if gate is not None:  # Computer Use: Freigabe-Richtlinie „granular“, damit Elicitations bei uns ankommen
                from .codex_cu import open_thread

                def start(sid):
                    return open_thread(codex, sid, model=model, sandbox=Sandbox.read_only, base_instructions=sys_text)
            else:
                def start(sid):
                    return codex.thread_resume(sid, **kw) if sid else codex.thread_start(**kw)
            thread = None
            fresh = not session_id
            if session_id:
                try:
                    thread = start(session_id)
                except Exception as e:  # noqa: BLE001 – Thread weg (z. B. anderer CODEX_HOME): neu beginnen
                    print("Codex-Thread nicht fortsetzbar:", str(e)[:200], flush=True)
                    thread, fresh = None, True
            if thread is None:
                thread = start(None)
            sid = thread.id
            content = flatten(fresh_messages if (fresh and fresh_messages) else messages, intro=fresh)
            items = []
            for b in content:
                if b.get("type") == "text":
                    items.append(TextInput(b["text"]))
                elif b.get("type") == "image":
                    src = b.get("source") or {}
                    items.append(ImageInput(f"data:{src.get('media_type', 'image/png')};base64,{src.get('data', '')}"))
                else:
                    items.append(TextInput("(PDF-Anhang: mit datei_aus_bibliothek bzw. dem Anhang-Werkzeug lesen)"))
            nudges = 0
            while True:
                text, err = self._turn(thread, items, work_effort or effort, ctx, usage, model, on_text, gate)
                if err:
                    kind = abos.classify(err)
                    if kind:
                        if kind == "limit":
                            abos.note_limit("openai", err)
                        raise abos.SubscriptionUnavailable("openai", err[:300], limit=kind == "limit",
                                                           started=ctx.used_tools > 0)
                    if cancel and cancel.is_set():
                        stop, text = "stopped", ""
                    else:
                        raise RuntimeError(f"Codex: {err[:300]}")
                final = text
                if cancel and cancel.is_set():
                    stop, final = "stopped", ""
                    break
                if nudges < MAX_NUDGES and not ctx.handed_off and announces_action(final):
                    nudges += 1
                    items = [TextInput(NUDGE)]
                    continue
                break
            abos.clear_limit("openai")
        except abos.SubscriptionUnavailable:
            raise
        except Exception as e:
            kind = abos.classify(str(e))
            with self._plock:
                if self.warm.get(session_key or "") is w:
                    self.warm.pop(session_key or "", None)
            self._close(w)
            if kind:
                raise abos.SubscriptionUnavailable("openai", str(e)[:300], limit=kind == "limit",
                                                   started=ctx.used_tools > 0) from e
            raise
        finally:
            w.busy, w.last_used, w.gate = False, time.time(), None
            if gate is not None:
                gate.close()
            ctx.release()
            if w.temp:
                self._close(w)
        out = Outcome(final, stop, usage, lines, ctx.used_computer or bool(gate and gate.used), model,
                      ctx.used_tools + (gate.actions if gate else 0), None)
        out.session_id = sid  # type: ignore[attr-defined]
        out.billing = "abo"  # type: ignore[attr-defined]
        return out

    @staticmethod
    def _turn(thread, items, effort: str, ctx: RunCtx, usage: UsageBook, model: str, on_text,
              gate=None) -> tuple[str, str]:
        from .tasks import _codex_line
        handle = thread.turn(items, effort=effort if effort in ("low", "medium", "high") else "medium")
        stop_flag = {"done": False}

        def watch() -> None:
            while not stop_flag["done"]:
                if ctx.cancel and ctx.cancel.is_set():
                    try:
                        handle.interrupt()
                    except Exception:  # noqa: BLE001
                        pass
                    return
                time.sleep(0.3)

        threading.Thread(target=watch, daemon=True).start()
        final, err = "", ""
        last_total = None
        try:
            for ev in handle.stream():
                p = ev.payload
                if ev.method == "item/started":
                    it = p.item.root if hasattr(p.item, "root") else p.item
                    kind = type(it).__name__
                    if "WebSearch" in kind:
                        q = str(getattr(it, "query", "") or "")
                        ctx.line(f"Sucht im Web: {q[:50]}" if q else "Sucht im Web")
                    elif "Mcp" in kind:
                        if gate is not None:
                            gate.item_started(it)  # Computer Use: Zeile („Klickt in Safari“), Rechner belegt
                    else:
                        ctx.line(_codex_line(it, ctx.tools))
                elif ev.method == "item/completed":
                    it = p.item.root if hasattr(p.item, "root") else p.item
                    if gate is not None:
                        gate.item_completed(it)
                    if type(it).__name__ == "AgentMessageThreadItem":
                        final = getattr(it, "text", "") or final
                elif ev.method == "thread/tokenUsage/updated":
                    tu = getattr(p, "token_usage", None) or getattr(p, "tokenUsage", None)
                    last_total = getattr(tu, "last", None) or last_total
                elif ev.method == "turn/completed":
                    turn = p.turn
                    e = getattr(turn, "error", None)
                    if e:
                        err = str(getattr(e, "message", "") or e)
                    items = getattr(turn, "items", None) or []
                    try:
                        from openai_codex._run import _final_assistant_response_from_items
                        final = _final_assistant_response_from_items(items) or final
                    except Exception:  # noqa: BLE001
                        pass
                elif ev.method == "error":
                    err = err or str(getattr(p, "message", "") or getattr(getattr(p, "error", None), "message", "") or p)
        finally:
            stop_flag["done"] = True
        if last_total is not None:
            cached = getattr(last_total, "cached_input_tokens", 0) or 0
            usage.add_counts(model, max(0, (getattr(last_total, "input_tokens", 0) or 0) - cached),
                             getattr(last_total, "output_tokens", 0) or 0, cached, 0, 1)
        else:
            usage.add_counts(model, 0, 0, 0, 0, 1)
        if final and on_text:
            on_text(final)
        return final.strip(), err


def _screen_fallback(ex: ExtraTool, gate, reason: str | None, ctx: RunCtx) -> ExtraTool:
    """`bildschirm` im Codex-Chat: Mit Computer Use von Codex nur als Ersatz, wenn Computer Use gescheitert ist. Ohne
    Computer Use (aber am Server-Mac, z. B. App fehlt): beim ersten Einsatz eine Zeile, warum."""
    told = {"done": False}

    def fn(i: dict):
        if gate is not None and not gate.failed:
            return ("Nimm für den Bildschirm die Werkzeuge von computer-use (get_app_state, click, type_text …). "
                    "bildschirm nur, wenn computer-use mit einem Fehler scheitert.")
        if gate is not None:
            gate.detach()  # ab jetzt belegt bildschirm den Rechner über ctx (dieselbe Belegung, kein Wechsel)
        if reason and not told["done"]:
            told["done"] = True
            ctx.line(f"Bildschirm über Scoops statt Codex Computer Use ({reason})")
        return ex.handler(i)

    return ExtraTool(ex.schema, fn, ex.status)


def _decline(method: str, params: dict | None) -> dict:
    from .tasks import _codex_decline
    return _codex_decline(method, params)


# -- Kurze Hilfsaufrufe (Gruppen-Routing u. ä.) -----------------------------------------------------------------------
def quick_text(system: str, prompt: str, model: str = "claude-haiku-5-5", timeout: float = 60) -> str:
    """Ein kurzer Aufruf ohne Werkzeuge über Claude Code mit Abo. Wirft bei Fehlern (der Aufrufer nimmt dann die API)."""
    from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query

    async def go() -> str:
        opts = ClaudeAgentOptions(model=model, system_prompt=system, tools=[], setting_sources=[], strict_mcp_config=True,
                                  max_turns=1, effort="low", cwd=str(abos.abo_dir()),
                                  env=abos.claude_env({"DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
                                                       "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}),
                                  max_buffer_size=abos.SDK_MAX_BUFFER, stderr=lambda s: None)
        out = ""
        async for m in query(prompt=prompt, options=opts):
            if isinstance(m, ResultMessage):
                if m.is_error:
                    raise RuntimeError(f"Claude Code: {m.subtype} {'; '.join(m.errors or [])}"[:300])
                out = m.result or ""
        return out

    abos.abo_dir().mkdir(parents=True, exist_ok=True)
    return LOOP.run(go(), timeout=timeout)
