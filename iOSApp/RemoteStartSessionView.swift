import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StartSessionSheet: View {
    @Bindable var store: RemoteStore
    let initialBotID: String
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var source = "local"
    @State private var selectedModelID = ""
    @State private var selectedReasoningEffort: String?
    @State private var showModelPicker = false
    @State private var prompt = ""
    @State private var botComputers: [RemoteBotComputer] = []
    @State private var selectedBotComputerID: UUID?
    @State private var botComputerBusyID: UUID?
    @State private var consoleComputer: RemoteBotComputer?
    @State private var keyProviderID = "openAI"
    @State private var keyDraft = ""
    @State private var isSavingKey = false
    @State private var keyMessage: String?
    @State private var selectedBotID = ""
    @State private var isStarting = false
    @State private var selectedWorkspacePath = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var folderPathDraft = ""
    @State private var showPathEntry = false

    private var codeFolderMissing: Bool {
        store.sessionMode == .code
            && selectedBotComputerID == nil
            && (selectedWorkspacePath.isEmpty || !store.workspacesSupported)
    }

    private var canStart: Bool {
        store.isConnected
            && !selectedModelID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStarting
            && !codeFolderMissing
    }

    private var botProfile: RemoteBotProfile {
        RemoteBotProfile.profile(id: selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID)
    }
    private var models: [RemoteStartModelOption] { store.startModels.filter { $0.source == source } }
    private var groupedAPIModels: [(detail: String, models: [RemoteStartModelOption])] {
        let groups = Dictionary(grouping: models, by: \.detail)
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            (key, groups[key]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }
    private var sourceIcon: String {
        switch source {
        case "chatgpt": "person.crop.circle"
        case "api": "cloud"
        default: "cpu"
        }
    }
    private var emptyModelsTitle: String {
        switch source {
        case "chatgpt": "No ChatGPT models"
        case "api": "No API models"
        default: "No local models"
        }
    }
    private var emptyModelsDescription: String {
        switch source {
        case "chatgpt": "Sign in with ChatGPT on your Mac, then refresh."
        case "api": "Configure an API provider on your Mac first."
        default: "Download a model on your Mac first."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !store.isConnected {
                            RemoteReconnectBanner(store: store)
                        }
                        RemoteModeSwitcher(mode: $store.sessionMode)
                        Text(store.sessionMode == .chat
                             ? "Conversation only — no project folder on your Mac."
                             : "The agent stays inside one Mac folder.")
                            .font(.caption)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        if store.sessionMode == .code {
                            workspaceSection
                        }
                        Text(botProfile.instruction == nil
                             ? "Plain chat — no specialist instructions."
                             : "\(botProfile.name) will \(botProfile.subtitle.lowercased()).")
                            .font(.subheadline)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        RemoteBotChooser(selectedBotID: $selectedBotID)
                        RemoteBotStarters(
                            starters: botProfile.starters,
                            tint: botProfile.tint,
                            appearance: appearance,
                            prompt: $prompt)
                        Picker("Model source", selection: $source) {
                            ForEach(RemoteModelPickerSheet.sources, id: \.self) { option in
                                let count = store.startModels.filter { $0.source == option }.count
                                Text(count > 0
                                     ? "\(RemoteModelPickerSheet.sourceLabel(option)) \(count)"
                                     : RemoteModelPickerSheet.sourceLabel(option))
                                    .tag(option)
                            }
                        }.pickerStyle(.segmented)

                        botComputerSection

                        apiKeySection

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MODEL").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            if models.isEmpty {
                                ContentUnavailableView(emptyModelsTitle, systemImage: sourceIcon, description: Text(emptyModelsDescription))
                                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                            } else {
                                // A summary row into the searchable picker, not
                                // the whole catalog inline: a few hundred API
                                // models made this form scroll for minutes with
                                // no way to find a known name.
                                RemoteModelSummaryRow(
                                    models: store.startModels,
                                    selectedModelID: selectedModelID,
                                    action: { showModelPicker = true })
                            }
                        }

                        if let selected = models.first(where: { $0.id == selectedModelID }),
                           let efforts = selected.reasoningEfforts, !efforts.isEmpty {
                            RemoteReasoningSelector(
                                modelName: selected.name,
                                efforts: efforts,
                                defaultEffort: selected.defaultReasoningEffort,
                                selection: $selectedReasoningEffort)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIRST PROMPT").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            TextField("What should Vamp Assistant work on?", text: $prompt, axis: .vertical).lineLimit(3...8).padding(14)
                                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                        }
                        Button { start() } label: {
                            HStack { if isStarting { ProgressView().tint(.white) }; Label(isStarting ? "Starting…" : "Start session", systemImage: "arrow.up.circle.fill") }
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }.buttonStyle(RemotePrimaryButtonStyle()).disabled(!canStart)
                    }.padding(18)
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $consoleComputer) { computer in
                RemoteBotConsoleView(store: store, computer: computer)
            }
            .sheet(isPresented: $showModelPicker) {
                RemoteModelPickerSheet(
                    models: store.startModels,
                    source: $source,
                    selectedModelID: $selectedModelID,
                    onSelect: { selectedReasoningEffort = $0.defaultReasoningEffort },
                    onRefresh: { await store.loadStartModels() })
                    .environment(\.remoteAppearance, appearance)
            }
            .task {
                selectedBotID = initialBotID
                async let models: Void = store.loadStartModels()
                async let computers: Void = loadBotComputers()
                async let folders: Void = store.loadWorkspaces()
                _ = await (models, computers, folders)
                attachMatchingBotComputer()
                selectFirstModel()
                if selectedWorkspacePath.isEmpty {
                    selectedWorkspacePath = store.workspaces.first(where: { $0.isCurrent == true })?.path
                        ?? store.workspaces.first?.path
                        ?? ""
                }
            }
            .onChange(of: source) { _, _ in selectFirstModel() }
            .onChange(of: store.sessionMode) { _, mode in
                if mode == .chat { selectedBotComputerID = nil }
            }
            .onChange(of: selectedBotID) { _, _ in
                attachMatchingBotComputer()
            }
            .alert("New folder on Mac", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") { createFolder() }
            } message: {
                Text(store.workspaceCreateParent.map { "Created inside \($0)." } ?? "Created in the app’s Documents folder on your Mac.")
            }
            .alert("Open a folder path", isPresented: $showPathEntry) {
                TextField("~/Developer/my-app", text: $folderPathDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { folderPathDraft = "" }
                Button("Open") { openFolderPath() }
            } message: {
                Text("The folder must already exist inside your Mac home directory.")
            }
            .keyboardDismissToolbar()
        }
    }

    private func selectFirstModel() {
        let first = source == "api" ? groupedAPIModels.first?.models.first : models.first
        selectedModelID = first?.id ?? ""
        selectedReasoningEffort = first?.defaultReasoningEffort
    }

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROJECT FOLDER").font(.caption2.bold()).tracking(0.8)
                Spacer()
                if selectedBotComputerID != nil {
                    Text("Bot computer")
                        .font(.caption)
                }
            }.foregroundStyle(BeetTheme.secondaryText(appearance))
            if !store.workspacesSupported {
                Text("Update Vamp Assistant on your Mac to open or create a project folder from here.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            } else if selectedBotComputerID != nil {
                Text("This session uses the selected bot computer’s workspace and private browser.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            } else {
                if store.workspaces.isEmpty {
                    Text("No recent folders yet. Create one or open a path on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.workspaces) { folder in
                            Button {
                                selectedWorkspacePath = folder.path
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedWorkspacePath == folder.path ? "checkmark.circle.fill" : "folder.fill")
                                        .foregroundStyle(selectedWorkspacePath == folder.path ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.name).font(.body.weight(.semibold))
                                        Text(folder.path).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
                                    }
                                    Spacer()
                                }.padding(13).contentShape(Rectangle())
                                    .accessibilityAddTraits(selectedWorkspacePath == folder.path ? .isSelected : [])
                            }.buttonStyle(.plain)
                            if folder.path != store.workspaces.last?.path {
                                Divider().overlay(BeetTheme.line(appearance))
                            }
                        }
                    }
                    .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                }
                HStack(spacing: 10) {
                    Button { showNewFolder = true } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    Button { showPathEntry = true } label: {
                        Label("Path", systemImage: "text.alignleft")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                }
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            if let created = await store.createWorkspace(name: name) {
                selectedWorkspacePath = created.path
            }
        }
    }

    private func openFolderPath() {
        let path = folderPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        folderPathDraft = ""
        guard !path.isEmpty else { return }
        Task {
            if let opened = await store.openWorkspace(path: path) {
                selectedWorkspacePath = opened.path
            }
        }
    }

    @ViewBuilder
    private var botComputerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BOT COMPUTER").font(.caption2.bold()).tracking(0.8)
                Spacer()
                Text(botComputers.isEmpty
                     ? "None prepared on Mac"
                     : (selectedBotComputerID == nil ? "Optional — tap to attach" : "Attached"))
                    .font(.caption)
            }.foregroundStyle(BeetTheme.secondaryText(appearance))
            if !botComputers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(botComputers) { computer in
                        HStack(spacing: 11) {
                            Image(systemName: selectedBotComputerID == computer.id ? "checkmark.circle.fill" : "square.stack.3d.up.fill")
                                .foregroundStyle(selectedBotComputerID == computer.id ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(for: computer)).font(.body.weight(.semibold))
                                Text(botComputerSubtitle(computer))
                                    .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                            }
                            Spacer()
                            // A bot computer has no screen to stream; its console is the shell,
                            // the workspace, and the output.
                            Button {
                                consoleComputer = computer
                            } label: {
                                Image(systemName: "terminal")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Open \(displayName(for: computer)) console")
                            if computer.state == "running" {
                                Button(botComputerBusyID == computer.id ? "Stopping…" : "Stop") { stopBotComputer(computer) }
                                    .buttonStyle(.bordered)
                                    .disabled(botComputerBusyID != nil)
                            } else if computer.backend != "isolatedWorkspace" {
                                Button(botComputerBusyID == computer.id ? "Starting…" : "Start") { startBotComputer(computer) }
                                    .buttonStyle(.borderedProminent).tint(BeetTheme.accentBright)
                                    .disabled(botComputerBusyID != nil)
                            }
                        }
                        .padding(13)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canAttachBotComputer(computer) else { return }
                            selectedBotComputerID = selectedBotComputerID == computer.id ? nil : computer.id
                            if selectedBotComputerID != nil { store.sessionMode = .code }
                        }
                        if computer.id != botComputers.last?.id { Divider().overlay(BeetTheme.line(appearance)) }
                    }
                }
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
            }
            if let profileID = RemoteBotProfile.resolvedID(selectedBotID),
               !botComputers.contains(where: { $0.profileID == profileID }) {
                Button {
                    prepareBotComputer(profileID: profileID)
                } label: {
                    Label("Create \(botProfile.name) computer on Mac", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .disabled(botComputerBusyID != nil || !store.isConnected)
            } else if botComputers.isEmpty {
                Button {
                    prepareBotComputer(profileID: nil)
                } label: {
                    Label("Prepare bot computers on Mac", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .disabled(botComputerBusyID != nil || !store.isConnected)
            }
        }
    }

    private func displayName(for computer: RemoteBotComputer) -> String {
        computer.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Beet") == .orderedSame
            ? "Assistant computer"
            : computer.name
    }

    private func canAttachBotComputer(_ computer: RemoteBotComputer) -> Bool {
        computer.state == "running" || computer.backend == "isolatedWorkspace"
    }

    private func botComputerSubtitle(_ computer: RemoteBotComputer) -> String {
        let backend: String
        switch computer.backend {
        case "appleContainer": backend = "Linux micro-VM"
        case "isolatedWorkspace": backend = "Private workspace"
        default: backend = computer.backend
        }
        return computer.state.capitalized + " · " + backend + " · private browser"
    }

    private func attachMatchingBotComputer() {
        guard let profileID = RemoteBotProfile.resolvedID(selectedBotID) else { return }
        if let match = botComputers.first(where: { $0.profileID == profileID && canAttachBotComputer($0) }) {
            selectedBotComputerID = match.id
            store.sessionMode = .code
        }
    }

    private func prepareBotComputer(profileID: String?) {
        botComputerBusyID = UUID()
        Task {
            let computers = await store.prepareBotComputers(profileID: profileID)
            if !computers.isEmpty {
                botComputers = computers
                attachMatchingBotComputer()
            } else {
                await loadBotComputers()
            }
            botComputerBusyID = nil
        }
    }

    private func loadBotComputers() async {
        if let envelope = await store.botComputers() {
            botComputers = envelope.computers
            if let selected = selectedBotComputerID,
               !envelope.computers.contains(where: {
                   $0.id == selected && ($0.state == "running" || $0.backend == "isolatedWorkspace")
               }) {
                selectedBotComputerID = nil
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("API KEY").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
            HStack(spacing: 8) {
                Picker("Provider", selection: $keyProviderID) {
                    Text("OpenAI").tag("openAI")
                    Text("Gemini").tag("gemini")
                    Text("OpenRouter").tag("openRouter")
                    Text("Anthropic").tag("anthropic")
                    Text("DeepSeek").tag("deepSeek")
                    Text("OpenCode Zen").tag("openCode")
                    Text("OpenCode Go").tag("openCodeGo")
                }.pickerStyle(.menu)
                SecureField("Paste key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(isSavingKey ? "Saving…" : "Save") { saveAPIKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
            }
            if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Text("Stored securely in the Mac Keychain; the key is never saved on this device or in chat.")
                .font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance))
        }
    }

    private func saveAPIKey() {
        isSavingKey = true
        let key = keyDraft
        Task {
            let saved = await store.saveAPIKey(providerID: keyProviderID, key: key)
            if saved {
                keyDraft = ""
                source = "api"
                await store.loadStartModels()
                selectFirstModel()
                let count = store.startModels.filter { $0.source == "api" }.count
                keyMessage = count == 0
                    ? "Saved on Mac, but no models came back yet."
                    : "Saved. Loaded \(count) API models."
            } else {
                keyMessage = "Could not save the key."
            }
            isSavingKey = false
        }
    }

    private func startBotComputer(_ computer: RemoteBotComputer) {
        botComputerBusyID = computer.id
        Task {
            if await store.startBotComputer(computer.id) {
                await loadBotComputers()
                selectedBotComputerID = computer.id
                store.sessionMode = .code
            }
            botComputerBusyID = nil
        }
    }

    private func stopBotComputer(_ computer: RemoteBotComputer) {
        botComputerBusyID = computer.id
        Task {
            if await store.stopBotComputer(computer.id) {
                await loadBotComputers()
                if selectedBotComputerID == computer.id { selectedBotComputerID = nil }
            }
            botComputerBusyID = nil
        }
    }
    private func start() {
        isStarting = true
        store.reasoningEffort = selectedReasoningEffort
        let firstMessage = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = await store.startSession(
                modelID: selectedModelID,
                message: firstMessage,
                botProfileID: RemoteBotProfile.resolvedID(selectedBotID),
                botComputerID: selectedBotComputerID,
                workspacePath: store.sessionMode == .code && selectedBotComputerID == nil
                    ? selectedWorkspacePath : nil,
                chatOnly: store.sessionMode == .chat && selectedBotComputerID == nil) { onStarted(id) }
            isStarting = false
        }
    }
}
