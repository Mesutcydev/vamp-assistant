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
