"""Anbindung an Lucy-Telefonie (Documents/Telefonie, Twilio + OpenAI GPT-Live-1).

Der Scoop-Server darf als launchd-Dienst nicht in Documents lesen. Deshalb startet er Lucys CLI
als eigenen launchd-Job mit genau dem Node, das auch Lucys Dienst nutzt und Zugriff hat.

Regeln aus Lucys Projekt (AGENTS.md / Skill ais-lucy-telefonie), die hier gelten:
- Ein Anruf nur nach ausdrücklicher Freigabe genau dieses Anrufs (Freigabe-Karte in der App).
- Die Ziel-Nummer wird nur für diesen einen Prozess freigegeben (TELEPHONY_ALLOWED_NUMBERS).
- Keine automatische Wiederwahl. Vor dem Anruf Betriebsbereitschaft prüfen.
- Lucys Dienst wird hier nie neu gestartet oder umkonfiguriert.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import time
from pathlib import Path

from .profile import HOME

# Lucy-Telefonie (optional, nur Edition „personal“): Pfade per Umgebung überschreibbar.
NODE = os.environ.get("AISBOT_LUCY_NODE", str(Path.home() / ".hermes/node/bin/node"))
CLI = os.environ.get("AISBOT_LUCY_CLI", str(Path.home() / "Documents/Telefonie/cli.mjs"))
WORK = HOME / "calls"
E164 = re.compile(r"^\+[1-9]\d{6,14}$")


def available() -> bool:
    return os.path.exists(NODE)


def normalize_number(n: str) -> str | None:
    n = re.sub(r"[\s\-/()]", "", n or "")
    if n.startswith("00"):
        n = "+" + n[2:]
    elif n.startswith("0"):
        n = "+49" + n[1:]
    return n if E164.match(n) else None


def run(args: list[str], env: dict | None = None, timeout: float = 60) -> tuple[int, str]:
    """Führt Lucys CLI GENAU EINMAL als launchd-Job aus und liefert (Exitcode, Ausgabe).

    Wichtig: Kein `launchctl submit` – solche Jobs startet launchd nach dem Ende automatisch neu
    (bei einem Anruf hieße das: erneut wählen). Stattdessen ein temporärer Job mit
    KeepAlive=false und LaunchOnlyOnce, der nach dem Ende sofort entfernt wird.
    """
    import plistlib

    WORK.mkdir(parents=True, exist_ok=True)
    os.chmod(WORK, 0o700)
    label = f"com.ais-bot.lucy.{secrets.token_hex(4)}"
    out = WORK / f"{label}.out"
    plist_path = WORK / f"{label}.plist"
    plist = {
        "Label": label,
        "ProgramArguments": [NODE, CLI, *args],
        "EnvironmentVariables": {**(env or {}), "PATH": "/usr/bin:/bin"},
        "RunAtLoad": True,
        "KeepAlive": False,
        "LaunchOnlyOnce": True,
        "AbandonProcessGroup": False,
        "StandardOutPath": str(out),
        "StandardErrorPath": str(out),
    }
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    domain = f"gui/{os.getuid()}"
    code: int | None = None
    started = False
    try:
        subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], check=True, capture_output=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(1.5)
            r = subprocess.run(["launchctl", "print", f"{domain}/{label}"], capture_output=True, text=True)
            if r.returncode != 0:
                break
            if re.search(r"\bpid = \d+", r.stdout):
                started = True
                continue
            m = re.search(r"last exit code = (-?\d+)", r.stdout)
            if m or started:
                code = int(m.group(1)) if m else 0
                break
        else:
            code = -1  # Zeitüberschreitung: Job wird unten beendet
    finally:
        # Job sofort entfernen, damit launchd ihn unter keinen Umständen erneut startet.
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True)
        plist_path.unlink(missing_ok=True)
    text = out.read_text(errors="replace") if out.exists() else ""
    out.unlink(missing_ok=True)
    return (code if code is not None else 0), text


def _json(text: str):
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    if start < 0:
        return None
    try:
        return json.loads(text[start:])
    except json.JSONDecodeError:
        # Ausgabe kann vor dem JSON Statuszeilen enthalten; letzten JSON-Block versuchen
        for m in reversed(list(re.finditer(r"^\{", text, re.M))):
            try:
                return json.loads(text[m.start():])
            except json.JSONDecodeError:
                continue
    return None


def status() -> dict:
    code, text = run(["service-status"], timeout=40)
    d = _json(text) or {}
    return d if isinstance(d, dict) else {}


def history(direction: str | None = None, since: str | None = None) -> list[dict]:
    args = ["history"]
    if direction in ("incoming", "outgoing"):
        args += ["--direction", direction]
    if since:
        args += ["--since", since]
    code, text = run(args, timeout=40)
    d = _json(text)
    return d if isinstance(d, list) else []


def show(call_id: str) -> str:
    if not re.match(r"^[\w:.\-]+$", call_id):
        return "Ungültige Protokoll-ID."
    code, text = run(["history-show", "--id", call_id], timeout=40)
    return text.strip()[:6000]


def place_call(number: str, brief: str, seconds: int | None = None) -> dict:
    """Startet einen freigegebenen Anruf und wartet bis zum Ende (max. ~12 Minuten)."""
    WORK.mkdir(parents=True, exist_ok=True)
    bf = WORK / f"auftrag-{secrets.token_hex(4)}.txt"
    bf.write_text(brief, encoding="utf-8")
    os.chmod(bf, 0o600)
    args = ["call", "--to", number, "--brief", str(bf), "--confirm"]
    if seconds:
        args += ["--seconds", str(int(seconds))]
    try:
        code, text = run(args, env={"TELEPHONY_ALLOWED_NUMBERS": number}, timeout=12 * 60)
    finally:
        bf.unlink(missing_ok=True)
    result = _json(text) if "{" in text else None
    return {"exit": code, "result": result if isinstance(result, dict) else None, "log": text[-1500:]}
