"""KI-Abos (docs/abos.md): Claude Max/Pro über Claude Code, ChatGPT Plus/Pro über Codex statt API-Schlüssel.

Der Server steuert die unveränderten offiziellen Programme (Claude Agent SDK mit der gebündelten Claude-Code-CLI,
Codex SDK mit der gebündelten Codex-CLI). Angemeldet wird ausschließlich im Programm selbst (`claude auth login`,
`codex login`); diese Datei startet den Login-Ablauf nur und fragt den Status über die Programme ab.

Harte Regeln (Anthropic-/OpenAI-Bedingungen):
- Nie Anmeldedaten oder Tokens einsammeln, lesen, speichern, weiterreichen oder ausgeben (kein `setup-token`, kein
  Schlüsselbund-Zugriff, kein Lesen von ~/.claude/.credentials*, ~/.codex/auth.json oder <data>/abo/codex/auth.json).
- Binärdateien unverändert lassen.

Abrechnungsmodus pro Anbieter (`config.json` → `billing: {"claude": …, "openai": …}`):
- "api": wie bisher über den API-Schlüssel,
- "abo": nur über das Abo (ohne Login/bei Limit → klarer Fehler),
- "abo_api": Abo, bei Limit oder Abo-Fehler auf den API-Schlüssel ausweichen (mit kurzem Hinweis).
Ohne Eintrag gilt "api", bis sich der Nutzer im Programm angemeldet hat; danach automatisch "abo_api".
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

PROVIDERS = ("claude", "openai")
MODES = ("api", "abo", "abo_api")
MODE_LABEL = {"api": "API-Schlüssel", "abo": "Abo", "abo_api": "Abo, bei Limit API"}
PROVIDER_LABEL = {"claude": "Claude (Claude Code)", "openai": "ChatGPT (Codex)"}
STATUS_TTL = 60.0  # Login-Status höchstens jede Minute neu abfragen
# Claude Agent SDK: größte JSON-Zeile von Claude Code (Standard 1 MB). Ein Werkzeug-Ergebnis mit Bildschirmbild einer vollen
# Webseite (X, Dia …) war als Base64 größer; der Lauf brach mit „JSON message exceeded maximum buffer size“ ab (Server 1.35).
SDK_MAX_BUFFER = 64 * 1024 * 1024
LIMIT_BACKOFF = 15 * 60  # Abo-Limit ohne Rücksetzzeit: so lange gleich die API nehmen
# Umgebungsvariablen, die ein Programm statt seines eigenen Logins nehmen würde. Im Abo-Weg werden sie geleert,
# damit garantiert der Login des Programms gilt (und nie ein Schlüssel des Servers).
CLAUDE_ENV_BLANK = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")
# Nie leer übergeben, sondern ganz weglassen: Claude Code nimmt CLAUDE_CONFIG_DIR="" als Konfigordner "" (relative Pfade
# im Arbeitsordner, ab und zu „API Error: ENOENT: no such file or directory, mkdir“, Server 1.37). Die SDK-Umgebung kann
# Variablen nur setzen, nicht entfernen; darum entfernt claude_env() sie aus der Umgebung des Serverprozesses.
CLAUDE_ENV_DROP = ("CLAUDE_CONFIG_DIR",)
CODEX_ENV_BLANK = ("OPENAI_API_KEY", "CODEX_API_KEY", "AISBOT_OPENAI_KEY", "OPENAI_BASE_URL")


class SubscriptionUnavailable(RuntimeError):
    """Abo-Weg geht gerade nicht (nicht angemeldet, Limit, Abo-Fehler). `limit` = Nutzungslimit erreicht."""

    def __init__(self, provider: str, reason: str, limit: bool = False, resets_at: float | None = None,
                 started: bool = False):
        super().__init__(reason)
        self.provider, self.reason, self.limit, self.resets_at = provider, reason, limit, resets_at
        self.started = started  # True: der Lauf hatte schon Werkzeuge ausgeführt


# -- Pfade und Programme ----------------------------------------------------------------------------------------------
def explain_sdk_error(e: BaseException) -> str:
    """Ehrlicher Fehlertext für Fehler des Agent-SDK-Transports. Ohne das sprach der Scoop bei zu großen Bildschirmbildern
    von einer „abgebrochenen Bildschirmverbindung“."""
    s = str(e)
    if "maximum buffer size" in s or "Failed to decode JSON" in s:
        return ("Interner Fehler im Scoops-Server: Eine Nachricht von Claude Code (meist ein Bildschirmbild) war zu groß "
                f"für die Verbindung ({s[:160]}). Das ist keine abgebrochene Bildschirmverbindung; bitte so melden.")
    return s


def abo_dir() -> Path:
    from .profile import DATA_DIR
    return DATA_DIR / "abo"


def codex_home() -> Path:
    """Eigener CODEX_HOME für die Scoops. Codex lädt immer config.toml (MCP-Server, Plugins) aus seinem Home; Armans
    ~/.codex enthält z. B. 1Password- und Computer-Use-Server, die Scoops nie bekommen sollen. Darum meldet sich der
    Nutzer hier einmal selbst an (`codex login`); Codex speichert den Login in diesem Ordner (Datei, nicht Schlüsselbund,
    damit Updates der signierten App keine Schlüsselbund-Abfragen auslösen). Der Server liest ihn nie."""
    p = Path(os.environ["AISBOT_CODEX_HOME"]) if os.environ.get("AISBOT_CODEX_HOME") else abo_dir() / "codex"
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def claude_bin() -> str | None:
    """Gebündelte Claude-Code-CLI des Agent SDK (dieselbe, die das SDK startet)."""
    try:
        import claude_agent_sdk
        p = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
        if p.exists():
            return str(p)
    except Exception:  # noqa: BLE001
        pass
    for c in ("/opt/homebrew/bin/claude", "/usr/local/bin/claude", str(Path.home() / ".local/bin/claude")):
        if os.path.exists(c):
            return c
    return None


def codex_bin() -> str | None:
    """Gebündelte Codex-CLI (openai-codex-cli-bin), dieselbe wie im Codex SDK."""
    try:
        import codex_cli_bin
        p = Path(codex_cli_bin.__file__).parent / "bin" / "codex"
        if p.exists():
            return str(p)
    except Exception:  # noqa: BLE001
        pass
    for c in (str(Path.home() / ".local/bin/codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex"):
        if os.path.exists(c):
            return c
    return None


def resume_failed(text: str) -> bool:
    """Claude Code kennt die gespeicherte Sitzung nicht (mehr), z. B. nach dem Wechsel des Konfigordners (Server 1.37)."""
    t = (text or "").lower()
    return "no conversation found" in t or ("session" in t and "not found" in t)


def claude_env(extra: dict | None = None) -> dict:
    """Umgebung für Claude Code im Abo-Weg: Standard-Konfiguration (der Login des Nutzers), keine Schlüssel."""
    for k in CLAUDE_ENV_DROP:
        os.environ.pop(k, None)
    env = {k: "" for k in CLAUDE_ENV_BLANK}
    env.update(extra or {})
    return env


def codex_overrides() -> tuple[str, ...]:
    """Codex im Abo-Weg: Login aus Datei im eigenen CODEX_HOME, keine Fremd-Werkzeuge, keine Updates."""
    return ('cli_auth_credentials_store="file"', 'forced_login_method="chatgpt"', 'check_for_update_on_startup=false',
            'history.persistence="none"', "features.memories=false", "features.plugins=false", "features.apps=false",
            "features.browser_use=false", "features.in_app_browser=false", "features.computer_use=false")


def codex_env(extra: dict | None = None) -> dict:
    env = {k: "" for k in CODEX_ENV_BLANK}
    env["CODEX_HOME"] = str(codex_home())
    env.update(extra or {})
    return env


def _clean_env(blank: tuple[str, ...], extra: dict) -> dict:
    env = {k: v for k, v in os.environ.items() if k not in blank}
    env.update({k: v for k, v in extra.items() if v})
    return env


# -- Status (über die Programme selbst) -------------------------------------------------------------------------------
_cache: dict[str, tuple[float, dict]] = {}
_lock = threading.Lock()


def _claude_status_now() -> dict:
    b = claude_bin()
    if not b:
        return {"installed": False, "logged_in": False, "subscription": False}
    try:
        r = subprocess.run([b, "auth", "status", "--json"], capture_output=True, text=True, timeout=20,
                           env=_clean_env(CLAUDE_ENV_BLANK + CLAUDE_ENV_DROP, {"DISABLE_AUTOUPDATER": "1"}), cwd=str(Path.home()))
        d = json.loads(r.stdout or "{}")
    except Exception as e:  # noqa: BLE001
        return {"installed": True, "logged_in": False, "subscription": False, "error": str(e)[:200]}
    sub = str(d.get("subscriptionType") or "")
    method = str(d.get("authMethod") or "")
    # Nur Felder, die der Nutzer sehen soll; keine Tokens (die gibt `auth status` auch nicht aus)
    return {"installed": True, "logged_in": bool(d.get("loggedIn")), "method": method,
            "subscription": bool(d.get("loggedIn")) and method == "claude.ai",
            "plan": sub or None, "plan_tier": d.get("planTier") or None, "account": d.get("email") or None,
            "expires_at": d.get("loginExpiresAt") or None}


def _codex_status_now() -> dict:
    b = codex_bin()
    if not b:
        return {"installed": False, "logged_in": False, "subscription": False}
    try:
        r = subprocess.run([b, *sum((["-c", o] for o in codex_overrides()), []), "login", "status"], capture_output=True,
                           text=True, timeout=20, env=_clean_env(CODEX_ENV_BLANK, codex_env()), cwd=str(Path.home()))
        text = (r.stdout + "\n" + r.stderr).strip()
    except Exception as e:  # noqa: BLE001
        return {"installed": True, "logged_in": False, "subscription": False, "error": str(e)[:200]}
    chatgpt = "chatgpt" in text.lower() and "logged in" in text.lower() and "not logged in" not in text.lower()
    api_key = "api key" in text.lower() and "not logged in" not in text.lower()
    out = {"installed": True, "logged_in": chatgpt or api_key, "method": "chatgpt" if chatgpt else ("api_key" if api_key else ""),
           "subscription": chatgpt, "plan": None, "account": None}
    if chatgpt:
        out.update(_codex_account())
    return out


_ACCOUNT: dict = {"at": 0.0, "data": {}}


def _codex_account() -> dict:
    if time.time() - _ACCOUNT["at"] < 1800:
        return _ACCOUNT["data"]
    data = _codex_account_now()
    _ACCOUNT.update(at=time.time(), data=data)
    return data


def _codex_account_now() -> dict:
    """Abo-Art über den App-Server von Codex (`account/read`), ohne Tokens. Fehler sind egal (Anzeige optional)."""
    try:
        from openai_codex import Codex, CodexConfig
        with Codex(CodexConfig(codex_bin=codex_bin(), config_overrides=codex_overrides(), env=codex_env(),
                               cwd=str(codex_home()))) as c:
            acc = c.account()
        d = acc.model_dump() if hasattr(acc, "model_dump") else {}
        a = d.get("account") or {}
        a = a.get("root", a) if isinstance(a, dict) else {}
        plan = a.get("plan_type") or a.get("planType")
        return {"plan": str(plan.value if hasattr(plan, "value") else plan) if plan else None, "account": a.get("email")}
    except Exception:  # noqa: BLE001
        return {}


def login_status(provider: str, refresh: bool = False) -> dict:
    with _lock:
        hit = _cache.get(provider)
        if hit and not refresh and time.time() - hit[0] < STATUS_TTL:
            return hit[1]
    st = _claude_status_now() if provider == "claude" else _codex_status_now()
    with _lock:
        _cache[provider] = (time.time(), st)
    return st


def set_status_for_tests(provider: str, st: dict) -> None:
    with _lock:
        _cache[provider] = (time.time() + 10 ** 9, st)


def clear_status() -> None:
    with _lock:
        _cache.clear()
    _ACCOUNT["at"] = 0.0


# -- Modus und Limits -------------------------------------------------------------------------------------------------
def _config() -> dict:
    from .bots import load_config
    return load_config()


def configured_mode(provider: str, cfg: dict | None = None) -> str | None:
    cfg = _config() if cfg is None else cfg
    v = (cfg.get("billing") or {}).get(provider) if isinstance(cfg.get("billing"), dict) else None
    return v if v in MODES else None


def mode(provider: str, cfg: dict | None = None) -> str:
    """Wirksamer Modus. Ohne Einstellung: "api", bis der Nutzer im Programm mit Abo angemeldet ist, dann "abo_api"."""
    from . import demo
    if demo.active(cfg):
        return "api"  # Demo-Server: nie über ein KI-Abo (docs/demo-server.md)
    m = configured_mode(provider, cfg)
    if m:
        return m
    if os.environ.get("AISBOT_OFFLINE") == "1" and os.environ.get("AISBOT_ABO") != "1":
        return "api"  # Tests/Probedurchlauf: nie still über ein echtes Abo (nur mit ausdrücklicher Einstellung)
    st = login_status(provider)
    return "abo_api" if st.get("subscription") else "api"


def set_mode(provider: str, value: str) -> None:
    from .bots import load_config, save_config
    if provider not in PROVIDERS or value not in MODES:
        raise ValueError("Anbieter claude/openai, Modus api/abo/abo_api")
    cfg = load_config()
    b = dict(cfg.get("billing") or {})
    b[provider] = value
    cfg["billing"] = b
    save_config(cfg)


# Limit-Zustand pro Anbieter (im Speicher; nach Neustart wird neu probiert)
_limits: dict[str, dict] = {}
_info: dict[str, dict] = {}


def note_limit(provider: str, reason: str, resets_at: float | None = None) -> None:
    until = resets_at if resets_at and resets_at > time.time() else time.time() + LIMIT_BACKOFF
    _limits[provider] = {"until": until, "reason": reason[:300], "since": time.time()}


def clear_limit(provider: str) -> None:
    _limits.pop(provider, None)


def limited(provider: str) -> dict | None:
    lim = _limits.get(provider)
    if lim and lim["until"] > time.time():
        return lim
    _limits.pop(provider, None)
    return None


def note_info(provider: str, info: dict) -> None:
    """Letzte Limit-Meldung des Programms (Auslastung, Fenster, Rücksetzzeit) für die Anzeige. Alle gemeldeten
    Fenster werden zusätzlich dauerhaft gemerkt (`<data>/abo/limits.json`, nur Zahlen), damit die Seite „Nutzung und
    Verbrauch“ sie auch nach einem Neustart zeigt."""
    _info[provider] = {**info, "at": time.time()}
    windows = info.get("windows")
    if not isinstance(windows, dict) or not windows:
        return
    try:
        stored = _load_limits()
        prev = (stored.get(provider) or {}).get("windows") or {}
        now_ts = time.time()
        # Fenster, die diese Meldung nicht enthält, bleiben, solange sie nicht zurückgesetzt sind
        keep = {k: v for k, v in prev.items() if isinstance(v, dict) and float(v.get("resetsAt") or 0) > now_ts}
        keep.update(windows)
        stored[provider] = {"windows": keep, "at": now_ts}
        p = abo_dir() / "limits.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(stored))
        tmp.replace(p)
    except Exception:  # noqa: BLE001 – Anzeige ist optional
        pass


def _load_limits() -> dict:
    try:
        d = json.loads((abo_dir() / "limits.json").read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def stored_info(provider: str) -> dict | None:
    """Zuletzt gemeldete Fenster (aus Scoops-Läufen) mit Zeitstempel, auch nach einem Neustart."""
    return _load_limits().get(provider)


def has_api_key(provider: str) -> bool:
    try:
        if provider == "claude":
            from .config import anthropic_api_key
            return bool(anthropic_api_key())
        from .engine_openai import _key
        return bool(_key())
    except Exception:  # noqa: BLE001
        return False


def provider_of(model: str) -> str:
    return "openai" if (model or "").startswith("gpt-") else "claude"


def model_supports_abo(model: str | None) -> bool:
    """Kann dieses Modell laut Modellkatalog über das Abo laufen (Weg claude_abo/chatgpt_abo)? Unbekannte: ja."""
    if not model:
        return True
    from .models_catalog import current
    c = current()
    m = c.models.get(c.resolve(model) or "")
    return m is None or ("chatgpt_abo" if m.provider == "openai" else "claude_abo") in m.routes


def route(provider: str, model: str | None = None) -> str:
    """Welcher Weg jetzt: "abo" oder "api". Abo nur mit Abo-Login im Programm; "abo_api" weicht bei Limit aus.
    `model`: Modelle, die laut Katalog nicht übers Abo laufen, nehmen den API-Schlüssel."""
    if not model_supports_abo(model):
        return "api"
    m = mode(provider)
    if m == "api":
        return "api"
    st = login_status(provider)
    if not st.get("subscription"):
        return "api" if m == "abo_api" else "abo"  # "abo" ohne Login → der Lauf meldet es klar
    if m == "abo_api" and limited(provider) and has_api_key(provider):
        return "api"
    return "abo"


def fallback_allowed(provider: str) -> bool:
    return mode(provider) == "abo_api" and has_api_key(provider)


def status(refresh: bool = False) -> dict:
    """Für Server-App und Admin-Ansicht: pro Anbieter Login, Abo-Art, Modus, Limit."""
    out = {}
    for p in PROVIDERS:
        st = login_status(p, refresh=refresh)
        lim = limited(p)
        info = _info.get(p)
        out[p] = {
            "label": PROVIDER_LABEL[p], "mode": mode(p), "mode_label": MODE_LABEL[mode(p)],
            "configured": configured_mode(p), "route": route(p), "api_key": has_api_key(p),
            "installed": bool(st.get("installed")), "logged_in": bool(st.get("logged_in")),
            "subscription": bool(st.get("subscription")), "method": st.get("method") or None,
            "plan": st.get("plan"), "account": st.get("account"),
            "limit": {"reason": lim["reason"], "until": _iso(lim["until"])} if lim else None,
            "usage": _public_info(info) if info else None,
            "login_command": login_command(p, shown=True),
        }
    out["modes"] = [{"id": m, "label": MODE_LABEL[m]} for m in MODES]
    try:  # Computer Use von Codex (Server 1.36, codex_cu.py): Schalter und Zustand; ältere Server haben das Feld nicht
        from . import codex_cu
        out["codex_computer_use"] = codex_cu.status()
    except Exception as e:  # noqa: BLE001
        print("Computer-Use-Status:", e, flush=True)
    return out


def _iso(ts: float | None) -> str | None:
    if not ts:
        return None
    from datetime import datetime, timezone
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds")


def _public_info(info: dict) -> dict:
    return {"status": info.get("status"), "window": info.get("window"), "utilization": info.get("utilization"),
            "resets_at": _iso(info.get("resets_at")), "at": _iso(info.get("at"))}


# -- Login starten (offizieller Ablauf des Programms) -----------------------------------------------------------------
def login_command(provider: str, shown: bool = False) -> str | None:
    """Befehl, den der Nutzer im Terminal ausführt (bzw. den die Server-App in einem Terminal-Fenster startet)."""
    if provider == "claude":
        b = claude_bin()
        if not b:
            return None
        unset = " ".join(f"-u {k}" for k in CLAUDE_ENV_BLANK)
        return f"env {unset} {shlex.quote(b)} auth login --claudeai"
    b = codex_bin()
    if not b:
        return None
    home = codex_home()
    cfg = " ".join(f"-c {shlex.quote(o)}" for o in codex_overrides()[:2])
    unset = " ".join(f"-u {k}" for k in CODEX_ENV_BLANK)
    return f"env {unset} CODEX_HOME={shlex.quote(str(home))} {shlex.quote(b)} {cfg} login"


def start_login(provider: str) -> dict:
    """Öffnet ein Terminal-Fenster mit dem Login-Befehl des Programms. Der Nutzer meldet sich dort (bzw. im Browser,
    den das Programm öffnet) selbst an; der Server sieht davon nichts außer dem Status danach."""
    if provider not in PROVIDERS:
        raise ValueError("Anbieter claude oder openai")
    cmd = login_command(provider)
    if not cmd:
        raise RuntimeError("Programm nicht gefunden (Server-Runtime unvollständig)")
    if sys.platform != "darwin" or os.environ.get("AISBOT_NO_TERMINAL") == "1" or (
            os.environ.get("AISBOT_OFFLINE") == "1" and os.environ.get("AISBOT_ABO") != "1"):
        return {"started": False, "command": cmd}  # Tests: nie ein Terminal öffnen
    d = abo_dir()
    d.mkdir(parents=True, exist_ok=True)
    script = d / f"anmelden-{provider}.command"
    title = "Mit Claude anmelden" if provider == "claude" else "Mit ChatGPT anmelden"
    script.write_text("#!/bin/zsh\n"
                      f"echo '{title} – AIS Scoops nutzt danach dein Abo.'\n"
                      "echo 'Melde dich im Browser an, der sich gleich öffnet.'\necho\n"
                      f"{cmd}\n"
                      "echo\necho 'Fertig. Dieses Fenster kannst du schließen.'\n")
    os.chmod(script, 0o700)
    subprocess.Popen(["/usr/bin/open", "-a", "Terminal", str(script)], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)
    clear_status()
    return {"started": True, "command": cmd}


# -- Fehler deuten ---------------------------------------------------------------------------------------------------
_LIMIT_RE = re.compile(r"usage limit|rate.?limit|limit reached|out of (?:extra )?usage|usage_limit|quota|"
                       r"too many requests|\b429\b|weekly limit|session limit|5-hour limit", re.I)
_AUTH_RE = re.compile(r"not logged in|please run /login|authentication|unauthori[sz]ed|\b401\b|invalid api key|"
                      r"oauth token|login (?:expired|required)|credit balance|billing", re.I)


def classify(text: str) -> str | None:
    """"limit" | "auth" | None für eine Fehlermeldung eines Programms."""
    t = text or ""
    if _LIMIT_RE.search(t):
        return "limit"
    if _AUTH_RE.search(t):
        return "auth"
    return None
