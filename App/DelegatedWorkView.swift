import SwiftUI

/// The requesting conversation and the worker's session have distinct IDs.
/// Unlinked legacy and remote work remains visible from chat's Activity action.
struct DelegatedWorkSection: View {
    @EnvironmentObject private var appState: AppState
    var originatingSessionID: UUID?
    var body: some View {
        DelegatedWorkRows(coordinator: appState.botRuns, originatingSessionID: originatingSessionID)
    }
}

private struct DelegatedWorkRows: View {
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    @ObservedObject var coordinator: BotRunCoordinator
    var originatingSessionID: UUID?
    private var runs: [BotRunRecord] {
        coordinator.runs.filter { originatingSessionID != nil && $0.originatingSessionID == originatingSessionID }
    }
    var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Specialist work", systemImage: "person.2")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                ForEach(runs) { run in
                    SpecialistRunCard(run: run, coordinator: coordinator) {
                        NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.specialist(run.id), windowID: workspaceWindowID)
                    }
                }
            }
            .accessibilityIdentifier("inline-specialist-work")
        }
    }
}

struct DelegatedWorkList: View {
    @EnvironmentObject private var appState: AppState
    var onOpen: (WorkspacePanel) -> Void
    var body: some View { DelegatedWorkListContent(coordinator: appState.botRuns, onOpen: onOpen) }
}

private struct DelegatedWorkListContent: View {
    @ObservedObject var coordinator: BotRunCoordinator
    var onOpen: (WorkspacePanel) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Specialist activity").font(.system(size: 20, weight: .semibold))
                Text("Runs from your chats, paired devices, and earlier versions.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                if coordinator.runs.isEmpty {
                    ContentUnavailableView("No specialist work yet", systemImage: "person.2",
                        description: Text("Ask Vamp Assistant to delegate a task in your conversation."))
                }
                ForEach(coordinator.runs) { run in
                    SpecialistRunCard(run: run, coordinator: coordinator) { onOpen(.specialist(run.id)) }
                }
                if let error = coordinator.persistenceError {
                    Text(error).foregroundStyle(Theme.warning)
                    Button("Retry saving") { Task { await coordinator.retryPersistence() } }
                }
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.workspaceCanvas)
    }
}

private struct SpecialistRunCard: View {
    let run: BotRunRecord
    @ObservedObject var coordinator: BotRunCoordinator
    var onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: run.state == .completed ? "checkmark.circle" : "person.crop.circle")
                        .foregroundStyle(run.state == .needsApproval || run.state == .needsInput ? Theme.warning : Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.profileName).font(.system(size: 13, weight: .semibold))
                        Text(run.phase).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open \(run.profileName): \(run.phase)")
            if let evidence = run.evidence {
                Label(evidence.label, systemImage: evidence.confidence == .verified ? "checkmark.seal" : "circle.dotted")
                    .font(.system(size: 12)).foregroundStyle(evidence.confidence == .verified ? Theme.success : Theme.textSecondary)
            }
            if run.state == .needsApproval || run.state == .needsInput || run.state == .recoverable {
                RunInteractionControls(run: run, coordinator: coordinator, onReview: onOpen)
            } else if !run.latestOutput.isEmpty {
                Text(run.latestOutput).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct SpecialistRunDetail: View {
    @EnvironmentObject private var appState: AppState
    let runID: UUID
    var onOpen: (WorkspacePanel) -> Void
    var body: some View {
        SpecialistRunDetailContent(runID: runID, coordinator: appState.botRuns, onOpen: onOpen)
    }
}

private struct SpecialistRunDetailContent: View {
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    @EnvironmentObject private var appState: AppState
    let runID: UUID
    @ObservedObject var coordinator: BotRunCoordinator
    var onOpen: (WorkspacePanel) -> Void
    @State private var applyResult: String?
    @State private var applying = false
    var body: some View {
        ScrollView {
            if let run = coordinator.record(runID) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(run.profileName).font(.system(size: 24, weight: .semibold))
                    Text(run.prompt).font(AppFont.chatBody).textSelection(.enabled)
                    Label(run.phase, systemImage: "circle.dotted").foregroundStyle(Theme.textSecondary)
                    if let controller = appState.specialistController(for: runID) {
                        SpecialistPendingPreview(controller: controller)
                    }
                    RunInteractionControls(run: run, coordinator: coordinator,
                        onReview: { if let work = run.workPath { onOpen(.runChanges(runID, work)) } })
                    if !run.state.isTerminal && run.state != .recoverable {
                        RunSteeringControls(run: run, coordinator: coordinator)
                    }
                    if !run.latestOutput.isEmpty {
                        Text(run.latestOutput).font(AppFont.chatBody).textSelection(.enabled)
                    }
                    if let evidence = run.evidence {
                        SettingsCard(title: "Verification", icon: "checkmark.shield") {
                            Text(evidence.label).font(.system(size: 13, weight: .medium))
                            if !evidence.missing.isEmpty {
                                Text("Evidence still needed: \(evidence.missing.map(\.rawValue).joined(separator: ", "))")
                                    .foregroundStyle(Theme.warning)
                            }
                            ForEach(run.acceptanceCriteria ?? []) { criterion in
                                Label(criterion.summary, systemImage: criterion.satisfied ? "checkmark.circle" : "circle")
                            }
                            ForEach(run.artifacts ?? []) { artifact in
                                Text(artifact.title).fontWeight(.medium)
                                Text(artifact.value).textSelection(.enabled)
                            }
                        }
                    }
                    if run.baseTree != nil, let work = run.workPath {
                        Button("Review changes", systemImage: "doc.text.magnifyingglass") { onOpen(.runChanges(runID, work)) }
                        if run.state == .completed {
                            Button("Apply changes to project") {
                                applying = true
                                Task { applyResult = await appState.applyBotChanges(runID: runID); applying = false }
                            }.buttonStyle(.borderedProminent).disabled(applying)
                        }
                    }
                    if let applyResult { Text(applyResult).foregroundStyle(Theme.textSecondary).textSelection(.enabled) }
                    HStack {
                        if let computer = appState.botComputers.computers.first(where: { $0.profileID == run.profileID }) {
                            Button("Private browser", systemImage: "globe") { onOpen(.specialistBrowser(computer.id)) }
                        }
                        if let id = run.sessionID {
                            Button("Open worker chat") { NotificationCenter.default.postWorkspace(name: .openSessionRecord, object: id, windowID: workspaceWindowID) }
                        }
                    }.buttonStyle(.borderless)
                    DisclosureGroup("Run details") {
                        BotConsolePanel(computer: appState.botComputers.computers.first { $0.profileID == run.profileID },
                            run: run, events: coordinator.events(for: runID))
                        Text("Model: \(run.modelID)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            } else { ContentUnavailableView("Run unavailable", systemImage: "person.crop.circle.badge.questionmark") }
        }.background(Theme.workspaceCanvas)
    }
}

/// Preview only; decision delivery still goes through the coordinator's durable log.
private struct SpecialistPendingPreview: View {
    @ObservedObject var controller: AgentSessionController
    var body: some View {
        if let approval = controller.pendingApproval {
            VStack(alignment: .leading, spacing: 8) {
                Text(approval.invocation.summary).font(.system(size: 13, weight: .semibold))
                if case .diff(let diff, _) = approval.preview { DiffPreview(diff: diff) }
            }
        }
        if let plan = controller.pendingPlan {
            Text(plan).font(AppFont.chatBody).textSelection(.enabled)
        }
    }
}

private struct RunInteractionControls: View {
    let run: BotRunRecord
    @ObservedObject var coordinator: BotRunCoordinator
    var onReview: () -> Void
    @ObservedObject private var drafts = BotDraftStore.shared
    @State private var answer = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = run.pendingInteraction ?? run.errorMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.warning).textSelection(.enabled)
            }
            if run.state == .needsApproval {
                HStack {
                    Button("Review", action: onReview)
                    Button("Allow") { deliver(.approve) }.buttonStyle(.borderedProminent)
                    Button("Reject") { deliver(.decline) }
                }
            }
            if run.state == .needsInput {
                TextField("Your answer…", text: $answer, axis: .vertical).vampField().lineLimit(1...4)
                    .onSubmit { deliver(.answer, payload: answer) }
                Button("Send answer") { deliver(.answer, payload: answer) }
                    .buttonStyle(.borderedProminent).disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if run.state == .recoverable || run.state == .interrupted {
                Button("Resume work", systemImage: "arrow.clockwise") {
                    if !coordinator.resume(runID: run.id) { error = "This run could not be resumed. Check its model connection and try again." }
                }
            }
            if run.state == .failed || run.state == .stopped {
                Button("Run again", systemImage: "arrow.clockwise") {
                    if case .failure(let failure) = coordinator.start(profileID: run.profileID, profileName: run.profileName,
                        modelID: run.modelID, prompt: run.prompt, projectPath: run.projectPath,
                        originatingSessionID: run.originatingSessionID) { error = failure.localizedDescription }
                }
            }
            if !run.state.isTerminal {
                Button("Stop work", systemImage: "stop") { _ = coordinator.stop(runID: run.id) }.buttonStyle(.borderless)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .disabled(busy)
        .onAppear { answer = drafts.value(for: "answer.\(run.id)") }
        .onChange(of: answer) { _, value in drafts.set(value, for: "answer.\(run.id)") }
    }
    private func deliver(_ kind: BotRunCommandRecord.Kind, payload: String? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            let accepted = await coordinator.deliverCommand(runID: run.id, kind: kind, payload: payload)
            if accepted { if kind == .answer { answer = "" }; error = nil }
            else { error = "The response was not delivered. Your text is retained; try again." }
            busy = false
        }
    }
}

private struct RunSteeringControls: View {
    let run: BotRunRecord
    @ObservedObject var coordinator: BotRunCoordinator
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Steer this work…", text: $text, axis: .vertical).vampField().lineLimit(1...4)
            Button("Send guidance") {
                let submitted = text
                busy = true
                Task {
                    if await coordinator.deliverCommand(runID: run.id, kind: .steer, payload: submitted) {
                        text = ""; error = nil
                    } else { error = "Guidance was not delivered. Your draft is retained." }
                    busy = false
                }
            }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundStyle(Theme.warning) }
        }
        .onAppear { text = BotDraftStore.shared.value(for: "steer.\(run.id)") }
        .onChange(of: text) { _, value in BotDraftStore.shared.set(value, for: "steer.\(run.id)") }
    }
}
