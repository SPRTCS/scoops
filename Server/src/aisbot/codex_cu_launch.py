"""Startprogramm für den Computer-Use-Client von Codex (docs/computer.md, „Computer Use von Codex“).

Aufruf durch Codex (MCP-Server `computer-use` bzw. `notify`): `python -I codex_cu_launch.py <SkyComputerUseClient> mcp`.
Nur Standardbibliothek (läuft mit `-I`, ohne das Paket aisbot zu laden).

Warum es das gibt: Der Client holt sich seine Verbindung zum Dienst „Codex Computer Use“ per Apple Event. macOS prüft
dabei die Automations-Berechtigung des *verantwortlichen* Prozesses, und das wäre ohne dieses Programm der Scoops-Server
(bzw. das Terminal oder T3 Code, aus dem er gestartet wurde) – abgelehnt, ohne Rückfrage. Mit
`responsibility_spawnattrs_setdisclaim` wird der Client sein eigener verantwortlicher Prozess (wie bei Terminal-Apps
üblich); der Dienst erkennt ihn dann als eigenen Client. `POSIX_SPAWN_SETEXEC` ersetzt dieses Programm durch den Client,
sodass Codex der Elternprozess bleibt – das prüft der Dienst ebenfalls („Sender process is not authenticated“, wenn
nicht). Es werden keine macOS-Rechte erteilt oder verändert.
"""

import ctypes
import os
import sys

POSIX_SPAWN_SETEXEC = 0x0040


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write("Aufruf: codex_cu_launch.py <programm> [argumente …]\n")
        return 2
    prog = argv[0]
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        attr = ctypes.c_void_p()
        if libc.posix_spawnattr_init(ctypes.byref(attr)) != 0:
            raise OSError("posix_spawnattr_init")
        if libc.responsibility_spawnattrs_setdisclaim(ctypes.byref(attr), ctypes.c_int(1)) != 0:
            raise OSError("responsibility_spawnattrs_setdisclaim")
        if libc.posix_spawnattr_setflags(ctypes.byref(attr), ctypes.c_short(POSIX_SPAWN_SETEXEC)) != 0:
            raise OSError("posix_spawnattr_setflags")
        c_argv = (ctypes.c_char_p * (len(argv) + 1))(*[a.encode() for a in argv], None)
        env = [f"{k}={v}".encode() for k, v in os.environ.items()]
        c_env = (ctypes.c_char_p * (len(env) + 1))(*env, None)
        pid = ctypes.c_int()
        rc = libc.posix_spawn(ctypes.byref(pid), prog.encode(), None, ctypes.byref(attr), c_argv, c_env)
        # Mit SETEXEC kehrt posix_spawn nur bei einem Fehler zurück
        sys.stderr.write(f"Computer Use konnte nicht gestartet werden: {os.strerror(rc)}\n")
        return 127
    except (OSError, AttributeError) as e:
        # Ohne disclaim (z. B. älteres macOS): normal starten; der Dienst lehnt dann ggf. ab und Scoops fällt zurück
        sys.stderr.write(f"Computer Use ohne eigene Verantwortlichkeit gestartet ({e})\n")
        os.execv(prog, argv)
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
