import XCTest
@testable import BeetCode

final class QwenStreamExpertTraceTests: XCTestCase {
    func testGroupedLRUUsesExactBundleBytesAndCapacityVariants() {
        let snapshot = QwenStreamExpertTraceSnapshot(
            groups: [
                .init(layer: 0, experts: [0, 1, 2, 3, 4, 5, 6, 7]),
                .init(layer: 0, experts: [0, 1, 2, 3, 4, 5, 6, 7]),
                .init(layer: 1, experts: [0, 1, 2, 3, 4, 5, 6, 7]),
            ], keyCount: 24, droppedKeys: 0)
        let results = QwenStreamExpertLRUSimulator.simulate(
            snapshot: snapshot, capacities: [8, 16])
        XCTAssertEqual(results.map(\.capacitySlots), [8, 16])
        XCTAssertEqual(results[0].misses, 16)
        XCTAssertEqual(results[0].hits, 8)
        XCTAssertEqual(results[0].evictions, 8)
        XCTAssertEqual(
            results[0].requestedBytes,
            UInt64(16) * QwenStreamArtifact.expertBundleBytes)
        XCTAssertEqual(results[1].misses, 16)
        XCTAssertEqual(results[1].hits, 8)
        XCTAssertTrue(results.allSatisfy(\.supported))
    }

    func testTraceIsBoundedAndReportsDroppedKeys() {
        let trace = QwenStreamExpertAccessTrace(maximumKeys: 3)
        trace.record(layer: 2, keys: [10, 11])
        trace.record(layer: 2, keys: [12, 13])
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.keyCount, 3)
        XCTAssertEqual(snapshot.droppedKeys, 1)
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.groups, [
            .init(layer: 2, experts: [10, 11]),
            .init(layer: 2, experts: [12]),
        ])
    }
}
