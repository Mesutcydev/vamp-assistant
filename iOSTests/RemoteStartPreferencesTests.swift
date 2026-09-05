import Foundation
import XCTest
@testable import BeetCodeRemoteIOS

@MainActor
final class RemoteStartPreferencesTests: XCTestCase {
    private func model(
        _ id: String,
        source: String,
        name: String? = nil,
        defaultEffort: String? = nil
    ) -> RemoteStartModelOption {
        RemoteStartModelOption(
            id: id,
            name: name ?? id,
            source: source,
            detail: source.capitalized,
            reasoningEfforts: nil,
            defaultReasoningEffort: defaultEffort)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "RemoteStartPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testChoicesSurviveRelaunch() throws {
        let defaults = try makeDefaults()
        let preferences = RemoteStartPreferences(defaults: defaults)
        preferences.remember(model: model("gpt", source: "api"))
        preferences.botID = "reviewer"
        preferences.workspacePath = "/Users/me/project"

        let restored = RemoteStartPreferences(defaults: defaults)
        XCTAssertEqual(restored.modelID, "gpt")
        XCTAssertEqual(restored.modelSource, "api")
        XCTAssertEqual(restored.botID, "reviewer")
        XCTAssertEqual(restored.workspacePath, "/Users/me/project")
    }

    func testFirstLaunchDefaultsToLocalAndChatOnly() throws {
        let preferences = RemoteStartPreferences(defaults: try makeDefaults())
        XCTAssertEqual(preferences.modelSource, "local")
        XCTAssertTrue(preferences.modelID.isEmpty)
        XCTAssertTrue(preferences.workspacePath.isEmpty)
    }

    func testRememberedModelWinsWhenStillOffered() {
        let models = [model("a", source: "local"), model("b", source: "api")]
        let resolved = RemoteStartPreferences.resolveModel(
            in: models, rememberedID: "b", rememberedSource: "api")
        XCTAssertEqual(resolved?.id, "b")
    }

    func testFallsBackWithinRememberedSourceWhenModelIsGone() {
        let models = [model("a", source: "local"), model("c", source: "api")]
        let resolved = RemoteStartPreferences.resolveModel(
            in: models, rememberedID: "b", rememberedSource: "api")
        XCTAssertEqual(resolved?.id, "c")
    }

    /// An empty remembered source is what used to strand the sheet on an empty
    /// list with a Start button that could never be tapped.
    func testFallsBackToAnotherSourceWhenRememberedSourceIsEmpty() {
        let models = [model("a", source: "local")]
        let resolved = RemoteStartPreferences.resolveModel(
            in: models, rememberedID: "b", rememberedSource: "api")
        XCTAssertEqual(resolved?.id, "a")
    }

    func testResolveModelReturnsNilWithoutModels() {
        XCTAssertNil(RemoteStartPreferences.resolveModel(
            in: [], rememberedID: "b", rememberedSource: "api"))
    }

    func testEmptyRememberedFolderStaysChatOnly() {
        let workspaces = [RemoteWorkspace(path: "/a", name: "a", isCurrent: true)]
        XCTAssertEqual(
            RemoteStartPreferences.resolveWorkspacePath(in: workspaces, rememberedPath: ""),
            "")
    }

    func testRememberedFolderSurvivesAndFallsBackToCurrent() {
        let workspaces = [
            RemoteWorkspace(path: "/a", name: "a", isCurrent: false),
            RemoteWorkspace(path: "/b", name: "b", isCurrent: true),
        ]
        XCTAssertEqual(
            RemoteStartPreferences.resolveWorkspacePath(in: workspaces, rememberedPath: "/a"),
            "/a")
        XCTAssertEqual(
            RemoteStartPreferences.resolveWorkspacePath(in: workspaces, rememberedPath: "/gone"),
            "/b")
        XCTAssertEqual(
            RemoteStartPreferences.resolveWorkspacePath(in: [], rememberedPath: "/gone"),
            "")
    }
}
