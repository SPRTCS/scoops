"""Test für Scoop-Vorlagen (docs/vorlagen.md): Export ohne Privates, strenge Prüfung beim Import, alles oder nichts,
Standardrechte, pausierte Routinen, neuere Formatversion, Beispielvorlagen aus docs/vorlagen/.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, Edition standard) – niemals die
laufende Produktion. Kein Netz, keine Schlüssel; Läufe übernimmt eine Fake-Engine (sie darf beim Import nie anspringen).

    cd Server && uv run python tests/test_vorlagen.py
"""

from __future__ import annotations

import base64
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

TMP = Path(tempfile.mkdtemp(prefix="aisbot-vorlagen-test-"))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT = free_port()
PREFIX = "ais-scoops-vorlagentest-" + os.urandom(3).hex()
API_TOKEN = "test-token-" + os.urandom(6).hex()
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION=os.environ.get("AISBOT_TEST_EDITION", "standard"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_KEYCHAIN_PREFIX=PREFIX, AISBOT_CLOUD_KEYCHAIN=PREFIX + "-cloud",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from PIL import Image  # noqa: E402

from aisbot import avatars, profile, server, vorlagen  # noqa: E402
from aisbot.bots import load_config, save_config  # noqa: E402
from aisbot.engine import Outcome  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
assert profile.kc("apns").startswith(PREFIX), "Test darf nie echte Schlüssel lesen"
BASE = f"http://127.0.0.1:{PORT}"
http = httpx.Client(base_url=BASE, timeout=20)
db, service = server.db, server.service
EXAMPLES = ROOT.parent / "docs" / "vorlagen"
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def wait_for(fn, timeout=10.0, msg="Bedingung"):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"Zeitüberschreitung: {msg}")


class FakeEngine:
    calls = 0

    @classmethod
    def run(cls, **kw):
        cls.calls += 1
        u = SimpleNamespace(dollars=0.001, input_tokens=1, output_tokens=1, cache_read_tokens=0, cache_write_tokens=0)
        return Outcome("Hallo", "end_turn", SimpleNamespace(by_model={kw["model"]: u}, dollars=0.001), [], False, kw["model"], 1)


service.engine.run = FakeEngine.run
service.openai_engine.run = FakeEngine.run


def api(method: str, path: str, **kw) -> httpx.Response:
    headers = {"Authorization": f"Bearer {API_TOKEN}", **kw.pop("headers", {})}
    return http.request(method, path, headers=headers, **kw)


def png(size=(640, 480), color=(200, 40, 90)) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", size, color).save(out, "PNG")
    return out.getvalue()


def base(**over) -> dict:
    t = {"format": 1, "type": "ais-scoops-template", "name": "Vera", "label": "Vertrieb",
         "appearance": {"shape": "heart", "color": "#ff5fa8", "eyes": "cat", "accessory": "tie"},
         "character": "freundlich und knapp",
         "skills": [{"name": "Angebot schreiben", "description": "kurz", "steps": "1. Fragen\n2. Schreiben"}],
         "routines": [{"title": "Morgens", "schedule": "30 7 * * 1-5", "schedule_text": "Einmal im Jahr", "prompt": "Briefing"},
                      {"title": "Oft", "schedule": "*/5 * * * *", "prompt": "Prüfen"}],
         "requires": [{"kind": "app", "id": "gmail", "name": "Gmail", "note": "Mails"}]}
    t.update(over)
    return t


def counts() -> tuple[int, int, int]:
    return (db.one("SELECT COUNT(*) n FROM bots")["n"], db.one("SELECT COUNT(*) n FROM skills")["n"],
            db.one("SELECT COUNT(*) n FROM routines")["n"])


# -- Teil 1: Export ---------------------------------------------------------------------------------------
def part_export() -> str:
    print("Export: nur, was in eine Vorlage gehört")
    cfg = load_config()
    cfg.update(api_token=API_TOKEN, user_name="Arman", owner_name="Arman Beispiel")
    save_config(cfg)
    server.TOKEN = API_TOKEN
    bid = service.create_bot({"name": "Mila", "label": "Assistenz", "character":
                              "locker, präzise, duzt. Liest morgens Gmail und den Google Kalender von Arman. "
                              "Rückfragen an arman@beispiel.example oder +49 30 1234567.",
                              "mascot": {"shape": "bean", "color": "#7C5CFF", "eyes": "lashes", "accessory": "glasses",
                                         "gaze": "left"}})["id"]
    wait_for(lambda: not service.runs, 10, "Vorstellungs-Lauf fertig")
    db.save_skill(bid, "Mails sortieren", "nach Wichtigkeit", "1. Posteingang öffnen\n2. Sortieren")
    db.save_skill(None, "Höflich absagen", "für alle Scoops", "1. Danken\n2. Absagen")
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at,model) "
         "VALUES('rt_a',?,'routine','Morgenbriefing','30 7 * * 1-5','Werktags 7:30','Fasse Mails zusammen',1,"
         "'2099-01-01T07:30:00+01:00',datetime('now'),'claude-haiku-5-5')", (bid,))
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at) "
         "VALUES('rt_b',?,'erinnerung','GEHEIM-ERINNERUNG Zahnarzt','2099-01-01T09:00:00+01:00','','GEHEIM-ERINNERUNG',1,"
         "'2099-01-01T09:00:00+01:00',datetime('now'))", (bid,))
    # Alles, was nie in eine Vorlage darf
    db.add_memory(bid, "profil", "GEHEIM-GEDAECHTNIS: Arman mag Tee")
    db.add_memory(None, "fakt", "GEHEIM-FAKT für alle")
    db.add_message(bid, "user", "GEHEIM-VERLAUF Hallo", {})
    db.add_file(bid, None, "GEHEIM-DATEI.txt", b"GEHEIM-INHALT", "text/plain")
    db.q("INSERT INTO vault(id,title,url,domain,username,created_at,updated_at) VALUES('v_1','GEHEIM-TRESOR','https://x.example',"
         "'x.example','GEHEIM-NUTZER',datetime('now'),datetime('now'))")
    service.add_standing(bid, "teamapp-geheim", "GEHEIM-DAUERFREIGABE")
    db.set_access(bid, {"mode": "full", "scope": "home", "folders": ["~/GEHEIM-ORDNER"]})
    db.set_sharing(bid, {"guest_tools": {"computer": True}, "guest_budget": 77})
    r = api("GET", f"/api/bots/{bid}/template")
    ok(r.status_code == 200, "GET /api/bots/{id}/template")
    data = r.json()
    t = data["template"]
    ok(t["format"] == 1 and t["type"] == "ais-scoops-template" and t["name"] == "Mila" and t["label"] == "Assistenz",
       "Format 1, Typ, Name und Rolle")
    ok(t["appearance"] == {"shape": "bean", "color": "#7C5CFF", "eyes": "lashes", "accessory": "glasses", "gaze": "left"},
       "Aussehen ohne Bild")
    ok(t["character"].startswith("locker, präzise") and t["model"] == db.bot_row(bid)["model"], "Charakter und bevorzugtes Modell")
    ok(t["skills"] == [{"name": "Mails sortieren", "description": "nach Wichtigkeit", "steps": "1. Posteingang öffnen\n2. Sortieren"}],
       "eigene Fähigkeiten")
    ok(data["optional"]["skills"] == [{"name": "Höflich absagen", "description": "für alle Scoops", "steps": "1. Danken\n2. Absagen"}],
       "Fähigkeiten für alle Scoops nur auf Wunsch (optional)")
    ok(t["routines"] == [{"title": "Morgenbriefing", "schedule": "30 7 * * 1-5", "schedule_text": "Werktags um 7:30",
                          "prompt": "Fasse Mails zusammen", "model": "claude-haiku-5-5"}], "Routinen mit Zeitplan, Auftrag, Modell – ohne Erinnerungen")
    ok({(q["kind"], q["id"]) for q in t["requires"]} == {("app", "gmail"), ("app", "googlecalendar")},
       "benötigte Verbindungen aus den Texten erkannt (Gmail, Google Kalender)")
    dump = json.dumps(data, ensure_ascii=False)
    ok("GEHEIM" not in dump, "kein Gedächtnis, Verlauf, Tresor, keine Dateien, Dauerfreigaben, Erinnerungen")
    ok(not {"computer_access", "guest_tools", "guest_budget", "shared", "memories", "standing", "usage", "pinned", "section",
            "primary", "computer_node", "id", "created_at"} & set(t), "keine Rechte, Teilen-Daten, Nutzung oder Kennungen")
    w = " ".join(x["text"] for x in data["warnings"])
    ok("Arman" in w and "Mailadresse" in w and "Telefonnummer" in w and data["warnings"][0]["where"] == "Charakter und Anweisungen",
       "Hinweise auf Persönliches (Name, Mailadresse, Telefonnummer) mit Stelle")
    ok(data["optional"]["photo"] is None and data["file_name"] == "Mila.scoop", "ohne eigenes Bild kein Foto; Dateiname")
    ok(vorlagen.validate(t)["name"] == "Mila", "der Export besteht die eigene Prüfung")

    print("Bild nur auf Wunsch")
    ok(api("PUT", f"/api/bots/{bid}/avatar", content=png(), headers={"content-type": "image/png",
                                                                        "Authorization": f"Bearer {API_TOKEN}"}).status_code == 200,
       "eigenes Bild hochgeladen")
    data = api("GET", f"/api/bots/{bid}/template").json()
    ph = data["optional"]["photo"]
    img = Image.open(io.BytesIO(base64.b64decode(ph["data"])))
    ok("photo" not in data["template"]["appearance"] and ph["mime"] == "image/jpeg" and img.size == (256, 256),
       "Bild steht unter optional (256 px), nicht in der Vorlage")
    ok(api("GET", "/api/bots/b_gibtsnicht/template").status_code == 404, "unbekannter Scoop → 404")
    ok(http.get(f"/api/bots/{bid}/template").status_code == 401, "ohne Anmeldung → 401")
    return bid


# -- Teil 2: Prüfen ---------------------------------------------------------------------------------------
def part_validate() -> None:
    print("Strenge Prüfung")

    def bad(t, needle: str, status: int = 400, what: str = "") -> None:
        r = api("POST", "/api/templates/check", json=t)
        ok(r.status_code == status and needle in r.json()["error"], f"{what or needle} → {status}")

    before = counts()
    bad(base(format=2), "neueren Version von AIS Scoops", what="neuere Formatversion mit verständlicher Meldung")
    bad(base(format=99), "Format 99", what="Formatnummer steht in der Meldung")
    bad({"format": 1, "name": "X"}, "keine Scoop-Vorlage", what="ohne Typ")
    bad(base(format="1"), "keine Scoop-Vorlage", what="Format als Text")
    bad(base(format=True), "keine Scoop-Vorlage", what="Format als Wahrheitswert")
    bad(base(format=0), "keine Scoop-Vorlage", what="Format 0")
    bad([1, 2], "keine Scoop-Vorlage", what="Liste statt Objekt")
    r = api("POST", "/api/templates/check", content=b"kein json", headers={"content-type": "application/json",
                                                                             "Authorization": f"Bearer {API_TOKEN}"})
    ok(r.status_code == 400 and "keine Scoop-Vorlage" in r.json()["error"], "kein JSON → 400")
    bad(base(name=""), "Der Name fehlt")
    bad(base(name="x" * 41), "höchstens 40 Zeichen", what="Name zu lang")
    bad(base(name=7), "erwartet wird Text", what="Name als Zahl")
    bad(base(character="x" * 8001), "höchstens 8000 Zeichen", what="Anweisungen zu lang")
    bad(base(skills=[{"name": "a", "steps": "b"}] * 2), "doppelt", what="doppelte Fähigkeit")
    bad(base(skills=[{"name": f"s{i}", "steps": "b"} for i in range(31)]), "höchstens 30 Einträge", what="zu viele Fähigkeiten")
    bad(base(skills=[{"name": "a"}]), "die Anleitung fehlt", what="Fähigkeit ohne Anleitung")
    bad(base(skills="alle"), "erwartet wird eine Liste", what="Fähigkeiten als Text")
    bad(base(skills=["x"]), "erwartet wird ein Objekt", what="Fähigkeit als Text")
    bad(base(routines=[{"title": "t", "schedule": "jeden Tag", "prompt": "p"}]), "kein gültiger Cron-Ausdruck", what="Zeitplan in Worten")
    bad(base(routines=[{"title": "t", "schedule": "0 0 7 * * *", "prompt": "p"}]), "kein gültiger Cron-Ausdruck", what="Cron mit sechs Feldern")
    bad(base(routines=[{"title": "t", "schedule": "0 7 * * *; rm -rf ~", "prompt": "p"}]), "kein gültiger Cron-Ausdruck",
        what="Cron mit Shell-Anhang")
    bad(base(routines=[{"title": "t", "schedule": "0 7 * * *"}]), "der Auftrag fehlt", what="Routine ohne Auftrag")
    bad(base(routines=[{"title": f"r{i}", "schedule": "0 7 * * *", "prompt": "p"} for i in range(21)]), "höchstens 20 Einträge",
        what="zu viele Routinen")
    bad(base(appearance={"photo": {"mime": "image/png", "data": base64.b64encode(b"#!/bin/sh\necho hi").decode()}}),
        "Bild in der Vorlage ist nicht lesbar", what="Bild, das keins ist")
    bad(base(appearance={"photo": {"mime": "image/png", "data": "kein base64 !!!"}}), "nicht lesbar", what="kaputtes Base64")
    bad(base(appearance={"photo": {"mime": "image/png", "data": "A" * 600_001}}), "zu groß", 413, what="Bild zu groß")
    r = api("POST", "/api/templates/check", json=base(character="x" * 7000, description="y" * 500, skills=[
        {"name": f"s{i}", "steps": "z" * 6000, "description": ""} for i in range(30)], routines=[
        {"title": f"r{i}", "schedule": "0 7 * * *", "prompt": "p" * 4000} for i in range(20)]))
    ok(r.status_code == 200, "alles an der Obergrenze, aber gültig → 200")
    r = http.post("/api/templates/check", content=b"{" + b" " * 1_600_000 + b"}",
                  headers={"Authorization": f"Bearer {API_TOKEN}", "content-type": "application/json"})
    ok(r.status_code == 413, "Datei über 1,5 MB → 413")
    ok(http.post("/api/templates/check", json=base()).status_code == 401, "ohne Anmeldung → 401")
    ok(counts() == before, "Prüfen legt nichts an")

    print("Unbekanntes fällt weg, Werte werden normalisiert")
    t = base(computer_access={"mode": "full", "scope": "home"}, guest_tools={"computer": True}, memories=[{"text": "x"}],
             standing_approvals=[{"key": "mail"}], primary=True, pinned=True, path="/etc/passwd", files=["~/.ssh/id_rsa"],
             appearance={"shape": "würfel", "color": "rot", "eyes": "laser", "accessory": "raketenrucksack", "gaze": "oben",
                         "command": "open -a Terminal"},
             character="Zeile 1\r\nZeile 2\x00\x07‮", model="../../etc/passwd",
             requires=[{"kind": "virus", "id": "../x", "name": "Etwas"}])
    out = api("POST", "/api/templates/check", json=t).json()
    n = out["template"]
    ok(set(n) == {"format", "type", "name", "label", "description", "appearance", "character", "model", "skills", "routines",
                  "requires"}, "nur bekannte Felder kommen zurück (keine Rechte, Pfade, Gedächtnis-Einträge)")
    ok(n["appearance"] == {"shape": "bean", "color": "#7C5CFF", "eyes": "dots", "accessory": "none"},
       "unbekanntes Aussehen → Standard, fremde Felder weg")
    ok(n["character"] == "Zeile 1\nZeile 2" and n["model"] is None, "Steuerzeichen entfernt, ungültige Modellkennung verworfen")
    ok(n["requires"] == [{"kind": "other", "id": "", "name": "Etwas", "note": "", "status": "unknown"}],
       "unbekannte Art einer Verbindung → other/unknown")

    print("Vorschau: Zeitplan vom Server, Häufigkeit, Verbindungen, Modell")
    out = api("POST", "/api/templates/check", json={"template": base(model="claude-opus-5-5")}).json()
    r0, r1 = out["template"]["routines"]
    ok(r0["schedule_text"] == "Werktags um 7:30" and 0.7 <= r0["runs_per_day"] <= 0.72,
       "Text der Datei („Einmal im Jahr“) wird ignoriert: Werktags um 7:30, 5 Läufe pro Woche")
    ok(r1["schedule_text"] == "Alle 5 Minuten" and r1["runs_per_day"] == 288, "häufige Routine: 288 Läufe pro Tag")
    ok(out["template"]["requires"][0]["status"] == "missing", "Gmail ist auf diesem Server nicht verbunden")
    ok(out["model"]["id"] == "claude-opus-5-5" and out["model"]["available"] is False and out["model"]["default"],
       "Modell der Vorlage ohne Schlüssel nicht nutzbar → Standardmodell wird genannt")
    ok(any("pausiert" in x for x in out["notes"]) and any("Standardrechten" in x for x in out["notes"]), "Hinweise für die Vorschau")
    ok(vorlagen.describe_cron("0 9 1 * *") == "Am 1. jedes Monats um 9:00" and vorlagen.describe_cron("15 8 * * 1,3") == "Mo, Mi um 8:15"
       and vorlagen.describe_cron("5 4 * 1 2") == "Zeitplan 5 4 * 1 2", "Zeitpläne in Worten, sonst der Ausdruck")


# -- Teil 3: Import ---------------------------------------------------------------------------------------
def part_import(source_bot: str) -> None:
    print("Import: Standardrechte, pausierte Routinen, kein Lauf")
    FakeEngine.calls = 0
    before = counts()
    photo = base64.b64encode(png((300, 300))).decode()
    t = base(appearance={"shape": "heart", "color": "#ff5fa8", "eyes": "cat", "accessory": "tie",
                         "photo": {"mime": "image/png", "data": photo}},
             computer_access={"mode": "full", "scope": "home"}, guest_tools={"computer": True}, primary=True, pinned=True,
             can_review=True, standing_approvals=[{"key": "mail", "label": "Mails senden"}], memories=[{"text": "x"}],
             model="modell-das-es-nicht-gibt")
    r = api("POST", "/api/templates/import", json={"template": t})
    ok(r.status_code == 200, "POST /api/templates/import")
    res = r.json()
    b = res["bot"]
    bid = b["id"]
    ok(b["name"] == "Vera" and b["label"] == "Vertrieb" and b["character"] == "freundlich und knapp", "Name, Rolle, Charakter")
    ok({k: b["mascot"][k] for k in ("shape", "color", "eyes", "accessory")} ==
       {"shape": "heart", "color": "#FF5FA8", "eyes": "cat", "accessory": "tie"}, "Aussehen übernommen")
    ok(b["avatar"] is not None and avatars.current_path(bid) is not None, "Bild neu kodiert gespeichert")
    ok(b["computer_access"]["mode"] == "auto" and b["computer_access"]["scope"] == "workspace",
       "Rechner-Zugriff: Standard (Automatisch, Nur Arbeitsordner), nicht aus der Vorlage")
    ok(b["primary"] is False and b["pinned"] is False and b["can_review"] is False and b["shared"]["count"] == 0
       and b["guest_tools"]["computer"] is False, "kein Haupt-Scoop, nicht angeheftet, keine Aufsicht, nichts geteilt")
    ok(service.standing_approvals(bid) == [] and db.memories(bid, ("profil", "tagebuch")) == [], "keine Dauerfreigaben, kein Gedächtnis")
    ok(res["model_from_template"] is False and b["model"] == db.bot_row(source_bot)["model"],
       "unbekanntes Modell → Standardmodell des Servers")
    rs = api("GET", f"/api/bots/{bid}/routines").json()
    ok(len(rs) == 2 and all(x["enabled"] is False for x in rs) and res["routines"] == 2, "Routinen pausiert angelegt")
    ok({x["title"]: x["schedule_text"] for x in rs} == {"Morgens": "Werktags um 7:30", "Oft": "Alle 5 Minuten"},
       "Zeitplan-Text vom Server")
    ok(not [x for x in service.due_routines() if x["bot_id"] == bid], "nichts davon ist fällig")
    sk = [s for s in api("GET", f"/api/bots/{bid}/skills").json() if s["bot_id"] == bid]
    ok([s["name"] for s in sk] == ["Angebot schreiben"] and res["skills"] == 1, "Fähigkeit angelegt")
    time.sleep(0.5)
    msgs = api("GET", f"/api/bots/{bid}/messages").json()
    ok(FakeEngine.calls == 0 and not service.runs and [m["role"] for m in msgs] == ["event"]
       and "aus einer Vorlage" in msgs[0]["text"] and "2 Routinen pausiert" in msgs[0]["text"],
       "kein automatischer Lauf: nur eine Ereigniszeile im Chat")
    ok(counts() == (before[0] + 1, before[1] + 1, before[2] + 2), "genau ein Scoop, eine Fähigkeit, zwei Routinen")
    r = api("PATCH", f"/api/routines/{rs[0]['id']}", json={"enabled": True}).json()
    ok(r["enabled"] is True and r["next_run"] > time.strftime("%Y-%m-%dT%H:%M:%S"), "Nutzer schaltet eine Routine ein → nächster Termin")

    print("Auswahl in der Vorschau: Name, Routinen, Fähigkeiten, Bild")
    before = counts()
    res = api("POST", "/api/templates/import", json={"template": t, "name": "  Vera Zwei ", "routines": [1], "skills": [],
                                                     "use_photo": False}).json()
    b2 = res["bot"]
    ok(b2["name"] == "Vera Zwei" and res["routines"] == 1 and res["skills"] == 0 and b2["avatar"] is None,
       "geänderter Name, nur die zweite Routine, keine Fähigkeit, ohne Bild")
    ok([x["title"] for x in api("GET", f"/api/bots/{b2['id']}/routines").json()] == ["Oft"], "abgewählte Routine fehlt")
    ok(api("POST", "/api/templates/import", json={"template": t, "name": ""}).status_code == 400, "leerer Name → 400")
    ok(api("POST", "/api/templates/import", json={"template": t, "routines": "alle"}).status_code == 400, "Auswahl als Text → 400")
    ok(api("POST", "/api/templates/import", json={"name": "X"}).status_code == 400, "ohne Vorlage → 400")
    ok(api("POST", "/api/templates/import", json={"template": base(format=3)}).status_code == 400, "neueres Format → 400")
    ok(counts() == (before[0] + 1, before[1], before[2] + 1), "abgelehnte Importe legen nichts an")

    print("Alles oder nichts")
    before = counts()
    files_before = sorted(p.name for p in avatars.AVATAR_DIR.glob("*"))
    # Fehler mitten in der Transaktion: doppelte Kennung bei der zweiten Routine
    from aisbot import db as db_mod
    real_new_id = db_mod.new_id
    seen = {"rt": 0}

    def clashing(prefix: str) -> str:
        if prefix == "rt":
            seen["rt"] += 1
            return "rt_gleich"
        return real_new_id(prefix)

    db_mod.new_id = clashing
    try:
        r = http.post("/api/templates/import", json={"template": t}, headers={"Authorization": f"Bearer {API_TOKEN}"})
    except Exception as e:  # noqa: BLE001
        r = e
    finally:
        db_mod.new_id = real_new_id
    ok(seen["rt"] == 2 and getattr(r, "status_code", 500) == 500, "Fehler mitten im Anlegen (zweite Routine)")
    ok(counts() == before, "kein halber Scoop: weder Scoop noch Fähigkeit noch Routine bleiben zurück")
    ok(sorted(p.name for p in avatars.AVATAR_DIR.glob("*")) == files_before, "auch das Bild ist wieder weg")
    ok(api("GET", "/api/bots").status_code == 200 and api("POST", "/api/templates/import", json={"template": base()}).status_code == 200,
       "die Datenbank arbeitet danach normal weiter")

    print("Hin und zurück: Export eines Scoops wieder importieren")
    data = api("GET", f"/api/bots/{source_bot}/template").json()
    tpl = dict(data["template"])
    tpl["appearance"] = {**tpl["appearance"], "photo": data["optional"]["photo"]}
    tpl["skills"] = tpl["skills"] + data["optional"]["skills"]
    res = api("POST", "/api/templates/import", json={"template": tpl, "name": "Mila Kopie"})
    ok(res.status_code == 200 and res.json()["bot"]["avatar"] is not None and res.json()["skills"] == 2
       and res.json()["routines"] == 1, "Export mit Bild und allen Fähigkeiten lässt sich importieren")
    copy = res.json()["bot"]["id"]
    ok(db.memories(copy) == [m for m in db.memories(copy) if m["bot_id"] is None] and service.standing_approvals(copy) == []
       and api("GET", f"/api/bots/{copy}/messages").json()[0]["role"] == "event",
       "die Kopie hat kein eigenes Gedächtnis, keine Dauerfreigaben und keinen Verlauf")

    print("Beispielvorlagen aus docs/vorlagen/")
    files = sorted(EXAMPLES.glob("*.scoop"))
    ok(len(files) >= 3, f"{len(files)} Beispielvorlagen gefunden")
    for f in files:
        raw = f.read_bytes()
        t = json.loads(raw)
        chk = api("POST", "/api/templates/check", content=raw, headers={"content-type": "application/json",
                                                                        "Authorization": f"Bearer {API_TOKEN}"})
        ok(chk.status_code == 200 and chk.json()["template"]["name"] == t["name"], f"{f.name}: Prüfung besteht")
        ok(all(r["schedule_text"] == o.get("schedule_text") for r, o in zip(chk.json()["template"]["routines"], t["routines"])),
           f"{f.name}: Zeitplan-Texte der Datei stimmen mit dem Server überein")
        dump = raw.decode()
        ok("@" not in dump and "Arman" not in dump, f"{f.name}: keine Mailadressen, kein Name des Besitzers")
        res = api("POST", "/api/templates/import", json={"template": t})
        ok(res.status_code == 200 and res.json()["routines"] == len(t["routines"]) and res.json()["skills"] == len(t["skills"]),
           f"{f.name}: Import legt {len(t['skills'])} Fähigkeit(en) und {len(t['routines'])} Routine(n) an")
    ok(FakeEngine.calls == 0, "bei keinem Import ist ein Lauf gestartet")


def main() -> None:
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="critical"))
    threading.Thread(target=srv.run, daemon=True).start()
    wait_for(lambda: srv.started, 15, "Server startet")
    print(f"Testinstanz auf {BASE}, Daten in {TMP}, Edition {profile.edition()}")
    bid = part_export()
    part_validate()
    part_import(bid)
    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil

        shutil.rmtree(TMP, ignore_errors=True)
