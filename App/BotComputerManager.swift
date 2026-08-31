import Foundation

@MainActor
final class BotComputerManager: ObservableObject {
    @Published private(set) var capabilities: BotHostCapabilities?
    @Published private(set) var computers: [BotComputerRecord] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let service: BotComputerService
    /// Tail of the work chain, and how many operations are still queued behind it.
    private var workTask: Task<Void, Never>?
    private var inFlight = 0

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
            return (capabilities, try await service.prepareSpecialists())
        }
    }

    func prepare(profileID: String) {
        perform { service in
            _ = try await service.prepareSpecialist(profileID: profileID)
            return (await service.capabilities(), try await service.refresh())
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

    // MARK: - Console
    //
    // Deliberately outside `perform`: that path serialises lifecycle work behind `isWorking` and
    // silently drops anything requested while it is busy, which is right for start/stop and wrong
    // for a console the user is typing into.

    func exec(computerID: UUID, command: String) async throws -> String {
        try await service.exec(id: computerID, command: command)
    }

    func listWorkspace(computerID: UUID, path: String) async throws -> [BotWorkspaceEntry] {
        try await service.listWorkspace(id: computerID, relativePath: path)
    }

    func readWorkspaceFile(computerID: UUID, path: String) async throws -> String {
        try await service.readWorkspaceFile(id: computerID, relativePath: path)
    }

    private func perform(
        _ operation: @escaping @Sendable (BotComputerService) async throws
            -> (BotHostCapabilities, [BotComputerRecord])
    ) {
        // Queued, not dropped. `guard !isWorking else { return }` discarded any request that
        // arrived mid-flight — a reload() during a start() vanished silently and left the UI on
        // stale state with no error and no retry. Chaining keeps call order and keeps every
        // request; `inFlight` keeps the spinner up until the last one lands.
        inFlight += 1
        isWorking = true
        errorMessage = nil
        let previous = workTask
        workTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await operation(self.service)
                self.capabilities = result.0
                self.computers = result.1
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.inFlight -= 1
            self.isWorking = self.inFlight > 0
        }
    }
}
