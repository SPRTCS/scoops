"""Fake-MCP-Server für Tests und den Probedurchlauf (eigene MCP-Server, custom_mcp.py, ab Server 1.35).

Ein lokaler HTTP-Server mit drei MCP-Endpunkten (Streamable HTTP, JSON-Antworten):

- `/open/mcp`  ohne Anmeldung
- `/token/mcp` mit festem Token (`Authorization: Bearer …` oder `X-Api-Key: …`)
- `/oauth/mcp` mit OAuth 2.1 wie Qonto/Notion: 401 mit `resource_metadata`, Protected-Resource-Metadaten, Authorization
  Server unter `/as` (RFC-8414-Pfad), offene Registrierung, PKCE S256, rotierende Refresh-Tokens, Widerruf.

Werkzeuge: `list_items` (readOnlyHint), `create_item` (schreibend), `make.transfer` (schreibend, Name mit Punkt).
Läuft nur auf 127.0.0.1 und kennt keine echten Daten.
"""



import base64
import hashlib
import secrets
import socket
import threading
import time
from urllib.parse import parse_qs, urlencode, urlparse

TOKEN = "fake-geheim-" + secrets.token_hex(4)
TOOLS = [
    {"name": "list_items", "description": "Listet die Einträge (nur lesen).", "annotations": {"readOnlyHint": True},
     "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}}},
    {"name": "create_item", "description": "Legt einen Eintrag an.",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]}},
    {"name": "make.transfer", "description": "Überweist Geld an ein Konto.", "annotations": {"destructiveHint": True},
     "inputSchema": {"type": "object", "properties": {"amount": {"type": "number"}}}},
]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeMCP:
    def __init__(self) -> None:
        self.port = _free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.calls: list[tuple[str, str, dict]] = []  # (Modus, Werkzeug, Argumente)
        self.registrations: list[dict] = []
        self.codes: dict[str, dict] = {}
        self.access: set[str] = set()
        self.refresh: dict[str, str] = {}
        self.revoked: list[str] = []
        self.token_calls: list[dict] = []
        self.loopback_only = False  # wie Qonto: nur Loopback-Redirects bei der Registrierung
        self.n = 0

    # -- Hilfen für Tests --------------------------------------------------------------------------------------------
    def url(self, mode: str) -> str:
        return f"{self.base}/{mode}/mcp"

    def authorize(self, url: str) -> str:
        """Simuliert die Anmeldung im Browser: Authorize-URL → Rücksprung-URL mit Code."""
        q = {k: v[0] for k, v in parse_qs(urlparse(url).query).items()}
        assert q["code_challenge_method"] == "S256" and q["response_type"] == "code"
        code = "code-" + secrets.token_hex(6)
        self.codes[code] = q
        return f"{q['redirect_uri']}?{urlencode({'code': code, 'state': q['state']})}"

    def expire_access(self) -> None:
        self.access.clear()

    # -- App --------------------------------------------------------------------------------------------------------
    def app(self):
        from fastapi import FastAPI, Request
        from fastapi.responses import JSONResponse, Response

        app = FastAPI()
        fake = self

        @app.get("/.well-known/oauth-protected-resource/oauth/mcp")
        def prm():
            return {"resource": fake.url("oauth"), "authorization_servers": [fake.base + "/as"],
                    "scopes_supported": ["items.read", "offline_access"], "resource_name": "Fake Bank MCP"}

        @app.get("/.well-known/oauth-authorization-server/as")
        def asm():
            b = fake.base + "/as"
            return {"issuer": b, "authorization_endpoint": b + "/authorize", "token_endpoint": b + "/token",
                    "registration_endpoint": b + "/register", "revocation_endpoint": b + "/revoke",
                    "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"],
                    "scopes_supported": ["items.read", "offline_access"]}

        @app.post("/as/register")
        async def register(request: Request):
            body = await request.json()
            if fake.loopback_only and not all(u.startswith("http://127.0.0.1:") for u in body.get("redirect_uris") or []):
                return JSONResponse({"error": "invalid_redirect_uri",
                                     "error_description": "this redirect_uri is not allowed"}, status_code=400)
            fake.registrations.append(body)
            return JSONResponse({"client_id": f"client-{len(fake.registrations)}", **body}, status_code=201)

        def issue() -> dict:
            fake.n += 1
            at, rt = f"at-{fake.n}-{secrets.token_hex(3)}", f"rt-{fake.n}-{secrets.token_hex(3)}"
            fake.access.add(at)
            return {"access_token": at, "refresh_token": rt, "expires_in": 3600, "token_type": "bearer"}

        @app.post("/as/token")
        async def token(request: Request):
            form = {k: v for k, v in (await request.form()).items()}
            fake.token_calls.append(form)
            if form.get("grant_type") == "authorization_code":
                q = fake.codes.pop(form.get("code", ""), None)
                verifier = form.get("code_verifier", "")
                chal = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                if (not q or q["code_challenge"] != chal or q["redirect_uri"] != form.get("redirect_uri")
                        or q["client_id"] != form.get("client_id") or form.get("resource") != fake.url("oauth")):
                    return JSONResponse({"error": "invalid_grant"}, status_code=400)
                tok = issue()
                fake.refresh[tok["refresh_token"]] = form["client_id"]
                return tok
            if form.get("grant_type") == "refresh_token":
                cid = fake.refresh.pop(form.get("refresh_token", ""), None)
                if not cid or cid != form.get("client_id"):
                    return JSONResponse({"error": "invalid_grant", "error_description": "abgelaufen"}, status_code=400)
                tok = issue()
                fake.refresh[tok["refresh_token"]] = cid
                return tok
            return JSONResponse({"error": "unsupported_grant_type"}, status_code=400)

        @app.post("/as/revoke")
        async def revoke(request: Request):
            form = await request.form()
            fake.revoked.append(str(form.get("token")))
            fake.refresh.pop(str(form.get("token")), None)
            return Response(status_code=200)

        @app.post("/{mode}/mcp")
        async def mcp(mode: str, request: Request):
            auth = request.headers.get("authorization") or ""
            if mode == "token" and auth != f"Bearer {TOKEN}" and request.headers.get("x-api-key") != TOKEN:
                return Response("no token", status_code=401)
            if mode == "oauth" and auth[7:] not in fake.access:
                meta = f'{fake.base}/.well-known/oauth-protected-resource/oauth/mcp'
                return Response("no bearer token", status_code=401,
                                headers={"WWW-Authenticate": f'Bearer resource_metadata="{meta}"'})
            if mode not in ("open", "token", "oauth"):
                return Response(status_code=404)
            msg = await request.json()
            mid, method = msg.get("id"), msg.get("method")
            if mid is None:
                return Response(status_code=202)
            if method == "initialize":
                return JSONResponse({"jsonrpc": "2.0", "id": mid, "result": {
                    "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                    "serverInfo": {"name": f"fake-{mode}", "version": "1"}}}, headers={"Mcp-Session-Id": "s-" + mode})
            if method == "tools/list":
                return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
            if method == "tools/call":
                p = msg.get("params") or {}
                fake.calls.append((mode, p.get("name"), p.get("arguments") or {}))
                if p.get("name") == "list_items":
                    text = "Einträge: Apfel, Birne, Kirsche"
                else:
                    text = f"{p.get('name')} ausgeführt: {p.get('arguments')}"
                return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}}
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unbekannt"}}

        return app

    def start(self) -> "FakeMCP":
        import httpx
        import uvicorn
        srv = uvicorn.Server(uvicorn.Config(self.app(), host="127.0.0.1", port=self.port, log_level="warning"))
        threading.Thread(target=srv.run, daemon=True).start()
        end = time.time() + 10
        while time.time() < end:
            try:
                httpx.get(self.base + "/.well-known/oauth-authorization-server/as", timeout=1)
                return self
            except httpx.HTTPError:
                time.sleep(0.05)
        raise RuntimeError("Fake-MCP startet nicht")


STDIO_SCRIPT = r'''
import json, os, sys
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if "id" not in m:
        continue
    if m.get("method") == "initialize":
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-stdio"}}
    elif m.get("method") == "tools/list":
        r = {"tools": [{"name": "env_lesen", "description": "Liest FAKE_KEY", "annotations": {"readOnlyHint": True},
                        "inputSchema": {"type": "object", "properties": {}}}]}
    elif m.get("method") == "tools/call":
        r = {"content": [{"type": "text", "text": "FAKE_KEY gesetzt" if os.environ.get("FAKE_KEY") else "FAKE_KEY fehlt"}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\n")
    sys.stdout.flush()
'''


class DictStore:
    """Schlüsselbund-Ersatz im Speicher (pro Server-ID ein Eintrag)."""

    data: dict[str, dict] = {}

    def __init__(self, sid: str) -> None:
        self.sid = sid

    def get(self) -> dict:
        import json
        return json.loads(json.dumps(self.data.get(self.sid) or {}))

    def set(self, data: dict) -> None:
        import json
        self.data[self.sid] = json.loads(json.dumps(data))

    def delete(self) -> None:
        self.data.pop(self.sid, None)
