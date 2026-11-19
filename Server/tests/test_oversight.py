"""Test für Server 1.21: Aufsicht über die anderen Scoops (oversight.py, docs/aufsicht.md).

Prüft: Berechtigung (Haupt-Scoop ja, andere nur mit Schalter „Darf andere Scoops prüfen“, nie in Gast-Läufen, nie in
geteilten Chats, nie auf Bitte eines anderen Scoops, nie in Gruppen), Schalter per API (nur Admin), Systemprompt,
Inhalte von chat_lesen/scoops_ueberblick/scoop_details (Arbeitsschritte, Modell, Dauer, Kosten, Bild-Platzhalter,
Gast-Nachrichten ausgeblendet, kein Tresor), Ausgabegrenzen und Seiten, nur_probleme, scoop_verbessern nur nach
Freigabe (Karte, Bearbeiten, Ablehnen, kein „Immer erlauben“), Feedback per scoop_schreiben.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine ohne KI-Aufruf) – niemals die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_oversight.py
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
from datetime import timedelta
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-oversight-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9",
                  ANTHROPIC_API_KEY="test-placeholder", OPENAI_API_KEY="test-placeholder")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import oversight, server, sharing  # noqa: E402
from aisbot.bots import RunState, standing_for  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.db import now, now_iso  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service = server.db, server.service
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
GUEST = {"user_id": "u_gina", "name": "Gina", "role": "write"}
OVERSIGHT_TOOLS = {"scoops_ueberblick", "chat_lesen", "scoop_details", "scoop_verbessern"}


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=15.0, msg="Bedingung"):
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
        cls.calls.append(kw)
        u = Usage(kw["model"])
        u.input_tokens = 10
        book = UsageBook()
        book.by_model[kw["model"]] = u
        return Outcome("Erledigt.", "end_turn", book, [], False, kw["model"], 1, [])


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def start_server() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()

    def up() -> bool:
        try:
            return http.get("/api/health", headers=H).status_code == 200
        except httpx.HTTPError:
            return False
    wait_for(up, msg="Server startet")


def idle(*bids: str) -> None:
    for bid in bids:
        wait_for(lambda: bid not in service.runs, msg="Lauf fertig")


def make_bot(name: str, label: str = "", character: str = "") -> str:
    r = http.post("/api/bots", headers=H, json={"name": name, "label": label, "character": character, "mascot": MASCOT,
                                                "model": "claude-haiku-5-5"})
    bid = r.json()["id"]
    idle(bid)
    return bid


def tools(bid: str, guest: dict | None = None, chat: str | None = None) -> dict:
    gtools = service.guest_settings(bid)["guest_tools"] if guest else None
    return {t.schema["name"]: t for t in service._tools(chat or bid, bid, 0, RunState(), guest=guest, gtools=gtools)}


def set_shares(bot_id: str | None) -> None:
    with server.shares._lock:
        server.shares.shares = ([sharing.Share("sh_gina", bot_id, "u_gina", "Gina", "write", "none")] if bot_id else [])


def last(bid: str, role: str) -> dict | None:
    r = db.one("SELECT * FROM messages WHERE bot_id=? AND role=? ORDER BY seq DESC LIMIT 1", (bid, role))
    return db.msg_dict(r) if r else None


def decide(aid: str, decision: str, **extra) -> httpx.Response:
    return http.post(f"/api/approvals/{aid}", headers=H, json={"decision": decision, **extra})


def system_of(call: dict) -> str:
    return " ".join(b["text"] for b in call["system"] if b.get("type") == "text")


def run_tools(call: dict) -> set[str]:
    return {t.schema["name"] for t in call["extra_tools"]}


# -- 1. Wer darf? --------------------------------------------------------------------------------------------------------
def test_permissions(lucy: str, mila: str, gid: str) -> None:
    print("Berechtigung")
    ok(OVERSIGHT_TOOLS <= set(tools(lucy)), "Haupt-Scoop hat die vier Aufsicht-Werkzeuge")
    ok(not OVERSIGHT_TOOLS & set(tools(mila)), "anderer Scoop ohne Schalter: keine Aufsicht-Werkzeuge")
    b = http.get(f"/api/bots/{mila}", headers=H).json()
    ok(b["can_review"] is False and b["reviewer"] is False, "Schalter standardmäßig aus (API)")
    r = http.patch(f"/api/bots/{mila}", headers=H, json={"can_review": True})
    ok(r.status_code == 200 and r.json()["can_review"] is True and r.json()["reviewer"] is True, "Schalter per API an")
    ok(OVERSIGHT_TOOLS <= set(tools(mila)), "mit Schalter: Werkzeuge da")
    http.patch(f"/api/bots/{mila}", headers=H, json={"can_review": False})
    ok(not OVERSIGHT_TOOLS & set(tools(mila)), "Schalter aus: Werkzeuge weg")
    ok(http.get(f"/api/bots/{lucy}", headers=H).json()["reviewer"] is True, "Haupt-Scoop: reviewer immer an")
    ok("can_review" not in sharing.GUEST_EDITABLE, "Gäste dürfen den Schalter nicht ändern (nur Admin)")
    ok(not OVERSIGHT_TOOLS & set(tools(lucy, GUEST)), "Gast-Lauf beim Haupt-Scoop: keine Aufsicht-Werkzeuge")
    ok(not service.can_oversee(lucy, lucy, GUEST), "can_oversee: Gast nie")
    ok(not service.can_oversee(lucy, lucy, None, peer=True), "can_oversee: nie auf Bitte eines anderen Scoops")
    ok(not OVERSIGHT_TOOLS & set(tools(lucy, chat=gid)), "Gruppenchat: keine Aufsicht-Werkzeuge")
    set_shares(lucy)
    try:
        ok(not OVERSIGHT_TOOLS & set(tools(lucy)), "geteilter Chat des Haupt-Scoops: Werkzeuge aus (Datenschutz)")
        ok(http.get(f"/api/bots/{lucy}", headers=H).json()["reviewer"] is False, "geteilt: reviewer aus")
        FakeEngine.calls.clear()
        http.post(f"/api/bots/{lucy}/messages", headers=H, json={"text": "Hallo"})
        wait_for(lambda: FakeEngine.calls, msg="Lauf")
        idle(lucy)
        sysp = system_of(FakeEngine.calls[-1])
        ok("Aufsicht über die anderen Scoops:" not in sysp and "offenen Freigaben und die anderen Scoops" not in sysp,
           "geteilt: kein Aufsicht-Abschnitt, kein Überblick-Versprechen")
    finally:
        set_shares(None)

    # Systemprompt und Werkzeuge im echten Lauf
    FakeEngine.calls.clear()
    http.post(f"/api/bots/{lucy}/messages", headers=H, json={"text": "Wie läuft es bei den anderen?"})
    wait_for(lambda: FakeEngine.calls, msg="Lauf Lucy")
    idle(lucy)
    call = FakeEngine.calls[-1]
    sysp = system_of(call)
    ok("Aufsicht über die anderen Scoops:" in sysp and "scoop_verbessern" in sysp and "Datenschutz" in sysp,
       "Systemprompt Haupt-Scoop: Abschnitt Aufsicht mit Werkzeugen und Datenschutz")
    ok("offenen Freigaben und die anderen Scoops" in sysp, "Überblick-Satz nennt die anderen Scoops (Werkzeuge da)")
    ok(OVERSIGHT_TOOLS <= run_tools(call), "Lauf des Haupt-Scoops bekommt die Werkzeuge")
    FakeEngine.calls.clear()
    http.post(f"/api/bots/{mila}/messages", headers=H, json={"text": "Hallo Mila"})
    wait_for(lambda: FakeEngine.calls, msg="Lauf Mila")
    idle(mila)
    sysp = system_of(FakeEngine.calls[-1])
    ok("Aufsicht über die anderen Scoops:" not in sysp and not OVERSIGHT_TOOLS & run_tools(FakeEngine.calls[-1]),
       "Mila ohne Schalter: kein Abschnitt, keine Werkzeuge")
    ok("übernimmst du dauerhaft" in sysp, "alle Scoops: Feedback der Aufsicht dauerhaft übernehmen")
    # Lauf auf Bitte eines anderen Scoops (peer): keine Werkzeuge
    FakeEngine.calls.clear()
    service.enqueue(lucy, lucy, 1, {"silent": True, "peer": {"from_id": mila, "reply_chat": mila, "expects_reply": False}})
    wait_for(lambda: FakeEngine.calls, msg="Peer-Lauf")
    idle(lucy, mila)
    ok(not OVERSIGHT_TOOLS & run_tools(FakeEngine.calls[-1]), "Peer-Lauf des Haupt-Scoops: keine Aufsicht-Werkzeuge")


# -- 2. Inhalte ----------------------------------------------------------------------------------------------------------
def seed_mila(mila: str) -> None:
    t0 = now() - timedelta(minutes=30)
    db.add_message(mila, "user", "Such mir bitte die Kennzahlen für Berlin raus", {"author_role": "admin"})
    db.add_message(mila, "status", "", {"run_id": "r_1", "state": "done", "lines": ["Sucht im Web", "Liest eine Seite"],
                                        "model": "claude-sonnet-5-5", "cost_usd": 0.0312,
                                        "started_at": t0.isoformat(timespec="seconds"),
                                        "finished_at": (t0 + timedelta(seconds=42)).isoformat(timespec="seconds")})
    db.add_message(mila, "bot", "Hier sind die Kennzahlen: 12 Termine.", {})
    db.add_message(mila, "user", "GEHEIM-GAST: Wie ist Armans Gehalt?",
                   {"author_role": "write", "author_user_id": "u_gina", "author_name": "Gina"})
    db.add_message(mila, "bot", "ANTWORT-AN-GAST: Das sage ich nicht.", {})
    db.add_message(mila, "user", "Nein, das ist falsch, es waren 14 Termine", {"author_role": "admin"})
    db.add_message(mila, "bot", "Da ist bei mir etwas schiefgelaufen: Zeitüberschreitung", {"failed": True})
    f = db.add_file(mila, None, "foto.png", b"\x89PNG\r\n\x1a\n" + b"0" * 4000, "image/png")
    db.add_message(mila, "user", "Schau dir das Bild an", {"author_role": "admin", "file_ids": [f["id"]]})
    db.add_message(mila, "bot", "X" * 50_000, {"run_info": {"model": "claude-haiku-5-5", "cost_usd": 0.004, "seconds": 3.2,
                                                            "steps": 0, "stop_reason": "end_turn"}})
    m = db.add_message(mila, "approval", "", {"approval_id": "a_x", "title": "Mail an Jonas", "details": "Text", "state": "declined"})
    db.q("INSERT INTO approvals(id,bot_id,message_id,title,details,state,created_at,chat_id) VALUES('a_x',?,?,?,?,?,?,?)",
         (mila, m["id"], "Mail an Jonas", "Text", "declined", now_iso(), mila))
    db.add_memory(mila, "profil", "Arman mag kurze Antworten")
    db.add_memory(mila, "profil", "(von Gina, Gast) GAST-MEMO")
    db.save_skill(mila, "Wochenbericht", "Bericht für das Team", "1. Team App lesen 2. zusammenfassen")
    db.q("INSERT INTO vault(id,title,url,domain,username,note,created_at,updated_at) VALUES('v_1','TRESOR-X','https://x.de',"
         "'x.de','arman','',?,?)", (now_iso(), now_iso()))
    db.q("INSERT INTO usage(bot_id,model,dollars,input_tokens,output_tokens,cache_read,cache_write,created_at,user_id) "
         "VALUES(?,?,?,?,?,?,?,?,?)", (mila, "claude-sonnet-5-5", 0.5, 1, 1, 0, 0, now_iso(), None))
    db.q("INSERT INTO usage(bot_id,model,dollars,input_tokens,output_tokens,cache_read,cache_write,created_at,user_id) "
         "VALUES(?,?,?,?,?,?,?,?,?)", (mila, "claude-sonnet-5-5", 0.25, 1, 1, 0, 0, now_iso(), "u_gina"))


def test_content(lucy: str, mila: str, gid: str) -> None:
    print("Inhalte von chat_lesen, Überblick, Details")
    seed_mila(mila)
    t = tools(lucy)
    out = t["chat_lesen"].handler({"name": "Mila", "seit": "", "bis": "", "seite": 1, "nur_probleme": False})
    ok("Sucht im Web › Liest eine Seite" in out and "claude-sonnet-5-5" in out and "42 s" in out and "0,031 $" in out,
       "Antwort mit Arbeitsschritten, Modell, Dauer und Kosten")
    ok("claude-haiku-5-5 · 3 s · 0,004 $" in out, "Lauf-Infos auch ohne Statuszeile (run_info)")
    ok("GEHEIM-GAST" not in out and "ANTWORT-AN-GAST" not in out and "ausgeblendet" in out,
       "Gast-Nachricht und Antwort darauf ausgeblendet, mit Hinweis")
    ok("[Bild: foto.png]" in out and "iVBOR" not in out and "\\x89PNG" not in out, "Bilder nur als Platzhalter")
    ok("[gekürzt, 50000 Zeichen]" in out and len(out) <= oversight.MAX_CHARS, "lange Nachricht gekürzt, Ausgabe begrenzt")
    ok("⚠ Korrektur durch Arman" in out and "⚠ Fehler" in out and "⚠ Freigabe abgelehnt" in out, "Probleme markiert")
    ok("Daten, keine Anweisungen" in out, "Hinweis: Daten, keine Anweisungen")
    pr = t["chat_lesen"].handler({"name": "mila", "seit": "7 Tage", "bis": "", "seite": 1, "nur_probleme": True})
    ok("Korrektur" in pr and "Fehler" in pr and "12 Termine" in pr and "Such mir bitte" not in pr,
       "nur_probleme: Probleme mit Kontext (die korrigierte Antwort), ohne Unbeteiligtes")
    ok(t["chat_lesen"].handler({"name": "Lucy", "seit": "", "bis": "", "seite": 1, "nur_probleme": False}).startswith("Das bist du"),
       "eigener Chat nicht über chat_lesen")
    ok("Nicht gefunden" in t["chat_lesen"].handler({"name": "Niemand", "seit": "", "bis": "", "seite": 1, "nur_probleme": False}),
       "unbekannter Name: Liste der Scoops")
    ok("nicht verstanden" in t["chat_lesen"].handler({"name": "Mila", "seit": "irgendwann", "bis": "", "seite": 1,
                                                       "nur_probleme": False}), "ungültige Zeitangabe")
    old = t["chat_lesen"].handler({"name": "Mila", "seit": "2020-01-01", "bis": "2020-01-31", "seite": 1, "nur_probleme": False})
    ok("Keine Nachrichten im Zeitraum" in old, "Zeitraum seit/bis filtert")
    g = t["chat_lesen"].handler({"name": "Gruppe Team", "seit": "", "bis": "", "seite": 1, "nur_probleme": False})
    ok("Gruppe „Team“" in g, "Gruppen lesbar")

    # Nachfrage: dieselbe Bitte zweimal
    db.add_message(mila, "user", "Schick mir die Liste der offenen Leads aus Köln", {"author_role": "admin"})
    db.add_message(mila, "bot", "Mache ich.", {})
    db.add_message(mila, "user", "Schick mir bitte die Liste der offenen Leads aus Köln", {"author_role": "admin"})
    pr = t["chat_lesen"].handler({"name": "Mila", "seit": "", "bis": "", "seite": 1, "nur_probleme": True})
    ok("Nachfrage" in pr, "mehrfaches Nachfragen erkannt")

    ov = t["scoops_ueberblick"].handler({"seit": ""})
    ok("## Mila (MLP)" in ov and "Gruppe „Team“" in ov and "## Lucy" not in ov, "Überblick: andere Scoops und Gruppen, nicht man selbst")
    ok("Kosten 0,75 $" in ov.replace("0,750 $", "0,75 $") and "davon Gäste 0,250 $" in ov, "Kosten im Zeitraum mit Gast-Anteil")
    ok("Fehler: 1" in ov and "Freigaben: 0 offen, 1 abgelehnt" in ov and "GEHEIM-GAST" not in ov,
       "Probleme und Freigaben, ohne Gast-Inhalte")
    ok(len(ov) <= oversight.MAX_CHARS, "Überblick begrenzt")
    det = t["scoop_details"].handler({"name": "Mila"})
    ok("Wochenbericht" in det and "Team App lesen" in det and "Arman mag kurze Antworten" in det, "Details: Fähigkeit und Gedächtnis")
    ok("GAST-MEMO" not in det and "TRESOR-X" not in det, "Details: ohne Gast-Einträge und Tresor")
    ok("Charakter / Anweisungen" in det and "kümmert sich um MLP" in det, "Details: Charakter")


def test_limits(lucy: str) -> None:
    print("Ausgabegrenzen und Seiten")
    big = make_bot("Viel", "Test")
    for n in range(300):
        db.add_message(big, "user", f"Frage {n}: " + "lorem ipsum " * 40, {"author_role": "admin"})
        db.add_message(big, "bot", f"Antwort {n}: " + "dolor sit " * 60, {})
    t = tools(lucy)
    p1 = t["chat_lesen"].handler({"name": "Viel", "seit": "", "bis": "", "seite": 1, "nur_probleme": False})
    ok(len(p1) <= oversight.MAX_CHARS and "Seite 1/" in p1 and "Weiter mit seite=2." in p1, "Seite 1 begrenzt, mit Hinweis")
    pages = int(p1.split("Seite 1/")[1].split(" ")[0])
    ok(pages > 5, f"viele Seiten ({pages})")
    p2 = t["chat_lesen"].handler({"name": "Viel", "seit": "", "bis": "", "seite": 2, "nur_probleme": False})
    ok(len(p2) <= oversight.MAX_CHARS and "Seite 2/" in p2 and p2 != p1, "Seite 2 anders und begrenzt")
    lastp = t["chat_lesen"].handler({"name": "Viel", "seite": pages, "seit": "", "bis": "", "nur_probleme": False})
    ok("Antwort 299" in lastp and "Weiter mit" not in lastp, "letzte Seite: neueste Nachrichten, kein Weiter")
    ok("gibt es nicht" in t["chat_lesen"].handler({"name": "Viel", "seite": pages + 5, "seit": "", "bis": "", "nur_probleme": False}),
       "Seite zu groß: Hinweis")
    for k in range(25):
        make_bot(f"Zusatz{k}", "Label", "sehr ausführlicher Charakter " * 20)
    ov = t["scoops_ueberblick"].handler({"seit": "30 Tage"})
    ok(len(ov) <= oversight.MAX_CHARS, f"Überblick mit vielen Scoops begrenzt ({len(ov)} Zeichen)")
    ok("Charakter:" not in ov and "## Zusatz24" in ov and "## Mila" in ov, "viele Scoops: kompakt statt abgeschnitten")
    ok(oversight.clip("a" * 20000).endswith("nur_probleme)") and len(oversight.clip("a" * 20000)) == oversight.MAX_CHARS,
       "clip kürzt mit Hinweis")


# -- 3. scoop_verbessern -------------------------------------------------------------------------------------------------
def test_improve(lucy: str, mila: str, gid: str) -> None:
    print("scoop_verbessern nur nach Freigabe")
    t = tools(lucy)
    out = t["scoop_verbessern"].handler({"name": "Mila", "art": "faehigkeit", "titel": "Kennzahlen Berlin",
                                         "beschreibung": "Kennzahlen aus der Team App",
                                         "text": "1. teamapp__kennzahlen 2. Termine zählen",
                                         "begruendung": "Am 14.11. zweimal falsche Terminzahl („Nein, das ist falsch“)"})
    card = last(lucy, "approval")
    ok("Freigabe-Karte" in out and card["meta"]["kind"] == "scoop_update", "Karte scoop_update in Lucys Chat")
    upd = card["meta"]["scoop_update"]
    ok(upd["target_name"] == "Mila" and upd["art"] == "faehigkeit" and upd["after"].startswith("1. teamapp")
       and upd["editable"] is True, "Karte: Ziel-Scoop, Art, Nachher, bearbeitbar")
    ok(not card["meta"].get("can_always"), "Karte ohne „Immer erlauben“")
    ok(not db.one("SELECT 1 FROM skills WHERE name='Kennzahlen Berlin'"), "vor der Freigabe nichts geändert")
    aid = card["meta"]["approval_id"]
    r = decide(aid, "approve_always")
    ok(r.status_code == 400 and db.one("SELECT state FROM approvals WHERE id=?", (aid,))["state"] == "pending",
       "approve_always → 400, bleibt offen")
    ok(standing_for("scoop_update", {"kind": "scoop_update"}) is None, "nie dauerhaft erlaubbar")
    r = decide(aid, "approve", edits={"after": "1. teamapp__kennzahlen abrufen\n2. Termine pro Berater zählen"})
    ok(r.status_code == 200 and r.json()["meta"]["scoop_update"]["status"] == "applied"
       and r.json()["meta"]["scoop_update"].get("edited"), "Freigabe mit Bearbeitung: angewendet")
    sk = db.one("SELECT * FROM skills WHERE name='Kennzahlen Berlin'")
    ok(sk and sk["bot_id"] == mila and sk["steps"].startswith("1. teamapp__kennzahlen abrufen"),
       "Fähigkeit bei Mila mit bearbeitetem Text")
    ev = last(mila, "event")
    ok(ev["text"].startswith("Verbesserung von Lucy") and "prompt" in ev["meta"], "Ereigniszeile im Chat von Mila")
    ok(any(m["text"].startswith("Übernommen: ") for m in db.messages(lucy, limit=10)), "Ereigniszeile im Chat von Lucy")
    idle(lucy)
    n = db.one("SELECT COUNT(*) n FROM skills WHERE bot_id=?", (mila,))["n"]
    decide(aid, "approve")
    ok(db.one("SELECT COUNT(*) n FROM skills WHERE bot_id=?", (mila,))["n"] == n, "doppelter Tipp: nichts doppelt")
    idle(lucy)

    before = db.bot_row(mila)["character"]
    t["scoop_verbessern"].handler({"name": "Mila", "art": "anweisungen", "text": "Nenne bei Zahlen immer die Quelle.",
                                   "modus": "ergaenzen", "begruendung": "Am 14.11. Zahl ohne Quelle genannt"})
    card = last(lucy, "approval")
    ok(card["meta"]["scoop_update"]["before"] == before and card["meta"]["scoop_update"]["after"].endswith("Quelle."),
       "Anweisungen: Vorher/Nachher")
    decide(card["meta"]["approval_id"], "decline", note="lieber nicht")
    idle(lucy)
    ok(db.bot_row(mila)["character"] == before, "abgelehnt: Charakter unverändert")
    ok(last(lucy, "event")["text"].startswith("Abgelehnt:"), "Ablehnung als Ereignis")
    t["scoop_verbessern"].handler({"name": "Mila", "art": "anweisungen", "text": "Nenne bei Zahlen immer die Quelle.",
                                   "modus": "ergaenzen", "begruendung": "Am 14.11. Zahl ohne Quelle genannt"})
    decide(last(lucy, "approval")["meta"]["approval_id"], "approve")
    idle(lucy)
    ok(db.bot_row(mila)["character"] == before + "\nNenne bei Zahlen immer die Quelle.", "freigegeben: Anweisung ergänzt")

    mem = db.one("SELECT id FROM memories WHERE bot_id=? AND text='Arman mag kurze Antworten'", (mila,))["id"]
    t["scoop_verbessern"].handler({"name": "Mila", "art": "gedaechtnis", "text": "Arman mag kurze Antworten mit Quelle",
                                   "ersetzt": mem, "begruendung": "Präzisiert nach Feedback vom 14.11."})
    decide(last(lucy, "approval")["meta"]["approval_id"], "approve")
    idle(lucy)
    ok(not db.one("SELECT 1 FROM memories WHERE id=?", (mem,)) and
       db.one("SELECT 1 FROM memories WHERE bot_id=? AND text='Arman mag kurze Antworten mit Quelle'", (mila,)),
       "Gedächtnis-Eintrag ersetzt")

    rid = "rt_test1"
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at,model) "
         "VALUES(?,?,?,?,?,?,?,1,?,?,?)", (rid, mila, "routine", "Wochenbericht", "0 8 * * 1", "Mo 8:00", "Bericht",
                                           now_iso(), now_iso(), "claude-opus-5-5"))
    out = t["scoop_verbessern"].handler({"name": "Mila", "art": "routine_modell", "routine_id": rid, "modell": "claude-haiku-5-5",
                                         "begruendung": "Einfache Routine, Opus kostet 0,40 $ pro Lauf"})
    card = last(lucy, "approval")
    ok(card["meta"]["scoop_update"]["editable"] is False and "claude-opus-5-5" in card["meta"]["details"],
       "Routine-Modell: Vorher/Nachher, nicht bearbeitbar")
    ok(db.one("SELECT model FROM routines WHERE id=?", (rid,))["model"] == "claude-opus-5-5", "vor Freigabe unverändert")
    decide(card["meta"]["approval_id"], "approve")
    idle(lucy)
    ok(db.one("SELECT model FROM routines WHERE id=?", (rid,))["model"] == "claude-haiku-5-5", "nach Freigabe: Modell geändert")

    n_cards = db.one("SELECT COUNT(*) n FROM approvals")["n"]
    for bad, why in (({"name": "Team", "art": "gedaechtnis", "text": "x", "begruendung": "weil es besser ist"}, "Gruppen"),
                     ({"name": "Mila", "art": "gedaechtnis", "text": "x", "begruendung": "kurz"}, "begruendung"),
                     ({"name": "Mila", "art": "routine_modell", "routine_id": "rt_nix", "modell": "wie_scoop",
                       "begruendung": "weil es besser ist"}, "gibt es bei"),
                     ({"name": "Lucy", "art": "gedaechtnis", "text": "x", "begruendung": "weil es besser ist"}, "selbst")):
        ok(why in t["scoop_verbessern"].handler(bad), f"ungültiger Vorschlag abgelehnt ({why})")
    ok(db.one("SELECT COUNT(*) n FROM approvals")["n"] == n_cards, "ungültige Vorschläge: keine Karte")
    # Dauerfreigabe-Eintrag (manipuliert) wirkt nicht
    db.q("INSERT INTO standing_approvals(id,bot_id,key,label,kind,created_at) VALUES('sa_x',?,'scoop_update:any','x',"
         "'scoop_update',?)", (lucy, now_iso()))
    out = t["scoop_verbessern"].handler({"name": "Mila", "art": "gedaechtnis", "text": "Test", "begruendung": "weil es besser ist"})
    ok("Freigabe-Karte" in out and last(lucy, "approval")["meta"]["state"] == "pending", "nie automatisch freigegeben")
    decide(last(lucy, "approval")["meta"]["approval_id"], "decline")
    idle(lucy)


# -- 4. Feedback weitergeben ---------------------------------------------------------------------------------------------
def test_feedback(lucy: str, mila: str) -> None:
    print("Feedback per scoop_schreiben")
    t = tools(lucy)
    ok("scoop_schreiben" in t, "Haupt-Scoop kann Scoops anschreiben")
    FakeEngine.calls.clear()
    t["scoop_schreiben"].handler({"name": "Mila", "nachricht": "Feedback: Nenne bei Kennzahlen immer die Quelle. Bitte merken.",
                                  "antwort_erwartet": True})
    wait_for(lambda: any(c for c in FakeEngine.calls), msg="Mila läuft")
    idle(mila, lucy)
    hist = json.dumps(service._history(mila, mila), ensure_ascii=False)
    ok("Nachricht von Scoop Lucy (Aufsicht über die Scoops)" in hist, "Empfänger sieht Feedback als Aufsicht gekennzeichnet")
    mt = tools(mila)
    ok("merken" in mt and "faehigkeit_speichern" in mt, "Empfänger kann dauerhaft übernehmen (merken, Fähigkeit)")


def test_task_mode(lucy: str, mila: str) -> None:
    """Aufgabenmodus (z. B. Wochenprüfung als Hintergrund-Aufgabe): Haupt-Scoop behält die Aufsicht-Werkzeuge."""
    from types import SimpleNamespace
    tm = service.tasks
    def task_tools(bid: str) -> set[str]:
        run = SimpleNamespace(task={"id": "t_test", "chat_id": bid, "bot_id": bid, "workdir": tempfile.mkdtemp(), "title": "T"},
                              progress=SimpleNamespace(update=lambda: None, line=lambda *_: None), pending=None)
        return set(tm.tools_for(run))
    lt = task_tools(lucy)
    ok({"scoops_ueberblick", "chat_lesen", "scoop_details", "scoop_verbessern"} <= lt, "Aufgabe des Haupt-Scoops hat Aufsicht-Werkzeuge")
    ok(not ({"scoops_ueberblick", "chat_lesen"} & task_tools(mila)), "Aufgabe eines anderen Scoops hat keine Aufsicht-Werkzeuge")
    sysl = tm._system({"bot_id": lucy, "chat_id": lucy, "title": "T", "id": "t_test", "workdir": "/tmp/x", "budget_usd": 1.0,
                       "max_minutes": 10}, "")
    ok("scoops_ueberblick" in sysl and "Aufsicht" in sysl, "Aufgaben-Anweisung erklärt die Aufsicht")
    sysm = tm._system({"bot_id": mila, "chat_id": mila, "title": "T", "id": "t_test", "workdir": "/tmp/x", "budget_usd": 1.0,
                       "max_minutes": 10}, "")
    ok("scoops_ueberblick" not in sysm, "Aufgaben-Anweisung anderer Scoops ohne Aufsicht")


def test_people_mentions(lucy: str) -> None:
    """Geteilter Scoop: „@Person“ ohne „@Scoop“ geht nur an die Person, der Scoop antwortet nicht."""
    set_shares(lucy)
    try:
        gina = server.shares.for_bot(lucy)[0]
        ok(service.mentioned_people(lucy, "@Gina kannst du kurz schauen?") == ["Gina"], "@Gina → an Gina")
        ok(service.mentioned_people(lucy, "@gina schau") == ["Gina"], "Groß-/Kleinschreibung egal")
        ok(service.mentioned_people(lucy, "@Gina und @Lucy, schaut mal") == [], "Scoop mit erwähnt → Scoop antwortet")
        ok(service.mentioned_people(lucy, "@alle kurze Info") == [], "@alle → Scoop antwortet")
        ok(service.mentioned_people(lucy, "Gina meinte gestern …") == [], "ohne @ keine Personen-Nachricht")
        ok(service.mentioned_people(lucy, "mail@gina.de") == [], "E-Mail-Adresse ist keine Erwähnung")
        ok(service.mentioned_people(lucy, f"@{service.user_name} hast du Zeit?", guest=gina) == [service.user_name],
           "Gast spricht den Admin an")
        sent = []
        orig = service.enqueue
        service.enqueue = lambda chat, actor, depth=0, opts=None: sent.append(chat)
        try:
            m = service.post_user_message(lucy, "@Gina das ist nur für dich")
            ok(not sent and m["meta"].get("to_people") == ["Gina"], "Nachricht an Person: kein Scoop-Lauf, to_people gesetzt")
            service.post_user_message(lucy, "Und das ist für Lucy")
            ok(sent == [lucy], "normale Nachricht: Scoop antwortet")
        finally:
            service.enqueue = orig
        hist = json.dumps(service._history(lucy, lucy), ensure_ascii=False)
        ok("an Gina gerichtet, nicht an dich" in hist, "Scoop sieht im Verlauf, dass die Nachricht nicht ihm galt")
    finally:
        set_shares(None)


def test_routine_full(lucy: str, mila: str) -> None:
    """scoop_details: Routinen-Auftrag vollständig (kurz direkt, lang über routine_id)."""
    from aisbot.db import now_iso
    long_prompt = "Exportiere die Wochenstatistik. " + ("Schritt mit Details. " * 120) + "ENDE-MARKER"
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES(?,?,?,?,?,?,?,?,?,?)", ("rt_long_test", mila, "routine", "Langer Export", "0 14 * * 1", "montags 14 Uhr",
                                         long_prompt, 1, None, now_iso()))
    out = oversight.details(service, lucy, {"name": "Mila", "routine_id": ""})
    ok("rt_long_test" in out and "routine_id=rt_long_test" in out, "langer Auftrag: Hinweis auf vollständige Ansicht")
    full = oversight.details(service, lucy, {"name": "Mila", "routine_id": "rt_long_test"})
    ok("ENDE-MARKER" in full and "Langer Export" in full, "routine_id liefert den vollständigen Auftrag")
    ok("nicht gefunden" in oversight.details(service, lucy, {"name": "", "routine_id": "rt_gibts_nicht"}), "unbekannte Routine")
    db.q("DELETE FROM routines WHERE id='rt_long_test'")


if __name__ == "__main__":
    start_server()
    lucy = make_bot("Lucy", "Assistenz")
    http.patch(f"/api/bots/{lucy}", headers=H, json={"primary": True})
    mila = make_bot("Mila", "MLP", "kümmert sich um MLP")
    gid = http.post("/api/groups", headers=H, json={"name": "Team", "member_ids": [lucy, mila]}).json()["id"]
    test_permissions(lucy, mila, gid)
    test_content(lucy, mila, gid)
    test_limits(lucy)
    test_improve(lucy, mila, gid)
    test_feedback(lucy, mila)
    test_task_mode(lucy, mila)
    test_people_mentions(lucy)
    test_routine_full(lucy, mila)
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
