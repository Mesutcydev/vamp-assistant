import Foundation

/// Nested `task` subagents share the parent engine. This wrapper keeps the
/// child's transcript on the side and calls `streamReplay` so the parent's
/// accumulated turns stay intact. `reset()` only clears the child side.
final class IsolatedReplayEngine: LLMEngine, @unchecked Sendable {
    private let inner: any LLMEngine
    private let lock = NSLock()
    private var childHistory: [ChatTurn] = []

    init(_ inner: any LLMEngine) {
        self.inner = inner
    }

    var loadedModelID: String? { get async { await inner.loadedModelID } }
    var stats: EngineStats { get async { await inner.stats } }
    var effectiveContextWindow: Int? { get async { await inner.effectiveContextWindow } }
    var externalResidentMemoryBytes: UInt64? { get async { await inner.externalResidentMemoryBytes } }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        try await inner.load(directory: directory, modelID: modelID, diskBytes: diskBytes)
    }

    func unload() async { await inner.unload() }

    func reset() async {
        lock.withLock { childHistory = [] }
    }

    func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        lock.withLock { childHistory = turns }
        return SemanticRebaseResult(installedHistory: true)
    }

    func prepareForGeneration(contextTokens: Int, contextWindow: Int) async {
        await inner.prepareForGeneration(contextTokens: contextTokens, contextWindow: contextWindow)
    }

    func trimTransientMemory() async {
        await inner.trimTransientMemory()
    }

    func stream(
        adding turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let transcript = lock.withLock { () -> [ChatTurn] in
            childHistory.append(contentsOf: turns)
            return childHistory
        }
        return inner.streamReplay(transcript, maxTokens: maxTokens, temperature: temperature)
    }

    func streamReplay(
        _ turns: [ChatTurn],
        maxTokens: Int?,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        inner.streamReplay(turns, maxTokens: maxTokens, temperature: temperature)
    }

    func cancelGeneration() async {
        await inner.cancelGeneration()
    }
}
