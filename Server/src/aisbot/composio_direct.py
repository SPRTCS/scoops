"""Vollständige, kompakte Ergebnisse für COMPOSIO_MULTI_EXECUTE_TOOL (ab Server 1.24).

Problem: Der Composio-Tool-Router liefert bei großen Antworten nur eine Vorschau (`data_preview` mit drei Zeilen,
verschachtelte Werte als „{object}“) und legt den Rest in seiner Sandbox ab. Schwache Modelle werten die Datei nicht
aus, sondern bauen Listen aus alten Chat-Nachrichten zusammen (erfundene Fälligkeiten).

Lösung:
1. Eindeutig lesende Werkzeuge (QUERY, LIST, GET, SEARCH, FETCH, RETRIEVE, FIND, READ – ohne schreibendes Wort
   im Namen) führt der Server selbst über die REST-API aus (`/api/v3/tools/execute/<slug>`, Version „latest“ wie der
   Tool Router), mit demselben Composio-User und demselben verbundenen Konto (`account` = Alias/E-Mail/ID, sonst das
   einzige aktive Konto der App). Damit kommt nie eine Vorschau, und es wird nichts doppelt ausgeführt.
2. Alles andere (schreibend, unklar, mehrere Konten ohne Angabe, REST-Fehler) geht wie bisher an den Tool Router.
   Liefert er für ein lesendes Werkzeug doch eine Vorschau, holt der Server es per REST nach.
3. Ergebnisse werden kompaktiert (leere Werte, Metadaten, URLs, Icons weg; Notion-Seiten auf einfache Werte) und
   auf `LIMIT` Zeichen begrenzt, mit ehrlichem Hinweis „N von M Zeilen“. Bleibt eine Vorschau übrig, sagt ein
   Hinweis klar: daraus nichts zusammenbauen.
"""

from __future__ import annotations

import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Callable

import httpx

LIMIT = 40_000  # Zeichen für die gesamte Antwort an das Modell
MAX_STRING = 6_000  # einzelne Texte (z. B. Mail-Inhalt) darüber kürzen
RELATION_LOOKUPS = 25  # höchstens so viele unbekannte Notion-Verknüpfungen je Aufruf nachschlagen
TITLE_TTL = 15 * 60

READ_VERBS = {"QUERY", "LIST", "GET", "SEARCH", "FETCH", "RETRIEVE", "FIND", "READ"}
# Kommt eines dieser Wörter irgendwo im Namen vor, gilt das Werkzeug nicht als lesend (lieber zu vorsichtig).
WRITE_WORDS = {
    "CREATE", "UPDATE", "DELETE", "REMOVE", "SEND", "REPLY", "FORWARD", "POST", "PUT", "PATCH", "ADD", "INSERT",
    "APPEND", "MOVE", "COPY", "DUPLICATE", "ARCHIVE", "UNARCHIVE", "TRASH", "UNTRASH", "RESTORE", "MARK", "SET",
    "MODIFY", "EDIT", "WRITE", "UPLOAD", "IMPORT", "EXPORT", "EXECUTE", "RUN", "START", "STOP", "CANCEL", "MERGE",
    "CLOSE", "OPEN", "INVITE", "ASSIGN", "UNASSIGN", "APPROVE", "REJECT", "PUBLISH", "UNPUBLISH", "SHARE", "SUBMIT",
    "TRIGGER", "ENABLE", "DISABLE", "LOCK", "UNLOCK", "PIN", "UNPIN", "STAR", "UNSTAR", "UNTAG",
    "REPLACE", "RENAME", "CHARGE", "PAY", "REFUND", "RESCHEDULE", "SUBSCRIBE", "UNSUBSCRIBE",
    "FOLLOW", "UNFOLLOW", "LIKE", "UNLIKE", "REACT", "MUTATE", "PURGE", "CLEAR", "RESET", "SYNC",
    "REFRESH", "REVOKE", "LOGIN", "LOGOUT", "REGISTER", "VERIFY", "TRANSFER", "BUY", "SELL",
    "ACCEPT", "DECLINE", "RESPOND", "SAVE", "STORE", "PUSH", "COMMIT", "DEPLOY", "INVOKE", "DIAL",
    "NOTIFY", "UNBLOCK", "MUTE", "UNMUTE", "BAN", "KICK", "JOIN", "LEAVE", "CONVERT", "GENERATE",
    "EMPTY", "SNOOZE", "UNDO", "BULK", "UPSERT", "INCREMENT", "DECREMENT", "TOGGLE",
}  # Substantive wie MESSAGE, BLOCK, COMMENT, LABEL, DRAFT fehlen absichtlich (GMAIL_FETCH_MESSAGE…, NOTION_FETCH_BLOCK…)

DROP_KEYS = {"icon", "cover", "created_by", "last_edited_by", "request_id", "log_id", "etag", "annotations",
             "avatar_url", "logo", "thumbnail", "favicon", "parent", "public_url", "page_or_database",
             "structure_info", "instruction"}
FALSE_NOISE = {"archived", "in_trash", "is_archived", "is_locked", "is_inline", "has_children", "has_more_children"}
URL_KEY = re.compile(r"(^|_)(url|href|link)$|(Url|Link)$|^self$", re.IGNORECASE)
B64 = re.compile(r"^[A-Za-z0-9+/=_\-]{200,}$")

PREVIEW_HINT = ("Achtung: Für {slugs} kam nur eine Vorschau (die Antwort war zu groß). Bau daraus keine Liste und ergänze "
                "nichts aus früheren Nachrichten. Lade gezielter nach (Filter, kleinere page_size bzw. Seitengröße, "
                "konkretes Konto über `account`) oder sag ehrlich, welche Daten fehlen.")


# -- lesend oder nicht ---------------------------------------------------------------
def split_slug(slug: str, apps: list[str] | tuple[str, ...] = ()) -> tuple[str, list[str]]:
    """GOOGLECALENDAR_EVENTS_LIST → ("googlecalendar", ["EVENTS", "LIST"]). Bekannte App-Slugs (auch mit „_“)
    haben Vorrang, sonst gilt das erste Wort als App."""
    s = (slug or "").upper()
    for app in sorted(apps, key=len, reverse=True):
        p = app.upper() + "_"
        if s.startswith(p) and len(s) > len(p):
            return app.lower(), [w for w in s[len(p):].split("_") if w]
    head, _, rest = s.partition("_")
    return head.lower(), [w for w in rest.split("_") if w]


def is_readonly(slug: str, apps: list[str] | tuple[str, ...] = ()) -> bool:
    """Nur eindeutig lesende Werkzeuge: lesendes Verb vorn oder hinten, kein schreibendes Wort im Namen."""
    _, words = split_slug(slug, apps)
    if not words or any(w in WRITE_WORDS for w in words):
        return False
    return words[0] in READ_VERBS or words[-1] in READ_VERBS


# -- Kompaktieren --------------------------------------------------------------------
def _rich(items) -> str:
    return "".join(str(x.get("plain_text") or (x.get("text") or {}).get("content") or "")
                   for x in items or [] if isinstance(x, dict)).strip()


def _empty(v) -> bool:
    return v is None or v == "" or v == [] or v == {}


def _short_time(v):
    return v[:16] if isinstance(v, str) and len(v) >= 16 and v[10:11] == "T" else v


def _date(d) -> object:
    if not isinstance(d, dict) or not d.get("start"):
        return None
    start, end = _short_time(d["start"]), _short_time(d.get("end"))
    if str(start).endswith("T00:00"):
        start = start[:10]
    return {"start": start, "end": end} if end else start


def _person(p) -> str | None:
    if not isinstance(p, dict):
        return None
    return p.get("name") or (p.get("person") or {}).get("email") or None


def _formula(f) -> object:
    if not isinstance(f, dict):
        return None
    t = f.get("type")
    v = f.get(t) if t else None
    return _date(v) if t == "date" else v


def notion_value(prop: dict, titles: dict[str, str]) -> object:
    """Eine Notion-Eigenschaft → einfacher Wert (None = weglassen)."""
    if not isinstance(prop, dict):
        return prop
    t = prop.get("type")
    v = prop.get(t) if t else None
    if t in ("title", "rich_text"):
        return _rich(v) or None
    if t == "date":
        return _date(v)
    if t in ("status", "select"):
        return (v or {}).get("name") if isinstance(v, dict) else None
    if t == "multi_select":
        return [x.get("name") for x in v or [] if isinstance(x, dict) and x.get("name")] or None
    if t == "people":
        names = [n for n in (_person(p) for p in v or []) if n]
        return names or (f"{len(v)} Person(en)" if v else None)
    if t in ("created_by", "last_edited_by"):
        return _person(v)
    if t == "relation":
        ids = [x.get("id") for x in v or [] if isinstance(x, dict) and x.get("id")]
        if not ids:
            return None
        names = [titles.get(i) for i in ids]
        if all(names):
            return names + (["…"] if prop.get("has_more") else [])
        return f"{len(ids)}{'+' if prop.get('has_more') else ''} verknüpft"
    if t == "formula":
        return _formula(v)
    if t == "rollup":
        if not isinstance(v, dict):
            return None
        rt = v.get("type")
        if rt == "array":
            out = [notion_value(x, titles) for x in v.get("array") or []]
            return [x for x in out if not _empty(x)] or None
        return _date(v.get(rt)) if rt == "date" else v.get(rt)
    if t == "files":
        return [x.get("name") for x in v or [] if isinstance(x, dict) and x.get("name")] or None
    if t == "unique_id":
        if isinstance(v, dict) and v.get("number") is not None:
            return f"{v.get('prefix') + '-' if v.get('prefix') else ''}{v['number']}"
        return None
    if t == "verification":
        return (v or {}).get("state") if isinstance(v, dict) else None
    if t in ("created_time", "last_edited_time"):
        return _short_time(v)
    if t == "button":
        return None
    if t in ("checkbox", "number", "url", "email", "phone_number"):
        return v
    return compact(v)


def _title_of(page: dict) -> str | None:
    for p in (page.get("properties") or {}).values():
        if isinstance(p, dict) and p.get("type") == "title":
            return _rich(p.get("title")) or None
    return None


def notion_page(page: dict, titles: dict[str, str]) -> dict:
    out: dict = {"id": page.get("id")}
    for name, prop in (page.get("properties") or {}).items():
        val = notion_value(prop, titles)
        if _empty(val):
            continue
        out[name if name not in ("id", "created_time", "last_edited_time") else f"{name} (Eigenschaft)"] = val
    if page.get("archived") or page.get("in_trash"):
        out["im_papierkorb"] = True
    for k in ("created_time", "last_edited_time"):
        if page.get(k):
            out[k] = _short_time(page[k])
    return out


def _schema_entry(prop: dict) -> str:
    t = prop.get("type") or "?"
    opts = ((prop.get(t) or {}) if isinstance(prop.get(t), dict) else {}).get("options") or []
    names = [o.get("name") for o in opts if isinstance(o, dict) and o.get("name")]
    return f"{t}: {' | '.join(names)}" if names else t


def notion_database(db: dict) -> dict:
    out: dict = {"id": db.get("id"), "objekt": db.get("object")}
    title = _rich(db.get("title")) if isinstance(db.get("title"), list) else db.get("title")
    if title:
        out["titel"] = title
    desc = _rich(db.get("description")) if isinstance(db.get("description"), list) else None
    if desc:
        out["beschreibung"] = desc
    props = {n: _schema_entry(p) for n, p in (db.get("properties") or {}).items() if isinstance(p, dict)}
    if props:
        out["eigenschaften"] = props
    if db.get("data_sources"):
        out["data_sources"] = [{"id": d.get("id"), "name": d.get("name")} for d in db["data_sources"] if isinstance(d, dict)]
    return out


def compact(v, titles: dict[str, str] | None = None):
    """Generisch: leere Werte, Metadaten, URLs, Icons, Binärdaten weg, Ein-Schlüssel-Verschachtelungen flach.
    Notion-Seiten und -Datenbanken werden gezielt vereinfacht. IDs von Datensätzen bleiben (zum späteren Ändern)."""
    titles = titles or {}
    if isinstance(v, dict):
        obj = v.get("object")
        if obj == "page" and isinstance(v.get("properties"), dict):
            return notion_page(v, titles)
        if obj in ("database", "data_source") and isinstance(v.get("properties"), dict):
            return notion_database(v)
        if "plain_text" in v and v.get("type") in ("text", "mention", "equation"):
            return v.get("plain_text") or None
        out: dict = {}
        for k, x in v.items():
            if k in DROP_KEYS or (k in FALSE_NOISE and not x) or (isinstance(x, str) and URL_KEY.search(k)):
                continue
            if k == "object" and isinstance(x, str):
                continue
            if isinstance(x, dict) and set(x) <= {"id", "object"} and x.get("object") in ("user", "bot"):
                continue  # Verweis auf Notion-Nutzer ohne Namen
            c = compact(x, titles)
            if _empty(c):
                continue
            if isinstance(c, dict) and len(c) == 1:
                (kk, vv), = c.items()
                out[f"{k}.{kk}"] = vv
            else:
                out[k] = c
        return out
    if isinstance(v, list):
        if v and all(isinstance(x, dict) and "plain_text" in x for x in v):
            return _rich(v) or None
        out_l = [compact(x, titles) for x in v]
        return [x for x in out_l if not _empty(x)]
    if isinstance(v, str):
        if B64.match(v):
            return f"[Binärdaten, {len(v)} Zeichen]"
        if len(v) > MAX_STRING:
            return v[:MAX_STRING] + f" …[gekürzt, insgesamt {len(v)} Zeichen]"
    return v


def _relation_ids(v, out: set[str]) -> None:
    """Alle verknüpften Seiten-IDs aus Notion-Seiten (für Titel)."""
    if isinstance(v, dict):
        if v.get("object") == "page" and isinstance(v.get("properties"), dict):
            for p in v["properties"].values():
                if isinstance(p, dict) and p.get("type") == "relation":
                    out.update(x["id"] for x in p.get("relation") or [] if isinstance(x, dict) and x.get("id"))
            return
        for x in v.values():
            _relation_ids(x, out)
    elif isinstance(v, list):
        for x in v:
            _relation_ids(x, out)


def _own_titles(v, out: dict[str, str]) -> None:
    if isinstance(v, dict):
        if v.get("object") == "page" and v.get("id"):
            t = _title_of(v)
            if t:
                out[v["id"]] = t
            return
        for x in v.values():
            _own_titles(x, out)
    elif isinstance(v, list):
        for x in v:
            _own_titles(x, out)


def unwrap(data):
    """REST liefert manche Werkzeuge als {"response_data": {...}}; der Tool Router packt das aus."""
    while isinstance(data, dict) and len(data) == 1 and isinstance(data.get("response_data"), (dict, list)):
        data = data["response_data"]
    return data


# -- Obergrenze ----------------------------------------------------------------------
def _size(v) -> int:
    return len(json.dumps(v, ensure_ascii=False, separators=(",", ":")))


def _biggest_list(d) -> tuple[dict | None, str | None]:
    """Größte Liste direkt im Ergebnis oder eine Ebene tiefer → (Eltern-Objekt, Schlüssel)."""
    best: tuple[int, dict | None, str | None] = (0, None, None)
    if not isinstance(d, dict):
        return None, None
    for k, x in d.items():
        if isinstance(x, list) and len(x) > 1:
            s = _size(x)
            if s > best[0]:
                best = (s, d, k)
        elif isinstance(x, dict):
            for kk, xx in x.items():
                if isinstance(xx, list) and len(xx) > 1:
                    s = _size(xx)
                    if s > best[0]:
                        best = (s, x, kk)
    return best[1], best[2]


def fit(result: dict, budget: int) -> dict:
    """Kürzt die größte Zeilenliste eines Ergebnisses auf `budget` Zeichen, mit ehrlichem Hinweis."""
    if _size(result) <= budget:
        return result
    data = result.get("data")
    parent, key = _biggest_list(data)
    if parent is not None and key:
        rows = parent[key]
        total = len(rows)
        lo, hi = 0, total
        while lo < hi:  # größte Anzahl Zeilen, die passt
            mid = (lo + hi + 1) // 2
            parent[key] = rows[:mid]
            if _size(result) + 400 <= budget:
                lo = mid
            else:
                hi = mid - 1
        parent[key] = rows[:lo]
        more = bool(_find(data, ("has_more", "next_cursor", "nextPageToken", "next_page_token")))
        result["hinweis"] = (f"Gekürzt: {lo} von {total} Zeilen dieser Seite gezeigt (Grenze {budget} Zeichen). "
                             f"Die übrigen {total - lo} fehlen hier – frag sie gezielt ab (Filter oder kleinere "
                             f"Seitengröße, z. B. page_size={max(lo, 1)}) statt sie zu raten."
                             + (" Danach gibt es weitere Seiten (next_cursor)." if more else ""))
        if _size(result) <= budget:
            return result
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    result["data"] = text[: max(budget - 600, 1000)] + " …[abgeschnitten]"
    result["hinweis"] = ("Abgeschnitten: Die Antwort war zu groß. Frag gezielter ab (Filter, weniger Felder, "
                         "kleinere Seitengröße) statt fehlende Teile zu raten.")
    return result


def _find(v, keys: tuple[str, ...]):
    if isinstance(v, dict):
        for k in keys:
            if v.get(k):
                return v[k]
        for x in v.values():
            if isinstance(x, (dict, list)):
                r = _find(x, keys)
                if r:
                    return r
    elif isinstance(v, list):
        for x in v[:3]:
            r = _find(x, keys) if isinstance(x, (dict, list)) else None
            if r:
                return r
    return None


def _paging_hint(result: dict) -> None:
    """„N Zeilen geladen, weitere mit next_cursor“, wenn die API weitere Seiten meldet."""
    data = result.get("data")
    if not isinstance(data, dict) or result.get("hinweis"):
        return
    cursor = _find(data, ("next_cursor", "nextPageToken", "next_page_token"))
    has_more = data.get("has_more")
    if not cursor and not has_more:
        return
    parent, key = _biggest_list(data)
    n = len(parent[key]) if parent is not None and key else None
    result["hinweis"] = ((f"{n} Zeilen geladen. " if n is not None else "")
                         + "Es gibt weitere: für die nächste Seite denselben Aufruf mit diesem Cursor wiederholen"
                         + (f" (next_cursor/page token: {cursor})." if cursor else "."))


# -- Ausführung ----------------------------------------------------------------------
class ComposioDirect:
    """Hängt zwischen MCPHub und Tool Router (nur COMPOSIO_MULTI_EXECUTE_TOOL)."""

    def __init__(self, connections) -> None:
        self.conn = connections
        self._titles: dict[tuple[str, str], tuple[float, str | None]] = {}
        self._lock = threading.Lock()

    # Konten -----------------------------------------------------------------------
    def _accounts(self) -> list[dict]:
        try:
            return [a for a in self.conn.accounts() if a.get("status") == "active"]
        except Exception:  # noqa: BLE001 – Composio nicht erreichbar: alles über den Tool Router
            return []

    def resolve_account(self, slug: str, account: str | None, accounts: list[dict]) -> str | None:
        """Gleiches Konto wie der Tool Router: `account` (Alias, E-Mail oder ID) bzw. das einzige aktive Konto.
        Mehrere Konten ohne Angabe → None (dann entscheidet der Tool Router)."""
        app, _ = split_slug(slug, sorted({a["app"] for a in accounts}))
        mine = [a for a in accounts if a["app"] == app]
        key = (account or "").strip().lower()
        if not key:
            return mine[0]["id"] if len(mine) == 1 else None
        for a in mine:
            if key in (a.get("alias", "").lower(), a.get("email", "").lower(), a["id"].lower()):
                return a["id"]
        return None

    # REST -------------------------------------------------------------------------
    def _rest(self, slug: str, account_id: str, args: dict) -> dict:
        _, _, uid = self.conn._cfg()  # noqa: SLF001
        return self.conn._req("POST", f"/v3/tools/execute/{slug}", timeout=90,  # noqa: SLF001
                              json={"user_id": uid, "connected_account_id": account_id, "version": "latest",
                                    "arguments": args or {}})

    def _direct(self, item: dict, account_id: str) -> dict | None:
        """Ergebnis wie beim Tool Router oder None (dann Tool Router). Werkzeugfehler (z. B. falsche Argumente)
        kommen als Ergebnis zurück, Fehler der Composio-API (Werkzeug/Konto unbekannt, Ausfall) nicht."""
        slug = str(item.get("tool_slug") or "")
        try:
            d = self._rest(slug, account_id, item.get("arguments") or {})
        except httpx.TimeoutException:
            return {"successful": False, "error": "Zeitüberschreitung bei Composio (90 s)"}
        except Exception as e:  # noqa: BLE001
            print(f"Composio direkt {slug}: {str(e)[:200]} – weiter über den Tool Router", flush=True)
            return None
        if d.get("successful") is False or d.get("error"):
            return {"successful": False, "error": str(d.get("error") or "Composio meldet einen Fehler")[:1500]}
        return {"successful": True, "data": unwrap(d.get("data")), "_account": account_id}

    def _resolve_titles(self, account_id: str, ids: set[str]) -> dict[str, str]:
        now = time.time()
        out: dict[str, str] = {}
        todo: list[str] = []
        with self._lock:
            for i in ids:
                hit = self._titles.get((account_id, i))
                if hit and now - hit[0] < TITLE_TTL:
                    if hit[1]:
                        out[i] = hit[1]
                else:
                    todo.append(i)
        todo = todo[:RELATION_LOOKUPS]

        def one(pid: str) -> tuple[str, str | None]:
            try:
                d = self._rest("NOTION_FETCH_ROW", account_id, {"page_id": pid})
                page = unwrap(d.get("data")) or {}
                page = page.get("page_data", page) if isinstance(page, dict) else {}
                return pid, _title_of(page) if isinstance(page, dict) and d.get("successful") is not False else None
            except Exception:  # noqa: BLE001
                return pid, None

        if todo:
            with ThreadPoolExecutor(max_workers=8) as ex:
                found = list(ex.map(one, todo))
            with self._lock:
                for pid, title in found:
                    self._titles[(account_id, pid)] = (now, title)
                    if title:
                        out[pid] = title
        return out

    def _compact_result(self, slug: str, res: dict, apps: list[str]) -> dict:
        out: dict = {"tool_slug": slug, "successful": bool(res.get("successful"))}
        if res.get("error"):
            out["error"] = str(res["error"])[:1500]
        if "data" in res:
            data = res["data"]
            titles: dict[str, str] = {}
            if split_slug(slug, apps)[0] == "notion":
                _own_titles(data, titles)
                rel: set[str] = set()
                _relation_ids(data, rel)
                rel -= set(titles)
                if rel and res.get("_account"):
                    titles.update(self._resolve_titles(res["_account"], rel))
            out["data"] = compact(data, titles)
        if "preview" in res:
            out["vorschau"] = res["preview"]
        return out

    def multi_execute(self, args: dict, router: Callable[[dict], list | str]) -> list[dict] | str:
        items = [t for t in args.get("tools") or [] if isinstance(t, dict)]
        if not items:
            return router(args)
        accounts = self._accounts()
        apps = sorted({a["app"] for a in accounts})
        results: dict[int, dict] = {}
        direct: dict[int, str] = {}
        for i, t in enumerate(items):
            slug = str(t.get("tool_slug") or "")
            if is_readonly(slug, apps):
                acc = self.resolve_account(slug, t.get("account"), accounts)
                if acc:
                    direct[i] = acc
        if direct:
            with ThreadPoolExecutor(max_workers=min(8, len(direct))) as ex:
                futs = {i: ex.submit(self._direct, items[i], acc) for i, acc in direct.items()}
            for i, f in futs.items():
                r = f.result()
                if r is not None:
                    results[i] = r
        rest = [i for i in range(len(items)) if i not in results]
        note: str | None = None
        if rest:
            sub = {k: v for k, v in args.items() if k != "tools"}
            sub["tools"] = [items[i] for i in rest]
            if len(rest) < len(items):
                sub["sync_response_to_workbench"] = bool(args.get("sync_response_to_workbench"))
            try:
                raw = router(sub)
            except Exception as e:  # noqa: BLE001
                if not results:
                    raise
                raw = None
                for i in rest:
                    results[i] = {"successful": False, "error": str(e)[:1500]}
            if raw is not None:
                parsed = _parse_router(raw)
                if parsed is None:  # unbekanntes Format: unverändert durchreichen (nur wenn nichts direkt lief)
                    if not results:
                        return raw
                    for i in rest:
                        results[i] = {"successful": False, "error": _text(raw)[:1500]}
                else:
                    by_local, file_note = parsed
                    for local, i in enumerate(rest):
                        r = by_local.get(local) or {"successful": False, "error": "Keine Antwort vom Tool Router"}
                        if "preview" in r:
                            slug = str(items[i].get("tool_slug") or "")
                            acc = self.resolve_account(slug, items[i].get("account"), accounts) \
                                if is_readonly(slug, apps) else None
                            full = self._direct(items[i], acc) if acc else None
                            if full is not None:
                                r = full
                        results[i] = r
                    previews = [str(items[i].get("tool_slug")) for i in rest if "preview" in results[i]]
                    if previews:
                        note = PREVIEW_HINT.format(slugs=", ".join(sorted(set(previews))))
                        if file_note:
                            note += " " + file_note
        out_results = [self._compact_result(str(items[i].get("tool_slug") or ""), results[i], apps)
                       for i in range(len(items))]
        for r in out_results:
            _paging_hint(r)
        budget = max(4_000, (LIMIT - 1_000) // max(len(out_results), 1))
        out_results = [fit(r, budget) for r in out_results]
        payload: dict = {"successful": all(r["successful"] for r in out_results), "results": out_results}
        if note:
            payload["hinweis"] = note
        return [{"type": "text", "text": json.dumps(payload, ensure_ascii=False, separators=(",", ":"))}]


def _text(raw) -> str:
    if isinstance(raw, list):
        return " ".join(b.get("text", "") for b in raw if isinstance(b, dict) and b.get("type") == "text")
    return str(raw)


def _parse_router(raw) -> tuple[dict[int, dict], str | None] | None:
    """Antwort des Tool Routers → {lokaler Index: {"successful", "data"|"preview"|"error"}}, Hinweis zur Sandbox-Datei."""
    try:
        d = json.loads(_text(raw))
    except (ValueError, TypeError):
        return None
    data = d.get("data") if isinstance(d, dict) else None
    if not isinstance(data, dict) or not isinstance(data.get("results"), list):
        return None
    out: dict[int, dict] = {}
    for n, r in enumerate(data["results"]):
        if not isinstance(r, dict):
            continue
        idx = r.get("index") if isinstance(r.get("index"), int) else n
        resp = r.get("response") if isinstance(r.get("response"), dict) else {}
        item: dict = {"successful": bool(resp.get("successful", r.get("successful", False)))}
        err = resp.get("error") or r.get("error")
        if err:
            item["error"] = err if isinstance(err, str) else json.dumps(err, ensure_ascii=False)
        if "data" in resp:
            item["data"] = unwrap(resp["data"])
        elif "data_preview" in resp:
            item["preview"] = resp["data_preview"]
        out[idx] = item
    info = data.get("remote_file_info") if isinstance(data.get("remote_file_info"), dict) else {}
    file_note = (f"Die vollständige Antwort liegt nur in der Composio-Sandbox ({info['file_path']}) und ließe sich "
                 "nur mit COMPOSIO_REMOTE_WORKBENCH auswerten.") if info.get("file_path") else None
    return out, file_note
