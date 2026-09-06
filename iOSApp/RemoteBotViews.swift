import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The page for one bot: what it does, what it is running, and the two ways to
/// put it to work — a chat session, or an autonomous run.
struct RemoteBotDetailView: View {
    let store: RemoteStore
    let profile: RemoteBotProfile
    @Binding var selectedModelID: String
    let onOpen: (UUID) -> Void
    @State private var prompt = ""
    @State private var steerDraft = ""
    @State private var answerDraft = ""
    @Environment(\.remoteAppearance) private var appearance
    /// One cover: chat and the model picker are both sheets from this screen.
    @State private var sheet: BotSheet?
    @State private var starterPrompt = ""
    @State private var defaultModelSource = "local"

    enum BotSheet: String, Identifiable {
        case chat, model
        var id: String { rawValue }
    }

    private var preferences: RemoteStartPreferences { .shared }

    /// The model this bot starts on. Nil means it follows whatever was used
    /// last, which is what every bot did before.
    private var defaultModel: RemoteStartModelOption? {
        guard let id = preferences.defaultModelID(forBot: profile.id) else { return nil }
        return store.startModels.first { $0.id == id }
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
        List {
            Section { hero }
            if !store.isConnected {
                Section { RemoteOfflineRow(store: store) }
                    .remoteListRow()
            }
            chatSection
            modelSection
            if let run, !run.isTerminal { activeRunSection(run) }
            if profile.isSpecialist { newRunSection }
            if let run, run.isTerminal { lastRunSection(run) }
        }
        .remotePlainList()
        .remoteContentSheet()
        .refreshable { try? await store.refresh() }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { which in
            switch which {
            case .chat:
                StartSessionSheet(
                    store: store,
                    initialBotID: RemoteBotProfile.resolvedID(profile.id) ?? "",
                    initialPrompt: starterPrompt) { sessionID in
                        sheet = nil
                        onOpen(sessionID)
                    }
            case .model:
                RemoteModelPickerSheet(
                    models: store.startModels,
                    source: $defaultModelSource,
                    selectedModelID: Binding(
                        get: { preferences.defaultModelID(forBot: profile.id) ?? "" },
                        set: { id in
                            preferences.setDefaultModel(
                                store.startModels.first { $0.id == id }, forBot: profile.id)
                        }),
                    onRefresh: { await store.loadStartModels() },
                    isConnected: store.isConnected)
                    .environment(\.remoteAppearance, appearance)
            }
        }
        .task {
            if store.startModels.isEmpty { await store.loadStartModels() }
            defaultModelSource = defaultModel?.source ?? "local"
            // A run started from this page follows the bot's model unless the
            // row above it is changed for this one run.
            if selectedModelID.isEmpty, let id = preferences.defaultModelID(forBot: profile.id) {
                selectedModelID = id
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                // The roster dropped the portraits because five grey discs
                // carried no information; the detail page kept one out of
                // habit. The bot's own glyph says which bot this is.
                Image(systemName: profile.symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 46, height: 46)
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
                starterPrompt = ""
                sheet = .chat
            } label: {
                Label("Start a chat", systemImage: "plus.bubble")
            }
            .disabled(!store.isConnected)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
            // The starters were grey text you could not tap — they read as
            // disabled rows, which is exactly what they looked like. They open
            // a chat with the line already typed.
            ForEach(profile.starters, id: \.self) { starter in
                Button {
                    starterPrompt = starter
                    sheet = .chat
                } label: {
                    HStack(spacing: 10) {
                        Text(starter)
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.82))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(RemoteInk.quiet)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!store.isConnected)
            }
        } header: {
            RemoteSectionHeading("Chat")
        } footer: {
            Text("A normal conversation, with this bot's brief applied.")
        }
        .remoteListRow()
    }

    /// This bot's own model, in the same row shape the rest of the app uses.
    private var modelSection: some View {
        Section {
            RemoteDisclosureRow(
                title: "Default model",
                icon: "cpu",
                value: defaultModel?.name ?? "Follows last used",
                detail: defaultModel?.detail,
                action: { sheet = .model })
            if defaultModel != nil {
                Button("Clear", systemImage: "arrow.uturn.backward") {
                    preferences.setDefaultModel(nil, forBot: profile.id)
                }
                .foregroundStyle(.primary.opacity(0.82))
            }
        } header: {
            RemoteSectionHeading("Model")
        } footer: {
            Text("Chats and runs you start from here open on this model.")
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
            RemoteSectionHeading("Running now")
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
                .pickerStyle(.menu)
                .accessibilityLabel("Model for this run")
            }
            TextField("Task for \(profile.name)", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
            Button("Start run") {
                let text = prompt
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let modelID = selectedModelID.isEmpty
                    ? (preferences.defaultModelID(forBot: profile.id) ?? "")
                    : selectedModelID
                Task {
                    if await store.startBotRun(profileID: profile.id, modelID: modelID, prompt: text) {
                        prompt = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
            .fontWeight(.semibold)
            .disabled(!canStartRun)
            .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
        } header: {
            RemoteSectionHeading("Run autonomously")
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
            RemoteSectionHeading("Last run")
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

    /// One line glyph per bot. The portraits read as five identical grey discs
    /// at row size; a distinct symbol is what actually tells them apart.
    var symbol: String {
        switch id {
        case "builder": "hammer"
        case "reviewer": "text.magnifyingglass"
        case "navigator": "safari"
        case "researcher": "books.vertical"
        default: "bubble.left.and.bubble.right"
        }
    }

    @MainActor var tint: Color {
        BeetTheme.accentBright
    }

    /// Only the specialists have an autonomous-run backend; the general
    /// assistant is chat-only.
    var isSpecialist: Bool { id != RemoteBotProfile.general.id }
}
