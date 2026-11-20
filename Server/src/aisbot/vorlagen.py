"""Scoop-Vorlagen: einen Scoop als Datei weitergeben und bei sich anlegen (docs/vorlagen.md, App 1.3).

Eine Vorlage ist eine JSON-Datei (Endung `.scoop`, `"format": 1`) mit Name, Aussehen, Rolle, Charakter und
Anweisungen, Fähigkeiten, Routinen, bevorzugtem Modell und Hinweisen auf benötigte Verbindungen.

**Nie enthalten** (der Export liest diese Daten gar nicht erst): Gedächtnis, Chatverlauf, Dateien, Tresor, Konten und
Tokens von Verbindungen, Dauerfreigaben, Rechte (Rechner-Zugriff, Teilen), Nutzungsdaten, Name oder Adressen des
Besitzers.

**Eine Vorlage ist fremder Inhalt.** Der Import prüft streng (Größe, Längen, Typen, erlaubte Werte; unbekannte Felder
fallen weg, es gibt keine Pfade und nichts Ausführbares), legt alles in einem Schritt an oder gar nicht, mit
Standardrechten und ohne Dauerfreigaben. Routinen starten pausiert, und der neue Scoop läuft erst, wenn der Nutzer
ihm schreibt. Den Text des Zeitplans berechnet der Server selbst aus dem Cron-Ausdruck, statt dem der Datei zu trauen.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
from datetime import datetime, timedelta

from croniter import croniter
from fastapi import Depends, HTTPException, Request

from . import i18n
from .i18n import N_, translate, tx, txn

FORMAT = 1
TYPE = "ais-scoops-template"
MAX_BYTES = 1_500_000  # ganze Datei (mit Bild)
MAX_PHOTO_B64 = 600_000
PHOTO_SIZE = 256
LIMITS = {"name": 40, "label": 60, "description": 600, "character": 8000, "model": 80,
          "skills": 30, "skill_name": 80, "skill_description": 400, "skill_steps": 6000,
          "routines": 20, "routine_title": 80, "routine_prompt": 4000, "schedule": 100,
          "requires": 30, "require_name": 60, "require_note": 200}

SHAPES = {"bean", "pear", "cloud", "egg", "blob", "star", "drop", "bun", "ghost", "flower", "circle", "oval_tall",
          "oval_wide", "square", "rect_tall", "rect_wide", "triangle", "diamond", "hexagon", "heart", "arrow", "pill",
          "flower_round", "star_soft"}
EYES = {"lashes", "cat", "relaxed", "focused", "dashes", "happy", "skeptical", "calm", "dots", "ovals", "diamonds",
        "sleepy", "sparkle"}
ACCESSORIES = {"none", "beret", "bowtie", "glasses", "headphones", "cap", "flower", "crown", "beanie", "tophat", "cowboy",
               "partyhat", "wizard", "halo", "hair_bow", "cat_ears", "bunny_ears", "horns", "headset", "sunglasses",
               "monocle", "tie", "scarf"}
GAZES, MOUTHS = {"left", "center", "right"}, {"smirk", "smile", "neutral"}
DEFAULT_APPEARANCE = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
REQUIRE_KINDS = {"app", "mcp", "apple", "other"}
_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
_SLUG = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,59}$")
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")
_CRON_FIELD = re.compile(r"^[0-9A-Za-z*/,\-?#]+$")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f  ‪-‮⁦-⁩]")

# Verbindungen, die der Export in den Texten eines Scoops erkennt („braucht Gmail“): Kennung → Name und Suchwörter.
APP_WORDS = {
    "gmail": ("Gmail", ("gmail", "google mail")),
    "googlecalendar": (N_("Google Kalender"), ("google kalender", "google calendar", "googlecalendar", "gcal")),
    "outlook": ("Outlook", ("outlook",)),
    "notion": ("Notion", ("notion",)),
    "googledrive": ("Google Drive", ("google drive", "googledrive")),
    "googlesheets": ("Google Sheets", ("google sheets", "googlesheets", "google tabellen")),
    "googledocs": ("Google Docs", ("google docs", "googledocs")),
    "slack": ("Slack", ("slack",)),
    "github": ("GitHub", ("github",)),
    "linkedin": ("LinkedIn", ("linkedin",)),
}
APPLE_WORDS = {
    "reminders": (N_("Apple Erinnerungen"), ("apple erinnerungen", "apple_erinnerungen", "erinnerungen-app",
                                             "apple reminders")),
    "calendar": (N_("Apple Kalender"), ("apple kalender", "apple_kalender", "apple-kalender", "apple calendar")),
    "contacts": (N_("Apple Kontakte"), ("apple kontakte", "apple_kontakte", "apple contacts")),
    "home": ("Apple Home", ("apple home", "apple_home", "homekit")),
}


class TemplateError(ValueError):
    """Vorlage abgelehnt (Text ist für Menschen gedacht). `status`: HTTP-Status, `code`: Kennung für die App."""

    def __init__(self, message: str, status: int = 400, code: str = "invalid") -> None:
        super().__init__(message)
        self.status, self.code = status, code


# -- Prüfen ---------------------------------------------------------------------------------------------------
def _text(value, limit: int, what: str, *, required: bool = False, single_line: bool = False) -> str:
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise TemplateError(tx("{what}: erwartet wird Text.", what=what))
    t = _CONTROL.sub("", value.replace("\r\n", "\n").replace("\r", "\n")).strip()
    if single_line:
        t = re.sub(r"\s+", " ", t)
    if required and not t:
        raise TemplateError(tx("{what} fehlt.", what=what))
    if len(t) > limit:
        raise TemplateError(tx("{what} ist zu lang (höchstens {limit} Zeichen).", what=what, limit=limit))
    return t


def _list(value, limit: int, what: str) -> list:
    if value is None:
        return []
    if not isinstance(value, list):
        raise TemplateError(tx("{what}: erwartet wird eine Liste.", what=what))
    if len(value) > limit:
        raise TemplateError(tx("{what}: höchstens {limit} Einträge.", what=what, limit=limit))
    return value


def _appearance(raw) -> dict:
    a = raw if isinstance(raw, dict) else {}
    out = dict(DEFAULT_APPEARANCE)
    if a.get("shape") in SHAPES:
        out["shape"] = a["shape"]
    if isinstance(a.get("color"), str) and _COLOR.match(a["color"]):
        out["color"] = a["color"].upper()
    if a.get("eyes") in EYES:
        out["eyes"] = a["eyes"]
    if a.get("accessory") in ACCESSORIES:
        out["accessory"] = a["accessory"]
    if a.get("gaze") in GAZES:
        out["gaze"] = a["gaze"]
    if a.get("mouth") in MOUTHS:
        out["mouth"] = a["mouth"]
    if isinstance(a.get("cheeks"), bool):
        out["cheeks"] = a["cheeks"]
    photo = _photo(a.get("photo"))
    if photo:
        out["photo"] = photo
    return out


def _photo(raw) -> dict | None:
    """Bild der Vorlage: Base64, muss sich als Bild öffnen lassen und wird immer neu kodiert (256 px, JPEG/PNG)."""
    if raw is None:
        return None
    if not isinstance(raw, dict) or not isinstance(raw.get("data"), str):
        raise TemplateError(tx("Das Bild in der Vorlage ist nicht lesbar."))
    if len(raw["data"]) > MAX_PHOTO_B64:
        raise TemplateError(tx("Das Bild in der Vorlage ist zu groß."), 413)
    from . import avatars
    try:
        data = base64.b64decode(raw["data"], validate=True)
        body, ext = avatars.process(data, PHOTO_SIZE)
    except (binascii.Error, ValueError):
        raise TemplateError(tx("Das Bild in der Vorlage ist nicht lesbar.")) from None
    return {"mime": "image/png" if ext == "png" else "image/jpeg", "data": base64.b64encode(body).decode()}


def valid_cron(expr: str) -> bool:
    """Genau fünf Felder (Minute Stunde Tag Monat Wochentag), nur Zeichen eines Cron-Ausdrucks."""
    parts = expr.split()
    return len(parts) == 5 and all(_CRON_FIELD.match(p) for p in parts) and croniter.is_valid(expr)


def describe_cron(expr: str) -> str:
    """Zeitplan in Worten, vom Server aus dem Cron-Ausdruck berechnet (der Text der Datei könnte etwas anderes
    behaupten). Häufige Muster in Worten (Sprache der Person), sonst der Ausdruck selbst."""
    m, h, dom, mon, dow = expr.split()
    num = re.compile(r"^\d+$")
    if mon == "*" and num.match(m) and num.match(h):
        at = f"{int(h)}:{int(m):02d}" if i18n.current() == "de" else i18n.clock(int(h), int(m))
        if dom == "*" and dow == "*":
            return tx("Täglich um {at}", at=at)
        if dom == "*" and dow in ("1-5", "MON-FRI", "mon-fri"):
            return tx("Werktags um {at}", at=at)
        if dom == "*" and dow in ("0,6", "6,0", "6,7", "SAT,SUN", "sat,sun"):
            return tx("Am Wochenende um {at}", at=at)
        if dom == "*" and re.match(r"^[0-7](,[0-7])*$", dow):
            days = [i18n.weekday((int(d) - 1) % 7, short=True) for d in dow.split(",")]  # Cron: 0 und 7 = Sonntag
            return tx("{days} um {at}", days=", ".join(days), at=at)
        if dow == "*" and num.match(dom):
            return tx("Am {day}. jedes Monats um {at}", day=int(dom), at=at)
    if (dom, mon, dow) == ("*", "*", "*"):
        if h == "*" and (s := re.match(r"^\*/(\d+)$", m)):
            return tx("Alle {n} Minuten", n=int(s.group(1)))
        if h == "*" and m == "*":
            return tx("Jede Minute")
        if h == "*" and num.match(m):
            return tx("Stündlich (Minute {minute})", minute=int(m))
        if num.match(m) and (s := re.match(r"^\*/(\d+)$", h)):
            return tx("Alle {n} Stunden", n=int(s.group(1)))
    return tx("Zeitplan {expr}", expr=expr)


def runs_per_day(expr: str, start: datetime | None = None) -> float:
    """Läufe pro Tag (Mittel der nächsten 7 Tage), damit die Vorschau häufige Routinen kennzeichnen kann."""
    from .db import now
    start = start or now()
    end, it, n = start + timedelta(days=7), croniter(expr, start), 0
    while n < 10080 and it.get_next(datetime) <= end:
        n += 1
    return round(n / 7, 2)


def validate(raw) -> dict:
    """Roh-JSON einer Vorlage → geprüfte, normalisierte Vorlage (nur bekannte Felder). Wirft TemplateError."""
    if not isinstance(raw, dict):
        raise TemplateError(tx("Das ist keine Scoop-Vorlage."), code="not_a_template")
    fmt = raw.get("format")
    if raw.get("type") != TYPE or isinstance(fmt, bool) or not isinstance(fmt, int) or fmt < 1:
        raise TemplateError(tx("Das ist keine Scoop-Vorlage."), code="not_a_template")
    if fmt > FORMAT:
        raise TemplateError(tx("Diese Vorlage wurde mit einer neueren Version von AIS Scoops erstellt (Format {fmt}). "
                               "Dieser Server liest Vorlagen bis Format {max}. Aktualisiere den Server und versuch es "
                               "erneut.", fmt=fmt, max=FORMAT),
                            code="newer_format")
    out: dict = {"format": FORMAT, "type": TYPE,
                 "name": _text(raw.get("name"), LIMITS["name"], tx("Der Name"), required=True, single_line=True),
                 "label": _text(raw.get("label"), LIMITS["label"], tx("Die Rolle"), single_line=True),
                 "description": _text(raw.get("description"), LIMITS["description"], tx("Die Beschreibung")),
                 "appearance": _appearance(raw.get("appearance")),
                 "character": _text(raw.get("character"), LIMITS["character"], tx("Charakter und Anweisungen"))}
    model = raw.get("model")
    out["model"] = model if isinstance(model, str) and _MODEL.match(model) else None

    skills, seen = [], set()
    for i, s in enumerate(_list(raw.get("skills"), LIMITS["skills"], tx("Fähigkeiten")), 1):
        if not isinstance(s, dict):
            raise TemplateError(tx("Fähigkeit {i}: erwartet wird ein Objekt.", i=i))
        name = _text(s.get("name"), LIMITS["skill_name"], tx("Fähigkeit {i}: der Name", i=i), required=True,
                     single_line=True)
        if name.lower() in seen:
            raise TemplateError(tx("Fähigkeit „{name}“ steht doppelt in der Vorlage.", name=name))
        seen.add(name.lower())
        skills.append({"name": name,
                       "description": _text(s.get("description"), LIMITS["skill_description"],
                                            tx("Fähigkeit „{name}“: die Beschreibung", name=name)),
                       "steps": _text(s.get("steps"), LIMITS["skill_steps"], tx("Fähigkeit „{name}“: die Anleitung", name=name),
                                      required=True)})
    out["skills"] = skills

    routines = []
    for i, r in enumerate(_list(raw.get("routines"), LIMITS["routines"], tx("Routinen")), 1):
        if not isinstance(r, dict):
            raise TemplateError(tx("Routine {i}: erwartet wird ein Objekt.", i=i))
        title = _text(r.get("title"), LIMITS["routine_title"], tx("Routine {i}: der Titel", i=i), required=True,
                      single_line=True)
        expr = _text(r.get("schedule"), LIMITS["schedule"], tx("Routine „{title}“: der Zeitplan", title=title),
                     required=True, single_line=True)
        if not valid_cron(expr):
            raise TemplateError(tx("Routine „{title}“: Der Zeitplan „{expr}“ ist kein gültiger Cron-Ausdruck "
                                   "(Minute Stunde Tag Monat Wochentag, z. B. „30 7 * * 1-5“).", title=title, expr=expr))
        rm = r.get("model")
        routines.append({"title": title, "schedule": expr, "schedule_text": describe_cron(expr),
                         "prompt": _text(r.get("prompt"), LIMITS["routine_prompt"],
                                         tx("Routine „{title}“: der Auftrag", title=title), required=True),
                         "model": rm if isinstance(rm, str) and _MODEL.match(rm) else None})
    out["routines"] = routines

    requires = []
    for i, q in enumerate(_list(raw.get("requires"), LIMITS["requires"], tx("Benötigte Verbindungen")), 1):
        if not isinstance(q, dict):
            raise TemplateError(tx("Verbindung {i}: erwartet wird ein Objekt.", i=i))
        rid = str(q.get("id") or "").strip().lower()
        requires.append({"kind": q.get("kind") if q.get("kind") in REQUIRE_KINDS else "other",
                         "id": rid if _SLUG.match(rid) else "",
                         "name": _text(q.get("name"), LIMITS["require_name"], tx("Verbindung {i}: der Name", i=i),
                                       required=True, single_line=True),
                         "note": _text(q.get("note"), LIMITS["require_note"], tx("Verbindung {i}: der Hinweis", i=i),
                                       single_line=True)})
    out["requires"] = requires
    return out


def parse(data: bytes) -> dict:
    """Rohdaten einer Datei bzw. eines Request-Bodys → JSON-Objekt (mit Größengrenze)."""
    if len(data) > MAX_BYTES:
        raise TemplateError(tx("Die Vorlage ist zu groß (höchstens 1,5 MB)."), 413, "too_large")
    try:
        obj = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise TemplateError(tx("Das ist keine Scoop-Vorlage."), code="not_a_template") from None
    if not isinstance(obj, dict):
        raise TemplateError(tx("Das ist keine Scoop-Vorlage."), code="not_a_template")
    return obj


# -- Exportieren ----------------------------------------------------------------------------------------------
def _has_word(text: str, word: str) -> bool:
    return re.search(r"(?<![\w@.])" + re.escape(word) + r"(?![\w])", text, re.I) is not None


def detect_requires(text: str, *, apps: dict[str, str] | None = None, mcp: list[tuple[str, str]] | None = None) -> list[dict]:
    """Verbindungen, die in den Texten eines Scoops vorkommen. `apps`: weitere verbundene Apps (Kennung → Name),
    `mcp`: eigene MCP-Server (Kennung, Name). Bewusst einfach (Wortsuche); die Vorschau lässt jede Zeile abwählen."""
    out = []
    known = {**{slug: (name, words) for slug, (name, words) in APP_WORDS.items()}}
    for slug, name in (apps or {}).items():
        known.setdefault(slug, (name, (name.lower(), slug)))
    for slug, (name, words) in known.items():
        if any(_has_word(text, w) for w in words):
            out.append({"kind": "app", "id": slug, "name": translate(name), "note": ""})
    for sid, (name, words) in APPLE_WORDS.items():
        if any(_has_word(text, w) for w in words):
            out.append({"kind": "apple", "id": sid, "name": translate(name), "note": ""})
    for sid, name in mcp or []:
        if name and len(name) >= 3 and _has_word(text, name):
            rid = re.sub(r"[^a-z0-9_.-]", "-", name.lower())[:60].strip("-.")
            out.append({"kind": "mcp", "id": rid, "name": name[:LIMITS["require_name"]], "note": tx("Eigener MCP-Server")})
    return out[:LIMITS["requires"]]


_MAIL = re.compile(r"[\w.+-]+@[\w-]+(\.[\w-]+)+")
_PHONE = re.compile(r"(?<![\w.])\+?\d[\d ()/-]{7,}\d(?!\w)")


def privacy_warnings(parts: list[tuple[str, str]], owner_names: list[str]) -> list[dict]:
    """Hinweise auf Persönliches in den Texten (Name des Besitzers, Mailadressen, Telefonnummern), jeweils mit der
    Stelle. Nur Hinweise: Der Text bleibt, wie er ist; die Person entscheidet in der Vorschau."""
    out = []
    names = [n for n in dict.fromkeys(x.strip() for x in owner_names if x) if len(n) >= 3]
    for where, text in parts:
        found = []
        for n in names:
            if _has_word(text, n):
                found.append(tx("den Namen „{name}“", name=n))
        if _MAIL.search(text):
            found.append(tx("eine Mailadresse"))
        if _PHONE.search(text):
            found.append(tx("eine Telefonnummer"))
        if found:
            listed = found[0] if len(found) == 1 else tx("{items} und {last}", items=", ".join(found[:-1]), last=found[-1])
            out.append({"where": where, "text": tx("{where} enthält {listed}.", where=where, listed=listed)})
    return out


def export(db, bot_row, *, owner_names: list[str], apps: dict[str, str] | None = None,
           mcp: list[tuple[str, str]] | None = None) -> dict:
    """Vorlage eines Scoops. Liest nur, was in eine Vorlage gehört – kein Gedächtnis, kein Verlauf, keine Dateien,
    kein Tresor, keine Konten, keine Dauerfreigaben, keine Rechte, keine Kosten.
    Rückgabe: `template` (alles, was standardmäßig in die Datei kommt), `optional` (nur auf Wunsch: Bild, Fähigkeiten
    für alle Scoops) und `warnings` (Hinweise auf Persönliches)."""
    bot_id = bot_row["id"]
    mascot = json.loads(bot_row["mascot"] or "{}")
    mascot.pop("photo", None)
    appearance = _appearance(mascot)
    own, common = [], []
    for s in db.skills(bot_id):
        item = {"name": (s["name"] or "")[:LIMITS["skill_name"]], "description": (s["description"] or "")[:LIMITS["skill_description"]],
                "steps": (s["steps"] or "")[:LIMITS["skill_steps"]]}
        if item["name"].strip() and item["steps"].strip():
            (own if s["bot_id"] == bot_id else common).append(item)
    routines = []
    for r in db.routines(bot_id):
        if r["kind"] != "routine" or not valid_cron(r["schedule"] or "") or not (r["prompt"] or "").strip():
            continue  # Erinnerungen sind einmalig und persönlich, sie gehören nicht in eine Vorlage
        routines.append({"title": (r["title"] or "Routine")[:LIMITS["routine_title"]], "schedule": r["schedule"],
                         "schedule_text": describe_cron(r["schedule"]), "prompt": r["prompt"][:LIMITS["routine_prompt"]],
                         "model": r.get("model")})
    character = (bot_row["character"] or "")[:LIMITS["character"]]
    parts = [(tx("Charakter und Anweisungen"), character)]
    parts += [(tx("Fähigkeit „{name}“", name=s["name"]), f"{s['description']}\n{s['steps']}") for s in own + common]
    parts += [(tx("Routine „{title}“", title=r["title"]), r["prompt"]) for r in routines]
    text = "\n".join(t for _, t in parts)
    template = {"format": FORMAT, "type": TYPE, "name": bot_row["name"][:LIMITS["name"]],
                "label": (bot_row["label"] or "")[:LIMITS["label"]], "description": "", "appearance": appearance,
                "character": character, "model": bot_row["model"], "skills": own[:LIMITS["skills"]],
                "routines": routines[:LIMITS["routines"]], "requires": detect_requires(text, apps=apps, mcp=mcp)}
    optional: dict = {"skills": common[:LIMITS["skills"]], "photo": None}
    from . import avatars
    path = avatars.current_path(bot_id)
    if path:
        try:
            body, mime = avatars.resized(path, PHOTO_SIZE)
            optional["photo"] = {"mime": mime, "data": base64.b64encode(body).decode()}
        except Exception as e:  # noqa: BLE001 – ohne Bild exportieren
            print("Vorlage: Bild nicht lesbar:", e, flush=True)
    return {"template": template, "optional": optional, "warnings": privacy_warnings(parts, owner_names),
            "file_name": file_name(bot_row["name"])}


def file_name(name: str) -> str:
    safe = re.sub(r"[^\w\- ]", "", name, flags=re.U).strip() or "Scoop"
    return f"{safe[:40]}.scoop"


# -- Vorschau und Importieren ---------------------------------------------------------------------------------
def check(raw, *, requirement_status, model_info) -> dict:
    """Geprüfte Vorlage für die Vorschau vor dem Import: genau die Texte, die später im Prompt landen, Routinen mit
    vom Server berechnetem Zeitplan und Häufigkeit, Verbindungen mit Stand (`connected` | `missing` | `unknown`)."""
    t = validate(raw)
    for r in t["routines"]:
        r["runs_per_day"] = runs_per_day(r["schedule"])
    for q in t["requires"]:
        q["status"] = requirement_status(q)
    return {"template": t, "model": model_info(t["model"]),
            "notes": [tx("Der Scoop startet mit den Standardrechten und ohne dauerhafte Freigaben."),
                      tx("Routinen werden pausiert angelegt. Du schaltest sie im Profil ein.")] if t["routines"] else
                     [tx("Der Scoop startet mit den Standardrechten und ohne dauerhafte Freigaben.")]}


def _pick(items: list, chosen, what: str) -> list:
    """Auswahl per Index (`None` = alle)."""
    if chosen is None:
        return items
    if not isinstance(chosen, list) or any(isinstance(i, bool) or not isinstance(i, int) for i in chosen):
        raise TemplateError(tx("{what}: erwartet wird eine Liste von Positionen.", what=what))
    return [x for i, x in enumerate(items) if i in set(chosen)]


def import_template(service, raw, *, name=None, routines=None, skills=None, use_model: bool = True,
                    use_photo: bool = True, default_models, model_ok) -> dict:
    """Legt aus einer Vorlage einen Scoop mit Fähigkeiten und (pausierten) Routinen an: alles in einer Transaktion
    oder gar nichts. Rechte, Teilen, Dauerfreigaben, Rechner und Gedächtnis kommen nie aus der Vorlage.
    `default_models(model)` → (Modell, Eskalationsmodell) für diesen Server, `model_ok(model)` → nutzbar?"""
    from . import avatars
    from .db import new_id, now_iso
    from .bots import _next_cron, load_config
    from . import workspace

    t = validate(raw)
    db = service.db
    bot_name = _text(name, LIMITS["name"], tx("Der Name"), required=True, single_line=True) if name is not None else t["name"]
    pick_r = _pick(t["routines"], routines, tx("Routinen"))
    pick_s = _pick(t["skills"], skills, tx("Fähigkeiten"))
    wanted = t["model"] if use_model and t["model"] and model_ok(t["model"]) else None
    model, escalation = default_models(wanted)
    mascot = {k: v for k, v in t["appearance"].items() if k != "photo"}
    photo = t["appearance"].get("photo") if use_photo else None
    bid, ts = new_id("b"), now_iso()
    node = load_config().get("default_computer_node") or None
    version = None
    rows_r, rows_s = [], []
    with db.lock:  # eine Verbindung für alle Threads: Sperre halten, bis alles geschrieben ist
        try:
            if photo:
                version = avatars.save(bid, base64.b64decode(photo["data"]))
            db.conn.execute(
                "INSERT INTO bots(id,name,label,mascot,character,model,escalation_model,pinned,section,created_at,"
                "last_activity,computer_node,avatar_version) VALUES(?,?,?,?,?,?,?,0,NULL,?,?,?,?)",
                (bid, bot_name, t["label"], json.dumps(mascot), t["character"], model, escalation, ts, ts,
                 None if node in (None, "vm") else node, version))
            for s in pick_s:
                sid = new_id("sk")
                db.conn.execute("INSERT INTO skills(id,bot_id,name,description,steps,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                                (sid, bid, s["name"], s["description"], s["steps"], ts, ts))
                rows_s.append(sid)
            for r in pick_r:
                rid = new_id("rt")
                rmodel = r["model"] if use_model and r["model"] and model_ok(r["model"]) else None
                db.conn.execute(  # enabled=0: Routinen aus einer Vorlage laufen erst, wenn der Nutzer sie einschaltet
                    "INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at,model) "
                    "VALUES(?,?,?,?,?,?,?,0,?,?,?)",
                    (rid, bid, "routine", r["title"], r["schedule"], r["schedule_text"], r["prompt"],
                     _next_cron(r["schedule"]), ts, rmodel))
                rows_r.append(rid)
            db.conn.commit()
        except Exception:
            db.conn.rollback()
            avatars.remove(bid)
            raise
    try:
        workspace.ensure_all([db.bot_row(bid)], load_config())  # Ordner <arbeitsordner>/<Name>/
    except Exception as e:  # noqa: BLE001 – der Ordner entsteht sonst beim nächsten Start
        print("Vorlage: Arbeitsordner nicht angelegt:", e, flush=True)
    service.publish("bot.created", service.bot_json(bid))
    for sid in rows_s:
        service.publish("skill.updated", db.skill_dict(db.skill_row(sid)))
    for rid in rows_r:
        service.publish("routine.updated", db.routine_dict(db.one("SELECT * FROM routines WHERE id=?", (rid,))))
    # Kein automatischer Lauf: Der Scoop arbeitet mit fremden Anweisungen erst, wenn der Nutzer ihm schreibt.
    hint = tx("{name} ist da (aus einer Vorlage)", name=bot_name)
    if rows_r:
        hint += " · " + txn("{n} Routine pausiert", "{n} Routinen pausiert", len(rows_r))
    service._add(bid, "event", hint, {"icon": "square.and.arrow.down", "silent": True, "template": True})
    return {"bot": service.bot_json(bid), "skills": len(rows_s), "routines": len(rows_r),
            "model_from_template": bool(wanted)}


# -- Endpunkte ------------------------------------------------------------------------------------------------
def register(app, *, auth, service, connections, bot_or_404, models) -> None:
    """Hängt die Endpunkte an die FastAPI-App (server.py). Alle nur für den Inhaber (`auth`): Gäste geteilter Scoops
    können weder exportieren noch importieren (403)."""
    from . import config as config_mod
    from .bots import load_config

    db = service.db

    def fail(e: TemplateError):
        return HTTPException(e.status, str(e))

    def connected_apps() -> dict[str, str]:
        """Kennung → Name der Apps mit aktivem Konto (leer, wenn Composio nicht eingerichtet oder nicht erreichbar ist)."""
        try:
            return {a["app"]: connections.display_name(a["app"]) for a in connections.accounts() if a.get("status") == "active"}
        except Exception:  # noqa: BLE001
            return {}

    def mcp_servers() -> list[tuple[str, str]]:
        try:
            return [(e["id"], e.get("name") or e["id"]) for e in service.custom_mcp.entries()] if service.custom_mcp else []
        except Exception:  # noqa: BLE001
            return []

    def requirement_status(q: dict) -> str:
        if q["kind"] == "app":
            return "connected" if q["id"] and q["id"] in connected_apps() else "missing"
        if q["kind"] == "mcp":
            names = {n.lower() for _, n in mcp_servers()} | {i.lower() for i, _ in mcp_servers()}
            return "connected" if q["name"].lower() in names or (q["id"] and q["id"] in names) else "missing"
        if q["kind"] == "apple":
            tool = {"reminders": "apple_erinnerungen", "calendar": "apple_kalender", "contacts": "apple_kontakte",
                    "home": "apple_home"}.get(q["id"])
            active: list[str] = []
            for attr in ("apple", "apple_devices"):
                try:
                    svc = getattr(service, attr, None)
                    active += list(svc.active_services()) if svc else []
                except Exception:  # noqa: BLE001
                    pass
            return "connected" if tool and tool in active else "missing"
        return "unknown"

    def model_info(model: str | None) -> dict:
        resolved = config_mod.resolve_model(model) if model else None
        usable = bool(resolved) and config_mod.model_available(resolved)
        return {"id": model, "resolved": resolved if resolved in models else None, "available": usable,
                "default": default_models(None)[0]}

    def default_models(wanted: str | None) -> tuple[str, str | None]:
        """Modell und Eskalationsmodell wie beim normalen Anlegen (BotService.create_bot)."""
        from .models_catalog import current as catalog
        cfg = load_config()
        model = config_mod.resolve_model(wanted) if wanted else None
        model = model or config_mod.resolve_model(cfg.get("default_model")) or catalog().default("anthropic")
        prov = catalog().provider_of(model)
        esc = config_mod.resolve_model(cfg.get("default_escalation_model"))
        if not esc or catalog().provider_of(esc) != prov:
            esc = catalog().default(prov, "escalation")
        return model, esc

    def model_ok(model: str) -> bool:
        m = config_mod.resolve_model(model)
        return bool(m) and m in models and config_mod.model_available(m)

    async def body_of(request: Request) -> dict:
        try:
            declared = int(request.headers.get("content-length") or 0)
        except ValueError:
            declared = 0
        if declared > MAX_BYTES + 4096:
            raise HTTPException(413, tx("Die Vorlage ist zu groß (höchstens 1,5 MB)."))
        data = await request.body()
        try:
            if len(data) > MAX_BYTES + 4096:
                raise TemplateError(tx("Die Vorlage ist zu groß (höchstens 1,5 MB)."), 413, "too_large")
            return parse(data) if data.strip() else {}
        except TemplateError as e:
            raise fail(e) from None

    @app.get("/api/bots/{bot_id}/template", dependencies=[Depends(auth)])
    def export_template(bot_id: str):
        """Scoop als Vorlage (für die Export-Vorschau der App; die App schreibt daraus die Datei)."""
        bot_or_404(bot_id)
        cfg = load_config()
        names = [service.user_name, cfg.get("owner_name") or "", cfg.get("user_name") or ""]
        names += [n.split()[0] for n in names if n and " " in n]
        return export(db, db.bot_row(bot_id), owner_names=names, apps=connected_apps(), mcp=mcp_servers())

    @app.post("/api/templates/check", dependencies=[Depends(auth)])
    async def check_template(request: Request):
        """Vorlage prüfen, ohne etwas anzulegen (Vorschau vor dem Import)."""
        raw = await body_of(request)
        try:
            return check(raw.get("template") if isinstance(raw.get("template"), dict) else raw,
                         requirement_status=requirement_status, model_info=model_info)
        except TemplateError as e:
            raise fail(e) from None

    @app.post("/api/templates/import", dependencies=[Depends(auth)])
    async def import_endpoint(request: Request):
        """Scoop aus einer Vorlage anlegen: `{"template": {…}, "name"?, "routines"?: [0, 2], "skills"?: [0],
        "use_model"?: true, "use_photo"?: true}` (Listen = Positionen, ohne Angabe alle)."""
        import asyncio
        raw = await body_of(request)
        if not isinstance(raw.get("template"), dict):
            raise HTTPException(400, tx("template fehlt"))
        try:
            return await asyncio.to_thread(
                import_template, service, raw["template"], name=raw.get("name"), routines=raw.get("routines"),
                skills=raw.get("skills"), use_model=raw.get("use_model", True) is not False,
                use_photo=raw.get("use_photo", True) is not False, default_models=default_models, model_ok=model_ok)
        except TemplateError as e:
            raise fail(e) from None
