"""Test des Modellkatalogs (docs/modelle.md): gebündelter Katalog, strenge Prüfung, Fernkopie mit Rückfall,
Zwischenspeicher, Abbildung abgelöster Kennungen (Datenbank, API-Eingaben, Kosten) und GET /api/models.

Eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, eigener Schlüsselbund-Präfix, keine Fernkopie aus dem Netz).

    cd Server && AISBOT_SKIP_CONVEX=1 .venv/bin/python tests/test_models_catalog.py
"""

from __future__ import annotations

import copy
import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-models-test-"))
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    PORT = s.getsockname()[1]
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_OFFLINE="1", AISBOT_PORT=str(PORT), AISBOT_MODELS_URL="",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-test-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from aisbot import config, models_catalog as mc  # noqa: E402

passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def bundled_raw() -> dict:
    return json.loads(mc.BUNDLED.read_text(encoding="utf-8"))


def rejects(data, part: str, msg: str, require=None) -> None:
    try:
        mc.validate(data, require=require)
    except mc.CatalogError as e:
        ok(part in str(e), f"{msg} ({e})")
        return
    raise AssertionError(f"{msg}: wurde angenommen")


def test_bundled() -> None:
    print("Gebündelter Katalog")
    c = mc.bundled()
    ok(c.ids == ("claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2",
                 "gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol", "gpt-6.2-astra"), f"wählbar, nach Anbieter und Rang: {c.ids}")
    ok(c.label("claude-fable-5-2") == "Fable 5.2" and c.label("gpt-6.2-astra") == "GPT-6.2 Astra", "Anzeigenamen")
    ok(c.replaced == {"gpt-6.1-sol": "gpt-6.2-sol", "gpt-6-astra": "gpt-6.2-astra"}, "Ablösungen")
    ok(list(config.MODELS) == list(c.ids) and "claude-fable-5-2" in config.MODELS and "gpt-6.1-sol" not in config.MODELS,
       "config.MODELS folgt dem Katalog")
    ok(config.resolve_model("gpt-6.1-sol") == "gpt-6.2-sol" and config.resolve_model("gpt-6-astra") == "gpt-6.2-astra"
       and config.resolve_model("claude-haiku-5-5") == "claude-haiku-5-5" and config.resolve_model("x-neu") == "x-neu",
       "resolve_model: alt → neu, Rest unverändert")
    ok(config.MODEL_RANK["claude-fable-5-2"] > config.MODEL_RANK["claude-opus-5-5"] > config.MODEL_RANK["claude-sonnet-5-5"],
       "Rang: Fable > Opus > Sonnet")
    ok(config.MODEL_RANK["gpt-6.1-sol"] == config.MODEL_RANK["gpt-6.2-sol"], "abgelöste Kennung hat den Rang des Nachfolgers")
    from aisbot.engine_openai import ESCALATE, OPENAI_MODELS, is_openai
    ok(dict(ESCALATE) == {"gpt-6-luna": "gpt-6.1-terra", "gpt-6.1-terra": "gpt-6.2-sol", "gpt-6.2-sol": "gpt-6.2-astra",
                          "gpt-6.1-sol": "gpt-6.2-astra"}, f"OpenAI-Verstärkung Luna → Terra → Sol → Astra: {dict(ESCALATE)}")
    ok("gpt-6.2-sol" in OPENAI_MODELS and is_openai("gpt-6-astra"), "OPENAI_MODELS aus dem Katalog")
    from aisbot.engine import FALLBACK_MODELS, WEB_NEW_MODELS
    ok("claude-fable-5-2" in FALLBACK_MODELS and "claude-fable-5-2" in WEB_NEW_MODELS
       and "claude-haiku-5-5" not in WEB_NEW_MODELS, "Fable: Ausweichen und neue Web-Werkzeuge; Haiku: Basis")
    p = config.PRICES
    ok(p["gpt-6.2-sol"].input == 2 and p["gpt-6.2-sol"].cache_read == 0.10 and p["gpt-6.2-sol"].output == 10,
       "Preis GPT-6.2 Sol 2 / 0,10 / 10 $")
    ok(p["gpt-6.2-astra"].input == 8 and p["gpt-6.2-astra"].cache_read == 0.40 and p["gpt-6.2-astra"].output == 40,
       "Preis GPT-6.2 Astra 8 / 0,40 / 40 $")
    ok(p["claude-fable-5-2"].input == 8 and p["claude-fable-5-2"].output == 40, "Preis Fable 5.2 8 / 40 $")
    ok(p["gpt-6-astra"].output == 50 and p["gpt-6.1-sol"].cache_read == 0.20, "alte Kennungen behalten alte Preise")
    ok(config.Usage("gpt-6-astra", 1_000_000).dollars == 10.0, "Kostenhistorie mit alter Kennung richtig bewertet")
    ok(config.price_for("gpt-7-sol")[1:] == ("gpt-6.2-sol", True), "Familienpreis für unbekannte Version")
    ok(config.price_for("claude-mythos-5-2")[1] == "claude-mythos-5-2", "Bewertung anderer Apps (nur Preis)")
    js = c.as_json()
    ok(all(not m["id"].startswith("claude-mythos") for m in js["models"]), "reine Preiseinträge nicht in der App-Liste")
    ok(any(m["id"] == "gpt-6.1-sol" and not m["selectable"] for m in js["models"]), "abgelöste Modelle in der Liste")


def test_validation() -> None:
    print("Strenge Prüfung")
    base = bundled_raw()
    ok(mc.validate(base).version == base["version"], "gebündelter Katalog gültig")

    def changed(fn) -> dict:
        d = copy.deepcopy(base)
        fn(d)
        return d

    rejects([], "JSON-Objekt", "keine Liste")
    rejects(changed(lambda d: d.update(schema=2)), "schema", "fremdes Schema")
    rejects(changed(lambda d: d.update(version="2026")), "version", "Version als Text")
    rejects(changed(lambda d: d["models"][0].update(id="o3-mini")), "claude-", "Kennung ohne claude-/gpt-")
    rejects(changed(lambda d: d["models"][0].update(id="claude-x; rm -rf")), "claude-", "Sonderzeichen in Kennung")
    rejects(changed(lambda d: d["models"][0].update(provider="openai")), "Anbieter", "Anbieter passt nicht")
    rejects(changed(lambda d: d["models"][0]["price"].update(output=0.01)), "price.output", "Ausgabe billiger als Eingabe")
    rejects(changed(lambda d: d["models"][0]["price"].update(input=5000)), "price.input", "Preis unplausibel hoch")
    rejects(changed(lambda d: d["models"][0]["price"].update(cache_read=9)), "cache_read", "Cache teurer als Eingabe")
    rejects(changed(lambda d: d["models"][0]["price"].update(input=True)), "price.input", "Wahrheitswert statt Zahl")
    rejects(changed(lambda d: d["models"][4].update(routes=["api", "claude_abo"])), "routes", "Claude-Abo für GPT")
    rejects(changed(lambda d: d["models"][0].update(label="")), "label", "leerer Anzeigename")
    rejects(changed(lambda d: d["models"].append(dict(d["models"][0]))), "doppelt", "doppelte Kennung")
    rejects(changed(lambda d: d["defaults"]["openai"].update(model="gpt-6.1-sol")), "defaults", "abgelöstes Standardmodell")
    rejects(changed(lambda d: d["defaults"]["anthropic"].update(model="gpt-6-luna")), "defaults", "Standard vom falschen Anbieter")
    rejects(changed(lambda d: [m.update(deprecated=False) for m in d["models"] if m["id"] == "gpt-6.1-sol"]), "wählbar",
            "abgelöstes Modell noch wählbar")
    rejects(changed(lambda d: d.update(models=[m for m in d["models"] if m["id"] != "claude-opus-5-5"])), "claude-opus-5-5",
            "Fernkopie darf kein bekanntes Modell still verlieren", require=mc.bundled())
    keep = changed(lambda d: [m.update(deprecated=True) for m in d["models"] if m["id"] == "gpt-6.1-terra"]
                   and d["models"].append({"id": "gpt-6.3-terra", "label": "GPT-6.3 Terra", "provider": "openai",
                                           "rank": 21, "price": {"input": 1, "output": 5}, "replaces": ["gpt-6.1-terra"]}))
    ok(mc.validate(keep, require=mc.bundled()).resolve("gpt-6.1-terra") == "gpt-6.3-terra",
       "Ablösung mit replaces gültig, Cache-Preise mit Standardwerten")
    ok(mc.validate(changed(lambda d: d["models"][0].update(features=["neu_unbekannt"]))).version == base["version"],
       "unbekannte Merkmale werden ignoriert")


def newer(version: int, fn=None) -> bytes:
    d = bundled_raw()
    d["version"] = version
    if fn:
        fn(d)
    return json.dumps(d).encode()


def add_nova(d: dict) -> None:
    d["models"].append({"id": "gpt-6.3-nova", "label": "GPT-6.3 Nova", "provider": "openai", "hint": "Neu", "rank": 50,
                        "price": {"input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3},
                        "routes": ["api", "chatgpt_abo"]})


def replace_terra(d: dict) -> None:
    add_nova(d)
    for m in d["models"]:
        if m["id"] == "gpt-6.1-terra":
            m["deprecated"] = True
    d["models"].append({"id": "gpt-6.3-terra", "label": "GPT-6.3 Terra", "provider": "openai", "hint": "Ausgewogen",
                        "rank": 20, "price": {"input": 1, "output": 5, "cache_read": 0.05, "cache_write": 1.25},
                        "routes": ["api", "chatgpt_abo"], "replaces": ["gpt-6.1-terra"]})


def test_remote_and_server() -> None:
    from aisbot import server
    assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
    db = server.db
    base = f"http://127.0.0.1:{PORT}"
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning")
    threading.Thread(target=uvicorn.Server(cfg).run, daemon=True).start()
    token = json.loads((TMP / "config.json").read_text())["api_token"] if (TMP / "config.json").exists() else None
    http = httpx.Client(base_url=base, timeout=20)
    for _ in range(100):
        try:
            http.get("/api/version")
            break
        except httpx.HTTPError:
            time.sleep(0.1)
    token = token or json.loads((TMP / "config.json").read_text())["api_token"]
    H = {"Authorization": f"Bearer {token}"}

    print("GET /api/models")
    r = http.get("/api/models", headers=H)
    ok(r.status_code == 200, "Katalog abrufbar")
    d = r.json()
    ids = [m["id"] for m in d["models"] if m["selectable"]]
    ok("claude-fable-5-2" in ids and "gpt-6.2-sol" in ids and "gpt-6.1-sol" not in ids, "neue Modelle wählbar")
    fable = next(m for m in d["models"] if m["id"] == "claude-fable-5-2")
    ok(fable["label"] == "Fable 5.2" and fable["provider"] == "anthropic" and fable["routes"] == ["api", "claude_abo"],
       "Fable: Name, Anbieter, Wege API und Claude-Abo")
    ok(fable["available"] is False and fable["routes_available"] == [], "ohne Schlüssel und Abo: nicht verfügbar")
    ok(d["replaced"]["gpt-6-astra"] == "gpt-6.2-astra" and d["version"] == mc.bundled().version, "Ablösungen und Version")
    ok(http.get("/api/models").status_code == 401, "nur angemeldet")

    print("Alte Kennungen in der Datenbank und in Anfragen")
    old_bot = db.create_bot(model="gpt-6.1-sol", escalation_model="gpt-6-astra", name="Solli", label="", mascot={},
                            character="")
    now = "2026-11-18T10:00:00+01:00"
    db.q("INSERT INTO routines(id,bot_id,kind,title,schedule,schedule_text,prompt,enabled,next_run,created_at,model) "
         "VALUES('rt_alt',?,'routine','Bericht','0 8 * * 1','Mo 8:00','x',1,?,?,'gpt-6-astra')", (old_bot, now, now))
    for tid, state in (("t_offen", "scheduled"), ("t_fertig", "done")):
        db.q("INSERT INTO tasks(id,bot_id,chat_id,title,prompt,engine,model,state,workdir,budget_usd,max_minutes,"
             "created_at,updated_at,model_choice) VALUES(?,?,?,'T','x','openai','gpt-6.1-sol',?,'/tmp/x',1,1,?,?,"
             "'gpt-6.1-sol')", (tid, old_bot, old_bot, state, now, now))
    db.q("INSERT INTO usage(bot_id,model,dollars,input_tokens,output_tokens,cache_read,cache_write,created_at) "
         "VALUES(?,'gpt-6-astra',0.5,1000,1000,0,0,?)", (old_bot, now))
    n = mc.remap_db(db)
    ok(n >= 5, f"Umstellung meldet {n} Änderungen")
    row = db.bot_row(old_bot)
    ok(row["model"] == "gpt-6.2-sol" and row["escalation_model"] == "gpt-6.2-astra", "Scoop: Modell und Verstärkung neu")
    ok(db.one("SELECT model FROM routines WHERE id='rt_alt'")["model"] == "gpt-6.2-astra", "Routine umgestellt")
    t_open = db.one("SELECT model, model_choice FROM tasks WHERE id='t_offen'")
    t_done = db.one("SELECT model, model_choice FROM tasks WHERE id='t_fertig'")
    ok(t_open["model"] == "gpt-6.2-sol" and t_open["model_choice"] == "gpt-6.2-sol", "offene Aufgabe umgestellt")
    ok(t_done["model"] == "gpt-6.1-sol", "erledigte Aufgabe behält ihr damaliges Modell")
    ok(db.one("SELECT model FROM usage WHERE bot_id=?", (old_bot,))["model"] == "gpt-6-astra",
       "Kostenhistorie unverändert (alte Kennung, alter Preis)")
    ok(mc.remap_db(db) == 0, "zweite Umstellung ändert nichts mehr")

    r = http.post("/api/bots", headers=H, json={"name": "Alti", "mascot": {}, "model": "gpt-6-astra"})
    ok(r.status_code == 200 and r.json()["model"] == "gpt-6.2-astra", "ältere App schickt alte Kennung → Nachfolger")
    bid = r.json()["id"]
    r = http.patch(f"/api/bots/{bid}", headers=H, json={"model": "gpt-6.1-sol"})
    ok(r.status_code == 200 and db.bot_row(bid)["model"] == "gpt-6.2-sol", "PATCH mit alter Kennung")
    ok(http.patch(f"/api/bots/{bid}", headers=H, json={"model": "gpt-9-quatsch"}).status_code == 400, "unbekannt → 400")
    r = http.patch(f"/api/bots/{bid}", headers=H, json={"model": "claude-fable-5-2"})
    ok(r.status_code == 200 and db.bot_row(bid)["model"] == "claude-fable-5-2", "Fable wählbar")
    ok(http.patch("/api/routines/rt_alt", headers=H, json={"model": "gpt-6.1-sol"}).json()["model"] == "gpt-6.2-sol",
       "Routine: alte Kennung → Nachfolger")

    from aisbot.bots import BotService
    cur = BotService._current_models
    ok(cur({"model": "claude-fable-5-2", "escalation_model": "claude-sonnet-5-5"})["escalation_model"] is None,
       "Fable-Scoop gibt nicht an das schwächere Sonnet ab")
    ok(cur({"model": "claude-haiku-5-5", "escalation_model": "claude-fable-5-2"})["escalation_model"] == "claude-fable-5-2",
       "Haiku → Fable als Verstärkung erlaubt")
    ok(cur({"model": "gpt-6.1-sol", "escalation_model": "claude-sonnet-5-5"}) == {"model": "gpt-6.2-sol",
                                                                                 "escalation_model": "claude-sonnet-5-5"},
       "OpenAI: alte Kennung abgebildet, Verstärkung bleibt Schalter")

    print("Fernkopie, Rückfall, Zwischenspeicher")
    seen: list[str] = []
    real_publish = server.events.publish
    server.events.publish = lambda kind, data=None: (seen.append(kind), real_publish(kind, data))[1]
    v0 = mc.current().version
    ok(mc.refresh(lambda url: newer(v0 + 1)) is False, "ohne Adresse: kein Laden (Testinstanz)")
    os.environ["AISBOT_MODELS_URL"] = "https://test.invalid/models.json"
    try:
        ok(mc.refresh(lambda url: b"{kaputt") is False and "JSON" in (mc.status()["last_error"] or ""),
           "kaputtes JSON: alter Katalog bleibt, Fehler vermerkt")
        ok(mc.refresh(lambda url: newer(v0 + 1, lambda d: d["models"][0].update(id="o4"))) is False
           and mc.current().version == v0, "ungültige Fernkopie verworfen")
        ok(mc.refresh(lambda url: newer(v0)) is False, "gleiche Version: nichts zu tun")

        def boom(url):
            raise httpx.ConnectError("offline")
        ok(mc.refresh(boom) is False and mc.current().version == v0, "Netzfehler: gebündelter Katalog gilt")
        terra_bot = db.create_bot(model="gpt-6.1-terra", escalation_model="x", name="Terri", label="", mascot={},
                                  character="")
        ok(mc.refresh(lambda url: newer(v0 + 5, replace_terra)) is True, "neuere Fernkopie übernommen")
        ok(mc.current().source == "remote" and mc.current().version == v0 + 5, "Quelle und Version")
        ok("gpt-6.3-nova" in config.MODELS and "gpt-6.1-terra" not in config.MODELS, "neues Modell sofort wählbar")
        from aisbot.engine_openai import ESCALATE
        ok(ESCALATE["gpt-6.2-astra"] == "gpt-6.3-nova" and ESCALATE["gpt-6-luna"] == "gpt-6.3-terra",
           "Verstärkungskette folgt dem Rang")
        ok(db.bot_row(terra_bot)["model"] == "gpt-6.3-terra", "Wechsel stellt Scoops auf den Nachfolger um")
        ok("models.updated" in seen, "Apps bekommen „models.updated“")
        r = http.get("/api/models", headers=H).json()
        ok(any(m["id"] == "gpt-6.3-nova" for m in r["models"]) and r["source"] == "remote", "API liefert neuen Katalog")
        ok(config.price_for("gpt-6.3-nova")[0].output == 15, "Preis des neuen Modells bekannt")
        cache = TMP / "data" / "models_catalog.json"
        ok(cache.exists() and json.loads(cache.read_text())["version"] == v0 + 5, "Fernkopie zwischengespeichert")
        ok(mc.refresh(lambda url: newer(v0 + 3, replace_terra)) is False and mc.current().version == v0 + 5,
           "ältere Fernkopie wird nicht übernommen")
        ok(mc.refresh(lambda url: newer(v0 + 9)) is False, "Fernkopie ohne inzwischen bekannte Modelle verworfen")
        mc._current = None  # Neustart simulieren
        ok(mc.current().source == "cache" and mc.current().version == v0 + 5, "nach Neustart: Zwischenspeicher gilt")
        cache.write_text("{kaputt")
        mc._current = None
        ok(mc.current().source == "bundled", "kaputter Zwischenspeicher: gebündelter Katalog")
    finally:
        os.environ["AISBOT_MODELS_URL"] = ""
        server.events.publish = real_publish


def main() -> None:
    test_bundled()
    test_validation()
    test_remote_and_server()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
