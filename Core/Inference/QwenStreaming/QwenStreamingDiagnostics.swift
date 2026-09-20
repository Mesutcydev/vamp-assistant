import CryptoKit
import Foundation

public struct QwenStreamingDiagnostics: Sendable, Equatable {
    static func hashTokenIDs(_ tokenIDs: [Int]) -> String {
        let bytes = Data(tokenIDs.map(String.init).joined(separator: ",").utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var state = "ready"
    var poolBytes: UInt64 = 0
    var poolSlots = 0
    var contextTokens = 0
    var promptTokens = 0
    /// SHA-256 of the rendered token IDs, truncated to a safe diagnostic
    /// identifier. The prompt text itself is never persisted or logged.
    var inputHash: String?
    var generatedTokens = 0
    var stopReason = "unavailable"
    var decodeCalls = 0
    var loadSeconds: Double?
    var promptRenderSeconds: Double?
    var prefillSeconds: Double?
    var firstTokenSeconds: Double?
    var firstTokenGapSeconds: Double?
    var firstAnswerSeconds: Double?
    var lastTokenSeconds: Double?
    var finalizationSeconds: Double?
    var totalSeconds: Double?
    var unclassifiedSeconds: Double?
    var tokenDecodeSeconds: Double?
    var decodeSeconds: Double?
    var decodeTokensPerSecond: Double?
    var endToEndTokensPerSecond: Double?
    var cancellationSeconds: Double?
    var requestedFileBytes: UInt64 = 0
    var completedFileBytes: UInt64 = 0
    var prefillRequestedBytes: UInt64 = 0
    var prefillCompletedBytes: UInt64 = 0
    var decodeRequestedBytes: UInt64 = 0
    var decodeCompletedBytes: UInt64 = 0
    var prefillReadCalls = 0
    var decodeReadCalls = 0
    var ssdReadSeconds: Double?
    var prefillReadSeconds: Double?
    var decodeReadSeconds: Double?
    var expertHits = 0
    var expertMisses = 0
    var expertEvictions = 0
    var peakLeases = 0
    var peakReads = 0
    var configuredReadLimit = 0
    var routedSelections = 0
    var uniqueExpertDemands = 0
    var completedExpertBundles = 0
    var completedPayloadBytes: UInt64 = 0
    var expectedPayloadBytes: UInt64 = 0
    var processBeforeLoadBytes: UInt64?
    var processAfterLoadBytes: UInt64?
    /// Maximum process footprint observed by the bounded phase sampler. It is
    /// explicitly a sampled peak, not a kernel-guaranteed high-water mark.
    var processPeakBytes: UInt64?
    var footprintBytes: UInt64?
    var mlxActiveBytes: Int?
    var mlxCacheBytes: Int?
    var mlxPeakBytes: Int?
    var accessTraceGroups = 0
    var accessTraceKeys = 0
    var accessTraceDroppedKeys = 0

    /// Q2.18 attention-strategy reporting. Every generation publishes the
    /// strategy that was requested and the concrete strategies that actually
    /// executed, so a hybrid run can never be mistaken for a pure one and a
    /// silent fallback is visible in the diagnostics rather than hidden.
    var attentionRequestedStrategy: String?
    var attentionEffectiveStrategies: [String] = []
    var attentionFusedCalls = 0
    var attentionExplicitCalls = 0
    var attentionFusedPrefillCalls = 0
    var attentionExplicitPrefillCalls = 0
    var attentionFusedDecodeCalls = 0
    var attentionExplicitDecodeCalls = 0

    var offlineCacheSimulation: [QwenStreamExpertCacheSimulation] = []
    var accessTracePath: String?

    var summary: String {
        let timing = prefillSeconds.map { String(format: "Prefill %.2f s", $0) } ?? "Prefill unavailable"
        let ttft = firstTokenSeconds.map { String(format: "TTFT %.2f s", $0) } ?? "TTFT unavailable"
        let decode = decodeTokensPerSecond.flatMap { rate in
            decodeSeconds.map { seconds in
                String(format: "Decode %.2f tok/s over %.2f s", rate, seconds)
            }
        } ?? "Decode unavailable"
        let endToEnd = endToEndTokensPerSecond.map {
            String(format: "End-to-end %.2f tok/s", $0)
        } ?? "End-to-end unavailable"
        let load = loadSeconds.map { String(format: "Load %.2f s", $0) } ?? "Load unavailable"
        let prompt = promptRenderSeconds.map { String(format: "Template/tokenize %.3f s", $0) } ?? "Template/tokenize unavailable"
        let read = ssdReadSeconds.map { String(format: "range reads %.2f s", $0) } ?? "range reads unavailable"
        let memory = footprintBytes.map { ByteFormatter.bytes($0) } ?? "unavailable"
        let sampledPeak = processPeakBytes.map { ByteFormatter.bytes($0) } ?? "unavailable"
        let total = totalSeconds.map { String(format: "%.2f s", $0) } ?? "unavailable"
        let loadMemory: String
        if let before = processBeforeLoadBytes, let after = processAfterLoadBytes {
            loadMemory = "load process \(ByteFormatter.bytes(before)) → \(ByteFormatter.bytes(after))"
        } else {
            loadMemory = "load process unavailable"
        }
        let mlx: String
        if let active = mlxActiveBytes, let cache = mlxCacheBytes, let peak = mlxPeakBytes {
            mlx = "MLX \(ByteFormatter.bytes(Int64(active)))/\(ByteFormatter.bytes(Int64(cache)))/\(ByteFormatter.bytes(Int64(peak)))"
        } else {
            mlx = "MLX unavailable"
        }
        let simulationText = offlineCacheSimulation.map { simulation in
            String(format: "%d slots: %.1f%% hit", simulation.capacitySlots, simulation.hitRate * 100)
        }.joined(separator: ", ")
        let attentionText: String
        if let requested = attentionRequestedStrategy {
            let effective = attentionEffectiveStrategies.isEmpty ? "none" : attentionEffectiveStrategies.joined(separator: "+")
            attentionText = "Attention requested \(requested) · effective \(effective) · "
                + "fused \(attentionFusedCalls) (prefill \(attentionFusedPrefillCalls) / decode \(attentionFusedDecodeCalls)) · "
                + "explicit \(attentionExplicitCalls) (prefill \(attentionExplicitPrefillCalls) / decode \(attentionExplicitDecodeCalls))\n"
        } else {
            attentionText = ""
        }
        return "Qwen3.5-35B-A3B · 4-bit · K=8 · native SSD streaming\n"
            + "\(promptTokens) prompt / \(generatedTokens) output · stop \(stopReason) · \(decodeCalls) decode calls\n"
            + "\(load) · \(prompt) · \(timing) · \(ttft)\n"
            + "\(decode) · \(endToEnd) · total \(total)\n"
            + attentionText
            + "Expert cache \(ByteFormatter.bytes(poolBytes)) / \(poolSlots) slots · reads ≤\(configuredReadLimit) (observed \(peakReads))\n"
            + "hits \(expertHits), misses \(expertMisses), evictions \(expertEvictions), bundles \(completedExpertBundles)\n"
            + "Requested \(ByteFormatter.bytes(requestedFileBytes)) / completed \(ByteFormatter.bytes(completedFileBytes)) · prefill \(ByteFormatter.bytes(prefillRequestedBytes)) · decode \(ByteFormatter.bytes(decodeRequestedBytes))\n"
            + "Expert payload expected \(ByteFormatter.bytes(expectedPayloadBytes)) / completed \(ByteFormatter.bytes(completedPayloadBytes)) · \(read); physical SSD traffic and swap delta unavailable.\n"
            + "\(loadMemory) · sampled process peak \(sampledPeak) · end process \(memory) · \(mlx)\n"
            + (accessTraceGroups > 0
                ? "Trace \(accessTraceKeys) keys / \(accessTraceGroups) groups · offline LRU \(simulationText)\n"
                : "")
            + "Explicit attention validated against the pinned MLX 0.31.1 Metal K=8 reference (64/64 IDs, zero true router membership failures). Not official Qwen certification or BF16 equivalence. No K reduction, adapters, vision, MTP, or prefix reuse."
    }
}

/// Bounded, low-frequency process-footprint observation for one generation.
/// It deliberately samples outside the token hot path and reports its result
/// as a sampled peak rather than claiming a kernel-level high-water mark.
final class QwenProcessFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakBytes: UInt64 = 0

    func sample() {
        let current = MemoryAdvisor.processFootprint
        guard current > 0 else { return }
        lock.lock()
        peakBytes = max(peakBytes, current)
        lock.unlock()
    }

    func snapshot() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return peakBytes > 0 ? peakBytes : nil
    }

    func start() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

extension Duration {
    var qwenSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
