"""Englische Texte: Engines (API, OpenAI, Abo), Rechner-Werkzeuge, Codex Computer Use, KI-Abos (siehe i18n_en/__init__.py)."""

TEXTS: dict = {
    # -- Statuszeilen der Läufe (engine.py, engine_openai.py, engine_abo.py) --------------------------------------------
    "Schaut auf den Bildschirm": "Looks at the screen",
    "Schaut genauer hin": "Takes a closer look",
    "Klickt": "Clicks",
    "Klickt doppelt": "Double-clicks",
    "Tippt": "Types",
    "Tippt „{text}“": "Types “{text}”",
    "Drückt {key}": "Presses {key}",
    "Drückt Tasten": "Presses keys",
    "Scrollt": "Scrolls",
    "Zieht": "Drags",
    "Bewegt die Maus": "Moves the mouse",
    "Arbeitet im Terminal": "Works in the terminal",
    "Öffnet ein Programm": "Opens an app",
    "Wartet kurz": "Waits a moment",
    "Holt sich Verstärkung": "Calls in a stronger model",
    "Fragt die Team App": "Checks the Team App",
    "Nutzt {app}": "Uses {app}",
    "Nutzt eine verbundene App": "Uses a connected app",
    "Sucht das passende Werkzeug": "Looks for the right tool",
    "Prüft die Verbindungen": "Checks the connections",
    "Wertet Daten aus": "Analyzes data",
    "Schaut in deinen Kalender": "Checks your calendar",
    "Schaut in {app}": "Checks {app}",
    "Wartet, bis der Rechner frei ist": "Waits for the computer to be free",
    "Wartet, bis der Bot-Rechner frei ist": "Waits for the bot computer to be free",
    "Fasst den bisherigen Verlauf zusammen": "Summarizes the conversation so far",
    "Sucht im Web": "Searches the web",
    "Sucht im Web: {query}": "Searches the web: {query}",
    "Liest eine Webseite": "Reads a web page",
    "Liest Dateien auf dem Mac": "Reads files on the Mac",
    "Arbeitet am Bildschirm": "Works on the screen",
    "Bildschirm über Scoops statt Codex Computer Use ({reason})": "Uses the Scoops screen instead of Codex Computer Use ({reason})",
    # -- Ende eines Laufs (Text als Antwort des Scoops) -----------------------------------------------------------------
    "Ich habe nach {steps} Schritten abgebrochen.": "I stopped after {steps} steps.",
    "Ich habe nach vielen Schritten abgebrochen.": "I stopped after many steps.",
    "Ich habe abgebrochen, weil die Kostengrenze von {budget:.2f} $ für diese Aufgabe erreicht ist.":
        "I stopped because the cost limit of ${budget:.2f} for this task was reached.",
    "Der Rechner ist in diesem Lauf nicht freigegeben.": "The computer isn't enabled for this run.",
    "Der Rechner antwortet gerade nicht (mehrmals kein Bildschirmfoto). Ich habe deshalb angehalten. Sag Bescheid, "
    "sobald er wieder erreichbar ist, dann mache ich weiter.":
        "The computer isn't responding right now (no screenshot several times), so I stopped. Let me know once it's "
        "reachable again and I'll continue.",
    "Ich habe am Bildschirm angehalten, weil OpenAI eine Sicherheitswarnung meldet: {warnings}. Soll ich trotzdem "
    "weitermachen?":
        "I paused on the screen because OpenAI reported a safety warning: {warnings}. Should I continue anyway?",
    "Quelle": "Source",
    "Quellen: {links}": "Sources: {links}",
    # -- Fehler, die als Antwort oder in den Einstellungen ankommen --------------------------------------------------
    "Abgebrochen, während auf den Bot-Rechner gewartet wurde": "Canceled while waiting for the bot computer",
    "Computer-Server nicht erreichbar": "Can't reach the computer server",
    "Kein OpenAI-Schlüssel im Schlüsselbund ({service})": "No OpenAI key in the keychain ({service})",
    "Claude Code ist nicht mit einem Claude-Abo angemeldet.": "Claude Code isn't signed in with a Claude subscription.",
    "Codex ist nicht mit ChatGPT angemeldet.": "Codex isn't signed in with ChatGPT.",
    "Claude-Code-Sitzung ließ sich nicht starten.": "The Claude Code session couldn't be started.",
    "Claude Code nutzt einen API-Schlüssel statt des Abo-Logins.":
        "Claude Code is using an API key instead of the subscription sign-in.",
    "Claude-Abo-Limit erreicht ({window})": "Claude subscription limit reached ({window})",
    "Limit": "limit",
    "Claude-Abo: {error}": "Claude subscription: {error}",
    "Claude-Code-Anmeldung abgelaufen": "Claude Code sign-in expired",
    "Interner Fehler im Scoops-Server: Eine Nachricht von Claude Code (meist ein Bildschirmbild) war zu groß für die "
    "Verbindung ({error}). Das ist keine abgebrochene Bildschirmverbindung; bitte so melden.":
        "Internal error in the Scoops server: a message from Claude Code (usually a screenshot) was too large for the "
        "connection ({error}). This isn't a dropped screen connection; please report it as such.",
    # -- KI-Abos (abos.py): Einstellungen, Einrichtung, Anmelde-Fenster -------------------------------------------------
    "API-Schlüssel": "API Key",
    "Abo": "Subscription",
    "Abo, bei Limit API": "Subscription, Then API",
    "Anbieter claude/openai, Modus api/abo/abo_api": "Provider claude/openai, mode api/abo/abo_api",
    "Anbieter claude oder openai": "Provider claude or openai",
    "Programm nicht gefunden (Server-Runtime unvollständig)": "Program not found (the server runtime is incomplete)",
    "Mit Claude anmelden – AIS Scoops nutzt danach dein Abo.":
        "Sign in with Claude so AIS Scoops can use your subscription.",
    "Mit ChatGPT anmelden – AIS Scoops nutzt danach dein Abo.":
        "Sign in with ChatGPT so AIS Scoops can use your subscription.",
    "Melde dich im Browser an, der sich gleich öffnet.": "Sign in using the browser window that opens next.",
    "Fertig. Dieses Fenster kannst du schließen.": "Done. You can close this window.",
    # -- Rechner-Werkzeuge (computer_tools.py): Statuszeilen und Freigabe-Karten ---------------------------------------
    "Liest {name}": "Reads {name}",
    "Durchsucht Dateien": "Searches files",
    "Bearbeitet {name}": "Edits {name}",
    "Schreibt {name}": "Writes to {name}",  # Datei schreiben und einem Scoop schreiben
    "Befehl ausführen: {command}": "Run command: {command}",
    "Befehl soll außerhalb deines Bereichs schreiben": "The command wants to write outside your scope",
    "Rechner: {computer}\nOrdner: {folder}": "Computer: {computer}\nFolder: {folder}",
    "Datei überschreiben: {name}": "Overwrite file: {name}",
    "Datei anlegen: {name}": "Create file: {name}",
    "Datei ändern: {name}": "Edit file: {name}",
    "Datei: {path}": "File: {path}",
    # -- Codex Computer Use (codex_cu.py) ---------------------------------------------------------------------------
    "Codex Computer Use ist auf dem Server-Mac nicht installiert. Einrichten: in der ChatGPT- bzw. Codex-App am "
    "Server-Mac Computer Use einmal einschalten (installiert „Codex Computer Use“ unter ~/.codex/computer-use) und die "
    "Rechte für Bedienungshilfen und Bildschirmaufnahme erteilen.":
        "Codex Computer Use isn't installed on the server Mac. To set it up, turn on Computer Use once in the ChatGPT "
        "or Codex app on the server Mac (this installs “Codex Computer Use” in ~/.codex/computer-use) and grant the "
        "Accessibility and Screen Recording permissions.",
    "Codex Computer Use fehlen macOS-Rechte. Am Server-Mac in Systemeinstellungen › Datenschutz & Sicherheit › "
    "Bedienungshilfen und › Bildschirm- & Systemaudioaufnahme „Codex Computer Use“ erlauben (bzw. dem Fenster von "
    "Computer Use folgen). Bis dahin arbeiten die Scoops über den Scoops-Bildschirm.":
        "Codex Computer Use is missing macOS permissions. On the server Mac, go to System Settings › Privacy & "
        "Security and allow “Codex Computer Use” under Accessibility and under Screen & System Audio Recording (or "
        "follow the Computer Use window). Until then, Scoops use the Scoops screen.",
    "Codex Computer Use ließ sich nicht starten ({detail}). Die Scoops arbeiten so lange über den Scoops-Bildschirm.":
        "Codex Computer Use couldn't start ({detail}). Until it does, Scoops use the Scoops screen.",
    "Codex Computer Use ist nicht installiert": "Codex Computer Use isn't installed",
    "Codex Computer Use fehlen macOS-Rechte": "Codex Computer Use is missing macOS permissions",
    "Codex Computer Use gerade gestört": "Codex Computer Use isn't working right now",
    "nur auf macOS": "macOS only",
    "nicht installiert": "not installed",
    "macOS-Rechte fehlen": "macOS permissions missing",
    "gestört": "not working",
    "eine App": "an app",
    "Aktion": "action",
    "Schaut auf {app}": "Looks at {app}",
    "Schaut, welche Apps offen sind": "Checks which apps are open",
    "Klickt in {app}": "Clicks in {app}",
    "Doppelklickt": "Double-clicks",
    "Doppelklickt in {app}": "Double-clicks in {app}",
    "Rechtsklickt": "Right-clicks",
    "Rechtsklickt in {app}": "Right-clicks in {app}",
    "Trägt „{text}“ ein": "Enters “{text}”",
    "Scrollt in {app}": "Scrolls in {app}",
    "Zieht in {app}": "Drags in {app}",
    "Markiert Text": "Selects text",
    "Markiert Text in {app}": "Selects text in {app}",
    "Führt „{action}“ aus": "Performs “{action}”",
    "Führt „{action}“ aus in {app}": "Performs “{action}” in {app}",
    "Macht am Bildschirm weiter": "Continues on the screen",
    "Pausiert: {user} hat den Bildschirm übernommen": "Paused: {user} took over the screen",
    "Der Mac ist gesperrt": "The Mac is locked",
    "Computer Use von Codex hat keine macOS-Rechte – nimmt den Scoops-Bildschirm":
        "Codex Computer Use lacks macOS permissions; uses the Scoops screen",
    "Computer Use von Codex fehlt – nimmt den Scoops-Bildschirm": "Codex Computer Use is missing; uses the Scoops screen",
    "Computer Use von Codex gestört – nimmt den Scoops-Bildschirm":
        "Codex Computer Use isn't working; uses the Scoops screen",
    "Computer Use wollte eine Webseite zur Anmeldung öffnen – abgelehnt":
        "Declined: Computer Use wanted to open a sign-in page",
    "Wartet auf Freigabe": "Waits for approval",
    "Wartet auf Freigabe: {app} bedienen": "Waits for approval to use {app}",
    "{app} nicht freigegeben": "{app} not approved",
    "Nicht freigegeben": "Not approved",
}
