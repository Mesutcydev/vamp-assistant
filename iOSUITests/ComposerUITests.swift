import XCTest

@MainActor
final class QueuedFollowUpUITests: XCTestCase {
    func testSendQueuedFollowUpWithEmptyComposer() throws {
        guard let host = ProcessInfo.processInfo.environment["BEETCODE_QUEUE_UI_HOST"] else {
            throw XCTSkip("Set BEETCODE_QUEUE_UI_HOST to an isolated queued-session host.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["BEETCODE_REMOTE_TEST_URL"] = host
        app.launchEnvironment["BEETCODE_REMOTE_TEST_TOKEN"] = "local-ui-fixture-token"
        app.launchEnvironment["VAMP_TEST_APPEARANCE"] = ProcessInfo.processInfo.environment["BEETCODE_QUEUE_UI_APPEARANCE"] ?? "light"
        app.launch()
        let chat = app.staticTexts["Queue recovery"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.tap()
        let send = app.buttons["remote.queue.send.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(send.isEnabled)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        let editor = app.textFields["remote.composer.editor"]
        editor.tap()
        XCTAssertFalse(app.buttons["remote.composer.primary"].isEnabled)
        XCTAssertTrue(send.isHittable, "The saved message remains sendable with an empty, focused composer")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "queued-message-with-keyboard"
        before.lifetime = .keepAlways
        add(before)
        send.tap()
        XCTAssertTrue(app.staticTexts["Queued follow-up delivered."].waitForExistence(timeout: 15))
        XCTAssertFalse(send.exists)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "queued-message-delivered"
        after.lifetime = .keepAlways
        add(after)
    }
}

@MainActor
final class NewChatUITests: XCTestCase {
    /// Opt-in against an isolated host with a model and no required workspace.
    /// Never uses a saved Mac connection or sends a message to the user's host.
    func testMessageAloneCanStartChat() throws {
        guard let host = ProcessInfo.processInfo.environment["BEETCODE_NEW_CHAT_UI_HOST"] else {
            throw XCTSkip("Set BEETCODE_NEW_CHAT_UI_HOST to an isolated test host.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["BEETCODE_REMOTE_TEST_URL"] = host
        app.launchEnvironment["BEETCODE_REMOTE_TEST_TOKEN"] = "local-ui-fixture-token"
        app.launchEnvironment["VAMP_TEST_APPEARANCE"] = "light"
        app.launch()
        let newSession = app.buttons["Start a new session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15))
        XCTAssertTrue(newSession.isEnabled)
        newSession.tap()
        let input = app.textFields["remote.start.prompt"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let start = app.buttons["remote.start.submit"]
        XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(app.buttons["Auto mode"].exists, "Advanced choices start collapsed")
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "new-chat-default"
        empty.lifetime = .keepAlways
        add(empty)
        input.tap()
        input.typeText("Hello from the simplified chat.")
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable, "Start stays reachable above the keyboard")
        let ready = XCTAttachment(screenshot: app.screenshot())
        ready.name = "new-chat-keyboard-ready"
        ready.lifetime = .keepAlways
        add(ready)
        start.tap()
        XCTAssertTrue(app.staticTexts["Session created successfully."].waitForExistence(timeout: 15))
    }
}

@MainActor
final class ModelPickerUITests: XCTestCase {
    private func launch(_ state: String = "ready", appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VAMP_REMOTE_TEST_SCREEN"] = "model-picker"
        app.launchEnvironment["VAMP_REMOTE_FIXTURE"] = state
        app.launchEnvironment["VAMP_TEST_APPEARANCE"] = appearance
        app.launch()
        return app
    }

    func testUnloadPreservesModelListInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let unload = app.buttons["remote.model.unload"]
            XCTAssertTrue(unload.waitForExistence(timeout: 15))
            XCTAssertTrue(unload.isEnabled)
            XCTAssertTrue(unload.isHittable)
            XCTAssertGreaterThanOrEqual(unload.frame.height, 44)
            let before = XCTAttachment(screenshot: app.screenshot())
            before.name = "model-picker-\(appearance)-loaded"
            before.lifetime = .keepAlways
            add(before)
            unload.tap()
            XCTAssertTrue(app.staticTexts["remote.model.unloaded"].waitForExistence(timeout: 5))
            XCTAssertFalse(unload.exists)
            XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Ternary Bonsai 27B").firstMatch.exists)
            let after = XCTAttachment(screenshot: app.screenshot())
            after.name = "model-picker-\(appearance)-unloaded"
            after.lifetime = .keepAlways
            add(after)
            app.terminate()
        }
    }

    func testBusyAndDisconnectedModelsCannotUnload() {
        for state in ["busy", "offline"] {
            let app = launch(state, appearance: "dark")
            let unload = app.buttons["remote.model.unload"]
            XCTAssertTrue(unload.waitForExistence(timeout: 15))
            XCTAssertFalse(unload.isEnabled)
            app.terminate()
        }
    }
}

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
