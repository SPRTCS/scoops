"""Anbindung an AIS Scoops Cloud (Convex, siehe docs/accounts.md).

Convex kennt nur Konten, Server und Sitzungen – keine Inhalte. Dieses Modul
  • koppelt den Server mit einem Konto (Code wie bei Scoops Connect: start → Nutzer gibt Code in der App ein → poll),
  • schickt alle 60 s einen Herzschlag (öffentliche URL, Version) und lernt dabei abgemeldete Sitzungen,
  • prüft Sitzungs-JWTs der App (RS256, JWKS von Convex), damit die App ohne API-Token verbinden kann.

Das serverSecret liegt im Schlüsselbund (`ais-bot-cloud` / `server-secret`), `owner_id`, `cloud_server_id` und
`cloud_url` in config.json.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import sys
import threading
import time
from typing import Callable

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from .i18n import tx
from .profile import kc

# HTTP-Adresse (…convex.site) des Produktions-Deployments; überschreibbar per config `cloud_url`.
DEFAULT_CLOUD_URL = "https://helpful-puma-445.eu-west-1.convex.site"
AUDIENCE = "ais-scoops"
KEYCHAIN_SERVICE = os.environ.get("AISBOT_CLOUD_KEYCHAIN") or kc("cloud")  # Tests nutzen einen eigenen Eintrag
KEYCHAIN_ACCOUNT = "server-secret"
HEARTBEAT_EVERY = 60.0
POLL_EVERY = float(os.environ.get("AISBOT_CLOUD_POLL", "3"))
JWKS_TTL = 3600.0
JWKS_REFETCH_MIN = 30.0  # bei unbekannter kid höchstens so oft neu laden
LEEWAY = 60  # Sekunden Toleranz für exp/nbf/iat


# -- Schlüsselbund ----------------------------------------------------------------
def get_secret() -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
                       capture_output=True, text=True)
    return (r.stdout.strip() or None) if r.returncode == 0 else None


def set_secret(secret: str) -> None:
    subprocess.run(["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT,
                    "-l", "AIS Scoops – Server-Kopplung", "-w", secret], check=True, capture_output=True)


def delete_secret() -> None:
    subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
                   capture_output=True)


def server_name() -> str:
    r = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True)
    return (r.stdout.strip() if r.returncode == 0 else "") or socket.gethostname().split(".")[0] or "AIS-Scoops-Server"


# -- JWT ------------------------------------------------------------------------
def _b64d(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _b64int(s: str) -> int:
    return int.from_bytes(_b64d(s), "big")


def looks_like_jwt(token: str) -> bool:
    return token.count(".") == 2 and token.startswith("eyJ")


class JWKS:
    """Öffentliche Schlüssel von <cloud_url>/.well-known/jwks.json, zwischengespeichert."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._url = ""
        self._keys: dict[str, rsa.RSAPublicKey] = {}
        self._fetched = 0.0
        self._last_try = 0.0

    def _fetch(self, url: str) -> None:
        self._last_try = time.time()
        r = httpx.get(url, timeout=8)
        r.raise_for_status()
        keys = {}
        for k in r.json().get("keys", []):
            if k.get("kty") == "RSA" and k.get("kid") and k.get("n") and k.get("e"):
                keys[k["kid"]] = rsa.RSAPublicNumbers(_b64int(k["e"]), _b64int(k["n"])).public_key()
        self._url, self._keys, self._fetched = url, keys, time.time()

    def key(self, base_url: str, kid: str) -> rsa.RSAPublicKey | None:
        url = base_url.rstrip("/") + "/.well-known/jwks.json"
        with self._lock:
            stale = url != self._url or time.time() - self._fetched > JWKS_TTL
            unknown = kid not in self._keys and time.time() - self._last_try > JWKS_REFETCH_MIN
            if stale or unknown:
                try:
                    self._fetch(url)
                except Exception as e:  # noqa: BLE001 – alter Stand bleibt nutzbar
                    print("Cloud: JWKS nicht ladbar:", e, flush=True)
                    if url != self._url:
                        return None
            return self._keys.get(kid)


def verify_jwt(token: str, key_for: Callable[[str], rsa.RSAPublicKey | None], *, issuer: str, audience: str,
               now: float | None = None) -> dict | None:
    """Prüft ein RS256-JWT. Liefert die Claims oder None (nie eine Ausnahme)."""
    return check_jwt(token, key_for, issuer=issuer, audience=audience, now=now)[0]


def check_jwt(token: str, key_for: Callable[[str], rsa.RSAPublicKey | None], *, issuer: str, audience: str,
              now: float | None = None) -> tuple[dict | None, str]:
    """Wie `verify_jwt`, liefert zusätzlich den Ablehnungsgrund (für das Log, ohne Token-Inhalt)."""
    try:
        h64, p64, s64 = token.split(".")
        header = json.loads(_b64d(h64))
        claims = json.loads(_b64d(p64))
        if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str) or not isinstance(claims, dict):
            return None, "kein RS256-JWT mit kid"
        key = key_for(header["kid"])
        if key is None:
            return None, "Schlüssel (kid) nicht in der JWKS des Konto-Dienstes"
        key.verify(_b64d(s64), f"{h64}.{p64}".encode(), padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature:
        return None, "Signatur ungültig"
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        return None, "nicht lesbar"
    t = time.time() if now is None else now
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    exp, nbf = claims.get("exp"), claims.get("nbf")
    iss = (claims.get("iss") or "").rstrip("/")
    if iss != issuer.rstrip("/"):
        return None, f"Aussteller {iss or '–'} statt {issuer.rstrip('/')}"
    if audience not in auds:
        return None, "falsche Zielgruppe (aud)"
    if not isinstance(exp, (int, float)) or exp + LEEWAY < t:
        return None, "abgelaufen" + (f" seit {int(t - exp)} s" if isinstance(exp, (int, float)) else "")
    if isinstance(nbf, (int, float)) and nbf - LEEWAY > t:
        return None, "noch nicht gültig (nbf, Uhrzeit prüfen)"
    if not isinstance(claims.get("sub"), str):
        return None, "ohne sub"
    return claims, ""


# -- Kopplung und Herzschlag --------------------------------------------------------
class Cloud:
    def __init__(self, load_config: Callable[[], dict], save_config: Callable[[dict], None], version: str) -> None:
        self.load_config, self.save_config, self.version = load_config, save_config, version
        self.jwks = JWKS()
        self.revoked: set[str] = set()
        self.pending: dict | None = None  # {code, claim_id, claim_secret, expires_at}
        self.last_heartbeat = 0.0
        self.last_heartbeat_ok: float | None = None
        self.last_error: str | None = None
        self._lock = threading.Lock()
        self._rejected_logged: dict[str, float] = {}  # Grund → letzte Log-Zeile (verify_session)
        self._reject_lock = threading.Lock()
        self._poll_thread: threading.Thread | None = None
        self.on_change: Callable[[], None] | None = None  # z. B. Push-Transport neu wählen (push.py)
        self.on_heartbeat: Callable[[dict], None] | None = None  # z. B. Shares neu laden (sharing.py)

    # Zustand
    def url(self, cfg: dict | None = None) -> str:
        cfg = cfg if cfg is not None else self.load_config()
        return (cfg.get("cloud_url") or DEFAULT_CLOUD_URL).rstrip("/")

    def owner_id(self) -> str | None:
        return self.load_config().get("owner_id") or None

    def status(self) -> dict:
        cfg = self.load_config()
        p = self.pending
        if p and p["expires_at"] <= time.time():
            p = None
        return {
            "version": self.version,
            "cloud_url": self.url(cfg),
            "linked": bool(cfg.get("owner_id")),
            "owner_id": cfg.get("owner_id"),
            "server_id": cfg.get("cloud_server_id"),
            "pending": {"code": p["code"], "expires_at": p["expires_at_iso"],
                        "ttl_seconds": max(0, int(p["expires_at"] - time.time()))} if p else None,
            "last_heartbeat_at": _iso(self.last_heartbeat_ok) if self.last_heartbeat_ok else None,
            "last_error": self.last_error,
        }

    # Kopplung
    def start_link(self, *, force: bool = False, background: bool = True) -> dict:
        """Fordert einen Code an. Ein Hintergrund-Thread pollt, bis er in der App eingelöst wurde."""
        cfg = self.load_config()
        if cfg.get("owner_id") and not force:
            raise RuntimeError(tx("Server ist bereits mit einem Konto gekoppelt (erneut koppeln: force)."))
        body = {"name": cfg.get("server_name") or server_name(), "version": self.version,
                "publicUrl": cfg.get("public_url") or ""}
        if cfg.get("tailnet_url"):
            body["tailnetUrl"] = cfg["tailnet_url"]
        r = httpx.post(self.url(cfg) + "/servers/claim/start", json=body, timeout=15)
        data = _json(r)
        if r.status_code != 200:
            raise RuntimeError(data.get("error") or tx("Kopplung nicht möglich ({status})", status=r.status_code))
        expires_at = time.time() + float(data.get("ttlSeconds") or 600)
        with self._lock:
            self.pending = {"code": data["code"], "claim_id": data["claimId"], "claim_secret": data["claimSecret"],
                            "expires_at": expires_at, "expires_at_iso": _iso(expires_at)}
        print(f"Cloud: Kopplungscode {data['code']} (10 Minuten gültig) – in der App unter „Server hinzufügen“ eingeben",
              flush=True)
        if background and not (self._poll_thread and self._poll_thread.is_alive()):
            self._poll_thread = threading.Thread(target=self._poll_loop, daemon=True, name="cloud-link")
            self._poll_thread.start()
        return self.status()

    def _poll_loop(self) -> None:
        while True:
            time.sleep(POLL_EVERY)
            try:
                if self.poll_once() != "pending":
                    return
            except Exception as e:  # noqa: BLE001 – Netzfehler: weiter versuchen, bis der Code abläuft
                self.last_error = tx("Kopplung: {error}", error=e)
                if not self.pending or self.pending["expires_at"] <= time.time():
                    return

    def poll_once(self) -> str:
        """Fragt einmal nach. Rückgabe: pending | claimed | expired | none."""
        p = self.pending
        if not p:
            return "none"
        r = httpx.post(self.url() + "/servers/claim/poll", json={"claimId": p["claim_id"], "claimSecret": p["claim_secret"]},
                       timeout=15)
        data = _json(r)
        if r.status_code == 200 and data.get("status") == "pending":
            return "pending"
        if r.status_code == 200 and data.get("status") == "claimed":
            self._store_link(data)
            return "claimed"
        with self._lock:
            if self.pending is p:
                self.pending = None
        self.last_error = data.get("error") or tx("Kopplung beendet ({status})", status=r.status_code)
        return "expired"

    def _store_link(self, data: dict) -> None:
        set_secret(data["serverSecret"])
        cfg = self.load_config()
        cfg.update(owner_id=data["ownerId"], cloud_server_id=data["serverId"])
        if data.get("ownerName"):
            cfg["owner_name"] = data["ownerName"]  # Anzeigename des Kontos (Ansprache, siehe profile.user_name)
        cfg.setdefault("cloud_url", self.url(cfg))
        self.save_config(cfg)
        with self._lock:
            self.pending = None
        self.revoked.clear()
        self.last_error = None
        self.last_heartbeat = 0.0  # gleich bestätigen (erst der Herzschlag macht die Kopplung endgültig)
        print(f"Cloud: gekoppelt mit Konto {data['ownerId']} als „{data.get('name', '')}“", flush=True)
        self._changed()
        try:
            self.heartbeat()
        except Exception as e:  # noqa: BLE001
            self.last_error = tx("Herzschlag: {error}", error=e)

    def unlink(self, reason: str) -> None:
        cfg = self.load_config()
        for k in ("owner_id", "cloud_server_id", "owner_name"):
            cfg.pop(k, None)
        self.save_config(cfg)
        delete_secret()
        self.revoked.clear()
        print(f"Cloud: Kopplung aufgehoben ({reason})", flush=True)
        self._changed()

    def _changed(self) -> None:
        if self.on_change:
            try:
                self.on_change()
            except Exception as e:  # noqa: BLE001
                print("Cloud: on_change-Fehler:", e, flush=True)

    # Herzschlag
    def heartbeat_tick(self) -> None:
        """Aus dem Planer (alle 15 s aufgerufen): höchstens alle 60 s, nur wenn gekoppelt."""
        if time.time() - self.last_heartbeat < HEARTBEAT_EVERY or not self.owner_id():
            return
        try:
            self.heartbeat()
        except Exception as e:  # noqa: BLE001
            self.last_error = tx("Herzschlag: {error}", error=e)

    def heartbeat(self) -> dict | None:
        self.last_heartbeat = time.time()
        cfg = self.load_config()
        if not cfg.get("owner_id"):
            return None
        secret = get_secret()
        if not secret:
            self.last_error = tx("Herzschlag: serverSecret fehlt im Schlüsselbund")
            return None
        body = {"publicUrl": cfg.get("public_url") or "", "version": self.version}
        if cfg.get("tailnet_url"):
            body["tailnetUrl"] = cfg["tailnet_url"]
        r = httpx.post(self.url(cfg) + "/servers/heartbeat", json=body,
                       headers={"Authorization": f"Bearer {secret}"}, timeout=15)
        data = _json(r)
        if r.status_code == 401 and data.get("code") == "unknown_server":
            self.last_error = tx("Server wurde in der App entfernt oder das Konto gelöscht")
            self.unlink("vom Konto entfernt")
            return None
        if r.status_code != 200:
            raise RuntimeError(data.get("error") or f"HTTP {r.status_code}")
        changed = False
        if data.get("ownerId") and data["ownerId"] != cfg.get("owner_id"):
            print("Cloud: Inhaber laut Convex weicht ab – übernehme", data["ownerId"], flush=True)
            cfg["owner_id"] = data["ownerId"]
            changed = True
        if data.get("ownerName") and data["ownerName"] != cfg.get("owner_name"):
            cfg["owner_name"] = data["ownerName"]
            changed = True
        if changed:
            self.save_config(cfg)
        self.revoked = set(data.get("revokedSessions") or [])
        self.last_heartbeat_ok = time.time()
        self.last_error = None
        if self.on_heartbeat:
            try:
                self.on_heartbeat(data)
            except Exception as e:  # noqa: BLE001
                print("Cloud: on_heartbeat-Fehler:", e, flush=True)
        return data

    # Sitzungs-JWT
    def verify_session(self, token: str) -> dict | None:
        """Claims eines gültigen Sitzungs-JWT des Server-Inhabers, sonst None. Abgelehnte JWTs landen mit Grund
        (nie mit Token-Inhalt) im Log, höchstens einmal pro Grund und Minute."""
        claims = self.verify_any(token)
        if claims and claims["sub"] != self.load_config().get("owner_id"):
            self._log_rejected("Konto passt nicht zum Inhaber dieses Servers")
            return None
        return claims

    def verify_any(self, token: str) -> dict | None:
        """Claims eines gültigen Sitzungs-JWT irgendeines Kontos (Inhaber oder Gast, geteilte Scoops), sonst None.
        Was ein Gast darf, entscheidet allein server.py anhand der Shares (Standard: nichts)."""
        if not token or not looks_like_jwt(token):
            return None
        cfg = self.load_config()
        owner = cfg.get("owner_id")
        if not owner:
            self._log_rejected("Server ist mit keinem Konto gekoppelt (owner_id fehlt)")
            return None
        base = self.url(cfg)
        claims, reason = check_jwt(token, lambda kid: self.jwks.key(base, kid), issuer=base, audience=AUDIENCE)
        if not claims:
            self._log_rejected(reason)
            return None
        if claims.get("sid") in self.revoked:
            self._log_rejected("Sitzung wurde abgemeldet")
            return None
        return claims

    def _log_rejected(self, reason: str) -> None:
        now = time.time()
        with self._reject_lock:
            if now - self._rejected_logged.get(reason, 0.0) < 60:
                return
            self._rejected_logged[reason] = now
        print(f"Cloud: Sitzungs-JWT abgelehnt – {reason}", flush=True)


def _json(r: httpx.Response) -> dict:
    try:
        d = r.json()
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


# -- Kommandozeile: bin/aisbot cloud-link -------------------------------------------
def cli_link(argv: list[str]) -> None:
    """Startet die Kopplung über den laufenden Server (GET/POST /api/setup) und zeigt den Code.
    Läuft kein Server, koppelt die Kommandozeile selbst."""
    sys.stdout.reconfigure(line_buffering=True)  # Code sofort zeigen, auch wenn die Ausgabe umgeleitet ist
    force = "--force" in argv or "--neu" in argv
    only_status = "--status" in argv
    base = f"http://127.0.0.1:{os.environ.get('AISBOT_PORT', '8787')}"
    try:
        st = httpx.get(base + "/api/setup", timeout=5).json()
    except Exception:  # noqa: BLE001
        st = None
    if st is None:
        print("Server läuft nicht – koppele direkt von der Kommandozeile.")
        _cli_link_direct(force, only_status)
        return
    if only_status or (st.get("linked") and not force):
        _print_status(st)
        if st.get("linked") and not only_status:
            print("Bereits gekoppelt. Neu koppeln: bin/aisbot cloud-link --force")
        return
    if not st.get("pending"):
        r = httpx.post(base + "/api/setup/link", json={"force": force}, timeout=20)
        if r.status_code != 200:
            sys.exit(f"Fehler: {_json(r).get('error') or r.status_code}")
        st = r.json()
    _wait_and_show(lambda: httpx.get(base + "/api/setup", timeout=5).json(), st)


def _cli_link_direct(force: bool, only_status: bool) -> None:
    from .bots import load_config, save_config
    from .version import VERSION

    c = Cloud(load_config, save_config, VERSION)
    if only_status:
        _print_status(c.status())
        return
    st = c.start_link(force=force, background=False)

    def step() -> dict:
        try:
            c.poll_once()
        except Exception as e:  # noqa: BLE001
            print("  (Netzfehler:", e, ")")
        return c.status()

    _wait_and_show(step, st)


def _wait_and_show(get_status: Callable[[], dict], st: dict) -> None:
    p = st.get("pending") or {}
    if not p:
        _print_status(st)
        return
    code = p["code"]
    print(f"\n  Kopplungscode:  {code}\n")
    print("  In AIS Scoops: Anmelden → „Deine Server“ → „Server hinzufügen“ → Code eingeben.")
    print(f"  Gültig für {p.get('ttl_seconds', 600) // 60} Minuten. Warte auf Bestätigung … (Strg-C bricht ab)")
    try:
        while True:
            time.sleep(2)
            st = get_status()
            if st.get("linked"):
                print(f"\n✓ Gekoppelt (Server-ID {st.get('server_id')}).")
                return
            if not st.get("pending"):
                sys.exit(f"\nCode abgelaufen oder ungültig{': ' + st['last_error'] if st.get('last_error') else ''}. "
                         "Erneut starten mit bin/aisbot cloud-link")
    except KeyboardInterrupt:
        print("\nAbgebrochen (der Code bleibt bis zum Ablauf gültig).")


def _print_status(st: dict) -> None:
    print(f"Cloud: {st.get('cloud_url')}")
    print(f"Gekoppelt: {'ja' if st.get('linked') else 'nein'}"
          + (f" (Konto {st.get('owner_id')}, Server {st.get('server_id')})" if st.get("linked") else ""))
    if st.get("pending"):
        print(f"Offener Code: {st['pending']['code']} (noch {st['pending']['ttl_seconds']} s)")
    if st.get("last_heartbeat_at"):
        print(f"Letzter Herzschlag: {st['last_heartbeat_at']}")
    if st.get("last_error"):
        print(f"Letzter Fehler: {st['last_error']}")
