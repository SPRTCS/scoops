"""Test für die Suche über alle Chats (docs/API.md „Suche und Chat-Komfort“, `suche.py`):
`GET /api/search`, Volltext-Index mit Triggern, Nachindex bestehender Datenbanken, Teilwörter, Sonderzeichen,
Gäste geteilter Scoops, Ausschnitt um eine Nachricht (`…/messages/around/…`) und Weiterladen (`?after=`).

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, Fake-Engine ohne KI-Aufruf) – niemals die Produktion.

    cd Server && uv run python tests/test_suche.py
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

TMP = Path(tempfile.mkdtemp(prefix="aisbot-suche-test-"))
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

from aisbot import server, suche  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402
from aisbot.sharing import Principal, Share  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db, service = server.db, server.service
BASE = f"http://127.0.0.1:{PORT}"
H = {"Authorization": f"Bearer {TOKEN}"}
G = {"Authorization": f"Bearer {GUEST_TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=20)
passed = 0
MASCOT = {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"}

# Gast ohne Fake-Convex: eigenes Token → Gast-Prinzipal; der Share steht direkt im Cache
_principal_of = server.principal_of
server.principal_of = lambda given: Principal("guest", "u_lea", "s_lea") if given == GUEST_TOKEN else _principal_of(given)


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


def fake_run(**kw):
    u = SimpleNamespace(dollars=0.0, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
    return Outcome("Antwort vom Scoop", "end_turn", SimpleNamespace(by_model={kw["model"]: u}, dollars=0.0), [], False,
                   kw["model"], 1)


service.engine.run = fake_run
service.openai_engine.run = fake_run


def settle() -> None:
    time.sleep(0.1)
    wait_for(lambda: not service.runs, 10, "Läufe beendet")


def post(path: str, **body) -> dict:
    r = http.post(path, headers=H, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def find(q: str, headers=H, **params) -> dict:
    r = http.get("/api/search", headers=headers, params={"q": q, **params})
    assert r.status_code == 200, f"{q!r}: {r.status_code} {r.text}"
    return r.json()


def ids(res: dict) -> list[str]:
    return [h["message_id"] for h in res["hits"]]


def marked(hit: dict) -> list[str]:
    return [hit["snippet"][a:b] for a, b in hit["marks"]]


def main() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}, Index: {suche.mode(db)}")

    mila = post("/api/bots", name="Mila", mascot=MASCOT)["id"]
    lio = post("/api/bots", name="Lio", mascot=MASCOT)["id"]
    settle()
    g = post("/api/groups", name="Team", member_ids=[mila, lio])["id"]

    print("Fähigkeiten")
    h = http.get("/api/health", headers=H).json()
    ok(h.get("search") is True and h.get("message_edit") is True, "/api/health meldet search und message_edit")
    ok(suche.mode(db) in ("trigram", "prefix"), "Index angelegt (trigram oder Präfix-Rückfall)")
    trigram = suche.mode(db) == "trigram"

    print("Alle sichtbaren Nachrichtenarten landen im Index")
    u1 = service._add(mila, "user", "Bitte die Rechnung von Müller & Söhne prüfen")
    b1 = service._add(mila, "bot", "Die **Abrechnung** für das Büro ist fertig. Details stehen im [Bericht](https://example.org/b).")
    ev = service._add(mila, "event", "Routine angelegt: Wochenrechnung prüfen", {"icon": "clock", "prompt": "geheimer Auftragstext"})
    ap = service._add(mila, "approval", "", {"approval_id": "a_1", "title": "Mail an Jonas senden",
                                               "details": "Betreff: Rechnungskorrektur\n\nHallo Jonas …", "state": "pending"})
    st = service._add(mila, "status", "", {"run_id": "r_1", "state": "done", "lines": ["Sucht die Rechnung im Web"]})
    g1 = service._add(g, "bot", "Ich habe die Reisekostenabrechnung vorbereitet.", {"author_id": lio})
    g2 = service._add(g, "user", "Danke, die Rechnungsnummer fehlt noch")
    l1 = service._add(lio, "user", "Wann ist der Zahnarzt?")
    res = find("rechn")
    want = {u1["id"], b1["id"], ev["id"], ap["id"], g1["id"], g2["id"]} if trigram else {u1["id"], ev["id"], ap["id"], g2["id"]}
    ok(set(ids(res)) == want, f"„rechn“ findet Nutzer-, Scoop-, Ereignis-, Freigabe- und Gruppennachrichten ({len(want)})")
    ok(st["id"] not in ids(res), "Statuszeilen (Arbeitsschritte) werden nicht durchsucht")
    ok(ids(res) == sorted(ids(res), key=lambda i: -db.one("SELECT seq FROM messages WHERE id=?", (i,))["seq"]),
       "Treffer neueste zuerst")
    hit = next(x for x in res["hits"] if x["message_id"] == u1["id"])
    ok(hit["chat_id"] == mila and hit["chat_kind"] == "bot" and hit["chat_name"] == "Mila" and hit["role"] == "user"
       and hit["author_name"] == "Arman" and hit["created_at"], "Treffer nennt Chat, Rolle, Absender und Zeit")
    ok(marked(hit) == ["Rechn"] and "Müller & Söhne" in hit["snippet"], "Ausschnitt mit markierter Fundstelle")
    gh = next(x for x in res["hits"] if x["message_id"] == g2["id"])
    ok(gh["chat_kind"] == "group" and gh["chat_name"] == "Team", "Gruppentreffer nennt die Gruppe")
    if trigram:
        gb = next(x for x in res["hits"] if x["message_id"] == g1["id"])
        ok(gb["author_id"] == lio and gb["author_name"] == "Lio" and marked(gb) == ["rechn"],
           "Teilwort mitten im Wort („Reisekostenabrechnung“), Autor in der Gruppe")
        bh = next(x for x in res["hits"] if x["message_id"] == b1["id"])
        ok("**" not in bh["snippet"] and "https://" not in bh["snippet"], "Ausschnitt ohne Markdown")
    aph = next(x for x in res["hits"] if x["message_id"] == ap["id"])
    ok(aph["role"] == "approval" and "Rechnungskorrektur" in aph["snippet"], "Freigabe-Karte: Titel und Details durchsuchbar")
    ok(not find("geheimer Auftragstext")["hits"], "interner Auftrag eines Ereignisses (meta.prompt) ist nicht im Index")

    print("Schreibweise, mehrere Wörter, kurze Wörter")
    ok(u1["id"] in ids(find("RECHNUNG")) and u1["id"] in ids(find("rechnung müller")), "Groß-/Kleinschreibung egal, Wörter mit UND")
    ok(u1["id"] in ids(find("muller")) and b1["id"] in ids(find("buro")), "Akzente/Umlaute egal („buro“ findet „Büro“)")
    ok(not find("rechnung zahnarzt")["hits"], "alle Wörter müssen in derselben Nachricht stehen")
    ok(l1["id"] in ids(find("zahn")), "Wortanfang findet das Wort")
    ok(not find("x")["hits"] and not find("")["hits"] and not find("   ")["hits"], "leere und einbuchstabige Suche: nichts")
    r2 = find("in")
    ok(isinstance(r2["hits"], list), "zwei Buchstaben: Antwort ohne Fehler")
    if trigram:
        ok(u1["id"] in ids(find("die rechn")) and b1["id"] not in ids(find("im xy")), "kurze Wörter zählen mit (Nachprüfung)")

    print("Sonderzeichen lösen keinen FTS-Fehler aus")
    for q in ['"', '""', "rechn*", "(rechnung", "rechnung)", "AND", "OR NOT", "NEAR(a b)", "a:b", "-rechnung", "^rechnung",
              "müller & söhne", "100%", "c++ {x}", "'; DROP TABLE messages; --", "\\", "rechnung OR", "text:rechnung", "*", "+ - ~",
              "\x00abc", "😀 rechn", "a" * 500]:
        r = http.get("/api/search", headers=H, params={"q": q})
        if r.status_code != 200 or "hits" not in r.json():
            raise AssertionError(f"Suche nach {q!r}: {r.status_code} {r.text[:200]}")
    ok(True, "23 Eingaben mit Sonderzeichen → 200, keine Fehler")
    ok(u1["id"] in ids(find("müller & söhne")) and u1["id"] in ids(find('"Rechnung"')), "Sonderzeichen in der Eingabe stören den Treffer nicht")
    ok(db.one("SELECT COUNT(*) n FROM messages")["n"] > 0, "Tabelle messages unversehrt")

    print("Eingrenzen und Blättern")
    only = find("rechn", chat=g)
    ok(set(ids(only)) == ({g1["id"], g2["id"]} if trigram else {g2["id"]}) and only["total"] == len(only["hits"]),
       "chat=<Gruppe>: nur Treffer dieses Chats, mit Gesamtzahl")
    ok(http.get("/api/search", headers=H, params={"q": "rechn", "chat": "b_gibtsnicht"}).status_code == 404, "unbekannter Chat → 404")
    one = find("rechn", limit=1)
    ok(len(one["hits"]) == 1 and one["truncated"] and one["total"] == len(want), "limit=1: ein Treffer, truncated, total stimmt")
    nxt = find("rechn", limit=1, before=one["hits"][0]["message_id"])
    ok(len(nxt["hits"]) == 1 and nxt["hits"][0]["message_id"] != one["hits"][0]["message_id"], "before=<id> blättert weiter")
    for i in range(30):
        service._add(lio, "user", f"Stichwort Quarkbällchen Nummer {i}")
    ok(len(find("quark")["hits"]) == 30 and len(find("quark", limit=500)["hits"]) == 30 and len(find("quark", limit=5)["hits"]) == 5,
       "Standard 30 Treffer, limit begrenzt")

    print("Index bleibt aktuell (Ändern, Löschen, Zurücksetzen)")
    db.update_message(u1["id"], text="Bitte die Quittung von Müller prüfen")
    ok(u1["id"] not in ids(find("rechn")) and u1["id"] in ids(find("quittung")), "geänderter Text: alter Begriff weg, neuer da")
    meta = dict(ap["meta"], state="approved", details="Betreff: Liefertermin")
    db.update_message(ap["id"], meta=meta)
    ok(ap["id"] not in ids(find("rechnungskorrektur")) and ap["id"] in ids(find("liefertermin")), "geänderte Freigabe-Karte neu im Index")
    n_before = db.one("SELECT COUNT(*) n FROM message_fts")["n"]
    service.set_reaction(b1["id"], "user", "👍")
    ok(db.one("SELECT COUNT(*) n FROM message_fts")["n"] == n_before and b1["id"] in ids(find("büro")), "Reaktion ändert den Index nicht")
    ok(http.post(f"/api/groups/{g}/reset", headers=H).status_code == 200 and not find("rechn", chat=g)["hits"],
       "Gruppe zurücksetzen entfernt ihre Treffer")
    tmp = post("/api/bots", name="Kurz", mascot=MASCOT)["id"]
    settle()
    service._add(tmp, "user", "Einmalwort Zitronenfalter")
    ok(len(find("zitronenfalter")["hits"]) == 1, "neuer Scoop: Nachricht sofort gefunden")
    http.delete(f"/api/bots/{tmp}", headers=H)
    ok(not find("zitronenfalter")["hits"], "Scoop löschen entfernt seine Treffer")
    ok(db.one("SELECT COUNT(*) n FROM message_fts")["n"]
       == db.one("SELECT COUNT(*) n FROM messages WHERE role IN ('user','bot','event','approval')")["n"], "Index und Nachrichten gleich groß")

    print("Bestehende Datenbanken: einmaliger Nachindex")
    total = db.one("SELECT COUNT(*) n FROM message_fts")["n"]
    for t in ("message_fts_ai", "message_fts_au", "message_fts_ad"):
        db.q(f"DROP TRIGGER {t}")
    db.q("DROP TABLE message_fts")
    db.q("DELETE FROM settings WHERE key='message_fts_version'")
    old = db.add_message(mila, "bot", "Nachricht aus der Zeit vor dem Index: Pfefferminztee")  # ohne Trigger, wie früher
    kind = suche.ensure(db)
    ok(kind == suche.mode(db) and db.one("SELECT COUNT(*) n FROM message_fts")["n"] == total + 1, "Index aus vorhandenen Nachrichten aufgebaut")
    ok(old["id"] in ids(find("pfefferminz")) and b1["id"] in ids(find("büro")), "alte Nachrichten sind auffindbar")
    db.q("DELETE FROM message_fts WHERE rowid=(SELECT seq FROM messages WHERE id=?)", (old["id"],))
    suche.ensure(db)
    ok(old["id"] in ids(find("pfefferminz")), "fehlende Zeilen (z. B. nach Sicherung) → Neuaufbau beim Start")
    again = service._add(mila, "user", "Nach dem Neuaufbau: Kamillentee")
    ok(again["id"] in ids(find("kamillen")), "Trigger greifen nach dem Neuaufbau")
    db.set_setting("message_fts_version", "0:json:trigram")
    suche.ensure(db)
    ok(db.setting("message_fts_version").startswith(f"{suche.VERSION}:") and again["id"] in ids(find("kamillen")),
       "andere Index-Fassung → Neuaufbau")

    print("Ausschnitt um eine Nachricht und Weiterladen")
    seq = [service._add(lio, "user" if i % 2 == 0 else "bot", f"Verlauf Zeile {i}") for i in range(80)]
    mid = seq[40]["id"]
    a = http.get(f"/api/chats/{lio}/messages/around/{mid}", headers=H, params={"before": 10, "after": 10}).json()
    got = [m["id"] for m in a["messages"]]
    ok(got == [m["id"] for m in seq[30:51]] and a["has_older"] and a["has_newer"], "around: 10 davor, Treffer, 10 danach, beide Richtungen offen")
    a = http.get(f"/api/chats/{lio}/messages/around/{seq[-2]['id']}", headers=H, params={"before": 5, "after": 25}).json()
    ok(a["messages"][-1]["id"] == seq[-1]["id"] and not a["has_newer"] and a["has_older"], "around am Ende: has_newer false")
    ok(http.get(f"/api/chats/{mila}/messages/around/{mid}", headers=H).status_code == 404, "Nachricht aus anderem Chat → 404")
    nx = http.get(f"/api/bots/{lio}/messages", headers=H, params={"after": seq[50]["id"], "limit": 10}).json()
    ok([m["id"] for m in nx] == [m["id"] for m in seq[51:61]], "?after=<id>: die nächsten Nachrichten aufsteigend")
    gm = [service._add(g, "user", f"Gruppe Zeile {i}") for i in range(6)]
    nx = http.get(f"/api/groups/{g}/messages", headers=H, params={"after": gm[1]["id"], "limit": 3}).json()
    ok([m["id"] for m in nx] == [m["id"] for m in gm[2:5]], "?after= auch in Gruppen")
    a = http.get(f"/api/chats/{g}/messages/around/{gm[3]['id']}", headers=H).json()
    ok(gm[3]["id"] in [m["id"] for m in a["messages"]], "around auch in Gruppen")
    plain = http.get(f"/api/bots/{lio}/messages", headers=H, params={"limit": 5}).json()
    ok([m["id"] for m in plain] == [m["id"] for m in seq[-5:]], "ohne after/before unverändert: die jüngsten Nachrichten")

    print("Gäste geteilter Scoops")
    server.shares.shares = [Share("sh_1", mila, "u_lea", "Lea", "read", "none")]
    secret = service._add(lio, "user", "Streng privat: Gartenzwerg im Tresor")
    shared_msg = service._add(mila, "bot", "Der Gartenzwerg steht jetzt im Flur.")
    gap = service._add(mila, "approval", "", {"approval_id": "a_2", "title": "Gartenzwerg bestellen",
                                               "details": "Bestellung über 49 €", "state": "pending"})
    own = find("gartenzwerg")
    ok({secret["id"], shared_msg["id"], gap["id"]} <= set(ids(own)), "Admin findet alles")
    guest = find("gartenzwerg", headers=G)
    ok(ids(guest) == [shared_msg["id"]], "Gast findet nur die Nachricht im geteilten Scoop – nicht den privaten Chat, nicht die Freigabe")
    ok(guest["total"] == 1, "Gast: auch die Gesamtzahl verrät nichts")
    ok(not find("bestellung", headers=G)["hits"] and not find("zahnarzt", headers=G)["hits"], "Gast: Freigabe-Details und andere Chats nie")
    ok(http.get("/api/search", headers=G, params={"q": "gartenzwerg", "chat": lio}).status_code == 403, "Gast: chat=<nicht geteilt> → 403")
    ok(http.get("/api/search", headers=G, params={"q": "gruppe", "chat": g}).status_code == 403, "Gast: Gruppen → 403")
    ok(ids(find("gartenzwerg", headers=G, chat=mila)) == [shared_msg["id"]], "Gast: chat=<geteilt> geht")
    ok(not find("gruppe zeile", headers=G)["hits"], "Gast: keine Gruppentreffer")
    r = http.get(f"/api/chats/{mila}/messages/around/{gap['id']}", headers=G)
    card = next(m for m in r.json()["messages"] if m["id"] == gap["id"])
    ok(r.status_code == 200 and card["meta"].get("guest_view") and "Bestellung" not in json.dumps(card, ensure_ascii=False),
       "Gast: around liefert die Gast-Ansicht (Freigabe ohne Inhalt)")
    ok(http.get(f"/api/chats/{lio}/messages/around/{secret['id']}", headers=G).status_code == 403, "Gast: around im fremden Chat → 403")
    ok(http.get(f"/api/bots/{lio}/messages", headers=G, params={"after": seq[0]["id"]}).status_code == 403, "Gast: ?after= im fremden Chat → 403")
    me = http.get("/api/shared/me", headers=G).json()
    ok(me.get("search") is True and me.get("message_edit") is True, "/api/shared/me meldet die Fähigkeiten auch Gästen")
    server.shares.shares = []
    ok(http.get("/api/search", headers=G, params={"q": "gartenzwerg"}).status_code == 403, "ohne Share → 403")
    ok(http.get("/api/search", params={"q": "gartenzwerg"}).status_code == 401, "ohne Anmeldung → 401")

    print("Rückfall ohne Trigram-Tokenizer (ältere SQLite-Versionen)")
    tokenizers = suche._TOKENIZERS
    suche._TOKENIZERS = tokenizers[-1:]
    db.set_setting("message_fts_version", "alt")
    ok(suche.ensure(db) == "prefix", "Index mit Wortanfängen statt Trigrammen")
    r1 = service._add(mila, "user", "Die Rechnung ist da")
    ok(r1["id"] in ids(find("rechn")) and r1["id"] in ids(find("RECH da")) and b1["id"] in ids(find("buro")),
       "Präfix-Index: „rechn“ findet „Rechnung“, Groß-/Kleinschreibung und Umlaute egal")
    for q in ['"', "rechn*", "(a", "NEAR(a b)", "a:b", "-x", "AND"]:
        assert http.get("/api/search", headers=H, params={"q": q}).status_code == 200, q
    ok(True, "Präfix-Index: Sonderzeichen ohne Fehler")
    suche._TOKENIZERS = tokenizers
    db.set_setting("message_fts_version", "alt")
    ok(suche.ensure(db) == ("trigram" if trigram else "prefix"), "zurück auf den Standard-Index")

    print("Bausteine")
    s, m = suche.snippet("Ein sehr langer Text. " * 20 + "Hier steht die Abrechnung für März. " + "Und noch mehr Text. " * 20, ["abrechn"])
    ok(s.startswith("…") and s.endswith("…") and len(s) <= suche.SNIPPET_LEN + 2 and [s[a:b] for a, b in m] == ["Abrechn"],
       "langer Text: Ausschnitt um die Fundstelle, vorn und hinten gekürzt")
    s, m = suche.snippet("Größe ändern: ÄNDERN geht", ["andern"])
    ok([s[a:b] for a, b in m] == ["ändern", "ÄNDERN"], "Markierung trifft das Original trotz Umlaut und Großschreibung")
    ok(suche.tokens('  "Hallo"   WELT hallo ') == ["hallo", "welt"], "Suchwörter: gefaltet, ohne Anführungszeichen, ohne Dopplung")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil

        shutil.rmtree(TMP, ignore_errors=True)
