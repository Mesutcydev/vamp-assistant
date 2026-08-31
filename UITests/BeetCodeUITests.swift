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
        XCTAssertTrue(app.menuButtons["composer-commands"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testComposerStartsReadyForTaskInput() {
        let app = launchApp()
        let composer = app.textFields["Task description"]

        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.menuButtons["composer-commands"].exists)
        XCTAssertTrue(app.menuButtons["Tools and capabilities"].exists)
    }

    func testHistoryNavigationIsAccessible() {
        let app = launchApp()
        let imported = app.buttons["Imported"]

        revealHistory(in: app, ifNeeded: imported)

        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Search, ⌘F"].exists)
        XCTAssertTrue(app.buttons["Switch workspace"].exists)
        XCTAssertTrue(app.buttons["New chat"].exists)
    }

    func testCommandFFocusesChatSearch() {
        let app = launchApp()
        let search = app.textFields["Search all history"]

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeText("x")

        XCTAssertEqual(search.value as? String, "x")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-smoke",
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
        if app.buttons["Chats"].exists {
            app.buttons["Chats"].click()
        } else if app.buttons["Toggle sidebar"].exists {
            app.buttons["Toggle sidebar"].click()
        }
    }
}
