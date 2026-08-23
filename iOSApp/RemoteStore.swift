import Foundation
import Observation

@MainActor
@Observable
final class RemoteStore {
    var sessions: [RemoteSessionSummary] = []
    var selectedSession: RemoteSessionDetail?
    var isConnecting = false
    var isRefreshing = false
    var errorMessage: String?
    var connectionLabel = "Disconnected"

    private(set) var baseURL: URL?
    private var token: String?
    private var pollingTask: Task<Void, Never>?

    init() {
        token = RemoteTokenStore.load()
        if let saved = UserDefaults.standard.string(forKey: "remoteBaseURL"),
           let url = URL(string: saved) {
            baseURL = url
        }
    }

    var isConnected: Bool { baseURL != nil && token != nil }

    func restore() async {
        guard isConnected else { return }
        do {
            try await refresh()
            startPolling()
        } catch {
            disconnect(clearAddress: false)
            errorMessage = error.localizedDescription
        }
    }

    func connect(address: String, code: String) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let parsed = try Self.parse(address: address, explicitCode: code)
            let response = try await RemoteAPIClient(baseURL: parsed.url).pair(code: parsed.code)
            try RemoteTokenStore.save(response.token)
            baseURL = parsed.url
            token = response.token
            UserDefaults.standard.set(parsed.url.absoluteString, forKey: "remoteBaseURL")
            try await refresh()
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async throws {
        guard let client else { throw RemoteClientError.notConnected }
        isRefreshing = true
        defer { isRefreshing = false }
        async let status = client.status()
        async let list = client.sessions()
        let (nextStatus, nextList) = try await (status, list)
        sessions = nextList.sessions
        connectionLabel = nextStatus.isRunning ? nextStatus.phase.capitalized : "Connected"
        if let id = selectedSession?.id ?? sessions.first?.id {
            selectedSession = try await client.session(id)
        }
        errorMessage = nil
    }

    func select(_ session: RemoteSessionSummary) async {
        guard let client else { return }
        do { selectedSession = try await client.session(session.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func send(_ text: String) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let client, let id = selectedSession?.id else { return false }
        do {
            _ = try await client.send(message, to: id)
            selectedSession = try await client.session(id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stop() async {
        guard let client, let id = selectedSession?.id else { return }
        do { _ = try await client.stop(id) as RemoteAcceptedResponse }
        catch { errorMessage = error.localizedDescription }
    }

    func resolvePending(_ value: String) async {
        guard let client, let detail = selectedSession, let pending = detail.pending else { return }
        do {
            try await client.resolve(pending, sessionID: detail.id, value: value)
            selectedSession = try await client.session(detail.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func revoke() async {
        if let client { try? await client.revoke() }
        disconnect(clearAddress: true)
    }

    func disconnect(clearAddress: Bool = false) {
        pollingTask?.cancel()
        pollingTask = nil
        token = nil
        RemoteTokenStore.clear()
        sessions = []
        selectedSession = nil
        connectionLabel = "Disconnected"
        if clearAddress {
            baseURL = nil
            UserDefaults.standard.removeObject(forKey: "remoteBaseURL")
        }
    }

    private var client: RemoteAPIClient? {
        guard let baseURL, let token else { return nil }
        return RemoteAPIClient(baseURL: baseURL, token: token)
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                try? await self?.refresh()
            }
        }
    }

    private static func parse(address: String, explicitCode: String) throws -> (url: URL, code: String) {
        let candidate = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, components.port != nil else {
            throw RemoteClientError.invalidAddress
        }
        let queryCode = components.queryItems?.first(where: { $0.name == "pair" })?.value
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemoteClientError.invalidAddress }
        if scheme == "http", !isPrivateHost(host) { throw RemoteClientError.insecurePublicAddress }
        let code = (queryCode ?? explicitCode).filter(\.isNumber)
        guard code.count == 6 else { throw RemoteClientError.invalidPairingCode }
        return (url, code)
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || (parts[0] == 100 && (64...127).contains(parts[1]))
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || parts[0] == 127
    }
}
