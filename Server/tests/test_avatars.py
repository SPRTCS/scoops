"""Test für eigene Scoop-Bilder: PUT/GET/DELETE /api/bots/{id}/avatar, Zuschnitt, Cache-Header, Bot-JSON.

Startet eine eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, ohne MCP/VM-Wächter) –
niemals die laufende Produktion auf 8787.

    cd Server && uv run python tests/test_avatars.py
"""

from __future__ import annotations

import io
import json
import os
import socket
import sqlite3
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-avatar-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from PIL import Image  # noqa: E402

from aisbot import server  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "crown"}


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def image(w: int, h: int, fmt: str = "JPEG", mode: str = "RGB") -> bytes:
    """Testbild: linke Hälfte rot, rechte Hälfte blau (für die Prüfung des mittigen Zuschnitts)."""
    img = Image.new(mode, (w, h), (220, 40, 40, 255) if mode == "RGBA" else (220, 40, 40))
    img.paste((40, 60, 220, 255) if mode == "RGBA" else (40, 60, 220), (w // 2, 0, w, h))
    if mode == "RGBA":
        img.paste((0, 0, 0, 0), (0, 0, w // 8, h // 8))  # transparente Ecke
    buf = io.BytesIO()
    img.save(buf, fmt)
    return buf.getvalue()


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning")
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    end = time.time() + 15
    while not srv.started and time.time() < end:
        time.sleep(0.05)
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")

    con = sqlite3.connect(server.db.path)
    con.execute("INSERT INTO bots(id,name,mascot,model,created_at,last_activity) VALUES('b_pic','Foto',?,"
                "'claude-haiku-5-5',datetime('now'),datetime('now'))", (json.dumps(MASCOT),))
    con.commit()

    print("Ohne Bild")
    b = http.get("/api/bots/b_pic", headers=H).json()
    ok(b["avatar"] is None and "photo" not in b["mascot"], "neuer Scoop: avatar = null, kein mascot.photo")
    ok(http.get("/api/bots/b_pic/avatar", headers=H).status_code == 404, "GET ohne Bild → 404")

    print("Schutz")
    ok(http.put("/api/bots/b_pic/avatar", content=image(10, 10)).status_code == 401, "PUT ohne Token → 401")
    ok(http.put("/api/bots/b_nix/avatar", content=image(10, 10), headers=H).status_code == 404, "unbekannter Scoop → 404")
    ok(http.put("/api/bots/b_pic/avatar", content=b"kein bild", headers=H).status_code == 400, "kaputte Daten → 400")
    ok(http.put("/api/bots/b_pic/avatar", content=b"", headers=H).status_code == 400, "leerer Body → 400")

    print("Hochladen (Querformat-Foto)")
    r = http.put("/api/bots/b_pic/avatar", content=image(1600, 900), headers=H | {"Content-Type": "image/jpeg"})
    ok(r.status_code == 200, "PUT → 200")
    b = r.json()
    v = b["avatar"]["version"]
    ok(isinstance(v, int) and v > 0, f"avatar.version gesetzt ({v})")
    ok(b["avatar"]["url"] == f"/api/bots/b_pic/avatar?v={v}", "avatar.url mit Version")
    ok(b["mascot"]["photo"] == {"id": "b_pic", "version": v}, "mascot.photo = {id, version}")
    ok(b["mascot"]["accessory"] == "crown", "Maskottchen-Felder bleiben erhalten")
    ok(http.get("/api/bots", headers=H).json()[0]["avatar"]["version"] == v, "GET /api/bots enthält avatar")

    g = http.get(f"/api/bots/b_pic/avatar?v={v}", headers=H)
    ok(g.status_code == 200 and g.headers["content-type"] == "image/jpeg", "GET → JPEG")
    ok("immutable" in g.headers["cache-control"], "mit passender Version: immutable")
    img = Image.open(io.BytesIO(g.content))
    ok(img.size == (512, 512), "quadratisch auf 512 px")
    left, right = img.getpixel((60, 256)), img.getpixel((450, 256))
    ok(left[0] > 150 and right[2] > 150, "mittig zugeschnitten (links rot, rechts blau)")
    ok("no-cache" in http.get("/api/bots/b_pic/avatar", headers=H).headers["cache-control"], "ohne Version: no-cache")
    etag = g.headers["etag"]
    ok(http.get(f"/api/bots/b_pic/avatar?v={v}", headers=H | {"If-None-Match": etag}).status_code == 304, "ETag → 304")
    ok(http.get(f"/api/bots/b_pic/avatar?v={v}&token={TOKEN}").status_code == 200, "Token als Query-Parameter")

    small = http.get(f"/api/bots/b_pic/avatar?v={v}&size=128", headers=H)
    ok(Image.open(io.BytesIO(small.content)).size == (128, 128), "?size=128 → 128 px")
    ok(small.headers["etag"] != etag, "eigene ETag pro Größe")

    print("Maskottchen bearbeiten ändert das Bild nicht")
    p = http.patch("/api/bots/b_pic", json={"mascot": MASCOT | {"color": "#FF0000", "photo": {"id": "x", "version": 1}}},
                   headers=H).json()
    ok(p["mascot"]["color"] == "#FF0000" and p["mascot"]["photo"]["version"] == v, "PATCH mascot: Farbe neu, Bild bleibt")
    raw = sqlite3.connect(server.db.path).execute("SELECT mascot FROM bots WHERE id='b_pic'").fetchone()[0]
    ok("photo" not in json.loads(raw), "photo wird nie gespeichert")

    print("Neues Bild (PNG mit Transparenz, klein)")
    time.sleep(0.01)
    b2 = http.put("/api/bots/b_pic/avatar", content=image(300, 200, "PNG", "RGBA"), headers=H).json()
    v2 = b2["avatar"]["version"]
    ok(v2 > v, "neue Version")
    g2 = http.get(f"/api/bots/b_pic/avatar?v={v2}", headers=H)
    im2 = Image.open(io.BytesIO(g2.content))
    ok(g2.headers["content-type"] == "image/png" and im2.mode == "RGBA", "Transparenz → PNG")
    ok(im2.size == (200, 200), "kleine Bilder werden nicht hochskaliert")
    ok("no-cache" in http.get(f"/api/bots/b_pic/avatar?v={v}", headers=H).headers["cache-control"],
       "alte Version: nicht mehr immutable")
    files = sorted(p.name for p in (TMP / "data" / "avatars").iterdir())
    ok(files == ["b_pic.png"], f"altes JPEG entfernt ({files})")

    print("Zurück zum Maskottchen")
    d = http.delete("/api/bots/b_pic/avatar", headers=H)
    ok(d.status_code == 200 and d.json()["avatar"] is None and "photo" not in d.json()["mascot"], "DELETE → avatar = null")
    ok(http.get("/api/bots/b_pic/avatar", headers=H).status_code == 404, "danach 404")
    ok(not list((TMP / "data" / "avatars").iterdir()), "Datei gelöscht")

    print("Scoop löschen räumt das Bild weg")
    http.put("/api/bots/b_pic/avatar", content=image(64, 64), headers=H)
    ok((TMP / "data" / "avatars" / "b_pic.jpg").exists(), "Bild vorhanden")
    ok(http.delete("/api/bots/b_pic", headers=H).status_code == 200, "DELETE /api/bots/b_pic")
    ok(not (TMP / "data" / "avatars" / "b_pic.jpg").exists(), "Bild mit gelöscht")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil
        shutil.rmtree(TMP, ignore_errors=True)
