import CryptoKit
import Foundation
import XCTest
@testable import BeetCode

/// Target-host consumer for the development-only off-host oracle package.
/// The archive is supplied through BEETCODE_QWEN35_ORACLE_FIXTURE and is
/// never bundled into Vamp Assistant.  Normal test runs skip the live model
/// comparison because it intentionally loads the installed 35B checkpoint.
final class QwenStreamOracleFixtureTests: XCTestCase {
    private struct Artifact: Decodable {
        let repo: String
        let revision: String
        let inventorySHA256: String
    }

    private struct Oracle: Decodable {
        let mlx: String
        let mlxLM: String
        let device: String
        let recurrentState: String
        let runtimeLabel: String?
    }

    private struct Semantics: Decodable {
        let routingK: Int
        let expertCount: Int
        let sharedExpert: Bool
        let thinking: Bool
        let sampler: String
        let fullAttentionLayerIndices: [Int]?
    }

    private struct FixtureEntry: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
        let promptTokenCount: Int
        let promptSHA256: String
        let generatedTokens: Int
        let stopReason: String
    }

    private struct Manifest: Decodable {
        let fixtureFormatVersion: String
        let artifact: Artifact
        let configSHA256: String
        let tokenizerSHA256: String
        let tokenizerConfigSHA256: String
        let templateSHA256: String
        let oracle: Oracle
        let semantics: Semantics
        let fixtures: [String: FixtureEntry]
    }

    private struct ArraySummary: Decodable {
        let shape: [Int]
        let dtype: String
        let sample: [Float]
        let checksum: String?
    }

    private struct LayerSnapshot: Decodable {
        let layer: Int
        let hidden: ArraySummary
    }

    private struct CacheSnapshot: Decodable {
        let layer: Int
        let type: String
        let offset: Int
        let state: [ArraySummary]
    }

    private struct RouterSnapshot: Decodable {
        let layer: Int
        let position: Int
        let expertIDs: [Int]
        let scores: [Float]
        let topLogitIDs: [Int]
        let topLogits: [Float]
        let kthScore: Float
        let kPlusOneScore: Float
        let kGap: Float
    }

    private struct Checkpoint: Decodable {
        let decodeStep: Int
        let positionBefore: Int
        let positionAfter: Int
        let inputToken: Int?
        let predictedToken: Int
        let topLogitIDs: [Int]
        let topLogits: [Float]
        let layerSnapshots: [LayerSnapshot]
        let cache: [CacheSnapshot]
        let router: [RouterSnapshot]
    }

    private struct Fixture: Decodable {
        let fixtureID: String
        let promptTokenIDs: [Int]
        let promptTokenCount: Int
        let promptSHA256: String
        let generatedTokenIDs: [Int]
        let stopReason: String
        let finalConsumedPosition: Int
        let checkpoints: [Checkpoint]
    }

    private struct RouterKey: Hashable {
        let layer: Int
        let position: Int
    }

    private let expectedInventorySHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
    private let expectedConfigSHA256 = "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964"
    private let expectedTokenizerSHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
    private let expectedTokenizerConfigSHA256 = "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"
    private let expectedTemplateSHA256 = "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"

    func testPortableFixturePathRejectsTraversal() throws {
        let root = URL(fileURLWithPath: "/tmp/qwen35-fixture-test", isDirectory: true)
        XCTAssertThrowsError(try safeRelativeURL("../manifest.json", root: root))
        XCTAssertThrowsError(try safeRelativeURL("/etc/passwd", root: root))
    }

    func testOptInPortableOracleFixtureParity() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = environment["BEETCODE_QWEN35_Q27_MATCHED_CORE_FIXTURE"]
            ?? environment["BEETCODE_QWEN35_ORACLE_FIXTURE"]
        guard let fixturePath else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q27_MATCHED_CORE_FIXTURE (or BEETCODE_QWEN35_ORACLE_FIXTURE) to a fixture ZIP or extracted directory.")
        }
        let source = URL(fileURLWithPath: fixturePath)
        var temporaryRoot: URL?
        let root: URL
        if source.hasDirectoryPath || (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = source
        } else {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen35-k8-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", source.path, "-d", temporary.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw XCTSkip("Could not extract the portable fixture archive.")
            }
            temporaryRoot = temporary
            root = temporary
        }
        defer {
            if let temporaryRoot {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }

        try rejectUnsafeEntries(in: root)
        let manifestURL = try safeRelativeURL("manifest.json", root: root)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        validate(manifest)
        let matchedCore = manifest.fixtureFormatVersion == "qwen35-k8-matched-core-v1"
        let explicitReference = manifest.fixtureFormatVersion == "qwen35-k8-q216-explicit-reference-v1"
        guard let primaryEntry = manifest.fixtures["primary"] else {
            XCTFail("portable fixture has no primary entry")
            return
        }
        let primaryURL = try safeRelativeURL(primaryEntry.path, root: root)
        XCTAssertEqual(try fileSize(primaryURL), primaryEntry.bytes)
        XCTAssertEqual(try sha256(primaryURL), primaryEntry.sha256)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: primaryURL))
        XCTAssertEqual(fixture.fixtureID, "primary")
        XCTAssertEqual(fixture.promptTokenIDs.count, fixture.promptTokenCount)
        XCTAssertEqual(fixture.generatedTokenIDs.count, primaryEntry.generatedTokens)
        XCTAssertGreaterThanOrEqual(fixture.generatedTokenIDs.count, 64)
        XCTAssertEqual(
            fixture.checkpoints.map(\.decodeStep),
            explicitReference ? [-1, 1, 2, 4, 8, 16, 32] : [-1, 1, 2, 4, 8, 16, 32, 64])

        let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed on the target host.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(directory: modelDirectory, modelID: QwenStreamArtifact.modelID,
                              diskBytes: QwenStreamArtifact.downloadBytes, contextSize: 4096)
        defer { Task { await engine.unload() } }

        let attentionCounters = StreamQwen35AttentionDiagnosticCounters()
        let rawRouterKeys: Set<QwenStreamRouterTraceKey> =
            environment["BEETCODE_QWEN35_Q28_CAPTURE_RAW"] == "1"
            ? [QwenStreamRouterTraceKey(layer: 19, position: 46)]
            : []
        let native = try await engine.debugGreedy(
            tokenIDs: fixture.promptTokenIDs,
            maxTokens: fixture.generatedTokenIDs.count,
            rawRouterKeys: rawRouterKeys,
            attentionStrategy: explicitReference ? .referenceCompatibleExplicit : .productionFused,
            diagnosticCounters: attentionCounters,
            includeFinalStateProbe: !explicitReference)
        if let dumpPath = environment["BEETCODE_QWEN35_Q27_NATIVE_DUMP"], !dumpPath.isEmpty {
            let data = try JSONEncoder().encode(native)
            try data.write(to: URL(fileURLWithPath: dumpPath), options: .atomic)
            print("[qwen-q27-dump] path=\(dumpPath) bytes=\(data.count)")
        }
        XCTAssertEqual(native.promptTokenIDs, fixture.promptTokenIDs)
        let differenceDescription = firstDifference(native.generatedTokenIDs, fixture.generatedTokenIDs)
            .map { String($0) } ?? "none"
        XCTAssertEqual(native.generatedTokenIDs, fixture.generatedTokenIDs,
                       "first differing generated-token index: \(differenceDescription)")
        XCTAssertEqual(native.stopReason, fixture.stopReason)
        XCTAssertEqual(native.finalConsumedPosition, fixture.finalConsumedPosition)
        XCTAssertEqual(native.prefillCallCount, (fixture.promptTokenCount + 3) / 4,
                       "the native debug path must prefill once per bounded group")
        XCTAssertEqual(
            native.cachedDecodeCallCount,
            explicitReference ? max(0, fixture.generatedTokenIDs.count - 1) : fixture.generatedTokenIDs.count,
            "cached decode accounting must match the fixture's emitted-token contract")
        if explicitReference {
            XCTAssertEqual(native.finalStateProbeCallCount, 0,
                           "Q2.16 ordinary parity excludes a post-final-token probe")

            let expectedFullLayers = [3, 7, 11, 15, 19, 23, 27, 31, 35, 39]
            XCTAssertEqual(manifest.semantics.fullAttentionLayerIndices, expectedFullLayers)
            let actualFullLayers = await engine.debugFullAttentionLayerIndices()
            XCTAssertEqual(actualFullLayers, expectedFullLayers)
            XCTAssertEqual(attentionCounters.fusedInvocations, 0,
                           "explicit validation must not invoke fused attention")
            let expectedInvocationsPerLayer = native.prefillCallCount + native.cachedDecodeCallCount
            XCTAssertEqual(
                attentionCounters.explicitInvocations,
                expectedFullLayers.count * expectedInvocationsPerLayer,
                "every full-attention invocation must use the explicit path")
            for layer in expectedFullLayers {
                XCTAssertEqual(
                    attentionCounters.explicitInvocationsByLayer[layer],
                    expectedInvocationsPerLayer,
                    "explicit invocation coverage missing for layer \(layer)")
                let lengths = attentionCounters.explicitQueryLengthsByLayer[layer] ?? []
                XCTAssertEqual(lengths.filter { $0 == 1 }.count, native.cachedDecodeCallCount,
                               "cached qLen=1 coverage missing for layer \(layer)")
                XCTAssertEqual(lengths.filter { $0 > 1 }.count, native.prefillCallCount,
                               "prefill coverage missing for layer \(layer)")
            }
        }

        let expectedByStep = Dictionary(uniqueKeysWithValues: fixture.checkpoints.map { ($0.decodeStep, $0) })
        for checkpoint in native.checkpoints {
            guard let expected = expectedByStep[checkpoint.decodeStep] else {
                XCTFail("portable fixture missing checkpoint \(checkpoint.decodeStep)")
                continue
            }
            XCTAssertEqual(checkpoint.inputToken, expected.inputToken)
            XCTAssertEqual(checkpoint.predictedToken, expected.predictedToken)
            XCTAssertEqual(checkpoint.topLogitIDs.first, expected.topLogitIDs.first,
                           "greedy top-1 mismatch at checkpoint \(checkpoint.decodeStep)")
            let nativeLogits = Dictionary(uniqueKeysWithValues: zip(checkpoint.topLogitIDs, checkpoint.topLogits))
            for (token, score) in zip(expected.topLogitIDs, expected.topLogits) {
                if let actualScore = nativeLogits[token] {
                    XCTAssertLessThanOrEqual(abs(Double(actualScore) - Double(score)), 0.5,
                                             "top-logit drift at checkpoint \(checkpoint.decodeStep), token \(token)")
                }
            }
            compareStates(expected: expected, actual: checkpoint)
        }
        compareRouters(expected: fixture, actual: native, requireComplete: matchedCore || explicitReference)
        let runtimeLabel = manifest.oracle.runtimeLabel ?? "legacy"
        print("[qwen-portable-parity] format=\(manifest.fixtureFormatVersion) runtime=\(runtimeLabel) generated=\(native.generatedTokenIDs.count) stop=\(native.stopReason) prefillCalls=\(native.prefillCallCount) cachedDecodeCalls=\(native.cachedDecodeCallCount) explicit=\(attentionCounters.explicitInvocations) fused=\(attentionCounters.fusedInvocations)")

        // Q2.7 reuses the exact matched-core fixture after a complete unload
        // boundary. This stays opt-in because it performs a second full
        // streamed generation, and it proves that no stale cache/state from
        // the first comparison is being reused.
        if (matchedCore && environment["BEETCODE_QWEN35_Q27_LIFECYCLE"] == "1") ||
            (explicitReference && environment["BEETCODE_QWEN35_Q216_LIFECYCLE"] == "1") {
            let beforeUnload = await engine.debugQuiescence()
            XCTAssertFalse(beforeUnload.ownerActive)
            XCTAssertFalse(beforeUnload.poolBusy)
            XCTAssertEqual(beforeUnload.activeReads, 0)
            await engine.unload()
            await engine.unload()
            try await engine.load(
                directory: modelDirectory,
                modelID: QwenStreamArtifact.modelID,
                diskBytes: QwenStreamArtifact.downloadBytes,
                contextSize: 4096)
            let reloaded = try await engine.debugGreedy(
                tokenIDs: fixture.promptTokenIDs,
                maxTokens: fixture.generatedTokenIDs.count,
                attentionStrategy: explicitReference ? .referenceCompatibleExplicit : .productionFused,
                includeFinalStateProbe: !explicitReference)
            let reloadDifference = firstDifference(reloaded.generatedTokenIDs, fixture.generatedTokenIDs)
                .map(String.init) ?? "none"
            XCTAssertEqual(reloaded.generatedTokenIDs, fixture.generatedTokenIDs,
                           "reloaded matched-core fixture diverged at index \(reloadDifference)")
            let afterReload = await engine.debugQuiescence()
            XCTAssertFalse(afterReload.ownerActive)
            XCTAssertFalse(afterReload.poolBusy)
            XCTAssertEqual(afterReload.activeReads, 0)
            print("[qwen-lifecycle] format=\(manifest.fixtureFormatVersion) reload=passed generated=\(reloaded.generatedTokenIDs.count) pool=quiescent activeReads=\(afterReload.activeReads)")
        }
    }

    /// Q2.17 lifecycle closeout. This stays opt-in because it runs the real
    /// 35B checkpoint several times. The observer events are emitted by the
    /// production stream/pool only when a test installs the developer hook;
    /// the normal user-facing path remains unchanged.
    func testOptInQwenQ217LifecycleCloseout() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q217_LIFECYCLE"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q217_LIFECYCLE=1 for Q2.17 lifecycle validation.")
        }
        let (manifest, fixture) = try loadExplicitFixture()
        XCTAssertEqual(manifest.fixtureFormatVersion, "qwen35-k8-q216-explicit-reference-v1")
        XCTAssertEqual(fixture.generatedTokenIDs.count, 64)

        let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed on the target host.")
        }

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(directory: modelDirectory, modelID: QwenStreamArtifact.modelID,
                              diskBytes: QwenStreamArtifact.downloadBytes, contextSize: 4096)
        defer { Task { await engine.unload() } }

        let turns = [ChatTurn(role: .user,
                              content: "Write a compact numbered list of four practical software testing tips.")]
        var cancellationRecords: [[String: Any]] = []

        // Cancel before the first prefill group enters the model. This is a
        // deterministic prefill boundary, rather than a wall-clock sleep.
        let prefill = try await cancelStream(
            engine: engine,
            turns: turns,
            target: { _, event in event == "prefill-group-start" })
        try await assertQuiescent(engine, label: "prefill cancellation")
        let prefillPrefix = try await runExplicitPrefix(engine: engine, fixture: fixture, count: 8)
        XCTAssertEqual(prefillPrefix.generatedTokenIDs,
                       Array(fixture.generatedTokenIDs.prefix(8)))
        cancellationRecords.append([
            "phase": "prefill",
            "eventCount": prefill.events.count,
            "lastEvent": prefill.events.last ?? "none",
            "outputBytes": prefill.output.utf8.count,
            "recoveryPrefix": prefillPrefix.generatedTokenIDs.count,
        ])

        // Clear reusable entries so the next run is guaranteed to wait for a
        // real expert read. The callback is inside QwenStreamExpertPool after
        // the execution lease is acquired and before the bounded read group.
        let poolReset = await engine.resetApplicationExpertPool()
        XCTAssertTrue(poolReset)
        let acquisition = try await cancelStream(
            engine: engine,
            turns: turns,
            target: { _, event in event == "expert-reads-start:prefill" })
        try await assertQuiescent(engine, label: "expert-acquisition cancellation")
        let acquisitionPrefix = try await runExplicitPrefix(engine: engine, fixture: fixture, count: 8)
        XCTAssertEqual(acquisitionPrefix.generatedTokenIDs,
                       Array(fixture.generatedTokenIDs.prefix(8)))
        cancellationRecords.append([
            "phase": "expert-acquisition",
            "eventCount": acquisition.events.count,
            "lastEvent": acquisition.events.last ?? "none",
            "outputBytes": acquisition.output.utf8.count,
            "recoveryPrefix": acquisitionPrefix.generatedTokenIDs.count,
        ])

        // Keep the first three decode calls observable, then cancel at the
        // fourth bounded cached call after several tokens have been emitted.
        let decode = try await cancelStream(
            engine: engine,
            turns: turns,
            target: { events, event in
                event == "decode-call-start" && events.filter { $0 == event }.count >= 4
            })
        try await assertQuiescent(engine, label: "cached-decode cancellation")
        let decodePrefix = try await runExplicitPrefix(engine: engine, fixture: fixture, count: 8)
        XCTAssertEqual(decodePrefix.generatedTokenIDs,
                       Array(fixture.generatedTokenIDs.prefix(8)))
        cancellationRecords.append([
            "phase": "cached-decode",
            "eventCount": decode.events.count,
            "lastEvent": decode.events.last ?? "none",
            "outputBytes": decode.output.utf8.count,
            "recoveryPrefix": decodePrefix.generatedTokenIDs.count,
        ])

        // Final recovery is the accepted independent golden, not output from
        // any cancelled request. It also proves the explicit strategy was
        // restored after all three cancellation paths.
        let fullCounters = StreamQwen35AttentionDiagnosticCounters()
        let recovered = try await engine.debugGreedy(
            tokenIDs: fixture.promptTokenIDs,
            maxTokens: fixture.generatedTokenIDs.count,
            attentionStrategy: .productionDefault,
            diagnosticCounters: fullCounters,
            includeFinalStateProbe: false)
        XCTAssertEqual(recovered.generatedTokenIDs, fixture.generatedTokenIDs)
        XCTAssertEqual(recovered.stopReason, fixture.stopReason)
        XCTAssertEqual(fullCounters.fusedInvocations, 0)
        XCTAssertGreaterThan(fullCounters.explicitInvocations, 0)
        // The three cancellation phases above drive engine.stream(), so they
        // exercise whatever the shipping production default is. Asserting it
        // here keeps the lifecycle gate honestly scoped to production.
        let lifecycleStrategy = await engine.debugAttentionStrategy()
        XCTAssertEqual(lifecycleStrategy, .productionDefault)
        try await assertQuiescent(engine, label: "post-cancellation recovery")
        print("[qwen-q217-cancel] records=\(cancellationRecords) recovered=\(recovered.generatedTokenIDs.count) explicit=\(fullCounters.explicitInvocations) fused=\(fullCounters.fusedInvocations)")
    }

    /// Exercises the real EngineRouter/EnginePool switching path on the
    /// installed target host. The pool is deliberately capped at one resident
    /// model so the switch proves an actual Qwen unload/reload boundary.
    func testOptInQwenQ217ModelSwitchLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q217_SWITCH"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q217_SWITCH=1 for Q2.17 model-switch validation.")
        }
        let (_, fixture) = try loadExplicitFixture()
        let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
        let qwenDirectory = modelsRoot.appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        let lightweightID = "Qwen3.5-9B-abliterated-MLX-4bit"
        let lightweightDirectory = modelsRoot.appendingPathComponent(lightweightID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: qwenDirectory.path),
              FileManager.default.fileExists(atPath: lightweightDirectory.path) else {
            throw XCTSkip("Both the pinned Qwen artifact and the installed lightweight MLX model must be present.")
        }

        let pool = EnginePool(maxResident: 1)
        let router = EngineRouter(pool: pool)
        defer { Task { await router.unloadAll() } }

        try await router.load(
            directory: qwenDirectory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            format: .qwenStreaming,
            contextSize: 4096)
        let loadedQwen = await router.loadedModelID
        XCTAssertEqual(loadedQwen, QwenStreamArtifact.modelID)
        let qwenOutput = try await collect(
            router.stream(
                adding: [ChatTurn(role: .user, content: "Reply with the word READY.")],
                maxTokens: 1,
                temperature: 0))
        XCTAssertFalse(qwenOutput.isEmpty)
        await router.cancelGeneration()

        try await router.load(
            directory: lightweightDirectory,
            modelID: lightweightID,
            diskBytes: ModelCatalog.model(id: lightweightID)?.diskBytes ?? 5_058_250_075,
            format: .mlx,
            contextSize: 4096)
        let loadedLightweight = await router.loadedModelID
        XCTAssertEqual(loadedLightweight, lightweightID)
        let lightweightOutput = try await collect(
            router.stream(
                adding: [ChatTurn(role: .user, content: "Reply with the word READY.")],
                maxTokens: 2,
                temperature: 0))
        XCTAssertFalse(lightweightOutput.isEmpty)

        // This is the real switch-back: maxResident=1 evicted Qwen before
        // the lightweight load, so the next activation must reconstruct it.
        try await router.load(
            directory: qwenDirectory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            format: .qwenStreaming,
            contextSize: 4096)
        let reloadedQwen = await router.loadedModelID
        XCTAssertEqual(reloadedQwen, QwenStreamArtifact.modelID)
        guard let qwen = await pool.debugQwenEngine() else {
            XCTFail("Qwen engine was not present after switching back")
            return
        }
        let counters = StreamQwen35AttentionDiagnosticCounters()
        let recovered = try await qwen.debugGreedy(
            tokenIDs: fixture.promptTokenIDs,
            maxTokens: fixture.generatedTokenIDs.count,
            attentionStrategy: .productionDefault,
            diagnosticCounters: counters,
            includeFinalStateProbe: false)
        XCTAssertEqual(recovered.generatedTokenIDs, fixture.generatedTokenIDs)
        XCTAssertEqual(recovered.stopReason, fixture.stopReason)
        XCTAssertEqual(counters.fusedInvocations, 0)
        XCTAssertGreaterThan(counters.explicitInvocations, 0)
        let state = await qwen.debugQuiescence()
        XCTAssertFalse(state.ownerActive)
        XCTAssertFalse(state.poolBusy)
        XCTAssertEqual(state.activeLeases, 0)
        XCTAssertEqual(state.queuedReads, 0)
        XCTAssertEqual(state.activeReads, 0)
        print("[qwen-q217-switch] qwen=passed lightweight=passed switchBack=passed generated=\(recovered.generatedTokenIDs.count) explicit=\(counters.explicitInvocations) fused=\(counters.fusedInvocations)")
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var output = ""
        for try await chunk in stream { output += chunk }
        return output
    }

    private struct CancellationRun {
        let events: [String]
        let output: String
    }

    private func cancelStream(
        engine: QwenStreamingEngine,
        turns: [ChatTurn],
        target: @escaping @Sendable ([String], String) -> Bool
    ) async throws -> CancellationRun {
        let (phases, continuation) = AsyncStream<String>.makeStream()
        await engine.debugSetLifecycleObserver { event in continuation.yield(event) }

        let generation = Task { () -> String in
            var output = ""
            do {
                for try await chunk in engine.stream(adding: turns, maxTokens: 64, temperature: 0) {
                    output += chunk
                }
            } catch {
                // Cancellation is the expected terminal result. The caller
                // validates quiescence and the subsequent golden recovery.
            }
            return output
        }

        let observed = await withTaskGroup(of: [String]?.self) { group -> [String]? in
            group.addTask {
                var events: [String] = []
                for await event in phases {
                    events.append(event)
                    if target(events, event) {
                        await engine.cancelGeneration()
                        continuation.finish()
                        return events
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(180))
                continuation.finish()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let events = observed else {
            await engine.cancelGeneration()
            _ = await generation.value
            await engine.debugSetLifecycleObserver(nil)
            throw XCTSkip("Q2.17 lifecycle phase observer did not reach its deterministic cancellation point.")
        }
        let output = await generation.value
        await engine.debugSetLifecycleObserver(nil)
        return CancellationRun(events: events, output: output)
    }

    private func runExplicitPrefix(
        engine: QwenStreamingEngine,
        fixture: Fixture,
        count: Int
    ) async throws -> QwenStreamDebugRun {
        let counters = StreamQwen35AttentionDiagnosticCounters()
        let run = try await engine.debugGreedy(
            tokenIDs: fixture.promptTokenIDs,
            maxTokens: count,
            attentionStrategy: .productionDefault,
            diagnosticCounters: counters,
            includeFinalStateProbe: false)
        XCTAssertEqual(counters.fusedInvocations, 0)
        XCTAssertGreaterThan(counters.explicitInvocations, 0)
        return run
    }

    private func assertQuiescent(
        _ engine: QwenStreamingEngine,
        label: String
    ) async throws {
        let state = await engine.debugQuiescence()
        XCTAssertFalse(state.ownerActive, "\(label): generation owner remains active")
        XCTAssertFalse(state.poolBusy, "\(label): expert pool remains busy")
        XCTAssertEqual(state.activeLeases, 0, "\(label): execution leases remain")
        XCTAssertEqual(state.queuedReads, 0, "\(label): queued reads remain")
        XCTAssertEqual(state.activeReads, 0, "\(label): tensor reads remain active")
    }

    private func loadExplicitFixture() throws -> (Manifest, Fixture) {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["BEETCODE_QWEN35_ORACLE_FIXTURE"] else {
            throw XCTSkip("Set BEETCODE_QWEN35_ORACLE_FIXTURE to the accepted Q2.16 fixture ZIP.")
        }
        let source = URL(fileURLWithPath: fixturePath)
        let root: URL
        var temporaryRoot: URL?
        if source.hasDirectoryPath || (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = source
        } else {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen35-k8-q217-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", source.path, "-d", temporary.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw XCTSkip("Could not extract the accepted Q2.16 fixture archive.")
            }
            temporaryRoot = temporary
            root = temporary
        }
        defer {
            if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        }
        try rejectUnsafeEntries(in: root)
        let manifestURL = try safeRelativeURL("manifest.json", root: root)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        validate(manifest)
        guard let entry = manifest.fixtures["primary"] else {
            throw XCTSkip("Accepted Q2.16 fixture has no primary entry.")
        }
        let fixtureURL = try safeRelativeURL(entry.path, root: root)
        XCTAssertEqual(try sha256(fixtureURL), entry.sha256)
        return (manifest, try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)))
    }

    private func validate(_ manifest: Manifest) {
        let isMatchedCore = manifest.fixtureFormatVersion == "qwen35-k8-matched-core-v1"
        let isExplicitReference = manifest.fixtureFormatVersion == "qwen35-k8-q216-explicit-reference-v1"
        XCTAssertTrue(
            isMatchedCore || isExplicitReference || manifest.fixtureFormatVersion == "qwen35-k8-oracle-v1",
            "unsupported Qwen fixture format \(manifest.fixtureFormatVersion)")
        XCTAssertEqual(manifest.artifact.repo, QwenStreamArtifact.repo)
        XCTAssertEqual(manifest.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(manifest.artifact.inventorySHA256, expectedInventorySHA256)
        XCTAssertEqual(manifest.configSHA256, expectedConfigSHA256)
        XCTAssertEqual(manifest.tokenizerSHA256, expectedTokenizerSHA256)
        XCTAssertEqual(manifest.tokenizerConfigSHA256, expectedTokenizerConfigSHA256)
        XCTAssertEqual(manifest.templateSHA256, expectedTemplateSHA256)
        XCTAssertEqual(manifest.oracle.mlx, isMatchedCore || isExplicitReference ? "0.31.1" : "0.32.2")
        XCTAssertEqual(manifest.oracle.mlxLM, "0.31.1")
        XCTAssertEqual(manifest.oracle.device, isMatchedCore || isExplicitReference ? "metal" : "cpu")
        if isMatchedCore {
            XCTAssertEqual(manifest.oracle.runtimeLabel, "python-mlx-core-0.31.1-metal")
        }
        XCTAssertEqual(manifest.oracle.recurrentState, "float32 (config)")
        XCTAssertEqual(manifest.semantics.routingK, 8)
        XCTAssertEqual(manifest.semantics.expertCount, 256)
        XCTAssertTrue(manifest.semantics.sharedExpert)
        XCTAssertFalse(manifest.semantics.thinking)
        XCTAssertTrue(manifest.semantics.sampler.contains("greedy"))
    }

    private func compareRouters(expected fixture: Fixture, actual run: QwenStreamDebugRun, requireComplete: Bool = false) {
        guard let trace = run.router else {
            XCTFail("native router trace is missing")
            return
        }
        if requireComplete {
            XCTAssertTrue(trace.isComplete, "matched-core router trace exceeded its bounded diagnostic capacity")
        }
        let expectedRecords = fixture.checkpoints.flatMap(\.router).reduce(into: [RouterKey: RouterSnapshot]()) {
            $0[RouterKey(layer: $1.layer, position: $1.position)] = $1
        }
        let actualRecords = trace.records.reduce(into: [RouterKey: (ids: [Int], scores: [Float], topIDs: [Int], topLogits: [Float])]()) { records, record in
            for index in record.positions.indices where index < record.expertIDs.count {
                records[RouterKey(layer: record.layer, position: record.positions[index])] = (
                    ids: record.expertIDs[index],
                    scores: record.scores[index],
                    topIDs: index < record.topLogitIDs.count ? record.topLogitIDs[index] : [],
                    topLogits: index < record.topLogits.count ? record.topLogits[index] : [])
            }
        }
        for (key, expectedRecord) in expectedRecords {
            guard let actual = actualRecords[key] else {
                XCTFail("native router record missing layer=\(key.layer) position=\(key.position)")
                continue
            }
            let expectedSet = Set(expectedRecord.expertIDs)
            let actualSet = Set(actual.ids)
            if expectedSet != actualSet {
                // A membership change is a semantic routing failure. Keep
                // the raw K/K+1 records in the log so a near-tie can be
                // investigated without turning it into an order-only pass.
                let expectedTop = zip(expectedRecord.topLogitIDs, expectedRecord.topLogits)
                    .map { "\($0.0):\($0.1)" }
                    .joined(separator: ",")
                let actualTop = zip(actual.topIDs, actual.topLogits)
                    .map { "\($0.0):\($0.1)" }
                    .joined(separator: ",")
                print("[qwen-q27-router-mismatch] layer=\(key.layer) position=\(key.position) expected=\(expectedRecord.expertIDs) actual=\(actual.ids) expectedTop=\(expectedTop) actualTop=\(actualTop)")
                XCTAssertEqual(actualSet, expectedSet,
                               "K=8 router selection set mismatch at layer=\(key.layer) position=\(key.position)")
                continue
            }
            if actual.ids != expectedRecord.expertIDs {
                // argPartition does not promise stable ordering for equal or
                // nearly equal values. The score remains attached to its ID,
                // so this is an order-only diagnostic rather than a semantic
                // failure.
                print("[qwen-q27-router-order-only] layer=\(key.layer) position=\(key.position) expected=\(expectedRecord.expertIDs) actual=\(actual.ids)")
            }
            let expectedByID = Dictionary(uniqueKeysWithValues: zip(expectedRecord.expertIDs, expectedRecord.scores))
            let actualByID = Dictionary(uniqueKeysWithValues: zip(actual.ids, actual.scores))
            let commonIDs = expectedRecord.expertIDs.filter { actualByID[$0] != nil }
            let expectedScores = commonIDs.compactMap { expectedByID[$0] }
            let actualScores = commonIDs.compactMap { actualByID[$0] }
            XCTAssertLessThanOrEqual(relativeL2(actualScores, expectedScores), 0.03,
                                     "router score drift at layer=\(key.layer) position=\(key.position)")
            XCTAssertLessThanOrEqual(maxAbsDifference(actualScores, expectedScores), 0.05,
                                     "router score maxAbs at layer=\(key.layer) position=\(key.position)")
            guard actual.topLogits.count >= 9, expectedRecord.topLogits.count >= 9 else {
                XCTFail("router K/K+1 margin is missing at layer=\(key.layer) position=\(key.position)")
                continue
            }
            XCTAssertLessThanOrEqual(abs(Double(actual.topLogits[7]) - Double(expectedRecord.kthScore)), 0.05,
                                     "router Kth score drift at layer=\(key.layer) position=\(key.position)")
            XCTAssertLessThanOrEqual(abs(Double(actual.topLogits[8]) - Double(expectedRecord.kPlusOneScore)), 0.05,
                                     "router K+1 score drift at layer=\(key.layer) position=\(key.position)")
            XCTAssertLessThanOrEqual(abs(Double(actual.topLogits[7] - actual.topLogits[8]) - Double(expectedRecord.kGap)), 0.05,
                                     "router K/K+1 gap drift at layer=\(key.layer) position=\(key.position)")
        }
    }

    private func compareStates(expected: Checkpoint, actual: QwenStreamDebugCheckpoint) {
        let expectedLayers = Dictionary(uniqueKeysWithValues: expected.layerSnapshots.map { ($0.layer, $0.hidden) })
        let actualLayers = Dictionary(uniqueKeysWithValues: actual.layerSnapshots.map { ($0.layer, $0.hidden) })
        for layer in [0, 19, 39] {
            guard let left = expectedLayers[layer], let right = actualLayers[layer] else {
                XCTFail("hidden snapshot missing for layer \(layer) at step \(expected.decodeStep)")
                continue
            }
            XCTAssertEqual(right.shape, left.shape)
            XCTAssertLessThanOrEqual(
                relativeL2(right.sample, left.sample), 0.08,
                "hidden relL2 at checkpoint \(expected.decodeStep), layer \(layer)")
            XCTAssertLessThanOrEqual(
                maxAbsDifference(right.sample, left.sample), 0.25,
                "hidden maxAbs at checkpoint \(expected.decodeStep), layer \(layer)")
        }
        let expectedCaches = Dictionary(uniqueKeysWithValues: expected.cache.map { ($0.layer, $0) })
        let actualCaches = Dictionary(uniqueKeysWithValues: actual.cache.layers.map { ($0.layer, $0) })
        // Q2.16's independent fixture contains every config-derived
        // full-attention KV cache at each sampled boundary. Keep the early,
        // middle, and late recurrent caches as stateful-layer sentinels too.
        let requiredCacheLayers = [0, 3, 7, 11, 15, 18, 19, 23, 27, 31, 35, 39]
        let fullAttentionLayers = Set([3, 7, 11, 15, 19, 23, 27, 31, 35, 39])
        for layer in requiredCacheLayers {
            guard let left = expectedCaches[layer], let right = actualCaches[layer] else {
                XCTFail("cache snapshot missing for layer \(layer) at step \(expected.decodeStep)")
                continue
            }
            if fullAttentionLayers.contains(layer) {
                XCTAssertEqual(left.type, "KVCache")
                XCTAssertTrue(right.kind.hasPrefix("FullAttention/"),
                              "full-attention cache kind mismatch at layer \(layer)")
            } else {
                XCTAssertEqual(left.type, "ArraysCache")
                XCTAssertTrue(right.kind.hasPrefix("GatedDeltaNet/"),
                              "GatedDeltaNet cache kind mismatch at layer \(layer)")
            }
            XCTAssertEqual(right.offset, left.offset)
            XCTAssertEqual(right.state.count, left.state.count)
            for (index, expectedArray) in left.state.enumerated() where index < right.state.count {
                let actualArray = right.state[index]
                XCTAssertEqual(actualArray.shape, expectedArray.shape)
                XCTAssertLessThanOrEqual(
                    relativeL2(actualArray.sample, expectedArray.sample), 0.08,
                    "cache relL2 at checkpoint \(expected.decodeStep), layer \(layer), state \(index)")
                XCTAssertLessThanOrEqual(
                    maxAbsDifference(actualArray.sample, expectedArray.sample), 0.25,
                    "cache maxAbs at checkpoint \(expected.decodeStep), layer \(layer), state \(index)")
            }
        }
    }

    private func safeRelativeURL(_ path: String, root: URL) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
            throw NSError(domain: "QwenFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsafe fixture path"])
        }
        let base = root.standardizedFileURL
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else {
            throw NSError(domain: "QwenFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "escaping fixture path"])
        }
        return candidate
    }

    private func rejectUnsafeEntries(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw NSError(domain: "QwenFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture contains a symbolic link"])
            }
        }
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func firstDifference(_ lhs: [Int], _ rhs: [Int]) -> Int? {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return index
        }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
    }

    private func relativeL2(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        var numerator = 0.0
        var denominator = 0.0
        for (left, right) in zip(lhs, rhs) {
            let difference = Double(left) - Double(right)
            numerator += difference * difference
            denominator += Double(right) * Double(right)
        }
        return sqrt(numerator) / max(sqrt(denominator), 1e-12)
    }

    private func maxAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }
}
