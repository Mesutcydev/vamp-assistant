import Foundation
import MLX
import MLXLMCommon

/// Owned exclusively by the shared GenerationGate. No graph escapes evaluate:
/// selected bundles remain pinned until the gathered output is evaluated.
final class QwenStreamExpertPool: @unchecked Sendable {
    enum Storage: String, Sendable { case stacked, reusableSlots }
    struct Key: Hashable { let layer: Int; let expert: Int }
    struct Bundle: @unchecked Sendable {
        let arrays: [String: MLXArray]
        var payloads: [String: Data] = [:]
    }
    struct Counters: Sendable {
        var hits = 0
        var misses = 0
        var evictions = 0
        var requestedBytes: UInt64 = 0
        var peakLeases = 0
        var routedSelections = 0
        var uniqueDemands = 0
        var completedExpertBundles = 0
        var completedPayloadBytes: UInt64 = 0
    }
    struct DebugState: Sendable {
        let busy: Bool
        let activeLeases: Int
        let entries: Int
        let capacitySlots: Int
        let capacityBytes: UInt64
    }
    let capacityBytes: UInt64
    let capacitySlots: Int
    let storage: Storage
    private var bank: QwenStreamExpertBank?
    private var slotByKey: [Key: Int] = [:]
    private var freeSlots: [Int]
    private let accessTrace: QwenStreamExpertAccessTrace?
    private var routerTrace: QwenStreamRouterTrace?
    private(set) var debugPositionOffset: Int = 0
    /// A safe upper bound for actual-router prefill groups. The engine may
    /// use a smaller group, but never asks a small test or pressure-tier pool
    /// to stage more than its K=8 headroom can hold.
    var maximumPrefillTokens: Int { max(1, min(4, capacitySlots / QwenStreamArtifact.routingK)) }
    let index: QwenStreamSafetensorsIndex
    let stores: QwenStreamTensorStoreSet
    private var entries: [Key: Bundle] = [:]
    private var lastUse: [Key: UInt64] = [:]
    private var sequence: UInt64 = 0
    private var busy = false
    private var activeLeases = 0
    private var debugLifecycleObserver: (@Sendable (String) -> Void)?
    private var debugLifecyclePhase = "unknown"
    private(set) var counters = Counters()

    init(index: QwenStreamSafetensorsIndex, stores: QwenStreamTensorStoreSet,
         bytes: UInt64, slots: Int,
         accessTrace: QwenStreamExpertAccessTrace? = nil,
         routerTrace: QwenStreamRouterTrace? = nil,
         storage: Storage = .reusableSlots) throws {
        let effective = min(slots, Int(bytes / QwenStreamArtifact.expertBundleBytes))
        guard effective >= QwenStreamArtifact.routingK else {
            throw EngineError.loadFailed("The expert cache cannot hold one token’s eight routed experts.")
        }
        self.index = index
        self.stores = stores
        self.capacityBytes = bytes
        self.capacitySlots = effective
        self.storage = storage
        self.freeSlots = Array((0..<effective).reversed())
        self.accessTrace = accessTrace
        self.routerTrace = routerTrace
    }

    /// Enables bounded router diagnostics for an explicit validation run. The
    /// normal production path leaves this nil, so no per-token score capture or
    /// sorting is performed during ordinary generation.
    func enableRouterTrace(_ trace: QwenStreamRouterTrace? = QwenStreamRouterTrace()) {
        routerTrace = trace
        routerTrace?.reset()
    }

    func debugRouterTrace() -> QwenStreamRouterTraceSnapshot? {
        routerTrace?.snapshot()
    }

    var routerTraceEnabled: Bool { routerTrace != nil }

    func setDebugPositionOffset(_ position: Int) {
        debugPositionOffset = max(0, position)
    }

    /// Developer-only lifecycle seam. The normal runtime leaves this nil, so
    /// no phase callback is allocated or invoked during production inference.
    func setDebugLifecycleObserver(_ observer: (@Sendable (String) -> Void)?) {
        debugLifecycleObserver = observer
    }

    func setDebugLifecyclePhase(_ phase: String) {
        debugLifecyclePhase = phase
    }

    private func notifyDebugLifecycle(_ event: String) {
        debugLifecycleObserver?(event)
    }

    func recordRouter(
        layer: Int,
        logits: MLXArray,
        expertIDs: MLXArray,
        scores: MLXArray,
        selectorScores: MLXArray,
        routerInput: MLXArray
    ) {
        guard let routerTrace,
              routerTrace.shouldRecord(
                layer: layer,
                position: debugPositionOffset,
                tokenCount: logits.dim(-2)) else { return }
        routerTrace.record(
            layer: layer,
            position: debugPositionOffset,
            logits: logits,
            expertIDs: expertIDs,
            scores: scores,
            selectorScores: selectorScores,
            routerInput: routerInput)
    }

    /// Exact routed evaluation for one token or a bounded prefill group. The
    /// router supplies K=8 IDs for every token; the pool only deduplicates the
    /// resulting bundles for the quantized matrix multiplies. No predicted
    /// routes or reduced-K path enters this seam.
    func evaluate(_ x: MLXArray, layer: Int, expertIDs: [Int]) async throws -> MLXArray {
        let batchTokens = x.dim(1)
        guard !busy, x.dim(0) == 1, (1...4).contains(batchTokens),
              expertIDs.count == batchTokens * 8,
              (0..<40).contains(layer), expertIDs.allSatisfy({ (0..<256).contains($0) }) else {
            throw EngineError.loadFailed("Invalid or overlapping Qwen K=8 expert demand.")
        }
        busy = true
        notifyDebugLifecycle("expert-acquisition-start:\(debugLifecyclePhase)")
        defer {
            activeLeases = 0
            busy = false
            notifyDebugLifecycle("expert-acquisition-end:\(debugLifecyclePhase)")
        }
        var orderedKeys: [Key] = []
        var localByKey: [Key: UInt32] = [:]
        for expert in expertIDs {
            let key = Key(layer: layer, expert: expert)
            if localByKey[key] == nil {
                localByKey[key] = UInt32(orderedKeys.count)
                orderedKeys.append(key)
            }
        }
        guard orderedKeys.count <= capacitySlots else {
            throw EngineError.loadFailed("Expert demand exceeds cache capacity.")
        }
        accessTrace?.record(layer: layer, keys: orderedKeys.map(\.expert))

        let pinned = Set(orderedKeys)
        activeLeases = pinned.count
        counters.routedSelections += expertIDs.count
        counters.uniqueDemands += orderedKeys.count
        counters.peakLeases = max(counters.peakLeases, pinned.count)
        let missing = orderedKeys.filter { entries[$0] == nil }
        let requiredEvictions = max(0, entries.count + missing.count - capacitySlots)
        if requiredEvictions > 0 {
            for _ in 0..<requiredEvictions {
                // Avoid allocating a filtered dictionary on every eviction.
                let victim = lastUse.lazy.filter { !pinned.contains($0.key) }
                    .min { a, b in
                        if a.value != b.value { return a.value < b.value }
                        if a.key.layer != b.key.layer { return a.key.layer < b.key.layer }
                        return a.key.expert < b.key.expert
                    }?.key
                guard let victim else {
                    throw EngineError.loadFailed("Expert demand exceeds cache capacity.")
                }
                entries[victim] = nil
                lastUse[victim] = nil
                if let slot = slotByKey.removeValue(forKey: victim) { freeSlots.append(slot) }
                counters.evictions += 1
            }
        }

        // The tensor store still caps physical reads at four. Launching the
        // missing bundles together removes per-bundle scheduling gaps while
        // the store preserves the global I/O bound and cancellation behavior.
        notifyDebugLifecycle("expert-reads-start:\(debugLifecyclePhase)")
        let loaded: [Key: Bundle] = try await withThrowingTaskGroup(of: (Key, Bundle).self) { group in
            for key in missing {
                group.addTask { [self] in (key, try await self.load(key)) }
            }
            var result: [Key: Bundle] = [:]
            for try await (key, bundle) in group { result[key] = bundle }
            return result
        }
        notifyDebugLifecycle("expert-reads-complete:\(debugLifecyclePhase)")
        try Task.checkCancellation()
        if storage == .reusableSlots && bank == nil {
            let prefix = "language_model.model.layers.\(layer).mlp.switch_mlp."
            let locations = try Dictionary(uniqueKeysWithValues: Self.parts.map {
                ($0, try index.location(prefix + $0).row(0))
            })
            bank = try QwenStreamExpertBank(slots: capacitySlots, locations: locations)
        }
        sequence &+= 1
        for key in orderedKeys {
            if entries[key] != nil {
                counters.hits += 1
                lastUse[key] = sequence
            } else if let bundle = loaded[key] {
                if storage == .reusableSlots {
                    guard let slot = freeSlots.popLast(), let bank else {
                        throw EngineError.loadFailed("Qwen expert slots are exhausted.")
                    }
                    do { try bank.commit(bundle.payloads, to: slot) }
                    catch { freeSlots.append(slot); throw error }
                    slotByKey[key] = slot
                    // Only membership is retained: slot bytes replace the
                    // per-expert MLX arrays and transient read buffers.
                    entries[key] = Bundle(arrays: [:])
                } else {
                    entries[key] = bundle
                }
                lastUse[key] = sequence
                counters.misses += 1
                counters.completedExpertBundles += 1
                counters.completedPayloadBytes += QwenStreamArtifact.expertBundleBytes
            } else {
                throw EngineError.loadFailed("Expert bundle disappeared during installation.")
            }
        }
        counters.requestedBytes += UInt64(missing.count) * QwenStreamArtifact.expertBundleBytes
        let localIndices = MLXArray(expertIDs.map { expert in
            let key = Key(layer: layer, expert: expert)
            return storage == .reusableSlots ? UInt32(slotByKey[key]!) : localByKey[key]!
        })
            .reshaped(1, batchTokens, 8)
        let selected = try orderedKeys.map { key in
            guard let bundle = entries[key] else {
                throw EngineError.loadFailed("Expert bundle is unavailable after installation.")
            }
            return bundle
        }
        func projection(_ name: String, _ input: MLXArray) -> MLXArray {
            func component(_ suffix: String) -> MLXArray {
                let part = name + "." + suffix
                if let bank { return bank.components[part]!.array }
                return stacked(selected.map { $0.arrays[part]! })
            }
            return MLX.gatherQuantizedMM(
                input, component("weight"),
                scales: component("scales"),
                biases: component("biases"),
                rhsIndices: localIndices, transpose: true, groupSize: 64, bits: 4,
                mode: .affine, sortedIndices: false)
        }
        let input = expandedDimensions(x, axes: [-2, -3])
        let up = projection("up_proj", input)
        let gate = projection("gate_proj", input)
        let activated = compiledSiluProduct(gate, up)
        let result = squeezed(projection("down_proj", activated), axis: -2)
        MLX.eval(result)
        return result
    }

    private func load(_ key: Key) async throws -> Bundle {
        let prefix = "language_model.model.layers.\(key.layer).mlp.switch_mlp."
        let parts = Self.parts
        let locations = try parts.map { try index.location(prefix + $0).row(key.expert) }
        let byteCount = locations.reduce(UInt64(0)) { $0 + $1.byteCount }
        guard byteCount == QwenStreamArtifact.expertBundleBytes else {
            throw EngineError.loadFailed("Unsupported expert bundle geometry.")
        }
        let payloads = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (i, location) in locations.enumerated() {
                group.addTask { [stores] in (i, try await stores.read(location).bytes) }
            }
            var values = [Int: Data]()
            for try await (i, bytes) in group { values[i] = bytes }
            return values
        }
        var arrays = [String: MLXArray]()
        if storage == .reusableSlots {
            return Bundle(arrays: [:], payloads: Dictionary(uniqueKeysWithValues:
                parts.enumerated().map { ($0.element, payloads[$0.offset]!) }))
        }
        for (i, part) in parts.enumerated() {
            arrays[part] = try QwenStreamArrays.make(payloads[i]!, location: locations[i])
        }
        MLX.eval(Array(arrays.values))
        return Bundle(arrays: arrays)
    }

    func trim() {
        precondition(!busy)
        entries.removeAll()
        lastUse.removeAll()
        slotByKey.removeAll()
        freeSlots = Array((0..<capacitySlots).reversed())
        bank = nil
    }

    private static let parts = ["gate_proj", "up_proj", "down_proj"].flatMap { projection in
        ["weight", "scales", "biases"].map { projection + "." + $0 }
    }

    func debugState() -> DebugState {
        DebugState(
            busy: busy,
            activeLeases: activeLeases,
            entries: entries.count,
            capacitySlots: capacitySlots,
            capacityBytes: capacityBytes)
    }
}

enum QwenStreamArrays {
    static func make(_ data: Data, location: QwenStreamTensorLocation) throws -> MLXArray {
        MLXArray(data, location.shape, dtype: try dtype(location))
    }

    static func dtype(_ location: QwenStreamTensorLocation) throws -> DType {
        switch location.dtype {
        case .u32: return .uint32
        case .bf16: return .bfloat16
        case .f16: return .float16
        case .f32: return .float32
        default: throw EngineError.loadFailed("Unsupported Qwen tensor dtype.")
        }
    }
}
