"""Hintergrundbild für die DMG von „AIS Scoops Server“ (640×400 Punkte, dazu @2x).

    uv run --no-project --with pillow python scripts/dmg-background.py <ziel.png>

Erzeugt <ziel.png> und <ziel@2x.png>; dmgbuild kombiniert beide zu einem Retina-Hintergrund.
Icons liegen bei (160, 190) und (480, 190) – siehe build-server-dmg.sh.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 640, 400
FONTS = ["/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf",
         "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"]


def font(size: int) -> ImageFont.FreeTypeFont:
    for f in FONTS:
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    top, bottom = (255, 247, 236), (255, 228, 236)  # Vanille → Erdbeere
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    s = scale
    # Bunte Kugeln als Deko (wie Eiskugeln)
    for (cx, cy, r, col) in [(40, 360, 46, (255, 200, 87)), (600, 40, 38, (124, 92, 255)), (590, 370, 26, (255, 143, 177)),
                             (70, 50, 18, (94, 214, 177))]:
        d.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=tuple(min(255, v + 25) for v in col))
    title = "AIS Scoops Server"
    f1 = font(26 * s)
    tw = d.textlength(title, font=f1)
    d.text(((w - tw) / 2, 42 * s), title, font=f1, fill=(60, 40, 70))
    sub = "Zum Installieren in den Ordner „Programme“ ziehen"
    f2 = font(14 * s)
    sw = d.textlength(sub, font=f2)
    d.text(((w - sw) / 2, 300 * s), sub, font=f2, fill=(110, 90, 120))
    # Pfeil zwischen App (160) und Programme (480)
    y = 190 * s
    d.line([(250 * s, y), (382 * s, y)], fill=(124, 92, 255), width=5 * s)
    d.polygon([(392 * s, y), (374 * s, y - 12 * s), (374 * s, y + 12 * s)], fill=(124, 92, 255))
    return img


def main() -> None:
    out = Path(sys.argv[1])
    draw(1).save(out)
    draw(2).save(out.with_name(out.stem + "@2x" + out.suffix))


if __name__ == "__main__":
    main()
