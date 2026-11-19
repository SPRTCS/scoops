"""Fake-Codex für Computer Use von Codex (test_codex_cu.py, Probelauf Ablauf 19).

Spielt nach, was Codex (0.169) mit dem MCP-Server `computer-use` (Codex Computer Use 1001923) an den Client schickt,
gemessen am 18.11.2026:
- App-Freigabe: `mcpServer/elicitation/request` mit `serverName: "computer-use"`, `mode: "form"`,
  `_meta: {"persist": ["always"]}`, `message: "Allow ChatGPT to use Finder?"`, leeres Schema.
- Aktions-Freigabe (`default_tools_approval_mode = "prompt"`): Elicitation mit `_meta.codex_approval_kind`.
- Ereignisse `item/started`/`item/completed` mit `McpToolCallThreadItem` (server, tool, arguments, result, error).
Kein Prozess, kein Netz, kein Login. Das Skript eines Zugs ist ein Generator, der Ereignisse liefert und den
Freigabe-Handler (`client._approval_handler`) so aufruft, wie es der Lese-Thread des SDK täte.
"""

from __future__ import annotations

import threading
from types import SimpleNamespace as NS
from typing import Callable, Iterator


class McpToolCallThreadItem:  # Name wie im SDK (die Engines prüfen type(it).__name__)
    def __init__(self, tool: str, arguments: dict | None = None, server: str = "computer-use", text: str | None = None,
                 error: str | None = None):
        self.server, self.tool, self.arguments = server, tool, arguments or {}
        self.result = NS(content=[{"type": "text", "text": text}]) if text is not None else None
        self.error = NS(message=error) if error else None
        self.status = "failed" if error else "completed"


class AgentMessageThreadItem:
    def __init__(self, text: str):
        self.text = text


def ev(method: str, **payload) -> NS:
    return NS(method=method, payload=NS(**payload))


def started(item) -> NS:
    return ev("item/started", item=item)


def completed(item) -> NS:
    return ev("item/completed", item=item)


def done(text: str = "") -> list[NS]:
    return [completed(AgentMessageThreadItem(text)), ev("turn/completed", turn=NS(error=None, items=[]))]


def app_request(app: str = "Safari") -> dict:
    return {"threadId": "thr", "turnId": None, "serverName": "computer-use", "mode": "form",
            "_meta": {"persist": ["always"]}, "message": f"Allow ChatGPT to use {app}?",
            "requestedSchema": {"type": "object", "properties": {}}}


def action_request(tool: str = "click") -> dict:
    return {"threadId": "thr", "turnId": "turn", "serverName": "computer-use", "mode": "form",
            "_meta": {"codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"]},
            "message": f"Allow the computer-use MCP server to run tool \"{tool}\"?",
            "requestedSchema": {"type": "object", "properties": {}}}


ELICIT = "mcpServer/elicitation/request"


class FakeClient:
    def __init__(self, owner: "FakeCodex"):
        self.owner = owner
        self._approval_handler: Callable[[str, dict | None], dict] | None = None
        self._proc = None
        self.starts: list = []
        self.resumes: list = []

    def thread_start(self, params):
        self.starts.append(params)
        return NS(thread=NS(id=f"thr-{len(self.starts)}"))

    def thread_resume(self, thread_id, params):
        self.resumes.append((thread_id, params))
        return NS(thread=NS(id=thread_id))

    def ask(self, method: str, params: dict) -> dict:
        """Wie der Lese-Thread des SDK: Server-Anfrage an den Handler, Antwort zurück an Codex."""
        out = self._approval_handler(method, params) if self._approval_handler else {}
        self.owner.answers.append((params.get("message"), out))
        return out


class FakeHandle:
    def __init__(self, client: FakeClient, items):
        self.client, self.items = client, items
        self.interrupted = threading.Event()

    def interrupt(self):
        self.interrupted.set()

    def stream(self) -> Iterator[NS]:
        script = FakeCodex.script or (lambda c, items: iter(done("OK")))
        yield from script(self.client, self.items)


class FakeThread:
    def __init__(self, client: FakeClient, id: str):
        self._client, self.id = client, id

    def turn(self, items, effort=None):
        return FakeHandle(self._client, items)


class FakeCodex:
    """Ersetzt `openai_codex.Codex`. `FakeCodex.script(client, items)` liefert die Ereignisse eines Zugs."""

    instances: list["FakeCodex"] = []
    script: Callable | None = None

    def __init__(self, cfg=None):
        self.cfg = cfg
        self.overrides = tuple(getattr(cfg, "config_overrides", ()) or ())
        self.env = dict(getattr(cfg, "env", None) or {})
        self._client = FakeClient(self)
        self.answers: list = []
        self.plain: list = []
        FakeCodex.instances.append(self)

    # Weg ohne Computer Use (SDK-Methoden mit approval_mode)
    def thread_start(self, **kw):
        self.plain.append(("start", kw))
        return FakeThread(self._client, f"thr-plain-{len(self.plain)}")

    def thread_resume(self, sid, **kw):
        self.plain.append(("resume", kw))
        return FakeThread(self._client, sid)

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def install() -> Callable[[], None]:
    """Ersetzt Codex und Thread im SDK; gibt eine Funktion zum Zurücksetzen zurück."""
    import openai_codex
    import openai_codex.api as api
    real = (openai_codex.Codex, api.Thread)
    openai_codex.Codex = FakeCodex
    api.Thread = FakeThread

    def restore():
        openai_codex.Codex, api.Thread = real
        FakeCodex.script = None
    return restore
