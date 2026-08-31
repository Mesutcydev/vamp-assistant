import Foundation
import AppKit
import Darwin
import Security
import CryptoKit
@preconcurrency import ScreenCaptureKit

enum RemoteNetworkKind: String, Equatable, Sendable {
    case tailscale
    case localNetwork
}

struct RemoteUnlockAttemptLimiter: Sendable {
    static let maximumAttempts = 5
    static let window: TimeInterval = 30

    private var attemptsByClient: [String: [Date]] = [:]

    mutating func accept(clientID: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.window)
        var attempts = attemptsByClient[clientID, default: []].filter { $0 > cutoff }
        guard attempts.count < Self.maximumAttempts else {
            attemptsByClient[clientID] = attempts
            return false
        }
        attempts.append(now)
        attemptsByClient[clientID] = attempts
        return true
    }

    mutating func removeAll() {
        attemptsByClient.removeAll(keepingCapacity: false)
    }
}

struct RemoteStartModel: Sendable, Equatable {
    let id: String
    let name: String
    let source: String
    let detail: String
    let reasoningEfforts: [String]
    let defaultReasoningEffort: String?

    init(
        id: String, name: String, source: String, detail: String,
        reasoningEfforts: [String] = [], defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.detail = detail
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

struct RemoteRunOptions: Sendable, Equatable {
    let autoMode: Bool
    let fullAccess: Bool
    let reasoningEffort: String?
    let botProfileID: String?
    let botComputerID: UUID?
    let botWorkspacePath: String?
    let botContainerName: String?
    let botContainerExecutable: String?
    let workspacePath: String?
    let botBrowser: BrowserSession?

    var resolvedWorkspacePath: String? {
        if let botWorkspacePath, !botWorkspacePath.isEmpty { return botWorkspacePath }
        if let workspacePath, !workspacePath.isEmpty { return workspacePath }
        return nil
    }

    var linuxContainer: LinuxContainerTarget? {
        guard let botContainerExecutable, let botContainerName, let botWorkspacePath,
              !botContainerExecutable.isEmpty, !botContainerName.isEmpty else { return nil }
        return LinuxContainerTarget(
            executable: botContainerExecutable,
            containerName: botContainerName,
            hostWorkspacePath: botWorkspacePath)
    }

    static let standard = RemoteRunOptions(
        autoMode: true, fullAccess: false, reasoningEffort: nil, botProfileID: nil,
        botComputerID: nil, botWorkspacePath: nil, botContainerName: nil,
        botContainerExecutable: nil, workspacePath: nil, botBrowser: nil)
}

enum RemoteSessionStartOutcome: Sendable, Equatable {
    case accepted(UUID)
    case rejected(String)
}

/// Owns the network-facing Beetcode browser surface.
///
/// This is deliberately a session controller, not a terminal bridge: the
/// browser sees encrypted Beetcode session records and sends the next prompt
/// through `AgentSessionController`, so the Mac continues the exact same
/// workspace, transcript, checkpoints, and model context.
@MainActor
final class RemoteSessionHost {

    nonisolated static let defaultPort = RemoteSessionPorts.defaultPort
    static let pairingLifetime: TimeInterval = 10 * 60
    /// Browser access survives normal phone/laptop use, while the QR itself
    /// remains a short-lived, one-time approval. Revocation takes effect
    /// immediately. Stopping the host keeps paired tokens so the phone can
    /// reconnect after a Mac sleep or Remote toggle.
    static let tokenLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maxMessageBytes = 20_000
    static let maxPairBodyBytes = 4 * 1024
    static let maxRemoteFileBytes = 20 * 1024 * 1024
    static let maxRemoteBodyBytes = maxRemoteFileBytes
    static let maxClipboardCharacters = 200_000
    static let maxUnlockBodyBytes = 2 * 1024
    static let maxUnlockPasswordCharacters = 256
    static let maxPairedClients = 8
    static let maxPairFailuresPerWindow = 8
    static let pairFailureWindow: TimeInterval = 60

    enum HostError: Error, LocalizedError, Equatable {
        case tailscaleUnavailable
        case noReachableAddress
        case portUnavailable

        var errorDescription: String? {
            switch self {
            case .tailscaleUnavailable:
                return "Tailscale is not connected. Connect Tailscale, or enable the trusted local-network fallback in Settings."
            case .noReachableAddress:
                return "No reachable network address was found for remote sessions."
            case .portUnavailable:
                return "Remote Sessions could not bind a free port. Vamp Host uses 9475; Vamp Assistant uses \(RemoteSessionPorts.defaultPort)."
            }
        }
    }

    private let engine: any LLMEngine
    private let sessions: AgentSessionController
    private let sharing: RemoteSharingStore
    private let botComputers: BotComputerService
    private let persistsPairedClients: Bool
    /// AppState installs these handlers so remote messages become durable
    /// queued tasks. Tests and lightweight hosts may leave them nil and keep
    /// the direct continuation behavior.
    var enqueueTaskHandler: ((UUID, String) -> QueuedAgentTask?)?
    var taskLookupHandler: ((UUID) -> QueuedAgentTask?)?
    var queuedTasksHandler: ((UUID) -> [QueuedAgentTask])?
    var removeQueuedTaskHandler: ((UUID, UUID) -> Bool)?
    var steerHandler: ((UUID, String) -> Bool)?
    var modelOptionsHandler: (() -> [RemoteStartModel])?
    var clipboardSharingAllowedHandler: (() -> Bool)?
    var fileSharingAllowedHandler: (() -> Bool)?
    var macControlAllowedHandler: (() -> Bool)?
    var remoteMacUnlockAllowedHandler: (() -> Bool)?
    var remoteMacUnlockHandler: ((String) async throws -> Void)?
    var botRunsHandler: (() -> [BotRunRecord])?
    var startBotRunHandler: ((String, String?, String) async -> (UUID?, String?))?
    var orchestrateBotRunsHandler: ((String?, String) async -> (UUID?, String?))?
    var steerBotRunHandler: ((UUID, String) -> Bool)?
    var stopBotRunHandler: ((UUID) -> Bool)?
    var approveBotRunHandler: ((UUID, Bool) -> Bool)?
    var answerBotRunHandler: ((UUID, String) -> Bool)?
    var resumeBotRunHandler: ((UUID) -> Bool)?
    /// Returns nil on success, or a user-facing error string.
    var startSessionHandler: ((String, String, RemoteRunOptions) async -> RemoteSessionStartOutcome)?
    /// Activates a start-model id for the next remote turn. Returns an error string, or nil.
    var applyModelHandler: ((String, String?) async -> String?)?
    var configureRunHandler: ((RemoteRunOptions) -> Void)?
    private var server: LocalAPIServer?
    private let macControlApplicationRegistry = RemoteControlApplicationRegistry()
    private var tokens: [String: Date] = [:]
    /// Bumped to drop every live SSE loop when the host stops or all clients
    /// are revoked. Per-token revoke uses `revokedEventDigests` so other
    /// phones keep their streams.
    private var eventStreamGeneration = 0
    private var revokedEventDigests: Set<String> = []
    private struct CachedSessionSnapshot {
        let content: String
        let revision: UInt64
        let detail: [String: LFJSONValue]
        let encoded: String
    }
    private var sessionSnapshotSequence: UInt64 = 0
    private var sessionSnapshotCache: [UUID: CachedSessionSnapshot] = [:]
    /// Invalidates an in-flight bind when Settings changes or the host is
    /// stopped. LocalAPIServer.start awaits socket setup, so this guard keeps
    /// an older start from publishing itself after a newer request wins.
    private var startGeneration = 0
    private struct PairFailureWindow {
        var count: Int
        var firstAt: Date
    }
    private var pairFailuresByAddress: [String: PairFailureWindow] = [:]
    private var remoteUnlockAttemptLimiter = RemoteUnlockAttemptLimiter()
    private(set) var boundPort: Int?
    private(set) var pairingCode = RemoteSessionHost.makePairingCode()
    private(set) var pairingExpiresAt = Date().addingTimeInterval(RemoteSessionHost.pairingLifetime)
    private(set) var networkHost: String?
    private(set) var networkKind: RemoteNetworkKind?
    private var allowLANPeers = false

    init(
        engine: any LLMEngine,
        sessions: AgentSessionController,
        sharing: RemoteSharingStore? = nil,
        botComputers: BotComputerService? = nil,
        persistsPairedClients: Bool = true
    ) {
        self.engine = engine
        self.sessions = sessions
        self.sharing = sharing ?? RemoteSharingStore()
        self.botComputers = botComputers ?? BotComputerService()
        self.persistsPairedClients = persistsPairedClients
        self.tokens = persistsPairedClients ? RemotePairedClientStore.load() : [:]
    }

    var isRunning: Bool { server != nil }
    var actualPort: Int? { boundPort }

    var pairingURL: String? {
        guard let port = actualPort, let host = networkHost else { return nil }
        return "http://\(host):\(port)/?pair=\(pairingCode)"
    }

    var browserURL: String? {
        guard let port = actualPort, let host = networkHost else { return nil }
        return "http://\(host):\(port)/"
    }

    var pairedClientCount: Int {
        pruneExpiredTokens()
        return tokens.count
    }

    func start(port: Int, allowLAN: Bool = false) async throws {
        startGeneration &+= 1
        let generation = startGeneration
        let endpoint = RemoteNetworkEndpointDiscovery.preferredEndpoint(allowLAN: allowLAN)
        if let server {
            if await server.isRunning {
                let currentPort = await server.actualPort
                if let endpoint,
                   (port == 0 || currentPort == port || currentPort == RemoteSessionPorts.resolved(port)),
                   networkHost == endpoint.host,
                   networkKind == endpoint.kind,
                   allowLANPeers == allowLAN { return }
                await server.stop()
            }
            self.server = nil
            boundPort = nil
        }

        guard let endpoint else {
            networkHost = nil
            networkKind = nil
            if allowLAN {
                throw HostError.noReachableAddress
            }
            throw HostError.tailscaleUnavailable
        }

        networkHost = endpoint.host
        networkKind = endpoint.kind
        allowLANPeers = allowLAN
        rotatePairingCode()
        let resolver: LocalAPIServer.RouteResolver = { [weak self] request in
            guard let self else { return nil }
            return await self.route(request)
        }
        var nextServer: LocalAPIServer?
        var lastError: Error?
        for candidate in RemoteSessionPorts.candidates(preferred: port) {
            let attempt = LocalAPIServer(engine: engine)
            do {
                try await attempt.start(
                    .init(
                        port: candidate,
                        bindIPv6: false,
                        bindHost: "0.0.0.0",
                        modelIDOverride: nil,
                        bearerToken: nil,
                        idleTTLSeconds: nil,
                        exposeStandardRoutes: false,
                        maxBodyBytes: Self.maxRemoteBodyBytes,
                        allowCORS: false),
                    routeResolver: resolver)
                nextServer = attempt
                lastError = nil
                break
            } catch {
                lastError = error
                await attempt.stop()
            }
        }
        guard let nextServer else {
            if generation == startGeneration {
                networkHost = nil
                networkKind = nil
                boundPort = nil
            }
            throw lastError ?? HostError.portUnavailable
        }
        guard !Task.isCancelled, generation == startGeneration else {
            await nextServer.stop()
            throw CancellationError()
        }
        let actualPort = await nextServer.actualPort
        guard !Task.isCancelled, generation == startGeneration else {
            await nextServer.stop()
            throw CancellationError()
        }
        server = nextServer
        boundPort = actualPort
        refreshPairingState()
    }

    func stop() async {
        startGeneration &+= 1
        cancelEventStreams(matching: nil)
        await RemoteMacControl.releaseAll()
        RemoteMacTerminal.close()
        await server?.stop()
        server = nil
        boundPort = nil
        networkHost = nil
        networkKind = nil
        pairFailuresByAddress.removeAll()
        remoteUnlockAttemptLimiter.removeAll()
    }

    func rotatePairingCode() {
        pairingCode = Self.makePairingCode()
        pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
        pairFailuresByAddress.removeAll()
    }

    /// Rotates an expired code even when nobody opens the pairing sheet. This
    /// keeps the displayed code and the code accepted by the listener aligned.
    func refreshPairingState() {
        if Date() >= pairingExpiresAt {
            rotatePairingCode()
        }
    }

    func revokeAllClients() {
        cancelEventStreams(matching: nil)
        tokens.removeAll()
        remoteUnlockAttemptLimiter.removeAll()
        persistPairedClients()
        rotatePairingCode()
    }

    // MARK: HTTP routes

    private func route(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        refreshPairingState()
        guard allowedPeer(request.remoteAddress) else {
            return .response(json(["error": .string("This network path is not allowed for Vamp Assistant remote sessions.")], status: 403))
        }
        guard allowedOrigin(request) else {
            return .response(json(["error": .string("This browser origin is not the Vamp Assistant remote host.")], status: 403))
        }

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return .response(securityResponse(status: 204, contentType: "text/plain"))
        case ("GET", "/"), ("GET", "/index.html"):
            return .response(htmlPage())
        case ("GET", let path) where Self.publicImages[path] != nil:
            return .response(imageResponse(named: Self.publicImages[path]!))
        case ("POST", "/api/pair"):
            return pair(request)
        case ("GET", "/api/status"):
            guard authorized(request) else { return unauthorized() }
            return .response(json([
                "product": .string("Vamp Assistant"),
                "protocolVersion": .number(1),
                "pairedClients": .number(Double(pairedClientCount)),
                "networkKind": .string(networkKind?.rawValue ?? "unknown"),
                "tokenExpiresAt": tokenDigest(from: request).flatMap { tokens[$0] }.map { .number($0.timeIntervalSince1970) } ?? .null,
                "activeSessionID": sessions.activeSessionID.map { .string($0.uuidString) } ?? .null,
                "isRunning": .bool(sessions.isRunning),
                "phase": .string(sessions.currentPhase.rawValue),
                "queuedTasks": .number(Double(taskQueueCount)),
                "macControl": macControlStatusJSON(request: request),
            ]))
        case ("GET", "/api/sessions"):
            guard authorized(request) else { return unauthorized() }
            return .response(json(["sessions": .array(sessionSummaries())]))
        case ("GET", "/api/bot-runs"):
            guard authorized(request) else { return unauthorized() }
            return .response(json(["runs": .array((botRunsHandler?() ?? []).map(Self.botRunJSON))]))
        case ("POST", "/api/bot-runs"):
            guard authorized(request) else { return unauthorized() }
            guard let object = request.bodyJSON?.objectValue,
                  let profileID = object["profileID"]?.stringValue,
                  let prompt = object["prompt"]?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= Self.maxMessageBytes,
                  let startBotRunHandler else {
                return .response(json(["error": .string("Choose a specialist and enter a task.")], status: 400))
            }
            let result = await startBotRunHandler(profileID, object["modelID"]?.stringValue, prompt)
            if let id = result.0 {
                return .response(json(["accepted": .bool(true), "runID": .string(id.uuidString)], status: 202))
            }
            return .response(json(["error": .string(result.1 ?? "The bot run could not start.")], status: 409))
        case ("POST", "/api/bot-workflows"):
            guard authorized(request) else { return unauthorized() }
            guard let object = request.bodyJSON?.objectValue,
                  let prompt = object["prompt"]?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= Self.maxMessageBytes,
                  let orchestrateBotRunsHandler else {
                return .response(json(["error": .string("Enter a workflow objective.")], status: 400))
            }
            let result = await orchestrateBotRunsHandler(object["modelID"]?.stringValue, prompt)
            if let id = result.0 {
                return .response(json(["accepted": .bool(true), "workflowID": .string(id.uuidString)], status: 202))
            }
            return .response(json(["error": .string(result.1 ?? "The workflow could not start.")], status: 409))
        case ("GET", "/api/workspaces"):
            guard authorized(request) else { return unauthorized() }
            return .response(json(workspaceListJSON()))
        case ("POST", "/api/workspaces"):
            guard authorized(request) else { return unauthorized() }
            return createOrOpenWorkspace(request)
        case ("GET", "/api/models"):
            guard authorized(request) else { return unauthorized() }
            let models = (modelOptionsHandler?() ?? []).map { model in
                LFJSONValue.object([
                    "id": .string(model.id), "name": .string(model.name),
                    "source": .string(model.source), "detail": .string(model.detail),
                    "reasoningEfforts": .array(model.reasoningEfforts.map { .string($0) }),
                    "defaultReasoningEffort": model.defaultReasoningEffort.map { .string($0) } ?? .null,
                ])
            }
            return .response(json(["models": .array(models)]))
        case ("POST", "/api/providers/key"):
            guard authorized(request) else { return unauthorized() }
            guard let object = request.bodyJSON?.objectValue,
                  let providerID = object["providerID"]?.stringValue,
                  let provider = LLMProvider(rawValue: providerID),
                  let key = object["key"]?.stringValue,
                  key.utf8.count <= 8_192 else {
                return .response(json(["error": .string("Choose a supported provider and enter a valid API key.")], status: 400))
            }
            guard APIKeyStore.shared.save(key: key, for: provider) else {
                return .response(json(["error": .string("The API key could not be saved to the Mac Keychain.")], status: 500))
            }
            if let profiles = try? await RemoteLLMClient.fetchModelProfiles(provider: provider, apiKey: key),
               !profiles.isEmpty {
                AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
            }
            return .response(json(["accepted": .bool(true), "providerID": .string(provider.rawValue)]))
        case ("GET", "/api/bot-computers"):
            guard authorized(request) else { return unauthorized() }
            do {
                let records = try await botComputers.refresh()
                return .response(json([
                    "computers": .array(records.map(Self.botComputerJSON)),
                    "capabilities": Self.botCapabilitiesJSON(await botComputers.capabilities()),
                ]))
            } catch {
                return .response(json(["error": .string(error.localizedDescription)], status: 500))
            }
        case ("POST", "/api/bot-computers"):
            guard authorized(request) else { return unauthorized() }
            return await prepareBotComputers(request)
        case ("POST", "/api/bot-computers/refresh"):
            guard authorized(request) else { return unauthorized() }
            do {
                return .response(json(["computers": .array(try await botComputers.refresh().map(Self.botComputerJSON))]))
            } catch {
                return .response(json(["error": .string(error.localizedDescription)], status: 500))
            }
        case ("GET", "/api/control"):
            guard authorized(request) else { return unauthorized() }
            return .response(json(macControlStatusFields(request: request)))
        case ("GET", "/api/control/apps"):
            guard authorized(request) else { return unauthorized() }
            return await macControlApplications()
        case ("POST", "/api/control/apps/launch"):
            guard authorized(request) else { return unauthorized() }
            return await macControlLaunchApplication(request)
        case ("POST", "/api/control/apps/resize"):
            guard authorized(request) else { return unauthorized() }
            return await macControlResizeApplication(request)
        case ("GET", "/api/control/screen"):
            guard authorized(request) else { return unauthorized() }
            return await macControlScreen(request)
        case ("GET", "/api/control/screen/stream"):
            guard authorized(request) else { return unauthorized() }
            return macControlScreenStream(request)
        case ("POST", "/api/control/input"):
            guard authorized(request) else { return unauthorized() }
            return await macControlInput(request)
        case ("POST", "/api/control/unlock"):
            guard authorized(request) else { return unauthorized() }
            return await macControlUnlock(request)
        case ("GET", "/api/control/audio"):
            guard authorized(request) else { return unauthorized() }
            return macControlAudio()
        case ("GET", "/api/control/terminal/output"):
            guard authorized(request) else { return unauthorized() }
            return macControlTerminalOutput()
        case ("POST", "/api/control/terminal"):
            guard authorized(request) else { return unauthorized() }
            return macControlTerminal(request)
        case ("GET", "/api/clipboard"):
            guard authorized(request) else { return unauthorized() }
            guard clipboardSharingAllowedHandler?() ?? false else {
                return sharingPermissionDenied("Clipboard sharing")
            }
            return .response(json([
                "text": .string(sharing.clipboardText()),
                "updatedAt": .number(Date().timeIntervalSince1970),
            ]))
        case ("PUT", "/api/clipboard"):
            guard authorized(request) else { return unauthorized() }
            guard clipboardSharingAllowedHandler?() ?? false else {
                return sharingPermissionDenied("Clipboard sharing")
            }
            guard let text = request.bodyJSON?.objectValue?["text"]?.stringValue,
                  text.count <= Self.maxClipboardCharacters else {
                return .response(json(["error": .string("Clipboard text must be under 200,000 characters.")], status: 400))
            }
            sharing.setClipboardText(text)
            return .response(json(["accepted": .bool(true)]))
        case ("GET", "/api/files"):
            guard authorized(request) else { return unauthorized() }
            guard fileSharingAllowedHandler?() ?? false else {
                return sharingPermissionDenied("File transfer")
            }
            do {
                let files = try sharing.files().map { file in
                    LFJSONValue.object([
                        "name": .string(file.name),
                        "size": .number(Double(file.size)),
                        "modifiedAt": .number(file.modifiedAt.timeIntervalSince1970),
                    ])
                }
                return .response(json(["files": .array(files)]))
            } catch {
                return .response(json(["error": .string("The Mac could not open its BeetCode Remote Downloads folder.")], status: 500))
            }
        case ("POST", "/api/files"):
            guard authorized(request) else { return unauthorized() }
            guard fileSharingAllowedHandler?() ?? false else {
                return sharingPermissionDenied("File transfer")
            }
            guard let rawName = request.query["name"], !rawName.isEmpty else {
                return .response(json(["error": .string("A file name is required.")], status: 400))
            }
            do {
                let file = try sharing.save(request.body, suggestedName: rawName)
                return .response(json([
                    "accepted": .bool(true),
                    "name": .string(file.name),
                    "size": .number(Double(file.size)),
                ], status: 201))
            } catch {
                return .response(json(["error": .string(error.localizedDescription)], status: 400))
            }
        case ("POST", "/api/sessions"):
            guard authorized(request) else { return unauthorized() }
            guard let modelID = request.bodyJSON?.objectValue?["modelID"]?.stringValue,
                  let message = request.bodyJSON?.objectValue?["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= Self.maxMessageBytes,
                  let startSessionHandler else {
                return .response(json(["error": .string("Choose a model and enter a first prompt.")], status: 400))
            }
            var options = runOptions(from: request)
            if let botID = options.botComputerID {
                do {
                    var record = try await botComputers.load().first(where: { $0.id == botID })
                    if let current = record, current.backend == .isolatedWorkspace, current.state != .running {
                        record = try await botComputers.start(id: botID)
                    }
                    guard let record, record.state == .running else {
                        return .response(json(["error": .string("Start the selected Bot Computer before creating a session.")], status: 409))
                    }
                    options = RemoteRunOptions(
                        autoMode: options.autoMode, fullAccess: options.fullAccess,
                        reasoningEffort: options.reasoningEffort, botProfileID: options.botProfileID,
                        botComputerID: botID, botWorkspacePath: record.workspacePath,
                        botContainerName: record.backend == .appleContainer ? record.containerName : nil,
                        botContainerExecutable: record.backend == .appleContainer
                            ? BotComputerService.containerCLI() : nil,
                        workspacePath: options.workspacePath,
                        botBrowser: BrowserSession(id: record.id, name: record.name))
                } catch {
                    return .response(json(["error": .string("The selected Bot Computer could not be loaded.")], status: 409))
                }
            }
            if options.botComputerID == nil, let path = options.workspacePath, !path.isEmpty {
                do {
                    _ = try RemoteWorkspaceCatalog.resolveExisting(
                        path,
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        knownPaths: knownWorkspacePaths())
                } catch {
                    return .response(json(["error": .string(error.localizedDescription)], status: 400))
                }
            }
            configureRunHandler?(options)
            switch await startSessionHandler(modelID, message, options) {
            case .accepted(let sessionID):
                return .response(json([
                    "accepted": .bool(true),
                    "sessionID": .string(sessionID.uuidString),
                ], status: 202))
            case .rejected(let error):
                return .response(json(["error": .string(error)], status: 409))
            }
        case ("POST", "/api/revoke"):
            guard authorized(request) else { return unauthorized() }
            guard let digest = tokenDigest(from: request) else { return unauthorized() }
            cancelEventStreams(matching: digest)
            tokens.removeValue(forKey: digest)
            persistPairedClients()
            return .response(json(["ok": .bool(true), "revoked": .bool(true)]))
        default:
            guard authorized(request) else { return unauthorized() }
            if request.method == "GET", request.path.hasPrefix("/api/files/") {
                guard fileSharingAllowedHandler?() ?? false else {
                    return sharingPermissionDenied("File transfer")
                }
                return .response(sharedFileResponse(request))
            }
            if request.path.hasPrefix("/api/bot-computers/") {
                return await botComputerRoute(request)
            }
            if request.path.hasPrefix("/api/bot-runs/") {
                return botRunRoute(request)
            }
            return await sessionRoute(request)
        }
    }

    private func botRunRoute(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        let parts = request.path.split(separator: "/")
        guard parts.count >= 3, let id = UUID(uuidString: String(parts[2])) else {
            return .response(json(["error": .string("Unknown bot run endpoint.")], status: 404))
        }
        if request.method == "GET", parts.count == 3 {
            guard let run = botRunsHandler?().first(where: { $0.id == id }) else {
                return .response(json(["error": .string("That bot run was not found.")], status: 404))
            }
            return .response(json(["run": Self.botRunJSON(run)]))
        }
        guard request.method == "POST", parts.count == 4 else {
            return .response(json(["error": .string("Use GET or a supported bot-run action.")], status: 405))
        }
        switch String(parts[3]) {
        case "steer":
            guard let message = request.bodyJSON?.objectValue?["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= Self.maxMessageBytes else {
                return .response(json(["error": .string("Enter steering guidance.")], status: 400))
            }
            guard steerBotRunHandler?(id, message) == true else {
                return .response(json(["error": .string("That run cannot be steered right now.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)], status: 202))
        case "stop":
            guard stopBotRunHandler?(id) == true else {
                return .response(json(["error": .string("That run is already finished or cannot be stopped.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)]))
        case "approve", "decline":
            let approved = String(parts[3]) == "approve"
            guard approveBotRunHandler?(id, approved) == true else {
                return .response(json(["error": .string("That run has no pending approval.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)], status: 202))
        case "answer":
            guard let answer = request.bodyJSON?.objectValue?["answer"]?.stringValue,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= Self.maxMessageBytes,
                  answerBotRunHandler?(id, answer) == true else {
                return .response(json(["error": .string("That run has no pending question.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)], status: 202))
        case "resume":
            guard resumeBotRunHandler?(id) == true else {
                return .response(json(["error": .string("That run is not recoverable.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)], status: 202))
        default:
            return .response(json(["error": .string("Unknown bot run action.")], status: 404))
        }
    }

    private func botComputerRoute(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        let parts = request.path.split(separator: "/")
        guard parts.count == 4, let id = UUID(uuidString: String(parts[2])) else {
            return .response(json(["error": .string("Unknown bot computer endpoint.")], status: 404))
        }
        do {
            let record: BotComputerRecord
            switch (request.method, String(parts[3])) {
            case ("POST", "start"):
                record = try await botComputers.start(id: id)
            case ("POST", "stop"):
                record = try await botComputers.stop(id: id)

            // Console. The path is client-supplied; `BotComputerService` confines it to the
            // bot's workspace and returns relative paths, so the host layout never crosses
            // the wire and a traversal is refused rather than served.
            case ("POST", "exec"):
                let command = request.bodyJSON?.objectValue?["command"]?.stringValue ?? ""
                let output = try await botComputers.exec(id: id, command: command)
                return .response(json(["output": .string(output)]))
            case ("GET", "files"):
                let entries = try await botComputers.listWorkspace(
                    id: id, relativePath: request.query["path"] ?? "")
                return .response(json([
                    "path": .string(request.query["path"] ?? ""),
                    "entries": .array(entries.map(Self.botWorkspaceEntryJSON)),
                ]))
            case ("GET", "file"):
                guard let path = request.query["path"], !path.isEmpty else {
                    return .response(json(["error": .string("Missing path.")], status: 400))
                }
                let contents = try await botComputers.readWorkspaceFile(id: id, relativePath: path)
                return .response(json(["path": .string(path), "contents": .string(contents)]))

            default:
                return .response(json(["error": .string("Unknown bot computer endpoint.")], status: 405))
            }
            return .response(json(["accepted": .bool(true), "computer": Self.botComputerJSON(record)]))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 409))
        }
    }

    private static func botWorkspaceEntryJSON(_ entry: BotWorkspaceEntry) -> LFJSONValue {
        .object([
            "path": .string(entry.path),
            "name": .string(entry.name),
            "isDirectory": .bool(entry.isDirectory),
            "byteSize": .number(Double(entry.byteSize)),
            "modifiedAt": .number(entry.modifiedAt.timeIntervalSince1970),
        ])
    }

    private func prepareBotComputers(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        do {
            let profileID = request.bodyJSON?.objectValue?["profileID"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let profileID, !profileID.isEmpty {
                let record = try await botComputers.prepareSpecialist(profileID: profileID)
                return .response(json([
                    "accepted": .bool(true),
                    "computer": Self.botComputerJSON(record),
                    "computers": .array(try await botComputers.refresh().map(Self.botComputerJSON)),
                ], status: 201))
            }
            let records = try await botComputers.prepareSpecialists()
            return .response(json([
                "accepted": .bool(true),
                "computers": .array(records.map(Self.botComputerJSON)),
            ], status: 201))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 409))
        }
    }

    private static func botComputerJSON(_ record: BotComputerRecord) -> LFJSONValue {
        .object([
            "id": .string(record.id.uuidString),
            "profileID": .string(record.profileID),
            "name": .string(record.name),
            "backend": .string(record.backend.rawValue),
            "state": .string(record.state.rawValue),
            "workspacePath": .string(record.workspacePath),
            "browserProfilePath": .string(record.browserProfilePath),
            "containerName": record.containerName.map { .string($0) } ?? .null,
            "updatedAt": .number(record.updatedAt.timeIntervalSince1970),
        ])
    }

    private static func botRunJSON(_ run: BotRunRecord) -> LFJSONValue {
        .object([
            "id": .string(run.id.uuidString),
            "profileID": .string(run.profileID),
            "profileName": .string(run.profileName),
            "modelID": .string(run.modelID),
            "sessionID": run.sessionID.map { .string($0.uuidString) } ?? .null,
            "prompt": .string(run.prompt),
            "state": .string(run.state.rawValue),
            "phase": .string(run.phase),
            "queuePosition": run.queuePosition.map { .number(Double($0)) } ?? .null,
            "pendingInteraction": run.pendingInteraction.map { .string($0) } ?? .null,
            "latestOutput": .string(run.latestOutput),
            "errorMessage": run.errorMessage.map { .string($0) } ?? .null,
            "resourceClass": run.resourceClass.map { .string($0.rawValue) } ?? .null,
            "retryCount": .number(Double(run.retryCount ?? 0)),
            "workflowID": run.workflowID.map { .string($0.uuidString) } ?? .null,
            "dependencyRunIDs": .array((run.dependencyRunIDs ?? []).map { .string($0.uuidString) }),
            "traceID": run.traceID.map { .string($0) } ?? .null,
            "checkpoint": run.checkpoint.map { checkpoint in .object([
                "phase": .string(checkpoint.phase),
                "sequence": .number(Double(checkpoint.sequence)),
                "createdAt": .number(checkpoint.createdAt.timeIntervalSince1970),
            ]) } ?? .null,
            "artifacts": .array((run.artifacts ?? []).map { artifact in .object([
                "id": .string(artifact.id.uuidString), "kind": .string(artifact.kind.rawValue),
                "title": .string(artifact.title), "value": .string(artifact.value),
                "createdAt": .number(artifact.createdAt.timeIntervalSince1970),
            ]) }),
            "createdAt": .number(run.createdAt.timeIntervalSince1970),
            "updatedAt": .number(run.updatedAt.timeIntervalSince1970),
        ])
    }

    private static func botCapabilitiesJSON(_ capabilities: BotHostCapabilities) -> LFJSONValue {
        .object([
            "architecture": .string(capabilities.architecture),
            "macOSVersion": .string(capabilities.macOSVersion),
            "appleContainerExecutable": capabilities.appleContainerExecutable.map { .string($0) } ?? .null,
            "appleContainerServiceRunning": .bool(capabilities.appleContainerServiceRunning),
            "supportsAppleContainers": .bool(capabilities.supportsAppleContainers),
        ])
    }

    private func sharingPermissionDenied(_ capability: String) -> LocalAPIServer.RouteResult {
        .response(json([
            "error": .string("\(capability) is off on this Mac. Enable it in Remote Sessions."),
        ], status: 403))
    }

    private func macControlStatusJSON(request: LocalAPIServer.Request) -> LFJSONValue {
        .object(macControlStatusFields(request: request))
    }

    private func macControlStatusFields(request: LocalAPIServer.Request) -> [String: LFJSONValue] {
        let enabled = macControlAllowedHandler?() ?? false
        let screen = ComputerPermission.screenRecordingGranted
        let accessibility = ComputerPermission.accessibilityGranted
        let locked = ComputerPermission.sessionLocked
        let unlockEnabled = remoteMacUnlockAllowedHandler?() ?? false
        let secureUnlockPath = Self.isSecureRemoteUnlockPeer(request.remoteAddress)
        let unlockAvailable = enabled && unlockEnabled && accessibility && secureUnlockPath
        let ready = enabled && screen && accessibility && !locked
        let bounds = ComputerEvents.quartzDisplayUnion()
        let message: String?
        if !enabled {
            message = "Turn on Mac Control in Vamp Assistant → Remote Sessions."
        } else if locked {
            message = "The Mac is locked. Unlock it to resume Vamp Stream and Remote Control."
        } else if !screen || !accessibility {
            message = "Grant Screen Recording and Accessibility for Vamp Assistant in System Settings."
        } else {
            message = nil
        }
        let displays: [LFJSONValue] = RemoteMacControl.attachedDisplays().map { display in
            .object([
                "id": .number(Double(display.id)),
                "name": .string(display.name),
                "x": .number(display.x),
                "y": .number(display.y),
                "width": .number(display.width),
                "height": .number(display.height),
            ])
        }
        return [
            "enabled": .bool(enabled),
            "screenRecording": .bool(screen),
            "accessibility": .bool(accessibility),
            "locked": .bool(locked),
            "remoteUnlockEnabled": .bool(unlockEnabled),
            "remoteUnlockAvailable": .bool(unlockAvailable),
            "remoteUnlockMessage": .string(remoteUnlockMessage(
                enabled: enabled,
                unlockEnabled: unlockEnabled,
                accessibility: accessibility,
                securePath: secureUnlockPath)),
            "ready": .bool(ready),
            "displayX": .number(bounds.minX),
            "displayY": .number(bounds.minY),
            "displayWidth": .number(max(bounds.width, 1)),
            "displayHeight": .number(max(bounds.height, 1)),
            "displays": .array(displays),
            "message": message.map { .string($0) } ?? .null,
        ]
    }

    private func remoteUnlockMessage(
        enabled: Bool,
        unlockEnabled: Bool,
        accessibility: Bool,
        securePath: Bool
    ) -> String {
        if !enabled {
            return "Turn on Mac Control in Vamp Assistant → Remote Sessions."
        }
        if !unlockEnabled {
            return "Turn on Remote Unlock in Vamp Assistant → Remote Sessions."
        }
        if !accessibility {
            return "Grant Accessibility to Vamp Assistant on the Mac."
        }
        if !securePath {
            return "Remote Unlock requires the encrypted Tailscale connection."
        }
        return "Enter the Mac login password. It is used once and never stored."
    }

    private func macControlDenied(_ reason: String) -> LocalAPIServer.RouteResult {
        .response(json(["error": .string(reason)], status: 403))
    }

    private func macControlApplications() async -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard ComputerPermission.screenRecordingGranted else {
            return macControlDenied("Screen Recording permission is required to list streamable apps.")
        }
        let applications = macControlApplicationRegistry.snapshot().map(Self.macControlApplicationJSON)
        return .response(json(["applications": .array(applications)]))
    }

    private func macControlLaunchApplication(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard ComputerPermission.screenRecordingGranted else {
            return macControlDenied("Screen Recording permission is required to stream an application.")
        }
        guard let bundleIdentifier = request.bodyJSON?.objectValue?["bundleIdentifier"]?.stringValue,
              !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 512 else {
            return .response(json(["error": .string("Choose an installed Mac application.")], status: 400))
        }
        do {
            let aspect = request.bodyJSON?.objectValue?["clientViewportAspect"]?.numberValue
            let application = try await macControlApplicationRegistry.launch(
                bundleIdentifier: bundleIdentifier,
                clientViewportAspect: aspect)
            return .response(json(["application": Self.macControlApplicationJSON(application)]))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 409))
        }
    }

    private func macControlResizeApplication(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard ComputerPermission.screenRecordingGranted else {
            return macControlDenied("Screen Recording permission is required to stream an application.")
        }
        guard ComputerPermission.accessibilityGranted else {
            return macControlDenied("Accessibility permission is required to resize a streamed application.")
        }
        guard let windowValue = request.bodyJSON?.objectValue?["windowID"]?.numberValue,
              windowValue >= 0,
              windowValue <= Double(UInt32.max),
              let windowID = UInt32(exactly: windowValue),
              let aspect = request.bodyJSON?.objectValue?["clientViewportAspect"]?.numberValue else {
            return .response(json(["error": .string("A valid window and viewport aspect are required.")], status: 400))
        }
        do {
            let application = try await macControlApplicationRegistry.resize(
                windowID: windowID,
                clientViewportAspect: aspect)
            return .response(json(["application": Self.macControlApplicationJSON(application)]))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 409))
        }
    }

    private static func macControlApplicationJSON(
        _ application: RemoteControlApplicationRegistry.Application
    ) -> LFJSONValue {
        .object([
            "windowID": application.windowID.map { .number(Double($0)) } ?? .null,
            "bundleIdentifier": .string(application.bundleIdentifier),
            "name": .string(application.name),
            "windowTitle": application.windowTitle.map(LFJSONValue.string) ?? .null,
            "width": .number(application.width),
            "height": .number(application.height),
            "isRunning": .bool(application.isRunning),
            "isActive": .bool(application.isActive),
            "iconPNGBase64": application.iconPNGBase64.map(LFJSONValue.string) ?? .null,
        ])
    }

    private func macControlScreen(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard !ComputerPermission.sessionLocked else {
            return .response(json(["error": .string("The Mac is locked. Unlock it to resume streaming.")], status: 423))
        }
        let displayID = request.query["display"].flatMap(UInt32.init)
        let windowID = request.query["window"].flatMap(UInt32.init)
        do {
            let profile = RemoteStreamProfile(resolution: RemoteStreamResolution.resolve(request.query["resolution"]))
            let frame: RemoteMacControl.Frame
            if let windowID {
                frame = try await RemoteMacControl.captureWindowJPEG(
                    windowID: windowID,
                    maxWidth: profile.maxWidth)
            } else {
                frame = try await RemoteMacControl.captureDisplayJPEG(
                    displayID: displayID,
                    maxWidth: profile.maxWidth)
            }
            return .response(screenJPEGResponse(frame, displayID: displayID))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 403))
        }
    }

    private func macControlScreenStream(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard !ComputerPermission.sessionLocked else {
            return .response(json(["error": .string("The Mac is locked. Unlock it to resume streaming.")], status: 423))
        }
        let displayID = request.query["display"].flatMap(UInt32.init)
        let windowID = request.query["window"].flatMap(UInt32.init)
        let config = screenCaptureConfig(from: request, displayID: displayID, windowID: windowID)
        // Each HTTP stream owns its capture pipeline. A display viewer and an
        // app-window viewer must never restart or retarget one another.
        let capture = RemoteMacScreenCapture()
        // Multipart H.264 (AVCC) — Vamp-style live video, no JPEG/MJPEG.
        let boundary = "beetframe"
        let lines = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task.detached {
                for await frame in capture.frames(config: config) {
                    try Task.checkCancellation()
                    guard case .h264(let data, let keyframe, let parameterSets) = frame.payload else { continue }
                    let params = (keyframe ? parameterSets : nil) ?? Data()
                    let bodyCount = params.count + data.count
                    var part = Data()
                    part.append(contentsOf: "--\(boundary)\r\n".utf8)
                    part.append(contentsOf: "Content-Type: video/avc\r\n".utf8)
                    part.append(contentsOf: "Content-Length: \(bodyCount)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Keyframe: \(keyframe ? 1 : 0)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Params-Length: \(params.count)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Image-Width: \(frame.imageWidth)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Image-Height: \(frame.imageHeight)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Display-X: \(frame.displayX)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Display-Y: \(frame.displayY)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Display-Width: \(frame.displayWidth)\r\n".utf8)
                    part.append(contentsOf: "X-Beet-Display-Height: \(frame.displayHeight)\r\n".utf8)
                    part.append(contentsOf: "\r\n".utf8)
                    if !params.isEmpty { part.append(params) }
                    part.append(data)
                    part.append(contentsOf: "\r\n".utf8)
                    continuation.yield(part)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        // Use multipart/mixed (not x-mixed-replace). URLSession on iOS special-cases
        // x-mixed-replace and rewrites the response Content-Type to each part's type
        // (video/avc), which breaks our boundary parser.
        var response = LocalAPIServer.Response(
            status: 200,
            contentType: "multipart/mixed; boundary=\(boundary)")
        response.headers = Self.securityHeaders
        return .stream(response, lines: lines)
    }

    private func screenCaptureConfig(
        from request: LocalAPIServer.Request,
        displayID: CGDirectDisplayID?,
        windowID: CGWindowID?
    ) -> RemoteMacScreenCapture.Config {
        let profile = RemoteStreamProfile(resolution: RemoteStreamResolution.resolve(request.query["resolution"]))
        return RemoteMacScreenCapture.Config(
            displayID: displayID,
            windowID: windowID,
            maxWidth: profile.maxWidth,
            averageBitrate: profile.averageBitrate,
            framesPerSecond: profile.framesPerSecond)
    }

    private func screenJPEGResponse(
        _ frame: RemoteMacControl.Frame,
        displayID: CGDirectDisplayID?
    ) -> LocalAPIServer.Response {
        let jpeg = frame.jpegData ?? Data()
        return LocalAPIServer.Response(
            status: 200,
            contentType: "image/jpeg",
            body: jpeg,
            headers: Self.securityHeaders + [
                ("X-Beet-Image-Width", "\(frame.imageWidth)"),
                ("X-Beet-Image-Height", "\(frame.imageHeight)"),
                ("X-Beet-Display-X", String(frame.displayX)),
                ("X-Beet-Display-Y", String(frame.displayY)),
                ("X-Beet-Display-Width", String(frame.displayWidth)),
                ("X-Beet-Display-Height", String(frame.displayHeight)),
                ("X-Beet-Display-ID", displayID.map(String.init) ?? ""),
            ])
    }

    private func macControlAudio() -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard !ComputerPermission.sessionLocked else {
            return .response(json(["error": .string("The Mac is locked. Unlock it to resume audio streaming.")], status: 423))
        }
        let lines = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            let task = Task.detached {
                for await chunk in RemoteMacAudio.shared.outputStream() {
                    try Task.checkCancellation()
                    let payload = "{\"sr\":\(chunk.sampleRate),\"ch\":\(chunk.channels),\"pcm\":\"\(chunk.data.base64EncodedString())\"}"
                    continuation.yield(Data("data: \(payload)\n\n".utf8))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var response = LocalAPIServer.Response(status: 200, contentType: "text/event-stream; charset=utf-8")
        response.headers = Self.securityHeaders
        return .stream(response, lines: lines)
    }

    private func macControlTerminalOutput() -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        let lines = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task.detached {
                for await chunk in RemoteMacTerminal.outputStream() {
                    try Task.checkCancellation()
                    let snapshot = LFJSONValue.object([
                        "data": .string(chunk.base64EncodedString()),
                        "out": .string(String(decoding: chunk, as: UTF8.self))
                    ]).encoded()
                    continuation.yield(Data("event: out\ndata: \(snapshot)\n\n".utf8))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var response = LocalAPIServer.Response(status: 200, contentType: "text/event-stream; charset=utf-8")
        response.headers = Self.securityHeaders
        return .stream(response, lines: lines)
    }

    private func macControlTerminal(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        let object = request.bodyJSON?.objectValue
        switch object?["action"]?.stringValue {
        case "open":
            let colsValue = object?["cols"]?.intValue ?? 80
            let rowsValue = object?["rows"]?.intValue ?? 24
            guard (1...240).contains(colsValue), (1...120).contains(rowsValue) else {
                return .response(json(["error": .string("Terminal dimensions are out of range.")], status: 400))
            }
            do {
                try RemoteMacTerminal.open(cols: UInt16(colsValue), rows: UInt16(rowsValue))
                return .response(json(["accepted": .bool(true)]))
            } catch {
                return .response(json(["error": .string(error.localizedDescription)], status: 500))
            }
        case "input":
            let data: Data?
            if let raw = object?["data"]?.stringValue {
                data = Data(base64Encoded: raw)
            } else if let text = object?["text"]?.stringValue {
                data = Data(text.utf8)
            } else {
                data = nil
            }
            guard let data, !data.isEmpty, data.count <= 16 * 1024 else {
                return .response(json(["error": .string("Terminal input is missing, malformed, or too large.")], status: 400))
            }
            RemoteMacTerminal.input(data)
            return .response(json(["accepted": .bool(true)]))
        case "resize":
            let cols = object?["cols"]?.intValue ?? 80
            let rows = object?["rows"]?.intValue ?? 24
            guard (1...240).contains(cols), (1...120).contains(rows) else {
                return .response(json(["error": .string("Terminal dimensions are out of range.")], status: 400))
            }
            RemoteMacTerminal.resize(cols: UInt16(cols), rows: UInt16(rows))
            return .response(json(["accepted": .bool(true)]) )
        case "close":
            RemoteMacTerminal.close()
            return .response(json(["accepted": .bool(true)]))
        default:
            return .response(json(["error": .string("Unknown terminal action.")], status: 400))
        }
    }

    private func macControlInput(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard !ComputerPermission.sessionLocked else {
            return .response(json(["error": .string("The Mac is locked. Unlock it before sending input.")], status: 423))
        }
        guard ComputerPermission.accessibilityGranted else {
            return macControlDenied("Accessibility permission is required to control this Mac.")
        }
        guard let object = request.bodyJSON?.objectValue else {
            return .response(json(["error": .string("A control command is required.")], status: 400))
        }

        let isBatch = object["commands"]?.arrayValue != nil
        let commands: [RemoteMacControl.Command]
        if let entries = object["commands"]?.arrayValue {
            guard !entries.isEmpty, entries.count <= 64 else {
                return .response(json(["error": .string("A control batch must contain 1 to 64 commands.")], status: 400))
            }
            var parsed: [RemoteMacControl.Command] = []
            parsed.reserveCapacity(entries.count)
            for entry in entries {
                guard let commandObject = entry.objectValue else {
                    return .response(json(["error": .string("Every control batch entry must be an object.")], status: 400))
                }
                switch RemoteMacControl.parse(commandObject) {
                case .success(let command): parsed.append(command)
                case .failure(let error):
                    return .response(json(["error": .string(error.localizedDescription)], status: 400))
                }
            }
            commands = parsed
        } else {
            switch RemoteMacControl.parse(object) {
            case .success(let command): commands = [command]
            case .failure(let error):
                return .response(json(["error": .string(error.localizedDescription)], status: 400))
            }
        }

        // The phone serializes batches already. Await the input actor so a 2xx
        // means macOS accepted the commands, not merely that a detached task
        // was created. This also provides natural backpressure.
        do {
            try await RemoteMacControl.perform(commands)
        } catch {
            return .response(json([
                "error": .string(error.localizedDescription),
            ], status: 409))
        }
        if isBatch {
            return .response(json(["accepted": .bool(true), "count": .number(Double(commands.count))]))
        }
        return .response(json(["accepted": .bool(true)]))
    }

    private func macControlUnlock(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        guard request.body.count <= Self.maxUnlockBodyBytes else {
            return .response(json(["error": .string("Remote Unlock requests must be under 2 KB.")], status: 413))
        }
        guard Self.isSecureRemoteUnlockPeer(request.remoteAddress) else {
            return .response(json([
                "error": .string("Remote Unlock requires the encrypted Tailscale connection."),
            ], status: 403))
        }
        guard macControlAllowedHandler?() ?? false else {
            return macControlDenied("Mac Control is off on this Mac. Enable it in Remote Sessions.")
        }
        guard remoteMacUnlockAllowedHandler?() ?? false else {
            return macControlDenied("Remote Unlock is off on this Mac. Enable it in Remote Sessions.")
        }
        guard ComputerPermission.accessibilityGranted else {
            return macControlDenied("Accessibility permission is required for Remote Unlock.")
        }
        guard ComputerPermission.sessionLocked else {
            return .response(json(["error": .string("The Mac is no longer locked.")], status: 423))
        }
        guard let password = request.bodyJSON?.objectValue?["password"]?.stringValue,
              !password.isEmpty,
              password.count <= Self.maxUnlockPasswordCharacters,
              !password.contains("\n"),
              !password.contains("\r"),
              !password.contains("\0") else {
            return .response(json([
                "error": .string("Enter a login password between 1 and 256 characters."),
            ], status: 400))
        }
        guard let clientID = tokenDigest(from: request) else { return unauthorized() }
        guard remoteUnlockAttemptLimiter.accept(clientID: clientID) else {
            return .response(json([
                "error": .string("Too many Remote Unlock attempts. Wait 30 seconds, then try again."),
            ], status: 429))
        }
        guard let remoteMacUnlockHandler else {
            return .response(json([
                "error": .string("Remote Unlock is unavailable in this build."),
            ], status: 501))
        }

        do {
            try await remoteMacUnlockHandler(password)
            return .response(json(["accepted": .bool(true)], status: 202))
        } catch {
            return .response(json([
                "error": .string("Remote Unlock could not deliver the login keystrokes. Check Accessibility and try again."),
            ], status: 409))
        }
    }

    private func pair(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        guard request.body.count <= Self.maxPairBodyBytes else {
            return .response(json(["error": .string("Pairing requests must be under 4 KB.")], status: 413))
        }
        let address = request.remoteAddress
        guard canAttemptPairing(from: address) else {
            return .response(json(["error": .string("Too many pairing attempts. Try again in a minute.")], status: 429))
        }

        let submittedCodes = [
            request.bodyJSON?.objectValue?["code"]?.stringValue,
            request.query["pair"],
        ].compactMap { $0.flatMap(Self.normalizePairingCode) }
        guard submittedCodes.contains(where: { Self.constantTimeEqual($0, pairingCode) }),
              Date() < pairingExpiresAt else {
            recordPairFailure(from: address)
            return .response(json(["error": .string("The pairing code is invalid or expired.")], status: 401))
        }

        let token = Self.makeToken()
        let tokenExpiresAt = Date().addingTimeInterval(Self.tokenLifetime)
        if tokens.count >= Self.maxPairedClients,
           let oldest = tokens.min(by: { $0.value < $1.value })?.key {
            cancelEventStreams(matching: oldest)
            tokens.removeValue(forKey: oldest)
        }
        tokens[Self.tokenDigest(token)] = tokenExpiresAt
        persistPairedClients()
        // Pairing codes are approvals, not reusable passwords.
        rotatePairingCode()
        return .response(json([
            "token": .string(token),
            "expiresAt": .number(tokenExpiresAt.timeIntervalSince1970),
            "product": .string("Vamp Assistant"),
        ]))
    }

    private func sessionRoute(_ request: LocalAPIServer.Request) async -> LocalAPIServer.RouteResult {
        let components = request.path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "api",
              components[1] == "sessions",
              let id = UUID(uuidString: String(components[2])) else {
            return .response(json(["error": .string("Unknown endpoint.")], status: 404))
        }

        if components.count == 3, request.method == "GET" {
            guard let record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            return .response(json(sessionSnapshot(record).detail))
        }

        // Delete and rename mirror the Mac sidebar exactly: a hard delete of
        // the encrypted session file, and a title edit. Both are refused while
        // that session is the running one — the Mac already refuses rename on
        // the same condition, and a phone is where a mis-tap costs the most.
        if components.count == 3, request.method == "DELETE" {
            guard let record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            guard !(sessions.activeSessionID == record.id && sessions.isRunning) else {
                return .response(json([
                    "error": .string("This chat is still answering. Stop it before deleting."),
                ], status: 409))
            }
            SessionStore.shared.delete(record)
            sessionSnapshotCache.removeValue(forKey: record.id)
            NotificationCenter.default.post(name: .remoteSessionsChanged, object: record.id)
            return .response(json(["ok": .bool(true), "deleted": .bool(true)]))
        }

        if components.count == 3, request.method == "PATCH" {
            guard let raw = request.bodyJSON?.objectValue?["title"]?.stringValue else {
                return .response(json(["error": .string("A title is required.")], status: 400))
            }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 200 else {
                return .response(json(["error": .string("Enter a name under 200 bytes.")], status: 400))
            }
            guard var record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            guard !(sessions.activeSessionID == record.id && sessions.isRunning) else {
                return .response(json([
                    "error": .string("This chat is still answering. Rename it once the model stops."),
                ], status: 409))
            }
            record.title = title
            record.updatedAt = Date()
            guard case .success = SessionStore.shared.save(record) else {
                return .response(json(["error": .string("The rename could not be saved.")], status: 500))
            }
            NotificationCenter.default.post(
                name: .sessionTitleChanged, object: record.id, userInfo: ["title": title])
            NotificationCenter.default.post(name: .remoteSessionsChanged, object: record.id)
            return .response(json(["ok": .bool(true), "title": .string(title)]))
        }

        if components.count == 4, components[3] == "events", request.method == "GET" {
            guard ownedRecord(id) != nil else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            guard let digest = tokenDigest(from: request) else { return unauthorized() }
            return sessionEventStream(id: id, digest: digest)
        }

        if components.count == 4, components[3] == "options", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning else {
                return .response(json(["error": .string("That session is not running.")], status: 409))
            }
            guard let object = request.bodyJSON?.objectValue,
                  let autoMode = object["autoMode"]?.boolValue,
                  let fullAccess = object["fullAccess"]?.boolValue else {
                return .response(json(["error": .string("Provide autoMode and fullAccess.")], status: 400))
            }
            configureRunHandler?(RemoteRunOptions(
                autoMode: autoMode,
                fullAccess: fullAccess,
                reasoningEffort: nil,
                botProfileID: nil,
                botComputerID: nil,
                botWorkspacePath: nil,
                botContainerName: nil,
                botContainerExecutable: nil,
                workspacePath: nil,
                botBrowser: nil))
            return .response(json([
                "accepted": .bool(true),
                "autoMode": .bool(autoMode),
                "fullAccess": .bool(fullAccess),
            ]))
        }

        if components.count == 4, components[3] == "messages", request.method == "POST" {
            guard let message = request.bodyJSON?.objectValue?["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= Self.maxMessageBytes else {
                return .response(json(["error": .string("A non-empty message under 20 KB is required.")], status: 400))
            }
            guard let record = ownedRecord(id) else {
                return .response(json(["error": .string("Session not found.")], status: 404))
            }
            let options = runOptions(from: request)
            configureRunHandler?(options)
            if let modelID = request.bodyJSON?.objectValue?["modelID"]?.stringValue,
               !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let error = await applyContinueModel(
                    sessionID: record.id,
                    modelID: modelID,
                    reasoningEffort: options.reasoningEffort
                ) {
                    return .response(json(["error": .string(error)], status: 409))
                }
            }
            let action = request.bodyJSON?.objectValue?["action"]?.stringValue
            if action == "steer" {
                if sessions.activeSessionID == record.id, sessions.isRunning {
                    if steerHandler?(record.id, message) == true {
                        return .response(json([
                            "accepted": .bool(true),
                            "steered": .bool(true),
                            "queued": .bool(false),
                            "sessionID": .string(record.id.uuidString),
                        ], status: 202))
                    }
                    return .response(json(["error": .string("Vamp Assistant could not steer this turn. Try again or stop the current task.")], status: 409))
                }
            }
            if let enqueueTaskHandler {
                if let task = enqueueTaskHandler(record.id, message) {
                    return .response(json([
                        "accepted": .bool(true),
                        "queued": .bool(true),
                        "taskID": .string(task.id.uuidString),
                        "state": .string(task.state.rawValue),
                        "sessionID": .string(record.id.uuidString),
                    ], status: 202))
                }

                // Queue persistence can be temporarily unavailable when the
                // user's Keychain is locked or needs approval. Pairing and
                // transcript reads do not use that store, so rejecting here
                // made the remote surface look connected but unable to send.
                // An idle session can safely continue directly; only an
                // already-busy agent still requires the durable queue.
                guard !sessions.isRunning else {
                    return .response(json(["error": .string("Vamp Assistant is already working and the task queue is unavailable. Try again when the current task finishes.")], status: 409))
                }
                guard sessions.continuePersistedSession(id: record.id, message: message) else {
                    return .response(json(["error": .string("That session could not be resumed. Check that its workspace and model are available.")], status: 409))
                }
                return .response(json([
                    "accepted": .bool(true),
                    "queued": .bool(false),
                    "fallback": .bool(true),
                    "sessionID": .string(record.id.uuidString),
                ], status: 202))
            }
            guard !sessions.isRunning else {
                return .response(json(["error": .string("Vamp Assistant is already working on another prompt.")], status: 409))
            }
            guard sessions.continuePersistedSession(id: record.id, message: message) else {
                return .response(json(["error": .string("That session could not be resumed. Check that its workspace still exists.")], status: 409))
            }
            return .response(json([
                "accepted": .bool(true),
                "sessionID": .string(record.id.uuidString),
            ], status: 202))
        }

        if components.count == 4, components[3] == "approval", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  let pending = sessions.pendingApproval,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == pending.id,
                  let approved = request.bodyJSON?.objectValue?["approved"]?.boolValue else {
                return .response(json(["error": .string("That approval is no longer pending.")], status: 409))
            }
            // New companion clients may change Auto/Full Access from the
            // approval card itself. Apply those optional run-scoped values
            // before resuming the loop; an old client that omits them keeps
            // the existing mode untouched.
            let approvalBody = request.bodyJSON?.objectValue
            if approvalBody?["autoMode"] != nil || approvalBody?["fullAccess"] != nil {
                configureRunHandler?(runOptions(from: request))
            }
            let always = request.bodyJSON?.objectValue?["always"]?.boolValue ?? false
            sessions.approve(approved, always: always)
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "question", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  let pendingID = sessions.pendingQuestionRequestID,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == pendingID,
                  let answer = request.bodyJSON?.objectValue?["answer"]?.stringValue,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= Self.maxMessageBytes else {
                return .response(json(["error": .string("That question is no longer pending, or the answer is invalid.")], status: 409))
            }
            sessions.answerQuestion(answer)
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "plan", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning,
                  sessions.pendingPlan != nil,
                  let requestID = request.bodyJSON?.objectValue?["requestID"]?.stringValue,
                  UUID(uuidString: requestID) == sessions.pendingPlanRequestID,
                  let action = request.bodyJSON?.objectValue?["action"]?.stringValue else {
                return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
            }
            let planBody = request.bodyJSON?.objectValue
            if planBody?["autoMode"] != nil || planBody?["fullAccess"] != nil {
                configureRunHandler?(runOptions(from: request))
            }
            switch action {
            case "approve":
                guard sessions.approvePlan(requestID: UUID(uuidString: requestID)) else {
                    return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
                }
            case "revise":
                guard let feedback = request.bodyJSON?.objectValue?["feedback"]?.stringValue,
                      !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      feedback.utf8.count <= Self.maxMessageBytes else {
                    return .response(json(["error": .string("Plan feedback must be non-empty and under 20 KB.")], status: 400))
                }
                guard sessions.revisePlan(feedback, requestID: UUID(uuidString: requestID)) else {
                    return .response(json(["error": .string("That plan is no longer pending.")], status: 409))
                }
            default:
                return .response(json(["error": .string("Use approve or revise for a pending plan.")], status: 400))
            }
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "stop", request.method == "POST" {
            guard sessions.activeSessionID == id, sessions.isRunning else {
                return .response(json(["error": .string("That session is not running.")], status: 409))
            }
            sessions.stop()
            return .response(json(["accepted": .bool(true)]))
        }

        // Undo the last git checkpoint. Refused while the agent is running: the
        // loop would keep writing into a tree that had just been rewound.
        if components.count == 4, components[3] == "undo", request.method == "POST" {
            guard sessions.activeSessionID == id else {
                return .response(json(["error": .string("Open that session on the Mac first.")], status: 409))
            }
            guard !sessions.isRunning else {
                return .response(json(["error": .string("Stop the run before undoing a checkpoint.")], status: 409))
            }
            guard SessionStore.shared.load(id: id)?.checkpoints.last != nil else {
                return .response(json(["error": .string("This session has no checkpoint to restore.")], status: 404))
            }
            sessions.undoLastCheckpoint()
            return .response(json(["accepted": .bool(true)]))
        }

        if components.count == 4, components[3] == "queue", request.method == "POST" {
            guard let taskID = request.bodyJSON?.objectValue?["taskID"]?.stringValue.flatMap(UUID.init),
                  request.bodyJSON?.objectValue?["action"]?.stringValue == "cancel" else {
                return .response(json(["error": .string("Cancel a queued follow-up with taskID and action=cancel.")], status: 400))
            }
            guard removeQueuedTaskHandler?(id, taskID) == true else {
                return .response(json(["error": .string("That follow-up is no longer queued.")], status: 409))
            }
            return .response(json(["accepted": .bool(true)]))
        }

        return .response(json(["error": .string("Unknown endpoint.")], status: 404))
    }

    private func sessionSummaries() -> [LFJSONValue] {
        let activeID = sessions.activeSessionID
        return SessionStore.shared.cachedAll(maxAge: 2)
            .filter { $0.source == .app }
            .prefix(100)
            .map { record in
                .object([
                    "id": .string(record.id.uuidString),
                    "title": .string(Self.displayTitle(record)),
                    "workspace": .string(Self.workspaceName(record.workspacePath)),
                    "workspacePath": record.workspacePath.isEmpty ? .null : .string(record.workspacePath),
                    "mode": .string(record.workspacePath.isEmpty ? "chat" : "code"),
                    "messageCount": .number(Double(record.messages.count)),
                    "updatedAt": .number(record.updatedAt.timeIntervalSince1970),
                    "isCurrent": .bool(activeID == record.id),
                    "isRunning": .bool(activeID == record.id && sessions.isRunning),
                    "phase": .string(activeID == record.id ? sessions.currentPhase.rawValue : AgentPhase.idle.rawValue),
                    "queueState": taskLookupHandler?(record.id).map { .string($0.state.rawValue) } ?? .null,
                ])
            }
    }

    private func sessionDetail(_ record: SessionRecord) -> [String: LFJSONValue] {
        let activeID = sessions.activeSessionID
        let isCurrent = activeID == record.id
        let isRunning = isCurrent && sessions.isRunning
        let messages = isCurrent
            ? liveMessages(record: record)
            : persistedMessages(record)
        let liveText = isRunning
            ? String(SessionStore.redact(sessions.streamingText).prefix(16_000))
            : ""
        let remoteAgentMode = isCurrent
            ? sessions.remoteRunAgentMode
            : nil
        let remoteFullAccess = isCurrent
            ? sessions.remoteRunHasFullAccess
            : nil
        var detail: [String: LFJSONValue] = [
            "id": .string(record.id.uuidString),
            "title": .string(Self.displayTitle(record)),
            "workspace": .string(Self.workspaceName(record.workspacePath)),
            "workspacePath": record.workspacePath.isEmpty ? .null : .string(record.workspacePath),
            "mode": .string(record.workspacePath.isEmpty ? "chat" : "code"),
            "modelID": .string(record.modelID),
            "updatedAt": .number(record.updatedAt.timeIntervalSince1970),
            "messages": .array(Array(messages)),
            "isCurrent": .bool(isCurrent),
            "isRunning": .bool(isRunning),
            "phase": .string(isCurrent ? sessions.currentPhase.rawValue : AgentPhase.idle.rawValue),
            "streamingText": .string(liveText),
            // Active remote options are session-scoped. Falling back to the
            // Mac's global settings here made the phone show the wrong mode,
            // then send a new turn with unexpected approval behavior.
            "agentMode": .string(remoteAgentMode ?? SettingsStore.shared.agentMode.rawValue),
            "fullAccess": .bool(
                remoteFullAccess
                    ?? (SettingsStore.shared.remoteFullAccessEnabled
                        || SettingsStore.shared.agentMode == .auto)),
        ]
        detail["pending"] = pendingInteraction(for: record.id)
        detail["error"] = errorPresentation(for: record)
        if let task = taskLookupHandler?(record.id) {
            detail["queue"] = .object([
                "id": .string(task.id.uuidString),
                "state": .string(task.state.rawValue),
                "label": .string(task.phase ?? task.state.label),
                "attempts": .number(Double(task.attempts)),
            ])
        }
        let queued = queuedTasksHandler?(record.id) ?? []
        detail["queued"] = .array(queued.map { task in
            .object([
                "id": .string(task.id.uuidString),
                "message": .string(String(SessionStore.redact(task.message).prefix(240))),
                "state": .string(task.state.rawValue),
                "label": .string(task.phase ?? task.state.label),
            ])
        })
        return detail
    }

    private func persistedMessages(_ record: SessionRecord) -> [LFJSONValue] {
        let messages = record.messages.enumerated().filter { $0.element.role != .system }
        return messages.suffix(120).map { offset, message in
            let content = String(SessionStore.redact(message.content).prefix(16_000))
            let role = message.role == .assistant && content.lowercased().hasPrefix("error:")
                ? "error"
                : message.role.rawValue
            return .object([
                "id": .string("\(record.id.uuidString):message:\(offset)"),
                "role": .string(role),
                "content": .string(content),
                "toolName": message.toolName.map { .string($0) } ?? .null,
                "timestamp": .number(message.timestamp.timeIntervalSince1970),
            ])
        }
    }

    private func liveMessages(record: SessionRecord) -> [LFJSONValue] {
        let items = sessions.transcript.suffix(120)
        guard !items.isEmpty else { return persistedMessages(record) }
        let baseTimestamp = record.createdAt.timeIntervalSince1970
        return items.enumerated().map { offset, item in
            let role: String
            let content: String
            let toolName: String?
            // Extra structure the flat role/content pair cannot carry: whether a
            // tool failed, and which checkpoint a revert would target. Clients
            // that do not know these keys ignore them.
            var failed: Bool?
            var checkpointID: String?
            switch item.kind {
            case .user(let text):
                role = "user"; content = text; toolName = nil
            case .assistant(let text):
                role = text.lowercased().hasPrefix("error:") ? "error" : "assistant"
                content = text; toolName = nil
            case .toolCall(let invocation):
                role = "toolCall"; content = invocation.argumentsJSON; toolName = invocation.name
            case .toolResult(_, let output, let didFail, let name):
                role = "toolResult"; content = output; toolName = name
                failed = didFail
            case .reasoning(let text):
                role = "reasoning"; content = text; toolName = nil
            case .checkpoint(let checkpoint):
                // A real kind, not a stringified notice: the client needs the id
                // to offer a revert.
                role = "checkpoint"; content = checkpoint.summary; toolName = nil
                checkpointID = checkpoint.id.uuidString
            case .notice(let text):
                role = text.lowercased().hasPrefix("error:") ? "error" : "notice"
                content = text; toolName = nil
            }
            return .object([
                "id": .string(item.id.uuidString),
                "role": .string(role),
                "content": .string(String(SessionStore.redact(content).prefix(16_000))),
                "toolName": toolName.map { .string($0) } ?? .null,
                "failed": failed.map { .bool($0) } ?? .null,
                "checkpointID": checkpointID.map { .string($0) } ?? .null,
                "timestamp": .number(baseTimestamp + Double(offset) / 1_000),
            ])
        }
    }

    /// Gives GET and SSE responses one ordering domain. The client can reject
    /// an older in-flight event after a newer approval/detail response lands.
    /// Older clients ignore the additive revision and message-id fields.
    private func sessionSnapshot(_ record: SessionRecord) -> CachedSessionSnapshot {
        let baseDetail = sessionDetail(record)
        let content = LFJSONValue.object(baseDetail).encoded()
        if let cached = sessionSnapshotCache[record.id], cached.content == content {
            return cached
        }
        // Session history can be large and long lived. The cache only exists to
        // avoid rebuilding snapshots for currently active clients, so keep a
        // modest ceiling instead of retaining every session opened since launch.
        if sessionSnapshotCache[record.id] == nil,
           sessionSnapshotCache.count >= 128,
           let oldestID = sessionSnapshotCache.min(by: { $0.value.revision < $1.value.revision })?.key {
            sessionSnapshotCache.removeValue(forKey: oldestID)
        }
        sessionSnapshotSequence &+= 1
        var detail = baseDetail
        detail["revision"] = .number(Double(sessionSnapshotSequence))
        let snapshot = CachedSessionSnapshot(
            content: content,
            revision: sessionSnapshotSequence,
            detail: detail,
            encoded: LFJSONValue.object(detail).encoded())
        sessionSnapshotCache[record.id] = snapshot
        return snapshot
    }

    /// A bounded change detector for the hot SSE loop. It intentionally hashes
    /// only live/tail state; the expensive 120-message JSON is rebuilt only
    /// when this signal changes or the persisted record is refreshed.
    private func sessionEventSignal(_ record: SessionRecord) -> String {
        let tail = sessions.transcript.last.map {
            "\($0.id.uuidString):\(String(describing: $0.kind).hashValue)"
        } ?? "none"
        let task = taskLookupHandler?(record.id)
        let queued = (queuedTasksHandler?(record.id) ?? []).map {
            "\($0.id.uuidString):\($0.state.rawValue):\($0.phase ?? "")"
        }.joined(separator: ",")
        let pendingInteractionHash = pendingInteraction(for: record.id).encoded().hashValue
        let errorPresentationHash = errorPresentation(for: record).encoded().hashValue
        let taskSignal: String
        if let task {
            taskSignal = "\(task.id.uuidString):\(task.state.rawValue):\(task.phase ?? "")"
        } else {
            taskSignal = "none"
        }
        let components: [String] = [
            String(record.updatedAt.timeIntervalSince1970),
            String(record.messages.count),
            sessions.activeSessionID?.uuidString ?? "none",
            String(sessions.isRunning),
            sessions.currentPhase.rawValue,
            String(sessions.streamingText.hashValue),
            String(sessions.transcript.count),
            tail,
            String(pendingInteractionHash),
            String(errorPresentationHash),
            sessions.remoteRunAgentMode ?? "none",
            String(sessions.remoteRunHasFullAccess ?? false),
            taskSignal,
            queued,
        ]
        return components.joined(separator: "|")
    }

    private func errorPresentation(
        for record: SessionRecord
    ) -> LFJSONValue {
        if sessions.activeSessionID == record.id,
           case .engineError(let message)? = sessions.finishReason {
            return .object([
                "title": .string("API or model error"),
                "message": .string(String(SessionStore.redact(message).prefix(16_000))),
            ])
        }
        return .null
    }

    private func cancelEventStreams(matching digest: String?) {
        if let digest {
            revokedEventDigests.insert(digest)
        } else {
            eventStreamGeneration &+= 1
            revokedEventDigests.removeAll()
        }
    }

    private func sessionEventStream(id: UUID, digest: String) -> LocalAPIServer.RouteResult {
        let generation = eventStreamGeneration
        let lines = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self, var record = self.ownedRecord(id) else {
                    continuation.finish()
                    return
                }
                var previousSignal: String?
                var previousRevision: UInt64?
                var heartbeatTick = 0
                var persistedRecordTick = 0
                while !Task.isCancelled {
                    guard self.eventStreamGeneration == generation,
                          !self.revokedEventDigests.contains(digest) else { break }
                    self.pruneExpiredTokens()
                    guard self.tokens[digest] != nil else { break }
                    if persistedRecordTick >= 14 {
                        guard let refreshed = self.ownedRecord(id) else { break }
                        record = refreshed
                        persistedRecordTick = 0
                    }
                    let signal = self.sessionEventSignal(record)
                    if signal != previousSignal {
                        let snapshot = self.sessionSnapshot(record)
                        if snapshot.revision != previousRevision {
                            continuation.yield(Data("event: session\ndata: \(snapshot.encoded)\n\n".utf8))
                            previousRevision = snapshot.revision
                        }
                        previousSignal = signal
                        heartbeatTick = 0
                    } else if heartbeatTick >= 40 {
                        continuation.yield(Data(": keep-alive\n\n".utf8))
                        heartbeatTick = 0
                    }
                    heartbeatTick += 1
                    persistedRecordTick += 1
                    try? await Task.sleep(for: .milliseconds(150))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var response = LocalAPIServer.Response(
            status: 200,
            contentType: "text/event-stream; charset=utf-8")
        response.headers = Self.securityHeaders
        return .stream(response, lines: lines)
    }

    private func applyContinueModel(sessionID: UUID, modelID: String, reasoningEffort: String?) async -> String? {
        if let error = await applyModelHandler?(modelID, reasoningEffort) {
            return error
        }
        guard var record = SessionStore.shared.load(id: sessionID) else { return nil }
        let parts = modelID.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.first == "chatgpt", parts.count >= 2 {
            record.modelID = "openai-codex:\(parts[1])"
        } else {
            record.modelID = parts.last ?? modelID
        }
        _ = SessionStore.shared.save(record)
        SessionStore.shared.invalidateCache()
        return nil
    }

    private func runOptions(from request: LocalAPIServer.Request) -> RemoteRunOptions {
        let object = request.bodyJSON?.objectValue
        let chatOnly = object?["chatOnly"]?.boolValue == true
        let workspacePath = chatOnly ? nil : object?["workspacePath"]?.stringValue
        return RemoteRunOptions(
            autoMode: object?["autoMode"]?.boolValue ?? true,
            fullAccess: object?["fullAccess"]?.boolValue ?? false,
            reasoningEffort: object?["reasoningEffort"]?.stringValue,
            botProfileID: {
                let raw = object?["botProfileID"]?.stringValue
                guard let raw, !raw.isEmpty, raw != "general" else { return nil }
                return raw
            }(),
            botComputerID: object?["botComputerID"]?.stringValue.flatMap(UUID.init),
            botWorkspacePath: nil,
            botContainerName: nil,
            botContainerExecutable: nil,
            workspacePath: workspacePath,
            botBrowser: nil)
    }

    private var taskQueueCount: Int {
        Set(SessionStore.shared.cachedAll(maxAge: 2).compactMap { record in
            taskLookupHandler?(record.id)?.id
        }).count
    }

    private func ownedRecord(_ id: UUID) -> SessionRecord? {
        guard let record = SessionStore.shared.load(id: id),
              record.source == .app,
              SessionStore.shared.validateWorkspaceBinding(record) else { return nil }
        return record
    }

    private func authorized(_ request: LocalAPIServer.Request) -> Bool {
        pruneExpiredTokens()
        guard let digest = tokenDigest(from: request) else { return false }
        return tokens[digest] != nil
    }

    static func isSecureRemoteUnlockPeer(_ address: String) -> Bool {
        if RemoteNetworkEndpointDiscovery.isTailscale(address) { return true }
        #if DEBUG
        // Unit tests and the iOS Simulator can exercise the route without
        // weakening release builds for ordinary LAN peers.
        return address == "127.0.0.1" || address == "::1"
        #else
        return false
        #endif
    }

    private func tokenDigest(from request: LocalAPIServer.Request) -> String? {
        guard let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : Self.tokenDigest(token)
    }

    private func pruneExpiredTokens() {
        let now = Date()
        let next = tokens.filter { $0.value > now }
        guard next.count != tokens.count else { return }
        tokens = next
        persistPairedClients()
    }

    private func persistPairedClients() {
        guard persistsPairedClients else { return }
        RemotePairedClientStore.save(tokens)
    }

    private func sharedFileResponse(_ request: LocalAPIServer.Request) -> LocalAPIServer.Response {
        let prefix = "/api/files/"
        let encodedName = String(request.path.dropFirst(prefix.count))
        guard !encodedName.isEmpty else {
            return json(["error": .string("A shared file name is required.")], status: 400)
        }
        do {
            let result = try sharing.data(for: encodedName.removingPercentEncoding ?? encodedName)
            return LocalAPIServer.Response(
                status: 200,
                contentType: result.contentType,
                body: result.data,
                headers: Self.securityHeaders + [
                    ("Content-Disposition", "attachment; filename=\"\(Self.safeHeaderFileName(result.file.name))\""),
                ])
        } catch {
            return json(["error": .string(error.localizedDescription)], status: 404)
        }
    }

    private static func safeHeaderFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private func unauthorized() -> LocalAPIServer.RouteResult {
        .response(json(["error": .string("Pair this browser with the code shown in Vamp Assistant.")], status: 401))
    }

    private func json(_ fields: [String: LFJSONValue], status: Int = 200) -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response.json(.object(fields), status: status)
        response.headers = Self.securityHeaders
        return response
    }

    private func htmlPage() -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response.html(RemoteSessionPage.html)
        response.headers = Self.securityHeaders + [
            ("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"),
            ("X-Frame-Options", "DENY"),
        ]
        return response
    }

    private static let publicImages: [String: String] = [
        "/assets/vamp-backdrop.png": "WindowAtmosphere",
        "/assets/vamp-icon.png": "VampBackdrop",
        "/assets/bot-builder-light.png": "BotBuilderLight",
        "/assets/bot-builder-dark.png": "BotBuilderDark",
        "/assets/bot-reviewer-light.png": "BotReviewerLight",
        "/assets/bot-reviewer-dark.png": "BotReviewerDark",
        "/assets/bot-navigator-light.png": "BotNavigatorLight",
        "/assets/bot-navigator-dark.png": "BotNavigatorDark",
        "/assets/bot-researcher-light.png": "BotResearcherLight",
        "/assets/bot-researcher-dark.png": "BotResearcherDark",
    ]

    private func imageResponse(named name: String) -> LocalAPIServer.Response {
        guard let image = NSImage(named: NSImage.Name(name)),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return LocalAPIServer.Response(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Logo unavailable".utf8), headers: Self.securityHeaders)
        }
        return LocalAPIServer.Response(
            status: 200,
            contentType: "image/png",
            body: png,
            headers: Self.securityHeaders + [("Content-Disposition", "inline")])
    }

    private func securityResponse(status: Int, contentType: String) -> LocalAPIServer.Response {
        var response = LocalAPIServer.Response(status: status, contentType: contentType)
        response.headers = Self.securityHeaders
        return response
    }

    private static let securityHeaders: [(String, String)] = [
        ("Cache-Control", "no-store, max-age=0"),
        ("Pragma", "no-cache"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]

    private func allowedOrigin(_ request: LocalAPIServer.Request) -> Bool {
        guard let rawOrigin = request.headers["origin"], !rawOrigin.isEmpty else { return true }
        guard rawOrigin != "null",
              !rawOrigin.contains(where: { $0 == "\r" || $0 == "\n" }),
              let origin = URLComponents(string: rawOrigin),
              let scheme = origin.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let originHost = origin.host?.lowercased(),
              let hostHeader = request.headers["host"],
              let hostComponents = URLComponents(string: "http://\(hostHeader)"),
              let requestHost = hostComponents.host?.lowercased(),
              originHost == requestHost,
              origin.user == nil,
              origin.password == nil,
              origin.path.isEmpty,
              origin.query == nil,
              origin.fragment == nil else { return false }
        let originPort = origin.port ?? (scheme == "https" ? 443 : 80)
        let expectedPort = hostComponents.port ?? 80
        guard originPort == expectedPort,
              expectedPort == boundPort else { return false }

        // The Host header alone is not an origin allowlist: a DNS-rebinding
        // page could make both Host and Origin attacker-controlled. Accept
        // the advertised numeric endpoint, plus explicit loopback access for
        // local debugging, and reject every other browser origin.
        let trustedHosts = Set([networkHost?.lowercased(), "127.0.0.1", "localhost"].compactMap { $0 })
        if trustedHosts.contains(originHost) { return true }
        return allowLANPeers && RemoteNetworkEndpointDiscovery.isPrivateIPv4(originHost)
    }

    private func allowedPeer(_ address: String) -> Bool {
        RemoteNetworkEndpointDiscovery.allowsPeer(
            address,
            advertisedKind: networkKind,
            allowLAN: allowLANPeers)
    }

    private func pendingInteraction(for id: UUID) -> LFJSONValue {
        guard sessions.activeSessionID == id else { return .null }
        if let approval = sessions.pendingApproval {
            let preview: LFJSONValue
            switch approval.preview {
            case .none:
                preview = .object(["kind": .string("none")])
            case .command(let command):
                preview = .object([
                    "kind": .string("command"),
                    "content": .string(String(command.prefix(12_000))),
                ])
            case .diff(let diff, let path):
                preview = .object([
                    "kind": .string("diff"),
                    "path": .string(path),
                    "content": .string(String(diff.unified.prefix(12_000))),
                    "added": .number(Double(diff.addedCount)),
                    "removed": .number(Double(diff.removedCount)),
                ])
            }
            return .object([
                "kind": .string("approval"),
                "requestID": .string(approval.id.uuidString),
                "toolName": .string(approval.invocation.name),
                "summary": .string(String(approval.invocation.summary.prefix(12_000))),
                "preview": preview,
            ])
        }
        if let question = sessions.pendingQuestion,
           let requestID = sessions.pendingQuestionRequestID {
            return .object([
                "kind": .string("question"),
                "requestID": .string(requestID.uuidString),
                "content": .string(String(question.prefix(12_000))),
                "options": .array(sessions.pendingQuestionChoices.map { .string($0) }),
            ])
        }
        if let plan = sessions.pendingPlan {
            return .object([
                "kind": .string("plan"),
                "requestID": sessions.pendingPlanRequestID.map { .string($0.uuidString) } ?? .null,
                "content": .string(String(plan.prefix(16_000))),
            ])
        }
        return .null
    }

    private func canAttemptPairing(from address: String) -> Bool {
        prunePairFailures()
        guard let window = pairFailuresByAddress[address] else { return true }
        return window.count < Self.maxPairFailuresPerWindow
    }

    private func recordPairFailure(from address: String) {
        prunePairFailures()
        let now = Date()
        var window = pairFailuresByAddress[address] ?? PairFailureWindow(count: 0, firstAt: now)
        window.count += 1
        pairFailuresByAddress[address] = window
        if window.count >= Self.maxPairFailuresPerWindow {
            rotatePairingCode()
        }
    }

    private func prunePairFailures() {
        let now = Date()
        pairFailuresByAddress = pairFailuresByAddress.filter {
            now.timeIntervalSince($0.value.firstAt) < Self.pairFailureWindow
        }
    }

    private static func displayTitle(_ record: SessionRecord) -> String {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "Session" ? "Untitled session" : title
    }

    private static func workspaceName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Chat" }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? "Project" : name
    }

    private func workspaceListJSON() -> [String: LFJSONValue] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let createParentURL = RemoteWorkspaceCatalog.defaultCreateParent(home: home)
        try? FileManager.default.createDirectory(at: createParentURL, withIntermediateDirectories: true)
        let createParent = createParentURL.path
        let items = RemoteWorkspaceCatalog.list(
            currentPath: sessions.workspaceURL?.path,
            lastPath: AppPreferencesStore.shared.current.lastWorkspacePath,
            records: SessionStore.shared.cachedAll(maxAge: 2).map {
                (path: $0.workspacePath, updatedAt: $0.updatedAt)
            },
            home: home)
        return [
            "workspaces": .array(items.map { item in
                .object([
                    "path": .string(item.path),
                    "name": .string(item.name),
                    "isCurrent": .bool(item.isCurrent),
                ])
            }),
            "createParent": .string(createParent),
        ]
    }

    private func knownWorkspacePaths() -> [String] {
        RemoteWorkspaceCatalog.list(
            currentPath: sessions.workspaceURL?.path,
            lastPath: AppPreferencesStore.shared.current.lastWorkspacePath,
            records: SessionStore.shared.cachedAll(maxAge: 2).map {
                (path: $0.workspacePath, updatedAt: $0.updatedAt)
            }).map(\.path)
    }

    private func createOrOpenWorkspace(_ request: LocalAPIServer.Request) -> LocalAPIServer.RouteResult {
        let object = request.bodyJSON?.objectValue
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = knownWorkspacePaths()
        do {
            let url: URL
            if let path = object?["path"]?.stringValue,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                url = try RemoteWorkspaceCatalog.resolveExisting(path, home: home, knownPaths: known)
            } else if let name = object?["name"]?.stringValue {
                url = try RemoteWorkspaceCatalog.createFolder(
                    name: name,
                    parentPath: object?["parentPath"]?.stringValue,
                    home: home,
                    knownPaths: known)
            } else {
                return .response(json(["error": .string("Choose an existing folder or enter a name for a new one.")], status: 400))
            }
            var preferences = AppPreferencesStore.shared.current
            preferences.lastWorkspacePath = url.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: url)
            AppPreferencesStore.shared.save(preferences)
            return .response(json([
                "path": .string(url.path),
                "name": .string(url.lastPathComponent),
            ], status: 201))
        } catch {
            return .response(json(["error": .string(error.localizedDescription)], status: 400))
        }
    }

    private static func makePairingCode() -> String {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        let number = status == errSecSuccess ? Int(value % 1_000_000) : Int.random(in: 0...999_999)
        return String(format: "%06d", number)
    }

    private static func makeToken() -> String {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            data = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func tokenDigest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizePairingCode(_ raw: String) -> String? {
        var digits = ""
        digits.reserveCapacity(6)
        for character in raw {
            if character.isWhitespace || character == "-" || character == "·" { continue }
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            digits.append(String(value))
        }
        return digits.count == 6 ? digits : nil
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt8(left.count ^ right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Chooses a phone-reachable address. Tailscale's CGNAT range wins so the QR
/// works away from home; otherwise the first private LAN address is used only
/// when the user explicitly enables that fallback.
enum RemoteNetworkEndpointDiscovery {
    struct Endpoint: Equatable, Sendable {
        let host: String
        let kind: RemoteNetworkKind
    }

    enum TailscaleCLIStatus: Equatable, Sendable {
        case running(String)
        case stopped
        case unavailable
    }

    static func preferredHost() -> String? {
        preferredEndpoint(allowLAN: true)?.host
    }

    static func preferredEndpoint(allowLAN: Bool) -> Endpoint? {
        selectEndpoint(
            addresses: interfaceIPv4Addresses(),
            allowLAN: allowLAN,
            tailscaleStatus: tailscaleCLIStatus())
    }

    static func selectEndpoint(
        addresses: [String],
        allowLAN: Bool,
        tailscaleStatus: TailscaleCLIStatus
    ) -> Endpoint? {
        if case .running(let host) = tailscaleStatus, isTailscale(host) {
            return Endpoint(host: host, kind: .tailscale)
        }
        let lan = addresses.first { isPrivateIPv4($0) }
        if tailscaleStatus == .unavailable,
           let host = addresses.first(where: isTailscale) {
            return Endpoint(host: host, kind: .tailscale)
        }
        guard allowLAN, let lan else { return nil }
        return Endpoint(host: lan, kind: .localNetwork)
    }

    static func tailscaleCLIStatus() -> TailscaleCLIStatus {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        var foundExecutable = false
        for executable in candidates where FileManager.default.isExecutableFile(atPath: executable) {
            foundExecutable = true
            do {
                let result = try ShellRunner.runProcess(
                    executable: executable,
                    arguments: ["status", "--json"],
                    workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
                    timeout: 3,
                    maxOutputBytes: 512 * 1024)
                // Some Tailscale app bundles expose a GUI executable at the
                // expected path but not the CLI protocol. Keep looking for a
                // working CLI instead of treating that candidate as offline.
                guard !result.failed else { continue }
                return parseTailscaleStatusJSON(result.output)
            } catch {
                continue
            }
        }
        return foundExecutable ? .stopped : .unavailable
    }

    static func parseTailscaleStatusJSON(_ text: String) -> TailscaleCLIStatus {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .stopped }
        guard (json["BackendState"] as? String)?.lowercased() == "running" else {
            return .stopped
        }
        if let selfStatus = json["Self"] as? [String: Any],
           selfStatus["Online"] as? Bool == false {
            return .stopped
        }
        let addresses = json["TailscaleIPs"] as? [String] ?? []
        guard let host = addresses.first(where: isTailscale) else { return .stopped }
        return .running(host)
    }

    private static func interfaceIPv4Addresses() -> [String] {
        var values: [String] = []
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return [] }
        defer { freeifaddrs(interfacePointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard value != "127.0.0.1" else { continue }
            values.append(value)
        }
        return values
    }

    static func isTailscale(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 || parts[0] == 192 && parts[1] == 168 { return true }
        return parts[0] == 172 && (16...31).contains(parts[1])
    }

    static func allowsPeer(
        _ address: String,
        advertisedKind: RemoteNetworkKind?,
        allowLAN: Bool
    ) -> Bool {
        guard address != "unknown" else { return false }
        if address == "127.0.0.1" || address == "::1" { return true }
        if allowLAN, isPrivateIPv4(address) { return true }
        switch advertisedKind {
        case .tailscale:
            return isTailscale(address)
        case .localNetwork:
            return isPrivateIPv4(address)
        case nil:
            return false
        }
    }
}

/// Stores only SHA-256 token digests and expiry dates. The bearer token stays
/// on the paired device, while the Mac can still recognize it after the host
/// is restarted. These values are identifiers, not credentials, so keeping
/// them in app preferences avoids Keychain ACL prompts after an ad-hoc update.
/// The legacy Keychain item is intentionally left untouched for upgrade
/// compatibility, but is no longer read during launch.
private enum RemotePairedClientStore {
    private static let defaultsKey = "remote.paired-client-digests.v2"
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: [String: Date]?

    static func load() -> [String: Date] {
        cacheLock.lock()
        if let cached {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([String: Double].self, from: data) else {
            cacheLock.lock()
            cached = [:]
            cacheLock.unlock()
            return [:]
        }
        let now = Date()
        let loaded = values.reduce(into: [String: Date]()) { result, item in
            let expiration = Date(timeIntervalSince1970: item.value)
            if expiration > now { result[item.key] = expiration }
        }
        cacheLock.lock()
        cached = loaded
        cacheLock.unlock()
        return loaded
    }

    static func save(_ tokens: [String: Date]) {
        cacheLock.lock()
        cached = tokens
        cacheLock.unlock()
        let values = tokens.mapValues(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(values) else { return }
        if tokens.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
