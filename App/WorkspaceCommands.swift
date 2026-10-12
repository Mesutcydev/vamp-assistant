import SwiftUI

/// Window-scoped actions keep shortcuts from reaching every open chat.
struct WorkspaceActions {
    var newChat: () -> Void
    var openProject: () -> Void
    var settings: () -> Void
    var models: () -> Void
    var devices: () -> Void
    var search: () -> Void
    var palette: () -> Void
    var openPanel: (WorkspacePanel) -> Void
    var resetLayout: () -> Void
    var send: () -> Void
    var stop: () -> Void
    var togglePlan: () -> Void
    var canSend: Bool
    var isRunning: Bool
    var hasProject: Bool
    var activePaneTitle: String
    var canSplitPane: Bool
    var paneGroups: [DockGroup]
    var splitPane: (DockPlacement) -> Void
    var joinGroup: (UUID) -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }
extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

struct WorkspaceAppCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    @ObservedObject private var settings = SettingsStore.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.settings() }.keyboardShortcut(",", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandGroup(after: .newItem) {
            Button("New Chat") { actions?.newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("Open Project…") { actions?.openProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Send / Queue Follow-up") { actions?.send() }
                .keyboardShortcut(ShortcutBinding(rawValue: settings.sendShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.sendShortcut).eventModifiers)
                .disabled(actions?.canSend != true)
            Button("Stop") { actions?.stop() }
                .keyboardShortcut(ShortcutBinding(rawValue: settings.stopShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.stopShortcut).eventModifiers)
                .disabled(actions?.isRunning != true)
            Button("Toggle Plan Mode") { actions?.togglePlan() }
                .keyboardShortcut(ShortcutBinding(rawValue: settings.planShortcut).keyEquivalent,
                    modifiers: ShortcutBinding(rawValue: settings.planShortcut).eventModifiers)
        }
        CommandMenu("Workspace") {
            Button("Command Palette…") { actions?.palette() }.keyboardShortcut("k", modifiers: .command)
            Button("Search Chats") { actions?.search() }.keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Models & Connections…") { actions?.models() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Devices") { actions?.devices() }
            Divider()
            ForEach([WorkspacePanel.browser, .changes, .simulator, .context, .activity, .diagnostics, .session]) { panel in
                Button(panel.title) { actions?.openPanel(panel) }
                    .disabled(actions == nil || (panel.needsProject && actions?.hasProject != true))
            }
            Divider()
            Menu("Arrange \(actions?.activePaneTitle ?? "Pane")") {
                ForEach(DockPlacement.allCases.filter { $0 != .center }, id: \.rawValue) { placement in
                    Button(placement.title) { actions?.splitPane(placement) }.disabled(actions?.canSplitPane != true)
                }
                Menu("Move to group") {
                    ForEach(actions?.paneGroups ?? []) { group in
                        Button(group.selected.title) { actions?.joinGroup(group.id) }
                    }
                }
            }
            Button("Reset Layout") { actions?.resetLayout() }
        }
        CommandGroup(after: .help) {
            Button("System Readiness…") { NotificationCenter.default.post(name: .openSystemReadiness, object: nil) }
        }
    }
}

struct WorkspaceCommandPalette: View {
    let actions: WorkspaceActions
    let onClose: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searchFocused: Bool

    private struct Command: Identifiable {
        let id: String
        let symbol: String
        let shortcut: String
        let perform: () -> Void
    }
    private var commands: [Command] {
        var items: [Command] = [
            .init(id: "New chat", symbol: "square.and.pencil", shortcut: "⌘N", perform: actions.newChat),
            .init(id: "Search chats", symbol: "magnifyingglass", shortcut: "⌘F", perform: actions.search),
            .init(id: "Open project…", symbol: "folder", shortcut: "⇧⌘O", perform: actions.openProject),
            .init(id: "Models & connections", symbol: "cpu", shortcut: "⇧⌘M", perform: actions.models),
            .init(id: "Devices", symbol: "laptopcomputer.and.iphone", shortcut: "", perform: actions.devices),
            .init(id: "Settings", symbol: "gearshape", shortcut: "⌘,", perform: actions.settings),
        ]
        for panel in [WorkspacePanel.browser, .changes, .simulator, .context, .activity, .diagnostics, .session]
            where !panel.needsProject || actions.hasProject {
            items.append(.init(id: "Open \(panel.title)", symbol: panel.symbol, shortcut: "",
                               perform: { actions.openPanel(panel) }))
        }
        items.append(.init(id: "Reset layout", symbol: "rectangle.split.2x1", shortcut: "", perform: actions.resetLayout))
        if actions.isRunning { items.append(.init(id: "Stop work", symbol: "stop", shortcut: "Esc", perform: actions.stop)) }
        return items.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Search actions…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { if commands.indices.contains(selected) { run(commands[selected]) } }
                    .accessibilityIdentifier("command-palette-search")
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            Button { run(command) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: command.symbol).frame(width: 20)
                                    Text(command.id)
                                    Spacer()
                                    Text(command.shortcut).foregroundStyle(Theme.textSecondary)
                                }
                                .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selected == index ? Theme.accent.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .id(index)
                        }
                        if commands.isEmpty { ContentUnavailableView.search(text: query).frame(height: 160) }
                    }.padding(12)
                }
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }
        .frame(minWidth: 360, idealWidth: 520, maxWidth: 640, minHeight: 280, idealHeight: 460)
        .background(Theme.surface)
        .foregroundStyle(Theme.textPrimary)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) { selected = min(commands.count - 1, selected + 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
    }
    private func run(_ command: Command) { onClose(); command.perform() }
}

private struct WorkspaceWindowIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var workspaceWindowID: String? {
        get { self[WorkspaceWindowIDKey.self] }
        set { self[WorkspaceWindowIDKey.self] = newValue }
    }
}
extension NotificationCenter {
    func postWorkspace(name: Notification.Name, object: Any?, windowID: String?) {
        post(name: name, object: object, userInfo: windowID.map { ["workspaceWindowID": $0] })
    }
}
