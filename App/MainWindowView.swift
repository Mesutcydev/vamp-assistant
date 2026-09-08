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
enum SidebarHistoryTab {
    case sessions, imported
}

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    /// Settings is a first-class in-app workspace.  Keeping the selected
    /// tab here lets deep links (the composer, readiness card, and sidebar)
    /// open Models in the same split view instead of spawning a cramped sheet.
    @State private var settingsTab: SettingsView.Tab = .general
    @State private var settingsModelsSection: ModelsAndProvidersTab.Section = .library
    @State private var showSimulator = false
    @State private var showBrowser = false
    @State private var showDiagnostics = false
    @State private var showRemoteAccess = false
    @State private var showRemoteAccessConsent = false
    @State private var showChangedFilesReview = false
    @State private var showReadiness = false
    @State private var readinessIsOnboarding = false
    @State private var showBotsDashboard = false
    @State private var showSettings = false
    @State private var showComposerFixture = false
    @State private var fixtureStore = ComposerStore()
    /// Dev-only visual-verification mode (`--design-preview <screen>`).
    /// Nil in production launches; when present the app opens the requested
    /// screen at the reference artboard size with inert fixture content.
    @State private var designPreview: DesignPreviewScreen? = DesignPreviewScreen.fromLaunchArguments()
    /// The sidebar is a region of the window's root row, not a
    /// NavigationSplitView column: on macOS 26 that column is wrapped in an
    /// inset, rounded concentric-glass panel, which gave the drawer its own
    /// bottom-trailing corner instead of letting the window own the corners.
    @State private var sidebarVisible = true
    @State private var composerDockHeight: CGFloat = 224
    @State private var sidebarWidth: CGFloat = SidebarMetrics.width

    private var dockedPanelOpen: Bool {
        showSimulator || showBrowser || showDiagnostics
    }

    /// Chat keeps leftover space; mins drop when a docked panel is open so
    /// the three columns fit a 960-pt window instead of overflowing.
    private var chatMinWidth: CGFloat { dockedPanelOpen ? 300 : 380 }

    private enum ToolPanel {
        case browser, simulator, diagnostics
    }

    /// One tool surface at a time — stacked Browser/Simulator/Diagnostics
    /// sheets (or three docked columns) hide the composer.
    private func presentToolPanel(_ panel: ToolPanel) {
        showSettings = false
        showBotsDashboard = false
        showBrowser = panel == .browser
        showSimulator = panel == .simulator
        showDiagnostics = panel == .diagnostics
        appState.isSimulatorPanelOpen = showSimulator
    }

    private func toggleToolPanel(_ panel: ToolPanel) {
        let open: Bool = switch panel {
        case .browser: showBrowser
        case .simulator: showSimulator
        case .diagnostics: showDiagnostics
        }
        if open {
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
            appState.isSimulatorPanelOpen = false
        } else {
            presentToolPanel(panel)
        }
    }

    var body: some View {
        notificationView
    }

    private var configuredLayout: some View {
        ZStack {
            // One continuous instrument canvas for the whole window: the
            // fixed silver shell every module mounts onto. No atmosphere,
            // no wallpaper — the app reads as one industrial object family.
            Theme.workspaceCanvas
                .ignoresSafeArea()

            Group {
                if showComposerFixture {
                    composerFixture
                } else if showSettings {
                    SettingsView(initialTab: settingsTab, initialModelsSection: settingsModelsSection, onClose: { showSettings = false })
                        .environmentObject(appState)
                } else {
                    responsiveLayout
                }
            }
        }
            // Reference: one full-width 52pt chrome band styled as a quiet
            // silver instrument strip; native traffic lights and toolbar
            // items draw above it, content below keeps its own safe area.
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Instrument.silverTop, Instrument.silverMid],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Instrument.seam).frame(height: 0.75)
                }
                .frame(height: Chrome.topBandHeight)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .navigationTitle(windowTitle)
            .toolbar {
                if !showSettings {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            sidebarVisible.toggle()
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Instrument.ink)
                        }
                        .help("Toggle sidebar")
                        .accessibilityLabel("Toggle sidebar")
                        .accessibilityValue(sidebarVisible ? "Expanded" : "Collapsed")
                        .keyboardShortcut("s", modifiers: [.command, .control])
                    }
                }
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarItemGroup(placement: .primaryAction) {
                        topToolCluster
                        moreActionsMenu
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        topToolCluster
                        moreActionsMenu
                    }
                }
#else
                ToolbarItemGroup(placement: .primaryAction) {
                    topToolCluster
                    moreActionsMenu
                }
#endif
            }
            .onAppear(perform: applyDesignPreview)
            .onChange(of: appState.enginePhase) { _, phase in
                switch phase {
                case .idle:
                    DiagnosticsCenter.shared.record(.engine, "Engine idle")
                case .loading(let name):
                    DiagnosticsCenter.shared.record(.engine, "Loading \(name)…")
                case .ready(let name):
                    DiagnosticsCenter.shared.record(.engine, "\(name) ready")
                case .failed(let reason):
                    DiagnosticsCenter.shared.record(.engine, "Model load failed",
                                                    detail: reason, level: .error)
                }
            }
            // The sidebar surface runs up under the titlebar. A visible
            // toolbar band would paint its own material and separator across
            // that corner, splitting one window silhouette into two stacked
            // rectangles.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(Theme.bg)
    }

    /// Window title follows the active chat (like the reference client),
    /// falling back to the workspace name when there is no saved chat yet.
    private var windowTitle: String {
        if showSettings { return "Settings" }
        if showBotsDashboard { return "Bots" }
        if let id = sessions.activeSessionID,
           let record = SessionStore.shared.load(id: id) {
            let title = SessionTitle.display(for: record)
            if !title.isEmpty { return title }
        }
        return sessions.workspaceURL?.lastPathComponent ?? "Vamp Assistant"
    }

    private var topToolCluster: some View {
        HStack(spacing: 8) {
            topToolButton("Browser", icon: "safari", active: showBrowser) {
                toggleToolPanel(.browser)
            }
            topToolButton("Simulator", icon: "iphone", active: showSimulator) {
                toggleToolPanel(.simulator)
            }
            topToolButton("Diagnostics", icon: "waveform.path.ecg", active: showDiagnostics) {
                toggleToolPanel(.diagnostics)
            }
            topBotsButton
        }
    }

    /// One Bots destination with a text label, matching the reference
    /// client's trailing toolbar button.
    private var topBotsButton: some View {
        VampToolbarButton(active: showBotsDashboard) {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                    .font(.app(size: 13, weight: .medium ))
                Text("Bots")
                    .font(.app(size: 12.5, weight: .medium ))
            }
        } action: {
            showSettings = false
            showBotsDashboard = true
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
        }
        .help("Bots")
        .accessibilityLabel("Bots")
    }

    private var moreActionsMenu: some View {
        InstrumentMenu(menuWidth: 260) {
            Image(systemName: "ellipsis")
                .font(.system(size: Chrome.toolbarIcon, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Chrome.toolbarButtonHeight, height: Chrome.toolbarButtonHeight)
                .background(Theme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: Chrome.toolbarButtonRadius,
                                                 style: .continuous))
        } options: {
            InstrumentMenuRow(
                title: settings.showHomeSuggestions ? "Hide homepage suggestions" : "Show homepage suggestions",
                systemImage: settings.showHomeSuggestions ? "eye.slash" : "eye") {
                settings.showHomeSuggestions.toggle()
            }
            InstrumentMenuRow(title: "Remote sessions…", systemImage: "antenna.radiowaves.left.and.right") {
                requestRemoteAccess()
            }
            InstrumentMenuRow(title: "Models…", systemImage: "cpu") {
                openModelsSettings()
            }
            InstrumentMenuRow(title: "Export current chat as Markdown…", systemImage: "doc.text") {
                exportCurrentChat(format: .markdown)
            }
            InstrumentMenuRow(title: "Export current chat as JSON…", systemImage: "curlybraces.square") {
                exportCurrentChat(format: .json)
            }
        }
        .help("More app actions")
        .accessibilityLabel("More app actions")
    }

    private func topToolButton(
        _ title: String,
        icon: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VampToolbarIconButton(icon: icon, active: active, help: title, action: action)
    }

    private var presentationView: some View {
        configuredLayout
            .sheet(isPresented: $showRemoteAccess) {
                RemoteAccessView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showRemoteAccessConsent) {
                RemoteAccessConsentView(
                    onCancel: { showRemoteAccessConsent = false },
                    onAllow: { clipboard, files in
                        settings.remoteAccessConsentCompleted = true
                        settings.remoteClipboardSharingEnabled = clipboard
                        settings.remoteFileSharingEnabled = files
                        settings.remoteSessionEnabled = true
                        showRemoteAccessConsent = false
                        DispatchQueue.main.async { showRemoteAccess = true }
                    })
            }
            .sheet(isPresented: $showChangedFilesReview) {
                if let workspace = sessions.workspaceURL {
                    ChangedFilesReviewView(workspace: workspace)
                }
            }
            .sheet(isPresented: $showReadiness) {
                WelcomeReadinessView(
                    isOnboarding: readinessIsOnboarding,
                    onOpenWorkspace: {
                        completeWelcome()
                        showReadiness = false
                        DispatchQueue.main.async { chooseWorkspace() }
                    },
                    onOpenModelManager: {
                        completeWelcome()
                        showReadiness = false
                        DispatchQueue.main.async { openProvidersSettings() }
                    },
                    onComplete: completeWelcome)
                .environmentObject(appState)
            }
            .task { presentWelcomeIfNeeded() }
    }

    private var notificationView: some View {
        AnyView(presentationView)
            .onReceive(appNotifications, perform: handleAppNotification)
            .onReceive(NotificationCenter.default.publisher(for: .focusChatSearch)) { _ in
                showBotsDashboard = false
                guard !sidebarVisible else { return }
                sidebarVisible = true
                Task { @MainActor in
                    await Task.yield()
                    NotificationCenter.default.post(name: .focusChatSearch, object: nil)
                }
            }
    }

    private var appNotifications: AnyPublisher<Notification, Never> {
        Publishers.MergeMany([
            .openModelManager, .openWorkspace, .openSystemReadiness, .openRemoteAccess,
            .openBrowserPanel, .openBotsDashboard, .openAssistantHome, .openAppSettings,
            .openProviderSettings,
            .toggleBrowserPanel, .toggleSimulatorPanel, .toggleDiagnosticsPanel,
            .gitStatus, .gitDiff, .undoCheckpoint, .exportChatMarkdown,
            .exportChatJSON, .exportTaskBundle, .newChat, .stopAgent,
        ].map { NotificationCenter.default.publisher(for: $0) })
        .eraseToAnyPublisher()
    }

    private func handleAppNotification(_ notification: Notification) {
        switch notification.name {
        case .openModelManager: openModelsSettings()
        case .openWorkspace: chooseWorkspace()
        case .openSystemReadiness:
            readinessIsOnboarding = false
            showReadiness = true
        case .openRemoteAccess: requestRemoteAccess()
        case .openBrowserPanel: presentToolPanel(.browser)
        case .openBotsDashboard:
            showSettings = false
            showBotsDashboard = true
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
        case .openAssistantHome:
            showSettings = false
            showBotsDashboard = false
        case .openAppSettings:
            settingsTab = .general
            showSettings = true
            showBotsDashboard = false
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
        case .openProviderSettings:
            openProvidersSettings()
        case .toggleBrowserPanel: toggleToolPanel(.browser)
        case .toggleSimulatorPanel: toggleToolPanel(.simulator)
        case .toggleDiagnosticsPanel: toggleToolPanel(.diagnostics)
        case .gitStatus: sessions.gitStatus()
        case .gitDiff: showChangedFilesReview = sessions.workspaceURL != nil
        case .undoCheckpoint: sessions.undoLastCheckpoint()
        case .exportChatMarkdown: exportCurrentChat(format: .markdown)
        case .exportChatJSON: exportCurrentChat(format: .json)
        case .exportTaskBundle: exportCurrentTaskBundle()
        case .newChat:
            showBotsDashboard = false
            Task { await sessions.switchToChatOnly() }
        case .stopAgent: sessions.stop()
        default: break
        }
    }

    /// Opens the Models page inside the full Settings workspace.  This keeps
    /// navigation, sizing, keyboard focus, and the Back to Assistant affordance
    /// identical to every other settings destination.
    private func openModelsSettings() {
        settingsTab = .models
        settingsModelsSection = .library
        showSettings = true
        showBotsDashboard = false
        showBrowser = false
        showSimulator = false
        showDiagnostics = false
    }

    private func openProvidersSettings() {
        settingsTab = .models
        settingsModelsSection = .providers
        showSettings = true
        showBotsDashboard = false
        showBrowser = false
        showSimulator = false
        showDiagnostics = false
    }

    private func requestRemoteAccess() {
        if settings.remoteAccessConsentCompleted {
            showRemoteAccess = true
        } else {
            showRemoteAccessConsent = true
        }
    }

    private func presentWelcomeIfNeeded() {
        guard !AppState.isTestHost,
              !AppPreferencesStore.shared.current.hasCompletedWelcome else { return }
        readinessIsOnboarding = true
        showReadiness = true
    }

    /// Opens the requested screen for design capture and sizes the window to
    /// the reference artboard (1320 × 856 content). Fixture content is inert:
    /// no tools run, nothing persists, and approvals only clear locally.
    private func applyDesignPreview() {
        guard let screen = designPreview else { return }
        designPreview = nil
        Instrument.debugFrameReport = true
        DispatchQueue.main.async {
            // Design captures must not inherit a restored in-app destination.
            // Reset every mutually exclusive workspace before selecting the
            // requested fixture so the screenshot always shows the argument
            // that launched this exact binary.
            showComposerFixture = false
            showSettings = false
            showBotsDashboard = false
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
            if let window = NSApplication.shared.windows.first {
                let args = ProcessInfo.processInfo.arguments
                var width: CGFloat = 1320
                var height: CGFloat = 856
                if let i = args.firstIndex(of: "--design-size"),
                   args.indices.contains(i + 1) {
                    let parts = args[i + 1].split(separator: "x")
                    if parts.count == 2,
                       let w = Double(parts[0]), let h = Double(parts[1]) {
                        width = CGFloat(w)
                        height = CGFloat(h)
                    }
                }
                window.setContentSize(NSSize(width: width, height: height))
                window.center()
            }
            switch screen {
            case .chat:
                DesignPreview.install(.chat, into: sessions)
            case .composer:
                showComposerFixture = true
                sidebarVisible = false
                DesignPreview.install(.composer, into: sessions)
                fixtureStore.prompt = "Draft the release notes for 0.9.5"
            case .welcome:
                break
            case .settingsGeneral:
                settingsTab = .general
                showSettings = true
            case .settingsModels:
                settingsTab = .models
                settingsModelsSection = .library
                showSettings = true
            case .settingsBots:
                settingsTab = .bots
                showSettings = true
            case .settingsAgent:
                settingsTab = .agent
                showSettings = true
            case .settingsNetwork:
                settingsTab = .network
                showSettings = true
            case .settingsPlugins:
                settingsTab = .plugins
                showSettings = true
            case .settingsHover:
                settingsTab = .general
                showSettings = true
                SettingsRail.previewHover = .models
            case .settingsFocus:
                settingsTab = .general
                showSettings = true
                SettingsRail.previewFocus = .bots
            case .botsDashboard:
                showSettings = false
                showBotsDashboard = true
            }
            if ProcessInfo.processInfo.arguments.contains("--design-collapsed") {
                sidebarVisible = false
            }
        }
    }

    /// Export the active conversation even when the sidebar is collapsed. The
    /// sidebar rows still offer the same actions for older chats; these
    /// notifications make the current chat reachable from the top bar too.
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
            showBotsDashboard = false
            await sessions.switchWorkspace(to: url)
            if case .failed = appState.enginePhase { appState.enginePhase = .idle }
            var preferences = AppPreferencesStore.shared.current
            preferences.lastWorkspacePath = url.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: url)
            AppPreferencesStore.shared.save(preferences)
        }
    }

    private var responsiveLayout: some View {
        GeometryReader { proxy in
            wideLayout(compact: proxy.size.width < 900)
                .sheet(isPresented: Binding(get: { proxy.size.width < 900 && showBrowser }, set: { showBrowser = $0 })) {
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
                }
                .sheet(isPresented: Binding(get: { proxy.size.width < 900 && showSimulator }, set: { showSimulator = $0 })) {
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                    .environmentObject(appState)
                    .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
                }
                .sheet(isPresented: Binding(get: { proxy.size.width < 900 && showDiagnostics }, set: { showDiagnostics = $0 })) {
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 360, idealWidth: 520, minHeight: 420)
                }
        }
    }

    /// Sidebar, divider, and main region are siblings in the window's root
    /// row. Nothing here is a card: no region carries a radius of its own, so
    /// the window mask is the only thing that rounds a corner and every
    /// interior junction — drawer/content and drawer/status bar — is square.
    private func wideLayout(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ChatRail(showsBots: showBotsDashboard,
                     composerHeight: composerDockHeight,
                     onNewChat: { NotificationCenter.default.post(name: .newChat, object: nil) },
                     onSearch: {
                         showBotsDashboard = false
                         sidebarVisible = true
                         Task { @MainActor in
                             await Task.yield()
                             NotificationCenter.default.post(name: .focusChatSearch, object: nil)
                         }
                     },
                     onExpand: {
                         if showBotsDashboard {
                             showBotsDashboard = false
                             sidebarVisible = true
                         } else {
                             sidebarVisible.toggle()
                         }
                     },
                     onBots: { showSettings = false; showBotsDashboard = true },
                     onSettings: {
                         settingsTab = .general
                         showSettings = true
                         showBotsDashboard = false
                     })
                SidebarView(showRemoteAccess: $showRemoteAccess,
                            onClose: { sidebarVisible = false })
                    .frame(width: sidebarWidth)
                    .background(Theme.workspaceCanvas)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: sidebarVisible ? sidebarWidth : 0)
                    }
                    .frame(width: !compact && sidebarVisible ? sidebarWidth : 0, alignment: .leading)
                    .zIndex(1)
                    .allowsHitTesting(sidebarVisible)
                    .accessibilityHidden(!sidebarVisible)
            if sidebarVisible && !compact {
                SidebarSplitDivider(width: $sidebarWidth,
                                    range: SidebarMetrics.minWidth...SidebarMetrics.maxWidth)
            }
            HStack(spacing: 0) {
                Group {
                    if showBotsDashboard {
                        BotDashboardView()
                            .environmentObject(appState)
                            .environmentObject(sessions)
                    } else {
                        chatColumn
                    }
                }
                .frame(minWidth: chatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                if showSimulator && !compact {
                    Divider()
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                    .environmentObject(appState)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
                }
                if showBrowser && !compact {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                }
                if showDiagnostics && !compact {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
        .onPreferenceChange(ComposerDockHeightKey.self) { composerDockHeight = $0 }
    }

    private var chatColumn: some View {
        ChatView(controller: sessions)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
    }

    /// Canonical composer fixture: the approved object spans the workspace
    /// and docks flush to the usable bottom edge exactly like production.
    /// Isolated store; no sends, permissions, or history mutation.
    private var composerFixture: some View {
        VStack {
            Spacer(minLength: 0)
            InstrumentComposer(store: fixtureStore, placement: .conversation)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Chrome.composerBottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(appState)
        .environmentObject(sessions)
    }

}
