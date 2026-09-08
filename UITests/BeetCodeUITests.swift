import XCTest

@MainActor
final class BeetCodeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrimaryComposerControlsAreAccessibleAtLaunch() {
        let app = launchApp()

        XCTAssertTrue(app.textFields["Task description"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Attach files"].exists)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testComposerStartsReadyForTaskInput() {
        let app = launchApp()
        let composer = app.textFields["Task description"]

        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
        XCTAssertTrue(app.buttons["Tools"].exists)
    }

    func testHistoryNavigationIsAccessible() {
        let app = launchApp()
        let imported = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Show imported conversations", "Imported filter active"])).firstMatch

        revealHistory(in: app, ifNeeded: imported)

        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Workspace:")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Close history"].exists)
        XCTAssertFalse(app.buttons["Chats"].exists)
        XCTAssertTrue(app.buttons["New chat"].exists)
    }

    func testCommandFFocusesChatSearch() {
        let app = launchApp()
        let search = app.textFields["Search chats"]

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("x")

        XCTAssertEqual(search.value as? String, "x")
    }

    func testHistoryTogglePreservesDraftAndRail() {
        let app = launchApp()
        let composer = app.textFields["Task description"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("Keep this draft")
        let existingDraft = composer.value as? String
        XCTAssertFalse(existingDraft?.isEmpty ?? true)
        let history = app.buttons["Conversation history"]
        XCTAssertTrue(history.exists)
        history.click()
        XCTAssertTrue(history.exists)
        XCTAssertEqual(composer.value as? String, existingDraft)
        history.click()
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, existingDraft)
    }

    func testCompactComposerStaysInsideWindow() {
        let app = launchApp(size: "1000x700")
        let editor = app.textFields["Task description"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let bounds = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(editor.frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(editor.frame.maxX, bounds.maxX)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists)
        XCTAssertLessThanOrEqual(send.frame.maxX, bounds.maxX)
    }

    func testModelsCatalogOpensAtNormalWidth() {
        let app = launchApp(screen: "settings-models")
        XCTAssertTrue(app.textFields["Filter models"].waitForExistence(timeout: 10))
    }

    func testComposerHardwareLivesOnlyInPermanentSpine() {
        let app = launchApp()
        let status = app.buttons["Session status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "Session status").count, 1)
        XCTAssertLessThanOrEqual(status.frame.maxX, app.windows.firstMatch.frame.minX + 64)
        XCTAssertEqual(status.frame.width, 44, accuracy: 1)
        XCTAssertEqual(status.frame.height, 44, accuracy: 1)
        // Popover content is checked with native AX interaction separately:
        // this Xcode beta's XCTest popover query throws commonInit assertions.
    }

    func testMinimumWindowKeepsRailAndComposer() {
        let app = launchApp(size: "520x700")
        let history = app.buttons["Conversation history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.click()
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    func testDarkWelcomeRetainsTitleAndHardwareGeometry() {
        let app = launchApp(appearance: "dark")
        XCTAssertTrue(app.staticTexts["welcome-wordmark"].waitForExistence(timeout: 10))
        let status = app.buttons["Session status"]
        XCTAssertTrue(status.exists)
        XCTAssertEqual(status.frame.width, 44, accuracy: 1)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testDarkModelSearchAcceptsKeyboardInputAtMinimumWidth() {
        let app = launchApp(size: "520x700", screen: "settings-models", appearance: "dark")
        let search = app.textFields["Filter models"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("x")
        XCTAssertEqual(search.value as? String, "x")
        XCTAssertLessThanOrEqual(search.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    func testBotsComposerFillsWorkspaceAndNavigationLeavesBots() {
        let app = launchApp(screen: "bots")
        let editor = app.textViews["Task for Builder"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(editor.frame.width, window.width * 0.65)
        XCTAssertGreaterThan(editor.frame.height, window.height * 0.4)
        XCTAssertLessThanOrEqual(editor.frame.maxY, window.maxY)

        app.buttons["Conversation history"].click()
        XCTAssertTrue(app.textFields["Task description"].waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists)

        app.buttons["Bots"].firstMatch.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["Search chats"].firstMatch.click()
        XCTAssertTrue(app.textFields["Task description"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search chats"].exists)
        XCTAssertFalse(editor.exists)
    }

    private func launchApp(size: String = "1320x856", screen: String = "welcome",
                           appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-smoke",
            "--design-preview", screen, "--design-size", size,
            "--design-appearance", appearance,
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        return app
    }

    private func revealHistory(in app: XCUIApplication, ifNeeded element: XCUIElement) {
        guard !element.waitForExistence(timeout: 2) else { return }
        if app.buttons["Conversation history"].exists {
            app.buttons["Conversation history"].click()
        } else if app.buttons["Toggle sidebar"].exists {
            app.buttons["Toggle sidebar"].click()
        }
    }
}
