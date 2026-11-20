"""Stummschalten und Ruhezeiten (docs/ruhe.md, App 1.3).

Beides gilt **pro Person**: für den Inhaber des Servers und getrennt für jeden Gast eines geteilten Scoops
(docs/sharing.md). Die Einstellungen liegen auf dem Server, damit sie auf allen Geräten gelten und Mitteilungen
schon an der Quelle wegfallen (push.py), also auch auf der Apple Watch.

- **Stummschalten** (pro Chat, Scoop oder Gruppe): keine Mitteilungen aus diesem Chat, bis zu einem Zeitpunkt oder
  dauerhaft. Der Ungelesen-Zähler läuft weiter; am App-Symbol zählen stumme Chats nicht mit.
- **Ruhezeiten** (pro Person): Uhrzeit von/bis, Wochentage, Zeitzone des Geräts. In der Ruhezeit kommen Mitteilungen
  still an (`interruption-level: passive`, ohne Ton).

Was trotzdem durchkommt:
- **Freigabe-Anfragen**: immer trotz Stummschaltung (sonst bleibt der Scoop unbemerkt hängen); in der Ruhezeit
  normal, solange „Freigaben trotzdem melden“ an ist (Standard), sonst still.
- **Erinnerungen**, die jemand ausdrücklich auf eine Uhrzeit gelegt hat (`erinnerung_setzen`): immer normal.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import Depends, HTTPException

from .db import TZ, now_iso
from .i18n import tx
from .sharing import Principal

OWNER = ""  # user_id des Inhabers in den Tabellen (Gäste: ihre Konto-ID)
MAX_MUTE = timedelta(days=366)
QUIET_DEFAULT = {"enabled": False, "start": "22:00", "end": "07:00", "days": [1, 2, 3, 4, 5, 6, 7], "approvals": True,
                 "timezone": "Europe/Berlin"}
_HHMM = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


class RuheError(ValueError):
    """Ungültige Eingabe (Text ist für Menschen gedacht)."""


def _user(user_id: str | None) -> str:
    return user_id or OWNER


def _minutes(hhmm: str) -> int:
    return int(hhmm[:2]) * 60 + int(hhmm[3:])


def _zone(name) -> ZoneInfo | None:
    if not isinstance(name, str) or not name or len(name) > 64:
        return None
    try:
        return ZoneInfo(name)
    except Exception:  # noqa: BLE001 – unbekannte Zone, kaputter Name
        return None


def quiet_at(q: dict, when: datetime) -> bool:
    """Liegt `when` in der Ruhezeit `q`? Gerechnet wird in der Zeitzone der Person (Sommerzeit inklusive).
    Eine Ruhezeit über Mitternacht gehört zu dem Wochentag, an dem sie beginnt."""
    if not q.get("enabled"):
        return False
    local = when.astimezone(_zone(q.get("timezone")) or TZ)
    days = set(q.get("days") or [])
    m, s, e = local.hour * 60 + local.minute, _minutes(q["start"]), _minutes(q["end"])
    today, yesterday = local.isoweekday(), (local - timedelta(days=1)).isoweekday()
    if s == e:  # ganzer Tag
        return today in days
    if s < e:
        return s <= m < e and today in days
    return (m >= s and today in days) or (m < e and yesterday in days)


class Ruhe:
    def __init__(self, db):
        self.db = db
        db.q("CREATE TABLE IF NOT EXISTS mutes (user_id TEXT NOT NULL, chat_id TEXT NOT NULL, until TEXT, "
             "created_at TEXT NOT NULL, PRIMARY KEY (user_id, chat_id))")  # until NULL = dauerhaft, sonst UTC-ISO
        db.q("CREATE TABLE IF NOT EXISTS quiet_hours (user_id TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)")

    # -- Stummschalten ---------------------------------------------------------------------------------
    @staticmethod
    def _now() -> datetime:
        return datetime.now(timezone.utc)

    def _row(self, user_id: str | None, chat_id: str):
        r = self.db.one("SELECT until FROM mutes WHERE user_id=? AND chat_id=?", (_user(user_id), chat_id))
        if r and r["until"] and datetime.fromisoformat(r["until"]) <= self._now():
            return None  # abgelaufen (räumt `sweep` weg)
        return r

    def is_muted(self, user_id: str | None, chat_id: str) -> bool:
        return self._row(user_id, chat_id) is not None

    def mute_json(self, user_id: str | None, chat_id: str) -> dict:
        """Für das Scoop- bzw. Gruppen-JSON: `{"muted": bool, "until": "<ISO>" | null}` (`until` null = dauerhaft).
        Das Feld ist immer da, damit die App daran erkennt, dass der Server stummschalten kann."""
        r = self._row(user_id, chat_id)
        return {"muted": r is not None, "until": r["until"] if r else None}

    def parse_mute(self, body: dict, user_id: str | None = None) -> tuple[bool, datetime | None]:
        """Body von `PUT /api/chats/{id}/mute` → (stumm?, bis). `{"forever": true}`, `{"until": "<ISO>"}` oder
        `{"minutes": 60}`; alles andere (auch `{}` und `{"until": null}`) hebt die Stummschaltung auf."""
        if not isinstance(body, dict):
            raise RuheError(tx("Erwartet wird ein JSON-Objekt"))
        if body.get("forever") is True:
            return True, None
        until = None
        if body.get("minutes") is not None:
            m = body["minutes"]
            if isinstance(m, bool) or not isinstance(m, (int, float)) or m != m or m <= 0:
                raise RuheError(tx("minutes muss eine positive Zahl sein"))
            until = self._now() + timedelta(minutes=min(float(m), MAX_MUTE.total_seconds() / 60))
        elif body.get("until"):
            try:
                until = datetime.fromisoformat(str(body["until"]).strip().replace("Z", "+00:00"))
            except ValueError:
                raise RuheError(tx("until muss ein Zeitpunkt im ISO-Format sein, z. B. 2026-11-20T07:00:00+01:00")) from None
            if until.tzinfo is None:  # ohne Zone: Zeitzone der Person (aus den Ruhezeiten), sonst die des Servers
                until = until.replace(tzinfo=_zone(self.quiet(user_id)["timezone"]) or TZ)
            if until <= self._now():
                raise RuheError(tx("Der Zeitpunkt liegt in der Vergangenheit"))
            if until - self._now() > MAX_MUTE:
                raise RuheError(tx("Höchstens ein Jahr; für länger bitte dauerhaft stummschalten"))
        else:
            return False, None
        return True, until

    def set_mute(self, user_id: str | None, chat_id: str, muted: bool, until: datetime | None = None) -> dict:
        if not muted:
            self.db.q("DELETE FROM mutes WHERE user_id=? AND chat_id=?", (_user(user_id), chat_id))
        else:
            iso = until.astimezone(timezone.utc).isoformat(timespec="seconds") if until else None
            self.db.q("INSERT OR REPLACE INTO mutes(user_id,chat_id,until,created_at) VALUES(?,?,?,?)",
                      (_user(user_id), chat_id, iso, now_iso()))
        return self.mute_json(user_id, chat_id)

    def sweep(self) -> list[tuple[str | None, str]]:
        """Abgelaufene Stummschaltungen entfernen → [(Konto-ID oder None für den Inhaber, Chat-ID)]."""
        ts = self._now().isoformat(timespec="seconds")
        rows = self.db.q("SELECT user_id, chat_id FROM mutes WHERE until IS NOT NULL AND until<=?", (ts,))
        for r in rows:
            self.db.q("DELETE FROM mutes WHERE user_id=? AND chat_id=? AND until IS NOT NULL AND until<=?",
                      (r["user_id"], r["chat_id"], ts))
        return [(r["user_id"] or None, r["chat_id"]) for r in rows]

    def unread_chat_count(self) -> int:
        """Zahl am App-Symbol des Inhabers: Chats mit Ungelesenem, ohne stumme Chats."""
        ids = [r["id"] for r in self.db.q("SELECT id FROM bots WHERE unread>0 UNION ALL SELECT id FROM groups WHERE unread>0")]
        return sum(1 for i in ids if not self.is_muted(None, i))

    # -- Ruhezeiten --------------------------------------------------------------------------------------
    def quiet(self, user_id: str | None = None) -> dict:
        r = self.db.one("SELECT value FROM quiet_hours WHERE user_id=?", (_user(user_id),))
        try:
            stored = json.loads(r["value"]) if r else {}
        except ValueError:
            stored = {}
        return {**QUIET_DEFAULT, **{k: v for k, v in stored.items() if k in QUIET_DEFAULT}}

    def set_quiet(self, user_id: str | None, body: dict) -> dict:
        """Teiländerung (nur bekannte Felder). Ungültige Werte → RuheError."""
        if not isinstance(body, dict):
            raise RuheError(tx("Erwartet wird ein JSON-Objekt"))
        q = self.quiet(user_id)
        for k in ("enabled", "approvals"):
            if k in body:
                if not isinstance(body[k], bool):
                    raise RuheError(tx("{field} muss true oder false sein", field=k))
                q[k] = body[k]
        for k in ("start", "end"):
            if k in body:
                if not isinstance(body[k], str) or not _HHMM.match(body[k]):
                    raise RuheError(tx("{field} muss eine Uhrzeit im Format HH:MM sein", field=k))
                q[k] = body[k]
        if "days" in body:
            d = body["days"]
            if not isinstance(d, list) or any(isinstance(x, bool) or not isinstance(x, int) or not 1 <= x <= 7 for x in d):
                raise RuheError(tx("days: Wochentage als Zahlen 1 (Montag) bis 7 (Sonntag)"))
            q["days"] = sorted(set(d))
        if "timezone" in body:
            if _zone(body["timezone"]) is None:
                raise RuheError(tx("timezone: unbekannte Zeitzone (erwartet z. B. Europe/Berlin)"))
            q["timezone"] = body["timezone"]
        self.db.q("INSERT OR REPLACE INTO quiet_hours(user_id,value,updated_at) VALUES(?,?,?)",
                  (_user(user_id), json.dumps(q), now_iso()))
        return q

    def in_quiet(self, user_id: str | None = None, when: datetime | None = None) -> bool:
        return quiet_at(self.quiet(user_id), when or self._now())

    # -- Entscheidung für eine Mitteilung ------------------------------------------------------------------
    def delivery(self, user_id: str | None, chat_id: str | None, kind: str = "message",
                 when: datetime | None = None) -> str | None:
        """Wie eine Mitteilung bei dieser Person ankommt: `"normal"`, `"passive"` (still, in der Ruhezeit) oder
        `None` (gar nicht, Chat ist stumm). `kind`: `message`, `approval` (Freigabe-Anfrage) oder `reminder`
        (Erinnerung, die jemand ausdrücklich auf eine Uhrzeit gelegt hat)."""
        if kind == "reminder":
            return "normal"
        q = self.quiet(user_id)
        quiet = quiet_at(q, when or self._now())
        if kind == "approval":
            return "passive" if quiet and not q["approvals"] else "normal"
        if chat_id and self.is_muted(user_id, chat_id):
            return None
        return "passive" if quiet else "normal"


# -- Endpunkte --------------------------------------------------------------------------------------------
def register(app, *, ruhe: Ruhe, shared, service, events, pusher, guest_bot_view):
    """Hängt die Endpunkte an die FastAPI-App (server.py). Gäste geteilter Scoops dürfen ihre eigenen Einstellungen
    ändern (`shared(...)`), sehen und ändern aber nie die des Inhabers oder anderer Gäste.
    Rückgabe: Funktion für den Planer (abgelaufene Stummschaltungen aufräumen)."""
    def publish_chat(user_id: str | None, chat_id: str, share=None) -> None:
        """Geänderte Stummschaltung an die Geräte genau dieser Person melden."""
        if user_id:
            sh = share or (service.shares.share(user_id, chat_id, refresh_on_miss=False) if service.shares else None)
            view = guest_bot_view(chat_id, sh) if sh else None
            if view:
                events.send_user(user_id, "bot.updated", view)
            return
        if chat_id.startswith("g_"):
            g = service.group_json(chat_id)
            if g:
                events.publish("group.updated", g)
        else:
            b = service.bot_json(chat_id)
            if b:
                events.publish("bot.updated", b)
        pusher.badge_changed()  # stumme Chats zählen am App-Symbol nicht mit

    @app.put("/api/chats/{chat_id}/mute")
    def put_mute(chat_id: str, body: dict | None = None, p: Principal = Depends(shared("read", via="chat_id"))):
        """Chat stummschalten bzw. Stummschaltung aufheben – für die anfragende Person (Inhaber oder Gast)."""
        if not service.chat_exists(chat_id):
            raise HTTPException(404, tx("Chat nicht gefunden"))
        uid = None if p.is_owner else p.user_id
        try:
            muted, until = ruhe.parse_mute(body or {}, uid)
        except RuheError as e:
            raise HTTPException(400, str(e)) from None
        state = ruhe.set_mute(uid, chat_id, muted, until)
        publish_chat(uid, chat_id, p.share)
        return {"chat_id": chat_id, "mute": state}

    @app.get("/api/settings/quiet-hours")
    def get_quiet(p: Principal = Depends(shared(via="any"))):
        uid = None if p.is_owner else p.user_id
        return {**ruhe.quiet(uid), "active": ruhe.in_quiet(uid)}

    @app.patch("/api/settings/quiet-hours")
    def patch_quiet(body: dict | None = None, p: Principal = Depends(shared(via="any"))):
        uid = None if p.is_owner else p.user_id
        try:
            q = ruhe.set_quiet(uid, body or {})
        except RuheError as e:
            raise HTTPException(400, str(e)) from None
        data = {**q, "active": ruhe.in_quiet(uid)}
        if uid:
            events.send_user(uid, "quiet_hours.updated", data)
        else:
            events.publish("quiet_hours.updated", data)  # geht nur an den Inhaber (Gast-Filter kennt den Typ nicht)
        return data

    def tick() -> None:
        """Planer: abgelaufene Stummschaltungen entfernen und den Geräten der Person melden."""
        for uid, chat_id in ruhe.sweep():
            publish_chat(uid, chat_id)

    return tick
