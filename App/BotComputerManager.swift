import Foundation

@MainActor
final class BotComputerManager: ObservableObject {
    @Published private(set) var capabilities: BotHostCapabilities?
    @Published private(set) var computers: [BotComputerRecord] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let service: BotComputerService

    init(service: BotComputerService = BotComputerService()) {
        self.service = service
    }

    func reload() {
        perform { service in
            let capabilities = await service.capabilities()
            let records = try await service.refresh()
            return (capabilities, records)
        }
    }

    func prepareDefault() {
        perform { service in
            let capabilities = await service.capabilities()
            _ = try await service.prepare(
                profileID: "beet",
                name: "Beet",
                backend: capabilities.supportsAppleContainers
                    ? .appleContainer : .isolatedWorkspace)
            return (capabilities, try await service.refresh())
        }
    }

    func start(_ computer: BotComputerRecord) {
        perform { service in
            _ = try await service.start(id: computer.id)
            return (await service.capabilities(), try await service.refresh())
        }
    }

    func stop(_ computer: BotComputerRecord) {
        perform { service in
            _ = try await service.stop(id: computer.id)
            return (await service.capabilities(), try await service.refresh())
        }
    }

    private func perform(
        _ operation: @escaping @Sendable (BotComputerService) async throws
            -> (BotHostCapabilities, [BotComputerRecord])
    ) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await operation(service)
                capabilities = result.0
                computers = result.1
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
