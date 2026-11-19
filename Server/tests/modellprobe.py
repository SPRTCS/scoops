"""Modellprobe (docs/modelle.md): Laufen die Modelle des Katalogs wirklich über die API-Schlüssel dieses Servers?

Je wählbarem Modell ein Minimalaufruf (wenige Tokens, zusammen deutlich unter einem Cent) mit dem Schlüssel, den der
Server ohnehin nutzt (Umgebung oder Schlüsselbund, wie config.anthropic_api_key / engine_openai._key). Schlüssel werden
nie ausgegeben. Modelle ohne passenden Schlüssel werden übersprungen. Kein Teil der normalen Tests (kostet Geld).

  Server/bin/modellprobe                 alle wählbaren Modelle
  Server/bin/modellprobe gpt-6.2-sol     nur bestimmte
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402

from aisbot import models_catalog  # noqa: E402


def claude(key: str, model: str) -> str:
    import anthropic
    r = anthropic.Anthropic(api_key=key, max_retries=1).messages.create(
        model=model, max_tokens=256, output_config={"effort": "low"},
        messages=[{"role": "user", "content": "Antworte nur mit OK."}])
    if r.stop_reason == "refusal":
        return "abgelehnt (refusal)"
    return "".join(b.text for b in r.content if b.type == "text").strip()[:40] or f"(leer, {r.stop_reason})"


def openai(key: str, model: str) -> str:
    r = httpx.post("https://api.openai.com/v1/responses", timeout=120,
                   headers={"Authorization": f"Bearer {key}"},
                   json={"model": model, "input": "Antworte nur mit OK.", "max_output_tokens": 256, "store": False})
    if r.status_code != 200:
        msg = (r.json().get("error") or {}).get("message", r.text) if r.headers.get("content-type", "").startswith(
            "application/json") else r.text
        raise RuntimeError(f"HTTP {r.status_code}: {str(msg)[:200]}")
    d = r.json()
    text = "".join(c.get("text", "") for o in d.get("output", []) if o.get("type") == "message"
                   for c in o.get("content", []))
    return text.strip()[:40] or f"(leer, {d.get('status')})"


def main() -> int:
    cat = models_catalog.current()
    wanted = set(sys.argv[1:])
    keys: dict[str, str | None] = {}
    try:
        from aisbot.config import anthropic_api_key
        keys["anthropic"] = anthropic_api_key()
    except Exception:  # noqa: BLE001
        keys["anthropic"] = None
    try:
        from aisbot.engine_openai import _key
        keys["openai"] = _key()
    except Exception:  # noqa: BLE001
        keys["openai"] = None
    print(f"Modellkatalog Version {cat.version} ({cat.source})")
    failed = 0
    for m in cat.selectable():
        if wanted and m.id not in wanted:
            continue
        key = keys[m.provider]
        if not key:
            print(f"  –  {m.id:<20} übersprungen (kein {m.provider}-Schlüssel)")
            continue
        try:
            out = (claude if m.provider == "anthropic" else openai)(key, m.id)
            print(f"  ✓  {m.id:<20} {out}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ✗  {m.id:<20} {type(e).__name__}: {str(e)[:200]}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
