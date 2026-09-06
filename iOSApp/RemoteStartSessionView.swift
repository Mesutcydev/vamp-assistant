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
    /// SwiftUI honours ONE `sheet(isPresented:)` per view: with four stacked
    /// here, only the last modifier ever presented, so tapping Model, Works in
    /// or Bot did nothing. One `sheet(item:)` over an enum instead.
    @State private var sheet: StartSheet?

    enum StartSheet: String, Identifiable {
        case model, workspace, bot, advanced
        var id: String { rawValue }
    }

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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.isConnected { reconnectCard.padding(.bottom, 22) }
                    promptField
                    chipRow
                    startersList
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { RemoteBackdrop() }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { startBar }
            .sheet(item: $sheet) { which in
                switch which {
                case .model:
                    RemoteModelPickerSheet(
                        models: store.startModels,
                        source: $selectedSource,
                        selectedModelID: $selectedModelID,
                        onSelect: { model in
                            selectedReasoningEffort = model.defaultReasoningEffort
                            preferences.remember(model: model)
                        },
                        onRefresh: { await store.loadStartModels() },
                        isConnected: store.isConnected)
                        .environment(\.remoteAppearance, appearance)
                case .workspace:
                    RemoteWorkspacePickerSheet(
                        store: store,
                        selectedPath: $selectedWorkspacePath,
                        attachedComputerName: attachedComputer.map(RemoteBotComputerNaming.displayName))
                        .environment(\.remoteAppearance, appearance)
                case .bot:
                    RemoteBotPickerSheet(selectedBotID: $selectedBotID)
                        .environment(\.remoteAppearance, appearance)
                case .advanced:
                    RemoteStartAdvancedSheet(
                        store: store,
                        botComputers: $botComputers,
                        selectedBotComputerID: $selectedBotComputerID,
                        botProfile: botProfile,
                        reload: loadBotComputers)
                        .environment(\.remoteAppearance, appearance)
                }
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

    private var reconnectCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BeetTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected").font(.subheadline.weight(.semibold))
                Text(store.connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(store.isConnecting ? "Connecting…" : "Reconnect") {
                Task { await store.connectSaved() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BeetTheme.accent)
            .disabled(store.isConnecting)
        }
        .padding(14)
        .remoteCardSurface()
    }

    /// The screen is the question.
    ///
    /// This was a Form: a hero, a card with the field in it, a Setup section of
    /// three rows, a More section, and a full-width bar. Six containers for one
    /// sentence and three settings. The sentence is now the page — set in the
    /// size a title would be — the three settings are chips underneath it, and
    /// Start lives in the field's own row.
    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if prompt.isEmpty {
                Text("What should it work on?")
                    .font(.system(size: 27, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.32))
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            TextField("", text: $prompt, axis: .vertical)
                .font(.system(size: 27, weight: .regular))
                .lineLimit(1...6)
                .focused($promptFocused)
                .accessibilityLabel("First prompt")
        }
        .frame(minHeight: 84, alignment: .topLeading)
    }

    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                RemoteSettingChip(
                    title: locationValue,
                    icon: isChatOnly ? "bubble.left.and.bubble.right" : "folder") {
                        sheet = .workspace
                    }
                RemoteSettingChip(title: botProfile.name, icon: botProfile.symbol) {
                    sheet = .bot
                }
                RemoteSettingChip(
                    title: selectedModel?.name ?? (isLoading ? "Loading…" : "Choose a model"),
                    icon: "cpu") {
                        sheet = .model
                    }
                if let model = selectedModel, let efforts = model.reasoningEfforts, !efforts.isEmpty {
                    Menu {
                        Picker("Reasoning", selection: $selectedReasoningEffort) {
                            Text("Auto").tag(String?.none)
                            ForEach(efforts, id: \.self) { effort in
                                Text(effort.capitalized).tag(String?.some(effort))
                            }
                        }
                    } label: {
                        RemoteSettingChipLabel(
                            title: selectedReasoningEffort?.capitalized ?? "Auto",
                            icon: "brain")
                    }
                }
                RemoteSettingChip(title: "Sandboxes & keys", icon: "shippingbox") {
                    sheet = .advanced
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 20)
        .accessibilityLabel("Session setup")
    }

    @ViewBuilder
    private var startersList: some View {
        if prompt.isEmpty, !botProfile.starters.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Or start from")
                    .font(.caption.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(.primary.opacity(0.55))
                    .padding(.bottom, 6)
                ForEach(botProfile.starters, id: \.self) { starter in
                    Button {
                        prompt = starter
                        promptFocused = true
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 10) {
                            Text(starter)
                                .font(.body)
                                .foregroundStyle(.primary.opacity(0.72))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary.opacity(0.45))
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(RemoteSurface.separator(appearance))
                        .frame(height: 0.75)
                }
            }
            .padding(.top, 30)
        }
    }

    private var startBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(height: 0.75)
            HStack(alignment: .center, spacing: 12) {
                Text(blockedReason ?? "Return sends. This is where it begins.")
                    .font(.footnote)
                    .foregroundStyle(.primary.opacity(blockedReason == nil ? 0.45 : 0.7))
                    .lineLimit(2)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Button(action: start) {
                    HStack(spacing: 7) {
                        if isStarting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(isStarting ? "Starting" : "Start")
                            .font(.subheadline.weight(.semibold))
                        if !isStarting {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    // Drawn rather than .borderedProminent, whose disabled fill
                    // is white on a light sheet and near-black on a dark one.
                    .background(canStart ? AnyShapeStyle(BeetTheme.accent)
                                         : AnyShapeStyle(RemoteSurface.well(appearance)),
                                in: Capsule())
                    .foregroundStyle(canStart ? AnyShapeStyle(Color.white)
                                              : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .accessibilityLabel(isStarting ? "Starting" : "Start session")
                .accessibilityHint(blockedReason ?? "")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            // Opaque, in the app's own grey. `.bar` painted a white slab across
            // the bottom of a dark sheet and let the list show through it.
            .background(RemoteSurface.card(appearance))
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
