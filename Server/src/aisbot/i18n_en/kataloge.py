"""Englische Texte: Kataloge (Modelle, Apps verbinden, Composio, eigene MCP-Server, Notion direkt) (siehe i18n_en/__init__.py)."""

TEXTS: dict = {
    # Modellkatalog (models_catalog.json, `hint`; eine Fernkopie kann `hint_en` mitbringen, das hat Vorrang)
    "Schnell & günstig": "Fast & affordable",
    "Stärker": "Stronger",
    "Sehr stark, teuer": "Very strong, expensive",
    "Am stärksten, sehr teuer": "Strongest, very expensive",
    "Schnell & sehr günstig": "Fast & very affordable",
    "Ausgewogen & günstig": "Balanced & affordable",
    "Stark, Allrounder": "Strong all-rounder",
    "Am stärksten, teuer": "Strongest, expensive",

    # Apps verbinden: vorgeschlagene Apps
    "Google Kalender": "Google Calendar",
    "Mails lesen, Entwürfe schreiben, senden": "Read, draft, and send email",
    "Termine lesen und anlegen": "Read and create events",
    "Microsoft-Mail und -Kalender": "Microsoft email and calendar",
    "Seiten und Datenbanken, z. B. Tasks": "Pages and databases, like your tasks",
    "Dateien finden und ablegen": "Find and store files",
    "Tabellen lesen und füllen": "Read and fill in spreadsheets",
    "Dokumente lesen und schreiben": "Read and write documents",
    "Nachrichten lesen und schreiben": "Read and write messages",
    "Repos, Issues, Pull Requests": "Repos, issues, and pull requests",
    "Profil und Beiträge": "Profile and posts",

    # Apps verbinden: Kategorien
    "Beliebt": "Popular",
    "Verbunden": "Connected",
    "Produktivität": "Productivity",
    "Kommunikation": "Communication",
    "Entwicklung": "Development",
    "Daten": "Data",
    "Finanzen": "Finance",
    "Vertrieb & CRM": "Sales & CRM",
    "KI": "AI",
    "Handel": "Commerce",
    "Personal": "HR",
    "Bildung": "Education",
    "Freizeit": "Lifestyle",

    # Apps verbinden: Meldungen
    "Für {name} bietet Composio keine fertige Anmeldung an. Dafür müsste zuerst im Composio-Konto eine eigene "
    "Anmeldung (Auth-Config) für diese App hinterlegt werden.":
        "Composio doesn't offer a ready-made sign-in for {name}. To connect it, a custom sign-in (auth config) for this "
        "app has to be set up in the Composio account first.",
    "Kein Composio-Schlüssel hinterlegt": "No Composio key saved",
    "Composio: Antwort ohne Sitzungs-ID": "Composio: response without a session ID",
    "Composio-Sitzung nicht anlegbar ({last})": "Couldn't create a Composio session ({last})",
    "Composio ist nicht eingerichtet": "Composio isn't set up",
    "Composio meldet einen Fehler": "Composio reported an error",
    "Composio: leerer Katalog": "Composio: empty catalog",
    "Composio: Antwort ohne Auth-Config-ID": "Composio: response without an auth config ID",
    "Höchstens {max} Konten pro App": "Up to {max} accounts per app",
    "Diesen Namen gibt es für diese App schon": "This app already has an account with that name",
    "Unbekannte App": "Unknown app",
    "Diese App gibt es bei Composio nicht.": "Composio doesn't have this app.",
    "{name} ist bei Composio nicht (mehr) verfügbar.": "{name} is no longer available on Composio.",
    "Name fehlt": "Name is missing",
    "Dieses Konto meldest du neu an, indem du es trennst und mit neuem Schlüssel wieder verbindest.":
        "To update this account, disconnect it and reconnect it with a new key.",
    "{name} braucht keine Anmeldung. Die Scoops können die App direkt nutzen.":
        "{name} doesn't need a sign-in. Your Scoops can use the app right away.",
    "{name} verbindest du über die Anmeldung im Browser.": "Connect {name} by signing in with your browser.",
    "Bitte „{label}“ ausfüllen.": "Please fill in “{label}”.",
    "„{label}“ ist zu lang.": "“{label}” is too long.",
    "{name} hat die Angaben abgelehnt. Bitte prüfe sie und versuche es noch einmal.":
        "{name} rejected these details. Please check them and try again.",
    "Kein Logo": "No logo",

    # Notion direkt
    "Notion direkt": "Notion Direct",
    "Notion-Anmeldung konnte nicht im Schlüsselbund gespeichert werden.":
        "Couldn't save the Notion sign-in to the keychain.",
    "Notion ist gerade nicht erreichbar (HTTP {status}).": "Notion can't be reached right now (HTTP {status}).",
    "Notion unterstützt die sichere Anmeldung (PKCE S256) nicht mehr.":
        "Notion no longer supports secure sign-in (PKCE S256).",
    "Registrierung bei Notion fehlgeschlagen: {error}": "Registration with Notion failed: {error}",
    "Die Anmeldung bei Notion wurde abgebrochen.": "Signing in to Notion was canceled.",
    "Notion hat die Anmeldung abgelehnt: {error}": "Notion declined the sign-in: {error}",
    "Diese Anmeldung ist abgelaufen. Bitte tippe noch einmal auf Verbinden.":
        "This sign-in has expired. Please tap Connect again.",
    "Notion hat keinen Anmelde-Code geliefert.": "Notion didn't return a sign-in code.",
    "Notion hat kein Zugangs-Token geliefert.": "Notion didn't return an access token.",
    "Die Notion-Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden.":
        "Your Notion sign-in has expired. Please sign in again under “Connect Apps.”",
    "Notion ist nicht verbunden.": "Notion isn't connected.",

    # MCP-Verbindungen
    "Prozess beendet": "Process ended",
    "{name}: keine Antwort nach {seconds} s": "{name}: no response after {seconds} s",

    # Eigene MCP-Server
    "Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden.":
        "Couldn't save the credentials to the keychain.",
    "Bitte eine vollständige Adresse eingeben, z. B. https://mcp.example.com/mcp":
        "Please enter a complete address, such as https://mcp.example.com/mcp",
    "Bitte https:// verwenden (http nur für localhost oder .local).":
        "Please use https:// (http only for localhost or .local).",
    "Der Server ist nicht erreichbar: {error}": "The server can't be reached: {error}",
    "Keine Anmeldung nötig": "No sign-in needed",
    "Anmeldung über den Anbieter (OAuth)": "Sign in with the provider (OAuth)",
    "Der Server verlangt ein Token": "The server requires a token",
    "Unter dieser Adresse antwortet kein MCP-Server (HTTP 404). Endet sie auf /mcp?":
        "No MCP server responds at this address (HTTP 404). Does it end in /mcp?",
    "Der Server nimmt keine MCP-Anfragen an (HTTP 405). Nur Streamable HTTP wird unterstützt.":
        "The server doesn't accept MCP requests (HTTP 405). Only Streamable HTTP is supported.",
    "Der Server antwortet mit HTTP {status}.": "The server responds with HTTP {status}.",
    "Der Server nennt keinen Anmelde-Dienst (OAuth-Metadaten fehlen).":
        "The server doesn't name a sign-in service (OAuth metadata is missing).",
    "Diesen MCP-Server gibt es nicht (mehr).": "This MCP server no longer exists.",
    "Art: remote oder stdio": "Type: remote or stdio",
    "Höchstens {max} eigene MCP-Server": "Up to {max} custom MCP servers",
    "Anmeldung: none, token, oauth oder auto": "Sign-in: none, token, oauth, or auto",
    "Dieser Server verlangt ein Token. Bitte unter „Token“ eintragen.":
        "This server requires a token. Enter it under “Token.”",
    "Ungültiger Header-Name": "Invalid header name",
    "Bitte einen Befehl angeben, z. B. /Applications/Atrium.app/Contents/MacOS/Atrium":
        "Please enter a command, such as /Applications/Atrium.app/Contents/MacOS/Atrium",
    "Programm nicht gefunden: {program}": "Program not found: {program}",
    "Umgebungsvariablen: Namen aus Buchstaben, Ziffern und _":
        "Environment variables: names made of letters, digits, and _",
    "Bitte einen Namen eingeben.": "Please enter a name.",
    "Nur Remote-Server haben ein Token.": "Only remote servers have a token.",
    "Bitte ein Token eingeben.": "Please enter a token.",
    "Anmeldung abgelaufen": "Sign-in expired",
    "Anmeldung nötig": "Sign-in needed",
    "Nicht geladen": "Not loaded",
    "Noch keine Werkzeuge geladen": "No tools loaded yet",
    "Dieser Server bietet keine Anmeldung über OAuth an.": "This server doesn't offer OAuth sign-in.",
    "Der Server unterstützt die sichere Anmeldung (PKCE S256) nicht.":
        "The server doesn't support secure sign-in (PKCE S256).",
    "Dieser Server erlaubt keine automatische Registrierung (Dynamic Client Registration). Nutze stattdessen ein Token.":
        "This server doesn't allow automatic registration (Dynamic Client Registration). Use a token instead.",
    "Registrierung beim Server fehlgeschlagen: {error}": "Registration with the server failed: {error}",
    "Dieser Server braucht keine Anmeldung.": "This server doesn't need a sign-in.",
    "Unbekannter Rücksprung-Link": "Unknown callback link",
    "Die Anmeldung wurde abgebrochen.": "Signing in was canceled.",
    "Der Server hat die Anmeldung abgelehnt: {error}": "The server declined the sign-in: {error}",
    "Diese Anmeldung ist abgelaufen. Bitte tippe noch einmal auf Anmelden.":
        "This sign-in has expired. Please tap Sign In again.",
    "Der Server hat keinen Anmelde-Code geliefert.": "The server didn't return a sign-in code.",
    "Anmeldung: {error}": "Sign-in: {error}",
    "Der Server hat kein Zugangs-Token geliefert.": "The server didn't return an access token.",
    "Die Anmeldung ist abgelaufen. Bitte in „Apps verbinden“ neu anmelden.":
        "Your sign-in has expired. Please sign in again under “Connect Apps.”",
}
