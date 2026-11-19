"""Seite „Nutzung und Verbrauch“ (docs/nutzung.md): Kosten und Tokens über alle Abo-Apps auf diesem Mac plus die echten
API-Kosten der Scoops.

Datenquellen:
- `log_usage` (usage_logs.py): Abo-Verbrauch aus den Protokollen von Claude Code und Codex – alle Apps auf diesem Mac,
  Scope „scoops“ für die eigenen Abo-Läufe der Scoops. Bewertet zum API-Listenpreis (Schätzung).
- `usage` mit `billing IS NULL`: echte API-Kosten der Scoops (Betrag wie gespeichert).
- `usage` mit `billing='abo'`: nur als Ersatz, wenn für Anbieter und Tag keine Scoops-Einträge in den Protokollen stehen
  (sonst doppelt gezählt).
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta

from .config import price_for
from .db import TZ, now

RANGES = {"24h": 1, "7d": 7, "30d": 30, "90d": 90}
PROVIDERS = ("claude", "openai")
PROVIDER_LABEL = {"claude": "Claude", "openai": "OpenAI"}
SOURCE_LABEL = {"scoops": "AIS Scoops", "other": "Andere Apps auf diesem Mac"}
APP_LABEL = {
    "scoops": "AIS Scoops", "cli": "Claude Code (Terminal)", "sdk-cli": "Claude Code (Skript)",
    "t3-code": "T3 Code", "sdk-ts": "Agent SDK (TypeScript)", "sdk-py": "Agent SDK (Python)",
    "claude-desktop": "Claude Desktop", "claude-vscode": "VS Code", "claude-jetbrains": "JetBrains",
    "Codex Desktop": "Codex Desktop", "T3 Code": "T3 Code", "t3code_desktop": "T3 Code", "codex_exec": "Codex (exec)",
    "codex_cli_rs": "Codex CLI", "codex-tui": "Codex CLI", "codex_vscode": "VS Code", "codex_python_sdk": "Codex SDK",
    "codex_sdk_ts": "Codex SDK", "lucy_whatsapp": "Lucy (WhatsApp)",
}
TYPES = ("input", "cache_read", "cache_write", "output")


def provider_of(model: str) -> str:
    m = (model or "").lower()
    return "openai" if m.startswith(("gpt", "o1", "o3", "o4", "codex", "chatgpt")) else "claude"


def app_label(app: str) -> str:
    return APP_LABEL.get(app) or APP_LABEL.get((app or "").lower()) or (app or "Unbekannt")


def model_label(model: str) -> str:
    from .models_catalog import current
    known = current().models.get(model or "")
    if known:
        return known.label  # Anzeigename aus dem Modellkatalog (auch für abgelöste Kennungen der Kostenhistorie)
    m = model or ""
    if m.startswith("claude-"):
        parts = m[7:].split("-")
        if len(parts) >= 2 and all(p.isdigit() for p in parts[1:]):
            return f"{parts[0].capitalize()} {'.'.join(parts[1:])}"
        return m[7:].replace("-", " ").title()
    if m.startswith("gpt-"):
        bits = m[4:].split("-")
        if bits[0].isalpha():
            return "GPT-" + "-".join(b.capitalize() for b in bits)
        return "GPT-" + bits[0] + ("" if len(bits) == 1 else " " + " ".join(b.capitalize() for b in bits[1:]))
    return m


def cost_parts(model: str, inp: int, out: int, cr: int, cw: int) -> tuple[dict, bool, bool]:
    """Kosten nach Typ zum Listenpreis ($), ob bepreist, ob Preis geschätzt (Familie)."""
    p, _ref, approx = price_for(model)
    if p is None:
        return {t: 0.0 for t in TYPES}, False, False
    return ({"input": inp * p.input / 1e6, "cache_read": cr * p.cache_read / 1e6,
             "cache_write": cw * p.cache_write / 1e6, "output": out * p.output / 1e6}, True, approx)


def _window(rng: str) -> tuple[datetime, str, list[str]]:
    """Beginn, Bucket-Art und alle Bucket-Schlüssel (Europe/Berlin)."""
    n = now()
    if rng == "24h":
        start = (n - timedelta(hours=23)).replace(minute=0, second=0, microsecond=0)
        keys = [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H") for i in range(24)]
        return start, "hour", keys
    days = RANGES[rng]
    start = (n - timedelta(days=days - 1)).replace(hour=0, minute=0, second=0, microsecond=0)
    keys = [(start + timedelta(days=i)).strftime("%Y-%m-%d") for i in range(days)]
    return start, "day", keys


def _bucket_label(key: str, bucket: str) -> str:
    if bucket == "hour":
        return f"{int(key[11:13])} Uhr"
    return f"{int(key[8:10])}.{int(key[5:7])}."


class _Acc:
    __slots__ = ("cost", "api", "abo", "input", "output", "cache_read", "cache_write", "reasoning", "requests",
                 "types", "unpriced", "approx", "scoops_cost", "scoops_tokens")

    def __init__(self):
        self.cost = self.api = self.abo = self.scoops_cost = 0.0
        self.input = self.output = self.cache_read = self.cache_write = self.reasoning = self.requests = 0
        self.unpriced = self.scoops_tokens = 0
        self.approx = False
        self.types = {t: 0.0 for t in TYPES}

    @property
    def tokens(self) -> int:
        return self.input + self.output + self.cache_read + self.cache_write

    def add(self, r: dict) -> None:
        self.cost += r["cost"]
        self.api += r["api"]
        self.abo += r["abo"]
        for k in ("input", "output", "cache_read", "cache_write", "reasoning", "requests"):
            setattr(self, k, getattr(self, k) + r[k])
        for t in TYPES:
            self.types[t] += r["types"][t]
        if not r["priced"]:
            self.unpriced += r["input"] + r["output"] + r["cache_read"] + r["cache_write"]
        self.approx = self.approx or r["approx"]
        if r["scope"] == "scoops":
            self.scoops_cost += r["cost"]
            self.scoops_tokens += r["input"] + r["output"] + r["cache_read"] + r["cache_write"]

    def out(self, total_cost: float = 0, total_tokens: int = 0) -> dict:
        d = {"cost_usd": round(self.cost, 4), "api_usd": round(self.api, 4), "abo_usd": round(self.abo, 4),
             "tokens": self.tokens, "input": self.input, "output": self.output, "cache_read": self.cache_read,
             "cache_write": self.cache_write, "reasoning": self.reasoning, "requests": self.requests,
             "scoops_usd": round(self.scoops_cost, 4), "scoops_tokens": self.scoops_tokens}
        d["share_cost"] = round(self.cost / total_cost, 4) if total_cost else 0.0
        d["share_tokens"] = round(self.tokens / total_tokens, 4) if total_tokens else 0.0
        if self.unpriced:
            d["unpriced_tokens"] = self.unpriced
        if self.approx:
            d["price_estimated"] = True
        return d


def _rows(db, rng: str, source: str, logs_ok: bool) -> tuple[list[dict], datetime, str, list[str], int]:
    start, bucket, keys = _window(rng)
    t0 = int(start.timestamp())
    rows: list[dict] = []
    sessions = 0
    bcol = "hour" if bucket == "hour" else "day"
    scoops_days: set[tuple[str, str]] = set()
    if logs_ok:
        where, args = "t>=?", [t0]
        if source in ("scoops", "other"):
            where += " AND scope=?"
            args.append(source)
        for r in db.q(f"SELECT provider, scope, app, model, {bcol} b, day, SUM(input) i, SUM(output) o, "
                      "SUM(cache_read) cr, SUM(cache_write) cw, SUM(reasoning) rs, COUNT(*) n FROM log_usage "
                      f"WHERE {where} GROUP BY provider, scope, app, model, {bcol}", tuple(args)):
            types, priced, approx = cost_parts(r["model"], r["i"] or 0, r["o"] or 0, r["cr"] or 0, r["cw"] or 0)
            c = sum(types.values())
            rows.append({"provider": r["provider"], "scope": r["scope"], "app": r["app"], "model": r["model"],
                         "bucket": r["b"], "bot": None, "input": r["i"] or 0, "output": r["o"] or 0,
                         "cache_read": r["cr"] or 0, "cache_write": r["cw"] or 0, "reasoning": r["rs"] or 0,
                         "requests": r["n"] or 0, "types": types, "priced": priced, "approx": approx, "cost": c,
                         "api": 0.0, "abo": c})
            if r["scope"] == "scoops":
                scoops_days.add((r["provider"], r["day"]))
        s = db.one(f"SELECT COUNT(DISTINCT session) n FROM log_usage WHERE {where}", tuple(args))
        sessions = int(s["n"] or 0) if s else 0
    if source != "other":
        first_day = start.strftime("%Y-%m-%d")
        for r in db.q("SELECT bot_id, model, billing, created_at, dollars, input_tokens, output_tokens, cache_read, "
                      "cache_write FROM usage WHERE substr(created_at,1,10)>=?", (first_day,)):
            try:
                ts = datetime.fromisoformat(r["created_at"])
            except (TypeError, ValueError):
                continue
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=TZ)
            if ts < start:
                continue
            ts = ts.astimezone(TZ)
            prov = provider_of(r["model"])
            day = ts.strftime("%Y-%m-%d")
            abo = r["billing"] == "abo"
            if abo and (prov, day) in scoops_days:
                continue  # steht schon in den Protokollen
            i, o, cr, cw = (int(r["input_tokens"] or 0), int(r["output_tokens"] or 0), int(r["cache_read"] or 0),
                            int(r["cache_write"] or 0))
            types, priced, approx = cost_parts(r["model"], i, o, cr, cw)
            est = sum(types.values())
            actual = float(r["dollars"] or 0) if not abo else 0.0
            if actual != actual:  # NaN (unbekanntes Modell)
                actual = 0.0
            if not abo and actual > 0 and est > 0:
                # echte Kosten (inkl. Websuche) auf die Typen verteilen
                types = {t: v * actual / est for t, v in types.items()}
            elif not abo and actual > 0:
                types = {**{t: 0.0 for t in TYPES}, "input": actual}
            cost = est if abo else actual
            rows.append({"provider": prov, "scope": "scoops", "app": "scoops", "model": r["model"],
                         "bucket": ts.strftime("%Y-%m-%dT%H") if bucket == "hour" else day, "bot": r["bot_id"],
                         "input": i, "output": o, "cache_read": cr, "cache_write": cw, "reasoning": 0, "requests": 1,
                         "types": types, "priced": priced or (not abo and actual > 0), "approx": approx and abo,
                         "cost": cost, "api": 0.0 if abo else actual, "abo": est if abo else 0.0})
    return rows, start, bucket, keys, sessions


def details(db, rng: str = "30d", source: str = "all", logs: dict | None = None,
            account: dict | None = None, bot_names: dict | None = None) -> dict:
    if rng not in RANGES:
        rng = "30d"
    if source not in ("all", "scoops", "other"):
        source = "all"
    logs = logs or {}
    logs_ok = bool(logs.get("available", True))
    rows, start, bucket, keys, sessions = _rows(db, rng, source, logs_ok)

    tot = _Acc()
    by_prov: dict[str, _Acc] = defaultdict(_Acc)
    by_src: dict[str, _Acc] = defaultdict(_Acc)
    by_app: dict[tuple[str, str], _Acc] = defaultdict(_Acc)
    by_model: dict[str, _Acc] = defaultdict(_Acc)
    by_bucket: dict[str, dict[str, _Acc]] = defaultdict(lambda: defaultdict(_Acc))
    by_bot: dict[str, _Acc] = defaultdict(_Acc)
    for r in rows:
        tot.add(r)
        by_prov[r["provider"]].add(r)
        by_src[r["scope"]].add(r)
        by_app[(r["provider"], app_label(r["app"]))].add(r)
        by_model[r["model"]].add(r)
        by_bucket[r["bucket"]][r["provider"]].add(r)
        if r["bot"]:
            by_bot[r["bot"]].add(r)

    tc, tt = tot.cost, tot.tokens
    savings = 0.0
    for m, a in by_model.items():
        p, _ref, _ = price_for(m)
        if p:
            savings += a.cache_read * max(0.0, p.input - p.cache_read) / 1e6

    def acc_list(items, extra):
        out = [{**extra(k), **a.out(tc, tt)} for k, a in items]
        return sorted(out, key=lambda x: (-x["cost_usd"], -x["tokens"]))

    series = []
    for k in keys:
        provs = by_bucket.get(k) or {}
        entry = {"key": k, "label": _bucket_label(k, bucket), "cost_usd": 0.0, "tokens": 0, "api_usd": 0.0}
        for p in PROVIDERS:
            a = provs.get(p)
            entry[p] = {"cost_usd": round(a.cost, 4) if a else 0.0, "tokens": a.tokens if a else 0,
                        "api_usd": round(a.api, 4) if a else 0.0}
            entry["cost_usd"] += entry[p]["cost_usd"]
            entry["tokens"] += entry[p]["tokens"]
            entry["api_usd"] += entry[p]["api_usd"]
        entry["cost_usd"] = round(entry["cost_usd"], 4)
        entry["api_usd"] = round(entry["api_usd"], 4)
        series.append(entry)

    names = bot_names or {}
    days_rows = []
    if bucket == "day":
        for e in reversed(series):
            if e["tokens"] or e["cost_usd"]:
                days_rows.append({"id": e["key"], "label": e["label"], "cost_usd": e["cost_usd"],
                                  "api_usd": e["api_usd"], "tokens": e["tokens"],
                                  "share_cost": round(e["cost_usd"] / tc, 4) if tc else 0.0,
                                  "share_tokens": round(e["tokens"] / tt, 4) if tt else 0.0})

    totals = tot.out(tc, tt)
    totals.pop("share_cost", None)
    totals.pop("share_tokens", None)
    totals.update(sessions=sessions, cache_savings_usd=round(savings, 4),
                  cached_share=round(tot.cache_read / (tot.input + tot.cache_read + tot.cache_write), 4)
                  if (tot.input + tot.cache_read + tot.cache_write) else 0.0)
    acct = None
    if account and source != "scoops":
        days = [d for d in (account.get("days") or []) if d.get("day", "") >= start.strftime("%Y-%m-%d")]
        acct = {"openai": {"tokens": sum(int(d.get("tokens") or 0) for d in days), "days": days,
                           "at": account.get("at"), "label": "Laut OpenAI (alle Geräte)"}} if days else None
    return {
        "range": rng, "bucket": bucket, "source": source, "start": start.isoformat(timespec="seconds"),
        "end": now().isoformat(timespec="seconds"), "generated_at": now().isoformat(timespec="seconds"),
        "totals": totals,
        "by_type": {t: round(tot.types[t], 4) for t in TYPES},
        "providers": [{"id": p, "label": PROVIDER_LABEL[p], **by_prov[p].out(tc, tt)} for p in PROVIDERS],
        "sources": [{"id": s, "label": SOURCE_LABEL[s], **by_src[s].out(tc, tt)} for s in ("scoops", "other")
                    if source in ("all", s)],
        "apps": acc_list(by_app.items(), lambda k: {"id": f"{k[0]}:{k[1]}", "label": k[1], "provider": k[0]}),
        "models": acc_list(by_model.items(), lambda m: {"id": m, "label": model_label(m), "provider": provider_of(m)}),
        "days": days_rows,
        "scoops": acc_list(by_bot.items(), lambda b: {"id": b, "label": names.get(b) or "Gelöschter Scoop"}),
        "series": series,
        "account": acct,
        "logs": logs,
        "notes": [
            "Abo-Verbrauch ist zum API-Listenpreis bewertet (Schätzung). Die Abo-Gebühr selbst fällt unabhängig davon an.",
            "Kosten und Tokens umfassen nur Programme auf diesem Mac (Claude Code, Codex, T3 Code, Scoops …). "
            "Nutzung auf anderen Geräten oder in claude.ai/ChatGPT im Browser fehlt hier, steckt aber in den Limits.",
        ],
    }
