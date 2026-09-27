import Combine
import Foundation

/// Retains one specialist's completely independent agent controller and its
/// observation pipeline. The foreground Assistant controller is never
/// mutated by a bot run.
@MainActor
final class BotRunRuntimeHandle {
    let controller: AgentSessionController
    private var cancellables: Set<AnyCancellable> = []
    private var terminalDelivered = false

    init(controller: AgentSessionController) {
        self.controller = controller
    }

    func bind(
        runID: UUID,
        coordinator: BotRunCoordinator,
        onTerminal: @escaping (UUID) -> Void
    ) {
        Publishers.CombineLatest3(
            controller.$currentPhase,
            controller.$finishReason,
            controller.$streamingText)
            // Streaming republishes every ~120 ms and each sync rewrites the run history to disk.
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak coordinator] phase, finish, output in
                // One terminal sync per runtime; anything after it is stale.
                guard let self, let coordinator, !terminalDelivered else { return }
                coordinator.sync(
                    runID: runID, phase: phase, finish: finish, output: output,
                    trace: finish == nil ? [] : controller.botToolTrace)
                guard finish != nil else { return }
                terminalDelivered = true
                Task { @MainActor in onTerminal(runID) }
            }
            .store(in: &cancellables)
    }
}

extension AgentSessionController {
    /// This session's finished tool calls, in order, for bot evidence.
    var botToolTrace: [BotToolTrace] {
        var calls: [UUID: ToolInvocation] = [:]
        for case .toolCall(let call) in transcript.map(\.kind) { calls[call.id] = call }
        return transcript.compactMap { item in
            guard case .toolResult(let id, _, let failed, let name) = item.kind else { return nil }
            let arguments = calls[id].flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.argumentsJSON.utf8)) as? [String: Any]
            }
            return BotToolTrace(
                name: name ?? calls[id]?.name ?? "",
                command: arguments?["command"] as? String,
                failed: failed)
        }
    }
}
