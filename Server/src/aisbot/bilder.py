"""Bilder erstellen und bearbeiten über das ChatGPT-Abo (docs/bilder.md, ab Server 1.39).

Der Server lässt Bilder ausschließlich vom unveränderten Codex mit dem ChatGPT-Login im Scoops-`CODEX_HOME` erzeugen
(abos.codex_home, eingebautes Bildwerkzeug `image_generation`). Nie über die API, nie mit einem Schlüssel.

- **ChatGPT-Scoops im Codex-Weg** (engine_abo.CodexChatEngine) nutzen das Bildwerkzeug von Codex direkt im Chat-Thread.
  Die Engine meldet jedes fertige Bild (`imageGeneration`-Item) an `ChatImages`; das speichert es in Bibliothek und
  Arbeitsordner und zeigt es im Chat.
- **Alle anderen Läufe** (Claude-Scoops über Abo oder API, OpenAI-Scoops im API-Weg, Hintergrund-Aufgaben) bekommen die
  Werkzeuge `bild_erstellen` und `bild_bearbeiten`. Jeder Aufruf ist ein eigener, kurzer Codex-Lauf (`generate`) ohne
  Shell, ohne MCP-Server, mit Nur-Lese-Sandbox und eigenem Temp-Ordner; das Ergebnis geht als Pfad und Bild zurück.

Gemessen (19.11.2026, Codex 0.169.0, ChatGPT Pro): Bild fertig nach 22–38 s (davon 12–23 s Bilderzeugung), PNG,
1254×1254 (1:1), 1536×1024 (3:2), 1672×941 (16:9), transparenter Hintergrund als PNG mit Alpha. Codex legt jedes Bild
unter `<CODEX_HOME>/generated_images/<Thread>/<Item>.png` ab und schickt es zusätzlich Base64 im Item (`result`).

Grenzen: höchstens MAX_PARALLEL Bildläufe gleichzeitig, Zeitlimit TIMEOUT je Bild, höchstens MAX_INPUTS Eingabebilder
zu je INPUT_MAX_BYTES. Temp-Ordner, Bilddateien in `generated_images` und der Codex-Prozess werden nach jedem Lauf
aufgeräumt. Gäste geteilter Scoops bekommen keine Bildwerkzeuge (ihre Läufe gehen nie über das Abo des Admins).
"""

from __future__ import annotations

import base64
import io
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import abos, i18n, workspace
from .i18n import N_, tx
from .config import UsageBook
from .engine import ExtraTool

DEFAULT_MODEL = "gpt-6.2-sol"  # schnelles Codex-Modell; es ruft nur das Bildwerkzeug auf (config `image_model`)
TIMEOUT = 300.0  # Sekunden je Bild (gemessen 22–38 s)
MAX_PARALLEL = 2  # gleichzeitige Bildläufe auf dem Server (Abo-Limit, Rechnerlast)
QUEUE_WAIT = 180.0  # so lange wartet ein Bild höchstens auf einen freien Platz
MAX_INPUTS = 4
INPUT_MAX_BYTES = 25_000_000  # wie Dateien in der Bibliothek (tasks.FILE_MAX)
INPUT_MAX_SIDE = 2048  # größere Eingabebilder werden vorher verkleinert
PREVIEW_SIDE = 1024  # Bild im Werkzeug-Ergebnis (damit der Scoop es ansehen kann)
FORMATS = ("1:1", "3:2", "2:3", "16:9", "9:16", "4:3", "3:4")
IMAGE_TOOLS = ("bild_erstellen", "bild_bearbeiten")
IMAGE_EXTS = {".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".webp": "WEBP"}
MIME = {"PNG": "image/png", "JPEG": "image/jpeg", "WEBP": "image/webp"}
# Hinweis für Menschen (Health, übersetzt bei der Ausgabe); in Texten an den Scoop bleibt er deutsch
CONNECT_HINT = N_("In den Einstellungen unter „KI-Abos“ ChatGPT verbinden (App oder Mac-App „AIS Scoops Server“).")

INSTRUCTIONS = (
    "Du bist der Bildgenerator von AIS Scoops. Deine einzige Aufgabe: mit deinem Bildwerkzeug genau ein Bild erzeugen "
    "bzw. bearbeiten, wie im Auftrag beschrieben. Keine Rückfragen, keine anderen Werkzeuge, kein Code. Übernimm "
    "Seitenverhältnis und Hintergrund aus dem Auftrag. Beim Bearbeiten sind die angehängten Bilder die Grundlage: Ändere "
    "nur, was verlangt ist, alles andere (Ausschnitt, Licht, Details, Personen, Schrift) bleibt genau gleich. Darfst oder "
    "kannst du das Bild nicht erzeugen, erzeuge keins und antworte mit einem Satz, der mit „Abgelehnt:“ beginnt und den "
    "Grund nennt. Sonst antworte nach dem Bild nur mit „Fertig.“")

NATIVE_PROMPT = (
    "Bilder: Du kannst mit deinem eingebauten Bildwerkzeug Bilder erstellen und bearbeiten (über {user_gen} ChatGPT-Abo, "
    "etwa 30 Sekunden pro Bild). Zum Bearbeiten muss das Bild im Gespräch sein: Angehängte Bilder siehst du schon; ein "
    "Bild aus der Bibliothek holst du vorher mit datei_lesen (ID f_…). Seitenverhältnis und transparenten Hintergrund "
    "nennst du in der Bildbeschreibung. Jedes fertige Bild speichert der Server selbst in der Bibliothek und in deinem "
    "Arbeitsordner (Dateien/) und zeigt es im Chat – nicht noch einmal mit datei_zeigen zeigen, keine Pfade oder Links "
    "dazu erfinden. Ein Bild pro Wunsch, außer {user} will mehrere. Lehnt das Bildwerkzeug ab oder ist das Limit "
    "erreicht, sag das ehrlich in einem Satz.")

UNAVAILABLE_PROMPT = (
    "Bilder erstellen oder bearbeiten kannst du gerade nicht: Dafür braucht der Server ein verbundenes ChatGPT-Abo. "
    "Wünscht sich {user} ein Bild, sag in einem Satz, dass er dafür in den Einstellungen unter „KI-Abos“ ChatGPT "
    "verbinden kann. Biete keinen anderen Weg an (auch nicht über die API).")


class ImageError(RuntimeError):
    """Kein Bild (Text ist für den Scoop gedacht)."""


class Refused(ImageError):
    """Codex hat kein Bild erzeugt, meist eine inhaltliche Ablehnung."""


class Cancelled(ImageError):
    pass


@dataclass
class ImageResult:
    data: bytes
    fmt: str  # PNG | JPEG | WEBP
    width: int
    height: int
    revised_prompt: str = ""
    transparent: bool = False
    seconds: float = 0.0
    model: str = DEFAULT_MODEL
    usage: UsageBook = field(default_factory=lambda: UsageBook(billing="abo"))


# -- Verfügbarkeit -----------------------------------------------------------------------------------------------------
def _config() -> dict:
    from .bots import load_config
    return load_config()


def available(cfg: dict | None = None) -> tuple[bool, str | None]:
    """(verfügbar, Grund). Nur mit ChatGPT-Login in Codex; unabhängig vom Abrechnungsmodus, weil es keinen API-Weg
    gibt. Abschaltbar mit `images: false` in config.json. Tests/Probedurchlauf (AISBOT_OFFLINE) nur mit `images: true`,
    damit sie nie still ein echtes Abo nutzen."""
    from . import demo
    cfg = _config() if cfg is None else cfg
    if demo.active(cfg):
        return False, "demo"
    if cfg.get("images") is False:
        return False, "aus"
    if os.environ.get("AISBOT_OFFLINE") == "1" and cfg.get("images") is not True:
        return False, "offline"
    try:
        st = abos.login_status("openai")
    except Exception as e:  # noqa: BLE001
        return False, f"Status: {e}"[:200]
    if not st.get("installed"):
        return False, "Codex fehlt"
    if not st.get("subscription"):
        return False, "nicht verbunden"
    return True, None


def health(cfg: dict | None = None) -> dict:
    """Für /api/health: Fähigkeit (Server kann Bilder) und ob sie gerade nutzbar ist."""
    ok, reason = available(cfg)
    return {"supported": True, "available": ok, "via": "chatgpt_abo",
            "hint": None if ok or reason not in ("nicht verbunden", "Codex fehlt") else i18n.translate(CONNECT_HINT)}


def prompt_note(user: str, cfg: dict | None = None) -> str | None:
    """Systemanweisung des Chat-Laufs: Nur wenn das ChatGPT-Abo fehlt, ein Satz, was der Nutzer tun kann (die Werkzeuge
    erklären sich sonst selbst)."""
    ok, reason = available(cfg)
    return None if ok or reason != "nicht verbunden" else UNAVAILABLE_PROMPT.format(user=user)


def native_prompt(user: str) -> str:
    gen = user + "’" if user[-1:].lower() in ("s", "ß", "x", "z") else user + "s"
    return NATIVE_PROMPT.format(user=user, user_gen=gen)


def image_model(cfg: dict | None = None) -> str:
    """Codex-Modell der Bildläufe: `image_model` aus config.json, sonst DEFAULT_MODEL bzw. das erste Abo-Modell von
    OpenAI im Katalog."""
    cfg = _config() if cfg is None else cfg
    if cfg.get("image_model"):
        return str(cfg["image_model"])
    try:
        from .models_catalog import current
        c = current()
        m = c.models.get(DEFAULT_MODEL)
        if m is None or "chatgpt_abo" not in m.routes:
            return next((k for k, v in c.models.items() if v.provider == "openai" and "chatgpt_abo" in v.routes),
                        DEFAULT_MODEL)
    except Exception:  # noqa: BLE001
        pass
    return DEFAULT_MODEL


# -- Bilddaten ---------------------------------------------------------------------------------------------------------
def _open(data: bytes):
    from PIL import Image
    img = Image.open(io.BytesIO(data))
    img.load()
    return img


def _has_alpha(img) -> bool:
    return img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info)


def _encode(img, fmt: str) -> bytes:
    buf = io.BytesIO()
    if fmt == "JPEG":
        if _has_alpha(img):
            from PIL import Image
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img.convert("RGBA"), mask=img.convert("RGBA").getchannel("A"))
            img = bg
        img.convert("RGB").save(buf, format="JPEG", quality=92, optimize=True)
    else:
        img.save(buf, format=fmt, **({"optimize": True} if fmt == "PNG" else {"quality": 92}))
    return buf.getvalue()


def _heic_to_png(data: bytes) -> bytes | None:
    """HEIC/HEIF (iPhone-Fotos) kann Pillow nicht lesen; auf dem Mac wandelt `sips` es um."""
    if not shutil.which("sips"):
        return None
    tmp = abos.abo_dir() / "bilder" / f"heic-{secrets.token_hex(4)}"
    tmp.mkdir(parents=True, exist_ok=True)
    try:
        src, dst = tmp / "ein.heic", tmp / "aus.png"
        src.write_bytes(data)
        subprocess.run(["sips", "-s", "format", "png", str(src), "--out", str(dst)], capture_output=True, timeout=30)
        return dst.read_bytes() if dst.exists() else None
    except Exception:  # noqa: BLE001
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def prepare_input(data: bytes, name: str = "Bild") -> tuple[bytes, str]:
    """Eingabebild prüfen und für Codex vorbereiten → (Daten, Endung). Zu große Bilder werden verkleinert."""
    if len(data) > INPUT_MAX_BYTES:
        raise ImageError(f"„{name}“ ist größer als {INPUT_MAX_BYTES // 1_000_000} MB.")
    try:
        img = _open(data)
    except Exception:  # noqa: BLE001
        conv = _heic_to_png(data)
        if not conv:
            raise ImageError(f"„{name}“ ist kein lesbares Bild (PNG, JPEG, WebP, GIF oder HEIC).") from None
        data, img = conv, _open(conv)
    fmt = (img.format or "").upper()
    if fmt in ("PNG", "JPEG", "WEBP") and max(img.size) <= INPUT_MAX_SIDE and len(data) <= 8_000_000:
        return data, {"PNG": ".png", "JPEG": ".jpg", "WEBP": ".webp"}[fmt]
    img.thumbnail((INPUT_MAX_SIDE, INPUT_MAX_SIDE))
    if _has_alpha(img):
        return _encode(img.convert("RGBA"), "PNG"), ".png"
    return _encode(img, "JPEG"), ".jpg"


def preview(data: bytes) -> tuple[bytes, str]:
    """Kleine Fassung für das Werkzeug-Ergebnis (der Scoop sieht sich das Bild an und bessert nach)."""
    try:
        img = _open(data)
        img.thumbnail((PREVIEW_SIDE, PREVIEW_SIDE))
        if _has_alpha(img):
            png = _encode(img.convert("RGBA"), "PNG")
            if len(png) < 1_500_000:
                return png, "image/png"
        return _encode(img, "JPEG"), "image/jpeg"
    except Exception:  # noqa: BLE001
        return data, "image/png"


def file_name_for(text: str, wanted: str | None, fmt: str = "PNG") -> tuple[str, str]:
    """(Dateiname, Zielformat). Ohne Wunsch: die ersten Wörter der Beschreibung. Endung bestimmt das Format."""
    ext_of = {"PNG": ".png", "JPEG": ".jpg", "WEBP": ".webp"}
    fmt = fmt if fmt in ext_of else "PNG"
    wanted = (wanted or "").strip()
    if wanted:
        stem, ext = os.path.splitext(workspace.file_name(wanted, tx("Bild")))
        if IMAGE_EXTS.get(ext.lower()):
            return stem + ext, IMAGE_EXTS[ext.lower()]
        return stem.strip() + ext_of[fmt], fmt  # unbekannte Endung (z. B. .gif) → Format des Bildes
    words = re.findall(r"[\w-]+", text or "")[:6]
    stem = " ".join(words).strip()[:60] or tx("Bild {when}", when=time.strftime('%Y-%m-%d %H.%M'))
    stem = stem[:1].upper() + stem[1:]
    return workspace.file_name(stem, tx("Bild")) + ext_of[fmt], fmt


def convert(data: bytes, fmt: str) -> bytes:
    try:
        img = _open(data)
        if (img.format or "").upper() == fmt:
            return data
        return _encode(img, fmt)
    except Exception:  # noqa: BLE001
        return data


def _image_info(data: bytes) -> tuple[str, int, int, bool]:
    try:
        img = _open(data)
        return (img.format or "PNG").upper(), img.size[0], img.size[1], _has_alpha(img)
    except Exception:  # noqa: BLE001
        return "PNG", 0, 0, False


# -- Ereignisse von Codex (gemeinsam für Werkzeug-Läufe und den Chat-Thread) ---------------------------------------------
def is_image_item(it) -> bool:
    return getattr(it, "type", None) == "imageGeneration"


def item_failure(it) -> tuple[str, float | None] | None:
    """(Art, Rücksetzzeit) bei einem gescheiterten Bild, z. B. ("usageLimitExceeded", 1795…)."""
    f = getattr(it, "failure", None)
    if f is None:
        return None
    f = getattr(f, "root", f)
    kind = getattr(f, "type", None) or (f.get("type") if isinstance(f, dict) else None) or "failed"
    reset = getattr(f, "resets_at", None) or (f.get("resetsAt") if isinstance(f, dict) else None)
    return str(kind), float(reset) if reset else None


def generated_dir() -> Path:
    return abos.codex_home() / "generated_images"


def item_bytes(it) -> bytes | None:
    """Bilddaten eines fertigen Items: aus der Datei, die Codex abgelegt hat (nur im eigenen generated_images),
    sonst aus dem Base64-Feld `result`."""
    p = getattr(it, "saved_path", None)
    p = str(getattr(p, "root", p) or "")
    if p:
        try:
            real = os.path.realpath(p)
            if real.startswith(os.path.realpath(generated_dir()) + os.sep) and os.path.isfile(real):
                return Path(real).read_bytes()
        except OSError:
            pass
    raw = getattr(it, "result", None)
    if raw:
        try:
            return base64.b64decode(raw)
        except (ValueError, TypeError):
            return None
    return None


def cleanup_item(it) -> None:
    """Die Datei, die Codex für ein Bild abgelegt hat, wieder entfernen (liegt danach in Bibliothek/Arbeitsordner)."""
    p = getattr(it, "saved_path", None)
    p = str(getattr(p, "root", p) or "")
    base = os.path.realpath(generated_dir())
    if not p:
        return
    real = os.path.realpath(p)
    if not real.startswith(base + os.sep):
        return
    try:
        os.remove(real)
        parent = os.path.dirname(real)
        if parent != base and not os.listdir(parent):
            os.rmdir(parent)
    except OSError:
        pass


def cleanup_thread(thread_id: str | None) -> None:
    if not thread_id or "/" in thread_id or thread_id.startswith("."):
        return
    shutil.rmtree(generated_dir() / thread_id, ignore_errors=True)


def failure_text(kind: str, reset: float | None) -> str:
    if kind == "usageLimitExceeded":
        if reset:
            return tx("Das Bild-Limit des ChatGPT-Abos ist erreicht (wieder ab {time} Uhr).",
                      time=i18n.clock(time.localtime(reset).tm_hour, time.localtime(reset).tm_min))
        return tx("Das Bild-Limit des ChatGPT-Abos ist erreicht.")
    return tx("Das Bild ist gescheitert ({kind}).", kind=kind)


# -- Ein Bildlauf über Codex ---------------------------------------------------------------------------------------------
_slots = threading.BoundedSemaphore(MAX_PARALLEL)
_active = {"n": 0}
_alock = threading.Lock()


def active_runs() -> int:
    return _active["n"]


def overrides() -> tuple[str, ...]:
    """Codex für einen Bildlauf: Login aus dem Scoops-CODEX_HOME, keine Shell, kein Web, keine MCP-Server (das
    Scoops-CODEX_HOME hat keine; Computer Use kommt nur in Chat-Läufen dazu), Bildwerkzeug an."""
    return abos.codex_overrides() + ("features.shell_tool=false", 'web_search="disabled"',
                                     'shell_environment_policy.inherit="core"', "features.image_generation=true")


def _task_text(prompt: str, fmt: str | None, transparent: bool, inputs: list[str]) -> str:
    if inputs:
        which = ("das angehängte Bild" if len(inputs) == 1 else
                 f"die {len(inputs)} angehängten Bilder (in dieser Reihenfolge: "
                 + ", ".join(f"Bild {i + 1} = {n}" for i, n in enumerate(inputs)) + ")")
        out = f"Bearbeite {which}.\nAnweisung: {prompt.strip()}\n"
        out += f"Seitenverhältnis: {fmt}." if fmt in FORMATS else "Seitenverhältnis: wie Bild 1."
    else:
        aspect = fmt if fmt in FORMATS else ("passend zum Motiv" if fmt == "auto" else "1:1")
        out = f"Erstelle ein Bild.\nBeschreibung: {prompt.strip()}\nSeitenverhältnis: {aspect}."
    if transparent:
        out += " Transparenter Hintergrund (PNG mit Alpha)."
    return out


class _Any:
    """Mehrere Abbruch-Signale (Stopp im Chat, Stopp der Aufgabe) als ein Event."""

    def __init__(self, *events) -> None:
        self.events = [e for e in events if e is not None]

    def is_set(self) -> bool:
        return any(e.is_set() for e in self.events)


def generate(prompt: str, *, fmt: str | None = None, transparent: bool = False,
             inputs: list[tuple[bytes, str]] | None = None, cancel=None, line: Callable[[str], None] | None = None,
             timeout: float = TIMEOUT, model: str | None = None,
             on_usage: Callable[[UsageBook, str], None] | None = None) -> ImageResult:
    """Ein Bild über Codex (ChatGPT-Abo). `inputs`: [(Bilddaten, Name)] zum Bearbeiten. Wirft
    abos.SubscriptionUnavailable (nicht verbunden, Limit, Anmeldung abgelaufen), Refused, Cancelled, ImageError."""
    ok, reason = available()
    if not ok:
        raise abos.SubscriptionUnavailable("openai", f"Kein ChatGPT-Abo verbunden ({reason}). {CONNECT_HINT}")
    inputs = list(inputs or [])[:MAX_INPUTS]
    model = model or image_model()
    say = line or (lambda s: None)
    waited = time.time()
    told = False
    while not _slots.acquire(timeout=0.5):
        if cancel is not None and cancel.is_set():
            raise Cancelled("Abgebrochen.")
        if not told:
            say(tx("Wartet auf einen freien Platz für Bilder"))
            told = True
        if time.time() - waited > QUEUE_WAIT:
            raise ImageError(f"Gerade laufen schon {MAX_PARALLEL} Bilder. Versuch es gleich noch einmal.")
    with _alock:
        _active["n"] += 1
    work = abos.abo_dir() / "bilder" / f"{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}"
    usage = UsageBook(billing="abo")
    codex = None
    thread_id = None
    t0 = time.time()
    try:
        work.mkdir(parents=True, exist_ok=True)
        names, paths = [], []
        for i, (data, name) in enumerate(inputs, 1):
            prepared, ext = prepare_input(data, name)
            p = work / f"bild{i}{ext}"
            p.write_bytes(prepared)
            names.append(name)
            paths.append(str(p))
        from openai_codex import ApprovalMode, Codex, CodexConfig, Sandbox, TextInput
        try:
            from openai_codex import LocalImageInput
        except ImportError:  # ältere SDKs
            LocalImageInput = None  # noqa: N806
        codex = Codex(CodexConfig(codex_bin=abos.codex_bin(), config_overrides=overrides(), cwd=str(work),
                                  env=abos.codex_env()))
        try:  # nichts ausweiten (wie im Chat): jede Rückfrage von Codex ablehnen
            from .tasks import _codex_decline
            codex._client._approval_handler = _codex_decline
        except Exception:  # noqa: BLE001
            pass
        thread = codex.thread_start(model=model, sandbox=Sandbox.read_only, approval_mode=ApprovalMode.deny_all,
                                    base_instructions=INSTRUCTIONS, ephemeral=True)
        thread_id = getattr(thread, "id", None)
        items: list = [TextInput(_task_text(prompt, fmt, transparent, names))]
        for p in paths:
            if LocalImageInput is not None:
                items.append(LocalImageInput(p))
            else:
                from openai_codex import ImageInput
                mime = MIME.get(_image_info(Path(p).read_bytes())[0], "image/png")
                items.append(ImageInput(f"data:{mime};base64,{base64.b64encode(Path(p).read_bytes()).decode()}"))
        handle = thread.turn(items, effort="low")
        state = {"done": False, "why": None}
        deadline = time.time() + timeout

        def watch() -> None:
            while not state["done"]:
                why = "cancel" if cancel is not None and cancel.is_set() else ("timeout" if time.time() > deadline else None)
                if why:
                    state["why"] = why
                    try:
                        handle.interrupt()
                    except Exception:  # noqa: BLE001
                        pass
                    return
                time.sleep(0.3)

        threading.Thread(target=watch, daemon=True, name="bild-watch").start()
        image: bytes | None = None
        item_meta: dict = {}
        text, err, fail = "", "", None
        last_total = None
        try:
            for ev in handle.stream():
                p = ev.payload
                if ev.method in ("item/started", "item/completed"):
                    it = getattr(p.item, "root", p.item)
                    if is_image_item(it):
                        if ev.method == "item/started":
                            say(tx("Bearbeitet das Bild") if inputs else tx("Malt das Bild"))
                        else:
                            fail = item_failure(it) or fail
                            data = item_bytes(it) if getattr(it, "status", "completed") != "failed" else None
                            if data:
                                image = data
                                item_meta = {"revised": getattr(it, "revised_prompt", None) or "",
                                             "transparent": bool(getattr(it, "transparent_background", False))}
                            cleanup_item(it)
                    elif ev.method == "item/completed" and (getattr(it, "type", None) == "agentMessage"
                                                            or type(it).__name__ == "AgentMessageThreadItem"):
                        text = getattr(it, "text", "") or text
                elif ev.method == "thread/tokenUsage/updated":
                    tu = getattr(p, "token_usage", None) or getattr(p, "tokenUsage", None)
                    last_total = getattr(tu, "last", None) or last_total
                elif ev.method == "turn/completed":
                    e = getattr(p.turn, "error", None)
                    if e:
                        err = str(getattr(e, "message", "") or e)
                elif ev.method == "error":
                    err = err or str(getattr(p, "message", "") or getattr(getattr(p, "error", None), "message", "") or p)
        finally:
            state["done"] = True
        if last_total is not None:
            cached = getattr(last_total, "cached_input_tokens", 0) or 0
            usage.add_counts(model, max(0, (getattr(last_total, "input_tokens", 0) or 0) - cached),
                             getattr(last_total, "output_tokens", 0) or 0, cached, 0, 1)
        else:
            usage.add_counts(model, 0, 0, 0, 0, 1)
        if state["why"] == "cancel":
            raise Cancelled("Abgebrochen.")
        if image is None and state["why"] == "timeout":
            raise ImageError(f"Zeitlimit von {int(timeout // 60)} Minuten überschritten, kein Bild.")
        if image is None and fail:
            raise abos.SubscriptionUnavailable("openai", failure_text(*fail), limit=fail[0] == "usageLimitExceeded",
                                               resets_at=fail[1])
        if image is None and err:
            kind = abos.classify(err)
            if kind == "limit":
                abos.note_limit("openai", err)
            if kind:
                raise abos.SubscriptionUnavailable("openai", err[:300], limit=kind == "limit")
            raise ImageError(f"Codex: {err[:300]}")
        if image is None:
            reason = re.sub(r"^\s*abgelehnt:\s*", "", text or "", flags=re.I).strip()
            raise Refused(reason[:400] or "Codex hat kein Bild erzeugt.")
        fmt_out, w, h, alpha = _image_info(image)
        return ImageResult(image, fmt_out, w, h, item_meta.get("revised", ""), item_meta.get("transparent") or alpha,
                           round(time.time() - t0, 1), model, usage)
    finally:
        if on_usage is not None:
            try:
                on_usage(usage, model)
            except Exception as e:  # noqa: BLE001
                print("Bild-Nutzung:", e, flush=True)
        if codex is not None:
            try:
                codex.close()
            except Exception:  # noqa: BLE001
                pass
        cleanup_thread(thread_id)
        shutil.rmtree(work, ignore_errors=True)
        with _alock:
            _active["n"] -= 1
        _slots.release()


# -- Speichern und Zeigen ----------------------------------------------------------------------------------------------
def save(svc, chat_id: str, actor_id: str, data: bytes, name: str, *, task_id: str | None = None,
         verb: str = "Bild erstellt", fmt: str | None = None) -> dict:
    """Bild in die Bibliothek des Chats, in den Arbeitsordner des Scoops (Chat: Dateien/, Aufgabe: Aufgaben/<…>/ und
    bilder/ im Arbeitsordner der Aufgabe) und als Karte in den Chat. → {file, workspace, task_path, name}"""
    from .bots import is_group, load_config
    fmt = fmt or _image_info(data)[0]
    data = convert(data, fmt)
    mime = MIME.get(fmt, "image/png")
    f = svc.db.add_file(chat_id, actor_id, name, data, mime)
    cfg = load_config()
    bot = svc.db.bot_row(actor_id) or {"id": actor_id}
    task = None
    if task_id and getattr(svc, "tasks", None):
        # Laufende Aufgabe: deren Datensatz im Speicher (sonst überschreibt der Lauf später die Dateiliste)
        run = svc.tasks.runs.get(task_id)
        task = run.task if run is not None else svc.tasks.row(task_id)
    copy, task_path = None, None
    if task:
        copy = workspace.mirror_task_file(bot, cfg, task, name, data)
        try:  # damit die Aufgabe weiter damit arbeiten kann (nicht in ergebnis/: das käme am Ende doppelt in die Bibliothek)
            dest = workspace.save_bytes(Path(task["workdir"]) / "bilder", name, data)
            task_path = str(dest.relative_to(Path(task["workdir"])))
        except Exception as e:  # noqa: BLE001
            print("Bild in den Arbeitsordner der Aufgabe:", e, flush=True)
        try:
            seen = json.loads(task.get("files") or "[]") + [f["id"]]
            svc.tasks._set(task, files=json.dumps(seen))  # noqa: SLF001 – wie datei_in_bibliothek
        except Exception as e:  # noqa: BLE001
            print("Bild bei der Aufgabe vermerken:", e, flush=True)
    else:
        copy = workspace.mirror_file(bot, cfg, name, data)
    where = f" ({workspace.pretty(copy)})" if copy else ""
    meta = {"icon": "photo", "file_id": f["id"], "image": True,
            "prompt": f"{verb}: „{name}“ ({f['id']}), in der Bibliothek{where}"}
    if is_group(chat_id):
        meta["author_id"] = actor_id
    if task_id:
        meta["task_id"] = task_id
    line = tx("Bild bearbeitet: {name}", name=name) if verb == "Bild bearbeitet" else tx("Bild erstellt: {name}", name=name)
    svc._add(chat_id, "event", line, meta)  # noqa: SLF001
    return {"file": f, "workspace": copy, "task_path": task_path, "name": name}


class ChatImages:
    """Bilder, die Codex im Chat-Thread eines ChatGPT-Scoops erzeugt (CodexChatEngine): speichern und zeigen."""

    def __init__(self, svc, chat_id: str, actor_id: str) -> None:
        self.svc, self.chat_id, self.actor_id = svc, chat_id, actor_id
        self.saved: list[dict] = []

    def started(self, line: Callable[[str], None]) -> None:
        line(tx("Erstellt ein Bild"))

    def completed(self, it, line: Callable[[str], None]) -> None:
        fail = item_failure(it)
        data = item_bytes(it) if getattr(it, "status", "completed") != "failed" else None
        try:
            if not data:
                if fail:
                    line(failure_text(*fail).rstrip("."))
                return
            # Name nach Datum: Codex' überarbeitete Beschreibung ist meist englisch und lang
            name, _fmt = file_name_for("", None, _image_info(data)[0])
            self.saved.append(save(self.svc, self.chat_id, self.actor_id, data, name))
        except Exception as e:  # noqa: BLE001 – ein Speicherfehler darf den Chat-Lauf nicht abbrechen
            print("Bild aus dem Chat speichern:", e, flush=True)
        finally:
            cleanup_item(it)


# -- Werkzeuge für Claude-Scoops, API-Läufe und Aufgaben -------------------------------------------------------------------
def _resolve_inputs(svc, chat_id: str, actor_id: str, refs: list, task_id: str | None) -> list[tuple[bytes, str]]:
    """Eingabebilder: Bibliotheks-IDs (f_…, nur dieser Chat; auch Anhänge des Nutzers), „zuletzt“ (neuestes Bild des
    Chats) oder Pfade (relativ zum Arbeitsordner des Scoops bzw. der Aufgabe, sonst im erlaubten Bereich)."""
    from . import access as acc_mod
    out: list[tuple[bytes, str]] = []
    refs = [str(r).strip() for r in (refs or []) if str(r).strip()]
    if len(refs) > MAX_INPUTS:
        raise ImageError(f"Höchstens {MAX_INPUTS} Eingabebilder.")
    task = svc.tasks.row(task_id) if task_id and getattr(svc, "tasks", None) else None
    for ref in refs:
        if ref.lower() in ("zuletzt", "letztes", "anhang"):
            row = svc.db.one("SELECT id FROM files WHERE chat_id=? AND kind='bild' ORDER BY created_at DESC, rowid DESC "
                             "LIMIT 1", (chat_id,))
            if not row:
                raise ImageError("In diesem Chat gibt es noch kein Bild.")
            ref = row["id"]
        if re.fullmatch(r"f_[\w-]+", ref):
            r = svc.db.file_row(ref)
            if not r or r["chat_id"] != chat_id or not r["path"]:
                raise ImageError(f"Bild {ref} nicht gefunden (nur Dateien dieses Chats; IDs mit dateien_auflisten).")
            if not (r["mime"] or "").startswith("image/") and r["kind"] != "bild":
                raise ImageError(f"„{r['name']}“ ist kein Bild.")
            if (r["size"] or 0) > INPUT_MAX_BYTES:
                raise ImageError(f"„{r['name']}“ ist größer als {INPUT_MAX_BYTES // 1_000_000} MB.")
            out.append((Path(r["path"]).read_bytes(), r["name"]))
            continue
        from .bots import load_config
        from .computer_tools import bot_access
        acc = svc.tasks.access_for(task) if task else bot_access(svc, actor_id)
        if task:
            base = Path(task["workdir"])
        else:
            base = workspace.bot_dir(svc.db.bot_row(actor_id) or {"id": actor_id}, load_config())
        p = Path(os.path.expanduser(ref))
        p = p if p.is_absolute() else base / p
        v = acc_mod.check_read(acc, str(p))
        if not v.ok:
            raise ImageError(v.reason)
        if not p.is_file():
            raise ImageError(f"{workspace.pretty(p)} gibt es nicht.")
        if p.stat().st_size > INPUT_MAX_BYTES:
            raise ImageError(f"„{p.name}“ ist größer als {INPUT_MAX_BYTES // 1_000_000} MB.")
        out.append((workspace.guarded(p.read_bytes), p.name))
    return out


def _error_text(e: Exception, user: str) -> str:
    if isinstance(e, abos.SubscriptionUnavailable):
        if e.limit:
            return (f"Kein Bild: {e.reason} Sag {user} kurz Bescheid; einen anderen Weg (API) gibt es dafür nicht.").strip()
        if "Kein ChatGPT-Abo" in e.reason:
            return f"Kein Bild: Auf dem Server ist kein ChatGPT-Abo verbunden. Sag {user}: {CONNECT_HINT}"
        return (f"Kein Bild: Die ChatGPT-Anmeldung des Servers geht gerade nicht ({e.reason[:160]}). Sag {user}, dass "
                f"er ChatGPT in den Einstellungen unter „KI-Abos“ neu verbinden soll.")
    if isinstance(e, Refused):
        return (f"Codex hat kein Bild erzeugt: {e}. Sag {user} das ehrlich in einem Satz. Höchstens ein neuer Versuch mit "
                "angepasster Beschreibung, wenn das zum Wunsch passt.")
    if isinstance(e, Cancelled):
        return "Abgebrochen (Stopp). Kein Bild."
    return f"Kein Bild: {e}"


def tools(svc, chat_id: str, actor_id: str, st) -> list[ExtraTool]:
    """bild_erstellen und bild_bearbeiten für einen Lauf (Chat oder Aufgabe über `st.task_id`). Nur aufrufen, wenn
    available() und kein Gast-Lauf (bots._tools)."""
    user = svc.user_name
    s = {"type": "string"}
    fmt_prop = {"type": "string", "enum": ["auto", *FORMATS]}

    def run(i: dict, editing: bool):
        task_id = getattr(st, "task_id", None)
        run_ = svc.tasks.runs.get(task_id) if task_id and getattr(svc, "tasks", None) else None
        cancel = _Any(getattr(st, "cancel", None), getattr(run_, "cancel", None))
        text = str(i.get("anweisung" if editing else "beschreibung") or "").strip()
        if not text:
            return "Fehler: " + ("anweisung" if editing else "beschreibung") + " fehlt."
        fmt = str(i.get("format") or "").strip()
        fmt = fmt if fmt in FORMATS or fmt == "auto" else None
        try:
            inputs = _resolve_inputs(svc, chat_id, actor_id, i.get("bilder") or [], task_id) if editing else []
            if editing and not inputs:
                return "Fehler: bilder fehlt (Bibliotheks-ID f_…, „zuletzt“ oder Pfad)."
            booked = svc.db.add_usage

            def on_usage(book: UsageBook, model: str) -> None:
                for m, u in book.by_model.items():
                    booked(actor_id, m, u)

            res = generate(text, fmt=fmt, transparent=bool(i.get("transparent")), inputs=inputs, cancel=cancel,
                           on_usage=on_usage)
        except Exception as e:  # noqa: BLE001
            if not isinstance(e, (ImageError, abos.SubscriptionUnavailable)):
                print("Bild:", str(e)[:300], flush=True)
            return _error_text(e, user)
        name, out_fmt = file_name_for(text, i.get("dateiname"), res.fmt)
        saved = save(svc, chat_id, actor_id, res.data, name, task_id=task_id,
                     verb="Bild bearbeitet" if editing else "Bild erstellt", fmt=out_fmt)
        f = saved["file"]
        msg = (f"{'Bearbeitet' if editing else 'Erstellt'} und gespeichert: „{saved['name']}“ ({f['id']}, "
               f"{res.width}×{res.height} {out_fmt}{', transparent' if res.transparent else ''}, {res.seconds:.0f} s) in der "
               "Bibliothek")
        if saved["workspace"]:
            msg += f" und unter {workspace.pretty(saved['workspace'])}"
        if saved["task_path"]:
            msg += f"; im Arbeitsordner der Aufgabe: {saved['task_path']}"
        msg += (". Es ist schon im Chat zu sehen (nicht noch einmal mit datei_zeigen zeigen). Sieh es dir an; passt "
                f"etwas nicht, bessere mit bild_bearbeiten nach (bilder = ['{f['id']}']).")
        small, mime = preview(res.data)
        return [{"type": "text", "text": msg},
                {"type": "image", "source": {"type": "base64", "media_type": mime, "data": base64.b64encode(small).decode()}}]

    def schema(name: str, desc: str, props: dict, req: list[str]) -> dict:
        return {"name": name, "description": desc,
                "input_schema": {"type": "object", "properties": props, "required": req, "additionalProperties": False}}

    common = ("Läuft über das ChatGPT-Abo von " + user + " (kein API-Schlüssel) und dauert etwa 30 Sekunden. Das fertige "
              "Bild landet in der Bibliothek und im Arbeitsordner, erscheint sofort im Chat, und du bekommst es zum "
              "Ansehen zurück. format = Seitenverhältnis ('auto' = passend zum Motiv), transparent = freigestellt mit "
              "transparentem Hintergrund (PNG), dateiname optional (Endung .png, .jpg oder .webp).")
    return [
        ExtraTool(schema("bild_erstellen", "Erstellt ein neues Bild (Foto, Illustration, Grafik, Icon, Sticker …) nach "
                         "einer Beschreibung. beschreibung = Motiv, Stil, Stimmung, Farben, Text im Bild wörtlich. "
                         + common,
                         {"beschreibung": s, "format": fmt_prop, "transparent": {"type": "boolean"}, "dateiname": s},
                         ["beschreibung"]),
                  lambda i: run(i, False), lambda i: tx("Erstellt ein Bild")),
        ExtraTool(schema("bild_bearbeiten", "Bearbeitet vorhandene Bilder nach einer Anweisung (Farbe ändern, etwas "
                         "hinzufügen oder entfernen, Hintergrund tauschen, Stil, mehrere Bilder kombinieren); der Rest "
                         "bleibt möglichst gleich. bilder = 1–4 Bilder: Bibliotheks-IDs (f_…, auch Anhänge, die "
                         + user + " geschickt hat), 'zuletzt' für das neueste Bild im Chat oder Pfade (relativ zu deinem "
                         "Arbeitsordner). anweisung = was sich ändern soll. format leer = wie das erste Bild. " + common,
                         {"bilder": {"type": "array", "items": s}, "anweisung": s, "format": fmt_prop,
                          "transparent": {"type": "boolean"}, "dateiname": s},
                         ["bilder", "anweisung"]),
                  lambda i: run(i, True), lambda i: tx("Bearbeitet ein Bild")),
    ]
