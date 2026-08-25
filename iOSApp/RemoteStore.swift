import Foundation
import Observation

struct PairedBeetCodeComputer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseURL: URL

    init(id: UUID = UUID(), name: String? = nil, baseURL: URL) {
        self.id = id
        self.name = name ?? baseURL.host ?? "Vamp Assistant Mac"
        self.baseURL = baseURL
    }
}

@MainActor
@Observable
final class RemoteStore {
    var sessions: [RemoteSessionSummary] = []
    var selectedSession: RemoteSessionDetail?
    var startModels: [RemoteStartModelOption] = []
    var botRuns: [RemoteBotRun] = []
    var sharedFiles: [RemoteSharedFileItem] = []
    var isConnecting = false
    var isRefreshing = false
    var isSharing = false
    var errorMessage: String?
    var errorTitle = "Couldn't complete that"
    var connectionLabel = "Disconnected"
    var autoMode = true
    var sessionMode: RemoteSessionMode = .chat
    var workspaces: [RemoteWorkspace] = []
    var workspaceCreateParent: String?
    var workspacesSupported = true
    var fullAccess = false
    var reasoningEffort: String?
    private(set) var pairedComputers: [PairedBeetCodeComputer] = []
    private(set) var activeComputerID: UUID?

    private(set) var baseURL: URL?
    private var token: String?
    private var pollingTask: Task<Void, Never>?
    private var sessionStreamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Error>?
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
        restoreComputerProfiles()
    }

    var hasSavedConnection: Bool { baseURL != nil && token != nil }
    var isConnected: Bool { hasSavedConnection && connectionAvailable }
    var isMacReachable: Bool { isConnected }
    var connectionSubtitle: String {
        if isConnected { return "Private over Tailscale" }
        if isConnecting || connectionLabel == "Reconnecting…" || connectionLabel == "Connecting…" {
            return "Looking for \(activeComputerName)"
        }
        return "Tap to retry"
    }
    var savedMacAddress: String? { baseURL?.absoluteString }
    var activeComputer: PairedBeetCodeComputer? {
        pairedComputers.first { $0.id == activeComputerID }
    }
    var activeComputerName: String { activeComputer?.name ?? "Mac" }

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
            if showFailure {
                errorTitle = "Mac unavailable"
                errorMessage = "Your saved Mac is not reachable yet. Make sure Vamp Assistant Remote Sessions and Tailscale are on, then try again."
            }
        }
    }

    func connect(address: String, code: String) async -> Bool {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let parsed = try Self.parse(address: address, explicitCode: code)
            let response = try await RemoteAPIClient(baseURL: parsed.url).pair(code: parsed.code)
            let computer = pairedComputers.first { $0.baseURL == parsed.url }
                ?? PairedBeetCodeComputer(baseURL: parsed.url)
            try RemoteTokenStore.save(response.token, computerID: computer.id)
            if let index = pairedComputers.firstIndex(where: { $0.id == computer.id }) {
                pairedComputers[index] = computer
            } else {
                pairedComputers.append(computer)
            }
            activeComputerID = computer.id
            baseURL = parsed.url
            token = response.token
            saveComputerProfiles()
            try await refresh()
            connectionAvailable = true
            connectionLabel = "Connected"
            startPolling()
            await RemoteNotificationCenter.shared.requestPermission()
            return true
        } catch {
            presentError("Couldn't pair", error)
            return false
        }
    }

    func refresh() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRefresh()
        }
        refreshTask = task
        defer {
            refreshTask = nil
            isRefreshing = false
        }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let client else { throw RemoteClientError.notConnected }
        async let status = client.status()
        async let list = client.sessions()
        let (nextStatus, nextList) = try await (status, list)
        connectionAvailable = true
        consecutivePollingFailures = 0
        sessions = nextList.sessions
        // Bot runs were added after the original paired-session protocol;
        // an older Mac must remain usable instead of failing the whole refresh.
        botRuns = (try? await client.botRuns())?.runs ?? []
        RemoteNotificationCenter.shared.observeSessions(
            nextList.sessions,
            computerName: activeComputerName)
        connectionLabel = nextStatus.isRunning ? nextStatus.phase.capitalized : "Connected"
        if let id = selectedSession?.id,
           sessions.contains(where: { $0.id == id }) {
            if sessionStreamTask == nil {
                selectedSession = try await client.session(id)
                startSessionStream(id: id)
            }
        } else if selectedSession != nil {
            sessionStreamTask?.cancel()
            sessionStreamTask = nil
            selectedSession = nil
        }
        errorMessage = nil
    }

    func macControlStatus() async throws -> RemoteMacControlStatus {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.controlStatus()
    }

    func macControlApplications() async throws -> [RemoteMacApplication] {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.controlApplications().applications
    }

    func macControlFrame(
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        resolution: RemoteStreamResolution = .balanced
    ) async throws -> RemoteMacControlFrame {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.controlScreen(
            displayID: displayID,
            windowID: windowID,
            resolution: resolution)
    }

    func macControlFrames(
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        resolution: RemoteStreamResolution = .balanced
    ) -> AsyncThrowingStream<RemoteMacControlFrame, Error> {
        guard let client else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RemoteClientError.notConnected)
            }
        }
        return client.controlScreenStream(
            displayID: displayID,
            windowID: windowID,
            resolution: resolution)
    }

    func sendMacControl(_ command: RemoteInputSender.Command) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        let json = try JSONSerialization.data(withJSONObject: Self.controlBody(for: command))
        _ = try await client.sendControlPayload(json)
    }

    func sendMacControlBatch(_ commands: [RemoteInputSender.Command]) async throws -> RemoteAcceptedResponse {
        guard let client else { throw RemoteClientError.notConnected }
        guard !commands.isEmpty else { throw RemoteClientError.invalidResponse }
        let json = try JSONSerialization.data(
            withJSONObject: ["commands": commands.map(Self.controlBody(for:))])
        return try await client.sendControlPayload(json)
    }

    static func controlBody(for command: RemoteInputCommand) -> [String: Any] {
        command.wireBody()
    }

    func controlAudio() -> AsyncThrowingStream<RemoteMacAudioChunk, Error> {
        guard let client else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RemoteClientError.notConnected)
            }
        }
        return client.controlAudio()
    }

    func openTerminal(cols: Int = 80, rows: Int = 24) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        _ = try await client.openTerminal(cols: cols, rows: rows)
    }

    func sendTerminalInput(_ data: Data) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        _ = try await client.sendTerminalInput(data)
    }

    func resizeTerminal(cols: Int, rows: Int) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        _ = try await client.resizeTerminal(cols: cols, rows: rows)
    }

    func closeTerminal() async throws {
        guard let client else { throw RemoteClientError.notConnected }
        _ = try await client.closeTerminal()
    }

    func terminalOutput() -> AsyncThrowingStream<Data, Error> {
        guard let client else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RemoteClientError.notConnected)
            }
        }
        return client.terminalOutput()
    }

    func select(_ session: RemoteSessionSummary) async {
        await select(sessionID: session.id)
    }

    func select(sessionID: UUID) async {
        guard let client else { return }
        sessionStreamTask?.cancel()
        sessionStreamTask = nil
        selectedSession = nil
        do {
            let detail = try await client.session(sessionID)
            selectedSession = detail
            RemoteNotificationCenter.shared.observeDetail(detail, computerName: activeComputerName)
            autoMode = detail.agentMode != "goal"
            fullAccess = detail.fullAccess ?? false
            startSessionStream(id: sessionID)
        }
        catch { presentError("Couldn't open session", error) }
    }

    func loadStartModels() async {
        guard let client else { return }
        do { startModels = try await client.models().models }
        catch { presentError("Couldn't load models", error) }
    }

    func startBotRun(profileID: String, modelID: String?, prompt: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.startBotRun(profileID: profileID, modelID: modelID, prompt: prompt)
            try await refresh()
            return true
        } catch { presentError("Couldn't start bot", error); return false }
    }

    func steerBotRun(_ id: UUID, message: String) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.steerBotRun(id, message: message); try await refresh(); return true }
        catch { presentError("Couldn't steer bot", error); return false }
    }

    func stopBotRun(_ id: UUID) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.stopBotRun(id); try await refresh(); return true }
        catch { presentError("Couldn't stop bot", error); return false }
    }

    func orchestrateBots(modelID: String?, prompt: String) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.orchestrateBots(modelID: modelID, prompt: prompt); try await refresh(); return true }
        catch { presentError("Couldn't start workflow", error); return false }
    }

    func approveBotRun(_ id: UUID, approved: Bool) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.approveBotRun(id, approved: approved); try await refresh(); return true }
        catch { presentError("Couldn't respond to approval", error); return false }
    }

    func answerBotRun(_ id: UUID, answer: String) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.answerBotRun(id, answer: answer); try await refresh(); return true }
        catch { presentError("Couldn't answer bot", error); return false }
    }

    func resumeBotRun(_ id: UUID) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.resumeBotRun(id); try await refresh(); return true }
        catch { presentError("Couldn't resume bot", error); return false }
    }

    func botComputers() async -> RemoteBotComputerEnvelope? {
        guard let client else { return nil }
        do { return try await client.botComputers() }
        catch let error as RemoteClientError {
            // Older BeetCode hosts predate bot-computer endpoints. The bot
            // gallery is still useful on those hosts; leave the workspace
            // section empty instead of presenting a blocking "Unknown
            // endpoint" alert as soon as the Bots button is tapped.
            if case .server(let message) = error,
               message.localizedCaseInsensitiveContains("unknown endpoint") ||
               message.localizedCaseInsensitiveContains("bot computer endpoint") {
                return nil
            }
            presentError("Couldn't load bots", error)
            return nil
        }
        catch { presentError("Couldn't load bots", error); return nil }
    }

    func saveAPIKey(providerID: String, key: String) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.saveAPIKey(providerID: providerID, key: key); return true }
        catch { presentError("Couldn't save key", error); return false }
    }

    func startBotComputer(_ id: UUID) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.startBotComputer(id); return true }
        catch { presentError("Couldn't start bot", error); return false }
    }

    func stopBotComputer(_ id: UUID) async -> Bool {
        guard let client else { return false }
        do { _ = try await client.stopBotComputer(id); return true }
        catch { presentError("Couldn't stop bot", error); return false }
    }

    func prepareBotComputers(profileID: String? = nil) async -> [RemoteBotComputer] {
        guard let client else { return [] }
        do {
            let envelope = try await client.prepareBotComputers(profileID: profileID)
            return envelope.computers
        } catch {
            presentError("Couldn't prepare bot computer", error)
            return []
        }
    }

    func startSession(
        modelID: String,
        message: String,
        botProfileID: String? = nil,
        botComputerID: UUID? = nil,
        workspacePath: String? = nil,
        chatOnly: Bool = false
    ) async -> UUID? {
        guard let client else { return nil }
        do {
            let response = try await client.startSession(
                modelID: modelID,
                message: message,
                autoMode: autoMode,
                fullAccess: fullAccess,
                reasoningEffort: reasoningEffort,
                botProfileID: botProfileID,
                botComputerID: botComputerID,
                workspacePath: workspacePath,
                chatOnly: chatOnly)
            guard let sessionID = response.sessionID else {
                throw RemoteClientError.invalidResponse
            }
            try await refresh()
            await select(sessionID: sessionID)
            return sessionID
        } catch { presentError("Couldn't start", error) }
        return nil
    }

    func loadWorkspaces() async {
        guard let client else { return }
        do {
            let envelope = try await client.workspaces()
            workspaces = envelope.workspaces
            workspaceCreateParent = envelope.createParent
            workspacesSupported = true
        } catch let error as RemoteClientError {
            if Self.isCancellation(error) { return }
            if case .server(let message) = error,
               message.localizedCaseInsensitiveContains("unknown endpoint") ||
               message.contains("(404)") {
                workspacesSupported = false
                workspaces = []
                return
            }
            presentError("Couldn't load folders", error)
        } catch {
            if Self.isCancellation(error) { return }
            presentError("Couldn't load folders", error)
        }
    }

    func createWorkspace(name: String) async -> RemoteWorkspace? {
        guard let client else { return nil }
        do {
            let created = try await client.createWorkspace(name: name, parentPath: workspaceCreateParent)
            await loadWorkspaces()
            return workspaces.first(where: { $0.path == created.path })
                ?? RemoteWorkspace(path: created.path, name: created.name, isCurrent: true)
        } catch {
            presentError("Couldn't create folder", error)
            return nil
        }
    }

    func openWorkspace(path: String) async -> RemoteWorkspace? {
        guard let client else { return nil }
        do {
            let opened = try await client.openWorkspace(path: path)
            await loadWorkspaces()
            return workspaces.first(where: { $0.path == opened.path })
                ?? RemoteWorkspace(path: opened.path, name: opened.name, isCurrent: true)
        } catch {
            presentError("Couldn't open folder", error)
            return nil
        }
    }

    func send(_ text: String, modelID: String? = nil, action: String? = nil) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let client, let id = selectedSession?.id else { return false }
        do {
            _ = try await client.send(
                message,
                to: id,
                autoMode: autoMode,
                fullAccess: fullAccess,
                reasoningEffort: reasoningEffort,
                modelID: modelID,
                action: action)
            return true
        } catch {
            presentError("Couldn't send", error)
            return false
        }
    }

    func cancelQueuedTask(_ taskID: UUID) async {
        guard let client, let id = selectedSession?.id else { return }
        do {
            _ = try await client.cancelQueuedTask(taskID, sessionID: id) as RemoteAcceptedResponse
        } catch {
            presentError("Couldn't remove follow-up", error)
        }
    }

    func stop() async {
        guard let client, let id = selectedSession?.id else { return }
        do { _ = try await client.stop(id) as RemoteAcceptedResponse }
        catch { presentError("Couldn't stop", error) }
    }

    func resolvePending(_ value: String) async {
        guard let client, let detail = selectedSession, let pending = detail.pending else { return }
        do {
            try await client.resolve(pending, sessionID: detail.id, value: value)
            selectedSession = try await client.session(detail.id)
        } catch { presentError("Couldn't continue", error) }
    }

    func revoke() async {
        if let client { try? await client.revoke() }
        forgetSavedMac()
    }

    func forgetSavedMac() {
        guard let activeComputerID else {
            clearActiveConnection()
            return
        }
        RemoteTokenStore.clear(computerID: activeComputerID)
        pairedComputers.removeAll { $0.id == activeComputerID }
        self.activeComputerID = pairedComputers.first?.id
        saveComputerProfiles()
        clearActiveConnection()
        if let nextID = self.activeComputerID {
            activateComputer(nextID, connect: false)
            Task { await connectSaved(showFailure: false) }
        }
    }

    func switchComputer(to id: UUID) async {
        guard pairedComputers.contains(where: { $0.id == id }) else { return }
        activateComputer(id, connect: false)
        await connectSaved()
    }

    func renameComputer(_ id: UUID, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = pairedComputers.firstIndex(where: { $0.id == id }) else { return }
        pairedComputers[index].name = cleaned
        saveComputerProfiles()
    }

    func removeComputer(_ id: UUID) {
        if id == activeComputerID {
            forgetSavedMac()
            return
        }
        RemoteTokenStore.clear(computerID: id)
        pairedComputers.removeAll { $0.id == id }
        saveComputerProfiles()
    }

    private func clearActiveConnection() {
        pollingTask?.cancel()
        pollingTask = nil
        sessionStreamTask?.cancel()
        sessionStreamTask = nil
        connectionAvailable = false
        token = nil
        sessions = []
        startModels = []
        sharedFiles = []
        workspaces = []
        selectedSession = nil
        connectionLabel = "Disconnected"
        baseURL = nil
    }

    func loadSharing() async {
        guard let client else { return }
        isSharing = true
        defer { isSharing = false }
        do { sharedFiles = try await client.sharedFiles().files }
        catch { presentError("Couldn't load files", error) }
    }

    func copyMacClipboard() async -> String? {
        guard let client else { return nil }
        isSharing = true
        defer { isSharing = false }
        do { return try await client.clipboard().text }
        catch { presentError("Couldn't copy clipboard", error); return nil }
    }

    func sendClipboardToMac(_ text: String) async -> Bool {
        guard let client, !text.isEmpty else { return false }
        isSharing = true
        defer { isSharing = false }
        do { _ = try await client.setClipboard(text); return true }
        catch { presentError("Couldn't send clipboard", error); return false }
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
        } catch { presentError("Couldn't upload", error); return false }
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
        } catch { presentError("Couldn't download", error); return nil }
    }

    private func presentError(_ title: String, _ error: Error) {
        if Self.isCancellation(error) { return }
        errorTitle = title
        errorMessage = error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return error.localizedDescription.localizedCaseInsensitiveCompare("cancelled") == .orderedSame
    }

    private var client: RemoteAPIClient? {
        guard let baseURL, let token else { return nil }
        return RemoteAPIClient(baseURL: baseURL, token: token)
    }

    private func activateComputer(_ id: UUID, connect: Bool) {
        guard let computer = pairedComputers.first(where: { $0.id == id }) else { return }
        pollingTask?.cancel()
        sessionStreamTask?.cancel()
        sessions = []
        selectedSession = nil
        startModels = []
        sharedFiles = []
        connectionAvailable = false
        connectionLabel = connect ? "Connecting…" : "Disconnected"
        activeComputerID = id
        baseURL = computer.baseURL
        token = RemoteTokenStore.load(computerID: id)
        saveComputerProfiles()
    }

    private func restoreComputerProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "pairedBeetCodeComputers"),
           let computers = try? JSONDecoder().decode([PairedBeetCodeComputer].self, from: data),
           !computers.isEmpty {
            pairedComputers = computers
            let savedID = defaults.string(forKey: "activeBeetCodeComputerID").flatMap(UUID.init(uuidString:))
            let selectedID = computers.contains(where: { $0.id == savedID }) ? savedID : computers.first?.id
            if let selectedID { activateComputer(selectedID, connect: false) }
            return
        }

        // One-time migration from the original single-Mac storage.
        if let address = defaults.string(forKey: "remoteBaseURL"),
           let url = URL(string: address),
           let legacyToken = RemoteTokenStore.loadLegacy() {
            let computer = PairedBeetCodeComputer(baseURL: url)
            try? RemoteTokenStore.save(legacyToken, computerID: computer.id)
            pairedComputers = [computer]
            activeComputerID = computer.id
            baseURL = url
            token = legacyToken
            saveComputerProfiles()
            RemoteTokenStore.clearLegacy()
            defaults.removeObject(forKey: "remoteBaseURL")
        }
    }

    private func saveComputerProfiles() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(pairedComputers) {
            defaults.set(data, forKey: "pairedBeetCodeComputers")
        }
        defaults.set(activeComputerID?.uuidString, forKey: "activeBeetCodeComputerID")
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

    private func startSessionStream(id: UUID) {
        guard let client else { return }
        sessionStreamTask?.cancel()
        sessionStreamTask = Task { [weak self] in
            var retryDelay = Duration.milliseconds(300)
            while !Task.isCancelled {
                guard let self, self.selectedSession?.id == id else { return }
                do {
                    for try await detail in client.sessionEvents(id) {
                        guard !Task.isCancelled, self.selectedSession?.id == id else { return }
                        self.selectedSession = detail
                        RemoteNotificationCenter.shared.observeDetail(
                            detail,
                            computerName: self.activeComputerName)
                        retryDelay = .milliseconds(300)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                }
                try? await Task.sleep(for: retryDelay)
                retryDelay = .seconds(2)
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
