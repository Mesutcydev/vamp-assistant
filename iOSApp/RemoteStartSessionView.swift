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
    /// A starter tapped on a bot's page arrives here already typed.
    var initialPrompt: String = ""
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance

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
        // An empty field is not a blocker worth a sentence: the send button is
        // already dim, and the placeholder already asks the question.
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
                    if !store.isConnected { reconnectCard.padding(.bottom, 20) }
                    setupRow
                    startersList
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .remoteContentSheet()
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
                if let modelID = preferences.defaultModelID(forBot: botProfile.id),
                   let model = store.startModels.first(where: { $0.id == modelID }) {
                    selectedModelID = model.id
                    selectedSource = model.source
                    selectedReasoningEffort = model.defaultReasoningEffort
                }
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

    /// The four things a session is, as a row of cells rather than a rail of
    /// pills.
    ///
    /// The pills scrolled sideways, so the model — the one setting people
    /// actually change — sat half off the screen and the row read as a filter
    /// bar. This is the shape the home screen already uses for the Mac's
    /// actions: even cells on the ground between two hairlines, a glyph over
    /// what the setting is currently set to.
    private var setupRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(height: 0.75)
            HStack(spacing: 0) {
                setupCell(icon: isChatOnly ? "bubble.left.and.bubble.right" : "folder",
                          value: locationValue,
                          spoken: "Works in, \(locationValue)") { sheet = .workspace }
                setupCell(icon: botProfile.symbol,
                          value: botProfile.name,
                          spoken: "Bot, \(botProfile.name)") { sheet = .bot }
                setupCell(icon: "cpu",
                          value: shortModelName,
                          spoken: "Model, \(selectedModel?.name ?? "none chosen")") { sheet = .model }
                if let model = selectedModel, let efforts = model.reasoningEfforts, !efforts.isEmpty {
                    Menu {
                        Picker("Reasoning", selection: $selectedReasoningEffort) {
                            Text("Auto").tag(String?.none)
                            ForEach(efforts, id: \.self) { effort in
                                Text(effort.capitalized).tag(String?.some(effort))
                            }
                        }
                    } label: {
                        setupCellLabel(icon: "brain",
                                       value: selectedReasoningEffort?.capitalized ?? "Auto")
                    }
                    .accessibilityLabel("Reasoning, \(selectedReasoningEffort?.capitalized ?? "Auto")")
                } else {
                    setupCell(icon: "shippingbox",
                              value: "Keys",
                              spoken: "Sandboxes and keys") { sheet = .advanced }
                }
            }
            .frame(height: 64)
            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(height: 0.75)
        }
        .padding(.top, 22)
        .accessibilityLabel("Session setup")
    }

    private func setupCell(icon: String,
                           value: String,
                           spoken: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            setupCellLabel(icon: icon, value: value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
    }

    private func setupCellLabel(icon: String, value: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(height: 22)
            Text(value)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// Model names run long ("Qwen3.5 9B Abliterated MLX 4bit"); a cell shows
    /// the part that identifies it.
    private var shortModelName: String {
        guard let name = selectedModel?.name else { return isLoading ? "Loading" : "Choose" }
        return name.split(separator: " ").prefix(2).joined(separator: " ")
    }

    @ViewBuilder
    private var startersList: some View {
        if prompt.isEmpty, !botProfile.starters.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Or start from".uppercased())
                    .remoteSectionHeadingStyle()
                    .padding(.bottom, 6)
                ForEach(botProfile.starters, id: \.self) { starter in
                    Button {
                        // Tapping a starter fills the composer rather than
                        // starting immediately: it is a first draft, not a
                        // command.
                        prompt = starter
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
                                .foregroundStyle(RemoteInk.quiet)
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

    /// The chat's own composer, so the first message of a session is typed
    /// where every message after it will be.
    ///
    /// This screen used to have a bar of its own — a hint line and a capsule
    /// labelled Start — which meant the app had two input bars that looked
    /// nothing alike, and the one you met first was the odd one.
    private var startBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(height: 0.75)
            if let blockedReason {
                Text(blockedReason)
                    .font(.footnote)
                    .foregroundStyle(.primary.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(RemoteSurface.card(appearance))
                    .accessibilityHidden(true)
            }
            RemoteComposer(
                draft: $prompt,
                isRunning: false,
                isReachable: store.isConnected,
                isSending: isStarting,
                showsCommands: false,
                sendLabel: isStarting ? "Starting" : "Start session",
                placeholderOverride: "What should it work on?",
                onSend: start)
        }
    }

    // MARK: Loading

    private func load() async {
        selectedBotID = initialBotID.isEmpty ? preferences.botID : initialBotID
        if prompt.isEmpty { prompt = initialPrompt }
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

    }

    private func applyRememberedModel() {
        // A bot's own default wins over the last-used model: a reviewer and a
        // builder want different models, and re-picking on every switch was
        // the whole reason the default exists.
        let botDefault = preferences.defaultModelID(forBot: botProfile.id)
        guard let model = RemoteStartPreferences.resolveModel(
            in: store.startModels,
            rememberedID: botDefault ?? preferences.modelID,
            rememberedSource: preferences.defaultModelSource(forBot: botProfile.id)
                ?? preferences.modelSource) else { return }
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
