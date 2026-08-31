import Foundation
import XCTest
@testable import BeetCodeRemoteIOS

final class RemoteProtocolRegressionTests: XCTestCase {
    func testUnauthorizedResponseRequiresPairingAndPreservesServerMessage() {
        let body = Data(#"{"error":"The saved access token expired."}"#.utf8)
        let error = RemoteAPIClient.responseError(statusCode: 401, data: body)

        XCTAssertTrue(error.requiresPairing)
        XCTAssertEqual(error.errorDescription, "The saved access token expired.")
    }

    func testNonAuthenticationResponseDoesNotRequestPairing() {
        let error = RemoteAPIClient.responseError(statusCode: 423, fallback: "The Mac is locked.")

        XCTAssertFalse(error.requiresPairing)
        XCTAssertEqual(error.errorDescription, "The Mac is locked.")
    }

    func testRevisionOrderingRejectsOnlyAnOlderVersionedSnapshot() {
        XCTAssertFalse(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 41))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 42))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 43))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: nil))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: nil, incoming: 1))
    }

    func testServerMessageIdentitySurvivesSnapshotContentChanges() throws {
        let first = try decodeMessage(id: "session:message:17", content: "Working", timestamp: 10)
        let updated = try decodeMessage(id: "session:message:17", content: "Finished", timestamp: 11)

        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(updated.id, "session:message:17")
    }

    func testLegacySavedComputerDecodesWithoutNewMetadata() throws {
        let id = UUID()
        let data = Data(#"{"id":"\#(id.uuidString)","name":"Studio Mac","baseURL":"http:\/\/192.168.1.10:9575"}"#.utf8)
        let computer = try JSONDecoder().decode(PairedBeetCodeComputer.self, from: data)

        XCTAssertEqual(computer.id, id)
        XCTAssertNil(computer.tokenExpiresAt)
        XCTAssertNil(computer.networkKind)
    }

    func testStatusDecodesTokenExpiryAndTransportKind() throws {
        let data = Data(#"{"pairedClients":1,"networkKind":"localNetwork","tokenExpiresAt":1798761600,"isRunning":false,"phase":"idle","queuedTasks":0}"#.utf8)
        let status = try JSONDecoder().decode(RemoteStatus.self, from: data)

        XCTAssertEqual(status.networkKind, "localNetwork")
        XCTAssertEqual(status.tokenExpiresAt, 1_798_761_600)
    }

    func testMacControlStatusDecodesRemoteUnlockCapability() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":true,"remoteUnlockMessage":"Enter the Mac login password.","displays":[]}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertTrue(status.locked == true)
        XCTAssertTrue(status.remoteUnlockEnabled == true)
        XCTAssertTrue(status.remoteUnlockAvailable == true)
        XCTAssertEqual(status.remoteUnlockMessage, "Enter the Mac login password.")
        XCTAssertTrue(status.shouldOfferRemoteUnlock)
    }

    func testLegacyMacControlStatusLeavesRemoteUnlockUnavailable() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertNil(status.remoteUnlockEnabled)
        XCTAssertNil(status.remoteUnlockAvailable)
        XCTAssertNil(status.remoteUnlockMessage)
        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }

    func testLockedStatusDoesNotOfferPasswordFieldOnUnencryptedPath() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":false,"remoteUnlockMessage":"Remote Unlock requires the encrypted Tailscale connection."}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }

    func testKeyboardTransitionCannotReplaceStableStreamViewport() {
        let size = CGSize(width: 393, height: 852)

        XCTAssertTrue(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: false,
            keyboardInset: 0))
        XCTAssertFalse(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: true,
            keyboardInset: 0), "the overlay flag must close the notification-ordering race")
        XCTAssertFalse(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: false,
            keyboardInset: 320))
    }

    private func decodeMessage(id: String, content: String, timestamp: Double) throws -> RemoteMessage {
        let object: [String: Any] = [
            "id": id,
            "role": "assistant",
            "content": content,
            "timestamp": timestamp,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}
