import XCTest
@testable import BeetCode

final class CoreAICompatibilityTests: XCTestCase {
    func testNestedCoreAIPackIsRecognized() throws {
        let workspace = TempWorkspace()
        let pack = workspace.url.appendingPathComponent("ios/int8", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pack.appendingPathComponent("metadata.json"))
        try Data([0, 1, 2]).write(to: pack.appendingPathComponent("decoder.aimodel"))

        XCTAssertTrue(ModelStore.isCompleteCoreAIPack(at: workspace.url))
    }

    func testCoreAIPackRequiresMetadataAndAsset() throws {
        let workspace = TempWorkspace()
        try Data("{}".utf8).write(to: workspace.url.appendingPathComponent("metadata.json"))
        XCTAssertFalse(ModelStore.isCompleteCoreAIPack(at: workspace.url))
    }

    func testFormatRoundTripsAsCoreAI() throws {
        let data = try JSONEncoder().encode(CatalogModel.Format.coreAI)
        XCTAssertEqual(try JSONDecoder().decode(CatalogModel.Format.self, from: data), .coreAI)
    }
}
