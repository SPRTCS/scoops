"""Test für den Live-Sprechmodus (live_voice.py) gegen einen nachgebauten OpenAI-Live-Endpunkt.

Startet eine eigene Testinstanz im Prozess (Temp-Ordner, eigener Port, AISBOT_OFFLINE) – niemals die Produktion
auf 8787 – und einen Mock von `wss://api.openai.com/v1/live/sessions` (Ereignisse wie in der Live-Doku).
Kein echter OpenAI-Aufruf, kein Anthropic-Aufruf (der delegierte Scoop-Lauf ist ersetzt).

    cd Server && uv run python tests/test_live_voice.py
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-live-test-"))
TOKEN = "test-token-" + os.urandom(6).hex()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT, MOCK_PORT = free_port(), free_port()
(TMP / "config.json").write_text(json.dumps({"api_token": TOKEN, "live_voice": {"idle_seconds": 6, "max_minutes": 1}}))
os.environ.update(AISBOT_DATA=str(TMP / "data"), AISBOT_CONFIG=str(TMP / "config.json"), AISBOT_OFFLINE="1",
                  AISBOT_PORT=str(PORT), AISBOT_COMPUTER_URL="http://127.0.0.1:9",
                  AISBOT_KEYCHAIN_PREFIX="ais-live-test-" + os.urandom(3).hex(),
                  AISBOT_LIVE_URL=f"ws://127.0.0.1:{MOCK_PORT}/v1/live/sessions")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402
from websockets.asyncio.server import serve  # noqa: E402

from aisbot import server  # noqa: E402
from aisbot.db import new_id, now_iso  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
BASE = f"http://127.0.0.1:{PORT}"
WS = f"ws://127.0.0.1:{PORT}/api/voice/live"
H = {"Authorization": f"Bearer {TOKEN}"}
http = httpx.Client(base_url=BASE, timeout=30)
passed = 0
FAKE_KEY = "sk-test-" + os.urandom(4).hex()
key_present = {"on": True}
server._keychain = lambda service, account: FAKE_KEY if (service.endswith("-openai") and key_present["on"]) else None


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def tone(seconds: float) -> bytes:
    return (b"\x10\x20" * int(24_000 * seconds))


# -- Mock von OpenAI Live -------------------------------------------------------
class MockLive:
    """Verhält sich wie der Live-Primärendpunkt: session.start → started, Begrüßung, Transkripte, Delegation."""

    def __init__(self) -> None:
        self.sessions: list[dict] = []
        self.auth: list[str] = []
        self.loop = asyncio.new_event_loop()
        self.ready = threading.Event()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        asyncio.run_coroutine_threadsafe(self._start(), self.loop).result(10)

    async def _start(self) -> None:
        self.server = await serve(self.handler, "127.0.0.1", MOCK_PORT, max_size=8 * 2**20)

    async def handler(self, ws) -> None:
        s = {"start": None, "events": [], "audio_in": 0, "closed": False, "outputs": []}
        self.sessions.append(s)
        self.auth.append(ws.request.headers.get("Authorization", ""))
        t0 = time.monotonic()

        async def say(text: str, seconds: float) -> None:
            for word in text.split(" "):
                await ws.send(json.dumps({"type": "session.output_transcript.delta", "delta": word + " ",
                                          "start_ms": 0, "end_ms": 0}))
            await ws.send(json.dumps({"type": "session.output_audio.delta",
                                      "delta": base64.b64encode(tone(seconds)).decode()}))

        try:
            await self._serve(ws, s, t0, say)
        except Exception:  # noqa: BLE001 – Gegenseite hat geschlossen
            pass

    async def _serve(self, ws, s, t0, say) -> None:
        spoke_user = False
        async for raw in ws:
            e = json.loads(raw)
            s["events"].append(e)
            t = e.get("type")
            if t == "session.start":
                s["start"] = e
                await ws.send(json.dumps({"type": "session.started", "event_id": "ev1",
                                          "session": {"id": "live_mock", "status": "active", "model": "gpt-live-1"}}))
            elif t == "session.instructions.append" and e.get("event_id"):
                await ws.send(json.dumps({"type": "session.instructions.appended", "client_event_id": e["event_id"],
                                          "start_ms": 0, "end_ms": 0}))
            elif t == "session.commentary.append":
                if s["start"]["session"]["delegation"]["type"] == "client":  # Stimmprobe
                    await ws.send(json.dumps({"type": "session.output_audio.delta",
                                              "delta": base64.b64encode(tone(1.0)).decode()}))
                elif "Begrüßung" in e.get("content", ""):
                    await say("Hey, ich hör dich!", 0.3)
            elif t == "session.input_audio.append":
                s["audio_in"] += len(base64.b64decode(e["audio"]))
                # Nach 0,5 s Nutzeraudio: Nutzer „sagt“ eine Aufgabe, Live delegiert ans Backend
                if not spoke_user and s["audio_in"] >= 24_000 and s["start"]["session"]["delegation"]["type"] == "responses":
                    spoke_user = True
                    ms = s["audio_in"] / 48  # Position im Eingabestrom (wie Live: start_ms/end_ms)
                    for w in ["Wie", "ist", "das", "Wetter", "morgen?"]:
                        await ws.send(json.dumps({"type": "session.input_transcript.delta", "delta": w + " ",
                                                  "start_ms": ms - 500, "end_ms": ms}))
                    await asyncio.sleep(1.8)  # Nutzer fertig → Beitrag wird abgeschlossen
                    d = "del_1"
                    env = lambda ev: json.dumps({"type": "response.event", "delegation_id": d, "event": ev})  # noqa: E731
                    await ws.send(json.dumps({"type": "session.delegation.created", "delegation": {"id": d, "target": "responses"}}))
                    await ws.send(env({"type": "response.created", "response": {"id": "resp_1"}}))
                    await ws.send(env({"type": "response.output_item.done", "item": {
                        "type": "function_call", "call_id": "call_1", "name": "aufgabe_an_scoop",
                        "arguments": json.dumps({"auftrag": "Wetter für morgen in Berlin nachschauen"})}}))
                    await ws.send(env({"type": "response.completed", "response": {
                        "id": "resp_1", "output": [], "usage": {"input_tokens": 1000, "output_tokens": 50,
                                                               "input_tokens_details": {"cached_tokens": 200}}}}))
            elif t == "response.item.create":
                s["outputs"].append(e["item"])
            elif t == "response.create":
                await ws.send(json.dumps({"type": "response.event", "delegation_id": "del_1",
                                          "event": {"type": "response.created", "response": {"id": "resp_2"}}}))
                await ws.send(json.dumps({"type": "response.event", "delegation_id": "del_1", "event": {
                    "type": "response.completed", "response": {"id": "resp_2", "output": [],
                                                               "usage": {"input_tokens": 1200, "output_tokens": 30}}}}))
                # Nachlaufendes Ende des Nutzer-Transkripts (vor Beginn der Antwort gesprochen): kein Barge-in
                ms = s["audio_in"] / 48
                await say("Morgen wird es sonnig bei achtzehn Grad.", 3.0)
                await ws.send(json.dumps({"type": "session.input_transcript.delta", "delta": "Bitte ",
                                          "start_ms": ms - 400, "end_ms": ms - 100}))
                await asyncio.sleep(0.6)
                # Barge-in: Nutzer redet dazwischen, während der Scoop noch hörbar spricht (0,6 s nach Beginn;
                # der Mock liest währenddessen nicht weiter, daher Position aus der Wartezeit)
                await ws.send(json.dumps({"type": "session.input_transcript.delta", "delta": "Danke ",
                                          "start_ms": ms + 500, "end_ms": ms + 600}))
                await ws.send(json.dumps({"type": "session.usage.updated", "usage": {"seconds": 4.5}}))
            elif t == "session.close":
                s["closed"] = True
                await ws.send(json.dumps({"type": "session.closed", "reason": "close_requested",
                                          "usage": {"seconds": round(time.monotonic() - t0, 2)}}))
                await ws.close()
                return


async def app_client(chat: str, *, until=lambda m: False, send_audio=True, stop_after: float | None = None,
                     timeout: float = 25, headers=None) -> tuple[list, int]:
    """Spielt die App: verbindet, schickt Mikrofon-Pakete (40 ms), sammelt alles bis `until` oder `end`."""
    got: list = []
    audio = 0
    async with connect(f"{WS}?chat={chat}", additional_headers=headers if headers is not None else H) as ws:
        t0 = time.monotonic()

        async def mic():
            while True:
                await asyncio.sleep(0.04)
                await ws.send(b"\x00\x00" * 960)

        mtask = None
        try:
            while time.monotonic() - t0 < timeout:
                try:
                    raw = await asyncio.wait_for(ws.recv(), 0.5)
                except TimeoutError:
                    raw = None
                except Exception:  # noqa: BLE001 – Server hat geschlossen
                    break
                if isinstance(raw, bytes):
                    audio += len(raw)
                elif raw:
                    m = json.loads(raw)
                    got.append(m)
                    if m["type"] == "ready" and send_audio:
                        mtask = asyncio.create_task(mic())
                    if m["type"] in ("end", "error") or until(m):
                        break
                if stop_after and time.monotonic() - t0 > stop_after:
                    await ws.send(json.dumps({"type": "stop"}))
                    stop_after = None
        finally:
            if mtask:
                mtask.cancel()
    return got, audio


def run(coro):
    return asyncio.run(coro)


def main() -> None:
    mock = MockLive()
    cfg = uvicorn.Config(server.app, host="127.0.0.1", port=PORT, log_level="warning", ws_ping_interval=20)
    srv = uvicorn.Server(cfg)
    threading.Thread(target=srv.run, daemon=True).start()
    for _ in range(100):
        try:
            if http.get("/api/health", headers=H).status_code == 200:
                break
        except httpx.HTTPError:
            time.sleep(0.1)

    bot = http.post("/api/bots", headers=H, json={"name": "Lina", "label": "Assistenz",
                                                  "character": "fröhlich und direkt"}).json()
    bid = bot["id"]
    # Vorstellungs-Lauf des neuen Scoops abwarten (offline → Fehler-Antwort, egal)
    for _ in range(100):
        if bid not in server.service.runs:
            break
        time.sleep(0.1)
    server.db.add_memory(bid, "profil", "Arman trinkt morgens Flat White.")

    # Delegierter Scoop-Lauf ohne Modell: antwortet fest
    def fake_run_once(chat_id, actor_id, depth, st, opts=None):
        time.sleep(0.6)
        server.service._add(chat_id, "bot", "Morgen in Berlin: sonnig, 18 Grad, kaum Wind.")
    server.service._run_once = fake_run_once

    print("Info und Anmeldung")
    info = http.get("/api/voice/live", headers=H).json()
    ok(info["available"] is True and info["model"] == "gpt-live-1", "GET /api/voice/live: verfügbar, gpt-live-1")
    ok(info["default_voice"] == "marin" and any(v["id"] == "juni" for v in info["voices"]), "Stimmen inkl. marin/juni")
    ok(info["idle_seconds"] == 6 and info["max_seconds"] == 60, "Einstellungen aus config.json")
    ok(http.get("/api/voice/live").status_code == 401, "ohne Token → 401")

    async def unauth():
        try:
            async with connect(f"{WS}?chat={bid}") as ws:
                await ws.recv()
            return None
        except Exception as e:  # noqa: BLE001
            return e
    err = run(unauth())
    ok(err is not None and ("403" in str(err) or "4401" in str(err)), f"WebSocket ohne Token abgewiesen ({str(err)[:60]})")

    print("Gespräch mit Delegation, Untertiteln, Barge-in")
    server.db.update_bot(bid, {"voice": "live:juni|com.apple.voice.premium.de-DE.Anna"})
    got, audio = run(app_client(bid, until=lambda m: m["type"] == "interrupt", timeout=30))
    types = [m["type"] for m in got]
    s = mock.sessions[-1]
    start = s["start"]["session"]
    ok(mock.auth[-1] == f"Bearer {FAKE_KEY}", "Schlüssel nur Server → OpenAI (Bearer)")
    ok(start["model"] == "gpt-live-1" and start["audio"]["format"] == {"type": "audio/pcm", "rate": 24000},
       "session.start: gpt-live-1, audio/pcm 24 kHz")
    ok(start["audio"]["output"]["voice"] == "juni", "Stimme des Scoops (live:juni|<Rückfall>)")
    ok(start["delegation"]["type"] == "responses" and start["delegation"]["responses"]["tools"][0]["name"] == "aufgabe_an_scoop",
       "Delegation: Responses-Backend mit aufgabe_an_scoop")
    ins = start["instructions"]
    ok("Lina" in ins and "fröhlich und direkt" in ins and "Flat White" in ins, "Systemanweisung: Name, Charakter, Gedächtnis")
    ok(types[0] == "ready" and got[0]["voice"] == "juni" and got[0]["rate"] == 24000, "App bekommt ready")
    ok(any(m["type"] == "transcript" and m["role"] == "assistant" for m in got), "Untertitel Scoop")
    ok(any(m["type"] == "transcript" and m["role"] == "user" for m in got), "Untertitel Nutzer")
    ok(any(m["type"] == "task" and m["state"] == "running" for m in got), "Zwischenstand: Aufgabe läuft")
    ok(any(m["type"] == "task" and m["state"] == "done" for m in got), "Aufgabe fertig")
    ok(audio > 24_000 * 2 * 3, f"Antwort-Audio als Binärpakete angekommen ({audio} Byte)")
    ok(s["audio_in"] > 0, "Mikrofon-Audio bei OpenAI angekommen (session.input_audio.append)")
    ok(types[-1] == "interrupt", "Barge-in: Nutzer spricht während Wiedergabe → interrupt an die App")
    ok(types.count("interrupt") == 1, "nachlaufendes Ende der eigenen Frage löst kein Barge-in aus")
    outs = s["outputs"]
    ok(len(outs) == 1 and outs[0]["type"] == "function_call_output" and outs[0]["call_id"] == "call_1",
       "function_call_output an Live zurück")
    res = json.loads(outs[0]["output"])
    ok("sonnig" in res.get("antwort", ""), "Ergebnis des normalen Scoop-Laufs geht an Live")
    ok(any(e["type"] == "response.create" for e in s["events"]), "response.create nach dem Ergebnis")
    # Sitzung endet, sobald die App weg ist; kurz warten, bis Nachrichten/Kosten gespeichert sind
    for _ in range(60):
        if s["closed"] and server.db.one("SELECT COUNT(*) n FROM usage WHERE model='gpt-live-1'")["n"]:
            break
        time.sleep(0.1)
    ok(s["closed"], "App trennt → session.close an OpenAI")
    msgs = http.get(f"/api/bots/{bid}/messages", headers=H, params={"limit": 50}).json()
    live_user = [m for m in msgs if m["role"] == "user" and m["meta"].get("live")]
    live_bot = [m for m in msgs if m["role"] == "bot" and m["meta"].get("live")]
    ok(any("Wetter morgen" in m["text"] for m in live_user) and live_user[0]["meta"].get("voice"),
       "Gesprochenes des Nutzers als Chat-Nachricht (voice+live)")
    ok(any("ich hör dich" in m["text"] for m in live_bot), "Gesprochenes des Scoops als Chat-Nachricht (live)")
    ok(all(m["meta"].get("silent") for m in live_bot), "Live-Antworten ohne Mitteilung (silent)")
    ok(any(m["role"] == "event" and m["text"].startswith("Live-Auftrag:") for m in msgs), "Ereignis „Live-Auftrag“ im Chat")
    ok(any(m["role"] == "bot" and "18 Grad" in m["text"] and not m["meta"].get("live") for m in msgs),
       "ausführliche Antwort des Scoop-Laufs im Chat")
    order = [m["text"][:14] for m in msgs if m["role"] in ("user", "event") and (m["meta"].get("live"))]
    ok(order and order[0].startswith("Wie ist") and any(o.startswith("Live-Auftrag") for o in order[1:]),
       "Reihenfolge: Nutzerbeitrag vor dem Auftrag")
    u = {r["model"]: r for r in server.db.q("SELECT model, SUM(dollars) d FROM usage GROUP BY model")}
    ok("gpt-live-1" in u and u["gpt-live-1"]["d"] > 0, f"Minutenkosten erfasst ({u['gpt-live-1']['d']:.5f} $)")
    ok("gpt-6-luna" in u and u["gpt-6-luna"]["d"] > 0, "Backend-Tokens erfasst (gpt-6-luna)")
    ok(http.get("/api/usage", headers=H).json()["by_model"].get("gpt-live-1") is not None, "/api/usage zeigt gpt-live-1")

    print("Kostenanzeige, Stopp")
    got, _ = run(app_client(bid, stop_after=2.5, timeout=10))
    ok(any(m["type"] == "usage" and m["seconds"] >= 1 and "cost_usd" in m for m in got), "usage-Meldungen (Laufzeit/Kosten)")
    ok(got[-1]["type"] == "end" and got[-1]["reason"] == "stopped", "stop → end (stopped)")
    time.sleep(0.5)
    ok(mock.sessions[-1]["closed"], "OpenAI-Sitzung sauber geschlossen")

    print("Stille → automatisches Ende")
    t0 = time.monotonic()
    got, _ = run(app_client(bid, send_audio=False, timeout=20))
    ok(got[-1]["type"] == "end" and got[-1]["reason"] == "idle", f"nach {time.monotonic() - t0:.1f} s Stille beendet (idle)")

    print("Rückfall")
    gid = http.post("/api/groups", headers=H, json={"name": "Team", "member_ids": [bid, bid]}).json().get("id")
    if gid:
        got, _ = run(app_client(gid, timeout=5))
        ok(got and got[0]["type"] == "error" and got[0]["fallback"], "Gruppe → error mit fallback")
    key_present["on"] = False
    ok(http.get("/api/voice/live", headers=H).json()["available"] is False, "ohne OpenAI-Schlüssel: nicht verfügbar")
    got, _ = run(app_client(bid, timeout=5))
    ok(got and got[0]["type"] == "error" and got[0]["fallback"] and "Schlüssel" in got[0]["message"],
       "ohne Schlüssel → error mit fallback")
    key_present["on"] = True

    print("Probehören")
    n0 = len(mock.sessions)
    r = http.post("/api/voice/live/preview", headers=H, json={"voice": "marin"})
    ok(r.status_code == 200 and r.headers["content-type"] == "audio/wav", "Stimmprobe als WAV")
    with wave.open(io.BytesIO(r.content)) as w:
        ok(w.getframerate() == 24000 and w.getnchannels() == 1 and w.getnframes() >= 24000, "WAV 24 kHz mono, ≥ 1 s")
    ok(mock.sessions[-1]["start"]["session"]["audio"]["output"]["voice"] == "marin", "Probe nutzt die gewählte Stimme")
    r2 = http.post("/api/voice/live/preview", headers=H, json={"voice": "marin"})
    ok(r2.content == r.content and len(mock.sessions) == n0 + 1, "zweites Probehören aus dem Zwischenspeicher")
    ok(http.post("/api/voice/live/preview", headers=H, json={"voice": "nope"}).status_code == 400, "unbekannte Stimme → 400")

    srv.should_exit = True
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    try:
        main()
    finally:
        import shutil
        shutil.rmtree(TMP, ignore_errors=True)
