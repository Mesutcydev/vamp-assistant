import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionNavigationView: View {
    let store: RemoteStore
    @State private var path: [UUID] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    SessionListView(store: store, onOpen: { path = [$0] }, selectedSessionID: path.last)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: {
                    NavigationStack {
                        if let sessionID = path.last {
                            ConversationView(store: store, sessionID: sessionID)
                        } else {
                            ContentUnavailableView("Choose a conversation", systemImage: "text.alignleft",
                                description: Text("Your chats stay in the conversation library."))
                                .foregroundStyle(RemoteInstrument.ink)
                                .background(RemoteInstrument.reading)
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    SessionListView(store: store, onOpen: { path.append($0) })
                        .navigationDestination(for: UUID.self) { ConversationView(store: store, sessionID: $0) }
                }
            }
        }
            .alert(store.errorTitle, isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
            .task(id: RemoteNotificationCenter.shared.pendingNavigation) {
                guard let target = RemoteNotificationCenter.shared.pendingNavigation else { return }
                guard await store.openNotification(target) else {
                    if RemoteNotificationCenter.shared.pendingNavigation == target {
                        RemoteNotificationCenter.shared.pendingNavigation = nil
                    }
                    return
                }
                if path.last != target.sessionID { path = [target.sessionID] }
                if RemoteNotificationCenter.shared.pendingNavigation == target {
                    RemoteNotificationCenter.shared.pendingNavigation = nil
                }
            }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct SessionListView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    var selectedSessionID: UUID? = nil
    @Environment(\.remoteAppearance) private var appearance
    @State private var search = ""
    @State private var showStartSession = false
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var showControl = false
    @State private var showBotRuns = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var startBotID = ""
    @State private var deferredSessionID: UUID?
    private var visible: [RemoteSessionSummary] { search.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.workspace.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ZStack {
            RemoteBackdrop()
            VStack(spacing: 0) {
                SessionControlHeader(
                    store: store,
                    search: $search,
                    onBots: { showBotRuns = true },
                    onControl: { showControl = true },
                    onChooseComputer: { showComputers = true })
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if visible.isEmpty {
                            RemoteEmptySessions(isSearching: !search.isEmpty, isConnected: store.isConnected,
                                onStart: { startBotID = ""; showStartSession = true },
                                onClearSearch: { search = "" })
                        } else {
                            SessionSectionHeader(count: visible.count)
                            SessionGroup(sessions: visible, store: store, onOpen: onOpen, selectedSessionID: selectedSessionID)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: RemoteInstrument.contentWidth)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { try? await store.refresh() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: {
                        startBotID = ""
                        showStartSession = true
                    }) {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.isConnected)
                    .accessibilityLabel("Start a new session")
                    Button { Task { try? await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Refresh sessions")
                    Button { showSharing = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share clipboard or files")
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $showStartSession, onDismiss: openDeferredSession) {
                StartSessionSheet(store: store, initialBotID: startBotID) { sessionID in
                    deferredSessionID = sessionID
                    showStartSession = false
                }
            }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
            .sheet(isPresented: $showSettings) {
                RemoteSettingsSheet(
                    store: store,
                    onSwitchComputer: { showComputers = true },
                    onDiagnostics: { showDiagnostics = true })
            }
            .sheet(isPresented: $showBotRuns, onDismiss: openDeferredSession) {
                RemoteBotsView(store: store) { sessionID in
                    deferredSessionID = sessionID
                    showBotRuns = false
                }
            }
            .sheet(isPresented: $showComputers) { ComputerSwitcherSheet(store: store) }
            .sheet(isPresented: $showDiagnostics) {
                NavigationStack {
                    RemoteDiagnosticsSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showDiagnostics = false }
                            }
                        }
                }
            }
            .fullScreenCover(isPresented: $showControl) { RemoteControlView(store: store) }
    }

    private func openDeferredSession() {
        guard let sessionID = deferredSessionID else { return }
        deferredSessionID = nil
        // Navigation changes issued during sheet dismissal are occasionally
        // dropped by SwiftUI. The dismissal completion is the first stable
        // point at which the stack can accept the destination.
        Task { @MainActor in
            await Task.yield()
            onOpen(sessionID)
        }
    }
}

// MARK: - Bots

/// A small non-blocking notice. Background failures and the disconnected state
/// used to be invisible here — the screen just rendered a full form where every
/// control was dead and nothing said why.
struct SessionControlHeader: View {
    @Bindable var store: RemoteStore
    @Binding var search: String
    var onBots: (() -> Void)? = nil
    var onControl: (() -> Void)? = nil
    var onChooseComputer: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("VAMP / REMOTE")
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(2)
                Spacer()
                RemoteSignal(color: store.isConnected ? RemoteInstrument.green : RemoteInstrument.orange,
                             isActive: store.isConnecting || store.isRefreshing)
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            let clusterLayout = horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            clusterLayout {
            VStack(alignment: .leading, spacing: 8) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            headerLayout {
                Text("Vamp Assistant")
                    .font(RemoteInstrument.TypeStyle.title)
                    .fontDesign(.default)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
                Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isConnected ? RemoteInstrument.green : BeetTheme.secondaryText(appearance))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Button {
                if !store.isConnected { Task { await store.connectSaved() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(store.isConnected ? RemoteInstrument.green : RemoteInstrument.secondaryInk)
                    Text(store.connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    if !store.isConnected {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isConnected)
            .accessibilityLabel(store.isConnected ? "Mac connected. \(store.connectionSubtitle)" : "\(store.connectionLabel). \(store.connectionSubtitle). Retry connection")
            }
            let headerActions: [InstrumentAction] = [
                onBots.map {
                    InstrumentAction(id: "bots", title: "Bots", symbol: "person.3",
                                     index: "01", action: $0)
                },
                onControl.map {
                    InstrumentAction(id: "control", title: "Control Mac", symbol: "display",
                                     index: "02",
                                     secondary: store.isConnecting ? "CONNECTING" :
                                         (store.isConnected ? store.connectionSubtitle : "RECONNECT"),
                                     ledColor: store.isConnected
                                         ? RemoteInstrument.green
                                         : (store.isConnecting ? RemoteInstrument.orange : RemoteInstrument.secondaryInk),
                                     ledActive: store.isConnecting || store.isRefreshing,
                                     action: $0)
                },
                onChooseComputer.map {
                    InstrumentAction(id: "choose", title: "Computer",
                                     symbol: "desktopcomputer.and.macbook",
                                     index: "03",
                                     secondary: store.activeComputerName,
                                     action: $0)
                }
            ].compactMap { $0 }
            if !headerActions.isEmpty {
                InstrumentActionBank(actions: headerActions,
                                     vertical: dynamicTypeSize.isAccessibilitySize)
            }
            }
            SearchField(text: $search)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(BeetTheme.readingSurface(appearance))
        .overlay(alignment: .bottom) {
            Rectangle().fill(BeetTheme.line(appearance)).frame(height: 0.75)
        }
    }

}

struct SessionSectionHeader: View {
    let count: Int
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack {
            Text("SESSIONS")
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .tracking(1.1)
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 10)
    }
}

struct SessionGroup: View {
    let sessions: [RemoteSessionSummary]
    var store: RemoteStore? = nil
    var onOpen: ((UUID) -> Void)? = nil
    var selectedSessionID: UUID? = nil
    @State private var pendingDelete: RemoteSessionSummary?
    @State private var renaming: RemoteSessionSummary?
    @State private var renameDraft = ""

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(sessions) { session in
                Group {
                    if let onOpen {
                        Button { onOpen(session.id) } label: { SessionRow(session: session) }
                    } else {
                        NavigationLink(value: session.id) { SessionRow(session: session) }
                    }
                }
                    .buttonStyle(RemoteSessionButtonStyle())
                    .background(selectedSessionID == session.id ? RemoteInstrument.recess : .clear)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(RemoteInstrument.orange)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .opacity(selectedSessionID == session.id ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .accessibilityAddTraits(selectedSessionID == session.id ? .isSelected : [])
                    .contextMenu {
                        if store != nil {
                            Button("Rename", systemImage: "pencil") {
                                renameDraft = session.title
                                renaming = session
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = session
                            }
                        }
                    }
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete) { session in
                Button("Delete", role: .destructive) {
                    Task {
                        if await store?.deleteSession(session.id) == true {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                // Same wording as the Mac: this removes the file, not a copy.
                Text("“\(session.title)” is removed from your Mac. This cannot be undone.")
            }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Chat name", text: $renameDraft)
            Button("Rename") {
                guard let session = renaming else { return }
                let title = renameDraft
                Task { _ = await store?.renameSession(session.id, title: title) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a short name that is easy to find in history.")
        }
    }
}

struct RemoteReasoningSelector: View {
    let modelName: String
    let efforts: [String]
    let defaultEffort: String?
    @Binding var selection: String?
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Reasoning", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(selection ?? defaultEffort ?? "Auto")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
            }
            Text("Choose how much thinking \(modelName) should use.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    reasoningButton("Auto", value: nil)
                    ForEach(efforts, id: \.self) { effort in
                        reasoningButton(effort.capitalized, value: effort)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(13)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(BeetTheme.line(appearance)) }
    }

    private func reasoningButton(_ title: String, value: String?) -> some View {
        let selected = selection == value
        return Button(title) { selection = value }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : BeetTheme.secondaryText(appearance))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                selected ? BeetTheme.accent : BeetTheme.surfaceStrong(appearance),
                in: Capsule())
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SearchField: View {
    @Environment(\.remoteAppearance) private var appearance
    @Binding var text: String
    var placeholder = "Search sessions"
    var body: some View {
        HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(BeetTheme.secondaryText(appearance)).accessibilityHidden(true); TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(RemoteInstrument.secondaryInk)).textInputAutocapitalization(.never); if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Clear search").buttonStyle(.plain).foregroundStyle(BeetTheme.secondaryText(appearance)) } }
            .padding(.horizontal, 13).frame(minHeight: 44)
            .remoteRecess()
    }
}

struct SessionRow: View {
    let session: RemoteSessionSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.isRunning ? RemoteInstrument.green : .clear)
                .frame(width: 6, height: 6)
                .padding(.top, 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(session.title).font(.body.weight(.medium))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize {
                        SessionTimestamp(updatedAt: session.updatedAt)
                    }
                }
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Text(session.workspace.isEmpty ? "CHAT" : session.workspace)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Text("\(session.messageCount) messages")
                    if session.isRunning { Text(session.phase).foregroundStyle(RemoteInstrument.green) }
                }
                .font(.caption.monospaced())
                .foregroundStyle(RemoteInstrument.secondaryInk)
                if dynamicTypeSize.isAccessibilitySize { SessionTimestamp(updatedAt: session.updatedAt) }
            }
        }
        .foregroundStyle(RemoteInstrument.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(session.isRunning ? [.isButton, .updatesFrequently] : .isButton)
    }
}

private struct SessionTimestamp: View {
    let updatedAt: TimeInterval
    var body: some View {
        Text(Date(timeIntervalSince1970: updatedAt).formatted(.relative(presentation: .named)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(RemoteInstrument.secondaryInk)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct RemoteSessionButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? RemoteInstrument.recess : Color.clear)
            .overlay(alignment: .bottom) { VampHairline() }
            .animation(reduceMotion ? nil : RemoteInstrument.motion, value: configuration.isPressed)
    }
}

/// Flat list/disclosure rows use immediate tonal feedback. Physical action
/// buttons use RemoteKeyButtonStyle so rows never acquire decorative shells.
struct RemotePressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? RemoteInstrument.recess.opacity(0.55) : .clear)
            .opacity(isEnabled ? 1 : 0.48)
    }
}

struct RemoteEmptySessions: View {
    let isSearching: Bool
    var isConnected = true
    var onStart: (() -> Void)? = nil
    var onClearSearch: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "rectangle.stack.badge.plus")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(BeetTheme.accentBright)
                .accessibilityHidden(true)
            Text(isSearching ? "No matching sessions" : "No sessions yet").font(.headline)
            Text(isSearching
                 ? "Try another title or project name."
                 : "Start a chat, or pick a bot from the Bots screen. You can also continue a conversation from your Mac.")
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .multilineTextAlignment(.center)
            // The copy described an action but never offered one.
            if isSearching, let onClearSearch {
                Button("Clear search", action: onClearSearch)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    .controlSize(.large)
            } else if !isSearching, let onStart {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onStart()
                } label: {
                    Label("Start a chat", systemImage: "plus.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 180, minHeight: 46)
                }
                .buttonStyle(RemotePrimaryButtonStyle())
                .disabled(!isConnected)
                .accessibilityHint(isConnected ? "" : "Connect to your Mac first")
                .padding(.top, 2)
            }
        }
        .padding(RemoteInstrument.Space.section)
        .frame(maxWidth: .infinity)

    }
}
