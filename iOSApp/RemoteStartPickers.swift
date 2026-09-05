import SwiftUI
import UIKit

// MARK: - Shared summary row

/// One decision, one line: what it is, what it is currently set to, and a
/// chevron into the screen that changes it.
///
/// The new-session sheet used to render every one of those screens inline and
/// at full size, so the single required input — the prompt — sat below four
/// scrolls of controls that almost never change between sessions.
struct RemoteStartSetupRow: View {
    let icon: String
    let title: String
    let value: String
    var detail: String?
    var isPlaceholder = false
    let action: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isPlaceholder ? BeetTheme.secondaryText(appearance) : .primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityHint("Opens \(title.lowercased()) options")
    }
}

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
    @Environment(\.remoteAppearance) private var appearance
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var folderPathDraft = ""
    @State private var showPathEntry = false

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let attachedComputerName {
                            RemoteStartNotice(
                                icon: "square.stack.3d.up.fill",
                                text: "This session runs on \(attachedComputerName), which brings its own workspace and private browser.")
                        }
                        chatOnlyRow
                        if !store.workspacesSupported {
                            RemoteStartNotice(
                                icon: "arrow.up.circle",
                                text: "Update Vamp Assistant on your Mac to open or create a project folder from here.")
                        } else {
                            folderList
                            HStack(spacing: 10) {
                                Button { showNewFolder = true } label: {
                                    Label("New folder", systemImage: "folder.badge.plus")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                }
                                .buttonStyle(RemoteSecondaryButtonStyle())
                                Button { showPathEntry = true } label: {
                                    Label("Open path", systemImage: "text.alignleft")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                }
                                .buttonStyle(RemoteSecondaryButtonStyle())
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Where it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private var chatOnlyRow: some View {
        selectionRow(
            title: "Chat only",
            subtitle: "Conversation on your Mac — no project folder.",
            symbol: "bubble.left.and.bubble.right.fill",
            isSelected: selectedPath.isEmpty) {
                selectedPath = ""
                dismiss()
            }
            .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
    }

    @ViewBuilder
    private var folderList: some View {
        Text("PROJECT FOLDER")
            .font(.caption2.bold()).tracking(0.8)
            .foregroundStyle(BeetTheme.secondaryText(appearance))
        if store.workspaces.isEmpty {
            Text("No recent folders yet. Create one, or open a path that already exists on your Mac.")
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
        } else {
            VStack(spacing: 0) {
                ForEach(store.workspaces) { folder in
                    selectionRow(
                        title: folder.name,
                        subtitle: folder.path,
                        symbol: "folder.fill",
                        isSelected: selectedPath == folder.path) {
                            selectedPath = folder.path
                            dismiss()
                        }
                    if folder.path != store.workspaces.last?.path {
                        Divider().overlay(BeetTheme.line(appearance))
                    }
                }
            }
            .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
        }
    }

    private func selectionRow(
        title: String,
        subtitle: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(isSelected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
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
    @Environment(\.remoteAppearance) private var appearance

    private var effectiveID: String {
        selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(RemoteBotProfile.profiles) { profile in
                            row(profile)
                            if profile.id != RemoteBotProfile.profiles.last?.id {
                                Divider().overlay(BeetTheme.line(appearance))
                            }
                        }
                    }
                    .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
                    .padding(18)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ profile: RemoteBotProfile) -> some View {
        let isSelected = effectiveID == profile.id
        return Button {
            selectedBotID = RemoteBotProfile.resolvedID(profile.id) ?? ""
            UISelectionFeedbackGenerator().selectionChanged()
            dismiss()
        } label: {
            HStack(spacing: 13) {
                Image(profile.imageName)
                    .resizable()
                    .scaledToFit()
                    .saturation(0)
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.75) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.body.weight(.semibold))
                    Text(profile.instruction == nil ? "Plain chat — no specialist instructions." : profile.subtitle)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BeetTheme.accentBright)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Advanced

/// Everything that is setup rather than a per-session decision: how hard the
/// model should think, the bot computers prepared on the Mac, and API keys.
///
/// These used to sit in the middle of the start form, between the bot and the
/// prompt, so every session paid the cost of controls most sessions never touch.
struct RemoteStartAdvancedSheet: View {
    let store: RemoteStore
    @Binding var botComputers: [RemoteBotComputer]
    @Binding var selectedBotComputerID: UUID?
    @Binding var reasoningEffort: String?
    let model: RemoteStartModelOption?
    let botProfile: RemoteBotProfile
    /// MainActor-isolated on purpose: it is a method on the presenting view,
    /// and dropping the isolation on the way in is a Swift 6 conversion error.
    let reload: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var busyID: UUID?
    @State private var consoleComputer: RemoteBotComputer?
    @State private var keyProviderID = "openAI"
    @State private var keyDraft = ""
    @State private var isSavingKey = false
    @State private var keyMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let model, let efforts = model.reasoningEfforts, !efforts.isEmpty {
                            RemoteReasoningSelector(
                                modelName: model.name,
                                efforts: efforts,
                                defaultEffort: model.defaultReasoningEffort,
                                selection: $reasoningEffort)
                        }
                        botComputerSection
                        apiKeySection
                    }
                    .padding(18)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("More options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $consoleComputer) { computer in
                RemoteBotConsoleView(store: store, computer: computer)
            }
            .keyboardDismissToolbar()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var botComputerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("BOT COMPUTER").font(.caption2.bold()).tracking(0.8)
                Spacer()
                Text(botComputers.isEmpty
                     ? "None prepared on Mac"
                     : (selectedBotComputerID == nil ? "Optional — tap to attach" : "Attached"))
                    .font(.caption)
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            Text("A sandboxed machine on your Mac with its own workspace and private browser. Attach one and the session runs there instead of in a project folder.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if !botComputers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(botComputers) { computer in
                        computerRow(computer)
                        if computer.id != botComputers.last?.id {
                            Divider().overlay(BeetTheme.line(appearance))
                        }
                    }
                }
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
            }
            if let profileID = RemoteBotProfile.resolvedID(botProfile.id),
               !botComputers.contains(where: { $0.profileID == profileID }) {
                prepareButton(
                    title: "Create \(botProfile.name) computer on Mac",
                    profileID: profileID)
            } else if botComputers.isEmpty {
                prepareButton(title: "Prepare bot computers on Mac", profileID: nil)
            }
        }
    }

    private func computerRow(_ computer: RemoteBotComputer) -> some View {
        HStack(spacing: 11) {
            Image(systemName: selectedBotComputerID == computer.id
                  ? "checkmark.circle.fill" : "square.stack.3d.up.fill")
                .foregroundStyle(selectedBotComputerID == computer.id
                                 ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
            VStack(alignment: .leading, spacing: 3) {
                Text(RemoteBotComputerNaming.displayName(computer)).font(.body.weight(.semibold))
                Text(RemoteBotComputerNaming.subtitle(computer))
                    .font(.caption)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Spacer(minLength: 4)
            // A bot computer has no screen to stream; its console is the shell,
            // the workspace, and the output.
            Button { consoleComputer = computer } label: { Image(systemName: "terminal") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open \(RemoteBotComputerNaming.displayName(computer)) console")
            if computer.state == "running" {
                Button(busyID == computer.id ? "Stopping…" : "Stop") { stop(computer) }
                    .buttonStyle(.bordered)
                    .disabled(busyID != nil)
            } else if computer.backend != "isolatedWorkspace" {
                Button(busyID == computer.id ? "Starting…" : "Start") { start(computer) }
                    .buttonStyle(.borderedProminent).tint(BeetTheme.accentBright)
                    .disabled(busyID != nil)
            }
        }
        .padding(13)
        .contentShape(Rectangle())
        .onTapGesture {
            guard RemoteBotComputerNaming.canAttach(computer) else { return }
            selectedBotComputerID = selectedBotComputerID == computer.id ? nil : computer.id
        }
    }

    private func prepareButton(title: String, profileID: String?) -> some View {
        Button {
            busyID = UUID()
            Task {
                let computers = await store.prepareBotComputers(profileID: profileID)
                if computers.isEmpty { await reload() } else { botComputers = computers }
                busyID = nil
            }
        } label: {
            Label(title, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(RemoteSecondaryButtonStyle())
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
        VStack(alignment: .leading, spacing: 9) {
            Text("API KEY").font(.caption2.bold()).tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
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
            if let keyMessage {
                Text(keyMessage).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
            }
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

/// A quiet inline explanation. Used where a screen would otherwise just be
/// missing its controls with no word about why.
struct RemoteStartNotice: View {
    let icon: String
    let text: String
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(BeetTheme.accentBright)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) }
    }
}
