"""Test für „Notion direkt“ (offizieller Notion-MCP, OAuth pro Server, Server 1.25, notion_mcp.py).

Notion ist komplett gemockt (httpx.MockTransport), der Schlüsselbund durch einen Speicher im Arbeitsspeicher ersetzt.
Eigener Temp-Ordner und Schlüsselbund-Präfix, nie die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_notion_mcp.py
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

TMP = Path(tempfile.mkdtemp(prefix="aisbot-notion-test-"))
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-notiontest-" + os.urandom(3).hex(),
                  AISBOT_COMPUTER_URL="http://127.0.0.1:9")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from aisbot import notion_mcp as nm, server  # noqa: E402
from aisbot.connections import Connections  # noqa: E402
from aisbot.mcp_client import MCPHub, MCPServer  # noqa: E402
from aisbot.sharing import ScopedMCP  # noqa: E402

assert str(server.db.path).startswith(str(TMP)), "Test darf nie die echte Datenbank benutzen"
passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


class DictStore:
    def __init__(self) -> None:
        self.data: dict = {}
        self.writes = 0

    def get(self) -> dict:
        return json.loads(json.dumps(self.data))

    def set(self, data: dict) -> None:
        self.data = json.loads(json.dumps(data))
        self.writes += 1

    def delete(self) -> None:
        self.data = {}


class FakeNotion:
    """mcp.notion.com: Metadaten, offene Registrierung, Token-Tausch mit PKCE, rotierende Refresh-Tokens, MCP."""

    def __init__(self) -> None:
        self.registrations: list[dict] = []
        self.codes: dict[str, dict] = {}
        self.refresh: dict[str, str] = {}  # gültige Refresh-Tokens → client_id
        self.access: set[str] = set()
        self.token_calls: list[dict] = []
        self.revoked: list[str] = []
        self.mcp_auth: list[str] = []
        self.n = 0

    def issue(self, client_id: str, first: bool) -> dict:
        self.n += 1
        at, rt = f"at-{self.n}", f"rt-{self.n}"
        self.access.add(at)
        self.refresh[rt] = client_id
        out = {"access_token": at, "refresh_token": rt, "expires_in": 28800, "token_type": "bearer"}
        if first:
            out |= {"workspace_name": "Armans Workspace", "workspace_id": "ws1"}
        return out

    def handler(self, req: httpx.Request) -> httpx.Response:
        p = req.url.path
        if p == "/.well-known/oauth-authorization-server":
            return httpx.Response(200, json={"issuer": nm.ISSUER, "authorization_endpoint": nm.ISSUER + "/authorize",
                                             "token_endpoint": nm.ISSUER + "/token", "registration_endpoint": nm.ISSUER + "/register",
                                             "revocation_endpoint": nm.ISSUER + "/token", "code_challenge_methods_supported": ["S256"]})
        if p == "/register":
            body = json.loads(req.content)
            self.registrations.append(body)
            if any(not (u.startswith("https://") or u.startswith("aisscoops://") or u.startswith("http://127.0.0.1"))
                   for u in body["redirect_uris"]):
                return httpx.Response(400, json={"error": "invalid_redirect_uri"})
            return httpx.Response(201, json={"client_id": f"client-{len(self.registrations)}", **body})
        if p == "/token":
            form = {k: v[0] for k, v in parse_qs(req.content.decode()).items()}
            self.token_calls.append(form)
            if "token" in form:  # Widerruf
                self.revoked.append(form["token"])
                return httpx.Response(200, json={})
            if form.get("grant_type") == "authorization_code":
                c = self.codes.pop(form.get("code", ""), None)
                challenge = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).rstrip(b"=").decode()
                if not c or c["challenge"] != challenge or c["redirect_uri"] != form.get("redirect_uri") \
                        or c["client_id"] != form.get("client_id") or form.get("resource") != nm.RESOURCE:
                    return httpx.Response(400, json={"error": "invalid_grant", "error_description": "bad code"})
                return httpx.Response(200, json=self.issue(form["client_id"], True))
            if form.get("grant_type") == "refresh_token":
                cid = self.refresh.pop(form.get("refresh_token", ""), None)  # Rotation: altes Token verbraucht
                if not cid or cid != form.get("client_id"):
                    return httpx.Response(400, json={"error": "invalid_grant", "error_description": "revoked"})
                return httpx.Response(200, json=self.issue(cid, False))
        if p == "/mcp":
            auth = req.headers.get("authorization", "")
            self.mcp_auth.append(auth)
            if auth.removeprefix("Bearer ") not in self.access:
                return httpx.Response(401, json={"error": "invalid_token"})
            body = json.loads(req.content)
            if body.get("method") == "tools/list":
                return httpx.Response(200, json={"jsonrpc": "2.0", "id": body["id"], "result": {"tools": [
                    {"name": "notion-search", "inputSchema": {"type": "object"}}]}})
            return httpx.Response(200, json={"jsonrpc": "2.0", "id": body.get("id"), "result": {}})
        return httpx.Response(404, json={"error": "not_found"})

    def authorize(self, url: str) -> str:
        """Simuliert die Anmeldung im Browser → Rücksprung-Adresse."""
        q = {k: v[0] for k, v in parse_qs(urlparse(url).query).items()}
        code = f"code-{len(self.codes) + 1}-{os.urandom(2).hex()}"
        self.codes[code] = {"challenge": q["code_challenge"], "redirect_uri": q["redirect_uri"], "client_id": q["client_id"]}
        return f"{q['redirect_uri']}?code={code}&state={q['state']}"


def make() -> tuple[nm.NotionMCP, FakeNotion, DictStore]:
    fake, store = FakeNotion(), DictStore()
    n = nm.NotionMCP(store=store, http=httpx.Client(transport=httpx.MockTransport(fake.handler)))
    return n, fake, store


def test_oauth() -> None:
    print("Anmeldung (DCR, PKCE, Redirect aisscoops://)")
    n, fake, store = make()
    ok(not n.connected() and n.account() is None and n.mcp_spec() is None, "anfangs nicht verbunden")
    link = n.start()
    q = {k: v[0] for k, v in parse_qs(urlparse(link["url"]).query).items()}
    ok(link["url"].startswith(nm.ISSUER + "/authorize?") and link["callback_scheme"] == "aisscoops"
       and link["account_id"] == nm.ACCOUNT_ID, "Anmelde-Link mit Rücksprung-Schema der App")
    ok(q["redirect_uri"] == "aisscoops://oauth/notion" and q["code_challenge_method"] == "S256"
       and q["resource"] == nm.RESOURCE and len(q["state"]) >= 20, "PKCE S256, state, resource")
    reg = fake.registrations[0]
    ok(reg["token_endpoint_auth_method"] == "none" and reg["redirect_uris"] == ["aisscoops://oauth/notion"],
       "öffentliche Registrierung ohne Geheimnis")
    acc = n.finish(fake.authorize(link["url"]))
    ok(acc["status"] == "active" and acc["email"] == "Armans Workspace" and n.connected(), "verbunden mit Workspace-Name")
    ok(store.data["refresh_token"] == "rt-1" and store.data["client_id"] == "client-1", "Tokens im (Schlüsselbund-)Speicher")
    spec = n.mcp_spec()
    ok(spec["name"] == "notion" and spec["url"] == nm.MCP_URL and callable(spec["authorization_token"]),
       "MCP-Server `notion` mit Token-Funktion")
    n.start()
    ok(len(fake.registrations) == 1, "Registrierung wird wiederverwendet (keine verwaisten Anmeldungen)")

    for bad, msg in ((link["url"], "fremder Link"), ("aisscoops://oauth/notion?code=x&state=falsch", "unbekannter state"),
                     ("aisscoops://oauth/notion?error=access_denied&state=x", "abgebrochen")):
        try:
            n.finish(bad)
            ok(False, msg)
        except ValueError as e:
            ok(True, f"{msg} → {e}")
    l2 = n.start()
    back = fake.authorize(l2["url"])
    n.finish(back)
    try:
        n.finish(back)
        ok(False, "state doppelt")
    except ValueError:
        ok(True, "derselbe Rücksprung gilt nur einmal")


def test_refresh() -> None:
    print("Automatisch erneuern (rotierend), Ablauf")
    n, fake, store = make()
    n.finish(fake.authorize(n.start()["url"]))
    ok(n.access_token() == "at-1" and len(fake.token_calls) == 1, "gültiges Token ohne Netzabruf")
    store.data["expires_at"] = time.time() + 60
    n._cache = None  # noqa: SLF001
    ok(n.access_token() == "at-2" and store.data["refresh_token"] == "rt-2", "kurz vor Ablauf erneuert, neues Refresh-Token gesichert")
    ok(fake.token_calls[-1]["resource"] == nm.RESOURCE and fake.token_calls[-1]["client_id"] == "client-1", "Refresh mit resource und client_id")
    ok(n.access_token(force_refresh=True) == "at-3", "erzwungen erneuert (nach 401)")
    fake.refresh.clear()  # Notion hat die Anmeldung widerrufen
    changed = []
    n.on_change = lambda: changed.append(1)
    try:
        n.access_token(force_refresh=True)
        ok(False, "invalid_grant muss scheitern")
    except nm.NotionAuthError as e:
        ok("neu anmelden" in str(e), "invalid_grant → klare Meldung")
    time.sleep(0.05)
    ok(n.account()["status"] == "expired" and not n.connected() and n.mcp_spec() is None and changed,
       "abgelaufen: Konto zeigt „expired“, Hub ohne Notion direkt")
    calls = len(fake.token_calls)
    try:
        n.access_token()
    except nm.NotionAuthError:
        pass
    ok(len(fake.token_calls) == calls, "kein erneuter Versuch mit dem toten Token")
    n.finish(fake.authorize(n.start()["url"]))
    ok(n.connected() and n.account()["status"] == "active", "neu anmelden klappt")


def test_disconnect() -> None:
    print("Trennen")
    n, fake, store = make()
    n.finish(fake.authorize(n.start()["url"]))
    n.rename("Firma")
    ok(n.account()["alias"] == "Firma", "umbenennen")
    n.disconnect()
    ok(fake.revoked == ["rt-1"] and not n.connected() and n.account() is None, "widerrufen und gelöscht")
    ok(store.data == {"client_id": "client-1", "redirect_uri": nm.REDIRECT_URI}, "Registrierung bleibt")


def test_mcp_token() -> None:
    print("MCP-Aufrufe mit erneuerbarem Token")
    n, fake, store = make()
    n.finish(fake.authorize(n.start()["url"]))
    srv = MCPServer("notion", nm.MCP_URL, n.access_token)
    srv.http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    ok([t["name"] for t in srv.tools()] == ["notion-search"], "Werkzeugliste mit Bearer-Token")
    fake.access.clear()  # Token serverseitig ungültig
    srv._tools_at = 0  # noqa: SLF001
    ok(srv.tools() and fake.mcp_auth[-1] == "Bearer at-2", "401 → einmal erneuert und wiederholt")


def test_hub_and_sharing() -> None:
    print("Composio-Notion ausblenden, Gäste")

    class Srv:
        def __init__(self, tools) -> None:
            self._tools = tools
            self.calls = []

        def call(self, tool, args):
            self.calls.append((tool, args))
            return "OK"

        def tools(self):
            return self._tools

    hub = MCPHub()
    comp = Srv([])
    hub.servers["composio"] = comp
    args = {"tools": [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {}}]}
    ok(hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", args) == "OK", "ohne Notion direkt: Composio-Notion wie bisher")
    hub.servers["notion"] = Srv([{"name": "notion-search"}])
    try:
        hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", args)
        ok(False, "Composio-Notion muss umgeleitet werden")
    except RuntimeError as e:
        ok("notion__notion-search" in str(e), "mit Notion direkt: Composio-Notion verweist auf notion__…")
    hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL",
             {"tools": [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {}, "account": "zweiter-workspace"}]})
    ok(len(comp.calls) == 2, "ausdrücklich gewähltes Composio-Konto bleibt möglich")
    hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", {"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {}}]})
    ok(len(comp.calls) == 3, "andere Apps unberührt")
    hub.servers["notion"] = Srv([])
    hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", args)
    ok(len(comp.calls) == 4, "Notion direkt ohne Werkzeuge (gestört): Composio-Notion als Rückfall")
    scoped = ScopedMCP(hub, [], ["notion"])
    ok("notion" in scoped.servers, "Gast mit Notion-Freigabe darf auch Notion direkt")
    ok("notion" not in ScopedMCP(hub, [], ["gmail"]).servers, "Gast ohne Notion-Freigabe nicht")


def test_connections_and_api() -> None:
    print("„Apps verbinden“ und API")
    n, fake, store = make()
    nm._instance = n  # noqa: SLF001
    c = Connections(lambda: {})
    c._cache = (time.time(), [])  # noqa: SLF001 – keine Composio-Konten
    c.extra_accounts = lambda: [a for a in [n.account()] if a]
    c.extra_prompt = lambda: nm.PROMPT_HINT if n.connected() else None
    ok(c.overview([])["apps"][3]["accounts"] == [] and c.prompt_block() is None, "anfangs kein Notion-Konto")
    server.connections = c
    old_offline, old_specs = server.OFFLINE, server.mcp_servers
    server.OFFLINE = False
    server.mcp_servers = lambda: []  # keine echten MCP-Verbindungen im Test
    try:
        api = TestClient(server.app)
        h = {"Authorization": f"Bearer {server.TOKEN}"}
        r = api.post("/api/connections/notion/link", headers=h, json={"native": True})
        ok(r.status_code == 200 and r.json()["callback_scheme"] == "aisscoops", "neue App: Notion-Link direkt")
        url = r.json()["url"]
        r = api.post("/api/connections/oauth/callback", headers=h, json={"url": fake.authorize(url)})
        ok(r.status_code == 200 and r.json()["status"] == "active", "Rücksprung → verbunden")
        r = api.post("/api/connections/oauth/callback", headers=h, json={"url": "aisscoops://oauth/notion?code=x&state=y"})
        ok(r.status_code == 409, "falscher Rücksprung → 409 mit Text")
        notion = next(a for a in c.overview([])["apps"] if a["slug"] == "notion")
        ok([a["id"] for a in notion["accounts"]] == ["notion-mcp"], "Notion direkt erscheint als Konto der App Notion")
        ok(nm.PROMPT_HINT in (c.prompt_block() or ""), "Hinweis in der Systemanweisung")
        ok(api.get("/api/connections/accounts/notion-mcp", headers=h).json()["status"] == "active", "Status abfragbar")
        ok(api.patch("/api/connections/accounts/notion-mcp", headers=h, json={"alias": "Büro"}).json()["alias"] == "Büro",
           "umbenennen")
        ok(api.post("/api/connections/accounts/notion-mcp/reconnect", headers=h).json()["callback_scheme"] == "aisscoops",
           "neu anmelden liefert wieder den direkten Link")
        ok(api.delete("/api/connections/accounts/notion-mcp", headers=h).status_code == 200 and not n.connected(),
           "trennen")
        ok(api.post("/api/connections/oauth/callback", headers={"Authorization": "Bearer gast"}, json={}).status_code in (401, 403),
           "Rücksprung nur für den Inhaber")
    finally:
        server.OFFLINE, server.mcp_servers = old_offline, old_specs


def main() -> None:
    test_oauth()
    test_refresh()
    test_disconnect()
    test_mcp_token()
    test_hub_and_sharing()
    test_connections_and_api()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
