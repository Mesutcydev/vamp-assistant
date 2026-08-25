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
            .sink { [weak self, weak coordinator] phase, finish, output in
                guard let self, let coordinator else { return }
                coordinator.sync(
                    runID: runID, phase: phase, finish: finish, output: output)
                guard finish != nil, !terminalDelivered else { return }
                terminalDelivered = true
                Task { @MainActor in onTerminal(runID) }
            }
            .store(in: &cancellables)
    }
}
