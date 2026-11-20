"""Abo-Limits für die Seite „Nutzung und Verbrauch“ (docs/nutzung.md).

Die Fenster gelten für das ganze Abo-Konto (alle Apps und Geräte). Quellen, jeweils ohne Modellaufruf und ohne dass
der Server Anmeldedaten sieht – die offiziellen Programme fragen ihr Konto selbst ab:

- Claude: Steuerbefehl `get_usage` der Claude-Code-CLI (wie `/usage`, `skip_behaviors`), über das Agent SDK mit dem
  Abo-Login. Ersatz: die letzten `RateLimitEvent`s aus Scoops-Läufen (`abos.note_info`, alle `unifiedWindows`).
- Codex: `account/rateLimits/read` und `account/usage/read` des Codex-App-Servers (eigenes CODEX_HOME der Scoops).
  Ersatz: die jüngste `rate_limits`-Meldung aus den lokalen Codex-Protokollen (usage_logs.py).

Der letzte Stand wird in `settings` gespeichert und überlebt Neustarts.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from datetime import datetime, timezone

from . import abos
from .i18n import N_, translate, tx, txn

SCOPE_NOTE = N_("Gesamtes Abo, alle Apps und Geräte")
MIN_REFRESH = 60.0  # höchstens jede Minute live abfragen
STALE_AFTER = 5 * 60.0  # ohne ausdrückliches Aktualisieren: älter als 5 Minuten → neu abfragen
WINDOW_MIN = {"five_hour": 300, "seven_day": 10080, "seven_day_opus": 10080, "seven_day_sonnet": 10080,
              "seven_day_oauth_apps": 10080, "seven_day_overage_included": 10080}
# Beschriftungen entstehen deutsch (auch in gespeicherten Ständen); `localize_label` übersetzt sie bei der Ausgabe
WEEKLY = N_("Wöchentlich")
WINDOW_LABEL = {"five_hour": "5-Stunden-Fenster", "seven_day": WEEKLY, "seven_day_opus": f"{WEEKLY} · Opus",
                "seven_day_sonnet": f"{WEEKLY} · Sonnet",
                "seven_day_oauth_apps": f"{WEEKLY} · " + N_("Drittanbieter-Apps"),
                "seven_day_overage_included": f"{WEEKLY} · " + N_("inkl. Zusatznutzung")}
_LABEL_PARTS = (N_("Täglich"), N_("Modell"))  # „Limit“ heißt in beiden Sprachen gleich
PLAN_LABEL = {"max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise", "plus": "Plus",
              "prolite": "Pro Lite", "free": "Free", "business": "Business", "edu": "Edu"}


def _iso(ts) -> str | None:
    if ts in (None, ""):
        return None
    if isinstance(ts, str):
        try:
            d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            return d.astimezone(timezone.utc).isoformat(timespec="seconds")
        except ValueError:
            return None
    try:
        t = float(ts)
        t = t / 1000 if t > 1e12 else t
        return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds")
    except (TypeError, ValueError, OSError):
        return None


def _pct(v, fraction: bool = False) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if fraction:
        f *= 100
    return round(max(0.0, min(100.0, f)), 1)


def _window_label_minutes(mins: int | None) -> tuple[str, str]:
    if mins == 300:
        return "5-Stunden-Fenster", "session"
    if mins == 10080:
        return "Wöchentlich", "weekly"
    if mins == 1440:
        return "Täglich", "daily"
    if mins and mins % 1440 == 0:
        return f"{mins // 1440} Tage", "other"
    if mins and mins % 60 == 0:
        return f"{mins // 60}-Stunden-Fenster", "session"
    return "Limit", "other"


def localize_label(label):
    """Fensterbeschriftung (deutsch erzeugt, ggf. gespeichert) in der aktuellen Sprache, Teil für Teil („ · “)."""
    if not isinstance(label, str):
        return label
    out = []
    for part in label.split(" · "):
        if m := re.fullmatch(r"(\d+)-Stunden-Fenster", part):
            part = tx("{n}-Stunden-Fenster", n=int(m.group(1)))
        elif m := re.fullmatch(r"(\d+) Tage", part):
            part = txn("{n} Tag", "{n} Tage", int(m.group(1)))
        elif part != "Limit":
            part = translate(part)
        out.append(part)
    return " · ".join(out)


def plan_label(plan) -> str | None:
    if not plan:
        return None
    p = str(plan)
    return PLAN_LABEL.get(p.lower(), p[:1].upper() + p[1:])


# -- Claude ----------------------------------------------------------------------------------------------------------
def parse_claude_usage(resp: dict) -> dict:
    """Antwort von `get_usage` → Fenster. `utilization` ist hier schon 0–100."""
    rl = resp.get("rate_limits") or {}
    windows = []
    for wid in ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"):
        w = rl.get(wid)
        if isinstance(w, dict) and w.get("utilization") is not None:
            windows.append({"id": wid, "label": WINDOW_LABEL[wid], "kind": "session" if wid == "five_hour" else
                            ("weekly" if wid == "seven_day" else "model"), "used_percent": _pct(w.get("utilization")),
                            "resets_at": _iso(w.get("resets_at")), "window_minutes": WINDOW_MIN[wid]})
    for m in rl.get("model_scoped") or []:
        if isinstance(m, dict) and m.get("utilization") is not None:
            name = str(m.get("display_name") or "Modell")
            windows.append({"id": f"model:{name.lower()}", "label": f"Wöchentlich · {name}", "kind": "model",
                            "used_percent": _pct(m.get("utilization")), "resets_at": _iso(m.get("resets_at")),
                            "window_minutes": 10080})
    extra = rl.get("extra_usage") if isinstance(rl.get("extra_usage"), dict) else None
    if extra:
        extra = {"enabled": bool(extra.get("is_enabled")), "monthly_limit": extra.get("monthly_limit"),
                 "used": extra.get("used_credits"), "used_percent": _pct(extra.get("utilization")),
                 "currency": extra.get("currency")}
    return {"windows": windows, "plan": plan_label(resp.get("subscription_type")), "extra_usage": extra,
            "available": bool(resp.get("rate_limits_available", bool(windows)))}


def parse_claude_event(info: dict) -> dict:
    """Gespeicherte RateLimitEvent-Fenster (`unifiedWindows`: Auslastung als Anteil 0–1, resetsAt in Sekunden)."""
    raw = info.get("windows") or {}
    windows = []
    for wid, w in raw.items():
        if not isinstance(w, dict) or w.get("utilization") is None:
            continue
        mins = WINDOW_MIN.get(wid)
        label = WINDOW_LABEL.get(wid) or ("Wöchentlich · " + wid.split("_")[-1].capitalize() if wid.startswith("seven_day")
                                          else wid)
        u = float(w.get("utilization"))
        windows.append({"id": wid, "label": label, "kind": "session" if wid == "five_hour" else
                        ("weekly" if wid == "seven_day" else "model"), "used_percent": _pct(u, fraction=u <= 1.0),
                        "resets_at": _iso(w.get("resetsAt") or w.get("resets_at")), "window_minutes": mins or 10080})
    return {"windows": windows, "plan": None, "extra_usage": None, "available": bool(windows)}


async def _claude_get_usage(timeout: float = 25.0) -> dict:
    from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
    abos.abo_dir().mkdir(parents=True, exist_ok=True)
    opts = ClaudeAgentOptions(tools=[], setting_sources=[], strict_mcp_config=True, cwd=str(abos.abo_dir()),
                              env=abos.claude_env({"DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
                                                   "CLAUDE_AGENT_SDK_CLIENT_APP": "ais-scoops-server"}),
                              max_buffer_size=abos.SDK_MAX_BUFFER, stderr=lambda s: None)
    client = ClaudeSDKClient(options=opts)
    await client.connect()
    try:
        q = client._query  # Steuerbefehl ohne Modellaufruf (wie /usage)
        return await q._send_control_request({"subtype": "get_usage", "skip_behaviors": True}, timeout=timeout)
    finally:
        try:
            await client.disconnect()
        except Exception:  # noqa: BLE001
            pass


def fetch_claude() -> dict:
    from .engine_abo import LOOP
    resp = LOOP.run(_claude_get_usage(), timeout=40)
    return parse_claude_usage(resp if isinstance(resp, dict) else {})


# -- Codex -----------------------------------------------------------------------------------------------------------
def _codex_window(w: dict | None, prefix: str = "") -> dict | None:
    if not isinstance(w, dict) or w.get("usedPercent", w.get("used_percent")) is None:
        return None
    mins = w.get("windowDurationMins", w.get("window_minutes"))
    label, kind = _window_label_minutes(int(mins) if mins else None)
    return {"id": f"{prefix}{mins or 'x'}", "label": label, "kind": kind,
            "used_percent": _pct(w.get("usedPercent", w.get("used_percent"))),
            "resets_at": _iso(w.get("resetsAt", w.get("resets_at"))), "window_minutes": int(mins) if mins else None}


def parse_codex_limits(rl: dict) -> dict:
    """`account/rateLimits/read` (oder `rate_limits` aus einem Protokoll) → Fenster, Credits."""
    buckets = rl.get("rateLimitsByLimitId") or {}
    snaps = list(buckets.values()) if isinstance(buckets, dict) and buckets else [rl.get("rateLimits") or rl]
    windows, credits, plan = [], None, None
    for s in snaps:
        if not isinstance(s, dict):
            continue
        lid = s.get("limitId") or s.get("limit_id") or "codex"
        name = s.get("limitName") or s.get("limit_name") or s.get("normalModelSlug")
        for key in ("primary", "secondary"):
            w = _codex_window(s.get(key), f"{lid}:{key}:")
            if w:
                if lid != "codex" and name:
                    w["label"] = f"{w['label']} · {name}"
                    w["kind"] = "model"
                windows.append(w)
        c = s.get("credits")
        if isinstance(c, dict) and credits is None:
            bal = c.get("balance")
            try:
                bal = float(bal) if bal is not None else None
            except (TypeError, ValueError):
                bal = None
            credits = {"has_credits": bool(c.get("hasCredits", c.get("has_credits"))), "unlimited": bool(c.get("unlimited")),
                       "balance": bal}
        plan = plan or s.get("planType") or s.get("plan_type")
    resets = rl.get("rateLimitResetCredits")
    extra = None
    if isinstance(resets, dict) and resets.get("availableCount") is not None:
        extra = {"reset_credits": int(resets.get("availableCount") or 0)}
    return {"windows": windows, "plan": plan_label(plan), "credits": credits, "extra": extra, "available": bool(windows)}


def parse_codex_usage(us: dict) -> dict:
    days = [{"day": b.get("startDate"), "tokens": int(b.get("tokens") or 0)} for b in us.get("dailyUsageBuckets") or []
            if isinstance(b, dict) and b.get("startDate")]
    s = us.get("summary") or {}
    return {"days": days, "lifetime_tokens": s.get("lifetimeTokens"), "peak_daily_tokens": s.get("peakDailyTokens")}


def fetch_codex() -> tuple[dict, dict | None]:
    from openai_codex import Codex, CodexConfig
    with Codex(CodexConfig(codex_bin=abos.codex_bin(), config_overrides=abos.codex_overrides(), env=abos.codex_env(),
                           cwd=str(abos.codex_home()))) as c:
        rl = c._client._request_raw("account/rateLimits/read", None)
        try:
            us = c._client._request_raw("account/usage/read", {})
        except Exception:  # noqa: BLE001 – älteres Codex: kein kontoweiter Verlauf
            us = None
    rl = rl if isinstance(rl, dict) else {}
    rl.pop("accountId", None)
    return parse_codex_limits(rl), (parse_codex_usage(us) if isinstance(us, dict) else None)


# -- Dienst ----------------------------------------------------------------------------------------------------------
class Limits:
    def __init__(self, db, fetch_claude_fn=None, fetch_codex_fn=None):
        self.db = db
        self._fc = fetch_claude_fn or fetch_claude
        self._fx = fetch_codex_fn or fetch_codex
        self._lock = threading.Lock()
        self._busy: dict[str, threading.Event] = {}
        self._tried: dict[str, float] = {}

    def _live_allowed(self) -> bool:
        from . import demo
        if demo.active():
            return False  # Demo-Server: nie die Abo-Konten dieses Macs abfragen
        return os.environ.get("AISBOT_OFFLINE") != "1" or os.environ.get("AISBOT_ABO") == "1"

    def _load(self, key: str) -> dict | None:
        v = self.db.setting(key)
        try:
            return json.loads(v) if v else None
        except ValueError:
            return None

    def _save(self, key: str, value: dict) -> None:
        self.db.set_setting(key, json.dumps(value))

    def account_usage(self) -> dict | None:
        return self._load("usage_account_openai")

    def _refresh_one(self, provider: str) -> None:
        try:
            if provider == "claude":
                data = self._fc()
                self._save("usage_limits_claude", {**data, "at": time.time(), "source": "live"})
            else:
                data, usage = self._fx()
                self._save("usage_limits_openai", {**data, "at": time.time(), "source": "live"})
                if usage and usage.get("days"):
                    self._save("usage_account_openai", {**usage, "at": time.time()})
            self.db.set_setting(f"usage_limits_error_{provider}", "")
        except Exception as e:  # noqa: BLE001
            self.db.set_setting(f"usage_limits_error_{provider}", f"{type(e).__name__}: {str(e)[:160]}")

    def refresh(self, providers: list[str], force: bool = False, wait: float = 30.0) -> None:
        """Fragt die Programme live ab (parallel, höchstens jede Minute), nur für angemeldete Anbieter."""
        if not self._live_allowed():
            return
        threads = []
        for p in providers:
            cached = self._load(f"usage_limits_{p}") or {}
            age = time.time() - float(cached.get("at") or 0)
            if not force and age < STALE_AFTER:
                continue
            with self._lock:
                if time.time() - self._tried.get(p, 0) < MIN_REFRESH and p not in self._busy:
                    continue
                ev = self._busy.get(p)
                if ev is None:
                    ev = threading.Event()
                    self._busy[p] = ev
                    self._tried[p] = time.time()

                    def run(prov=p, e=ev):
                        try:
                            self._refresh_one(prov)
                        finally:
                            with self._lock:
                                self._busy.pop(prov, None)
                            e.set()
                    th = threading.Thread(target=run, daemon=True, name=f"limits-{p}")
                    th.start()
            threads.append(ev)
        deadline = time.time() + wait
        for ev in threads:
            ev.wait(max(0.0, deadline - time.time()))

    def snapshot(self, refresh: bool = False, wait: float = 30.0) -> dict:
        status = {p: abos.login_status(p) for p in abos.PROVIDERS}
        logged = [p for p in abos.PROVIDERS if status[p].get("subscription")]
        self.refresh(logged, force=refresh, wait=wait)
        out = []
        for p in abos.PROVIDERS:
            st = status[p]
            cand = []
            live = self._load(f"usage_limits_{p}")
            if live and live.get("windows"):
                cand.append(live)
            if p == "claude":
                ev = abos.stored_info("claude")
                if ev and ev.get("windows"):
                    cand.append({**parse_claude_event(ev), "at": ev.get("at"), "source": "event"})
            else:
                lg = self._load("codex_rate_limits_logs")
                if lg and lg.get("data"):
                    cand.append({**parse_codex_limits(lg["data"]), "at": lg.get("t"), "source": "logs"})
            best = max(cand, key=lambda c: float(c.get("at") or 0), default=None)
            err = self.db.setting(f"usage_limits_error_{p}") or None
            if not st.get("subscription"):
                state = "not_logged_in"
            elif best:
                state = "ok"
            else:
                state = "unavailable"
            out.append({
                "id": p, "label": "Claude" if p == "claude" else "OpenAI",
                "app_label": tx("Claude-Abo (Claude Code)") if p == "claude" else tx("ChatGPT-Abo (Codex)"),
                "logged_in": bool(st.get("logged_in")), "subscription": bool(st.get("subscription")),
                "state": state, "plan": (best or {}).get("plan") or plan_label(st.get("plan")),
                "source": (best or {}).get("source"), "at": _iso((best or {}).get("at")),
                "windows": [{**w, "label": localize_label(w.get("label"))} for w in (best or {}).get("windows") or []],
                "credits": (best or {}).get("credits"),
                "extra_usage": (best or {}).get("extra_usage"), "extra": (best or {}).get("extra"),
                "error": err if st.get("subscription") else None,  # letzter Abfragefehler (Stand bleibt sichtbar)
            })
        return {"providers": out, "scope_note": translate(SCOPE_NOTE), "generated_at": _iso(time.time())}
