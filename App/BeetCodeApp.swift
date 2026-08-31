import SwiftUI

/// Application delegate for lifecycle events SwiftUI's `App` can't express.
@MainActor
final class BeetCodeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI can restore a previous "all windows closed" state and leave
        // this regular GUI app running with only its menu bar. Defer one turn
        // so WindowGroup gets the first chance to create its scene, then use
        // the scene's own New Window command when no window exists.
        DispatchQueue.main.async {
            Self.openMainWindowIfNeeded(in: NSApplication.shared)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            Self.openMainWindowIfNeeded(in: sender)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous best-effort: engines' async unload path can't run on
        // the way out, so registered child processes (llama-server) get a
        // plain SIGTERM here.
        ChildProcessRegistry.terminateAll()
    }

    private static func openMainWindowIfNeeded(in application: NSApplication) {
        guard application.windows.isEmpty,
              let item = application.mainMenu?
                .item(withTitle: "File")?
                .submenu?
                .item(withTitle: "New Window"),
              let action = item.action else { return }
        application.sendAction(action, to: item.target, from: item)
        application.activate(ignoringOtherApps: true)
    }
}

/// Maps the persisted appearance setting onto SwiftUI. `nil` means "follow
/// the OS"; `.light`/`.dark` force it; `.beet` forces dark chrome (its
/// beet-tinted neutrals come from Theme, not the system scheme).
extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .beet: .dark
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

    init() {
        // CLI early-exit (Phase 22): `beetcode intel <command>` runs the
        // intelligence CLI and terminates before any UI or app state boots.
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "intel" {
            let code = IntelligenceCLIRunner.run(Array(arguments.dropFirst(2)))
            Foundation.exit(code)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                // Root face for text that never went through AppFont/.app().
                .fontDesign(Font.resolvedDesign(.serif))
                .tint(Theme.accent)
                .environmentObject(appState)
                .environmentObject(appState.sessions)
                // A real working minimum: sidebar + chat + docked panel need room.
                .frame(minWidth: 520, minHeight: 640)
                .preferredColorScheme(settings.appearance.colorScheme)
                // Keep AppKit's appearance in sync so Theme's dynamic NSColors
                // resolve to the forced scheme, not just the OS one.
                .task(id: settings.appearance) { Theme.applyAppearance(settings.appearance) }
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
                }
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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
    /// A paired device changed the session list (delete or rename). The
    /// sidebar keeps its own decrypted snapshot, which nothing else invalidates.
    static let remoteSessionsChanged = Notification.Name("com.beetcode.remoteSessionsChanged")
    static let openWorkspace = Notification.Name("com.beetcode.openWorkspace")
    static let openSystemReadiness = Notification.Name("com.beetcode.openSystemReadiness")
    static let focusChatSearch = Notification.Name("com.beetcode.focusChatSearch")
    static let openBotsDashboard = Notification.Name("com.beetcode.openBotsDashboard")
    static let openAssistantHome = Notification.Name("com.beetcode.openAssistantHome")
    static let openAppSettings = Notification.Name("com.beetcode.openAppSettings")
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
