"""Apple-Dienste (Server 1.17/1.18): Erinnerungen, Kalender und Kontakte über einen „Apple-Rechner“,
Home, Wecker und Standort über das iPhone (apple_device.py).

Die Mac-App „AIS Scoops Server“ (Ziel ScoopsConnect) hat die echten macOS-Freigaben (EventKit, Contacts) und ist
ohnehin per WebSocket mit dem Server verbunden (`/api/nodes/link`). Die Scoops bekommen die Werkzeuge
`apple_erinnerungen`, `apple_kalender` und `apple_kontakte`; der Server leitet jede Aktion als Befehl `apple.*` an
den Apple-Rechner weiter (siehe docs/scoops-connect.md). Dank iCloud erscheinen Änderungen sofort auf dem iPhone.

Apple-Rechner: config.json `apple_node` (ausdrücklich gewählt), sonst der Rechner auf demselben Mac wie der Server
(gleiche Geräte-ID wie Scoops Connect sie meldet), sonst `default_computer_node`. Ein Werkzeug erscheint nur, wenn
der Dienst eingeschaltet ist (`apple_services`), der Rechner verbunden ist und dort die Freigabe erteilt wurde.
Gäste geteilter Scoops bekommen diese Werkzeuge nie (sharing.NEVER_FOR_GUESTS).
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import threading
from typing import Callable

from . import apple_device
from .apple_device import AppleDevices, AppleDeviceError
from .computer import ComputerError

SERVICES = ("reminders", "calendar", "contacts")
LABEL = {"reminders": "Erinnerungen", "calendar": "Kalender", "contacts": "Kontakte"}
TOOL = {"reminders": "apple_erinnerungen", "calendar": "apple_kalender", "contacts": "apple_kontakte"}
TOOL_NAMES = frozenset(TOOL.values())
# Freigabe-Zustände, wie Scoops Connect sie im hello/state meldet (`apple: {reminders: "granted", …}`)
PERMISSIONS = {"granted", "denied", "not_determined", "restricted", "write_only", "disabled", "unknown"}
PRIORITY_IN = {"keine": "none", "niedrig": "low", "mittel": "medium", "hoch": "high"}
MAX_RESULT = 20000


def normalize_grants(raw) -> dict[str, str]:
    """`{reminders: true|"granted"|…}` → `{reminders: "granted", calendar: …, contacts: …}` (Unbekanntes → unknown)."""
    out = {s: "unknown" for s in SERVICES}
    if not isinstance(raw, dict):
        return out
    for s in SERVICES:
        v = raw.get(s)
        if v is True:
            out[s] = "granted"
        elif v is False:
            out[s] = "denied"
        elif isinstance(v, str):
            v = v.strip().lower().replace("-", "_").replace("notdetermined", "not_determined").replace("writeonly", "write_only")
            out[s] = v if v in PERMISSIONS else "unknown"
    return out


_device_lock = threading.Lock()
_device_id: str | None = None
_device_checked = False


def local_device_id() -> str | None:
    """Geräte-ID dieses Macs im selben Format wie Scoops Connect (`Pairing.deviceID`): „mac-“ + 24 Hex-Zeichen
    aus SHA-256("ais-scoops-node:" + IOPlatformUUID). Damit erkennt der Server „seinen“ Rechner."""
    global _device_id, _device_checked
    with _device_lock:
        if _device_checked:
            return _device_id
        _device_checked = True
        try:
            out = subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True,
                                 text=True, timeout=5).stdout
            m = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', out)
            if m:
                digest = hashlib.sha256(("ais-scoops-node:" + m.group(1)).encode()).digest()
                _device_id = "mac-" + digest[:12].hex()
        except Exception:  # noqa: BLE001 – kein macOS / ioreg fehlt
            _device_id = None
        return _device_id


class AppleError(RuntimeError):
    pass


class Apple:
    """Apple-Dienste: Konfiguration, Auswahl des Apple-Rechners, Weiterleitung und Werkzeuge."""

    def __init__(self, computers, load_config: Callable[[], dict], save_config: Callable[[dict], None],
                 user_name: Callable[[], str] = lambda: "Arman", devices: AppleDevices | None = None):
        self.computers = computers
        self.load_config = load_config
        self.save_config = save_config
        self.user_name = user_name
        self.devices = devices  # Home, Wecker, Standort über das iPhone (v1.18)

    # -- Konfiguration --------------------------------------------------------
    def enabled(self, cfg: dict | None = None) -> dict[str, bool]:
        cfg = self.load_config() if cfg is None else cfg
        raw = cfg.get("apple_services") if isinstance(cfg.get("apple_services"), dict) else {}
        return {s: bool(raw.get(s)) for s in SERVICES}

    def _node_hubs(self) -> list:
        return [h for h in self.computers.all() if h.node_id != "vm" and getattr(h, "transport", None) is not None]

    def node(self, cfg: dict | None = None) -> tuple[object | None, str]:
        """(Hub des Apple-Rechners oder None, Quelle: config | local | default | none)."""
        cfg = self.load_config() if cfg is None else cfg
        chosen = cfg.get("apple_node")
        if chosen and chosen != "vm":
            hub = self.computers.get(chosen)
            if hub is not None and hub.node_id == chosen:
                return hub, "config"
        dev = local_device_id()
        if dev:
            rows = self.computers.db.q("SELECT id FROM nodes WHERE device_id=? ORDER BY created_at", (dev,))
            for r in rows:
                hub = self.computers.get(r["id"])
                if hub is not None and hub.node_id == r["id"]:
                    return hub, "local"
        default = cfg.get("default_computer_node")
        if default and default != "vm":
            hub = self.computers.get(default)
            if hub is not None and hub.node_id == default:
                return hub, "default"
        return None, "none"

    @staticmethod
    def grants_of(hub) -> dict[str, str]:
        return normalize_grants(getattr(hub.transport, "apple", None)) if hub is not None else normalize_grants(None)

    def available(self, service: str, cfg: dict | None = None) -> bool:
        cfg = self.load_config() if cfg is None else cfg
        if not self.enabled(cfg).get(service):
            return False
        hub, _ = self.node(cfg)
        return bool(hub is not None and hub.transport.online and self.grants_of(hub)[service] == "granted")

    def active_services(self) -> list[str]:
        """Verfügbare Dienste: Mac (reminders, calendar, contacts) und iPhone (home, alarms, location)."""
        cfg = self.load_config()
        out = [s for s in SERVICES if self.available(s, cfg)]
        if self.devices is not None:
            out += [s for s in apple_device.SERVICES if self.devices.available(s, cfg)]
        return out

    # -- API ------------------------------------------------------------------
    def status(self) -> dict:
        cfg = self.load_config()
        hub, source = self.node(cfg)
        enabled = self.enabled(cfg)
        grants = self.grants_of(hub)
        online = bool(hub is not None and hub.transport.online)
        services = []
        for s in SERVICES:
            perm = grants[s]
            if hub is None:
                st, hint = "no_node", "Kein Mac mit AIS Scoops Server verbunden."
            elif not online:
                st, hint = "offline", f"„{hub.name}“ ist gerade nicht verbunden."
            elif perm == "unknown":
                st, hint = "needs_update", f"AIS Scoops Server auf „{hub.name}“ ist zu alt. Bitte aktualisieren."
            elif perm != "granted":
                st, hint = "needs_permission", "Auf dem Mac in AIS Scoops Server freigeben."
            elif not enabled[s]:
                st, hint = "off", None
            else:
                st, hint = "ready", None
            services.append({"id": s, "name": LABEL[s], "tool": TOOL[s], "enabled": enabled[s], "permission": perm,
                             "available": st == "ready", "status": st, "hint": hint,
                             "node_id": hub.node_id if hub is not None else None})
        nodes = [{"id": h.node_id, "name": h.name, "online": bool(h.transport.online), "apple": self.grants_of(h)}
                 for h in self._node_hubs()]
        out = {"node_id": hub.node_id if hub is not None else None, "node_name": hub.name if hub is not None else None,
               "node_online": online, "node_source": source, "node_choice": cfg.get("apple_node") or "auto",
               "nodes": nodes, "services": services}
        if self.devices is not None:  # v1.18: eigene Liste, damit ältere Apps die neuen Dienste nicht falsch zeigen
            out.update(self.devices.status(cfg))
        return out

    def patch(self, body: dict) -> dict:
        cfg = self.load_config()
        raw = dict(cfg.get("apple_services") if isinstance(cfg.get("apple_services"), dict) else {})
        for s in SERVICES:
            if s in body:
                if not isinstance(body[s], bool):
                    raise ValueError(f"{s}: true oder false")
                raw[s] = body[s]
        cfg["apple_services"] = raw
        if self.devices is not None:
            self.devices.patch(body, cfg)  # Home/Wecker/Standort und Gerät; wirft ValueError/KeyError vor dem Speichern
        keys = SERVICES + (apple_device.SERVICES if self.devices is not None else ())
        cfg["apple_services"] = {s: bool(cfg["apple_services"].get(s)) for s in keys}
        if "node" in body:
            nid = str(body.get("node") or "").strip()
            if nid in ("", "auto"):
                cfg.pop("apple_node", None)
            else:
                hub = self.computers.get(nid)
                if nid == "vm" or hub is None or hub.node_id != nid:
                    raise KeyError(nid)
                cfg["apple_node"] = nid
        self.save_config(cfg)
        return self.status()

    # -- Weiterleitung ----------------------------------------------------------
    def call(self, service: str, command: str, params: dict) -> dict:
        """Befehl an den Apple-Rechner; wirft AppleError mit einer Meldung, die der Scoop weitergeben kann."""
        who = self.user_name()
        cfg = self.load_config()
        hub, _ = self.node(cfg)
        if hub is None:
            raise AppleError(f"Kein Apple-Rechner verbunden: Auf keinem Mac läuft AIS Scoops Server mit Verbindung zu "
                             f"diesem Server. Sag {who} Bescheid, statt es weiter zu versuchen.")
        if not hub.transport.online:
            raise AppleError(f"Der Apple-Rechner „{hub.name}“ ist offline (AIS Scoops Server ist dort nicht verbunden). "
                             f"{LABEL[service]} gehen erst wieder, wenn er online ist. Sag {who} Bescheid, statt es weiter "
                             "zu versuchen.")
        if not self.enabled(cfg)[service]:
            raise AppleError(f"{LABEL[service]} sind in AIS Scoops ausgeschaltet ({who} kann sie unter Apps verbinden → "
                             "Apple einschalten).")
        perm = self.grants_of(hub)[service]
        if perm != "granted":
            raise AppleError(f"Auf „{hub.name}“ fehlt die Freigabe für {LABEL[service]} ({perm}). {who} muss sie dort in "
                             "AIS Scoops Server unter „Apple-Dienste“ erteilen. Sag es kurz, statt es weiter zu versuchen.")
        try:
            data = hub.transport.send(command, params)
        except ComputerError as e:
            raise AppleError(str(e)) from e
        if not isinstance(data, dict):
            raise AppleError("Leere Antwort vom Apple-Rechner")
        if not data.get("success", False):
            raise AppleError(str(data.get("error") or "Unbekannter Fehler auf dem Apple-Rechner"))
        return {k: v for k, v in data.items() if k != "success"}

    # -- Werkzeuge ----------------------------------------------------------------
    def tools(self, make_tool: Callable, request_approval: Callable[[str, str, dict], str], chat_id: str = "",
              bot_id: str = "") -> list:
        """ExtraTools der verfügbaren Dienste. `make_tool(name, desc, props, req, fn, line)` wie in bots._tools,
        `request_approval(titel, details, action)` legt eine Freigabe-Karte an (Löschen, Schlösser …)."""
        out = self.devices.tools(make_tool, request_approval, chat_id, bot_id) if self.devices is not None else []
        cfg = self.load_config()
        services = [x for x in SERVICES if self.available(x, cfg)]
        if not services:
            return out
        s = {"type": "string"}
        if "reminders" in services:
            out.append(make_tool(
                TOOL["reminders"],
                "Apple-Erinnerungen (iCloud, erscheinen sofort auf iPhone/Mac). aktion: 'listen' (alle Listen), 'anzeigen' "
                "(Erinnerungen; Filter liste, status offen/erledigt/alle, faellig_bis, suche), 'anlegen' (titel, optional notiz, "
                "faellig, liste, prioritaet), 'aendern' (id + geänderte Felder; faellig '' entfernt das Datum), 'erledigen' "
                "(id; erledigt=false macht es rückgängig), 'loeschen' (id; braucht Freigabe). Datum als ISO 8601, z. B. "
                "2026-11-20T09:00 oder 2026-11-20 (ganztägig).",
                {"aktion": {"type": "string", "enum": ["listen", "anzeigen", "anlegen", "aendern", "erledigen", "loeschen"]},
                 "id": s, "titel": s, "notiz": s, "faellig": s, "faellig_bis": s, "liste": s,
                 "prioritaet": {"type": "string", "enum": ["keine", "niedrig", "mittel", "hoch"]},
                 "status": {"type": "string", "enum": ["offen", "erledigt", "alle"]}, "suche": s,
                 "erledigt": {"type": "boolean"}, "anzahl": {"type": "integer"}},
                ["aktion"], lambda i: self._reminders(i, request_approval), _line_reminders))
        if "calendar" in services:
            out.append(make_tool(
                TOOL["calendar"],
                "Apple-Kalender (iCloud und alle auf dem Mac eingerichteten Kalender). aktion: 'kalender' (alle Kalender), "
                "'termine' (von/bis, optional kalender, suche; Standard: heute), 'anlegen' (titel, beginn, optional ende, "
                "ganztaegig, kalender, ort, notiz, erinnerung_minuten), 'aendern' (id + geänderte Felder), 'loeschen' (id; "
                "braucht Freigabe). Bei Serienterminen gilt eine Änderung nur für diesen Termin, außer alle_folgenden=true. "
                "Zeiten als ISO 8601 (Berliner Zeit, wenn ohne Zeitzone).",
                {"aktion": {"type": "string", "enum": ["kalender", "termine", "anlegen", "aendern", "loeschen"]},
                 "id": s, "von": s, "bis": s, "kalender": s, "suche": s, "titel": s, "beginn": s, "ende": s,
                 "ganztaegig": {"type": "boolean"}, "ort": s, "notiz": s, "erinnerung_minuten": {"type": "integer"},
                 "alle_folgenden": {"type": "boolean"}, "anzahl": {"type": "integer"}},
                ["aktion"], lambda i: self._calendar(i, request_approval), _line_calendar))
        if "contacts" in services:
            out.append(make_tool(
                TOOL["contacts"],
                f"{self.user_name()}s Apple-Kontakte (nur lesen). aktion: 'suchen' (suche = Name, Firma, Telefonnummer oder "
                "Mailadresse) oder 'geburtstage' (anstehende Geburtstage der nächsten tage Tage, Standard 30). Liefert Namen, "
                "Telefonnummern, Mailadressen, Geburtstag, Firma und Adressen.",
                {"aktion": {"type": "string", "enum": ["suchen", "geburtstage"]}, "suche": s,
                 "tage": {"type": "integer"}, "anzahl": {"type": "integer"}},
                ["aktion"], self._contacts, lambda i: "Schaut in deine Kontakte"))
        return out

    # Die Handler geben Text zurück; Fehler als Text (der Scoop soll sie verstehen und weitergeben).
    def _run(self, service: str, command: str, params: dict) -> str:
        try:
            data = self.call(service, command, params)
        except AppleError as e:
            return f"Fehler: {e}"
        text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        if len(text) > MAX_RESULT:
            text = text[:MAX_RESULT] + " … (gekürzt, enger filtern oder anzahl setzen)"
        return text

    def _reminders(self, i: dict, request_approval) -> str:
        a = i.get("aktion")
        if a == "listen":
            return self._run("reminders", "apple.reminders.lists", {})
        if a == "anzeigen":
            status = {"offen": "open", "erledigt": "completed", "alle": "all"}.get(i.get("status") or "offen", "open")
            p = _clean({"list": i.get("liste"), "status": status, "due_before": i.get("faellig_bis"),
                        "query": i.get("suche"), "limit": _limit(i.get("anzahl"), 50)})
            return self._run("reminders", "apple.reminders.list", p)
        if a == "anlegen":
            if not (i.get("titel") or "").strip():
                return "Fehler: titel fehlt."
            p = _clean({"title": i["titel"].strip(), "notes": i.get("notiz"), "due": i.get("faellig"),
                        "list": i.get("liste"), "priority": PRIORITY_IN.get(i.get("prioritaet") or "")})
            return self._run("reminders", "apple.reminders.add", p)
        if not (i.get("id") or "").strip():
            return "Fehler: id fehlt (erst mit aktion 'anzeigen' suchen)."
        rid = i["id"].strip()
        if a == "aendern":
            p = {"id": rid, **_clean({"title": i.get("titel"), "notes": i.get("notiz"), "list": i.get("liste"),
                                      "priority": PRIORITY_IN.get(i.get("prioritaet") or "")})}
            if "faellig" in i and i["faellig"] is not None:
                p["due"] = i["faellig"]  # "" entfernt das Fälligkeitsdatum
            if isinstance(i.get("erledigt"), bool):
                p["completed"] = i["erledigt"]
            return self._run("reminders", "apple.reminders.update", p)
        if a == "erledigen":
            done = i.get("erledigt") if isinstance(i.get("erledigt"), bool) else True
            return self._run("reminders", "apple.reminders.complete", {"id": rid, "completed": done})
        if a == "loeschen":
            try:
                item = self.call("reminders", "apple.reminders.get", {"id": rid}).get("reminder") or {}
            except AppleError as e:
                return f"Fehler: {e}"
            title = f"Erinnerung löschen: „{item.get('title') or rid}“"
            details = "\n".join(x for x in (f"Liste: {item.get('list')}" if item.get("list") else "",
                                            f"Fällig: {item.get('due')}" if item.get("due") else "",
                                            (item.get("notes") or "")[:300]) if x)
            return request_approval(title, details or "Wird aus Apple-Erinnerungen gelöscht.",
                                    {"kind": "apple", "service": "reminders", "command": "apple.reminders.delete",
                                     "params": {"id": rid}, "label": item.get("title") or rid})
        return "Fehler: unbekannte aktion."

    def _calendar(self, i: dict, request_approval) -> str:
        a = i.get("aktion")
        if a == "kalender":
            return self._run("calendar", "apple.calendar.calendars", {})
        if a == "termine":
            p = _clean({"from": i.get("von"), "to": i.get("bis"), "calendar": i.get("kalender"), "query": i.get("suche"),
                        "limit": _limit(i.get("anzahl"), 100)})
            return self._run("calendar", "apple.calendar.events", p)
        span = "future" if i.get("alle_folgenden") else "this"
        if a == "anlegen":
            if not (i.get("titel") or "").strip() or not (i.get("beginn") or "").strip():
                return "Fehler: titel und beginn sind nötig."
            p = _clean({"title": i["titel"].strip(), "start": i["beginn"], "end": i.get("ende"),
                        "all_day": i.get("ganztaegig") if isinstance(i.get("ganztaegig"), bool) else None,
                        "calendar": i.get("kalender"), "location": i.get("ort"), "notes": i.get("notiz"),
                        "alarm_minutes": i.get("erinnerung_minuten") if isinstance(i.get("erinnerung_minuten"), int) else None})
            return self._run("calendar", "apple.calendar.add", p)
        if not (i.get("id") or "").strip():
            return "Fehler: id fehlt (erst mit aktion 'termine' suchen)."
        eid = i["id"].strip()
        if a == "aendern":
            p = {"id": eid, "span": span, **_clean({
                "title": i.get("titel"), "start": i.get("beginn"), "end": i.get("ende"), "calendar": i.get("kalender"),
                "location": i.get("ort"), "notes": i.get("notiz"),
                "all_day": i.get("ganztaegig") if isinstance(i.get("ganztaegig"), bool) else None,
                "alarm_minutes": i.get("erinnerung_minuten") if isinstance(i.get("erinnerung_minuten"), int) else None})}
            return self._run("calendar", "apple.calendar.update", p)
        if a == "loeschen":
            try:
                ev = self.call("calendar", "apple.calendar.get", {"id": eid}).get("event") or {}
            except AppleError as e:
                return f"Fehler: {e}"
            when = ev.get("start") or ""
            title = f"Termin löschen: „{ev.get('title') or eid}“" + (f" ({_short_dt(when)})" if when else "")
            details = "\n".join(x for x in (f"Kalender: {ev.get('calendar')}" if ev.get("calendar") else "",
                                            f"Beginn: {when}" if when else "", f"Ort: {ev.get('location')}" if ev.get("location") else "",
                                            "Alle folgenden Termine der Serie" if span == "future" and ev.get("recurring") else "")
                                if x)
            return request_approval(title, details or "Wird aus dem Apple-Kalender gelöscht.",
                                    {"kind": "apple", "service": "calendar", "command": "apple.calendar.delete",
                                     "params": {"id": eid, "span": span}, "label": ev.get("title") or eid})
        return "Fehler: unbekannte aktion."

    def _contacts(self, i: dict) -> str:
        a = i.get("aktion")
        limit = _limit(i.get("anzahl"), 20)
        if a == "geburtstage":
            days = max(1, min(int(i.get("tage") or 30), 366)) if str(i.get("tage") or "30").lstrip("-").isdigit() else 30
            return self._run("contacts", "apple.contacts.search", _clean({"query": i.get("suche"), "birthdays_days": days,
                                                                          "limit": limit}))
        q = (i.get("suche") or "").strip()
        if not q:
            return "Fehler: suche fehlt (Name, Firma, Telefonnummer oder Mailadresse)."
        return self._run("contacts", "apple.contacts.search", {"query": q, "limit": limit})

    def run_approved(self, action: dict) -> str:
        """Führt eine freigegebene Aktion (Löschen, Home) aus; Fehler als AppleError."""
        if action.get("service") in apple_device.SERVICES:
            if self.devices is None:
                raise AppleError("Kein iPhone angebunden")
            try:
                return self.devices.run_approved(action)
            except AppleDeviceError as e:
                raise AppleError(str(e)) from e
        service = action.get("service") if action.get("service") in SERVICES else "reminders"
        cmd = str(action.get("command") or "")
        if cmd not in ("apple.reminders.delete", "apple.calendar.delete"):
            raise AppleError("Unbekannte Aktion")
        self.call(service, cmd, dict(action.get("params") or {}))
        return action.get("label") or ""


def _clean(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None and v != ""}


def _limit(v, default: int) -> int:
    try:
        n = int(v)
    except (TypeError, ValueError):
        return default
    return max(1, min(n, 200)) if n > 0 else default


def _short_dt(iso: str) -> str:
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?", iso or "")
    if not m:
        return iso
    y, mo, d, hh, mm = m.groups()
    return f"{d}.{mo}.{y}" + (f", {hh}:{mm}" if hh else "")


def _line_reminders(i: dict) -> str:
    return {"anlegen": "Legt eine Erinnerung an", "aendern": "Ändert eine Erinnerung", "erledigen": "Hakt eine Erinnerung ab",
            "loeschen": "Bereitet das Löschen einer Erinnerung vor"}.get(i.get("aktion") or "", "Schaut in deine Erinnerungen")


def _line_calendar(i: dict) -> str:
    return {"anlegen": "Trägt einen Termin ein", "aendern": "Ändert einen Termin",
            "loeschen": "Bereitet das Löschen eines Termins vor"}.get(i.get("aktion") or "", "Schaut in deinen Kalender")


def prompt_hint(services: list[str], user_name: str) -> str | None:
    """Kurzer Systemprompt-Hinweis, wann die Apple-Werkzeuge statt Composio/Google Kalender dran sind."""
    if not services:
        return None
    device = apple_device.prompt_hint(services, user_name)
    device_note = ("Über sein iPhone (v1.18): " + "; ".join(device) + ". Ist das iPhone im Hintergrund, kann es bis zu "
                   "25 s dauern oder scheitern; dann kurz Bescheid sagen statt mehrfach zu versuchen.") if device else ""
    if not any(s in services for s in SERVICES):
        return "Apple-Dienste: " + device_note
    parts = []
    if "reminders" in services:
        parts.append(f"`apple_erinnerungen` für {user_name}s Erinnerungen und To-dos in Apple-Erinnerungen")
    if "calendar" in services:
        parts.append("`apple_kalender` für Termine in seinem Apple-Kalender (enthält auch eingebundene Google-/Exchange-Kalender)")
    if "contacts" in services:
        parts.append("`apple_kontakte` für Telefonnummern, Mailadressen, Geburtstage und Adressen aus seinen Kontakten")
    return ("Apple-Dienste (über seinen Mac, Änderungen erscheinen per iCloud sofort auf dem iPhone): " + "; ".join(parts) + ". "
            "Für Erinnerungen, Termine und Kontakte nimmst du zuerst diese Werkzeuge statt Composio/Google Kalender, außer "
            f"{user_name} nennt ausdrücklich Google Kalender oder ein bestimmtes Konto. „Erinnere mich an …“ ohne Uhrzeit-Ping "
            "im Chat ist eine Apple-Erinnerung; eine Nachricht von dir zu einem Zeitpunkt bleibt `erinnerung_setzen`. "
            "Anlegen und Ändern darfst du direkt. Löschen legt selbst eine Freigabe-Karte an (kein zusätzliches "
            "`freigabe_anfordern`). Nimm IDs immer aus einer "
            "vorherigen Abfrage, rate keine." + (" " + device_note if device_note else ""))
