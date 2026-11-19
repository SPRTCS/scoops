"""Notion direkt über den offiziellen Remote-MCP von Notion (`https://mcp.notion.com/mcp`, ab Server 1.25).

Warum: Notions eigener MCP liefert kompakte Antworten (Markdown statt JSON-Bergen) und Datenbank-Abfragen über
Ansichten/SQL. Ist er verbunden, nutzen die Scoops ihn statt Composio-Notion; ohne bleibt Composio (samt
composio_direct.py).

Anmeldung ohne Handarbeit für jeden Server (OAuth 2.1, docs/app-daten.md):
- Metadaten: `/.well-known/oauth-authorization-server` (authorize, token, register; PKCE nur S256).
- Dynamic Client Registration (RFC 7591, offen, ohne Konto): Jeder Server registriert sich einmal selbst als
  öffentlicher Client (`token_endpoint_auth_method: none`). Die Registrierung bleibt im Schlüsselbund erhalten, denn
  eine neue Registrierung würde frühere Anmeldungen verwaisen lassen.
- Redirect: `aisscoops://oauth/notion` (URL-Schema der App). Notion erlaubt eigene Schemata, aber kein
  `http://name.local`. So klappt es auf jedem Server, egal ob Tailscale, LAN oder nur lokal. Die App fängt den
  Rücksprung mit ASWebAuthenticationSession ab und schickt die Rücksprung-Adresse an `POST /api/connections/oauth/callback`.
- PKCE-Verifier und `state` bleiben nur im Speicher (15 Minuten). Der Code-Tausch läuft auf dem Server.
- Tokens: Access-Token etwa 8 h, Refresh-Token wird bei jeder Erneuerung ersetzt (höchstens 180 Tage). Erneuert
  wird automatisch 5 Minuten vor Ablauf, immer nur einmal gleichzeitig, das neue Refresh-Token sofort gespeichert.
  Bei `invalid_grant` gilt die Verbindung als abgelaufen: kein Wiederholen, die App zeigt „Neu anmelden“.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

from .profile import kc

MCP_URL = "https://mcp.notion.com/mcp"
ISSUER = "https://mcp.notion.com"
RESOURCE = MCP_URL
REDIRECT_URI = "aisscoops://oauth/notion"
CALLBACK_SCHEME = "aisscoops"
ACCOUNT_ID = "notion-mcp"  # Pseudo-Konto in „Apps verbinden“ (App „notion“)
SERVER_NAME = "notion"  # Name im MCPHub → Werkzeuge `notion__notion-search` usw.
CLIENT_NAME = "AIS Scoops"
PENDING_TTL = 15 * 60
REFRESH_EARLY = 5 * 60
KEYCHAIN_ACCOUNT = "oauth"


class NotionAuthError(RuntimeError):
    """Anmeldung bei Notion fehlgeschlagen oder abgelaufen."""


# -- Speicher (Schlüsselbund) --------------------------------------------------------
class KeychainStore:
    """Ein JSON-Eintrag im Schlüsselbund. Geschrieben über `security -i` (stdin), damit der Wert nie in der
    Prozessliste steht. Base64 statt rohem JSON, weil `security -i` Anführungszeichen selbst auswertet."""

    def __init__(self, service: str | None = None, account: str = KEYCHAIN_ACCOUNT) -> None:
        self.service = service or kc("notion-mcp")
        self.account = account

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
            raise NotionAuthError("Notion-Anmeldung konnte nicht im Schlüsselbund gespeichert werden.")

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


class NotionMCP:
    def __init__(self, store=None, http: httpx.Client | None = None) -> None:
        self.store = store or KeychainStore()
        self.http = http or httpx.Client(timeout=20)
        self._meta: dict | None = None
        self._pending: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._refresh_lock = threading.Lock()
        self._cache: dict | None = None  # Kopie des Schlüsselbund-Eintrags (spart `security`-Aufrufe)
        self.on_change = None  # server.py: MCPHub neu konfigurieren, wenn die Anmeldung abläuft

    # -- Zustand ----------------------------------------------------------------------
    def _data(self) -> dict:
        if self._cache is None:
            self._cache = self.store.get()
        return dict(self._cache)

    def _save(self, data: dict) -> None:
        self.store.set(data)
        self._cache = dict(data)

    def connected(self) -> bool:
        d = self._data()
        return bool(d.get("refresh_token") or d.get("access_token")) and not d.get("expired")

    def account(self) -> dict | None:
        """Pseudo-Konto für „Apps verbinden“ (App `notion`) oder None, wenn nie verbunden."""
        d = self._data()
        if not (d.get("refresh_token") or d.get("access_token")):
            return None
        return {"id": ACCOUNT_ID, "app": "notion", "alias": d.get("alias") or "Notion direkt",
                "email": d.get("workspace_name") or "", "status": "expired" if d.get("expired") else "active",
                "created_at": d.get("connected_at"), "direct": True}

    def mcp_spec(self) -> dict | None:
        """Eintrag für MCPHub.configure, solange verbunden. Das Token holt der Hub bei jedem Aufruf frisch."""
        if not self.connected():
            return None
        return {"type": "url", "name": SERVER_NAME, "url": MCP_URL, "authorization_token": self.access_token}

    # -- OAuth ------------------------------------------------------------------------
    def metadata(self) -> dict:
        if self._meta:
            return self._meta
        r = self.http.get(ISSUER + "/.well-known/oauth-authorization-server")
        if r.status_code >= 400:
            raise NotionAuthError(f"Notion ist gerade nicht erreichbar (HTTP {r.status_code}).")
        meta = r.json()
        if "S256" not in (meta.get("code_challenge_methods_supported") or ["S256"]):
            raise NotionAuthError("Notion unterstützt die sichere Anmeldung (PKCE S256) nicht mehr.")
        self._meta = meta
        return meta

    def _client_id(self) -> str:
        """Einmalige, dauerhafte Registrierung dieses Servers bei Notion (Dynamic Client Registration)."""
        d = self._data()
        if d.get("client_id") and d.get("redirect_uri") == REDIRECT_URI:
            return d["client_id"]
        meta = self.metadata()
        reg = meta.get("registration_endpoint") or ISSUER + "/register"
        r = self.http.post(reg, json={"client_name": CLIENT_NAME, "redirect_uris": [REDIRECT_URI],
                                      "grant_types": ["authorization_code", "refresh_token"],
                                      "response_types": ["code"], "token_endpoint_auth_method": "none"})
        if r.status_code >= 400 or not (r.json() if r.content else {}).get("client_id"):
            err, desc = _err_text(r)
            raise NotionAuthError(f"Registrierung bei Notion fehlgeschlagen: {desc or err or r.status_code}")
        d = self._data()
        d.update(client_id=r.json()["client_id"], redirect_uri=REDIRECT_URI)
        self._save(d)
        return d["client_id"]

    def start(self, alias: str | None = None) -> dict:
        """Anmelde-Link für die App. `callback_scheme`: Darauf hört ASWebAuthenticationSession."""
        meta = self.metadata()
        client_id = self._client_id()
        verifier = _b64(secrets.token_bytes(48))
        state = _b64(secrets.token_bytes(24))
        now = time.time()
        with self._lock:
            self._pending = {s: p for s, p in self._pending.items() if now - p["t"] < PENDING_TTL}
            self._pending[state] = {"verifier": verifier, "t": now, "client_id": client_id,
                                    "alias": (alias or "").strip()[:60]}
        q = {"response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT_URI,
             "code_challenge": _b64(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256",
             "state": state, "resource": RESOURCE}
        url = (meta.get("authorization_endpoint") or ISSUER + "/authorize") + "?" + urlencode(q)
        return {"url": url, "account_id": ACCOUNT_ID, "callback_scheme": CALLBACK_SCHEME, "kind": "notion_mcp"}

    def finish(self, callback_url: str) -> dict:
        """Rücksprung `aisscoops://oauth/notion?code=…&state=…` → Tokens tauschen und speichern."""
        u = urlparse(callback_url or "")
        q = {k: v[0] for k, v in parse_qs(u.query).items() if v}
        if u.scheme != CALLBACK_SCHEME or (u.netloc + u.path).rstrip("/") != "oauth/notion":
            raise ValueError("Unbekannter Rücksprung-Link")
        if q.get("error"):
            if q["error"] == "access_denied":
                raise ValueError("Die Anmeldung bei Notion wurde abgebrochen.")
            raise ValueError(f"Notion hat die Anmeldung abgelehnt: {q.get('error_description') or q['error']}")
        with self._lock:
            pending = self._pending.pop(q.get("state") or "", None)
        if not pending or time.time() - pending["t"] > PENDING_TTL:
            raise ValueError("Diese Anmeldung ist abgelaufen. Bitte tippe noch einmal auf Verbinden.")
        if not q.get("code"):
            raise ValueError("Notion hat keinen Anmelde-Code geliefert.")
        tok = self._token_request({"grant_type": "authorization_code", "code": q["code"], "redirect_uri": REDIRECT_URI,
                                   "client_id": pending["client_id"], "code_verifier": pending["verifier"],
                                   "resource": RESOURCE})
        d = self._data()
        d.pop("expired", None)
        d.update(self._token_fields(tok), connected_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        for k in ("workspace_name", "workspace_id"):
            if tok.get(k):
                d[k] = tok[k]
        if pending.get("alias"):
            d["alias"] = pending["alias"]
        self._save(d)
        return self.account() or {}

    def _token_request(self, form: dict) -> dict:
        meta = self.metadata()
        r = self.http.post(meta.get("token_endpoint") or ISSUER + "/token", data=form,
                           headers={"Accept": "application/json"})
        if r.status_code >= 400:
            err, desc = _err_text(r)
            e = NotionAuthError(f"Notion: {desc or err or f'HTTP {r.status_code}'}")
            e.code = err  # type: ignore[attr-defined]
            raise e
        tok = r.json()
        if not tok.get("access_token"):
            raise NotionAuthError("Notion hat kein Zugangs-Token geliefert.")
        return tok

    @staticmethod
    def _token_fields(tok: dict) -> dict:
        out = {"access_token": tok["access_token"],
               "expires_at": time.time() + float(tok.get("expires_in") or 3600)}
        if tok.get("refresh_token"):
            out["refresh_token"] = tok["refresh_token"]
        return out

    def access_token(self, force_refresh: bool = False) -> str:
        """Gültiges Access-Token; erneuert bei Bedarf (einmal gleichzeitig, rotierendes Refresh-Token)."""
        d = self._data()
        if d.get("expired"):
            raise NotionAuthError("Die Notion-Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden.")
        if not force_refresh and d.get("access_token") and float(d.get("expires_at") or 0) - time.time() > REFRESH_EARLY:
            return d["access_token"]
        with self._refresh_lock:
            d = self._data()  # ein anderer Thread hat vielleicht gerade erneuert
            if not force_refresh and d.get("access_token") and float(d.get("expires_at") or 0) - time.time() > REFRESH_EARLY:
                return d["access_token"]
            if not d.get("refresh_token") or not d.get("client_id"):
                raise NotionAuthError("Notion ist nicht verbunden.")
            try:
                tok = self._token_request({"grant_type": "refresh_token", "refresh_token": d["refresh_token"],
                                           "client_id": d["client_id"], "resource": RESOURCE})
            except NotionAuthError as e:
                if getattr(e, "code", "") in ("invalid_grant", "invalid_client", "unauthorized_client"):
                    d["expired"] = True
                    d.pop("access_token", None)
                    self._save(d)
                    if self.on_change:  # Hub ohne Notion direkt → Composio-Notion gilt wieder
                        threading.Thread(target=self.on_change, daemon=True).start()
                    raise NotionAuthError("Die Notion-Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu "
                                          "anmelden.") from None
                raise
            d.update(self._token_fields(tok))
            self._save(d)  # neues Refresh-Token sofort sichern (das alte ist ab jetzt verbraucht)
            return d["access_token"]

    def rename(self, alias: str) -> dict:
        d = self._data()
        d["alias"] = alias.strip()[:60]
        self._save(d)
        return self.account() or {}

    def disconnect(self) -> None:
        """Abmelden: Token bei Notion widerrufen (best effort) und Anmeldung löschen. Die Registrierung bleibt."""
        d = self._data()
        tok = d.get("refresh_token") or d.get("access_token")
        if tok and d.get("client_id"):
            try:
                meta = self.metadata()
                self.http.post(meta.get("revocation_endpoint") or ISSUER + "/token",
                               data={"token": tok, "client_id": d["client_id"],
                                     "token_type_hint": "refresh_token" if d.get("refresh_token") else "access_token"})
            except Exception:  # noqa: BLE001
                pass
        keep = {k: d[k] for k in ("client_id", "redirect_uri") if d.get(k)}
        if keep:
            self._save(keep)
        else:
            self.store.delete()
            self._cache = {}


PROMPT_HINT = ("Notion ist direkt verbunden (offizieller Notion-Zugang, Werkzeuge `notion__…`). Für Notion nimmst du "
               "nur diese Werkzeuge, nicht Composio: suchen mit `notion__notion-search`, Seiten und Datenbanken lesen mit "
               "`notion__notion-fetch` (liefert Schema und Daten-Quellen), Zeilen einer Datenbank mit "
               "`notion__notion-query-data-sources`, ändern mit `notion__notion-update-page`, anlegen mit "
               "`notion__notion-create-pages`. Weitere über die Werkzeugsuche.")

_instance: NotionMCP | None = None


def instance() -> NotionMCP:
    global _instance
    if _instance is None:
        _instance = NotionMCP()
    return _instance
