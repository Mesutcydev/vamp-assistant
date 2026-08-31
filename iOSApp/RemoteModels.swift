import Foundation

struct RemotePairResponse: Decodable {
    let token: String
    let expiresAt: Double
}

struct RemoteStatus: Decodable {
    let pairedClients: Int
    let networkKind: String
    let tokenExpiresAt: Double?
    let isRunning: Bool
    let phase: String
    let queuedTasks: Int
    let macControl: RemoteMacControlStatus?
}

struct RemoteMacControlStatus: Decodable, Equatable {
    let enabled: Bool
    let screenRecording: Bool
    let accessibility: Bool
    let ready: Bool
    let locked: Bool?
    let remoteUnlockEnabled: Bool?
    let remoteUnlockAvailable: Bool?
    let remoteUnlockMessage: String?
    let displayX: Double?
    let displayY: Double?
    let displayWidth: Double?
    let displayHeight: Double?
    let displays: [RemoteMacDisplay]?
    let message: String?

    /// Both full Mac Control and app-only Vamp Stream use this same policy.
    /// The explicit host capability keeps the password field off unencrypted
    /// LAN paths while ensuring neither surface forgets the locked-state form.
    var shouldOfferRemoteUnlock: Bool {
        locked == true && remoteUnlockAvailable == true
    }
}

struct RemoteMacDisplay: Decodable, Equatable, Identifiable {
    let id: Int
    let name: String
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
}

struct RemoteMacApplicationEnvelope: Decodable, Equatable {
    let applications: [RemoteMacApplication]
}

struct RemoteMacApplicationResponse: Decodable, Equatable {
    let application: RemoteMacApplication
}

struct RemoteMacApplication: Decodable, Equatable, Identifiable {
    /// Installed applications do not have a window until the Mac launches
    /// them. The host intentionally encodes that state as `null`.
    let windowID: Int?
    let bundleIdentifier: String?
    let name: String
    let windowTitle: String?
    let width: Double
    let height: Double
    let isRunning: Bool?
    let isActive: Bool?
    let iconPNGBase64: String?

    /// Bundle identifiers stay stable while launch/resize replaces the
    /// registry snapshot. Older hosts may omit one, so retain a window-based
    /// fallback for protocol compatibility.
    var id: String {
        bundleIdentifier ?? windowID.map { "window:\($0)" } ?? "name:\(name)"
    }

    var isStreamable: Bool { windowID != nil }

    var detail: String {
        guard let windowID else {
            return isRunning == true ? "Open a window to stream" : "Ready to launch"
        }
        guard let windowTitle, !windowTitle.isEmpty, windowTitle != name else {
            return width > 0 && height > 0
                ? "\(Int(width))×\(Int(height))"
                : "Window \(windowID)"
        }
        return "\(windowTitle) · \(Int(width))×\(Int(height))"
    }
}

struct RemoteMacControlFrame {
    enum Payload: Equatable {
        case h264(data: Data, keyframe: Bool, parameterSets: Data?)
        case jpeg(Data) // stills only
    }

    let payload: Payload
    let imageWidth: Int
    let imageHeight: Int
    let displayX: Double
    let displayY: Double
    let displayWidth: Double
    let displayHeight: Double

    var byteCount: Int {
        switch payload {
        case .h264(let data, _, _): data.count
        case .jpeg(let data): data.count
        }
    }

    var jpegStill: Data? {
        if case .jpeg(let data) = payload { return data }
        return nil
    }

    var geometry: RemoteMacControlGeometry {
        RemoteMacControlGeometry(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            displayX: displayX,
            displayY: displayY,
            displayWidth: displayWidth,
            displayHeight: displayHeight)
    }
}

struct RemoteMacControlGeometry: Equatable, Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let displayX: Double
    let displayY: Double
    let displayWidth: Double
    let displayHeight: Double
}

struct RemoteMacAudioChunk: Sendable {
    let sampleRate: Double
    let channelCount: Int
    let pcmData: Data
}

struct RemoteTerminalOutputPayload: Decodable {
    let output: Data?
    let legacyOutput: String?

    private enum CodingKeys: String, CodingKey {
        case output = "data"
        case legacyOutput = "out"
    }

    var bytes: Data? {
        output ?? legacyOutput.flatMap { Data($0.utf8) }
    }
}

struct RemoteSessionEnvelope: Decodable {
    let sessions: [RemoteSessionSummary]
}

enum RemoteSessionMode: String, CaseIterable, Identifiable {
    case chat
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .code: "Code"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct RemoteModelEnvelope: Decodable { let models: [RemoteStartModelOption] }

struct RemoteBotComputerEnvelope: Decodable { let computers: [RemoteBotComputer]; let capabilities: RemoteBotCapabilities? }
struct RemoteBotRunEnvelope: Decodable { let runs: [RemoteBotRun] }
struct RemoteBotRun: Decodable, Identifiable, Hashable {
    struct Artifact: Decodable, Hashable, Identifiable {
        let id: UUID
        let kind: String
        let title: String
        let value: String
        let createdAt: Double
    }
    let id: UUID
    let profileID: String
    let profileName: String
    let modelID: String
    let sessionID: UUID?
    let prompt: String
    let state: String
    let phase: String
    let queuePosition: Int?
    let pendingInteraction: String?
    let latestOutput: String
    let errorMessage: String?
    let createdAt: Double
    let updatedAt: Double
    let resourceClass: String?
    let retryCount: Int?
    let workflowID: UUID?
    let dependencyRunIDs: [UUID]?
    let traceID: String?
    let artifacts: [Artifact]?

    var isTerminal: Bool { ["completed", "failed", "stopped", "interrupted"].contains(state) }
}
struct RemoteBotWorkspaceEntry: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let byteSize: Int
    let modifiedAt: Double
}

struct RemoteBotFileListing: Decodable { let path: String; let entries: [RemoteBotWorkspaceEntry] }
struct RemoteBotFileContents: Decodable { let path: String; let contents: String }
struct RemoteBotExecResult: Decodable { let output: String }

struct RemoteBotComputer: Decodable, Identifiable, Hashable {
    let id: UUID
    let profileID: String
    let name: String
    let backend: String
    let state: String
    let workspacePath: String
    let browserProfilePath: String
    let containerName: String?
    let updatedAt: Double
}
struct RemoteBotCapabilities: Decodable, Hashable {
    let architecture: String
    let macOSVersion: String
    let appleContainerExecutable: String?
    let appleContainerServiceRunning: Bool
    let supportsAppleContainers: Bool
}

struct RemoteClipboardSnapshot: Decodable {
    let text: String
    let updatedAt: Double
}

struct RemoteSharedFileEnvelope: Decodable { let files: [RemoteSharedFileItem] }

struct RemoteSharedFileItem: Decodable, Identifiable, Hashable {
    let name: String
    let size: Int
    let modifiedAt: Double

    var id: String { name }
}

struct RemoteWorkspaceEnvelope: Decodable {
    let workspaces: [RemoteWorkspace]
    let createParent: String?
}

struct RemoteWorkspace: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let isCurrent: Bool?

    var id: String { path }
}

struct RemoteWorkspaceAccepted: Decodable {
    let path: String
    let name: String
}

struct RemoteFileAcceptedResponse: Decodable {
    let accepted: Bool
    let name: String
    let size: Int
}

struct RemoteStartModelOption: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let source: String
    let detail: String
    let reasoningEfforts: [String]?
    let defaultReasoningEffort: String?
}

extension Array where Element == RemoteStartModelOption {
    func matching(sessionModelID: String) -> RemoteStartModelOption? {
        if let exact = first(where: { $0.id == sessionModelID }) { return exact }
        let short = sessionModelID.hasPrefix("openai-codex:")
            ? String(sessionModelID.dropFirst("openai-codex:".count))
            : sessionModelID
        return first { $0.id.hasSuffix("|" + short) || $0.id == short || $0.name == short }
    }
}

struct RemoteSessionSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let workspace: String
    let workspacePath: String?
    let mode: String?
    let messageCount: Int
    let updatedAt: Double
    let isRunning: Bool
    let phase: String
    let queueState: String?
}

struct RemoteSessionDetail: Decodable, Identifiable {
    let id: UUID
    /// Monotonic server snapshot revision. Older Mac hosts omit it, so the
    /// companion keeps accepting unversioned snapshots for compatibility.
    let revision: UInt64?
    let title: String
    let workspace: String
    let workspacePath: String?
    let mode: String?
    let modelID: String
    let messages: [RemoteMessage]
    let isRunning: Bool
    let phase: String
    let streamingText: String
    let pending: RemotePendingInteraction?
    let error: RemoteErrorPresentation?
    let agentMode: String?
    let fullAccess: Bool?
    let queued: [RemoteQueuedItem]?
}

struct RemoteQueuedItem: Decodable, Identifiable, Hashable {
    let id: UUID
    let message: String
    let state: String
    let label: String?
}

struct RemoteErrorPresentation: Decodable {
    let title: String
    let message: String
}

struct RemoteMessage: Decodable, Identifiable {
    /// Stable identity supplied by current Mac hosts. The legacy fallback is
    /// retained so a newly sideloaded phone can still open an older host.
    private let messageID: String?
    let role: String
    let content: String
    let toolName: String?
    let timestamp: Double
    /// Set on `toolResult`. Older Macs omit it, so a nil is "unknown", not
    /// "succeeded" — the card only shows a failure when it is explicitly true.
    let failed: Bool?
    /// Set on `checkpoint`. Its presence is what lets the client offer a revert.
    let checkpointID: String?

    var id: String { messageID ?? "\(timestamp)-\(role)-\(content.hashValue)" }

    var didFail: Bool { failed == true }

    private enum CodingKeys: String, CodingKey {
        case messageID = "id"
        case role
        case content
        case toolName
        case timestamp
        case failed
        case checkpointID
    }
}

struct RemotePendingInteraction: Decodable {
    let kind: String
    let requestID: String?
    let toolName: String?
    let summary: String?
    let content: String?
    let options: [String]?
    /// What the agent is actually asking to do: the unified diff for an edit,
    /// or the exact command for a shell run. The Mac has always sent this; the
    /// client used to drop it, which meant every approval on the phone was made
    /// against a one-line summary.
    let preview: RemoteApprovalPreview?
}

/// The concrete change behind an approval request.
struct RemoteApprovalPreview: Decodable {
    let kind: String            // "diff" | "command" | "none"
    let path: String?
    let content: String?
    let added: Int?
    let removed: Int?

    var isDiff: Bool { kind == "diff" }
    var isCommand: Bool { kind == "command" }
    var hasContent: Bool { !(content ?? "").isEmpty }

    /// Split into renderable lines, capped so a huge diff cannot lock up the
    /// transcript. The remainder is reported rather than silently dropped.
    func lines(limit: Int = 400) -> (shown: [String], hidden: Int) {
        let all = (content ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > limit else { return (all, 0) }
        return (Array(all.prefix(limit)), all.count - limit)
    }
}

struct RemoteAcceptedResponse: Decodable {
    let accepted: Bool
    let queued: Bool?
    let steered: Bool?
    let fallback: Bool?
    let sessionID: UUID?
    let taskID: UUID?
    let runID: UUID?
}

struct RemoteErrorBody: Decodable {
    let error: String
}

enum RemoteClientError: LocalizedError {
    case invalidAddress
    case insecurePublicAddress
    case invalidPairingCode
    case notConnected
    case authenticationRequired(String)
    case server(String)
    case invalidResponse
    case invalidResponseReason(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter the private Vamp Assistant address shown on your Mac."
        case .insecurePublicAddress: "Plain HTTP is allowed only for private Tailscale or local-network addresses."
        case .invalidPairingCode: "Enter the six-digit pairing code shown by Vamp Assistant."
        case .notConnected: "Connect to your Mac first."
        case .authenticationRequired(let message): message
        case .server(let message): message
        case .invalidResponse: "Vamp Assistant returned an unreadable response."
        case .invalidResponseReason(let reason): "Vamp Assistant stream error: \(reason)"
        }
    }


    var requiresPairing: Bool {
        if case .authenticationRequired = self { return true }
        return false
    }
}
