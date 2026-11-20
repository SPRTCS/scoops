"""Sprachen des Servers (docs/sprache.md): Deutsch ist Quellsprache und Standard, Englisch kommt aus einer Tabelle.

Grundsätze:
- Der deutsche Text steht weiter im Code und ist zugleich der Schlüssel. `tx("Routine angelegt: {title}", title=t)`
  liefert für Deutsch genau den bisherigen Text, für Englisch die Übersetzung aus `i18n_en`.
- `txn(einzahl, mehrzahl, n, …)` für Mehrzahlformen (Schlüssel ist die deutsche Einzahl, die Tabelle hat zwei Formen).
- `N_("…")` markiert Texte, die beim Import entstehen (Konstanten, Kataloge); übersetzt wird erst bei der Ausgabe mit
  `translate(text)` (z. B. Fehlermeldungen in server.py, Kataloge). `N_` selbst ändert nichts.
- Welche Sprache gilt, steht in einer Kontextvariable: Anfragen setzen sie für die anfragende Person (server.py),
  alles andere (Läufe, Routinen, Aufgaben, Mitteilungen an den Inhaber) nimmt die gespeicherte Sprache des Inhabers.
  Texte für einen bestimmten Gast entstehen in `with use(lang_of(user_id)):`.
- Gespeichert wird pro Person (Inhaber `""`, Gäste mit Konto-ID) in der Tabelle `user_languages`.

tests/test_i18n.py durchsucht den Quelltext nach `tx`/`txn`/`N_` und prüft die Tabelle gegen (fehlt, übrig,
Platzhalter, Mehrzahl).
"""

from __future__ import annotations

import re
import string
import threading
from contextlib import contextmanager
from contextvars import ContextVar

from fastapi import Request  # Modulebene: FastAPI muss die Annotation `request: Request` in register auflösen

LANGS = ("de", "en")
DEFAULT = "de"
OWNER = ""  # user_id des Inhabers in der Tabelle (wie ruhe.py)

_current: ContextVar[str | None] = ContextVar("aisbot_lang", default=None)
_tables: dict[str, dict] = {}
_store = None  # Languages (nach init)


# -- Übersetzen --------------------------------------------------------------------------------------------------------
def _table(lang: str) -> dict:
    if lang not in _tables:
        if lang == "en":
            from .i18n_en import TEXTS
            _tables[lang] = TEXTS
        else:
            _tables[lang] = {}
    return _tables[lang]


def current() -> str:
    """Sprache für Texte, die gerade entstehen: gesetzt (Anfrage, `use`) oder die des Inhabers."""
    v = _current.get()
    if v:
        return v
    return owner_lang()


def tx(text: str, /, **kw) -> str:
    """Deutscher Quelltext → Text in der aktuellen Sprache, Platzhalter `{name}` mit `kw` gefüllt."""
    lang = current()
    s = text
    if lang != DEFAULT:
        v = _table(lang).get(text)
        if isinstance(v, str):
            s = v
    return s.format(**kw) if kw else s


def txn(singular: str, plural: str, n: int, /, **kw) -> str:
    """Mehrzahl: `txn("{n} Schritt", "{n} Schritte", n)`. `n` steht automatisch als Platzhalter bereit."""
    lang = current()
    s = singular if n == 1 else plural
    if lang != DEFAULT:
        v = _table(lang).get(singular)
        if isinstance(v, (tuple, list)) and len(v) == 2:
            s = v[0] if n == 1 else v[1]
    return s.format(n=n, **kw)


def N_(text: str) -> str:
    """Markiert einen Text zum Übersetzen bei der Ausgabe (`translate`). Gibt ihn unverändert zurück."""
    return text


def translate(text, lang: str | None = None):
    """Laufzeit-Übersetzung eines (mit N_ markierten oder als Fehlermeldung durchgereichten) deutschen Texts ohne
    Platzhalter. Unbekannte Texte und Nicht-Texte kommen unverändert zurück."""
    if not isinstance(text, str):
        return text
    lang = lang or current()
    if lang == DEFAULT:
        return text
    v = _table(lang).get(text)
    return v if isinstance(v, str) else text


def placeholders(s: str) -> set[str]:
    """Namen der Platzhalter in einem Formattext (für den Test)."""
    try:
        return {f for _, f, _, _ in string.Formatter().parse(s) if f is not None}
    except ValueError:
        return {"<ungültig>"}


@contextmanager
def use(lang: str | None):
    """Texte in diesem Block in `lang` (None = unverändert)."""
    if not lang:
        yield
        return
    token = _current.set(normalize(lang) or DEFAULT)
    try:
        yield
    finally:
        _current.reset(token)


def set_current(lang: str | None):
    """Für die Middleware: Sprache dieser Anfrage setzen (Rückgabe: Token zum Zurücksetzen)."""
    return _current.set(normalize(lang) if lang else None)


def reset_current(token) -> None:
    _current.reset(token)


def for_owner():
    """Block, dessen Texte für den Inhaber bzw. in seine Chats gehen (auch aus der Anfrage eines Gasts heraus)."""
    return use(owner_lang())


def for_user(user_id: str | None):
    """Block, dessen Texte für genau diese Person sind (None/"" = Inhaber), z. B. Mitteilung an einen Gast."""
    return use(lang_of(user_id))


# -- Zahlen und Daten in Texten --------------------------------------------------------------------------------------
_WEEKDAYS = {"de": ("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"),
             "en": ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")}
_WEEKDAYS_SHORT = {"de": ("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"), "en": ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")}
_MONTHS = {"de": ("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober",
                  "November", "Dezember"),
           "en": ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                  "November", "December")}


def decimal(value: float, digits: int = 2) -> str:
    """Zahl mit Nachkommastellen für Texte: „1,50“ (Deutsch) bzw. „1.50“ (Englisch)."""
    s = f"{value:.{digits}f}"
    return s.replace(".", ",") if current() == "de" else s


def weekday(i: int, short: bool = False) -> str:
    """Wochentag 0 = Montag … 6 = Sonntag in der aktuellen Sprache."""
    return (_WEEKDAYS_SHORT if short else _WEEKDAYS)[current() if current() in _WEEKDAYS else DEFAULT][i % 7]


def clock(hour: int, minute: int) -> str:
    """Uhrzeit für Texte: „09:00“/„15:30“ (Deutsch) bzw. „9:00 AM“/„3:30 PM“ (Englisch, USA)."""
    if current() == "de":
        return f"{hour:02d}:{minute:02d}"
    return f"{hour % 12 or 12}:{minute:02d} {'AM' if hour < 12 else 'PM'}"


def month(i: int) -> str:
    """Monat 1 = Januar … 12 = Dezember in der aktuellen Sprache."""
    return _MONTHS[current() if current() in _MONTHS else DEFAULT][(i - 1) % 12]


# -- Sprachcodes -------------------------------------------------------------------------------------------------------
def normalize(code) -> str | None:
    """„en-US“, „EN“, „en_GB“ → „en“; nicht unterstützte Sprachen → None."""
    if not isinstance(code, str):
        return None
    base = code.strip().lower().replace("_", "-").split("-", 1)[0]
    return base if base in LANGS else None


_AL = re.compile(r"\s*([A-Za-z]{1,8}(?:[-_][A-Za-z0-9]{1,8})*|\*)\s*(?:;\s*q\s*=\s*([0-9.]+))?\s*")


def from_accept_language(header: str | None) -> str | None:
    """Erste unterstützte Sprache aus `Accept-Language` (nach q-Wert), sonst None."""
    if not header or len(header) > 500:
        return None
    found = []
    for i, part in enumerate(header.split(",")):
        m = _AL.fullmatch(part)
        if not m:
            continue
        try:
            q = float(m.group(2)) if m.group(2) else 1.0
        except ValueError:
            continue
        lang = normalize(m.group(1))
        if lang and q > 0:
            found.append((-q, i, lang))
    return min(found)[2] if found else None


# -- Speicher pro Person ---------------------------------------------------------------------------------------------
class Languages:
    """Gespeicherte Sprache pro Person: Inhaber (`""`) und jeder Gast (Konto-ID) getrennt."""

    def __init__(self, db):
        self.db = db
        db.q("CREATE TABLE IF NOT EXISTS user_languages (user_id TEXT PRIMARY KEY, lang TEXT NOT NULL, "
             "updated_at TEXT NOT NULL)")
        self._lock = threading.Lock()
        self._cache: dict[str, str | None] = {}

    def stored(self, user_id: str | None) -> str | None:
        uid = user_id or OWNER
        with self._lock:
            if uid in self._cache:
                return self._cache[uid]
        r = self.db.one("SELECT lang FROM user_languages WHERE user_id=?", (uid,))
        v = normalize(r["lang"]) if r else None
        with self._lock:
            self._cache[uid] = v
        return v

    def set(self, user_id: str | None, lang: str | None) -> str | None:
        uid = user_id or OWNER
        v = normalize(lang) if lang else None
        if v:
            from .db import now_iso
            self.db.q("INSERT INTO user_languages(user_id, lang, updated_at) VALUES(?,?,?) ON CONFLICT(user_id) "
                      "DO UPDATE SET lang=excluded.lang, updated_at=excluded.updated_at", (uid, v, now_iso()))
        else:
            self.db.q("DELETE FROM user_languages WHERE user_id=?", (uid,))
        with self._lock:
            self._cache[uid] = v
        return v


def init(db) -> Languages:
    global _store
    _store = Languages(db)
    return _store


def set_lang(user_id: str | None, lang: str | None) -> str | None:
    """Sprache einer Person speichern (None = löschen, dann gilt wieder Kopfzeile bzw. Deutsch)."""
    return _store.set(user_id, lang) if _store else None


def stored_lang(user_id: str | None) -> str | None:
    return _store.stored(user_id) if _store else None


def owner_lang() -> str:
    """Sprache des Inhabers: gespeichert, sonst Deutsch. Gilt für Chats, Gruppen, geteilte Chats und Hintergrund."""
    return stored_lang(OWNER) or DEFAULT


def lang_of(user_id: str | None) -> str:
    """Sprache einer Person (None/"" = Inhaber): gespeichert, sonst Deutsch."""
    return stored_lang(user_id) or DEFAULT


def request_lang(user_id: str | None, *, param: str | None = None, header: str | None = None,
                 header_first: bool = False) -> str:
    """Sprache für die Antwort einer Anfrage: Parameter `lang` > gespeichert > `Accept-Language` > Deutsch.
    Einrichtung (`header_first`): Parameter > `Accept-Language` > gespeichert (Inhaber) > Deutsch."""
    p = normalize(param)
    if p:
        return p
    h = from_accept_language(header)
    if header_first and h:
        return h
    return stored_lang(user_id) or h or DEFAULT


def state(user_id: str | None) -> dict:
    """Antwort von GET/PATCH /api/settings/language."""
    stored = stored_lang(user_id)
    return {"language": stored or current(), "stored": stored, "available": list(LANGS), "default": DEFAULT}


# -- Endpunkte ---------------------------------------------------------------------------------------------------------
def register(app, *, shared, events, on_owner_change=None):
    """`GET`/`PATCH /api/settings/language` – für den Inhaber und (getrennt) für jeden Gast geteilter Scoops.
    `on_owner_change()` läuft, nachdem der Inhaber seine Sprache geändert hat (z. B. Start-Scoop umstellen)."""
    from fastapi import Depends, HTTPException

    from .sharing import Principal

    @app.get("/api/settings/language")
    def get_language(p: Principal = Depends(shared(via="any"))):
        return state(None if p.is_owner else p.user_id)

    @app.patch("/api/settings/language")
    def patch_language(request: Request, body: dict | None = None, p: Principal = Depends(shared(via="any"))):
        uid = None if p.is_owner else p.user_id
        body = body or {}
        if "language" not in body:
            raise HTTPException(400, tx("language fehlt (de, en oder null)"))
        raw = body.get("language")
        if raw is not None and not normalize(raw):
            raise HTTPException(400, tx("Unbekannte Sprache. Möglich: {langs}", langs=", ".join(LANGS)))
        set_lang(uid, raw)
        with use(request_lang(uid, header=request.headers.get("accept-language"))):
            data = state(uid)
        if uid:
            events.send_user(uid, "language.updated", data)
        else:
            events.publish("language.updated", data)  # nur an den Inhaber (Gast-Filter kennt den Typ nicht)
            if on_owner_change:
                on_owner_change()
        return data
