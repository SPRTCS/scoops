import XCTest

/// Einführung der App (docs/onboarding.md) im iOS-Simulator: Screenshots jedes Schritts, ganzer Ablauf im Demo-Modus,
/// Neustart mitten im Ablauf und – wenn `ONB_SERVER_URL`/`ONB_SERVER_TOKEN` gesetzt sind (über `TEST_RUNNER_…`) – der
/// Ablauf gegen einen lokalen Testserver mit „Erweitert: Manuell verbinden“.
///
/// Screenshots landen als Anhänge im Ergebnisbündel:
/// `xcrun xcresulttool export attachments --path <x.xcresult> --output-path <ordner>`
@MainActor
final class OnboardingUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String], theme: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-nopush"]
            + (theme.map { ["-theme", $0] } ?? [])
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func wait(_ element: XCUIElement, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Fehlt: \(element)", file: file, line: line)
        return element
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    // MARK: Screenshots jedes Schritts

    func testScreenshotsJedesSchritts() {
        let cases: [(String, [String], String)] = [
            ("1-willkommen", ["-onboarding", "welcome"], "Scoops sind kleine KI-Helfer"),
            ("1b-willkommen-mac", ["-onboarding", "welcome:2"], "Sie wohnen auf deinem Mac"),
            ("1c-willkommen-plan", ["-onboarding", "welcome:3"], "So geht"),
            ("1d-manuell-verbinden", ["-onboarding", "welcome", "-manualconnect"], "Scoops sind kleine KI-Helfer"),
            ("2-anmelden", ["-onboarding", "signin"], "Melde dich an"),
            ("3a-server-anleitung", ["-onboarding", "server"], "Verbinde deinen Mac"),
            ("3b-server-auswahl", ["-onboarding", "server", "-mockservers"], "Wähle deinen Server"),
            ("3c-kopplungscode", ["-onboarding", "server:code"], "Gib deinen Kopplungscode ein"),
            ("3d-code-abgelaufen", ["-onboarding", "server:expired"], "Code abgelaufen"),
            ("3e-warten", ["-onboarding", "server:waiting"], "Fast geschafft"),
            ("3f-nicht-erreichbar", ["-onboarding", "server:unreachable"], "Server nicht erreichbar"),
            ("4a-scoop-name", ["-onboarding", "scoop"], "Wie soll dein Scoop heißen?"),
            ("4b-scoop-aussehen", ["-onboarding", "scoop:look"], "Wie sieht Fina aus?"),
            ("4c-scoop-zweck", ["-onboarding", "scoop:purpose"], "Wobei hilft dir Fina?"),
            ("5a-erste-nachricht", ["-onboarding", "message"], "Sag Hallo zu Fina"),
            ("6-tipps", ["-onboarding", "tips"], "Gut zu wissen"),
        ]
        for (name, args, marker) in cases {
            for theme in ["hell", "nacht"] {
                let app = launch(["-mock"] + args, theme: theme)
                wait(text(app, marker), 15)
                if name == "3e-warten" { Thread.sleep(forTimeInterval: 0.8) } else { Thread.sleep(forTimeInterval: 1.2) }
                shot("\(name)-\(theme)")
                app.terminate()
            }
        }
        // Erste Antwort gefeiert
        for theme in ["hell", "nacht"] {
            let app = launch(["-mock", "-onboarding", "message:reply"], theme: theme)
            wait(text(app, "Deine erste Antwort!"), 25)
            Thread.sleep(forTimeInterval: 0.4)
            shot("5b-erste-antwort-\(theme)")
            app.terminate()
        }
    }

    // MARK: Ganzer Ablauf im Demo-Modus

    func testGanzerAblaufDemo() {
        let app = launch(["-mock", "-onboarding", "welcome"], theme: "hell")
        wait(text(app, "Scoops sind kleine KI-Helfer"))
        XCTAssertTrue(button(app, "Manuell verbinden").exists, "Manuell verbinden muss auf dem ersten Bildschirm stehen")
        XCTAssertTrue(button(app, "ohne Server ausprobieren").exists, "Demo-Knopf muss auf dem ersten Bildschirm stehen")
        XCTAssertTrue(text(app, "Schritt 1 von 5").exists)
        button(app, "Weiter").tap()
        wait(text(app, "Sie wohnen auf deinem Mac"))
        // Zurück geht immer
        button(app, "Zurück").tap()
        wait(text(app, "Scoops sind kleine KI-Helfer"))
        button(app, "Weiter").tap()
        button(app, "Weiter").tap()
        button(app, "Los geht").tap()

        // Anmelden (Demo-Konto ohne Apple)
        wait(text(app, "Melde dich an"))
        XCTAssertTrue(text(app, "Schritt 2 von 5").exists)
        let apple = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Apple'")).firstMatch
        wait(apple).tap()

        // Server: Anleitung → Code → Warten → verbunden
        wait(text(app, "Verbinde deinen Mac"))
        XCTAssertTrue(button(app, "Link an meinen Mac senden").exists)
        shot("flow-3-anleitung")
        button(app, "Ich habe einen Kopplungscode").tap()
        let field = wait(app.textFields["Kopplungscode"])
        field.tap()
        field.typeText("FEHLER23")
        button(app, "Koppeln").tap()
        wait(text(app, "Code abgelaufen"))
        shot("flow-3-code-fehler")
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        field.typeText("K7QX29PL")
        button(app, "Koppeln").tap()
        wait(text(app, "Fast geschafft"))
        shot("flow-3-warten")

        // Erster Scoop
        wait(text(app, "Wie soll dein Scoop heißen?"), 25)
        XCTAssertTrue(text(app, "Schritt 4 von 5").exists)
        let name = app.textFields["Name deines Scoops"]
        wait(name).tap()
        name.typeText("Fina")
        button(app, "Weiter").tap()
        wait(text(app, "Wie sieht Fina aus?"))
        app.buttons["Farbe"].tap()
        shot("flow-4-farbe")
        button(app, "Weiter").tap()
        wait(text(app, "Wobei hilft dir Fina?"))
        button(app, "Recherche").tap()
        button(app, "Fina erstellen").tap()

        // Erste Nachricht
        wait(text(app, "Sag Hallo zu Fina"), 20)
        XCTAssertTrue(text(app, "Schritt 5 von 5").exists)
        button(app, "Rezepte für Kürbissuppe").tap()
        wait(text(app, "Deine erste Antwort!"), 25)
        shot("flow-5-gefeiert")
        button(app, "Weiter").tap()

        // Tipps → App mit dem neuen Chat
        wait(text(app, "Gut zu wissen"))
        button(app, "Los geht").tap()
        XCTAssertFalse(text(app, "Gut zu wissen").waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 1.5)
        shot("flow-6-app")
    }

    // MARK: Neustart mitten im Ablauf

    func testNeustartSetztFort() {
        var app = launch(["-mock", "-onboarding", "scoop"])
        let name = app.textFields["Name deines Scoops"]
        wait(name).tap()
        name.typeText("Momo")
        button(app, "Weiter").tap()
        wait(text(app, "Wie sieht Momo aus?"))
        Thread.sleep(forTimeInterval: 1)  // Entwurf wird verzögert gesichert
        app.terminate()

        app = launch(["-mock", "-onboarding", "resume"])
        wait(text(app, "Wie sieht Momo aus?"), 15)
        XCTAssertTrue(text(app, "Schritt 4 von 5").exists)
        shot("neustart-fortgesetzt")
        app.terminate()
    }

    // MARK: Größenwechsel mitten im Ablauf (iPhone Duo auf-/zuklappen, Drehen)

    /// Ein Größenwechsel (Auf-/Zuklappen des iPhone Duo, Drehen, iPad-Fenstergröße) darf Eingaben, Schritt und
    /// Zurück-Weg nicht verlieren, und mit offener Tastatur müssen Feld und Fehlermeldung sichtbar bleiben.
    ///
    /// XCUITest kann das Duo nicht klappen (nur das Scharnier-Ereignis des Simulators, etwa `agent-device fold open`).
    /// Drehen löst denselben Weg aus: neue Fenstergröße, neues Layout, Tastatur bleibt offen.
    func testGroessenwechselMittenImAblauf() {
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        func turn() {
            device.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            device.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
        }

        // Name mit offener Tastatur, dann Figur
        var app = launch(["-mock", "-onboarding", "scoop"])
        let name = app.textFields["Name deines Scoops"]
        wait(name).tap()
        name.typeText("Kiwi")
        turn()
        XCTAssertEqual(name.value as? String, "Kiwi")
        XCTAssertTrue(text(app, "Schritt 4 von 5").exists)
        XCTAssertTrue(button(app, "Weiter").isHittable, "Weiter muss mit offener Tastatur erreichbar sein")
        assertAbove(name, button(app, "Weiter"), "Namensfeld unter den Knöpfen")
        button(app, "Weiter").tap()
        wait(text(app, "Wie sieht Kiwi aus?"))
        let heart = app.buttons["Herz"]
        wait(heart).tap()
        turn()
        XCTAssertTrue(text(app, "Wie sieht Kiwi aus?").exists, "Teil des Editors verloren")
        XCTAssertTrue(app.buttons["Herz"].isSelected, "Gewählte Figur verloren")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Wie sieht Kiwi aus?'")).count, 1,
                       "Ansicht doppelt")
        button(app, "Zurück").tap()
        wait(text(app, "Wie soll dein Scoop heißen?"))
        XCTAssertEqual(app.textFields["Name deines Scoops"].value as? String, "Kiwi")
        app.terminate()

        // Kopplungscode halb eingegeben
        app = launch(["-mock", "-onboarding", "server:code"])
        let code = wait(app.textFields["Kopplungscode"])
        code.tap()
        code.typeText("K7QX29")
        turn()
        XCTAssertEqual(code.value as? String, "K7QX-29")
        XCTAssertTrue(text(app, "Schritt 3 von 5").exists)
        app.terminate()

        // Code abgelaufen: Meldung steht trotz Tastatur frei über „Koppeln“, auch nach dem Größenwechsel
        app = launch(["-mock", "-onboarding", "server:expired"])
        let expired = wait(text(app, "Code abgelaufen"), 15)
        Thread.sleep(forTimeInterval: 1)
        assertAbove(expired, button(app, "Koppeln"), "Fehlermeldung verdeckt")
        turn()
        assertAbove(expired, button(app, "Koppeln"), "Fehlermeldung nach Größenwechsel verdeckt")
        shot("groessenwechsel-code-abgelaufen")
        app.terminate()
    }

    /// `element` liegt sichtbar über `actions` (und damit nicht unter Knöpfen oder Tastatur)
    private func assertAbove(_ element: XCUIElement, _ actions: XCUIElement, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty, message, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, actions.frame.minY + 1, message, file: file, line: line)
        XCTAssertGreaterThan(frame.minY, 0, message, file: file, line: line)
    }

    // MARK: Lokaler Testserver (Manuell verbinden)

    func testLokalerTestserver() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["ONB_SERVER_URL"], let token = env["ONB_SERVER_TOKEN"] else {
            throw XCTSkip("ONB_SERVER_URL/ONB_SERVER_TOKEN nicht gesetzt")
        }
        let app = launch(["-onboarding", "welcome"], theme: "hell")
        wait(text(app, "Scoops sind kleine KI-Helfer"))
        button(app, "Manuell verbinden").tap()
        let address = wait(app.textFields.element(boundBy: 0))
        address.tap()
        address.typeText(url)
        let secret = app.secureTextFields.firstMatch
        secret.tap()
        secret.typeText(token)
        shot("server-manuell")
        button(app, "Verbinden").tap()

        // Frischer Server (nur Pip) → erster Scoop
        wait(text(app, "Wie soll dein Scoop heißen?"), 30)
        let name = app.textFields["Name deines Scoops"]
        wait(name).tap()
        name.typeText("Lumi")
        button(app, "Weiter").tap()
        button(app, "Weiter").tap()
        button(app, "Alltag").tap()
        button(app, "Lumi erstellen").tap()
        wait(text(app, "Sag Hallo zu Lumi"), 30)
        button(app, "Was kannst du alles").tap()
        wait(text(app, "Deine erste Antwort!"), 40)
        shot("server-erste-antwort")
        button(app, "Weiter").tap()
        wait(text(app, "Gut zu wissen"))
        button(app, "Los geht").tap()
        XCTAssertFalse(text(app, "Gut zu wissen").waitForExistence(timeout: 2))
        shot("server-app")

        // Neustart: Einführung bleibt erledigt, Bestandsnutzer sehen sie nicht wieder
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(de)", "-nopush"]
        app.launch()
        XCTAssertFalse(text(app, "Scoops sind kleine KI-Helfer").waitForExistence(timeout: 6))
        shot("server-neustart")
    }
}
