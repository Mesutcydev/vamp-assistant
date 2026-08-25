import Foundation

struct RemotePairResponse: Decodable {
    let token: String
    let expiresAt: Double
}

struct RemoteStatus: Decodable {
    let pairedClients: Int
    let networkKind: String
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
    let displayX: Double?
    let displayY: Double?
    let displayWidth: Double?
    let displayHeight: Double?
    let displays: [RemoteMacDisplay]?
    let message: String?
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

struct RemoteMacApplication: Decodable, Equatable, Identifiable {
    let windowID: Int
    let bundleIdentifier: String?
    let name: String
    let windowTitle: String?
    let width: Double
    let height: Double

    var id: Int { windowID }

    var detail: String {
        guard let windowTitle, !windowTitle.isEmpty, windowTitle != name else {
            return "\(Int(width))×\(Int(height))"
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
    let role: String
    let content: String
    let toolName: String?
    let timestamp: Double

    var id: String { "\(timestamp)-\(role)-\(content.hashValue)" }
}

struct RemotePendingInteraction: Decodable {
    let kind: String
    let requestID: String?
    let toolName: String?
    let summary: String?
    let content: String?
    let options: [String]?
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
    case server(String)
    case invalidResponse
    case invalidResponseReason(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter the private Vamp Assistant address shown on your Mac."
        case .insecurePublicAddress: "Plain HTTP is allowed only for private Tailscale or local-network addresses."
        case .invalidPairingCode: "Enter the six-digit pairing code shown by Vamp Assistant."
        case .notConnected: "Connect to your Mac first."
        case .server(let message): message
        case .invalidResponse: "Vamp Assistant returned an unreadable response."
        case .invalidResponseReason(let reason): "Vamp Assistant stream error: \(reason)"
        }
    }
}
