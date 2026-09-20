import XCTest
@testable import BeetCode

// MARK: - QwenStreamTensorStoreTests

final class QwenStreamTensorStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try QwenStreamTestFixtures.makeTemporaryDirectory("store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPreadReturnsExactBytesForRange() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = QwenStreamTestFixtures.payload(shape: [64], dtype: .u32)
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [64], payload),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let file = try QwenStreamPreadFile(path: url.path)
        defer { file.close() }
        let bytes = try file.read(
            offset: location.payloadOffset,
            count: Int(location.byteCount)
        )
        XCTAssertEqual(bytes, payload)

        // Exact sub-range read.
        let head = try file.read(offset: location.payloadOffset, count: 16)
        XCTAssertEqual(head, payload.prefix(16))
    }

    func testReadPastEOFThrowsTypedError() throws {
        let url = directory.appendingPathComponent("short.bin")
        try Data(count: 8).write(to: url)
        let file = try QwenStreamPreadFile(path: url.path)
        defer { file.close() }

        XCTAssertThrowsError(try file.read(offset: 4, count: 16)) { error in
            guard case .unexpectedEOF? = error as? QwenStreamTensorStoreError else {
                return XCTFail("Expected unexpectedEOF, got \(error)")
            }
        }
    }

    func testClosedStoreRejectsReadsAndDoubleCloseIsSafe() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let store = try QwenStreamPreadTensorStore(path: url.path, shardName: "model.safetensors")
        await store.close()
        await store.close()

        do {
            _ = try await store.read(location)
            XCTFail("Expected closed error")
        } catch {
            guard case .closed? = error as? QwenStreamTensorStoreError else {
                return XCTFail("Expected closed, got \(error)")
            }
        }
    }

    func testConcurrentReadsAreIndependent() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = QwenStreamTestFixtures.payload(shape: [128], dtype: .u32)
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [128], payload),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try QwenStreamTensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"],
            maxConcurrentReads: 2
        )
        defer { Task { await stores.closeAll() } }

        async let first = stores.read(location)
        async let second = stores.read(location)
       let results = try await [first, second]
       XCTAssertEqual(results[0].bytes, payload)
       XCTAssertEqual(results[1].bytes, payload)
        let stats = stores.readStatistics()
        XCTAssertEqual(stats.totalRequestedBytes, UInt64(payload.count * 2))
        XCTAssertEqual(stats.totalCompletedBytes, UInt64(payload.count * 2))
        XCTAssertGreaterThan(stats.totalReadSeconds, 0)
        XCTAssertLessThanOrEqual(stats.peakConcurrentReads, 2)
        XCTAssertEqual(stats.stats(for: .load).completedBytes, UInt64(payload.count * 2))
    }

    func testCancelledContextThrowsBeforeRead() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let store = try QwenStreamPreadTensorStore(path: url.path, shardName: "model.safetensors")

        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.read(location)
                return nil
            } catch {
                return error
            }
        }
        let error = await task.value
        XCTAssertTrue(
            error is CancellationError,
            "Expected CancellationError, got \(String(describing: error))"
        )
    }

    func testStoreSetRejectsUnknownShard() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try QwenStreamTensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )
        defer { Task { await stores.closeAll() } }

        let ghost = QwenStreamTensorLocation(
            name: location.name,
            shard: "other.safetensors",
            payloadOffset: location.payloadOffset,
            byteCount: location.byteCount,
            dtype: location.dtype,
            shape: location.shape
        )
        do {
            _ = try await stores.read(ghost)
            XCTFail("Expected unknownShard")
        } catch {
            guard case .unknownShard? = error as? QwenStreamSafetensorsError else {
                return XCTFail("Expected unknownShard, got \(error)")
            }
        }
    }

    func testPhaseCountersSeparateRequestedAndCompletedBytes() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = QwenStreamTestFixtures.payload(shape: [32], dtype: .u32)
        try QwenStreamTestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [32], payload),
        ])
        let index = try QwenStreamSafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try QwenStreamTensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"], maxConcurrentReads: 1)
        stores.setReadPhase(.prefill)
        _ = try await stores.read(location)
        stores.setReadPhase(.decode)
        _ = try await stores.read(location)
        let stats = stores.readStatistics()
        XCTAssertEqual(stats.stats(for: .prefill).requestedBytes, UInt64(payload.count))
        XCTAssertEqual(stats.stats(for: .prefill).completedBytes, UInt64(payload.count))
        XCTAssertEqual(stats.stats(for: .decode).requestedBytes, UInt64(payload.count))
        XCTAssertEqual(stats.stats(for: .decode).completedBytes, UInt64(payload.count))
        await stores.closeAll()
    }
}
