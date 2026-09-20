import XCTest

/// The Control Mac action opens a full-screen control surface. A hang there is invisible to
/// unit tests, so drive it the way a person does: tap the button, wait for the surface, leave it,
/// and prove the app still answers.
@MainActor
final class ControlSurfaceUITests: XCTestCase {
    /// The local mock control host (127.0.0.1:9576) is a development harness: without it the
    /// session list is unreachable and this test has nothing to drive. Skip rather than fail.
    private func requireMockHost() throws {
        let url = URL(string: "http://127.0.0.1:9576/api/control")!
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        try XCTSkipUnless(reachable, "start /tmp/mock_vamp_host.py to run the control-surface harness")
    }

    func testControlMacTapStaysResponsive() throws {
        try requireMockHost()
        let app = XCUIApplication()
        app.launchEnvironment["VAMP_UITEST"] = "1"
        // Point the client at the local mock control host so the session list is reachable and
        // the control surface takes its connected path.
        app.launchEnvironment["BEETCODE_REMOTE_TEST_URL"] = "http://127.0.0.1:9576"
        app.launchEnvironment["BEETCODE_REMOTE_TEST_TOKEN"] = "mock"
        app.launch()

        let controlButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "control mac"))
            .firstMatch
        XCTAssertTrue(
            controlButton.waitForExistence(timeout: 30),
            "session header never appeared — the app is stuck before the control surface")

        controlButton.tap()

        let close = app.buttons["Close remote control"].firstMatch
        XCTAssertTrue(
            close.waitForExistence(timeout: 15),
            "tapping Control Mac never produced the control surface — the main thread is blocked")

        // A second, unhurried interaction proves the main thread is actually free rather than
        // merely having painted one frame before wedging.
        sleep(3)
        XCTAssertTrue(close.isHittable, "the control surface stopped accepting touches")

        close.tap()
        XCTAssertTrue(
            controlButton.waitForExistence(timeout: 15),
            "the app never returned from the control surface — it wedged on dismiss")
    }
}
