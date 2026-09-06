import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Bots have their own screen now: an index of every profile with its live run
/// state, and a detail page per bot. They used to be split between a cramped
/// home-screen strip (start a chat) and a grid of dense cards (start a run), so
/// nothing ever said what a bot is or what it is currently doing.
struct RemoteBotsView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var workflowPrompt = ""
    @State private var selectedModelID = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    RemotePageHero(
                        icon: "person.3.sequence",
                        title: "Bots",
                        subtitle: "Five specialists that run on your Mac. Open one to start or steer its work.")
                }
                if !store.isConnected {
                    Section { RemoteOfflineRow(store: store) }
                        .remoteListRow()
                } else if let notice = store.backgroundNotice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { try? await store.refresh() } }
                    }
                    .remoteListRow()
                }
                workflowSection
                Section {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        NavigationLink(value: profile.id) {
                            RemoteBotIndexRow(profile: profile, run: run(for: profile.id))
                        }
                    }
                } header: {
                    Text("Bots")
                }
                .remoteListRow()
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .refreshable { try? await store.refresh() }
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                RemoteBotDetailView(
                    store: store,
                    profile: RemoteBotProfile.profile(id: id),
                    selectedModelID: $selectedModelID,
                    onOpen: onOpen)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if store.startModels.isEmpty { await store.loadStartModels() }
                if selectedModelID.isEmpty { selectedModelID = store.startModels.first?.id ?? "" }
                try? await store.refresh()
            }
        }
        .presentationDetents([.large])
    }

    private func run(for profileID: String) -> RemoteBotRun? {
        store.botRuns.first { $0.profileID == profileID && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profileID }
    }

    private var canOrchestrate: Bool {
        store.isConnected && !selectedModelID.isEmpty
            && !workflowPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workflowSection: some View {
        Section {
            if !store.startModels.isEmpty {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                .accessibilityLabel("Model for the workflow")
            }
            TextField("Describe the complete outcome", text: $workflowPrompt, axis: .vertical)
                .lineLimit(2...4)
            Button("Orchestrate") {
                let prompt = workflowPrompt
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    if await store.orchestrateBots(modelID: selectedModelID, prompt: prompt) {
                        workflowPrompt = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
            .disabled(!canOrchestrate)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        } header: {
            Text("Adaptive workflow")
        } footer: {
            Text("Describe an outcome and the bots divide the work between them.")
        }
        .remoteListRow()
    }
}

/// One tile in the bot index: who the bot is, plus whatever it is doing now.
/// One row in the bot index. The portrait stays: it is the only thing on this
/// screen that is ours rather than the platform's, and it is what makes the
/// list read as five characters instead of five settings.
private struct RemoteBotIndexRow: View {
    let profile: RemoteBotProfile
    let run: RemoteBotRun?

    private var isActive: Bool { run.map { !$0.isTerminal } ?? false }

    private var statusText: String {
        guard let run else { return profile.isSpecialist ? "Idle" : "Chat only" }
        if run.isTerminal { return "Last run \(run.phase)" }
        return run.phase.capitalized
    }

    var body: some View {
        HStack(spacing: 13) {
            RemoteBotThumbnail(profile: profile, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text(profile.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isActive ? BeetTheme.accentBright : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                }
                .foregroundStyle(isActive ? BeetTheme.accentBright : Color.secondary)
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The page for one bot: what it does, what it is running, and the two ways to
/// put it to work — a chat session, or an autonomous run.
private struct RemoteBotDetailView: View {
    let store: RemoteStore
    let profile: RemoteBotProfile
    @Binding var selectedModelID: String
    let onOpen: (UUID) -> Void
    @State private var prompt = ""
    @State private var steerDraft = ""
    @State private var answerDraft = ""
    @State private var showStartChat = false

    private var run: RemoteBotRun? {
        store.botRuns.first { $0.profileID == profile.id && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profile.id }
    }

    private var canStartRun: Bool {
        store.isConnected && !selectedModelID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section { hero }
            if !store.isConnected {
                Section { RemoteOfflineRow(store: store) }
                    .remoteListRow()
            }
            chatSection
            if let run, !run.isTerminal { activeRunSection(run) }
            if profile.isSpecialist { newRunSection }
            if let run, run.isTerminal { lastRunSection(run) }
        }
        .scrollContentBackground(.hidden)
        .background { RemoteBackdrop() }
        .refreshable { try? await store.refresh() }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showStartChat) {
            StartSessionSheet(store: store, initialBotID: RemoteBotProfile.resolvedID(profile.id) ?? "") { sessionID in
                showStartChat = false
                onOpen(sessionID)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RemoteBotThumbnail(profile: profile, size: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.title2.weight(.semibold))
                    Text(profile.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(profile.instruction ?? "A general assistant with no specialist brief. Good for planning, explaining, and deciding.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))
        .accessibilityElement(children: .combine)
    }

    private var chatSection: some View {
        Section {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showStartChat = true
            } label: {
                Label("Start a chat", systemImage: "plus.bubble")
            }
            .disabled(!store.isConnected)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
            ForEach(profile.starters, id: \.self) { starter in
                Text(starter)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Chat")
        } footer: {
            Text("A normal conversation, with this bot's brief applied.")
        }
        .remoteListRow()
    }

    private func activeRunSection(_ run: RemoteBotRun) -> some View {
        Section {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.phase.capitalized).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let queue = run.queuePosition {
                    Text("Queue #\(queue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(run.prompt).font(.subheadline).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            runMetadata(run)
            if !run.latestOutput.isEmpty {
                Text(run.latestOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gate = run.pendingInteraction ?? run.errorMessage {
                Label(gate, systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            runControls(run)
        } header: {
            Text("Running now")
        }
        .remoteListRow()
    }

    @ViewBuilder
    private func runControls(_ run: RemoteBotRun) -> some View {
        switch run.state {
        case "recoverable":
            Button("Resume from checkpoint") { Task { _ = await store.resumeBotRun(run.id) } }
                .fontWeight(.semibold)
        case "needsApproval":
            HStack(spacing: 16) {
                Button("Approve") { Task { _ = await store.approveBotRun(run.id, approved: true) } }
                    .fontWeight(.semibold)
                Button("Decline", role: .destructive) { Task { _ = await store.approveBotRun(run.id, approved: false) } }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
        case "needsInput":
            TextField("Answer \(profile.name)", text: $answerDraft, axis: .vertical)
                .lineLimit(1...4)
            Button("Send answer") {
                let answer = answerDraft
                Task { if await store.answerBotRun(run.id, answer: answer) { answerDraft = "" } }
            }
            .fontWeight(.semibold)
            .disabled(answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        default:
            TextField("Steer this run", text: $steerDraft, axis: .vertical)
                .lineLimit(1...4)
            HStack(spacing: 16) {
                Button("Steer") {
                    let message = steerDraft
                    Task { if await store.steerBotRun(run.id, message: message) { steerDraft = "" } }
                }
                .fontWeight(.semibold)
                .disabled(steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let sessionID = run.sessionID {
                    Button("Inspect") { onOpen(sessionID) }
                }
                Spacer(minLength: 0)
                Button("Stop", role: .destructive) { Task { _ = await store.stopBotRun(run.id) } }
            }
            .buttonStyle(.borderless)
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
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var newRunSection: some View {
        Section {
            if !store.startModels.isEmpty {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                .accessibilityLabel("Model for this run")
            }
            TextField("Task for \(profile.name)", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
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
            .fontWeight(.semibold)
            .disabled(!canStartRun)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        } header: {
            Text("Run autonomously")
        } footer: {
            Text("\(profile.name) works the task on its own and reports back.")
        }
        .remoteListRow()
    }

    private func lastRunSection(_ run: RemoteBotRun) -> some View {
        Section {
            LabeledContent("Finished", value: run.phase.capitalized)
            Text(run.prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let trace = run.traceID {
                Text("Trace \(trace.suffix(10)) · \(run.artifacts?.count ?? 0) artifacts")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let sessionID = run.sessionID {
                Button("Open the transcript") { onOpen(sessionID) }
            }
        } header: {
            Text("Last run")
        }
        .remoteListRow()
    }
}

struct RemoteBotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let imageName: String
    let starters: [String]
    let instruction: String?

    static let general = RemoteBotProfile(
        id: "general", name: "Assistant", subtitle: "Balanced assistant",
        imageName: "VampBackdrop",
        starters: ["Plan this task", "Explain this project", "Help me decide"],
        instruction: nil)
    static let profiles: [RemoteBotProfile] = [
        general,
        .init(id: "builder", name: "Builder", subtitle: "Build and fix",
              imageName: "BotBuilder",
              starters: ["Fix the current issue", "Build this feature", "Run the tests"],
              instruction: "Work as a focused software builder. Inspect the existing project, implement the request completely, preserve unrelated work, and verify the result."),
        .init(id: "reviewer", name: "Reviewer", subtitle: "Diff and risks",
              imageName: "BotReviewer",
              starters: ["Review my changes", "Check for regressions", "Audit this diff"],
              instruction: "Work as a careful code reviewer. Inspect the current changes, identify concrete bugs and regressions first, and give evidence-backed recommendations. Do not edit unless asked."),
        .init(id: "navigator", name: "Navigator", subtitle: "Browser control",
              imageName: "BotNavigator",
              starters: ["Open and inspect this site", "Test this web flow", "Compare these pages"],
              instruction: "Work as a browser navigator. Use the available browser tools directly, keep actions scoped to the request, and summarize what changed or what you found."),
        .init(id: "researcher", name: "Researcher", subtitle: "Sources and synthesis",
              imageName: "BotResearcher",
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

private struct RemoteBotThumbnail: View {
    let profile: RemoteBotProfile
    var size: CGFloat = 56

    var body: some View {
        Image(profile.imageName)
            .resizable()
            .scaledToFit()
            .saturation(0)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .shadow(color: profile.tint.opacity(0.22), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}
