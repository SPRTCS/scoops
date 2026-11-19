"""Push-Mitteilungen über APNs: Mitteilungen, App-Badge, Widget-Aktualisierung, Live-Aktivität.

Zwei Wege (Transport), automatisch gewählt:

1. **direkt** – ein eigener APNs-Schlüssel ist hinterlegt (nur Armans Server):
   - Schlüsselbund: Dienst `ais-bot-apns`, Konto `p8` (Inhalt der .p8-Datei)
   - config.json: `apns_key_id` (10 Zeichen), optional `apns_team_id` (Standard MYXQKK3T2Z)
   Token-Authentifizierung (JWT ES256), HTTP/2 direkt zu Apple – wie bisher.
2. **Relay** – kein eigener Schlüssel, aber mit einem AIS-Scoops-Konto gekoppelt (cloud.py): Versand über
   AIS Scoops Cloud (Convex, `/push/*`, siehe docs/accounts.md „Push-Relay“). Convex hält den Schlüssel, prüft
   Topic, Größe, Ratenbegrenzung und dass das Token von einem Gerät des Inhabers stammt (der Server meldet die
   Tokens, die er von der App bekommt, über `/push/register`).

Ohne beides tut dieses Modul nichts. Fehler im Versand blockieren nie einen Lauf (Hintergrund-Threads, Zeitlimits).
"""

from __future__ import annotations

import base64
import json
import subprocess
import threading
import time

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from .profile import kc

BUNDLE_ID = "com.ais.aisbot"
HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
APP_PLATFORMS_SQL = "platform IN ('ios','macos') OR platform IS NULL"  # echte App-Geräte (keine Widget-/Live-Tokens)
MODE_TTL = 30.0          # so lange gilt die Wahl direkt/Relay (spart `security`-Aufrufe)
BADGE_DEBOUNCE_S = 2.0   # Badge-Push nach „gelesen“ kurz entprellen
GONE_REASONS = ("Unregistered", "ExpiredToken")


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class Relay:
    """Push über AIS Scoops Cloud (Convex) für gekoppelte Server ohne eigenen APNs-Schlüssel."""

    STATUS_EVERY = 600.0
    SECRET_TTL = 60.0

    def __init__(self, load_config):
        self.load_config = load_config
        self._client: httpx.Client | None = None
        self._secret: tuple[float, str | None] | None = None
        self._configured: bool | None = None  # laut /push/status; None = noch nicht gefragt
        self._status_at = 0.0
        self._status_running = False
        self._registered: set[str] = set()
        self.last_error: str | None = None
        self._lock = threading.Lock()

    # Zustand
    def _url(self) -> str:
        from .cloud import DEFAULT_CLOUD_URL
        return (self.load_config().get("cloud_url") or DEFAULT_CLOUD_URL).rstrip("/")

    def secret(self) -> str | None:
        if self._secret and time.time() - self._secret[0] < self.SECRET_TTL:
            return self._secret[1]
        from .cloud import get_secret
        s = get_secret() if self.load_config().get("owner_id") else None
        self._secret = (time.time(), s)
        return s

    def reset(self) -> None:
        """Nach Kopplung/Entkopplung oder in Tests: alles neu ermitteln."""
        self._secret = None
        self._configured = None
        self._status_at = 0.0
        self._registered.clear()

    def available(self) -> bool:
        """Gekoppelt und (soweit bekannt) Relay eingerichtet. Blockiert nie: Status wird im Hintergrund erneuert."""
        if not self.secret():
            return False
        if time.time() - self._status_at > self.STATUS_EVERY and not self._status_running:
            self._status_running = True
            threading.Thread(target=self._refresh_status, daemon=True, name="push-relay-status").start()
        return self._configured is not False

    def _refresh_status(self) -> None:
        try:
            r = self._post("/push/status", {}, timeout=10)
            if r is None:
                return
            if r.status_code == 200:
                self._configured = bool(_json(r).get("configured"))
                self.last_error = None if self._configured else "Push-Relay ist in der Cloud nicht eingerichtet"
            elif r.status_code == 401:
                self._configured = False
                self._secret = None
                self.last_error = "Server ist nicht (mehr) mit einem Konto gekoppelt"
        except Exception as e:  # noqa: BLE001 – Netzfehler: letzter Stand bleibt
            self.last_error = f"Push-Relay nicht erreichbar: {e}"
        finally:
            self._status_at = time.time()
            self._status_running = False

    def _post(self, path: str, body: dict, timeout: float = 30) -> httpx.Response | None:
        secret = self.secret()
        if not secret:
            return None
        if self._client is None:
            self._client = httpx.Client(timeout=timeout)
        return self._client.post(self._url() + path, json=body, timeout=timeout,
                                 headers={"Authorization": f"Bearer {secret}"})

    # Tokens
    def register(self, entries: list[tuple[str, str]], user_of=None) -> None:
        """Tokens (token, platform) bei Convex melden, damit der Inhaber sie über das Relay erreichen darf.
        `user_of(token)` → Konto-ID eines Gasts (geteilte Scoops); Convex prüft, dass er einen Share hat."""
        entries = [(t, p) for t, p in entries if t and t not in self._registered]
        for i in range(0, len(entries), 100):
            chunk = entries[i:i + 100]
            tokens = []
            for t, p in chunk:
                e = {"token": t, "platform": p or "ios"}
                uid = user_of(t) if user_of else None
                if uid:
                    e["userId"] = uid
                tokens.append(e)
            r = self._post("/push/register", {"tokens": tokens}, 15)
            if r is None:
                return
            if r.status_code != 200:
                print(f"Push-Relay: Tokens melden fehlgeschlagen ({r.status_code} {_json(r).get('code', '')})", flush=True)
                return
            rejected = {x.get("token", "").lower() for x in _json(r).get("rejected") or []}
            for t, _ in chunk:
                if t.lower() not in rejected:
                    self._registered.add(t)

    # Versand
    def send(self, pushes: list[dict], platform_of, user_of=None) -> list[dict]:
        """pushes: [{token, pushType, priority, payload, expiration?}] → Ergebnisse je Eintrag (status, reason)."""
        with self._lock:
            self.register([(p["token"], platform_of(p["token"])) for p in pushes], user_of)
            results: list[dict] = []
            for i in range(0, len(pushes), 100):
                results += self._send_chunk(pushes[i:i + 100], platform_of, retry=True, user_of=user_of)
            return results

    def _send_chunk(self, chunk: list[dict], platform_of, retry: bool, user_of=None) -> list[dict]:
        r = self._post("/push/send", {"pushes": chunk})
        if r is None:
            return [{"token": p["token"], "status": 0, "reason": "NotLinked"} for p in chunk]
        if r.status_code != 200:
            data = _json(r)
            print(f"Push-Relay: {r.status_code} {data.get('code') or data.get('error') or ''}", flush=True)
            if r.status_code == 503:
                self._configured = False
                self._status_at = time.time()
            return [{"token": p["token"], "status": r.status_code, "reason": data.get("code") or "RelayError"} for p in chunk]
        results = list(_json(r).get("results") or [])
        unknown = [i for i, x in enumerate(results) if x.get("reason") == "UnknownToken"]
        if unknown and retry:
            # Convex kennt das Token nicht (mehr) – neu melden und einmal wiederholen
            again = [chunk[i] for i in unknown]
            for p in again:
                self._registered.discard(p["token"])
            self.register([(p["token"], platform_of(p["token"])) for p in again], user_of)
            for i, res in zip(unknown, self._send_chunk(again, platform_of, retry=False, user_of=user_of)):
                results[i] = res
        return results

    def create_channel(self) -> str | None:
        r = self._post("/push/channel", {"action": "create"}, 20)
        if r is None:
            return None
        data = _json(r)
        if r.status_code == 200 and data.get("ok") and data.get("channelId"):
            return data["channelId"]
        print(f"Push-Relay-Kanal: {r.status_code} {data.get('reason') or data.get('code') or ''}", flush=True)
        return None

    def delete_channel(self, channel: str) -> None:
        self._post("/push/channel", {"action": "delete", "channelId": channel}, 20)

    def broadcast(self, channel: str, payload: dict, priority: str) -> bool:
        r = self._post("/push/broadcast", {"channelId": channel, "payload": payload, "priority": priority,
                                           "expiration": int(time.time()) + 3600}, 20)
        if r is None:
            return False
        data = _json(r)
        ok = r.status_code == 200 and bool(data.get("ok"))
        if not ok:
            print(f"Push-Relay-Broadcast: {r.status_code} {data.get('reason') or data.get('code') or ''}", flush=True)
        return ok


def _json(r: httpx.Response) -> dict:
    try:
        d = r.json()
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


class Pusher:
    def __init__(self, db, config_loader):
        self.db = db
        self.load_config = config_loader
        self._jwt: tuple[float, str] | None = None
        self._client: httpx.Client | None = None
        self._lock = threading.Lock()
        self._mode: tuple[float, str | None] | None = None
        self.relay = Relay(config_loader)
        self._badge_last: int | None = None
        self._badge_timer: threading.Timer | None = None
        self._badge_lock = threading.Lock()
        self.db.q("DROP TABLE IF EXISTS live_ended")
        self.board = LiveBoard(self)

    # -- Transport wählen ------------------------------------------------------------
    def _key(self) -> tuple[str, str, str] | None:
        cfg = self.load_config()
        kid = cfg.get("apns_key_id")
        if not kid:
            return None
        r = subprocess.run(["security", "find-generic-password", "-s", kc("apns"), "-a", "p8", "-w"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None
        pem = r.stdout.strip()
        if "PRIVATE KEY" not in pem:
            # `security -w` gibt mehrzeilige Werte hexkodiert aus
            try:
                pem = bytes.fromhex(pem).decode()
            except ValueError:
                return None
        if "PRIVATE KEY" not in pem:
            return None
        return kid, cfg.get("apns_team_id", "MYXQKK3T2Z"), pem.replace("\\n", "\n")

    def mode(self) -> str | None:
        """„direct“ (eigener Schlüssel), „relay“ (AIS Scoops Cloud) oder None (keine Mitteilungen)."""
        if self._mode and time.time() - self._mode[0] < MODE_TTL:
            m = self._mode[1]
            return m if m != "relay" or self.relay.available() else None
        m = "direct" if self._key() is not None else ("relay" if self.relay.available() else None)
        self._mode = (time.time(), m)
        return m

    def reset_mode(self) -> None:
        self._mode = None
        self.relay.reset()

    @property
    def enabled(self) -> bool:
        return self.mode() is not None

    # -- direkt zu APNs ---------------------------------------------------------------
    def _token(self) -> str | None:
        if self._jwt and time.time() - self._jwt[0] < 40 * 60:
            return self._jwt[1]
        k = self._key()
        if not k:
            return None
        kid, team, pem = k
        key = serialization.load_pem_private_key(pem.encode(), password=None)
        header = _b64(json.dumps({"alg": "ES256", "kid": kid}).encode())
        claims = _b64(json.dumps({"iss": team, "iat": int(time.time())}).encode())
        r, s = decode_dss_signature(key.sign(f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
        sig = _b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        self._jwt = (time.time(), f"{header}.{claims}.{sig}")
        return self._jwt[1]

    def _send(self, device: str, payload: dict, push_type: str = "alert", topic: str = BUNDLE_ID,
              priority: str = "10") -> None:
        tok = self._token()
        if not tok:
            return
        if self._client is None:
            self._client = httpx.Client(http2=True, timeout=10)
        headers = {"authorization": f"bearer {tok}", "apns-topic": topic, "apns-push-type": push_type,
                   "apns-priority": priority}
        for env in ("production", "sandbox"):
            r = self._client.post(f"{HOSTS[env]}/3/device/{device}", headers=headers, json=payload)
            if r.status_code == 200:
                return
            reason = (r.json() if r.content else {}).get("reason", "")
            if reason != "BadDeviceToken":
                if reason in GONE_REASONS:
                    self._forget(device)
                print(f"APNs {env}: {r.status_code} {reason}", flush=True)
                return

    def _forget(self, token: str) -> None:
        self.db.q("DELETE FROM devices WHERE token=?", (token,))
        self.db.q("DELETE FROM guest_devices WHERE token=?", (token,))
        self.db.q("DELETE FROM live_tokens WHERE token=?", (token,))

    # -- gemeinsamer Versand (im Hintergrund-Thread, unter self._lock) ------------------
    def _platform_of(self, token: str, push_type: str = "alert") -> str:
        """Plattform für die Meldung bei Convex (bestimmt, welche Push-Art das Token bekommen darf)."""
        r = self.db.one("SELECT platform FROM devices WHERE token=?", (token,)) or \
            self.db.one("SELECT platform FROM guest_devices WHERE token=?", (token,))
        if r and r["platform"]:
            return r["platform"]
        return {"liveactivity": "liveactivity", "widgets": "ios-widgets"}.get(push_type, "ios")

    def _deliver(self, jobs: list[tuple[str, dict]], push_type: str, topic: str, priority: str) -> None:
        mode = self.mode()
        if mode == "direct":
            for token, payload in jobs:
                try:
                    self._send(token, payload, push_type=push_type, topic=topic, priority=priority)
                except Exception as e:  # noqa: BLE001
                    print(f"APNs-{push_type}-Fehler:", e, flush=True)
        elif mode == "relay":
            pushes = [{"token": t, "pushType": push_type, "topic": topic, "priority": priority, "payload": p}
                      for t, p in jobs]
            try:
                results = self.relay.send(pushes, lambda t: self._platform_of(t, push_type), self._guest_of)
            except Exception as e:  # noqa: BLE001 – Netzfehler: nie den Lauf stören
                print(f"Push-Relay-{push_type}-Fehler:", e, flush=True)
                return
            for res in results:
                reason = res.get("reason") or ""
                if reason in GONE_REASONS or reason == "BadDeviceToken":
                    self._forget(res.get("token", ""))
                if res.get("status") != 200:
                    print(f"Push-Relay {push_type}: {res.get('status')} {reason}", flush=True)

    def _spawn(self, jobs: list[tuple[str, dict]], push_type: str, topic: str, priority: str) -> None:
        if not jobs or not self.enabled:
            return

        def run() -> None:
            with self._lock:
                self._deliver(jobs, push_type, topic, priority)

        threading.Thread(target=run, daemon=True).start()

    def _guest_of(self, token: str) -> str | None:
        """Konto-ID, falls das Token einem Gast gehört (geteilte Scoops); sonst None (Gerät des Inhabers)."""
        if self.db.one("SELECT 1 FROM devices WHERE token=?", (token,)):
            return None
        r = self.db.one("SELECT user_id FROM guest_devices WHERE token=?", (token,))
        return r["user_id"] if r else None

    def note_guest_token(self, token: str, platform: str | None, user_id: str) -> None:
        """Gast-Gerät (POST /api/shared/devices): im Relay-Modus mit Konto-ID des Gasts bei Convex melden."""
        if not token or self.mode() != "relay":
            return

        def run() -> None:
            try:
                self.relay.register([(token, platform or "ios")], lambda _t: user_id)
            except Exception as e:  # noqa: BLE001
                print("Push-Relay: Gast-Token melden fehlgeschlagen:", e, flush=True)

        threading.Thread(target=run, daemon=True).start()

    def notify_users(self, user_ids: list[str], title: str, body: str, data: dict | None = None) -> None:
        """Mitteilung an die Geräte von Gästen (geteilte Scoops). Ohne Badge – die Zahl am App-Symbol gehört dem
        eigenen Server des Gasts. Zusätzlich `shared`, `server_id`, `owner_id`, damit die App den Chat findet."""
        if not self.enabled or not user_ids:
            return
        ph = ",".join("?" * len(user_ids))
        devices = [r["token"] for r in self.db.q(
            f"SELECT token FROM guest_devices WHERE user_id IN ({ph}) AND (platform IN ('ios','macos','ipados') OR platform IS NULL)",
            tuple(user_ids))]
        if not devices:
            return
        cfg = self.load_config()
        payload = {"aps": {"alert": {"title": title, "body": body[:240]}, "sound": "default",
                           "thread-id": (data or {}).get("bot_id", "aisbot"), "mutable-content": 1},
                   **(data or {}), "shared": True, "server_id": cfg.get("cloud_server_id"), "owner_id": cfg.get("owner_id")}
        self._spawn([(d, payload) for d in devices], "alert", BUNDLE_ID, "10")

    def note_token(self, token: str, platform: str | None) -> None:
        """Token, das die App gemeldet hat: im Relay-Modus gleich bei Convex anmelden (im Hintergrund)."""
        if not token or self.mode() != "relay":
            return

        def run() -> None:
            try:
                self.relay.register([(token, platform or "ios")])
            except Exception as e:  # noqa: BLE001
                print("Push-Relay: Token melden fehlgeschlagen:", e, flush=True)

        threading.Thread(target=run, daemon=True).start()

    def _app_devices(self) -> list[str]:
        return [r["token"] for r in self.db.q(f"SELECT token FROM devices WHERE {APP_PLATFORMS_SQL}")]

    # -- Mitteilungen und Badge ----------------------------------------------------------
    def notify(self, title: str, body: str, data: dict | None = None, category: str | None = None) -> None:
        """Mitteilung an alle registrierten Geräte (im Hintergrund). Badge = Chats mit ungelesenen Nachrichten.
        `category` = `aps.category` (Freigabe-Knöpfe an der Mitteilung, ab 1.32)."""
        if not self.enabled:
            return
        # Nur echte App-Geräte; Widget- und Live-Aktivitäts-Tokens haben eigene Topics.
        devices = self._app_devices()
        if not devices:
            return
        badge = self.db.unread_chat_count()
        with self._badge_lock:
            self._badge_last = badge
        payload = {"aps": {"alert": {"title": title, "body": body[:240]}, "sound": "default", "badge": badge,
                           "thread-id": (data or {}).get("bot_id", "aisbot"), "mutable-content": 1},
                   **(data or {})}
        if category:
            payload["aps"]["category"] = category
        self._spawn([(d, payload) for d in devices], "alert", BUNDLE_ID, "10")

    def badge_changed(self) -> None:
        """Ein Chat wurde gelesen (unread=0): Badge der App leise aktualisieren, entprellt, nur bei Änderung."""
        if not self.enabled:
            return
        with self._badge_lock:
            if self._badge_timer:
                self._badge_timer.cancel()
            self._badge_timer = threading.Timer(BADGE_DEBOUNCE_S, self._badge_flush)
            self._badge_timer.daemon = True
            self._badge_timer.start()

    def _badge_flush(self) -> None:
        with self._badge_lock:
            self._badge_timer = None
            n = self.db.unread_chat_count()
            if n == self._badge_last:
                return
            self._badge_last = n
        devices = self._app_devices()
        if devices:
            self._spawn([(d, {"aps": {"badge": n}}) for d in devices], "alert", BUNDLE_ID, "5")

    # -- Live-Aktivität (eine gemeinsame Anzeige für alle arbeitenden Scoops) ---------------
    def live_start(self, bot: dict, run_id: str, meta: dict) -> "LiveSession | None":
        if not self.enabled:
            return None
        self.board.run_started(bot, run_id, meta)
        return LiveSession(self.board, bot["id"], run_id)

    def end_stale_live(self, busy: set[str] | None = None) -> None:
        """Planer-Tick: hängengebliebene Anzeige beenden, alte Kanäle löschen. busy = Chats/Scoops, die gerade arbeiten."""
        if self.enabled:
            self.board.sweep(busy)

    def _broadcast(self, channel: str, payload: dict, priority: str) -> bool:
        if self.mode() == "relay":
            return self.relay.broadcast(channel, payload, priority)
        tok = self._token()
        if not tok:
            return False
        if self._client is None:
            self._client = httpx.Client(http2=True, timeout=10)
        r = self._client.post(f"{HOSTS['production']}/4/broadcasts/apps/{BUNDLE_ID}", json=payload, headers={
            "authorization": f"bearer {tok}", "apns-channel-id": channel, "apns-push-type": "LiveActivity",
            "apns-priority": priority, "apns-expiration": str(int(time.time()) + 3600)})  # Pflicht bei Broadcast
        if r.status_code != 200:
            print(f"APNs-Broadcast: {r.status_code} {r.text[:200]}", flush=True)
        return r.status_code == 200

    def _channel(self, method: str, channel: str | None = None) -> str | None:
        """Broadcast-Kanal anlegen (POST) oder löschen (DELETE). None, wenn Broadcast nicht freigeschaltet ist."""
        if self.mode() == "relay":
            if method == "POST":
                return self.relay.create_channel()
            if channel:
                self.relay.delete_channel(channel)
            return None
        tok = self._token()
        if not tok:
            return None
        if self._client is None:
            self._client = httpx.Client(http2=True, timeout=10)
        headers = {"authorization": f"bearer {tok}"}
        if channel:
            headers["apns-channel-id"] = channel
        r = self._client.request(method, f"{BROADCAST_MANAGE}/1/apps/{BUNDLE_ID}/channels", headers=headers,
                                 json={"message-storage-policy": 1, "push-type": "LiveActivity"} if method == "POST" else None)
        if method == "POST":
            if r.status_code in (200, 201):
                return r.headers.get("apns-channel-id")
            print(f"APNs-Kanal: {r.status_code} {r.text[:200]}", flush=True)
        return None

    def wake(self, token: str, data: dict | None = None) -> bool:
        """Stille Push (`content-available`, Priorität 5) an ein App-Gerät, z. B. damit das iPhone einen Befehl für
        Home/Wecker/Standort abholt (apple_device.py). iOS stellt sie nach eigenem Ermessen zu (nicht garantiert)."""
        if not token or not self.enabled:
            return False
        payload = {"aps": {"content-available": 1}, **(data or {})}
        self._spawn([(token, payload)], "background", BUNDLE_ID, "5")
        return True

    def reload_widgets(self) -> None:
        """Stößt eine Widget-Aktualisierung an (WidgetKit-Push), sofern Geräte registriert sind."""
        if not self.enabled:
            return
        devices = [r["token"] for r in self.db.q("SELECT token FROM devices WHERE platform='ios-widgets'")]
        self._spawn([(d, {"aps": {"content-changed": True}}) for d in devices], "widgets",
                    f"{BUNDLE_ID}.push-type.widgets", "5")


APPLE_EPOCH = 978307200  # 1.1.2001, Standard-Datumskodierung von ActivityKit
BROADCAST_MANAGE = "https://api-manage-broadcast.push.apple.com:2196"
LIVE_TOPIC = f"{BUNDLE_ID}.push-type.liveactivity"
DONE_VISIBLE_S = 45      # fertige Scoops bleiben so lange in der Liste, solange andere noch arbeiten
DISMISS_AFTER_S = 60     # „Alle fertig“ verschwindet danach vom Sperrbildschirm


def _apple_ts(iso: str | None) -> float | None:
    if not iso:
        return None
    from datetime import datetime
    return datetime.fromisoformat(iso).timestamp() - APPLE_EPOCH


class LiveBoard:
    """Genau eine Live-Aktivität für alle arbeitenden Scoops.

    Jede Anzeige-Sitzung bekommt einen eigenen APNs-Broadcast-Kanal (falls Broadcast freigeschaltet ist):
    Updates und das Ende erreichen dann jede Aktivität, auch wenn das iPhone nie ein Token gemeldet hat.
    Ohne Broadcast: Update-Tokens der App (`/api/live-activities`, run_id = Sitzung).
    """

    def __init__(self, pusher: "Pusher"):
        self.p = pusher
        self.lock = threading.RLock()
        self.entries: dict[str, dict] = {}   # chat_id → Eintrag
        self.runs: dict[str, str] = {}       # run_id → chat_id
        self.session: str | None = None
        self.channel: str | None = None
        self.alive = False
        self.ended: tuple[str | None, str | None, float] | None = None  # (Sitzung, Kanal, Zeit) der letzten „Fertig“-Anzeige
        self._last_push = 0.0
        self._timer: threading.Timer | None = None
        self._broadcast_checked = 0.0
        self._broadcast_ok = False
        db = pusher.db
        db.q("CREATE TABLE IF NOT EXISTS live_sessions (session TEXT PRIMARY KEY, channel TEXT, alive INTEGER NOT NULL, "
             "created_at TEXT NOT NULL DEFAULT (datetime('now')), ended_at TEXT)")
        # Alte Einzel-Anzeigen (BotRunAttributes) nicht mehr per Push starten
        db.q("DELETE FROM devices WHERE platform='ios-liveactivity-start'")

    # -- Zustand -----------------------------------------------------------------
    def _entry(self, bot: dict, meta: dict, old: dict | None = None) -> dict:
        lines = meta.get("lines") or []
        e = dict(old or {})
        e.update({"id": bot["id"], "name": bot["name"], "label": bot.get("label") or None, "mascot": bot["mascot"],
                  "state": meta.get("state", "running"), "statusLine": (lines or ["Denkt nach"])[-1][:80],
                  "steps": len(lines), "startedAt": _apple_ts(meta.get("started_at")) or (time.time() - APPLE_EPOCH)})
        fin = _apple_ts(meta.get("finished_at"))
        if fin is not None:
            e["finishedAt"] = fin
        else:
            e.pop("finishedAt", None)
        return e

    def _running(self) -> list[dict]:
        return [e for e in self.entries.values() if e["state"] == "running"]

    def content(self) -> dict:
        now = time.time() - APPLE_EPOCH
        if self._running():  # erledigte nur kurz zeigen, solange andere noch arbeiten
            for cid in [c for c, e in self.entries.items()
                        if e["state"] != "running" and now - e.get("finishedAt", now) > DONE_VISIBLE_S]:
                self.entries.pop(cid, None)
        scoops = sorted(self.entries.values(), key=lambda e: (e["state"] != "running", e["startedAt"]))
        return {"scoops": scoops, "updatedAt": now}

    def snapshot(self) -> dict:
        with self.lock:
            return {"active": self.alive, "session": self.session if self.alive else None,
                    "channel": self.channel if self.alive else None,
                    "content": self.content() if self.alive else None}

    # -- Broadcast ------------------------------------------------------------------
    def _broadcast_available(self) -> bool:
        if time.time() - self._broadcast_checked > 600:
            self._broadcast_checked = time.time()
            self._broadcast_ok = True  # wird beim Anlegen geprüft
        return self._broadcast_ok

    def _new_channel(self) -> str | None:
        if not self._broadcast_available():
            return None
        try:
            ch = self.p._channel("POST")
        except Exception as e:  # noqa: BLE001
            print("APNs-Kanal-Fehler:", e, flush=True)
            ch = None
        if not ch:
            self._broadcast_ok = False
        return ch

    # -- Senden ---------------------------------------------------------------------
    def _send(self, session: str | None, channel: str | None, payload: dict, priority: str) -> None:
        tokens = [r["token"] for r in self.p.db.q("SELECT token FROM live_tokens WHERE run_id=?", (session,))] if session else []

        def run() -> None:
            with self.p._lock:
                if channel:
                    try:
                        self.p._broadcast(channel, payload, priority)
                    except Exception as e:  # noqa: BLE001
                        print("APNs-Broadcast-Fehler:", e, flush=True)
                if tokens:
                    self.p._deliver([(t, payload) for t in tokens], "liveactivity", LIVE_TOPIC, priority)

        threading.Thread(target=run, daemon=True).start()

    def _end_payload(self, content: dict, dismiss_s: int) -> dict:
        now = int(time.time())
        return {"aps": {"timestamp": now, "event": "end", "content-state": content, "dismissal-date": now + dismiss_s}}

    def _dismiss_previous(self) -> None:
        """Noch sichtbare „Alle fertig“-Anzeige sofort wegräumen, bevor eine neue startet."""
        if not self.ended:
            return
        session, channel, _ = self.ended
        self.ended = None
        self._send(session, channel, self._end_payload({"scoops": [], "updatedAt": time.time() - APPLE_EPOCH}, 0), "10")

    def _open(self, push_start: bool) -> None:
        import uuid
        self._dismiss_previous()
        self.session = "live-" + uuid.uuid4().hex[:12]
        self.channel = self._new_channel()
        self.alive = True
        self.p.db.q("INSERT INTO live_sessions(session, channel, alive) VALUES(?,?,1)", (self.session, self.channel))
        self._last_push = time.time()
        if not push_start:
            return
        start_tokens = [r["token"] for r in self.p.db.q("SELECT token FROM devices WHERE platform='ios-scoops-live-start'")]
        if not start_tokens:
            return
        names = [e["name"] for e in self._running()]
        aps = {"timestamp": int(time.time()), "event": "start", "content-state": self.content(),
               "attributes-type": "ScoopsLiveAttributes", "attributes": {"title": "AIS Scoops"},
               "alert": {"title": names[0] if len(names) == 1 else "AIS Scoops",
                         "body": "arbeitet …" if len(names) == 1 else f"{len(names)} Scoops arbeiten"}}
        if self.channel:
            aps["input-push-channel"] = self.channel
        else:
            aps["input-push-token"] = 1
        self.p._spawn([(t, {"aps": aps}) for t in start_tokens], "liveactivity", LIVE_TOPIC, "10")

    def _push_update(self, priority: str = "5") -> None:
        if self._timer:
            self._timer.cancel()
            self._timer = None
        self._last_push = time.time()
        payload = {"aps": {"timestamp": int(time.time()), "event": "update", "content-state": self.content()}}
        self._send(self.session, self.channel, payload, priority)

    def _flush_later(self) -> None:
        if self._timer:
            return
        wait = max(0.5, 4 - (time.time() - self._last_push))

        def fire() -> None:
            with self.lock:
                self._timer = None
                if self.alive:
                    self._push_update()

        self._timer = threading.Timer(wait, fire)
        self._timer.daemon = True
        self._timer.start()

    def _close(self) -> None:
        if self._timer:
            self._timer.cancel()
            self._timer = None
        content = self.content()
        self._send(self.session, self.channel, self._end_payload(content, DISMISS_AFTER_S), "10")
        self.p.db.q("UPDATE live_sessions SET alive=0, ended_at=datetime('now') WHERE session=?", (self.session,))
        self.ended = (self.session, self.channel, time.time())
        self.alive = False
        self.entries.clear()

    # -- Ereignisse aus den Läufen ---------------------------------------------------
    def run_started(self, bot: dict, run_id: str, meta: dict) -> None:
        with self.lock:
            self.runs[run_id] = bot["id"]
            self.entries[bot["id"]] = self._entry(bot, meta)
            if not self.alive:
                self._open(push_start=True)
            else:
                self._push_update("10")

    def run_update(self, run_id: str, bot: dict, meta: dict) -> None:
        with self.lock:
            cid = self.runs.get(run_id)
            if not cid or not self.alive:
                return
            old = self.entries.get(cid)
            new = self._entry(bot, meta, old)
            if old and old.get("statusLine") == new["statusLine"] and old.get("state") == new["state"]:
                return
            self.entries[cid] = new
            if time.time() - self._last_push >= 4:  # Apple begrenzt die Update-Rate
                self._push_update()
            else:
                self._flush_later()

    def run_finished(self, run_id: str, bot: dict, meta: dict) -> None:
        with self.lock:
            cid = self.runs.pop(run_id, None)
            if not cid or not self.alive:
                return
            if cid not in self.runs.values():
                self.entries[cid] = self._entry(bot, meta, self.entries.get(cid))
            if self._running():
                self._push_update("10")
            else:
                self._close()

    def ensure(self) -> dict:
        """Von der App im Vordergrund: Sitzung sicherstellen, wenn ein Scoop arbeitet (App startet dann lokal)."""
        with self.lock:
            if not self.alive and self._running():
                self._open(push_start=False)
        return self.snapshot()

    def register_token(self, token: str, session: str | None) -> None:
        with self.lock:
            self.p.db.q("INSERT OR REPLACE INTO live_tokens(token,chat_id,run_id,created_at) VALUES(?,?,?,datetime('now'))",
                        (token, "scoops", session))
            self.p.note_token(token, "liveactivity")
            if not (self.alive and session == self.session):
                # Anzeige gehört zu keiner laufenden Sitzung → sofort beenden
                payload = self._end_payload({"scoops": [], "updatedAt": time.time() - APPLE_EPOCH}, 0)
                self.p._spawn([(token, payload)], "liveactivity", LIVE_TOPIC, "10")
                self.p.db.q("DELETE FROM live_tokens WHERE token=?", (token,))

    def sweep(self, busy: set[str] | None = None) -> None:
        with self.lock:
            # Läufe, die ohne Ende abgebrochen sind (Absturz), aus der Liste nehmen
            if busy is not None:
                now = time.time() - APPLE_EPOCH
                for rid, cid in list(self.runs.items()):
                    e = self.entries.get(cid)
                    if cid not in busy and (not e or now - e["startedAt"] > 120):
                        self.runs.pop(rid, None)
                        if e and e["state"] == "running":
                            e.update(state="stopped", finishedAt=now)
                if self.alive and self.runs and not self._running():
                    self._push_update("10")
            # Sitzung offen, aber kein Lauf mehr aktiv (z. B. Fehler) → beenden
            if self.alive and not self.runs:
                for e in self.entries.values():
                    if e["state"] == "running":
                        e["state"] = "stopped"
                self._close()
            if self.ended and time.time() - self.ended[2] > DISMISS_AFTER_S + 30:
                self.ended = None
            # Sitzungen aus früheren Serverläufen (Neustart) beenden; alte Kanäle löschen
            for r in self.p.db.q("SELECT session, channel FROM live_sessions WHERE alive=1 AND session<>?",
                                 (self.session or "",)):
                self._send(r["session"], r["channel"],
                           self._end_payload({"scoops": [], "updatedAt": time.time() - APPLE_EPOCH}, 0), "10")
                self.p.db.q("UPDATE live_sessions SET alive=0, ended_at=datetime('now') WHERE session=?", (r["session"],))
            old = self.p.db.q("SELECT session, channel FROM live_sessions WHERE alive=0 AND ended_at < datetime('now','-30 minutes')")
            for r in old:
                if r["channel"]:
                    try:
                        self.p._channel("DELETE", r["channel"])
                    except Exception:  # noqa: BLE001
                        pass
                self.p.db.q("DELETE FROM live_tokens WHERE run_id=?", (r["session"],))
                self.p.db.q("DELETE FROM live_sessions WHERE session=?", (r["session"],))
            self.p.db.q("DELETE FROM live_tokens WHERE created_at < datetime('now','-1 day')")


class LiveSession:
    """Schnittstelle für einen Lauf (bots.py): update/end gehen an die gemeinsame Anzeige."""

    def __init__(self, board: LiveBoard, chat_id: str, run_id: str):
        self.board = board
        self.chat_id = chat_id
        self.run_id = run_id

    def _bot(self) -> dict | None:
        return self.board.entries.get(self.chat_id)

    def update(self, meta: dict) -> None:
        e = self._bot()
        if e:
            self.board.run_update(self.run_id, e, meta)

    def end(self, meta: dict) -> None:
        e = self._bot() or {"id": self.chat_id, "name": "", "mascot": {}}
        self.board.run_finished(self.run_id, e, meta)
