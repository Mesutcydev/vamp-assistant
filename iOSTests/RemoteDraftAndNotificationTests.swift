import Foundation
import XCTest
@testable import BeetCodeRemoteIOS

@MainActor
final class RemoteDraftAndNotificationTests: XCTestCase {
    func testDraftsSurviveRelaunchAndStayIsolatedByComputer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstMac = UUID(), secondMac = UUID(), session = UUID()
        let drafts = RemoteDraftStore(directory: directory)
        drafts[firstMac, session] = "First Mac draft"
        drafts[secondMac, session] = "Second Mac draft"
        await drafts.flush()
        XCTAssertNil(drafts.errorMessage)
        let restored = RemoteDraftStore(directory: directory)
        XCTAssertEqual(restored[firstMac, session], "First Mac draft")
        XCTAssertEqual(restored[secondMac, session], "Second Mac draft")
        restored[firstMac, session] = ""
        await restored.flush()
        let cleared = RemoteDraftStore(directory: directory)
        XCTAssertEqual(cleared[firstMac, session], "")
        XCTAssertEqual(cleared[secondMac, session], "Second Mac draft")
    }

    func testRemovingComputerOnlyRemovesItsDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstMac = UUID(), secondMac = UUID(), session = UUID()
        let drafts = RemoteDraftStore(directory: directory)
        drafts[firstMac, session] = "A"
        drafts[secondMac, session] = "B"
        drafts.remove(computerID: firstMac)
        await drafts.flush()
        let restored = RemoteDraftStore(directory: directory)
        XCTAssertEqual(restored[firstMac, session], "")
        XCTAssertEqual(restored[secondMac, session], "B")
    }

    func testNotificationPayloadPreservesOriginAndSupportsLegacyAlerts() {
        let target = RemoteNotificationTarget(computerID: UUID(), sessionID: UUID())
        XCTAssertEqual(RemoteNotificationTarget(userInfo: target.userInfo), target)
        let legacy = RemoteNotificationTarget(userInfo: ["sessionID": target.sessionID.uuidString])
        XCTAssertEqual(legacy?.sessionID, target.sessionID)
        XCTAssertNil(legacy?.computerID)
        XCTAssertNil(RemoteNotificationTarget(userInfo: ["sessionID": "invalid"]))
    }
}
