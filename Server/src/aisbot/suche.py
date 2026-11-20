"""Suche über alle Chats (API `GET /api/search`, docs/API.md „Suche und Chat-Komfort“).

Eigener Volltext-Index `message_fts` neben `search_fts` (den nutzen die Scoops für `erinnerung_suchen`, mit
Gedächtnis-Einträgen und dem Namen vor jeder Nachricht – für die Suche der App ungeeignet):

- **Was drin steht:** alle sichtbaren Nachrichtenarten mit Text – `user`, `bot`, `event` und `approval` (Titel und
  Details der Karte), aus Einzel- und Gruppenchats. Statuszeilen (Arbeitsschritte) nicht.
- **Immer aktuell:** Trigger an der Tabelle `messages` (Einfügen, Ändern, Löschen). Damit landet jede Nachricht im
  Index, egal welcher Code sie schreibt (auch Zurücksetzen und Löschen eines Chats). Zeilen-ID im Index = `seq`.
- **Bestehende Datenbanken:** `ensure()` baut den Index beim Start einmal auf und danach nur neu, wenn sich die
  Fassung ändert oder Zeilen fehlen.
- **Teilwörter:** Tokenizer `trigram` („rechn“ findet „Rechnung“ und „Abrechnung“, ohne Rücksicht auf Groß-/
  Kleinschreibung und Akzente). Kennt SQLite ihn nicht, fällt der Index auf Wortanfänge zurück (`unicode61`, Präfixe).
- **Eingabe:** Jedes Wort wird als Zeichenkette in Anführungszeichen gesucht; Sonderzeichen können deshalb keinen
  FTS-Syntaxfehler auslösen.
"""

from __future__ import annotations

import re
import sqlite3
import time
import unicodedata

VERSION = "1"  # hochzählen, wenn sich Inhalt oder Aufbau des Index ändert → einmaliger Neuaufbau beim Start
ROLES = ("user", "bot", "event", "approval")  # durchsuchbare Nachrichtenarten (Admin)
GUEST_ROLES = ("user", "bot", "event")  # Gäste sehen von Freigaben nur „Wartet auf Freigabe …“, nie den Inhalt
MAX_LIMIT = 200
MAX_QUERY = 200
SNIPPET_BEFORE = 36  # Zeichen vor der Fundstelle
SNIPPET_LEN = 150
SHORT_SCAN = 4000  # Suche nur aus 1–2 Zeichen langen Wörtern: so viele jüngste Nachrichten werden durchgesehen

_ROLE_SQL = "(" + ",".join(f"'{r}'" for r in ROLES) + ")"
_TOKENIZERS = (  # erste Fassung, die diese SQLite-Version anlegen kann
    ("trigram", "tokenize='trigram remove_diacritics 1'"),
    ("trigram", "tokenize='trigram'"),
    ("prefix", "tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'"),
)


def _text_expr(row: str, json_ok: bool) -> str:
    """SQL-Ausdruck für den durchsuchbaren Text einer Nachricht (`row` = NEW, OLD oder Tabellenname)."""
    if not json_ok:
        return f"COALESCE({row}.text,'')"
    return (f"CASE WHEN {row}.role='approval' AND json_valid({row}.meta) THEN "
            f"COALESCE(json_extract({row}.meta,'$.title'),'') || char(10) || COALESCE(json_extract({row}.meta,'$.details'),'') "
            f"ELSE COALESCE({row}.text,'') END")


def ensure(db) -> str:
    """Index und Trigger anlegen, bei Bedarf einmal neu aufbauen. Gibt die Art des Index zurück (`trigram`/`prefix`).
    Fehler landen im Protokoll; die Suche fällt dann auf einen einfachen Durchlauf zurück (`mode() == "scan"`)."""
    try:
        return _ensure(db)
    except sqlite3.Error as e:
        print("Suchindex nicht angelegt:", e, flush=True)
        for t in ("message_fts_ai", "message_fts_au", "message_fts_ad"):  # nie Schreibzugriffe blockieren
            try:
                db.q(f"DROP TRIGGER IF EXISTS {t}")
            except sqlite3.Error:
                pass
        db.search_mode = "scan"
        return "scan"


def _ensure(db) -> str:
    with db.lock:
        try:
            db.q("SELECT json_valid('{}')")
            json_ok = True
        except sqlite3.Error:
            json_ok = False
        want = f"{VERSION}:{'json' if json_ok else 'text'}"
        have = db.setting("message_fts_version") or ""
        exists = bool(db.one("SELECT 1 FROM sqlite_master WHERE name='message_fts'"))
        kind = have.split(":")[-1] if exists and have.startswith(want + ":") else None
        rebuild = kind is None
        if rebuild:
            for t in ("message_fts_ai", "message_fts_au", "message_fts_ad"):
                db.q(f"DROP TRIGGER IF EXISTS {t}")
            db.q("DROP TABLE IF EXISTS message_fts")
            for kind, opts in _TOKENIZERS:
                try:
                    db.q(f"CREATE VIRTUAL TABLE message_fts USING fts5(text, {opts})")
                    break
                except sqlite3.Error:
                    continue
            else:
                raise sqlite3.OperationalError("FTS5 fehlt in dieser SQLite-Version")
        new, old = _text_expr("NEW", json_ok), _text_expr("OLD", json_ok)
        # Trigger jedes Mal neu anlegen (billig), damit eine geänderte Fassung sicher greift
        for t in ("message_fts_ai", "message_fts_au", "message_fts_ad"):
            db.q(f"DROP TRIGGER IF EXISTS {t}")
        db.q(f"CREATE TRIGGER message_fts_ai AFTER INSERT ON messages WHEN NEW.role IN {_ROLE_SQL} BEGIN "
             f"INSERT INTO message_fts(rowid, text) VALUES (NEW.seq, {new}); END")
        # Nur wenn sich der durchsuchbare Text ändert (Reaktionen und Zustände ändern nur `meta`)
        db.q(f"CREATE TRIGGER message_fts_au AFTER UPDATE OF text, meta, seq ON messages "
             f"WHEN NEW.role IN {_ROLE_SQL} AND (NEW.seq IS NOT OLD.seq OR {new} IS NOT {old}) BEGIN "
             f"DELETE FROM message_fts WHERE rowid=OLD.seq; "
             f"INSERT INTO message_fts(rowid, text) VALUES (NEW.seq, {new}); END")
        db.q("CREATE TRIGGER message_fts_ad AFTER DELETE ON messages BEGIN "
             "DELETE FROM message_fts WHERE rowid=OLD.seq; END")
        if not rebuild:
            # Zeilen fehlen (z. B. Datenbank aus einer Sicherung vor dem Index)? Dann ebenfalls neu aufbauen.
            n_idx = db.one("SELECT COUNT(*) n FROM message_fts")["n"]
            n_msg = db.one(f"SELECT COUNT(*) n FROM messages WHERE role IN {_ROLE_SQL}")["n"]
            rebuild = n_idx != n_msg
        if rebuild:
            t0 = time.time()
            db.q("DELETE FROM message_fts")
            expr = _text_expr("messages", json_ok)
            try:
                db.q(f"INSERT INTO message_fts(rowid, text) SELECT seq, {expr} FROM messages WHERE role IN {_ROLE_SQL}")
            except sqlite3.Error:
                # Einzelne kaputte Zeile (doppelte seq o. Ä.): Zeile für Zeile, Fehler überspringen
                db.q("DELETE FROM message_fts")
                for r in db.q(f"SELECT seq, {expr} AS t FROM messages WHERE role IN {_ROLE_SQL}"):
                    try:
                        db.q("INSERT INTO message_fts(rowid, text) VALUES (?,?)", (r["seq"], r["t"]))
                    except sqlite3.Error:
                        pass
            n = db.one("SELECT COUNT(*) n FROM message_fts")["n"]
            print(f"Suchindex ({kind}) aufgebaut: {n} Nachrichten in {time.time() - t0:.1f} s", flush=True)
        db.set_setting("message_fts_version", f"{want}:{kind}")
        db.search_mode = kind
        return kind


def mode(db) -> str:
    return getattr(db, "search_mode", None) or "scan"


# -- Text falten und Ausschnitt -------------------------------------------------------------------
def fold(s: str) -> tuple[str, list[int]]:
    """Kleinbuchstaben ohne Akzente („Büro“ → „buro“) und je gefaltetem Zeichen die Position im Original."""
    out: list[str] = []
    idx: list[int] = []
    for i, ch in enumerate(s):
        for c in unicodedata.normalize("NFKD", ch.lower()):
            if unicodedata.combining(c):
                continue
            out.append(c)
            idx.append(i)
    return "".join(out), idx


def tokens(query: str) -> list[str]:
    """Suchwörter (gefaltet), ohne Anführungszeichen; höchstens acht."""
    q = (query or "")[:MAX_QUERY].replace('"', " ").replace("\x00", " ")
    seen: list[str] = []
    for t in q.split():
        f = fold(t)[0].strip()
        if f and f not in seen:
            seen.append(f)
    return seen[:8]


_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_MD_MARK = re.compile(r"\*\*|__|`+|^#+\s*", re.M)


def plain(text: str) -> str:
    """Markdown grob entfernen, alles in eine Zeile."""
    t = _MD_LINK.sub(r"\1", text or "")
    t = _MD_MARK.sub("", t)
    return re.sub(r"\s+", " ", t).strip()


def snippet(text: str, toks: list[str]) -> tuple[str, list[list[int]]]:
    """Einzeiliger Ausschnitt um die erste Fundstelle und die markierten Bereiche darin.
    `marks`: Liste `[start, ende)` in Unicode-Zeichen (Codepoints) des Ausschnitts."""
    flat = plain(text)
    folded, idx = fold(flat)
    spans: list[tuple[int, int]] = []
    for t in toks:
        start = 0
        while t:
            p = folded.find(t, start)
            if p < 0:
                break
            spans.append((idx[p], idx[p + len(t) - 1] + 1))
            start = p + len(t)
    spans.sort()
    first = spans[0][0] if spans else 0
    lo = max(0, first - SNIPPET_BEFORE)
    if lo > 0:  # an einer Wortgrenze beginnen
        sp = flat.find(" ", lo, first)
        lo = sp + 1 if sp >= 0 else lo
    hi = min(len(flat), lo + SNIPPET_LEN)
    if hi < len(flat):
        sp = flat.rfind(" ", lo + SNIPPET_LEN // 2, hi)
        hi = sp if sp > 0 else hi
    pre, post = ("…" if lo > 0 else ""), ("…" if hi < len(flat) else "")
    marks: list[list[int]] = []
    for a, b in spans:
        a, b = max(a, lo), min(b, hi)
        if a >= b:
            continue
        a, b = a - lo + len(pre), b - lo + len(pre)
        if marks and a <= marks[-1][1]:
            marks[-1][1] = max(marks[-1][1], b)
        else:
            marks.append([a, b])
    return pre + flat[lo:hi] + post, marks


# -- Abfrage --------------------------------------------------------------------------------------
def _quoted(t: str) -> str:
    return '"' + t.replace('"', '""') + '"'


def _match(toks: list[str], kind: str) -> tuple[str | None, list[str]]:
    """FTS-Ausdruck und die Wörter, die der Index nicht prüfen kann (im Trigram-Index: kürzer als drei Zeichen)."""
    if kind == "trigram":
        long = [t for t in toks if len(t) >= 3]
        short = [t for t in toks if len(t) < 3]
        return (" AND ".join(_quoted(t) for t in long) or None), short
    if kind == "prefix":
        return " AND ".join(_quoted(t) + "*" for t in toks), []
    return None, list(toks)


def _searchable(r) -> str:
    """Durchsuchbarer Text einer Nachrichtenzeile (wie im Index)."""
    if r["role"] == "approval":
        import json
        try:
            meta = json.loads(r["meta"] or "{}")
        except ValueError:
            meta = {}
        return f"{meta.get('title') or ''}\n{meta.get('details') or ''}"
    return r["text"] or ""


def search(db, query: str, *, chats: list[str] | None = None, roles: tuple[str, ...] = ROLES, limit: int = 30,
           before: str | None = None) -> dict:
    """Treffer (neueste zuerst) als Nachrichtenzeilen plus Ausschnitt.

    `chats`: nur diese Chats (None = alle; leere Liste = nichts). `before`: nur Nachrichten vor dieser (Blättern).
    Rückgabe: `{"rows": [(sqlite3.Row, snippet, marks)], "total": int, "truncated": bool, "tokens": [...]}`."""
    toks = tokens(query)
    limit = max(1, min(int(limit or 30), MAX_LIMIT))
    empty = {"rows": [], "total": 0, "truncated": False, "tokens": toks}
    if not toks or sum(len(t) for t in toks) < 2 or chats == []:
        return empty
    kind = mode(db)
    match, loose = _match(toks, kind)
    where = [f"m.role IN ({','.join('?' * len(roles))})"]
    args: list = list(roles)
    if chats is not None:
        where.append(f"m.bot_id IN ({','.join('?' * len(chats))})")
        args += chats
    if before:
        b = db.one("SELECT seq FROM messages WHERE id=?", (before,))
        if b:
            where.append("m.seq < ?")
            args.append(b["seq"])
    cond = " AND ".join(where)
    try:
        if match:
            sql = (f"FROM message_fts f JOIN messages m ON m.seq = f.rowid WHERE message_fts MATCH ? AND {cond}")
            qargs = [match, *args]
        else:
            # Nur sehr kurze Wörter (oder kein Index): die jüngsten Nachrichten der Reihe nach durchsehen
            sql, qargs = f"FROM messages m WHERE {cond}", list(args)
        if match and not loose:
            total = db.one(f"SELECT COUNT(*) n {sql}", tuple(qargs))["n"]
            rows = db.q(f"SELECT m.* {sql} ORDER BY m.seq DESC LIMIT ?", (*qargs, limit))
        else:
            cand = db.q(f"SELECT m.* {sql} ORDER BY m.seq DESC LIMIT ?", (*qargs, SHORT_SCAN))
            need = loose if match else toks
            hits = [r for r in cand if all(t in fold(_searchable(r))[0] for t in need)]
            total, rows = len(hits), hits[:limit]
    except sqlite3.Error as e:  # sollte durch die Anführungszeichen nie passieren; im Zweifel leer statt Fehler
        print("Suche fehlgeschlagen:", str(e)[:200], flush=True)
        return empty
    out = []
    for r in rows:
        s, marks = snippet(_searchable(r), toks)
        out.append((r, s, marks))
    return {"rows": out, "total": total, "truncated": total > len(out), "tokens": toks}


# -- Ausschnitt eines Chats rund um eine Nachricht (Sprung zu einer Fundstelle) --------------------
def around(db, chat_id: str, message_id: str, before: int = 25, after: int = 25) -> dict | None:
    """Nachrichten rund um `message_id` (aufsteigend) und ob es davor/danach weitere gibt. None = nicht in diesem Chat."""
    r = db.one("SELECT seq FROM messages WHERE id=? AND bot_id=?", (message_id, chat_id))
    if not r:
        return None
    before, after = max(0, min(int(before), 100)), max(0, min(int(after), 100))
    older = db.q("SELECT * FROM messages WHERE bot_id=? AND seq<? ORDER BY seq DESC LIMIT ?", (chat_id, r["seq"], before + 1))
    newer = db.q("SELECT * FROM messages WHERE bot_id=? AND seq>=? ORDER BY seq LIMIT ?", (chat_id, r["seq"], after + 2))
    has_older, has_newer = len(older) > before, len(newer) > after + 1
    rows = list(reversed(older[:before])) + newer[:after + 1]
    return {"messages": [db.msg_dict(x) for x in rows], "has_older": has_older, "has_newer": has_newer}


def after(db, chat_id: str, message_id: str, limit: int = 50) -> list[dict]:
    """Nachrichten nach `message_id` (aufsteigend, die nächsten `limit`)."""
    r = db.one("SELECT seq FROM messages WHERE id=? AND bot_id=?", (message_id, chat_id))
    if not r:
        return []
    rows = db.q("SELECT * FROM messages WHERE bot_id=? AND seq>? ORDER BY seq LIMIT ?", (chat_id, r["seq"], limit))
    return [db.msg_dict(x) for x in rows]
