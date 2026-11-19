"""Installationsprofil: Datenordner, Edition und persönliche Zusatzfunktionen.

Zwei Editionen:

- **personal** (Standard, Armans Server auf dem MacBook Air): alles wie bisher – Datenordner
  ~/.local/share/ais-bot, Lucy-Telefonie, T3, Team App, Atrium, VM-Bot-Rechner, persönliche Prompt-Hinweise.
- **standard** (Mac-App „AIS Scoops Server“ für andere Personen): Datenordner
  ~/Library/Application Support/AIS Scoops Server, keine persönlichen Zusatzfunktionen, kein VM-Bot-Rechner,
  neutrale Ansprache (Name aus dem Konto bzw. der Einrichtung), ein Start-Scoop zum Kennenlernen.

Festgelegt wird die Edition durch `edition` in config.json, sonst durch die Umgebungsvariable `AISBOT_EDITION`
(setzt die Mac-App), sonst `personal`. Einzelne Funktionen lassen sich mit `features` in config.json
gezielt ein- oder ausschalten, z. B. `{"features": {"lucy": false}}`.

Umgebungsvariablen (alle optional):
  AISBOT_HOME             Basisordner (config.json, data/, logs/, backups/)
  AISBOT_CONFIG / AISBOT_DATA   einzelne Pfade wie bisher (haben Vorrang)
  AISBOT_EDITION          personal | standard
  AISBOT_KEYCHAIN_PREFIX  Präfix der Schlüsselbund-Dienste (Standard `ais-bot`; Testinstanzen nutzen einen eigenen)
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

EDITIONS = ("personal", "standard")
_ENV_EDITION = (os.environ.get("AISBOT_EDITION") or "").strip().lower()

if os.environ.get("AISBOT_HOME"):
    HOME = Path(os.path.expanduser(os.environ["AISBOT_HOME"]))
elif _ENV_EDITION == "standard":
    HOME = Path.home() / "Library/Application Support/AIS Scoops Server"
else:
    HOME = Path.home() / ".local/share/ais-bot"

CONFIG_PATH = os.environ.get("AISBOT_CONFIG") or str(HOME / "config.json")
DATA_DIR = Path(os.environ.get("AISBOT_DATA") or HOME / "data")
LOG_DIR = HOME / "logs"
KEYCHAIN_PREFIX = os.environ.get("AISBOT_KEYCHAIN_PREFIX") or "ais-bot"

# Persönliche Zusatzfunktionen (nur Armans Installation). Alle anderen Funktionen sind immer aktiv.
PERSONAL_FEATURES = (
    "vm",            # Bot-Rechner als Lume-VM (eingebauter Rechner `vm`, VM-Wächter)
    "lucy",          # Telefon-Assistentin Lucy (anrufen, anrufe_lesen)
    "t3",            # Programmieraufträge an T3 Code
    "teamapp",       # MLP Team App (MCP)
    "atrium",        # Atrium-Vault und Team-Bereiche
    "personal_hints",  # persönliche Prompt-Hinweise (Notion-Tasks, WhatsApp, Mail-Konten, Scoop-Namen)
)


def _read_config() -> dict:
    try:
        with open(CONFIG_PATH) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def edition(cfg: dict | None = None) -> str:
    cfg = _read_config() if cfg is None else cfg
    e = str(cfg.get("edition") or _ENV_EDITION or "personal").lower()
    return e if e in EDITIONS else "personal"


def is_personal(cfg: dict | None = None) -> bool:
    return edition(cfg) == "personal"


def feature(name: str, cfg: dict | None = None) -> bool:
    """Ist eine persönliche Zusatzfunktion aktiv? `features` in config.json hat Vorrang vor der Edition."""
    cfg = _read_config() if cfg is None else cfg
    flags = cfg.get("features") if isinstance(cfg.get("features"), dict) else {}
    if name in flags:
        return bool(flags[name])
    return is_personal(cfg)


def active_features(cfg: dict | None = None) -> frozenset:
    cfg = _read_config() if cfg is None else cfg
    return frozenset(f for f in PERSONAL_FEATURES if feature(f, cfg))


def kc(name: str) -> str:
    """Schlüsselbund-Dienst, z. B. kc("anthropic") → „ais-bot-anthropic“."""
    return f"{KEYCHAIN_PREFIX}-{name}"


def keychain_get(service: str, account: str) -> str | None:
    """Liest einen Eintrag aus dem Schlüsselbund des angemeldeten Nutzers (None, wenn er fehlt)."""
    r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                       capture_output=True, text=True)
    return (r.stdout.strip() or None) if r.returncode == 0 else None


def user_name(cfg: dict | None = None) -> str:
    """Wie die Scoops den Nutzer ansprechen: config `user_name`, sonst Name aus dem Konto, sonst neutral."""
    cfg = _read_config() if cfg is None else cfg
    if cfg.get("user_name"):
        return str(cfg["user_name"])
    if is_personal(cfg):
        return "Arman"
    owner = str(cfg.get("owner_name") or "").strip()
    if owner:
        return owner.split()[0]
    try:  # Vollständiger Name des macOS-Benutzers
        import pwd
        full = (pwd.getpwuid(os.getuid()).pw_gecos or "").strip()
        if full:
            return full.split()[0]
    except (KeyError, ImportError):
        pass
    return "du"
