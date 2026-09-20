import Foundation
import XCTest
@testable import BeetCode

/// Opt-in instrumentation for the installed pinned artifact. This is kept out
/// of normal test runs because it performs a multi-minute, multi-gigabyte SSD
/// streaming generation on the developer machine.
final class QwenStreamingRealBenchmarkTests: XCTestCase {
    func testOptInRealArtifact128TokenTimelineAndStorage() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_BENCHMARK"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_BENCHMARK=1 to run the installed Qwen K=8 benchmark.")
        }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }

        // Q2.18: this is the ONE frozen benchmark. Only the attention strategy
        // may vary between runs. The checkpoint, K=8, the 1,213-slot / ~2.15 GB
        // pool, read concurrency, prompt token IDs, output limit, Thinking
        // setting, greedy sampling, and the application-pool starting-state
        // policy are all held fixed. Nothing is tuned during measurement.
        let requested = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_BENCHMARK_STRATEGY"]
            ?? StreamQwen35AttentionStrategy.productionFused.rawValue
        guard let strategy = StreamQwen35AttentionStrategy(rawValue: requested) else {
            XCTFail("Unknown BEETCODE_QWEN35_BENCHMARK_STRATEGY \(requested)")
            return
        }
        let counters = StreamQwen35AttentionDiagnosticCounters()

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        await engine.debugSetAttentionStrategy(strategy, counters: counters)

        let prompt = "Write 30 numbered practical tips for improving software engineering productivity. Each tip must contain exactly two sentences and include a concrete example."
        // Mirror AgentSessionController's Qwen text-only envelope: no tools,
        // chat-only, lean prompt, 4,096-token context, and a 512-token
        // response reserve. The user text remains the fixed benchmark input.
        let systemPrompt = PromptBuilder.systemPrompt(
            tools: [],
            workspace: Workspace(root: directory),
            outputStyle: .normal,
            contextWindowTokens: 4096,
            responseReserveTokens: 512,
            leanPrompt: true,
            chatOnly: true)
        var output = ""
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(role: .system, content: systemPrompt),
                ChatTurn(role: .user, content: prompt)
            ],
            maxTokens: 128,
            temperature: 0) {
            output += chunk
        }

        let stats = await engine.stats
        guard let diagnostics = stats.qwenStreaming else {
            await engine.unload()
            XCTFail("The Qwen engine did not publish diagnostics.")
            return
        }

        print("[qwen-benchmark] \(diagnostics.summary)")
        print("[qwen-benchmark] attention requested=\(diagnostics.attentionRequestedStrategy ?? "none") effective=\(diagnostics.attentionEffectiveStrategies.joined(separator: "+")) fused=\(counters.fusedInvocations) explicit=\(counters.explicitInvocations) fusedPrefill=\(counters.fusedPrefillInvocations) explicitPrefill=\(counters.explicitPrefillInvocations) fusedDecode=\(counters.fusedDecodeInvocations) explicitDecode=\(counters.explicitDecodeInvocations) fusedShapes=\(counters.fusedShapes.sorted()) explicitShapes=\(counters.explicitShapes.sorted())")
        print("[qwen-benchmark] inputHash=\(diagnostics.inputHash ?? "unavailable") promptTokens=\(diagnostics.promptTokens) generatedTokens=\(diagnostics.generatedTokens) stop=\(diagnostics.stopReason)")
        print("[qwen-benchmark] timing load=\(diagnostics.loadSeconds ?? -1) render=\(diagnostics.promptRenderSeconds ?? -1) prefill=\(diagnostics.prefillSeconds ?? -1) firstTokenGap=\(diagnostics.firstTokenGapSeconds ?? -1) firstAnswer=\(diagnostics.firstAnswerSeconds ?? -1) lastToken=\(diagnostics.lastTokenSeconds ?? -1) decode=\(diagnostics.decodeSeconds ?? -1) finalize=\(diagnostics.finalizationSeconds ?? -1) total=\(diagnostics.totalSeconds ?? -1) unclassified=\(diagnostics.unclassifiedSeconds ?? -1)")
        print("[qwen-benchmark] reads requested=\(diagnostics.requestedFileBytes) completed=\(diagnostics.completedFileBytes) prefill=\(diagnostics.prefillRequestedBytes)/\(diagnostics.prefillCompletedBytes) decode=\(diagnostics.decodeRequestedBytes)/\(diagnostics.decodeCompletedBytes) calls=\(diagnostics.prefillReadCalls)+\(diagnostics.decodeReadCalls) readSeconds=\(diagnostics.ssdReadSeconds ?? -1) phaseReadSeconds=\(diagnostics.prefillReadSeconds ?? -1)/\(diagnostics.decodeReadSeconds ?? -1)")
        print("[qwen-benchmark] cache hits=\(diagnostics.expertHits) misses=\(diagnostics.expertMisses) evictions=\(diagnostics.expertEvictions) bundles=\(diagnostics.completedExpertBundles) payload=\(diagnostics.completedPayloadBytes)/\(diagnostics.expectedPayloadBytes) reads=\(diagnostics.peakReads)/\(diagnostics.configuredReadLimit)")
        print("[qwen-benchmark] memory before=\(diagnostics.processBeforeLoadBytes ?? 0) after=\(diagnostics.processAfterLoadBytes ?? 0) sampledPeak=\(diagnostics.processPeakBytes ?? 0) end=\(diagnostics.footprintBytes ?? 0) mlx=\(diagnostics.mlxActiveBytes ?? 0)/\(diagnostics.mlxCacheBytes ?? 0)/\(diagnostics.mlxPeakBytes ?? 0) outputBytes=\(output.utf8.count)")

        await engine.unload()
        XCTAssertEqual(diagnostics.generatedTokens, 128)
        XCTAssertEqual(diagnostics.stopReason, "output limit")
        XCTAssertGreaterThan(diagnostics.promptTokens, 0)
        XCTAssertEqual(diagnostics.completedPayloadBytes, diagnostics.expectedPayloadBytes)
        XCTAssertGreaterThan(diagnostics.decodeTokensPerSecond ?? 0, 0)
        XCTAssertEqual(diagnostics.attentionRequestedStrategy, strategy.rawValue)
        XCTAssertFalse(diagnostics.attentionEffectiveStrategies.isEmpty)
        XCTAssertEqual(counters.fusedInvocations + counters.explicitInvocations,
                       counters.fusedPrefillInvocations + counters.explicitPrefillInvocations
                        + counters.fusedDecodeInvocations + counters.explicitDecodeInvocations)
        switch strategy {
        case .productionFused:
            XCTAssertEqual(counters.explicitInvocations, 0)
        case .referenceCompatibleExplicit:
            XCTAssertEqual(counters.fusedInvocations, 0)
        case .candidateHybrid:
            XCTAssertEqual(counters.fusedPrefillInvocations, 0)
            XCTAssertEqual(counters.explicitDecodeInvocations, 0)
        }
    }
}
