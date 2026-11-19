"""Test für Server 1.20: „Immer erlauben“ (dauerhafte Freigaben pro Scoop) und Modell pro Routine.

Prüft: Schlüssel je Art und Sperrliste (Anrufe, Tresor, Schlösser/Alarm, Zahlungen, Logins, zu allgemeine Schlüssel),
approve_always über die API, automatische Freigabe ohne Karte (allgemein, Mail, T3, Home), Gast-Fall (kein Knopf, 400,
keine automatische Freigabe), Systemprompt, Aufgabenmodus pausiert nicht bei Dauerfreigabe, Liste/Entfernen,
Routine mit eigenem Modell (Werkzeuge, API, Lauf, Kosten, Rückfall, Verstärkung).

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine ohne KI-Aufruf) – niemals die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_standing.py
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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-standing-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9",
                  # Schlüssel nur als Platzhalter, damit die Modelle als verfügbar gelten (Fake-Engine, kein Aufruf)
                  ANTHROPIC_API_KEY="test-placeholder", OPENAI_API_KEY="test-placeholder")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import bots as bots_mod, server  # noqa: E402
from aisbot.bots import RunState, art_slug, standing_for  # noqa: E402
from aisbot.config import Usage, UsageBook  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service, tasks = server.db, server.service, server.tasks
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}
GUEST = {"user_id": "u_gast", "name": "Gina", "role": "write"}


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


def make_bot(name: str, model: str = "claude-haiku-5-5") -> str:
    r = http.post("/api/bots", headers=H, json={"name": name, "mascot": MASCOT, "model": model})
    bid = r.json()["id"]
    wait_for(lambda: bid not in service.runs, msg="Begrüßung fertig")
    return bid


def idle(bid: str) -> None:
    wait_for(lambda: bid not in service.runs, msg="Lauf fertig")


def tools(bid: str, guest: dict | None = None) -> dict:
    gtools = service.guest_settings(bid)["guest_tools"] if guest else None
    return {t.schema["name"]: t for t in service._tools(bid, bid, 0, RunState(), guest=guest, gtools=gtools)}


def last(bid: str, role: str) -> dict | None:
    r = db.one("SELECT * FROM messages WHERE bot_id=? AND role=? ORDER BY seq DESC LIMIT 1", (bid, role))
    return db.msg_dict(r) if r else None


def count(bid: str, role: str) -> int:
    return db.one("SELECT COUNT(*) n FROM messages WHERE bot_id=? AND role=?", (bid, role))["n"]


def decide(aid: str, decision: str, **extra) -> httpx.Response:
    return http.post(f"/api/approvals/{aid}", headers=H, json={"decision": decision, **extra})


# -- 1. Schlüssel und Sperrliste --------------------------------------------------------------------------------------
def test_keys() -> None:
    print("Schlüssel je Art und Sperrliste")
    k = standing_for("freigabe", art="teamapp-checkouts-abhaken", art_label="Friday Checkouts abhaken", title="Checkouts abhaken")
    ok(k == ("freigabe:teamapp-checkouts-abhaken", "Friday Checkouts abhaken"), "allgemeine Freigabe mit art")
    ok(art_slug("Team App: Checkouts abhaken") == "team-app-checkouts-abhaken", "art wird zu stabilem Schlüssel")
    ok(standing_for("freigabe", art="", title="Checkouts abhaken") is None, "ohne art kein „Immer erlauben“")
    for generic in ("allgemein", "alles", "freigabe", "aktion", "mail", "alle-aktionen", "xy"):
        ok(standing_for("freigabe", art=generic, title="Irgendwas") is None, f"zu allgemeiner Schlüssel „{generic}“ zählt nicht")
    for art, title in (("rechnung-bezahlen", "Rechnung bezahlen"), ("miete-ueberweisen", "Miete überweisen"),
                       ("haustuer-oeffnen", "Haustür öffnen"), ("garage-zu", "Garage schließen"),
                       ("alarm-scharf", "Alarmanlage scharf"), ("netflix-login", "Login bei Netflix"),
                       ("amazon-bestellung", "Bestellung aufgeben"), ("kunden-anruf", "Kunden anrufen"),
                       ("passwort-aendern", "Passwort ändern"), ("schloss-auf", "Türschloss entriegeln")):
        ok(standing_for("freigabe", art=art, title=title) is None, f"nie dauerhaft: {title}")
    ok(standing_for("freigabe", art="wochenbericht-teilen", title="Natürlich den Wochenbericht teilen") is not None,
       "„natürlich“ ist keine Tür")
    ok(standing_for("call", {"kind": "call", "number": "+49301234567"}) is None, "Anrufe nie dauerhaft")
    ok(standing_for("vault", {"kind": "vault", "domain": "x.de"}) is None, "Tresor nie dauerhaft")
    mk = standing_for("mail", {"kind": "mail", "account": "privat", "account_email": "me@x.de", "to": ["Jonas@x.de"], "cc": []})
    ok(mk and mk[0] == "mail:me@x.de:jonas@x.de", "Mail je Konto und Empfänger")
    ok(standing_for("t3", {"kind": "t3", "project_id": "p1", "project_path": "/a", "project_title": "App"})[0] == "t3:p1:/a",
       "T3 je Projekt")
    ok(standing_for("t3_send", {"kind": "t3_send", "thread_id": "th1"})[0] == "t3_send:th1", "T3-Nachricht je Thread")
    light = {"kind": "apple", "service": "home", "command": "apple.home.set", "params": {"id": "acc1", "on": True},
             "label": "Stehlampe"}
    ok(standing_for("apple", light) == ("apple:apple.home.set:acc1", "Home: Stehlampe"), "Home: Licht erlaubbar")
    ok(standing_for("apple", {**light, "sensitive": True}) is None, "Home: als sensibel markiert nie")
    ok(standing_for("apple", {**light, "params": {"id": "l1", "lock": "unsecured", "confirmed": True}}) is None,
       "Home: Schloss nie")
    ok(standing_for("apple", {**light, "params": {"id": "g1", "door": "open"}}) is None, "Home: Tür/Garage nie")
    ok(standing_for("apple", {**light, "params": {"id": "s1", "security": "away"}}) is None, "Home: Alarmanlage nie")
    ok(standing_for("apple", {"kind": "apple", "service": "reminders", "command": "apple.reminders.delete",
                              "params": {"id": "r1"}}) is None, "Apple: Löschen nie dauerhaft")


# -- 2. Allgemeine Freigabe: Immer erlauben, dann automatisch ----------------------------------------------------------
def test_generic(bid: str) -> None:
    print("Allgemeine Freigabe mit art")
    t = tools(bid)
    out = t["freigabe_anfordern"].handler({"titel": "Friday Checkouts abhaken", "details": "3 Einträge in der Team App",
                                           "art": "teamapp-checkouts-abhaken", "art_bezeichnung": "Friday Checkouts abhaken"})
    ok("Freigabe angefragt" in out, "Karte angelegt")
    card = last(bid, "approval")
    ok(card["meta"].get("can_always") is True and card["meta"]["always_label"] == "Friday Checkouts abhaken",
       "Karte: can_always und Bezeichnung")
    aid = card["meta"]["approval_id"]
    r = decide(aid, "approve_always")
    ok(r.status_code == 200 and r.json()["meta"]["state"] == "approved" and r.json()["meta"].get("always"),
       "approve_always gibt frei und markiert die Karte")
    idle(bid)
    lst = http.get(f"/api/bots/{bid}/standing-approvals", headers=H).json()
    ok(len(lst) == 1 and lst[0]["key"] == "freigabe:teamapp-checkouts-abhaken" and lst[0]["kind"] == "freigabe",
       "Dauerfreigabe gespeichert und per API gelistet")
    ok(any(m["text"].startswith("Immer erlaubt: ") for m in http.get(f"/api/bots/{bid}/messages", headers=H).json()),
       "Ereignis „Immer erlaubt“ im Chat")
    ok(decide(aid, "approve_always").status_code == 200 and
       len(http.get(f"/api/bots/{bid}/standing-approvals", headers=H).json()) == 1, "doppelter Tipp: nichts doppelt")

    n_cards = count(bid, "approval")
    out = tools(bid)["freigabe_anfordern"].handler({"titel": "Friday Checkouts abhaken (KW 47)", "details": "5 Einträge",
                                                     "art": "teamapp-checkouts-abhaken", "art_bezeichnung": "Checkouts"})
    ok(out.startswith("Automatisch freigegeben") and count(bid, "approval") == n_cards, "nächstes Mal: keine Karte")
    ev = last(bid, "event")
    ok(not (ev and ev["text"].startswith("Automatisch freigegeben")), "keine Zeile „Automatisch freigegeben“ im Chat")

    out = tools(bid)["freigabe_anfordern"].handler({"titel": "Andere Sache", "details": "x", "art": "", "art_bezeichnung": ""})
    card = last(bid, "approval")
    ok("Freigabe angefragt" in out and not card["meta"].get("can_always"), "ohne art: Karte ohne „Immer erlauben“")
    r = decide(card["meta"]["approval_id"], "approve_always")
    ok(r.status_code == 400 and db.one("SELECT state FROM approvals WHERE id=?", (card["meta"]["approval_id"],))["state"] == "pending",
       "approve_always ohne can_always → 400, Freigabe bleibt offen")
    decide(card["meta"]["approval_id"], "decline")
    idle(bid)
    out = tools(bid)["freigabe_anfordern"].handler({"titel": "Rechnung bezahlen", "details": "120 €", "art": "rechnung-zahlen-monatlich",
                                                     "art_bezeichnung": "Monatsrechnung bezahlen"})
    card = last(bid, "approval")
    ok(not card["meta"].get("can_always") and "kein „Immer erlauben“" in out, "Zahlung: kein Knopf, Scoop bekommt Hinweis")
    ok(decide(card["meta"]["approval_id"], "approve_always").status_code == 400, "Zahlung: approve_always → 400")
    decide(card["meta"]["approval_id"], "decline")
    idle(bid)

    # Systemprompt nennt die Dauerfreigaben
    FakeEngine.calls.clear()
    http.post(f"/api/bots/{bid}/messages", headers=H, json={"text": "Hallo"})
    wait_for(lambda: FakeEngine.calls, msg="Lauf")
    idle(bid)
    system = " ".join(b["text"] for b in FakeEngine.calls[-1]["system"] if b.get("type") == "text")
    ok("Dauerhafte Freigaben" in system and "Friday Checkouts abhaken" in system and "teamapp-checkouts-abhaken" in system,
       "Systemprompt nennt Dauerfreigaben mit Schlüssel")
    ok("`art`" in system, "Systemprompt weist an, art zu setzen")


# -- 3. Gast-Fall --------------------------------------------------------------------------------------------------------
def test_guest(bid: str) -> None:
    print("Gast-Läufe (geteilte Scoops)")
    t = tools(bid, GUEST)
    ok("freigabe_anfordern" in t, "Gast darf Freigaben beim Admin anfragen")
    n_cards = count(bid, "approval")
    out = t["freigabe_anfordern"].handler({"titel": "Friday Checkouts abhaken", "details": "Gast-Lauf",
                                           "art": "teamapp-checkouts-abhaken", "art_bezeichnung": "Checkouts"})
    card = last(bid, "approval")
    ok("Freigabe angefragt" in out and count(bid, "approval") == n_cards + 1,
       "Dauerfreigabe greift in Gast-Läufen nicht (Karte statt automatisch)")
    ok(not card["meta"].get("can_always"), "Gast-Freigabe: kein „Immer erlauben“-Knopf")
    aid = card["meta"]["approval_id"]
    ok(db.one("SELECT guest_user_id FROM approvals WHERE id=?", (aid,))["guest_user_id"] == "u_gast", "Freigabe gehört zum Gast")
    # Selbst wenn die Spalte gesetzt wäre: Gast-Freigaben nie dauerhaft
    db.q("UPDATE approvals SET always_key='freigabe:gast-sache-dauernd', always_label='Gast-Sache' WHERE id=?", (aid,))
    r = decide(aid, "approve_always")
    ok(r.status_code == 400, "approve_always für Gast-Freigabe → 400")
    ok(not any(x["key"] == "freigabe:gast-sache-dauernd" for x in service.standing_approvals(bid)),
       "keine Dauerfreigabe aus einer Gast-Freigabe")
    decide(aid, "decline")
    idle(bid)


# -- 4. Mail, T3, Home, Anruf, Tresor -------------------------------------------------------------------------------------
def test_kinds(bid: str) -> None:
    print("Mail, T3, Home, Anruf, Tresor")
    sent = []
    acc = {"id": "acc_1", "alias": "privat", "email": "me@x.de", "app": "gmail", "status": "active"}
    orig_conn = service.connections
    service.connections = SimpleNamespace(account_for=lambda app, name: acc, accounts=lambda: [acc],
                                          execute=lambda slug, aid, args: sent.append((slug, args)),
                                          prompt_block=lambda: None)
    orig_feature, orig_t3 = bots_mod.feature, {k: getattr(bots_mod.t3, k) for k in ("available", "find_project", "start", "show", "send")}
    started = []
    bots_mod.feature = lambda name: name in ("t3", "lucy") or orig_feature(name)
    bots_mod.t3.available = lambda: True
    bots_mod.t3.find_project = lambda q: {"id": "p_app", "title": "App", "path": "/Users/x/App"}
    bots_mod.t3.start = lambda pid, msg, title=None: started.append(pid) or {"threadId": "th_1", "title": title}
    bots_mod.t3.show = lambda tid, n=1: {"thread": {"title": "Fix", "status": "running"}, "messages": []}
    bots_mod.t3.send = lambda tid, msg: started.append(tid)
    orig_lucy = (bots_mod.lucy.available, bots_mod.lucy.normalize_number)
    bots_mod.lucy.available = lambda: True
    bots_mod.lucy.normalize_number = lambda n: "+4930123456"
    captured = {}
    ran = []

    def apple_tools(tool, request_approval, chat_id, actor_id):
        captured["req"] = request_approval
        return []
    orig_apple = getattr(service, "apple", None)
    service.apple = SimpleNamespace(tools=apple_tools, active_services=lambda: [], run_approved=lambda a: ran.append(a) or "ok")
    try:
        t = tools(bid)
        # Mail: Karte → approve_always → nächste Mail an dieselbe Adresse geht direkt raus
        t["mail_vorbereiten"].handler({"konto": "privat", "an": "jonas@firma.de", "betreff": "Hallo", "text": "Text 1"})
        card = last(bid, "approval")
        ok(card["meta"]["kind"] == "mail" and card["meta"].get("can_always"), "Mail-Karte mit „Immer erlauben“")
        r = decide(card["meta"]["approval_id"], "approve_always")
        ok(r.status_code == 200, "Mail: approve_always")
        wait_for(lambda: len(sent) == 1, msg="Mail 1 gesendet")
        n_cards = count(bid, "approval")
        out = tools(bid)["mail_vorbereiten"].handler({"konto": "privat", "an": "Jonas@firma.de", "betreff": "Nochmal", "text": "Text 2"})
        wait_for(lambda: len(sent) == 2, msg="Mail 2 automatisch gesendet")
        ok(out.startswith("Automatisch freigegeben") and count(bid, "approval") == n_cards and sent[1][1]["body"] == "Text 2",
           "Mail an dieselbe Adresse: automatisch gesendet, keine Karte")
        tools(bid)["mail_vorbereiten"].handler({"konto": "privat", "an": "fremd@firma.de", "betreff": "x", "text": "y"})
        ok(count(bid, "approval") == n_cards + 1 and len(sent) == 2, "andere Adresse: wieder eine Karte")
        decide(last(bid, "approval")["meta"]["approval_id"], "decline")
        # Mail mit geänderten Empfängern: Dauerfreigabe gilt für die tatsächlich gesendeten
        tools(bid)["mail_vorbereiten"].handler({"konto": "privat", "an": "a@firma.de", "betreff": "x", "text": "y"})
        decide(last(bid, "approval")["meta"]["approval_id"], "approve_always", edits={"to": ["b@firma.de"]})
        wait_for(lambda: len(sent) == 3, msg="Mail 3 gesendet")
        keys = {x["key"] for x in service.standing_approvals(bid)}
        ok("mail:me@x.de:b@firma.de" in keys and "mail:me@x.de:a@firma.de" not in keys, "Mail: Schlüssel aus den bearbeiteten Empfängern")
        idle(bid)

        # T3: je Projekt
        t = tools(bid)
        t["t3_auftrag"].handler({"projekt": "App", "auftrag": "Fehler beheben", "titel": "Fix", "rechner": "air"})
        card = last(bid, "approval")
        ok(card["meta"].get("can_always") and "App" in card["meta"]["always_label"], "T3-Karte mit „Immer erlauben“ je Projekt")
        decide(card["meta"]["approval_id"], "approve_always")
        wait_for(lambda: started == ["p_app"], msg="T3 gestartet")
        n_cards = count(bid, "approval")
        out = tools(bid)["t3_auftrag"].handler({"projekt": "App", "auftrag": "Noch was", "titel": "Fix 2", "rechner": "air"})
        wait_for(lambda: started == ["p_app", "p_app"], msg="T3 automatisch gestartet")
        ok(out.startswith("Automatisch freigegeben") and count(bid, "approval") == n_cards, "T3 im selben Projekt: automatisch")
        tools(bid)["t3_nachricht"].handler({"thread_id": "th_9", "nachricht": "Ja, mach"})
        card = last(bid, "approval")
        ok(card["meta"].get("can_always") and count(bid, "approval") == n_cards + 1, "T3-Nachricht: eigener Schlüssel je Thread")
        decide(card["meta"]["approval_id"], "decline")
        idle(bid)

        # Home: unkritisch erlaubbar, Schloss nie
        light = {"kind": "apple", "service": "home", "command": "apple.home.set", "params": {"id": "acc1", "on": True},
                 "label": "Stehlampe", "done": "Stehlampe: einschalten"}
        tools(bid)
        captured["req"]("Stehlampe einschalten", "Licht", light)
        card = last(bid, "approval")
        ok(card["meta"].get("can_always"), "Home-Licht: „Immer erlauben“")
        decide(card["meta"]["approval_id"], "approve_always")
        wait_for(lambda: len(ran) == 1, msg="Home ausgeführt")
        idle(bid)
        n_cards = count(bid, "approval")
        tools(bid)
        out = captured["req"]("Stehlampe einschalten", "Licht", light)
        ok(out.startswith("Automatisch freigegeben") and len(ran) == 2 and count(bid, "approval") == n_cards,
           "Home-Licht: danach automatisch ausgeführt")
        lock = {"kind": "apple", "service": "home", "command": "apple.home.set", "sensitive": True,
                "params": {"id": "lock1", "lock": "unsecured", "confirmed": True}, "label": "Haustür"}
        captured["req"]("Haustür: entriegeln", "Schloss", lock)
        card = last(bid, "approval")
        ok(not card["meta"].get("can_always") and decide(card["meta"]["approval_id"], "approve_always").status_code == 400,
           "Schloss: kein Knopf, approve_always → 400")
        decide(card["meta"]["approval_id"], "decline")
        idle(bid)

        # Anruf und Tresor: nie
        tools(bid)["anrufen"].handler({"nummer": "+49 30 123456", "empfaenger": "Praxis", "kontext": "Termin", "ziel": "Termin"})
        card = last(bid, "approval")
        ok(card["meta"]["kind"] == "call" and not card["meta"].get("can_always"), "Anruf-Karte ohne „Immer erlauben“")
        db.q("UPDATE approvals SET always_key='call:x', always_label='Anruf' WHERE id=?", (card["meta"]["approval_id"],))
        ok(decide(card["meta"]["approval_id"], "approve_always").status_code == 400, "Anruf: approve_always → 400 (auch mit Schlüssel)")
        decide(card["meta"]["approval_id"], "decline")
        idle(bid)
        tools(bid)["tresor_eintrag_anlegen"].handler({"titel": "Netflix", "url": "netflix.com"})
        card = last(bid, "approval")
        ok(card["meta"]["kind"] == "vault" and not card["meta"].get("can_always"), "Tresor-Karte ohne „Immer erlauben“")
        ok(decide(card["meta"]["approval_id"], "approve_always").status_code == 400, "Tresor: approve_always → 400")
        decide(card["meta"]["approval_id"], "decline")
        idle(bid)
    finally:
        service.connections = orig_conn
        bots_mod.feature = orig_feature
        for k, v in orig_t3.items():
            setattr(bots_mod.t3, k, v)
        bots_mod.lucy.available, bots_mod.lucy.normalize_number = orig_lucy
        service.apple = orig_apple


# -- 5. Aufgabenmodus, Liste, Entfernen -------------------------------------------------------------------------------
def test_task_and_delete(bid: str) -> None:
    print("Aufgabenmodus, Liste und Entfernen")
    ex = tools(bid)["freigabe_anfordern"]
    run = SimpleNamespace(task={"bot_id": bid, "id": "t_test"}, pending=None)
    out = tasks._pausing_approval(run, ex).handler({"titel": "Checkouts abhaken", "details": "x",
                                                    "art": "teamapp-checkouts-abhaken", "art_bezeichnung": "Checkouts"})
    ok(out.startswith("Automatisch freigegeben") and run.pending is None, "Aufgabe pausiert bei Dauerfreigabe nicht")
    out = tasks._pausing_approval(run, ex).handler({"titel": "Neu", "details": "x", "art": "", "art_bezeichnung": ""})
    ok(run.pending and json.loads(run.pending)["approval_ids"], "ohne Dauerfreigabe pausiert die Aufgabe wie bisher")
    aid = json.loads(run.pending)["approval_ids"][0]
    db.q("UPDATE approvals SET task_id=NULL WHERE id=?", (aid,))
    decide(aid, "decline")
    idle(bid)

    lst = http.get(f"/api/bots/{bid}/standing-approvals", headers=H).json()
    sid = next(x["id"] for x in lst if x["key"] == "freigabe:teamapp-checkouts-abhaken")
    ok(http.delete(f"/api/bots/{bid}/standing-approvals/{sid}", headers=H).status_code == 200, "Dauerfreigabe entfernt")
    ok(http.delete(f"/api/bots/{bid}/standing-approvals/{sid}", headers=H).status_code == 404, "zweimal entfernen → 404")
    other = make_bot("Andere")
    ok(http.get(f"/api/bots/{other}/standing-approvals", headers=H).json() == [], "gilt nur pro Scoop")
    n_cards = count(bid, "approval")
    tools(bid)["freigabe_anfordern"].handler({"titel": "Checkouts abhaken", "details": "x", "art": "teamapp-checkouts-abhaken",
                                              "art_bezeichnung": "Checkouts"})
    ok(count(bid, "approval") == n_cards + 1, "nach dem Entfernen wird wieder gefragt")
    decide(last(bid, "approval")["meta"]["approval_id"], "decline")
    idle(bid)
    ok(http.get(f"/api/bots/{bid}/standing-approvals", headers={"Authorization": "Bearer falsch"}).status_code == 401,
       "ohne gültiges Token kein Zugriff")


# -- 6. Modell pro Routine --------------------------------------------------------------------------------------------
def test_routine_model(bid: str) -> None:
    print("Modell pro Routine")
    t = tools(bid)
    enum = t["routine_anlegen"].schema["input_schema"]["properties"]["modell"]["enum"]
    ok(enum[0] == "wie_scoop" and "claude-sonnet-5-5" in enum and "gpt-6-luna" in enum, "Werkzeug: modell mit Modellliste")
    out = t["routine_anlegen"].handler({"titel": "Klein", "cron": "0 7 * * *", "zeitplan_text": "Täglich 7:00",
                                        "auftrag": "Kurz prüfen", "modell": "wie_scoop"})
    rid_scoop = out.split("(")[1].split(")")[0]
    out = t["routine_anlegen"].handler({"titel": "Stark", "cron": "0 8 * * 1", "zeitplan_text": "Montags 8:00",
                                        "auftrag": "Wochenanalyse", "modell": "claude-sonnet-5-5"})
    rid = out.split("(")[1].split(")")[0]
    rs = {r["id"]: r for r in http.get(f"/api/bots/{bid}/routines", headers=H).json()}
    ok(rs[rid_scoop]["model"] is None and rs[rid]["model"] == "claude-sonnet-5-5", "Routine speichert Modell (null = wie Scoop)")

    FakeEngine.calls.clear()
    http.post(f"/api/routines/{rid}/run", headers=H)
    wait_for(lambda: FakeEngine.calls, msg="Routinenlauf")
    idle(bid)
    ok(FakeEngine.calls[-1]["model"] == "claude-sonnet-5-5", "Routinenlauf nutzt das Modell der Routine")
    u = db.one("SELECT model FROM usage WHERE bot_id=? ORDER BY id DESC LIMIT 1", (bid,))
    ok(u["model"] == "claude-sonnet-5-5", "Kosten mit dem tatsächlich genutzten Modell gebucht")
    FakeEngine.calls.clear()
    http.post(f"/api/routines/{rid_scoop}/run", headers=H)
    wait_for(lambda: FakeEngine.calls, msg="Routinenlauf 2")
    idle(bid)
    ok(FakeEngine.calls[-1]["model"] == "claude-haiku-5-5", "„Wie Scoop“ nutzt das Modell des Scoops")

    # API: ändern, zurücksetzen, unbekannt
    r = http.patch(f"/api/routines/{rid_scoop}", headers=H, json={"model": "gpt-6-luna"})
    ok(r.status_code == 200 and r.json()["model"] == "gpt-6-luna", "PATCH setzt Modell")
    FakeEngine.calls.clear()
    http.post(f"/api/routines/{rid_scoop}/run", headers=H)
    wait_for(lambda: FakeEngine.calls, msg="Routinenlauf OpenAI")
    idle(bid)
    ok(FakeEngine.calls[-1]["model"] == "gpt-6-luna", "Claude-Scoop: Routine läuft mit OpenAI-Modell")
    ok(http.patch(f"/api/routines/{rid_scoop}", headers=H, json={"model": "gpt-99"}).status_code == 400, "unbekanntes Modell → 400")
    r = http.patch(f"/api/routines/{rid_scoop}", headers=H, json={"model": None})
    ok(r.status_code == 200 and r.json()["model"] is None, "PATCH null = wie Scoop")
    ok(http.patch("/api/routines/rt_gibtsnicht", headers=H, json={"model": "claude-opus-5-5"}).status_code == 404,
       "unbekannte Routine → 404")

    # Werkzeug routine_aendern
    out = tools(bid)["routine_aendern"].handler({"id": rid, "modell": "claude-opus-5-5"})
    ok(out.startswith("Geändert") and db.one("SELECT model FROM routines WHERE id=?", (rid,))["model"] == "claude-opus-5-5",
       "routine_aendern setzt Modell")
    tools(bid)["routine_aendern"].handler({"id": rid, "modell": "wie_scoop"})
    ok(db.one("SELECT model FROM routines WHERE id=?", (rid,))["model"] is None, "routine_aendern: wie_scoop setzt zurück")
    ok(tools(bid)["routine_aendern"].handler({"id": "rt_fremd", "modell": "claude-opus-5-5"}) == "Nicht gefunden.",
       "fremde/unbekannte Routine nicht änderbar")

    # Rückfall: Modell ohne Schlüssel
    db.q("UPDATE routines SET model='gpt-6-astra' WHERE id=?", (rid,))
    orig = bots_mod.model_available
    bots_mod.model_available = lambda m: not m.startswith("gpt-")
    try:
        FakeEngine.calls.clear()
        http.post(f"/api/routines/{rid}/run", headers=H)
        wait_for(lambda: FakeEngine.calls, msg="Routinenlauf Rückfall")
        idle(bid)
        ok(FakeEngine.calls[-1]["model"] == "claude-haiku-5-5", "Modell ohne Schlüssel → Modell des Scoops")
        out = tools(bid)["routine_anlegen"].handler({"titel": "X", "cron": "0 9 * * *", "zeitplan_text": "9:00", "auftrag": "x",
                                                     "modell": "gpt-6-astra"})
        rx = out.split("(")[1].split(")")[0]
        ok(db.one("SELECT model FROM routines WHERE id=?", (rx,))["model"] is None and "kein Schlüssel" in out,
           "Anlegen mit nicht verfügbarem Modell: wie Scoop, mit Hinweis")
    finally:
        bots_mod.model_available = orig

    # Verstärkung passt zum Routinen-Modell
    b = {"model": "claude-haiku-5-5", "escalation_model": "claude-sonnet-5-5"}
    ok(service._with_model(b, "claude-opus-5-5")["escalation_model"] is None, "Opus-Routine: keine Verstärkung nach unten")
    ok(service._with_model(b, "claude-haiku-5-5") is b, "gleiches Modell: unverändert")
    ok(service._with_model({"model": "gpt-6.1-sol", "escalation_model": "gpt-6-astra"}, "claude-haiku-5-5")["escalation_model"] is None,
       "Claude-Routine bei OpenAI-Scoop: keine OpenAI-Verstärkung")
    ok(service._with_model(b, "gpt-6-luna")["escalation_model"] == "claude-sonnet-5-5", "OpenAI-Routine: Verstärkung bleibt Schalter")
    ok(service._with_model(b, "kein-modell")["model"] == "claude-haiku-5-5", "unbekanntes Modell → Modell des Scoops")


if __name__ == "__main__":
    start_server()
    test_keys()
    bid = make_bot("Mila")
    test_generic(bid)
    test_guest(bid)
    test_kinds(bid)
    test_task_and_delete(bid)
    test_routine_model(make_bot("Rosi"))
    print(f"\nAlle {passed} Prüfungen bestanden.", flush=True)
    sys.stdout.flush()
    os._exit(0)
