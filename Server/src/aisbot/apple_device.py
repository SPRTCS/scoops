"""Apple-Dienste Phase 2 (Server 1.18): Home, Wecker und Standort über das iPhone/iPad mit AIS Scoops.

HomeKit, AlarmKit und Geofences gibt es nur auf iPhone und iPad. Die iOS-App AIS Scoops meldet sich deshalb als
„Apple-Gerät“ beim eigenen Server an: über die bestehende Live-Verbindung `/api/ws` (`device.hello`), im Hintergrund
über HTTP (`POST /api/apple/device…`). Der Server hält pro Gerät Status, zuletzt gesehen, Fähigkeiten und Freigaben
(Tabelle `apple_devices`). Ein Befehl an das Gerät:

1. geht als `device.cmd` über `/api/ws`, wenn die App gerade verbunden und im Vordergrund ist,
2. sonst (oder ohne Antwort nach 3 s) weckt eine stille Push (`content-available`) die App; sie holt offene Befehle
   per `POST /api/apple/device/poll`, führt sie aus und antwortet mit `POST /api/apple/device/result`,
3. nach 25 s ohne Antwort bekommt der Scoop „iPhone nicht erreichbar – öffne AIS Scoops“.

Im Hintergrund ist das nicht garantiert: iOS stellt stille Pushes nach eigenem Ermessen zu (Energiesparmodus,
App vom Nutzer beendet, Drosselung bei vielen Pushes).

Gerät: config.json `apple_device` (ausdrücklich gewählt), sonst das zuletzt aktive iPhone, sonst das zuletzt aktive
iPad. Der Mac-Client meldet keine dieser Fähigkeiten. Gäste geteilter Scoops bekommen die Werkzeuge nie
(sharing.NEVER_FOR_GUESTS). Koordinaten von Orten liegen nur auf dem Gerät; der Server speichert pro Ort nur Name,
Chat, Scoop, Notiz und Auslöser. Standort- und Home-Daten werden nie protokolliert.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import json
import re
import secrets
import threading
import time
from typing import Callable

from .db import new_id, now_iso

SERVICES = ("home", "alarms", "location")
LABEL = {"home": "Home", "alarms": "Wecker", "location": "Standort"}
TOOL = {"home": "apple_home", "alarms": "apple_wecker", "location": "apple_standort"}
TOOL_NAMES = frozenset(TOOL.values())
KINDS = ("iphone", "ipad", "mac")
# Freigabe-Zustände, wie die App sie meldet. Standort zusätzlich `always` / `when_in_use`.
PERMISSIONS = {"granted", "denied", "not_determined", "restricted", "unavailable", "always", "when_in_use", "unknown"}
GRANTED = {"home": {"granted"}, "alarms": {"granted"}, "location": {"always", "when_in_use"}}
WAIT_S = 25.0
PUSH_FALLBACK_S = 3.0
MAX_RESULT = 20000
# Diese Geräte schaltet ein Scoop nur über eine Freigabe-Karte (auch in Szenen).
SENSITIVE_TYPES = {"lock", "garage_door", "security_system", "door"}
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
WEEKDAY_IN = {"mo": 0, "montag": 0, "di": 1, "dienstag": 1, "mi": 2, "mittwoch": 2, "do": 3, "donnerstag": 3,
              "fr": 4, "freitag": 4, "sa": 5, "samstag": 5, "so": 6, "sonntag": 6}
SECURITY_IN = {"aus": "off", "zuhause": "stay", "abwesend": "away", "nacht": "night"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS apple_devices (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, model TEXT DEFAULT '', os TEXT DEFAULT '',
  app_version TEXT DEFAULT '', capabilities TEXT DEFAULT '[]', permissions TEXT DEFAULT '{}', push_token TEXT,
  created_at TEXT NOT NULL, last_seen TEXT, last_active TEXT
);
CREATE TABLE IF NOT EXISTS apple_geofences (
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL, chat_id TEXT NOT NULL, bot_id TEXT NOT NULL, name TEXT NOT NULL,
  note TEXT DEFAULT '', on_entry INTEGER DEFAULT 1, on_exit INTEGER DEFAULT 0, radius INTEGER DEFAULT 150,
  created_at TEXT NOT NULL, last_event TEXT, last_event_at TEXT
);
"""


class AppleDeviceError(RuntimeError):
    pass


def normalize_permissions(raw) -> dict[str, str]:
    out = {s: "unknown" for s in SERVICES}
    if not isinstance(raw, dict):
        return out
    for s in SERVICES:
        v = raw.get(s)
        if v is True:
            out[s] = "always" if s == "location" else "granted"
        elif v is False:
            out[s] = "denied"
        elif isinstance(v, str):
            v = re.sub(r"(?<!^)(?=[A-Z])", "_", v.strip()).lower().replace("-", "_")  # notDetermined → not_determined
            v = {"authorized": "granted", "authorized_always": "always", "authorized_when_in_use": "when_in_use"}.get(v, v)
            out[s] = v if v in PERMISSIONS else "unknown"
    return out


def granted(service: str, permission: str) -> bool:
    return permission in GRANTED[service]


class _Socket:
    """Verbindung `/api/ws` eines Geräts: Senden aus Worker-Threads über die Event-Loop des Servers."""

    def __init__(self, ws, loop: asyncio.AbstractEventLoop, send: Callable[[dict], object], active: bool):
        self.ws, self.loop, self.send_fn, self.active = ws, loop, send, active

    def post(self, data: dict) -> bool:
        if self.loop.is_closed():
            return False
        try:
            asyncio.run_coroutine_threadsafe(self.send_fn(data), self.loop).result(timeout=5)
            return True
        except Exception:  # noqa: BLE001 – Verbindung gerade weg: Push übernimmt
            return False


class AppleDevices:
    """Registry der Apple-Geräte, Befehlsweiterleitung (Socket oder stille Push) und Werkzeuge."""

    def __init__(self, db, load_config: Callable[[], dict], save_config: Callable[[dict], None], pusher=None,
                 user_name: Callable[[], str] = lambda: "Arman"):
        self.db = db
        with db.lock:
            db.conn.executescript(SCHEMA)
            db.conn.commit()
        self.load_config = load_config
        self.save_config = save_config
        self.pusher = pusher
        self.user_name = user_name
        self.sockets: dict[str, _Socket] = {}
        self.pending: dict[str, tuple[dict, concurrent.futures.Future]] = {}
        self._lock = threading.Lock()
        self._recent_events: dict[str, float] = {}
        self.on_changed: Callable[[], None] | None = None  # → apple.updated
        self.on_geofence: Callable[[dict, str, str], None] | None = None  # (Ort, enter|exit, Zeitpunkt)

    # -- Geräte ---------------------------------------------------------------------
    def _json(self, r) -> dict:
        did = r["id"]
        sock = self.sockets.get(did)
        try:
            caps = [c for c in json.loads(r["capabilities"] or "[]") if c in SERVICES]
        except ValueError:
            caps = []
        try:
            perms = normalize_permissions(json.loads(r["permissions"] or "{}"))
        except ValueError:
            perms = normalize_permissions(None)
        return {"id": did, "name": r["name"], "kind": r["kind"], "model": r["model"] or None, "os": r["os"] or None,
                "app_version": r["app_version"] or None, "online": sock is not None, "active": bool(sock and sock.active),
                "last_seen": now_iso() if sock is not None else r["last_seen"], "last_active": r["last_active"],
                "capabilities": caps, "permissions": perms, "push": bool(r["push_token"])}

    def all(self) -> list[dict]:
        rows = self.db.q("SELECT * FROM apple_devices ORDER BY COALESCE(last_active, created_at) DESC")
        return [self._json(r) for r in rows]

    def get(self, did: str) -> dict | None:
        r = self.db.one("SELECT * FROM apple_devices WHERE id=?", (did,))
        return self._json(r) if r else None

    def device(self, cfg: dict | None = None) -> tuple[dict | None, str]:
        """(gewähltes Gerät oder None, Quelle config | auto | none)."""
        cfg = self.load_config() if cfg is None else cfg
        devices = [d for d in self.all() if d["kind"] in ("iphone", "ipad") and d["capabilities"]]
        chosen = cfg.get("apple_device")
        if chosen:
            for d in devices:
                if d["id"] == chosen:
                    return d, "config"
        iphones = [d for d in devices if d["kind"] == "iphone"]
        pool = iphones or devices
        return (pool[0], "auto") if pool else (None, "none")

    def register(self, body: dict) -> dict:
        """Anmeldung/Aktualisierung eines Geräts (`device.hello` bzw. `POST /api/apple/device`)."""
        did = str(body.get("device_id") or "").strip()[:80]
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{6,80}", did):
            raise ValueError("device_id fehlt oder ist ungültig")
        kind = body.get("kind") if body.get("kind") in KINDS else "iphone"
        caps = [c for c in (body.get("capabilities") or []) if c in SERVICES] if kind != "mac" else []
        perms = normalize_permissions(body.get("permissions"))
        name = (str(body.get("name") or "").strip() or ("iPad" if kind == "ipad" else "iPhone"))[:60]
        push = str(body.get("push_token") or "").strip().lower()
        push = push if re.fullmatch(r"[0-9a-f]{32,400}", push) else None
        ts = now_iso()
        active = body.get("active", True) is not False
        old = self.db.one("SELECT * FROM apple_devices WHERE id=?", (did,))
        fields = {"name": name, "kind": kind, "model": str(body.get("model") or "")[:60], "os": str(body.get("os") or "")[:40],
                  "app_version": str(body.get("app_version") or "")[:40], "capabilities": json.dumps(caps),
                  "permissions": json.dumps(perms), "last_seen": ts}
        if push:
            fields["push_token"] = push
        if active:
            fields["last_active"] = ts
        if old:
            sets = ",".join(f"{k}=?" for k in fields)
            self.db.q(f"UPDATE apple_devices SET {sets} WHERE id=?", (*fields.values(), did))
        else:
            fields.setdefault("last_active", ts)
            cols = ",".join(["id", "created_at", *fields])
            self.db.q(f"INSERT INTO apple_devices({cols}) VALUES({','.join('?' * (len(fields) + 2))})",
                      (did, ts, *fields.values()))
        changed = not old or any(str(old[k] or "") != str(fields.get(k, old[k]) or "")
                                 for k in ("name", "kind", "capabilities", "permissions"))
        if changed:
            self._changed()
        return self.get(did)

    def remove(self, did: str) -> bool:
        if not self.db.one("SELECT 1 FROM apple_devices WHERE id=?", (did,)):
            return False
        self.db.q("DELETE FROM apple_devices WHERE id=?", (did,))
        self.db.q("DELETE FROM apple_geofences WHERE device_id=?", (did,))
        with self._lock:
            self.sockets.pop(did, None)
        cfg = self.load_config()
        if cfg.get("apple_device") == did:
            cfg.pop("apple_device", None)
            self.save_config(cfg)
        self._changed()
        return True

    def _changed(self) -> None:
        if self.on_changed:
            try:
                self.on_changed()
            except Exception as e:  # noqa: BLE001
                print("apple.updated (Gerät):", e, flush=True)

    # -- Live-Verbindung (/api/ws) ------------------------------------------------------
    def attach(self, did: str, ws, loop, send: Callable[[dict], object], active: bool = True) -> None:
        with self._lock:
            was = did in self.sockets
            self.sockets[did] = _Socket(ws, loop, send, active)
        if not was:
            self._changed()

    def set_active(self, did: str, active: bool) -> None:
        sock = self.sockets.get(did)
        if sock:
            sock.active = active
        if active:
            self.db.q("UPDATE apple_devices SET last_active=?, last_seen=? WHERE id=?", (now_iso(), now_iso(), did))

    def detach(self, did: str, ws) -> None:
        with self._lock:
            sock = self.sockets.get(did)
            if not sock or sock.ws is not ws:
                return
            del self.sockets[did]
        self.db.q("UPDATE apple_devices SET last_seen=? WHERE id=?", (now_iso(), did))
        self._changed()

    # -- Befehle --------------------------------------------------------------------------
    def pending_for(self, did: str) -> list[dict]:
        with self._lock:
            return [dict(e) for e, f in self.pending.values() if e["device_id"] == did and not f.done()]

    def resolve(self, did: str | None, cid: str, result) -> bool:
        with self._lock:
            item = self.pending.get(str(cid))
        if not item or (did and item[0]["device_id"] != did):
            return False
        fut = item[1]
        if not fut.done():
            fut.set_result(result if isinstance(result, dict) else {"success": False, "error": "Ungültige Antwort"})
        if did:
            self.db.q("UPDATE apple_devices SET last_seen=? WHERE id=?", (now_iso(), did))
        return True

    def _wake(self, dev: dict, cid: str) -> bool:
        r = self.db.one("SELECT push_token FROM apple_devices WHERE id=?", (dev["id"],))
        token = r["push_token"] if r else None
        if not token or self.pusher is None:
            return False
        try:
            return bool(self.pusher.wake(token, {"apple_cmd": cid}))
        except Exception as e:  # noqa: BLE001
            print("Stille Push an Apple-Gerät fehlgeschlagen:", type(e).__name__, flush=True)
            return False

    def unreachable(self, dev: dict) -> str:
        what = "iPad" if dev.get("kind") == "ipad" else "iPhone"
        return (f"{what} nicht erreichbar – öffne AIS Scoops auf „{dev['name']}“. Im Hintergrund kann iOS das Aufwecken "
                f"verzögern oder auslassen. Sag {self.user_name()} kurz Bescheid und versuch es nicht sofort erneut.")

    def call(self, service: str, command: str, params: dict, timeout: float | None = None) -> dict:
        """Befehl an das Apple-Gerät; wirft AppleDeviceError mit einer Meldung, die der Scoop weitergeben kann."""
        timeout = timeout or WAIT_S
        who = self.user_name()
        cfg = self.load_config()
        dev, _ = self.device(cfg)
        if dev is None:
            raise AppleDeviceError(f"Kein iPhone mit AIS Scoops angemeldet. Sag {who} Bescheid, statt es weiter zu versuchen.")
        if not self.enabled(cfg)[service]:
            raise AppleDeviceError(f"{LABEL[service]} ist in AIS Scoops ausgeschaltet ({who} kann es unter Apps verbinden → "
                                   "Apple einschalten).")
        perm = dev["permissions"][service]
        if service not in dev["capabilities"] or not granted(service, perm):
            raise AppleDeviceError(f"Auf „{dev['name']}“ fehlt die Freigabe für {LABEL[service]} ({perm}). {who} muss sie in "
                                   "AIS Scoops unter Apps verbinden → Apple erteilen. Sag es kurz, statt es weiter zu versuchen.")
        cid = "dc_" + secrets.token_hex(8)
        entry = {"id": cid, "device_id": dev["id"], "command": command, "params": params, "created_at": now_iso()}
        fut: concurrent.futures.Future = concurrent.futures.Future()
        with self._lock:
            self.pending[cid] = (entry, fut)
            sock = self.sockets.get(dev["id"])
        deadline = time.time() + timeout
        try:
            sent = bool(sock and sock.active and sock.post({"type": "device.cmd", "data": entry}))
            if sent:
                try:
                    return self._unwrap(fut.result(timeout=min(PUSH_FALLBACK_S, timeout)))
                except concurrent.futures.TimeoutError:
                    pass  # App vermutlich gerade im Hintergrund: zusätzlich wecken
            self._wake(dev, cid)
            if sock and not sent:
                sock.post({"type": "device.cmd", "data": entry})  # falls die App doch gleich wieder aktiv ist
            try:
                return self._unwrap(fut.result(timeout=max(0.5, deadline - time.time())))
            except concurrent.futures.TimeoutError as e:
                raise AppleDeviceError(self.unreachable(dev)) from e
        finally:
            with self._lock:
                self.pending.pop(cid, None)

    @staticmethod
    def _unwrap(data) -> dict:
        if not isinstance(data, dict):
            raise AppleDeviceError("Leere Antwort vom iPhone")
        if not data.get("success", False):
            raise AppleDeviceError(str(data.get("error") or "Unbekannter Fehler auf dem iPhone"))
        return {k: v for k, v in data.items() if k != "success"}

    # -- Ereignisse vom Gerät (Geofence) ------------------------------------------------------
    def event(self, did: str, body: dict) -> dict:
        if body.get("type") != "geofence":
            return {"ok": True, "handled": False}
        gid = str(body.get("id") or "")
        kind = body.get("event") if body.get("event") in ("enter", "exit") else None
        r = self.db.one("SELECT * FROM apple_geofences WHERE id=? AND device_id=?", (gid, did))
        if not r or not kind:
            return {"ok": True, "handled": False}
        key = f"{gid}:{kind}"
        now_s = time.time()
        if now_s - self._recent_events.get(key, 0) < 90:  # doppelt gemeldet (Socket + HTTP, Neustart)
            return {"ok": True, "handled": False, "duplicate": True}
        self._recent_events[key] = now_s
        at = str(body.get("at") or now_iso())[:40]
        self.db.q("UPDATE apple_geofences SET last_event=?, last_event_at=? WHERE id=?", (kind, at, gid))
        wanted = bool(r["on_entry"]) if kind == "enter" else bool(r["on_exit"])
        if wanted and self.on_geofence:
            self.on_geofence(dict(r), kind, at)
        return {"ok": True, "handled": wanted}

    # -- Konfiguration und Status ------------------------------------------------------------
    def enabled(self, cfg: dict | None = None) -> dict[str, bool]:
        cfg = self.load_config() if cfg is None else cfg
        raw = cfg.get("apple_services") if isinstance(cfg.get("apple_services"), dict) else {}
        return {s: bool(raw.get(s)) for s in SERVICES}

    def available(self, service: str, cfg: dict | None = None) -> bool:
        cfg = self.load_config() if cfg is None else cfg
        if not self.enabled(cfg)[service]:
            return False
        dev, _ = self.device(cfg)
        return bool(dev and service in dev["capabilities"] and granted(service, dev["permissions"][service]))

    def active_services(self) -> list[str]:
        cfg = self.load_config()
        return [s for s in SERVICES if self.available(s, cfg)]

    def status(self, cfg: dict | None = None) -> dict:
        cfg = self.load_config() if cfg is None else cfg
        dev, source = self.device(cfg)
        enabled = self.enabled(cfg)
        services = []
        for s in SERVICES:
            perm = dev["permissions"][s] if dev else "unknown"
            what = "iPad" if dev and dev["kind"] == "ipad" else "iPhone"
            if dev is None:
                st, hint = "no_device", "Öffne AIS Scoops auf deinem iPhone, damit es sich anmeldet."
            elif s not in dev["capabilities"]:
                st, hint = "unsupported", f"„{dev['name']}“ kann das nicht (iOS 26 und eine aktuelle AIS-Scoops-App nötig)."
            elif not granted(s, perm):
                st, hint = "needs_permission", f"Auf dem {what} in AIS Scoops erlauben."
            elif not enabled[s]:
                st, hint = "off", None
            else:
                st, hint = "ready", None
            services.append({"id": s, "name": LABEL[s], "tool": TOOL[s], "enabled": enabled[s], "permission": perm,
                             "available": st == "ready", "status": st, "hint": hint,
                             "device_id": dev["id"] if dev else None,
                             **({"background": perm == "always"} if s == "location" else {})})
        return {"device": ({**dev, "source": source} if dev else None), "device_choice": cfg.get("apple_device") or "auto",
                "devices": [d for d in self.all() if d["kind"] in ("iphone", "ipad")], "device_services": services}

    def patch(self, body: dict, cfg: dict) -> None:
        """Ändert `cfg` (wird vom Aufrufer gespeichert): Dienste und Geräteauswahl."""
        raw = dict(cfg.get("apple_services") if isinstance(cfg.get("apple_services"), dict) else {})
        for s in SERVICES:
            if s in body:
                if not isinstance(body[s], bool):
                    raise ValueError(f"{s}: true oder false")
                raw[s] = body[s]
        cfg["apple_services"] = raw
        if "device" in body:
            did = str(body.get("device") or "").strip()
            if did in ("", "auto"):
                cfg.pop("apple_device", None)
            else:
                d = self.get(did)
                if not d or d["kind"] not in ("iphone", "ipad"):
                    raise KeyError(did)
                cfg["apple_device"] = did

    # -- Werkzeuge -------------------------------------------------------------------------------
    def tools(self, make_tool: Callable, request_approval: Callable[[str, str, dict], str], chat_id: str,
              bot_id: str) -> list:
        services = self.active_services()
        if not services:
            return []
        s = {"type": "string"}
        out = []
        if "home" in services:
            out.append(make_tool(
                TOOL["home"],
                f"Apple Home (HomeKit) über {self.user_gen()} iPhone. aktion: 'uebersicht' (Zuhause, Räume, Geräte mit "
                "Zustand und Szenen; optional zuhause, raum), 'geraet' (id: aktuellen Zustand frisch lesen), 'schalten' (id "
                "eines Geräts oder Dienstes + an, helligkeit 0–100, temperatur (Zieltemperatur °C), position 0–100 für "
                "Rollos), 'szene' (id oder Name einer Szene ausführen). Schlösser (verriegeln), Garagentore und Türen "
                "(oeffnen) sowie Alarmanlagen (modus aus/zuhause/abwesend/nacht) und Szenen, die solche Geräte schalten, "
                "brauchen eine Freigabe-Karte – das Werkzeug legt sie selbst an. IDs immer aus 'uebersicht'.",
                {"aktion": {"type": "string", "enum": ["uebersicht", "geraet", "schalten", "szene"]},
                 "id": s, "zuhause": s, "raum": s, "an": {"type": "boolean"}, "helligkeit": {"type": "integer"},
                 "temperatur": {"type": "number"}, "position": {"type": "integer"}, "verriegeln": {"type": "boolean"},
                 "oeffnen": {"type": "boolean"}, "modus": {"type": "string", "enum": list(SECURITY_IN)}},
                ["aktion"], lambda i: self._home(i, request_approval), _line_home))
        if "alarms" in services:
            out.append(make_tool(
                TOOL["alarms"],
                f"Wecker und Timer auf {self.user_gen()} iPhone (AlarmKit, klingeln auch im Stummmodus, Timer mit "
                "Countdown auf dem Sperrbildschirm). aktion: 'stellen' (uhrzeit HH:MM oder zeitpunkt ISO 8601, titel, "
                "optional wiederholen z. B. 'mo,mi,fr', 'werktags', 'wochenende', 'täglich'), 'timer' (minuten oder "
                "sekunden, titel), 'anzeigen' (alle Wecker/Timer dieser App), 'loeschen' (id aus 'anzeigen'). Nur die "
                "eigenen Wecker von AIS Scoops, nicht die der Uhr-App.",
                {"aktion": {"type": "string", "enum": ["stellen", "timer", "anzeigen", "loeschen"]},
                 "uhrzeit": s, "zeitpunkt": s, "titel": s, "wiederholen": s, "minuten": {"type": "number"},
                 "sekunden": {"type": "integer"}, "id": s},
                ["aktion"], self._alarms, _line_alarms))
        if "location" in services:
            out.append(make_tool(
                TOOL["location"],
                f"Standort von {self.user_gen()} iPhone. aktion: 'wo' (aktueller Standort: Koordinaten, Adresse, "
                "Genauigkeit), 'ort_anlegen' (ortsabhängige Erinnerung: name, adresse ODER hier=true für den aktuellen "
                "Standort, radius_m 100–2000, bei betreten/verlassen/beides, notiz = was du dann tun oder sagen sollst; "
                "beim Auslösen bekommt er eine Mitteilung und du eine Nachricht hier im Chat), 'orte' (alle Orte), "
                "'ort_loeschen' (id). Standortdaten nur für den Zweck nutzen, nicht unnötig wiederholen.",
                {"aktion": {"type": "string", "enum": ["wo", "ort_anlegen", "orte", "ort_loeschen"]},
                 "name": s, "adresse": s, "hier": {"type": "boolean"}, "radius_m": {"type": "integer"},
                 "bei": {"type": "string", "enum": ["betreten", "verlassen", "beides"]}, "notiz": s, "id": s},
                ["aktion"], lambda i: self._location(i, chat_id, bot_id), _line_location))
        return out

    def user_gen(self) -> str:
        n = self.user_name()
        return n + "’" if n[-1:].lower() in ("s", "ß", "x", "z") else n + "s"

    def _run(self, service: str, command: str, params: dict) -> str:
        try:
            data = self.call(service, command, params)
        except AppleDeviceError as e:
            return f"Fehler: {e}"
        return _text(data)

    # Home
    def _home(self, i: dict, request_approval) -> str:
        a = i.get("aktion")
        if a == "uebersicht":
            return self._run("home", "apple.home.overview", _clean({"home": i.get("zuhause"), "room": i.get("raum")}))
        tid = (i.get("id") or "").strip()
        if a == "geraet":
            if not tid:
                return "Fehler: id fehlt (erst mit aktion 'uebersicht' suchen)."
            return self._run("home", "apple.home.get", {"id": tid})
        if a == "szene":
            if not tid:
                return "Fehler: id fehlt (Szene aus 'uebersicht')."
            try:
                ov = self.call("home", "apple.home.overview", {})
            except AppleDeviceError as e:
                return f"Fehler: {e}"
            scene = _find_scene(ov, tid)
            if not scene:
                return "Fehler: Szene nicht gefunden. Nimm id oder Namen aus 'uebersicht'."
            params = {"id": scene["id"]}
            if scene.get("sensitive"):
                return request_approval(
                    f"Szene ausführen: „{scene.get('name')}“",
                    "Die Szene schaltet Schlösser, Türen, Garagentore oder die Alarmanlage.",
                    {"kind": "apple", "service": "home", "command": "apple.home.scene", "sensitive": True,
                     "params": {**params, "confirmed": True}, "label": scene.get("name") or scene["id"],
                     "done": f"Szene „{scene.get('name')}“ ausgeführt"})
            return self._run("home", "apple.home.scene", params)
        if a == "schalten":
            if not tid:
                return "Fehler: id fehlt (erst mit aktion 'uebersicht' suchen)."
            params: dict = {"id": tid}
            if isinstance(i.get("an"), bool):
                params["on"] = i["an"]
            if isinstance(i.get("helligkeit"), (int, float)):
                params["brightness"] = max(0, min(100, int(i["helligkeit"])))
            if isinstance(i.get("temperatur"), (int, float)):
                params["target_temperature"] = max(5.0, min(35.0, float(i["temperatur"])))
            if isinstance(i.get("position"), (int, float)):
                params["position"] = max(0, min(100, int(i["position"])))
            sensitive_change = []
            if isinstance(i.get("verriegeln"), bool):
                params["lock"] = "secured" if i["verriegeln"] else "unsecured"
                sensitive_change.append("verriegeln" if i["verriegeln"] else "entriegeln")
            if isinstance(i.get("oeffnen"), bool):
                params["door"] = "open" if i["oeffnen"] else "closed"
                sensitive_change.append("öffnen" if i["oeffnen"] else "schließen")
            if i.get("modus") in SECURITY_IN:
                params["security"] = SECURITY_IN[i["modus"]]
                sensitive_change.append(f"Alarmanlage: {i['modus']}")
            if len(params) == 1:
                return "Fehler: nichts zu schalten (an, helligkeit, temperatur, position, verriegeln, oeffnen oder modus)."
            try:
                acc = self.call("home", "apple.home.get", {"id": tid}).get("accessory") or {}
            except AppleDeviceError as e:
                return f"Fehler: {e}"
            sensitive = bool(acc.get("sensitive")) or any(
                (x.get("type") in SENSITIVE_TYPES) for x in (acc.get("services") or []) if isinstance(x, dict))
            if sensitive or sensitive_change:
                name = acc.get("name") or tid
                what = ", ".join(sensitive_change) or _describe_change(params)
                room = f" ({acc.get('room')})" if acc.get("room") else ""
                return request_approval(
                    f"{name}{room}: {what}",
                    "Schlösser, Türen, Garagentore und die Alarmanlage schaltet ein Scoop nur mit deiner Freigabe.",
                    {"kind": "apple", "service": "home", "command": "apple.home.set", "sensitive": True,
                     "params": {**params, "confirmed": True}, "label": name, "done": f"{name}: {what}"})
            return self._run("home", "apple.home.set", params)
        return "Fehler: unbekannte aktion."

    # Wecker
    def _alarms(self, i: dict) -> str:
        a = i.get("aktion")
        if a == "anzeigen":
            return self._run("alarms", "apple.alarms.list", {})
        if a == "loeschen":
            aid = (i.get("id") or "").strip()
            if not aid:
                return "Fehler: id fehlt (erst mit aktion 'anzeigen' suchen)."
            return self._run("alarms", "apple.alarms.delete", {"id": aid})
        title = (i.get("titel") or "").strip()[:60]
        if a == "timer":
            secs = 0
            if isinstance(i.get("sekunden"), (int, float)):
                secs = int(i["sekunden"])
            elif isinstance(i.get("minuten"), (int, float)):
                secs = int(round(float(i["minuten"]) * 60))
            if not 5 <= secs <= 24 * 3600:
                return "Fehler: Dauer zwischen 5 Sekunden und 24 Stunden angeben (minuten oder sekunden)."
            return self._run("alarms", "apple.alarms.timer", {"seconds": secs, "title": title or "Timer"})
        if a == "stellen":
            p: dict = {"title": title or "Wecker"}
            t = (i.get("uhrzeit") or "").strip()
            if t:
                m = re.fullmatch(r"(\d{1,2})[:.](\d{2})(?:\s*uhr)?", t.lower())
                if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
                    return "Fehler: uhrzeit als HH:MM, z. B. 07:30."
                p["time"] = f"{int(m.group(1)):02d}:{m.group(2)}"
            elif (i.get("zeitpunkt") or "").strip():
                if not re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", i["zeitpunkt"].strip()):
                    return "Fehler: zeitpunkt als ISO 8601, z. B. 2026-11-20T06:45."
                p["date"] = i["zeitpunkt"].strip()
            else:
                return "Fehler: uhrzeit (HH:MM) oder zeitpunkt (ISO 8601) fehlt."
            rep = (i.get("wiederholen") or "").strip()
            if rep:
                days = parse_weekdays(rep)
                if days is None:
                    return "Fehler: wiederholen z. B. als 'mo,mi,fr', 'werktags', 'wochenende' oder 'täglich'."
                if "date" in p:
                    return "Fehler: Wiederholen geht nur mit uhrzeit, nicht mit festem zeitpunkt."
                p["weekdays"] = days
            return self._run("alarms", "apple.alarms.add", p)
        return "Fehler: unbekannte aktion."

    # Standort
    def _location(self, i: dict, chat_id: str, bot_id: str) -> str:
        a = i.get("aktion")
        if a == "wo":
            return self._run("location", "apple.location.current", {})
        if a == "orte":
            try:
                data = self.call("location", "apple.location.geofences", {})
            except AppleDeviceError as e:
                return f"Fehler: {e}"
            rows = {r["id"]: r for r in self.db.q("SELECT * FROM apple_geofences")}
            for g in data.get("geofences") or []:
                r = rows.get(g.get("id"))
                if r:
                    g["notiz"] = r["note"]
                    g["scoop"] = (self.db.bot_row(r["bot_id"]) or {"name": None})["name"]
                    g["bei"] = _trigger_label(r["on_entry"], r["on_exit"])
            return _text(data)
        if a == "ort_loeschen":
            gid = (i.get("id") or "").strip()
            if not gid:
                return "Fehler: id fehlt (erst mit aktion 'orte' suchen)."
            out = self._run("location", "apple.location.geofence_delete", {"id": gid})
            if not out.startswith("Fehler"):
                self.db.q("DELETE FROM apple_geofences WHERE id=?", (gid,))
            return out
        if a == "ort_anlegen":
            name = (i.get("name") or "").strip()[:60]
            if not name:
                return "Fehler: name fehlt (z. B. „Büro“)."
            addr = (i.get("adresse") or "").strip()[:200]
            here = i.get("hier") is True
            if not addr and not here:
                return "Fehler: adresse angeben oder hier=true für den aktuellen Standort."
            dev, _ = self.device()
            if dev and dev["permissions"]["location"] != "always":
                return (f"Fehler: Für Orte braucht AIS Scoops auf „{dev['name']}“ den Standortzugriff „Immer“ "
                        f"(sonst merkt das iPhone das Betreten nicht im Hintergrund). {self.user_name()} kann das in AIS Scoops "
                        "unter Apps verbinden → Apple → Standort erlauben. Sag es kurz.")
            radius = i.get("radius_m") if isinstance(i.get("radius_m"), int) else 150
            radius = max(100, min(2000, radius))
            bei = i.get("bei") if i.get("bei") in ("betreten", "verlassen", "beides") else "betreten"
            on_entry, on_exit = bei in ("betreten", "beides"), bei in ("verlassen", "beides")
            gid = new_id("gf")
            p = {"id": gid, "name": name, "radius": radius, "on_entry": on_entry, "on_exit": on_exit}
            p.update({"address": addr} if addr else {"here": True})
            try:
                data = self.call("location", "apple.location.geofence_add", p)
            except AppleDeviceError as e:
                return f"Fehler: {e}"
            self.db.q("INSERT INTO apple_geofences(id,device_id,chat_id,bot_id,name,note,on_entry,on_exit,radius,created_at) "
                      "VALUES(?,?,?,?,?,?,?,?,?,?)", (gid, dev["id"] if dev else "", chat_id, bot_id, name,
                                                     (i.get("notiz") or "").strip()[:500], int(on_entry), int(on_exit),
                                                     radius, now_iso()))
            return _text({**data, "hinweis": "Ort angelegt. Beim Auslösen kommt eine Nachricht in diesen Chat."})
        return "Fehler: unbekannte aktion."

    def run_approved(self, action: dict) -> str:
        cmd = str(action.get("command") or "")
        if cmd not in ("apple.home.set", "apple.home.scene"):
            raise AppleDeviceError("Unbekannte Aktion")
        self.call("home", cmd, dict(action.get("params") or {}))
        return action.get("label") or ""


def parse_weekdays(text: str) -> list[str] | None:
    t = text.strip().lower().replace("ä", "ae")
    if t in ("taeglich", "jeden tag", "alle"):
        return list(WEEKDAYS)
    if t in ("werktags", "wochentags", "mo-fr"):
        return WEEKDAYS[:5]
    if t in ("wochenende", "sa,so", "sa-so"):
        return WEEKDAYS[5:]
    out: list[str] = []
    for part in re.split(r"[,\s;/]+", t):
        if not part:
            continue
        idx = WEEKDAY_IN.get(part.rstrip("."))
        if idx is None:
            return None
        if WEEKDAYS[idx] not in out:
            out.append(WEEKDAYS[idx])
    return sorted(out, key=WEEKDAYS.index) or None


def _find_scene(overview: dict, key: str) -> dict | None:
    k = key.strip().casefold()
    scenes = [sc for h in (overview.get("homes") or []) for sc in (h.get("scenes") or []) if isinstance(sc, dict)]
    return next((sc for sc in scenes if sc.get("id") == key), None) or \
        next((sc for sc in scenes if str(sc.get("name") or "").casefold() == k), None)


def _describe_change(p: dict) -> str:
    parts = []
    if "on" in p:
        parts.append("einschalten" if p["on"] else "ausschalten")
    if "brightness" in p:
        parts.append(f"Helligkeit {p['brightness']} %")
    if "target_temperature" in p:
        parts.append(f"{p['target_temperature']:g} °C")
    if "position" in p:
        parts.append(f"Position {p['position']} %")
    return ", ".join(parts) or "schalten"


def _trigger_label(on_entry, on_exit) -> str:
    return "beides" if on_entry and on_exit else ("verlassen" if on_exit else "betreten")


def _clean(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None and v != ""}


def _text(data) -> str:
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    if len(text) > MAX_RESULT:
        text = text[:MAX_RESULT] + " … (gekürzt, enger filtern, z. B. mit raum)"
    return text


def _line_home(i: dict) -> str:
    return {"schalten": "Schaltet ein Gerät", "szene": "Führt eine Szene aus"}.get(i.get("aktion") or "", "Schaut in Home")


def _line_alarms(i: dict) -> str:
    return {"stellen": "Stellt einen Wecker", "timer": "Startet einen Timer", "loeschen": "Löscht einen Wecker"}.get(
        i.get("aktion") or "", "Schaut nach deinen Weckern")


def _line_location(i: dict) -> str:
    return {"wo": "Schaut, wo du bist", "ort_anlegen": "Merkt sich einen Ort", "ort_loeschen": "Löscht einen Ort"}.get(
        i.get("aktion") or "", "Schaut nach deinen Orten")


def prompt_hint(services: list[str], user_name: str) -> list[str]:
    parts = []
    if "home" in services:
        parts.append("`apple_home` für Licht, Steckdosen, Heizung, Rollos und Szenen in Apple Home (Schlösser, Türen, "
                     "Garagentore und Alarmanlage nur über die Freigabe-Karte, die das Werkzeug selbst anlegt)")
    if "alarms" in services:
        parts.append("`apple_wecker` für Wecker („weck mich um 6:45“) und Timer („Timer 10 Minuten“) auf dem iPhone")
    if "location" in services:
        parts.append("`apple_standort` für seinen aktuellen Standort und ortsabhängige Erinnerungen („wenn ich im Büro "
                     "bin …“); fragt nicht ungefragt nach dem Standort")
    return parts
