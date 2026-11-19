"""Einzelne Aufgabe von der Kommandozeile (Test- und Wartungswerkzeug).

Nutzt dieselbe Engine wie die Bots, protokolliert jeden Lauf unter runs/<zeitstempel>/.
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

from .engine import DEFAULT_MODEL, ESCALATION_MODEL, ComputerHub, Engine
from .prompts import base_rules, now_line

RUNS_DIR = Path.home() / ".local/share/ais-bot/runs"


def run_task(
    task: str,
    *,
    model: str = DEFAULT_MODEL,
    escalation_model: str | None = ESCALATION_MODEL,
    effort: str = "medium",
    budget: float = 1.0,
    max_steps: int = 60,
    mcp_servers: list[dict] | None = None,
    hub: ComputerHub | None = None,
) -> dict:
    hub = hub or ComputerHub()
    run_dir = RUNS_DIR / datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    run_dir.mkdir(parents=True, exist_ok=True)
    w, h = hub.screen_size()
    system = (
        "Du bist ein AIS Bot und arbeitest selbstständig für Arman.\n\n" + base_rules(w, h)
        + "\n\nAntworte am Ende kurz auf Deutsch wie in einem Messenger."
    )
    print(f"▶ {task}\n  Modell {model} (Eskalation: {escalation_model or 'aus'}), Protokoll: {run_dir}", flush=True)
    out = Engine(hub).run(
        system=system,
        messages=[{"role": "user", "content": f"{now_line()}\n\n{task}"}],
        model=model,
        escalation_model=escalation_model,
        effort=effort,
        mcp_servers=mcp_servers,
        budget=budget,
        max_steps=max_steps,
        on_line=lambda s: print(f"  · {s}", flush=True),
        on_screenshot=lambda step, name, png: (run_dir / f"{step:03d}_{name}.png").write_bytes(png),
    )
    summary = {
        "aufgabe": task,
        "modell": model,
        "modell_ende": out.model_end,
        "schritte": out.steps,
        "stop_reason": out.stop_reason,
        "antwort": out.final_text,
        "kosten_usd": round(out.usage.dollars, 4),
        "usage": out.usage.as_dict(),
        "aktionen": out.lines,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"■ {out.stop_reason} nach {out.steps} Schritten · {out.usage.summary()}\n\n{out.final_text}", flush=True)
    return summary
