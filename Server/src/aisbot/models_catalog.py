"""Modellkatalog (docs/modelle.md): welche Modelle Scoops nutzen dürfen, mit Anzeigenamen, Hinweis, Rang, Preisen
und Wegen (API-Schlüssel, Claude-Abo, ChatGPT-Abo).

Quellen, die neueste `version` gewinnt:
1. gebündelt: `models_catalog.json` neben dieser Datei (kommt mit jedem Server-Release),
2. Zwischenspeicher: `<data>/models_catalog.json` (zuletzt erfolgreich geladene Fernkopie),
3. Fernkopie: `models.json` im öffentlichen Release-Repo (MODELS_URL), beim Start und dann alle 24 Stunden.
Eine Fernkopie wird streng geprüft (`validate`) und nur übernommen, wenn ihre `version` größer ist. Bei jedem Fehler
gilt weiter, was schon geladen ist. Neue Modelle brauchen so weder einen App-Build noch ein Server-Release.

Alle bisherigen Listen (config.MODELS/MODEL_RANK/PRICES, engine_openai.OPENAI_MODELS/ESCALATE, Standardmodelle)
leiten sich aus `current()` ab und folgen einem Wechsel des Katalogs sofort.
"""

from __future__ import annotations

import json
import os
import random
import re
import threading
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

from . import i18n

BUNDLED = Path(__file__).with_name("models_catalog.json")
MODELS_URL = "https://raw.githubusercontent.com/SPRTCS/ais-scoops-server/main/models.json"
REFRESH_EVERY = 24 * 3600
MAX_BYTES = 256 * 1024
SCHEMA = 1
PROVIDERS = ("anthropic", "openai")
ROUTES = {"api": None, "claude_abo": "anthropic", "chatgpt_abo": "openai"}  # Weg → nur für diesen Anbieter
_ID = re.compile(r"^(claude|gpt)-[a-z0-9][a-z0-9.\-]{0,60}$")


class CatalogError(ValueError):
    pass


@dataclass(frozen=True)
class Model:
    id: str
    label: str
    provider: str
    hint: str
    rank: int
    price: dict
    routes: tuple[str, ...]
    features: frozenset[str]
    replaces: tuple[str, ...]
    deprecated: bool
    pricing_only: bool
    # Hinweis in weiteren Sprachen aus dem Katalog (`hint_en` …, docs/sprache.md); sonst übersetzt die Tabelle
    hints: dict = field(default_factory=dict, compare=False)

    @property
    def selectable(self) -> bool:
        return not self.deprecated and not self.pricing_only

    def hint_for(self, lang: str | None = None) -> str:
        """Hinweis in der Sprache `lang` (Standard: aktuelle): `hint_<lang>` aus dem Katalog, sonst Tabelle, sonst
        der deutsche `hint`."""
        lang = lang or i18n.current()
        if lang == i18n.DEFAULT or not self.hint:
            return self.hint
        return self.hints.get(lang) or i18n.translate(self.hint, lang)


@dataclass
class Catalog:
    version: int
    updated: str
    source: str  # "bundled" | "cache" | "remote"
    models: dict[str, Model]
    defaults: dict[str, dict[str, str]]
    raw: dict = field(repr=False, default_factory=dict)

    # -- Ableitungen ------------------------------------------------------------------------------------------------
    def selectable(self, provider: str | None = None) -> list[Model]:
        """Wählbare Modelle, nach Anbieter (Claude zuerst) und Rang."""
        ms = [m for m in self.models.values() if m.selectable and (provider is None or m.provider == provider)]
        return sorted(ms, key=lambda m: (PROVIDERS.index(m.provider), m.rank))

    @property
    def ids(self) -> tuple[str, ...]:
        return tuple(m.id for m in self.selectable())

    @property
    def replaced(self) -> dict[str, str]:
        """Alte Kennung → neue Kennung (aus `replaces`)."""
        return {old: m.id for m in self.models.values() for old in m.replaces}

    def resolve(self, model: str | None) -> str | None:
        """Kennung, unter der ein Modell heute läuft (alte Kennungen → Nachfolger). Unbekanntes bleibt, wie es ist."""
        if not model:
            return model
        rep, seen = self.replaced, set()
        while model in rep and model not in seen:
            seen.add(model)
            model = rep[model]
        return model

    def provider_of(self, model: str) -> str:
        m = self.models.get(model)
        if m:
            return m.provider
        return "openai" if (model or "").startswith("gpt-") else "anthropic"

    def rank(self, model: str) -> int:
        m = self.models.get(self.resolve(model) or "")
        return m.rank if m else -1

    def next_stronger(self, model: str) -> str | None:
        """Nächststärkeres wählbares Modell desselben Anbieters (OpenAI-Verstärkung Schritt für Schritt)."""
        model = self.resolve(model) or ""
        prov, r = self.provider_of(model), self.rank(model)
        if r < 0:
            return None
        up = [m for m in self.selectable(prov) if m.rank > r]
        return up[0].id if up else None

    def has(self, model: str, feature: str) -> bool:
        m = self.models.get(self.resolve(model) or "")
        return bool(m and feature in m.features)

    def label(self, model: str) -> str | None:
        m = self.models.get(model) or self.models.get(self.resolve(model) or "")
        return m.label if m else None

    def default(self, provider: str, kind: str = "model") -> str:
        return self.defaults[provider][kind]

    def family_refs(self) -> list[tuple[str, str]]:
        """(Bruchstück, Preismodell) für Modelle ohne eigenen Preis: erstes nicht abgelöstes Modell der Familie in
        Dateireihenfolge (z. B. „-sol“ → gpt-6.2-sol, „claude-opus“ → claude-opus-5-5)."""
        out: dict[str, str] = {}
        for m in self.models.values():
            if m.deprecated:
                continue
            if m.provider == "openai":
                tail = m.id.rsplit("-", 1)[-1]
                frag = f"-{tail}" if tail.isalpha() and "-" in m.id[4:] else None
            else:
                parts = m.id.split("-")
                frag = f"claude-{parts[1]}" if len(parts) > 1 and parts[1].isalpha() else None
            if frag and frag not in out:
                out[frag] = m.id
        return list(out.items())

    def as_json(self) -> dict:
        return {"version": self.version, "updated": self.updated, "source": self.source,
                "defaults": self.defaults,
                "models": [{"id": m.id, "label": m.label, "provider": m.provider, "hint": m.hint_for(), "rank": m.rank,
                            "price": m.price, "routes": list(m.routes), "features": sorted(m.features),
                            "replaces": list(m.replaces), "deprecated": m.deprecated, "selectable": m.selectable}
                           for m in sorted(self.models.values(),
                                           key=lambda m: (PROVIDERS.index(m.provider), not m.selectable, m.rank))
                           if not m.pricing_only]}


# -- Prüfung ------------------------------------------------------------------------------------------------------------
def _num(v, name: str, lo: float, hi: float) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not (lo <= float(v) <= hi):
        raise CatalogError(f"{name}: Zahl zwischen {lo} und {hi} erwartet, nicht {v!r}")
    return float(v)


def _text(v, name: str, lo: int, hi: int) -> str:
    if not isinstance(v, str) or not (lo <= len(v.strip()) <= hi) or any(ord(c) < 32 for c in v):
        raise CatalogError(f"{name}: Text mit {lo}–{hi} Zeichen erwartet")
    return v.strip()


def validate(data, source: str = "remote", require: Catalog | None = None) -> Catalog:
    """Katalog streng prüfen. `require`: Jede Kennung dieses Katalogs muss im neuen vorkommen (auch als abgelöst oder
    über `replaces`), damit eine Fernkopie nie still ein genutztes Modell verschwinden lässt."""
    if not isinstance(data, dict):
        raise CatalogError("Katalog muss ein JSON-Objekt sein")
    if data.get("schema") != SCHEMA:
        raise CatalogError(f"schema {data.get('schema')!r} wird nicht unterstützt (erwartet {SCHEMA})")
    version = data.get("version")
    if isinstance(version, bool) or not isinstance(version, int) or version <= 0:
        raise CatalogError("version: positive ganze Zahl erwartet (z. B. 2026111801)")
    raw_models = data.get("models")
    if not isinstance(raw_models, list) or not 1 <= len(raw_models) <= 200:
        raise CatalogError("models: Liste mit 1–200 Einträgen erwartet")
    models: dict[str, Model] = {}
    for i, r in enumerate(raw_models):
        where = f"models[{i}]"
        if not isinstance(r, dict):
            raise CatalogError(f"{where}: Objekt erwartet")
        mid = r.get("id")
        if not isinstance(mid, str) or not _ID.match(mid):
            raise CatalogError(f"{where}.id: nur Kennungen wie claude-… oder gpt-… erlaubt, nicht {mid!r}")
        where = f"Modell {mid}"
        if mid in models:
            raise CatalogError(f"{where}: doppelt")
        provider = r.get("provider")
        if provider not in PROVIDERS:
            raise CatalogError(f"{where}.provider: anthropic oder openai")
        if (provider == "openai") != mid.startswith("gpt-"):
            raise CatalogError(f"{where}: Anbieter passt nicht zur Kennung")
        p = r.get("price")
        if not isinstance(p, dict):
            raise CatalogError(f"{where}.price fehlt")
        inp = _num(p.get("input"), f"{where}.price.input", 0.001, 500)
        out = _num(p.get("output"), f"{where}.price.output", inp, 2000)
        cr = _num(p.get("cache_read", inp * 0.1), f"{where}.price.cache_read", 0, inp)
        cw = _num(p.get("cache_write", inp * 1.25), f"{where}.price.cache_write", 0, inp * 4)
        routes = r.get("routes", ["api"])
        if not isinstance(routes, list) or not routes or any(x not in ROUTES for x in routes):
            raise CatalogError(f"{where}.routes: Liste aus {', '.join(ROUTES)}")
        for x in routes:
            if ROUTES[x] not in (None, provider):
                raise CatalogError(f"{where}.routes: {x} passt nicht zu {provider}")
        features = r.get("features", [])
        if not isinstance(features, list) or any(not isinstance(f, str) or len(f) > 40 for f in features):
            raise CatalogError(f"{where}.features: Liste kurzer Texte")
        replaces = r.get("replaces", [])
        if not isinstance(replaces, list) or any(not isinstance(x, str) or not _ID.match(x) or x == mid
                                                 for x in replaces):
            raise CatalogError(f"{where}.replaces: Liste anderer Kennungen")
        for flag in ("deprecated", "pricing_only"):
            if not isinstance(r.get(flag, False), bool):
                raise CatalogError(f"{where}.{flag}: true oder false")
        rank = r.get("rank", 0)
        if isinstance(rank, bool) or not isinstance(rank, int) or not 0 <= rank <= 1000:
            raise CatalogError(f"{where}.rank: ganze Zahl 0–1000")
        hints = {lang: _text(r[f"hint_{lang}"], f"{where}.hint_{lang}", 0, 80)
                 for lang in i18n.LANGS if lang != i18n.DEFAULT and r.get(f"hint_{lang}") is not None}
        models[mid] = Model(
            id=mid, label=_text(r.get("label"), f"{where}.label", 1, 40),
            hint=_text(r.get("hint", ""), f"{where}.hint", 0, 80), provider=provider, rank=rank,
            hints={k: v for k, v in hints.items() if v},
            price={"input": inp, "output": out, "cache_read": cr, "cache_write": cw}, routes=tuple(routes),
            features=frozenset(features), replaces=tuple(replaces), deprecated=bool(r.get("deprecated", False)),
            pricing_only=bool(r.get("pricing_only", False)))
    for m in models.values():
        for old in m.replaces:
            if old in models and models[old].selectable:
                raise CatalogError(f"Modell {m.id} löst {old} ab, {old} ist aber noch wählbar (deprecated: true setzen)")
        if m.replaces and not m.selectable:
            raise CatalogError(f"Modell {m.id}: nur wählbare Modelle dürfen andere ablösen")
    olds = [o for m in models.values() for o in m.replaces]
    if len(olds) != len(set(olds)):
        raise CatalogError("replaces: eine alte Kennung wird von zwei Modellen abgelöst")
    defaults = data.get("defaults")
    if not isinstance(defaults, dict):
        raise CatalogError("defaults fehlt")
    clean_defaults: dict[str, dict[str, str]] = {}
    for prov in PROVIDERS:
        d = defaults.get(prov)
        if not isinstance(d, dict):
            raise CatalogError(f"defaults.{prov} fehlt")
        clean_defaults[prov] = {}
        for kind in ("model", "escalation"):
            mid = d.get(kind)
            if mid not in models or not models[mid].selectable or models[mid].provider != prov:
                raise CatalogError(f"defaults.{prov}.{kind}: wählbares {prov}-Modell erwartet, nicht {mid!r}")
            clean_defaults[prov][kind] = mid
    cat = Catalog(version=version, updated=str(data.get("updated") or "")[:40], source=source, models=models,
                  defaults=clean_defaults, raw=data)
    if require is not None:
        missing = [mid for mid in require.models if mid not in models and mid not in cat.replaced]
        if missing:
            raise CatalogError(f"Es fehlen bekannte Modelle: {', '.join(sorted(missing))} (als deprecated behalten "
                               "oder per replaces ablösen)")
    return cat


def i18n_texts() -> list[str]:
    """Deutsche Hinweise des gebündelten Katalogs, die zur Laufzeit übersetzt werden (tests/test_i18n.py)."""
    return sorted({m.hint for m in bundled().models.values() if m.hint})


# -- Laden, Zwischenspeicher, Fernkopie --------------------------------------------------------------------------------
_lock = threading.RLock()
_current: Catalog | None = None
_bundled: Catalog | None = None
_listeners: list[Callable[[Catalog, Catalog], None]] = []
_status: dict = {"last_check": None, "last_error": None}


def _cache_path() -> Path:
    from .profile import DATA_DIR
    return DATA_DIR / "models_catalog.json"


def bundled() -> Catalog:
    global _bundled
    if _bundled is None:
        _bundled = validate(json.loads(BUNDLED.read_text(encoding="utf-8")), "bundled")
    return _bundled


def _load() -> Catalog:
    cat = bundled()
    try:
        p = _cache_path()
        if p.exists():
            cached = validate(json.loads(p.read_text(encoding="utf-8")), "cache", require=cat)
            if cached.version > cat.version:
                cat = cached
    except Exception as e:  # noqa: BLE001 – kaputter Zwischenspeicher: gebündelter Katalog gilt
        print("Modellkatalog: Zwischenspeicher ignoriert:", str(e)[:200], flush=True)
    return cat


def current() -> Catalog:
    global _current
    if _current is None:
        with _lock:
            if _current is None:
                _current = _load()
    return _current


def on_change(fn: Callable[[Catalog, Catalog], None]) -> None:
    """`fn(alt, neu)` nach jedem Wechsel des Katalogs (z. B. alte Kennungen in der Datenbank umstellen)."""
    _listeners.append(fn)


def install(cat: Catalog) -> bool:
    """Katalog übernehmen, wenn er neuer ist. True = gewechselt."""
    global _current
    with _lock:
        old = current()
        if cat.version <= old.version:
            return False
        _current = cat
    print(f"Modellkatalog: Version {cat.version} ({cat.source}) aktiv, vorher {old.version}", flush=True)
    for fn in list(_listeners):
        try:
            fn(old, cat)
        except Exception as e:  # noqa: BLE001
            print("Modellkatalog: Nacharbeit fehlgeschlagen:", str(e)[:200], flush=True)
    return True


def remote_url() -> str | None:
    """Adresse der Fernkopie; leer = aus. Umgebung AISBOT_MODELS_URL > config.json `models_url` > Standard.
    Testinstanzen (AISBOT_OFFLINE=1) laden nur mit ausdrücklicher Adresse."""
    env = os.environ.get("AISBOT_MODELS_URL")
    if env is not None:
        return env.strip() or None
    try:
        from .profile import _read_config
        cfg = _read_config()
    except Exception:  # noqa: BLE001
        cfg = {}
    if "models_url" in cfg:
        return str(cfg.get("models_url") or "").strip() or None
    if os.environ.get("AISBOT_OFFLINE") == "1":
        return None
    return MODELS_URL


def parse_remote(body: bytes) -> Catalog:
    if len(body) > MAX_BYTES:
        raise CatalogError("Fernkatalog zu groß")
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise CatalogError(f"kein gültiges JSON: {e}") from None
    return validate(data, "remote", require=current())


def refresh(fetch: Callable[[str], bytes] | None = None) -> bool:
    """Fernkopie laden, prüfen, zwischenspeichern und übernehmen, wenn neuer. Wirft nie; True = gewechselt."""
    url = remote_url()
    _status["last_check"] = time.time()
    if not url:
        return False
    try:
        body = (fetch or _http_get)(url)
        cat = parse_remote(body)
        _status["last_error"] = None
        if cat.version <= current().version:
            return False
        p = _cache_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(cat.raw, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, p)
        return install(cat)
    except Exception as e:  # noqa: BLE001 – Netzfehler, Prüffehler: der geladene Katalog gilt weiter
        _status["last_error"] = str(e)[:300]
        print("Modellkatalog: Fernkopie nicht übernommen:", _status["last_error"], flush=True)
        return False


def _http_get(url: str) -> bytes:
    import httpx
    with httpx.Client(timeout=15, follow_redirects=True, headers={"User-Agent": "ais-scoops-server"}) as c:
        r = c.get(url)
        r.raise_for_status()
        if int(r.headers.get("content-length") or 0) > MAX_BYTES:
            raise CatalogError("Fernkatalog zu groß")
        return r.content


_started = False


def start_updates() -> None:
    """Hintergrund: gleich beim Start, danach etwa alle 24 Stunden (mit etwas Streuung)."""
    global _started
    if _started or not remote_url():
        return
    _started = True

    def loop() -> None:
        time.sleep(5)
        while True:
            refresh()
            time.sleep(REFRESH_EVERY + random.uniform(0, 1800))

    threading.Thread(target=loop, daemon=True, name="models-catalog").start()


def status() -> dict:
    c = current()
    return {"version": c.version, "source": c.source, "url": remote_url(), **_status}


# -- Datenbank: alte Kennungen umstellen --------------------------------------------------------------------------------
def remap_db(db, cfg_load=None, cfg_save=None) -> int:
    """Scoops, Routinen, offene Aufgaben und Standardmodelle von abgelösten Kennungen auf die Nachfolger umstellen.
    Die Kostenhistorie (`usage`) behält ihre Kennungen; sie bleibt über die Preise der alten Modelle bewertet."""
    rep = current().replaced
    if not rep:
        return 0
    n = 0
    open_states = "('open','scheduled','queued','running','waiting')"
    for old in rep:
        new = current().resolve(old)
        for sql in ("UPDATE bots SET model=? WHERE model=?",
                    "UPDATE bots SET escalation_model=? WHERE escalation_model=?",
                    "UPDATE routines SET model=? WHERE model=?",
                    "UPDATE tasks SET model_choice=? WHERE model_choice=?",
                    f"UPDATE tasks SET model=? WHERE model=? AND state IN {open_states}"):
            try:
                with db.lock:
                    n += db.conn.execute(sql, (new, old)).rowcount or 0
                    db.conn.commit()
            except Exception as e:  # noqa: BLE001 – Tabelle/Spalte fehlt in alten Datenbanken
                if "no such" not in str(e):
                    print("Modellkatalog: Umstellung", sql, "fehlgeschlagen:", str(e)[:200], flush=True)
    if cfg_load and cfg_save:
        cfg = cfg_load()
        changed = False
        for k in ("default_model", "default_escalation_model"):
            if cfg.get(k) in rep:
                cfg[k] = current().resolve(cfg[k])
                changed = True
        if changed:
            cfg_save(cfg)
    if n:
        print(f"Modellkatalog: {n} Einträge auf neue Modellkennungen umgestellt", flush=True)
    return n


# -- Live-Sichten für bestehende Aufrufer (folgen jedem Katalogwechsel) ------------------------------------------------
class LiveIds(Sequence):
    """Wählbare Kennungen; `x in MODELS`, `for m in MODELS`, `", ".join(MODELS)` wie bei einem Tupel."""

    def __init__(self, provider: str | None = None) -> None:
        self._provider = provider

    def _ids(self) -> tuple[str, ...]:
        return tuple(m.id for m in current().selectable(self._provider))

    def __getitem__(self, i):
        return self._ids()[i]

    def __len__(self) -> int:
        return len(self._ids())

    def __iter__(self) -> Iterator[str]:
        return iter(self._ids())

    def __contains__(self, x) -> bool:
        return x in self._ids()

    def __repr__(self) -> str:
        return repr(self._ids())


class LiveMap(Mapping):
    def __init__(self, build: Callable[[Catalog], dict]) -> None:
        self._build = build
        self._cache: tuple[Catalog, dict] | None = None

    def _d(self) -> dict:
        c = current()
        if self._cache is None or self._cache[0] is not c:
            self._cache = (c, self._build(c))
        return self._cache[1]

    def __getitem__(self, k):
        return self._d()[k]

    def __iter__(self):
        return iter(self._d())

    def __len__(self) -> int:
        return len(self._d())

    def __repr__(self) -> str:
        return repr(self._d())
