"""Test für die Seite „Nutzung und Verbrauch“ (Server 1.31, docs/nutzung.md): Parser der Claude-Code- und
Codex-Protokolle (nur Zähler, Duplikate, kumulative Codex-Summen, inkrementelles Lesen, archivierte Kopien),
Preisbewertung, Auswertung (Abo-Schätzung vs. echte API-Kosten, Scoops vs. andere Apps, keine Doppelzählung mit der
Tabelle `usage`), Limits (Claude `get_usage`, RateLimitEvents, Codex `account/rateLimits/read`, Speicherung) und die
Endpunkte.

Nur synthetische Beispieldateien in einem Temp-Ordner – nie echte Protokolle, nie echte Programme.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_usage.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-usage-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "user_name": "Arman"}))
HOME = TMP / "home"  # synthetischer Home-Ordner mit .claude/.codex
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9", AISBOT_NO_TERMINAL="1", AISBOT_USAGE_HOME=str(HOME))
os.environ.pop("AISBOT_ABO", None)
SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from fastapi.testclient import TestClient  # noqa: E402

from aisbot import abos, server, usage_limits, usage_logs, usage_report  # noqa: E402
from aisbot.config import Usage, price_for  # noqa: E402
from aisbot.db import TZ, now  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
db = server.db
DATA = Path(os.environ["AISBOT_DATA"])
INHALT = "Vertraulicher Chattext 4711"
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


T_NOW = now()
T1 = T_NOW - timedelta(hours=2)
T2 = T_NOW - timedelta(days=3)


def claude_line(mid, rid, model="claude-opus-5-5", t=T1, inp=10, out=100, cr=1000, cw=200, cwd="/Users/x/proj",
                entry="t3-code", session="s-claude-1", text=INHALT):
    return json.dumps({"type": "assistant", "timestamp": iso(t), "requestId": rid, "sessionId": session,
                       "entrypoint": entry, "cwd": cwd, "uuid": os.urandom(4).hex(),
                       "message": {"id": mid, "model": model, "role": "assistant",
                                   "content": [{"type": "text", "text": text}],
                                   "usage": {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cr,
                                             "cache_creation_input_tokens": cw}}})


def codex_tc(t, total, last=None, rl=None):
    tot = {"input_tokens": total[0], "cached_input_tokens": total[1], "cache_write_input_tokens": 0,
           "output_tokens": total[2], "reasoning_output_tokens": total[3] if len(total) > 3 else 0,
           "total_tokens": total[0] + total[2]}
    info = {"total_token_usage": tot, "last_token_usage": last or tot}
    return json.dumps({"timestamp": iso(t), "type": "event_msg",
                       "payload": {"type": "token_count", "info": info, "rate_limits": rl}})


def codex_file(session="sess-o-1", originator="Codex Desktop", model="gpt-6-astra", cwd="/Users/x/proj"):
    head = [json.dumps({"timestamp": iso(T1), "type": "session_meta",
                        "payload": {"id": session, "originator": originator, "cwd": cwd,
                                    "base_instructions": INHALT}}),
            json.dumps({"timestamp": iso(T1), "type": "turn_context", "payload": {"model": model, "cwd": cwd}}),
            json.dumps({"timestamp": iso(T1), "type": "response_item",
                        "payload": {"type": "message", "content": [{"type": "input_text", "text": INHALT}]}})]
    return head


# -- Parser ----------------------------------------------------------------------------------------------------------
def test_parsers() -> None:
    print("Parser (nur Zähler)")
    data_dir = str(DATA)
    lines = [claude_line("m1", "r1", out=50).encode(), claude_line("m1", "r1", out=120).encode(),  # gleiche Antwort
             claude_line("m2", "r2", model="<synthetic>").encode(),
             json.dumps({"type": "user", "message": {"content": INHALT}}).encode(),
             claude_line("m3", "r3", cwd=data_dir + "/abo/chats", entry="sdk-py").encode()]
    recs = usage_logs.parse_claude_lines(lines, "other", data_dir)
    ok(len(recs) == 3, "synthetische Antworten übersprungen, Nutzerzeilen ignoriert")
    ok(recs[0]["key"] == recs[1]["key"] == "c:m1:r1", "Duplikat-Schlüssel message.id + requestId")
    ok(recs[2]["scope"] == "scoops" and recs[2]["app"] == "scoops", "Arbeitsordner im Datenordner → Scoops")
    ok(recs[0]["app"] == "t3-code" and recs[0]["scope"] == "other", "App aus entrypoint")
    ok(all(INHALT not in json.dumps(r) for r in recs), "kein Inhalt in den Einträgen")

    st: dict = {}
    clines = codex_file() + [
        codex_tc(T1, (1000, 800, 50, 10), rl={"limit_id": "codex", "primary": {"used_percent": 40, "window_minutes": 10080,
                                                                               "resets_at": 1999999999}}),
        codex_tc(T1, (1000, 800, 50, 10)),  # doppelte Meldung
        codex_tc(T1 + timedelta(minutes=1), (3000, 2500, 80, 10)),
    ]
    recs = usage_logs.parse_codex_lines([x.encode() for x in clines], st, "other", data_dir)
    ok(len(recs) == 2, "doppelte token_count-Meldung zählt nicht")
    ok(recs[0]["input"] == 200 and recs[0]["cache_read"] == 800 and recs[0]["output"] == 50 and recs[0]["reasoning"] == 10,
       "Codex: Eingabe ohne Cache, Cache gelesen, Ausgabe, Reasoning")
    ok(recs[1]["input"] == 300 and recs[1]["cache_read"] == 1700 and recs[1]["output"] == 30,
       "kumulative Summen als Differenz verrechnet")
    ok(recs[0]["model"] == "gpt-6-astra" and recs[0]["app"] == "Codex Desktop", "Modell aus turn_context, App aus originator")
    ok(st["rate_limits"]["data"]["primary"]["used_percent"] == 40, "Limit-Meldung aus dem Protokoll gemerkt")
    # Zurückgesetzter Zähler: letzte Anfrage zählt
    more = [codex_tc(T1 + timedelta(minutes=2), (100, 0, 5), last={"input_tokens": 100, "cached_input_tokens": 0,
                                                                    "output_tokens": 5, "total_tokens": 105})]
    recs2 = usage_logs.parse_codex_lines([x.encode() for x in more], st, "other", data_dir)
    ok(len(recs2) == 1 and recs2[0]["input"] == 100 and recs2[0]["output"] == 5, "Zähler-Reset: letzte Anfrage")


def write(p: Path, lines: list[str], mode="w", end="\n") -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, mode) as f:
        f.write("\n".join(lines) + end)


def test_scanner() -> None:
    print("Scanner (inkrementell, ohne Doppelzählung)")
    # Andere Apps
    cfile = HOME / ".claude/projects/-Users-x-proj/s1.jsonl"
    write(cfile, [claude_line("a1", "q1", t=T1), claude_line("a1", "q1", t=T1, out=150), claude_line("a2", "q2", t=T2)])
    ofile = HOME / ".codex/sessions/2026/11/17/rollout-x-sess-o-1.jsonl"
    write(ofile, codex_file() + [codex_tc(T1, (1000, 800, 50))])
    (HOME / ".codex").mkdir(parents=True, exist_ok=True)
    (HOME / ".codex/auth.json").write_text(json.dumps({"token": INHALT}))  # darf nie gelesen werden
    (HOME / ".claude/.credentials.json").write_text(json.dumps({"token": INHALT}))
    # Scoops (Claude Code im Abo-Weg legt Sitzungen unter <cwd>/projects ab, Codex im eigenen CODEX_HOME)
    sfile = DATA / "abo/chats/projects/-scoops/c1.jsonl"
    write(sfile, [claude_line("s1", "sr1", model="claude-haiku-5-5", t=T1, inp=5, out=20, cr=100, cw=0,
                              cwd=str(DATA / "abo/chats"), entry="sdk-py", session="scoops-1")])
    xfile = DATA / "abo/codex/sessions/2026/11/17/rollout-y-sess-scoops.jsonl"
    write(xfile, codex_file("sess-scoops", "codex_python_sdk", "gpt-6.1-sol") + [codex_tc(T1, (500, 400, 20))])
    # API-Aufgaben (eigene Config, in `usage` mit Kosten) zählen nicht als Abo
    write(DATA / "tasks/.claude/projects/-api/a.jsonl", [claude_line("api1", "x", t=T1)])

    opened: list[str] = []
    import builtins
    real_open = builtins.open

    def spy(f, *a, **k):
        opened.append(str(f))
        return real_open(f, *a, **k)

    sc = server.log_scanner
    builtins.open = spy
    try:
        st = sc.scan_now()
    finally:
        builtins.open = real_open
    ok(st["error"] is None and st["files"] == 4, f"vier Protokolle gefunden ({st['files']})")
    ok(not [f for f in opened if "auth.json" in f or "credentials" in f], "keine Login-Datei geöffnet")
    rows = {r["key"]: dict(r) for r in db.q("SELECT * FROM log_usage")}
    ok(set(rows) == {"c:a1:q1", "c:a2:q2", "c:s1:sr1", "o:sess-o-1:1050", "o:sess-scoops:520"},
       f"Einträge dedupliziert, API-Aufgaben ausgelassen ({sorted(rows)})")
    ok(rows["c:a1:q1"]["output"] == 150, "größter Zählerstand einer Antwort gewinnt")
    ok(rows["c:s1:sr1"]["scope"] == "scoops" and rows["o:sess-scoops:520"]["scope"] == "scoops",
       "Scoops-Ordner als Scoops markiert")
    raw = (DATA / "aisbot.db").read_bytes() + (Path(str(DATA / "aisbot.db") + "-wal").read_bytes()
                                               if Path(str(DATA / "aisbot.db") + "-wal").exists() else b"")
    ok(INHALT.encode() not in raw, "kein Gesprächsinhalt in der Datenbank")

    # Unverändert: nichts neu gelesen
    st = sc.scan_now()
    ok(st["changed"] == 0, "zweiter Durchlauf liest nichts neu")
    # Anhängen mit halber letzter Zeile
    half = claude_line("a3", "q3", t=T1, out=7)
    with open(cfile, "a") as f:
        f.write(claude_line("a4", "q4", t=T1, out=9) + "\n" + half[:40])
    sc.scan_now()
    ok(db.one("SELECT 1 FROM log_usage WHERE key='c:a4:q4'") and not db.one("SELECT 1 FROM log_usage WHERE key='c:a3:q3'"),
       "nur ganze neue Zeilen gelesen")
    with open(cfile, "a") as f:
        f.write(half[40:] + "\n")
    sc.scan_now()
    ok(db.one("SELECT output FROM log_usage WHERE key='c:a3:q3'")["output"] == 7, "halbe Zeile beim nächsten Mal")
    # Codex: Fortsetzung derselben Datei (kumulativ) und archivierte Kopie
    with open(ofile, "a") as f:
        f.write(codex_tc(T1 + timedelta(minutes=5), (1500, 1200, 70)) + "\n")
    sc.scan_now()
    r = db.one("SELECT input, cache_read, output FROM log_usage WHERE key='o:sess-o-1:1570'")
    ok(r and r["input"] == 100 and r["cache_read"] == 400 and r["output"] == 20, "Codex inkrementell mit gemerktem Stand")
    n_before = db.one("SELECT COUNT(*) n FROM log_usage")["n"]
    arch = HOME / ".codex/archived_sessions/rollout-x-sess-o-1.jsonl"
    arch.parent.mkdir(parents=True, exist_ok=True)
    arch.write_bytes(ofile.read_bytes())
    sc.scan_now()
    ok(db.one("SELECT COUNT(*) n FROM log_usage")["n"] == n_before, "archivierte Kopie zählt nicht doppelt")
    try:
        import zstandard
        z = HOME / ".codex/archived_sessions/rollout-z-sess-zst.jsonl.zst"
        z.write_bytes(zstandard.ZstdCompressor().compress(
            ("\n".join(codex_file("sess-zst") + [codex_tc(T2, (200, 0, 10))]) + "\n").encode()))
        sc.scan_now()
        ok(db.one("SELECT 1 FROM log_usage WHERE key='o:sess-zst:210'"), "komprimierte Protokolle (.zst) gelesen")
        z.unlink()
        db.q("DELETE FROM log_usage WHERE key='o:sess-zst:210'")
    except ImportError:
        print("  (zstandard fehlt in dieser Umgebung – .zst-Test übersprungen)")


# -- Preise und Auswertung --------------------------------------------------------------------------------------------
def test_prices() -> None:
    print("Preise")
    p, ref, approx = price_for("claude-opus-5-5[1m]")
    ok(ref == "claude-opus-5-5" and not approx and p.input == 4.0, "[1m]-Zusatz entfernt")
    ok(price_for("claude-sonnet-4-5-20250929")[1] == "claude-sonnet-4-5", "Datumsstempel entfernt")
    ok(price_for("claude-fable-5-2")[0].output == 40.0, "Fable 5.2 bewertet")
    p, ref, approx = price_for("gpt-5.6-sol")
    ok(ref == "gpt-6.2-sol" and approx, "unbekannte Version: Familienpreis, als geschätzt markiert")
    ok(price_for("gpt-6.1-sol")[0].cache_read == 0.20 and price_for("gpt-6-astra")[0].output == 50.0,
       "abgelöste Kennungen behalten ihren alten Preis (Kostenhistorie)")
    ok(price_for("codex-auto-review")[0] is None, "unbekanntes Modell ohne Preis")
    ok(Usage("claude-opus-5-5", 1_000_000, 0, billing="abo").dollars == 0.0, "Abo-Läufe speichern weiter 0 $")


def add_usage(bot, model, dollars, i, o, cr, cw, t: datetime, billing=None):
    db.q("INSERT INTO usage(bot_id,model,dollars,input_tokens,output_tokens,cache_read,cache_write,created_at,billing) "
         "VALUES(?,?,?,?,?,?,?,?,?)", (bot, model, dollars, i, o, cr, cw, t.astimezone(TZ).isoformat(timespec="seconds"),
                                       billing))


def test_report() -> None:
    print("Auswertung")
    bid = db.create_bot(name="Abi", label="", mascot={"shape": "bean"}, character="", model="claude-haiku-5-5",
                        escalation_model=None) if hasattr(db, "create_bot") else "b1"
    # Echte API-Kosten (billing NULL) und ein Abo-Lauf, der schon in den Protokollen steht (Claude, heute)
    add_usage(bid, "claude-sonnet-5-5", 0.5, 1000, 1000, 0, 0, T1)
    add_usage(bid, "claude-haiku-5-5", 0.0, 5, 20, 100, 0, T1, billing="abo")  # = c:s1:sr1 → nicht doppelt
    # Abo-Lauf ohne Protokoll (OpenAI vor 3 Tagen) → aus der Tabelle bewertet
    add_usage(bid, "gpt-6.1-terra", 0.0, 1_000_000, 0, 0, 0, T2, billing="abo")
    names = {r["id"]: r["name"] for r in db.bots()}
    d = usage_report.details(db, "7d", "all", logs={"available": True}, bot_names=names)
    t = d["totals"]
    ok(abs(t["api_usd"] - 0.5) < 1e-9, "echte API-Kosten getrennt ausgewiesen")
    # Abo-Schätzung von Hand: Protokolle + Terra aus der Tabelle
    exp = 0.0
    for r in db.q("SELECT model, SUM(input) i, SUM(output) o, SUM(cache_read) cr, SUM(cache_write) cw FROM log_usage "
                  "GROUP BY model"):
        pr = price_for(r["model"])[0]
        if pr:
            exp += (r["i"] * pr.input + r["o"] * pr.output + r["cr"] * pr.cache_read + r["cw"] * pr.cache_write) / 1e6
    exp += 1.0  # 1 Mio. Terra-Eingabe zu 1 $
    ok(abs(t["abo_usd"] - exp) < 1e-3, f"Abo-Verbrauch zum Listenpreis bewertet ({t['abo_usd']:.4f} ≈ {exp:.4f})")
    ok(abs(t["cost_usd"] - (exp + 0.5)) < 1e-3, "Gesamt = Abo-Schätzung + API")
    ok(abs(sum(d["by_type"].values()) - t["cost_usd"]) < 1e-3, "Kosten nach Typ ergeben die Summe")
    ok(t["tokens"] == t["input"] + t["output"] + t["cache_read"] + t["cache_write"], "Token-Summe")
    haiku = next(m for m in d["models"] if m["id"] == "claude-haiku-5-5")
    ok(haiku["requests"] == 1, "Scoops-Abo-Lauf nur einmal gezählt (Protokoll statt Tabelle)")
    ok(len(d["series"]) == 7 and d["bucket"] == "day", "7 Tagesbalken, auch leere")
    ok(abs(sum(s["cost_usd"] for s in d["series"]) - t["cost_usd"]) < 1e-3, "Tageswerte ergeben die Summe")
    src = {s["id"]: s for s in d["sources"]}
    ok(src["scoops"]["api_usd"] == 0.5 and src["scoops"]["tokens"] > 0 and src["other"]["tokens"] > 0,
       "Aufteilung Scoops / andere Apps")
    ok(d["scoops"] and d["scoops"][0]["label"] == "Abi", "pro Scoop mit Namen")
    ok(t["cache_savings_usd"] > 0, "Cache-Ersparnis berechnet")
    so = usage_report.details(db, "7d", "other", logs={"available": True})
    ok(so["totals"]["api_usd"] == 0 and all(s["id"] == "other" for s in so["sources"]), "Filter „andere Apps“")
    ss = usage_report.details(db, "7d", "scoops", logs={"available": True})
    ok(abs(ss["totals"]["cost_usd"] + so["totals"]["cost_usd"] - t["cost_usd"]) < 1e-3, "Filter ergänzen sich")
    h = usage_report.details(db, "24h", "all", logs={"available": True})
    ok(h["bucket"] == "hour" and len(h["series"]) == 24 and h["series"][-1]["key"] == now().strftime("%Y-%m-%dT%H"),
       "24 h stündlich bis jetzt")
    ok(all(r["key"] != "o:sess-zst:210" for r in db.q("SELECT key FROM log_usage")), "vor 3 Tagen nicht in 24 h")
    nolog = usage_report.details(db, "7d", "all", logs={"available": False})
    ok(any(m["id"] == "claude-haiku-5-5" for m in nolog["models"]), "ohne Protokolle: Abo-Läufe aus der Tabelle")
    acc = usage_report.details(db, "7d", "all", logs={"available": True},
                               account={"days": [{"day": now().strftime("%Y-%m-%d"), "tokens": 123}], "at": 1})
    ok(acc["account"]["openai"]["tokens"] == 123, "kontoweite OpenAI-Tokens laut Codex")


# -- Limits ----------------------------------------------------------------------------------------------------------
CLAUDE_RESP = {"subscription_type": "max", "rate_limits_available": True, "rate_limits": {
    "five_hour": {"utilization": 23.0, "resets_at": "2026-11-17T15:00:00Z"},
    "seven_day": {"utilization": 61.5, "resets_at": "2026-11-20T08:00:00Z"},
    "seven_day_opus": None,
    "model_scoped": [{"display_name": "Fable", "utilization": 12, "resets_at": "2026-11-20T08:00:00Z"}],
    "extra_usage": {"is_enabled": False, "monthly_limit": None, "used_credits": None, "utilization": None}},
    "session": {"total_cost_usd": 0}}
CODEX_RESP = {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 46, "windowDurationMins": 10080,
                                                             "resetsAt": 1794989093}},
              "rateLimitsByLimitId": {
                  "codex": {"limitId": "codex", "primary": {"usedPercent": 46, "windowDurationMins": 10080,
                                                            "resetsAt": 1794989093},
                            "secondary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1794920000},
                            "credits": {"hasCredits": True, "unlimited": False, "balance": "70055.33"},
                            "planType": "prolite"},
                  "codex_bengal": {"limitId": "codex_bengal", "limitName": "GPT-6 Astra",
                                   "primary": {"usedPercent": 5, "windowDurationMins": 10080, "resetsAt": 1794989093}}},
              "rateLimitResetCredits": {"availableCount": 3}}


def test_limits() -> None:
    print("Limits")
    c = usage_limits.parse_claude_usage(CLAUDE_RESP)
    ids = [w["id"] for w in c["windows"]]
    ok(ids == ["five_hour", "seven_day", "model:fable"], f"Claude-Fenster inkl. Modellfenster ({ids})")
    ok(c["windows"][2]["label"] == "Wöchentlich · Fable" and c["plan"] == "Max", "Beschriftung und Abo-Art")
    e = usage_limits.parse_claude_event({"windows": {"five_hour": {"utilization": 0.42, "resetsAt": 1794920000},
                                                     "seven_day_sonnet": {"utilization": 0.1, "resetsAt": 1794989093}}})
    ok(e["windows"][0]["used_percent"] == 42.0 and e["windows"][1]["label"] == "Wöchentlich · Sonnet",
       "RateLimitEvent: Anteil → Prozent")
    x = usage_limits.parse_codex_limits(CODEX_RESP)
    ok([w["label"] for w in x["windows"]] == ["Wöchentlich", "5-Stunden-Fenster", "Wöchentlich · GPT-6 Astra"],
       "Codex: Woche, 5 Stunden, Modell-Bucket")
    ok(x["credits"]["balance"] == 70055.33 and x["extra"]["reset_credits"] == 3 and x["plan"] == "Pro Lite",
       "Codex: Credits, Resets, Abo-Art")
    u = usage_limits.parse_codex_usage({"dailyUsageBuckets": [{"startDate": "2026-11-16", "tokens": 5}]})
    ok(u["days"] == [{"day": "2026-11-16", "tokens": 5}], "kontoweiter Codex-Verlauf")

    # Dienst: Abfragen nur für angemeldete Anbieter, Stand überlebt einen Neustart
    calls = []
    abos.set_status_for_tests("claude", {"installed": True, "logged_in": True, "subscription": True, "plan": "max"})
    abos.set_status_for_tests("openai", {"installed": True, "logged_in": False, "subscription": False})
    os.environ["AISBOT_ABO"] = "1"  # Live-Abfrage im Test erlauben (Fakes, keine Programme)
    try:
        lim = usage_limits.Limits(db, fetch_claude_fn=lambda: calls.append("c") or c,
                                  fetch_codex_fn=lambda: calls.append("x") or (x, u))
        snap = lim.snapshot(refresh=True, wait=5)
        cl, oa = snap["providers"]
        ok(calls == ["c"], "nur angemeldete Anbieter live abgefragt")
        ok(cl["state"] == "ok" and cl["source"] == "live" and len(cl["windows"]) == 3, "Claude live")
        ok(oa["state"] == "not_logged_in", "OpenAI: Hinweis „nicht angemeldet“")
        ok(snap["scope_note"] == "Gesamtes Abo, alle Apps und Geräte", "Hinweis: kontoweit")
        lim.snapshot(refresh=True, wait=5)
        ok(calls == ["c"], "höchstens jede Minute live")
        abos.set_status_for_tests("openai", {"installed": True, "logged_in": True, "subscription": True})
        lim2 = usage_limits.Limits(db, fetch_claude_fn=lambda: 1 / 0, fetch_codex_fn=lambda: calls.append("x") or (x, u))
        snap2 = lim2.snapshot(refresh=False, wait=5)
        ok(snap2["providers"][0]["windows"] and snap2["providers"][0]["source"] == "live",
           "gespeicherter Stand nach Neustart")
        ok(snap2["providers"][1]["credits"]["balance"] == 70055.33, "Codex abgefragt, Credits")
        ok(lim2.account_usage()["days"][0]["tokens"] == 5, "kontoweiter Verlauf gespeichert")
        # Fehler: letzter Stand bleibt, Fehler wird gemeldet
        db.set_setting("usage_limits_claude", json.dumps({**c, "at": time.time() - 3600, "source": "live"}))
        lim3 = usage_limits.Limits(db, fetch_claude_fn=lambda: (_ for _ in ()).throw(RuntimeError("aus")),
                                   fetch_codex_fn=lambda: (x, u))
        s3 = lim3.snapshot(refresh=True, wait=5)["providers"][0]
        ok(s3["state"] == "ok" and s3["windows"] and s3["error"] and "aus" in s3["error"], "Fehler: letzter Stand + Hinweis")
    finally:
        os.environ.pop("AISBOT_ABO", None)
    # RateLimitEvent wird dauerhaft mit allen Fenstern gemerkt
    from aisbot.engine_abo import _limit_info
    info = _limit_info({"status": "allowed", "unifiedWindows": {"five_hour": {"utilization": 0.3, "resetsAt": 4102444800},
                                                                "seven_day": {"utilization": 0.5, "resetsAt": 4102444800}}})
    ok(info["window"] == "seven_day" and set(info["windows"]) == {"five_hour", "seven_day"}, "alle Fenster im Event")
    abos.note_info("claude", info)
    ok(set((abos.stored_info("claude") or {}).get("windows") or {}) == {"five_hour", "seven_day"},
       "Fenster dauerhaft gespeichert")
    stored = json.loads((DATA / "abo/limits.json").read_text())
    ok(all(set(w) <= {"utilization", "resetsAt", "status"} for w in stored["claude"]["windows"].values()),
       "nur Auslastung, Rücksetzzeit und Status gespeichert")


# -- Endpunkte -------------------------------------------------------------------------------------------------------
def test_endpoints() -> None:
    print("Endpunkte")
    cl = TestClient(server.app)
    H = {"Authorization": f"Bearer {TOKEN}"}
    ok(cl.get("/api/usage/details").status_code == 401, "Details nur mit Anmeldung")
    r = cl.get("/api/usage/details?range=7d", headers=H)
    ok(r.status_code == 200 and r.json()["range"] == "7d" and r.json()["logs"]["available"], "GET /api/usage/details")
    r = cl.get("/api/usage/details?range=quatsch&source=quatsch", headers=H)
    ok(r.json()["range"] == "30d" and r.json()["source"] == "all", "ungültige Parameter → Standard")
    abos.set_status_for_tests("claude", {"installed": True, "logged_in": False, "subscription": False})
    abos.set_status_for_tests("openai", {"installed": True, "logged_in": False, "subscription": False})
    r = cl.get("/api/usage/limits", headers=H)
    ok(r.status_code == 200 and [p["id"] for p in r.json()["providers"]] == ["claude", "openai"], "GET /api/usage/limits")
    u = cl.get("/api/usage", headers=H).json()
    ok({"today_usd", "month_usd", "by_model", "by_bot", "abo"} <= set(u), "/api/usage bleibt kompatibel")
    ok(cl.get("/api/health", headers=H).json().get("usage_details") is True, "Health meldet die neue Seite")


def main() -> None:
    test_parsers()
    test_scanner()
    test_prices()
    test_report()
    test_limits()
    test_endpoints()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    import traceback
    try:
        main()
    except BaseException:  # noqa: BLE001
        traceback.print_exc(file=sys.stdout)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1)
    sys.stdout.flush()
    os._exit(0)
