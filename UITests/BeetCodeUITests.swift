import AppKit
import XCTest

@MainActor
final class BeetCodeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsRoundTripPreservesToolbarAndDraft() {
        let app = launchApp()
        defer { app.terminate() }
        let editor = composer(in: app)
        editor.click(); pasteText("Keep this draft through Settings", app: app)
        app.buttons["Settings"].click()
        XCTAssertTrue(app.staticTexts["General"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sidebar")).firstMatch.exists)
        XCTAssertTrue(app.buttons["new-conversation"].exists)
        XCTAssertEqual(app.windows.firstMatch.toolbars.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sidebar")).count, 1)
        app.buttons["Chats"].click()
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer(in: app).value as? String, "Keep this draft through Settings")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sidebar")).firstMatch.click()
        XCTAssertEqual(composer(in: app).value as? String, "Keep this draft through Settings")
        XCTAssertTrue(app.buttons["command-palette-toggle"].exists)
    }

    func testBrowserKeepsComposerInsideWindowAndDraftIntact() {
        let app = launchApp(screen: "chat")
        defer { app.terminate() }
        composer(in: app).click(); pasteText("Finish the UI review", app: app)
        workspaceAction("Browser", app: app)
        XCTAssertTrue(app.textFields["browser-url"].waitForExistence(timeout: 5))
        assertComposerBounds(app)
        XCTAssertEqual(composer(in: app).value as? String, "Finish the UI review")
        app.buttons["Close Browser"].click()
        assertComposerBounds(app)
        XCTAssertEqual(composer(in: app).value as? String, "Finish the UI review")
    }

    func testNestedDockingAndKeyboardMenuReset() {
        let app = launchApp(screen: "docking")
        defer { app.terminate() }
        XCTAssertTrue(app.textFields["browser-url"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dock-split-")).count, 2)
        assertComposerBounds(app)
        // The native context menu provides the keyboard equivalent of edge drops.
        app.buttons["Browser pane"].rightClick()
        app.menuItems["Dock below conversation"].click()
        assertComposerBounds(app)
        workspaceAction("Reset Layout", app: app)
        XCTAssertTrue(app.buttons["Conversation pane"].exists)
        XCTAssertTrue(app.buttons["Browser pane"].exists)
        XCTAssertTrue(app.buttons["Diagnostics pane"].exists)
    }

    func testNarrowDockingProvidesPaneSwitcherAndReturnToConversation() {
        let app = launchApp(size: "520x640", screen: "docking")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Focus layout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Back to conversation"].exists)
        app.buttons["Back to conversation"].click()
        assertComposerBounds(app)
        XCTAssertFalse(app.buttons["Close Conversation"].exists)
    }

    func testSidebarSearchAndCommandPaletteHaveSeparateKeyboardFlows() {
        let app = launchApp()
        defer { app.terminate() }
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["conversation-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        pasteText("nothing-matches-this-chat", app: app)
        XCTAssertEqual(search.value as? String, "nothing-matches-this-chat")
        XCTAssertEqual(composer(in: app).value as? String, "")
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields["command-palette-search"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        pasteText("Devices", app: app)
        XCTAssertEqual(palette.value as? String, "Devices")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Remote access"].waitForExistence(timeout: 5))
    }

    func testComposerGrowsAndShrinksWithoutClipping() {
        let app = launchApp(size: "900x700")
        defer { app.terminate() }
        let field = composer(in: app)
        let original = field.frame.height
        field.click()
        for index in 1...4 {
            pasteText("Draft line \(index)", app: app)
            app.typeKey(.return, modifierFlags: .shift)
        }
        XCTAssertGreaterThan(composer(in: app).frame.height, original)
        assertComposerBounds(app)
        app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(composer(in: app).value as? String, "")
        assertComposerBounds(app)
    }

    func testModelsAndProviderRowsStayInsideNormalAndNarrowWindows() {
        for size in ["1240x840", "520x700"] {
            let app = launchApp(size: size, screen: "settings-models")
            let window = app.windows.firstMatch
            let filter = app.textFields["Filter models"]
            XCTAssertTrue(filter.waitForExistence(timeout: 10))
            XCTAssertLessThanOrEqual(filter.frame.maxX, window.frame.maxX - 12)
            let providers = app.radioButtons["Providers"]
            XCTAssertTrue(providers.exists)
            providers.click()
            let providerSearch = app.textFields["Find a provider"]
            XCTAssertTrue(providerSearch.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(providerSearch.frame.maxX, window.frame.maxX - 12)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ChatGPT,")).firstMatch.click()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(app.buttons["Done"].frame.maxX, window.frame.maxX)
            app.terminate()
        }
    }

    func testDelegationIsInlineAndApprovalsRemainAccessible() {
        let app = launchApp(screen: "delegation")
        defer { app.terminate() }
        let work = app.descendants(matching: .any)["inline-specialist-work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        let review = app.buttons["Review"].firstMatch
        if !review.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(review.exists)
        review.click()
        XCTAssertTrue(app.buttons["Specialist work pane"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Allow"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Bots"].exists)
        XCTAssertFalse(app.buttons["Team task"].exists)
        assertComposerBounds(app)
    }

    func testDevicesShowsStatusPairingAndSharedPermissions() {
        let app = launchApp(screen: "devices")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Remote access"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running"].exists)
        XCTAssertTrue(app.staticTexts["2 paired clients"].exists)
        XCTAssertTrue(app.staticTexts["482 716"].exists)
        XCTAssertTrue(app.staticTexts["Sharing"].exists)
        XCTAssertFalse(app.buttons["Enable remote access"].exists)
    }

    func testAppearanceControlsFitAtMinimumWidthAndPreserveOLED() {
        let app = launchApp(size: "520x700", screen: "settings-general", appearance: "oled")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let oled = app.radioButtons["OLED"]
        XCTAssertTrue(oled.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(oled.frame.maxX, window.frame.maxX - 12)
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
        capture(app, name: "settings-oled-minimum")
    }

    func testVisualPreviewMatrix() {
        for appearance in ["light", "dark"] {
            for screen in ["welcome", "chat", "approvals", "delegation", "docking", "settings-models", "devices", "settings-general"] {
                let app = launchApp(screen: screen, appearance: appearance)
                if screen == "settings-models" { XCTAssertTrue(app.textFields["Filter models"].waitForExistence(timeout: 5)) }
                else if ["welcome", "chat", "approvals", "delegation", "docking"].contains(screen) { assertComposerBounds(app) }
                capture(app, name: "redesign-\(screen)-\(appearance)")
                app.terminate()
            }
        }
    }

    /// Xcode's physical-key text injection drops dotted i on Turkish-QWERTY
    /// layouts. Unicode paste tests draft fidelity without changing the Mac's
    /// input source; navigation and shortcuts still use real key events.
    private func pasteText(_ text: String, app: XCUIApplication) {
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { clipboard.clearContents(); if !saved.isEmpty { clipboard.writeObjects(saved) } }
        clipboard.clearContents(); clipboard.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["Task description"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }
    private func assertComposerBounds(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = composer(in: app)
        let window = app.windows.firstMatch
        XCTAssertGreaterThanOrEqual(field.frame.minX, window.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(field.frame.maxX, window.frame.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(field.frame.maxY, window.frame.maxY - 8, file: file, line: line)
        XCTAssertTrue(app.buttons["Send"].exists || app.buttons["Stop"].exists, file: file, line: line)
    }
    private func workspaceAction(_ title: String, app: XCUIApplication) {
        app.menuBars.menuBarItems["Workspace"].click()
        app.menuItems[title].click()
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func launchApp(size: String = "1240x840", screen: String = "welcome", appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-smoke", "--design-preview", screen, "--design-size", size,
            "--design-appearance", appearance, "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        if app.state != .notRunning { app.terminate() }
        app.launch(); app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }
}
