"""Kontoweiter Abo-Verbrauch aus den lokalen Sitzungsprotokollen von Claude Code und Codex (docs/nutzung.md).

Anthropic und OpenAI bieten für Abo-Nutzung keine Verlaufs-API mit Modellen und Token-Arten. Wie ccusage und T3 Code
wertet der Server darum die Protokolle aus, die die offiziellen Programme auf diesem Mac schreiben – von allen Apps,
die sie nutzen (Claude Code im Terminal, T3 Code, Codex, VS Code …) und von den Scoops selbst.

Datenschutz (harte Regeln):
- Gelesen werden nur Zeitstempel, Modell, Token-Zähler, Sitzungs-ID, App-Kennung (`entrypoint`/`originator`) und das
  Arbeitsverzeichnis (nur zur Zuordnung „Scoops“, nicht gespeichert). Gesprächsinhalte werden nie gespeichert, geloggt
  oder ausgegeben; Zeilen ohne Zähler werden gar nicht erst als JSON gelesen.
- Anmeldedateien (auth.json, .credentials.json, Schlüsselbund) werden nie angefasst: gelesen werden nur `*.jsonl` bzw.
  `*.jsonl.zst` unter `projects/` (Claude) und `sessions/`/`archived_sessions/` (Codex).

Doppelzählungen:
- Claude Code schreibt eine Antwort oft in mehrere Zeilen (eine pro Inhaltsblock) mit derselben `message.id` und
  `requestId` → ein Eintrag je Schlüssel (größter Zählerstand gewinnt), wie ccusage.
- Codex meldet `token_count` mit kumulativen Summen (`total_token_usage`) → Differenz zum letzten Stand je Datei;
  Schlüssel `Sitzung:Summe` macht doppelte Meldungen und archivierte/komprimierte Kopien unschädlich.
- Scoops' eigene Abo-Läufe stehen in diesen Protokollen (Scope „scoops“) und in der Tabelle `usage`; die Auswertung
  (usage_report.py) zählt sie nur einmal.

Inkrementell: pro Datei werden Größe, mtime, Lese-Offset und (Codex) der letzte Summenstand gemerkt (`log_files`);
gelesen wird nur, was neu dazugekommen ist. Komprimierte Dateien (`.zst`) werden einmal entpackt und gelesen.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .db import TZ

SCHEMA = """
CREATE TABLE IF NOT EXISTS log_usage (
  key TEXT PRIMARY KEY, provider TEXT NOT NULL, t INTEGER NOT NULL, day TEXT NOT NULL, hour TEXT NOT NULL,
  model TEXT NOT NULL, app TEXT NOT NULL, scope TEXT NOT NULL, session TEXT,
  input INTEGER DEFAULT 0, output INTEGER DEFAULT 0, cache_read INTEGER DEFAULT 0, cache_write INTEGER DEFAULT 0,
  reasoning INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_log_usage_t ON log_usage(t);
CREATE TABLE IF NOT EXISTS log_files (
  path TEXT PRIMARY KEY, size INTEGER, mtime REAL, offset INTEGER, state TEXT
);
"""

MAX_SCAN_AGE = 60.0  # höchstens jede Minute neu einlesen
CHUNK = 1 << 20


@dataclass(frozen=True)
class Source:
    provider: str  # "claude" | "openai"
    root: Path
    scope: str  # "scoops" | "other"


def _data_dir() -> Path:
    from .profile import DATA_DIR
    return DATA_DIR


def _demo_active() -> bool:
    from . import demo
    return demo.active()


def default_sources() -> list[Source]:
    """Protokollordner auf diesem Mac. Scoops: eigene Ordner im Datenordner (Claude Code im Abo-Weg legt seine
    Sitzungen unter `<cwd>/projects` ab, Codex im eigenen CODEX_HOME). API-Läufe der Aufgaben (`tasks/.claude`,
    `tasks/.codex`) gehören nicht dazu: Sie sind in `usage` mit echten Kosten erfasst."""
    data = _data_dir()
    out: list[Source] = []
    if os.environ.get("AISBOT_USAGE_HOME"):
        home = Path(os.environ["AISBOT_USAGE_HOME"])
    elif os.environ.get("AISBOT_OFFLINE") == "1" or _demo_active():
        home = data / "_keine_fremden_protokolle"  # Tests/Probedurchlauf/Demo-Server: nie Armans echte Protokolle lesen
    else:
        home = Path.home()
    claude_dirs = [home / ".claude", home / ".config" / "claude"]
    if os.environ.get("CLAUDE_CONFIG_DIR") and not os.environ.get("AISBOT_USAGE_HOME"):
        claude_dirs += [Path(p) for p in os.environ["CLAUDE_CONFIG_DIR"].split(",") if p.strip()]
    for d in claude_dirs:
        out.append(Source("claude", d / "projects", "other"))
    out.append(Source("claude", data / "abo" / "projects", "scoops"))
    out.append(Source("claude", data / "abo" / "chats" / "projects", "scoops"))
    tasks = data / "tasks"
    if tasks.is_dir():
        for t in sorted(tasks.iterdir()):
            if t.name.startswith("t_") and (t / "projects").is_dir():
                out.append(Source("claude", t / "projects", "scoops"))
    codex_dirs = [home / ".codex"]
    if os.environ.get("CODEX_HOME") and not os.environ.get("AISBOT_USAGE_HOME"):
        codex_dirs.append(Path(os.environ["CODEX_HOME"]))
    for d in codex_dirs:
        out += [Source("openai", d / "sessions", "other"), Source("openai", d / "archived_sessions", "other")]
    scoops_codex = Path(os.environ["AISBOT_CODEX_HOME"]) if os.environ.get("AISBOT_CODEX_HOME") else data / "abo" / "codex"
    out += [Source("openai", scoops_codex / "sessions", "scoops"),
            Source("openai", scoops_codex / "archived_sessions", "scoops")]
    # gleiche Ordner nur einmal (Scoops-Zuordnung hat Vorrang)
    seen: dict[str, Source] = {}
    for s in out:
        k = str(s.root.resolve()) if s.root.exists() else str(s.root)
        if k not in seen or s.scope == "scoops":
            seen[k] = s
    return list(seen.values())


def _iter_files(src: Source):
    if not src.root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(src.root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            if f.endswith(".jsonl") or f.endswith(".jsonl.zst"):
                if src.provider == "openai" and not f.startswith("rollout-"):
                    continue
                yield Path(dirpath) / f


# -- Zeit ------------------------------------------------------------------------------------------------------------
def _ts(s) -> int | None:
    if not s:
        return None
    try:
        if isinstance(s, (int, float)):
            return int(s / 1000 if s > 1e12 else s)
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return int(d.timestamp())
    except (ValueError, TypeError):
        return None


def _day_hour(t: int) -> tuple[str, str]:
    d = datetime.fromtimestamp(t, TZ)
    return d.strftime("%Y-%m-%d"), d.strftime("%Y-%m-%dT%H")


# -- Parser (reine Funktionen, testbar) ------------------------------------------------------------------------------
def _int(v) -> int:
    try:
        return max(0, int(v or 0))
    except (TypeError, ValueError):
        return 0


def _is_scoops_cwd(cwd: str | None, data_dir: str) -> bool:
    return bool(cwd) and (cwd == data_dir or cwd.startswith(data_dir.rstrip("/") + "/"))


def parse_claude_lines(lines, scope: str, data_dir: str) -> list[dict]:
    """Zeilen eines Claude-Code-Protokolls → Verbrauchseinträge (nur Zähler, keine Inhalte)."""
    out: list[dict] = []
    for raw in lines:
        if b'"usage"' not in raw or b'"assistant"' not in raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "assistant":
            continue
        m = d.get("message") or {}
        u = m.get("usage") if isinstance(m, dict) else None
        if not isinstance(u, dict):
            continue
        model = str(m.get("model") or "")
        if not model or model.startswith("<"):
            continue  # "<synthetic>": keine echte Anfrage
        t = _ts(d.get("timestamp"))
        if t is None:
            continue
        rec = {"input": _int(u.get("input_tokens")), "output": _int(u.get("output_tokens")),
               "cache_read": _int(u.get("cache_read_input_tokens")),
               "cache_write": _int(u.get("cache_creation_input_tokens")), "reasoning": 0}
        if not any(rec.values()):
            continue
        mid, rid = m.get("id"), d.get("requestId")
        key = f"c:{mid}:{rid}" if mid and rid else f"c:{mid or ''}:{d.get('uuid') or ''}"
        sc = "scoops" if scope == "scoops" or _is_scoops_cwd(d.get("cwd"), data_dir) else "other"
        app = "scoops" if sc == "scoops" else str(d.get("entrypoint") or "claude")
        out.append({"key": key, "provider": "claude", "t": t, "model": model, "app": app, "scope": sc,
                    "session": d.get("sessionId"), **rec})
    return out


_CODEX_FIELDS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens",
                 "reasoning_output_tokens", "total_tokens")


def parse_codex_lines(lines, state: dict, scope: str, data_dir: str) -> list[dict]:
    """Zeilen eines Codex-Rollouts → Verbrauchseinträge. `state` (pro Datei) hält Sitzung, Modell, App und den letzten
    kumulativen Stand; er wird fortgeschrieben, damit spätere Teile der Datei inkrementell gelesen werden können.
    Zusätzlich landet die jüngste Limit-Meldung (`rate_limits`) in state["rate_limits"] (kontoweit, ohne Inhalte)."""
    out: list[dict] = []
    for raw in lines:
        if b'"token_count"' not in raw and b'"turn_context"' not in raw and b'"session_meta"' not in raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(d, dict):
            continue
        typ, p = d.get("type"), d.get("payload")
        if not isinstance(p, dict):
            continue
        if typ == "session_meta":
            state["session"] = p.get("id") or p.get("session_id") or state.get("session")
            state["app"] = str(p.get("originator") or p.get("source") or "codex")
            if _is_scoops_cwd(p.get("cwd"), data_dir):
                state["scoops"] = True
            continue
        if typ == "turn_context":
            if p.get("model"):
                state["model"] = str(p["model"])
            continue
        if typ != "event_msg" or p.get("type") != "token_count":
            continue
        t = _ts(d.get("timestamp"))
        rl = p.get("rate_limits")
        if isinstance(rl, dict) and t and t >= int((state.get("rate_limits") or {}).get("t") or 0):
            state["rate_limits"] = {"t": t, "data": {k: rl.get(k) for k in ("limit_id", "limit_name", "primary",
                                                                            "secondary", "credits", "plan_type")}}
        info = p.get("info")
        if not isinstance(info, dict):
            continue
        total = info.get("total_token_usage")
        last = info.get("last_token_usage")
        if not isinstance(total, dict) or t is None:
            continue
        cur = {k: _int(total.get(k)) for k in _CODEX_FIELDS}
        if not cur["total_tokens"]:
            cur["total_tokens"] = cur["input_tokens"] + cur["output_tokens"]
        prev = state.get("prev") or {}
        if cur["total_tokens"] == _int(prev.get("total_tokens")):
            continue  # doppelte Meldung
        if cur["total_tokens"] > _int(prev.get("total_tokens")):
            delta = {k: max(0, cur[k] - _int(prev.get(k))) for k in _CODEX_FIELDS}
        elif isinstance(last, dict):  # Zähler zurückgesetzt: letzte Anfrage nehmen
            delta = {k: _int(last.get(k)) for k in _CODEX_FIELDS}
        else:
            delta = cur
        state["prev"] = cur
        cached = min(delta["cached_input_tokens"], delta["input_tokens"])
        rec = {"input": delta["input_tokens"] - cached, "output": delta["output_tokens"], "cache_read": cached,
               "cache_write": delta["cache_write_input_tokens"], "reasoning": delta["reasoning_output_tokens"]}
        if not any(rec.values()):
            continue
        session = state.get("session") or state.get("file") or ""
        sc = "scoops" if scope == "scoops" or state.get("scoops") else "other"
        out.append({"key": f"o:{session}:{cur['total_tokens']}", "provider": "openai", "t": t,
                    "model": state.get("model") or "gpt-unbekannt", "app": "scoops" if sc == "scoops" else
                    (state.get("app") or "codex"), "scope": sc, "session": session, **rec})
    return out


# -- Scanner ---------------------------------------------------------------------------------------------------------
class LogScanner:
    def __init__(self, db, sources: list[Source] | None = None):
        self.db = db
        self._sources = sources
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.status: dict = {"state": "idle", "last_scan": None, "files": 0, "changed": 0, "error": None,
                             "skipped_compressed": 0, "seconds": None}
        with db.lock:
            db.conn.executescript(SCHEMA)
            db.conn.commit()
        self._last = 0.0

    def sources(self) -> list[Source]:
        return self._sources if self._sources is not None else default_sources()

    # Öffentliche Steuerung
    def ensure_fresh(self, wait: float = 0.0, force: bool = False) -> dict:
        """Startet bei Bedarf einen Durchlauf im Hintergrund und wartet höchstens `wait` Sekunden darauf."""
        with self._lock:
            running = self._thread is not None and self._thread.is_alive()
            if not running and (force or time.time() - self._last > MAX_SCAN_AGE):
                self._thread = threading.Thread(target=self._run, daemon=True, name="usage-logs")
                self._thread.start()
                running = True
            th = self._thread
        if running and th is not None and wait > 0:
            th.join(wait)
        return dict(self.status)

    def scan_now(self) -> dict:
        self._run()
        return dict(self.status)

    def _run(self) -> None:
        t0 = time.time()
        self.status.update(state="running", error=None)
        try:
            files, changed, skipped = self._scan()
            self.status.update(files=files, changed=changed, skipped_compressed=skipped)
        except Exception as e:  # noqa: BLE001
            self.status["error"] = str(e)[:200]
            print("Nutzungsprotokolle:", e, flush=True)
        self._last = time.time()
        self.status.update(state="idle", last_scan=self._last, seconds=round(time.time() - t0, 2))

    def _scan(self) -> tuple[int, int, int]:
        known = {r["path"]: r for r in self.db.q("SELECT path,size,mtime,offset,state FROM log_files")}
        data_dir = str(_data_dir().resolve()) if _data_dir().exists() else str(_data_dir())
        files = changed = skipped = 0
        for src in self.sources():
            for path in _iter_files(src):
                files += 1
                try:
                    st = path.stat()
                except OSError:
                    continue
                k = str(path)
                row = known.get(k)
                if row and row["size"] == st.st_size and abs((row["mtime"] or 0) - st.st_mtime) < 1e-6:
                    continue
                if path.suffix == ".zst":
                    try:
                        import zstandard  # noqa: F401
                    except ImportError:
                        skipped += 1
                        continue
                changed += 1
                try:
                    self._read_file(src, path, st, row, data_dir)
                except Exception as e:  # noqa: BLE001
                    print(f"Nutzungsprotokoll {path.name}: {type(e).__name__}", flush=True)
        return files, changed, skipped

    def _read_file(self, src: Source, path: Path, st, row, data_dir: str) -> None:
        compressed = path.suffix == ".zst"
        offset = int(row["offset"] or 0) if row and not compressed else 0
        state = json.loads(row["state"] or "{}") if row and not compressed and row["state"] else {}
        if offset > st.st_size:  # Datei neu geschrieben
            offset, state = 0, {}
        state.setdefault("file", path.name)
        recs: list[dict] = []
        if compressed:
            import zstandard
            with open(path, "rb") as fh, zstandard.ZstdDecompressor().stream_reader(fh) as r:
                lines = _lines(r)
                recs = self._parse(src, lines, state, data_dir)
            new_offset = st.st_size
        else:
            with open(path, "rb") as fh:
                fh.seek(offset)
                consumed = [0]
                lines = _complete_lines(fh, consumed)
                recs = self._parse(src, lines, state, data_dir)
            new_offset = offset + consumed[0]
        self._store(recs)
        rl = state.get("rate_limits")
        if rl:
            self._note_rate_limits(rl)
        self.db.q("INSERT OR REPLACE INTO log_files(path,size,mtime,offset,state) VALUES(?,?,?,?,?)",
                  (str(path), st.st_size, st.st_mtime, new_offset,
                   json.dumps({k: v for k, v in state.items() if k != "rate_limits"})))

    @staticmethod
    def _parse(src: Source, lines, state: dict, data_dir: str) -> list[dict]:
        if src.provider == "claude":
            return parse_claude_lines(lines, src.scope, data_dir)
        return parse_codex_lines(lines, state, src.scope, data_dir)

    def _store(self, recs: list[dict]) -> None:
        if not recs:
            return
        rows = []
        for r in recs:
            day, hour = _day_hour(r["t"])
            rows.append((r["key"], r["provider"], r["t"], day, hour, r["model"], r["app"], r["scope"], r.get("session"),
                         r["input"], r["output"], r["cache_read"], r["cache_write"], r["reasoning"]))
        with self.db.lock:
            self.db.conn.executemany(
                "INSERT INTO log_usage(key,provider,t,day,hour,model,app,scope,session,input,output,cache_read,"
                "cache_write,reasoning) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET "
                "input=MAX(input,excluded.input), output=MAX(output,excluded.output), "
                "cache_read=MAX(cache_read,excluded.cache_read), cache_write=MAX(cache_write,excluded.cache_write), "
                "reasoning=MAX(reasoning,excluded.reasoning), "
                "scope=CASE WHEN excluded.scope='scoops' THEN 'scoops' ELSE scope END, "
                "app=CASE WHEN excluded.scope='scoops' THEN excluded.app ELSE app END", rows)
            self.db.conn.commit()

    def _note_rate_limits(self, rl: dict) -> None:
        cur = self.db.setting("codex_rate_limits_logs")
        try:
            old_t = int(json.loads(cur).get("t") or 0) if cur else 0
        except ValueError:
            old_t = 0
        if int(rl.get("t") or 0) >= old_t:
            self.db.set_setting("codex_rate_limits_logs", json.dumps(rl))


def _complete_lines(fh, consumed: list[int]):
    """Ganze Zeilen ab der aktuellen Position; `consumed[0]` zählt die Bytes bis zum Ende der letzten ganzen Zeile
    (eine halb geschriebene letzte Zeile wird beim nächsten Durchlauf gelesen)."""
    buf = b""
    while True:
        chunk = fh.read(CHUNK)
        if not chunk:
            break
        buf += chunk
        parts = buf.split(b"\n")
        buf = parts.pop()
        for p in parts:
            consumed[0] += len(p) + 1
            yield p


def _lines(reader):
    buf = b""
    while True:
        chunk = reader.read(CHUNK)
        if not chunk:
            break
        buf += chunk
        parts = buf.split(b"\n")
        buf = parts.pop()
        yield from parts
    if buf.strip():
        yield buf
