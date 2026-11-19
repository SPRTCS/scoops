"""Regressionstest (Server 1.35): Bildschirmbilder über den Claude-Abo-Weg.

Fehler auf 1.34.0: `bildschirm_aufgabe` brach mit „JSON message exceeded maximum buffer size of 1048576 bytes“ ab, weil
der Claude Agent SDK die Zeilen von Claude Code nur bis 1 MB liest und ein Screenshot einer vollen Webseite (PNG, Base64)
größer war. Der Scoop sprach dann von einer „abgebrochenen Bildschirmverbindung“.

Prüft: SDK-Transport mit einer > 1 MB großen Zeile (Fake-Claude-Code) mit und ohne unsere Puffergröße, alle
`ClaudeAgentOptions(` im Server setzen `max_buffer_size`, große Screenshots werden JPEG mit gleichen Pixelmaßen (kleine
bleiben PNG), Engine-Werkzeug liefert den passenden media_type, MCP-Inhalt für Abo/Aufgaben übernimmt ihn, ehrliche
Fehlermeldung in der Abo-Engine.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_screen_buffer.py
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-screen-test-"))
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_OFFLINE="1", AISBOT_EDITION="standard",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-screentest-" + os.urandom(3).hex(),
                  CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK="1")
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from PIL import Image  # noqa: E402

from aisbot import abos, engine_abo  # noqa: E402
from aisbot.computer import JPEG_OVER, compact_image  # noqa: E402
from aisbot.engine import Engine  # noqa: E402
from aisbot.tasks import _mcp_content  # noqa: E402

passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def noisy_png(w: int = 1512, h: int = 982) -> bytes:
    """Bild wie eine volle Webseite mit viel Text/Fotos: Rauschen komprimiert als PNG schlecht (> 1 MB)."""
    img = Image.frombytes("RGB", (w, h), os.urandom(w * h * 3))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def test_compact() -> None:
    print("Große Screenshots als JPEG, gleiche Pixelmaße")
    big = noisy_png()
    ok(len(base64.b64encode(big)) > 1024 * 1024, f"Test-PNG ist groß ({len(big) // 1024} KB, Base64 > 1 MB)")
    data, mt = compact_image(big)
    ok(mt == "image/jpeg" and len(data) < len(big), f"großes PNG → JPEG ({len(data) // 1024} KB)")
    ok(Image.open(io.BytesIO(data)).size == (1512, 982), "Pixelmaße unverändert (Koordinaten stimmen)")
    small = Image.new("RGB", (1512, 982), (250, 250, 250))
    buf = io.BytesIO()
    small.save(buf, format="PNG")
    d2, mt2 = compact_image(buf.getvalue())
    ok(mt2 == "image/png" and d2 == buf.getvalue() and len(d2) <= JPEG_OVER, "kleines PNG bleibt PNG")

    class FakeComputer:
        def screenshot_png(self):
            return big

        def zoom_png(self, region):
            return big

    for action in ("screenshot", "zoom"):
        out = Engine._exec_computer(FakeComputer(), action, {"region": [0, 0, 10, 10]})
        ok(out[0]["source"]["media_type"] == "image/jpeg", f"Werkzeug {action}: media_type image/jpeg")
    mcp = _mcp_content(out)
    ok(mcp[0]["mimeType"] == "image/jpeg", "MCP-Inhalt (Abo-Weg, Aufgaben) übernimmt den media_type")
    ok(len(data) * 3 < len(big), "JPEG mindestens dreimal kleiner (Extremfall Rauschen; den Rest deckt der 64-MB-Puffer)")


def test_options_everywhere() -> None:
    print("Alle ClaudeAgentOptions setzen max_buffer_size")
    n = 0
    for f in sorted((SRC / "aisbot").glob("*.py")):
        text = f.read_text()
        for m in re.finditer(r"ClaudeAgentOptions\(", text):
            depth, i = 0, m.end() - 1
            while True:  # bis zur passenden schließenden Klammer
                c = text[i]
                depth += c == "("
                depth -= c == ")"
                i += 1
                if depth == 0:
                    break
            n += 1
            ok("max_buffer_size" in text[m.start():i], f"{f.name}: ClaudeAgentOptions mit max_buffer_size")
    ok(n >= 4, f"{n} Stellen geprüft")
    ok(abos.SDK_MAX_BUFFER >= 32 * 1024 * 1024, "Puffergröße großzügig (≥ 32 MB)")


def fake_cli(size: int) -> Path:
    """Fake-Claude-Code: schreibt eine Werkzeug-Ergebnis-Zeile mit großem Bild auf stdout und endet."""
    script = TMP / "fake-claude"
    line = json.dumps({"type": "user", "message": {"role": "user", "content": [{
        "type": "tool_result", "tool_use_id": "t1", "content": [{"type": "image", "source": {
            "type": "base64", "media_type": "image/png", "data": "A" * size}}]}]}})
    (TMP / "line.json").write_text(line + "\n")
    script.write_text(f"#!/bin/sh\ncat '{TMP / 'line.json'}'\nsleep 0.2\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


async def read_all(max_buffer: int | None) -> list[dict]:
    from claude_agent_sdk import ClaudeAgentOptions
    from claude_agent_sdk._internal.transport.subprocess_cli import SubprocessCLITransport
    opts = ClaudeAgentOptions(cli_path=str(fake_cli(1_600_000)), max_buffer_size=max_buffer, stderr=lambda s: None)
    tr = SubprocessCLITransport(prompt="x", options=opts)
    await tr.connect()
    out = []
    try:
        async for msg in tr.read_messages():
            out.append(msg)
    finally:
        await tr.close()
    return out


def test_transport() -> None:
    print("SDK-Transport mit einer Zeile > 1 MB (Fake-Claude-Code)")
    try:
        asyncio.run(read_all(None))
        ok(False, "ohne max_buffer_size müsste der alte Fehler kommen")
    except Exception as e:  # noqa: BLE001
        ok("maximum buffer size" in str(e), "ohne Einstellung: alter Fehler reproduziert (1 MB)")
        text = abos.explain_sdk_error(e)
        ok("zu groß" in text and "keine abgebrochene Bildschirmverbindung" in text, "ehrlicher Fehlertext")
    msgs = asyncio.run(read_all(abos.SDK_MAX_BUFFER))
    ok(len(msgs) == 1 and msgs[0]["type"] == "user", "mit SDK_MAX_BUFFER: Zeile wird gelesen")


def test_engine_error() -> None:
    print("Abo-Engine meldet den Fehler ehrlich")
    eng = engine_abo.ClaudeCodeEngine(type("Api", (), {"hub": None})())
    old_status, old_run = abos.login_status, engine_abo.LOOP.run
    abos.login_status = lambda p: {"subscription": True}

    def boom(coro, timeout=None):
        coro.close()
        raise RuntimeError("Failed to decode JSON: JSON message exceeded maximum buffer size of 1048576 bytes...")
    engine_abo.LOOP.run = boom
    try:
        eng.run(system="s", messages=[{"role": "user", "content": "x"}], model="claude-sonnet-5-5", extra_tools=[],
                allow_computer=False, allow_web=False)
        ok(False, "Fehler erwartet")
    except RuntimeError as e:
        ok("Interner Fehler" in str(e) and "keine abgebrochene Bildschirmverbindung" in str(e),
           "RuntimeError mit klarem Text statt SDK-Meldung")
    finally:
        abos.login_status, engine_abo.LOOP.run = old_status, old_run


def test_all() -> None:
    test_compact()
    test_options_everywhere()
    test_transport()
    test_engine_error()


if __name__ == "__main__":
    test_all()
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    os._exit(0)
