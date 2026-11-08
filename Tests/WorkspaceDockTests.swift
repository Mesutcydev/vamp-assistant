import XCTest
@testable import BeetCode

@MainActor
final class WorkspaceDockTests: XCTestCase {
    func testConversationCannotCloseAndResourcesOpenOnce() {
        let dock = WorkspaceDock(defaults: nil)
        dock.close(.conversation)
        dock.open(.browser)
        dock.open(.browser)
        XCTAssertEqual(dock.panels.filter { $0 == .conversation }.count, 1)
        XCTAssertEqual(dock.panels.filter { $0 == .browser }.count, 1)
        XCTAssertTrue(dock.root.isValidWorkspace)
    }

    func testNestedSplitsTabMovesAndEmptyGroupCollapse() throws {
        let dock = WorkspaceDock(defaults: nil)
        dock.open(.browser)
        dock.open(.diagnostics)
        let group = try XCTUnwrap(dock.group(containing: .browser))
        XCTAssertTrue(dock.move(.diagnostics, to: group.id, placement: .bottom))
        XCTAssertEqual(dock.root.groups.count, 3)
        if case .split(_, .horizontal, _, _, .split(_, .vertical, _, _, _)) = dock.root {} else {
            XCTFail("Expected a vertical split nested inside the horizontal workspace")
        }
        let conversation = try XCTUnwrap(dock.group(containing: .conversation))
        XCTAssertTrue(dock.move(.diagnostics, to: conversation.id, placement: .center))
        XCTAssertEqual(dock.root.groups.count, 2)
        dock.close(.browser)
        XCTAssertEqual(dock.root.groups.count, 1)
        XCTAssertTrue(dock.root.isValidWorkspace)
    }

    func testCanMoveConversationWhileKeepingExactlyOne() throws {
        let dock = WorkspaceDock(defaults: nil)
        dock.open(.browser)
        let target = try XCTUnwrap(dock.group(containing: .browser))
        XCTAssertTrue(dock.move(.conversation, to: target.id, placement: .center))
        XCTAssertEqual(dock.root.groups.count, 1)
        XCTAssertTrue(dock.move(.conversation, to: target.id, placement: .top))
        XCTAssertTrue(dock.root.isValidWorkspace)
        dock.close(.conversation)
        XCTAssertTrue(dock.contains(.conversation))
    }

    func testNarrowFallbackDoesNotRewriteSavedArrangement() throws {
        let dock = WorkspaceDock(defaults: nil)
        dock.open(.browser)
        dock.open(.diagnostics)
        let group = try XCTUnwrap(dock.group(containing: .browser))
        _ = dock.move(.diagnostics, to: group.id, placement: .bottom)
        let original = dock.root
        XCTAssertTrue(dock.needsFocusMode(in: .init(width: 520, height: 640)))
        XCTAssertFalse(dock.needsFocusMode(in: .init(width: 1000, height: 800)))
        XCTAssertEqual(dock.root, original)
    }

    func testWindowAndWorkspaceLayoutsRestoreIndependently() throws {
        let suite = "DockTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dock = WorkspaceDock(defaults: defaults)
        dock.bind(windowID: "one", workspace: "A")
        dock.open(.browser)
        let original = dock.root
        dock.bind(windowID: "one", workspace: "B")
        XCTAssertEqual(dock.panels, [.conversation])
        dock.open(.diagnostics)
        dock.bind(windowID: "two", workspace: "A")
        XCTAssertEqual(dock.panels, [.conversation])
        dock.bind(windowID: "one", workspace: "A")
        XCTAssertEqual(dock.root, original)
        let recreated = WorkspaceDock(defaults: defaults)
        recreated.bind(windowID: "one", workspace: "A")
        XCTAssertEqual(recreated.root, original)
    }

    func testCorruptPersistedLayoutFallsBackToConversation() throws {
        let suite = "DockTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = DockNode.group(.init(tabs: [.browser], selected: .browser))
        defaults.set(try JSONEncoder().encode(invalid), forKey: "workspace-layout.v1.one.A")
        let dock = WorkspaceDock(defaults: defaults)
        dock.bind(windowID: "one", workspace: "A")
        XCTAssertEqual(dock.panels, [.conversation])
        XCTAssertTrue(dock.root.isValidWorkspace)
    }

    func testResetPreservesOpenToolsAndRejectsInvalidMoves() throws {
        let dock = WorkspaceDock(defaults: nil)
        dock.open(.browser)
        dock.open(.diagnostics)
        let group = try XCTUnwrap(dock.group(containing: .browser))
        _ = dock.move(.diagnostics, to: group.id, placement: .bottom)
        XCTAssertFalse(dock.move(.session, to: group.id, placement: .center))
        XCTAssertFalse(dock.move(.browser, to: UUID(), placement: .left))
        dock.reset()
        XCTAssertEqual(dock.root.groups.count, 2)
        XCTAssertEqual(Set(dock.panels), [.conversation, .browser, .diagnostics])
        XCTAssertEqual(dock.group(containing: .browser)?.id, dock.group(containing: .diagnostics)?.id)
    }

    func testAgentRevealKeepsConversationFocused() {
        let dock = WorkspaceDock(defaults: nil)
        dock.open(.browser, activate: false)
        XCTAssertEqual(dock.focusedPanel, .conversation)
        XCTAssertTrue(dock.contains(.browser))
    }

    func testRunResourceIdentitySurvivesPathChange() {
        let dock = WorkspaceDock(defaults: nil)
        let id = UUID()
        dock.open(.runChanges(id, "/first"))
        dock.open(.runChanges(id, "/second"))
        XCTAssertEqual(dock.panels.count, 2)
        XCTAssertTrue(dock.root.isValidWorkspace)
    }

    func testLegacyRunDecodesWithoutParentConversationAndRoundTripsNewMetadata() throws {
        var run = BotRunRecord.queued(profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "Task")
        run.sessionID = UUID()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "originatingSessionID")
        let legacy = try JSONDecoder().decode(BotRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.originatingSessionID)
        run.originatingSessionID = UUID()
        let restored = try JSONDecoder().decode(BotRunRecord.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(restored.originatingSessionID, run.originatingSessionID)
        XCTAssertEqual(restored.sessionID, run.sessionID)
        XCTAssertNotEqual(restored.originatingSessionID, restored.sessionID)
    }
}
