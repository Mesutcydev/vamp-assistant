import CryptoKit
import Foundation

/// Keeps optional MLX runtimes outside the app's MLX ABI. Both serve through
/// the existing OpenAI transport, but remain local pool residents: load,
/// memory admission, cancellation, eviction, and Unload still apply.
final class ManagedMLXEngine: LLMEngine, NativeToolConfigurable, @unchecked Sendable {
    static let bonsaiModelID = "Ternary-Bonsai-2-27B-MLXFast"

    private let lock = NSLock()
    private let fallback: any LLMEngine
    private let runtimeRoot: URL
    private let resolveRuntime: @Sendable (ManagedInferenceRuntime.Kind, String) -> ManagedInferenceRuntime?
    private var delegate: (any LLMEngine)?
    private var child: Process?
    private var watchdog: Process?
    private var memoryMonitor: Task<Void, Never>?
    private var memoryFailure: String?
    private var modelID: String?
    private var vision = false
    private var contextWindow: Int?
    private var backendLabel: String?
    private var nativeTools: [NativeToolSpec] = []

    init(fallback: any LLMEngine, runtimeRoot: URL = ManagedInferenceRuntime.root,
         resolveRuntime: @escaping @Sendable (ManagedInferenceRuntime.Kind, String) -> ManagedInferenceRuntime? = {
             ManagedInferenceRuntime.resolve(kind: $0, modelID: $1)
         }) {
        self.fallback = fallback
        self.runtimeRoot = runtimeRoot
        self.resolveRuntime = resolveRuntime
    }

    var loadedModelID: String? { get async { lock.withLock { child.map { $0.isRunning } == false ? nil : modelID } } }
    var effectiveContextWindow: Int? { get async { lock.withLock { contextWindow } } }
    var supportsImageInput: Bool { get async { lock.withLock { vision && child.map { $0.isRunning } != false } } }
    var externalResidentMemoryBytes: UInt64? {
        get async {
            guard let pid = lock.withLock({ child?.processIdentifier }) else { return nil }
            return MemoryAdvisor.processFootprint(pid: pid)
        }
    }
    var stats: EngineStats {
        get async {
            guard let engine = lock.withLock({ delegate }) else { return EngineStats() }
            var stats = await engine.stats
            stats.runtimeName = lock.withLock { backendLabel }
            return stats
        }
    }

    func configureNativeTools(_ tools: [NativeToolSpec]) {
        let engine = lock.withLock { nativeTools = tools; return delegate }
        (engine as? any NativeToolConfigurable)?.configureNativeTools(tools)
    }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: nil)
    }

    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        await unload()
        let kind: ManagedInferenceRuntime.Kind = modelID == Self.bonsaiModelID ? .mlxfast : .omlx
        if let runtime = resolveRuntime(kind, modelID) {
            do {
                try await loadManaged(runtime, directory: directory, modelID: modelID, contextSize: contextSize)
                return
            } catch {
                await unload()
                try Task.checkCancellation()
                // The Bonsai pack needs its fork's ternary kernels. Sending it
                // to the app's ordinary MLX library is not a valid fallback.
                if kind == .mlxfast { throw error }
                Log.engine.warning("oMLX could not load; retrying built-in MLX: \(error.localizedDescription, privacy: .public)")
            }
        } else if kind == .mlxfast {
            guard ManagedInferenceRuntime.Kind.mlxfast.supportedOnThisMac else {
                throw EngineError.loadFailed("The MLXFast Bonsai experiment exceeds the safe memory budget on this Mac. It currently requires 24 GB RAM. Use the existing Bonsai GGUF model here.")
            }
            throw EngineError.loadFailed("Enable the installed MLXFast Bonsai runtime in Settings → Agent. This checkpoint requires its native Swift engine.")
        }
        try await fallback.load(directory: directory, modelID: modelID, diskBytes: diskBytes, contextSize: contextSize)
        let canSee = await fallback.supportsImageInput
        let context = await fallback.effectiveContextWindow
        lock.withLock {
            delegate = fallback; self.modelID = modelID; vision = canSee; contextWindow = context
            (fallback as? any NativeToolConfigurable)?.configureNativeTools(nativeTools)
        }
    }

    private func loadManaged(_ runtime: ManagedInferenceRuntime, directory: URL, modelID: String, contextSize: Int?) async throws {
        guard let binary = runtime.executableURL(root: runtimeRoot) else { throw EngineError.loadFailed("The optional runtime is missing. Reinstall it before loading this model.") }
        let port = GGUFEngine.freePort()
        let key = UUID().uuidString
        let context = min(contextSize ?? 4096, 4096)
        let stateKey = SHA256.hash(data: Data((modelID + directory.resolvingSymlinksInPath().path).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let state = runtimeRoot.appendingPathComponent("State/\(runtime.kind.rawValue)/\(stateKey)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let arguments: [String]
        let servedModel: String
        if runtime.kind == .omlx {
            let settingsURL = state.appendingPathComponent("model_settings.json")
            // This state directory belongs to Vamp. Refresh the limit when
            // the user reloads with a different context budget.
            let defaults: [String: Any] = ["models": ["model": [
                "enable_thinking": false, "max_context_window": context, "max_tokens": 512,
            ]]]
            try JSONSerialization.data(withJSONObject: defaults).write(to: settingsURL, options: .atomic)
            let models = state.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            let link = models.appendingPathComponent("model")
            if FileManager.default.fileExists(atPath: link.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            servedModel = "model"
            arguments = ["serve", "--model-dir", models.path, "--host", "127.0.0.1", "--port", String(port),
                         "--base-path", state.path, "--no-hf-cache", "--api-key", key,
                         "--max-concurrent-requests", "1", "--memory-guard", "balanced",
                         "--paged-ssd-cache-max-size", "1GB", "--hot-cache-max-size", "256MB"]
        } else {
            servedModel = directory.path
            arguments = ["--model", directory.path, "--host", "127.0.0.1", "--port", String(port),
                         "--tool-call-parser", "auto", "--reasoning-parser", "qwen3"]
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        var environment = ShellRunner.sanitizedEnvironment()
        environment["OMLX_DISCOVERY"] = "0"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        ChildProcessRegistry.register(process)
        let janitor = Process()
        janitor.executableURL = URL(fileURLWithPath: "/bin/sh")
        janitor.arguments = GGUFEngine.Planner.janitorCommand(serverPID: process.processIdentifier,
                                                             parentPID: ProcessInfo.processInfo.processIdentifier)
        janitor.standardOutput = FileHandle.nullDevice
        janitor.standardError = FileHandle.nullDevice
        try? janitor.run()
        lock.withLock { child = process; watchdog = janitor }
        // MLX's allocator limit is soft. Keep an independent process budget
        // so an optional fork cannot swap the whole Mac before replying.
        let memoryCeiling = min(MemoryAdvisor.cleanUsableBudget,
                                ProcessInfo.processInfo.physicalMemory * 7 / 10)
        let monitor = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled && process.isRunning {
                if let footprint = MemoryAdvisor.processFootprint(pid: process.processIdentifier), footprint > memoryCeiling {
                    self?.lock.withLock {
                        self?.memoryFailure = "\(runtime.kind.label) exceeded the safe memory budget. Use a smaller model or the existing GGUF model."
                    }
                    process.terminate()
                    try? await Task.sleep(for: .seconds(1))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        lock.withLock { memoryMonitor = monitor }
        let base = URL(string: "http://127.0.0.1:\(port)/v1")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(180)
        var ready = false
        while process.isRunning && Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: base.appendingPathComponent("models"))
            request.timeoutInterval = 2
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { ready = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard ready else {
            throw EngineError.loadFailed(lock.withLock { memoryFailure }
                ?? "\(runtime.kind.label) did not become ready. The standard runtime remains available.")
        }
        if runtime.kind == .omlx {
            var request = URLRequest(url: base.appendingPathComponent("models/model/load"))
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw EngineError.loadFailed("oMLX could not admit this model into memory.")
            }
        }
        try Task.checkCancellation()
        let endpoint = RemoteEndpoint(provider: .custom, model: servedModel, providerID: "vamp-\(runtime.kind.rawValue)",
                                      displayName: runtime.kind.label, baseURL: base, apiProtocol: .openAIChatCompletions,
                                      apiKey: runtime.kind == .omlx ? key : "")
        guard let engine = RemoteLLMEngine(endpoint: endpoint) else { throw EngineError.loadFailed("Invalid local API configuration.") }
        lock.withLock {
            delegate = engine; self.modelID = modelID; contextWindow = context
            vision = runtime.visionModels.contains(modelID); backendLabel = runtime.kind.label
            engine.configureNativeTools(nativeTools)
        }
    }

    func unload() async {
        let old = lock.withLock { () -> ((any LLMEngine)?, Process?, Process?) in
            let old = (delegate, child, watchdog)
            memoryMonitor?.cancel(); memoryMonitor = nil; memoryFailure = nil
            delegate = nil; child = nil; watchdog = nil; modelID = nil
            vision = false; contextWindow = nil; backendLabel = nil
            return old
        }
        await old.0?.cancelGeneration()
        await old.0?.unload()
        if let process = old.1 {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            ChildProcessRegistry.unregister(process)
        }
        if let janitor = old.2, janitor.isRunning { janitor.terminate() }
    }

    func reset() async { await lock.withLock { delegate }?.reset() }
    func cancelGeneration() async { await lock.withLock { delegate }?.cancelGeneration() }
    func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        await lock.withLock { delegate }?.rebaseConversation(to: turns) ?? .unsupported
    }
    func prepareForGeneration(contextTokens: Int, contextWindow: Int) async {
        await lock.withLock { delegate }?.prepareForGeneration(contextTokens: contextTokens, contextWindow: contextWindow)
    }
    func trimTransientMemory() async { await lock.withLock { delegate }?.trimTransientMemory() }
    func stream(adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        if let failure = lock.withLock({ memoryFailure }) { return AsyncThrowingStream { $0.finish(throwing: EngineError.loadFailed(failure)) } }
        guard let engine = lock.withLock({ delegate }) else { return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) } }
        return engine.stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
    }
    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        if let failure = lock.withLock({ memoryFailure }) { return AsyncThrowingStream { $0.finish(throwing: EngineError.loadFailed(failure)) } }
        guard let engine = lock.withLock({ delegate }) else { return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) } }
        return engine.streamReplay(turns, maxTokens: maxTokens, temperature: temperature)
    }
}
