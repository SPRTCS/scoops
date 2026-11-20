"""Eigene MCP-Server (ab Server 1.35, docs/mcp.md).

Jeder Nutzer kann in „Apps verbinden“ eigene MCP-Server hinzufügen, so wie Atrium oder die Team App fest eingebaut sind:

- **Remote (Streamable HTTP)** ohne Anmeldung, mit festem Token (Bearer oder eigener Header) oder mit **OAuth 2.1**
  (Discovery über 401 / `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`, Dynamic
  Client Registration einmal pro Server, PKCE S256, Rücksprung `aisscoops://oauth/mcp`, Refresh 5 Minuten vor Ablauf).
  Vorbild ist `notion_mcp.py`; Notion selbst bleibt dort unverändert.
- **Lokal (stdio)**: Befehl, Argumente, Umgebungsvariablen (wie `Atrium --mcp`). Nur der Inhaber legt sie an (API `auth`).

Speicher: Die Liste (ID, Name, Art, URL bzw. Befehl, Auth-Art, Namen der Umgebungsvariablen) steht in `config.json`
unter `custom_mcp`, **ohne Geheimnisse**. Tokens, Umgebungswerte, OAuth-Registrierung und Refresh-Tokens liegen nur im
Schlüsselbund, ein Eintrag pro Server (Dienst `<prefix>-mcp-<id>`, Konto `secret`, JSON als Base64).

Werkzeugnamen im Hub: `<id>__<werkzeug>`; IDs beginnen immer mit `mcp_` (z. B. `mcp_qonto`), damit nichts mit
composio/notion/teamapp/atrium kollidiert.

Sicherheit: Schreibende Werkzeuge (alles ohne `readOnlyHint: true`) laufen über Freigabe-Karten (`ApprovalGate`).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

from .i18n import tx
from .profile import kc

CALLBACK_SCHEME = "aisscoops"
REDIRECT_URI = "aisscoops://oauth/mcp"
# Rückfall, wenn der Anbieter eigene Schemata bei der Registrierung ablehnt (Qonto: Allowlist, Loopback erlaubt). Die App
# hört während der Anmeldung kurz auf diesem Port (nur 127.0.0.1) und reicht den Rücksprung weiter (RFC 8252 §7.3).
LOOPBACK_PORT = 47615
LOOPBACK_URI = f"http://127.0.0.1:{LOOPBACK_PORT}/oauth/mcp"
CLIENT_NAME = "AIS Scoops"
PENDING_TTL = 15 * 60
REFRESH_EARLY = 5 * 60
KEYCHAIN_ACCOUNT = "secret"
ID_PREFIX = "mcp_"
MAX_SERVERS = 20
AUTHS = ("none", "token", "oauth")
KINDS = ("remote", "stdio")
PROTOCOL = "2025-06-18"
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
HEADER_NAME = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# Geldbewegungen, Karten u. Ä. sind nie dauerhaft erlaubbar (ergänzt bots._NEVER_ALWAYS um englische Werkzeugnamen).
NEVER_ALWAYS_TOOL = re.compile(r"transfer|payout|payment|beneficiar|\bcards?\b|_cards?\b|\bcards?_|iban|sepa|"
                               r"direct_debit|invoice.*pay|pay_|_pay\b|delete_account|password|secret", re.IGNORECASE)


class McpAuthError(RuntimeError):
    """Anmeldung beim MCP-Server fehlgeschlagen oder abgelaufen."""

    code = ""


# -- Schlüsselbund ------------------------------------------------------------------------------------------------------
class KeychainStore:
    """Ein JSON-Eintrag pro Server im Schlüsselbund (wie notion_mcp.KeychainStore: `security -i` über stdin, Base64)."""

    def __init__(self, server_id: str) -> None:
        self.service = kc(f"mcp-{server_id}")
        self.account = KEYCHAIN_ACCOUNT

    def get(self) -> dict:
        r = subprocess.run(["security", "find-generic-password", "-s", self.service, "-a", self.account, "-w"],
                           capture_output=True, text=True)
        raw = r.stdout.strip() if r.returncode == 0 else ""
        if not raw:
            return {}
        try:
            return json.loads(base64.urlsafe_b64decode(raw.encode()).decode())
        except (ValueError, TypeError):
            return {}

    def set(self, data: dict) -> None:
        blob = base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).decode()
        cmd = f'add-generic-password -U -s "{self.service}" -a "{self.account}" -w "{blob}"\n'
        r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True)
        if r.returncode != 0 or "error" in (r.stderr or "").lower():
            raise McpAuthError(tx("Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden."))

    def delete(self) -> None:
        subprocess.run(["security", "delete-generic-password", "-s", self.service, "-a", self.account],
                       capture_output=True)


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _err_text(r: httpx.Response) -> tuple[str, str]:
    try:
        d = r.json()
        return str(d.get("error") or ""), str(d.get("error_description") or d.get("message") or "")[:300]
    except ValueError:
        return "", r.text[:300]


def _origin(url: str) -> str:
    u = urlparse(url)
    return f"{u.scheme}://{u.netloc}"


def _www_auth_param(header: str, key: str) -> str:
    m = re.search(rf'{key}="([^"]*)"', header or "") or re.search(rf"{key}=([^\s,]+)", header or "")
    return m.group(1) if m else ""


def slug(name: str) -> str:
    t = (name or "").strip().lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    t = re.sub(r"[^a-z0-9]+", "_", t).strip("_")[:20].strip("_")
    return t or "server"


def check_url(url: str) -> str:
    url = (url or "").strip()
    u = urlparse(url)
    if u.scheme not in ("https", "http") or not u.netloc:
        raise ValueError(tx("Bitte eine vollständige Adresse eingeben, z. B. https://mcp.example.com/mcp"))
    if u.scheme == "http" and u.hostname not in ("127.0.0.1", "localhost", "::1") and not (u.hostname or "").endswith(".local"):
        raise ValueError(tx("Bitte https:// verwenden (http nur für localhost oder .local)."))
    return url


# -- Erkennen: braucht der Server eine Anmeldung? --------------------------------------------------------------------------
def detect(url: str, http: httpx.Client) -> dict:
    """POST initialize ohne Token. Ergebnis: {auth: none|token|oauth, resource_metadata?, scope?, detail}."""
    body = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": PROTOCOL, "capabilities": {}, "clientInfo": {"name": "ais-scoops", "version": "1"}}}
    try:
        r = http.post(url, json=body, headers={"Content-Type": "application/json",
                                               "Accept": "application/json, text/event-stream",
                                               "MCP-Protocol-Version": PROTOCOL})
    except httpx.HTTPError as e:
        raise ValueError(tx("Der Server ist nicht erreichbar: {error}", error=str(e)[:160])) from None
    if r.status_code < 400:
        return {"auth": "none", "detail": tx("Keine Anmeldung nötig")}
    if r.status_code in (401, 403):
        www = r.headers.get("www-authenticate") or ""
        meta_url = _www_auth_param(www, "resource_metadata")
        scope = _www_auth_param(www, "scope")
        prm = _fetch_prm(url, meta_url, http)
        if prm is not None:
            return {"auth": "oauth", "resource_metadata": meta_url, "scope": scope, "prm": prm,
                    "detail": tx("Anmeldung über den Anbieter (OAuth)")}
        try:
            _as_metadata(_origin(url), http)
            return {"auth": "oauth", "scope": scope, "prm": {}, "detail": tx("Anmeldung über den Anbieter (OAuth)")}
        except McpAuthError:
            return {"auth": "token", "detail": tx("Der Server verlangt ein Token")}
    if r.status_code == 404:
        raise ValueError(tx("Unter dieser Adresse antwortet kein MCP-Server (HTTP 404). Endet sie auf /mcp?"))
    if r.status_code == 405:
        raise ValueError(tx("Der Server nimmt keine MCP-Anfragen an (HTTP 405). Nur Streamable HTTP wird unterstützt."))
    raise ValueError(tx("Der Server antwortet mit HTTP {status}.", status=r.status_code))


def _fetch_prm(url: str, meta_url: str, http: httpx.Client) -> dict | None:
    """Protected-Resource-Metadaten (RFC 9728): aus dem 401-Header, sonst die üblichen Pfade."""
    u = urlparse(url)
    cands = [meta_url] if meta_url else []
    path = u.path.rstrip("/")
    if path:
        cands.append(f"{_origin(url)}/.well-known/oauth-protected-resource{path}")
    cands.append(f"{_origin(url)}/.well-known/oauth-protected-resource")
    for c in cands:
        try:
            r = http.get(c, headers={"Accept": "application/json"})
            if r.status_code == 200:
                d = r.json()
                if isinstance(d, dict) and (d.get("authorization_servers") or d.get("resource")):
                    return d
        except (httpx.HTTPError, ValueError):
            continue
    return None


def _as_metadata(issuer: str, http: httpx.Client) -> dict:
    """Authorization-Server-Metadaten (RFC 8414, mit Pfad-Einfügung), sonst OpenID-Konfiguration."""
    u = urlparse(issuer)
    base, path = _origin(issuer), u.path.rstrip("/")
    cands = []
    if path:
        cands += [f"{base}/.well-known/oauth-authorization-server{path}", f"{base}/.well-known/openid-configuration{path}",
                  f"{issuer.rstrip('/')}/.well-known/openid-configuration"]
    cands += [f"{base}/.well-known/oauth-authorization-server", f"{base}/.well-known/openid-configuration"]
    for c in cands:
        try:
            r = http.get(c, headers={"Accept": "application/json"})
            if r.status_code == 200:
                d = r.json()
                if isinstance(d, dict) and d.get("authorization_endpoint") and d.get("token_endpoint"):
                    return d
        except (httpx.HTTPError, ValueError):
            continue
    raise McpAuthError(tx("Der Server nennt keinen Anmelde-Dienst (OAuth-Metadaten fehlen)."))


# -- Token-Funktion für den Hub ------------------------------------------------------------------------------------------
class TokenFn:
    """Liefert dem MCPServer bei jedem Aufruf ein gültiges Token (OAuth mit Refresh). Gleichheit über die Server-ID,
    damit MCPHub.configure den Server nicht bei jedem Neuladen neu anlegt (Werkzeugliste bleibt im Speicher)."""

    def __init__(self, mgr: "CustomMCP", sid: str) -> None:
        self.mgr, self.sid = mgr, sid

    def __call__(self, force_refresh: bool = False) -> str:
        return self.mgr.access_token(self.sid, force_refresh)

    def __eq__(self, other) -> bool:
        return isinstance(other, TokenFn) and other.mgr is self.mgr and other.sid == self.sid

    def __hash__(self) -> int:
        return hash(("TokenFn", self.sid))


# -- Verwaltung ----------------------------------------------------------------------------------------------------------
class CustomMCP:
    def __init__(self, load_config, save_config, store_factory=KeychainStore, http: httpx.Client | None = None) -> None:
        self.load_config, self.save_config = load_config, save_config
        self.store_factory = store_factory
        self.http = http or httpx.Client(timeout=20, follow_redirects=True)
        self._cache: dict[str, dict] = {}  # Kopien der Schlüsselbund-Einträge
        self._pending: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._refresh_locks: dict[str, threading.Lock] = {}
        self.on_change = None  # server.py: Hub neu konfigurieren (z. B. wenn eine Anmeldung abläuft)

    # -- Liste in config.json ---------------------------------------------------------------------------------------
    def entries(self) -> list[dict]:
        raw = self.load_config().get("custom_mcp")
        return [dict(e) for e in raw if isinstance(e, dict) and str(e.get("id", "")).startswith(ID_PREFIX)] \
            if isinstance(raw, list) else []

    def get(self, sid: str) -> dict:
        e = next((e for e in self.entries() if e["id"] == sid), None)
        if not e:
            raise KeyError(tx("Diesen MCP-Server gibt es nicht (mehr)."))
        return e

    def _write(self, entries: list[dict]) -> None:
        cfg = self.load_config()
        cfg["custom_mcp"] = entries
        self.save_config(cfg)

    def _update(self, sid: str, **fields) -> dict:
        entries = self.entries()
        for e in entries:
            if e["id"] == sid:
                e.update({k: v for k, v in fields.items() if v is not None})
                for k in [k for k, v in fields.items() if v is None]:
                    e.pop(k, None)
                self._write(entries)
                return e
        raise KeyError(tx("Diesen MCP-Server gibt es nicht (mehr)."))

    def ids(self) -> set[str]:
        return {e["id"] for e in self.entries()}

    def labels(self) -> dict[str, str]:
        return {e["id"]: e.get("name") or e["id"] for e in self.entries()}

    # -- Geheimnisse ------------------------------------------------------------------------------------------------
    def _secret(self, sid: str) -> dict:
        if sid not in self._cache:
            self._cache[sid] = self.store_factory(sid).get()
        return dict(self._cache[sid])

    def _save_secret(self, sid: str, data: dict) -> None:
        self.store_factory(sid).set(data)
        self._cache[sid] = dict(data)

    def _drop_secret(self, sid: str) -> None:
        self.store_factory(sid).delete()
        self._cache.pop(sid, None)

    # -- Hinzufügen -------------------------------------------------------------------------------------------------
    def probe(self, url: str) -> dict:
        """Nur erkennen, nichts speichern (App: Auth-Art vorschlagen)."""
        d = detect(check_url(url), self.http)
        return {"auth": d["auth"], "detail": d["detail"], "name": (d.get("prm") or {}).get("resource_name") or ""}

    def add(self, body: dict) -> dict:
        """Neuer Server. Gibt {server, oauth?} zurück; bei OAuth gleich den Anmelde-Link für die App."""
        kind = str(body.get("kind") or "remote")
        if kind not in KINDS:
            raise ValueError(tx("Art: remote oder stdio"))
        name = re.sub(r"\s+", " ", str(body.get("name") or "")).strip()[:40]
        entries = self.entries()
        if len(entries) >= MAX_SERVERS:
            raise ValueError(tx("Höchstens {max} eigene MCP-Server", max=MAX_SERVERS))
        entry: dict = {"kind": kind, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        secret: dict = {}
        detected = None
        if kind == "remote":
            url = check_url(str(body.get("url") or ""))
            auth = str(body.get("auth") or "auto")
            if auth not in AUTHS + ("auto",):
                raise ValueError(tx("Anmeldung: none, token, oauth oder auto"))
            token = str(body.get("token") or "").strip()
            if auth == "auto":
                detected = detect(url, self.http)
                auth = "token" if token and detected["auth"] != "none" else detected["auth"]
            if auth == "token":
                if not token:
                    raise ValueError(tx("Dieser Server verlangt ein Token. Bitte unter „Token“ eintragen."))
                header = str(body.get("header") or "Authorization").strip() or "Authorization"
                if not HEADER_NAME.match(header):
                    raise ValueError(tx("Ungültiger Header-Name"))
                entry["header"] = header
                secret["token"] = token
            if not name:
                name = ((detected or {}).get("prm") or {}).get("resource_name") or urlparse(url).hostname or "MCP"
                name = re.sub(r"\s*MCP$", "", name).strip()[:40] or "MCP"
            entry.update(url=url, auth=auth)
        else:
            cmd = body.get("command")
            if isinstance(cmd, str):
                cmd = cmd.strip()
                cmd = [cmd] if cmd else []
            args = body.get("args") or []
            if isinstance(args, str):
                import shlex
                args = shlex.split(args)
            if not cmd or not isinstance(cmd, list) or not all(isinstance(x, str) and x for x in cmd + list(args)):
                raise ValueError(tx("Bitte einen Befehl angeben, z. B. /Applications/Atrium.app/Contents/MacOS/Atrium"))
            prog = os.path.expanduser(cmd[0])
            if not (os.path.isabs(prog) and os.access(prog, os.X_OK)) and not shutil.which(prog):
                raise ValueError(tx("Programm nicht gefunden: {program}", program=cmd[0]))
            env = body.get("env") or {}
            if isinstance(env, list):  # App: [{key, value}] (der JSON-Encoder würde Dict-Schlüssel umschreiben)
                env = {str(x.get("key") or ""): str(x.get("value") or "") for x in env if isinstance(x, dict)}
            if not isinstance(env, dict) or not all(ENV_NAME.match(str(k)) for k in env):
                raise ValueError(tx("Umgebungsvariablen: Namen aus Buchstaben, Ziffern und _"))
            entry.update(command=[prog] + cmd[1:] + [str(a) for a in args], env_keys=sorted(str(k) for k in env),
                         auth="none")
            if env:
                secret["env"] = {str(k): str(v) for k, v in env.items()}
            name = name or os.path.basename(prog)[:40]
        base = ID_PREFIX + slug(name)
        sid, n = base, 2
        taken = {e["id"] for e in entries}
        while sid in taken:
            sid, n = f"{base}_{n}", n + 1
        entry = {"id": sid, "name": name, **entry}
        if secret:
            self._save_secret(sid, secret)
        else:
            self._drop_secret(sid)  # alte Reste eines gleichnamigen, früher entfernten Servers
        if entry.get("auth") == "oauth" and detected:
            self._cache_discovery(sid, entry["url"], detected)
        self._write(entries + [entry])
        out: dict = {"server": entry}
        if entry.get("auth") == "oauth":
            try:
                out["oauth"] = self.start(sid)
            except Exception as e:  # noqa: BLE001 – Server bleibt in der Liste, „Neu anmelden“ versucht es wieder
                out["error"] = str(e)[:300]
        return out

    def rename(self, sid: str, name: str) -> dict:
        name = re.sub(r"\s+", " ", name or "").strip()[:40]
        if not name:
            raise ValueError(tx("Bitte einen Namen eingeben."))
        return self._update(sid, name=name)

    def set_token(self, sid: str, token: str, header: str | None = None) -> dict:
        """Neues Token für einen Remote-Server (Auth-Art wird „token“). Der Wert geht nur in den Schlüsselbund."""
        e = self.get(sid)
        token = (token or "").strip()
        if e["kind"] != "remote":
            raise ValueError(tx("Nur Remote-Server haben ein Token."))
        if not token:
            raise ValueError(tx("Bitte ein Token eingeben."))
        header = (header or e.get("header") or "Authorization").strip()
        if not HEADER_NAME.match(header):
            raise ValueError(tx("Ungültiger Header-Name"))
        d = {} if e.get("auth") == "oauth" else self._secret(sid)
        d["token"] = token
        self._save_secret(sid, d)
        return self._update(sid, auth="token", header=header)

    def remove(self, sid: str) -> None:
        e = self.get(sid)
        if e.get("auth") == "oauth":
            self._revoke(sid)
        self._drop_secret(sid)
        self._write([x for x in self.entries() if x["id"] != sid])

    # -- Hub ------------------------------------------------------------------------------------------------------------
    def specs(self) -> list[dict]:
        out = []
        for e in self.entries():
            try:
                if e["kind"] == "stdio":
                    out.append({"type": "stdio", "name": e["id"], "label": e.get("name"), "command": list(e["command"]),
                                "env": dict(self._secret(e["id"]).get("env") or {})})
                    continue
                auth = e.get("auth")
                if auth == "oauth":
                    if not self.logged_in(e["id"]):
                        continue  # erst nach der Anmeldung in den Hub (Status „Anmeldung nötig“)
                    tok, header = TokenFn(self, e["id"]), "Authorization"
                elif auth == "token":
                    tok, header = self._secret(e["id"]).get("token") or "", e.get("header") or "Authorization"
                else:
                    tok, header = "", None
                out.append({"type": "url", "name": e["id"], "label": e.get("name"), "url": e["url"],
                            "authorization_token": tok, "header": header})
            except Exception as ex:  # noqa: BLE001
                print(f"Eigener MCP {e.get('id')}: {ex}", flush=True)
        return out

    def logged_in(self, sid: str) -> bool:
        d = self._secret(sid)
        return bool(d.get("refresh_token") or d.get("access_token")) and not d.get("expired")

    def status(self, hub) -> list[dict]:
        """Für „Apps verbinden“: Liste mit Status ok / error / login und Werkzeuganzahl. Ohne Geheimnisse."""
        out = []
        for e in self.entries():
            srv = hub.servers.get(e["id"]) if hub else None
            tools = list(getattr(srv, "_tools", []) or []) if srv else []
            if e.get("auth") == "oauth" and not self.logged_in(e["id"]):
                state, err = "login", (tx("Anmeldung abgelaufen") if self._secret(e["id"]).get("expired") else tx("Anmeldung nötig"))
            elif tools:
                state, err = "ok", None
            elif srv is None:
                state, err = "error", tx("Nicht geladen")
            else:
                state, err = ("error", getattr(srv, "last_error", None) or tx("Noch keine Werkzeuge geladen"))
            item = {"id": e["id"], "name": e.get("name") or e["id"], "kind": e["kind"], "auth": e.get("auth", "none"),
                    "status": state, "error": err, "tools": len(tools),
                    "write_tools": sum(1 for t in tools if not is_read_only(t)), "created_at": e.get("created_at")}
            if e["kind"] == "remote":
                item["url"] = e["url"]
                if e.get("auth") == "token":
                    item["header"] = e.get("header") or "Authorization"
            else:
                item["command"] = " ".join(e["command"])
                item["env_keys"] = e.get("env_keys") or []
            out.append(item)
        return out

    # -- OAuth ------------------------------------------------------------------------------------------------------
    def _cache_discovery(self, sid: str, url: str, detected: dict) -> None:
        d = self._secret(sid)
        d["discovery"] = {"prm": detected.get("prm") or {}, "scope": detected.get("scope") or ""}
        self._save_secret(sid, d)

    def _oauth_meta(self, sid: str) -> dict:
        """Endpunkte und Ressource; einmal ermittelt und im Schlüsselbund-Eintrag gemerkt."""
        d = self._secret(sid)
        if d.get("as") and d.get("resource"):
            return d
        e = self.get(sid)
        disc = d.get("discovery")
        if not disc:
            det = detect(e["url"], self.http)
            if det["auth"] != "oauth":
                raise McpAuthError(tx("Dieser Server bietet keine Anmeldung über OAuth an."))
            disc = {"prm": det.get("prm") or {}, "scope": det.get("scope") or ""}
        prm = disc.get("prm") or {}
        issuer = (prm.get("authorization_servers") or [_origin(e["url"])])[0]
        meta = _as_metadata(issuer, self.http)
        if "S256" not in (meta.get("code_challenge_methods_supported") or ["S256"]):
            raise McpAuthError(tx("Der Server unterstützt die sichere Anmeldung (PKCE S256) nicht."))
        scopes = [s for s in (disc.get("scope") or "").split() if s] or list(prm.get("scopes_supported") or [])
        if "offline_access" in (meta.get("scopes_supported") or []) and "offline_access" not in scopes:
            scopes.append("offline_access")
        keep = ("issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint", "revocation_endpoint")
        d = self._secret(sid)
        d.update(**{"as": {k: meta[k] for k in keep if meta.get(k)}, "resource": prm.get("resource") or e["url"],
                    "scope": " ".join(scopes)})
        d.pop("discovery", None)
        self._save_secret(sid, d)
        return d

    def _client_id(self, sid: str) -> str:
        """Einmalige Registrierung (DCR). Zuerst mit dem App-Schema, lehnt der Anbieter das ab, mit Loopback."""
        d = self._oauth_meta(sid)
        if d.get("client_id") and d.get("redirect_uri") in (REDIRECT_URI, LOOPBACK_URI):
            return d["client_id"]
        reg = d["as"].get("registration_endpoint")
        if not reg:
            raise McpAuthError(tx("Dieser Server erlaubt keine automatische Registrierung (Dynamic Client Registration). "
                                  "Nutze stattdessen ein Token."))
        last = ""
        for redirect in (REDIRECT_URI, LOOPBACK_URI):
            body = {"client_name": CLIENT_NAME, "redirect_uris": [redirect],
                    "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                    "token_endpoint_auth_method": "none"}
            if d.get("scope"):
                body["scope"] = d["scope"]
            r = self.http.post(reg, json=body)
            try:
                data = r.json() if r.content else {}
            except ValueError:
                data = {}
            if r.status_code < 400 and isinstance(data, dict) and data.get("client_id"):
                d = self._secret(sid)
                d.update(client_id=data["client_id"], redirect_uri=redirect)
                self._save_secret(sid, d)
                return d["client_id"]
            err, desc = _err_text(r)
            last = desc or err or str(r.status_code)
            if "redirect" not in f"{err} {desc}".lower():
                break  # anderer Fehler: nicht mit Loopback wiederholen
        raise McpAuthError(tx("Registrierung beim Server fehlgeschlagen: {error}", error=last))

    def start(self, sid: str) -> dict:
        e = self.get(sid)
        if e.get("auth") != "oauth":
            raise ValueError(tx("Dieser Server braucht keine Anmeldung."))
        client_id = self._client_id(sid)
        d = self._secret(sid)
        redirect = d.get("redirect_uri") or REDIRECT_URI
        verifier = _b64(secrets.token_bytes(48))
        state = _b64(secrets.token_bytes(24))
        now = time.time()
        with self._lock:
            self._pending = {s: p for s, p in self._pending.items() if now - p["t"] < PENDING_TTL}
            self._pending[state] = {"sid": sid, "verifier": verifier, "t": now, "client_id": client_id,
                                    "redirect_uri": redirect}
        q = {"response_type": "code", "client_id": client_id, "redirect_uri": redirect,
             "code_challenge": _b64(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256",
             "state": state, "resource": d["resource"]}
        if d.get("scope"):
            q["scope"] = d["scope"]
        url = d["as"]["authorization_endpoint"] + ("&" if "?" in d["as"]["authorization_endpoint"] else "?") + urlencode(q)
        out = {"url": url, "server_id": sid, "callback_scheme": CALLBACK_SCHEME, "kind": "custom_mcp",
               "redirect_uri": redirect}
        if redirect == LOOPBACK_URI:  # App hört kurz auf 127.0.0.1:<port> (ältere Apps: Hinweis „App aktualisieren“)
            out["loopback_port"] = LOOPBACK_PORT
            out["loopback_path"] = "/oauth/mcp"
        return out

    @staticmethod
    def owns_callback(url: str) -> bool:
        u = urlparse(url or "")
        if u.scheme == CALLBACK_SCHEME and (u.netloc + u.path).rstrip("/") == "oauth/mcp":
            return True
        return (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and u.port == LOOPBACK_PORT
                and u.path.rstrip("/") == "/oauth/mcp")

    def finish(self, callback_url: str) -> dict:
        u = urlparse(callback_url or "")
        q = {k: v[0] for k, v in parse_qs(u.query).items() if v}
        if not self.owns_callback(callback_url):
            raise ValueError(tx("Unbekannter Rücksprung-Link"))
        with self._lock:
            pending = self._pending.pop(q.get("state") or "", None)
        if q.get("error"):
            if q["error"] == "access_denied":
                raise ValueError(tx("Die Anmeldung wurde abgebrochen."))
            raise ValueError(tx("Der Server hat die Anmeldung abgelehnt: {error}", error=q.get("error_description") or q["error"]))
        if not pending or time.time() - pending["t"] > PENDING_TTL:
            raise ValueError(tx("Diese Anmeldung ist abgelaufen. Bitte tippe noch einmal auf Anmelden."))
        if not q.get("code"):
            raise ValueError(tx("Der Server hat keinen Anmelde-Code geliefert."))
        sid = pending["sid"]
        d = self._oauth_meta(sid)
        tok = self._token_request(sid, {"grant_type": "authorization_code", "code": q["code"],
                                        "redirect_uri": pending.get("redirect_uri") or REDIRECT_URI,
                                        "client_id": pending["client_id"],
                                        "code_verifier": pending["verifier"], "resource": d["resource"]})
        d = self._secret(sid)
        d.pop("expired", None)
        d.update(self._token_fields(tok), connected_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        self._save_secret(sid, d)
        return {"id": sid, "name": self.get(sid).get("name"), "status": "ok"}

    def _token_request(self, sid: str, form: dict) -> dict:
        d = self._oauth_meta(sid)
        r = self.http.post(d["as"]["token_endpoint"], data=form, headers={"Accept": "application/json"})
        if r.status_code >= 400:
            err, desc = _err_text(r)
            e = McpAuthError(tx("Anmeldung: {error}", error=desc or err or f"HTTP {r.status_code}"))
            e.code = err
            raise e
        try:
            tok = r.json()
        except ValueError:
            tok = {}
        if not tok.get("access_token"):
            raise McpAuthError(tx("Der Server hat kein Zugangs-Token geliefert."))
        return tok

    @staticmethod
    def _token_fields(tok: dict) -> dict:
        out = {"access_token": tok["access_token"], "expires_at": time.time() + float(tok.get("expires_in") or 3600)}
        if tok.get("refresh_token"):
            out["refresh_token"] = tok["refresh_token"]
        return out

    def access_token(self, sid: str, force_refresh: bool = False) -> str:
        d = self._secret(sid)
        if d.get("expired"):
            raise McpAuthError(tx("Die Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden."))
        fresh = lambda x: x.get("access_token") and float(x.get("expires_at") or 0) - time.time() > REFRESH_EARLY  # noqa: E731
        if not force_refresh and fresh(d):
            return d["access_token"]
        lock = self._refresh_locks.setdefault(sid, threading.Lock())
        with lock:
            d = self._secret(sid)
            if not force_refresh and fresh(d):
                return d["access_token"]
            if not d.get("refresh_token") or not d.get("client_id"):
                if d.get("access_token") and not force_refresh:
                    return d["access_token"]  # ohne Refresh-Token: so lange nutzen, bis der Server 401 meldet
                self._expire(sid, d)
                raise McpAuthError(tx("Die Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden."))
            try:
                tok = self._token_request(sid, {"grant_type": "refresh_token", "refresh_token": d["refresh_token"],
                                                "client_id": d["client_id"], "resource": d.get("resource") or ""})
            except McpAuthError as e:
                if e.code in ("invalid_grant", "invalid_client", "unauthorized_client"):
                    self._expire(sid, d)
                    raise McpAuthError(tx("Die Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden.")) from None
                raise
            d.update(self._token_fields(tok))
            self._save_secret(sid, d)  # neues Refresh-Token sofort sichern
            return d["access_token"]

    def _expire(self, sid: str, d: dict) -> None:
        d["expired"] = True
        d.pop("access_token", None)
        self._save_secret(sid, d)
        if self.on_change:
            threading.Thread(target=self.on_change, daemon=True).start()

    def _revoke(self, sid: str) -> None:
        d = self._secret(sid)
        tok = d.get("refresh_token") or d.get("access_token")
        rev = (d.get("as") or {}).get("revocation_endpoint")
        if tok and rev and d.get("client_id"):
            try:
                self.http.post(rev, data={"token": tok, "client_id": d["client_id"],
                                          "token_type_hint": "refresh_token" if d.get("refresh_token") else "access_token"})
            except Exception:  # noqa: BLE001
                pass


# -- Freigaben ------------------------------------------------------------------------------------------------------------
def is_read_only(tool: dict) -> bool:
    ann = tool.get("annotations") or {}
    return ann.get("readOnlyHint") is True


def never_always(tool: str, description: str = "") -> bool:
    return bool(NEVER_ALWAYS_TOOL.search(tool or "")) or bool(NEVER_ALWAYS_TOOL.search((description or "")[:200]))


class ApprovalGate:
    """Hub-Hülle für einen Lauf: schreibende Werkzeuge eigener MCP-Server gehen über `ask` (Freigabe-Karte, Dauerfreigabe),
    lesende und alle übrigen Server direkt. `ask(name, args, tool, label) -> Ergebnis` legt die Karte an."""

    SEP = "__"

    def __init__(self, hub, custom_ids, ask, raw_hub=None) -> None:
        self.hub = hub  # evtl. sharing.ScopedMCP (Gäste)
        self.raw = raw_hub or hub
        self.custom_ids = custom_ids
        self.ask = ask

    def __getattr__(self, item):
        return getattr(self.hub, item)

    def tool_schemas(self) -> list[dict]:
        return self.hub.tool_schemas()

    def owns(self, name: str) -> bool:
        return self.hub.owns(name)

    def needs_approval(self, name: str) -> dict | None:
        """Werkzeug-Beschreibung, wenn der Aufruf eine Freigabe braucht, sonst None."""
        server, _, tool = name.partition(self.SEP)
        ids = self.custom_ids() if callable(self.custom_ids) else self.custom_ids
        if server not in ids:
            return None
        srv = getattr(self.raw, "servers", {}).get(server)
        t = self.raw.resolve(name)[2] if hasattr(self.raw, "resolve") else None
        if t is None and srv is not None:
            try:
                srv.tools()
                t = self.raw.resolve(name)[2] if hasattr(self.raw, "resolve") else None
            except Exception:  # noqa: BLE001
                t = None
        if t is not None and is_read_only(t):
            return None
        return t or {"name": tool}

    def call(self, name: str, args: dict):
        t = self.needs_approval(name)
        if t is None:
            return self.hub.call(name, args)
        return self.ask(name, args, t)


PROMPT_HINT = ("Eigene MCP-Server von {user}: {servers}. Ihre Werkzeuge heißen `<server>__<werkzeug>` (seltenere über die "
               "Werkzeugsuche bzw. app_werkzeug_suchen). Lesende Werkzeuge laufen sofort. Schreibende (alles, was etwas "
               "ändert, anlegt, sendet oder Geld bewegt) rufst du ganz normal auf: Der Server zeigt {user} dann eine "
               "Freigabe-Karte und führt sie erst nach der Freigabe aus. Nichts davon auf anderem Weg erledigen.")


_instance: CustomMCP | None = None


def instance(load_config=None, save_config=None) -> CustomMCP:
    global _instance
    if _instance is None:
        if load_config is None:
            from .bots import load_config as lc, save_config as sc
            load_config, save_config = lc, sc
        _instance = CustomMCP(load_config, save_config)
    return _instance
