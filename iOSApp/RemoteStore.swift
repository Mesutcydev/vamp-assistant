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
    let drafts: RemoteDraftStore
    private var temporaryDrafts: [UUID: String] = [:]
    var sessions: [RemoteSessionSummary] = []
    var selectedSession: RemoteSessionDetail?
    var startModels: [RemoteStartModelOption] = []
    var botRuns: [RemoteBotRun] = []
    var sharedFiles: [RemoteSharedFileItem] = []
    var isConnecting = false
    var isRefreshing = false
    private(set) var isUpdatingAccess = false
    var isSharing = false
    var errorMessage: String?
    var errorTitle = "Couldn't complete that"
    private(set) var hostStatus: RemoteStatus?
    private(set) var lastConnectedAt: Date?
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
    private var refreshID: UUID?
    private var connectionGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var requestedSessionID: UUID?
    private let connectionStorage: any RemoteConnectionPersisting
    private let apiSession: URLSession?
    private let observesNotifications: Bool
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
    private(set) var sendingSessionIDs: Set<UUID> = []

    init(
        connectionStorage: any RemoteConnectionPersisting = RemoteConnectionStorage(),
        apiSession: URLSession? = nil,
        observesNotifications: Bool = true,
        drafts: RemoteDraftStore = RemoteDraftStore()
    ) {
        self.drafts = drafts
        self.connectionStorage = connectionStorage
        self.apiSession = apiSession
        self.observesNotifications = observesNotifications
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

    subscript(draftFor sessionID: UUID) -> String {
        get {
            guard let activeComputerID else { return temporaryDrafts[sessionID] ?? "" }
            return drafts[activeComputerID, sessionID]
        }
        set {
            if let activeComputerID { drafts[activeComputerID, sessionID] = newValue }
            else { temporaryDrafts[sessionID] = newValue }
        }
    }

    /// Deliberate allowlist: never include addresses, tokens, computer names,
    /// workspace paths, prompts, clipboard contents, or raw server errors.
    var connectionDiagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let network: String
        switch activeComputer?.networkKind {
        case "tailscale": network = "Tailscale"
        case "localNetwork": network = "Local network"
        default: network = "Unknown"
        }
        return """
        Vamp Assistant connection diagnostics
        Client: \(version) (\(build))
        Host: \(hostStatus?.appVersion ?? "unreported") (\(hostStatus?.appBuild ?? "unreported"))
        Protocol: \(hostStatus?.protocolVersion.map(String.init) ?? "legacy")
        Connected: \(isConnected)
        Pairing required: \(requiresPairing)
        Network: \(network)
        Stream: \(String(describing: sessionStreamPhase))
        Consecutive refresh failures: \(consecutivePollingFailures)
        Last successful refresh: \(lastConnectedAt?.ISO8601Format() ?? "none")
        """
    }

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
        let generation = connectionGeneration
        if requiresPairing || activeComputer?.tokenExpiresAt.map({ $0 <= Date() }) == true {
            markPairingRequired(
                "This Mac's access token expired. Enter the new pairing code shown on the Mac.",
                showAlert: showFailure)
            return
        }
        isConnecting = true
        if showFailure { errorMessage = nil }
        defer { if generation == connectionGeneration { isConnecting = false } }
        do {
            try await refresh()
            try requireConnection(generation)
            connectionAvailable = true
            connectionLabel = "Connected"
            consecutivePollingFailures = 0
            startPolling()
        } catch {
            guard isCurrentConnection(generation) else { return }
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
        invalidateConnectionWork()
        let generation = connectionGeneration
        isConnecting = true
        errorMessage = nil
        defer { if generation == connectionGeneration { isConnecting = false } }
        do {
            let parsed = try Self.parse(address: address, explicitCode: code)
            let response = try await RemoteAPIClient(baseURL: parsed.url, session: apiSession).pair(code: parsed.code)
            try requireConnection(generation)
            var computer = pairedComputers.first { $0.baseURL == parsed.url }
                ?? PairedBeetCodeComputer(baseURL: parsed.url)
            computer.tokenExpiresAt = Date(timeIntervalSince1970: response.expiresAt)
            try connectionStorage.saveToken(response.token, for: computer.id)
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
            do {
                try await refresh()
                try requireConnection(generation)
                connectionLabel = "Connected"
            } catch {
                try requireConnection(generation)
                connectionLabel = "Reconnecting…"
                backgroundNotice = "Pairing succeeded. Reconnecting to load your Mac…"
            }
            startPolling()
            if observesNotifications { await RemoteNotificationCenter.shared.requestPermission() }
            return true
        } catch {
            guard isCurrentConnection(generation) else { return false }
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
        let generation = connectionGeneration
        let id = UUID()
        refreshID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRefresh(generation: generation)
        }
        refreshTask = task
        defer {
            if refreshID == id {
                refreshTask = nil
                refreshID = nil
                isRefreshing = false
            }
        }
        try await task.value
    }

    private func performRefresh(generation: UInt64) async throws {
        guard let client else { throw RemoteClientError.notConnected }
        async let status = client.status()
        async let list = client.sessions()
        let (nextStatus, nextList) = try await (status, list)
        try requireConnection(generation)
        if let version = nextStatus.protocolVersion, version != 1 {
            throw RemoteClientError.server("This Mac uses remote protocol \(version). Update both Vamp Assistant apps to compatible versions.")
        }
        let nextBotRuns = (try? await client.botRuns())?.runs ?? []
        try requireConnection(generation)
        hostStatus = nextStatus
        lastConnectedAt = Date()
        connectionAvailable = true
        consecutivePollingFailures = 0
        noteIdleTick(changed: sessions != nextList.sessions)
        sessions = nextList.sessions
        // Bot runs were added after the original paired-session protocol;
        // an older Mac must remain usable instead of failing the whole refresh.
        botRuns = nextBotRuns
        if observesNotifications {
            RemoteNotificationCenter.shared.observeSessions(nextList.sessions, computerName: activeComputerName, computerID: activeComputerID)
        }
        updateActiveComputer(
            networkKind: nextStatus.networkKind,
            tokenExpiresAt: nextStatus.tokenExpiresAt.map { Date(timeIntervalSince1970: $0) })
        connectionLabel = nextStatus.isRunning ? nextStatus.phase.capitalized : "Connected"
        if let id = selectedSession?.id,
           sessions.contains(where: { $0.id == id }) {
            if !isSessionStreamHealthy(for: id) {
                let selection = selectionGeneration
                let detail = try await client.session(id)
                try requireConnection(generation)
                guard selection == selectionGeneration else { return }
                applySessionDetail(detail)
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
        let generation = connectionGeneration
        selectionGeneration &+= 1
        let selection = selectionGeneration
        requestedSessionID = sessionID
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
            try requireConnection(generation)
            guard selection == selectionGeneration, applySessionDetail(detail) else { return }
            if observesNotifications {
                RemoteNotificationCenter.shared.observeDetail(detail, computerName: activeComputerName, computerID: activeComputerID)
            }
            autoMode = detail.agentMode != "goal"
            fullAccess = detail.fullAccess ?? false
            startSessionStream(id: sessionID)
        }
        catch {
            guard isCurrentConnection(generation), selection == selectionGeneration else { return }
            presentError("Couldn't open session", error)
        }
    }

    func loadStartModels() async {
        guard let client else { return }
        let generation = connectionGeneration
        do {
            let models = try await client.models().models
            try requireConnection(generation)
            startModels = models
            backgroundNotice = nil
        }
        catch {
            guard isCurrentConnection(generation) else { return }
            presentError("Couldn't load models", error, background: true)
        }
    }

    func startBotRun(profileID: String, modelID: String?, prompt: String) async -> Bool {
        await performMutation("Couldn't start bot") { client in
            _ = try await client.startBotRun(profileID: profileID, modelID: modelID, prompt: prompt)
        }
    }

    func steerBotRun(_ id: UUID, message: String) async -> Bool {
        await performMutation("Couldn't steer bot") { _ = try await $0.steerBotRun(id, message: message) }
    }

    func stopBotRun(_ id: UUID) async -> Bool {
        await performMutation("Couldn't stop bot") { _ = try await $0.stopBotRun(id) }
    }

    func orchestrateBots(modelID: String?, prompt: String) async -> Bool {
        await performMutation("Couldn't start workflow") { _ = try await $0.orchestrateBots(modelID: modelID, prompt: prompt) }
    }

    func approveBotRun(_ id: UUID, approved: Bool) async -> Bool {
        await performMutation("Couldn't respond to approval") { _ = try await $0.approveBotRun(id, approved: approved) }
    }

    func answerBotRun(_ id: UUID, answer: String) async -> Bool {
        await performMutation("Couldn't answer bot") { _ = try await $0.answerBotRun(id, answer: answer) }
    }

    func resumeBotRun(_ id: UUID) async -> Bool {
        await performMutation("Couldn't resume bot") { _ = try await $0.resumeBotRun(id) }
    }

    private func performMutation(
        _ errorTitle: String,
        action: (RemoteAPIClient) async throws -> Void
    ) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        do { try await action(client) }
        catch {
            guard isCurrentConnection(generation) else { return false }
            presentError(errorTitle, error)
            return false
        }
        guard isCurrentConnection(generation) else { return false }
        await refreshAfterAcceptance(generation: generation)
        return true
    }

    private func refreshAfterAcceptance(generation: UInt64) async {
        do { try await refresh() }
        catch {
            guard isCurrentConnection(generation) else { return }
            backgroundNotice = "Your Mac accepted the request. Updates are temporarily unavailable; pull to refresh."
        }
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
        let generation = connectionGeneration
        do {
            let result = try await client.botComputers()
            try requireConnection(generation)
            return result
        }
        catch let error as RemoteClientError {
            guard isCurrentConnection(generation) else { return nil }
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
        catch { guard isCurrentConnection(generation) else { return nil }; presentError("Couldn't load bots", error, background: true); return nil }
    }

    /// Hard delete on the Mac, mirroring its own sidebar. The server refuses
    /// while that chat is still answering, so the phone surfaces that as an
    /// error rather than pre-guessing state it polls at two-second intervals.
    func deleteSession(_ id: UUID) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        do {
            _ = try await client.deleteSession(id)
            try requireConnection(generation)
            sessions.removeAll { $0.id == id }
            return true
        }
        catch {
            guard isCurrentConnection(generation) else { return false }
 presentError("Couldn't delete the chat", error); return false }
    }

    func renameSession(_ id: UUID, title: String) async -> Bool {
        guard let client else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let generation = connectionGeneration
        do {
            _ = try await client.renameSession(id, title: trimmed)
            try requireConnection(generation)
            await refreshAfterAcceptance(generation: generation)
            return true
        }
        catch {
            guard isCurrentConnection(generation) else { return false }
 presentError("Couldn't rename the chat", error); return false }
    }

    func saveAPIKey(providerID: String, key: String) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        do { _ = try await client.saveAPIKey(providerID: providerID, key: key); try requireConnection(generation); return true }
        catch {
            guard isCurrentConnection(generation) else { return false }
 presentError("Couldn't save key", error); return false }
    }

    func startBotComputer(_ id: UUID) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        do { _ = try await client.startBotComputer(id); try requireConnection(generation); return true }
        catch {
            guard isCurrentConnection(generation) else { return false }
 presentError("Couldn't start bot", error); return false }
    }

    func stopBotComputer(_ id: UUID) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        do { _ = try await client.stopBotComputer(id); try requireConnection(generation); return true }
        catch {
            guard isCurrentConnection(generation) else { return false }
 presentError("Couldn't stop bot", error); return false }
    }

    func prepareBotComputers(profileID: String? = nil) async -> [RemoteBotComputer] {
        guard let client else { return [] }
        let generation = connectionGeneration
        do {
            let envelope = try await client.prepareBotComputers(profileID: profileID)
            try requireConnection(generation)
            return envelope.computers
        } catch {
            guard isCurrentConnection(generation) else { return [] }

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
        let generation = connectionGeneration
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
            try requireConnection(generation)
            await refreshAfterAcceptance(generation: generation)
            try requireConnection(generation)
            await select(sessionID: sessionID)
            return sessionID
        } catch {
            guard isCurrentConnection(generation) else { return nil }
            presentError("Couldn't start", error)
        }
        return nil
    }

    func loadWorkspaces() async {
        guard let client else { return }
        let generation = connectionGeneration
        do {
            let envelope = try await client.workspaces()
            try requireConnection(generation)
            workspaces = envelope.workspaces
            workspaceCreateParent = envelope.createParent
            workspacesSupported = true
        } catch let error as RemoteClientError {
            guard isCurrentConnection(generation) else { return }
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
            guard isCurrentConnection(generation) else { return }
            if Self.isCancellation(error) { return }
            presentError("Couldn't load folders", error)
        }
    }

    func createWorkspace(name: String) async -> RemoteWorkspace? {
        guard let client else { return nil }
        let generation = connectionGeneration
        do {
            let created = try await client.createWorkspace(name: name, parentPath: workspaceCreateParent)
            try requireConnection(generation)
            await loadWorkspaces()
            try requireConnection(generation)
            return workspaces.first(where: { $0.path == created.path })
                ?? RemoteWorkspace(path: created.path, name: created.name, isCurrent: true)
        } catch {
            guard isCurrentConnection(generation) else { return nil }
            presentError("Couldn't create folder", error)
            return nil
        }
    }

    func openWorkspace(path: String) async -> RemoteWorkspace? {
        guard let client else { return nil }
        let generation = connectionGeneration
        do {
            let opened = try await client.openWorkspace(path: path)
            try requireConnection(generation)
            await loadWorkspaces()
            try requireConnection(generation)
            return workspaces.first(where: { $0.path == opened.path })
                ?? RemoteWorkspace(path: opened.path, name: opened.name, isCurrent: true)
        } catch {
            guard isCurrentConnection(generation) else { return nil }
            presentError("Couldn't open folder", error)
            return nil
        }
    }

    func send(_ text: String, modelID: String? = nil, action: String? = nil, sessionID: UUID? = nil) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let client, let id = selectedSession?.id else { return false }
        guard sessionID == nil || sessionID == id, sendingSessionIDs.insert(id).inserted else { return false }
        let generation = connectionGeneration
        defer { if generation == connectionGeneration { sendingSessionIDs.remove(id) } }
        do {
            _ = try await client.send(
                message,
                to: id,
                autoMode: autoMode,
                fullAccess: fullAccess,
                reasoningEffort: reasoningEffort,
                modelID: modelID,
                action: action)
            try requireConnection(generation)
            return true
        } catch {
            guard isCurrentConnection(generation) else { return false }
            presentError("Couldn't send", error)
            return false
        }
    }

    /// Only called by an explicit user gesture. Loading a session must never
    /// grant access or answer an approval prompt as a side effect.
    func setAccessMode(autoMode requestedAuto: Bool? = nil, fullAccess requestedFull: Bool? = nil) async {
        guard !isUpdatingAccess, let client, let detail = selectedSession else { return }
        let generation = connectionGeneration
        isUpdatingAccess = true
        defer { if generation == connectionGeneration { isUpdatingAccess = false } }
        let selection = selectionGeneration
        let newAuto = requestedAuto ?? autoMode
        let newFull = requestedFull ?? fullAccess
        do {
            if detail.isRunning {
                _ = try await client.updateSessionOptions(detail.id, autoMode: newAuto, fullAccess: newFull)
            }
            try requireConnection(generation)
            guard selection == selectionGeneration else { return }
            autoMode = newAuto
            fullAccess = newFull
            // Existing approval cards remain explicit choices; the new mode
            // applies to subsequent tool requests and the next message.
        } catch {
            guard isCurrentConnection(generation), selection == selectionGeneration else { return }
            presentError("Couldn't update access mode", error)
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
        let generation = connectionGeneration
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
            try requireConnection(generation)
            responseAccepted = true
            if hasHealthyStream {
                // Give the normal live event the first chance to land. A
                // revisioned GET then repairs a stalled-but-not-yet-closed SSE
                // connection without allowing an older event to win later.
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard isCurrentConnection(generation), selectedSession?.id == detail.id,
                  resolvingPendingKey == key else { return }
            let updated = try await client.session(detail.id)
            try requireConnection(generation)
            if applySessionDetail(updated) {
                reconcilePendingResolution(with: updated)
            }
        } catch {
            guard isCurrentConnection(generation) else { return }
            if responseAccepted { backgroundNotice = "Your response was accepted. Reconnecting to update the conversation…" }
            else { presentError("Couldn't continue", error) }
        }
    }

    @discardableResult
    func revoke() async -> Bool {
        guard let client else {
            forgetSavedMac()
            return true
        }
        let generation = connectionGeneration
        do {
            try await client.revoke()
            try requireConnection(generation)
            forgetSavedMac()
            return true
        } catch {
            guard isCurrentConnection(generation) else { return false }
            presentError("Couldn't unpair this Mac", error)
            return false
        }
    }

    func forgetSavedMac() {
        guard let activeComputerID else {
            clearActiveConnection()
            return
        }
        connectionStorage.clearToken(for: activeComputerID)
        drafts.remove(computerID: activeComputerID)
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

    func openNotification(_ target: RemoteNotificationTarget) async -> Bool {
        if let computerID = target.computerID {
            guard pairedComputers.contains(where: { $0.id == computerID }) else {
                errorTitle = "Mac is no longer paired"
                errorMessage = "Pair the Mac that sent this notification again to open its conversation."
                return false
            }
            if activeComputerID != computerID { await switchComputer(to: computerID) }
            else if !isConnected { await connectSaved() }
            return activeComputerID == computerID && isConnected
        }
        return hasSavedConnection
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
        connectionStorage.clearToken(for: id)
        drafts.remove(computerID: id)
        pairedComputers.removeAll { $0.id == id }
        saveComputerProfiles()
    }

    private func clearActiveConnection() {
        invalidateConnectionWork()
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
        let generation = connectionGeneration
        isSharing = true
        defer { if generation == connectionGeneration { isSharing = false } }
        do {
            let files = try await client.sharedFiles().files
            try requireConnection(generation)
            sharedFiles = files
        }
        catch { if isCurrentConnection(generation) { presentError("Couldn't load files", error) } }
    }

    func copyMacClipboard() async -> String? {
        guard let client else { return nil }
        let generation = connectionGeneration
        isSharing = true
        defer { if generation == connectionGeneration { isSharing = false } }
        do {
            let text = try await client.clipboard().text
            try requireConnection(generation)
            return text
        }
        catch { if isCurrentConnection(generation) { presentError("Couldn't copy clipboard", error) }; return nil }
    }

    func sendClipboardToMac(_ text: String) async -> Bool {
        guard let client, !text.isEmpty else { return false }
        let generation = connectionGeneration
        isSharing = true
        defer { if generation == connectionGeneration { isSharing = false } }
        do { _ = try await client.setClipboard(text); try requireConnection(generation); return true }
        catch { if isCurrentConnection(generation) { presentError("Couldn't send clipboard", error) }; return false }
    }

    func uploadFile(_ url: URL) async -> Bool {
        guard let client else { return false }
        let generation = connectionGeneration
        isSharing = true
        defer { if generation == connectionGeneration { isSharing = false } }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
                throw RemoteClientError.server("Choose a non-empty file smaller than 20 MB.")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            _ = try await client.uploadFile(data: data, name: url.lastPathComponent)
            try requireConnection(generation)
            await loadSharing()
            return true
        } catch { if isCurrentConnection(generation) { presentError("Couldn't upload", error) }; return false }
    }

    func downloadFile(_ file: RemoteSharedFileItem) async -> URL? {
        guard let client else { return nil }
        let generation = connectionGeneration
        isSharing = true
        defer { if generation == connectionGeneration { isSharing = false } }
        do {
            let data = try await client.downloadFile(named: file.name)
            try requireConnection(generation)
            guard file.name == URL(fileURLWithPath: file.name).lastPathComponent,
                  file.name != ".", file.name != ".." else { throw RemoteClientError.invalidResponse }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BeetCode Remote", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(file.name, isDirectory: false)
            try data.write(to: destination, options: [.atomic])
            return destination
        } catch { if isCurrentConnection(generation) { presentError("Couldn't download", error) }; return nil }
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
        return RemoteAPIClient(baseURL: baseURL, token: token, session: apiSession)
    }

    private func isCurrentConnection(_ generation: UInt64) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    private func requireConnection(_ generation: UInt64) throws {
        guard isCurrentConnection(generation) else { throw CancellationError() }
    }

    private func invalidateConnectionWork() {
        hostStatus = nil
        lastConnectedAt = nil
        connectionGeneration &+= 1
        selectionGeneration &+= 1
        requestedSessionID = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
        isConnecting = false
        isSharing = false
        isUpdatingAccess = false
        autoMode = true
        fullAccess = false
        pollingTask?.cancel()
        pollingTask = nil
        sessionStreamTask?.cancel()
        sessionStreamTask = nil
        sessionStreamPhase = .stopped
        sessionStreamLastActivity = nil
        selectedSessionRevision = nil
        selectedSession = nil
        sessions = []
        startModels = []
        botRuns = []
        sharedFiles = []
        workspaces = []
        workspaceCreateParent = nil
        workspacesSupported = true
        resolvingPendingKeys.removeAll()
        sendingSessionIDs.removeAll()
        resolvingPendingKey = nil
        backgroundNotice = nil
        errorMessage = nil
        connectionAvailable = false
        consecutivePollingFailures = 0
        pollIdleSeconds = 4
    }

    private func activateComputer(_ id: UUID, connect: Bool) {
        guard let computer = pairedComputers.first(where: { $0.id == id }) else { return }
        invalidateConnectionWork()
        connectionLabel = connect ? "Connecting…" : "Disconnected"
        activeComputerID = id
        baseURL = computer.baseURL
        token = connectionStorage.token(for: id)
        requiresPairing = computer.tokenExpiresAt.map { $0 <= Date() } == true
        if requiresPairing { connectionLabel = "Pair again" }
        saveComputerProfiles()
    }

    private func restoreComputerProfiles() {
        let saved = connectionStorage.load()
        pairedComputers = saved.computers
        let id = saved.computers.contains(where: { $0.id == saved.activeID })
            ? saved.activeID : saved.computers.first?.id
        if let id { activateComputer(id, connect: false) }
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
        connectionStorage.save(computers: pairedComputers, activeID: activeComputerID)
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
        invalidateConnectionWork()
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
        let generation = connectionGeneration
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.pollInterval ?? .seconds(2) }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                do { try await self?.refresh() }
                catch {
                    guard let self, self.isCurrentConnection(generation) else { return }
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
        let generation = connectionGeneration
        let selection = selectionGeneration
        sessionStreamTask?.cancel()
        sessionStreamPhase = .connecting
        sessionStreamLastActivity = nil
        sessionStreamTask = Task { [weak self] in
            var retryDelay = Duration.milliseconds(300)
            while !Task.isCancelled {
                guard let self, self.isCurrentConnection(generation),
                      self.selectionGeneration == selection, self.selectedSession?.id == id else { return }
                do {
                    for try await event in client.sessionEvents(id) {
                        guard self.isCurrentConnection(generation), self.selectionGeneration == selection,
                              self.selectedSession?.id == id else { return }
                        self.sessionStreamPhase = .connected
                        self.sessionStreamLastActivity = Date()
                        switch event {
                        case .heartbeat:
                            continue
                        case .snapshot(let detail):
                            guard self.applySessionDetail(detail) else { continue }
                            self.reconcilePendingResolution(with: detail)
                            if self.observesNotifications {
                                RemoteNotificationCenter.shared.observeDetail(detail, computerName: self.activeComputerName, computerID: self.activeComputerID)
                            }
                            retryDelay = .milliseconds(300)
                        }
                    }
                } catch {
                    guard self.isCurrentConnection(generation), self.selectionGeneration == selection else { return }
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
        guard requestedSessionID == detail.id else { return false }
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
