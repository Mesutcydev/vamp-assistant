import Foundation

/// Opt-in diagnostic trace of the actual routed expert demand. The trace stores
/// only `(layer, expert)` keys grouped by one pool evaluation; it never retains
/// hidden states, tensor bytes, or prompt text. Keeping the group boundary is
/// important because the pool deduplicates a token batch before applying its
/// LRU policy.
final class QwenStreamExpertAccessTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumKeys: Int
    private var groups: [QwenStreamExpertTraceGroup] = []
    private var keyCount = 0
    private var droppedKeys = 0

    init(maximumKeys: Int = 250_000) {
        self.maximumKeys = max(1, maximumKeys)
    }

    func reset() {
        lock.lock()
        groups.removeAll(keepingCapacity: true)
        keyCount = 0
        droppedKeys = 0
        lock.unlock()
    }

    func record(layer: Int, keys: [Int]) {
        guard !keys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = maximumKeys - keyCount
        guard remaining > 0 else {
            droppedKeys += keys.count
            return
        }
        let kept = Array(keys.prefix(remaining))
        groups.append(QwenStreamExpertTraceGroup(layer: layer, experts: kept))
        keyCount += kept.count
        droppedKeys += keys.count - kept.count
    }

    func snapshot() -> QwenStreamExpertTraceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return QwenStreamExpertTraceSnapshot(
            groups: groups,
            keyCount: keyCount,
            droppedKeys: droppedKeys)
    }
}

struct QwenStreamExpertTraceGroup: Codable, Sendable, Equatable {
    let layer: Int
    let experts: [Int]
}

struct QwenStreamExpertTraceSnapshot: Codable, Sendable, Equatable {
    let groups: [QwenStreamExpertTraceGroup]
    let keyCount: Int
    let droppedKeys: Int

    var isComplete: Bool { droppedKeys == 0 }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct QwenStreamExpertCacheSimulation: Codable, Sendable, Equatable {
    let capacitySlots: Int
    let capacityBytes: UInt64
    let hits: Int
    let misses: Int
    let evictions: Int
    let requestedBytes: UInt64
    let supported: Bool

    var hitRate: Double {
        let accesses = hits + misses
        return accesses > 0 ? Double(hits) / Double(accesses) : 0
    }
}

/// Offline, deterministic simulation of the pool's current grouped global LRU.
/// It intentionally lives outside the inference hot path. A miss represents
/// one complete quantized expert bundle and therefore uses the exact artifact
/// bundle size rather than an estimate of the underlying shard range.
enum QwenStreamExpertLRUSimulator {
    static func simulate(
        snapshot: QwenStreamExpertTraceSnapshot,
        capacities: [Int],
        bundleBytes: UInt64 = QwenStreamArtifact.expertBundleBytes
    ) -> [QwenStreamExpertCacheSimulation] {
        capacities
            .map { max(0, $0) }
            .filter { $0 > 0 }
            .sorted()
            .reduce(into: [Int]()) { result, value in
                if result.last != value { result.append(value) }
            }
            .map { simulate(snapshot: snapshot, capacitySlots: $0, bundleBytes: bundleBytes) }
    }

    private static func simulate(
        snapshot: QwenStreamExpertTraceSnapshot,
        capacitySlots: Int,
        bundleBytes: UInt64
    ) -> QwenStreamExpertCacheSimulation {
        struct Key: Hashable {
            let layer: Int
            let expert: Int
        }

        var entries = Set<Key>()
        var lastUse = [Key: UInt64]()
        var sequence: UInt64 = 0
        var hits = 0
        var misses = 0
        var evictions = 0
        var supported = true

        for group in snapshot.groups {
            var ordered = [Key]()
            var seen = Set<Key>()
            for expert in group.experts {
                let key = Key(layer: group.layer, expert: expert)
                if seen.insert(key).inserted { ordered.append(key) }
            }
            guard ordered.count <= capacitySlots else {
                supported = false
                break
            }

            let pinned = Set(ordered)
            let missing = ordered.filter { !entries.contains($0) }
            let requiredEvictions = max(0, entries.count + missing.count - capacitySlots)
            if requiredEvictions > 0 {
                for _ in 0..<requiredEvictions {
                    guard let victim = lastUse
                        .filter({ !pinned.contains($0.key) })
                        .min(by: { $0.value < $1.value })?.key else {
                        supported = false
                        break
                    }
                    entries.remove(victim)
                    lastUse.removeValue(forKey: victim)
                    evictions += 1
                }
            }
            guard supported else { break }

            sequence &+= 1
            for key in ordered {
                if entries.contains(key) {
                    hits += 1
                } else {
                    entries.insert(key)
                    misses += 1
                }
                lastUse[key] = sequence
            }
        }

        return QwenStreamExpertCacheSimulation(
            capacitySlots: capacitySlots,
            capacityBytes: UInt64(capacitySlots) * bundleBytes,
            hits: hits,
            misses: misses,
            evictions: evictions,
            requestedBytes: UInt64(misses) * bundleBytes,
            supported: supported && snapshot.isComplete)
    }
}
