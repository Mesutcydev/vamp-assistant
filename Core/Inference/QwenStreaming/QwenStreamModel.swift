// Adapted from mlx-swift-lm 3.31.4 (MIT). See docs/QWEN-STREAMING-NOTICES.md.
// Exact single-token K=8 path; the routed module is never instantiated resident.
//
//  StreamQwen35.swift
//  mlx-swift-lm
//
//  Created by John Mai on 2026/2/9.
//
//  Port of https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/qwen3_5.py
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - Configuration

private enum RopeParametersCodingKey: String, CodingKey {
    case ropeParameters = "rope_parameters"
}

struct StreamQwen35TextConfiguration: Codable, Sendable {
    var modelType: String = ""
    var hiddenSize: Int = 4096
    var hiddenLayers: Int = 32
    var intermediateSize: Int = 14336
    var attentionHeads: Int = 32
    var kvHeads: Int = 8
    var linearNumValueHeads: Int = 64
    var linearNumKeyHeads: Int = 16
    var linearKeyHeadDim: Int = 192
    var linearValueHeadDim: Int = 128
    var linearConvKernelDim: Int = 4
    var rmsNormEps: Float = 1e-6
    var vocabularySize: Int = 151_936
    var ropeTheta: Float = 100000.0
    var partialRotaryFactor: Float = 0.25
    var maxPositionEmbeddings: Int = 131072
    var tieWordEmbeddings: Bool = false
    var attentionBias: Bool = false
    var headDim: Int?
    var ropeScaling: [String: StringOrNumber]?
    var fullAttentionInterval: Int = 4

    // MoE fields
    var numExperts: Int = 0
    var numExpertsPerTok: Int = 0
    var decoderSparseStep: Int = 1
    var sharedExpertIntermediateSize: Int = 0
    var moeIntermediateSize: Int = 0
    var normTopkProb: Bool = true

    /// Full-attention positions derived from the pinned configuration.  The
    /// model contract is interval-based; callers must not carry a guessed
    /// hard-coded layer list into a diagnostic run.
    var fullAttentionLayerIndices: [Int] {
        guard fullAttentionInterval > 0 else { return [] }
        return (0 ..< hiddenLayers).filter { ($0 + 1) % fullAttentionInterval == 0 }
    }

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case linearNumValueHeads = "linear_num_value_heads"
        case linearNumKeyHeads = "linear_num_key_heads"
        case linearKeyHeadDim = "linear_key_head_dim"
        case linearValueHeadDim = "linear_value_head_dim"
        case linearConvKernelDim = "linear_conv_kernel_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case partialRotaryFactor = "partial_rotary_factor"
        case maxPositionEmbeddings = "max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case headDim = "head_dim"
        case ropeScaling = "rope_scaling"
        case fullAttentionInterval = "full_attention_interval"
        case numExperts = "num_experts"
        case numExpertsPerTok = "num_experts_per_tok"
        case decoderSparseStep = "decoder_sparse_step"
        case sharedExpertIntermediateSize = "shared_expert_intermediate_size"
        case moeIntermediateSize = "moe_intermediate_size"
        case normTopkProb = "norm_topk_prob"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultRopeParameters: [String: StringOrNumber] = [
            "type": .string("default"),
            "mrope_section": .ints([11, 11, 10]),
            "rope_theta": .float(100000.0),
            "partial_rotary_factor": .float(0.25),
        ]

        self.modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? ""
        self.hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 4096
        self.hiddenLayers = try container.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 32
        self.intermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 14336
        self.attentionHeads = try container.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 32
        self.kvHeads = try container.decodeIfPresent(Int.self, forKey: .kvHeads) ?? 8
        self.linearNumValueHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumValueHeads) ?? 64
        self.linearNumKeyHeads =
            try container.decodeIfPresent(Int.self, forKey: .linearNumKeyHeads) ?? 16
        self.linearKeyHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearKeyHeadDim) ?? 192
        self.linearValueHeadDim =
            try container.decodeIfPresent(Int.self, forKey: .linearValueHeadDim) ?? 128
        self.linearConvKernelDim =
            try container.decodeIfPresent(Int.self, forKey: .linearConvKernelDim) ?? 4
        self.rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        self.vocabularySize =
            try container.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? 151_936
        self.maxPositionEmbeddings =
            try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        self.tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        self.attentionBias =
            try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        self.headDim = try container.decodeIfPresent(Int.self, forKey: .headDim)
        self.fullAttentionInterval =
            try container.decodeIfPresent(Int.self, forKey: .fullAttentionInterval) ?? 4

        // MoE fields
        self.numExperts = try container.decodeIfPresent(Int.self, forKey: .numExperts) ?? 0
        self.numExpertsPerTok =
            try container.decodeIfPresent(Int.self, forKey: .numExpertsPerTok) ?? 0
        self.decoderSparseStep =
            try container.decodeIfPresent(Int.self, forKey: .decoderSparseStep) ?? 1
        self.sharedExpertIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .sharedExpertIntermediateSize) ?? 0
        self.moeIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .moeIntermediateSize) ?? 0
        self.normTopkProb = try container.decodeIfPresent(Bool.self, forKey: .normTopkProb) ?? true

        let ropeContainer = try decoder.container(keyedBy: RopeParametersCodingKey.self)
        let ropeParameters = try ropeContainer.decodeIfPresent(
            [String: StringOrNumber].self, forKey: .ropeParameters)

        if var ropeParameters {
            if ropeParameters["type"] == nil, let ropeType = ropeParameters["rope_type"] {
                ropeParameters["type"] = ropeType
            }
            self.ropeTheta = ropeParameters["rope_theta"]?.asFloat() ?? 100000.0
            self.partialRotaryFactor =
                ropeParameters["partial_rotary_factor"]?.asFloat() ?? 0.25
            self.ropeScaling = ropeParameters
        } else {
            self.ropeTheta =
                try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 100000.0
            self.partialRotaryFactor =
                try container.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 0.25
            self.ropeScaling =
                try container.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling)
                ?? defaultRopeParameters
        }

        if self.headDim == nil {
            self.headDim = self.hiddenSize / self.attentionHeads
        }
    }
}

// MARK: - GatedDeltaNet

final class StreamQwen35GatedDeltaNet: Module {
    struct DiagnosticProjections {
        let qkv: MLXArray
        let z: MLXArray
        let b: MLXArray
        let a: MLXArray
    }

    /// Bounded, diagnostic-only handles for one linear-attention invocation.
    /// The production path does not retain these intermediates. Keeping the
    /// recurrent output and the post-gated projection separate lets the
    /// target comparison distinguish a kernel/state mismatch from an output
    /// projection mismatch without persisting hidden tensors.
    struct DiagnosticAttention {
        let projections: DiagnosticProjections
        let convOutput: MLXArray
        let qNormed: MLXArray
        let kNormed: MLXArray
        let v: MLXArray
        let gatedOutput: MLXArray
        let normalizedOutput: MLXArray
        let output: MLXArray
    }

    let hiddenSize: Int
    let numVHeads: Int
    let numKHeads: Int
    let headKDim: Int
    let headVDim: Int
    let keyDim: Int
    let valueDim: Int
    let convKernelSize: Int
    let convDim: Int

    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "in_proj_qkv") var inProjQKV: Linear
    @ModuleInfo(key: "in_proj_z") var inProjZ: Linear
    @ModuleInfo(key: "in_proj_b") var inProjB: Linear
    @ModuleInfo(key: "in_proj_a") var inProjA: Linear

    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray

    @ModuleInfo(key: "norm") var norm: StreamQwenNextRMSNormGated
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ args: StreamQwen35TextConfiguration) {
        self.hiddenSize = args.hiddenSize
        self.numVHeads = args.linearNumValueHeads
        self.numKHeads = args.linearNumKeyHeads
        self.headKDim = args.linearKeyHeadDim
        self.headVDim = args.linearValueHeadDim
        self.keyDim = headKDim * numKHeads
        self.valueDim = headVDim * numVHeads
        self.convKernelSize = args.linearConvKernelDim
        self.convDim = keyDim * 2 + valueDim

        precondition(
            numVHeads % numKHeads == 0,
            "num_v_heads (\(numVHeads)) must be divisible by num_k_heads (\(numKHeads))"
        )

        _conv1d.wrappedValue = Conv1d(
            inputChannels: convDim,
            outputChannels: convDim,
            kernelSize: convKernelSize,
            stride: 1,
            padding: 0,
            dilation: 1,
            groups: convDim,
            bias: false
        )

        _inProjQKV.wrappedValue = Linear(hiddenSize, keyDim * 2 + valueDim, bias: false)
        _inProjZ.wrappedValue = Linear(hiddenSize, valueDim, bias: false)
        _inProjB.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)
        _inProjA.wrappedValue = Linear(hiddenSize, numVHeads, bias: false)

        _dtBias.wrappedValue = MLXArray.ones([numVHeads])
        let a = MLXRandom.uniform(low: 0, high: 16, [numVHeads])
        _aLog.wrappedValue = log(a)

        _norm.wrappedValue = StreamQwenNextRMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)
        _outProj.wrappedValue = Linear(valueDim, hiddenSize, bias: false)

        super.init()
    }

    func diagnosticProjections(_ inputs: MLXArray) -> DiagnosticProjections {
        let qkv = inProjQKV(inputs)
        let z = inProjZ(inputs)
        let b = inProjB(inputs)
        let a = inProjA(inputs)
        MLX.eval(qkv, z, b, a)
        return DiagnosticProjections(qkv: qkv, z: z, b: b, a: a)
    }

    /// Runs the exact native linear-attention path once and exposes only
    /// bounded diagnostic handles. This intentionally mirrors
    /// `callAsFunction` line-for-line; it is used only by the Q2.5
    /// localization probe.
    func callWithDiagnostics(
        _ inputs: MLXArray,
        mask: MLXArray? = nil,
        cache: MambaCache? = nil
    ) -> DiagnosticAttention {
        let B = inputs.dim(0)
        let S = inputs.dim(1)

        let projections = DiagnosticProjections(
            qkv: inProjQKV(inputs),
            z: inProjZ(inputs),
            b: inProjB(inputs),
            a: inProjA(inputs))
        var qkv = projections.qkv
        let z = projections.z.reshaped(B, S, numVHeads, headVDim)

        let convState: MLXArray
        if let cacheState = cache?[0] {
            convState = cacheState
        } else {
            convState = MLXArray.zeros([B, convKernelSize - 1, convDim], dtype: inputs.dtype)
        }

        if let mask {
            qkv = MLX.where(mask[.ellipsis, .newAxis], qkv, 0)
        }
        let convInput = concatenated([convState, qkv], axis: 1)
        if let cache {
            cache[0] = contiguous(convInput[0..., (-(convKernelSize - 1))..., 0...])
        }
        let convOutput = silu(conv1d(convInput))
        let convSplit = MLX.split(convOutput, indices: [keyDim, 2 * keyDim], axis: -1)
        let q = convSplit[0].reshaped(B, S, numKHeads, headKDim)
        let k = convSplit[1].reshaped(B, S, numKHeads, headKDim)
        let v = convSplit[2].reshaped(B, S, numVHeads, headVDim)

        var state = cache?[1]
        let dtype = q.dtype
        let invScale = pow(Float(headKDim), -0.5)
        let qNormed =
            MLXArray(pow(invScale, 2)).asType(dtype)
            * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
        let kNormed =
            MLXArray(invScale).asType(dtype)
            * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

        let (gatedOutput, newState) = gatedDeltaUpdate(
            q: qNormed,
            k: kNormed,
            v: v,
            a: projections.a,
            b: projections.b,
            aLog: aLog,
            dtBias: dtBias,
            state: state,
            mask: mask)
        state = newState
        if let cache {
            cache[1] = state
            cache.advance(S)
        }

        let normalizedOutput = norm(gatedOutput, gate: z)
        let output = outProj(normalizedOutput.reshaped(B, S, -1))
        MLX.eval(
            projections.qkv, projections.z, projections.b, projections.a,
            convOutput, qNormed, kNormed, v, gatedOutput, normalizedOutput, output)
        return DiagnosticAttention(
            projections: projections,
            convOutput: convOutput,
            qNormed: qNormed,
            kNormed: kNormed,
            v: v,
            gatedOutput: gatedOutput,
            normalizedOutput: normalizedOutput,
            output: output)
    }

    func callAsFunction(
        _ inputs: MLXArray,
        mask: MLXArray? = nil,
        cache: MambaCache? = nil
    ) -> MLXArray {
        let B = inputs.dim(0)
        let S = inputs.dim(1)

        var qkv = inProjQKV(inputs)
        let z = inProjZ(inputs).reshaped(B, S, numVHeads, headVDim)
        let b = inProjB(inputs)
        let a = inProjA(inputs)

        let convState: MLXArray
        if let cacheState = cache?[0] {
            convState = cacheState
        } else {
            convState = MLXArray.zeros([B, convKernelSize - 1, convDim], dtype: inputs.dtype)
        }

        if let mask {
            qkv = MLX.where(mask[.ellipsis, .newAxis], qkv, 0)
        }

        let convInput = concatenated([convState, qkv], axis: 1)
        if let cache {
            cache[0] = contiguous(convInput[0..., (-(convKernelSize - 1))..., 0...])
        }

        let convOut = silu(conv1d(convInput))

        let convSplit = MLX.split(convOut, indices: [keyDim, 2 * keyDim], axis: -1)
        let q = convSplit[0].reshaped(B, S, numKHeads, headKDim)
        let k = convSplit[1].reshaped(B, S, numKHeads, headKDim)
        let v = convSplit[2].reshaped(B, S, numVHeads, headVDim)

        var state = cache?[1]
        let dtype = q.dtype
        let invScale = pow(Float(headKDim), -0.5)
        let qNormed =
            MLXArray(pow(invScale, 2)).asType(dtype)
            * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
        let kNormed =
            MLXArray(invScale).asType(dtype)
            * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

        var out: MLXArray

        (out, state) = gatedDeltaUpdate(
            q: qNormed,
            k: kNormed,
            v: v,
            a: a,
            b: b,
            aLog: aLog,
            dtBias: dtBias,
            state: state,
            mask: mask
        )

        if let cache {
            cache[1] = state
            cache.advance(S)
        }

        out = norm(out, gate: z)
        return outProj(out.reshaped(B, S, -1))
    }
}

// MARK: - Attention

/// Attention execution choices for the Qwen3.5 full-attention layers.
///
/// - ``productionFused`` is the shipped ``attentionWithCacheUpdate`` path.
/// - ``referenceCompatibleExplicit`` replays the pinned independent Python
///   expression with ordinary MLX operations.  Q2.16/Q2.17 validated it
///   against the MLX 0.31.1 Metal K=8 reference, so it is the known-correct
///   native baseline.
/// - ``candidateHybrid`` is the Q2.18 correctness-gated candidate.  It is a
///   pure function of the query length and is only admissible if the qLen=1
///   fused compatibility matrix passes.
///
/// No strategy silently falls back to another: every invocation records both
/// the requested and the effective strategy, and ``effective(queryLength:)``
/// is the only place a request is resolved.
enum StreamQwen35AttentionStrategy: String, Sendable, CaseIterable {
    case productionFused
    case referenceCompatibleExplicit
    case candidateHybrid

    /// True when this value names a concrete kernel rather than a rule that
    /// selects one.  Only concrete strategies may reach an attention call.
    var isConcrete: Bool { self != .candidateHybrid }

    /// Whether the concrete strategy uses the explicit ordinary-MLX replay.
    var usesExplicitAttention: Bool { self == .referenceCompatibleExplicit }

    /// Resolves a possibly-hybrid request into the concrete strategy that will
    /// actually execute for one attention call.
    ///
    /// The hybrid rule is deliberately semantic and shape-only:
    /// `queryLength > 1` (a multi-token prefill group) takes the validated
    /// explicit path, and `queryLength == 1` (a cached decode step) takes the
    /// fused path.  It is keyed to nothing else — not to a layer index, a
    /// position, a prompt, or an expert ID — so it cannot encode a whitelist
    /// of known failures.
    func effective(queryLength: Int) -> StreamQwen35AttentionStrategy {
        switch self {
        case .productionFused, .referenceCompatibleExplicit:
            return self
        case .candidateHybrid:
            return queryLength > 1 ? .referenceCompatibleExplicit : .productionFused
        }
    }

    /// A short, stable label for reports and diagnostics.
    var reportLabel: String { rawValue }

    /// The strategy the shipping Qwen3.5 generation path uses.
    ///
    /// Q2.18 decision (outcome C). The fused qLen=1 decode hypothesis was
    /// tested and rejected: over a teacher-forced golden history it produced
    /// 450 true K=8 routing membership differences out of 2,560 comparisons,
    /// two predicted-token differences, and zero byte-identical block outputs
    /// at layer 19. The hybrid built on it diverged from the accepted
    /// independent 64-token golden at generated index 21 with 4 of 21 sampled
    /// router memberships wrong. Fused-everywhere is worse: over a 128-token
    /// native explicit-control extension it differed from the validated
    /// baseline in 52 of 128 tokens.
    ///
    /// ``referenceCompatibleExplicit`` is the path Q2.16/Q2.17 validated
    /// against the pinned MLX 0.31.1 Metal reference — 64/64 token IDs, 63
    /// cached-decode calls, 730 explicit invocations, zero fused invocations,
    /// zero true router membership failures — and it costs only ~5% decode
    /// throughput and ~4% end-to-end time versus the unvalidated fused path,
    /// while using less peak memory. Correctness is therefore the default.
    ///
    /// This is the single source of truth: every API default in the Qwen
    /// streaming stack resolves through it, so no diagnostic or production
    /// entry point can silently execute a strategy that production does not.
    static let productionDefault: StreamQwen35AttentionStrategy = .referenceCompatibleExplicit
}

/// Evaluated intermediates for the developer-only reference-compatible SDPA
/// candidate.  The arrays are returned in the native attention layout
/// ``[batch, heads, queryLength, headDim]`` and are retained only by opt-in
/// tests.  No fast SDPA primitive is called here.
struct StreamQwen35ExplicitAttentionTrace {
    let expandedKeys: MLXArray
    let expandedValues: MLXArray
    let rawQK: MLXArray
    let scaledScores: MLXArray
    let maskedScores: MLXArray
    let probabilities: MLXArray
    let weightedOutputFloat32: MLXArray
    let output: MLXArray
}

/// Mutable only inside the serialized diagnostic generation gate. Normal
/// inference never creates or observes this counter.
final class StreamQwen35AttentionDiagnosticCounters: @unchecked Sendable {
    var fusedInvocations = 0
    var explicitInvocations = 0
    /// Per-layer counts are retained only by opt-in validation callers. They
    /// prove that a requested explicit run actually exercised every
    /// config-derived full-attention layer in both prefill and cached decode.
    var fusedInvocationsByLayer: [Int: Int] = [:]
    var explicitInvocationsByLayer: [Int: Int] = [:]
    var explicitQueryLengthsByLayer: [Int: [Int]] = [:]
    var fusedQueryLengthsByLayer: [Int: [Int]] = [:]
    var lastLayer: Int?
    var lastGroup: Int?
    var lastRequestedStrategy: StreamQwen35AttentionStrategy?
    var lastEffectiveStrategy: StreamQwen35AttentionStrategy?

    /// Q2.18 phase breakdown.  "Prefill" means a multi-token query
    /// (`queryLength > 1`); "decode" means a cached single-token query
    /// (`queryLength == 1`).  The hybrid candidate is only describable with
    /// this split, because its effective strategy varies per call.
    var fusedPrefillInvocations = 0
    var explicitPrefillInvocations = 0
    var fusedDecodeInvocations = 0
    var explicitDecodeInvocations = 0

    /// Every strategy requested during the run, and every concrete strategy
    /// that actually executed.  A hybrid run therefore reports both concrete
    /// strategies here while requesting only ``.candidateHybrid``.
    var requestedStrategies = Set<StreamQwen35AttentionStrategy>()
    var effectiveStrategies = Set<StreamQwen35AttentionStrategy>()

    /// Distinct query lengths observed per concrete strategy.  Bounded so a
    /// long generation cannot grow this without limit.
    var fusedQueryLengths = Set<Int>()
    var explicitQueryLengths = Set<Int>()

    /// Observed shapes as `queryLength x keyLength`, bounded and de-duplicated.
    /// These are the real production shapes the Q2.18 compatibility matrix
    /// must cover rather than invented synthetic contexts.
    var fusedShapes = Set<String>()
    var explicitShapes = Set<String>()

    func record(
        requested: StreamQwen35AttentionStrategy,
        effective: StreamQwen35AttentionStrategy,
        layer: Int?,
        queryLength: Int,
        keyLength: Int? = nil
    ) {
        precondition(effective.isConcrete, "an attention call must resolve to a concrete strategy")
        requestedStrategies.insert(requested)
        effectiveStrategies.insert(effective)
        lastRequestedStrategy = requested
        lastEffectiveStrategy = effective

        let isDecode = queryLength == 1
        let shape = keyLength.map { "\(queryLength)x\($0)" }
        switch effective {
        case .productionFused:
            fusedInvocations += 1
            if isDecode { fusedDecodeInvocations += 1 } else { fusedPrefillInvocations += 1 }
            fusedQueryLengths.insert(queryLength)
            if let shape { fusedShapes.insert(shape) }
        case .referenceCompatibleExplicit, .candidateHybrid:
            explicitInvocations += 1
            if isDecode { explicitDecodeInvocations += 1 } else { explicitPrefillInvocations += 1 }
            explicitQueryLengths.insert(queryLength)
            if let shape { explicitShapes.insert(shape) }
        }

        guard let layer else { return }
        switch effective {
        case .productionFused:
            fusedInvocationsByLayer[layer, default: 0] += 1
            fusedQueryLengthsByLayer[layer, default: []].append(queryLength)
        case .referenceCompatibleExplicit, .candidateHybrid:
            explicitInvocationsByLayer[layer, default: 0] += 1
            explicitQueryLengthsByLayer[layer, default: []].append(queryLength)
        }
    }

    /// Clears the run-scoped accumulators so one engine instance can serve a
    /// counterbalanced A/B without leaking counts between scored trials.
    func reset() {
        fusedInvocations = 0
        explicitInvocations = 0
        fusedInvocationsByLayer = [:]
        explicitInvocationsByLayer = [:]
        explicitQueryLengthsByLayer = [:]
        fusedQueryLengthsByLayer = [:]
        lastLayer = nil
        lastGroup = nil
        lastRequestedStrategy = nil
        lastEffectiveStrategy = nil
        fusedPrefillInvocations = 0
        explicitPrefillInvocations = 0
        fusedDecodeInvocations = 0
        explicitDecodeInvocations = 0
        requestedStrategies = []
        effectiveStrategies = []
        fusedQueryLengths = []
        explicitQueryLengths = []
        fusedShapes = []
        explicitShapes = []
    }

    /// Compact one-line report used by the Q2.18 validation logs.
    var summary: String {
        let requested = requestedStrategies.map(\.reportLabel).sorted().joined(separator: "+")
        let effective = effectiveStrategies.map(\.reportLabel).sorted().joined(separator: "+")
        return "requested=\(requested.isEmpty ? "none" : requested) effective=\(effective.isEmpty ? "none" : effective) "
            + "fused=\(fusedInvocations) explicit=\(explicitInvocations) "
            + "fusedPrefill=\(fusedPrefillInvocations) explicitPrefill=\(explicitPrefillInvocations) "
            + "fusedDecode=\(fusedDecodeInvocations) explicitDecode=\(explicitDecodeInvocations)"
    }
}

final class StreamQwen35Attention: Module {
    struct DiagnosticAttention {
        struct SDPAInvocation {
            let scale: Float
            let scaleBits: UInt32
            let scaleExpression: String
            let maskMode: String
            let mask: MLXArray?
            let queries: MLXArray
            let keys: MLXArray
            let values: MLXArray
            let cachedKeys: MLXArray?
            let cachedValues: MLXArray?
            let output: MLXArray
            let requestedStrategy: StreamQwen35AttentionStrategy
            let effectiveStrategy: StreamQwen35AttentionStrategy
            let explicitTrace: StreamQwen35ExplicitAttentionTrace?
            let sentinelApplied: Bool
        }

        let queryProjection: MLXArray
        let gate: MLXArray
        let queries: MLXArray
        let keys: MLXArray
        let values: MLXArray
        let attentionValues: MLXArray
        let gatedValues: MLXArray
        let output: MLXArray
        let sdpa: SDPAInvocation
    }

    let attentionHeads: Int
    let kvHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPELayer

    init(_ args: StreamQwen35TextConfiguration) {
        let headDim = args.headDim ?? (args.hiddenSize / args.attentionHeads)
        self.attentionHeads = args.attentionHeads
        self.kvHeads = args.kvHeads
        self.scale = pow(Float(headDim), -0.5)

        _qProj.wrappedValue = Linear(
            args.hiddenSize, args.attentionHeads * headDim * 2, bias: args.attentionBias)
        _kProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias)
        _vProj.wrappedValue = Linear(
            args.hiddenSize, args.kvHeads * headDim, bias: args.attentionBias)
        _oProj.wrappedValue = Linear(
            args.attentionHeads * headDim, args.hiddenSize, bias: args.attentionBias)

        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        let ropeDims = Int(Float(headDim) * args.partialRotaryFactor)
        self.rope = initializeRope(
            dims: max(1, ropeDims),
            base: args.ropeTheta,
            traditional: false,
            scalingConfig: args.ropeScaling,
            maxPositionEmbeddings: args.maxPositionEmbeddings
        )

        super.init()
    }

    /// Replays the pinned Python explicit attention expression with ordinary
    /// MLX operations.  This is a developer-only reference candidate for the
    /// Q2.11 primitive localization; it is not used by ``callAsFunction``.
    ///
    /// The Python contract is deliberately visible here:
    ///
    /// 1. Expand the two KV heads to sixteen query heads with ``repeat`` on
    ///    axis 1 (GQA ratio 8).
    /// 2. Convert Q/K/V to Float32.  Preserve the reference's scale-before-
    ///    matmul order for the scored path while also returning an unscaled
    ///    QK product for localization.
    /// 3. Apply the [queryLength, keyLength] Boolean mask by replacing false
    ///    cells with Float32's finite minimum.
    /// 4. Use precise Float32 softmax, multiply by V in Float32, then cast the
    ///    result to BF16.  The returned ``output`` remains untransposed.
    static func referenceCompatibleExplicitAttention(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        mask: MLXArray
    ) -> StreamQwen35ExplicitAttentionTrace {
        precondition(queries.ndim == 4, "Q2.11 explicit attention expects rank-4 queries")
        precondition(keys.ndim == 4 && values.ndim == 4,
                     "Q2.11 explicit attention expects rank-4 KV tensors")
        precondition(queries.dim(1) % keys.dim(1) == 0,
                     "query heads must be divisible by KV heads")
        precondition(mask.ndim == 2,
                     "Q2.11 explicit attention expects a [queryLength,keyLength] mask")

        let repeats = queries.dim(1) / keys.dim(1)
        let expandedKeys = repeated(keys, count: repeats, axis: 1)
        let expandedValues = repeated(values, count: repeats, axis: 1)

        let qFloat = queries.asType(.float32)
        let kFloat = expandedKeys.asType(.float32)
        let vFloat = expandedValues.asType(.float32)
        let transposedKeys = kFloat.swappedAxes(-1, -2)
        let rawQK = matmul(qFloat, transposedKeys)
        // mlx-lm's independent replay scales Q before the matrix product. Do
        // not rewrite this as rawQK * scale: that changes the rounding path.
        let scaledScores = matmul(
            qFloat * MLXArray(scale, dtype: .float32), transposedKeys)
        let expandedMask = mask.expandedDimensions(axes: [0, 1])
        let maskedScores = MLX.where(
            expandedMask,
            scaledScores,
            MLXArray(-Float.greatestFiniteMagnitude, dtype: .float32))
        let probabilities = softmax(maskedScores, axis: -1, precise: true)
        let weightedOutputFloat32 = matmul(probabilities, vFloat)
        let output = weightedOutputFloat32.asType(.bfloat16)

        // Explicit evaluation is part of this diagnostic seam. It makes the
        // exported intermediates stable and prevents a later summary from
        // accidentally retaining a graph instead of completed values.
        MLX.eval(
            expandedKeys, expandedValues, rawQK, scaledScores, maskedScores,
            probabilities, weightedOutputFloat32, output)
        return StreamQwen35ExplicitAttentionTrace(
            expandedKeys: expandedKeys,
            expandedValues: expandedValues,
            rawQK: rawQK,
            scaledScores: scaledScores,
            maskedScores: maskedScores,
            probabilities: probabilities,
            weightedOutputFloat32: weightedOutputFloat32,
            output: output)
    }

    /// Diagnostic dispatch point.  Keeping the strategy argument at this
    /// seam prevents the explicit candidate from becoming an accidental
    /// production fallback.  The fused case is intentionally unavailable to
    /// this trace API because production already owns that path above.
    static func diagnosticAttentionTrace(
        strategy: StreamQwen35AttentionStrategy,
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        mask: MLXArray
    ) -> StreamQwen35ExplicitAttentionTrace {
        switch strategy {
        case .referenceCompatibleExplicit:
            return referenceCompatibleExplicitAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: mask)
        case .productionFused, .candidateHybrid:
            preconditionFailure(
                "only referenceCompatibleExplicit has an explicit diagnostic trace; "
                + "the fused kernel is owned by callAsFunction")
        }
    }

    /// Q2.18 SDPA compatibility probe.  This is the only place where the fused
    /// kernel and the explicit reference replay are evaluated from
    /// byte-identical inputs, and it exists purely as a diagnostic: ordinary
    /// generation must choose one path *before* computing attention.
    ///
    /// Three outputs are returned so the report can separate two independent
    /// sources of difference:
    ///
    /// - ``fusedProductionMask``: the fused kernel with the mask mode the
    ///   production decoder actually passes (`.causal` for a multi-token
    ///   prefill group, `.none` for a cached single-token decode).
    /// - ``fusedSameMask``: the fused kernel fed the *materialized* mask the
    ///   explicit path uses, isolating kernel numerics from mask semantics.
    /// - ``explicit``: the validated ordinary-MLX replay.
    struct StreamQwen35SDPACompatibilityProbe {
        let queryLength: Int
        let keyLength: Int
        let queryHeads: Int
        let kvHeads: Int
        let headDim: Int
        let scale: Float
        let productionMaskMode: String
        let fusedProductionMask: MLXArray
        let fusedSameMask: MLXArray
        let explicit: MLXArray
    }

    static func sdpaCompatibilityProbe(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        productionMaskMode: MLXFast.ScaledDotProductAttentionMaskMode,
        explicitMask: MLXArray
    ) -> StreamQwen35SDPACompatibilityProbe {
        precondition(queries.ndim == 4 && keys.ndim == 4 && values.ndim == 4,
                     "Q2.18 compatibility probe expects rank-4 Q/K/V")
        precondition(explicitMask.ndim == 2,
                     "Q2.18 compatibility probe expects a [queryLength,keyLength] mask")
        let queryLength = queries.dim(2)
        let keyLength = keys.dim(2)
        precondition(explicitMask.dim(0) == queryLength && explicitMask.dim(1) == keyLength,
                     "Q2.18 compatibility probe mask shape must match Q/K")

        let fusedProduction = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values,
            scale: scale, mask: productionMaskMode)
        let fusedSame = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values,
            scale: scale, mask: .array(explicitMask))
        let explicitTrace = referenceCompatibleExplicitAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: explicitMask)
        MLX.eval(fusedProduction, fusedSame, explicitTrace.output)
        return StreamQwen35SDPACompatibilityProbe(
            queryLength: queryLength,
            keyLength: keyLength,
            queryHeads: queries.dim(1),
            kvHeads: keys.dim(1),
            headDim: queries.dim(3),
            scale: scale,
            productionMaskMode: productionMaskMode.mode.isEmpty ? "none/array" : productionMaskMode.mode,
            fusedProductionMask: fusedProduction,
            fusedSameMask: fusedSame,
            explicit: explicitTrace.output)
    }

    /// Diagnostic-only full-attention decomposition.  It follows the
    /// production call line-for-line and exposes only bounded handles for the
    /// opt-in Q2.9 boundary fixture.
    func callWithDiagnostics(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?,
        strategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticLayer: Int? = nil,
        diagnosticGroup: Int? = nil,
        diagnosticSentinel: Float? = nil
    ) -> DiagnosticAttention {
        let B = x.dim(0)
        let L = x.dim(1)

        let queryProjection = qProj(x)
        let qSplit = queryProjection.reshaped(B, L, attentionHeads, -1).split(parts: 2, axis: -1)
        var queries = qSplit[0]
        let gate = qSplit[1].reshaped(B, L, -1)

        var keys = kProj(x)
        var values = vProj(x)
        queries = qNorm(queries).transposed(0, 2, 1, 3)
        keys = kNorm(keys.reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        // Keep the diagnostic decomposition in the same layout as the
        // production attention kernel: [batch, kvHeads, sequence, headDim].
        values = values.reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        let cacheOffsetBeforeUpdate = cache?.offset ?? 0
        // One resolution point for the requested strategy. The effective value
        // is what gets counted and reported, so a hybrid run can never claim
        // fused coverage it did not execute.
        let effective = strategy.effective(queryLength: L)
        let keyLength = cache == nil ? L : cacheOffsetBeforeUpdate + L
        let explicitTrace: StreamQwen35ExplicitAttentionTrace?
        var rawAttention: MLXArray
        if effective == .productionFused {
            diagnosticCounters?.record(
                requested: strategy, effective: effective, layer: diagnosticLayer,
                queryLength: L, keyLength: keyLength)
            explicitTrace = nil
            rawAttention = attentionWithCacheUpdate(
                queries: queries,
                keys: keys,
                values: values,
                cache: cache,
                scale: scale,
                mask: mask)
        } else {
            diagnosticCounters?.record(
                requested: strategy, effective: effective, layer: diagnosticLayer,
                queryLength: L, keyLength: keyLength)
            let cachedKeys: MLXArray
            let cachedValues: MLXArray
            if let cache {
                (cachedKeys, cachedValues) = cache.update(keys: keys, values: values)
            } else {
                cachedKeys = keys
                cachedValues = values
            }
            let explicitMask = Self.materializedMask(
                mask, queryLength: L, keyLength: cachedKeys.dim(2),
                cacheOffset: cacheOffsetBeforeUpdate)
            let trace = Self.referenceCompatibleExplicitAttention(
                queries: queries,
                keys: cachedKeys,
                values: cachedValues,
                scale: scale,
                mask: explicitMask)
            explicitTrace = trace
            rawAttention = trace.output
            // This hook exists only for the opt-in data-flow sentinel test. It
            // is never passed by production generation and is compile-gated so
            // a release build cannot acquire a hidden numerical perturbation.
            // The trace itself remains the unsentinelled helper result.
            #if DEBUG
            if let diagnosticSentinel {
                rawAttention = rawAttention + MLXArray(
                    diagnosticSentinel, dtype: rawAttention.dtype)
            }
            #endif
        }
        diagnosticCounters?.lastLayer = diagnosticLayer
        diagnosticCounters?.lastGroup = diagnosticGroup
        diagnosticCounters?.lastRequestedStrategy = strategy
        diagnosticCounters?.lastEffectiveStrategy = effective
        let sentinelApplied: Bool
        #if DEBUG
        sentinelApplied = effective == .referenceCompatibleExplicit && diagnosticSentinel != nil
        #else
        sentinelApplied = false
        #endif
        let attentionValues = rawAttention
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
        let gatedValues = streamQwenSigmoidMultiply(attentionValues, gate)
        let output = oProj(gatedValues)
        let sdpa = DiagnosticAttention.SDPAInvocation(
            scale: scale,
            scaleBits: scale.bitPattern,
            scaleExpression: "pow(Float(headDim), -0.5)",
            maskMode: mask.mode,
            mask: mask.mask,
            queries: queries,
            keys: keys,
            values: values,
            cachedKeys: cache?.state.first,
            cachedValues: cache?.state.dropFirst().first,
            output: rawAttention,
            requestedStrategy: strategy,
            effectiveStrategy: effective,
            explicitTrace: explicitTrace,
            sentinelApplied: sentinelApplied)
        MLX.eval(
            queryProjection, gate, queries, keys, values,
            rawAttention, attentionValues, gatedValues, output)
        return DiagnosticAttention(
            queryProjection: queryProjection,
            gate: gate,
            queries: queries,
            keys: keys,
            values: values,
            attentionValues: attentionValues,
            gatedValues: gatedValues,
            output: output,
            sdpa: sdpa)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        callWithStrategy(
            x,
            mask: mask,
            cache: cache,
            strategy: .productionDefault)
    }

    /// Executes one attention block with the requested developer-only
    /// strategy.  The default production entry point above stays fused; the
    /// explicit case is used only by bounded parity probes and never becomes
    /// an implicit fallback after a fused failure.
    func callWithStrategy(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?,
        strategy: StreamQwen35AttentionStrategy,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticLayer: Int? = nil,
        diagnosticGroup: Int? = nil
    ) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        let qProjOutput = qProj(x)
        let qSplit = qProjOutput.reshaped(B, L, attentionHeads, -1).split(parts: 2, axis: -1)
        var queries = qSplit[0]
        let gate = qSplit[1].reshaped(B, L, -1)

        var keys = kProj(x)
        var values = vProj(x)

        queries = qNorm(queries).transposed(0, 2, 1, 3)
        keys = kNorm(keys.reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        // Single resolution point, identical to callWithDiagnostics: the
        // hybrid candidate is a pure function of the query length and never a
        // per-layer or per-position whitelist.
        let effective = strategy.effective(queryLength: L)
        let cacheOffsetBeforeUpdate = cache?.offset ?? 0
        let rawAttention: MLXArray
        if effective == .productionFused {
            diagnosticCounters?.record(
                requested: strategy, effective: effective, layer: diagnosticLayer,
                queryLength: L,
                keyLength: cache == nil ? L : cacheOffsetBeforeUpdate + L)
            rawAttention = attentionWithCacheUpdate(
                queries: queries,
                keys: keys,
                values: values,
                cache: cache,
                scale: scale,
                mask: mask)
        } else {
            diagnosticCounters?.record(
                requested: strategy, effective: effective, layer: diagnosticLayer,
                queryLength: L,
                keyLength: cache == nil ? L : cacheOffsetBeforeUpdate + L)
            let cachedKeys: MLXArray
            let cachedValues: MLXArray
            if let cache {
                (cachedKeys, cachedValues) = cache.update(keys: keys, values: values)
            } else {
                cachedKeys = keys
                cachedValues = values
            }
            let explicitMask = Self.materializedMask(
                mask, queryLength: L, keyLength: cachedKeys.dim(2),
                cacheOffset: cacheOffsetBeforeUpdate)
            let trace = Self.referenceCompatibleExplicitAttention(
                queries: queries,
                keys: cachedKeys,
                values: cachedValues,
                scale: scale,
                mask: explicitMask)
            rawAttention = trace.output
        }

        diagnosticCounters?.lastLayer = diagnosticLayer
        diagnosticCounters?.lastGroup = diagnosticGroup
        diagnosticCounters?.lastRequestedStrategy = strategy
        diagnosticCounters?.lastEffectiveStrategy = effective

        let output = rawAttention
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)

        return oProj(streamQwenSigmoidMultiply(output, gate))
    }

    /// Converts the mask mode the production decoder passes into the
    /// materialized `[queryLength, keyLength]` Boolean mask the explicit
    /// reference replay requires.  `.none` at a cached single-token decode is
    /// semantically "attend to every cached key", which is an all-true mask.
    static func materializedMask(
        _ mask: MLXFast.ScaledDotProductAttentionMaskMode,
        queryLength: Int,
        keyLength: Int,
        cacheOffset: Int
    ) -> MLXArray {
        switch mask {
        case .none:
            return MLXArray.ones([queryLength, keyLength], dtype: .bool)
        case .array(let array):
            return array
        case .arrays(let arrays):
            return arrays.first
                ?? MLXArray.ones([queryLength, keyLength], dtype: .bool)
        case .causal:
            return createCausalMask(n: queryLength, offset: cacheOffset)
        }
    }
}

// MARK: - SparseMoeBlock

final class StreamQwen35SparseMoeBlock: Module {
    struct DiagnosticComponents {
        let routerInput: MLXArray
        let routerLogits: MLXArray
        let routedOutput: MLXArray
        let sharedOutput: MLXArray
        let output: MLXArray
    }

    let normTopkProb: Bool
    let numExperts: Int
    let topK: Int

    @ModuleInfo(key: "gate") var gate: Linear

    @ModuleInfo(key: "shared_expert") var sharedExpert: StreamQwenNextMLP
    @ModuleInfo(key: "shared_expert_gate") var sharedExpertGate: Linear

    init(_ args: StreamQwen35TextConfiguration) {
        self.normTopkProb = args.normTopkProb
        self.numExperts = args.numExperts
        self.topK = args.numExpertsPerTok

        _gate.wrappedValue = Linear(args.hiddenSize, args.numExperts, bias: false)

        _sharedExpert.wrappedValue = StreamQwenNextMLP(
            dimensions: args.hiddenSize,
            hiddenDimensions: args.sharedExpertIntermediateSize
        )
        _sharedExpertGate.wrappedValue = Linear(args.hiddenSize, 1, bias: false)
    }

    func callAsFunction(_ x: MLXArray, layer: Int, pool: QwenStreamExpertPool) async throws -> MLXArray {
        let routerLogits = gate(x)
        var gates = routerLogits
        gates = MLX.softmax(gates, axis: -1, precise: true)

        let k = topK
        let kth = gates.dim(-1) - k
        let inds = MLX.argPartition(gates, kth: kth, axis: -1)[.ellipsis, (kth)...]
        var scores = MLX.takeAlong(gates, inds, axis: -1)
        if normTopkProb {
            scores = scores / scores.sum(axis: -1, keepDims: true)
        }

        // Only actual K=8 demand enters the pool; router ordering stays upstream.
        if pool.routerTraceEnabled {
            MLX.eval(routerLogits, inds, scores)
            pool.recordRouter(
                layer: layer,
                logits: routerLogits,
                expertIDs: inds,
                scores: scores,
                selectorScores: gates,
                routerInput: x)
        } else {
            MLX.eval(inds, scores)
        }
        let y = try await pool.evaluate(x, layer: layer, expertIDs: inds.asArray(Int.self))
        let combined = weightedExpertSum(y, scores)

        var sharedY = sharedExpert(x)
        sharedY = sigmoid(sharedExpertGate(x)) * sharedY

        return combined + sharedY
    }

    /// Diagnostic-only decomposition of the MoE branch. It follows the
    /// production route once and retains only arrays selected by the caller;
    /// normal generation never asks for these intermediate values.
    func callWithComponents(
        _ x: MLXArray,
        layer: Int,
        pool: QwenStreamExpertPool
    ) async throws -> DiagnosticComponents {
        let routerLogits = gate(x)
        let gates = MLX.softmax(routerLogits, axis: -1, precise: true)
        let kth = gates.dim(-1) - topK
        let expertIDs = MLX.argPartition(gates, kth: kth, axis: -1)[.ellipsis, (kth)...]
        var scores = MLX.takeAlong(gates, expertIDs, axis: -1)
        if normTopkProb {
            scores = scores / scores.sum(axis: -1, keepDims: true)
        }
        if pool.routerTraceEnabled {
            MLX.eval(routerLogits, expertIDs, scores)
            pool.recordRouter(
                layer: layer,
                logits: routerLogits,
                expertIDs: expertIDs,
                scores: scores,
                selectorScores: gates,
                routerInput: x)
        } else {
            MLX.eval(expertIDs, scores)
        }
        let routed = try await pool.evaluate(x, layer: layer, expertIDs: expertIDs.asArray(Int.self))
        let combined = weightedExpertSum(routed, scores)
        let shared = sigmoid(sharedExpertGate(x)) * sharedExpert(x)
        let output = combined + shared
        MLX.eval(routerLogits, routed, combined, shared, output)
        return DiagnosticComponents(
            routerInput: x,
            routerLogits: routerLogits,
            // Keep the diagnostic schema comparable with the independent oracle:
            // the native pool keeps the per-expert stack internally, but the
            // decoder observes the weighted routed aggregate.
            routedOutput: combined,
            sharedOutput: shared,
            output: output)
    }
}

// MARK: - Decoder Layer

final class StreamQwen35DecoderLayer: Module {
    struct DiagnosticComponents {
        let layerInput: MLXArray
        let attentionInput: MLXArray
        let attentionOutput: MLXArray
        let postAttentionResidual: MLXArray
        let postAttentionInput: MLXArray
        let mlpOutput: MLXArray
        let output: MLXArray
        let routerInput: MLXArray
        let routerLogits: MLXArray
        let routedOutput: MLXArray
        let sharedOutput: MLXArray
        let linearProjections: StreamQwen35GatedDeltaNet.DiagnosticProjections?
        let linearAttention: StreamQwen35GatedDeltaNet.DiagnosticAttention?
        let fullAttention: StreamQwen35Attention.DiagnosticAttention?
    }

    let isLinear: Bool

    @ModuleInfo(key: "self_attn") var selfAttn: StreamQwen35Attention?
    @ModuleInfo(key: "linear_attn") var linearAttn: StreamQwen35GatedDeltaNet?

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    @ModuleInfo(key: "mlp") var mlp: Module

    init(_ args: StreamQwen35TextConfiguration, layerIdx: Int) {
        self.isLinear = (layerIdx + 1) % args.fullAttentionInterval != 0

        if isLinear {
            _linearAttn.wrappedValue = StreamQwen35GatedDeltaNet(args)
        } else {
            _selfAttn.wrappedValue = StreamQwen35Attention(args)
        }

        if args.numExperts > 0 {
            _mlp.wrappedValue = StreamQwen35SparseMoeBlock(args)
        } else {
            _mlp.wrappedValue = StreamQwenNextMLP(
                dimensions: args.hiddenSize,
                hiddenDimensions: args.intermediateSize
            )
        }

        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?,
        layerIndex: Int,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> MLXArray {
        let r: MLXArray
        if isLinear {
            r = linearAttn!(inputLayerNorm(x), mask: ssmMask, cache: cache as? MambaCache)
        } else {
            r = selfAttn!.callWithStrategy(
                inputLayerNorm(x),
                mask: attentionMask,
                cache: cache,
                strategy: attentionStrategy,
                diagnosticCounters: diagnosticCounters,
                diagnosticLayer: layerIndex,
                diagnosticGroup: diagnosticGroup)
        }

        let h = x + r
        let output = try await (mlp as! StreamQwen35SparseMoeBlock)(
            postAttentionLayerNorm(h), layer: layerIndex, pool: pool)
        let result = h + output
        // Complete every consumer before releasing per-layer graph dependencies.
        MLX.eval(result)
        return result
    }

    /// Diagnostic-only layer decomposition used by the bounded Q2.5
    /// localization probe. The exact production operations are executed once;
    /// no alternate math path is used.
    func callWithComponents(
        _ x: MLXArray,
        attentionMask: MLXFast.ScaledDotProductAttentionMaskMode,
        ssmMask: MLXArray?,
        cache: KVCache?,
        layerIndex: Int,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> DiagnosticComponents {
        let attentionInput = inputLayerNorm(x)
        let attentionOutput: MLXArray
        let linearProjections: StreamQwen35GatedDeltaNet.DiagnosticProjections?
        let linearAttention: StreamQwen35GatedDeltaNet.DiagnosticAttention?
        let fullAttention: StreamQwen35Attention.DiagnosticAttention?
        if isLinear {
            let diagnostic = linearAttn!.callWithDiagnostics(
                attentionInput, mask: ssmMask, cache: cache as? MambaCache)
            linearProjections = diagnostic.projections
            linearAttention = diagnostic
            fullAttention = nil
            attentionOutput = diagnostic.output
        } else {
            linearProjections = nil
            linearAttention = nil
            let diagnostic = selfAttn!.callWithDiagnostics(
                attentionInput,
                mask: attentionMask,
                cache: cache,
                strategy: attentionStrategy,
                diagnosticCounters: diagnosticCounters,
                diagnosticLayer: layerIndex,
                diagnosticGroup: diagnosticGroup,
                diagnosticSentinel: diagnosticSentinel)
            fullAttention = diagnostic
            attentionOutput = diagnostic.output
        }
        let h = x + attentionOutput
        let postAttentionInput = postAttentionLayerNorm(h)
        let moe = try await (mlp as! StreamQwen35SparseMoeBlock).callWithComponents(
            postAttentionInput, layer: layerIndex, pool: pool)
        let result = h + moe.output
        MLX.eval(
            attentionInput, attentionOutput, h, postAttentionInput,
            moe.routedOutput, moe.sharedOutput, moe.output, result)
        return DiagnosticComponents(
            layerInput: x,
            attentionInput: attentionInput,
            attentionOutput: attentionOutput,
            postAttentionResidual: h,
            postAttentionInput: postAttentionInput,
            mlpOutput: moe.output,
            output: result,
            routerInput: moe.routerInput,
            routerLogits: moe.routerLogits,
            routedOutput: moe.routedOutput,
            sharedOutput: moe.sharedOutput,
            linearProjections: linearProjections,
            linearAttention: linearAttention,
            fullAttention: fullAttention)
    }
}

// MARK: - Text Model

class StreamQwen35TextModelInner: Module {
    struct LayerDiagnosticArrays {
        let layer: Int
        let components: StreamQwen35DecoderLayer.DiagnosticComponents
    }

    struct LayerOutputArrays {
        let layer: Int
        let input: MLXArray
        let output: MLXArray
    }

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [StreamQwen35DecoderLayer]
    let norm: RMSNorm

    let ssmIdx: Int
    let faIdx: Int
    let fullAttentionLayerIndices: [Int]

    init(_ args: StreamQwen35TextConfiguration) {
        precondition(args.vocabularySize > 0)

        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize,
            dimensions: args.hiddenSize
        )

        self.layers = (0 ..< args.hiddenLayers).map { layerIdx in
            StreamQwen35DecoderLayer(args, layerIdx: layerIdx)
        }

        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)

        self.ssmIdx = 0
        self.faIdx = args.fullAttentionInterval - 1
        self.fullAttentionLayerIndices = args.fullAttentionLayerIndices

        super.init()
    }

    func callAsFunction(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil
    ) async throws -> MLXArray {
        var hiddenStates = embedTokens(inputs)

        var cacheArray = cache
        if cacheArray == nil {
            cacheArray = Array(repeating: nil as KVCache?, count: layers.count)
        }

        let faMask = createAttentionMask(h: hiddenStates, cache: cacheArray?[faIdx])
        let ssmMask = createSSMMask(h: hiddenStates, cache: cacheArray?[ssmIdx] as? MambaCache)

        for (i, layer) in layers.enumerated() {
            let mask = layer.isLinear ? ssmMask : nil
            let attnMask =
                layer.isLinear
                ? MLXFast.ScaledDotProductAttentionMaskMode.none : faMask
            try Task.checkCancellation()
            hiddenStates = try await layer(
                hiddenStates,
                attentionMask: attnMask,
                ssmMask: mask,
                cache: cacheArray?[i],
                layerIndex: i,
                pool: pool,
                attentionStrategy: attentionStrategy,
                diagnosticCounters: diagnosticCounters,
                diagnosticGroup: nil)
        }

        return norm(hiddenStates)
    }

    /// Independent-parity diagnostics only. This follows the production loop
    /// exactly while retaining one evaluated hidden-state snapshot per layer;
    /// it is never called by normal chat generation.
    func callWithLayerOutputs(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> (MLXArray, [MLXArray]) {
        let (hidden, _, outputs) = try await callWithLayerInputsOutputs(
            inputs,
            cache: cache,
            pool: pool,
            attentionStrategy: attentionStrategy,
            diagnosticCounters: diagnosticCounters,
            diagnosticGroup: diagnosticGroup)
        return (hidden, outputs)
    }

    /// Diagnostic-only variant that retains the input and output of every
    /// decoder layer. It follows the same production execution loop and is
    /// used to localize the first semantic mismatch against the independent
    /// oracle. Normal inference never calls this method.
    func callWithLayerInputsOutputs(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> (MLXArray, [MLXArray], [MLXArray]) {
        var hiddenStates = embedTokens(inputs)
        var cacheArray = cache
        if cacheArray == nil {
            cacheArray = Array(repeating: nil as KVCache?, count: layers.count)
        }

        let faMask = createAttentionMask(h: hiddenStates, cache: cacheArray?[faIdx])
        let ssmMask = createSSMMask(h: hiddenStates, cache: cacheArray?[ssmIdx] as? MambaCache)
        var inputsByLayer = [MLXArray]()
        inputsByLayer.reserveCapacity(layers.count)
        var outputs = [MLXArray]()
        outputs.reserveCapacity(layers.count)
        for (i, layer) in layers.enumerated() {
            let mask = layer.isLinear ? ssmMask : nil
            let attnMask =
                layer.isLinear
                ? MLXFast.ScaledDotProductAttentionMaskMode.none : faMask
            try Task.checkCancellation()
            let layerInput = hiddenStates
            hiddenStates = try await layer(
                hiddenStates,
                attentionMask: attnMask,
                ssmMask: mask,
                cache: cacheArray?[i],
                layerIndex: i,
                pool: pool,
                attentionStrategy: attentionStrategy,
                diagnosticCounters: diagnosticCounters,
                diagnosticGroup: diagnosticGroup)
            MLX.eval(layerInput, hiddenStates)
            inputsByLayer.append(layerInput)
            outputs.append(hiddenStates)
        }
        return (norm(hiddenStates), inputsByLayer, outputs)
    }

    /// Diagnostic-only decomposition for selected layers. Unselected layers
    /// stay on the exact production call path while the complete model still
    /// runs to preserve the real router/cache transitions.
    func callWithLayerComponents(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil,
        pool: QwenStreamExpertPool,
        diagnosticLayers: Set<Int>,
        forceExplicitFullAttentionMask: Bool = false,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        attentionStrategyLayers: Set<Int> = [],
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil,
        diagnosticGroup: Int? = nil,
        applyStrategyToAllLayers: Bool = false
    ) async throws -> (MLXArray, [LayerDiagnosticArrays]) {
        let (hidden, diagnostics, _) = try await callWithLayerComponentsAndOutputs(
            inputs,
            cache: cache,
            pool: pool,
            diagnosticLayers: diagnosticLayers,
            outputLayers: [],
            forceExplicitFullAttentionMask: forceExplicitFullAttentionMask,
            attentionStrategy: attentionStrategy,
            attentionStrategyLayers: attentionStrategyLayers,
            diagnosticCounters: diagnosticCounters,
            diagnosticSentinel: diagnosticSentinel,
            diagnosticGroup: diagnosticGroup,
            applyStrategyToAllLayers: applyStrategyToAllLayers)
        return (hidden, diagnostics)
    }

    /// Diagnostic-only variant that returns selected layer inputs and outputs
    /// in the same pass as component decomposition. It is used for a single
    /// teacher-forced cached-decode boundary while localizing Q2.9.
    func callWithLayerComponentsAndOutputs(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil,
        pool: QwenStreamExpertPool,
        diagnosticLayers: Set<Int>,
        outputLayers: Set<Int>,
        forceExplicitFullAttentionMask: Bool = false,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        attentionStrategyLayers: Set<Int> = [],
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil,
        diagnosticGroup: Int? = nil,
        applyStrategyToAllLayers: Bool = false
    ) async throws -> (MLXArray, [LayerDiagnosticArrays], [LayerOutputArrays]) {
        var hiddenStates = embedTokens(inputs)
        var cacheArray = cache
        if cacheArray == nil {
            cacheArray = Array(repeating: nil as KVCache?, count: layers.count)
        }

        let faMask: MLXFast.ScaledDotProductAttentionMaskMode
        if forceExplicitFullAttentionMask {
            let offset = cacheArray?[faIdx]?.offset ?? 0
            faMask = .array(createCausalMask(n: hiddenStates.dim(1), offset: offset))
        } else {
            faMask = createAttentionMask(h: hiddenStates, cache: cacheArray?[faIdx])
        }
        let ssmMask = createSSMMask(h: hiddenStates, cache: cacheArray?[ssmIdx] as? MambaCache)
        var diagnostics = [LayerDiagnosticArrays]()
        diagnostics.reserveCapacity(diagnosticLayers.count)
        var capturedOutputs = [LayerOutputArrays]()
        capturedOutputs.reserveCapacity(outputLayers.count)
        for (i, layer) in layers.enumerated() {
            let mask = layer.isLinear ? ssmMask : nil
            let attnMask = layer.isLinear
                ? MLXFast.ScaledDotProductAttentionMaskMode.none : faMask
            try Task.checkCancellation()
            let layerInput = hiddenStates
            if diagnosticLayers.contains(i) {
                let result = try await layer.callWithComponents(
                    hiddenStates,
                    attentionMask: attnMask,
                    ssmMask: mask,
                    cache: cacheArray?[i],
                    layerIndex: i,
                    pool: pool,
                    attentionStrategy: attentionStrategyLayers.contains(i)
                        ? attentionStrategy : .productionDefault,
                    diagnosticCounters: diagnosticCounters,
                    diagnosticSentinel: attentionStrategyLayers.contains(i)
                        ? diagnosticSentinel : nil,
                    diagnosticGroup: diagnosticGroup)
                diagnostics.append(LayerDiagnosticArrays(layer: i, components: result))
                hiddenStates = result.output
            } else if applyStrategyToAllLayers {
                // Q2.18: a strategy comparison is only meaningful when every
                // full-attention layer honours it. Without this the layers that
                // are not being decomposed would silently stay on the fused
                // default, which is exactly the silent fallback this phase
                // forbids.
                hiddenStates = try await layer(
                    hiddenStates,
                    attentionMask: attnMask,
                    ssmMask: mask,
                    cache: cacheArray?[i],
                    layerIndex: i,
                    pool: pool,
                    attentionStrategy: attentionStrategy,
                    diagnosticCounters: diagnosticCounters,
                    diagnosticGroup: diagnosticGroup)
            } else {
                hiddenStates = try await layer(
                    hiddenStates,
                    attentionMask: attnMask,
                    ssmMask: mask,
                    cache: cacheArray?[i],
                    layerIndex: i,
                    pool: pool)
            }
            if outputLayers.contains(i) {
                // Materialize only the explicitly requested boundaries before
                // their graph owners can be released.
                MLX.eval(layerInput, hiddenStates)
                capturedOutputs.append(LayerOutputArrays(
                    layer: i,
                    input: layerInput,
                    output: hiddenStates))
            }
        }
        return (norm(hiddenStates), diagnostics, capturedOutputs)
    }
}

final class StreamQwen35TextModel: Module {
    let vocabularySize: Int
    let kvHeads: [Int]
    let fullAttentionLayerIndices: [Int]

    let model: StreamQwen35TextModelInner
    let configuration: StreamQwen35TextConfiguration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ args: StreamQwen35TextConfiguration) {
        self.configuration = args
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.fullAttentionLayerIndices = args.fullAttentionLayerIndices
        self.model = StreamQwen35TextModelInner(args)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    func callAsFunction(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil
    ) async throws -> MLXArray {
        var out = try await model(
            inputs,
            cache: cache,
            pool: pool,
            attentionStrategy: attentionStrategy,
            diagnosticCounters: diagnosticCounters)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return out
    }

    func callWithLayerOutputs(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> (MLXArray, [MLXArray]) {
        let (logits, _, outputs) = try await callWithLayerInputsOutputs(
            inputs,
            cache: cache,
            pool: pool,
            attentionStrategy: attentionStrategy,
            diagnosticCounters: diagnosticCounters,
            diagnosticGroup: diagnosticGroup)
        return (logits, outputs)
    }

    func callWithLayerInputsOutputs(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        pool: QwenStreamExpertPool,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticGroup: Int? = nil
    ) async throws -> (MLXArray, [MLXArray], [MLXArray]) {
        let (hidden, layerInputs, outputs) = try await model.callWithLayerInputsOutputs(
            inputs,
            cache: cache,
            pool: pool,
            attentionStrategy: attentionStrategy,
            diagnosticCounters: diagnosticCounters,
            diagnosticGroup: diagnosticGroup)
        let logits: MLXArray
        if let lmHead {
            logits = lmHead(hidden)
        } else {
            logits = model.embedTokens.asLinear(hidden)
        }
        return (logits, layerInputs, outputs)
    }

    func callWithLayerComponents(
        _ inputs: MLXArray,
        cache: [KVCache?],
        pool: QwenStreamExpertPool,
        diagnosticLayers: Set<Int>,
        forceExplicitFullAttentionMask: Bool = false,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        attentionStrategyLayers: Set<Int> = [],
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil,
        diagnosticGroup: Int? = nil,
        applyStrategyToAllLayers: Bool = false
    ) async throws -> (MLXArray, [StreamQwen35TextModelInner.LayerDiagnosticArrays]) {
        let (hidden, diagnostics) = try await model.callWithLayerComponents(
            inputs,
            cache: cache,
            pool: pool,
            diagnosticLayers: diagnosticLayers,
            forceExplicitFullAttentionMask: forceExplicitFullAttentionMask,
            attentionStrategy: attentionStrategy,
            attentionStrategyLayers: attentionStrategyLayers,
            diagnosticCounters: diagnosticCounters,
            diagnosticSentinel: diagnosticSentinel,
            diagnosticGroup: diagnosticGroup,
            applyStrategyToAllLayers: applyStrategyToAllLayers)
        let logits: MLXArray
        if let lmHead {
            logits = lmHead(hidden)
        } else {
            logits = model.embedTokens.asLinear(hidden)
        }
        MLX.eval(logits)
        return (logits, diagnostics)
    }

    func callWithLayerComponentsAndOutputs(
        _ inputs: MLXArray,
        cache: [KVCache?],
        pool: QwenStreamExpertPool,
        diagnosticLayers: Set<Int>,
        outputLayers: Set<Int>,
        forceExplicitFullAttentionMask: Bool = false,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        attentionStrategyLayers: Set<Int> = [],
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil,
        diagnosticGroup: Int? = nil,
        applyStrategyToAllLayers: Bool = false
    ) async throws -> (
        MLXArray,
        [StreamQwen35TextModelInner.LayerDiagnosticArrays],
        [StreamQwen35TextModelInner.LayerOutputArrays]
    ) {
        let (hidden, diagnostics, outputs) = try await model.callWithLayerComponentsAndOutputs(
            inputs,
            cache: cache,
            pool: pool,
            diagnosticLayers: diagnosticLayers,
            outputLayers: outputLayers,
            forceExplicitFullAttentionMask: forceExplicitFullAttentionMask,
            attentionStrategy: attentionStrategy,
            attentionStrategyLayers: attentionStrategyLayers,
            diagnosticCounters: diagnosticCounters,
            diagnosticSentinel: diagnosticSentinel,
            diagnosticGroup: diagnosticGroup,
            applyStrategyToAllLayers: applyStrategyToAllLayers)
        let logits: MLXArray
        if let lmHead {
            logits = lmHead(hidden)
        } else {
            logits = model.embedTokens.asLinear(hidden)
        }
        MLX.eval(logits)
        return (logits, diagnostics, outputs)
    }

    /// Diagnostic-only replay of one GatedDelta update with caller-supplied
    /// BF16 projections and FP32 recurrent state. Keeping the model-owned
    /// `aLog`/`dtBias` parameters makes this an exact native kernel invocation
    /// while allowing a reference state to be injected for classification.
    func debugGatedDeltaReplay(
        layer: Int,
        q: MLXArray,
        k: MLXArray,
        v: MLXArray,
        a: MLXArray,
        b: MLXArray,
        state: MLXArray
    ) throws -> (MLXArray, MLXArray) {
        guard model.layers.indices.contains(layer), let linear = model.layers[layer].linearAttn else {
            throw EngineError.loadFailed("GatedDelta replay requires a linear-attention layer.")
        }
        let (output, newState) = gatedDeltaUpdate(
            q: q,
            k: k,
            v: v,
            a: a,
            b: b,
            aLog: linear.aLog,
            dtBias: linear.dtBias,
            state: state,
            mask: nil)
        MLX.eval(output, newState)
        return (output, newState)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        return model.layers.map { layer in
            if layer.isLinear {
                return MambaCache()
            }
            return KVCacheSimple()
        }
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let hasMTPWeights = weights.keys.contains { $0.contains("mtp.") }
        let hasUnsanitizedConv1d = weights.contains { key, value in
            key.contains("conv1d.weight") && value.dim(-1) != 1
        }
        let shouldShiftNormWeights = hasMTPWeights || hasUnsanitizedConv1d

        var weights = weights.filter { !$0.key.contains("mtp.") }

        if configuration.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }

        let normKeys = [
            ".input_layernorm.weight",
            ".post_attention_layernorm.weight",
            "model.norm.weight",
            ".q_norm.weight",
            ".k_norm.weight",
        ]

        for k in Array(weights.keys) {
            guard let v = weights[k] else { continue }
            if k.contains("conv1d.weight") && v.dim(-1) != 1 {
                weights[k] = v.movedAxis(source: 2, destination: 1)
                continue
            }
            if shouldShiftNormWeights
                && normKeys.contains(where: { k.hasSuffix($0) })
                && v.ndim == 1
            {
                weights[k] = v + MLXArray(1, dtype: v.dtype)
            }
        }

        return weights
    }
}


func streamQwenSigmoidMultiply(_ x: MLXArray, _ gate: MLXArray) -> MLXArray {
    x * sigmoid(gate)
}

private func preciseSwiGLU(_ hiddenStates: MLXArray, gate: MLXArray, x: MLXArray) -> MLXArray {
    (silu(gate.asType(.float32)) * x.asType(.float32)).asType(hiddenStates.dtype)
}

// MARK: - Model Components

final class StreamQwenNextRMSNormGated: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ hiddenStates: MLXArray, gate: MLXArray? = nil) -> MLXArray {
        var x = MLXFast.rmsNorm(hiddenStates, weight: weight, eps: eps)
        if let gate {
            x = preciseSwiGLU(hiddenStates, gate: gate, x: x)
        }
        return x
    }
}

final class StreamQwenNextMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gateProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _downProj.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _upProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}
