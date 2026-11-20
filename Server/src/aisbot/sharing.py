"""Geteilte Scoops (docs/sharing.md): Wer darf was – Prinzipal, Share-Cache, Gast-Ansichten, Werkzeug-Richtlinie.

Grundsatz **Standard verweigern**: Ein Gast (gültiges Sitzungs-JWT eines anderen Kontos) darf nur Endpunkte, die in
server.py ausdrücklich mit `shared(...)` markiert sind, und nur für Scoops, für die ihm der Cache einen Share zeigt.
Der Cache kommt von AIS Scoops Cloud (`POST /shares/sync`) und wird neu geladen, sobald der Herzschlag eine neue
`sharesVersion` meldet (≤ 60 s) – zusätzlich sofort, wenn die Admin-App `POST /api/shares/refresh` ruft, und gedrosselt,
wenn ein Gast einen Scoop anfragt, den der Cache (noch) nicht kennt (gerade angenommen).
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field, replace
from typing import Callable

import httpx

from .i18n import N_, translate, tx

ROLE_RANK = {"read": 1, "write": 2, "edit": 3}
COMPUTER_RANK = {"none": 0, "view": 1, "control": 2}
ROLE_LABEL = {"read": N_("Lesen"), "write": N_("Schreiben"), "edit": N_("Bearbeiten"), "admin": N_("Admin")}  # deutsch (Prompts)
MISS_REFRESH_EVERY = 5.0   # höchstens so oft neu laden, wenn ein Gast etwas Unbekanntes anfragt
SYNC_TIMEOUT = 10.0

def role_label(role: str) -> str:
    """Beschriftung einer Rolle in der aktuellen Sprache (Fehlermeldungen, Ansichten); Prompts nehmen ROLE_LABEL."""
    return translate(ROLE_LABEL.get(role, role))


# „Werkzeuge für Geteilte“ (pro Scoop, Admin-Einstellung). Standard: nur Websuche und Antworten.
DEFAULT_GUEST_TOOLS = {"web": True, "computer": False, "apps": [], "mcp": [], "phone": False, "mail": False}
DEFAULT_GUEST_BUDGET = 2.0  # US-Dollar pro Gast und Tag (Europe/Berlin)
MAX_GUEST_BUDGET = 100.0
# Scoop-Felder, die die Rolle „Bearbeiten“ ändern darf (Modell, Rechner, Teilen, Löschen bleiben beim Admin)
GUEST_EDITABLE = {"name", "label", "mascot", "character", "voice"}


def normalize_tools(d: dict | None) -> dict:
    """Nur bekannte Schlüssel mit passendem Typ; Unbekanntes fällt weg (nie mehr Rechte als ausdrücklich gesetzt)."""
    out = {**DEFAULT_GUEST_TOOLS, "apps": [], "mcp": []}
    if not isinstance(d, dict):
        return out
    for k in ("web", "computer", "phone", "mail"):
        if k in d:
            out[k] = bool(d[k])
    for k in ("apps", "mcp"):
        v = d.get(k)
        if isinstance(v, list):
            out[k] = sorted({str(x).strip().lower()[:60] for x in v if isinstance(x, str) and str(x).strip()})[:50]
    return out


def normalize_budget(v) -> float:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return DEFAULT_GUEST_BUDGET
    if f != f or f < 0:
        return DEFAULT_GUEST_BUDGET
    return round(min(f, MAX_GUEST_BUDGET), 2)


@dataclass(frozen=True)
class Share:
    share_id: str
    bot_id: str
    user_id: str
    name: str
    role: str  # read | write | edit
    computer: str  # none | view | control
    created_at: float = 0

    def allows(self, role: str = "read", computer: str | None = None) -> bool:
        if ROLE_RANK.get(self.role, 0) < ROLE_RANK[role]:
            return False
        if computer and COMPUTER_RANK.get(self.computer, 0) < COMPUTER_RANK[computer]:
            return False
        return True

    def public(self) -> dict:
        return {"share_id": self.share_id, "user_id": self.user_id, "name": self.name, "role": self.role,
                "computer": self.computer}


@dataclass(frozen=True)
class Principal:
    """Wer fragt: der Inhaber (API-Token oder sein Sitzungs-JWT) oder ein Gast (Sitzungs-JWT eines anderen Kontos)."""

    kind: str  # owner | guest
    user_id: str | None = None
    sid: str | None = None
    share: Share | None = field(default=None, compare=False)  # vom Endpunkt geprüfter Share (nur Gäste)

    @property
    def is_owner(self) -> bool:
        return self.kind == "owner"

    def with_share(self, share: Share | None) -> "Principal":
        return replace(self, share=share)


OWNER = Principal("owner")


class ShareCache:
    """Alle Shares dieses Servers (aus Convex). Threadsicher; ohne Kopplung leer (dann gibt es keine Gäste)."""

    def __init__(self, cloud, bot_info: Callable[[list[str]], list[dict]] | None = None) -> None:
        self.cloud = cloud
        self.bot_info = bot_info  # bot_ids → [{botId, name, mascot}] (Namen in Convex aktuell halten)
        self._lock = threading.Lock()
        self._sync_lock = threading.Lock()
        self.version: int | None = None
        self.shares: list[Share] = []
        self.synced_at = 0.0
        self.last_error: str | None = None
        self._miss_at = 0.0
        self._removed_bots: set[str] = set()
        self.on_change: Callable[[set[str], set[str]], None] | None = None  # (betroffene Gäste, betroffene Scoops)

    # Abfragen
    def share(self, user_id: str | None, bot_id: str | None, *, refresh_on_miss: bool = True) -> Share | None:
        if not user_id or not bot_id:
            return None
        s = self._find(user_id, bot_id)
        if s is None and refresh_on_miss and self._may_refresh():
            self.sync()
            s = self._find(user_id, bot_id)
        return s

    def _find(self, user_id: str, bot_id: str) -> Share | None:
        with self._lock:
            return next((s for s in self.shares if s.user_id == user_id and s.bot_id == bot_id), None)

    def for_user(self, user_id: str | None, *, refresh_on_miss: bool = True) -> list[Share]:
        if not user_id:
            return []
        with self._lock:
            out = [s for s in self.shares if s.user_id == user_id]
        if not out and refresh_on_miss and self._may_refresh():
            self.sync()
            with self._lock:
                out = [s for s in self.shares if s.user_id == user_id]
        return out

    def for_bot(self, bot_id: str) -> list[Share]:
        with self._lock:
            return [s for s in self.shares if s.bot_id == bot_id]

    def guests_of(self, bot_id: str) -> list[str]:
        return [s.user_id for s in self.for_bot(bot_id)]

    def name_of(self, user_id: str) -> str:
        with self._lock:
            return next((s.name for s in self.shares if s.user_id == user_id and s.name), "") or "Gast"

    def shared_bot_ids(self) -> set[str]:
        with self._lock:
            return {s.bot_id for s in self.shares}

    def _may_refresh(self) -> bool:
        if not self.cloud.owner_id():
            return False
        now = time.time()
        with self._lock:
            if now - self._miss_at < MISS_REFRESH_EVERY:
                return False
            self._miss_at = now
        return True

    # Laden
    def bot_removed(self, bot_id: str) -> None:
        """Scoop gelöscht: lokal sofort sperren und beim nächsten Abgleich in Convex aufräumen lassen."""
        with self._lock:
            before = self.shares
            had = any(s.bot_id == bot_id for s in before)
            self.shares = [s for s in before if s.bot_id != bot_id]
            if had:
                self._removed_bots.add(bot_id)
        if had:
            self._changed(before, self.shares)
            threading.Thread(target=self.sync, daemon=True, name="shares-sync").start()

    def on_heartbeat(self, data: dict) -> None:
        v = data.get("sharesVersion")
        if isinstance(v, (int, float)) and (self.version is None or int(v) != self.version):
            threading.Thread(target=self.sync, daemon=True, name="shares-sync").start()

    def clear(self) -> None:
        with self._lock:
            before = self.shares
            self.shares, self.version = [], None
        self._changed(before, [])

    def sync(self) -> bool:
        """Lädt alle Shares (blockierend, höchstens SYNC_TIMEOUT). False bei Fehler (alter Stand bleibt)."""
        from . import cloud as cloud_mod

        if not self.cloud.owner_id():
            self.clear()
            return False
        secret = cloud_mod.get_secret()
        if not secret:
            return False
        with self._sync_lock:
            with self._lock:
                removed = sorted(self._removed_bots)
                bots = sorted({s.bot_id for s in self.shares})
            body: dict = {}
            if removed:
                body["removeBots"] = removed
            if self.bot_info and bots:
                try:
                    body["bots"] = self.bot_info(bots)
                except Exception:  # noqa: BLE001
                    pass
            try:
                r = httpx.post(self.cloud.url() + "/shares/sync", json=body, timeout=SYNC_TIMEOUT,
                               headers={"Authorization": f"Bearer {secret}"})
                data = r.json() if r.content else {}
            except Exception as e:  # noqa: BLE001
                self.last_error = tx("Shares laden: {error}", error=e)
                print("Geteilte Scoops:", self.last_error, flush=True)
                return False
            if r.status_code != 200 or not isinstance(data, dict):
                self.last_error = tx("Shares laden: {error}", error=f"HTTP {r.status_code} "
                                     f"{data.get('code', '') if isinstance(data, dict) else ''}")
                print("Geteilte Scoops:", self.last_error, flush=True)
                if r.status_code == 401:
                    self.clear()
                return False
            fresh = []
            for x in data.get("shares") or []:
                try:
                    if x["role"] not in ROLE_RANK or x["computer"] not in COMPUTER_RANK:
                        continue
                    fresh.append(Share(str(x["shareId"]), str(x["botId"]), str(x["granteeId"]),
                                       str(x.get("granteeName") or "Gast")[:80], x["role"], x["computer"],
                                       float(x.get("createdAt") or 0)))
                except (KeyError, TypeError):
                    continue
            with self._lock:
                before = self.shares
                self.shares = fresh
                self.version = int(data.get("sharesVersion") or 0)
                self.synced_at = time.time()
                self._removed_bots -= set(removed)
            self.last_error = None
        self._changed(before, fresh)
        return True

    def _changed(self, before: list[Share], after: list[Share]) -> None:
        if set(before) == set(after) or not self.on_change:
            return
        diff = set(before) ^ set(after)
        try:
            self.on_change({s.user_id for s in diff}, {s.bot_id for s in diff})
        except Exception as e:  # noqa: BLE001
            print("Geteilte Scoops: on_change-Fehler:", e, flush=True)


# -- Gast-Ansichten ------------------------------------------------------------------------------
_BOT_KEYS = ("id", "name", "label", "mascot", "avatar", "character", "voice", "created_at", "busy")


def guest_bot(b: dict, share: Share, *, owner_name: str, server_name: str, owner_id: str | None,
              unread: int, last_message: dict | None) -> dict:
    """Scoop-JSON für einen Gast: ohne Modell, Freigaben, Teilen-Daten; Rechner nur mit Stufe view/control."""
    out = {k: b.get(k) for k in _BOT_KEYS}
    out["unread"] = unread
    out["last_message"] = last_message
    out["pinned"], out["section"], out["primary"] = False, None, False
    if share.computer != "none":
        out["computer_node"] = b.get("computer_node")
    out["access"] = {"share_id": share.share_id, "role": share.role, "computer": share.computer,
                    "owner_id": owner_id, "owner_name": owner_name, "server_name": server_name}
    return out


def guest_message(m: dict, share: Share, owner_name: str) -> dict:
    """Nachricht für einen Gast: Freigaben nur als „Wartet auf Freigabe durch <Admin>“, keine internen Hinweise,
    Rechner-Details nur mit Rechner-Stufe."""
    meta = dict(m.get("meta") or {})
    role = m.get("role")
    for k in ("prompt", "url", "t3_thread_id", "cost_usd", "run_info", "scoop_update"):
        meta.pop(k, None)
    text = m.get("text") or ""
    if role == "approval":
        state = meta.get("state") or "pending"
        title = {"pending": tx("Wartet auf Freigabe durch {name}", name=owner_name),
                 "approved": tx("Freigegeben durch {name}", name=owner_name),
                 "declined": tx("Abgelehnt durch {name}", name=owner_name)}.get(
            state, tx("Freigabe durch {name}", name=owner_name))
        meta = {k: meta[k] for k in ("author_id",) if k in meta} | {"state": state, "title": title, "details": "",
                                                                       "guest_view": True}
        text = ""
    elif role == "status" and share.computer == "none" and meta.get("uses_computer"):
        meta["lines"] = [tx("Arbeitet am Rechner")]
    return {**m, "text": text, "meta": meta}


# -- Werkzeuge in Gast-Läufen --------------------------------------------------------------------
# Eigene Server-Werkzeuge (bots._tools), die Gast-Läufe immer bekommen: Antworten, Reagieren, Bibliothek dieses
# Chats, Fähigkeit lesen, Freigabe beim Admin anfragen. Alles andere nur über „Werkzeuge für Geteilte“ – Tresor,
# Logins, Routinen, andere Scoops anschreiben, T3, Anrufprotokolle nie.
GUEST_BASE_TOOLS = {"merken", "reagieren", "datei_speichern", "dateien_auflisten", "datei_lesen", "datei_zeigen", "link_merken",
                    "faehigkeit_lesen", "freigabe_anfordern"}
GUEST_TOOL_GROUPS = {"mail": {"mail_vorbereiten"}, "computer": {"datei_vom_rechner", "datei_auf_rechner"},
                     "phone": {"anrufen"}}
# Nie in Gast-Läufen, auch nicht über „Werkzeuge für Geteilte“: Armans private Apple-Daten (Erinnerungen, Kalender,
# Kontakte über seinen Mac; Home, Wecker, Standort über sein iPhone). Tauchen deshalb auch nicht im Auswahlkatalog
# für Gäste auf.
NEVER_FOR_GUESTS = frozenset({"apple_erinnerungen", "apple_kalender", "apple_kontakte",
                              "apple_home", "apple_wecker", "apple_standort"})
# Composio (Tool Router): nur Suchen, Schemas lesen und Ausführen geprüfter Slugs – kein Workbench/Bash,
# keine Verbindungsverwaltung (die hätten Zugriff auf alle Apps des Admins).
COMPOSIO_ALLOWED = {"COMPOSIO_SEARCH_TOOLS", "COMPOSIO_GET_TOOL_SCHEMAS", "COMPOSIO_MULTI_EXECUTE_TOOL"}


def guest_tool_names(tools: dict) -> set[str]:
    names = set(GUEST_BASE_TOOLS)
    for key, group in GUEST_TOOL_GROUPS.items():
        if tools.get(key):
            names |= group
    return names - NEVER_FOR_GUESTS


class ScopedMCP:
    """MCP-Hub mit nur freigegebenen Servern (z. B. atrium) bzw. Composio-Apps (z. B. gmail) für Gast-Läufe."""

    SEP = "__"

    def __init__(self, hub, servers: list[str], apps: list[str]) -> None:
        self.hub = hub
        self.servers = {s.lower() for s in servers if s and s.lower() != "composio"}
        self.apps = {a.upper() for a in apps if a}
        if "NOTION" in self.apps:  # Notion direkt (notion_mcp.py) ist dieselbe Freigabe wie Composio-Notion
            self.servers.add("notion")

    def _allowed(self, name: str) -> bool:
        server, _, tool = name.partition(self.SEP)
        if server == "composio":
            return bool(self.apps) and tool.upper() in COMPOSIO_ALLOWED
        return server.lower() in self.servers

    def tool_schemas(self) -> list[dict]:
        if not self.servers and not self.apps:
            return []
        return [s for s in self.hub.tool_schemas() if self._allowed(s["name"])]

    def owns(self, name: str) -> bool:
        return self.hub.owns(name)

    def call(self, name: str, args: dict):
        if not self._allowed(name):
            raise RuntimeError("Dieses Werkzeug ist für Läufe von Gästen nicht freigegeben.")
        server, _, tool = name.partition(self.SEP)
        if server == "composio":
            slugs = [str(t.get("tool_slug", "")).upper() for t in (args.get("tools") or []) if isinstance(t, dict)]
            if tool.upper() == "COMPOSIO_MULTI_EXECUTE_TOOL" and not slugs:
                raise RuntimeError("Keine Werkzeuge angegeben.")
            for slug in slugs:
                if slug.split("_", 1)[0] not in self.apps:
                    raise RuntimeError(f"{slug.split('_', 1)[0].title()} ist für Läufe von Gästen nicht freigegeben.")
        return self.hub.call(name, args)
