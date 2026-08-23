import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

/// Pure correctness boundary for in-memory prompt reuse. MLX already holds
/// the generated assistant tokens in its KV cache; Beet Code may omit the
/// assistant echo on the next request only when it is byte-for-byte the same
/// after harmless edge-whitespace trimming and another turn follows it.
enum MLXPromptCachePlanner {
    enum Plan: Equatable {
        case fullReplay
        case incremental([ChatTurn])
    }

    static func plan(
        newTurns: [ChatTurn],
        expectedAssistantEcho: String?,
        enabled: Bool
    ) -> Plan {
        guard enabled,
              let expectedAssistantEcho,
              newTurns.count > 1,
              let first = newTurns.first,
              first.role == .assistant,
              canonical(first.content) == canonical(expectedAssistantEcho)
        else { return .fullReplay }

        return .incremental(Array(newTurns.dropFirst()))
    }

    static func canonical(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// MLX-backed engine. Runs in-process on the app's own GPU context.
///
/// All `ChatSession`/Metal access is funneled through `GenerationGate` —
/// `session` is only ever touched inside `gate.run { }` closures, which are
/// serialized. That is what keeps concurrent command buffers (a process-
/// killing MLX crash) impossible by construction.
public final class MLXEngine: LLMEngine, @unchecked Sendable {

    private let gate: GenerationGate

    /// Engines created with a shared gate (the EnginePool) serialize their
    /// Metal work with every other resident model — MLX permits only one
    /// command buffer in flight per process, regardless of how many models
    /// are resident. Standalone engines own their gate.
    public init(
        gate: GenerationGate = GenerationGate(),
        experimentalPromptCacheEnabled: Bool = false,
        experimentalQuantizedKVEnabled: Bool = false
    ) {
        self.gate = gate
        self.configuredPromptCacheEnabled = experimentalPromptCacheEnabled
        self.configuredQuantizedKVEnabled = experimentalQuantizedKVEnabled
    }

    private let configuredPromptCacheEnabled: Bool
    private let configuredQuantizedKVEnabled: Bool

    // Only accessed inside gate.run closures. `nonisolated(unsafe)` documents
    // that the gate — not the type system — guarantees exclusive access.
    private nonisolated(unsafe) var session: ChatSession?
    private nonisolated(unsafe) var loadedID: String?
    /// Lightweight symlink snapshot used only for custom Qwen3.5 conversions
    /// whose text weights retain the unified `language_model.*` namespace.
    private nonisolated(unsafe) var compatibilityDirectory: URL?
    private nonisolated(unsafe) var statsState = EngineStats()
    private nonisolated(unsafe) var loading = false
    /// Per-load runtime state. Any experimental failure turns both off until
    /// the next reload, while the persisted switches remain unchanged.
    private nonisolated(unsafe) var runtimePromptCacheEnabled = false
    private nonisolated(unsafe) var runtimeQuantizedKVEnabled = false
    private nonisolated(unsafe) var expectedAssistantEcho: String?
    /// The active stream task. Retaining it lets Stop cancel the running
    /// generation instead of only invalidating queued gate work.
    private nonisolated(unsafe) var generationTask: Task<Void, Never>?
    private nonisolated(unsafe) var generationID: UUID?
    private let generationLock = NSLock()
    /// Canonical conversation. It remains the source of truth even when the
    /// optional prompt cache is active, so every mismatch can clear MLX state
    /// and replay a correct transcript immediately.
    private nonisolated(unsafe) var history: [ChatTurn] = []

    public var loadedModelID: String? {
        get async { try? await gate.run { self.loadedID } }
    }

    public var stats: EngineStats {
        get async { (try? await gate.run { self.statsState }) ?? EngineStats() }
    }

    public func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        // MemoryAdvisor is the single admission authority — engines never
        // second-guess it.
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)

        try await gate.run {
            guard !self.loading else { throw EngineError.alreadyLoading }
            self.loading = true
            defer { self.loading = false }

            do {
                Log.engine.info("Loading model \(modelID, privacy: .public)")
                let started = Date()

                let loadDirectory: URL
                if let compatibilityDirectory = try Qwen35CheckpointCompatibility
                    .makeLoadDirectoryIfNeeded(for: directory)
                {
                    self.compatibilityDirectory = compatibilityDirectory
                    loadDirectory = compatibilityDirectory
                    await LLMTypeRegistry.shared.registerModelType(
                        Qwen35CheckpointCompatibility.modelType,
                        creator: Qwen35CheckpointCompatibility.makeModel)
                    Log.engine.info(
                        "Using tied-output compatibility for unified Qwen3.5 text weights")
                } else {
                    loadDirectory = directory
                }

                let isVisionLanguageModel = MLXModelInspector.isVisionLanguageModel(
                    at: loadDirectory)
                let container: ModelContainer
                if isVisionLanguageModel {
                    Log.engine.info("Detected multimodal MLX checkpoint; loading through the VLM factory")
                    container = try await VLMModelFactory.shared.loadContainer(
                        from: loadDirectory,
                        using: HFTokenizerLoader())
                } else {
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: loadDirectory,
                        using: HFTokenizerLoader())
                }

                // Keep the Metal buffer cache modest: weights are memory-mapped
                // and paged in on demand; a large cache would double-count RAM.
                MLX.Memory.cacheLimit = 128 * 1024 * 1024

                // Text-only first: VLM cache shapes vary widely and are not a
                // useful first target for these deliberately risky switches.
                self.runtimePromptCacheEnabled =
                    self.configuredPromptCacheEnabled && !isVisionLanguageModel
                self.runtimeQuantizedKVEnabled =
                    self.configuredQuantizedKVEnabled && !isVisionLanguageModel
                self.expectedAssistantEcho = nil

                self.session = ChatSession(
                    container,
                    generateParameters: MLXEngine.makeParameters(
                        temperature: 0.6,
                        maxTokens: nil,
                        quantizedKVEnabled: self.runtimeQuantizedKVEnabled),
                    // Qwen 3.5's chat template enables its hidden thinking
                    // channel by default. BeetCode already owns a separate
                    // reasoning surface, so leave the template in direct-
                    // answer mode; otherwise a short task can consume the
                    // whole budget before emitting visible text.
                    additionalContext: ["enable_thinking": false])
                self.loadedID = modelID
                self.statsState = EngineStats(
                    mlxPromptCacheActive: self.runtimePromptCacheEnabled,
                    mlxQuantizedKVActive: self.runtimeQuantizedKVEnabled)
                self.history.removeAll()

                // Do not synchronously page the whole model during activation.
                // On larger Apple Silicon models this can keep the composer in
                // "Loading" for minutes (or appear hung while Metal faults in
                // every weight). MLX will page the weights on the first
                // generation; activation should become ready once the session
                // exists so the user can see and cancel a real first turn.
                Log.engine.info(
                    "Model session ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s — weights page on first generation; footprint \(MemoryAdvisor.processFootprint / 1_000_000) MB")
            } catch {
                self.session = nil
                self.loadedID = nil
                self.runtimePromptCacheEnabled = false
                self.runtimeQuantizedKVEnabled = false
                self.expectedAssistantEcho = nil
                self.statsState = EngineStats()
                self.removeCompatibilityDirectory()
                throw EngineError.loadFailed(String(describing: error))
            }
        }
    }

    public func unload() async {
        _ = try? await gate.run {
            self.session = nil
            self.loadedID = nil
            self.statsState = EngineStats()
            self.runtimePromptCacheEnabled = false
            self.runtimeQuantizedKVEnabled = false
            self.expectedAssistantEcho = nil
            self.removeCompatibilityDirectory()
        }
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    public func reset() async {
        _ = try? await gate.run {
            self.history.removeAll()
            self.expectedAssistantEcho = nil
            await self.session?.clear()
        }
    }

    public func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        let result: SemanticRebaseResult? = try? await gate.run {
            if self.history == turns {
                return SemanticRebaseResult(
                    installedHistory: true,
                    preservedCachePrefixTurns: turns.count)
            }

            // ChatSession does not expose a safe rewind-to-turn-boundary API.
            // Keep the rebuilt transcript canonical, but clear its opaque KV
            // state and let the next request replay correctly.
            self.history = turns
            self.expectedAssistantEcho = nil
            await self.session?.clear()
            return SemanticRebaseResult(installedHistory: true)
        }
        return result ?? .unsupported
    }

    public func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let generationTask = Task {
                defer { self.clearGenerationTask(id: id) }
                do {
                    try await self.gate.run {
                        guard let session = self.session else { throw EngineError.notLoaded }

                        self.history.append(contentsOf: turns)
                        let started = Date()
                        var emitted = 0

                        func consume(_ messages: [Chat.Message]) async throws
                            -> (tokens: Int, wireOutput: String, info: GenerateCompletionInfo?)
                        {
                            var tokens = 0
                            var wireOutput = ""
                            var completionInfo: GenerateCompletionInfo?
                            // streamDetails, NOT streamResponse: MLXLMCommon
                            // parses tool calls into generations whose chunk is
                            // nil. Re-serialize them for Beet Code's parser.
                            for try await generation in session.streamDetails(to: messages) {
                                if Task.isCancelled { throw CancellationError() }
                                switch generation {
                                case .chunk(let chunk):
                                    continuation.yield(chunk)
                                    wireOutput += chunk
                                    tokens += 1
                                    emitted += 1
                                case .toolCall(let call):
                                    let wire = MLXEngine.serializeToolCall(call)
                                    continuation.yield(wire)
                                    wireOutput += wire
                                    emitted += 1
                                case .info(let info):
                                    completionInfo = info
                                }
                            }
                            return (tokens, wireOutput, completionInfo)
                        }

                        let plan = MLXPromptCachePlanner.plan(
                            newTurns: turns,
                            expectedAssistantEcho: self.expectedAssistantEcho,
                            enabled: self.runtimePromptCacheEnabled)
                        let messages: [Chat.Message]
                        switch plan {
                        case .incremental(let incremental):
                            messages = MLXEngine.messages(from: incremental)
                        case .fullReplay:
                            await session.clear()
                            messages = MLXEngine.messages(from: self.history)
                        }

                        session.generateParameters = MLXEngine.makeParameters(
                            temperature: temperature ?? 0.6,
                            maxTokens: maxTokens,
                            quantizedKVEnabled: self.runtimeQuantizedKVEnabled)

                        let result: (
                            tokens: Int,
                            wireOutput: String,
                            info: GenerateCompletionInfo?
                        )
                        do {
                            result = try await consume(messages)
                        } catch {
                            let hadExperiment = self.runtimePromptCacheEnabled
                                || self.runtimeQuantizedKVEnabled
                            self.expectedAssistantEcho = nil
                            self.runtimePromptCacheEnabled = false
                            self.runtimeQuantizedKVEnabled = false
                            await session.clear()

                            // A pre-token experimental failure is safe to
                            // retry once from the canonical transcript. Once
                            // output was emitted, retrying would duplicate it.
                            guard hadExperiment, emitted == 0, !Task.isCancelled else {
                                self.statsState = EngineStats()
                                throw error
                            }
                            Log.engine.error(
                                "MLX experiment failed; retrying this model with full replay and standard KV")
                            session.generateParameters = MLXEngine.makeParameters(
                                temperature: temperature ?? 0.6,
                                maxTokens: maxTokens,
                                quantizedKVEnabled: false)
                            result = try await consume(MLXEngine.messages(from: self.history))
                        }

                        self.expectedAssistantEcho = self.runtimePromptCacheEnabled
                            ? MLXEngine.assistantEcho(from: result.wireOutput)
                            : nil

                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed > 0.2 {
                            let generatedTokens = result.info?.generationTokenCount
                                ?? result.tokens
                            let nextSerial = self.statsState.usageSerial + 1
                            self.statsState = EngineStats(
                                tokensPerSecond: result.info?.tokensPerSecond
                                    ?? Double(result.tokens) / elapsed,
                                generatedTokens: generatedTokens,
                                promptTokens: result.info?.promptTokenCount ?? 0,
                                usageSerial: nextSerial,
                                mlxPromptCacheActive: self.runtimePromptCacheEnabled,
                                mlxQuantizedKVActive: self.runtimeQuantizedKVEnabled)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.setGenerationTask(generationTask, id: id)
            continuation.onTermination = { _ in
                generationTask.cancel()
                self.clearGenerationTask(id: id)
            }
        }
    }

    public func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let saved = (try? await self.gate.run { () -> [ChatTurn] in
                    let old = self.history
                    self.history = []
                    self.expectedAssistantEcho = nil
                    await self.session?.clear()
                    return old
                }) ?? []
                do {
                    let inner = self.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                _ = try? await self.gate.run {
                    self.history = saved
                    // The isolated replay used the same ChatSession, so drop
                    // its cache. The next parent request safely full-replays.
                    self.expectedAssistantEcho = nil
                    await self.session?.clear()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancelGeneration() async {
        let task = withGenerationLock { generationTask }
        task?.cancel()
        await gate.cancelAll()
    }

    private func setGenerationTask(_ task: Task<Void, Never>, id: UUID) {
        generationLock.lock()
        generationTask = task
        generationID = id
        generationLock.unlock()
    }

    private func clearGenerationTask(id: UUID) {
        generationLock.lock()
        if generationID == id {
            generationTask = nil
            generationID = nil
        }
        generationLock.unlock()
    }

    private func withGenerationLock<T>(_ body: () -> T) -> T {
        generationLock.lock()
        defer { generationLock.unlock() }
        return body()
    }

    /// Frees Metal buffer cache once any in-flight generation finishes.
    public func clearCaches() async {
        _ = try? await gate.run {
            self.expectedAssistantEcho = nil
            await self.session?.clear()
        }
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    /// Drops only MLX's disposable allocation cache. The ChatSession and its
    /// KV state remain intact, so proactive memory control does not force a
    /// long prompt replay.
    public func trimTransientMemory() async {
        await gate.clearCacheWhenIdle {
            MLX.Memory.clearCache()
        }
    }

    private func removeCompatibilityDirectory() {
        guard let directory = compatibilityDirectory else { return }
        compatibilityDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Emergency unload path used by the memory-pressure coordinator. Returns
    /// true when a model was actually resident and got dumped.
    @discardableResult
    public func dumpIfResident() async -> Bool {
        let wasLoaded: String? = (try? await gate.run {
            let id = self.loadedID
            self.session = nil
            self.loadedID = nil
            self.statsState = EngineStats()
            self.runtimePromptCacheEnabled = false
            self.runtimeQuantizedKVEnabled = false
            self.expectedAssistantEcho = nil
            self.removeCompatibilityDirectory()
            return id
        }) ?? nil
        if wasLoaded != nil {
            await gate.clearCacheWhenIdle { MLX.Memory.clearCache() }
            Log.memory.warning("Resident model dumped by memory pressure")
        }
        return wasLoaded != nil
    }

    static func makeParameters(
        temperature: Double,
        maxTokens: Int?,
        quantizedKVEnabled: Bool = false
    ) -> GenerateParameters {
        var params = GenerateParameters()
        params.temperature = Float(temperature)
        // Qwen-recommended sampling for the local catalog: nucleus + top-k
        // with a light repetition penalty keeps small 4-bit models off the
        // rambling/repetition tails that plain temperature sampling invites
        // (defaults are topP 1.0 / topK 0 — unbounded).
        if temperature > 0 {
            params.topP = 0.95
            params.topK = 20
            params.repetitionPenalty = 1.05
        }
        params.maxTokens = maxTokens
        if quantizedKVEnabled {
            // 8-bit is the conservative experiment: roughly half the eligible
            // attention-cache storage of fp16, with a much smaller quality
            // risk than 4-bit. Keep the first 512 tokens unquantized.
            params.kvBits = 8
            params.kvGroupSize = 64
            params.quantizedKVStart = 512
        }
        return params
    }

    private static func messages(from turns: [ChatTurn]) -> [Chat.Message] {
        turns.map { turn in
            switch turn.role {
            case .system: Chat.Message.system(turn.content)
            case .user: Chat.Message.user(turn.content)
            case .assistant: Chat.Message.assistant(turn.content)
            case .tool: Chat.Message.tool(turn.content)
            }
        }
    }

    static func assistantEcho(from wireOutput: String) -> String {
        MLXPromptCachePlanner.canonical(
            ToolParser.strippingEmptyCallWrappers(
                from: PromptBuilder.cleaningGeneratedText(wireOutput)))
    }

    /// Re-serializes a parsed tool call into the `<tool_call>` wire text the
    /// agent's `ToolParser` recognizes (the inverse of parsing — see
    /// `ToolCallText`).
    private static func serializeToolCall(_ call: ToolCall) -> String {
        let object = call.function.arguments.mapValues { $0.anyValue }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let argumentsJSON = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCallText.serialize(name: call.function.name, argumentsJSON: argumentsJSON)
    }
}

/// Adapts third-party Qwen3.5 text conversions that retain the unified
/// `language_model.*` namespace. The upstream text loader expects bare
/// `model.*`/`lm_head.*` keys and otherwise reports apparently missing layers.
enum Qwen35CheckpointCompatibility {
    static let modelType = "beetcode_qwen3_5_text_tied_unified"

    static func makeLoadDirectoryIfNeeded(for source: URL) throws -> URL? {
        let fileManager = FileManager.default
        let configURL = source.appendingPathComponent("config.json")
        let indexURL = source.appendingPathComponent("model.safetensors.index.json")

        guard let configData = try? Data(contentsOf: configURL),
              var config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              config["model_type"] as? String == "qwen3_5_text",
              config["tie_word_embeddings"] as? Bool == false,
              let indexData = try? Data(contentsOf: indexURL),
              let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let weightMap = index["weight_map"] as? [String: Any]
        else { return nil }

        let keys = weightMap.keys
        let hasUnifiedEmbedding = keys.contains {
            $0.hasPrefix("language_model.model.embed_tokens.")
        }
        let hasOutputHead = keys.contains {
            $0.hasPrefix("lm_head.") || $0.contains(".lm_head.")
        }
        guard hasUnifiedEmbedding else { return nil }

        let loadDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("beetcode-qwen35-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: loadDirectory, withIntermediateDirectories: true)

        do {
            for item in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            where item.lastPathComponent != "config.json" {
                try fileManager.createSymbolicLink(
                    at: loadDirectory.appendingPathComponent(item.lastPathComponent),
                    withDestinationURL: item)
            }

            config["model_type"] = modelType
            // A few community conversions omit lm_head while leaving the flag
            // false; those truly need tied logits. Preserve the separate head
            // whenever it is present, as in the 9B abliterated checkpoint.
            if !hasOutputHead {
                config["tie_word_embeddings"] = true
            }
            let compatibleConfig = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys])
            try compatibleConfig.write(
                to: loadDirectory.appendingPathComponent("config.json"),
                options: .atomic)
            return loadDirectory
        } catch {
            try? fileManager.removeItem(at: loadDirectory)
            throw error
        }
    }

    static func makeModel(_ data: Data) throws -> LanguageModel {
        let configuration = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data)
        return UnifiedTiedQwen35TextModel(configuration)
    }
}

/// Wraps the upstream Qwen3.5 text model so its module paths match unified
/// checkpoints. Quantized weights remain memory-mapped; this adapter only
/// changes their logical names and does not duplicate the 4.7 GB model file.
private final class UnifiedTiedQwen35TextModel: Module, LLMModel {
    @ModuleInfo(key: "base") private var base: Qwen35TextModel

    init(_ configuration: Qwen35TextConfiguration) {
        _base.wrappedValue = Qwen35TextModel(configuration)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        base(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        base.newCache(parameters: parameters)
    }

    var loraLayers: [Module] { base.loraLayers }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var normalized = [String: MLXArray]()
        normalized.reserveCapacity(weights.count)

        for (originalKey, value) in weights {
            if originalKey.hasPrefix("vision_tower.") || originalKey.hasPrefix("model.visual.") {
                continue
            }

            let key: String
            if originalKey.hasPrefix("language_model.") {
                key = String(originalKey.dropFirst("language_model.".count))
            } else if originalKey.hasPrefix("model.language_model.") {
                key = "model." + String(originalKey.dropFirst("model.language_model.".count))
            } else {
                key = originalKey
            }
            normalized[key] = value
        }

        let sanitized = base.sanitize(weights: normalized)
        return Dictionary(uniqueKeysWithValues: sanitized.map { ("base.\($0.key)", $0.value) })
    }
}
