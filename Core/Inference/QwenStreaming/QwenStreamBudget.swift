import Foundation

/// Mac policy only. The app advisor supplies usable headroom after accounting
/// for its current footprint and macOS reserve; missing/zero headroom refuses.
struct QwenStreamBudget: Sendable, Equatable {
    let poolBytes: UInt64
    let contextTokens: Int
    let reservedBytes: UInt64
    static let contextCeiling = 4096
    // Native BF16 K/V: ten layers * two arrays * two heads * 256 * two bytes.
    static let kvBytesPerToken: UInt64 = 20_480
    // FP32 recurrent matrices plus BF16 three-position convolution buffers.
    static let fixedStateBytes: UInt64 = 64_389_120
    // Includes gathered stacks, eager payload copies, temporary MLX graphs,
    // allocator slack, and application growth above the measured footprint.
    static let transientReserve: UInt64 = 1_073_741_824
    static let safetyReserve: UInt64 = 536_870_912

    var slots: Int { Int(poolBytes / QwenStreamArtifact.expertBundleBytes) }

    static func resolve(availableBytes: UInt64, outputTokens: Int = 512,
                        requestedContext: Int = contextCeiling,
                        poolCeiling: UInt64 = 2 * 1_073_741_824) -> Self? {
        guard outputTokens > 0, requestedContext > outputTokens else { return nil }
        let fixed = QwenStreamArtifact.residentBytes + fixedStateBytes
            + transientReserve + safetyReserve
        guard availableBytes > fixed else { return nil }
        let minimumPool: UInt64 = 512 * 1_048_576
        guard poolCeiling >= minimumPool, availableBytes - fixed > minimumPool else { return nil }
        let tokens = min(contextCeiling, requestedContext,
            Int((availableBytes - fixed - minimumPool) / kvBytesPerToken))
        guard tokens > outputTokens else { return nil }
        for mib: UInt64 in [2048, 1024, 512] {
            let pool = mib * 1_048_576
            guard pool <= poolCeiling, availableBytes - fixed > pool else { continue }
            guard UInt64(tokens) * kvBytesPerToken <= availableBytes - fixed - pool else { continue }
            return Self(poolBytes: pool, contextTokens: tokens,
                        reservedBytes: fixed + pool + UInt64(tokens) * kvBytesPerToken)
        }
        return nil
    }
}
