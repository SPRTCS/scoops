"""Arbeitsordner der Scoops auf dem Server-Mac (docs/arbeitsordner.md).

Der Nutzer wählt einen Ordner (config.json `workspace_dir`, Standard `~/Scoops`). Darin hat jeder Scoop einen
Unterordner mit seinem Namen:

    <arbeitsordner>/<Scoop>/Dateien/                    einzeln gespeicherte Dateien (datei_speichern, datei_auf_rechner)
    <arbeitsordner>/<Scoop>/Aufgaben/<JJJJ-MM-TT Titel>/ Ergebnisse von Hintergrund-Aufgaben

Die Bibliothek bleibt die Hauptablage; der Arbeitsordner ist eine Kopie für den Finder. Spiegeln ist deshalb immer
„best effort“: Fehler werden protokolliert (und im Status angezeigt), brechen aber nie das Speichern ab.

Regeln:
- Dateien werden nie überschrieben. Gibt es den Namen schon mit anderem Inhalt, heißt die neue Datei „Name (2).md“;
  mit gleichem Inhalt wird nichts doppelt abgelegt.
- Umbenennen eines Scoops benennt seinen Ordner mit um (nur wenn der neue Name noch frei ist).
- Ein neuer Arbeitsordner verschiebt nichts: Die alten Ordner bleiben, wo sie sind, und werden im Status unter
  `previous` angezeigt.
"""

from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
import tempfile
import threading
import unicodedata
from datetime import datetime
from pathlib import Path

from .db import TZ
from .profile import DATA_DIR
from .profile import HOME as SERVER_HOME

CONFIG_KEY = "workspace_dir"
PREVIOUS_KEY = "workspace_previous"
DEFAULT_DIR = "~/Scoops"
FILES_SUB = "Dateien"
TASKS_SUB = "Aufgaben"
MAX_PREVIOUS = 3
# Ordnerauswahl über die API: nur innerhalb dieses Ordners (Tests setzen einen Temp-Ordner)
BROWSE_ROOT = Path.home()
BROWSE_LIMIT = 500
PACKAGE_SUFFIXES = (".app", ".bundle", ".framework", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".imovielibrary",
                    ".fcpbundle", ".xcodeproj", ".xcworkspace", ".pkg", ".plugin", ".kext")

_lock = threading.Lock()
last_error: str | None = None  # letzter Fehler beim Spiegeln (für den Status in den Einstellungen)


IO_TIMEOUT = 8.0  # Sekunden; danach gilt ein Dateizugriff als hängend (z. B. offene macOS-Datenschutz-Abfrage)
PENDING_HINT = ("macOS fragt auf dem Server-Mac vermutlich gerade, ob der Server auf diesen Ordner zugreifen darf. Bitte dort "
                "„Erlauben“ wählen oder einen Ordner außerhalb von Schreibtisch und Dokumente nehmen.")


class WorkspaceError(ValueError):
    """Ungültiger oder nicht nutzbarer Ordner (Text ist für Menschen gedacht)."""


def guarded(fn, *args, timeout: float | None = None):
    """Führt einen Dateizugriff mit Zeitgrenze aus. macOS hält Zugriffe auf Schreibtisch/Dokumente an, bis jemand die
    Datenschutz-Abfrage beantwortet; ein Scoop-Lauf oder eine API-Anfrage darf daran nie hängen bleiben."""
    box: dict = {}

    def run() -> None:
        try:
            box["value"] = fn(*args)
        except BaseException as e:  # noqa: BLE001
            box["error"] = e

    th = threading.Thread(target=run, daemon=True, name="workspace-io")
    th.start()
    th.join(IO_TIMEOUT if timeout is None else timeout)
    if th.is_alive():
        raise WorkspaceError(PENDING_HINT)
    if "error" in box:
        raise box["error"]
    return box.get("value")


# -- Pfade ---------------------------------------------------------------------------------------------------------------
def default_dir() -> str:
    """Standard für neue Server: `~/Scoops` (außerhalb von iCloud, Schreibtisch und Dokumente).

    Testinstanzen (eigener Datenordner bzw. AISBOT_OFFLINE) bekommen einen Ordner neben ihren Daten, damit Tests nie
    im echten Home-Ordner schreiben."""
    env = (os.environ.get("AISBOT_WORKSPACE") or "").strip()
    if env:
        return env
    if os.environ.get("AISBOT_DATA") or os.environ.get("AISBOT_OFFLINE") == "1":
        return str(DATA_DIR.parent / "Scoops")
    return DEFAULT_DIR


def expand(raw: str) -> Path:
    return Path(os.path.abspath(os.path.expanduser(raw)))


def pretty(p: Path | str) -> str:
    """Pfad mit `~` statt Home-Ordner (so liest man ihn im Finder)."""
    s = str(p)
    home = str(Path.home())
    if s == home:
        return "~"
    return "~" + s[len(home):] if s.startswith(home + os.sep) else s


def configured(cfg: dict) -> str:
    return str(cfg.get(CONFIG_KEY) or "").strip() or default_dir()


def root(cfg: dict) -> Path:
    return expand(configured(cfg))


def folder_name(name: str, fallback: str = "Scoop") -> str:
    """Ordnername aus dem Scoop-Namen: ohne / und :, ohne führende Punkte, höchstens 60 Zeichen."""
    n = unicodedata.normalize("NFC", str(name or "")).strip()
    n = re.sub(r"[/:\\\x00-\x1f\x7f]+", "-", n)
    n = re.sub(r"\s+", " ", n).strip(" .-")
    return n[:60].strip() or fallback


def file_name(name: str, fallback: str = "Datei") -> str:
    """Dateiname für den Finder (Umlaute und Leerzeichen bleiben, nur problematische Zeichen werden ersetzt)."""
    n = unicodedata.normalize("NFC", os.path.basename(str(name or "").replace("\\", "/"))).strip()
    n = re.sub(r"[/:\x00-\x1f\x7f]+", "-", n).strip()
    n = n.lstrip(".").strip()
    if len(n) > 150:
        stem, ext = os.path.splitext(n)
        n = stem[: 150 - len(ext)].rstrip() + ext[:20]
    return n or fallback


def _bot_name(bot) -> tuple[str, str]:
    get = bot.get if isinstance(bot, dict) else (lambda k, d=None: bot[k] if k in bot.keys() else d)
    return str(get("name") or ""), str(get("id") or "Scoop")


def bot_dir(bot, cfg: dict, create: bool = False) -> Path:
    name, bid = _bot_name(bot)
    d = root(cfg) / folder_name(name, bid)
    if create:
        d.mkdir(parents=True, exist_ok=True)
    return d


def task_folder(title: str, created_at: str | None) -> str:
    """„2026-11-16 Wochenbericht Leads“ (Datum der Aufgabe, Titel gekürzt)."""
    try:
        day = datetime.fromisoformat(str(created_at)).astimezone(TZ).strftime("%Y-%m-%d")
    except (TypeError, ValueError):
        day = datetime.now(TZ).strftime("%Y-%m-%d")
    t = folder_name(title or "", "Aufgabe")[:70].strip()
    return f"{day} {t}"


def task_dir(bot, cfg: dict, task: dict) -> Path:
    return bot_dir(bot, cfg) / TASKS_SUB / task_folder(task.get("title") or "", task.get("created_at"))


def files_dir(bot, cfg: dict) -> Path:
    return bot_dir(bot, cfg) / FILES_SUB


# -- Schreiben -----------------------------------------------------------------------------------------------------------
def save_bytes(folder: Path, name: str, data: bytes) -> Path:
    """Legt `data` in `folder` ab, ohne etwas zu überschreiben. Gleicher Inhalt unter gleichem Namen → vorhandene Datei."""
    folder.mkdir(parents=True, exist_ok=True)
    base = file_name(name)
    stem, ext = os.path.splitext(base)
    with _lock:
        for i in range(1, 1000):
            target = folder / (base if i == 1 else f"{stem} ({i}){ext}")
            if target.exists():
                try:
                    if target.is_file() and target.stat().st_size == len(data) and target.read_bytes() == data:
                        return target
                except OSError:
                    pass
                continue
            with open(target, "xb") as f:
                f.write(data)
            return target
    raise WorkspaceError(f"Zu viele Dateien mit dem Namen „{base}“")


def _note_error(what: str, e: Exception) -> None:
    global last_error
    msg = f"{what}: {e}"
    if isinstance(e, PermissionError):
        msg += " (macOS erlaubt dem Server diesen Ordner nicht; Datenschutz-Freigabe prüfen oder anderen Ordner wählen)"
    last_error = msg
    print("Arbeitsordner:", msg, flush=True)


def mirror_bytes(folder: Path, name: str, data: bytes) -> Path | None:
    """Wie save_bytes, aber ohne Fehler nach außen (Spiegeln darf das Speichern in der Bibliothek nie verhindern)."""
    global last_error
    try:
        p = guarded(save_bytes, folder, name, data)
        last_error = None
        return p
    except Exception as e:  # noqa: BLE001
        _note_error(f"„{name}“ nicht nach {pretty(folder)} kopiert", e)
        return None


def mirror_file(bot, cfg: dict, name: str, data: bytes) -> Path | None:
    """Einzelne Datei (datei_speichern) → <Scoop>/Dateien/."""
    return mirror_bytes(files_dir(bot, cfg), name, data)


def mirror_task_file(bot, cfg: dict, task: dict, name: str, data: bytes) -> Path | None:
    """Aufgaben-Ergebnis → <Scoop>/Aufgaben/<JJJJ-MM-TT Titel>/."""
    return mirror_bytes(task_dir(bot, cfg, task), name, data)


def ensure_all(bots, cfg: dict) -> list[str]:
    """Unterordner aller Scoops anlegen (beim Start, nach dem Wechsel des Ordners). Gibt Fehler zurück."""
    def make_all() -> list[str]:
        errors = []
        for b in bots:
            try:
                bot_dir(b, cfg, create=True)
            except Exception as e:  # noqa: BLE001
                _note_error(f"Ordner für {_bot_name(b)[0]} nicht angelegt", e)
                errors.append(str(e))
        return errors

    try:
        return guarded(make_all)  # eine Zeitgrenze für alle (hängt einer, hängen meist alle)
    except WorkspaceError as e:
        _note_error("Scoop-Ordner nicht angelegt", e)
        return [str(e)]


def rename_bot(cfg: dict, bot_id: str, old_name: str, new_name: str) -> str:
    """Scoop umbenannt: Ordner mitnehmen, wenn der neue Name noch frei ist. Ergebnis als kurzer Text (für das Protokoll)."""
    try:
        return guarded(_rename_bot, cfg, bot_id, old_name, new_name)
    except WorkspaceError as e:
        _note_error("Ordner nicht umbenannt", e)
        return "Fehler"


def _rename_bot(cfg: dict, bot_id: str, old_name: str, new_name: str) -> str:
    old = root(cfg) / folder_name(old_name, bot_id)
    new = root(cfg) / folder_name(new_name, bot_id)
    if old == new:
        return "unverändert"
    try:
        if not old.is_dir():
            new.mkdir(parents=True, exist_ok=True)
            return "neu angelegt"
        same = new.exists() and os.path.samefile(old, new)  # nur Groß-/Kleinschreibung geändert (APFS)
        if new.exists() and not same:
            print(f"Arbeitsordner: {pretty(new)} gibt es schon, {pretty(old)} bleibt bestehen", flush=True)
            return "neuer Ordner existiert schon, alter bleibt"
        os.rename(old, new)
        return "umbenannt"
    except Exception as e:  # noqa: BLE001
        _note_error(f"Ordner {pretty(old)} nicht umbenannt", e)
        return "Fehler"


# -- Einstellung setzen und prüfen ---------------------------------------------------------------------------------------
def validate(raw: str) -> Path:
    """Prüft einen neuen Arbeitsordner: absoluter Pfad oder `~/…`, anlegbar, beschreibbar. Legt ihn dabei an."""
    return guarded(_validate, raw)


def _validate(raw: str) -> Path:
    raw = str(raw or "").strip()
    if not raw:
        raw = default_dir()
    if not (raw.startswith("/") or raw == "~" or raw.startswith("~/")):
        raise WorkspaceError("Bitte einen absoluten Pfad angeben (beginnt mit / oder ~/).")
    if "\x00" in raw or len(raw) > 500:
        raise WorkspaceError("Ungültiger Pfad.")
    p = expand(raw)
    home = Path.home()
    if p in (Path("/"), home) or p == home.parent:
        raise WorkspaceError("Bitte einen eigenen Ordner wählen, nicht den Home-Ordner oder die oberste Ebene.")
    for blocked in (SERVER_HOME, DATA_DIR, home / "Library"):
        b = expand(str(blocked))
        if p == b or b in p.parents:
            raise WorkspaceError(f"{pretty(p)} liegt in einem Systemordner ({pretty(b)}). Bitte einen anderen Ordner wählen.")
    try:
        p.mkdir(parents=True, exist_ok=True)
    except FileExistsError:
        raise WorkspaceError(f"{pretty(p)} ist eine Datei, kein Ordner.") from None
    except PermissionError:
        raise WorkspaceError(f"Keine Berechtigung, {pretty(p)} anzulegen. macOS erlaubt dem Server diesen Ort nicht "
                             "(Datenschutz-Freigabe) – bitte anderen Ordner wählen.") from None
    except OSError as e:
        raise WorkspaceError(f"{pretty(p)} lässt sich nicht anlegen: {e.strerror or e}") from None
    if not p.is_dir():
        raise WorkspaceError(f"{pretty(p)} ist kein Ordner.")
    try:
        fd, probe = tempfile.mkstemp(prefix=".scoops-schreibtest-", dir=p)
        os.close(fd)
        os.remove(probe)
    except OSError as e:
        raise WorkspaceError(f"In {pretty(p)} darf der Server nicht schreiben ({e.strerror or e}). Bitte anderen Ordner "
                             "wählen oder dem Server in den Systemeinstellungen den Zugriff erlauben.") from None
    return p


def apply(cfg: dict, raw: str) -> tuple[dict, bool]:
    """Neuen Ordner in `cfg` eintragen (ohne zu speichern). Der alte wandert nach `workspace_previous`.
    Gibt (cfg, geändert) zurück. Verschoben wird nichts."""
    p = validate(raw)
    old = root(cfg)
    stored = pretty(p)
    changed = p != old
    if changed:
        prev = [x for x in (cfg.get(PREVIOUS_KEY) or []) if isinstance(x, str)]
        prev = [pretty(old)] + [x for x in prev if expand(x) not in (old, p)]
        cfg[PREVIOUS_KEY] = prev[:MAX_PREVIOUS]
    else:
        prev = [x for x in (cfg.get(PREVIOUS_KEY) or []) if isinstance(x, str) and expand(x) != p]
        if prev:
            cfg[PREVIOUS_KEY] = prev
        else:
            cfg.pop(PREVIOUS_KEY, None)
    cfg[CONFIG_KEY] = stored
    return cfg, changed


def _icloud_hint(p: Path) -> bool:
    home = Path.home()
    for synced in (home / "Desktop", home / "Documents", home / "Library" / "Mobile Documents"):
        if p == synced or synced in p.parents:
            return True
    return False


def _nonempty(d: Path) -> bool:
    try:
        return any(not x.name.startswith(".") for x in d.iterdir())
    except OSError:
        return False


def status(cfg: dict, bots) -> dict:
    """Stand für App und Mac-App: Ordner, Scoop-Unterordner, frühere Ordner mit Dateien."""
    try:
        return guarded(_status, cfg, bots)
    except WorkspaceError as e:
        p = root(cfg)
        return {"path": pretty(p), "absolute": str(p), "default": default_dir(), "is_default": p == expand(default_dir()),
                "exists": False, "writable": False, "icloud": _icloud_hint(p), "error": str(e),
                "scoops": [{"id": _bot_name(b)[1], "name": _bot_name(b)[0], "folder": folder_name(*_bot_name(b)),
                            "path": pretty(p / folder_name(*_bot_name(b))), "exists": False} for b in bots],
                "previous": [], "browse_root": pretty(BROWSE_ROOT)}


def _status(cfg: dict, bots) -> dict:
    p = root(cfg)
    exists = p.is_dir()
    scoops = []
    for b in bots:
        name, bid = _bot_name(b)
        d = p / folder_name(name, bid)
        scoops.append({"id": bid, "name": name, "folder": folder_name(name, bid), "path": pretty(d), "exists": d.is_dir()})
    previous = []
    for raw in cfg.get(PREVIOUS_KEY) or []:
        if not isinstance(raw, str):
            continue
        q = expand(raw)
        if q == p or not q.is_dir():
            continue
        try:
            folders = sorted(x.name for x in q.iterdir() if x.is_dir() and not x.name.startswith(".") and _nonempty(x))
        except OSError:
            folders = []
        if folders:
            previous.append({"path": pretty(q), "absolute": str(q), "folders": folders})
    return {"path": pretty(p), "absolute": str(p), "default": default_dir(), "is_default": p == expand(default_dir()),
            "exists": exists, "writable": exists and os.access(p, os.W_OK), "icloud": _icloud_hint(p),
            "error": last_error, "scoops": scoops, "previous": previous, "browse_root": pretty(BROWSE_ROOT)}


# -- Ordnerauswahl ohne Mac-Dateidialog (iPhone/iPad) ------------------------------------------------------------------
def _hidden(entry: os.DirEntry) -> bool:
    if entry.name.startswith(".") or entry.name.lower().endswith(PACKAGE_SUFFIXES):
        return True
    try:
        return bool(entry.stat(follow_symlinks=False).st_flags & stat.UF_HIDDEN)
    except (OSError, AttributeError):
        return False


def _inside_root(raw: str | None) -> Path:
    base = BROWSE_ROOT.resolve()
    raw = str(raw or "").strip() or "~"
    if raw == "~" or raw.startswith("~/"):
        raw = str(BROWSE_ROOT) + raw[1:]
    if not raw.startswith("/"):
        raise WorkspaceError("Ungültiger Pfad.")
    p = Path(os.path.abspath(raw))
    try:
        real = p.resolve()
    except OSError:
        real = p
    if real != base and base not in real.parents:
        raise WorkspaceError("Nur Ordner innerhalb deines Home-Ordners.")
    return p


def browse(raw: str | None) -> dict:
    """Unterordner eines Ordners (nur Verzeichnisse, keine versteckten, nur innerhalb des Home-Ordners)."""
    return guarded(_browse, raw)


def _browse(raw: str | None) -> dict:
    p = _inside_root(raw)
    if not p.is_dir():
        raise WorkspaceError(f"{pretty(p)} gibt es nicht.")
    try:
        with os.scandir(p) as it:
            dirs = [e for e in it if not _hidden(e) and e.is_dir()]
    except PermissionError:
        raise WorkspaceError(f"Kein Zugriff auf {pretty(p)} (macOS-Datenschutz). Bitte einen anderen Ordner wählen.") from None
    except OSError as e:
        raise WorkspaceError(f"{pretty(p)} lässt sich nicht lesen: {e.strerror or e}") from None
    dirs.sort(key=lambda e: e.name.casefold())
    base = BROWSE_ROOT.resolve()
    parent = None if p.resolve() == base else pretty(p.parent)
    return {"path": pretty(p), "absolute": str(p), "parent": parent, "name": p.name if parent else "Home",
            "dirs": [{"name": e.name, "path": pretty(Path(e.path))} for e in dirs[:BROWSE_LIMIT]],
            "truncated": len(dirs) > BROWSE_LIMIT}


def make_folder(parent: str | None, name: str) -> dict:
    """Neuen Unterordner anlegen (Ordnerauswahl auf iPhone/iPad) und den neuen Ordner auflisten."""
    return guarded(_make_folder, parent, name)


def _make_folder(parent: str | None, name: str) -> dict:
    p = _inside_root(parent)
    n = str(name or "").strip()
    if not n or n.startswith(".") or "/" in n or ":" in n or len(n) > 100 or n in (".", ".."):
        raise WorkspaceError("Ungültiger Ordnername.")
    target = p / unicodedata.normalize("NFC", n)
    try:
        target.mkdir(exist_ok=True)
    except PermissionError:
        raise WorkspaceError(f"Keine Berechtigung, in {pretty(p)} einen Ordner anzulegen.") from None
    except OSError as e:
        raise WorkspaceError(f"Ordner lässt sich nicht anlegen: {e.strerror or e}") from None
    return _browse(str(target))


# -- Läuft der Rechner des Scoops auf dem Server-Mac? -------------------------------------------------------------------
_device_id: str | None = None


def this_mac_device_id() -> str:
    """Geräte-ID dieses Macs, genau wie Scoops Connect sie bildet (Pairing.deviceID: SHA-256 der Hardware-UUID)."""
    global _device_id
    if _device_id is None:
        try:
            out = subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True,
                                 text=True, timeout=5).stdout
            m = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', out)
            _device_id = ("mac-" + hashlib.sha256(("ais-scoops-node:" + m.group(1)).encode()).hexdigest()[:24]) if m else ""
        except Exception:  # noqa: BLE001
            _device_id = ""
    return _device_id


def hub_on_server_mac(hub, db) -> bool:
    """Arbeitet dieser Rechner auf demselben Mac wie der Server? (VM und andere Macs: nein.)"""
    if getattr(hub, "transport", None) is None or getattr(hub, "node_id", "vm") == "vm":
        return False
    row = db.one("SELECT device_id, mode FROM nodes WHERE id=?", (hub.node_id,))
    if not row or (row["mode"] or "direct") != "direct" or not row["device_id"]:
        return False
    return row["device_id"] == this_mac_device_id()


def prompt_line(folder: Path, on_server_mac: bool, user: str) -> str:
    """Hinweis für die Systemanweisung im Chat."""
    d = pretty(folder)
    if on_server_mac:
        return (f"Dein Arbeitsordner auf dem Mac: {d} (Unterordner {FILES_SUB}/ und {TASKS_SUB}/). Dateien, die du für "
                f"{user} auf dem Mac anlegst oder ablegst, kommen dorthin. Was du mit `datei_speichern` in die Bibliothek legst "
                f"und die Ergebnisse deiner Hintergrund-Aufgaben landen automatisch zusätzlich dort; `datei_auf_rechner` "
                f"ohne Pfad legt nach {d}/{FILES_SUB}/. Diese Angabe gilt vor älteren Pfadangaben in deinem Gedächtnis.")
    return (f"Dein Arbeitsordner liegt auf dem Server-Mac unter {d} (nicht auf deinem Rechner). Was du mit `datei_speichern` "
            f"in die Bibliothek legst und die Ergebnisse deiner Hintergrund-Aufgaben landen automatisch dort. Diese Angabe gilt "
            f"vor älteren Pfadangaben in deinem Gedächtnis.")
