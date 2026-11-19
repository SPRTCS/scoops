"""Test für „Apps verbinden“ mit dem ganzen Composio-Katalog (Server 1.16).

Composio ist komplett gemockt (httpx.MockTransport), es gibt keine echten Aufrufe. Eigene Testinstanz
(Temp-Ordner, eigener Schlüsselbund-Präfix, Edition standard), nie die Produktion.

    cd Server && uv run python tests/test_connections_catalog.py
"""

from __future__ import annotations

import io
import json
import logging
import os
import sys
import tempfile
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-catalog-test-"))
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-cattest-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from aisbot import connections as conn_mod, server  # noqa: E402
from aisbot.connections import ComposioError, Connections, NotFound, Unsupported  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"

SECRET = "test-wert-" + os.urandom(8).hex()  # zufällig, nur für den Test
LOGO_SVG = (b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
            b'<rect width="64" height="64" rx="12" fill="#E5482F"/><circle cx="32" cy="32" r="14" fill="#fff"/></svg>')
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


def raises(exc, fn, *a):
    try:
        fn(*a)
    except exc as e:  # noqa: BLE001
        return e
    raise AssertionError(f"{exc.__name__} erwartet")


# -- Fake Composio -------------------------------------------------------------------
def tk(slug, name, cats, schemes, managed=(), desc="", no_auth=False):
    return {"slug": slug, "name": name, "auth_schemes": list(schemes), "composio_managed_auth_schemes": list(managed),
            "no_auth": no_auth, "is_local_toolkit": False, "deprecated": {"toolkitId": "x"},
            "meta": {"description": desc or f"{name} is a helpful tool for teams. It does many things.", "logo": f"https://logos.example/{slug}",
                     "categories": [{"id": c, "name": c} for c in cats], "tools_count": 5}}


TOOLKITS = [
    tk("gmail", "Gmail", ["email"], ["OAUTH2"], ["OAUTH2"]),
    tk("tavily", "Tavily", ["ai web scraping", "web search & research"], ["API_KEY"]),
    tk("notion", "Notion", ["productivity", "documents"], ["OAUTH2"], ["OAUTH2"]),
    tk("freshdesk", "Freshdesk", ["customer support"], ["API_KEY"]),
    tk("twitter", "Twitter", ["social media accounts"], ["OAUTH2"]),
    tk("apify_mcp", "Apify MCP", ["model context protocol"], ["DCR_OAUTH"]),
    tk("weatherfree", "Weather Free", ["places & weather"], ["NO_AUTH"], no_auth=True),
    tk("snowflake", "Snowflake", ["databases"], ["OAUTH2"]),
    tk("figma", "Figma", ["images & design"], ["OAUTH2"], ["OAUTH2"]),
    tk("quirky", "Quirky", ["space travel"], ["BASIC"]),
] + [tk(f"space{i}", f"Space App {i}", ["space travel"], ["API_KEY"]) for i in range(9)] + [
    tk("kaputt", "Kaputt", ["email"], ["API_KEY"])]

DETAILS = {
    "tavily": {"slug": "tavily", "auth_guide_url": None, "auth_config_details": [
        {"mode": "API_KEY", "fields": {"auth_config_creation": {"required": [], "optional": []},
                                       "connected_account_initiation": {"required": [
                                           {"name": "generic_api_key", "displayName": "API Key", "type": "string",
                                            "description": "Dein Tavily-Schlüssel", "required": True,
                                            "is_secret": True, "user_visible": True}], "optional": []}}}]},
    "freshdesk": {"slug": "freshdesk", "auth_config_details": [
        {"mode": "API_KEY", "fields": {"auth_config_creation": {"required": [], "optional": []},
                                       "connected_account_initiation": {"required": [
                                           {"name": "subdomain", "displayName": "Subdomain", "type": "string",
                                            "required": True, "is_secret": False, "user_visible": True},
                                           {"name": "generic_api_key", "displayName": "API Key", "type": "string",
                                            "required": True, "is_secret": True, "user_visible": True}],
                                           "optional": [{"name": "region", "displayName": "Region", "type": "string",
                                                         "default": "eu", "required": False}]}}}]},
    "quirky": {"slug": "quirky", "auth_config_details": [
        {"mode": "BASIC", "fields": {"auth_config_creation": {"required": [{"name": "client_id"}], "optional": []},
                                     "connected_account_initiation": {"required": [], "optional": []}}}]},
}


class Fake:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict | None]] = []
        self.accounts: list[dict] = []
        self.auth_configs: list[dict] = [{"id": "ac_gmail", "toolkit": {"slug": "gmail"}, "auth_scheme": "OAUTH2",
                                          "status": "ENABLED"}]
        self.fail_toolkits = False
        self.reject_key = False
        self.echo_secret = False
        self.session_auth: dict = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "logos.example":
            self.calls.append(("LOGO", request.url.path, None))
            if request.url.path.endswith("/kaputt"):
                return httpx.Response(200, content=b"nicht svg", headers={"content-type": "text/plain"})
            return httpx.Response(200, content=LOGO_SVG, headers={"content-type": "image/svg+xml"})
        path, method = request.url.path.removeprefix("/api"), request.method
        body = json.loads(request.content) if request.content else None
        self.calls.append((method, path, body))
        assert request.headers.get("x-api-key") == "test-key"
        if path == "/v3/toolkits" and method == "GET":
            if self.fail_toolkits:
                return httpx.Response(503, json={"error": {"message": "down"}})
            cursor = request.url.params.get("cursor")
            if not cursor:
                return httpx.Response(200, json={"items": TOOLKITS[:6], "next_cursor": "p2"})
            return httpx.Response(200, json={"items": TOOLKITS[6:], "next_cursor": None})
        if path.startswith("/v3/toolkits/") and method == "GET":
            slug = path.rsplit("/", 1)[1]
            if slug in DETAILS:
                return httpx.Response(200, json=DETAILS[slug])
            return httpx.Response(404, json={"error": {"message": f"Toolkit {slug} not found", "status": 404}})
        if path == "/v3/auth_configs" and method == "GET":
            return httpx.Response(200, json={"items": self.auth_configs, "next_cursor": None})
        if path == "/v3/auth_configs" and method == "POST":
            ac = {"id": f"ac_new_{body['toolkit']['slug']}", "toolkit": body["toolkit"],
                  "auth_scheme": body["auth_config"]["authScheme"], "status": "ENABLED"}
            self.auth_configs.append(ac)
            return httpx.Response(201, json={"toolkit": body["toolkit"], "auth_config": {"id": ac["id"],
                                             "auth_scheme": ac["auth_scheme"], "is_composio_managed": False}})
        if path == "/v3/connected_accounts" and method == "GET":
            return httpx.Response(200, json={"items": self.accounts})
        if path == "/v3.1/connected_accounts" and method == "POST":
            key = body["connection"]["state"]["val"].get("generic_api_key", "")
            if self.reject_key:
                msg = f"Invalid key {key}" if self.echo_secret else "Invalid credentials"
                return httpx.Response(400, json={"error": {"message": msg,
                                                           "slug": "ConnectedAccount_CredentialValidationRejected"}})
            if self.echo_secret:
                return httpx.Response(500, json={"error": {"message": f"boom {key} boom"}})
            slug = next(a["toolkit"]["slug"] for a in self.auth_configs if a["id"] == body["auth_config"]["id"])
            acc = {"id": f"ca_{len(self.accounts) + 1}", "toolkit": {"slug": slug}, "status": "ACTIVE",
                   "auth_config": {"id": body["auth_config"]["id"], "is_composio_managed": False},
                   "alias": body["connection"].get("alias"), "created_at": "2026-11-14T10:00:00Z", "state": {"val": {}}}
            self.accounts.append(acc)
            return httpx.Response(201, json={"id": acc["id"], "status": "ACTIVE", "connectionData": {"val": {"generic_api_key": "tvly..."}}})
        if path == "/v3.1/tool_router/session/sess_1" and method == "GET":
            return httpx.Response(200, json={"session_id": "sess_1", "config": {"user_id": "u_test", "auth_configs": self.session_auth or None}})
        if path == "/v3.1/tool_router/session/sess_1" and method == "PATCH":
            self.session_auth = dict(body.get("auth_configs") or {})
            return httpx.Response(200, json={"session_id": "sess_1", "config": {"auth_configs": self.session_auth}})
        if path.startswith("/v3.1/tool_router/session/") and path.endswith("/link"):
            if body["toolkit"] in ("twitter", "snowflake"):
                return httpx.Response(400, json={"error": {"message": "Composio does not manage auth", "code": 4308,
                                                           "slug": "ToolRouterV2_NoManagedAuth", "status": 400}})
            return httpx.Response(201, json={"redirect_url": "https://connect.example/x", "connected_account_id": "ca_link"})
        return httpx.Response(404, json={"error": {"message": f"unbekannt {method} {path}"}})


def make(fake: Fake, data_dir: Path, key: str | None = "test-key") -> Connections:
    conn_mod._key = lambda: key  # noqa: SLF001 – Schlüsselbund im Test ersetzen
    c = Connections(lambda: {"composio_session_id": "sess_1", "composio_user_id": "u_test"})
    c.http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    c.data_dir = data_dir
    return c


def toolkit_gets(fake: Fake) -> int:
    return sum(1 for m, p, _ in fake.calls if m == "GET" and p == "/v3/toolkits")


def main() -> None:
    log = io.StringIO()
    handler = logging.StreamHandler(log)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.DEBUG)
    for name in ("httpx", "httpcore", "aisbot", "uvicorn", "fastapi"):
        logging.getLogger(name).setLevel(logging.DEBUG)

    data = TMP / "data"
    print("Katalog laden und cachen")
    fake = Fake()
    c = make(fake, data)
    res = c.catalog()
    ok(toolkit_gets(fake) == 2, "Composio-Katalog seitenweise geladen (cursor)")
    ok(res["source"] == "composio" and res["total"] == len(TOOLKITS), f"alle {len(TOOLKITS)} Apps im Katalog")
    ok((data / "composio_catalog.json").exists(), "Katalog auf der Platte gespeichert")
    ok([i["slug"] for i in res["items"][:3]] == ["gmail", "notion", "tavily"], "bekannte Apps (Beliebt) vorn")
    g = res["items"][0]
    ok(g["name"] == "Gmail" and g["detail"].startswith("Mails lesen") and g["popular"], "deutscher Text für Gmail")
    ok(g["logo_url"] == "https://logos.example/gmail" and g["symbol"] == "envelope.fill", "Logo-URL und SF-Symbol")
    t = next(i for i in res["items"] if i["slug"] == "tavily")
    ok(t["detail"] == "Tavily is a helpful tool for teams." and t["category"] == "data", "Beschreibung einzeilig, Kategorie gemappt")

    print("Anmeldearten")
    kinds = {i["slug"]: i["auth"] for i in c.catalog(limit=200)["items"]}
    ok(kinds["gmail"] == "oauth" and kinds["notion"] == "oauth", "Composio-verwaltetes OAuth → oauth")
    ok(kinds["apify_mcp"] == "oauth", "DCR_OAUTH → oauth (Link)")
    ok(kinds["tavily"] == "fields" and kinds["freshdesk"] == "fields", "API_KEY → Formular")
    ok(kinds["weatherfree"] == "none", "NO_AUTH → keine Anmeldung")
    ok(kinds["twitter"] == "unavailable" and kinds["snowflake"] == "unavailable", "OAuth ohne verwaltete Config → nicht verfügbar")
    fake.auth_configs.append({"id": "ac_tw", "toolkit": {"slug": "twitter"}, "auth_scheme": "OAUTH2", "status": "ENABLED"})
    c._configs = (0.0, {})  # noqa: SLF001
    ok(next(i for i in c.catalog(q="twitter")["items"])["auth"] == "oauth", "eigene Auth-Config im Projekt → oauth")
    fake.auth_configs.pop()
    c._configs = (0.0, {})  # noqa: SLF001

    print("Kategorien")
    cats = c.categories()["categories"]
    ids = [x["id"] for x in cats]
    ok(ids[:2] == ["popular", "connected"] and cats[0]["name"] == "Beliebt" and cats[1]["name"] == "Verbunden",
       "Beliebt und Verbunden vorn")
    names = {x["id"]: x["name"] for x in cats}
    ok(names.get("productivity") == "Produktivität" and names.get("communication") == "Kommunikation"
       and names.get("design") == "Design" and names.get("development") == "Entwicklung" and names.get("data") == "Daten",
       "deutsche Namen für Composio-Kategorien")
    ok(names.get("space-travel") == "Space travel", "unbekannte Kategorie mit Originalnamen")
    ok("ä" in names["productivity"], "Umlaute korrekt")
    prod = c.catalog(category="productivity")
    ok([i["slug"] for i in prod["items"]] == ["notion"], "Filter Produktivität")
    ok([i["slug"] for i in c.catalog(category="data")["items"]] == ["tavily", "weatherfree", "snowflake"],
       "Filter Daten (Beliebtheit)")
    pop = c.catalog(category="popular")
    ok([i["slug"] for i in pop["items"]] == ["gmail", "notion"], "Beliebt: nur die bekannten Apps, in fester Reihenfolge")

    print("Suche und Seiten")
    ok([i["slug"] for i in c.catalog(q="Fresh")["items"]][:1] == ["freshdesk"], "Suche nach Namensanfang")
    ok([i["slug"] for i in c.catalog(q="space app 3")["items"]][:1] == ["space3"], "Suche mit Leerzeichen")
    ok(c.catalog(q="helpful tool")["total"] == len(TOOLKITS), "Suche in Beschreibungen")
    ok(c.catalog(q="zzzz")["total"] == 0, "kein Treffer → leer")
    p1 = c.catalog(limit=5)
    p2 = c.catalog(limit=5, offset=p1["next_offset"])
    ok(p1["next_offset"] == 5 and len(p2["items"]) == 5 and not ({i["slug"] for i in p1["items"]} & {i["slug"] for i in p2["items"]}),
       "Seiten ohne Überschneidung")
    ok(c.catalog(limit=5, offset=len(TOOLKITS) - 2)["next_offset"] is None, "letzte Seite ohne next_offset")
    ok(len(c.catalog(limit=10_000)["items"]) == len(TOOLKITS), "limit wird auf 200 begrenzt")

    print("Cache auf der Platte (24 h)")
    fake2 = Fake()
    fake2.fail_toolkits = True
    c2 = make(fake2, data)
    ok(c2.catalog()["source"] == "composio" and toolkit_gets(fake2) == 0, "frischer Cache: kein Netzabruf")
    d = json.loads((data / "composio_catalog.json").read_text())
    d["fetched_at"] = time.time() - 25 * 3600
    (data / "composio_catalog.json").write_text(json.dumps(d))
    fake3 = Fake()
    c3 = make(fake3, data)
    r3 = c3.catalog()
    ok(r3["total"] == len(TOOLKITS), "alter Cache wird sofort geliefert")
    for _ in range(50):
        if toolkit_gets(fake3) >= 2 and not c3._catalog_refreshing:  # noqa: SLF001
            break
        time.sleep(0.05)
    ok(toolkit_gets(fake3) == 2 and time.time() - json.loads((data / "composio_catalog.json").read_text())["fetched_at"] < 60,
       "älter als 24 h → im Hintergrund neu geladen")
    fake4 = Fake()
    c4 = make(fake4, TMP / "leer", key=None)
    r4 = c4.catalog()
    ok(r4["source"] == "fallback" and r4["total"] == 10 and toolkit_gets(fake4) == 0, "ohne Schlüssel: die zehn bekannten Apps")
    conn_mod._key = lambda: "test-key"  # noqa: SLF001

    print("Formularfelder")
    info = c.auth_info("freshdesk")
    ok(info["auth"] == "fields" and info["scheme"] == "API_KEY", "Freshdesk: API_KEY")
    f = {x["name"]: x for x in info["fields"]}
    ok(list(f) == ["subdomain", "generic_api_key", "region"], "Felder in Reihenfolge, Pflicht vor optional")
    ok(f["generic_api_key"]["secret"] and not f["subdomain"]["secret"], "geheim laut Composio")
    ok(f["region"]["required"] is False and f["region"]["default"] == "eu", "optionales Feld mit Vorgabe")
    ok(c.auth_info("gmail")["auth"] == "oauth" and c.auth_info("gmail")["fields"] == [], "OAuth: keine Felder")
    u = c.auth_info("twitter")
    ok(u["auth"] == "unavailable" and "keine fertige Anmeldung" in u["message"], "verständliche Meldung ohne Auth-Config")
    ok(c.auth_info("quirky")["auth"] == "unavailable", "BASIC mit nötigen Entwickler-Zugangsdaten → nicht verfügbar")
    ok("keine Anmeldung" in c.auth_info("weatherfree")["message"], "ohne Anmeldung: Hinweis")
    raises(NotFound, c.auth_info, "gibtsnicht")
    raises(NotFound, c.auth_info, "../etc")
    ok(True, "unbekannte oder ungültige App → NotFound")

    print("Verbinden mit Schlüssel")
    r = c.connect("tavily", "privat", {"generic_api_key": SECRET, "unbekannt": "x"})
    ok(r == {"account_id": "ca_1", "status": "active"}, "Konto angelegt, Antwort ohne Werte")
    post_ac = [b for m, p, b in fake.calls if m == "POST" and p == "/v3/auth_configs"]
    ok(len(post_ac) == 1 and post_ac[0]["auth_config"] == {"type": "use_custom_auth", "authScheme": "API_KEY",
                                                           "name": "Tavily (Scoops)", "credentials": {}},
       "eigene Auth-Config ohne Zugangsdaten angelegt")
    post_ca = [b for m, p, b in fake.calls if m == "POST" and p == "/v3.1/connected_accounts"]
    ok(post_ca[-1]["connection"] == {"user_id": "u_test", "alias": "privat",
                                     "state": {"authScheme": "API_KEY", "val": {"generic_api_key": SECRET}}}
       and post_ca[-1]["auth_config"] == {"id": "ac_new_tavily"}, "Werte gehen nur an Composio (state.val), unbekannte Felder weg")
    patches = lambda: [b for m, p, b in fake.calls if m == "PATCH"]  # noqa: E731
    ok(fake.session_auth == {"tavily": "ac_new_tavily"} and len(patches()) == 1,
       "Tool-Router-Sitzung kennt die eigene Auth-Config sofort nach dem Verbinden")
    c.connect("tavily", "arbeit", {"generic_api_key": SECRET})
    ok(sum(1 for m, p, _ in fake.calls if m == "POST" and p == "/v3/auth_configs") == 1, "vorhandene Auth-Config wiederverwendet")
    ok(next(i for i in c.catalog(category="connected")["items"] if i["slug"] == "tavily")["connected"] == 2,
       "Verbunden: zwei Tavily-Konten")
    ok(c.catalog()["connected_apps"] == 1, "connected_apps zählt Apps")
    e = raises(ValueError, c.connect, "tavily", "Privat", {"generic_api_key": SECRET})
    ok("schon" in str(e), "Name je App eindeutig")
    e = raises(ValueError, c.connect, "freshdesk", None, {"generic_api_key": SECRET})
    ok("Subdomain" in str(e), "Pflichtfeld fehlt → Hinweis")
    c.connect("freshdesk", None, {"subdomain": "acme", "generic_api_key": SECRET})
    last_ca = lambda: [b for m, p, b in fake.calls if m == "POST" and p == "/v3.1/connected_accounts"][-1]  # noqa: E731
    ok(last_ca()["connection"]["state"]["val"] == {"subdomain": "acme", "generic_api_key": SECRET, "region": "eu"},
       "Vorgabe für optionales Feld übernommen")
    ok(fake.session_auth == {"freshdesk": "ac_new_freshdesk", "tavily": "ac_new_tavily"} and len(patches()) == 2,
       "Sitzung: ganze Liste, nur bei Änderung gesendet")
    fake.accounts.append({"id": "ca_g", "toolkit": {"slug": "gmail"}, "status": "ACTIVE", "alias": "", "created_at": "2026-11-14T10:00:00Z",
                          "auth_config": {"id": "ac_gmail", "is_composio_managed": True}, "state": {"val": {}}})
    c.accounts(fresh=True)
    ok("gmail" not in fake.session_auth and len(patches()) == 2, "verwaltete Konten (OAuth) ohne Vorgabe")
    fake.accounts.pop()
    fake.auth_configs.append({"id": "ac_x", "toolkit": {"slug": "twitter"}, "auth_scheme": "OAUTH2", "status": "ENABLED",
                              "is_composio_managed": False})
    c._configs = (0.0, {})  # noqa: SLF001
    c.accounts(fresh=True)
    ok(fake.session_auth.get("twitter") == "ac_x", "eigene OAuth-App ohne Konto: Sitzung kennt sie schon vor der Anmeldung")
    fake.auth_configs.pop()
    c._configs = (0.0, {})  # noqa: SLF001
    c.accounts(fresh=True)
    ok("twitter" not in fake.session_auth, "gelöschte eigene Auth-Config fällt aus der Sitzung")
    raises(Unsupported, c.connect, "gmail", None, {})
    raises(Unsupported, c.connect, "twitter", None, {})
    ok(True, "Formular nur für Schlüssel-Apps")
    fake.reject_key = True
    e = raises(ValueError, c.connect, "tavily", "neu", {"generic_api_key": SECRET})
    ok("abgelehnt" in str(e) and SECRET not in str(e), "abgelehnter Schlüssel → klare Meldung")
    fake.echo_secret = True
    e = raises(ValueError, c.connect, "tavily", "neu", {"generic_api_key": SECRET})
    ok(SECRET not in str(e), "Composio-Echo des Schlüssels geschwärzt (abgelehnt)")
    fake.reject_key = False
    e = raises(ComposioError, c.connect, "tavily", "neu", {"generic_api_key": SECRET})
    ok(SECRET not in str(e) and "•••" in str(e), "Composio-Echo des Schlüssels geschwärzt (Serverfehler)")
    fake.echo_secret = False

    print("Grenze 10 Konten, Link-Fehler")
    for i in range(10 - 2):
        c.connect("tavily", f"k{i}", {"generic_api_key": SECRET})
    e = raises(ValueError, c.connect, "tavily", "elf", {"generic_api_key": SECRET})
    ok("Höchstens 10" in str(e), "höchstens 10 Konten pro App")
    ok(c.link("gmail", None)["url"].startswith("https://"), "Link für OAuth-App")
    ok(c.link("apify_mcp", "x")["account_id"] == "ca_link", "Link für beliebige Slugs")
    e = raises(Unsupported, c.link, "snowflake", None)
    ok("Snowflake" in str(e) and "keine fertige Anmeldung" in str(e), "Link ohne verwaltete Anmeldung → verständliche Meldung")
    raises(NotFound, c.link, "gibtsnicht", None)
    ok(True, "Link für unbekannte App → NotFound")

    print("Logos (SVG → PNG)")
    png = c.logo_png("gmail")
    ok(png[:8] == b"\x89PNG\r\n\x1a\n", "SVG-Logo als PNG geliefert")
    n = sum(1 for m, _, _ in fake.calls if m == "LOGO")
    ok(c.logo_png("gmail") == png and sum(1 for m, _, _ in fake.calls if m == "LOGO") == n, "Logo aus dem Platten-Cache")
    ok((data / "connection_logos" / "gmail.png").exists(), "Logo auf der Platte")
    raises(NotFound, c.logo_png, "kaputt")
    raises(NotFound, c.logo_png, "../x")
    ok(True, "kein Bild / ungültiger Slug → NotFound")

    print("HTTP-Endpunkte")
    server.connections = c
    paths = {("GET", "/api/connections/catalog"), ("GET", "/api/connections/categories"),
             ("GET", "/api/connections/catalog/{app_slug}"), ("POST", "/api/connections/{app_slug}/connect"),
             ("GET", "/api/connections/logo/{app_slug}")}
    found = {}
    for route in server.app.routes:
        for m in getattr(route, "methods", None) or []:
            if (m, getattr(route, "path", "")) in paths:
                found[(m, route.path)] = [d.call for d in route.dependant.dependencies]
    ok(set(found) == paths, "neue Endpunkte vorhanden")
    ok(all(server.auth in deps for deps in found.values()), "alle nur für den Inhaber (`auth`, Gäste → 403)")
    api = TestClient(server.app)
    h = {"Authorization": f"Bearer {server.TOKEN}"}
    ok(api.get("/api/connections/catalog").status_code == 401, "ohne Token → 401")
    server.principal_of = lambda given: server.Principal("guest", "u_guest", None) if given == "gast" else server.OWNER \
        if given == server.TOKEN else None
    for m, p in [("GET", "/api/connections/catalog"), ("GET", "/api/connections/categories"),
                 ("GET", "/api/connections/catalog/tavily"), ("POST", "/api/connections/tavily/connect"),
                 ("GET", "/api/connections/logo/gmail")]:
        ok(api.request(m, p, headers={"Authorization": "Bearer gast"}, json={}).status_code == 403, f"Gast → 403 auf {m} {p}")
    r = api.get("/api/connections/catalog", params={"category": "popular"}, headers=h)
    ok(r.status_code == 200 and [i["slug"] for i in r.json()["items"]] == ["gmail", "notion"], "GET /catalog?category=popular")
    r = api.get("/api/connections/catalog", params={"q": "tav"}, headers=h)
    ok(r.json()["items"][0]["slug"] == "tavily" and r.json()["items"][0]["connected"] == 10, "GET /catalog?q=")
    ok(api.get("/api/connections/categories", headers=h).json()["categories"][0]["id"] == "popular", "GET /categories")
    ok(api.get("/api/connections/catalog/freshdesk", headers=h).json()["fields"][0]["name"] == "subdomain", "GET /catalog/{slug}")
    ok(api.get("/api/connections/catalog/gibtsnicht", headers=h).status_code == 404, "unbekannte App → 404")
    r = api.post("/api/connections/twitter/connect", headers=h, json={"fields": {}})
    ok(r.status_code == 422 and "keine fertige Anmeldung" in r.json()["error"], "nicht verbindbar → 422 mit Text")
    r = api.get("/api/connections/logo/notion", headers=h)
    ok(r.status_code == 200 and r.headers["content-type"] == "image/png" and r.content[:4] == b"\x89PNG", "GET /logo/{slug} → PNG")
    r = api.post("/api/connections/snowflake/link", headers=h, json={})
    ok(r.status_code == 422, "Link ohne verwaltete Anmeldung → 422")
    r = api.post("/api/connections/freshdesk/connect", headers=h, json={"alias": "web", "fields": {"subdomain": "a", "generic_api_key": SECRET}})
    ok(r.status_code == 200 and SECRET not in r.text, "POST /connect → Konto, Antwort ohne Schlüssel")
    r = api.post("/api/connections/freshdesk/connect", headers=h,
                 json={"alias": "liste", "fields": [{"name": "subdomain", "value": "b"}, {"name": "generic_api_key", "value": SECRET}]})
    ok(r.status_code == 200 and [b for m, p, b in fake.calls if m == "POST" and p == "/v3.1/connected_accounts"][-1]["connection"]["state"]["val"]["subdomain"] == "b", "Felder auch als Liste {name, value}")
    r = api.post("/api/connections/tavily/connect", headers=h, json={"alias": "zwölf", "fields": {"generic_api_key": SECRET}})
    ok(r.status_code == 409 and "Höchstens" in r.text, "POST /connect über der Grenze → 409")

    logging.getLogger().removeHandler(handler)
    ok(SECRET not in log.getvalue(), "Schlüssel taucht in keinem Log auf")
    print(f"\n{passed} Prüfungen bestanden")


if __name__ == "__main__":
    main()
