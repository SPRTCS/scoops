"""Demo-Modus und Ausgabenlimit (docs/demo-server.md).

**Ausgabenlimit** (für jede Installation nutzbar): `spend_limits` in config.json, z. B.
`{"spend_limits": {"daily_usd": 5, "monthly_usd": 25}}`. Gezählt wird alles, was in der Tabelle `usage` landet
(Chat-Läufe, Routinen, Aufgaben, Live-Gespräche), nach Tag bzw. Monat in Europe/Berlin. Ist ein Limit erreicht,
startet kein neuer Chat-Lauf und keine Aufgabe mehr; ein laufender Chat-Lauf bekommt höchstens das Restbudget.

**Demo-Modus** (`"demo": true` in config.json): für den öffentlich erreichbaren Demo-Server der App-Prüfung.
Der Server läuft dann mit einem festen, günstigen Modell und ohne alles, was nach außen wirkt oder den Mac berührt:

- nur die Werkzeuge aus `ALLOWED_TOOLS` (Gedächtnis, Routinen, Erinnerungen, Freigaben, Bibliothek, Fähigkeiten,
  andere Scoops, Websuche bei Anthropic). Kein Rechner, keine Shell, keine Apple-Dienste, kein Composio/MCP,
  kein Tresor, keine Aufgaben (Hintergrund-Agenten mit Shell), keine Eskalation auf ein teureres Modell.
- Mails: `mail_vorbereiten` zeigt die Mail-Karte mit einem Demo-Postfach; „Senden“ verschickt nichts.
- Kein KI-Abo (Claude Code/Codex), immer API-Schlüssel.
- Endpunkte für Einstellungen, die den Mac berühren (Arbeitsordner, Rechner koppeln, Apple, Abos, Apps verbinden,
  Aufgaben starten), antworten mit 403.

Die Dateisystem-Trennung von Armans Daten übernimmt zusätzlich die macOS-Sandbox des Startskripts
(`Server/bin/demo-server`); der Demo-Modus allein ist dafür nicht gedacht.
"""

from __future__ import annotations

import re

from .i18n import N_, tx
from .profile import _read_config

MODEL = "claude-haiku-5-5"
MAIL_ACCOUNT = {"id": "demo", "alias": "Demo", "email": "demo@scoops.example"}
DISABLED_TEXT = N_("Auf dem Demo-Server ausgeschaltet.")  # Ausgabe übersetzt (server.py, i18n.translate)

# Chat-Werkzeuge, die im Demo-Modus bleiben. Alles andere (auch neue Werkzeuge) fehlt, bis es hier steht.
ALLOWED_TOOLS = frozenset({
    "merken", "vergessen", "erinnerung_suchen",
    "routine_anlegen", "routine_aendern", "routine_loeschen", "erinnerung_setzen",
    "freigabe_anfordern", "mail_vorbereiten", "reagieren",
    "datei_speichern", "dateien_auflisten", "datei_lesen", "link_merken",
    "faehigkeit_speichern", "faehigkeit_lesen", "faehigkeit_loeschen",
    "scoop_schreiben", "an_scoop_uebergeben",
    "scoops_ueberblick", "chat_lesen", "scoop_details", "scoop_verbessern",
})

# (Methode oder "*", Pfad-Regex) – im Demo-Modus gesperrt
_BLOCKED = [
    ("*", r"/api/settings/workspace(/.*)?"),
    ("*", r"/api/settings/abos(/.*)?"),
    ("*", r"/api/setup/.*"),
    ("*", r"/api/nodes/(pair|claim)"),
    ("PATCH", r"/api/nodes/[^/]+"),
    ("*", r"/api/computer/.*"),
    ("PATCH", r"/api/apple"),
    ("POST", r"/api/apple/.*"),
    ("*", r"/api/connections/.*"),
    ("POST", r"/api/vault"),
    ("PATCH", r"/api/vault/[^/]+"),
    ("POST", r"/api/bots/[^/]+/tasks"),
    ("POST", r"/api/tasks"),
    ("POST", r"/api/tasks/[^/]+/(start|rework|continue)"),
    ("PATCH", r"/api/tasks/settings"),
    ("POST", r"/api/transcribe"),
    ("*", r"/api/voice/.*"),
    ("POST", r"/api/initiative/run"),
    ("PATCH", r"/api/settings/initiative"),
    ("PATCH", r"/api/bots/[^/]+/sharing"),
    ("POST", r"/api/shares/refresh"),
    ("*", r"/mcp/(task|abo)"),
]
_BLOCKED_RE = [(m, re.compile(p + r"/?$")) for m, p in _BLOCKED]


def active(cfg: dict | None = None) -> bool:
    cfg = _read_config() if cfg is None else cfg
    return bool(cfg.get("demo"))


def blocked(method: str, path: str, cfg: dict | None = None) -> bool:
    """Ist dieser Endpunkt im Demo-Modus gesperrt?"""
    if not active(cfg):
        return False
    method = method.upper()
    return any((m == "*" or m == method) and rx.match(path) for m, rx in _BLOCKED_RE)


def filter_tools(tools: list) -> list:
    return [t for t in tools if t.schema["name"] in ALLOWED_TOOLS]


def prompt_note() -> str:
    return ("[Demo server] This server is a demo for app review. LANGUAGE: always reply in the language of the user's "
            "latest message – if they write English, answer in English, even though these instructions are German. "
            "You have no computer, no shell, no connected accounts and no background tasks. Prepare emails with "
            "mail_vorbereiten (account \"Demo\"); even after the user taps Send, nothing really leaves the demo – say "
            "so honestly. Keep answers short and friendly.")


# -- Ausgabenlimit ------------------------------------------------------------------

def limits(cfg: dict | None = None) -> tuple[float | None, float | None]:
    """(Tageslimit, Monatslimit) in US-Dollar, None = ohne Limit."""
    cfg = _read_config() if cfg is None else cfg
    raw = cfg.get("spend_limits") if isinstance(cfg.get("spend_limits"), dict) else {}

    def num(v) -> float | None:
        try:
            f = float(v)
        except (TypeError, ValueError):
            return None
        return f if f > 0 else None
    return num(raw.get("daily_usd")), num(raw.get("monthly_usd"))


def spent(db) -> tuple[float, float]:
    """(heute, dieser Monat) in US-Dollar, Europe/Berlin. Abo-Läufe kosten 0 $ und zählen nicht."""
    from .db import now
    t = now()
    day, month = t.strftime("%Y-%m-%d"), t.strftime("%Y-%m")
    r = db.one("SELECT COALESCE(SUM(CASE WHEN substr(created_at,1,10)=? THEN dollars END),0) d, "
               "COALESCE(SUM(dollars),0) m FROM usage WHERE substr(created_at,1,7)=? AND billing IS NOT 'abo'",
               (day, month))
    return (float(r["d"] or 0), float(r["m"] or 0)) if r else (0.0, 0.0)


def budget_left(db, cfg: dict | None = None) -> tuple[float | None, str | None]:
    """(Restbudget in $ oder None = unbegrenzt, Hinweistext wenn erschöpft)."""
    daily, monthly = limits(cfg)
    if daily is None and monthly is None:
        return None, None
    today, month = spent(db)
    left = min(x for x in ((daily - today) if daily else None, (monthly - month) if monthly else None)
               if x is not None)
    if left >= 0.01:
        return left, None
    if daily and today >= daily - 0.01:
        return 0.0, tx("Das Tageslimit dieses Servers ({limit:.2f} $) ist erreicht. Morgen geht es weiter. "
                       "(Daily spending limit of this server reached; it resets at midnight, Berlin time.)", limit=daily)
    return 0.0, tx("Das Monatslimit dieses Servers ({limit:.2f} $) ist erreicht. "
                   "(Monthly spending limit of this server reached.)", limit=monthly)
