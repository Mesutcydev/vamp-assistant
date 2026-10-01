import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import BeetCode

final class QwenStreamOptimizationTests: XCTestCase {
    func testPrefixRequiresExactTokensSettingsAndOriginalChunkBoundary() {
        let state = QwenStreamPromptState(tokens: [1, 2, 3, 4], thinking: false,
            attention: .productionDefault, groupSize: 4, cache: [])
        XCTAssertTrue(state.matches(prompt: [1, 2, 3, 4, 5], thinking: false,
            attention: .productionDefault, groupSize: 4))
        for tokens in [[1, 2, 3], [1, 2, 3, 4], [1, 9, 3, 4, 5]] {
            XCTAssertFalse(state.matches(prompt: tokens, thinking: false,
                attention: .productionDefault, groupSize: 4))
        }
        XCTAssertFalse(state.matches(prompt: [1, 2, 3, 4, 5], thinking: true,
            attention: .productionDefault, groupSize: 4))
        XCTAssertFalse(state.matches(prompt: [1, 2, 3, 4, 5], thinking: false,
            attention: .productionFused, groupSize: 4))
        XCTAssertFalse(state.matches(prompt: [1, 2, 3, 4, 5], thinking: false,
            attention: .productionDefault, groupSize: 1))
        XCTAssertEqual(QwenStreamPromptState.checkpointLength(
            prompt: [7, 1, 2, 3, 4, 7, 8, 9], assistantStartToken: 7, groupSize: 4), 4)
        XCTAssertEqual(QwenStreamPromptState.checkpointLength(
            prompt: [1, 2, 3], assistantStartToken: nil, groupSize: 4), 0)
    }

    func testCheckpointOwnsIndependentAttentionAndRecurrentState() {
        let attention = KVCacheSimple()
        let keys = MLXArray.ones([1, 1, 4, 8])
        _ = attention.update(keys: keys, values: keys)
        let recurrent = MambaCache()
        recurrent[0] = MLXArray.ones([1, 3, 8])
        recurrent[1] = MLXArray.ones([1, 2, 4, 4])
        let snapshot = QwenStreamPromptState(tokens: [1, 2, 3, 4], thinking: false,
            attention: .productionDefault, groupSize: 4, cache: [attention, recurrent])
        _ = attention.update(keys: MLXArray.zeros([1, 1, 4, 8]), values: keys)
        recurrent[0]?[0, 0, 0] = MLXArray(99)
        recurrent[1] = MLXArray.zeros([1, 2, 4, 4])
        MLX.eval(attention.state, recurrent.state)
        XCTAssertEqual(snapshot.cache[0].offset, 4)
        XCTAssertEqual(snapshot.cache[0].state[0].shape, [1, 1, 4, 8])
        XCTAssertTrue(snapshot.cache[1] is MambaCache)
        XCTAssertEqual(snapshot.cache[1].state[0].asArray(Float.self), Array(repeating: 1, count: 24))
        XCTAssertEqual(snapshot.cache[1].state[1].asArray(Float.self), Array(repeating: 1, count: 32))
    }

    func testLargerPoolIsExplicitAndFitsAdmittedMemory() throws {
        let gib: UInt64 = 1_073_741_824
        let baseline = try XCTUnwrap(QwenStreamBudget.resolve(availableBytes: 9 * gib))
        let larger = try XCTUnwrap(QwenStreamBudget.resolve(availableBytes: 9 * gib, poolCeiling: 3 * gib))
        XCTAssertEqual(baseline.poolBytes, 2 * gib)
        XCTAssertEqual(larger.poolBytes, 3 * gib)
        XCTAssertEqual(larger.slots, 1820)
        let constrained = try XCTUnwrap(QwenStreamBudget.resolve(
            availableBytes: baseline.reservedBytes + 1, poolCeiling: 3 * gib))
        XCTAssertEqual(constrained.poolBytes, 2 * gib)
        XCTAssertLessThanOrEqual(constrained.reservedBytes, baseline.reservedBytes + 1)
    }

    func testSlotsOverwriteOnlyVictimAndRemainVisibleToNewGPUOperations() throws {
        let location = QwenStreamTensorLocation(name: "weight", shard: "test", payloadOffset: 0,
            byteCount: 4096, dtype: .f32, shape: [1024])
        let bank = try QwenStreamExpertBank(slots: 3, locations: ["weight": location])
        func payload(_ value: Float) -> Data { MLXArray(Array(repeating: value, count: 1024)).asData(access: .copy).data }
        try bank.commit(["weight": payload(3)], to: 0)
        try bank.commit(["weight": payload(7)], to: 2)
        let array = try XCTUnwrap(bank.components["weight"]?.array)
        XCTAssertEqual((array[0].sum()).item(Float.self), 3072)
        XCTAssertEqual((array[2].sum()).item(Float.self), 7168)
        try bank.commit(["weight": payload(11)], to: 0)
        XCTAssertEqual((array[0].sum()).item(Float.self), 11264)
        XCTAssertEqual((array[2].sum()).item(Float.self), 7168)
        XCTAssertThrowsError(try bank.commit(["weight": Data(count: 2)], to: 0))
        XCTAssertThrowsError(try bank.commit(["weight": payload(0)], to: 3))
        XCTAssertEqual((array[0].sum()).item(Float.self), 11264)
        let invalid = QwenStreamTensorLocation(name: "weight", shard: "test", payloadOffset: 0,
            byteCount: 8192, dtype: .f32, shape: [1024])
        XCTAssertThrowsError(try QwenStreamExpertBank(slots: 3, locations: ["weight": invalid]))
    }

    private func load(_ options: QwenStreamOptimizations) async throws -> QwenStreamingEngine {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models/\(QwenStreamArtifact.modelID)")
        let engine = QwenStreamingEngine(gate: GenerationGate(), optimizations: options)
        try await engine.load(directory: directory, modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes, contextSize: 4096)
        return engine
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }

    func testOptInRealGoldenWithReusableSlots() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_SSD_GOLDEN"] == "1" else {
            throw XCTSkip("Opt-in installed-weight slot-bank parity test")
        }
        struct Route: Decodable { let layer: Int; let position: Int; let expertIDs: [Int] }
        struct Checkpoint: Decodable { let router: [Route] }
        struct Golden: Decodable {
            let promptTokenIDs: [Int]; let generatedTokenIDs: [Int]; let checkpoints: [Checkpoint]
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_SSD_GOLDEN_JSON"]
            ?? "/tmp/vamp-ssd-golden/fixtures/primary.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "36d28854abfb78114b46a53b55607cfb4216b2ebd65d3aafb7618cc1d03d82f0")
        let golden = try JSONDecoder().decode(Golden.self, from: data)
        XCTAssertEqual(golden.generatedTokenIDs.count, 64)
        let engine = try await load(.init())
        do {
            let result = try await engine.debugGreedy(tokenIDs: golden.promptTokenIDs,
                maxTokens: golden.generatedTokenIDs.count, attentionStrategy: .productionDefault,
                includeFinalStateProbe: false)
            XCTAssertEqual(result.generatedTokenIDs, golden.generatedTokenIDs)
            let trace = try XCTUnwrap(result.router)
            var compared = 0
            for route in golden.checkpoints.flatMap(\.router) {
                for record in trace.records where record.layer == route.layer {
                    if let position = record.positions.firstIndex(of: route.position) {
                        XCTAssertEqual(Set(record.expertIDs[position]), Set(route.expertIDs),
                            "K=8 membership at layer \(route.layer), position \(route.position)")
                        compared += 1
                    }
                }
            }
            XCTAssertGreaterThan(compared, 20)
            print("[ssd-golden] matched \(result.generatedTokenIDs == golden.generatedTokenIDs) tokens=\(result.generatedTokenIDs.count)")
        } catch { await engine.unload(); throw error }
        await engine.unload()
    }

    func testOptInRealFollowUpReuseAndReset() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_SSD_PREFIX"] == "1" else {
            throw XCTSkip("Opt-in installed-weight prompt-state parity test")
        }
        let previousThinking = UserDefaults.standard.bool(forKey: ExperimentalInferencePreferences.qwenThinkingKey)
        UserDefaults.standard.set(false, forKey: ExperimentalInferencePreferences.qwenThinkingKey)
        defer { UserDefaults.standard.set(previousThinking, forKey: ExperimentalInferencePreferences.qwenThinkingKey) }
        let engine = try await load(.init())
        let first = [ChatTurn(role: .system, content: "Answer briefly and accurately. " + String(repeating: "Keep answers factual. ", count: 24)),
                     ChatTurn(role: .user, content: "Name three colors.")]
        do {
            let answer = try await collect(engine.stream(adding: first, maxTokens: 16, temperature: 0))
            let followUp = [ChatTurn(role: .assistant, content: answer), ChatTurn(role: .user, content: "Which of those is a primary color? Answer briefly.")]
            let warm = try await collect(engine.stream(adding: followUp, maxTokens: 24, temperature: 0))
            let warmEngineStats = await engine.stats
            let warmStats = try XCTUnwrap(warmEngineStats.qwenStreaming)
            let cold = try await collect(engine.streamReplay(first + followUp, maxTokens: 24, temperature: 0))
            let coldEngineStats = await engine.stats
            let coldStats = try XCTUnwrap(coldEngineStats.qwenStreaming)
            XCTAssertEqual(warm, cold)
            XCTAssertGreaterThan(warmStats.reusedPromptTokens, 80)
            XCTAssertEqual(coldStats.reusedPromptTokens, 0)
            print("[ssd-prefix] warm=\(warmStats.firstTokenSeconds ?? -1) cold=\(coldStats.firstTokenSeconds ?? -1) reused=\(warmStats.reusedPromptTokens) total=\(warmStats.promptTokens) identical=\(warm == cold)")
            await engine.reset()
            _ = try await collect(engine.stream(adding: first, maxTokens: 1, temperature: 0))
            let resetStats = await engine.stats
            XCTAssertEqual(resetStats.qwenStreaming?.reusedPromptTokens, 0)
            await engine.trimTransientMemory()
            _ = try await collect(engine.stream(adding: followUp, maxTokens: 1, temperature: 0))
            let trimStats = await engine.stats
            XCTAssertEqual(trimStats.qwenStreaming?.reusedPromptTokens, 0)
        } catch { await engine.unload(); throw error }
        await engine.unload()
    }

    func testOptInControlledCacheAndSlotExperiment() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_SSD_AB"] == "1" else {
            throw XCTSkip("Opt-in controlled cache/slot capacity experiment")
        }
        let previousThinking = UserDefaults.standard.bool(forKey: ExperimentalInferencePreferences.qwenThinkingKey)
        UserDefaults.standard.set(false, forKey: ExperimentalInferencePreferences.qwenThinkingKey)
        defer { UserDefaults.standard.set(previousThinking, forKey: ExperimentalInferencePreferences.qwenThinkingKey) }
        let prompt = [ChatTurn(role: .system, content: "You are a helpful assistant. Answer clearly and accurately."),
                      ChatTurn(role: .user, content: "Write 30 numbered practical tips for improving software engineering productivity. Each tip must contain exactly two sentences and include a concrete example.")]
        let variants: [(QwenStreamExpertPool.Storage, UInt64)] = [(.stacked, 2), (.stacked, 3), (.reusableSlots, 3), (.reusableSlots, 2)]
        var reference: String?
        var rows = [[String: Any]]()
        for (storage, gib) in variants + variants.reversed() {
            let engine = try await load(.init(reusePromptState: false, poolCeilingBytes: gib * 1_073_741_824, expertStorage: storage))
            do {
                let output = try await collect(engine.stream(adding: prompt, maxTokens: 128, temperature: 0))
                let stats = await engine.stats
                let d = try XCTUnwrap(stats.qwenStreaming)
                if let reference { XCTAssertEqual(output, reference, "\(storage) \(gib) GiB") }
                else { reference = output }
                XCTAssertEqual(d.poolBytes, gib * 1_073_741_824)
                XCTAssertEqual(d.generatedTokens, 128)
                let row: [String: Any] = ["storage": storage.rawValue, "poolGiB": gib,
                    "decodeTokensPerSecond": d.decodeTokensPerSecond ?? -1,
                    "firstTokenSeconds": d.firstTokenSeconds ?? -1,
                    "totalSeconds": d.totalSeconds ?? -1,
                    "requestedBytes": d.requestedFileBytes, "hits": d.expertHits, "misses": d.expertMisses,
                    "peakProcessBytes": d.processPeakBytes ?? 0, "inputHash": d.inputHash ?? "",
                    "identicalOutput": output == reference]
                rows.append(row)
                let report = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                try report.write(to: URL(fileURLWithPath: "/tmp/vamp-ssd-experiment.json"), options: .atomic)
                print("[ssd-ab] \(storage.rawValue) \(gib)GiB decode=\(d.decodeTokensPerSecond ?? -1) TTFT=\(d.firstTokenSeconds ?? -1) peak=\(d.processPeakBytes ?? 0)")
            } catch { await engine.unload(); throw error }
            await engine.unload()
        }
    }

    func testOptInCancelledReplyDiscardsCheckpointAndDrainsSlots() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_SSD_CANCEL"] == "1" else {
            throw XCTSkip("Opt-in cancellation/recovery test with reusable slots")
        }
        let engine = try await load(.init())
        do {
            var received = false
            do {
                for try await _ in engine.stream(adding: [.init(role: .user, content: "Count from one to one hundred.")],
                                                maxTokens: 128, temperature: 0) {
                    received = true
                    await engine.cancelGeneration()
                    break
                }
            } catch is CancellationError {}
            XCTAssertTrue(received)
            let state = await engine.debugQuiescence()
            XCTAssertFalse(state.ownerActive)
            XCTAssertFalse(state.poolBusy)
            XCTAssertEqual(state.activeLeases, 0)
            XCTAssertEqual(state.activeReads, 0)
            XCTAssertEqual(state.queuedReads, 0)
            _ = try await collect(engine.stream(adding: [.init(role: .user, content: "Say hello.")],
                maxTokens: 4, temperature: 0))
            let recovered = await engine.stats
            XCTAssertEqual(recovered.qwenStreaming?.reusedPromptTokens, 0)
            XCTAssertGreaterThan(recovered.generatedTokens, 0)
        } catch { await engine.unload(); throw error }
        await engine.unload()
        let unloaded = await engine.debugQuiescence()
        XCTAssertEqual(unloaded.poolEntries, 0)
        XCTAssertEqual(unloaded.activeReads, 0)
    }
}
