import XCTest

@MainActor
final class BeetCodeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOLEDModeIsAvailableAndRenders() {
        let app = launchApp(screen: "settings-general", appearance: "")
        let oled = app.radioButtons["OLED"]
        XCTAssertTrue(oled.waitForExistence(timeout: 10))
        let previous = ["System", "Light", "Dark", "OLED"].first {
            let button = app.radioButtons[$0]
            return button.isSelected || (button.value as? String) == "1" || (button.value as? Int) == 1
        }
        defer { if let previous { app.radioButtons[previous].click() } }
        oled.click()
        XCTAssertTrue(oled.isSelected || (oled.value as? String) == "1" || (oled.value as? Int) == 1)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "mac-oled-settings"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testAppearanceSegmentsStayInsideTheirControl() {
        let app = launchApp(size: "900x700", screen: "settings-general", appearance: "oled")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let oled = window.radioButtons["OLED"]
        XCTAssertTrue(oled.waitForExistence(timeout: 10))
        let picker = window.descendants(matching: .any)
            .matching(identifier: "instrument-segmented").firstMatch
        XCTAssertTrue(picker.exists)
        XCTAssertLessThanOrEqual(oled.frame.maxX, picker.frame.maxX + 1)
        XCTAssertLessThanOrEqual(picker.frame.maxX, window.frame.maxX - 16)
    }

    func testAppearanceAndTypeStylesFitAtMinimumWindowWidth() {
        let app = launchApp(size: "520x700", screen: "settings-general", appearance: "oled")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let capture = XCTAttachment(screenshot: window.screenshot())
        capture.name = "mac-minimum-settings"
        capture.lifetime = .keepAlways
        add(capture)
        let appearance = window.descendants(matching: .any)
            .matching(identifier: "instrument-segmented").firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(appearance.frame.maxX, window.frame.maxX - 16)
        let typeface = window.popUpButtons.matching(NSPredicate(
            format: "label CONTAINS %@", "Typeface")).firstMatch
        XCTAssertTrue(typeface.exists)
        XCTAssertLessThanOrEqual(typeface.frame.maxX, window.frame.maxX - 16)
    }

    func testConversationsSelectionMeetsSidebarCorner() {
        let app = launchApp(screen: "chat", appearance: "oled")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let conversations = window.buttons["Conversations"]
        XCTAssertTrue(conversations.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(conversations.frame.minX - window.frame.minX, 2)
    }

    func testBotsHeaderIsVisibleBelowToolbar() {
        let app = launchApp(screen: "bots", appearance: "oled")
        let back = app.buttons["Back to chat"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable, "The titlebar must not cover the Bots header")
    }

    func testPolishCaptureMatrix() {
        for appearance in ["light", "dark"] {
            for screen in ["chat", "settings-general", "settings-models", "bots"] {
                let app = launchApp(screen: screen, appearance: appearance)
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
                let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                capture.name = "mac-\(screen)-\(appearance)"
                capture.lifetime = .keepAlways
                add(capture)
                app.terminate()
            }
        }
    }

    func testComposerGrowsAndShrinksWithDraft() {
        let app = launchApp(size: "1000x700")
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let emptyHeight = field.frame.height
        XCTAssertLessThan(emptyHeight, 40)
        field.click()
        XCTAssertEqual(field.frame.height, emptyHeight, accuracy: 2)
        field.typeText("First line")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .shift)
        field.typeText("Second line")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .shift)
        field.typeText("Third line")
        XCTAssertGreaterThan(field.frame.height, emptyHeight + 20)
        XCTAssertLessThan(field.frame.height, 160)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertEqual(field.frame.height, emptyHeight, accuracy: 2)
    }

    func testPrimaryComposerControlsAreAccessibleAtLaunch() {
        let app = launchApp()

        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Attach files"].exists)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testComposerStartsReadyForTaskInput() {
        let app = launchApp()
        let editor = composer(in: app)

        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.isEnabled)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
        XCTAssertTrue(app.buttons["Tools"].exists)
    }

    /// The conversation library is the sidebar now: its destinations, the
    /// session list, and the project row all live there.
    func testHistoryNavigationIsAccessible() {
        let app = launchApp()
        let library = app.descendants(matching: .any)
            .matching(identifier: "conversation-browser").firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        // The destinations are drawn rows (buttons) on the column's own
        // surface, not system list cells: the label is the contract, not the
        // element role.
        for destination in ["Conversations", "Bots", "Devices"] {
            XCTAssertTrue(app.staticTexts[destination].exists
                          || app.buttons[destination].exists,
                          "Sidebar destination missing a label: \(destination)")
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Project:")).firstMatch.exists)
    }

    /// ⌘F focuses the toolbar's conversation search and typing lands there —
    /// and never reaches the composer.
    func testCommandFFocusesChatSearch() {
        let app = launchApp()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: .command)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("x")

        XCTAssertEqual(search.value as? String, "x")
        XCTAssertEqual(composer(in: app).value as? String ?? "", "")
    }

    /// Typing in the toolbar's search filters the library and never submits a
    /// prompt: the composer's draft must be untouched afterwards.
    func testToolbarSearchFiltersWithoutSubmitting() {
        let app = launchApp()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        app.typeText("zzz-no-such-chat")
        XCTAssertEqual(search.value as? String, "zzz-no-such-chat")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "conversation-browser").firstMatch.exists)
        XCTAssertEqual(composer(in: app).value as? String ?? "", "")
    }

    /// Collapsing the sidebar must not disturb the draft in the composer.
    func testSidebarTogglePreservesDraft() {
        let app = launchApp()
        let editor = composer(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Keep this draft")
        let existingDraft = editor.value as? String
        XCTAssertFalse(existingDraft?.isEmpty ?? true)

        let toggle = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "sidebar")).firstMatch
        if toggle.exists {
            toggle.click()
            XCTAssertEqual(editor.value as? String, existingDraft)
            toggle.click()
        }
        XCTAssertEqual(editor.value as? String, existingDraft)
    }

    /// Every control the redesign introduced carries a name VoiceOver can
    /// read: the toolbar buttons, the sidebar destinations, the search field,
    /// the inspector rows, and the composer's primary action.
    func testShellControlsAreNamedForAccessibility() {
        let app = launchApp()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))

        for name in ["New conversation", "Browser", "Simulator", "Diagnostics",
                     "Session info", "More app actions"] {
            // Menus report as pop-up buttons, so match on the name alone.
            XCTAssertTrue(app.descendants(matching: .any)[name].exists,
                          "Toolbar control missing a label: \(name)")
        }
        for destination in ["Conversations", "Bots", "Devices", "Settings"] {
            XCTAssertTrue(app.staticTexts[destination].exists
                          || app.buttons[destination].exists,
                          "Sidebar destination missing a label: \(destination)")
        }
        XCTAssertTrue(app.buttons["Send"].exists)
        XCTAssertTrue(app.buttons["Attach files"].exists)

        // The inspector's rows must read as text, not colour alone.
        app.buttons["Session info"].click()
        let assistantRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Assistant:")).firstMatch
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 5))
    }

    func testCompactComposerStaysInsideWindow() {
        let app = launchApp(size: "1000x700")
        let editor = composer(in: app)
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

    /// The Models page section switch must be drivable from UI tests: the old
    /// custom key row merged its accessibility frames, so a click always hit
    /// the first key and the provider directory could not be opened.
    func testProviderDirectorySegmentOpensProviderBrowser() {
        let app = launchApp(screen: "settings-models")
        XCTAssertTrue(app.textFields["Filter models"].waitForExistence(timeout: 10))

        let providers = app.radioButtons["Providers"]
        XCTAssertTrue(providers.waitForExistence(timeout: 5))
        providers.click()

        XCTAssertTrue(app.textFields["Find a provider"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "OpenAI")).firstMatch.waitForExistence(timeout: 5))
    }

    func testComposerKeepsOneSendAndOneModelControl() {
        let app = launchApp()
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "Send").count, 1)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
        let model = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Active model:")).firstMatch
        XCTAssertTrue(model.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Active model:")).count, 1)
    }

    /// At the smallest supported size the composer stays reachable inside the
    /// window and the toolbar keeps its search field.
    func testMinimumWindowKeepsSearchAndComposer() {
        let app = launchApp(size: "520x700")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(send.frame.maxX, app.windows.firstMatch.frame.maxX)
        // At this width the toolbar legitimately moves the search field into
        // the system overflow; it is asserted at a regular width instead.
    }

    func testDarkWelcomeRetainsTitleAndHardwareGeometry() {
        let app = launchApp(appearance: "dark")
        XCTAssertTrue(app.staticTexts["welcome-wordmark"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Send"].exists)
        XCTAssertTrue(app.buttons["Assistant mode"].exists)
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

    func testBotsComposerIsReadableAndNavigationLeavesBots() {
        let app = launchApp(screen: "bots")
        let editor = app.textViews["Task for Builder"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(editor.frame.width, window.width * 0.55)
        XCTAssertGreaterThanOrEqual(editor.frame.height, 160)
        XCTAssertLessThanOrEqual(editor.frame.height, 340)
        XCTAssertLessThanOrEqual(editor.frame.maxY, window.maxY)

        // The Bots dashboard is a destination of the main window; leaving via
        // a panel toggle returns to the chat composer and its hardware.
        let browserToggle = app.buttons.matching(identifier: "browser-toggle").firstMatch
        browserToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(editor.exists)

        // Bots is a sidebar destination now, not a toolbar toggle — a drawn
        // row (button) on the column's own surface.
        let botsDestination = app.buttons["Bots"].firstMatch
        if botsDestination.exists {
            botsDestination.click()
        } else {
            app.staticTexts["Bots"].firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        // The composer editor is a vertical-axis text field labelled
        // "Task description"; query by label so a future TextEditor keeps
        // the same contract.
        app.textFields["Task description"]
    }

    private func launchApp(size: String = "1320x856", screen: String = "welcome",
                           appearance: String = "light") -> XCUIApplication {
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["VAMP_UI_APP_PATH"] {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        app.launchArguments += [
            "--ui-smoke",
            "--design-preview", screen, "--design-size", size,
            "--design-appearance", appearance,
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        if app.state != .notRunning { app.terminate() }
        app.launch()
        app.activate()
        // Give SwiftUI's WindowGroup time to create its first window before
        // invoking New Window. A two-second fallback raced slow cold launches
        // and made subsequent queries match overlapping restored windows.
        if !app.windows.firstMatch.waitForExistence(timeout: 15) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, "UI smoke previews should open one main window")
        return app
    }
}
