import Foundation

enum BotRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case needsApproval
    case needsInput
    case completed
    case failed
    case stopped
    case interrupted
    case recoverable

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped, .interrupted: true
        case .queued, .running, .needsApproval, .needsInput, .recoverable: false
        }
    }
}

enum BotRunResourceClass: String, Codable, Sendable {
    case remoteAPI
    case codex
    case localInference

    static func resolve(modelID: String) -> Self {
        if modelID.hasPrefix("local|") { return .localInference }
        if modelID.hasPrefix("chatgpt|") { return .codex }
        return .remoteAPI
    }
}

enum BotEvidencePhase: String, Codable, Sendable {
    case route = "Route"
    case research = "Research"
    case navigation = "Navigate"
    case code = "Code"
    case review = "Review"
    case test = "Test"
}

enum BotEvidenceConfidence: String, Codable, Sendable {
    case notRun = "not run"
    case running
    case reportedDone = "reported done"
    case verified
    case blocked
    case failed
    case cancelled
}

enum BotEvidenceKind: String, Codable, Sendable, CaseIterable {
    case sources
    case execution
    case verification
    case review
}

struct BotRunEvidence: Codable, Equatable, Sendable {
    var phase: BotEvidencePhase
    var confidence: BotEvidenceConfidence
    var required: [BotEvidenceKind]
    var observed: [BotEvidenceKind]

    var label: String { "\(phase.rawValue) · \(confidence.rawValue)" }
    var missing: [BotEvidenceKind] { required.filter { !observed.contains($0) } }
}

struct BotAcceptanceCriterion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var summary: String
    var satisfied: Bool
    var evidenceReferences: [String]
}

struct BotRunBudget: Codable, Equatable, Sendable {
    var maximumTurns: Int
    var maximumTokens: Int?
    var maximumDurationSeconds: TimeInterval
    var maximumRetries: Int
    var maximumDelegationDepth: Int

    static let standard = Self(
        maximumTurns: 30, maximumTokens: nil,
        maximumDurationSeconds: 30 * 60,
        maximumRetries: 1, maximumDelegationDepth: 2)
}

struct BotRunArtifact: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case summary, file, evidence, verification, diagnostic }
    var id: UUID
    var kind: Kind
    var title: String
    var value: String
    var createdAt: Date
}

struct BotRunCheckpoint: Codable, Equatable, Sendable {
    var phase: String
    var latestOutput: String
    var sequence: Int
    var createdAt: Date
}

struct BotRunEvent: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case created, queued, started, phaseChanged, interactionRequested
        case commandAccepted, commandRejected, checkpointed, retrying
        case artifactProduced, completed, failed, cancelled, interrupted, recovered
    }
    var id: UUID
    var runID: UUID
    var sequence: Int
    var kind: Kind
    var phase: String
    var detail: String?
    var createdAt: Date
}

struct BotRunCommandRecord: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case steer, approve, decline, answer, pause, resume, cancel }
    enum State: String, Codable, Sendable { case pending, delivered, acknowledged, rejected }
    var id: UUID
    var runID: UUID
    var sequence: Int
    var kind: Kind
    var payload: String?
    var state: State
    var createdAt: Date
    var deliveredAt: Date?
    var acknowledgedAt: Date?
    var result: String?
}

struct BotRunRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var profileID: String
    var profileName: String
    var modelID: String
    var prompt: String
    var state: BotRunState
    var phase: String
    var queuePosition: Int?
    var sessionID: UUID?
    var latestOutput: String
    var pendingInteraction: String?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var resourceClass: BotRunResourceClass? = nil
    var budget: BotRunBudget? = nil
    var retryCount: Int? = nil
    var parentRunID: UUID? = nil
    var workflowID: UUID? = nil
    var dependencyRunIDs: [UUID]? = nil
    var dependencyContextAttached: Bool? = nil
    var traceID: String? = nil
    var checkpoint: BotRunCheckpoint? = nil
    var artifacts: [BotRunArtifact]? = nil
    var evidence: BotRunEvidence? = nil
    var acceptanceCriteria: [BotAcceptanceCriterion]? = nil

    static func queued(profileID: String, profileName: String, modelID: String, prompt: String) -> Self {
        let now = Date()
        return Self(
            id: UUID(), profileID: profileID, profileName: profileName,
            modelID: modelID, prompt: prompt, state: .queued,
            phase: "Queued", queuePosition: nil, sessionID: nil,
            latestOutput: "", pendingInteraction: nil, errorMessage: nil,
            createdAt: now, updatedAt: now,
            resourceClass: .resolve(modelID: modelID), budget: .standard,
            retryCount: 0, traceID: "trace_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            evidence: BotRunEvidence(
                phase: .route, confidence: .notRun,
                required: [.execution], observed: []),
            acceptanceCriteria: [])
    }
}

/// Durable, compatibility-safe storage for specialist runs. The legacy
/// Application Support directory remains authoritative across the Vamp Assistant
/// product rename so existing users never lose bot state.
actor BotRunStore {
    static let shared = BotRunStore()

    private let url: URL
    private let eventsURL: URL
    private let commandsURL: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = root ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("BeetCode", isDirectory: true)
        url = base.appendingPathComponent("bot-runs.json")
        eventsURL = base.appendingPathComponent("bot-run-events.json")
        commandsURL = base.appendingPathComponent("bot-run-commands.json")
    }

    func loadAll(recoverInterrupted: Bool = false) -> [BotRunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var records = try? decoder.decode([BotRunRecord].self, from: data) else { return [] }

        if recoverInterrupted {
            var changed = false
            for index in records.indices where !records[index].state.isTerminal {
                records[index].state = .recoverable
                records[index].phase = "Recoverable after restart"
                records[index].queuePosition = nil
                records[index].pendingInteraction = nil
                records[index].updatedAt = Date()
                changed = true
            }
            if changed { try? save(records) }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ records: [BotRunRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    func loadEvents(runID: UUID? = nil) -> [BotRunEvent] {
        let values: [BotRunEvent] = decodeFile(eventsURL) ?? []
        return values.filter { runID == nil || $0.runID == runID }
            .sorted { $0.sequence < $1.sequence }
    }

    @discardableResult
    func appendEvent(
        runID: UUID, kind: BotRunEvent.Kind, phase: String, detail: String? = nil
    ) throws -> BotRunEvent {
        var values: [BotRunEvent] = decodeFile(eventsURL) ?? []
        let sequence = (values.filter { $0.runID == runID }.map(\.sequence).max() ?? 0) + 1
        let event = BotRunEvent(
            id: UUID(), runID: runID, sequence: sequence, kind: kind,
            phase: phase, detail: detail, createdAt: Date())
        values.append(event)
        try encodeFile(values, to: eventsURL)
        return event
    }

    func loadCommands(runID: UUID? = nil) -> [BotRunCommandRecord] {
        let values: [BotRunCommandRecord] = decodeFile(commandsURL) ?? []
        return values.filter { runID == nil || $0.runID == runID }
            .sorted { $0.sequence < $1.sequence }
    }

    @discardableResult
    func enqueueCommand(
        runID: UUID, kind: BotRunCommandRecord.Kind, payload: String? = nil
    ) throws -> BotRunCommandRecord {
        var values: [BotRunCommandRecord] = decodeFile(commandsURL) ?? []
        let sequence = (values.filter { $0.runID == runID }.map(\.sequence).max() ?? 0) + 1
        let command = BotRunCommandRecord(
            id: UUID(), runID: runID, sequence: sequence, kind: kind,
            payload: payload, state: .pending, createdAt: Date(),
            deliveredAt: nil, acknowledgedAt: nil, result: nil)
        values.append(command)
        try encodeFile(values, to: commandsURL)
        return command
    }

    func acknowledgeCommand(_ id: UUID, accepted: Bool, result: String?) throws {
        var values: [BotRunCommandRecord] = decodeFile(commandsURL) ?? []
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].state = accepted ? .acknowledged : .rejected
        values[index].deliveredAt = values[index].deliveredAt ?? Date()
        values[index].acknowledgedAt = Date()
        values[index].result = result
        try encodeFile(values, to: commandsURL)
    }

    private func decodeFile<Value: Decodable>(_ file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    private func encodeFile<Value: Encodable>(_ value: Value, to file: URL) throws {
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
