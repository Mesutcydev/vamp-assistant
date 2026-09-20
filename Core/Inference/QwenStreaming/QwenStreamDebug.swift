import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// A bounded, JSON-friendly description of one cache tensor.  The debug path
/// stores only shapes, dtypes, and a small evaluated prefix; it never retains a
/// hidden state or a full cache tensor on disk.
struct QwenStreamArraySummary: Codable, Sendable, Equatable {
    let shape: [Int]
    let dtype: String
    let sample: [Float]
    let tailSample: [Float]
    /// Optional complete values for a bounded diagnostic fixture. Normal
    /// inference and ordinary debug traces retain only prefix/suffix samples.
    let fullValues: [Float]?
    /// Exact BF16 words for a bounded diagnostic fixture. This prevents a
    /// decimal JSON round-trip from becoming the comparison boundary.
    let rawBFloat16Bits: [UInt16]?
    /// Exact words for any other 16-bit tensor (currently Float16). This is
    /// populated only by the explicit full-value diagnostic path.
    let rawUInt16Bits: [UInt16]?
    /// Exact words for Float32 tensors captured by the diagnostic path.
    let rawUInt32Bits: [UInt32]?

    init(_ array: MLXArray, sampleCount: Int = 16, captureFullValues: Bool = false) {
        MLX.eval(array)
        self.shape = array.shape
        self.dtype = String(describing: array.dtype)
        let flat = array.flattened()
        let count = min(max(0, sampleCount), flat.size)
        self.sample = count == 0 ? [] : flat[0..<count].asArray(Float.self)
        self.tailSample = count == 0 ? [] : flat[(flat.size - count)..<flat.size].asArray(Float.self)
        if captureFullValues {
            let values = flat.asArray(Float.self)
            self.fullValues = values
            let lower = dtype.lowercased()
            if lower.contains("bfloat16") || lower.contains("float16") {
                let bits = flat.view(dtype: .uint16).asArray(UInt16.self)
                self.rawUInt16Bits = bits
                self.rawBFloat16Bits = lower.contains("bfloat16") ? bits : nil
                self.rawUInt32Bits = nil
            } else if lower.contains("float32") {
                self.rawBFloat16Bits = nil
                self.rawUInt16Bits = nil
                self.rawUInt32Bits = flat.view(dtype: .uint32).asArray(UInt32.self)
            } else {
                self.rawBFloat16Bits = nil
                self.rawUInt16Bits = nil
                self.rawUInt32Bits = nil
            }
        } else {
            self.fullValues = nil
            self.rawBFloat16Bits = nil
            self.rawUInt16Bits = nil
            self.rawUInt32Bits = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case shape, dtype, sample, tailSample, fullValues, rawBFloat16Bits, rawUInt16Bits, rawUInt32Bits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decode([Int].self, forKey: .shape)
        dtype = try container.decode(String.self, forKey: .dtype)
        sample = try container.decode([Float].self, forKey: .sample)
        // Older native debug files predate tail samples.  Reading them stays
        // source-compatible while every newly written boundary contains both
        // ends of the evaluated tensor.
        tailSample = try container.decodeIfPresent([Float].self, forKey: .tailSample) ?? []
        fullValues = try container.decodeIfPresent([Float].self, forKey: .fullValues)
        rawBFloat16Bits = try container.decodeIfPresent([UInt16].self, forKey: .rawBFloat16Bits)
        rawUInt16Bits = try container.decodeIfPresent([UInt16].self, forKey: .rawUInt16Bits)
        rawUInt32Bits = try container.decodeIfPresent([UInt32].self, forKey: .rawUInt32Bits)
    }
}

/// Physical layout metadata for a diagnostic MLX array.  This is captured
/// only by the opt-in SDPA replay; normal inference does not inspect backing
/// storage or hash tensor bytes.
struct QwenStreamArrayLayout: Codable, Sendable, Equatable {
    let shape: [Int]
    let strides: [Int]
    let logicalDType: String
    let storageDType: String
    let itemSize: Int
    let logicalBytes: Int
    let backingBytes: Int
    let contiguous: Bool
    let rowContiguous: Bool
    let byteOffset: Int?
    let viewStatus: String
    let device: String
    let stream: String
    let rawSHA256: String

    init(_ array: MLXArray) {
        MLX.eval(array)
        let noCopy = array.asData(access: .noCopy)
        let shape = array.shape
        let strides = noCopy.strides
        var expected = [Int](repeating: 1, count: shape.count)
        if !shape.isEmpty {
            for index in stride(from: shape.count - 2, through: 0, by: -1) {
                expected[index] = expected[index + 1] * shape[index + 1]
            }
        }
        let isContiguous = strides == expected
        let bytes = array.asData(access: .copy).data
        self.shape = shape
        self.strides = strides
        self.logicalDType = String(describing: array.dtype)
        self.storageDType = String(describing: noCopy.dType)
        self.itemSize = array.itemSize
        self.logicalBytes = array.nbytes
        self.backingBytes = noCopy.data.count
        self.contiguous = isContiguous
        self.rowContiguous = isContiguous
        // MLX's public Swift API exposes strides but not a view byte offset.
        self.byteOffset = nil
        self.viewStatus = isContiguous ? "contiguous-storage" : "strided-view"
        self.device = Device.defaultDevice().deviceType?.rawValue ?? "unavailable"
        self.stream = StreamOrDevice.default.description
        self.rawSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct QwenStreamCacheLayerSnapshot: Codable, Sendable, Equatable {
    let layer: Int
    let kind: String
    let offset: Int
    let state: [QwenStreamArraySummary]

    init(
        layer: Int,
        kind: String,
        offset: Int,
        state: [QwenStreamArraySummary]
    ) {
        self.layer = layer
        self.kind = kind
        self.offset = offset
        self.state = state
    }

    /// Capture one cache entry without forcing callers to materialize the
    /// other 39 layer states. This is used by the Q2.9 target-step probe.
    init(layer: Int, cache: KVCache, captureFullValues: Bool = false) {
        self.layer = layer
        self.kind = cache is MambaCache ? "GatedDeltaNet/MambaCache" : "FullAttention/KVCache"
        self.offset = cache.offset
        let cacheState = cache.state
        MLX.eval(cacheState)
        self.state = cacheState.map {
            QwenStreamArraySummary($0, captureFullValues: captureFullValues)
        }
    }
}

struct QwenStreamCacheSnapshot: Codable, Sendable, Equatable {
    let layers: [QwenStreamCacheLayerSnapshot]

    init(cache: [KVCache]) {
        var snapshots = [QwenStreamCacheLayerSnapshot]()
        snapshots.reserveCapacity(cache.count)
        for (index, item) in cache.enumerated() {
            let state = item.state
            MLX.eval(state)
            var arrays = [QwenStreamArraySummary]()
            arrays.reserveCapacity(state.count)
            for array in state {
                arrays.append(QwenStreamArraySummary(array))
            }
            snapshots.append(QwenStreamCacheLayerSnapshot(
                layer: index,
                kind: item is MambaCache ? "GatedDeltaNet/MambaCache" : "FullAttention/KVCache",
                offset: item.offset,
                state: arrays))
        }
        self.layers = snapshots
    }
}

struct QwenStreamLayerSnapshot: Codable, Sendable, Equatable {
    let layer: Int
    let hidden: QwenStreamArraySummary
}

struct QwenStreamDebugCheckpoint: Codable, Sendable, Equatable {
    /// -1 is the completed prefill boundary; positive values are the number
    /// of generated tokens that have been fed through cached decode.
    let decodeStep: Int
    let inputToken: Int?
    let predictedToken: Int
    let topToken: Int
    let topLogitIDs: [Int]
    let topLogits: [Float]
    let layerSnapshots: [QwenStreamLayerSnapshot]
    let cache: QwenStreamCacheSnapshot
}

struct QwenStreamDebugLayerComponents: Codable, Sendable, Equatable {
    struct LinearProjections: Codable, Sendable, Equatable {
        let qkv: QwenStreamArraySummary
        let z: QwenStreamArraySummary
        let b: QwenStreamArraySummary
        let a: QwenStreamArraySummary
    }

    let attentionInput: QwenStreamArraySummary
    let attentionOutput: QwenStreamArraySummary
    let postAttentionResidual: QwenStreamArraySummary
    let postAttentionInput: QwenStreamArraySummary
    let mlpOutput: QwenStreamArraySummary
    let routerInput: QwenStreamArraySummary
    let routerLogits: QwenStreamArraySummary
    let routedOutput: QwenStreamArraySummary
    let sharedOutput: QwenStreamArraySummary
    let linearProjections: LinearProjections?
    let linearAttention: LinearAttention?
    let fullAttention: FullAttention?

    struct LinearAttention: Codable, Sendable, Equatable {
        let convOutput: QwenStreamArraySummary
        let qNormed: QwenStreamArraySummary
        let kNormed: QwenStreamArraySummary
        let v: QwenStreamArraySummary
        let gatedOutput: QwenStreamArraySummary
        let normalizedOutput: QwenStreamArraySummary
    }

    /// Bounded full-attention intermediates used only by the Q2.9
    /// localization fixture.  The cache itself remains represented by the
    /// enclosing layer snapshot.
    struct FullAttention: Codable, Sendable, Equatable {
        let queryProjection: QwenStreamArraySummary
        let gate: QwenStreamArraySummary
        let queries: QwenStreamArraySummary
        let keys: QwenStreamArraySummary
        let values: QwenStreamArraySummary
        let attentionValues: QwenStreamArraySummary
        let gatedValues: QwenStreamArraySummary
        let sdpa: QwenStreamDebugSDPAInvocation?
        /// The explicit SDPA candidate is present only for Q2.12's
        /// model-level data-flow probe. Older fixtures decode with nil.
        let requestedStrategy: String?
        let effectiveStrategy: String?
        let sentinelApplied: Bool?
        let explicitTrace: QwenStreamDebugExplicitAttention?
    }
}

/// Bounded T3-T7 intermediates from the diagnostic explicit attention seam.
/// T0-T2 and T8-T14 remain represented by the surrounding full-attention and
/// decoder-layer fields so the production data-flow order stays visible.
struct QwenStreamDebugExplicitAttention: Codable, Sendable, Equatable {
    let expandedKeys: QwenStreamArraySummary
    let expandedValues: QwenStreamArraySummary
    let rawQK: QwenStreamArraySummary
    let scaledScores: QwenStreamArraySummary
    let maskedScores: QwenStreamArraySummary
    let probabilities: QwenStreamArraySummary
    let weightedOutputFloat32: QwenStreamArraySummary
    let output: QwenStreamArraySummary
}

/// Exact argument/layout record for one attention primitive invocation.  The
/// logical Q/K/V arrays are retained by ``FullAttention``; this record adds
/// the raw kernel output, mask/scale contract, and physical array metadata.
struct QwenStreamDebugSDPAInvocation: Codable, Sendable, Equatable {
    let scale: Float
    let scaleBits: UInt32
    let scaleExpression: String
    let maskMode: String
    let mask: QwenStreamArraySummary?
    let queryLayout: QwenStreamArrayLayout
    let keyLayout: QwenStreamArrayLayout
    let valueLayout: QwenStreamArrayLayout
    let cachedKeyLayout: QwenStreamArrayLayout?
    let cachedValueLayout: QwenStreamArrayLayout?
    let outputLayout: QwenStreamArrayLayout
    let output: QwenStreamArraySummary
}

/// Result of the diagnostic GatedDelta replay used to separate recurrent
/// state-history drift from a local native kernel mismatch. This type is never
/// produced by normal generation.
struct QwenStreamDebugGatedDeltaReplay: Codable, Sendable, Equatable {
    let output: QwenStreamArraySummary
    let state: QwenStreamArraySummary
}

struct QwenStreamDebugRun: Codable, Sendable, Equatable {
    let promptTokenIDs: [Int]
    let generatedTokenIDs: [Int]
    let stopReason: String
    let finalConsumedPosition: Int
    let checkpoints: [QwenStreamDebugCheckpoint]
    let router: QwenStreamRouterTraceSnapshot?
    let prefillCallCount: Int
    let cachedDecodeCallCount: Int
    /// Number of cached calls that advanced from one emitted token to the
    /// next.  The first emitted token is selected from the prefill logits.
    let decodeEmissionCallCount: Int
    /// The final call feeds the last emitted token to materialize the next
    /// logits and final recurrent/KV state. It is included in
    /// `cachedDecodeCallCount` but is not another emitted token interval.
    let finalStateProbeCallCount: Int
}

/// Compact prefill boundary diagnostics. These records are opt-in and retain
/// only summaries of the embedding, selected layer inputs/outputs, cache
/// state, and router decisions. They never retain model payloads or hidden
/// tensors in full.
struct QwenStreamDebugBoundaryLayer: Codable, Sendable, Equatable {
    let layer: Int
    let kind: String
    let positionBefore: Int
    let positionAfter: Int
    let input: QwenStreamArraySummary
    let output: QwenStreamArraySummary
    let tokenOutputs: [QwenStreamArraySummary]
    let cache: QwenStreamCacheLayerSnapshot
    let router: [QwenStreamRouterRecord]
    let components: QwenStreamDebugLayerComponents?
}

struct QwenStreamDebugBoundaryGroup: Codable, Sendable, Equatable {
    let groupIndex: Int
    let positionBefore: Int
    let positionAfter: Int
    let tokenIDs: [Int]
    let embedding: QwenStreamArraySummary
    let layers: [QwenStreamDebugBoundaryLayer]
}

struct QwenStreamDebugBoundaryRun: Codable, Sendable, Equatable {
    let fixtureFormatVersion: String
    let fixtureID: String
    let promptTokenIDs: [Int]
    let promptTokenCount: Int
    let prefillGroupSize: Int
    let boundaryLayerCount: Int
    let groups: [QwenStreamDebugBoundaryGroup]
}

struct QwenStreamDebugTeacherForcedRun: Codable, Sendable, Equatable {
    let fixtureFormatVersion: String
    let fixtureID: String
    let promptTokenIDs: [Int]
    let forcedTokenIDs: [Int]
    let prefillCallCount: Int
    let cachedDecodeCallCount: Int
    let checkpoints: [QwenStreamDebugCheckpoint]
}

/// A compact teacher-forced snapshot used only while localizing a semantic
/// mismatch. The target layer retains complete bounded component arrays for
/// one token; selected earlier layers retain only their input/output arrays.
/// No production generation path creates this value.
struct QwenStreamDebugLayerBoundary: Codable, Sendable, Equatable {
    let layer: Int
    let kind: String
    let positionBefore: Int
    let positionAfter: Int
    let input: QwenStreamArraySummary
    let output: QwenStreamArraySummary
}

struct QwenStreamDebugTargetLayer: Codable, Sendable, Equatable {
    let layer: Int
    let kind: String
    let position: Int
    let input: QwenStreamArraySummary
    let output: QwenStreamArraySummary
    let components: QwenStreamDebugLayerComponents
    let cacheBefore: QwenStreamCacheLayerSnapshot
    let cacheAfter: QwenStreamCacheLayerSnapshot
}

struct QwenStreamDebugTeacherForcedComponentsRun: Codable, Sendable, Equatable {
    let fixtureFormatVersion: String
    let fixtureID: String
    let promptTokenIDs: [Int]
    let forcedTokenIDs: [Int]
    let targetLayer: Int
    let targetPosition: Int
    let targetInputTokenID: Int
    let prefillCallCount: Int
    let cachedDecodeCallCount: Int
    let capturedLayers: [QwenStreamDebugLayerBoundary]
    let target: QwenStreamDebugTargetLayer
}

/// A single full router capture used by Q2.8. It is opt-in and keyed to an
/// explicit layer/position, so normal traces retain no full 256-way arrays.
struct QwenStreamRouterRawSnapshot: Codable, Sendable, Equatable {
    let position: Int
    let routerInput: QwenStreamArraySummary
    let routerLogits: QwenStreamArraySummary
    let selectorScores: QwenStreamArraySummary
    let selectedExpertIDs: [Int]
    let selectedNormalizedScores: [Float]
}

struct QwenStreamRouterTraceKey: Hashable, Sendable {
    let layer: Int
    let position: Int
}

// MARK: - Q2.18 attention-strategy compatibility evidence

/// One bounded SDPA compatibility observation: the fused kernel and the
/// validated explicit replay evaluated from byte-identical Q/K/V/mask/scale.
///
/// ``fusedProductionMask`` is what the shipped decoder would compute (the
/// `.causal`/`.none` mask mode it actually passes); ``fusedSameMask`` feeds the
/// fused kernel the *materialized* mask the explicit path uses, so the report
/// can separate kernel numerics from mask-semantics differences.
struct QwenStreamSDPACompatibilityEntry: Codable, Sendable, Equatable {
    let phase: String
    let layer: Int
    let group: Int
    let position: Int
    let queryLength: Int
    let keyLength: Int
    let queryHeads: Int
    let kvHeads: Int
    let headDim: Int
    let scale: Float
    let productionMaskMode: String
    let outputDtype: String
    let byteIdenticalBF16: Bool
    let byteIdenticalBF16SameMask: Bool
    let relL2: Double
    let maxAbs: Double
    let worstCoordinate: String
    let worstValueFused: Double
    let worstValueExplicit: Double
    let relL2SameMask: Double
    let maxAbsSameMask: Double
    let maskSemanticsAgree: Bool
}

/// Aggregate classification for the whole matrix.
struct QwenStreamSDPACompatibilityMatrix: Codable, Sendable, Equatable {
    let captureStrategy: String
    let entries: [QwenStreamSDPACompatibilityEntry]
    let decodeEntries: Int
    let decodeByteIdentical: Int
    let decodeMaxRelL2: Double
    let decodeMaxAbs: Double
    let prefillEntries: Int
    let prefillByteIdentical: Int
    let prefillMaxRelL2: Double
    let prefillMaxAbs: Double
    let distinctPrefillQueryLengths: [Int]
    let distinctDecodeKeyLengths: [Int]

    /// The Q2.18 promotion gate for fused qLen=1 decode: every sampled decode
    /// shape must produce a bit-identical BF16 attention output.
    var decodeBitwiseClean: Bool {
        decodeEntries > 0 && decodeByteIdentical == decodeEntries
    }
}

/// One downstream observation from the teacher-forced qLen=1 routing replay.
/// `expected` is always the validated explicit baseline; `actual` is the
/// strategy under test.
struct QwenStreamDecodeRoutingComparison: Codable, Sendable, Equatable {
    let layer: Int
    let position: Int
    let expectedExpertIDs: [Int]
    let actualExpertIDs: [Int]
    let membershipIdentical: Bool
    let orderIdentical: Bool
    let scoreRelL2: Double
    let scoreMaxAbs: Double
    let kthScore: Double
    let kPlusOneScore: Double
    let kGap: Double
}

/// Aggregate result of comparing a candidate decode strategy against the
/// explicit baseline over a teacher-forced reference history.
struct QwenStreamDecodeRoutingReplay: Codable, Sendable, Equatable {
    let candidateStrategy: String
    let promptTokenCount: Int
    let forcedTokenCount: Int
    let candidateFusedDecodeCalls: Int
    let candidateExplicitDecodeCalls: Int
    let candidateFusedPrefillCalls: Int
    let candidateExplicitPrefillCalls: Int
    let baselineExplicitCalls: Int
    let baselineFusedCalls: Int
    let comparisons: Int
    let membershipFailures: Int
    let orderOnlyDifferences: Int
    let maxScoreRelL2: Double
    let maxScoreMaxAbs: Double
    let minKGap: Double
    let predictedTokenDifferences: Int
    let firstPredictedDifferenceIndex: Int?
    let records: [QwenStreamDecodeRoutingComparison]

    /// The Q2.18 gate for promoting fused qLen=1 decode: at least one real
    /// comparison and zero true K=8 membership differences.
    var routingClean: Bool { comparisons > 0 && membershipFailures == 0 }
}

/// One captured full-attention decoder block from the teacher-forced replay.
/// It follows the signal chain the Q2.18 hypothesis names explicitly: SDPA
/// output, head merge, gate, o_proj, and the whole block output.
struct QwenStreamAttentionBlockCapture: Codable, Sendable, Equatable {
    let layer: Int
    let decodeIndex: Int
    let position: Int
    let effectiveStrategy: String
    let layerInput: QwenStreamArraySummary
    let sdpaOutput: QwenStreamArraySummary
    let attentionValues: QwenStreamArraySummary
    let gatedValues: QwenStreamArraySummary
    let oProjOutput: QwenStreamArraySummary
    let blockOutput: QwenStreamArraySummary
}

/// Raw result of one teacher-forced strategy replay, before any comparison.
struct QwenStreamDecodeStrategyReplay: Codable, Sendable, Equatable {
    let strategy: String
    let promptTokenCount: Int
    let forcedTokenCount: Int
    let prefillCallCount: Int
    let cachedDecodeCallCount: Int
    let fusedCalls: Int
    let explicitCalls: Int
    let fusedPrefillCalls: Int
    let explicitPrefillCalls: Int
    let fusedDecodeCalls: Int
    let explicitDecodeCalls: Int
    let requestedStrategies: [String]
    let effectiveStrategies: [String]
    let predictedTokenIDs: [Int]
    let blocks: [QwenStreamAttentionBlockCapture]
    let router: QwenStreamRouterTraceSnapshot?
}

/// Router diagnostics are opt-in and bounded. A normal record contains only
/// selected IDs, normalized scores, and the nine highest raw router logits.
/// A full raw snapshot is retained only for explicitly requested keys.
final class QwenStreamRouterTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumRecords: Int
    private let layers: Set<Int>
    private let positions: Set<Int>
    private let rawKeys: Set<QwenStreamRouterTraceKey>
    private var records: [QwenStreamRouterRecord] = []
    private var dropped = 0

    init(
        maximumRecords: Int = 256,
        layers: Set<Int> = [0, 19, 39],
        positions: Set<Int> = [0, 1, 2, 4, 8, 16, 32, 64, 128, 256],
        rawKeys: Set<QwenStreamRouterTraceKey> = []
    ) {
        self.maximumRecords = max(1, maximumRecords)
        self.layers = layers
        self.positions = positions
        self.rawKeys = rawKeys
    }

    func reset() {
        lock.lock()
        records.removeAll(keepingCapacity: true)
        dropped = 0
        lock.unlock()
    }

    func shouldRecord(layer: Int, position: Int, tokenCount: Int) -> Bool {
        guard layers.contains(layer) else { return false }
        return (position..<(position + max(0, tokenCount))).contains { positions.contains($0) }
    }

    func record(
        layer: Int,
        position: Int,
        logits: MLXArray,
        expertIDs: MLXArray,
        scores: MLXArray,
        selectorScores: MLXArray,
        routerInput: MLXArray
    ) {
        guard shouldRecord(layer: layer, position: position, tokenCount: logits.dim(-2)) else { return }
        let tokenCount = logits.dim(-2)
        let positions = (0..<tokenCount).map { position + $0 }
        let captureRaw = positions.contains { rawKeys.contains(QwenStreamRouterTraceKey(layer: layer, position: $0)) }
        if captureRaw {
            MLX.eval(logits, expertIDs, scores, selectorScores, routerInput)
        } else {
            MLX.eval(logits, expertIDs, scores)
        }
        let logitsValues = logits.asArray(Float.self)
        let idsValues = expertIDs.asArray(Int.self)
        let scoreValues = scores.asArray(Float.self)
        let selected = (0..<tokenCount).map { token in
            Array(idsValues[(token * 8)..<(token * 8 + 8)])
        }
        let selectedScores = (0..<tokenCount).map { token in
            Array(scoreValues[(token * 8)..<(token * 8 + 8)])
        }
        let topIDs = (0..<tokenCount).map { token -> [Int] in
            let row = Array(logitsValues[(token * logits.dim(-1))..<(token + 1) * logits.dim(-1)])
            return row.indices.sorted { row[$0] > row[$1] }.prefix(9).map { $0 }
        }
        let topValues = (0..<tokenCount).map { token -> [Float] in
            let row = Array(logitsValues[(token * logits.dim(-1))..<(token + 1) * logits.dim(-1)])
            return row.indices.sorted { row[$0] > row[$1] }.prefix(9).map { row[$0] }
        }
        let rawSnapshots: [QwenStreamRouterRawSnapshot] = captureRaw
            ? (0..<tokenCount).compactMap { token in
                let absolutePosition = position + token
                guard rawKeys.contains(QwenStreamRouterTraceKey(layer: layer, position: absolutePosition)) else { return nil }
                let selectedIDs = selected[token]
                let normalizedScores = selectedScores[token]
                let width = logits.dim(-1)
                let scoreRow = selectorScores[0, token]
                let inputRow = routerInput[0, token]
                return QwenStreamRouterRawSnapshot(
                    position: absolutePosition,
                    routerInput: QwenStreamArraySummary(inputRow, sampleCount: inputRow.size, captureFullValues: true),
                    routerLogits: QwenStreamArraySummary(logits[0, token], sampleCount: width, captureFullValues: true),
                    selectorScores: QwenStreamArraySummary(scoreRow, sampleCount: width, captureFullValues: true),
                    selectedExpertIDs: selectedIDs,
                    selectedNormalizedScores: normalizedScores)
            }
            : []
        let record = QwenStreamRouterRecord(
            layer: layer,
            positions: positions,
            expertIDs: selected,
            scores: selectedScores,
            topLogitIDs: topIDs,
            topLogits: topValues,
            raw: rawSnapshots.isEmpty ? nil : rawSnapshots)
        lock.lock()
        defer { lock.unlock() }
        guard records.count < maximumRecords else {
            dropped += tokenCount
            return
        }
        records.append(record)
    }

    func snapshot() -> QwenStreamRouterTraceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return QwenStreamRouterTraceSnapshot(records: records, droppedRecords: dropped)
    }
}

struct QwenStreamRouterRecord: Codable, Sendable, Equatable {
    let layer: Int
    let positions: [Int]
    let expertIDs: [[Int]]
    let scores: [[Float]]
    let topLogitIDs: [[Int]]
    let topLogits: [[Float]]
    let raw: [QwenStreamRouterRawSnapshot]?
}

struct QwenStreamRouterTraceSnapshot: Codable, Sendable, Equatable {
    let records: [QwenStreamRouterRecord]
    let droppedRecords: Int

    var isComplete: Bool { droppedRecords == 0 }
}
