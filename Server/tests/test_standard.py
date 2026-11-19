"""Test der Edition „standard“ (Mac-App „AIS Scoops Server“): frische Installation ohne Armans Zusatzfunktionen.

Eigene Testinstanz im Prozess: Datenordner im Temp-Verzeichnis (AISBOT_HOME), eigener Port, eigener
Schlüsselbund-Präfix (liest nie Armans Schlüssel), ohne MCP/VM-Wächter. Niemals die Produktion auf 8787.

    cd Server && uv run python tests/test_standard.py
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-standard-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT),
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-test-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import profile, server  # noqa: E402
from aisbot.prompts import bot_system  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
PERSONAL_WORDS = ("Arman", "Lucy", "web.whatsapp", "Team App", "teamapp", "Atrium", "T3 Code", "MLP", "Tasks“",
                  "hello.ais", "virtuelle Maschine")


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def main() -> None:
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning")
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    for _ in range(100):
        try:
            http.get("/api/setup")
            break
        except httpx.HTTPError:
            time.sleep(0.1)

    print("Profil")
    ok(profile.edition() == "standard", "Edition standard")
    ok(profile.HOME == TMP and str(profile.CONFIG_PATH).startswith(str(TMP)), "Datenordner aus AISBOT_HOME")
    ok(not profile.active_features(), "keine persönlichen Zusatzfunktionen aktiv")
    ok(profile.kc("anthropic").startswith("ais-scoops-test-"), "eigener Schlüsselbund-Präfix")

    print("Frische Installation")
    bots = server.db.bots()
    ok(len(bots) == 1 and bots[0]["name"] == "Pip", "genau ein Start-Scoop (Pip)")
    ok(server.db.primary_bot()["id"] == bots[0]["id"], "Start-Scoop ist Haupt-Scoop")
    msgs = server.db.q("SELECT role, text FROM messages WHERE bot_id=?", (bots[0]["id"],))
    ok(len(msgs) == 1 and msgs[0]["role"] == "bot" and "Pip" in msgs[0]["text"], "Begrüßung ohne KI-Aufruf")
    server.seed_fresh_install()
    ok(len(server.db.bots()) == 1, "Start-Scoop wird nur einmal angelegt")
    ok(not server.initiative_settings()["enabled"], "Initiative standardmäßig aus")

    print("Einrichtungs-Endpunkte (nur lokal)")
    st = http.get("/api/setup").json()
    ok(st["linked"] is False and st["server"]["edition"] == "standard", "GET /api/setup: nicht gekoppelt, standard")
    ok(st["server"]["keys"] == {"anthropic": False, "openai": False, "composio": False}, "keine Schlüssel")
    ok(st["server"]["port"] == PORT, "Port gemeldet")
    ok(http.get("/api/setup", headers={"X-Forwarded-For": "1.2.3.4"}).status_code == 403, "über Proxy abgelehnt")
    ok(st["server"]["own_scoops"] == {"count": 0, "newest": None}, "Start-Scoop zählt nicht als eigener Scoop")
    own_id = server.db.create_bot(model="claude-haiku-5-5", name="Kiwi", label="", mascot={}, character="")
    own = http.get("/api/setup").json()["server"]["own_scoops"]
    ok(own == {"count": 1, "newest": "Kiwi"}, "erster eigener Scoop wird gemeldet (Glückwunsch im Assistenten)")
    server.db.delete_bot(own_id)
    r = http.patch("/api/setup/config", json={"user_name": "Lena", "public_url": "https://lena.example.ts.net/"})
    ok(r.status_code == 200 and r.json()["server"]["user_name"] == "Lena", "Name gesetzt")
    ok(r.json()["server"]["public_url"] == "https://lena.example.ts.net", "public_url ohne Schrägstrich")
    ok(http.patch("/api/setup/config", json={"public_url": "ftp://x"}).status_code == 400, "ungültige URL abgelehnt")
    ok(server.service.user_name == "Lena", "Scoops sprechen den Nutzer mit Namen an")
    pair = http.post("/api/setup/node-pair").json()
    ok(len(pair["code"]) == 9 and pair["code"][4] == "-", "Kopplungscode für „Dieser Mac“")
    claim = http.post("/api/nodes/claim", json={"code": pair["code"], "name": "Dieser Mac", "mode": "direct",
                                                "os": "macOS 27.0", "app_version": "test"})
    ok(claim.status_code == 200 and claim.json()["node_id"].startswith("n_"), "Code einlösbar")
    nid = claim.json()["node_id"]
    http.patch("/api/setup/config", json={"default_computer_node": nid})
    tok = json.loads((TMP / "config.json").read_text())["api_token"]
    nodes = http.get("/api/nodes", headers={"Authorization": f"Bearer {tok}"}).json()
    ok([n["id"] for n in nodes] == [nid], "Rechnerliste ohne VM-Bot-Rechner")
    ok(server.computers.for_bot({"computer_node": None}).node_id == nid, "Scoops ohne Zuordnung → Standard-Rechner")
    ids = [b["id"] for b in server._builtin_status()]
    ok(not ids, f"keine persönlichen Apps in „Apps verbinden“ {ids}")

    r = http.patch("/api/setup/config", json={"provider": "openai"})
    ok(server.db.bot_row(bots[0]["id"])["model"] == "gpt-6-luna", "nur OpenAI-Schlüssel → Scoops nutzen GPT")
    http.patch("/api/setup/config", json={"provider": "anthropic"})
    ok(server.db.bot_row(bots[0]["id"])["model"] == "claude-haiku-5-5", "zurück zu Claude")
    ok(server.db.bot_row(bots[0]["id"])["computer_node"] == nid, "Start-Scoop arbeitet an „Dieser Mac“")
    ok(http.patch("/api/setup/config", json={"host": "1.2.3.4"}).status_code == 400, "fremder Host abgelehnt")

    print("Prompt und Werkzeuge")
    bot = dict(server.service.bot_json(bots[0]["id"]))
    text = "\n".join(b["text"] for b in bot_system(bot, [], [], server.service.user_name, 1512, 982,
                                                   features=profile.active_features()))
    hits = [w for w in PERSONAL_WORDS if w in text]
    ok(not hits, f"Systemanweisung ohne persönliche Hinweise {hits}")
    ok("Lena" in text, "Systemanweisung nennt den Nutzer")
    from aisbot.bots import RunState
    tools = server.service._tools(bots[0]["id"], bots[0]["id"], 0, RunState())
    names = {t.schema["name"] for t in tools}
    ok(not names & {"anrufen", "anrufe_lesen", "t3_auftrag", "t3_projekte"}, "keine Lucy-/T3-Werkzeuge")
    descs = " ".join(t.schema["description"] for t in tools)
    ok("Arman" not in descs and "Lena" in descs, "Werkzeugbeschreibungen mit Nutzername")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
