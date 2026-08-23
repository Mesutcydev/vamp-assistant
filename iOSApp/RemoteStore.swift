import Foundation
import Observation

@MainActor
@Observable
final class RemoteStore {
    var sessions: [RemoteSessionSummary] = []
    var selectedSession: RemoteSessionDetail?
    var startModels: [RemoteStartModelOption] = []
    var sharedFiles: [RemoteSharedFileItem] = []
    var isConnecting = false
    var isRefreshing = false
    var isSharing = false
    var errorMessage: String?
    var connectionLabel = "Disconnected"

    private(set) var baseURL: URL?
    private var token: String?
    private var pollingTask: Task<Void, Never>?
    private var connectionAvailable = false
    private var consecutivePollingFailures = 0

    init() {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["BEETCODE_REMOTE_TEST_URL"],
           let url = URL(string: address),
           let testToken = environment["BEETCODE_REMOTE_TEST_TOKEN"] {
            baseURL = url
            token = testToken
            return
        }
#endif
        token = RemoteTokenStore.load()
        if let saved = UserDefaults.standard.string(forKey: "remoteBaseURL"),
           let url = URL(string: saved) {
            baseURL = url
        }
    }

    var hasSavedConnection: Bool { baseURL != nil && token != nil }
    var isConnected: Bool { hasSavedConnection && connectionAvailable }
    var savedMacAddress: String? { baseURL?.absoluteString }

    func restore() async {
        guard hasSavedConnection else { return }
        await connectSaved(showFailure: false)
    }

    func connectSaved(showFailure: Bool = true) async {
        guard hasSavedConnection else { return }
        isConnecting = true
        if showFailure { errorMessage = nil }
        defer { isConnecting = false }
        do {
            try await refresh()
            connectionAvailable = true
            connectionLabel = "Connected"
            consecutivePollingFailures = 0
            startPolling()
        } catch {
            connectionAvailable = false
            connectionLabel = "Mac unavailable"
            if showFailure { errorMessage = "Your saved Mac is not reachable yet. Make sure Beet Code Remote Sessions and Tailscale are on, then try again." }
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
            connectionAvailable = true
            connectionLabel = "Connected"
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
        connectionAvailable = true
        consecutivePollingFailures = 0
        sessions = nextList.sessions
        connectionLabel = nextStatus.isRunning ? nextStatus.phase.capitalized : "Connected"
        if let id = selectedSession?.id,
           sessions.contains(where: { $0.id == id }) {
            selectedSession = try await client.session(id)
        } else if selectedSession != nil {
            selectedSession = nil
        }
        errorMessage = nil
    }

    func select(_ session: RemoteSessionSummary) async {
        await select(sessionID: session.id)
    }

    func select(sessionID: UUID) async {
        guard let client else { return }
        do { selectedSession = try await client.session(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }

    func loadStartModels() async {
        guard let client else { return }
        do { startModels = try await client.models().models }
        catch { errorMessage = error.localizedDescription }
    }

    func startSession(modelID: String, message: String) async -> UUID? {
        guard let client else { return nil }
        do {
            _ = try await client.startSession(modelID: modelID, message: message) as RemoteAcceptedResponse
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(350))
                try await refresh()
                if let session = sessions.first(where: { $0.isRunning }) ?? sessions.first {
                    await select(sessionID: session.id)
                    return session.id
                }
            }
            errorMessage = "The session started, but has not appeared yet. Pull down to refresh."
        } catch { errorMessage = error.localizedDescription }
        return nil
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
        forgetSavedMac()
    }

    func forgetSavedMac() {
        pollingTask?.cancel()
        pollingTask = nil
        connectionAvailable = false
        token = nil
        RemoteTokenStore.clear()
        sessions = []
        startModels = []
        sharedFiles = []
        selectedSession = nil
        connectionLabel = "Disconnected"
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: "remoteBaseURL")
    }

    func loadSharing() async {
        guard let client else { return }
        isSharing = true
        defer { isSharing = false }
        do { sharedFiles = try await client.sharedFiles().files }
        catch { errorMessage = error.localizedDescription }
    }

    func copyMacClipboard() async -> String? {
        guard let client else { return nil }
        isSharing = true
        defer { isSharing = false }
        do { return try await client.clipboard().text }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func sendClipboardToMac(_ text: String) async -> Bool {
        guard let client, !text.isEmpty else { return false }
        isSharing = true
        defer { isSharing = false }
        do { _ = try await client.setClipboard(text); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func uploadFile(_ url: URL) async -> Bool {
        guard let client else { return false }
        isSharing = true
        defer { isSharing = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
                throw RemoteClientError.server("Choose a non-empty file smaller than 20 MB.")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            _ = try await client.uploadFile(data: data, name: url.lastPathComponent)
            sharedFiles = try await client.sharedFiles().files
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func downloadFile(_ file: RemoteSharedFileItem) async -> URL? {
        guard let client else { return nil }
        isSharing = true
        defer { isSharing = false }
        do {
            let data = try await client.downloadFile(named: file.name)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BeetCode Remote", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(file.name, isDirectory: false)
            try data.write(to: destination, options: [.atomic])
            return destination
        } catch { errorMessage = error.localizedDescription; return nil }
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
                do { try await self?.refresh() }
                catch {
                    guard let self else { return }
                    self.consecutivePollingFailures += 1
                    if self.consecutivePollingFailures >= 3 {
                        self.connectionAvailable = false
                        self.connectionLabel = "Reconnecting…"
                    }
                }
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
