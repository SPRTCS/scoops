"""Englische Texte des Servers (docs/sprache.md). Schlüssel ist der deutsche Quelltext aus `tx`/`txn`/`N_`.

Je Bereich ein Modul mit `TEXTS = {"Deutsch": "English", …}`; Mehrzahl: `"{n} Schritt": ("{n} step", "{n} steps")`.
Gleiche deutsche Texte dürfen in mehreren Bereichen stehen, müssen dann aber gleich übersetzt sein
(tests/test_i18n.py prüft das, dazu fehlende, übrige und Platzhalter).
"""

from __future__ import annotations

from importlib import import_module

# Texte aus Datenquellen (JSON-Kataloge), die zur Laufzeit mit i18n.translate() übersetzt werden: "modul:funktion",
# die Funktion liefert die deutschen Texte (tests/test_i18n.py nimmt sie in die Prüfung auf).
DATA_SOURCES = ("aisbot.models_catalog:i18n_texts",)

AREAS = ("chat", "aufgaben", "server", "dienste", "engines", "kataloge")


def _load() -> tuple[dict, dict]:
    merged: dict = {}
    by_area: dict[str, dict] = {}
    for name in AREAS:
        texts = getattr(import_module(f"{__name__}.{name}"), "TEXTS", {})
        by_area[name] = texts
        for k, v in texts.items():
            merged.setdefault(k, v)
    return merged, by_area


TEXTS, BY_AREA = _load()
