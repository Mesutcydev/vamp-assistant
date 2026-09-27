import Foundation
import MLX
import MLXLMCommon
import MLXRunners

/// OpenAI transport for MLXFast's optimized runner. The stock mlx-server's
/// ModelContainer path bypasses CBv2; it is not the Bonsai benchmark engine.
actor VampBonsaiServerEngine: MLXServerEngine {
    private let runner: any Runner
    private let modelID: String
    private var busy = false
    private var serial: UInt64 = 0

    init(runner: any Runner, modelID: String) {
        self.runner = runner
        self.modelID = modelID
    }

    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    func availableModels() async throws -> [MLXServerModel] { [.init(id: modelID)] }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        .init(tokens: runner.tokenizer.encode(text: request.prompt, addSpecialTokens: request.addSpecialTokens ?? true))
    }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        .init(text: runner.tokenizer.decode(tokenIds: request.tokens, skipSpecialTokens: request.skipSpecialTokens ?? false))
    }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        .init(tokens: try runner.tokenizer.applyChatTemplate(
            messages: request.messages.map { $0.templateMessage() },
            tools: request.tools?.map { $0.toolSpec() },
            additionalContext: ["enable_thinking": false]))
    }

    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        guard !busy else { throw Failure.message("The local Bonsai engine is busy. Wait for the current reply.") }
        guard !request.messages.contains(where: { $0.content.hasMedia }) else {
            throw MLXModelContainerEngineError.mediaUnsupported
        }
        try MLXModelContainerEngine.validateToolParserOverride(
            requested: request.toolCallParser, pinned: .qwen35, modelType: "qwen3_5")
        let tools = request.tools?.map { $0.toolSpec() }
        let prompt = try runner.tokenizer.applyChatTemplate(
            messages: request.messages.map { $0.templateMessage() }, tools: tools,
            additionalContext: ["enable_thinking": false])
        guard prompt.count < 4096 else { throw Failure.message("Bonsai's context is limited to 4096 tokens on this Mac.") }
        let engine = try runner.makeEngine(EngineBuild(
            kvBackend: .contiguous, kvBytesCapacity: 512 * 1024 * 1024,
            schedulerConfig: CBv2SchedulerConfig(maxConcurrentRequests: 1, prefillChunkSize: 256,
                                                maxWaiting: 1, enablePrefixCache: false),
            decoder: .serial, mtpConfig: CBv2MTPConfig(enabled: false),
            environment: ProcessInfo.processInfo.environment))
        serial &+= 1
        let id = CBv2RequestID(serial)
        let input = CBv2Request(id: id, promptTokens: prompt,
                               sampling: .init(temperature: request.temperature ?? 0.6, topP: request.topP ?? 1),
                               maxTokens: min(request.maxTokens ?? 512, 4096 - prompt.count),
                               stopTokens: runner.eosTokenIDs, stopStrings: request.stop ?? [],
                               prefixCacheEnabled: false)
        let events: AsyncStream<CBv2Event>
        do { events = try engine.submit(input) }
        catch { await engine.shutdown(); throw error }
        busy = true
        return AsyncThrowingStream { continuation in
            let task = Task {
                let processor = ToolCallProcessor(format: .qwen35, tools: tools)
                let started = Date()
                var firstToken: Date?
                var terminal = false
                for await event in events {
                    if Task.isCancelled { engine.cancel(id); break }
                    switch event {
                    case .delta(let text, _, _):
                        if firstToken == nil { firstToken = Date() }
                        if let content = processor.processChunk(text), !content.isEmpty { continuation.yield(.content(content)) }
                        for call in processor.drainToolCalls() { continuation.yield(.toolCall(call)) }
                    case .finished(let reason, let usage):
                        terminal = true
                        switch reason {
                        case .error(let message), .terminal(_, let message):
                            continuation.finish(throwing: Failure.message(message))
                        default:
                            if let content = processor.processEOS(returnBufferedText: true), !content.isEmpty {
                                continuation.yield(.content(content))
                            }
                            for call in processor.drainToolCalls() { continuation.yield(.toolCall(call)) }
                            continuation.yield(.info(.init(promptTokens: usage.promptTokens,
                                completionTokens: usage.completionTokens,
                                promptTime: (firstToken ?? Date()).timeIntervalSince(started),
                                generationTime: Date().timeIntervalSince(firstToken ?? started),
                                stopReason: reason == .length ? "length" : "stop")))
                            continuation.finish()
                        }
                    }
                }
                if !terminal { continuation.finish(throwing: CancellationError()) }
                await engine.shutdown()
                MLX.Memory.clearCache()
                busy = false
            }
            continuation.onTermination = { _ in task.cancel(); engine.cancel(id) }
        }
    }
}
