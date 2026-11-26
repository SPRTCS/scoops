"""Tresor: Logins für Webseiten. Passwörter liegen ausschließlich im macOS-Schlüsselbund des Air.

Ein Scoop sieht nur Titel, Webseite und Benutzername. Zum Ausfüllen tippt der Server das Passwort
direkt in den Bot-Rechner – aber nur, wenn die gerade geöffnete Webseite zur Domain des Eintrags passt.
Das Passwort erscheint nie im Verlauf, in Protokollen oder in Antworten an das Modell.
"""

from __future__ import annotations

import re
import subprocess
from urllib.parse import urlparse

from .profile import kc

SERVICE = kc("vault")


def domain_of(url: str) -> str:
    u = url.strip()
    if "://" not in u:
        u = "https://" + u
    host = (urlparse(u).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def set_secret(entry_id: str, secret: str) -> None:
    subprocess.run(["security", "add-generic-password", "-U", "-s", SERVICE, "-a", entry_id, "-w", secret],
                   check=True, capture_output=True)


def get_secret(entry_id: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-a", entry_id, "-w"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    v = r.stdout.rstrip("\n")
    if re.fullmatch(r"[0-9a-f]+", v) and len(v) % 2 == 0 and len(v) >= 16:
        try:  # `security -w` gibt Werte mit Sonderzeichen hexkodiert aus
            dec = bytes.fromhex(v).decode()
            if dec.isprintable():
                return dec
        except ValueError:
            pass
    return v


def delete_secret(entry_id: str) -> None:
    subprocess.run(["security", "delete-generic-password", "-s", SERVICE, "-a", entry_id], capture_output=True)


# Browser, deren aktuelle Adresse der Tresor lesen kann. macOS fragt jedes Programm einzeln per AppleScript; dass Dia und
# Chrome beide auf Chromium basieren, hilft dabei nicht. Name = Prozessname in System Events.
BROWSERS = {
    "Safari": 'tell application "Safari" to return URL of front document',
    "Google Chrome": 'tell application "Google Chrome" to return URL of active tab of front window',
    "Dia": 'tell application "Dia" to return URL of active tab of front window',
}
BROWSER_NAMES = "Safari, Chrome oder Dia"
NOT_ACTIVE = "Dein Rechner ist für dich gerade nicht aktiv. Mach zuerst einen Screenshot, dann nochmal versuchen."


def current_page(computer) -> tuple[str | None, str | None]:
    """(Programm, URL) des vordersten Fensters im Bot-Rechner, soweit lesbar. Wartet höchstens 20 s auf den Browser
    (beim ersten Zugriff kann macOS nach der Automation-Erlaubnis fragen)."""
    cases = " ".join(f"""  "{name}") osascript -e 'with timeout of 20 seconds' -e '{cmd}' -e 'end timeout' 2>/dev/null;; """
                     for name, cmd in BROWSERS.items())
    script = (
        'app=$(osascript -e "tell application \\"System Events\\" to get name of first process whose frontmost is true" 2>/dev/null); '
        'echo "APP=$app"; '
        f'case "$app" in {cases}esac'
    )
    try:
        out = computer.shell(script).get("stdout", "")
    except Exception:  # noqa: BLE001
        return None, None
    lines = [x for x in out.splitlines() if x.strip()]
    app = lines[0][4:] if lines and lines[0].startswith("APP=") else None
    url = lines[1].strip() if len(lines) > 1 else None
    if url and not url.lower().startswith(("https://", "http://")):
        url = None  # „missing value“, leerer Tab, interne Browser-Seite
    return app, url


def mismatch_message(app: str | None, url: str | None, title: str, domain: str, user: str) -> str:
    """Warum nicht ausgefüllt wurde, so dass der Scoop den richtigen nächsten Schritt kennt."""
    if app not in BROWSERS:
        return (f"Nicht ausgefüllt: Vorne ist {app or 'kein lesbares Programm'}. Der Tresor füllt nur in {BROWSER_NAMES} aus. "
                f"Bring die Seite von {domain} dort nach vorn und versuch es erneut.")
    if not url:
        return (f"Nicht ausgefüllt: Die Adresse in {app} ist nicht lesbar. Ist dort eine normale Webseite offen, fehlt "
                f"wahrscheinlich die macOS-Erlaubnis (Systemeinstellungen > Datenschutz & Sicherheit > Automation). "
                f"Sag {user} das; bestätige solche Abfragen nicht selbst.")
    return (f"Nicht ausgefüllt: Die geöffnete Seite ({domain_of(url)}, {app}) passt nicht zu „{title}“ ({domain}). "
            f"Öffne die richtige Seite in {BROWSER_NAMES} und versuch es erneut.")


def domain_matches(page_url: str | None, entry_domain: str) -> bool:
    if not page_url or not entry_domain:
        return False
    host = domain_of(page_url)
    d = entry_domain.lower().lstrip(".")
    return host == d or host.endswith("." + d)
