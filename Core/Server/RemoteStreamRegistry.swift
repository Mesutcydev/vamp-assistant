import Foundation

/// Keeps authorization alive for the entire response, including while an
/// upstream source is idle. No captured screen/audio data is retained here.
@MainActor
final class RemoteStreamRegistry {
    enum Capability { case session, control }

    private struct Entry {
        let clientID: String
        let capability: Capability
        let cancel: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private let checkInterval: Duration

    init(checkInterval: Duration = .milliseconds(250)) {
        self.checkInterval = checkInterval
    }

    isolated deinit {
        for entry in entries.values { entry.cancel() }
    }

    func protect(
        _ source: AsyncStream<Data>,
        clientID: String,
        capability: Capability,
        bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy = .bufferingNewest(32),
        isAuthorized: @escaping @MainActor () -> Bool
    ) -> AsyncStream<Data> {
        let id = UUID()
        let interval = checkInterval
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let forwarder = Task { @MainActor [weak self] in
                defer {
                    continuation.finish()
                    self?.remove(id)
                }
                for await data in source {
                    guard !Task.isCancelled, isAuthorized() else { return }
                    continuation.yield(data)
                }
            }
            let monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard isAuthorized() else {
                        self?.remove(id)
                        return
                    }
                    do { try await Task.sleep(for: interval) }
                    catch { return }
                }
            }
            entries[id] = Entry(clientID: clientID, capability: capability) {
                forwarder.cancel()
                monitor.cancel()
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.remove(id) }
            }
        }
    }

    func cancel(clientID: String? = nil, capability: Capability? = nil) {
        let ids = entries.compactMap { id, entry in
            (clientID == nil || entry.clientID == clientID)
                && (capability == nil || entry.capability == capability) ? id : nil
        }
        for id in ids { remove(id) }
    }

    private func remove(_ id: UUID) {
        // Remove before finishing: termination can itself request removal.
        entries.removeValue(forKey: id)?.cancel()
    }
}
