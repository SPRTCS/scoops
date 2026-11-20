"""Eigene Nachricht bearbeiten (`PATCH /api/messages/{id}`, docs/API.md „Suche und Chat-Komfort“).

Bearbeiten lässt sich die **jüngste eigene** Nachricht eines Chats. Der Server hält einen laufenden Lauf an, ersetzt den
Text und entscheidet dann zwischen zwei Wegen. Regel dahinter: Der sichtbare Verlauf und das, was der Scoop weiß,
stimmen immer überein.

**Neu antworten (`edited.mode = "replaced"`).** Die Antwort auf die alte Fassung verschwindet, der Scoop antwortet auf
die neue. Das geht nur, wenn sich alles sauber zurücksetzen lässt – in allen Engines:

- API-Engines (Claude, OpenAI) bauen den Verlauf bei jedem Lauf aus der Datenbank (`bots._history`). Gelöschte
  Nachrichten und der neue Text gelten damit sofort; der gespeicherte Stand für „mach weiter“ wird verworfen.
- Abo-Engines (Claude Code, Codex) halten eine Sitzung pro Chat, in der die alte Fassung steht. Die Sitzung wird
  verworfen (`abo_sessions`); der nächste Lauf beginnt eine neue und bekommt den sichtbaren Verlauf als Mitschrift –
  derselbe Weg wie nach einer verlorenen Sitzung (docs/abos.md).
- Gruppen: wie oben für alle Scoops der Gruppe; danach wird neu verteilt, wer antwortet.
- Nebenspuren der alten Antwort: Tagebuch-Eintrag des Laufs und Reaktionen der Scoops auf die Nachricht werden entfernt.

Voraussetzung: Die alte Fassung hat **nichts ausgelöst**. Nach der Nachricht stehen nur Antworten und Arbeitsschritte
von Läufen, die nachweislich nur gelesen haben (`effects = False`, siehe `track_effects`), „Angehalten“ und Abo-Hinweise.
Sobald etwas anderes folgt – Freigabe-Karte, Ereignis (Routine, Datei, Übergabe …), Aufgabe, Nachricht einer anderen
Person, ein Lauf mit Werkzeugen, die etwas verändern, oder ein Lauf ohne diese Angabe (älterer Server) – gilt der zweite Weg.

**Korrektur (`edited.mode = "corrected"`).** Nichts wird gelöscht oder zurückgenommen. Die Nachricht zeigt die neue
Fassung und ist als bearbeitet markiert; im Chat steht das Ereignis „Nachricht bearbeitet“, und der Scoop bekommt die
Korrektur (alte und neue Fassung) als neuen Auftrag. So bleibt auch eine Abo-Sitzung stimmig, in der die alte Fassung steht.
"""

from __future__ import annotations

import json
import re
import threading
import time

from . import i18n
from .db import now_iso
from .i18n import tx

# Eigene Werkzeuge, die nur lesen (alles andere gilt als „hat etwas bewirkt“). `reagieren` steht hier, weil die
# Reaktion an der bearbeiteten Nachricht hängt und beim Zurücksetzen mit entfernt wird.
READONLY_TOOLS = frozenset({
    "erinnerung_suchen", "dateien_auflisten", "datei_lesen", "faehigkeit_lesen", "aufgaben_status", "reagieren",
    "t3_projekte", "t3_threads", "t3_thread_lesen", "anrufe_lesen", "scoops_ueberblick", "chat_lesen", "scoop_details",
    "eskalieren", "app_werkzeug_suchen",
})
# Arbeitsschritte, hinter denen sicher nur Lesen steckt (Websuche, eingebautes Lesen im Abo-Weg, Werkzeugsuche,
# Zusammenfassen des Verlaufs, Verstärkung). Jede andere Zeile, die nicht von einem der Werkzeuge oben stammt, zählt
# als Wirkung: Alle Engines melden jeden Aufruf einer verbundenen App (`engine.mcp_line`) und jede Aktion am Rechner
# als Zeile, bevor sie ihn ausführen. Ändert jemand diese Texte, wird schlimmstenfalls zu oft „Korrektur“ gewählt.
HARMLESS_LINES = frozenset({"Liest eine Webseite", "Liest Dateien auf dem Mac", "Fasst den bisherigen Verlauf zusammen",
                            "Sucht das passende Werkzeug", "Holt sich Verstärkung"})
WAIT_FOR_STOP = 120.0  # Sekunden: so lange wartet das Bearbeiten darauf, dass ein laufender Lauf anhält
REPLY_WAIT = 6.0  # Sekunden: so lange wartet der Endpunkt auf das Ergebnis, danach kommt es per WebSocket
GUEST_ROLES = ("read", "write", "edit")


class EditError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status, self.message = status, message


# -- Was hat ein Lauf bewirkt? ----------------------------------------------------------------------
def _translated_forms() -> tuple[frozenset, tuple, tuple]:
    """Dieselben Zeilen in den übersetzten Fassungen (Statuszeilen entstehen in der Sprache des Inhabers, docs/sprache.md):
    ganze Zeilen, Anfänge („Sucht im Web …“) und Enden („… weiter über den API-Schlüssel“) aus der Tabelle."""
    from .i18n_en import TEXTS
    whole = frozenset(v for k, v in TEXTS.items() if k in HARMLESS_LINES and isinstance(v, str))
    starts = tuple(v.split("{")[0].rstrip(": ") for k, v in TEXTS.items()
                   if k.startswith("Sucht im Web") and isinstance(v, str) and v.split("{")[0].strip())
    ends = tuple(v.rsplit("}", 1)[-1] for k, v in TEXTS.items()
                 if k.endswith("weiter über den API-Schlüssel") and isinstance(v, str) and v.rsplit("}", 1)[-1].strip())
    return whole, starts, ends


def harmless_line(line: str) -> bool:
    if line in HARMLESS_LINES or line.startswith("Sucht im Web") or line.endswith("weiter über den API-Schlüssel"):
        return True
    whole, starts, ends = _translated_forms()
    return line in whole or (bool(starts) and line.startswith(starts)) or (bool(ends) and line.endswith(ends))


class EffectTracker:
    """Merkt sich, ob ein Lauf etwas bewirkt haben kann: aufgerufene Werkzeuge, die nicht nur lesen, und
    Arbeitsschritte, die sich nicht als reines Lesen erklären lassen (verbundene Apps, Rechner, Unbekanntes)."""

    def __init__(self) -> None:
        self.names: list[str] = []  # aufgerufene eigene Werkzeuge mit Wirkung
        self.lines: list[str] = []  # alle Arbeitsschritte des Laufs
        self.readonly_lines: set[str] = set()  # Zeilen der eigenen Werkzeuge, die nur lesen

    def note(self, name: str) -> None:
        if name not in self.names:
            self.names.append(name)

    def unexplained(self) -> list[str]:
        return [s for s in self.lines if s not in self.readonly_lines and not harmless_line(s)]

    def result(self, out=None, uses_computer: bool = False) -> bool:
        return (bool(self.names) or bool(uses_computer) or bool(getattr(out, "used_computer", False))
                or bool(self.unexplained()))


def track_effects(common: dict) -> EffectTracker:
    """Hängt sich an die Werkzeuge und Arbeitsschritte eines Laufs (`extra_tools`, `on_line` in den Engine-Argumenten).
    Das Ergebnis (`tracker.result(out)`) steht danach als `effects` in der Statuszeile und in `run_info` der Antwort."""
    tracker = EffectTracker()
    for t in common.get("extra_tools") or []:  # die Liste entsteht pro Lauf neu (bots._tools)
        name = (t.schema or {}).get("name") or ""
        if name in READONLY_TOOLS:
            if t.status:
                def status(i, _fn=t.status):
                    s = _fn(i)
                    if s:
                        tracker.readonly_lines.add(s)
                    return s

                t.status = status
            continue

        def handler(i, _fn=t.handler, _name=name):
            tracker.note(_name)
            return _fn(i)

        t.handler = handler
    on_line = common.get("on_line")
    if on_line:
        def line(s: str) -> None:
            if s:
                tracker.lines.append(s)
            on_line(s)

        common["on_line"] = line
    return tracker


# -- Prüfen, was nach der Nachricht kam --------------------------------------------------------------
def _meta(row) -> dict:
    try:
        m = json.loads(row["meta"] or "{}")
    except ValueError:
        m = {}
    return m if isinstance(m, dict) else {}


def clean_followers(rows: list) -> bool:
    """True, wenn sich alles nach der bearbeiteten Nachricht folgenlos verwerfen lässt (siehe Modul-Text)."""
    for r in rows:
        meta, role = _meta(r), r["role"]
        if role == "status":
            if meta.get("task") or meta.get("state") == "running" or meta.get("effects") is not False:
                return False
        elif role == "bot":
            if meta.get("peer") or meta.get("task_id") or meta.get("live"):
                return False
            info = meta.get("run_info") if isinstance(meta.get("run_info"), dict) else {}
            if info.get("effects") is False or meta.get("failed") or meta.get("spend_limit") or meta.get("guest_limit"):
                continue
            return False
        elif role == "event":
            stopped = meta.get("icon") == "stop.circle" and (r["text"] or "") == "Angehalten"
            if not (stopped or meta.get("abo_fallback")):
                return False
        else:  # Freigabe, Nachricht einer Person, Unbekanntes
            return False
    return True


def _is_task_message(text: str) -> bool:
    return bool(re.match(r"^/aufgabe\b", (text or "").strip(), re.I))


def _same_author(meta: dict, guest) -> bool:
    if guest:
        return meta.get("author_user_id") == guest.user_id
    return meta.get("author_role") not in GUEST_ROLES


# -- Bearbeiten -------------------------------------------------------------------------------------
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _chat_lock(chat_id: str) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(chat_id, threading.Lock())


def edit_message(service, message_id: str, text, guest=None) -> dict:
    """Ersetzt den Text der jüngsten eigenen Nachricht und stößt die Antwort auf die neue Fassung an.
    `guest`: sharing.Share des Gasts (None = Admin). Gibt die aktualisierte Nachricht zurück."""
    db = service.db
    text = (text if isinstance(text, str) else "").strip()
    row = db.one("SELECT * FROM messages WHERE id=?", (message_id,))
    if not row or row["role"] != "user":
        raise EditError(404, tx("Nachricht nicht gefunden"))
    chat_id, meta = row["bot_id"], _meta(row)
    if not _same_author(meta, guest):
        raise EditError(403, tx("Du kannst nur deine eigenen Nachrichten bearbeiten."))
    if not text and not meta.get("file_ids"):
        raise EditError(400, tx("Leere Nachricht"))
    if meta.get("live"):
        raise EditError(409, tx("Gesprochenes aus dem Live-Sprechmodus lässt sich nicht bearbeiten."))
    if meta.get("task_options") or _is_task_message(row["text"]) or _is_task_message(text):
        raise EditError(409, tx("Aufgaben lassen sich nicht nachträglich bearbeiten. Schick die Aufgabe neu."))
    later = db.q("SELECT meta FROM messages WHERE bot_id=? AND role='user' AND seq>?", (chat_id, row["seq"]))
    if any(_same_author(_meta(r), guest) for r in later):
        raise EditError(409, tx("Nur deine jüngste Nachricht lässt sich bearbeiten. Ältere kannst du erneut senden."))
    if text == (row["text"] or ""):
        return db.msg_dict(row)

    lock = _chat_lock(chat_id)
    if not lock.acquire(timeout=1):
        raise EditError(409, tx("Diese Nachricht wird gerade schon bearbeitet."))
    try:
        # 1. Laufenden Lauf anhalten (nur den Chat-Lauf; Hintergrund-Aufgaben laufen weiter)
        with service.lock:
            st = service.runs.get(chat_id)
            if st:
                st.queue.clear()
                st.cancel.set()
        # 2. Text sofort ersetzen; die Antwort folgt, sobald der Lauf steht
        old_text = row["text"] or ""
        meta["edited"] = {"at": now_iso()}
        meta.pop("voice", None)  # die neue Fassung ist getippt
        to_people = service.mentioned_people(chat_id, text, guest) if not chat_id.startswith("g_") else []
        if to_people:
            meta["to_people"] = to_people
        else:
            meta.pop("to_people", None)
        m = db.update_message(message_id, text=text, meta=meta)
        from .profile import user_name
        db.q("UPDATE search_fts SET text=? WHERE ref_id=? AND kind='nachricht'", (f"{user_name()}: {text}", message_id))
        service.publish("message.updated", m)
    except Exception:
        lock.release()
        raise
    worker = threading.Thread(target=_finish, args=(service, lock, chat_id, message_id, old_text, guest), daemon=True,
                              name=f"edit-{chat_id}")
    worker.start()
    worker.join(REPLY_WAIT)
    fresh = db.one("SELECT * FROM messages WHERE id=?", (message_id,))
    return db.msg_dict(fresh) if fresh else m


def _finish(service, lock: threading.Lock, chat_id: str, message_id: str, old_text: str, guest) -> None:
    try:
        deadline = time.time() + WAIT_FOR_STOP
        while time.time() < deadline:
            with service.lock:
                if chat_id not in service.runs:
                    break
            time.sleep(0.1)
        _apply(service, chat_id, message_id, old_text, guest)
    except Exception as e:  # noqa: BLE001 – nie einen hängenden Zustand hinterlassen
        import traceback
        traceback.print_exc()
        print("Nachricht bearbeiten fehlgeschlagen:", e, flush=True)
    finally:
        lock.release()


def _apply(service, chat_id: str, message_id: str, old_text: str, guest) -> None:
    db = service.db
    row = db.one("SELECT * FROM messages WHERE id=?", (message_id,))
    if not row:
        return  # Chat inzwischen geleert
    meta, text = _meta(row), row["text"] or ""
    group = chat_id.startswith("g_")
    followers = db.q("SELECT * FROM messages WHERE bot_id=? AND seq>? ORDER BY seq", (chat_id, row["seq"]))
    with service.lock:
        still_running = chat_id in service.runs
    guest_opts = {"guest": {"user_id": guest.user_id, "name": guest.name, "role": guest.role}} if guest else {}
    edited = dict(meta.get("edited") or {"at": now_iso()})

    if not still_running and clean_followers(followers):
        # -- Neu antworten: alles nach der Nachricht verwerfen ------------------------------------
        actors = [chat_id]
        if group:
            g = db.group_row(chat_id)
            actors = json.loads(g["members"]) if g else []
        ids = [r["id"] for r in followers]
        _drop_journal(service, chat_id, followers, row["created_at"])
        for i in range(0, len(ids), 400):
            part = ids[i:i + 400]
            ph = ",".join("?" * len(part))
            db.q(f"DELETE FROM messages WHERE id IN ({ph})", tuple(part))
            db.q(f"DELETE FROM search_fts WHERE kind='nachricht' AND ref_id IN ({ph})", tuple(part))
        for a in actors:
            service.resumes.clear(chat_id, a)
        db.drop_abo_session(chat_id)
        if isinstance(meta.get("reactions"), dict):  # Reaktionen der Scoops galten der alten Fassung
            meta["reactions"] = {k: v for k, v in meta["reactions"].items() if not k.startswith("b_")}
            if not meta["reactions"]:
                meta.pop("reactions")
        edited["mode"] = "replaced"
        meta["edited"] = edited
        for mid in ids:
            service.publish("message.deleted", {"id": mid, "bot_id": chat_id})
        service.publish("message.updated", db.update_message(message_id, meta=meta))
        _mark_read(service, chat_id, guest)
        service._emit_chat(chat_id)
        if group:
            ref = meta.get("reply_to") if isinstance(meta.get("reply_to"), dict) else {}
            replied = ref.get("author_id") if ref.get("role") == "bot" else None
            for actor in service._route(chat_id, text, replied):
                service.enqueue(chat_id, actor)
        elif not meta.get("to_people"):
            service.enqueue(chat_id, chat_id, opts=dict(guest_opts))
        return

    # -- Korrektur: nichts zurücknehmen, dem Scoop die neue Fassung als Auftrag geben --------------
    edited["mode"] = "corrected"
    meta["edited"] = edited
    service.publish("message.updated", db.update_message(message_id, meta=meta))
    who = guest.name if guest else service.user_name
    prompt = (f"{who} hat eine frühere Nachricht nachträglich korrigiert. Alte Fassung: „{_cut(old_text, 600)}“. "
              f"Neue Fassung: „{_cut(text, 2000)}“. Im Verlauf steht jetzt nur noch die neue Fassung; was du danach "
              "geantwortet oder getan hast, bezog sich auf die alte. Antworte jetzt auf die korrigierte Fassung. Was du "
              "schon erledigt oder angestoßen hast (Aufgaben, Freigaben, Aktionen), bleibt bestehen: nichts "
              "stillschweigend rückgängig machen und nichts doppelt ausführen. Sag kurz, was sich durch die Korrektur "
              "ändert, und pass nur das Nötige an.")
    with i18n.for_owner():  # gespeicherte Zeile im Chat: Sprache des Inhabers (auch wenn ein Gast bearbeitet)
        shown = tx("Nachricht bearbeitet")
    service._add(chat_id, "event", shown, {"icon": "pencil", "prompt": prompt, "edit_of": message_id})
    _mark_read(service, chat_id, guest)
    if meta.get("to_people"):
        return
    if group:
        actors: list[str] = []
        for r in followers:  # wer auf die alte Fassung geantwortet hat, antwortet auf die neue
            a = _meta(r).get("author_id")
            if r["role"] in ("bot", "status") and a and a not in actors and db.bot_row(a):
                actors.append(a)
        for actor in actors or service._route(chat_id, text):
            service.enqueue(chat_id, actor)
    else:
        service.enqueue(chat_id, chat_id, opts=dict(guest_opts))


def _cut(s: str, limit: int) -> str:
    s = re.sub(r"\s+", " ", s or "").strip()
    return s if len(s) <= limit else s[: limit - 1].rstrip() + "…"


def _mark_read(service, chat_id: str, guest) -> None:
    """Wie beim Senden: Wer schreibt, hat den Chat gelesen."""
    db = service.db
    if guest:
        db.guest_mark_read(guest.user_id, chat_id)
    else:
        db.q(f"UPDATE {'groups' if chat_id.startswith('g_') else 'bots'} SET unread=0 WHERE id=?", (chat_id,))
    if service.pusher:
        service.pusher.badge_changed()


def _drop_journal(service, chat_id: str, followers: list, since: str) -> None:
    """Tagebuch-Einträge der verworfenen Antworten entfernen (bots._journal: erster Satz der Antwort)."""
    from .bots import _plain
    db = service.db
    group = db.group_row(chat_id) if chat_id.startswith("g_") else None
    for r in followers:
        if r["role"] != "bot" or not r["text"]:
            continue
        actor = _meta(r).get("author_id") or chat_id
        t = _plain(r["text"]).split(". ")[0]
        t = t[:180] + ("…" if len(t) > 180 else "")
        forms = [t]
        if group:  # wie bots._journal; der Eintrag entstand in der damaligen Sprache des Inhabers
            forms = []
            for lang in i18n.LANGS:
                with i18n.use(lang):
                    forms.append(tx("(Gruppe {group}) {text}", group=group["name"], text=t))
        for form in dict.fromkeys(forms):
            for mem in db.q("SELECT id FROM memories WHERE bot_id=? AND kind='tagebuch' AND text=? AND created_at>=?",
                            (actor, form, since)):
                db.delete_memory(mem["id"])
