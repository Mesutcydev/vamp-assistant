import Foundation
import Observation

struct PairedBeetCodeComputer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseURL: URL
    var tokenExpiresAt: Date?
    var networkKind: String?

    init(
        id: UUID = UUID(),
        name: String? = nil,
        baseURL: URL,
        tokenExpiresAt: Date? = nil,
        networkKind: String? = nil
    ) {
        self.id = id
        self.name = name ?? baseURL.host ?? "Vamp Assistant Mac"
        self.baseURL = baseURL
        self.tokenExpiresAt = tokenExpiresAt
        self.networkKind = networkKind
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
    /// Failure text for loads the user did not explicitly ask for. Rendered
    /// inline next to whatever is missing rather than as an alert.
    var backgroundNotice: String?
    private(set) var pairedComputers: [PairedBeetCodeComputer] = []
    private(set) var activeComputerID: UUID?
    private(set) var requiresPairing = false

    private(set) var baseURL: URL?
    private var token: String?
    private var pollingTask: Task<Void, Never>?
    private var sessionStreamTask: Task<Void, Never>?
    private enum SessionStreamPhase: Equatable {
        case stopped
        case connecting
        case connected
        case reconnecting
    }
    private var sessionStreamPhase: SessionStreamPhase = .stopped
    private var sessionStreamLastActivity: Date?
    private var selectedSessionRevision: UInt64?
    private var refreshTask: Task<Void, Error>?
    /// Prevent an approval toggle and a button tap (or two rapid taps) from
    /// resolving the same server request twice. A duplicate resolve races the
    /// SSE snapshot and used to make the pending card flash back into view.
    private var resolvingPendingKeys: Set<String> = []
    /// The request currently being resolved by this phone. The value remains
    /// set until the live session stream confirms that the pending interaction
    /// changed, so an older SSE snapshot renders a stable disabled card
    /// instead of making the approval UI disappear and reappear.
    private(set) var resolvingPendingKey: String?
    private var connectionAvailable = false
    private var consecutivePollingFailures = 0
    private var pollIdleSeconds: Int = 4

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

    var hasSavedConnection: Bool { baseURL != nil && token != nil && !requiresPairing }
    var isConnected: Bool { hasSavedConnection && connectionAvailable }
    var isMacReachable: Bool { isConnected }
    var connectionSubtitle: String {
        if isConnected {
            switch activeComputer?.networkKind {
            case "tailscale": return "Private over Tailscale"
            case "localNetwork": return "Local network · HTTP"
            default: return "Connected directly to your Mac"
            }
        }
        if requiresPairing { return "Enter the new code shown on your Mac" }
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

    func isResolvingPending(_ pending: RemotePendingInteraction, sessionID: UUID) -> Bool {
        guard let requestID = pending.requestID else { return false }
        return resolvingPendingKey == "\(sessionID.uuidString):\(requestID)"
    }

    func restore() async {
        guard hasSavedConnection else { return }
        await connectSaved(showFailure: false)
    }

    func connectSaved(showFailure: Bool = true) async {
        guard baseURL != nil, token != nil else { return }
        if requiresPairing || activeComputer?.tokenExpiresAt.map({ $0 <= Date() }) == true {
            markPairingRequired(
                "This Mac's access token expired. Enter the new pairing code shown on the Mac.",
                showAlert: showFailure)
            return
        }
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
            if handleAuthenticationError(error, showAlert: showFailure) { return }
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
            var computer = pairedComputers.first { $0.baseURL == parsed.url }
                ?? PairedBeetCodeComputer(baseURL: parsed.url)
            computer.tokenExpiresAt = Date(timeIntervalSince1970: response.expiresAt)
            try RemoteTokenStore.save(response.token, computerID: computer.id)
            if let index = pairedComputers.firstIndex(where: { $0.id == computer.id }) {
                pairedComputers[index] = computer
            } else {
                pairedComputers.append(computer)
            }
            activeComputerID = computer.id
            baseURL = parsed.url
            token = response.token
            requiresPairing = false
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
        noteIdleTick(changed: sessions != nextList.sessions)
        sessions = nextList.sessions
        // Bot runs were added after the original paired-session protocol;
        // an older Mac must remain usable instead of failing the whole refresh.
        botRuns = (try? await client.botRuns())?.runs ?? []
        RemoteNotificationCenter.shared.observeSessions(
            nextList.sessions,
            computerName: activeComputerName)
        updateActiveComputer(
            networkKind: nextStatus.networkKind,
            tokenExpiresAt: nextStatus.tokenExpiresAt.map { Date(timeIntervalSince1970: $0) })
        connectionLabel = nextStatus.isRunning ? nextStatus.phase.capitalized : "Connected"
        if let id = selectedSession?.id,
           sessions.contains(where: { $0.id == id }) {
            if !isSessionStreamHealthy(for: id) {
                applySessionDetail(try await client.session(id))
            }
            if sessionStreamTask == nil { startSessionStream(id: id) }
        } else if selectedSession != nil {
            sessionStreamTask?.cancel()
            sessionStreamTask = nil
            sessionStreamPhase = .stopped
            sessionStreamLastActivity = nil
            selectedSessionRevision = nil
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

    func launchMacControlApplication(
        bundleIdentifier: String,
        viewportAspect: Double
    ) async throws -> RemoteMacApplication {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.launchControlApplication(
            bundleIdentifier: bundleIdentifier,
            clientViewportAspect: viewportAspect).application
    }

    func resizeMacControlApplication(
        windowID: UInt32,
        viewportAspect: Double
    ) async throws -> RemoteMacApplication {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.resizeControlApplication(
            windowID: windowID,
            clientViewportAspect: viewportAspect).application
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
        _ = try await client.sendControl(Self.controlBody(for: command))
    }

    func sendMacControlBatch(_ commands: [RemoteInputSender.Command]) async throws -> RemoteAcceptedResponse {
        guard let client else { throw RemoteClientError.notConnected }
        guard !commands.isEmpty else { throw RemoteClientError.invalidResponse }
        return try await client.sendControlBatch(commands.map(Self.controlBody(for:)))
    }

    func unlockMac(password: String) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        guard !password.isEmpty, password.count <= 256 else {
            throw RemoteClientError.server("Enter a login password between 1 and 256 characters.")
        }
        _ = try await client.unlockMac(password: password)
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
        sessionStreamPhase = .stopped
        sessionStreamLastActivity = nil
        selectedSessionRevision = nil
        resolvingPendingKeys.removeAll()
        resolvingPendingKey = nil
        selectedSession = nil
        do {
            let detail = try await client.session(sessionID)
            applySessionDetail(detail)
            RemoteNotificationCenter.shared.observeDetail(detail, computerName: activeComputerName)
            autoMode = detail.agentMode != "goal"
            fullAccess = detail.fullAccess ?? false
            startSessionStream(id: sessionID)
        }
        catch { presentError("Couldn't open session", error) }
    }

    func loadStartModels() async {
        guard let client else { return }
        do {
            startModels = try await client.models().models
            backgroundNotice = nil
        }
        catch { presentError("Couldn't load models", error, background: true) }
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

    // MARK: Bot console
    //
    // These throw rather than presenting an alert: the console shows its own inline error, and a
    // mistyped shell command is not worth a modal.

    func execInBotComputer(_ id: UUID, command: String) async throws -> String {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.execInBotComputer(id, command: command).output
    }

    func botComputerFiles(_ id: UUID, path: String) async throws -> [RemoteBotWorkspaceEntry] {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.botComputerFiles(id, path: path).entries
    }

    func botComputerFile(_ id: UUID, path: String) async throws -> String {
        guard let client else { throw RemoteClientError.notConnected }
        return try await client.botComputerFile(id, path: path).contents
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
            presentError("Couldn't load bots", error, background: true)
            return nil
        }
        catch { presentError("Couldn't load bots", error, background: true); return nil }
    }

    /// Hard delete on the Mac, mirroring its own sidebar. The server refuses
    /// while that chat is still answering, so the phone surfaces that as an
    /// error rather than pre-guessing state it polls at two-second intervals.
    func deleteSession(_ id: UUID) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.deleteSession(id)
            sessions.removeAll { $0.id == id }
            return true
        }
        catch { presentError("Couldn't delete the chat", error); return false }
    }

    func renameSession(_ id: UUID, title: String) async -> Bool {
        guard let client else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await client.renameSession(id, title: trimmed)
            try? await refresh()
            return true
        }
        catch { presentError("Couldn't rename the chat", error); return false }
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

    /// Keeps a currently running Mac loop in sync with the companion's
    /// Auto/Full Access controls. Idle sessions carry the same values on their
    /// next message, so no extra request is needed in that state.
    func updateRunOptionsIfNeeded() async {
        guard let client,
              let detail = selectedSession,
              detail.isRunning else { return }
        do {
            _ = try await client.updateSessionOptions(
                detail.id,
                autoMode: autoMode,
                fullAccess: fullAccess)
        } catch {
            presentError("Couldn't update access mode", error, background: true)
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

    func undoCheckpoint() async {
        guard let client, let id = selectedSession?.id else { return }
        do {
            _ = try await client.undoCheckpoint(id) as RemoteAcceptedResponse
            try? await refresh()
        } catch {
            presentError("Couldn't restore the checkpoint", error)
        }
    }

    func resolvePending(_ value: String) async {
        guard let client, let detail = selectedSession, let pending = detail.pending else { return }
        guard let requestID = pending.requestID else { return }
        let key = "\(detail.id.uuidString):\(requestID)"
        guard resolvingPendingKeys.insert(key).inserted else { return }
        resolvingPendingKey = key
        var responseAccepted = false
        defer {
            resolvingPendingKeys.remove(key)
            // Keep the visual lock until SSE (or the fallback detail request)
            // confirms the old interaction is gone. On a failed POST it is
            // safe to make the controls interactive again immediately.
            if !responseAccepted, resolvingPendingKey == key {
                resolvingPendingKey = nil
            }
        }
        // The event stream is the source of truth while a session is open.
        // Fetching a detail immediately after POST can win the race with an
        // in-flight SSE snapshot and briefly restore the old pending state.
        let hasHealthyStream = isSessionStreamHealthy(for: detail.id)
        do {
            try await client.resolve(
                pending,
                sessionID: detail.id,
                value: value,
                autoMode: autoMode,
                fullAccess: fullAccess)
            responseAccepted = true
            if hasHealthyStream {
                // Give the normal live event the first chance to land. A
                // revisioned GET then repairs a stalled-but-not-yet-closed SSE
                // connection without allowing an older event to win later.
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard selectedSession?.id == detail.id,
                  resolvingPendingKey == key else { return }
            let updated = try await client.session(detail.id)
            if applySessionDetail(updated) {
                reconcilePendingResolution(with: updated)
            }
        } catch { presentError("Couldn't continue", error) }
    }

    @discardableResult
    func revoke() async -> Bool {
        guard let client else {
            forgetSavedMac()
            return true
        }
        do {
            try await client.revoke()
            forgetSavedMac()
            return true
        } catch {
            presentError("Couldn't unpair this Mac", error)
            return false
        }
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
        sessionStreamPhase = .stopped
        sessionStreamLastActivity = nil
        selectedSessionRevision = nil
        connectionAvailable = false
        token = nil
        requiresPairing = false
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

    // ponytail: `background: true` reports inline instead of throwing a modal.
    // A blocking alert for a poll or prefetch failure interrupts whatever the
    // user is doing, and the reconnect banner already explains the usual cause.
    private func presentError(_ title: String, _ error: Error, background: Bool = false) {
        if Self.isCancellation(error) { return }
        if background {
            backgroundNotice = "\(title). \(error.localizedDescription)"
            return
        }
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
        sessionStreamTask = nil
        sessionStreamPhase = .stopped
        sessionStreamLastActivity = nil
        selectedSessionRevision = nil
        sessions = []
        selectedSession = nil
        startModels = []
        sharedFiles = []
        connectionAvailable = false
        connectionLabel = connect ? "Connecting…" : "Disconnected"
        activeComputerID = id
        baseURL = computer.baseURL
        token = RemoteTokenStore.load(computerID: id)
        requiresPairing = computer.tokenExpiresAt.map { $0 <= Date() } == true
        if requiresPairing { connectionLabel = "Pair again" }
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

    /// Grows while the session list stays unchanged and resets the moment
    /// anything moves, so a phone left on the list screen stops waking every
    /// two seconds without ever feeling stale when it matters.
    private func noteIdleTick(changed: Bool) {
        if changed {
            pollIdleSeconds = 4
        } else {
            pollIdleSeconds = min(30, pollIdleSeconds + 2)
        }
    }

    private func saveComputerProfiles() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(pairedComputers) {
            defaults.set(data, forKey: "pairedBeetCodeComputers")
        }
        defaults.set(activeComputerID?.uuidString, forKey: "activeBeetCodeComputerID")
    }

    private func updateActiveComputer(networkKind: String, tokenExpiresAt: Date?) {
        guard let activeComputerID,
              let index = pairedComputers.firstIndex(where: { $0.id == activeComputerID }) else { return }
        var computer = pairedComputers[index]
        let previous = computer
        computer.networkKind = networkKind
        if let tokenExpiresAt { computer.tokenExpiresAt = tokenExpiresAt }
        guard computer != previous else { return }
        pairedComputers[index] = computer
        saveComputerProfiles()
    }

    private func handleAuthenticationError(_ error: Error, showAlert: Bool) -> Bool {
        guard let clientError = error as? RemoteClientError,
              clientError.requiresPairing else { return false }
        markPairingRequired(
            "This Mac no longer accepts the saved access token. Enter the new pairing code shown on the Mac.",
            showAlert: showAlert)
        return true
    }

    private func markPairingRequired(_ message: String, showAlert: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        sessionStreamTask?.cancel()
        sessionStreamTask = nil
        sessionStreamPhase = .stopped
        sessionStreamLastActivity = nil
        selectedSessionRevision = nil
        connectionAvailable = false
        requiresPairing = true
        connectionLabel = "Pair again"
        sessions = []
        selectedSession = nil
        if showAlert {
            errorTitle = "Pair again"
            errorMessage = message
        }
    }

    /// Poll cadence. Two seconds is right while something is actually happening
    /// on the Mac, and wasteful when nothing is — this used to run at 2s
    /// forever, which is a battery cost on the device least able to afford it.
    /// Any running session, or a session the user is looking at, keeps it fast.
    private var pollInterval: Duration {
        if selectedSession != nil { return .seconds(2) }
        if sessions.contains(where: \.isRunning) { return .seconds(2) }
        return .seconds(pollIdleSeconds)
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.pollInterval ?? .seconds(2) }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                do { try await self?.refresh() }
                catch {
                    guard let self else { return }
                    if self.handleAuthenticationError(error, showAlert: false) { return }
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
        sessionStreamPhase = .connecting
        sessionStreamLastActivity = nil
        sessionStreamTask = Task { [weak self] in
            var retryDelay = Duration.milliseconds(300)
            while !Task.isCancelled {
                guard let self, self.selectedSession?.id == id else { return }
                do {
                    for try await event in client.sessionEvents(id) {
                        guard !Task.isCancelled, self.selectedSession?.id == id else { return }
                        self.sessionStreamPhase = .connected
                        self.sessionStreamLastActivity = Date()
                        switch event {
                        case .heartbeat:
                            continue
                        case .snapshot(let detail):
                            guard self.applySessionDetail(detail) else { continue }
                            self.reconcilePendingResolution(with: detail)
                            RemoteNotificationCenter.shared.observeDetail(
                                detail,
                                computerName: self.activeComputerName)
                            retryDelay = .milliseconds(300)
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if self.handleAuthenticationError(error, showAlert: false) { return }
                }
                self.sessionStreamPhase = .reconnecting
                self.sessionStreamLastActivity = nil
                try? await Task.sleep(for: retryDelay)
                retryDelay = .seconds(2)
            }
        }
    }

    @discardableResult
    private func applySessionDetail(_ detail: RemoteSessionDetail) -> Bool {
        guard selectedSession == nil || selectedSession?.id == detail.id else { return false }
        guard Self.shouldAcceptSessionRevision(
            current: selectedSessionRevision,
            incoming: detail.revision
        ) else { return false }
        selectedSessionRevision = detail.revision ?? selectedSessionRevision
        selectedSession = detail
        return true
    }

    /// Versionless snapshots are accepted for older Mac hosts. Once both sides
    /// provide revisions, an in-flight older event may never overwrite newer
    /// state fetched after an approval or reconnect.
    nonisolated static func shouldAcceptSessionRevision(
        current: UInt64?,
        incoming: UInt64?
    ) -> Bool {
        guard let current, let incoming else { return true }
        return incoming >= current
    }

    private func isSessionStreamHealthy(for id: UUID) -> Bool {
        guard sessionStreamTask != nil,
              selectedSession?.id == id,
              sessionStreamPhase == .connected,
              let lastActivity = sessionStreamLastActivity else { return false }
        // The Mac emits a heartbeat every ~6 seconds. A 15-second deadline
        // tolerates scheduling jitter while letting ordinary polling repair a
        // half-open URLSession stream promptly.
        return Date().timeIntervalSince(lastActivity) < 15
    }

    private func reconcilePendingResolution(with detail: RemoteSessionDetail) {
        guard let key = resolvingPendingKey else { return }
        let currentKey = detail.pending?.requestID.map { "\(detail.id.uuidString):\($0)" }
        if currentKey != key {
            resolvingPendingKey = nil
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
