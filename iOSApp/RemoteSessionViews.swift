import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionNavigationView: View {
    let store: RemoteStore
    @State private var path: [UUID] = []
    var body: some View {
        NavigationStack(path: $path) {
            SessionListView(store: store, onOpen: { path.append($0) })
                .navigationDestination(for: UUID.self) { ConversationView(store: store, sessionID: $0) }
        }
            .alert(store.errorTitle, isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
            .keyboardDismissToolbar()
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
    @Environment(\.remoteAppearance) private var appearance
    @State private var search = ""
    @State private var showStartSession = false
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var showControl = false
    @State private var showAppStream = false
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
                    onControl: { showControl = true },
                    onSettings: { showSettings = true },
                    onStart: {
                        startBotID = ""
                        showStartSession = true
                    })
                ScrollView {
                    VStack(spacing: 16) {
                        SessionSectionHeader(count: visible.count)
                        if visible.isEmpty {
                            RemoteEmptySessions(
                                isSearching: !search.isEmpty,
                                isConnected: store.isConnected,
                                onStart: {
                                    startBotID = ""
                                    showStartSession = true
                                },
                                onClearSearch: { search = "" })
                        }
                        else { SessionGroup(sessions: visible, store: store) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { try? await store.refresh() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showBotRuns = true } label: { Image(systemName: "person.3.sequence.fill") }
                        .accessibilityLabel("Specialist bots")
                    Button { showComputers = true } label: {
                        Image(systemName: "desktopcomputer.and.macbook")
                    }
                    .accessibilityLabel("Choose a Vamp Assistant computer")
                    Button { showSharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share clipboard or files")
                    // Diagnostics and unpairing moved into Settings, which left
                    // this menu holding one item — a menu wrapping a single
                    // action is just an extra tap.
                    Button { showAppStream = true } label: { Image(systemName: "macwindow.on.rectangle") }
                        .accessibilityLabel("App Stream")
                }
            }
            .sheet(isPresented: $showStartSession, onDismiss: openDeferredSession) {
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
            .fullScreenCover(isPresented: $showAppStream) {
                RemoteControlView(store: store, sourceMode: .application)
            }
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
    let onControl: () -> Void
    let onSettings: () -> Void
    let onStart: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vamp Assistant")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Circle()
                    .fill(store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: (store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.35),
                        radius: 4)
                Button {
                    if !store.isConnected { Task { await store.connectSaved() } }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel)
                            .font(.subheadline.weight(.semibold))
                            // Scale rather than wrap: a single long word
                            // ("Disconnected") otherwise hyphenates mid-word.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(store.connectionSubtitle)
                            .font(.caption2)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .lineLimit(2)
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(store.isConnected)
                .accessibilityLabel(store.isConnected ? "Mac connected" : "\(store.connectionLabel). \(store.connectionSubtitle)")
                Spacer(minLength: 8)
                Button(action: onControl) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .hitTarget(4)
                }
                .buttonStyle(RemotePressButtonStyle())
                .disabled(!store.isConnected)
                .opacity(store.isConnected ? 1 : 0.62)
                .accessibilityLabel("Control Mac")
                .accessibilityHint(store.isConnected ? "Open a live view of this Mac" : "Connect to your Mac first")
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .hitTarget(4)
                }
                .buttonStyle(RemoteChromeButtonStyle())
                .accessibilityLabel("Settings")
                Button { Task { try? await store.refresh() } } label: {
                    Group {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 36, height: 36)
                    .hitTarget(4)
                }
                .buttonStyle(RemoteChromeButtonStyle())
                .accessibilityLabel("Refresh sessions")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            // The primary action of the whole screen, at the size of a primary
            // action. It used to be a 36pt "+" competing with three other
            // glyphs in the same row — the hardest thing on the screen to find
            // was the thing people open the app to do.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onStart()
            } label: {
                Label("New session", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .disabled(!store.isConnected)
            .opacity(store.isConnected ? 1 : 0.62)
            .accessibilityHint(store.isConnected ? "Type a prompt and start" : "Connect to your Mac first")
            SearchField(text: $search)
            // No Chat/Code switcher here: the mode belongs to a session, and every session is
            // created through the New session sheet, which asks for it there. On the home screen
            // it decided nothing — the list is not filtered by it — so it read as a filter that
            // did not work.
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(BeetTheme.background(appearance).opacity(0.94))
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
                .font(.caption2.weight(.bold))
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
    @State private var pendingDelete: RemoteSessionSummary?
    @State private var renaming: RemoteSessionSummary?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 2) {
            ForEach(sessions) { session in
                NavigationLink(value: session.id) { SessionRow(session: session) }
                    .buttonStyle(RemoteSessionButtonStyle())
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
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
    }

    private func reasoningButton(_ title: String, value: String?) -> some View {
        let selected = selection == value
        return Button(title) { selection = value }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : BeetTheme.secondaryText(appearance))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                selected ? BeetTheme.accent : BeetTheme.surfaceStrong(appearance),
                in: Capsule())
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ConnectionCard: View {
    let store: RemoteStore
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 11) {
            ZStack { Circle().fill((store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.13)).frame(width: 34, height: 34); Circle().fill(store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 9, height: 9).shadow(color: (store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.55), radius: 4) }
            VStack(alignment: .leading, spacing: 2) { Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel).font(.subheadline.weight(.semibold)); Text(store.connectionSubtitle).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 36, height: 36) } else { Button { Task { try? await store.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)).frame(width: 36, height: 36).background(BeetTheme.surfaceStrong(appearance), in: Circle()).hitTarget(4) }.buttonStyle(RemotePressButtonStyle()).accessibilityLabel("Refresh sessions") }
        }.padding(.horizontal, 12).frame(minHeight: 58).remoteGlass(appearance, radius: 17)
    }
}

struct SearchField: View {
    @Environment(\.remoteAppearance) private var appearance
    @Binding var text: String
    var body: some View {
        HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(BeetTheme.secondaryText(appearance)).accessibilityHidden(true); TextField("Search sessions", text: $text).textInputAutocapitalization(.never); if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(BeetTheme.secondaryText(appearance)) } }
            .padding(.horizontal, 13).frame(minHeight: 44)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .background(BeetTheme.surfaceStrong(appearance).opacity(0.5), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.7), lineWidth: 0.75) }
    }
}

struct SessionRow: View {
    let session: RemoteSessionSummary
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(session.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance).opacity(0.48))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: session.mode == "code" || !(session.workspacePath ?? "").isEmpty ? "folder.fill" : "bubble.left.and.bubble.right.fill")
                    Text(session.workspace).lineLimit(1)
                    Text("·")
                    Text("\(session.messageCount) messages")
                    if session.isRunning { Text("·"); Text(session.phase.capitalized).foregroundStyle(BeetTheme.accentBright) }
                }
                .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Date(timeIntervalSince1970: session.updatedAt).formatted(.relative(presentation: .named)))
                .font(.caption2.weight(.medium)).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(session.isRunning ? [.isButton, .updatesFrequently] : .isButton)
    }
}

struct RemoteSessionButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? BeetTheme.surfaceStrong(appearance) : BeetTheme.surface(appearance).opacity(0.22),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct RemoteChromeButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct RemotePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
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
                .font(.largeTitle)
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
                    .buttonStyle(.bordered)
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
        .padding(30)
        .frame(maxWidth: .infinity)
        .remoteGlass(appearance, radius: 18)
    }
}
