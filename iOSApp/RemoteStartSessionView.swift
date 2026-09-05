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
        if selectedWorkspacePath.isEmpty { return nil }
        return selectedWorkspacePath
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                if !store.isConnected { reconnectSection }
                promptSection
                setupSection
                moreSection
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background { RemoteBackdrop() }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { startBar }
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
        }
    }

    // MARK: Sections

    private var reconnectSection: some View {
        Section {
            Button {
                Task { await store.connectSaved() }
            } label: {
                Label(store.isConnecting ? "Reconnecting…" : "Reconnect",
                      systemImage: "wifi.exclamationmark")
            }
            .disabled(store.isConnecting)
        } footer: {
            Text(store.connectionSubtitle)
        }
        .remoteListRow()
    }

    private var promptSection: some View {
        Section {
            TextField("Describe the task", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .focused($promptFocused)
                .accessibilityLabel("First prompt")
            if !botProfile.starters.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(botProfile.starters, id: \.self) { starter in
                            Button(starter) {
                                prompt = starter
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("Suggested tasks")
            }
        } header: {
            Text("Task")
        }
        .remoteListRow()
    }

    private var setupSection: some View {
        Section {
            RemoteDisclosureRow(
                title: "Works in",
                value: locationValue,
                detail: locationDetail,
                action: { showWorkspacePicker = true })
            RemoteDisclosureRow(
                title: "Bot",
                value: botProfile.name,
                action: { showBotPicker = true })
            RemoteDisclosureRow(
                title: "Model",
                value: selectedModel?.name ?? (isLoading ? "Loading…" : "Choose a model"),
                detail: selectedModel?.detail,
                action: { showModelPicker = true })
        } header: {
            Text("Setup")
        } footer: {
            Text("Starts with the folder, bot and model you used last.")
        }
        .remoteListRow()
    }

    @ViewBuilder
    private var moreSection: some View {
        Section {
            // Inline rather than behind another sheet: it is a short list of
            // named values, which is exactly what a menu picker is for.
            if let model = selectedModel, let efforts = model.reasoningEfforts, !efforts.isEmpty {
                Picker("Reasoning", selection: $selectedReasoningEffort) {
                    Text("Auto").tag(String?.none)
                    ForEach(efforts, id: \.self) { effort in
                        Text(effort.capitalized).tag(String?.some(effort))
                    }
                }
            }
            RemoteDisclosureRow(
                title: "Bot computers & API keys",
                action: { showAdvanced = true })
        } header: {
            Text("More")
        }
        .remoteListRow()
    }

    private var startBar: some View {
        VStack(spacing: 8) {
            if let blockedReason {
                Text(blockedReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().tint(.white) }
                    Text(isStarting ? "Starting…" : "Start session")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStart)
            .accessibilityHint(blockedReason ?? "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
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
