"""Test der Übersetzungstabelle (docs/sprache.md): durchsucht den Quelltext nach übersetzbaren Texten (`tx`, `txn`,
`N_`) und prüft die englische Tabelle dagegen:

- jeder Text ist ein fester String (kein f-String, keine Verkettung zur Laufzeit),
- keiner fehlt in der Tabelle, keiner ist dort übrig,
- Platzhalter stimmen überein, und jeder Platzhalter wird beim Aufruf auch übergeben,
- Mehrzahl (`txn`) hat genau zwei englische Formen,
- gleiche Texte sind in allen Bereichen gleich übersetzt,
- englische Texte enthalten keine Umlaute oder ß (Ausnahmen: Eigennamen in ALLOW_UMLAUT).

Läuft ohne Server und ohne Netz:  cd Server && uv run python tests/test_i18n.py
"""

from __future__ import annotations

import ast
import os
import re
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("AISBOT_HOME", tempfile.mkdtemp(prefix="aisbot-i18n-test-"))
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "aisbot"
sys.path.insert(0, str(ROOT / "src"))

from aisbot import i18n  # noqa: E402
from aisbot.i18n_en import BY_AREA, TEXTS  # noqa: E402

MARKERS = {"tx": 1, "txn": 2, "N_": 1}
ALLOW_UMLAUT = re.compile(r"Köln|München|Düsseldorf|Zürich")

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def call_name(node: ast.Call) -> str | None:
    f = node.func
    if isinstance(f, ast.Name) and f.id in MARKERS:
        return f.id
    if isinstance(f, ast.Attribute) and f.attr in MARKERS and isinstance(f.value, ast.Name) and f.value.id == "i18n":
        return f.attr
    return None


def scan() -> dict[str, dict]:
    """{deutscher Text: {"kind": "tx"|"txn"|"N_", "plural": str|None, "where": [...]}}"""
    found: dict[str, dict] = {}
    files = [p for p in SRC.rglob("*.py") if "i18n_en" not in p.parts]
    for path in sorted(files):
        rel = path.relative_to(SRC.parent)
        tree = ast.parse(path.read_text(), str(path))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            name = call_name(node)
            if not name:
                continue
            where = f"{rel}:{node.lineno}"
            need = MARKERS[name]
            args = node.args[:need]
            if len(args) < need or not all(isinstance(a, ast.Constant) and isinstance(a.value, str) for a in args):
                err(f"{where}: {name}(…) braucht einen festen Text als erstes Argument (kein f-String, keine Variable)")
                continue
            key = args[0].value
            plural = args[1].value if name == "txn" else None
            kind = "txn" if name == "txn" else "tx"
            entry = found.setdefault(key, {"kind": kind, "plural": plural, "where": []})
            if entry["kind"] != kind:
                err(f"{where}: „{key}“ einmal als Mehrzahl, einmal ohne")
            entry["where"].append(where)
            # Platzhalter müssen beim Aufruf übergeben werden (tx/txn); N_ hat keine
            ph = i18n.placeholders(key) | (i18n.placeholders(plural) if plural else set())
            if name == "N_":
                continue
            given = {k.arg for k in node.keywords if k.arg}
            if any(k.arg is None for k in node.keywords):
                continue  # **kw: nicht prüfbar
            if name == "txn":
                given.add("n")
            missing = {p for p in ph if p.split(".")[0].split("[")[0] not in given}
            if missing:
                err(f"{where}: Platzhalter ohne Wert: {sorted(missing)} in „{key}“")
            if not ph and given - {"n"}:
                err(f"{where}: Werte übergeben, aber „{key}“ hat keine Platzhalter")
    return found


def check() -> int:
    found = scan()
    data_keys = set()
    # Texte aus Datenquellen (Kataloge in JSON), die zur Laufzeit mit translate() übersetzt werden
    from aisbot import i18n_en
    for src in getattr(i18n_en, "DATA_SOURCES", ()):
        mod, fn = src.split(":")
        for key in getattr(__import__(mod, fromlist=[fn]), fn)():
            data_keys.add(key)
            found.setdefault(key, {"kind": "tx", "plural": None, "where": [src]})
    for key, e in found.items():
        if key not in TEXTS:
            err(f"fehlt in der englischen Tabelle: „{key}“ ({e['where'][0]})")
            continue
        en = TEXTS[key]
        if e["kind"] == "txn":
            if not (isinstance(en, (tuple, list)) and len(en) == 2 and all(isinstance(x, str) for x in en)):
                err(f"Mehrzahl braucht zwei englische Formen: „{key}“")
                continue
            de_ph = i18n.placeholders(key) | i18n.placeholders(e["plural"]) | {"n"}
            for form in en:
                if not i18n.placeholders(form) <= de_ph:
                    err(f"Platzhalter passen nicht: „{key}“ → „{form}“")
        else:
            if not isinstance(en, str):
                err(f"Übersetzung muss ein Text sein: „{key}“")
                continue
            if i18n.placeholders(key) != i18n.placeholders(en):
                err(f"Platzhalter passen nicht: „{key}“ {sorted(i18n.placeholders(key))} → „{en}“ "
                    f"{sorted(i18n.placeholders(en))}")
        for form in (en if isinstance(en, (tuple, list)) else [en]):
            if re.search(r"[äöüÄÖÜß]", ALLOW_UMLAUT.sub("", str(form))):
                err(f"Umlaut im englischen Text: „{form}“")
            if not str(form).strip() and str(key).strip():
                err(f"Leere Übersetzung: „{key}“")
    extra = set(TEXTS) - set(found)
    for k in sorted(extra):
        err(f"übrig in der englischen Tabelle (kommt im Code nicht vor): „{k}“")
    seen: dict[str, tuple[str, object]] = {}
    for area, texts in BY_AREA.items():
        for k, v in texts.items():
            if k in seen and seen[k][1] != v:
                err(f"„{k}“ in {seen[k][0]} und {area} verschieden übersetzt")
            seen.setdefault(k, (area, v))
    return len(found)


def check_runtime() -> None:
    """Kleine Funktionsprüfung von tx/txn/translate und Accept-Language."""
    assert i18n.tx("Hallo {name}", name="A") == "Hallo A"
    assert i18n.txn("{n} Schritt", "{n} Schritte", 1) == "1 Schritt"
    assert i18n.txn("{n} Schritt", "{n} Schritte", 3) == "3 Schritte"
    assert i18n.from_accept_language("en-US,en;q=0.9,de;q=0.8") == "en"
    assert i18n.from_accept_language("fr-FR, de-DE;q=0.7, en;q=0.5") == "de"
    assert i18n.from_accept_language("fr, es") is None
    assert i18n.from_accept_language("en;q=0, de") == "de"
    assert i18n.normalize("EN_gb") == "en" and i18n.normalize("fr") is None
    assert i18n.request_lang(None, param="en", header="de") == "en"
    assert i18n.request_lang(None, header="en-US") == "en"
    assert i18n.current() == "de"
    with i18n.use("en"):
        assert i18n.current() == "en"
        assert [i18n.clock(h, m) for h, m in ((0, 5), (9, 0), (12, 30), (23, 59))] == \
            ["12:05 AM", "9:00 AM", "12:30 PM", "11:59 PM"]
    assert i18n.current() == "de"
    assert i18n.clock(9, 0) == "09:00" and i18n.clock(23, 59) == "23:59"


if __name__ == "__main__":
    print("Übersetzungstabelle gegen Quelltext (tx, txn, N_)")  # zweite Zeile: bin/test zeigt die letzte Zeile
    check_runtime()
    n = check()
    if errors:
        for e in errors[:200]:
            print("✗", e)
        print(f"\n{len(errors)} Fehler bei {n} übersetzbaren Texten")
        sys.exit(1)
    per_area = ", ".join(f"{a} {len(t)}" for a, t in BY_AREA.items())
    print(f"Bereiche: {per_area}")
    print(f"Alle {n} übersetzbaren Texte mit englischer Fassung.")
