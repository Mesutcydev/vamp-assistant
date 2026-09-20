import SwiftUI

private struct BotSpecialist: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let starter: String

    static let all = [
        Self(id: "builder", name: "Builder", detail: "Build, repair, and verify software", symbol: "hammer",
             starter: "Build and verify the requested change."),
        Self(id: "reviewer", name: "Reviewer", detail: "Inspect diffs, risks, and regressions", symbol: "checkmark.shield",
             starter: "Review the current changes for bugs and regressions."),
        Self(id: "navigator", name: "Navigator", detail: "Operate browser and Mac workflows", symbol: "cursorarrow",
             starter: "Open and test the requested browser workflow."),
        Self(id: "researcher", name: "Researcher", detail: "Collect sources and synthesize evidence", symbol: "sparkle.magnifyingglass",
             starter: "Research the request and return evidence-backed findings."),
    ]
}

private struct BotModelSelections {
    private var values: [String: String] = [:]

    subscript(modelFor specialistID: String) -> String {
        get { values[specialistID] ?? "" }
        set { values[specialistID] = newValue }
    }
}

struct BotDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @ObservedObject private var drafts = BotDraftStore.shared
    @State private var workflowPrompt = ""
    @State private var workflowModelID = ""
    @State private var workflowMessage: String?
    @State private var selectedSpecialistID = BotSpecialist.all[0].id
    @State private var specialistModels = BotModelSelections()

    @State private var showsTeamTask = false
    @State private var showsConsole = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back to chat", systemImage: "arrow.left") {
                    NotificationCenter.default.post(name: .openAssistantHome, object: nil)
                }
                .buttonStyle(LFCapsuleButtonStyle())
                Text("bots").font(.appMono(size: 23, weight: .regular))
                BotHeaderModelPicker(
                    models: appState.botModelOptions,
                    selection: $specialistModels[modelFor: selectedSpecialistID],
                    onOpenModels: {
                        NotificationCenter.default.post(name: .openProviderSettings, object: nil)
                    })
                Spacer()
                Text("\(appState.botRuns.activeRuns.count) running")
                    .font(.appMono(size: 11)).foregroundStyle(Theme.textSecondary)
                Button("Team task") { showsTeamTask = true }
                    .buttonStyle(LFCapsuleButtonStyle())
                Toggle("Console", isOn: $showsConsole).toggleStyle(.button)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Instrument.silverMid)
            ScrollView(.horizontal) {
                HStack(spacing: 1) {
                    ForEach(BotSpecialist.all) { specialist in
                        BotSelectorKey(specialist: specialist,
                                       isSelected: specialist.id == selectedSpecialistID,
                                       run: appState.botRuns.run(for: specialist.id)) {
                            selectedSpecialistID = specialist.id
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .background(Instrument.silverLow)
            Rectangle().fill(Instrument.silverEdgeDark).frame(height: 1)
            GeometryReader { geometry in
                ZStack {
                    // Stable identities preserve separate drafts when switching specialists.
                    ForEach(BotSpecialist.all) { specialist in
                        ScrollView {
                            VStack(spacing: 20) {
                                detailCard(for: specialist)
                                if showsConsole && specialist.id == selectedSpecialistID {
                                    BotConsolePanel(
                                        computer: appState.botComputers.computers.first { $0.profileID == specialist.id },
                                        run: appState.botRuns.run(for: specialist.id),
                                        events: appState.botRuns.run(for: specialist.id)
                                            .map { appState.botRuns.events(for: $0.id) } ?? [])
                                        .id(specialist.id)
                                }
                            }
                            .frame(maxWidth: .infinity,
                                   minHeight: geometry.size.height,
                                   alignment: .top)
                        }
                        .opacity(specialist.id == selectedSpecialistID ? 1 : 0)
                        .allowsHitTesting(specialist.id == selectedSpecialistID)
                        .disabled(specialist.id != selectedSpecialistID)
                        .accessibilityHidden(specialist.id != selectedSpecialistID)
                    }
                }
            }
        }
        .background(Theme.workspaceCanvas)
        .overlay(alignment: .bottom) {
            if let message = appState.botRuns.persistenceError ?? drafts.errorMessage {
                HStack {
                    Text(message).font(.appUI(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button("Retry saving") {
                        BotDraftStore.shared.retry()
                        Task { await appState.botRuns.retryPersistence() }
                    }
                }
                .padding(12).background(Theme.surface).foregroundStyle(Theme.warning)
            }
        }
        .sheet(isPresented: $showsTeamTask) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Team task").font(.appMono(size: 22))
                    Spacer()
                    Button("Done") { showsTeamTask = false }
                        .keyboardShortcut(.cancelAction)
                }
                workflowComposer
            }
            .padding(24).frame(width: 520)
            .background(Theme.workspaceCanvas)
        }
        .task { appState.botComputers.reload() }
        .onAppear {
            selectWorkflowModel()
            workflowPrompt = BotDraftStore.shared.value(for: "workflow")
        }
        .onChange(of: workflowPrompt) { _, value in BotDraftStore.shared.set(value, for: "workflow") }
        .onChange(of: appState.botModelOptions.map(\.id)) { _, _ in selectWorkflowModel() }
    }

    private func detailCard(for specialist: BotSpecialist) -> some View {
        BotSpecialistCard(
                specialist: specialist,
                computer: appState.botComputers.computers.first { $0.profileID == specialist.id },
                run: appState.botRuns.run(for: specialist.id),
                events: appState.botRuns.run(for: specialist.id)
                    .map { appState.botRuns.events(for: $0.id) } ?? [],
                models: appState.botModelOptions,
                selectedModelID: $specialistModels[modelFor: specialist.id],
                onOpenModels: {
                    NotificationCenter.default.post(name: .openProviderSettings, object: nil)
                },
                onStart: { model, prompt in
                    appState.botRuns.start(
                        profileID: specialist.id,
                        profileName: specialist.name,
                        modelID: model,
                        prompt: prompt)
                },
                onOpen: open,
                onSteer: { await appState.botRuns.deliverCommand(runID: $0, kind: .steer, payload: $1) },
                onApprove: { await appState.botRuns.deliverCommand(runID: $0, kind: $1 ? .approve : .decline) },
                onAnswer: { await appState.botRuns.deliverCommand(runID: $0, kind: .answer, payload: $1) },
            onResume: { appState.botRuns.resume(runID: $0) },
            onStop: { appState.botRuns.stop(runID: $0) })
    }

    /// Deliberate vertical arrangement: title + short description, then a
    /// full-width model picker, a full-width multiline task editor, and a
    /// separate action row whose primary label never wraps.
    private var workflowComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delegate an outcome")
                .vampSectionLabel()
            Text("Vamp Assistant selects specialists, runs independent steps concurrently, passes durable outputs to dependent steps, and finishes with verification.")
                .font(.app(size: 12 )).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Workflow model", selection: $workflowModelID) {
                ForEach(appState.botModelOptions, id: \.id) {
                    Text("\($0.name) · \($0.source)").tag($0.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            TextField("Describe the complete outcome…", text: $workflowPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.app(size: 13 ))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3...6)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: Chrome.buttonRadius,
                                                 style: .continuous))
                .accessibilityLabel("Workflow task")

            HStack(spacing: 8) {
                Button("Orchestrate", action: orchestrate)
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(workflowModelID.isEmpty || workflowPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(workflowModelID.isEmpty ? "Set up a model first" : "Start an adaptive multi-bot workflow")
                Spacer(minLength: 0)
            }
            if let workflowMessage {
                Text(workflowMessage)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Instrument.silverMid, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Instrument.silverEdgeDark, lineWidth: 0.75))
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


    private func open(_ run: BotRunRecord) {
        guard let sessionID = run.sessionID,
              let record = SessionStore.shared.load(id: sessionID),
              sessions.restore(record) else { return }
        NotificationCenter.default.post(name: .openAssistantHome, object: nil)
    }
}

/// The header and selected specialist share the same model binding.
/// Keeping selections keyed by specialist preserves them across tab switches.
private struct BotHeaderModelPicker: View {
    let models: [RemoteStartModel]
    @Binding var selection: String
    let onOpenModels: () -> Void

    var body: some View {
        Menu {
            Picker("Model for next bot task", selection: $selection) {
                ForEach(models, id: \.id) { model in
                    Text("\(model.name) · \(model.source)").tag(model.id)
                }
            }
            Divider()
            Button("Set up model", action: onOpenModels)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Instrument.inkSecondary)
                if let model = models.first(where: { $0.id == selection }) {
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Choose model")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Instrument.inkSecondary)
            }
            .font(.appUI(size: 12, weight: .medium))
            .foregroundStyle(Instrument.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Instrument.silverLow, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Instrument.silverEdgeDark.opacity(0.45), lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityLabel("Model for next bot task")
        .accessibilityValue(models.first(where: { $0.id == selection })?.name ?? "Choose model")
        .help(models.first(where: { $0.id == selection })
            .map { "\($0.name) · \($0.source) — used for the next task" }
            ?? "Choose or set up a model for this specialist")
    }
}

private struct BotSpecialistCard: View {
    let specialist: BotSpecialist
    let computer: BotComputerRecord?
    let run: BotRunRecord?
    let events: [BotRunEvent]
    let models: [RemoteStartModel]
    @Binding var selectedModelID: String
    let onOpenModels: () -> Void
    let onStart: (String, String) -> Result<UUID, BotRunCoordinator.StartError>
    let onOpen: (BotRunRecord) -> Void
    let onSteer: (UUID, String) async -> Bool
    let onApprove: (UUID, Bool) async -> Bool
    let onAnswer: (UUID, String) async -> Bool
    let onResume: (UUID) -> Bool
    let onStop: (UUID) -> Bool

    @State private var prompt = ""
    @State private var steerText = ""
    @State private var answerText = ""
    @State private var errorMessage: String?
    @State private var isDelivering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if let run {
                runStatus(run)
                if run.state == .recoverable || run.state == .interrupted {
                    Button("Resume from checkpoint") { _ = onResume(run.id) }
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                } else if run.state.isTerminal {
                    Divider()
                    composer
                } else if run.state == .needsApproval {
                    HStack {
                        Button("Approve") { respondToApproval(run, approved: true) }
                            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                        Button("Decline", role: .destructive) { respondToApproval(run, approved: false) }
                            .buttonStyle(LFCapsuleButtonStyle())
                    }
                    .disabled(isDelivering)
                } else if run.state == .needsInput {
                    HStack {
                        TextField("Answer the specialist…", text: $answerText)
                            .vampField()
                        Button("Answer") {
                            let submitted = answerText
                            isDelivering = true
                            Task {
                                let accepted = await onAnswer(run.id, submitted)
                                if accepted && answerText == submitted { answerText = "" }
                                errorMessage = accepted ? nil : "Answer was not delivered. Your text is retained."
                                isDelivering = false
                            }
                        }
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                        .disabled(isDelivering || answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text(errorMessage).font(.app(size: 11.5 )).foregroundStyle(Theme.negative)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectAvailableModel()
            prompt = BotDraftStore.shared.value(for: specialist.id + ":task")
            steerText = BotDraftStore.shared.value(for: specialist.id + ":steer")
            answerText = BotDraftStore.shared.value(for: specialist.id + ":answer")
        }
        .onChange(of: prompt) { _, value in BotDraftStore.shared.set(value, for: specialist.id + ":task") }
        .onChange(of: steerText) { _, value in BotDraftStore.shared.set(value, for: specialist.id + ":steer") }
        .onChange(of: answerText) { _, value in BotDraftStore.shared.set(value, for: specialist.id + ":answer") }
        .onChange(of: models.map(\.id)) { _, _ in selectAvailableModel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: specialist.symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Instrument.ink)
                .frame(width: 52, height: 52)
                .background(Instrument.silverMid, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Instrument.silverEdgeDark, lineWidth: 0.75))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(specialist.name)
                    .font(.appMono(size: 28, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                Text(specialist.detail)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Circle()
                .fill(run.map { $0.state.isTerminal ? Theme.statusNeutral : Theme.positive }
                    ?? (computer?.state == .running ? Theme.positive : Theme.statusNeutral))
                .frame(width: 8, height: 8)
                .accessibilityLabel(run?.phase ?? computer?.state.rawValue ?? "Ready on first run")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if models.isEmpty {
                HStack(spacing: 8) {
                    Label("No model is ready", systemImage: "exclamationmark.circle")
                        .font(.app(size: 12, weight: .medium ))
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Set up model", action: onOpenModels)
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.app(size: 13 ))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surfaceInset.opacity(0.7),
                                in: RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.75))
                    .accessibilityLabel("Task for \(specialist.name)")
                // Draw above the editor's cavity, not underneath its fill.
                if prompt.isEmpty {
                    Text("What should \(specialist.name) do?")
                        .font(.appUI(size: 13))
                        .foregroundStyle(Theme.placeholderOnSilver)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 8) {
                Button("Suggested task") {
                    prompt = specialist.starter
                    errorMessage = nil
                }
                .buttonStyle(LFCapsuleButtonStyle())
                Button("Start \(specialist.name)", action: start)
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(selectedModelID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(selectedModelID.isEmpty ? "Set up a model first" : "Start this specialist in its private workspace")
            }
            Text(computer == nil
                 ? "The private workspace and browser are prepared automatically on first run."
                 : "Computer: \(computer?.state.rawValue ?? "ready")")
                .font(.app(size: 11 ))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .background(LinearGradient(colors: [Instrument.silverTop, Instrument.silverLow],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle()
            .strokeBorder(Instrument.silverEdgeDark, lineWidth: 0.75))
    }

    private func steering(_ run: BotRunRecord) -> some View {
        HStack(spacing: 8) {
            TextField("Redirect this run…", text: $steerText)
                .textFieldStyle(.plain)
                .font(.app(size: 12.5 ))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: Chrome.buttonHeight)
                .background(Theme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: Chrome.buttonRadius,
                                                 style: .continuous))
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
                    .font(.app(size: 11.5, weight: .semibold ))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(run.queuePosition.map { "Queue #\($0)" }
                    ?? run.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.app(size: 11 )).foregroundStyle(Theme.textTertiary)
            }
            Text(run.prompt)
                .font(.app(size: 13, weight: .medium ))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
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
            .font(.app(size: 11 )).foregroundStyle(Theme.textTertiary)
            if let evidence = run.evidence, !evidence.missing.isEmpty {
                Text("Still needs evidence: \(evidence.missing.map(\.rawValue).joined(separator: ", "))")
                    .font(.app(size: 11, weight: .medium ))
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
                .font(.app(size: 11 ))
                .foregroundStyle(Theme.textSecondary)
            }
            if !run.latestOutput.isEmpty {
                Text(run.latestOutput)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            if let message = run.pendingInteraction ?? run.errorMessage {
                Text(message)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(run.errorMessage == nil ? Theme.warning : Theme.negative)
            }
            if let trace = run.traceID {
                Text("Trace \(trace.suffix(10)) · checkpoint \(run.checkpoint?.sequence ?? 0) · \(run.artifacts?.count ?? 0) artifacts")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            if !events.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 0.75)
                ForEach(events.suffix(3)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("#\(event.sequence)").font(.system(size: 10.5, design: .monospaced))
                        Text(event.kind.rawValue).font(.app(size: 10.5, weight: .semibold ))
                        Text(event.phase).font(.app(size: 10.5 )).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.createdAt.formatted(date: .omitted, time: .standard))
                            .font(.app(size: 10.5 )).foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceInset.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous))
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
        case .verified: Theme.positive
        case .running: Theme.info
        case .blocked: Theme.warning
        case .failed, .cancelled: Theme.negative
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
        guard !isDelivering else { return }
        let submitted = steerText
        isDelivering = true
        Task {
            let accepted = await onSteer(run.id, submitted)
            if accepted && steerText == submitted { steerText = "" }
            errorMessage = accepted ? nil : "Steering was not delivered. Your text is retained."
            isDelivering = false
        }
    }

    private func respondToApproval(_ run: BotRunRecord, approved: Bool) {
        guard !isDelivering else { return }
        isDelivering = true
        Task {
            let accepted = await onApprove(run.id, approved)
            errorMessage = accepted ? nil : "The approval response was not delivered. Please retry."
            isDelivering = false
        }
    }

    private func selectAvailableModel() {
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id ?? ""
        }
    }
}

/// Shared instrument selector deck, without raster portraits.
private struct BotSelectorKey: View {
    let specialist: BotSpecialist
    let isSelected: Bool
    let run: BotRunRecord?
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: specialist.symbol).font(.system(size: 16, weight: .medium))
                VStack(alignment: .leading, spacing: 4) {
                    Text(specialist.name).font(.appUI(size: 13, weight: .semibold))
                    Text(run?.phase ?? "Ready for a task")
                        .font(.appMono(size: 10)).opacity(0.75).lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle().fill(run.map { $0.state.isTerminal ? Theme.statusNeutral : Theme.positive }
                              ?? Theme.statusNeutral).frame(width: 5, height: 5)
            }
            .foregroundStyle(isSelected ? Color.white : Instrument.ink)
            .padding(.horizontal, 14).frame(width: 176, height: 56)
            .background(isSelected ? Instrument.darkInsert : Instrument.silverTop)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isSelected ? Instrument.accentOrange : Instrument.seam)
                    .frame(height: 2)
            }
            .brightness(hovering && !isSelected ? 0.035 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(specialist.detail)
    }
}
