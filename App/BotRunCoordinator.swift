import Combine
import Foundation

@MainActor
final class BotRunCoordinator: ObservableObject {
    struct StartError: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }
    typealias StartHandler = (BotRunRecord) async -> RemoteSessionStartOutcome
    typealias SteerHandler = (UUID, String) -> Bool
    typealias StopHandler = (UUID) -> Bool
    typealias ApprovalHandler = (UUID, Bool) -> Bool
    typealias AnswerHandler = (UUID, String) -> Bool

    @Published private(set) var runs: [BotRunRecord] = []
    @Published private(set) var eventsByRun: [UUID: [BotRunEvent]] = [:]

    var startHandler: StartHandler?
    var steerHandler: SteerHandler?
    var stopHandler: StopHandler?
    var approvalHandler: ApprovalHandler?
    var answerHandler: AnswerHandler?

    private let store: BotRunStore
    private var pendingIDs: [UUID] = []
    private var activeRunIDs: Set<UUID> = []
    private var activeLocalRunID: UUID?
    private var budgetTasks: [UUID: Task<Void, Never>] = [:]

    init(store: BotRunStore = .shared) {
        self.store = store
        Task { await restore() }
    }

    var activeRuns: [BotRunRecord] { runs.filter { !$0.state.isTerminal } }

    func run(for profileID: String) -> BotRunRecord? {
        runs.first { $0.profileID == profileID && !$0.state.isTerminal }
            ?? runs.first { $0.profileID == profileID }
    }

    func events(for runID: UUID) -> [BotRunEvent] {
        eventsByRun[runID] ?? []
    }

    @discardableResult
    func start(profileID: String, profileName: String, modelID: String, prompt: String) -> Result<UUID, StartError> {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return .failure(StartError(message: "Enter a task for this specialist.")) }
        guard !modelID.isEmpty else { return .failure(StartError(message: "Choose a model first.")) }
        guard !activeRuns.contains(where: { $0.profileID == profileID }) else {
            return .failure(StartError(message: "\(profileName) already has an active run."))
        }

        var record = BotRunRecord.queued(
            profileID: profileID, profileName: profileName,
            modelID: modelID, prompt: task)
        record.evidence = Self.evidenceContract(for: profileID)
        pendingIDs.append(record.id)
        record.queuePosition = pendingIDs.count
        runs.insert(record, at: 0)
        persist()
        recordEvent(runID: record.id, kind: .created, phase: record.phase, detail: task)
        recordEvent(runID: record.id, kind: .queued, phase: record.phase)
        drain()
        return .success(record.id)
    }

    @discardableResult
    func orchestrate(prompt: String, modelID: String) -> Result<UUID, StartError> {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return .failure(StartError(message: "Enter a workflow objective.")) }
        guard !modelID.isEmpty else { return .failure(StartError(message: "Choose a model first.")) }
        let plan = BotAdaptivePlanner.plan(prompt: task)
        let specialistIDs = Set(plan.nodes.map(\.specialistID))
        if let busy = activeRuns.first(where: { specialistIDs.contains($0.profileID) }) {
            return .failure(StartError(message: "\(busy.profileName) already has an active run."))
        }

        var idsByKey: [String: UUID] = [:]
        var created: [BotRunRecord] = []
        for node in plan.nodes {
            var record = BotRunRecord.queued(
                profileID: node.specialistID, profileName: node.specialistName,
                modelID: modelID, prompt: node.prompt)
            record.workflowID = plan.id
            record.evidence = BotRunEvidence(
                phase: node.phase, confidence: .notRun,
                required: node.requiredEvidence, observed: [])
            record.acceptanceCriteria = node.acceptanceCriteria.enumerated().map {
                BotAcceptanceCriterion(
                    id: "AC\($0.offset + 1)", summary: $0.element,
                    satisfied: false, evidenceReferences: [])
            }
            idsByKey[node.key] = record.id
            created.append(record)
        }
        for index in created.indices {
            let template = plan.nodes[index]
            created[index].dependencyRunIDs = template.dependencyKeys.compactMap { idsByKey[$0] }
            pendingIDs.append(created[index].id)
            runs.insert(created[index], at: 0)
            recordEvent(
                runID: created[index].id, kind: .created, phase: "Workflow planned",
                detail: "\(plan.rationale) · workflow \(plan.id.uuidString)")
        }
        refreshQueuePositions()
        persist()
        drain()
        return .success(plan.id)
    }

    func steer(runID: UUID, message: String) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let run = record(runID), !run.state.isTerminal,
              steerHandler != nil else { return false }
        update(runID) {
            $0.latestOutput = "Steering queued: \(text)"
            $0.updatedAt = Date()
        }
        Task {
            guard let command = try? await store.enqueueCommand(
                runID: runID, kind: .steer, payload: text) else { return }
            let accepted = await MainActor.run { steerHandler?(runID, text) == true }
            try? await store.acknowledgeCommand(
                command.id, accepted: accepted,
                result: accepted ? "Steering delivered." : "Runtime rejected steering.")
            recordEvent(
                runID: runID, kind: accepted ? .commandAccepted : .commandRejected,
                phase: record(runID)?.phase ?? run.phase, detail: "steer")
        }
        return true
    }

    func stop(runID: UUID) -> Bool {
        guard let run = record(runID), !run.state.isTerminal else { return false }
        pendingIDs.removeAll { $0 == runID }
        update(runID) { $0.phase = "Cancelling"; $0.updatedAt = Date() }
        Task {
            guard let command = try? await store.enqueueCommand(
                runID: runID, kind: .cancel) else { return }
            let accepted = await MainActor.run {
                activeRunIDs.contains(runID) ? (stopHandler?(runID) ?? false) : true
            }
            try? await store.acknowledgeCommand(
                command.id, accepted: accepted,
                result: accepted ? "Cancellation requested." : "Runtime rejected cancellation.")
            await MainActor.run {
                guard accepted else { return }
                update(runID) {
                    $0.state = .stopped
                    $0.phase = "Stopped"
                    $0.evidence?.confidence = .cancelled
                    $0.queuePosition = nil
                    $0.pendingInteraction = nil
                    $0.updatedAt = Date()
                }
                finishScheduling(runID)
            }
        }
        return true
    }

    func approve(runID: UUID, approved: Bool) -> Bool {
        guard let run = record(runID), run.state == .needsApproval,
              approvalHandler != nil else { return false }
        Task {
            let kind: BotRunCommandRecord.Kind = approved ? .approve : .decline
            guard let command = try? await store.enqueueCommand(runID: runID, kind: kind) else { return }
            let accepted = await MainActor.run { approvalHandler?(runID, approved) == true }
            try? await store.acknowledgeCommand(
                command.id, accepted: accepted,
                result: accepted ? "Approval response delivered." : "Approval response rejected.")
            recordEvent(
                runID: runID, kind: accepted ? .commandAccepted : .commandRejected,
                phase: record(runID)?.phase ?? run.phase, detail: kind.rawValue)
        }
        return true
    }

    func answer(runID: UUID, text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let run = record(runID), run.state == .needsInput,
              answerHandler != nil else { return false }
        Task {
            guard let command = try? await store.enqueueCommand(
                runID: runID, kind: .answer, payload: value) else { return }
            let accepted = await MainActor.run { answerHandler?(runID, value) == true }
            try? await store.acknowledgeCommand(
                command.id, accepted: accepted,
                result: accepted ? "Answer delivered." : "Answer rejected.")
            recordEvent(
                runID: runID, kind: accepted ? .commandAccepted : .commandRejected,
                phase: record(runID)?.phase ?? run.phase, detail: "answer")
        }
        return true
    }

    func resume(runID: UUID) -> Bool {
        guard let run = record(runID), run.state == .recoverable || run.state == .interrupted else {
            return false
        }
        update(runID) {
            $0.state = .queued
            $0.phase = "Queued for recovery"
            $0.evidence?.confidence = .notRun
            $0.errorMessage = nil
            $0.pendingInteraction = nil
            $0.sessionID = nil
            $0.updatedAt = Date()
        }
        pendingIDs.append(runID)
        recordEvent(runID: runID, kind: .recovered, phase: "Queued for recovery")
        refreshQueuePositions()
        drain()
        return true
    }

    func sync(sessionID: UUID?, phase: AgentPhase, finish: AgentFinish?, output: String) {
        guard let sessionID,
              let run = runs.first(where: { $0.sessionID == sessionID }) else { return }
        sync(runID: run.id, phase: phase, finish: finish, output: output)
    }

    func sync(runID: UUID, phase: AgentPhase, finish: AgentFinish?, output: String) {
        guard let run = record(runID) else { return }
        update(run.id) { record in
            record.phase = phase.rawValue.capitalized
            record.latestOutput = String(output.suffix(2_000))
            record.updatedAt = Date()
            if let finish {
                record.queuePosition = nil
                record.pendingInteraction = nil
                switch finish {
                case .completed:
                    record.state = .completed
                    record.evidence?.confidence = .reportedDone
                    let observedKind: BotEvidenceKind? = switch record.evidence?.phase {
                    case .research: .sources
                    case .navigation, .code: .execution
                    case .review: .review
                    case .test: .verification
                    case .route, .none: nil
                    }
                    if let observedKind,
                       record.evidence?.observed.contains(observedKind) == false {
                        record.evidence?.observed.append(observedKind)
                    }
                    let summary = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(8_000))
                    if !summary.isEmpty {
                        record.artifacts = (record.artifacts ?? []) + [BotRunArtifact(
                            id: UUID(), kind: .summary, title: "Final output",
                            value: summary, createdAt: Date())]
                    }
                case .cancelled, .declined:
                    record.state = .stopped
                    record.evidence?.confidence = .cancelled
                case .maxTurnsReached:
                    record.state = .failed
                    record.evidence?.confidence = .failed
                case .engineError(let message):
                    record.state = .failed
                    record.evidence?.confidence = .failed
                    record.errorMessage = message
                }
            } else {
                switch phase {
                case .awaitingApproval, .awaitingPlanApproval:
                    record.state = .needsApproval
                    record.evidence?.confidence = .blocked
                    record.pendingInteraction = "Approval required"
                case .awaitingQuestion:
                    record.state = .needsInput
                    record.evidence?.confidence = .blocked
                    record.pendingInteraction = "Answer required"
                default:
                    record.state = .running
                    record.evidence?.confidence = .running
                    record.pendingInteraction = nil
                }
            }
        }
        if finish != nil, activeRunIDs.contains(run.id) {
            let shouldRetry: Bool
            if case .engineError = finish,
               let current = record(run.id) {
                shouldRetry = (current.retryCount ?? 0) < (current.budget?.maximumRetries ?? 0)
            } else {
                shouldRetry = false
            }
            finishScheduling(run.id)
            if shouldRetry { scheduleRetry(runID: run.id) }
        }
    }

    private func restore() async {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let restored = await store.loadAll(recoverInterrupted: !isTestHost)
        let restoredEvents = await store.loadEvents()
        // Startup restoration is asynchronous. Preserve runs accepted while the
        // store was loading instead of replacing them with the older snapshot.
        let liveIDs = Set(runs.map(\.id))
        runs = (runs + restored.filter { !liveIDs.contains($0.id) })
            .sorted { $0.updatedAt > $1.updatedAt }
        let restoredByRun = Dictionary(grouping: restoredEvents, by: \.runID)
        for (runID, events) in restoredByRun {
            let liveEventIDs = Set((eventsByRun[runID] ?? []).map(\.id))
            eventsByRun[runID] = (eventsByRun[runID] ?? [])
                + events.filter { !liveEventIDs.contains($0.id) }
            eventsByRun[runID]?.sort { $0.sequence < $1.sequence }
        }
        persist()
    }

    /// Remote API and Codex specialists own independent runtimes and can run
    /// concurrently. Local models share one Metal generation gate and are
    /// admitted one at a time; their durable queue remains visible.
    private func drain() {
        guard let startHandler else { return }
        var dispatch: [UUID] = []
        for id in pendingIDs {
            guard var run = record(id) else { continue }
            let dependencies = (run.dependencyRunIDs ?? []).compactMap(record)
            if dependencies.contains(where: { $0.state.isTerminal && $0.state != .completed }) {
                update(id) {
                    $0.state = .failed
                    $0.phase = "Dependency failed"
                    $0.evidence?.confidence = .blocked
                    $0.errorMessage = "A required workflow step did not complete."
                    $0.queuePosition = nil
                    $0.updatedAt = Date()
                }
                continue
            }
            guard dependencies.allSatisfy({ $0.state == .completed }) else { continue }
            if !dependencies.isEmpty, run.dependencyContextAttached != true {
                let context = dependencies.map { dependency in
                    let output = dependency.artifacts?.last?.value ?? dependency.latestOutput
                    let evidence = dependency.evidence?.label ?? "Outcome · unclassified"
                    let criteria = (dependency.acceptanceCriteria ?? []).map {
                        "- [\($0.satisfied ? "x" : " ")] \($0.summary)"
                    }.joined(separator: "\n")
                    return "### \(dependency.profileName) handoff\nEvidence: \(evidence)\n"
                        + (criteria.isEmpty ? "" : "Criteria:\n\(criteria)\n")
                        + "Output:\n\(output)"
                }.joined(separator: "\n\n")
                update(id) {
                    $0.prompt += "\n\nCompleted dependency outputs:\n\(context)"
                    $0.dependencyContextAttached = true
                    $0.updatedAt = Date()
                }
                guard let refreshed = record(id) else { continue }
                run = refreshed
            }
            if run.modelID.hasPrefix("local|") {
                guard activeLocalRunID == nil,
                      !dispatch.contains(where: { record($0)?.modelID.hasPrefix("local|") == true })
                else { continue }
            }
            dispatch.append(id)
        }
        pendingIDs.removeAll { id in
            record(id)?.state.isTerminal == true
        }
        guard !dispatch.isEmpty else { refreshQueuePositions(); return }
        pendingIDs.removeAll { dispatch.contains($0) }
        for id in dispatch {
            guard let run = record(id) else { continue }
            activeRunIDs.insert(id)
            if run.modelID.hasPrefix("local|") { activeLocalRunID = id }
            update(id) {
                $0.state = .running
                $0.phase = "Starting"
                $0.evidence?.confidence = .running
                $0.queuePosition = nil
                $0.updatedAt = Date()
            }
            scheduleBudget(for: run)
            Task {
                let outcome = await startHandler(run)
                switch outcome {
                case .accepted(let sessionID):
                    update(id) {
                        $0.sessionID = sessionID
                        $0.state = .running
                        $0.phase = "Working"
                        $0.evidence?.confidence = .running
                        $0.updatedAt = Date()
                    }
                case .rejected(let message):
                    update(id) {
                        $0.state = .failed
                        $0.phase = "Failed"
                        $0.evidence?.confidence = .failed
                        $0.errorMessage = message
                        $0.updatedAt = Date()
                    }
                    activeRunIDs.remove(id)
                    if activeLocalRunID == id { activeLocalRunID = nil }
                    drain()
                }
            }
        }
        refreshQueuePositions()
    }

    private func record(_ id: UUID) -> BotRunRecord? { runs.first { $0.id == id } }

    private func update(_ id: UUID, mutation: (inout BotRunRecord) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        let previous = runs[index]
        mutation(&runs[index])
        if previous.phase != runs[index].phase || previous.state != runs[index].state {
            runs[index].checkpoint = BotRunCheckpoint(
                phase: runs[index].phase,
                latestOutput: String(runs[index].latestOutput.suffix(2_000)),
                sequence: (previous.checkpoint?.sequence ?? 0) + 1,
                createdAt: Date())
            let current = runs[index]
            recordEvent(
                runID: id, kind: eventKind(for: current), phase: current.phase,
                detail: current.pendingInteraction ?? current.errorMessage)
        }
        runs.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func eventKind(for run: BotRunRecord) -> BotRunEvent.Kind {
        switch run.state {
        case .queued: .queued
        case .running: run.phase == "Starting" ? .started : .phaseChanged
        case .needsApproval, .needsInput: .interactionRequested
        case .completed: .completed
        case .failed: .failed
        case .stopped: .cancelled
        case .interrupted: .interrupted
        case .recoverable: .recovered
        }
    }

    private func recordEvent(
        runID: UUID, kind: BotRunEvent.Kind, phase: String, detail: String? = nil
    ) {
        Task {
            guard let event = try? await store.appendEvent(
                runID: runID, kind: kind, phase: phase, detail: detail) else { return }
            await MainActor.run {
                var events = eventsByRun[runID] ?? []
                events.append(event)
                eventsByRun[runID] = events.sorted { $0.sequence < $1.sequence }
            }
        }
    }

    private func scheduleBudget(for run: BotRunRecord) {
        budgetTasks[run.id]?.cancel()
        let seconds = run.budget?.maximumDurationSeconds
            ?? BotRunBudget.standard.maximumDurationSeconds
        budgetTasks[run.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self?.stop(runID: run.id) }
        }
    }

    private func finishScheduling(_ runID: UUID) {
        budgetTasks[runID]?.cancel()
        budgetTasks[runID] = nil
        activeRunIDs.remove(runID)
        if activeLocalRunID == runID { activeLocalRunID = nil }
        refreshQueuePositions()
        drain()
    }

    private func scheduleRetry(runID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let current = self.record(runID), current.state == .failed else { return }
                self.update(runID) {
                    $0.retryCount = ($0.retryCount ?? 0) + 1
                    $0.state = .queued
                    $0.phase = "Retrying"
                    $0.errorMessage = nil
                    $0.sessionID = nil
                    $0.updatedAt = Date()
                }
                self.pendingIDs.append(runID)
                self.recordEvent(runID: runID, kind: .retrying, phase: "Retrying")
                self.refreshQueuePositions()
                self.drain()
            }
        }
    }

    private func refreshQueuePositions() {
        for index in runs.indices {
            runs[index].queuePosition = pendingIDs.firstIndex(of: runs[index].id).map { $0 + 1 }
        }
        persist()
    }

    private func persist() {
        let snapshot = runs
        Task { try? await store.save(snapshot) }
    }

    private static func evidenceContract(for profileID: String) -> BotRunEvidence {
        switch profileID {
        case "researcher":
            BotRunEvidence(phase: .research, confidence: .notRun, required: [.sources], observed: [])
        case "navigator":
            BotRunEvidence(phase: .navigation, confidence: .notRun, required: [.execution], observed: [])
        case "reviewer":
            BotRunEvidence(phase: .review, confidence: .notRun, required: [.review], observed: [])
        default:
            BotRunEvidence(
                phase: .code, confidence: .notRun,
                required: [.execution, .verification], observed: [])
        }
    }
}
