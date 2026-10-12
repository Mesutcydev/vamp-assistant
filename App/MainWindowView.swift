import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Writes a passphrase-protected task handoff. This helper is shared by the
/// active-chat menu and sidebar row context menus so every export follows the
/// same redaction, encryption, and file-picker contract.
@MainActor
func exportTaskBundleFile(for record: SessionRecord) {
    guard let passphrase = TaskBundlePassphrasePrompt.ask(forExport: true) else { return }

    let panel = NSSavePanel()
    panel.title = "Export Task Bundle"
    panel.prompt = "Export"
    panel.nameFieldStringValue = SessionExporter
        .suggestedName(for: record, format: .json)
        .replacingOccurrences(of: ".json", with: ".beetask")
    panel.allowedContentTypes = [UTType(filenameExtension: "beetask") ?? .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
        let data = try TaskBundleCodec.encode(TaskBundle.make(from: record), passphrase: passphrase)
        try data.write(to: url, options: .atomic)
    } catch {
        let alert = NSAlert()
        alert.messageText = "Task bundle export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
enum SidebarHistoryTab { case sessions, imported }

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = SettingsStore.shared
    @SceneStorage("workspace.window-id") private var windowID = UUID().uuidString
    @State private var destination: ShellDestination = .conversations
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarAutoCollapsed = false
    @State private var conversationTitle = "New chat"
    @State private var historySearch = ""
    @State private var searchFocusRevision = 0
    @State private var settingsModelsSection: ModelsAndProvidersTab.Section = .library
    @State private var showRemoteAccessConsent = false
    @State private var showReadiness = false
    @State private var readinessIsOnboarding = false
    @State private var showCommandPalette = false
    @State private var designPreview = DesignPreviewScreen.fromLaunchArguments()
    @State private var composerStore = ComposerStore()
    @State private var resources = WorkspaceResources()
    @State private var dock = WorkspaceDock(defaults: AppState.isTestHost || DesignPreviewScreen.fromLaunchArguments() != nil ? nil : .standard)

    private var remoteAccessBinding: Binding<Bool> {
        Binding(get: { destination == .devices }, set: { if $0 { requestRemoteAccess() } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ShellSidebar(destination: $destination,
                         historySearch: $historySearch,
                         searchFocusRevision: searchFocusRevision,
                         showRemoteAccess: remoteAccessBinding,
                         onSettings: { destination = .settings(.general) },
                         onOpenInNewWindow: { openWindow(id: "chat", value: $0) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            destinationContent
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.workspaceCanvas)
        .navigationTitle(windowTitle)
        .navigationSubtitle(workspaceSubtitle)
        .toolbar {
            // NavigationSplitView owns the single native sidebar toggle.
            ToolbarItem(id: "workspace-palette", placement: .primaryAction) {
                Button { showCommandPalette = true } label: {
                    Label("Command palette", systemImage: "magnifyingglass")
                }
                .help("Command palette (⌘K)")
                .accessibilityIdentifier("command-palette-toggle")
            }
            ToolbarItem(id: "workspace-new", placement: .primaryAction) {
                Button(action: newConversation) { Label("New chat", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("new-conversation")
                    .help("New chat (⌘N)")
            }
            ToolbarItem(id: "workspace-panels", placement: .primaryAction) {
                Menu {
                    ForEach([WorkspacePanel.browser, .changes, .simulator, .activity, .context, .diagnostics, .session]) { panel in
                        Button { openPanel(panel) } label: { Label(panel.title, systemImage: panel.symbol) }
                            .disabled(panel.needsProject && sessions.workspaceURL == nil)
                    }
                    Divider()
                    Button("Reset layout") { dock.reset() }
                } label: { Label("Panels", systemImage: "rectangle.split.2x1") }
                .help("Open a tool or arrange your workspace")
                .accessibilityIdentifier("workspace-panels")
            }
            ToolbarItem(id: "workspace-more", placement: .primaryAction) { moreActionsMenu }
        }
        .focusedSceneValue(\.workspaceActions, actions)
        .sheet(isPresented: $showCommandPalette) {
            WorkspaceCommandPalette(actions: actions, onClose: { showCommandPalette = false })
                .environmentObject(appState)
        }
        .sheet(isPresented: $showRemoteAccessConsent) {
            RemoteAccessConsentView(onCancel: { showRemoteAccessConsent = false }, onAllow: { clipboard, files in
                settings.remoteAccessConsentCompleted = true
                settings.remoteClipboardSharingEnabled = clipboard
                settings.remoteFileSharingEnabled = files
                settings.remoteSessionEnabled = true
                showRemoteAccessConsent = false
                destination = .devices
            })
        }
        .sheet(isPresented: $showReadiness) {
            WelcomeReadinessView(isOnboarding: readinessIsOnboarding,
                onOpenWorkspace: { completeWelcome(); showReadiness = false; chooseWorkspace() },
                onOpenModelManager: { completeWelcome(); showReadiness = false; openModelsSettings() },
                onComplete: completeWelcome)
                .environmentObject(appState)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width < 760, sidebarVisibility != .detailOnly {
                sidebarAutoCollapsed = true
                sidebarVisibility = .detailOnly
            } else if width >= 900, sidebarAutoCollapsed {
                sidebarAutoCollapsed = false
                sidebarVisibility = .all
            }
        }
        .onChange(of: sessions.workspaceURL) { _, workspace in
            dock.bind(windowID: windowID, workspace: workspace?.standardizedFileURL.path ?? "assistant")
        }
        .onChange(of: dock.panels) { old, new in
            appState.isSimulatorPanelOpen = new.contains(.simulator)
            if old.contains(.simulator), !new.contains(.simulator) { resources.simulator.stopStreaming() }
        }
        .task(id: sessions.activeSessionID) {
            let id = sessions.activeSessionID
            let title = await Task.detached(priority: .utility) {
                id.flatMap { SessionStore.shared.load(id: $0) }.map { SessionTitle.display(for: $0) } ?? "New chat"
            }.value
            if !Task.isCancelled { conversationTitle = title }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionTitleChanged)) { note in
            if note.object as? UUID == sessions.activeSessionID, let title = note.userInfo?["title"] as? String { conversationTitle = title }
        }
        .onReceive(appNotifications, perform: handleAppNotification)
        .onReceive(NotificationCenter.default.publisher(for: .focusChatSearch)) { _ in focusSearch() }
        .onAppear {
            composerStore.configureWindow(windowID)
            composerStore.attach(controller: sessions, appState: appState)
            dock.bind(windowID: windowID, workspace: sessions.workspaceURL?.standardizedFileURL.path ?? "assistant")
            applyDesignPreview()
            presentWelcomeIfNeeded()
        }
        .onDisappear { dock.flush(); composerStore.flushDraft() }
        .environment(\.workspaceWindowID, windowID)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .conversations:
            WorkspaceDockView(dock: dock, content: panelContent)
        case .devices:
            RemoteAccessView(presentedAsSheet: false)
        case .settings(let section):
            SettingsView(initialTab: section, initialModelsSection: settingsModelsSection,
                         embedded: true, onSelect: { destination = .settings($0) }, onClose: { destination = .conversations })
                .id(section)
        }
    }

    private func panelContent(_ panel: WorkspacePanel) -> AnyView {
        switch panel {
        case .conversation:
            return AnyView(ChatView(controller: sessions, store: composerStore))
        case .browser:
            return AnyView(BrowserPanelView())
        case .simulator:
            return AnyView(SimulatorPanelView(controller: resources.simulator))
        case .changes:
            if let workspace = sessions.workspaceURL {
                return AnyView(WorkspaceChangesPane(model: resources.review(for: workspace)))
            }
        case .diagnostics:
            return AnyView(DiagnosticsPanelView())
        case .session:
            return AnyView(ShellInspector())
        case .context:
            if let workspace = sessions.workspaceURL {
                return AnyView(WorkspaceContextPane(workspace: workspace))
            }
        case .activity:
            return AnyView(DelegatedWorkList(onOpen: openPanel))
        case .specialist(let id):
            return AnyView(SpecialistRunDetail(runID: id, onOpen: openPanel))
        case .runChanges(_, let path):
            return AnyView(WorkspaceChangesPane(model: resources.review(for: URL(fileURLWithPath: path))))
        case .specialistBrowser(let id):
            let legacyRun = appState.botRuns.record(id)
            if let computer = appState.botComputers.computers.first(where: {
                $0.id == id || $0.profileID == legacyRun?.profileID
            }) {
                let controller = BrowserController.controller(for: BrowserSession(id: computer.id, name: computer.name))
                return AnyView(BrowserPanelView(controller: controller))
            }
        }
        return AnyView(ContentUnavailableView("Open a project", systemImage: "folder",
                       description: Text("Choose a project folder to use this panel.")))
    }

    private func openPanel(_ panel: WorkspacePanel) {
        guard !panel.needsProject || sessions.workspaceURL != nil else { chooseWorkspace(); return }
        destination = .conversations
        dock.open(panel)
    }

    private var actions: WorkspaceActions {
        WorkspaceActions(newChat: newConversation, openProject: chooseWorkspace,
            settings: { destination = .settings(.general) }, models: openModelsSettings,
            devices: requestRemoteAccess, search: focusSearch,
            palette: { showCommandPalette = true }, openPanel: openPanel,
            resetLayout: { dock.reset() },
            send: { _ = composerStore.submit() }, stop: sessions.stop,
            togglePlan: { settings.planMode.toggle() },
            canSend: composerStore.canSend || composerStore.canQueue,
            isRunning: sessions.isRunning, hasProject: sessions.workspaceURL != nil,
            activePaneTitle: dock.focusedPanel.title,
            canSplitPane: (dock.group(containing: dock.focusedPanel)?.tabs.count ?? 0) > 1,
            paneGroups: dock.root.groups.filter { $0.id != dock.group(containing: dock.focusedPanel)?.id },
            splitPane: { placement in
                if let group = dock.group(containing: dock.focusedPanel) { _ = dock.move(dock.focusedPanel, to: group.id, placement: placement) }
            }, joinGroup: { _ = dock.move(dock.focusedPanel, to: $0, placement: .center) })
    }

    private func newConversation() {
        composerStore.beginNewConversation()
        destination = .conversations
        if sessions.workspaceURL != nil { sessions.newSession() }
        else { Task { await sessions.switchToChatOnly() } }
        dock.select(.conversation)
    }

    private func focusSearch() {
        destination = .conversations
        sidebarVisibility = .all
        searchFocusRevision += 1
    }

    private var windowTitle: String {
        switch destination {
        case .devices: return "Devices"
        case .settings(let section): return section.rawValue
        case .conversations: return conversationTitle
        }
    }
    private var workspaceSubtitle: String {
        sessions.workspaceURL.map { "Code · \($0.lastPathComponent)" } ?? "Vamp Assistant"
    }

    private var moreActionsMenu: some View {
        Menu {
            Button("Open project…", systemImage: "folder") { chooseWorkspace() }
            Button("Models & connections…", systemImage: "cpu") { openModelsSettings() }
            Divider()
            Button("Git status", systemImage: "circle.dashed") { sessions.gitStatus() }.disabled(sessions.workspaceURL == nil)
            Button("Undo last checkpoint", systemImage: "arrow.uturn.backward") { sessions.undoLastCheckpoint() }.disabled(sessions.workspaceURL == nil)
            Divider()
            Button("Import chats…") { importExternalHistory() }
            Button("Import task bundle…") { importTaskBundle() }
            Button("Export chat as Markdown…") { exportCurrentChat(format: .markdown) }
            Button("Export chat as JSON…") { exportCurrentChat(format: .json) }
            Button("Export task bundle…") { exportCurrentTaskBundle() }
        } label: { Label("More app actions", systemImage: "ellipsis") }
        .accessibilityIdentifier("workspace-more")
    }

    private var appNotifications: AnyPublisher<Notification, Never> {
        Publishers.MergeMany([
            .openModelManager, .openWorkspace, .openSystemReadiness, .openRemoteAccess,
            .openBrowserPanel, .openBotsDashboard, .openAssistantHome, .openAppSettings, .openProviderSettings,
            .toggleBrowserPanel, .toggleSimulatorPanel, .toggleDiagnosticsPanel,
            .gitStatus, .gitDiff, .undoCheckpoint, .exportChatMarkdown, .exportChatJSON,
            .exportTaskBundle, .newChat, .stopAgent, .openSessionRecord, .importChats, .importBundle,
            .openWorkspacePanel,
        ].map { NotificationCenter.default.publisher(for: $0) }).eraseToAnyPublisher()
    }
    private func handleAppNotification(_ notification: Notification) {
        if let target = notification.userInfo?["workspaceWindowID"] as? String, target != windowID { return }
        switch notification.name {
        case .openWorkspacePanel:
            if let panel = notification.object as? WorkspacePanel { openPanel(panel) }
        case .openModelManager: openModelsSettings()
        case .openProviderSettings: settingsModelsSection = .providers; destination = .settings(.models)
        case .openWorkspace: chooseWorkspace()
        case .openSystemReadiness: readinessIsOnboarding = false; showReadiness = true
        case .openRemoteAccess: requestRemoteAccess()
        case .openBrowserPanel:
            if let controller = notification.object as? BrowserController, let browser = controller.resourceSession {
                dock.open(.specialistBrowser(browser.id), activate: false)
            } else { dock.open(.browser, activate: false) }
        case .openBotsDashboard: openPanel(.activity)
        case .openAssistantHome: destination = .conversations; dock.select(.conversation)
        case .openAppSettings: destination = .settings(.general)
        case .toggleBrowserPanel: togglePanel(.browser)
        case .toggleSimulatorPanel: togglePanel(.simulator)
        case .toggleDiagnosticsPanel: togglePanel(.diagnostics)
        case .gitStatus: sessions.gitStatus()
        case .gitDiff: openPanel(.changes)
        case .undoCheckpoint: sessions.undoLastCheckpoint()
        case .exportChatMarkdown: exportCurrentChat(format: .markdown)
        case .exportChatJSON: exportCurrentChat(format: .json)
        case .exportTaskBundle: exportCurrentTaskBundle()
        case .newChat: newConversation()
        case .stopAgent: sessions.stop()
        case .importChats: importExternalHistory()
        case .importBundle: importTaskBundle()
        case .openSessionRecord:
            guard let id = notification.object as? UUID else { return }
            Task {
                let record = await Task.detached(priority: .utility) { SessionStore.shared.load(id: id) }.value
                if let record { openRecord(record) }
            }
        default: break
        }
    }
    private func togglePanel(_ panel: WorkspacePanel) {
        if dock.contains(panel) { dock.close(panel) } else { openPanel(panel) }
    }
    private func openModelsSettings() { settingsModelsSection = .library; destination = .settings(.models) }
    private func requestRemoteAccess() { destination = .devices }
    private func presentWelcomeIfNeeded() {
        guard !AppState.isTestHost, !AppPreferencesStore.shared.current.hasCompletedWelcome else { return }
        readinessIsOnboarding = true
        showReadiness = true
    }
    private func installDelegationPreview() {
        DesignPreview.install(.chat, into: sessions)
        appState.botRuns.installDesignPreview(originatingSessionID: sessions.activeSessionID)
    }

    private func applyDesignPreview() {
        guard let screen = designPreview else { return }
        designPreview = nil
        Instrument.debugFrameReport = true
        // Column states for capture runs: the shell's two optional columns
        // cannot be reached from a launch argument otherwise.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--design-inspector") { dock.open(.session) }
        if args.contains("--design-sidebar-collapsed") { sidebarVisibility = .detailOnly }
        DispatchQueue.main.async {
            // Design captures must not inherit a restored in-app destination.
            // Reset every mutually exclusive workspace before selecting the
            // requested fixture so the screenshot always shows the argument
            // that launched this exact binary.
            destination = .conversations
            if let window = NSApplication.shared.windows.first {
                var width: CGFloat = 1240
                var height: CGFloat = 840
                if let i = args.firstIndex(of: "--design-size"),
                   args.indices.contains(i + 1) {
                    let parts = args[i + 1].split(separator: "x")
                    if parts.count == 2,
                       let w = Double(parts[0]), let h = Double(parts[1]) {
                        width = CGFloat(w)
                        height = CGFloat(h)
                    }
                }
                if let screen = window.screen ?? NSScreen.main {
                    let available = screen.visibleFrame
                    let content = window.contentRect(forFrameRect: available)
                    width = min(width, max(520, content.width - 16))
                    height = min(height, max(640, content.height - 16))
                }
                window.setContentSize(NSSize(width: width, height: height))
                window.center()
            }
            switch screen {
            case .chat:
                DesignPreview.install(.chat, into: sessions)
            case .composer, .approvals:
                // The hardware composer fixture is gone with the instrument
                // chassis; the composer now lives in the real chat route.
                DesignPreview.install(.chat, into: sessions)
            case .welcome:
                break
            case .docking:
                DesignPreview.install(.chat, into: sessions)
                dock.open(.browser)
                dock.open(.diagnostics)
                if let group = dock.group(containing: .browser) {
                    _ = dock.move(.diagnostics, to: group.id, placement: .bottom)
                }
            case .devices:
                destination = .devices
            case .delegation:
                installDelegationPreview()
            case .settingsGeneral:
                destination = .settings(.general)
            case .settingsModels:
                settingsModelsSection = .library
                destination = .settings(.models)
            case .settingsBots:
                destination = .settings(.advanced)
            case .settingsAgent:
                destination = .settings(.agent)
            case .settingsNetwork:
                destination = .settings(.advanced)
            case .settingsPlugins:
                destination = .settings(.plugins)
            case .settingsHover:
                destination = .settings(.general)
            case .settingsFocus:
                destination = .settings(.general)
            case .botsDashboard:
                destination = .conversations
                installDelegationPreview()
            }
        }
    }

    private func exportCurrentChat(format: SessionExporter.Format) {
        let id = sessions.activeSessionID ?? SessionStore.shared.currentSessionID
        guard let id, let record = SessionStore.shared.load(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Run a task first — the conversation is exported once it has been saved."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Chat"
        panel.prompt = "Export"
        panel.nameFieldStringValue = SessionExporter.suggestedName(for: record, format: format)
        panel.allowedContentTypes = [format == .markdown ? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .markdown:
                try SessionExporter.markdown(for: record)
                    .write(to: url, atomically: true, encoding: .utf8)
            case .json:
                guard let data = SessionExporter.json(for: record) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func exportCurrentTaskBundle() {
        let id = sessions.activeSessionID ?? SessionStore.shared.currentSessionID
        guard let id, let record = SessionStore.shared.load(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Run a task first — the conversation is exported once it has been saved."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        exportTaskBundleFile(for: record)
    }

    private func completeWelcome() {
        var preferences = AppPreferencesStore.shared.current
        preferences.hasCompletedWelcome = true
        preferences.schemaVersion = max(preferences.schemaVersion, 2)
        AppPreferencesStore.shared.save(preferences)
        readinessIsOnboarding = false
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "The agent works inside this folder and cannot escape it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            destination = .conversations
            await sessions.switchWorkspace(to: url)
            if case .failed = appState.enginePhase { appState.enginePhase = .idle }
            var preferences = AppPreferencesStore.shared.current
            preferences.lastWorkspacePath = url.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: url)
            AppPreferencesStore.shared.save(preferences)
        }
    }

    private func openRecord(_ record: SessionRecord) {
        destination = .conversations
        restore(record)
    }

    /// Restore an already-decrypted record (a sidebar pick, a fresh import).
    private func restore(_ record: SessionRecord) {
        guard SessionStore.shared.validateWorkspaceBinding(record) else { return }
        if sessions.restore(record) {
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = record.workspacePath.isEmpty ? nil : record.workspacePath
            AppPreferencesStore.shared.save(preferences)
            if case .failed = appState.enginePhase { appState.enginePhase = .idle }
        }
    }

    private func handleWorkspaceCommand(_ command: WorkspaceCommand) {
        switch command {
        case .newChat:
            NotificationCenter.default.post(name: .newChat, object: nil)
        case .openProject:
            chooseWorkspace()
        case .chatOnly:
            Task { await sessions.switchToChatOnly() }
        case .importChats:
            importExternalHistory()
        case .importBundle:
            importTaskBundle()
        case .refresh:
            // The strip reloads its records on this notification.
            NotificationCenter.default.post(name: .sessionTitleChanged, object: nil)
        }
    }

    /// Import Claude / Codex / Cursor histories. The drawer used to own this;
    /// it now runs from the tab strip's workspace menu with an alert summary.
    private func importExternalHistory() {
        Task {
            let report = await Task.detached(priority: .utility) {
                ExternalHistoryImporter.importAll { _ in }
            }.value
            NotificationCenter.default.post(name: .sessionTitleChanged, object: nil)
            let alert = NSAlert()
            alert.messageText = report.failed > 0
                ? "History import finished with failures"
                : "History import finished"
            alert.informativeText = [
                "\(report.imported) imported",
                "\(report.upToDate) up to date",
                "\(report.skipped) skipped",
                report.failed > 0 ? "\(report.failed) failed to save" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            alert.alertStyle = report.failed > 0 ? .warning : .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Import a portable, passphrase-protected task bundle and rebind it to a
    /// folder on this Mac. Three explicit choices: file, passphrase, folder.
    private func importTaskBundle() {
        guard !sessions.isRunning else {
            let alert = NSAlert()
            alert.messageText = "Finish the current answer first"
            alert.informativeText = "A task bundle can be imported when the agent is idle."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Task Bundle"
        panel.message = "Choose a Vamp Assistant task bundle to decrypt and rebind."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "beetask") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = TaskBundlePassphrasePrompt.ask(forExport: false) else { return }
        guard let data = try? Data(contentsOf: url) else {
            taskBundleError("The selected bundle could not be read.")
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let bundle = try TaskBundleCodec.decode(data, passphrase: passphrase)
                await MainActor.run { chooseWorkspaceForTaskBundle(bundle) }
            } catch {
                await MainActor.run { taskBundleError(error.localizedDescription) }
            }
        }
    }

    /// A decrypted bundle never supplies its own destination; the selected
    /// folder is the only source of the new session's workspace binding.
    private func chooseWorkspaceForTaskBundle(_ bundle: TaskBundle) {
        let panel = NSOpenPanel()
        panel.title = "Choose Workspace for Imported Task"
        panel.message = bundle.workspaceHint.isEmpty
            ? "Choose the project folder where this task should continue."
            : "Rebind “\(bundle.workspaceHint)” to a project folder on this Mac."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let workspace = panel.url else { return }
        do {
            let record = try TaskBundleCodec.reboundSession(bundle, workspace: workspace)
            if case .failure(let error) = SessionStore.shared.save(record) {
                throw error
            }
            guard sessions.restore(record) else {
                SessionStore.shared.delete(record)
                throw TaskBundleError.workspaceRequired
            }
            openRecord(record)
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = workspace.standardizedFileURL.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: workspace)
            AppPreferencesStore.shared.save(preferences)
        } catch {
            taskBundleError(error.localizedDescription)
        }
    }

    private func taskBundleError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Task bundle import failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }


}
