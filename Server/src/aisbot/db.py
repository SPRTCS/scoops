"""SQLite-Speicher für Bots, Nachrichten, Gedächtnis, Routinen und Kosten.

Ein Nutzer, ein Prozess: eine Verbindung mit Sperre reicht. Alle Funktionen sind threadsicher.
"""

from __future__ import annotations

import json
import os
import secrets
import sqlite3
import threading
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Berlin")
from . import access as _access  # noqa: E402
from .profile import DATA_DIR, user_name  # noqa: E402 – Standard ~/.local/share/ais-bot/data (siehe profile.py)

SCHEMA = """
CREATE TABLE IF NOT EXISTS bots (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, label TEXT DEFAULT '', mascot TEXT NOT NULL,
  character TEXT DEFAULT '', model TEXT NOT NULL, escalation_model TEXT,
  pinned INTEGER DEFAULT 0, section TEXT, created_at TEXT NOT NULL, last_activity TEXT NOT NULL,
  unread INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT DEFAULT '',
  meta TEXT DEFAULT '{}', created_at TEXT NOT NULL, seq INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_bot ON messages(bot_id, seq);
CREATE TABLE IF NOT EXISTS memories (
  id TEXT PRIMARY KEY, bot_id TEXT, kind TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(kind, ref_id UNINDEXED, bot_id UNINDEXED, text, created_at UNINDEXED);
CREATE TABLE IF NOT EXISTS routines (
  id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
  schedule TEXT NOT NULL, schedule_text TEXT DEFAULT '', prompt TEXT DEFAULT '',
  enabled INTEGER DEFAULT 1, next_run TEXT, last_run TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS approvals (
  id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, message_id TEXT NOT NULL, title TEXT NOT NULL,
  details TEXT DEFAULT '', state TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT, bot_id TEXT, model TEXT NOT NULL, dollars REAL NOT NULL,
  input_tokens INTEGER, output_tokens INTEGER, cache_read INTEGER, cache_write INTEGER, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  token TEXT PRIMARY KEY, platform TEXT, name TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS groups (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, members TEXT NOT NULL, pinned INTEGER DEFAULT 0, section TEXT,
  created_at TEXT NOT NULL, last_activity TEXT NOT NULL, unread INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS files (
  id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, author_id TEXT, kind TEXT NOT NULL, name TEXT NOT NULL,
  mime TEXT, size INTEGER DEFAULT 0, path TEXT, url TEXT, note TEXT DEFAULT '', created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_files_chat ON files(chat_id, created_at);
CREATE TABLE IF NOT EXISTS skills (
  id TEXT PRIMARY KEY, bot_id TEXT, name TEXT NOT NULL, description TEXT DEFAULT '', steps TEXT NOT NULL,
  uses INTEGER DEFAULT 0, last_used TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS vault (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT DEFAULT '', domain TEXT DEFAULT '', username TEXT DEFAULT '',
  note TEXT DEFAULT '', last_used TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, mode TEXT NOT NULL DEFAULT 'direct', token_hash TEXT NOT NULL UNIQUE,
  os TEXT DEFAULT '', app_version TEXT DEFAULT '', screen TEXT, created_at TEXT NOT NULL, last_seen TEXT
);
CREATE TABLE IF NOT EXISTS node_pairings (code TEXT PRIMARY KEY, expires_at TEXT NOT NULL, used INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS live_tokens (
  token TEXT PRIMARY KEY, chat_id TEXT NOT NULL, run_id TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS guest_devices (
  token TEXT PRIMARY KEY, user_id TEXT NOT NULL, platform TEXT, name TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, chat_id TEXT NOT NULL, title TEXT NOT NULL, prompt TEXT NOT NULL,
  origin TEXT, engine TEXT NOT NULL, model TEXT NOT NULL, state TEXT NOT NULL, session_id TEXT, workdir TEXT NOT NULL,
  status_message_id TEXT, cost_usd REAL DEFAULT 0, budget_usd REAL NOT NULL, max_minutes INTEGER NOT NULL,
  active_seconds REAL DEFAULT 0, note TEXT, result TEXT, error TEXT, files TEXT DEFAULT '[]', pending TEXT,
  created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_chat ON tasks(chat_id, created_at);
CREATE TABLE IF NOT EXISTS standing_approvals (
  id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, key TEXT NOT NULL, label TEXT NOT NULL, kind TEXT DEFAULT '',
  created_at TEXT NOT NULL, UNIQUE(bot_id, key)
);
CREATE TABLE IF NOT EXISTS guest_reads (
  user_id TEXT NOT NULL, chat_id TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, chat_id)
);
CREATE TABLE IF NOT EXISTS abo_sessions (
  chat_id TEXT NOT NULL, actor_id TEXT NOT NULL, provider TEXT NOT NULL, session_id TEXT NOT NULL,
  last_seq INTEGER NOT NULL DEFAULT 0, model TEXT, updated_at TEXT NOT NULL, PRIMARY KEY (chat_id, actor_id, provider)
);
"""

MIGRATIONS = [
    "ALTER TABLE bots ADD COLUMN voice TEXT",
    "ALTER TABLE approvals ADD COLUMN chat_id TEXT",
    "ALTER TABLE approvals ADD COLUMN action TEXT",
    "ALTER TABLE bots ADD COLUMN is_primary INTEGER DEFAULT 0",
    "ALTER TABLE bots ADD COLUMN computer_node TEXT",  # Scoops Connect: NULL = Bot-Rechner (vm)
    "ALTER TABLE bots ADD COLUMN avatar_version INTEGER",  # eigenes Bild (avatars.py), NULL = Maskottchen
    "ALTER TABLE nodes ADD COLUMN device_id TEXT",  # Scoops Connect: stabile Geräte-ID (Neukopplung ersetzt den Eintrag)
    "ALTER TABLE bots ADD COLUMN sharing TEXT",  # Geteilte Scoops: {"guest_tools": {…}, "guest_budget": 2.0}
    "ALTER TABLE usage ADD COLUMN user_id TEXT",  # Absender des Laufs (Gast-Konto); NULL = Admin
    "ALTER TABLE usage ADD COLUMN billing TEXT",  # 'abo' = über ein KI-Abo (docs/abos.md, dollars 0); NULL = API
    "ALTER TABLE approvals ADD COLUMN guest_user_id TEXT",  # Freigabe aus einem Gast-Lauf
    "CREATE INDEX IF NOT EXISTS idx_usage_user ON usage(user_id, created_at)",
    "ALTER TABLE approvals ADD COLUMN task_id TEXT",  # Freigabe aus einer Hintergrund-Aufgabe (tasks.py)
    "ALTER TABLE tasks ADD COLUMN pid INTEGER",  # Prozess des Agenten (Claude-/Codex-CLI), nach Absturz beenden
    "ALTER TABLE approvals ADD COLUMN always_key TEXT",  # „Immer erlauben“ möglich: Schlüssel der Dauerfreigabe (1.20)
    "ALTER TABLE approvals ADD COLUMN always_label TEXT",
    "ALTER TABLE routines ADD COLUMN model TEXT",  # eigenes Modell der Routine, NULL = Modell des Scoops (1.20)
    "ALTER TABLE bots ADD COLUMN can_review INTEGER DEFAULT 0",  # „Darf andere Scoops prüfen“ (1.21, oversight.py)
    # Aufgaben-Board (1.22, tasks.py): Termin, Abnahme getrennt vom Laufzustand, gewähltes Modell (NULL = wie Scoop)
    "ALTER TABLE tasks ADD COLUMN scheduled_at TEXT",
    "ALTER TABLE tasks ADD COLUMN review TEXT",
    "ALTER TABLE tasks ADD COLUMN reviewed_at TEXT",
    "ALTER TABLE tasks ADD COLUMN archived_at TEXT",
    "ALTER TABLE tasks ADD COLUMN model_choice TEXT",
    "ALTER TABLE tasks ADD COLUMN routine_id TEXT",  # 1.26: Aufgabe aus einer Routine (Board-Kennzeichen, kein „Zu prüfen“)
    "CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state, review)",
    # Rechner-Zugriff (1.29, access.py): {mode, scope, folders} je Scoop (NULL = Automatisch, Nur Arbeitsordner) und
    # gewählter Bereich je Aufgabe ({scope, folders}, NULL = wie Scoop)
    "ALTER TABLE bots ADD COLUMN computer_access TEXT",
    "ALTER TABLE tasks ADD COLUMN access TEXT",
    "ALTER TABLE tasks ADD COLUMN billing TEXT",  # Abrechnung der laufenden Agent-Session: 'abo' | 'api' (docs/abos.md)
]
FILES_DIR = DATA_DIR / "files"
BACKUP_DIR = DATA_DIR.parent / "backups"


def now() -> datetime:
    return datetime.now(TZ)


def now_iso() -> str:
    return now().isoformat(timespec="seconds")


def _strip_photo(mascot):
    """`photo` ist ein abgeleitetes Feld (siehe DB._mascot_out) und wird nie gespeichert."""
    return {k: v for k, v in mascot.items() if k != "photo"} if isinstance(mascot, dict) else mascot


def new_id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_hex(5)}"


class DB:
    def __init__(self, path: Path | None = None):
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        self.path = path or DATA_DIR / "aisbot.db"
        self.conn = sqlite3.connect(self.path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SCHEMA)
        for m in MIGRATIONS:
            try:
                self.conn.execute(m)
            except sqlite3.OperationalError:
                pass  # Spalte existiert schon
        self.conn.commit()
        FILES_DIR.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()

    def q(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self.lock:
            cur = self.conn.execute(sql, args)
            rows = cur.fetchall()
            self.conn.commit()
            return rows

    def one(self, sql: str, args: tuple = ()) -> sqlite3.Row | None:
        rows = self.q(sql, args)
        return rows[0] if rows else None

    def unread_chat_count(self) -> int:
        """Anzahl Chats (Scoops und Gruppen) mit ungelesenen Nachrichten – die Zahl am App-Symbol."""
        r = self.one("SELECT (SELECT COUNT(*) FROM bots WHERE unread>0) + (SELECT COUNT(*) FROM groups WHERE unread>0) AS n")
        return int(r["n"] or 0) if r else 0

    # -- Einstellungen -----------------------------------------------------
    def setting(self, key: str, default: str | None = None) -> str | None:
        r = self.one("SELECT value FROM settings WHERE key=?", (key,))
        return r["value"] if r else default

    def set_setting(self, key: str, value: str) -> None:
        self.q("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (key, value))

    # -- Bots --------------------------------------------------------------
    def bot_row(self, bot_id: str) -> sqlite3.Row | None:
        return self.one("SELECT * FROM bots WHERE id=?", (bot_id,))

    def bot_dict(self, r: sqlite3.Row) -> dict:
        last = self.one(
            "SELECT * FROM messages WHERE bot_id=? AND role IN ('user','bot','event','approval') ORDER BY seq DESC LIMIT 1",
            (r["id"],),
        )
        return {
            "id": r["id"],
            "name": r["name"],
            "label": r["label"] or "",
            "mascot": self._mascot_out(r),
            "avatar": self._avatar_out(r),
            "character": r["character"] or "",
            "model": r["model"],
            "escalation_model": r["escalation_model"],
            "pinned": bool(r["pinned"]),
            "section": r["section"],
            "created_at": r["created_at"],
            "last_message": self.msg_dict(last) if last else None,
            "unread": r["unread"],
            "voice": r["voice"] if "voice" in r.keys() else None,
            "primary": bool(r["is_primary"]) if "is_primary" in r.keys() else False,
            "can_review": bool(r["can_review"]) if "can_review" in r.keys() else False,
            "computer_node": (r["computer_node"] if "computer_node" in r.keys() else None) or "vm",
            "computer_access": _access.public(self.access_of(r)),
            "sharing": self.sharing_of(r),
            "busy": False,  # wird vom Runner überschrieben
        }

    @staticmethod
    def sharing_of(r: sqlite3.Row) -> dict:
        """Admin-Einstellungen für Gäste (roh; normalisiert in sharing.py)."""
        raw = r["sharing"] if "sharing" in r.keys() else None
        try:
            d = json.loads(raw) if raw else {}
        except ValueError:
            d = {}
        return d if isinstance(d, dict) else {}

    @staticmethod
    def access_of(r: sqlite3.Row | dict | None) -> dict:
        """Rechner-Zugriff eines Scoops (roh; normalisiert in access.py)."""
        if r is None:
            return {}
        raw = r["computer_access"] if "computer_access" in r.keys() else None
        try:
            d = json.loads(raw) if raw else {}
        except ValueError:
            d = {}
        return d if isinstance(d, dict) else {}

    def set_access(self, bot_id: str, value: dict) -> None:
        self.q("UPDATE bots SET computer_access=? WHERE id=?", (json.dumps(value, ensure_ascii=False), bot_id))

    def set_sharing(self, bot_id: str, value: dict) -> None:
        self.q("UPDATE bots SET sharing=? WHERE id=?", (json.dumps(value, ensure_ascii=False), bot_id))

    @staticmethod
    def _avatar_version(r: sqlite3.Row) -> int | None:
        return r["avatar_version"] if "avatar_version" in r.keys() else None

    def _avatar_out(self, r: sqlite3.Row) -> dict | None:
        v = self._avatar_version(r)
        return {"version": v, "url": f"/api/bots/{r['id']}/avatar?v={v}"} if v else None

    def _mascot_out(self, r: sqlite3.Row) -> dict:
        """Maskottchen wie gespeichert; mit eigenem Bild zusätzlich `photo: {id, version}` (klein, ohne Bilddaten),
        damit App, Widgets und Live-Aktivität das Bild aus ihrem Zwischenspeicher zeigen können."""
        m = json.loads(r["mascot"])
        m.pop("photo", None)
        v = self._avatar_version(r)
        if v:
            m["photo"] = {"id": r["id"], "version": v}
        return m

    def set_avatar_version(self, bot_id: str, version: int | None) -> None:
        self.q("UPDATE bots SET avatar_version=? WHERE id=?", (version, bot_id))

    def bots(self) -> list[sqlite3.Row]:
        return self.q("SELECT * FROM bots ORDER BY pinned DESC, last_activity DESC")

    def create_bot(self, **f) -> str:
        bid = new_id("b")
        ts = now_iso()
        self.q(
            "INSERT INTO bots(id,name,label,mascot,character,model,escalation_model,pinned,section,created_at,last_activity) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (bid, f["name"], f.get("label", ""), json.dumps(_strip_photo(f["mascot"])), f.get("character", ""), f["model"],
             f.get("escalation_model"), int(f.get("pinned", False)), f.get("section"), ts, ts),
        )
        return bid

    def update_bot(self, bot_id: str, fields: dict) -> None:
        allowed = {"name", "label", "mascot", "character", "model", "escalation_model", "pinned", "section", "voice",
                   "computer_node", "can_review"}
        sets, args = [], []
        for k, v in fields.items():
            if k not in allowed:
                continue
            if k == "mascot":
                v = json.dumps(_strip_photo(v))  # Bild nur über /api/bots/{id}/avatar
            if k in ("pinned", "can_review"):
                v = int(bool(v))
            if k == "section" and isinstance(v, str) and not v.strip():
                v = None
            if k == "computer_node" and (not v or v == "vm"):
                v = None
            sets.append(f"{k}=?")
            args.append(v)
        if sets:
            self.q(f"UPDATE bots SET {','.join(sets)} WHERE id=?", (*args, bot_id))

    # -- Haupt-Scoop ------------------------------------------------------
    def set_primary(self, bot_id: str | None) -> None:
        self.q("UPDATE bots SET is_primary=0")
        if bot_id:
            self.q("UPDATE bots SET is_primary=1 WHERE id=?", (bot_id,))

    def primary_bot(self) -> sqlite3.Row | None:
        return self.one("SELECT * FROM bots WHERE is_primary=1")

    # -- Fähigkeiten -------------------------------------------------------
    def skill_dict(self, r: sqlite3.Row) -> dict:
        return {k: r[k] for k in ("id", "bot_id", "name", "description", "steps", "uses", "last_used", "created_at", "updated_at")}

    def skills(self, bot_id: str | None = None) -> list[dict]:
        if bot_id:
            rows = self.q("SELECT * FROM skills WHERE bot_id=? OR bot_id IS NULL ORDER BY name", (bot_id,))
        else:
            rows = self.q("SELECT * FROM skills ORDER BY name")
        return [self.skill_dict(r) for r in rows]

    def skill_row(self, sid: str) -> sqlite3.Row | None:
        return self.one("SELECT * FROM skills WHERE id=?", (sid,))

    def save_skill(self, bot_id: str | None, name: str, description: str, steps: str) -> dict:
        ts = now_iso()
        existing = self.one("SELECT id FROM skills WHERE lower(name)=lower(?) AND (bot_id IS ? OR bot_id=?)", (name, bot_id, bot_id))
        if existing:
            self.q("UPDATE skills SET description=?, steps=?, updated_at=? WHERE id=?", (description, steps, ts, existing["id"]))
            sid = existing["id"]
        else:
            sid = new_id("sk")
            self.q("INSERT INTO skills(id,bot_id,name,description,steps,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                   (sid, bot_id, name, description, steps, ts, ts))
        return self.skill_dict(self.skill_row(sid))

    # -- Tresor (nur Metadaten; Geheimnisse liegen im Schlüsselbund) -------
    def vault_dict(self, r: sqlite3.Row) -> dict:
        return {k: r[k] for k in ("id", "title", "url", "domain", "username", "note", "last_used", "created_at", "updated_at")}

    def vault_entries(self) -> list[dict]:
        return [self.vault_dict(r) for r in self.q("SELECT * FROM vault ORDER BY title")]

    def vault_row(self, vid: str) -> sqlite3.Row | None:
        return self.one("SELECT * FROM vault WHERE id=?", (vid,))

    # -- Gruppen -----------------------------------------------------------
    def group_row(self, gid: str) -> sqlite3.Row | None:
        return self.one("SELECT * FROM groups WHERE id=?", (gid,))

    def group_dict(self, r: sqlite3.Row) -> dict:
        last = self.one(
            "SELECT * FROM messages WHERE bot_id=? AND role IN ('user','bot','event','approval') ORDER BY seq DESC LIMIT 1",
            (r["id"],),
        )
        return {"id": r["id"], "name": r["name"], "member_ids": json.loads(r["members"]), "pinned": bool(r["pinned"]),
                "section": r["section"], "created_at": r["created_at"], "last_message": self.msg_dict(last) if last else None,
                "unread": r["unread"], "busy": False, "busy_ids": []}

    def groups(self) -> list[sqlite3.Row]:
        return self.q("SELECT * FROM groups ORDER BY pinned DESC, last_activity DESC")

    def create_group(self, name: str, members: list[str]) -> str:
        gid = new_id("g")
        ts = now_iso()
        self.q("INSERT INTO groups(id,name,members,created_at,last_activity) VALUES(?,?,?,?,?)",
               (gid, name, json.dumps(members), ts, ts))
        return gid

    def update_group(self, gid: str, fields: dict) -> None:
        for k, v in fields.items():
            if k == "name" and v:
                self.q("UPDATE groups SET name=? WHERE id=?", (v, gid))
            elif k == "member_ids":
                self.q("UPDATE groups SET members=? WHERE id=?", (json.dumps(v), gid))
            elif k == "pinned":
                self.q("UPDATE groups SET pinned=? WHERE id=?", (int(bool(v)), gid))
            elif k == "section":
                self.q("UPDATE groups SET section=? WHERE id=?", (v if (isinstance(v, str) and v.strip()) else None, gid))

    def delete_group(self, gid: str) -> None:
        self.q("DELETE FROM messages WHERE bot_id=?", (gid,))
        self.q("DELETE FROM search_fts WHERE bot_id=? AND kind='nachricht'", (gid,))
        for f in self.files(gid):
            self.delete_file(f["id"])
        self.q("DELETE FROM groups WHERE id=?", (gid,))

    # -- Dateien -----------------------------------------------------------
    def file_dict(self, r: sqlite3.Row) -> dict:
        return {"id": r["id"], "chat_id": r["chat_id"], "author_id": r["author_id"], "kind": r["kind"], "name": r["name"],
                "mime": r["mime"], "size": r["size"], "url": r["url"], "note": r["note"] or "",
                "created_at": r["created_at"], "download_url": f"/api/files/{r['id']}" if r["path"] else None}

    def add_file(self, chat_id: str, author_id: str | None, name: str, data: bytes | None, mime: str | None,
                 kind: str = "datei", url: str | None = None, note: str = "") -> dict:
        fid = new_id("f")
        path = None
        if data is not None:
            safe = "".join(c if c.isalnum() or c in "._- " else "_" for c in name)[:120] or "datei"
            path = str(FILES_DIR / f"{fid}_{safe}")
            with open(path, "wb") as f:
                f.write(data)
            if kind == "datei" and (mime or "").startswith("image/"):
                kind = "bild"
        self.q("INSERT INTO files(id,chat_id,author_id,kind,name,mime,size,path,url,note,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
               (fid, chat_id, author_id, kind, name, mime, len(data) if data else 0, path, url, note, now_iso()))
        return self.file_dict(self.one("SELECT * FROM files WHERE id=?", (fid,)))

    def file_row(self, fid: str) -> sqlite3.Row | None:
        return self.one("SELECT * FROM files WHERE id=?", (fid,))

    def files(self, chat_id: str) -> list[dict]:
        return [self.file_dict(r) for r in self.q("SELECT * FROM files WHERE chat_id=? ORDER BY created_at DESC", (chat_id,))]

    def delete_file(self, fid: str) -> None:
        r = self.file_row(fid)
        if r and r["path"]:
            try:
                os.remove(r["path"])
            except OSError:
                pass
        self.q("DELETE FROM files WHERE id=?", (fid,))

    # -- Sicherung ---------------------------------------------------------
    def backup(self, keep: int = 14) -> Path:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        target = BACKUP_DIR / f"aisbot-{now():%Y-%m-%d}.db"
        with self.lock:
            dst = sqlite3.connect(target)
            self.conn.backup(dst)
            dst.close()
        os.chmod(target, 0o600)
        olds = sorted(BACKUP_DIR.glob("aisbot-*.db"))
        for old in olds[:-keep]:
            old.unlink()
        return target

    def delete_bot(self, bot_id: str) -> None:
        for t in ("messages", "routines", "approvals", "standing_approvals"):
            self.q(f"DELETE FROM {t} WHERE bot_id=?", (bot_id,))
        self.q("DELETE FROM memories WHERE bot_id=?", (bot_id,))
        self.q("DELETE FROM search_fts WHERE bot_id=?", (bot_id,))
        self.q("DELETE FROM bots WHERE id=?", (bot_id,))
        from .avatars import remove as remove_avatar
        remove_avatar(bot_id)

    # -- Nachrichten -------------------------------------------------------
    def msg_dict(self, r: sqlite3.Row) -> dict:
        return {
            "id": r["id"],
            "bot_id": r["bot_id"],
            "role": r["role"],
            "text": r["text"] or "",
            "created_at": r["created_at"],
            "meta": json.loads(r["meta"] or "{}"),
        }

    def add_message(self, bot_id: str, role: str, text: str = "", meta: dict | None = None) -> dict:
        mid = new_id("m")
        ts = now_iso()
        with self.lock:
            seq = (self.one("SELECT COALESCE(MAX(seq),0)+1 AS s FROM messages")["s"])
            self.q(
                "INSERT INTO messages(id,bot_id,role,text,meta,created_at,seq) VALUES(?,?,?,?,?,?,?)",
                (mid, bot_id, role, text, json.dumps(meta or {}, ensure_ascii=False), ts, seq),
            )
            table = "groups" if bot_id.startswith("g_") else "bots"
            if role in ("user", "bot", "event", "approval"):
                self.q(f"UPDATE {table} SET last_activity=? WHERE id=?", (ts, bot_id))
            if role in ("bot", "approval"):
                self.q(f"UPDATE {table} SET unread=unread+1 WHERE id=?", (bot_id,))
            if role in ("user", "bot") and text:
                self.q("INSERT INTO search_fts(kind,ref_id,bot_id,text,created_at) VALUES('nachricht',?,?,?,?)",
                       (mid, bot_id, f"{user_name() if role == 'user' else 'Bot'}: {text}", ts))
        return self.msg_dict(self.one("SELECT * FROM messages WHERE id=?", (mid,)))

    def update_message(self, mid: str, text: str | None = None, meta: dict | None = None) -> dict:
        if text is not None:
            self.q("UPDATE messages SET text=? WHERE id=?", (text, mid))
        if meta is not None:
            self.q("UPDATE messages SET meta=? WHERE id=?", (json.dumps(meta, ensure_ascii=False), mid))
        return self.msg_dict(self.one("SELECT * FROM messages WHERE id=?", (mid,)))

    def messages(self, bot_id: str, before: str | None = None, limit: int = 50) -> list[dict]:
        if before:
            b = self.one("SELECT seq FROM messages WHERE id=?", (before,))
            rows = self.q("SELECT * FROM messages WHERE bot_id=? AND seq<? ORDER BY seq DESC LIMIT ?",
                          (bot_id, b["seq"] if b else 1 << 62, limit))
        else:
            rows = self.q("SELECT * FROM messages WHERE bot_id=? ORDER BY seq DESC LIMIT ?", (bot_id, limit))
        return [self.msg_dict(r) for r in reversed(rows)]

    def messages_since(self, bot_id: str, seq: int, limit: int = 60) -> list[dict]:
        """Nachrichten nach `seq` (aufsteigend, höchstens `limit` – die jüngsten), jeweils mit `seq`."""
        rows = self.q("SELECT * FROM messages WHERE bot_id=? AND seq>? ORDER BY seq DESC LIMIT ?", (bot_id, seq, limit))
        return [{**self.msg_dict(r), "seq": r["seq"]} for r in reversed(rows)]

    def max_seq(self, bot_id: str) -> int:
        r = self.one("SELECT MAX(seq) s FROM messages WHERE bot_id=?", (bot_id,))
        return int(r["s"] or 0) if r else 0

    # -- KI-Abos: Sitzung pro Chat (docs/abos.md) ----------------------------
    def abo_session(self, chat_id: str, actor_id: str, provider: str) -> dict | None:
        r = self.one("SELECT * FROM abo_sessions WHERE chat_id=? AND actor_id=? AND provider=?", (chat_id, actor_id, provider))
        return dict(r) if r else None

    def set_abo_session(self, chat_id: str, actor_id: str, provider: str, session_id: str, last_seq: int,
                        model: str | None) -> None:
        self.q("INSERT OR REPLACE INTO abo_sessions(chat_id,actor_id,provider,session_id,last_seq,model,updated_at) "
               "VALUES(?,?,?,?,?,?,?)", (chat_id, actor_id, provider, session_id, int(last_seq), model, now_iso()))

    def drop_abo_session(self, chat_id: str, actor_id: str | None = None, provider: str | None = None) -> None:
        sql, args = "DELETE FROM abo_sessions WHERE chat_id=?", [chat_id]
        if actor_id:
            sql, args = sql + " AND actor_id=?", args + [actor_id]
        if provider:
            sql, args = sql + " AND provider=?", args + [provider]
        self.q(sql, tuple(args))

    # -- Gedächtnis --------------------------------------------------------
    def mem_dict(self, r: sqlite3.Row) -> dict:
        return {"id": r["id"], "bot_id": r["bot_id"], "kind": r["kind"], "text": r["text"], "created_at": r["created_at"]}

    def add_memory(self, bot_id: str | None, kind: str, text: str) -> dict:
        mid = new_id("mem")
        ts = now_iso()
        self.q("INSERT INTO memories(id,bot_id,kind,text,created_at) VALUES(?,?,?,?,?)", (mid, bot_id, kind, text, ts))
        self.q("INSERT INTO search_fts(kind,ref_id,bot_id,text,created_at) VALUES(?,?,?,?,?)", (kind, mid, bot_id, text, ts))
        return self.mem_dict(self.one("SELECT * FROM memories WHERE id=?", (mid,)))

    def memories(self, bot_id: str, kinds: tuple[str, ...] = ("profil", "fakt", "tagebuch")) -> list[dict]:
        ph = ",".join("?" * len(kinds))
        rows = self.q(
            f"SELECT * FROM memories WHERE (bot_id=? OR bot_id IS NULL) AND kind IN ({ph}) ORDER BY created_at",
            (bot_id, *kinds),
        )
        return [self.mem_dict(r) for r in rows]

    def delete_memory(self, mem_id: str) -> None:
        self.q("DELETE FROM memories WHERE id=?", (mem_id,))
        self.q("DELETE FROM search_fts WHERE ref_id=?", (mem_id,))

    def search(self, bot_id: str, query: str, limit: int = 8) -> list[dict]:
        terms = " OR ".join(f'"{t}"' for t in query.replace('"', " ").split() if len(t) > 1)
        if not terms:
            return []
        try:
            rows = self.q(
                "SELECT kind, ref_id, text, created_at FROM search_fts WHERE search_fts MATCH ? "
                "AND (bot_id=? OR bot_id IS NULL) ORDER BY rank LIMIT ?",
                (terms, bot_id, limit),
            )
        except sqlite3.OperationalError:
            return []
        return [dict(r) for r in rows]

    # -- Routinen ----------------------------------------------------------
    def routine_dict(self, r: sqlite3.Row) -> dict:
        return {k: (bool(r[k]) if k == "enabled" else r[k]) for k in
                ("id", "bot_id", "kind", "title", "schedule", "schedule_text", "prompt", "enabled", "next_run", "last_run",
                 "model") if k in r.keys()}

    def routines(self, bot_id: str | None = None) -> list[dict]:
        if bot_id:
            rows = self.q("SELECT * FROM routines WHERE bot_id=? ORDER BY next_run", (bot_id,))
        else:
            rows = self.q("SELECT * FROM routines ORDER BY next_run")
        return [self.routine_dict(r) for r in rows]

    # -- Kosten ------------------------------------------------------------
    def add_usage(self, bot_id: str | None, model: str, u, user_id: str | None = None) -> None:
        self.q(
            "INSERT INTO usage(bot_id,model,dollars,input_tokens,output_tokens,cache_read,cache_write,created_at,user_id,"
            "billing) VALUES(?,?,?,?,?,?,?,?,?,?)",
            (bot_id, model, u.dollars, u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens, now_iso(),
             user_id, "abo" if getattr(u, "billing", "api") == "abo" else None),
        )

    def guest_spent_today(self, user_id: str) -> float:
        """Kosten aller Läufe, die dieser Gast heute (Europe/Berlin) ausgelöst hat – über alle geteilten Scoops."""
        r = self.one("SELECT COALESCE(SUM(dollars),0) s FROM usage WHERE user_id=? AND substr(created_at,1,10)=?",
                     (user_id, now().strftime("%Y-%m-%d")))
        return float(r["s"] or 0) if r else 0.0

    def usage_by_person(self, bot_id: str) -> dict:
        """{user_id|None: {today_usd, month_usd, total_usd}} für einen Scoop (None = Admin)."""
        today, month = now().strftime("%Y-%m-%d"), now().strftime("%Y-%m")
        out: dict = {}
        for r in self.q("SELECT user_id, "
                        "SUM(CASE WHEN substr(created_at,1,10)=? THEN dollars ELSE 0 END) t, "
                        "SUM(CASE WHEN substr(created_at,1,7)=? THEN dollars ELSE 0 END) m, SUM(dollars) a "
                        "FROM usage WHERE bot_id=? GROUP BY user_id", (today, month, bot_id)):
            out[r["user_id"]] = {"today_usd": round(r["t"] or 0, 4), "month_usd": round(r["m"] or 0, 4),
                                 "total_usd": round(r["a"] or 0, 4)}
        return out

    # -- Geteilte Scoops: Lesestatus pro Gast --------------------------------
    def guest_unread(self, user_id: str, chat_id: str) -> int:
        r = self.one("SELECT seq FROM guest_reads WHERE user_id=? AND chat_id=?", (user_id, chat_id))
        last = r["seq"] if r else 0
        n = self.one("SELECT COUNT(*) n FROM messages WHERE bot_id=? AND seq>? AND (role IN ('bot') OR "
                     "(role='user' AND meta NOT LIKE ?))", (chat_id, last, f'%"author_user_id": "{user_id}"%'))
        return int(n["n"] or 0) if n else 0

    def guest_mark_read(self, user_id: str, chat_id: str) -> None:
        r = self.one("SELECT COALESCE(MAX(seq),0) s FROM messages WHERE bot_id=?", (chat_id,))
        self.q("INSERT OR REPLACE INTO guest_reads(user_id,chat_id,seq) VALUES(?,?,?)", (user_id, chat_id, r["s"] if r else 0))

    def usage_summary(self) -> dict:
        today = now().strftime("%Y-%m-%d")
        month = now().strftime("%Y-%m")
        t = self.one("SELECT COALESCE(SUM(dollars),0) s FROM usage WHERE substr(created_at,1,10)=?", (today,))["s"]
        m = self.one("SELECT COALESCE(SUM(dollars),0) s FROM usage WHERE substr(created_at,1,7)=?", (month,))["s"]
        by = {r["model"]: round(r["s"], 4) for r in
              self.q("SELECT model, SUM(dollars) s FROM usage WHERE substr(created_at,1,7)=? GROUP BY model", (month,))}
        by_bot = {r["bot_id"]: {"today_usd": round(r["t"] or 0, 4), "month_usd": round(r["m"] or 0, 4)} for r in
                  self.q("SELECT bot_id, SUM(CASE WHEN substr(created_at,1,10)=? THEN dollars ELSE 0 END) t, SUM(dollars) m "
                         "FROM usage WHERE substr(created_at,1,7)=? AND bot_id IS NOT NULL GROUP BY bot_id", (today, month))}
        # KI-Abos (docs/abos.md): Läufe über Claude Code/Codex mit Abo zählen getrennt, ohne Betrag
        abo = {"today_runs": 0, "month_runs": 0, "by_model": {}}
        for r in self.q("SELECT model, SUM(CASE WHEN substr(created_at,1,10)=? THEN 1 ELSE 0 END) t, COUNT(*) m, "
                        "SUM(COALESCE(input_tokens,0)+COALESCE(cache_read,0)+COALESCE(cache_write,0)) i, "
                        "SUM(COALESCE(output_tokens,0)) o FROM usage WHERE billing='abo' AND substr(created_at,1,7)=? "
                        "GROUP BY model", (today, month)):
            abo["today_runs"] += int(r["t"] or 0)
            abo["month_runs"] += int(r["m"] or 0)
            abo["by_model"][r["model"]] = {"runs": int(r["m"] or 0), "input_tokens": int(r["i"] or 0),
                                           "output_tokens": int(r["o"] or 0)}
        return {"today_usd": round(t, 4), "month_usd": round(m, 4), "by_model": by, "by_bot": by_bot, "abo": abo}
