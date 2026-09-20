import Foundation

/// An image carried by a user turn. Engines that see pixels natively (a GGUF
/// model served with a multimodal projector) forward the bytes as an
/// OpenAI-compatible `image_url` part. Engines that cannot see must ignore
/// them rather than pretend — dropping an image silently is worse than
/// falling back to a described-image path the caller chooses explicitly.
public struct ChatImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let name: String

    public init(data: Data, mimeType: String, name: String) {
        self.data = data
        self.mimeType = mimeType
        self.name = name
    }

    /// Parse a `data:` URL back into an image — the local API server uses
    /// this when a client posts an image part. A remote http(s) URL returns
    /// nil: nothing is ever fetched implicitly on the model's behalf.
    public init?(dataURL: String) {
        guard dataURL.hasPrefix("data:"), let marker = dataURL.range(of: ";base64,") else { return nil }
        let meta = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<marker.lowerBound]
        guard let data = Data(base64Encoded: String(dataURL[marker.upperBound...])), !data.isEmpty
        else { return nil }
        self.data = data
        self.mimeType = meta.isEmpty ? "image/png" : String(meta)
        self.name = "image"
    }

    /// Read an image file for native image input, honouring the container
    /// whitelist and a size ceiling (a 40 MB image is a prompt bomb, not a
    /// screenshot). Returns nil when the file cannot be sent natively.
    public static func fromFile(
        at url: URL,
        maxBytes: Int = 12 * 1024 * 1024
    ) -> ChatImage? {
        guard canSendNatively(pathExtension: url.pathExtension) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maxBytes
        else { return nil }
        return ChatImage(
            data: data,
            mimeType: sniffMimeType(data, pathExtension: url.pathExtension),
            name: url.lastPathComponent)
    }

    /// `data:` URL for an OpenAI-compatible `image_url` content part.
    public var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Containers llama.cpp's multimodal path actually decodes (stb_image):
    /// PNG, JPEG, GIF, BMP. Everything else — notably HEIC from an iPhone —
    /// must go through the CoreImage-based sidecar instead.
    public static let nativeExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp"]

    /// True when an image with this path extension can be sent as raw bytes.
    public static func canSendNatively(pathExtension: String) -> Bool {
        nativeExtensions.contains(pathExtension.lowercased())
    }

    /// Magic-byte sniff — an image with a wrong or missing extension still
    /// gets a mime type a strict server accepts.
    public static func sniffMimeType(_ data: Data, pathExtension: String = "") -> String {
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.count >= 6, data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if data.count >= 2, data.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }
}

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
    /// Images the user attached to this turn. Only an engine with native
    /// image input (`supportsImageInput`) serializes them.
    public let images: [ChatImage]

    public init(
        role: Role,
        content: String,
        toolName: String? = nil,
        thoughtSignature: String? = nil,
        images: [ChatImage] = []
    ) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.thoughtSignature = thoughtSignature
        self.images = images
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
    public var qwenStreaming: QwenStreamingDiagnostics? = nil
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
    /// resident conversation. Used by nested `task` subagents and the local
    /// OpenAI-compatible API so the parent turn history / KV accumulation
    /// stays intact. Default: `stream(adding:)`.
    func streamReplay(_ turns: [ChatTurn], maxTokens: Int?, temperature: Double?) -> AsyncThrowingStream<String, Error>

    /// True when the resident model can accept image content directly — a
    /// GGUF model launched with a multimodal projector. The send path uses
    /// this to choose between native image bytes and the described-image
    /// fallback, so it must be runtime truth about the LOADED model, not a
    /// catalog guess. A protocol REQUIREMENT (default below) for the same
    /// dispatch reason as `effectiveContextWindow`.
    var supportsImageInput: Bool { get async }

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

    /// Default: this engine cannot see pixels. MLX text models and every
    /// remote/BYOK provider use the described-image path instead.
    public var supportsImageInput: Bool { get async { false } }

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

/// Nested agents and the local OpenAI API need a full-transcript generation
/// that does not keep the parent's accumulated turns. Engines swap their
/// resident transcript out, generate, then put it back.
enum IsolatedTranscriptReplay {
    static func stream(
        _ turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?,
        swapOut: @escaping @Sendable () -> [ChatTurn],
        swapIn: @escaping @Sendable ([ChatTurn]) -> Void,
        generate: @escaping @Sendable ([ChatTurn], Int?, Double?) -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let saved = swapOut()
                defer { swapIn(saved) }
                do {
                    for try await chunk in generate(turns, maxTokens, temperature) {
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
}
