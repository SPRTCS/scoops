#!/usr/bin/env python3
"""String Catalogs der App AIS Scoops pflegen und prüfen (App/README.md „Sprachen“).

    scripts/strings.py build [--out DIR]          iOS-Simulator, macOS (ohne Signierung) und watchOS bauen (Stringsdata)
    scripts/strings.py sync  [--dd DIR …]         Localizable.xcstrings mit dem Quelltext abgleichen (xcstringstool sync)
    scripts/strings.py apply DATEI.json …         englische Übersetzungen einspielen (Format siehe unten)
    scripts/strings.py check [--dd DIR …]         Catalogs vollständig? Deutsche Texte am Catalog vorbei? (Exit 1 bei Fehlern)
    scripts/strings.py todo                       Einträge ohne Englisch auflisten (JSON-Vorlage für `apply`)

Ohne `--dd` nehmen `sync` und `check` die Builds aus `build` (Standard: $TMPDIR/scoops-strings). Die Prüfung braucht
die Stringsdata aller drei Plattformen, weil `#if os(macOS)`-Code nur im Mac-Build und die Uhr nur im watchOS-Build
übersetzt wird.

Format für `apply` (ein JSON-Array):
    {"de": "Wartet auf \\(name)", "en": "Waiting for \\(name)", "comment": "optional"}
    {"de": "\\(n) Aufgaben", "plural": {"de": {"one": "\\(n) Aufgabe", "other": "\\(n) Aufgaben"},
                                        "en": {"one": "\\(n) task", "other": "\\(n) tasks"}}}
`de` ist das Literal wie im Quelltext, Interpolationen als `\\(ausdruck)`; das Skript sucht den passenden Schlüssel
(Format-Platzhalter wie %@/%lld) und setzt im Englischen die Platzhalter, bei geänderter Reihenfolge mit Position.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
CATALOG = APP / "Shared/Localization/Localizable.xcstrings"
INFOPLIST_CATALOGS = sorted(APP.glob("*/InfoPlist.xcstrings")) + sorted(APP.glob("*/Resources/InfoPlist.xcstrings"))
SHORTCUTS = APP / "AISBot/Resources/AppShortcuts.xcstrings"
# Targets mit Texten aus dem gemeinsamen Catalog (ScoopsConnect hat eigene Catalogs, docs/sprache-serverapp.md)
TARGETS = ["AISBot", "AISBotWidgets", "AISBotNotifications", "AISBotShare", "AISBotWatch", "AISBotWatchWidgets"]
SOURCE_DIRS = ["AISBot", "Shared", "AISBotWidgets", "AISBotNotifications", "AISBotShare", "AISBotWatch",
               "AISBotWatchWidgets"]
DEFAULT_DD = Path(os.environ.get("TMPDIR", "/tmp")) / "scoops-strings"

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDuUxXoOfeEgGcCsSpaA])")


# MARK: - Hilfen

def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, data: dict) -> None:
    data["strings"] = dict(sorted(data["strings"].items(), key=lambda kv: kv[0]))
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf-8")


def specs(text: str) -> list[str]:
    """Platzhalter ohne Position, in Reihenfolge des Auftretens (bzw. nach Position, falls angegeben)."""
    found = []
    clean = text.replace("%%", "")
    for i, m in enumerate(SPEC.finditer(clean)):
        pos = int(m.group(1)) - 1 if m.group(1) else i
        found.append((pos, (m.group(2) or "") + m.group(3)))
    return [s for _, s in sorted(found)]


def skeleton_key(key: str) -> str:
    return SPEC.sub("\x00", key.replace("%%", "\x01")).replace("\x01", "%")


def split_literal(text: str) -> tuple[list[str], list[str]]:
    """Zerlegt ein Swift-Literal in Textstücke und Interpolationen (`\\(…)` mit geschachtelten Klammern)."""
    parts, exprs, buf, i = [], [], "", 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            parts.append(buf)
            exprs.append(text[i + 2:j - 1].strip())
            buf, i = "", j
        else:
            buf += text[i]
            i += 1
    parts.append(buf)
    return parts, exprs


def skeleton_literal(text: str) -> str:
    parts, _ = split_literal(text)
    return "\x00".join(parts)


def unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def has_letters(key: str) -> bool:
    rest = SPEC.sub("", key.replace("%%", ""))
    return re.search(r"[A-Za-zÄÖÜäöüß]{2,}", rest) is not None


# MARK: - build / sync

def build(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    jobs = [
        ("ios", ["-scheme", "AISBot", "-destination", "generic/platform=iOS Simulator"]),
        ("mac", ["-scheme", "AISBot", "-destination", "platform=macOS", "CODE_SIGNING_ALLOWED=NO"]),
        ("watch", ["-scheme", "AISBotWatch", "-destination", "generic/platform=watchOS Simulator"]),
    ]
    for name, args in jobs:
        print(f"→ {name} …", flush=True)
        log = out / f"{name}.log"
        with log.open("w") as fh:
            rc = subprocess.call(["xcodebuild", "-project", "AISBot.xcodeproj", *args, "-derivedDataPath", str(out / name), "build"], cwd=APP,
                                 stdout=fh, stderr=subprocess.STDOUT)
        if rc:
            sys.exit(f"Build {name} fehlgeschlagen, siehe {log}")


def stringsdata(dds: list[Path]) -> list[str]:
    files = []
    for dd in dds:
        for target in TARGETS:
            files += glob.glob(str(dd / f"**/{target}.build/**/*.stringsdata"), recursive=True)
    files = [f for f in files if "ExtractedAppShortcutsMetadata" not in f]
    if not files:
        sys.exit("Keine .stringsdata gefunden – erst `scripts/strings.py build` (SWIFT_EMIT_LOC_STRINGS=YES).")
    return files


def default_dds(args) -> list[Path]:
    if args.dd:
        return [Path(d) for d in args.dd]
    return [DEFAULT_DD / n for n in ("ios", "mac", "watch") if (DEFAULT_DD / n).exists()]


def sync(dds: list[Path]) -> None:
    files = stringsdata(dds)
    # xcstringstool nimmt viele Dateien; in Blöcken übergeben ginge nicht (jeder Aufruf würde den Rest „stale“ setzen)
    subprocess.check_call(["xcrun", "xcstringstool", "sync", str(CATALOG), "--stringsdata", *files])
    data = load(CATALOG)
    # Texte ohne Wörter („%@ · %@“, „%lld“) brauchen keine Übersetzung
    for key, entry in data["strings"].items():
        if not has_letters(key):
            entry["shouldTranslate"] = False
    save(CATALOG, data)
    stale = [k for k, e in data["strings"].items() if e.get("extractionState") == "stale"]
    print(f"{len(data['strings'])} Einträge, davon {len(stale)} veraltet.")


# MARK: - apply

def english_value(de_literal: str, en_literal: str, key: str) -> str:
    _, de_exprs = split_literal(de_literal)
    en_parts, en_exprs = split_literal(en_literal)
    key_specs = [m for m in SPEC.finditer(key.replace("%%", "\x01"))]
    spec_text = ["%" + (m.group(2) or "") + m.group(3) for m in key_specs]
    if len(spec_text) != len(de_exprs):
        raise ValueError(f"Platzhalter passen nicht: {key!r} ↔ {de_literal!r}")
    # (Mehrzahlformen mit weniger Platzhaltern laufen über literal_to_value)
    order = []
    remaining = list(range(len(de_exprs)))
    for e in en_exprs:
        idx = next((i for i in remaining if de_exprs[i] == e), None)
        if idx is None:
            raise ValueError(f"Interpolation {e!r} fehlt im Deutschen: {de_literal!r} → {en_literal!r}")
        remaining.remove(idx)
        order.append(idx)
    if remaining:
        raise ValueError(f"Interpolation fehlt im Englischen: {de_literal!r} → {en_literal!r}")
    positional = order != sorted(order)
    out = en_parts[0].replace("%", "%%")
    for k, idx in enumerate(order):
        s = spec_text[idx]
        out += (f"%{idx + 1}$" + s[1:]) if positional else s
        out += en_parts[k + 1].replace("%", "%%")
    return out


def polish(value: str) -> str:
    """Englische Typografie: Auslassungspunkte ohne Leerzeichen davor („Loading…“), wie Apple."""
    return re.sub(r"(?<=[\w)’”@]) …", "…", value)


def literal_to_value(literal: str, key: str) -> str:
    """Mehrzahlform (Literal) mit den Platzhaltern des Schlüssels. Eine Form ohne Zahl („1 Bild“, „one file“) ist erlaubt."""
    if not split_literal(literal)[1]:
        return literal.replace("%", "%%")
    return english_value(literal, literal, key)


def apply(paths: list[str]) -> None:
    data = load(CATALOG)
    by_skel: dict[str, list[str]] = {}
    for key in data["strings"]:
        by_skel.setdefault(skeleton_key(key), []).append(key)
    applied, missing, errors = 0, [], []
    for path in paths:
        for item in json.loads(Path(path).read_text(encoding="utf-8")):
            de = item.get("de", "")
            if "localizations" in item:
                # Fertige Catalog-Einträge, z. B. Mehrzahl mit mehreren Platzhaltern (`substitutions`)
                entry = data["strings"].get(item["key"])
                if entry is None:
                    missing.append(f"{Path(path).name}: Schlüssel {item['key']}")
                    continue
                entry["localizations"] = item["localizations"]
                applied += 1
                continue
            if "key" in item:
                # Eigener Schlüssel mit `defaultValue` (gleiches deutsches Wort, andere Bedeutung)
                entry = data["strings"].get(item["key"])
                if entry is None:
                    missing.append(f"{Path(path).name}: Schlüssel {item['key']}")
                    continue
                locs = entry.setdefault("localizations", {})
                locs["de"] = unit(de)
                locs["en"] = unit(polish(item["en"]))
                applied += 1
                continue
            keys = by_skel.get(skeleton_literal(de), [])
            if not keys:
                missing.append(f"{Path(path).name}: {de}")
                continue
            for key in keys:
                entry = data["strings"][key]
                try:
                    locs = entry.setdefault("localizations", {})
                    if "plural" in item:
                        for lang in ("de", "en"):
                            forms = item["plural"][lang]
                            locs[lang] = {"variations": {"plural": {
                                f: unit(polish(literal_to_value(v, key)) if lang == "en" else literal_to_value(v, key))
                                for f, v in forms.items()}}}
                    else:
                        locs["en"] = unit(polish(english_value(de, item["en"], key)))
                    if item.get("comment") and not entry.get("comment"):
                        entry["comment"] = item["comment"]
                    applied += 1
                except (ValueError, KeyError) as exc:
                    errors.append(f"{Path(path).name}: {exc}")
    save(CATALOG, data)
    print(f"{applied} Übersetzungen eingespielt.")
    if missing:
        print(f"{len(missing)} ohne passenden Schlüssel (nicht übersetzbar im Code oder Tippfehler):")
        for m in missing:
            print("  ", m)
    if errors:
        print(f"{len(errors)} Fehler:")
        for e in errors:
            print("  ", e)


# MARK: - check

def entry_problems(key: str, entry: dict, source_lang: str = "de") -> list[str]:
    if entry.get("shouldTranslate") is False:
        return []
    probs = []
    if entry.get("extractionState") == "stale":
        probs.append("veraltet (im Code nicht mehr benutzt)")
    en = entry.get("localizations", {}).get("en")
    if not en:
        return probs + ["ohne Englisch"]
    key_specs = sorted(specs(key))
    units = []
    if "stringUnit" in en:
        unit_ = dict(en["stringUnit"])
        # Mehrzahl mit mehreren Platzhaltern: „%#@n@“ steht für die Zahl (argNum, formatSpecifier)
        for name, sub in en.get("substitutions", {}).items():
            unit_["value"] = unit_["value"].replace(f"%#@{name}@", f"%{sub['argNum']}${sub['formatSpecifier']}")
            for form, u in sub.get("variations", {}).get("plural", {}).items():
                su = u.get("stringUnit", {})
                if su.get("state") != "translated":
                    probs.append(f"Englisch Mehrzahl {name}.{form} im Zustand „{su.get('state')}“")
                if re.search(r"[äöüÄÖÜß]", su.get("value", "")):
                    probs.append(f"Umlaut im Englischen: {su.get('value')!r}")
        units.append(("", unit_))
    for kind, forms in en.get("variations", {}).items():
        for form, u in forms.items():
            if "stringUnit" in u:
                units.append((f"{kind}.{form}", u["stringUnit"]))
    if "stringSet" in en:
        units.append(("set", {"state": en["stringSet"].get("state"), "value": " ".join(en["stringSet"]["values"])}))
    if not units:
        probs.append("Englisch leer")
    for form, u in units:
        if u.get("state") != "translated":
            probs.append(f"Englisch {form or ''} im Zustand „{u.get('state')}“".replace("  ", " "))
        value = u.get("value", "")
        if re.search(r"[äöüÄÖÜß]", value):
            probs.append(f"Umlaut im Englischen: {value!r}")
        if "${" not in key and sorted(specs(value)) != key_specs and not (form.startswith("plural") and
                                                                         set(specs(value)) <= set(key_specs)):
            probs.append(f"Platzhalter weichen ab: {value!r}")
    de = entry.get("localizations", {}).get("de", {})
    for kind, forms in de.get("variations", {}).items():
        for form, u in forms.items():
            v = u.get("stringUnit", {}).get("value", "")
            if not set(specs(v)) <= set(key_specs):
                probs.append(f"Platzhalter der deutschen Form {form} weichen ab: {v!r}")
    return probs


def check_catalogs() -> list[str]:
    errors = []
    for path in [CATALOG, SHORTCUTS, *INFOPLIST_CATALOGS]:
        data = load(path)
        for key, entry in data["strings"].items():
            for p in entry_problems(key, entry):
                errors.append(f"{path.relative_to(APP)}: {key!r}: {p}")
    return errors


# Deutsche Texte, die bewusst nicht übersetzt werden (Datei-Muster → Grund). Einzelne Zeilen markiert ein Kommentar
# `// nicht übersetzen: <Grund>` auf derselben oder der vorigen Zeile.
DEMO = "Demo-Inhalt, zweisprachig mit demoText/AppLanguage.isGerman (nicht im Catalog, App/README.md „Sprachen“)"
EXEMPT_FILES = {
    "AISBot/Support/InspectorBench.swift": "Messwerkzeug nur für Debug-Builds (-perfbench)",
    "AISBot/Support/MascotStyleSheet.swift": "Übersichtsblatt der Maskottchen für die Gestaltung (-render-assets)",
    "AISBot/Support/NotificationTestPush.swift": "Test-Mitteilungen nur für Debug-Builds (-localpush)",
    "Shared/System/SharedKeychain.swift": "Selbsttest des Schlüsselbunds (-keychainselftest), Ausgabe nur im Protokoll",
    "AISBot/Store/MockService.swift": DEMO,
    "AISBot/Store/PreviewData.swift": DEMO,
    "AISBot/Templates/MockService+Templates.swift": DEMO,
    "AISBot/Ruhe/MockService+Ruhe.swift": DEMO,
    "AISBot/Views/Today/TodayMock.swift": DEMO,
    "AISBot/Views/Tasks/TaskMock.swift": DEMO,
    "AISBot/Views/Usage/UsageMockData.swift": DEMO,
    "AISBot/Sharing/MockGuestData.swift": DEMO,
    "AISBot/Search/ComfortDemo.swift": DEMO,
    "AISBotWatch/Store/WatchDemo.swift": DEMO,
    "AISBot/Views/SidebarShrinkTest.swift": "Testwerkzeug nur für Debug-Builds (-sidebarshrinktest)",
    "AISBot/Support/AssetRenderer.swift": "rendert App-Symbol und Vorschaubilder (-render-assets), nicht im Betrieb",
    "AISBotWatch/Views/WatchPreviews.swift": "nur Xcode-Vorschauen",
}
# Zeilen, deren deutscher Text nicht auf der Oberfläche landet
EXEMPT_LINE = re.compile(
    r"(\blog(ger)?\.|\bLog\.|\bprint\(|NSLog\(|os_log\(|Logger\(|\.debug\(|\.notice\(|\.error\(\"|\.info\(|"
    r"fatalError\(|assert(ionFailure)?\(|precondition\(|#Preview|nicht übersetzen:|demoText\(|"
    # Rückgaben der Apple-Brücken an Server/Modell (Protokoll), Debug-Beschreibungen, Suchbegriffe der Befehlspalette
    # (beide Sprachen), Siri-Sätze (stehen in AppShortcuts.xcstrings), Sätze der Kurzbefehle (stehen als
    # `${parameter}`-Einträge von Hand im Catalog, der Compiler meldet sie nicht)
    r"Summary\(\"|AppleBridgeError\(|debugDescription:|Self\.log\(|keywords:|\\\(\.applicationName\))")
GERMAN_HINT = re.compile(r"[äöüÄÖÜß]|\b(der|die|das|und|nicht|mit|ist|ein|eine|einen|noch|auf|für|kein|keine|bitte|"
                         r"wird|werden|kann|du|dein|deine|ich|zu|von|bei|im|oder|schon|jetzt|alle|neu|neue|neuer|"
                         r"Einstellungen|Abbrechen|Speichern|Löschen|Fertig|Schließen|Weiter|Zurück)\b")


def source_literals(files: list[str]) -> list[tuple[str, int, str]]:
    """Alle Literale, die Schlüssel sein könnten (xcstringstool extract), als (Datei, Zeile, Text)."""
    out = []
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(0, len(files), 200):
            subprocess.check_call(["xcrun", "xcstringstool", "extract", "--all-potential-swift-keys", "--SwiftUI",
                                   "--modern-localizable-strings", "--omit-empty-stringsdata", "-o", tmp,
                                   *files[i:i + 200]], stdout=subprocess.DEVNULL)
        for f in Path(tmp).glob("*.stringsdata"):
            d = load(f)
            src = d["source"]
            for table, items in d["tables"].items():
                for it in items:
                    out.append((src, it["location"]["startingLine"], it["key"], table))
    return out


def compiler_locations(dds: list[Path]) -> set[tuple[str, int]]:
    locs = set()
    for f in stringsdata(dds):
        d = load(Path(f))
        src = os.path.realpath(d.get("source", ""))
        for items in d.get("tables", {}).values():
            for it in items:
                loc = it.get("location") or {}
                if "startingLine" in loc:
                    locs.add((src, loc["startingLine"]))
    return locs


def check_sources(dds: list[Path]) -> list[str]:
    files = []
    for d in SOURCE_DIRS:
        files += [str(p) for p in (APP / d).rglob("*.swift")]
    localized = compiler_locations(dds)
    lines_cache: dict[str, list[str]] = {}
    errors = []
    for src, line, key, table in source_literals(files):
        rel = os.path.relpath(src, APP)
        if rel in EXEMPT_FILES or table != "__PotentialKeys":
            continue
        if not GERMAN_HINT.search(key):
            continue
        if (os.path.realpath(src), line) in localized:
            continue
        lines = lines_cache.setdefault(src, Path(src).read_text(encoding="utf-8").splitlines())
        here = lines[line - 1] if line - 1 < len(lines) else ""
        before = lines[line - 2] if line >= 2 else ""
        if EXEMPT_LINE.search(here) or "nicht übersetzen:" in before or here.lstrip().startswith("//"):
            continue
        # zweites Argument von demoText über mehrere Zeilen
        if "demoText(" in before or re.search(r"^\s*en:", here):
            continue
        errors.append(f"{rel}:{line}: deutscher Text am Catalog vorbei: {key!r}")
    return errors


def check(dds: list[Path]) -> int:
    errors = check_catalogs()
    if dds:
        errors += check_sources(dds)
    else:
        print("Hinweis: ohne Builds nur die Catalogs geprüft (scripts/strings.py build).")
    for e in errors:
        print(e)
    data = load(CATALOG)
    print(f"{len(data['strings'])} Einträge in Localizable.xcstrings, {len(errors)} Probleme.")
    return 1 if errors else 0


def todo() -> None:
    data = load(CATALOG)
    items = [{"de": k, "en": ""} for k, e in data["strings"].items()
             if entry_problems(k, e) and e.get("extractionState") != "stale"]
    print(json.dumps(items, ensure_ascii=False, indent=1))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", default=str(DEFAULT_DD))
    for name in ("sync", "check"):
        p = sub.add_parser(name)
        p.add_argument("--dd", action="append")
    a = sub.add_parser("apply")
    a.add_argument("files", nargs="+")
    sub.add_parser("todo")
    args = ap.parse_args()
    if args.cmd == "build":
        build(Path(args.out))
    elif args.cmd == "sync":
        sync(default_dds(args))
    elif args.cmd == "apply":
        apply(args.files)
    elif args.cmd == "check":
        return check(default_dds(args))
    elif args.cmd == "todo":
        todo()
    return 0


if __name__ == "__main__":
    sys.exit(main())
