"""Chat-Werkzeuge am Rechner wie bei Claude Code (docs/rechnerzugriff.md): persistente Shell und Datei-Werkzeuge.

- `terminal`: zsh-Befehl auf dem Rechner des Scoops. Pro Chat und Rechner bleiben aktueller Ordner und exportierte
  Umgebungsvariablen zwischen den Befehlen erhalten (eine „Sitzung“ im Server, kein dauerhaft offener Prozess).
  Auf echten Macs läuft der Befehl in einer macOS-Sandbox, die nur im Bereich schreiben lässt. Riskantes (nach Modus)
  und Schreiben außerhalb des Bereichs gehen erst nach einer Freigabe-Karte, dann ohne Sandbox.
- `rechner_datei_lesen` (Zeilenbereich), `rechner_dateien_suchen` (Namen per Glob, Inhalt per grep),
  `rechner_datei_ersetzen` (gezielt), `rechner_datei_schreiben`: nur im Bereich, über Scoops Connect bzw. direkt im
  Server-Prozess, wenn der Rechner der Server-Mac ist.

Lange Ausgaben werden gekürzt, mit Hinweis (Anfang und Ende bleiben sichtbar).
"""

from __future__ import annotations

import base64
import os
import re
import shlex
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import access as acc_mod
from . import workspace
from .engine import ExtraTool, status_line
from .i18n import tx

OUT_LIMIT = 12_000  # Zeichen stdout je Befehl (Anfang + Ende), stderr 4000
ERR_LIMIT = 4_000
READ_LINES = 400  # Standard-Zeilenzahl beim Lesen
READ_MAX_CHARS = 60_000
SEARCH_MAX = 200  # Treffer
WRITE_MAX = 2_000_000
STATE_MARK = "__SCOOPS_SHELL_STATE__"
# Variablen, die die Sitzung nicht übernimmt (ändern sich ohnehin bei jedem Start oder gehören der Shell)
_ENV_SKIP = frozenset({"PWD", "OLDPWD", "SHLVL", "_", "TMPDIR", "__CF_USER_TEXT_ENCODING", "TERM_SESSION_ID",
                       "SECURITYSESSIONID", "LaunchInstanceID", "XPC_SERVICE_NAME", "XPC_FLAGS", "COMMAND_MODE",
                       "ZSH_EXECUTION_STRING", "SANDBOX_PROFILE"})
# Schreibbar auch in der Sandbox: Caches und temporäre Ordner, sonst scheitern npm, pip & Co. an ihrem Cache
CACHE_DIRS = ("Library/Caches", ".cache", ".npm", ".yarn", ".pnpm-store", "Library/pnpm", ".bun/install/cache",
              ".gradle/caches", ".cargo/registry", ".zsh_history", ".zsh_sessions", ".lesshst", ".python_history",
              ".node_repl_history")


def clip(text: str, limit: int) -> str:
    """Kürzt mit Hinweis statt still: ein Drittel Anfang, zwei Drittel Ende."""
    text = text or ""
    if len(text) <= limit:
        return text
    head = limit // 3
    tail = limit - head
    cut = len(text) - limit
    return (text[:head] + f"\n[… {cut} Zeichen ausgelassen. Ganze Ausgabe: in eine Datei umleiten (> ausgabe.txt) und "
            "mit rechner_datei_lesen abschnittsweise lesen, oder mit grep/head/tail filtern …]\n" + text[-tail:])


@dataclass
class Session:
    cwd: str | None = None
    env: dict[str, str] = field(default_factory=dict)
    used: float = field(default_factory=time.time)


class Sessions:
    """Shell-Sitzungen je (Chat, Rechner). Nur im Speicher: Ein Neustart des Servers beginnt wieder im Arbeitsordner."""

    def __init__(self) -> None:
        self._d: dict[tuple[str, str], Session] = {}
        self.lock = threading.Lock()

    def get(self, chat_id: str, node_id: str) -> Session:
        with self.lock:
            s = self._d.get((chat_id, node_id))
            if s is None:
                s = self._d[(chat_id, node_id)] = Session()
            s.used = time.time()
            # alte Sitzungen (über 2 Tage) aufräumen
            for k in [k for k, v in self._d.items() if time.time() - v.used > 2 * 86400]:
                self._d.pop(k, None)
            return s

    def reset(self, chat_id: str) -> None:
        with self.lock:
            for k in [k for k in self._d if k[0] == chat_id]:
                self._d.pop(k, None)


SESSIONS = Sessions()


def wrap(command: str, sess: Session, default_cwd: str) -> str:
    """Skript für zsh: Ausgangsumgebung merken, gemerkte Variablen setzen, in den gemerkten Ordner wechseln, Befehl
    ausführen, danach Ordner und Umgebung hinter einer Marke ausgeben (auch bei `exit`, über den EXIT-Trap)."""
    lines = ["__scoops_b0=$(env -0 | /usr/bin/base64)",
             "__scoops_state() { print -rn -- $'\\n" + STATE_MARK + "'\"$PWD\"$'\\x1f'\"$__scoops_b0\"$'\\x1f'; "
             "env -0 | /usr/bin/base64; }"]
    for k, v in sess.env.items():
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            lines.append(f"export {k}={shlex.quote(v)}")
    cwd = sess.cwd or default_cwd
    lines.append(f"cd -- {shlex.quote(cwd)} 2>/dev/null || cd -- {shlex.quote(default_cwd)} 2>/dev/null || cd ~")
    lines.append("trap '__scoops_rc=$?; __scoops_state; exit $__scoops_rc' EXIT")
    return "\n".join(lines) + "\n" + command + "\n"


def _env(b64: str) -> dict[str, str] | None:
    try:
        raw = base64.b64decode(b64.strip()).decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return None
    return {k: v for k, v in (x.split("=", 1) for x in raw.split("\x00") if "=" in x)
            if k not in _ENV_SKIP and not k.startswith("__scoops")}


def parse_state(stdout: str, sess: Session) -> str:
    """Marke aus der Ausgabe nehmen, Ordner und geänderte Variablen (gegenüber der Login-Shell) in die Sitzung
    übernehmen. Gibt die bereinigte Ausgabe zurück."""
    mark = "\n" + STATE_MARK
    if mark not in stdout:
        return stdout
    out, _, state = stdout.rpartition(mark)
    parts = state.split("\x1f")
    if len(parts) < 3:
        return out
    cwd, base, after = parts[0].strip(), _env(parts[1]), _env(parts[2])
    if cwd:
        sess.cwd = cwd
    if base is not None and after is not None:
        sess.env = {k: v for k, v in after.items() if base.get(k) != v}
    return out


# -- Rechner (Server-Mac direkt oder über Scoops Connect) ---------------------------------------------------------------
class Target:
    """Der Rechner eines Scoops für Datei-Werkzeuge: direkt (Server-Mac) oder über den Transport (Scoops Connect/VM)."""

    def __init__(self, hub, db) -> None:
        self.hub = hub
        self.local = bool(db is not None and workspace.hub_on_server_mac(hub, db))
        mode = None
        if db is not None and hub.node_id != "vm":
            r = db.one("SELECT mode FROM nodes WHERE id=?", (hub.node_id,))
            mode = r["mode"] if r else None
        self.vm = hub.node_id == "vm" or mode == "vm"
        self._home: str | None = None

    @property
    def home(self) -> str:
        if self._home is None:
            self._home = str(Path.home()) if self.local else self.hub.expand_home("~")
        return self._home

    def shell(self, script: str) -> dict:
        """Befehl über den Rechner (Scoops Connect `run_command`, zsh -lc). Auch auf dem Server-Mac, damit Befehle mit
        der Identität von Scoops Connect laufen (Datenschutz-Freigaben, angemeldete Programme)."""
        return self.hub.computer.shell(script)

    def run(self, argv: list[str], timeout: float = 40) -> tuple[int, str, str]:
        """Hilfsbefehl (find, grep): auf dem Server-Mac direkt, sonst über den Rechner."""
        if self.local:
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, errors="replace")
                return r.returncode, r.stdout, r.stderr
            except subprocess.TimeoutExpired:
                return 124, "", f"nach {int(timeout)} s abgebrochen"
        d = self.hub.computer.shell(" ".join(shlex.quote(a) for a in argv))
        return int(d.get("return_code") or 0), d.get("stdout") or "", d.get("stderr") or ""

    def realpaths(self, paths: list[str]) -> list[str]:
        if self.local:
            return [os.path.realpath(p) for p in paths]
        if not paths:
            return []
        script = "for p in " + " ".join(shlex.quote(p) for p in paths) + "; do print -r -- ${p:A}; done"
        out = (self.hub.computer.shell(script).get("stdout") or "").splitlines()
        return out if len(out) == len(paths) else [os.path.normpath(p) for p in paths]

    def info(self, path: str) -> tuple[bool, bool]:
        """(existiert, ist Ordner)"""
        if self.local:
            return workspace.guarded(lambda: (os.path.exists(path), os.path.isdir(path)))
        d = self.hub.computer.shell(f"if [[ -d {shlex.quote(path)} ]]; then print d; elif [[ -e {shlex.quote(path)} ]]; "
                                    "then print f; else print n; fi")
        s = (d.get("stdout") or "").strip()
        return s in ("d", "f"), s == "d"

    def read(self, path: str, limit: int = 25_000_000) -> bytes:
        if self.local:
            def go() -> bytes:
                with open(path, "rb") as f:
                    return f.read(limit + 1)
            return workspace.guarded(go)
        d = self.hub.computer.cmd("read_bytes", path=path, length=limit + 1)
        return base64.b64decode(d["content_b64"])

    def write(self, path: str, data: bytes) -> None:
        if self.local:
            def go() -> None:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                tmp = path + ".scoops-tmp"
                with open(tmp, "wb") as f:
                    f.write(data)
                try:
                    st = os.stat(path)
                    os.chmod(tmp, st.st_mode & 0o7777)
                except OSError:
                    pass
                os.replace(tmp, path)
            workspace.guarded(go)
            return
        self.hub.computer.cmd("write_bytes", path=path, content_b64=base64.b64encode(data).decode())


def bot_access(svc, actor_id: str, override: dict | None = None, task_dir: str | None = None) -> acc_mod.Access:
    """Wirksamer Zugriff eines Scoops (Einstellung des Scoops, optional Bereich einer Aufgabe)."""
    from .bots import load_config
    r = svc.db.bot_row(actor_id)
    setting = acc_mod.normalize(svc.db.access_of(r) if r is not None else {})
    if override:
        setting.update({k: v for k, v in override.items() if k in ("scope", "folders")})
    try:
        ws = workspace.pretty(workspace.bot_dir(r if r is not None else {"id": actor_id}, load_config()))
    except Exception:  # noqa: BLE001
        ws = None
    return acc_mod.Access(mode=setting["mode"], scope=setting["scope"], folders=list(setting.get("folders") or []),
                          workspace=ws, task_dir=task_dir, user=svc.user_name)


class ComputerTools:
    """Werkzeuge eines Chat-Laufs (nicht für Gäste). `ask(title, details, action)` legt eine Freigabe-Karte an."""

    def __init__(self, svc, chat_id: str, actor_id: str, ask) -> None:
        self.svc, self.chat_id, self.actor_id, self.ask = svc, chat_id, actor_id, ask
        self._target: Target | None = None
        self._roots: tuple | None = None

    # -- Umgebung ------------------------------------------------------------------------------------------------------
    @property
    def target(self) -> Target:
        if self._target is None:
            self._target = Target(self.svc.hub_for(self.actor_id), self.svc.db)
        return self._target

    @property
    def access(self) -> acc_mod.Access:
        a = bot_access(self.svc, self.actor_id)
        if self.target.vm:
            a.scope, a.folders = "home", []  # eigene VM des Scoops: kein Bereich, nur der Modus gilt
        return a

    def session(self) -> Session:
        return SESSIONS.get(self.chat_id, self.target.hub.node_id)

    def default_cwd(self, a: acc_mod.Access) -> str:
        if a.workspace and not self.target.vm:
            return acc_mod._expand(a.workspace, self.target.home)
        return self.target.home

    def resolve(self, raw: str) -> str:
        """Pfad (absolut, ~ oder relativ zum Ordner der Shell-Sitzung) → absolut auf dem Rechner."""
        p = str(raw or "").strip()
        home = self.target.home
        if p == "~" or p.startswith("~/"):
            p = home + p[1:]
        if not p.startswith("/"):
            p = os.path.join(self.session().cwd or self.default_cwd(self.access), p)
        return os.path.normpath(p)

    def real_roots(self, a: acc_mod.Access) -> tuple[list[str], list[str]]:
        """(eigene Ordner, Bereich) als echte Pfade auf dem Rechner (Symlinks aufgelöst)."""
        home = self.target.home
        own = [acc_mod._expand(x, home) for x in ([a.workspace] if a.workspace else [])]
        scope = list(own)
        if a.scope == "home":
            scope.append(home)
        elif a.scope == "projects":
            scope += [acc_mod._expand(f, home) for f in a.folders]
        key = (tuple(own), tuple(scope))
        if self._roots and self._roots[0] == key:
            return self._roots[1], self._roots[2]
        real = self.target.realpaths(own + scope)
        self._roots = (key, real[:len(own)], real[len(own):])
        return self._roots[1], self._roots[2]

    def _scoped(self, a: acc_mod.Access) -> acc_mod.Access:
        """Access mit echten Pfaden des Rechners (für within/check_*)."""
        own, scope = self.real_roots(a)
        b = acc_mod.Access(mode=a.mode, scope="projects", folders=[], workspace=None, user=a.user)
        b.own_roots = lambda home=None, own=own: list(own)  # type: ignore[method-assign]
        b.roots = lambda home=None, scope=scope: list(scope)  # type: ignore[method-assign]
        b.label = lambda a=a: a.label()  # type: ignore[method-assign]
        return b

    def _real(self, path: str) -> str:
        return self.target.realpaths([path])[0]

    def _card(self, title: str, reason: str, action: dict, details: str) -> str:
        self.ask(title, f"{reason}\n\n{details}", {"kind": "rechner", "node_id": self.target.hub.node_id, **action})
        return (f"Freigabe angefragt ({reason}). Führe es NICHT anders aus. Nach {self.svc.user_gen} Freigabe führt der "
                "Server es aus und du bekommst das Ergebnis. Beende deine Antwort mit einem kurzen Satz.")

    # -- Shell ---------------------------------------------------------------------------------------------------------
    def sandbox_roots(self, a: acc_mod.Access) -> list[str]:
        own, scope = self.real_roots(a)
        home = self.target.home
        return list(dict.fromkeys(own + scope + [os.path.join(home, c) for c in CACHE_DIRS]))

    def execute_shell(self, command: str, sandboxed: bool) -> str:
        """Befehl in der Sitzung ausführen (für die Freigabe auch ohne Sandbox). Ausgabe wie beim alten `terminal`."""
        a = self.access
        sess = self.session()
        script = wrap(command, sess, self.default_cwd(a))
        if sandboxed and not self.target.vm:
            prof = acc_mod.sandbox_profile(self.sandbox_roots(a))
            script = (f"/usr/bin/sandbox-exec {acc_mod.SANDBOX_PARAMS_SHELL} -p {shlex.quote(prof)} "
                      f"/bin/zsh -c {shlex.quote(script)}")
        before = sess.cwd
        d = self.target.shell(script)
        out = parse_state(d.get("stdout") or "", sess)
        err = d.get("stderr") or ""
        rc = d.get("return_code")
        text = f"Rückgabecode {rc}\nstdout:\n{clip(out, OUT_LIMIT)}\nstderr:\n{clip(err, ERR_LIMIT)}"
        if sess.cwd and sess.cwd != before:
            text += f"\n[Ordner der Shell jetzt: {workspace.pretty(sess.cwd) if self.target.local else sess.cwd}]"
        if sandboxed and rc not in (0, None) and "operation not permitted" in (err + out).lower():
            text += ("\n[Hinweis: Schreiben außerhalb deines Bereichs ist gesperrt (Sandbox), oder macOS verweigert den "
                     "Zugriff (Datenschutz). Muss es wirklich außerhalb sein und will " + self.svc.user_name
                     + " das, ruf terminal mit ausserhalb_bereich: true auf; dann kommt eine Freigabe-Karte.]")
        return text

    def terminal(self, i: dict) -> str:
        command = str(i.get("command") or "").strip()
        if not command:
            return "Kein Befehl."
        a = self.access
        sess = self.session()
        cwd = sess.cwd or self.default_cwd(a)
        verdict = acc_mod.assess_command(self._scoped(a), command, cwd=cwd, home=self.target.home,
                                         exists=lambda p: self.target.info(p)[0], venv=bool(sess.env.get("VIRTUAL_ENV")))
        outside = bool(i.get("ausserhalb_bereich")) and not self.target.vm
        if verdict.kind == "ask" or outside:
            reason = verdict.reason if verdict.kind == "ask" else tx("Befehl soll außerhalb deines Bereichs schreiben")
            return self._card(tx("Befehl ausführen: {command}", command=command[:70]), reason,
                              {"op": "shell", "command": command, "chat_id": self.chat_id},
                              tx("Rechner: {computer}\nOrdner: {folder}", computer=self.target.hub.name, folder=cwd)
                              + f"\n\n$ {command}")
        if verdict.kind == "deny":
            return f"Abgelehnt: {verdict.reason}"
        return self.execute_shell(command, sandboxed=True)

    # -- Dateien -------------------------------------------------------------------------------------------------------
    def lesen(self, i: dict) -> str:
        path = self.resolve(i.get("pfad") or "")
        a = self.access
        v = acc_mod.check_read(self._scoped(a), self._real(path), self.target.home)
        if not v.ok:
            return f"Abgelehnt: {v.reason}"
        exists, is_dir = self.target.info(path)
        if not exists:
            return f"Nicht gefunden: {path}"
        if is_dir:
            return f"{path} ist ein Ordner. Inhalt mit rechner_dateien_suchen (art: name, muster: '*') oder terminal ls."
        data = self.target.read(path, 25_000_000)
        if b"\x00" in data[:8000]:
            return (f"Binärdatei ({len(data)} Bytes). Mit terminal auswerten (z. B. file, pdftotext, textutil -convert txt) "
                    "oder mit datei_vom_rechner in die Bibliothek holen.")
        text = data.decode("utf-8", "replace")
        lines = text.splitlines()
        start = max(1, int(i.get("ab_zeile") or 1))
        count = max(1, min(int(i.get("zeilen") or READ_LINES), 4000))
        part = lines[start - 1:start - 1 + count]
        width = len(str(start + len(part)))
        body, used = [], 0
        for n, line in enumerate(part, start):
            if len(line) > 2000:
                line = line[:2000] + " [… Zeile gekürzt]"
            row = f"{str(n).rjust(width)}\t{line}"
            if used + len(row) > READ_MAX_CHARS:
                body.append(f"[… weiter mit ab_zeile={n}]")
                break
            body.append(row)
            used += len(row) + 1
        end = start + len(part) - 1
        more = (f"\n[Zeilen {start}–{end} von {len(lines)}; weiter mit ab_zeile={end + 1}]" if end < len(lines)
                else f"\n[Ende, {len(lines)} Zeilen]")
        return "\n".join(body) + more

    def suchen(self, i: dict) -> str:
        a = self.access
        base = self.resolve(i.get("pfad") or ".")
        v = acc_mod.check_read(self._scoped(a), self._real(base), self.target.home)
        if not v.ok:
            return f"Abgelehnt: {v.reason}"
        art = str(i.get("art") or "name").lower()
        muster = str(i.get("muster") or "").strip()
        if not muster:
            return "Bitte ein Suchmuster angeben."
        if art.startswith("inh"):
            argv = ["/usr/bin/grep", "-rnIE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.venv",
                    "--exclude-dir=build", "--exclude-dir=DerivedData", "-m", "20"]
            if i.get("gross_klein_egal"):
                argv.append("-i")
            fm = str(i.get("dateimuster") or "").strip()
            if fm:
                argv.append(f"--include={fm}")
            argv += ["--", muster, base]
            rc, out, err = self.target.run(argv)
            if rc == 1 and not out:
                return "Keine Treffer."
            if rc not in (0, 1):
                return f"Fehler: {err.strip()[:500]}"
        else:
            # Glob wie bei Claude Code: '*.md', '**/*.swift', 'Sources/**/Test*'
            pattern = muster if "/" in muster or "**" in muster else f"**/{muster}"
            script = ("setopt extendedglob globdots nullglob; cd -- " + shlex.quote(base)
                      + " && for f in " + pattern.replace(" ", "\\ ") + "(N); do print -r -- \"$f\"; done | "
                      "/usr/bin/grep -v -E '(^|/)(\\.git|node_modules|\\.venv|DerivedData)/' | /usr/bin/head -n "
                      + str(SEARCH_MAX + 1))
            rc, out, err = self.target.run(["/bin/zsh", "-c", script])
            if rc not in (0, 1) and not out:
                return f"Fehler: {err.strip()[:500]}"
            if not out.strip():
                return "Keine Treffer."
        rows = out.splitlines()
        note = f"\n[mehr als {SEARCH_MAX} Treffer, Suche eingrenzen]" if len(rows) > SEARCH_MAX else ""
        return f"In {base}:\n" + "\n".join(r[:400] for r in rows[:SEARCH_MAX]) + note

    def _write_checked(self, path: str, kind: str, exists: bool, action: dict, title: str, details: str) -> str | None:
        """None = schreiben erlaubt; sonst Text (abgelehnt oder Karte angelegt)."""
        a = self.access
        real = self._real(path)
        v = acc_mod.check_write(self._scoped(a), real, kind, exists, self.target.home)
        if v.kind == "deny":
            return f"Abgelehnt: {v.reason}"
        if v.kind == "ask":
            return self._card(title, v.reason, action, details)
        return None

    def schreiben(self, i: dict) -> str:
        path = self.resolve(i.get("pfad") or "")
        content = str(i.get("inhalt") if i.get("inhalt") is not None else "")
        if len(content.encode()) > WRITE_MAX:
            return "Zu groß (höchstens 2 MB je Datei)."
        exists, is_dir = self.target.info(path)
        if is_dir:
            return f"{path} ist ein Ordner."
        blocked = self._write_checked(path, "overwrite" if exists else "create", exists,
                                      {"op": "write", "path": path, "content": content},
                                      (tx("Datei überschreiben: {name}", name=os.path.basename(path)) if exists
                                       else tx("Datei anlegen: {name}", name=os.path.basename(path))),
                                      tx("Datei: {path}", path=path) + f"\n\n{content[:1500]}"
                                      + (" …" if len(content) > 1500 else ""))
        if blocked:
            return blocked
        return self.apply_write(path, content, exists)

    def apply_write(self, path: str, content: str, existed: bool | None = None) -> str:
        self.target.write(path, content.encode("utf-8"))
        return f"{'Überschrieben' if existed else 'Geschrieben'}: {path} ({len(content.encode())} Bytes)."

    def ersetzen(self, i: dict) -> str:
        path = self.resolve(i.get("pfad") or "")
        old, new = str(i.get("alt") or ""), str(i.get("neu") if i.get("neu") is not None else "")
        if not old:
            return "alt fehlt (genauer Text, der ersetzt werden soll)."
        if old == new:
            return "alt und neu sind gleich."
        exists, is_dir = self.target.info(path)
        if not exists or is_dir:
            return f"Datei nicht gefunden: {path}"
        a = self.access
        v = acc_mod.check_read(self._scoped(a), self._real(path), self.target.home)
        if v.kind == "deny":
            return f"Abgelehnt: {v.reason}"
        text = self.target.read(path, WRITE_MAX).decode("utf-8", "replace")
        n = text.count(old)
        if n == 0:
            return "Der Text unter alt kommt in der Datei nicht vor (genau so, mit Leerzeichen und Einrückung)."
        alle = bool(i.get("alle"))
        if n > 1 and not alle:
            return f"alt kommt {n}-mal vor. Mehr Kontext angeben, damit es eindeutig ist, oder alle: true."
        updated = text.replace(old, new) if alle else text.replace(old, new, 1)
        blocked = self._write_checked(path, "edit", True, {"op": "edit", "path": path, "old": old, "new": new, "all": alle},
                                      tx("Datei ändern: {name}", name=os.path.basename(path)),
                                      tx("Datei: {path}", path=path) + f"\n\n− {old[:700]}\n+ {new[:700]}")
        if blocked:
            return blocked
        self.target.write(path, updated.encode("utf-8"))
        return f"Ersetzt ({n if alle else 1}×) in {path}."

    def apply_edit(self, path: str, old: str, new: str, alle: bool) -> str:
        text = self.target.read(path, WRITE_MAX).decode("utf-8", "replace")
        if old not in text:
            return "Der Text kommt inzwischen nicht mehr vor; nichts geändert."
        self.target.write(path, (text.replace(old, new) if alle else text.replace(old, new, 1)).encode("utf-8"))
        return f"Geändert: {path}."

    # -- Werkzeugliste -------------------------------------------------------------------------------------------------
    def tools(self) -> list[ExtraTool]:
        s = {"type": "string"}
        user = self.svc.user_name

        def mk(name, desc, props, req, fn, line):
            return ExtraTool({"name": name, "description": desc,
                              "input_schema": {"type": "object", "properties": props, "required": req,
                                               "additionalProperties": False}}, fn, line)

        def safe(fn):
            def run(i: dict):
                try:
                    return fn(i)
                except workspace.WorkspaceError as e:
                    return f"Fehler: {e}"
                except Exception as e:  # noqa: BLE001
                    return f"Fehler: {e}"
            return run

        return [
            mk("terminal", "Führt einen Shell-Befehl (zsh) auf deinem Rechner aus und liefert stdout, stderr und Rückgabecode. "
               "Die Shell bleibt pro Chat erhalten: Ordner (cd) und exportierte Variablen (z. B. eine aktivierte venv) gelten "
               "für die nächsten Befehle. Für Dateien, Git, Skripte, Programme starten (z. B. `open -a Safari https://…`). "
               "Geschrieben wird nur in deinem Bereich (Sandbox); riskante Befehle bekommen automatisch eine Freigabe-Karte. "
               f"ausserhalb_bereich: true nur, wenn {user} ausdrücklich will, dass ein Befehl außerhalb deines Bereichs "
               "schreibt (dann Freigabe-Karte, danach ohne Sandbox).",
               {"command": {"type": "string", "description": "Der auszuführende Befehl"},
                "ausserhalb_bereich": {"type": "boolean"}}, ["command"], safe(self.terminal),
               lambda i: status_line("terminal", i)),
            mk("rechner_datei_lesen", "Liest eine Textdatei auf deinem Rechner mit Zeilennummern (pfad absolut, ~ oder relativ zum "
               "Ordner der Shell). ab_zeile/zeilen für Abschnitte (Standard 400 Zeilen).",
               {"pfad": s, "ab_zeile": {"type": "integer"}, "zeilen": {"type": "integer"}}, ["pfad"], safe(self.lesen),
               lambda i: tx("Liest {name}", name=os.path.basename(str(i.get("pfad") or ""))).strip()),
            mk("rechner_dateien_suchen", "Sucht auf deinem Rechner in deinem Bereich. art 'name': Dateien per Glob (muster z. B. "
               "'*.md', '**/*.swift'); art 'inhalt': Text per Regex (grep -E) in Dateien, optional dateimuster wie '*.py'. "
               "pfad = Startordner (Standard: Ordner der Shell).",
               {"muster": s, "art": {"type": "string", "enum": ["name", "inhalt"]}, "pfad": s, "dateimuster": s,
                "gross_klein_egal": {"type": "boolean"}}, ["muster"], safe(self.suchen), lambda i: tx("Durchsucht Dateien")),
            mk("rechner_datei_ersetzen", "Ersetzt in einer Datei auf deinem Rechner genau einen Textabschnitt (alt → neu), wie ein "
               "Editor. alt muss genau so (mit Einrückung) und eindeutig vorkommen; alle: true ersetzt jedes Vorkommen. "
               "Vorher mit rechner_datei_lesen ansehen.",
               {"pfad": s, "alt": s, "neu": s, "alle": {"type": "boolean"}}, ["pfad", "alt", "neu"], safe(self.ersetzen),
               lambda i: tx("Bearbeitet {name}", name=os.path.basename(str(i.get("pfad") or ""))).strip()),
            mk("rechner_datei_schreiben", "Schreibt eine Textdatei auf deinem Rechner (legt Ordner an; eine vorhandene Datei wird "
               "ganz ersetzt – für kleine Änderungen rechner_datei_ersetzen).",
               {"pfad": s, "inhalt": s}, ["pfad", "inhalt"], safe(self.schreiben),
               lambda i: tx("Schreibt {name}", name=os.path.basename(str(i.get("pfad") or ""))).strip()),
        ]


FILE_TOOL_NAMES = frozenset({"terminal", "rechner_datei_lesen", "rechner_dateien_suchen", "rechner_datei_ersetzen",
                             "rechner_datei_schreiben"})


def run_approved(svc, chat_id: str, actor_id: str, action: dict) -> str:
    """Nach der Freigabe einer Rechner-Karte (bots.decide): ausführen und das Ergebnis als Text liefern."""
    ct = ComputerTools(svc, chat_id, actor_id, ask=lambda *a, **k: None)
    op = action.get("op")
    if op == "shell":
        return ct.execute_shell(str(action.get("command") or ""), sandboxed=False)
    if op == "write":
        return ct.apply_write(str(action["path"]), str(action.get("content") or ""), True)
    if op == "edit":
        return ct.apply_edit(str(action["path"]), str(action.get("old") or ""), str(action.get("new") or ""),
                             bool(action.get("all")))
    return "Unbekannte Aktion."


# Nur mit Festplattenvollzugriff lesbar, ohne dass macOS je einen Dialog zeigt (geschützte Kategorien fragen nicht).
# Die System-Datenbank gibt es auf jedem Mac; die anderen sind Rückfall (z. B. ältere Systeme).
FDA_PROBES = ("/Library/Application Support/com.apple.TCC/TCC.db",
              "~/Library/Application Support/com.apple.TCC/TCC.db", "~/Library/Safari", "~/Library/Mail")


def full_disk_access() -> dict:
    """Festplattenvollzugriff des Server-Prozesses prüfen, ohne eine Abfrage auszulösen: Lesetest auf Dateien, die nur
    mit Festplattenvollzugriff lesbar sind (ohne liefert macOS sofort „Operation not permitted“). `granted` None =
    nicht prüfbar (keine der Dateien vorhanden)."""
    import sys
    exe = os.path.realpath(sys.executable)
    m = re.search(r"^(.*?\.app)/", exe)
    app = m.group(1) if m else None
    granted = None
    for raw in FDA_PROBES:
        p = os.path.expanduser(raw)
        try:
            if os.path.isdir(p):
                os.listdir(p)
            else:
                with open(p, "rb") as f:
                    f.read(16)
            granted = True
            break
        except FileNotFoundError:
            continue
        except OSError:
            granted = False
            break
    who = (os.path.basename(app)[:-4] if app else os.path.basename(exe))
    return {"granted": granted, "process": who, "path": app or exe, "app": bool(app),
            "settings_url": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"}
