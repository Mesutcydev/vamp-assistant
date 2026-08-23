import Darwin
import Foundation

/// GGUF engine: runs llama.cpp's `llama-server` as a localhost child process
/// against the model's `.gguf` file and streams through the same
/// OpenAI-compatible client used for BYOK servers. This gives Beet Code the
/// full GGUF quantization universe (Q2–Q8, every architecture llama.cpp
/// supports) without vendoring the C++ runtime — llama.cpp already has
/// first-class Apple Silicon Metal support.
///
/// Lifecycle mirrors the MLX engine: admission goes through `MemoryAdvisor`,
/// generation is serialized on the pool's shared `GenerationGate`, and unload
/// terminates the server process.
final class GGUFEngine: LLMEngine, NativeToolConfigurable, @unchecked Sendable {

    enum GGUFError: Error, LocalizedError, Equatable {
        case noGGUFFile
        case serverBinaryMissing(String)
        case serverFailedToStart(String)
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .noGGUFFile:
                return "No .gguf weight file found in the model directory."
            case .serverBinaryMissing(let hint):
                return hint
            case .serverFailedToStart(let detail):
                return "llama-server failed to start: \(detail)"
            case .notLoaded:
                return "No GGUF model is loaded."
            }
        }
    }

    /// Pure decisions — deterministic and unit-testable.
    enum Planner {

        struct DFlashDraft: Sendable, Equatable {
            let repository: String
            let fileName: String
            let sourceURL: URL
            let diskBytes: Int64
            let maxDraftTokens: Int
        }

        struct PerformanceProfile: Sendable, Equatable {
            let batchSize: Int
            let microBatchSize: Int

            /// Measured on the base M4 / 16 GB Qwen3.8 9B Q5 workload:
            /// 193.8 prompt tok/s versus 183.4 at llama.cpp's 2048/512
            /// defaults, while also reducing transient prefill memory.
            static let m4Base16GB = PerformanceProfile(
                batchSize: 1_024,
                microBatchSize: 256)

            static func recommended(for device: DeviceProfile) -> PerformanceProfile? {
                guard device.generationNumber == 4,
                      device.variant == .base,
                      device.memoryGB <= 16
                else { return nil }
                return .m4Base16GB
            }
        }

        enum Speculation: Sendable, Equatable {
            case none
            case mtp
            case dflash(modelPath: String, maxDraftTokens: Int)
            case ngram

            var acceleration: EngineAcceleration {
                switch self {
                case .none: .standard
                case .mtp: .mtp
                case .dflash: .dflash
                case .ngram: .ngram
                }
            }
        }

        /// Choose the stable speculative path after any explicit DFlash
        /// attempt. ngram-mod is an explicit, reversible preference and must
        /// not be silently shadowed by an embedded MTP head. On Apple
        /// silicon, current llama.cpp Metal builds can spend as much work
        /// evaluating the MTP head as they save by accepting its drafts, so
        /// ordinary decoding remains the stable default there. Other
        /// platforms keep using a model-provided MTP head automatically.
        static func fallbackSpeculation(
            metadata: GGUFMetadata?,
            experimentalNGramEnabled: Bool,
            isAppleSilicon: Bool
        ) -> Speculation {
            if experimentalNGramEnabled { return .ngram }
            if metadata?.supportsDraftMTP == true, !isAppleSilicon { return .mtp }
            return .none
        }

        /// llama.cpp's current OpenAI-compatible request contract maps
        /// `reasoning_effort: none` to a hybrid model's non-thinking chat
        /// template. Chat-only turns use that fast path by default so a tiny
        /// answer cannot spend its entire output allowance in hidden
        /// reasoning. A user can still ask explicitly for deep reasoning;
        /// project-agent turns retain the model's automatic reasoning mode.
        static func reasoningEffort(turns: [ChatTurn], maxTokens: Int?) -> String? {
            if let maxTokens, maxTokens <= 512 { return "none" }
            guard let system = turns.first(where: { $0.role == .system })?.content,
                  system.localizedCaseInsensitiveContains("chat-only mode")
            else { return nil }
            let request = turns.last(where: { $0.role == .user })?.content ?? ""
            return requestsDeepReasoning(request) ? nil : "none"
        }

        private static func requestsDeepReasoning(_ request: String) -> Bool {
            let normalized = request.lowercased()
            return [
                "think deeply", "reason carefully", "analyze deeply",
                "step by step", "extended reasoning", "show your reasoning",
                "take your time and think", "work through the proof",
            ].contains(where: normalized.contains)
        }

        /// The weight file to serve: the LARGEST `.gguf` in the directory
        /// (multi-file splits are rare; the biggest shard is the real model).
        static func selectGGUF(named fileNames: [String]) -> String? {
            let candidates = fileNames.filter { $0.lowercased().hasSuffix(".gguf") }
            return candidates.max { a, b in
                if a.count != b.count { return a.count < b.count }
                return quantizationLevel(a) < quantizationLevel(b)
            }
        }

        /// Numeric -q<digits> marker ("model-q8.gguf" -> 8); 0 when absent.
        private static func quantizationLevel(_ name: String) -> Int {
            let lower = name.lowercased()
            guard let dot = lower.range(of: ".gguf") else { return 0 }
            let stem = String(lower[lower.startIndex..<dot.lowerBound])
            guard let qRange = stem.range(of: "-q") else { return 0 }
            let rest = stem[qRange.upperBound...]
            let digits = rest.prefix(while: { $0.isNumber })
            guard digits.count > 0 else { return 0 }
            return Int(digits) ?? 0
        }

        /// Server launch arguments: loopback-only, no web UI, GPU-offloaded.
        /// Speculation is explicit and mutually exclusive. DFlash takes a
        /// separate 4-bit draft checkpoint; MTP uses next-token tensors
        /// embedded in the target GGUF. The ordinary launch remains the
        /// default and contains no experimental flags.
        static func serverArguments(modelPath: String, port: Int, contextSize: Int = defaultContextSize,
                                    speculation: Speculation = .none,
                                    performanceProfile: PerformanceProfile? = nil) -> [String] {
            var args = [
                "--model", modelPath,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--ctx-size", String(clampContextSize(contextSize)),
                // Beet Code serializes generation for one local user. One
                // slot avoids reserving four independent KV contexts while
                // keeping the full requested context available to the chat.
                "--parallel", "1",
                // Full conversation replay has a stable prefix. Make the
                // server's exact-prefix KV reuse contract explicit.
                "--cache-prompt",
                // llama.cpp's Jinja chat templates are the path that accepts
                // OpenAI-compatible native tool definitions for Qwen/Llama.
                // The request layer still retries without tools when an older
                // embedded server rejects them.
                "--jinja",
                "--n-gpu-layers", "99",
                "--alias", "beetcode",
                "--no-webui",
            ]
            if let performanceProfile {
                args += [
                    "--batch-size", String(performanceProfile.batchSize),
                    "--ubatch-size", String(performanceProfile.microBatchSize),
                ]
            }
            switch speculation {
            case .none:
                break
            case .mtp:
                // Deeper MTP drafts lose acceptance quickly for code.
                args += ["--spec-type", "draft-mtp", "--spec-draft-n-max", "2"]
            case .dflash(let draftPath, let maxDraftTokens):
                args += [
                    "--spec-draft-model", draftPath,
                    "--spec-type", "draft-dflash",
                    "--spec-draft-n-max", String(maxDraftTokens),
                    "--flash-attn", "on",
                ]
            case .ngram:
                // Model-free and constant-memory (~16 MB). Upstream defaults
                // deliberately require long matches to protect quality.
                args += ["--spec-type", "ngram-mod"]
            }
            return args
        }

        /// The first experimental pairing is intentionally narrow. The
        /// draft was trained for Qwen3.5 9B; using it with a different size
        /// can make speculation slower or invalid. Imported derivatives are
        /// accepted only when the GGUF id/name still identifies both family
        /// and parameter size.
        static func dflashDraft(modelID: String, metadata: GGUFMetadata?) -> DFlashDraft? {
            let identity = [modelID, metadata?.modelName, metadata?.architecture]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            guard identity.contains("qwen35"), identity.contains("9b") else { return nil }
            let repository = "Anbeeld/Qwen3.5-9B-DFlash-GGUF"
            let fileName = "qwen35-9b-dflash-Q4_K_M.gguf"
            return DFlashDraft(
                repository: repository,
                fileName: fileName,
                sourceURL: URL(
                    string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)")!,
                diskBytes: 765_959_872,
                // Quantized verification widths above five currently lose
                // efficiency on Apple silicon; four is the conservative
                // coding/agent default.
                maxDraftTokens: 4)
        }

        /// Context the server gets when the catalog says nothing.
        static let defaultContextSize = 8_192
        /// Sanity ceiling for any launch. The RAM-aware choice below is the
        /// real limit; this only bounds absurd catalog values (attention cost
        /// also grows quadratically past a few hundred K).
        static let maxContextSize = 262_144
        static let minContextSize = 4_096
        /// Conservative cap when the GGUF header can't be sniffed: KV cache
        /// scales linearly with ctx and MemoryAdvisor admission counts only
        /// the weights, so unknown models stay in proven-safe territory.
        static let fallbackContextSize = 32_768

        static func clampContextSize(_ requested: Int) -> Int {
            min(max(requested, minContextSize), maxContextSize)
        }

        /// KV cache bytes per token (f16 K+V): 2 caches × layers × kv-heads ×
        /// head-dim × 2 bytes. Needs the transformer dims from the GGUF
        /// header; MHA models (no kv-head count) use the full head count.
        static func kvBytesPerToken(metadata: GGUFMetadata) -> Int? {
            guard let layers = metadata.blockCount,
                  let embedding = metadata.embeddingLength,
                  let heads = metadata.attentionHeadCount, heads > 0
            else { return nil }
            let kvHeads = metadata.attentionHeadCountKV ?? heads
            let headDim = embedding / heads
            guard kvHeads > 0, headDim > 0 else { return nil }
            let (value, overflow) = (2 * layers * kvHeads).multipliedReportingOverflow(by: headDim * 2)
            return overflow ? nil : value
        }

        /// Largest context that fits the RAM budget honestly: the weights'
        /// projected footprint is spent first, what remains buys KV tokens.
        /// `availableBudget` is MemoryAdvisor's usable-minus-footprint figure.
        /// The floor is `minContextSize` — the load was already admitted on
        /// the weights, and 4 K of KV is small next to any 9 B file.
        static func chooseContextSize(
            requested: Int,
            kvBytesPerToken: Int?,
            projectedWeights: UInt64,
            availableBudget: UInt64
        ) -> Int {
            let requestedClamped = clampContextSize(requested)
            guard let kvPerToken = kvBytesPerToken, kvPerToken > 0 else {
                return min(requestedClamped, fallbackContextSize)
            }
            let kvBudget = availableBudget > projectedWeights ? availableBudget - projectedWeights : 0
            let affordable = kvBudget / UInt64(kvPerToken)
            let capped = min(UInt64(requestedClamped), affordable)
            return max(Int(capped), minContextSize)
        }

        /// Watchdog script: kill the server when the APP dies, even on a
        /// hard crash (SIGABRT skips applicationWillTerminate). macOS has no
        /// parent-death signal, so a tiny /bin/sh loop polls both PIDs; it
        /// exits as soon as either is gone, killing the server if the parent
        /// went first. Pure function for tests.
        static func janitorCommand(serverPID: Int32, parentPID: Int32) -> [String] {
            [
                "-c",
                """
                while kill -0 "$1" 2>/dev/null; do
                  kill -0 "$2" 2>/dev/null || { kill "$1" 2>/dev/null; break; }
                  sleep 3
                done
                """,
                "beetcode-gguf-janitor", String(serverPID), String(parentPID),
            ]
        }

        /// True when the health response body indicates the model is ready.
        static func isHealthy(responseBody: String) -> Bool {
            responseBody.contains("\"data\"") || responseBody.contains("beetcode")
        }
    }

    // MARK: State

    private let lock = NSLock()
    private var process: Process?
    /// Crash-safety watchdog for `process` (see Planner.janitorCommand).
    private var janitor: Process?
    private var port: Int = 0
    private var loadedID: String?
    /// The ctx-size the running server was actually launched with (RAM-fitted
    /// by the Planner — often smaller than the catalog window). The agent
    /// loop compacts against this, never the catalog number.
    private var launchedContextSize: Int?
    private var statsState = EngineStats()
    /// The active HTTP relay task. Retaining it makes Stop cancel the request
    /// instead of waiting for llama-server to finish the full response.
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?
    /// Compact task-specific catalog supplied by AgentLoop. llama-server can
    /// apply the model's native tool template instead of relying only on the
    /// text fence described in the system prompt.
    private var nativeTools: [NativeToolSpec] = []
    /// Stateless replay buffer — identical semantics to RemoteLLMEngine:
    /// llama-server slots are not guaranteed across requests, so every call
    /// sends the full conversation.
    private var accumulated: [ChatTurn] = []

    private let experimentalDFlashEnabled: Bool
    private let experimentalNGramEnabled: Bool

    init(
        experimentalDFlashEnabled: Bool = false,
        experimentalNGramEnabled: Bool = false
    ) {
        self.experimentalDFlashEnabled = experimentalDFlashEnabled
        self.experimentalNGramEnabled = experimentalNGramEnabled
    }

    var loadedModelID: String? {
        get async { withLock { loadedID } }
    }

    var effectiveContextWindow: Int? {
        get async { withLock { launchedContextSize } }
    }

    var stats: EngineStats {
        get async { withLock { statsState } }
    }

    var externalResidentMemoryBytes: UInt64? {
        get async {
            let pid = withLock { process?.processIdentifier }
            guard let pid else { return nil }
            return MemoryAdvisor.processFootprint(pid: pid)
        }
    }

    func configureNativeTools(_ tools: [NativeToolSpec]) {
        withLock { nativeTools = tools }
    }

    // MARK: Lifecycle

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: nil)
    }

    /// `contextSize` comes from the catalog entry; the Planner fits it to the
    /// RAM budget (KV cache) before launch. nil uses the 8 K default.
    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        // Defensive: loading while resident must replace the old server, not
        // orphan it (the pool normally prevents this; the unpooled path and
        // tests don't).
        if withLock({ process != nil }) {
            await unload()
        }
        // Same admission authority as every other engine: the GGUF weights
        // inflate the child's footprint just like MLX's mmap does.
        try MemoryAdvisor.admitLoad(diskBytes: diskBytes)

        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let ggufName = Planner.selectGGUF(named: fileNames) else {
            throw GGUFError.noGGUFFile
        }
        let modelPath = directory.appendingPathComponent(ggufName).path
        let binary = try Self.resolveServerBinary()

        // RAM-honest context sizing: sniff the transformer dims from the GGUF
        // header and buy as many KV tokens as the budget left over after the
        // weights affords. Unsniffable headers keep the conservative 32 K cap.
        let sniffed = GGUFMetadata.read(from: URL(fileURLWithPath: modelPath))
        let candidateDraft = experimentalDFlashEnabled
            ? Planner.dflashDraft(modelID: modelID, metadata: sniffed)
            : nil
        let dflashDraft: Planner.DFlashDraft?
        if let candidateDraft,
           (try? MemoryAdvisor.admitLoad(
                diskBytes: diskBytes + candidateDraft.diskBytes)) != nil {
            dflashDraft = candidateDraft
        } else {
            dflashDraft = nil
            if candidateDraft != nil {
                Log.engine.warning(
                    "DFlash skipped: target plus draft exceeds the current safe memory budget")
            }
        }
        let reservedDraftBytes = dflashDraft.map {
            MemoryAdvisor.projectedFootprint(diskBytes: $0.diskBytes)
        } ?? 0
        let contextBudget = MemoryAdvisor.availableBudget > reservedDraftBytes
            ? MemoryAdvisor.availableBudget - reservedDraftBytes
            : 0
        let chosenContext = Planner.chooseContextSize(
            requested: contextSize ?? Planner.defaultContextSize,
            kvBytesPerToken: sniffed.flatMap(Planner.kvBytesPerToken),
            projectedWeights: MemoryAdvisor.projectedFootprint(diskBytes: diskBytes),
            availableBudget: contextBudget)

        // Experimental DFlash gets the first attempt only for the exact
        // compatible family/size and when its additional working set fits.
        // It may download the public 4-bit draft on first use, hence the
        // longer health timeout. Any failure falls back to existing MTP and
        // finally ordinary decoding, so enabling the experiment cannot make
        // a previously working GGUF model unloadable.
        let fallbackSpeculation = Planner.fallbackSpeculation(
            metadata: sniffed,
            experimentalNGramEnabled: experimentalNGramEnabled,
            isAppleSilicon: DeviceProfile.current().isAppleSilicon)
        var usedSpeculation: Planner.Speculation = .none
        var attempt: (child: Process, watchdog: Process, port: Int)?
        if let dflashDraft {
            do {
                let draftPath = try await Self.cachedDFlashDraftPath(for: dflashDraft)
                let mode = Planner.Speculation.dflash(
                    modelPath: draftPath,
                    maxDraftTokens: dflashDraft.maxDraftTokens)
                attempt = try await launchServer(
                    binary: binary, modelPath: modelPath,
                    contextSize: chosenContext, speculation: mode,
                    timeout: 180)
                if attempt != nil {
                    usedSpeculation = mode
                } else {
                    Log.engine.warning(
                        "DFlash launch failed; retrying with a stable decoding path")
                }
            } catch {
                Log.engine.warning(
                    "DFlash draft unavailable (\(error.localizedDescription, privacy: .public)); retrying with a stable decoding path")
            }
        }
        if attempt == nil, fallbackSpeculation != .none {
            let mode = fallbackSpeculation
            attempt = try await launchServer(
                binary: binary, modelPath: modelPath,
                contextSize: chosenContext, speculation: mode)
            if attempt != nil {
                usedSpeculation = mode
            } else {
                Log.engine.warning(
                    "llama-server rejected the selected acceleration; retrying standard decoding")
            }
        }
        if attempt == nil {
            usedSpeculation = .none
            attempt = try await launchServer(
                binary: binary, modelPath: modelPath,
                contextSize: chosenContext, speculation: .none)
        }
        guard let (child, watchdog, serverPort) = attempt else {
            throw GGUFError.serverFailedToStart(
                "no response from llama-server after experimental and stable launch attempts")
        }

        withLock {
            self.process = child
            self.janitor = watchdog
            self.port = serverPort
            self.loadedID = modelID
            self.launchedContextSize = chosenContext
            self.statsState = EngineStats(acceleration: usedSpeculation.acceleration)
            self.accumulated.removeAll()
        }
        child.terminationHandler = { [weak self] _ in
            ChildProcessRegistry.unregister(child)
            guard let self else { return }
            self.withLock {
                self.process = nil
                self.loadedID = nil
            }
        }
        Log.engine.info("GGUF server ready: \(modelID, privacy: .public) on port \(serverPort)")
    }

    func unload() async {
        let (child, watchdog, generation) = withLock { () -> (Process?, Process?, Task<Void, Never>?) in
            let p = process
            let j = janitor
            let generation = generationTask
            process = nil
            janitor = nil
            generationTask = nil
            generationID = nil
            port = 0
            loadedID = nil
            launchedContextSize = nil
            statsState = EngineStats()
            accumulated.removeAll()
            return (p, j, generation)
        }
        generation?.cancel()
        // The watchdog exits on its own once the server is gone; terminate it
        // explicitly so unload never waits on its 3 s poll.
        if let watchdog, watchdog.isRunning { watchdog.terminate() }
        guard let child, child.isRunning else { return }
        child.terminate()
        // Graceful → forced: never leak a model server.
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
    }

    func reset() async {
        withLock { accumulated.removeAll() }
    }

    func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        let preserved = withLock { () -> Int in
            let count = SemanticContextPlanner.commonPrefixTurnCount(
                accumulated, turns)
            accumulated = turns
            return count
        }
        // Deliberately do not reset or restart llama-server. Its single slot
        // retains token-granular KV pages, and --cache-prompt reuses the exact
        // prefix through the last unchanged semantic turn.
        return SemanticRebaseResult(
            installedHistory: true,
            preservedCachePrefixTurns: preserved)
    }

    // MARK: Generation

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let allTurns = withLock { () -> [ChatTurn] in
            accumulated.append(contentsOf: turns)
            return accumulated
        }
        let baseURL = withLock { URL(string: "http://127.0.0.1:\(port)/v1")! }
        let usageBox = UsageBox()
        let tools = withLock { nativeTools }
        let onUsage: @Sendable (RemoteLLMClient.UsageInfo) -> Void = { [weak self] usage in
            usageBox.store(usage)
            self?.noteUsage(usage, startedAt: usageBox.started)
        }
        let inner = RemoteLLMClient.streamOpenAICompatible(
            provider: .custom,
            baseURL: baseURL,
            apiKey: "",
            model: "beetcode",
            turns: allTurns,
            temperature: temperature ?? 0.6,
            maxTokens: maxTokens,
            reasoningEffort: Planner.reasoningEffort(
                turns: allTurns, maxTokens: maxTokens),
            cachePrompt: true,
            tools: tools,
            onUsage: onUsage)

        // Relay while measuring throughput (same stats contract as the other
        // engines).
        return AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task { [weak self] in
                defer { self?.clearGenerationTask(id: id) }
                var tokens = 0
                let started = Date()
                do {
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                        tokens += 1
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0.2, usageBox.load() == nil {
                        // NSLock lives inside the synchronous withLock
                        // helper — never raw lock/unlock in async contexts.
                        if let self {
                            self.withLock {
                                let nextSerial = self.statsState.usageSerial + 1
                                self.statsState = EngineStats(
                                    tokensPerSecond: Double(tokens) / elapsed,
                                    generatedTokens: tokens,
                                    usageSerial: nextSerial,
                                    acceleration: self.statsState.acceleration)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            setGenerationTask(task, id: id)
            continuation.onTermination = { _ in
                task.cancel()
                self.clearGenerationTask(id: id)
            }
        }
    }

    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let saved = self.withLock { () -> [ChatTurn] in
                    let old = self.accumulated
                    self.accumulated = []
                    return old
                }
                defer { self.withLock { self.accumulated = saved } }
                let inner = self.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
                do {
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelGeneration() async {
        let task = withLock { generationTask }
        task?.cancel()
    }

    /// llama-server supplies exact usage in its final SSE frame. Prefer that
    /// over transport-chunk counting so the status bar and per-answer token
    /// details remain truthful even when the network coalesces many tokens
    /// into one chunk.
    private func noteUsage(
        _ usage: RemoteLLMClient.UsageInfo,
        startedAt: Date
    ) {
        let completion = usage.completionTokens ?? 0
        let prompt = usage.promptTokens ?? 0
        guard completion > 0 || prompt > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        withLock {
            let nextSerial = statsState.usageSerial + 1
            statsState = EngineStats(
                tokensPerSecond: usage.tokensPerSecond
                    ?? (elapsed > 0 && completion > 0
                        ? Double(completion) / elapsed
                        : nil),
                generatedTokens: completion,
                promptTokens: prompt,
                usageSerial: nextSerial,
                acceleration: statsState.acceleration)
        }
    }

    private final class UsageBox: @unchecked Sendable {
        let started = Date()
        private let lock = NSLock()
        private var last: RemoteLLMClient.UsageInfo?

        func store(_ usage: RemoteLLMClient.UsageInfo) {
            lock.lock()
            last = usage
            lock.unlock()
        }

        func load() -> RemoteLLMClient.UsageInfo? {
            lock.lock()
            defer { lock.unlock() }
            return last
        }
    }

    private func setGenerationTask(_ task: Task<Void, Never>, id: UUID) {
        withLock {
            generationTask = task
            generationID = id
        }
    }

    private func clearGenerationTask(id: UUID) {
        withLock {
            if generationID == id {
                generationTask = nil
                generationID = nil
            }
        }
    }

    @discardableResult
    func dumpIfResident() async -> Bool {
        let wasLoaded = withLock { loadedID != nil }
        if wasLoaded {
            await unload()
            Log.memory.warning("GGUF model dumped by memory pressure")
        }
        return wasLoaded
    }

    // MARK: Helpers

    /// Resolve the experimental draft into Beet Code's managed model cache.
    /// Some llama.cpp builds leave their HF draft shortcut with an empty
    /// path, so the app owns this one-file download and launches the server
    /// with an explicit local checkpoint. Exact sizing rejects partial files.
    private static func cachedDFlashDraftPath(for draft: Planner.DFlashDraft) async throws -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support
            .appendingPathComponent("BeetCode/Models/.DFlash", isDirectory: true)
        let destination = directory.appendingPathComponent(draft.fileName)
        if fileSize(at: destination) == draft.diskBytes {
            return destination.path
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1_200
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: draft.sourceURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        guard fileSize(at: temporary) == draft.diskBytes else {
            throw GGUFError.serverFailedToStart(
                "the downloaded DFlash checkpoint was incomplete")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination.path
    }

    private static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    /// Spawns llama-server (plus its crash watchdog) and waits for the health
    /// endpoint. Returns nil when the server never answers — the caller may
    /// retry with different arguments. Spawn failures throw immediately (no
    /// retry would fix a bad binary path).
    private func launchServer(
        binary: URL, modelPath: String,
        contextSize: Int, speculation: Planner.Speculation,
        timeout: TimeInterval = 120
    ) async throws -> (child: Process, watchdog: Process, port: Int)? {
        let serverPort = Self.freePort()
        let child = Process()
        child.executableURL = binary
        child.arguments = Planner.serverArguments(
            modelPath: modelPath, port: serverPort,
            contextSize: contextSize, speculation: speculation,
            performanceProfile: Planner.PerformanceProfile.recommended(
                for: DeviceProfile.current()))
        child.environment = ShellRunner.sanitizedEnvironment()
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw GGUFError.serverFailedToStart(error.localizedDescription)
        }
        // Quit-safety net: if the app exits without an unload (window close,
        // ⌘Q with a model resident), the app delegate SIGTERMs registered
        // children — otherwise a multi-GB llama-server outlives the app.
        ChildProcessRegistry.register(child)
        // Crash-safety net: SIGABRT skips willTerminate, so a watchdog shell
        // kills the server if the app process disappears (see Planner).
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = Planner.janitorCommand(
            serverPID: child.processIdentifier,
            parentPID: ProcessInfo.processInfo.processIdentifier)
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()

        // Wait for the HTTP health endpoint (model page-in can take a while).
        let healthy = await waitForHealthy(port: serverPort, process: child, timeout: timeout)
        guard healthy else {
            child.terminate()
            watchdog.terminate()
            ChildProcessRegistry.unregister(child)
            return nil
        }
        return (child, watchdog, serverPort)
    }

    /// Polls the server's model endpoint until it answers or the deadline /
    /// process death arrives.
    private func waitForHealthy(port: Int, process: Process, timeout: TimeInterval) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let session = URLSession(configuration: .ephemeral)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if let (_, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                session.finishTasksAndInvalidate()
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        session.finishTasksAndInvalidate()
        return false
    }

    /// Locates `llama-server`: PATH first (Homebrew installs link it), then
    /// the canonical Homebrew prefix. Absence is reported with install
    /// guidance instead of a cryptic spawn error.
    nonisolated static func resolveServerBinary() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("llama-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")
        if FileManager.default.isExecutableFile(atPath: homebrew.path) {
            return homebrew
        }
        throw GGUFError.serverBinaryMissing(
            "llama-server not found. Install llama.cpp (brew install llama.cpp) to run GGUF models.")
    }

    /// An ephemeral loopback port: bind port 0, read the assignment, close.
    nonisolated static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8901 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 8901 }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard nameResult == 0 else { return 8901 }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
