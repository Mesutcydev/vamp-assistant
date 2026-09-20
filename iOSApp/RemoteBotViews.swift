import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct RemoteInlineNotice: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        if let action {
            Button(action: action) {
                RemoteNoticeLabel(title: title, detail: detail, actionTitle: actionTitle)
            }
            .buttonStyle(RemotePressButtonStyle())
        } else {
            RemoteNoticeLabel(title: title, detail: detail)
        }
    }
}

/// Bots have their own screen now: an index of every profile with its live run
/// state, and a detail page per bot. They used to be split between a cramped
/// home-screen strip (start a chat) and a grid of dense cards (start a run), so
/// nothing ever said what a bot is or what it is currently doing.
struct RemoteBotsView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var path: [String] = []
    @State private var selectedBotID: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var workflowPrompt = ""
    @State private var selectedModelID = ""

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    library.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: {
                    if let selectedBotID {
                        RemoteBotDetailView(store: store, profile: RemoteBotProfile.profile(id: selectedBotID),
                            selectedModelID: $selectedModelID, onOpen: onOpen)
                            .id(selectedBotID)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "person.2").font(.title2)
                            VampMicroLabel(title: "Choose a specialist")
                            Text("Select a bot to open its workspace.").font(.subheadline)
                        }
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RemoteInstrument.canvas)
                    }
                }
            } else {
                NavigationStack(path: $path) { library }
            }
        }
        .presentationDetents([.large])
    }

    private var library: some View {
            RemoteInstrumentForm {
                if !store.isConnected {
                    Section {
                        RemoteInlineNotice(
                            title: "Mac unreachable",
                            detail: "Bots run on your Mac. Reconnect to start or steer a run.",
                            actionTitle: "Retry",
                            action: { Task { await store.connectSaved() } })
                            .listRowInsets(EdgeInsets())
                    }
                } else if let notice = store.backgroundNotice {
                    Section {
                        RemoteInlineNotice(
                            title: "Some bot data didn't load",
                            detail: notice,
                            actionTitle: "Retry",
                            action: { Task { try? await store.refresh() } })
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    workflowPanel
                } header: {
                    Text("Delegate")
                }
                Section("Specialists") {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        if horizontalSizeClass == .regular {
                            Button { selectedBotID = profile.id } label: {
                                RemoteBotIndexRow(profile: profile, run: run(for: profile.id))
                                    .background(selectedBotID == profile.id ? RemoteInstrument.recess : .clear)
                            }
                            .buttonStyle(RemotePressButtonStyle())
                            .accessibilityAddTraits(selectedBotID == profile.id ? .isSelected : [])
                        } else {
                            NavigationLink(value: profile.id) {
                                RemoteBotIndexRow(profile: profile, run: run(for: profile.id))
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BeetTheme.background(appearance))
            .refreshable { try? await store.refresh() }
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
            .navigationDestination(for: String.self) { id in
                RemoteBotDetailView(
                    store: store,
                    profile: RemoteBotProfile.profile(id: id),
                    selectedModelID: $selectedModelID,
                    onOpen: onOpen)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }.vampUtilityAction()
            }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 10)
                    .allowsHitTesting(false)
            }
            .task {
                if store.startModels.isEmpty { await store.loadStartModels() }
                if selectedModelID.isEmpty { selectedModelID = store.startModels.first?.id ?? "" }
                try? await store.refresh()
            }
    }

    private func run(for profileID: String) -> RemoteBotRun? {
        store.botRuns.first { $0.profileID == profileID && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profileID }
    }

    private var canOrchestrate: Bool {
        store.isConnected && !selectedModelID.isEmpty
            && !workflowPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workflowPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(RemoteInstrument.orange).frame(width: 3, height: 12)
                    .accessibilityHidden(true)
                VampMicroLabel(title: "Adaptive workflow")
            }
            .padding(.leading, 12)
            Text("Describe an outcome and the bots divide the work between them.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .padding(.leading, 12)
            if !store.startModels.isEmpty {
                Picker("Model", selection: $selectedModelID) {
                    if selectedModelID.isEmpty { Text("Choose model").tag("") }
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("Model for the workflow")
            }
            TextField("Describe the complete outcome", text: $workflowPrompt, prompt: Text("Describe the complete outcome").foregroundStyle(RemoteInstrument.ink.opacity(0.58)), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(12)
                .remoteRecess()
            Button {
                let prompt = workflowPrompt
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    if await store.orchestrateBots(modelID: selectedModelID, prompt: prompt) {
                        workflowPrompt = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            } label: {
                Text("Orchestrate")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(RemotePrimaryButtonStyle(alignment: .leading))
            .controlSize(.large)
            .disabled(!canOrchestrate)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        }
        .padding(12)
        .remoteFaceplate()
    }
}

/// One native list row in the bot index: who the bot is, plus whatever it is doing now.
private struct RemoteBotIndexRow: View {
    let profile: RemoteBotProfile
    let run: RemoteBotRun?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var status: String {
        run?.phase ?? (profile.isSpecialist ? "Idle" : "Chat")
    }
    private var stateColor: Color {
        if run?.state == "failed" { return RemoteInstrument.danger }
        if let run, !run.isTerminal { return RemoteInstrument.green }
        if !profile.isSpecialist { return RemoteInstrument.green }
        return RemoteInstrument.secondaryInk
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SpecialistIndexMark(profile: profile)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(profile.name).font(.body.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 4)
                        RemoteMobileStatus(title: status, color: stateColor, isActive: run.map { !$0.isTerminal } ?? false)
                            .frame(width: 96, alignment: .leading)
                    }
                }
                Text(profile.subtitle).font(.subheadline)
                    .foregroundStyle(RemoteInstrument.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if dynamicTypeSize.isAccessibilitySize {
                    RemoteMobileStatus(title: status, color: stateColor, isActive: run.map { !$0.isTerminal } ?? false)
                }
            }
        }
        .foregroundStyle(RemoteInstrument.ink)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The page for one bot: what it does, what it is running, and the two ways to
/// put it to work — a chat session, or an autonomous run.
struct RemoteBotDetailView: View {
    let store: RemoteStore
    let profile: RemoteBotProfile
    @Binding var selectedModelID: String
    let onOpen: (UUID) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var prompt = ""
    @State private var detailMode = "chat"
    @State private var steerDraft = ""
    @State private var answerDraft = ""
    @State private var showStartChat = false
    @State private var deferredChatSessionID: UUID?
    @State private var mutationInFlight = false

    init(store: RemoteStore, profile: RemoteBotProfile, selectedModelID: Binding<String>,
         initialMode: String = "chat", onOpen: @escaping (UUID) -> Void) {
        self.store = store
        self.profile = profile
        self._selectedModelID = selectedModelID
        self._detailMode = State(initialValue: initialMode == "run" ? "run" : "chat")
        self.onOpen = onOpen
    }

    private var run: RemoteBotRun? {
        store.botRuns.first { $0.profileID == profile.id && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profile.id }
    }

    private var canStartRun: Bool {
        store.isConnected && !selectedModelID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    if !store.isConnected {
                        RemoteInlineNotice(
                            title: "Mac unreachable",
                            detail: "Reconnect to start a chat or a run with \(profile.name).",
                            actionTitle: "Retry",
                            action: { Task { await store.connectSaved() } })
                    }
                    if let run, !run.isTerminal { activeRunCard(run) }
                    if profile.isSpecialist {
                        RemoteInstrumentSegments(selection: $detailMode, options: [("Chat", "chat"), ("Run", "run")])
                        if detailMode == "chat" { chatCard } else { newRunCard }
                    } else { chatCard }
                    if let run, run.isTerminal { lastRunCard(run) }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { try? await store.refresh() }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showStartChat, onDismiss: openDeferredChat) {
            StartSessionSheet(store: store, initialBotID: RemoteBotProfile.resolvedID(profile.id) ?? "") { sessionID in
                deferredChatSessionID = sessionID
                showStartChat = false
            }
        }
    }

    private func openDeferredChat() {
        guard let sessionID = deferredChatSessionID else { return }
        deferredChatSessionID = nil
        Task { @MainActor in
            await Task.yield()
            onOpen(sessionID)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SpecialistIndexMark(profile: profile)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.title3.weight(.semibold))
                    Text(profile.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
            }
            DisclosureGroup("Role instructions") {
                Text(profile.instruction ?? "A general assistant with no specialist brief. Good for planning, explaining, and deciding.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .frame(minHeight: 44)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { VampHairline() }
    }

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chat with \(profile.name)", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
            Text("A normal conversation, with this bot's brief applied.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if !profile.starters.isEmpty {
                Text("Openers").font(.system(.caption2, design: .monospaced, weight: .medium)).tracking(0.8)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                ForEach(profile.starters, id: \.self) { starter in
                    Text("· \(starter)")
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showStartChat = true
            } label: {
                Label("Start a chat", systemImage: "plus.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .disabled(!store.isConnected)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { VampHairline() }
    }

    private func activeRunCard(_ run: RemoteBotRun) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.phase.capitalized).font(.subheadline.weight(.semibold))
                Spacer()
                if let queue = run.queuePosition {
                    Text("Queue #\(queue)").font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
            }
            Text(run.prompt).font(.subheadline).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            runMetadata(run)
            if !run.latestOutput.isEmpty {
                Text(run.latestOutput)
                    .font(.caption)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gate = run.pendingInteraction ?? run.errorMessage {
                Text(gate).font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            runControls(run)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { VampHairline() }
    }

    private func performMutation(_ operation: @escaping () async -> Bool) {
        guard !mutationInFlight else { return }
        mutationInFlight = true
        Task {
            _ = await operation()
            mutationInFlight = false
        }
    }

    @ViewBuilder
    private func runControls(_ run: RemoteBotRun) -> some View {
        switch run.state {
        case "recoverable":
            Button("Resume from checkpoint") { performMutation { await store.resumeBotRun(run.id) } }
                .buttonStyle(RemotePrimaryButtonStyle())
                .controlSize(.large)
                .disabled(mutationInFlight)
        case "needsApproval":
            HStack(spacing: 10) {
                Button("Approve") { performMutation { await store.approveBotRun(run.id, approved: true) } }
                    .buttonStyle(RemotePrimaryButtonStyle())
                Button("Decline", role: .destructive) { performMutation { await store.approveBotRun(run.id, approved: false) } }
            }
            .controlSize(.large)
            .disabled(mutationInFlight)
        case "needsInput":
            TextField("Answer \(profile.name)", text: $answerDraft, prompt: Text("Answer \(profile.name)").foregroundStyle(RemoteInstrument.secondaryInk), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(RemoteInstrument.seam, lineWidth: 0.75) }
            Button("Send answer") {
                let answer = answerDraft
                performMutation {
                    let success = await store.answerBotRun(run.id, answer: answer)
                    if success { answerDraft = "" }
                    return success
                }
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .controlSize(.large)
            .disabled(answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mutationInFlight)
        default:
            TextField("Steer this run", text: $steerDraft, prompt: Text("Steer this run").foregroundStyle(RemoteInstrument.secondaryInk), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(RemoteInstrument.seam, lineWidth: 0.75) }
            HStack(spacing: 10) {
                Button("Steer") {
                    let message = steerDraft
                    performMutation {
                        let success = await store.steerBotRun(run.id, message: message)
                        if success { steerDraft = "" }
                        return success
                    }
                }
                .disabled(steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mutationInFlight)
                if let sessionID = run.sessionID {
                    Button("Inspect") { onOpen(sessionID) }
                }
                Spacer()
                Button("Stop", role: .destructive) { performMutation { await store.stopBotRun(run.id) } }
                    .disabled(mutationInFlight)
            }
            .controlSize(.large)
        }
    }

    private func runMetadata(_ run: RemoteBotRun) -> some View {
        HStack(spacing: 9) {
            Label(run.resourceClass ?? "remote", systemImage: "cpu")
            if run.workflowID != nil {
                Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted")
            }
            if let dependencies = run.dependencyRunIDs, !dependencies.isEmpty {
                Label("\(dependencies.count) deps", systemImage: "arrow.triangle.branch")
            }
            if let retry = run.retryCount, retry > 0 {
                Label("Retry \(retry)", systemImage: "arrow.clockwise")
            }
        }
        .font(.caption2)
        .foregroundStyle(BeetTheme.secondaryText(appearance))
    }

    private var newRunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Run autonomously", systemImage: "play.circle.fill")
                .font(.headline)
            Text("\(profile.name) works the task on its own and reports back.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if !store.startModels.isEmpty {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                .accessibilityLabel("Model for this run")
            }
            TextField("Task for \(profile.name)", text: $prompt, prompt: Text("Task for \(profile.name)").foregroundStyle(RemoteInstrument.secondaryInk), axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(12)
                .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(RemoteInstrument.seam, lineWidth: 0.75) }
            Button("Start run") {
                let text = prompt
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    if await store.startBotRun(profileID: profile.id, modelID: selectedModelID, prompt: text) {
                        prompt = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .controlSize(.large)
            .disabled(!canStartRun)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { VampHairline() }
    }

    private func lastRunCard(_ run: RemoteBotRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST RUN").font(.system(.caption2, design: .monospaced, weight: .medium)).tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            Text(run.phase.capitalized).font(.subheadline.weight(.semibold))
            Text(run.prompt).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let trace = run.traceID {
                Text("Trace \(trace.suffix(10)) · \(run.artifacts?.count ?? 0) artifacts")
                    .font(.caption2.monospaced())
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            if let sessionID = run.sessionID {
                Button("Open the transcript") { onOpen(sessionID) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    .controlSize(.large)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { VampHairline() }
    }
}

struct RemoteBotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let starters: [String]
    let instruction: String?

    static let general = RemoteBotProfile(
        id: "general", name: "Assistant", subtitle: "Balanced assistant",
        starters: ["Plan this task", "Explain this project", "Help me decide"],
        instruction: nil)
    static let profiles: [RemoteBotProfile] = [
        general,
        .init(id: "builder", name: "Builder", subtitle: "Build and fix",
              starters: ["Fix the current issue", "Build this feature", "Run the tests"],
              instruction: "Work as a focused software builder. Inspect the existing project, implement the request completely, preserve unrelated work, and verify the result."),
        .init(id: "reviewer", name: "Reviewer", subtitle: "Diff and risks",
              starters: ["Review my changes", "Check for regressions", "Audit this diff"],
              instruction: "Work as a careful code reviewer. Inspect the current changes, identify concrete bugs and regressions first, and give evidence-backed recommendations. Do not edit unless asked."),
        .init(id: "navigator", name: "Navigator", subtitle: "Browser control",
              starters: ["Open and inspect this site", "Test this web flow", "Compare these pages"],
              instruction: "Work as a browser navigator. Use the available browser tools directly, keep actions scoped to the request, and summarize what changed or what you found."),
        .init(id: "researcher", name: "Researcher", subtitle: "Sources and synthesis",
              starters: ["Research this topic", "Compare the best options", "Verify this claim"],
              instruction: "Work as a technical researcher. Prefer primary sources, compare evidence, distinguish facts from inference, and return concise actionable findings."),
    ]

    static func profile(id: String) -> RemoteBotProfile {
        profiles.first(where: { $0.id == id }) ?? general
    }

    static func resolvedID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id != general.id else { return nil }
        return id
    }

    @MainActor var tint: Color {
        BeetTheme.accentBright
    }

    /// Only the specialists have an autonomous-run backend; the general
    /// assistant is chat-only.
    var isSpecialist: Bool { id != RemoteBotProfile.general.id }
}

private struct SpecialistIndexMark: View {
    let profile: RemoteBotProfile

    var body: some View {
        Text(String(format: "%02d", (RemoteBotProfile.profiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1))
            .font(.system(.subheadline, design: .monospaced, weight: .medium))
            .foregroundStyle(RemoteInstrument.secondaryInk)
            .frame(minWidth: 30, minHeight: 44, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

struct RemoteBotChooser: View {
    @Binding var selectedBotID: String

    private var effectiveID: String {
        selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(RemoteBotProfile.profiles) { profile in
                Button {
                    selectedBotID = RemoteBotProfile.resolvedID(profile.id) ?? ""
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    RemoteBotIndexRow(profile: profile, run: nil)
                        .padding(.horizontal, 12)
                        .background(effectiveID == profile.id ? RemoteInstrument.recess : .clear)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(RemoteInstrument.orange).frame(width: 2)
                                .padding(.vertical, 14)
                                .opacity(effectiveID == profile.id ? 1 : 0)
                        }
                }
                .buttonStyle(RemoteSessionButtonStyle())
                .accessibilityAddTraits(effectiveID == profile.id ? .isSelected : [])
            }
        }
    }
}

struct RemoteBotStarters: View {
    let starters: [String]
    let tint: Color
    let appearance: RemoteAppearance
    @Binding var prompt: String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(starters, id: \.self) { starter in
                    Button(starter) {
                        prompt = starter
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .padding(.horizontal, 11)
                    .frame(minHeight: 34)
                    .background(RemoteInstrument.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(RemoteInstrument.seam, lineWidth: 0.75))
                    .buttonStyle(RemotePressButtonStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Suggested tasks")
    }
}
