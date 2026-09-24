import SwiftUI

/// Application delegate for lifecycle events SwiftUI's `App` can't express.
@MainActor
final class BeetCodeAppDelegate: NSObject, NSApplicationDelegate {
    /// One "New Window" request at a time: the menu action opens its window
    /// asynchronously, so a second request before the first lands would stack
    /// a second window on top.
    private var windowRequestInFlight = false
    /// Guards the post-reopen verification below the same way.
    private var reopenVerificationScheduled = false

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Clicking the dock icon asks for "the window". A minimized window
        // reports isVisible=false *and* canBecomeMain=false (measured live) —
        // and meanwhile still counts as "visible" for `flag` per AppKit — so
        // it has to be matched by its title bar and brought back, not be
        // joined by a second window the way it used to be.
        if let existing = Self.appWindow(in: sender) {
            sender.unhide(nil)
            sender.activate(ignoringOtherApps: true)
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return false
        }
        // No window at all: let the standard reopen try first and verify a
        // moment later. Asking for a window immediately raced slow launches
        // (measured: the WindowGroup window can take seconds on a loaded
        // machine), which is how a pair of windows appeared.
        verifyReopenCreatesWindow()
        return true
    }

    /// The sidebar is the window's leading edge, not a card floating over it.
    ///
    /// macOS 26 draws a split-view sidebar as an inset rounded panel over the
    /// window background. With a dark or OLED canvas that leaves black gutters
    /// between the navigation column and the window's own edges — the column
    /// reads as a detached slab with a border of its own. This app's navigation
    /// column is a full-height surface flush with the window mask, so the
    /// floating appearance is switched off before any window exists.
    ///
    /// Registered rather than written: a user who prefers the floating panel
    /// can still set the same key in the global domain and win.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSSplitViewItemSidebarDefaultsToFloatingAppearance": false,
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous best-effort: engines' async unload path can't run on
        // the way out, so registered child processes (llama-server) get a
        // plain SIGTERM here.
        ChildProcessRegistry.terminateAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A state restoration that comes back empty leaves the app with no
        // window at all: AppKit asks SwiftUI's restorer for the saved window,
        // gets nothing (logged as `window=0x0`), and no window is ever
        // created — the app runs invisibly, which reads as "the app didn't
        // open". The reopen path above recovers a windowless app, so launch
        // gets the same net, later: a slow launch can legitimately take
        // seconds to put its window up, and acting too early is how a pair of
        // windows appears.
        // Cold launches under UI automation or system load can take longer
        // than five seconds to create the WindowGroup window. Recovering at
        // five races that first window and leaves two overlapping windows.
        verifyReopenCreatesWindow(after: 12.0)
    }

    /// Falls back to opening a window only if the app is still windowless a
    /// beat after a reopen — by then a WindowGroup window would exist if one
    /// were coming, so this cannot duplicate it.
    private func verifyReopenCreatesWindow(after delay: TimeInterval = 2.0) {
        guard !reopenVerificationScheduled else { return }
        reopenVerificationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reopenVerificationScheduled = false
            let application = NSApplication.shared
            guard Self.appWindow(in: application) == nil,
                  !self.windowRequestInFlight else { return }
            self.windowRequestInFlight = true
            // Ask AppKit's own route first: SwiftUI's WindowGroup answers
            // `newWindowForTab:` with a window. Matching a menu item titled
            // "New Window" — what this used to do — silently did nothing here,
            // because the app replaces the standard new-item group, so a
            // windowless launch stayed windowless.
            let opened = application.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            var route = "newWindowForTab"
            if !opened, let item = Self.newWindowItem(in: application.mainMenu), let action = item.action {
                application.sendAction(action, to: item.target, from: item)
                route = "menu item \(item.title)"
            }
            application.activate(ignoringOtherApps: true)
            DiagnosticsCenter.shared.record(
                .system, opened ? "Opened a window that was missing" : "Window recovery: no route",
                detail: "via \(route)")
        }
    }

    /// The app's own window(s): the main window or a detached chat. Matched
    /// on the title bar because a minimized window reports isVisible=false
    /// *and* canBecomeMain=false (measured live) — the old on-screen-only
    /// test saw a minimized app as windowless, which is exactly how a dock
    /// click used to end up opening a second window beside it.
    private static func appWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { $0.styleMask.contains(.titled) }
    }

    static func newWindowItem(in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == "New Window", item.action != nil { return item }
            if let match = newWindowItem(in: item.submenu) { return match }
        }
        return nil
    }

}

/// Maps the persisted appearance setting onto SwiftUI. `nil` means "follow
/// the OS"; `.light`/`.dark` force it.
extension AppAppearance {
    /// Resolve the request before translating System into a nil color scheme.
    static func resolved(saved: Self, override: Self?) -> Self {
        override ?? saved
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .oled: .dark
        }
    }
}

@main
struct BeetCodeApp: App {
    // Termination hook: SIGTERM any registered child processes (llama-server
    // backing a resident GGUF model) so they never outlive the app.
    @NSApplicationDelegateAdaptor(BeetCodeAppDelegate.self) private var appDelegate
    // AppState is an ObservableObject the app OWNS: StateObject guarantees
    // exactly one instance across view updates.
    @StateObject private var appState = AppState()
    // Observing the settings store re-applies the color scheme live when the
    // user changes Appearance in Settings.
    @ObservedObject private var settings = SettingsStore.shared

    init() {}

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                // Un-migrated text defaults to engineered system sans; prose
                // call sites opt into the user's Typeface via `.appProse`.
                .tint(Theme.accent)
                .environmentObject(appState)
                .environmentObject(appState.sessions)
                // A real working minimum: sidebar + chat + docked panel need room.
                .frame(minWidth: 520, minHeight: 640)
                .preferredColorScheme(AppAppearance.resolved(saved: settings.appearance,
                    override: DesignPreview.appearanceOverride).colorScheme)
                // Keep AppKit's appearance in sync so Theme's dynamic NSColors
                // resolve to the forced scheme, not just the OS one.
                .onChange(of: AppAppearance.resolved(saved: settings.appearance,
                                                    override: DesignPreview.appearanceOverride),
                          initial: true) { _, appearance in
                    Theme.applyAppearance(appearance)
                }
                // Palette / typeface / text size live in Theme globals that
                // SwiftUI cannot observe, so mirroring them from a `.task`
                // would land a frame late and never force a redraw.
                .modifier(ThemeSync(palette: settings.accentPalette,
                                    typeface: settings.typeface,
                                    textSize: settings.textSize))
                .task {
                    DiagnosticsCenter.shared.record(
                        .system, "App launched",
                        detail: "appearance: \(settings.appearance.rawValue) · palette: \(settings.accentPalette.rawValue)")
                    await QwenQ217RelaunchValidation.runIfRequested(appState: appState)
                }
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        // A separated conversation: dragging a tab out of the main strip
        // opens that chat in its own window with its own session controller.
        WindowGroup("Chat", id: "chat", for: UUID.self) { $sessionID in
            if let sessionID {
                DetachedChatWindow(sessionID: sessionID)
                    .environmentObject(appState)
                    .preferredColorScheme(AppAppearance.resolved(saved: settings.appearance,
                        override: DesignPreview.appearanceOverride).colorScheme)
            }
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            // ⌘M is macOS's standard Minimize shortcut; Model Manager gets
            // ⇧⌘M so neither command fights the system.
            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("Stop Agent") {
                    NotificationCenter.default.post(name: .stopAgent, object: nil)
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.stopShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.stopShortcut).eventModifiers)
                Button("Send") {
                    NotificationCenter.default.post(name: .sendMessage, object: nil)
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.sendShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.sendShortcut).eventModifiers)
                Button("Toggle Plan Mode") {
                    settings.planMode.toggle()
                }
                .keyboardShortcut(
                    ShortcutBinding(rawValue: settings.planShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.planShortcut).eventModifiers)
                Button("Model Manager…") {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])
                Divider()
                Button("Search Chats") {
                    NotificationCenter.default.post(name: .focusChatSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            CommandGroup(after: .help) {
                Button("System Readiness…") {
                    NotificationCenter.default.post(name: .openSystemReadiness, object: nil)
                }
            }
        }

    }
}

/// Developer-only fresh-process validation for Q2.17. The normal app never
/// sets this environment variable, so launch and chat behavior are unchanged.
@MainActor
private enum QwenQ217RelaunchValidation {
    private struct Manifest: Decodable {
        let fixtureFormatVersion: String
        let fixtures: [String: Entry]
    }

    private struct Entry: Decodable {
        let path: String
    }

    private struct Fixture: Decodable {
        let promptTokenIDs: [Int]
        let generatedTokenIDs: [Int]
        let stopReason: String
    }

    private struct Result: Encodable {
        let status: String
        let fixtureFormat: String
        let loadedModelID: String?
        let generatedTokens: Int
        let expectedTokens: Int
        let firstDifference: Int?
        let stopReason: String?
        let explicitCalls: Int
        let fusedCalls: Int
    }

    static func runIfRequested(appState: AppState) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEETCODE_QWEN35_Q217_RELAUNCH_FIXTURE"] == "1",
              let fixturePath = environment["BEETCODE_QWEN35_ORACLE_FIXTURE"],
              !fixturePath.isEmpty else { return }
        let reportPath = environment["BEETCODE_QWEN35_Q217_RELAUNCH_REPORT"]
            ?? "/tmp/qwen35-q217-relaunch-validation.json"
        do {
            let (manifest, fixture) = try loadFixture(at: URL(fileURLWithPath: fixturePath))
            guard manifest.fixtureFormatVersion == "qwen35-k8-q216-explicit-reference-v1" else {
                throw EngineError.loadFailed("Q2.17 relaunch fixture format is not the accepted Q2.16 explicit fixture.")
            }
            guard let pool = appState.engine.enginePool else {
                throw EngineError.loadFailed("Q2.17 relaunch validation requires the pooled local engine.")
            }
            var qwen: QwenStreamingEngine?
            for _ in 0..<180 {
                if case .ready = appState.enginePhase,
                   appState.activeModelID == QwenStreamArtifact.modelID,
                   let candidate = await pool.debugQwenEngine(modelID: QwenStreamArtifact.modelID) {
                    qwen = candidate
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard let qwen else {
                throw EngineError.loadFailed("Q2.17 relaunch validation timed out waiting for restored Qwen readiness.")
            }
            let counters = StreamQwen35AttentionDiagnosticCounters()
            // Q2.18: exercise the shipping production default rather than a
            // hardcoded strategy, so a fresh-process relaunch proves the path
            // users actually get.
            let production = await qwen.debugAttentionStrategy()
            guard production == .productionDefault else {
                throw EngineError.loadFailed(
                    "Q2.18 relaunch probe expected the production default \(StreamQwen35AttentionStrategy.productionDefault.rawValue) but found \(production.rawValue)")
            }
            let run = try await qwen.debugGreedy(
                tokenIDs: fixture.promptTokenIDs,
                maxTokens: fixture.generatedTokenIDs.count,
                attentionStrategy: .productionDefault,
                diagnosticCounters: counters,
                includeFinalStateProbe: false)
            let difference = firstDifference(run.generatedTokenIDs, fixture.generatedTokenIDs)
            let result = Result(
                status: difference == nil && run.stopReason == fixture.stopReason ? "passed" : "failed",
                fixtureFormat: manifest.fixtureFormatVersion,
                loadedModelID: await qwen.loadedModelID,
                generatedTokens: run.generatedTokenIDs.count,
                expectedTokens: fixture.generatedTokenIDs.count,
                firstDifference: difference,
                stopReason: run.stopReason,
                explicitCalls: counters.explicitInvocations,
                fusedCalls: counters.fusedInvocations)
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            if result.status == "failed" {
                throw EngineError.loadFailed("Q2.17 relaunch fixture diverged at \(difference.map(String.init) ?? "stop")")
            }
        } catch {
            let failure = Result(
                status: "failed: \(error)", fixtureFormat: "unknown", loadedModelID: appState.activeModelID,
                generatedTokens: 0, expectedTokens: 0, firstDifference: nil, stopReason: nil,
                explicitCalls: 0, fusedCalls: 0)
            try? JSONEncoder().encode(failure).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func loadFixture(at source: URL) throws -> (Manifest, Fixture) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen35-q217-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", source.path, "-d", temporary.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw EngineError.loadFailed("Q2.17 relaunch fixture could not be extracted.")
        }
        let manifestURL = temporary.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard let entry = manifest.fixtures["primary"] else {
            throw EngineError.loadFailed("Q2.17 relaunch fixture has no primary entry.")
        }
        let fixtureURL = temporary.appendingPathComponent(entry.path)
        return (manifest, try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)))
    }

    private static func firstDifference(_ lhs: [Int], _ rhs: [Int]) -> Int? {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] { return index }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
    }
}

extension Notification.Name {
    static let openModelManager = Notification.Name("com.beetcode.openModelManager")
    static let openProviderSettings = Notification.Name("com.beetcode.openProviderSettings")
    static let openRemoteAccess = Notification.Name("com.beetcode.openRemoteAccess")
    static let toggleBrowserPanel = Notification.Name("com.beetcode.toggleBrowserPanel")
    static let toggleSimulatorPanel = Notification.Name("com.beetcode.toggleSimulatorPanel")
    static let toggleDiagnosticsPanel = Notification.Name("com.beetcode.toggleDiagnosticsPanel")
    static let gitStatus = Notification.Name("com.beetcode.gitStatus")
    static let gitDiff = Notification.Name("com.beetcode.gitDiff")
    static let undoCheckpoint = Notification.Name("com.beetcode.undoCheckpoint")
    static let exportChatMarkdown = Notification.Name("com.beetcode.exportChatMarkdown")
    static let exportChatJSON = Notification.Name("com.beetcode.exportChatJSON")
    static let exportTaskBundle = Notification.Name("com.beetcode.exportTaskBundle")
    static let newChat = Notification.Name("com.beetcode.newChat")
    static let stopAgent = Notification.Name("com.beetcode.stopAgent")
    static let sendMessage = Notification.Name("com.beetcode.sendMessage")
    static let sessionTitleChanged = Notification.Name("com.beetcode.sessionTitleChanged")
    /// A chat was deleted. Open tabs drop the id so a deleted conversation
    /// cannot be selected (and then silently re-saved) from the tab strip.
    static let sessionDeleted = Notification.Name("com.beetcode.sessionDeleted")
    /// A paired device changed the session list (delete or rename). The
    /// sidebar keeps its own decrypted snapshot, which nothing else invalidates.
    static let remoteSessionsChanged = Notification.Name("com.beetcode.remoteSessionsChanged")
    static let openWorkspace = Notification.Name("com.beetcode.openWorkspace")
    static let openSystemReadiness = Notification.Name("com.beetcode.openSystemReadiness")
    static let focusChatSearch = Notification.Name("com.beetcode.focusChatSearch")
    static let openBotsDashboard = Notification.Name("com.beetcode.openBotsDashboard")
    static let openAssistantHome = Notification.Name("com.beetcode.openAssistantHome")
    static let openAppSettings = Notification.Name("com.beetcode.openAppSettings")
    /// Open one saved conversation by id (object: UUID) — posted by the
    /// history popover so any surface can request a chat without owning the
    /// window's tab logic.
    static let openSessionRecord = Notification.Name("com.beetcode.openSessionRecord")
    static let importChats = Notification.Name("com.beetcode.importChats")
    static let importBundle = Notification.Name("com.beetcode.importBundle")
}

/// Mirrors the user's theme settings into `Theme`'s draw-time globals. The
/// mirroring happens in `body` — on the main actor, before any descendant
/// resolves a font or color — which is exactly the contract those
/// `nonisolated(unsafe)` globals document.
///
/// Deliberately does NOT `.id()` the subtree to force a redraw: that would
/// give `MainWindowView` a new identity and reset every piece of its `@State`,
/// so changing the accent from inside Settings would close Settings. The
/// redraw comes from the surfaces that already observe `SettingsStore` —
/// `MainWindowView` and `SettingsView` both do — which re-create their
/// children with the new values.
private struct ThemeSync: ViewModifier {
    let palette: AccentPalette
    let typeface: AppTypeface
    let textSize: AppTextSize

    func body(content: Content) -> some View {
        Theme.currentPalette = palette
        Theme.currentTypeface = typeface
        Theme.currentTextSize = textSize
        return content
    }
}
