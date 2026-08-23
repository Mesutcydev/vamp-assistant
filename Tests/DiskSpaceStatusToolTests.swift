import XCTest
@testable import BeetCode

final class DiskSpaceStatusToolTests: XCTestCase {
    func testReportsStartupDiskCapacityWithoutComputerUse() async throws {
        let tool = DiskSpaceStatusTool()
        let call = ParsedToolCall(name: tool.name, arguments: .object([:]), index: 0)
        let output = try await tool.execute(
            call,
            in: ToolContext(workspace: Workspace(root: URL(fileURLWithPath: "/"))))

        XCTAssertEqual(tool.risk, .read)
        XCTAssertTrue(output.contains("available"))
        XCTAssertTrue(output.contains("used of"))
        XCTAssertTrue(output.contains("% used"))
    }

    func testReportsMacSystemFactsWithoutComputerUse() async throws {
        let tool = MacSystemStatusTool()
        let call = ParsedToolCall(name: tool.name, arguments: .object([:]), index: 0)
        let output = try await tool.execute(
            call,
            in: ToolContext(workspace: Workspace(root: URL(fileURLWithPath: "/"))))

        XCTAssertEqual(tool.risk, .read)
        XCTAssertTrue(output.contains("installed memory"))
        XCTAssertTrue(output.contains("uptime"))
        XCTAssertTrue(output.contains("thermal state"))
    }
}
