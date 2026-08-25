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
    @State private var showModelManager = false
    @State private var showSimulator = false
    @State private var showBrowser = false
    @State private var showDiagnostics = false
    @State private var showRemoteAccess = false
    @State private var showRemoteAccessConsent = false
    @State private var showCompactSidebar = false
    @State private var showChangedFilesReview = false
    @State private var showReadiness = false
    @State private var readinessIsOnboarding = false
    @State private var showBotsDashboard = false

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
        showCompactSidebar = false
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
        responsiveLayout
            .navigationTitle(showBotsDashboard ? "Bots" : (sessions.workspaceURL?.lastPathComponent ?? "Vamp Assistant"))
            .toolbar {
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
            }
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
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .background(Theme.bg)
            .onChange(of: showCompactSidebar) { _, on in
                if on {
                    showBrowser = false
                    showSimulator = false
                    showDiagnostics = false
                    appState.isSimulatorPanelOpen = false
                }
            }
    }

    private var topToolCluster: some View {
        HStack(spacing: 2) {
            topToolButton("Browser", icon: "safari", active: showBrowser) {
                toggleToolPanel(.browser)
            }
            topToolButton("Simulator", icon: "iphone", active: showSimulator) {
                toggleToolPanel(.simulator)
            }
            topToolButton("Remote", icon: "iphone.gen3.radiowaves.left.and.right", active: appState.remoteSessionRunning) {
                requestRemoteAccess()
            }
            topToolButton("Diagnostics", icon: "waveform.path.ecg", active: showDiagnostics) {
                toggleToolPanel(.diagnostics)
            }
        }
        .padding(2)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.hairline.opacity(0.42), lineWidth: 0.75))
    }

    private var moreActionsMenu: some View {
        Menu {
            Button("Remote sessions…") { requestRemoteAccess() }
            Button("Model manager…") { showModelManager = true }
            Divider()
            Button("Export current chat as Markdown…") {
                exportCurrentChat(format: .markdown)
            }
            Button("Export current chat as JSON…") {
                exportCurrentChat(format: .json)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline.opacity(0.42), lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .help("More app actions")
    }

    private func topToolButton(
        _ title: String,
        icon: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(active ? Theme.rose : Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(active ? Theme.surfaceInset : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(title)
        .accessibilityLabel(title)
    }

    private var presentationView: some View {
        configuredLayout
            .sheet(isPresented: $showModelManager) {
                ModelManagerView()
                    .environmentObject(appState)
                    .frame(minWidth: 640, minHeight: 480)
            }
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
                        showReadiness = false
                        DispatchQueue.main.async { chooseWorkspace() }
                    },
                    onOpenModelManager: {
                        showReadiness = false
                        DispatchQueue.main.async { showModelManager = true }
                    },
                    onComplete: completeWelcome)
                .environmentObject(appState)
            }
            .task { presentWelcomeIfNeeded() }
    }

    private var notificationView: some View {
        AnyView(presentationView)
            .onReceive(appNotifications, perform: handleAppNotification)
    }

    private var appNotifications: AnyPublisher<Notification, Never> {
        Publishers.MergeMany([
            .openModelManager, .openWorkspace, .openSystemReadiness, .openRemoteAccess,
            .openBrowserPanel, .openBotsDashboard, .openAssistantHome,
            .toggleBrowserPanel, .toggleSimulatorPanel, .toggleDiagnosticsPanel,
            .gitStatus, .gitDiff, .undoCheckpoint, .exportChatMarkdown,
            .exportChatJSON, .exportTaskBundle, .newChat, .stopAgent,
        ].map { NotificationCenter.default.publisher(for: $0) })
        .eraseToAnyPublisher()
    }

    private func handleAppNotification(_ notification: Notification) {
        switch notification.name {
        case .openModelManager: showModelManager = true
        case .openWorkspace: chooseWorkspace()
        case .openSystemReadiness:
            readinessIsOnboarding = false
            showReadiness = true
        case .openRemoteAccess: requestRemoteAccess()
        case .openBrowserPanel: presentToolPanel(.browser)
        case .openBotsDashboard:
            showBotsDashboard = true
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
        case .openAssistantHome: showBotsDashboard = false
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

    private func requestRemoteAccess() {
        if settings.remoteAccessConsentCompleted {
            showRemoteAccess = true
        } else {
            showRemoteAccessConsent = true
        }
    }

    private func presentWelcomeIfNeeded() {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isTestHost, !AppPreferencesStore.shared.current.hasCompletedWelcome else { return }
        readinessIsOnboarding = true
        showReadiness = true
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
            Group {
                if proxy.size.width < 900 {
                    portraitLayout
                } else {
                    wideLayout
                }
            }
        }
    }

    private var wideLayout: some View {
        NavigationSplitView {
            SidebarView(showRemoteAccess: $showRemoteAccess)
                .navigationSplitViewColumnWidth(min: 240, ideal: 292, max: 380)
        } detail: {
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
                if showSimulator {
                    Divider()
                    SimulatorPanelView(onClose: {
                        showSimulator = false
                        appState.isSimulatorPanelOpen = false
                    })
                    .environmentObject(appState)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
                }
                if showBrowser {
                    Divider()
                    BrowserPanelView(onClose: { showBrowser = false })
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                }
                if showDiagnostics {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            ChatView(controller: sessions)
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// Portrait windows use one readable column. Sidebar/history and tools
    /// become sheets instead of competing for horizontal space with the
    /// transcript and composer.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showCompactSidebar = true
                } label: {
                    Label("Chats", systemImage: "sidebar.left")
                }
                .buttonStyle(LFCapsuleButtonStyle())
                Button {
                    sessions.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(LFIconButtonStyle(size: 30))
                .lfHoverLift()
                .help("New chat")
                Spacer()
                Text(showBotsDashboard ? "Bots" : (sessions.workspaceURL?.lastPathComponent ?? "Vamp Assistant"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            if showBotsDashboard {
                BotDashboardView()
                    .environmentObject(appState)
                    .environmentObject(sessions)
            } else {
                chatColumn
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $showCompactSidebar) {
            SidebarView(showRemoteAccess: $showRemoteAccess,
                        showsCloseButton: true)
            .environmentObject(appState)
            .environmentObject(sessions)
            .frame(minWidth: 320, idealWidth: 360, minHeight: 500)
        }
        .sheet(isPresented: $showBrowser) {
            BrowserPanelView(onClose: { showBrowser = false })
                .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showSimulator) {
            SimulatorPanelView(onClose: {
                showSimulator = false
                appState.isSimulatorPanelOpen = false
            })
            .environmentObject(appState)
            .frame(minWidth: 360, idealWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsPanelView(onClose: { showDiagnostics = false })
                .frame(minWidth: 360, idealWidth: 520, minHeight: 420)
        }
    }
}
