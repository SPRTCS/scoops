"""Rechner-Zugriff der Scoops (docs/rechnerzugriff.md): Rechte-Modus und Bereich pro Scoop, pro Aufgabe wählbar.

Modus (wie viel ein Scoop ohne Rückfrage am Rechner tun darf):
- „Immer genehmigen“ (`ask`): Lesen im Bereich frei. Jeder verändernde Shell-Befehl und jede Dateiänderung außerhalb
  des Arbeitsordners braucht vorher eine Freigabe-Karte (ein Plan als eine Karte ist in Ordnung).
- „Automatisch“ (`auto`, Standard): frei im Bereich. Riskantes braucht eine Freigabe: Löschen oder Überschreiben
  außerhalb des Arbeitsordners, `git push`/Force, `rm -rf` auf breite Pfade, Installationen, `sudo`,
  Systemeinstellungen, Datei-Uploads ins Netz.
- „Vollzugriff“ (`full`): keine Rückfragen für lokale Arbeit.
In allen Modi gilt: Nach außen Wirkendes (Mail, Posten, Anrufen, Kaufen) läuft über die bestehenden Karten, und `sudo`
bzw. Passwörter gibt es nie ohne den Nutzer.

Bereich (wo ein Scoop arbeiten darf):
- „Nur Arbeitsordner“ (`workspace`): sein Ordner im Arbeitsordner (dazu bei Aufgaben deren eigener Ordner).
- „Projektordner“ (`projects`): zusätzlich ein oder mehrere gewählte Ordner.
- „Überall“ (`home`): das ganze Home.
Der Bereich ist eine harte Grenze: Pfade außerhalb werden abgelehnt (auch über `..` oder Symlinks). Ein Scoop kann ihn
für eine Aufgabe nur enger wählen, nie weiter als der Nutzer erlaubt hat.

Die Befehlsprüfung ist bewusst einfach (Wortlisten und Muster, wie die Freigabe-Regeln von Claude Code): Sie fängt die
typischen riskanten Befehle ab. Die harte Grenze für Shell-Befehle setzt die Sandbox (Aufgaben, Chat-Terminal).
"""

from __future__ import annotations

import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

MODES = {"ask": "Immer genehmigen", "auto": "Automatisch", "full": "Vollzugriff"}
SCOPES = {"workspace": "Nur Arbeitsordner", "projects": "Projektordner", "home": "Überall"}
DEFAULT_MODE, DEFAULT_SCOPE = "auto", "workspace"
MAX_FOLDERS = 12

# Zugangsdaten: Datei-Werkzeuge lesen sie nie, auch nicht mit Bereich „Überall“ (Git/SSH/gh im Terminal dürfen sie
# benutzen, der Scoop sieht sie aber nicht als Text).
SECRET_PARTS = (".ssh", ".aws", ".gnupg", ".netrc", ".appstoreconnect", "Library/Keychains", ".config/gh/hosts.yml",
                ".docker/config.json", ".npmrc", ".pypirc", ".git-credentials", ".kube/config",
                # Abo-Logins von Claude Code und Codex (docs/abos.md): nie als Datei lesen
                ".claude/.credentials.json", ".codex/auth.json")


class AccessError(ValueError):
    """Ungültige Einstellung (Text ist für Menschen gedacht)."""


# -- Einstellungen -------------------------------------------------------------------------------------------------------
def _pretty(p: str) -> str:
    home = str(Path.home())
    if p == home:
        return "~"
    return "~" + p[len(home):] if p.startswith(home + os.sep) else p


def _expand(raw: str, home: str | None = None) -> str:
    raw = str(raw or "").strip()
    h = home or str(Path.home())
    if raw == "~":
        return h
    if raw.startswith("~/"):
        return h + raw[1:]
    return raw


def clean_folders(raw, check: bool = True) -> list[str]:
    """Projektordner prüfen: absolut oder `~/…`, im Home, nicht das Home selbst, nicht ~/Library, ohne Doppelte.
    Gespeichert mit `~`. `check` = muss auf dem Server-Mac als Ordner existieren."""
    if raw is None:
        return []
    if isinstance(raw, str):
        raw = [x for x in re.split(r"[\n;]", raw) if x.strip()]
    if not isinstance(raw, list):
        raise AccessError("Projektordner: Liste von Pfaden erwartet.")
    home = os.path.realpath(str(Path.home()))
    out: list[str] = []
    for item in raw:
        s = str(item or "").strip()
        if not s:
            continue
        if "\x00" in s or len(s) > 500 or not (s.startswith("/") or s == "~" or s.startswith("~/")):
            raise AccessError(f"„{s}“ ist kein absoluter Pfad (beginnt mit / oder ~/).")
        real = os.path.realpath(_expand(s))
        if real == home or real == "/" or not (real.startswith(home + os.sep)):
            raise AccessError(f"„{s}“: Bitte einen Ordner innerhalb deines Home-Ordners wählen (für alles: Bereich „Überall“).")
        lib = os.path.join(home, "Library")
        if real == lib or real.startswith(lib + os.sep):
            raise AccessError(f"„{s}“ liegt in ~/Library. Bitte einen anderen Ordner wählen.")
        if check and not os.path.isdir(real):
            raise AccessError(f"„{_pretty(real)}“ gibt es nicht (oder ist kein Ordner).")
        p = _pretty(real)
        if p not in out:
            out.append(p)
    if len(out) > MAX_FOLDERS:
        raise AccessError(f"Höchstens {MAX_FOLDERS} Projektordner.")
    return out


def normalize(raw, check: bool = False) -> dict:
    """Einstellung aus DB/API → {mode, scope, folders}. Unbekanntes fällt auf den Standard zurück."""
    d = raw if isinstance(raw, dict) else {}
    mode = d.get("mode") if d.get("mode") in MODES else DEFAULT_MODE
    scope = d.get("scope") if d.get("scope") in SCOPES else DEFAULT_SCOPE
    try:
        folders = clean_folders(d.get("folders") or [], check=check)
    except AccessError:
        if check:
            raise
        folders = [str(x) for x in (d.get("folders") or []) if isinstance(x, str)][:MAX_FOLDERS]
    if scope == "projects" and not folders:
        scope = "workspace"
    return {"mode": mode, "scope": scope, "folders": folders if scope == "projects" else folders}


def validate(body: dict) -> dict:
    """Änderung über die API prüfen (mode, scope, folders). Fehler als AccessError mit lesbarem Text."""
    if not isinstance(body, dict):
        raise AccessError("Ungültige Einstellung.")
    if "mode" in body and body["mode"] not in MODES:
        raise AccessError("Modus: ask (Immer genehmigen), auto (Automatisch) oder full (Vollzugriff).")
    if "scope" in body and body["scope"] not in SCOPES:
        raise AccessError("Bereich: workspace (Nur Arbeitsordner), projects (Projektordner) oder home (Überall).")
    folders = clean_folders(body.get("folders"), check=True) if "folders" in body else None
    if body.get("scope") == "projects" and folders is not None and not folders:
        raise AccessError("Für „Projektordner“ bitte mindestens einen Ordner wählen.")
    out = {}
    for k in ("mode", "scope"):
        if k in body:
            out[k] = body[k]
    if folders is not None:
        out["folders"] = folders
    return out


def merge(current: dict, change: dict) -> dict:
    d = {**normalize(current), **change}
    if d["scope"] == "projects" and not d.get("folders"):
        raise AccessError("Für „Projektordner“ bitte mindestens einen Ordner wählen.")
    return normalize(d)


def public(setting: dict) -> dict:
    d = normalize(setting)
    return {**d, "mode_label": MODES[d["mode"]], "scope_label": SCOPES[d["scope"]]}


def summary(mode: str, scope: str, folders: list[str] | None = None) -> str:
    """„Automatisch · Projektordner (~/Code/App)“"""
    s = SCOPES.get(scope, scope)
    if scope == "projects" and folders:
        s += " (" + ", ".join(folders[:3]) + (" …" if len(folders) > 3 else "") + ")"
    return f"{MODES.get(mode, mode)} · {s}"


def narrow(allowed: dict, wanted: dict | None) -> dict:
    """Bereich, den ein Scoop selbst wählt (aufgabe_starten `ordner`): nie weiter als `allowed` (Scoop-Einstellung).
    Projektordner müssen in einem erlaubten Ordner liegen (bei „Überall“: irgendwo im Home)."""
    base = normalize(allowed)
    if not wanted:
        return {"scope": base["scope"], "folders": base["folders"]}
    scope = wanted.get("scope") or base["scope"]
    if scope == "workspace":
        return {"scope": "workspace", "folders": []}
    order = {"workspace": 0, "projects": 1, "home": 2}
    if order[scope] > order[base["scope"]]:
        raise AccessError(f"Der Bereich „{SCOPES[scope]}“ ist für diesen Scoop nicht freigegeben (erlaubt: "
                          f"{SCOPES[base['scope']]}). Nur der Nutzer kann ihn erweitern.")
    if scope == "home":
        return {"scope": "home", "folders": []}
    folders = clean_folders(wanted.get("folders") or base["folders"], check=True)
    if not folders:
        raise AccessError("Für „Projektordner“ bitte mindestens einen Ordner nennen.")
    if base["scope"] == "projects":
        roots = [os.path.realpath(_expand(f)) for f in base["folders"]]
        for f in folders:
            real = os.path.realpath(_expand(f))
            if not any(real == r or real.startswith(r + os.sep) for r in roots):
                raise AccessError(f"„{f}“ liegt nicht in den freigegebenen Projektordnern ({', '.join(base['folders'])}). "
                                  "Nur der Nutzer kann weitere Ordner freigeben.")
    return {"scope": "projects", "folders": folders}


def parse_ordner(value) -> dict | None:
    """Parameter `ordner` von aufgabe_starten: '' = wie Scoop, 'arbeitsordner', 'überall', 'projektordner'
    (= Projektordner des Scoops) oder Pfade (Zeilen oder ';' getrennt)."""
    s = str(value or "").strip()
    if not s:
        return None
    low = s.lower().replace("ü", "ue")
    if low in ("arbeitsordner", "nur arbeitsordner", "workspace"):
        return {"scope": "workspace"}
    if low in ("ueberall", "home", "ganzes home", "alles"):
        return {"scope": "home"}
    if low in ("projektordner", "projekte", "projects"):
        return {"scope": "projects"}
    return {"scope": "projects", "folders": [x.strip() for x in re.split(r"[\n;]", s) if x.strip()]}


# -- Wirksamer Zugriff eines Laufs ---------------------------------------------------------------------------------------
@dataclass
class Access:
    """Zugriff eines Chat-Laufs oder einer Aufgabe. Pfade mit `~` (werden auf dem jeweiligen Rechner aufgelöst)."""

    mode: str = DEFAULT_MODE
    scope: str = DEFAULT_SCOPE
    folders: list[str] = field(default_factory=list)
    workspace: str | None = None  # Ordner des Scoops im Arbeitsordner (~/Scoops/Codi)
    task_dir: str | None = None  # Arbeitsordner einer Aufgabe (absolut, nur auf dem Server-Mac)
    plan_approved: bool = False  # „Immer genehmigen“: Plan freigegeben → für diesen Abschnitt wie „Automatisch“
    user: str = "Arman"

    @property
    def effective_mode(self) -> str:
        return "auto" if self.mode == "ask" and self.plan_approved else self.mode

    def own_roots(self, home: str | None = None) -> list[str]:
        """Arbeitsordner (des Scoops und der Aufgabe): dort ist alles erlaubt."""
        out = [x for x in (self.task_dir, _expand(self.workspace, home) if self.workspace else None) if x]
        return [os.path.realpath(x) for x in out]

    def roots(self, home: str | None = None) -> list[str]:
        """Alle Ordner des Bereichs (realpath)."""
        h = home or str(Path.home())
        out = self.own_roots(h)
        if self.scope == "home":
            out.append(os.path.realpath(h))
        elif self.scope == "projects":
            out += [os.path.realpath(_expand(f, h)) for f in self.folders]
        seen: list[str] = []
        for r in out:
            if r not in seen:
                seen.append(r)
        return seen

    def label(self) -> str:
        return summary(self.mode, self.scope, self.folders)

    def describe(self, home_hint: str = "~") -> str:
        """Text für die Systemanweisung (Chat und Aufgaben)."""
        where = {"workspace": f"nur dein Arbeitsordner ({self.workspace or 'Arbeitsordner'})",
                 "projects": f"dein Arbeitsordner ({self.workspace or 'Arbeitsordner'}) und diese Projektordner: "
                             + ", ".join(self.folders),
                 "home": f"überall in {self.user}s Home-Ordner ({home_hint})"}[self.scope]
        mode = {"ask": (f"„Immer genehmigen“: Lesen im Bereich ist frei. Jeder Befehl, der etwas verändert, und jede "
                        f"Dateiänderung außerhalb deines Arbeitsordners braucht vorher {self.user}s Freigabe. Bündle das: "
                        "Leg einen Plan mit den nötigen Änderungen als eine Freigabe (freigabe_anfordern) vor; nach der "
                        "Freigabe darfst du die Schritte ausführen."),
                "auto": ("„Automatisch“: Du arbeitest im Bereich frei. Riskantes braucht eine Freigabe (die Werkzeuge "
                         "fragen dann selbst): Löschen oder Überschreiben außerhalb deines Arbeitsordners, git push und "
                         "Force-Befehle, rm -rf auf breite Pfade, Installationen (brew, npm -g, pip außerhalb einer venv), "
                         "sudo, Systemeinstellungen und Datei-Uploads ins Netz."),
                "full": ("„Vollzugriff“: Lokale Arbeit am Rechner braucht keine Rückfrage. sudo und Passwörter nie ohne "
                         f"{self.user}.")}[self.mode]
        return (f"Rechner-Zugriff: Bereich = {where}. Außerhalb davon liest und schreibst du nichts; den Bereich erweitern "
                f"kann nur {self.user}. Modus {mode} Nach außen Wirkendes (Mails, Posten, Anrufe, Käufe) läuft immer über "
                "die Freigabe-Karten.")


def within(path: str, roots: list[str]) -> bool:
    """Liegt `path` (realpath, Symlinks und `..` aufgelöst) in einem der Ordner?"""
    if not path:
        return False
    real = os.path.realpath(path)
    return any(real == r or real.startswith(r.rstrip(os.sep) + os.sep) for r in roots)


def is_secret(path: str, home: str | None = None) -> bool:
    h = os.path.realpath(home or str(Path.home()))
    real = os.path.realpath(path)
    try:  # eigener Codex-Login der Scoops (<data>/abo)
        from .profile import DATA_DIR
        abo = os.path.realpath(str(DATA_DIR / "abo"))
        if real == abo or real.startswith(abo + os.sep):
            return True
    except Exception:  # noqa: BLE001
        pass
    for part in SECRET_PARTS:
        p = os.path.join(h, part)
        if real == p or real.startswith(p + os.sep):
            return True
    return False


@dataclass
class Verdict:
    """Ergebnis einer Prüfung: ok (ausführen), ask (erst Freigabe-Karte) oder deny (nie, außerhalb des Bereichs)."""

    kind: str
    reason: str = ""

    @property
    def ok(self) -> bool:
        return self.kind == "ok"


OK = Verdict("ok")


def check_read(acc: Access, path: str, home: str | None = None) -> Verdict:
    if is_secret(path, home):
        return Verdict("deny", "Zugangsdaten (Schlüssel, Tokens) liest du nie als Datei.")
    if not within(path, acc.roots(home)):
        return Verdict("deny", f"{_pretty(os.path.realpath(path))} liegt außerhalb deines Bereichs ({acc.label()}). "
                               f"Erweitern kann ihn nur {acc.user}.")
    return OK


def check_write(acc: Access, path: str, kind: str, exists: bool, home: str | None = None) -> Verdict:
    """kind: create (neue Datei), edit (gezielt ersetzen), overwrite (ganze Datei ersetzen), delete."""
    real = os.path.realpath(path)
    if is_secret(real, home):
        return Verdict("deny", "Zugangsdaten änderst du nie.")
    if not within(real, acc.roots(home)):
        return Verdict("deny", f"{_pretty(real)} liegt außerhalb deines Bereichs ({acc.label()}). Erweitern kann ihn nur "
                               f"{acc.user}.")
    if within(real, acc.own_roots(home)):
        return OK
    mode = acc.effective_mode
    if mode == "full":
        return OK
    what = {"create": "Neue Datei", "edit": "Datei ändern", "overwrite": "Datei überschreiben",
            "delete": "Datei löschen"}.get(kind, "Datei ändern")
    if mode == "ask":
        return Verdict("ask", f"{what} außerhalb des Arbeitsordners: {_pretty(real)}")
    if kind == "delete" or (kind == "overwrite" and exists):
        return Verdict("ask", f"{what} außerhalb des Arbeitsordners: {_pretty(real)}")
    return OK


# -- Shell-Befehle ------------------------------------------------------------------------------------------------------
_SPLIT = re.compile(r"\|\||&&|;|\||\n|&(?!>)")
READ_ONLY = frozenset("""
ls cat head tail grep egrep fgrep rg ag find fd wc file stat du df pwd echo printf which whereis type whoami id date cal
uname sw_vers hostname env printenv uptime ps lsof mdfind mdls tree sort uniq cut tr awk sed jq yq column diff cmp comm
md5 shasum sha256sum xxd hexdump od strings otool nm true false test [ sleep basename dirname realpath readlink cd
export unset alias pbpaste man less more open curl wget log system_profiler ioreg sysctl vm_stat top locale tput clear
history set source . exit return local typeset declare
""".split())
_GIT_READ = frozenset("status log diff show rev-parse ls-files ls-tree blame describe grep shortlog reflog remote config "
                      "branch tag fetch cat-file show-ref for-each-ref worktree stash".split())
_RISK_SYSTEM = re.compile(
    r"^(defaults\s+(write|delete|import)|pmset\s+(?!-g)|networksetup\s+-set|systemsetup\s+-set|scutil\s+--set|nvram\b|"
    r"csrutil\b|spctl\s+--(master|global|add|enable|disable)|tccutil\b|launchctl\s+(load|unload|bootstrap|bootout|enable|"
    r"disable|submit|kickstart|remove)|crontab\b(?!\s+-l)|chsh\b|dscl\s+\S+\s+-(create|delete|append|passwd|change)|"
    r"sysadminctl\b|fdesetup\b|diskutil\s+(erase|partition|unmount|eject|apfs\s+delete|reformat)|kextload\b|kmutil\b|"
    r"shutdown\b|reboot\b|halt\b|softwareupdate\s+-(i|-install)|profiles\s+(install|remove)|chflags\b|chown\b|"
    r"systemextensionsctl\b|mdutil\s+-[aiEd]|tmutil\s+(delete|disable|enable|setdestination))")
_INSTALL = re.compile(
    r"^(brew\s+(install|reinstall|upgrade|uninstall|remove|rm|tap|untap|link|unlink|services|cask|bundle|autoremove|cleanup)|"
    r"(npm|pnpm)\s+(i|install|add|uninstall|remove|rm|update|up|link)\b.*\s(-g|--global)\b|yarn\s+global\b|"
    r"gem\s+(install|uninstall|update)|cargo\s+install|go\s+install|pipx\s+(install|uninstall|upgrade)|mas\s+(install|"
    r"uninstall|upgrade)|port\s+(install|uninstall|upgrade)|installer\b|uv\s+tool\s+install|"
    r"uv\s+pip\s+install\b.*--system)")
_PIP = re.compile(r"^((\S*/)?(pip3?(\.\d+)?)|(\S*/)?python3?(\.\d+)?\s+-m\s+pip)\s+(install|uninstall)\b")
_UPLOAD = re.compile(
    r"(^curl\b.*(\s-T\s|\s--upload-file\b|\s(-F|--form)\s+\S*@|\s(-d|--data|--data-binary|--data-raw|--data-urlencode)"
    r"\s+@)|^wget\b.*--post-file|^scp\b|^sftp\b|^ftp\b|^rsync\b.*\s[\w.@-]+:\S*|^gh\s+(gist\s+create|release\s+(create|"
    r"upload))|^gh\s+api\b.*\s-F\s+\S*=@|^aws\s+s3\s+(cp|sync|mv)\b.*\ss3://|^gsutil\s+(cp|rsync|mv)\b.*gs://|"
    r"^rclone\s+(copy|sync|move)\b|^croc\s+send\b|^(magic-)?wormhole\s+send\b|^nc\b.*<)")
_SECRET_CMD = re.compile(r"^(security\s+(find-(generic|internet)-password\b.*\s-[wg]\b|dump-keychain|"
                         r"unlock-keychain|export)|passwd\b|dscl\s+\S+\s+-passwd)")
_CURL_PIPE = re.compile(r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|)sh\b")
_SUDO = re.compile(r"(^|[\s;&|(`])(sudo|doas|su)(\s|$)")


def _words(cmd: str) -> list[str]:
    try:
        return shlex.split(cmd, comments=True, posix=True)
    except ValueError:
        return cmd.split()


def _strip_env(words: list[str]) -> list[str]:
    i = 0
    while i < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[i]):
        i += 1
    rest = words[i:]
    while rest and rest[0] in ("command", "builtin", "nohup", "time", "exec", "env", "noglob", "caffeinate"):
        rest = rest[1:]
        while rest and (rest[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", rest[0])):
            rest = rest[1:]
    return rest


def segments(cmd: str) -> list[str]:
    """Einzelbefehle (getrennt an ; && || | Zeilenumbruch und &), auch aus $(…) und `…`."""
    inner = re.findall(r"\$\(([^()]*)\)", cmd) + re.findall(r"`([^`]*)`", cmd)
    out = [s.strip() for s in _SPLIT.split(cmd) if s.strip()]
    for i in inner:
        out += [s.strip() for s in _SPLIT.split(i) if s.strip()]
    return out


def _redirects(seg: str) -> list[tuple[str, str]]:
    """Ausgabeumleitungen eines Befehls: [(op, ziel)], ohne /dev/null und &1/&2."""
    out = []
    for m in re.finditer(r"(?<![<0-9&])(&>>?|\d?>>?\|?)\s*(\"[^\"]+\"|'[^']+'|[^\s;&|<>]+)", seg):
        op, target = m.group(1), m.group(2).strip("'\"")
        if target.startswith("&") or target in ("/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"):
            continue
        out.append((">>" if ">>" in op else ">", target))
    return out


def _resolve(word: str, cwd: str, home: str) -> str:
    w = word
    if w == "~" or w.startswith("~/"):
        w = home + w[1:]
    w = w.replace("$HOME", home).replace("${HOME}", home)
    return os.path.normpath(os.path.join(cwd, w))


def _is_broad(path: str, home: str) -> bool:
    """`rm -rf` auf breite Pfade: /, Home, eine Ebene unter / oder Home (z. B. ~/Documents), Platzhalter dort."""
    p = path.rstrip("/") or "/"
    h = home.rstrip("/")
    if p in ("/", h, os.path.dirname(h)) or p.count("/") <= 2:
        return True
    if p.startswith(h + "/") and p[len(h) + 1:].count("/") == 0:
        return True
    return False


def _paths(words: list[str]) -> list[str]:
    return [w for w in words[1:] if not w.startswith("-")]


def assess_command(acc: Access, command: str, cwd: str | None = None, home: str | None = None,
                   exists=None, venv: bool = False) -> Verdict:
    """Braucht dieser Shell-Befehl vorher eine Freigabe? `exists(path)` prüft auf dem Zielrechner, ob eine Datei schon
    da ist (None = unbekannt, gilt dann als vorhanden). `venv` = in der Shell ist eine venv aktiv."""
    h = home or str(Path.home())
    cwd = cwd or (acc.task_dir or (_expand(acc.workspace, h) if acc.workspace else h))
    cmd = str(command or "").strip()
    if not cmd:
        return OK
    mode = acc.effective_mode
    if _SUDO.search(cmd):
        return Verdict("ask", "Befehl mit sudo (Administratorrechte)")
    own = acc.own_roots(h)
    roots = acc.roots(h)
    reasons: list[str] = []
    readonly = True
    for seg in segments(cmd):
        words = _strip_env(_words(seg))
        if not words:
            continue
        line = " ".join(words)
        head = os.path.basename(words[0])
        if head == "cd":
            cwd = _resolve(words[1], cwd, h) if len(words) > 1 and words[1] != "-" else h
            continue
        if _SECRET_CMD.match(line):
            return Verdict("ask", "Befehl liest oder ändert Passwörter bzw. den Schlüsselbund")
        risky = None
        if head == "git" and len(words) > 1:
            sub = words[1]
            if sub == "push":
                risky = "git push (lädt Änderungen hoch)"
            elif any(w in ("--force", "-f", "--force-with-lease") for w in words[2:]) and sub in ("push", "checkout",
                                                                                                    "branch", "clean"):
                risky = f"git {sub} mit Force"
            elif sub == "reset" and "--hard" in words:
                risky = "git reset --hard (verwirft Änderungen)"
            elif sub == "clean" and any(w.startswith("-") and "f" in w for w in words[2:]):
                risky = "git clean (löscht Dateien)"
            elif sub == "branch" and any(w in ("-D", "-d", "--delete") for w in words[2:]):
                risky = "Git-Branch löschen"
            if sub not in _GIT_READ or (sub == "branch" and len(words) > 2 and not words[2].startswith("--list")) \
                    or (sub == "remote" and len(words) > 2 and words[2] not in ("-v", "show", "get-url")) \
                    or (sub == "config" and not any(w in ("--get", "--list", "-l", "--get-all") for w in words)) \
                    or (sub == "tag" and len(words) > 2 and words[2] not in ("-l", "--list")) \
                    or (sub == "stash" and len(words) > 2 and words[2] not in ("list", "show")) \
                    or (sub == "worktree" and len(words) > 2 and words[2] != "list"):
                readonly = False
        elif head in ("rm", "rmdir", "unlink", "trash", "srm"):
            readonly = False
            rec = any(w.startswith("-") and ("r" in w.lower()) for w in words[1:])
            for w in _paths(words):
                p = _resolve(w, cwd, h)
                if rec and (_is_broad(p, h) or "*" in w and not within(os.path.dirname(p), own)):
                    risky = f"rm -r auf einen breiten Pfad ({w})"
                    break
                if not within(p, own):
                    risky = (f"Löschen außerhalb des Arbeitsordners ({w})" if within(p, roots)
                             else f"Löschen außerhalb deines Bereichs ({w})")
                    break
        elif head in ("mv", "cp", "ditto", "rsync", "ln", "install", "tee", "truncate", "dd"):
            readonly = False
            ps = _paths(words)
            if head == "dd":
                ps = [w.split("=", 1)[1] for w in words[1:] if w.startswith("of=")]
            if head == "tee" or head == "truncate":
                targets = ps
            elif head == "mv":
                targets = ps  # Quelle verschwindet, Ziel wird evtl. überschrieben
            else:
                targets = ps[-1:]
            for w in targets:
                p = _resolve(w, cwd, h)
                if within(p, own):
                    continue
                if not within(p, roots):
                    risky = f"Schreibt außerhalb deines Bereichs ({w})"
                    break
                if head == "mv" or head == "dd" or head == "truncate" or exists is None or exists(p) \
                        or (head == "rsync" and "--delete" in words):
                    risky = f"Überschreiben oder Verschieben außerhalb des Arbeitsordners ({w})"
                    break
        elif head in ("sed", "perl") and any(w.startswith("-i") or w == "-pi" for w in words[1:]):
            readonly = False
        elif head == "find" and any(w in ("-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint") for w in words):
            readonly = False
            if "-delete" in words:
                start = _resolve(next((w for w in words[1:] if not w.startswith("-")), "."), cwd, h)
                if not within(start, own):
                    risky = "find -delete außerhalb des Arbeitsordners"
        elif head in ("curl", "wget"):
            if any(w in ("-o", "-O", "--output", "--remote-name", "-X", "--request", "-d", "--data", "-F", "--form", "-T")
                   for w in words) or head == "wget" and "-O" not in words:
                readonly = False
        elif head == "awk" and re.search(r"system\s*\(|print[^;]*>", seg):
            readonly = False
        elif head == "open" and any(w in ("-e", "-t", "-f") for w in words):
            readonly = False
        elif head == "sed" or head in READ_ONLY:
            pass
        elif len(words) > 1 and all(w in ("--version", "-v", "-V", "--help", "-h", "version") for w in words[1:]):
            pass
        elif head in ("brew",) and len(words) > 1 and words[1] in ("list", "info", "search", "outdated", "--prefix",
                                                                     "config", "doctor", "deps", "uses", "leaves"):
            pass
        elif head in ("npm", "pnpm", "yarn") and len(words) > 1 and words[1] in ("ls", "list", "view", "info",
                                                                                 "outdated", "why", "config"):
            pass
        elif head in ("pip", "pip3") and len(words) > 1 and words[1] in ("list", "show", "freeze", "check"):
            pass
        elif head == "gh" and len(words) > 2 and words[2] in ("view", "list", "status", "diff", "checks"):
            pass
        elif head in ("security",) and len(words) > 1 and words[1].startswith("find-") and not any(
                w in ("-w", "-g") for w in words):
            pass
        else:
            readonly = False
        if risky is None and _RISK_SYSTEM.match(line):
            risky = "Systemeinstellung ändern"
        if risky is None and _INSTALL.match(line):
            risky = "Installation"
        if risky is None and _PIP.match(line) and not venv and not re.search(r"(^|/)(\.?venv|env|\.tox)/bin/", words[0]) \
                and "--target" not in words and "-t" not in words:
            risky = "pip install außerhalb einer venv"
        if risky is None and _UPLOAD.match(line):
            risky = "Datei-Upload ins Netz"
        for op, target in _redirects(seg):
            readonly = False
            p = _resolve(target, cwd, h)
            if within(p, own):
                continue
            if not within(p, roots):
                risky = risky or f"Schreibt außerhalb deines Bereichs ({target})"
                continue
            if op == ">" and (exists is None or exists(p)) and risky is None:
                risky = f"Überschreiben außerhalb des Arbeitsordners ({target})"
        if risky:
            reasons.append(risky)
    if _CURL_PIPE.search(cmd):
        reasons.append("Installationsskript aus dem Netz (curl | sh)")
        readonly = False
    if mode == "full":
        return OK
    if reasons:
        return Verdict("ask", reasons[0])
    if mode == "ask" and not readonly:
        return Verdict("ask", "Befehl verändert etwas (Modus „Immer genehmigen“)")
    return OK


# Eigene temporäre Ordner des Nutzers (/var/folders/…/T und …/C) als Parameter der Sandbox: Sie werden auf dem
# jeweiligen Rechner ermittelt (sandbox-exec -D …), nicht pauschal ganz /private/var/folders.
SANDBOX_PARAMS_SHELL = ('-D UTMP="${$(/usr/bin/getconf DARWIN_USER_TEMP_DIR):A}" '
                        '-D UCACHE="${$(/usr/bin/getconf DARWIN_USER_CACHE_DIR):A}"')


def sandbox_params_local() -> list[str]:
    import subprocess
    out = []
    for key, name in (("UTMP", "DARWIN_USER_TEMP_DIR"), ("UCACHE", "DARWIN_USER_CACHE_DIR")):
        try:
            v = subprocess.run(["/usr/bin/getconf", name], capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:  # noqa: BLE001
            v = ""
        out += ["-D", f"{key}={os.path.realpath(v) if v else '/private/tmp'}"]
    return out


def sandbox_profile(write_roots: list[str], deny_read: list[str] | None = None) -> str:
    """macOS-Sandbox (sandbox-exec): schreiben nur in `write_roots` (plus /private/tmp, die eigenen temporären Ordner
    über die Parameter UTMP/UCACHE und /dev), Netz erlaubt. Aufruf mit SANDBOX_PARAMS_SHELL bzw.
    sandbox_params_local()."""
    def q(p: str) -> str:
        return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'
    allow = " ".join(f"(subpath {q(os.path.realpath(p))})" for p in write_roots)
    deny = " ".join(f"(subpath {q(os.path.realpath(p))})" for p in (deny_read or []))
    out = ("(version 1)\n(allow default)\n"
           f"(deny file-write* (require-not (require-any {allow} (subpath \"/private/tmp\") "
           "(subpath (param \"UTMP\")) (subpath (param \"UCACHE\")) (subpath \"/dev\"))))\n")
    if deny:
        out += f"(deny file-read* {deny})\n"
    return out
