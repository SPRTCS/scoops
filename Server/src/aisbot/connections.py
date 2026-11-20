"""„Apps verbinden“: Konten bei Composio (Gmail, Kalender, Notion …) anzeigen, verbinden, umbenennen, trennen.

Composio verwaltet die OAuth-Anmeldung; der Server holt nur Links und Kontolisten über die REST-API.
Pro App sind bis zu 10 Konten möglich (Grenze der Composio-Sitzung, `multi_account.max_accounts_per_toolkit`).
Die Scoops wählen das Konto bei COMPOSIO_MULTI_EXECUTE_TOOL über `account` = Alias.

Ab Server 1.16 gibt es den ganzen Composio-Katalog (`/api/v3/toolkits`, ca. 1700 Apps) mit Kategorien und Suche,
24 h auf der Platte zwischengespeichert. Apps mit API-Schlüssel o. Ä. verbinden über ein Formular in der App
(`connect`): Die Werte gehen nur an Composio und werden weder gespeichert noch protokolliert.
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import httpx

from .i18n import N_, translate, tx
from .profile import DATA_DIR, kc

API = "https://backend.composio.dev/api"
MAX_PER_APP = 10

# Vorgeschlagene Apps (Reihenfolge in der App). Weitere verbundene Apps erscheinen zusätzlich.
CATALOG = [
    ("gmail", "Gmail", N_("Mails lesen, Entwürfe schreiben, senden")),
    ("googlecalendar", N_("Google Kalender"), N_("Termine lesen und anlegen")),
    ("outlook", "Outlook", N_("Microsoft-Mail und -Kalender")),
    ("notion", "Notion", N_("Seiten und Datenbanken, z. B. Tasks")),
    ("googledrive", "Google Drive", N_("Dateien finden und ablegen")),
    ("googlesheets", "Google Sheets", N_("Tabellen lesen und füllen")),
    ("googledocs", "Google Docs", N_("Dokumente lesen und schreiben")),
    ("slack", "Slack", N_("Nachrichten lesen und schreiben")),
    ("github", "GitHub", N_("Repos, Issues, Pull Requests")),
    ("linkedin", "LinkedIn", N_("Profil und Beiträge")),
]


class _Translated(dict):
    """Dict mit deutschen (N_-markierten) Texten, das beim Lesen in die aktuelle Sprache übersetzt (docs/sprache.md)."""

    def __getitem__(self, k):
        return translate(super().__getitem__(k))

    def get(self, k, default=None):
        return translate(super().get(k, default))


NAMES = _Translated({slug: name for slug, name, _ in CATALOG})
DETAILS = _Translated({slug: detail for slug, _, detail in CATALOG})
POPULAR_ORDER = {slug: i for i, (slug, _, _) in enumerate(CATALOG)}
SF_SYMBOLS = {"gmail": "envelope.fill", "outlook": "envelope.badge.fill", "googlecalendar": "calendar",
              "notion": "doc.text.fill", "googledrive": "externaldrive.fill", "googlesheets": "tablecells.fill",
              "googledocs": "doc.richtext.fill", "slack": "number", "github": "chevron.left.forwardslash.chevron.right",
              "linkedin": "person.crop.square.fill"}

# -- Katalog (ab 1.16) ---------------------------------------------------------------
CATALOG_TTL = 24 * 3600
CATALOG_FILE = "composio_catalog.json"
LOGO_DIR = "connection_logos"  # PNG-Logos (Composio liefert SVG, das die App nicht direkt zeigen kann)
LOGO_TTL = 30 * 24 * 3600
LOGO_MAX_BYTES = 1_000_000
OAUTH_SCHEMES = {"OAUTH2", "OAUTH1", "DCR_OAUTH"}
# Anmeldearten, für die die App ein Formular zeigt (Reihenfolge = Vorzug, falls eine App mehrere kann)
FIELD_SCHEMES = ("API_KEY", "BEARER_TOKEN", "BASIC", "BASIC_WITH_JWT")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_\-]{0,79}$")

# Eigene Kategorien mit deutschem Namen; jede fasst mehrere Composio-Kategorien (Kleinschreibung) zusammen.
# Composio-Kategorien, die hier fehlen, erscheinen mit ihrem Originalnamen.
GROUPS: list[tuple[str, str, set[str]]] = [
    ("productivity", N_("Produktivität"), {"productivity", "project management", "task management", "documents",
                                       "spreadsheets", "notes", "time tracking software", "file management & storage",
                                       "signatures", "forms & surveys", "content & files", "product management",
                                       "bookmark managers", "documents & ocr", "scheduling & booking", "calendar",
                                       "event management"}),
    ("communication", N_("Kommunikation"), {"email", "team chat", "communication", "phone & sms", "team collaboration",
                                        "notifications", "video conferencing", "transactional email",
                                        "ai meeting assistants"}),
    ("design", "Design", {"images & design", "video & audio", "media generation", "website builders",
                          "website & app building", "app builder"}),
    ("development", N_("Entwicklung"), {"developer tools", "model context protocol", "server monitoring", "it operations",
                                    "security & identity tools", "internet of things"}),
    ("data", N_("Daten"), {"analytics", "business intelligence", "databases", "ai web scraping", "web scraping & browser",
                       "web search & research", "dashboards", "market data", "company data", "people & contact data",
                       "places & weather"}),
    ("finance", N_("Finanzen"), {"accounting", "payment processing", "proposal & invoice management", "taxes",
                             "fundraising"}),
    ("marketing", "Marketing", {"marketing automation", "marketing", "social media marketing", "ads & conversion",
                                "email newsletters", "social media accounts", "drip emails", "url shortener",
                                "customer appreciation"}),
    ("sales", N_("Vertrieb & CRM"), {"crm", "sales & crm", "contact management", "ai sales tools", "customer support"}),
    ("ai", N_("KI"), {"artificial intelligence", "ai agents", "ai content generation", "ai models", "ai chatbots",
                  "ai document extraction", "transcription", "audio & speech", "ai assistants",
                  "ai safety compliance detection"}),
    ("commerce", N_("Handel"), {"ecommerce", "commerce", "reviews"}),
    ("hr", N_("Personal"), {"human resources", "hr talent & recruitment"}),
    ("education", N_("Bildung"), {"education", "online courses"}),
    ("lifestyle", N_("Freizeit"), {"lifestyle & entertainment", "news & lifestyle", "gaming"}),
]
GROUP_OF = {name: gid for gid, _, names in GROUPS for name in names}
GROUP_NAMES = _Translated({gid: label for gid, label, _ in GROUPS})
MIN_OTHER_CATEGORY = 8  # unbekannte Kategorien erst ab so vielen Apps als Chip

def unavailable(name: str) -> str:
    """Hinweis, wenn Composio für eine App keine fertige Anmeldung hat (in der Sprache der Anfrage)."""
    return tx("Für {name} bietet Composio keine fertige Anmeldung an. Dafür müsste zuerst im Composio-Konto "
              "eine eigene Anmeldung (Auth-Config) für diese App hinterlegt werden.", name=name)


def _field(f: dict, required: bool) -> dict:
    """Composio-Feld → Formularfeld. Geheim: laut Composio (`is_secret`), sonst nach Typ/Name (Schlüssel, Token …)."""
    name = str(f.get("name") or "")
    typ = str(f.get("type") or "string").lower()
    if "is_secret" in f:
        secret = bool(f.get("is_secret")) or typ == "password"
    else:
        secret = typ == "password" or any(k in name.lower() for k in ("key", "token", "secret", "password"))
    default = f.get("default")
    return {"name": name, "label": str(f.get("displayName") or name), "description": " ".join(str(f.get("description") or "").split())[:400],
            "secret": secret, "required": required, "default": None if secret or default in (None, "") else str(default)}


class ComposioError(RuntimeError):
    """Fehler der Composio-API mit Status und Fehler-Slug (z. B. ToolRouterV2_NoManagedAuth)."""

    def __init__(self, msg: str, status: int = 0, slug: str = "", code: int | None = None) -> None:
        super().__init__(msg)
        self.status, self.slug, self.code = status, slug, code


class Unsupported(ValueError):
    """App lässt sich hier nicht verbinden (keine verwaltete Anmeldung, falsche Art) → 422."""


class NotFound(LookupError):
    """Unbekannte App → 404."""


def _category_id(name: str) -> str:
    n = (name or "").strip().lower()
    return GROUP_OF.get(n) or re.sub(r"[^a-z0-9]+", "-", n).strip("-") or "other"


def _short(text: str, limit: int = 120) -> str:
    """Erster Satz der (englischen) Composio-Beschreibung, gekürzt für eine Zeile."""
    t = " ".join((text or "").split())
    m = re.match(r"(.+?[.!?])(\s|$)", t)
    t = m.group(1) if m and len(m.group(1)) >= 20 else t
    return t if len(t) <= limit else t[: limit - 1].rstrip(" ,;:-") + "…"


def _toolkit_item(tk: dict, rank: int) -> dict:
    """Composio-Toolkit → kompakter Katalogeintrag (so auch auf der Platte)."""
    slug = tk["slug"]
    meta = tk.get("meta") or {}
    cats: list[str] = []
    raw: list[str] = []
    for c in meta.get("categories") or []:
        name = (c.get("name") or c.get("id") or "").strip()
        if not name or name.lower() == "popular":
            continue
        cid = _category_id(name)
        if cid not in cats:
            cats.append(cid)
            raw.append(name)
    return {"slug": slug, "name": tk.get("name") or slug, "description": _short(meta.get("description") or ""),
            "logo_url": meta.get("logo") or f"https://logos.composio.dev/api/{slug}",
            "categories": cats, "category_names": raw,
            "schemes": [str(x).upper() for x in tk.get("auth_schemes") or []],
            "managed": [str(x).upper() for x in tk.get("composio_managed_auth_schemes") or []],
            "no_auth": bool(tk.get("no_auth")), "tools": int(meta.get("tools_count") or 0), "rank": rank}


def _fallback_items() -> list[dict]:
    """Ohne Composio-Katalog (kein Schlüssel, offline): die zehn bekannten Apps."""
    return [{"slug": slug, "name": name, "description": "", "logo_url": f"https://logos.composio.dev/api/{slug}",
             "categories": [], "category_names": [], "schemes": ["OAUTH2"], "managed": ["OAUTH2"], "no_auth": False,
             "tools": 0, "rank": i} for i, (slug, name, _) in enumerate(CATALOG)]


def _search_score(item: dict, q: str) -> int:
    """0 = kein Treffer; höher = besser (Namensanfang > Wortanfang > Teilstring > Slug > Beschreibung)."""
    name = item["name"].lower()
    if name == q or item["slug"] == q:
        return 100
    if name.startswith(q):
        return 80
    if any(w.startswith(q) for w in re.split(r"[\s\-_.]+", name)):
        return 60
    if q in name:
        return 50
    if q.replace(" ", "") in item["slug"]:
        return 40
    if q in (item.get("description") or "").lower():
        return 20
    if any(q in c.lower() for c in item.get("category_names") or []):
        return 10
    return 0


def _key() -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", kc("composio"), "-a", "api-key", "-w"],
                       capture_output=True, text=True)
    return r.stdout.strip() or None if r.returncode == 0 else None


def _age_s(iso: str | None) -> float:
    if not iso:
        return 0
    try:
        return (datetime.now(timezone.utc) - datetime.fromisoformat(iso.replace("Z", "+00:00"))).total_seconds()
    except ValueError:
        return 0


class Connections:
    def __init__(self, load_config):
        self.load_config = load_config
        self.http = httpx.Client(timeout=20)
        self._cache: tuple[float, list[dict]] = (0.0, [])
        self._lock = threading.Lock()
        # Katalog (ab 1.16): Einträge, Zeitpunkt, Quelle („composio“ | „fallback“)
        self._catalog: tuple[float, list[dict], str] = (0.0, [], "")
        self._catalog_lock = threading.Lock()
        self._catalog_refreshing = False
        self._configs: tuple[float, dict[str, dict[str, str]]] = (0.0, {})  # slug → {scheme: auth_config_id}
        self._details: dict[str, tuple[float, dict]] = {}
        self._by_slug: dict[str, dict] = {}
        self._session_auth: dict[str, str] | None = None
        # Toolkit → eigene (nicht Composio-verwaltete) Auth-Config bzw. Toolkits mit verwalteter Config (aus _auth_configs)
        self._custom_cfgs: dict[str, str] = {}
        self._managed_cfgs: set[str] = set()  # zuletzt an die Sitzung gemeldete eigene Auth-Configs
        self.data_dir = DATA_DIR
        # Ab 1.25: Konten außerhalb von Composio (Notion direkt, notion_mcp.py) für „Apps verbinden“ und
        # ein Zusatz für die Systemanweisung. Setzt server.py.
        self.extra_accounts = lambda: []
        self.extra_prompt = lambda: None

    # -- Composio ---------------------------------------------------------------------
    def ensure_session(self) -> str:
        """Neue Installation: legt eine Composio-Tool-Router-Sitzung an und speichert sie in config.json
        (`composio_session_id`, `composio_user_id`). Vorhandene Sitzungen bleiben unverändert."""
        from .bots import save_config
        cfg = self.load_config()
        if cfg.get("composio_session_id"):
            return cfg["composio_session_id"]
        key = _key()
        if not key:
            raise RuntimeError(tx("Kein Composio-Schlüssel hinterlegt"))
        import secrets
        user_id = cfg.get("composio_user_id") or f"scoops-{secrets.token_hex(6)}"
        bodies = [{"user_id": user_id, "multi_account": {"enable": True, "max_accounts_per_toolkit": MAX_PER_APP}},
                  {"user_id": user_id}]
        last = ""
        for body in bodies:
            r = self.http.post(API + "/v3.1/tool_router/session", headers={"x-api-key": key}, json=body)
            if r.status_code < 400:
                d = r.json()
                sid = d.get("session_id") or d.get("id")
                if not sid:
                    url = ((d.get("mcp") or {}).get("url") or "")
                    parts = [p for p in url.split("/") if p]
                    sid = parts[parts.index("mcp") - 1] if "mcp" in parts else None
                if not sid:
                    raise RuntimeError(tx("Composio: Antwort ohne Sitzungs-ID"))
                cfg = self.load_config()
                cfg.update(composio_session_id=sid, composio_user_id=user_id)
                save_config(cfg)
                return sid
            last = f"{r.status_code} {r.text[:200]}"
            if r.status_code in (401, 403):
                break
        raise RuntimeError(tx("Composio-Sitzung nicht anlegbar ({last})", last=last))

    def _cfg(self) -> tuple[str, str, str]:
        key = _key()
        cfg = self.load_config()
        sid = cfg.get("composio_session_id")
        if not key or not sid:
            raise RuntimeError(tx("Composio ist nicht eingerichtet"))
        return key, sid, cfg.get("composio_user_id", "arman")

    def _req(self, method: str, path: str, *, scrub: tuple[str, ...] = (), **kw) -> dict:
        """REST-Aufruf mit dem Projekt-Schlüssel. `scrub`: Werte (z. B. API-Schlüssel des Nutzers), die nie in
        einer Fehlermeldung landen dürfen."""
        key, _, _ = self._cfg()
        return self._call(key, method, path, scrub=scrub, **kw)

    def _call(self, key: str, method: str, path: str, *, scrub: tuple[str, ...] = (), **kw) -> dict:
        r = self.http.request(method, API + path, headers={"x-api-key": key}, **kw)
        if r.status_code >= 400:
            slug, code = "", None
            try:
                body = r.json()
                err = body.get("error") if isinstance(body.get("error"), dict) else {}
                msg = err.get("message") or body.get("message") or r.text
                slug, code = str(err.get("slug") or ""), err.get("code")
            except ValueError:
                msg = r.text
            msg = str(msg)
            for v in scrub:
                if v and len(v) >= 3:
                    msg = msg.replace(v, "•••")
            raise ComposioError(f"Composio: {msg[:200]}", r.status_code, slug, code)
        return r.json() if r.content else {}

    def accounts(self, fresh: bool = False) -> list[dict]:
        """Verbundene Konten (60 s zwischengespeichert), bereinigt um liegengebliebene Anmeldungen."""
        with self._lock:
            if not fresh and time.time() - self._cache[0] < 60:
                return self._cache[1]
            _, _, uid = self._cfg()
            items = self._req("GET", "/v3/connected_accounts", params={"user_ids": uid, "limit": 200}).get("items", [])
            keep: list[dict] = []
            active = {(a["toolkit"]["slug"], a.get("alias")) for a in items if a.get("status") == "ACTIVE"}
            for a in items:
                st, slug = a.get("status"), a["toolkit"]["slug"]
                stale_init = st in ("INITIALIZING", "INITIATED") and _age_s(a.get("created_at")) > 3600
                replaced = st in ("EXPIRED", "FAILED") and (slug, a.get("alias")) in active
                if stale_init or replaced:
                    try:
                        self._req("DELETE", f"/v3/connected_accounts/{a['id']}")
                    except Exception:  # noqa: BLE001
                        pass
                    continue
                val = (a.get("state") or {}).get("val") or {}
                keep.append({"id": a["id"], "app": slug, "alias": a.get("alias") or "",
                             "email": val.get("displayName") or "", "status": st.lower(),
                             "created_at": a.get("created_at")})
            self._cache = (time.time(), keep)
            try:
                self._sync_session_auth(items)
            except Exception as e:  # noqa: BLE001
                print(f"Composio-Sitzung: eigene Anmeldungen nicht übernommen: {str(e)[:200]}", flush=True)
            return keep

    def _sync_session_auth(self, items: list[dict]) -> None:
        """Konten mit eigener Auth-Config (API-Schlüssel/Token aus dem Formular) sieht die Tool-Router-Sitzung nur,
        wenn ihr die Config je Toolkit genannt wird (`auth_configs`); sonst meldet sie „keine Verbindung“, obwohl
        das Konto aktiv ist. Toolkits mit aktivem Composio-verwaltetem Konto bleiben ohne Vorgabe.
        Gesendet wird nur bei Änderung, immer die ganze Liste (Composio ersetzt sie)."""
        managed: set[str] = set()
        custom: dict[str, str] = {}
        for a in sorted(items, key=lambda x: str(x.get("created_at") or "")):
            if a.get("status") != "ACTIVE":
                continue
            ac = a.get("auth_config") or {}
            slug = (a.get("toolkit") or {}).get("slug")
            if not slug or not ac.get("id"):
                continue
            if ac.get("is_composio_managed", True):
                managed.add(slug)
            else:
                custom[slug] = ac["id"]
        # Eigene Auth-Configs ohne Konto (z. B. eigene X-App, Konto noch nicht angemeldet): sonst bricht schon der
        # Anmelde-Link mit „keine fertige Anmeldung“ ab.
        self._auth_configs()
        for slug, ac in self._custom_cfgs.items():
            if slug not in managed and slug not in custom and slug not in self._managed_cfgs:
                custom[slug] = ac
        want = {s: ac for s, ac in sorted(custom.items()) if s not in managed}
        _, sid, _ = self._cfg()
        if self._session_auth is None:
            cfg = self._req("GET", f"/v3.1/tool_router/session/{sid}").get("config") or {}
            self._session_auth = dict(cfg.get("auth_configs") or {})
        if want == self._session_auth:
            return
        self._req("PATCH", f"/v3.1/tool_router/session/{sid}", json={"auth_configs": want or None})
        self._session_auth = want
        print(f"Composio-Sitzung: eigene Anmeldungen für {', '.join(want) or 'keine'}", flush=True)

    def _extra(self) -> list[dict]:
        try:
            return list(self.extra_accounts() or [])
        except Exception:  # noqa: BLE001
            return []

    def overview(self, builtin: list[dict]) -> dict:
        extra = self._extra()
        try:
            accs = self.accounts()
        except RuntimeError:
            if not extra:  # ohne Composio und ohne direkte Verbindung: Fehler wie bisher
                raise
            accs = []  # z. B. nur Notion direkt verbunden, Composio nicht eingerichtet
        accs = accs + extra
        known = self._known()
        slugs = [s for s, _, _ in CATALOG] + sorted({a["app"] for a in accs} - set(NAMES))
        apps = []
        for slug in slugs:
            detail = translate(next((d for s, _, d in CATALOG if s == slug), "")) or (known.get(slug) or {}).get("description", "")
            mine = [a for a in accs if a["app"] == slug and a["status"] != "initializing"]
            apps.append({"slug": slug, "name": self.display_name(slug), "detail": detail,
                         "symbol": SF_SYMBOLS.get(slug, "app.connected.to.app.below.fill"),
                         "logo_url": (known.get(slug) or {}).get("logo_url") or f"https://logos.composio.dev/api/{slug}",
                         "accounts": mine, "can_add": sum(1 for a in mine if a["status"] == "active") < MAX_PER_APP})
        return {"apps": apps, "max_per_app": MAX_PER_APP, "builtin": builtin}

    def _check_add(self, slug: str, alias: str) -> None:
        """Grenzen vor dem Verbinden: höchstens MAX_PER_APP aktive Konten, Name je App eindeutig."""
        accs = self.accounts(fresh=True)
        mine = [a for a in accs if a["app"] == slug and a["status"] == "active"]
        if len(mine) >= MAX_PER_APP:
            raise ValueError(tx("Höchstens {max} Konten pro App", max=MAX_PER_APP))
        if alias and any(a["alias"].lower() == alias.lower() for a in mine):
            raise ValueError(tx("Diesen Namen gibt es für diese App schon"))

    def _check_slug(self, slug: str) -> None:
        if not SLUG_RE.match(slug or ""):
            raise NotFound(tx("Unbekannte App"))
        _, items, source = self._catalog
        if source == "composio" and items and slug not in {i["slug"] for i in items} and slug not in NAMES:
            raise NotFound(tx("Diese App gibt es bei Composio nicht."))

    def link(self, slug: str, alias: str | None) -> dict:
        _, sid, _ = self._cfg()
        self._check_slug(slug)
        alias = (alias or "").strip()
        self._check_add(slug, alias)
        body: dict = {"toolkit": slug}
        if alias:
            body["alias"] = alias
        try:
            d = self._req("POST", f"/v3.1/tool_router/session/{sid}/link", json=body)
        except ComposioError as e:
            # vielleicht eine eben erst angelegte eigene Auth-Config: Liste neu laden, der Sitzung melden, neu versuchen
            self._auth_configs(fresh=True)
            if not self._custom_cfgs.get(slug):
                raise self._link_error(slug, e) from None
            self.accounts(fresh=True)
            try:
                d = self._req("POST", f"/v3.1/tool_router/session/{sid}/link", json=body)
            except ComposioError as e2:
                raise self._link_error(slug, e2) from None
        self._cache = (0.0, [])
        return {"url": d["redirect_url"], "account_id": d.get("connected_account_id")}

    def _link_error(self, slug: str, e: ComposioError) -> Exception:
        """Composio-Fehler beim Link → verständliche Meldung (keine verwaltete Anmeldung, Name doppelt …)."""
        if e.slug.endswith("NoManagedAuth") or e.code == 4308 or e.status == 501:
            return Unsupported(unavailable(self.display_name(slug)))
        if e.status == 404:
            return NotFound(tx("{name} ist bei Composio nicht (mehr) verfügbar.", name=self.display_name(slug)))
        if e.status == 409:
            return ValueError(tx("Diesen Namen gibt es für diese App schon"))
        return e

    def status(self, account_id: str) -> dict:
        a = self._req("GET", f"/v3/connected_accounts/{account_id}")
        val = (a.get("state") or {}).get("val") or {}
        if a.get("status") == "ACTIVE":
            self._cache = (0.0, [])
        return {"id": a["id"], "app": a["toolkit"]["slug"], "alias": a.get("alias") or "",
                "email": val.get("displayName") or "", "status": (a.get("status") or "").lower()}

    def rename(self, account_id: str, alias: str) -> dict:
        alias = alias.strip()
        if not alias:
            raise ValueError(tx("Name fehlt"))
        self._req("PATCH", f"/v3/connected_accounts/{account_id}", json={"alias": alias})
        self._cache = (0.0, [])
        return self.status(account_id)

    def remove(self, account_id: str) -> None:
        self._req("DELETE", f"/v3/connected_accounts/{account_id}")
        self._cache = (0.0, [])

    def reconnect(self, account_id: str) -> dict:
        """Abgelaufenes Konto neu anmelden: neuer Link mit gleichem Namen; das alte fällt nach Erfolg weg."""
        a = self.status(account_id)
        _, sid, _ = self._cfg()
        body: dict = {"toolkit": a["app"]}
        if a["alias"]:
            body["alias"] = a["alias"]
        try:
            d = self._req("POST", f"/v3.1/tool_router/session/{sid}/link", json=body)
        except ComposioError as e:
            err = self._link_error(a["app"], e)
            if isinstance(err, Unsupported) and self.auth_info(a["app"]).get("auth") == "fields":
                raise Unsupported(tx("Dieses Konto meldest du neu an, indem du es trennst und mit neuem Schlüssel "
                                     "wieder verbindest.")) from None
            raise err from None
        self._cache = (0.0, [])
        return {"url": d["redirect_url"], "account_id": d.get("connected_account_id")}

    def account_for(self, app: str, key: str) -> dict | None:
        """Aktives Konto einer App über Namen (Alias), E-Mail-Adresse oder ID."""
        key = (key or "").strip().lower()
        mine = [a for a in self.accounts() if a["app"] == app and a["status"] == "active"]
        if not key and len(mine) == 1:
            return mine[0]
        for a in mine:
            if key in (a["alias"].lower(), a["email"].lower(), a["id"].lower()):
                return a
        hits = [a for a in mine if key and (key in a["alias"].lower() or key in a["email"].lower())]
        return hits[0] if len(hits) == 1 else None

    def execute(self, slug: str, account_id: str, args: dict) -> dict:
        """Führt ein Composio-Werkzeug direkt mit einem bestimmten Konto aus (z. B. nach Armans Freigabe)."""
        _, _, uid = self._cfg()
        d = self._req("POST", f"/v3/tools/execute/{slug}",
                      json={"connected_account_id": account_id, "user_id": uid, "arguments": args})
        if d.get("successful") is False or d.get("error"):
            raise RuntimeError(str(d.get("error") or tx("Composio meldet einen Fehler"))[:300])
        return d.get("data") or {}

    # -- Katalog (ab 1.16) ------------------------------------------------------------
    def display_name(self, slug: str) -> str:
        return NAMES.get(slug) or (self._known().get(slug) or {}).get("name") or slug.capitalize()

    def _known(self) -> dict[str, dict]:
        """Katalog ohne Netzabruf (Speicher, sonst Platte) – für Namen und Logos verbundener Apps."""
        if not self._by_slug:
            disk = self._read_disk()
            if disk:
                with self._catalog_lock:
                    if not self._catalog[1]:
                        self._set_catalog(disk)
        return self._by_slug

    def _path(self) -> Path:
        return Path(self.data_dir) / CATALOG_FILE

    def _read_disk(self) -> tuple[float, list[dict], str] | None:
        try:
            d = json.loads(self._path().read_text())
            items = d.get("items")
            if isinstance(items, list) and items and all(isinstance(i, dict) and i.get("slug") for i in items):
                return float(d.get("fetched_at") or 0), items, "composio"
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        return None

    def _write_disk(self, ts: float, items: list[dict]) -> None:
        try:
            path = self._path()
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"fetched_at": ts, "items": items}, ensure_ascii=False))
            tmp.replace(path)
        except OSError:
            pass

    def _set_catalog(self, entry: tuple[float, list[dict], str]) -> None:
        self._catalog = entry
        self._by_slug = {i["slug"]: i for i in entry[1]}

    def _fetch_catalog(self) -> list[dict]:
        """Alle Toolkits von Composio (seitenweise, je 1000), ohne veraltete und lokale."""
        key = _key()
        if not key:
            raise ComposioError(tx("Kein Composio-Schlüssel hinterlegt"))
        raw: list[dict] = []
        cursor = None
        for _ in range(20):
            params: dict = {"limit": 1000}
            if cursor:
                params["cursor"] = cursor
            d = self._call(key, "GET", "/v3/toolkits", params=params)
            page = d.get("items") or []
            raw.extend(page)
            cursor = d.get("next_cursor")
            if not cursor or not page:
                break
        seen: set[str] = set()
        out: list[dict] = []
        for tk in raw:
            if not isinstance(tk, dict) or not tk.get("slug") or tk["slug"] in seen:
                continue
            if (tk.get("deprecated") or {}).get("isDeprecated") or tk.get("is_local_toolkit"):
                continue
            seen.add(tk["slug"])
            out.append(_toolkit_item(tk, len(out)))
        if not out:
            raise ComposioError(tx("Composio: leerer Katalog"))
        return out

    def _refresh_catalog(self) -> None:
        try:
            items = self._fetch_catalog()
        except Exception:  # noqa: BLE001
            return
        now = time.time()
        with self._catalog_lock:
            self._set_catalog((now, items, "composio"))
        self._write_disk(now, items)

    def _refresh_in_background(self) -> None:
        if self._catalog_refreshing:
            return
        self._catalog_refreshing = True

        def run() -> None:
            try:
                self._refresh_catalog()
            finally:
                self._catalog_refreshing = False

        threading.Thread(target=run, daemon=True).start()

    def catalog_items(self) -> tuple[list[dict], str, float]:
        """Katalog aus Speicher → Platte → Composio. Älter als 24 h: Neuladen im Hintergrund, die alte Liste gilt
        so lange weiter. Ohne Composio (kein Schlüssel, offline): die zehn bekannten Apps, neuer Versuch nach 5 min."""
        with self._catalog_lock:
            if not self._catalog[1]:
                disk = self._read_disk()
                if disk:
                    self._set_catalog(disk)
            ts, items, source = self._catalog
            if items and source == "composio":
                if time.time() - ts > CATALOG_TTL:
                    self._refresh_in_background()
                return items, source, ts
            if items and source == "fallback" and time.time() - ts < 300:
                return items, source, ts
            try:
                fresh = self._fetch_catalog()
                now = time.time()
                self._set_catalog((now, fresh, "composio"))
            except Exception:  # noqa: BLE001
                self._set_catalog((time.time(), _fallback_items(), "fallback"))
                return self._catalog[1], "fallback", self._catalog[0]
        self._write_disk(now, fresh)
        return fresh, "composio", now

    def _auth_configs(self, fresh: bool = False) -> dict[str, dict[str, str]]:
        """Auth-Configs des Composio-Projekts: Toolkit → {Anmeldeart: ac_…} (10 min zwischengespeichert)."""
        ts, known = self._configs
        if not fresh and ts and time.time() - ts < 600:
            return known
        key = _key()
        if not key:
            return known
        out: dict[str, dict[str, str]] = {}
        custom: dict[str, str] = {}
        managed: set[str] = set()
        try:
            cursor = None
            for _ in range(10):
                params: dict = {"limit": 200}
                if cursor:
                    params["cursor"] = cursor
                d = self._call(key, "GET", "/v3/auth_configs", params=params)
                page = d.get("items") or []
                for a in page:
                    if str(a.get("status") or "ENABLED").upper() != "ENABLED":
                        continue
                    slug = (a.get("toolkit") or {}).get("slug")
                    scheme = str(a.get("auth_scheme") or "").upper()
                    if slug and scheme and a.get("id"):
                        out.setdefault(slug, {}).setdefault(scheme, a["id"])
                        if a.get("is_composio_managed", True):
                            managed.add(slug)
                        else:
                            custom.setdefault(slug, a["id"])
                cursor = d.get("next_cursor")
                if not cursor or not page:
                    break
        except Exception:  # noqa: BLE001
            self._configs = (time.time(), known)
            return known
        self._configs = (time.time(), out)
        self._custom_cfgs, self._managed_cfgs = custom, managed
        return out

    @staticmethod
    def _auth_kind(item: dict, configs: dict[str, dict[str, str]]) -> str:
        """oauth (Link im Browser) | fields (Formular) | none (keine Anmeldung nötig) | unavailable."""
        schemes = set(item.get("schemes") or [])
        managed = set(item.get("managed") or [])
        have = set(configs.get(item["slug"]) or {})
        if item.get("no_auth") or (schemes and schemes <= {"NO_AUTH"}):
            return "none"
        if managed & OAUTH_SCHEMES or "DCR_OAUTH" in schemes or (have - set(FIELD_SCHEMES) - {"NO_AUTH"}):
            return "oauth"
        if schemes & set(FIELD_SCHEMES):
            return "fields"
        return "unavailable"

    def _public(self, item: dict, by_app: dict[str, list[dict]], configs: dict[str, dict[str, str]]) -> dict:
        slug = item["slug"]
        mine = by_app.get(slug, [])
        active = sum(1 for a in mine if a["status"] == "active")
        cats = item.get("categories") or []
        return {"slug": slug, "name": self.display_name(slug), "detail": DETAILS.get(slug) or item.get("description") or "",
                "logo_url": item.get("logo_url") or f"https://logos.composio.dev/api/{slug}",
                "symbol": SF_SYMBOLS.get(slug), "category": cats[0] if cats else None, "categories": cats,
                "auth": self._auth_kind(item, configs), "auth_schemes": item.get("schemes") or [],
                "popular": slug in POPULAR_ORDER, "connected": active, "accounts": mine,
                "can_add": active < MAX_PER_APP, "tools": item.get("tools") or 0}

    def _accounts_by_app(self) -> dict[str, list[dict]]:
        try:
            accs = self.accounts()
        except Exception:  # noqa: BLE001
            accs = []
        accs = accs + self._extra()
        by: dict[str, list[dict]] = {}
        for a in accs:
            if a["status"] != "initializing":
                by.setdefault(a["app"], []).append(a)
        return by

    def catalog(self, category: str = "", q: str = "", limit: int = 60, offset: int = 0) -> dict:
        """Katalog für die App: Filter nach Kategorie (popular, connected, productivity …) und Suche über alle Apps,
        seitenweise (`limit` ≤ 200, `offset`). Ohne Filter: die bekannten Apps vorn, dann nach Beliebtheit."""
        items, source, ts = self.catalog_items()
        by = self._accounts_by_app()
        configs = self._auth_configs()
        index = {i["slug"] for i in items}
        extra = [{"slug": s, "name": self.display_name(s), "description": "", "categories": [], "category_names": [],
                  "schemes": ["OAUTH2"], "managed": ["OAUTH2"], "no_auth": False, "tools": 0, "rank": 10_000}
                 for s in sorted(by) if s not in index]
        pool = items + extra
        cat = (category or "").strip().lower()
        query = " ".join((q or "").lower().split())

        def base(i: dict) -> tuple:
            return POPULAR_ORDER.get(i["slug"], 99), i.get("rank", 0)

        if cat == "popular":
            sel = sorted((i for i in pool if i["slug"] in POPULAR_ORDER), key=base)
        elif cat == "connected":
            sel = sorted((i for i in pool if by.get(i["slug"])), key=base)
        elif cat:
            sel = sorted((i for i in pool if cat in (i.get("categories") or [])), key=base)
        else:
            sel = sorted(pool, key=base)
        if query:
            scored = [(sc, i) for i in sel if (sc := _search_score(i, query))]
            scored.sort(key=lambda x: (-x[0], *base(x[1])))
            sel = [i for _, i in scored]
        limit = max(1, min(int(limit or 60), 200))
        offset = max(0, int(offset or 0))
        page = sel[offset:offset + limit]
        return {"items": [self._public(i, by, configs) for i in page], "total": len(sel), "offset": offset,
                "next_offset": offset + limit if offset + limit < len(sel) else None,
                "connected_apps": sum(1 for s, v in by.items() if any(a["status"] == "active" for a in v)),
                "max_per_app": MAX_PER_APP, "source": source,
                "updated_at": datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None}

    def categories(self) -> dict:
        """Kategorie-Chips: Beliebt, Verbunden, eigene Gruppen (deutsch), dann häufige unbekannte im Original."""
        items, source, _ = self.catalog_items()
        counts = Counter(c for i in items for c in i.get("categories") or [])
        raw_name: dict[str, str] = {}
        for i in items:
            for cid, name in zip(i.get("categories") or [], i.get("category_names") or []):
                raw_name.setdefault(cid, name)
        by = self._accounts_by_app()
        out = [{"id": "popular", "name": tx("Beliebt"), "count": len(CATALOG)},
               {"id": "connected", "name": tx("Verbunden"), "count": len(by)}]
        out += [{"id": gid, "name": translate(label), "count": counts[gid]} for gid, label, _ in GROUPS if counts[gid]]
        others = sorted(((cid, n) for cid, n in counts.items() if cid not in GROUP_NAMES and n >= MIN_OTHER_CATEGORY),
                        key=lambda x: (-x[1], x[0]))
        for cid, n in others:
            name = raw_name.get(cid) or cid
            out.append({"id": cid, "name": name[:1].upper() + name[1:], "count": n})
        return {"categories": out, "total": len(items), "source": source}

    def _toolkit_detail(self, slug: str) -> dict:
        ts, d = self._details.get(slug, (0.0, {}))
        if d and time.time() - ts < CATALOG_TTL:
            return d
        key = _key()
        if not key:
            raise ComposioError(tx("Kein Composio-Schlüssel hinterlegt"))
        try:
            d = self._call(key, "GET", f"/v3/toolkits/{slug}")
        except ComposioError as e:
            if e.status == 404:
                raise NotFound(tx("Diese App gibt es bei Composio nicht.")) from None
            raise
        self._details[slug] = (time.time(), d)
        return d

    def auth_info(self, slug: str) -> dict:
        """Wie sich eine App verbinden lässt; bei `fields` mit den Formularfeldern (Name, Beschriftung, geheim …)."""
        self.catalog_items()
        self._check_slug(slug)
        item = self._by_slug.get(slug) or {"slug": slug, "schemes": ["OAUTH2"], "managed": ["OAUTH2"]}
        name = self.display_name(slug)
        kind = self._auth_kind(item, self._auth_configs())
        out: dict = {"slug": slug, "name": name, "detail": DETAILS.get(slug) or item.get("description") or "",
                     "logo_url": item.get("logo_url") or f"https://logos.composio.dev/api/{slug}",
                     "auth": kind, "scheme": None, "fields": [], "message": None, "guide_url": None,
                     "max_per_app": MAX_PER_APP}
        if kind == "none":
            out["message"] = tx("{name} braucht keine Anmeldung. Die Scoops können die App direkt nutzen.", name=name)
        elif kind == "unavailable":
            out["message"] = unavailable(name)
        elif kind == "fields":
            detail = self._toolkit_detail(slug)
            chosen = None
            for scheme in FIELD_SCHEMES:
                for cfg in detail.get("auth_config_details") or []:
                    fields = cfg.get("fields") or {}
                    if str(cfg.get("mode") or "").upper() == scheme and not (fields.get("auth_config_creation") or {}).get("required"):
                        chosen = (scheme, cfg)
                        break
                if chosen:
                    break
            if not chosen:
                out.update(auth="unavailable", message=unavailable(name))
            else:
                scheme, cfg = chosen
                init = (cfg.get("fields") or {}).get("connected_account_initiation") or {}
                fields = [_field(f, True) for f in init.get("required") or [] if f.get("user_visible", True)]
                fields += [_field(f, False) for f in init.get("optional") or [] if f.get("user_visible", True)]
                out.update(scheme=scheme, fields=[f for f in fields if f["name"]],
                           guide_url=detail.get("auth_guide_url") or cfg.get("auth_hint_url"))
        return out

    def _auth_config_id(self, slug: str, scheme: str, name: str) -> str:
        """Vorhandene Auth-Config der Anmeldeart oder neue eigene (`use_custom_auth`, ohne Zugangsdaten): Die
        Werte trägt jedes Konto selbst. Die Tool-Router-Sitzung erfährt die Config über `_sync_session_auth`."""
        for fresh in (False, True):
            ac = (self._auth_configs(fresh=fresh).get(slug) or {}).get(scheme)
            if ac:
                return ac
        d = self._req("POST", "/v3/auth_configs",
                      json={"toolkit": {"slug": slug},
                            "auth_config": {"type": "use_custom_auth", "authScheme": scheme,
                                            "name": f"{name} (Scoops)", "credentials": {}}})
        ac = (d.get("auth_config") or {}).get("id") or d.get("id")
        if not ac:
            raise ComposioError(tx("Composio: Antwort ohne Auth-Config-ID"))
        self._configs = (0.0, {})
        return ac

    def connect(self, slug: str, alias: str | None, values: dict | None) -> dict:
        """Konto mit API-Schlüssel/Feldern anlegen. Die Werte gehen nur an Composio: kein Speichern, kein Log,
        in Fehlermeldungen geschwärzt."""
        _, _, uid = self._cfg()
        info = self.auth_info(slug)
        if info["auth"] != "fields":
            if info["auth"] == "oauth":
                raise Unsupported(tx("{name} verbindest du über die Anmeldung im Browser.", name=info["name"]))
            raise Unsupported(info.get("message") or unavailable(info["name"]))
        if isinstance(values, list):  # App: [{"name": …, "value": …}] (Feldnamen bleiben unverändert)
            values = {str(x.get("name")): x.get("value") for x in values if isinstance(x, dict) and x.get("name")}
        values = values if isinstance(values, dict) else {}
        val: dict[str, str] = {}
        for f in info["fields"]:
            v = values.get(f["name"])
            v = "" if v is None else str(v).strip()
            if not v and not f["secret"] and f.get("default") not in (None, ""):
                v = str(f["default"])
            if not v:
                if f["required"]:
                    raise ValueError(tx("Bitte „{label}“ ausfüllen.", label=f["label"]))
                continue
            if len(v) > 4000:
                raise ValueError(tx("„{label}“ ist zu lang.", label=f["label"]))
            val[f["name"]] = v
        alias = (alias or "").strip()
        self._check_add(slug, alias)
        ac = self._auth_config_id(slug, info["scheme"], info["name"])
        conn: dict = {"user_id": uid, "state": {"authScheme": info["scheme"], "val": val}}
        if alias:
            conn["alias"] = alias
        try:
            d = self._req("POST", "/v3.1/connected_accounts", json={"auth_config": {"id": ac}, "connection": conn},
                          scrub=tuple(val.values()))
        except ComposioError as e:
            text = f"{e.slug} {e}".lower()
            if "credentialvalidation" in text or "credential" in text or e.status == 422:
                raise ValueError(tx("{name} hat die Angaben abgelehnt. Bitte prüfe sie und versuche es "
                                    "noch einmal.", name=info["name"])) from None
            if e.status == 409:
                raise ValueError(tx("Diesen Namen gibt es für diese App schon")) from None
            raise ComposioError(str(e), e.status, e.slug, e.code) from None
        finally:
            val.clear()
        self._cache = (0.0, [])
        try:
            self.accounts(fresh=True)  # meldet die neue Anmeldung gleich der Tool-Router-Sitzung
        except Exception:  # noqa: BLE001
            pass
        return {"account_id": d.get("id"), "status": str(d.get("status") or "initiated").lower()}

    def logo_png(self, slug: str) -> bytes:
        """App-Logo als PNG (128 px), 30 Tage auf der Platte. Composio liefert SVG; umgewandelt mit `sips` (macOS)."""
        if not SLUG_RE.match(slug or ""):
            raise NotFound(tx("Unbekannte App"))
        path = Path(self.data_dir) / LOGO_DIR / f"{slug}.png"
        try:
            if path.stat().st_size and time.time() - path.stat().st_mtime < LOGO_TTL:
                return path.read_bytes()
        except OSError:
            pass
        url = (self._known().get(slug) or {}).get("logo_url") or ""
        if not url.startswith("https://"):
            url = f"https://logos.composio.dev/api/{slug}"
        try:
            r = self.http.get(url, follow_redirects=True, timeout=10)
        except httpx.HTTPError as e:
            raise NotFound(tx("Kein Logo")) from e
        if r.status_code >= 400 or not r.content or len(r.content) > LOGO_MAX_BYTES:
            raise NotFound(tx("Kein Logo"))
        ctype = r.headers.get("content-type", "").split(";")[0].strip().lower()
        ext = {"image/svg+xml": ".svg", "image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp",
               "image/gif": ".gif"}.get(ctype) or (".svg" if r.content.lstrip()[:5] in (b"<svg ", b"<?xml") else "")
        if not ext:
            raise NotFound(tx("Kein Logo"))
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            src, out = Path(tmp) / f"logo{ext}", Path(tmp) / "logo.png"
            src.write_bytes(r.content)
            try:
                res = subprocess.run(["sips", "-s", "format", "png", "-Z", "128", str(src), "--out", str(out)],
                                     capture_output=True, timeout=20)
            except (OSError, subprocess.TimeoutExpired) as e:
                raise NotFound(tx("Kein Logo")) from e
            if res.returncode != 0 or not out.exists() or not out.stat().st_size:
                raise NotFound(tx("Kein Logo"))
            data = out.read_bytes()
        try:
            path.write_bytes(data)
        except OSError:
            pass
        return data

    # -- für die Systemanweisung der Scoops --------------------------------------------
    def prompt_block(self) -> str | None:
        """Kurze Kontenliste; blockiert nie lange (nutzt den Zwischenspeicher, aktualisiert im Hintergrund)."""
        ts, accs = self._cache
        if time.time() - ts > 60:
            if ts == 0:
                try:
                    accs = self.accounts()
                except Exception:  # noqa: BLE001
                    return None
            else:
                threading.Thread(target=lambda: self._safe_refresh(), daemon=True).start()
        by_app: dict[str, list[str]] = {}
        for a in accs:
            if a["status"] != "active":
                continue
            label = a["alias"] or a["email"] or a["id"]
            if a["email"] and a["alias"] and a["email"] != a["alias"]:
                label += f" ({a['email']})"
            by_app.setdefault(self.display_name(a["app"]), []).append(label)
        try:
            extra = self.extra_prompt()
        except Exception:  # noqa: BLE001
            extra = None
        if not by_app:
            return extra
        lines = "\n".join(f"- {app}: " + ", ".join(v) for app, v in by_app.items())
        return ("Verbundene Konten (Composio). Bei mehreren Konten einer App wählst du es in COMPOSIO_MULTI_EXECUTE_TOOL "
                "über `account` = Name vor der Klammer. Nennt Arman kein Konto: lesen/suchen über die passenden Konten, "
                "senden nur aus dem eindeutig passenden Konto, sonst kurz nachfragen.\n" + lines
                + (f"\n{extra}" if extra else ""))

    def _safe_refresh(self) -> None:
        try:
            self.accounts(fresh=True)
        except Exception:  # noqa: BLE001
            pass
