import SwiftUI
import UIKit

/// Starting a session, reduced to the one thing only the user can supply.
///
/// The old sheet asked nine questions in a single scroll — mode, folder, bot,
/// starters, model source, bot computer, API key, model, reasoning — before the
/// prompt field it all led to, and forgot every answer as soon as it closed.
/// Now the prompt is first and focused, the three answers that vary are one
/// tappable line each (pre-filled with what was used last time), and everything
/// that is really setup lives behind "More options". A returning user types and
/// taps Start.
struct StartSessionSheet: View {
    let store: RemoteStore
    let initialBotID: String
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @FocusState private var promptFocused: Bool

    private var preferences: RemoteStartPreferences { .shared }

    @State private var prompt = ""
    @State private var selectedBotID = ""
    @State private var selectedModelID = ""
    @State private var selectedSource = "local"
    @State private var selectedWorkspacePath = ""
    @State private var selectedReasoningEffort: String?
    @State private var botComputers: [RemoteBotComputer] = []
    @State private var selectedBotComputerID: UUID?
    @State private var isStarting = false
    @State private var isLoading = true
    @State private var showModelPicker = false
    @State private var showWorkspacePicker = false
    @State private var showBotPicker = false
    @State private var showAdvanced = false

    // MARK: Derived state

    private var botProfile: RemoteBotProfile {
        RemoteBotProfile.profile(id: selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID)
    }

    private var selectedModel: RemoteStartModelOption? {
        store.startModels.first { $0.id == selectedModelID }
    }

    private var attachedComputer: RemoteBotComputer? {
        botComputers.first { $0.id == selectedBotComputerID }
    }

    private var selectedWorkspace: RemoteWorkspace? {
        store.workspaces.first { $0.path == selectedWorkspacePath }
    }

    /// No folder and no bot computer means a plain conversation. Mode is not a
    /// separate switch any more — it is whatever this answers.
    private var isChatOnly: Bool {
        attachedComputer == nil && selectedWorkspacePath.isEmpty
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        store.isConnected && !selectedModelID.isEmpty && !trimmedPrompt.isEmpty && !isStarting
    }

    /// Why Start is unavailable, in the user's terms. A disabled button that
    /// never says what is missing was the single most common way this screen
    /// stalled people.
    private var blockedReason: String? {
        if isStarting { return nil }
        if !store.isConnected { return "Reconnect to your Mac to start a session." }
        if store.startModels.isEmpty {
            return isLoading ? "Loading models from your Mac…" : "No models available. Add an API key under More options."
        }
        if selectedModelID.isEmpty { return "Choose a model first." }
        if trimmedPrompt.isEmpty { return "Type what you want done." }
        return nil
    }

    private var locationValue: String {
        if let attachedComputer { return RemoteBotComputerNaming.displayName(attachedComputer) }
        if selectedWorkspacePath.isEmpty { return "Chat only" }
        return selectedWorkspace?.name ?? (selectedWorkspacePath as NSString).lastPathComponent
    }

    private var locationDetail: String? {
        if attachedComputer != nil { return "Bot computer" }
        if selectedWorkspacePath.isEmpty { return "No project folder" }
        return selectedWorkspacePath
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                VStack(spacing: 0) {
                    if !store.isConnected { RemoteReconnectBanner(store: store) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            promptCard
                            RemoteBotStarters(
                                starters: botProfile.starters,
                                tint: botProfile.tint,
                                appearance: appearance,
                                prompt: $prompt)
                            setupCard
                            moreOptionsButton
                        }
                        .padding(18)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    startBar
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showModelPicker) {
                RemoteModelPickerSheet(
                    models: store.startModels,
                    source: $selectedSource,
                    selectedModelID: $selectedModelID,
                    onSelect: { model in
                        selectedReasoningEffort = model.defaultReasoningEffort
                        preferences.remember(model: model)
                    },
                    onRefresh: { await store.loadStartModels() })
                    .environment(\.remoteAppearance, appearance)
            }
            .sheet(isPresented: $showWorkspacePicker) {
                RemoteWorkspacePickerSheet(
                    store: store,
                    selectedPath: $selectedWorkspacePath,
                    attachedComputerName: attachedComputer.map(RemoteBotComputerNaming.displayName))
                    .environment(\.remoteAppearance, appearance)
            }
            .sheet(isPresented: $showBotPicker) {
                RemoteBotPickerSheet(selectedBotID: $selectedBotID)
                    .environment(\.remoteAppearance, appearance)
            }
            .sheet(isPresented: $showAdvanced) {
                RemoteStartAdvancedSheet(
                    store: store,
                    botComputers: $botComputers,
                    selectedBotComputerID: $selectedBotComputerID,
                    reasoningEffort: $selectedReasoningEffort,
                    model: selectedModel,
                    botProfile: botProfile,
                    reload: loadBotComputers)
                    .environment(\.remoteAppearance, appearance)
            }
            .task { await load() }
            .onChange(of: selectedWorkspacePath) { _, path in
                preferences.workspacePath = path
                // Choosing a folder is a statement about where the work
                // happens; a bot computer would silently override it.
                if !path.isEmpty { selectedBotComputerID = nil }
            }
            .onChange(of: selectedBotID) { _, id in
                preferences.botID = id
                attachMatchingBotComputer()
            }
            .keyboardDismissToolbar()
        }
    }

    // MARK: Sections

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should Vamp Assistant do?")
                .font(.subheadline.weight(.semibold))
            TextField("Describe the task, or pick a suggestion below", text: $prompt, axis: .vertical)
                .lineLimit(4...9)
                .font(.body)
                .focused($promptFocused)
                .padding(14)
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                .accessibilityLabel("First prompt")
        }
    }

    private var setupCard: some View {
        VStack(spacing: 0) {
            RemoteStartSetupRow(
                icon: isChatOnly ? "bubble.left.and.bubble.right.fill" : "folder.fill",
                title: "Works in",
                value: locationValue,
                detail: locationDetail,
                action: { showWorkspacePicker = true })
            Divider().overlay(BeetTheme.line(appearance))
            RemoteStartSetupRow(
                icon: "person.crop.square.filled.and.at.rectangle",
                title: "Bot",
                value: botProfile.name,
                detail: botProfile.instruction == nil ? "Plain chat" : botProfile.subtitle,
                action: { showBotPicker = true })
            Divider().overlay(BeetTheme.line(appearance))
            RemoteStartSetupRow(
                icon: RemoteModelPickerSheet.sourceIcon(selectedModel?.source ?? selectedSource),
                title: "Model",
                value: selectedModel?.name ?? (isLoading ? "Loading…" : "Choose a model"),
                detail: selectedModel?.detail ?? "\(store.startModels.count) available",
                isPlaceholder: selectedModel == nil,
                action: { showModelPicker = true })
        }
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }

    private var moreOptionsButton: some View {
        Button { showAdvanced = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text("More options")
                if let effort = selectedReasoningEffort {
                    Text("· \(effort.capitalized) reasoning")
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(BeetTheme.secondaryText(appearance))
        .accessibilityHint("Reasoning effort, bot computers, and API keys")
    }

    private var startBar: some View {
        VStack(spacing: 8) {
            if let blockedReason {
                Text(blockedReason)
                    .font(.caption)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Button { start() } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().tint(.white) }
                    Label(isStarting ? "Starting…" : "Start session", systemImage: "arrow.up.circle.fill")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.55)
            .accessibilityHint(blockedReason ?? "")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(BeetTheme.background(appearance).opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(BeetTheme.line(appearance)).frame(height: 0.75)
        }
    }

    // MARK: Loading

    private func load() async {
        selectedBotID = initialBotID.isEmpty ? preferences.botID : initialBotID
        selectedSource = preferences.modelSource
        selectedWorkspacePath = preferences.workspacePath
        async let models: Void = store.loadStartModels()
        async let computers: Void = loadBotComputers()
        async let folders: Void = store.loadWorkspaces()
        _ = await (models, computers, folders)
        applyRememberedModel()
        selectedWorkspacePath = RemoteStartPreferences.resolveWorkspacePath(
            in: store.workspaces, rememberedPath: preferences.workspacePath)
        attachMatchingBotComputer()
        isLoading = false
        // Focus last: the field is the only thing left to fill in, and doing it
        // before the sheet settles loses the keyboard on slower connections.
        promptFocused = prompt.isEmpty
    }

    private func applyRememberedModel() {
        guard let model = RemoteStartPreferences.resolveModel(
            in: store.startModels,
            rememberedID: preferences.modelID,
            rememberedSource: preferences.modelSource) else { return }
        selectedModelID = model.id
        selectedSource = model.source
        selectedReasoningEffort = model.defaultReasoningEffort
    }

    private func loadBotComputers() async {
        guard let envelope = await store.botComputers() else { return }
        botComputers = envelope.computers
        if let selected = selectedBotComputerID,
           !envelope.computers.contains(where: { $0.id == selected && RemoteBotComputerNaming.canAttach($0) }) {
            selectedBotComputerID = nil
        }
    }

    /// A specialist that already has its own computer prepared should use it —
    /// but never at the cost of a folder the user picked on purpose.
    private func attachMatchingBotComputer() {
        guard selectedWorkspacePath.isEmpty,
              let profileID = RemoteBotProfile.resolvedID(selectedBotID),
              let match = botComputers.first(where: {
                  $0.profileID == profileID && RemoteBotComputerNaming.canAttach($0)
              }) else { return }
        selectedBotComputerID = match.id
    }

    // MARK: Start

    private func start() {
        isStarting = true
        store.reasoningEffort = selectedReasoningEffort
        store.sessionMode = isChatOnly ? .chat : .code
        if let selectedModel { preferences.remember(model: selectedModel) }
        preferences.botID = selectedBotID
        preferences.workspacePath = selectedWorkspacePath
        let firstMessage = trimmedPrompt
        let computerID = attachedComputer?.id
        Task {
            if let id = await store.startSession(
                modelID: selectedModelID,
                message: firstMessage,
                botProfileID: RemoteBotProfile.resolvedID(selectedBotID),
                botComputerID: computerID,
                workspacePath: computerID == nil && !selectedWorkspacePath.isEmpty
                    ? selectedWorkspacePath : nil,
                chatOnly: computerID == nil && selectedWorkspacePath.isEmpty) {
                onStarted(id)
            }
            isStarting = false
        }
    }
}
