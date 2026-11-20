"""Eigener MCP-Client (Streamable HTTP und stdio) für Composio, die Team App und Atrium.

Warum: Hängt man MCP-Server über den MCP-Connector der Claude API an, verbindet sich die API bei
JEDER Anfrage neu – das kostete ~5 s pro Antwort. Hier hält der Scoop-Server die Werkzeuglisten
im Speicher und ruft die Werkzeuge selbst auf; Claude sieht sie als normale (verzögert geladene) Werkzeuge.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time

import httpx

from .i18n import tx
from .profile import user_name

# Senden, Antworten, Weiterleiten von Mails läuft nur über die Mail-Karte (Freigabe durch Arman).
MAIL_SEND = re.compile(r"^(GMAIL|OUTLOOK)_\w*(SEND|REPLY|FORWARD)")
TOOLS_TTL = 30 * 60  # Werkzeuglisten 30 Minuten zwischenspeichern
SEP = "__"
# Häufig gebrauchte Werkzeuge großer Server immer direkt laden (der Rest über die Werkzeugsuche).
ALWAYS_LOADED = {
    "teamapp": {"app_ueberblick", "recruiting_kontakte_lesen", "team_mitglieder_suchen", "wochenreports_lesen",
                "team_statistik", "kennzahlen_rangliste", "daten_lesen", "nachrichten_lesen"},
    "atrium": {"list_areas", "list_projects", "get_area_context", "get_project_context", "search_sources",
               "get_open_questions", "list_tasks", "add_capture"},
    "atrium_berlin": {"get_space", "get_project", "search", "append_knowledge"},
    "atrium_koeln": {"get_space", "get_project", "search", "append_knowledge"},
    "notion": {"notion-search", "notion-fetch", "notion-query-data-sources", "notion-update-page", "notion-create-pages"},
}
# Notion direkt verbunden (notion_mcp.py): Composio-Notion nur noch mit ausdrücklich gewähltem Konto.
NOTION_SLUG = re.compile(r"^NOTION_")
# Anzeigenamen eigener MCP-Server (custom_mcp.py) für Statuszeilen („Nutzt Qonto“), gesetzt in MCPHub.configure.
LABELS: dict[str, str] = {}


def safe_tool_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", name or "")


class MCPServer:
    def __init__(self, name: str, url: str, token, header: str | None = "Authorization"):
        """`token`: fester Wert oder Funktion (OAuth). `header`: „Authorization“ (Bearer), eigener Header-Name (Wert
        unverändert) oder None/leeres Token = ohne Anmeldung (eigene MCP-Server, ab 1.35)."""
        self.name = name
        self.url = url
        self.token = token
        self.header = header
        self.last_error: str | None = None
        self.http = httpx.Client(timeout=httpx.Timeout(120, connect=10))
        self.session_id: str | None = None
        self._tools: list[dict] = []
        self._tools_at = 0.0
        self._lock = threading.Lock()
        self._id = 0

    def _rpc(self, method: str, params: dict | None = None, notify: bool = False) -> dict:
        self._id += 1
        body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            body["id"] = self._id
        # `token` ist ein fester Schlüssel oder (OAuth, z. B. Notion) eine Funktion, die ein gültiges Token liefert.
        dynamic = callable(self.token)
        tok = self.token() if dynamic else self.token
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"}
        self._auth(headers, tok)
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        r = self.http.post(self.url, headers=headers, json=body)
        if r.status_code == 401 and dynamic:  # Token abgelaufen/widerrufen: einmal erneuern und wiederholen
            self._auth(headers, self.token(force_refresh=True))
            r = self.http.post(self.url, headers=headers, json=body)
        if r.headers.get("mcp-session-id"):
            self.session_id = r.headers["mcp-session-id"]
        if notify:
            return {}
        if r.status_code >= 400:
            raise RuntimeError(f"{self.name}: HTTP {r.status_code} {r.text[:200]}")
        text = r.text
        if "text/event-stream" in r.headers.get("content-type", ""):
            data = [ln[5:].strip() for ln in text.splitlines() if ln.startswith("data:")]
            msgs = [json.loads(d) for d in data if d]
            msg = next((m for m in reversed(msgs) if m.get("id") == body.get("id")), msgs[-1] if msgs else {})
        else:
            msg = json.loads(text) if text.strip() else {}
        if "error" in msg:
            raise RuntimeError(f"{self.name}: {msg['error'].get('message', msg['error'])}")
        return msg.get("result", {})

    def _auth(self, headers: dict, tok) -> None:
        if not self.header or not tok:
            return
        if self.header.lower() == "authorization":
            headers["Authorization"] = tok if re.match(r"^(Bearer|Basic|Token) ", str(tok)) else f"Bearer {tok}"
        else:
            headers[self.header] = str(tok)

    def _ensure_init(self) -> None:
        if self.session_id is not None or self._tools_at:
            return
        try:
            self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "ais-bot", "version": "1.5"}})
            self._rpc("notifications/initialized", notify=True)
        except Exception:  # noqa: BLE001 - zustandslose Server brauchen kein initialize
            pass

    def tools(self) -> list[dict]:
        with self._lock:
            if self._tools and time.time() - self._tools_at < TOOLS_TTL:
                return self._tools
            self._ensure_init()
            tools, cursor = [], None
            for _ in range(10):
                res = self._rpc("tools/list", {"cursor": cursor} if cursor else {})
                tools += res.get("tools", [])
                cursor = res.get("nextCursor")
                if not cursor:
                    break
            self._tools, self._tools_at = tools, time.time()
            self.last_error = None
            return tools

    def call(self, tool: str, args: dict) -> list[dict] | str:
        try:
            res = self._rpc("tools/call", {"name": tool, "arguments": args})
        except RuntimeError as e:
            if "session" in str(e).lower():  # Sitzung abgelaufen: neu verbinden und einmal wiederholen
                self.session_id, self._tools_at = None, 0.0
                self._ensure_init()
                res = self._rpc("tools/call", {"name": tool, "arguments": args})
            else:
                raise
        return _blocks(res)


def _blocks(res: dict) -> list[dict] | str:
    blocks = []
    for c in res.get("content", []):
        if c.get("type") == "text":
            blocks.append({"type": "text", "text": c.get("text", "")[:60000]})
        elif c.get("type") == "image" and c.get("data"):
            blocks.append({"type": "image", "source": {"type": "base64", "media_type": c.get("mimeType", "image/png"),
                                                       "data": c["data"]}})
    if res.get("isError"):
        text = " ".join(b.get("text", "") for b in blocks if b["type"] == "text")
        raise RuntimeError(text[:2000] or "Werkzeugfehler")
    return blocks or "OK"


class MCPStdioServer:
    """Lokaler MCP-Server als Unterprozess (stdio, eine JSON-RPC-Nachricht pro Zeile), z. B. Atrium."""

    def __init__(self, name: str, command: list[str], env: dict[str, str]):
        self.name = name
        self.command = command
        self.env = env
        self.url, self.token = " ".join(command), json.dumps(env, sort_keys=True)  # für MCPHub.configure
        self.proc: subprocess.Popen | None = None
        self.last_error: str | None = None
        self._tools: list[dict] = []
        self._tools_at = 0.0
        self._lock = threading.Lock()
        self._id = 0

    def _start(self) -> None:
        if self.proc and self.proc.poll() is None:
            return
        self.proc = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env={**os.environ, **self.env}, text=True, bufsize=1)
        self._request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "ais-bot", "version": "1.8"}}, timeout=30)
        self._write({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _write(self, msg: dict) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def _request(self, method: str, params: dict, timeout: float = 180) -> dict:
        self._id += 1
        rid = self._id
        self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        assert self.proc and self.proc.stdout
        done = threading.Event()
        box: dict = {}

        def read() -> None:
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    box["error"] = tx("Prozess beendet")
                    break
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == rid and ("result" in msg or "error" in msg):
                    box["msg"] = msg
                    break
            done.set()

        threading.Thread(target=read, daemon=True).start()
        if not done.wait(timeout):
            self.proc.kill()
            raise RuntimeError(tx("{name}: keine Antwort nach {seconds} s", name=self.name, seconds=int(timeout)))
        if "error" in box:
            raise RuntimeError(f"{self.name}: {box['error']}")
        msg = box["msg"]
        if "error" in msg:
            raise RuntimeError(f"{self.name}: {msg['error'].get('message', msg['error'])}")
        return msg.get("result", {})

    def tools(self) -> list[dict]:
        with self._lock:
            if self._tools and time.time() - self._tools_at < TOOLS_TTL and self.proc and self.proc.poll() is None:
                return self._tools
            self._start()
            self._tools, self._tools_at = self._request("tools/list", {}).get("tools", []), time.time()
            self.last_error = None
            return self._tools

    def call(self, tool: str, args: dict) -> list[dict] | str:
        with self._lock:
            self._start()
            res = self._request("tools/call", {"name": tool, "arguments": args})
        return _blocks(res)



class MCPHub:
    """Alle MCP-Server des Scoop-Servers; liefert Werkzeug-Schemas und führt Aufrufe aus."""

    def __init__(self) -> None:
        self.servers: dict[str, MCPServer] = {}
        # Ab 1.24: lesende Composio-Werkzeuge direkt per REST, vollständig und kompakt (composio_direct.py).
        # Setzt server.py; ohne bleibt es beim reinen Tool Router.
        self.composio_direct = None

    def configure(self, specs: list[dict]) -> None:
        for s in specs:
            cur = self.servers.get(s["name"])
            if s.get("label"):
                LABELS[s["name"]] = s["label"]
            if s.get("type") == "stdio":
                srv = MCPStdioServer(s["name"], s["command"], s.get("env") or {})
                if not cur or cur.url != srv.url or cur.token != srv.token:
                    self._drop(s["name"])
                    self.servers[s["name"]] = srv
            else:
                header = s.get("header", "Authorization")
                if (not cur or cur.url != s["url"] or cur.token != s["authorization_token"]
                        or getattr(cur, "header", "Authorization") != header):
                    self._drop(s["name"])
                    self.servers[s["name"]] = MCPServer(s["name"], s["url"], s["authorization_token"], header)
        for name in list(self.servers):
            if name not in {s["name"] for s in specs}:
                self._drop(name)

    def _drop(self, name: str) -> None:
        srv = self.servers.pop(name, None)
        proc = getattr(srv, "proc", None)
        if proc and proc.poll() is None:
            proc.terminate()

    def warm(self) -> None:
        for srv in self.servers.values():
            try:
                srv.tools()
            except Exception as e:  # noqa: BLE001
                srv.last_error = str(e)[:300]
                print(f"MCP {srv.name} nicht erreichbar: {e}", flush=True)

    def tool_schemas(self) -> list[dict]:
        out = []
        for srv in self.servers.values():
            try:
                tools = srv.tools()
            except Exception as e:  # noqa: BLE001
                srv.last_error = str(e)[:300]
                print(f"MCP {srv.name}: {e}", flush=True)
                continue
            defer = len(tools) > 15  # kleine Server direkt laden, große nur über die Werkzeugsuche
            keep = ALWAYS_LOADED.get(srv.name, set())
            for t in tools:
                name = f"{srv.name}{SEP}{safe_tool_name(t['name'])}"[:128]
                schema = t.get("inputSchema") or {"type": "object", "properties": {}}
                if schema.get("type") != "object":
                    schema = {"type": "object", "properties": {}}
                out.append({"name": name, "description": (t.get("description") or t.get("title") or t["name"])[:1024],
                            "input_schema": schema, "defer_loading": defer and t["name"] not in keep})
        return out

    def owns(self, tool_name: str) -> bool:
        return SEP in tool_name and tool_name.split(SEP, 1)[0] in self.servers

    def resolve(self, tool_name: str) -> tuple[str, str, dict | None]:
        """(Server, echter Werkzeugname, Werkzeug-Beschreibung) zu einem Hub-Namen. Namen mit Zeichen außerhalb von
        [A-Za-z0-9_-] werden in tool_schemas ersetzt (sonst lehnt die API die ganze Anfrage ab) und hier zurückgeführt."""
        server, tool = tool_name.split(SEP, 1)
        srv = self.servers.get(server)
        for t in (getattr(srv, "_tools", None) or []) if srv else []:
            if t.get("name") == tool or safe_tool_name(t.get("name", "")) == tool:
                return server, t["name"], t
        return server, tool, None

    def call(self, tool_name: str, args: dict):
        server, tool, _ = self.resolve(tool_name)
        if server == "composio" and tool == "COMPOSIO_MULTI_EXECUTE_TOOL":
            for t in args.get("tools") or []:
                if MAIL_SEND.match(str(t.get("tool_slug", "")).upper()):
                    raise RuntimeError(f"Mails sendest du nie direkt. Nutz `mail_vorbereiten`: {user_name()} sieht dann das "
                                       "Mail-Fenster, kann den Text bearbeiten und tippt selbst auf Senden.")
            if "notion" in self.servers and self.servers["notion"]._tools:
                via = [t for t in args.get("tools") or [] if NOTION_SLUG.match(str(t.get("tool_slug", "")).upper())
                       and not str(t.get("account") or "").strip()]
                if via:
                    raise RuntimeError("Notion ist direkt verbunden: Nimm dafür die Werkzeuge `notion__…` "
                                       "(z. B. `notion__notion-search`, `notion__notion-fetch`, "
                                       "`notion__notion-query-data-sources`), nicht Composio.")
            if self.composio_direct is not None:
                srv = self.servers[server]
                return self.composio_direct.multi_execute(args, lambda a: srv.call(tool, a))
        return self.servers[server].call(tool, args)
