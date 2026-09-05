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
/// The session list, rebuilt on the platform's own list.
///
/// It used to be a hand-drawn header (title, connection line, three icon
/// buttons, a primary button and a search pill) over a hand-drawn card of
/// hand-drawn rows, under a toolbar of four unlabelled glyphs — twelve controls
/// before the first session. This is a stock `insetGrouped` list with a large
/// title and `.searchable`, which is both far less code and where swipe
/// actions, section headers, VoiceOver order and Dynamic Type come from.
struct SessionListView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
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
    @State private var pendingDelete: RemoteSessionSummary?
    @State private var renaming: RemoteSessionSummary?
    @State private var renameDraft = ""

    private var visible: [RemoteSessionSummary] {
        guard !search.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.workspace.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            connectionSection
            if visible.isEmpty {
                Section { emptyState }
            } else {
                ForEach(SessionDaySection.group(visible)) { section in
                    Section(section.title) {
                        ForEach(section.sessions) { session in
                            NavigationLink(value: session.id) { SessionRow(session: session) }
                                .remoteListRow()
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        pendingDelete = session
                                    }
                                    Button("Rename", systemImage: "pencil") {
                                        renameDraft = session.title
                                        renaming = session
                                    }
                                    .tint(.gray)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { RemoteBackdrop() }
        .refreshable { try? await store.refresh() }
        .searchable(text: $search, prompt: "Search sessions")
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startBotID = ""
                    showStartSession = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!store.isConnected)
                .accessibilityLabel("New session")
                .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // One labelled menu, not four unlabelled glyphs. Every entry
                // now says what it does at any Dynamic Type size.
                Menu {
                    Button("Control Mac", systemImage: "display.and.arrow.down") { showControl = true }
                        .disabled(!store.isConnected)
                    Button("App Stream", systemImage: "macwindow.on.rectangle") { showAppStream = true }
                        .disabled(!store.isConnected)
                    Divider()
                    Button("Specialist bots", systemImage: "person.3.sequence.fill") { showBotRuns = true }
                    Button("Share clipboard or files", systemImage: "square.and.arrow.up") { showSharing = true }
                    Divider()
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
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
                        if await store.deleteSession(session.id) {
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
                Task { _ = await store.renameSession(session.id, title: title) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a short name that is easy to find in history.")
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

    /// The Mac itself, as the list's first row: connected or not, and the way
    /// into the computer switcher. The old header said the same thing in a
    /// custom status line that also had to explain itself in a subtitle.
    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Button {
                if store.isConnected { showComputers = true }
                else { Task { await store.connectSaved() } }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(store.activeComputerName)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(store.isConnected ? "Connected" : store.connectionLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .remoteListRow()
            .accessibilityLabel("\(store.activeComputerName), \(store.isConnected ? "connected" : store.connectionLabel)")
            .accessibilityHint(store.isConnected ? "Switch computer" : "Reconnect")
        } footer: {
            if !store.isConnected {
                Text(store.connectionSubtitle)
            }
        }
    }

    private var connectionTint: Color {
        if store.isConnected { return .green }
        if store.isConnecting { return .orange }
        return .secondary
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
                .remoteListRow()
        } else {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start one here, or continue a conversation from your Mac.")
            } actions: {
                Button("Start a chat") {
                    startBotID = ""
                    showStartSession = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isConnected)
            }
            .remoteListRow()
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

/// Sessions bucketed by day, the way Mail and Messages group a long history.
/// One undifferentiated list of 100 chats gives no sense of when anything
/// happened; "Today" and "Yesterday" do most of that work for free.
struct SessionDaySection: Identifiable {
    let id: String
    let title: String
    let sessions: [RemoteSessionSummary]

    static func group(
        _ sessions: [RemoteSessionSummary],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [SessionDaySection] {
        var today: [RemoteSessionSummary] = []
        var yesterday: [RemoteSessionSummary] = []
        var earlier: [RemoteSessionSummary] = []
        for session in sessions {
            let date = Date(timeIntervalSince1970: session.updatedAt)
            if calendar.isDate(date, inSameDayAs: now) { today.append(session) }
            else if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
                yesterday.append(session)
            }
            else { earlier.append(session) }
        }
        var sections: [SessionDaySection] = []
        if !today.isEmpty { sections.append(SessionDaySection(id: "today", title: "Today", sessions: today)) }
        if !yesterday.isEmpty { sections.append(SessionDaySection(id: "yesterday", title: "Yesterday", sessions: yesterday)) }
        if !earlier.isEmpty { sections.append(SessionDaySection(id: "earlier", title: "Earlier", sessions: earlier)) }
        return sections
    }
}

/// A standard two-line row: headline, subtitle, trailing timestamp. The
/// running session carries the leading dot Mail uses for unread — the one
/// thing on this screen that is genuinely urgent.
struct SessionRow: View {
    let session: RemoteSessionSummary

    private var isCode: Bool {
        session.mode == "code" || !(session.workspacePath ?? "").isEmpty
    }

    private var place: String { isCode ? session.workspace : "Chat" }

    private var subtitle: String {
        session.isRunning
            ? "\(session.phase.capitalized) · \(place)"
            : "\(place) · \(session.messageCount) messages"
    }

    private var timestamp: String {
        let date = Date(timeIntervalSince1970: session.updatedAt)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(BeetTheme.accentBright)
                .frame(width: 10, height: 10)
                // Hidden rather than absent: the titles stay aligned whether or
                // not a session is running.
                .opacity(session.isRunning ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(session.isRunning ? BeetTheme.accentBright : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(timestamp)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(session.isRunning ? .updatesFrequently : [])
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
