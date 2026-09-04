import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct RemoteInlineNotice: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BeetTheme.accentBright)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .remoteGlass(appearance, radius: 15)
        .accessibilityElement(children: .contain)
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
    @State private var workflowPrompt = ""
    @State private var selectedModelID = ""

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !store.isConnected {
                            RemoteInlineNotice(
                                title: "Mac unreachable",
                                detail: "Bots run on your Mac. Reconnect to start or steer a run.",
                                actionTitle: "Retry",
                                action: { Task { await store.connectSaved() } })
                        } else if let notice = store.backgroundNotice {
                            RemoteInlineNotice(
                                title: "Some bot data didn't load",
                                detail: notice,
                                actionTitle: "Retry",
                                action: { Task { try? await store.refresh() } })
                        }
                        workflowCard
                        Text("BOTS")
                            .font(.caption2.weight(.bold)).tracking(1.1)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .padding(.top, 2)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(RemoteBotProfile.profiles) { profile in
                                NavigationLink(value: profile.id) {
                                    RemoteBotIndexCard(profile: profile, run: run(for: profile.id))
                                }
                                .buttonStyle(RemotePressButtonStyle())
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { try? await store.refresh() }
            }
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
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Adaptive workflow", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Describe an outcome and the bots divide the work between them.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if !store.startModels.isEmpty {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                .accessibilityLabel("Model for the workflow")
            }
            TextField("Describe the complete outcome", text: $workflowPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canOrchestrate)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        }
        .padding(14)
        .remoteGlass(appearance, radius: 18, strong: true)
    }
}

/// One tile in the bot index: who the bot is, plus whatever it is doing now.
private struct RemoteBotIndexCard: View {
    let profile: RemoteBotProfile
    let run: RemoteBotRun?
    @Environment(\.remoteAppearance) private var appearance

    private var isActive: Bool { run.map { !$0.isTerminal } ?? false }

    private var statusText: String {
        guard let run else { return profile.isSpecialist ? "Idle" : "Chat only" }
        if run.isTerminal { return "Last run \(run.phase)" }
        return run.phase.capitalized
    }

    var body: some View {
        HStack(spacing: 13) {
            RemoteBotThumbnail(profile: profile, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text(profile.subtitle)
                    .font(.caption)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                HStack(spacing: 5) {
                    Circle()
                        .fill(isActive ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance).opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(statusText).font(.caption2.weight(.medium))
                }
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .padding(.top, 1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .accessibilityHidden(true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 18)
        .overlay {
            // Only the active bot draws its own ring; the rest keep the
            // gradient hairline that remoteGlass already applies.
            if isActive {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(BeetTheme.accentBright.opacity(0.6), lineWidth: 1.25)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The page for one bot: what it does, what it is running, and the two ways to
/// put it to work — a chat session, or an autonomous run.
private struct RemoteBotDetailView: View {
    let store: RemoteStore
    let profile: RemoteBotProfile
    @Binding var selectedModelID: String
    let onOpen: (UUID) -> Void
    @Environment(\.remoteAppearance) private var appearance
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
                    chatCard
                    if let run, !run.isTerminal { activeRunCard(run) }
                    if profile.isSpecialist { newRunCard }
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
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                RemoteBotThumbnail(profile: profile, size: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.title3.weight(.semibold))
                    Text(profile.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
            }
            Text(profile.instruction ?? "A general assistant with no specialist brief. Good for planning, explaining, and deciding.")
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 20, strong: true)
    }

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chat with \(profile.name)", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
            Text("A normal conversation, with this bot's brief applied.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if !profile.starters.isEmpty {
                Text("Openers").font(.caption2.weight(.bold)).tracking(0.8)
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
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 20)
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
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 20, strong: true)
    }

    @ViewBuilder
    private func runControls(_ run: RemoteBotRun) -> some View {
        switch run.state {
        case "recoverable":
            Button("Resume from checkpoint") { Task { _ = await store.resumeBotRun(run.id) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case "needsApproval":
            HStack(spacing: 10) {
                Button("Approve") { Task { _ = await store.approveBotRun(run.id, approved: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Decline", role: .destructive) { Task { _ = await store.approveBotRun(run.id, approved: false) } }
            }
            .controlSize(.large)
        case "needsInput":
            TextField("Answer \(profile.name)", text: $answerDraft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button("Send answer") {
                let answer = answerDraft
                Task { if await store.answerBotRun(run.id, answer: answer) { answerDraft = "" } }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        default:
            TextField("Steer this run", text: $steerDraft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("Steer") {
                    let message = steerDraft
                    Task { if await store.steerBotRun(run.id, message: message) { steerDraft = "" } }
                }
                .disabled(steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let sessionID = run.sessionID {
                    Button("Inspect") { onOpen(sessionID) }
                }
                Spacer()
                Button("Stop", role: .destructive) { Task { _ = await store.stopBotRun(run.id) } }
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
            TextField("Task for \(profile.name)", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStartRun)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 20)
    }

    private func lastRunCard(_ run: RemoteBotRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST RUN").font(.caption2.weight(.bold)).tracking(0.8)
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
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remoteGlass(appearance, radius: 20)
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

struct RemoteBotChooser: View {
    @Binding var selectedBotID: String
    @Environment(\.remoteAppearance) private var appearance

    private var effectiveID: String {
        selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BOT").font(.caption2.bold()).tracking(0.8)
                Spacer()
                Text(effectiveID == RemoteBotProfile.general.id ? "None — plain chat" : RemoteBotProfile.profile(id: effectiveID).name)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        let isSelected = effectiveID == profile.id
                        Button {
                            selectedBotID = RemoteBotProfile.resolvedID(profile.id) ?? ""
                        } label: {
                            VStack(spacing: 6) {
                                RemoteBotThumbnail(profile: profile, size: 48)
                                Text(profile.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? profile.tint : .primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(minWidth: 76)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .background(
                                BeetTheme.surface(appearance).opacity(isSelected ? 0.96 : 0.5),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isSelected ? profile.tint.opacity(0.7) : BeetTheme.line(appearance).opacity(0.5), lineWidth: isSelected ? 1.25 : 0.75)
                            }
                        }
                        .buttonStyle(RemotePressButtonStyle())
                        .accessibilityLabel(profile.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
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
                    .background(BeetTheme.surfaceStrong(appearance), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.16), lineWidth: 0.75))
                    .buttonStyle(RemotePressButtonStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Suggested tasks")
    }
}
