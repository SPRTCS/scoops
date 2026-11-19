"""Test für Antworten auf Nachrichten (Server 1.15, docs/API.md „v1.15 – Antworten auf Nachrichten“):
`reply_to` beim Senden, Speicherung in meta.reply_to, fremde IDs werden ignoriert, Kontext für das Modell,
Gruppen-Routing an den Scoop, auf dessen Nachricht geantwortet wird.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine ohne KI-Aufruf) – niemals die Produktion.

    cd Server && uv run python tests/test_replies.py
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
from types import SimpleNamespace

TMP = Path(tempfile.mkdtemp(prefix="aisbot-reply-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import server  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service = server.db, server.service
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=10.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


class FakeEngine:
    calls: list[dict] = []

    @classmethod
    def run(cls, **kw):
        cls.calls.append({"actor": kw.get("bot_id"), "messages": kw["messages"]})
        u = SimpleNamespace(dollars=0.0, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        return Outcome("Antwort vom Scoop", "end_turn", SimpleNamespace(by_model={kw["model"]: u}, dollars=0.0), [], False,
                       kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def settle() -> None:
    time.sleep(0.1)
    wait_for(lambda: not service.runs, 10, "Läufe beendet")


def post(path: str, **body) -> dict:
    r = http.post(path, headers=H, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def history_text(call: dict) -> str:
    return json.dumps(call["messages"], ensure_ascii=False)


def main() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")

    mila = post("/api/bots", name="Mila", mascot=MASCOT)["id"]
    lio = post("/api/bots", name="Lio", mascot=MASCOT)["id"]
    settle()

    print("Einzelchat")
    bot_msg = service._add(mila, "bot", "**Morgen** um 9 Uhr ist das Teammeeting im großen Raum. " + "x" * 400)
    n = len(FakeEngine.calls)
    m = post(f"/api/bots/{mila}/messages", text="Kannst du das verschieben?", reply_to=bot_msg["id"])
    ref = m["meta"].get("reply_to")
    ok(ref and ref["id"] == bot_msg["id"] and ref["role"] == "bot" and ref["author_name"] == "Mila"
       and ref["author_id"] == mila, "reply_to mit ID, Rolle, Name und Autor gespeichert")
    ok(ref["text"].startswith("Morgen um 9 Uhr") and "**" not in ref["text"] and len(ref["text"]) <= 200
       and ref["text"].endswith("…"), "Auszug ohne Markdown, höchstens 200 Zeichen")
    settle()
    call = FakeEngine.calls[-1]
    ok(len(FakeEngine.calls) > n and "[Antwort auf deine Nachricht: „Morgen um 9 Uhr" in history_text(call),
       "Modell bekommt den Bezug (eigene Nachricht)")
    got = [x for x in http.get(f"/api/bots/{mila}/messages", headers=H).json() if x["id"] == m["id"]][0]
    ok(got["meta"]["reply_to"]["id"] == bot_msg["id"], "Verlauf liefert meta.reply_to")

    own = post(f"/api/bots/{mila}/messages", text="Erste Idee: Kino")
    settle()
    m2 = post(f"/api/bots/{mila}/messages", text="Vergiss das", reply_to=own["id"])
    ok(m2["meta"]["reply_to"]["role"] == "user" and m2["meta"]["reply_to"]["author_name"] == "Arman"
       and m2["meta"]["reply_to"]["text"] == "Erste Idee: Kino", "Antwort auf eigene Nachricht: Name Arman")
    settle()
    ok("[Antwort auf Nachricht von Arman: „Erste Idee: Kino“]" in history_text(FakeEngine.calls[-1]),
       "Modell-Kontext nennt den Absender")

    foreign = service._add(lio, "bot", "Geheimnis aus Lios Chat")
    for bad, label in ((foreign["id"], "aus anderem Chat"), ("m_gibtsnicht", "unbekannt"), (123, "keine Zeichenkette")):
        r = post(f"/api/bots/{mila}/messages", text="Hm", reply_to=bad)
        ok("reply_to" not in (r["meta"] or {}), f"reply_to {label} → ignoriert")
    settle()
    ok("Geheimnis" not in history_text(FakeEngine.calls[-1]), "fremder Chat landet nicht im Modell-Kontext")
    ev = service._add(mila, "event", "Routine angelegt")
    r = post(f"/api/bots/{mila}/messages", text="Ok", reply_to=ev["id"])
    ok("reply_to" not in (r["meta"] or {}), "Ereigniszeilen sind nicht zitierbar")
    settle()

    print("Gruppe")
    g = post("/api/groups", name="Team", member_ids=[mila, lio])["id"]
    lio_msg = service._add(g, "bot", "Ich kümmere mich um die Folien.", {"author_id": lio})
    n = len(FakeEngine.calls)
    gm = post(f"/api/groups/{g}/messages", text="Super, bis wann?", reply_to=lio_msg["id"])
    ok(gm["meta"]["reply_to"]["author_name"] == "Lio" and gm["meta"]["reply_to"]["author_id"] == lio,
       "Gruppe: reply_to mit Autor-Scoop")
    settle()
    new_calls = FakeEngine.calls[n:]
    ok(len(new_calls) == 1, "Antwort auf Scoop-Nachricht ohne @: genau ein Lauf (kein Routing-Modell)")
    ok("[Antwort auf deine Nachricht: „Ich kümmere mich um die Folien.“]" in history_text(new_calls[0]),
       "der zitierte Scoop antwortet und sieht den Bezug")
    replies = [x for x in db.messages(g, limit=5) if x["role"] == "bot" and x["text"] == "Antwort vom Scoop"]
    ok(replies and replies[-1]["meta"].get("author_id") == lio, "Lio antwortet")
    other = post(f"/api/groups/{g}/messages", text="Und du @Mila?", reply_to=lio_msg["id"])
    settle()
    replies = [x for x in db.messages(g, limit=5) if x["role"] == "bot" and x["text"] == "Antwort vom Scoop"]
    ok(other["meta"]["reply_to"]["id"] == lio_msg["id"] and replies[-1]["meta"].get("author_id") == mila,
       "@Erwähnung hat Vorrang vor dem Zitat")
    r = post(f"/api/groups/{g}/messages", text="@Mila Test", reply_to=bot_msg["id"])
    ok("reply_to" not in (r["meta"] or {}), "Gruppe: ID aus Einzelchat → ignoriert")
    settle()

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil

        shutil.rmtree(TMP, ignore_errors=True)
