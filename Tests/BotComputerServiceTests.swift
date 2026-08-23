import XCTest
@testable import BeetCode

final class BotComputerServiceTests: XCTestCase {
    func testPrepareCreatesPrivateSeparateWorkspaceAndBrowserProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)

        let first = try await service.prepare(profileID: "builder", name: "Builder")
        let second = try await service.prepare(profileID: "reviewer", name: "Reviewer")
        let records = try await service.load()

        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(first.workspacePath, second.workspacePath)
        XCTAssertNotEqual(first.browserProfilePath, second.browserProfilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.workspacePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.browserProfilePath))
        XCTAssertEqual(first.state, .prepared)
        XCTAssertTrue(first.containerName?.hasPrefix("beet-builder-") == true)

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testPreparedCatalogRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let prepared = try await service.prepare(
            profileID: "research bot",
            name: "Researcher",
            backend: .isolatedWorkspace)

        let loaded = try await service.load()
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, prepared.id)
        XCTAssertEqual(restored.backend, .isolatedWorkspace)
        XCTAssertNil(restored.containerName)
    }
}
