import CryptoKit
import Foundation
import MLX
import XCTest
@testable import BeetCode

/// Q2.5 localization diagnostics for the target-only Qwen K=8 path. The
/// reference is a compact, independently produced boundary JSON file. These
/// tests are opt-in because they load the installed 35B model and intentionally
/// remain a validation tool rather than a normal regression suite.
final class QwenStreamQ25LocalizationTests: XCTestCase {
    private let expectedInventorySHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
    private let expectedConfigSHA256 = "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964"
    private let expectedTokenizerSHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
    private let expectedTokenizerConfigSHA256 = "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"
    private let expectedTemplateSHA256 = "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"

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
    }

    private struct Semantics: Decodable {
        let routingK: Int
        let expertCount: Int
        let sharedExpert: Bool
        let thinking: Bool
        let prefillGroupSize: Int
    }

    private struct Summary: Decodable {
        let shape: [Int]
        let dtype: String
        let sample: [Float]
        let tailSample: [Float]?
        let values: [Float]?
        let rawBFloat16Bits: [UInt16]?
    }

    private struct Cache: Decodable {
        let layer: Int?
        let type: String
        let offset: Int
        let state: [Summary]
    }

    private struct Router: Decodable {
        let layer: Int
        let position: Int
        let expertIDs: [Int]
        let scores: [Float]
        let topLogitIDs: [Int]?
        let topLogits: [Float]?

        private enum CodingKeys: String, CodingKey {
            case layer, position, expertIDs, scores, topLogitIDs, topLogits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            layer = try container.decode(Int.self, forKey: .layer)
            position = try container.decode(Int.self, forKey: .position)
            expertIDs = try container.decode([Int].self, forKey: .expertIDs)
            scores = try container.decode([Float].self, forKey: .scores)
            topLogitIDs = try container.decodeIfPresent([Int].self, forKey: .topLogitIDs)
            topLogits = try container.decodeIfPresent([Float].self, forKey: .topLogits)
        }
    }

    private struct Layer: Decodable {
        let layer: Int
        let layerKind: String
        let positionBefore: Int
        let positionAfter: Int
        let input: Summary
        let output: Summary
        let tokenOutputs: [Summary]
        let cache: Cache
        let router: [Router]
        let components: Components?
    }

    private struct Components: Decodable {
        let attentionInput: Summary
        let attentionOutput: Summary
        let postAttentionResidual: Summary?
        let postAttentionInput: Summary
        let mlpOutput: Summary
        let routerInput: Summary
        let routerLogits: Summary
        let routedOutput: Summary
        let sharedOutput: Summary
        let linearProjections: LinearProjections?
        let linearAttention: LinearAttention?
    }

    private struct LinearProjections: Decodable {
        let qkv: Summary
        let z: Summary
        let b: Summary
        let a: Summary
    }

    private struct LinearAttention: Decodable {
        let convOutput: Summary
        let qNormed: Summary
        let kNormed: Summary
        let v: Summary
        let gatedOutput: Summary
        let normalizedOutput: Summary
    }

    private struct QKVFixtureArtifact: Decodable {
        let repo: String
        let revision: String
        let inventorySHA256: String
    }

    private struct QKVFixtureSemantics: Decodable {
        let layer: Int
        let module: String
        let routingK: Int
        let transpose: Bool
        let bits: Int
        let groupSize: Int
        let mode: String
        let inputDType: String
        let weightDType: String
        let outputDType: String
    }

    private struct QKVFixtureTensor: Decodable {
        let dtype: String
        let shape: [Int]
        let payloadOffset: Int
        let byteCount: Int
        let shard: String
    }

    private struct QKVFixtureCase: Decodable {
        let groupIndex: Int
        let positionBefore: Int
        let positionAfter: Int
        let tokenIDs: [Int]
        let inputShape: [Int]
        let outputShape: [Int]
        let input: String
        let nativeInput: String
        let referenceOutput: String
        let nativeOutput: String
    }

    private struct QKVFixture: Decodable {
        let format: String
        let artifact: QKVFixtureArtifact
        let semantics: QKVFixtureSemantics
        let tensors: [String: QKVFixtureTensor]
        let tensorFiles: [String: String]
        let cases: [QKVFixtureCase]
        let promptTokenIDs: [Int]
        let promptTokenCount: Int
    }

    private struct Embedding: Decodable {
        let output: Summary
    }

    private struct Group: Decodable {
        let groupIndex: Int
        let positionBefore: Int
        let positionAfter: Int
        let tokenIDs: [Int]
        let embedding: Embedding
        let layers: [Layer]
    }

    private struct Boundary: Decodable {
        let fixtureFormatVersion: String
        let fixtureID: String
        let artifact: Artifact
        let configSHA256: String
        let tokenizerSHA256: String
        let tokenizerConfigSHA256: String
        let templateSHA256: String
        let oracle: Oracle
        let semantics: Semantics
        let promptTokenIDs: [Int]
        let promptTokenCount: Int
        let promptSHA256: String
        let prefillGroupSize: Int
        let boundaryLayerCount: Int
        let groups: [Group]
    }

    private struct SelectorVector: Decodable {
        let name: String
        let source: String
        let layer: Int
        let position: Int
        let shape: [Int]
        let dtype: String
        let values: [Float]
        let rawBFloat16Bits: [UInt16]
        let routerInputShape: [Int]
        let routerInputDType: String
        let routerInputValues: [Float]
        let routerInputRawBFloat16Bits: [UInt16]
        let selectionScores: [Float]
        let selectionRawBFloat16Bits: [UInt16]
        let recordedExpertIDs: [Int]
        let recordedScores: [Float]
    }

    private struct SelectorFixture: Decodable {
        let format: String
        let routingK: Int
        let selection: Selection
        let vectors: [SelectorVector]

        struct Selection: Decodable {
            let expertAxis: Int
            let softmaxPrecise: Bool
            let normTopkProb: Bool
            let referencePartitionKth: Int
            let nativePartitionKth: Int
            let finalSliceLength: Int
        }
    }

    private struct SelectorResult: Encodable {
        let name: String
        let source: String
        let layer: Int
        let position: Int
        let device: String
        let inputDType: String
        let softmaxDType: String
        let expertIDs: [Int]
        let selectionScores: [Float]
        let scores: [Float]
        let recordedSetEqual: Bool
        let recordedOrderEqual: Bool
    }

    func testOptInPrefillBoundaryLocalization() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_BOUNDARY"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q25_BOUNDARY=1 for target-only Qwen boundary localization.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_BOUNDARY_FIXTURE"]
            ?? "/tmp/qwen35-k8-q25-boundary/boundary.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Q2.5 boundary fixture is not present at \(path).")
        }
        let reference = try JSONDecoder().decode(
            Boundary.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        validateIdentity(reference)
        XCTAssertEqual(reference.promptTokenIDs.count, reference.promptTokenCount)
        XCTAssertEqual(reference.prefillGroupSize, 4)
        XCTAssertEqual(reference.groups.count, (reference.promptTokenCount + 3) / 4)
        XCTAssertEqual(reference.promptSHA256, promptHash(reference.promptTokenIDs))

        let directory = modelDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }

        let layers: [Int] = reference.groups.flatMap { group in
            group.layers.map { $0.layer }
        }
        let selectedLayers: [Int] = Array(Set<Int>(layers)).sorted()
        XCTAssertFalse(selectedLayers.isEmpty)
        XCTAssertEqual(selectedLayers.count, reference.boundaryLayerCount)

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: reference.promptTokenIDs,
            boundaryLayers: selectedLayers)
        if let output = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(native).write(
                to: URL(fileURLWithPath: output),
                options: .atomic)
        }

        XCTAssertEqual(native.promptTokenIDs, reference.promptTokenIDs)
        XCTAssertEqual(native.prefillGroupSize, reference.prefillGroupSize)
        XCTAssertEqual(native.groups.count, reference.groups.count)
        for (expected, actual) in zip(reference.groups, native.groups) {
            let groupContext = "prefill group \(expected.groupIndex)"
            XCTAssertEqual(actual.groupIndex, expected.groupIndex, groupContext)
            XCTAssertEqual(actual.positionBefore, expected.positionBefore, groupContext)
            XCTAssertEqual(actual.positionAfter, expected.positionAfter, groupContext)
            XCTAssertEqual(actual.tokenIDs, expected.tokenIDs, groupContext)
            compareSummary(
                expected.embedding.output,
                actual.embedding,
                context: "\(groupContext) embedding")
            XCTAssertEqual(actual.layers.map(\.layer), expected.layers.map(\.layer), groupContext)
            for (expectedLayer, actualLayer) in zip(expected.layers, actual.layers) {
                let context = "\(groupContext) layer \(expectedLayer.layer)"
                let expectedKind = expectedLayer.layerKind == "linear_attention"
                    ? "GatedDeltaNet/MambaCache" : "FullAttention/KVCache"
                XCTAssertEqual(actualLayer.kind, expectedKind, context)
                XCTAssertEqual(actualLayer.positionBefore, expectedLayer.positionBefore, context)
                XCTAssertEqual(actualLayer.positionAfter, expectedLayer.positionAfter, context)
                compareSummary(expectedLayer.input, actualLayer.input, context: "\(context) input")
                compareSummary(expectedLayer.output, actualLayer.output, context: "\(context) output")
                if let expectedComponents = expectedLayer.components,
                   let actualComponents = actualLayer.components {
                    compareComponents(expectedComponents, actualComponents, context: context)
                } else {
                    XCTFail("\(context) component decomposition is missing")
                }
                XCTAssertEqual(actualLayer.tokenOutputs.count, expectedLayer.tokenOutputs.count, context)
                for (index, pair) in zip(expectedLayer.tokenOutputs, actualLayer.tokenOutputs).enumerated() {
                    compareSummary(pair.0, pair.1, context: "\(context) token \(index)")
                }
                compareCache(expectedLayer.cache, actualLayer.cache, context: context)
                compareRouters(expectedLayer.router, actualLayer.router, context: context)
            }
        }
        let state = await engine.debugQuiescence()
        XCTAssertFalse(state.ownerActive)
        XCTAssertFalse(state.poolBusy)
        print("[qwen-q25-boundary] groups=\(native.groups.count) layers=\(selectedLayers) output=\(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_NATIVE_OUTPUT"] ?? "not-written")")
    }

    func testOptInTeacherForcedDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_TEACHER_FORCED"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q25_TEACHER_FORCED=1 for teacher-forced Qwen diagnostics.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_REFERENCE"]
            ?? ProcessInfo.processInfo.environment["BEETCODE_QWEN35_LONG_REFERENCE"]
            ?? "/tmp/qwen35-k8-long-reference-q21.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Q2.5 teacher-forcing source fixture is not present at \(path).")
        }
        struct IDs: Decodable {
            let promptTokenIDs: [Int]
            let generatedTokenIDs: [Int]
        }
        let ids = try JSONDecoder().decode(IDs.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(ids.promptTokenIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(ids.generatedTokenIDs.count, 1)
        let directory = modelDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }
        let checkpointSteps = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_TEACHER_STEPS"]
            .map { raw in
                raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? [-1, 1, 2, 4, 8, 16, 32, 64]
        let run = try await engine.debugTeacherForced(
            tokenIDs: ids.promptTokenIDs,
            forcedTokenIDs: ids.generatedTokenIDs,
            checkpointSteps: checkpointSteps)
        XCTAssertEqual(run.promptTokenIDs, ids.promptTokenIDs)
        XCTAssertEqual(run.forcedTokenIDs, ids.generatedTokenIDs)
        XCTAssertEqual(run.prefillCallCount, (ids.promptTokenIDs.count + 3) / 4)
        XCTAssertEqual(run.cachedDecodeCallCount, ids.generatedTokenIDs.count)
        XCTAssertFalse(run.checkpoints.isEmpty)
        if let output = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_TEACHER_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(run).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let state = await engine.debugQuiescence()
        XCTAssertFalse(state.ownerActive)
        XCTAssertFalse(state.poolBusy)
        print("[qwen-q25-teacher] forced=\(run.forcedTokenIDs.count) cachedCalls=\(run.cachedDecodeCallCount) output=\(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_TEACHER_OUTPUT"] ?? "not-written")")
    }

    /// Tiny selector-only replay for the two Q2.5 membership mismatches.  It
    /// never loads the model: complete 256-wide BF16 router rows are supplied
    /// by the compact fixture, then the exact native MLX softmax/argPartition
    /// expression is run on the current default backend (Metal on the Mac).
    func testOptInRouterSelectorReplay() throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_SELECTOR"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q25_SELECTOR=1 for tiny Qwen selector replay.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_SELECTOR_FIXTURE"]
            ?? "/tmp/qwen35-k8-q25-selector-input-v6.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Q2.5 selector fixture is not present at \(path).")
        }
        let fixture = try JSONDecoder().decode(
            SelectorFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fixture.format, "qwen35-k8-router-selector-input-v1")
        XCTAssertEqual(fixture.routingK, QwenStreamArtifact.routingK)
        XCTAssertEqual(fixture.selection.expertAxis, -1)
        XCTAssertTrue(fixture.selection.softmaxPrecise)
        XCTAssertTrue(fixture.selection.normTopkProb)
        XCTAssertEqual(fixture.selection.nativePartitionKth, 256 - fixture.routingK)
        XCTAssertEqual(fixture.selection.finalSliceLength, fixture.routingK)

        let device = Device.defaultDevice().deviceType?.rawValue ?? "unavailable"
        var results: [SelectorResult] = []
        for vector in fixture.vectors {
            XCTAssertEqual(vector.dtype, "bfloat16", vector.name)
            XCTAssertEqual(vector.shape.reduce(1, *), vector.values.count, vector.name)
            XCTAssertEqual(vector.shape.last ?? -1, 256, vector.name)

            // The boundary summaries contain BF16 values represented as exact
            // Float scalars.  Convert once at the fixture boundary, then keep
            // the original model dtype for softmax and partition.
            XCTAssertEqual(vector.rawBFloat16Bits.count, vector.values.count, vector.name)
            XCTAssertEqual(vector.selectionRawBFloat16Bits.count, vector.selectionScores.count, vector.name)
            let rawValues = vector.rawBFloat16Bits.map { Float(bitPattern: UInt32($0) << 16) }
            XCTAssertEqual(rawValues, vector.values, "\(vector.name) raw BF16 logits")
            let source = MLXArray(rawValues, vector.shape)
            let logits = source.asType(.bfloat16)
            MLX.eval(logits)
            let roundTrip = logits.asType(.float32).asArray(Float.self)
            let conversionError = maxAbs(roundTrip, vector.values)
            XCTAssertLessThanOrEqual(conversionError, 0, "\(vector.name) BF16 fixture conversion")

            let gates = MLX.softmax(logits, axis: fixture.selection.expertAxis, precise: true)
            let kth = logits.dim(-1) - fixture.routingK
            XCTAssertEqual(kth, fixture.selection.nativePartitionKth, vector.name)
            let partitioned = MLX.argPartition(gates, kth: kth, axis: fixture.selection.expertAxis)
            let expertIDs = partitioned[.ellipsis, kth...]
            let selectionScores = MLX.takeAlong(gates, expertIDs, axis: fixture.selection.expertAxis)
            var scores = selectionScores
            if fixture.selection.normTopkProb {
                scores = selectionScores / selectionScores.sum(axis: -1, keepDims: true)
            }
            MLX.eval(gates, partitioned, expertIDs, selectionScores, scores)

            let actualIDs = expertIDs.asArray(Int.self)
            let actualSelectionScores = selectionScores.asArray(Float.self)
            let actualScores = scores.asArray(Float.self)
            let actualSet = Set(actualIDs)
            let recordedSet = Set(vector.recordedExpertIDs)
            XCTAssertEqual(actualSet, recordedSet, "\(vector.name) native selector set")
            let scoreByID = Dictionary(uniqueKeysWithValues: zip(actualIDs, actualScores))
            let recordedByID = Dictionary(uniqueKeysWithValues: zip(vector.recordedExpertIDs, vector.recordedScores))
            let pairedIDs = vector.recordedExpertIDs.filter { scoreByID[$0] != nil }
            let pairedActual = pairedIDs.compactMap { scoreByID[$0] }
            let pairedRecorded = pairedIDs.compactMap { recordedByID[$0] }
            XCTAssertLessThanOrEqual(relativeL2(pairedActual, pairedRecorded), 0.03, "\(vector.name) native scores")

            let result = SelectorResult(
                name: vector.name,
                source: vector.source,
                layer: vector.layer,
                position: vector.position,
                device: device,
                inputDType: String(describing: logits.dtype),
                softmaxDType: String(describing: gates.dtype),
                expertIDs: actualIDs,
                selectionScores: actualSelectionScores,
                scores: actualScores,
                recordedSetEqual: actualSet == recordedSet,
                recordedOrderEqual: actualIDs == vector.recordedExpertIDs)
            results.append(result)
            print("[qwen-q25-selector] \(vector.name) device=\(device) ids=\(actualIDs) recordedSetEqual=\(actualSet == recordedSet) recordedOrderEqual=\(actualIDs == vector.recordedExpertIDs)")
        }

        if let output = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_SELECTOR_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: [
                "format": "qwen35-k8-router-selector-native-v1",
                "device": device,
                "routingK": fixture.routingK,
                "results": results.map { result in
                    [
                        "name": result.name,
                        "source": result.source,
                        "layer": result.layer,
                        "position": result.position,
                        "device": result.device,
                        "inputDType": result.inputDType,
                        "softmaxDType": result.softmaxDType,
                        "expertIDs": result.expertIDs,
                        "selectionScores": result.selectionScores,
                        "scores": result.scores,
                        "recordedSetEqual": result.recordedSetEqual,
                        "recordedOrderEqual": result.recordedOrderEqual,
                    ] as [String: Any]
                },
            ], options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    /// Gate-input localization for the rows whose native logits differ.  The
    /// native quantized projection reads only the small resident router gate;
    /// no full model or expert payload is loaded by this test.
    func testOptInRouterGateInputReplay() throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_GATE"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q25_GATE=1 for gate-input replay.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_SELECTOR_FIXTURE"]
            ?? "/tmp/qwen35-k8-q25-selector-input-v6.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Q2.5 selector fixture is not present at \(path).")
        }
        let fixture = try JSONDecoder().decode(
            SelectorFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = modelDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }
        let selected = fixture.vectors.filter { $0.source == "reference" }
        XCTAssertEqual(selected.count, 3)
        var output: [[String: Any]] = []
        for vector in selected {
            XCTAssertEqual(vector.routerInputDType, "bfloat16", vector.name)
            XCTAssertEqual(vector.routerInputShape.last ?? -1, 2048, vector.name)
            XCTAssertEqual(vector.routerInputShape.reduce(1, *), vector.routerInputValues.count, vector.name)
            XCTAssertEqual(vector.routerInputRawBFloat16Bits.count, vector.routerInputValues.count, vector.name)
            let rawInputValues = vector.routerInputRawBFloat16Bits.map { Float(bitPattern: UInt32($0) << 16) }
            XCTAssertEqual(rawInputValues, vector.routerInputValues, "\(vector.name) raw BF16 router input")
            let nativeLogits = try QwenStreamReferenceAudit.routerGateProjection(
                directory: directory,
                layer: vector.layer,
                input: rawInputValues,
                shape: vector.routerInputShape)
            XCTAssertEqual(nativeLogits.count, vector.values.count, vector.name)
            let rel = relativeL2(nativeLogits, vector.values)
            let abs = maxAbs(nativeLogits, vector.values)
            print("[qwen-q25-gate] \(vector.name) relL2=\(rel) maxAbs=\(abs)")
            XCTAssertLessThanOrEqual(rel, 0.03, "\(vector.name) native gate logits")
            XCTAssertLessThanOrEqual(abs, 0.05, "\(vector.name) native gate logits maxAbs")
            output.append([
                "name": vector.name,
                "source": vector.source,
                "layer": vector.layer,
                "position": vector.position,
                "inputDType": vector.routerInputDType,
                "outputDType": "bfloat16",
                "relL2": rel,
                "maxAbs": abs,
                "nativeLogits": nativeLogits,
            ])
        }
        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_GATE_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: [
                "format": "qwen35-k8-router-gate-input-native-v1",
                "artifactRevision": QwenStreamArtifact.revision,
                "results": output,
            ], options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    /// Q2.6 diagnostic trace for the first two four-token chunks. It retains
    /// complete bounded activation rows and reports numerical errors for the
    /// layer-0 path before expert selection. This is deliberately a diagnostic
    /// pass: a nonzero result identifies the next operation to inspect and is
    /// not a parity assertion.
    func testOptInLayer0ActivationTrace() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_ACTIVATION_TRACE"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q25_ACTIVATION_TRACE=1 for bounded layer-0 activation diagnostics.")
        }
        let path = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_ACTIVATION_REFERENCE"]
            ?? "/tmp/qwen35-k8-q25-activation-reference/boundary.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Q2.6 activation fixture is not present at \(path).")
        }
        let reference = try JSONDecoder().decode(
            Boundary.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        validateIdentity(reference)
        XCTAssertEqual(reference.prefillGroupSize, 4)
        XCTAssertEqual(reference.promptTokenCount, 8)
        XCTAssertEqual(reference.groups.count, 2)

        let directory = modelDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }
        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let native = try await engine.debugPrefillBoundaries(
            tokenIDs: reference.promptTokenIDs,
            boundaryLayers: [0],
            captureFullComponents: true)
        // Keep the complete native boundary beside the activation report so
        // the linear-attention subpath can be compared offline on the same
        // exact inputs. This is opt-in diagnostic output only; normal
        // generation never retains these tensors.
        if let nativeOutput = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_NATIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(native).write(
                to: URL(fileURLWithPath: nativeOutput),
                options: .atomic)
        }
        XCTAssertEqual(native.promptTokenIDs, reference.promptTokenIDs)
        XCTAssertEqual(native.groups.count, reference.groups.count)

        var rows: [[String: Any]] = []
        for (expectedGroup, actualGroup) in zip(reference.groups, native.groups) {
            XCTAssertEqual(actualGroup.positionBefore, expectedGroup.positionBefore)
            XCTAssertEqual(actualGroup.positionAfter, expectedGroup.positionAfter)
            XCTAssertEqual(actualGroup.tokenIDs, expectedGroup.tokenIDs)
            guard let expectedLayer = expectedGroup.layers.first,
                  let actualLayer = actualGroup.layers.first,
                  let expectedComponents = expectedLayer.components,
                  let actualComponents = actualLayer.components else {
                XCTFail("Q2.6 layer-0 activation components are missing")
                continue
            }

            let positions = expectedGroup.positionBefore..<expectedGroup.positionAfter
            let expectedSummaryPairs: [(String, Summary, QwenStreamArraySummary)] = [
                ("embedding", expectedGroup.embedding.output, actualGroup.embedding),
                ("inputNormalization", expectedComponents.attentionInput, actualComponents.attentionInput),
                ("attentionOutput", expectedComponents.attentionOutput, actualComponents.attentionOutput),
                ("postAttentionResidual", expectedComponents.postAttentionResidual ?? expectedComponents.attentionOutput, actualComponents.postAttentionResidual),
                ("postAttentionNormalization", expectedComponents.postAttentionInput, actualComponents.postAttentionInput),
                ("routerLogits", expectedComponents.routerLogits, actualComponents.routerLogits),
            ]

            for position in positions {
                let tokenIndex = position - expectedGroup.positionBefore
                var operationMetrics: [[String: Any]] = []
                for (name, expectedSummary, actualSummary) in expectedSummaryPairs {
                    guard let expectedValues = completeValues(expectedSummary),
                          let actualValues = completeValues(actualSummary) else {
                        XCTFail("Q2.6 full values are missing for \(name) at position \(position)")
                        continue
                    }
                    let expectedRow = row(expectedValues, shape: expectedSummary.shape, tokenIndex: tokenIndex)
                    let actualRow = row(actualValues, shape: actualSummary.shape, tokenIndex: tokenIndex)
                    let metric = activationMetric(
                        name: name,
                        reference: expectedRow,
                        native: actualRow,
                        shape: [expectedRow.count],
                        referenceDType: expectedSummary.dtype,
                        nativeDType: actualSummary.dtype)
                    operationMetrics.append(metric)
                }

                if let expectedRouter = expectedGroup.layers[0].router.first(where: { $0.position == position }),
                   let actualRouter = routerRecord(actualLayer.router, position: position) {
                    let expectedByID = Dictionary(uniqueKeysWithValues: zip(expectedRouter.expertIDs, expectedRouter.scores))
                    let actualByID = Dictionary(uniqueKeysWithValues: zip(actualRouter.expertIDs, actualRouter.scores))
                    let common = expectedRouter.expertIDs.filter { actualByID[$0] != nil }
                    let expectedScores = common.compactMap { expectedByID[$0] }
                    let actualScores = common.compactMap { actualByID[$0] }
                    operationMetrics.append(activationMetric(
                        name: "selectionScores",
                        reference: expectedScores,
                        native: actualScores,
                        shape: [common.count],
                        referenceDType: "bfloat16",
                        nativeDType: "bfloat16"))
                }

                let firstDifference = operationMetrics.first {
                    (($0["relativeL2"] as? Double) ?? 0) > 1e-7
                }?["name"] as? String
                let rowReport: [String: Any] = [
                    "position": position,
                    "chunkIndex": expectedGroup.groupIndex,
                    "tokenID": expectedGroup.tokenIDs[tokenIndex],
                    "positionBeforeChunk": expectedGroup.positionBefore,
                    "positionAfterChunk": expectedGroup.positionAfter,
                    "firstDifferingOperation": firstDifference as Any,
                    "operations": operationMetrics,
                ]
                rows.append(rowReport)
                let headline = operationMetrics.map { metric in
                    "\(metric["name"] ?? "?") relL2=\(metric["relativeL2"] ?? "?") maxAbs=\(metric["maxAbs"] ?? "?")"
                }.joined(separator: "; ")
                print("[qwen-q25-activation] position=\(position) first=\(firstDifference ?? "none") \(headline)")
            }
        }

        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_ACTIVATION_OUTPUT"] {
            let report: [String: Any] = [
                "format": "qwen35-k8-q25-layer0-activation-report-v1",
                "artifactRevision": QwenStreamArtifact.revision,
                "routingK": QwenStreamArtifact.routingK,
                "promptTokenIDs": reference.promptTokenIDs,
                "promptSHA256": reference.promptSHA256,
                "prefillGroupSize": reference.prefillGroupSize,
                "groupsCompared": reference.groups.count,
                "nativeDevice": Device.defaultDevice().deviceType?.rawValue ?? "unavailable",
                "rows": rows,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        let state = await engine.debugQuiescence()
        XCTAssertFalse(state.ownerActive)
        XCTAssertFalse(state.poolBusy)
        print("[qwen-q25-activation] rows=\(rows.count) output=\(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q25_ACTIVATION_OUTPUT"] ?? "not-written")")
    }

    /// Q2.6 operator-only replay.  A is the production Vampire Assistant
    /// wrapper, while B invokes the same native MLX quantized primitive with
    /// the fixture's raw inputs and checkpoint bytes.  The test deliberately
    /// records the known A/B result against both independently generated
    /// boundary outputs; a mismatch against the saved reference is evidence
    /// for the runtime matrix, not a reason to change Qwen semantics.
    func testOptInQwenK8QKVOperatorReplay() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q26_QKV_OPERATOR"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q26_QKV_OPERATOR=1 for the bounded QKV operator matrix.")
        }
        let fixturePath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q26_QKV_FIXTURE"]
            ?? "/tmp/qwen35-k8-q26-qkv-operator-v1"
        let fixtureDirectory = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let metadataURL = fixtureDirectory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw XCTSkip("Q2.6 QKV operator fixture is not present at \(metadataURL.path).")
        }
        let fixture = try JSONDecoder().decode(
            QKVFixture.self,
            from: Data(contentsOf: metadataURL))
        XCTAssertEqual(fixture.format, "qwen35-k8-qkv-operator-v1")
        XCTAssertEqual(fixture.artifact.repo, QwenStreamArtifact.repo)
        XCTAssertEqual(fixture.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(fixture.artifact.inventorySHA256, expectedInventorySHA256)
        XCTAssertEqual(fixture.semantics.layer, 0)
        XCTAssertEqual(fixture.semantics.module, "linear_attn.in_proj_qkv")
        XCTAssertEqual(fixture.semantics.routingK, 8)
        XCTAssertTrue(fixture.semantics.transpose)
        XCTAssertEqual(fixture.semantics.bits, 4)
        XCTAssertEqual(fixture.semantics.groupSize, 64)
        XCTAssertEqual(fixture.semantics.mode, "affine")
        XCTAssertEqual(fixture.semantics.inputDType, "bfloat16")
        XCTAssertEqual(fixture.semantics.weightDType, "uint32")
        XCTAssertEqual(fixture.semantics.outputDType, "bfloat16")
        XCTAssertEqual(fixture.promptTokenCount, fixture.promptTokenIDs.count)
        XCTAssertEqual(fixture.cases.count, 2)

        let directory = modelDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }
        guard let weightName = fixture.tensorFiles["weight"],
              let scalesName = fixture.tensorFiles["scales"],
              let biasesName = fixture.tensorFiles["biases"],
              let weightMetadata = fixture.tensors[QKVFixtureTensorName.weight],
              let scalesMetadata = fixture.tensors[QKVFixtureTensorName.scales],
              let biasesMetadata = fixture.tensors[QKVFixtureTensorName.biases] else {
            XCTFail("Q2.6 QKV fixture tensor metadata is incomplete")
            return
        }
        XCTAssertEqual(weightMetadata.shape, [8192, 256])
        XCTAssertEqual(scalesMetadata.shape, [8192, 32])
        XCTAssertEqual(biasesMetadata.shape, [8192, 32])
        XCTAssertEqual(weightMetadata.dtype.lowercased(), "u32")
        XCTAssertEqual(scalesMetadata.dtype.lowercased(), "bf16")
        XCTAssertEqual(biasesMetadata.dtype.lowercased(), "bf16")

        let weightData = try Data(contentsOf: fixtureDirectory.appendingPathComponent(weightName))
        let scalesData = try Data(contentsOf: fixtureDirectory.appendingPathComponent(scalesName))
        let biasesData = try Data(contentsOf: fixtureDirectory.appendingPathComponent(biasesName))
        XCTAssertEqual(weightData.count, weightMetadata.byteCount)
        XCTAssertEqual(scalesData.count, scalesMetadata.byteCount)
        XCTAssertEqual(biasesData.count, biasesMetadata.byteCount)

        // Keep the exact checkpoint representation through the native API.
        // The BF16 companions are reinterpreted from their raw UInt16 words;
        // no decimal conversion or dequantized resident copy is introduced.
        let weight = MLXArray(weightData, weightMetadata.shape, dtype: .uint32)
        let scales = MLXArray(scalesData, scalesMetadata.shape, dtype: .uint16).view(dtype: .bfloat16)
        let biases = MLXArray(biasesData, biasesMetadata.shape, dtype: .uint16).view(dtype: .bfloat16)
        MLX.eval(weight, scales, biases)

        let engine = QwenStreamingEngine(gate: GenerationGate())
        try await engine.load(
            directory: directory,
            modelID: QwenStreamArtifact.modelID,
            diskBytes: QwenStreamArtifact.downloadBytes,
            contextSize: 4096)
        defer { Task { await engine.unload() } }

        let nativeBoundary = try await engine.debugPrefillBoundaries(
            tokenIDs: fixture.promptTokenIDs,
            boundaryLayers: [0],
            captureFullComponents: true)
        XCTAssertEqual(nativeBoundary.promptTokenIDs, fixture.promptTokenIDs)
        XCTAssertEqual(nativeBoundary.groups.count, fixture.cases.count)

        var rows: [[String: Any]] = []
        for testCase in fixture.cases {
            guard let group = nativeBoundary.groups.first(where: { $0.groupIndex == testCase.groupIndex }),
                  let layer = group.layers.first(where: { $0.layer == 0 }),
                  let components = layer.components,
                  let projections = components.linearProjections else {
                XCTFail("native QKV boundary is missing group \(testCase.groupIndex)")
                continue
            }
            XCTAssertEqual(group.positionBefore, testCase.positionBefore)
            XCTAssertEqual(group.positionAfter, testCase.positionAfter)
            XCTAssertEqual(group.tokenIDs, testCase.tokenIDs)
            XCTAssertEqual(components.attentionInput.shape, testCase.inputShape)
            XCTAssertEqual(projections.qkv.shape, testCase.outputShape)

            let expectedInput = try Data(contentsOf: fixtureDirectory.appendingPathComponent(testCase.input))
            let expectedNativeInput = try Data(contentsOf: fixtureDirectory.appendingPathComponent(testCase.nativeInput))
            XCTAssertEqual(expectedInput, expectedNativeInput, "fixture group \(testCase.groupIndex) input")
            let actualInputBits = try XCTUnwrap(components.attentionInput.rawBFloat16Bits)
            let actualQKVBits = try XCTUnwrap(projections.qkv.rawBFloat16Bits)
            let expectedInputBits = expectedInput.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: UInt16.self))
            }
            XCTAssertEqual(actualInputBits, expectedInputBits, "A input bytes group \(testCase.groupIndex)")

            let input = MLXArray(expectedInput, testCase.inputShape, dtype: .uint16).view(dtype: .bfloat16)
            let directNative = MLX.quantizedMM(
                input,
                weight,
                scales: scales,
                biases: biases,
                transpose: fixture.semantics.transpose,
                groupSize: fixture.semantics.groupSize,
                bits: fixture.semantics.bits,
                mode: .affine)
            MLX.eval(directNative)
            let directBits = directNative.view(dtype: .uint16).flattened().asArray(UInt16.self)
            let expectedNativeOutput = try Data(contentsOf: fixtureDirectory.appendingPathComponent(testCase.nativeOutput))
            let expectedReferenceOutput = try Data(contentsOf: fixtureDirectory.appendingPathComponent(testCase.referenceOutput))
            let expectedNativeBits = expectedNativeOutput.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: UInt16.self))
            }
            let expectedReferenceBits = expectedReferenceOutput.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: UInt16.self))
            }
            XCTAssertEqual(actualQKVBits, expectedNativeBits, "A saved native output group \(testCase.groupIndex)")
            XCTAssertEqual(directBits, actualQKVBits, "A/B native quantizedMM group \(testCase.groupIndex)")

            let actualValues = actualQKVBits.map { Float(bitPattern: UInt32($0) << 16) }
            let referenceValues = expectedReferenceBits.map { Float(bitPattern: UInt32($0) << 16) }
            let nativeMetric = activationMetric(
                name: "qkv-vs-reference",
                reference: referenceValues,
                native: actualValues,
                shape: testCase.outputShape,
                referenceDType: "bfloat16",
                nativeDType: "bfloat16")
            let row: [String: Any] = [
                "groupIndex": testCase.groupIndex,
                "positionBefore": testCase.positionBefore,
                "positionAfter": testCase.positionAfter,
                "inputShape": testCase.inputShape,
                "outputShape": testCase.outputShape,
                "inputBytesEqual": actualInputBits == expectedInputBits,
                "aBytesEqualSavedNative": actualQKVBits == expectedNativeBits,
                "bBytesEqualA": directBits == actualQKVBits,
                "aBytesEqualReference": actualQKVBits == expectedReferenceBits,
                "nativeVsReference": nativeMetric,
            ]
            rows.append(row)
            print(
                "[qwen-q26-qkv] group=\(testCase.groupIndex) " +
                    "A_saved_native=\(actualQKVBits == expectedNativeBits) " +
                    "B_A=\(directBits == actualQKVBits) " +
                    "A_reference=\(actualQKVBits == expectedReferenceBits) " +
                    "relL2=\(nativeMetric["relativeL2"] ?? "?") " +
                    "maxAbs=\(nativeMetric["maxAbs"] ?? "?")")
        }

        // The matched M=4 matrix is the acceptance case.  Once it has
        // completed, replay one M=1 dispatch to expose any shape-specific
        // quantized kernel path without changing the production strategy.
        if let firstCase = fixture.cases.first {
            let fullInput = try Data(contentsOf: fixtureDirectory.appendingPathComponent(firstCase.input))
            let oneInputByteCount = firstCase.inputShape[2] * MemoryLayout<UInt16>.size
            let oneInput = Data(fullInput.prefix(oneInputByteCount))
            let oneBoundary = try await engine.debugPrefillBoundaries(
                tokenIDs: Array(fixture.promptTokenIDs.prefix(1)),
                boundaryLayers: [0],
                captureFullComponents: true)
            guard let oneLayer = oneBoundary.groups.first?.layers.first,
                  let oneComponents = oneLayer.components,
                  let oneProjections = oneComponents.linearProjections else {
                XCTFail("native M=1 QKV boundary is missing")
                return
            }
            let oneInputArray = MLXArray(oneInput, [1, 1, firstCase.inputShape[2]], dtype: .uint16)
                .view(dtype: .bfloat16)
            let oneDirect = MLX.quantizedMM(
                oneInputArray,
                weight,
                scales: scales,
                biases: biases,
                transpose: fixture.semantics.transpose,
                groupSize: fixture.semantics.groupSize,
                bits: fixture.semantics.bits,
                mode: .affine)
            MLX.eval(oneDirect)
            let oneDirectBits = oneDirect.view(dtype: .uint16).flattened().asArray(UInt16.self)
            let oneABits = try XCTUnwrap(oneProjections.qkv.rawBFloat16Bits)
            let oneExpectedNative = try Data(contentsOf: fixtureDirectory.appendingPathComponent(firstCase.nativeOutput))
            let oneExpectedReference = try Data(contentsOf: fixtureDirectory.appendingPathComponent(firstCase.referenceOutput))
            let oneNativeBits = Array(oneExpectedNative.withUnsafeBytes { $0.bindMemory(to: UInt16.self) }.prefix(oneDirectBits.count))
            let oneReferenceBits = Array(oneExpectedReference.withUnsafeBytes { $0.bindMemory(to: UInt16.self) }.prefix(oneDirectBits.count))
            XCTAssertEqual(oneABits, oneNativeBits, "A saved native M=1 output")
            XCTAssertEqual(oneDirectBits, oneABits, "A/B native M=1 quantizedMM")
            let oneNativeValues = oneABits.map { Float(bitPattern: UInt32($0) << 16) }
            let oneReferenceValues = oneReferenceBits.map { Float(bitPattern: UInt32($0) << 16) }
            let oneMetric = activationMetric(
                name: "qkv-m1-vs-reference",
                reference: oneReferenceValues,
                native: oneNativeValues,
                shape: [1, 1, firstCase.outputShape[2]],
                referenceDType: "bfloat16",
                nativeDType: "bfloat16")
            rows.append([
                "shapeCase": "M1",
                "groupIndex": firstCase.groupIndex,
                "inputShape": [1, 1, firstCase.inputShape[2]],
                "outputShape": [1, 1, firstCase.outputShape[2]],
                "aBytesEqualSavedNative": oneABits == oneNativeBits,
                "bBytesEqualA": oneDirectBits == oneABits,
                "aBytesEqualReference": oneABits == oneReferenceBits,
                "nativeVsReference": oneMetric,
            ])
            print(
                "[qwen-q26-qkv] M=1 " +
                    "A_saved_native=\(oneABits == oneNativeBits) " +
                    "B_A=\(oneDirectBits == oneABits) " +
                    "A_reference=\(oneABits == oneReferenceBits) " +
                    "relL2=\(oneMetric["relativeL2"] ?? "?") " +
                    "maxAbs=\(oneMetric["maxAbs"] ?? "?")")
        }

        if let outputPath = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q26_QKV_OUTPUT"] {
            let report: [String: Any] = [
                "format": "qwen35-k8-qkv-operator-native-result-v1",
                "artifactRevision": QwenStreamArtifact.revision,
                "artifactInventorySHA256": expectedInventorySHA256,
                "nativePackage": "mlx-swift 0.31.6",
                "nativeMLXCore": "0.31.1",
                "nativeMLXC": "0.6.0",
                "device": Device.defaultDevice().deviceType?.rawValue ?? "unavailable",
                "promptTokenCount": fixture.promptTokenCount,
                "promptTokenIDs": fixture.promptTokenIDs,
                "groups": rows,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        let state = await engine.debugQuiescence()
        XCTAssertFalse(state.ownerActive)
        XCTAssertFalse(state.poolBusy)
        print("[qwen-q26-qkv] groups=\(rows.count) output=\(ProcessInfo.processInfo.environment["BEETCODE_QWEN35_Q26_QKV_OUTPUT"] ?? "not-written")")
    }

    private enum QKVFixtureTensorName {
        static let weight = "language_model.model.layers.0.linear_attn.in_proj_qkv.weight"
        static let scales = "language_model.model.layers.0.linear_attn.in_proj_qkv.scales"
        static let biases = "language_model.model.layers.0.linear_attn.in_proj_qkv.biases"
    }

    private func completeValues(_ summary: Summary) -> [Float]? {
        let expectedCount = summary.shape.reduce(1, *)
        if let raw = summary.rawBFloat16Bits, raw.count == expectedCount {
            return raw.map { Float(bitPattern: UInt32($0) << 16) }
        }
        if let values = summary.values, values.count == expectedCount {
            return values
        }
        return nil
    }

    private func completeValues(_ summary: QwenStreamArraySummary) -> [Float]? {
        let expectedCount = summary.shape.reduce(1, *)
        if let raw = summary.rawBFloat16Bits, raw.count == expectedCount {
            return raw.map { Float(bitPattern: UInt32($0) << 16) }
        }
        if let values = summary.fullValues, values.count == expectedCount {
            return values
        }
        return nil
    }

    private func row(_ values: [Float], shape: [Int], tokenIndex: Int) -> [Float] {
        let width = shape.last ?? values.count
        let start = max(0, tokenIndex) * width
        let end = min(values.count, start + width)
        guard start < end else { return [] }
        return Array(values[start..<end])
    }

    private func routerRecord(
        _ records: [QwenStreamRouterRecord],
        position: Int
    ) -> (expertIDs: [Int], scores: [Float])? {
        for record in records {
            guard let index = record.positions.firstIndex(of: position),
                  index < record.expertIDs.count,
                  index < record.scores.count else { continue }
            return (record.expertIDs[index], record.scores[index])
        }
        return nil
    }

    private func activationMetric(
        name: String,
        reference: [Float],
        native: [Float],
        shape: [Int],
        referenceDType: String,
        nativeDType: String
    ) -> [String: Any] {
        var sum = 0.0
        var referenceSum = 0.0
        var maxAbs = 0.0
        var worstIndex = 0
        for (index, pair) in zip(reference, native).enumerated() {
            let difference = Double(pair.1) - Double(pair.0)
            sum += difference * difference
            referenceSum += Double(pair.0) * Double(pair.0)
            let absolute = abs(difference)
            if absolute > maxAbs {
                maxAbs = absolute
                worstIndex = index
            }
        }
        let referenceNorm = sqrt(referenceSum)
        let nativeNorm = sqrt(native.reduce(0.0) { $0 + Double($1) * Double($1) })
        let relativeL2 = reference.count == native.count
            ? sqrt(sum) / max(referenceNorm, 1e-12)
            : Double.infinity
        return [
            "name": name,
            "shape": shape,
            "referenceDType": dtypeClass(referenceDType),
            "nativeDType": dtypeClass(nativeDType),
            "referenceNorm": referenceNorm,
            "nativeNorm": nativeNorm,
            "relativeL2": relativeL2,
            "maxAbs": maxAbs,
            "worstIndex": worstIndex,
            "worstCoordinate": [worstIndex],
            "referenceCount": reference.count,
            "nativeCount": native.count,
        ]
    }

    private func validateIdentity(_ reference: Boundary) {
        XCTAssertEqual(reference.fixtureFormatVersion, "qwen35-k8-boundary-v1")
        XCTAssertEqual(reference.fixtureID, "qwen35-k8-prefill-boundary")
        XCTAssertEqual(reference.artifact.repo, QwenStreamArtifact.repo)
        XCTAssertEqual(reference.artifact.revision, QwenStreamArtifact.revision)
        XCTAssertEqual(reference.artifact.inventorySHA256, expectedInventorySHA256)
        XCTAssertEqual(reference.configSHA256, expectedConfigSHA256)
        XCTAssertEqual(reference.tokenizerSHA256, expectedTokenizerSHA256)
        XCTAssertEqual(reference.tokenizerConfigSHA256, expectedTokenizerConfigSHA256)
        XCTAssertEqual(reference.templateSHA256, expectedTemplateSHA256)
        XCTAssertEqual(reference.oracle.mlx, "0.32.2")
        XCTAssertEqual(reference.oracle.mlxLM, "0.31.1")
        XCTAssertEqual(reference.oracle.device, "cpu")
        XCTAssertEqual(reference.oracle.recurrentState, "float32 (config mamba_ssm_dtype)")
        XCTAssertEqual(reference.semantics.routingK, QwenStreamArtifact.routingK)
        XCTAssertEqual(reference.semantics.expertCount, QwenStreamArtifact.expertCount)
        XCTAssertTrue(reference.semantics.sharedExpert)
        XCTAssertFalse(reference.semantics.thinking)
    }

    private func compareRouters(_ expected: [Router], _ actual: [QwenStreamRouterRecord], context: String) {
        let actualByPosition: [(position: Int, expertIDs: [Int], scores: [Float])] = actual.flatMap { record in
            record.positions.indices.compactMap { index in
                guard index < record.expertIDs.count, index < record.scores.count else { return nil }
                return (position: record.positions[index], expertIDs: record.expertIDs[index], scores: record.scores[index])
            }
        }
        let actualMap: [Int: ([Int], [Float])] = Dictionary(
            uniqueKeysWithValues: actualByPosition.map { ($0.position, ($0.expertIDs, $0.scores)) })
        for item in expected {
            guard let observed = actualMap[item.position] else {
                XCTFail("\(context) router position \(item.position) is missing")
                continue
            }
            let expectedSet = Set(item.expertIDs)
            let actualSet = Set(observed.0)
            if expectedSet != actualSet {
                let expectedTop = zip(item.topLogitIDs ?? [], item.topLogits ?? [])
                    .map { "\($0.0):\($0.1)" }.joined(separator: ",")
                let actualRecord = actual.first { $0.positions.contains(item.position) }
                let actualIndex = actualRecord?.positions.firstIndex(of: item.position)
                let actualTop = actualIndex.flatMap { index in
                    guard let actualRecord else { return nil }
                    return zip(actualRecord.topLogitIDs[index], actualRecord.topLogits[index])
                        .map { "\($0.0):\($0.1)" }.joined(separator: ",")
                } ?? "unavailable"
                print("[qwen-q25-router-mismatch] \(context) position=\(item.position) expected=\(item.expertIDs) actual=\(observed.0) expectedTop=\(expectedTop) actualTop=\(actualTop)")
            } else if observed.0 != item.expertIDs {
                // argPartition does not promise a stable ordering for equal
                // or nearly equal values.  The score remains attached to its
                // expert ID, so this is an order-only diagnostic rather than
                // a semantic failure.
                print("[qwen-q25-router-order-only] \(context) position=\(item.position) expected=\(item.expertIDs) actual=\(observed.0)")
            }
            XCTAssertEqual(actualSet, expectedSet, "\(context) router selection set at \(item.position)")

            // Compare scores by expert ID so an order-only argPartition
            // permutation cannot masquerade as a score mismatch.
            let expectedByID = Dictionary(uniqueKeysWithValues: zip(item.expertIDs, item.scores))
            let actualByID = Dictionary(uniqueKeysWithValues: zip(observed.0, observed.1))
            let commonIDs = item.expertIDs.filter { actualByID[$0] != nil }
            let expectedScores = commonIDs.compactMap { expectedByID[$0] }
            let actualScores = commonIDs.compactMap { actualByID[$0] }
            let scoreRel = relativeL2(actualScores, expectedScores)
            let scoreAbs = maxAbs(actualScores, expectedScores)
            print("[qwen-q25-router-scores] \(context) position=\(item.position) common=\(commonIDs.count) relL2=\(scoreRel) maxAbs=\(scoreAbs)")
            if expectedSet == actualSet {
                XCTAssertLessThanOrEqual(scoreRel, 0.03, "\(context) router score drift")
                XCTAssertLessThanOrEqual(scoreAbs, 0.05, "\(context) router score maxAbs")
            }
        }
    }

    private func compareCache(_ expected: Cache, _ actual: QwenStreamCacheLayerSnapshot, context: String) {
        if let expectedLayer = expected.layer {
            XCTAssertEqual(actual.layer, expectedLayer, "\(context) cache layer")
        }
        XCTAssertEqual(actual.offset, expected.offset, "\(context) cache offset")
        XCTAssertEqual(actual.state.count, expected.state.count, "\(context) cache state count")
        for (index, pair) in zip(expected.state, actual.state).enumerated() {
            compareSummary(pair.0, pair.1, context: "\(context) cache state \(index)")
            if expected.type == "ArraysCache", index == 1 {
                XCTAssertTrue(dtypeClass(pair.1.dtype) == "float32", "\(context) recurrent state must remain FP32")
            }
        }
    }

    private func compareComponents(
        _ expected: Components,
        _ actual: QwenStreamDebugLayerComponents,
        context: String
    ) {
        compareSummary(expected.attentionInput, actual.attentionInput, context: "\(context) attention input")
        compareSummary(expected.attentionOutput, actual.attentionOutput, context: "\(context) attention output")
        if let expectedResidual = expected.postAttentionResidual {
            compareSummary(
                expectedResidual,
                actual.postAttentionResidual,
                context: "\(context) post-attention residual")
        }
        compareSummary(expected.postAttentionInput, actual.postAttentionInput, context: "\(context) post-attention input")
        compareSummary(expected.mlpOutput, actual.mlpOutput, context: "\(context) MoE output")
        compareSummary(expected.routerInput, actual.routerInput, context: "\(context) router input")
        compareSummary(expected.routerLogits, actual.routerLogits, context: "\(context) router logits")
        compareSummary(expected.routedOutput, actual.routedOutput, context: "\(context) routed output")
        compareSummary(expected.sharedOutput, actual.sharedOutput, context: "\(context) shared output")
        if let expectedProjections = expected.linearProjections,
           let actualProjections = actual.linearProjections {
            compareSummary(expectedProjections.qkv, actualProjections.qkv, context: "\(context) qkv projection")
            compareSummary(expectedProjections.z, actualProjections.z, context: "\(context) z projection")
            compareSummary(expectedProjections.b, actualProjections.b, context: "\(context) b projection")
            compareSummary(expectedProjections.a, actualProjections.a, context: "\(context) a projection")
        }
        if let expectedAttention = expected.linearAttention,
           let actualAttention = actual.linearAttention {
            compareSummary(expectedAttention.convOutput, actualAttention.convOutput, context: "\(context) conv output")
            compareSummary(expectedAttention.qNormed, actualAttention.qNormed, context: "\(context) q normalized")
            compareSummary(expectedAttention.kNormed, actualAttention.kNormed, context: "\(context) k normalized")
            compareSummary(expectedAttention.v, actualAttention.v, context: "\(context) v projection")
            compareSummary(expectedAttention.gatedOutput, actualAttention.gatedOutput, context: "\(context) gated output")
            compareSummary(expectedAttention.normalizedOutput, actualAttention.normalizedOutput, context: "\(context) normalized output")
        }
    }

    private func compareSummary(_ expected: Summary, _ actual: QwenStreamArraySummary, context: String) {
        XCTAssertEqual(actual.shape, expected.shape, "\(context) shape")
        XCTAssertEqual(dtypeClass(actual.dtype), dtypeClass(expected.dtype), "\(context) dtype")
        let expectedValues = expected.tailSample.map { expected.sample + $0 } ?? expected.sample
        let actualValues = actual.tailSample.isEmpty ? actual.sample : actual.sample + actual.tailSample
        XCTAssertEqual(actualValues.count, expectedValues.count, "\(context) summary length")
        guard actualValues.count == expectedValues.count else { return }
        let rel = relativeL2(actualValues, expectedValues)
        let abs = maxAbs(actualValues, expectedValues)
        print("[qwen-q25-boundary] \(context) relL2=\(rel) maxAbs=\(abs)")
        XCTAssertLessThanOrEqual(rel, 0.08, "\(context) relL2")
        XCTAssertLessThanOrEqual(abs, 0.25, "\(context) maxAbs")
    }

    private func dtypeClass(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("float32") || lower == "f32" { return "float32" }
        if lower.contains("bfloat16") || lower == "bf16" { return "bfloat16" }
        if lower.contains("float16") || lower == "f16" { return "float16" }
        return lower
    }

    private func relativeL2(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var numerator = 0.0
        var denominator = 0.0
        for (left, right) in zip(lhs, rhs) {
            let difference = Double(left) - Double(right)
            numerator += difference * difference
            denominator += Double(right) * Double(right)
        }
        return sqrt(numerator) / max(sqrt(denominator), 1e-12)
    }

    private func maxAbs(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    private func promptHash(_ ids: [Int]) -> String {
        SHA256.hash(data: Data(String(describing: ids).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func modelDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
    }
}
