import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import BeetCode

/// Q2.18 — production attention strategy.
///
/// The Q2.16/Q2.17 independent fixture established that the developer-only
/// ``referenceCompatibleExplicit`` path matches the pinned MLX 0.31.1 Metal
/// Qwen3.5-35B-A3B K=8 reference. That path is therefore the known-correct
/// native baseline, and the shipped fused strategy remains unvalidated because
/// a demonstrated qLen=4 prefill drift altered real K=8 routing membership.
///
/// These tests decide, in order:
///
/// 1. a bounded SDPA compatibility matrix built from real production shapes;
/// 2. the qLen=1 fused-decode hypothesis, including teacher-forced downstream
///    routing;
/// 3. hybrid A (explicit prefill + fused qLen=1 decode) against the accepted
///    64-token independent golden;
/// 4. a longer native explicit-control extension;
/// 5. a counterbalanced performance A/B.
///
/// Nothing here changes model weights, K=8, quantization, the router, the
/// shared expert, the expert pool, read concurrency, the tokenizer/template,
/// Thinking, sampling, MLX dependencies, GatedDeltaNet, or cache semantics.
/// Only attention-strategy selection varies.
final class QwenStreamQ218AttentionStrategyTests: XCTestCase {

    // MARK: - Frozen golden evidence

    /// The accepted Q2.16 independent fixture. It is immutable evidence: the
    /// expected tokens are never regenerated from native execution.
    private static let goldenSHA256 =
        "cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a"
    private static let goldenFormat = "qwen35-k8-q216-explicit-reference-v1"
    private static let fullAttentionLayers = [3, 7, 11, 15, 19, 23, 27, 31, 35, 39]

    // MARK: - Strategy selection rule (no model required)

    /// The hybrid rule must be semantic and shape-only. It cannot encode a
    /// whitelist of known failures, so it is a pure function of query length
    /// and has no layer, position, prompt, or expert parameter at all.
    func testHybridSelectionRuleIsQueryLengthOnly() {
        for queryLength in 1 ... 64 {
            XCTAssertEqual(
                StreamQwen35AttentionStrategy.productionFused.effective(queryLength: queryLength),
                .productionFused)
            XCTAssertEqual(
                StreamQwen35AttentionStrategy.referenceCompatibleExplicit.effective(queryLength: queryLength),
                .referenceCompatibleExplicit)
            let hybrid = StreamQwen35AttentionStrategy.candidateHybrid.effective(queryLength: queryLength)
            XCTAssertEqual(
                hybrid,
                queryLength > 1 ? .referenceCompatibleExplicit : .productionFused,
                "hybrid must resolve on query length alone")
            XCTAssertTrue(hybrid.isConcrete)
        }
        XCTAssertFalse(StreamQwen35AttentionStrategy.candidateHybrid.isConcrete)
        XCTAssertTrue(StreamQwen35AttentionStrategy.productionFused.isConcrete)
        XCTAssertTrue(StreamQwen35AttentionStrategy.referenceCompatibleExplicit.isConcrete)
        XCTAssertEqual(
            StreamQwen35AttentionStrategy.allCases.map(\.rawValue),
            ["productionFused", "referenceCompatibleExplicit", "candidateHybrid"])
    }

    /// Requested and effective strategies must both be recorded, and a hybrid
    /// run must report both concrete strategies rather than claiming a single
    /// one. This is what makes "no silent fallback" observable.
    func testCountersReportPhaseBreakdownWithoutSilentFallback() {
        let counters = StreamQwen35AttentionDiagnosticCounters()
        let layers = Self.fullAttentionLayers

        // One 39-token prompt in groups of four: nine groups of 4 plus a tail
        // of 3, exactly the shape the frozen fixture produces.
        let prefillLengths = [4, 4, 4, 4, 4, 4, 4, 4, 4, 3]
        for (group, length) in prefillLengths.enumerated() {
            for layer in layers {
                counters.record(
                    requested: .candidateHybrid,
                    effective: StreamQwen35AttentionStrategy.candidateHybrid.effective(queryLength: length),
                    layer: layer, queryLength: length, keyLength: group * 4 + length)
            }
        }
        for step in 0 ..< 63 {
            for layer in layers {
                counters.record(
                    requested: .candidateHybrid,
                    effective: StreamQwen35AttentionStrategy.candidateHybrid.effective(queryLength: 1),
                    layer: layer, queryLength: 1, keyLength: 39 + step + 1)
            }
        }

        XCTAssertEqual(counters.requestedStrategies, [.candidateHybrid])
        XCTAssertEqual(
            counters.effectiveStrategies,
            [.productionFused, .referenceCompatibleExplicit])
        XCTAssertEqual(counters.fusedInvocations, layers.count * 63)
        XCTAssertEqual(counters.explicitInvocations, layers.count * (prefillLengths.count + 0))
        XCTAssertEqual(counters.fusedPrefillInvocations, 0)
        XCTAssertEqual(counters.explicitPrefillInvocations, layers.count * prefillLengths.count)
        XCTAssertEqual(counters.fusedDecodeInvocations, layers.count * 63)
        XCTAssertEqual(counters.explicitDecodeInvocations, 0)
        XCTAssertEqual(counters.fusedInvocations + counters.explicitInvocations,
                       counters.fusedPrefillInvocations + counters.explicitPrefillInvocations
                        + counters.fusedDecodeInvocations + counters.explicitDecodeInvocations)
        for layer in layers {
            XCTAssertEqual(counters.explicitInvocationsByLayer[layer], prefillLengths.count)
            XCTAssertEqual(counters.fusedInvocationsByLayer[layer], 63)
            XCTAssertEqual(counters.explicitQueryLengthsByLayer[layer], prefillLengths)
            XCTAssertEqual(Set(counters.fusedQueryLengthsByLayer[layer] ?? []), [1])
        }
        XCTAssertEqual(counters.explicitQueryLengths, Set(prefillLengths))
        XCTAssertEqual(counters.fusedQueryLengths, [1])
        XCTAssertTrue(counters.summary.contains("requested=candidateHybrid"))
        XCTAssertTrue(counters.summary.contains("effective=productionFused+referenceCompatibleExplicit"))

        counters.reset()
        XCTAssertEqual(counters.fusedInvocations, 0)
        XCTAssertEqual(counters.explicitInvocations, 0)
        XCTAssertTrue(counters.requestedStrategies.isEmpty)
        XCTAssertTrue(counters.effectiveStrategies.isEmpty)
        XCTAssertEqual(counters.fusedPrefillInvocations, 0)
        XCTAssertEqual(counters.explicitDecodeInvocations, 0)
    }

    /// The Q2.18 production decision, locked. Outcome C: fused qLen=1 decode
    /// failed the section-6 routing gate, so the validated explicit path is the
    /// shipping default. Every API default in the Qwen streaming stack resolves
    /// through `productionDefault`, so this one assertion pins the user-facing
    /// behaviour; changing it requires new correctness evidence.
    func testProductionDefaultIsTheValidatedExplicitPath() async {
        XCTAssertEqual(
            StreamQwen35AttentionStrategy.productionDefault,
            .referenceCompatibleExplicit,
            "the Qwen production default must remain the independently validated explicit path")
        XCTAssertTrue(StreamQwen35AttentionStrategy.productionDefault.isConcrete)
        XCTAssertTrue(StreamQwen35AttentionStrategy.productionDefault.usesExplicitAttention)
        // A hybrid or fused request must still resolve through the same single
        // resolution point, so the default cannot be bypassed by shape.
        for queryLength in [1, 2, 3, 4, 8, 128] {
            XCTAssertEqual(
                StreamQwen35AttentionStrategy.productionDefault.effective(queryLength: queryLength),
                .referenceCompatibleExplicit)
        }
        // The engine starts on the production default and reports it.
        let engine = QwenStreamingEngine(gate: GenerationGate())
        let strategy = await engine.debugAttentionStrategy()
        XCTAssertEqual(strategy, .productionDefault)
        XCTAssertEqual(strategy.rawValue, "referenceCompatibleExplicit")
    }

    /// Pure fused and pure explicit runs must not report a hybrid effective
    /// strategy, so a benchmark log can never be misread.
    func testCountersKeepPureStrategiesPure() {
        let fused = StreamQwen35AttentionDiagnosticCounters()
        fused.record(requested: .productionFused, effective: .productionFused,
                     layer: 7, queryLength: 4, keyLength: 28)
        XCTAssertEqual(fused.effectiveStrategies, [.productionFused])
        XCTAssertEqual(fused.fusedPrefillInvocations, 1)
        XCTAssertEqual(fused.explicitDecodeInvocations, 0)

        let explicit = StreamQwen35AttentionDiagnosticCounters()
        explicit.record(requested: .referenceCompatibleExplicit,
                        effective: .referenceCompatibleExplicit,
                        layer: 7, queryLength: 1, keyLength: 103)
        XCTAssertEqual(explicit.effectiveStrategies, [.referenceCompatibleExplicit])
        XCTAssertEqual(explicit.explicitDecodeInvocations, 1)
        XCTAssertEqual(explicit.fusedDecodeInvocations, 0)
        XCTAssertEqual(explicit.explicitShapes, ["1x103"])

        // Counting must happen in exactly one place. A global counter that is
        // incremented both by the call site and by record() would silently
        // double every figure in the validation reports, so the global total
        // must equal the sum of the per-layer totals.
        let consistency = StreamQwen35AttentionDiagnosticCounters()
        for layer in Self.fullAttentionLayers {
            for queryLength in [4, 4, 3, 1, 1, 1] {
                consistency.record(
                    requested: .candidateHybrid,
                    effective: StreamQwen35AttentionStrategy.candidateHybrid
                        .effective(queryLength: queryLength),
                    layer: layer, queryLength: queryLength, keyLength: 32)
            }
        }
        let total = Self.fullAttentionLayers.count * 6
        XCTAssertEqual(consistency.fusedInvocations + consistency.explicitInvocations, total)
        XCTAssertEqual(consistency.fusedInvocationsByLayer.values.reduce(0, +),
                       consistency.fusedInvocations)
        XCTAssertEqual(consistency.explicitInvocationsByLayer.values.reduce(0, +),
                       consistency.explicitInvocations)
        XCTAssertEqual(
            consistency.fusedPrefillInvocations + consistency.explicitPrefillInvocations
                + consistency.fusedDecodeInvocations + consistency.explicitDecodeInvocations,
            total)
        // A record with no layer attribution still counts globally.
        consistency.record(requested: .productionFused, effective: .productionFused,
                           layer: nil, queryLength: 1, keyLength: 40)
        XCTAssertEqual(consistency.fusedInvocations, Self.fullAttentionLayers.count * 3 + 1)
        XCTAssertEqual(consistency.fusedInvocationsByLayer.values.reduce(0, +),
                       Self.fullAttentionLayers.count * 3)
    }

    /// The explicit path's materialized mask must preserve production mask
    /// semantics: `.none` at a cached single-token decode is "attend to every
    /// cached key", and `.causal` is the standard lower-triangular mask at the
    /// cache offset.
    func testMaterializedMaskPreservesProductionSemantics() {
        let none = StreamQwen35Attention.materializedMask(
            .none, queryLength: 1, keyLength: 5, cacheOffset: 4)
        XCTAssertEqual(none.shape, [1, 5])
        XCTAssertEqual(none.dtype, .bool)
        XCTAssertTrue(MLX.all(none).item(Bool.self), ".none must become an all-true mask")

        let causal = StreamQwen35Attention.materializedMask(
            .causal, queryLength: 4, keyLength: 28, cacheOffset: 24)
        XCTAssertEqual(causal.shape, [4, 28])
        let expected = createCausalMask(n: 4, offset: 24)
        XCTAssertEqual(causal.shape, expected.shape)
        XCTAssertTrue(MLX.all(MLX.equal(causal, expected)).item(Bool.self))
        // The last prefill row still attends to every key at or before it.
        let rows = causal.asType(.int32).asArray(Int32.self)
        XCTAssertEqual(rows.suffix(28).filter { $0 == 1 }.count, 28)
        XCTAssertEqual(rows.prefix(28).filter { $0 == 1 }.count, 25)

        let explicitArray = MLXArray.ones([2, 6], dtype: .bool)
        let passthrough = StreamQwen35Attention.materializedMask(
            .array(explicitArray), queryLength: 2, keyLength: 6, cacheOffset: 4)
        XCTAssertTrue(MLX.all(MLX.equal(passthrough, explicitArray)).item(Bool.self))
    }

    /// The explicit reference replay must stay a faithful float32 pipeline. A
    /// tiny deterministic case pins the GQA expansion, the scale-before-matmul
    /// order, the precise softmax, and the final BF16 cast.
    func testExplicitReferenceReplayIsDeterministicOnSyntheticInput() throws {
        let queries = MLXArray([Float](repeating: 0.25, count: 1 * 4 * 2 * 8)).reshaped(1, 4, 2, 8)
        let keys = MLXArray([Float](repeating: 0.5, count: 1 * 2 * 2 * 8)).reshaped(1, 2, 2, 8)
        let values = MLXArray([Float](repeating: 1.0, count: 1 * 2 * 2 * 8)).reshaped(1, 2, 2, 8)
        let mask = MLXArray.ones([2, 2], dtype: .bool)
        let scale = pow(Float(8), -0.5)

        let first = StreamQwen35Attention.referenceCompatibleExplicitAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask)
        let second = StreamQwen35Attention.referenceCompatibleExplicitAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask)
        XCTAssertEqual(first.output.dtype, .bfloat16)
        XCTAssertEqual(first.output.shape, [1, 4, 2, 8])
        XCTAssertEqual(first.expandedKeys.shape, [1, 4, 2, 8], "GQA ratio must expand 2 KV heads to 4")
        XCTAssertEqual(first.probabilities.dtype, .float32)
        XCTAssertTrue(MLX.all(MLX.equal(first.output, second.output)).item(Bool.self))

        // Uniform scores over two identical value rows collapse to the value
        // itself; this pins the softmax/matmul order without a tolerance.
        let out = first.output.asType(.float32).flattened().asArray(Float.self)
        for value in out {
            XCTAssertEqual(value, 1.0, accuracy: 1e-6)
        }
        // The documented scale-before-matmul order is observable: scaling the
        // raw product instead must not be substituted silently.
        let raw = first.rawQK.asType(.float32).flattened().asArray(Float.self)
        let scaled = first.scaledScores.asType(.float32).flattened().asArray(Float.self)
        XCTAssertEqual(raw.count, scaled.count)
        XCTAssertEqual(scaled[0], raw[0] * scale, accuracy: 1e-5)
    }

    // MARK: - Real-model evidence (opt-in)

    /// Builds the bounded SDPA compatibility matrix from actual production
    /// shapes on all ten full-attention layers.
    func testOptInQ218SDPACompatibilityMatrix() async throws {
        guard Self.enabled("BEETCODE_QWEN35_Q218_MATRIX") else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q218_MATRIX=1 for the Q2.18 SDPA compatibility matrix.")
        }
        let fixture = try Self.loadGoldenFixture()
        let engine = try await Self.loadEngine()
        defer { Task { await engine.unload() } }

        let actualLayers = await engine.debugFullAttentionLayerIndices()
        XCTAssertEqual(actualLayers, Self.fullAttentionLayers)

        // Prefill groups come straight from the frozen fixture: ten groups
        // covering qLen 4 and the qLen 3 tail. Decode steps sample short,
        // medium, and the longest KV length the fixture actually reaches — no
        // invented synthetic context.
        let decodeSteps: Set<Int> = [0, 1, 2, 3, 7, 15, 31, 45, 62]
        let matrix = try await engine.debugSDPACompatibilityMatrix(
            tokenIDs: fixture.promptTokenIDs,
            forcedTokenIDs: Array(fixture.generatedTokenIDs.prefix(63)),
            layers: Set(actualLayers),
            prefillGroups: nil,
            decodeSteps: decodeSteps,
            captureStrategy: .referenceCompatibleExplicit)

        XCTAssertGreaterThan(matrix.prefillEntries, 0)
        XCTAssertGreaterThan(matrix.decodeEntries, 0)
        XCTAssertEqual(matrix.captureStrategy, "referenceCompatibleExplicit")
        XCTAssertEqual(
            Set(matrix.entries.map(\.layer)), Set(actualLayers),
            "the matrix must cover every config-derived full-attention layer")
        XCTAssertEqual(matrix.entries.map(\.headDim).unique(), [256])
        XCTAssertEqual(matrix.entries.map(\.queryHeads).unique(), [16])
        XCTAssertEqual(matrix.entries.map(\.kvHeads).unique(), [2])

        // Every entry must be a real production shape: prefill query lengths
        // come from the four-token groups and their tail, decode is qLen=1.
        XCTAssertEqual(Set(matrix.entries.filter { $0.phase == "prefill" }.map(\.queryLength)),
                       Set([3, 4]),
                       "prefill must cover the real group size and the real tail length")
        XCTAssertEqual(matrix.entries.filter { $0.phase == "decode" }.map(\.queryLength).unique(), [1])

        // The fused kernel and the explicit replay must agree on mask
        // semantics, otherwise the matrix would be comparing different
        // mathematical objects rather than different kernels.
        for entry in matrix.entries {
            XCTAssertTrue(
                entry.maskSemanticsAgree,
                "mask semantics differ at layer \(entry.layer) phase \(entry.phase) qLen \(entry.queryLength)")
        }

        Self.write(matrix, to: "Qwen35-K8-Q2.18-sdpa-compatibility-matrix.json")
        Self.logMatrix(matrix)
        print("[qwen-q218-matrix] decodeBitwiseClean=\(matrix.decodeBitwiseClean) "
            + "decode=\(matrix.decodeByteIdentical)/\(matrix.decodeEntries) "
            + "maxRelL2=\(matrix.decodeMaxRelL2) maxAbs=\(matrix.decodeMaxAbs) | "
            + "prefill=\(matrix.prefillByteIdentical)/\(matrix.prefillEntries) "
            + "maxRelL2=\(matrix.prefillMaxRelL2) maxAbs=\(matrix.prefillMaxAbs) "
            + "qLens=\(matrix.distinctPrefillQueryLengths) kvLens=\(matrix.distinctDecodeKeyLengths)")
    }

    /// The key hypothesis: fused qLen=1 decode is clean. This compares the
    /// candidate hybrid against the explicit baseline over a teacher-forced
    /// reference history, at the attention block level and at every router
    /// position.
    func testOptInQ218QLen1FusedDecodeDownstreamRouting() async throws {
        guard Self.enabled("BEETCODE_QWEN35_Q218_DECODE") else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q218_DECODE=1 for the Q2.18 qLen=1 decode correctness check.")
        }
        let fixture = try Self.loadGoldenFixture()
        let engine = try await Self.loadEngine()
        defer { Task { await engine.unload() } }

        let forced = fixture.generatedTokenIDs
        let blockIndices: Set<Int> = [0, 1, 2, 4, 8, 16, 32, 45, 62]
        let layers = Set(0 ..< 40)

        let baseline = try await engine.debugTeacherForcedStrategyReplay(
            tokenIDs: fixture.promptTokenIDs,
            forcedTokenIDs: forced,
            strategy: .referenceCompatibleExplicit,
            blockLayer: 19,
            blockDecodeIndices: blockIndices,
            routerTraceLayers: layers,
            blockCaptureFullValues: true)
        XCTAssertEqual(baseline.fusedCalls, 0, "the explicit baseline must not touch the fused kernel")
        XCTAssertEqual(baseline.effectiveStrategies, ["referenceCompatibleExplicit"])
        XCTAssertEqual(baseline.explicitCalls,
                       Self.fullAttentionLayers.count
                        * (baseline.prefillCallCount + baseline.cachedDecodeCallCount),
                       "every full-attention invocation in the baseline must be instrumented")

        // Anchor the baseline to the independent golden before using it as the
        // correctness reference. If the baseline itself had drifted, the
        // comparison below would be meaningless.
        let goldenRouters = Self.expectedRouters(fixture)
        var baselineGoldenFailures = 0
        var baselineGoldenComparisons = 0
        if let trace = baseline.router {
            let actual = Self.actualRouters(trace)
            for (key, expectedIDs) in goldenRouters {
                guard let record = actual[key] else { continue }
                baselineGoldenComparisons += 1
                if Set(record.ids) != Set(expectedIDs) {
                    baselineGoldenFailures += 1
                    print("[qwen-q218-baseline-vs-golden-mismatch] layer=\(key.layer) "
                        + "position=\(key.position) golden=\(expectedIDs) baseline=\(record.ids)")
                }
            }
        }
        XCTAssertGreaterThan(baselineGoldenComparisons, 0)
        XCTAssertEqual(baselineGoldenFailures, 0,
                       "the explicit baseline must still match the independent golden")

        let candidate = try await engine.debugTeacherForcedStrategyReplay(
            tokenIDs: fixture.promptTokenIDs,
            forcedTokenIDs: forced,
            strategy: .candidateHybrid,
            blockLayer: 19,
            blockDecodeIndices: blockIndices,
            routerTraceLayers: layers,
            blockCaptureFullValues: true)

        // Hybrid A must be explicit for every multi-token prefill group and
        // fused for every cached single-token decode call.
        XCTAssertEqual(candidate.requestedStrategies, ["candidateHybrid"])
        XCTAssertEqual(candidate.effectiveStrategies.sorted(),
                       ["productionFused", "referenceCompatibleExplicit"])
        XCTAssertEqual(candidate.explicitPrefillCalls,
                       Self.fullAttentionLayers.count * baseline.prefillCallCount)
        XCTAssertEqual(candidate.fusedPrefillCalls, 0)
        XCTAssertEqual(candidate.fusedDecodeCalls,
                       Self.fullAttentionLayers.count * baseline.cachedDecodeCallCount)
        XCTAssertEqual(candidate.explicitDecodeCalls, 0)
        XCTAssertEqual(candidate.cachedDecodeCallCount, baseline.cachedDecodeCallCount)
        XCTAssertEqual(candidate.prefillCallCount, baseline.prefillCallCount)

        let comparison = Self.compareRouters(
            baseline: baseline, candidate: candidate)
        XCTAssertGreaterThan(comparison.comparisons, 0)

        let blocks = Self.compareBlocks(
            baseline: baseline.blocks, candidate: candidate.blocks)
        XCTAssertFalse(blocks.isEmpty)

        // This is a classification, not a wish. Section 6 requires zero true
        // K=8 membership differences; the verdict is derived from the measured
        // evidence and the promotion decision follows from it mechanically.
        let confirmed = comparison.routingClean
        let verdict = QwenStreamQ218QLen1Verdict(
            hypothesisConfirmed: confirmed,
            gate: "zero true K=8 membership differences over a teacher-forced golden history",
            baselineGoldenComparisons: baselineGoldenComparisons,
            baselineGoldenMembershipFailures: baselineGoldenFailures,
            comparisons: comparison.comparisons,
            membershipFailures: comparison.membershipFailures,
            orderOnlyDifferences: comparison.orderOnlyDifferences,
            maxScoreRelL2: comparison.maxScoreRelL2,
            maxScoreMaxAbs: comparison.maxScoreMaxAbs,
            minKGap: comparison.minKGap,
            predictedTokenDifferences: comparison.predictedTokenDifferences,
            firstPredictedDifferenceIndex: comparison.firstPredictedDifferenceIndex,
            blockEntries: blocks.count,
            blockOutputByteIdentical: blocks.filter(\.blockOutputByteIdentical).count,
            sdpaByteIdentical: blocks.filter(\.sdpaByteIdentical).count,
            maxBlockRelL2: blocks.map(\.blockRelL2).max() ?? 0,
            maxBlockMaxAbs: blocks.map(\.blockMaxAbs).max() ?? 0,
            promotion: confirmed
                ? "hybrid A admissible: proceed to the 64-token golden parity run"
                : "REJECT hybrid A: explicit everywhere is the only correctness candidate",
            routing: comparison)
        if confirmed {
            XCTAssertTrue(comparison.routingClean)
        } else {
            XCTAssertGreaterThan(comparison.membershipFailures, 0)
            XCTAssertEqual(verdict.promotion,
                           "REJECT hybrid A: explicit everywhere is the only correctness candidate")
        }

        Self.write(verdict, to: "Qwen35-K8-Q2.18-qlen1-verdict.json")
        Self.write(comparison, to: "Qwen35-K8-Q2.18-qlen1-decode-routing.json")
        Self.write(QwenStreamQ218BlockComparisonReport(entries: blocks),
                   to: "Qwen35-K8-Q2.18-qlen1-decode-blocks.json")
        print("[qwen-q218-decode] hypothesisConfirmed=\(confirmed) "
            + "comparisons=\(comparison.comparisons) "
            + "membershipFailures=\(comparison.membershipFailures) "
            + "orderOnly=\(comparison.orderOnlyDifferences) "
            + "maxScoreRelL2=\(comparison.maxScoreRelL2) minKGap=\(comparison.minKGap) "
            + "predictedDifferences=\(comparison.predictedTokenDifferences) "
            + "firstDifferenceIndex=\(comparison.firstPredictedDifferenceIndex.map(String.init) ?? "none") "
            + "baselineVsGolden=\(baselineGoldenComparisons) comparisons/\(baselineGoldenFailures) failures "
            + "fusedDecode=\(candidate.fusedDecodeCalls) explicitPrefill=\(candidate.explicitPrefillCalls) "
            + "blockOutputByteIdentical=\(verdict.blockOutputByteIdentical)/\(blocks.count)")
        for block in blocks {
            print("[qwen-q218-block] index=\(block.decodeIndex) layer=\(block.layer) "
                + "sdpaByteIdentical=\(block.sdpaByteIdentical) "
                + "blockOutputByteIdentical=\(block.blockOutputByteIdentical) "
                + "sdpaRelL2=\(block.sdpaRelL2) blockRelL2=\(block.blockRelL2) "
                + "blockMaxAbs=\(block.blockMaxAbs)")
        }
    }

    /// Golden parity for both candidates.
    ///
    /// The explicit candidate must reproduce the accepted independent 64-token
    /// fixture exactly — that is the frozen correctness baseline and it is
    /// re-asserted here rather than assumed.
    ///
    /// The hybrid candidate is the one section 6 rejected. It is still run
    /// against the golden so the report records the trap the phase brief warns
    /// about: a 64-token greedy stream can happen to stay identical while true
    /// K=8 routing membership has already diverged. Greedy-stream equality is
    /// therefore reported separately from, and never allowed to waive, the
    /// router membership result.
    func testOptInQ218GoldenParityClassification() async throws {
        guard Self.enabled("BEETCODE_QWEN35_Q218_GOLDEN") else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q218_GOLDEN=1 for the Q2.18 golden parity classification.")
        }
        let fixture = try Self.loadGoldenFixture()
        let engine = try await Self.loadEngine()
        defer { Task { await engine.unload() } }

        func runCandidate(
            _ strategy: StreamQwen35AttentionStrategy
        ) async throws -> (QwenStreamQ218GoldenReport, [Int], Int, Int) {
            let counters = StreamQwen35AttentionDiagnosticCounters()
            let run = try await engine.debugGreedy(
                tokenIDs: fixture.promptTokenIDs,
                maxTokens: fixture.generatedTokenIDs.count,
                rawRouterKeys: [QwenStreamRouterTraceKey(layer: 19, position: 46)],
                attentionStrategy: strategy,
                diagnosticCounters: counters,
                includeFinalStateProbe: false)

            XCTAssertEqual(run.promptTokenIDs, fixture.promptTokenIDs)
            XCTAssertEqual(run.prefillCallCount, (fixture.promptTokenCount + 3) / 4)
            XCTAssertEqual(counters.requestedStrategies, [strategy])
            XCTAssertEqual(
                counters.explicitInvocations + counters.fusedInvocations,
                Self.fullAttentionLayers.count
                    * (run.prefillCallCount + run.cachedDecodeCallCount),
                "every full-attention invocation must be instrumented exactly once")
            switch strategy {
            case .referenceCompatibleExplicit:
                XCTAssertEqual(counters.fusedInvocations, 0)
                XCTAssertEqual(counters.explicitPrefillInvocations,
                               Self.fullAttentionLayers.count * run.prefillCallCount)
                XCTAssertEqual(counters.explicitDecodeInvocations,
                               Self.fullAttentionLayers.count * run.cachedDecodeCallCount)
                XCTAssertEqual(run.cachedDecodeCallCount, fixture.generatedTokenIDs.count - 1)
                XCTAssertEqual(run.finalConsumedPosition, fixture.finalConsumedPosition)
            case .candidateHybrid:
                XCTAssertEqual(counters.fusedPrefillInvocations, 0)
                XCTAssertEqual(counters.explicitDecodeInvocations, 0)
                XCTAssertEqual(counters.explicitPrefillInvocations,
                               Self.fullAttentionLayers.count * run.prefillCallCount)
                XCTAssertEqual(counters.fusedDecodeInvocations,
                               Self.fullAttentionLayers.count * run.cachedDecodeCallCount)
            case .productionFused:
                XCTAssertEqual(counters.explicitInvocations, 0)
            }

            var membershipFailures = 0
            var comparisons = 0
            guard let trace = run.router else {
                XCTFail("\(strategy.rawValue) produced no router trace")
                return (QwenStreamQ218GoldenReport(
                    strategy: strategy.rawValue,
                    generatedTokens: run.generatedTokenIDs.count,
                    expectedTokens: fixture.generatedTokenIDs.count,
                    firstDifference: Self.firstDifference(
                        run.generatedTokenIDs, fixture.generatedTokenIDs),
                    greedyStreamIdentical: false,
                    stopReason: run.stopReason,
                    stopReasonIdentical: false,
                    finalConsumedPosition: run.finalConsumedPosition,
                    prefillCallCount: run.prefillCallCount,
                    cachedDecodeCallCount: run.cachedDecodeCallCount,
                    requestedStrategies: counters.requestedStrategies.map(\.reportLabel).sorted(),
                    effectiveStrategies: counters.effectiveStrategies.map(\.reportLabel).sorted(),
                    fusedCalls: counters.fusedInvocations,
                    explicitCalls: counters.explicitInvocations,
                    fusedPrefillCalls: counters.fusedPrefillInvocations,
                    explicitPrefillCalls: counters.explicitPrefillInvocations,
                    fusedDecodeCalls: counters.fusedDecodeInvocations,
                    explicitDecodeCalls: counters.explicitDecodeInvocations,
                    routerComparisons: 0,
                    routerMembershipFailures: 0), [], 0, 0)
            }
            XCTAssertTrue(trace.isComplete, "router trace exceeded its bounded capacity")
            let expected = Self.expectedRouters(fixture)
            let actual = Self.actualRouters(trace)
            for (key, expectedIDs) in expected {
                guard let record = actual[key] else {
                    XCTFail("\(strategy.rawValue) router record missing "
                        + "layer=\(key.layer) position=\(key.position)")
                    continue
                }
                comparisons += 1
                if Set(record.ids) != Set(expectedIDs) {
                    membershipFailures += 1
                    print("[qwen-q218-golden-router-mismatch] strategy=\(strategy.rawValue) "
                        + "layer=\(key.layer) position=\(key.position) "
                        + "golden=\(expectedIDs) actual=\(record.ids)")
                }
            }
            let identical = run.generatedTokenIDs == fixture.generatedTokenIDs
            let report = QwenStreamQ218GoldenReport(
                strategy: strategy.rawValue,
                generatedTokens: run.generatedTokenIDs.count,
                expectedTokens: fixture.generatedTokenIDs.count,
                firstDifference: Self.firstDifference(
                    run.generatedTokenIDs, fixture.generatedTokenIDs),
                greedyStreamIdentical: identical,
                stopReason: run.stopReason,
                stopReasonIdentical: run.stopReason == fixture.stopReason,
                finalConsumedPosition: run.finalConsumedPosition,
                prefillCallCount: run.prefillCallCount,
                cachedDecodeCallCount: run.cachedDecodeCallCount,
                requestedStrategies: counters.requestedStrategies.map(\.reportLabel).sorted(),
                effectiveStrategies: counters.effectiveStrategies.map(\.reportLabel).sorted(),
                fusedCalls: counters.fusedInvocations,
                explicitCalls: counters.explicitInvocations,
                fusedPrefillCalls: counters.fusedPrefillInvocations,
                explicitPrefillCalls: counters.explicitPrefillInvocations,
                fusedDecodeCalls: counters.fusedDecodeInvocations,
                explicitDecodeCalls: counters.explicitDecodeInvocations,
                routerComparisons: comparisons,
                routerMembershipFailures: membershipFailures)
            return (report, run.generatedTokenIDs, comparisons, membershipFailures)
        }

        // The correctness candidate. This is a hard gate, not a measurement.
        let (explicitReport, explicitTokens, explicitComparisons, explicitFailures) =
            try await runCandidate(.referenceCompatibleExplicit)
        XCTAssertEqual(explicitReport.firstDifference, nil,
                       "the explicit baseline must reproduce all 64 independent golden token IDs")
        XCTAssertTrue(explicitReport.greedyStreamIdentical)
        XCTAssertTrue(explicitReport.stopReasonIdentical)
        XCTAssertEqual(explicitReport.stopReason, fixture.stopReason)
        XCTAssertEqual(explicitReport.finalConsumedPosition, fixture.finalConsumedPosition)
        XCTAssertEqual(explicitReport.cachedDecodeCallCount, fixture.generatedTokenIDs.count - 1)
        XCTAssertGreaterThan(explicitComparisons, 0)
        XCTAssertEqual(explicitFailures, 0,
                       "the explicit baseline must have zero true K=8 membership failures")
        Self.write(explicitReport, to: "Qwen35-K8-Q2.18-golden-explicit.json")

        // The rejected candidate, measured for the record.
        let (hybridReport, hybridTokens, hybridComparisons, hybridFailures) =
            try await runCandidate(.candidateHybrid)
        XCTAssertGreaterThan(hybridComparisons, 0)
        Self.write(hybridReport, to: "Qwen35-K8-Q2.18-golden-hybrid-rejected.json")

        // The whole point of the phase brief: greedy-stream equality must never
        // be read as correctness. Record both facts independently.
        let greedyAgreement = hybridTokens == explicitTokens
        let classification = QwenStreamQ218GoldenClassification(
            explicit: explicitReport,
            hybridRejected: hybridReport,
            hybridGreedyStreamMatchesExplicit: greedyAgreement,
            hybridRouterMembershipFailures: hybridFailures,
            waiverAllowed: false,
            note: greedyAgreement && hybridFailures > 0
                ? "hybrid greedy stream matched while true K=8 membership diverged: "
                    + "final-token equality is NOT a compatibility test"
                : (hybridFailures > 0
                    ? "hybrid diverged from the golden in both greedy stream and routing"
                    : "hybrid matched the golden on this fixture; section 6 still governs"))
        Self.write(classification, to: "Qwen35-K8-Q2.18-golden-classification.json")
        print("[qwen-q218-golden] explicit=64/\(fixture.generatedTokenIDs.count) "
            + "routers=\(explicitComparisons) failures=\(explicitFailures) | "
            + "hybrid greedyIdentical=\(greedyAgreement) routers=\(hybridComparisons) "
            + "failures=\(hybridFailures) stop=\(hybridReport.stopReason)")
        print("[qwen-q218-golden] \(classification.note)")
    }

    /// Longer decode coverage, labelled honestly: the portion beyond the
    /// independently validated 64-token horizon is a NATIVE EXPLICIT CONTROL
    /// EXTENSION, not independent-oracle validation.
    ///
    /// Section 6 rejected the hybrid, so the candidate here defaults to the
    /// strategy that actually ships today — fused everywhere — and the run is a
    /// measurement of how far the shipping path drifts from the validated
    /// baseline over a longer horizon. It is not a promotion gate: a fused run
    /// cannot win promotion regardless of the numbers.
    func testOptInQ218LongerExplicitControlExtension() async throws {
        guard Self.enabled("BEETCODE_QWEN35_Q218_LONG") else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q218_LONG=1 for the Q2.18 explicit control extension.")
        }
        let limit = Int(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q218_LONG_TOKENS"] ?? "128") ?? 128
        let requested = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q218_LONG_CANDIDATE"]
            ?? StreamQwen35AttentionStrategy.productionFused.rawValue
        guard let candidateStrategy = StreamQwen35AttentionStrategy(rawValue: requested),
              candidateStrategy != .referenceCompatibleExplicit else {
            XCTFail("BEETCODE_QWEN35_Q218_LONG_CANDIDATE must name a non-explicit candidate")
            return
        }
        _ = try Self.loadGoldenFixture()
        let engine = try await Self.loadEngine()
        defer { Task { await engine.unload() } }

        let prompt = Self.longControlPromptTokenIDs
        XCTAssertGreaterThan(prompt.count, 0)

        let explicitCounters = StreamQwen35AttentionDiagnosticCounters()
        let explicitRun = try await engine.debugGreedy(
            tokenIDs: prompt,
            maxTokens: limit,
            attentionStrategy: .referenceCompatibleExplicit,
            diagnosticCounters: explicitCounters,
            includeFinalStateProbe: false)
        XCTAssertEqual(explicitCounters.fusedInvocations, 0)
        XCTAssertEqual(explicitCounters.explicitInvocations,
                       Self.fullAttentionLayers.count
                        * (explicitRun.prefillCallCount + explicitRun.cachedDecodeCallCount))

        let candidateCounters = StreamQwen35AttentionDiagnosticCounters()
        let candidateRun = try await engine.debugGreedy(
            tokenIDs: prompt,
            maxTokens: limit,
            attentionStrategy: candidateStrategy,
            diagnosticCounters: candidateCounters,
            includeFinalStateProbe: false)
        switch candidateStrategy {
        case .productionFused:
            XCTAssertEqual(candidateCounters.explicitInvocations, 0)
        case .candidateHybrid:
            XCTAssertEqual(candidateCounters.fusedPrefillInvocations, 0)
            XCTAssertEqual(candidateCounters.explicitDecodeInvocations, 0)
        case .referenceCompatibleExplicit:
            break
        }

        let difference = Self.firstDifference(
            candidateRun.generatedTokenIDs, explicitRun.generatedTokenIDs)
        let tokenDifferences = zip(explicitRun.generatedTokenIDs, candidateRun.generatedTokenIDs)
            .filter { $0 != $1 }.count

        var membershipFailures = 0
        var comparisons = 0
        if let expected = explicitRun.router, let actual = candidateRun.router {
            let expectedRecords = Self.actualRouters(expected)
            let actualRecords = Self.actualRouters(actual)
            for key in expectedRecords.keys.sorted(by: {
                $0.layer != $1.layer ? $0.layer < $1.layer : $0.position < $1.position
            }) {
                guard let candidate = actualRecords[key] else { continue }
                comparisons += 1
                if Set(candidate.ids) != Set(expectedRecords[key]!.ids) {
                    membershipFailures += 1
                    print("[qwen-q218-long-router-mismatch] layer=\(key.layer) "
                        + "position=\(key.position) explicit=\(expectedRecords[key]!.ids) "
                        + "candidate=\(candidate.ids)")
                }
            }
        }

        let report = QwenStreamQ218LongControlReport(
            label: "NATIVE EXPLICIT CONTROL EXTENSION",
            independentCoverage: "none beyond the accepted 64-token Q2.16 golden",
            candidateStrategy: candidateStrategy.rawValue,
            candidateEligibleForPromotion: false,
            requestedTokens: limit,
            promptTokenCount: prompt.count,
            explicitGenerated: explicitRun.generatedTokenIDs.count,
            candidateGenerated: candidateRun.generatedTokenIDs.count,
            firstDifference: difference,
            tokenDifferences: tokenDifferences,
            greedyStreamIdentical: difference == nil,
            stopReasonExplicit: explicitRun.stopReason,
            stopReasonCandidate: candidateRun.stopReason,
            finalPositionExplicit: explicitRun.finalConsumedPosition,
            finalPositionCandidate: candidateRun.finalConsumedPosition,
            cachedDecodeCallsExplicit: explicitRun.cachedDecodeCallCount,
            cachedDecodeCallsCandidate: candidateRun.cachedDecodeCallCount,
            explicitFusedCalls: explicitCounters.fusedInvocations,
            explicitExplicitCalls: explicitCounters.explicitInvocations,
            candidateFusedCalls: candidateCounters.fusedInvocations,
            candidateExplicitCalls: candidateCounters.explicitInvocations,
            candidateFusedDecodeCalls: candidateCounters.fusedDecodeInvocations,
            candidateExplicitPrefillCalls: candidateCounters.explicitPrefillInvocations,
            routerComparisons: comparisons,
            routerMembershipFailures: membershipFailures,
            generatedTokenIDs: explicitRun.generatedTokenIDs)
        Self.write(report, to: "Qwen35-K8-Q2.18-long-explicit-control.json")
        print("[qwen-q218-long] candidate=\(candidateStrategy.rawValue) tokens=\(limit) "
            + "greedyIdentical=\(difference == nil) tokenDifferences=\(tokenDifferences) "
            + "firstDifference=\(difference.map(String.init) ?? "none") "
            + "stop=\(explicitRun.stopReason)/\(candidateRun.stopReason) "
            + "routers=\(comparisons) membershipFailures=\(membershipFailures) "
            + "explicitFused=\(explicitCounters.fusedInvocations) "
            + "candidateFused=\(candidateCounters.fusedInvocations)")
    }

    /// Counterbalanced performance A/B: A → B → B → A with a defined recovery
    /// between scored trials. Only correctness-classified strategies are
    /// scored; the fused-everywhere control is informational and can never win
    /// promotion here.
    func testOptInQ218PerformanceAB() async throws {
        guard Self.enabled("BEETCODE_QWEN35_Q218_PERF") else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q218_PERF=1 for the Q2.18 counterbalanced performance A/B.")
        }
        let strategies = (ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q218_PERF_STRATEGIES"] ?? "")
            .split(separator: ",")
            .compactMap { StreamQwen35AttentionStrategy(rawValue: String($0)) }
        // Hybrid A was rejected by the section-6 gate, so the informational
        // control here is the strategy that actually ships: fused everywhere.
        // It cannot win promotion no matter what these numbers say.
        let candidate = strategies.count == 2 ? strategies[1] : StreamQwen35AttentionStrategy.productionFused
        let baseline = strategies.count == 2 ? strategies[0] : StreamQwen35AttentionStrategy.referenceCompatibleExplicit
        let limit = Int(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q218_PERF_TOKENS"] ?? "128") ?? 128

        let engine = try await Self.loadEngine()
        defer { Task { await engine.unload() } }

        var trials: [QwenStreamQ218PerfTrial] = []
        for (index, strategy) in [baseline, candidate, candidate, baseline].enumerated() {
            try await Self.recover(engine)
            let trial = try await Self.scoredTrial(
                engine: engine, strategy: strategy, limit: limit, order: index)
            trials.append(trial)
            print("[qwen-q218-perf] order=\(index) strategy=\(trial.strategy) "
                + "prefill=\(String(format: "%.3f", trial.prefillSeconds))s "
                + "decode=\(String(format: "%.3f", trial.decodeSeconds))s "
                + "tok/s=\(String(format: "%.3f", trial.decodeTokensPerSecond)) "
                + "e2e=\(String(format: "%.3f", trial.endToEndSeconds))s "
                + "e2eTok/s=\(String(format: "%.3f", trial.endToEndTokensPerSecond)) "
                + "tokens=\(trial.generatedTokens) hits=\(trial.expertHits) misses=\(trial.expertMisses) "
                + "fused=\(trial.fusedCalls) explicit=\(trial.explicitCalls) "
                + "peak=\(trial.processPeakBytes)")
        }

        let baselineTrials = trials.filter { $0.strategy == baseline.rawValue }
        let candidateTrials = trials.filter { $0.strategy == candidate.rawValue }
        XCTAssertEqual(baselineTrials.count, 2)
        XCTAssertEqual(candidateTrials.count, 2)
        let medians = QwenStreamQ218PerfMedians(
            baseline: baseline.rawValue,
            candidate: candidate.rawValue,
            baselineDecodeTokensPerSecond: Self.median(baselineTrials.map(\.decodeTokensPerSecond)),
            candidateDecodeTokensPerSecond: Self.median(candidateTrials.map(\.decodeTokensPerSecond)),
            baselineEndToEndSeconds: Self.median(baselineTrials.map(\.endToEndSeconds)),
            candidateEndToEndSeconds: Self.median(candidateTrials.map(\.endToEndSeconds)),
            baselinePrefillSeconds: Self.median(baselineTrials.map(\.prefillSeconds)),
            candidatePrefillSeconds: Self.median(candidateTrials.map(\.prefillSeconds)),
            baselineDecodeSeconds: Self.median(baselineTrials.map(\.decodeSeconds)),
            candidateDecodeSeconds: Self.median(candidateTrials.map(\.decodeSeconds)),
            baselineProcessPeakBytes: Self.median(baselineTrials.map { Double($0.processPeakBytes) }),
            candidateProcessPeakBytes: Self.median(candidateTrials.map { Double($0.processPeakBytes) }),
            order: trials.map(\.strategy))
        let decodeGain = (medians.candidateDecodeTokensPerSecond
            / max(medians.baselineDecodeTokensPerSecond, 1e-9) - 1) * 100
        let endToEndGain = (medians.baselineEndToEndSeconds
            / max(medians.candidateEndToEndSeconds, 1e-9) - 1) * 100
        let memoryDelta = (medians.candidateProcessPeakBytes
            / max(medians.baselineProcessPeakBytes, 1) - 1) * 100
        // The suggested benefit gate: >=5% decode throughput or >=5%
        // meaningful end-to-end improvement, with no >10% unexplained memory
        // increase. Meeting it is necessary but never sufficient — correctness
        // eligibility is decided separately and recorded alongside.
        let candidateEligible = candidate == .referenceCompatibleExplicit
            || candidate == .candidateHybrid && Self.hybridAdmissible
        let meetsGate = (decodeGain >= 5 || endToEndGain >= 5) && memoryDelta <= 10
        Self.write(QwenStreamQ218PerfReport(
            medians: medians,
            trials: trials,
            baselineEligibleForPromotion: baseline == .referenceCompatibleExplicit
                || baseline == .candidateHybrid && Self.hybridAdmissible,
            candidateEligibleForPromotion: candidateEligible,
            decodeThroughputGainPercent: decodeGain,
            endToEndGainPercent: endToEndGain,
            peakMemoryDeltaPercent: memoryDelta,
            meetsBenefitGate: meetsGate),
            to: "Qwen35-K8-Q2.18-performance-ab.json")
        print("[qwen-q218-perf-medians] \(medians.baseline) vs \(medians.candidate) "
            + "decodeTok/s=\(String(format: "%.3f", medians.baselineDecodeTokensPerSecond))→"
            + "\(String(format: "%.3f", medians.candidateDecodeTokensPerSecond)) (\(String(format: "%+.2f", decodeGain))%) "
            + "e2eSeconds=\(String(format: "%.3f", medians.baselineEndToEndSeconds))→"
            + "\(String(format: "%.3f", medians.candidateEndToEndSeconds)) (\(String(format: "%+.2f", endToEndGain))%) "
            + "peakMemory=\(String(format: "%+.2f", memoryDelta))% "
            + "benefitGate=\(meetsGate) candidateEligible=\(candidateEligible)")
        if !candidateEligible {
            print("[qwen-q218-perf-medians] \(candidate.rawValue) is an INFORMATIONAL CONTROL only: "
                + "it failed the section-6 correctness gate and cannot win promotion on performance.")
        }
    }

    // MARK: - Support

    /// Section 6 measured 450 true K=8 membership differences for fused qLen=1
    /// decode, so hybrid A is not admissible and can never be promoted on the
    /// strength of a performance number. This constant keeps that decision
    /// visible at the point where performance is scored.
    private static let hybridAdmissible = false

    private static func enabled(_ key: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] == "1" || environment["BEETCODE_QWEN35_Q218_ALL"] == "1"
    }

    /// A deterministic prompt for the native control extension. It is longer
    /// than the golden prompt so the decode horizon genuinely extends past the
    /// independently validated range.
    private static let longControlPromptTokenIDs: [Int] = {
        // The frozen golden prompt plus a deterministic continuation drawn
        // from the golden's own generated stream, so the extension starts from
        // a real in-distribution context rather than a synthetic one.
        guard let fixture = try? loadGoldenFixture() else { return [] }
        return fixture.promptTokenIDs + Array(fixture.generatedTokenIDs.prefix(24))
    }()

    private struct GoldenFixture {
        let promptTokenIDs: [Int]
        let promptTokenCount: Int
        let generatedTokenIDs: [Int]
        let stopReason: String
        let finalConsumedPosition: Int
        let routers: [(layer: Int, position: Int, expertIDs: [Int])]
    }

    private static func loadGoldenFixture() throws -> GoldenFixture {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["BEETCODE_QWEN35_ORACLE_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip"
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("The accepted Q2.16 golden fixture is not present at \(path).")
        }
        if !source.hasDirectoryPath {
            let digest = SHA256.hash(data: try Data(contentsOf: source))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, goldenSHA256, "golden fixture archive hash drifted")
        }
        let root: URL
        var temporary: URL?
        if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = source
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen35-k8-q218-golden-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", source.path, "-d", directory.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw XCTSkip("Could not extract the accepted Q2.16 golden archive.")
            }
            temporary = directory
            root = directory
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)) as! [String: Any]
        XCTAssertEqual(manifest["fixtureFormatVersion"] as? String, goldenFormat)
        let semantics = manifest["semantics"] as? [String: Any]
        XCTAssertEqual(semantics?["routingK"] as? Int, 8)
        XCTAssertEqual(semantics?["expertCount"] as? Int, 256)
        XCTAssertEqual(semantics?["sharedExpert"] as? Bool, true)
        XCTAssertEqual(semantics?["thinking"] as? Bool, false)
        XCTAssertEqual(semantics?["attentionStrategy"] as? String, "explicit")
        XCTAssertEqual(semantics?["fullAttentionLayerIndices"] as? [Int], fullAttentionLayers)

        let entries = manifest["fixtures"] as? [String: Any]
        let primary = entries?["primary"] as? [String: Any]
        let fixturePath = primary?["path"] as? String ?? "fixtures/primary.json"
        let fixtureURL = root.appendingPathComponent(fixturePath)
        let data = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, primary?["sha256"] as? String, "golden primary fixture hash drifted")

        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let prompt = object["promptTokenIDs"] as? [Int] ?? []
        let generated = object["generatedTokenIDs"] as? [Int] ?? []
        XCTAssertEqual(prompt.count, object["promptTokenCount"] as? Int)
        XCTAssertEqual(generated.count, 64)
        XCTAssertEqual(object["stopReason"] as? String, "output_limit")

        var routers: [(Int, Int, [Int])] = []
        for checkpoint in object["checkpoints"] as? [[String: Any]] ?? [] {
            for router in checkpoint["router"] as? [[String: Any]] ?? [] {
                guard let layer = router["layer"] as? Int,
                      let position = router["position"] as? Int,
                      let ids = router["expertIDs"] as? [Int] else { continue }
                routers.append((layer, position, ids))
            }
        }
        XCTAssertFalse(routers.isEmpty, "golden fixture carries no router records")
        return GoldenFixture(
            promptTokenIDs: prompt,
            promptTokenCount: prompt.count,
            generatedTokenIDs: generated,
            stopReason: object["stopReason"] as? String ?? "",
            finalConsumedPosition: object["finalConsumedPosition"] as? Int ?? (prompt.count + generated.count),
            routers: routers.map { (layer: $0.0, position: $0.1, expertIDs: $0.2) })
    }

    private static func loadEngine() async throws -> QwenStreamingEngine {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("The pinned Qwen3.5 artifact is not installed on this host.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        return engine
    }

    /// Defined recovery between scored trials: unload, let the pool quiesce,
    /// and reload so neither trial benefits from a warm expert cache left by
    /// the other. The application pool starting-state policy is therefore the
    /// same for every scored trial.
    private static func recover(_ engine: QwenStreamingEngine) async throws {
        await engine.unload()
        _ = await engine.resetApplicationExpertPool()
        try Task.checkCancellation()
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
    }

    /// One scored trial on the real production streaming path. Nothing is
    /// tuned during measurement: the same prompt, output limit, K=8, pool,
    /// read concurrency, sampling, and Thinking setting are used throughout.
    private static func scoredTrial(
        engine: QwenStreamingEngine,
        strategy: StreamQwen35AttentionStrategy,
        limit: Int,
        order: Int
    ) async throws -> QwenStreamQ218PerfTrial {
        let counters = StreamQwen35AttentionDiagnosticCounters()
        await engine.debugSetAttentionStrategy(strategy, counters: counters)
        let prompt = "Write 30 numbered practical tips for improving software engineering productivity. Each tip must contain exactly two sentences and include a concrete example."
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
        let systemPrompt = PromptBuilder.systemPrompt(
            tools: [],
            workspace: Workspace(root: directory),
            outputStyle: .normal,
            contextWindowTokens: 4096,
            responseReserveTokens: 512,
            leanPrompt: true,
            chatOnly: true)
        var output = ""
        var firstChunk: ContinuousClock.Instant?
        let started = ContinuousClock.now
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(role: .system, content: systemPrompt),
                ChatTurn(role: .user, content: prompt),
            ],
            maxTokens: limit,
            temperature: 0) {
            if firstChunk == nil { firstChunk = ContinuousClock.now }
            output += chunk
        }
        let wallClock = started.duration(to: .now).qwenSeconds
        let stats = await engine.stats
        guard let diagnostics = stats.qwenStreaming else {
            throw XCTSkip("The Qwen engine did not publish diagnostics for trial \(order).")
        }
        XCTAssertEqual(diagnostics.generatedTokens, limit)
        XCTAssertEqual(diagnostics.attentionRequestedStrategy, strategy.rawValue)
        if let installed = diagnostics.attentionEffectiveStrategies.first {
            XCTAssertFalse(installed.isEmpty)
        }
        return QwenStreamQ218PerfTrial(
            order: order,
            strategy: strategy.rawValue,
            requestedStrategy: diagnostics.attentionRequestedStrategy ?? strategy.rawValue,
            effectiveStrategies: diagnostics.attentionEffectiveStrategies,
            promptTokens: diagnostics.promptTokens,
            generatedTokens: diagnostics.generatedTokens,
            stopReason: diagnostics.stopReason,
            decodeCalls: diagnostics.decodeCalls,
            prefillSeconds: diagnostics.prefillSeconds ?? 0,
            firstTokenSeconds: diagnostics.firstTokenSeconds ?? 0,
            firstAnswerSeconds: diagnostics.firstAnswerSeconds ?? 0,
            decodeSeconds: diagnostics.decodeSeconds ?? 0,
            decodeTokensPerSecond: diagnostics.decodeTokensPerSecond ?? 0,
            endToEndSeconds: diagnostics.totalSeconds ?? wallClock,
            endToEndTokensPerSecond: diagnostics.endToEndTokensPerSecond ?? 0,
            finalizationSeconds: diagnostics.finalizationSeconds ?? 0,
            unclassifiedSeconds: diagnostics.unclassifiedSeconds ?? 0,
            expertHits: diagnostics.expertHits,
            expertMisses: diagnostics.expertMisses,
            expertEvictions: diagnostics.expertEvictions,
            requestedFileBytes: diagnostics.requestedFileBytes,
            completedFileBytes: diagnostics.completedFileBytes,
            completedApplicationReads: diagnostics.completedExpertBundles,
            peakReads: diagnostics.peakReads,
            processPeakBytes: diagnostics.processPeakBytes ?? 0,
            mlxFootprintBytes: UInt64(max(0, diagnostics.footprintBytes ?? 0)),
            mlxActiveBytes: UInt64(max(0, diagnostics.mlxActiveBytes ?? 0)),
            mlxPeakBytes: UInt64(max(0, diagnostics.mlxPeakBytes ?? 0)),
            fusedCalls: counters.fusedInvocations,
            explicitCalls: counters.explicitInvocations,
            fusedPrefillCalls: counters.fusedPrefillInvocations,
            explicitPrefillCalls: counters.explicitPrefillInvocations,
            fusedDecodeCalls: counters.fusedDecodeInvocations,
            explicitDecodeCalls: counters.explicitDecodeInvocations,
            outputBytes: output.utf8.count,
            firstChunkSeconds: firstChunk.map { started.duration(to: $0).qwenSeconds } ?? 0)
    }

    private struct RouterKey: Hashable {
        let layer: Int
        let position: Int
    }

    private static func expectedRouters(_ fixture: GoldenFixture) -> [RouterKey: [Int]] {
        Dictionary(
            uniqueKeysWithValues: fixture.routers.map {
                (RouterKey(layer: $0.layer, position: $0.position), $0.expertIDs)
            })
    }

    private static func actualRouters(
        _ trace: QwenStreamRouterTraceSnapshot
    ) -> [RouterKey: (ids: [Int], scores: [Float], topLogits: [Float])] {
        var result: [RouterKey: (ids: [Int], scores: [Float], topLogits: [Float])] = [:]
        for record in trace.records {
            for index in record.positions.indices where index < record.expertIDs.count {
                result[RouterKey(layer: record.layer, position: record.positions[index])] = (
                    ids: record.expertIDs[index],
                    scores: record.scores[index],
                    topLogits: index < record.topLogits.count ? record.topLogits[index] : [])
            }
        }
        return result
    }

    private static func compareRouters(
        baseline: QwenStreamDecodeStrategyReplay,
        candidate: QwenStreamDecodeStrategyReplay
    ) -> QwenStreamDecodeRoutingReplay {
        guard let baselineTrace = baseline.router, let candidateTrace = candidate.router else {
            return QwenStreamDecodeRoutingReplay(
                candidateStrategy: candidate.strategy,
                promptTokenCount: candidate.promptTokenCount,
                forcedTokenCount: candidate.forcedTokenCount,
                candidateFusedDecodeCalls: candidate.fusedDecodeCalls,
                candidateExplicitDecodeCalls: candidate.explicitDecodeCalls,
                candidateFusedPrefillCalls: candidate.fusedPrefillCalls,
                candidateExplicitPrefillCalls: candidate.explicitPrefillCalls,
                baselineExplicitCalls: baseline.explicitCalls,
                baselineFusedCalls: baseline.fusedCalls,
                comparisons: 0, membershipFailures: 0, orderOnlyDifferences: 0,
                maxScoreRelL2: 0, maxScoreMaxAbs: 0, minKGap: 0,
                predictedTokenDifferences: 0, firstPredictedDifferenceIndex: nil,
                records: [])
        }
        XCTAssertTrue(baselineTrace.isComplete)
        XCTAssertTrue(candidateTrace.isComplete)
        let expected = actualRouters(baselineTrace)
        let actual = actualRouters(candidateTrace)
        var records = [QwenStreamDecodeRoutingComparison]()
        var membershipFailures = 0
        var orderOnly = 0
        for key in expected.keys.sorted(by: {
            $0.layer != $1.layer ? $0.layer < $1.layer : $0.position < $1.position
        }) {
            guard let candidateRecord = actual[key] else { continue }
            let expectedRecord = expected[key]!
            let identical = Set(candidateRecord.ids) == Set(expectedRecord.ids)
            if !identical { membershipFailures += 1 }
            if identical && candidateRecord.ids != expectedRecord.ids { orderOnly += 1 }
            let common = expectedRecord.ids.filter { candidateRecord.ids.contains($0) }
            let expectedByID = Dictionary(uniqueKeysWithValues: zip(expectedRecord.ids, expectedRecord.scores))
            let actualByID = Dictionary(uniqueKeysWithValues: zip(candidateRecord.ids, candidateRecord.scores))
            let topLogits = candidateRecord.topLogits
            records.append(QwenStreamDecodeRoutingComparison(
                layer: key.layer,
                position: key.position,
                expectedExpertIDs: expectedRecord.ids,
                actualExpertIDs: candidateRecord.ids,
                membershipIdentical: identical,
                orderIdentical: candidateRecord.ids == expectedRecord.ids,
                scoreRelL2: relativeL2(
                    common.compactMap { actualByID[$0] }, common.compactMap { expectedByID[$0] }),
                scoreMaxAbs: maxAbsDifference(
                    common.compactMap { actualByID[$0] }, common.compactMap { expectedByID[$0] }),
                kthScore: topLogits.count > 7 ? Double(topLogits[7]) : 0,
                kPlusOneScore: topLogits.count > 8 ? Double(topLogits[8]) : 0,
                kGap: topLogits.count > 8 ? Double(topLogits[7] - topLogits[8]) : 0))
        }
        let predictedDifference = firstDifference(
            candidate.predictedTokenIDs, baseline.predictedTokenIDs)
        let predictedDifferences = zip(baseline.predictedTokenIDs, candidate.predictedTokenIDs)
            .filter { $0 != $1 }.count
        return QwenStreamDecodeRoutingReplay(
            candidateStrategy: candidate.strategy,
            promptTokenCount: candidate.promptTokenCount,
            forcedTokenCount: candidate.forcedTokenCount,
            candidateFusedDecodeCalls: candidate.fusedDecodeCalls,
            candidateExplicitDecodeCalls: candidate.explicitDecodeCalls,
            candidateFusedPrefillCalls: candidate.fusedPrefillCalls,
            candidateExplicitPrefillCalls: candidate.explicitPrefillCalls,
            baselineExplicitCalls: baseline.explicitCalls,
            baselineFusedCalls: baseline.fusedCalls,
            comparisons: records.count,
            membershipFailures: membershipFailures,
            orderOnlyDifferences: orderOnly,
            maxScoreRelL2: records.map(\.scoreRelL2).max() ?? 0,
            maxScoreMaxAbs: records.map(\.scoreMaxAbs).max() ?? 0,
            minKGap: records.map(\.kGap).filter { $0 > 0 }.min() ?? 0,
            predictedTokenDifferences: predictedDifferences,
            firstPredictedDifferenceIndex: predictedDifference,
            records: records)
    }

    private static func compareBlocks(
        baseline: [QwenStreamAttentionBlockCapture],
        candidate: [QwenStreamAttentionBlockCapture]
    ) -> [QwenStreamQ218BlockComparison] {
        let expected = Dictionary(uniqueKeysWithValues: baseline.map { ($0.decodeIndex, $0) })
        return candidate.compactMap { block in
            guard let reference = expected[block.decodeIndex] else { return nil }
            XCTAssertEqual(block.layer, reference.layer)
            XCTAssertEqual(block.position, reference.position)
            return QwenStreamQ218BlockComparison(
                decodeIndex: block.decodeIndex,
                layer: block.layer,
                position: block.position,
                baselineStrategy: reference.effectiveStrategy,
                candidateStrategy: block.effectiveStrategy,
                layerInputByteIdentical: identical(reference.layerInput, block.layerInput),
                sdpaByteIdentical: identical(reference.sdpaOutput, block.sdpaOutput),
                attentionValuesByteIdentical: identical(reference.attentionValues, block.attentionValues),
                gatedValuesByteIdentical: identical(reference.gatedValues, block.gatedValues),
                oProjByteIdentical: identical(reference.oProjOutput, block.oProjOutput),
                blockOutputByteIdentical: identical(reference.blockOutput, block.blockOutput),
                sdpaRelL2: relativeL2(reference.sdpaOutput.sample, block.sdpaOutput.sample),
                attentionValuesRelL2: relativeL2(
                    reference.attentionValues.sample, block.attentionValues.sample),
                gatedValuesRelL2: relativeL2(reference.gatedValues.sample, block.gatedValues.sample),
                oProjRelL2: relativeL2(reference.oProjOutput.sample, block.oProjOutput.sample),
                blockRelL2: relativeL2(reference.blockOutput.sample, block.blockOutput.sample),
                blockMaxAbs: maxAbsDifference(reference.blockOutput.sample, block.blockOutput.sample))
        }
    }

    private static func identical(_ lhs: QwenStreamArraySummary, _ rhs: QwenStreamArraySummary) -> Bool {
        guard lhs.shape == rhs.shape, lhs.dtype == rhs.dtype else { return false }
        if let left = lhs.rawBFloat16Bits, let right = rhs.rawBFloat16Bits {
            return left == right
        }
        if let left = lhs.fullValues, let right = rhs.fullValues {
            return left.map(\.bitPattern) == right.map(\.bitPattern)
        }
        return lhs.sample.map(\.bitPattern) == rhs.sample.map(\.bitPattern)
            && lhs.tailSample.map(\.bitPattern) == rhs.tailSample.map(\.bitPattern)
    }

    private static func relativeL2(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        var numerator = 0.0
        var denominator = 0.0
        for (left, right) in zip(lhs, rhs) {
            let difference = Double(left) - Double(right)
            numerator += difference * difference
            denominator += Double(right) * Double(right)
        }
        return numerator.squareRoot() / max(denominator.squareRoot(), 1e-12)
    }

    private static func maxAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        return zip(lhs, rhs).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    private static func firstDifference(_ lhs: [Int], _ rhs: [Int]) -> Int? {
        for index in 0 ..< min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return index
        }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func logMatrix(_ matrix: QwenStreamSDPACompatibilityMatrix) {
        for entry in matrix.entries.sorted(by: {
            $0.phase == $1.phase ? ($0.layer == $1.layer ? $0.position < $1.position : $0.layer < $1.layer) : $0.phase < $1.phase
        }) {
            print("[qwen-q218-sdpa] \(entry.phase) layer=\(entry.layer) group=\(entry.group) "
                + "qLen=\(entry.queryLength) kvLen=\(entry.keyLength) mask=\(entry.productionMaskMode) "
                + "byteIdentical=\(entry.byteIdenticalBF16) relL2=\(String(format: "%.3e", entry.relL2)) "
                + "maxAbs=\(String(format: "%.6f", entry.maxAbs)) worst=\(entry.worstCoordinate) "
                + "fused=\(entry.worstValueFused) explicit=\(entry.worstValueExplicit)")
        }
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        let directory = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q218_REPORT_DIR"]
            ?? "/Users/m/Downloads"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }.joined()
            print("[qwen-q218-report] path=\(url.path) sha256=\(digest)")
        } catch {
            print("[qwen-q218-report] failed to write \(url.path): \(error)")
        }
    }
}

// MARK: - Q2.18 report schemas

private extension Array where Element == Int {
    func unique() -> [Int] { Array(Set(self)).sorted() }
}

struct QwenStreamQ218BlockComparison: Codable, Sendable, Equatable {
    let decodeIndex: Int
    let layer: Int
    let position: Int
    let baselineStrategy: String
    let candidateStrategy: String
    let layerInputByteIdentical: Bool
    let sdpaByteIdentical: Bool
    let attentionValuesByteIdentical: Bool
    let gatedValuesByteIdentical: Bool
    let oProjByteIdentical: Bool
    let blockOutputByteIdentical: Bool
    let sdpaRelL2: Double
    let attentionValuesRelL2: Double
    let gatedValuesRelL2: Double
    let oProjRelL2: Double
    let blockRelL2: Double
    let blockMaxAbs: Double
}

struct QwenStreamQ218BlockComparisonReport: Codable, Sendable, Equatable {
    let entries: [QwenStreamQ218BlockComparison]
}

/// The section-6 classification of the "fused qLen=1 decode is clean"
/// hypothesis, and the promotion decision that follows from it mechanically.
struct QwenStreamQ218QLen1Verdict: Codable, Sendable, Equatable {
    let hypothesisConfirmed: Bool
    let gate: String
    let baselineGoldenComparisons: Int
    let baselineGoldenMembershipFailures: Int
    let comparisons: Int
    let membershipFailures: Int
    let orderOnlyDifferences: Int
    let maxScoreRelL2: Double
    let maxScoreMaxAbs: Double
    let minKGap: Double
    let predictedTokenDifferences: Int
    let firstPredictedDifferenceIndex: Int?
    let blockEntries: Int
    let blockOutputByteIdentical: Int
    let sdpaByteIdentical: Int
    let maxBlockRelL2: Double
    let maxBlockMaxAbs: Double
    let promotion: String
    let routing: QwenStreamDecodeRoutingReplay
}

struct QwenStreamQ218GoldenReport: Codable, Sendable, Equatable {
    let strategy: String
    let generatedTokens: Int
    let expectedTokens: Int
    let firstDifference: Int?
    let greedyStreamIdentical: Bool
    let stopReason: String
    let stopReasonIdentical: Bool
    let finalConsumedPosition: Int
    let prefillCallCount: Int
    let cachedDecodeCallCount: Int
    let requestedStrategies: [String]
    let effectiveStrategies: [String]
    let fusedCalls: Int
    let explicitCalls: Int
    let fusedPrefillCalls: Int
    let explicitPrefillCalls: Int
    let fusedDecodeCalls: Int
    let explicitDecodeCalls: Int
    let routerComparisons: Int
    let routerMembershipFailures: Int
}

/// Records that a rejected candidate's greedy-stream agreement is never
/// allowed to waive its routing divergence.
struct QwenStreamQ218GoldenClassification: Codable, Sendable, Equatable {
    let explicit: QwenStreamQ218GoldenReport
    let hybridRejected: QwenStreamQ218GoldenReport
    let hybridGreedyStreamMatchesExplicit: Bool
    let hybridRouterMembershipFailures: Int
    let waiverAllowed: Bool
    let note: String
}

struct QwenStreamQ218LongControlReport: Codable, Sendable, Equatable {
    let label: String
    let independentCoverage: String
    let candidateStrategy: String
    /// Always false in this phase: a fused run cannot win promotion, and the
    /// rejected hybrid is not a candidate at all.
    let candidateEligibleForPromotion: Bool
    let requestedTokens: Int
    let promptTokenCount: Int
    let explicitGenerated: Int
    let candidateGenerated: Int
    let firstDifference: Int?
    let tokenDifferences: Int
    let greedyStreamIdentical: Bool
    let stopReasonExplicit: String
    let stopReasonCandidate: String
    let finalPositionExplicit: Int
    let finalPositionCandidate: Int
    let cachedDecodeCallsExplicit: Int
    let cachedDecodeCallsCandidate: Int
    let explicitFusedCalls: Int
    let explicitExplicitCalls: Int
    let candidateFusedCalls: Int
    let candidateExplicitCalls: Int
    let candidateFusedDecodeCalls: Int
    let candidateExplicitPrefillCalls: Int
    let routerComparisons: Int
    let routerMembershipFailures: Int
    let generatedTokenIDs: [Int]
}

struct QwenStreamQ218PerfTrial: Codable, Sendable, Equatable {
    let order: Int
    let strategy: String
    let requestedStrategy: String
    let effectiveStrategies: [String]
    let promptTokens: Int
    let generatedTokens: Int
    let stopReason: String
    let decodeCalls: Int
    let prefillSeconds: Double
    let firstTokenSeconds: Double
    let firstAnswerSeconds: Double
    let decodeSeconds: Double
    let decodeTokensPerSecond: Double
    let endToEndSeconds: Double
    let endToEndTokensPerSecond: Double
    let finalizationSeconds: Double
    let unclassifiedSeconds: Double
    let expertHits: Int
    let expertMisses: Int
    let expertEvictions: Int
    let requestedFileBytes: UInt64
    let completedFileBytes: UInt64
    let completedApplicationReads: Int
    let peakReads: Int
    let processPeakBytes: UInt64
    let mlxFootprintBytes: UInt64
    let mlxActiveBytes: UInt64
    let mlxPeakBytes: UInt64
    let fusedCalls: Int
    let explicitCalls: Int
    let fusedPrefillCalls: Int
    let explicitPrefillCalls: Int
    let fusedDecodeCalls: Int
    let explicitDecodeCalls: Int
    let outputBytes: Int
    let firstChunkSeconds: Double
}

struct QwenStreamQ218PerfMedians: Codable, Sendable, Equatable {
    let baseline: String
    let candidate: String
    let baselineDecodeTokensPerSecond: Double
    let candidateDecodeTokensPerSecond: Double
    let baselineEndToEndSeconds: Double
    let candidateEndToEndSeconds: Double
    let baselinePrefillSeconds: Double
    let candidatePrefillSeconds: Double
    let baselineDecodeSeconds: Double
    let candidateDecodeSeconds: Double
    let baselineProcessPeakBytes: Double
    let candidateProcessPeakBytes: Double
    let order: [String]
}

struct QwenStreamQ218PerfReport: Codable, Sendable, Equatable {
    let medians: QwenStreamQ218PerfMedians
    let trials: [QwenStreamQ218PerfTrial]
    /// The correctness classification decided earlier in the phase. Performance
    /// can only choose between strategies that already passed correctness, so
    /// this field records which of the two scored arms was even eligible.
    let baselineEligibleForPromotion: Bool
    let candidateEligibleForPromotion: Bool
    let decodeThroughputGainPercent: Double
    let endToEndGainPercent: Double
    let peakMemoryDeltaPercent: Double
    let meetsBenefitGate: Bool
}
