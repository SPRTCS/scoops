"""Scoops Connect: weitere Rechner (Macs), die sich per WebSocket mit dem Server verbinden.

Der eingebaute Bot-Rechner `vm` wird wie bisher per HTTP angesprochen. Jeder gekoppelte Rechner
(„Knoten“) bekommt einen eigenen `ComputerHub` mit `NodeTransport`: Befehle gehen als JSON über den
WebSocket der Scoops-Connect-App, Antworten kommen mit derselben `id` zurück.

Nebenläufigkeit: Engine-Läufe sind Threads, der WebSocket gehört der asyncio-Schleife des Servers.
`NodeTransport.send` (aus einem Thread) legt pro Befehl ein `concurrent.futures.Future` an, schickt
den Befehl per `run_coroutine_threadsafe` auf die Schleife und wartet blockierend auf das Future,
das die Empfangsschleife beim passenden `result` erfüllt.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import hashlib
import json
import secrets
import threading
import time
from collections import deque
from datetime import datetime, timedelta
from typing import Callable

from .apple import normalize_grants
from .computer import ComputerError
from .db import DB, new_id, now, now_iso
from .engine import USER_HOLDER, ComputerHub
from .profile import feature, user_name

VM_ID = "vm"
VM_NAME = "Bot-Rechner"
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_TTL = 10 * 60
CMD_TIMEOUT = 60.0
SCREENSHOT_TIMEOUT = 30.0
PING_EVERY = 20.0
DEAD_AFTER = 60.0
CLAIM_FAILS_PER_MIN = 10


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def normalize_code(code: str) -> str:
    return "".join(ch for ch in (code or "").upper() if ch.isalnum())


def pretty_code(code: str) -> str:
    return f"{code[:4]}-{code[4:]}"


class NodeTransport:
    """WebSocket-Transport zu einem Scoops-Connect-Rechner (threadsicher)."""

    def __init__(self, node_id: str, name: str):
        self.node_id = node_id
        self.name = name
        self.loop: asyncio.AbstractEventLoop | None = None
        self.ws = None
        self.send_lock: asyncio.Lock | None = None
        self.paused = False
        self.screen: dict | None = None
        self.info: dict = {}
        self.apple: dict | None = None  # Apple-Freigaben laut hello/state (None = alte App ohne Apple-Dienste)
        self.last_msg = 0.0
        self._pending: dict[str, concurrent.futures.Future] = {}
        self._lock = threading.Lock()

    @property
    def online(self) -> bool:
        return self.ws is not None

    def alive(self) -> bool:
        return self.online

    # -- Verbindung (nur aus der Event-Loop aufrufen) -------------------------
    def attach(self, ws, loop: asyncio.AbstractEventLoop):
        old = self.ws
        self.ws, self.loop, self.send_lock = ws, loop, asyncio.Lock()
        self.last_msg = time.time()
        return old

    def detach(self, ws, reason: str) -> bool:
        if self.ws is not ws:
            return False  # schon durch eine neuere Verbindung ersetzt
        self.ws = None
        self.fail_all(reason)
        return True

    async def send_json(self, data: dict, ws=None) -> None:
        ws = ws or self.ws
        if ws is None:
            raise ComputerError(f"Der Rechner „{self.name}“ ist offline")
        async with self.send_lock or asyncio.Lock():
            await ws.send_text(json.dumps(data, ensure_ascii=False))

    def resolve(self, cid: str, result) -> None:
        with self._lock:
            fut = self._pending.get(cid)
        if fut and not fut.done():
            fut.set_result(result if isinstance(result, dict) else {"success": False, "error": "Ungültige Antwort"})

    def fail_all(self, reason: str) -> None:
        with self._lock:
            futs = list(self._pending.values())
        for f in futs:
            if not f.done():
                f.set_exception(ComputerError(reason))

    def post(self, data: dict) -> None:
        """Nachricht ohne Antwort aus einem beliebigen Thread verschicken (Fehler werden ignoriert)."""
        loop = self.loop
        if not self.online or loop is None or loop.is_closed():
            return

        async def go():
            try:
                await self.send_json(data)
            except Exception:  # noqa: BLE001
                pass

        try:
            in_loop = asyncio.get_running_loop() is loop
        except RuntimeError:
            in_loop = False
        if in_loop:
            loop.create_task(go())
        else:
            asyncio.run_coroutine_threadsafe(go(), loop)

    # -- Befehle (aus Worker-Threads) -----------------------------------------
    def send(self, command: str, params: dict) -> dict:
        if not self.online or self.loop is None:
            raise ComputerError(f"Der Rechner „{self.name}“ ist offline (Scoops Connect ist nicht verbunden). "
                                f"Sag {user_name()} Bescheid, statt es weiter zu versuchen.")
        if self.paused and not command.startswith("apple."):  # Pause betrifft die Steuerung, nicht die Apple-Dienste
            raise ComputerError(f"Rechner ist pausiert: Auf „{self.name}“ wurde Scoops Connect pausiert. "
                                f"Sag {user_name()} Bescheid, statt es weiter zu versuchen.")
        try:
            if asyncio.get_running_loop() is self.loop:
                raise RuntimeError("NodeTransport.send darf nicht in der Event-Loop laufen (asyncio.to_thread nutzen)")
        except RuntimeError as e:
            if "Event-Loop" in str(e):
                raise
        cid = "c_" + secrets.token_hex(8)
        fut: concurrent.futures.Future = concurrent.futures.Future()
        with self._lock:
            self._pending[cid] = fut
        timeout = SCREENSHOT_TIMEOUT if command == "screenshot" else CMD_TIMEOUT
        try:
            try:
                asyncio.run_coroutine_threadsafe(
                    self.send_json({"type": "cmd", "id": cid, "command": command, "params": params}), self.loop
                ).result(timeout=10)
            except ComputerError:
                raise
            except Exception as e:  # noqa: BLE001
                raise ComputerError(f"Befehl an „{self.name}“ nicht zustellbar: {e}") from e
            try:
                return fut.result(timeout=timeout)
            except concurrent.futures.TimeoutError as e:
                raise ComputerError(f"{command}: keine Antwort von „{self.name}“ nach {int(timeout)} s") from e
        finally:
            with self._lock:
                self._pending.pop(cid, None)


class Computers:
    """Registry aller Rechner: `vm` (HTTP) + je gekoppeltem Rechner ein Hub mit WebSocket-Transport."""

    def __init__(self, db: DB, vm: ComputerHub):
        self.db = db
        vm.node_id, vm.name = VM_ID, VM_NAME
        self.vm = vm
        self.hubs: dict[str, ComputerHub] = {VM_ID: vm}
        self.listeners: list[Callable[[dict], None]] = []
        self.on_node_changed: Callable[[str, dict | None], None] | None = None  # (node_id, json oder None = gelöscht)
        self._lock = threading.Lock()
        self._claim_fails: deque[float] = deque()
        for r in db.q("SELECT * FROM nodes ORDER BY created_at"):
            self._make(r)

    # -- Hubs -----------------------------------------------------------------
    def _make(self, r) -> ComputerHub:
        tr = NodeTransport(r["id"], r["name"])
        if r["screen"]:
            try:
                tr.screen = json.loads(r["screen"])
            except ValueError:
                pass
        hub = ComputerHub(url="", node_id=r["id"], name=r["name"], transport=tr)
        for f in self.listeners:
            hub.listeners.append(f)
        hub.listeners.append(lambda st, tr=tr: self._tell_node(tr, st))
        with self._lock:
            self.hubs[r["id"]] = hub
        return hub

    def add_listener(self, f: Callable[[dict], None]) -> None:
        self.listeners.append(f)
        with self._lock:
            hubs = list(self.hubs.values())
        for h in hubs:
            h.listeners.append(f)

    def get(self, node_id: str | None) -> ComputerHub | None:
        with self._lock:
            return self.hubs.get(node_id or VM_ID)

    def for_bot(self, bot: dict | None) -> ComputerHub:
        nid = (bot or {}).get("computer_node") or self.default_id()
        return self.get(nid) or self.get(self.default_id()) or self.vm

    def default_id(self) -> str:
        """Ohne VM-Bot-Rechner (Edition „standard“) arbeiten Scoops ohne eigene Zuordnung am Standard-Rechner.

        Zeigt `default_computer_node` auf einen nicht (mehr) vorhandenen Rechner, gilt der zuletzt aktive."""
        if feature("vm"):
            return VM_ID
        from .profile import _read_config
        nid = _read_config().get("default_computer_node")
        if nid and self.get(nid):
            return nid
        return self.fallback_id() or VM_ID

    def fallback_id(self, exclude: set[str] | None = None) -> str | None:
        """Zuletzt aktiver gekoppelter Rechner (online zuerst) – Ersatz, wenn der Standard-Rechner fehlt."""
        exclude = exclude or set()
        hubs = [h for h in self.all() if h.node_id != VM_ID and h.node_id not in exclude]
        if not hubs:
            return None
        seen = {r["id"]: (r["last_seen"] or r["created_at"] or "") for r in self.db.q("SELECT id, last_seen, created_at FROM nodes")}
        hubs.sort(key=lambda h: (bool(getattr(h.transport, "online", False)), seen.get(h.node_id, "")), reverse=True)
        return hubs[0].node_id

    def visible(self) -> list[ComputerHub]:
        """Rechner für die App: ohne VM-Funktion erscheint der eingebaute Bot-Rechner nicht."""
        hubs = self.all()
        return hubs if feature("vm") else [h for h in hubs if h.node_id != VM_ID]

    def all(self) -> list[ComputerHub]:
        with self._lock:
            return list(self.hubs.values())

    def release_if_idle(self) -> None:
        for h in self.all():
            h.release_if_idle()

    # -- Darstellung ---------------------------------------------------------
    def _bot_name(self, bot_id: str | None) -> str | None:
        if not bot_id or bot_id == USER_HOLDER:
            return None
        r = self.db.bot_row(bot_id)
        return r["name"] if r else None

    def node_json(self, hub: ComputerHub) -> dict:
        """Achtung: für `vm` ein HTTP-Aufruf (bis 2 s), daher nicht in der Event-Loop aufrufen."""
        st = hub.state()
        if hub.node_id == VM_ID:
            return {"id": VM_ID, "name": self.vm_name(), "mode": "vm", "builtin": True, "online": st["state"] != "asleep",
                    "paused": False, "os": "macOS (VM)", "app_version": None, "last_seen": None,
                    "screen": {"width": st["width"], "height": st["height"]}, "state": st["state"],
                    "bot_id": st["bot_id"], "bot_name": self._bot_name(st["bot_id"]), "created_at": None}
        r = self.db.one("SELECT * FROM nodes WHERE id=?", (hub.node_id,))
        tr: NodeTransport = hub.transport
        return {"id": hub.node_id, "name": hub.name, "mode": (r["mode"] if r else None) or "direct", "builtin": False,
                "online": tr.online, "paused": tr.paused, "os": r["os"] if r else None,
                "app_version": r["app_version"] if r else None,
                "last_seen": now_iso() if tr.online else (r["last_seen"] if r else None),
                "screen": tr.screen, "state": st["state"], "bot_id": st["bot_id"], "bot_name": self._bot_name(st["bot_id"]),
                "created_at": r["created_at"] if r else None,
                "apple": normalize_grants(tr.apple) if tr.apple is not None else None}

    def list_json(self) -> list[dict]:
        return [self.node_json(h) for h in self.visible()]

    def vm_name(self) -> str:
        return self.db.setting("node_vm_name") or VM_NAME

    def changed(self, node_id: str) -> None:
        if not self.on_node_changed:
            return
        hub = self.get(node_id)
        if hub and node_id != VM_ID:
            self.on_node_changed(node_id, self.node_json(hub))

    def _tell_node(self, tr: NodeTransport, st: dict) -> None:
        """Scoops Connect zeigt an, wer gerade auf dem Rechner arbeitet."""
        tr.post({"type": "activity", "state": st.get("state"), "bot_id": st.get("bot_id"),
                 "bot_name": self._bot_name(st.get("bot_id"))})

    # -- Verwaltung ----------------------------------------------------------
    def rename(self, node_id: str, name: str) -> None:
        name = name.strip()[:60]
        if not name:
            raise ValueError("Name fehlt")
        if node_id == VM_ID:
            self.db.set_setting("node_vm_name", name)
            return
        hub = self.get(node_id)
        if not hub:
            raise KeyError(node_id)
        self.db.q("UPDATE nodes SET name=? WHERE id=?", (name, node_id))
        hub.name = name
        hub.transport.name = name
        hub.transport.post({"type": "renamed", "name": name})

    def remove(self, node_id: str) -> tuple[NodeTransport, list[str]]:
        """Entfernt den Rechner; gibt Transport (zum Trennen) und betroffene Scoops zurück."""
        if node_id == VM_ID:
            raise ValueError("Der Bot-Rechner kann nicht entfernt werden")
        with self._lock:
            hub = self.hubs.pop(node_id, None)
        if not hub:
            raise KeyError(node_id)
        self.db.q("DELETE FROM nodes WHERE id=?", (node_id,))
        ids = [r["id"] for r in self.db.q("SELECT id FROM bots WHERE computer_node=?", (node_id,))]
        self.db.q("UPDATE bots SET computer_node=NULL WHERE computer_node=?", (node_id,))
        self._fix_default({node_id})
        return hub.transport, ids

    def _fix_default(self, gone: set[str], replacement: str | None = None) -> None:
        """`default_computer_node` zeigt auf einen entfernten Rechner → Ersatz (oder Eintrag entfernen)."""
        from .bots import load_config, save_config
        cfg = load_config()
        cur = cfg.get("default_computer_node")
        if not cur or (cur not in gone and self.get(cur)):
            return
        new = replacement if replacement and self.get(replacement) else self.fallback_id(exclude=gone)
        if new:
            cfg["default_computer_node"] = new
        else:
            cfg.pop("default_computer_node", None)
        save_config(cfg)

    def absorb(self, keep_id: str, old_ids) -> tuple[list[NodeTransport], list[str]]:
        """Ersetzt Rechner `old_ids` durch `keep_id`: Scoops werden umgehängt, alte Einträge entfernt.

        Gibt die Transporte der entfernten Rechner (zum Trennen) und die betroffenen Scoops zurück."""
        old_ids = [o for o in dict.fromkeys(old_ids) if o and o != keep_id and o != VM_ID]
        if not old_ids or not self.get(keep_id):
            return [], []
        transports: list[NodeTransport] = []
        bots: list[str] = []
        for oid in old_ids:
            with self._lock:
                hub = self.hubs.pop(oid, None)
            if hub:
                transports.append(hub.transport)
            bots += [r["id"] for r in self.db.q("SELECT id FROM bots WHERE computer_node=?", (oid,))]
            self.db.q("UPDATE bots SET computer_node=? WHERE computer_node=?", (keep_id, oid))
            self.db.q("DELETE FROM nodes WHERE id=?", (oid,))
        self._fix_default(set(old_ids), replacement=keep_id)
        return transports, bots

    def duplicates_of(self, node_id: str, device_id: str | None = None, legacy_by_name: bool = False) -> list[str]:
        """Weitere Einträge desselben Macs: gleiche Geräte-ID; mit `legacy_by_name` zusätzlich alte Einträge
        ohne Geräte-ID mit gleichem Namen, die gerade offline sind (frühere Kopplungen von „Dieser Mac“)."""
        r = self.db.one("SELECT * FROM nodes WHERE id=?", (node_id,))
        if not r:
            return []
        dev = device_id or r["device_id"]
        out = []
        for o in self.db.q("SELECT * FROM nodes WHERE id<>?", (node_id,)):
            hub = self.get(o["id"])
            online = bool(hub and getattr(hub.transport, "online", False))
            if dev and o["device_id"] == dev:
                out.append(o["id"])
            elif legacy_by_name and not o["device_id"] and not online and o["name"].strip().casefold() == r["name"].strip().casefold():
                out.append(o["id"])
        return out

    def set_device(self, node_id: str, device_id: str) -> None:
        self.db.q("UPDATE nodes SET device_id=? WHERE id=?", (device_id[:80], node_id))

    def cleanup_orphans(self) -> dict:
        """Beim Start: Verweise von Scoops und Konfiguration auf nicht mehr vorhandene Rechner aufräumen."""
        rows = self.db.q("SELECT id FROM bots WHERE computer_node IS NOT NULL AND computer_node<>? "
                         "AND computer_node NOT IN (SELECT id FROM nodes)", (VM_ID,))
        bots = [r["id"] for r in rows]
        if bots:
            self.db.q("UPDATE bots SET computer_node=NULL WHERE computer_node IS NOT NULL AND computer_node<>? "
                      "AND computer_node NOT IN (SELECT id FROM nodes)", (VM_ID,))
        from .profile import _read_config
        before = _read_config().get("default_computer_node")
        self._fix_default(set())
        after = _read_config().get("default_computer_node")
        return {"bots": bots, "default_before": before, "default_after": after}

    # -- Kopplung -------------------------------------------------------------
    def create_pairing(self) -> dict:
        self.db.q("DELETE FROM node_pairings WHERE expires_at < ?", (now_iso(),))
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
        expires = (now() + timedelta(seconds=CODE_TTL)).isoformat(timespec="seconds")
        self.db.q("INSERT INTO node_pairings(code, expires_at, used) VALUES(?,?,0)", (code, expires))
        return {"code": pretty_code(code), "expires_at": expires, "ttl_seconds": CODE_TTL}

    def claim_rate_limited(self) -> bool:
        cut = time.time() - 60
        with self._lock:
            while self._claim_fails and self._claim_fails[0] < cut:
                self._claim_fails.popleft()
            return len(self._claim_fails) >= CLAIM_FAILS_PER_MIN

    def claim(self, body: dict) -> dict | None:
        """Löst einen Code ein. None = ungültig/abgelaufen/benutzt (zählt als Fehlversuch)."""
        code = normalize_code(body.get("code") or "")
        with self._lock:
            r = self.db.one("SELECT * FROM node_pairings WHERE code=?", (code,)) if len(code) == 8 else None
            ok = bool(r) and not r["used"] and datetime.fromisoformat(r["expires_at"]) > now()
            if not ok:
                self._claim_fails.append(time.time())
                return None
            self.db.q("UPDATE node_pairings SET used=1 WHERE code=?", (code,))
        mode = body.get("mode") if body.get("mode") in ("direct", "vm") else "direct"
        name = (body.get("name") or "").strip()[:60] or "Mac"
        device = str(body.get("device_id") or "").strip()[:80] or None
        token = secrets.token_urlsafe(32)
        ts = now_iso()
        os_, ver = (body.get("os") or "")[:60], (body.get("app_version") or "")[:40]
        # Derselbe Mac koppelt sich neu (gleiche Geräte-ID): alten Eintrag weiterverwenden statt einen neuen
        # anzulegen. ID bleibt, Scoops bleiben zugeordnet; nur das Token wird ersetzt.
        same = self.db.q("SELECT id FROM nodes WHERE device_id=? ORDER BY created_at", (device,)) if device else []
        if same:
            nid = same[0]["id"]
            hub = self.get(nid)
            old_tr = hub.transport if hub else None
            self.db.q("UPDATE nodes SET name=?, mode=?, token_hash=?, os=?, app_version=? WHERE id=?",
                      (name, mode, token_hash(token), os_, ver, nid))
            if hub:
                hub.name = name
                hub.transport.name = name
            else:
                self._make(self.db.one("SELECT * FROM nodes WHERE id=?", (nid,)))
            transports, bots = self.absorb(nid, [r["id"] for r in same[1:]])
            if old_tr is not None:
                transports.append(old_tr)  # alte Verbindung (altes Token) trennen
            return {"node_id": nid, "node_token": token, "replaced": [r["id"] for r in same[1:]],
                    "_drop": transports, "_bots": bots, "reused": True}
        nid = new_id("n")
        self.db.q("INSERT INTO nodes(id,name,mode,token_hash,os,app_version,created_at,last_seen,device_id) "
                  "VALUES(?,?,?,?,?,?,?,?,?)", (nid, name, mode, token_hash(token), os_, ver, ts, None, device))
        self._make(self.db.one("SELECT * FROM nodes WHERE id=?", (nid,)))
        return {"node_id": nid, "node_token": token, "replaced": [], "_drop": [], "_bots": [], "reused": False}

    def by_token(self, token: str) -> ComputerHub | None:
        if not token:
            return None
        r = self.db.one("SELECT id FROM nodes WHERE token_hash=?", (token_hash(token),))
        return self.get(r["id"]) if r else None

    # -- Nachrichten vom Rechner (in der Event-Loop) -------------------------------
    def handle(self, hub: ComputerHub, msg: dict) -> dict | None:
        """Verarbeitet eine Nachricht; gibt ggf. eine direkte Antwort zurück."""
        tr: NodeTransport = hub.transport
        tr.last_msg = time.time()
        typ = msg.get("type")
        if typ == "result":
            tr.resolve(str(msg.get("id")), msg.get("result"))
        elif typ == "ping":
            return {"type": "pong"}
        elif typ == "hello":
            tr.info = {k: msg.get(k) for k in ("os", "app_version", "mode")}
            scr = msg.get("screen") or {}
            if scr.get("width") and scr.get("height"):
                tr.screen = {"width": int(scr["width"]), "height": int(scr["height"])}
                hub.reset_screen()
            tr.paused = bool(msg.get("paused"))
            tr.apple = normalize_grants(msg["apple"]) if isinstance(msg.get("apple"), dict) else None
            fields = {"os": (msg.get("os") or "")[:60], "app_version": (msg.get("app_version") or "")[:40],
                      "screen": json.dumps(tr.screen) if tr.screen else None, "last_seen": now_iso()}
            if msg.get("mode") in ("direct", "vm"):
                fields["mode"] = msg["mode"]
            dev = str(msg.get("device_id") or "").strip()[:80]
            if dev and not (self.db.one("SELECT device_id FROM nodes WHERE id=?", (hub.node_id,)) or {"device_id": None})["device_id"]:
                fields["device_id"] = dev
            sets = ",".join(f"{k}=?" for k in fields)
            self.db.q(f"UPDATE nodes SET {sets} WHERE id=?", (*fields.values(), hub.node_id))
            return {"type": "welcome", "node_id": hub.node_id, "name": hub.name}
        elif typ == "state":
            if "paused" in msg:
                tr.paused = bool(msg["paused"])
            if isinstance(msg.get("apple"), dict):
                tr.apple = normalize_grants(msg["apple"])
            scr = msg.get("screen") or {}
            if scr.get("width") and scr.get("height"):
                tr.screen = {"width": int(scr["width"]), "height": int(scr["height"])}
                hub.reset_screen()
        return None

    def touch(self, node_id: str) -> None:
        self.db.q("UPDATE nodes SET last_seen=? WHERE id=?", (now_iso(), node_id))


__all__ = ["Computers", "NodeTransport", "VM_ID"]
