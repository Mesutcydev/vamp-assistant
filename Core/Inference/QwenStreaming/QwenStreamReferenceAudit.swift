import Foundation
import MLX

/// Small, independent checks for the pinned quantized artifact. This audit
/// intentionally does not use QwenStreamExpertPool or the streaming model:
/// it opens shard ranges directly and compares MLX's quantized kernel against
/// a dense dequantized reference for real expert payloads. It is bounded to
/// one expert projection at a time and never materializes the checkpoint.
struct QwenStreamReferenceAudit: Sendable, Equatable {
    struct Projection: Sendable, Equatable {
        let layer: Int
        let expert: Int
        let projection: String
        let shape: [Int]
        let relL2: Double
        let maxAbs: Double
        let tokenSafe: Bool
    }

    let artifactRevision: String
    let projections: [Projection]

    static func run(
        directory: URL,
        layer: Int = 0,
        expert: Int = 0,
        inputSeed: Int = 17
    ) throws -> QwenStreamReferenceAudit {
        let index = try QwenStreamArtifact.inspect(directory)
        guard (0..<40).contains(layer), (0..<256).contains(expert) else {
            throw EngineError.loadFailed("Reference audit layer/expert is out of range.")
        }

        let prefix = "language_model.model.layers.\(layer).mlp.switch_mlp."
        let projections = try ["gate_proj", "up_proj", "down_proj"].map { name in
            try compare(
                index: index,
                directory: directory,
                prefix: prefix,
                projection: name,
                layer: layer,
                expert: expert,
                inputSeed: inputSeed
            )
        }
        return QwenStreamReferenceAudit(
            artifactRevision: QwenStreamArtifact.revision,
            projections: projections
        )
    }

    /// Apply the native quantized router projection to a saved router input.
    /// This is a bounded gate-only replay: it reads one 256 x 2048 gate and
    /// its quantization companions, never constructs the model or expert pool,
    /// and keeps the input at the checkpoint's BF16 boundary.
    static func routerGateProjection(
        directory: URL,
        layer: Int,
        input: [Float],
        shape: [Int]
    ) throws -> [Float] {
        guard (0..<40).contains(layer), shape.count >= 2,
              shape.last == 2048,
              shape.reduce(1, *) == input.count else {
            throw EngineError.loadFailed("Reference router gate input shape is invalid.")
        }
        let index = try QwenStreamArtifact.inspect(directory)
        let prefix = "language_model.model.layers.\(layer).mlp.gate."
        let weight = try index.location(prefix + "weight")
        let scales = try index.location(prefix + "scales")
        let biases = try index.location(prefix + "biases")
        guard weight.dtype == .u32, scales.dtype == .bf16, biases.dtype == .bf16,
              weight.shape == [256, 256], scales.shape == [256, 32], biases.shape == [256, 32] else {
            throw EngineError.loadFailed("Reference router gate quantization metadata is unsupported.")
        }

        let fileURL = try QwenStreamPaths.file(weight.shard, in: directory)
        let file = try QwenStreamPreadFile(path: fileURL.path)
        defer { file.close() }
        let weightData = try file.read(offset: weight.payloadOffset, count: Int(weight.byteCount))
        let scaleData = try file.read(offset: scales.payloadOffset, count: Int(scales.byteCount))
        let biasData = try file.read(offset: biases.payloadOffset, count: Int(biases.byteCount))

        let q = MLXArray(weightData, weight.shape, dtype: .uint32)
        let s = MLXArray(scaleData, scales.shape, dtype: .bfloat16)
        let b = MLXArray(biasData, biases.shape, dtype: .bfloat16)
        let x = MLXArray(input, shape).asType(.bfloat16)
        let logits = MLX.quantizedMM(
            x, q, scales: s, biases: b, transpose: true,
            groupSize: 64, bits: 4, mode: .affine)
        MLX.eval(logits)
        return logits.asArray(Float.self)
    }

    private static func compare(
        index: QwenStreamSafetensorsIndex,
        directory: URL,
        prefix: String,
        projection: String,
        layer: Int,
        expert: Int,
        inputSeed: Int
    ) throws -> Projection {
        let weight = try index.location(prefix + projection + ".weight").row(expert)
        let scales = try index.location(prefix + projection + ".scales").row(expert)
        let biases = try index.location(prefix + projection + ".biases").row(expert)

        let fileURL = try QwenStreamPaths.file(weight.shard, in: directory)
        let file = try QwenStreamPreadFile(path: fileURL.path)
        defer { file.close() }
        let weightData = try file.read(offset: weight.payloadOffset, count: Int(weight.byteCount))
        let scaleData = try file.read(offset: scales.payloadOffset, count: Int(scales.byteCount))
        let biasData = try file.read(offset: biases.payloadOffset, count: Int(biases.byteCount))

        let q = MLXArray(weightData, weight.shape, dtype: .uint32)
        let s = MLXArray(scaleData, scales.shape, dtype: .bfloat16)
        let b = MLXArray(biasData, biases.shape, dtype: .bfloat16)
        let input = MLXArray((0..<weight.shape[1] * 8).map { i in
            // Stable, nonzero input that exercises every quantization group.
            Float(((i + inputSeed) % 37) - 18) / 19
        }, [1, weight.shape[1] * 8])

        // This is the same native quantized primitive used by the streamed
        // path, but with one complete expert and no pool or cache involved.
        let quantized = MLX.quantizedMM(
            input, q, scales: s, biases: b, transpose: true,
            groupSize: 64, bits: 4, mode: .affine)
        let denseWeight = MLX.dequantized(
            q, scales: s, biases: b, groupSize: 64, bits: 4,
            mode: .affine, dtype: .float32)
        let dense = matmul(input.asType(.float32), denseWeight.transposed())
        MLX.eval(quantized, dense)

        let qValues = quantized.asArray(Float.self)
        let dValues = dense.asArray(Float.self)
        guard qValues.count == dValues.count else {
            throw EngineError.loadFailed("Reference projection shape mismatch for \(projection).")
        }
        var sum = 0.0
        var referenceSum = 0.0
        var maxAbs = 0.0
        for (lhs, rhs) in zip(qValues, dValues) {
            let delta = Double(lhs) - Double(rhs)
            sum += delta * delta
            referenceSum += Double(rhs) * Double(rhs)
            maxAbs = max(maxAbs, abs(delta))
        }
        let relL2 = sqrt(sum) / max(sqrt(referenceSum), 1e-12)
        return Projection(
            layer: layer,
            expert: expert,
            projection: projection,
            shape: quantized.shape,
            relL2: relL2,
            maxAbs: maxAbs,
            tokenSafe: qValues.allSatisfy(\.isFinite) && dValues.allSatisfy(\.isFinite)
        )
    }
}
