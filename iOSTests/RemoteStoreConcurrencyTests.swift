import Foundation
import Synchronization
import XCTest
@testable import BeetCodeRemoteIOS

@MainActor
final class MemoryConnectionStorage: RemoteConnectionPersisting {
    var computers: [PairedBeetCodeComputer]
    var activeID: UUID?
    var tokens: [UUID: String]
    init(_ computers: [PairedBeetCodeComputer]) {
        self.computers = computers
        activeID = computers.first?.id
        tokens = Dictionary(uniqueKeysWithValues: computers.map { ($0.id, "test-token") })
    }
    func load() -> (computers: [PairedBeetCodeComputer], activeID: UUID?) { (computers, activeID) }
    func save(computers: [PairedBeetCodeComputer], activeID: UUID?) {
        self.computers = computers
        self.activeID = activeID
    }
    func token(for id: UUID) -> String? { tokens[id] }
    func saveToken(_ token: String, for id: UUID) throws { tokens[id] = token }
    func clearToken(for id: UUID) { tokens.removeValue(forKey: id) }
}

final class RemoteStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    static let handler = Mutex<Handler?>(nil)
    private let work = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let request = self.request
        let task = Task.detached { @Sendable [self] in
            do {
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        work.withLock { $0 = task }
    }
    override func stopLoading() { work.withLock { $0?.cancel(); $0 = nil } }
}

@MainActor
final class RemoteStoreConcurrencyTests: XCTestCase {
    private func disconnect(_ store: RemoteStore) {
        for computer in store.pairedComputers where computer.id != store.activeComputerID {
            store.removeComputer(computer.id)
        }
        store.forgetSavedMac()
    }
    private func makeStore(handler: @escaping RemoteStubProtocol.Handler) -> (RemoteStore, MemoryConnectionStorage, URLSession) {
        RemoteStubProtocol.handler.withLock { $0 = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let storage = MemoryConnectionStorage([
            PairedBeetCodeComputer(name: "Mac A", baseURL: URL(string: "http://192.168.1.1:9575")!),
            PairedBeetCodeComputer(name: "Mac B", baseURL: URL(string: "http://192.168.1.2:9575")!),
        ])
        return (RemoteStore(connectionStorage: storage, apiSession: session, observesNotifications: false,
            drafts: RemoteDraftStore(directory: nil)), storage, session)
    }

    nonisolated static func status(_ expiry: Int) -> Data {
        Data("{\"pairedClients\":1,\"networkKind\":\"localNetwork\",\"tokenExpiresAt\":\(expiry),\"isRunning\":false,\"phase\":\"idle\",\"queuedTasks\":0}".utf8)
    }

    nonisolated static func detail(_ id: UUID) -> Data {
        Data("{\"id\":\"\(id)\",\"title\":\"Test\",\"workspace\":\"\",\"modelID\":\"test\",\"messages\":[],\"isRunning\":false,\"phase\":\"idle\",\"streamingText\":\"\"}".utf8)
    }

    func testImageMessageRequiresHostCapabilityAndPreservesDraft() async throws {
        let id = UUID()
        let posts = Mutex(0)
        let (store, _, session) = makeStore { request in
            switch request.url?.path {
            case "/api/status": return (200, Self.status(2_100_000_000))
            case "/api/sessions": return (200, Data("{\"sessions\":[]}".utf8))
            case "/api/sessions/\(id)": return (200, Self.detail(id))
            default:
                if request.httpMethod == "POST" { posts.withLock { $0 += 1 } }
                return (404, Data("{}".utf8))
            }
        }
        defer { disconnect(store); session.invalidateAndCancel() }
        await store.connectSaved()
        await store.select(sessionID: id)
        let computer = try XCTUnwrap(store.activeComputerID)
        let image = RemoteImageAttachment(id: UUID(), data: Data([1, 2, 3]))
        store.drafts.setImages([image], computerID: computer, sessionID: id)
        let sent = await store.send("", sessionID: id, images: [image])
        XCTAssertFalse(sent)
        XCTAssertEqual(posts.withLock { $0 }, 0)
        XCTAssertEqual(store.errorTitle, "Update Vamp on your Mac")
        XCTAssertEqual(store.drafts.images(computerID: computer, sessionID: id), [image])
    }

    func testUnloadCallsHostOnceAndKeepsDownloadedModels() async throws {
        let posted = expectation(description: "unload started")
        let posts = Mutex(0)
        let unloaded = Mutex(false)
        let (store, _, session) = makeStore { request in
            switch request.url?.path {
            case "/api/status": return (200, Self.status(2_100_000_000))
            case "/api/sessions": return (200, Data("{\"sessions\":[]}".utf8))
            case "/api/models/unload":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                posts.withLock { $0 += 1 }
                posted.fulfill()
                try await Task.sleep(for: .milliseconds(100))
                unloaded.withLock { $0 = true }
                return (200, Data("{\"accepted\":true}".utf8))
            case "/api/models":
                let loaded = unloaded.withLock { $0 } ? "null" : "{\"id\":\"local|huihui\",\"name\":\"Huihui\",\"canUnload\":true}"
                return (200, Data("{\"models\":[{\"id\":\"local|huihui\",\"name\":\"Huihui\",\"source\":\"local\",\"detail\":\"Downloaded\"}],\"loadedLocalModel\":\(loaded)}".utf8))
            default: return (200, Data("{\"runs\":[]}".utf8))
            }
        }
        defer { session.invalidateAndCancel(); disconnect(store) }
        try await store.refresh()
        await store.loadStartModels()
        XCTAssertEqual(store.loadedLocalModel?.id, "local|huihui")
        let first = Task { await store.unloadLocalModel() }
        await fulfillment(of: [posted], timeout: 2)
        XCTAssertTrue(store.isUnloadingModel)
        let duplicate = await store.unloadLocalModel()
        XCTAssertFalse(duplicate)
        let success = await first.value
        XCTAssertTrue(success)
        XCTAssertEqual(posts.withLock { $0 }, 1)
        XCTAssertNil(store.loadedLocalModel)
        XCTAssertFalse(store.isUnloadingModel)
        XCTAssertEqual(store.startModels.map(\.id), ["local|huihui"])
    }

    func testOlderHostModelListRemainsCompatible() throws {
        let envelope = try JSONDecoder().decode(RemoteModelEnvelope.self, from: Data("{\"models\":[]}".utf8))
        XCTAssertNil(envelope.loadedLocalModel)
        XCTAssertTrue(envelope.models.isEmpty)
    }

    func testQueuedSendIsSerializedAndPreservedOnFailure() async throws {
        for responseStatus in [200, 409] {
            let id = UUID(), taskID = UUID()
            let posted = expectation(description: "queued send started")
            let posts = Mutex(0)
            let (store, _, session) = makeStore { request in
                if request.httpMethod == "POST" {
                    XCTAssertEqual(request.url?.path, "/api/sessions/\(id)/queue")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                    posts.withLock { $0 += 1 }
                    posted.fulfill()
                    try await Task.sleep(for: .milliseconds(150))
                    return (responseStatus, Data((responseStatus == 200
                        ? "{\"accepted\":true}" : "{\"error\":\"The Mac is busy.\"}").utf8))
                }
                if request.url?.path == "/api/status" { return (200, Self.status(2_100_000_000)) }
                if request.url?.path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
                if request.url?.path.hasSuffix(id.uuidString) == true {
                    var detail = try JSONSerialization.jsonObject(with: Self.detail(id)) as! [String: Any]
                    detail["queued"] = [["id": taskID.uuidString, "message": "Keep this follow-up", "state": "queued"]]
                    return (200, try JSONSerialization.data(withJSONObject: detail))
                }
                return (404, Data("{}".utf8))
            }
            defer { session.invalidateAndCancel(); disconnect(store) }
            try await store.refresh()
            await store.select(sessionID: id)
            let operation = Task { await store.sendQueuedTask(taskID, sessionID: id) }
            await fulfillment(of: [posted], timeout: 2)
            XCTAssertEqual(store.sendingQueuedTaskID, taskID)
            let duplicate = await store.sendQueuedTask(taskID, sessionID: id)
            XCTAssertFalse(duplicate)
            await store.cancelQueuedTask(taskID, sessionID: id)
            let success = await operation.value
            XCTAssertEqual(success, responseStatus == 200)
            XCTAssertEqual(posts.withLock { $0 }, 1)
            XCTAssertFalse(store.isUpdatingQueue)
            if responseStatus == 409 {
                XCTAssertEqual(store.selectedSession?.queued?.first?.message, "Keep this follow-up")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }

    func testSwitchingMacDuringRefreshDoesNotReuseOldStatusOrExpiry() async throws {
        let started = expectation(description: "A request started")
        let (store, storage, session) = makeStore { request in
            let isA = request.url?.host == "192.168.1.1"
            if request.url?.path == "/api/status" {
                if isA { started.fulfill(); try await Task.sleep(for: .milliseconds(200)) }
                return (200, Self.status(isA ? 2_000_000_000 : 2_100_000_000))
            }
            if request.url?.path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
            return (200, Data("{\"runs\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let oldRefresh = Task { try? await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await store.switchComputer(to: storage.computers[1].id)
        await oldRefresh.value
        XCTAssertEqual(store.activeComputer?.name, "Mac B")
        XCTAssertEqual(store.activeComputer?.tokenExpiresAt?.timeIntervalSince1970, 2_100_000_000)
        XCTAssertTrue(store.isConnected)
        disconnect(store)
    }

    func testLatestConversationSelectionWinsWhenOlderResponseArrivesLast() async {
        let firstID = UUID(), secondID = UUID()
        let started = expectation(description: "first selection started")
        let (store, _, session) = makeStore { request in
            let path = request.url!.path
            if path.hasSuffix(firstID.uuidString) {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(200))
                return (200, Self.detail(firstID))
            }
            if path.hasSuffix(secondID.uuidString) { return (200, Self.detail(secondID)) }
            return (404, Data("{}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let first = Task { await store.select(sessionID: firstID) }
        await fulfillment(of: [started], timeout: 2)
        await store.select(sessionID: secondID)
        await first.value
        XCTAssertEqual(store.selectedSession?.id, secondID)
        XCTAssertNil(store.errorMessage)
        disconnect(store)
    }

    func testOlderSelectionCannotWinWhileLatestIsStillLoading() async {
        let firstID = UUID(), secondID = UUID()
        let started = expectation(description: "first selection started")
        let (store, _, session) = makeStore { request in
            if request.url!.path.hasSuffix(firstID.uuidString) {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(50))
                return (200, Self.detail(firstID))
            }
            if request.url!.path.hasSuffix(secondID.uuidString) {
                try await Task.sleep(for: .milliseconds(200))
                return (200, Self.detail(secondID))
            }
            return (404, Data("{}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let first = Task { await store.select(sessionID: firstID) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await store.select(sessionID: secondID) }
        await first.value
        XCTAssertNil(store.selectedSession, "an obsolete response must not populate the new selection")
        await second.value
        XCTAssertEqual(store.selectedSession?.id, secondID)
        disconnect(store)
    }

    func testFailedConversationLoadKeepsRecoveryMessageAfterBackgroundRefresh() async throws {
        let id = UUID()
        let (store, _, session) = makeStore { request in
            if request.url?.path == "/api/status" { return (200, Self.status(2_100_000_000)) }
            if request.url?.path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
            if request.url?.path == "/api/bots/runs" { return (200, Data("{\"runs\":[]}".utf8)) }
            return (404, Data("{\"error\":\"Conversation not found\"}".utf8))
        }
        defer { session.invalidateAndCancel() }

        await store.select(sessionID: id)
        XCTAssertNil(store.selectedSession)
        XCTAssertNotNil(store.selectedSessionError)
        try await store.refresh()
        XCTAssertNil(store.errorMessage, "a healthy background poll clears global alerts")
        XCTAssertNotNil(store.selectedSessionError, "the conversation must still offer Retry")
        disconnect(store)
    }

    func testRemovedConversationShowsRecoveryMessageInsteadOfWaitingForever() async throws {
        let id = UUID()
        let (store, _, session) = makeStore { request in
            if request.url?.path == "/api/status" { return (200, Self.status(2_100_000_000)) }
            if request.url?.path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
            if request.url?.path.hasSuffix(id.uuidString) == true { return (200, Self.detail(id)) }
            return (200, Data("{\"runs\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }

        await store.select(sessionID: id)
        XCTAssertEqual(store.selectedSession?.id, id)
        try await store.refresh()
        XCTAssertNil(store.selectedSession)
        XCTAssertNotNil(store.selectedSessionError)
        disconnect(store)
    }

    func testDuplicateSendIsRejectedWhileFirstSubmissionIsPending() async {
        let id = UUID()
        let sent = expectation(description: "message POST started")
        let postCount = Mutex(0)
        let (store, _, session) = makeStore { request in
            if request.httpMethod == "POST" {
                postCount.withLock { $0 += 1 }
                sent.fulfill()
                try await Task.sleep(for: .milliseconds(150))
                return (202, Data("{\"accepted\":true}".utf8))
            }
            if request.url!.path.hasSuffix(id.uuidString) { return (200, Self.detail(id)) }
            return (404, Data("{}".utf8))
        }
        defer { session.invalidateAndCancel() }
        await store.select(sessionID: id)
        let first = Task { await store.send("hello", sessionID: id) }
        await fulfillment(of: [sent], timeout: 2)
        let duplicate = await store.send("hello", sessionID: id)
        XCTAssertFalse(duplicate)
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(postCount.withLock { $0 }, 1)
        XCTAssertTrue(store.sendingSessionIDs.isEmpty)
        disconnect(store)
    }

    func testAcceptedBotStartRemainsSuccessfulWhenRefreshFails() async {
        let (store, _, session) = makeStore { request in
            if request.httpMethod == "POST" { return (202, Data("{\"accepted\":true}".utf8)) }
            throw URLError(.networkConnectionLost)
        }
        defer { session.invalidateAndCancel() }
        let accepted = await store.startBotRun(profileID: "builder", modelID: nil, prompt: "test")
        XCTAssertTrue(accepted)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.backgroundNotice?.contains("accepted") == true)
        disconnect(store)
    }
    func testNotificationSwitchesToOriginatingMac() async {
        let (store, storage, session) = makeStore { request in
            if request.url?.path == "/api/status" { return (200, Self.status(2_100_000_000)) }
            if request.url?.path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
            return (200, Data("{\"runs\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let origin = storage.computers[1].id
        let opened = await store.openNotification(RemoteNotificationTarget(computerID: origin, sessionID: UUID()))
        XCTAssertTrue(opened)
        XCTAssertEqual(store.activeComputerID, origin)
        let unknown = await store.openNotification(RemoteNotificationTarget(computerID: UUID(), sessionID: UUID()))
        XCTAssertFalse(unknown)
        XCTAssertEqual(store.activeComputerID, origin)
        disconnect(store)
    }

    func testSelectingFullAccessConversationNeverWritesAccessOrApproval() async {
        let id = UUID()
        let writes = Mutex(0)
        let (store, _, session) = makeStore { request in
            if request.httpMethod == "POST" { writes.withLock { $0 += 1 } }
            if request.url?.path.hasSuffix(id.uuidString) == true {
                let data = Self.detail(id)
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["fullAccess"] = true
                object["agentMode"] = "auto"
                return (200, try JSONSerialization.data(withJSONObject: object))
            }
            return (404, Data("{}".utf8))
        }
        defer { session.invalidateAndCancel() }
        await store.select(sessionID: id)
        XCTAssertTrue(store.fullAccess)
        XCTAssertTrue(store.autoMode)
        // Auto mode carries full-access authority, but the key bank must still
        // render AUTO: deriving the selection from `fullAccess` alone made
        // every AUTO run show as FULL.
        XCTAssertFalse(store.isFullAccessSelected)
        XCTAssertEqual(writes.withLock { $0 }, 0)
        disconnect(store)
    }

    func testDiagnosticsExcludeAddressesNamesAndTokens() {
        let (store, _, session) = makeStore { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel() }
        let report = store.connectionDiagnostics
        XCTAssertFalse(report.contains("192.168"))
        XCTAssertFalse(report.contains("test-token"))
        XCTAssertFalse(report.contains("Mac A"))
        XCTAssertTrue(report.contains("Connected: false"))
        disconnect(store)
    }

    func testSuccessfulPairingSurvivesInitialRefreshFailure() async {
        let (store, storage, session) = makeStore { request in
            if request.url?.path == "/api/pair" {
                return (200, Data("{\"token\":\"new-test-token\",\"expiresAt\":2100000000}".utf8))
            }
            throw URLError(.networkConnectionLost)
        }
        defer { session.invalidateAndCancel() }
        let paired = await store.connect(address: "http://192.168.1.1:9575", code: "123456")
        XCTAssertTrue(paired)
        XCTAssertTrue(store.hasSavedConnection)
        XCTAssertEqual(storage.token(for: store.activeComputerID!), "new-test-token")
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.backgroundNotice?.contains("Pairing succeeded") == true)
        disconnect(store)
    }

}

@MainActor
extension RemoteStoreConcurrencyTests {
    func testUnlockRefreshesStatusUntilConfirmedAndPostsPasswordOnlyOnce() async throws {
        let posts = Mutex(0)
        let polls = Mutex(0)
        let (store, _, session) = makeStore { request in
            if request.url?.path == "/api/control/unlock" {
                posts.withLock { $0 += 1 }
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertGreaterThanOrEqual(request.timeoutInterval, 20,
                    "Allow 256 paced characters plus host confirmation")
                return (202, Data(#"{"accepted":true}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/control")
            let attempt = polls.withLock { $0 += 1; return $0 }
            return (200, Data("{\"enabled\":true,\"screenRecording\":true,\"accessibility\":true,\"ready\":\(attempt > 1),\"locked\":\(attempt == 1)}".utf8))
        }
        defer { disconnect(store); session.invalidateAndCancel() }
        let client = RemoteAPIClient(baseURL: URL(string: "http://100.90.4.3:9575")!, token: "test-token", session: session)

        let status = try await client.unlockMac(password: String(repeating: "a", count: 256), sleep: { _ in })

        XCTAssertEqual(status.locked, false)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(posts.withLock { $0 }, 1)
        XCTAssertEqual(polls.withLock { $0 }, 2)
    }

    func testUnlockNeverTreatsAcceptedOrMissingLockStateAsConfirmation() async throws {
        for lockField in [",\"locked\":true", ""] {
            let posts = Mutex(0)
            let polls = Mutex(0)
            let (store, _, session) = makeStore { request in
                if request.url?.path == "/api/control/unlock" {
                    posts.withLock { $0 += 1 }
                    return (202, Data(#"{"accepted":true}"#.utf8))
                }
                polls.withLock { $0 += 1 }
                return (200, Data("{\"enabled\":true,\"screenRecording\":true,\"accessibility\":true,\"ready\":false\(lockField)}".utf8))
            }
            defer { disconnect(store); session.invalidateAndCancel() }
            let client = RemoteAPIClient(baseURL: URL(string: "http://100.90.4.3:9575")!, token: "test-token", session: session)

            do {
                _ = try await client.unlockMac(password: "never-log-this", sleep: { _ in })
                XCTFail("Must require an unlocked status")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("still locked"))
                XCTAssertFalse(error.localizedDescription.contains("never-log-this"))
            }
            XCTAssertEqual(posts.withLock { $0 }, 1)
            XCTAssertEqual(polls.withLock { $0 }, 12)
        }
    }

    func testUnlockPreservesHostRejectionWithoutRetrying() async {
        for statusCode in [409, 423] {
            let requests = Mutex(0)
            let (store, _, session) = makeStore { _ in
                requests.withLock { $0 += 1 }
                return (statusCode, Data(#"{"error":"The Mac is still locked."}"#.utf8))
            }
            defer { disconnect(store); session.invalidateAndCancel() }
            let client = RemoteAPIClient(baseURL: URL(string: "http://100.90.4.3:9575")!, token: "test-token", session: session)
            do {
                _ = try await client.unlockMac(password: "example", sleep: { _ in })
                XCTFail("Must preserve the host failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, "The Mac is still locked.")
            }
            XCTAssertEqual(requests.withLock { $0 }, 1)
        }
    }

    func testUnlockCancellationStopsConfirmationWithoutResending() async {
        let requests = Mutex(0)
        let (store, _, session) = makeStore { request in
            requests.withLock { $0 += 1 }
            if request.url?.path == "/api/control/unlock" {
                return (202, Data(#"{"accepted":true}"#.utf8))
            }
            return (200, Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true}"#.utf8))
        }
        defer { disconnect(store); session.invalidateAndCancel() }
        let client = RemoteAPIClient(baseURL: URL(string: "http://100.90.4.3:9575")!, token: "test-token", session: session)
        do {
            _ = try await client.unlockMac(password: "example", sleep: { _ in throw CancellationError() })
            XCTFail("Must stop confirmation when cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(requests.withLock { $0 }, 2)
    }

    func testFileDownloadEncodesNamesExactlyOnce() async throws {
        let payload = Data("download payload".utf8)
        for name in ["notes.txt", "my notes.txt", "résumé.txt", "report #1+100%.txt"] {
            let (store, _, session) = makeStore { request in
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                XCTAssertEqual(components.percentEncodedPath.removingPercentEncoding, "/api/files/" + name)
                XCTAssertNil(components.query)
                XCTAssertNil(components.fragment)
                return (200, payload)
            }
            let client = RemoteAPIClient(baseURL: URL(string: "http://192.168.1.1:9575")!, token: "test-token", session: session)
            let data = try await client.downloadFile(named: name)
            XCTAssertEqual(data, payload)
            session.invalidateAndCancel()
            disconnect(store)
        }
    }

    func testFileDownloadRejectsPathTraversal() async {
        let client = RemoteAPIClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-token")
        for name in ["", ".", "..", "../secret.txt", "folder/file.txt"] {
            do { _ = try await client.downloadFile(named: name); XCTFail("Accepted invalid filename") }
            catch { XCTAssertTrue(error is RemoteClientError) }
        }
    }

    func testOldMacMutationFailuresDoNotAlertOnNewMac() async {
        for mutation in ["stop", "queue", "undo"] {
            await verifyOldMacMutation(mutation, statusCode: 500)
        }
    }

    func testOldMacUndoSuccessDoesNotRefreshNewMac() async {
        await verifyOldMacMutation("undo", statusCode: 200)
    }

    private func verifyOldMacMutation(_ mutation: String, statusCode: Int) async {
        let started = expectation(description: "old mutation started")
        let id = UUID()
        let newStatusCalls = Mutex(0)
        let (store, storage, session) = makeStore { request in
            let path = request.url!.path
            if request.httpMethod == "POST" || request.httpMethod == "DELETE" {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(250))
                return (statusCode, Data((statusCode == 200 ? "{\"accepted\":true}" : "{\"error\":\"Old Mac failed\"}").utf8))
            }
            if path == "/api/status" {
                if request.url?.host == "192.168.1.2" { newStatusCalls.withLock { $0 += 1 } }
                return (200, Self.status(2_100_000_000))
            }
            if path == "/api/sessions" { return (200, Data("{\"sessions\":[]}".utf8)) }
            if path.hasSuffix(id.uuidString) { return (200, Self.detail(id)) }
            return (200, Data("{\"runs\":[]}".utf8))
        }
        defer { session.invalidateAndCancel(); disconnect(store) }
        await store.select(sessionID: id)
        let operation = Task {
            switch mutation {
            case "stop": await store.stop()
            case "queue": await store.cancelQueuedTask(UUID())
            default: await store.undoCheckpoint()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await store.switchComputer(to: storage.computers[1].id)
        let callsAfterSwitch = newStatusCalls.withLock { $0 }
        await operation.value
        XCTAssertNil(store.errorMessage, mutation)
        XCTAssertEqual(newStatusCalls.withLock { $0 }, callsAfterSwitch, "Old completion refreshed the new Mac")
    }
}
