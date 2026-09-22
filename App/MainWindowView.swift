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
    @Environment(\.openWindow) private var openWindow
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
    @State private var showSettings = false
    /// Dev-only visual-verification mode (`--design-preview <screen>`).
    /// Nil in production launches; when present the app opens the requested
    /// screen at the reference artboard size with inert fixture content.
    @State private var designPreview: DesignPreviewScreen? = DesignPreviewScreen.fromLaunchArguments()
    /// Sidebar destination and column state — the window reflects the
    /// sidebar's selection instead of owning a private set of flags.
    @State private var destination: ShellDestination = .conversations
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    /// True while the sidebar is hidden because the window is too narrow, so
    /// it can come back on its own — a collapse the user chose is theirs.
    @State private var sidebarAutoCollapsed = false
    /// Measured so the toolbar's centre follows a sidebar the user resized.
    @State private var sidebarWidth: CGFloat = 240
    /// Never slide the field so far that it could reach a neighbouring cluster.
    private static let maximumToolbarShift: CGFloat = 260
    /// Sidebar (220) + a readable transcript + the composer's controls do not
    /// coexist below this; above the second figure there is room again.
    private static let sidebarCollapseWidth: CGFloat = 720
    private static let sidebarRestoreWidth: CGFloat = 860
    /// The toolbar's search field and the sidebar's conversation list share
    /// this query: typing in the toolbar filters the library.
    @State private var historySearch = ""
    /// Kept so the window-update observer that drops macOS 26's duplicate
    /// sidebar-toggle item can be torn down when the view goes away.
    @State private var updateObserver: NSObjectProtocol?
    /// True while the navigation column is on screen, so the corner patch that
    /// masks the system panel's shadow is only drawn when there is a panel.
    @State private var sidebarOnScreen = false
    /// One draft shared by the middle's writing well and the bottom key bar.
    @State private var composerStore = ComposerStore()
    @State private var composerDockHeight: CGFloat = ComposerDockHeightKey.defaultValue

    private var dockedPanelOpen: Bool {
        showSimulator || showBrowser || showDiagnostics
    }

    /// Chat keeps leftover space; mins drop when a docked panel is open so
    /// the three columns fit a 960-pt window instead of overflowing.
    private var chatMinWidth: CGFloat { dockedPanelOpen ? 280 : 320 }

    private enum ToolPanel {
        case browser, simulator, diagnostics
    }

    /// One tool surface at a time — stacked Browser/Simulator/Diagnostics
    /// sheets (or three docked columns) hide the composer.
    private func presentToolPanel(_ panel: ToolPanel) {
        showSettings = false
        if destination == .bots { destination = .conversations }
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
            // The window's own background. This used to ignore the safe area
            // so a painted canvas ran under the titlebar; with the system
            // toolbar that inset is exactly what keeps the transcript from
            // drawing through the title band.
            Theme.workspaceCanvas

            Group {
                if showSettings {
                    SettingsView(initialTab: settingsTab, initialModelsSection: settingsModelsSection, onClose: { showSettings = false })
                        .environmentObject(appState)
                } else {
                    responsiveLayout
                }
            }

            // Painted last, above the split view, so it can cover the shadow the
            // system draws around the sidebar panel's rounded leading corners.
            if sidebarOnScreen, !showSettings {
                SidebarCornerPatch()
                    .frame(width: SidebarCornerPatch.size, height: SidebarCornerPatch.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                SidebarCornerPatch(corner: .bottomLeading)
                    .frame(width: SidebarCornerPatch.size, height: SidebarCornerPatch.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
            .navigationTitle(windowTitle)
            .toolbar(removing: .title)
            // The system's own sidebar toggle lands at the sidebar's trailing
            // edge (~148 pt right of the traffic lights, hugging the seam),
            // which reads as a stray control floating over the column instead
            // of the window's top-left corner. The app draws that button now.
            .toolbar(removing: .sidebarToggle)
            // Browser grammar in SYSTEM parts: each ToolbarItemGroup is one
            // capsule the way Safari groups sidebar+chevron and back/forward,
            // and the OS draws every face, hover, and press.
            .toolbar {
                if !showSettings {
                    // Leading edge, next to the traffic lights: show/hide the
                    // conversation library. One item, native rendering.
                    ToolbarItem(placement: .navigation) {
                        Button {
                            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                        } label: {
                            Label("Toggle sidebar", systemImage: "sidebar.left")
                        }
                        .help(sidebarVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
                        .accessibilityIdentifier("sidebar-toggle")
                    }
                    // Centre: one real search field over the conversation
                    // library. It navigates only — it never submits a prompt.
                    ToolbarItem(placement: .principal) {
                        searchFieldItem
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            destination = .conversations
                            NotificationCenter.default.post(name: .newChat, object: nil)
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        .help("New conversation")
                        .accessibilityIdentifier("new-conversation")
                    }
#if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
#endif
                    ToolbarItemGroup(placement: .primaryAction) {
                        toolPanelButtons
                    }
#if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
#endif
                    ToolbarItemGroup(placement: .primaryAction) {
                        moreActionsMenu
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Session info", systemImage: "info.circle")
                        }
                        .help("Session info")
                        .accessibilityIdentifier("inspector-toggle")
                    }
                }
            }
            .onAppear(perform: applyDesignPreview)
            .onAppear {
                // macOS 26 keeps injecting its own sidebar-toggle toolbar item
                // even after `.toolbar(removing: .sidebarToggle)`, and that
                // item lands at the sidebar's trailing edge — a second toggle
                // hovering over the seam. The app draws its own; the system's
                // duplicate is removed once the toolbar exists.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    adoptOwnSidebarToggle()
                }
                // `Theme.applyAppearance` configures whatever windows exist
                // when the appearance is applied, which loses a window that the
                // system restores afterwards: that window keeps AppKit's default
                // background, so the sidebar's inset shows black. Configure the
                // window from its own lifecycle instead.
                if let window = NSApp.windows.first(where: { $0.isMainWindow })
                    ?? NSApp.windows.first(where: { $0.isVisible }) {
                    Theme.configureTitlebar(of: window)
                }
            }
            .onDisappear {
                if let updateObserver {
                    NotificationCenter.default.removeObserver(updateObserver)
                    self.updateObserver = nil
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
            // The unified window lets content scroll under the titlebar, so the
            // toolbar must carry its own material — without it the transcript
            // was legible straight through the title band and over the traffic
            // lights at small window sizes. It carries the chrome band's
            // material rather than the system default, so the title band and
            // the navigation column beside it read as one plane.
            .toolbarBackground(Theme.chromeBar, for: .windowToolbar)
            .background(Theme.bg)
    }

    /// Removes the system's own sidebar-toggle toolbar item. macOS 26 adds it
    /// regardless of `.toolbar(removing: .sidebarToggle)`, and it sits at the
    /// sidebar's trailing edge rather than the window's corner.
    private func removeSystemSidebarToggle() {
        dropSystemSidebarToggle()
    }

    /// Drops SwiftUI's own sidebar-toggle item. `removeItem` alone is undone —
    /// SwiftUI re-inserts the item on its next toolbar pass, ten times in half a
    /// minute in practice — so the item and its view are hidden instead, which
    /// leaves the toolbar's item list alone and therefore sticks.
    private func dropSystemSidebarToggle() {
        let window = NSApp.windows.first(where: { $0.isMainWindow })
            ?? NSApp.windows.first(where: { $0.isVisible })
        guard let toolbar = window?.toolbar else { return }
        // SwiftUI's own item: 'com.apple.SwiftUI.navigationSplitView.toggleSidebar',
        // labelled "Hide Sidebar"/"Show Sidebar" — it sits at the sidebar's
        // trailing edge, not the window's corner, so the app draws its own and
        // this one is taken out.
        guard let item = toolbar.items.first(where: { item in
            item.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
                || item.label == "Hide Sidebar"
                || item.label == "Show Sidebar"
        }) else { return }
        if !item.isHidden { item.isHidden = true }
        if let view = item.view, !view.isHidden { view.isHidden = true }
    }

    /// macOS 26's split view keeps the toggle item alive, so it is re-checked
    /// while the window settles and again whenever the window updates.
    private func adoptOwnSidebarToggle() {
        guard let window = NSApp.windows.first(where: { $0.isMainWindow })
            ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        dropSystemSidebarToggle()
        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                removeSystemSidebarToggle()
                // Same reason as the toggle: the window's own setup can land
                // before the window that finally stays on screen exists, so it
                // is re-applied as the window updates.
                Theme.configureTitlebar(of: window)
            }
        }
        for step in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(step)) {
                removeSystemSidebarToggle()
            }
        }
    }

    /// Window title follows the active chat (like the reference client),
    /// falling back to the workspace name when there is no saved chat yet.
    private var windowTitle: String {
        if showSettings { return "Settings" }
        if destination == .bots { return "Bots" }
        if let id = sessions.activeSessionID,
           let record = SessionStore.shared.load(id: id) {
            let title = SessionTitle.display(for: record)
            if !title.isEmpty { return title }
        }
        return sessions.workspaceURL?.lastPathComponent ?? "Vamp Assistant"
    }

    /// Search travels in the middle of the WINDOW, the way Safari composes
    /// its address field. A `.principal` item is centred on the detail pane,
    /// so the field is pulled back by half of whatever the sidebar takes:
    /// the item gets trailing padding, which widens it without drawing
    /// anything, and the system's centring then lands the visible field on the
    /// window's middle. (An `.offset` here does nothing — AppKit owns toolbar
    /// item placement and ignores it.)
    private var searchFieldItem: some View {
        // The field keeps its own toolbar item: anything sharing an item with
        // it is drawn inside one merged capsule, and the search field loses
        // its bezel. The clear spacer widens the ITEM (never the field) so the
        // system's centring lands the field on the window's middle.
        HStack(spacing: 0) {
            ToolbarSearchField(text: $historySearch,
                               placeholder: "Search conversations",
                               onCommit: revealSearchResults)
                .frame(width: 380)
                // Without this the field stretches to whatever the item is
                // given, so the spacer below widened the field instead of
                // moving it.
                .fixedSize(horizontal: true, vertical: false)
            Color.clear
                .frame(width: toolbarCenteringInset)
        }
            // Without this the toolbar stretches the whole item to fill the
            // space left of the trailing controls, which drags the field right
            // of the window's middle; a fixed-size item is centred instead.
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("conversation-search")
            .onChange(of: historySearch) { _, value in
                guard !value.isEmpty else { return }
                revealSearchResults()
            }
    }

    /// Half the sidebar, expressed as trailing padding on the principal item.
    private var toolbarCenteringInset: CGFloat {
        guard sidebarVisibility != .detailOnly else { return 0 }
        return min(sidebarWidth, Self.maximumToolbarShift * 2)
    }

    /// The `.principal` slot centres on the space the other items leave over,
    /// which sits half a sidebar right of the window's middle whenever the
    /// sidebar is open. (The inspector does not move it: it lives inside the
    /// detail column, so the slot never sees it.) With the sidebar collapsed
    /// the system's own placement stands.

    /// Searching filters the conversation library in the sidebar, so a search
    /// has to bring that column back into view. The field itself takes first
    /// responder (see `ToolbarSearchField`).
    private func revealSearchResults() {
        destination = .conversations
        showSettings = false
        if sidebarVisibility == .detailOnly { sidebarVisibility = .all }
    }

    /// The three docked tool surfaces, each with its own toolbar button: they
    /// are used often enough that a menu would cost a click every time, and
    /// their pressed state has to be visible at a glance.
    @ViewBuilder
    private var toolPanelButtons: some View {
        Button { toggleToolPanel(.browser) } label: {
            Label("Browser", systemImage: "safari")
        }
        .help("Browser")
        .accessibilityIdentifier("browser-toggle")
        .toolbarSelected(showBrowser)
        Button { toggleToolPanel(.simulator) } label: {
            Label("Simulator", systemImage: "iphone")
        }
        .help("Simulator")
        .accessibilityIdentifier("simulator-toggle")
        .toolbarSelected(showSimulator)
        Button { toggleToolPanel(.diagnostics) } label: {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
        }
        .help("Diagnostics")
        .accessibilityIdentifier("diagnostics-toggle")
        .toolbarSelected(showDiagnostics)
    }

    private var moreActionsMenu: some View {
        Menu {
            Button(settings.showHomeSuggestions ? "Hide homepage suggestions" : "Show homepage suggestions",
                   systemImage: settings.showHomeSuggestions ? "eye.slash" : "eye") {
                settings.showHomeSuggestions.toggle()
            }
            Button("Remote sessions…", systemImage: "antenna.radiowaves.left.and.right") {
                requestRemoteAccess()
            }
            Button("Models…", systemImage: "cpu") { openModelsSettings() }
            Divider()
            // Workspace actions previously lived in the chat header; the tab
            // strip replaced it, so the toolbar's overflow menu is their home.
            Button("Review changed files", systemImage: "doc.text.magnifyingglass") {
                NotificationCenter.default.post(name: .gitDiff, object: nil)
            }
            .disabled(sessions.workspaceURL == nil)
            Button("Git status", systemImage: "circle.dashed") {
                NotificationCenter.default.post(name: .gitStatus, object: nil)
            }
            .disabled(sessions.workspaceURL == nil)
            Button("Undo last checkpoint", systemImage: "arrow.uturn.backward") {
                NotificationCenter.default.post(name: .undoCheckpoint, object: nil)
            }
            .disabled(sessions.workspaceURL == nil)
            Divider()
            Button("Export current chat as Markdown…", systemImage: "doc.text") {
                exportCurrentChat(format: .markdown)
            }
            Button("Export current chat as JSON…", systemImage: "curlybraces.square") {
                exportCurrentChat(format: .json)
            }
            Button("Export task bundle…", systemImage: "shippingbox") {
                NotificationCenter.default.post(name: .exportTaskBundle, object: nil)
            }
        } label: {
            Label("More app actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More app actions")
        .chromeControl()
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
                // ⌘F goes to the toolbar's search field, which takes first
                // responder itself (see ToolbarSearchField). The window only
                // makes sure the results it filters are on screen.
                revealSearchResults()
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
            .openSessionRecord, .importChats, .importBundle,
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
            destination = .bots
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
        case .openAssistantHome:
            showSettings = false
            if destination == .bots { destination = .conversations }
        case .openAppSettings:
            settingsTab = .general
            showSettings = true
            if destination == .bots { destination = .conversations }
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
            if destination == .bots { destination = .conversations }
            // New Chat is contextual: it preserves the selected project and
            // starts inside it. Leaving the project is an explicit action in
            // the sidebar's workspace menu.
            if sessions.workspaceURL != nil {
                sessions.newSession()
            } else {
                Task { await sessions.switchToChatOnly() }
            }
        case .stopAgent: sessions.stop()
        case .importChats: importExternalHistory()
        case .importBundle: importTaskBundle()
        case .openSessionRecord:
            guard let id = notification.object as? UUID else { break }
            Task { @MainActor in
                let record = await Task.detached(priority: .userInitiated) {
                    SessionStore.shared.load(id: id)
                }.value
                if let record { openRecord(record) }
            }
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
        if destination == .bots { destination = .conversations }
        showBrowser = false
        showSimulator = false
        showDiagnostics = false
    }

    private func openProvidersSettings() {
        settingsTab = .models
        settingsModelsSection = .providers
        showSettings = true
        if destination == .bots { destination = .conversations }
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
        // Column states for capture runs: the shell's two optional columns
        // cannot be reached from a launch argument otherwise.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--design-inspector") { showInspector = true }
        if args.contains("--design-sidebar-collapsed") { sidebarVisibility = .detailOnly }
        DispatchQueue.main.async {
            // Design captures must not inherit a restored in-app destination.
            // Reset every mutually exclusive workspace before selecting the
            // requested fixture so the screenshot always shows the argument
            // that launched this exact binary.
            showSettings = false
            if destination == .bots { destination = .conversations }
            showBrowser = false
            showSimulator = false
            showDiagnostics = false
            if let window = NSApplication.shared.windows.first {
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
                // The hardware composer fixture is gone with the instrument
                // chassis; the composer now lives in the real chat route.
                DesignPreview.install(.chat, into: sessions)
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
            case .settingsFocus:
                settingsTab = .general
                showSettings = true
            case .botsDashboard:
                showSettings = false
                destination = .bots
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
            if destination == .bots { destination = .conversations }
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
                // Below this the sidebar and a usable transcript cannot both
                // fit, and the composer was pushed off the window's edge. The
                // sidebar yields, and takes itself back when there is room —
                // unless the user collapsed it themselves.
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    if width < Self.sidebarCollapseWidth, sidebarVisibility != .detailOnly {
                        sidebarAutoCollapsed = true
                        sidebarVisibility = .detailOnly
                    } else if width >= Self.sidebarRestoreWidth, sidebarAutoCollapsed {
                        sidebarAutoCollapsed = false
                        sidebarVisibility = .all
                    }
                }
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

    /// A standard macOS three-column window: sidebar (destinations and the
    /// conversation library), detail (transcript + composer, with any docked
    /// tool panel beside it), inspector (session status and model controls).
    /// The frame rails, the tab strip, and the bottom bar are gone — the
    /// system draws this window's structure now.
    private func wideLayout(compact: Bool) -> some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ShellSidebar(destination: $destination,
                         historySearch: $historySearch,
                         showRemoteAccess: $showRemoteAccess,
                         onSettings: {
                             settingsTab = .general
                             showSettings = true
                         },
                         onOpenInNewWindow: { openWindow(id: "chat", value: $0) })
                .environmentObject(appState)
                .environmentObject(sessions)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
                .onAppear { sidebarOnScreen = true }
                .onDisappear { sidebarOnScreen = false }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detailPane(compact: compact)
        }
        .navigationSplitViewStyle(.balanced)
        // Belt and braces: the removal has to be in scope of the split view
        // itself, not only of the window content that wraps it.
        .toolbar(removing: .sidebarToggle)
        .inspector(isPresented: $showInspector) {
            ShellInspector()
                .environmentObject(appState)
                .environmentObject(sessions)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .onChange(of: destination) { _, value in
            // Choosing a destination leaves Settings behind: they are two
            // views of the same window, never stacked.
            if value != .conversations { showSettings = false }
        }
    }

    /// The detail column: the conversation, plus whichever tool panel is
    /// docked beside it.
    @ViewBuilder
    private func detailPane(compact: Bool) -> some View {
        switch destination {
        case .bots:
            BotDashboardView()
                .environmentObject(appState)
                .environmentObject(sessions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .devices:
            RemoteAccessView(presentedAsSheet: false)
                .environmentObject(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .conversations:
            HStack(spacing: 0) {
                chatColumn
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
                        .frame(minWidth: 340, idealWidth: 460, maxWidth: 680, maxHeight: .infinity)
                }
                if showDiagnostics && !compact {
                    Divider()
                    DiagnosticsPanelView(onClose: { showDiagnostics = false })
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                }
            }
            .frame(minWidth: chatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Conversations

    /// Open a saved conversation. The record is already in hand, so no second
    /// decrypt is needed.
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

    private var chatColumn: some View {
        ChatView(controller: sessions, store: composerStore)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
    }



}
