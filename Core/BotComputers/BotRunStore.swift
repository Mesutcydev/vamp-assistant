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

    /// Evidence a finished run demonstrated, derived from what its tools did rather than
    /// from what the model says it did.
    static func observed(from trace: [BotToolTrace], phase: BotEvidencePhase) -> [BotEvidenceKind] {
        let succeeded = trace.filter { !$0.failed }
        var kinds: [BotEvidenceKind] = []
        if succeeded.contains(where: { ["web_search", "web_fetch", "browser_navigate", "browser_read"].contains($0.name) }) {
            kinds.append(.sources)
        }
        if !succeeded.isEmpty { kinds.append(.execution) }
        // Verification: the last check after the last edit passed.
        var verified = false
        for call in trace {
            if ["apply_patch", "write_file", "move_file"].contains(call.name), !call.failed {
                verified = false
            } else if call.name == "run_command", let command = call.command, isCheck(command) {
                verified = !call.failed
            }
        }
        if verified { kinds.append(.verification) }
        if phase == .review, !succeeded.isEmpty { kinds.append(.review) }
        return kinds
    }

    /// Test/build/lint through a known runner. Deliberately narrow: counting `ls tests` as
    /// verification would be worse than missing an exotic runner.
    static func isCheck(_ command: String) -> Bool {
        command.range(
            of: #"\b(pytest|xcodebuild|tsc|jest|vitest)\b|\b(npm|pnpm|yarn|bun|swift|cargo|go|make|gradle|gradlew|mvn|deno)\b[^;&|]*\b(test|build|check|lint|vet|typecheck|clippy)\b"#,
            options: .regularExpression) != nil
    }

    /// A reviewer's closing `Verdict: pass`, as its orchestration contract asks for.
    static func reportsPass(_ answer: String) -> Bool {
        answer.range(of: #"\bverdict:\s*pass\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// One finished tool call from a run's transcript, reduced to what evidence needs.
struct BotToolTrace: Equatable, Sendable {
    var name: String
    var command: String?
    var failed: Bool
}

struct BotAcceptanceCriterion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var summary: String
    var satisfied: Bool
    var evidenceReferences: [String]

    /// Marks each criterion the final answer reports as `AC1: met`. Self-reported, so it only
    /// counts toward "verified" together with observed evidence.
    static func applyReport(_ answer: String, to criteria: [Self]) -> [Self] {
        criteria.map { criterion in
            var copy = criterion
            copy.satisfied = answer.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: criterion.id)):\\s*met\\b",
                options: [.regularExpression, .caseInsensitive]) != nil
            copy.evidenceReferences = copy.satisfied ? ["final report"] : []
            return copy
        }
    }
}

struct BotRunBudget: Codable, Equatable, Sendable {
    var maximumTurns: Int
    var maximumDurationSeconds: TimeInterval
    var maximumRetries: Int

    static let standard = Self(
        maximumTurns: 30,
        maximumDurationSeconds: 30 * 60,
        maximumRetries: 1)
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
    var workflowID: UUID? = nil
    /// The user's project this run works on. Never edited in place: the run gets a private
    /// copy at `workPath`, and its changes are applied only on request.
    var projectPath: String? = nil
    var workPath: String? = nil
    /// Git tree `workPath` was seeded with; the run's changes are the diff against it.
    var baseTree: String? = nil
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

    /// Verified only when every required kind was observed and every criterion reported met.
    mutating func settleEvidence() {
        guard state == .completed, var evidence else { return }
        evidence.confidence = evidence.missing.isEmpty
            && (acceptanceCriteria ?? []).allSatisfy(\.satisfied) ? .verified : .reportedDone
        self.evidence = evidence
    }
}

/// Durable, compatibility-safe storage for specialist runs. The legacy
/// Application Support directory remains authoritative across the Vamp Assistant
/// product rename so existing users never lose bot state.
actor BotRunStore {
    static let shared = BotRunStore()

    private let url: URL
    /// Append-only, one event per line: adding an event no longer re-reads and rewrites the
    /// whole history, and one damaged line costs that line rather than the file.
    private let eventsURL: URL
    private let legacyEventsURL: URL
    private let commandsURL: URL
    private let fileManager: FileManager
    private var eventsCache: [BotRunEvent]?

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = root ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("BeetCode", isDirectory: true)
        url = base.appendingPathComponent("bot-runs.json")
        eventsURL = base.appendingPathComponent("bot-run-events.jsonl")
        legacyEventsURL = base.appendingPathComponent("bot-run-events.json")
        commandsURL = base.appendingPathComponent("bot-run-commands.json")
    }

    func loadAll(recoverInterrupted: Bool = false) -> [BotRunRecord] {
        guard var records: [BotRunRecord] = decodeFile(url) else {
            // A missing file legitimately means “no runs yet”. A file that
            // exists but cannot decode has already been quarantined by
            // decodeFile, so the next persist cannot silently replace it with
            // an empty array.
            return []
        }

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
        Self.harden(url, fileManager: fileManager)
    }

    func loadEvents(runID: UUID? = nil) -> [BotRunEvent] {
        allEvents().filter { runID == nil || $0.runID == runID }
            .sorted { $0.sequence < $1.sequence }
    }

    @discardableResult
    func appendEvent(
        runID: UUID, kind: BotRunEvent.Kind, phase: String, detail: String? = nil
    ) throws -> BotRunEvent {
        let values = allEvents()
        let sequence = (values.filter { $0.runID == runID }.map(\.sequence).max() ?? 0) + 1
        let event = BotRunEvent(
            id: UUID(), runID: runID, sequence: sequence, kind: kind,
            phase: phase, detail: detail, createdAt: Date())
        try fileManager.createDirectory(
            at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: eventsURL.path) {
            fileManager.createFile(atPath: eventsURL.path, contents: nil)
            Self.harden(eventsURL, fileManager: fileManager)
        }
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.line(event))
        eventsCache = values + [event]
        return event
    }

    /// Drops history for runs no longer kept, so the files stay bounded by retention.
    func prune(keeping runIDs: Set<UUID>) throws {
        let events = allEvents().filter { runIDs.contains($0.runID) }
        try writeEvents(events)
        let commands: [BotRunCommandRecord] = decodeFile(commandsURL) ?? []
        try encodeFile(commands.filter { runIDs.contains($0.runID) }, to: commandsURL)
    }

    private func allEvents() -> [BotRunEvent] {
        if let eventsCache { return eventsCache }
        var values: [BotRunEvent] = []
        if let text = try? String(contentsOf: eventsURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            values = text.split(separator: "\n").compactMap {
                try? decoder.decode(BotRunEvent.self, from: Data($0.utf8))
            }
        } else if let legacy: [BotRunEvent] = decodeFile(legacyEventsURL) {
            // One-time move from the old whole-file array.
            values = legacy
            if (try? writeEvents(legacy)) != nil { try? fileManager.removeItem(at: legacyEventsURL) }
        }
        eventsCache = values
        return values
    }

    private func writeEvents(_ events: [BotRunEvent]) throws {
        try fileManager.createDirectory(
            at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try events.map(Self.line).reduce(Data(), +).write(to: eventsURL, options: .atomic)
        Self.harden(eventsURL, fileManager: fileManager)
        eventsCache = events
    }

    private static func line(_ event: BotRunEvent) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return ((try? encoder.encode(event)) ?? Data()) + Data("\n".utf8)
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
        if let value = try? decoder.decode(Value.self, from: data) {
            return value
        }
        quarantine(file)
        return nil
    }

    /// Preserves an unreadable state file instead of letting a later persist
    /// overwrite it with an empty snapshot. The backup keeps the raw bytes for
    /// manual recovery.
    private func quarantine(_ file: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = file.appendingPathExtension("corrupt-\(stamp)")
        try? fileManager.moveItem(at: file, to: backup)
    }

    private func encodeFile<Value: Encodable>(_ value: Value, to file: URL) throws {
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: file, options: .atomic)
        Self.harden(file, fileManager: fileManager)
    }

    /// Bot prompts and model output are as sensitive as chat content; the
    /// other stores already restrict access to the owning user. Match that
    /// hardening (0600 files / 0700 directory) for the bot run state.
    private static func harden(_ file: URL, fileManager: FileManager) {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: file.deletingLastPathComponent().path)
    }
}
