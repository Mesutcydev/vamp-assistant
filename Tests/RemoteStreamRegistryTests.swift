import Foundation
import XCTest
@testable import BeetCode

@MainActor
final class RemoteStreamRegistryTests: XCTestCase {
    func testRevokingOneClientClosesItsIdleStreamAndPreservesOtherClient() async {
        let registry = RemoteStreamRegistry()
        let first = AsyncStream<Data>.makeStream()
        let second = AsyncStream<Data>.makeStream()
        let closed = expectation(description: "revoked idle stream closes")
        let received = expectation(description: "other client continues")
        let streamA = registry.protect(first.stream, clientID: "a", capability: .control) { true }
        let streamB = registry.protect(second.stream, clientID: "b", capability: .control) { true }
        let taskA = Task { for await _ in streamA {} ; closed.fulfill() }
        let taskB = Task {
            for await data in streamB {
                XCTAssertEqual(data, Data("still authorized".utf8))
                received.fulfill()
                break
            }
        }
        registry.cancel(clientID: "a")
        second.continuation.yield(Data("still authorized".utf8))
        await fulfillment(of: [closed, received], timeout: 2)
        registry.cancel()
        taskA.cancel()
        taskB.cancel()
        first.continuation.finish()
        second.continuation.finish()
    }

    func testExpiredAuthorizationClosesIdleStreamWithoutAnotherRequest() async {
        let registry = RemoteStreamRegistry(checkInterval: .milliseconds(10))
        let source = AsyncStream<Data>.makeStream()
        var authorized = true
        let stream = registry.protect(source.stream, clientID: "a", capability: .control) { authorized }
        let closed = expectation(description: "expired stream closes")
        let task = Task { for await _ in stream {} ; closed.fulfill() }
        authorized = false
        await fulfillment(of: [closed], timeout: 2)
        task.cancel()
        source.continuation.finish()
    }

    func testDisablingControlKeepsSessionStreamAlive() async {
        let registry = RemoteStreamRegistry()
        let source = AsyncStream<Data>.makeStream()
        let stream = registry.protect(source.stream, clientID: "a", capability: .session) { true }
        registry.cancel(capability: .control)
        source.continuation.yield(Data("chat".utf8))
        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertEqual(next, Data("chat".utf8))
        registry.cancel()
        let end = await iterator.next()
        XCTAssertNil(end)
        source.continuation.finish()
    }
}
