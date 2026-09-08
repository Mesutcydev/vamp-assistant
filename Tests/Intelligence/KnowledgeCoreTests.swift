import Foundation
import XCTest
@testable import BeetCode

final class KnowledgeCoreTests: XCTestCase {

    private func makeStore() throws -> KnowledgeStore {
        try KnowledgeStore(store: SQLiteStore(
            url: URL(fileURLWithPath: ":memory:"), inMemory: true))
    }

    func testInsertAndReadBack() throws {
        let store = try makeStore()
        let record = KnowledgeRecord(
            id: "kn_test1", kind: .capability, scope: "InferenceServer",
            statement: "Inference responses support SSE streaming.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "Sources/Inference.swift", symbolID: "sym_x",
                                startLine: 10, endLine: 40, contentHash: "hash-v1",
                                gitCommit: "abc1234", capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record)
        let loaded = try store.record(id: "kn_test1")
        XCTAssertEqual(loaded?.statement, record.statement)
        XCTAssertEqual(loaded?.confidence, .verified)
        XCTAssertEqual(loaded?.evidence.count, 1)
        XCTAssertEqual(loaded?.evidence.first?.contentHash, "hash-v1")
    }

    func testStaleOnHashChangeInvalidOnDelete() throws {
        let store = try makeStore()
        let record = KnowledgeRecord(
            id: "kn_stale", kind: .capability, scope: "S",
            statement: "Something true about the file.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "a.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "v1",
                                gitCommit: nil, capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record)

        var changed = try store.reevaluateFreshness(currentHashes: ["a.swift": "v2"])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try store.record(id: "kn_stale")?.freshness, .stale)

        let record2 = KnowledgeRecord(
            id: "kn_gone", kind: .capability, scope: "S",
            statement: "Something about a now-deleted file.",
            confidence: .verified, freshness: .fresh,
            evidence: [Evidence(path: "gone.swift", symbolID: nil, startLine: nil,
                                endLine: nil, contentHash: "v1",
                                gitCommit: nil, capturedAt: Date())],
            branchScope: nil, createdAt: Date(), updatedAt: Date())
        try store.insert(record2)
        changed = try store.reevaluateFreshness(currentHashes: ["gone.swift": nil])
        XCTAssertEqual(try store.record(id: "kn_gone")?.freshness, .invalid)
    }
}
