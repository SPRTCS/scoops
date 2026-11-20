"""Test für „Eigene Nachricht bearbeiten“ (docs/API.md „Suche und Chat-Komfort“, `chat_edit.py`):
`PATCH /api/messages/{id}` – neu antworten, wenn die alte Fassung nichts ausgelöst hat (Antwort verwerfen, Verlauf
zurücksetzen: API-Engine, Abo-Sitzung, „mach weiter“, Tagebuch, Gruppen), sonst Korrektur als neuer Auftrag.
Dazu: laufenden Lauf anhalten, Grenzen (nur jüngste eigene Nachricht), Gäste geteilter Scoops, Ereignis `message.deleted`.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine ohne KI-Aufruf) – niemals die Produktion.

    cd Server && uv run python tests/test_chat_edit.py
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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-edit-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
GUEST_TOKEN = "gast-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import chat_edit, server  # noqa: E402
from aisbot.engine import Outcome, mcp_line  # noqa: E402
from aisbot.sharing import Principal, Share  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service = server.db, server.service
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
G = {"Authorization": f"Bearer {GUEST_TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=30)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}

_principal_of = server.principal_of
server.principal_of = lambda given: Principal("guest", "u_lea", "s_lea") if given == GUEST_TOKEN else _principal_of(given)

events: list[tuple[str, dict]] = []
_publish = service.publish


def publish(typ: str, data: dict) -> None:
    events.append((typ, data))
    _publish(typ, data)


service.publish = publish


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
    """Spielt einen Lauf nach Drehbuch: Arbeitsschritte (`lines`), Werkzeugaufrufe (`tools`), Antworttext (`text`),
    oder blockiert bis zum Anhalten (`block`). Ohne Drehbuch: einfache Antwort."""

    calls: list[dict] = []
    script: list[dict] = []
    started = threading.Event()

    @classmethod
    def run(cls, **kw):
        step = cls.script.pop(0) if cls.script else {}
        cls.calls.append({"messages": json.dumps(kw["messages"], ensure_ascii=False), "holder": kw.get("holder"),
                          "allow_computer": kw.get("allow_computer"), "session_id": kw.get("session_id")})
        u = SimpleNamespace(dollars=0.0, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        usage = SimpleNamespace(by_model={kw["model"]: u}, dollars=0.0)
        lines = []
        for line in step.get("lines", []):
            kw["on_line"](line)
            lines.append(line)
        for name, args in step.get("tools", []):
            next(t for t in kw["extra_tools"] if t.schema["name"] == name).handler(args)
        if step.get("mcp"):  # wie die Engines: erst der Arbeitsschritt, dann der Aufruf der verbundenen App
            srv, _, tool = step["mcp"].partition("__")
            kw["on_line"](mcp_line(srv, tool, {}))
            lines.append(mcp_line(srv, tool, {}))
            kw["mcp_hub"].call(step["mcp"], {})
        if step.get("block"):
            cls.started.set()
            kw["cancel"].wait(15)
            return Outcome("", "stopped", usage, lines, False, kw["model"], 1)
        return Outcome(step.get("text", f"Antwort {len(cls.calls)}"), "end_turn", usage, lines, False, kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def settle() -> None:
    time.sleep(0.15)
    wait_for(lambda: not service.runs and not any(lock.locked() for lock in chat_edit._locks.values()), 20,
             "Läufe und Bearbeiten beendet")


def post(path: str, headers=H, **body) -> dict:
    r = http.post(path, headers=headers, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def edit(mid: str, text, headers=H) -> httpx.Response:
    return http.patch(f"/api/messages/{mid}", headers=headers, json={"text": text})


def chat(chat_id: str) -> list[dict]:
    return db.messages(chat_id, limit=200)


def texts(chat_id: str, role: str | None = None) -> list[str]:
    return [m["text"] for m in chat(chat_id) if role is None or m["role"] == role]


def main() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}")

    mila = post("/api/bots", name="Mila", mascot=MASCOT)["id"]
    lio = post("/api/bots", name="Lio", mascot=MASCOT)["id"]
    settle()

    print("Neu antworten: reine Textantwort")
    m = post(f"/api/bots/{mila}/messages", text="Was ist die Hauptstadt von Frankreisch?")
    settle()
    old_reply = chat(mila)[-1]
    ok(old_reply["role"] == "bot" and old_reply["meta"]["run_info"]["effects"] is False, "Antwort trägt run_info.effects = false")
    service.resumes.save(mila, mila, {"engine": "claude", "model": "x", "transcript": [{"role": "user", "content": "alt"}]})
    db.set_abo_session(mila, mila, "claude", "sess_alt", old_reply and db.max_seq(mila), "claude-haiku-5-5")
    service.set_reaction(m["id"], mila, "👍")
    service.set_reaction(m["id"], "user", "❤️")
    n_calls, n_events = len(FakeEngine.calls), len(events)
    r = edit(m["id"], "Was ist die Hauptstadt von Frankreich?")
    ok(r.status_code == 200 and r.json()["text"] == "Was ist die Hauptstadt von Frankreich?" and r.json()["id"] == m["id"],
       "PATCH liefert die Nachricht mit neuem Text (gleiche ID)")
    settle()
    msgs = chat(mila)
    e = next(x for x in msgs if x["id"] == m["id"])
    ok(e["meta"]["edited"]["mode"] == "replaced" and e["meta"]["edited"]["at"], "meta.edited: at und mode = replaced")
    ok(old_reply["id"] not in [x["id"] for x in msgs], "alte Antwort ist aus dem Verlauf verschwunden")
    ok(msgs[-1]["role"] == "bot" and msgs[-1]["id"] != old_reply["id"] and msgs[-2]["id"] == m["id"],
       "neue Antwort steht direkt nach der bearbeiteten Nachricht")
    call = FakeEngine.calls[-1]
    ok(len(FakeEngine.calls) == n_calls + 1 and "Frankreich?" in call["messages"] and "Frankreisch" not in call["messages"]
       and old_reply["text"] not in call["messages"], "Scoop sieht nur die neue Fassung, nicht die alte Frage oder Antwort")
    new_events = events[n_events:]
    ok(("message.deleted", {"id": old_reply["id"], "bot_id": mila}) in new_events, "WebSocket: message.deleted für die alte Antwort")
    ok(any(t == "message.updated" and d["id"] == m["id"] and d["meta"].get("edited", {}).get("mode") == "replaced" for t, d in new_events),
       "WebSocket: message.updated mit der neuen Fassung")
    ok(service.resumes.load(mila, mila) is None, "gespeicherter Stand für „mach weiter“ verworfen")
    ok(db.abo_session(mila, mila, "claude") is None, "Abo-Sitzung verworfen (nächster Lauf beginnt mit dem sichtbaren Verlauf)")
    ok(e["meta"].get("reactions") == {"user": "❤️"}, "Reaktion des Scoops auf die alte Fassung entfernt, eigene bleibt")
    ok(e["created_at"] == m["created_at"], "Zeitpunkt der Nachricht bleibt")
    hits = http.get("/api/search", headers=H, params={"q": "Frankreisch"}).json()["hits"]
    ok(not hits and http.get("/api/search", headers=H, params={"q": "Frankreich"}).json()["hits"], "Suche kennt nur die neue Fassung")
    ok(old_reply["text"] not in json.dumps(db.search(mila, old_reply["text"]), ensure_ascii=False)
       and "Frankreich?" in json.dumps(db.search(mila, "Hauptstadt Frankreich"), ensure_ascii=False),
       "Gedächtnis-Suche des Scoops (search_fts) folgt")

    print("Neu antworten: Lauf mit Arbeitsschritten, die nur lesen")
    FakeEngine.script = [{"lines": ["Sucht im Web: Wetter Berlinn"], "tools": [("erinnerung_suchen", {"suchbegriff": "Wetter"})],
                          "text": "In Berlinn ist es sonnig. Mehr weiß ich nicht."}]
    m = post(f"/api/bots/{mila}/messages", text="Wie ist das Wetter in Berlinn?")
    settle()
    status = next(x for x in chat(mila) if x["role"] == "status")
    ok(status["meta"]["effects"] is False and status["meta"]["lines"], "Statuszeile trägt effects = false (nur gelesen)")
    diary = [x["text"] for x in db.memories(mila) if x["kind"] == "tagebuch"]
    ok(diary == ["In Berlinn ist es sonnig"], "Tagebuch-Eintrag des Laufs vorhanden")
    FakeEngine.script = [{"text": "In Berlin regnet es."}]
    ok(edit(m["id"], "Wie ist das Wetter in Berlin?").status_code == 200, "Bearbeiten nach Lauf mit Websuche")
    settle()
    msgs = chat(mila)
    ok(status["id"] not in [x["id"] for x in msgs] and "In Berlinn ist es sonnig. Mehr weiß ich nicht." not in texts(mila),
       "Statuszeile und alte Antwort verworfen")
    ok(msgs[-1]["text"] == "In Berlin regnet es." and next(x for x in msgs if x["id"] == m["id"])["meta"]["edited"]["mode"] == "replaced",
       "neue Antwort auf die neue Fassung")
    ok(not [x for x in db.memories(mila) if x["kind"] == "tagebuch"], "Tagebuch-Eintrag der verworfenen Antwort entfernt")

    print("Korrektur: die alte Fassung hat etwas ausgelöst")
    FakeEngine.script = [{"lines": ["Merkt sich etwas"], "tools": [("merken", {"text": "Arman mag Tee"})],
                          "text": "Ich habe mir gemerkt, dass du Tee magst."}]
    m = post(f"/api/bots/{mila}/messages", text="Merk dir: Ich mag Tee")
    settle()
    status = [x for x in chat(mila) if x["role"] == "status"][-1]
    reply = chat(mila)[-1]
    ok(status["meta"]["effects"] is True and reply["meta"]["run_info"]["effects"] is True, "Werkzeug „merken“ → effects = true")
    db.set_abo_session(mila, mila, "claude", "sess_bleibt", db.max_seq(mila), "claude-haiku-5-5")
    n_calls, n_events = len(FakeEngine.calls), len(events)
    r = edit(m["id"], "Merk dir: Ich mag Kaffee")
    settle()
    msgs = chat(mila)
    e = next(x for x in msgs if x["id"] == m["id"])
    ok(r.status_code == 200 and e["text"] == "Merk dir: Ich mag Kaffee" and e["meta"]["edited"]["mode"] == "corrected",
       "Text ersetzt, meta.edited.mode = corrected")
    ok(reply["id"] in [x["id"] for x in msgs] and status["id"] in [x["id"] for x in msgs], "alte Antwort und Arbeitsschritte bleiben")
    ok(not [t for t, _ in events[n_events:] if t == "message.deleted"], "nichts gelöscht")
    ev = next(x for x in msgs if x["role"] == "event" and x["text"] == "Nachricht bearbeitet")
    ok(ev["meta"]["icon"] == "pencil" and ev["meta"]["edit_of"] == m["id"], "Ereignis „Nachricht bearbeitet“ im Chat")
    call = FakeEngine.calls[-1]
    ok(len(FakeEngine.calls) == n_calls + 1 and "Alte Fassung: „Merk dir: Ich mag Tee“" in call["messages"]
       and "Neue Fassung: „Merk dir: Ich mag Kaffee“" in call["messages"] and "nichts doppelt ausführen" in call["messages"],
       "Scoop bekommt die Korrektur mit alter und neuer Fassung als Auftrag")
    ok("Ich habe mir gemerkt, dass du Tee magst." in call["messages"], "die alte Antwort steht weiter im Verlauf des Scoops")
    ok(any(x["text"] == "Arman mag Tee" for x in db.memories(mila)), "Gedächtnis-Eintrag wird nicht stillschweigend gelöscht")
    ok(db.abo_session(mila, mila, "claude")["session_id"] == "sess_bleibt", "Abo-Sitzung bleibt (die Korrektur kommt als neue Nachricht)")
    ok(msgs[-1]["role"] == "bot" and msgs[-1]["id"] != reply["id"], "Scoop antwortet auf die korrigierte Fassung")
    db.drop_abo_session(mila)

    print("Korrektur: weitere Auslöser")
    FakeEngine.script = [{"mcp": "composio__COMPOSIO_MULTI_EXECUTE_TOOL", "text": "Erledigt."}]
    service.mcp_hub.call = lambda name, args: "ok"
    m = post(f"/api/bots/{mila}/messages", text="Schick die Mail")
    settle()
    ok([x for x in chat(mila) if x["role"] == "status"][-1]["meta"]["effects"] is True, "App-Werkzeug (MCP) → effects = true")
    edit(m["id"], "Schick die Mail an Jonas")
    settle()
    ok(next(x for x in chat(mila) if x["id"] == m["id"])["meta"]["edited"]["mode"] == "corrected", "nach App-Werkzeug: Korrektur")
    FakeEngine.script = [{"lines": ["Liest eine Webseite"], "mcp": "composio__COMPOSIO_SEARCH_TOOLS", "text": "Gefunden."}]
    m = post(f"/api/bots/{mila}/messages", text="Welche Werkzeuge gipts?")
    settle()
    ok([x for x in chat(mila) if x["role"] == "status"][-1]["meta"]["effects"] is False, "Werkzeuge nur suchen (Composio) → effects = false")
    edit(m["id"], "Welche Werkzeuge gibt es?")
    settle()
    ok(next(x for x in chat(mila) if x["id"] == m["id"])["meta"]["edited"]["mode"] == "replaced", "danach: neu antworten")

    FakeEngine.script = [{"lines": ["Klickt"], "text": "Geklickt."}]
    m = post(f"/api/bots/{mila}/messages", text="Klick auf Sendn")
    settle()
    ok([x for x in chat(mila) if x["role"] == "status"][-1]["meta"]["effects"] is True, "unbekannter Arbeitsschritt (Rechner) → effects = true")
    edit(m["id"], "Klick auf Senden")
    settle()
    ok(next(x for x in chat(mila) if x["id"] == m["id"])["meta"]["edited"]["mode"] == "corrected", "danach: Korrektur")

    m = post(f"/api/bots/{mila}/messages", text="Bestell Kaffe")
    settle()
    card = service._add(mila, "approval", "", {"approval_id": "a_x", "title": "Kaffee bestellen", "details": "", "state": "pending"})
    edit(m["id"], "Bestell Kaffee")
    settle()
    msgs = chat(mila)
    ok(next(x for x in msgs if x["id"] == m["id"])["meta"]["edited"]["mode"] == "corrected" and card["id"] in [x["id"] for x in msgs],
       "Freigabe-Karte nach der Nachricht → Korrektur, Karte bleibt")

    m = post(f"/api/bots/{mila}/messages", text="Leg eine Routine ahn")
    settle()
    service._add(mila, "event", "Routine angelegt: Briefing", {"icon": "clock"})
    edit(m["id"], "Leg eine Routine an")
    settle()
    ok(next(x for x in chat(mila) if x["id"] == m["id"])["meta"]["edited"]["mode"] == "corrected", "Ereignis (Routine) → Korrektur")

    m = post(f"/api/bots/{mila}/messages", text="Alte Antwort ohne Angabe")
    settle()
    last = chat(mila)[-1]
    info = dict(last["meta"]["run_info"])
    info.pop("effects")
    db.update_message(last["id"], meta={**last["meta"], "run_info": info})
    edit(m["id"], "Antwort eines älteren Servers")
    settle()
    ok(next(x for x in chat(mila) if x["id"] == m["id"])["meta"]["edited"]["mode"] == "corrected",
       "Lauf ohne effects-Angabe (älterer Server) → sicherheitshalber Korrektur")

    print("Laufenden Lauf anhalten")
    FakeEngine.started.clear()
    FakeEngine.script = [{"lines": ["Sucht im Web"], "block": True}]
    m = post(f"/api/bots/{mila}/messages", text="Lange Recherche zu Tehma A")
    wait_for(FakeEngine.started.is_set, 5, "Lauf gestartet")
    ok(mila in service.runs, "Lauf läuft")
    FakeEngine.script = [{"text": "Hier ist Thema A."}]
    t0 = time.time()
    r = edit(m["id"], "Lange Recherche zu Thema A")
    ok(r.status_code == 200 and time.time() - t0 < chat_edit.REPLY_WAIT + 2, "PATCH antwortet zügig, auch wenn ein Lauf läuft")
    settle()
    msgs = chat(mila)
    tail = msgs[[x["id"] for x in msgs].index(m["id"]):]
    ok([x["role"] for x in tail] == ["user", "bot"] and tail[1]["text"] == "Hier ist Thema A.",
       "Lauf angehalten, Arbeitsschritte und „Angehalten“ verworfen, neue Antwort da")
    ok(tail[0]["meta"]["edited"]["mode"] == "replaced", "mode = replaced")

    print("Grenzen")
    first = post(f"/api/bots/{mila}/messages", text="Erste Nachricht")
    settle()
    second = post(f"/api/bots/{mila}/messages", text="Zweite Nachricht")
    settle()
    r = edit(first["id"], "Erste, geändert")
    ok(r.status_code == 409 and "jüngste" in r.json()["error"], "ältere Nachricht → 409 (erneut senden)")
    ok(texts(mila, "user")[-2] == "Erste Nachricht", "ältere Nachricht bleibt unverändert")
    n = len(FakeEngine.calls)
    r = edit(second["id"], "Zweite Nachricht")
    settle()
    ok(r.status_code == 200 and "edited" not in r.json()["meta"] and len(FakeEngine.calls) == n, "gleicher Text → nichts passiert")
    ok(edit(second["id"], "   ").status_code == 400 and edit(second["id"], None).status_code == 400, "leerer Text → 400")
    ok(edit("m_gibtsnicht", "x").status_code == 404, "unbekannte Nachricht → 404")
    bot_msg = chat(mila)[-1]
    ok(edit(bot_msg["id"], "x").status_code == 404, "Nachricht des Scoops lässt sich nicht bearbeiten")
    ok(edit(second["id"], "/aufgabe Bericht schreiben").status_code == 409, "Text „/aufgabe …“ → 409")
    live = service._add(mila, "user", "Gesprochen", {"voice": True, "live": True})
    ok(edit(live["id"], "Getippt").status_code == 409, "Live-Sprechmodus → 409")
    db.q("DELETE FROM messages WHERE id=?", (live["id"],))
    voice = post(f"/api/bots/{mila}/messages", text="Diktiert mit Fehlr", voice=True)
    settle()
    edit(voice["id"], "Diktiert ohne Fehler")
    settle()
    ok("voice" not in next(x for x in chat(mila) if x["id"] == voice["id"])["meta"], "diktierte Nachricht: nach dem Bearbeiten nicht mehr „gesprochen“")
    ok(http.patch(f"/api/messages/{second['id']}", json={"text": "x"}).status_code == 401, "ohne Anmeldung → 401")
    f = db.add_file(mila, None, "notiz.txt", b"hallo", "text/plain")
    att = post(f"/api/bots/{mila}/messages", text="Sieh dir das ahn", file_ids=[f["id"]])
    settle()
    r = edit(att["id"], "Sieh dir das an")
    settle()
    ok(r.json()["meta"]["file_ids"] == [f["id"]] and f"({f['id']})" in FakeEngine.calls[-1]["messages"], "Anhänge bleiben erhalten")

    print("Gruppe")
    g = post("/api/groups", name="Team", member_ids=[mila, lio])["id"]
    gm = post(f"/api/groups/{g}/messages", text="@Mila und @Lio: Wer macht die Follien?")
    settle()
    replies = [x for x in chat(g) if x["role"] == "bot"]
    ok({x["meta"]["author_id"] for x in replies} == {mila, lio}, "beide Scoops haben geantwortet")
    for a in (mila, lio):
        db.set_abo_session(g, a, "claude", f"sess_{a}", db.max_seq(g), "m")
    n = len(FakeEngine.calls)
    edit(gm["id"], "@Lio: Wer macht die Folien?")
    settle()
    msgs = chat(g)
    after = msgs[[x["id"] for x in msgs].index(gm["id"]) + 1:]
    ok([x["meta"].get("author_id") for x in after if x["role"] == "bot"] == [lio] and len(FakeEngine.calls) == n + 1,
       "Gruppe: alte Antworten verworfen, nach der neuen Fassung antwortet nur Lio")
    ok(not db.abo_session(g, mila, "claude") and not db.abo_session(g, lio, "claude"), "Gruppe: Abo-Sitzungen aller Scoops verworfen")
    gm = post(f"/api/groups/{g}/messages", text="@Mila übergib das")
    settle()
    service._add(g, "event", "Mila → Lio: Folien bauen", {"author_id": mila})
    n = len(FakeEngine.calls)
    edit(gm["id"], "@Mila übergib das bitte")
    settle()
    ok(next(x for x in chat(g) if x["id"] == gm["id"])["meta"]["edited"]["mode"] == "corrected"
       and FakeEngine.calls[-1]["holder"] == mila and len(FakeEngine.calls) == n + 1,
       "Gruppe mit Übergabe → Korrektur; es antwortet, wer auf die alte Fassung geantwortet hat")

    print("Gäste geteilter Scoops")
    server.shares.shares = [Share("sh_1", lio, "u_lea", "Lea", "write", "none")]
    own = post(f"/api/bots/{lio}/messages", text="Nachricht des Admins")
    settle()
    gmsg = post(f"/api/bots/{lio}/messages", headers=G, text="Hallo von Lea mit Tippfeler")
    settle()
    ok(gmsg["meta"]["author_user_id"] == "u_lea" and FakeEngine.calls[-1]["allow_computer"] is False, "Gast-Nachricht, Gast-Lauf")
    ok(edit(own["id"], "gekapert", headers=G).status_code in (403, 409) and texts(lio, "user")[-2] == "Nachricht des Admins",
       "Gast kann die Nachricht des Admins nicht bearbeiten")
    ok(edit(gmsg["id"], "vom Admin geändert").status_code == 403, "Admin kann die Nachricht eines Gasts nicht bearbeiten")
    r = edit(gmsg["id"], "Hallo von Lea ohne Tippfehler", headers=G)
    settle()
    ok(r.status_code == 200 and r.json()["meta"]["edited"] and "run_info" not in json.dumps(r.json()), "Gast bearbeitet die eigene Nachricht")
    ok(FakeEngine.calls[-1]["allow_computer"] is False and "ohne Tippfehler" in FakeEngine.calls[-1]["messages"],
       "die neue Antwort ist wieder ein Gast-Lauf (eingeschränkte Werkzeuge)")
    FakeEngine.script = [{"lines": ["Merkt sich etwas"], "tools": [("merken", {"text": "Lea mag Tee"})], "text": "Gemerkt."}]
    gmsg = post(f"/api/bots/{lio}/messages", headers=G, text="Merk dir Tee")
    settle()
    edit(gmsg["id"], "Merk dir Kaffee", headers=G)
    settle()
    ok(next(x for x in chat(lio) if x["id"] == gmsg["id"])["meta"]["edited"]["mode"] == "corrected"
       and FakeEngine.calls[-1]["allow_computer"] is False, "Korrektur eines Gasts bleibt ein Gast-Lauf")
    mine = post(f"/api/bots/{lio}/messages", text="Admin schreibt, dann Lea")
    settle()
    post(f"/api/bots/{lio}/messages", headers=G, text="Lea dazwischen")
    settle()
    edit(mine["id"], "Admin schreibt, dann Lea (korrigiert)")
    settle()
    ok(next(x for x in chat(lio) if x["id"] == mine["id"])["meta"]["edited"]["mode"] == "corrected"
       and "Lea dazwischen" in texts(lio, "user"), "geteilter Chat: Nachricht einer anderen Person danach → Korrektur, nichts gelöscht")
    lea = Principal("guest", "u_lea", "s_lea")
    ok(server.guest_event("message.deleted", {"id": "m_1", "bot_id": lio}, lea) == ("message.deleted", {"id": "m_1", "bot_id": lio}),
       "WebSocket-Filter: message.deleted geht an Gäste des geteilten Scoops")
    ok(server.guest_event("message.deleted", {"id": "m_1", "bot_id": mila}, lea) is None, "… aber nicht für andere Scoops")
    server.shares.shares = [Share("sh_1", lio, "u_lea", "Lea", "read", "none")]
    ok(edit(gmsg["id"], "nur lesen", headers=G).status_code == 403, "Rolle „Lesen“ darf nicht bearbeiten")
    server.shares.shares = []

    print("Bausteine")
    row = lambda role, text="", **meta: {"role": role, "text": text, "meta": json.dumps(meta)}  # noqa: E731
    ok(chat_edit.clean_followers([]), "nichts nach der Nachricht → sauber")
    ok(chat_edit.clean_followers([row("status", lines=["x"], effects=False), row("bot", "a", run_info={"effects": False}),
                                  row("event", "Angehalten", icon="stop.circle"), row("event", "Abo", abo_fallback="claude"),
                                  row("bot", "Fehler", failed=True)]), "Antworten ohne Wirkung, Angehalten, Abo-Hinweis → sauber")
    for bad, why in ((row("status", lines=["x"]), "Status ohne Angabe"), (row("status", effects=False, task={"id": "t"}), "Aufgaben-Karte"),
                     (row("bot", "a", run_info={"effects": False}, peer=True), "Nachricht eines anderen Scoops"),
                     (row("bot", "a"), "Antwort ohne run_info"), (row("event", "Datei", file_id="f_1"), "Datei-Ereignis"),
                     (row("approval"), "Freigabe"), (row("user", "x"), "Nachricht einer Person"),
                     (row("bot", "a", run_info={"effects": False}, task_id="t_1"), "Antwort aus einer Aufgabe")):
        if chat_edit.clean_followers([bad]):
            raise AssertionError(f"{why} dürfte nicht als sauber gelten")
    ok(True, "acht Fälle mit möglicher Wirkung → nie sauber")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil

        shutil.rmtree(TMP, ignore_errors=True)
