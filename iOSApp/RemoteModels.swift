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
}

struct RemoteSessionEnvelope: Decodable {
    let sessions: [RemoteSessionSummary]
}

struct RemoteModelEnvelope: Decodable { let models: [RemoteStartModelOption] }

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
}

struct RemoteSessionSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let workspace: String
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
    let modelID: String
    let messages: [RemoteMessage]
    let isRunning: Bool
    let phase: String
    let streamingText: String
    let pending: RemotePendingInteraction?
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
}

struct RemoteAcceptedResponse: Decodable {
    let accepted: Bool
    let queued: Bool?
    let fallback: Bool?
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

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter the private Beet Code address shown on your Mac."
        case .insecurePublicAddress: "Plain HTTP is allowed only for private Tailscale or local-network addresses."
        case .invalidPairingCode: "Enter the six-digit pairing code shown by Beet Code."
        case .notConnected: "Connect to your Mac first."
        case .server(let message): message
        case .invalidResponse: "Beet Code returned an unreadable response."
        }
    }
}
