import XCTest
@testable import BeetCode

final class CoreAICompatibilityTests: XCTestCase {
    func testNestedCoreAIPackIsRecognizedAndResolved() throws {
        let workspace = TempWorkspace()
        let pack = workspace.url.appendingPathComponent("ios/int8", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pack.appendingPathComponent("metadata.json"))
        try Data([0, 1, 2]).write(to: pack.appendingPathComponent("decoder.aimodel"))

        XCTAssertTrue(ModelStore.isCompleteCoreAIPack(at: workspace.url))
        XCTAssertEqual(
            CoreAIEngine.Planner.resourceDirectory(in: workspace.url)?.resolvingSymlinksInPath(),
            pack.resolvingSymlinksInPath())
    }

    func testCoreAIPackRequiresMetadataAndAsset() throws {
        let workspace = TempWorkspace()
        try Data("{}".utf8).write(to: workspace.url.appendingPathComponent("metadata.json"))
        XCTAssertFalse(ModelStore.isCompleteCoreAIPack(at: workspace.url))
        XCTAssertNil(CoreAIEngine.Planner.resourceDirectory(in: workspace.url))
    }

    func testRunnerOverrideWinsAndDuplicatesAreRemoved() {
        let candidates = CoreAIEngine.Planner.runnerCandidates(
            environment: ["BEETCODE_COREAI_RUNNER": "/custom/llm-runner"],
            home: "/Users/test",
            bundle: .main)
        XCTAssertEqual(candidates.first?.path, "/custom/llm-runner")
        XCTAssertEqual(Set(candidates.map(\.path)).count, candidates.count)
    }

    func testPromptPreservesRolesAndEndsAtAssistantBoundary() {
        let prompt = CoreAIEngine.Planner.prompt(from: [
            ChatTurn(role: .system, content: "Use tools safely"),
            ChatTurn(role: .user, content: "Inspect the app"),
            ChatTurn(role: .tool, content: "result"),
        ])
        XCTAssertTrue(prompt.contains("System: Use tools safely"))
        XCTAssertTrue(prompt.contains("User: Inspect the app"))
        XCTAssertTrue(prompt.contains("Tool: result"))
        XCTAssertTrue(prompt.hasSuffix("Assistant:"))
    }

    func testRunnerOutputDropsPreparationAndMetrics() {
        let output = "preparing\nGenerating...\nHello from Core AI\n\n⏱️  Performance Summary:\n10 tok/s"
        XCTAssertEqual(CoreAIEngine.Planner.generatedText(from: output), "Hello from Core AI")
        XCTAssertNil(CoreAIEngine.Planner.generatedText(from: "no generation marker"))
    }

    func testFormatRoundTripsAsCoreAI() throws {
        let data = try JSONEncoder().encode(CatalogModel.Format.coreAI)
        XCTAssertEqual(try JSONDecoder().decode(CatalogModel.Format.self, from: data), .coreAI)
    }
}
