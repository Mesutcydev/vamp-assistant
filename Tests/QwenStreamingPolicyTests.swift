import XCTest
@testable import BeetCode

final class QwenStreamingPolicyTests: XCTestCase {
    func testReasoningStateUsesLastAssistantMarker() {
        XCTAssertTrue(QwenStreamingEngine.suffixStartsInReasoning("</think>user text<|assistant|><think>\n"))
        XCTAssertFalse(QwenStreamingEngine.suffixStartsInReasoning("<think>\n\n</think>\n"))
        XCTAssertFalse(QwenStreamingEngine.suffixStartsInReasoning("ordinary answer"))
    }

    func testPinnedK8ArtifactIsDistinctFromEdge0() {
        XCTAssertEqual(QwenStreamArtifact.routingK, 8)
        XCTAssertEqual(QwenStreamArtifact.downloadBytes, 20_411_897_485)
        XCTAssertEqual(QwenStreamArtifact.files.filter { $0.name.hasSuffix(".safetensors") }.count, 4)
        XCTAssertFalse(QwenStreamArtifact.files.contains { $0.name.contains("lora") || $0.name.contains("prerouter") })
        let model = ModelCatalog.bundled.first { $0.id == QwenStreamArtifact.modelID }
        XCTAssertEqual(model?.format, .qwenStreaming)
        XCTAssertEqual(model?.contextWindow, 4096)
        XCTAssertEqual(model?.minRAMGB, 16)
    }

    func testAdmissionDoesNotChargeAllExpertsAsResident() {
        let streamed = MemoryAdvisor.projectedFootprint(
            diskBytes: QwenStreamArtifact.downloadBytes, format: .qwenStreaming)
        let full = MemoryAdvisor.projectedFootprint(diskBytes: QwenStreamArtifact.downloadBytes, format: .mlx)
        XCTAssertLessThan(streamed, 6 * 1_073_741_824)
        XCTAssertGreaterThan(full, 20 * 1_073_741_824)
    }

    func testContextAndPoolNeverGrowAsMemoryFalls() {
        var previousTokens = 4096
        var previousPool: UInt64 = 2 * 1_073_741_824
        for mib in stride(from: 8192, through: 0, by: -16) {
            let budget = QwenStreamBudget.resolve(availableBytes: UInt64(mib) * 1_048_576)
            XCTAssertLessThanOrEqual(budget?.contextTokens ?? 0, previousTokens)
            XCTAssertLessThanOrEqual(budget?.poolBytes ?? 0, previousPool)
            if let budget { XCTAssertLessThanOrEqual(budget.reservedBytes, UInt64(mib) * 1_048_576) }
            previousTokens = budget?.contextTokens ?? 0
            previousPool = budget?.poolBytes ?? 0
        }
    }

    func testNoForcedPositiveContextWhenOutputExhaustsAdmission() {
        XCTAssertNil(QwenStreamBudget.resolve(availableBytes: 0))
        XCTAssertNil(QwenStreamBudget.resolve(availableBytes: 8 * 1_073_741_824, outputTokens: 4096))
        XCTAssertNil(QwenStreamBudget.resolve(availableBytes: 8 * 1_073_741_824, poolCeiling: 4))
    }

    func testPathTraversalAndEscapingSymlinkAreRejected() throws {
        let root = try QwenStreamTestFixtures.makeTemporaryDirectory("paths")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside", "/tmp/file", "a/b", "a\\b", "..", ""] {
            XCTAssertThrowsError(try QwenStreamPaths.file(path, in: root))
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path,
                                                  withDestinationPath: "/tmp/outside")
        XCTAssertThrowsError(try QwenStreamPaths.file("escape", in: root))
    }

    func testSevenSlotsCannotServeK8() async throws {
        let directory = try QwenStreamTestFixtures.makeTemporaryDirectory("pool-minimum")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try QwenStreamTensorStoreSet(directory: directory, shardNames: [])
        let index = QwenStreamSafetensorsIndex(locations: [:], shardNames: [], fileSizes: [:])
        XCTAssertThrowsError(try QwenStreamExpertPool(index: index, stores: stores,
            bytes: 2 * 1_073_741_824, slots: 7))
        XCTAssertThrowsError(try QwenStreamExpertPool(index: index, stores: stores,
            bytes: 7 * QwenStreamArtifact.expertBundleBytes, slots: 100))
        await stores.closeAll()
    }

    func testPrefillGroupsRespectK8CapacityHeadroom() async throws {
        let directory = try QwenStreamTestFixtures.makeTemporaryDirectory("pool-prefill-capacity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try QwenStreamTensorStoreSet(directory: directory, shardNames: [])
        let index = QwenStreamSafetensorsIndex(locations: [:], shardNames: [], fileSizes: [:])
        let pool = try QwenStreamExpertPool(index: index, stores: stores,
            bytes: 8 * QwenStreamArtifact.expertBundleBytes, slots: 8)
        XCTAssertEqual(pool.maximumPrefillTokens, 1)
        await stores.closeAll()
    }

    func testFailedGenerationClearsOwnershipBeforeFinishingStream() async throws {
        let engine = QwenStreamingEngine(gate: GenerationGate())
        for _ in 0..<8 {
            do {
                for try await _ in engine.stream(adding: [.init(role: .user, content: "fixture")],
                                                  maxTokens: 1, temperature: 0) {
                    XCTFail("Unloaded engine emitted text")
                }
                XCTFail("Unloaded engine should fail")
            } catch {
                XCTAssertEqual(error as? EngineError, .notLoaded)
            }
        }
    }

    func testUnloadResetAndCancelAreIdempotentAfterFailedLoad() async throws {
        let engine = QwenStreamingEngine(gate: GenerationGate())
        await engine.unload()
        await engine.reset()
        await engine.cancelGeneration()
        await engine.cancelGeneration()

        let directory = try QwenStreamTestFixtures.makeTemporaryDirectory("invalid-load")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await engine.load(
                directory: directory,
                modelID: QwenStreamArtifact.modelID,
                diskBytes: QwenStreamArtifact.downloadBytes,
                contextSize: 4096
            )
            XCTFail("An incomplete artifact must not load")
        } catch {
            XCTAssertNotNil(error)
        }
        let loadedAfterFailure = await engine.loadedModelID
        XCTAssertNil(loadedAfterFailure)
        await engine.unload()
        await engine.unload()
        let loadedAfterUnload = await engine.loadedModelID
        XCTAssertNil(loadedAfterUnload)
    }

    func testPromptHashIsStableWithoutExposingPromptText() {
        let first = QwenStreamingDiagnostics.hashTokenIDs([1, 2, 3, 4])
        let second = QwenStreamingDiagnostics.hashTokenIDs([1, 2, 3, 4])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 24)
        XCTAssertFalse(first.contains("1,2,3,4"))
    }
}
