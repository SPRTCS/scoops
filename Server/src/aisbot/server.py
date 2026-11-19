"""AIS-Bot-Server (FastAPI). Läuft als LaunchAgent auf dem Agenten-Air, nur an 127.0.0.1.

Erreichbar von iPhone/iPad über Tailscale Serve (HTTPS), siehe docs/API.md.
"""

from __future__ import annotations

from datetime import datetime, timezone
import asyncio
import io
import json
import os
import re
import secrets
import subprocess
import threading
import time

from fastapi import Depends, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response
from PIL import Image

from .bots import BotService, load_config, save_config
from .db import DB
from .engine import COMPUTER_URL, USER_HOLDER, ComputerHub
from .nodes import DEAD_AFTER, PING_EVERY, VM_ID, Computers
from .push import Pusher
from . import vault as vault_mod
from .cloud import Cloud
from . import sharing
from .sharing import OWNER, Principal, ShareCache
from .version import VERSION
from . import config, demo, profile
from . import notion_mcp
from . import custom_mcp
from . import workspace
from . import usage_report
from .usage_limits import Limits
from .usage_logs import LogScanner
from .profile import feature, kc

MAX_UPLOAD = 25 * 1024 * 1024
# Größte WebSocket-Nachricht (uvicorn-Standard: 16 MiB). Ein Rechner schickt Dateien bis 25 MB (datei_vom_rechner)
# als Base64 (~33 MB) in einer Nachricht; die Mac-App erlaubt 64 MiB, der Server jetzt auch.
WS_MAX_SIZE = 64 * 1024 * 1024
# Host: Umgebung > config.json `host` („0.0.0.0“ = im lokalen Netz erreichbar, setzt die Mac-App) > nur lokal
HOST = os.environ.get("AISBOT_HOST") or profile._read_config().get("host") or "127.0.0.1"
# Port: Umgebung > config.json `port` (setzt die Mac-App „AIS Scoops Server“) > 8787
PORT = int(os.environ.get("AISBOT_PORT") or profile._read_config().get("port") or 8787)
# Testinstanz: AISBOT_OFFLINE=1 schaltet MCP, VM-Wächter und Initiative ab (siehe Server/tests/test_nodes.py).
OFFLINE = os.environ.get("AISBOT_OFFLINE") == "1"
MODELS = config.MODELS  # wählbare Modelle laut Modellkatalog (folgt einer neueren Fernkopie sofort)
catalog = config.catalog


def _model_param(value) -> str:
    """Modell aus einer Anfrage: abgelöste Kennungen (ältere Apps) → Nachfolger; unbekannt → 400."""
    m = config.resolve_model(str(value or "").strip())
    if m not in MODELS:
        raise HTTPException(400, "Unbekanntes Modell")
    return m


def _keychain(service: str, account: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                       capture_output=True, text=True)
    return r.stdout.strip() or None if r.returncode == 0 else None


def mcp_servers() -> list[dict]:
    """Fest eingebaute MCP-Server und die eigenen MCP-Server des Nutzers (custom_mcp.py, ab 1.35, alle Editionen)."""
    try:
        custom = custom_mcp.instance(load_config, save_config).specs()
    except Exception as e:  # noqa: BLE001
        print("Eigene MCP-Server nicht verfügbar:", e, flush=True)
        custom = []
    return _builtin_mcp_servers() + custom


def _builtin_mcp_servers() -> list[dict]:
    """Composio (Gmail, Notion …), Team App und Atrium, sofern eingerichtet (Team App/Atrium nur mit Funktion)."""
    if OFFLINE:
        return []
    cfg = load_config()
    out = []
    key = _keychain(kc("composio"), "api-key")
    if key and cfg.get("composio_session_id"):
        out.append({"type": "url", "url": f"https://backend.composio.dev/tool_router/{cfg['composio_session_id']}/mcp",
                    "name": "composio", "authorization_token": key})
    try:  # Notion direkt (offizieller Notion-MCP, OAuth pro Server, notion_mcp.py)
        spec = notion_mcp.instance().mcp_spec()
        if spec:
            out.append(spec)
    except Exception as e:  # noqa: BLE001
        print("Notion direkt nicht verfügbar:", e, flush=True)
    if not feature("atrium", cfg) and not feature("teamapp", cfg):
        return out
    tok = _keychain(kc("mcp-teamapp"), "token") if feature("teamapp", cfg) else None
    if tok:
        out.append({"type": "url", "url": "https://mlp-berlin-koeln.vercel.app/api/mcp", "name": "teamapp",
                    "authorization_token": tok})
    if not feature("atrium", cfg):
        return out
    for team in cfg.get("atrium_teams") or []:  # Atrium-Team-Bereiche (Cloud, Remote-MCP)
        ttok = _keychain(kc("atrium-team"), team["account"])
        if ttok:
            out.append({"type": "url", "url": team["url"], "name": team["name"], "authorization_token": ttok})
    # Lokaler Atrium-Vault über die installierte App (`Atrium --mcp`): Die sandboxed App darf ihren
    # iCloud-Vault lesen, ein launchd-Dienst direkt nicht (TCC blockiert dann jeden Dateizugriff).
    at = cfg.get("atrium") or {}
    at_token = _keychain(kc("atrium"), "mcp-token")
    app = at.get("app", "/Applications/Atrium.app/Contents/MacOS/Atrium")
    if at_token and os.path.exists(app):
        env = {"ATRIUM_MCP_TOKEN": at_token}
        at_key = _keychain(kc("atrium"), "api-key")
        if at_key:
            env |= {"ATRIUM_API_KEY": at_key, "ATRIUM_PROVIDER": at.get("provider", "anthropic")}
        out.append({"type": "stdio", "name": "atrium", "command": [app, "--mcp"], "env": env})
    return out


class Hub:
    """Verteilt Ereignisse an alle verbundenen WebSockets (threadsicher). Gäste geteilter Scoops bekommen nur,
    was `guest_filter` für sie durchlässt (umgeformt, siehe guest_event); Standard: nichts."""

    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop | None = None
        self.clients: dict[WebSocket, Principal] = {}
        self.guest_filter = None  # (typ, data, principal) -> (typ, data) | None

    def publish(self, typ: str, data: dict) -> None:
        if not self.loop:
            return
        payload = json.dumps({"type": typ, "data": data}, ensure_ascii=False)
        out: list[tuple[WebSocket, str]] = []
        for ws, p in list(self.clients.items()):
            if p.is_owner:
                out.append((ws, payload))
                continue
            try:
                ev = self.guest_filter(typ, data, p) if self.guest_filter else None
            except Exception as e:  # noqa: BLE001 – im Zweifel nichts an Gäste
                print("WS-Gastfilter-Fehler:", e, flush=True)
                ev = None
            if ev is not None:
                out.append((ws, json.dumps({"type": ev[0], "data": ev[1]}, ensure_ascii=False)))
        if out:
            self.loop.call_soon_threadsafe(lambda: asyncio.ensure_future(self._send(out)))

    def send_user(self, user_id: str, typ: str, data: dict, close_code: int | None = None) -> None:
        """Nur an die Verbindungen eines Gasts (z. B. share.updated); optional danach schließen."""
        if not self.loop:
            return
        targets = [ws for ws, p in list(self.clients.items()) if not p.is_owner and p.user_id == user_id]
        if not targets:
            return
        payload = json.dumps({"type": typ, "data": data}, ensure_ascii=False)

        async def go() -> None:
            for ws in targets:
                try:
                    await ws.send_text(payload)
                    if close_code:
                        self.clients.pop(ws, None)
                        await ws.close(code=close_code)
                except Exception:  # noqa: BLE001
                    self.clients.pop(ws, None)

        self.loop.call_soon_threadsafe(lambda: asyncio.ensure_future(go()))

    async def _send(self, items: list[tuple[WebSocket, str]]) -> None:
        for ws, payload in items:
            try:
                await ws.send_text(payload)
            except Exception:  # noqa: BLE001
                self.clients.pop(ws, None)


def api_token() -> str:
    cfg = load_config()
    if not cfg.get("api_token"):
        cfg["api_token"] = secrets.token_urlsafe(32)
        save_config(cfg)
    return cfg["api_token"]


events = Hub()
db = DB()
computer_hub = ComputerHub(os.environ.get("AISBOT_COMPUTER_URL", COMPUTER_URL))  # Bot-Rechner (VM)
computers = Computers(db, computer_hub)  # + Scoops-Connect-Rechner
pusher = Pusher(db, load_config)
service = BotService(db, computers, events.publish, mcp_servers,
                     user_name=None, pusher=pusher)  # Name dynamisch: config `user_name`, Konto oder „Arman“ (profile.py)
service.custom_mcp = custom_mcp.instance(load_config, save_config)  # eigene MCP-Server (docs/mcp.md)


# Modellkatalog (docs/modelle.md): abgelöste Kennungen in Scoops, Routinen und offenen Aufgaben umstellen – beim Start
# und nach jedem Wechsel auf eine neuere Fernkopie; die Apps laden die Liste dann neu („models.updated“).
def _catalog_changed(_old, new) -> None:
    catalog.remap_db(db, load_config, save_config)
    for b in db.bots():
        bj = service.bot_json(b["id"])
        if bj:
            events.publish("bot.updated", bj)
    events.publish("models.updated", {"version": new.version})


catalog.remap_db(db, load_config, save_config)
catalog.on_change(_catalog_changed)
from .connections import Connections  # noqa: E402

connections = Connections(load_config)
service.connections = connections
from .composio_direct import ComposioDirect  # noqa: E402 – vollständige Composio-Ergebnisse (ab 1.24)

service.mcp_hub.composio_direct = ComposioDirect(connections)
if not OFFLINE:  # Notion direkt in „Apps verbinden“ und in der Systemanweisung (ab 1.25)
    connections.extra_accounts = lambda: [a for a in [notion_mcp.instance().account()] if a]
    connections.extra_prompt = lambda: notion_mcp.PROMPT_HINT if "notion" in service.mcp_hub.servers else None
    notion_mcp.instance().on_change = lambda: service.mcp_hub.configure(mcp_servers())
from .tasks import TaskService, TaskError  # noqa: E402 – Aufgabenmodus (docs/aufgaben.md)

tasks = TaskService(service, PORT)
service.tasks = tasks
service.codex_abo.port = PORT  # Codex-Chat übers ChatGPT-Abo holt die Werkzeuge über /mcp/abo (docs/abos.md)
TOKEN = api_token()


def _startup_cleanup() -> None:
    """Beim Start: Verweise auf entfernte Rechner aufräumen und eine LAN-Adresse (…local/private IP) auf den
    tatsächlichen Port ziehen – die Mac-App weicht auf einen anderen Port aus, wenn der alte belegt ist."""
    try:
        out = computers.cleanup_orphans()
        if out["bots"] or out["default_before"] != out["default_after"]:
            print(f"Rechner aufgeräumt: {len(out['bots'])} Scoop-Verweis(e), Standard "
                  f"{out['default_before']} → {out['default_after']}", flush=True)
    except Exception as e:  # noqa: BLE001
        print("Rechner-Aufräumen fehlgeschlagen:", e, flush=True)
    try:
        cfg = load_config()
        changed = False
        for k in ("public_url", "lan_url"):
            fixed = lan_url_for_port(cfg.get(k) or "", PORT)
            if fixed and fixed != cfg.get(k):
                print(f"{k}: {cfg.get(k)} → {fixed} (Port {PORT})", flush=True)
                cfg[k] = fixed
                changed = True
        if changed:
            save_config(cfg)
    except Exception as e:  # noqa: BLE001
        print("Adress-Korrektur fehlgeschlagen:", e, flush=True)


def lan_url_for_port(url: str, port: int) -> str | None:
    """http://<name>.local:<alt> bzw. http://192.168.x.y:<alt> → gleicher Host mit `port`. Sonst None (z. B. https/Tailscale)."""
    m = re.match(r"^http://([^/:]+)(?::(\d+))?/?$", url or "")
    if not m:
        return None
    host = m.group(1)
    private = host.endswith(".local") or re.match(r"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)", host)
    return f"http://{host}:{port}" if private else None


_startup_cleanup()


def _ensure_workspace() -> None:
    """Arbeitsordner und Unterordner aller Scoops anlegen (docs/arbeitsordner.md). Fehler nur ins Protokoll."""
    try:
        workspace.ensure_all(db.bots(), load_config())
    except Exception as e:  # noqa: BLE001
        print("Arbeitsordner nicht angelegt:", e, flush=True)


threading.Thread(target=_ensure_workspace, daemon=True, name="workspace-ensure").start()
cloud = Cloud(load_config, save_config, VERSION)  # Konto-Kopplung (Convex), siehe cloud.py


def _shared_bot_info(bot_ids: list[str]) -> list[dict]:
    out = []
    for b in bot_ids:
        r = db.bot_row(b)
        if r:
            out.append({"botId": b, "name": r["name"], "mascot": db._mascot_out(r)})
    return out


shares = ShareCache(cloud, _shared_bot_info)  # geteilte Scoops (sharing.py, docs/sharing.md)
service.shares = shares


def _cloud_changed() -> None:
    pusher.reset_mode()  # Push über das Relay hängt an der Kopplung
    if not cloud.owner_id():
        shares.clear()  # ohne Kopplung keine Gäste
    else:
        threading.Thread(target=shares.sync, daemon=True, name="shares-sync").start()


cloud.on_change = _cloud_changed
cloud.on_heartbeat = shares.on_heartbeat
app = FastAPI(title="AIS Scoops", version=VERSION)


@app.middleware("http")
async def demo_guard(request: Request, call_next):
    """Demo-Server (docs/demo-server.md): Einstellungen, die den Mac oder Konten berühren, sind gesperrt."""
    if demo.blocked(request.method, request.url.path):
        return JSONResponse({"error": demo.DISABLED_TEXT}, status_code=403)
    return await call_next(request)


def _given(request_or_ws, token: str | None) -> str | None:
    h = request_or_ws.headers.get("authorization", "")
    return h[7:] if h.lower().startswith("bearer ") else token


def principal_of(given: str | None) -> Principal | None:
    """Bisheriges API-Token oder Sitzungs-JWT des Inhabers → OWNER (alles wie bisher); gültiges Sitzungs-JWT eines
    anderen Kontos → Gast (darf nur, was ein Endpunkt mit `shared(...)` ausdrücklich erlaubt); sonst None."""
    if not given:
        return None
    try:
        if secrets.compare_digest(given.encode(), TOKEN.encode()):
            return OWNER
    except Exception:  # noqa: BLE001
        return None
    claims = cloud.verify_any(given)
    if not claims:
        return None
    if claims["sub"] == cloud.owner_id():
        return OWNER
    return Principal("guest", claims["sub"], claims.get("sid"))


def token_ok(given: str | None) -> bool:
    """Nur Inhaber: API-Token ODER gültiges Sitzungs-JWT des Server-Inhabers (Convex, docs/accounts.md)."""
    p = principal_of(given)
    return p is not None and p.is_owner


FORBIDDEN_GUEST = "Kein Zugriff: Dieser Bereich gehört dem Admin des Servers."


def auth(request: Request, token: str | None = Query(default=None)) -> Principal:
    """Standard für alle Endpunkte: nur der Inhaber. Gäste (geteilte Scoops) → 403, ohne gültiges Token → 401."""
    p = principal_of(_given(request, token))
    if p is None:
        raise HTTPException(401, "Nicht angemeldet")
    if not p.is_owner:
        raise HTTPException(403, FORBIDDEN_GUEST)
    return p


# Woraus ein Endpunkt den betroffenen Scoop ableitet (für die Prüfung des Shares).
def _row_col(sql: str, col: str, param: str):
    def f(request: Request) -> str | None:
        v = request.path_params.get(param)
        r = db.one(sql, (v,)) if v else None
        return r[col] if r and r[col] else None
    return f


BOT_OF = {
    "bot_id": lambda r: r.path_params.get("bot_id"),
    "chat_id": lambda r: r.path_params.get("chat_id"),
    "query": lambda r: r.query_params.get("bot") or r.query_params.get("chat"),
    "mid": _row_col("SELECT bot_id FROM messages WHERE id=?", "bot_id", "mid"),
    "fid": _row_col("SELECT chat_id FROM files WHERE id=?", "chat_id", "fid"),
    "mem_id": _row_col("SELECT bot_id FROM memories WHERE id=?", "bot_id", "mem_id"),  # „für alle“ (NULL) → nie
    "rid": _row_col("SELECT bot_id FROM routines WHERE id=?", "bot_id", "rid"),
    "sid": _row_col("SELECT bot_id FROM skills WHERE id=?", "bot_id", "sid"),
}


def guest_principal(p: Principal, bot_id: str | None, role: str = "read", computer: str | None = None) -> Principal:
    """Prüft den Share eines Gasts für einen Scoop (Rolle, Rechner-Stufe). Ohne passenden Share → 403."""
    if p.is_owner:
        return p
    if not bot_id or not bot_id.startswith("b_"):
        raise HTTPException(403, FORBIDDEN_GUEST)
    sh = shares.share(p.user_id, bot_id)
    if sh is None:
        raise HTTPException(403, "Dieser Scoop ist nicht (mehr) mit dir geteilt.")
    if not sh.allows(role, computer):
        need = f"Rechner-Zugriff „{computer}“" if computer and sh.allows(role) else f"Rolle „{sharing.ROLE_LABEL[role]}“"
        raise HTTPException(403, f"Dafür brauchst du {need}.")
    return p.with_share(sh)


def shared(role: str = "read", computer: str | None = None, via: str = "bot_id"):
    """Markiert einen Endpunkt als für Gäste freigegeben (sonst gilt `auth`: nur Inhaber).
    `via` = woraus der Scoop folgt (BOT_OF), `via="any"` = mindestens ein Share auf diesem Server.
    Der Inhaber darf wie bisher alles; zurückgegeben wird der (geprüfte) Prinzipal."""

    def dep(request: Request, token: str | None = Query(default=None)) -> Principal:
        p = principal_of(_given(request, token))
        if p is None:
            raise HTTPException(401, "Nicht angemeldet")
        if p.is_owner:
            return p
        if via == "any":
            if not shares.for_user(p.user_id):
                raise HTTPException(403, "Mit dir ist auf diesem Server kein Scoop geteilt.")
            return p
        return guest_principal(p, BOT_OF[via](request), role, computer)

    dep.__name__ = f"shared_{role}_{computer or 'x'}_{via}"
    return dep


@app.exception_handler(HTTPException)
async def http_error(_req, exc: HTTPException):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


@app.on_event("startup")
async def startup() -> None:
    events.loop = asyncio.get_running_loop()
    threading.Thread(target=scheduler_loop, daemon=True, name="scheduler").start()
    if not OFFLINE or os.environ.get("AISBOT_TASKS_RECOVER") == "1":
        tasks.recover()  # nach Neustart unterbrochene Aufgaben fortsetzen
    log_scanner.ensure_fresh()  # Nutzungsprotokolle im Hintergrund einlesen (docs/nutzung.md)
    catalog.start_updates()  # Modellkatalog: Fernkopie beim Start und dann täglich (docs/modelle.md)
    if os.environ.get("AISBOT_PARENT_PID"):
        threading.Thread(target=parent_watch, args=(int(os.environ["AISBOT_PARENT_PID"]),), daemon=True,
                         name="parent-watch").start()


def parent_watch(parent: int) -> None:
    """Mac-App „AIS Scoops Server“: Endet die App (auch durch Absturz), beendet sich der Server mit."""
    while True:
        time.sleep(2)
        if os.getppid() != parent:
            print("Mac-App beendet – Server stoppt", flush=True)
            os._exit(0)


def scheduler_loop() -> None:
    from .db import BACKUP_DIR, now

    while True:
        try:
            for r in service.due_routines():
                service.fire_routine(r)
        except Exception as e:  # noqa: BLE001
            print("Planer-Fehler:", e, flush=True)
        try:
            tasks.start_due()  # geplante Aufgaben (Board, `termin`), übersteht Neustarts
        except Exception as e:  # noqa: BLE001
            print("Aufgaben-Planer-Fehler:", e, flush=True)
        computers.release_if_idle()  # Übernahme endet nach 10 Minuten ohne Eingabe
        try:
            cloud.heartbeat_tick()  # alle 60 s, nur wenn mit einem Konto gekoppelt
        except Exception as e:  # noqa: BLE001
            print("Cloud-Fehler:", e, flush=True)
        if OFFLINE:
            time.sleep(15)
            continue
        try:
            initiative_tick()
        except Exception as e:  # noqa: BLE001
            print("Initiative-Fehler:", e, flush=True)
        try:
            # Tägliche Sicherung der Datenbank (14 Tage aufbewahrt), nachts oder falls heute noch keine existiert.
            today = BACKUP_DIR / f"aisbot-{now():%Y-%m-%d}.db"
            if not today.exists() and (now().hour >= 3 or not any(BACKUP_DIR.glob("aisbot-*.db"))):
                print("Sicherung:", db.backup(), flush=True)
        except Exception as e:  # noqa: BLE001
            print("Sicherungs-Fehler:", e, flush=True)
        try:
            pusher.end_stale_live(set(service.runs) | set(service.busy_bots))  # verwaiste Live-Aktivitäten aufräumen
        except Exception as e:  # noqa: BLE001
            print("Live-Aufräum-Fehler:", e, flush=True)
        try:
            vm_watchdog()
        except Exception as e:  # noqa: BLE001
            print("VM-Wächter-Fehler:", e, flush=True)
        time.sleep(15)


# -- Wächter für den Bot-Rechner ----------------------------------------------
_vm_watch = {"last_check": 0.0, "fails": 0, "last_restart": 0.0}


def vm_watchdog() -> None:
    """Prüft jede Minute den computer-server der VM. Ist er 5 Minuten lang nicht erreichbar,
    werden VM und Tunnel über ihre LaunchAgents neu gestartet (höchstens alle 20 Minuten)."""
    w = _vm_watch
    if not feature("vm") or not load_config().get("vm_enabled", True):  # VM bewusst abgeschaltet (Scoops arbeiten direkt am Mac)
        return
    if time.time() - w["last_check"] < 60:
        return
    w["last_check"] = time.time()
    import httpx
    try:
        ok = httpx.get("http://127.0.0.1:18000/status", timeout=8).status_code == 200
    except Exception:  # noqa: BLE001
        ok = False
    if ok:
        w["fails"] = 0
        return
    w["fails"] += 1
    if w["fails"] < 5 or time.time() - w["last_restart"] < 20 * 60:
        return
    uid = os.getuid()
    print("VM-Wächter: Bot-Rechner seit 5 Minuten nicht erreichbar, starte VM und Tunnel neu", flush=True)
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/com.ais-bot.vm"], capture_output=True, timeout=30)
    for _ in range(36):
        time.sleep(5)
        try:
            if httpx.get("http://192.168.64.2:8000/status", timeout=3).status_code == 200:
                break
        except Exception:  # noqa: BLE001
            pass
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/com.ais-bot.vm-tunnel"], capture_output=True, timeout=30)
    w["fails"], w["last_restart"] = 0, time.time()


# -- Initiative des Haupt-Scoops ----------------------------------------------
INITIATIVE_DEFAULT = {"enabled": profile.is_personal(),  # neue Installationen: aus, bis man es in der App einschaltet
                       "times": ["07:30", "12:30", "17:30"], "quiet_start": "22:00", "quiet_end": "07:00"}
INITIATIVE_PROMPT = (
    "Initiative-Check ({zeit}). Schau kurz nach, ohne etwas nach außen auszuführen: überfällige oder heute fällige "
    "To-dos in Notion (Tasks), wichtige ungelesene Mails seit dem letzten Check, offene Freigaben in der App, Termine "
    "heute und morgen (falls ein Kalender verbunden ist). Schreib Arman nur, wenn es etwas gibt, das er jetzt wissen "
    "oder entscheiden sollte: kurz, konkret, höchstens 5 Punkte. {morgen}Gibt es nichts Relevantes, antworte exakt [NICHTS]."
)


def initiative_settings() -> dict:
    try:
        return {**INITIATIVE_DEFAULT, **json.loads(db.setting("initiative") or "{}")}
    except ValueError:
        return dict(INITIATIVE_DEFAULT)


def run_initiative(bot_id: str, zeit: str, first_of_day: bool) -> None:
    morgen = "Beim ersten Check des Tages gern ein kurzes Tages-Briefing (wichtigste 3 Dinge). " if first_of_day else ""
    prompt = INITIATIVE_PROMPT.format(zeit=zeit, morgen=morgen)
    if not feature("personal_hints"):
        prompt = prompt.replace("To-dos in Notion (Tasks)", "To-dos (falls eine To-do-App verbunden ist)")
    from .prompts import personalize
    service.enqueue(bot_id, bot_id, opts={"quiet": True, "prompt": personalize(prompt, service.user_name)})


def initiative_tick() -> None:
    from .db import now

    cfg = initiative_settings()
    p = db.primary_bot()
    if not cfg.get("enabled") or not p:
        return
    n = now()
    hhmm = n.strftime("%H:%M")
    if hhmm not in cfg["times"]:
        return
    qs, qe = cfg.get("quiet_start", "22:00"), cfg.get("quiet_end", "07:00")
    in_quiet = (qs <= hhmm or hhmm < qe) if qs > qe else (qs <= hhmm < qe)
    if in_quiet:
        return
    key = f"{n:%Y-%m-%d} {hhmm}"
    if db.setting("initiative_last") == key:
        return
    db.set_setting("initiative_last", key)
    first = hhmm == sorted(cfg["times"])[0]
    run_initiative(p["id"], hhmm, first)


def bot_or_404(bot_id: str) -> dict:
    b = service.bot_json(bot_id)
    if not b:
        raise HTTPException(404, "Bot nicht gefunden")
    return b


# -- Endpunkte -------------------------------------------------------------
@app.get("/api/health", dependencies=[Depends(auth)])
def health():
    return {"ok": True, "version": VERSION, "user_name": service.user_name, "push_enabled": pusher.enabled,
            "push_mode": pusher.mode(), "active_runs": len(service.runs), "active_tasks": tasks.active_count(),
            "edition": profile.edition(), "usage_details": True, "models_catalog": catalog.status()["version"]}


def close_interrupted_runs() -> None:
    """Statuszeilen, die beim letzten Neustart mitten im Lauf waren, als angehalten markieren
    (sonst zeigt die App sie für immer als „arbeitet … Live“)."""
    from .db import now_iso
    for r in db.q("SELECT id, meta FROM messages WHERE role='status' AND meta LIKE '%\"state\": \"running\"%'"):
        meta = json.loads(r["meta"])
        if meta.get("state") == "running":
            meta.update(state="stopped", finished_at=meta.get("finished_at") or now_iso(), interrupted=True)
            db.update_message(r["id"], meta=meta)


close_interrupted_runs()


WELCOME_SCOOP = {
    "name": "Pip", "label": "Start", "section": None, "pinned": True,
    "mascot": {"shape": "bean", "color": "#FF8FB1", "eyes": "dots", "accessory": "none"},
    "character": "fröhlich, geduldig und neugierig; erklärt einfach und ohne Fachbegriffe",
}
WELCOME_TEXT = (
    "Hallo! Ich bin **Pip**, dein erster Scoop. 🍦\n\n"
    "Scoops sind kleine Helfer, die für dich recherchieren, Texte schreiben, an Dinge erinnern und – wenn du willst – "
    "an deinem Mac klicken und tippen. Probier zum Beispiel:\n"
    "- „Erinnere mich morgen um 9 an den Zahnarzt“\n"
    "- „Such mir drei Rezepte mit Kürbis“\n"
    "- „Merk dir: Ich trinke keinen Kaffee“\n\n"
    "Weitere Scoops legst du mit **+** an, jeder mit eigenem Charakter. Wobei soll ich dir helfen?"
)


def seed_fresh_install() -> None:
    """Neue Installation (Edition „standard“): ein Start-Scoop zum Kennenlernen – ohne KI-Aufruf, damit es auch
    vor dem Hinterlegen eines API-Schlüssels klappt. Läuft nur einmal (Einstellung `seeded`)."""
    if profile.is_personal() or db.setting("seeded") or db.bots():
        return
    from .db import now_iso
    bid = db.create_bot(model="claude-haiku-5-5", escalation_model="claude-sonnet-5-5", **WELCOME_SCOOP)
    db.set_primary(bid)
    db.add_message(bid, "bot", WELCOME_TEXT, {})
    db.set_setting("seeded", now_iso())
    db.set_setting("seed_bot", bid)
    print("Neue Installation: Start-Scoop angelegt", flush=True)


seed_fresh_install()


# -- Gast-Ansichten (geteilte Scoops) ----------------------------------------------------
_server_name: list[str] = []


def server_display_name() -> str:
    cfg = load_config()
    if cfg.get("server_name"):
        return cfg["server_name"]
    if not _server_name:
        from .cloud import server_name
        _server_name.append(server_name())
    return _server_name[0]


def guest_msg(m: dict | None, sh) -> dict | None:
    return sharing.guest_message(m, sh, service.user_name) if m else None


def guest_bot_view(bot_id: str, sh, b: dict | None = None) -> dict | None:
    b = b or service.bot_json(bot_id)
    if not b:
        return None
    return sharing.guest_bot(b, sh, owner_name=service.user_name, server_name=server_display_name(),
                             owner_id=cloud.owner_id(), unread=db.guest_unread(sh.user_id, bot_id),
                             last_message=guest_msg(b.get("last_message"), sh))


def guest_event(typ: str, data: dict, p: Principal):
    """WebSocket-Filter für Gäste: nur Ereignisse geteilter Scoops, umgeformt wie die REST-Antworten. None = nicht senden."""
    def share_for(bot_id):
        return shares.share(p.user_id, bot_id, refresh_on_miss=False) if bot_id else None

    if typ in ("message.created", "message.updated"):
        sh = share_for(data.get("bot_id"))
        return (typ, guest_msg(data, sh)) if sh else None
    if typ == "bot.updated":
        sh = share_for(data.get("id"))
        return (typ, guest_bot_view(sh.bot_id, sh, data)) if sh else None
    if typ == "bot.typing":
        return (typ, data) if share_for(data.get("chat_id")) else None
    if typ == "routine.updated":
        sh = share_for(data.get("bot_id"))
        return (typ, data) if sh and sh.allows("edit") else None
    if typ == "skill.updated":
        sh = share_for(data.get("bot_id"))
        return (typ, data) if sh and sh.allows("edit") else None
    if typ in ("computer.updated", "node.updated"):
        node = data.get("node_id") if typ == "computer.updated" else data.get("id")
        for sh in shares.for_user(p.user_id, refresh_on_miss=False):
            b = service.bot_json(sh.bot_id)
            if b and sh.allows("read", "view") and b.get("computer_node") == node:
                d = dict(data)
                d.pop("apple", None)  # Apple-Freigaben des Admins gehen Gäste nichts an
                if typ == "computer.updated" and d.get("bot_id") and not share_for(d["bot_id"]):
                    d["bot_id"] = None  # anderer (nicht geteilter) Scoop des Admins arbeitet
                return (typ, d)
        return None
    return None  # Gruppen, Bereiche, Rechner-Verwaltung, Fähigkeiten löschen … nie an Gäste


events.guest_filter = guest_event


def _shares_changed(users: set[str], bots: set[str]) -> None:
    """Nach dem Neuladen der Shares: Gäste informieren (bzw. trennen) und Admin-Ansicht der Scoops aktualisieren."""
    for uid in users:
        mine = shares.for_user(uid, refresh_on_miss=False)
        data = {"shares": [{"bot_id": s.bot_id, "share_id": s.share_id, "role": s.role, "computer": s.computer} for s in mine]}
        events.send_user(uid, "share.updated", data, close_code=None if mine else 4403)
    for b in bots:
        bj = service.bot_json(b)
        if bj:
            events.publish("bot.updated", bj)


shares.on_change = _shares_changed


@app.get("/api/shared/me")
def shared_me(p: Principal = Depends(shared(via="any"))):
    """Wer bin ich auf diesem Server? Gast: eigene Shares (lädt bei leerem Cache einmal neu)."""
    base = {"server_name": server_display_name(), "owner_name": service.user_name, "version": VERSION}
    if p.is_owner:
        return {"role": "owner", "user_id": cloud.owner_id(), "name": service.user_name, **base, "shares": []}
    mine = shares.for_user(p.user_id)
    return {"role": "guest", "user_id": p.user_id, "name": shares.name_of(p.user_id), **base,
            "shares": [{"bot_id": s.bot_id, "share_id": s.share_id, "role": s.role, "computer": s.computer} for s in mine]}


@app.post("/api/shared/devices")
def shared_register_device(body: dict, p: Principal = Depends(shared(via="any"))):
    """Push-Token eines Gasts (getrennt von /api/devices des Inhabers)."""
    if p.is_owner:
        raise HTTPException(400, "Für den Inhaber: POST /api/devices")
    tok = str(body.get("apns_token") or "").strip()
    if not re.fullmatch(r"[0-9a-fA-F]{32,400}", tok):
        raise HTTPException(400, "apns_token fehlt oder ist ungültig")
    platform = str(body.get("platform") or "ios")[:20]
    if platform not in ("ios", "ipados", "macos", "visionos"):
        raise HTTPException(400, "platform: ios, ipados, macos oder visionos")
    if db.one("SELECT 1 FROM devices WHERE token=?", (tok,)):
        raise HTTPException(409, "Dieses Gerät ist schon als Gerät des Inhabers gemeldet")
    db.q("INSERT OR REPLACE INTO guest_devices(token,user_id,platform,name,created_at) VALUES(?,?,?,?,datetime('now'))",
         (tok, p.user_id, platform, str(body.get("name") or "")[:100]))
    pusher.note_guest_token(tok, platform, p.user_id)
    return {"ok": True, "push_enabled": pusher.enabled}


@app.delete("/api/shared/devices")
def shared_delete_device(body: dict, p: Principal = Depends(shared(via="any"))):
    if p.is_owner:
        raise HTTPException(400, "Für den Inhaber nicht vorgesehen")
    db.q("DELETE FROM guest_devices WHERE token=? AND user_id=?", (str(body.get("apns_token") or ""), p.user_id))
    return {"ok": True}


@app.post("/api/shares/refresh", dependencies=[Depends(auth)])
def shares_refresh():
    """Admin-App nach einer Änderung in Convex: Shares sofort neu laden."""
    ok = shares.sync()
    if not ok:
        raise HTTPException(502, shares.last_error or "Shares konnten nicht geladen werden (Server nicht gekoppelt?)")
    return {"ok": True, "shares": len(shares.shares), "version": shares.version}


@app.get("/api/bots/{bot_id}/sharing", dependencies=[Depends(auth)])
def get_sharing(bot_id: str):
    bot_or_404(bot_id)
    st = service.guest_settings(bot_id)
    apps = []
    try:
        from .connections import NAMES
        seen = set()
        for a in connections.accounts():
            if a.get("status") == "active" and a["app"] not in seen:
                seen.add(a["app"])
                apps.append({"id": a["app"], "name": NAMES.get(a["app"], a["app"].title())})
    except Exception:  # noqa: BLE001 – Composio nicht eingerichtet/erreichbar
        pass
    from .mcp_client import LABELS
    mcp = [{"id": n, "name": {"teamapp": "Team App", "atrium": "Atrium", "notion": "Notion (direkt)"}.get(n)
            or LABELS.get(n) or n.replace("_", " ").title()}
           for n in service.mcp_hub.servers if n != "composio"]
    return {**st, "members": [s.public() for s in shares.for_bot(bot_id)],
            "options": {"web": True, "computer": True, "apps": apps, "mcp": mcp, "phone": feature("lucy"),
                        "mail": bool(getattr(service, "connections", None))}}


@app.patch("/api/bots/{bot_id}/sharing", dependencies=[Depends(auth)])
def patch_sharing(bot_id: str, body: dict):
    bot_or_404(bot_id)
    service.set_guest_settings(bot_id, body)
    b = bot_or_404(bot_id)
    events.publish("bot.updated", b)
    return get_sharing(bot_id)


@app.get("/api/bots/{bot_id}/usage")
def bot_usage(bot_id: str, p: Principal = Depends(shared("read"))):
    """Kosten eines Scoops pro Person (Admin: alle; Gast: nur eigene Zeile und eigenes Limit)."""
    bot_or_404(bot_id)
    rows = db.usage_by_person(bot_id)
    owner = cloud.owner_id()
    budget = service.guest_settings(bot_id)["guest_budget"]
    zero = {"today_usd": 0.0, "month_usd": 0.0, "total_usd": 0.0}
    people = []
    admin = {k: round(sum(v[k] for u, v in rows.items() if not u or u == owner), 4) for k in zero}
    people.append({"user_id": None, "name": service.user_name, "is_owner": True, **admin})
    for s in shares.for_bot(bot_id):
        r = rows.get(s.user_id, zero)
        people.append({"user_id": s.user_id, "name": s.name, "is_owner": False, "role": s.role, **r,
                       "budget_left_usd": round(max(0.0, budget - db.guest_spent_today(s.user_id)), 4)})
    for u, r in rows.items():  # frühere Gäste (Share entfernt) mit Kosten
        if u and u != owner and not any(x["user_id"] == u for x in people):
            people.append({"user_id": u, "name": "Ehemaliger Gast", "is_owner": False, "role": None, **r})
    if not p.is_owner:
        people = [x for x in people if x["user_id"] == p.user_id]
    tot = {k: round(sum(x[k] for x in people), 4) for k in zero}
    return {"bot_id": bot_id, **tot, "guest_budget": budget, "by_person": people}


@app.get("/api/bots")
def list_bots(p: Principal = Depends(shared(via="any"))):
    if p.is_owner:
        return service.bots_json()
    return [v for v in (guest_bot_view(s.bot_id, s) for s in shares.for_user(p.user_id)) if v]


@app.post("/api/bots", dependencies=[Depends(auth)])
async def create_bot(body: dict):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "Der Bot braucht einen Namen")
    if body.get("model"):
        body["model"] = _model_param(body["model"])
    fields = {k: body[k] for k in ("name", "label", "mascot", "character", "model", "section", "pinned") if k in body}
    fields["name"] = name
    return await asyncio.to_thread(service.create_bot, fields)


@app.get("/api/bots/{bot_id}")
def get_bot(bot_id: str, p: Principal = Depends(shared("read"))):
    b = bot_or_404(bot_id)
    return b if p.is_owner else guest_bot_view(bot_id, p.share, b)


@app.patch("/api/bots/{bot_id}")
def patch_bot(bot_id: str, body: dict, p: Principal = Depends(shared("edit"))):
    bot_or_404(bot_id)
    old_name = db.bot_row(bot_id)["name"]
    if not p.is_owner:
        extra = set(body) - sharing.GUEST_EDITABLE
        if extra:
            raise HTTPException(403, f"Nur der Admin darf ändern: {', '.join(sorted(extra))}")
        db.update_bot(bot_id, body)
        _workspace_renamed(bot_id, old_name)
        b = bot_or_404(bot_id)
        events.publish("bot.updated", b)
        return guest_bot_view(bot_id, p.share, b)
    if "guest_tools" in body or "guest_budget" in body:
        service.set_guest_settings(bot_id, body)
    if "primary" in body:
        old = db.primary_bot()
        db.set_primary(bot_id if body["primary"] else None)
        if old and old["id"] != bot_id:
            events.publish("bot.updated", bot_or_404(old["id"]))
    if body.get("model"):
        body["model"] = _model_param(body["model"])
    if body.get("computer_node") and not computers.get(body["computer_node"]):
        raise HTTPException(400, "Unbekannter Rechner")
    if isinstance(body.get("computer_access"), dict):
        # Rechner-Zugriff (1.29, docs/rechnerzugriff.md): Modus und Standard-Bereich, nur der Admin
        from . import access as access_mod
        try:
            db.set_access(bot_id, access_mod.merge(db.access_of(db.bot_row(bot_id)),
                                                   access_mod.validate(body["computer_access"])))
        except access_mod.AccessError as e:
            raise HTTPException(400, str(e)) from None
    db.update_bot(bot_id, body)
    _workspace_renamed(bot_id, old_name)
    b = bot_or_404(bot_id)
    events.publish("bot.updated", b)
    return b


def _workspace_renamed(bot_id: str, old_name: str) -> None:
    """Scoop umbenannt → Ordner im Arbeitsordner mit umbenennen (docs/arbeitsordner.md)."""
    r = db.bot_row(bot_id)
    if r and r["name"] != old_name:
        res = workspace.rename_bot(load_config(), bot_id, old_name, r["name"])
        print(f"Arbeitsordner: {old_name} → {r['name']}: {res}", flush=True)


@app.delete("/api/bots/{bot_id}", dependencies=[Depends(auth)])
def delete_bot(bot_id: str):
    bot_or_404(bot_id)
    service.delete_bot(bot_id)
    return {"ok": True}


@app.get("/api/bots/{bot_id}/messages")
def get_messages(bot_id: str, before: str | None = None, limit: int = 50, p: Principal = Depends(shared("read"))):
    bot_or_404(bot_id)
    msgs = db.messages(bot_id, before, max(1, min(limit, 200)))
    return msgs if p.is_owner else [guest_msg(m, p.share) for m in msgs]


@app.post("/api/bots/{bot_id}/messages")
def post_message(bot_id: str, body: dict, p: Principal = Depends(shared("write"))):
    bot_or_404(bot_id)
    m = _post(bot_id, body, guest=p.share)
    return m if p.is_owner else guest_msg(m, p.share)


def _post(chat_id: str, body: dict, guest=None):
    text = (body.get("text") or "").strip()
    file_ids = body.get("file_ids") or []
    if not text and not file_ids:
        raise HTTPException(400, "Leere Nachricht")
    if not isinstance(file_ids, list):
        raise HTTPException(400, "file_ids muss eine Liste sein")
    # reply_to: ID einer Nachricht desselben Chats (sonst ignoriert, siehe BotService.reply_ref)
    # task: Optionen des Aufgaben-Chips im Eingabefeld (1.22) für „/aufgabe …“: {"model": …, "scheduled_at": …}
    opts = body.get("task") if isinstance(body.get("task"), dict) and not guest else None
    return service.post_user_message(chat_id, text, voice=bool(body.get("voice")), file_ids=file_ids, guest=guest,
                                     reply_to=body.get("reply_to"), task_options=opts)


@app.post("/api/bots/{bot_id}/stop")
def stop_bot(bot_id: str, p: Principal = Depends(shared("write"))):
    service.stop(bot_id)
    return {"ok": True}


@app.post("/api/bots/{bot_id}/read")
def read_bot(bot_id: str, p: Principal = Depends(shared("read"))):
    if not p.is_owner:
        bot_or_404(bot_id)
        db.guest_mark_read(p.user_id, bot_id)  # Lesestatus pro Gast, der des Admins bleibt
        events.send_user(p.user_id, "bot.updated", guest_bot_view(bot_id, p.share))
        return {"ok": True}
    db.q("UPDATE bots SET unread=0 WHERE id=?", (bot_id,))
    pusher.badge_changed()
    events.publish("bot.updated", bot_or_404(bot_id))
    return {"ok": True}


@app.post("/api/bots/{bot_id}/reset", dependencies=[Depends(auth)])
def reset_bot(bot_id: str):
    bot_or_404(bot_id)
    service.stop(bot_id)
    db.q("DELETE FROM messages WHERE bot_id=?", (bot_id,))
    db.q("DELETE FROM search_fts WHERE bot_id=? AND kind='nachricht'", (bot_id,))
    events.publish("bot.updated", bot_or_404(bot_id))
    return {"ok": True}


@app.get("/api/bots/{bot_id}/memories")
def get_memories(bot_id: str, p: Principal = Depends(shared("edit"))):
    mems = db.memories(bot_id)
    return mems if p.is_owner else [m for m in mems if m["bot_id"] == bot_id]  # „für alle Scoops“ nur Admin


@app.delete("/api/memories/{mem_id}")
def delete_memory(mem_id: str, p: Principal = Depends(shared("edit", via="mem_id"))):
    db.delete_memory(mem_id)
    return {"ok": True}


@app.get("/api/bots/{bot_id}/routines")
def get_routines(bot_id: str, p: Principal = Depends(shared("edit"))):
    return db.routines(bot_id)


@app.patch("/api/routines/{rid}")
def patch_routine(rid: str, body: dict, p: Principal = Depends(shared("edit", via="rid"))):
    if "model" in body:
        # Eigenes Modell der Routine (null / "" = wie der Scoop); kostet den Admin Geld, darum nur der Admin
        if not p.is_owner:
            raise HTTPException(403, "Nur der Admin darf ändern: model")
        model = _model_param(body["model"]) if body["model"] else None
        if not db.one("SELECT 1 FROM routines WHERE id=?", (rid,)):
            raise HTTPException(404, "Routine nicht gefunden")
        db.q("UPDATE routines SET model=? WHERE id=?", (model, rid))
    if "enabled" in body:
        db.q("UPDATE routines SET enabled=? WHERE id=?", (int(bool(body["enabled"])), rid))
    r = db.one("SELECT * FROM routines WHERE id=?", (rid,))
    if not r:
        raise HTTPException(404, "Routine nicht gefunden")
    d = db.routine_dict(r)
    events.publish("routine.updated", d)
    return d


@app.delete("/api/routines/{rid}")
def delete_routine(rid: str, p: Principal = Depends(shared("edit", via="rid"))):
    db.q("DELETE FROM routines WHERE id=?", (rid,))
    return {"ok": True}


@app.post("/api/routines/{rid}/run", dependencies=[Depends(auth)])
def run_routine(rid: str):
    r = db.one("SELECT * FROM routines WHERE id=?", (rid,))
    if not r:
        raise HTTPException(404, "Routine nicht gefunden")
    service.fire_routine(db.routine_dict(r))
    return {"ok": True}


@app.get("/api/bots/{bot_id}/standing-approvals", dependencies=[Depends(auth)])
def get_standing_approvals(bot_id: str):
    """Dauerhafte Freigaben („Immer erlauben“) eines Scoops – nur der Admin."""
    bot_or_404(bot_id)
    return service.standing_approvals(bot_id)


@app.delete("/api/bots/{bot_id}/standing-approvals/{sid}", dependencies=[Depends(auth)])
def delete_standing_approval(bot_id: str, sid: str):
    if not service.delete_standing(bot_id, sid):
        raise HTTPException(404, "Dauerhafte Freigabe nicht gefunden")
    return {"ok": True}


@app.post("/api/approvals/{aid}", dependencies=[Depends(auth)])
def decide(aid: str, body: dict):
    if body.get("decision") not in ("approve", "decline", "approve_always"):
        raise HTTPException(400, "decision muss approve, decline oder approve_always sein")
    try:
        return service.decide(aid, body["decision"], body.get("note"), body.get("edits"))
    except KeyError as e:
        raise HTTPException(404, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


# -- Aufgabenmodus (docs/aufgaben.md) ---------------------------------------------------------------------------
@app.get("/api/bots/{bot_id}/tasks", dependencies=[Depends(auth)])
def list_tasks(bot_id: str):
    return tasks.list(bot_id)


@app.post("/api/bots/{bot_id}/tasks", dependencies=[Depends(auth)])
def start_task(bot_id: str, body: dict):
    """Aufgabe ausdrücklich starten. In Gruppen (g_…) ist `actor_id` der arbeitende Scoop."""
    prompt = str(body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(400, "prompt fehlt")
    actor = body.get("actor_id") or bot_id
    if not service.chat_exists(bot_id) or not db.bot_row(actor):
        raise HTTPException(404, "Chat oder Scoop nicht gefunden")
    from .bots import _task_title
    try:
        return tasks.start(bot_id, actor, str(body.get("title") or _task_title(prompt)), prompt, origin="user",
                           budget_usd=body.get("budget_usd"), max_minutes=body.get("max_minutes"),
                           model=body.get("model"), scheduled_at=body.get("scheduled_at"),
                           access=body.get("access") if isinstance(body.get("access"), dict) else None)
    except TaskError as e:
        raise HTTPException(400, str(e)) from e


@app.get("/api/tasks", dependencies=[Depends(auth)])
def all_tasks(limit: int = 30, bot: str | None = None, chat: str | None = None, column: str | None = None):
    """Board (1.22): alle Aufgaben über alle Scoops, neueste zuerst. `column` = planned,active,review,done,archived
    (kommagetrennt), `bot` = arbeitender Scoop, `chat` = Chat. Nur der Admin (Gäste: 403)."""
    cols = [c.strip() for c in (column or "").split(",") if c.strip()]
    return tasks.list(chat, limit=max(1, min(limit, 500)), bot_id=bot, columns=cols or None)


@app.post("/api/tasks", dependencies=[Depends(auth)])
def create_task(body: dict):
    """Board (1.22): Aufgabe anlegen. Ohne `scheduled_at` startet sie sofort, sonst landet sie unter „Geplant“;
    `backlog: true` (1.23) sammelt sie nur unter „Offen“ (startet erst auf Wunsch).
    Felder: chat_id (Pflicht), actor_id (Pflicht in Gruppen), prompt, title, model (null/"wie_scoop" = wie Scoop)."""
    chat_id = str(body.get("chat_id") or body.get("actor_id") or "").strip()
    prompt = str(body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(400, "prompt fehlt")
    actor = str(body.get("actor_id") or chat_id)
    if not chat_id or not service.chat_exists(chat_id) or not db.bot_row(actor):
        raise HTTPException(404, "Chat oder Scoop nicht gefunden")
    if chat_id.startswith("g_") and actor not in ((service.group_json(chat_id) or {}).get("member_ids") or []):
        raise HTTPException(400, "Der Scoop ist kein Mitglied dieser Gruppe")
    from .bots import _task_title
    try:
        return tasks.start(chat_id, actor, str(body.get("title") or "").strip() or _task_title(prompt), prompt,
                           origin="board", model=body.get("model"), scheduled_at=body.get("scheduled_at"),
                           backlog=bool(body.get("backlog")),
                           access=body.get("access") if isinstance(body.get("access"), dict) else None)
    except TaskError as e:
        raise HTTPException(400, str(e)) from e


@app.get("/api/tasks/settings", dependencies=[Depends(auth)])
def task_settings():
    from .tasks import settings as task_cfg
    blocked = time.time() < tasks._codex_blocked_until
    return {**task_cfg(), "codex_available": not blocked, "codex_blocked_reason": tasks._codex_block_reason if blocked else None}


@app.patch("/api/tasks/settings", dependencies=[Depends(auth)])
def patch_task_settings(body: dict):
    from .tasks import DEFAULTS, settings as task_cfg
    cfg = load_config()
    for k in DEFAULTS:
        if k in body:
            v = body[k]
            if k == "task_mode" and not (v in ("all", "off") or (isinstance(v, list) and all(isinstance(x, str) for x in v))):
                raise HTTPException(400, "task_mode: \"all\", \"off\" oder Liste von Scoop-IDs")
            if k == "task_openai_engine" and v not in ("auto", "codex", "responses"):
                raise HTTPException(400, "task_openai_engine: auto, codex oder responses")
            cfg[k] = v
    save_config(cfg)
    return task_cfg(cfg)


@app.get("/api/tasks/{task_id}", dependencies=[Depends(auth)])
def get_task(task_id: str):
    """Eine Aufgabe mit Schritt-Verlauf (`lines`) und Ergebnisdateien (`file_items`)."""
    t = tasks.row(task_id)
    if not t:
        raise HTTPException(404, "Aufgabe nicht gefunden")
    return tasks.public(t, detail=True)


def _task_call(task_id: str, fn):
    if not tasks.row(task_id):
        raise HTTPException(404, "Aufgabe nicht gefunden")
    try:
        out = fn()
    except TaskError as e:
        raise HTTPException(409, str(e)) from e
    return tasks.public(tasks.row(task_id), detail=True) if isinstance(out, dict) else out


@app.patch("/api/tasks/{task_id}", dependencies=[Depends(auth)])
def patch_task(task_id: str, body: dict):
    """Offene oder geplante Aufgabe ändern: title, prompt, model (null/"wie_scoop" = wie Scoop), scheduled_at (plant ein),
    backlog: true (zurück nach „Offen“)."""
    return _task_call(task_id, lambda: tasks.update_planned(task_id, body))


@app.delete("/api/tasks/{task_id}", dependencies=[Depends(auth)])
def delete_task(task_id: str):
    """Nur offene oder geplante Aufgaben (erledigte archivieren)."""
    _task_call(task_id, lambda: tasks.delete_planned(task_id))
    return {"ok": True}


@app.post("/api/tasks/{task_id}/start", dependencies=[Depends(auth)])
def start_planned_task(task_id: str):
    return _task_call(task_id, lambda: tasks.start_now(task_id))


@app.post("/api/tasks/{task_id}/accept", dependencies=[Depends(auth)])
def accept_task(task_id: str):
    return _task_call(task_id, lambda: tasks.accept(task_id))


@app.post("/api/tasks/{task_id}/rework", dependencies=[Depends(auth)])
def rework_task(task_id: str, body: dict | None = None):
    return _task_call(task_id, lambda: tasks.rework(task_id, str((body or {}).get("message") or "")))


@app.post("/api/tasks/{task_id}/archive", dependencies=[Depends(auth)])
def archive_task(task_id: str):
    return _task_call(task_id, lambda: tasks.archive(task_id))


@app.post("/api/tasks/{task_id}/restore", dependencies=[Depends(auth)])
def restore_task(task_id: str):
    return _task_call(task_id, lambda: tasks.restore(task_id))


@app.post("/api/tasks/{task_id}/stop", dependencies=[Depends(auth)])
def stop_task(task_id: str):
    t = tasks.stop(task_id)
    if not t:
        raise HTTPException(404, "Aufgabe nicht gefunden")
    return t


@app.post("/api/tasks/{task_id}/continue", dependencies=[Depends(auth)])
def continue_task(task_id: str, body: dict | None = None):
    try:
        return tasks.continue_task(task_id, str((body or {}).get("message") or "Mach weiter, wo du aufgehört hast."))
    except TaskError as e:
        raise HTTPException(400, str(e)) from e


@app.post("/mcp/task")
async def task_mcp(request: Request):
    """MCP (Streamable HTTP, nur JSON-Antworten) für die Agent-SDKs einer laufenden Aufgabe. Token gilt nur für diesen Lauf.
    GET (SSE-Strom) und DELETE gibt es nicht: FastAPI antwortet 405, das erlaubt die MCP-Spezifikation."""
    auth_h = request.headers.get("authorization") or ""
    token = auth_h[7:].strip() if auth_h.lower().startswith("bearer ") else None
    try:
        payload = await request.json()
    except ValueError:
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, status_code=400)
    code, out = await asyncio.to_thread(tasks.mcp, token, payload)
    if out is None:
        return Response(status_code=code)
    return JSONResponse(out, status_code=code)


@app.post("/mcp/abo")
async def abo_mcp(request: Request):
    """MCP für Codex-Chat-Läufe über das ChatGPT-Abo (engine_abo.CodexChatEngine). Token gilt pro Codex-Prozess."""
    from .engine_abo import mcp_handle
    auth_h = request.headers.get("authorization") or ""
    token = auth_h[7:].strip() if auth_h.lower().startswith("bearer ") else None
    try:
        payload = await request.json()
    except ValueError:
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, status_code=400)
    code, out = await asyncio.to_thread(mcp_handle, token, payload)
    if out is None:
        return Response(status_code=code)
    return JSONResponse(out, status_code=code)


# -- KI-Abos (docs/abos.md) ----------------------------------------------------------------
def _abos_patch(body: dict) -> dict:
    from . import abos
    if "codex_computer_use" in body:  # Computer Use von Codex an/aus (codex_cu.py, ab 1.36)
        v = body["codex_computer_use"]
        if isinstance(v, dict):
            v = v.get("enabled")
        if not isinstance(v, bool):
            raise HTTPException(400, "codex_computer_use: true oder false")
        from . import codex_cu
        codex_cu.set_setting(v)
    for p in abos.PROVIDERS:
        if p in body:
            v = body[p]
            if isinstance(v, dict):
                v = v.get("mode")
            if v not in abos.MODES:
                raise HTTPException(400, f"{p}: api, abo oder abo_api")
            abos.set_mode(p, v)
    return abos.status()


def _abos_login(provider: str) -> dict:
    from . import abos
    if provider not in abos.PROVIDERS:
        raise HTTPException(404, "Anbieter claude oder openai")
    try:
        out = abos.start_login(provider)
    except RuntimeError as e:
        raise HTTPException(400, str(e)) from e
    return {**out, "status": abos.status()}


@app.get("/api/settings/abos", dependencies=[Depends(auth)])
def get_abos(refresh: bool = False):
    from . import abos
    return abos.status(refresh=refresh)


@app.patch("/api/settings/abos", dependencies=[Depends(auth)])
def patch_abos(body: dict):
    return _abos_patch(body)


@app.post("/api/settings/abos/{provider}/login", dependencies=[Depends(auth)])
def abos_login(provider: str):
    """Öffnet auf dem Server-Mac ein Terminal mit dem offiziellen Login des Programms (der Nutzer meldet sich dort an)."""
    return _abos_login(provider)


@app.put("/api/messages/{mid}/reaction")
def put_reaction(mid: str, body: dict, p: Principal = Depends(shared("write", via="mid"))):
    emoji = (body.get("emoji") or "").strip() or None
    if emoji and len(emoji) > 8:
        raise HTTPException(400, "Nur ein Emoji")
    try:
        m = service.set_reaction(mid, "user" if p.is_owner else f"user:{p.user_id}", emoji)
    except KeyError as e:
        raise HTTPException(404, str(e)) from e
    return m if p.is_owner else guest_msg(m, p.share)


def hub_or_404(node: str | None):
    if (not node or node == VM_ID) and not feature("vm"):
        node = computers.default_id()  # ohne VM-Bot-Rechner: „Bot-Rechner“ der App = Standard-Rechner
    hub = computers.get(node or VM_ID)
    if not hub:
        raise HTTPException(404, "Rechner nicht gefunden")
    return hub


def node_for(p: Principal, request: Request, node: str) -> str:
    """Gäste sehen nur den Rechner ihres geteilten Scoops (`?bot=`); ein anderer `node` → 403."""
    if p.is_owner:
        return node
    b = service.bot_json(p.share.bot_id)
    mine = (b or {}).get("computer_node") or VM_ID
    if "node" in request.query_params and request.query_params["node"] != mine:
        raise HTTPException(403, "Dieser Rechner gehört nicht zu deinem geteilten Scoop.")
    return mine


def guest_computer_state(p: Principal, st: dict) -> dict:
    if not p.is_owner and st.get("bot_id") and not shares.share(p.user_id, st["bot_id"], refresh_on_miss=False):
        st = {**st, "bot_id": None}
    return st


@app.get("/api/computer")
async def computer_state(request: Request, node: str = VM_ID,
                         p: Principal = Depends(shared("read", computer="view", via="query"))):
    node = node_for(p, request, node)
    return guest_computer_state(p, await asyncio.to_thread(hub_or_404(node).state))


_screen_caches: dict[str, dict] = {}


@app.get("/api/computer/screen.jpg")
async def computer_screen(request: Request, scale: float = 1.0, q: int = 60, node: str = VM_ID,
                          p: Principal = Depends(shared("read", computer="view", via="query"))):
    """Bildschirm eines Rechners als JPEG. `scale` (0.25–1) und `q` (20–90) sparen Daten bei schlechtem Netz."""
    hub = hub_or_404(node_for(p, request, node))
    cache = _screen_caches.setdefault(hub.node_id, {"t": 0.0, "img": None})
    max_age = 0.3 if hub.holder == USER_HOLDER else 1.0  # beim Übernehmen flüssiger
    if time.time() - cache["t"] > max_age or cache["img"] is None:
        def grab():
            png = hub.computer.screenshot_png()
            return Image.open(io.BytesIO(png)).convert("RGB")
        try:
            cache["img"] = await asyncio.to_thread(grab)
            cache["t"] = time.time()
        except Exception as e:  # noqa: BLE001
            label = "Bot-Rechner" if hub.node_id == VM_ID else f"Rechner „{hub.name}“"
            raise HTTPException(503, f"{label} nicht erreichbar: {e}") from e
    im = cache["img"]
    scale = min(max(scale, 0.25), 1.0)
    if scale < 1.0:
        im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=min(max(q, 20), 90), optimize=True)
    return Response(buf.getvalue(), media_type="image/jpeg", headers={"Cache-Control": "no-store"})


# -- Diktat (OpenAI) ---------------------------------------------------------
TRANSCRIBE_MODEL = "gpt-transcribe"


_guest_dictation: dict[tuple[str, str], int] = {}
GUEST_DICTATIONS_PER_DAY = 100


@app.post("/api/transcribe")
async def transcribe(request: Request, name: str = Query("diktat.m4a"), language: str = Query("de"),
                     prompt: str | None = Query(None), p: Principal = Depends(shared("write", via="query"))):
    """Audio (m4a/wav/mp3/webm, max. 25 MB) → Text mit OpenAI GPT-Transcribe."""
    if not p.is_owner:
        from .db import now
        k = (p.user_id, now().strftime("%Y-%m-%d"))
        if _guest_dictation.get(k, 0) >= GUEST_DICTATIONS_PER_DAY:
            raise HTTPException(429, "Tageslimit für Diktate erreicht")
        _guest_dictation[k] = _guest_dictation.get(k, 0) + 1
    key = _keychain(kc("openai"), "api-key")
    if not key:
        raise HTTPException(503, "Kein OpenAI-Schlüssel hinterlegt")
    data = await request.body()
    if not data:
        raise HTTPException(400, "Keine Audiodaten")
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "Aufnahme ist größer als 25 MB")
    import httpx

    mime = request.headers.get("content-type") or "audio/m4a"
    form = {"model": TRANSCRIBE_MODEL, "language": language, "response_format": "json"}
    if prompt:
        form["prompt"] = prompt[:500]

    def call() -> dict:
        r = httpx.post("https://api.openai.com/v1/audio/transcriptions", headers={"Authorization": f"Bearer {key}"},
                       data=form, files={"file": (name, data, mime)}, timeout=120)
        if r.status_code >= 400:
            raise HTTPException(502, f"Transkription fehlgeschlagen: {r.text[:200]}")
        return r.json()

    d = await asyncio.to_thread(call)
    return {"text": (d.get("text") or "").strip(), "model": TRANSCRIBE_MODEL}


@app.post("/api/computer/takeover")
async def computer_takeover(request: Request, node: str = VM_ID,
                            p: Principal = Depends(shared("read", computer="control", via="query"))):
    hub = hub_or_404(node_for(p, request, node))
    ok = await asyncio.to_thread(hub.take_over, 15)
    if not ok:
        holder = hub.holder
        name = (db.bot_row(holder) or {"name": "Ein Scoop"})["name"] if holder else "Ein Scoop"
        raise HTTPException(409, f"{name} arbeitet gerade am Rechner. Halte ihn an oder versuch es gleich nochmal.")
    return guest_computer_state(p, await asyncio.to_thread(hub.state))


@app.post("/api/computer/release")
def computer_release(request: Request, node: str = VM_ID,
                     p: Principal = Depends(shared("read", computer="control", via="query"))):
    hub_or_404(node_for(p, request, node)).give_back()
    return {"ok": True}


@app.post("/api/computer/input")
async def computer_input(request: Request, body: dict, node: str = VM_ID,
                         p: Principal = Depends(shared("read", computer="control", via="query"))):
    hub = hub_or_404(node_for(p, request, node))
    if hub.holder != USER_HOLDER:
        raise HTTPException(409, "Erst übernehmen")
    hub.user_seen = time.time()
    c = hub.computer
    t = body.get("type")
    x, y = body.get("x"), body.get("y")
    xy = [int(x), int(y)] if x is not None and y is not None else None

    def run() -> None:
        if t in ("click", "double_click", "right_click"):
            c.click({"click": "left_click"}.get(t, t), xy, body.get("modifiers"))
        elif t == "move" and xy:
            c.move(*xy)
        elif t == "drag":
            c.drag(xy, [int(body["x2"]), int(body["y2"])], body.get("modifiers"))
        elif t == "scroll":
            c.scroll(body.get("direction", "down"), int(body.get("amount", 3)), xy, body.get("modifiers"))
        elif t == "type":
            c.type_text(body.get("text", ""))
        elif t == "key":
            c.key(body.get("text", ""), int(body.get("repeat", 1)))
        else:
            raise ValueError("Unbekannte Eingabe")

    try:
        await asyncio.to_thread(run)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:  # noqa: BLE001 - z. B. Rechner offline/pausiert
        from .computer import ComputerError
        if isinstance(e, ComputerError):
            raise HTTPException(503, str(e)) from e
        raise
    _screen_caches.setdefault(hub.node_id, {"t": 0.0, "img": None})["t"] = 0.0  # nächstes Bild frisch holen
    return {"ok": True}


# -- Rechner (Scoops Connect) ----------------------------------------------------
def node_changed(node_id: str, data: dict | None) -> None:
    if data is None:
        events.publish("node.deleted", {"id": node_id})
    else:
        events.publish("node.updated", data)


computers.on_node_changed = node_changed

# -- Apple-Dienste (v1.17): Erinnerungen, Kalender, Kontakte über den Apple-Rechner ------------------
from .apple import Apple  # noqa: E402
from .apple_device import AppleDevices  # noqa: E402

# v1.18: Home, Wecker, Standort über das iPhone (apple_device.py)
apple_devices = AppleDevices(db, load_config, save_config, pusher, lambda: service.user_name)
apple = Apple(computers, load_config, save_config, lambda: service.user_name, devices=apple_devices)
service.apple = apple
# Im Hintergrund-Thread: kann aus der Event-Loop kommen (attach), apple.status() liest DB und Rechner.
apple_devices.on_changed = lambda: threading.Thread(
    target=lambda: events.publish("apple.updated", apple.status()), daemon=True).start()
apple_devices.on_geofence = service.apple_geofence


@app.get("/api/apple", dependencies=[Depends(auth)])
def get_apple():
    return apple.status()


@app.patch("/api/apple", dependencies=[Depends(auth)])
def patch_apple(body: dict):
    try:
        out = apple.patch(body or {})
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except KeyError as e:
        raise HTTPException(404, "Rechner nicht gefunden") from e
    events.publish("apple.updated", out)
    return out


# Gerätekanal der iOS-App (v1.18). Im Vordergrund läuft alles über /api/ws (`device.hello`, `device.cmd`,
# `device.result`); diese HTTP-Wege nutzt die App im Hintergrund, nachdem eine stille Push sie geweckt hat.
def _device_id(body: dict) -> str:
    did = str((body or {}).get("device_id") or "").strip()
    if not apple_devices.get(did):
        raise HTTPException(404, "Gerät unbekannt – bitte AIS Scoops öffnen")
    return did


@app.post("/api/apple/device", dependencies=[Depends(auth)])
def apple_device_register(body: dict):
    try:
        dev = apple_devices.register(body or {})
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return {"device": dev, "commands": apple_devices.pending_for(dev["id"])}


@app.post("/api/apple/device/poll", dependencies=[Depends(auth)])
def apple_device_poll(body: dict):
    did = _device_id(body)
    apple_devices.set_active(did, False)
    return {"commands": apple_devices.pending_for(did)}


@app.post("/api/apple/device/result", dependencies=[Depends(auth)])
def apple_device_result(body: dict):
    did = _device_id(body)
    return {"ok": True, "resolved": apple_devices.resolve(did, str(body.get("id") or ""), body.get("result"))}


@app.post("/api/apple/device/event", dependencies=[Depends(auth)])
def apple_device_event(body: dict):
    return apple_devices.event(_device_id(body), body or {})


@app.delete("/api/apple/device/{device_id}", dependencies=[Depends(auth)])
def apple_device_delete(device_id: str):
    if not apple_devices.remove(device_id):
        raise HTTPException(404, "Gerät unbekannt")
    return apple.status()


@app.get("/api/nodes", dependencies=[Depends(auth)])
async def list_nodes():
    return await asyncio.to_thread(computers.list_json)


@app.patch("/api/nodes/{node_id}", dependencies=[Depends(auth)])
async def patch_node(node_id: str, body: dict):
    hub = hub_or_404(node_id)
    if "name" in body:
        try:
            computers.rename(node_id, str(body.get("name") or ""))
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
    data = await asyncio.to_thread(computers.node_json, hub)
    events.publish("node.updated", data)
    return data


@app.delete("/api/nodes/{node_id}", dependencies=[Depends(auth)])
async def delete_node(node_id: str):
    if node_id == VM_ID:
        raise HTTPException(400, "Der Bot-Rechner kann nicht entfernt werden")
    try:
        tr, bot_ids = computers.remove(node_id)
    except KeyError as e:
        raise HTTPException(404, "Rechner nicht gefunden") from e
    ws = tr.ws
    tr.detach(ws, f"Rechner „{tr.name}“ wurde entfernt")
    if ws is not None:
        try:
            await tr.send_json({"type": "bye", "reason": "Dieser Rechner wurde in AIS Scoops entfernt."}, ws=ws)
            await ws.close(code=4401)
        except Exception:  # noqa: BLE001
            pass
    _screen_caches.pop(node_id, None)
    for b in bot_ids:
        bj = service.bot_json(b)
        if bj:
            events.publish("bot.updated", bj)
    events.publish("node.deleted", {"id": node_id})
    return {"ok": True}


@app.post("/api/nodes/pair", dependencies=[Depends(auth)])
def pair_node(request: Request):
    out = computers.create_pairing()
    out["server_url"] = load_config().get("public_url") or str(request.base_url).rstrip("/")
    return out


@app.post("/api/nodes/claim")
def claim_node(body: dict, request: Request):
    """Ohne Auth: Scoops Connect löst den Code ein und bekommt sein Rechner-Token (nur einmal sichtbar)."""
    if computers.claim_rate_limited():
        raise HTTPException(429, "Zu viele Fehlversuche. Bitte in einer Minute erneut versuchen.")
    out = computers.claim(body or {})
    if not out:
        raise HTTPException(404, "Code ungültig oder abgelaufen")
    drop, bots = out.pop("_drop", []), out.pop("_bots", [])
    out["server_url"] = load_config().get("public_url") or str(request.base_url).rstrip("/")
    hub = computers.get(out["node_id"])
    _nodes_replaced(out["node_id"], out.get("replaced") or [], drop, bots)
    events.publish("node.updated", computers.node_json(hub))
    how = "neu gekoppelt (Eintrag ersetzt)" if out.get("reused") else "gekoppelt"
    print(f"Rechner {how}: {out['node_id']} ({hub.name})", flush=True)
    return out


def _nodes_replaced(keep_id: str, old_ids: list[str], transports: list, bot_ids: list[str]) -> None:
    """Nach dem Ersetzen/Zusammenführen: alte Verbindungen trennen, App informieren (node.deleted, bot.updated)."""
    for tr in transports:
        ws, loop = tr.ws, tr.loop
        if ws is None or loop is None or loop.is_closed():
            continue
        gone = tr.node_id != keep_id
        tr.detach(ws, f"Rechner „{tr.name}“ wurde neu gekoppelt")

        async def close(ws=ws, tr=tr, gone=gone):
            try:
                if gone:
                    await tr.send_json({"type": "bye", "reason": "Dieser Rechner wurde durch eine neue Kopplung ersetzt."}, ws=ws)
                await ws.close(code=4401 if gone else 4000)
            except Exception:  # noqa: BLE001
                pass

        try:
            asyncio.run_coroutine_threadsafe(close(), loop)
        except Exception:  # noqa: BLE001
            pass
    for oid in old_ids:
        _screen_caches.pop(oid, None)
        events.publish("node.deleted", {"id": oid})
        print(f"Rechner {oid} durch {keep_id} ersetzt", flush=True)
    for b in dict.fromkeys(bot_ids):
        bj = service.bot_json(b)
        if bj:
            events.publish("bot.updated", bj)


@app.websocket("/api/nodes/link")
async def node_link(websocket: WebSocket, token: str = ""):
    h = websocket.headers.get("authorization", "")
    given = h[7:] if h.lower().startswith("bearer ") else token
    await websocket.accept()
    hub = computers.by_token(given)
    if hub is None:
        # Token unbekannt (Rechner entfernt): Scoops Connect löscht daraufhin sein Token.
        try:
            await websocket.send_text(json.dumps({"type": "bye", "reason": "Dieser Rechner ist nicht (mehr) gekoppelt."}))
            await websocket.close(code=4401)
        except Exception:  # noqa: BLE001
            pass
        return
    tr = hub.transport
    old = tr.attach(websocket, asyncio.get_running_loop())
    if old is not None:
        tr.fail_all("Rechner hat sich neu verbunden")
        try:
            await old.close(code=4000)
        except Exception:  # noqa: BLE001
            pass
    print(f"Rechner verbunden: {hub.node_id} ({hub.name})", flush=True)

    async def keepalive() -> None:
        last_touch = 0.0
        while True:
            await asyncio.sleep(PING_EVERY)
            if time.time() - tr.last_msg > DEAD_AFTER:
                print(f"Rechner {hub.node_id}: 60 s ohne Lebenszeichen, trenne", flush=True)
                try:
                    await websocket.close(code=4408)
                except Exception:  # noqa: BLE001
                    pass
                return
            try:
                await tr.send_json({"type": "ping"}, ws=websocket)
            except Exception:  # noqa: BLE001
                return
            if time.time() - last_touch > 60:
                last_touch = time.time()
                await asyncio.to_thread(computers.touch, hub.node_id)

    ka = asyncio.create_task(keepalive())
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            was_paused, was_apple = tr.paused, tr.apple
            reply = await asyncio.to_thread(computers.handle, hub, msg) if msg.get("type") in ("hello", "state") \
                else computers.handle(hub, msg)
            if reply:
                await tr.send_json(reply, ws=websocket)
            if msg.get("type") == "hello" or (msg.get("type") == "state" and (tr.paused != was_paused or tr.apple != was_apple)):
                await asyncio.to_thread(hub.notify)
                await asyncio.to_thread(computers.changed, hub.node_id)
            if msg.get("type") in ("hello", "state") and tr.apple != was_apple:
                events.publish("apple.updated", await asyncio.to_thread(apple.status))
    except WebSocketDisconnect:
        pass
    except Exception as e:  # noqa: BLE001
        if tr.ws is websocket:  # sonst: absichtlich getrennt (neu gekoppelt/ersetzt)
            print(f"Rechner {hub.node_id}: Verbindung beendet ({e})", flush=True)
    finally:
        ka.cancel()
        if tr.detach(websocket, f"Verbindung zum Rechner „{hub.name}“ getrennt"):
            print(f"Rechner getrennt: {hub.node_id} ({hub.name})", flush=True)
            if computers.get(hub.node_id):
                await asyncio.to_thread(computers.touch, hub.node_id)
                await asyncio.to_thread(hub.notify)
                await asyncio.to_thread(computers.changed, hub.node_id)
                if tr.apple is not None:
                    events.publish("apple.updated", await asyncio.to_thread(apple.status))


@app.get("/api/usage", dependencies=[Depends(auth)])
def usage():
    return db.usage_summary()


@app.get("/api/models")
def list_models(p: Principal = Depends(shared(via="any"))):
    """Modellkatalog für die Apps (docs/API.md): wählbare und abgelöste Modelle mit Anzeigename, Hinweis, Rang, Preisen
    und Wegen. Für den Admin zusätzlich `available` und `routes_available` (Schlüssel bzw. Abo auf diesem Server)."""
    c = catalog.current()
    out = c.as_json()
    if p.is_owner:
        pr = config.provider_routes()
        for m in out["models"]:
            r = config.model_routes(m["id"], pr) if m["selectable"] else []
            m["routes_available"], m["available"] = r, bool(r)
        out["providers"] = pr
    out["replaced"] = c.replaced
    return out


# -- Nutzung und Verbrauch (docs/nutzung.md) ---------------------------------------------------------------------------
log_scanner = LogScanner(db)
abo_limits = Limits(db)


def _logs_status() -> dict:
    st = dict(log_scanner.status)
    has_rows = db.one("SELECT 1 FROM log_usage LIMIT 1") is not None
    last = st.get("last_scan")
    return {"available": bool(last) or has_rows, "state": st.get("state"), "files": st.get("files"),
            "last_scan": datetime.fromtimestamp(last, timezone.utc).isoformat(timespec="seconds") if last else None,
            "seconds": st.get("seconds"), "skipped_compressed": st.get("skipped_compressed") or 0,
            "error": st.get("error")}


@app.get("/api/usage/details", dependencies=[Depends(auth)])
def usage_details(range: str = "30d", source: str = "all", refresh: int = 0):  # noqa: A002
    """Kosten und Tokens: Abo-Verbrauch aller Apps auf diesem Mac (Protokolle) plus echte API-Kosten der Scoops."""
    first = not log_scanner.status.get("last_scan")
    log_scanner.ensure_fresh(wait=8.0 if (refresh or first) else 2.0, force=bool(refresh))
    names = {r["id"]: r["name"] for r in db.bots()}
    return usage_report.details(db, range, source, logs=_logs_status(), account=abo_limits.account_usage(),
                                bot_names=names)


@app.get("/api/usage/limits", dependencies=[Depends(auth)])
def usage_limits(refresh: int = 0):
    """Abo-Fenster (Woche, 5 Stunden, pro Modell, Credits) – kontoweit, live von Claude Code bzw. Codex abgefragt."""
    return abo_limits.snapshot(refresh=bool(refresh), wait=30.0)


@app.post("/api/devices", dependencies=[Depends(auth)])
def register_device(body: dict):
    tok = body.get("apns_token")
    if not tok:
        raise HTTPException(400, "apns_token fehlt")
    db.q("INSERT OR REPLACE INTO devices(token,platform,name,created_at) VALUES(?,?,?,datetime('now'))",
         (tok, body.get("platform"), body.get("name")))
    pusher.note_token(tok, body.get("platform"))  # Relay-Modus: Token bei AIS Scoops Cloud melden
    return {"ok": True, "push_enabled": pusher.enabled}


# -- Gruppen ----------------------------------------------------------------
def group_or_404(gid: str) -> dict:
    g = service.group_json(gid)
    if not g:
        raise HTTPException(404, "Gruppe nicht gefunden")
    return g


def _check_members(ids) -> list[str]:
    if not isinstance(ids, list) or not 2 <= len(ids) <= 6:
        raise HTTPException(400, "Eine Gruppe braucht 2 bis 6 Scoops")
    if any(not db.bot_row(i) for i in ids):
        raise HTTPException(400, "Unbekannter Scoop in der Gruppe")
    return list(dict.fromkeys(ids))


@app.get("/api/groups", dependencies=[Depends(auth)])
def list_groups():
    return service.groups_json()


@app.post("/api/groups", dependencies=[Depends(auth)])
def create_group(body: dict):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "Die Gruppe braucht einen Namen")
    return service.create_group(name, _check_members(body.get("member_ids")))


@app.get("/api/groups/{gid}", dependencies=[Depends(auth)])
def get_group(gid: str):
    return group_or_404(gid)


@app.patch("/api/groups/{gid}", dependencies=[Depends(auth)])
def patch_group(gid: str, body: dict):
    group_or_404(gid)
    if "member_ids" in body:
        body["member_ids"] = _check_members(body["member_ids"])
    db.update_group(gid, body)
    g = group_or_404(gid)
    events.publish("group.updated", g)
    return g


@app.delete("/api/groups/{gid}", dependencies=[Depends(auth)])
def delete_group(gid: str):
    group_or_404(gid)
    service.delete_group(gid)
    return {"ok": True}


@app.get("/api/groups/{gid}/messages", dependencies=[Depends(auth)])
def group_messages(gid: str, before: str | None = None, limit: int = 50):
    group_or_404(gid)
    return db.messages(gid, before, max(1, min(limit, 200)))


@app.post("/api/groups/{gid}/messages", dependencies=[Depends(auth)])
def group_post(gid: str, body: dict):
    group_or_404(gid)
    return _post(gid, body)


@app.post("/api/groups/{gid}/stop", dependencies=[Depends(auth)])
def group_stop(gid: str):
    service.stop(gid)
    return {"ok": True}


@app.post("/api/groups/{gid}/read", dependencies=[Depends(auth)])
def group_read(gid: str):
    db.q("UPDATE groups SET unread=0 WHERE id=?", (gid,))
    pusher.badge_changed()
    events.publish("group.updated", group_or_404(gid))
    return {"ok": True}


@app.post("/api/groups/{gid}/reset", dependencies=[Depends(auth)])
def group_reset(gid: str):
    group_or_404(gid)
    service.stop(gid)
    db.q("DELETE FROM messages WHERE bot_id=?", (gid,))
    events.publish("group.updated", group_or_404(gid))
    return {"ok": True}


# -- Bibliothek --------------------------------------------------------------
def chat_or_404(chat_id: str) -> None:
    if not service.chat_exists(chat_id):
        raise HTTPException(404, "Chat nicht gefunden")


@app.get("/api/chats/{chat_id}/files")
def list_files(chat_id: str, p: Principal = Depends(shared("read", via="chat_id"))):
    chat_or_404(chat_id)
    return db.files(chat_id)


@app.post("/api/chats/{chat_id}/files")
async def upload_file(chat_id: str, request: Request, name: str = Query(...),
                      p: Principal = Depends(shared("write", via="chat_id"))):
    chat_or_404(chat_id)
    data = await request.body()
    if not data:
        raise HTTPException(400, "Leere Datei")
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "Datei ist größer als 25 MB")
    mime = request.headers.get("content-type") or None
    if mime in (None, "application/octet-stream"):
        import mimetypes
        mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
    return db.add_file(chat_id, None, name, data, mime)


@app.get("/api/files/{fid}")
def download_file(fid: str, p: Principal = Depends(shared("read", via="fid"))):
    r = db.file_row(fid)
    if not r or not r["path"] or not os.path.exists(r["path"]):
        raise HTTPException(404, "Datei nicht gefunden")
    return FileResponse(r["path"], media_type=r["mime"] or "application/octet-stream", filename=r["name"],
                        content_disposition_type="inline")


@app.delete("/api/files/{fid}")
def delete_file(fid: str, p: Principal = Depends(shared("edit", via="fid"))):
    db.delete_file(fid)
    return {"ok": True}


# -- Live-Aktivitäten ---------------------------------------------------------
@app.post("/api/live-activities", dependencies=[Depends(auth)])
def register_live_activity(body: dict):
    """Update-Token der gemeinsamen Live-Aktivität (run_id = Sitzung aus /api/live-activity)."""
    tok = body.get("push_token")
    if not tok:
        raise HTTPException(400, "push_token nötig")
    pusher.board.register_token(tok, body.get("run_id"))
    return {"ok": True}


@app.get("/api/live-activity", dependencies=[Depends(auth)])
def live_activity_state():
    return pusher.board.snapshot()


@app.post("/api/live-activity/ensure", dependencies=[Depends(auth)])
def live_activity_ensure():
    return pusher.board.ensure() if pusher.enabled else {"active": False, "session": None, "channel": None, "content": None}


# -- Bereiche in der Seitenleiste ------------------------------------------------
def sections_state() -> list[dict]:
    try:
        saved = json.loads(db.setting("sections") or "[]")
    except ValueError:
        saved = []
    names = [x["name"] for x in saved]
    # Bereiche, die nur an Scoops/Gruppen hängen, aber noch nicht gespeichert sind, hinten anfügen
    used = [r["section"] for r in db.q("SELECT section FROM bots WHERE section IS NOT NULL UNION "
                                        "SELECT section FROM groups WHERE section IS NOT NULL")]
    for n in used:
        if n and n not in names:
            saved.append({"name": n, "collapsed": False})
            names.append(n)
    return saved


def publish_sections() -> dict:
    out = {"sections": sections_state()}
    events.publish("sections.updated", out)
    return out


@app.get("/api/sections", dependencies=[Depends(auth)])
def get_sections():
    return {"sections": sections_state()}


@app.put("/api/sections", dependencies=[Depends(auth)])
def put_sections(body: dict):
    secs, seen = [], set()
    for x in body.get("sections", []):
        name = (x.get("name") if isinstance(x, dict) else str(x) or "").strip()[:40]
        if name and name.lower() not in seen:
            seen.add(name.lower())
            secs.append({"name": name, "collapsed": bool(x.get("collapsed")) if isinstance(x, dict) else False})
    db.set_setting("sections", json.dumps(secs, ensure_ascii=False))
    return publish_sections()


@app.post("/api/sections/rename", dependencies=[Depends(auth)])
def rename_section(body: dict):
    old, new = (body.get("from") or "").strip(), (body.get("to") or "").strip()[:40]
    if not old or not new:
        raise HTTPException(400, "from und to nötig")
    db.q("UPDATE bots SET section=? WHERE section=?", (new, old))
    db.q("UPDATE groups SET section=? WHERE section=?", (new, old))
    secs = [dict(x, name=new) if x["name"] == old else x for x in sections_state()]
    db.set_setting("sections", json.dumps(secs, ensure_ascii=False))
    for r in db.q("SELECT id FROM bots WHERE section=?", (new,)):
        events.publish("bot.updated", service.bot_json(r["id"]))
    for r in db.q("SELECT id FROM groups WHERE section=?", (new,)):
        events.publish("group.updated", service.group_json(r["id"]))
    return publish_sections()


@app.delete("/api/sections/{name}", dependencies=[Depends(auth)])
def delete_section(name: str):
    ids = [r["id"] for r in db.q("SELECT id FROM bots WHERE section=?", (name,))]
    gids = [r["id"] for r in db.q("SELECT id FROM groups WHERE section=?", (name,))]
    db.q("UPDATE bots SET section=NULL WHERE section=?", (name,))
    db.q("UPDATE groups SET section=NULL WHERE section=?", (name,))
    db.set_setting("sections", json.dumps([x for x in sections_state() if x["name"] != name], ensure_ascii=False))
    for i in ids:
        events.publish("bot.updated", service.bot_json(i))
    for g in gids:
        events.publish("group.updated", service.group_json(g))
    return publish_sections()


# -- Arbeitsordner der Scoops (docs/arbeitsordner.md) ---------------------------
def workspace_status() -> dict:
    from .computer_tools import full_disk_access
    return {**workspace.status(load_config(), db.bots()), "full_disk_access": full_disk_access()}


def set_workspace(raw: str) -> dict:
    """Neuen Arbeitsordner prüfen, speichern und die Scoop-Ordner anlegen. Alte Dateien bleiben, wo sie sind."""
    cfg = load_config()
    try:
        cfg, changed = workspace.apply(cfg, raw)
    except workspace.WorkspaceError as e:
        raise HTTPException(400, str(e)) from None
    save_config(cfg)
    workspace.last_error = None
    workspace.ensure_all(db.bots(), cfg)
    if changed:
        print(f"Arbeitsordner gesetzt: {cfg[workspace.CONFIG_KEY]}", flush=True)
    return workspace_status()


@app.get("/api/settings/workspace", dependencies=[Depends(auth)])
def get_workspace():
    return workspace_status()


@app.patch("/api/settings/workspace", dependencies=[Depends(auth)])
def patch_workspace(body: dict):
    if not isinstance(body.get("path"), str):
        raise HTTPException(400, "path fehlt")
    return set_workspace(body["path"])


@app.get("/api/settings/workspace/browse", dependencies=[Depends(auth)])
def browse_workspace(path: str = "~"):
    """Unterordner eines Ordners für die Ordnerauswahl auf iPhone/iPad (nur Verzeichnisse im Home-Ordner)."""
    try:
        return workspace.browse(path)
    except workspace.WorkspaceError as e:
        raise HTTPException(400, str(e)) from None


@app.post("/api/settings/workspace/folder", dependencies=[Depends(auth)])
def make_workspace_folder(body: dict):
    try:
        return workspace.make_folder(str(body.get("parent") or "~"), str(body.get("name") or ""))
    except workspace.WorkspaceError as e:
        raise HTTPException(400, str(e)) from None


# -- Initiative -----------------------------------------------------------------
@app.get("/api/settings/initiative", dependencies=[Depends(auth)])
def get_initiative():
    p = db.primary_bot()
    return {**initiative_settings(), "primary_bot_id": p["id"] if p else None}


@app.patch("/api/settings/initiative", dependencies=[Depends(auth)])
def patch_initiative(body: dict):
    cfg = initiative_settings()
    if "enabled" in body:
        cfg["enabled"] = bool(body["enabled"])
    if "times" in body:
        times = sorted({t for t in body["times"] if isinstance(t, str) and re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", t)})
        if len(times) > 8:
            raise HTTPException(400, "Höchstens 8 Zeiten")
        cfg["times"] = times
    for k in ("quiet_start", "quiet_end"):
        if k in body and re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", str(body[k])):
            cfg[k] = body[k]
    db.set_setting("initiative", json.dumps({k: cfg[k] for k in INITIATIVE_DEFAULT}))
    return get_initiative()


@app.post("/api/initiative/run", dependencies=[Depends(auth)])
def initiative_now():
    p = db.primary_bot()
    if not p:
        raise HTTPException(400, "Kein Haupt-Scoop festgelegt")
    from .db import now
    run_initiative(p["id"], now().strftime("%H:%M"), False)
    return {"ok": True}


# -- Fähigkeiten ----------------------------------------------------------------
@app.get("/api/skills", dependencies=[Depends(auth)])
def list_skills():
    return db.skills()


@app.get("/api/bots/{bot_id}/skills")
def bot_skills(bot_id: str, p: Principal = Depends(shared("edit"))):
    bot_or_404(bot_id)
    sk = db.skills(bot_id)
    return sk if p.is_owner else [s for s in sk if s["bot_id"] == bot_id]  # „für alle Scoops“ nur Admin


@app.patch("/api/skills/{sid}")
def patch_skill(sid: str, body: dict, p: Principal = Depends(shared("edit", via="sid"))):
    r = db.skill_row(sid)
    if not r:
        raise HTTPException(404, "Fähigkeit nicht gefunden")
    from .db import now_iso
    db.q("UPDATE skills SET name=?, description=?, steps=?, updated_at=? WHERE id=?",
         (body.get("name", r["name"]), body.get("description", r["description"]), body.get("steps", r["steps"]), now_iso(), sid))
    sk = db.skill_dict(db.skill_row(sid))
    events.publish("skill.updated", sk)
    return sk


@app.delete("/api/skills/{sid}")
def delete_skill(sid: str, p: Principal = Depends(shared("edit", via="sid"))):
    db.q("DELETE FROM skills WHERE id=?", (sid,))
    events.publish("skill.deleted", {"id": sid})
    return {"ok": True}


# -- Tresor -----------------------------------------------------------------------
@app.get("/api/vault", dependencies=[Depends(auth)])
def list_vault():
    out = []
    for e in db.vault_entries():
        out.append({**e, "has_password": vault_mod.get_secret(e["id"]) is not None})
    return out


@app.post("/api/vault", dependencies=[Depends(auth)])
def create_vault(body: dict):
    from .db import new_id, now_iso
    title, url = (body.get("title") or "").strip(), (body.get("url") or "").strip()
    if not title or not url:
        raise HTTPException(400, "Titel und Webseite sind nötig")
    domain = vault_mod.domain_of(url)
    if not domain or "." not in domain:
        raise HTTPException(400, "Ungültige Webseite")
    vid = new_id("v")
    ts = now_iso()
    db.q("INSERT INTO vault(id,title,url,domain,username,note,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
         (vid, title, url, domain, body.get("username", ""), body.get("note", ""), ts, ts))
    if body.get("password"):
        vault_mod.set_secret(vid, body["password"])
    return {**db.vault_dict(db.vault_row(vid)), "has_password": bool(body.get("password"))}


@app.patch("/api/vault/{vid}", dependencies=[Depends(auth)])
def patch_vault(vid: str, body: dict):
    r = db.vault_row(vid)
    if not r:
        raise HTTPException(404, "Eintrag nicht gefunden")
    from .db import now_iso
    url = body.get("url", r["url"])
    db.q("UPDATE vault SET title=?, url=?, domain=?, username=?, note=?, updated_at=? WHERE id=?",
         (body.get("title", r["title"]), url, vault_mod.domain_of(url), body.get("username", r["username"]),
          body.get("note", r["note"]), now_iso(), vid))
    if body.get("password"):
        vault_mod.set_secret(vid, body["password"])
    return {**db.vault_dict(db.vault_row(vid)), "has_password": vault_mod.get_secret(vid) is not None}


@app.delete("/api/vault/{vid}", dependencies=[Depends(auth)])
def delete_vault(vid: str):
    vault_mod.delete_secret(vid)
    db.q("DELETE FROM vault WHERE id=?", (vid,))
    return {"ok": True}


# -- Apps verbinden ----------------------------------------------------------------
BUILTIN = [("teamapp", "Team App", "MLP-Team, Recruiting, Kennzahlen", "person.3.fill"),
           ("atrium", "Atrium", "Dein Kontext-Vault (lokal)", "building.columns.fill"),
           ("atrium_berlin", "Atrium · Team Berlin", "Berater-Kontexte (Cloud)", "person.2.wave.2.fill"),
           ("atrium_koeln", "Atrium · Team Köln", "Berater-Kontexte (Cloud)", "person.2.wave.2.fill")]


def _builtin_status() -> list[dict]:
    out = []
    for name, title, detail, symbol in BUILTIN:
        if not feature("teamapp" if name == "teamapp" else "atrium"):
            continue
        srv = service.mcp_hub.servers.get(name)
        if not srv:
            state = "off"
        else:
            state = "ok" if srv._tools else "error"
        out.append({"id": name, "name": title, "detail": detail, "symbol": symbol, "status": state,
                    "tools": len(srv._tools) if srv else 0})
    from . import t3 as t3mod
    if feature("t3"):
        out.append({"id": "t3", "name": "T3 Code", "detail": "Programmieraufträge auf dem Air und Pro", "symbol": "terminal.fill",
                    "status": "ok" if t3mod.available() else "off", "tools": 0})
    if feature("lucy"):
        out.append({"id": "lucy", "name": "Lucy Telefonie", "detail": "Anrufe nur mit Freigabe", "symbol": "phone.fill",
                    "status": "ok", "tools": 0})
    return out


def _conn_call(fn, *a):
    from .connections import NotFound, Unsupported
    try:
        return fn(*a)
    except NotFound as e:
        raise HTTPException(404, str(e))
    except Unsupported as e:
        raise HTTPException(422, str(e))
    except ValueError as e:
        raise HTTPException(409, str(e))
    except RuntimeError as e:
        raise HTTPException(502, str(e))


# Katalog aller Composio-Apps (v1.16). Nur Inhaber (`auth`): Gäste geteilter Scoops → 403.
@app.get("/api/connections/catalog", dependencies=[Depends(auth)])
def connections_catalog(category: str = "", q: str = "", limit: int = 60, offset: int = 0):
    return _conn_call(connections.catalog, category, q, limit, offset)


@app.get("/api/connections/categories", dependencies=[Depends(auth)])
def connections_categories():
    return _conn_call(connections.categories)


@app.get("/api/connections/catalog/{app_slug}", dependencies=[Depends(auth)])
def connections_app_auth(app_slug: str):
    return _conn_call(connections.auth_info, app_slug)


@app.get("/api/connections/logo/{app_slug}", dependencies=[Depends(auth)])
def connection_logo(app_slug: str):
    data = _conn_call(connections.logo_png, app_slug)
    return Response(content=data, media_type="image/png", headers={"Cache-Control": "private, max-age=604800"})


@app.post("/api/connections/{app_slug}/connect", dependencies=[Depends(auth)])
def connect_with_fields(app_slug: str, body: dict | None = None):
    """Konto mit API-Schlüssel o. Ä.: Werte gehen nur an Composio (nicht gespeichert, nicht protokolliert)."""
    body = body or {}
    return _conn_call(connections.connect, app_slug, body.get("alias"), body.get("fields"))


@app.get("/api/connections", dependencies=[Depends(auth)])
def list_connections(fresh: bool = False):
    if fresh:
        _conn_call(connections.accounts, True)
    try:
        out = _conn_call(connections.overview, _builtin_status())
    except HTTPException as e:
        # Composio nicht eingerichtet/erreichbar: eigene MCP-Server trotzdem zeigen (ab 1.35)
        if e.status_code != 502 or not service.custom_mcp.entries():
            raise
        out = {"apps": [], "max_per_app": 0, "builtin": _builtin_status(), "composio_error": str(e.detail)}
    out["custom_mcp"] = service.custom_mcp.status(service.mcp_hub)
    out["custom_mcp_supported"] = True
    return out


# Notion direkt (ab 1.25, notion_mcp.py): eigenes OAuth statt Composio. Nur Apps, die den Rücksprung
# `aisscoops://oauth/…` abfangen können, schicken `native: true`; ältere Apps bekommen weiter Composio.
NATIVE_APPS = {"notion"}


def _notion_call(fn, *a):
    try:
        return fn(*a)
    except ValueError as e:
        raise HTTPException(409, str(e))
    except notion_mcp.NotionAuthError as e:
        raise HTTPException(502, str(e))
    except Exception as e:  # noqa: BLE001 – Netzfehler o. Ä.
        raise HTTPException(502, f"Notion ist gerade nicht erreichbar: {str(e)[:200]}")


def _reload_mcp() -> None:
    service.mcp_hub.configure(mcp_servers())
    threading.Thread(target=service.mcp_hub.warm, daemon=True).start()


service.custom_mcp.on_change = lambda: _reload_mcp()


# -- Eigene MCP-Server (ab 1.35, custom_mcp.py, docs/mcp.md). Nur der Inhaber (`auth`), Gäste → 403. ----------------
def _mcp_call(fn, *a):
    try:
        return fn(*a)
    except KeyError as e:
        raise HTTPException(404, str(e).strip("'\""))
    except ValueError as e:
        raise HTTPException(400, str(e))
    except custom_mcp.McpAuthError as e:
        raise HTTPException(502, str(e))
    except Exception as e:  # noqa: BLE001 – Netzfehler o. Ä.
        raise HTTPException(502, f"Der MCP-Server ist gerade nicht erreichbar: {str(e)[:200]}")


def _mcp_list() -> dict:
    return {"servers": service.custom_mcp.status(service.mcp_hub), "supported": True,
            "callback_scheme": custom_mcp.CALLBACK_SCHEME}


@app.get("/api/mcp-servers", dependencies=[Depends(auth)])
def mcp_list():
    return _mcp_list()


@app.post("/api/mcp-servers/probe", dependencies=[Depends(auth)])
def mcp_probe(body: dict):
    return _mcp_call(service.custom_mcp.probe, str((body or {}).get("url") or ""))


@app.post("/api/mcp-servers", dependencies=[Depends(auth)])
def mcp_add(body: dict):
    out = _mcp_call(service.mcp_connect, body or {})
    return {**out, **_mcp_list()}


@app.patch("/api/mcp-servers/{sid}", dependencies=[Depends(auth)])
def mcp_patch(sid: str, body: dict):
    body = body or {}
    if body.get("name") is not None:
        _mcp_call(service.custom_mcp.rename, sid, str(body["name"]))
    if body.get("token"):
        _mcp_call(service.custom_mcp.set_token, sid, str(body["token"]), body.get("header"))
        _mcp_call(service.mcp_test, sid)
    return _mcp_list()


@app.delete("/api/mcp-servers/{sid}", dependencies=[Depends(auth)])
def mcp_delete(sid: str):
    _mcp_call(service.mcp_remove, sid)
    return _mcp_list()


@app.post("/api/mcp-servers/{sid}/login", dependencies=[Depends(auth)])
def mcp_login(sid: str):
    return _mcp_call(service.custom_mcp.start, sid)


@app.post("/api/mcp-servers/{sid}/test", dependencies=[Depends(auth)])
def mcp_test(sid: str):
    res = _mcp_call(service.mcp_test, sid)
    return {**res, **_mcp_list()}


@app.post("/api/connections/{app_slug}/link", dependencies=[Depends(auth)])
def link_connection(app_slug: str, body: dict | None = None):
    body = body or {}
    if app_slug in NATIVE_APPS and body.get("native") and not OFFLINE:
        return _notion_call(notion_mcp.instance().start, body.get("alias"))
    return _conn_call(connections.link, app_slug, body.get("alias"))


@app.post("/api/connections/oauth/callback", dependencies=[Depends(auth)])
def oauth_callback(body: dict):
    """Rücksprung aus dem Browser (`aisscoops://oauth/notion?code=…&state=…`), von der App weitergereicht."""
    url = str((body or {}).get("url") or "")
    if custom_mcp.CustomMCP.owns_callback(url):  # eigener MCP-Server (aisscoops://oauth/mcp, ab 1.35)
        return _mcp_call(service.mcp_oauth_finished, url)
    if OFFLINE:
        raise HTTPException(404, "Nicht verfügbar")
    acc = _notion_call(notion_mcp.instance().finish, url)
    _reload_mcp()
    return acc


@app.get("/api/connections/accounts/{account_id}", dependencies=[Depends(auth)])
def connection_status(account_id: str):
    if account_id == notion_mcp.ACCOUNT_ID:
        acc = notion_mcp.instance().account()
        if not acc:
            raise HTTPException(404, "Notion ist nicht direkt verbunden")
        return acc
    return _conn_call(connections.status, account_id)


@app.patch("/api/connections/accounts/{account_id}", dependencies=[Depends(auth)])
def rename_connection(account_id: str, body: dict):
    if account_id == notion_mcp.ACCOUNT_ID:
        return _notion_call(notion_mcp.instance().rename, str(body.get("alias") or ""))
    return _conn_call(connections.rename, account_id, body.get("alias") or "")


@app.post("/api/connections/accounts/{account_id}/reconnect", dependencies=[Depends(auth)])
def reconnect_connection(account_id: str):
    if account_id == notion_mcp.ACCOUNT_ID:
        return _notion_call(notion_mcp.instance().start)
    return _conn_call(connections.reconnect, account_id)


@app.delete("/api/connections/accounts/{account_id}", dependencies=[Depends(auth)])
def delete_connection(account_id: str):
    if account_id == notion_mcp.ACCOUNT_ID:
        _notion_call(notion_mcp.instance().disconnect)
        _reload_mcp()
        return {"ok": True}
    _conn_call(connections.remove, account_id)
    return {"ok": True}


# -- Eigenes Scoop-Bild (statt Maskottchen, siehe avatars.py) --------------------
@app.put("/api/bots/{bot_id}/avatar")
async def put_avatar(bot_id: str, request: Request, p: Principal = Depends(shared("edit"))):
    """Rohe Bilddaten im Body (JPEG/PNG/HEIC/WebP …). Wird quadratisch auf 512 px zugeschnitten."""
    from . import avatars
    bot_or_404(bot_id)
    data = await request.body()
    try:
        version = await asyncio.to_thread(avatars.save, bot_id, data)
    except avatars.AvatarError as e:
        raise HTTPException(413 if "15 MB" in str(e) else 400, str(e)) from None
    db.set_avatar_version(bot_id, version)
    b = bot_or_404(bot_id)
    events.publish("bot.updated", b)
    pusher.reload_widgets()
    return b if p.is_owner else guest_bot_view(bot_id, p.share, b)


@app.delete("/api/bots/{bot_id}/avatar")
def delete_avatar(bot_id: str, p: Principal = Depends(shared("edit"))):
    """Zurück zum Maskottchen."""
    from . import avatars
    bot_or_404(bot_id)
    avatars.remove(bot_id)
    db.set_avatar_version(bot_id, None)
    b = bot_or_404(bot_id)
    events.publish("bot.updated", b)
    pusher.reload_widgets()
    return b if p.is_owner else guest_bot_view(bot_id, p.share, b)


@app.get("/api/bots/{bot_id}/avatar")
def get_avatar(bot_id: str, request: Request, v: int | None = None, size: int | None = None,
               p: Principal = Depends(shared("read"))):
    """Bild abrufen. `?v=<version>` (aus `avatar.version`) macht die Antwort dauerhaft cachebar,
    `?size=64…512` liefert eine verkleinerte Fassung (z. B. 128 für Widgets)."""
    from . import avatars
    b = bot_or_404(bot_id)
    path = avatars.current_path(bot_id)
    current = (b.get("avatar") or {}).get("version")
    if not path or not current:
        raise HTTPException(404, "Kein eigenes Bild")
    side = max(64, min(int(size), avatars.SIZE)) if size else None
    etag = f'"{bot_id}-{current}-{side or avatars.SIZE}"'
    cache = "private, max-age=31536000, immutable" if v == current else "private, no-cache"
    headers = {"ETag": etag, "Cache-Control": cache, "X-Avatar-Version": str(current)}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    if side and side < avatars.SIZE:
        body, mime = avatars.resized(path, side)
        return Response(body, media_type=mime, headers=headers)
    return FileResponse(path, media_type="image/png" if path.suffix == ".png" else "image/jpeg", headers=headers)


# -- Einrichtung: Kopplung mit einem Konto (nur lokal, docs/accounts.md) -------------
_PROXY_HEADERS = ("x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip", "forwarded",
                  "tailscale-user-login", "tailscale-user-name", "tailscale-app-capabilities")


def local_only(request: Request) -> None:
    """Nur direkte Aufrufe auf diesem Mac. Tailscale Serve verbindet zwar auch von 127.0.0.1,
    setzt aber Weiterleitungs-Header – solche Anfragen werden abgelehnt."""
    host = request.client.host if request.client else ""
    if host not in ("127.0.0.1", "::1") or any(request.headers.get(h) for h in _PROXY_HEADERS):
        raise HTTPException(403, "Nur lokal auf dem Server erreichbar")


@app.get("/api/setup", dependencies=[Depends(local_only)])
def setup_status():
    """Kopplungsstatus (cloud.py) plus Zustand der Installation für die Mac-App „AIS Scoops Server“."""
    cfg = load_config()
    push_mode = pusher.mode()
    return {**cloud.status(), "push": {
        "enabled": push_mode is not None, "mode": push_mode,
        "error": pusher.relay.last_error if push_mode != "direct" else None}, "server": {
        "edition": profile.edition(cfg), "port": PORT, "home": str(profile.HOME),
        "user_name": service.user_name, "owner_name": cfg.get("owner_name"),
        "server_name": cfg.get("server_name") or __import__("aisbot.cloud", fromlist=["server_name"]).server_name(),
        "public_url": cfg.get("public_url") or "", "tailnet_url": cfg.get("tailnet_url") or "",
        "host": HOST, "host_configured": cfg.get("host") or "127.0.0.1",
        "default_model": config.resolve_model(cfg.get("default_model")) or catalog.current().default("anthropic"),
        "default_computer_node": cfg.get("default_computer_node"),
        "keys": {"anthropic": bool(_keychain(kc("anthropic"), "api-key")),
                 "openai": bool(_keychain(kc("openai"), "api-key")),
                 "composio": bool(_keychain(kc("composio"), "api-key"))},
        "composio_ready": bool(cfg.get("composio_session_id")),
        "bots": len(db.bots()), "own_scoops": _own_scoops(), "active_runs": len(service.runs),
        "nodes": [{"id": h.node_id, "name": h.name, "online": bool(getattr(h.transport, "online", False))}
                  for h in computers.visible() if h.node_id != VM_ID],
        "effective_computer_node": computers.default_id(),
        "lan_url": cfg.get("lan_url") or "",
        "workspace": workspace.status(cfg, db.bots()),
        "full_disk_access": __import__("aisbot.computer_tools", fromlist=["full_disk_access"]).full_disk_access(),
        "abos": _abos_safe(),
    }}


def _own_scoops() -> dict:
    """Scoops, die der Nutzer selbst angelegt hat (ohne den Start-Scoop der frischen Installation, siehe
    seed_fresh_install). Der Einrichtungsassistent der Mac-App gratuliert damit zum ersten eigenen Scoop."""
    seed_id, seeded = db.setting("seed_bot"), db.setting("seeded")
    # Ältere Installationen kennen die ID des Start-Scoops nicht: dann alles bis zum Anlegen ausnehmen
    own = [b for b in db.bots()
           if b["id"] != seed_id and (seed_id or not seeded or b["created_at"] > seeded)]
    newest = max(own, key=lambda b: b["created_at"], default=None)
    return {"count": len(own), "newest": newest["name"] if newest else None}


def _abos_safe() -> dict | None:
    try:
        from . import abos
        return abos.status()
    except Exception as e:  # noqa: BLE001
        print("Abo-Status:", e, flush=True)
        return None


# Standardmodell und Verstärkung je Anbieter (Modellkatalog `defaults`)
PROVIDER_MODELS = catalog.LiveMap(lambda c: {p: (c.default(p), c.default(p, "escalation")) for p in catalog.PROVIDERS})
SETUP_KEYS = ("user_name", "public_url", "tailnet_url", "lan_url", "server_name", "default_computer_node", "host")


@app.patch("/api/setup/config", dependencies=[Depends(local_only)])
def setup_config(body: dict):
    """Einstellungen aus dem Einrichtungsassistenten (nur bekannte Felder; leerer Text = entfernen).
    `workspace_dir` (Arbeitsordner, Mac-App) wird geprüft und angelegt; bei Fehlern 400 mit Erklärung."""
    if isinstance(body.get("workspace_dir"), str):
        set_workspace(body["workspace_dir"])
    cfg = load_config()
    urls_before = (cfg.get("public_url"), cfg.get("tailnet_url"))
    for k in SETUP_KEYS:
        if k in body:
            v = str(body[k] or "").strip()[:300]
            if k == "host" and v not in ("", "127.0.0.1", "0.0.0.0"):
                raise HTTPException(400, "host: 127.0.0.1 (nur dieser Mac) oder 0.0.0.0 (lokales Netz)")
            if k in ("public_url", "tailnet_url", "lan_url") and v and not re.match(r"^https?://", v):
                raise HTTPException(400, f"{k} muss mit http:// oder https:// beginnen")
            if v:
                cfg[k] = v.rstrip("/") if k.endswith("_url") else v
            else:
                cfg.pop(k, None)
    provider = str(body.get("provider") or "").strip().lower()
    if provider in PROVIDER_MODELS:
        cfg["default_model"], cfg["default_escalation_model"] = PROVIDER_MODELS[provider]
        other = {m for p, ms in PROVIDER_MODELS.items() if p != provider for m in ms}
        for b in db.bots():  # Start-Scoop & Co. auf den Anbieter mit Schlüssel umstellen
            if config.resolve_model(b["model"]) in other:
                db.update_bot(b["id"], {"model": cfg["default_model"], "escalation_model": cfg["default_escalation_model"]})
    save_config(cfg)
    node = cfg.get("default_computer_node")
    if "default_computer_node" in body and node and not feature("vm") and computers.get(node):
        db.q("UPDATE bots SET computer_node=? WHERE computer_node IS NULL", (node,))
    for b in db.bots():
        bj = service.bot_json(b["id"])
        if bj:
            events.publish("bot.updated", bj)
    cloud.last_heartbeat = 0.0  # neue Adresse an Convex melden
    if (cfg.get("public_url"), cfg.get("tailnet_url")) != urls_before and cloud.owner_id():
        # sofort statt erst beim nächsten Planer-Takt (bis 15 s), damit die App gleich die neue Adresse bekommt
        threading.Thread(target=cloud.heartbeat_tick, daemon=True, name="heartbeat-now").start()
    return setup_status()


@app.post("/api/setup/this-mac", dependencies=[Depends(local_only)])
def setup_this_mac(body: dict):
    """Mac-App: „Dieser Mac“ ist Rechner `node_id` mit Geräte-ID `device_id`. Frühere Einträge desselben Macs
    (gleiche Geräte-ID, ausdrücklich genannte `replaces` oder alte offline-Einträge gleichen Namens ohne
    Geräte-ID) werden zusammengeführt; Scoops darauf werden umgehängt. In der Edition „standard“ wird der
    Rechner außerdem Standard-Rechner, falls noch keiner (gültig) gesetzt ist."""
    nid = str(body.get("node_id") or "")
    if not computers.get(nid) or nid == VM_ID:
        raise HTTPException(404, "Rechner nicht gefunden")
    dev = str(body.get("device_id") or "").strip()[:80]
    if dev:
        computers.set_device(nid, dev)
    old = computers.duplicates_of(nid, dev or None, legacy_by_name=True)
    old += [str(x) for x in (body.get("replaces") or []) if isinstance(x, str) and computers.get(x)]
    old = [o for o in dict.fromkeys(old) if o not in (nid, VM_ID)]
    transports, bots = computers.absorb(nid, old)
    _nodes_replaced(nid, old, transports, bots)
    cfg = load_config()
    if not feature("vm") and (body.get("make_default") or not computers.get(cfg.get("default_computer_node") or "")):
        cfg["default_computer_node"] = nid
        save_config(cfg)
        for b in db.bots():
            bj = service.bot_json(b["id"])
            if bj:
                events.publish("bot.updated", bj)
    events.publish("node.updated", computers.node_json(computers.get(nid)))
    return {**setup_status(), "merged": old}


# KI-Abos für die Mac-App „AIS Scoops Server“ (nur lokal, docs/abos.md)
@app.get("/api/setup/abos", dependencies=[Depends(local_only)])
def setup_abos(refresh: bool = False):
    from . import abos
    return abos.status(refresh=refresh)


@app.get("/api/setup/abos/refresh", dependencies=[Depends(local_only)])
def setup_abos_refresh():
    from . import abos
    return abos.status(refresh=True)


@app.patch("/api/setup/abos", dependencies=[Depends(local_only)])
def setup_abos_patch(body: dict):
    return _abos_patch(body)


@app.post("/api/setup/abos/{provider}/login", dependencies=[Depends(local_only)])
def setup_abos_login(provider: str):
    return _abos_login(provider)


@app.post("/api/setup/node-pair", dependencies=[Depends(local_only)])
def setup_node_pair():
    """Kopplungscode für „Dieser Mac“ (Scoops-Connect-Teil der Mac-App) – ohne API-Token, nur lokal."""
    return computers.create_pairing()


@app.post("/api/setup/reload", dependencies=[Depends(local_only)])
def setup_reload():
    """Nach dem Ändern von Schlüsseln: Composio-Sitzung anlegen (falls nötig) und Apps neu laden."""
    out: dict = {"ok": True}
    if _keychain(kc("composio"), "api-key") and not load_config().get("composio_session_id"):
        try:
            connections.ensure_session()
            out["composio"] = "created"
        except RuntimeError as e:
            out["composio"] = f"error: {e}"
    try:
        service.mcp_hub.configure(mcp_servers())
        threading.Thread(target=service.mcp_hub.warm, daemon=True).start()
    except Exception as e:  # noqa: BLE001
        out["mcp_error"] = str(e)
    return out


@app.post("/api/setup/link", dependencies=[Depends(local_only)])
def setup_link(body: dict | None = None):
    try:
        return cloud.start_link(force=bool((body or {}).get("force")))
    except RuntimeError as e:
        raise HTTPException(409, str(e)) from None
    except Exception as e:  # noqa: BLE001 – Convex nicht erreichbar
        raise HTTPException(502, f"Konto-Dienst nicht erreichbar: {e}") from None


@app.websocket("/api/ws")
async def ws(websocket: WebSocket, token: str = ""):
    p = await asyncio.to_thread(principal_of, _given(websocket, token))
    if p is None:
        await websocket.close(code=4401)
        return
    if not p.is_owner and not await asyncio.to_thread(shares.for_user, p.user_id):
        await websocket.accept()  # erst annehmen, damit die App den Code 4403 sieht (statt HTTP 403)
        await websocket.close(code=4403)  # Gast ohne Share auf diesem Server
        return
    await websocket.accept()
    events.clients[websocket] = p
    device_id: str | None = None  # v1.18: diese Verbindung gehört einem Apple-Gerät (iPhone/iPad)
    loop = asyncio.get_running_loop()

    async def send_device(data: dict) -> None:
        await websocket.send_text(json.dumps(data, ensure_ascii=False))

    try:
        while True:
            msg = await websocket.receive_text()
            if '"device.' in msg and p.is_owner:
                try:
                    data = json.loads(msg)
                except ValueError:
                    continue
                typ = data.get("type") if isinstance(data, dict) else None
                if typ == "device.hello":
                    try:
                        dev = await asyncio.to_thread(apple_devices.register, data)
                    except ValueError as e:
                        await send_device({"type": "device.error", "data": {"error": str(e)}})
                        continue
                    if device_id and device_id != dev["id"]:
                        apple_devices.detach(device_id, websocket)
                    device_id = dev["id"]
                    apple_devices.attach(device_id, websocket, loop, send_device, active=data.get("active", True) is not False)
                    await send_device({"type": "device.welcome", "data": dev})
                    for cmd in apple_devices.pending_for(device_id):
                        await send_device({"type": "device.cmd", "data": cmd})
                elif typ == "device.state" and device_id:
                    active = data.get("active", True) is not False
                    await asyncio.to_thread(apple_devices.set_active, device_id, active)
                    if active:
                        for cmd in apple_devices.pending_for(device_id):
                            await send_device({"type": "device.cmd", "data": cmd})
                elif typ == "device.result":
                    await asyncio.to_thread(apple_devices.resolve, device_id, str(data.get("id") or ""), data.get("result"))
                continue
            if '"ping"' in msg:
                await websocket.send_text('{"type":"pong"}')
    except WebSocketDisconnect:
        pass
    finally:
        events.clients.pop(websocket, None)
        if device_id:
            await asyncio.to_thread(apple_devices.detach, device_id, websocket)


# -- Live-Sprechmodus (GPT-Live-1, live_voice.py) -----------------------------
from . import live_voice  # noqa: E402
from .db import DATA_DIR as _LIVE_DATA_DIR  # noqa: E402

def _live_guest_check(p: Principal, chat: str):
    """Sprechmodus für Gäste: Share mit Rolle „Schreiben“ auf diesen Scoop; Rest des Tageslimits."""
    try:
        g = guest_principal(p, chat, "write")
    except HTTPException:
        return False, None, None
    left = service.guest_settings(chat)["guest_budget"] - db.guest_spent_today(p.user_id)
    return True, g.share, left


live_voice.register(app, service=service, token_ok=token_ok, keychain=lambda s, a: _keychain(s, a), kc=kc,
                    load_config=load_config, auth_dep=auth, data_dir=_LIVE_DATA_DIR,
                    principal_of=principal_of, guest_dep=shared("write", via="query"),
                    guest_check=_live_guest_check)
# -- Ende Live-Sprechmodus ------------------------------------------------------


def main() -> None:
    import uvicorn

    print(f"AIS-Bot-Server {VERSION} auf http://{HOST}:{PORT}", flush=True)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning", ws_ping_interval=20, ws_max_size=WS_MAX_SIZE)


if __name__ == "__main__":
    main()
