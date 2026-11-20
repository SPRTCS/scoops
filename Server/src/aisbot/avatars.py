"""Eigene Scoop-Bilder (statt des gezeichneten Maskottchens).

Das hochgeladene Bild wird quadratisch (mittig) zugeschnitten, auf höchstens 512 px verkleinert und
im Datenordner unter `avatars/<bot_id>.<jpg|png>` abgelegt. Die Version (Millisekunden-Zeitstempel)
steht in `bots.avatar_version`; die App lädt das Bild nur neu, wenn sich die Version ändert.
Bilder mit Transparenz bleiben PNG, alles andere wird JPEG.
"""

from __future__ import annotations

import io
import time
from pathlib import Path

from PIL import Image, ImageOps

from .db import DATA_DIR
from .i18n import tx

AVATAR_DIR = DATA_DIR / "avatars"
SIZE = 512
MAX_BYTES = 15 * 1024 * 1024
MAX_PIXELS = 60_000_000  # Schutz vor „Dekompressionsbomben“


class AvatarError(ValueError):
    pass


def _path(bot_id: str, ext: str) -> Path:
    safe = "".join(c for c in bot_id if c.isalnum() or c in "_-")
    return AVATAR_DIR / f"{safe}.{ext}"


def current_path(bot_id: str) -> Path | None:
    for ext in ("jpg", "png"):
        p = _path(bot_id, ext)
        if p.exists():
            return p
    return None


def _has_alpha(img: Image.Image) -> bool:
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        alpha = img.convert("RGBA").getchannel("A")
        return alpha.getextrema()[0] < 250
    return False


def process(data: bytes, size: int = SIZE) -> tuple[bytes, str]:
    """Bilddaten → (quadratisches Bild, Endung). Wirft AvatarError bei kaputten/zu großen Bildern."""
    if not data:
        raise AvatarError(tx("Leeres Bild"))
    if len(data) > MAX_BYTES:
        raise AvatarError(tx("Bild ist größer als 15 MB"))
    try:
        Image.MAX_IMAGE_PIXELS = MAX_PIXELS
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception as e:  # noqa: BLE001
        raise AvatarError(tx("Kein lesbares Bild (JPEG, PNG, HEIC als JPEG, WebP, GIF)")) from e
    img = ImageOps.exif_transpose(img)  # Handyfotos richtig herum
    alpha = _has_alpha(img)
    img = img.convert("RGBA" if alpha else "RGB")
    side = min(img.size)
    left, top = (img.width - side) // 2, (img.height - side) // 2
    img = img.crop((left, top, left + side, top + side))
    if side > size:
        img = img.resize((size, size), Image.LANCZOS)
    out = io.BytesIO()
    if alpha:
        img.save(out, "PNG", optimize=True)
        return out.getvalue(), "png"
    img.save(out, "JPEG", quality=88, optimize=True, progressive=True)
    return out.getvalue(), "jpg"


def save(bot_id: str, data: bytes) -> int:
    """Speichert das Bild und gibt die neue Version zurück (Aufrufer schreibt sie in die DB)."""
    body, ext = process(data)
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    remove(bot_id)
    target = _path(bot_id, ext)
    tmp = target.with_suffix(".tmp")
    tmp.write_bytes(body)
    tmp.replace(target)
    return int(time.time() * 1000)


def remove(bot_id: str) -> None:
    for ext in ("jpg", "png"):
        _path(bot_id, ext).unlink(missing_ok=True)


def resized(path: Path, size: int) -> tuple[bytes, str]:
    """Kleinere Fassung (z. B. 128 px für Widgets), ohne die gespeicherte Datei zu ändern."""
    img = Image.open(path)
    img.load()
    png = path.suffix == ".png"
    img = img.convert("RGBA" if png else "RGB").resize((size, size), Image.LANCZOS)
    out = io.BytesIO()
    if png:
        img.save(out, "PNG", optimize=True)
        return out.getvalue(), "image/png"
    img.save(out, "JPEG", quality=85, optimize=True)
    return out.getvalue(), "image/jpeg"

