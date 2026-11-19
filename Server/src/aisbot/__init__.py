"""AIS Bot – Server und Kommandozeile.

  aisbot serve            Server starten (normalerweise per LaunchAgent)
  aisbot pair             Kopplungslink für die App ausgeben
  aisbot cloud-link       Server mit einem AIS-Scoops-Konto koppeln (Code für die App; --status, --force)
  aisbot run "Aufgabe"    Einzelne Aufgabe auf dem Bot-Rechner (Test)
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.parse

VM_NAME = "ais-bot-mac"


def vm_info(name: str = VM_NAME) -> dict:
    out = subprocess.run(["lume", "get", name, "--format", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or out.stdout.strip())
    s = out.stdout
    data = json.loads(s[s.find("["):] if "[" in s else s[s.find("{"):])
    return data[0] if isinstance(data, list) else data


def vm_ensure_running(name: str = VM_NAME, timeout: float = 240) -> None:
    """Startet die VM ohne Fenster, falls sie nicht läuft."""
    if vm_info(name).get("status") == "running":
        return
    subprocess.run(["lume", "run", name, "--display", "none", "--detach"], check=True, capture_output=True)
    deadline = time.time() + timeout
    while time.time() < deadline and vm_info(name).get("status") != "running":
        time.sleep(3)


def _pair_url() -> str:
    from .bots import load_config

    cfg = load_config()
    base = cfg.get("public_url") or "http://127.0.0.1:8787"
    return "aisbot://pair?" + urllib.parse.urlencode({"url": base, "token": cfg.get("api_token", "")})


def main() -> None:
    argv = sys.argv[1:]
    if argv and argv[0] == "serve":
        from .server import main as serve
        serve()
        return
    if argv and argv[0] == "pair":
        from .server import api_token
        api_token()
        print(_pair_url())
        return
    if argv and argv[0] == "cloud-link":
        from .cloud import cli_link
        cli_link(argv[1:])
        return
    if argv and argv[0] == "run":
        argv = argv[1:]

    from .agent import run_task
    from .computer import Computer
    from .engine import COMPUTER_URL
    from .server import mcp_servers

    p = argparse.ArgumentParser(prog="aisbot run", description="Eine Aufgabe auf dem Bot-Rechner erledigen lassen")
    p.add_argument("task", help="Aufgabe in natürlicher Sprache")
    p.add_argument("--model", default="claude-haiku-5-5", help="Startmodell (Standard: Haiku 5.5)")
    p.add_argument("--eskalation", default="claude-sonnet-5-5", help="Stärkeres Modell bei Bedarf ('aus' = keins)")
    p.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    p.add_argument("--budget", type=float, default=1.0, help="Kostengrenze in US-Dollar")
    p.add_argument("--max-steps", type=int, default=60)
    p.add_argument("--no-mcp", action="store_true", help="Ohne Composio und Team App")
    a = p.parse_args(argv)

    vm_ensure_running()
    Computer(COMPUTER_URL).wait_until_ready()
    s = run_task(a.task, model=a.model, escalation_model=None if a.eskalation == "aus" else a.eskalation,
                 effort=a.effort, budget=a.budget, max_steps=a.max_steps,
                 mcp_servers=[] if a.no_mcp else [m for m in mcp_servers() if m["type"] == "url"])
    sys.exit(0 if s["stop_reason"] == "end_turn" else 1)
