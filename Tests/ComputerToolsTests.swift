import XCTest
import Carbon
@testable import BeetCode

/// Computer-use unit tests. Everything here is hermetic: key mapping, AX-tree
/// rendering, argument accessors, registration. Posting real CGEvents or
/// reading a live AX tree is exercised manually (and would be hostile in CI).
final class ComputerToolsTests: XCTestCase {

    // MARK: Key mapping

    func testNamedKeysResolve() {
        XCTAssertEqual(ComputerKey.keyCode(for: "return"), 36)
        XCTAssertEqual(ComputerKey.keyCode(for: "Enter"), 36) // case-insensitive
        XCTAssertEqual(ComputerKey.keyCode(for: "escape"), 53)
        XCTAssertEqual(ComputerKey.keyCode(for: "esc"), 53)
        XCTAssertEqual(ComputerKey.keyCode(for: "tab"), 48)
        XCTAssertEqual(ComputerKey.keyCode(for: "left"), 123)
        XCTAssertEqual(ComputerKey.keyCode(for: "f5"), 96)
        XCTAssertEqual(ComputerKey.keyCode(for: "page_down"), 121)
    }

    func testSingleCharacterKeysResolve() {
        XCTAssertEqual(ComputerKey.keyCode(for: "a"), 0)
        XCTAssertEqual(ComputerKey.keyCode(for: "S"), 1)
        XCTAssertEqual(ComputerKey.keyCode(for: "0"), 29)
    }

    func testUnknownKeysReturnNil() {
        XCTAssertNil(ComputerKey.keyCode(for: "hyper"))
        XCTAssertNil(ComputerKey.keyCode(for: "ab")) // multi-char, not a named key
        XCTAssertNil(ComputerKey.keyCode(for: ""))
    }

    func testModifierMapping() {
        XCTAssertEqual(ComputerKey.modifiers(for: ["cmd"]), .maskCommand)
        XCTAssertEqual(ComputerKey.modifiers(for: ["command", "shift"]),
                       [.maskCommand, .maskShift])
        XCTAssertEqual(ComputerKey.modifiers(for: ["opt"]), .maskAlternate)
        XCTAssertEqual(ComputerKey.modifiers(for: ["ctrl"]), .maskControl)
        XCTAssertEqual(ComputerKey.modifiers(for: ["bogus"]), [])
    }

    @MainActor
    func testLoginWindowUSAndTurkishLayoutsResolveDifferentPhysicalKeys() throws {
        func layout(_ id: String) throws -> CFData {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            let sources = try XCTUnwrap(TISCreateInputSourceList(filter, true)).takeRetainedValue() as NSArray
            let source = try XCTUnwrap(sources.firstObject) as! TISInputSource
            let raw = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        }
        let us = try layout("com.apple.keylayout.US")
        let turkish = try layout("com.apple.keylayout.Turkish-QWERTY-PC")
        XCTAssertEqual(try LoginWindowInputService.keys("i", layoutData: us), [.init(code: 34)])
        XCTAssertEqual(
            try LoginWindowInputService.keys("ı", layoutData: turkish),
            [.init(code: 34)])
        XCTAssertEqual(try LoginWindowInputService.keys("şğıİç", layoutData: turkish).count, 5)
        XCTAssertThrowsError(try LoginWindowInputService.keys("🙂", layoutData: us))
    }

    // MARK: AX tree rendering

    func testRenderFormatsNodesWithCoordinates() {
        let nodes = [
            AXNodeInfo(depth: 0, role: "AXWindow", label: "Document", value: "",
                       frame: CGRect(x: 100, y: 50, width: 800, height: 600), enabled: true),
            AXNodeInfo(depth: 1, role: "AXButton", label: "Save", value: "",
                       frame: CGRect(x: 808, y: 606, width: 64, height: 28), enabled: true),
        ]
        let text = AXTreeWalker.render(nodes)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("AXWindow \"Document\""))
        XCTAssertTrue(lines[1].hasPrefix("  AXButton \"Save\""), "children indent by depth")
        // Center point of the frame, top-left origin — what computer_click takes.
        XCTAssertTrue(lines[1].contains("at (840,620)"))
        XCTAssertTrue(lines[1].contains("64×28"))
    }

    func testRenderShowsValueWhenDifferentFromLabel() {
        let node = AXNodeInfo(depth: 0, role: "AXTextField", label: "Search",
                              value: "beet", frame: .zero, enabled: true)
        let text = AXTreeWalker.render([node])
        XCTAssertTrue(text.contains("value \"beet\""))
        XCTAssertFalse(text.contains("at ("), "zero frame renders no coordinates")
    }

    func testRenderMarksDisabledElements() {
        let node = AXNodeInfo(depth: 0, role: "AXButton", label: "Go",
                              value: "", frame: .zero, enabled: false)
        XCTAssertTrue(AXTreeWalker.render([node]).contains("[disabled]"))
    }

    func testRenderEmptyTreeHasPlaceholder() {
        XCTAssertEqual(AXTreeWalker.render([]), "(no accessible elements found)")
    }

    func testRenderIncludesFreshElementReferencesWhenProvided() {
        let node = AXNodeInfo(
            depth: 0,
            role: "AXButton",
            label: "Continue",
            value: "",
            frame: CGRect(x: 20, y: 30, width: 80, height: 40),
            enabled: true)
        let text = AXTreeWalker.render([node], references: [0: "c3:e1"])
        XCTAssertTrue(text.contains("[ref=c3:e1]"))
    }

    func testNewComputerObservationInvalidatesOlderRefs() throws {
        let first = AXNodeInfo(
            depth: 0,
            role: "AXButton",
            label: "First",
            value: "",
            frame: CGRect(x: 10, y: 20, width: 40, height: 20),
            enabled: true)
        let firstRefs = AXReferenceStore.capture([first])
        let firstRef = try XCTUnwrap(firstRefs[0])
        XCTAssertNotNil(AXReferenceStore.resolve(firstRef))

        let second = AXNodeInfo(
            depth: 0,
            role: "AXButton",
            label: "Second",
            value: "",
            frame: CGRect(x: 100, y: 200, width: 60, height: 30),
            enabled: true)
        let secondRefs = AXReferenceStore.capture([second])
        let secondRef = try XCTUnwrap(secondRefs[0])
        XCTAssertNil(AXReferenceStore.resolve(firstRef))
        let resolved = try XCTUnwrap(AXReferenceStore.resolve(secondRef))
        XCTAssertEqual(resolved.point.x, 130, accuracy: 0.5)
        XCTAssertEqual(resolved.point.y, 215, accuracy: 0.5)
    }

    // MARK: strings accessor

    func testStringsAccessorReadsArraysAndSingleStrings() {
        let arrayCall = ToolParser.parse(
            #"```tool {"name":"computer_key","arguments":{"key":"s","modifiers":["cmd","shift"]}} ```"#)
            .first
        XCTAssertEqual(arrayCall?.strings("modifiers"), ["cmd", "shift"])

        let singleCall = ToolParser.parse(
            #"```tool {"name":"computer_key","arguments":{"key":"s","modifiers":"cmd"}} ```"#)
            .first
        XCTAssertEqual(singleCall?.strings("modifiers"), ["cmd"],
                       "a bare string is a one-element array — models emit both")

        XCTAssertEqual(arrayCall?.strings("missing"), [])
    }

    // MARK: Registration

    @MainActor
    func testComputerToolsRegisteredWithCorrectRiskClasses() {
        let tools = Dictionary(
            uniqueKeysWithValues: AgentSessionController.computerControlTools.map { ($0.name, $0.risk) })
        // Observation: auto-approved reads.
        XCTAssertEqual(tools["computer_status"], .read)
        XCTAssertEqual(tools["computer_ui_tree"], .read)
        XCTAssertEqual(tools["computer_screenshot"], .read)
        // Input: approval-gated, always.
        XCTAssertEqual(tools["computer_click"], .execute)
        XCTAssertEqual(tools["computer_type"], .execute)
        XCTAssertEqual(tools["computer_key"], .execute)
        XCTAssertEqual(tools["computer_scroll"], .execute)
    }

    func testComputerActionSchemasExposeFreshRefsAndCapture() throws {
        for schema in [
            ComputerClickTool().schemaText,
            ComputerTypeTool().schemaText,
            ComputerScrollTool().schemaText,
        ] {
            XCTAssertTrue(schema.contains("\"ref\""))
            XCTAssertTrue(schema.contains("capture_after"))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(schema.utf8)))
        }
    }

    @MainActor
    func testComputerToolsAreOptInNotDefault() {
        let defaultNames = Set(AgentSessionController.defaultTools.map(\.name))
        XCTAssertFalse(defaultNames.contains("computer_click"))
        XCTAssertFalse(defaultNames.contains("computer_ui_tree"))

        let optedIn = Set(
            AgentSessionController.sessionTools(computerControlEnabled: true).map(\.name))
        XCTAssertTrue(optedIn.contains("computer_click"))
        XCTAssertTrue(optedIn.contains("sim_build_run"))
        XCTAssertTrue(optedIn.contains("read_file"))
    }

    @MainActor
    func testComputerToolSchemasAreValidJSON() {
        for tool in AgentSessionController.computerControlTools {
            let data = Data(tool.schemaText.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "\(tool.name) schemaText must be valid JSON")
        }
    }

    // MARK: Coordinate clamp (Quartz space — no Y flip)

    func testClampDoesNotFlipY() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let point = ComputerEvents.clamped(840, 620, quartzBounds: bounds)
        XCTAssertEqual(point.x, 840, accuracy: 0.5)
        XCTAssertEqual(point.y, 620, accuracy: 0.5, "AX/CGEvent Y is already top-left; must not be inverted")
    }

    func testClampKeepsSecondaryMonitorLeft() {
        let bounds = CGRect(x: -1920, y: 0, width: 3360, height: 1080)
        let point = ComputerEvents.clamped(-100, 200, quartzBounds: bounds)
        XCTAssertEqual(point.x, -100, accuracy: 0.5)
        XCTAssertEqual(point.y, 200, accuracy: 0.5)
    }

    func testClampPinsOffscreenPoints() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let point = ComputerEvents.clamped(99_999, -50, quartzBounds: bounds)
        XCTAssertEqual(point.x, 1439, accuracy: 0.5)
        XCTAssertEqual(point.y, 0, accuracy: 0.5)
    }

    func testRemoteMacControlParsesClickAndRejectsUnknown() {
        let click = RemoteMacControl.parse(action: "click", x: 120, y: 80)
        XCTAssertEqual(click, .success(.click(x: 120, y: 80, button: "left", count: 1)))
        let typed = RemoteMacControl.parse(action: "type", text: "hello")
        XCTAssertEqual(typed, .success(.type("hello")))
        let unknown = RemoteMacControl.parse(action: "explode")
        XCTAssertEqual(unknown, .failure(.message("Unknown control action.")))
        let blocked = RemoteMacControl.parse(action: "key", key: "q", modifiers: ["cmd"])
        XCTAssertEqual(blocked, .failure(.message("That shortcut is blocked.")))
        let rel = RemoteMacControl.parse(action: "rel", x: 4, y: -2)
        XCTAssertEqual(rel, .success(.moveRelative(dx: 4, dy: -2)))
        let down = RemoteMacControl.parse(action: "down", button: "left")
        XCTAssertEqual(down, .success(.down("left")))
        let right = RemoteMacControl.parse(action: "click", button: "right")
        XCTAssertEqual(right, .success(.click(x: nil, y: nil, button: "right", count: 1)))
        let middle = RemoteMacControl.parse(action: "click", x: 10, y: 20, button: "middle", count: 2)
        XCTAssertEqual(middle, .success(.click(x: 10, y: 20, button: "middle", count: 2)))
    }

    func testComputerPermissionRecognizesSecureLockSession() {
        XCTAssertTrue(ComputerPermission.sessionIsLocked(["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(ComputerPermission.sessionIsLocked(["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(ComputerPermission.sessionIsLocked(nil))
    }

    // MARK: Dangerous shortcuts

    func testBlocksQuitLogoutLockAndForceQuit() {
        XCTAssertTrue(ComputerKey.isBlocked(key: "q", modifiers: ["cmd"]))
        XCTAssertTrue(ComputerKey.isBlocked(key: "q", modifiers: ["command", "shift"]))
        XCTAssertTrue(ComputerKey.isBlocked(key: "q", modifiers: ["ctrl", "cmd"]))
        XCTAssertTrue(ComputerKey.isBlocked(key: "escape", modifiers: ["cmd", "alt"]))
        XCTAssertTrue(ComputerKey.isBlocked(key: "esc", modifiers: ["cmd", "option"]))
        XCTAssertFalse(ComputerKey.isBlocked(key: "s", modifiers: ["cmd"]))
        XCTAssertFalse(ComputerKey.isBlocked(key: "return", modifiers: []))
        XCTAssertFalse(ComputerKey.isBlocked(key: "q", modifiers: []))
    }

    // MARK: Screenshot window pick

    func testPickerPrefersFrontmostLargestStandardWindow() {
        let windows = [
            CaptureCandidate(bundleID: "com.apple.Safari", isOnScreen: true, layer: 0, area: 100),
            CaptureCandidate(bundleID: "com.apple.Safari", isOnScreen: true, layer: 0, area: 9_000),
            CaptureCandidate(bundleID: "com.apple.finder", isOnScreen: true, layer: 0, area: 50_000),
            CaptureCandidate(bundleID: "com.apple.Safari", isOnScreen: true, layer: 25, area: 80_000),
        ]
        XCTAssertEqual(
            CaptureWindowPicker.pickIndex(
                windows: windows, frontmostBundleID: "com.apple.Safari", selfBundleID: "com.beetcode.app"),
            1)
    }

    func testPickerIgnoresSelfAndOffscreen() {
        let windows = [
            CaptureCandidate(bundleID: "com.beetcode.app", isOnScreen: true, layer: 0, area: 9_000),
            CaptureCandidate(bundleID: "com.apple.Safari", isOnScreen: false, layer: 0, area: 9_000),
        ]
        XCTAssertNil(
            CaptureWindowPicker.pickIndex(
                windows: windows, frontmostBundleID: "com.beetcode.app", selfBundleID: "com.beetcode.app"))
        XCTAssertNil(
            CaptureWindowPicker.pickIndex(
                windows: windows, frontmostBundleID: "com.apple.Safari", selfBundleID: "com.beetcode.app"))
    }

    // MARK: Secure field redaction

    func testRenderRedactsSecureFieldValues() {
        let node = AXNodeInfo(
            depth: 0, role: "AXSecureTextField", label: "Password",
            value: "(redacted)", frame: .zero, enabled: true)
        let text = AXTreeWalker.render([node])
        XCTAssertTrue(text.contains("Password"))
        XCTAssertTrue(text.contains("(redacted)"))
        XCTAssertFalse(text.contains("hunter2"))
    }
}

@MainActor
final class LoginWindowInputServiceTests: XCTestCase {
    private typealias Key = LoginWindowInputService.Key

    @MainActor private final class Fixture {
        var locked = true
        var accessibility = true
        var events: [(Key, Bool)] = []
        var waits: [Duration] = []
        var onWait: (() throws -> Void)?
        var keys = [Key(code: 18), Key(code: 19, modifiers: .maskShift)]

        func service() -> LoginWindowInputService {
            LoginWindowInputService(
                isLocked: { self.locked },
                hasAccessibility: { self.accessibility },
                resolveKeys: { $0 == "a" ? [Key(code: 0)] : self.keys },
                postKey: { self.events.append(($0, $1)) },
                sleep: { duration in
                    self.waits.append(duration)
                    try self.onWait?()
                }
            )
        }
    }

    func testWakeClearPasswordAndReturnSequenceIsBalancedAndRepeatable() async throws {
        let fixture = Fixture()
        let service = fixture.service()
        for _ in 0..<2 {
            fixture.events = []
            try await service.submit(password: "example")
            let downs = fixture.events.filter(\.1).map(\.0)
            XCTAssertEqual(
                downs,
                [Key(code: 49), Key(code: 0, modifiers: .maskCommand), Key(code: 51)]
                    + fixture.keys + [Key(code: 36)])
            XCTAssertEqual(fixture.events.count, downs.count * 2)
            for index in stride(from: 0, to: fixture.events.count, by: 2) {
                XCTAssertEqual(fixture.events[index].0, fixture.events[index + 1].0)
                XCTAssertFalse(fixture.events[index + 1].1)
            }
        }
        XCTAssertTrue(fixture.waits.contains(.milliseconds(750)))
    }

    func testLocalUnlockStopsBeforePasswordAndBalancesWakeKey() async {
        let fixture = Fixture()
        fixture.onWait = { fixture.locked = false }
        do {
            try await fixture.service().submit(password: "example")
            XCTFail("Must stop when the Mac unlocks locally")
        } catch {
            XCTAssertEqual(fixture.events.map(\.0.code), [49, 49])
            XCTAssertFalse(fixture.events.last?.1 ?? true)
        }
    }

    func testPermissionLossAndCancellationStopBeforePassword() async {
        for error in [false, true] {
            let fixture = Fixture()
            fixture.onWait = {
                if error { throw CancellationError() }
                fixture.accessibility = false
            }
            do {
                try await fixture.service().submit(password: "example")
                XCTFail("Must stop safely")
            } catch {
                XCTAssertEqual(fixture.events.map(\.0.code), [49, 49])
                XCTAssertFalse(fixture.events.last?.1 ?? true)
            }
        }
    }

    func testLayoutFailurePostsNothingAndDoesNotExposePassword() async {
        var posted = false
        let service = LoginWindowInputService(
            isLocked: { true }, hasAccessibility: { true },
            resolveKeys: { _ in
                throw RemoteMacControl.ParseError.message("Unsupported keyboard layout")
            },
            postKey: { _, _ in posted = true }, sleep: { _ in }
        )
        do {
            try await service.submit(password: "never-log-this")
            XCTFail("Must reject unsupported input before posting")
        } catch {
            XCTAssertFalse(posted)
            XCTAssertFalse(error.localizedDescription.contains("never-log-this"))
        }
    }
}
