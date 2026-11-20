import XCTest

/// Die App auf Englisch (App/README.md „Sprachen“): Demo-Modus mit `-AppleLanguages (en)`. Prüft die Einführung und die
/// Hauptansichten auf englische Texte und darauf, dass keine deutschen Reste sichtbar sind. Screenshots als Anhänge.
@MainActor
final class EnglishUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-nopush", "-theme", "hell"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        attachment.name = "en-\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func wait(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath,
                      line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Fehlt: \(element)", file: file, line: line)
        return element
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// Keine deutschen Reste: Umlaute und typische deutsche Wörter in sichtbaren Texten und Knöpfen.
    /// Namen aus den Demo-Daten (Personen, Scoops) enthalten keine Umlaute.
    private func assertNoGerman(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let german = try! NSRegularExpression(
            pattern: "[äöüÄÖÜß]|\\b(und|nicht|mit|der|die|das|ist|noch|Einstellungen|Abbrechen|Weiter|Zurück|Heute|Aufgaben)\\b")
        // Ausnahme: echte Ordnernamen im Arbeitsordner („Dateien“, „Aufgaben“) bleiben in jeder Sprache gleich
        let labels = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex).map {
            $0.label.replacingOccurrences(of: "“Dateien”", with: "").replacingOccurrences(of: "“Aufgaben”", with: "")
        }
        let hits = labels.filter { german.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        XCTAssertTrue(hits.isEmpty, "Deutsche Texte auf \(screen): \(hits)", file: file, line: line)
    }

    // MARK: Einführung

    func testEinfuehrungEnglisch() {
        let app = launch(["-mock", "-onboarding", "welcome"])
        wait(text(app, "Scoops are little AI helpers"))
        XCTAssertTrue(button(app, "Try It Without a Server").exists)
        XCTAssertTrue(text(app, "Step 1 of 5").exists)
        assertNoGerman(app, "Willkommen")
        shot("1-welcome")
        button(app, "Continue").tap()
        wait(text(app, "They Live on Your Mac"))
        assertNoGerman(app, "Willkommen 2")
        button(app, "Continue").tap()
        wait(text(app, "Here’s How It Works"))
        button(app, "Let’s Go").tap()
        wait(text(app, "Sign In"))
        XCTAssertTrue(text(app, "Step 2 of 5").exists)
        assertNoGerman(app, "Anmelden")
        shot("2-sign-in")
        app.terminate()
    }

    // MARK: Hauptansichten im Demo-Modus

    func testHauptansichtenEnglisch() {
        let cases: [(String, [String], String)] = [
            ("chats", [], "Search Scoops and Messages"),
            ("chat", ["-select", "b_mila"], "Approve"),
            ("today", ["-heute"], "Waiting for You"),
            ("board", ["-aufgaben"], "Tasks"),
            ("settings", ["-settings"], "Settings"),
            ("create", ["-create"], "New Scoop"),
        ]
        for (name, args, marker) in cases {
            let app = launch(["-mock"] + args)
            let found = text(app, marker).waitForExistence(timeout: 15) || button(app, marker).exists
                || app.searchFields.containing(NSPredicate(format: "placeholderValue CONTAINS %@", marker)).firstMatch.exists
                || app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS %@", marker)).firstMatch.exists
            XCTAssertTrue(found, "Fehlt auf \(name): \(marker)")
            Thread.sleep(forTimeInterval: 1)
            assertNoGerman(app, name)
            shot(name)
            app.terminate()
        }
    }
}
