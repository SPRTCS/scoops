"""Agenten-Engine: eine Claude-Schleife mit Bot-Rechner, MCP-Servern und eigenen Werkzeugen.

Wird von Bots (Chat, Routinen) und der Kommandozeile genutzt. Der Bot-Rechner ist eine
geteilte Ressource: Ein Lauf belegt ihn erst beim ersten Bildschirm- oder Terminal-Befehl
und gibt ihn am Ende wieder frei.
"""

from __future__ import annotations

import base64
import re
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

import anthropic

from .computer import Computer, ComputerError, compact_image
from .config import UsageBook, anthropic_api_key
from .i18n import tx

DEFAULT_MODEL = "claude-haiku-5-5"
ESCALATION_MODEL = "claude-sonnet-5-5"
COMPUTER_URL = "http://127.0.0.1:18000"

BETAS = ["context-management-2025-06-27", "compact-2026-01-12"]
# Serverseitige Compaction (Beta compact-2026-01-12): Ab dieser Eingabegröße fasst die API ältere Teile des Laufs
# zusammen und liefert einen `compaction`-Block, der mit dem vollen response.content im Verlauf bleiben muss.
# Liegt unter dem Standard (150.000), weil jeder Schritt die ganze Eingabe kostet (Kostenbremse).
COMPACT_TRIGGER = 120_000
COMPACT_INSTRUCTIONS = (
    "Fasse den bisherigen Verlauf so zusammen, dass die Arbeit nahtlos weitergehen kann: Auftrag und Ziel, wichtige "
    "Fakten, Zwischenergebnisse, Dateien/IDs/Links, was erledigt ist und was als Nächstes kommt. Schreib die "
    "Zusammenfassung in <summary></summary>. Rufe dabei keine Werkzeuge auf, antworte nur mit Text.")
MAX_STEPS = 150  # Schrittgrenze eines Chat-Laufs (vorher 60); die Kostengrenze `budget` bremst zusätzlich
FALLBACK_BETA = "server-side-fallback-2026-07-01"
# Modelle mit serverseitigem Ausweichen bei Ablehnung (fallbacks: "default") und den neuen Web-Werkzeugen: laut
# Modellkatalog (Merkmale "fallback" und "web_new", models_catalog.json)
from . import models_catalog as _catalog  # noqa: E402

FALLBACK_MODELS = _catalog.LiveMap(lambda c: {m.id: True for m in c.models.values() if "fallback" in m.features})
WEB_NEW_MODELS = _catalog.LiveMap(lambda c: {m.id: True for m in c.models.values() if "web_new" in m.features})
MCP_BETA = "mcp-client-2025-11-20"
# Websuche/Web-Abruf: neue Varianten (mit Filterung) nur für Sonnet/Opus/Fable, Haiku nutzt die Basisvarianten.
WEB_TOOLS_NEW = [{"type": "web_search_20260209", "name": "web_search", "max_uses": 8},
                 {"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 8}]
WEB_TOOLS_BASIC = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 8},
                   {"type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 8}]

TERMINAL_TOOL = {
    "name": "terminal",
    "description": (
        "Führt einen Shell-Befehl (zsh) auf deinem macOS-Rechner aus und liefert stdout, stderr "
        "und Rückgabecode. Für Dateien, schnelle Abfragen oder Programme starten (z. B. "
        "`open -a Safari https://…`) oft schneller als Klicken."
    ),
    "input_schema": {
        "type": "object",
        "properties": {"command": {"type": "string", "description": "Der auszuführende Befehl"}},
        "required": ["command"],
        "additionalProperties": False,
    },
    "strict": True,
}

ESCALATE_TOOL = {
    "name": "eskalieren",
    "description": (
        "Übergibt die Aufgabe an ein stärkeres Modell, das mit dem bisherigen Verlauf weiterarbeitet. "
        "Nutze das, wenn die Aufgabe viele Schritte mit Abwägungen braucht, wenn du zweimal am selben "
        "Schritt gescheitert bist oder wenn du dir bei einem wichtigen Ergebnis unsicher bist. "
        "Nicht für einfache Abfragen."
    ),
    "input_schema": {
        "type": "object",
        "properties": {"grund": {"type": "string", "description": "Kurz, warum"}},
        "required": ["grund"],
        "additionalProperties": False,
    },
    "strict": True,
}

# Composio-Toolkits in Statuszeilen („Schaut in Gmail“); der Kalender hat eine eigene Zeile (mcp_line)
TOOLKIT_NAMES = {
    "GMAIL": "Gmail", "NOTION": "Notion", "GOOGLEDRIVE": "Google Drive",
    "GOOGLESHEETS": "Google Sheets", "SLACK": "Slack", "GITHUB": "GitHub", "LINEAR": "Linear", "TWITTER": "X",
}


@dataclass
class ExtraTool:
    """Eigenes Werkzeug, das der Server ausführt (Gedächtnis, Routinen, Freigaben …)."""

    schema: dict
    handler: Callable[[dict], str]
    status: Callable[[dict], str] | None = None


@dataclass
class Outcome:
    final_text: str
    stop_reason: str
    usage: UsageBook
    lines: list[str] = field(default_factory=list)
    used_computer: bool = False
    model_end: str = ""
    steps: int = 0
    transcript: list | None = None  # Verlauf des Laufs (zum Fortsetzen nach Abbruch, siehe bots.ResumeStore)


USER_HOLDER = "__user__"


class ComputerHub:
    """Ein Rechner (Bot-Rechner `vm` oder ein Scoops-Connect-Rechner). Belegung mit Sperre, Zustand für die App."""

    def __init__(self, url: str = COMPUTER_URL, node_id: str = "vm", name: str = "Bot-Rechner", transport=None):
        self.url = url
        self.node_id = node_id
        self.name = name
        self.transport = transport  # None = HTTP an `url` (Cua-Computer-Server)
        self._lock = threading.Lock()
        self.holder: str | None = None
        self.listeners: list[Callable[[dict], None]] = []
        self._computer: Computer | None = None
        self.user_seen = 0.0
        # Der Nutzer will übernehmen: Codex-Computer-Use-Läufe geben den Rechner zwischen zwei Aktionen frei (codex_cu.Gate)
        self.takeover_wanted = False

    @property
    def computer(self) -> Computer:
        if self._computer is None:
            self._computer = Computer(self.url, transport=self.transport) if self.transport else Computer(self.url)
        return self._computer

    @property
    def online(self) -> bool:
        return self.computer.transport.alive()

    @property
    def paused(self) -> bool:
        return bool(getattr(self.transport, "paused", False))

    def reset_screen(self) -> None:
        if self._computer is not None:
            self._computer._screen = None

    def _state_dict(self, alive: bool | None) -> dict:
        w, h = self.screen_size()
        base = {"node_id": self.node_id, "width": w, "height": h}
        if self.transport is not None:
            base["online"], base["paused"] = bool(self.transport.online), self.paused
        if self.holder == USER_HOLDER:
            return {"state": "user", "bot_id": None, **base}
        if self.holder:
            return {"state": "busy", "bot_id": self.holder, **base}
        if alive is None:
            alive = self.transport.online and not self.paused if self.transport is not None else True
        return {"state": "awake" if alive else "asleep", "bot_id": None, **base}

    def state(self) -> dict:
        if self.transport is not None:
            return self._state_dict(None)
        if self.holder:
            return self._state_dict(True)
        return self._state_dict(self.computer.transport.alive())

    def _notify(self) -> None:
        st = self._state_dict(None)
        for f in self.listeners:
            try:
                f(st)
            except Exception as e:  # noqa: BLE001
                print("Rechner-Listener-Fehler:", e, flush=True)

    def notify(self) -> None:
        self._notify()

    def expand_home(self, path: str) -> str:
        """`~` auf dem jeweiligen Rechner auflösen (VM: Benutzer lume)."""
        if not path.startswith("~"):
            return path
        if self.transport is None:
            return path.replace("~", "/Users/lume", 1)
        home = getattr(self, "_home", None)
        if not home:
            home = (self.computer.shell("printf %s \"$HOME\"").get("stdout") or "").strip() or "/Users/Shared"
            self._home = home
        return path.replace("~", home, 1)

    def acquire(self, holder: str, cancel: threading.Event | None = None) -> Computer:
        while True:
            if cancel and cancel.is_set():
                raise ComputerError(tx("Abgebrochen, während auf den Bot-Rechner gewartet wurde"))
            if self.takeover_wanted:  # der Nutzer will übernehmen: er ist vor wartenden Scoops dran
                time.sleep(0.1)
                continue
            if self._lock.acquire(timeout=0.5):
                break
        self.holder = holder
        self._notify()
        return self.computer

    def release(self) -> None:
        self.holder = None
        try:
            self._lock.release()
        except RuntimeError:
            pass
        self._notify()

    # -- Übernehmen durch Arman ---------------------------------------
    def take_over(self, timeout: float = 15) -> bool:
        """Arman übernimmt den Rechner. Laufende Scoops warten, bis er zurückgibt."""
        if self.holder == USER_HOLDER:
            self.user_seen = time.time()
            return True
        self.takeover_wanted = True
        try:
            if not self._lock.acquire(timeout=timeout):
                return False
        finally:
            self.takeover_wanted = False
        self.holder = USER_HOLDER
        self.user_seen = time.time()
        self._notify()
        return True

    def give_back(self) -> None:
        if self.holder == USER_HOLDER:
            self.release()

    def release_if_idle(self, idle: float = 600) -> None:
        if self.holder == USER_HOLDER and time.time() - self.user_seen > idle:
            self.release()

    def screen_size(self) -> tuple[int, int]:
        hint = getattr(self.transport, "screen", None) if self.transport is not None else None
        if hint:
            return int(hint["width"]), int(hint["height"])
        if self.transport is not None and not self.transport.online:
            return 1024, 768
        try:
            s = self.computer.screen
            return s.width, s.height
        except Exception:  # noqa: BLE001
            return 1024, 768


def block_dict(b) -> dict:
    """Antwortblock → Parameter-Dict (für gespeicherte Verläufe). Compaction-Blöcke behalten `content` auch als null."""
    if isinstance(b, dict):
        return b
    d = b.to_dict(exclude_none=True) if hasattr(b, "to_dict") else dict(b)
    if d.get("type") == "compaction":
        d.setdefault("content", None)
    return d


def plain_messages(messages: list[dict]) -> list[dict]:
    """Verlauf mit SDK-Objekten → reines JSON (Liste von {role, content}); Inhalt unverändert."""
    out = []
    for m in messages:
        c = m["content"]
        out.append({"role": m["role"], "content": c if isinstance(c, str) else [block_dict(b) for b in c]})
    return out


def _compaction_index(messages: list[dict]) -> int | None:
    """Index der letzten Assistenten-Nachricht mit Compaction-Block (davor verwirft die API ohnehin alles)."""
    for i in range(len(messages) - 1, -1, -1):
        m = messages[i]
        if m["role"] != "assistant" or isinstance(m["content"], str):
            continue
        if any((b.get("type") if isinstance(b, dict) else getattr(b, "type", None)) == "compaction" for b in m["content"]):
            return i
    return None


def img_block(data: bytes, media_type: str = "image/png") -> dict:
    return {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": base64.b64encode(data).decode()}}


def status_line(name: str, inp: dict) -> str:
    """Freundliche Statuszeile statt Werkzeugname."""
    if name == "screenshot":
        return tx("Schaut auf den Bildschirm")
    if name == "zoom":
        return tx("Schaut genauer hin")
    if name in ("left_click", "double_click", "triple_click", "right_click", "middle_click"):
        return tx("Klickt")
    if name == "type":
        t = inp.get("text", "")
        return tx("Tippt „{text}“", text=f"{t[:40]}{'…' if len(t) > 40 else ''}")
    if name == "key":
        return tx("Drückt {key}", key=inp.get("text"))
    if name == "scroll":
        return tx("Scrollt")
    if name in ("left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position"):
        return tx("Bewegt die Maus")
    if name == "terminal":
        cmd = inp.get("command", "")
        if cmd.startswith("open "):
            return tx("Öffnet ein Programm")
        return tx("Arbeitet im Terminal")
    if name == "wait" or name == "hold_key":
        return tx("Wartet kurz")
    if name == "eskalieren":
        return tx("Holt sich Verstärkung")
    return name


# Antwort, die eine Handlung ankündigt („ich schaue jetzt nach“, „ich melde mich, sobald …“), ohne ein Werkzeug
# aufzurufen: Der Lauf wäre damit zu Ende und niemand täte etwas. Kleine Modelle machen das oft.
_ANNOUNCE = re.compile(
    r"\bich\s+(?:schaue?|sehe|gucke?|prüfe|checke|teste|probiere|versuche|suche|hole|lese|öffne|starte|mache|"
    r"kümmere\s+mich|poste|schicke|sende|logge|melde\s+mich|wechsle|klicke|nehme|recherchiere|frage)\b"
    r"[^.!?\n]{0,60}?(?<!\bab\s)(?<!\bvon\s)\b(?:jetzt|gleich|sofort|direkt|gerade|kurz|als\s+nächstes|nun)\b"
    r"|(?<!\bab\s)(?<!\bvon\s)\b(?:jetzt|gleich|sofort|direkt|kurz)\s+(?:schaue|prüfe|teste|suche|hole|öffne|starte|mache|poste|logge)\s+ich\b"
    r"|\bich\s+melde\s+mich,?\s+(?:sobald|wenn)\b"
    r"|\bdafür\s+(?:nehme|mache|öffne)\s+ich\b",
    re.IGNORECASE)
NUDGE = ("[System, nicht vom Nutzer] Du hast gerade angekündigt, etwas zu tun, aber kein Werkzeug aufgerufen. "
         "Dein Zug endet sonst hier und nichts passiert. Tu es jetzt mit deinen Werkzeugen. Wenn du es nicht "
         "kannst oder erst eine Antwort von Arman brauchst, sag das klar in einem Satz, ohne erneut etwas anzukündigen. "
         "Ist nichts offen (schon erledigt, oder du hast nur beschrieben, wie du es künftig machst), antworte nur mit OK. "
         "Inhalte aus deiner Antwort davor wiederholst du nicht, die bleiben stehen.")
MAX_NUDGES = 2
# Antworten vor einem Nachhaken bleiben stehen, wenn sie mehr sind als die bloße Ankündigung (z. B. ein ganzer Digest,
# der nebenbei „ab jetzt prüfe ich …“ sagt). Sonst ersetzte die Antwort aufs Nachhaken den eigentlichen Inhalt.
NUDGE_KEEP = 280
_ANNOUNCE_TAIL = 400  # Ankündigungen stehen am Ende; ein langer Text davor ist Inhalt, keine Ankündigung
# Weiche Abgabe an den Aufgabenmodus (1.22): Hat ein Chat-Lauf schon viele Werkzeug-/Bildschirmschritte gemacht und gibt es
# `aufgabe_starten`, bekommt der Scoop einmal den Hinweis, den Rest als Hintergrund-Aufgabe abzugeben. Keine Zwangsumleitung.
HANDOFF_AFTER = 12
HANDOFF_HINT = ("[System, nicht vom Nutzer] Du hast in diesem Chat-Lauf schon {n} Werkzeug- bzw. Bildschirmschritte gemacht. "
                "Sind noch mehrere Schritte übrig, gib den Rest jetzt mit `aufgabe_starten` als Hintergrund-Aufgabe ab: Auftrag "
                "mit allem Nötigen und dem bisherigen Stand (was erledigt ist, wo du stehst, was noch fehlt), dann sag Arman in "
                "einem Satz Bescheid. Ist es in ein, zwei Schritten fertig, mach es hier zu Ende.")


def handoff_due(steps: int, tool_names, handed_off: bool, hinted: bool) -> bool:
    """True, wenn der Lauf jetzt (einmalig) den Abgabe-Hinweis bekommen soll."""
    return not hinted and not handed_off and steps >= HANDOFF_AFTER and "aufgabe_starten" in tool_names


def hands_off(tool_name: str) -> bool:
    """Werkzeuge, nach denen „ich melde mich, sobald …“ stimmt: Freigabe, Hintergrund-Aufgabe, Erinnerung, Routine."""
    n = (tool_name or "").lower()
    return any(k in n for k in ("freigabe", "aufgabe_starten", "aufgabe_fortsetzen", "erinnerung", "routine", "eskalieren"))


def announces_action(text: str) -> bool:
    """True, wenn die (Schluss-)Antwort eine Handlung ankündigt, statt sie zu tun oder Arman etwas zu fragen."""
    t = (text or "").strip()
    if not t or t.endswith("?"):
        return False
    return bool(_ANNOUNCE.search(t[-_ANNOUNCE_TAIL:]))


def after_nudges(before: list[str], final: str) -> str:
    """Schlussantwort nach einem oder mehreren Nachhaken: Inhalt aus den Antworten davor bleibt erhalten, bloße
    Ankündigungen fallen weg, ein „OK“ (nichts offen) zählt nicht als eigene Antwort."""
    if not before:
        return final
    kept = [t.strip() for t in before if len((t or "").strip()) > NUDGE_KEEP]
    f = (final or "").strip()
    if re.fullmatch(r"ok[.!]?", f, re.IGNORECASE):
        parts = kept or [b.strip() for b in before[-1:]]
    else:
        parts = kept + ([f] if f else [])
    return "\n\n".join(p for p in parts if p) or final


def mcp_line(server: str, name: str, inp: dict) -> str:
    if server == "teamapp":
        return tx("Fragt die Team App")
    from .mcp_client import LABELS
    if server in LABELS:  # eigene MCP-Server (custom_mcp.py)
        return tx("Nutzt {app}", app=LABELS[server])
    if name == "COMPOSIO_SEARCH_TOOLS":
        return tx("Sucht das passende Werkzeug")
    if name == "COMPOSIO_MANAGE_CONNECTIONS":
        return tx("Prüft die Verbindungen")
    slugs = []
    for t in (inp or {}).get("tools", []) or []:
        slug = t.get("tool_slug") or t.get("slug") or ""
        if slug:
            slugs.append(slug)
    for s in slugs:
        prefix = s.split("_", 1)[0]
        if prefix == "GOOGLECALENDAR":
            return tx("Schaut in deinen Kalender")
        if prefix in TOOLKIT_NAMES:
            return tx("Schaut in {app}", app=TOOLKIT_NAMES[prefix])
    if name == "COMPOSIO_REMOTE_WORKBENCH" or name == "COMPOSIO_REMOTE_BASH_TOOL":
        return tx("Wertet Daten aus")
    return tx("Nutzt eine verbundene App")


class Engine:
    def __init__(self, hub: ComputerHub, client: anthropic.Anthropic | None = None):
        self.hub = hub
        self._fixed_client = client
        self._client: anthropic.Anthropic | None = None
        self._client_key: str | None = None
        self._key_checked = 0.0

    @property
    def client(self) -> anthropic.Anthropic:
        """Anthropic-Client, erst bei Bedarf erzeugt. Der Schlüssel wird höchstens jede Minute neu gelesen,
        damit ein in der Einrichtung neu gesetzter Schlüssel ohne Neustart greift (und der Server auch ohne
        Schlüssel startet – Läufe melden dann einen klaren Fehler)."""
        if self._fixed_client is not None:
            return self._fixed_client
        if self._client is None or time.time() - self._key_checked > 60:
            key = anthropic_api_key()
            self._key_checked = time.time()
            if self._client is None or key != self._client_key:
                self._client, self._client_key = anthropic.Anthropic(api_key=key), key
        return self._client

    # -- Bildschirm-Aktionen ----------------------------------------------
    @staticmethod
    def _exec_computer(c: Computer, name: str, inp: dict) -> list[dict] | str:
        # Große Bilder als JPEG (computer.compact_image): sonst sprengt eine volle Webseite die 1-MB-Zeilen des Agent SDK
        if name == "screenshot":
            return [img_block(*compact_image(c.screenshot_png()))]
        if name == "zoom":
            return [img_block(*compact_image(c.zoom_png(inp["region"])))]
        if name in ("left_click", "right_click", "middle_click", "double_click", "triple_click"):
            c.click(name, inp.get("coordinate"), inp.get("text"))
        elif name == "left_click_drag":
            c.drag(inp["start_coordinate"], inp["coordinate"], inp.get("text"))
        elif name == "mouse_move":
            c.move(*inp["coordinate"])
        elif name == "left_mouse_down":
            c.mouse_down()
        elif name == "left_mouse_up":
            c.mouse_up()
        elif name == "cursor_position":
            x, y = c.cursor_position()
            return f"[{x}, {y}]"
        elif name == "scroll":
            c.scroll(inp["scroll_direction"], inp.get("scroll_amount", 3), inp.get("coordinate"), inp.get("text"))
        elif name == "type":
            c.type_text(inp["text"])
        elif name == "key":
            c.key(inp["text"], inp.get("repeat", 1))
        elif name == "hold_key":
            c.hold_key(inp["text"], inp.get("duration", 1))
        elif name == "wait":
            time.sleep(min(float(inp.get("duration", 1)), 30))
        else:
            raise ComputerError(f"Aktion {name} wird nicht unterstützt")
        time.sleep(0.4)
        return "OK"

    @staticmethod
    def _exec_terminal(c: Computer, inp: dict) -> str:
        """Eingebautes `terminal` (Gäste geteilter Scoops): einzelner Befehl, gekürzt mit Hinweis statt still."""
        d = c.shell(inp["command"])
        out, err = d.get("stdout") or "", d.get("stderr") or ""
        if len(out) > 6000:
            out = f"[… {len(out) - 6000} Zeichen am Anfang ausgelassen]\n" + out[-6000:]
        if len(err) > 2000:
            err = f"[… {len(err) - 2000} Zeichen am Anfang ausgelassen]\n" + err[-2000:]
        return f"Rückgabecode {d.get('return_code')}\nstdout:\n{out}\nstderr:\n{err}"

    # -- Schleife ----------------------------------------------------------
    def run(
        self,
        *,
        system: str | list[dict],
        messages: list[dict],
        model: str = DEFAULT_MODEL,
        escalation_model: str | None = ESCALATION_MODEL,
        effort: str = "medium",
        extra_tools: list[ExtraTool] | None = None,
        mcp_servers: list[dict] | None = None,
        mcp_hub=None,
        work_effort: str | None = None,
        budget: float = 1.0,
        max_steps: int = MAX_STEPS,
        holder: str = "cli",
        on_line: Callable[[str], None] | None = None,
        on_text: Callable[[str], None] | None = None,
        on_screenshot: Callable[[int, str, bytes], None] | None = None,
        cancel: threading.Event | None = None,
        hub: ComputerHub | None = None,
        allow_computer: bool = True,
        allow_web: bool = True,
        checkpoint: Callable[[list], None] | None = None,
        compact_trigger: int | None = COMPACT_TRIGGER,
    ) -> Outcome:
        """`allow_computer`/`allow_web`: Läufe für Gäste geteilter Scoops bekommen nur freigegebene Werkzeuge.
        `checkpoint(messages)` wird nach jedem Schritt mit dem aktuellen Verlauf aufgerufen (Fortsetzen nach Abbruch).
        `compact_trigger`: Eingabegröße für die serverseitige Compaction (None = aus)."""
        hub = hub or self.hub  # Rechner des Scoops (Standard: Bot-Rechner)
        extra = {t.schema["name"]: t for t in (extra_tools or [])}
        mcp_servers = mcp_servers or []
        # Eigene MCP-Verbindungen: Werkzeuglisten einmal holen, nicht bei jeder Anfrage (spart ~5 s).
        hub_tools = mcp_hub.tool_schemas() if mcp_hub else []
        usage = UsageBook()
        lines: list[str] = []
        computer: Computer | None = None
        used_computer = False
        escalation = escalation_model if escalation_model and escalation_model != model else None

        def line(s: str) -> None:
            if not s:  # Kleinigkeiten (z. B. „reagieren“) erscheinen nicht als Arbeitsschritt
                return
            lines.append(s)
            if on_line:
                on_line(s)

        def get_computer() -> Computer:
            nonlocal computer, used_computer
            if computer is None:
                if hub.holder and hub.holder != holder:
                    line(tx("Wartet, bis der Rechner frei ist"))
                computer = hub.acquire(holder, cancel)
                used_computer = True
            return computer

        final_text, stop_reason, step = "", "", 0
        nudges, handed_off, nudged = 0, False, []
        tool_steps, hinted = 0, False
        try:
            while step < max_steps:
                if cancel and cancel.is_set():
                    stop_reason, final_text = "stopped", ""
                    break
                step += 1
                # Eigenes `terminal` (persistente Shell mit Rechte-Prüfung, computer_tools.py) ersetzt das eingebaute
                tools: list[dict] = ([{"type": "computer_toolset_20260801"}]
                                     + ([] if "terminal" in extra else [TERMINAL_TOOL])) if allow_computer else []
                tools += [t.schema for t in extra.values()]
                if allow_web:
                    tools += WEB_TOOLS_NEW if model in WEB_NEW_MODELS else WEB_TOOLS_BASIC
                if escalation:
                    tools.append(ESCALATE_TOOL)
                kwargs: dict = {}
                betas = list(BETAS)
                edits: list[dict] = [{"type": "clear_tool_uses_20250919"}]
                if compact_trigger:
                    edits.append({"type": "compact_20260112", "trigger": {"type": "input_tokens", "value": compact_trigger},
                                  "instructions": COMPACT_INSTRUCTIONS})
                else:
                    betas.remove("compact-2026-01-12")
                if model in FALLBACK_MODELS:
                    betas.append(FALLBACK_BETA)
                    kwargs["fallbacks"] = "default"
                if hub_tools:
                    tools.append({"type": "tool_search_tool_bm25_20251119", "name": "tool_search_tool_bm25"})
                    tools += hub_tools
                if mcp_servers:
                    if not hub_tools:
                        tools.append({"type": "tool_search_tool_bm25_20251119", "name": "tool_search_tool_bm25"})
                    for m in mcp_servers:
                        entry = {"type": "mcp_toolset", "mcp_server_name": m["name"], "default_config": {"defer_loading": True}}
                        if m.get("always_loaded"):
                            entry["configs"] = {t: {"defer_loading": False} for t in m["always_loaded"]}
                        tools.append(entry)
                    kwargs["mcp_servers"] = [{k: v for k, v in m.items() if k != "always_loaded"} for m in mcp_servers]
                    betas.append(MCP_BETA)

                response = self.client.beta.messages.create(
                    model=model,
                    max_tokens=16000,
                    system=system,
                    tools=tools,
                    messages=messages,
                    thinking={"type": "adaptive", "display": "summarized"},
                    output_config={"effort": effort},
                    cache_control={"type": "ephemeral"},
                    context_management={"edits": edits},
                    betas=betas,
                    **kwargs,
                )
                usage.add(model, response.usage)
                stop_reason = response.stop_reason or ""

                for b in response.content:
                    if b.type == "mcp_tool_use":
                        line(mcp_line(b.server_name, b.name, b.input))
                    elif b.type == "server_tool_use" and b.name == "web_search":
                        q = (b.input or {}).get("query", "")
                        line(tx("Sucht im Web: {query}", query=q[:50]) if q else tx("Sucht im Web"))
                    elif b.type == "server_tool_use" and b.name == "web_fetch":
                        line(tx("Liest eine Webseite"))
                    elif b.type == "text" and b.text.strip() and on_text:
                        on_text(b.text.strip())

                messages.append({"role": "assistant", "content": response.content})
                if any(b.type == "compaction" for b in response.content):
                    line(tx("Fasst den bisherigen Verlauf zusammen"))
                    cut = _compaction_index(messages)
                    if cut:  # alles davor verwirft die API ohnehin; hält auch gespeicherte Verläufe klein
                        del messages[:cut]
                if checkpoint:
                    checkpoint(messages)

                if stop_reason == "pause_turn":
                    continue
                tool_uses = [b for b in response.content if b.type == "tool_use"]
                if tool_uses and work_effort and effort != work_effort:
                    effort = work_effort  # erst schnell antworten, beim Arbeiten gründlicher denken
                if stop_reason != "tool_use" or not tool_uses:
                    final_text = "\n\n".join(b.text.strip() for b in response.content if b.type == "text" and b.text.strip())
                    if (stop_reason == "end_turn" and nudges < MAX_NUDGES and not handed_off
                            and announces_action(final_text)):
                        nudges += 1
                        nudged.append(final_text)
                        messages.append({"role": "user", "content": [{"type": "text", "text": NUDGE}]})
                        continue
                    final_text = after_nudges(nudged, final_text)
                    break

                handed_off = handed_off or any(hands_off(tu.name) for tu in tool_uses)
                results, failed = [], False
                for tu in tool_uses:
                    toolset = getattr(tu, "toolset_name", None)
                    ex = extra.get(tu.name)
                    is_mcp = bool(mcp_hub and mcp_hub.owns(tu.name))
                    if ex and ex.status:
                        line(ex.status(tu.input))
                    elif is_mcp:
                        srv, _, tname = tu.name.partition("__")
                        line(mcp_line(srv, tname, tu.input))
                    elif not ex:
                        line(status_line(tu.name, tu.input))
                    result: dict = {"type": "tool_result", "tool_use_id": tu.id}
                    if toolset:
                        result["toolset_name"] = toolset
                    if failed:
                        result.update(content="Not executed: an earlier action in this turn failed.", is_error=True)
                        results.append(result)
                        continue
                    try:
                        if not allow_computer and (toolset == "computer" or tu.name == "terminal"):
                            out = "Fehler: Der Rechner ist in diesem Lauf nicht freigegeben."
                        elif toolset == "computer":
                            out = self._exec_computer(get_computer(), tu.name, tu.input)
                        elif tu.name == "terminal" and not ex:
                            out = self._exec_terminal(get_computer(), tu.input)
                        elif tu.name == "eskalieren" and escalation:
                            model, escalation = escalation, None
                            out = f"Übergeben. Du bist jetzt {model} und arbeitest mit dem bisherigen Verlauf weiter."
                        elif ex:
                            out = ex.handler(tu.input)
                        elif is_mcp:
                            out = mcp_hub.call(tu.name, tu.input)
                        else:
                            raise ComputerError(f"Unbekanntes Werkzeug {tu.name}")
                        if isinstance(out, list) and on_screenshot and toolset == "computer":
                            on_screenshot(step, tu.name, base64.b64decode(out[0]["source"]["data"]))
                        result["content"] = out if isinstance(out, list) else [{"type": "text", "text": str(out)}]
                    except Exception as e:  # noqa: BLE001 - Fehler gehen an Claude zurück
                        print(f"Werkzeugfehler {tu.name}: {str(e)[:300]}", flush=True)
                        failed = True
                        result.update(content=f"Fehler: {e}", is_error=True)
                    results.append(result)
                tool_steps += len(tool_uses)
                if handoff_due(tool_steps, extra, handed_off, hinted):
                    hinted = True
                    results.append({"type": "text", "text": HANDOFF_HINT.format(n=tool_steps)})
                messages.append({"role": "user", "content": results})
                if checkpoint:
                    checkpoint(messages)

                if usage.dollars >= budget:
                    final_text = tx("Ich habe abgebrochen, weil die Kostengrenze von {budget:.2f} $ für diese Aufgabe "
                                    "erreicht ist.", budget=budget)
                    stop_reason = "budget"
                    break
            else:
                final_text = tx("Ich habe nach {steps} Schritten abgebrochen.", steps=max_steps)
                stop_reason = "max_steps"
        finally:
            if computer is not None:
                hub.release()
        return Outcome(final_text, stop_reason, usage, lines, used_computer, model, step, messages)
