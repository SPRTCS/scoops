"""Rechner-Treiber: steuert die macOS-VM über den Cua-Computer-Server (HTTP /cmd).

Claude rechnet in Pixeln des Screenshots, den wir zurückgeben. Wir verkleinern
Screenshots auf die logische Bildschirmgröße (Punkte, keine Retina-Pixel), damit
Claude-Koordinaten direkt als Mausposition gelten.
"""

from __future__ import annotations

import base64
import io
import json
import time
from dataclasses import dataclass

import httpx
from PIL import Image

# Höchstens so groß schicken wir Screenshots (lange Kante), siehe Doku-Empfehlung.
MAX_LONG_EDGE = 1440

# Tastennamen im xdotool-Stil (von Claude) -> pyautogui-Namen (vom Server).
KEY_ALIASES = {
    "return": "enter",
    "kp_enter": "enter",
    "escape": "esc",
    "backspace": "backspace",
    "delete": "delete",
    "page_up": "pageup",
    "prior": "pageup",
    "page_down": "pagedown",
    "next": "pagedown",
    "super": "command",
    "super_l": "command",
    "cmd": "command",
    "meta": "command",
    "control": "ctrl",
    "control_l": "ctrl",
    "ctrl_l": "ctrl",
    "alt_l": "option",
    "alt": "option",
    "option": "option",
    "shift_l": "shift",
    "arrowleft": "left",
    "arrowright": "right",
    "arrowup": "up",
    "arrowdown": "down",
    "space": "space",
    "minus": "-",
    "plus": "+",
    "equal": "=",
    "period": ".",
    "comma": ",",
    "slash": "/",
}


def to_pyautogui_key(name: str) -> str:
    k = name.strip()
    low = k.lower()
    if low in KEY_ALIASES:
        return KEY_ALIASES[low]
    if low.startswith("f") and low[1:].isdigit():
        return low
    return low if len(k) > 1 else k



# Bildschirmbilder für die Modelle: Volle Webseiten (X, Dia …) werden als PNG schnell über 1 MB groß (Base64 noch ein Drittel
# mehr). Ab dieser Größe als JPEG (Qualität 85) bei gleicher Pixelgröße – Koordinaten bleiben gleich (Server 1.35).
JPEG_OVER = 600_000
JPEG_QUALITY = 85


def compact_image(png: bytes) -> tuple[bytes, str]:
    """(Bilddaten, media_type): kleines PNG unverändert, großes als JPEG mit denselben Pixelmaßen (nur wenn kleiner)."""
    if len(png) <= JPEG_OVER:
        return png, "image/png"
    try:
        img = Image.open(io.BytesIO(png)).convert("RGB")
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    except Exception:  # noqa: BLE001 – im Zweifel das Original
        return png, "image/png"
    data = buf.getvalue()
    return (data, "image/jpeg") if len(data) < len(png) else (png, "image/png")

class ComputerError(RuntimeError):
    pass


@dataclass
class Screen:
    width: int  # logische Breite (Punkte), in diesem Raum rechnet Claude
    height: int


class HttpTransport:
    """Cua-Computer-Server per HTTP (`/cmd` liefert SSE-Zeilen `data: {…}`), z. B. die VM des Bot-Rechners."""

    def __init__(self, base_url: str, timeout: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self.http = httpx.Client(timeout=timeout)

    def send(self, command: str, params: dict) -> dict | None:
        r = self.http.post(f"{self.base_url}/cmd", json={"command": command, "params": params})
        r.raise_for_status()
        data = None
        for line in r.text.splitlines():
            if line.startswith("data: "):
                data = json.loads(line[6:])
        return data

    def alive(self) -> bool:
        try:
            self.http.get(f"{self.base_url}/status", timeout=2).raise_for_status()
            return True
        except Exception:  # noqa: BLE001
            return False


class Computer:
    """Befehle an einen Rechner. Der Transport ist austauschbar: HTTP (VM) oder WebSocket (Scoops Connect)."""

    def __init__(self, base_url: str | None = None, timeout: float = 60.0, transport=None):
        self.transport = transport or HttpTransport(base_url or "", timeout)
        self.base_url = getattr(self.transport, "base_url", "")
        self._screen: Screen | None = None

    @property
    def http(self) -> httpx.Client:  # Altlast: nur beim HTTP-Transport vorhanden
        return self.transport.http

    # -- Transport ---------------------------------------------------------
    def cmd(self, name: str, /, **params) -> dict:
        command = name
        data = self.transport.send(command, params)
        if data is None:
            raise ComputerError(f"Leere Antwort auf {command}")
        if not data.get("success", False):
            raise ComputerError(f"{command} fehlgeschlagen: {data.get('error')}")
        return data

    def wait_until_ready(self, timeout: float = 180.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.transport.alive():
                return
            time.sleep(3)  # VM bootet noch
        raise ComputerError("Computer-Server nicht erreichbar")

    # -- Bildschirm --------------------------------------------------------
    @property
    def screen(self) -> Screen:
        if self._screen is None:
            d = self.cmd("get_screen_size")
            size = d.get("size") or d
            self._screen = Screen(int(size["width"]), int(size["height"]))
        return self._screen

    def screenshot_png(self) -> bytes:
        """Screenshot, skaliert auf logische Größe (und höchstens MAX_LONG_EDGE)."""
        raw = base64.b64decode(self.cmd("screenshot")["image_data"])
        img = Image.open(io.BytesIO(raw))
        target_w, target_h = self.screen.width, self.screen.height
        if img.size != (target_w, target_h):
            img = img.resize((target_w, target_h), Image.LANCZOS)
        buf = io.BytesIO()
        img.convert("RGB").save(buf, format="PNG", optimize=True)
        return buf.getvalue()

    def zoom_png(self, region: list[int]) -> bytes:
        x0, y0, x1, y1 = region
        raw = base64.b64decode(self.cmd("screenshot")["image_data"])
        img = Image.open(io.BytesIO(raw))
        sx = img.width / self.screen.width
        sy = img.height / self.screen.height
        crop = img.crop((int(x0 * sx), int(y0 * sy), int(x1 * sx), int(y1 * sy)))
        crop.thumbnail((self.screen.width, self.screen.height), Image.LANCZOS)
        buf = io.BytesIO()
        crop.convert("RGB").save(buf, format="PNG", optimize=True)
        return buf.getvalue()

    # -- Eingaben ----------------------------------------------------------
    def _with_modifiers(self, modifiers: str | None, action) -> None:
        mods = [to_pyautogui_key(m) for m in modifiers.split("+")] if modifiers else []
        for m in mods:
            self.cmd("key_down", key=m)
        try:
            action()
        finally:
            for m in reversed(mods):
                self.cmd("key_up", key=m)

    def click(self, kind: str, coordinate: list[int] | None, modifiers: str | None) -> None:
        xy = {"x": int(coordinate[0]), "y": int(coordinate[1])} if coordinate else {}

        def act():
            if kind == "left_click":
                self.cmd("left_click", **xy)
            elif kind == "right_click":
                self.cmd("right_click", **xy)
            elif kind == "double_click":
                self.cmd("double_click", **xy)
            elif kind == "triple_click":
                self.cmd("double_click", **xy)
                self.cmd("left_click", **xy)
            elif kind == "middle_click":
                self.cmd("mouse_down", button="middle", **xy)
                self.cmd("mouse_up", button="middle", **xy)

        self._with_modifiers(modifiers, act)

    def move(self, x: int, y: int) -> None:
        self.cmd("move_cursor", x=int(x), y=int(y))

    def drag(self, start: list[int], end: list[int], modifiers: str | None) -> None:
        self._with_modifiers(
            modifiers,
            lambda: self.cmd("drag", path=[[int(start[0]), int(start[1])], [int(end[0]), int(end[1])]]),
        )

    def mouse_down(self) -> None:
        self.cmd("mouse_down", button="left")

    def mouse_up(self) -> None:
        self.cmd("mouse_up", button="left")

    def cursor_position(self) -> tuple[int, int]:
        d = self.cmd("get_cursor_position")
        pos = d.get("position") or d
        return int(pos["x"]), int(pos["y"])

    def scroll(self, direction: str, amount: int, coordinate: list[int] | None, modifiers: str | None) -> None:
        if coordinate:
            self.move(*coordinate)
        amount = max(1, int(amount or 3))
        dx, dy = {"up": (0, amount), "down": (0, -amount), "left": (-amount, 0), "right": (amount, 0)}[direction]
        self._with_modifiers(modifiers, lambda: self.cmd("scroll", x=dx, y=dy))

    def type_text(self, text: str) -> None:
        self.cmd("type_text", text=text)

    def key(self, combo: str, repeat: int = 1) -> None:
        keys = [to_pyautogui_key(k) for k in combo.split("+")]
        for _ in range(max(1, int(repeat or 1))):
            if len(keys) == 1:
                self.cmd("press_key", key=keys[0])
            else:
                self.cmd("hotkey", keys=keys)

    def hold_key(self, combo: str, duration: float) -> None:
        keys = [to_pyautogui_key(k) for k in combo.split("+")]
        for k in keys:
            self.cmd("key_down", key=k)
        time.sleep(min(float(duration), 30))
        for k in reversed(keys):
            self.cmd("key_up", key=k)

    def shell(self, command: str) -> dict:
        return self.cmd("run_command", command=command)
