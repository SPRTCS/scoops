"""Englische Texte: Chat, Läufe, Freigabe-Karten, Ereigniszeilen, Statuszeilen der Chat-Werkzeuge, Nachricht bearbeiten
(bots.py, chat_edit.py; siehe i18n_en/__init__.py)."""

TEXTS: dict = {
    # -- Fehler als Antwort im Chat ---------------------------------------------------------------------------------
    "Da ist bei mir etwas schiefgelaufen: {error}": "Something went wrong on my end: {error}",
    "Über das {who}-Abo geht es gerade nicht: {reason} In der Server-App unter „KI-Abos“ anmelden oder dort "
    "„Abo, bei Limit API“ bzw. „API-Schlüssel“ wählen.":
        "The {who} subscription isn't working right now: {reason} Sign in under “AI Subscriptions” in the server app, "
        "or choose “Subscription, Then API” or “API Key” there.",
    "Die Verbindung zum KI-Anbieter ist gerade abgerissen, auch nach mehreren Versuchen. "
    "Schick mir die Nachricht bitte gleich noch einmal.":
        "I lost the connection to the AI provider, even after several retries. Please send your message again in a "
        "moment.",
    "Tageslimit erreicht: Für heute ist dein Budget von {budget:.2f} $ aufgebraucht. "
    "Morgen geht es weiter – oder frag {owner}, ob das Limit erhöht werden kann.":
        "Daily limit reached: you've used today's budget of ${budget:.2f}. Try again tomorrow, or ask {owner} to "
        "raise the limit.",
    " Sag „mach weiter“, dann setze ich genau dort fort.": " Say “continue” and I'll pick up right where I left off.",
    "Aufgabe nicht gestartet: {error}": "Task not started: {error}",

    # -- Ereigniszeilen -----------------------------------------------------------------------------------------------
    "{name} ist da": "{name} is here",
    "Gruppe „{name}“ mit {names}": "Group “{name}” with {names}",
    "Angehalten": "Stopped",
    "Ergebnis: {name}": "Result: {name}",
    "Routine: {title}": "Routine: {title}",
    "Routine angelegt: {title} · {schedule}": "Routine created: {title} · {schedule}",
    "Routine geändert: {title}": "Routine updated: {title}",
    "Routine gelöscht: {title}": "Routine deleted: {title}",
    "Erinnerung gesetzt: {text} · {when}": "Reminder set: {text} · {when}",
    "Datei gespeichert": "File saved",
    "Vom Rechner geholt": "Fetched from the computer",
    "Link gemerkt": "Link saved",
    "{name} → {target}: {task}": "{name} → {target}: {task}",
    "An {name}: {text}": "To {name}: {text}",
    "Fähigkeit gespeichert: {name}": "Skill saved: {name}",
    "Freigegeben: {title}": "Approved: {title}",
    "Abgelehnt: {title}": "Declined: {title}",
    "Immer erlaubt: {label}": "Always allowed: {label}",
    "Nicht mehr nötig: {title} (der Lauf ist schon vorbei)": "No longer needed: {title} (the run has already ended)",
    "Login gespeichert: {title}": "Login saved: {title}",
    "Nicht gespeichert: {title}": "Not saved: {title}",
    "Mail verworfen: {subject}": "Email discarded: {subject}",
    "Mail gesendet an {to}": "Email sent to {to}",
    "Mail nicht gesendet: {error}": "Email not sent: {error}",
    "Demo: Mail an {to} freigegeben (nicht wirklich gesendet) · demo, nothing was sent":
        "Demo: email to {to} approved (not actually sent)",
    "Ausgeführt: {title}": "Done: {title}",
    "Fehlgeschlagen: {title}": "Failed: {title}",
    "Nicht übernommen: {title}": "Not applied: {title}",
    "Übernommen: {change}": "Applied: {change}",
    "Verbesserung von {name}: {label}": "Improvement from {name}: {label}",
    "Ein Scoop": "A Scoop",
    "T3 arbeitet: {title}": "T3 is working: {title}",
    "Coding-Auftrag": "Coding task",
    "T3-Auftrag fehlgeschlagen": "T3 task failed",
    "T3 braucht Antwort: {title}": "T3 needs an answer: {title}",
    "T3 fertig: {title}": "T3 done: {title}",
    "Home: {label}": "Home: {label}",
    "ausgeführt": "done",
    "Home: nicht ausgeführt": "Home: not done",
    "Erinnerung": "Reminder",
    "Termin": "Event",
    "Erinnerung gelöscht: {label}": "Reminder deleted: {label}",
    "Termin gelöscht: {label}": "Event deleted: {label}",
    "Erinnerung nicht gelöscht": "Reminder not deleted",
    "Termin nicht gelöscht": "Event not deleted",
    "{place} betreten": "Arrived at {place}",
    "{place} verlassen": "Left {place}",
    "Es läuft schon ein Anruf, kein zweiter gestartet": "A call is already in progress; no second call started",
    "Lucy ist gerade nicht erreichbar, kein Anruf": "Lucy isn't reachable right now; no call made",
    "Lucy ruft an: {number}": "Lucy is calling: {number}",
    "Anruf beendet: {number}": "Call ended: {number}",
    "Anruf fehlgeschlagen": "Call failed",
    "{who}-Abo am Limit – weiter über den API-Schlüssel": "{who} subscription limit reached, continuing with the API key",
    "{who}-Abo nicht verfügbar – weiter über den API-Schlüssel":
        "{who} subscription unavailable, continuing with the API key",
    "Nachricht bearbeitet": "Message edited",
    # Eigene MCP-Server
    ("Bei {name} angemeldet · {n} Werkzeug"): ("Signed in to {name} · {n} tool", "Signed in to {name} · {n} tools"),
    "{name}: angemeldet, aber keine Werkzeuge": "{name}: signed in, but no tools",
    "Bei {name} anmelden: in „Apps verbinden“ › Eigene MCP-Server":
        "Sign in to {name}: in “Connect Apps” › Custom MCP Servers",
    "MCP-Server hinzugefügt: {name}": "MCP server added: {name}",
    "MCP-Server verbunden: {name} · {n} Werkzeug": ("MCP server connected: {name} · {n} tool",
                                                   "MCP server connected: {name} · {n} tools"),
    "MCP-Server hinzugefügt: {name} (Fehler)": "MCP server added: {name} (error)",
    "Token gespeichert: {name}": "Token saved: {name}",
    "MCP-Server entfernt: {name}": "MCP server removed: {name}",
    "MCP-Server: fehlgeschlagen": "MCP server: failed",
    "Nicht geladen": "Not loaded",

    # -- Freigabe-Karten ----------------------------------------------------------------------------------------------
    "Bittet um Freigabe: {title}": "Asks for approval: {title}",
    "{who} in {group}": "{who} in {group}",
    "eine App": "an app",
    "Computer Use: {app} bedienen": "Computer Use: control {app}",
    "Computer Use von Codex möchte „{app}“ auf dem Server-Mac bedienen: Bildschirm und Inhalte der App sehen, klicken "
    "und tippen. Gilt für diesen Lauf; mit „Immer erlauben“ künftig für diesen Scoop.":
        "Codex Computer Use wants to control “{app}” on the server Mac: see the screen and the app's content, click, "
        "and type. Applies to this run only; “Always Allow” covers this Scoop from now on.",
    "\n\nAnfrage von Computer Use: {message}": "\n\nRequest from Computer Use: {message}",
    "Argumente:": "Arguments:",
    "Achtung: Das Werkzeug meldet sich selbst als unumkehrbar.": "Caution: the tool reports itself as irreversible.",
    "{label}: {tool} ausführen": "{label}: run {tool}",
    "Lokalen MCP-Server verbinden: {name}": "Connect local MCP server: {name}",
    "Befehl: {command}\nLäuft auf dem Server-Mac mit den Rechten des Servers.":
        "Command: {command}\nRuns on the server Mac with the server's permissions.",
    "\nUmgebungsvariablen: {names}": "\nEnvironment variables: {names}",
    "Token": "Token",
    "Wert für {header}": "Value for {header}",
    "MCP-Server verbinden: {name}": "Connect MCP server: {name}",
    "keine": "none",
    "Token (Header {header})": "Token (header {header})",
    "beim Anbieter (OAuth), danach Karte „Anmelden“": "with the provider (OAuth), then the “Sign In” card",
    "Adresse: {url}\nAnmeldung: {login}\nSchreibende Werkzeuge des Servers laufen immer über Freigabe-Karten.":
        "Address: {url}\nSign-in: {login}\nTools on this server that make changes always need an approval card.",
    "MCP-Server entfernen: {name}": "Remove MCP server: {name}",
    "{target}\nZugangsdaten werden gelöscht.": "{target}\nIts credentials will be deleted.",
    "Token für {name} eintragen": "Enter token for {name}",
    "Adresse: {url}\nDas Token geht direkt in den Schlüsselbund des Servers.":
        "Address: {url}\nThe token goes straight into the server's keychain.",
    "Antwort an {to}": "Reply to {to}",
    "Mail an {to}": "Email to {to}",
    "Von: {account} ({email})": "From: {account} ({email})",
    "An: {to}": "To: {to}",
    "Cc: {cc}": "Cc: {cc}",
    "Betreff: {subject}": "Subject: {subject}",
    "(ohne Betreff)": "(no subject)",
    "Login speichern: {title}": "Save login: {title}",
    "Webseite: {url}\nBenutzer: {user}\n\nBenutzer und Passwort gibst du hier ein. Das Passwort landet nur im Tresor, "
    "kein Scoop sieht es.":
        "Website: {url}\nUsername: {user}\n\nEnter the username and password here. The password only goes into the "
        "Vault; no Scoop ever sees it.",
    "(trägst du ein)": "(you'll enter it)",
    "Anruf: {who} ({number})": "Call: {who} ({number})",
    "Nummer: {number}\n\nKontext: {context}\n\nZiel: {goal}": "Number: {number}\n\nContext: {context}\n\nGoal: {goal}",
    "Coding-Auftrag an T3: {title} ({project})": "Coding task for T3: {title} ({project})",
    "Projekt: {project}\nOrdner: {path}\n\nAuftrag:\n{task}": "Project: {project}\nFolder: {path}\n\nTask:\n{task}",
    "Nachricht an T3-Thread: {thread}": "Message to T3 thread: {thread}",
    # „Immer erlauben“-Bezeichnungen
    "Mails an {to} (Konto {account})": "Emails to {to} (account {account})",
    "Coding-Aufträge an T3 im Projekt {project}": "Coding tasks for T3 in project {project}",
    "Nachrichten an den T3-Thread „{thread}“": "Messages to the T3 thread “{thread}”",

    # -- Fehlermeldungen der API ----------------------------------------------------------------------------------------
    "Freigabe nicht gefunden": "Approval not found",
    "Diese Freigabe kann nicht dauerhaft erlaubt werden.": "“Always Allow” isn't available for this approval.",
    "Bitte Benutzer und Passwort im Formular eintragen (ab Build 12 der App).":
        "Enter the username and password in the form (requires app build 12 or later).",
    "Bitte in der Karte eintragen: {fields} (App aktualisieren, falls kein Eingabefeld zu sehen ist).":
        "Fill in these fields on the card: {fields} (update the app if you don't see them).",
    "Nachricht nicht gefunden": "Message not found",
    "Du kannst nur deine eigenen Nachrichten bearbeiten.": "You can only edit your own messages.",
    "Leere Nachricht": "Empty message",
    "Gesprochenes aus dem Live-Sprechmodus lässt sich nicht bearbeiten.":
        "Messages spoken in voice mode can't be edited.",
    "Aufgaben lassen sich nicht nachträglich bearbeiten. Schick die Aufgabe neu.":
        "Tasks can't be edited once sent. Send the task again.",
    "Nur deine jüngste Nachricht lässt sich bearbeiten. Ältere kannst du erneut senden.":
        "Only your latest message can be edited. You can resend older ones.",
    "Diese Nachricht wird gerade schon bearbeitet.": "This message is already being edited.",

    # -- Gespeicherte Texte -----------------------------------------------------------------------------------------
    "Anhang": "Attachment",
    "(Gruppe {group}) {text}": "(Group {group}) {text}",
    "(von {name}, Gast) {text}": "(from {name}, guest) {text}",
    "Notiz.md": "Note.md",
    "datei": "file",

    # -- Statuszeilen der Chat-Werkzeuge ------------------------------------------------------------------------------
    "Merkt sich etwas": "Remembers something",
    "Vergisst etwas": "Forgets something",
    "Erinnert sich": "Searches memory",
    "Legt eine Routine an": "Creates a routine",
    "Ändert eine Routine": "Updates a routine",
    "Setzt eine Erinnerung": "Sets a reminder",
    "Löscht eine Routine": "Deletes a routine",
    "Fragt dich um Freigabe": "Asks for your approval",
    "Bereitet eine Mail vor": "Prepares an email",
    "Legt eine Datei ab": "Saves a file",
    "Holt eine Datei vom Rechner": "Fetches a file from the computer",
    "Legt eine Datei auf den Rechner": "Puts a file on the computer",
    "Schaut in die Bibliothek": "Checks the Library",
    "Liest eine Datei": "Reads a file",
    "Merkt sich einen Link": "Saves a link",
    "Speichert eine Fähigkeit": "Saves a skill",
    "Nutzt Fähigkeit „{name}“": "Uses the “{name}” skill",
    "Löscht eine Fähigkeit": "Deletes a skill",
    "Schaut in T3": "Checks T3",
    "Bereitet einen Coding-Auftrag vor": "Prepares a coding task",
    "Liest einen T3-Thread": "Reads a T3 thread",
    "Bereitet einen Anruf vor": "Prepares a call",
    "Schaut in Lucys Anrufe": "Checks Lucy's calls",
    "Schreibt {name}": "Writes to {name}",  # Datei schreiben und einem Scoop schreiben
    "Übergibt an {name}": "Hands off to {name}",
    "Schaut sich die anderen Scoops an": "Looks at the other Scoops",
    "Liest den Chat von {name}": "Reads {name}'s chat",
    "Schaut sich {name} genauer an": "Takes a closer look at {name}",
    "Schlägt eine Verbesserung für {name} vor": "Suggests an improvement for {name}",
    "Startet eine Aufgabe": "Starts a task",
    "Schaut nach den Aufgaben": "Checks the tasks",
    "Setzt eine Aufgabe fort": "Continues a task",
    "Hält eine Aufgabe an": "Stops a task",
    "Nimmt eine Aufgabe ab": "Accepts a task",
    "Prüft einen MCP-Server": "Checks an MCP server",
    "Bereitet eine MCP-Verbindung vor": "Prepares an MCP connection",
    "Schaut nach den MCP-Servern": "Checks the MCP servers",
    "Fragt sicher nach einem Token": "Asks for a token securely",
    "Zeigt die Anmeldung": "Shows the sign-in card",
    "Entfernt einen MCP-Server": "Removes an MCP server",
}
