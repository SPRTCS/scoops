"""Konfiguration: API-Schlüssel aus dem macOS-Schlüsselbund, Modellpreise."""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass

from .profile import kc

KEYCHAIN_SERVICE = kc("anthropic")
KEYCHAIN_ACCOUNT = "api-key"


def anthropic_api_key() -> str:
    """Liest den API-Schlüssel. Umgebungsvariable hat Vorrang, sonst Schlüsselbund."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    out = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(
            f"Kein API-Schlüssel gefunden (Schlüsselbund-Eintrag '{KEYCHAIN_SERVICE}')."
        )
    return out.stdout.strip()


# Modelle, Rang, Preise und Wege kommen aus dem Modellkatalog (models_catalog.py, docs/modelle.md). Die Namen hier
# bleiben für bestehende Aufrufer und folgen jedem Katalogwechsel (auch einer neueren Fernkopie) sofort.
from . import models_catalog as catalog  # noqa: E402

# Modelle, die Scoops und Routinen wählen dürfen (server.py prüft Eingaben dagegen)
MODELS = catalog.LiveIds()
# Stärke innerhalb eines Anbieters (für die Verstärkung bei Routinen mit eigenem Modell); abgelöste Kennungen
# bekommen den Rang ihres Nachfolgers
MODEL_RANK = catalog.LiveMap(lambda c: {**{m.id: m.rank for m in c.models.values()},
                                        **{old: c.models[new].rank for old, new in c.replaced.items()}})


def resolve_model(model: str | None) -> str | None:
    """Abgelöste Kennung (z. B. gpt-6.1-sol) → Nachfolger; alles andere unverändert."""
    return catalog.current().resolve(model)


def provider_routes(only: str | None = None) -> dict[str, dict[str, bool]]:
    """Pro Anbieter (anthropic/openai): geht der API-Weg (Schlüssel hinterlegt, Modus nicht „nur Abo“) und der Abo-Weg
    (Modus nicht „nur API“, im Programm mit Abo angemeldet)?"""
    from . import abos
    out = {}
    for prov, name in (("anthropic", "claude"), ("openai", "openai")):
        if only and prov != only:
            continue
        try:
            mode = abos.mode(name)
            api = mode != "abo" and abos.has_api_key(name)
            abo = mode != "api" and bool(abos.login_status(name).get("subscription"))
        except Exception:  # noqa: BLE001
            api, abo = False, False
        out[prov] = {"api": bool(api), "abo": bool(abo)}
    return out


def model_routes(model: str, routes: dict | None = None) -> list[str]:
    """Wege, über die dieses Modell auf diesem Server gerade laufen kann: "api" und/oder "abo" (das Modell muss den
    Weg laut Katalog können)."""
    c = catalog.current()
    m = c.models.get(c.resolve(model) or "")
    if m is None:
        return []
    pr = (routes or provider_routes(m.provider))[m.provider]
    abo_route = "chatgpt_abo" if m.provider == "openai" else "claude_abo"
    return [r for r, ok in (("api", pr["api"] and "api" in m.routes), ("abo", pr["abo"] and abo_route in m.routes)) if ok]


def model_available(model: str) -> bool:
    """Wählbares Modell, das auf diesem Server über den API-Schlüssel oder das Abo laufen kann."""
    if model not in MODELS:
        return False
    try:
        return bool(model_routes(model))
    except Exception:  # noqa: BLE001
        return False


@dataclass(frozen=True)
class Price:
    """US-Dollar pro 1 Mio. Tokens."""

    input: float
    output: float
    cache_read: float
    cache_write: float


# Listenpreise aller Modelle im Katalog (wählbare, abgelöste – damit alte Kostenhistorie richtig bewertet bleibt – und
# Modelle, die nur in der Nutzungsansicht vorkommen: Abo-Läufe anderer Apps, docs/nutzung.md).
PRICES = catalog.LiveMap(lambda c: {m.id: Price(m.price["input"], m.price["output"], m.price["cache_read"],
                                                m.price["cache_write"]) for m in c.models.values()})
VALUATION_PRICES = PRICES
# Ohne eigenen Preis: gleiche Modellfamilie (Annahme, in der Ansicht als „Preis geschätzt“ markiert)
_FAMILY = catalog.LiveMap(lambda c: dict(c.family_refs()))


def _norm_model(model: str) -> str:
    import re
    m = (model or "").strip().lower()
    for pre in ("anthropic/", "openai/", "anthropic.", "us.anthropic.", "eu.anthropic."):
        if m.startswith(pre):
            m = m[len(pre):]
    m = re.sub(r"\[[^\]]*\]$", "", m)  # claude-opus-5-5[1m]
    m = re.sub(r"[-@]20\d{6}$", "", m)  # Datumsstempel
    m = re.sub(r"-fast$", "", m)
    return m


def price_for(model: str) -> tuple[Price | None, str | None, bool]:
    """(Preis, verwendetes Preismodell, geschätzt) für ein beliebiges Modell aus Protokollen oder der Datenbank."""
    m = _norm_model(model)
    if m in VALUATION_PRICES:
        return VALUATION_PRICES[m], m, False
    best = max((k for k in VALUATION_PRICES if m.startswith(k + "-")), key=len, default=None)
    if best:
        return VALUATION_PRICES[best], best, False
    for frag, ref in _FAMILY.items():
        if frag in m:
            return VALUATION_PRICES[ref], ref, True
    return None, None, False


@dataclass
class Usage:
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    requests: int = 0
    web_searches: int = 0
    billing: str = "api"  # "abo": Lauf über das Abo (Claude Code/Codex mit Login des Nutzers) → keine Kosten in $

    def add(self, usage) -> None:
        self.requests += 1
        self.input_tokens += usage.input_tokens or 0
        self.output_tokens += usage.output_tokens or 0
        self.cache_read_tokens += getattr(usage, "cache_read_input_tokens", 0) or 0
        self.cache_write_tokens += getattr(usage, "cache_creation_input_tokens", 0) or 0
        stu = getattr(usage, "server_tool_use", None)
        self.web_searches += (getattr(stu, "web_search_requests", 0) or 0) if stu else 0
        # Compaction (Beta compact-2026-01-12): Die Zusammenfassung ist eine eigene Iteration, die in den Summen oben
        # NICHT enthalten ist, aber berechnet wird (usage.iterations, type "compaction").
        for it in getattr(usage, "iterations", None) or []:
            kind = it.get("type") if isinstance(it, dict) else getattr(it, "type", None)
            if kind != "compaction":
                continue
            get = (lambda k: it.get(k)) if isinstance(it, dict) else (lambda k: getattr(it, k, None))
            self.input_tokens += get("input_tokens") or 0
            self.output_tokens += get("output_tokens") or 0
            self.cache_read_tokens += get("cache_read_input_tokens") or 0
            self.cache_write_tokens += get("cache_creation_input_tokens") or 0

    @property
    def dollars(self) -> float:
        if self.billing == "abo":
            return 0.0
        p = PRICES.get(self.model)
        if p is None:
            return float("nan")
        return (
            self.input_tokens * p.input
            + self.output_tokens * p.output
            + self.cache_read_tokens * p.cache_read
            + self.cache_write_tokens * p.cache_write
        ) / 1_000_000 + self.web_searches * 0.01  # Websuche: 10 $ pro 1.000

    def summary(self) -> str:
        return (
            f"{self.requests} Anfragen · Eingabe {self.input_tokens:,} · Ausgabe {self.output_tokens:,} · "
            f"Cache gelesen {self.cache_read_tokens:,} · Cache geschrieben {self.cache_write_tokens:,} · "
            f"≈ {self.dollars:.3f} $"
        ).replace(",", ".")


class UsageBook:
    """Kosten über mehrere Modelle hinweg (z. B. Haiku, dann Eskalation auf Sonnet)."""

    def __init__(self, billing: str = "api") -> None:
        self.by_model: dict[str, Usage] = {}
        self.billing = billing

    def add(self, model: str, usage) -> None:
        self.by_model.setdefault(model, Usage(model, billing=self.billing)).add(usage)

    def add_counts(self, model: str, input_tokens: int = 0, output_tokens: int = 0, cache_read: int = 0,
                   cache_write: int = 0, requests: int = 1, web_searches: int = 0) -> None:
        """Zählerstände direkt (Abo-Läufe: Claude Code/Codex melden Summen statt einzelner API-Antworten)."""
        u = self.by_model.setdefault(model, Usage(model, billing=self.billing))
        u.input_tokens += int(input_tokens or 0)
        u.output_tokens += int(output_tokens or 0)
        u.cache_read_tokens += int(cache_read or 0)
        u.cache_write_tokens += int(cache_write or 0)
        u.requests += int(requests or 0)
        u.web_searches += int(web_searches or 0)

    @property
    def dollars(self) -> float:
        return sum(u.dollars for u in self.by_model.values())

    def summary(self) -> str:
        parts = [f"{m.replace('claude-', '')}{' (Abo)' if u.billing == 'abo' else ''}: {u.summary()}"
                 for m, u in self.by_model.items()]
        return " | ".join(parts) + (f" | gesamt ≈ {self.dollars:.3f} $" if len(parts) > 1 else "")

    def as_dict(self) -> dict:
        return {m: u.__dict__ | {"dollars": round(u.dollars, 4)} for m, u in self.by_model.items()}
