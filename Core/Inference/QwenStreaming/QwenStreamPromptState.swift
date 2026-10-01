import MLX
import MLXLMCommon

/// One in-memory checkpoint at a canonical prefill boundary. Qwen's recurrent
/// layers cannot rewind, and its template removes historical thinking markers.
/// Save before the generation suffix, not after decoding a displayed answer.
/// Keeping the original four-token grouping also preserves BF16 arithmetic.
struct QwenStreamPromptState {
    let tokens: [Int]
    let thinking: Bool
    let attention: StreamQwen35AttentionStrategy
    let groupSize: Int
    let cache: [KVCache]

    static func checkpointLength(prompt: [Int], assistantStartToken: Int?, groupSize: Int) -> Int {
        guard groupSize > 0, let assistantStartToken,
              let suffixStart = prompt.lastIndex(of: assistantStartToken) else { return 0 }
        return suffixStart / groupSize * groupSize
    }

    func matches(prompt: [Int], thinking: Bool,
                 attention: StreamQwen35AttentionStrategy, groupSize: Int) -> Bool {
        groupSize > 0 && !tokens.isEmpty && tokens.count < prompt.count
            && self.thinking == thinking && self.attention == attention
            && self.groupSize == groupSize && tokens.count.isMultiple(of: groupSize)
            && prompt.starts(with: tokens)
    }

    init(tokens: [Int], thinking: Bool, attention: StreamQwen35AttentionStrategy,
         groupSize: Int, cache: [KVCache]) {
        self.tokens = tokens
        self.thinking = thinking
        self.attention = attention
        self.groupSize = groupSize
        // copy() makes independent cache objects with copy-on-write MLX state,
        // including both the convolution and recurrent matrix in MambaCache.
        self.cache = cache.map { $0.copy() }
        MLX.eval(self.cache.map { $0.state })
    }
}

struct QwenStreamOptimizations: Sendable {
    var reusePromptState = true
    // M4/16 GiB counterbalanced trials: 3 GiB saved 21% requested I/O but
    // added only 4.4% decode throughput over reusable 2 GiB slots, at +1 GiB
    // process memory. Keep the lean default; 3 GiB remains an explicit trial.
    var poolCeilingBytes: UInt64 = 2 * 1_073_741_824
    var expertStorage: QwenStreamExpertPool.Storage = .reusableSlots
}
