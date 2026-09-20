import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import BeetCode

/// Q2.9 target-host localization. The test is opt-in because it loads the
/// installed 35B checkpoint and executes the real native cached path through
/// the single disputed layer-19/position-46 boundary.
final class QwenStreamQ29LocalizationTests: XCTestCase {
    private struct Summary: Decodable {
        let shape: [Int]
        let dtype: String
        let values: [Float]?
        let fullValues: [Float]?
        let rawBFloat16Bits: [UInt16]?
        let rawUInt16Bits: [UInt16]?
        let rawUInt32Bits: [UInt32]?
    }

    private struct Side: Decodable {
        let routerInput: Summary
        let routerLogits: Summary
        let selectorScores: Summary
        let selectedExpertIDs: [Int]
        let selectedNormalizedScores: [Float]
    }

    private struct History: Decodable {
        let promptTokenIDs: [Int]
        let promptTokenCount: Int
        let promptSHA256: String
        let generatedTokenIDs: [Int]
        let generatedTokenIDsConsumedBeforePosition: [Int]
        let targetInputTokenID: Int
        let targetDecodeStep: Int
        let absolutePosition: Int
        let phase: String
        let prefillGroupSize: Int
        let cacheBoundary: CacheBoundary
    }

    private struct CacheBoundary: Decodable {
        let positionBefore: Int
        let positionAfter: Int
        let promptPrefillComplete: Bool
        let generatedTokensConsumedBeforePosition: Int
    }

    private struct Fixture: Decodable {
        let fixtureFormatVersion: String
        let artifact: Artifact
        let layer: Int
        let position: Int
        let routingK: Int
        let history: History
        let reference: Side
        let native: Side
    }

    private struct Artifact: Decodable {
        let repo: String
        let revision: String
        let inventorySHA256: String
    }

    private struct ProjectionRecord: Codable {
        let inputSide: String
        let implementation: String
        let logits: [Float]
        let sha256: String
    }

    private struct DiagnosticOutput: Codable {
        let fixtureSHA256: String
        let projections: [ProjectionRecord]
        let native: QwenStreamDebugTeacherForcedComponentsRun
    }

    private struct OracleCache: Decodable {
        let state: [Summary]
    }

    private struct OracleLayer: Decodable {
        let layer: Int
        let components: QwenStreamDebugLayerComponents?
        let cacheBefore: OracleCache?
    }

    private struct OracleOutput: Decodable {
        let capturedLayers: [OracleLayer]
    }

    // Q2.11's compact Python package stores raw words instead of decimal
    // tensors.  UInt32 is used for the JSON field so the same decoder can
    // represent BF16/Float16 words and Float32 bit patterns.
    private struct Q211PythonArtifact: Codable {
        let repo: String
        let revision: String
        let inventorySHA256: String
    }

    private struct Q211PythonArray: Decodable {
        let name: String
        let shape: [Int]
        let dtype: String
        let rawWords: [UInt32]
        let checksum: String
    }

    private struct Q211PythonFixture: Decodable {
        let fixtureFormatVersion: String
        let artifact: Q211PythonArtifact
        let layer: Int
        let prefillGroup: Int
        let queryPositions: [Int]
        let scale: Float
        let scaleExpression: String
        let gqa: Q211GQA
        let mask: Q211Mask
        let operationOrder: [String]
        let arrays: [Q211PythonArray]
    }

    private struct Q211GQA: Decodable {
        let queryHeads: Int
        let kvHeads: Int
        let repeatCount: Int
        let axis: Int
        let operation: String
    }

    private struct Q211Mask: Decodable {
        let dtype: String
        let shape: [Int]
        let validKeyRanges: [Int]
        let rowAlignment: String
    }

    private struct Q211Comparison: Codable {
        let name: String
        let shape: [Int]
        let expectedDType: String
        let candidateDType: String
        let bitExact: Bool
        let expectedChecksum: String
        let candidateChecksum: String
        let relL2: Double
        let maxAbs: Float
        let worstIndex: Int?
        let candidateValueAtWorst: Float?
        let expectedValueAtWorst: Float?
    }

    private struct Q211OracleOutputComparison: Codable {
        let bitExact: Bool
        let oracleChecksum: String
        let candidateChecksum: String
        let relL2: Double
        let maxAbs: Float
        let candidateShape: [Int]
        let oracleShape: [Int]
    }

    private struct Q211SwiftExport: Codable {
        let fixtureFormatVersion: String
        let artifact: Q211PythonArtifact
        let nativeCandidate: String
        let operationOrder: [String]
        let arrays: [String: QwenStreamArraySummary]
        let comparisons: [Q211Comparison]
        let firstDifference: String?
        let oracleOutput: Q211OracleOutputComparison
        let notes: [String]
    }

    private struct Q212BoundaryComparison: Codable {
        let name: String
        let source: String
        let candidateShape: [Int]
        let candidateDType: String
        let referenceShape: [Int]?
        let referenceDType: String?
        let candidateChecksum: String?
        let referenceChecksum: String?
        let bitExact: Bool?
        let relL2: Double?
        let maxAbs: Float?
        let note: String?
    }

    private struct Q212StrategyRecord: Codable {
        let requested: String
        let effective: String
        let layer: Int?
        let group: Int?
        let explicitInvocations: Int
        let fusedInvocations: Int
        let sentinelApplied: Bool
    }

    private struct Q212LegacyComparison: Codable {
        let candidateChecksum: String
        let referenceChecksum: String
        let shape: [Int]
        let dtype: String
        let relL2: Double
        let maxAbs: Float
    }

    private struct Q212Report: Codable {
        let fixtureFormatVersion: String
        let artifact: Q211PythonArtifact
        let pythonFixtureSHA256: String
        let sourceFixtureSHA256: String
        let historyFixtureSHA256: String
        let layer: Int
        let prefillGroup: Int
        let queryPositions: [Int]
        let boundaryDefinitions: [String]
        let strategy: Q212StrategyRecord
        let sentinelStrategy: Q212StrategyRecord
        let q211MatchedIntermediates: [String]
        let legacyT9Comparison: Q212LegacyComparison
        let supportingInputs: [Q212BoundaryComparison]
        let boundaries: [Q212BoundaryComparison]
        let firstComparableMismatch: String?
        let conclusion: String
        let notes: [String]
    }

    private struct Q213Authority: Decodable {
        let name: String
        let producer: String
        let mlx: String
        let python: String
        let device: String
        let recurrentState: String
    }

    private struct Q213CorrectedFixture: Decodable {
        let fixtureFormatVersion: String
        let artifact: Q211PythonArtifact
        let authority: Q213Authority
        let layer: Int
        let prefillGroup: Int
        let queryPositions: [Int]
        let promptTokenCount: Int
        let promptPrefixSHA256: String
        let scale: Float
        let scaleBits: UInt32
        let scaleExpression: String
        let lineage: [String: String]
        let boundaries: [String: Summary]
    }

    private struct Q213NativeReport: Codable {
        let fixtureFormatVersion: String
        let correctedFixtureSHA256: String
        let strategy: Q212StrategyRecord
        let comparisons: [Q212BoundaryComparison]
        let firstMismatch: String?
        let conclusion: String
    }

    private struct Q214CoverageReport: Codable {
        let fixtureFormatVersion: String
        let attentionStrategy: String
        let fullAttentionLayerIndices: [Int]
        let prefillCallCount: Int
        let cachedDecodeCallCount: Int
        let explicitInvocations: Int
        let fusedInvocations: Int
        let generatedTokenIDs: [Int]
        let stopReason: String
        let finalConsumedPosition: Int
        let conclusion: String
    }

    private let expectedFixtureSHA256 = "0386926d2fa71a3880d577244bc1d59f5ba45a851911ad516de96bf108c39cfd"

    func testOptInQ29RouterInputReplayAndTargetComponents() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29=1 for the bounded Q2.9 localization run.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let fixtureURL = URL(fileURLWithPath: path)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureSHA = SHA256.hash(data: fixtureData)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fixtureSHA, expectedFixtureSHA256)
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)

        XCTAssertEqual(fixture.fixtureFormatVersion, "qwen35-k8-q29-router-input-v1")
        XCTAssertEqual(fixture.artifact.repo, QwenStreamArtifact.repo)
        XCTAssertEqual(fixture.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(fixture.artifact.inventorySHA256,
                       "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592")
        XCTAssertEqual(fixture.layer, 19)
        XCTAssertEqual(fixture.position, 46)
        XCTAssertEqual(fixture.routingK, 8)

        // Same-history gate: position 46 is the eighth teacher-forced decode
        // token after a 39-token prompt, not a prefill row.
        XCTAssertEqual(fixture.history.promptTokenIDs.count, fixture.history.promptTokenCount)
        XCTAssertEqual(fixture.history.promptTokenCount, 39)
        XCTAssertEqual(fixture.history.generatedTokenIDsConsumedBeforePosition.count, 7)
        XCTAssertEqual(
            fixture.history.generatedTokenIDsConsumedBeforePosition,
            Array(fixture.history.generatedTokenIDs.prefix(7)))
        XCTAssertEqual(fixture.history.targetInputTokenID, fixture.history.generatedTokenIDs[7])
        XCTAssertEqual(fixture.history.targetDecodeStep, 8)
        XCTAssertEqual(fixture.history.absolutePosition, 46)
        XCTAssertEqual(fixture.history.phase, "cached_decode")
        XCTAssertEqual(fixture.history.prefillGroupSize, 4)
        XCTAssertEqual(fixture.history.cacheBoundary.positionBefore, 46)
        XCTAssertEqual(fixture.history.cacheBoundary.positionAfter, 47)
        XCTAssertTrue(fixture.history.cacheBoundary.promptPrefillComplete)
        XCTAssertEqual(fixture.history.cacheBoundary.generatedTokensConsumedBeforePosition, 7)

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }

        let referenceInput = rawFloatValues(fixture.reference.routerInput)
        let nativeInput = rawFloatValues(fixture.native.routerInput)
        XCTAssertEqual(referenceInput.count, 2048)
        XCTAssertEqual(nativeInput.count, 2048)

        // 2x2 replay. The two captured reference cells are independent
        // Python/MLX outputs; the two native cells use the exact production
        // quantized gate reader. Equality of each same-input pair classifies
        // the defect as upstream router-input drift.
        let nativeOnReferenceInput = try QwenStreamReferenceAudit.routerGateProjection(
            directory: directory,
            layer: fixture.layer,
            input: referenceInput,
            shape: [1, referenceInput.count])
        let nativeOnNativeInput = try QwenStreamReferenceAudit.routerGateProjection(
            directory: directory,
            layer: fixture.layer,
            input: nativeInput,
            shape: [1, nativeInput.count])
        let referenceOnReferenceInput = rawFloatValues(fixture.reference.routerLogits)
        let referenceOnNativeInput = rawFloatValues(fixture.native.routerLogits)
        XCTAssertEqual(nativeOnReferenceInput, referenceOnReferenceInput,
                       "native/reference router projection differs for the same reference input")
        XCTAssertEqual(nativeOnNativeInput, referenceOnNativeInput,
                       "native/reference router projection differs for the same native input")

        let records = [
            ProjectionRecord(
                inputSide: "reference",
                implementation: "reference-mlx-captured",
                logits: referenceOnReferenceInput,
                sha256: floatSHA256(referenceOnReferenceInput)),
            ProjectionRecord(
                inputSide: "reference",
                implementation: "native-quantized-gate",
                logits: nativeOnReferenceInput,
                sha256: floatSHA256(nativeOnReferenceInput)),
            ProjectionRecord(
                inputSide: "native",
                implementation: "reference-mlx-captured",
                logits: referenceOnNativeInput,
                sha256: floatSHA256(referenceOnNativeInput)),
            ProjectionRecord(
                inputSide: "native",
                implementation: "native-quantized-gate",
                logits: nativeOnNativeInput,
                sha256: floatSHA256(nativeOnNativeInput)),
        ]

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        // Capture every layer through the disputed prefix. The earlier
        // sampled set (0, 9, 14, 17, 18, 19) proved that drift was already
        // present by layer 9, but cannot identify the first operation that
        // changes. This remains a diagnostic-only run; production inference
        // never retains these boundaries.
        let localizationLayers = Array(0...19)
        let run = try await engine.debugTeacherForcedLayerComponents(
            tokenIDs: fixture.history.promptTokenIDs,
            forcedTokenIDs: Array(fixture.history.generatedTokenIDs.prefix(8)),
            targetLayer: fixture.layer,
            targetPosition: fixture.position,
            captureLayers: localizationLayers,
            captureFullValues: true)

        XCTAssertEqual(run.promptTokenIDs, fixture.history.promptTokenIDs)
        XCTAssertEqual(run.forcedTokenIDs, Array(fixture.history.generatedTokenIDs.prefix(8)))
        XCTAssertEqual(run.targetLayer, fixture.layer)
        XCTAssertEqual(run.targetPosition, fixture.position)
        XCTAssertEqual(run.targetInputTokenID, fixture.history.targetInputTokenID)
        XCTAssertEqual(run.prefillCallCount, 10)
        XCTAssertEqual(run.cachedDecodeCallCount, 8)
        XCTAssertEqual(run.capturedLayers.map(\.layer), localizationLayers)
        XCTAssertEqual(run.target.input.shape, [1, 1, 2048])
        XCTAssertEqual(run.target.components.routerInput.shape, [1, 1, 2048])
        XCTAssertEqual(run.target.components.routerLogits.shape, [1, 1, 256])

        let targetInputBits = try XCTUnwrap(
            run.target.components.routerInput.rawBFloat16Bits ?? run.target.components.routerInput.rawUInt16Bits)
        let expectedInputBits = try XCTUnwrap(
            fixture.native.routerInput.rawBFloat16Bits ?? fixture.native.routerInput.rawUInt16Bits)
        XCTAssertEqual(targetInputBits, expectedInputBits,
                       "native target router input did not reproduce the frozen Q2.8 input")
        let targetLogitBits = try XCTUnwrap(
            run.target.components.routerLogits.rawBFloat16Bits ?? run.target.components.routerLogits.rawUInt16Bits)
        let expectedLogitBits = try XCTUnwrap(
            fixture.native.routerLogits.rawBFloat16Bits ?? fixture.native.routerLogits.rawUInt16Bits)
        XCTAssertEqual(targetLogitBits, expectedLogitBits,
                       "native target router logits did not reproduce the frozen Q2.8 logits")
        // Layer 19 is the fifth interval boundary (19 + 1 divisible by 4),
        // so its target state is the full-attention KV cache.
        XCTAssertEqual(run.target.cacheBefore.kind, "FullAttention/KVCache")
        XCTAssertEqual(run.target.cacheAfter.kind, "FullAttention/KVCache")

        let output = DiagnosticOutput(
            fixtureSHA256: fixtureSHA,
            projections: records,
            native: run)
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(output).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("[qwen-q29-output] path=\(outputPath) bytes=\(try Data(contentsOf: URL(fileURLWithPath: outputPath)).count)")
        }
        print("[qwen-q29-2x2] refInputNative=exact nativeInputNative=exact normalInputRelL2=\(relativeL2(referenceInput, nativeInput)) target=layer\(fixture.layer)/position\(fixture.position) phase=\(fixture.history.phase)")
    }

    /// Focused decomposition for the first layer boundary that differs in the
    /// all-layer output replay. This is deliberately separate from the router
    /// probe: it captures layer 8's linear-attention and MoE components while
    /// preserving the same teacher-forced history and cache schedule.
    func testOptInQ29Layer8Components() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_L8"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_L8=1 for the focused layer-8 localization run.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixtureSHA = SHA256.hash(data: fixtureData)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fixtureSHA, expectedFixtureSHA256)
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let localizationLayers = Array(0...8)
        let run = try await engine.debugTeacherForcedLayerComponents(
            tokenIDs: fixture.history.promptTokenIDs,
            forcedTokenIDs: Array(fixture.history.generatedTokenIDs.prefix(8)),
            targetLayer: 8,
            targetPosition: fixture.position,
            captureLayers: localizationLayers,
            captureFullValues: true)

        XCTAssertEqual(run.promptTokenIDs, fixture.history.promptTokenIDs)
        XCTAssertEqual(run.forcedTokenIDs, Array(fixture.history.generatedTokenIDs.prefix(8)))
        XCTAssertEqual(run.targetLayer, 8)
        XCTAssertEqual(run.targetPosition, fixture.position)
        XCTAssertEqual(run.targetInputTokenID, fixture.history.targetInputTokenID)
        XCTAssertEqual(run.prefillCallCount, 10)
        XCTAssertEqual(run.cachedDecodeCallCount, 8)
        XCTAssertEqual(run.capturedLayers.map(\.layer), localizationLayers)
        XCTAssertEqual(run.target.kind, "GatedDeltaNet/MambaCache")
        XCTAssertEqual(run.target.components.attentionInput.shape, [1, 1, 2048])
        XCTAssertEqual(run.target.components.routerInput.shape, [1, 1, 2048])
        XCTAssertEqual(run.target.components.routerLogits.shape, [1, 1, 256])

        let output = DiagnosticOutput(fixtureSHA256: fixtureSHA, projections: [], native: run)
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_L8_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(output).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("[qwen-q29-l8-output] path=\(outputPath) bytes=\(try Data(contentsOf: URL(fileURLWithPath: outputPath)).count)")
        }
        print("[qwen-q29-l8] layer=8 position=\(fixture.position) captured=\(localizationLayers.count) phase=\(fixture.history.phase)")
    }

    /// Same-input replay for the first differing operation. The reference
    /// q/k/v/projection tensors and incoming FP32 state come from the
    /// independent layer-8 worker; only the model-owned A_log/dt_bias are
    /// loaded from the installed native artifact.
    func testOptInQ29Layer8GatedDeltaReplay() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_GATED"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_GATED=1 for the isolated GatedDelta replay.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_L8_REFERENCE"]
            ?? "/tmp/qwen35-k8-q29-reference-l8-cache-v1/router-raw.json"
        let oracle = try JSONDecoder().decode(
            OracleOutput.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let layer = try XCTUnwrap(oracle.capturedLayers.first(where: { $0.layer == 8 }))
        let components = try XCTUnwrap(layer.components)
        let projections = try XCTUnwrap(components.linearProjections)
        let attention = try XCTUnwrap(components.linearAttention)
        let cache = try XCTUnwrap(layer.cacheBefore)
        XCTAssertEqual(cache.state.count, 2)

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let replay = try await engine.debugGatedDeltaReplay(
            layer: 8,
            q: rawFloatValues(attention.qNormed), qShape: attention.qNormed.shape,
            k: rawFloatValues(attention.kNormed), kShape: attention.kNormed.shape,
            v: rawFloatValues(attention.v), vShape: attention.v.shape,
            a: rawFloatValues(projections.a), aShape: projections.a.shape,
            b: rawFloatValues(projections.b), bShape: projections.b.shape,
            state: rawFloatValues(cache.state[1]), stateShape: cache.state[1].shape)
        let expected = rawFloatValues(attention.gatedOutput)
        let actual = rawFloatValues(replay.output)
        let rel = relativeL2(expected, actual)
        var maxAbs: Float = 0
        for (lhs, rhs) in zip(expected, actual) {
            maxAbs = max(maxAbs, abs(lhs - rhs))
        }
        XCTAssertEqual(expected.count, actual.count)
        XCTAssertLessThan(rel, 1e-5,
                          "native GatedDelta differs for the same reference state/input")
        print("[qwen-q29-gated] layer=8 sameState relL2=\(rel) maxAbs=\(maxAbs) referenceState=\(cache.state[1].shape)")
    }

    /// Captures the ordinary bounded cache samples after each forced decode
    /// token. Comparing these checkpoints with the independent worker results
    /// identifies the first time at which layer-8 recurrent state history
    /// diverges, without retaining a multi-step hidden-state trace.
    func testOptInQ29Layer8StateCheckpoints() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_STATES"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_STATES=1 for state-history checkpoints.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }
        let forced = Array(fixture.history.generatedTokenIDs.prefix(8))
        // -1 records the cache immediately after prompt prefill.  The
        // subsequent checkpoints are after each forced cached-decode token.
        let checkpointSteps = [-1] + Array(1...8)
        let run = try await engine.debugTeacherForced(
            tokenIDs: fixture.history.promptTokenIDs,
            forcedTokenIDs: forced,
            checkpointSteps: checkpointSteps)
        XCTAssertEqual(run.promptTokenIDs, fixture.history.promptTokenIDs)
        XCTAssertEqual(run.forcedTokenIDs, forced)
        XCTAssertEqual(run.checkpoints.map(\.decodeStep), checkpointSteps)
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_STATES_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(run).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("[qwen-q29-states-output] path=\(outputPath) bytes=\(try Data(contentsOf: URL(fileURLWithPath: outputPath)).count)")
        }
        for checkpoint in run.checkpoints {
            if let layer = checkpoint.cache.layers.first(where: { $0.layer == 8 }) {
                print("[qwen-q29-state] step=\(checkpoint.decodeStep) layer=8 stateSamples=\(layer.state.count)")
            }
        }
    }

    /// Captures each four-token prefill boundary for layer 8.  This is kept
    /// separate from the decode checkpoints so an early recurrent-state drift
    /// cannot be hidden by the later teacher-forced history.
    func testOptInQ29Layer8PrefillStateBoundaries() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_PREFILL"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_PREFILL=1 for prefill state boundaries.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }
        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: fixture.history.promptTokenIDs,
            // The boundary helper also records the embedding boundary as its
            // stable fixture root; layer 8 is the state under investigation.
            boundaryLayers: Array(0...8),
            captureFullComponents: false)
        XCTAssertEqual(native.promptTokenIDs, fixture.history.promptTokenIDs)
        XCTAssertEqual(native.prefillGroupSize, fixture.history.prefillGroupSize)
        XCTAssertEqual(native.groups.count, (fixture.history.promptTokenCount + 3) / 4)
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_PREFILL_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(native).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("[qwen-q29-prefill-output] path=\(outputPath) bytes=\(try Data(contentsOf: URL(fileURLWithPath: outputPath)).count)")
        }
        for group in native.groups {
            if let layer = group.layers.first(where: { $0.layer == 8 }) {
                print("[qwen-q29-prefill-state] group=\(group.groupIndex) stateSamples=\(layer.cache.state.count)")
            }
        }
    }

    /// Retains full bounded component arrays through the first material
    /// prefill divergence (the first seven four-token groups, layers 0...7).
    /// This is an opt-in diagnostic fixture; it is never part of normal chat.
    func testOptInQ29Layer7PrefillComponents() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_PREFILL_COMPONENTS"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_PREFILL_COMPONENTS=1 for component localization.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_FIXTURE"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let prefixTokens = Array(fixture.history.promptTokenIDs.prefix(28))
        XCTAssertEqual(prefixTokens.count, 28)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }
        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: prefixTokens,
            boundaryLayers: Array(0...7),
            captureFullComponents: true,
            fullComponentLayers: [7],
            forceExplicitFullAttentionMask:
                ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_EXPLICIT_MASK"] == "1")
        XCTAssertEqual(native.promptTokenIDs, prefixTokens)
        XCTAssertEqual(native.prefillGroupSize, fixture.history.prefillGroupSize)
        XCTAssertEqual(native.groups.count, 7)
        XCTAssertEqual(native.groups.flatMap { $0.layers }.map(\.layer),
                       Array(repeating: Array(0...7), count: 7).flatMap { $0 })
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_PREFILL_COMPONENTS_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(native).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("[qwen-q29-prefill-components-output] path=\(outputPath) bytes=\(try Data(contentsOf: URL(fileURLWithPath: outputPath)).count)")
        }
    }

    /// Isolates the first Q2.9 full-attention discrepancy from model state and
    /// projection loading.  The query, current K/V tensors, and the oracle
    /// attention output are read from the independently generated boundary
    /// captures.  This diagnostic intentionally does not alter production
    /// attention; it records how the native Swift MLX SDPA primitive compares
    /// with the Python MLX oracle and with the documented unfused expression.
    func testOptInQ29FullAttentionPrimitiveReplay() throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_SDPA_REPLAY"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q29_SDPA_REPLAY=1 for the isolated SDPA replay.")
        }
        func mark(_ message: String) {
            FileHandle.standardError.write(Data(("[qwen-q29-sdpa-stage] " + message + "\n").utf8))
        }
        mark("start")
        let referencePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_SDPA_REFERENCE"]
            ?? "/tmp/qwen35-k8-q29-sdpa-reference-focused.json"
        let nativePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q29_SDPA_NATIVE"]
            ?? "/tmp/qwen35-k8-q29-sdpa-native-focused.json"

        let referenceLayer = try boundaryLayerObject(
            at: URL(fileURLWithPath: referencePath), group: 6, layer: 7)
        let nativeLayer = try boundaryLayerObject(
            at: URL(fileURLWithPath: nativePath), group: 6, layer: 7)
        mark("json-loaded")
        let referenceComponents = try dictionary(referenceLayer["components"], named: "reference components")
        let nativeComponents = try dictionary(nativeLayer["components"], named: "native components")
        let referenceAttention = try dictionary(
            referenceComponents["fullAttention"], named: "reference full attention")
        let nativeAttention = try dictionary(
            nativeComponents["fullAttention"], named: "native full attention")
        let referenceCache = try dictionary(referenceLayer["cache"], named: "reference cache")
        let referenceState = try array(referenceCache["state"], named: "reference cache state")
        XCTAssertEqual(referenceState.count, 2)

        let querySummary = try decodeSummary(referenceAttention["queries"], named: "queries")
        let keySummary = try decodeSummary(referenceState[0], named: "keys")
        let valueSummary = try decodeSummary(referenceState[1], named: "values")
        let expectedSummary = try decodeSummary(
            referenceAttention["attentionValues"], named: "reference attention values")
        let nativeSummary = try decodeSummary(
            nativeAttention["attentionValues"], named: "native attention values")

        let queries = rawMLXArray(querySummary)
        let keys = rawMLXArray(keySummary)
        let values = rawMLXArray(valueSummary)
        let expected = rawFloatValues(expectedSummary)
        let nativeCaptured = rawFloatValues(nativeSummary)
        mark("arrays-created")
        XCTAssertEqual(queries.shape, [1, 16, 4, 256])
        XCTAssertEqual(keys.shape, [1, 2, 28, 256])
        XCTAssertEqual(values.shape, [1, 2, 28, 256])

        let scale = pow(Float(256), -0.5)
        let fast = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: .causal)
            .transposed(0, 2, 1, 3)
            .reshaped(expectedSummary.shape)
        mark("fast-built")

        // This is the regular-operation sequence used for the independent
        // Python cross-check. It makes the GQA expansion and dtype boundaries
        // explicit so the operation order is visible in the diagnostic.
        let repeats = queries.dim(1) / keys.dim(1)
        let repeatedKeys = repeated(keys, count: repeats, axis: 1)
        let repeatedValues = repeated(values, count: repeats, axis: 1)
        let scores = matmul(
            queries.asType(.float32) * MLXArray(scale),
            repeatedKeys.asType(.float32).swappedAxes(-1, -2))
        mark("scores-built")
        let causal = createCausalMask(
            n: queries.dim(2), offset: keys.dim(2) - queries.dim(2))
            .expandedDimensions(axes: [0, 1])
        let maskedScores = MLX.where(
            causal, scores, MLXArray(-Float.greatestFiniteMagnitude))
        let probabilities = softmax(
            maskedScores, axis: -1, precise: true)
        let unfused = matmul(probabilities, repeatedValues.asType(.float32))
            .asType(.bfloat16)
            .transposed(0, 2, 1, 3)
            .reshaped(expectedSummary.shape)
        mark("unfused-built")
        MLX.eval(fast, unfused)
        mark("eval-complete")

        let fastValues = fast.asType(.float32).flattened().asArray(Float.self)
        let unfusedValues = unfused.asType(.float32).flattened().asArray(Float.self)
        let fastAgainstOracle = relativeL2(fastValues, expected)
        let unfusedAgainstOracle = relativeL2(unfusedValues, expected)
        let fastAgainstNative = relativeL2(fastValues, nativeCaptured)
        let unfusedAgainstNative = relativeL2(unfusedValues, nativeCaptured)
        let fastMax = maxAbs(fastValues, expected)
        let unfusedMax = maxAbs(unfusedValues, expected)
        print(
            "[qwen-q29-sdpa] shape=Q\(queries.shape)/K\(keys.shape) " +
            "fastVsOracleRelL2=\(fastAgainstOracle) fastVsOracleMaxAbs=\(fastMax) " +
            "unfusedVsOracleRelL2=\(unfusedAgainstOracle) unfusedVsOracleMaxAbs=\(unfusedMax) " +
            "fastVsNativeRelL2=\(fastAgainstNative) unfusedVsNativeRelL2=\(unfusedAgainstNative)")
        XCTAssertEqual(fastValues.count, expected.count)
        XCTAssertEqual(unfusedValues.count, expected.count)
    }

    /// Validates the Q2.10 SDPA call contract captured from the real layer-7
    /// prefill boundary.  This is deliberately fixture-only: it does not
    /// replace the production fused attention path or load model weights.
    func testOptInQ210SDPAInvocationMetadata() throws {
        guard let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q210_SDPA_METADATA"] else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q210_SDPA_METADATA=1 for the Q2.10 SDPA metadata check.")
        }
        let document = try dictionary(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))),
            named: "Q2.10 SDPA document")
        let groups = try array(document["groups"], named: "Q2.10 groups")
        let group = try dictionary(groups[6], named: "Q2.10 group 6")
        let layers = try array(group["layers"], named: "Q2.10 group 6 layers")
        let layer = try XCTUnwrap(layers.compactMap { $0 as? [String: Any] }
            .first(where: { ($0["layer"] as? Int) == 7 }))
        let components = try dictionary(layer["components"], named: "Q2.10 components")
        let attention = try dictionary(components["fullAttention"], named: "Q2.10 full attention")
        let sdpa = try dictionary(attention["sdpa"], named: "Q2.10 SDPA")
        let queryLayout = try dictionary(sdpa["queryLayout"], named: "Q2.10 query layout")
        let keyLayout = try dictionary(sdpa["keyLayout"], named: "Q2.10 key layout")
        let valueLayout = try dictionary(sdpa["valueLayout"], named: "Q2.10 value layout")
        let cachedKeyLayout = try dictionary(sdpa["cachedKeyLayout"], named: "Q2.10 cached key layout")
        let cachedValueLayout = try dictionary(sdpa["cachedValueLayout"], named: "Q2.10 cached value layout")
        let outputLayout = try dictionary(sdpa["outputLayout"], named: "Q2.10 output layout")

        XCTAssertEqual(sdpa["maskMode"] as? String, "causal")
        XCTAssertEqual(sdpa["scale"] as? Double, 0.0625)
        XCTAssertEqual(sdpa["scaleBits"] as? UInt32, 0x3d800000)
        XCTAssertEqual(queryLayout["shape"] as? [Int], [1, 16, 4, 256])
        XCTAssertEqual(queryLayout["strides"] as? [Int], [16384, 1024, 256, 1])
        XCTAssertEqual(keyLayout["shape"] as? [Int], [1, 2, 4, 256])
        XCTAssertEqual(keyLayout["strides"] as? [Int], [2048, 1024, 256, 1])
        XCTAssertEqual(valueLayout["shape"] as? [Int], [1, 2, 4, 256])
        XCTAssertEqual(valueLayout["strides"] as? [Int], [2048, 256, 512, 1])
        XCTAssertEqual(valueLayout["contiguous"] as? Bool, false)
        XCTAssertEqual(cachedKeyLayout["shape"] as? [Int], [1, 2, 28, 256])
        XCTAssertEqual(cachedValueLayout["shape"] as? [Int], [1, 2, 28, 256])
        XCTAssertEqual(cachedKeyLayout["strides"] as? [Int], [131072, 65536, 256, 1])
        XCTAssertEqual(cachedValueLayout["strides"] as? [Int], [131072, 65536, 256, 1])
        XCTAssertEqual(outputLayout["shape"] as? [Int], [1, 16, 4, 256])
        XCTAssertEqual(outputLayout["rawSHA256"] as? String,
                       "52ee0c82dd91af169be3a1f3aa2f5bd2c8fcbea75ff42b6aaf534dc68d35902e")

        if let explicitPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q210_SDPA_EXPLICIT_METADATA"] {
            let explicit = try dictionary(
                JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: explicitPath))),
                named: "Q2.10 explicit-mask document")
            let explicitGroups = try array(explicit["groups"], named: "Q2.10 explicit groups")
            let explicitGroup = try dictionary(explicitGroups[6], named: "Q2.10 explicit group 6")
            let explicitLayers = try array(explicitGroup["layers"], named: "Q2.10 explicit layers")
            let explicitLayer = try XCTUnwrap(explicitLayers.compactMap { $0 as? [String: Any] }
                .first(where: { ($0["layer"] as? Int) == 7 }))
            let explicitComponents = try dictionary(explicitLayer["components"], named: "Q2.10 explicit components")
            let explicitAttention = try dictionary(explicitComponents["fullAttention"], named: "Q2.10 explicit full attention")
            let explicitSDPA = try dictionary(explicitAttention["sdpa"], named: "Q2.10 explicit SDPA")
            let explicitOutput = try dictionary(explicitSDPA["outputLayout"], named: "Q2.10 explicit output layout")
            XCTAssertEqual(explicitSDPA["maskMode"] as? String, "")
            XCTAssertNotNil(explicitSDPA["mask"] as? [String: Any])
            XCTAssertEqual(explicitOutput["rawSHA256"] as? String, outputLayout["rawSHA256"] as? String)
        }
        print("[qwen-q210-sdpa-metadata] layer=7 group=6 scaleBits=0x3d800000 causal=verified cachedKV=verified")
    }

    /// Q2.11 developer-only primitive candidate.  This replays the exact
    /// compact Python explicit-operation package through ordinary Swift MLX
    /// ops and exports every intermediate.  It deliberately does not load
    /// model weights, alter the fused production path, or assert that the
    /// candidate equals the fused oracle; the latter comparison is the
    /// localization result for this phase.
    func testOptInQ211ReferenceCompatibleExplicitIntermediates() throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q211_EXPLICIT"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q211_EXPLICIT=1 for the Q2.11 explicit attention replay.")
        }
        func mark(_ message: String) {
            FileHandle.standardError.write(Data(("[qwen-q211-stage] " + message + "\n").utf8))
        }
        mark("start")

        let pythonPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q211_PYTHON"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.11-Python-explicit-intermediates.json"
        let pythonURL = URL(fileURLWithPath: pythonPath)
        let pythonData = try Data(contentsOf: pythonURL)
        let python = try JSONDecoder().decode(Q211PythonFixture.self, from: pythonData)
        mark("python-loaded")

        XCTAssertEqual(python.fixtureFormatVersion,
                       "qwen35-k8-q2.11-explicit-intermediates-v1")
        XCTAssertEqual(python.artifact.repo, "mlx-community/Qwen3.5-35B-A3B-4bit")
        XCTAssertEqual(python.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(python.artifact.inventorySHA256,
                       "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592")
        XCTAssertEqual(python.layer, 7)
        XCTAssertEqual(python.prefillGroup, 6)
        XCTAssertEqual(python.queryPositions, [24, 25, 26, 27])
        XCTAssertEqual(python.scale, 0.0625)
        XCTAssertEqual(python.gqa.queryHeads, 16)
        XCTAssertEqual(python.gqa.kvHeads, 2)
        XCTAssertEqual(python.gqa.repeatCount, 8)
        XCTAssertEqual(python.gqa.axis, 1)
        XCTAssertEqual(python.gqa.operation, "mx.repeat")
        XCTAssertEqual(python.mask.dtype, "bool")
        XCTAssertEqual(python.mask.shape, [4, 28])
        XCTAssertEqual(python.mask.validKeyRanges, [25, 26, 27, 28])
        XCTAssertEqual(python.mask.rowAlignment, "absolute query position")

        let sourcePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q211_SOURCE"]
            ?? "/tmp/qwen35-k8-q29-sdpa-reference-focused.json"
        let referenceLayer = try boundaryLayerObject(
            at: URL(fileURLWithPath: sourcePath), group: python.prefillGroup, layer: python.layer)
        mark("source-loaded")
        let referenceComponents = try dictionary(referenceLayer["components"], named: "Q2.11 components")
        let referenceAttention = try dictionary(
            referenceComponents["fullAttention"], named: "Q2.11 full attention")
        let referenceCache = try dictionary(referenceLayer["cache"], named: "Q2.11 cache")
        let referenceState = try array(referenceCache["state"], named: "Q2.11 cache state")
        XCTAssertEqual(referenceState.count, 2)

        let queries = rawMLXArray(
            try decodeSummary(referenceAttention["queries"], named: "Q2.11 queries"))
        let keys = rawMLXArray(
            try decodeSummary(referenceState[0], named: "Q2.11 cache keys"))
        let values = rawMLXArray(
            try decodeSummary(referenceState[1], named: "Q2.11 cache values"))
        XCTAssertEqual(queries.shape, [1, 16, 4, 256])
        XCTAssertEqual(keys.shape, [1, 2, 28, 256])
        XCTAssertEqual(values.shape, [1, 2, 28, 256])

        // Rows are aligned to absolute positions 24...27.  The mask is true
        // for key columns 0...position in each row, exactly as in the Python
        // fixture, and is intentionally supplied as a rank-2 Boolean array.
        let maskValues = (0..<4).flatMap { row in
            (0..<28).map { key in key <= 24 + row }
        }
        let mask = MLXArray(maskValues, [4, 28])
        mark("inputs-created")
        let trace = StreamQwen35Attention.diagnosticAttentionTrace(
            strategy: .referenceCompatibleExplicit,
            queries: queries,
            keys: keys,
            values: values,
            scale: python.scale,
            mask: mask)
        mark("candidate-evaluated")

        let candidateArrays: [(String, MLXArray)] = [
            ("expandedKeys", trace.expandedKeys),
            ("expandedValues", trace.expandedValues),
            ("rawQK", trace.rawQK),
            ("scaledScores", trace.scaledScores),
            ("maskedScores", trace.maskedScores),
            ("probabilities", trace.probabilities),
            ("weightedOutputFloat32", trace.weightedOutputFloat32),
            ("output", trace.output),
        ]
        let expectedByName = Dictionary(uniqueKeysWithValues: python.arrays.map { ($0.name, $0) })
        var summaries = [String: QwenStreamArraySummary]()
        var comparisons = [Q211Comparison]()
        var firstDifference: String?

        for (name, array) in candidateArrays {
            let expected = try XCTUnwrap(expectedByName[name], "missing Python intermediate \(name)")
            let summary = QwenStreamArraySummary(array, captureFullValues: true)
            summaries[name] = summary
            let candidateValues = rawFloatValues(summary)
            let expectedValues = q211FloatValues(expected)
            let candidateWords = q211RawWords(summary)
            let bitExact = candidateWords == expected.rawWords
                && summary.shape == expected.shape
                && q211NormalizedDType(summary.dtype) == expected.dtype
            let (worstIndex, candidateWorst, expectedWorst, maxValue) =
                q211Worst(candidateValues, expectedValues)
            let record = Q211Comparison(
                name: name,
                shape: summary.shape,
                expectedDType: expected.dtype,
                candidateDType: q211NormalizedDType(summary.dtype),
                bitExact: bitExact,
                expectedChecksum: expected.checksum,
                candidateChecksum: q211Checksum(summary),
                relL2: relativeL2(candidateValues, expectedValues),
                maxAbs: maxValue,
                worstIndex: worstIndex,
                candidateValueAtWorst: candidateWorst,
                expectedValueAtWorst: expectedWorst)
            comparisons.append(record)
            if !bitExact && firstDifference == nil {
                firstDifference = name
            }
            XCTAssertEqual(summary.shape, expected.shape, "shape mismatch at \(name)")
            XCTAssertEqual(q211NormalizedDType(summary.dtype), expected.dtype,
                           "dtype mismatch at \(name)")
            XCTAssertEqual(candidateWords, expected.rawWords,
                           "Swift explicit candidate differs from Python at \(name)")
        }
        mark("comparisons-complete")

        let oracleSummary = try decodeSummary(
            referenceAttention["attentionValues"], named: "Q2.11 oracle attention values")
        let oracleValues = rawFloatValues(oracleSummary)
        let candidateOutputSummary = try XCTUnwrap(summaries["output"])
        // The primitive export intentionally stays in attention layout.  The
        // independent boundary fixture stores the post-SDPA presentation
        // layout [batch, sequence, heads * headDim], so compare after the
        // same transpose/reshape used by the production attention wrapper.
        let candidateOracleArray = trace.output
            .transposed(0, 2, 1, 3)
            .reshaped(oracleSummary.shape)
        let candidateOracleSummary = QwenStreamArraySummary(
            candidateOracleArray, captureFullValues: true)
        let candidateOutputValues = rawFloatValues(candidateOracleSummary)
        let oracleComparison = Q211OracleOutputComparison(
            bitExact: q211RawWords(candidateOracleSummary) == q211RawWords(oracleSummary),
            oracleChecksum: q211Checksum(oracleSummary),
            candidateChecksum: q211Checksum(candidateOracleSummary),
            relL2: relativeL2(candidateOutputValues, oracleValues),
            maxAbs: maxAbs(candidateOutputValues, oracleValues),
            candidateShape: candidateOracleSummary.shape,
            oracleShape: oracleSummary.shape)

        let export = Q211SwiftExport(
            fixtureFormatVersion: "qwen35-k8-q2.11-swift-explicit-v1",
            artifact: python.artifact,
            nativeCandidate: StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue,
            operationOrder: python.operationOrder,
            arrays: summaries,
            comparisons: comparisons,
            firstDifference: firstDifference,
            oracleOutput: oracleComparison,
            notes: [
                "Candidate is diagnostic-only; StreamQwen35Attention.callAsFunction remains fused.",
                "GQA uses repeated(..., count: 8, axis: 1), matching Python mx.repeat(axis=1).",
                "The scored Python expression scales Float32 Q before matmul; rawQK is returned only for localization.",
                "Mask is Boolean [4,28], expanded over batch and query heads; false cells use Float32 finite minimum.",
                "Softmax uses precise=true; P@V is Float32 and output is cast to BF16 without layout transpose.",
            ])
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q211_SWIFT_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let outputURL = URL(fileURLWithPath: outputPath)
            try encoder.encode(export).write(to: outputURL, options: .atomic)
            print("[qwen-q211-output] path=\(outputPath) bytes=\(try Data(contentsOf: outputURL).count)")
        }
        mark("export-complete")

        for comparison in comparisons {
            print(
                "[qwen-q211-intermediate] \(comparison.name) exact=\(comparison.bitExact) " +
                "relL2=\(comparison.relL2) maxAbs=\(comparison.maxAbs) " +
                "candidateSHA=\(comparison.candidateChecksum) expectedSHA=\(comparison.expectedChecksum)")
        }
        print(
            "[qwen-q211-oracle] explicitVsFusedOracleExact=\(oracleComparison.bitExact) " +
            "relL2=\(oracleComparison.relL2) maxAbs=\(oracleComparison.maxAbs) " +
            "firstCandidateDifference=\(firstDifference ?? "none")")
    }

    /// Q2.12 reconciles the Q2.11 primitive replay with a real layer-7 model
    /// call.  The explicit candidate is selected for one prefill group only;
    /// every other group and every unselected layer remains on the production
    /// fused path.  This test is intentionally opt-in because it loads the
    /// installed 35B checkpoint and performs two bounded 28-token passes.
    func testOptInQ212ExplicitModelDataflowAndBoundaryProvenance() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q212"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q212=1 for the model-level explicit-attention probe.")
        }
        func mark(_ message: String) {
            FileHandle.standardError.write(Data(("[qwen-q212-stage] " + message + "\n").utf8))
        }
        mark("start")

        let pythonPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q211_PYTHON"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.11-Python-explicit-intermediates.json"
        let pythonData = try Data(contentsOf: URL(fileURLWithPath: pythonPath))
        let pythonSHA = SHA256.hash(data: pythonData)
            .map { String(format: "%02x", $0) }.joined()
        let python = try JSONDecoder().decode(Q211PythonFixture.self, from: pythonData)
        let pythonByName = Dictionary(uniqueKeysWithValues: python.arrays.map { ($0.name, $0) })
        mark("python-loaded")

        let sourcePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q212_SOURCE"]
            ?? "/tmp/qwen35-k8-q29-sdpa-reference-focused.json"
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let sourceData = try Data(contentsOf: sourceURL)
        let sourceSHA = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }.joined()
        let sourceLayer = try boundaryLayerObject(at: sourceURL, group: 6, layer: 7)
        let sourceComponents = try dictionary(sourceLayer["components"], named: "Q2.12 source components")
        let sourceAttention = try dictionary(
            sourceComponents["fullAttention"], named: "Q2.12 source full attention")
        let sourceCache = try dictionary(sourceLayer["cache"], named: "Q2.12 source cache")
        let sourceState = try array(sourceCache["state"], named: "Q2.12 source cache state")
        let sourceQueries = try decodeSummary(sourceAttention["queries"], named: "Q2.12 source T0")
        let sourceKeys = try decodeSummary(sourceAttention["keys"], named: "Q2.12 source T1")
        let sourceValues = try decodeSummary(sourceAttention["values"], named: "Q2.12 source T2")
        let sourceAttentionValues = try decodeSummary(
            sourceAttention["attentionValues"], named: "Q2.12 source T9")
        let sourceCacheKeys = try decodeSummary(sourceState[0], named: "Q2.12 source cached K")
        let sourceCacheValues = try decodeSummary(sourceState[1], named: "Q2.12 source cached V")
        let sourceT7Array = rawMLXArray(sourceAttentionValues)
            .reshaped(1, 4, 16, 256)
            .transposed(0, 2, 1, 3)
        let sourceT7 = QwenStreamArraySummary(sourceT7Array, captureFullValues: true)
        mark("source-loaded")

        let historyPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q212_HISTORY"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let historyData = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let historySHA = SHA256.hash(data: historyData)
            .map { String(format: "%02x", $0) }.joined()
        let historyFixture = try JSONDecoder().decode(Fixture.self, from: historyData)
        let tokenIDs = Array(historyFixture.history.promptTokenIDs.prefix(28))
        XCTAssertEqual(tokenIDs.count, 28)
        XCTAssertEqual(historyFixture.history.prefillGroupSize, 4)
        XCTAssertEqual(python.queryPositions, [24, 25, 26, 27])
        XCTAssertEqual(python.layer, 7)
        XCTAssertEqual(python.prefillGroup, 6)
        XCTAssertEqual(sourceCacheKeys.shape, [1, 2, 28, 256])
        XCTAssertEqual(sourceCacheValues.shape, [1, 2, 28, 256])

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let counters = StreamQwen35AttentionDiagnosticCounters()
        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: tokenIDs,
            boundaryLayers: Array(0...7),
            captureFullComponents: true,
            fullComponentLayers: [7],
            forceExplicitFullAttentionMask: true,
            attentionStrategy: .referenceCompatibleExplicit,
            attentionStrategyLayers: [7],
            attentionStrategyGroup: 6,
            diagnosticCounters: counters)
        mark("native-loaded")

        let nativeGroup = try XCTUnwrap(native.groups.first(where: { $0.groupIndex == 6 }))
        let nativeLayer = try XCTUnwrap(nativeGroup.layers.first(where: { $0.layer == 7 }))
        let full = try XCTUnwrap(nativeLayer.components?.fullAttention)
        let trace = try XCTUnwrap(full.explicitTrace)
        XCTAssertEqual(full.requestedStrategy, StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(full.effectiveStrategy, StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(full.sentinelApplied, false)
        XCTAssertEqual(counters.explicitInvocations, 1)
        XCTAssertGreaterThan(counters.fusedInvocations, 0)
        XCTAssertEqual(counters.lastLayer, 7)
        XCTAssertEqual(counters.lastGroup, 6)
        XCTAssertEqual(full.sdpa?.mask?.shape, [4, 28])
        XCTAssertEqual(q211NormalizedDType(full.sdpa?.mask?.dtype ?? ""), "bool")

        // The model-level current operands must be the same values that fed
        // the independent boundary fixture.  These checks make the following
        // T7 comparison a provenance check rather than a hidden upstream drift.
        let supporting = [
            q212Compare("T0", source: "Q2.10 independent full-model boundary",
                        candidate: full.queries, reference: sourceQueries),
            q212Compare("T1", source: "Q2.10 independent full-model boundary",
                        candidate: full.keys, reference: sourceKeys),
            q212Compare("T2", source: "Q2.10 independent full-model boundary",
                        candidate: full.values, reference: sourceValues),
            q212Compare("cachedK", source: "Q2.10 independent cache snapshot",
                        candidate: nativeLayer.cache.state[0], reference: sourceCacheKeys),
            q212Compare("cachedV", source: "Q2.10 independent cache snapshot",
                        candidate: nativeLayer.cache.state[1], reference: sourceCacheValues),
        ]
        for item in supporting {
            XCTAssertEqual(item.bitExact, true, "input provenance mismatch at \(item.name)")
        }

        var boundaries = [Q212BoundaryComparison]()
        let explicitNames = [
            ("T3", "rawQK"),
            ("T4", "scaledScores"),
            ("T5", "maskedScores"),
            ("T6", "probabilities"),
        ]
        for (boundary, arrayName) in explicitNames {
            let expected = try XCTUnwrap(pythonByName[arrayName], "missing Python \(arrayName)")
            let candidate = q212Summary(for: trace, name: arrayName)
            let comparison = q212Compare(
                boundary,
                source: "Q2.11 independent explicit-operation fixture",
                candidate: candidate,
                reference: expected)
            boundaries.append(comparison)
            XCTAssertEqual(comparison.bitExact, true, "model-level explicit candidate differs at \(boundary)")
        }

        // Q2.11's `output` is raw T7 in attention layout.  The old 7.5845e-05
        // comparison used the value-preserving T9 transpose/reshape on this
        // candidate and compared it with the independent full-model
        // `attentionValues` tensor.  Reconstructing T7 from that oracle tensor
        // makes the first comparable mismatch explicit at the attention
        // helper boundary itself.
        let t7 = q212Compare(
            "T7",
            source: "Q2.10 independent full-model attentionValues, inverse T9 layout",
            candidate: q212Summary(for: trace, name: "output"),
            reference: sourceT7)
        boundaries.append(t7)
        XCTAssertEqual(t7.bitExact, false, "Q2.12 expected the known fused/oracle boundary mismatch")
        let t7RelL2 = try XCTUnwrap(t7.relL2)
        let t7MaxAbs = try XCTUnwrap(t7.maxAbs)
        XCTAssertEqual(t7RelL2, 7.584503077329163e-05, accuracy: 1e-12)
        XCTAssertEqual(t7MaxAbs, 0.00390625)

        let legacyT9RelL2 = relativeL2(
            rawFloatValues(full.attentionValues), rawFloatValues(sourceAttentionValues))
        let legacyT9 = Q212LegacyComparison(
            candidateChecksum: q211Checksum(full.attentionValues),
            referenceChecksum: q211Checksum(sourceAttentionValues),
            shape: sourceAttentionValues.shape,
            dtype: q211NormalizedDType(sourceAttentionValues.dtype),
            relL2: legacyT9RelL2,
            maxAbs: maxAbs(rawFloatValues(full.attentionValues), rawFloatValues(sourceAttentionValues)))
        XCTAssertEqual(legacyT9RelL2, 7.584503077329163e-05, accuracy: 1e-12)

        // A second pass applies a DEBUG-only sentinel after the explicit
        // helper. The helper trace remains unmodified; the model's
        // attentionValues, o_proj input, residual, and following MoE path see
        // the sentinel. This is the unambiguous model-level data-flow proof.
        let sentinelCounters = StreamQwen35AttentionDiagnosticCounters()
        let sentinelRun = try await engine.debugPrefillBoundaries(
            tokenIDs: tokenIDs,
            boundaryLayers: Array(0...7),
            captureFullComponents: true,
            fullComponentLayers: [7],
            forceExplicitFullAttentionMask: true,
            attentionStrategy: .referenceCompatibleExplicit,
            attentionStrategyLayers: [7],
            attentionStrategyGroup: 6,
            diagnosticCounters: sentinelCounters,
            diagnosticSentinel: 1.0)
        let sentinelGroup = try XCTUnwrap(sentinelRun.groups.first(where: { $0.groupIndex == 6 }))
        let sentinelLayer = try XCTUnwrap(sentinelGroup.layers.first(where: { $0.layer == 7 }))
        let sentinelFull = try XCTUnwrap(sentinelLayer.components?.fullAttention)
        let sentinelTrace = try XCTUnwrap(sentinelFull.explicitTrace)
        XCTAssertEqual(sentinelFull.requestedStrategy, StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(sentinelFull.effectiveStrategy, StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(sentinelFull.sentinelApplied, true)
        XCTAssertEqual(sentinelCounters.explicitInvocations, 1)
        XCTAssertEqual(q211RawWords(sentinelTrace.output), q211RawWords(trace.output))
        let expectedSentinelAttention = (rawMLXArray(trace.output)
            + MLXArray(1.0, dtype: .bfloat16))
            .transposed(0, 2, 1, 3)
            .reshaped(1, 4, 4096)
        let expectedSentinelSummary = QwenStreamArraySummary(
            expectedSentinelAttention, captureFullValues: true)
        XCTAssertEqual(
            q211RawWords(sentinelFull.attentionValues),
            q211RawWords(expectedSentinelSummary),
            "the model-level attentionValues did not receive the explicit-path sentinel")
        XCTAssertEqual(
            q211RawWords(sentinelFull.attentionValues),
            q211RawWords(expectedSentinelSummary))
        mark("sentinel-verified")

        let strategyRecord = Q212StrategyRecord(
            requested: full.requestedStrategy ?? "unavailable",
            effective: full.effectiveStrategy ?? "unavailable",
            layer: counters.lastLayer,
            group: counters.lastGroup,
            explicitInvocations: counters.explicitInvocations,
            fusedInvocations: counters.fusedInvocations,
            sentinelApplied: full.sentinelApplied ?? false)
        let sentinelRecord = Q212StrategyRecord(
            requested: sentinelFull.requestedStrategy ?? "unavailable",
            effective: sentinelFull.effectiveStrategy ?? "unavailable",
            layer: sentinelCounters.lastLayer,
            group: sentinelCounters.lastGroup,
            explicitInvocations: sentinelCounters.explicitInvocations,
            fusedInvocations: sentinelCounters.fusedInvocations,
            sentinelApplied: sentinelFull.sentinelApplied ?? false)
        let report = Q212Report(
            fixtureFormatVersion: "qwen35-k8-q2.12-boundary-v1",
            artifact: python.artifact,
            pythonFixtureSHA256: pythonSHA,
            sourceFixtureSHA256: sourceSHA,
            historyFixtureSHA256: historySHA,
            layer: 7,
            prefillGroup: 6,
            queryPositions: python.queryPositions,
            boundaryDefinitions: [
                "T0: Q after q_norm and RoPE",
                "T1: current K after k_norm and RoPE",
                "T2: current V entering attention",
                "T3: QK^T",
                "T4: scaled scores (scale applied before matmul)",
                "T5: Boolean-masked scores",
                "T6: precise softmax probabilities",
                "T7: P@V weighted output before BF16 cast plus the BF16 helper output",
                "T8: raw SDPA result returned to the attention wrapper",
                "T9: transpose/reshape/head merge attentionValues",
                "T10: output-gate input/result represented by gate and gatedValues",
                "T11: o_proj input represented by gatedValues",
                "T12: o_proj output represented by attentionOutput",
                "T13: residual-added attention result postAttentionResidual",
                "T14: post-attention normalization/MoE input postAttentionInput",
            ],
            strategy: strategyRecord,
            sentinelStrategy: sentinelRecord,
            q211MatchedIntermediates: [
                "expandedKeys", "expandedValues", "rawQK", "scaledScores",
                "maskedScores", "probabilities", "weightedOutputFloat32", "output",
            ],
            legacyT9Comparison: legacyT9,
            supportingInputs: supporting,
            boundaries: boundaries,
            firstComparableMismatch: "T7",
            conclusion: "The explicit candidate reaches the real layer-7/group-6 model path. Its T0-T6 operands and intermediates are exact against their independent provenance fixtures; the first full-model comparable mismatch is T7, the P@V/SDPA boundary, with the previously observed relL2 7.584503077329163e-05.",
            notes: [
                "Q2.11 Python arrays are an independent ordinary-operation replay, not the fused full-model oracle.",
                "The old Q2.11 comparison was trace.output.transpose(0,2,1,3).reshape([1,4,4096]) versus source fullAttention.attentionValues.",
                "T8-T14 are defined in the actual model order but are not promoted past the first T7 mismatch.",
                "The DEBUG-only sentinel is diagnostic-only; callAsFunction and normal production generation remain fused.",
                "No layer-19/64-token run, cache-pool experiment, or performance optimization was started.",
            ])
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q212_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let outputURL = URL(fileURLWithPath: outputPath)
            try encoder.encode(report).write(to: outputURL, options: .atomic)
            print("[qwen-q212-output] path=\(outputPath) bytes=\(try Data(contentsOf: outputURL).count)")
        }
        print("[qwen-q212-boundary] T0-T6 exact=true firstMismatch=T7 relL2=\(t7RelL2) maxAbs=\(t7MaxAbs)")
        mark("complete")
    }

    /// Q2.13 compares the real native explicit model seam with the versioned
    /// ordinary-MLX reference produced after reconciling the two fixture
    /// lineages.  The historical fused focused capture is intentionally not
    /// used as the expected explicit-operation output here.
    func testOptInQ213ReferenceProvenanceReconciliation() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q213"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q213=1 for the Q2.13 provenance reconciliation.")
        }
        func mark(_ message: String) {
            FileHandle.standardError.write(Data(("[qwen-q213-stage] " + message + "\n").utf8))
        }
        mark("start")

        let fixturePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q213_REFERENCE"]
            ?? "/Users/m/Downloads/beetcode/BeetCode/Tests/Fixtures/Qwen35-K8-Q2.13-authoritative-explicit-reference.json"
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureSHA = SHA256.hash(data: fixtureData)
            .map { String(format: "%02x", $0) }.joined()
        let fixture = try JSONDecoder().decode(Q213CorrectedFixture.self, from: fixtureData)
        mark("reference-loaded")

        XCTAssertEqual(
            fixture.fixtureFormatVersion,
            "qwen35-k8-q2.13-authoritative-explicit-reference-v1")
        XCTAssertEqual(fixture.artifact.repo, QwenStreamArtifact.repo)
        XCTAssertEqual(fixture.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(
            fixture.artifact.inventorySHA256,
            "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592")
        XCTAssertEqual(fixture.layer, 7)
        XCTAssertEqual(fixture.prefillGroup, 6)
        XCTAssertEqual(fixture.queryPositions, [24, 25, 26, 27])
        XCTAssertEqual(fixture.scale, 0.0625)
        XCTAssertEqual(fixture.scaleBits, Float(0.0625).bitPattern)
        XCTAssertEqual(fixture.authority.mlx, "0.31.1")
        XCTAssertEqual(fixture.authority.recurrentState, "float32")
        XCTAssertEqual(fixture.authority.producer, "qwen35_q213_reference_provenance.py::explicit_attention")
        XCTAssertEqual(fixture.lineage["referenceAFixtureSHA256"],
                       "7738f43288eb1f44d87a05c4c31f41c2915a9c96e0609bdc44c7d70634f2f8a2")
        let expectedT7F32 = try XCTUnwrap(fixture.boundaries["T7Float32"])
        let expectedT7 = try XCTUnwrap(fixture.boundaries["T7BF16"])
        let expectedT8 = try XCTUnwrap(fixture.boundaries["T8"])
        let expectedT9 = try XCTUnwrap(fixture.boundaries["T9"])
        XCTAssertEqual(expectedT7.shape, [1, 16, 4, 256])
        XCTAssertEqual(expectedT7.dtype, "bfloat16")
        XCTAssertEqual(expectedT8.shape, [1, 16, 4, 256])
        XCTAssertEqual(expectedT9.shape, [1, 4, 4096])
        mark("metadata-verified")

        let historyPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q213_HISTORY"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let historyData = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let history = try JSONDecoder().decode(Fixture.self, from: historyData)
        let tokenIDs = Array(history.history.promptTokenIDs.prefix(28))
        XCTAssertEqual(tokenIDs.count, fixture.promptTokenCount)
        let promptHash = SHA256.hash(data: Data(String(describing: tokenIDs).utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(promptHash, fixture.promptPrefixSHA256)

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let counters = StreamQwen35AttentionDiagnosticCounters()
        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: tokenIDs,
            boundaryLayers: Array(0...7),
            captureFullComponents: true,
            fullComponentLayers: [7],
            forceExplicitFullAttentionMask: true,
            attentionStrategy: .referenceCompatibleExplicit,
            attentionStrategyLayers: [7],
            attentionStrategyGroup: 6,
            diagnosticCounters: counters)
        mark("native-loaded")

        let nativeGroup = try XCTUnwrap(native.groups.first(where: { $0.groupIndex == 6 }))
        let nativeLayer = try XCTUnwrap(nativeGroup.layers.first(where: { $0.layer == 7 }))
        let full = try XCTUnwrap(nativeLayer.components?.fullAttention)
        let trace = try XCTUnwrap(full.explicitTrace)
        let sdpa = try XCTUnwrap(full.sdpa)
        XCTAssertEqual(full.requestedStrategy,
                       StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(full.effectiveStrategy,
                       StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue)
        XCTAssertEqual(full.sentinelApplied, false)
        XCTAssertEqual(counters.explicitInvocations, 1)
        XCTAssertGreaterThan(counters.fusedInvocations, 0)
        XCTAssertEqual(counters.lastLayer, 7)
        XCTAssertEqual(counters.lastGroup, 6)
        XCTAssertEqual(sdpa.mask?.shape, [4, 28])
        XCTAssertEqual(q211NormalizedDType(sdpa.mask?.dtype ?? ""), "bool")

        let comparisons = [
            q212Compare(
                "T7-F32", source: "Q2.13 authoritative explicit T7 pre-cast",
                candidate: trace.weightedOutputFloat32, reference: expectedT7F32),
            q212Compare(
                "T7", source: "Q2.13 authoritative explicit T7 BF16",
                candidate: trace.output, reference: expectedT7),
            q212Compare(
                "T8", source: "Q2.13 authoritative explicit T8 helper result",
                candidate: sdpa.output, reference: expectedT8),
            q212Compare(
                "T9", source: "Q2.13 authoritative explicit T9 head merge",
                candidate: full.attentionValues, reference: expectedT9),
        ]
        for comparison in comparisons {
            XCTAssertEqual(comparison.bitExact, true,
                           "native explicit path differs at (comparison.name)")
        }
        let report = Q213NativeReport(
            fixtureFormatVersion: "qwen35-k8-q2.13-native-comparison-v1",
            correctedFixtureSHA256: fixtureSHA,
            strategy: Q212StrategyRecord(
                requested: full.requestedStrategy ?? "",
                effective: full.effectiveStrategy ?? "",
                layer: counters.lastLayer,
                group: counters.lastGroup,
                explicitInvocations: counters.explicitInvocations,
                fusedInvocations: counters.fusedInvocations,
                sentinelApplied: full.sentinelApplied ?? false),
            comparisons: comparisons,
            firstMismatch: comparisons.first(where: { $0.bitExact != true })?.name,
            conclusion: "The real native explicit model path matches the authoritative ordinary-MLX reference through T9 for layer 7 / prefill group 6.")
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q213_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        print("[qwen-q213-boundary] T7/T8/T9 exact=true explicit=\(counters.explicitInvocations) fused=\(counters.fusedInvocations)")
        mark("complete")
    }

    /// Q2.14 is a developer-only coverage smoke for the full explicit
    /// candidate. It exercises every configured full-attention layer through
    /// the real streamed model loop while leaving production fused attention
    /// untouched. Full-model reference/token parity is intentionally a later
    /// gate and is not claimed by this test.
    func testOptInQ214ExplicitFullAttentionCandidateCoverage() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q214"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q214=1 for the explicit full-attention candidate.")
        }
        let historyPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q214_HISTORY"]
            ?? "/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json"
        let historyData = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let history = try JSONDecoder().decode(Fixture.self, from: historyData)
        let tokenIDs = Array(history.history.promptTokenIDs.prefix(28))
        XCTAssertEqual(tokenIDs.count, 28)

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5 artifact is not installed.")
        }

        let configURL = directory.appendingPathComponent("config.json")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let textConfig = try XCTUnwrap(root["text_config"] as? [String: Any])
        let configuredTypes = try XCTUnwrap(textConfig["layer_types"] as? [String])
        let configuredFullLayers = configuredTypes.enumerated().compactMap { index, type in
            type == "full_attention" ? index : nil
        }
        XCTAssertEqual(configuredTypes.count, 40)
        XCTAssertEqual(configuredFullLayers.count, 10)

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let derivedFullLayers = await engine.debugFullAttentionLayerIndices()
        XCTAssertEqual(derivedFullLayers, configuredFullLayers)
        let counters = StreamQwen35AttentionDiagnosticCounters()
        let run = try await engine.debugGreedy(
            tokenIDs: tokenIDs,
            maxTokens: 1,
            checkpointSteps: [-1],
            attentionStrategy: .referenceCompatibleExplicit,
            diagnosticCounters: counters)

        let modelCalls = run.prefillCallCount + run.cachedDecodeCallCount
        XCTAssertEqual(counters.explicitInvocations, modelCalls * derivedFullLayers.count)
        XCTAssertEqual(counters.fusedInvocations, 0)
        XCTAssertEqual(counters.lastEffectiveStrategy, .referenceCompatibleExplicit)
        XCTAssertEqual(counters.lastRequestedStrategy, .referenceCompatibleExplicit)
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q214_OUTPUT"] {
            let report = Q214CoverageReport(
                fixtureFormatVersion: "qwen35-k8-q2.14-explicit-candidate-coverage-v1",
                attentionStrategy: StreamQwen35AttentionStrategy.referenceCompatibleExplicit.rawValue,
                fullAttentionLayerIndices: derivedFullLayers,
                prefillCallCount: run.prefillCallCount,
                cachedDecodeCallCount: run.cachedDecodeCallCount,
                explicitInvocations: counters.explicitInvocations,
                fusedInvocations: counters.fusedInvocations,
                generatedTokenIDs: run.generatedTokenIDs,
                stopReason: run.stopReason,
                finalConsumedPosition: run.finalConsumedPosition,
                conclusion: "Every configured full-attention layer used the developer-only explicit strategy in the real native model loop; this is coverage evidence, not full-model reference parity.")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(
                to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        print(
            "[qwen-q214-explicit] layers=\(derivedFullLayers) calls=\(modelCalls) "
                + "explicit=\(counters.explicitInvocations) fused=\(counters.fusedInvocations) "
                + "generated=\(run.generatedTokenIDs.count) stop=\(run.stopReason)")
    }

    private func q212Summary(
        for trace: QwenStreamDebugExplicitAttention,
        name: String
    ) -> QwenStreamArraySummary {
        switch name {
        case "expandedKeys": return trace.expandedKeys
        case "expandedValues": return trace.expandedValues
        case "rawQK": return trace.rawQK
        case "scaledScores": return trace.scaledScores
        case "maskedScores": return trace.maskedScores
        case "probabilities": return trace.probabilities
        case "weightedOutputFloat32": return trace.weightedOutputFloat32
        case "output": return trace.output
        default: fatalError("unknown Q2.12 explicit trace array \(name)")
        }
    }

    private func q212Compare(
        _ name: String,
        source: String,
        candidate: QwenStreamArraySummary,
        reference: Summary
    ) -> Q212BoundaryComparison {
        let candidateValues = rawFloatValues(candidate)
        let referenceValues = rawFloatValues(reference)
        return Q212BoundaryComparison(
            name: name,
            source: source,
            candidateShape: candidate.shape,
            candidateDType: q211NormalizedDType(candidate.dtype),
            referenceShape: reference.shape,
            referenceDType: q211NormalizedDType(reference.dtype),
            candidateChecksum: q211Checksum(candidate),
            referenceChecksum: q211Checksum(reference),
            bitExact: candidate.shape == reference.shape
                && q211NormalizedDType(candidate.dtype) == q211NormalizedDType(reference.dtype)
                && q211RawWords(candidate) == q211RawWords(reference),
            relL2: relativeL2(candidateValues, referenceValues),
            maxAbs: maxAbs(candidateValues, referenceValues),
            note: nil)
    }

    private func q212Compare(
        _ name: String,
        source: String,
        candidate: QwenStreamArraySummary,
        reference: QwenStreamArraySummary
    ) -> Q212BoundaryComparison {
        let candidateValues = rawFloatValues(candidate)
        let referenceValues = rawFloatValues(reference)
        return Q212BoundaryComparison(
            name: name,
            source: source,
            candidateShape: candidate.shape,
            candidateDType: q211NormalizedDType(candidate.dtype),
            referenceShape: reference.shape,
            referenceDType: q211NormalizedDType(reference.dtype),
            candidateChecksum: q211Checksum(candidate),
            referenceChecksum: q211Checksum(reference),
            bitExact: candidate.shape == reference.shape
                && q211NormalizedDType(candidate.dtype) == q211NormalizedDType(reference.dtype)
                && q211RawWords(candidate) == q211RawWords(reference),
            relL2: relativeL2(candidateValues, referenceValues),
            maxAbs: maxAbs(candidateValues, referenceValues),
            note: nil)
    }

    private func q212Compare(
        _ name: String,
        source: String,
        candidate: QwenStreamArraySummary,
        reference: Q211PythonArray
    ) -> Q212BoundaryComparison {
        let candidateValues = rawFloatValues(candidate)
        let referenceValues = q211FloatValues(reference)
        return Q212BoundaryComparison(
            name: name,
            source: source,
            candidateShape: candidate.shape,
            candidateDType: q211NormalizedDType(candidate.dtype),
            referenceShape: reference.shape,
            referenceDType: reference.dtype,
            candidateChecksum: q211Checksum(candidate),
            referenceChecksum: reference.checksum,
            bitExact: candidate.shape == reference.shape
                && q211NormalizedDType(candidate.dtype) == reference.dtype
                && q211RawWords(candidate) == reference.rawWords,
            relL2: relativeL2(candidateValues, referenceValues),
            maxAbs: maxAbs(candidateValues, referenceValues),
            note: nil)
    }

    private func rawMLXArray(_ summary: QwenStreamArraySummary) -> MLXArray {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            return MLXArray(data, summary.shape, dtype: .uint16).view(dtype: .bfloat16)
        }
        if let bits = summary.rawUInt32Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            return MLXArray(data, summary.shape, dtype: .uint32).view(dtype: .float32)
        }
        return MLXArray(summary.fullValues ?? summary.sample, summary.shape)
    }

    private func rawFloatValues(_ summary: Summary) -> [Float] {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            return bits.map { Float(bitPattern: UInt32($0) << 16) }
        }
        if let bits = summary.rawUInt32Bits {
            return bits.map { Float(bitPattern: $0) }
        }
        return summary.fullValues ?? summary.values ?? []
    }

    private func rawMLXArray(_ summary: Summary) -> MLXArray {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            return MLXArray(data, summary.shape, dtype: .uint16).view(dtype: .bfloat16)
        }
        if let bits = summary.rawUInt32Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            return MLXArray(data, summary.shape, dtype: .uint32).view(dtype: .float32)
        }
        return MLXArray(summary.fullValues ?? summary.values ?? [], summary.shape)
    }

    private func q211NormalizedDType(_ dtype: String) -> String {
        let lower = dtype.lowercased()
        if lower.contains("bfloat16") { return "bfloat16" }
        if lower.contains("float16") { return "float16" }
        if lower.contains("float32") { return "float32" }
        return lower
    }

    private func q211FloatValues(_ array: Q211PythonArray) -> [Float] {
        switch array.dtype {
        case "bfloat16":
            return array.rawWords.map { Float(bitPattern: $0 << 16) }
        case "float16":
            return array.rawWords.map { Float(Float16(bitPattern: UInt16($0))) }
        case "float32":
            return array.rawWords.map { Float(bitPattern: $0) }
        default:
            return []
        }
    }

    private func q211RawWords(_ summary: QwenStreamArraySummary) -> [UInt32] {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            return bits.map(UInt32.init)
        }
        if let bits = summary.rawUInt32Bits {
            return bits
        }
        return summary.fullValues?.map(\.bitPattern) ?? []
    }

    private func q211RawWords(_ summary: Summary) -> [UInt32] {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            return bits.map(UInt32.init)
        }
        if let bits = summary.rawUInt32Bits {
            return bits
        }
        return summary.fullValues?.map(\.bitPattern) ?? summary.values?.map(\.bitPattern) ?? []
    }

    private func q211Checksum(_ summary: QwenStreamArraySummary) -> String {
        let words = q211RawWords(summary)
        let dtype = q211NormalizedDType(summary.dtype)
        var data = Data(capacity: words.count * (dtype == "float32" ? 4 : 2))
        for word in words {
            if dtype == "float32" {
                var value = word.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            } else {
                var value = UInt16(truncatingIfNeeded: word).littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func q211Checksum(_ summary: Summary) -> String {
        let words = q211RawWords(summary)
        let dtype = q211NormalizedDType(summary.dtype)
        var data = Data(capacity: words.count * (dtype == "float32" ? 4 : 2))
        for word in words {
            if dtype == "float32" {
                var value = word.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            } else {
                var value = UInt16(truncatingIfNeeded: word).littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func q211Worst(
        _ lhs: [Float], _ rhs: [Float]
    ) -> (Int?, Float?, Float?, Float) {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return (nil, nil, nil, .infinity) }
        var index = 0
        var largest: Float = 0
        for (candidateIndex, pair) in zip(lhs.indices, zip(lhs, rhs)) {
            let difference = abs(pair.0 - pair.1)
            if difference > largest {
                largest = difference
                index = candidateIndex
            }
        }
        return (index, lhs[index], rhs[index], largest)
    }

    private func boundaryLayerObject(
        at url: URL,
        group: Int,
        layer: Int
    ) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let document = try dictionary(root, named: "boundary document")
        let groups = try array(document["groups"], named: "groups")
        let groupObject = try dictionary(groups[group], named: "group \(group)")
        let layers = try array(groupObject["layers"], named: "group \(group) layers")
        guard let match = layers.compactMap({ $0 as? [String: Any] })
            .first(where: { ($0["layer"] as? Int) == layer }) else {
            throw NSError(domain: "QwenStreamQ29", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing layer \(layer) in group \(group)"])
        }
        return match
    }

    private func dictionary(_ value: Any?, named: String) throws -> [String: Any] {
        guard let value, let result = value as? [String: Any] else {
            throw NSError(domain: "QwenStreamQ29", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing dictionary: \(named)"])
        }
        return result
    }

    private func array(_ value: Any?, named: String) throws -> [Any] {
        guard let value, let result = value as? [Any] else {
            throw NSError(domain: "QwenStreamQ29", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "missing array: \(named)"])
        }
        return result
    }

    private func decodeSummary(_ value: Any?, named: String) throws -> Summary {
        let object = try dictionary(value, named: named)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Summary.self, from: data)
    }

    private func rawFloatValues(_ summary: QwenStreamArraySummary) -> [Float] {
        if let bits = summary.rawBFloat16Bits ?? summary.rawUInt16Bits {
            return bits.map { Float(bitPattern: UInt32($0) << 16) }
        }
        if let bits = summary.rawUInt32Bits {
            return bits.map { Float(bitPattern: $0) }
        }
        return summary.fullValues ?? summary.sample
    }

    private func floatSHA256(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func relativeL2(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var numerator = 0.0
        var denominator = 0.0
        for (left, right) in zip(lhs, rhs) {
            let delta = Double(left) - Double(right)
            numerator += delta * delta
            denominator += Double(left) * Double(left)
        }
        return sqrt(numerator) / max(sqrt(denominator), 1e-12)
    }

    private func maxAbs(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
    }
}
