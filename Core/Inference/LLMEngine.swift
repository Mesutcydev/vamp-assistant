import Foundation

/// A chat turn as the engine sees it. Engines accumulate the turns they are
/// handed as the canonical transcript. Stateless engines replay it; a local
/// engine may reuse only a verified equivalent cache prefix. Call `reset`
/// between unrelated tasks.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    /// Gemini `functionResponse.name` pairing. Other engines ignore it.
    public let toolName: String?
    /// Gemini thought signature that must be echoed on the next model turn.
    public let thoughtSignature: String?

    public init(
        role: Role,
        content: String,
        toolName: String? = nil,
        thoughtSignature: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.thoughtSignature = thoughtSignature
    }
}

/// Result of replacing an engine's canonical transcript after compaction.
/// `installedHistory` lets AgentLoop avoid sending the rebuilt transcript a
/// second time. `preservedCachePrefixTurns` is runtime truth: only a backend
/// that actually keeps a reusable prefix reports a non-zero value.
public struct SemanticRebaseResult: Sendable, Equatable {
    public var installedHistory: Bool
    public var preservedCachePrefixTurns: Int

    public init(installedHistory: Bool, preservedCachePrefixTurns: Int = 0) {
        self.installedHistory = installedHistory
        self.preservedCachePrefixTurns = max(0, preservedCachePrefixTurns)
    }

    public static let unsupported = SemanticRebaseResult(installedHistory: false)
}

/// Pure semantic-boundary planner shared by the agent and local backends.
/// Reuse stops at the first complete turn whose role or bytes changed; it
/// never guesses that a partial message is token-equivalent.
enum SemanticContextPlanner {
    static func commonPrefixTurnCount(_ old: [ChatTurn], _ new: [ChatTurn]) -> Int {
        var count = 0
        for (lhs, rhs) in zip(old, new) {
            guard lhs == rhs else { break }
            count += 1
        }
        return count
    }
}

public enum EngineAcceleration: String, Sendable, Equatable {
    case standard
    case mtp
    case dflash
    case ngram
}

public struct EngineStats: Sendable, Equatable {
    public var tokensPerSecond: Double?
    public var generatedTokens: Int
    /// Prompt tokens from the last usage report (0 when the engine doesn't know).
    public var promptTokens: Int
    /// Monotonic id bumped on every completed generation that reported usage.
    /// AppState uses this to accumulate session totals without double-counting
    /// the 2-second stats poll.
    public var usageSerial: UInt64
    /// Decode acceleration actually used by the resident engine. This is
    /// runtime truth, not the requested setting: a failed experimental launch
    /// reports `.standard` (or `.mtp` when the built-in fallback succeeded).
    public var acceleration: EngineAcceleration
    /// Runtime truth for the two opt-in MLX memory experiments. These stay
    /// false for GGUF/remote engines and are cleared if MLX falls back.
    public var mlxPromptCacheActive: Bool
    public var mlxQuantizedKVActive: Bool

    public init(
        tokensPerSecond: Double? = nil,
        generatedTokens: Int = 0,
        promptTokens: Int = 0,
        usageSerial: UInt64 = 0,
        acceleration: EngineAcceleration = .standard,
        mlxPromptCacheActive: Bool = false,
        mlxQuantizedKVActive: Bool = false
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.generatedTokens = generatedTokens
        self.promptTokens = promptTokens
        self.usageSerial = usageSerial
        self.acceleration = acceleration
        self.mlxPromptCacheActive = mlxPromptCacheActive
        self.mlxQuantizedKVActive = mlxQuantizedKVActive
    }
}

public enum EngineError: Error, LocalizedError, Equatable {
    case notLoaded
    case alreadyLoading
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "No model is loaded."
        case .alreadyLoading: return "A model load is already in progress."
        case .loadFailed(let reason): return "Model failed to load: \(reason)"
        }
    }
}

/// Abstraction over inference backends. Today: MLX. Later: a GGUF/llama.cpp
/// engine behind the same protocol.
public protocol LLMEngine: AnyObject, Sendable {
    var loadedModelID: String? { get async }
    var stats: EngineStats { get async }

    /// Memory charged to a helper process owned by this engine, when the
    /// backend runs outside Beet Code. In-process engines return nil because
    /// their footprint is already included in `MemoryAdvisor.processFootprint`.
    /// The pool uses this to keep warm GGUF servers from becoming invisible
    /// to admission decisions.
    var externalResidentMemoryBytes: UInt64? { get async }

    /// The context window actually in effect for the resident model, when
    /// the engine knows it. GGUF fits the llama-server launch ctx to the RAM
    /// budget, which can be SMALLER than the catalog window — the agent
    /// loop's compaction must target this number or the server hard-errors
    /// (HTTP 400) instead of compacting. nil → fall back to the catalog.
    /// A protocol REQUIREMENT (default below) for the same dispatch reason
    /// as the context-aware load.
    var effectiveContextWindow: Int? { get async }

    /// Loads a model from a local directory. Admission is arbitrated by
    /// `MemoryAdvisor` before any weights are touched.
    func load(directory: URL, modelID: String, diskBytes: Int64) async throws

    /// Context-window-aware load. A protocol REQUIREMENT (with the default
    /// below) so calls through `any LLMEngine` dispatch to the conformer's
    /// witness — GGUFEngine's llama-server needs the size as a launch flag,
    /// and an extension-only member would be statically bypassed.
    func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws

    func unload() async

    func reset() async

    /// Replaces canonical history after semantic compaction. GGUF keeps its
    /// llama.cpp slot alive so exact-prefix KV pages up to the first edited
    /// tool/turn boundary remain reusable. Backends that cannot safely rebase
    /// return `.unsupported`; AgentLoop resets and replays in full.
    func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult

    /// Safe-point hook immediately before generation. A pooled local engine
    /// may release idle residents and disposable allocation caches as context
    /// grows. It must never discard the active conversation or model.
    func prepareForGeneration(contextTokens: Int, contextWindow: Int) async

    /// Releases backend allocation/workspace caches without clearing the
    /// canonical transcript or active KV state.
    func trimTransientMemory() async

    /// Appends turns to the session and streams the model's reply as text
    /// chunks. `maxTokens` caps this generation (thermal policy applied by
    /// the caller).
    func stream(adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// Generate from an explicit transcript WITHOUT mutating the engine's
    /// resident conversation. Used by nested `task` subagents so the parent
    /// turn history / KV accumulation stays intact. Default: `stream(adding:)`.
    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// Cancels queued/in-flight generation. In-flight Metal work completes;
    /// queued work is skipped.
    func cancelGeneration() async
}

extension LLMEngine {
    /// Memory-pressure response: free caches. Default: nothing (engines that
    /// maintain caches override this).
    func clearCaches() async {}

    public func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        .unsupported
    }

    public func prepareForGeneration(contextTokens: Int, contextWindow: Int) async {}

    public func trimTransientMemory() async {}

    /// Default context-aware load: engines that size context from the model
    /// itself (MLX reads the checkpoint config) ignore the hint. Public —
    /// witnesses for a public protocol must be.
    public func load(directory: URL, modelID: String, diskBytes: Int64, contextSize: Int?) async throws {
        try await load(directory: directory, modelID: modelID, diskBytes: diskBytes)
    }

    /// Default: the engine doesn't size context itself — callers use the
    /// catalog window. Public — witnesses for a public protocol must be.
    public var effectiveContextWindow: Int? { get async { nil } }

    /// In-process and remote engines have no separately-accounted helper.
    public var externalResidentMemoryBytes: UInt64? { get async { nil } }

    public func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
    }

    /// Emergency unload used by the memory-pressure coordinator. Returns true
    /// when a model was actually resident and got dumped.
    @discardableResult
    func dumpIfResident() async -> Bool { false }
}
