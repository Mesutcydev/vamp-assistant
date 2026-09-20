import Foundation
import MLX
import MLXNN
import Metal
import MLXLMCommon

/// Native, single-token streamed Qwen. GPU/model state belongs to GenerationGate;
/// the lock protects only presentation snapshots and cancellation ownership.
final class QwenStreamingEngine: LLMEngine, @unchecked Sendable {
    private let gate: GenerationGate
    private let lock = NSLock()
    private var loadedID: String?
    private var currentStats = EngineStats()
    private var contextWindow = 0
    private var owner: UUID?
    private var task: Task<Void, Never>?
    private var model: StreamQwen35TextModel?
    private var tokenizer: (any MLXLMCommon.Tokenizer)?
    private var pool: QwenStreamExpertPool?
    private var accessTrace: QwenStreamExpertAccessTrace?
    private var stores: QwenStreamTensorStoreSet?
    private var history: [ChatTurn] = []
    private var scopedDirectory: URL?
    private var debugLifecycleObserver: (@Sendable (String) -> Void)?
    /// Attention strategy for the production streaming path. Defaults to
    /// ``StreamQwen35AttentionStrategy/productionDefault``, the Q2.18 outcome-C
    /// decision; developer validation may select another and every generation
    /// reports what was requested versus what actually executed.
    private var attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault
    /// Installed only by opt-in validation. Ordinary generation leaves this
    /// nil so the hot path performs no counter work.
    private var debugAttentionCounters: StreamQwen35AttentionDiagnosticCounters?

    init(gate: GenerationGate) { self.gate = gate }
    var loadedModelID: String? { get async { lock.withLock { loadedID } } }
    var stats: EngineStats { get async { lock.withLock { currentStats } } }
    var effectiveContextWindow: Int? { get async { lock.withLock { contextWindow > 0 ? contextWindow : nil } } }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: nil)
    }

    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        guard modelID == QwenStreamArtifact.modelID else {
            throw EngineError.loadFailed("This backend accepts only the pinned Qwen3.5 K=8 conversion.")
        }
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
            throw EngineError.loadFailed("Qwen streaming requires Apple Silicon with Metal unified memory.")
        }
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes, format: .qwenStreaming)
        let usable = min(UInt64(Double(MemoryAdvisor.availableBudget) * 0.95),
                         device.recommendedMaxWorkingSetSize)
        guard let budget = QwenStreamBudget.resolve(
            availableBytes: usable,
            requestedContext: min(contextSize ?? 4096, 4096)) else {
            throw EngineError.loadFailed("Not enough memory for Qwen text state and eight experts.")
        }
        let scoped = directory.startAccessingSecurityScopedResource()
        do {
        try await gate.run {
            guard self.model == nil else { throw EngineError.alreadyLoading }
            let loadStarted = ContinuousClock.now
            let processBeforeLoad = MemoryAdvisor.processFootprint
            let index = try QwenStreamArtifact.inspect(directory)
            let stores = try QwenStreamTensorStoreSet(directory: directory,
                shardNames: index.shardNames, maxConcurrentReads: 4)
            do {
                let configURL = try QwenStreamPaths.file("config.json", in: directory)
                guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
                      let textObject = root["text_config"] as? [String: Any] else {
                    throw EngineError.loadFailed("The pinned Qwen config has no valid text_config object.")
                }
                let textData = try JSONSerialization.data(withJSONObject: textObject)
                let config = try JSONDecoder().decode(StreamQwen35TextConfiguration.self, from: textData)
                guard config.numExperts == 256,
                      config.numExpertsPerTok == QwenStreamArtifact.routingK,
                      config.hiddenLayers == 40,
                      config.hiddenSize == 2048,
                      config.vocabularySize == 248_320,
                      config.fullAttentionInterval == 4,
                      config.linearNumKeyHeads == 16,
                      config.linearNumValueHeads == 32,
                      config.linearKeyHeadDim == 128,
                      config.linearValueHeadDim == 128,
                      config.linearConvKernelDim == 4 else {
                    throw EngineError.loadFailed("Unsupported Qwen routing configuration.")
                }
                if let layerTypes = textObject["layer_types"] as? [String] {
                    let configuredFullLayers = layerTypes.enumerated().compactMap { index, type in
                        type == "full_attention" ? index : nil
                    }
                    guard layerTypes.count == config.hiddenLayers,
                          layerTypes.filter({ $0 == "full_attention" }).count == 10,
                          layerTypes.filter({ $0 == "linear_attention" }).count == 30,
                          configuredFullLayers == config.fullAttentionLayerIndices else {
                        throw EngineError.loadFailed("Unsupported Qwen attention layer layout.")
                    }
                }
                let model = StreamQwen35TextModel(config)
                var weights = [String: MLXArray]()
                for (name, location) in index.locations.sorted(by: { $0.key < $1.key })
                where name.hasPrefix("language_model.") && !name.contains(".switch_mlp.") && !name.contains(".mtp.") {
                    try Task.checkCancellation()
                    let payload = try await stores.read(location)
                    weights[String(name.dropFirst("language_model.".count))] =
                        try QwenStreamArrays.make(payload.bytes, location: location)
                }
                // The pinned header determines quantization membership, including
                // small gates that a dimension-only heuristic would get wrong.
                quantize(model: model, groupSize: 64, bits: 4,
                         filter: { path, _ in weights[path + ".scales"] != nil })
                weights = model.sanitize(weights: weights)
                try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
                MLX.eval(model.parameters())
                let tokenizer = try await HFTokenizerLoader().load(from: directory)
                let accessTrace = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_TRACE"] == "1"
                    ? QwenStreamExpertAccessTrace() : nil
                let pool = try QwenStreamExpertPool(index: index, stores: stores,
                    bytes: budget.poolBytes, slots: budget.slots, accessTrace: accessTrace)
                self.scopedDirectory = scoped ? directory : nil
                self.model = model
                self.tokenizer = tokenizer
                self.stores = stores
                self.pool = pool
                self.accessTrace = accessTrace
                self.history = []
                MLX.Memory.cacheLimit = 128 * 1024 * 1024
                self.lock.withLock {
                    self.loadedID = modelID
                    self.contextWindow = budget.contextTokens
                    self.currentStats = EngineStats()
                    self.currentStats.qwenStreaming = QwenStreamingDiagnostics(
                        poolBytes: budget.poolBytes, poolSlots: budget.slots,
                        contextTokens: budget.contextTokens,
                        loadSeconds: loadStarted.duration(to: .now).qwenSeconds,
                        processBeforeLoadBytes: processBeforeLoad > 0 ? processBeforeLoad : nil,
                        processAfterLoadBytes: MemoryAdvisor.processFootprint > 0
                            ? MemoryAdvisor.processFootprint : nil)
                }
            } catch {
                await stores.closeAll()
                MLX.Memory.clearCache()
                throw error
            }
        }
        } catch {
            if scoped { directory.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func stream(adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        makeStream(turns, replay: false, maxTokens: maxTokens, temperature: temperature)
    }
    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        makeStream(turns, replay: true, maxTokens: maxTokens, temperature: temperature)
    }

    /// Installs a developer-only phase observer for lifecycle validation.
    /// Production generation leaves this unset, so it adds no hot-path work.
    func debugSetLifecycleObserver(_ observer: (@Sendable (String) -> Void)?) async {
        _ = try? await gate.run {
            self.lock.withLock { self.debugLifecycleObserver = observer }
            self.pool?.setDebugLifecycleObserver(observer)
        }
    }

    private func notifyDebugLifecycle(_ event: String) {
        let observer = lock.withLock { debugLifecycleObserver }
        observer?(event)
    }

    /// Developer-only selection of the attention strategy used by the real
    /// production streaming loop. It is not a user-facing setting and it never
    /// changes silently mid-generation: the value is captured once per
    /// generation and reported through ``QwenStreamingDiagnostics``.
    func debugSetAttentionStrategy(
        _ strategy: StreamQwen35AttentionStrategy,
        counters: StreamQwen35AttentionDiagnosticCounters? = nil
    ) async {
        _ = try? await gate.run {
            self.lock.withLock {
                self.attentionStrategy = strategy
                self.debugAttentionCounters = counters
            }
        }
    }

    /// The strategy the production loop will use for its next generation.
    func debugAttentionStrategy() async -> StreamQwen35AttentionStrategy {
        lock.withLock { attentionStrategy }
    }

    private func makeStream(_ turns: [ChatTurn], replay: Bool, maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let accepted = lock.withLock { () -> Bool in
                guard owner == nil else { return false }
                owner = id
                return true
            }
            guard accepted else {
                continuation.finish(throwing: EngineError.loadFailed("A generation is already active."))
                return
            }
            let worker = Task {
                defer { self.finishOwnership(id) }
                do {
                    try await self.gate.run {
                        try self.checkOwnership(id)
                        guard let model = self.model, let tokenizer = self.tokenizer, let pool = self.pool else {
                            throw EngineError.notLoaded
                        }
                        let started = ContinuousClock.now
                        var diagnostics = self.lock.withLock { self.currentStats.qwenStreaming ?? QwenStreamingDiagnostics() }
                        diagnostics.state = "interrupted"
                        // Captured once per generation so the reported strategy
                        // cannot change underneath a running request.
                        let (generationAttentionStrategy, generationAttentionCounters) = self.lock.withLock {
                            (self.attentionStrategy, self.debugAttentionCounters)
                        }
                        generationAttentionCounters?.reset()
                        diagnostics.attentionRequestedStrategy = generationAttentionStrategy.reportLabel
                        diagnostics.attentionEffectiveStrategies = []
                        diagnostics.attentionFusedCalls = 0
                        diagnostics.attentionExplicitCalls = 0
                        diagnostics.attentionFusedPrefillCalls = 0
                        diagnostics.attentionExplicitPrefillCalls = 0
                        diagnostics.attentionFusedDecodeCalls = 0
                        diagnostics.attentionExplicitDecodeCalls = 0
                        var generatedCount = 0
                        var decodeCallCount = 0
                        var firstToken: ContinuousClock.Instant?
                        var lastToken: ContinuousClock.Instant?
                        var prefillCompleted: ContinuousClock.Instant?
                        var tokenDecodeSeconds = 0.0
                        let before = pool.counters
                        self.accessTrace?.reset()
                        let beforeReadStats = self.stores?.readStatistics()
                        let beforeReads = beforeReadStats?.totalRequestedBytes ?? 0
                        let beforeCompletedReads = beforeReadStats?.totalCompletedBytes ?? 0
                        let beforeReadSeconds = beforeReadStats?.totalReadSeconds ?? 0
                        let footprintSampler = QwenProcessFootprintSampler()
                        footprintSampler.sample()
                        let footprintTask = footprintSampler.start()
                        defer {
                            footprintTask.cancel()
                            footprintSampler.sample()
                            let after = pool.counters
                            diagnostics.totalSeconds = started.duration(to: .now).qwenSeconds
                            diagnostics.generatedTokens = generatedCount
                            diagnostics.decodeCalls = decodeCallCount
                            diagnostics.stopReason = diagnostics.state
                            if let firstToken, let lastToken, generatedCount > 1 {
                                let decodeSeconds = firstToken.duration(to: lastToken).qwenSeconds
                                if decodeSeconds > 0 {
                                    diagnostics.decodeSeconds = decodeSeconds
                                    diagnostics.decodeTokensPerSecond =
                                        Double(generatedCount - 1) / decodeSeconds
                                }
                            }
                            diagnostics.lastTokenSeconds = lastToken.map { started.duration(to: $0).qwenSeconds }
                            if let prefillCompleted, let firstToken {
                                let gap = prefillCompleted.duration(to: firstToken).qwenSeconds
                                diagnostics.firstTokenGapSeconds = max(0, gap)
                            }
                            if let totalSeconds = diagnostics.totalSeconds, totalSeconds > 0,
                               generatedCount > 0 {
                                diagnostics.endToEndTokensPerSecond =
                                    Double(generatedCount) / totalSeconds
                            }
                            let readStats = self.stores?.readStatistics()
                            diagnostics.requestedFileBytes = (readStats?.totalRequestedBytes ?? beforeReads) - beforeReads
                            diagnostics.completedFileBytes = (readStats?.totalCompletedBytes ?? beforeCompletedReads) - beforeCompletedReads
                            let readSeconds = (readStats?.totalReadSeconds ?? beforeReadSeconds) - beforeReadSeconds
                            diagnostics.ssdReadSeconds = readSeconds >= 0 ? readSeconds : nil
                            if let readStats {
                                let prefill = readStats.stats(for: .prefill)
                                let decode = readStats.stats(for: .decode)
                                let beforePrefill = beforeReadStats?.stats(for: .prefill) ?? QwenStreamPhaseReadStats()
                                let beforeDecode = beforeReadStats?.stats(for: .decode) ?? QwenStreamPhaseReadStats()
                                diagnostics.prefillRequestedBytes = prefill.requestedBytes - beforePrefill.requestedBytes
                                diagnostics.prefillCompletedBytes = prefill.completedBytes - beforePrefill.completedBytes
                                diagnostics.prefillReadSeconds = max(0, prefill.totalReadSeconds - beforePrefill.totalReadSeconds)
                                diagnostics.prefillReadCalls = prefill.totalReads - beforePrefill.totalReads
                                diagnostics.decodeRequestedBytes = decode.requestedBytes - beforeDecode.requestedBytes
                                diagnostics.decodeCompletedBytes = decode.completedBytes - beforeDecode.completedBytes
                                diagnostics.decodeReadSeconds = max(0, decode.totalReadSeconds - beforeDecode.totalReadSeconds)
                                diagnostics.decodeReadCalls = decode.totalReads - beforeDecode.totalReads
                                diagnostics.configuredReadLimit = readStats.configuredMaxConcurrentReads
                            }
                            diagnostics.expertHits = after.hits - before.hits
                            diagnostics.expertMisses = after.misses - before.misses
                            diagnostics.expertEvictions = after.evictions - before.evictions
                            diagnostics.peakLeases = after.peakLeases
                            diagnostics.peakReads = self.stores?.readStatistics().peakConcurrentReads ?? 0
                            diagnostics.routedSelections = after.routedSelections - before.routedSelections
                            diagnostics.uniqueExpertDemands = after.uniqueDemands - before.uniqueDemands
                            diagnostics.completedExpertBundles = after.completedExpertBundles - before.completedExpertBundles
                            diagnostics.completedPayloadBytes = after.completedPayloadBytes - before.completedPayloadBytes
                            diagnostics.expectedPayloadBytes = UInt64(max(0, diagnostics.expertMisses)) * QwenStreamArtifact.expertBundleBytes
                            diagnostics.tokenDecodeSeconds = tokenDecodeSeconds > 0 ? tokenDecodeSeconds : nil
                            diagnostics.processPeakBytes = footprintSampler.snapshot()
                            let footprint = MemoryAdvisor.processFootprint
                            diagnostics.footprintBytes = footprint > 0 ? footprint : nil
                            diagnostics.mlxActiveBytes = MLX.Memory.activeMemory
                            diagnostics.mlxCacheBytes = MLX.Memory.cacheMemory
                            diagnostics.mlxPeakBytes = MLX.Memory.peakMemory
                            if let accessTrace = self.accessTrace {
                                let snapshot = accessTrace.snapshot()
                                diagnostics.accessTraceGroups = snapshot.groups.count
                                diagnostics.accessTraceKeys = snapshot.keyCount
                                diagnostics.accessTraceDroppedKeys = snapshot.droppedKeys
                                let base = max(1, pool.capacitySlots)
                                let capacities = [
                                    base,
                                    Int(Double(base) * 1.25),
                                    Int(Double(base) * 1.50),
                                    Int(Double(base) * 1.75),
                                ]
                                diagnostics.offlineCacheSimulation =
                                    QwenStreamExpertLRUSimulator.simulate(
                                        snapshot: snapshot, capacities: capacities)
                                if let hash = diagnostics.inputHash {
                                    let traceURL: URL
                                    if let configured = ProcessInfo.processInfo.environment["BEETCODE_QWEN35_TRACE_PATH"],
                                       !configured.isEmpty {
                                        traceURL = URL(fileURLWithPath: configured)
                                    } else {
                                        traceURL = URL(fileURLWithPath: NSTemporaryDirectory())
                                            .appendingPathComponent("qwen35-k8-expert-trace-\(hash).json")
                                    }
                                    if (try? snapshot.write(to: traceURL)) != nil {
                                        diagnostics.accessTracePath = traceURL.path
                                    }
                                }
                            }
                            let total = diagnostics.totalSeconds ?? 0
                            let known = (diagnostics.promptRenderSeconds ?? 0)
                                + (diagnostics.prefillSeconds ?? 0)
                                + (diagnostics.firstTokenGapSeconds ?? 0)
                                + (diagnostics.decodeSeconds ?? 0)
                                + (diagnostics.finalizationSeconds ?? 0)
                            diagnostics.unclassifiedSeconds = max(0, total - known)
                            if let counters = generationAttentionCounters {
                                diagnostics.attentionEffectiveStrategies =
                                    counters.effectiveStrategies.map(\.reportLabel).sorted()
                                diagnostics.attentionFusedCalls = counters.fusedInvocations
                                diagnostics.attentionExplicitCalls = counters.explicitInvocations
                                diagnostics.attentionFusedPrefillCalls = counters.fusedPrefillInvocations
                                diagnostics.attentionExplicitPrefillCalls = counters.explicitPrefillInvocations
                                diagnostics.attentionFusedDecodeCalls = counters.fusedDecodeInvocations
                                diagnostics.attentionExplicitDecodeCalls = counters.explicitDecodeInvocations
                            } else if generationAttentionStrategy.isConcrete {
                                // Without an installed counter the effective
                                // strategy is still fully determined: a concrete
                                // request resolves to itself on every call.
                                diagnostics.attentionEffectiveStrategies =
                                    [generationAttentionStrategy.reportLabel]
                            }
                            self.lock.withLock { self.currentStats.qwenStreaming = diagnostics }
                        }
                        let conversation = replay ? turns : self.history + turns
                        let thinking = UserDefaults.standard.bool(forKey: ExperimentalInferencePreferences.qwenThinkingKey)
                        let messages: [[String: any Sendable]] = conversation.map {
                            ["role": $0.role.rawValue, "content": $0.content]
                        }
                        let promptStarted = ContinuousClock.now
                        let prompt = try tokenizer.applyChatTemplate(messages: messages, tools: nil,
                            additionalContext: ["enable_thinking": thinking])
                        self.notifyDebugLifecycle("prompt-rendered")
                        diagnostics.promptRenderSeconds = promptStarted.duration(to: .now).qwenSeconds
                        diagnostics.promptTokens = prompt.count
                        diagnostics.inputHash = QwenStreamingDiagnostics.hashTokenIDs(Array(prompt))
                        let limit = maxTokens ?? 512
                        guard limit > 0, !prompt.isEmpty,
                              prompt.count <= self.contextWindow - limit else {
                            throw EngineError.loadFailed("Qwen’s admitted context includes both input and reserved output. Shorten this conversation or reduce output length.")
                        }
                        let requestedTemperature = temperature ?? 0.6
                        guard requestedTemperature.isFinite, requestedTemperature >= 0, Float(requestedTemperature).isFinite else {
                            throw EngineError.loadFailed("Invalid sampling temperature.")
                        }
                        let parameters = GenerateParameters(temperature: Float(requestedTemperature))
                        let sampler = parameters.sampler()
                        let cache = model.newCache(parameters: parameters)
                        // AgentLoop sends the previous assistant turn with the
                        // next input. Accumulate only handed-in canonical turns.
                        if !replay { self.history = conversation }
                        var logits: MLXArray?
                        let prefillStarted = ContinuousClock.now
                        // Bound prefill to four tokens. The model computes the
                        // real router and all eight experts for every token;
                        // QwenStreamExpertPool only deduplicates those actual
                        // bundles for one quantized matmul. Decode below stays
                        // single-token so its cache and routing contract is
                        // independent of this throughput optimization.
                        let prefillBatchSize = pool.maximumPrefillTokens
                        self.stores?.setReadPhase(.prefill)
                        pool.setDebugLifecyclePhase("prefill")
                        self.notifyDebugLifecycle("prefill-start")
                        var prefillOffset = 0
                        while prefillOffset < prompt.count {
                            try self.checkOwnership(id)
                            let end = min(prefillOffset + prefillBatchSize, prompt.count)
                            self.notifyDebugLifecycle("prefill-group-start")
                            let tokenBatch = Array(prompt[prefillOffset..<end])
                            logits = try await model(
                                MLXArray(tokenBatch).reshaped(1, tokenBatch.count),
                                cache: cache, pool: pool,
                                attentionStrategy: generationAttentionStrategy,
                                diagnosticCounters: generationAttentionCounters)
                            MLX.eval(logits!, cache.map { $0.state })
                            prefillOffset = end
                        }
                        prefillCompleted = ContinuousClock.now
                        self.notifyDebugLifecycle("prefill-complete")
                        diagnostics.prefillSeconds = prefillStarted.duration(to: prefillCompleted!).qwenSeconds
                        self.stores?.setReadPhase(.decode)
                        pool.setDebugLifecyclePhase("decode")
                        var generated: [Int] = []
                        var delivered = ""
                        // Opening thinking marker may already be in the prompt.
                        let suffix = tokenizer.decode(tokenIds: Array(prompt.suffix(12)), skipSpecialTokens: false)
                        let opening = thinking && Self.suffixStartsInReasoning(suffix) ? "<think>\n" : ""
                        if !opening.isEmpty { try self.checkOwnership(id); continuation.yield(opening) }
                        for _ in 0..<limit {
                            try self.checkOwnership(id)
                            self.notifyDebugLifecycle("decode-step-start")
                            let nextLogits = logits![0, -1]
                            guard MLX.all(MLX.isFinite(nextLogits)).item(Bool.self) else {
                                throw EngineError.loadFailed("Qwen produced a non-finite sampling distribution.")
                            }
                            let token = sampler.sample(logits: nextLogits).item(Int.self)
                            if token == 248046 || token == 248044 { diagnostics.state = "eos"; break }
                            let now = ContinuousClock.now
                            if firstToken == nil {
                                firstToken = now
                                diagnostics.firstTokenSeconds = started.duration(to: now).qwenSeconds
                            }
                            lastToken = now
                            generated.append(token)
                            generatedCount = generated.count
                            let decodeStarted = ContinuousClock.now
                            let decoded = tokenizer.decode(tokenIds: generated, skipSpecialTokens: false)
                            tokenDecodeSeconds += decodeStarted.duration(to: .now).qwenSeconds
                            if !decoded.hasSuffix("\u{FFFD}"), decoded.hasPrefix(delivered) {
                                let delta = String(decoded.dropFirst(delivered.count))
                                if !delta.isEmpty { try self.checkOwnership(id); continuation.yield(delta) }
                                delivered = decoded
                                if diagnostics.firstAnswerSeconds == nil {
                                    let wire = opening + decoded
                                    let answer = thinking ? wire.components(separatedBy: "</think>").dropFirst().joined(separator: "</think>") : wire
                                    if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        diagnostics.firstAnswerSeconds = started.duration(to: now).qwenSeconds
                                    }
                                }
                            }
                            if generated.count < limit {
                                decodeCallCount += 1
                                self.notifyDebugLifecycle("decode-call-start")
                                logits = try await model(
                                    MLXArray([token]).reshaped(1, 1), cache: cache, pool: pool,
                                    attentionStrategy: generationAttentionStrategy,
                                    diagnosticCounters: generationAttentionCounters)
                                MLX.eval(logits!, cache.map { $0.state })
                            }
                        }
                        try self.checkOwnership(id)
                        let finalDecodeStarted = ContinuousClock.now
                        let finalText = tokenizer.decode(tokenIds: generated, skipSpecialTokens: false)
                        tokenDecodeSeconds += finalDecodeStarted.duration(to: .now).qwenSeconds
                        if finalText.hasPrefix(delivered), finalText != delivered {
                            continuation.yield(String(finalText.dropFirst(delivered.count)))
                        }
                        if diagnostics.state != "eos" { diagnostics.state = "output limit" }
                        let seconds = firstToken.flatMap { first in lastToken.map { first.duration(to: $0) } }
                        let elapsed = seconds.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
                        if generated.count > 1, elapsed > 0 {
                            diagnostics.decodeSeconds = elapsed
                            diagnostics.decodeTokensPerSecond = Double(generated.count - 1) / elapsed
                        }
                        diagnostics.generatedTokens = generated.count
                        diagnostics.decodeCalls = decodeCallCount
                        diagnostics.stopReason = diagnostics.state
                        let totalSeconds = started.duration(to: .now).qwenSeconds
                        diagnostics.endToEndTokensPerSecond = totalSeconds > 0
                            ? Double(generated.count) / totalSeconds
                            : nil
                        self.lock.withLock {
                            self.currentStats = EngineStats(
                                tokensPerSecond: diagnostics.decodeTokensPerSecond,
                                generatedTokens: generated.count, promptTokens: prompt.count,
                                usageSerial: self.currentStats.usageSerial &+ 1)
                        }
                        let finalized = ContinuousClock.now
                        if let lastToken {
                            diagnostics.finalizationSeconds = max(0, lastToken.duration(to: finalized).qwenSeconds)
                        } else {
                            diagnostics.finalizationSeconds = started.duration(to: finalized).qwenSeconds
                        }
                    }
                    self.finishOwnership(id)
                    continuation.finish()
                } catch {
                    self.finishOwnership(id)
                    continuation.finish(throwing: error)
                }
            }
            lock.withLock {
                if owner == id { task = worker } else { worker.cancel() }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    static func suffixStartsInReasoning(_ suffix: String) -> Bool {
        guard let opening = suffix.range(of: "<think>", options: .backwards) else { return false }
        guard let closing = suffix.range(of: "</think>", options: .backwards) else { return true }
        return opening.lowerBound > closing.lowerBound
    }

    private func checkOwnership(_ id: UUID) throws {
        try Task.checkCancellation()
        guard lock.withLock({ owner == id }) else { throw CancellationError() }
    }
    private func finishOwnership(_ id: UUID) {
        lock.withLock { if owner == id { owner = nil; task = nil } }
    }
    func cancelGeneration() async {
        let started = ContinuousClock.now
        let pending = lock.withLock { () -> Task<Void, Never>? in
            owner = nil
            let pending = task
            task = nil
            return pending
        }
        pending?.cancel()
        await pending?.value
        if pending != nil {
            lock.withLock { currentStats.qwenStreaming?.cancellationSeconds = started.duration(to: .now).qwenSeconds }
        }
    }
    func reset() async {
        await cancelGeneration()
        _ = try? await gate.run { self.history.removeAll() }
    }

    /// Clears only reusable application expert entries after the generation
    /// gate is idle. Resident common weights and the installed checkpoint are
    /// preserved. This is used by diagnostic cold-pool trials; it is not a
    /// model unload and it never races an active generation.
    func resetApplicationExpertPool() async -> Bool {
        (try? await gate.run {
            guard self.lock.withLock({ self.owner == nil }) else { return false }
            self.pool?.trim()
            self.accessTrace?.reset()
            return true
        }) ?? false
    }

    /// Development-only direct forward used by the independent parity
    /// fixture. It accepts already-rendered token IDs so the reference can
    /// compare the exact same prompt without reimplementing chat-template
    /// rendering. It does not mutate chat history or publish UI output.
    func debugForward(tokenIDs: [Int]) async throws -> [Float] {
        guard !tokenIDs.isEmpty else { throw EngineError.loadFailed("Parity fixture is empty.") }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            var logits: MLXArray?
            var offset = 0
            let groupSize = pool.maximumPrefillTokens
            while offset < tokenIDs.count {
                let end = min(offset + groupSize, tokenIDs.count)
                logits = try await model(
                    MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset),
                    cache: cache, pool: pool)
                MLX.eval(logits!, cache.map { $0.state })
                offset = end
            }
            let final = logits![0, -1]
            MLX.eval(final)
            return final.asArray(Float.self)
        }
    }

    /// Development-only layer snapshot path for locating the first mismatch
    /// against the independent reference. It returns only the last position
    /// of each evaluated layer, never hidden-state traces from normal chat.
    func debugLayerForward(tokenIDs: [Int]) async throws -> [[Float]] {
        guard !tokenIDs.isEmpty else { throw EngineError.loadFailed("Parity fixture is empty.") }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            var offset = 0
            var snapshots = [[Float]]()
            let groupSize = pool.maximumPrefillTokens
            while offset < tokenIDs.count {
                let end = min(offset + groupSize, tokenIDs.count)
                let (logits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset),
                    cache: cache,
                    pool: pool)
                MLX.eval(logits, cache.map { $0.state }, layerOutputs)
                snapshots = layerOutputs.map { output in
                    output[0, -1].asArray(Float.self)
                }
                offset = end
            }
            return snapshots
        }
    }

    /// Deterministic, cached-decode parity path.  This is intentionally kept
    /// separate from normal chat generation: it uses ArgMaxSampler, accepts
    /// already-rendered token IDs, and retains only bounded checkpoints.  The
    /// model, router, cache, and expert pool are otherwise exactly the same
    /// production objects used by Assistant Send.
    func debugGreedy(
        tokenIDs: [Int],
        maxTokens: Int,
        checkpointSteps: [Int] = [-1, 1, 2, 4, 8, 16, 32, 64, 128],
        rawRouterKeys: Set<QwenStreamRouterTraceKey> = [],
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        includeFinalStateProbe: Bool = true
    ) async throws -> QwenStreamDebugRun {
        guard !tokenIDs.isEmpty, maxTokens > 0 else {
            throw EngineError.loadFailed("Parity fixture is empty or has no output budget.")
        }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            let requestedSteps = Set(checkpointSteps)
            var prefillCallCount = 0
            var cachedDecodeCallCount = 0
            let sampledLayers = Set([0, 19, 39])
            // Match the bounded independent-oracle boundaries without
            // tracing every token.  This remains diagnostic-only: the trace
            // is capped and has no effect on routing or execution order.
            var diagnosticPositions = Set([0, 1, 2, 4, 8, 16, 32, 64, 128, 256])
            diagnosticPositions.insert(max(0, tokenIDs.count - 1))
            for step in requestedSteps where step >= 1 {
                diagnosticPositions.insert(tokenIDs.count + step - 1)
            }
            pool.enableRouterTrace(QwenStreamRouterTrace(
                positions: diagnosticPositions,
                rawKeys: rawRouterKeys))
            pool.setDebugPositionOffset(0)

            func checkpoint(
                decodeStep: Int,
                inputToken: Int?,
                logits: MLXArray,
                layerOutputs: [MLXArray]
            ) -> QwenStreamDebugCheckpoint {
                let finalLogits = logits[0, -1]
                MLX.eval(finalLogits)
                let logitsValues = finalLogits.asArray(Float.self)
                let topLogitIDs = logitsValues.indices
                    .sorted { logitsValues[$0] > logitsValues[$1] }
                    .prefix(9)
                    .map { $0 }
                let predicted = topLogitIDs.first ?? ArgMaxSampler().sample(logits: finalLogits).item(Int.self)
                let layers = sampledLayers.sorted().compactMap { layer -> QwenStreamLayerSnapshot? in
                    guard layer < layerOutputs.count else { return nil }
                    return QwenStreamLayerSnapshot(
                        layer: layer,
                        hidden: QwenStreamArraySummary(layerOutputs[layer][0, -1]))
                }
                return QwenStreamDebugCheckpoint(
                    decodeStep: decodeStep,
                    inputToken: inputToken,
                    predictedToken: predicted,
                    topToken: predicted,
                    topLogitIDs: topLogitIDs,
                    topLogits: topLogitIDs.map { logitsValues[$0] },
                    layerSnapshots: layers,
                    cache: QwenStreamCacheSnapshot(cache: cache))
            }

            var logits: MLXArray?
            var finalLayerOutputs = [MLXArray]()
            var offset = 0
            let groupSize = pool.maximumPrefillTokens
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset),
                    cache: cache,
                    pool: pool,
                    attentionStrategy: attentionStrategy,
                    diagnosticCounters: diagnosticCounters,
                    diagnosticGroup: prefillCallCount)
                logits = nextLogits
                finalLayerOutputs = layerOutputs
                MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                prefillCallCount += 1
                offset = end
            }

            var checkpoints = [QwenStreamDebugCheckpoint]()
            if requestedSteps.contains(-1), let logits {
                checkpoints.append(checkpoint(
                    decodeStep: -1,
                    inputToken: nil,
                    logits: logits,
                    layerOutputs: finalLayerOutputs))
            }

            var generated = [Int]()
            var stopReason = "output_limit"
            while generated.count < maxTokens {
                try Task.checkCancellation()
                guard let currentLogits = logits else { throw EngineError.loadFailed("Parity logits are unavailable.") }
                let next = ArgMaxSampler().sample(logits: currentLogits[0, -1]).item(Int.self)
                if next == 248046 || next == 248044 {
                    stopReason = "eos"
                    break
                }
                generated.append(next)

                // The reference-compatible fixture counts only calls that
                // produce another emitted token.  Keep the optional final
                // state probe explicit: callers that need the post-token
                // state can retain the historical default, while ordinary
                // cached-decode parity can stop after the final emitted ID.
                if generated.count == maxTokens && !includeFinalStateProbe {
                    break
                }

                // Feeding the emitted token advances every recurrent and KV
                // cache exactly once.  This is the boundary used by the
                // cached-decode oracle and avoids accidentally re-prefilling.
                pool.setDebugPositionOffset(tokenIDs.count + generated.count - 1)
                let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray([next]).reshaped(1, 1),
                    cache: cache,
                    pool: pool,
                    attentionStrategy: attentionStrategy,
                    diagnosticCounters: diagnosticCounters,
                    diagnosticGroup: prefillCallCount + cachedDecodeCallCount)
                logits = nextLogits
                finalLayerOutputs = layerOutputs
                MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                cachedDecodeCallCount += 1
                let step = generated.count
                if requestedSteps.contains(step) {
                    checkpoints.append(checkpoint(
                        decodeStep: step,
                        inputToken: next,
                        logits: nextLogits,
                        layerOutputs: layerOutputs))
                }
                if generated.count == maxTokens { break }
            }

            return QwenStreamDebugRun(
                promptTokenIDs: tokenIDs,
                generatedTokenIDs: generated,
                stopReason: stopReason,
                finalConsumedPosition: tokenIDs.count + generated.count,
                checkpoints: checkpoints.sorted { $0.decodeStep < $1.decodeStep },
                router: pool.debugRouterTrace(),
                prefillCallCount: prefillCallCount,
                cachedDecodeCallCount: cachedDecodeCallCount,
                decodeEmissionCallCount: max(0, min(cachedDecodeCallCount, generated.count - 1)),
                finalStateProbeCallCount: cachedDecodeCallCount > 0 && cachedDecodeCallCount == generated.count ? 1 : 0)
        }
    }

    /// Returns the full-attention layer indices derived from the installed
    /// model configuration.  This is exposed only to developer validation;
    /// production generation does not select an alternate attention path.
    func debugFullAttentionLayerIndices() async -> [Int] {
        (try? await gate.run { self.model?.fullAttentionLayerIndices ?? [] }) ?? []
    }

    // MARK: - Q2.18 attention-strategy evidence

    /// Builds the bounded SDPA compatibility matrix from *real production
    /// shapes*.  The model runs once on the requested capture strategy — by
    /// default the validated explicit baseline, which is the authoritative
    /// native correctness reference — and every selected full-attention layer
    /// then has its captured post-RoPE queries, post-update cached K/V, scale,
    /// and mask replayed through both the fused kernel and the explicit
    /// reference from byte-identical inputs.
    ///
    /// This is diagnostic-only dual evaluation.  Ordinary generation never
    /// computes both paths: a production strategy is resolved before the
    /// attention call.
    func debugSDPACompatibilityMatrix(
        tokenIDs: [Int],
        forcedTokenIDs: [Int] = [],
        layers: Set<Int>? = nil,
        prefillGroups: Set<Int>? = nil,
        decodeSteps: Set<Int>? = nil,
        captureStrategy: StreamQwen35AttentionStrategy = .referenceCompatibleExplicit
    ) async throws -> QwenStreamSDPACompatibilityMatrix {
        guard !tokenIDs.isEmpty else {
            throw EngineError.loadFailed("Compatibility matrix needs a non-empty prompt.")
        }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let fullLayers = layers ?? Set(model.fullAttentionLayerIndices)
            guard !fullLayers.isEmpty else {
                throw EngineError.loadFailed("No full-attention layers were selected.")
            }
            let cache = model.newCache(parameters: nil)
            let groupSize = pool.maximumPrefillTokens
            var entries = [QwenStreamSDPACompatibilityEntry]()

            func capture(
                _ input: MLXArray,
                phase: String,
                group: Int,
                position: Int
            ) async throws {
                let (_, diagnostics) = try await model.callWithLayerComponents(
                    input,
                    cache: cache,
                    pool: pool,
                    diagnosticLayers: fullLayers,
                    attentionStrategy: captureStrategy,
                    attentionStrategyLayers: fullLayers,
                    applyStrategyToAllLayers: true)
                MLX.eval(cache.map { $0.state })
                for diagnostic in diagnostics.sorted(by: { $0.layer < $1.layer }) {
                    guard let attention = diagnostic.components.fullAttention else { continue }
                    let sdpa = attention.sdpa
                    guard let cachedKeys = sdpa.cachedKeys,
                          let cachedValues = sdpa.cachedValues else { continue }
                    let queryLength = sdpa.queries.dim(2)
                    let keyLength = cachedKeys.dim(2)
                    // Reconstruct the exact mask mode the production decoder
                    // passes: `.causal` carries no array, `.array` does, and
                    // `.none` is the cached single-token decode case.
                    let productionMode: MLXFast.ScaledDotProductAttentionMaskMode
                    if let array = sdpa.mask {
                        productionMode = .array(array)
                    } else if sdpa.maskMode == "causal" {
                        productionMode = .causal
                    } else {
                        productionMode = .none
                    }
                    let explicitMask = StreamQwen35Attention.materializedMask(
                        productionMode,
                        queryLength: queryLength,
                        keyLength: keyLength,
                        cacheOffset: keyLength - queryLength)
                    let probe = StreamQwen35Attention.sdpaCompatibilityProbe(
                        queries: sdpa.queries,
                        keys: cachedKeys,
                        values: cachedValues,
                        scale: sdpa.scale,
                        productionMaskMode: productionMode,
                        explicitMask: explicitMask)
                    entries.append(Self.compareSDPA(
                        probe: probe,
                        phase: phase,
                        layer: diagnostic.layer,
                        group: group,
                        position: position))
                }
            }

            pool.setDebugPositionOffset(0)
            var offset = 0
            var groupIndex = 0
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let input = MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset)
                if prefillGroups == nil || prefillGroups!.contains(groupIndex) {
                    try await capture(input, phase: "prefill", group: groupIndex, position: offset)
                } else {
                    let logits = try await model(
                        input, cache: cache, pool: pool, attentionStrategy: captureStrategy)
                    MLX.eval(logits, cache.map { $0.state })
                }
                offset = end
                groupIndex += 1
            }

            for (index, token) in forcedTokenIDs.enumerated() {
                try Task.checkCancellation()
                let position = tokenIDs.count + index
                pool.setDebugPositionOffset(position)
                let input = MLXArray([token]).reshaped(1, 1)
                if decodeSteps == nil || decodeSteps!.contains(index) {
                    try await capture(input, phase: "decode", group: groupIndex, position: position)
                } else {
                    let logits = try await model(
                        input, cache: cache, pool: pool, attentionStrategy: captureStrategy)
                    MLX.eval(logits, cache.map { $0.state })
                }
                groupIndex += 1
            }

            return Self.summarizeSDPAMatrix(
                entries: entries, captureStrategy: captureStrategy)
        }
    }

    /// Teacher-forced execution of one attention strategy over a fixed
    /// reference token history.  Because both compared runs consume the *same*
    /// tokens, any K=8 membership difference is a true semantic divergence
    /// rather than an artifact of feeding different histories after a first
    /// free-running mismatch.
    ///
    /// The block capture covers one requested full-attention layer at the
    /// requested decode indices: SDPA output, head merge, gate, o_proj, and the
    /// decoder block output.  The router trace covers every requested layer at
    /// every traced position.
    func debugTeacherForcedStrategyReplay(
        tokenIDs: [Int],
        forcedTokenIDs: [Int],
        strategy: StreamQwen35AttentionStrategy,
        blockLayer: Int = 19,
        blockDecodeIndices: Set<Int> = [],
        routerTraceLayers: Set<Int>? = nil,
        rawRouterKeys: Set<QwenStreamRouterTraceKey> = [],
        counters: StreamQwen35AttentionDiagnosticCounters? = nil,
        blockCaptureFullValues: Bool = false
    ) async throws -> QwenStreamDecodeStrategyReplay {
        guard !tokenIDs.isEmpty, !forcedTokenIDs.isEmpty else {
            throw EngineError.loadFailed("Teacher-forced replay needs a prompt and reference tokens.")
        }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let observation = counters ?? StreamQwen35AttentionDiagnosticCounters()
            observation.reset()
            let cache = model.newCache(parameters: nil)
            let groupSize = pool.maximumPrefillTokens
            let tracedPositions = Set((0..<forcedTokenIDs.count).map { tokenIDs.count + $0 })
            pool.enableRouterTrace(QwenStreamRouterTrace(
                maximumRecords: max(
                    4096, (routerTraceLayers?.count ?? 40) * tracedPositions.count + 256),
                layers: routerTraceLayers ?? Set(0 ..< 40),
                positions: tracedPositions,
                rawKeys: rawRouterKeys))

            var prefillCallCount = 0
            var offset = 0
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let input = MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset)
                let logits = try await model(
                    input, cache: cache, pool: pool,
                    attentionStrategy: strategy, diagnosticCounters: observation)
                MLX.eval(logits, cache.map { $0.state })
                prefillCallCount += 1
                offset = end
            }

            var cachedDecodeCallCount = 0
            var predicted = [Int]()
            predicted.reserveCapacity(forcedTokenIDs.count)
            var blocks = [QwenStreamAttentionBlockCapture]()
            var logits: MLXArray?
            for (index, token) in forcedTokenIDs.enumerated() {
                try Task.checkCancellation()
                let position = tokenIDs.count + index
                pool.setDebugPositionOffset(position)
                let input = MLXArray([token]).reshaped(1, 1)
                if blockDecodeIndices.contains(index) {
                    let (nextLogits, diagnostics) = try await model.callWithLayerComponents(
                        input,
                        cache: cache,
                        pool: pool,
                        diagnosticLayers: Set([blockLayer]),
                        attentionStrategy: strategy,
                        attentionStrategyLayers: Set([blockLayer]),
                        diagnosticCounters: observation,
                        applyStrategyToAllLayers: true)
                    logits = nextLogits
                    MLX.eval(nextLogits, cache.map { $0.state })
                    if let diagnostic = diagnostics.first(where: { $0.layer == blockLayer }),
                       let attention = diagnostic.components.fullAttention {
                        func summary(_ array: MLXArray) -> QwenStreamArraySummary {
                            QwenStreamArraySummary(
                                array, sampleCount: 32,
                                captureFullValues: blockCaptureFullValues)
                        }
                        blocks.append(QwenStreamAttentionBlockCapture(
                            layer: blockLayer,
                            decodeIndex: index,
                            position: position,
                            effectiveStrategy: observation.lastEffectiveStrategy?.reportLabel ?? "none",
                            layerInput: summary(diagnostic.components.layerInput),
                            sdpaOutput: summary(attention.sdpa.output),
                            attentionValues: summary(attention.attentionValues),
                            gatedValues: summary(attention.gatedValues),
                            oProjOutput: summary(attention.output),
                            blockOutput: summary(diagnostic.components.output)))
                    }
                } else {
                    let nextLogits = try await model(
                        input, cache: cache, pool: pool,
                        attentionStrategy: strategy, diagnosticCounters: observation)
                    logits = nextLogits
                    MLX.eval(nextLogits, cache.map { $0.state })
                }
                cachedDecodeCallCount += 1
                if let logits {
                    let final = logits[0, -1]
                    MLX.eval(final)
                    predicted.append(ArgMaxSampler().sample(logits: final).item(Int.self))
                }
            }

            let trace = pool.debugRouterTrace()
            return QwenStreamDecodeStrategyReplay(
                strategy: strategy.reportLabel,
                promptTokenCount: tokenIDs.count,
                forcedTokenCount: forcedTokenIDs.count,
                prefillCallCount: prefillCallCount,
                cachedDecodeCallCount: cachedDecodeCallCount,
                fusedCalls: observation.fusedInvocations,
                explicitCalls: observation.explicitInvocations,
                fusedPrefillCalls: observation.fusedPrefillInvocations,
                explicitPrefillCalls: observation.explicitPrefillInvocations,
                fusedDecodeCalls: observation.fusedDecodeInvocations,
                explicitDecodeCalls: observation.explicitDecodeInvocations,
                requestedStrategies: observation.requestedStrategies.map(\.reportLabel).sorted(),
                effectiveStrategies: observation.effectiveStrategies.map(\.reportLabel).sorted(),
                predictedTokenIDs: predicted,
                blocks: blocks,
                router: trace)
        }
    }

    private static func relativeL2(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        var numerator = 0.0
        var denominator = 0.0
        for (left, right) in zip(lhs, rhs) {
            let difference = Double(left) - Double(right)
            numerator += difference * difference
            denominator += Double(right) * Double(right)
        }
        return numerator.squareRoot() / max(denominator.squareRoot(), 1e-12)
    }

    private static func maxAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        return zip(lhs, rhs).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    /// Compares one fused/explicit probe pair.  Both outputs are already BF16
    /// in the native `[batch, heads, queryLength, headDim]` layout, so
    /// byte-identity is a raw comparison of the BF16 backing store rather than
    /// a tolerance test on upcast values.
    private static func compareSDPA(
        probe: StreamQwen35Attention.StreamQwen35SDPACompatibilityProbe,
        phase: String,
        layer: Int,
        group: Int,
        position: Int
    ) -> QwenStreamSDPACompatibilityEntry {
        let explicit = probe.explicit.asType(.bfloat16)
        let fused = probe.fusedProductionMask.asType(.bfloat16)
        let fusedSame = probe.fusedSameMask.asType(.bfloat16)
        MLX.eval(explicit, fused, fusedSame)
        let explicitBytes = explicit.asData(access: .copy).data
        let fusedBytes = fused.asData(access: .copy).data
        let fusedSameBytes = fusedSame.asData(access: .copy).data

        let explicitValues = explicit.asType(.float32).flattened().asArray(Float.self)
        let fusedValues = fused.asType(.float32).flattened().asArray(Float.self)
        let fusedSameValues = fusedSame.asType(.float32).flattened().asArray(Float.self)

        var worstIndex = -1
        var worstDelta = -1.0
        for index in 0 ..< min(explicitValues.count, fusedValues.count) {
            let delta = abs(Double(fusedValues[index]) - Double(explicitValues[index]))
            if delta > worstDelta {
                worstDelta = delta
                worstIndex = index
            }
        }
        let headDim = max(1, probe.headDim)
        let queryLength = max(1, probe.queryLength)
        let heads = max(1, probe.queryHeads)
        let d = worstIndex >= 0 ? worstIndex % headDim : 0
        let q = worstIndex >= 0 ? (worstIndex / headDim) % queryLength : 0
        let h = worstIndex >= 0 ? (worstIndex / (headDim * queryLength)) % heads : 0
        let b = worstIndex >= 0 ? worstIndex / (headDim * queryLength * heads) : 0

        return QwenStreamSDPACompatibilityEntry(
            phase: phase,
            layer: layer,
            group: group,
            position: position,
            queryLength: probe.queryLength,
            keyLength: probe.keyLength,
            queryHeads: probe.queryHeads,
            kvHeads: probe.kvHeads,
            headDim: probe.headDim,
            scale: probe.scale,
            productionMaskMode: probe.productionMaskMode,
            outputDtype: String(describing: explicit.dtype),
            byteIdenticalBF16: fusedBytes == explicitBytes,
            byteIdenticalBF16SameMask: fusedSameBytes == explicitBytes,
            relL2: relativeL2(fusedValues, explicitValues),
            maxAbs: worstDelta >= 0 ? worstDelta : 0,
            worstCoordinate: worstIndex >= 0 ? "[\(b),\(h),\(q),\(d)]" : "n/a",
            worstValueFused: worstIndex >= 0 && worstIndex < fusedValues.count
                ? Double(fusedValues[worstIndex]) : 0,
            worstValueExplicit: worstIndex >= 0 && worstIndex < explicitValues.count
                ? Double(explicitValues[worstIndex]) : 0,
            relL2SameMask: relativeL2(fusedSameValues, explicitValues),
            maxAbsSameMask: maxAbsDifference(fusedSameValues, explicitValues),
            maskSemanticsAgree: fusedBytes == fusedSameBytes)
    }

    private static func summarizeSDPAMatrix(
        entries: [QwenStreamSDPACompatibilityEntry],
        captureStrategy: StreamQwen35AttentionStrategy
    ) -> QwenStreamSDPACompatibilityMatrix {
        let decode = entries.filter { $0.phase == "decode" }
        let prefill = entries.filter { $0.phase == "prefill" }
        return QwenStreamSDPACompatibilityMatrix(
            captureStrategy: captureStrategy.reportLabel,
            entries: entries,
            decodeEntries: decode.count,
            decodeByteIdentical: decode.filter(\.byteIdenticalBF16).count,
            decodeMaxRelL2: decode.map(\.relL2).max() ?? 0,
            decodeMaxAbs: decode.map(\.maxAbs).max() ?? 0,
            prefillEntries: prefill.count,
            prefillByteIdentical: prefill.filter(\.byteIdenticalBF16).count,
            prefillMaxRelL2: prefill.map(\.relL2).max() ?? 0,
            prefillMaxAbs: prefill.map(\.maxAbs).max() ?? 0,
            distinctPrefillQueryLengths: Array(Set(prefill.map(\.queryLength))).sorted(),
            distinctDecodeKeyLengths: Array(Set(decode.map(\.keyLength))).sorted())
    }

    /// Captures compact prefill boundaries for the first-mismatch diagnostic.
    /// The complete native model still executes so the selected layer outputs
    /// are production-path values; only the requested summaries are retained.
    func debugPrefillBoundaries(
        tokenIDs: [Int],
        boundaryLayers: [Int] = [0],
        captureFullComponents: Bool = false,
        fullComponentLayers: Set<Int> = [],
        forceExplicitFullAttentionMask: Bool = false,
        attentionStrategy: StreamQwen35AttentionStrategy = .productionDefault,
        attentionStrategyLayers: Set<Int> = [],
        attentionStrategyGroup: Int? = nil,
        diagnosticCounters: StreamQwen35AttentionDiagnosticCounters? = nil,
        diagnosticSentinel: Float? = nil
    ) async throws -> QwenStreamDebugBoundaryRun {
        guard !tokenIDs.isEmpty else { throw EngineError.loadFailed("Boundary fixture is empty.") }
        let selectedLayers = Array(Set(boundaryLayers).filter { (0..<40).contains($0) }).sorted()
        guard !selectedLayers.isEmpty else { throw EngineError.loadFailed("Boundary layer selection is empty.") }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            let groupSize = pool.maximumPrefillTokens
            let allPositions = Set(0..<tokenIDs.count)
            pool.enableRouterTrace(QwenStreamRouterTrace(
                maximumRecords: max(256, selectedLayers.count * tokenIDs.count),
                layers: Set(selectedLayers),
                positions: allPositions))
            pool.setDebugPositionOffset(0)

            var groups = [QwenStreamDebugBoundaryGroup]()
            groups.reserveCapacity((tokenIDs.count + groupSize - 1) / groupSize)
            var offset = 0
            var groupIndex = 0
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let input = MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset)
                let useStrategy = attentionStrategyGroup == nil || attentionStrategyGroup == groupIndex
                let (logits, layerDiagnostics) = try await model.callWithLayerComponents(
                    input,
                    cache: cache,
                    pool: pool,
                    diagnosticLayers: Set(selectedLayers),
                    forceExplicitFullAttentionMask: forceExplicitFullAttentionMask,
                    attentionStrategy: useStrategy ? attentionStrategy : .productionDefault,
                    attentionStrategyLayers: useStrategy ? attentionStrategyLayers : [],
                    diagnosticCounters: diagnosticCounters,
                    diagnosticSentinel: useStrategy ? diagnosticSentinel : nil,
                    diagnosticGroup: useStrategy ? groupIndex : nil)
                // Evaluating the logits, layer boundaries, and all cache state
                // forms the same completion barrier as the existing parity
                // path before summaries are allowed to release graph owners.
                MLX.eval(logits, cache.map { $0.state })
                let layers = selectedLayers.compactMap { layer -> QwenStreamDebugBoundaryLayer? in
                    guard let diagnostic = layerDiagnostics.first(where: { $0.layer == layer }),
                          layer < cache.count else {
                        return nil
                    }
                    let components = diagnostic.components
                    let captureFullForLayer = captureFullComponents &&
                        (fullComponentLayers.isEmpty || fullComponentLayers.contains(layer))
                    let cacheLayer = QwenStreamCacheLayerSnapshot(
                        layer: layer,
                        cache: cache[layer],
                        captureFullValues: captureFullForLayer)
                    return QwenStreamDebugBoundaryLayer(
                        layer: layer,
                        kind: cacheLayer.kind,
                        positionBefore: offset,
                        positionAfter: end,
                        input: QwenStreamArraySummary(
                            components.layerInput,
                            captureFullValues: captureFullForLayer),
                        output: QwenStreamArraySummary(
                            components.output,
                            captureFullValues: captureFullForLayer),
                        tokenOutputs: (0..<(end - offset)).map {
                            QwenStreamArraySummary(
                                components.output[0, $0],
                                captureFullValues: captureFullForLayer)
                        },
                        cache: cacheLayer,
                        router: pool.debugRouterTrace()?.records.filter { $0.layer == layer &&
                            $0.positions.contains(where: { (offset..<end).contains($0) }) } ?? [],
                        components: QwenStreamDebugLayerComponents(
                            attentionInput: QwenStreamArraySummary(
                                components.attentionInput,
                                captureFullValues: captureFullForLayer),
                            attentionOutput: QwenStreamArraySummary(
                                components.attentionOutput,
                                captureFullValues: captureFullForLayer),
                            postAttentionResidual: QwenStreamArraySummary(
                                components.postAttentionResidual,
                                captureFullValues: captureFullForLayer),
                            postAttentionInput: QwenStreamArraySummary(
                                components.postAttentionInput,
                                captureFullValues: captureFullForLayer),
                            mlpOutput: QwenStreamArraySummary(
                                components.mlpOutput,
                                captureFullValues: captureFullForLayer),
                            // Keep the bounded replay inputs complete for the
                            // four-token diagnostic group.  These are only
                            // emitted by the opt-in localization path; the
                            // normal generation path still stores no hidden
                            // or router tensors.
                            routerInput: QwenStreamArraySummary(
                                components.routerInput,
                                sampleCount: 8192,
                                captureFullValues: captureFullForLayer),
                            routerLogits: QwenStreamArraySummary(
                                components.routerLogits,
                                sampleCount: 1024,
                                captureFullValues: captureFullForLayer),
                            routedOutput: QwenStreamArraySummary(
                                components.routedOutput,
                                captureFullValues: captureFullForLayer),
                            sharedOutput: QwenStreamArraySummary(
                                components.sharedOutput,
                                captureFullValues: captureFullForLayer),
                            linearProjections: components.linearProjections.map {
                                QwenStreamDebugLayerComponents.LinearProjections(
                                    qkv: QwenStreamArraySummary(
                                        $0.qkv,
                                        captureFullValues: captureFullForLayer),
                                    z: QwenStreamArraySummary(
                                        $0.z,
                                        captureFullValues: captureFullForLayer),
                                    b: QwenStreamArraySummary(
                                        $0.b,
                                        captureFullValues: captureFullForLayer),
                                    a: QwenStreamArraySummary(
                                        $0.a,
                                        captureFullValues: captureFullForLayer))
                            },
                            linearAttention: components.linearAttention.map {
                                QwenStreamDebugLayerComponents.LinearAttention(
                                    convOutput: QwenStreamArraySummary(
                                        $0.convOutput,
                                        captureFullValues: captureFullForLayer),
                                    qNormed: QwenStreamArraySummary(
                                        $0.qNormed,
                                        captureFullValues: captureFullForLayer),
                                    kNormed: QwenStreamArraySummary(
                                        $0.kNormed,
                                        captureFullValues: captureFullForLayer),
                                    v: QwenStreamArraySummary(
                                        $0.v,
                                        captureFullValues: captureFullForLayer),
                                    gatedOutput: QwenStreamArraySummary(
                                        $0.gatedOutput,
                                        captureFullValues: captureFullForLayer),
                                    normalizedOutput: QwenStreamArraySummary(
                                        $0.normalizedOutput,
                                        captureFullValues: captureFullForLayer))
                            },
                            fullAttention: components.fullAttention.map {
                                QwenStreamDebugLayerComponents.FullAttention(
                                    queryProjection: QwenStreamArraySummary(
                                        $0.queryProjection,
                                        captureFullValues: captureFullForLayer),
                                    gate: QwenStreamArraySummary(
                                        $0.gate,
                                        captureFullValues: captureFullForLayer),
                                    queries: QwenStreamArraySummary(
                                        $0.queries,
                                        captureFullValues: captureFullForLayer),
                                    keys: QwenStreamArraySummary(
                                        $0.keys,
                                        captureFullValues: captureFullForLayer),
                                    values: QwenStreamArraySummary(
                                        $0.values,
                                        captureFullValues: captureFullForLayer),
                                    attentionValues: QwenStreamArraySummary(
                                        $0.attentionValues,
                                        captureFullValues: captureFullForLayer),
                                    gatedValues: QwenStreamArraySummary(
                                        $0.gatedValues,
                                        captureFullValues: captureFullForLayer),
                                    sdpa: self.makeDebugSDPA(
                                        $0.sdpa, captureFullValues: captureFullForLayer),
                                    requestedStrategy: $0.sdpa.requestedStrategy.rawValue,
                                    effectiveStrategy: $0.sdpa.effectiveStrategy.rawValue,
                                    sentinelApplied: $0.sdpa.sentinelApplied,
                                    explicitTrace: self.makeDebugExplicitAttention(
                                        $0.sdpa.explicitTrace,
                                        captureFullValues: captureFullForLayer))
                            }))
                }
                guard let embedding = layerDiagnostics.first(where: { $0.layer == 0 }) else {
                    throw EngineError.loadFailed("Boundary diagnostics require layer 0 for the embedding snapshot.")
                }
                groups.append(QwenStreamDebugBoundaryGroup(
                    groupIndex: groupIndex,
                    positionBefore: offset,
                    positionAfter: end,
                    tokenIDs: Array(tokenIDs[offset..<end]),
                    embedding: QwenStreamArraySummary(
                        embedding.components.layerInput,
                        captureFullValues: captureFullComponents &&
                            (fullComponentLayers.isEmpty || fullComponentLayers.contains(0))),
                    layers: layers))
                offset = end
                groupIndex += 1
            }
            return QwenStreamDebugBoundaryRun(
                fixtureFormatVersion: "qwen35-k8-boundary-v1",
                fixtureID: "qwen35-k8-prefill-boundary",
                promptTokenIDs: tokenIDs,
                promptTokenCount: tokenIDs.count,
                prefillGroupSize: groupSize,
                boundaryLayerCount: selectedLayers.count,
                groups: groups)
        }
    }

    /// Teacher-forced diagnostic execution. The prompt is prefixed once and
    /// each supplied reference token is then fed through the cached path. The
    /// native sampler is never used to choose the next input token, which lets
    /// a later comparison distinguish a first free-running token mismatch from
    /// a mismatch caused by feeding different histories after divergence.
    func debugTeacherForced(
        tokenIDs: [Int],
        forcedTokenIDs: [Int],
        checkpointSteps: [Int] = [-1, 1, 2, 4, 8, 16, 32, 64]
    ) async throws -> QwenStreamDebugTeacherForcedRun {
        guard !tokenIDs.isEmpty, !forcedTokenIDs.isEmpty else {
            throw EngineError.loadFailed("Teacher-forced fixture is empty.")
        }
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            let requestedSteps = Set(checkpointSteps)
            let sampledLayers = Set([0, 19, 39])
            let tracePositions = Set(0..<(tokenIDs.count + forcedTokenIDs.count))
            pool.enableRouterTrace(QwenStreamRouterTrace(
                maximumRecords: max(256, sampledLayers.count * tracePositions.count),
                layers: sampledLayers,
                positions: tracePositions))

            func checkpoint(
                decodeStep: Int,
                inputToken: Int?,
                logits: MLXArray,
                layerOutputs: [MLXArray]
            ) -> QwenStreamDebugCheckpoint {
                let finalLogits = logits[0, -1]
                MLX.eval(finalLogits)
                let values = finalLogits.asArray(Float.self)
                let ids = values.indices.sorted { values[$0] > values[$1] }.prefix(9).map { $0 }
                let predicted = ids.first ?? ArgMaxSampler().sample(logits: finalLogits).item(Int.self)
                let layers = sampledLayers.sorted().compactMap { layer -> QwenStreamLayerSnapshot? in
                    guard layer < layerOutputs.count else { return nil }
                    return QwenStreamLayerSnapshot(
                        layer: layer,
                        hidden: QwenStreamArraySummary(layerOutputs[layer][0, -1]))
                }
                return QwenStreamDebugCheckpoint(
                    decodeStep: decodeStep,
                    inputToken: inputToken,
                    predictedToken: predicted,
                    topToken: predicted,
                    topLogitIDs: ids,
                    topLogits: ids.map { values[$0] },
                    layerSnapshots: layers,
                    cache: QwenStreamCacheSnapshot(cache: cache))
            }

            var checkpoints = [QwenStreamDebugCheckpoint]()
            var logits: MLXArray?
            var offset = 0
            var prefillCalls = 0
            let groupSize = pool.maximumPrefillTokens
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset),
                    cache: cache,
                    pool: pool)
                logits = nextLogits
                MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                prefillCalls += 1
                offset = end
                if offset == tokenIDs.count, requestedSteps.contains(-1), let logits {
                    checkpoints.append(checkpoint(
                        decodeStep: -1,
                        inputToken: nil,
                        logits: logits,
                        layerOutputs: layerOutputs))
                }
            }

            for (index, forcedToken) in forcedTokenIDs.enumerated() {
                try Task.checkCancellation()
                guard let _ = logits else { throw EngineError.loadFailed("Teacher-forced logits are unavailable.") }
                let step = index + 1
                let position = tokenIDs.count + index
                pool.setDebugPositionOffset(position)
                let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray([forcedToken]).reshaped(1, 1),
                    cache: cache,
                    pool: pool)
                logits = nextLogits
                MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                if requestedSteps.contains(step) {
                    checkpoints.append(checkpoint(
                        decodeStep: step,
                        inputToken: forcedToken,
                        logits: nextLogits,
                        layerOutputs: layerOutputs))
                }
            }

            return QwenStreamDebugTeacherForcedRun(
                fixtureFormatVersion: "qwen35-k8-teacher-forced-v1",
                fixtureID: "qwen35-k8-teacher-forced",
                promptTokenIDs: tokenIDs,
                forcedTokenIDs: forcedTokenIDs,
                prefillCallCount: prefillCalls,
                cachedDecodeCallCount: forcedTokenIDs.count,
                checkpoints: checkpoints.sorted { $0.decodeStep < $1.decodeStep })
        }
    }

    /// Captures one teacher-forced cached-decode token with the real model
    /// state while retaining a bounded set of layer boundaries. This is a
    /// diagnostic-only path for Q2.9: the prompt is prefixed once, the
    /// supplied tokens are fed one at a time, and the target layer is
    /// decomposed in the same pass that advances its cache.
    func debugTeacherForcedLayerComponents(
        tokenIDs: [Int],
        forcedTokenIDs: [Int],
        targetLayer: Int = 19,
        targetPosition: Int = 46,
        captureLayers: [Int] = [0, 9, 14, 17, 18, 19],
        captureFullValues: Bool = true
    ) async throws -> QwenStreamDebugTeacherForcedComponentsRun {
        guard !tokenIDs.isEmpty, !forcedTokenIDs.isEmpty else {
            throw EngineError.loadFailed("Teacher-forced component fixture is empty.")
        }
        guard (0..<40).contains(targetLayer) else {
            throw EngineError.loadFailed("Teacher-forced target layer is out of range.")
        }
        let targetDecodeIndex = targetPosition - tokenIDs.count
        guard targetDecodeIndex >= 0, targetDecodeIndex < forcedTokenIDs.count else {
            throw EngineError.loadFailed("Teacher-forced target position is outside the supplied history.")
        }
        let selectedLayers = Set(captureLayers.filter { (0..<40).contains($0) } + [targetLayer])
        return try await gate.run {
            guard let model = self.model, let pool = self.pool else {
                throw EngineError.notLoaded
            }
            let cache = model.newCache(parameters: nil)
            var logits: MLXArray?
            var prefillCalls = 0
            var cachedDecodeCalls = 0
            var capturedBoundaries = [QwenStreamDebugLayerBoundary]()
            var targetCapture: QwenStreamDebugTargetLayer?
            let groupSize = pool.maximumPrefillTokens

            var offset = 0
            while offset < tokenIDs.count {
                try Task.checkCancellation()
                let end = min(offset + groupSize, tokenIDs.count)
                pool.setDebugPositionOffset(offset)
                let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                    MLXArray(Array(tokenIDs[offset..<end])).reshaped(1, end - offset),
                    cache: cache,
                    pool: pool)
                logits = nextLogits
                MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                prefillCalls += 1
                offset = end
            }

            for index in 0...targetDecodeIndex {
                try Task.checkCancellation()
                guard logits != nil else {
                    throw EngineError.loadFailed("Teacher-forced logits are unavailable.")
                }
                let position = tokenIDs.count + index
                let token = forcedTokenIDs[index]
                pool.setDebugPositionOffset(position)
                let input = MLXArray([token]).reshaped(1, 1)
                if index == targetDecodeIndex {
                    let cacheBefore = QwenStreamCacheLayerSnapshot(
                        layer: targetLayer,
                        cache: cache[targetLayer],
                        captureFullValues: captureFullValues)
                    let (nextLogits, diagnostics, layerOutputs) =
                        try await model.callWithLayerComponentsAndOutputs(
                            input,
                            cache: cache,
                            pool: pool,
                            diagnosticLayers: Set([targetLayer]),
                            outputLayers: selectedLayers)
                    logits = nextLogits
                    MLX.eval(nextLogits)
                    cachedDecodeCalls += 1

                    guard let diagnostic = diagnostics.first(where: { $0.layer == targetLayer }) else {
                        throw EngineError.loadFailed("Target layer diagnostics were not captured.")
                    }
                    guard layerOutputs.contains(where: { $0.layer == targetLayer }) else {
                        throw EngineError.loadFailed("Target layer output was not captured.")
                    }
                    capturedBoundaries = layerOutputs
                        .sorted { $0.layer < $1.layer }
                        .map { boundary in
                            QwenStreamDebugLayerBoundary(
                                layer: boundary.layer,
                                kind: boundary.layer == targetLayer
                                    ? (cache[targetLayer] is MambaCache
                                        ? "GatedDeltaNet/MambaCache"
                                        : "FullAttention/KVCache")
                                    : "DecoderLayer",
                                positionBefore: position,
                                positionAfter: position + 1,
                                input: QwenStreamArraySummary(
                                    boundary.input,
                                    captureFullValues: captureFullValues),
                                output: QwenStreamArraySummary(
                                    boundary.output,
                                    captureFullValues: captureFullValues))
                        }
                    let cacheAfter = QwenStreamCacheLayerSnapshot(
                        layer: targetLayer,
                        cache: cache[targetLayer],
                        captureFullValues: captureFullValues)
                    targetCapture = QwenStreamDebugTargetLayer(
                        layer: targetLayer,
                        kind: cacheAfter.kind,
                        position: position,
                        input: QwenStreamArraySummary(
                            diagnostic.components.layerInput,
                            captureFullValues: captureFullValues),
                        output: QwenStreamArraySummary(
                            diagnostic.components.output,
                            captureFullValues: captureFullValues),
                        components: self.makeDebugLayerComponents(
                            diagnostic.components,
                            captureFullValues: captureFullValues),
                        cacheBefore: cacheBefore,
                        cacheAfter: cacheAfter)
                } else {
                    let (nextLogits, layerOutputs) = try await model.callWithLayerOutputs(
                        input,
                        cache: cache,
                        pool: pool)
                    logits = nextLogits
                    MLX.eval(nextLogits, cache.map { $0.state }, layerOutputs)
                    cachedDecodeCalls += 1
                }
            }

            guard let targetCapture else {
                throw EngineError.loadFailed("Teacher-forced target capture is unavailable.")
            }
            return QwenStreamDebugTeacherForcedComponentsRun(
                fixtureFormatVersion: "qwen35-k8-q29-teacher-forced-components-v1",
                fixtureID: "qwen35-k8-q29-layer19-position46",
                promptTokenIDs: tokenIDs,
                forcedTokenIDs: forcedTokenIDs,
                targetLayer: targetLayer,
                targetPosition: targetPosition,
                targetInputTokenID: forcedTokenIDs[targetDecodeIndex],
                prefillCallCount: prefillCalls,
                cachedDecodeCallCount: cachedDecodeCalls,
                capturedLayers: capturedBoundaries,
                target: targetCapture)
        }
    }

    /// Replays the native GatedDelta kernel with explicitly supplied
    /// projection/state tensors. This is a bounded Q2.9 diagnostic seam only:
    /// it is used to test whether the first differing layer is caused by the
    /// operation itself or by its incoming recurrent state history.
    func debugGatedDeltaReplay(
        layer: Int,
        q: [Float], qShape: [Int],
        k: [Float], kShape: [Int],
        v: [Float], vShape: [Int],
        a: [Float], aShape: [Int],
        b: [Float], bShape: [Int],
        state: [Float], stateShape: [Int]
    ) async throws -> QwenStreamDebugGatedDeltaReplay {
        guard !q.isEmpty, !k.isEmpty, !v.isEmpty, !a.isEmpty, !b.isEmpty, !state.isEmpty else {
            throw EngineError.loadFailed("GatedDelta replay tensors are empty.")
        }
        return try await gate.run {
            guard let model = self.model else { throw EngineError.notLoaded }
            func bf16(_ values: [Float], _ shape: [Int]) -> MLXArray {
                MLXArray(values, shape).asType(.bfloat16)
            }
            let qArray = bf16(q, qShape)
            let kArray = bf16(k, kShape)
            let vArray = bf16(v, vShape)
            let aArray = bf16(a, aShape)
            let bArray = bf16(b, bShape)
            let stateArray = MLXArray(state, stateShape).asType(.float32)
            let (output, newState) = try model.debugGatedDeltaReplay(
                layer: layer,
                q: qArray,
                k: kArray,
                v: vArray,
                a: aArray,
                b: bArray,
                state: stateArray)
            return QwenStreamDebugGatedDeltaReplay(
                output: QwenStreamArraySummary(output, captureFullValues: true),
                state: QwenStreamArraySummary(newState, captureFullValues: true))
        }
    }

    private func makeDebugLayerComponents(
        _ components: StreamQwen35DecoderLayer.DiagnosticComponents,
        captureFullValues: Bool
    ) -> QwenStreamDebugLayerComponents {
        QwenStreamDebugLayerComponents(
            attentionInput: QwenStreamArraySummary(
                components.attentionInput,
                captureFullValues: captureFullValues),
            attentionOutput: QwenStreamArraySummary(
                components.attentionOutput,
                captureFullValues: captureFullValues),
            postAttentionResidual: QwenStreamArraySummary(
                components.postAttentionResidual,
                captureFullValues: captureFullValues),
            postAttentionInput: QwenStreamArraySummary(
                components.postAttentionInput,
                captureFullValues: captureFullValues),
            mlpOutput: QwenStreamArraySummary(
                components.mlpOutput,
                captureFullValues: captureFullValues),
            routerInput: QwenStreamArraySummary(
                components.routerInput,
                sampleCount: 8192,
                captureFullValues: captureFullValues),
            routerLogits: QwenStreamArraySummary(
                components.routerLogits,
                sampleCount: 1024,
                captureFullValues: captureFullValues),
            routedOutput: QwenStreamArraySummary(
                components.routedOutput,
                captureFullValues: captureFullValues),
            sharedOutput: QwenStreamArraySummary(
                components.sharedOutput,
                captureFullValues: captureFullValues),
            linearProjections: components.linearProjections.map {
                QwenStreamDebugLayerComponents.LinearProjections(
                    qkv: QwenStreamArraySummary(
                        $0.qkv,
                        captureFullValues: captureFullValues),
                    z: QwenStreamArraySummary(
                        $0.z,
                        captureFullValues: captureFullValues),
                    b: QwenStreamArraySummary(
                        $0.b,
                        captureFullValues: captureFullValues),
                    a: QwenStreamArraySummary(
                        $0.a,
                        captureFullValues: captureFullValues))
            },
            linearAttention: components.linearAttention.map {
                QwenStreamDebugLayerComponents.LinearAttention(
                    convOutput: QwenStreamArraySummary(
                        $0.convOutput,
                        captureFullValues: captureFullValues),
                    qNormed: QwenStreamArraySummary(
                        $0.qNormed,
                        captureFullValues: captureFullValues),
                    kNormed: QwenStreamArraySummary(
                        $0.kNormed,
                        captureFullValues: captureFullValues),
                    v: QwenStreamArraySummary(
                        $0.v,
                        captureFullValues: captureFullValues),
                    gatedOutput: QwenStreamArraySummary(
                        $0.gatedOutput,
                        captureFullValues: captureFullValues),
                    normalizedOutput: QwenStreamArraySummary(
                        $0.normalizedOutput,
                        captureFullValues: captureFullValues))
            },
            fullAttention: components.fullAttention.map {
                QwenStreamDebugLayerComponents.FullAttention(
                    queryProjection: QwenStreamArraySummary(
                        $0.queryProjection,
                        captureFullValues: captureFullValues),
                    gate: QwenStreamArraySummary(
                        $0.gate,
                        captureFullValues: captureFullValues),
                    queries: QwenStreamArraySummary(
                        $0.queries,
                        captureFullValues: captureFullValues),
                    keys: QwenStreamArraySummary(
                        $0.keys,
                        captureFullValues: captureFullValues),
                    values: QwenStreamArraySummary(
                        $0.values,
                        captureFullValues: captureFullValues),
                    attentionValues: QwenStreamArraySummary(
                        $0.attentionValues,
                        captureFullValues: captureFullValues),
                    gatedValues: QwenStreamArraySummary(
                        $0.gatedValues,
                        captureFullValues: captureFullValues),
                    sdpa: self.makeDebugSDPA(
                        $0.sdpa, captureFullValues: captureFullValues),
                    requestedStrategy: $0.sdpa.requestedStrategy.rawValue,
                    effectiveStrategy: $0.sdpa.effectiveStrategy.rawValue,
                    sentinelApplied: $0.sdpa.sentinelApplied,
                    explicitTrace: self.makeDebugExplicitAttention(
                        $0.sdpa.explicitTrace,
                        captureFullValues: captureFullValues))
            })
    }

    private func makeDebugSDPA(
        _ sdpa: StreamQwen35Attention.DiagnosticAttention.SDPAInvocation,
        captureFullValues: Bool
    ) -> QwenStreamDebugSDPAInvocation {
        QwenStreamDebugSDPAInvocation(
            scale: sdpa.scale,
            scaleBits: sdpa.scaleBits,
            scaleExpression: sdpa.scaleExpression,
            maskMode: sdpa.maskMode,
            mask: sdpa.mask.map {
                QwenStreamArraySummary($0, captureFullValues: captureFullValues)
            },
            queryLayout: QwenStreamArrayLayout(sdpa.queries),
            keyLayout: QwenStreamArrayLayout(sdpa.keys),
            valueLayout: QwenStreamArrayLayout(sdpa.values),
            cachedKeyLayout: sdpa.cachedKeys.map(QwenStreamArrayLayout.init),
            cachedValueLayout: sdpa.cachedValues.map(QwenStreamArrayLayout.init),
            outputLayout: QwenStreamArrayLayout(sdpa.output),
            output: QwenStreamArraySummary(
                sdpa.output, captureFullValues: captureFullValues))
    }

    private func makeDebugExplicitAttention(
        _ trace: StreamQwen35ExplicitAttentionTrace?,
        captureFullValues: Bool
    ) -> QwenStreamDebugExplicitAttention? {
        trace.map {
            QwenStreamDebugExplicitAttention(
                expandedKeys: QwenStreamArraySummary(
                    $0.expandedKeys, captureFullValues: captureFullValues),
                expandedValues: QwenStreamArraySummary(
                    $0.expandedValues, captureFullValues: captureFullValues),
                rawQK: QwenStreamArraySummary(
                    $0.rawQK, captureFullValues: captureFullValues),
                scaledScores: QwenStreamArraySummary(
                    $0.scaledScores, captureFullValues: captureFullValues),
                maskedScores: QwenStreamArraySummary(
                    $0.maskedScores, captureFullValues: captureFullValues),
                probabilities: QwenStreamArraySummary(
                    $0.probabilities, captureFullValues: captureFullValues),
                weightedOutputFloat32: QwenStreamArraySummary(
                    $0.weightedOutputFloat32, captureFullValues: captureFullValues),
                output: QwenStreamArraySummary(
                    $0.output, captureFullValues: captureFullValues))
        }
    }

    /// A compact resource/lifecycle assertion surface for validation tests.
    /// The production UI does not expose this and no payload data leaves the
    /// generation gate.
    func debugQuiescence() async -> (ownerActive: Bool, poolBusy: Bool, activeLeases: Int, poolEntries: Int, poolCapacitySlots: Int, queuedReads: Int, activeReads: Int) {
            (try? await gate.run {
            let state = self.pool?.debugState()
            let readState = self.stores?.readStatistics()
            return (
                ownerActive: self.lock.withLock { self.owner != nil },
                poolBusy: state?.busy ?? false,
                activeLeases: state?.activeLeases ?? 0,
                poolEntries: state?.entries ?? 0,
                poolCapacitySlots: state?.capacitySlots ?? 0,
                queuedReads: readState?.queuedReadsAtSnapshot ?? 0,
                activeReads: readState?.activeReadsAtSnapshot ?? 0)
        }) ?? (
            ownerActive: self.lock.withLock { self.owner != nil },
            poolBusy: false,
            activeLeases: 0,
            poolEntries: 0,
            poolCapacitySlots: 0,
            queuedReads: 0,
            activeReads: 0)
    }

    func unload() async {
        await cancelGeneration()
        _ = try? await gate.run {
            self.pool?.trim()
            self.pool = nil
            self.accessTrace = nil
            self.model = nil
            self.tokenizer = nil
            self.history = []
            await self.stores?.closeAll()
            self.stores = nil
            self.scopedDirectory?.stopAccessingSecurityScopedResource()
            self.scopedDirectory = nil
            MLX.Memory.clearCache()
            self.lock.withLock {
                self.loadedID = nil
                self.contextWindow = 0
                self.currentStats = EngineStats()
                self.debugLifecycleObserver = nil
            }
        }
    }
    func trimTransientMemory() async {
        _ = try? await gate.run { self.pool?.trim(); MLX.Memory.clearCache() }
    }
}
