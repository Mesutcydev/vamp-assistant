import SwiftUI
import UIKit

// MARK: - Where the session runs

/// Chat-or-folder as a single question.
///
/// Mode and folder used to be two separate controls that could disagree: Code
/// mode with no folder picked left Start disabled with no explanation. Picking
/// "Chat only" or a folder here answers both at once, so the invalid
/// combination no longer exists.
struct RemoteWorkspacePickerSheet: View {
    let store: RemoteStore
    @Binding var selectedPath: String
    /// Set when a bot computer is attached: it brings its own workspace, so
    /// this whole screen is read-only in that case rather than silently ignored.
    let attachedComputerName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var folderPathDraft = ""
    @State private var showPathEntry = false

    var body: some View {
        NavigationStack {
            List {
                if let attachedComputerName {
                    Section {
                        Text("This session runs on \(attachedComputerName), which brings its own workspace and private browser.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .remoteListRow()
                }

                Section {
                    RemoteSelectionRow(
                        title: "Chat only",
                        subtitle: "Conversation on your Mac — no project folder.",
                        isSelected: selectedPath.isEmpty) {
                            selectedPath = ""
                            dismiss()
                        }
                }
                .remoteListRow()

                if store.workspacesSupported {
                    Section {
                        ForEach(store.workspaces) { folder in
                            RemoteSelectionRow(
                                title: folder.name,
                                subtitle: folder.path,
                                isSelected: selectedPath == folder.path) {
                                    selectedPath = folder.path
                                    dismiss()
                                }
                        }
                    } header: {
                        Text("Project folder")
                    } footer: {
                        if store.workspaces.isEmpty {
                            Text("No recent folders yet. Create one, or open a path that already exists on your Mac.")
                        }
                    }
                    .remoteListRow()

                    Section {
                        Button("New folder", systemImage: "folder.badge.plus") { showNewFolder = true }
                        Button("Open a path", systemImage: "text.alignleft") { showPathEntry = true }
                    }
                    .remoteListRow()
                } else {
                    Section {
                        Text("Update Vamp Assistant on your Mac to open or create a project folder from here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .remoteListRow()
                }
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .navigationTitle("Where it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("New folder on Mac", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") { createFolder() }
            } message: {
                Text(store.workspaceCreateParent.map { "Created inside \($0)." }
                     ?? "Created in the app’s Documents folder on your Mac.")
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
            .task { await store.loadWorkspaces() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            if let created = await store.createWorkspace(name: name) {
                selectedPath = created.path
                dismiss()
            }
        }
    }

    private func openFolderPath() {
        let path = folderPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        folderPathDraft = ""
        guard !path.isEmpty else { return }
        Task {
            if let opened = await store.openWorkspace(path: path) {
                selectedPath = opened.path
                dismiss()
            }
        }
    }
}

// MARK: - Bot

/// The bot list, with each bot's job spelled out. The old horizontal strip of
/// portraits showed five near-identical circles and the name only — what a bot
/// actually does was one line of prose somewhere above it.
struct RemoteBotPickerSheet: View {
    @Binding var selectedBotID: String
    @Environment(\.dismiss) private var dismiss

    private var effectiveID: String {
        selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        RemoteSelectionRow(
                            title: profile.name,
                            subtitle: profile.instruction == nil
                                ? "Plain chat — no specialist instructions."
                                : profile.subtitle,
                            isSelected: effectiveID == profile.id) {
                                selectedBotID = RemoteBotProfile.resolvedID(profile.id) ?? ""
                                UISelectionFeedbackGenerator().selectionChanged()
                                dismiss()
                            }
                    }
                }
                .remoteListRow()
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .navigationTitle("Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Advanced

/// Setup rather than a per-session decision: the bot computers prepared on the
/// Mac, and API keys. These used to sit in the middle of the start form, so
/// every session paid the cost of controls most sessions never touch.
struct RemoteStartAdvancedSheet: View {
    let store: RemoteStore
    @Binding var botComputers: [RemoteBotComputer]
    @Binding var selectedBotComputerID: UUID?
    let botProfile: RemoteBotProfile
    /// MainActor-isolated on purpose: it is a method on the presenting view,
    /// and dropping the isolation on the way in is a Swift 6 conversion error.
    let reload: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busyID: UUID?
    @State private var consoleComputer: RemoteBotComputer?
    @State private var keyProviderID = "openAI"
    @State private var keyDraft = ""
    @State private var isSavingKey = false
    @State private var keyMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                botComputerSection
                apiKeySection
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background { RemoteBackdrop() }
            .navigationTitle("Bot computers & keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $consoleComputer) { computer in
                RemoteBotConsoleView(store: store, computer: computer)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var botComputerSection: some View {
        Section {
            ForEach(botComputers) { computer in
                computerRow(computer)
            }
            if let profileID = RemoteBotProfile.resolvedID(botProfile.id),
               !botComputers.contains(where: { $0.profileID == profileID }) {
                prepareButton(title: "Create \(botProfile.name) computer", profileID: profileID)
            } else if botComputers.isEmpty {
                prepareButton(title: "Prepare bot computers", profileID: nil)
            }
        } header: {
            Text("Bot computer")
        } footer: {
            Text("A sandboxed machine on your Mac with its own workspace and private browser. Attach one and the session runs there instead of in a project folder.")
        }
        .remoteListRow()
    }

    private func computerRow(_ computer: RemoteBotComputer) -> some View {
        // Every button here is `.borderless`: a List row routes taps to the
        // first Button in it unless each one opts out, which would have made
        // Start, Stop and the console glyph all select the row instead.
        HStack(spacing: 10) {
            RemoteSelectionRow(
                title: RemoteBotComputerNaming.displayName(computer),
                subtitle: RemoteBotComputerNaming.subtitle(computer),
                isSelected: selectedBotComputerID == computer.id) {
                    guard RemoteBotComputerNaming.canAttach(computer) else { return }
                    selectedBotComputerID = selectedBotComputerID == computer.id ? nil : computer.id
                }
                .buttonStyle(.borderless)
            // A bot computer has no screen to stream; its console is the shell,
            // the workspace, and the output.
            Button { consoleComputer = computer } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(RemoteBotComputerNaming.displayName(computer)) console")
            if computer.state == "running" {
                Button(busyID == computer.id ? "Stopping…" : "Stop") { stop(computer) }
                    .buttonStyle(.borderless)
                    .disabled(busyID != nil)
            } else if computer.backend != "isolatedWorkspace" {
                Button(busyID == computer.id ? "Starting…" : "Start") { start(computer) }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(busyID != nil)
            }
        }
    }

    private func prepareButton(title: String, profileID: String?) -> some View {
        Button(title, systemImage: "plus") {
            busyID = UUID()
            Task {
                let computers = await store.prepareBotComputers(profileID: profileID)
                if computers.isEmpty { await reload() } else { botComputers = computers }
                busyID = nil
            }
        }
        .disabled(busyID != nil || !store.isConnected)
    }

    private func start(_ computer: RemoteBotComputer) {
        busyID = computer.id
        Task {
            if await store.startBotComputer(computer.id) {
                await reload()
                selectedBotComputerID = computer.id
            }
            busyID = nil
        }
    }

    private func stop(_ computer: RemoteBotComputer) {
        busyID = computer.id
        Task {
            if await store.stopBotComputer(computer.id) {
                await reload()
                if selectedBotComputerID == computer.id { selectedBotComputerID = nil }
            }
            busyID = nil
        }
    }

    private var apiKeySection: some View {
        Section {
            Picker("Provider", selection: $keyProviderID) {
                Text("OpenAI").tag("openAI")
                Text("Gemini").tag("gemini")
                Text("OpenRouter").tag("openRouter")
                Text("Anthropic").tag("anthropic")
                Text("DeepSeek").tag("deepSeek")
                Text("OpenCode Zen").tag("openCode")
                Text("OpenCode Go").tag("openCodeGo")
            }
            SecureField("Paste key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(isSavingKey ? "Saving…" : "Save key") { saveAPIKey() }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
            if let keyMessage {
                Text(keyMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("API key")
        } footer: {
            Text("Stored securely in the Mac Keychain; the key is never saved on this device or in chat.")
        }
        .remoteListRow()
    }

    private func saveAPIKey() {
        isSavingKey = true
        let key = keyDraft
        Task {
            let saved = await store.saveAPIKey(providerID: keyProviderID, key: key)
            if saved {
                keyDraft = ""
                await store.loadStartModels()
                let count = store.startModels.filter { $0.source == "api" }.count
                keyMessage = count == 0
                    ? "Saved on Mac, but no models came back yet."
                    : "Saved. Loaded \(count) API models — pick one from Model."
            } else {
                keyMessage = "Could not save the key."
            }
            isSavingKey = false
        }
    }
}

/// Naming shared by the advanced sheet and the start sheet's summary row, so
/// an attached computer reads the same in both places.
enum RemoteBotComputerNaming {
    static func displayName(_ computer: RemoteBotComputer) -> String {
        computer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Beet") == .orderedSame
            ? "Assistant computer"
            : computer.name
    }

    static func canAttach(_ computer: RemoteBotComputer) -> Bool {
        computer.state == "running" || computer.backend == "isolatedWorkspace"
    }

    static func subtitle(_ computer: RemoteBotComputer) -> String {
        let backend: String
        switch computer.backend {
        case "appleContainer": backend = "Linux micro-VM"
        case "isolatedWorkspace": backend = "Private workspace"
        default: backend = computer.backend
        }
        return computer.state.capitalized + " · " + backend + " · private browser"
    }
}
