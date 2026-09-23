import XCTest

@MainActor
final class ComposerUITests: XCTestCase {
    private func launch(_ state: String = "ready", appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VAMP_REMOTE_TEST_SCREEN"] = "composer"
        app.launchEnvironment["VAMP_REMOTE_FIXTURE"] = state
        app.launchEnvironment["VAMP_TEST_APPEARANCE"] = appearance
        app.launch()
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["remote.composer.editor"]
    }

    func testCompactGrowthAndSend() {
        let app = launch()
        let input = editor(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let emptyHeight = input.frame.height
        XCTAssertLessThanOrEqual(emptyHeight, 48, "Empty editor must occupy one text line")
        let send = app.buttons["remote.composer.primary"]
        XCTAssertFalse(send.isEnabled)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        capture("empty-light")
        input.tap()
        XCTAssertEqual(input.frame.height, emptyHeight, accuracy: 2, "Focus must not expand an empty editor")
        input.typeText("One\nTwo\nThree\nFour\nFive\nSix")
        let cappedHeight = input.frame.height
        XCTAssertGreaterThan(cappedHeight, emptyHeight + 60)
        input.typeText("\nSeven\nEight\nNine\nTen")
        XCTAssertEqual(input.frame.height, cappedHeight, accuracy: 2, "Overflow must scroll within the six-line editor")
        XCTAssertTrue(send.isHittable)
        capture("multiline-keyboard-light")
        send.tap()
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "Send")
        XCTAssertEqual(input.frame.height, emptyHeight, accuracy: 2)
        XCTAssertFalse(send.isEnabled)
    }

    func testQueueSteerAndStop() {
        let app = launch("running", appearance: "dark")
        let input = editor(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Follow up")
        let primary = app.buttons["remote.composer.primary"]
        XCTAssertEqual(primary.label, "Queue follow-up")
        primary.tap()
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "Queue")
        input.typeText("Change direction")
        let steer = app.buttons["Steer"]
        XCTAssertTrue(steer.isHittable)
        capture("running-dark")
        steer.tap()
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "Steer")
        XCTAssertEqual(primary.label, "Stop the agent")
        primary.tap()
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "Stop")
    }

    func testOfflineDraftAndLandscape() {
        let app = launch("offline", appearance: "dark")
        let input = editor(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Keep this draft while offline.")
        XCTAssertFalse(app.buttons["remote.composer.primary"].isEnabled)
        capture("offline-dark")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.value as? String == "Keep this draft while offline.")
        input.typeText("\nTwo\nThree\nFour\nFive")
        XCTAssertLessThanOrEqual(input.frame.height, 90)
        capture("landscape-dark")
    }

    func testSendingDisablesSubmission() {
        let app = launch("sending")
        XCTAssertTrue(editor(app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["remote.composer.primary"].isEnabled)
        XCTAssertEqual(app.buttons["remote.composer.primary"].label, "Sending")
    }

    func testDeleteAndCanceledPress() {
        let app = launch()
        let input = editor(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let share = app.buttons["Share clipboard or files with Mac"]
        share.press(forDuration: 0.2, thenDragTo: app.navigationBars.firstMatch)
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "None", "Dragging off a key must cancel its action")
        share.tap()
        XCTAssertEqual(app.staticTexts["fixture.lastAction"].label, "Share")
        input.tap()
        let emptyHeight = input.frame.height
        let draft = "One\nTwo\nThree\nFour"
        input.typeText(draft)
        XCTAssertGreaterThan(input.frame.height, emptyHeight)
        // Send a generous delete run because simulator keyboards can encode
        // inserted newlines as more than one deletion unit.
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 64))
        XCTAssertEqual(input.frame.height, emptyHeight, accuracy: 2)
        XCTAssertFalse(app.buttons["remote.composer.primary"].isEnabled)
        app.buttons["remote.hideKeyboard"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "composer-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
