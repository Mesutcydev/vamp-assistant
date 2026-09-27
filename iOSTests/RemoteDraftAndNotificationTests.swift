import Foundation
import XCTest
import UIKit
import ImageIO
@testable import BeetCodeRemoteIOS

@MainActor
final class RemoteDraftAndNotificationTests: XCTestCase {
    func testPhotoNormalizationAndDraftSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1600))
        let png = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600))
        }
        let photo = try RemoteImageAttachment.prepare(png)
        XCTAssertLessThan(photo.data.count, RemoteImageAttachment.maximumBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        XCTAssertThrowsError(try RemoteImageAttachment.prepare(Data("invalid".utf8)))
        let mac = UUID(), chat = UUID()
        let drafts = RemoteDraftStore(directory: directory)
        drafts.setImages([photo], computerID: mac, sessionID: chat)
        drafts[mac, chat] = "Read this"
        drafts[mac, chat] = ""
        await drafts.flush()
        let restored = RemoteDraftStore(directory: directory)
        XCTAssertEqual(restored.images(computerID: mac, sessionID: chat), [photo])
        XCTAssertTrue(restored.images(computerID: UUID(), sessionID: chat).isEmpty)
        restored.setImages([], computerID: mac, sessionID: chat)
        await restored.flush()
        XCTAssertTrue(RemoteDraftStore(directory: directory).images(computerID: mac, sessionID: chat).isEmpty)
    }

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
