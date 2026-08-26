import SwiftUI

private struct BotSpecialist: Identifiable {
    let id: String
    let name: String
    let detail: String
    let image: String
    let starter: String

    static let all = [
        Self(id: "builder", name: "Builder", detail: "Build, repair, and verify software", image: "BotBuilder",
             starter: "Build and verify the requested change."),
        Self(id: "reviewer", name: "Reviewer", detail: "Inspect diffs, risks, and regressions", image: "BotReviewer",
             starter: "Review the current changes for bugs and regressions."),
        Self(id: "navigator", name: "Navigator", detail: "Operate browser and Mac workflows", image: "BotNavigator",
             starter: "Open and test the requested browser workflow."),
        Self(id: "researcher", name: "Researcher", detail: "Collect sources and synthesize evidence", image: "BotResearcher",
             starter: "Research the request and return evidence-backed findings."),
    ]
}

struct BotDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @State private var workflowPrompt = ""
    @State private var workflowModelID = ""
    @State private var workflowMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                workflowComposer
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(BotSpecialist.all) { specialist in
                        BotSpecialistCard(
                            specialist: specialist,
                            computer: appState.botComputers.computers.first { $0.profileID == specialist.id },
                            run: appState.botRuns.run(for: specialist.id),
                            events: appState.botRuns.run(for: specialist.id)
                                .map { appState.botRuns.events(for: $0.id) } ?? [],
                            models: appState.botModelOptions,
                            onOpenModels: {
                                NotificationCenter.default.post(name: .openModelManager, object: nil)
                            },
                            onStart: { model, prompt in
                                appState.botRuns.start(
                                    profileID: specialist.id,
                                    profileName: specialist.name,
                                    modelID: model,
                                    prompt: prompt)
                            },
                            onOpen: open,
                            onSteer: { appState.botRuns.steer(runID: $0, message: $1) },
                            onApprove: { appState.botRuns.approve(runID: $0, approved: $1) },
                            onAnswer: { appState.botRuns.answer(runID: $0, text: $1) },
                            onResume: { appState.botRuns.resume(runID: $0) },
                            onStop: { appState.botRuns.stop(runID: $0) })
                    }
                }
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background { AtmosphereBackground(intensity: .conversation) }
        .task { appState.botComputers.reload() }
        .onAppear { selectWorkflowModel() }
        .onChange(of: appState.botModelOptions.map(\.id)) { _, _ in selectWorkflowModel() }
    }

    private var workflowComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Adaptive workflow", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Vamp Assistant selects specialists, runs independent steps concurrently, passes durable outputs to dependent steps, and finishes with verification.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .top, spacing: 10) {
                Picker("Workflow model", selection: $workflowModelID) {
                    ForEach(appState.botModelOptions, id: \.id) {
                        Text("\($0.name) · \($0.source)").tag($0.id)
                    }
                }
                .labelsHidden().frame(maxWidth: 280)
                TextField("Describe the complete outcome…", text: $workflowPrompt, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                Button("Orchestrate", action: orchestrate)
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .disabled(workflowModelID.isEmpty)
                .help(workflowModelID.isEmpty ? "Set up a model first" : "Start an adaptive multi-bot workflow")
            }
            if let workflowMessage {
                Text(workflowMessage).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .lfGlass(radius: 18, contentLegibility: true)
    }

    private func selectWorkflowModel() {
        if !appState.botModelOptions.contains(where: { $0.id == workflowModelID }) {
            workflowModelID = appState.botModelOptions.first?.id ?? ""
        }
    }

    private func orchestrate() {
        switch appState.botRuns.orchestrate(prompt: workflowPrompt, modelID: workflowModelID) {
        case .success(let id):
            workflowMessage = "Workflow \(id.uuidString.prefix(8)) started."
            workflowPrompt = ""
        case .failure(let error):
            workflowMessage = error.localizedDescription
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Specialist bots")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Focused work in four private Linux workspaces and browser profiles. Vamp Assistant asks before delegating.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Label("\(appState.botRuns.activeRuns.count) active",
                  systemImage: appState.botRuns.activeRuns.isEmpty ? "moon.zzz" : "bolt.horizontal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appState.botRuns.activeRuns.isEmpty ? Theme.textTertiary : Theme.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func open(_ run: BotRunRecord) {
        guard let sessionID = run.sessionID,
              let record = SessionStore.shared.load(id: sessionID),
              sessions.restore(record) else { return }
        NotificationCenter.default.post(name: .openAssistantHome, object: nil)
    }
}

private struct BotSpecialistCard: View {
    let specialist: BotSpecialist
    let computer: BotComputerRecord?
    let run: BotRunRecord?
    let events: [BotRunEvent]
    let models: [RemoteStartModel]
    let onOpenModels: () -> Void
    let onStart: (String, String) -> Result<UUID, BotRunCoordinator.StartError>
    let onOpen: (BotRunRecord) -> Void
    let onSteer: (UUID, String) -> Bool
    let onApprove: (UUID, Bool) -> Bool
    let onAnswer: (UUID, String) -> Bool
    let onResume: (UUID) -> Bool
    let onStop: (UUID) -> Bool

    @State private var prompt = ""
    @State private var steerText = ""
    @State private var answerText = ""
    @State private var selectedModelID = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let run {
                runStatus(run)
                if run.state.isTerminal {
                    Divider()
                    composer
                } else if run.state == .recoverable {
                    Button("Resume from checkpoint") { _ = onResume(run.id) }
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                } else if run.state == .needsApproval {
                    HStack {
                        Button("Approve") { _ = onApprove(run.id, true) }
                            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                        Button("Decline", role: .destructive) { _ = onApprove(run.id, false) }
                            .buttonStyle(LFCapsuleButtonStyle())
                    }
                } else if run.state == .needsInput {
                    HStack {
                        TextField("Answer the specialist…", text: $answerText)
                            .textFieldStyle(.roundedBorder)
                        Button("Answer") {
                            if onAnswer(run.id, answerText) { answerText = "" }
                        }
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                        .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    steering(run)
                }
                HStack {
                    if run.sessionID != nil {
                        Button("Open conversation") { onOpen(run) }
                            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    }
                    Spacer()
                    if !run.state.isTerminal {
                        Button("Stop", role: .destructive) { _ = onStop(run.id) }
                            .buttonStyle(LFCapsuleButtonStyle())
                    }
                }
            } else {
                composer
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(16)
        .lfGlass(radius: 18, contentLegibility: true)
        .onAppear { selectAvailableModel() }
        .onChange(of: models.map(\.id)) { _, _ in selectAvailableModel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(specialist.image)
                .resizable().scaledToFit()
                .saturation(0)
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(specialist.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(specialist.detail).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Circle()
                .fill(run.map { $0.state.isTerminal ? Theme.textTertiary : Theme.success }
                    ?? (computer?.state == .running ? Theme.success : Theme.textTertiary))
                .frame(width: 8, height: 8)
                .accessibilityLabel(run?.phase ?? computer?.state.rawValue ?? "Ready on first run")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if models.isEmpty {
                HStack(spacing: 8) {
                    Label("No model is ready", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Set up model", action: onOpenModels)
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                }
            } else {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(models, id: \.id) { Text("\($0.name) · \($0.source)").tag($0.id) }
                }
                .labelsHidden()
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should \(specialist.name) do?")
                        .font(.callout)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .frame(minHeight: 76, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
                    .accessibilityLabel("Task for \(specialist.name)")
            }
            HStack(spacing: 8) {
                Button("Suggested task") {
                    prompt = specialist.starter
                    errorMessage = nil
                }
                .buttonStyle(LFCapsuleButtonStyle())
                Button("Start \(specialist.name)", action: start)
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .disabled(selectedModelID.isEmpty)
                    .help(selectedModelID.isEmpty ? "Set up a model first" : "Start this specialist in its private workspace")
            }
            Text(computer == nil
                 ? "The private workspace and browser are prepared automatically on first run."
                 : "Computer: \(computer?.state.rawValue ?? "ready")")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func steering(_ run: BotRunRecord) -> some View {
        HStack(spacing: 8) {
            TextField("Redirect this run…", text: $steerText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { steer(run) }
            Button("Steer") { steer(run) }
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func runStatus(_ run: BotRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(run.phase, systemImage: phaseIcon(run.state))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(run.queuePosition.map { "Queue #\($0)" }
                    ?? run.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Text(run.prompt).font(.callout.weight(.medium)).lineLimit(3)
            HStack(spacing: 10) {
                if let evidence = run.evidence {
                    Label(evidence.label, systemImage: evidenceIcon(evidence.confidence))
                        .foregroundStyle(evidenceColor(evidence.confidence))
                }
                Label(resourceLabel(run), systemImage: "cpu")
                if let retry = run.retryCount, retry > 0 {
                    Label("Retry \(retry)", systemImage: "arrow.clockwise")
                }
                if run.workflowID != nil {
                    Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted")
                }
                if !(run.dependencyRunIDs ?? []).isEmpty {
                    Label("\(run.dependencyRunIDs?.count ?? 0) dependencies", systemImage: "arrow.triangle.branch")
                }
            }
            .font(.caption2).foregroundStyle(Theme.textTertiary)
            if let evidence = run.evidence, !evidence.missing.isEmpty {
                Text("Still needs evidence: \(evidence.missing.map(\.rawValue).joined(separator: ", "))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.warning)
            }
            if let criteria = run.acceptanceCriteria, !criteria.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(criteria) { criterion in
                        Label(
                            criterion.summary,
                            systemImage: criterion.satisfied ? "checkmark.circle.fill" : "circle")
                            .lineLimit(2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }
            if !run.latestOutput.isEmpty {
                Text(run.latestOutput).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(4)
            }
            if let message = run.pendingInteraction ?? run.errorMessage {
                Text(message).font(.caption).foregroundStyle(run.errorMessage == nil ? Theme.warning : Theme.danger)
            }
            if let trace = run.traceID {
                Text("Trace \(trace.suffix(10)) · checkpoint \(run.checkpoint?.sequence ?? 0) · \(run.artifacts?.count ?? 0) artifacts")
                    .font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary)
            }
            if !events.isEmpty {
                Divider()
                ForEach(events.suffix(3)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("#\(event.sequence)").font(.caption2.monospaced())
                        Text(event.kind.rawValue).font(.caption2.weight(.semibold))
                        Text(event.phase).font(.caption2).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.createdAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(Theme.surfaceInset.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func resourceLabel(_ run: BotRunRecord) -> String {
        switch run.resourceClass ?? .resolve(modelID: run.modelID) {
        case .remoteAPI: "Remote API"
        case .codex: "Codex"
        case .localInference: "Local queue"
        }
    }

    private func phaseIcon(_ state: BotRunState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "bolt.fill"
        case .needsApproval, .needsInput: "exclamationmark.bubble.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped, .interrupted: "stop.circle.fill"
        case .recoverable: "arrow.clockwise.circle.fill"
        }
    }

    private func evidenceIcon(_ confidence: BotEvidenceConfidence) -> String {
        switch confidence {
        case .notRun: "circle.dotted"
        case .running: "bolt.fill"
        case .reportedDone: "checkmark.bubble"
        case .verified: "checkmark.seal.fill"
        case .blocked: "pause.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private func evidenceColor(_ confidence: BotEvidenceConfidence) -> Color {
        switch confidence {
        case .verified: Theme.success
        case .running: Theme.info
        case .blocked: Theme.warning
        case .failed, .cancelled: Theme.danger
        case .notRun, .reportedDone: Theme.textSecondary
        }
    }

    private func start() {
        switch onStart(selectedModelID, prompt) {
        case .success: prompt = ""; errorMessage = nil
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    private func steer(_ run: BotRunRecord) {
        if onSteer(run.id, steerText) { steerText = ""; errorMessage = nil }
        else { errorMessage = "This run cannot be steered right now." }
    }

    private func selectAvailableModel() {
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id ?? ""
        }
    }
}
